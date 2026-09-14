class_name GameGrid
extends Node3D
## Hex battlefield laid out in axial coordinates (q, r).
##
## About [member hex_size]: the axial formula below is expressed in units of a
## tile's circumradius, while the export is documented as the distance between
## adjacent tile centres. Those differ by a factor of sqrt(3), so the radius is
## derived from hex_size and each tile's mesh is scaled to that radius — without
## it the meshes (radius 1.0) would be spaced for radius 1.8 and the board would
## be full of gaps between tiles.

signal boss_battle_triggered(attacker: HexTile, defender: HexTile)
## A player tile was clicked (not dragged): the HUD offers build / recruit actions.
signal tile_context_requested(tile: HexTile)
## A castle came down. Whoever was sitting on that seat has lost the round.
signal castle_fell(owner_seat: int)

@export var hex_scene: PackedScene
@export var grid_radius: int = 3 # Rayon de la carte
@export var hex_size: float = 1.8 # Distance entre centres
## Scales each tile slightly below its cell. Below 1.0 it leaves a seam between
## neighbouring hexes, so the board reads as separate pieces instead of one slab.
@export_range(0.8, 1.0, 0.01) var tile_shrink: float = 0.95
## The piece that flies from tile to tile when troops march.
@export var pawn_scene: PackedScene
## Size of that piece, relative to a tile's radius.
@export_range(0.1, 1.5, 0.05) var pawn_scale: float = 0.7
## Starting garrison of the enemy fortress. MainLoop raises it with each stage.
@export var boss_troops: int = 80
## Whether infantry also joins the automatic fire. Off by default: an infantry
## "attack" is a march that sends half the garrison and takes the ground, so
## leaving it out keeps movement a manual decision. Tick it to let a whole army
## fight on its own — see the HUD's "TIR" button, which arms the mode itself.
@export var auto_attack_infantry: bool = false
## Minimum seconds between two moves on the board, whoever makes them.
##
## Every move the board can take — a drag of yours, an automatic shot, the AI's turn —
## goes through [method execute_march], so one gap here paces all of them together.
##
## Without it a wide board fires from every card at once, and the opponent's moves land on
## top of each other: with automatic fire on, every ranged tile of yours opens up in the
## same frame, and a levelled-up AI comes at you as fast as one move every 0.75 s. Pacing
## turns that back into something you can watch happen.
@export_range(0.0, 3.0, 0.05) var move_cooldown: float = 0.7

## How much a hovered target grows under the cursor while aiming.
const HOVER_GROWTH := 1.08

## Structure hit points. A castle has to be ground down before it falls, and a
## mine is a much smaller thing to break. The castle also gets tougher with every
## AI level, so a sharper opponent is a better fortified one.
const CASTLE_HP := 260
const CASTLE_HP_PER_LEVEL := 40
const MINE_HP := 120

# --- Combat: what each class throws, and what it does on impact ---------------

## Damage per troop committed, by class, for a ranged hit: a 30-strong archer
## company lands 15, a 50-strong catapult crew 25. The share of that a fortified
## tile absorbs from anything other than a siege engine:
const DAMAGE_PER_TROOP := {
	HexTile.UnitType.ARCHER: 0.5,
	HexTile.UnitType.CATAPULT: 0.5,
}
const FORTIFIED_DAMAGE_SCALE := 0.1

## Automatic-attack cadence, in seconds, per class. A bigger garrison fires
## faster: the interval is scaled by REFERENCE_TROOPS / troops, within these
## bounds.
const ATTACK_INTERVAL := {
	HexTile.UnitType.SOLDIER: 2.0,
	HexTile.UnitType.ARCHER: 1.5,
	HexTile.UnitType.CATAPULT: 3.0,
}
const REFERENCE_TROOPS := 20.0
const FASTEST_INTERVAL_FACTOR := 0.35
const SLOWEST_INTERVAL_FACTOR := 2.0

## Where a piece flies from and to, above the tile face.
const PIECE_LIFT := 0.8
## Arc height and flight time of each class's shot. The archer is a fast flat
## volley; the catapult is a slow, very arched lob.
const SOLDIER_ARC := 2.0
const SOLDIER_FLIGHT := 0.4
const ARCHER_ARC := 0.9
const ARCHER_FLIGHT := 0.18
const CATAPULT_ARC := 3.4
const CATAPULT_FLIGHT := 0.55
## Size of the thrown piece, relative to a pawn.
const SOLDIER_RELATIVE_SIZE := 1.0
const ARCHER_RELATIVE_SIZE := 0.3
const CATAPULT_RELATIVE_SIZE := 0.7

# --- Économie ----------------------------------------------------------------

## Coût d'une mine, payable en or ou en troupes.
const MINE_GOLD_COST := 50
const MINE_TROOP_COST := 30
## Coût de formation d'une classe d'unité.
const ARCHER_COST := 40
const CATAPULT_COST := 60
## Production d'une mine par palier, et ce que coûte chaque montée. Une mine de
## tier 3 rapporte trois fois ce qu'elle coûterait à défendre.
const MINE_RATES := [2.0, 4.0, 6.0]
const MINE_UPGRADE_COSTS := [80, 140]
## Renfort d'urgence : des troupes tout de suite, contre de l'or.
const RENFORT_COST := 60
const RENFORT_TROOPS := 15

# --- Synchronisation d'une partie ---------------------------------------------

## How many integers one tile occupies in a board snapshot: its coordinates, owner,
## garrison, kind, unit class, structure hit points, mine tier and structure ceiling.
const SNAPSHOT_STRIDE := 9
## How often the table's owner republishes the whole board, in seconds.
##
## Production runs on every peer so the numbers stay alive between syncs; this is what
## keeps them honest. A 91-tile board is under 3 Ko, so it costs a few Ko a second —
## cheap enough to be worth it as a blunt safety net. Everything that could go wrong
## settles here within half a second, without any of it needing its own handshake: a
## lost action, a peer that drifted on troop production, a client that joined the
## board a frame late.
const SYNC_INTERVAL := 0.5

var tiles: Dictionary = {}
var selected_tile: HexTile = null
## Tile currently under the cursor, tracked through the tiles' hover signals.
var hovered_tile: HexTile = null

## The aiming ribbon. A child of this node, so it shares the board's coordinates.
@onready var target_arrow: TargetArrow = $TargetArrow

## Distance from a tile centre to its vertices, derived from hex_size.
var _tile_radius: float = 1.0

## Seconds left before the owner republishes the board. Seeded to one full interval so
## the very first broadcast waits for the joiners to have their board up, rather than
## firing into a scene that is still loading.
var _sync_left: float = 0.5
## Peers that have opened their board and asked for one. The owner pushes snapshots
## only to these: a reliable RPC aimed at a GameGrid that does not exist yet is
## dropped with a "node not found", so shipping to a peer before it has said it is
## ready is not just wasteful, it is an error.
var _board_ready_peers: Dictionary = {}
## Set while an action that came off the wire is being applied, so the guarded public
## methods do not try to forward it back to the owner it just came from.
var _applying_remote: bool = false
## Set when this player is out of the match — eliminated, or the match already ruled on.
## Their clicks do nothing after that: an eliminated player may still be holding tiles
## elsewhere on the board, and being out has to mean out.
var input_locked: bool = false
## Seconds left before another move is allowed.
var _cooldown_left: float = 0.0


func _ready() -> void:
	generate_grid()
	# Ask the owner for the board the moment ours exists. The owner republishes on a
	# timer, so a peer whose scene came up between two ticks would otherwise sit on a
	# freshly generated board until the next one — and a broadcast that arrived during
	# the gap was aimed at a node that did not exist yet, which Godot answers with a
	# "node not found" and drops. The request makes that window impossible.
	if GameState.in_room and not GameState.is_authority:
		var owner_id: int = GameState.table_owner_id
		if owner_id > 0:
			_request_snapshot.rpc_id(owner_id)


func _process(delta: float) -> void:
	_cooldown_left = maxf(_cooldown_left - delta, 0.0)
	_run_board_sync(delta)
	if GameState.auto_attack:
		_run_auto_attacks(delta)
	if selected_tile == null or not target_arrow.is_active:
		return
	# A move that cannot land yet should say so rather than look broken.
	target_arrow.set_ready(can_move())
	# The ribbon only locks on to a tile the selected unit can actually reach;
	# on anything else it just follows the cursor.
	if hovered_tile != null and is_valid_target(selected_tile, hovered_tile):
		target_arrow.update_aim(hovered_tile.position)
		return
	# Nothing lockable under the cursor: follow it across the ground plane.
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
		return
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var ray_origin: Vector3 = camera.project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = camera.project_ray_normal(mouse_pos)
	var hit: Variant = Plane(Vector3.UP, 0.0).intersects_ray(ray_origin, ray_dir)
	if hit is Vector3:
		target_arrow.update_aim(hit)


# --- Attaques automatiques ----------------------------------------------------

## In automatic mode a player's ranged tiles fire on their own the moment
## something comes into range, on their own countdown. Nothing else is automated:
## infantry is skipped deliberately — its only action is a march, which takes
## ground, and moving your army stays a manual decision. Dragging keeps working
## for every class regardless.
func _run_auto_attacks(delta: float) -> void:
	# One move at a time for the whole board. Without this every ranged card of yours
	# opens up in the same frame, which is the firing-from-everywhere this pacing exists
	# to stop. The cards' own countdowns keep running while the board is busy, so nothing
	# is lost — it is only spread out.
	if not can_move():
		return
	for tile: HexTile in tiles.values():
		if tile.owner_seat != GameState.local_seat:
			continue
		# Infantry only takes part if the grid has been told to include it; its
		# action moves the army, which is the one thing this mode should not do.
		if not auto_attack_infantry and not is_ranged(tile):
			continue
		tile.auto_attack_timer -= delta
		if tile.auto_attack_timer > 0.0:
			continue
		var target: HexTile = best_target_for(tile)
		if target == null:
			continue
		tile.auto_attack_timer = attack_interval(tile)
		execute_march(tile, target)


## Whether a class shoots from a distance. Infantry is the one that does not.
func is_ranged(tile: HexTile) -> bool:
	return tile.unit_type != HexTile.UnitType.SOLDIER


## What a tile shoots at on its own: never its own side, the weakest thing in
## range first, and for a catapult a fortified structure above all — that is what
## a siege engine is for.
func best_target_for(from_tile: HexTile) -> HexTile:
	var best: HexTile = null
	var best_score: int = 1 << 30
	for tile: HexTile in tiles.values():
		if tile.owner_seat == from_tile.owner_seat:
			continue
		if not is_valid_target(from_tile, tile):
			continue
		var score: int = tile.troop_count
		if from_tile.unit_type == HexTile.UnitType.CATAPULT and tile.is_fortified():
			score -= 1000
		if score < best_score:
			best_score = score
			best = tile
	return best


## Seconds between two automatic shots: the class's base interval, shortened by
## the size of the garrison doing the firing.
func attack_interval(tile: HexTile) -> float:
	var base: float = float(ATTACK_INTERVAL.get(tile.unit_type, 2.0))
	var factor: float = clampf(REFERENCE_TROOPS / maxf(float(tile.troop_count), 1.0),
		FASTEST_INTERVAL_FACTOR, SLOWEST_INTERVAL_FACTOR)
	return base * factor


## Clears the board and builds a fresh map. Safe to call repeatedly: the stage
## loop rebuilds the whole grid every time a fortress falls.
func generate_grid() -> void:
	_clear_tiles()
	# A room sizes the board from its head count — more players need more ground
	# to spread into. Solo leaves grid_radius to MainLoop's level loop.
	if GameState.in_room:
		grid_radius = GameState.table_radius
	_tile_radius = hex_size / sqrt(3.0)
	for q in range(-grid_radius, grid_radius + 1):
		var r1: int = maxi(-grid_radius, -q - grid_radius)
		var r2: int = mini(grid_radius, -q + grid_radius)
		for r in range(r1, r2 + 1):
			spawn_tile(q, r)

	setup_initial_positions()


## Frees the previous board and forgets it. Without this, a second
## generate_grid() call stacks a whole new set of tiles on top of the old ones:
## the stale tiles stay in the scene, keep processing, keep their input
## connections, and still overlap the new board visually.
func _clear_tiles() -> void:
	for tile: HexTile in tiles.values():
		tile.queue_free()
	tiles.clear()
	selected_tile = null
	hovered_tile = null
	target_arrow.stop_aiming()


func spawn_tile(q: int, r: int) -> void:
	var tile: HexTile = hex_scene.instantiate()
	tile.scale = Vector3.ONE * _tile_radius * tile_shrink
	add_child(tile)

	# Conversion coordonnées axiales (q, r) en coordonnées monde 3D
	var x: float = _tile_radius * (sqrt(3.0) * q + sqrt(3.0) / 2.0 * r)
	var z: float = _tile_radius * (3.0 / 2.0 * r)
	tile.position = Vector3(x, 0, z)
	tile.grid_coords = Vector2i(q, r)

	tile.input_event.connect(_on_tile_input.bind(tile))
	tile.mouse_entered.connect(_on_tile_hover_entered.bind(tile))
	tile.mouse_exited.connect(_on_tile_hover_exited.bind(tile))
	tiles[Vector2i(q, r)] = tile


func _on_tile_hover_entered(tile: HexTile) -> void:
	hovered_tile = tile
	if selected_tile == null or selected_tile == tile:
		return
	# Micro-agrandissement de confirmation d'accrochage
	var tween := create_tween()
	tween.tween_property(tile, "scale", tile.base_scale * HOVER_GROWTH, 0.1)


func _on_tile_hover_exited(tile: HexTile) -> void:
	if hovered_tile == tile:
		hovered_tile = null
	var tween := create_tween()
	tween.tween_property(tile, "scale", tile.base_scale, 0.1)


## Starting garrison of a player's castle.
const START_TROOPS := 25
## How much bigger the AI's keep sits than a plain tile, so the objective reads
## from across the board.
const FORTRESS_SCALE := 1.3
## The seat the AI commands in solo. Seat 0 is always the human, so the AI takes
## the first seat after them — which in the table palette is also the red one.
const AI_SEAT := 1


## Corner of the board that `seat` starts in, in axial coordinates, for a board of
## the given radius.
##
## These are the four diagonal points of the hexagon rather than its east and west
## tips, so even a two-player duel starts the opponents as far apart as the map
## allows. The order matches [constant Net.CORNER_NAMES] exactly — that list is
## what the lobby shows, and this is where it lands — and because both are derived
## from the seat index alone, every peer builds the same table with nothing
## negotiated over the network.
func corner_coords(seat: int, radius: int) -> Vector2i:
	match seat % 4:
		1:
			return Vector2i(radius, -radius) # Nord-Est
		2:
			return Vector2i(0, radius) # Sud-Est
		3:
			return Vector2i(0, -radius) # Nord-Ouest
		_:
			return Vector2i(-radius, radius) # Sud-Ouest


func setup_initial_positions() -> void:
	# A room seats every player in their own corner at equal strength. Solo keeps
	# the original west-versus-east duel, where the AI's keep can be grown.
	if GameState.in_room:
		for seat in GameState.occupied_seats:
			_arm_castle(tiles.get(corner_coords(seat, grid_radius)), seat,
				START_TROOPS, CASTLE_HP, false)
		return

	_arm_castle(tiles.get(Vector2i(-grid_radius, 0)), GameState.local_seat,
		START_TROOPS, castle_hp(), false)
	_arm_castle(tiles.get(Vector2i(grid_radius, 0)), AI_SEAT,
		boss_troops, castle_hp(), true)


## Turns a plain tile into a seat's castle: theirs, fortified, and garrisoned.
##
## The owner is assigned before the tile type on purpose — the owner setter
## redraws the tile, and it should already know it is a fortress by then, so the
## type is applied first and the visuals refreshed once at the end.
func _arm_castle(tile: HexTile, seat: int, troops: int, hp: int, enlarge: bool) -> void:
	if tile == null:
		return
	tile.tile_type = HexTile.TileType.FORTRESS_BOSS
	tile.owner_seat = seat
	tile.troop_count = troops
	if enlarge:
		tile.scale *= FORTRESS_SCALE # Bâtiment plus imposant
	tile.arm_structure(hp)
	tile.update_visuals()


## Hit points of a castle at the current AI level: a sharper opponent also holds
## out longer.
func castle_hp() -> int:
	return CASTLE_HP + CASTLE_HP_PER_LEVEL * (GameState.ai_level - 1)


## Distance from the board centre out to the outer edge of the furthest tile.
## MainLoop's camera framing uses it, so any board size stays in frame without
## hand-tuning the camera per level.
func board_radius() -> float:
	var furthest := 0.0
	for tile: HexTile in tiles.values():
		furthest = maxf(furthest, tile.position.length())
	return furthest + _tile_radius


func _on_tile_input(_camera: Camera3D, event: InputEvent, _pos: Vector3, _normal: Vector3, _shape_idx: int, tile: HexTile) -> void:
	if input_locked:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			# A tile down to its last troop has nothing to send, so it cannot
			# start an action.
			if tile.owner_seat == GameState.local_seat and tile.troop_count > 1:
				selected_tile = tile
				tile.trigger_bounce_effect()
				target_arrow.start_aiming(tile.position)
		else:
			# Relâchement du clic / du doigt
			target_arrow.stop_aiming()
			if selected_tile:
				var origin: HexTile = selected_tile
				selected_tile = null
				if tile == origin:
					# Let go back on the tile it started from: that is a plain
					# click, so offer the build / recruit actions instead.
					tile_context_requested.emit(origin)
				elif is_valid_target(origin, tile):
					execute_march(origin, tile)
				if hovered_tile:
					hovered_tile.scale = hovered_tile.base_scale


# --- Portée et ciblage --------------------------------------------------------

## Axial (hex) distance between two grid coordinates: how many steps a piece has
## to walk to get from one tile to the other. The three-term sum is always even,
## so the halving is exact.
func axial_distance(a: Vector2i, b: Vector2i) -> int:
	var dq: int = a.x - b.x
	var dr: int = a.y - b.y
	return int((absi(dq) + absi(dr) + absi(dq + dr)) / 2.0)


## Effective attack range of a tile as (min, max) hexes: the class's own range
## plus whatever reach levels have been bought. Applied to both sides equally, so
## an upgrade widens the engagement window for everyone rather than only you.
func attack_range(from_tile: HexTile) -> Vector2i:
	var own: Vector2i = HexTile.unit_range(from_tile.unit_type)
	return Vector2i(own.x, own.y + GameState.reach_bonus())


## Whether `from_tile` may act on `to_tile` right now.
func is_valid_target(from_tile: HexTile, to_tile: HexTile) -> bool:
	if from_tile == to_tile:
		return false
	var reach: Vector2i = attack_range(from_tile)
	var distance: int = axial_distance(from_tile.grid_coords, to_tile.grid_coords)
	if distance < reach.x or distance > reach.y:
		return false
	# A mine can only be cracked by a siege engine.
	if to_tile.tile_type == HexTile.TileType.MINE and from_tile.unit_type != HexTile.UnitType.CATAPULT:
		return false
	return true


## Every tile the given tile could act on right now.
func targets_for(from_tile: HexTile) -> Array[HexTile]:
	var reach: Vector2i = attack_range(from_tile)
	var found: Array[HexTile] = []
	for tile: HexTile in tiles.values():
		var distance: int = axial_distance(from_tile.grid_coords, tile.grid_coords)
		if tile != from_tile and distance >= reach.x and distance <= reach.y:
			found.append(tile)
	return found


# --- Économie ----------------------------------------------------------------

## Construit une mine sur une de tes cases sans bâtiment, payée en or ou en troupes.
func build_mine(tile: HexTile, pay_with_troops: bool = false) -> bool:
	if tile == null or tile.owner_seat != GameState.local_seat:
		return false
	if tile.tile_type != HexTile.TileType.REGULAR:
		return false
	if pay_with_troops:
		if tile.troop_count < MINE_TROOP_COST:
			return false
	elif not GameState.spend_gold(MINE_GOLD_COST):
		return false
	if not _route("build_mine", {"tile": tile.grid_coords, "troops": pay_with_troops}):
		return true
	_apply_build_mine(tile, pay_with_troops)
	return true


## The shared half of building a mine: the building itself. Gold is spent by whoever
## pays and never travels — it is a per-player purse — but troops are shared state, so
## that half of the price is charged here, where every peer will agree on it.
func _apply_build_mine(tile: HexTile, paid_in_troops: bool) -> void:
	if paid_in_troops:
		tile.troop_count -= MINE_TROOP_COST
	tile.build_mine()
	tile.mine_level = 1
	tile.gold_per_second = MINE_RATES[0]
	tile.arm_structure(MINE_HP)


## Reforme la garnison d'une case en une autre classe d'unité, contre de l'or.
func recruit(tile: HexTile, type: HexTile.UnitType) -> bool:
	if tile == null or tile.owner_seat != GameState.local_seat:
		return false
	if type == tile.unit_type:
		return false
	if type != HexTile.UnitType.SOLDIER:
		var cost: int = ARCHER_COST if type == HexTile.UnitType.ARCHER else CATAPULT_COST
		if not GameState.spend_gold(cost):
			return false
	if not _route("recruit", {"tile": tile.grid_coords, "unit": type}):
		return true
	_apply_recruit(tile, type)
	return true


func _apply_recruit(tile: HexTile, type: int) -> void:
	tile.unit_type = type as HexTile.UnitType
	# Without this the badge and the label keep showing the old class: the recruit
	# works, but nothing on the board would say so.
	tile.update_visuals()
	tile.trigger_bounce_effect()


## Monte la mine d'un palier : elle rapporte plus, contre de l'or.
func upgrade_mine(tile: HexTile) -> bool:
	if tile == null or tile.owner_seat != GameState.local_seat:
		return false
	if tile.tile_type != HexTile.TileType.MINE or tile.mine_level >= MINE_RATES.size():
		return false
	if not GameState.spend_gold(MINE_UPGRADE_COSTS[tile.mine_level - 1]):
		return false
	if not _route("upgrade_mine", {"tile": tile.grid_coords}):
		return true
	_apply_upgrade_mine(tile)
	return true


func _apply_upgrade_mine(tile: HexTile) -> void:
	tile.mine_level = mini(tile.mine_level + 1, MINE_RATES.size())
	tile.gold_per_second = MINE_RATES[tile.mine_level - 1]
	tile.trigger_bounce_effect()


## Renfort d'urgence : des troupes tout de suite, contre de l'or.
func reinforce(tile: HexTile) -> bool:
	if tile == null or tile.owner_seat != GameState.local_seat:
		return false
	if tile.troop_count >= tile.max_troops:
		return false
	if not GameState.spend_gold(RENFORT_COST):
		return false
	if not _route("reinforce", {"tile": tile.grid_coords}):
		return true
	_apply_reinforce(tile)
	return true


func _apply_reinforce(tile: HexTile) -> void:
	tile.add_troops(RENFORT_TROOPS)
	tile.trigger_bounce_effect()


# --- Résolution des actions ---------------------------------------------------

func execute_march(from: HexTile, to: HexTile) -> void:
	# Enforced here rather than left to the call sites: every attacker, the AI
	# included, comes through this one door, so nothing can out-range the rules — and
	# nothing can skip the pace either.
	if not is_valid_target(from, to):
		return
	if not can_move():
		return
	if not _route("march", {"from": from.grid_coords, "to": to.grid_coords}):
		return
	_play_march(from, to)


## Whether the board is ready for another move.
func can_move() -> bool:
	return _cooldown_left <= 0.0


## The march itself, split out of [method execute_march] so an action coming back from
## the table's owner runs the very same code a local drag does — pawn flight included.
##
## The pace is set here rather than in [method execute_march] on purpose: this is where a
## move actually happens, whether it was decided locally or arrived from the table's
## owner, so the gap measures the board rather than whoever asked.
func _play_march(from: HexTile, to: HexTile) -> void:
	_cooldown_left = move_cooldown
	match from.unit_type:
		HexTile.UnitType.ARCHER:
			_fire_volley(from, to)
		HexTile.UnitType.CATAPULT:
			_fire_siege_shot(from, to)
		_:
			_assault(from, to)


## Infanterie : marche sur la case et la prend de force. Une forteresse ennemie
## fait démarrer le combat modal au lieu d'un corps-à-corps direct.
func _assault(from: HexTile, to: HexTile) -> void:
	if to.tile_type == HexTile.TileType.FORTRESS_BOSS and to.owner_seat != from.owner_seat:
		# A keep is stormed by the one who reaches it and held by the one sitting on
		# it, so only those two ever see the fight. The action is broadcast to every
		# peer, and without this guard each of them would open its own modal — a
		# spectator in a four-card match would be dragged into a duel that is not
		# theirs, and two modals resolving independently could name two winners.
		if from.owner_seat == GameState.local_seat or to.owner_seat == GameState.local_seat:
			boss_battle_triggered.emit(from, to)
		return
	var send_amount: int = int(from.troop_count / 2.0)
	var side: int = from.owner_seat
	from.troop_count -= send_amount
	from.update_label()
	_launch_piece(from, to, side, SOLDIER_RELATIVE_SIZE, SOLDIER_ARC, SOLDIER_FLIGHT,
		func() -> void:
			resolve_regular_clash(to, side, send_amount)
	)


## Archer : une volée à distance. Elle entame la garnison sans prendre la case,
## donc sans exposer l'archer à une riposte. Les dégâts suivent l'effectif, et
## une structure n'en encaisse que 10 % — c'est apply_ranged_damage qui tranche.
func _fire_volley(from: HexTile, to: HexTile) -> void:
	var damage: int = shot_damage(from)
	var side: int = from.owner_seat
	_launch_piece(from, to, side, ARCHER_RELATIVE_SIZE, ARCHER_ARC, ARCHER_FLIGHT,
		func() -> void:
			apply_ranged_damage(to, damage, side, false)
	)


## Catapulte : le seul engin qui entame vraiment une mine ou une forteresse, et le
## seul qui puisse abattre un château.
func _fire_siege_shot(from: HexTile, to: HexTile) -> void:
	var damage: int = shot_damage(from)
	var side: int = from.owner_seat
	_launch_piece(from, to, side, CATAPULT_RELATIVE_SIZE, CATAPULT_ARC, CATAPULT_FLIGHT,
		func() -> void:
			apply_ranged_damage(to, damage, side, true)
	)


## Dégâts d'un tir à distance : proportionnels au nombre d'unités qui tirent.
func shot_damage(from_tile: HexTile) -> int:
	var per_troop: float = float(DAMAGE_PER_TROOP.get(from_tile.unit_type, 0.5))
	return maxi(1, roundi(float(from_tile.troop_count) * per_troop))


## Dégâts à distance. Sur une case ordinaire ils entament la garnison ; sur une
## structure ils s'attaquent aux murs, et seuls les engins de siège y font
## vraiment mal. Quand les murs tombent, le bâtiment tombe avec eux.
func apply_ranged_damage(target: HexTile, damage: int, side: int, siege: bool) -> void:
	if target.owner_seat == side:
		return
	target.trigger_bounce_effect()

	if not target.is_fortified():
		target.troop_count = maxi(target.troop_count - damage, 0)
		target.update_label()
		return

	var against_walls: int = damage if siege else maxi(1, roundi(float(damage) * FORTIFIED_DAMAGE_SCALE))
	if not target.take_structure_damage(against_walls):
		target.update_label()
		return

	# The building comes down.
	var was_castle: bool = target.tile_type == HexTile.TileType.FORTRESS_BOSS
	var owner_before: int = target.owner_seat
	target.tile_type = HexTile.TileType.REGULAR
	target.structure_hp = 0
	target.structure_max_hp = 0
	if not was_castle:
		# A mine is a small thing: the shot razes it and takes the ground outright.
		target.owner_seat = side
	target.update_visuals()
	target.update_label()
	if was_castle:
		castle_fell.emit(owner_before)


## Envoie une pièce sur un arc de `from` vers `to`, puis exécute `on_impact`.
## Toutes les classes partagent ce trajet : seuls la taille, l'arc et la durée
## changent, ce qui suffit à les distinguer à l'œil.
func _launch_piece(from: HexTile, to: HexTile, side: int, relative_size: float,
		arc: float, duration: float, on_impact: Callable) -> void:
	if pawn_scene == null:
		# No piece assigned: settle the action right away rather than losing it.
		on_impact.call()
		return
	var piece: Node3D = pawn_scene.instantiate()
	piece.scale = Vector3.ONE * _tile_radius * pawn_scale * relative_size
	add_child(piece)
	var start: Vector3 = from.position + Vector3(0, PIECE_LIFT, 0)
	var end: Vector3 = to.position + Vector3(0, PIECE_LIFT, 0)
	piece.position = start
	_tint_pawn(piece, side)

	var mid: Vector3 = (start + end) / 2.0 + Vector3(0, arc, 0)
	var tween := create_tween()
	tween.tween_method(func(t: float) -> void:
		piece.position = start.bezier_interpolate(mid, mid, end, t)
		, 0.0, 1.0, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		# A shot can still be in the air when the board is rebuilt — the level loop does
		# exactly that the moment a keep falls, and it frees every tile on the way. A
		# piece landing on a tile that no longer exists is not an error; it is a shot
		# into a board that has moved on, so it is dropped.
		if is_instance_valid(from) and is_instance_valid(to):
			on_impact.call()
		piece.queue_free()
	)


## Picks up the faction colour on the imported piece. albedo_color multiplies the
## model's own texture, so the piece keeps its detail and just takes the hue.
func _tint_pawn(pawn: Node3D, side: int) -> void:
	var tint: Color = GameState.seat_color(side)
	for found in pawn.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		var source := mesh_instance.get_active_material(0)
		var mat := StandardMaterial3D.new()
		if source is StandardMaterial3D:
			mat = (source as StandardMaterial3D).duplicate() as StandardMaterial3D
		mat.albedo_color = tint
		mesh_instance.material_override = mat


func resolve_regular_clash(target: HexTile, side: int, amount: int) -> void:
	target.trigger_bounce_effect()

	if target.owner_seat == side:
		target.troop_count += amount
	else:
		target.troop_count -= amount
		if target.troop_count < 0:
			var lost_castle: bool = target.tile_type == HexTile.TileType.FORTRESS_BOSS
			var defender: int = target.owner_seat
			target.owner_seat = side
			target.troop_count = abs(target.troop_count)
			target.update_visuals()
			# A castle taken by storm counts as a castle lost, exactly like one
			# battered down by siege — otherwise losing it would go unnoticed.
			if lost_castle:
				castle_fell.emit(defender)
	target.update_label()


# --- Synchronisation d'une partie ----------------------------------------------

## The tile at `coords`, or null when the board has nothing there.
func tile_at(coords: Variant) -> HexTile:
	if typeof(coords) != TYPE_VECTOR2I:
		return null
	return tiles.get(coords)


## The whole board as one flat array, so a peer that has drifted can be put back on
## the same page in a single message.
func snapshot() -> PackedInt32Array:
	var data := PackedInt32Array()
	for coord: Vector2i in tiles:
		var tile: HexTile = tiles[coord]
		data.append(coord.x)
		data.append(coord.y)
		data.append(tile.owner_seat)
		data.append(tile.troop_count)
		data.append(tile.tile_type)
		data.append(tile.unit_type)
		data.append(tile.structure_hp)
		data.append(tile.mine_level)
		# The ceiling travels too, so a peer that joined after a mine was built gets
		# a health bar instead of a structure it cannot see the top of.
		data.append(tile.structure_max_hp)
	return data


## Puts every tile back to the state in `data`. Deliberately silent — no bounce, no
## pawn. This is the correction channel, not the action channel: the animations come
## from the action broadcast, and replaying them here too would double every blow.
func apply_snapshot(data: PackedInt32Array) -> void:
	if data.size() % SNAPSHOT_STRIDE != 0:
		return
	var i: int = 0
	while i < data.size():
		var tile: HexTile = tiles.get(Vector2i(data[i], data[i + 1]))
		if tile != null:
			# owner_seat's setter redraws on its own and troop_count's refreshes the
			# count, so only a class or building change needs the extra pass.
			var look_changed: bool = tile.tile_type != data[i + 4] \
				or tile.unit_type != data[i + 5]
			tile.owner_seat = data[i + 2]
			tile.troop_count = data[i + 3]
			tile.tile_type = data[i + 4] as HexTile.TileType
			tile.unit_type = data[i + 5] as HexTile.UnitType
			tile.mine_level = maxi(data[i + 7], 1)
			# The rate is derived, not stored: a peer that only ever saw the tier in a
			# snapshot must still pay the right gold for it.
			tile.gold_per_second = MINE_RATES[mini(tile.mine_level, MINE_RATES.size()) - 1]
			# The ceiling is adopted as it arrives: a tile that had no structure here
			# but has one in the snapshot needs it before the bar can mean anything.
			tile.structure_max_hp = data[i + 8]
			if tile.structure_max_hp > 0:
				tile.structure_hp = data[i + 6]
			if look_changed:
				tile.update_visuals()
			elif tile.structure_max_hp > 0:
				tile.update_health_bar()
		i += SNAPSHOT_STRIDE


## Republishes the board. Owner only, and the owner's own copy is already the truth,
## so there is nothing to apply on this side. Only peers that have announced their
## board are addressed, so a late joiner is not sent one before its node exists.
func _run_board_sync(delta: float) -> void:
	if not GameState.in_room or not GameState.is_authority:
		return
	_sync_left -= delta
	if _sync_left > 0.0:
		return
	_sync_left = SYNC_INTERVAL
	if _board_ready_peers.is_empty():
		return
	var data: PackedInt32Array = snapshot()
	for peer: int in _board_ready_peers:
		_board_received.rpc_id(peer, data)


@rpc("any_peer", "reliable")
func _board_received(data: PackedInt32Array) -> void:
	if GameState.is_authority:
		return
	apply_snapshot(data)


## A peer that has just opened its board asks for the current one, and the owner notes
## it as a subscriber. Answered only by the owner, whatever the request claims.
@rpc("any_peer", "reliable")
func _request_snapshot() -> void:
	if not GameState.is_authority:
		return
	var peer: int = multiplayer.get_remote_sender_id()
	_board_ready_peers[peer] = true
	_board_received.rpc_id(peer, snapshot())


# --- Acheminement des actions --------------------------------------------------

## Hands an action to the table's owner when this peer is not it, and reports whether
## the caller should go on and apply it here.
##
## Solo, and the owner itself, always get true, so the local path is untouched. Every
## other peer gets false: it runs the action only when the owner's broadcast brings it
## back, which is why everyone sees the same thing at the same moment instead of the
## actor watching it a round-trip early.
func _route(kind: String, fields: Dictionary) -> bool:
	if _applying_remote or not GameState.in_room:
		return true
	var action: Dictionary = fields.duplicate()
	action["kind"] = kind
	action["seat"] = GameState.local_seat
	if GameState.is_authority:
		# The owner decides, and tells the others so their pawns fly at the same moment
		# its own does.
		_action_received.rpc(action)
		return true
	var owner_id: int = GameState.table_owner_id
	if owner_id <= 0:
		return false # no table to ask yet: the click is dropped rather than applied
	_action_request.rpc_id(owner_id, action)
	return false


## An action from another peer, for the owner to decide on. Nothing here trusts the
## sender beyond its card, and the action re-enters the same methods a local click
## reaches, so it can only ever do what a click could have done.
@rpc("any_peer", "reliable")
func _action_request(action: Dictionary) -> void:
	if not GameState.is_authority:
		return
	var seat: int = GameState.seat_of_peer(multiplayer.get_remote_sender_id())
	if seat < 0:
		return
	var kind: String = str(action.get("kind", ""))
	# Taking a keep is the one action that is not about the sender's own tile — the
	# tile being taken belongs to whoever is losing it — so it is the one case that is
	# not checked against the sender's seat. It is also the one a client could lie
	# about; the fight itself already happened in a modal neither side can verify.
	if kind != "boss_won":
		var source: HexTile = tile_at(action.get("from", action.get("tile", null)))
		if source == null or source.owner_seat != seat:
			return
	# The payload's own "seat" is overwritten rather than read, so nobody can build or
	# capture in another player's name.
	action["seat"] = seat
	_play_action(action)
	_action_received.rpc(action)


## The owner's copy of an action, run by every other peer.
@rpc("any_peer", "reliable")
func _action_received(action: Dictionary) -> void:
	if GameState.is_authority:
		return
	_play_action(action)


## Runs one action by name. A closed set rather than anything reflective: what can
## travel is exactly what is listed here, and each case lands on the same applier a
## local click uses.
func _play_action(action: Dictionary) -> void:
	_applying_remote = true
	var tile: HexTile = tile_at(action.get("tile", action.get("from", null)))
	match str(action.get("kind", "")):
		"march":
			var target: HexTile = tile_at(action.get("to", null))
			if tile != null and target != null:
				_play_march(tile, target)
		"build_mine":
			if tile != null:
				_apply_build_mine(tile, bool(action.get("troops", false)))
		"recruit":
			if tile != null:
				_apply_recruit(tile, int(action.get("unit", HexTile.UnitType.SOLDIER)))
		"upgrade_mine":
			if tile != null:
				_apply_upgrade_mine(tile)
		"reinforce":
			if tile != null:
				_apply_reinforce(tile)
		"boss_won":
			if tile != null:
				_apply_capture(tile, int(action.get("seat", tile.owner_seat)))
	_applying_remote = false


## A keep taken by storm: whoever fought for it keeps it. Called by the main loop when
## the battle modal comes back a win, and routed like anything else so the tile changes
## hands on every screen at once.
func capture_stronghold(tile: HexTile, seat: int) -> void:
	if tile == null:
		return
	if not _route("boss_won", {"tile": tile.grid_coords}):
		return
	_apply_capture(tile, seat)


func _apply_capture(tile: HexTile, seat: int) -> void:
	tile.owner_seat = seat
	tile.update_visuals()
	tile.trigger_climax_effect()
