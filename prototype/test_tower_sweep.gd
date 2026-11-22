extends SceneTree

func _tower_shot(game: Node, velocity: Vector2, offset: float) -> void:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 4: game.balls[i].alive = false
	var ball: Dictionary = game.balls[4]
	var tower: Dictionary = game.towers[1]
	var radius: float = ball.r + tower.hit_r
	ball.p = tower.p + Vector2(offset, radius + 24.0)
	ball.v = velocity
	ball.armed = true
	var bounced := false
	for tick in range(160):
		game.step(1.0 / 240.0)
		var delta: Vector2 = ball.p - tower.p
		if delta.length_squared() > 0.000001 and delta.normalized().dot(tower.inward) >= cos(tower.fan_half):
			assert(delta.length() >= radius - 0.2, "Ball overlaps the tower fan")
		if ball.v.y > 0.0:
			bounced = true
			break
	assert(bounced, "Expected a tower bounce")

func _other_tower_shot(game: Node, tower_index: int) -> void:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 4: game.balls[i].alive = false
	var ball: Dictionary = game.balls[4]
	var tower: Dictionary = game.towers[tower_index]
	var inward: Vector2 = tower.inward
	var tangent := Vector2(-inward.y, inward.x)
	var radius: float = ball.r + tower.hit_r
	ball.p = tower.p + inward * (radius + 40.0)
	ball.v = -inward * 1200.0
	ball.armed = true
	var bounced := false
	for tick in range(80):
		game.step(1.0 / 240.0)
		var delta: Vector2 = ball.p - tower.p
		if delta.length_squared() > 0.000001 and delta.normalized().dot(inward) >= cos(tower.fan_half):
			assert(delta.length() >= radius - 0.2, "Ball overlaps tower %d" % tower_index)
		if ball.v.dot(inward) > 0.0:
			bounced = true
			break
	assert(bounced, "Expected bounce from tower %d" % tower_index)
	for tick in range(60):
		game.step(1.0 / 240.0)
		var delta: Vector2 = ball.p - tower.p
		if delta.length_squared() > 0.000001 and delta.normalized().dot(inward) >= cos(tower.fan_half):
			assert(delta.length() >= radius - 0.2, "Ball re-entered tower %d" % tower_index)
		assert(ball.v.length() <= 1201.0, "Tower bounce added energy")
	assert(tower.hp == 90, "Tower %d HP is %d after one bounce" % [tower_index, tower.hp])

func _initialize() -> void:
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	_tower_shot(game, Vector2(0, -120), 0.0)
	_tower_shot(game, Vector2(0, -700), 0.0)
	_tower_shot(game, Vector2(0, -1620), 0.0)
	_tower_shot(game, Vector2(600, -1500), 4.0)
	_tower_shot(game, Vector2(0, -1620), 15.0)
	_tower_shot(game, Vector2(0, -20000), 0.0)
	for tower_index in [0, 2, 3, 4, 5]:
		_other_tower_shot(game, tower_index)
	game.reset_game()
	for i in range(game.balls.size()):
		if i > 1: game.balls[i].alive = false
	var first: Dictionary = game.balls[0]
	var second: Dictionary = game.balls[1]
	first.p = Vector2(230, 450)
	second.p = Vector2(265, 450)
	first.v = Vector2(600, 0)
	game.step(1.0 / 240.0)
	assert(second.v.x > first.v.x, "Ball-to-ball impulse changed")
	assert(second.p.distance_to(first.p) >= first.r + second.r - 0.01)
	assert(first.armed and second.armed)
	print("TOWER_SWEEP_AND_BALL_COLLISION_OK")
	game.free()
	quit()
