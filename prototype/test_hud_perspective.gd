extends SceneTree

func _touch(game: Node, point: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.position = point
	event.pressed = pressed
	game._unhandled_input(event)

func _drag(game: Node, point: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.position = point
	game._unhandled_input(event)

func _initialize() -> void:
	call_deferred("_test")

func _test() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	assert(game.local_player_id == 2 and game.get_view_side() == 1)
	game.assign_local_player(0)
	assert(game.get_view_side() == 0)
	game.assign_local_player(2)
	assert(game.get_view_side() == 1)
	var original_towers: Array = game.towers.map(func(t): return [t.p, t.r, t.side])
	var original_boundary: PackedVector2Array = game.boundary_outline.duplicate()
	for side in [1, 0]:
		game.reset_game()
		game.set_preview_side(side)
		assert(game.get_view_side() == side)
		_touch(game, Vector2(270, 500), true)
		_drag(game, Vector2(270, 620))
		assert(game.aiming and absf(game.pull.length() - 120.0) < 0.01)
		_touch(game, Vector2(270, 620), false)
		assert(game.moving)
		var screen_velocity: Vector2 = game.balls[0].v.rotated(game.rotation)
		assert(screen_velocity.distance_to(Vector2(0, -120.0 * game.power)) < 0.01, "Touch aim direction changed with local team view")
		assert(game.turn == 0 and game.towers.map(func(t): return [t.p, t.r, t.side]) == original_towers)
		assert(game.boundary_outline == original_boundary)
	game.handle_developer_key(KEY_F3)
	assert(game.debug_mode)
	game.set_collision_debug(true)
	game.handle_developer_key(KEY_F4)
	assert(game.show_ui_bounds)
	var old_turn: int = game.turn
	var old_ball: Vector2 = game.balls[0].p
	var old_view: int = game.get_view_side()
	game.handle_developer_key(KEY_F5)
	assert(game.get_view_side() == 1 - old_view)
	game.handle_developer_key(KEY_F3)
	assert(not game.debug_collisions and not game.show_ui_bounds)
	assert(game.turn == old_turn and game.balls[0].p == old_ball and game.moving)
	print("HUD_PERSPECTIVE_OK touch=red,blue physics_unchanged=true debug_toggle_keeps_match=true")
	game.queue_free()
	quit()
