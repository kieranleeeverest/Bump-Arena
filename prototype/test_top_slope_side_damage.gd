extends SceneTree

func _inside(point: Vector2, outline: PackedVector2Array) -> bool:
	var inside := false
	for i in range(outline.size()):
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % outline.size()]
		if (a.y > point.y) != (b.y > point.y):
			if point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y): inside = not inside
	return inside

func _clearance(point: Vector2, outline: PackedVector2Array) -> float:
	var nearest := INF
	for i in range(outline.size()):
		var a: Vector2 = outline[i]
		var edge: Vector2 = outline[(i + 1) % outline.size()] - a
		var u: float = clampf((point - a).dot(edge) / edge.length_squared(), 0.0, 1.0)
		nearest = minf(nearest, point.distance_to(a + edge * u))
	return nearest

func _initialize() -> void:
	var game: Node = load("res://scripts/game/PrototypeMatch.gd").new()
	game.reset_game()
	assert(game.FIELD_CORNERS_IMAGE[0] == Vector2(120, 347))
	assert(game.FIELD_CORNERS_IMAGE[1] == Vector2(512, 254))
	assert(game.FIELD_CORNERS_IMAGE[2] == Vector2(904, 347))
	var tested := 0
	for edge_index in [0, 1]:
		game.reset_game()
		for i in range(game.balls.size()):
			if i != 0: game.balls[i].alive = false
		var a: Vector2 = game.field_corners[edge_index]
		var z: Vector2 = game.field_corners[edge_index + 1]
		var tangent: Vector2 = (z - a).normalized()
		var inward := Vector2(-tangent.y, tangent.x)
		var sliding: Dictionary = game.balls[0]
		sliding.p = (a + z) * 0.5 + inward * (sliding.r + 0.5)
		sliding.v = tangent * 180.0 - inward * 8.0
		for tick in range(120):
			var old_speed: float = sliding.v.length()
			game.step(1.0 / 240.0)
			assert(_inside(sliding.p, game.boundary_outline) and _clearance(sliding.p, game.boundary_outline) >= sliding.r - 0.25, "Top rail slide overlap")
			assert(sliding.v.length() <= old_speed + 1.0, "Top rail slide gained energy")
		tested += 1
	for tower_index in [0, 2, 3, 5]:
		var tower: Dictionary = game.towers[tower_index]
		var feasible: Array[int] = []
		for angle in range(-5, 76):
			var radial: Vector2 = Vector2.from_angle(deg_to_rad(float(angle))) * tower.damage_mirror
			var p: Vector2 = tower.p + radial * (tower.r + 18.5)
			if _inside(p, game.boundary_outline) and _clearance(p, game.boundary_outline) >= 18.0:
				feasible.append(angle)
		assert(not feasible.is_empty(), "Side tower has no reachable damage arc")
		print("SIDE_ACCESS tower=%d local_angle=%d..%d target=-5..75" % [tower_index, feasible.front(), feasible.back()])
		for angle in [feasible.front() + 2, (feasible.front() + feasible.back()) / 2, feasible.back() - 2]:
			game.reset_game()
			tower = game.towers[tower_index]
			for i in range(game.balls.size()):
				if i != 0: game.balls[i].alive = false
			var ball: Dictionary = game.balls[0]
			var radial: Vector2 = Vector2.from_angle(deg_to_rad(float(angle))) * tower.damage_mirror
			ball.p = tower.p + radial * (tower.r + ball.r + 5.0)
			ball.v = -radial * 180.0
			ball.armed = true
			if not _inside(ball.p, game.boundary_outline) or _clearance(ball.p, game.boundary_outline) < ball.r: continue
			for tick in range(60): game.step(1.0 / 240.0)
			assert(tower.hp == 90, "One armed side-tower contact must deal damage exactly once")
			tested += 1
		for ball_index in [0, 4]:
			for speed in [180.0, 1620.0]:
				game.reset_game()
				tower = game.towers[tower_index]
				for i in range(game.balls.size()):
					if i != ball_index: game.balls[i].alive = false
				var ball: Dictionary = game.balls[ball_index]
				var radial: Vector2 = Vector2.from_angle(deg_to_rad(38.0)) * tower.damage_mirror
				ball.p = tower.p + radial * (tower.r + ball.r + 5.0)
				ball.v = -radial * speed
				ball.armed = true
				for tick in range(60): game.step(1.0 / 240.0)
				assert(tower.hp == 90, "Player/iron side contact must deal one hit at both speeds")
				tested += 1
		for angle in [-6.0, -5.0, 0.0, 70.0, 75.0, 76.0]:
			var radial: Vector2 = Vector2.from_angle(deg_to_rad(angle)) * tower.damage_mirror
			assert(game._side_damage_angle(tower, radial) == (angle >= -5.0 and angle <= 75.0))
	assert(game.towers[1].fan_half == deg_to_rad(24.0) and game.towers[4].fan_half == deg_to_rad(24.0))
	print("TOP_SLOPE_SIDE_DAMAGE_OK contacts=%d" % tested)
	game.free()
	quit()
