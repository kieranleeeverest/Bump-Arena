extends Node2D

const FIRE_ARTWORK: Texture2D = preload("res://assets/orbs/fire_lava.png")
const IRON_ARTWORK: Texture2D = preload("res://assets/orbs/durable_iron_orb.png")
const VAMPIRE_ARTWORK: Texture2D = preload("res://assets/orbs/vampire_orb.png")
const ARENA_ARTWORK: Texture2D = preload("res://assets/arena/arena_nebula_crystal_final.png")
const FORMAL_HUD = preload("res://scripts/ui/FormalHud.gd")
const DEVELOPER_PANEL = preload("res://scripts/ui/DeveloperPanel.gd")
const UI_LAYOUT = preload("res://scripts/ui/UILayoutManager.gd")
const SKIN_IMAGE_SIZE := Vector2(1024.0, 1536.0)
const SKIN_DRAW_RECT := Rect2(Vector2(0.0, 75.0), Vector2(540.0, 810.0))
# These are coordinates in the unchanged PNG, not screenshot or phone pixels.
# The corners are intersections of the six fitted laser inner-edge lines.
const FIELD_CORNERS_IMAGE = [
	Vector2(120, 347), Vector2(512, 254), Vector2(904, 347),
	Vector2(904, 1121), Vector2(512, 1230), Vector2(120, 1121)
]
const TOWER_CENTERS_IMAGE = [
	Vector2(107, 337), Vector2(512, 239), Vector2(917, 337),
	Vector2(107, 1134), Vector2(512, 1240), Vector2(917, 1134)
]
const TOWER_RADII_IMAGE = [34.0, 49.0, 34.0, 34.0, 49.0, 34.0]
const CORNER_TOWER_INDICES = [0, 1, 2, 5, 4, 3]
const BOUNDARY_ARC_STEP_IMAGE := 2.0
const BOUNDARY_MAIN_BLEND_IMAGE := 10.0
const BOUNDARY_SIDE_BLEND_IMAGE := 6.0
# Side-tower red arc in the skin's local axes: 0..70 degrees. Other corners mirror it.
const SIDE_DAMAGE_ARC_START_DEG := 0.0
const SIDE_DAMAGE_ARC_END_DEG := 70.0

@export_range(0.0, 15.0, 0.5) var side_damage_tolerance_deg := 5.0

var balls: Array = []
var towers: Array = []
var field_corners: Array[Vector2] = []
var boundary_outline := PackedVector2Array()
var boundary_joints := PackedVector2Array()
var tower_impacts: Array = []
var debug_collisions := false
var debug_mode := false
var show_ui_bounds := false
@export_range(0, 3, 1) var local_player_id := 2
var preview_side_override := -1
var formal_hud: Control
var developer_panel: Window
var debug_contacts: Array = []
var debug_frame_ms := 0.0
var turn := 0
var moving := false
var aiming := false
var start := Vector2.ZERO
var pull := Vector2.ZERO
var timer := 15.0
var quiet := 0.0
var power := 9.0
var drag := 0.7
var bounce := 0.85
var banner := "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"
var font: Font
var finished := false
var last_hit := "NO IMPACTS YET"
var shot_number := 0

func _ready():
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	reset_game()
	_apply_view_transform()
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	formal_hud = FORMAL_HUD.new()
	formal_hud.game = self
	layer.add_child(formal_hud)
	formal_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _desktop_debug_available():
		developer_panel = DEVELOPER_PANEL.new()
		developer_panel.game = self
		add_child(developer_panel)
		developer_panel.position = get_window().position + Vector2i(get_window().size.x + 12, 0)

func _desktop_debug_available() -> bool:
	return DisplayServer.get_name() != "headless" and (OS.has_feature("windows") or OS.has_feature("linux") or OS.has_feature("macos"))

func get_view_side() -> int:
	return preview_side_override if preview_side_override >= 0 else (0 if local_player_id < 2 else 1)

func assign_local_player(player_id: int) -> void:
	if player_id < 0 or player_id >= 4: return
	local_player_id = player_id
	preview_side_override = -1
	_apply_view_transform()

func set_preview_side(side: int) -> void:
	if side != 0 and side != 1: return
	preview_side_override = side
	_apply_view_transform()

func _apply_view_transform() -> void:
	# Both views pivot around the board's actual geometry, inside its allotted screen region.
	# This keeps the existing blue-side placement while leaving world physics unchanged.
	var board_center := (_skin_to_world(TOWER_CENTERS_IMAGE[1]) + _skin_to_world(TOWER_CENTERS_IMAGE[4])) * 0.5
	transform = UI_LAYOUT.board_transform(board_center, get_view_side() == 0)
	queue_redraw()
	if formal_hud != null: formal_hud.queue_redraw()

func set_debug_mode(enabled: bool) -> void:
	debug_mode = enabled
	if not enabled:
		debug_collisions = false
		show_ui_bounds = false
		debug_contacts.clear()
	if formal_hud != null:
		formal_hud.show_layout_bounds = debug_mode and show_ui_bounds
		formal_hud.queue_redraw()
	if developer_panel != null:
		developer_panel.visible = enabled
		if enabled: developer_panel.refresh_status()
	queue_redraw()

func set_collision_debug(enabled: bool) -> void:
	debug_collisions = enabled and debug_mode
	if not debug_collisions: debug_contacts.clear()
	queue_redraw()

func set_ui_bounds_debug(enabled: bool) -> void:
	show_ui_bounds = enabled and debug_mode
	if formal_hud != null:
		formal_hud.show_layout_bounds = show_ui_bounds
		formal_hud.queue_redraw()

func handle_developer_key(keycode: Key) -> bool:
	if OS.has_feature("web") or OS.has_feature("mobile"): return false
	if keycode == KEY_F3:
		set_debug_mode(not debug_mode)
		return true
	if keycode == KEY_F4:
		if debug_mode: set_ui_bounds_debug(not show_ui_bounds)
		return true
	if keycode == KEY_F5:
		set_preview_side(1 - get_view_side())
		return true
	return false

func reset_game():
	balls.clear()
	towers.clear()
	tower_impacts.clear()
	debug_contacts.clear()
	field_corners.clear()
	for point in FIELD_CORNERS_IMAGE:
		field_corners.append(_skin_to_world(point))
	for i in range(4):
		balls.append({"p": Vector2(170 + (i % 2) * 200, 320 + (i / 2) * 260), "v": Vector2.ZERO, "r": 18.0, "kind": "player", "id": i, "armed": false, "alive": true, "angle": 0.0, "spin": 0.0, "spin_kick": 0.0, "impact": 0.0})
	var neutral_kinds := ["iron", "fire", "vampire", "iron"]
	for i in range(neutral_kinds.size()):
		balls.append({"p": Vector2(135 + i * 90, 455), "v": Vector2.ZERO, "r": 18.0, "kind": neutral_kinds[i], "id": -1, "armed": false, "alive": true, "angle": 0.0, "spin": 0.0, "spin_kick": 0.0, "impact": 0.0, "owner_side": -1})
	var tower_specs := [
		[Vector2(1, 1).normalized(), 0, false],
		[Vector2.DOWN, 0, true],
		[Vector2(-1, 1).normalized(), 0, false],
		[Vector2(1, -1).normalized(), 1, false],
		[Vector2.UP, 1, true],
		[Vector2(-1, -1).normalized(), 1, false]
	]
	for i in range(tower_specs.size()):
		var spec: Array = tower_specs[i]
		var main: bool = spec[2]
		var body_radius: float = TOWER_RADII_IMAGE[i] * _skin_scale()
		var mirror := Vector2(-1.0 if i == 2 or i == 5 else 1.0, -1.0 if i >= 3 else 1.0)
		towers.append({"p": _skin_to_world(TOWER_CENTERS_IMAGE[i]), "inward": spec[0], "side": spec[1], "main": main, "r": body_radius, "hit_r": body_radius, "fan_half": deg_to_rad(24.0 if main else 22.0), "damage_mirror": mirror, "hp": 100})
	_build_boundary_outline()
	turn = 0
	moving = false
	aiming = false
	finished = false
	last_hit = "NO IMPACTS YET"
	shot_number = 0
	timer = 15.0
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"

func _skin_scale() -> float:
	return SKIN_DRAW_RECT.size.x / SKIN_IMAGE_SIZE.x

func _skin_to_world(point: Vector2) -> Vector2:
	return SKIN_DRAW_RECT.position + point * _skin_scale()

func _corner_cut(corner: Vector2, neighbor: Vector2, center: Vector2, radius: float) -> Vector2:
	var direction: Vector2 = (neighbor - corner).normalized()
	var relative: Vector2 = corner - center
	var along: float = -relative.dot(direction)
	var cut_distance: float = along + sqrt(maxf(0.0, along * along + radius * radius - relative.length_squared()))
	return corner + direction * cut_distance

func _build_boundary_outline() -> void:
	boundary_outline.clear()
	boundary_joints.clear()
	var entries: Array[Vector2] = []
	var exits: Array[Vector2] = []
	var arc_starts: Array[Vector2] = []
	var arc_ends: Array[Vector2] = []
	var start_angles: Array[float] = []
	var end_angles: Array[float] = []
	# The field corners lie inside the visible tower circles. Both neighboring
	# rails meet the same circle; small cubic transitions make those joins G1.
	var arc_step: float = BOUNDARY_ARC_STEP_IMAGE * _skin_scale()
	for i in range(field_corners.size()):
		var corner: Vector2 = field_corners[i]
		var tower: Dictionary = towers[CORNER_TOWER_INDICES[i]]
		var center: Vector2 = tower.p
		var radius: float = tower.r
		var blend_length: float = (BOUNDARY_MAIN_BLEND_IMAGE if tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var entry: Vector2 = _corner_cut(corner, field_corners[(i - 1 + field_corners.size()) % field_corners.size()], center, radius)
		var exit_point: Vector2 = _corner_cut(corner, field_corners[(i + 1) % field_corners.size()], center, radius)
		var start_angle: float = (entry - center).angle()
		var end_angle: float = (exit_point - center).angle()
		while end_angle >= start_angle: end_angle -= TAU
		start_angle -= blend_length / radius
		end_angle += blend_length / radius
		entries.append(entry)
		exits.append(exit_point)
		start_angles.append(start_angle)
		end_angles.append(end_angle)
		arc_starts.append(center + Vector2.from_angle(start_angle) * radius)
		arc_ends.append(center + Vector2.from_angle(end_angle) * radius)
	boundary_outline.append(arc_starts[0])
	for i in range(field_corners.size()):
		var next: int = (i + 1) % field_corners.size()
		var tower: Dictionary = towers[CORNER_TOWER_INDICES[i]]
		var arc_length: float = tower.r * (start_angles[i] - end_angles[i])
		var arc_count: int = maxi(2, ceili(arc_length / arc_step))
		for arc_index in range(1, arc_count):
			var angle: float = lerpf(start_angles[i], end_angles[i], float(arc_index) / arc_count)
			boundary_outline.append(tower.p + Vector2.from_angle(angle) * tower.r)
		boundary_outline.append(arc_ends[i])
		var direction: Vector2 = (entries[next] - exits[i]).normalized()
		var blend_out: float = (BOUNDARY_MAIN_BLEND_IMAGE if tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var next_tower: Dictionary = towers[CORNER_TOWER_INDICES[next]]
		var blend_in: float = (BOUNDARY_MAIN_BLEND_IMAGE if next_tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var line_start: Vector2 = exits[i] + direction * blend_out
		var line_end: Vector2 = entries[next] - direction * blend_in
		var tangent_out := Vector2(sin(end_angles[i]), -cos(end_angles[i]))
		_append_boundary_cubic(arc_ends[i], arc_ends[i] + tangent_out * (blend_out * 0.5), line_start - direction * (blend_out * 0.5), line_start)
		boundary_outline.append(line_end)
		var tangent_in := Vector2(sin(start_angles[next]), -cos(start_angles[next]))
		_append_boundary_cubic(line_end, line_end + direction * (blend_in * 0.5), arc_starts[next] - tangent_in * (blend_in * 0.5), arc_starts[next])
		for joint in [arc_ends[i], line_start, line_end, arc_starts[next]]: boundary_joints.append(joint)
	# The last cubic ends at the first point, which is supplied by the implicit
	# closing segment when drawing and sweeping the outline.
	boundary_outline.remove_at(boundary_outline.size() - 1)

func _append_boundary_cubic(a: Vector2, control_a: Vector2, control_b: Vector2, b: Vector2) -> void:
	var count: int = maxi(3, ceili(a.distance_to(b) / (BOUNDARY_ARC_STEP_IMAGE * _skin_scale())))
	for index in range(1, count + 1):
		var t: float = float(index) / count
		var inv: float = 1.0 - t
		boundary_outline.append(a * inv * inv * inv + control_a * 3.0 * inv * inv * t + control_b * 3.0 * inv * t * t + b * t * t * t)

func _unhandled_input(e):
	if e is InputEventKey and e.pressed and not e.echo:
		if handle_developer_key(e.keycode): return
	if moving or finished: return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed: begin(to_local(e.position))
		else: release()
	elif e is InputEventMouseMotion and aiming: pull = (start - to_local(e.position)).limit_length(180)
	elif e is InputEventScreenTouch:
		if e.pressed: begin(to_local(e.position))
		else: release()
	elif e is InputEventScreenDrag and aiming: pull = (start - to_local(e.position)).limit_length(180)

func begin(p: Vector2):
	aiming = true
	start = p
	pull = Vector2.ZERO

func release():
	if not aiming: return
	aiming = false
	if pull.length() < 6: return
	shot_number += 1
	for b in balls:
		if b.kind == "vampire": b.owner_side = 0 if turn < 2 else 1
	# Store the actual starting state and shot, so a reported miss can be replayed.
	var recording := FileAccess.open("user://last_shot.json", FileAccess.WRITE)
	if recording:
		var state: Array = []
		for b in balls:
			state.append({"x": b.p.x, "y": b.p.y, "kind": b.kind, "id": b.id, "alive": b.alive, "armed": b.armed})
		recording.store_string(JSON.stringify({"shot": shot_number, "player": turn + 1, "pull": [pull.x, pull.y], "power": power, "drag": drag, "bounce": bounce, "balls": state, "tower_hp": towers.map(func(t): return t.hp)}, "  "))
		recording.close()
	balls[turn].v = pull * power
	moving = true
	quiet = 0.0
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"

func next_turn():
	for b in balls:
		b.armed = false
		b.v = Vector2.ZERO
	turn = (turn + 1) % 4
	timer = 15.0
	moving = false
	aiming = false
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"

func _physics_process(dt):
	var debug_start_usec := Time.get_ticks_usec() if debug_collisions else 0
	if debug_collisions:
		for i in range(debug_contacts.size() - 1, -1, -1):
			debug_contacts[i].life -= dt
			if debug_contacts[i].life <= 0.0: debug_contacts.remove_at(i)
	_update_tower_impacts(dt)
	if not moving and not finished:
		timer -= dt
		if timer <= 0: next_turn()
	if moving and not finished:
		for sub in range(4): step(dt / 4.0)
		var max_speed := 0.0
		for b in balls:
			if b.alive: max_speed = max(max_speed, b.v.length())
		quiet = quiet + dt if max_speed < 5 else 0.0
		if quiet > 0.25: next_turn()
	_update_orb_visuals(dt)
	if debug_collisions: debug_frame_ms = float(Time.get_ticks_usec() - debug_start_usec) / 1000.0
	queue_redraw()

func _record_debug_contact(kind: String, ball_index: int, shape_index: int, point: Vector2, normal: Vector2, speed: float, correction: float) -> void:
	if not debug_collisions: return
	if kind == "outside fan":
		for contact in debug_contacts:
			if contact.kind == kind and contact.ball == ball_index and contact.shape == shape_index:
				contact.point = point
				contact.normal = normal
				contact.life = 0.35
				return
	if debug_contacts.size() >= 32: debug_contacts.pop_front()
	debug_contacts.append({"kind": kind, "ball": ball_index, "shape": shape_index, "point": point, "normal": normal, "speed": speed, "correction": correction, "life": 0.35})

func _update_orb_visuals(dt: float) -> void:
	for b in balls:
		if not b.alive: continue
		var velocity: Vector2 = b.v
		var target_spin := 0.0
		if velocity.length() > 4.0:
			var roll_direction := signf(velocity.x) if absf(velocity.x) >= absf(velocity.y) else -signf(velocity.y)
			target_spin = roll_direction * minf(velocity.length() / b.r * 0.55, 14.0)
		target_spin = clampf(target_spin + b.spin_kick, -20.0, 20.0)
		b.spin = lerpf(b.spin, target_spin, 1.0 - exp(-10.0 * dt))
		b.angle = fposmod(b.angle + b.spin * dt, TAU)
		b.spin_kick *= exp(-2.8 * dt)
		b.impact *= exp(-12.0 * dt)

func _update_tower_impacts(dt: float) -> void:
	for i in range(tower_impacts.size() - 1, -1, -1):
		var effect: Dictionary = tower_impacts[i]
		effect.life -= dt
		if effect.life <= 0.0:
			tower_impacts.remove_at(i)

func _add_tower_impact(ball_index: int, tower_index: int, point: Vector2, normal: Vector2, speed: float, side: int) -> void:
	for effect in tower_impacts:
		if effect.ball == ball_index and effect.tower == tower_index:
			return
	var strength := clampf((speed - 60.0) / 1200.0, 0.08, 1.0)
	var duration := 0.10 + strength * 0.10
	if tower_impacts.size() >= 12:
		tower_impacts.pop_front()
	tower_impacts.append({"ball": ball_index, "tower": tower_index, "p": point, "n": normal, "side": side, "strength": strength, "life": duration, "duration": duration})

func _side_damage_angle(t: Dictionary, radial: Vector2) -> bool:
	var local: Vector2 = radial * t.damage_mirror
	var angle: float = rad_to_deg(local.angle())
	return angle >= SIDE_DAMAGE_ARC_START_DEG - side_damage_tolerance_deg and angle <= SIDE_DAMAGE_ARC_END_DEG + side_damage_tolerance_deg

func _apply_tower_damage(b: Dictionary, tower_index: int, radial: Vector2, eligible: bool) -> void:
	var t: Dictionary = towers[tower_index]
	if t.hp <= 0 or not eligible: return
	if not t.main and not _side_damage_angle(t, radial): return
	if b.kind == "vampire" and (b.owner_side < 0 or t.side == b.owner_side): return
	if not b.has("damage_latch"): b.damage_latch = {}
	if b.damage_latch.has(tower_index): return
	b.damage_latch[tower_index] = true
	var damage := 20 if b.kind == "fire" else 10
	var dealt: int = mini(damage, t.hp)
	t.hp -= dealt
	if b.kind == "vampire":
		var healed := _heal_team(b.owner_side, dealt)
		last_hit = "DRAIN: %s -%d HP / %s +%d HP" % ["BLUE" if t.side == 0 else "RED", dealt, "BLUE" if b.owner_side == 0 else "RED", healed]
	else:
		last_hit = "SHOT %d: %s -%d HP (%d LEFT)" % [shot_number, "BLUE" if t.side == 0 else "RED", dealt, t.hp]
	print(last_hit)
	if t.hp == 0 and t.main:
		finished = true
		banner = "CORE DESTROYED - ROUND OVER"
	if b.kind == "fire" or b.kind == "vampire": b.alive = false

func _damage_side_tower_wall_contact(b: Dictionary, point: Vector2, normal: Vector2, eligible: bool) -> void:
	for tower_index in [0, 2, 3, 5]:
		var t: Dictionary = towers[tower_index]
		var radial: Vector2 = point - t.p
		if absf(radial.length() - t.hit_r) > 0.5: continue
		if radial.normalized().dot(normal) < 0.92: continue
		_apply_tower_damage(b, tower_index, radial.normalized(), eligible)
		return

func step(dt: float):
	var previous_positions: Array[Vector2] = []
	for b in balls:
		previous_positions.append(b.p)
		if not b.alive: continue
		if b.has("damage_latch"):
			for tower_index in b.damage_latch.keys():
				var tower: Dictionary = towers[tower_index]
				if b.p.distance_to(tower.p) > b.r + tower.hit_r + 2.0: b.damage_latch.erase(tower_index)
		b.p += b.v * dt
		b.v *= exp(-drag * dt)
	for i in range(balls.size()):
		for j in range(i + 1, balls.size()):
			var a = balls[i]
			var b = balls[j]
			if not a.alive or not b.alive: continue
			var d: Vector2 = b.p - a.p
			var distance: float = d.length()
			if distance >= a.r + b.r: continue
			var n: Vector2 = d / distance if distance > 0.001 else Vector2.RIGHT
			var overlap: float = a.r + b.r - distance
			a.p -= n * overlap * 0.5
			b.p += n * overlap * 0.5
			var approach: float = (b.v - a.v).dot(n)
			if approach < 0:
				var impulse: Vector2 = -(1 + bounce) * approach * n * 0.5
				a.v -= impulse
				b.v += impulse
				if a.kind != "player": a.impact = maxf(a.impact, minf(-approach / 600.0, 1.0))
				if b.kind != "player": b.impact = maxf(b.impact, minf(-approach / 600.0, 1.0))
				a.armed = true
				b.armed = true
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		for tower_index in range(towers.size()):
			var t = towers[tower_index]
			if t.hp <= 0: continue
			var d: Vector2 = b.p - t.p
			var distance: float = d.length()
			var contact_radius: float = b.r + t.hit_r
			var n := Vector2.ZERO
			# Test the path to the new position so a fast ball cannot cross the fan between samples.
			var from: Vector2 = previous_positions[ball_index] - t.p
			var travel: Vector2 = b.p - previous_positions[ball_index]
			var travel_squared: float = travel.length_squared()
			if from.length_squared() >= contact_radius * contact_radius and travel_squared > 0.0001:
				var along: float = from.dot(travel)
				var discriminant: float = along * along - travel_squared * (from.length_squared() - contact_radius * contact_radius)
				if discriminant >= 0.0:
					var hit_time: float = (-along - sqrt(discriminant)) / travel_squared
					if hit_time >= 0.0 and hit_time <= 1.0:
						n = (from + travel * hit_time).normalized()
			if n.dot(t.inward) < cos(t.fan_half):
				if distance >= contact_radius: continue
				n = d.normalized() if distance > 0.001 else t.inward
			if n.dot(t.inward) < cos(t.fan_half):
				continue
			var approach: float = b.v.dot(n)
			if approach >= 0:
				if distance < contact_radius: b.p = t.p + n * (contact_radius + 0.1)
				continue
			var correction: float = b.p.distance_to(t.p + n * (contact_radius + 0.1))
			b.p = t.p + n * (contact_radius + 0.1)
			var tangent := Vector2(-n.y, n.x)
			var spin_added: float = -b.v.dot(tangent) / b.r * 0.70
			b.spin_kick = clampf(b.spin_kick + spin_added, -18.0, 18.0)
			b.spin = clampf(b.spin + spin_added, -20.0, 20.0)
			b.impact = maxf(b.impact, minf(-approach / 450.0, 1.0))
			b.v -= (1 + bounce) * approach * n
			_record_debug_contact("tower", ball_index, tower_index, t.p + n * t.hit_r, n, -approach, correction)
			_add_tower_impact(ball_index, tower_index, t.p + n * t.hit_r, n, -approach, t.side)
			_apply_tower_damage(b, tower_index, n, b.armed)
			if not b.alive: break
	_collide_field_walls(previous_positions, dt)
	if debug_collisions:
		for ball_index in range(balls.size()):
			var ball = balls[ball_index]
			if not ball.alive: continue
			for tower_index in range(towers.size()):
				var tower = towers[tower_index]
				var delta: Vector2 = ball.p - tower.p
				if delta.length() < ball.r + tower.r - 0.25:
					_record_debug_contact("outside fan", ball_index, tower_index, ball.p, delta.normalized(), ball.v.length(), 0.0)

func _sweep_boundary(origin: Vector2, travel: Vector2, radius: float) -> Dictionary:
	var best_time := 2.0
	var best := {}
	var travel_squared: float = travel.length_squared()
	if travel_squared < 0.000001: return best
	for segment_index in range(boundary_outline.size()):
		var a: Vector2 = boundary_outline[segment_index]
		var b: Vector2 = boundary_outline[(segment_index + 1) % boundary_outline.size()]
		var edge: Vector2 = b - a
		var length_squared: float = edge.length_squared()
		if length_squared < 0.000001: continue
		var inward: Vector2 = Vector2(-edge.y, edge.x).normalized()
		var velocity_normal: float = travel.dot(inward)
		if velocity_normal < -0.000001:
			var start_clearance: float = (origin - a).dot(inward)
			var time: float = (radius - start_clearance) / velocity_normal
			if time >= 0.0 and time <= 1.0 and time < best_time:
				var center: Vector2 = origin + travel * time
				var along: float = (center - a).dot(edge) / length_squared
				if along >= 0.0 and along <= 1.0:
					best_time = time
					best = {"time": time, "normal": inward, "point": a + edge * along, "segment": segment_index}
		# Swept endpoint circles close the join between neighboring segments.
		var relative: Vector2 = origin - a
		var half_b: float = relative.dot(travel)
		var discriminant: float = half_b * half_b - travel_squared * (relative.length_squared() - radius * radius)
		if discriminant < 0.0: continue
		var vertex_time: float = (-half_b - sqrt(discriminant)) / travel_squared
		if vertex_time < 0.0 or vertex_time > 1.0 or vertex_time >= best_time: continue
		var vertex_normal: Vector2 = (origin + travel * vertex_time - a).normalized()
		if travel.dot(vertex_normal) >= -0.000001: continue
		best_time = vertex_time
		best = {"time": vertex_time, "normal": vertex_normal, "point": a, "segment": segment_index}
	return best

func _resolve_boundary_overlap(ball: Dictionary, ball_index: int) -> void:
	for correction_pass in range(3):
		var closest_squared := INF
		var closest_point := Vector2.ZERO
		var closest_inward := Vector2.ZERO
		var closest_segment := -1
		for segment_index in range(boundary_outline.size()):
			var a: Vector2 = boundary_outline[segment_index]
			var b: Vector2 = boundary_outline[(segment_index + 1) % boundary_outline.size()]
			var edge: Vector2 = b - a
			var squared: float = edge.length_squared()
			if squared < 0.000001: continue
			var along: float = clampf((ball.p - a).dot(edge) / squared, 0.0, 1.0)
			var point: Vector2 = a + edge * along
			var distance_squared: float = ball.p.distance_squared_to(point)
			if distance_squared < closest_squared:
				closest_squared = distance_squared
				closest_point = point
				closest_inward = Vector2(-edge.y, edge.x).normalized()
				closest_segment = segment_index
		if closest_squared >= ball.r * ball.r: break
		var distance: float = sqrt(closest_squared)
		var normal: Vector2 = (ball.p - closest_point) / distance if distance > 0.0001 else closest_inward
		if normal.dot(closest_inward) < 0.0: normal = closest_inward
		var correction: float = ball.r + 0.05 - distance
		ball.p += normal * correction
		var approach: float = ball.v.dot(normal)
		if approach < 0.0:
			ball.v -= (1.0 + bounce) * approach * normal
			ball.impact = maxf(ball.impact, minf(-approach / 450.0, 1.0))
			if ball.kind != "player": ball.armed = true
		_record_debug_contact("wall", ball_index, closest_segment, closest_point, normal, maxf(-approach, 0.0), correction)

func _collide_field_walls(previous_positions: Array[Vector2] = [], dt: float = 0.0) -> void:
	if previous_positions.is_empty():
		for ball in balls: previous_positions.append(ball.p)
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		var position: Vector2 = previous_positions[ball_index]
		var travel: Vector2 = b.p - position
		for contact_index in range(4):
			var hit: Dictionary = _sweep_boundary(position, travel, b.r)
			if hit.is_empty():
				position += travel
				break
			var time: float = hit.time
			var normal: Vector2 = hit.normal
			position += travel * time + normal * 0.05
			var approach: float = b.v.dot(normal)
			if approach < 0.0:
				var eligible_before_wall: bool = b.armed
				b.v -= (1.0 + bounce) * approach * normal
				b.impact = maxf(b.impact, minf(-approach / 450.0, 1.0))
				_damage_side_tower_wall_contact(b, hit.point, normal, eligible_before_wall)
				# A player ball bouncing off a wall does not become tower-eligible.
				if b.kind != "player": b.armed = true
			_record_debug_contact("wall", ball_index, hit.segment, hit.point, normal, maxf(-approach, 0.0), 0.0)
			if not b.alive: break
			travel = b.v * dt * (1.0 - time)
		b.p = position
		_resolve_boundary_overlap(b, ball_index)

func _heal_team(side: int, amount: int) -> int:
	var target: Dictionary = {}
	for tower in towers:
		if tower.side != side or tower.hp <= 0 or tower.hp >= 100: continue
		if target.is_empty() or tower.hp < target.hp: target = tower
	if target.is_empty(): return 0
	var healed: int = mini(amount, 100 - target.hp)
	target.hp += healed
	return healed

func _draw():
	# Mirror the artwork's space-only margins beyond the shifted arena; never duplicate a tower in the backdrop.
	draw_set_transform(Vector2(0.0, 75.0), 0.0, Vector2(1.0, -1.0))
	draw_texture_rect_region(ARENA_ARTWORK, Rect2(Vector2.ZERO, Vector2(540.0, 127.0)), Rect2(Vector2.ZERO, Vector2(1024.0, 150.0)))
	draw_set_transform(Vector2(0.0, 885.0), 0.0, Vector2(1.0, -1.0))
	draw_texture_rect_region(ARENA_ARTWORK, Rect2(Vector2(0.0, -127.0), Vector2(540.0, 127.0)), Rect2(Vector2(0.0, 1386.0), Vector2(1024.0, 150.0)))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_texture_rect(ARENA_ARTWORK, SKIN_DRAW_RECT, false)
	_draw_balls()
	_draw_tower_impacts()
	if aiming and turn < balls.size() and balls[turn].alive:
		var p: Vector2 = balls[turn].p
		draw_line(p, p + pull, Color("ffe58a"), 7.0, true)
		draw_line(p, p + pull, Color("fff8d6"), 2.0, true)
		draw_circle(p + pull, 8, Color("fff1ad"))
	if debug_mode and debug_collisions: _draw_collision_debug()

func _draw_collision_debug() -> void:
	var field_color := Color("b5ff89")
	for i in range(boundary_outline.size()):
		draw_line(boundary_outline[i], boundary_outline[(i + 1) % boundary_outline.size()], field_color, 2.0)
	for joint in boundary_joints: draw_circle(joint, 2.5, Color("ffdf75"))
	for tower_index in range(towers.size()):
		var t = towers[tower_index]
		if t.hp <= 0: continue
		var start_angle: float = t.inward.angle() - t.fan_half
		var end_angle: float = t.inward.angle() + t.fan_half
		draw_arc(t.p, t.r, 0.0, TAU, 48, Color("ffffff"), 1.5)
		draw_circle(t.p, 2.5, Color("ff765d"))
		draw_arc(t.p, t.hit_r, start_angle, end_angle, 18, Color("54e9ff"), 2.0)
		if not t.main:
			var mirror: Vector2 = t.damage_mirror
			for tolerance in [false, true]:
				var low: float = SIDE_DAMAGE_ARC_START_DEG - (side_damage_tolerance_deg if tolerance else 0.0)
				var high: float = SIDE_DAMAGE_ARC_END_DEG + (side_damage_tolerance_deg if tolerance else 0.0)
				var points := PackedVector2Array()
				for sample in range(33):
					var angle: float = deg_to_rad(lerpf(low, high, float(sample) / 32.0))
					points.append(t.p + Vector2.from_angle(angle) * mirror * (t.r + (7.0 if tolerance else 4.0)))
				draw_polyline(points, Color("ff638a") if tolerance else Color("ffd36d"), 2.0)
			for endpoint in [SIDE_DAMAGE_ARC_START_DEG, SIDE_DAMAGE_ARC_END_DEG]:
				var direction: Vector2 = Vector2.from_angle(deg_to_rad(endpoint)) * mirror
				draw_circle(t.p + direction * t.r, 2.5, Color("ff638a"))
		# All current balls have radius 18: this arc is the center's contact boundary.
		draw_arc(t.p, t.hit_r + 18.0, start_angle, end_angle, 18, Color("ffcf70"), 2.0)
		for angle in [start_angle, end_angle]:
			draw_line(t.p, t.p + Vector2.from_angle(angle) * (t.hit_r + 18.0), Color("ffcf70", 0.6), 1.0)
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		draw_arc(b.p, b.r, 0.0, TAU, 40, Color("74ffad"), 1.5)
		var velocity: Vector2 = b.v
		if velocity.length_squared() > 1.0:
			var tip: Vector2 = b.p + velocity.normalized() * minf(velocity.length() * 0.045, 55.0)
			draw_line(b.p, tip, Color("ffe48c"), 2.0, true)
			draw_circle(tip, 2.5, Color("ffe48c"))
	for contact in debug_contacts:
		var point: Vector2 = contact.point
		var normal: Vector2 = contact.normal
		if contact.kind == "outside fan":
			draw_line(point + Vector2(-5, -5), point + Vector2(5, 5), Color("ff5aca"), 2.0)
			draw_line(point + Vector2(-5, 5), point + Vector2(5, -5), Color("ff5aca"), 2.0)
			continue
		var contact_color := Color("ffd26b") if contact.kind == "tower" else Color("b8a1ff")
		draw_circle(point, 3.0, contact_color)
		draw_line(point, point + normal * 22.0, contact_color, 2.0, true)

func _draw_arena():
	for edge_index in range(boundary_outline.size()):
		var a: Vector2 = boundary_outline[edge_index]
		var b: Vector2 = boundary_outline[(edge_index + 1) % boundary_outline.size()]
		draw_line(a, b, Color(0.74, 0.63, 1.0, 0.18), 2.0)

func _draw_tower_impacts() -> void:
	for effect in tower_impacts:
		var fade: float = clampf(effect.life / effect.duration, 0.0, 1.0)
		var strength: float = effect.strength
		var point: Vector2 = effect.p
		var normal: Vector2 = effect.n
		var tangent := Vector2(-normal.y, normal.x)
		var flash := Color("fff3d6")
		flash.a = fade * (0.35 + strength * 0.45)
		draw_circle(point, 1.5 + strength * 3.5, flash)
		var spark := Color("8de8ff") if effect.side == 0 else Color("ff9eae")
		spark.a = fade * (0.25 + strength * 0.50)
		for direction in [-normal, (-normal + tangent * 0.7).normalized(), (-normal - tangent * 0.7).normalized()]:
			draw_line(point + direction * 3.0, point + direction * (5.0 + strength * 9.0), spark, 1.0 + strength, true)

func _show_turn_halo(b: Dictionary) -> bool:
	var velocity: Vector2 = b.v
	return b.alive and b.kind == "player" and b.id == turn and not aiming and not moving and not finished and velocity.is_zero_approx()

func _draw_balls():
	for b in balls:
		if not b.alive: continue
		var c: Color = Color("9aacbf")
		if b.kind == "fire": c = Color("ff9b43")
		elif b.kind == "iron": c = Color("62d7e6")
		elif b.kind == "vampire": c = Color("e64ea8")
		elif b.kind == "player": c = Color("55c7ff") if b.id < 2 else Color("ff6683")
		var artwork: Texture2D = null
		if b.kind == "fire":
			artwork = FIRE_ARTWORK
		elif b.kind == "iron":
			artwork = IRON_ARTWORK
		elif b.kind == "vampire":
			artwork = VAMPIRE_ARTWORK
		if artwork != null:
			var art_size: float = b.r * 2.25
			if b.kind == "fire":
				var speed_ratio := clampf(b.v.length() / 500.0, 0.0, 1.0)
				if speed_ratio > 0.04:
					var trail_direction: Vector2 = b.v.normalized()
					for trail in range(3, 0, -1):
						var trail_pos: Vector2 = b.p - trail_direction * (b.r * 0.6 + float(trail) * b.r * 0.45)
						draw_circle(trail_pos, b.r * (0.55 - float(trail) * 0.1), Color(1.0, 0.30, 0.04, speed_ratio * (4.0 - float(trail)) * 0.085))
			var pulse: float = 1.0 + b.impact * 0.08
			draw_set_transform(b.p, b.angle, Vector2.ONE * pulse)
			draw_texture_rect(artwork, Rect2(Vector2.ONE * art_size * -0.5, Vector2.ONE * art_size), false)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			# Rotate the asymmetric highlights so tower contact is visible on player balls too.
			draw_set_transform(b.p, b.angle, Vector2.ONE * (1.0 + b.impact * 0.04))
			draw_circle(Vector2.ZERO, b.r + 1, c.darkened(0.55))
			draw_circle(Vector2.ZERO, b.r, c.darkened(0.06))
			draw_arc(Vector2.ZERO, b.r - 2, -PI * 0.88, PI * 0.65, 40, c.lightened(0.50), 2.0)
			draw_arc(Vector2.ZERO, b.r * 0.66, PI * 0.12, PI * 0.74, 28, c.darkened(0.35), 2.0)
			draw_circle(Vector2(-b.r * 0.32, -b.r * 0.34), max(3.0, b.r * 0.22), Color(1, 1, 1, 0.88))
			draw_circle(Vector2(b.r * 0.22, b.r * 0.30), max(2.0, b.r * 0.09), Color(1, 1, 1, 0.35))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if _show_turn_halo(b):
			draw_arc(b.p, b.r + 1.5, 0, TAU, 56, Color(0.75, 0.96, 1.0, 0.85), 2.0)
		if b.kind == "player":
			draw_set_transform(b.p, PI if get_view_side() == 0 else 0.0, Vector2.ONE)
			draw_string(font, Vector2(-7, 7), str(b.id + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("102236"))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func field_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color("0b2634")
	s.border_color = Color("27cfe0")
	s.set_border_width_all(3)
	s.set_corner_radius_all(18)
	return s
