extends SceneTree

func _check_only_current(game: Node, expected_index: int) -> void:
	for i in range(game.balls.size()):
		assert(game._show_turn_halo(game.balls[i]) == (i == expected_index), "Unexpected halo on ball %d" % i)

func _initialize() -> void:
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	game.reset_game()
	_check_only_current(game, 0)
	game.begin(Vector2(100, 100))
	_check_only_current(game, -1)
	game.release() # A short or cancelled pull restores the waiting state.
	_check_only_current(game, 0)
	game.begin(Vector2(100, 100))
	game.pull = Vector2(30, 0)
	game.release()
	game.balls[4].armed = true
	game.balls[4].v = Vector2(300, 0)
	_check_only_current(game, -1)
	game.next_turn()
	_check_only_current(game, 1)
	game.balls[1].v = Vector2(1, 0)
	_check_only_current(game, -1)
	game.balls[1].v = Vector2.ZERO
	game.finished = true
	_check_only_current(game, -1)
	print("TURN_HALO_STATES_OK")
	game.free()
	quit()
