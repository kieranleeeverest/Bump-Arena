extends RefCounted

# 三个副塔技能图标，纯几何绘制，无跨帧状态。
# skill: "double" | "heal" | "stun"
# alpha 是额外叠乘：副塔充能时用它做“从半透明到不透明”的进度感
static func draw_skill_icon(canvas: CanvasItem, center: Vector2, radius: float, skill: String, time: float, alpha := 1.0) -> void:
	if radius <= 0.0 or canvas == null:
		return
	# 呼吸闪烁：0.6..1.0，周期约 2.4 秒
	var pulse := (0.6 + 0.4 * (0.5 + 0.5 * sin(time * 2.6))) * clampf(alpha, 0.0, 1.0)
	match skill:
		"double":
			_draw_double(canvas, center, radius, pulse)
		"heal":
			_draw_heal(canvas, center, radius, pulse)
		"stun":
			_draw_stun(canvas, center, radius, pulse)


# 双倍：X 形交叉线 + 外围菱形
static func _draw_double(canvas: CanvasItem, c: Vector2, r: float, pulse: float) -> void:
	var gold := Color(0.906, 0.776, 0.553, pulse)  # #E7C68D
	var w := r * 0.18
	canvas.draw_line(c + Vector2(-0.52, -0.52) * r, c + Vector2(0.52, 0.52) * r, gold, w, true)
	canvas.draw_line(c + Vector2(-0.52, 0.52) * r, c + Vector2(0.52, -0.52) * r, gold, w, true)
	var diamond := PackedVector2Array([
		c + Vector2(0.0, -0.88) * r, c + Vector2(0.88, 0.0) * r,
		c + Vector2(0.0, 0.88) * r, c + Vector2(-0.88, 0.0) * r, c + Vector2(0.0, -0.88) * r,
	])
	canvas.draw_polyline(diamond, gold, w * 0.75, true)


# 治疗：十字，端点用圆头补全
static func _draw_heal(canvas: CanvasItem, c: Vector2, r: float, pulse: float) -> void:
	var mint := Color(0.412, 0.906, 0.643, pulse)  # #69E7A4
	var w := r * 0.22
	var top := c + Vector2(0.0, -0.74) * r
	var bottom := c + Vector2(0.0, 0.74) * r
	var left := c + Vector2(-0.74, 0.0) * r
	var right := c + Vector2(0.74, 0.0) * r
	canvas.draw_line(top, bottom, mint, w, true)
	canvas.draw_line(left, right, mint, w, true)
	for point in [top, bottom, left, right]:
		canvas.draw_circle(point, w * 0.5, mint, true, -1.0, true)


# 眩晕：三段同心弧，各自错开，像被搅乱的轨迹
static func _draw_stun(canvas: CanvasItem, c: Vector2, r: float, pulse: float) -> void:
	var violet := Color(0.635, 0.490, 0.918, pulse)  # #A27DEA
	var w := r * 0.14
	canvas.draw_arc(c, r * 0.30, 0.0, TAU, 24, violet, w, true)
	canvas.draw_arc(c, r * 0.58, 0.6, 0.6 + 1.9, 20, violet, w, true)
	canvas.draw_arc(c, r * 0.86, 2.4, 2.4 + 1.6, 20, violet, w, true)
