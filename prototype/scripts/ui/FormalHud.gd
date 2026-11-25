extends Control

const UI_LAYOUT = preload("res://scripts/ui/UILayoutManager.gd")
const SettingsStore = preload("res://scripts/data/SettingsStore.gd")
const SKILL_ICON = preload("res://scripts/visuals/SkillIcon.gd")

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

# 对局内观众席：只展示，不挂点击（换席只在等待房做）。
# 收起时是右上三点键紧左边的一颗 52×52 气泡，里面只有当前观众人数；
# 展开时整条从右往左铺开，左端挨着左上退出键右侧（留 5px 空档，不贴死），
# 右端固定贴着三点键左侧。顶栏高度 52、纵向中心 51 与两颗系统键齐平；
# y 25..77 完全避开远端主塔血条（y≈127）。
# 多人在横条里从左往右排，超出宽度可横滑；零观众也能展开看空态。
const SPECTATOR_STRIP := Rect2(96.0, 25.0, 348.0, 52.0)
const SPECTATOR_STRIP_COLLAPSED := Rect2(392.0, 25.0, 52.0, 52.0)
const SPECTATOR_STEP := 34.0
const SPECTATOR_AVATAR := 28.0
const SPECTATOR_PAD := 10.0
var spectator_rows: Array = []  # [{name, portrait, me}]
var _spectator_scroll := 0.0
var spectator_expanded := false

const CHAT_VIEWPORT := Rect2(20.0, 800.0, 454.0, 88.0)
const CHAT_LINE_HEIGHT := 24.0
const CHAT_TEXT_SIZE := 16
const CHAT_MEDIA_NAME_SIZE := 14
var _chat_rows: Array[Dictionary] = []
var _chat_scroll := 0.0
var _chat_scroll_max := 0.0
var _chat_view: Control
var _chat_content: Control
# 副塔"墨水充能"：显示进度按 4 段跳，充满瞬间闪一下满杯再清空
var _ink_ratio: Array[float] = []
var _ink_flash: Array[float] = []
var _ink_prev_charge: Array[int] = []
var _ink_last_skill: Array[String] = []
var _emoji_bubble_text := ""
var _emoji_bubble_until := 0.0
var _emoji_bubble_player := -1
var _hud_redraw_accum := 0.0
const HUD_REDRAW_INTERVAL := 1.0 / 30.0
# 静态层（头像/昵称/血条/计时/观战条）内容变化远慢于球：只有签名变了才重绘，
# 30Hz 全量重画在弱机上要 8~9ms。浮动文字单独一层，仍然每帧画，手感不变。
var _hud_signature := 0

# Fading callouts ("到你啦!" / "倒计时5秒!" / "已阵亡" / "已复活").
# Drawn here, not in PrototypeMatch: the board node is rotated 180 degrees for
# the red-side view, which would render any text upside down. This node lives
# under a CanvasLayer and never sees that rotation.
# [{text, p(screen), color, size, life, duration}]
var _floaters: Array = []

const UI_FONT := preload("res://fonts/game_zh.ttf")

# Public entry: show an emoji above a player's portrait for a short time.
func show_emoji(text: String, player_id: int, seconds: float = 2.0) -> void:
	_emoji_bubble_text = text
	_emoji_bubble_player = player_id
	_emoji_bubble_until = float(Time.get_ticks_msec()) + maxf(seconds, 0.0) * 1000.0
	queue_redraw()

func _emoji_bubble_active() -> bool:
	return not _emoji_bubble_text.is_empty() and float(Time.get_ticks_msec()) < _emoji_bubble_until

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_font = UI_FONT
	# 浮字不拆层（拆到子 Control 会丢绘制），改成让"内容签名"涵盖浮字：
	# 没有浮字时静态层完全不重画，有浮字时逐帧重画——正好是需要的频率。
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
	_chat_view = Control.new()
	_chat_view.position = CHAT_VIEWPORT.position
	_chat_view.size = CHAT_VIEWPORT.size
	_chat_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_view.clip_contents = true
	add_child(_chat_view)
	_chat_content = Control.new()
	_chat_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_view.add_child(_chat_content)
	_chat_content.draw.connect(_draw_chat_lines)
	resized.connect(queue_redraw)

func _process(_dt: float) -> void:
	_update_ink_levels(_dt)
	if not _emoji_bubble_text.is_empty() and float(Time.get_ticks_msec()) >= _emoji_bubble_until:
		_emoji_bubble_text = ""
		_emoji_bubble_player = -1
	_update_floaters(_dt)
	# HUD 内容（头像/血条/墨水/浮动字）变化远慢于球。60fps 下每帧重画会把
	# 字体 shaping 和几十条绘制命令重复一遍；30Hz 已经足够，30fps 设备仍是每帧。
	_hud_redraw_accum += _dt
	if _hud_redraw_accum >= HUD_REDRAW_INTERVAL:
		_hud_redraw_accum = 0.0
		# 静态层只在内容真的变了才重画；浮字层每帧画（它是唯一需要 30Hz 的东西）。
		var signature := _hud_content_signature()
		if signature != _hud_signature:
			_hud_signature = signature
			queue_redraw()

# world_point is a board-space coordinate; converting it here keeps the callout
# glued to the ball on screen no matter which side the camera is on.
func show_floater(text: String, world_point: Vector2, color: Color, size_px: int = 28, seconds: float = 2.0) -> void:
	var at: Vector2 = world_point
	if game != null:
		at = game.to_global(world_point)
	if _floaters.size() >= 6:
		_floaters.pop_front()
	_floaters.append({"text": text, "p": at, "color": color, "size": size_px, "life": seconds, "duration": seconds})
	queue_redraw()

func _update_floaters(dt: float) -> void:
	for i in range(_floaters.size() - 1, -1, -1):
		var item: Dictionary = _floaters[i]
		item.life = float(item.life) - dt
		if float(item.life) <= 0.0:
			_floaters.remove_at(i)

# 静态 HUD 的"内容指纹"：只有它变了才重画。
# 头像/昵称永远不变，血量/轮次/墨水才是变量；墨水动画按 0.01 量化，动画停下就不再重画。
func _hud_content_signature() -> int:
	if game == null: return 0
	var h := 17
	for i in range(mini(4, game.balls.size())):
		var ball: Dictionary = game.balls[i]
		h = h * 31 + int(ball.get("hp", 0)) * 7
		h = h * 31 + (1 if bool(ball.get("alive", true)) else 0)
		h = h * 31 + (1 if _is_striker(i) else 0)
	h = h * 31 + int(ceil(game.timer))
	h = h * 31 + spectator_rows.size()
	if spectator_expanded: h += 7
	h = h * 31 + int(game.team_double_shots[0]) * 3 + int(game.team_double_shots[1]) * 5
	h = h * 31 + int(game.team_stun_shots[0]) * 3 + int(game.team_stun_shots[1]) * 5
	h = h * 31 + (1 if _emoji_bubble_active() else 0)
	# 浮字：数量 + 每条的生命周期与位置。它在动，所以有浮字时每帧签名都不同 —— 正好逐帧重画。
	h = h * 31 + _floaters.size()
	for item in _floaters:
		h = h * 31 + int(round(float(item.life) * 40.0))
		var at: Vector2 = item.p
		h = h * 31 + int(round(at.x * 0.25)) + int(round(at.y * 0.25))
	for i in range(_ink_ratio.size()):
		h = h * 31 + int(round(float(_ink_ratio[i]) * 100.0))
		h = h * 31 + int(round(float(_ink_flash[i]) * 50.0))
	return h

func _draw_floaters() -> void:
	for item in _floaters:
		var progress: float = 1.0 - float(item.life) / maxf(float(item.duration), 0.001)
		var color: Color = item.color
		# Fade all the way to zero: the old curve stopped at 15% and then popped out.
		color.a = clampf(1.0 - progress, 0.0, 1.0)
		var lift: float = progress * 42.0
		if SettingsStore.reduce_motion:
			lift = 0.0
		var at: Vector2 = (item.p as Vector2) + Vector2(0.0, -lift)
		var size_px := int(item["size"])
		var width := 280.0
		draw_string(hud_font, Vector2(at.x - width * 0.5, at.y - float(size_px) * 0.4), str(item.text), HORIZONTAL_ALIGNMENT_CENTER, width, size_px, color)

func _team_color(side: int) -> Color:
	return Color("67d8f5") if side == 0 else Color("ff809c")

# --- 对局观众名单 -------------------------------------------------------------

func set_spectator_rows(rows: Array) -> void:
	spectator_rows = rows
	# 名单变短时把横滑收回可用范围，别停在空白上
	_spectator_scroll = clampf(_spectator_scroll, 0.0, spectator_max_scroll())
	queue_redraw()


func set_spectator_scroll(value: float) -> void:
	_spectator_scroll = clampf(value, 0.0, spectator_max_scroll())
	queue_redraw()


func set_spectator_expanded(value: bool) -> void:
	if spectator_expanded == value:
		return
	spectator_expanded = value
	if not value:
		_spectator_scroll = 0.0
	queue_redraw()


# 当前气泡占的屏幕矩形。展开/收起两种状态都由这里给出，页面层只读它，
# 不自己算坐标，热区与绘制永远一致。
func spectator_strip_rect() -> Rect2:
	return SPECTATOR_STRIP if spectator_expanded else SPECTATOR_STRIP_COLLAPSED


# 横条里可放头像的净宽（左右各留一个内边距）。
func spectator_view_width() -> float:
	return SPECTATOR_STRIP.size.x - SPECTATOR_PAD * 2.0


func spectator_max_scroll() -> float:
	if not spectator_expanded:
		return 0.0
	var content: float = float(spectator_rows.size()) * SPECTATOR_STEP - (SPECTATOR_STEP - SPECTATOR_AVATAR)
	return maxf(0.0, content - spectator_view_width())


func _spectator_tint(key: String) -> Color:
	return AVATAR_FILLS[posmod(key.hash(), AVATAR_FILLS.size())]


func _spectator_pill(rect: Rect2) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.055, 0.043, 0.11, 0.74)
	box.border_color = Color(0.42, 0.31, 0.72, 0.5)
	box.set_border_width_all(1)
	box.set_corner_radius_all(int(rect.size.y * 0.5))
	draw_style_box(box, rect)


func _draw_spectators() -> void:
	if hud_font == null:
		return
	if spectator_expanded:
		_draw_spectator_bar()
	else:
		_draw_spectator_bubble()


# 收起态：一颗药丸气泡，中间只写当前观众人数（没有人就是 0）。
# 不放图标、不放"人"字：一眼看数是几，点一下才铺开。
func _draw_spectator_bubble() -> void:
	var rect: Rect2 = SPECTATOR_STRIP_COLLAPSED
	_spectator_pill(rect)
	var count: int = spectator_rows.size()
	var ink: Color = Color("d6cde7") if count > 0 else Color("8e8e93")
	var center: Vector2 = rect.get_center()
	# 18px 数字在 52px 圆里居中：基线按字号略下压，读起来不偏高。
	_text_center(str(count), center.x, center.y + 6.5, rect.size.x, 18, ink)


# 展开态：一列圆头像，从左往右排；人多时按页面层推来的偏移横滑，
# 只画完整落在条里的头像，松手吸附整格，边缘不会留半张脸。
func _draw_spectator_bar() -> void:
	var rect: Rect2 = SPECTATOR_STRIP
	_spectator_pill(rect)
	var left: float = rect.position.x + SPECTATOR_PAD
	var right: float = rect.end.x - SPECTATOR_PAD
	var radius: float = SPECTATOR_AVATAR * 0.5
	var max_scroll: float = spectator_max_scroll()
	var scroll: float = clampf(_spectator_scroll, 0.0, max_scroll)
	var cy: float = rect.position.y + rect.size.y * 0.5
	for index in range(spectator_rows.size()):
		var entry: Variant = spectator_rows[index]
		if not entry is Dictionary:
			continue
		var row: Dictionary = entry
		var cx: float = left + radius + float(index) * SPECTATOR_STEP - scroll
		if cx - radius < left - 0.5 or cx + radius > right + 0.5:
			continue
		var who := str(row.get("name", "观众"))
		var center := Vector2(cx, cy)
		var portrait: Texture2D = row.get("portrait")
		draw_circle(center, radius, _spectator_tint(who))
		if portrait != null:
			draw_texture_rect(portrait, Rect2(cx - radius, cy - radius, SPECTATOR_AVATAR, SPECTATOR_AVATAR), false)
		else:
			var glyph := who.strip_edges().substr(0, 1).to_upper()
			if not glyph.is_empty():
				_text_center(glyph, cx, cy + 5.0, SPECTATOR_AVATAR, 13, Color("f2eefb"))
		draw_arc(center, radius, 0.0, TAU, 26, Color(0.42, 0.31, 0.72, 0.6), 1.0)
		if bool(row.get("me", false)):
			draw_arc(center, radius + 1.0, 0.0, TAU, 26, Color("67d8f5"), 1.6)
	if spectator_rows.is_empty():
		# 空态写在展开条的最左边，和头像的起始位置对齐 —— 读起来像"这一列从这里开始"。
		draw_string(hud_font, Vector2(left, cy + 4.5), "暂无观众",
			HORIZONTAL_ALIGNMENT_LEFT, right - left, 13, Color("5c5c61"))
	if max_scroll > 0.0:
		# 细轨提示"还能滑"：只在真的放不下时出现
		var track_w: float = right - left
		var track := Rect2(left, rect.end.y - 9.0, track_w, 2.0)
		draw_rect(track, Color(1.0, 1.0, 1.0, 0.06), true)
		var thumb_w: float = maxf(20.0, track_w * (track_w / (track_w + max_scroll)))
		var thumb_x: float = track.position.x + (track_w - thumb_w) * clampf(scroll / max_scroll, 0.0, 1.0)
		draw_rect(Rect2(thumb_x, track.position.y, thumb_w, 2.0), Color(1.0, 1.0, 1.0, 0.22), true)

# 缺头像时的填色盘：同一昵称永远得到同一色，四个座位不会撞成同一张脸。
const AVATAR_FILLS := [Color("2b3040"), Color("322b40"), Color("24323a"), Color("3a2f2a")]


# --- 球盘外的回合与读秒 -------------------------------------------------------
# 顶部中间原来写着「第 N 回合 · 谁 · 15 秒」，那行字既挤在系统键之间，
# 也和观众条抢位置。现在只把两侧留白用起来：左边「回合N」，右边「N秒」，
# 纵向对齐球盘（激光边界六边形）的中点。位置按 field_corners 的屏幕包围盒算，
# 不写死像素，两种视角、任何安全区下都贴在球盘外侧。
const SIDE_TEXT_SIZE := 16
const SIDE_TEXT_MARGIN := 6.0
const SIDE_TEXT_GAP := 5.0

func _field_screen_bounds() -> Rect2:
	if game == null or game.field_corners.is_empty():
		return Rect2()
	var bounds := Rect2(game.to_global(game.field_corners[0]), Vector2.ZERO)
	for index in range(1, game.field_corners.size()):
		bounds = bounds.expand(game.to_global(game.field_corners[index]))
	return bounds


func _draw_round_timer() -> void:
	var bounds: Rect2 = _field_screen_bounds()
	if bounds.size.x <= 0.0 or hud_font == null:
		return
	var mid_y: float = bounds.position.y + bounds.size.y * 0.5
	var round_text := "回合%d" % int(game.turn_manager.round_number)
	# 右对齐到球盘左边缘：回合数从 1 涨到 20 时文字向左长，不会顶到棋盘。
	var left_w: float = bounds.position.x - SIDE_TEXT_GAP - SIDE_TEXT_MARGIN
	if left_w > 24.0:
		draw_string(hud_font, Vector2(SIDE_TEXT_MARGIN, mid_y + 5.5), round_text,
			HORIZONTAL_ALIGNMENT_RIGHT, left_w, SIDE_TEXT_SIZE, Color("b8aacb"))
	if game.finished:
		return
	# 读秒左对齐到球盘右边缘，末 5 秒转暖金提醒，和紫蓝底拉开层次。
	var seconds: int = maxi(0, int(ceil(game.timer)))
	var right_x: float = bounds.end.x + SIDE_TEXT_GAP
	var right_w: float = size.x - right_x - SIDE_TEXT_MARGIN
	if right_w > 24.0:
		var tint := Color("ffcf70") if seconds <= 5 else Color("b8aacb")
		draw_string(hud_font, Vector2(right_x, mid_y + 5.5), "%d秒" % seconds,
			HORIZONTAL_ALIGNMENT_LEFT, right_w, SIDE_TEXT_SIZE, tint)


func _avatar_fill(player_id: int) -> Color:
	var key: String = player_names[player_id] if player_id < player_names.size() else ""
	return AVATAR_FILLS[posmod(key.hash(), AVATAR_FILLS.size())]

func _avatar_glyph(player_id: int) -> String:
	var key: String = player_names[player_id] if player_id < player_names.size() else ""
	key = key.strip_edges()
	if key.is_empty(): return ""
	return key.substr(0, 1).to_upper()

func _text_center(text: String, center_x: float, baseline: float, width: float, size_px: int, color: Color) -> void:
	draw_string(hud_font, Vector2(center_x - width * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, width, size_px, color)

# 谁是"当前击球人"。判定只读权威回合状态（game.turn 来自快照），
# 不看本地是否可操作，所以参赛和观战两边看到的永远是同一个人。
# 双人模式一人两球：轮到本方任一球都算本人在击球，两个头像一起亮，
# 否则高亮会在两张一模一样的脸之间来回跳，看起来像换了个人。
func _is_striker(ball_slot: int) -> bool:
	if game == null or game.finished: return false
	if ball_slot < 0 or ball_slot >= game.balls.size(): return false
	if not bool(game.balls[ball_slot].get("alive", true)): return false
	var current: int = int(game.turn)
	if ball_slot == current: return true
	var tm = game.turn_manager
	if tm == null or not tm.has_method("player_for_slot"): return false
	if current < 0 or current >= game.balls.size(): return false
	return tm.player_for_slot(ball_slot) == tm.player_for_slot(current)


func _draw_player(player_id: int, center_x: float, row_y: float, side: int) -> void:
	var color: Color = _team_color(side)
	var active: bool = _is_striker(player_id)
	var portrait_center := Vector2(center_x, row_y + 22.0)
	var portrait: Texture2D = player_portraits[player_id] if player_id < player_portraits.size() else null
	# 正在击球的人：先铺一层柔光再画头像。光晕比描边更能"提亮"，
	# 又不会像加粗描边那样在深色底上糊成一圈。
	if active:
		draw_circle(portrait_center, 23.0, Color(color.r, color.g, color.b, 0.13))
		draw_arc(portrait_center, 21.0, 0.0, TAU, 44, Color(color.r, color.g, color.b, 0.34), 3.0)
	draw_circle(portrait_center, 18.0, Color(0.09, 0.07, 0.19, 0.66))
	if portrait != null:
		draw_texture_rect(portrait, Rect2(portrait_center - Vector2(16, 16), Vector2(32, 32)), false)
	else:
		# 没有真实头像（游客号 / 从未上传）：画首字，颜色按昵称固定。
		# 绝不再借本机预置图——那是所有客户端共用的同一张脸，四个座位会看着像同一个人。
		draw_circle(portrait_center, 16.0, _avatar_fill(player_id))
		var glyph := _avatar_glyph(player_id)
		if not glyph.is_empty():
			_text_center(glyph, portrait_center.x, portrait_center.y + 5.0, 32.0, 15, Color("f2eefb"))
	draw_arc(portrait_center, 18.0, 0.0, TAU, 48, color.lightened(0.32) if active else color, 2.4 if active else 1.2)
	# Local-only emoji bubble above the matching player's portrait.
	if player_id == _emoji_bubble_player and _emoji_bubble_active():
		var bubble_center := portrait_center + Vector2(0.0, -34.0)
		var bubble_rect := Rect2(bubble_center.x - 24.0, bubble_center.y - 17.0, 48.0, 34.0)
		var bubble_box := StyleBoxFlat.new()
		bubble_box.bg_color = Color(0.13, 0.10, 0.24, 0.92)
		bubble_box.border_color = Color(color.r, color.g, color.b, 0.8)
		bubble_box.set_border_width_all(2)
		bubble_box.set_corner_radius_all(12)
		draw_style_box(bubble_box, bubble_rect)
		_text_center(_emoji_bubble_text, bubble_center.x, bubble_center.y + 7.0, 44.0, 18, Color.WHITE)
	var nickname: String = player_names[player_id] if player_id < player_names.size() else "玩家 %d" % (player_id + 1)
	nickname = nickname.strip_edges()
	if nickname.is_empty(): nickname = "玩家 %d" % (player_id + 1)
	# HUD 每格只有 112px 宽（13px 字号约 8 个汉字），超出会压到相邻座位。
	if nickname.length() > 8: nickname = nickname.left(8)
	# 昵称与头像同时提亮：未轮到的人压到次要色，轮到时回到纯白，
	# 远看也能一眼分出"该谁打"，不必再在顶部写一行中央文字。
	_text_center(nickname, center_x, row_y + 58.0, 112.0, 13, Color("ffffff") if active else Color("b8aacb"))
	# Player HP bar bound to the live ball HP, placed under the off-board portrait.
	var hp_ratio: float = 0.0
	if player_id >= 0 and player_id < game.balls.size():
		var ball_hp: int = int(game.balls[player_id].get("hp", 0))
		var max_hp: int = int(game.PLAYER_HP)
		hp_ratio = clampf(float(ball_hp) / float(max_hp), 0.0, 1.0) if max_hp > 0 else 0.0
	# HUD health bar under the portrait. Width is back to 70 (140 read too heavy);
	# tower bars below use the same 4px thickness so every bar looks the same weight.
	var bar := Rect2(center_x - 35.0, row_y + 66.0, 70.0, 4.0)
	draw_rect(bar, Color(0.40, 0.36, 0.53, 0.45), true)
	var hp_color: Color = Color("69e7a4")
	hp_color.a = 0.92 if active else 0.7
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * hp_ratio, bar.size.y)), hp_color, true)
	# Mark the dead slot until its next turn.
	if player_id >= 0 and player_id < game.balls.size():
		var ball: Dictionary = game.balls[player_id]
		if not bool(ball.get("alive", true)):
			draw_circle(portrait_center, 18.0, Color(0.04, 0.03, 0.08, 0.82))
			_text_center("阵亡", portrait_center.x, portrait_center.y + 5.0, 40.0, 15, Color("c9c2d6"))
		# #13 副塔充能与已绑技能
		var side_of: int = player_id
		if int(game.match_mode) == 1:
			side_of = 0 if player_id < 2 else 1
		else:
			side_of = 0 if player_id == 0 else 1
		# 充能已经画在副塔身上了，头像下不再重复
		# 棋盘外的头像旁只显示"已经生效"的队伍效果，且会闪烁；
		# 棋盘内的球上什么都不加，避免遮挡。
		var now_s := float(Time.get_ticks_msec()) / 1000.0
		var buff_center := portrait_center + Vector2(22.0, 0.0)
		if int(game.team_double_shots[side_of]) > 0:
			draw_circle(buff_center, 10.0, Color(0.04, 0.03, 0.08, 0.92))
			SKILL_ICON.draw_skill_icon(self, buff_center, 7.5, "double", now_s)
			buff_center += Vector2(18.0, 0.0)
		if int(game.team_stun_shots[side_of]) > 0:
			draw_circle(buff_center, 10.0, Color(0.04, 0.03, 0.08, 0.92))
			SKILL_ICON.draw_skill_icon(self, buff_center, 7.5, "stun", now_s)
			# Remaining stunned action slots, right next to the icon (disc radius is
			# 10px, so 13px clears it). Without the number the player cannot tell how
			# long the stun lasts and it just feels like "I am always stunned".
			var stun_left: int = int(game.team_stun_shots[side_of])
			var stun_color: Color = _skill_tint("stun")
			stun_color.a = 0.95
			draw_string(hud_font, Vector2(buff_center.x + 13.0, buff_center.y + 5.5), str(stun_left),
				HORIZONTAL_ALIGNMENT_LEFT, 20.0, 16, stun_color)

func _skill_tint(skill: String) -> Color:
	match skill:
		"double":
			return Color("e7c68d")
		"heal":
			return Color("69e7a4")
		"stun":
			return Color("a27dea")
	return Color("8e8e93")


# 每帧把"墨水高度"追到目标段位。4 段 = 0/25/50/75/100%，涨得快一点才有倒进去的感觉。
func _update_ink_levels(dt: float) -> void:
	if game == null:
		return
	var count: int = game.tower_skill.size()
	while _ink_ratio.size() < count:
		_ink_ratio.append(0.0)
		_ink_flash.append(0.0)
		_ink_prev_charge.append(0)
		_ink_last_skill.append("")
	for i in range(count):
		var st: Dictionary = game.tower_skill[i]
		var skill := str(st.get("skill", ""))
		var charge: int = int(st.get("charge", 0))
		if not skill.is_empty():
			_ink_last_skill[i] = skill
		# 第 4 手会当帧激活并把技能清空，所以"上一次看到的是 3 格"就当作刚刚满杯
		if skill.is_empty() and _ink_prev_charge[i] >= 3:
			_ink_flash[i] = 1.0
		_ink_prev_charge[i] = charge if not skill.is_empty() else 0
		if _ink_flash[i] > 0.0:
			# 满杯亮一下再排空：玩家要靠这一下认出是什么颜色/技能
			_ink_flash[i] = maxf(0.0, _ink_flash[i] - dt * 0.9)
			_ink_ratio[i] = 1.0
			continue
		var target := clampf(float(charge) / 4.0, 0.0, 1.0) if not skill.is_empty() else 0.0
		_ink_ratio[i] = move_toward(_ink_ratio[i], target, dt * 1.33)


# 往塔身里倒墨：液面以下的圆缺填成技能色，液面上留一道亮线
func _draw_ink_glass(center: Vector2, radius: float, ratio: float, color: Color) -> void:
	var r := maxf(radius - 2.0, 3.0)
	var level := clampf(ratio, 0.0, 1.0)
	if level <= 0.001:
		return
	var body := Color(color.r, color.g, color.b, 0.55)
	# 杯壁：一圈很淡的环，让"塔身"读起来像装着东西的容器
	draw_arc(center, r, 0.0, TAU, 36, Color(color.r, color.g, color.b, 0.22), 1.0, true)
	if level >= 0.999:
		draw_circle(center, r, body)
		draw_arc(center, r, 0.0, TAU, 44, Color(color.r, color.g, color.b, 0.85), 1.6, true)
		return
	var surface_y := center.y + r - 2.0 * r * level
	var dy := clampf(surface_y - center.y, -r, r)
	var half_w := sqrt(maxf(r * r - dy * dy, 0.0))
	# 沿下半圆从左边走到右边：先算两个端点角，再保证扫过正下方（+π/2）
	var a0 := atan2(dy, -half_w)
	var a1 := atan2(dy, half_w)
	while a1 > a0:
		a1 -= TAU
	var segs := maxi(8, int(absf(a1 - a0) / 0.16))
	var poly := PackedVector2Array()
	for i in range(segs + 1):
		var ang := lerpf(a0, a1, float(i) / float(segs))
		poly.append(center + Vector2(cos(ang), sin(ang)) * r)
	draw_colored_polygon(poly, body)
	# 液面反光
	draw_line(Vector2(center.x - half_w, surface_y), Vector2(center.x + half_w, surface_y),
		Color(color.r, color.g, color.b, 0.92), 1.6, true)


func _draw_tower_bars() -> void:
	var now_s := float(Time.get_ticks_msec()) / 1000.0
	for tower_index in range(game.towers.size()):
		var t: Dictionary = game.towers[tower_index]
		var screen: Vector2 = game.to_global(t.p)
		var upper: bool = screen.y < size.y * 0.5
		var width: float = 52.0 if t.main else 34.0
		var y: float = screen.y - t.r - (26.0 if t.main else 13.0) if upper else screen.y + t.r + (34.0 if t.main else 10.0)
		var rect := Rect2(screen.x - width * 0.5, y, width, 4.0)
		draw_rect(rect, Color(0.22, 0.19, 0.34, 0.68), true)
		var fill: Color = _team_color(t.side)
		fill.a = 0.88
		var hp_max: float = float(game.tower_hp_max()) if game.has_method("tower_hp_max") else 100.0
		draw_rect(Rect2(rect.position, Vector2(width * clampf(float(t.hp) / maxf(hp_max, 1.0), 0.0, 1.0), 4.0)), fill, true)
		if show_layout_bounds: draw_rect(rect.grow(2.0), Color("ffe183"), false, 1.0)
		# 副塔充能：塔身像玻璃杯，按 4 段倒进技能色的墨水；图标在杯里悬浮、随液面上浮而变实
		if tower_index < game.tower_skill.size() and not bool(t.main):
			var st: Dictionary = game.tower_skill[tower_index]
			var skill := str(st.get("skill", ""))
			var ink := _ink_ratio[tower_index] if tower_index < _ink_ratio.size() else 0.0
			var tint_skill := skill if not skill.is_empty() else (_ink_last_skill[tower_index] if tower_index < _ink_last_skill.size() else "")
			if ink > 0.001 and not tint_skill.is_empty():
				_draw_ink_glass(screen, t.r, ink, _skill_tint(tint_skill))
			if not skill.is_empty():
				var bob := sin(now_s * 1.5) * 2.2
				var icon_center := screen + Vector2(0.0, lerpf(t.r * 0.34, 0.0, ink) + bob)
				var icon_alpha := lerpf(0.32, 1.0, ink)
				draw_circle(icon_center, 11.0, Color(0.04, 0.03, 0.08, 0.86 * icon_alpha))
				SKILL_ICON.draw_skill_icon(self, icon_center, 8.0, skill, now_s, icon_alpha)

func set_chat_lines(lines: Array, appended := false) -> void:
	_chat_rows.clear()
	var bottom := CHAT_VIEWPORT.size.y
	for i in range(lines.size() - 1, -1, -1):
		var message: Dictionary = lines[i]
		var texture: Texture2D = message.get("tex")
		var media_src: String = message.get("media_src", "")
		var height := CHAT_LINE_HEIGHT
		var row: Dictionary
		if texture != null or not media_src.is_empty():
			var source: Vector2 = texture.get_size() if texture != null else message.media_size
			var dimensions := source * minf(240.0 / source.x, 64.0 / source.y)
			var label := "%s：" % message.get("nickname", "")
			var label_width := minf(170.0, hud_font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, CHAT_MEDIA_NAME_SIZE).x + 8.0)
			height = maxf(CHAT_LINE_HEIGHT, dimensions.y + 8.0)
			row = {
				"image_rect": Rect2(Vector2(label_width + 6.0, bottom - height), dimensions),
				"texture": texture, "media_src": media_src, "id": message.get("attachment", ""),
				"text": label, "label_width": label_width,
			}
		else:
			row = {"text": "%s：%s" % [message.get("nickname", ""), message.get("body", "")]}
		row["top"] = bottom - height
		row["bottom"] = bottom
		bottom -= height
		_chat_rows.append(row)
	_chat_scroll_max = maxf(0.0, -bottom)
	if appended and _chat_scroll > 0.0 and not _chat_rows.is_empty():
		_chat_scroll += float(_chat_rows[0].bottom) - float(_chat_rows[0].top)
	_chat_scroll = clampf(_chat_scroll, 0.0, _chat_scroll_max)
	_update_chat_scroll()


func scroll_chat(delta: float) -> bool:
	var next := clampf(_chat_scroll + delta, 0.0, _chat_scroll_max)
	if is_equal_approx(next, _chat_scroll):
		return false
	_chat_scroll = next
	_update_chat_scroll()
	return true


func _update_chat_scroll() -> void:
	_chat_content.position.y = _chat_scroll
	_chat_content.queue_redraw()


# 手绘八分音符：game_zh.ttf 没有 ♪/♫ 的字形，Web 端会变方块，所以用形状画。
func _draw_music_note() -> void:
	var ink := Color(1.0, 1.0, 1.0, 0.88)
	var cx := 504.0
	var cy := 920.0
	draw_circle(Vector2(cx, cy + 6.0), 5.0, ink)
	draw_line(Vector2(cx + 4.6, cy + 6.0), Vector2(cx + 4.6, cy - 12.0), ink, 2.0)
	draw_line(Vector2(cx + 4.6, cy - 12.0), Vector2(cx + 13.0, cy - 7.0), ink, 2.0)


func _visible_chat_rows() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for row in _chat_rows:
		if float(row.top) + _chat_scroll >= CHAT_VIEWPORT.size.y:
			continue
		if float(row.bottom) + _chat_scroll <= 0.0:
			break
		rows.append(row)
	return rows


func chat_media_tiles(previous_ids: Dictionary) -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	for row in _visible_chat_rows():
		if str(row.get("media_src", "")).is_empty():
			continue
		var rect: Rect2 = row.image_rect
		var tile := {"id": row.id, "rect": [rect.position.x, rect.position.y + _chat_scroll, rect.size.x, rect.size.y]}
		if not previous_ids.has(row.id):
			tile["src"] = row.media_src
		tiles.append(tile)
	return tiles


func chat_text_tiles() -> Array[Dictionary]:
	var tiles: Array[Dictionary] = []
	for row in _visible_chat_rows():
		tiles.append({
			"text": row.text,
			"top": float(row.top) + _chat_scroll,
			"width": row.get("label_width", 410.0),
			"font_size": CHAT_MEDIA_NAME_SIZE if row.has("image_rect") else CHAT_TEXT_SIZE,
		})
	return tiles


func _draw_chat_lines() -> void:
	for row in _visible_chat_rows():
		if row.has("image_rect"):
			if row.texture != null:
				_chat_content.draw_texture_rect(row.texture, row.image_rect, false)
		# Web chat uses the browser's emoji fonts inside the same clipped viewport.
		if OS.has_feature("web"):
			continue
		var font_size := CHAT_MEDIA_NAME_SIZE if row.has("image_rect") else CHAT_TEXT_SIZE
		_chat_content.draw_string(hud_font, Vector2(0.0, float(row.top) + CHAT_LINE_HEIGHT - 4.0),
			row.text, HORIZONTAL_ALIGNMENT_LEFT, float(row.get("label_width", 410.0)), font_size,
			Color(1.0, 1.0, 1.0, 0.95))


func _draw() -> void:
	_draw_music_note()
	if game == null or game.towers.is_empty() or hud_font == null or player_rows.size() != 2: return
	var draw_started_us := Time.get_ticks_usec()
	var upper_side: int = 1 - game.get_view_side()
	var lower_side: int = game.get_view_side()
	for row_index in range(2):
		var row: HBoxContainer = player_rows[row_index]
		var side: int = upper_side if row_index == 0 else lower_side
		var y: float = row.position.y
		var first_id: int = 0 if side == 0 else 2
		var left_slot: Control = row.get_child(0)
		var right_slot: Control = row.get_child(1)
		var left_id: int = first_id + 1 if game.get_view_side() == 0 else first_id
		var right_id: int = first_id if game.get_view_side() == 0 else first_id + 1
		_draw_player(left_id, row.position.x + left_slot.position.x + left_slot.size.x * 0.5, y, side)
		_draw_player(right_id, row.position.x + right_slot.position.x + right_slot.size.x * 0.5, y, side)
	_draw_spectators()
	_draw_tower_bars()
	_draw_round_timer()
	_draw_floaters()
	if show_layout_bounds:
		draw_rect(Rect2(4.0, safe_top, size.x - 8.0, size.y - safe_top - safe_bottom), Color("8affb0"), false, 1.0)
		for row in player_rows: draw_rect(Rect2(row.position, row.size), Color("ffe183"), false, 1.0)
	if game != null and game.has_method("note_hud_draw_us"):
		game.note_hud_draw_us(Time.get_ticks_usec() - draw_started_us)
