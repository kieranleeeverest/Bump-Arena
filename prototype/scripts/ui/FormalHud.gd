extends Control

const UI_LAYOUT = preload("res://scripts/ui/UILayoutManager.gd")

# Optional circular portrait art can replace the numbered placeholders later.
@export var player_portraits: Array[Texture2D] = []
@export var player_names := PackedStringArray(["蓝方 1", "蓝方 2", "红方 1", "红方 2"])
@export_range(20.0, 48.0, 1.0) var safe_top := 28.0
@export_range(20.0, 48.0, 1.0) var safe_bottom := 28.0
@export_range(60.0, 160.0, 1.0) var reserved_chat_space := 123.0

var game: Node2D
var show_layout_bounds := false
var hud_font: Font
var player_rows: Array[HBoxContainer] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_font = SystemFont.new()
	hud_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	var layout: Dictionary = UI_LAYOUT.safe_adjusted_layout(1.0, safe_top, safe_bottom)
	for bottom in [false, true]:
		var row := HBoxContainer.new()
		row.anchor_left = 0.5
		row.anchor_right = 0.5
		row.offset_left = -195.0
		row.offset_right = 195.0
		row.anchor_top = 0.0
		row.anchor_bottom = 0.0
		var row_top: float = layout.ally_row_y if bottom else layout.enemy_row_y
		row.offset_top = row_top
		row.offset_bottom = row_top + 80.0
		row.add_theme_constant_override("separation", 110)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for slot_width in [140.0, 140.0]:
			var slot := Control.new()
			slot.custom_minimum_size = Vector2(slot_width, 80.0)
			slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(slot)
		add_child(row)
		player_rows.append(row)
	resized.connect(queue_redraw)

func _process(_dt: float) -> void:
	queue_redraw()

func _team_color(side: int) -> Color:
	return Color("67d8f5") if side == 0 else Color("ff809c")

func _text_center(text: String, center_x: float, baseline: float, width: float, size_px: int, color: Color) -> void:
	draw_string(hud_font, Vector2(center_x - width * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, width, size_px, color)

func _draw_player(player_id: int, center_x: float, row_y: float, side: int) -> void:
	var color: Color = _team_color(side)
	var active: bool = game.turn == player_id and not game.moving and not game.finished
	var portrait_center := Vector2(center_x, row_y + 22.0)
	draw_circle(portrait_center, 18.0, Color(0.09, 0.07, 0.19, 0.66))
	if player_id < player_portraits.size() and player_portraits[player_id] != null:
		draw_texture_rect(player_portraits[player_id], Rect2(portrait_center - Vector2(16, 16), Vector2(32, 32)), false)
	else:
		_text_center(str(player_id + 1), center_x, row_y + 28.0, 32.0, 16, Color("f6f2fa"))
	draw_arc(portrait_center, 18.0, 0.0, TAU, 48, color.lightened(0.25) if active else color, 2.0 if active else 1.2)
	var nickname: String = player_names[player_id] if player_id < player_names.size() else "玩家 %d" % (player_id + 1)
	_text_center(nickname, center_x, row_y + 58.0, 112.0, 13, Color.WHITE if active else Color("d6cde7"))
	# A fine visual slot only: there is no player HP model to bind yet.
	draw_rect(Rect2(center_x - 35.0, row_y + 66.0, 70.0, 2.0), Color(0.40, 0.36, 0.53, 0.45), true)
	var line_color: Color = color
	line_color.a = 0.58 if active else 0.34
	draw_rect(Rect2(center_x - 35.0, row_y + 66.0, 70.0, 1.0), line_color, true)

func _draw_tower_bars() -> void:
	for t in game.towers:
		var screen: Vector2 = game.to_global(t.p)
		var upper: bool = screen.y < size.y * 0.5
		var width: float = 52.0 if t.main else 34.0
		var y: float = screen.y - t.r - (26.0 if t.main else 13.0) if upper else screen.y + t.r + (34.0 if t.main else 10.0)
		var rect := Rect2(screen.x - width * 0.5, y, width, 3.0)
		draw_rect(rect, Color(0.22, 0.19, 0.34, 0.68), true)
		var fill: Color = _team_color(t.side)
		fill.a = 0.88
		draw_rect(Rect2(rect.position, Vector2(width * clampf(float(t.hp) / 100.0, 0.0, 1.0), 2.0)), fill, true)
		if show_layout_bounds: draw_rect(rect.grow(2.0), Color("ffe183"), false, 1.0)

func _draw() -> void:
	if game == null or game.towers.is_empty() or hud_font == null or player_rows.size() != 2: return
	var upper_side: int = 1 - game.get_view_side()
	var lower_side: int = game.get_view_side()
	for row_index in range(2):
		var row: HBoxContainer = player_rows[row_index]
		var side: int = upper_side if row_index == 0 else lower_side
		var y: float = row.position.y
		var first_id: int = 0 if side == 0 else 2
		var left_slot: Control = row.get_child(0)
		var right_slot: Control = row.get_child(1)
		_draw_player(first_id, row.position.x + left_slot.position.x + left_slot.size.x * 0.5, y, side)
		_draw_player(first_id + 1, row.position.x + right_slot.position.x + right_slot.size.x * 0.5, y, side)
	_draw_tower_bars()
	if show_layout_bounds:
		draw_rect(Rect2(4.0, safe_top, size.x - 8.0, size.y - safe_top - safe_bottom), Color("8affb0"), false, 1.0)
		for row in player_rows: draw_rect(Rect2(row.position, row.size), Color("ffe183"), false, 1.0)
