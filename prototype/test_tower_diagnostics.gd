extends SceneTree

const CASES := [
	["low front", 180.0, 0.0, 0.0],
	["low graze", 180.0, 45.0, 14.0],
	["medium angled", 700.0, 250.0, 7.0],
	["max front", 1620.0, 0.0, 0.0],
	["max angled", 1500.0, 600.0, 6.0],
	["outside fan", 180.0, 80.0, 16.0]
]

func _scenario(game: Node, ball_index: int, tower_index: int, setup: Array) -> void:
	game.reset_game()
	game.debug_collisions = true
	for i in range(game.balls.size()):
		if i != ball_index: game.balls[i].alive = false
	var ball: Dictionary = game.balls[ball_index]
	var tower: Dictionary = game.towers[tower_index]
	var inward: Vector2 = tower.inward
	var tangent := Vector2(-inward.y, inward.x)
	var contact_radius: float = ball.r + tower.hit_r
	ball.p = tower.p + inward * (contact_radius + 22.0) + tangent * setup[3]
	ball.v = -inward * setup[1] + tangent * setup[2]
	# The opaque PNG sphere occupies about 89% of its 2.25*r sprite width.
	var visual_radius: float = ball.r
	var visual_limit: float = tower.r + visual_radius
	var hits := 0
	var skips := 0
	var walls := 0
	var pre_overlap := 0.0
	var post_overlap := 0.0
	var outside_overlap := 0.0
	var outside_position := Vector2.ZERO
	var max_correction := 0.0
	var min_normal_dot := 1.0
	var max_step_ms := 0.0
	var first_visual_tick := -1
	var first_hit_tick := -1
	var first_skip_tick := -1
	var first_wall_tick := -1
	for tick in range(160):
		var before: Vector2 = ball.p - tower.p
		if hits == 0:
			pre_overlap = maxf(pre_overlap, visual_limit - before.length())
		var started := Time.get_ticks_usec()
		game.step(1.0 / 240.0)
		max_step_ms = maxf(max_step_ms, float(Time.get_ticks_usec() - started) / 1000.0)
		for event in game.debug_contacts:
			if event.kind == "tower" and event.shape == tower_index:
				if first_hit_tick < 0: first_hit_tick = tick
				hits += 1
				max_correction = maxf(max_correction, event.correction)
				min_normal_dot = minf(min_normal_dot, event.normal.dot(inward))
			elif event.kind == "outside fan" and event.shape == tower_index:
				if first_skip_tick < 0: first_skip_tick = tick
				skips += 1
			elif event.kind == "wall":
				if first_wall_tick < 0: first_wall_tick = tick
				walls += 1
		game.debug_contacts.clear()
		var after: Vector2 = ball.p - tower.p
		var overlap: float = visual_limit - after.length()
		if overlap > 0.0 and first_visual_tick < 0: first_visual_tick = tick
		post_overlap = maxf(post_overlap, overlap)
		if overlap > outside_overlap and after.normalized().dot(inward) < cos(tower.fan_half):
			outside_overlap = overlap
			outside_position = ball.p
	print("DIAG %s B%d %s T%d: hits=%d skipped=%d walls=%d first_visual=%d first_skip=%d first_wall=%d first_hit=%d pre=%.2f post=%.2f outside=%.2f at=(%.1f,%.1f) fix=%.2f normal_dot=%.3f step_ms=%.3f" % [setup[0], ball_index, ball.kind, tower_index, hits, skips, walls, first_visual_tick, first_skip_tick, first_wall_tick, first_hit_tick, pre_overlap, post_overlap, outside_overlap, outside_position.x, outside_position.y, max_correction, min_normal_dot, max_step_ms])

func _multi_scenario(game: Node, tower_index: int, offset: float) -> void:
	game.reset_game()
	game.debug_collisions = true
	for i in range(game.balls.size()):
		if i != 0 and i != 4: game.balls[i].alive = false
	var tower: Dictionary = game.towers[tower_index]
	var inward: Vector2 = tower.inward
	var tangent := Vector2(-inward.y, inward.x)
	var near_ball: Dictionary = game.balls[0]
	var iron: Dictionary = game.balls[4]
	var contact_radius: float = iron.r + tower.hit_r
	near_ball.p = tower.p + inward * (contact_radius + 18.0) + tangent * offset
	iron.p = tower.p + inward * (contact_radius + 56.0) + tangent * offset
	iron.v = -inward * 1500.0 + tangent * 600.0
	var tower_hits := 0
	var max_outside := 0.0
	var max_correction := 0.0
	for tick in range(120):
		game.step(1.0 / 240.0)
		for event in game.debug_contacts:
			if event.kind == "tower" and event.shape == tower_index:
				tower_hits += 1
				max_correction = maxf(max_correction, event.correction)
		game.debug_contacts.clear()
		for ball in [near_ball, iron]:
			var delta: Vector2 = ball.p - tower.p
			if delta.length_squared() > 0.001 and delta.normalized().dot(inward) < cos(tower.fan_half):
				var visible_radius: float = ball.r
				max_outside = maxf(max_outside, tower.r + visible_radius - delta.length())
	print("MULTI T%d offset=%.0f: hits=%d outside=%.2f max_fix=%.2f" % [tower_index, offset, tower_hits, max_outside, max_correction])

func _initialize() -> void:
	print("CONFIG physics_ticks=%d interpolation=%s substeps=4" % [Engine.physics_ticks_per_second, str(ProjectSettings.get_setting("physics/common/physics_interpolation", false))])
	var game = load("res://scripts/game/PrototypeMatch.gd").new()
	var toggle := InputEventKey.new()
	toggle.keycode = KEY_F3
	toggle.pressed = true
	game.moving = true
	game._unhandled_input(toggle)
	assert(game.debug_collisions, "F3 did not toggle during motion")
	game._unhandled_input(toggle)
	assert(not game.debug_collisions)
	game.moving = false
	for pair in [[2, 0], [2, 2], [0, 3], [0, 5], [4, 0], [4, 2], [4, 3], [4, 5]]:
		for setup in CASES:
			_scenario(game, pair[0], pair[1], setup)
	# Compare the two central towers using the same paths and actual step() logic.
	for pair in [[2, 1], [0, 4], [4, 1], [4, 4]]:
		for setup in CASES:
			_scenario(game, pair[0], pair[1], setup)
	for tower_index in [0, 2, 3, 5]:
		for offset in [0.0, 10.0, 16.0, 20.0]:
			_multi_scenario(game, tower_index, offset)
	game.free()
	quit()
