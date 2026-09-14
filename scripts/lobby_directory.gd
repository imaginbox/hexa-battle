class_name LobbyDirectory
extends Node
## A public list of open games, built by the players themselves.
##
## Ziva's relay is a message switch: it routes by room name and knows nothing about
## which rooms exist, so a list of open games cannot be asked for — it has to be
## announced. This node keeps a second relay connection of its own (the "lobby
## channel") alongside the game's, and hosts publish their room on it while browsers
## listen and build the list. The two connections never share a socket, so browsing
## for a game cannot disturb one already in progress.
##
## Nothing here touches the game's own connection: this script deliberately does not
## refer to the [code]Net[/code] autoload, because a script carrying a [code]class_name[/code]
## can be compiled before the autoloads exist. It reads the relay settings from
## [ProjectSettings] directly instead.

## The list of open rooms changed: the VS screen should redraw it.
signal rooms_changed

## The lobby channel's own room name. Nothing is played here — it carries
## announcements and nothing else, so it must never collide with a game room.
const LOBBY_ROOM := "hexa-lobby"
## The relay's phantom slot. Ids at or below it are not real peers.
const RELAY_SERVER_ID := 1
## How often a host republishes its room, in seconds.
const PUBLISH_INTERVAL := 2.0
## How long an entry survives without a republish, in seconds. Three missed
## announcements: long enough to ride out a hiccup, short enough that a room whose host
## has left — or whose browser tab was closed, which the relay never reports — does not
## linger in the list as a place nobody can join.
const ENTRY_TTL := 6.0

var _sm: SceneMultiplayer
var _peer: WebSocketMultiplayerPeer
var _connected: bool = false

## The room this peer is announcing, empty when it is not hosting a public game.
var _published_code: String = ""
## Players currently seated in the published room, as of the last announcement.
var _published_count: int = 0
## Seconds left before the next announcement.
var _publish_left: float = 0.0

## Every room heard from, keyed by code: {code, count, max, ts}.
var _rooms: Dictionary = {}


func _ready() -> void:
	# One SceneMultiplayer is created up front and kept for the life of the node. Only
	# its peer is swapped when the lobby channel opens and closes, because registering
	# a fresh multiplayer with the tree on every visit would leak one per visit.
	_sm = SceneMultiplayer.new()
	_sm.multiplayer_peer = OfflineMultiplayerPeer.new()
	get_tree().set_multiplayer(_sm, get_path())
	set_process(false)


# --- Canal ----------------------------------------------------------------

## Opens the lobby channel. Safe to call repeatedly; a second call while open does
## nothing. A failure is silent on purpose — browsing is a convenience, and the
## private-code path must keep working whether or not it is available.
func open() -> void:
	if _peer != null:
		return
	_flush_dns()
	IP.clear_cache(_relay_host())
	var url: String = _relay_url(LOBBY_ROOM)
	if url.is_empty():
		return
	_peer = WebSocketMultiplayerPeer.new()
	var err: int = _peer.create_client(url)
	if err != OK:
		_peer = null
		return
	_sm.multiplayer_peer = _peer
	_connected = false
	set_process(true)


## Closes the lobby channel and forgets every room heard on it.
func close() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	_sm.multiplayer_peer = OfflineMultiplayerPeer.new()
	_connected = false
	_published_code = ""
	_published_count = 0
	_publish_left = 0.0
	var had: bool = not _rooms.is_empty()
	_rooms.clear()
	set_process(false)
	if had:
		rooms_changed.emit()


func is_open() -> bool:
	return _peer != null


# --- Publication ----------------------------------------------------------

## Announces `code` as an open room holding `count` players. Called by a host; the
## announcement is repeated on a timer until [method unpublish].
func publish(code: String, count: int) -> void:
	_published_code = code
	_published_count = count
	_publish_left = 0.0


## Stops announcing. The entry disappears from other players' lists on its own once it
## stops being refreshed.
func unpublish() -> void:
	_published_code = ""
	_published_count = 0


## Every open room heard from recently, oldest announcement first. Read by the VS
## screen to draw the list.
func rooms() -> Array[Dictionary]:
	_prune()
	var out: Array[Dictionary] = []
	for code: String in _rooms:
		out.append(_rooms[code])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["code"]) < str(b["code"]))
	return out


# --- Boucle ---------------------------------------------------------------

func _process(delta: float) -> void:
	if _peer == null:
		return
	_sm.poll()
	var now_connected: bool = _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	if now_connected != _connected:
		_connected = now_connected
		# A host that was mid-announcement when the socket dropped gets back on the air
		# the moment it reconnects, rather than waiting out its timer.
		if _connected and not _published_code.is_empty():
			_publish_left = PUBLISH_INTERVAL
	if _published_code.is_empty():
		_prune()
		return
	_publish_left -= delta
	if _publish_left > 0.0:
		return
	_publish_left = PUBLISH_INTERVAL
	if _connected:
		_announce.rpc({
			"code": _published_code,
			"count": _published_count,
			"max": 4,
		})


## Drops every entry that has gone quiet, telling the screen when that changed the
## list. Always called before the list is read, so a stale entry is never shown.
func _prune() -> void:
	if _rooms.is_empty():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	var dropped: bool = false
	for code: String in _rooms.keys():
		if now - float(_rooms[code]["ts"]) > ENTRY_TTL:
			_rooms.erase(code)
			dropped = true
	if dropped:
		rooms_changed.emit()


## A room announcement from a host. `reliable` because a lost one is a room missing
## from the list until the next one, and the payload is tiny.
@rpc("any_peer", "reliable")
func _announce(info: Dictionary) -> void:
	var code: String = str(info.get("code", "")).strip_edges()
	if code.is_empty():
		return
	var count: int = int(info.get("count", 0))
	var max_players: int = int(info.get("max", 4))
	var before: String = _entry_signature(_rooms.get(code, {}))
	_rooms[code] = {
		"code": code,
		"count": count,
		"max": max_players,
		"ts": Time.get_ticks_msec() / 1000.0,
	}
	# Only redraw when the visible content changed. A republish is a heartbeat, not
	# news, and rebuilding the list twice a second for every open room would make the
	# screen flicker under the player's cursor.
	if before != _entry_signature(_rooms[code]):
		rooms_changed.emit()


func _entry_signature(entry: Dictionary) -> String:
	return "%s/%s" % [str(entry.get("count", "")), str(entry.get("max", ""))]


# --- Réglages -------------------------------------------------------------

## Builds the relay URL for `room`, or an empty string when the project has not been
## given relay settings — in which case there is no online directory to speak of.
func _relay_url(room: String) -> String:
	var user_id: String = ProjectSettings.get_setting("ziva/multiplayer/user_id", "")
	var game_id: String = ProjectSettings.get_setting("ziva/multiplayer/game_id", "")
	var relay_url: String = ProjectSettings.get_setting("ziva/multiplayer/relay_url", "")
	if user_id.is_empty() or game_id.is_empty() or relay_url.is_empty():
		return ""
	return "%s/r/%s?u=%s&g=%s&v=1" % [relay_url, room, user_id, game_id]


## The bare host of the relay URL, so its DNS answer can be dropped before dialling.
func _relay_host() -> String:
	var relay_url: String = ProjectSettings.get_setting("ziva/multiplayer/relay_url", "")
	var host: String = relay_url
	for prefix in ["wss://", "ws://", "https://", "http://"]:
		if host.begins_with(prefix):
			host = host.substr(prefix.length())
			break
	var slash: int = host.find("/")
	return host.substr(0, slash) if slash >= 0 else host


## Empties the OS resolver cache on Windows before dialling. Duplicated from [code]Net[/code]
## rather than called through it, because a class_name script cannot rely on the
## autoload being registered by the time it compiles.
func _flush_dns() -> void:
	if OS.get_name() != "Windows":
		return
	OS.execute("ipconfig", ["/flushdns"], [], true)
