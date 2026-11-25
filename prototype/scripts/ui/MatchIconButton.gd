extends Control

# 对局顶部系统键的图标层：返回箭头 / 更多三点。
#
# 为什么不用 Button 的 "<" / "..." 文本：game_zh.ttf 里这两个字符只有字库自带的
# 稀疏笔画，66px 下又细又偏（"<" 的收笔在左上，"..." 贴着基线），Web 端还没有系统
# 字体兜底。这里用 _draw 画等宽 2.4px 的圆头线段，位置按像素中心对齐，缩放到任何
# 屏幕都清楚；触摸区由外层 Button 撑到 88×88，图标本身不参与命中测试。
#
# 质感沿用对局现有紫色星球：半透明深底 + 1px 紫环 + 顶部一道边缘反光。

enum Kind { BACK, MORE }

var kind: Kind = Kind.BACK
var tint := Color("f2eefb")
var rim := Color(0.42, 0.31, 0.72, 0.55)
var disc := Color(0.043, 0.035, 0.075, 0.62)
var hot := false

const VISUAL_RADIUS := 22.0
const STROKE := 2.4
const DOT_RADIUS := 2.1
const DOT_STEP := 8.4


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_hot(value: bool) -> void:
	if hot == value:
		return
	hot = value
	queue_redraw()


func _draw() -> void:
	var c := size * 0.5
	draw_circle(c, VISUAL_RADIUS, disc.lightened(0.06) if hot else disc)
	if hot:
		draw_circle(c, VISUAL_RADIUS, Color(rim.r, rim.g, rim.b, 0.16))
	draw_arc(c, VISUAL_RADIUS, 0.0, TAU, 56, rim, 1.0, true)
	# 星球边缘反光：只在上半弧留一道很淡的高光，不做大面积纯白（用户明确不喜欢刺眼）。
	draw_arc(c, VISUAL_RADIUS - 1.4, deg_to_rad(202.0), deg_to_rad(338.0), 28,
		Color(0.78, 0.70, 0.98, 0.24), 1.4, true)
	if kind == Kind.BACK:
		_draw_chevron(c)
	else:
		_draw_dots(c)


# 箭头用折线而不是字符：三点共线、左右对称，笔画宽度与三点直径同一套视觉重量。
func _draw_chevron(c: Vector2) -> void:
	var points := PackedVector2Array([
		c + Vector2(3.4, -8.2),
		c + Vector2(-4.6, 0.0),
		c + Vector2(3.4, 8.2),
	])
	draw_polyline(points, tint, STROKE, true)


func _draw_dots(c: Vector2) -> void:
	for index in range(3):
		var offset: float = (float(index) - 1.0) * DOT_STEP
		draw_circle(c + Vector2(offset, 0.0), DOT_RADIUS, tint)
