extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/ui_design_v2_2026-11-22"
const OVERLAY = preload("res://design_preview/UIPlanOverlayV2.gd")

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
		["08_result", "result", 0, 0],
		["09_social_home", "social_home", 0, 0],
		["10_chat_open", "chat", 0, 0],
		["11_keyboard_open", "keyboard", 0, 0],
		["12_image_select", "image", 0, 0],
		["13_emoji_picker", "emoji", 0, 0],
		["14_reaction_sent", "reaction", 0, 0],
		["15_shared_music", "music", 0, 0],
		["16_leave_confirm", "leave", 0, 0],
		["17_music_select", "music_select", 0, 0],
		["18_image_failed", "image_failed", 0, 0],
		["19_waiting_room", "waiting_room", 0, 0]
	]
	var failed := false
	for scene in scenes:
		game.set_preview_side(scene[2])
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
