extends Control

signal confirmed(image: Image)
signal cancelled

var source: Image
var source_texture: Texture2D
var crop_center := Vector2(0.5, 0.5)
var zoom := 1.0
var dragging := false
var font: Font
const VIEW := Rect2(118, 280, 304, 304)

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	var slider := HSlider.new()
	slider.position = Vector2(120, 622)
	slider.size = Vector2(300, 66)
	slider.min_value = 1.0
	slider.max_value = 2.5
	slider.step = 0.01
	slider.value_changed.connect(func(value: float): zoom = value; queue_redraw())
	add_child(slider)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.position = Vector2(83, 709)
	cancel.size = Vector2(170, 66)
	cancel.pressed.connect(func(): cancelled.emit())
	add_child(cancel)
	var save := Button.new()
	save.text = "确认裁剪"
	save.position = Vector2(287, 709)
	save.size = Vector2(170, 66)
	save.pressed.connect(_confirm)
	add_child(save)

func set_source(image: Image) -> void:
	source = image
	source_texture = ImageTexture.create_from_image(image)
	crop_center = Vector2(0.5, 0.5)
	zoom = 1.0
	queue_redraw()

func _crop_rect() -> Rect2i:
	var side: int = maxi(1, roundi(mini(source.get_width(), source.get_height()) / zoom))
	var center_px := Vector2(source.get_width() * crop_center.x, source.get_height() * crop_center.y)
	var x: int = clampi(roundi(center_px.x - side * 0.5), 0, source.get_width() - side)
	var y: int = clampi(roundi(center_px.y - side * 0.5), 0, source.get_height() - side)
	return Rect2i(x, y, side, side)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and VIEW.has_point(event.position): dragging = true
		elif not event.pressed: dragging = false
	if dragging and event is InputEventMouseMotion and source != null:
		var crop: Rect2i = _crop_rect()
		crop_center -= event.relative / VIEW.size * Vector2(float(crop.size.x) / source.get_width(), float(crop.size.y) / source.get_height())
		crop_center = crop_center.clamp(Vector2.ZERO, Vector2.ONE)
		queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.02, 0.01, 0.05, 0.93), true)
	_draw_label("裁剪圆形头像", Vector2(83, 196), 24, Color("f4efff"))
	if source_texture == null: return
	draw_texture_rect_region(source_texture, VIEW, _crop_rect())
	for part in [Rect2(118, 280, 304, 26), Rect2(118, 558, 304, 26), Rect2(118, 306, 26, 252), Rect2(396, 306, 26, 252)]:
		draw_rect(part, Color(0.02, 0.01, 0.05, 0.43), true)
	draw_arc(VIEW.get_center(), 125, 0, TAU, 80, Color("f4efff"), 2)
	_draw_label("拖动位置 · 滑动调整大小", Vector2(131, 621), 13, Color("b8aacb"))

func _draw_label(value: String, at: Vector2, font_size: int, color: Color) -> void:
	draw_string(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _confirm() -> void:
	if source == null: return
	var result: Image = source.get_region(_crop_rect())
	result.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	result.convert(Image.FORMAT_RGBA8)
	for y in range(256):
		for x in range(256):
			var distance := Vector2(x - 127.5, y - 127.5).length() / 128.0
			var pixel: Color = result.get_pixel(x, y)
			pixel.a *= 1.0 - smoothstep(0.94, 1.0, distance)
			result.set_pixel(x, y, pixel)
	confirmed.emit(result)
