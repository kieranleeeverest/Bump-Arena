extends SceneTree

const EPS := 0.02

func _initialize() -> void:
	call_deferred("_verify")

func _verify() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var saved_ball_positions: Array[Vector2] = []
	for ball in game.balls: saved_ball_positions.append(ball.p)
	var sides: Array = []
	for side in [0, 1]:
		game.set_preview_side(side)
		var top_id: int = 4 if side == 0 else 1
		var bottom_id: int = 1 if side == 0 else 4
		var top_pos: Vector2 = game.to_global(game.towers[top_id].p)
		var bottom_pos: Vector2 = game.to_global(game.towers[bottom_id].p)
		var screen_point := Vector2(310, 440)
		var roundtrip: Vector2 = game.to_global(game.to_local(screen_point))
		assert(roundtrip.distance_to(screen_point) < EPS)
		assert(absf(game.transform.get_scale().x - 1.0) < EPS)
		assert(absf(game.transform.get_scale().y - 1.0) < EPS)
		sides.append([top_pos, bottom_pos])
		print("VIEW_CHECK side=%d top=%s bottom=%s board_center=%s" % [side, top_pos, bottom_pos, (top_pos + bottom_pos) * 0.5])
	assert(sides[0][0].distance_to(sides[1][0]) < EPS)
	assert(sides[0][1].distance_to(sides[1][1]) < EPS)
	for i in range(game.balls.size()): assert(game.balls[i].p == saved_ball_positions[i])
	print("VIEW_CHECK PASS: red/blue tower anchors, uniform scale, inverse pointer map, world ball positions")
	game.queue_free()
	quit(0)
