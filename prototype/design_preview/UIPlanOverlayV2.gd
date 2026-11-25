extends Control

# Design-only overlay. It is never instanced by main.tscn and never edits match state.
const UI_LAYOUT = preload("res://scripts/ui/UILayoutManager.gd")
var preview_state := "normal"
var local_side := 0
var ui_font: Font

const INK := Color("f3edf9")
const MUTED := Color("c4b8d8")
const BLUE := Color("72d9f3")
const RED := Color("ff8aa7")
const GOLD := Color("e9d19b")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_font = SystemFont.new()
	ui_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])

func _box(rect: Rect2, opacity: float = 0.82, border: Color = Color(0.63, 0.54, 0.77, 0.42), radius: int = 14) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.075, 0.055, 0.15, opacity)
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	draw_style_box(style, rect)

func _text(value: String, x: float, y: float, width: float, font_size: int = 13, color: Color = INK) -> void:
	draw_string(ui_font, Vector2(x, y), value, HORIZONTAL_ALIGNMENT_CENTER, width, font_size, color)

func _button(value: String, rect: Rect2, primary: bool = false) -> void:
	_box(rect, 0.92 if primary else 0.62, BLUE if primary else Color(0.7, 0.62, 0.82, 0.42), 12)
	_text(value, rect.position.x, rect.position.y + rect.size.y * 0.64, rect.size.x, 15, INK)

func _chrome() -> void:
	var team_color: Color = BLUE if local_side == 0 else RED
	_round_icon(UI_LAYOUT.BACK_CENTER, "back")
	_box(UI_LAYOUT.STATUS_RECT, 0.62, Color(team_color.r, team_color.g, team_color.b, 0.36), 18)
	_text("第 3 回合", 211, 47, 118, 12, INK)
	_text("12秒 · %s行动" % ("蓝方" if local_side == 0 else "红方"), 211, 63, 118, 10, team_color)
	_round_icon(UI_LAYOUT.MENU_CENTER, "menu")
	_box(UI_LAYOUT.CHAT_RECT, 0.48, Color(0.7, 0.62, 0.82, 0.30), 21)
	_text("o  聊天…", 46, 899, 158, 12, MUTED)
	_round_icon(UI_LAYOUT.MUSIC_CENTER, "music")
	_round_icon(UI_LAYOUT.EMOJI_CENTER, "emoji")

func _round_icon(center: Vector2, kind: String) -> void:
	draw_circle(center, 21, Color(0.08, 0.06, 0.16, 0.70))
	draw_arc(center, 21, 0, TAU, 44, Color(0.7, 0.62, 0.82, 0.48), 1)
	match kind:
		"back":
			draw_line(center + Vector2(6, -7), center + Vector2(-4, 0), INK, 1.8, true)
			draw_line(center + Vector2(-4, 0), center + Vector2(6, 7), INK, 1.8, true)
		"menu":
			for offset in [-5.0, 0.0, 5.0]: draw_line(center + Vector2(-7, offset), center + Vector2(7, offset), INK, 1.5)
		"music":
			_text("音", center.x - 17, center.y + 6, 34, 20, BLUE)
		"emoji":
			_smile(center, 14)

func _smile(center: Vector2, radius: float) -> void:
	draw_circle(center, radius, Color("efcc73"))
	draw_circle(center + Vector2(-4, -3), 1.4, Color("3b2e50"))
	draw_circle(center + Vector2(4, -3), 1.4, Color("3b2e50"))
	draw_arc(center + Vector2(0, 1), 6, 0.2, PI - 0.2, 15, Color("3b2e50"), 1.6)

func _aiming() -> void:
	var base := Vector2(370, 558)
	var tip := Vector2(292, 424)
	draw_line(base, tip, Color(0.99, 0.88, 0.60, 0.32), 7, true)
	draw_line(base, tip, GOLD, 2, true)
	draw_circle(tip, 4, GOLD)
	for i in range(6):
		var x: float = 322.0 + i * 11.0
		var tint: Color = GOLD if i < 4 else Color(0.65, 0.59, 0.74, 0.45)
		draw_rect(Rect2(x, 585, 7, 3), tint, true)

func _special() -> void:
	_box(Rect2(155, 220, 230, 47), 0.80, Color(BLUE.r, BLUE.g, BLUE.b, 0.50), 17)
	draw_circle(Vector2(179, 243), 7, Color("f6a059"))
	_text("下一回合 · 特殊球刷新", 188, 248, 177, 12, INK)

func _black_hole() -> void:
	_box(Rect2(177, 218, 186, 42), 0.79, Color(BLUE.r, BLUE.g, BLUE.b, 0.46), 16)
	_text("黑洞 · 剩余 2 回合", 188, 245, 164, 12, INK)
	var center := Vector2(270, 420)
	draw_circle(center, 32, Color(0.018, 0.014, 0.05, 0.94))
	draw_arc(center, 35, 0.20, TAU + 0.20, 64, Color(0.57, 0.44, 0.78, 0.70), 2)
	draw_arc(center, 40, 0.70, 4.10, 40, Color(0.46, 0.76, 0.94, 0.50), 1)
	_box(Rect2(98, 825, 160, 30), 0.62, Color(BLUE.r, BLUE.g, BLUE.b, 0.28), 13)
	_text("蓝方 1 · 下回合重生", 104, 845, 148, 10, MUTED)

func _modal(title_text: String, subtitle: String, buttons: Array[String]) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.66), true)
	var panel_height: float = 178.0 + buttons.size() * 49.0
	var panel_y: float = (size.y - panel_height) * 0.5
	_box(Rect2(89, panel_y, 362, panel_height), 0.95, Color(0.72, 0.62, 0.85, 0.52), 20)
	_text(title_text, 119, panel_y + 49, 302, 21, INK)
	_text(subtitle, 119, panel_y + 78, 302, 12, MUTED)
	for i in range(buttons.size()):
		_button(buttons[i], Rect2(139, panel_y + 100 + i * 49, 262, 36), i == 0)

func _settings() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.66), true)
	_box(Rect2(89, 282, 362, 396), 0.95, Color(0.72, 0.62, 0.85, 0.52), 20)
	_text("设置", 119, 332, 302, 21, INK)
	for setting in [[390, "背景音乐", "开"], [445, "音效", "开"], [500, "触感反馈", "开"]]:
		var label_y: float = setting[0]
		var label: String = setting[1]
		var value: String = setting[2]
		_text(label, 118, label_y, 166, 14, INK)
		_box(Rect2(360, label_y - 21, 47, 26), 0.59, Color(BLUE.r, BLUE.g, BLUE.b, 0.48), 13)
		_text(value, 360, label_y - 3, 47, 11, BLUE)
	_button("规则说明", Rect2(139, 551, 262, 36))
	_button("返回对局", Rect2(139, 600, 262, 36), true)

func _chat_input(with_keyboard: bool) -> void:
	if with_keyboard:
		# VisualViewport shrinks; the board remains in its original world coordinates.
		draw_rect(Rect2(0, 0, 540, 960), Color(0.018, 0.012, 0.05, 0.37), true)
		_box(Rect2(18, 505, 504, 83), 0.95, Color(BLUE.r, BLUE.g, BLUE.b, 0.52), 17)
		_text("聊天输入 · 对局交互暂时冻结", 30, 526, 480, 11, MUTED)
		_box(Rect2(34, 538, 354, 37), 0.84, Color(0.7, 0.62, 0.82, 0.30), 13)
		_text("这局打得不错｜", 45, 563, 326, 14, INK)
		_button("发送", Rect2(399, 538, 104, 37), true)
		_draw_keyboard()
	else:
		_box(Rect2(18, 732, 504, 191), 0.94, Color(BLUE.r, BLUE.g, BLUE.b, 0.49), 18)
		_text("对局聊天", 36, 759, 136, 14, INK)
		_text("收起  ×", 424, 759, 74, 12, MUTED)
		_box(Rect2(34, 776, 472, 48), 0.62, Color(0.7, 0.62, 0.82, 0.29), 13)
		_text("输入消息…", 48, 805, 442, 13, MUTED)
		_button("表情", Rect2(34, 841, 96, 36))
		_button("图片", Rect2(143, 841, 96, 36))
		_button("发送", Rect2(391, 841, 115, 36), true)
		_text("中文输入、光标和发送将在功能接入时使用系统键盘", 29, 904, 482, 10, MUTED)

func _draw_keyboard() -> void:
	draw_rect(Rect2(0, 594, 540, 366), Color("292536"), true)
	_text("完成", 459, 619, 55, 13, BLUE)
	var rows := ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]
	for row_index in range(rows.size()):
		var keys: String = rows[row_index]
		var key_width: float = 45.0 if row_index == 0 else (47.0 if row_index == 1 else 50.0)
		var total: float = keys.length() * key_width + (keys.length() - 1) * 4.0
		var start_x: float = (540.0 - total) * 0.5
		for i in range(keys.length()):
			var rect := Rect2(start_x + i * (key_width + 4.0), 644 + row_index * 60, key_width, 49)
			_box(rect, 0.86, Color(0.74, 0.72, 0.80, 0.25), 6)
			_text(keys.substr(i, 1), rect.position.x, rect.position.y + 31, key_width, 18, INK)
	_box(Rect2(124, 828, 292, 45), 0.76, Color(0.74, 0.72, 0.80, 0.26), 8)
	_text("空格", 124, 857, 292, 16, INK)
	_text("系统键盘示意 · 游戏画面不移动", 90, 923, 360, 11, MUTED)

func _image_select() -> void:
	_chat_input(false)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.018, 0.012, 0.05, 0.60), true)
	_box(Rect2(82, 290, 376, 357), 0.96, Color(BLUE.r, BLUE.g, BLUE.b, 0.54), 19)
	_text("发送图片？", 110, 334, 320, 20, INK)
	_box(Rect2(146, 355, 248, 166), 0.78, Color(0.65, 0.61, 0.80, 0.40), 12)
	draw_circle(Vector2(260, 420), 24, Color(0.36, 0.31, 0.61, 0.60))
	draw_colored_polygon(PackedVector2Array([Vector2(164, 492), Vector2(226, 438), Vector2(258, 465), Vector2(298, 425), Vector2(378, 492)]), Color(0.36, 0.42, 0.67, 0.65))
	_text("image_01.png · 图片预览", 130, 552, 280, 11, MUTED)
	_button("取消", Rect2(113, 575, 145, 38))
	_button("确认发送", Rect2(282, 575, 145, 38), true)

func _emoji_picker() -> void:
	_box(Rect2(242, 722, 273, 136), 0.96, Color(GOLD.r, GOLD.g, GOLD.b, 0.48), 18)
	_text("最近   心情   鼓励", 256, 747, 245, 12, MUTED)
	for i in range(8):
		var center := Vector2(272 + (i % 4) * 72, 777 + (i / 4) * 42)
		_smile(center, 14)
		if i % 3 == 1:
			draw_arc(center + Vector2(0, 3), 6, PI + 0.25, TAU - 0.25, 12, Color("3b2e50"), 1.6)
	_text("点击即发送 · 点击外部关闭", 256, 847, 245, 10, MUTED)

func _reaction() -> void:
	_box(Rect2(100, 238, 141, 62), 0.83, Color(GOLD.r, GOLD.g, GOLD.b, 0.39), 20)
	_smile(Vector2(128, 269), 15)
	_text("红方 1 · 加油", 150, 274, 78, 11, INK)
	_box(Rect2(317, 736, 151, 31), 0.68, Color(BLUE.r, BLUE.g, BLUE.b, 0.30), 13)
	_text("已发送 · 2 秒后淡出", 323, 757, 139, 10, MUTED)

func _social_home() -> void:
	draw_circle(Vector2(309, 874), 9, BLUE)
	_text("2", 302, 878, 14, 10, Color("18102a"))

func _music_panel() -> void:
	_box(Rect2(138, 708, 368, 204), 0.96, Color(BLUE.r, BLUE.g, BLUE.b, 0.50), 19)
	_text("房间共享音乐", 158, 741, 330, 18, INK)
	_text("正在播放 · 银河漫游（演示曲目）", 157, 767, 330, 12, MUTED)
	_button("2  暂停", Rect2(157, 778, 147, 35), true)
	_button("选择歌曲", Rect2(318, 778, 168, 35))
	_text("房间共享 · 待接入", 158, 839, 304, 11, BLUE)
	_text("个人音量", 158, 878, 90, 12, MUTED)
	draw_line(Vector2(257, 874), Vector2(443, 874), Color(0.58, 0.53, 0.69), 3)
	draw_line(Vector2(257, 874), Vector2(372, 874), BLUE, 3)
	draw_circle(Vector2(372, 874), 5, BLUE)
	_text("静音", 442, 890, 50, 10, MUTED)

func _leave_confirm() -> void:
	_modal("退出对局？", "返回当前等待房间 · 房间尚未接入", ["取消", "返回房间"])

func _music_select() -> void:
	_box(Rect2(108, 613, 398, 302), 0.96, Color(BLUE.r, BLUE.g, BLUE.b, 0.50), 19)
	_text("选择房间音乐", 128, 649, 358, 19, INK)
	_text("仅展示已获授权的曲目（演示）", 130, 677, 354, 11, MUTED)
	for i in range(3):
		var y: float = 692.0 + i * 54.0
		_box(Rect2(129, y, 356, 44), 0.44, Color(BLUE.r, BLUE.g, BLUE.b, 0.17), 11)
		_text(["星海漫游", "远方微光", "无声轨道"][i], 144, y + 27, 208, 13, INK)
		_text("选择" if i > 0 else "播放中", 406, y + 27, 63, 11, BLUE)
	_text("曲源与版权确认后接入 · 返回音乐控制", 123, 884, 370, 10, MUTED)

func _image_failed() -> void:
	_image_select()
	_box(Rect2(99, 658, 342, 53), 0.95, Color(RED.r, RED.g, RED.b, 0.72), 14)
	_text("发送失败 · 图片已保留", 110, 680, 320, 12, INK)
	_text("重试     或     取消", 110, 699, 320, 11, RED)

func _waiting_room() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.055, 0.025, 0.10, 0.95), true)
	for i in range(36):
		var point := Vector2(float((i * 137 + 31) % 540), float((i * 223 + 67) % 960))
		draw_circle(point, 0.7 + float(i % 3) * 0.35, Color(0.65, 0.47, 0.85, 0.31))
	_text("等待房间", 90, 98, 360, 22, INK)
	_text("房间 #A102  ·  4/4  ·  演示页面", 90, 133, 360, 12, MUTED)
	_box(Rect2(74, 185, 392, 388), 0.49, Color(0.68, 0.51, 0.79, 0.24), 24)
	for i in range(4):
		var cx: float = 171.0 if i % 2 == 0 else 369.0
		var cy: float = 281.0 if i < 2 else 465.0
		var tint: Color = BLUE if i < 2 else RED
		draw_circle(Vector2(cx, cy), 29, Color(0.10, 0.07, 0.18, 0.8))
		draw_arc(Vector2(cx, cy), 29, 0, TAU, 44, tint, 1.8)
		_text(str(i + 1), cx - 15, cy + 7, 30, 19, INK)
		_text(["蓝方 1", "蓝方 2", "红方 1", "红方 2"][i], cx - 46, cy + 55, 92, 13, INK)
	_text("等待房主开始对局", 88, 629, 364, 15, MUTED)
	_button("准备（未接入）", Rect2(112, 690, 316, 44))
	_text("返回房间导航与联机状态尚未实现", 86, 818, 368, 11, MUTED)

func _draw() -> void:
	if ui_font == null: return
	_chrome()
	match preview_state:
		"aim": _aiming()
		"special": _special()
		"black_hole": _black_hole()
		"pause": _modal("已暂停", "对局状态保持不变", ["继续对局", "设置", "退出对局"])
		"settings": _settings()
		"result": _modal("胜利", "第 8 回合 · 蓝方获胜（模拟数据）", ["再来一局", "返回主界面"])
		"chat": _chat_input(false)
		"keyboard": _chat_input(true)
		"image": _image_select()
		"emoji": _emoji_picker()
		"reaction": _reaction()
		"social_home": _social_home()
		"music": _music_panel()
		"leave": _leave_confirm()
		"music_select": _music_select()
		"image_failed": _image_failed()
		"waiting_room": _waiting_room()
