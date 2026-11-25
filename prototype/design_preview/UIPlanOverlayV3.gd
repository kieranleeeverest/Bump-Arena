extends "res://design_preview/UIPlanOverlayV2.gd"

const AVATAR_ASSETS = preload("res://design_preview/AvatarPreviewAssets.gd")
var portraits: Array[Texture2D] = []
var raw_avatar: Texture2D
var active_id := 0

func _chrome() -> void:
	var team_color: Color = BLUE if local_side == 0 else RED
	_round_icon(UI_LAYOUT.BACK_CENTER, "back")
	_box(Rect2(181, 23, 178, 57), 0.74, Color(team_color.r, team_color.g, team_color.b, 0.44), 17)
	_text("第 3 回合", 189, 44, 162, 13, INK)
	var actor: String = AVATAR_ASSETS.NAMES[active_id]
	_text("%s行动   12 秒" % actor, 189, 68, 162, 15, team_color)
	_round_icon(UI_LAYOUT.MENU_CENTER, "menu")
	_box(UI_LAYOUT.CHAT_RECT, 0.48, Color(0.7, 0.62, 0.82, 0.30), 21)
	_text("o  聊天…", 46, 899, 158, 12, MUTED)
	_round_icon(UI_LAYOUT.MUSIC_CENTER, "music")
	_round_icon(UI_LAYOUT.EMOJI_CENTER, "emoji")

func _portrait(id: int, center: Vector2, radius: float, dim: bool = false) -> void:
	var color: Color = BLUE if id < 2 else RED
	draw_circle(center, radius, Color("120d27"))
	if id < portraits.size() and portraits[id] != null:
		var edge: float = radius * 1.85
		draw_texture_rect(portraits[id], Rect2(center - Vector2.ONE * edge * 0.5, Vector2.ONE * edge), false, Color(1, 1, 1, 0.38 if dim else 1.0))
	draw_arc(center, radius, 0, TAU, 48, color, 1.5)

func _profile_panel(state: String) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.80), true)
	_box(Rect2(63, 164, 414, 613), 0.97, Color(BLUE.r, BLUE.g, BLUE.b, 0.44), 21)
	_text("设置玩家资料", 92, 214, 356, 21, INK)
	_text("身份与昵称独立 · 演示资料", 92, 241, 356, 11, MUTED)
	_portrait(0, Vector2(270, 326), 55)
	_button("选择头像", Rect2(190, 402, 160, 36))
	_text("昵称", 105, 488, 330, 12, MUTED)
	_box(Rect2(103, 503, 334, 44), 0.64, Color(0.72, 0.62, 0.85, 0.36), 12)
	var name: String = "星澜"
	var hint: String = "2–12 个可见字符 · 中文、英文、数字"
	var tint: Color = MUTED
	match state:
		"name_empty":
			name = "输入昵称…"
			hint = "请输入昵称"
			tint = RED
		"name_long":
			name = "银河尽头的超级无敌旅行者…"
			hint = "昵称过长 · 最多 12 个可见字符"
			tint = RED
		"name_invalid":
			name = "<script>星澜</script>"
			hint = "包含不允许字符 · 请修改"
			tint = RED
	_text(name, 114, 531, 312, 15, INK if state == "profile_first" else tint)
	_text(hint, 105, 573, 330, 11, tint)
	_button("保存资料", Rect2(105, 622, 330, 43), state == "profile_first")
	_text("头像和昵称在新一局继续使用 · 同步尚未接入", 92, 721, 356, 11, MUTED)

func _avatar_choose() -> void:
	_profile_panel("profile_first")
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.65), true)
	_box(Rect2(81, 286, 378, 333), 0.98, Color(BLUE.r, BLUE.g, BLUE.b, 0.55), 19)
	_text("选择头像图片", 108, 330, 324, 19, INK)
	_button("从手机相册选择", Rect2(113, 365, 314, 45), true)
	_button("从本地文件选择", Rect2(113, 424, 314, 45))
	_text("支持 PNG / JPEG / WebP（拟定）", 108, 514, 324, 11, MUTED)
	_text("格式、大小与上传失败会在此显示", 108, 541, 324, 11, MUTED)
	_button("取消", Rect2(113, 562, 314, 34))

func _avatar_crop() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.83), true)
	_box(Rect2(47, 145, 446, 655), 0.98, Color(BLUE.r, BLUE.g, BLUE.b, 0.48), 20)
	_text("裁剪圆形头像", 80, 197, 380, 20, INK)
	if raw_avatar != null: draw_texture_rect(raw_avatar, Rect2(115, 247, 310, 310), false)
	for rectangle in [Rect2(115,247,310,48), Rect2(115,509,310,48), Rect2(115,295,48,214), Rect2(377,295,48,214)]:
		draw_rect(rectangle, Color(0.02, 0.01, 0.04, 0.55), true)
	draw_arc(Vector2(270, 402), 107, 0, TAU, 80, Color("f3edf9"), 2.0)
	_text("拖动位置 · 双指缩放", 80, 590, 380, 11, MUTED)
	draw_line(Vector2(152, 628), Vector2(388, 628), Color("8d7ba8"), 2)
	draw_line(Vector2(152, 628), Vector2(289, 628), BLUE, 2)
	draw_circle(Vector2(289, 628), 6, BLUE)
	_button("重新选择", Rect2(78, 681, 180, 41))
	_button("确认裁剪", Rect2(278, 681, 180, 41), true)

func _avatar_error() -> void:
	_profile_panel("profile_first")
	_box(Rect2(93, 574, 354, 75), 0.96, Color(RED.r, RED.g, RED.b, 0.69), 15)
	_text("头像保存失败 · 原头像已保留", 107, 604, 326, 12, INK)
	_text("重新选择图片     重试", 107, 629, 326, 11, RED)

func _feedback(text_value: String, point: Vector2, color: Color, subtitle: String = "") -> void:
	_text(text_value, point.x - 55, point.y, 110, 23, color)
	if not subtitle.is_empty(): _text(subtitle, point.x - 68, point.y + 18, 136, 10, MUTED)

func _round_change() -> void:
	_box(Rect2(170, 227, 200, 54), 0.78, Color(BLUE.r, BLUE.g, BLUE.b, 0.39), 17)
	_text("第 4 回合开始", 180, 257, 180, 17, INK)
	_text("四名玩家完成上一轮行动", 175, 278, 190, 10, MUTED)

func _swallowed() -> void:
	_box(Rect2(102, 757, 150, 43), 0.77, Color(BLUE.r, BLUE.g, BLUE.b, 0.44), 13)
	_text("星澜 · 等待重生", 108, 783, 138, 11, BLUE)
	_feedback("已被吞噬", Vector2(175, 589), MUTED)

func _respawn() -> void:
	var point := Vector2(370, 588)
	for angle in [0.2, 1.6, 3.0, 4.4, 5.6]:
		var direction: Vector2 = Vector2.from_angle(angle)
		draw_line(point + direction * 25, point + direction * 34, BLUE, 2.0, true)
	_feedback("重新登场", Vector2(370, 548), BLUE)

func _chat_preview() -> void:
	_box(Rect2(59, 815, 250, 39), 0.76, Color(BLUE.r, BLUE.g, BLUE.b, 0.32), 14)
	_text("北辰：这一球角度不错…", 70, 840, 228, 11, INK)

func _player_status(kind: String) -> void:
	var center := Vector2(395, 113) if kind == "disconnected" else Vector2(145, 113)
	draw_circle(center, 18, Color(0.02, 0.01, 0.05, 0.53))
	var label: String = "赤霄 · 连接中断" if kind == "disconnected" else "绯月 · 暂时离开"
	var tint: Color = RED if kind == "disconnected" else MUTED
	_box(Rect2(center.x - 72, 164, 144, 30), 0.80, Color(tint.r, tint.g, tint.b, 0.45), 12)
	_text(label, center.x - 66, 184, 132, 10, tint)

func _music_status() -> void:
	_music_panel()
	_box(Rect2(152, 667, 233, 27), 0.70, Color(BLUE.r, BLUE.g, BLUE.b, 0.31), 12)
	_text("房间音乐已切换 · 2 秒后淡出", 158, 685, 221, 10, BLUE)

func _music_failure() -> void:
	_music_panel()
	_box(Rect2(154, 652, 281, 32), 0.92, Color(RED.r, RED.g, RED.b, 0.51), 12)
	_text("播放失败 · 点按重试或保持静音", 160, 674, 269, 11, RED)

func _room(state: String) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.055, 0.025, 0.10, 0.96), true)
	_text("等待房间", 84, 95, 372, 23, INK)
	_text("房间 #A102 · 邀请码演示", 84, 127, 372, 12, MUTED)
	_box(Rect2(51, 173, 438, 497), 0.51, Color(0.68, 0.51, 0.79, 0.28), 24)
	for id in range(4):
		var center := Vector2(155 if id % 2 == 0 else 385, 268 if id < 2 else 506)
		var missing: bool = state == "room_unready" and id == 3
		var offline: bool = state == "room_disconnected" and id == 2
		if not missing: _portrait(id, center, 31, offline)
		else:
			draw_circle(center, 31, Color(0.13, 0.10, 0.24, 0.62))
			draw_arc(center, 31, 0, TAU, 36, MUTED, 1.0)
		var name: String = "等待加入" if missing else AVATAR_ASSETS.NAMES[id]
		_text(name, center.x - 55, center.y + 61, 110, 14, INK if not missing else MUTED)
		var status: String = "房主 · 已准备" if id == 0 else ("等待玩家" if missing else ("重新连接…" if offline else ("未准备" if state == "room_unready" and id == 2 else "已准备")))
		_text(status, center.x - 62, center.y + 82, 124, 11, RED if offline else MUTED)
	_text("3/4 已到齐" if state == "room_unready" else ("连接异常 · 等待重连" if state == "room_disconnected" else "4/4 已准备"), 92, 712, 356, 15, INK)
	_button("开始对局（演示）", Rect2(102, 746, 336, 45), state == "room_ready")
	_button("退出房间", Rect2(102, 813, 336, 37))

func _pause_v3() -> void:
	_modal("已打开对局菜单", "本地菜单不暂停其他玩家的回合", ["继续对局", "设置", "返回房间"])

func _settings_v3() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.72), true)
	_box(Rect2(73, 238, 394, 483), 0.96, Color(0.72, 0.62, 0.85, 0.52), 19)
	_text("设置", 101, 285, 338, 21, INK)
	for i in range(5):
		var row: float = 331.0 + i * 55.0
		var title: String = ["背景音乐", "游戏音效", "共享音乐音量", "触觉反馈", "降低动态效果"][i]
		_text(title, 101, row, 205, 13, INK)
		_box(Rect2(367, row - 22, 58, 26), 0.59, Color(BLUE.r, BLUE.g, BLUE.b, 0.45), 13)
		_text("开" if i != 4 else "关", 367, row - 3, 58, 11, BLUE if i != 4 else MUTED)
	_button("规则说明", Rect2(119, 625, 302, 36))
	_button("返回对局", Rect2(119, 674, 302, 36), true)

func _result_v3() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.74), true)
	_box(Rect2(62, 213, 416, 540), 0.96, Color(BLUE.r, BLUE.g, BLUE.b, 0.50), 21)
	_text("蓝方获胜", 86, 264, 368, 22, BLUE)
	_text("胜利原因：对方主塔被击破（演示）", 82, 297, 376, 11, MUTED)
	for id in range(4):
		var center := Vector2(160 if id % 2 == 0 else 380, 374 if id < 2 else 528)
		_portrait(id, center, 28)
		_text(AVATAR_ASSETS.NAMES[id], center.x - 60, center.y + 49, 120, 13, INK)
		_text("蓝方" if id < 2 else "红方", center.x - 60, center.y + 67, 120, 10, BLUE if id < 2 else RED)
	_button("再来一局 · 等待全员准备", Rect2(100, 620, 340, 39), true)
	_button("返回等待房间", Rect2(100, 675, 340, 39))

func _draw() -> void:
	if ui_font == null: return
	if preview_state.begins_with("room_"):
		_room(preview_state)
		return
	_chrome()
	match preview_state:
		"profile_first", "name_empty", "name_long", "name_invalid": _profile_panel(preview_state)
		"avatar_choose": _avatar_choose()
		"avatar_crop": _avatar_crop()
		"avatar_error": _avatar_error()
		"ball_avatar":
			_box(Rect2(35, 816, 210, 34), 0.70, Color(BLUE.r, BLUE.g, BLUE.b, 0.34), 12)
			_text("同一头像 · 球体与 HUD", 43, 838, 194, 11, BLUE)
		"four_blue", "four_red": pass
		"current_turn":
			_box(Rect2(315, 604, 114, 31), 0.76, Color(BLUE.r, BLUE.g, BLUE.b, 0.42), 12)
			_text("轮到你 · 北辰", 323, 625, 98, 11, BLUE)
		"tower_damage": _feedback("-10", Vector2(466, 191), RED, "塔受到伤害")
		"vampire_heal":
			_feedback("-10", Vector2(461, 193), RED, "敌方副塔")
			_feedback("+10", Vector2(270, 759), Color("87d6aa"), "己方主塔")
		"round_change": _round_change()
		"special_spawn":
			_box(Rect2(162, 222, 216, 43), 0.78, Color(GOLD.r, GOLD.g, GOLD.b, 0.42), 15)
			_text("火球已刷新 · 短暂提示", 171, 248, 198, 12, INK)
		"black_hole": _black_hole()
		"swallowed": _swallowed()
		"respawn": _respawn()
		"chat_preview": _chat_preview()
		"match_disconnected": _player_status("disconnected")
		"match_away": _player_status("away")
		"emoji_recent": _emoji_picker()
		"music_playing": _music_status()
		"music_failure": _music_failure()
		"pause_v3": _pause_v3()
		"settings_v3": _settings_v3()
		"result_v3": _result_v3()
