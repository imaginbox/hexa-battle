class_name AIController
extends Node
## Autonomous enemy commander.
##
## Wakes on its own unpredictable clock and picks one of three tactics from what
## it can see on the board. It acts through the same [GameGrid] API the player
## does, so its shots obey the same ranges and damage rules.

## Group the [GameGrid] node is in.
const GRID_GROUP := "battle_grid"

## Delay between two AI moves, in seconds, at the first level. Re-rolled after
## every move so the player can never settle into a rhythm.
const INTERVAL_MIN := 1.8
const INTERVAL_MAX := 3.2
## How much faster the AI moves once it has lost five duels' worth of levels.
const MAX_LEVEL_SPEEDUP := 2.4
## Levels over which that speed-up is reached.
const SPEEDUP_LEVELS := 5.0
## A neutral tile this lightly held is worth absorbing.
const SOFT_NEUTRAL := 14
## Below this, a tile has nothing worth sending out.
const MIN_ATTACK_GARRISON := 8
## The AI commits an attack only from a tile with at least this share of its
## troops, so it does not trickle its army away.
const MIN_SHARE := 2

@export var active: bool = true
## The seat this commander plays for. Solo puts the human on seat 0, so the AI
## takes seat 1 — which is also where its red keep stands in the table palette.
@export var seat: int = 1
## The AI stands down while a battle modal is open, so the board it is reading
## cannot change under the player's feet mid-fight.
var _grid: GameGrid
var _timer: Timer
## What the AI has learned about the player: 0 = turtling, 1 = pushing hard.
var _player_pressure: float = 0.0
var _last_player_share: float = -1.0


func _ready() -> void:
	_grid = get_tree().get_first_node_in_group(GRID_GROUP) as GameGrid
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_take_turn)
	add_child(_timer)
	_schedule()


## Stops the AI from taking turns, e.g. while the player is in a battle modal.
func set_active(value: bool) -> void:
	active = value
	if active:
		_schedule()
	else:
		_timer.stop()


## Cadence: the base roll, tightened by how many levels the AI has lost.
func _schedule() -> void:
	var speedup: float = lerpf(1.0, MAX_LEVEL_SPEEDUP,
		clampf(float(GameState.ai_level - 1) / SPEEDUP_LEVELS, 0.0, 1.0))
	_timer.start(randf_range(INTERVAL_MIN, INTERVAL_MAX) / speedup)


func _take_turn() -> void:
	if active and _grid != null:
		_update_player_profile()
		# Sabotage first: a mine pays for the whole enemy war effort. After that
		# the AI leans on how the player has been playing — against someone who is
		# pushing it counter-attacks, against someone quietly building up it just
		# keeps taking ground.
		var reacted: bool = _strike_player_mine()
		if not reacted and _player_pressure >= 0.5:
			reacted = _counter_offensive()
		if not reacted:
			reacted = _expand()
		if not reacted:
			_counter_offensive()
	_schedule()


# --- Lecture du joueur --------------------------------------------------------

## Reads how fast the player is gaining ground and remembers it, so the AI can
## lean defensive against a pusher and aggressive against someone turtling.
func _update_player_profile() -> void:
	var share: float = float(_count_seat(GameState.local_seat)) / float(maxi(_grid.tiles.size(), 1))
	if _last_player_share >= 0.0:
		_player_pressure = lerpf(_player_pressure,
			clampf((share - _last_player_share) * 8.0 + 0.5, 0.0, 1.0), 0.4)
	_last_player_share = share


func _count_seat(seat_index: int) -> int:
	var n := 0
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat == seat_index:
			n += 1
	return n


# --- Tactiques ----------------------------------------------------------------

## Sabotage : si le joueur tient une mine, une catapulte la pilonne. C'est le
## seul moyen d'entamer la mine, et l'IA le sait.
func _strike_player_mine() -> bool:
	var mine: HexTile = null
	for tile: HexTile in _grid.tiles.values():
		if tile.tile_type == HexTile.TileType.MINE and tile.owner_seat == GameState.local_seat:
			mine = tile
			break
	if mine == null:
		return false
	var engine: HexTile = _siege_engine(mine)
	if engine == null:
		return false
	_grid.execute_march(engine, mine)
	return true


## Contre-offensive surprise : si le joueur masse ses troupes sur une case, l'IA
## frappe ailleurs, là où c'est faiblement tenu.
func _counter_offensive() -> bool:
	var total: int = 0
	var strongest: int = 0
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat == GameState.local_seat:
			total += tile.troop_count
			strongest = maxi(strongest, tile.troop_count)
	if total <= 0 or float(strongest) < 0.5 * float(total):
		return false
	# The player is massed, so hit wherever the line looks thinnest.
	var target: HexTile = null
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat != GameState.local_seat:
			continue
		if target == null or tile.troop_count < target.troop_count:
			target = tile
	if target == null:
		return false
	return _attack(target)


## Expansion : absorber une case neutre proche et peu tenue.
func _expand() -> bool:
	for tile: HexTile in _grid.tiles.values():
		if tile.is_neutral() and tile.troop_count <= SOFT_NEUTRAL:
			if _attack(tile):
				return true
	return false


# --- Aides --------------------------------------------------------------------

## Sends the strongest tile that can reach `target` at it. Returns whether an
## attack actually went out.
func _attack(target: HexTile) -> bool:
	var attacker: HexTile = null
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat != seat:
			continue
		if tile.troop_count < MIN_ATTACK_GARRISON or not _grid.is_valid_target(tile, target):
			continue
		if attacker == null or tile.troop_count > attacker.troop_count:
			attacker = tile
	if attacker == null or attacker.troop_count < target.troop_count * MIN_SHARE:
		return false
	_grid.execute_march(attacker, target)
	return true


## L'IA n'a pas d'économie : quand une mine tombe dans la fenêtre de tir d'une
## catapulte, elle reforme la case la mieux placée plutôt que d'en construire une.
func _siege_engine(mine: HexTile) -> HexTile:
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat == seat and tile.unit_type == HexTile.UnitType.CATAPULT:
			if _grid.is_valid_target(tile, mine):
				return tile
	var best: HexTile = null
	var best_distance: int = 999
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat != seat:
			continue
		var distance: int = _grid.axial_distance(tile.grid_coords, mine.grid_coords)
		if distance < best_distance:
			best_distance = distance
			best = tile
	# A catapult needs 2 to 4 hexes, so only worth converting if it would land in
	# that window rather than wasting the tile.
	if best == null:
		return null
	# Only worth converting if it would land inside a catapult's effective window,
	# which the unlocked reach can shorten — and which execute_march enforces.
	var own: Vector2i = HexTile.unit_range(HexTile.UnitType.CATAPULT)
	var window := Vector2i(own.x, own.y + GameState.reach_bonus())
	if best_distance < window.x or best_distance > window.y:
		return null
	best.unit_type = HexTile.UnitType.CATAPULT
	return best
