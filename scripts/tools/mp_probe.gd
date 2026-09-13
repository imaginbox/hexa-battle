extends Node
## Verification tool: opens or joins a match over either transport, then reports the
## seating it was given and the board that seating produces. Not part of the game.
##
## Run two of these headlessly to prove a transport end to end without needing two
## screens — the lobby does exactly this, but this prints what it got instead of
## drawing it.
##
##     # Online relay: both peers just join the same room.
##     HEXA_TRANSPORT=relay HEXA_ROOM=mon-test godot --headless --path <projet> res://scenes/tools/mp_probe.tscn
##
##     # Local ENet: one hosts, one joins.
##     HEXA_TRANSPORT=enet HEXA_MODE=host godot --headless --path <projet> res://scenes/tools/mp_probe.tscn
##     HEXA_TRANSPORT=enet HEXA_MODE=join HEXA_ADDR=127.0.0.1 godot --headless --path <projet> res://scenes/tools/mp_probe.tscn
##
## HEXA_TRANSPORT picks relay (default) or enet, HEXA_MODE host or join (ENet only),
## HEXA_ADDR the ENet address to dial and HEXA_ROOM the relay room to enter.

## How long to let the match settle before the final report, and how often the
## seating is polled while it does. A join is asynchronous, and watching the peer
## list evolve is the whole point — a single end-state snapshot cannot tell
## "never arrived" from "arrived and was thrown away".
##
## Overridable with HEXA_SETTLE so two probes can be given different lifetimes:
## launch one short and one long and the short one reports while the long one is
## still connected.
const SETTLE_DEFAULT := 14.0
const POLL_SECONDS := 1.0

var _elapsed: float = 0.0
var _next_poll: float = 0.0
var _reported: bool = false
var _settle_seconds: float = SETTLE_DEFAULT
## Set by HEXA_START: mark ready once the table is playable. Harmless on a peer that
## turns out not to own the table, since readiness is routed to the owner.
var _auto_start: bool = false
## Set by HEXA_FILL_AI on the host: put an AI on every card still empty.
var _fill_ai: bool = false
var _started_round: bool = false
var _filled: bool = false
var _said_hello: bool = false

## Set by HEXA_SYNC_TEST: after the board is up, the host plays one action and both
## peers print a fingerprint of their board, so the two can be compared line for line.
var _sync_test: bool = false
var _board: Node3D = null
var _board_grid: GameGrid = null
var _reported_at: float = 0.0
var _acted: bool = false
var _sync_done: bool = false
## How long to stay alive after the fingerprint, set by HEXA_HOLD. The host needs a
## few seconds on it, or it hangs up before the client has had its say.
var _hold: float = 0.0
var _sync_quit_at: float = 0.0


## How long to wait before starting the round, so the joiner is seated first.
const AUTO_START_AT := 4.0
## How long after the board is up the host plays, and how long after that both peers
## report. The gap has to cover a network round-trip plus the pawn's flight.
const SYNC_ACT_AFTER := 2.0
const SYNC_CHECK_AFTER := 6.0


func _on_game_started() -> void:
	print("[probe] t=%5.1f  game_started -> the round is on" % _elapsed)


func _ready() -> void:
	var settle: String = OS.get_environment("HEXA_SETTLE")
	if settle.is_valid_float():
		_settle_seconds = settle.to_float()
	Net.failed.connect(_on_failed)
	Net.seats_changed.connect(_on_seats_changed)
	Net.game_started.connect(_on_game_started)
	Net.chat_line.connect(_on_chat)

	if OS.get_environment("HEXA_TRANSPORT") == "enet":
		Net.select_local_mode()
		if OS.get_environment("HEXA_MODE") == "host":
			print("[probe] hosting ENet on port %d (report after %.0fs)" % [Net.port, _settle_seconds])
			Net.open_match()
		else:
			var addr: String = OS.get_environment("HEXA_ADDR")
			if addr.is_empty():
				addr = Net.DEFAULT_ADDRESS
			print("[probe] joining ENet %s:%d (report after %.0fs)" % [addr, Net.port, _settle_seconds])
			Net.join_match(addr)
	else:
		# The relay has no server of its own, so on that transport hosting and
		# joining are the same act: enter the room and let the lowest peer own it.
		Net.select_online_mode()
		var room: String = OS.get_environment("HEXA_ROOM")
		if not room.is_empty():
			Net.room = room
		print("[probe] joining relay room '%s' (report after %.0fs)" % [Net.room, _settle_seconds])
		Net.open_match()

	if OS.get_environment("HEXA_START") == "1":
		_auto_start = true
	if OS.get_environment("HEXA_FILL_AI") == "1":
		_fill_ai = true
	if OS.get_environment("HEXA_SYNC_TEST") == "1":
		_sync_test = true
	var hold: String = OS.get_environment("HEXA_HOLD")
	if hold.is_valid_float():
		_hold = hold.to_float()


func _on_failed(reason: String) -> void:
	print("[probe] FAILED: %s" % reason)


## A one-line picture of the table: each card's kind and ready flag.
func _slots_text() -> String:
	var parts: Array[String] = []
	for i in Net.slots.size():
		var slot: Dictionary = Net.slots[i]
		var kind: String = ["vide", "humain", "IA"][int(slot["kind"])]
		parts.append("%d:%s%s" % [i, kind, " PRÊT" if bool(slot["ready"]) else ""])
	return " | ".join(parts)


func _on_seats_changed() -> void:
	print("[probe] t=%5.1f  table -> %s  is_host=%s" % [
		_elapsed, _slots_text(), str(Net.is_host())])


func _on_chat(seat: int, text: String, mine: bool) -> void:
	print("[probe] t=%5.1f  CHAT siege %d%s : %s" % [
		_elapsed, seat, " (moi)" if mine else "", text])


func _process(delta: float) -> void:
	_elapsed += delta
	# Fill any empty card with an AI, shortly before readiness, so the AI path is
	# exercised alongside the human one.
	if _fill_ai and not _filled and _elapsed >= AUTO_START_AT - 1.5:
		_filled = true
		for seat in Net.slots.size():
			if Net.is_seat_empty(seat):
				print("[probe] t=%5.1f  carte %d remplie par une IA" % [_elapsed, seat])
				Net.toggle_ai(seat)
	# Say something, so the chat round-trip is tested and not just declared.
	if not _said_hello and _elapsed >= 1.5:
		_said_hello = true
		Net.send_chat("bonjour du pair %d" % multiplayer.get_unique_id())
	# Mark ready: this is the real start trigger now, so the probe walks the actual
	# flow rather than forcing the round open.
	if _auto_start and not _started_round and _elapsed >= AUTO_START_AT:
		_started_round = true
		print("[probe] t=%5.1f  je me marque PRÊT (cartes occupées : %d)" % [
			_elapsed, Net.active_count()])
		Net.set_ready(true)
	if _elapsed >= _next_poll:
		_next_poll += POLL_SECONDS
		print("[probe] t=%5.1f  id=%d peers=%s  %s  is_host=%s" % [
			_elapsed, multiplayer.get_unique_id(),
			str(multiplayer.get_peers()), _slots_text(), str(Net.is_host())])
	if not _reported:
		# The wait lives inside the branch rather than in front of it: a guard that
		# returns once we have reported would make every phase below unreachable and the
		# probe would never quit.
		if _elapsed < _settle_seconds:
			return
		_reported = true
		_reported_at = _elapsed
		_report_seating()
		_report_board()
		if not _sync_test:
			get_tree().quit()
	# The host plays one move, then both peers describe their board. Two fingerprints
	# that disagree mean the action never travelled, or the boards drifted apart.
	if not _sync_test:
		return
	if not _sync_done:
		if Net.is_host() and not _acted and _elapsed >= _reported_at + SYNC_ACT_AFTER:
			_acted = true
			_play_sync_action()
		if _elapsed >= _reported_at + SYNC_CHECK_AFTER:
			_sync_done = true
			_sync_quit_at = _elapsed + _hold
			print("[probe] t=%5.1f  EMPREINTE APRÈS  %s" % [_elapsed, _fingerprint()])
		return
	if _hold <= 0.0 or _elapsed >= _sync_quit_at:
		get_tree().quit()


## Plays one move as the host, so the client has something it has to agree with. The
## castle has ~25 troops and the neutral tiles 10, so the march takes one of them.
func _play_sync_action() -> void:
	if _board_grid == null:
		print("[probe] pas de plateau — action impossible")
		return
	var from: HexTile = null
	for coord in _board_grid.tiles:
		var tile: HexTile = _board_grid.tiles[coord]
		if tile.owner_seat == GameState.local_seat:
			from = tile
			break
	if from == null:
		print("[probe] aucune case à moi")
		return
	var targets: Array[HexTile] = _board_grid.targets_for(from)
	if targets.is_empty():
		print("[probe] aucune cible en portée")
		return
	print("[probe] t=%5.1f  ACTION  %s -> %s" % [
		_elapsed, str(from.grid_coords), str(targets[0].grid_coords)])
	_board_grid.execute_march(from, targets[0])


## A fingerprint of the board, so two peers can be compared at a glance: per-card tile
## and troop totals, plus a checksum folded over every tile's *structure*.
##
## Troops are left out of the checksum on purpose. Production runs on every peer, so
## between two of the owner's corrections the counts legitimately differ by a trooper
## or two; what must match to the digit is who owns what and what is standing on it.
func _fingerprint() -> String:
	if _board_grid == null:
		return "(pas de plateau)"
	var counts: Dictionary = {}
	var troops: Dictionary = {}
	var checksum: int = 0
	for coord in _board_grid.tiles:
		var tile: HexTile = _board_grid.tiles[coord]
		checksum += (tile.owner_seat + 2) * 7 + tile.tile_type * 17 \
			+ tile.unit_type * 19 + int(coord.x) * 23 + int(coord.y) * 29
		if tile.owner_seat != HexTile.NEUTRAL:
			counts[tile.owner_seat] = int(counts.get(tile.owner_seat, 0)) + 1
			troops[tile.owner_seat] = int(troops.get(tile.owner_seat, 0)) + tile.troop_count
	var parts: Array[String] = []
	for seat in [0, 1, 2, 3]:
		if counts.has(seat):
			parts.append("s%d %d cases / %d troupes" % [seat, counts[seat], troops[seat]])
	return "%s   structure=%d" % [" | ".join(parts), checksum]


func _report_seating() -> void:
	print("[probe] connected=%s  my_peer_id=%d  peers=%s" % [
		Net.connected, multiplayer.get_unique_id(), str(multiplayer.get_peers())])
	print("[probe] occupied=%s  (%d cartes)  local_seat=%d  is_host=%s  tout prêt=%s" % [
		str(Net.occupied_seats()), Net.active_count(), Net.local_seat(),
		str(Net.is_host()), str(Net.all_ready())])
	print("[probe] GameState: in_room=%s occupied=%s ai=%s local_seat=%d radius=%d" % [
		GameState.in_room, str(GameState.occupied_seats), str(GameState.ai_seats),
		GameState.local_seat, GameState.table_radius])


## Builds the real board from that seating, exactly as the lobby would on start,
## and lists the castles it came up with.
func _report_board() -> void:
	var board: Node = load("res://scenes/main.tscn").instantiate()
	add_child(board)
	_board = board
	var grid: GameGrid = board.get_node("GameGrid")
	_board_grid = grid
	var castles: Array = []
	for coord in grid.tiles:
		var tile = grid.tiles[coord]
		if tile.tile_type == HexTile.TileType.FORTRESS_BOSS:
			castles.append(tile)
	castles.sort_custom(func(a, b): return a.owner_seat < b.owner_seat)
	print("[probe] board radius=%d tiles=%d castles=%d" % [
		grid.grid_radius, grid.tiles.size(), castles.size()])
	for tile in castles:
		print("[probe]    seat %d @ axial %-9s #%s  %s" % [
			tile.owner_seat, str(tile.grid_coords),
			GameState.seat_color(tile.owner_seat).to_html(false),
			"(MOI)" if tile.owner_seat == GameState.local_seat else ""])
	print("[probe] t=%5.1f  EMPREINTE AVANT  %s" % [_elapsed, _fingerprint()])
