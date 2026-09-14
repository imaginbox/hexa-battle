extends CanvasLayer
## HUD for the axial hex board: the tallies, the gold / reach economy, and the
## context panel that opens when one of the player's tiles is clicked.

## Group the [GameGrid] node is in.
const GRID_GROUP := "battle_grid"
## How often the tallies and the economy readout are refreshed, in seconds.
##
## Four times a second was costing a full walk of the board — 91 tiles at the largest
## table — for a line that only ever changes when troops are produced, which is once a
## second per tile at most. Twice a second still reads as live and halves the work.
const REFRESH_INTERVAL := 0.5
## Separator between the per-seat blocks on the status line.
const FACTION_GAP := "     "
## Status-line font size by table size. The line gains a block per seat, so it
## steps down to stay on screen — at the default size the fourth seat ran off the
## right edge of the viewport entirely.
const STATUS_FONT_BY_SEATS := {2: 26, 3: 22, 4: 19}
const STATUS_FONT_FALLBACK := 19

const COLOR_INK := Color("1b2430")
const COLOR_GOLD := Color("ffd166")

# --- Le menu de case : un essaim de petites cases hexagonales ------------------

## Where the menu's pictures live. Loaded at run time rather than preloaded, on purpose:
## a picture the editor has not finished importing has no `.import` yet, and a `preload`
## of one is a parse error that takes the whole HUD down with it. A missing picture should
## cost a picture, not the interface.
const ART := {
	"plate": "res://Assets/generated/ui_hex_plate.png",
	"mine": "res://Assets/generated/icon_mine.png",
	"coin": "res://Assets/generated/icon_coin.png",
	"upgrade": "res://Assets/generated/icon_upgrade.png",
	"close": "res://Assets/generated/icon_cross.png",
	"archer": "res://Assets/generated/icon_unit_archer.png",
	"catapult": "res://Assets/generated/icon_unit_catapult.png",
	"soldier": "res://Assets/generated/icon_unit_soldier.png",
}

## Side of one hexagonal cell in pixels.
const CELL := 72.0
## Height of the one-line caption above the cells. It is centred over the cluster and is
## allowed to overflow it, so its own width never widens the box.
const TITLE_HEIGHT := 30.0
## Pixels left between the unit and the first ring of choices. Near zero tucks them right
## up against the tile's edge.
const MENU_GAP := 2.0

@onready var _status: Label = $Status

var _grid: GameGrid

var _gold_label: Label
var _reach_button: Button
var _mode_button: Button
## The cluster of choices, the caption above it, and the full-screen catcher behind it
## that turns any other click into a dismissal.
var _cluster: Control
## The menu's pictures, filled once from [constant ART].
var _art: Dictionary = {}
var _cluster_title: Label
var _cluster_catcher: ColorRect
var _cluster_cells: Array[Control] = []
## Where the unit itself sits inside the cluster. The choices are laid out around this
## point, so it is the one that has to land on the tile.
var _cluster_anchor: Vector2 = Vector2.ZERO
## Tile the cluster is currently offering choices for.
var _context_tile: HexTile


func _ready() -> void:
	_grid = get_tree().get_first_node_in_group(GRID_GROUP) as GameGrid
	if _grid != null:
		_grid.tile_context_requested.connect(_on_tile_context_requested)
	_build_economy_ui()
	_load_art()
	_build_context_panel()

	var timer := Timer.new()
	timer.wait_time = REFRESH_INTERVAL
	timer.autostart = true
	timer.timeout.connect(_refresh_status)
	add_child(timer)
	_refresh_status()


func _refresh_status() -> void:
	if _grid == null:
		return
	var tiles_by_seat: Dictionary = {}
	var troops_by_seat: Dictionary = {}
	for tile: HexTile in _grid.tiles.values():
		if tile.owner_seat == HexTile.NEUTRAL:
			continue
		tiles_by_seat[tile.owner_seat] = int(tiles_by_seat.get(tile.owner_seat, 0)) + 1
		troops_by_seat[tile.owner_seat] = int(troops_by_seat.get(tile.owner_seat, 0)) + tile.troop_count

	# One block per card actually in play, the local one called out so a four-player
	# board still tells you at a glance which line is yours. Iterating the occupied
	# seats rather than a count keeps a table with a hole in it honest.
	var parts: Array[String] = []
	var seats: Array[int] = GameState.occupied_seats
	for seat in seats:
		var seat_name: String
		if seat == GameState.local_seat:
			seat_name = "TOI"
		elif GameState.is_ai_seat(seat):
			# Solo has exactly one machine opponent, so it needs no number — and a
			# number there reads like the difficulty level. A match can have several.
			seat_name = "IA" if not GameState.in_room else "IA%d" % (seat + 1)
		else:
			seat_name = "J%d" % (seat + 1)
		parts.append("%s %d cases, %d troupes" % [
			seat_name,
			int(tiles_by_seat.get(seat, 0)),
			int(troops_by_seat.get(seat, 0))])
	if not GameState.in_room:
		parts.append("IA NIVEAU %d" % GameState.ai_level)
	_status.add_theme_font_size_override("font_size",
		int(STATUS_FONT_BY_SEATS.get(seats.size(), STATUS_FONT_FALLBACK)))
	_status.text = FACTION_GAP.join(parts)

	_gold_label.text = "OR  %d" % GameState.player_gold
	var bonus: int = GameState.reach_bonus()
	if GameState.at_max_reach():
		_reach_button.text = "PORTÉE  +%d   (maximum)" % bonus
		_reach_button.disabled = true
	else:
		var cost: int = GameState.reach_cost()
		_reach_button.text = "PORTÉE  +%d → +%d   (%d or)" % [bonus, bonus + 1, cost]
		_reach_button.disabled = GameState.player_gold < cost
	_mode_button.text = "TIR : %s" % ("AUTOMATIQUE" if GameState.auto_attack else "MANUEL")

	# The board is rebuilt between levels, so the cluster may be pointing at a tile that
	# no longer exists.
	if _cluster.visible and not is_instance_valid(_context_tile):
		_close_context()


# --- Économie -----------------------------------------------------------------

func _build_economy_ui() -> void:
	_gold_label = Label.new()
	_gold_label.position = Vector2(24, 92)
	_gold_label.add_theme_font_size_override("font_size", 26)
	_gold_label.add_theme_color_override("font_color", COLOR_GOLD)
	_gold_label.add_theme_color_override("font_outline_color", COLOR_INK)
	_gold_label.add_theme_constant_override("outline_size", 6)
	add_child(_gold_label)

	_reach_button = Button.new()
	_reach_button.position = Vector2(24, 128)
	_reach_button.custom_minimum_size = Vector2(270, 42)
	_reach_button.add_theme_font_size_override("font_size", 18)
	_style_button(_reach_button)
	_reach_button.pressed.connect(_on_reach_pressed)
	add_child(_reach_button)

	_mode_button = Button.new()
	_mode_button.position = Vector2(24, 178)
	_mode_button.custom_minimum_size = Vector2(270, 42)
	_mode_button.add_theme_font_size_override("font_size", 18)
	_style_button(_mode_button)
	_mode_button.pressed.connect(_on_mode_pressed)
	add_child(_mode_button)


func _on_reach_pressed() -> void:
	GameState.upgrade_reach()
	_refresh_status()


## Pacifiste / automatique : who pulls the trigger on the player's tiles.
func _on_mode_pressed() -> void:
	GameState.auto_attack = not GameState.auto_attack
	_refresh_status()


# --- Le menu de case : un essaim de petites cases hexagonales ------------------
#
# Every choice is a small hexagon with an icon on it, laid out as a honeycomb beside the
# tile it belongs to. It is a one-shot menu: it closes the moment a choice is taken, and
# the moment anything else is clicked.

func _on_tile_context_requested(tile: HexTile) -> void:
	_context_tile = tile
	_rebuild_context_actions()


func _build_context_panel() -> void:
	# A full-screen transparent catcher sits behind the cluster, so a click that is not on
	# a cell lands here — which is what makes "click anywhere else and it goes away" work
	# without the board underneath reading that same click as a new selection.
	_cluster_catcher = ColorRect.new()
	# Dimmed rather than invisible: the choices belong to the unit behind them, and a menu
	# floating over an undimmed board reads as part of the board rather than as a question
	# being asked about it.
	_cluster_catcher.color = Color(0.06, 0.08, 0.11, 0.45)
	_cluster_catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cluster_catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	_cluster_catcher.gui_input.connect(_on_cluster_catcher_input)
	_cluster_catcher.visible = false
	add_child(_cluster_catcher)

	_cluster = Control.new()
	_cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cluster.visible = false
	add_child(_cluster)

	_cluster_title = Label.new()
	_cluster_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cluster_title.add_theme_font_size_override("font_size", 18)
	_cluster_title.add_theme_color_override("font_color", COLOR_GOLD)
	_cluster_title.add_theme_color_override("font_outline_color", COLOR_INK)
	_cluster_title.add_theme_constant_override("outline_size", 6)
	_cluster.add_child(_cluster_title)


## A click that reaches the catcher is a click outside the choices, so it closes them.
func _on_cluster_catcher_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_close_context()


func _close_context() -> void:
	_context_tile = null
	_cluster.visible = false
	_cluster_catcher.visible = false


## Takes one choice and closes the cluster: the menu is a one-shot, so a decision always
## leaves the board clear behind it.
func _choose(handler: Callable) -> void:
	handler.call()
	_close_context()


## One picture by name, or null when the editor has not imported it yet.
func _tex(key: String) -> Texture2D:
	return _art.get(key) as Texture2D


## Fills [member _art] once, from [constant ART].
func _load_art() -> void:
	for key: String in ART:
		var path: String = ART[key]
		if ResourceLoader.exists(path):
			_art[key] = load(path)
		else:
			push_warning("HUD: %s is not imported yet; the menu does without it." % path)


## Rebuilds the cluster for the tile that was clicked.
func _rebuild_context_actions() -> void:
	for cell in _cluster_cells:
		cell.queue_free()
	_cluster_cells.clear()

	var tile: HexTile = _context_tile
	if tile == null or not is_instance_valid(tile):
		_close_context()
		return
	_cluster_title.text = _tile_caption(tile)

	# One cell per choice. Two mine cells share the mine icon — the price chip is what
	# tells them apart, one paid in coins and one in soldiers.
	if tile.tile_type == HexTile.TileType.REGULAR:
		_add_cell(_tex("mine"), _tex("coin"), str(GameGrid.MINE_GOLD_COST), _build_mine_with_gold,
			GameState.player_gold >= GameGrid.MINE_GOLD_COST)
		_add_cell(_tex("mine"), _tex("soldier"), str(GameGrid.MINE_TROOP_COST), _build_mine_with_troops,
			tile.troop_count >= GameGrid.MINE_TROOP_COST)
	if tile.tile_type == HexTile.TileType.MINE and tile.mine_level < GameGrid.MINE_RATES.size():
		var cost: int = GameGrid.MINE_UPGRADE_COSTS[tile.mine_level - 1]
		_add_cell(_tex("upgrade"), _tex("coin"), str(cost), _upgrade_mine,
			GameState.player_gold >= cost)
	if tile.unit_type != HexTile.UnitType.ARCHER:
		_add_cell(_tex("archer"), _tex("coin"), str(GameGrid.ARCHER_COST), _recruit_archers,
			GameState.player_gold >= GameGrid.ARCHER_COST)
	if tile.unit_type != HexTile.UnitType.CATAPULT:
		_add_cell(_tex("catapult"), _tex("coin"), str(GameGrid.CATAPULT_COST), _recruit_catapult,
			GameState.player_gold >= GameGrid.CATAPULT_COST)
	if tile.unit_type != HexTile.UnitType.SOLDIER:
		_add_cell(_tex("soldier"), null, "", _recruit_soldiers, true)
	# Troops right now, on any card that is not already full.
	_add_cell(_tex("soldier"), _tex("coin"), str(GameGrid.RENFORT_COST), _reinforce,
		GameState.player_gold >= GameGrid.RENFORT_COST and tile.troop_count < tile.max_troops)
	_add_cell(_tex("close"), null, "", _close_context, true)

	_layout_cells(tile)
	_place_cluster(tile)
	_cluster_catcher.visible = true
	_cluster.visible = true


## One choice: the hexagon plate, the icon that says what it does, and the price along
## the bottom edge as a coin or a soldier. A choice nobody can pay for is drawn dimmed
## and cannot be pressed, so an unaffordable option still says it exists.
func _add_cell(icon: Texture2D, price_icon: Texture2D, price: String,
		handler: Callable, affordable: bool) -> void:
	var cell := Control.new()
	cell.size = Vector2(CELL, CELL)
	cell.pivot_offset = Vector2(CELL, CELL) * 0.5
	_cluster.add_child(cell)
	_cluster_cells.append(cell)

	var plate := TextureButton.new()
	plate.texture_normal = _tex("plate")
	plate.ignore_texture_size = true
	plate.stretch_mode = TextureButton.STRETCH_SCALE
	plate.set_anchors_preset(Control.PRESET_FULL_RECT)
	if affordable:
		plate.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		plate.pressed.connect(_choose.bind(handler))
		# The same nudge a tile gives under the cursor, so the cluster belongs to the board.
		plate.mouse_entered.connect(_nudge.bind(cell, 1.09))
		plate.mouse_exited.connect(_nudge.bind(cell, 1.0))
	else:
		plate.disabled = true
		plate.modulate = Color(1, 1, 1, 0.42)
	cell.add_child(plate)

	# A picture that has not been imported yet leaves its cell empty, and an empty hexagon
	# says nothing at all — so the two cells that can be read as a mark get one instead.
	if icon == null:
		var mark := Label.new()
		mark.text = "X"
		mark.set_anchors_preset(Control.PRESET_FULL_RECT)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		mark.add_theme_font_size_override("font_size", 36)
		mark.add_theme_color_override("font_color", COLOR_INK)
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(mark)
		return

	var glyph := TextureRect.new()
	glyph.texture = icon
	glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	glyph.offset_left = CELL * 0.20
	glyph.offset_top = CELL * 0.15
	glyph.offset_right = -CELL * 0.20
	glyph.offset_bottom = -(CELL * 0.32 if price != "" else CELL * 0.18)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(glyph)

	if price == "":
		return
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 3)
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.offset_left = -CELL * 0.5
	row.offset_right = CELL * 0.5
	row.offset_top = -CELL * 0.34
	row.offset_bottom = -CELL * 0.05
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(row)
	if price_icon != null:
		var chip := TextureRect.new()
		chip.texture = price_icon
		chip.custom_minimum_size = Vector2(CELL * 0.28, CELL * 0.28)
		chip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		chip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(chip)
	var label := Label.new()
	label.text = price
	label.add_theme_font_size_override("font_size", int(CELL * 0.24))
	label.add_theme_color_override("font_color", COLOR_INK)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)


## Grows a cell a little while the cursor is on it.
func _nudge(cell: Control, factor: float) -> void:
	var tween := create_tween()
	tween.tween_property(cell, "scale", Vector2.ONE * factor, 0.1)


## Lays the choices out as an arc hugging the unit's lower side, rather than a ring all the
## way round: they read as a fan of answers under the tile they are about.
##
## The radius is measured from the unit as it actually appears on screen, so the arc stays
## snug at every board size. A fixed pixel radius would only ever fit the smallest board —
## a four-player map is drawn from much further back and its tiles are far smaller, so the
## choices would float well clear of the one they belong to.
##
## The step is then chosen so neighbouring cells all but touch, the chord between two of
## them being the cell's own width. That is what turns a row of buttons into a curve.
func _layout_cells(tile: HexTile) -> void:
	var count: int = _cluster_cells.size()
	if count == 0:
		return
	var radius: float = CELL
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null and is_instance_valid(tile):
		var here: Vector2 = camera.unproject_position(tile.global_position)
		var edge: Vector2 = camera.unproject_position(
			tile.global_position + Vector3(tile.scale.x, 0.0, 0.0))
		# One local unit measured on screen is the tile's circumradius there; the tile's flat
		# side sits at sqrt(3)/2 of that, and that edge is what the choices have to clear.
		radius = (edge - here).length() * 0.866 + CELL * 0.5 + MENU_GAP
	var step: float = 2.0 * asin(clampf(CELL / (2.0 * radius), 0.0, 1.0))
	var span: float = step * float(count - 1)
	# Positions are built around the origin and only afterwards moved into the cluster,
	# because an arc is not symmetric: its box has to be measured rather than assumed.
	var offsets: Array[Vector2] = []
	# Started at zero so the origin — the unit itself — is part of the box too, which is what
	# puts the caption directly above the tile instead of on top of the arc.
	var left: float = 0.0
	var right: float = 0.0
	var top: float = 0.0
	var bottom: float = 0.0
	for i in count:
		# Straight down on screen is a quarter turn, and the arc spreads evenly either side.
		var angle: float = PI * 0.5 - span * 0.5 + step * float(i)
		var offset: Vector2 = Vector2(cos(angle), sin(angle)) * radius
		offsets.append(offset)
		left = minf(left, offset.x)
		right = maxf(right, offset.x)
		top = minf(top, offset.y)
		bottom = maxf(bottom, offset.y)
	left -= CELL * 0.5
	right += CELL * 0.5
	top -= CELL * 0.5
	bottom += CELL * 0.5
	var width: float = right - left
	_cluster.size = Vector2(width, TITLE_HEIGHT + (bottom - top))
	_cluster_title.position = Vector2.ZERO
	# The caption is allowed to spill out of the box rather than widen it: a box as wide as
	# the caption gets pushed off the unit whenever the tile sits near an edge, and it is the
	# arc, not the caption, that has to stay on the tile.
	_cluster_title.size = Vector2(width, TITLE_HEIGHT)
	# Where the unit lands inside the cluster: the origin the offsets were built around, moved
	# into the box. Everything else is placed relative to it.
	_cluster_anchor = Vector2(width * 0.5 - (left + right) * 0.5, TITLE_HEIGHT - top)
	for i in count:
		_cluster_cells[i].position = offsets[i] + _cluster_anchor - Vector2(CELL, CELL) * 0.5


## Puts the cluster on the unit it belongs to, and clamps the whole thing inside the screen:
## a menu hanging off the edge is worse than one slightly out of place.
func _place_cluster(tile: HexTile) -> void:
	var view: Vector2 = get_viewport().get_visible_rect().size
	var wanted: Vector2 = (view - _cluster.size) * 0.5
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera != null and is_instance_valid(tile):
		# The anchor is where the unit sits inside the cluster, so that is the point that has
		# to land on the tile — not the cluster's centre.
		wanted = camera.unproject_position(tile.global_position) - _cluster_anchor
	wanted.x = clampf(wanted.x, 12.0, maxf(12.0, view.x - _cluster.size.x - 12.0))
	wanted.y = clampf(wanted.y, 12.0, maxf(12.0, view.y - _cluster.size.y - 12.0))
	_cluster.position = wanted


## One line saying what was clicked, so the cluster is never a mystery.
func _tile_caption(tile: HexTile) -> String:
	var kind: String = "case"
	if tile.tile_type == HexTile.TileType.MINE:
		kind = "MINE tier %d" % tile.mine_level
	elif tile.tile_type == HexTile.TileType.FORTRESS_BOSS:
		kind = "CHÂTEAU"
	return "%s %s · %s · %d troupes" % [
		kind, str(tile.grid_coords), _unit_name(tile.unit_type), tile.troop_count]


func _unit_name(type: HexTile.UnitType) -> String:
	match type:
		HexTile.UnitType.ARCHER:
			return "ARCHERS"
		HexTile.UnitType.CATAPULT:
			return "CATAPULTE"
		_:
			return "INFANTERIE"


## Each of these is run through [method _choose], so the cluster closes itself the moment
## a choice is taken and none of them has to remember to do it.
func _build_mine_with_gold() -> void:
	_grid.build_mine(_context_tile)


func _build_mine_with_troops() -> void:
	_grid.build_mine(_context_tile, true)


func _recruit_archers() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.ARCHER)


func _recruit_catapult() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.CATAPULT)


func _recruit_soldiers() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.SOLDIER)


func _upgrade_mine() -> void:
	_grid.upgrade_mine(_context_tile)


func _reinforce() -> void:
	_grid.reinforce(_context_tile)


# --- Style --------------------------------------------------------------------

## Warm clay button, so the HUD sits with the rest of the game's palette.
func _style_button(button: Button) -> void:
	button.add_theme_color_override("font_color", COLOR_INK)
	button.add_theme_stylebox_override("normal", _button_style(Color("f5a623")))
	button.add_theme_stylebox_override("hover", _button_style(Color("ffc046")))
	button.add_theme_stylebox_override("pressed", _button_style(Color("d9821a")))
	button.add_theme_stylebox_override("disabled", _button_style(Color("b9b2a4")))


func _button_style(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = COLOR_INK
	box.set_border_width_all(3)
	box.set_corner_radius_all(12)
	box.content_margin_left = 12.0
	box.content_margin_right = 12.0
	box.content_margin_top = 8.0
	box.content_margin_bottom = 8.0
	return box


func _card_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.968627, 0.945098, 0.898039, 0.97)
	box.border_color = COLOR_INK
	box.set_border_width_all(4)
	box.set_corner_radius_all(16)
	box.content_margin_left = 18.0
	box.content_margin_right = 18.0
	box.content_margin_top = 14.0
	box.content_margin_bottom = 14.0
	return box
