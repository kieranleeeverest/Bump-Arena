extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/top_slope_damage_2026-11-22"

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.queue_redraw()
	await process_frame
	var normal_error: Error = root.get_texture().get_image().save_png(OUTPUT_DIR + "/godot_normal.png")
	game.debug_collisions = true
	game.queue_redraw()
	await process_frame
	await process_frame
	var debug_error: Error = root.get_texture().get_image().save_png(OUTPUT_DIR + "/godot_debug.png")
	var tower: Dictionary = game.towers[0]
	var ball: Dictionary = game.balls[0]
	var radial: Vector2 = Vector2.from_angle(deg_to_rad(38.0))
	ball.p = tower.p + radial * (tower.r + ball.r + 5.0)
	ball.v = -radial * 180.0
	ball.armed = true
	for tick in range(30):
		game.step(1.0 / 240.0)
		if game.debug_contacts.any(func(c): return c.kind == "tower" or c.kind == "wall"): break
	game.queue_redraw()
	await process_frame
	var contact_error: Error = root.get_texture().get_image().save_png(OUTPUT_DIR + "/godot_contact.png")
	print("TOP_SLOPE_CAPTURE normal=%s debug=%s contact=%s" % [str(normal_error), str(debug_error), str(contact_error)])
	game.queue_free()
	quit(0 if normal_error == OK and debug_error == OK and contact_error == OK else 1)
