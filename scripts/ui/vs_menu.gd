extends Control
## Screen 2: create a match, or join one that already exists.
##
## The two transports need different questions here. Online is a room code and
## nothing else — the relay has no game server, so the first peer in a room owns it
## and "creating" is just entering a room nobody else is in yet. Local is an address,
## and there somebody really does have to open the server, which is why only that
## mode grows a separate host button.

const WAITING_SCENE := "res://scenes/ui/waiting_room.tscn"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

var _mode_online: Button
var _mode_local: Button
var _target_label: Label
var _target_edit: LineEdit
var _create_button: Button
var _join_button: Button
var _status: Label


func _ready() -> void:
	Net.failed.connect(_on_failed)
	UiStyle.screen(self)
	UiStyle.title(self, "PARTIE VS", 26.0)
	_build()
	_sync_transport_ui()
	_update_status()


func _build() -> void:
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -420.0
	card.offset_top = -170.0
	card.offset_right = 420.0
	card.offset_bottom = 200.0
	card.add_theme_stylebox_override("panel", UiStyle.card_style())
	add_child(card)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 16)
	card.add_child(column)

	# Which transport. Online asks nothing of the player; local is the shortcut for
	# playing on one machine or across a LAN.
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	column.add_child(mode_row)

	var mode_label := Label.new()
	mode_label.text = "MODE"
	mode_label.custom_minimum_size = Vector2(120, 0)
	mode_label.add_theme_font_size_override("font_size", 20)
	mode_label.add_theme_color_override("font_color", UiStyle.INK)
	mode_row.add_child(mode_label)

	_mode_online = UiStyle.button(mode_row, "EN LIGNE", _on_online_pressed, Vector2(190, 46))
	_mode_local = UiStyle.button(mode_row, "LOCAL (LAN)", _on_local_pressed, Vector2(190, 46))
	# A browser has no raw sockets, so a web build only ever gets the relay. The
	# button is hidden there rather than offered and then refusing to work.
	_mode_local.visible = Net.local_transport_available()

	# The room code, or the address, depending on the transport.
	var target_row := HBoxContainer.new()
	target_row.add_theme_constant_override("separation", 12)
	column.add_child(target_row)

	_target_label = Label.new()
	_target_label.custom_minimum_size = Vector2(120, 0)
	_target_label.add_theme_font_size_override("font_size", 20)
	_target_label.add_theme_color_override("font_color", UiStyle.INK)
	target_row.add_child(_target_label)

	_target_edit = LineEdit.new()
	_target_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_target_edit.custom_minimum_size = Vector2(240, 46)
	_target_edit.add_theme_font_size_override("font_size", 20)
	target_row.add_child(_target_edit)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)

	_create_button = UiStyle.button(buttons, "CRÉER UNE PARTIE", _on_create_pressed,
		Vector2(250, 56), 19)
	_join_button = UiStyle.button(buttons, "REJOINDRE", _on_join_pressed,
		Vector2(190, 56), 19)

	_status = UiStyle.note(column, "")

	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(back_row)
	UiStyle.button(back_row, "RETOUR", _on_back_pressed, Vector2(170, 44), 17)


func _on_online_pressed() -> void:
	Net.select_online_mode()
	_sync_transport_ui()
	_update_status()


func _on_local_pressed() -> void:
	Net.select_local_mode()
	_sync_transport_ui()
	_update_status()


## Relabels whatever the transport decides. The field is only rewritten here — never
## on a redraw — so it can never clobber a code halfway through being typed.
func _sync_transport_ui() -> void:
	var online: bool = Net.is_online_mode()
	_target_label.text = "SALON" if online else "ADRESSE"
	_create_button.text = "CRÉER UNE PARTIE" if online else "HÉBERGER"
	_join_button.text = "REJOINDRE" if online else "REJOINDRE CETTE ADRESSE"
	if online:
		# Left empty on purpose: creating with no code picks a fresh one, so nobody
		# lands by accident in a room somebody else opened and then abandoned.
		_target_edit.text = ""
		_target_edit.placeholder_text = "vide → code au hasard"
	else:
		_target_edit.text = Net.address
		_target_edit.placeholder_text = Net.DEFAULT_ADDRESS
	UiStyle.set_toggle(_mode_online, online)
	UiStyle.set_toggle(_mode_local, not online)


func _update_status() -> void:
	if Net.is_online_mode():
		_status.text = ("Crée une partie et donne le code à tes amis ;\n"
			+ "ou saisis le code qu'on t'a donné pour rejoindre la leur.")
	else:
		_status.text = "Héberge sur le port %d, ou rejoins l'adresse de l'hôte.\nPare-feu : autorise Godot au premier hébergement." % Net.port


## Creating a match. Online that means choosing a code and entering the room — the
## first peer there owns it, so there is nothing else to do. Locally it means
## actually opening a server.
func _on_create_pressed() -> void:
	if Net.is_online_mode():
		var code: String = _target_edit.text.strip_edges()
		if code.is_empty():
			code = _fresh_code()
		_target_edit.text = code
		Net.join_match(code)
	else:
		Net.open_match()
	get_tree().change_scene_to_file(WAITING_SCENE)


func _on_join_pressed() -> void:
	# Joining needs a code to aim at: an empty field would silently reuse whatever
	# room this peer last entered, which is rarely what the player meant.
	if _target_edit.text.strip_edges().is_empty():
		_status.text = "Saisis le code de la partie à rejoindre."
		return
	Net.join_match(_target_edit.text)
	get_tree().change_scene_to_file(WAITING_SCENE)


func _on_back_pressed() -> void:
	Net.leave_room()
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_failed(reason: String) -> void:
	_status.text = reason


## A short code the host can read out loud. Generated rather than demanded, so
## creating is one click; it lands in the field so it can be shared or changed.
func _fresh_code() -> String:
	return "hexa-%04d" % (randi() % 10000)
