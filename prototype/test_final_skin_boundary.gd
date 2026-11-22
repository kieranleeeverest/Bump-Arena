extends SceneTree

var tested := 0
var max_correction := 0.0
var max_speed_gain := 0.0

func _inside(point: Vector2, outline: PackedVector2Array) -> bool:
	var inside := false
	for i in range(outline.size()):
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % outline.size()]
		if (a.y > point.y) != (b.y > point.y):
			var crossing_x: float = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y)
			if point.x < crossing_x: inside = not inside
	return inside

func _clearance(point: Vector2, outline: PackedVector2Array) -> float:
	var nearest := INF
	for i in range(outline.size()):
		var a: Vector2 = outline[i]
		var edge: Vector2 = outline[(i + 1) % outline.size()] - a
		var along: float = clampf((point - a).dot(edge) / edge.length_squared(), 0.0, 1.0)
		nearest = minf(nearest, point.distance_to(a + edge * along))
	return nearest

func _probe(game: Node, ball_index: int, label: String, contact: Vector2, inward: Vector2, speed: float, tangent_speed: float = 0.0) -> bool:
	game.reset_game()
	game.debug_collisions = true
	for i in range(game.balls.size()):
		if i != ball_index: game.balls[i].alive = false
	var ball: Dictionary = game.balls[ball_index]
	ball.p = contact + inward * (ball.r + 50.0)
	for adjustment in range(15):
		if _inside(ball.p, game.boundary_outline) and _clearance(ball.p, game.boundary_outline) >= ball.r + 1.0: break
		ball.p += inward * 5.0
	if not _inside(ball.p, game.boundary_outline) or _clearance(ball.p, game.boundary_outline) < ball.r + 1.0:
		inward = (Vector2(270, 470) - contact).normalized()
		ball.p = contact + inward * (ball.r + 50.0)
		for adjustment in range(15):
			if _inside(ball.p, game.boundary_outline) and _clearance(ball.p, game.boundary_outline) >= ball.r + 1.0: break
			ball.p += inward * 5.0
	if not _inside(ball.p, game.boundary_outline) or _clearance(ball.p, game.boundary_outline) < ball.r + 1.0:
		push_error("Invalid start %s at %s" % [label, str(ball.p)])
		return false
	var tangent := Vector2(-inward.y, inward.x)
	ball.v = -inward * speed + tangent * tangent_speed
	var contacts := 0
	for tick in range(90):
		var before_speed: float = ball.v.length()
		game.step(1.0 / 240.0)
		for event in game.debug_contacts:
			if event.kind != "wall" and event.kind != "tower": continue
			contacts += 1
			max_correction = maxf(max_correction, event.correction)
			# Tower correction includes the remaining swept travel inside this substep.
			# It is resolved before drawing; residual wall overlap must stay subpixel.
			var correction_limit: float = speed / 240.0 + 0.2 if event.kind == "tower" else 1.0
			if event.correction > correction_limit:
				push_error("Large correction %s tick=%d kind=%s correction=%.2f" % [label, tick, event.kind, event.correction])
				return false
		game.debug_contacts.clear()
		if not ball.alive: break
		var clearance: float = _clearance(ball.p, game.boundary_outline)
		if not _inside(ball.p, game.boundary_outline) or clearance < ball.r - 0.25:
			push_error("Overlap %s tick=%d clearance=%.2f" % [label, tick, clearance])
			return false
		max_speed_gain = maxf(max_speed_gain, ball.v.length() - before_speed)
		if ball.v.length() > before_speed + 1.0:
			push_error("Energy gain %s tick=%d" % [label, tick])
			return false
	if contacts == 0:
		push_error("No contact %s" % label)
		return false
	tested += 1
	return true

func _slide(game: Node, ball_index: int, edge_index: int) -> bool:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != ball_index: game.balls[i].alive = false
	var a: Vector2 = game.field_corners[edge_index]
	var b: Vector2 = game.field_corners[(edge_index + 1) % game.field_corners.size()]
	var tangent: Vector2 = (b - a).normalized()
	var inward := Vector2(-tangent.y, tangent.x)
	var ball: Dictionary = game.balls[ball_index]
	ball.p = (a + b) * 0.5 + inward * (ball.r + 0.4)
	ball.v = tangent * 180.0 - inward * 8.0
	for tick in range(120):
		var before_speed: float = ball.v.length()
		game.step(1.0 / 240.0)
		if not _inside(ball.p, game.boundary_outline) or _clearance(ball.p, game.boundary_outline) < ball.r - 0.25:
			push_error("Low-speed slide overlap ball=%d edge=%d tick=%d" % [ball_index, edge_index, tick])
			return false
		if ball.v.length() > before_speed + 1.0:
			push_error("Low-speed slide energy gain ball=%d edge=%d tick=%d" % [ball_index, edge_index, tick])
			return false
	tested += 1
	return true

func _initialize() -> void:
	var game: Node = load("res://scripts/game/PrototypeMatch.gd").new()
	game.reset_game()
	for ball_index in [0, 2, 4]:
		for edge_index in [2, 5]:
			if not _slide(game, ball_index, edge_index):
				quit(1)
				return
		for edge_index in range(game.field_corners.size()):
			var a: Vector2 = game.field_corners[edge_index]
			var b: Vector2 = game.field_corners[(edge_index + 1) % game.field_corners.size()]
			var edge: Vector2 = b - a
			var inward := Vector2(-edge.y, edge.x).normalized()
			for speed in [180.0, 1620.0]:
				if not _probe(game, ball_index, "ball %d straight %d speed %.0f" % [ball_index, edge_index, speed], (a + b) * 0.5, inward, speed):
					quit(1)
					return
		for tower_index in range(game.towers.size()):
			var tower: Dictionary = game.towers[tower_index]
			var inward: Vector2 = tower.inward
			for speed in [180.0, 1620.0]:
				if not _probe(game, ball_index, "ball %d tower %d speed %.0f" % [ball_index, tower_index, speed], tower.p + inward * tower.r, inward, speed):
					quit(1)
					return
		for corner_index in range(6):
			var joint: Vector2 = game.boundary_joints[corner_index * 4 + 1]
			var center: Vector2 = game.towers[game.CORNER_TOWER_INDICES[corner_index]].p
			var inward: Vector2 = (joint - center).normalized()
			for speed in [180.0, 1620.0]:
				if not _probe(game, ball_index, "ball %d joint %d speed %.0f" % [ball_index, corner_index, speed], joint, inward, speed, speed * 0.12):
					quit(1)
					return
	print("FINAL_SKIN_BOUNDARY_OK paths=%d ball_indices=0,2,4 max_correction=%.3f max_speed_gain=%.3f" % [tested, max_correction, max_speed_gain])
	game.free()
	quit()
