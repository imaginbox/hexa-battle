extends Control
## Screen 1 of the front end: pick a mode.
##
## Two modes and nothing else, because everything after this point branches on that
## one choice — solo walks straight onto the board, VS goes through a room.

const SOLO_SCENE := "res://scenes/main.tscn"
const VS_SCENE := "res://scenes/ui/vs_menu.tscn"


func _ready() -> void:
	UiStyle.screen(self)
	UiStyle.title(self, "HEXA BATTLE")
	_build()


func _build() -> void:
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -300.0
	card.offset_top = -180.0
	card.offset_right = 300.0
	card.offset_bottom = 175.0
	card.add_theme_stylebox_override("panel", UiStyle.card_style())
	add_child(card)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 20)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(column)

	UiStyle.button(column, "SOLO", _on_solo_pressed, Vector2(360, 68), 25)
	UiStyle.button(column, "VS   ·   MULTIJOUEUR", _on_vs_pressed, Vector2(360, 68), 25)

	var hint := UiStyle.note(column, "", 16)
	hint.text = "SOLO — campagne contre l'IA, niveau après niveau.\nVS — une partie entre joueurs, en ligne ou en local."


## Solo needs no connection at all. Leaving the session also has [Net] republish the
## fixed two-card table the single-player run is played on, so this is just a scene
## change and the board knows what to build.
func _on_solo_pressed() -> void:
	Net.leave_room()
	get_tree().change_scene_to_file(SOLO_SCENE)


func _on_vs_pressed() -> void:
	get_tree().change_scene_to_file(VS_SCENE)
