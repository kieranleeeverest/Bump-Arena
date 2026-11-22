extends SceneTree

var max_wall_fix := 0.0
var max_wall_fix_case := ""

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

func _test_path(game: Node, label: String, start: Vector2, velocity: Vector2, count: int = 100) -> bool:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 4: game.balls[i].alive = false
	var ball: Dictionary = game.balls[4]
	ball.p = start
	ball.v = velocity
	if not _inside(start, game.boundary_outline) or _clearance(start, game.boundary_outline) < ball.r:
		push_error("Invalid test start: %s p=%s inside=%s clearance=%.2f" % [label, str(start), str(_inside(start, game.boundary_outline)), _clearance(start, game.boundary_outline)])
		return false
	for tick in range(count):
		var speed_before: float = ball.v.length()
		game.step(1.0 / 240.0)
		for event in game.debug_contacts:
			if event.kind == "wall" and event.correction > max_wall_fix:
				max_wall_fix = event.correction
				max_wall_fix_case = "%s tick=%d point=%s" % [label, tick, str(event.point)]
		game.debug_contacts.clear()
		var clearance: float = _clearance(ball.p, game.boundary_outline)
		if not _inside(ball.p, game.boundary_outline) or clearance < ball.r - 0.25:
			push_error("Boundary overlap %s tick=%d clearance=%.2f pos=%s" % [label, tick, clearance, str(ball.p)])
			return false
		if ball.v.length() > speed_before + 1.0:
			push_error("Energy gain %s tick=%d" % [label, tick])
			return false
	return true

func _initialize() -> void:
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	game.reset_game()
	game.debug_collisions = true
	for pair in [[0, 2], [3, 5]]:
		var left: Dictionary = game.towers[pair[0]]
		var right: Dictionary = game.towers[pair[1]]
		if left.r != right.r or left.hit_r != right.hit_r or left.p.y != right.p.y or absf(left.p.x + right.p.x - 540.0) > 0.01:
			push_error("Side tower geometry is not mirror matched")
			quit(1)
			return
	if game.towers[0].r != game.towers[3].r or game.towers[1].r != game.towers[4].r:
		push_error("Top and bottom tower radii differ")
		quit(1)
		return
	var outline: PackedVector2Array = game.boundary_outline
	for edge_a in range(outline.size()):
		var start_a: Vector2 = outline[edge_a]
		var direction_a: Vector2 = outline[(edge_a + 1) % outline.size()] - start_a
		for edge_b in range(edge_a + 2, outline.size()):
			if edge_a == 0 and edge_b == outline.size() - 1: continue
			var start_b: Vector2 = outline[edge_b]
			var direction_b: Vector2 = outline[(edge_b + 1) % outline.size()] - start_b
			var denominator: float = direction_a.cross(direction_b)
			if absf(denominator) < 0.00001: continue
			var fraction_a: float = (start_b - start_a).cross(direction_b) / denominator
			var fraction_b: float = (start_b - start_a).cross(direction_a) / denominator
			if fraction_a > 0.0001 and fraction_a < 0.9999 and fraction_b > 0.0001 and fraction_b < 0.9999:
				push_error("Boundary self-intersection between segments %d and %d" % [edge_a, edge_b])
				quit(1)
				return
	var max_arc_edge := 0.0
	var max_turn_degrees := 0.0
	var max_turn_index := -1
	var max_tower_inset := 0.0
	for i in range(outline.size()):
		for tower in game.towers:
			max_tower_inset = maxf(max_tower_inset, tower.r - outline[i].distance_to(tower.p))
		var length: float = outline[i].distance_to(outline[(i + 1) % outline.size()])
		if length < 0.001:
			push_error("Zero-length boundary segment")
			quit(1)
			return
		if length < 20.0: max_arc_edge = maxf(max_arc_edge, length)
		var previous: Vector2 = outline[i] - outline[(i - 1 + outline.size()) % outline.size()]
		var following: Vector2 = outline[(i + 1) % outline.size()] - outline[i]
		var turn_degrees: float = rad_to_deg(acos(clampf(previous.normalized().dot(following.normalized()), -1.0, 1.0)))
		if turn_degrees > max_turn_degrees:
			max_turn_degrees = turn_degrees
			max_turn_index = i
	if max_turn_degrees > 22.0 or max_tower_inset > 0.25:
		push_error("Boundary join is too sharp or enters a visible tower circle")
		quit(1)
		return
	var tested := 0
	for tower_index in range(game.towers.size()):
		var tower: Dictionary = game.towers[tower_index]
		var inward: Vector2 = tower.inward
		var tangent := Vector2(-inward.y, inward.x)
		for offset in [-16.0, 0.0, 16.0]:
			for speed in [180.0, 700.0, 1620.0]:
				var start: Vector2 = tower.p + inward * (tower.hit_r + 18.0 + 42.0) + tangent * offset
				var velocity: Vector2 = -inward * speed + tangent * (speed * 0.18 if offset > 0.0 else -speed * 0.18 if offset < 0.0 else 0.0)
				var label := "tower %d offset %.0f speed %.0f" % [tower_index, offset, speed]
				if not _test_path(game, label, start, velocity):
					quit(1)
					return
				tested += 1
	for edge_index in range(game.field_corners.size()):
		var a: Vector2 = game.field_corners[edge_index]
		var b: Vector2 = game.field_corners[(edge_index + 1) % game.field_corners.size()]
		var tangent: Vector2 = (b - a).normalized()
		var inward := Vector2(-tangent.y, tangent.x)
		var midpoint: Vector2 = (a + b) * 0.5
		for speed in [180.0, 1620.0]:
			if not _test_path(game, "straight %d speed %.0f" % [edge_index, speed], midpoint + inward * 45.0, -inward * speed + tangent * speed * 0.12):
				quit(1)
				return
			tested += 1
		if not _test_path(game, "slide %d" % edge_index, midpoint + inward * 18.3, tangent * 700.0 - inward * 15.0):
			quit(1)
			return
		tested += 1
	for tower_index in [0, 2, 3, 5]:
		for offset in [0.0, 10.0, 16.0, 20.0]:
			game.reset_game()
			for i in range(game.balls.size()):
				if i != 0 and i != 4: game.balls[i].alive = false
			var tower: Dictionary = game.towers[tower_index]
			var inward: Vector2 = tower.inward
			var tangent := Vector2(-inward.y, inward.x)
			var near_ball: Dictionary = game.balls[0]
			var iron: Dictionary = game.balls[4]
			near_ball.p = tower.p + inward * (iron.r + tower.hit_r + 18.0) + tangent * offset
			iron.p = tower.p + inward * (iron.r + tower.hit_r + 56.0) + tangent * offset
			for test_ball in [near_ball, iron]:
				for adjustment in range(20):
					if _inside(test_ball.p, game.boundary_outline) and _clearance(test_ball.p, game.boundary_outline) >= test_ball.r + 0.5: break
					test_ball.p += inward * 5.0
			iron.v = -inward * 1500.0 + tangent * 600.0
			for tick in range(120):
				game.step(1.0 / 240.0)
				for event in game.debug_contacts:
					if event.kind == "wall" and event.correction > max_wall_fix:
						max_wall_fix = event.correction
						max_wall_fix_case = "multi-ball tower=%d offset=%.0f tick=%d point=%s" % [tower_index, offset, tick, str(event.point)]
				game.debug_contacts.clear()
				for ball in [near_ball, iron]:
					if not _inside(ball.p, game.boundary_outline) or _clearance(ball.p, game.boundary_outline) < ball.r - 0.25:
						push_error("Multi-ball boundary overlap tower=%d offset=%.0f tick=%d" % [tower_index, offset, tick])
						quit(1)
						return
			tested += 1
	game.reset_game()
	for i in range(game.balls.size()):
		game.balls[i].v = Vector2(260.0 + i * 25.0, -180.0 + i * 50.0)
	var started := Time.get_ticks_usec()
	for tick in range(500): game.step(1.0 / 240.0)
	var average_ms: float = float(Time.get_ticks_usec() - started) / 500000.0
	print("BOUNDARY_STRESS_METRICS max_wall_fix=%.3f case=%s avg_step_ms=%.3f" % [max_wall_fix, max_wall_fix_case, average_ms])
	if max_wall_fix > 1.0:
		push_error("Boundary needed a large post-contact correction")
		quit(1)
		return
	print("BOUNDARY_CONTOUR_OK paths=%d points=%d arc_step_max=%.2f max_turn_deg=%.1f tower_inset=%.2f max_wall_fix=%.2f avg_step_ms=%.3f" % [tested, outline.size(), max_arc_edge, max_turn_degrees, max_tower_inset, max_wall_fix, average_ms])
	game.free()
	quit()
