extends Control
## Screen 2: create a match, join one that is already open, or enter a code.
##
## Public and private are two genuinely different outcomes, so they are two buttons
## rather than one button with an option: pressing one is the whole answer.
##  - PUBLIQUE: announced on the lobby channel, listed for anyone, no code to share.
##  - PRIVÉE:  announced to nobody; the code is the only way in.
##  - PARTIE RAPIDE: the well-known common room, for two players who want a game
##    without arranging anything.
##
## The list of public matches is built from announcements over a second relay channel
## (see [LobbyDirectory]): the relay has no directory to ask, so the players announce
## their rooms to each other instead.

const WAITING_SCENE := "res://scenes/ui/waiting_room.tscn"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"

var _mode_online: Button
var _mode_local: Button
var _create_public_button: Button
var _create_private_button: Button
var _host_button: Button
var _join_button: Button
var _quick_button: Button
var _code_edit: LineEdit
var _status: Label

var _list_panel: PanelContainer
var _list_row: HBoxContainer
var _list_rows: VBoxContainer
var _list_note: Label


func _ready() -> void:
	Net.failed.connect(_on_failed)
	Lobby.rooms_changed.connect(_refresh_list)
	UiStyle.screen(self)
	UiStyle.title(self, "PARTIE VS", 22.0)
	_build()
	_sync_transport_ui()
	_update_status()


func _exit_tree() -> void:
	# Stop listening when the screen goes away: the list is this screen's job. This is
	# only the *browsing* half — a host still needs the channel to announce its room,
	# and that half keeps the channel alive on its own. Closing it outright here would
	# silence the very room this screen just opened, which is how a public game ended
	# up invisible to everybody else.
	Lobby.set_browsing(false)


func _build() -> void:
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.offset_left = -450.0
	# Clears the title band, so the card never sits under it.
	card.offset_top = -200.0
	card.offset_right = 450.0
	card.offset_bottom = 210.0
	card.add_theme_stylebox_override("panel", UiStyle.card_style())
	add_child(card)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	card.add_child(column)

	column.add_child(_build_mode_row())
	column.add_child(_build_create_row())
	# _build_room_list fills _list_row and hands back the labelled row to mount.
	column.add_child(_build_room_list())
	column.add_child(_build_join_row())

	_status = UiStyle.note(column, "")

	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(back_row)
	UiStyle.button(back_row, "RETOUR", _on_back_pressed, Vector2(170, 42), 17)


## A labelled row, so the screen reads top to bottom as: which mode, create, browse,
## join. Every row is built the same way, which is what makes it skimmable.
func _row(label_text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(108, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", UiStyle.MUTED)
	row.add_child(label)
	return row


func _build_mode_row() -> HBoxContainer:
	var row := _row("MODE")
	_mode_online = UiStyle.button(row, "EN LIGNE", _on_online_pressed, Vector2(190, 44))
	_mode_local = UiStyle.button(row, "LOCAL (LAN)", _on_local_pressed, Vector2(190, 44))
	# A browser has no raw sockets, so a web build only ever gets the relay. The button
	# is hidden there rather than offered and then refusing to work.
	_mode_local.visible = Net.local_transport_available()
	return row


## The two ways to open a game. Each button says what the other player will have to do
## to get in, because that is the only difference that matters to the host.
func _build_create_row() -> HBoxContainer:
	var row := _row("CRÉER")

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(column)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	column.add_child(buttons)

	_create_public_button = UiStyle.button(buttons, "PUBLIQUE",
		_on_create_public_pressed, Vector2(190, 52), 19)
	_create_private_button = UiStyle.button(buttons, "PRIVÉE",
		_on_create_private_pressed, Vector2(190, 52), 19)
	# LAN has no shared lobby to be listed in, so there "public" is meaningless and the
	# single button just opens a server.
	_host_button = UiStyle.button(buttons, "HÉBERGER", _on_host_pressed, Vector2(190, 52), 19)
	_host_button.visible = false

	var hint := Label.new()
	hint.text = "PUBLIQUE : visible par tous, aucun code à partager.   PRIVÉE : rejointe par son code."
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", UiStyle.MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	return row


## The browsable list of public matches. Built once and refilled on every change.
##
## Returns the whole labelled row, not just the panel: the label carries the row's name
## and would be orphaned (and invisible) if only the panel were returned.
func _build_room_list() -> HBoxContainer:
	var row := _row("OUVERTES")

	_list_panel = PanelContainer.new()
	_list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# A floor on the height, so the box does not collapse to nothing when the list is
	# empty — an empty list still has to look like a list, or "no games open" reads as
	# "the list is broken".
	_list_panel.custom_minimum_size = Vector2(0, 46)
	_list_panel.add_theme_stylebox_override("panel", UiStyle.seat_style(false))
	row.add_child(_list_panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	_list_panel.add_child(column)

	_list_rows = VBoxContainer.new()
	_list_rows.add_theme_constant_override("separation", 4)
	column.add_child(_list_rows)

	_list_note = Label.new()
	_list_note.add_theme_font_size_override("font_size", 14)
	_list_note.add_theme_color_override("font_color", UiStyle.MUTED)
	_list_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_list_note)
	_list_row = row
	return row


## Joining: the code field, the button that uses it, and the common room. All three
## put the player into somebody else's game, which is why they share one row.
func _build_join_row() -> HBoxContainer:
	var row := _row("REJOINDRE")

	_code_edit = LineEdit.new()
	_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_edit.custom_minimum_size = Vector2(150, 44)
	_code_edit.add_theme_font_size_override("font_size", 18)
	_code_edit.placeholder_text = "code"
	_code_edit.text_submitted.connect(func(_t: String) -> void: _on_join_pressed())
	row.add_child(_code_edit)

	_join_button = UiStyle.button(row, "PAR CODE", _on_join_pressed, Vector2(140, 44), 17)
	_quick_button = UiStyle.button(row, "RAPIDE", _on_quick_pressed, Vector2(130, 44), 17)
	return row


# --- Transport ----------------------------------------------------------------

func _on_online_pressed() -> void:
	Net.select_online_mode()
	_sync_transport_ui()
	_update_status()


func _on_local_pressed() -> void:
	Net.select_local_mode()
	_sync_transport_ui()
	_update_status()


## Relabels whatever the transport decides. The code field is only rewritten here —
## never on a redraw — so it can never clobber a code halfway through being typed.
func _sync_transport_ui() -> void:
	var online: bool = Net.is_online_mode()
	_create_public_button.visible = online
	_create_private_button.visible = online
	_host_button.visible = not online
	# Browsing and the common room are relay-only ideas: a LAN match has no shared
	# lobby to list in, so both would be buttons that lie about what they do.
	_quick_button.visible = online
	_join_button.text = "PAR CODE" if online else "REJOINDRE"
	if online:
		Lobby.set_browsing(true)
	else:
		Lobby.set_browsing(false)
	UiStyle.set_toggle(_mode_online, online)
	UiStyle.set_toggle(_mode_local, not online)
	_refresh_list()


func _update_status() -> void:
	if Net.is_online_mode():
		_status.text = ("Crée une partie PUBLIQUE pour qu'elle apparaisse dans OUVERTES, "
			+ "ou PRIVÉE et donne son code.")
	else:
		_status.text = "Héberge sur le port %d, ou rejoins l'adresse de l'hôte.\nPare-feu : autorise Godot au premier hébergement." % Net.port


# --- Liste des parties --------------------------------------------------------

## Redraws the list of open rooms. Only shown online: the other transports have no
## shared lobby to browse.
func _refresh_list() -> void:
	if _list_rows == null:
		return
	# The whole labelled row hides together offline: a bare list panel with no name on
	# it reads as a stray box.
	var online: bool = Net.is_online_mode()
	_list_row.visible = online
	if not online:
		return

	for child in _list_rows.get_children():
		_list_rows.remove_child(child)
		child.queue_free()

	var rooms: Array[Dictionary] = Lobby.rooms()
	if rooms.is_empty():
		_list_note.text = "Aucune partie publique pour l'instant."
		_list_note.visible = true
		return
	_list_note.visible = false
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
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", UiStyle.INK)
	row.add_child(label)

	# A full room is shown but not offered: joining it would only bounce off the table
	# being full, and a dead button is clearer than a refusal after the click.
	var full: bool = int(entry.get("count", 0)) >= int(entry.get("max", 4))
	UiStyle.button(row, "REJOINDRE", _on_room_picked.bind(str(entry.get("code", ""))),
		Vector2(130, 36), 15).disabled = full
	return row


# --- Actions ------------------------------------------------------------------

## A public match: no code to share and none shown. It is announced on the lobby
## channel, which is how everybody else finds it.
func _on_create_public_pressed() -> void:
	Net.public_room = true
	Net.join_match(_fresh_code())
	get_tree().change_scene_to_file(WAITING_SCENE)


## A private match: nothing is announced, and the generated code is the only way in.
## It is put in the field so the host can read it out.
func _on_create_private_pressed() -> void:
	var code: String = _fresh_code()
	_code_edit.text = code
	Net.public_room = false
	Net.join_match(code)
	get_tree().change_scene_to_file(WAITING_SCENE)


## LAN hosting: a real server on this machine, with no lobby to be listed in.
func _on_host_pressed() -> void:
	Net.public_room = false
	Net.open_match()
	get_tree().change_scene_to_file(WAITING_SCENE)


func _on_join_pressed() -> void:
	var code: String = _code_edit.text.strip_edges()
	# Joining needs a code to aim at: an empty field would silently reuse whatever room
	# this peer last entered, which is rarely what the player meant.
	if code.is_empty():
		_status.text = "Saisis le code de la partie à rejoindre."
		return
	Net.public_room = false
	Net.join_match(code)
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


## A short code for a room, generated rather than demanded. Public rooms use it too —
## it is the internal name the relay routes by — but a public host never has to read
## it out or type it, which is the whole point of the public path.
func _fresh_code() -> String:
	return "hexa-%04d" % (randi() % 10000)
