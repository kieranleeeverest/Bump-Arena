extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/final_skin_2026-11-22"

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.queue_redraw()
	await process_frame
	var normal_image: Image = root.get_texture().get_image()
	var normal_error := normal_image.save_png(OUTPUT_DIR + "/godot_normal.png")
	game.debug_collisions = true
	game.queue_redraw()
	await process_frame
	await process_frame
	var debug_image: Image = root.get_texture().get_image()
	var debug_error := debug_image.save_png(OUTPUT_DIR + "/godot_debug.png")
	print("CAPTURE_FINAL_SKIN normal=%s debug=%s image=%dx%d" % [str(normal_error), str(debug_error), debug_image.get_width(), debug_image.get_height()])
	game.queue_free()
	quit(0 if normal_error == OK and debug_error == OK else 1)
