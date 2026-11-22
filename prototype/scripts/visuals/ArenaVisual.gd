extends Node2D
class_name ArenaVisual

@export var theme: ArenaTheme
@export var layout: ArenaDefinition
@export var stage_rect: Rect2 = Rect2(24.0, 126.0, 492.0, 500.0)

var pulse_clock := 0.0

func _process(delta: float) -> void:
	pulse_clock += delta
	queue_redraw()

func _draw() -> void:
	if theme == null:
		return
	var field_viewport := stage_rect.grow(-14.0)
	var field_size := field_viewport.size
	if layout != null and layout.field_size.x > 0.0 and layout.field_size.y > 0.0:
		var fit_scale := minf(field_viewport.size.x / layout.field_size.x, field_viewport.size.y / layout.field_size.y)
		field_size = layout.field_size * fit_scale
	var field := Rect2(field_viewport.get_center() - field_size * 0.5, field_size)
	var pulse := 0.86 + 0.14 * sin(pulse_clock * 1.8)
	draw_rect(stage_rect, Color(0.0, 0.0, 0.0, 0.35), true)
	draw_rect(field, theme.floor_color, true)
	draw_rect(field.grow(-7.0), theme.inset_color, true)
	if theme.show_grid:
		var spacing := maxf(theme.grid_spacing, 12.0)
		var x := field.position.x + 12.0
		while x < field.end.x - 8.0:
			draw_line(Vector2(x, field.position.y + 8.0), Vector2(x, field.end.y - 8.0), Color(theme.grid_color, 0.075), 1.0)
			x += spacing
		var y := field.position.y + 12.0
		while y < field.end.y - 8.0:
			draw_line(Vector2(field.position.x + 8.0, y), Vector2(field.end.x - 8.0, y), Color(theme.grid_color, 0.055), 1.0)
			y += spacing
		draw_line(Vector2(field.position.x + 8.0, field.get_center().y), Vector2(field.end.x - 8.0, field.get_center().y), Color(theme.grid_color, 0.15), 1.5)
		draw_arc(field.get_center(), 62.0, 0.0, TAU, 64, Color(theme.grid_color, 0.14), 1.5)
	_draw_map_markers(field)
	var glow_color := Color(theme.border_color, 0.08 * theme.border_glow * pulse)
	draw_rect(field.grow(5.0), glow_color, false, theme.border_width + 10.0)
	draw_rect(field, Color(theme.border_color, 0.34 * theme.border_glow), false, theme.border_width + 4.0)
	draw_rect(field.grow(-4.0), Color(theme.border_color, 0.95), false, maxf(theme.border_width, 1.0))
	_draw_corners(field, theme.border_color)

func _draw_map_markers(field: Rect2) -> void:
	if layout == null:
		return
	for spawn in layout.spawn_points:
		var p := _map_to_view(spawn, field)
		draw_arc(p, 7.0, 0.0, TAU, 24, Color("8de7ff", 0.65), 1.5)
	for hazard in layout.fixed_hazard_points:
		var p := _map_to_view(hazard, field)
		draw_circle(p, 10.0, Color(0.9, 0.18, 0.30, 0.22))
		draw_line(p + Vector2(-6, -6), p + Vector2(6, 6), Color("ff6277"), 3.0, true)
		draw_line(p + Vector2(6, -6), p + Vector2(-6, 6), Color("ff6277"), 3.0, true)
	for obstacle in layout.obstacle_points:
		var p := _map_to_view(obstacle, field)
		draw_circle(p, 10.0, Color("8296a8", 0.75))
		draw_arc(p, 10.0, 0.0, TAU, 24, Color("d2e5ef"), 1.5)

func _map_to_view(point: Vector2, field: Rect2) -> Vector2:
	if layout == null:
		return field.get_center()
	var normalized := Vector2(point.x / layout.field_size.x, point.y / layout.field_size.y)
	return field.position + normalized * field.size

func _draw_corners(field: Rect2, color: Color) -> void:
	var length := 28.0
	var corners := [field.position, Vector2(field.end.x, field.position.y), field.end, Vector2(field.position.x, field.end.y)]
	var sx_values := [1.0, -1.0, -1.0, 1.0]
	var sy_values := [1.0, 1.0, -1.0, -1.0]
	for i in range(corners.size()):
		var p: Vector2 = corners[i]
		var sx: float = sx_values[i]
		var sy: float = sy_values[i]
		draw_line(p + Vector2(sx * length, 0.0), p, color.lightened(0.25), 4.0, true)
		draw_line(p + Vector2(0.0, sy * length), p, color.lightened(0.25), 4.0, true)
		draw_circle(p, 3.5, Color.WHITE)
