extends Control
## Screen 3: the waiting room, where a match is agreed before it starts.
##
## Four cards, one per seat. A card holds a player, an AI the host placed there, or
## nothing at all. Each player marks themselves ready, and the round begins by itself
## the moment every occupied card is ready and there are two of them or more — so
## nobody has to be handed a start button and nobody can start it alone.
##
## The chat is here because a waiting room without one is just a countdown: the host
## needs somewhere to say "give me one minute" and to pass the room code around.

const BOARD_SCENE := "res://scenes/main.tscn"
const VS_SCENE := "res://scenes/ui/vs_menu.tscn"

var _room_label: Label
var _card_panels: Array[PanelContainer] = []
var _card_bodies: Array[VBoxContainer] = []
var _ready_button: Button
var _chat_log: RichTextLabel
var _chat_edit: LineEdit
var _status: Label


func _ready() -> void:
	Net.seats_changed.connect(_refresh)
	Net.chat_line.connect(_on_chat_line)
	Net.failed.connect(_on_failed)
	Net.game_started.connect(_on_game_started)
	UiStyle.screen(self)
	_build()
	_refresh()


# --- Construction --------------------------------------------------------------

func _build() -> void:
	UiStyle.title(self, "SALLE D'ATTENTE", 16.0)

	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("margin_left", 44)
	root.add_theme_constant_override("margin_right", 44)
	root.add_theme_constant_override("margin_top", 88)
	root.add_theme_constant_override("margin_bottom", 18)
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	root.add_child(column)

	# What the host reads out to invite people.
	_room_label = UiStyle.heading(column, "", 21, UiStyle.PALE)

	# The four cards, sharing the width equally.
	var cards_row := HBoxContainer.new()
	cards_row.add_theme_constant_override("separation", 12)
	column.add_child(cards_row)
	for seat in Net.MAX_PLAYERS:
		cards_row.add_child(_build_card(seat))

	_ready_button = UiStyle.button(column, "PRÊT", _on_ready_pressed, Vector2(320, 54), 22)
	_ready_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	column.add_child(_build_chat())

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 14)
	column.add_child(bottom)
	UiStyle.button(bottom, "QUITTER LA SALLE", _on_leave_pressed, Vector2(230, 42), 17)
	_status = UiStyle.note(bottom, "", 16, UiStyle.PALE)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL


## The frame of one seat card. Its contents are rebuilt on every refresh, because
## what sits on a card changes as people come, go and ready up — so the seat number
## is not needed here, only its position in the row.
func _build_card(_seat: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.custom_minimum_size = Vector2(0, 150)
	card.add_theme_stylebox_override("panel", UiStyle.seat_style(false))

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	card.add_child(body)

	_card_panels.append(card)
	_card_bodies.append(body)
	return card


func _build_chat() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiStyle.card_style())
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)

	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.custom_minimum_size = Vector2(0, 96)
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_font_size_override("normal_font_size", 17)
	_chat_log.add_theme_color_override("default_color", UiStyle.INK)
	column.add_child(_chat_log)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)

	_chat_edit = LineEdit.new()
	_chat_edit.placeholder_text = "Écris un message…"
	_chat_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_edit.custom_minimum_size = Vector2(0, 42)
	_chat_edit.add_theme_font_size_override("font_size", 18)
	_chat_edit.text_submitted.connect(func(_line: String) -> void: _on_send_pressed())
	row.add_child(_chat_edit)

	UiStyle.button(row, "ENVOYER", _on_send_pressed, Vector2(140, 42), 17)
	return panel


# --- Affichage -----------------------------------------------------------------

func _refresh() -> void:
	_room_label.text = _room_line()
	for seat in _card_panels.size():
		_fill_card(seat)
	_update_ready_button()
	_status.text = _status_line()


## Rebuilds one card from the table.
func _fill_card(seat: int) -> void:
	var panel: PanelContainer = _card_panels[seat]
	var body: VBoxContainer = _card_bodies[seat]
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()

	var occupied: bool = not Net.is_seat_empty(seat)
	panel.add_theme_stylebox_override("panel", UiStyle.seat_style(occupied))

	# The stripe is the seat's own colour — the same one its castle will fly on the
	# board, so a player can already tell which corner they are getting.
	var stripe := ColorRect.new()
	stripe.color = GameState.seat_color(seat)
	stripe.custom_minimum_size = Vector2(0, 8)
	body.add_child(stripe)

	var who := Label.new()
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	who.add_theme_font_size_override("font_size", 20)
	who.add_theme_color_override("font_color", UiStyle.INK)
	body.add_child(who)

	var state := Label.new()
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	state.add_theme_font_size_override("font_size", 15)
	body.add_child(state)

	if Net.is_seat_empty(seat):
		who.text = "CARTE LIBRE"
		state.text = "personne pour l'instant"
		state.add_theme_color_override("font_color", UiStyle.MUTED)
		if Net.is_host():
			UiStyle.button(body, "AJOUTER UNE IA", _on_toggle_ai.bind(seat),
				Vector2(0, 36), 15)
	elif Net.is_seat_ai(seat):
		who.text = "IA  ·  siège %d" % (seat + 1)
		state.text = "toujours prête"
		state.add_theme_color_override("font_color", UiStyle.GO)
		if Net.is_host():
			UiStyle.button(body, "RETIRER L'IA", _on_toggle_ai.bind(seat),
				Vector2(0, 36), 15)
	else:
		var peer: int = int(Net.slots[seat]["peer"])
		var mine: bool = peer == multiplayer.get_unique_id()
		who.text = "TOI" if mine else "JOUEUR %d" % (seat + 1)
		state.text = "invité" if not mine else "toi"
		if Net.is_host():
			state.text = "hôte" if mine else "invité"
		# "marked_ready" rather than "ready": Node already has a `ready` signal.
		var marked_ready: bool = bool(Net.slots[seat]["ready"])
		if marked_ready:
			state.text += "   ·   PRÊT"
			state.add_theme_color_override("font_color", UiStyle.GO)
		else:
			state.text += "   ·   en attente…"
			state.add_theme_color_override("font_color", UiStyle.MUTED)


## Ready is the only action that can start the round, so its label says what the
## table is still missing.
func _update_ready_button() -> void:
	if Net.my_seat() < 0:
		_ready_button.disabled = true
		_ready_button.text = "EN ATTENTE D'UNE CARTE…"
		UiStyle.paint_button(_ready_button, UiStyle.CLAY)
		return
	# "marked_ready" rather than "ready": Node already has a `ready` signal.
	var marked_ready: bool = Net.is_local_ready()
	_ready_button.text = "ANNULER LE PRÊT" if marked_ready else "PRÊT"
	# Ready is pointless before there is somebody to play against: a round needs two
	# cards, and the AI always answers, so one human plus one AI is enough.
	_ready_button.disabled = not marked_ready and _human_count() < 2 \
		and Net.active_count() < 2
	UiStyle.paint_button(_ready_button, UiStyle.GO if marked_ready else UiStyle.CLAY)


func _human_count() -> int:
	var humans: int = 0
	for i in Net.slots.size():
		if not Net.is_seat_empty(i) and not Net.is_seat_ai(i):
			humans += 1
	return humans


## What the host reads out to invite people. A LAN match has no code to share, so the
## address is the invitation instead.
func _room_line() -> String:
	if not Net.connected:
		return "Connexion en cours…"
	if not Net.is_online_mode():
		return "Partie locale — les autres rejoignent %s (port %d)" % [Net.address, Net.port]
	if Net.active_count() <= 1:
		return "Salle « %s » — donne ce code à tes amis" % Net.room
	return "Salle « %s » — %d cartes occupées" % [Net.room, Net.active_count()]


## One sentence about what the table is waiting for.
func _status_line() -> String:
	if not Net.connected:
		return "Pas encore connecté."
	if Net.active_count() < 2:
		return "Il faut au moins deux cartes occupées — ajoute une IA si personne ne rejoint."
	if Net.all_ready():
		return "Tout le monde est prêt — la partie démarre…"
	var waiting: Array[String] = []
	for i in Net.slots.size():
		if Net.is_seat_empty(i) or Net.is_seat_ai(i):
			continue
		if not bool(Net.slots[i]["ready"]):
			waiting.append("J%d" % (i + 1))
	return "En attente de : %s" % ", ".join(waiting)


# --- Actions -------------------------------------------------------------------

func _on_ready_pressed() -> void:
	Net.set_ready(not Net.is_local_ready())


func _on_toggle_ai(seat: int) -> void:
	Net.toggle_ai(seat)


func _on_send_pressed() -> void:
	Net.send_chat(_chat_edit.text)
	_chat_edit.clear()
	_chat_edit.grab_focus()


## A line of chat. The speaker's name is painted in their seat colour — the same one
## as their castle — so the room and the board agree about who is who.
func _on_chat_line(seat: int, text: String, _mine: bool) -> void:
	var speaker: String = "Système"
	var colour: Color = UiStyle.MUTED
	if seat >= 0:
		colour = GameState.seat_color(seat)
		if seat == GameState.local_seat:
			speaker = "Toi"
		elif GameState.is_ai_seat(seat):
			speaker = "IA %d" % (seat + 1)
		else:
			speaker = "Joueur %d" % (seat + 1)
	# Escape the opening bracket, or a message containing one is read as markup.
	_chat_log.append_text("[color=#%s]%s[/color]  %s\n" % [
		colour.to_html(false), speaker, text.replace("[", "[lb]")])


func _on_leave_pressed() -> void:
	Net.leave_room()
	get_tree().change_scene_to_file(VS_SCENE)


func _on_game_started() -> void:
	get_tree().change_scene_to_file(BOARD_SCENE)


func _on_failed(reason: String) -> void:
	_status.text = reason
