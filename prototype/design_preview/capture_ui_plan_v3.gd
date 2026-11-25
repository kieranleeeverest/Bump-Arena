extends SceneTree

const OUTPUT_DIR := "E:/杂项/怼球复刻/diagnostics/ui_design_v3_2026-11-22"
const AVATAR_ASSETS = preload("res://design_preview/AvatarPreviewAssets.gd")
const BALL_PREVIEW = preload("res://design_preview/BallAvatarPreview.gd")
const OVERLAY = preload("res://design_preview/UIPlanOverlayV3.gd")

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var game: Node2D = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var avatars: Array[Texture2D] = AVATAR_ASSETS.load_circular_textures()
	game.formal_hud.player_portraits = avatars
	game.formal_hud.player_names = PackedStringArray(AVATAR_ASSETS.NAMES)
	var ball_preview: Node2D = BALL_PREVIEW.new()
	ball_preview.game = game
	ball_preview.portraits = avatars
	game.add_child(ball_preview)
	var layer := CanvasLayer.new()
	layer.layer = 20
	root.add_child(layer)
	var overlay: Control = OVERLAY.new()
	overlay.portraits = avatars
	overlay.raw_avatar = ImageTexture.create_from_image(Image.load_from_file(AVATAR_ASSETS.PATHS[0]))
	layer.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await process_frame
	var scenes := [
		["01_profile_first", "profile_first", 0, 0],
		["02_name_empty", "name_empty", 0, 0],
		["03_name_long", "name_long", 0, 0],
		["04_name_invalid", "name_invalid", 0, 0],
		["05_avatar_choose", "avatar_choose", 0, 0],
		["06_avatar_crop", "avatar_crop", 0, 0],
		["07_avatar_error", "avatar_error", 0, 0],
		["08_avatar_on_ball", "ball_avatar", 0, 0],
		["09_four_avatars_blue", "four_blue", 0, 0],
		["10_four_avatars_red", "four_red", 1, 2],
		["11_current_turn", "current_turn", 0, 1],
		["12_tower_damage", "tower_damage", 0, 0],
		["13_vampire_heal", "vampire_heal", 0, 0],
		["14_round_change", "round_change", 0, 0],
		["15_special_spawn", "special_spawn", 0, 0],
		["16_black_hole", "black_hole", 0, 0],
		["17_swallowed_waiting", "swallowed", 0, 0],
		["18_respawn", "respawn", 0, 0],
		["19_chat_preview", "chat_preview", 0, 0],
		["20_emoji_recent", "emoji_recent", 0, 0],
		["21_music_playing", "music_playing", 0, 0],
		["22_music_failure", "music_failure", 0, 0],
		["23_room_ready", "room_ready", 0, 0],
		["24_room_unready", "room_unready", 0, 0],
		["25_room_disconnected", "room_disconnected", 0, 0],
		["26_pause", "pause_v3", 0, 0],
		["27_settings", "settings_v3", 0, 0],
		["28_result", "result_v3", 0, 0],
		["29_match_disconnected", "match_disconnected", 0, 0],
		["30_match_away", "match_away", 0, 0]
	]
	var failed := false
	for scene in scenes:
		game.reset_game()
		game.set_preview_side(scene[2])
		game.turn = scene[3]
		game.timer = 12.0
		if scene[1] == "tower_damage" or scene[1] == "vampire_heal":
			game.towers[3].hp = 90
		if scene[1] == "vampire_heal": game.towers[1].hp = 80
		if scene[1] == "swallowed": game.balls[0].alive = false
		overlay.local_side = scene[2]
		overlay.active_id = scene[3]
		overlay.preview_state = scene[1]
		overlay.queue_redraw()
		game.formal_hud.queue_redraw()
		ball_preview.queue_redraw()
		game.queue_redraw()
		await process_frame
		await process_frame
		var error: Error = root.get_texture().get_image().save_png(OUTPUT_DIR + "/" + scene[0] + ".png")
		print("UI_V3_PREVIEW %s error=%s" % [scene[0], str(error)])
		failed = failed or error != OK
	layer.queue_free()
	game.queue_free()
	quit(1 if failed else 0)
