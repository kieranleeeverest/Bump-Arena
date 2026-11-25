extends RefCounted

const INK := Color("f4efff")
const MUTED := Color("b8aacb")
const ACCENT := Color("75d7e9")

static func _style(fill: Color, edge: Color, radius: int = 14) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 7
	box.content_margin_bottom = 7
	return box

const UI_FONT := preload("res://fonts/game_zh.ttf")

static func create() -> Theme:
	var theme := Theme.new()
	# Embedded CJK subset font: the Web build cannot borrow system fonts, so
	# Chinese text must come from a font shipped inside the .pck.
	theme.default_font = UI_FONT
	theme.default_font_size = 14
	for type in ["Button", "LineEdit", "Label"]:
		theme.set_color("font_color", type, INK)
		if type != "Label": theme.set_color("font_disabled_color", type, MUTED)
	theme.set_stylebox("normal", "Button", _style(Color("231a37"), Color("7a668e")))
	theme.set_stylebox("hover", "Button", _style(Color("294453"), ACCENT))
	theme.set_stylebox("pressed", "Button", _style(Color("183440"), ACCENT))
	theme.set_stylebox("disabled", "Button", _style(Color("1a1729"), Color("524960")))
	theme.set_stylebox("focus", "Button", _style(Color.TRANSPARENT, ACCENT))
	theme.set_stylebox("normal", "LineEdit", _style(Color("1b1530"), Color("685778")))
	theme.set_stylebox("focus", "LineEdit", _style(Color("1b1530"), ACCENT))
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_color("selection_color", "LineEdit", Color("3a6373"))
	return theme
