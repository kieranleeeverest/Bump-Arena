extends SceneTree

func _only_ball(game: Node, index: int) -> Dictionary:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != index: game.balls[i].alive = false
	return game.balls[index]

func _initialize() -> void:
	var game: Node = load("res://scripts/game/PrototypeMatch.gd").new()
	var ball: Dictionary = _only_ball(game, 4)
	var edge: Vector2 = game.field_corners[1] - game.field_corners[0]
	var inward := Vector2(-edge.y, edge.x).normalized()
	var midpoint: Vector2 = (game.field_corners[0] + game.field_corners[1]) * 0.5
	ball.p = midpoint + inward * (ball.r - 1.0)
	ball.v = -inward * 300.0
	game._collide_field_walls()
	assert(ball.v.dot(inward) > 0.0, "Sloped wall did not reflect")
	assert((ball.p - midpoint).dot(inward) >= ball.r - 0.1)

	ball = _only_ball(game, 4)
	var top: Dictionary = game.towers[1]
	ball.armed = true
	ball.p = top.p + top.inward * (ball.r + top.hit_r + 2.0)
	ball.v = -top.inward * 250.0
	game.step(0.01)
	assert(top.hp == 90, "Main tower damage changed")
	assert(absf(ball.spin_kick) < 0.01)

	ball = _only_ball(game, 4)
	top = game.towers[1]
	var tangent := Vector2(-top.inward.y, top.inward.x)
	ball.armed = true
	ball.p = top.p + top.inward * (ball.r + top.hit_r + 2.0) + tangent * 2.0
	ball.v = -top.inward * 250.0 + tangent * 220.0
	game.step(0.01)
	assert(top.hp == 90)
	assert(absf(ball.spin_kick) > 5.0)
	game._update_orb_visuals(0.1)
	assert(minf(ball.angle, TAU - ball.angle) > 0.2)

	var player: Dictionary = _only_ball(game, 0)
	top = game.towers[1]
	player.armed = true
	player.p = top.p + top.inward * (player.r + top.hit_r + 2.0) + tangent * 2.0
	player.v = -top.inward * 250.0 + tangent * 220.0
	game.step(0.01)
	assert(absf(player.spin_kick) > 5.0)

	ball = _only_ball(game, 4)
	var side: Dictionary = game.towers[0]
	ball.armed = true
	ball.p = side.p + Vector2.RIGHT * (ball.r + side.hit_r + 2.0)
	ball.v = Vector2.LEFT * 250.0
	game.step(0.01)
	assert(side.hp == 100, "Outside-fan hit damaged side tower")

	ball = _only_ball(game, 4)
	side = game.towers[0]
	ball.armed = true
	ball.p = side.p + side.inward * (ball.r + side.hit_r + 2.0)
	ball.v = -side.inward * 300.0
	game.step(0.01)
	assert(side.hp == 90, "Inward side tower contact missed")

	var vampire: Dictionary = _only_ball(game, 6)
	var bottom: Dictionary = game.towers[4]
	vampire.owner_side = 0
	vampire.armed = true
	vampire.p = bottom.p + bottom.inward * (vampire.r + bottom.hit_r + 2.0)
	vampire.v = -bottom.inward * 250.0
	game.towers[1].hp = 60
	game.step(0.01)
	assert(bottom.hp == 90)
	assert(game.towers[1].hp == 70)
	print("ANGLED_COLLISIONS_OK")
	game.free()
	quit()
