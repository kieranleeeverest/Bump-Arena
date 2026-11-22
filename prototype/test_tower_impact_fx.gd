extends SceneTree

func _hit_tower(game: Node, armed: bool) -> void:
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 4: game.balls[i].alive = false
	var ball: Dictionary = game.balls[4]
	var tower: Dictionary = game.towers[1]
	ball.armed = armed
	ball.p = tower.p + tower.inward * (ball.r + tower.hit_r + 2.0)
	ball.v = -tower.inward * 250.0
	game.step(0.01)
	assert(game.tower_impacts.size() == 1, "One tower contact should create one effect")
	assert(game.tower_impacts[0].p.distance_to(game.towers[1].p + game.towers[1].inward * game.towers[1].hit_r) < 1.0)
	assert(game.towers[1].hp == (90 if armed else 100), "Tower damage rule changed")

func _initialize() -> void:
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	_hit_tower(game, false)
	var impact_point: Vector2 = game.towers[1].p + game.towers[1].inward * game.towers[1].hit_r
	game._add_tower_impact(4, 1, impact_point, Vector2.DOWN, 1400, 0)
	assert(game.tower_impacts.size() == 1, "Sustained contact duplicated its effect")
	game._update_tower_impacts(0.25)
	assert(game.tower_impacts.is_empty(), "Impact effect did not expire")
	game._add_tower_impact(4, 1, impact_point, Vector2.DOWN, 100, 0)
	var light_strength: float = game.tower_impacts[0].strength
	var light_duration: float = game.tower_impacts[0].duration
	game.tower_impacts.clear()
	game._add_tower_impact(4, 1, impact_point, Vector2.DOWN, 1400, 0)
	assert(game.tower_impacts[0].strength > light_strength)
	assert(game.tower_impacts[0].duration > light_duration)
	_hit_tower(game, true)
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 5: game.balls[i].alive = false
	var fire_ball: Dictionary = game.balls[5]
	fire_ball.armed = true
	fire_ball.p = game.towers[1].p + game.towers[1].inward * (fire_ball.r + game.towers[1].hit_r + 2.0)
	fire_ball.v = -game.towers[1].inward * 250.0
	game.step(0.01)
	assert(not fire_ball.alive and game.tower_impacts.size() == 1)
	assert(game.towers[1].hp == 80, "Fireball damage changed")
	game.reset_game()
	assert(game.tower_impacts.is_empty(), "Restart retained an impact effect")
	for i in range(game.balls.size()):
		if i > 1: game.balls[i].alive = false
	game.balls[0].p = Vector2(230, 450)
	game.balls[1].p = Vector2(265, 450)
	game.balls[0].v = Vector2(600, 0)
	game.step(1.0 / 240.0)
	assert(game.tower_impacts.is_empty(), "Ball-to-ball contact created a tower effect")
	print("TOWER_IMPACT_FX_OK")
	game.free()
	quit()
