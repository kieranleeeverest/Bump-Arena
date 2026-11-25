extends SceneTree

const OUT := "E:/杂项/怼球复刻/diagnostics/app_shell_v1_2026-11-22"
const PREVIEW = preload("res://design_preview/AppShellPreviewV1.gd")
const AVATARS = preload("res://design_preview/AvatarPreviewAssets.gd")

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var overlay: Control = PREVIEW.new()
	overlay.portraits = AVATARS.load_circular_textures()
	root.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	var pages := [
		["01_first_profile", "first_profile"], ["02_lobby_rooms", "lobby"],
		["03_friends", "friends"], ["04_private_chat", "chat"],
		["05_profile_xp", "profile"], ["06_level_up", "level_up"],
		["07_badges_titles", "badges"], ["08_waiting_room", "waiting_room"],
		["09_result_to_room", "result_flow"],
		["10_invite_after_profile", "first_profile_invite"],
		["11_room_full", "join_error"]
	]
	var failed := false
	for item in pages:
		overlay.page = item[1]
		overlay.queue_redraw()
		await process_frame
		await process_frame
		var err: Error = root.get_texture().get_image().save_png(OUT + "/" + item[0] + ".png")
		print("APP_PREVIEW %s error=%s" % [item[0], str(err)])
		failed = failed or err != OK
	quit(1 if failed else 0)
