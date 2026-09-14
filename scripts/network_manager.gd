extends Node
## Connection, seating and authority for a match, over either transport.
##
## Lives as the `Net` autoload so it outlives the lobby -> game scene change.
##
## Everything above this node — seats, corners, colours, the board — is shared by
## both transports, because a seat is just an index derived from join order:
##
## [b]Relay[/b] — a [WebSocketMultiplayerPeer] against Ziva's hosted relay. Plays
## online with nothing to configure, on any network, browser exports included. The
## relay is a message switch with no game server, so peer [constant SERVER_ID] is a
## phantom slot it owns and runs no code: authority has to be elected, and the
## lowest [i]real[/i] peer id (above 1) owns the table.
##
## [b]ENet[/b] — an [ENetMultiplayerPeer] for a local or LAN match. Here peer
## [constant SERVER_ID] is a genuine server running our code, so authority is
## simply [method MultiplayerAPI.is_server] and needs no election at all — but
## reaching it from outside the LAN needs a port forward, which is exactly the
## problem the relay exists to remove.
##
## The two differ only in who owns the table and therefore which guard can be used
## on a seating broadcast, so both funnel into one [member _table_owner] and one
## [method _seats_received].

## Seating changed: the lobby redraws its player list.
signal seats_changed
## The host started the round: every peer leaves the lobby for the board.
signal game_started
## A connection could not be opened, or the host closed the match. `reason` is
## meant for the player.
signal failed(reason: String)
## The session was left, or the host dropped us.
signal session_ended
## A waiting-room line arrived. `seat` is the speaker's card (-1 if it holds none),
## `text` is the line, and `mine` is whether this peer was the one who said it.
signal chat_line(seat: int, text: String, mine: bool)

## Which of the two transports a match runs over.
enum Transport { RELAY, ENET }

## What occupies a card at the table.
enum SeatKind { EMPTY, HUMAN, AI }

## The relay's own server slot. On ENet this id is a real peer; on the relay it is a
## phantom that never runs our code, which is the whole reason the two differ.
const SERVER_ID := 1
const DEFAULT_ROOM := "hexa-1"
const DEFAULT_ADDRESS := "127.0.0.1"
const DEFAULT_PORT := 7777
const MIN_PLAYERS := 2
const MAX_PLAYERS := 4
## Colour and starting corner are decided by seat index alone, so every peer shows
## the same table without negotiating anything. The colours themselves live in
## [GameState] because the board needs them too, and the board must not depend on
## this autoload.
const CORNER_NAMES := ["corner Sud-Ouest", "corner Nord-Est", "corner Sud-Est", "corner Nord-Ouest"]

## Transport for the next match. Online is the default: it is the one that needs no
## setup from the player, and local ENet is the testing shortcut.
var transport: Transport = Transport.RELAY
## Relay room name.
var room: String = DEFAULT_ROOM
## Whether the room this peer opens should be listed in the public directory. A private
## match is found by its code; a public one is meant to be seen and joined by anyone.
var public_room: bool = false
## ENet address this peer last tried to reach, shown back in the lobby.
var address: String = DEFAULT_ADDRESS
## Port the ENet server listens on and clients dial. Fixed, so joining is one field.
var port: int = DEFAULT_PORT
## The table, always [constant MAX_PLAYERS] entries. The index IS the seat number,
## so a seat is a card somebody sits at rather than a position in a list of ids —
## which is what lets one card sit empty between two occupied ones.
##
## Each entry is `{"kind": SeatKind, "peer": int, "ready": bool}`. Only the table's
## owner ever writes to it; everyone else is sent copies.
var slots: Array[Dictionary] = []
var connected: bool = false
var started: bool = false

## The peer that owns the table. On ENet that is always the server. On the relay it
## is the elected lowest real peer, and stays 0 until this peer learns who it is.
var _table_owner: int = 0

## How many relay connection attempts have already failed, and the ceiling.
##
## The relay is a Cloudflare Worker, so its hostname resolves to a pool of edge IPs
## and a resolver is free to hand back any of them. Some of that pool is unreachable
## from a given network — a DNS that returns a black-holed edge produces exactly the
## flaky "connecting… never connects" a single attempt gives. Reconnecting rolls the
## dice again and, in practice, lands on a working edge within a couple of tries.
const RELAY_MAX_ATTEMPTS := 8
## Seconds between two relay attempts, so a failing burst does not hammer the resolver.
const RELAY_RETRY_DELAY := 1.0
var _relay_attempts: int = 0
## Set while a retry is already pending, so two failures cannot stack loops.
var _relay_retry_pending: bool = false

## How often a peer tells the room it is still there, in seconds.
const HEARTBEAT_INTERVAL := 1.5
## How long a peer may stay silent before it is treated as gone, in milliseconds.
##
## The relay is a message switch, not a server: it does not prune its own peer list,
## and Godot's `get_peers()` keeps reporting a peer that has stopped running. That is
## not a rare case here — a browser tab in the background has its requestAnimationFrame
## loop frozen, so a web peer goes completely silent while its socket stays open. The
## room then has a member that never answers, still holding the lowest id, and on a
## relay the lowest id **is** the table owner: nobody can be seated, and the ready
## button stays grey for ever. Counting only peers that have proved they are alive is
## what stops one abandoned tab from freezing the whole lobby.
const PEER_TIMEOUT_MS := 10000
## Last time each peer was heard from, keyed by peer id, in [method Time.get_ticks_msec].
var _last_seen: Dictionary = {}
## Peers this node has already met in this session. Kept separately from [_last_seen]
## so an expired peer is not mistaken for a newcomer and given the benefit of the doubt
## all over again — it is known, and no longer answering, and that is the whole signal.
var _known_peers: Dictionary = {}
var _heartbeat_left: float = 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# Every change of the table is mirrored into GameState for the board. Hooking the
	# signal rather than each caller keeps the mirror honest however the table moved.
	seats_changed.connect(_publish_table)
	_reset_slots()
	_publish_table()
	# The relay never prunes its own member list, so presence has to be proven rather
	# than assumed. This is the only clock the whole presence scheme needs.
	set_process(true)


func _process(delta: float) -> void:
	if transport != Transport.RELAY or not connected:
		return
	_heartbeat_left -= delta
	if _heartbeat_left > 0.0:
		return
	_heartbeat_left = HEARTBEAT_INTERVAL
	_heartbeat.rpc()
	_prune_silent_peers()
	_refresh_publication()


## Keeps the public directory entry for this room alive while it is ours to advertise.
##
## Only the table's owner publishes — a joiner must not advertise a room it does not
## hold, and the owner is also the one whose departure should take the entry down. The
## count travels with it so the list can say "1/4" rather than just naming rooms, and
## it is refreshed from the live table each beat so it follows people joining.
func _refresh_publication() -> void:
	if not public_room or not is_host() or started:
		Lobby.unpublish()
		return
	Lobby.publish(room, active_count())


## Says "still here" to the room. Every peer stamps the sender on arrival, which is
## what [method _prune_silent_peers] reads. A local call is used so a peer also stamps
## itself and can never time out on its own heartbeat.
@rpc("any_peer", "call_local", "unreliable")
func _heartbeat() -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	_last_seen[sender] = Time.get_ticks_msec()
	_known_peers[sender] = true


## Drops every known peer that has gone quiet for [constant PEER_TIMEOUT_MS]. When the
## one that fell silent is the owner, authority is re-elected immediately rather than
## waiting for a disconnection the relay will never deliver.
func _prune_silent_peers() -> void:
	var now: int = Time.get_ticks_msec()
	var dropped: bool = false
	for peer: int in _last_seen.keys():
		if peer == multiplayer.get_unique_id():
			continue
		if now - int(_last_seen[peer]) > PEER_TIMEOUT_MS:
			_last_seen.erase(peer)
			dropped = true
	if not dropped:
		return
	_refresh_table_owner(true)
	if is_host():
		# We just inherited the table: publish it so everyone is seated, rather than
		# leaving the room waiting for an owner that will never speak again.
		_rebuild_slots()
		_broadcast_table()
	else:
		seats_changed.emit()


## Mirrors the table into [GameState], which is where the board reads it from. See
## [member GameState.occupied_seats] for why the board does not simply ask this node.
##
## Solo is published from here too, as a fixed two-card table: this player on seat 0
## and the AI on seat 1. That keeps the board and the AI commander on one code path
## for both modes — they differ only in the mode flag, not in the shape of a table.
func _publish_table() -> void:
	if not connected:
		GameState.configure_table([0, 1], [1], 0, false)
		return
	GameState.configure_table(occupied_seats(), ai_seats(), local_seat(), true)


# --- Connexion ----------------------------------------------------------------

## Chooses the online relay for the next match.
func select_online_mode() -> void:
	_select_transport(Transport.RELAY)


## Chooses local/LAN ENet for the next match.
func select_local_mode() -> void:
	_select_transport(Transport.ENET)


## Whether the next match will use the online relay.
func is_online_mode() -> bool:
	return transport == Transport.RELAY


## Whether local ENet can be offered at all. A browser has no raw sockets, so a web
## build can only ever reach the relay — the option is withdrawn rather than offered
## and then failing on the click.
func local_transport_available() -> bool:
	return not OS.has_feature("web")


## Ignored while connected, so a live match can never have its transport changed
## under it.
func _select_transport(value: Transport) -> void:
	if connected:
		return
	if value == Transport.ENET and not local_transport_available():
		return
	transport = value


func leave_room() -> void:
	_teardown()
	# A private room is the default, so the next match starts private unless its host
	# says otherwise — a public listing is a decision, never something left over from
	# the last game.
	public_room = false
	session_ended.emit()
	seats_changed.emit()


## Opens a match. On the relay this only joins the room — the relay has no game
## server, so "hosting" there means being the lowest peer present, which happens by
## itself. On ENet it starts a real server.
func open_match() -> void:
	if transport == Transport.RELAY:
		_join_relay()
	else:
		_host_enet()


## Joins a match at `target`: a room name on the relay, an address on ENet. An
## empty target reuses whatever this peer last used.
func join_match(target: String = "") -> void:
	var wanted: String = target.strip_edges()
	if transport == Transport.RELAY:
		if not wanted.is_empty():
			room = wanted
		_join_relay()
		return
	if not wanted.is_empty():
		address = wanted
	_join_enet()


## Whether this peer owns the table: the ENet server, or the elected relay host.
func is_host() -> bool:
	if not connected:
		return false
	if transport == Transport.ENET:
		return multiplayer.is_server()
	return _table_owner > 0 and multiplayer.get_unique_id() == _table_owner


## The peer that owns the table, or 0 while this peer has not learnt who it is. The
## board aims its actions here, so it is readable from outside this node — which is
## the one piece of the election the rest of the game actually needs.
func table_owner() -> int:
	return _table_owner


## Starts the round. Only the owner may, and only once the table is genuinely
## playable: two cards or more, and every one of them ready.
func start_game() -> void:
	if not is_host() or started or not all_ready():
		return
	started = true
	_begin()
	_begin_received.rpc()


func _teardown() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	connected = false
	started = false
	_reset_slots()
	_table_owner = 0
	# Leaving takes the room off the public list at once, rather than letting it hang
	# there until the entry times out on everybody else's screen.
	Lobby.unpublish()
	# Presence is per-room, so it dies with the connection. Keeping the stamps would
	# carry a stale "who I knew" into the next match.
	_last_seen.clear()
	_known_peers.clear()
	_heartbeat_left = 0.0


# --- Ouverture des deux transports ---------------------------------------------

## Relay: every peer, host included, simply becomes a client of the relay.
func _join_relay() -> void:
	_teardown()
	_relay_attempts = 0
	_relay_retry_pending = false
	_open_relay_peer()


## Opens one relay connection. Split out of [method _join_relay] so a failed attempt
## can be retried without going through [method _teardown]'s lobby-visible signals.
func _open_relay_peer() -> void:
	var user_id: String = ProjectSettings.get_setting("ziva/multiplayer/user_id", "")
	var game_id: String = ProjectSettings.get_setting("ziva/multiplayer/game_id", "")
	var relay_url: String = ProjectSettings.get_setting("ziva/multiplayer/relay_url", "")
	# Fail loud rather than fall back to a default origin: a missing value would
	# connect to the wrong relay and waste a debug cycle.
	if user_id.is_empty() or game_id.is_empty() or relay_url.is_empty():
		failed.emit("Réglages du relais absents — demande à Ziva d'activer le multijoueur.")
		return
	var target: String = room.strip_edges()
	if target.is_empty():
		target = DEFAULT_ROOM
	room = target
	# Cloudflare hands the relay hostname out as a pool of edge IPs, and a resolver
	# may return one this network cannot reach — a filtered edge, or an IPv6 address
	# on a link with no working IPv6. The OS resolver caches that dead answer and
	# keeps serving it, so every dial goes to the same black hole and the relay looks
	# "down" while the hostname is perfectly fine. Emptying that cache before each
	# attempt makes the next dial draw a fresh answer; measured here, one flush takes
	# the relay from 0/10 to 6/6. Only Windows has the command, and in a browser the
	# engine's own networking already handles this, so both are simply skipped.
	_flush_dns()
	IP.clear_cache(_relay_host())
	var url: String = "%s/r/%s?u=%s&g=%s&v=1" % [relay_url, target, user_id, game_id]
	var peer := WebSocketMultiplayerPeer.new()
	var err: int = peer.create_client(url)
	if err != OK:
		failed.emit("Impossible d'ouvrir le relais (erreur %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	_arm_relay_watchdog()


## Empties the OS resolver cache on Windows, which is where a stale black-holed edge
## hides. A no-op everywhere else, and it never blocks: the command is given a short
## window so a hung resolver service cannot stall the connect flow.
func _flush_dns() -> void:
	if OS.get_name() != "Windows":
		return
	OS.execute("ipconfig", ["/flushdns"], [], true)


## The bare host of the relay URL, so the DNS cache can be addressed by name.
func _relay_host() -> String:
	var relay_url: String = ProjectSettings.get_setting("ziva/multiplayer/relay_url", "")
	var host: String = relay_url
	for prefix in ["wss://", "ws://", "https://", "http://"]:
		if host.begins_with(prefix):
			host = host.substr(prefix.length())
			break
	var slash: int = host.find("/")
	if slash >= 0:
		host = host.substr(0, slash)
	return host


## How long a relay attempt may stay silent before it is treated as a dead end. A
## black-holed edge does not always raise `connection_failed` — the socket simply
## never settles — so waiting on that signal alone leaves the player stuck on
## "connecting…" for ever. This timer is what turns that silence into a retry.
const RELAY_CONNECT_TIMEOUT := 6.0
var _relay_watchdog: SceneTreeTimer = null


## Starts (or restarts) the silence timer for the current attempt. Cancelled the
## moment the connection lands via [method _on_connected_to_server].
func _arm_relay_watchdog() -> void:
	_relay_watchdog = get_tree().create_timer(RELAY_CONNECT_TIMEOUT)
	var token: SceneTreeTimer = _relay_watchdog
	await token.timeout
	# A newer attempt replaced this timer; its own watchdog is the one that matters.
	if _relay_watchdog != token:
		return
	if connected or transport != Transport.RELAY:
		return
	_on_connection_failed()


## ENet: opens a server on [member port] and seats this peer at seat 0.
func _host_enet() -> void:
	_teardown()
	# Belt and braces behind _select_transport: a browser reaching here would fail
	# with a bare engine error, which reads as a crash rather than as "not supported".
	if not local_transport_available():
		failed.emit("Le mode local n'existe pas dans un navigateur — joue en ligne.")
		return
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		failed.emit("Impossible d'ouvrir le port %d (erreur %d)." % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	connected = true
	_table_owner = SERVER_ID
	# The server is peer 1 and needs no handshake to belong to its own table, nor
	# anyone to send it one.
	_rebuild_slots()
	_broadcast_table()


func _join_enet() -> void:
	_teardown()
	if not local_transport_available():
		failed.emit("Le mode local n'existe pas dans un navigateur — joue en ligne.")
		return
	var peer := ENetMultiplayerPeer.new()
	var err: int = peer.create_client(address, port)
	if err != OK:
		failed.emit("Adresse « %s » invalide (erreur %d)." % [address, err])
		return
	multiplayer.multiplayer_peer = peer


# --- Table ---------------------------------------------------------------------

## How many cards hold anything at all, AI included.
func player_count() -> int:
	return active_count()


## The card this peer sits at, or -1 when it holds none yet.
func my_seat() -> int:
	return seat_of_peer(multiplayer.get_unique_id())


## The seat this peer actually plays from. Solo has no match at all, so it is always
## seat 0 there — which keeps the single-player board on the same code path as a
## four-player one.
func local_seat() -> int:
	var found: int = seat_of_peer(multiplayer.get_unique_id())
	return found if found >= 0 else 0


## Whether there is a real table to play against, as opposed to solo.
func is_multiplayer() -> bool:
	return active_count() >= MIN_PLAYERS


func board_radius() -> int:
	return GameState.radius_for_players(active_count())


func color_for_seat(seat: int) -> Color:
	return GameState.seat_color(seat)


## Starting corner of a seat, as a name. The board turns the same index into
## coordinates in [method GameGrid.corner_coords], which is written to this order.
func corner_for_seat(seat: int) -> String:
	return CORNER_NAMES[seat % CORNER_NAMES.size()]


# --- Réseau --------------------------------------------------------------------

func _on_connected_to_server() -> void:
	connected = true
	# The attempt landed: disarm the silence timer so it cannot fire a false failure.
	_relay_watchdog = null
	if transport == Transport.ENET:
		# ENet's server is peer 1 and owns the table outright. It sends ours as soon
		# as it has processed our arrival. (This signal never fires on the server
		# itself — it seated itself in _host_enet.)
		_table_owner = SERVER_ID
	else:
		# Self is a candidate even on the connect burst. A roster here can be
		# incomplete — the relay does not announce peers that were already in the room
		# — so the minimum of what we can see may be too high; but it can never be too
		# low, and an owner that is too high is corrected the moment a lower peer
		# publishes (see _table_received). Excluding self instead strands a peer that
		# joins an empty room, or one whose host has just gone: nothing else will ever
		# tell it that it is the host, so it sits on no card for ever.
		_refresh_table_owner(true)
		if is_host():
			_rebuild_slots()
			_broadcast_table()
	seats_changed.emit()


## The relay announces its own phantom slot [constant SERVER_ID] as a peer arrival.
## It is not one — nobody runs code there — and treating it as an arrival makes a
## lone joiner re-elect itself as the table owner against an empty roster and
## broadcast a bogus table. ENet never announces id 1 this way: a client is told it
## connected to the server, not that the server arrived.
##
## `_id` is otherwise unused on purpose: the table is rebuilt from
## [method MultiplayerAPI.get_peers], which already lists the newcomer by the time
## this fires, so it cannot get out of step with the peer list.
func _on_peer_connected(id: int) -> void:
	if id <= SERVER_ID:
		return
	if transport == Transport.ENET and not multiplayer.is_server():
		# Only the server holds an ENet table; clients learn about each other
		# through the table broadcast, never by rebuilding it themselves.
		seats_changed.emit()
		return
	# On the relay a newcomer can change who the lowest real peer is, so re-elect
	# before deciding whether we are the one to republish. Self is a candidate here:
	# the connect-burst exclusion above is about a roster that is not yet complete,
	# not about one that has just grown.
	_refresh_table_owner(true)
	if not is_host():
		seats_changed.emit()
		return
	_rebuild_slots()
	_broadcast_table()


func _on_peer_disconnected(id: int) -> void:
	if id <= SERVER_ID:
		return
	if transport == Transport.ENET and not multiplayer.is_server():
		seats_changed.emit()
		return
	# Reactive failover: recompute from the roster, which is now authoritative. If
	# that makes us the new lowest peer we adopt the table immediately — no timer
	# and no grace window.
	_refresh_table_owner(true)
	if not is_host():
		seats_changed.emit()
		return
	_rebuild_slots()
	_broadcast_table()


func _on_connection_failed() -> void:
	connected = false
	if transport == Transport.RELAY:
		# A relay hostname resolves to a pool of Cloudflare edges, and a resolver can
		# hand back one this network cannot reach. That is transient, not a refusal —
		# so the connection is retried before the player is told anything, and only a
		# run of failures ends in a message.
		if _relay_attempts < RELAY_MAX_ATTEMPTS and not _relay_retry_pending:
			_relay_attempts += 1
			_relay_retry_pending = true
			_retry_relay_soon()
			return
		failed.emit("Connexion au salon « %s » refusée." % room)
	else:
		failed.emit("Connexion à %s:%d refusée." % [address, port])


## Waits out [constant RELAY_RETRY_DELAY] then rolls a fresh relay connection. The
## timer keeps the retry off the signal stack, so a synchronous failure cannot recurse.
func _retry_relay_soon() -> void:
	await get_tree().create_timer(RELAY_RETRY_DELAY).timeout
	_relay_retry_pending = false
	# The player may have left the lobby while the timer ran; nothing to reopen then.
	if transport != Transport.RELAY or connected:
		return
	_open_relay_peer()


func _on_server_disconnected() -> void:
	leave_room()
	failed.emit("L'hôte a fermé la partie.")


## Relay only: real peers are everyone above the phantom slot the relay owns, and only
## those that have proved they are alive. A peer the relay still lists but that has
## gone silent is treated as gone — see [constant PEER_TIMEOUT_MS] for why that matters
## on this transport specifically.
func _real_peers() -> Array[int]:
	var now: int = Time.get_ticks_msec()
	var out: Array[int] = []
	for p in multiplayer.get_peers():
		var id: int = int(p)
		if id <= SERVER_ID:
			continue
		# A peer only just met may not be stamped yet (its first heartbeat can still be
		# in flight); give it the benefit of the doubt. A peer already known and silent
		# past the window is gone, however loudly the relay still lists it.
		if _known_peers.has(id) and now - int(_last_seen.get(id, 0)) > PEER_TIMEOUT_MS:
			continue
		out.append(id)
	return out


## Relay only: elect the table owner as the lowest real peer id. `include_self` is
## false during the connect burst alone, where a peer's roster may not yet list the
## lower peers the relay is about to deliver.
func _refresh_table_owner(include_self: bool = true) -> void:
	if transport != Transport.RELAY:
		return
	var candidates: Array[int] = _real_peers()
	var me: int = multiplayer.get_unique_id()
	if include_self and me > SERVER_ID:
		candidates.append(me)
	candidates.sort()
	# Never drop a known owner to 0 on a transient empty view, so authority does not
	# flicker off the real host mid-burst.
	if candidates.size() > 0:
		_table_owner = int(candidates[0])


# --- Sièges --------------------------------------------------------------------

## The table with every card empty. Also the state a peer sits in before the owner
## has told it who it is playing with.
func _reset_slots() -> void:
	slots.clear()
	for i in MAX_PLAYERS:
		slots.append(_empty_slot())


func _empty_slot() -> Dictionary:
	return {"kind": SeatKind.EMPTY, "peer": 0, "ready": false}


## Every peer that should hold a card, including this one. The two transports answer
## it differently because their peer lists mean different things: ENet's server is a
## real peer listed alongside the clients, whereas the relay's slot 1 is a phantom
## that nobody runs and must never be seated.
func _roster() -> Array[int]:
	var alive: Array[int] = []
	if transport == Transport.ENET:
		for id in multiplayer.get_peers():
			alive.append(int(id))
		if not alive.has(SERVER_ID):
			alive.append(SERVER_ID)
	else:
		alive.append(multiplayer.get_unique_id())
		for id in _real_peers():
			alive.append(id)
	alive.sort()
	return alive


## Seats that hold anything at all, AI included, in ascending order. A list rather
## than a count because the cards can have holes in them.
func occupied_seats() -> Array[int]:
	var out: Array[int] = []
	for i in slots.size():
		if int(slots[i]["kind"]) != SeatKind.EMPTY:
			out.append(i)
	return out


func active_count() -> int:
	return occupied_seats().size()


## Seats run by the AI rather than by a person.
func ai_seats() -> Array[int]:
	var out: Array[int] = []
	for i in slots.size():
		if int(slots[i]["kind"]) == SeatKind.AI:
			out.append(i)
	return out


func is_seat_empty(seat: int) -> bool:
	return seat >= 0 and seat < slots.size() and int(slots[seat]["kind"]) == SeatKind.EMPTY


func is_seat_ai(seat: int) -> bool:
	return seat >= 0 and seat < slots.size() and int(slots[seat]["kind"]) == SeatKind.AI


## The card a peer sits at, or -1 when it has none.
func seat_of_peer(peer_id: int) -> int:
	for i in slots.size():
		var slot: Dictionary = slots[i]
		if int(slot["kind"]) == SeatKind.HUMAN and int(slot["peer"]) == peer_id:
			return i
	return -1


func _first_empty_seat() -> int:
	for i in slots.size():
		if int(slots[i]["kind"]) == SeatKind.EMPTY:
			return i
	return -1


## Rebuilds the table from the live roster: whoever arrived takes the lowest free
## card, cards whose player has left go back to empty, and AI cards are left alone —
## they were placed deliberately by the host and are not the roster's business.
func _rebuild_slots() -> void:
	var live: Array[int] = _roster()
	for i in slots.size():
		var slot: Dictionary = slots[i]
		if int(slot["kind"]) == SeatKind.HUMAN and not live.has(int(slot["peer"])):
			slots[i] = _empty_slot()
	for peer in live:
		if seat_of_peer(peer) >= 0:
			continue
		var free: int = _first_empty_seat()
		if free < 0:
			continue # room is full; this peer stays unseated
		slots[free] = {"kind": SeatKind.HUMAN, "peer": peer, "ready": false}


func _apply_slots(new_slots: Array) -> void:
	# Copy before clearing. Arrays are passed by reference, and a table arriving over
	# the wire can be the very array we hand back — clearing first would wipe the
	# very table we are trying to install, leaving every peer seated on nothing.
	var incoming: Array = new_slots.duplicate(true)
	slots.clear()
	for entry in incoming:
		slots.append(entry)


func _broadcast_table() -> void:
	# The owner is the only writer, so its own copy is already correct and rpc()
	# only has to cover everybody else. The public flag rides along: a joiner never
	# created the room, so it has no other way to learn that the room it entered is a
	# public one and should not be shown a code.
	_table_received.rpc(slots, public_room)
	seats_changed.emit()


## Only the table's owner may publish one. The guard is written by hand rather than
## using `@rpc("authority")` because the owner is peer 1 on ENet but an elected peer
## on the relay, where peer 1 is a phantom that never runs this code.
@rpc("any_peer", "reliable")
func _table_received(new_slots: Array, is_public: bool) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	# Trust any sender below our current owner. The owner is by definition the lowest
	# real peer, so a table arriving from lower down means we had the wrong one — which
	# is what an incomplete first view of the roster produces. Two peers that each
	# think they host therefore converge on the lower, and the higher one stops
	# publishing at its next refresh. It also means a match that already has an owner
	# cannot be taken over by a later arrival, since a later arrival has a higher id.
	if sender > SERVER_ID and (_table_owner == 0 or sender < _table_owner):
		_table_owner = sender
	if sender != _table_owner:
		return
	# The owner's word on the room's visibility, so a joiner shows the same thing the
	# host does instead of guessing from its own (false) default.
	public_room = is_public
	_apply_slots(new_slots)
	seats_changed.emit()


# --- Prêt, chat et IA ----------------------------------------------------------

## Whether the round may begin: two cards or more, and every one of them ready. An
## AI card counts as ready — it is not a person who has to agree to anything.
func all_ready() -> bool:
	var occupied: Array[int] = occupied_seats()
	if occupied.size() < MIN_PLAYERS:
		return false
	for seat in occupied:
		var slot: Dictionary = slots[seat]
		if int(slot["kind"]) == SeatKind.AI:
			continue
		if not bool(slot["ready"]):
			return false
	return true


## Whether this peer has marked itself ready.
func is_local_ready() -> bool:
	var seat: int = seat_of_peer(multiplayer.get_unique_id())
	if seat < 0:
		return false
	return bool(slots[seat]["ready"])


## Marks this peer ready or not, starting the round if that was the last one.
func set_ready(value: bool) -> void:
	var seat: int = seat_of_peer(multiplayer.get_unique_id())
	if seat < 0:
		return
	if is_host():
		_apply_ready(seat, value)
		return
	# Clients ask the owner instead of writing the table themselves: one writer means
	# the table cannot disagree with itself.
	_ready_request.rpc_id(_table_owner, value)


@rpc("any_peer", "reliable")
func _ready_request(value: bool) -> void:
	if not is_host():
		return
	var seat: int = seat_of_peer(multiplayer.get_remote_sender_id())
	if seat < 0:
		return
	_apply_ready(seat, value)


func _apply_ready(seat: int, value: bool) -> void:
	if int(slots[seat]["kind"]) != SeatKind.HUMAN:
		return
	slots[seat]["ready"] = value
	_broadcast_table()
	# The owner is the one who starts, so the all-ready check lives here rather than
	# on every peer reacting to the table.
	start_game()


## Fills or empties a card with an AI. The host's call, because the host is the one
## everyone else has agreed owns the table.
func toggle_ai(seat: int) -> void:
	if not is_host() or seat < 0 or seat >= slots.size():
		return
	if int(slots[seat]["kind"]) == SeatKind.HUMAN:
		return
	slots[seat] = _empty_slot() if is_seat_ai(seat) \
		else {"kind": SeatKind.AI, "peer": 0, "ready": true}
	_broadcast_table()
	start_game()


## Sends a line of chat to everyone in the waiting room.
func send_chat(text: String) -> void:
	var line: String = text.strip_edges()
	if line.is_empty():
		return
	_chat_received.rpc(line)


## `call_local` so the speaker sees their own line in the log without special-casing
## it, and the sender is read from the RPC rather than passed in, so nobody can put
## words in another seat's mouth.
@rpc("any_peer", "call_local", "reliable")
func _chat_received(text: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id() # a local call has no remote sender
	chat_line.emit(seat_of_peer(sender), text, sender == multiplayer.get_unique_id())


@rpc("any_peer", "reliable")
func _begin_received() -> void:
	if multiplayer.get_remote_sender_id() != _table_owner:
		return
	_begin()


func _begin() -> void:
	started = true
	game_started.emit()
