extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/formal_hud_2026-11-22"

func _initialize() -> void:
	call_deferred("_capture")

func _save_main(filename: String) -> Error:
	return root.get_texture().get_image().save_png(OUTPUT_DIR + "/" + filename)

func _capture() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	await process_frame
	await process_frame
	game.queue_redraw()
	await process_frame
	var red_error := _save_main("red_local_formal.png")
	game.set_preview_side(0)
	await process_frame
	await process_frame
	var blue_error := _save_main("blue_local_formal.png")
	game.set_debug_mode(true)
	game.set_ui_bounds_debug(true)
	await process_frame
	await process_frame
	var bounds_error := _save_main("blue_local_ui_bounds.png")
	game.set_ui_bounds_debug(false)
	await process_frame
	var panel_error: Error = ERR_UNAVAILABLE
	if game.developer_panel != null:
		panel_error = game.developer_panel.get_texture().get_image().save_png(OUTPUT_DIR + "/developer_panel.png")
	print("FORMAL_HUD_CAPTURE red=%s blue=%s bounds=%s panel=%s" % [str(red_error), str(blue_error), str(bounds_error), str(panel_error)])
	game.queue_free()
	quit(0 if red_error == OK and blue_error == OK and bounds_error == OK and panel_error == OK else 1)
