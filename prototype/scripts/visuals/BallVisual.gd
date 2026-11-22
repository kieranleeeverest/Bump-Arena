extends Node2D
class_name BallVisual

@export var profile: BallVisualProfile

var angular_velocity: float = 0.0
var spin_phase: float = 0.0
var age: float = 0.0

func _process(delta: float) -> void:
	age += delta
	if profile != null:
		spin_phase += angular_velocity * delta
		angular_velocity *= exp(-profile.spin_friction * delta)
	queue_redraw()

func start_spin(speed: float = -1.0) -> void:
	if profile == null:
		return
	angular_velocity = profile.spin_speed if speed < 0.0 else speed

func stop_spin() -> void:
	angular_velocity = 0.0

func _draw() -> void:
	if profile == null:
		return
	var r := profile.radius
	if profile.artwork != null:
		_draw_artwork(r)
		return
	var base := profile.body_color
	draw_circle(Vector2(0.0, r * 0.12), r + 2.0, Color(0.0, 0.0, 0.0, 0.35))
	draw_circle(Vector2.ZERO, r, base.darkened(0.42))
	draw_circle(Vector2.ZERO, r * 0.91, base.darkened(0.10))
	draw_circle(Vector2(-r * 0.12, -r * 0.12), r * 0.64, base.lightened(0.10))
	_draw_surface_pattern(r)
	draw_arc(Vector2.ZERO, r * 0.94, -PI * 0.84, PI * 0.50, 48, profile.rim_color, 2.2)
	draw_circle(Vector2(-r * 0.31, -r * 0.34), r * 0.16, Color(1.0, 1.0, 1.0, 0.82))
	draw_circle(Vector2(-r * 0.20, -r * 0.24), r * 0.065, Color(1.0, 1.0, 1.0, 0.9))
	if profile.show_eye:
		_draw_eye(r)

func _draw_artwork(r: float) -> void:
	var width := r * 2.4
	var rect := Rect2(Vector2(-width * 0.5, -width * 0.5), Vector2.ONE * width)
	var idle_spin := age * 0.35 if profile.pattern == BallVisualProfile.SurfacePattern.FLAME else 0.0
	draw_set_transform(Vector2.ZERO, spin_phase + idle_spin, Vector2.ONE)
	draw_texture_rect(profile.artwork, rect, false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_surface_pattern(r: float) -> void:
	var pattern_color := profile.rim_color
	var alpha := 0.32 + clampf(profile.glow, 0.0, 1.0) * 0.22
	draw_set_transform(Vector2.ZERO, spin_phase, Vector2(0.38, 1.0))
	match profile.pattern:
		BallVisualProfile.SurfacePattern.PLAYER:
			draw_arc(Vector2.ZERO, r * 0.72, -PI * 0.65, PI * 0.65, 36, Color(pattern_color, alpha), 2.0)
		BallVisualProfile.SurfacePattern.METAL:
			draw_arc(Vector2.ZERO, r * 0.78, -PI * 0.90, PI * 0.20, 36, Color(pattern_color, alpha), 2.0)
			draw_arc(Vector2.ZERO, r * 0.60, PI * 0.18, PI * 0.82, 36, Color(pattern_color, alpha * 0.65), 1.5)
		BallVisualProfile.SurfacePattern.FLAME:
			draw_arc(Vector2.ZERO, r * 0.72, -PI * 0.72, PI * 0.18, 36, Color("ffd0a1", alpha), 3.0)
			draw_arc(Vector2.ZERO, r * 0.52, PI * 0.20, PI * 0.78, 36, Color("ffdf98", alpha * 0.8), 2.0)
		BallVisualProfile.SurfacePattern.VEINS:
			for angle in [0.0, TAU / 3.0, TAU * 2.0 / 3.0]:
				var start := Vector2(cos(angle), sin(angle)) * r * 0.32
				var finish := Vector2(cos(angle + 0.7), sin(angle + 0.7)) * r * 0.78
				draw_line(start, finish, Color("e8b4ff", alpha), 2.0, true)
		BallVisualProfile.SurfacePattern.REFRESH:
			for angle in [0.0, TAU / 3.0, TAU * 2.0 / 3.0]:
				var point := Vector2(cos(angle), sin(angle)) * r * 0.70
				draw_circle(point, r * 0.075, Color("f5ffe4", alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_eye(r: float) -> void:
	var interval := maxf(profile.blink_interval, 0.25)
	var cycle := fposmod(age, interval)
	var blink_amount := 0.0
	if cycle < 0.12:
		blink_amount = sin(PI * cycle / 0.12)
	var eye_r := r * profile.eye_scale
	var open_y := maxf(0.08, 1.0 - blink_amount * 0.96)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.0, open_y))
	draw_circle(Vector2.ZERO, eye_r, Color("09121c"))
	draw_circle(Vector2.ZERO, eye_r * 0.82, Color("f7fbff"))
	draw_circle(Vector2(eye_r * 0.10, eye_r * 0.06), eye_r * 0.54, profile.eye_color)
	draw_circle(Vector2(eye_r * 0.16, eye_r * 0.05), eye_r * 0.28, Color("09121c"))
	draw_circle(Vector2(-eye_r * 0.15, -eye_r * 0.19), eye_r * 0.11, Color.WHITE)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
