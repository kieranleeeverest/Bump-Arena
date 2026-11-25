extends Control

# Standalone design preview only. Never loaded by main.tscn.
const AVATARS = preload("res://design_preview/AvatarPreviewAssets.gd")
const UI_FONT := preload("res://fonts/game_zh.ttf")
const SettingsStore = preload("res://scripts/data/SettingsStore.gd")
const BG := Color("0a0a0b")
const SURFACE := Color("101012")
const BUBBLE_SELF := Color("17191b")
const LINE := Color("1e1e22")
const INK := Color("f5f5f7")
const MUTED := Color("8e8e93")
const WEAK := Color("5c5c61")
const CYAN := Color("6fd3e8")
const PINK := Color("ba8b9e")
const GOLD := Color("e7c68d")
const AVATAR_A := Color("303840")
const AVATAR_B := Color("39333d")
const AVATAR_C := Color("34383a")
const FONT_CAPTION := 16
const FONT_SECONDARY := 20
const FONT_BODY := 28
const FONT_TITLE := 36
const PAGE_GUTTER := 20.0
const NAV_Y := 848.0
const NAV_H := 112.0
const NAV_SLOT_W := 180.0
const LIST_ROW_H := 96.0
const RADIUS := 10
# Presence threshold: heartbeat runs every 25s, so 60s tolerates one missed beat.
const ONLINE_WINDOW_SECONDS := 60

var page := "lobby"
var portraits: Array[Texture2D] = []
var font: Font
var display_name := "星澜"
var active_friend_name := "星澜" # Set by shell when entering a friend chat.
var suggest_nickname := false # True when the cloud username looks auto-generated.
var signature := "在群星之间，等待下一次碰撞。"
var room_ready := false
var room_opponent_ready := false
var room_blue_name := "星澜"
var room_red_name := "" # 对方没进房间时留空；旧值硬编码"绯月"是本地演示占位
# Chat page view state, mirrored from the shell (Step 5.5 cloud messages).
var chat_messages: Array = []    # [{id, from_user, body, created_at}], oldest first
var chat_state := ""             # "" | "loading" | "ready" | "failed"
var chat_last_error := ""
var chat_self_id := ""           # UID of the signed-in user, decides bubble side
var result_winner := "演示：蓝方获胜"
var result_names := PackedStringArray()
var result_portraits: Array[Texture2D] = []
var room_label := ""
# 大厅房间列表：[{code, host, players, createdAt}]，由 AppShell 轮询 /api/rooms 写入
var room_list: Array = []
# 大厅房间列表的滚动偏移（px）。房间多的时候一屏放不下，AppShell 负责手势，
# 这里只管按偏移绘制；越界的行直接跳过，底栏以下不会露出来。
var lobby_scroll := 0.0
# 列表请求失败时的原因（空 = 请求正常）。必须和"没人开桌"区分开：
# 两者画面一样的话，排查时分不清是网关/登录坏了还是真没人建房。
var room_list_error := ""
var room_is_host := true
# 单机测试态：借用等待房这一屏，但不联网、没有房间号、没有第二个玩家。
var room_is_solo := false
var invite_url := ""
var room_slot_names := PackedStringArray() # Player name for each slot in squad mode.
var room_slot_ready := []                  # Ready state for each slot.
# 每座位的真实头像（四人模式按 slot 索引）。空 = 该玩家没上传过，回落首字。
var room_slot_portraits: Array[Texture2D] = []
var match_mode := 0 # 0 = duel, 1 = squad
var room_reconnecting := false # Mirrored from the network client; always false in local hotseat.
# Waiting-room additions: host intro, spectator drawer, and my own role.
var room_intro := ""
var room_phase := "waiting"       # "waiting" | "playing"
var room_connecting := false      # Socket not ready yet: no role, no actions.
var room_spectator := false       # This device watches instead of playing.
var room_spectators: Array = []   # [{name, portrait, me}], oldest first.
var room_spectator_scroll := 0.0  # Horizontal offset inside the avatar strip.
const SEAT_TOP := 360.0
const SEAT_H := 88.0
# 等待房顶排：左边观战席（常显、可横滑），右边邀请好友，两框各 240 宽。
# 观战席 = 可滚动的圆头像区 + 条内最右端一个固定的空心加号，中间用发丝线分界。
const SPECTATOR_STRIP := Rect2(20.0, 168.0, 240.0, 80.0)
const INVITE_RECT := Rect2(280.0, 168.0, 240.0, 80.0)
const SPECTATOR_AVATAR := 48.0
# 48 头像 + 8px 空隙 = 56 一步。160px 的头像区正好放下 3 张整头像，
# 第 4 个人进来才开始滚——不会"只放得下两张就先冒滚动条"。
const SPECTATOR_STEP := 56.0
# 条内最右端固定给加号：60px 一格，不参与滚动，与头像区之间留 8px 分界。
const SPECTATOR_PLUS_ZONE := 60.0
const SPECTATOR_GAP := 8.0
const SPECTATOR_SIDE_PAD := 12.0
const BLUE_TEAM := CYAN
const RED_TEAM := Color("e2726e")
# Friend page view state, mirrored from the shell (Step 5 cloud data).
var friend_rows: Array = []      # [{id, username, avatar_key, last_seen, since}]
var friend_pending_count := 0    # Incoming requests waiting for an answer.
var friend_state_text := ""      # Sync status line; empty means "not loaded yet".
var friend_failed := false       # True when the last sync failed: never claim "no friends".
var friend_portraits: Dictionary = {} # uid -> downloaded avatar texture (empty = initials)
var active_friend_portrait: Texture2D = null # Chat header avatar, null = initials
# Friend uid -> unread message count, filled by the shell from server rows newer
# than this device's read watermark. The sum drives the bottom-bar badge; each
# row shows only its own count.
var unread_by_friend: Dictionary = {}
# Room code parsed out of the newest invite message; empty = nothing to join.
var chat_invite_code := ""
# 气泡里的每一行文字。Web 上这些交给 DOM 覆盖层渲染（浏览器字体才有 emoji），
# 位置由这里算好，GDScript 侧就不再画文字。
var chat_text_tiles_out: Array[Dictionary] = []
# 私聊图片块（Web 交给 DOM <img> 渲染，动图才会动）
var chat_image_tiles_out: Array[Dictionary] = []
# 消息列表滚动量：0 = 贴着底部（最新），正值 = 往上看更早的消息
var chat_scroll := 0.0
var chat_scroll_max := 0.0
const CHAT_LIST_TOP := 176.0
const CHAT_LIST_BOTTOM := 728.0
# Rect of every drawn bubble, index-aligned with chat_messages. Unpainted entries
# stay zero-sized. The shell reads this to put hit zones on invite messages —
# the chat list is pure _draw and has no controls of its own.
var chat_message_rects: Array[Rect2] = []
var local_seat := -1             # View index of my own waiting-room seat, -1 = unknown
var my_level := 1                # Real level from profiles.level (no XP system yet)
# In-room player card (opened by tapping another player's avatar).
var view_player_name := ""
var view_player_signature := ""
var view_player_level := 1
var view_player_state := ""      # "" | "loading" | "ready" | "failed"
var view_player_error := ""
var view_player_relation := "none" # "friend" | "requested" | "none"
var view_player_portrait: Texture2D = null

# Auth screen view state, mirrored from the shell.
var auth_mode := 0 # 0 = sign in, 1 = sign up
var auth_step := 0 # 0 = 邮箱密码；1 = 输入邮箱验证码
var auth_email := ""
var auth_password := ""
var auth_pending_email := ""
var auth_otp := ""
var auth_otp_error := ""
var auth_resend_wait := 0 # 重发冷却剩余秒数，>0 时按钮禁用
var auth_error := ""
var auth_progress := ""
var auth_signed_in := false # Mirrors supabase.session_valid() when the auth page opens.
var auth_identity := "" # Short display identity, never the full email.
var account_email := "" # 资料页展示的注册邮箱（仅自己可见）
var account_uid_short := "" # First 8 chars of the real account id; empty when signed out
var profile_sync_text := "" # Cloud sync status line, never faked
var realtime_text := "" # Realtime channel status, so a silent socket is visible

enum SeatState { EMPTY, WAITING, READY, RECONNECTING }

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Embedded CJK font (the Web build cannot borrow system fonts).
	font = UI_FONT

func panel(r: Rect2, fill: Color = SURFACE, edge: Color = Color.TRANSPARENT, rad: int = RADIUS) -> void:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = edge
	s.set_border_width_all(0 if edge.a == 0.0 else 1)
	s.set_corner_radius_all(rad)
	draw_style_box(s, r)

func txt(value: String, x: float, y: float, w: float, fs: int = FONT_SECONDARY, color: Color = INK, align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	draw_string(font, Vector2(x, y), value, align, w, fs, color)

func circle_icon(c: Vector2, label: String, color: Color = MUTED, radius: float = 22.0) -> void:
	txt(label, c.x - radius, c.y + 7, radius * 2.0, FONT_SECONDARY, color, HORIZONTAL_ALIGNMENT_CENTER)

func avatar(id: int, c: Vector2, radius: float = 26.0, color: Color = AVATAR_A, portrait_override: Texture2D = null) -> void:
	draw_circle(c, radius, color)
	var portrait: Texture2D = portrait_override
	if portrait == null and id >= 0 and id < portraits.size(): portrait = portraits[id]
	if portrait != null:
		draw_texture_rect(portrait, Rect2(c - Vector2.ONE * radius, Vector2.ONE * radius * 2), false)
	else:
		var name := display_name if id <= 0 else str(AVATARS.NAMES[id])
		initial_avatar(name, c, radius, color)

# Placeholder avatar for a remote player. Their real image only exists on their own
# device, so borrowing a local portrait here would show the wrong person.
func initial_avatar(name: String, c: Vector2, radius: float = 26.0, color: Color = AVATAR_A) -> void:
	var glyph := "?"
	if not name.is_empty():
		glyph = name.substr(0, 1).to_upper()
	draw_circle(c, radius, color)
	var fs: int = FONT_BODY if radius >= 25.0 else FONT_SECONDARY
	txt(glyph, c.x - radius, c.y + fs * 0.36, radius * 2, fs, INK, HORIZONTAL_ALIGNMENT_CENTER)

# Stable neutral fill per player.
func friend_tint(key: String) -> Color:
	var palette := [AVATAR_A, AVATAR_B, AVATAR_C]
	if key.is_empty():
		return palette[0]
	var picked: Color = palette[posmod(key.hash(), palette.size())]
	return picked

# --- Presence (Step 6) -----------------------------------------------------
# last_seen is a timestamptz string like "2026-11-23T07:59:32.51068+00:00".
# Only the first 19 chars are needed and they are already UTC.
func _last_seen_age(iso: String) -> int:
	if iso.length() < 19:
		return -1
	var stamp := int(Time.get_unix_time_from_datetime_string(iso.substr(0, 19)))
	if stamp <= 0:
		return -1
	return int(Time.get_unix_time_from_system()) - stamp

func is_online(last_seen: String) -> bool:
	var age := _last_seen_age(last_seen)
	return age >= 0 and age < ONLINE_WINDOW_SECONDS

func presence_text(last_seen: String) -> String:
	var age := _last_seen_age(last_seen)
	if age < 0:
		return "在线状态未知"
	if age < ONLINE_WINDOW_SECONDS:
		return "在线"
	if age < 3600:
		return "%d 分钟前在线" % maxi(age / 60, 1)
	if age < 86400:
		return "%d 小时前在线" % (age / 3600)
	return "%d 天前在线" % (age / 86400)

func online_count() -> int:
	var total := 0
	for entry in friend_rows:
		if typeof(entry) == TYPE_DICTIONARY and is_online(str((entry as Dictionary).get("last_seen", ""))):
			total += 1
	return total

# Unread numbers only; the shell owns where they come from.
func unread_total() -> int:
	var total := 0
	for value in unread_by_friend.values():
		total += int(value)
	return total

func friend_unread(uid: String) -> int:
	return int(unread_by_friend.get(uid, 0))

# Cyan count badge, same accent as the primary action, dark text on top so it
# stays readable at 16 px. Width follows the digits; "99+" caps the display.
func count_badge(center: Vector2, count: int) -> void:
	if count <= 0:
		return
	var label := str(count) if count < 100 else "99+"
	var text_w: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_CAPTION).x
	var w: float = maxf(20.0, text_w + 12.0)
	var r := Rect2(center.x - w * 0.5, center.y - 10.0, w, 20.0)
	panel(r, CYAN, Color.TRANSPARENT, 10)
	txt(label, r.position.x, r.position.y + 14, w, FONT_CAPTION, BG, HORIZONTAL_ALIGNMENT_CENTER)

func bar(r: Rect2, ratio: float, color: Color = CYAN) -> void:
	draw_rect(r, LINE, true)
	if ratio > 0.0:
		draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(ratio, 0.0, 1.0), r.size.y)), color, true)

func button(value: String, r: Rect2, primary: bool = false) -> void:
	panel(r, BUBBLE_SELF if primary else SURFACE)
	txt(value, r.position.x + 8, r.position.y + r.size.y * 0.5 + 7, r.size.x - 16, FONT_SECONDARY, INK, HORIZONTAL_ALIGNMENT_CENTER)

func chip(value: String, r: Rect2, color: Color = CYAN) -> void:
	txt(value, r.position.x + 2, r.position.y + r.size.y * 0.5 + 6, r.size.x - 4, FONT_CAPTION, color, HORIZONTAL_ALIGNMENT_CENTER)

func _background() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG, true)

func _header(title: String, subtitle: String = "") -> void:
	txt(title, PAGE_GUTTER, 112, 500, FONT_TITLE)
	if not subtitle.is_empty():
		txt(subtitle, PAGE_GUTTER, 149, 500, FONT_SECONDARY, MUTED)
	draw_line(Vector2(PAGE_GUTTER, 160), Vector2(520, 160), LINE, 1.0)

func _nav_icon(c: Vector2, kind: int, color: Color, stroke: float) -> void:
	match kind:
		0:
			draw_rect(Rect2(c.x - 11, c.y - 10, 22, 20), color, false, stroke)
			draw_line(Vector2(c.x - 3, c.y - 10), Vector2(c.x - 3, c.y + 10), color, stroke)
			draw_line(Vector2(c.x - 11, c.y - 2), Vector2(c.x + 11, c.y - 2), color, stroke)
		1:
			var path := PackedVector2Array([
				c + Vector2(0, 10), c + Vector2(-10, 0), c + Vector2(-10, -5),
				c + Vector2(-6, -10), c + Vector2(-2, -10), c,
				c + Vector2(2, -10), c + Vector2(6, -10), c + Vector2(10, -5),
				c + Vector2(10, 0), c + Vector2(0, 10)
			])
			draw_polyline(path, color, stroke, true)
		2:
			draw_arc(c + Vector2(0, -5), 5, 0, TAU, 24, color, stroke)
			draw_arc(c + Vector2(0, 17), 12, PI, TAU, 24, color, stroke)

func _nav(selected: int) -> void:
	draw_rect(Rect2(0, NAV_Y, 540, NAV_H), BG, true)
	draw_line(Vector2(0, NAV_Y), Vector2(540, NAV_Y), LINE, 1.0)
	var names := ["房间", "好友", "资料"]
	for i in range(3):
		var x: float = NAV_SLOT_W * (float(i) + 0.5)
		var col: Color = CYAN if i == selected else MUTED
		_nav_icon(Vector2(x, 882), i, col, 2.0 if i == selected else 1.5)
		txt(names[i], x - 52, 929, 104, FONT_SECONDARY, col, HORIZONTAL_ALIGNMENT_CENTER)
	# The badge rides on the friends slot even while that tab is open: opening the
	# list keeps the hint, only rendering a conversation clears it.
	var unread := unread_total()
	if unread > 0:
		count_badge(Vector2(NAV_SLOT_W * 1.5 + 15.0, 869.0), unread)

func _first_profile() -> void:
	_header("编辑个人资料" if page == "edit_profile" else "创建个人资料", "头像与昵称会显示在房间和对局中")
	# Editing needs a way back without saving; creating a profile is a first-run flow.
	if page == "edit_profile":
		txt("取消", 400, 112, 120, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	avatar(0, Vector2(270, 267), 60, AVATAR_A)
	button("选择并裁剪头像", Rect2(171, 345, 198, 39))
	txt("昵称", 76, 425, 100, FONT_SECONDARY, MUTED)
	# The value itself is typed into a transparent LineEdit on top; drawing it here
	# would render a second, slightly offset copy (ghosting).
	draw_line(Vector2(76, 507), Vector2(464, 507), LINE, 1.0)
	txt("个性签名", 76, 528, 200, FONT_SECONDARY, MUTED)
	draw_line(Vector2(76, 609), Vector2(464, 609), LINE, 1.0)
	txt("ID 将由账号系统分配", 76, 648, 388, FONT_CAPTION, MUTED)
	button("保存并前往邀请房间" if page == "first_profile_invite" else ("保存资料" if page == "edit_profile" else "进入游戏大厅"), Rect2(76, 688, 388, 48), true)
	if page == "first_profile_invite":
		txt("邀请链接已保留，保存后进入房间", 20, 805, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)

func _lobby() -> void:
	_header("房间", "和朋友开一局，或加入等待中的房间")
	txt("私人房间", 20, 210, 300, FONT_BODY)
	txt("分享房间号或邀请链接", 20, 243, 500, FONT_SECONDARY, MUTED)
	button("单人模式", Rect2(20, 257, 156, 53))
	button("创建房间", Rect2(192, 257, 156, 53), true)
	button("输入房间号", Rect2(364, 257, 156, 53))
	txt("邀请链接也可直接加入", 20, 350, 500, FONT_CAPTION, MUTED)
	# 实时房间列表：只展示"已开桌"的房间。判据是网关给的 open 标记
	# （有人连上，或刚被房主 claim）。预热备胎 open=false，永远不会出现在大厅。
	txt("房间列表", 20, 396, 300, FONT_SECONDARY, MUTED)
	var visible_rooms: Array = []
	for candidate in room_list:
		if bool(candidate.get("open", false)) or int(candidate.get("players", 0)) > 0:
			visible_rooms.append(candidate)
	txt("%d 桌有人" % visible_rooms.size(), 340, 396, 180, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_line(Vector2(20, 412), Vector2(520, 412), LINE, 1.0)
	if visible_rooms.is_empty():
		# 请求失败和"真没人开桌"显示成同一句话的话，排查时分不清是网关坏了还是没人建房。
		var empty_text: String = room_list_error if not room_list_error.is_empty() else "还没有人开桌 · 点上方创建房间"
		txt(empty_text, 20, 470, 500, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		for i in range(visible_rooms.size()):
			var room: Dictionary = visible_rooms[i]
			var row_y: float = 420.0 + float(i) * 96.0 - lobby_scroll
			# 可视区 420..848：整行在区外的直接跳过，别画到底栏下面
			if row_y > 856.0 or row_y + 96.0 < 412.0:
				continue
			var host_text := str(room.get("host", ""))
			var status := lobby_room_status(room)
			txt(str(room.get("code", "")), 20, row_y + 40, 180, FONT_BODY, INK)
			txt(_waiting_room_fit(host_text if not host_text.is_empty() else "有人", 136, FONT_CAPTION),
				200, row_y + 38, 136, FONT_CAPTION, MUTED)
			var status_color: Color = MUTED if str(room.get("phase", "waiting")) == "playing" else CYAN
			txt(status, 340, row_y + 38, 180, FONT_CAPTION, status_color, HORIZONTAL_ALIGNMENT_RIGHT)
			# 房间号正下方的一行小字：房主介绍；没写就明说，别用假内容占位。
			var intro := str(room.get("intro", "")).strip_edges()
			if intro.is_empty():
				intro = "对局进行中，可进入观战" if str(room.get("phase", "waiting")) == "playing" else "房主还没有写介绍"
			txt(_waiting_room_fit(intro, 500, FONT_CAPTION), 20, row_y + 74, 500, FONT_CAPTION, WEAK)
			draw_line(Vector2(20, row_y + 88), Vector2(520, row_y + 88), LINE, 1.0)
		_draw_lobby_scrollbar(visible_rooms.size())
	_nav(0)

# Lobby row status: mode + what a tap will do. Seat counts come from the host's
# authoritative meta (spectators are not seats), so this never shows a fake "3/4".
func lobby_room_status(room: Dictionary) -> String:
	var mode := int(room.get("mode", 0))
	var capacity := 2 if mode == 0 else 4
	var seats := int(room.get("seats", room.get("players", 0)))
	var mode_text := "双人" if mode == 0 else "四人"
	if str(room.get("phase", "waiting")) == "playing":
		return mode_text + " · 对局中"
	if seats >= capacity:
		return mode_text + " · 可观战"
	return mode_text + " · 可入座"

# 列表右侧的细滚动条：只做"还有更多"的提示，不能拖。
# 没有它的话，一屏正好只显示 4 行时，玩家根本不知道下面还有。
func _draw_lobby_scrollbar(count: int) -> void:
	var total := float(count) * 96.0
	var view := 428.0
	if total <= view + 1.0: return
	var thumb_h := maxf(36.0, view * view / total)
	var max_scroll := maxf(1.0, total - view + 12.0)
	var ratio := clampf(lobby_scroll / max_scroll, 0.0, 1.0)
	var thumb_y := 420.0 + (view - thumb_h) * ratio
	draw_rect(Rect2(526.0, 420.0, 2.0, view), Color(0.11, 0.11, 0.13, 0.9), true)
	draw_rect(Rect2(526.0, thumb_y, 2.0, thumb_h), Color(0.55, 0.55, 0.58, 0.8), true)

func _friends() -> void:
	var total := friend_rows.size()
	var subtitle: String = friend_state_text if not friend_state_text.is_empty() else "云端好友"
	if not friend_failed and total > 0:
		subtitle += " · %d 在线" % online_count()
	_header("好友", subtitle)
	# 放大镜用绘制而不是字符：game_zh.ttf 没有 U+2315（⌕），Web 端会显示成方块。
	draw_arc(Vector2(34, 200), 8.0, 0.0, TAU, 24, MUTED, 2.0)
	draw_line(Vector2(40, 206), Vector2(47, 213), MUTED, 2.0)
	txt("搜索玩家昵称", 60, 210, 440, FONT_BODY, MUTED)
	draw_line(Vector2(20, 222), Vector2(520, 222), LINE, 1.0)
	txt("好友申请", 20, 263, 240, FONT_BODY)
	txt("%d 待处理 >" % friend_pending_count if friend_pending_count > 0 else "查看 >", 346, 262, 174, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_line(Vector2(20, 275), Vector2(520, 275), LINE, 1.0)
	var shown := mini(total, 6) if not friend_failed else 0
	for i in range(shown):
		var y: float = 286.0 + i * 88.0
		var entry: Dictionary = friend_rows[i]
		var uname := str(entry.get("username", "未知玩家"))
		var uid := str(entry.get("id", ""))
		var tint := friend_tint(uid)
		var portrait: Texture2D = friend_portraits.get(uid) if friend_portraits.has(uid) else null
		if portrait != null:
			avatar(-1, Vector2(48, y + 43), 28, tint, portrait)
		else:
			initial_avatar(uname, Vector2(48, y + 43), 28, tint)
		txt(uname, 92, y + 37, 286, FONT_BODY)
		var online := is_online(str(entry.get("last_seen", "")))
		var unread := friend_unread(uid)
		draw_circle(Vector2(98, y + 61), 3.0, CYAN if online else WEAK)
		txt(presence_text(str(entry.get("last_seen", ""))), 110, y + 67, 250, FONT_SECONDARY, MUTED)
		# Unread friends are marked where the chat entry is, so the row still reads
		# as a list and the count sits on the action it belongs to.
		txt("聊天 >", 402, y + 52, 118, FONT_SECONDARY, CYAN if unread > 0 else MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
		if unread > 0:
			count_badge(Vector2(500, y + 24), unread)
		draw_line(Vector2(92, y + 87), Vector2(520, y + 87), LINE, 1.0)
	if friend_failed:
		txt("好友列表暂时读不到", 20, 376, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt("检查网络后重试", 20, 410, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	elif total == 0:
		txt("还没有好友", 20, 376, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt("搜索玩家昵称，发送好友申请", 20, 410, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	if total > shown and not friend_failed:
		txt("还有 %d 位好友未显示" % (total - shown), 20, 827, 500, FONT_CAPTION, WEAK)
	_nav(1)

# Bubble lines are measured with the actual font at the final display size.
const BUBBLE_W := 344.0
const BUBBLE_PAD := 16.0
const BUBBLE_FONT := FONT_BODY
const BUBBLE_MAX_LINES := 8
const BUBBLE_LINE_H := 38.0
# 每条消息上方单独一行发送时间；这段高度必须计入布局，否则邀请气泡的
# 点击矩形会比画面高出一行，滚动后点不中。
const TIME_LINE_H := 30.0
const INVITE_CARD_H := 136.0
const INVITE_CHIP_W := 176.0
const INVITE_CHIP_H := 40.0

func _bubble_text_and_height(body: String) -> Dictionary:
	var usable: float = BUBBLE_W - BUBBLE_PAD * 2.0
	var lines: Array[String] = []
	var current := ""
	var truncated := false
	for ch in body:
		if ch == "\n":
			lines.append(current)
			current = ""
			if lines.size() >= BUBBLE_MAX_LINES:
				truncated = true
				break
			continue
		var candidate := current + ch
		if not current.is_empty() and font.get_string_size(candidate, HORIZONTAL_ALIGNMENT_LEFT, -1, BUBBLE_FONT).x > usable:
			lines.append(current)
			current = ch
			if lines.size() >= BUBBLE_MAX_LINES:
				truncated = true
				break
		else:
			current = candidate
	if not truncated:
		lines.append(current)
	if lines.is_empty():
		lines.append("")
	if truncated:
		var last: int = BUBBLE_MAX_LINES - 1
		var clipped: String = lines[last]
		while not clipped.is_empty() and font.get_string_size(clipped + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, BUBBLE_FONT).x > usable:
			clipped = clipped.substr(0, clipped.length() - 1)
		lines[last] = clipped + "…"
	return {"lines": lines, "h": 32.0 + float(lines.size()) * BUBBLE_LINE_H}

# Room code out of any message body that carries "room=CODE". Historical invites
# are the long "...?invite=...&room=..." links, so parsing the code (instead of
# matching one exact string) keeps old conversations tappable.
func _chat_invite_code(body: String) -> String:
	var idx := body.find("room=")
	if idx < 0:
		return ""
	var code := ""
	for i in range(idx + 5, body.length()):
		var ch := body.substr(i, 1)
		if ch == "&" or ch == " " or ch == "\n" or ch == "#" or ch == "\"":
			break
		code += ch
	code = code.strip_edges()
	if code.length() < 4 or code.length() > 8:
		return ""
	for ch in code:
		if not "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(ch):
			return ""
	return code.to_upper()

# Supabase stores created_at in UTC (RFC3339). Show the sender's actual local
# time, never "now": the row's own timestamp is the only truthful source.
func _chat_time_text(created_at: String) -> String:
	var raw := created_at.strip_edges()
	if raw.length() < 19:
		return ""
	# Keep exactly YYYY-MM-DDTHH:MM:SS; Godot's parser rejects fractions/offset.
	var unix := Time.get_unix_time_from_datetime_string(raw.substr(0, 19))
	if unix <= 0:
		return ""
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var local := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	var now := Time.get_datetime_dict_from_system()
	var hm := "%02d:%02d" % [int(local.hour), int(local.minute)]
	if int(local.year) != int(now.year):
		return "%04d-%02d-%02d %s" % [int(local.year), int(local.month), int(local.day), hm]
	if int(local.month) != int(now.month) or int(local.day) != int(now.day):
		return "%02d-%02d %s" % [int(local.month), int(local.day), hm]
	return hm

func _chat_state_text() -> String:
	match chat_state:
		"ready":
			return "云端私聊 · 每 3 秒刷新"
		"failed":
			return "读取失败：%s" % chat_last_error
	return "正在加载消息…"

const CHAT_IMAGE_PREFIX := "[[img:"

# 消息体里的图片标记：[[img:宽x高]]https://...
# 带上宽高是为了让对方不用先下载就知道该留多大的格子。
func chat_image_info(body: String) -> Dictionary:
	if not body.begins_with(CHAT_IMAGE_PREFIX):
		return {}
	var close := body.find("]]")
	if close < 0:
		return {}
	var spec := body.substr(CHAT_IMAGE_PREFIX.length(), close - CHAT_IMAGE_PREFIX.length())
	var parts := spec.split("x")
	if parts.size() != 2:
		return {}
	var width := parts[0].to_float()
	var height := parts[1].to_float()
	var url := body.substr(close + 2)
	if url.is_empty() or width <= 0.0 or height <= 0.0:
		return {}
	return {"w": width, "h": height, "url": url}


func _chat() -> void:
	txt("<", 20, 111, 38, FONT_TITLE, MUTED)
	if active_friend_portrait != null:
		avatar(-1, Vector2(94, 100), 24, friend_tint(active_friend_name), active_friend_portrait)
	else:
		initial_avatar(active_friend_name, Vector2(94, 100), 24, friend_tint(active_friend_name))
	txt(active_friend_name, 132, 98, 380, FONT_BODY)
	txt(_chat_state_text(), 132, 132, 380, FONT_SECONDARY, MUTED)
	draw_line(Vector2(20, 160), Vector2(520, 160), LINE, 1.0)
	# Draw newest messages at the input, preserving source order and sender side.
	chat_message_rects.clear()
	chat_message_rects.resize(chat_messages.size())
	chat_text_tiles_out.clear()
	chat_image_tiles_out.clear()
	var web_text: bool = OS.has_feature("web")
	var items: Array[Dictionary] = []
	for entry in chat_messages:
		var row: Dictionary = entry
		var body := str(row.get("body", ""))
		var mine := str(row.get("from_user", "")) == chat_self_id
		var time_text := _chat_time_text(str(row.get("created_at", "")))
		var time_h := TIME_LINE_H if not time_text.is_empty() else 0.0
		var invite_code := _chat_invite_code(body)
		if not invite_code.is_empty():
			# 邀请消息不再铺一整段原始链接：房号 + 一个明确的进房操作。
			items.append({
				"h": INVITE_CARD_H,
				"mine": mine,
				"invite": invite_code,
				"time": time_text,
				"time_h": time_h,
			})
			continue
		var image_info := chat_image_info(body)
		if not image_info.is_empty():
			# 图片消息：按原始宽高比缩放，最高 200、最宽不超过气泡
			var aspect := float(image_info.w) / maxf(float(image_info.h), 1.0)
			var box := Vector2(220.0, 220.0 / aspect)
			if box.y > 200.0:
				box.y = 200.0
				box.x = box.y * aspect
			if box.x > BUBBLE_W - BUBBLE_PAD * 2.0:
				box.x = BUBBLE_W - BUBBLE_PAD * 2.0
				box.y = box.x / maxf(aspect, 0.01)
			items.append({
				"lines": [],
				"h": box.y + 32.0,
				"mine": mine,
				"image": image_info,
				"box": box,
				"time": time_text,
				"time_h": time_h,
			})
			continue
		var layout := _bubble_text_and_height(body)
		items.append({
			"lines": layout["lines"],
			"h": float(layout["h"]),
			"mine": mine,
			"time": time_text,
			"time_h": time_h,
		})
	# 先算总高：每条消息上方的时间行也要算进去，滚动上限才会准
	var total_h := 0.0
	for i in range(items.size()):
		total_h += float(items[i]["time_h"]) + float(items[i]["h"])
		if i > 0:
			total_h += 8.0 if bool(items[i]["mine"]) == bool(items[i - 1]["mine"]) else 24.0
	chat_scroll_max = maxf(0.0, total_h - (CHAT_LIST_BOTTOM - CHAT_LIST_TOP))
	chat_scroll = clampf(chat_scroll, 0.0, chat_scroll_max)
	var clip := Rect2(0.0, CHAT_LIST_TOP, 540.0, CHAT_LIST_BOTTOM - CHAT_LIST_TOP)
	var y := CHAT_LIST_BOTTOM + chat_scroll
	var drawn := 0
	for i in range(items.size() - 1, -1, -1):
		var item: Dictionary = items[i]
		var h: float = item["h"]
		var time_h: float = item["time_h"]
		y -= time_h + h
		var bubble_y := y + time_h
		if bubble_y + h < CHAT_LIST_TOP:
			break
		var mine: bool = item["mine"]
		# 左右各留 44px 给头像：好友的头像在左，自己的在右
		var r := Rect2(476.0 - BUBBLE_W if mine else 64.0, bubble_y, BUBBLE_W, h)
		var bubble_clip := r.intersection(clip)
		# 发送时间单独一行，贴着自己那条气泡；用消息自带的 created_at（本地时区），
		# 不是渲染时刻。它随 y 一起滚动，点击矩形只取气泡本身。
		if time_h > 0.0:
			var time_y := y + 20.0
			if time_y >= CHAT_LIST_TOP + 2.0 and time_y <= CHAT_LIST_BOTTOM:
				txt(str(item["time"]), r.position.x, time_y, BUBBLE_W, FONT_CAPTION, WEAK,
					HORIZONTAL_ALIGNMENT_RIGHT if mine else HORIZONTAL_ALIGNMENT_LEFT)
		var avatar_center := Vector2(502.0 if mine else 38.0, bubble_y + 18.0)
		if avatar_center.y + 18.0 > CHAT_LIST_TOP and avatar_center.y - 18.0 < CHAT_LIST_BOTTOM:
			if mine:
				# 自己的头像用本机预置图；好友的头像只可能是下载来的贴图或首字母
				avatar(0, avatar_center, 18.0, AVATAR_A)
			elif active_friend_portrait != null:
				avatar(-1, avatar_center, 18.0, friend_tint(active_friend_name), active_friend_portrait)
			else:
				initial_avatar(active_friend_name, avatar_center, 18.0, friend_tint(active_friend_name))
		var next_gap := 8.0 if i > 0 and bool(items[i - 1]["mine"]) == mine else 24.0
		if bubble_clip.size.y < 2.0:
			y -= next_gap
			continue
		# 点击矩形取裁切后的可见部分：气泡被列表边缘切掉时，按钮不会伸到
		# 输入框/发送键上把正常触摸吞掉；滚动多少，命中区就跟着走多少。
		chat_message_rects[i] = bubble_clip
		# 用裁切后的矩形画面板：滚动时气泡不会盖住下面的分隔线和输入框
		panel(bubble_clip, BUBBLE_SELF if mine else SURFACE)
		var invite_code := str(item.get("invite", ""))
		if not invite_code.is_empty():
			# 邀请卡带一圈青色边，和普通消息区分开；裁切时只画填充，避免边框随裁切线走。
			if r.position.y >= CHAT_LIST_TOP and r.end.y <= CHAT_LIST_BOTTOM:
				panel(r, Color.TRANSPARENT, Color(CYAN.r, CYAN.g, CYAN.b, 0.45))
			var title_y := r.position.y + 30.0
			if title_y >= CHAT_LIST_TOP + 2.0 and title_y <= CHAT_LIST_BOTTOM:
				txt("房间邀请", r.position.x + BUBBLE_PAD, title_y, BUBBLE_W - BUBBLE_PAD * 2.0, FONT_SECONDARY, MUTED)
			var code_y := r.position.y + 66.0
			if code_y >= CHAT_LIST_TOP + 2.0 and code_y <= CHAT_LIST_BOTTOM:
				txt("房间号 " + invite_code, r.position.x + BUBBLE_PAD, code_y, BUBBLE_W - BUBBLE_PAD * 2.0, FONT_BODY, INK)
			var chip := Rect2(r.position.x + BUBBLE_PAD, r.position.y + 82.0, INVITE_CHIP_W, INVITE_CHIP_H)
			if chip.position.y >= CHAT_LIST_TOP + 2.0 and chip.end.y <= CHAT_LIST_BOTTOM:
				panel(chip, CYAN)
				txt("进入房间", chip.position.x, chip.position.y + 27.0, chip.size.x, FONT_SECONDARY, BG, HORIZONTAL_ALIGNMENT_CENTER)
			drawn += 1
			y -= next_gap
			continue
		var image_info: Dictionary = item.get("image", {})
		if not image_info.is_empty():
			var box: Vector2 = item["box"]
			var img_rect := Rect2(r.position.x + BUBBLE_PAD, r.position.y + 16.0, box.x, box.y)
			if img_rect.intersection(clip).size.y >= 4.0:
				chat_image_tiles_out.append({
					"id": str(image_info.url),
					"url": str(image_info.url),
					"left": img_rect.position.x,
					"top": img_rect.position.y,
					"width": img_rect.size.x,
					"height": img_rect.size.y,
				})
			if not web_text:
				# 桌面版不下载私聊图片（那条链路走浏览器 <img>），这里只留一个占位框
				panel(img_rect, Color(0.08, 0.08, 0.10), LINE, 8)
				txt("[图片]", img_rect.position.x, img_rect.position.y + img_rect.size.y * 0.5 + 7.0,
					img_rect.size.x, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
			# 图片气泡也要推进间距和计数，否则下一条会压在它身上
			drawn += 1
			y -= next_gap
			continue
		var lines: Array = item["lines"]
		for line_index in range(lines.size()):
			var line_x: float = r.position.x + BUBBLE_PAD
			var line_y: float = r.position.y + 36.0 + float(line_index) * BUBBLE_LINE_H
			var line_w: float = BUBBLE_W - BUBBLE_PAD * 2.0
			if line_y < CHAT_LIST_TOP + 2.0 or line_y - float(BUBBLE_FONT) > CHAT_LIST_BOTTOM:
				continue
			if web_text:
				# DOM 标签的 top 是行盒顶，这里从基线倒推，让浏览器里的文字和气泡对齐
				chat_text_tiles_out.append({
					"text": str(lines[line_index]),
					"left": line_x,
					"top": line_y - float(BUBBLE_FONT) * 0.95,
					"width": line_w,
					"font_size": BUBBLE_FONT,
					"line_height": BUBBLE_FONT + 6,
				})
			else:
				txt(str(lines[line_index]), line_x, line_y, line_w, BUBBLE_FONT)
		drawn += 1
		y -= next_gap
	if chat_messages.is_empty():
		if chat_state == "failed":
			txt("消息读不到", 20, 360, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
			txt("检查网络后返回再进来一次", 20, 397, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		elif chat_state == "loading":
			txt("正在加载消息…", 20, 360, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		else:
			txt("还没有消息", 20, 360, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
			txt("发一条消息，开始聊天", 20, 397, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	elif chat_scroll_max > 0.0 and chat_scroll <= 0.5:
		# 还有更早的消息没进视野：给一句提示，别让人以为上面就是全部
		txt("往上滑看更早的消息（共 %d 条）" % chat_messages.size(), 20, 154, 500, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	draw_line(Vector2(0, 736), Vector2(540, 736), LINE, 1.0)
	# No placeholder text here: the LineEdit above draws its own, and drawing both
	# would stack two copies on top of whatever the user typed.
	panel(Rect2(448, 766, 72, 56), CYAN)
	txt("发送", 448, 802, 72, FONT_SECONDARY, BG, HORIZONTAL_ALIGNMENT_CENTER)
	_nav(1)

func _profile() -> void:
	_header("资料", "头像、昵称与等级")
	avatar(0, Vector2(99, 225), 44, AVATAR_A)
	txt(display_name, 164, 213, 330, FONT_BODY)
	txt(signature, 164, 246, 330, FONT_SECONDARY, MUTED)
	# Real account id, not a decorative placeholder: the old hard-coded
	# "ID 6F82-AX93" was pure fiction and identical for every account.
	txt("ID " + (account_uid_short if not account_uid_short.is_empty() else "未登录"), 164, 276, 230, FONT_CAPTION, WEAK)
	txt("星尘旅者", 392, 276, 105, FONT_CAPTION, GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	# 这一行原来显示"建议设置昵称"，昵称一旦有了它就是废话。
	# 改成展示本账号的注册邮箱（只有自己看得到自己的资料页）。
	if not account_email.is_empty():
		txt(account_email if account_email.length() <= 32 else account_email.left(30) + "…", 164, 306, 340, FONT_CAPTION, WEAK)
	txt("LV %d" % my_level, 20, 350, 200, FONT_BODY, GOLD)
	draw_line(Vector2(20, 385), Vector2(520, 385), LINE, 1.0)
	# Account entry: opens the auth page; label reflects sign-in state.
	var account_label := "已登录 · " + auth_identity if auth_signed_in else "账号登录 / 注册"
	txt(account_label, 20, 428, 460, FONT_SECONDARY, MUTED)
	txt(">", 480, 428, 32, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	draw_line(Vector2(20, 444), Vector2(520, 444), LINE, 1.0)
	# Password is Auth-only; the row exists only while signed in.
	if auth_signed_in:
		txt("修改密码", 20, 486, 460, FONT_SECONDARY, MUTED)
		txt(">", 480, 486, 32, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
		draw_line(Vector2(20, 502), Vector2(520, 502), LINE, 1.0)
	if not profile_sync_text.is_empty():
		txt(profile_sync_text, 20, 532, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	if not realtime_text.is_empty():
		txt(realtime_text, 20, 556, 500, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	_nav(2)


# Read-only card for another player: avatar, name, level, signature. Nothing else.
func _player_profile() -> void:
	txt("<", 20, 111, 38, FONT_TITLE, MUTED)
	draw_line(Vector2(20, 160), Vector2(520, 160), LINE, 1.0)
	if view_player_state == "failed":
		txt("看不到这位玩家的资料", 20, 420, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt(view_player_error, 20, 460, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	if view_player_state != "ready":
		txt("正在加载资料…", 20, 420, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	if view_player_portrait != null:
		avatar(-1, Vector2(270, 268), 72, AVATAR_A, view_player_portrait)
	else:
		initial_avatar(view_player_name, Vector2(270, 268), 72, friend_tint(view_player_name))
	txt(view_player_name, 20, 404, 500, FONT_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER)
	txt("LV %d" % view_player_level, 20, 448, 500, FONT_SECONDARY, GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	var sig := view_player_signature.strip_edges()
	txt(sig if not sig.is_empty() else "这位玩家还没有写签名", 60, 512, 420, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	# Relation button, one of three real states. "requested" is deliberately a
	# plain line instead of a dead button.
	var relation_label := "加好友"
	var relation_color := CYAN
	if view_player_relation == "friend":
		relation_label = "删除好友"
		relation_color = MUTED
	elif view_player_relation == "requested":
		relation_label = "已发出申请，等待对方确认"
		relation_color = MUTED
	elif view_player_relation == "incoming":
		relation_label = "接受好友申请"
		relation_color = CYAN
	panel(Rect2(20, 620, 500, 66), SURFACE, Color.TRANSPARENT, 10)
	txt(relation_label, 28, 662, 484, FONT_BODY, relation_color, HORIZONTAL_ALIGNMENT_CENTER)

func _level_up() -> void:
	_profile()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.82), true)
	panel(Rect2(68, 272, 404, 385), SURFACE)
	txt("等级提升", 106, 363, 328, FONT_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER)
	txt("LV 9", 106, 450, 328, FONT_TITLE, GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	txt("解锁称号：月环行者", 106, 548, 328, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	button("收下奖励", Rect2(123, 593, 294, 43), true)

func _badges() -> void:
	_header("徽章与称号", "纯外观收藏")
	for i in range(6):
		var x: float = 20.0 + float(i % 2) * 250.0
		var y: float = 169.0 + float(i / 2) * 190.0
		txt("LV %d" % [1, 5, 9, 15, 20, 30][i], x, y + 58, 230, FONT_BODY, GOLD, HORIZONTAL_ALIGNMENT_CENTER)
		txt(["初访星海", "星尘旅者", "月环行者", "星云巡游", "银河领航", "群星见证"][i], x, y + 108, 230, FONT_SECONDARY, INK, HORIZONTAL_ALIGNMENT_CENTER)
		draw_line(Vector2(x, y + 172), Vector2(x + 230, y + 172), LINE, 1.0)
	txt("解锁后可在个人资料中选择展示", 20, 810, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_nav(2)

# Pure derivations from preview fields only; no drawing, safe to unit-test.
# Seats are fixed by the board: 0/1 blue, 2/3 red. Duo only opens 0 and 2.
func seat_slots() -> Array:
	return [0, 2] if match_mode == 0 else [0, 1, 2, 3]


func seat_slot_for_row(row: int) -> int:
	var slots := seat_slots()
	if row < 0 or row >= slots.size():
		return -1
	return int(slots[row])


func seat_row_for_slot(slot: int) -> int:
	return seat_slots().find(slot)


func seat_name(slot: int) -> String:
	# A full-size array is authoritative (online rooms always send four entries).
	# Only the legacy local-hotseat view falls back to the blue/red defaults.
	if room_slot_names.size() >= 4:
		return room_slot_names[slot] if slot >= 0 and slot < 4 else ""
	if room_is_solo:
		return display_name if slot == 0 else ""
	return room_blue_name if slot < 2 else room_red_name


func _seat_state(slot_index: int, _side: int) -> int:
	if seat_name(slot_index).is_empty():
		return SeatState.EMPTY
	if room_reconnecting:
		return SeatState.RECONNECTING
	var ready := false
	if slot_index >= 0 and slot_index < room_slot_ready.size():
		ready = bool(room_slot_ready[slot_index])
	return SeatState.READY if ready else SeatState.WAITING


# Occupied-and-ready seats of the current mode. Single source for both the row
# badges and the bottom-bar count.
func ready_seat_count() -> int:
	var count := 0
	for slot in seat_slots():
		if seat_name(slot).is_empty():
			continue
		if _seat_state(slot, 0 if slot < 2 else 1) == SeatState.READY:
			count += 1
	return count


func seated_count() -> int:
	var count := 0
	for slot in seat_slots():
		if not seat_name(slot).is_empty():
			count += 1
	return count


func _start_button_label(ready_count: int, slots: int, local_ready: bool) -> String:
	if room_is_solo:
		return "开始对局" if local_ready else "准备并开始单机对局"
	# 全员就绪时服务端已经在开局，这里不能再给出一个"开始对局"的按钮。
	if slots > 0 and ready_count >= slots:
		return "正在开局…"
	if local_ready:
		return "取消准备"
	return "准备"


func _ready_count_label(ready_count: int, slots: int) -> String:
	return "%d/%d 已准备" % [ready_count, slots]


func _team_color(slot: int) -> Color:
	return BLUE_TEAM if slot < 2 else RED_TEAM


func _team_label(slot: int) -> String:
	return "蓝队" if slot < 2 else "红队"


func _waiting_room() -> void:
	var room_code: String = room_label.get_slice("#", 1) if room_label.contains("#") else room_label
	var leave_rect := Rect2(416, 24, 104, 88)
	var mode_duel_rect := Rect2(20, 256, 245, 88)
	var mode_squad_rect := Rect2(275, 256, 245, 88)
	txt("单机测试" if room_is_solo else "等待房间", PAGE_GUTTER, 52, 380, FONT_SECONDARY, MUTED)
	var heading: String = "单机测试" if room_is_solo else _waiting_room_fit("#" + room_code, 374, FONT_TITLE)
	txt(heading, PAGE_GUTTER, 108, 374, FONT_TITLE, INK)
	txt("离开", leave_rect.position.x, 79, leave_rect.size.x, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	var slots := 2 if match_mode == 0 else 4
	if not room_is_solo:
		# 房间介绍：房主写的一句话，大厅房间条也会显示（超宽截断）。
		var intro_text := room_intro.strip_edges()
		if intro_text.is_empty():
			intro_text = "写一句介绍，大厅里能看到" if room_is_host else "房主还没有写介绍"
		var intro_width: float = 396.0 if room_is_host else 500.0
		var intro_color: Color = MUTED if not room_intro.strip_edges().is_empty() else WEAK
		txt(_waiting_room_fit(intro_text, intro_width, FONT_CAPTION), PAGE_GUTTER, 142, intro_width, FONT_CAPTION, intro_color)
		if room_is_host:
			txt("编辑", 436, 142, 84, FONT_CAPTION, CYAN, HORIZONTAL_ALIGNMENT_RIGHT)
	if room_is_solo:
		txt("不连接服务器 · 不影响在线玩家", 20, 206, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		# 观战席固定在左、邀请在右，两框等宽对齐；观战席不再做卷帘。
		panel(INVITE_RECT, SURFACE, LINE, RADIUS)
		txt("邀请好友", INVITE_RECT.position.x, 216, INVITE_RECT.size.x, FONT_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER)
	if room_is_solo:
		txt("双人热座 · 你同时操控两边", 20, 300, 500, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt("点下方按钮直接开局", 20, 330, 500, FONT_SECONDARY, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		var mode_rects := [mode_duel_rect, mode_squad_rect]
		for mode_index in range(2):
			var mode_rect: Rect2 = mode_rects[mode_index]
			var selected: bool = match_mode == mode_index
			var mode_color: Color = CYAN if selected else (MUTED if room_is_host else WEAK)
			txt("双人模式" if mode_index == 0 else "四人模式", mode_rect.position.x, 300, mode_rect.size.x, FONT_BODY, mode_color, HORIZONTAL_ALIGNMENT_CENTER)
			txt("各控两球" if mode_index == 0 else "各控一球", mode_rect.position.x, 330, mode_rect.size.x, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
			if selected:
				draw_circle(Vector2(mode_rect.get_center().x, 340), 2.0, CYAN)
		if not room_is_host:
			txt("模式与介绍由房主设置", 20, 352, 500, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	# 参赛席：红蓝各一（双人）或各二（四人），与局内球位/血条一一对应。
	for row in range(slots):
		var slot: int = seat_slot_for_row(row)
		var y: float = SEAT_TOP + float(row) * SEAT_H
		var team_color := _team_color(slot)
		draw_rect(Rect2(20, y + 14, 3, SEAT_H - 28), team_color, true)
		var slot_name := seat_name(slot)
		var state: int = SeatState.EMPTY if slot_name.is_empty() else _seat_state(slot, 0 if slot < 2 else 1)
		if state == SeatState.EMPTY:
			_waiting_room_empty_avatar(Vector2(64, y + 44))
			var empty_text := "单人测试 · 无对手" if room_is_solo else "空位 · 点击入座"
			txt(empty_text, 108, y + 52, 236, FONT_BODY, WEAK)
		else:
			var state_text := "等待准备"
			var state_color := MUTED
			if state == SeatState.READY:
				state_text = "已准备"
				state_color = GOLD
			elif state == SeatState.RECONNECTING:
				state_text = "重连中…"
				state_color = MUTED
			var seat_portrait: Texture2D = null
			if slot >= 0 and slot < room_slot_portraits.size():
				seat_portrait = room_slot_portraits[slot]
			if seat_portrait != null:
				# 有真实头像就画真实头像（上传的 PNG 本身是圆形透明底），缺了才回落首字。
				draw_circle(Vector2(64, y + 44), 28.0, friend_tint(slot_name))
				draw_texture_rect(seat_portrait, Rect2(36, y + 16, 56, 56), false)
			else:
				initial_avatar(slot_name, Vector2(64, y + 44), 28.0, friend_tint(slot_name))
			txt(_waiting_room_fit(slot_name, 232, FONT_BODY), 108, y + 39, 232, FONT_BODY, INK)
			txt(state_text, 108, y + 68, 232, FONT_SECONDARY, state_color)
			if local_seat == row:
				txt("你", 344, y + 34, 44, FONT_CAPTION, CYAN, HORIZONTAL_ALIGNMENT_RIGHT)
		txt(_team_label(slot), 396, y + 34, 108, FONT_CAPTION, team_color, HORIZONTAL_ALIGNMENT_RIGHT)
		txt("%d 号位" % ((slot % 2) + 1), 396, y + 56, 108, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_RIGHT)
		draw_line(Vector2(20, y + SEAT_H - 1), Vector2(520, y + SEAT_H - 1), LINE, 1.0)
	if not room_is_solo:
		_waiting_room_spectator_strip()
	if room_is_solo:
		txt("开局后蓝红两边都由你操作", 20, 632, 500, FONT_CAPTION, WEAK, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		_waiting_room_v3_chat()
	var ready_count := ready_seat_count()
	var all_ready: bool = not room_is_solo and ready_count >= slots
	var start_rect := Rect2(20, 860, 500, 88)
	if room_connecting and not room_is_solo:
		# 还没拿到角色：不画准备按钮，也不假装自己是观众。
		panel(start_rect, SURFACE, Color.TRANSPARENT, 10)
		txt("连接房间中…", 36, 915, 468, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	if room_spectator and not room_is_solo:
		# 观众没有可点的主操作：明说"入座要去点空位"，而不是给一个假按钮。
		panel(start_rect, SURFACE, Color.TRANSPARENT, 10)
		txt("%d 人观战 · 可看完整对局" % room_spectators.size(), 36, 892, 468, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt("点上方空位可入座", 36, 926, 468, FONT_BODY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	# 未准备 = 主操作：实心青底。已准备改成次要样式，主操作交给"取消准备"。
	var primary: bool = not room_is_solo and not room_ready and not all_ready
	panel(start_rect, CYAN if primary else SURFACE, Color.TRANSPARENT, 10)
	var start_label := _waiting_room_fit(_start_button_label(ready_count, slots, room_ready), 468, FONT_BODY)
	if room_is_solo:
		txt(start_label, 36, 915, 468, FONT_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER)
	elif room_ready or all_ready:
		# 两行：人数在上、动作在下；"正在开局…"用弱化色，表明不用再点。
		txt(_ready_count_label(ready_count, slots), 36, 890, 468, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		txt(start_label, 36, 926, 468, FONT_BODY, MUTED if all_ready else INK, HORIZONTAL_ALIGNMENT_CENTER)
	else:
		txt(start_label, 36, 915, 468, FONT_BODY, BG, HORIZONTAL_ALIGNMENT_CENTER)


# 观战席：左边是可横滑的观众头像，右边是条内固定不动的空心加号。
# 头像从最左端依次排开，排到分界线才开始滚；只画完整落在头像区里的圆，
# 松手由页面层吸附到整格，边缘不会留下半张脸。
func _waiting_room_spectator_strip() -> void:
	var rect: Rect2 = SPECTATOR_STRIP
	panel(rect, SURFACE, LINE, RADIUS)
	var view: Rect2 = spectator_view_rect()
	var radius: float = SPECTATOR_AVATAR * 0.5
	var count: int = room_spectators.size()
	var max_scroll: float = spectator_max_scroll(count)
	var scroll := clampf(room_spectator_scroll, 0.0, max_scroll)
	var cy: float = rect.position.y + rect.size.y * 0.5
	for index in range(count):
		var entry: Variant = room_spectators[index]
		if not entry is Dictionary:
			continue
		var row: Dictionary = entry
		var cx: float = view.position.x + radius + float(index) * SPECTATOR_STEP - scroll
		if cx - radius < view.position.x - 0.5 or cx + radius > view.end.x + 0.5:
			continue
		var who := str(row.get("name", "观众"))
		var portrait: Texture2D = row.get("portrait")
		var center := Vector2(cx, cy)
		if portrait != null:
			draw_circle(center, radius, friend_tint(who))
			draw_texture_rect(portrait, Rect2(cx - radius, cy - radius, SPECTATOR_AVATAR, SPECTATOR_AVATAR), false)
		else:
			initial_avatar(who, center, radius, friend_tint(who))
		if bool(row.get("me", false)):
			# 自己加一圈青色，滑到别处也认得出。
			draw_arc(center, radius + 2.0, 0.0, TAU, 32, CYAN, 2.0)
	# 分界线：会滚的名单和不动的加号之间留一道发丝线，滑动时两段不会糊在一起。
	var divider_x: float = view.end.x + SPECTATOR_GAP * 0.5
	draw_line(Vector2(divider_x, rect.position.y + 18.0), Vector2(divider_x, rect.end.y - 18.0), LINE, 1.0)
	# 加号位置只由条带几何决定：名单变长变短、滚到哪一格，它都在条内最右端。
	# 连接中不画：热区还没启用，画出来就是一张点了没反应的假按钮。
	if not room_connecting:
		_spectator_plus_slot(spectator_plus_center(), radius)
	if count == 0:
		# 空态：左边一句说明这框是什么，右边加号仍在原位，读起来是"还能加人"。
		var empty_text: String = "连接房间中" if room_connecting else "暂无观众"
		txt(empty_text, view.position.x, cy + 6.0, view.size.x, FONT_CAPTION, WEAK)
	if max_scroll > 0.0:
		var track := Rect2(view.position.x, rect.end.y - 7.0, view.size.x, 2.0)
		draw_rect(track, Color(0.11, 0.11, 0.13, 0.9), true)
		var thumb_w: float = maxf(24.0, track.size.x * (track.size.x / (track.size.x + max_scroll)))
		var thumb_x: float = track.position.x + (track.size.x - thumb_w) * clampf(scroll / max_scroll, 0.0, 1.0)
		draw_rect(Rect2(thumb_x, track.position.y, thumb_w, 2.0), Color(0.55, 0.55, 0.58, 0.8), true)


# 可滚动的头像区（不含右端加号格）。绘制、热区、吸附都读这一份几何，
# 三处不会各自漂移。
static func spectator_view_rect() -> Rect2:
	return Rect2(
		SPECTATOR_STRIP.position.x + SPECTATOR_SIDE_PAD,
		SPECTATOR_STRIP.position.y,
		SPECTATOR_STRIP.size.x - SPECTATOR_PLUS_ZONE - SPECTATOR_SIDE_PAD - SPECTATOR_GAP,
		SPECTATOR_STRIP.size.y)


static func spectator_plus_center() -> Vector2:
	return Vector2(
		SPECTATOR_STRIP.end.x - SPECTATOR_PLUS_ZONE * 0.5,
		SPECTATOR_STRIP.position.y + SPECTATOR_STRIP.size.y * 0.5)


# 观战条的可滚动范围：只有头像会滚，加号固定占住最右 60px。
# 最后一张头像的右边缘贴住分界线时到底。
static func spectator_max_scroll(count: int) -> float:
	var view_w: float = SPECTATOR_STRIP.size.x - SPECTATOR_PLUS_ZONE - SPECTATOR_SIDE_PAD - SPECTATOR_GAP
	var content_w: float = float(count) * SPECTATOR_STEP - (SPECTATOR_STEP - SPECTATOR_AVATAR)
	return maxf(0.0, content_w - view_w)


# 加号格复用玩家空座的虚线圆（同 8 段弧），中心换成加号：
# 一眼看出这一格是"再加一个人"，而不是另一个头像。
func _spectator_plus_slot(center: Vector2, radius: float) -> void:
	for segment in range(8):
		var from_angle: float = float(segment) * TAU / 8.0
		draw_arc(center, radius, from_angle, from_angle + TAU / 16.0, 6, WEAK, 1.2)
	var arm: float = radius * 0.42
	draw_line(center + Vector2(-arm, 0.0), center + Vector2(arm, 0.0), WEAK, 1.8, true)
	draw_line(center + Vector2(0.0, -arm), center + Vector2(0.0, arm), WEAK, 1.8, true)

func _waiting_room_empty_avatar(center: Vector2) -> void:
	for segment in range(8):
		var from_angle: float = float(segment) * TAU / 8.0
		draw_arc(center, 28.0, from_angle, from_angle + TAU / 16.0, 4, WEAK, 1.0)
	draw_circle(center, 3.0, WEAK)

func _waiting_room_fit(value: String, max_width: float, font_size: int) -> String:
	if font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_width:
		return value
	var clipped := value
	while not clipped.is_empty() and font.get_string_size(clipped + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > max_width:
		clipped = clipped.substr(0, clipped.length() - 1)
	return clipped + "…"

func _waiting_room_v3_chat() -> void:
	var input_rect := Rect2(20, 764, 348, 88)
	var send_rect := Rect2(380, 764, 140, 88)
	var rows: Array = get_meta("room_chat_messages", [])
	var visible_count: int = 3 if match_mode == 0 else 1
	if rows.is_empty():
		txt("房间聊天", PAGE_GUTTER, 632 if match_mode == 0 else 736, 500, FONT_SECONDARY, MUTED)
	else:
		if match_mode == 0:
			txt("房间聊天", PAGE_GUTTER, 632, 500, FONT_SECONDARY, MUTED)
		var first: int = maxi(0, rows.size() - visible_count)
		for index in range(first, rows.size()):
			var entry: Variant = rows[index]
			if not entry is Dictionary:
				continue
			var row: Dictionary = entry
			var nickname := str(row.get("nickname", ""))
			var body := str(row.get("body", ""))
			var baseline: float = 736.0 - float(rows.size() - index - 1) * 32.0
			txt(_waiting_room_fit(nickname + "：", 100, FONT_SECONDARY), PAGE_GUTTER, baseline, 100, FONT_SECONDARY, MUTED)
			txt(_waiting_room_fit(body, 392, FONT_BODY), 128, baseline, 392, FONT_BODY, INK)
	draw_line(Vector2(PAGE_GUTTER, 752), Vector2(520, 752), LINE, 1.0)
	txt("说点什么…", input_rect.position.x, 819, input_rect.size.x, FONT_BODY, WEAK)
	txt("发送", send_rect.position.x, 819, send_rect.size.x, FONT_BODY, CYAN, HORIZONTAL_ALIGNMENT_CENTER)

func _result_flow() -> void:
	_header("对局结算", "本局已结束 · 经验仅为设计演示")
	for i in range(4):
		var x: float = 96.0 + i * 116.0
		var result_portrait: Texture2D = result_portraits[i] if i < result_portraits.size() else null
		avatar(i, Vector2(x, 253), 28, friend_tint(str(i)), result_portrait)
		var result_name: String = result_names[i] if i < result_names.size() else (display_name if i == 0 else AVATARS.NAMES[i])
		txt(result_name, x - 48, 307, 96, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	txt(result_winner, 20, 378, 500, FONT_TITLE, GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	txt("完成对局 +20 · 胜利 +10 · 参与 +3", 20, 416, 500, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	bar(Rect2(92, 436, 356, 5), 271.0 / 318.0, GOLD)
	txt("LV 8 · 238 - 271 / 318 XP", 20, 472, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	button("返回等待房间", Rect2(94, 488, 352, 46), true)
	for i in range(4):
		var x: float = 68.0 + i * 135.0
		circle_icon(Vector2(x, 634), str(i + 1), GOLD if i == 1 else MUTED, 15)
		txt(["结算", "等待房间", "离开房间", "大厅"][i], x - 60, 678, 120, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	for i in range(3):
		draw_line(Vector2(84 + i * 135, 634), Vector2(187 + i * 135, 634), LINE, 1.0)
	txt("默认返回原房间；离开后进入大厅", 20, 795, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)

func _join_error() -> void:
	_lobby()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.82), true)
	panel(Rect2(76, 319, 388, 280), SURFACE)
	txt("房间已满", 103, 425, 334, FONT_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER)
	txt("当前 4 / 4 席位都已占用", 103, 482, 334, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	button("返回房间列表", Rect2(123, 525, 294, 43), true)

func _auth() -> void:
	if auth_signed_in:
		_header("账号", "已登录 · 可用好友与邀请")
		txt("完成", 400, 112, 120, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
		txt("已登录", 58, 325, 424, FONT_TITLE, INK, HORIZONTAL_ALIGNMENT_CENTER)
		txt(auth_identity, 58, 409, 424, FONT_BODY, INK, HORIZONTAL_ALIGNMENT_CENTER)
		txt("此设备已保存登录状态", 58, 451, 424, FONT_SECONDARY, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		button("退出登录", Rect2(58, 500, 424, 52), false)
		txt("退出后将返回登录页", 20, 588, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
		return
	if auth_step == 1:
		_auth_otp()
		return
	_header("登录 / 注册", "好友与邀请需要账号")
	txt("邮箱", 58, 312, 200, FONT_SECONDARY, MUTED)
	draw_line(Vector2(58, 385), Vector2(482, 385), LINE, 1.0)
	txt("密码", 58, 414, 200, FONT_SECONDARY, MUTED)
	draw_line(Vector2(58, 487), Vector2(482, 487), LINE, 1.0)
	# Input text is drawn by the shell's transparent LineEdits over these frames.
	if not auth_progress.is_empty():
		txt(auth_progress, 58, 524, 424, FONT_CAPTION, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	elif not auth_error.is_empty():
		txt(auth_error, 58, 524, 424, FONT_CAPTION, Color("ff626c"), HORIZONTAL_ALIGNMENT_CENTER)
	var primary_label := "登录" if auth_mode == 0 else "注册"
	button(primary_label, Rect2(58, 540, 424, 52), true)
	var switch_label := "没有账号？去注册" if auth_mode == 0 else "已有账号？去登录"
	button(switch_label, Rect2(58, 606, 424, 46), false)
	txt("账号用于好友与邀请", 20, 686, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)

func _auth_otp() -> void:
	var shown_email := auth_pending_email if auth_pending_email.length() <= 30 else auth_pending_email.left(28) + "…"
	_header("验证邮箱", "验证码已发往 " + shown_email)
	txt("验证码", 58, 312, 200, FONT_SECONDARY, MUTED)
	# 输入框本体是 shell 的透明 LineEdit，这里只画下划线和提示
	draw_line(Vector2(58, 386), Vector2(482, 386), LINE, 1.0)
	# 位数不写死：Supabase 的 Email OTP Length 可以在后台改（当前项目是 8 位）
	txt("输入邮件里的验证码", 58, 404, 424, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	if not auth_otp_error.is_empty():
		txt(auth_otp_error, 58, 446, 424, FONT_CAPTION, PINK, HORIZONTAL_ALIGNMENT_CENTER)
	button("验证并登录", Rect2(58, 480, 424, 52), true)
	var resend_label := "重新发送验证码" if auth_resend_wait <= 0 else ("重新发送（%d 秒）" % auth_resend_wait)
	button(resend_label, Rect2(58, 546, 424, 46), false)
	button("返回修改邮箱", Rect2(58, 600, 424, 46), false)
	txt("没收到？先看垃圾邮件，再点重发", 20, 680, 500, FONT_CAPTION, MUTED, HORIZONTAL_ALIGNMENT_CENTER)

func _draw() -> void:
	if font == null: return
	_background()
	match page:
		"auth": _auth()
		"first_profile", "first_profile_invite", "edit_profile": _first_profile()
		"lobby": _lobby()
		"friends": _friends()
		"chat": _chat()
		"profile": _profile()
		"player_profile": _player_profile()
		"level_up": _level_up()
		"badges": _badges()
		"waiting_room": _waiting_room()
		"result_flow": _result_flow()
		"join_error": _join_error()
