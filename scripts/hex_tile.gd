class_name HexTile
extends Area3D
## A single hexagonal battlefield tile.
##
## A tile owns a seat and a garrison. Once owned (any seat, not [constant NEUTRAL])
## it keeps producing troops until it reaches [member max_troops]. Clicking a tile
## - with 3D object picking enabled - emits [signal clicked], which [GameGrid]
## turns into a selection or a troop transfer.
##
## Ownership is a seat index rather than a two-sided faction: seat 0-3 is whoever
## sits there at the table, and every seat takes its colour from
## [method GameState.seat_color]. Solo is simply seat 0 against the AI on seat 1,
## so the single-player board is the same code path as a four-player one.

## Left mouse button was pressed on this tile.
signal clicked(tile: HexTile)
## The owning seat changed.
signal owner_changed(tile: HexTile, owner_seat: int)
## The garrison changed. `count` is the new value.
signal troops_changed(tile: HexTile, count: int)

## Unclaimed ground: no seat holds this tile.
const NEUTRAL := -1

enum TileType { REGULAR, FORTRESS_BOSS, MINE }
## Tactical classes. A tile's class decides how far it can strike and what it does
## on impact — see [method GameGrid.execute_march].
enum UnitType { SOLDIER, ARCHER, CATAPULT }

## Attack range of a unit class in hexes, as (min, max). Infantry reaches one hex,
## archers two and catapults three from the start; the reach upgrade adds a hex to
## every class on top of that.
static func unit_range(type: UnitType) -> Vector2i:
	match type:
		UnitType.ARCHER:
			return Vector2i(1, 2)
		UnitType.CATAPULT:
			return Vector2i(1, 3)
		_:
			return Vector2i(1, 1)

## Ground nobody holds yet. Owned tiles take their colour from their seat, so the
## two faction colours live in [Net]'s palette rather than here.
const COLOR_NEUTRAL := Color("c8d6e5")
const COLOR_LABEL_OWNED := Color("ffffff")
const COLOR_LABEL_NEUTRAL := Color("2f3640")
## Matte, non-reflective shading shared by every tile material.
const MATERIAL_ROUGHNESS := 0.75
const MATERIAL_METALLIC := 0.0
## Godot's default specular (Schlick GGX) lays a white sheen over every surface,
## which washes the faction colours out. Disabling it gives the flat matte look.
const MATERIAL_SPECULAR_MODE := BaseMaterial3D.SPECULAR_DISABLED

## How far a fortress is washed towards white before its seat colour is laid over
## it. Enough to keep the model's brick texture readable under any hue, little
## enough that the seat is still unmistakable.
const BUILDING_TINT_WASHOUT := 0.45
## Strength of the emissive lift that carries the seat colour on buildings.
const BUILDING_TINT_GLOW := 0.35

## Height of the troop label in tile-local space when there is no building.
const LABEL_HEIGHT_PLAIN := 0.9
## Gap left between the top of a building and the troop count above it.
const LABEL_CLEARANCE := 0.6
## How far above the troop count the unit-class badge floats.
const BADGE_OFFSET := 0.5

## Badge shown above the troop count so the three classes read at a glance.
## Neutral tiles are always infantry and stay bare.
const UNIT_ICONS := {
	UnitType.SOLDIER: preload("res://Assets/generated/icon_unit_soldier.png"),
	UnitType.ARCHER: preload("res://Assets/generated/icon_unit_archer.png"),
	UnitType.CATAPULT: preload("res://Assets/generated/icon_unit_catapult.png"),
}

## Size of the castle / fortress model on a fortress tile. Past roughly 2.0 the
## model starts spilling over onto the neighbouring hexes.
@export_range(0.5, 4.0, 0.05) var building_scale: float = 2.0

## One shared material per seat, built on first use and reused by every tile.
static var _seat_materials: Dictionary = {}

@export var tile_type: TileType = TileType.REGULAR
## Which seat holds this tile, or [constant NEUTRAL] for unclaimed ground.
@export var owner_seat: int = NEUTRAL:
	set(value):
		if owner_seat == value:
			return
		owner_seat = value
		update_visuals()
		_update_process_state()
		owner_changed.emit(self, owner_seat)
## Garrison. Stored exactly as assigned: [member max_troops] only stops
## *generation*, so a fortress may legitimately start above the cap. Negative
## values are allowed too — an assault that outnumbers the garrison is applied as
## a subtraction, and the caller turns the leftover value into a capture.
@export var troop_count: int = 10:
	set(value):
		if troop_count == value:
			return
		troop_count = value
		update_label()
		troops_changed.emit(self, troop_count)
## Garrison cap. Owned tiles stop producing once they reach it.
@export var max_troops: int = 60
## Troops produced per second while the tile is owned.
@export var generation_rate: float = 1.0
## The tile's tactical class: how far it strikes, and what it does on impact.
@export var unit_type: UnitType = UnitType.SOLDIER
## Gold a MINE pays its owner per second.
@export var gold_per_second: float = 2.0

@onready var base_mesh: MeshInstance3D = $BaseMesh
@onready var fortress_model: Node3D = $FortressModel
@onready var castle_model: Node3D = $CastleModel
@onready var mine_model: MeshInstance3D = $MineModel
@onready var label_count: Label3D = $LabelCount
@onready var unit_badge: Sprite3D = $UnitBadge
@onready var health_bar: Node3D = $HealthBar
@onready var health_fill: MeshInstance3D = $HealthBar/Fill
@onready var selection_ring: MeshInstance3D = $SelectionRing

## Position on the logical grid, in axial coordinates (q, r) as set by the grid.
var grid_coords: Vector2i = Vector2i.ZERO
## Rest scale, restored after a capture bounce.
var base_scale: Vector3 = Vector3.ONE

## Hit points of the building standing on this tile. Both at 0 means there is no
## structure to break, which is the case for every plain tile.
var structure_hp: int = 0
var structure_max_hp: int = 0
## Tier of the mine on this tile: tier 1 pays 2 gold a second and it goes up from
## there. Meaningless on anything that is not a mine.
var mine_level: int = 1

var _spawn_accumulator: float = 0.0
var _gold_accumulator: float = 0.0
var _bounce_tween: Tween

## Countdown to this tile's next automatic attack, driven by [GameGrid].
var auto_attack_timer: float = 0.0


func _ready() -> void:
	base_scale = scale
	input_ray_pickable = true
	selection_ring.visible = false
	fortress_model.scale = Vector3.ONE * building_scale
	castle_model.scale = Vector3.ONE * building_scale
	update_visuals()
	_update_process_state()


func _process(delta: float) -> void:
	_produce_gold(delta)
	if owner_seat == NEUTRAL or troop_count >= max_troops:
		_spawn_accumulator = 0.0
		return
	_spawn_accumulator += generation_rate * delta
	if _spawn_accumulator < 1.0:
		return
	var produced: int = int(_spawn_accumulator)
	_spawn_accumulator -= float(produced)
	add_troops(produced)
	GameState.add_troops_raised(produced)


## A mine pays its owner every second, in whole gold. Only the local seat's mines
## pay the local purse: gold is not networked, so a rival's mine must not mint
## coins into this player's treasury.
func _produce_gold(delta: float) -> void:
	if tile_type != TileType.MINE or owner_seat != GameState.local_seat:
		return
	_gold_accumulator += gold_per_second * delta
	var whole: int = int(_gold_accumulator)
	if whole <= 0:
		return
	_gold_accumulator -= float(whole)
	GameState.add_gold(whole)


# --- Public API ---------------------------------------------------------------

## Splits a garrison: removes `amount` troops from this tile, never below zero.
func take_troops(amount: int) -> void:
	if amount <= 0:
		return
	troop_count -= amount


## Reinforces this tile, capped at [member max_troops].
func add_troops(amount: int) -> void:
	if amount <= 0:
		return
	troop_count = mini(troop_count + amount, max_troops)


## Hands the tile to `seat` with `garrison` troops left standing on it.
func capture(seat: int, garrison: int = 1) -> void:
	owner_seat = seat
	troop_count = garrison
	trigger_bounce_effect()


func is_owned_by(seat: int) -> bool:
	return owner_seat == seat


## Nobody has claimed this ground.
func is_neutral() -> bool:
	return owner_seat == NEUTRAL


## Structures that shrug off everything except a siege engine.
func is_fortified() -> bool:
	return tile_type == TileType.MINE or tile_type == TileType.FORTRESS_BOSS


## Turns this tile into a gold mine. The caller is responsible for paying for it.
func build_mine() -> void:
	tile_type = TileType.MINE
	_gold_accumulator = 0.0
	update_visuals()
	_update_process_state()


## Gives this tile a structure to defend, with hit points of its own.
func arm_structure(hp: int) -> void:
	structure_max_hp = hp
	structure_hp = hp
	update_visuals()


## Batter the building down. Returns true when it comes down on this hit.
func take_structure_damage(amount: int) -> bool:
	if structure_max_hp <= 0:
		return false
	structure_hp = maxi(structure_hp - amount, 0)
	update_health_bar()
	return structure_hp == 0


## The bar drains from the right and reddens as it empties.
func update_health_bar() -> void:
	if not is_node_ready():
		return
	var ratio: float = 0.0 if structure_max_hp <= 0 else float(structure_hp) / float(structure_max_hp)
	# The quad is centred, so shrinking it alone would drain it from both ends.
	health_fill.scale = Vector3(ratio, 1.0, 1.0)
	health_fill.position = Vector3(-0.5 * (1.0 - ratio), 0.0, 0.0)
	var material := health_fill.material_override as StandardMaterial3D
	if material != null:
		material.albedo_color = Color("5ad66a").lerp(Color("e05545"), 1.0 - ratio)


## Shows or hides the selection ring.
func set_selected(value: bool) -> void:
	if is_node_ready() and selection_ring != null:
		selection_ring.visible = value


## Overrides the rest scale, e.g. when the grid scales tiles as it places them.
func set_base_scale(value: Vector3) -> void:
	base_scale = value
	scale = value


# --- Visuals ------------------------------------------------------------------

func update_visuals() -> void:
	if not is_node_ready():
		return
	base_mesh.material_override = _seat_material(owner_seat)
	# Only a fortress tile carries a building. Which model it shows is ordered by
	# whose eyes are looking: your own keep is the castle, everyone else's is the
	# red fortress, so every peer reads the same board as "me against the rest".
	var is_fortress: bool = tile_type == TileType.FORTRESS_BOSS
	var is_mine: bool = is_fortress and owner_seat == GameState.local_seat
	castle_model.visible = is_mine
	fortress_model.visible = is_fortress and not is_mine
	# Whichever keep is standing takes the seat's colour, so three rivals on one
	# board are still told apart at a glance.
	var building: Node3D = castle_model if is_mine else fortress_model
	if is_fortress:
		_tint_building(building, owner_seat)
	mine_model.visible = tile_type == TileType.MINE
	# Lift the count clear of the building, whatever building_scale is set to.
	var label_height: float = (building_scale + LABEL_CLEARANCE) if is_fortress else LABEL_HEIGHT_PLAIN
	label_count.position = Vector3(0, label_height, 0)
	# The class badge floats above the count. Unowned tiles are plain infantry,
	# so they stay bare and the board does not turn into a wall of icons.
	unit_badge.visible = owner_seat != NEUTRAL
	unit_badge.texture = UNIT_ICONS.get(unit_type)
	unit_badge.position = Vector3(0, label_height + BADGE_OFFSET, 0)
	# Only a tile carrying a structure that can be broken shows a health bar, and
	# it sits above the badge so nothing overlaps.
	health_bar.visible = structure_max_hp > 0
	health_bar.position = Vector3(0, label_height + BADGE_OFFSET + 0.5, 0)
	update_health_bar()
	update_label()


func update_label() -> void:
	if not is_node_ready():
		return
	label_count.text = str(troop_count)
	label_count.modulate = COLOR_LABEL_OWNED if owner_seat != NEUTRAL else COLOR_LABEL_NEUTRAL


## The famous juicy bounce on capture or reinforcement.
func trigger_bounce_effect() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	else:
		# Not currently squashing, so adopt whatever rest scale the tile has.
		# Keeps an externally resized tile (e.g. an enlarged boss tile) from
		# snapping back to its original size on the first bounce.
		base_scale = scale
	scale = base_scale * Vector3(1.2, 0.7, 1.2) # Squash
	_bounce_tween = create_tween().set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	_bounce_tween.tween_property(self, "scale", base_scale, 0.5) # Bounce back


## Much bigger version of the capture bounce, saved for the moment a fortress
## falls: hard squash, overshoot out to 1.4x, then settle back to rest.
func trigger_climax_effect() -> void:
	if _bounce_tween != null and _bounce_tween.is_valid():
		_bounce_tween.kill()
	else:
		base_scale = scale
	scale = base_scale * Vector3(1.3, 0.7, 1.3) # S'écrase
	_bounce_tween = create_tween()
	_bounce_tween.tween_property(self, "scale", base_scale * 1.4, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_bounce_tween.tween_property(self, "scale", base_scale, 0.6).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# --- Internals ----------------------------------------------------------------

func _update_process_state() -> void:
	var owned: bool = owner_seat != NEUTRAL
	set_process(owned)
	if not owned:
		_spawn_accumulator = 0.0


## The flat faction colour of a tile, keyed by seat so the palette lives in one
## place ([Net]) and every peer draws the same board without negotiating.
func _seat_material(seat: int) -> StandardMaterial3D:
	if _seat_materials.has(seat):
		return _seat_materials[seat] as StandardMaterial3D
	var color: Color = COLOR_NEUTRAL if seat == NEUTRAL else GameState.seat_color(seat)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = MATERIAL_ROUGHNESS
	mat.metallic = MATERIAL_METALLIC
	mat.specular_mode = MATERIAL_SPECULAR_MODE
	_seat_materials[seat] = mat
	return mat


## Picks up the seat colour on a fortress / castle model. albedo_color multiplies
## the model's own texture, so a straight tint over a saturated brick texture goes
## muddy; lightening it keeps the texture legible while the hue still reads, and a
## matching emissive lift guarantees the seat is obvious on every base texture.
func _tint_building(building: Node3D, seat: int) -> void:
	var tint: Color = COLOR_NEUTRAL if seat == NEUTRAL else GameState.seat_color(seat)
	for found in building.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := found as MeshInstance3D
		var source := mesh_instance.get_active_material(0)
		var mat := StandardMaterial3D.new()
		if source is StandardMaterial3D:
			mat = (source as StandardMaterial3D).duplicate() as StandardMaterial3D
		mat.albedo_color = tint.lerp(Color.WHITE, BUILDING_TINT_WASHOUT)
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = BUILDING_TINT_GLOW
		mesh_instance.material_override = mat


func _input_event(_camera: Node, event: InputEvent, _event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			clicked.emit(self)
