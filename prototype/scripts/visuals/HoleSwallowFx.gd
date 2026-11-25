extends RefCounted

const SWALLOW_PURPLE := Color("#A27DEA")
const DEEP_PURPLE := Color("#6A4FB8")
const CYAN := Color("#6FD3E8")


static func draw_swallow(canvas: CanvasItem, hole_center: Vector2, entry: Vector2, ball_radius: float, hole_radius: float, progress: float, tint: Color) -> void:
	progress = clampf(progress, 0.0, 1.0)
	if canvas == null or progress <= 0.0 or progress >= 1.0:
		return

	if progress <= 0.40:
		_draw_pull(canvas, hole_center, entry, ball_radius, progress / 0.40, tint)

	if progress >= 0.30 and progress <= 0.62:
		var amount := (progress - 0.30) / (0.62 - 0.30)
		var radius := hole_radius * lerpf(1.18, 0.12, amount)
		var width := lerpf(2.0, 0.6, amount)
		var color := Color(SWALLOW_PURPLE, lerpf(0.85, 0.0, amount))
		canvas.draw_arc(hole_center, radius, 0.0, TAU, 40, color, width, true)

	if progress >= 0.55:
		_draw_afterglow(canvas, hole_center, hole_radius, (progress - 0.55) / (1.0 - 0.55))

	# 收束亮点与吞噬环重叠，只在指定时间窗内绘制。
	if progress >= 0.40 and progress <= 0.50:
		var alpha := lerpf(0.9, 0.0, (progress - 0.40) / (0.50 - 0.40))
		canvas.draw_circle(hole_center, 1.8, Color(CYAN, alpha), true, -1.0, true)


static func _draw_pull(
	canvas: CanvasItem,
	hole_center: Vector2,
	entry: Vector2,
	ball_radius: float,
	amount: float,
	tint: Color
) -> void:
	var travel := hole_center - entry
	var perpendicular := Vector2(-travel.y, travel.x).normalized()
	var remaining := 1.0 - amount
	var phase := TAU * amount

	# 纵向加速，横向摆幅随距离收拢，起点和终点都落在连线上。
	var offset := ball_radius * 0.9 * remaining * sin(phase)
	var center := entry.lerp(hole_center, amount * amount) + perpendicular * offset
	var radius := ball_radius * lerpf(1.0, 0.28, amount)
	var color := Color(tint.lerp(SWALLOW_PURPLE, amount), lerpf(1.0, 0.55, amount))

	# 取当前位置的运动方向，让三条短弧留在球后方。
	var offset_rate := ball_radius * 0.9 * (remaining * TAU * cos(phase) - sin(phase))
	var velocity := travel * (2.0 * amount) + perpendicular * offset_rate
	var trailing_angle := velocity.angle() + PI
	for index in range(3):
		var distance := float(index)
		var arc_radius := radius + (2.5 + distance * 3.0) * remaining
		var half_angle := (0.48 - distance * 0.08) * remaining
		var alpha := (0.66 - distance * 0.16) * remaining
		canvas.draw_arc(
			center, arc_radius, trailing_angle - half_angle, trailing_angle + half_angle,
			12, Color(DEEP_PURPLE, alpha), 1.4, true
		)

	canvas.draw_circle(center, radius, color, true, -1.0, true)


static func _draw_afterglow(
	canvas: CanvasItem,
	hole_center: Vector2,
	hole_radius: float,
	amount: float
) -> void:
	var remaining := 1.0 - amount
	var particle_radius := lerpf(2.2, 0.6, amount)
	var particle_color := Color(SWALLOW_PURPLE, lerpf(0.9, 0.0, amount))

	# 等角分布的粒子转过一整圈，轨道同步收向中心。
	for index in range(8):
		var start_radius := hole_radius * lerpf(1.0, 1.5, float(index) / 7.0)
		var angle := TAU * (float(index) / 8.0 + amount)
		var center := hole_center + Vector2.from_angle(angle) * start_radius * remaining
		canvas.draw_circle(center, particle_radius, particle_color, true, -1.0, true)

	var core_color := Color(DEEP_PURPLE, lerpf(0.45, 0.0, amount))
	canvas.draw_circle(hole_center, hole_radius * 0.10, core_color, true, -1.0, true)
