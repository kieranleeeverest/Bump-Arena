extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/ui_design_v1_2026-11-22"
const OVERLAY = preload("res://design_preview/UIPlanOverlay.gd")

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var layer := CanvasLayer.new()
	layer.layer = 20
	root.add_child(layer)
	var overlay: Control = OVERLAY.new()
	layer.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	game.set_preview_side(1)
	var shared_top_tower_y: float = game.to_global(game.towers[1].p).y
	await process_frame
	await process_frame
	var scenes := [
		["01_normal_blue", "normal", 0, 0],
		["02_normal_red", "normal", 1, 2],
		["03_aiming", "aim", 0, 0],
		["04_special_spawn", "special", 0, 0],
		["05_black_hole", "black_hole", 0, 0],
		["06_pause", "pause", 0, 0],
		["07_settings", "settings", 0, 0],
		["08_result", "result", 0, 0]
	]
	var failed := false
	for scene in scenes:
		game.set_preview_side(scene[2])
		if scene[2] == 0:
			# Mockup-only alignment; current gameplay's 180-degree view has a 30 px vertical offset.
			game.position.y += shared_top_tower_y - game.to_global(game.towers[4].p).y
		game.turn = scene[3]
		game.timer = 12.0
		overlay.local_side = scene[2]
		overlay.preview_state = scene[1]
		overlay.queue_redraw()
		game.formal_hud.queue_redraw()
		await process_frame
		await process_frame
		var error: Error = root.get_texture().get_image().save_png(OUTPUT_DIR + "/" + scene[0] + ".png")
		print("UI_STATIC_PREVIEW %s error=%s" % [scene[0], str(error)])
		failed = failed or error != OK
	layer.queue_free()
	game.queue_free()
	quit(1 if failed else 0)
