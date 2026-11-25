extends RefCounted

const SettingsStore = preload("res://scripts/data/SettingsStore.gd")

const CORE := Color("#0A0A0B")
const PURPLE := Color("#A27DEA")
const GOLD := Color("#E7C68D")
const CYAN := Color("#6FD3E8")
const DISK_SPEED := 0.31
const HALO_SPEED := 0.16
const STREAM_POINT_COUNT := 13
const STREAMS := [
	{
		"start_angle": -0.44, "sweep": 1.49, "outer_radius": 0.844, "inner_radius": 0.502,
		"width": 0.064, "color": Color(GOLD, 0.88),
	},
	{
		"start_angle": 0.14, "sweep": 1.38, "outer_radius": 0.826, "inner_radius": 0.484,
		"width": 0.091, "color": Color(PURPLE, 0.94),
	},
	{
		"start_angle": 2.78, "sweep": 1.63, "outer_radius": 0.795, "inner_radius": 0.536,
		"width": 0.068, "color": Color(PURPLE, 0.65),
	},
]

static func draw_hole(canvas: CanvasItem, center: Vector2, radius: float, time: float) -> void:
	if radius <= 0.0:
		return
	var motion_time := 0.0 if SettingsStore.reduce_motion else time
	var disk_phase := fposmod(motion_time * DISK_SPEED, TAU)
	var halo_phase := fposmod(motion_time * HALO_SPEED, TAU)

	# Two translucent rim strokes suggest a glow at the edge.
	canvas.draw_circle(center, radius, CORE, true, -1.0, true)
	canvas.draw_arc(center, radius * 0.945, 0.0, TAU, 41, Color(PURPLE, 0.15), radius * 0.110, true)
	canvas.draw_arc(center, radius * 0.960, 0.0, TAU, 41, Color(PURPLE, 0.25), radius * 0.045, true)
	canvas.draw_arc(center, radius * 0.949, halo_phase + 0.25, halo_phase + 1.19, 9, Color(PURPLE, 0.66), radius * 0.043, true)
	canvas.draw_arc(center, radius * 0.931, halo_phase + 3.56, halo_phase + 4.28, 7, Color(PURPLE, 0.42), radius * 0.034, true)

	# Faint circular tracks sit beneath the inward-curving streams.
	canvas.draw_circle(center, radius * 0.875, Color(PURPLE, 0.12), true, -1.0, true)
	canvas.draw_arc(center, radius * 0.815, 0.0, TAU, 33, Color(PURPLE, 0.24), radius * 0.040, true)
	canvas.draw_arc(center, radius * 0.674, 0.0, TAU, 33, Color(PURPLE, 0.18), radius * 0.040, true)
	var points := PackedVector2Array()
	points.resize(STREAM_POINT_COUNT)
	for stream: Dictionary in STREAMS:
		var start_angle: float = disk_phase + stream.start_angle
		var sweep: float = stream.sweep
		var outer_radius: float = stream.outer_radius * radius
		var inner_radius: float = stream.inner_radius * radius
		for index in range(STREAM_POINT_COUNT):
			var progress := float(index) / float(STREAM_POINT_COUNT - 1)
			var angle := start_angle + sweep * progress
			var distance := lerpf(outer_radius, inner_radius, progress)
			points[index] = center + Vector2.from_angle(angle) * distance
		canvas.draw_polyline(points, stream.color, radius * stream.width, true)
	canvas.draw_arc(center, radius * 0.480, disk_phase + 1.42, disk_phase + 2.74, 11, Color(GOLD, 0.53), radius * 0.035, true)

	# Keep the center free of highlights and reserve cyan for a single spark.
	canvas.draw_circle(center, radius * 0.430, CORE, true, -1.0, true)
	var spark := center + Vector2.from_angle(halo_phase + 1.26) * (radius * 0.946)
	canvas.draw_circle(spark, radius * 0.034, Color(CYAN, 0.81), true, -1.0, true)
