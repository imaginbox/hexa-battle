extends Control
## Screen 2: create a match, or join one that already exists.
##
## Three ways in, and they are genuinely different rather than three labels for one
## thing:
##  - a private match, found only by the code its host was given;
##  - a public match, listed for anyone browsing the lobby;
##  - the common room, for two players who just want a game and neither wants to
##    arrange anything.
##
## The list of public matches is built from announcements over a second relay channel
## (see [LobbyDirectory]): the relay has no directory to ask, so the players announce
## their rooms to each other instead.

const WAITING_SCENE := "res://scenes/ui/waiting_room.tscn"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

var _mode_online: Button
var _mode_local: Button
var _target_label: Label
var _target_edit: LineEdit
var _create_public_button: Button
var _create_private_button: Button
var _join_button: Button
var _quick_button: Button
var _status: Label

var _list_panel: PanelContainer
var _list_rows: VBoxContainer
var _list_note: Label


func _ready() -> void:
	Net.failed.connect(_on_failed)
	Lobby.rooms_changed.connect(_refresh_list)
	UiStyle.screen(self)
	UiStyle.title(self, "PARTIE VS", 26.0)
	_build()
	_sync_transport_ui()
	_update_status()


func _exit_tree() -> void:
	# Browsing is only needed while this screen is up, and the lobby channel is a whole
	# extra socket. Closing on the way out keeps a match from carrying a second, idle
	# connection it never uses.
	Lobby.close()


func _build() -> void:
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -430.0
	# Clears the title band (it runs to y≈92), so the card never sits under it.
	card.offset_top = -252.0
	card.offset_right = 430.0
	card.offset_bottom = 258.0
	card.add_theme_stylebox_override("panel", UiStyle.card_style())
	add_child(card)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
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

	# Creating is two buttons because public and private are two different outcomes,
	# not one outcome with an option: which one is pressed is the whole answer.
	var create_row := HBoxContainer.new()
	create_row.add_theme_constant_override("separation", 12)
	create_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(create_row)

	_create_public_button = UiStyle.button(create_row, "CRÉER PUBLIQUE",
		_on_create_public_pressed, Vector2(215, 54), 19)
	_create_private_button = UiStyle.button(create_row, "CRÉER PRIVÉE",
		_on_create_private_pressed, Vector2(215, 54), 19)

	column.add_child(_build_room_list())

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 12)
	join_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(join_row)

	_join_button = UiStyle.button(join_row, "REJOINDRE PAR CODE", _on_join_pressed,
		Vector2(300, 50), 18)
	_quick_button = UiStyle.button(join_row, "PARTIE RAPIDE", _on_quick_pressed,
		Vector2(300, 50), 18)

	_status = UiStyle.note(column, "")

	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(back_row)
	UiStyle.button(back_row, "RETOUR", _on_back_pressed, Vector2(170, 42), 17)


## The browsable list of public matches. Built once and refilled on every change, so
## the rows live in one place rather than being added and removed around a heading.
func _build_room_list() -> PanelContainer:
	_list_panel = PanelContainer.new()
	_list_panel.add_theme_stylebox_override("panel", UiStyle.seat_style(false))

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	_list_panel.add_child(column)

	var heading := Label.new()
	heading.text = "PARTIES OUVERTES"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 17)
	heading.add_theme_color_override("font_color", UiStyle.MUTED)
	column.add_child(heading)

	_list_rows = VBoxContainer.new()
	_list_rows.add_theme_constant_override("separation", 4)
	column.add_child(_list_rows)

	_list_note = Label.new()
	_list_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_list_note.add_theme_font_size_override("font_size", 15)
	_list_note.add_theme_color_override("font_color", UiStyle.MUTED)
	column.add_child(_list_note)

	_list_panel.visible = false
	return _list_panel


# --- Transport ----------------------------------------------------------------

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
	_create_public_button.text = "CRÉER PUBLIQUE" if online else "HÉBERGER"
	_create_private_button.text = "CRÉER PRIVÉE" if online else "CODE PRIVÉ"
	_create_private_button.visible = online
	_join_button.text = "REJOINDRE PAR CODE" if online else "REJOINDRE CETTE ADRESSE"
	# Browsing and the common room are relay-only ideas: a LAN match has no shared
	# lobby to list in, so both would be buttons that lie about what they do.
	_quick_button.visible = online
	if online:
		# Left empty on purpose: creating with no code picks a fresh one, so nobody
		# lands by accident in a room somebody else opened and then abandoned.
		_target_edit.text = ""
		_target_edit.placeholder_text = "vide → code au hasard"
		# Opening the channel here is what makes the list appear at all; it stays up
		# for as long as the screen does.
		Lobby.open()
	else:
		_target_edit.text = Net.address
		_target_edit.placeholder_text = Net.DEFAULT_ADDRESS
		Lobby.close()
	UiStyle.set_toggle(_mode_online, online)
	UiStyle.set_toggle(_mode_local, not online)
	_refresh_list()


func _update_status() -> void:
	if Net.is_online_mode():
		_status.text = ("Crée une partie PUBLIQUE pour qu'elle apparaisse dans la liste, "
			+ "ou PRIVÉE et donne son code.\nPARTIE RAPIDE rejoint le salon commun.")
	else:
		_status.text = "Héberge sur le port %d, ou rejoins l'adresse de l'hôte.\nPare-feu : autorise Godot au premier hébergement." % Net.port


# --- Liste des parties --------------------------------------------------------

## Redraws the list of open rooms. Only shown online: the other transports have no
## shared lobby to browse.
func _refresh_list() -> void:
	if _list_rows == null:
		return
	_list_rows.visible = Net.is_online_mode()
	_list_note.visible = Net.is_online_mode()
	if not Net.is_online_mode():
		_list_panel.visible = false
		return

	for child in _list_rows.get_children():
		_list_rows.remove_child(child)
		child.queue_free()

	var rooms: Array[Dictionary] = Lobby.rooms()
	_list_panel.visible = true
	if rooms.is_empty():
		_list_note.text = "Aucune partie publique pour l'instant — crée la tienne."
		return
	_list_note.text = ""
	for entry in rooms:
		_list_rows.add_child(_build_room_row(entry))


## One row per open room: what it is called, how full it is, and a button to join it.
func _build_room_row(entry: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := Label.new()
	label.text = "%s   ·   %d/%d joueurs" % [
		str(entry.get("code", "?")),
		int(entry.get("count", 0)),
		int(entry.get("max", 4))]
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", UiStyle.INK)
	row.add_child(label)

	# A full room is shown but not offered: joining it would only bounce off the table
	# being full, and a dead button is clearer than a refusal after the click.
	var full: bool = int(entry.get("count", 0)) >= int(entry.get("max", 4))
	UiStyle.button(row, "REJOINDRE", _on_room_picked.bind(str(entry.get("code", ""))),
		Vector2(140, 38), 16).disabled = full
	return row


# --- Actions ------------------------------------------------------------------

## A public match: same room code as a private one, but it is announced on the lobby
## channel so it shows up in everyone's list.
func _on_create_public_pressed() -> void:
	if Net.is_online_mode():
		var code: String = _target_edit.text.strip_edges()
		if code.is_empty():
			code = _fresh_code()
		_target_edit.text = code
		Net.public_room = true
		Net.join_match(code)
	else:
		Net.public_room = false
		Net.open_match()
	get_tree().change_scene_to_file(WAITING_SCENE)


## A private match: nothing is announced, and the code is the only way in.
func _on_create_private_pressed() -> void:
	var code: String = _target_edit.text.strip_edges()
	if code.is_empty():
		code = _fresh_code()
	_target_edit.text = code
	Net.public_room = false
	Net.join_match(code)
	get_tree().change_scene_to_file(WAITING_SCENE)


func _on_join_pressed() -> void:
	# Joining needs a code to aim at: an empty field would silently reuse whatever
	# room this peer last entered, which is rarely what the player meant.
	if _target_edit.text.strip_edges().is_empty():
		_status.text = "Saisis le code de la partie à rejoindre."
		return
	Net.public_room = false
	Net.join_match(_target_edit.text)
	get_tree().change_scene_to_file(WAITING_SCENE)


## Straight in from the list. The code is already known, so nothing is typed.
func _on_room_picked(code: String) -> void:
	if code.is_empty():
		return
	Net.public_room = false
	Net.join_match(code)
	get_tree().change_scene_to_file(WAITING_SCENE)


## The common room, so two players who both picked "quick match" meet without either
## having to pass a code around.
func _on_quick_pressed() -> void:
	Net.public_room = false
	Net.join_match(Net.DEFAULT_ROOM)
	get_tree().change_scene_to_file(WAITING_SCENE)


func _on_back_pressed() -> void:
	Net.public_room = false
	Net.leave_room()
	get_tree().change_scene_to_file(MENU_SCENE)


func _on_failed(reason: String) -> void:
	_status.text = reason


## A short code the host can read out loud. Generated rather than demanded, so
## creating is one click; it lands in the field so it can be shared or changed.
func _fresh_code() -> String:
	return "hexa-%04d" % (randi() % 10000)
