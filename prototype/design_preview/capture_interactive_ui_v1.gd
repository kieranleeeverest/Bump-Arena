extends SceneTree

const APP = preload("res://app_shell.tscn")
const OUT := "E:/杂项/怼球复刻/diagnostics/ui_v1_freeze_2026-11-22"

func _initialize() -> void:
	call_deferred("_capture")

func _shot(app: Control, filename: String) -> void:
	await process_frame
	await process_frame
	var error := root.get_texture().get_image().save_png(OUT + "/" + filename + ".png")
	print("UI_V1_SHOT %s error=%d" % [filename, error])

func _capture() -> void:
	var app: Control = APP.instantiate()
	app.profile_file = "res://design_preview/_capture_missing_profile.cfg"
	root.add_child(app)
	app.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await _shot(app, "01_profile_entry")
	app._route("lobby")
	await _shot(app, "02_lobby_clickable")
	app._route("friends")
	await _shot(app, "03_friends_clickable")
	app._friend_requests()
	await _shot(app, "03a_friend_requests")
	app._route("profile")
	await _shot(app, "04_profile_clickable")
	app._route("edit_profile")
	await _shot(app, "04a_profile_edit")
	app._route("badges")
	await _shot(app, "04b_badges")
	app._create_room()
	await _shot(app, "05_room_unready")
	app._ready_or_start()
	await _shot(app, "06_room_ready")
	app._ready_or_start()
	app.set_local_team(0)
	await _shot(app, "07_match_blue_bottom")
	app.set_local_team(1)
	await _shot(app, "07a_match_red_bottom")
	app._match_menu()
	await _shot(app, "08_match_menu")
	app._match_settings()
	await _shot(app, "08a_settings")
	app._match_chat()
	await _shot(app, "08b_match_chat")
	app._match_emoji()
	await _shot(app, "08c_emoji")
	app._match_music()
	await _shot(app, "08d_music")
	app._notice("连接中断 · 等待重连（模拟）")
	await _shot(app, "08e_disconnected")
	app._route("result_flow")
	await _shot(app, "09_result_return")
	quit(0)
