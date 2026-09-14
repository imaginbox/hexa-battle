extends Node3D
## Orchestrates the run: the board, the camera framing, the battle modal and the
## loop from one level to the next.
##
## Swap [member current_battle_module_scene] to switch the whole game's fight
## (Quiz, Cartes, ...) without touching anything else.

## Board radius of the first level. Each stage widens the board by one until the
## cap, after which only the fortress keeps growing.
const BASE_GRID_RADIUS := 3
## Where a match sends you when it ends.
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const MAX_GRID_RADIUS := 5
## Garrison of the enemy fortress, and how much it grows per stage.
const BASE_BOSS_TROOPS := 80
const BOSS_TROOPS_GROWTH := 15
## Camera distance as a multiple of the board's world radius. Keeps any board
## size inside the 45 degree view without hand-tuning per level.
const CAMERA_FIT := 1.65
## The reward chest falls in from this height, over this many seconds.
const CHEST_FALL_HEIGHT := 8.0
const CHEST_FALL_TIME := 0.45
## How high it bounces on landing.
const CHEST_BOUNCE := 0.7
## Beat between the fortress falling and the "next level" button appearing.
const REWARD_BEAT := 1.4

@onready var grid: GameGrid = $GameGrid
@onready var camera: Camera3D = $Camera3D
@onready var modal_container: CanvasLayer = $ModalContainer
## Stand-in commander authored into the scene. The real ones are built at startup,
## one per AI card; this one is disabled and only kept so the scene stays openable.
@onready var ai: AIController = $AIController

# Changez simplement ce chemin pour basculer le jeu entier sur Quiz, Cartes, etc.
@export var current_battle_module_scene: PackedScene

## Coffre de récompense, lâché du ciel sur la forteresse qui vient de tomber.
@export var victory_chest_scene: PackedScene
## Taille du coffre, relative au rayon d'une case.
@export_range(0.2, 2.0, 0.05) var chest_scale: float = 1.2

## One commander per AI card, in seat order.
var _ai_commanders: Array[AIController] = []

var current_boss_target: HexTile = null

## Camera framing for the current board, restored after a fight.
var _camera_home: Vector3 = Vector3.ZERO
## Reward chest currently on the board, freed when the next level starts.
var _chest: Node3D
## CanvasLayer and button for the between-levels transition, built on first use.
var _continue_layer: CanvasLayer
var _continue_button: Button
## Set when the player's castle falls: the run is over and the board is frozen.
var _game_over: bool = false
## Set once a match's outcome has been ruled on, so it is only ever ruled once.
var _decided: bool = false
## Set when this player is out of a match that is still going on: the screen says so,
## but the board keeps running so the rest of the fight can be watched.
var _eliminated: bool = false
## Game over screen, built on the first defeat.
var _game_over_layer: CanvasLayer
var _game_over_label: Label
## Offered only to a player who is out while their match is still going on.
var _watch_button: Button

## Where the level's tallies stood when it began, so the recap reports only what
## this level produced.
var _level_started_ms: int = 0
var _level_gold_start: int = 0
var _level_troops_start: int = 0
## Recap line on the between-levels screen.
var _recap_label: Label
## Banner announcing the AI stepping up, built on first use.
var _banner_layer: CanvasLayer
var _banner_label: Label


func _ready() -> void:
	grid.boss_battle_triggered.connect(_on_boss_battle_triggered)
	grid.castle_fell.connect(_on_castle_fell)
	Net.match_decided.connect(_on_match_decided)
	# Only fires while this board exists, so it is always about the match in progress.
	Net.failed.connect(_on_connection_lost)
	_adapt_shadows_to_platform()
	_build_ai_commanders()
	frame_board()
	_begin_level_stats()


## Drops real-time shadows on the board in a browser build.
##
## The web export runs on WebGL through the GL Compatibility renderer, where a shadow
## pass is disproportionately expensive — every caster is drawn a second time, and the
## browser is already the slowest target the game has. The board is a flat plane of
## tiles seen from a fixed high angle, so the shadows it loses are the shallow ones
## around the buildings, not anything the player navigates by. Desktop keeps them.
func _adapt_shadows_to_platform() -> void:
	if not OS.has_feature("web"):
		return
	for found in find_children("*", "DirectionalLight3D", true, false):
		(found as DirectionalLight3D).shadow_enabled = false


## Gives every AI card its own commander. A controller plays exactly one seat, so a
## table with two AI cards needs two of them — which is why they are built here
## rather than authored into the scene. A VS match with no AI cards builds none, and
## then nothing on the board is automated.
func _build_ai_commanders() -> void:
	ai.process_mode = Node.PROCESS_MODE_DISABLED
	# In a match the AI cards are played by the table's owner alone. Every peer building
	# its own commanders would put one machine on every board, each marching the same
	# army somewhere different, and none of them agreeing.
	if GameState.in_room and not Net.is_host():
		return
	for seat in GameState.ai_seats:
		var commander: AIController = AIController.new()
		commander.seat = seat
		commander.name = "AI%d" % seat
		add_child(commander)
		_ai_commanders.append(commander)


## Starts or holds every AI commander at once.
func _set_ai_active(value: bool) -> void:
	for commander in _ai_commanders:
		commander.set_active(value)


## Snapshots the run totals so the next recap only counts this level.
func _begin_level_stats() -> void:
	_level_started_ms = Time.get_ticks_msec()
	_level_gold_start = GameState.gold_earned
	_level_troops_start = GameState.troops_raised


## What this level produced, in one line.
func _level_recap() -> String:
	var seconds: int = int((Time.get_ticks_msec() - _level_started_ms) / 1000.0)
	return "%d min %02d   ·   %d troupes levées   ·   %d or récoltés" % [
		int(seconds / 60.0), seconds % 60,
		GameState.troops_raised - _level_troops_start,
		GameState.gold_earned - _level_gold_start]


## A castle coming down decides the round: someone else's means the fight is won,
## your own means the run is over. (The parameter is not called "owner" because
## that shadows Node.owner.)
func _on_castle_fell(lost_by: int) -> void:
	if _game_over or _decided:
		return
	if GameState.in_room:
		_match_castle_fell(lost_by)
		return
	if lost_by == GameState.local_seat:
		_end_run()
		return
	current_boss_target = null
	trigger_stage_clear()


## A keep coming down in a match is not the end of anything by itself: it puts one
## player out, and the match is settled by the last keep still standing. So this only
## reports, and the ruling is left to the table's owner.
func _match_castle_fell(lost_by: int) -> void:
	current_boss_target = null
	if lost_by == GameState.local_seat:
		# Out of the running, but the fight goes on without us: the board keeps running
		# so the rest can be watched, and input is locked so being out means out.
		_eliminated = true
		grid.input_locked = true
		_show_result("ÉLIMINÉ",
			"Votre château est tombé. La partie continue sans vous.", true)
	else:
		_show_banner("CHÂTEAU J%d PRIS !" % (lost_by + 1))
	_check_match_outcome()


## Counts the keeps still standing and, once only one is left, rules on the match.
## Owner only, because two peers ruling at once could declare two different winners.
func _check_match_outcome() -> void:
	if _decided or not Net.is_host():
		return
	var standing: Array[int] = []
	for tile: HexTile in grid.tiles.values():
		if tile.tile_type != HexTile.TileType.FORTRESS_BOSS:
			continue
		if tile.owner_seat != HexTile.NEUTRAL and not standing.has(tile.owner_seat):
			standing.append(tile.owner_seat)
	if standing.size() > 1:
		return
	_decided = true
	Net.decide_match(standing[0] if standing.size() == 1 else -1)


## The relay dropped us, or the host closed the game.
##
## There is no picking this back up: a board is built from the seats the table had when
## the round started, and a reconnect lands on a fresh peer id — and therefore a
## different seat — so the castle on this screen would no longer be the one this player
## owns. Rather than freeze or drift in silence, the match is closed out and said so.
func _on_connection_lost(reason: String) -> void:
	if _decided or _game_over:
		return
	_decided = true
	_set_ai_active(false)
	grid.input_locked = true
	_show_result("CONNEXION PERDUE", reason)


## The owner's ruling, arriving on every screen at once.
func _on_match_decided(winner: int) -> void:
	if _decided and not _eliminated:
		return
	_decided = true
	# Nobody is marching anywhere after this, so the machines can stop thinking too and
	# the board stops taking clicks.
	_set_ai_active(false)
	grid.input_locked = true
	if winner == GameState.local_seat:
		_show_result("VICTOIRE", "Dernier château debout.")
	elif winner < 0:
		_show_result("MATCH NUL", "Plus un seul château debout.")
	else:
		_show_result("DÉFAITE", "Le château J%d a tenu jusqu'au bout." % (winner + 1))


func _on_boss_battle_triggered(attacker: HexTile, defender: HexTile) -> void:
	current_boss_target = defender
	# Hold the enemy commander while the fight plays out.
	_set_ai_active(false)

	# 1. Zoom cinématique de la caméra vers le Boss
	var cam_tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	cam_tween.tween_property(camera, "position", defender.position + Vector3(0, 4, 4), 0.6)
	cam_tween.tween_callback(open_battle_modal.bind(attacker, defender))


func open_battle_modal(attacker: HexTile, defender: HexTile) -> void:
	if current_battle_module_scene == null:
		push_error("MainLoop: current_battle_module_scene is not set; no fight can start.")
		return
	var module_instance: IBattleModule = current_battle_module_scene.instantiate()
	modal_container.add_child(module_instance)

	module_instance.init_battle(_describe(attacker), _describe(defender))
	module_instance.battle_completed.connect(_on_battle_resolved.bind(module_instance))


## Builds the dictionary contract [IBattleModule] documents. "power" is the value
## a module reads for its odds; the rest lets it name or inspect the two tiles.
func _describe(tile: HexTile) -> Dictionary:
	return {
		"power": tile.troop_count,
		"tile": tile,
		"coords": tile.grid_coords,
		"side": tile.owner_seat,
		"is_boss": tile.tile_type == HexTile.TileType.FORTRESS_BOSS,
	}


func _on_battle_resolved(is_victory: bool, module_node: Node) -> void:
	module_node.queue_free()
	# Harmless when the table has no AI cards: the loop simply has nothing to resume.
	_set_ai_active(true)

	# Dézoom de la caméra
	var cam_tween := create_tween()
	cam_tween.tween_property(camera, "position", _camera_home, 0.5)

	if is_victory and current_boss_target:
		# 2. La forteresse rouge laisse place au château du joueur, avec un gros
		# écrasement suivi d'un rebond.
		var taken_from: int = current_boss_target.owner_seat
		# Routed like every other action, so the keep changes hands on every screen at
		# once rather than only on the one that fought for it.
		grid.capture_stronghold(current_boss_target, GameState.local_seat)
		# A room has no next level to offer, so the victory stops at the board —
		# but it should still be announced, the same as a keep battered down.
		if GameState.in_room:
			_show_banner("CHÂTEAU J%d PRIS !" % (taken_from + 1))
		else:
			trigger_stage_clear()


func trigger_stage_clear() -> void:
	print("Niveau %d terminé : château ennemi détruit." % GameState.ai_level)
	_drop_victory_chest()
	# Let the chest land before offering the next level.
	await get_tree().create_timer(REWARD_BEAT).timeout
	_show_continue_button()


## 3. Le coffre tombe du ciel sur la case conquise et rebondit à l'atterrissage.
func _drop_victory_chest() -> void:
	if victory_chest_scene == null or current_boss_target == null:
		return
	if _chest != null:
		_chest.queue_free()
	# Parented to the grid so it shares the board's coordinate space.
	_chest = victory_chest_scene.instantiate()
	grid.add_child(_chest)

	var size: float = current_boss_target.scale.x * chest_scale
	var landing: Vector3 = current_boss_target.position + Vector3(0, current_boss_target.scale.x * 1.55, 0)
	_chest.scale = Vector3.ONE * size
	_chest.position = Vector3(landing.x, CHEST_FALL_HEIGHT, landing.z)

	var tween := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_chest, "position", landing, CHEST_FALL_TIME)
	# Rebond élastique à l'atterrissage.
	tween.tween_property(_chest, "position:y", landing.y + CHEST_BOUNCE, 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(_chest, "position:y", landing.y, 0.5).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


# --- Transition vers le niveau suivant ----------------------------------------

func _show_continue_button() -> void:
	if _continue_layer == null:
		_build_continue_ui()
	_recap_label.text = "NIVEAU %d TERMINÉ\n%s" % [GameState.ai_level, _level_recap()]
	_continue_button.text = "NIVEAU %d  →" % (GameState.ai_level + 1)
	_continue_layer.visible = true


## Built in code rather than authored in a scene: a recap line and one button,
## which keeps the whole transition in this script.
func _build_continue_ui() -> void:
	_continue_layer = CanvasLayer.new()
	_continue_layer.layer = 20 # above the HUD (1) and the battle modal (10)
	add_child(_continue_layer)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.04, 0.055, 0.08, 0.45)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_continue_layer.add_child(backdrop)

	_recap_label = Label.new()
	_recap_label.set_anchors_preset(Control.PRESET_CENTER)
	_recap_label.offset_left = -340.0
	_recap_label.offset_top = -140.0
	_recap_label.offset_right = 340.0
	_recap_label.offset_bottom = -70.0
	_recap_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recap_label.add_theme_font_size_override("font_size", 24)
	_recap_label.add_theme_color_override("font_color", Color("ffd166"))
	_recap_label.add_theme_color_override("font_outline_color", Color("1b2430"))
	_recap_label.add_theme_constant_override("outline_size", 6)
	_continue_layer.add_child(_recap_label)

	_continue_button = Button.new()
	_continue_button.text = "NIVEAU SUIVANT"
	_continue_button.set_anchors_preset(Control.PRESET_CENTER)
	_continue_button.offset_left = -170.0
	_continue_button.offset_top = -38.0
	_continue_button.offset_right = 170.0
	_continue_button.offset_bottom = 38.0
	_continue_button.add_theme_font_size_override("font_size", 26)
	_continue_button.add_theme_color_override("font_color", Color("1b2430"))
	_style_continue_button(_continue_button)
	_continue_button.pressed.connect(_on_continue_pressed)
	_continue_layer.add_child(_continue_button)

	_continue_layer.visible = false


## Warm clay button, so the transition sits with the rest of the game's palette
## instead of looking like a default OS widget.
func _style_continue_button(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("f5a623")
	normal.border_color = Color("1b2430")
	normal.set_border_width_all(4)
	normal.set_corner_radius_all(18)
	button.add_theme_stylebox_override("normal", normal)

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("ffc046")
	button.add_theme_stylebox_override("hover", hover)

	var held := normal.duplicate() as StyleBoxFlat
	held.bg_color = Color("d9821a")
	button.add_theme_stylebox_override("pressed", held)


func _on_continue_pressed() -> void:
	_continue_layer.visible = false
	if _chest != null:
		_chest.queue_free()
		_chest = null
	current_boss_target = null

	# Beating a level is what makes the AI harder: it comes back moving faster,
	# with a better fortified castle and more of a garrison behind it.
	GameState.raise_ai_level()
	grid.grid_radius = mini(BASE_GRID_RADIUS + GameState.ai_level - 1, MAX_GRID_RADIUS)
	grid.boss_troops = BASE_BOSS_TROOPS + BOSS_TROOPS_GROWTH * (GameState.ai_level - 1)
	grid.generate_grid()
	frame_board()
	_begin_level_stats()
	_show_banner("L'IA PASSE AU NIVEAU %d" % GameState.ai_level)


# --- Fin de partie ------------------------------------------------------------

## The player's castle is rubble: freeze the board and offer a fresh run.
func _end_run() -> void:
	_game_over = true
	_set_ai_active(false)
	grid.selected_tile = null
	grid.target_arrow.stop_aiming()
	# Cuts off the tiles' own processing too, so the board stops moving.
	grid.process_mode = Node.PROCESS_MODE_DISABLED
	_show_game_over()


func _show_game_over() -> void:
	_show_result("DÉFAITE",
		"Votre château est tombé au niveau %d" % GameState.ai_level)


## The card a match ends on, shared by every way it can finish — won, lost, or watched
## from the sidelines — so they all look the same and all leave the same way.
## `can_watch` is only true for a player who is out of a match that is still running.
func _show_result(title: String, subtitle: String, can_watch: bool = false) -> void:
	if _game_over_layer == null:
		_build_game_over_ui()
	_game_over_label.text = "%s\n%s" % [title, subtitle]
	_watch_button.visible = can_watch
	_game_over_layer.visible = true


## Puts the card away and leaves the match running, for a player who is out and would
## rather see how it ends than leave.
func _watch_match() -> void:
	_game_over_layer.visible = false


## Leaves a match for good: drops the connection and returns to the front end.
func _leave_to_menu() -> void:
	Net.leave_room()
	get_tree().change_scene_to_file(MENU_SCENE)


## Built in code like the level transition: one label and one button.
func _build_game_over_ui() -> void:
	_game_over_layer = CanvasLayer.new()
	_game_over_layer.layer = 30 # above everything else
	add_child(_game_over_layer)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.09, 0.05, 0.06, 0.74)
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_game_over_layer.add_child(backdrop)

	var column := VBoxContainer.new()
	column.set_anchors_preset(Control.PRESET_CENTER)
	column.offset_left = -260.0
	column.offset_top = -130.0
	column.offset_right = 260.0
	column.offset_bottom = 130.0
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 26)
	_game_over_layer.add_child(column)

	_game_over_label = Label.new()
	_game_over_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_game_over_label.add_theme_font_size_override("font_size", 32)
	_game_over_label.add_theme_color_override("font_color", Color("ffd9d0"))
	column.add_child(_game_over_label)

	var restart := Button.new()
	# In a match there is no run to restart — the table is other people — so the way
	# out leads back to the front end instead of rebuilding the same board.
	restart.text = "RETOUR AU MENU" if GameState.in_room else "NOUVELLE PARTIE"
	restart.custom_minimum_size = Vector2(300, 58)
	restart.add_theme_font_size_override("font_size", 22)
	_style_continue_button(restart)
	restart.pressed.connect(_leave_to_menu if GameState.in_room else _restart_run)
	column.add_child(restart)

	# Only ever offered to a player who is out while the match is not: it dismisses the
	# card so the rest of the fight can be watched, without letting them take part — the
	# board's input stays locked.
	_watch_button = Button.new()
	_watch_button.text = "CONTINUER À REGARDER"
	_watch_button.custom_minimum_size = Vector2(300, 52)
	_watch_button.add_theme_font_size_override("font_size", 19)
	_style_continue_button(_watch_button)
	_watch_button.pressed.connect(_watch_match)
	_watch_button.visible = false
	column.add_child(_watch_button)

	_game_over_layer.visible = false


## A fresh run: the AI drops back to level one and the board is rebuilt.
func _restart_run() -> void:
	GameState.reset()
	_game_over = false
	_game_over_layer.visible = false
	if _chest != null:
		_chest.queue_free()
		_chest = null
	current_boss_target = null
	grid.process_mode = Node.PROCESS_MODE_INHERIT
	grid.grid_radius = BASE_GRID_RADIUS
	grid.boss_troops = BASE_BOSS_TROOPS
	grid.generate_grid()
	# Rebuilds whatever table this peer is playing: generate_grid re-reads the seat
	# list from GameState and setup_initial_positions re-seats everyone on it. The AI
	# commanders were built once and keep their seats, so they just resume.
	_set_ai_active(true)
	frame_board()
	_begin_level_stats()


# --- Bannière d'escalade ------------------------------------------------------

## Flashes a message across the top of the screen for a couple of seconds, so a
## difficulty step is something the player sees rather than something they infer.
func _show_banner(text: String) -> void:
	if _banner_layer == null:
		_build_banner_ui()
	_banner_label.text = text
	_banner_label.modulate.a = 0.0
	_banner_layer.visible = true
	var tween := create_tween()
	tween.tween_property(_banner_label, "modulate:a", 1.0, 0.25)
	tween.tween_interval(1.7)
	tween.tween_property(_banner_label, "modulate:a", 0.0, 0.6)
	tween.tween_callback(func() -> void: _banner_layer.visible = false)


func _build_banner_ui() -> void:
	_banner_layer = CanvasLayer.new()
	_banner_layer.layer = 25
	add_child(_banner_layer)

	_banner_label = Label.new()
	_banner_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner_label.offset_left = -420.0
	_banner_label.offset_top = 108.0
	_banner_label.offset_right = 420.0
	_banner_label.offset_bottom = 178.0
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.add_theme_font_size_override("font_size", 40)
	_banner_label.add_theme_color_override("font_color", Color("ffd166"))
	_banner_label.add_theme_color_override("font_outline_color", Color("1b2430"))
	_banner_label.add_theme_constant_override("outline_size", 8)
	_banner_layer.add_child(_banner_label)
	_banner_layer.visible = false


## Pulls the camera back to whatever distance the current board needs.
func frame_board() -> void:
	var extent: float = grid.board_radius()
	_camera_home = Vector3(0, extent * CAMERA_FIT, extent * CAMERA_FIT)
	camera.position = _camera_home
