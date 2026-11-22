extends Control

# Design-only overlay. It is never instanced by main.tscn and never edits match state.
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
	_box(Rect2(214, 28, 112, 54), 0.62, Color(team_color.r, team_color.g, team_color.b, 0.36), 18)
	_text("第 3 回合", 220, 50, 100, 13, INK)
	_text("12秒 · %s行动" % ("蓝方" if local_side == 0 else "红方"), 220, 70, 100, 10, team_color)
	# Quiet controls use the reserved lower band; none overlap the arena.
	_box(Rect2(94, 875, 352, 43), 0.47, Color(0.7, 0.62, 0.82, 0.22), 20)
	_text("对局聊天", 114, 902, 312, 12, MUTED)
	for item in [[48.0, "音"], [492.0, ""]]:
		var x: float = item[0]
		var glyph: String = item[1]
		draw_circle(Vector2(x, 897), 21, Color(0.08, 0.06, 0.16, 0.63))
		draw_arc(Vector2(x, 897), 21, 0, TAU, 44, Color(0.7, 0.62, 0.82, 0.42), 1)
		if glyph.is_empty():
			for offset in [-5.0, 0.0, 5.0]: draw_line(Vector2(x - 7, 897 + offset), Vector2(x + 7, 897 + offset), INK, 1.5)
		else:
			_text(glyph, x - 17, 902, 34, 13, INK)

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
