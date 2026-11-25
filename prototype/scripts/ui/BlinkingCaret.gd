extends Control
## Blinking caret drawn at the end of the text of a LineEdit.
##
## The owner disables the native caret, because it only appears when the
## LineEdit itself owns focus — and on Web the focus lives on an invisible DOM
## <input>, so the player would never see a caret at all. Drawing our own means
## exactly one caret everywhere, in the same place the text actually ends.

# 1.06s period = 530ms on / 530ms off, the long-standing OS text-caret rate.
const PERIOD := 1.06
const DUTY := 0.5
const WIDTH := 2.0
# Caret height as a fraction of the font size. A CJK glyph fills roughly 0.85 of
# the em box, so this makes the bar match the characters next to it.
const HEIGHT_RATIO := 0.85
# LineEdit draws its text a few pixels in from the left edge.
const TEXT_INSET := 4.0

var color := Color("ffffff")
# Only the focused field shows a caret. Several fields can exist on one page
# (email + password, nickname + signature), and blinking all of them at once
# reads as a glitch.
var active := false

var _elapsed := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Top-left anchors: every offset below is a plain absolute pixel value. With
	# LEFT_WIDE the bottom anchor is 1.0, which turns offset_bottom into an offset
	# from the parent's bottom edge and silently inflated the caret's height.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	set_process(true)


func _process(dt: float) -> void:
	_elapsed = fmod(_elapsed + dt, PERIOD)
	_follow_text()
	queue_redraw()


# Keep the caret glued to the end of whatever is typed, vertically centred at a
# sane height (a tall chat field must not get a 60px-tall caret).
func _follow_text() -> void:
	var field := get_parent() as LineEdit
	if field == null:
		return
	var font: Font = field.get_theme_font("font")
	var font_size: int = field.get_theme_font_size("font_size")
	if font == null or font_size <= 0:
		return
	# Password fields render the mask character, so measure the mask.
	var shown := field.text
	if field.secret and not field.secret_character.is_empty():
		shown = field.secret_character.repeat(field.text.length())
	var text_width := 0.0
	if not shown.is_empty():
		text_width = font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := clampf(TEXT_INSET + text_width, 2.0, maxf(field.size.x - 8.0, 2.0))
	offset_left = x
	offset_right = x + WIDTH
	# Height matches the glyphs; clamped so it still fits a thin field.
	var height := minf(float(font_size) * HEIGHT_RATIO, maxf(field.size.y - 10.0, 6.0))
	var top := (field.size.y - height) * 0.5
	offset_top = top
	offset_bottom = top + height


func _draw() -> void:
	# Hard on/off, not a fade: a real caret snaps between visible and invisible.
	if not active or _elapsed >= PERIOD * DUTY:
		return
	draw_rect(Rect2(Vector2.ZERO, size), color, true)
