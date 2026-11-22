extends SceneTree

func _initialize() -> void:
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	game.reset_game()
	for i in range(game.balls.size()):
		if i != 0 and i != 4: game.balls[i].alive = false
	var cue: Dictionary = game.balls[0]
	var iron: Dictionary = game.balls[4]
	cue.p = Vector2(93.5, 400)
	cue.v = Vector2(-100, 0)
	game.step(0.01)
	assert(not cue.armed, "Wall alone must not arm a player ball")
	cue.p = Vector2(270, 210)
	cue.v = Vector2(0, -100)
	game.step(0.01)
	assert(game.towers[1].hp == 100, "Unarmed tower hit must not damage")
	cue.p = Vector2(200, 400)
	cue.v = Vector2(100, 0)
	iron.p = Vector2(235, 400)
	iron.v = Vector2.ZERO
	game.step(0.01)
	assert(cue.armed and iron.armed, "Ball contact must arm both")
	cue.p = Vector2(93.5, 400)
	cue.v = Vector2(-100, 0)
	game.step(0.01)
	assert(cue.armed, "Wall must preserve prior eligibility")
	cue.p = Vector2(270, 210)
	cue.v = Vector2(0, -100)
	game.step(0.01)
	assert(game.towers[1].hp == 90, "Armed tower hit must damage")
	game.next_turn()
	assert(not cue.armed, "Turn end must clear eligibility")
	print("DAMAGE_RULES_OK")
	game.free()
	quit()
