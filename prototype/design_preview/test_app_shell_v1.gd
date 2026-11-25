extends SceneTree

const APP = preload("res://app_shell.tscn")
const PROFILE := "res://design_preview/_ui_v1_test_profile.cfg"
const GUEST_PROFILE := "res://design_preview/_ui_guest_test_profile.cfg"
const SESSION := "user://supabase_session.json"
var session_backup := ""

func _initialize() -> void:
	call_deferred("_run")

func _require(condition: bool, label: String) -> void:
	if not condition:
		push_error("UI_V1_FAIL " + label)
		quit(1)

func _press(app: Control, label: String) -> void:
	for child in app.hotspot_layer.get_children():
		if child is Button and child.accessibility_name == label:
			child.pressed.emit()
			return
	_require(false, "missing clickable control: " + label)

func _press_dialog(app: Control, label: String) -> void:
	var panel: PanelContainer = app.dialog_layer.get_child(1)
	for child in panel.get_child(0).get_children():
		if child is Button and child.text == label:
			child.pressed.emit()
			return
	_require(false, "missing dialog button: " + label)

func _write_fake_session() -> void:
	var data := {
		"access_token": "test_token",
		"refresh_token": "test_refresh",
		"expires_at": Time.get_unix_time_from_system() + 3600.0,
		"user_id": "11111111-1111-1111-1111-111111111111"
	}
	var f := FileAccess.open(SESSION, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _remove_session() -> void:
	if FileAccess.file_exists(SESSION):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION))

# The guest-guard case needs the session file gone, but the real login of whoever
# runs this test must survive: keep the original bytes and put them back at the end.
func _backup_session() -> void:
	if not FileAccess.file_exists(SESSION):
		return
	var f := FileAccess.open(SESSION, FileAccess.READ)
	if f == null:
		return
	session_backup = f.get_as_text()
	f.close()

func _restore_session() -> void:
	if session_backup.is_empty():
		return
	var f := FileAccess.open(SESSION, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(session_backup)
	f.close()

func _run() -> void:
	if FileAccess.file_exists(PROFILE): DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE))
	_backup_session()
	# Guard check first: with no session, a protected page must divert to auth.
	_remove_session()
	var guest: Control = APP.instantiate()
	guest.profile_file = GUEST_PROFILE
	root.add_child(guest)
	await process_frame
	guest._route("friends")
	await process_frame
	_require(guest.page == "auth", "guard diverts friends to auth without session")
	_require(guest.pending_route == "friends", "guard remembers pending_route=friends")
	guest.queue_free()
	await process_frame
	if FileAccess.file_exists(GUEST_PROFILE): DirAccess.remove_absolute(ProjectSettings.globalize_path(GUEST_PROFILE))
	# Inject a fake valid session so the guarded main flow can proceed.
	_write_fake_session()
	var app: Control = APP.instantiate()
	app.profile_file = PROFILE
	app.pending_invite = "A102"
	root.add_child(app)
	await process_frame
	_require(app.page == "first_profile_invite", "invite entry")
	app.profile_name_input.text = "测试星澜"
	app.profile_signature_input.text = "测试签名"
	_press(app, "保存资料")
	_require(FileAccess.file_exists(PROFILE), "profile saved")
	_require(app.page == "waiting_room", "invite resumed to room")
	_press(app, "准备或开始")
	_require(app.local_ready and app.page == "waiting_room", "ready toggle")
	_press(app, "切换对手准备状态（本地热座）")
	_require(app.opponent_ready, "second human ready")
	_press(app, "准备或开始")
	await process_frame
	_require(app.page == "match" and app.match_scene != null, "existing match entered")
	_require(app.match_scene.formal_hud.player_names[0] == "测试星澜", "profile reused in HUD")
	_require(app.match_scene.balls[0].r == 19.5, "ball physics radius preserved")
	app.set_local_team(1)
	_require(app.match_scene.formal_hud.player_names[2] == "测试星澜", "red-side local identity remains below")
	_require(app.match_scene.get_view_side() == 1, "red view follows local team")
	for tower in app.match_scene.towers:
		if tower.main and tower.side == 0: tower.hp = 0
	app.match_scene.finished = true
	await process_frame
	_require(app.page == "result_flow", "real finish route")
	_require(app.preview.result_winner == "红方获胜", "winner derived from destroyed core")
	_require(app.preview.result_names[2] == "测试星澜", "result portrait slot follows red-side identity")
	app._back_to_room()
	_require(app.page == "waiting_room" and not app.local_ready, "result returns to room")
	_press(app, "离开房间")
	_press(app, "输入房间号")
	var dialog_body: VBoxContainer = app.dialog_layer.get_child(1).get_child(0)
	var room_field: LineEdit = dialog_body.get_child(2)
	room_field.text = "FULL"
	_press_dialog(app, "加入房间")
	_require(app.page == "join_error", "room full state")
	_press(app, "返回房间列表")
	_press(app, "输入房间号")
	dialog_body = app.dialog_layer.get_child(1).get_child(0)
	room_field = dialog_body.get_child(2)
	room_field.text = "A102"
	_press_dialog(app, "加入房间")
	_require(app.page == "waiting_room", "join by room code")
	_press(app, "离开房间")
	_press(app, "好友与聊天")
	_press(app, "搜索玩家")
	_press(app, "个人资料")
	# Appearance collection / badges were removed from the profile page.
	_require(app.page == "profile", "profile tab shows profile without badge entry")
	_press(app, "账号登录")
	_require(app.page == "auth", "account entry opens auth page")
	app.queue_free()
	await process_frame
	var again: Control = APP.instantiate()
	again.profile_file = PROFILE
	root.add_child(again)
	await process_frame
	_require(again.page == "lobby", "returning user opens lobby")
	again.queue_free()
	await process_frame
	var invited: Control = APP.instantiate()
	invited.profile_file = PROFILE
	invited.pending_invite = "A102"
	root.add_child(invited)
	await process_frame
	_require(invited.page == "waiting_room", "returning user follows invite")
	invited.queue_free()
	await process_frame
	# Logged-in guard check: with a valid session, a protected page passes through.
	var logged: Control = APP.instantiate()
	logged.profile_file = PROFILE
	root.add_child(logged)
	await process_frame
	logged._route("friends")
	await process_frame
	_require(logged.page == "friends", "guard allows friends with valid session")
	logged.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE))
	_restore_session()
	print("UI_V1_TEST_PASS profile invite room ready match result tabs persistence guard")
	quit(0)
