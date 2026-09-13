class_name UiStyle
extends RefCounted
## Shared look for the game's overlay screens.
##
## Three screens now sit in front of the board — the menu, the VS screen and the
## waiting room — and they should read as one family rather than three takes on the
## same palette. Everything they have in common lives here.
##
## Static, like [GameState], so a screen can style itself with no node to thread
## around and no scene to inherit from: each screen stays a bare Control whose whole
## layout lives in its own script.

const INK := Color("1b2430")
const CREAM := Color(0.968627, 0.945098, 0.898039, 0.98)
const CLAY := Color("f5a623")
const TOGGLE_OFF := Color("c9c2b6")
const MUTED := Color("5b6b7f")
## Text that sits on the dark backdrop rather than on a cream card.
const PALE := Color("dfe6ee")
const BACKDROP := Color("17212b")
const ACCENT := Color("ffd166")
## The "ready" state on a seat card and on the ready button.
const GO := Color("3fae63")

## Built on first use and reused, so a screen full of buttons does not allocate a
## style box per button.
static var _button_styles: Dictionary = {}


## Paints the full-screen backdrop every overlay sits on. Added first, so it is
## behind whatever the screen builds next.
static func screen(root: Control) -> void:
	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(backdrop)


## The game's wordmark, across the top of a screen.
static func title(parent: Node, text: String, top: float = 44.0) -> Label:
	var label := Label.new()
	label.text = text
	label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	label.offset_left = -460.0
	label.offset_top = top
	label.offset_right = 460.0
	label.offset_bottom = top + 66.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 52)
	label.add_theme_color_override("font_color", ACCENT)
	parent.add_child(label)
	return label


static func heading(parent: Node, text: String, size: int = 24,
		color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


## A quiet line of supporting text.
static func note(parent: Node, text: String, size: int = 17,
		color: Color = MUTED) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


static func card_style() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = CREAM
	box.border_color = INK
	box.set_border_width_all(4)
	box.set_corner_radius_all(18)
	box.content_margin_left = 22.0
	box.content_margin_right = 22.0
	box.content_margin_top = 18.0
	box.content_margin_bottom = 18.0
	return box


## A seat card in the waiting room: filled when occupied, hollow when free.
static func seat_style(filled: bool) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = CREAM if filled else Color(0.968627, 0.945098, 0.898039, 0.35)
	box.border_color = INK
	box.set_border_width_all(4)
	box.set_corner_radius_all(16)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 12.0
	box.content_margin_bottom = 12.0
	return box


static func button_style(color: Color) -> StyleBoxFlat:
	if _button_styles.has(color):
		return _button_styles[color] as StyleBoxFlat
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = INK
	box.set_border_width_all(3)
	box.set_corner_radius_all(12)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	_button_styles[color] = box
	return box


## Repaints a button in the clay palette, or in the muted "off" fill. `node` rather
## than `button` because `button` is already the name of the factory below.
static func paint_button(node: Button, fill: Color) -> void:
	node.add_theme_color_override("font_color", INK)
	node.add_theme_stylebox_override("normal", button_style(fill))
	node.add_theme_stylebox_override("hover", button_style(fill.lightened(0.15)))
	node.add_theme_stylebox_override("pressed", button_style(fill.darkened(0.15)))
	node.add_theme_stylebox_override("disabled", button_style(TOGGLE_OFF))


## A clay button, added to `parent`. `handler` may be an empty Callable for a button
## the caller wires up itself.
static func button(parent: Node, text: String, handler: Callable = Callable(),
		size: Vector2 = Vector2(210, 46), font_size: int = 18) -> Button:
	var node := Button.new()
	node.text = text
	node.custom_minimum_size = size
	node.add_theme_font_size_override("font_size", font_size)
	paint_button(node, CLAY)
	if handler.is_valid():
		node.pressed.connect(handler)
	parent.add_child(node)
	return node


## Two-state button, for the transport picker and the ready toggle.
static func set_toggle(node: Button, active: bool) -> void:
	paint_button(node, CLAY if active else TOGGLE_OFF)
