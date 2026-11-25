extends SceneTree

func _initialize() -> void:
	call_deferred("run_test")

func check(value: bool, label: String) -> void:
	if not value:
		push_error("FAIL: " + label)
		quit(1)
		assert(false, label)

func run_test() -> void:
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	check(game.turn == game.turn_manager.current_slot() and game.turn_manager.round_number == 1, "initial slot and round")
	var drawn: Array = game.turn_manager.order.duplicate()
	check(drawn.size() == 4, "drawn order has four steps")
	var expected: Array = drawn + drawn
	for index in range(expected.size()):
		var slot: int = expected[index]
		var team: int = 0 if slot < 2 else 1
		check(game.turn == slot, "slot %d" % index)
		check(game.turn_manager.round_number == 1 + index / 4, "round %d" % index)
		check(not game.request_shot(1 - team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "wrong team blocked")
		check(not game.request_shot(team, (slot + 1) % 4, Vector2(30, 0), game.turn_manager.turn_nonce), "wrong slot blocked")
		check(game.request_shot(team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "valid shot")
		check(not game.request_shot(team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "duplicate blocked")
		check(game.moving and game.balls[slot].v.length() > 0, "actual physics ball launched")
		check(game.turn_manager.begin_resolving(), "resolving")
		game.next_turn()
		print("TURN %d: ball %d team %s round %d -> ball %d" % [index + 1, slot + 1, "blue" if team == 0 else "red", 1 + index / 4, game.turn + 1])
	check(game.turn == int(drawn[0]) and game.turn_manager.round_number == 3, "two rounds completed")
	game.reset_game()
	check(game.turn == int(game.turn_manager.order[0]) and game.turn_manager.round_number == 1, "rematch reset")
	for other in range(1, game.balls.size()): game.balls[other].alive = false
	var main_tower: Dictionary = game.towers[4]
	game.balls[0].p = main_tower.p + main_tower.inward * (main_tower.hit_r + game.balls[0].r + 1.0)
	game.balls[0].v = -main_tower.inward * 160.0
	game.balls[0].armed = true
	game.step(0.02)
	check(game.towers[4].hp == 134, "actual tower contact deals doubled damage")
	print("PHYSICS tower contact: red main HP=134")
	game.reset_game()
	for other in range(1, game.balls.size()): game.balls[other].alive = false
	for hit in range(7):
		main_tower = game.towers[4]
		game.balls[0].p = main_tower.p + main_tower.inward * (main_tower.hit_r + game.balls[0].r + 4.0)
		game.balls[0].kind = "iron"
		game.balls[0].armed = true
		# reset_game 之后速度是 0：不给速度球就不动，这一步原来漏了，断言必然失败。
		game.balls[0].v = -main_tower.inward * 620.0
		game.shot_number = hit + 1
		game.step(0.04)
		check(game.towers[4].hp == 140 - (hit + 1) * 20, "physical damage hit %d" % hit)
	check(game.finished and game.turn_manager.phase == game.TURN_MANAGER.Phase.FINISHED, "core victory locks game")
	check(not game.request_shot(0, 0, Vector2(30, 0), game.turn_manager.turn_nonce), "post-finish shot blocked")
	print("PASS local two-player turn order, authority, damage, victory, rematch")
	quit()

