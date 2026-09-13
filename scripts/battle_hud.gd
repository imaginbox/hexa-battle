extends CanvasLayer
## HUD for the axial hex board: the tallies, the gold / reach economy, and the
## context panel that opens when one of the player's tiles is clicked.

## Group the [GameGrid] node is in.
const GRID_GROUP := "battle_grid"
## How often the tallies and the economy readout are refreshed, in seconds.
const REFRESH_INTERVAL := 0.25
## Separator between the per-seat blocks on the status line.
const FACTION_GAP := "     "
## Status-line font size by table size. The line gains a block per seat, so it
## steps down to stay on screen — at the default size the fourth seat ran off the
## right edge of the viewport entirely.
const STATUS_FONT_BY_SEATS := {2: 26, 3: 22, 4: 19}
const STATUS_FONT_FALLBACK := 19

const COLOR_INK := Color("1b2430")
const COLOR_GOLD := Color("ffd166")

@onready var _status: Label = $Status

var _grid: GameGrid

var _gold_label: Label
var _reach_button: Button
var _mode_button: Button
var _context_panel: PanelContainer
var _context_title: Label
var _context_actions: VBoxContainer
## Tile the context panel is currently offering actions for.
var _context_tile: HexTile


func _ready() -> void:
	_grid = get_tree().get_first_node_in_group(GRID_GROUP) as GameGrid
	if _grid != null:
		_grid.tile_context_requested.connect(_on_tile_context_requested)
	_build_economy_ui()
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

	# The board is rebuilt between levels, so the panel may be pointing at a tile
	# that no longer exists.
	if _context_panel.visible and not is_instance_valid(_context_tile):
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


# --- Panneau contextuel -------------------------------------------------------

func _on_tile_context_requested(tile: HexTile) -> void:
	_context_tile = tile
	_context_panel.visible = true
	_rebuild_context_actions()


func _build_context_panel() -> void:
	_context_panel = PanelContainer.new()
	_context_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_context_panel.offset_left = -200.0
	_context_panel.offset_top = -260.0
	_context_panel.offset_right = 200.0
	_context_panel.offset_bottom = -24.0
	_context_panel.add_theme_stylebox_override("panel", _card_style())

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_context_panel.add_child(column)

	_context_title = Label.new()
	_context_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_context_title.add_theme_font_size_override("font_size", 19)
	_context_title.add_theme_color_override("font_color", COLOR_INK)
	column.add_child(_context_title)

	_context_actions = VBoxContainer.new()
	_context_actions.add_theme_constant_override("separation", 6)
	column.add_child(_context_actions)

	_context_panel.visible = false
	add_child(_context_panel)


func _rebuild_context_actions() -> void:
	for child in _context_actions.get_children():
		_context_actions.remove_child(child)
		child.queue_free()

	var tile: HexTile = _context_tile
	if tile == null:
		return
	var kind: String = "case"
	if tile.tile_type == HexTile.TileType.MINE:
		kind = "MINE tier %d" % tile.mine_level
	var reach: Vector2i = _grid.attack_range(tile)
	_context_title.text = "%s %s   ·   %s   ·   %d troupes   ·   portée %d" % [
		kind, str(tile.grid_coords), _unit_name(tile.unit_type), tile.troop_count, reach.y]

	if tile.tile_type == HexTile.TileType.REGULAR:
		_add_action("Bâtir une mine   (%d or)" % GameGrid.MINE_GOLD_COST, _build_mine_with_gold,
			GameState.player_gold >= GameGrid.MINE_GOLD_COST)
		_add_action("Bâtir une mine   (%d troupes)" % GameGrid.MINE_TROOP_COST, _build_mine_with_troops,
			tile.troop_count >= GameGrid.MINE_TROOP_COST)
	if tile.tile_type == HexTile.TileType.MINE and tile.mine_level < GameGrid.MINE_RATES.size():
		var next_cost: int = GameGrid.MINE_UPGRADE_COSTS[tile.mine_level - 1]
		var gain: int = int(GameGrid.MINE_RATES[tile.mine_level] - GameGrid.MINE_RATES[tile.mine_level - 1])
		_add_action("Mine tier %d → %d   (+%d or/s)   (%d or)" % [
			tile.mine_level, tile.mine_level + 1, gain, next_cost],
			_upgrade_mine, GameState.player_gold >= next_cost)
	if tile.unit_type != HexTile.UnitType.ARCHER:
		_add_action("Former des archers   (%d or)" % GameGrid.ARCHER_COST, _recruit_archers,
			GameState.player_gold >= GameGrid.ARCHER_COST)
	if tile.unit_type != HexTile.UnitType.CATAPULT:
		_add_action("Former une catapulte   (%d or)" % GameGrid.CATAPULT_COST, _recruit_catapult,
			GameState.player_gold >= GameGrid.CATAPULT_COST)
	if tile.unit_type != HexTile.UnitType.SOLDIER:
		_add_action("Revenir à l'infanterie   (gratuit)", _recruit_soldiers)
	# Des troupes tout de suite, sur n'importe quelle case qui n'est pas pleine.
	_add_action("Renfort   +%d troupes   (%d or)" % [GameGrid.RENFORT_TROOPS, GameGrid.RENFORT_COST],
		_reinforce, GameState.player_gold >= GameGrid.RENFORT_COST and tile.troop_count < tile.max_troops)
	_add_action("Fermer", _close_context)


## Adds one action button. `affordable` greys it out so the player can see at a
## glance what the current purse allows.
func _add_action(label: String, handler: Callable, affordable: bool = true) -> void:
	var button := Button.new()
	button.text = label
	button.custom_minimum_size = Vector2(340, 36)
	button.add_theme_font_size_override("font_size", 16)
	button.disabled = not affordable
	_style_button(button)
	button.pressed.connect(handler)
	_context_actions.add_child(button)


func _unit_name(type: HexTile.UnitType) -> String:
	match type:
		HexTile.UnitType.ARCHER:
			return "ARCHERS"
		HexTile.UnitType.CATAPULT:
			return "CATAPULTE"
		_:
			return "INFANTERIE"


## A plain warning line inside the action column.
func _add_note(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(340, 0)
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color("b3402f"))
	_context_actions.add_child(label)


func _build_mine_with_gold() -> void:
	_grid.build_mine(_context_tile)
	_rebuild_context_actions()


func _build_mine_with_troops() -> void:
	_grid.build_mine(_context_tile, true)
	_rebuild_context_actions()


func _recruit_archers() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.ARCHER)
	_rebuild_context_actions()


func _recruit_catapult() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.CATAPULT)
	_rebuild_context_actions()


func _recruit_soldiers() -> void:
	_grid.recruit(_context_tile, HexTile.UnitType.SOLDIER)
	_rebuild_context_actions()


func _upgrade_mine() -> void:
	_grid.upgrade_mine(_context_tile)
	_rebuild_context_actions()


func _reinforce() -> void:
	_grid.reinforce(_context_tile)
	_rebuild_context_actions()


func _close_context() -> void:
	_context_panel.visible = false


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
