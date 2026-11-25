extends Control

# Local, interactive UI prototype. Social/room/progression content is mock state.
# The existing match scene is instanced unchanged; no UI handler writes physics or HP.
signal create_room_requested
signal join_room_requested(room_code: String)
signal ready_changed(ready: bool)
signal profile_changed(display_name: String)
signal friend_request_requested(player_id: String)
signal chat_send_requested(message: String)
signal match_start_requested
signal leave_match_requested

const PREVIEW = preload("res://design_preview/AppShellPreviewV1.gd")
const AVATARS = preload("res://design_preview/AvatarPreviewAssets.gd")
const THEME = preload("res://scripts/ui/AppThemeV1.gd")
const UI_FONT := preload("res://fonts/game_zh.ttf")
const BALL_PORTRAITS = preload("res://scripts/ui/PlayerBallPortraitOverlay.gd")
const CROP_DIALOG = preload("res://scripts/ui/AvatarCropDialog.gd")
const CARET_HINT = preload("res://scripts/ui/BlinkingCaret.gd")
const LAN_CLIENT = preload("res://scripts/network/LanMatchClient.gd")
const ROOM_MUSIC_PANEL = preload("res://scripts/ui/RoomMusicPanel.gd")
const MATCH_ICON = preload("res://scripts/ui/MatchIconButton.gd")
const SettingsStore = preload("res://scripts/data/SettingsStore.gd")
const FriendBook = preload("res://scripts/data/FriendBook.gd")
const SupabaseClient = preload("res://scripts/network/SupabaseClient.gd")
const REALTIME = preload("res://scripts/network/SupabaseRealtime.gd")
const PROFILE_FILE := "user://ui_v1_mock_profile.cfg"
const AVATAR_FILE := "user://ui_v1_mock_avatar.png"
# Password mask. Godot defaults to U+2022 (bullet), which fonts/game_zh.ttf does
# not contain: on Web there is no system font to fall back to, so every character
# rendered as a tofu box. An ASCII asterisk is guaranteed to have a glyph.
const SECRET_CHAR := "*"
# 对局页观众席气泡的几何由 FormalHud 单点给出（展开/收起两态都在那边算），
# 这里只保留滚动步进；热区、横滑、吸附全部读 HUD 的 spectator_strip_rect()。
const MATCH_SPECTATOR_STEP := 34.0
const SPECTATOR_WHEEL_STEP := 64.0

var profile_file := PROFILE_FILE
var avatar_file := AVATAR_FILE

var preview: Control
var hotspot_layer: Control
var dialog_layer: Control
var match_layer: CanvasLayer
var music_modal_layer: CanvasLayer
var match_ui: Control
var match_hud_buttons: Array[Button] = []
var hud_buttons_ignoring := false
# 退出对局请求已交给宿主，等它确认才换页。服务端没点头就跳回房间，
# 会变成"人还在对局里、界面已经回到房间"的假状态。
var _match_leave_pending := false
var _match_leave_sent_ms := 0
# 对局顶部那行系统状态的短暂提示（例如退出请求没有回应），带过期时间。
var _match_status_flash := ""
var _match_status_flash_until := 0
# 换页后要补的一句话（例如"XX 退出了对局，本局结束"）。
# 先存下来、路由建完再弹，避免被紧随其后的 room 重绘清掉。
var _pending_room_notice := ""
var _pending_room_notice_until := 0
var match_scene: Node2D
var ball_portrait_overlay: Node2D
var match_status: Label
# 新玩家第一次轮到自己时的反向拖拽提示。纯 Label + MOUSE_FILTER_IGNORE，
# 不占热区、不挡拖动，也不改任何玩法参数。
var match_shot_hint: Label
var match_chat_input: LineEdit
var match_send_btn: Button
var match_plus_btn: Button
const MATCH_CHAT_HISTORY_LIMIT := 30
var match_chat_log: Array = []
var _web_match_chat_media_ids: Dictionary = {}
var network_debug_label: Label
var network_debug_elapsed := 0.0
var page := ""
var display_name := "星澜"
var signature := "在群星之间，等待下一次碰撞。"
var pending_invite := ""
var local_ready := false
var opponent_ready := false # Local hotseat only until a network room is connected.
var avatar_textures: Array[Texture2D] = []
# Per-seat portraits, indexed by the server slot (0/1 blue, 2/3 red). The board
# and the waiting room read from this instead of rotating avatar_textures, which
# is the local gallery (slot 0 is *me*). Rotating that array in place fed the
# guest's own face back into slot 0, so after the second roster update every ball
# showed the host's portrait while the host looked correct (his mapping is a no-op).
var slot_portraits: Array[Texture2D] = [null, null, null, null]
var slot_avatar_sig := PackedStringArray(["", "", "", ""])
var local_chat_lines: Array[String] = []
var active_friend_id := ""
var active_friend_name := ""
var invited_friend_ids: Array[String] = []
# In-room friend picker. The dialog is built from friend_rows, never from a local
# demo roster, so an "已发送邀请" badge always means a real message was accepted
# by Supabase. Busy/error are per-friend so one failure never blocks the others.
var invite_panel_open := false
var invite_panel_signature := ""
var invite_panel_busy: Dictionary = {}
var invite_panel_error: Dictionary = {}
var invite_panel_note: Dictionary = {}
var invite_last_copied := ""
var invite_refresh_timer: Timer
# Cloud friend state (Step 5). friend_rows mirrors Supabase, never local demo data.
var friend_rows: Array = []
var friend_pending_count := 0
var friend_cloud_state := "" # "" | "loading" | "synced" | "failed"
var friend_last_error := ""
var friend_busy := false
# Direct-message state (Step 5.5). Polling instead of realtime: honest, ~3s delay.
var chat_messages: Array = []
var chat_state := "" # "" | "loading" | "ready" | "failed"
var chat_last_error := ""
var chat_input: LineEdit
# Unread badge. The messages table has no read_at column and no UPDATE policy,
# so "read" can only be this device's watermark per friend. Counts are always
# recomputed from "server rows newer than the watermark", never accumulated, so
# a refresh or reconnect cannot double count.
var unread_by_friend: Dictionary = {} # friend uid -> unread message count
var chat_read_cursors: Dictionary = {} # friend uid -> {t: created_at}
var _read_state_all: Dictionary = {} # account uid -> the cursor table above
var _read_state_uid := "" # account whose cursors are loaded in memory
var _read_state_loaded := false # on-disk table already read once
var _read_state_seeded := true # false until a brand-new account's history is adopted
var unread_poll_timer: Timer
var _unread_busy := false
const CHAT_READ_STATE_PATH := "user://chat_read_state.json"
const UNREAD_POLL_SECONDS := 5.0
# Newest N incoming rows across all friends. Any total above 99 renders "99+",
# so this window is wide enough for every badge the UI can show.
const UNREAD_FETCH_LIMIT := 100
# Only pages that draw the bottom bar can show the badge; polling elsewhere
# would spend egress on a marker nobody can see.
const UNREAD_PAGES := ["lobby", "friends", "chat", "profile", "badges"]
# 邮箱验证码登录：输入框、重发冷却计时器
var auth_otp_field: LineEdit
var auth_resend_timer: Timer
var _login_started_ms := -1
# 等待房间内的临时聊天（不入库，人走即散）。绘制层从 preview 的 metadata
# "room_chat_messages" 读取，格式 [{nickname, body}, ...]。
var room_chat_input: LineEdit
var room_chat_log: Array = []
# 多房间：当前要进入的房间号，以及大厅房间列表的轮询定时器
var room_code := ""
var room_poll_timer: Timer
var chat_poll_timer: Timer
# 页面被手机系统回收后重载时，内存里的 room_code 已经没了，只剩落盘的 resume_key。
# 用 sessionStorage 记住"上次那一桌"，回来才能用同一个身份坐回原座位。
const ROOM_STORE_KEY := "arena_room_code"
var restored_room_code := ""
# 大厅列表请求失败的原因（空 = 正常）。为空列表和"请求挂了"要能区分开。
var room_list_error := ""
# 大厅房间行的热区。列表每 3 秒刷新，热区必须跟着重建，
# 否则后出现的桌子只有文字、点不动（只在 _route 里建一次就是这个后果）。
var lobby_room_buttons: Array[Button] = []
var lobby_room_signature := ""
# 大厅列表滚动。房间多于 4 桌时一屏放不下，靠手势/滚轮移动；
# 行高 96、可视区 420..848，越界的按钮隐藏并禁用，避免点到看不见的房间。
var lobby_scroll := 0.0
var lobby_drag_start_y := -1.0
var lobby_drag_last_y := -1.0
var lobby_dragging := false
const LOBBY_LIST_TOP := 420.0
const LOBBY_LIST_BOTTOM := 848.0
const LOBBY_ROW_H := 96.0
var chat_sending := false
# Web 移动端软键盘桥：页面里铺的真实 <input> 把值回传到这里（见网关的 vkBridge 注入）。
var auth_email_field: LineEdit
var auth_password_field: LineEdit
var web_vk_callback: JavaScriptObject
# Web has no FileDialog: the browser's <input type=file> is injected at runtime
# and hands the picked image back as a base64 PNG data URL.
var web_avatar_callback: JavaScriptObject
# Runtime DOM inputs for dialog fields the gateway's soft-keyboard bridge does
# not know about (password change, and anything added later). key -> LineEdit.
var web_dyn_input_callback: JavaScriptObject
var _web_dyn_fields: Dictionary = {}
# Caret bookkeeping: which fields exist, and which one currently owns the caret.
var web_caret_focus_callback: JavaScriptObject
var web_match_chat_callback: JavaScriptObject
var web_chat_media_callback: JavaScriptObject
var _caret_fields: Dictionary = {}
var _active_caret_field: LineEdit
# Avatar cache: uid -> Texture2D already downloaded from Storage (keyed by avatar_key).
var friend_avatar_textures: Dictionary = {}
var friend_avatar_keys: Dictionary = {}
var avatar_loading: Dictionary = {}
var avatar_sync_state := "" # "" | "sending" | "ok" | "failed" (last cloud avatar upload)
var avatar_sync_error := ""
var my_level := 1
# avatar_key stamps the last upload. Kept so a second device knows whether the
# local avatar file is still the current one, instead of re-downloading every launch.
var my_avatar_key := ""
# Cloud sync status, surfaced on the profile page. Silent failures were exactly
# why "signed in on the other device, nothing changed" was impossible to diagnose.
var profile_sync_state := "" # "" | "loading" | "ready" | "failed"
var profile_sync_error := ""
# Single-session enforcement: a random id minted at sign-in and stamped into
# profiles.session_id. Heartbeats only match while it is still ours.
var my_session_id := ""
var _session_claim_failed_once := false
var _session_claimed := false
var _session_retry_ticks := 0
var _heartbeat_busy := false
var _session_check_ms := 0
var _realtime_ui_elapsed := 0.0
# Realtime socket that pushes "another device claimed this account".
var realtime: Node
# In-room player card state (tapping another player's avatar in the waiting room).
var view_player_id := ""
var view_player_name := ""
var view_player_signature := ""
var view_player_level := 1
var view_player_state := "" # "" | "loading" | "ready" | "failed"
var view_player_error := ""
# "friend" | "requested" | "none" — decides what the relation button offers.
var view_player_relation := "none"
var view_player_portrait: Texture2D = null
# Last roster signature, so seat hot zones are rebuilt only when membership
# changes (not when someone merely toggles ready).
var _room_roster_signature := ""
# Hit zones laid over invite bubbles in the chat list, rebuilt when bubbles move.
var _chat_invite_hits: Array[Button] = []
var _chat_hits_signature := ""
var _chat_hit_elapsed := 0.0
# Presence heartbeat (Step 6): 25s interval, online = last_seen within 60s.
var heartbeat_timer: Timer
var music_wave_on := false
var music_wave_elapsed := 0.0
var active_music_bar: Button
var local_team := 0
var local_slot := -1 # 四人模式下自己占用的球槽（0-3），双人模式不用
var match_mode := 0 # 0 = 双人（各控两球），1 = 四人（各控一球、两人一队）
# 对局内四个球槽的展示名，按 slot 绑定（0/1 蓝，2/3 红）。
# 必须来自服务端 roster 的真实昵称：以前四人模式硬编码"蓝方 1/蓝方 2"，
# 双人模式又只取队里第一个人，结果每个座位都像房主。
var match_slot_names := PackedStringArray(["", "", "", ""])
var room_label := "" # 没有真实房间号之前不显示假号（旧值硬编码"私人房间 #A102"）
var room_is_host := false
# 房间成员模型：玩家 = 占一个参赛席，观众 = slot -1。座位与房主都由服务端裁定。
var local_role := "player" # "player" | "spectator"
var room_host_id := ""
var room_intro := ""
var room_phase := "waiting" # "waiting" | "playing"
var room_spectators: Array = [] # preview rows: [{name, portrait, me}]
var spectator_portraits: Dictionary = {} # player_id -> Texture2D
var spectator_avatar_sig: Dictionary = {} # player_id -> payload signature
var spectator_scroll := 0.0
# 对局页观众名单的横向偏移。等待房条和 HUD 条可视宽度不同，偏移必须分开算。
var match_spectator_scroll := 0.0
# 对局页观众气泡的展开状态。每局从收起开始，玩家点了才铺开。
var match_spectator_expanded := false
var _spectator_plus_hit: Button = null
var _strip_press_x := -1.0
var _strip_press_y := 0.0
var _strip_last_x := -1.0
var _strip_dragging := false
# 单机测试：借用等待房这一屏但不建连、不需要房间号，点准备直接本地热座开局。
var solo_room := false
# 单机「本地回环」：同进程再造一个隐藏的权威实例，按 50ms 把快照喂给屏幕上的客户端。
# 联机时服务器是独立进程、每个玩家都是客户端，特效和音效靠快照转发；不开回环的话
# 单机走的是本地物理直绘，一个人根本测不到那条链路。开法：网页 ?solo_net=1，桌面 --solo-net。
var solo_loop_host: Node = null
var solo_loop_seq := 0
var solo_loop_accum := 0.0
var solo_loop_enabled := false
const SOLO_LOOP_STEP_MS := 50.0
var profile_name_input: LineEdit
var profile_signature_input: LineEdit
var file_dialog: FileDialog
var network_client: Node
var supabase: RefCounted
var pending_route := ""
# 进入 auth 前所在的页面。登录成功后优先回到这里，避免从邀请房间去登录、回来却掉进大厅。
var auth_return_page := ""
var _profile_sync_failed_once := false
var bgm_player: AudioStreamPlayer
var _room_music_bridge := false
var _room_music_callback: JavaScriptObject
var _room_music_room := ""
var _room_music_state := {}
var _room_music_status := ""
var _room_music_error := ""
var _room_music_panel: ROOM_MUSIC_PANEL
# The current music room was opened by the gateway /api/music/solo: there is no
# network_client and no room_code, so lifecycle checks cannot compare room_code
# and look at this flag instead.
var _room_music_solo := false
var _room_music_solo_pending := false
var network_url := ""
# Optional HTTP control-plane base (room list / room claim). Empty = derive from
# network_url, which is correct when the gateway and game server share a host.
# Split-port LAN launches and isolated tests set it explicitly.
var api_base_url := ""
var invite_url := ""
var player_id := ""
var network_players: Array = []
## Solo quick play: enabled by the --solo command-line flag, skips the profile
## and room flow and enters a local hotseat match directly. network_client stays
## null in this mode, so no networking code path is ever touched.
var solo_quickstart := false
## Isolated perf runs need a repeatable opening layout and a direct local match
## entry in a real browser. Both are test seams only: they do not change any
## normal entry point, and ?seed= is ignored unless the caller passes it.
var perf_match_seed := -1
## Rooms normally require a real account. Isolated LAN/tests can switch the gate
## off; seats are then keyed by the local profile player_id. Production keeps it on.
var require_account_gate := true

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	SettingsStore.load_settings()
	# Cap the frame rate: the Web build follows the display's rAF, so a 144 Hz
	# monitor would otherwise render 144 fps and waste GPU for no benefit.
	# 30/60 由设置里的"限制为 30 帧"决定，重进游戏仍然生效。
	_apply_frame_limit()
	solo_loop_enabled = _read_solo_loop_flag()
	FriendBook.load_book()
	supabase = SupabaseClient.new()
	supabase.restore_session()
	if supabase.has_signal("auth_failed"):
		supabase.auth_failed.connect(_on_auth_failed)
	# Chat refresh loop: only ticks while the chat page is open.
	chat_poll_timer = Timer.new()
	chat_poll_timer.wait_time = 3.0
	chat_poll_timer.timeout.connect(_on_chat_poll)
	add_child(chat_poll_timer)
	# Unread badge loop: runs on the pages that draw the bottom bar. Kept separate
	# from the chat loop so a message from a friend you are NOT talking to still
	# raises the badge while you sit on the home page.
	unread_poll_timer = Timer.new()
	unread_poll_timer.wait_time = UNREAD_POLL_SECONDS
	unread_poll_timer.timeout.connect(_on_unread_poll)
	add_child(unread_poll_timer)
	heartbeat_timer = Timer.new()
	# Back to 25s: takeover detection is pushed over Realtime now. This timer only
	# refreshes last_seen for the friends list, plus a fallback session check.
	heartbeat_timer.wait_time = 25.0
	heartbeat_timer.timeout.connect(_on_heartbeat)
	add_child(heartbeat_timer)
	heartbeat_timer.start()
	# Presence inside the invite window: someone opening the game after the
	# window was built must flip from 离线/复制链接 to 在线/邀请 without closing it.
	invite_refresh_timer = Timer.new()
	invite_refresh_timer.wait_time = 5.0
	invite_refresh_timer.timeout.connect(_on_invite_refresh)
	add_child(invite_refresh_timer)
	_setup_bgm()
	# Web blocks autoplay until a user gesture; start there only on toggle.
	if not OS.has_feature("web"):
		_apply_bgm()
	if OS.has_feature("web"): print("ARENA_WEB shell ready begin")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = THEME.create()
	if OS.has_feature("web"): print("ARENA_WEB loading portraits")
	avatar_textures = AVATARS.load_circular_textures()
	if OS.has_feature("web"): print("ARENA_WEB portraits loaded")
	if OS.has_feature("web"): print("ARENA_WEB loading profile")
	_load_profile()
	_init_web_vk()
	_init_web_dyn_inputs()
	_init_web_match_chat()
	_init_room_music()
	# Restored session wins over any cached profile id, so identity survives restarts.
	# 有 refresh_token 就先续期一步：access_token 只活 1 小时，过期不代表要重新登录。
	# 必须放在 session_valid() 判断之前，否则隔天打开就只剩下登录页。
	# refresh_if_needed 内部会先看剩余时间，未过期直接返回，不会每次启动都发请求。
	if supabase.can_refresh():
		await supabase.refresh_if_needed()
	if supabase.session_valid():
		player_id = supabase.current_user_id()
		_persist_identity()
		# Restoring a saved session is a fresh login as far as single-session goes:
		# mint an id here too, otherwise a page reload would never be kickable.
		my_session_id = Crypto.new().generate_random_bytes(16).hex_encode()
		call_deferred("_claim_my_session")
		# Coroutine: must be deferred from a sync function, never called bare.
		call_deferred("_sync_profile_from_cloud")
		# Stamp last_seen immediately so friends see us online without waiting 25s.
		call_deferred("_heartbeat_tick", false)
	if OS.has_feature("web"): print("ARENA_WEB profile loaded")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--room="): pending_invite = arg.trim_prefix("--room=").strip_edges()
		if arg.begins_with("--join="): network_url = arg.trim_prefix("--join=").strip_edges()
		if arg == "--solo": solo_quickstart = true
	if OS.has_feature("web"):
		# Same seams as --solo / --seed on desktop, for the isolated Chrome A/B run.
		# They are ignored unless the gateway was started with the explicit test
		# switch and injected window.ARENA_TEST_SEAMS. Normal links cannot enable
		# them by appending ?solo=1 or ?seed=.
		var test_seams := bool(JavaScriptBridge.eval("window.ARENA_TEST_SEAMS===true", true))
		if test_seams:
			if str(JavaScriptBridge.eval("(new URLSearchParams(location.search).get('solo')||'')")) == "1":
				solo_quickstart = true
			var seed_param := str(JavaScriptBridge.eval("(new URLSearchParams(location.search).get('seed')||'')"))
			if seed_param.is_valid_int(): perf_match_seed = int(seed_param)
	if OS.has_feature("web") and network_url.is_empty():
		var browser_host: Variant = JavaScriptBridge.eval("window.location.host")
		var browser_secure: Variant = JavaScriptBridge.eval("window.location.protocol === 'https:'")
		# NOTE: On the single-threaded Web build, `browser_host is String` can stall
		# the whole `_ready` (leaving a black screen), so convert via str()/bool().
		var hs: String = str(browser_host)
		if not hs.is_empty():
			network_url = ("wss://" if bool(browser_secure) else "ws://") + hs + "/ws"
		# The gateway injects the full invite URL (the ?invite= token is otherwise
		# lost after the redirect), so the waiting room can show / copy it.
		invite_url = str(JavaScriptBridge.eval("(window.ARENA_INVITE_URL||'')"))
		# 邀请链接带 &room=CODE 时直接进对应房间（朋友点链接直达，不用再手输房间号）
		var room_param := str(JavaScriptBridge.eval("(new URLSearchParams(window.location.search).get('room')||'')")).strip_edges()
		if not room_param.is_empty():
			room_code = room_param.to_upper()
			room_label = "房间 #%s" % room_code
		else:
			# 页面被系统回收后重载：只有 resume_key 落盘、房间号留在内存里是不够的，
			# 座位能恢复但人已经掉到大厅。这里把上次那一桌捞回来，先校验再进。
			var saved_room := _read_saved_room()
			if not saved_room.is_empty():
				room_code = saved_room
				room_label = "房间 #%s" % room_code
				restored_room_code = saved_room
	preview = PREVIEW.new()
	preview.portraits = avatar_textures
	add_child(preview)
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hotspot_layer = Control.new()
	hotspot_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hotspot_layer)
	hotspot_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog_layer = Control.new()
	dialog_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dialog_layer)
	dialog_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	music_modal_layer = CanvasLayer.new()
	music_modal_layer.layer = 30
	add_child(music_modal_layer)
	match_layer = CanvasLayer.new()
	match_layer.layer = 20
	add_child(match_layer)
	match_ui = Control.new()
	match_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match_ui.visible = false
	match_layer.add_child(match_ui)
	match_ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A CanvasLayer breaks Control's theme chain: match_ui cannot see the root
	# node's theme, so every Label/Button under it falls back to Godot's built-in
	# font, which has no CJK glyphs. On desktop the OS font covers for it; on Web
	# there is nothing to fall back to and the whole HUD reads as tofu boxes.
	# Scoped theme: font only, no stylebox, so button visuals stay untouched.
	var match_theme := Theme.new()
	match_theme.default_font = UI_FONT
	match_theme.default_font_size = 14
	match_ui.theme = match_theme
	if OS.has_feature("web"): print("ARENA_WEB layers ready, checking profile")
	# Solo quick play: skip profile / room / ready flow and go straight into a
	# local hotseat match. No network client is created and no profile is written.
	if solo_quickstart:
		# --solo counts as solo too: the solo music room and the route guards key off solo_room.
		solo_room = true
		_route("match")
		return
	if FileAccess.file_exists(profile_file):
		if OS.has_feature("web"): print("ARENA_WEB existing profile")
		# 一律先到大厅。只有链接里带 room=CODE（房主复制的邀请）才直达那一桌，
		# 扫码/普通链接都先在主页挑桌子，不再"点开就被塞进某个房间"。
		_enter_room_or_lobby()
	else:
		# 必须登录才能进房：不再自动生成 guest 昵称和身份。
		# 未登录时 _route 的守卫会转到登录页，登录成功后按原路返回大厅或那一桌。
		if OS.has_feature("web") and not network_url.is_empty():
			_enter_room_or_lobby()
		else:
			if OS.has_feature("web"): print("ARENA_WEB first profile")
			_route("first_profile_invite" if not pending_invite.is_empty() else "first_profile")
	if OS.has_feature("web"): print("ARENA_WEB ready done")

# Procedurally build a soft ambient loop; no audio asset files exist in the project.
const BGM_MIX_RATE := 22050
const BGM_SECONDS := 4.0

func _make_ambient_wav() -> AudioStreamWAV:
	var frames := int(BGM_MIX_RATE * BGM_SECONDS)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = false
	wav.mix_rate = BGM_MIX_RATE
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var data := PackedByteArray()
	data.resize(frames * 2)
	var fade_frames := int(BGM_MIX_RATE * 0.25)
	var tau := TAU
	for i in range(frames):
		var t := float(i) / float(BGM_MIX_RATE)
		var wave := 0.6 * sin(tau * 110.0 * t) + 0.4 * sin(tau * 165.0 * t)
		var envelope := 1.0
		if i < fade_frames:
			envelope = float(i) / float(fade_frames)
		elif i >= frames - fade_frames:
			envelope = float(frames - 1 - i) / float(fade_frames)
		var sample := int(clampf(wave * envelope, -1.0, 1.0) * 12000.0)
		data.encode_s16(i * 2, sample)
	wav.data = data
	return wav

func _setup_bgm() -> void:
	# Web 上绝对不能建新总线：只要总线数 >= 2，Godot 的 JS 侧 Bus.addAt(-1) 会打乱
	# 总线数组、把 Master 与 AudioContext.destination 断开，整个游戏静音。
	# 详见 MatchSfx._ensure_bus 的注释（godotengine/godot#119026）。
	var music_bus: StringName = &"Master"
	if not OS.has_feature("web"):
		if AudioServer.get_bus_index("AmbientMusic") < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, "AmbientMusic")
		music_bus = &"AmbientMusic"
	bgm_player = AudioStreamPlayer.new()
	bgm_player.bus = music_bus
	bgm_player.stream = _make_ambient_wav()
	bgm_player.volume_db = -22.0
	add_child(bgm_player)

func _apply_bgm() -> void:
	if bgm_player == null:
		return
	if SettingsStore.bgm_enabled and _room_music_room.is_empty():
		if not bgm_player.playing:
			bgm_player.play()
	else:
		bgm_player.stop()


# 本机渲染帧率上限。默认 60（高刷屏也不白烧 GPU），打开"限制为 30 帧"就是 30。
# 只改 Engine.max_fps：物理步进（physics_ticks_per_second）和网络快照频率都不动，
# 所以低帧只是画面少画几次，出手时机、伤害与同步节奏完全一致。
func _apply_frame_limit() -> void:
	Engine.max_fps = 30 if SettingsStore.fps_limit_30 else 60

func _process(delta: float) -> void:
	# 本地回环的快照节拍：和 LanMatchHost 的 50ms 一致，客户端才会看到真实的采样间隔。
	# 上限卡住 4 次：切后台回来 delta 很大，不能一口气补上百帧快照。
	if solo_loop_host != null:
		solo_loop_accum = minf(solo_loop_accum + delta * 1000.0, SOLO_LOOP_STEP_MS * 4.0)
		while solo_loop_accum >= SOLO_LOOP_STEP_MS:
			solo_loop_accum -= SOLO_LOOP_STEP_MS
			_solo_loop_push_snapshot()
	if page == "auth" and _login_started_ms >= 0:
		var elapsed := Time.get_ticks_msec() - _login_started_ms
		var dots := 3 if SettingsStore.reduce_motion else 1 + int(elapsed / 500.0) % 3
		var progress := "正在登录" + ".".repeat(dots)
		if preview.auth_progress != progress:
			preview.auth_progress = progress
			preview.queue_redraw()
	var reconnecting: bool = network_client != null and bool(network_client.is_reconnecting)
	if preview != null and preview.room_reconnecting != reconnecting:
		preview.room_reconnecting = reconnecting
		preview.queue_redraw()
	# Waveform text alternation only while the music bar is visible and motion is allowed.
	if not SettingsStore.reduce_motion and is_instance_valid(active_music_bar) and active_music_bar.is_visible_in_tree():
		music_wave_elapsed += delta
		if music_wave_elapsed >= 0.5:
			music_wave_elapsed = 0.0
			music_wave_on = not music_wave_on
			active_music_bar.text = _music_bar_text()
	if is_instance_valid(network_debug_label) and network_debug_label.is_visible_in_tree():
		network_debug_elapsed += delta
		if network_debug_elapsed >= 0.25:
			network_debug_elapsed = 0.0
			_update_network_debug()
	# Invite bubbles move as messages arrive; re-lay their hit zones a few times a
	# second instead of every frame.
	if page == "chat":
		# 每帧推：滚动时 DOM 里的文字/图片必须和 Godot 画的气泡同步，慢一帧就会飘
		_push_friend_chat_tiles()
		_chat_hit_elapsed += delta
		if _chat_hit_elapsed >= 0.2:
			_chat_hit_elapsed = 0.0
			_refresh_chat_invite_hits()
			# 幂等重贴：既兜住"进页面那一次调用没生效"，也让键盘弹出/收起后重新校准位置
			_sync_web_friend_chat()
	# Realtime state is only meaningful while looking at the profile page; refresh
	# it twice a second so a dead socket cannot hide behind a "synced" label.
	_realtime_ui_elapsed += delta
	if _realtime_ui_elapsed >= 0.5:
		_realtime_ui_elapsed = 0.0
		if page == "profile" and preview != null:
			var rt_text := _realtime_status_text()
			if rt_text != preview.realtime_text:
				preview.realtime_text = rt_text
				preview.queue_redraw()
	if page == "match" and match_scene != null and match_status != null:
		# While aiming, let pointer events pass through HUD buttons to the board so
		# the aim line is not interrupted when the drag crosses a button.
		var want_ignore: bool = bool(match_scene.aiming)
		if want_ignore != hud_buttons_ignoring:
			hud_buttons_ignoring = want_ignore
			for btn in match_hud_buttons:
				if is_instance_valid(btn):
					btn.mouse_filter = Control.MOUSE_FILTER_IGNORE if want_ignore else Control.MOUSE_FILTER_STOP
		# 这一行只写真实系统状态。回合/击球人/读秒已经画在球盘外侧，
		# 顶部中间空出来给观众条；没有状态时不占位，也不显示空框。
		var status := _match_status_flash
		if not status.is_empty() and Time.get_ticks_msec() > _match_status_flash_until:
			_match_status_flash = ""
			status = ""
		if status.is_empty() and _match_leave_pending:
			status = "正在退出对局…"
			if Time.get_ticks_msec() - _match_leave_sent_ms > 6000:
				# 请求发出去了但宿主没回：不能一直挂着这句话，也不能假装已经退出。
				_match_leave_pending = false
				_match_status_flash = "退出请求没有回应，请检查网络"
				_match_status_flash_until = Time.get_ticks_msec() + 4000
				status = _match_status_flash
		elif status.is_empty() and network_client != null and network_client.is_reconnecting:
			status = "连接中断 · 正在重连" + (" · 这一杆未确认" if match_scene.shot_is_pending() else "")
		elif status.is_empty() and match_scene.network_paused:
			status = "对局暂停 · 等待玩家重连"
		elif status.is_empty() and match_scene.shot_is_pending():
			# 真实状态，不是假进度：包已经交给 socket，正在等服务端快照确认。
			# RTT 400ms 的玩家松手后 0.4 秒内屏幕毫无反应，会以为操作没生效。
			var rtt_ms: int = network_client.latency_ms if network_client != null else -1
			status = "已发出 · 等待服务器确认" + ("（%d ms）" % rtt_ms if rtt_ms >= 0 else "")
		elif status.is_empty():
			status = str(match_scene.shot_state_text())
		# 观众看的是同一场比赛，但不能操作：状态行必须说清楚，别让人以为轮到自己。
		if network_client != null and local_role == "spectator" and not network_client.is_reconnecting and not match_scene.network_paused:
			status = status if status.begins_with("观战中") else ("观战中 · " + status if not status.is_empty() else "观战中")
		if match_status.text != status:
			match_status.text = status
		if match_status.visible != not status.is_empty():
			match_status.visible = not status.is_empty()
		if match_shot_hint != null:
			var show_hint := _should_show_shot_hint(
				int(match_scene.turn_manager.round_number),
				bool(match_scene.can_control_current_ball()),
				bool(match_scene.aiming), bool(match_scene.moving), bool(match_scene.finished))
			if match_shot_hint.visible != show_hint:
				match_shot_hint.visible = show_hint
		if match_scene.finished:
			# 结算原因由玩法层给出：击破主塔 / 20 回合血量判定 / 平局
			var outcome := str(match_scene.result_text)
			preview.result_winner = outcome if not outcome.is_empty() else "对局结束"
			_route("result_flow")

# First-round only, and only while it is actually this device's turn to act.
# Kept as a pure predicate so the rule is testable without a live match.
func _should_show_shot_hint(round_number: int, can_control: bool, aiming: bool, moving: bool, finished: bool) -> bool:
	if finished or moving or aiming:
		return false
	if round_number > 1:
		return false
	return can_control

# Name of whoever is on the clock, by ball slot. Never invents a player: an
# empty or unknown slot reads as "等待中" instead of a numbered placeholder.
func _current_turn_name() -> String:
	if match_scene == null:
		return "等待中"
	var names: PackedStringArray = match_scene.formal_hud.player_names if match_scene.formal_hud != null else PackedStringArray()
	var slot: int = int(match_scene.turn)
	if slot >= 0 and slot < names.size() and not str(names[slot]).is_empty():
		return str(names[slot])
	return "等待中"

# Localize failure reasons for display without faking them: client-stable codes
# become Chinese; technical prefix codes become generic Chinese; unknown/server
# text falls back to the original so real causes are never masked.
func _localize_reason(reason: String) -> String:
	var r := reason.strip_edges()
	match r:
		"no_session": return "未登录"
		"refresh_failed": return "登录已过期，请重新登录"
		"profile_not_found": return "资料不存在"
		"invalid_response_body": return "资料数据异常"
		"invalid_auth_response": return "认证响应异常"
		"missing_auth_fields": return "认证信息不完整"
		"no_refresh_token": return "登录凭证缺失"
		"unknown_error": return "未知错误"
		"invalid_json": return "网络异常"
		"Invalid login credentials": return "邮箱或密码错误"
	if r.begins_with("network_error:") or r.begins_with("request_failed:") or r.begins_with("http_"):
		return "网络异常"
	if r.is_empty():
		return "未知错误"
	return r # B-class server text: keep original to avoid masking the real cause.

func _on_auth_failed(reason: String) -> void:
	if preview == null or page != "auth" or _login_started_ms >= 0: return
	preview.auth_error = _localize_reason(reason)
	preview.queue_redraw()

func _init_web_vk() -> void:
	if not OS.has_feature("web"): return
	# 引用必须留在成员变量里，否则回调被 GC 掉后页面调用会静默失效。
	web_vk_callback = JavaScriptBridge.create_callback(_on_web_vk_input)
	JavaScriptBridge.get_interface("window").arenaVKInput = web_vk_callback

func _on_web_vk_input(args: Array) -> void:
	if args.size() < 2: return
	var key := str(args[0])
	var value := str(args[1])
	# Typing is the fallback signal for "this field is active", in case the
	# browser never fired focusin for it.
	var registered: Variant = _caret_fields.get(key)
	if registered is LineEdit and is_instance_valid(registered):
		_set_active_caret(registered)
	if key == "email":
		if is_instance_valid(auth_email_field):
			auth_email_field.text = value
			auth_email_field.set_caret_column(value.length())
		preview.auth_email = value
	elif key == "password":
		if is_instance_valid(auth_password_field):
			auth_password_field.text = value
			auth_password_field.set_caret_column(value.length())
		preview.auth_password = value
	elif key == "otp":
		# 验证码是单独一屏的输入框：DOM 里的真 input 负责唤键盘，
		# 这里同步到 LineEdit（负责画面上的文字）和 preview（_verify_otp 读它）。
		# DOM 输入没有 maxlength，和 LineEdit 的 12 位对齐，避免超长串被当成验证码发出去。
		var max_len := 12
		if is_instance_valid(auth_otp_field) and auth_otp_field.max_length > 0:
			max_len = auth_otp_field.max_length
		var otp_value := value.strip_edges().left(max_len)
		if is_instance_valid(auth_otp_field):
			auth_otp_field.text = otp_value
			auth_otp_field.set_caret_column(otp_value.length())
		preview.auth_otp = otp_value
	preview.queue_redraw()

func _notify_web_vk_page() -> void:
	if not OS.has_feature("web"): return
	# 只有未登录的 auth 页才需要 DOM 输入代理。
	# 验证码是独立一屏（auth_step == 1），必须切到 otp 输入框：
	# 不切的话，盖在验证码那一行上面的是邮箱框，点上去弹的是邮箱键盘。
	var target := "none"
	if page == "auth" and not supabase.session_valid():
		target = "auth_otp" if preview != null and int(preview.auth_step) == 1 else "auth"
	JavaScriptBridge.eval("window.arenaVKSetPage&&window.arenaVKSetPage('%s')" % target, true)

func _web_vk_blur() -> void:
	# 提交后立刻收起键盘：移动端键盘会挡住下面的按钮和错误提示。
	if not OS.has_feature("web"): return
	JavaScriptBridge.eval("window.arenaVKBlur&&window.arenaVKBlur()", true)

# --- Runtime DOM inputs for dialogs ----------------------------------------
# The gateway's soft-keyboard bridge only knows a fixed set of fields
# (email/password/otp). Dialog inputs created later go through this instead:
# a real <input> is overlaid on the LineEdit's rect so the browser shows the
# keyboard, and typed text is mirrored back into the LineEdit for rendering.
func _init_web_dyn_inputs() -> void:
	if not OS.has_feature("web"): return
	web_dyn_input_callback = JavaScriptBridge.create_callback(_on_web_dyn_input)
	JavaScriptBridge.get_interface("window").arenaDynInput = web_dyn_input_callback
	JavaScriptBridge.eval("""
(function () {
	if (window.arenaDynShow) return;
	var fields = {};
	function box() {
		var c = document.getElementById('canvas');
		if (!c) return null;
		var r = c.getBoundingClientRect();
		if (!r.width || !r.height) return null;
		var s = Math.min(r.width / 540, r.height / 960);
		return { s: s, ox: r.left + (r.width - 540 * s) / 2, oy: r.top + (r.height - 960 * s) / 2 };
	}
	window.arenaDynShow = function (key, x, y, w, h, secret, reset) {
		var b = box();
		if (!b) return;
		var e = fields[key];
		if (!e) {
			e = document.createElement('input');
			e.setAttribute('autocomplete', 'off');
			e.setAttribute('autocapitalize', 'off');
			e.setAttribute('data-key', key);
			e.spellcheck = false;
			e.style.cssText = 'position:fixed;z-index:2147483000;opacity:0.011;border:0;'
				+ 'background:transparent;color:transparent;caret-color:transparent;'
				+ 'padding:0;margin:0;outline:none;';
			e.addEventListener('input', function () {
				if (window.arenaDynInput) window.arenaDynInput(key, e.value);
			});
			document.body.appendChild(e);
			fields[key] = e;
		}
		e.type = secret ? 'password' : 'text';
		// reset=false 用于输入态切换：重贴位置不能清掉用户打了一半的字
		if (reset !== false) e.value = '';
		e.style.left = (b.ox + x * b.s) + 'px';
		e.style.top = (b.oy + y * b.s) + 'px';
		e.style.width = (w * b.s) + 'px';
		e.style.height = (h * b.s) + 'px';
		e.style.fontSize = (20 * b.s) + 'px';
		e.style.display = 'block';
	};
	window.arenaDynHideAll = function () {
		for (var k in fields) {
			fields[k].style.display = 'none';
			fields[k].blur();
		}
	};
	// Which field the browser actually focused. Gateway-injected inputs carry no
	// id, so their type ("email"/"password"/"text") stands in for the key;
	// runtime-created ones are tagged with data-key.
	document.addEventListener('focusin', function (ev) {
		var el = ev.target;
		if (!el || el.tagName !== 'INPUT') return;
		var key = el.getAttribute('data-key') || el.type || '';
		if (window.arenaCaretFocus) window.arenaCaretFocus(key);
	}, true);
})();
""", true)
	web_caret_focus_callback = JavaScriptBridge.create_callback(_on_web_caret_focus)
	JavaScriptBridge.get_interface("window").arenaCaretFocus = web_caret_focus_callback

func _on_web_dyn_input(args: Array) -> void:
	if args.size() < 2: return
	var key := str(args[0])
	var value := str(args[1])
	var field_variant: Variant = _web_dyn_fields.get(key)
	if not (field_variant is LineEdit): return
	var field: LineEdit = field_variant
	if not is_instance_valid(field): return
	_set_active_caret(field)
	field.text = value
	field.set_caret_column(value.length())

func _web_show_input(key: String, rect: Rect2, secret: bool, reset_value: bool = true) -> void:
	if not OS.has_feature("web"): return
	JavaScriptBridge.eval("window.arenaDynShow&&window.arenaDynShow('%s',%.1f,%.1f,%.1f,%.1f,%s,%s)" % [
		key, rect.position.x, rect.position.y, rect.size.x, rect.size.y,
		"true" if secret else "false",
		"true" if reset_value else "false",
	], true)

func _web_dyn_hide_all() -> void:
	if not OS.has_feature("web"): return
	JavaScriptBridge.eval("window.arenaDynHideAll&&window.arenaDynHideAll()", true)

# Call after _fit_dialog(): the rects must be final before the DOM inputs are placed.
func _web_bind_dialog_inputs() -> void:
	if not OS.has_feature("web"): return
	if dialog_layer == null: return
	var fields: Array[LineEdit] = []
	_collect_line_edits(dialog_layer, fields)
	for field in fields:
		if not is_instance_valid(field): continue
		var key := str(field.get_meta("web_key", ""))
		if key.is_empty(): continue
		_web_dyn_fields[key] = field
		_web_show_input(key, field.get_global_rect(), field.secret)

func _collect_line_edits(node: Node, out: Array[LineEdit]) -> void:
	for child in node.get_children():
		if child is LineEdit:
			out.append(child)
		_collect_line_edits(child, out)

func _web_vk_clear(key: String) -> void:
	# DOM 里的 input 是隐藏的，重置页面时不清掉，旧内容会在下一次输入时被带出来。
	if not OS.has_feature("web"): return
	JavaScriptBridge.eval("window.arenaVKClear&&window.arenaVKClear('%s')" % key, true)

func _auth_input_field(placeholder: String, y: float, secret: bool) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.secret = secret
	if secret:
		field.secret_character = SECRET_CHAR
	field.position = Vector2(58, y)
	field.size = Vector2(424, 44)
	field.add_theme_font_size_override("font_size", 20)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	field.add_theme_stylebox_override("normal", sb)
	field.add_theme_stylebox_override("focus", sb)
	field.add_theme_color_override("font_color", Color("f5f5f7"))
	field.add_theme_color_override("font_placeholder_color", Color("8e8e93"))
	field.add_theme_color_override("caret_color", Color("6fd3e8"))
	hotspot_layer.add_child(field)
	_attach_caret_hint(field, "password" if secret else "email")
	if secret: auth_password_field = field
	else: auth_email_field = field
	return field

# Local profile is stored per-account: logged-in uses the supabase uid, guest uses "guest".
func _profile_section() -> String:
	if supabase != null and supabase.session_valid():
		var uid: String = supabase.current_user_id()
		if not uid.is_empty():
			return uid
	return "guest"

# One-time migration: copy the legacy global "profile" section into the target section,
# then erase "profile" so a later different account never inherits someone else's data.
func _migrate_profile_section(cfg: ConfigFile) -> bool:
	var section := _profile_section()
	if cfg.has_section(section):
		return false
	if not cfg.has_section("profile"):
		return false
	for key in ["name", "signature", "player_id"]:
		if cfg.has_section_key("profile", key):
			cfg.set_value(section, key, cfg.get_value("profile", key))
	cfg.erase_section("profile")
	return true

# Per-account avatar file; guest keeps the legacy path so old avatars carry over.
func _avatar_path() -> String:
	if supabase != null and supabase.session_valid():
		var uid: String = supabase.current_user_id()
		if not uid.is_empty():
			return "user://avatar_%s.png" % uid
	return AVATAR_FILE

func _persist_identity() -> void:
	# Never create a profile here: first-run routing checks for this file's absence.
	# Only refresh the id in an existing profile so identity survives restarts.
	if not FileAccess.file_exists(profile_file):
		return
	var cfg := ConfigFile.new()
	cfg.load(profile_file)
	var section := _profile_section()
	_migrate_profile_section(cfg)
	cfg.set_value(section, "player_id", player_id)
	cfg.save(profile_file)

func _persist_display_name() -> void:
	# Update only the name field; never touches player_id or creates the file.
	if not FileAccess.file_exists(profile_file):
		return
	var cfg := ConfigFile.new()
	cfg.load(profile_file)
	var section := _profile_section()
	_migrate_profile_section(cfg)
	cfg.set_value(section, "name", display_name)
	cfg.save(profile_file)

# Auto-generated usernames look like "prefix_6hex"; surface a hint in profile.
func _looks_auto_username(value: String) -> bool:
	var idx := value.rfind("_")
	if idx <= 0 or idx >= value.length() - 1:
		return false
	var suffix := value.substr(idx + 1)
	if suffix.length() != 6:
		return false
	for ch in suffix:
		if not "0123456789abcdefABCDEF".contains(ch):
			return false
	return true

# Coroutine: pull the cloud username and adopt it locally. Defer-only from sync code.
func _sync_profile_from_cloud() -> void:
	if supabase == null or not supabase.session_valid():
		return
	if not supabase.has_method("fetch_profile"):
		return # Safe no-op until the client exposes the method.
	profile_sync_state = "loading"
	profile_sync_error = ""
	_apply_profile_sync_state()
	var res: Dictionary = await supabase.fetch_profile()
	if bool(res.get("ok", false)):
		var uname := str(res.get("username", "")).strip_edges()
		if not uname.is_empty():
			if _looks_auto_username(uname):
				# Cloud still holds a generated name. Keep a locally typed nickname
				# and push it up; if the local one is just the built-in default, show
				# the generated one so every device at least agrees.
				if display_name.strip_edges().is_empty() or display_name == "星澜":
					display_name = uname
					_persist_display_name()
				else:
					call_deferred("_push_profile_to_cloud")
				if preview != null:
					preview.display_name = display_name
					preview.suggest_nickname = true
					preview.queue_redraw()
			else:
				# Cloud holds a real nickname: adopt it. This is the path that makes a
				# rename on the phone show up on the PC.
				display_name = uname
				_persist_display_name()
				if preview != null:
					preview.display_name = display_name
					preview.suggest_nickname = false
					preview.queue_redraw()
		# Level and signature are cloud-owned: switching devices must not keep
		# showing whatever signature that device happened to cache. Local edits
		# PATCH the cloud straight away, so an empty cloud value only survives
		# until the first successful save.
		my_level = int(res.get("level", 1))
		var cloud_sig := str(res.get("signature", "")).strip_edges()
		if not cloud_sig.is_empty():
			signature = cloud_sig
		if preview != null:
			preview.my_level = my_level
			preview.signature = signature
			preview.queue_redraw()
		# The avatar lives in Storage, not in this device's user:// folder. Without
		# this, signing in on a second device always shows the default portrait.
		var cloud_avatar := str(res.get("avatar_key", "")).strip_edges()
		print("PROFILE_SYNC level=%d sig_len=%d avatar_key=%s" % [my_level, cloud_sig.length(), cloud_avatar.left(16)])
		if not cloud_avatar.is_empty():
			await _adopt_cloud_avatar(cloud_avatar)
		# 云端刚拉下来的昵称/头像如果晚于进房，也要补到已开的棋盘上。
		if match_scene != null: _apply_local_team()
		profile_sync_state = "ready"
		_apply_profile_sync_state()
	else:
		profile_sync_state = "failed"
		profile_sync_error = _localize_reason(str(res.get("reason", "")))
		_apply_profile_sync_state()
		print("PROFILE_SYNC_FAIL reason=%s" % str(res.get("reason", "")))
		# Silent after the first failure to avoid popup spam.
		if not _profile_sync_failed_once:
			_profile_sync_failed_once = true
			_notice("资料同步失败：%s" % profile_sync_error)

func _profile_sync_text() -> String:
	match profile_sync_state:
		"loading":
			return "正在从云端读取资料…"
		"ready":
			return "已同步 · 云端"
		"failed":
			return "同步失败：%s" % profile_sync_error
	return ""

func _apply_profile_sync_state() -> void:
	if preview == null:
		return
	preview.profile_sync_text = _profile_sync_text()
	preview.queue_redraw()

# Coroutine: push the local display name to the cloud. Defer-only from sync code.
func _push_profile_to_cloud() -> void:
	if supabase == null or not supabase.session_valid():
		# Explicit, not silent: the user must know it only reached the local disk.
		_notice("未登录，昵称只保存在本地")
		return
	if not supabase.has_method("push_profile"):
		return # Safe no-op until the client exposes the method.
	var ok: bool = await supabase.push_profile(display_name, "", signature)
	if not ok:
		print("PROFILE_PUSH_FAIL reason=%s" % supabase.last_profile_error)
		_notice("昵称已保存到本地，云端同步失败：%s" % _profile_write_reason(supabase.last_profile_error))

# Real reasons for a failed profile write, so "sync failed" never hides the cause.
func _profile_write_reason(code: String) -> String:
	match code:
		"http_409", "duplicate":
			return "昵称已被其他账号占用，换一个"
		"no_rows_updated":
			return "云端没有你的资料行"
		"http_403", "http_401":
			return "没有写入权限"
		"no_session":
			return "登录状态失效"
		"refresh_failed":
			return "登录已过期，请重新登录"
	if code.is_empty():
		return "未知错误"
	return _localize_reason(code)

func _auth_identity_label() -> String:
	if not supabase.session_valid():
		return ""
	var nick := display_name.strip_edges()
	if not nick.is_empty():
		return nick
	var uid: String = supabase.current_user_id()
	return uid.substr(0, 8) if uid.length() > 8 else uid

func _confirm_sign_out() -> void:
	# Two choices only: leave or stay. No third "close" row on a destructive action.
	var body := _dialog_frame("退出登录", "退出后需要重新输入邮箱和密码才能回来")
	_dialog_row(body, "确认退出").pressed.connect(_sign_out_action)
	_dialog_row(body, "取消").pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()


func _sign_out_action() -> void:
	_stop_realtime()
	supabase.sign_out()
	my_session_id = ""
	_session_claimed = false
	player_id = ""
	_reset_unread_state()
	# The room still knows the old identity; drop the socket instead of reconnecting
	# as somebody else under a stale session.
	if network_client != null:
		var stale := network_client
		network_client = null
		stale.queue_free()
	# Session just cleared -> section is now "guest"; reload that account's local data.
	_load_profile()
	if preview != null:
		preview.display_name = display_name
		preview.portraits = avatar_textures
		preview.queue_redraw()
	_route("auth")

func _auth_succeeded() -> void:
	# 清掉验证码步骤的临时状态，回到干净的登录页（下次打开不该还停在验证码输入）
	if preview != null:
		preview.auth_step = 0
		preview.auth_otp = ""
		preview.auth_otp_error = ""
		preview.auth_error = ""
	# Switch to the newly signed-in account's section FIRST, so _load_profile reads
	# the new user's nickname/avatar (not the previous account's leftovers).
	_load_profile()
	player_id = supabase.current_user_id() # authoritative identity after load
	_persist_identity()
	# Mint this device's session id and claim the account. A second login
	# overwrites it and the first device is kicked on its next heartbeat.
	my_session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	call_deferred("_claim_my_session")
	# 身份从 guest 换成了真实账号：旧连接还顶着 guest id，必须丢弃重连，
	# 否则房间名单、座位归属、昵称全是上一个身份的。
	if network_client != null:
		network_client.queue_free()
		network_client = null
	if preview != null:
		preview.display_name = display_name
		preview.portraits = avatar_textures
		preview.queue_redraw()
	var dest := pending_route
	if dest.is_empty(): dest = auth_return_page
	if dest.is_empty(): dest = "waiting_room" if not network_url.is_empty() else "lobby"
	_route(dest)
	pending_route = ""
	auth_return_page = ""
	call_deferred("_sync_profile_from_cloud")

# auth 页的控件随时可能在三种形态间切换（已登录 / 验证码 / 邮箱密码），
# 所以抽成独立函数：_route 进入时调一次，auth_step 变化时再调一次。
# 不重建的话旧的邮箱框、密码框会留在原位，和新验证码框叠在一起。
func _build_auth_hotspots() -> void:
	if supabase.session_valid():
		# Signed in: the page must be escapable without logging out.
		_hit(Rect2(400, 84, 120, 56), "返回资料", func(): _route("profile"))
		_hit(Rect2(58, 500, 424, 52), "退出登录", _confirm_sign_out)
		return
	if preview.auth_step == 1:
		var otp_field := _auth_otp_field_create()
		otp_field.text_changed.connect(func(v): preview.auth_otp = v)
		_hit(Rect2(58, 480, 424, 52), "验证并登录", _verify_otp)
		_hit(Rect2(58, 546, 424, 46), "重新发送验证码", _resend_otp)
		_hit(Rect2(58, 600, 424, 46), "返回修改邮箱", _auth_back_to_email)
		return
	var email_field := _auth_input_field("请输入邮箱", 338.0, false)
	# 从验证码页返回时这两个控件会重建，值只存在 preview 里，必须回填，
	# 否则画面上的邮箱是空的、但 preview.auth_email 还留着旧值，改起来对不上。
	email_field.text = str(preview.auth_email)
	email_field.set_caret_column(email_field.text.length())
	email_field.text_changed.connect(func(v): preview.auth_email = v)
	var pwd_field := _auth_input_field("请输入密码", 440.0, true)
	pwd_field.text = str(preview.auth_password)
	pwd_field.set_caret_column(pwd_field.text.length())
	pwd_field.text_changed.connect(func(v): preview.auth_password = v)
	_hit(Rect2(58, 540, 424, 52), "登录注册主按钮", _do_auth)
	_hit(Rect2(58, 606, 424, 46), "切换注册登录", _toggle_auth_mode)

func _refresh_auth_page() -> void:
	_clear(hotspot_layer)
	if page == "auth":
		_build_auth_hotspots()
	# 登录页在"邮箱密码"和"验证码"之间切换时要同步换 DOM 输入框，
	# 否则验证码那一屏点上去弹的还是邮箱键盘。
	_notify_web_vk_page()
	if preview != null:
		preview.queue_redraw()

func _do_auth() -> void:
	if _login_started_ms >= 0: return
	_web_vk_blur()
	var email: String = str(preview.auth_email).strip_edges()
	var password: String = str(preview.auth_password)
	if email.is_empty() or password.is_empty():
		preview.auth_error = "请输入邮箱和密码"
		preview.queue_redraw()
		return
	preview.auth_error = ""
	preview.queue_redraw()
	if preview.auth_mode == 0:
		_login_started_ms = Time.get_ticks_msec()
		preview.auth_progress = "正在登录..." if SettingsStore.reduce_motion else "正在登录."
		preview.queue_redraw()
		var login: Dictionary = await supabase.sign_in_with_result(email, password)
		_login_started_ms = -1
		preview.auth_progress = ""
		if bool(login.get("ok", false)):
			_auth_succeeded()
		else:
			preview.auth_error = _login_error_text(login)
			preview.queue_redraw()
		return
	# 注册：三种结果必须分开处理，否则开启邮箱确认后会被误判成失败
	var result: Dictionary = await supabase.sign_up_with_status(email, password)
	match str(result.get("status", "error")):
		"session":
			_auth_succeeded()
		"pending_confirmation":
			preview.auth_step = 1
			preview.auth_pending_email = str(result.get("email", email))
			preview.auth_otp = ""
			preview.auth_otp_error = ""
			_start_resend_cooldown(60)
			_web_vk_clear("otp")
			_refresh_auth_page()
		_:
			preview.auth_error = "注册失败：%s" % _auth_reason_text(str(result.get("reason", "unknown")))
			_refresh_auth_page()

func _login_error_text(result: Dictionary) -> String:
	var reason := str(result.get("reason", "")).strip_edges().to_lower()
	var error_code := str(result.get("error_code", "")).strip_edges().to_lower()
	var status := int(result.get("code", 0))
	if status == 429 or error_code == "over_request_rate_limit":
		return "登录请求太频繁，请稍后再试"
	if status in [408, 504] or error_code == "request_timeout":
		return "登录服务响应超时，请重试"
	if status >= 500:
		return "登录服务暂不可用（HTTP %d）" % status
	if error_code == "invalid_credentials" or reason == "invalid login credentials":
		return "邮箱或密码错误"
	if error_code == "email_not_confirmed" or reason == "email not confirmed":
		return "邮箱尚未验证，请先完成邮箱验证"
	match error_code:
		"user_banned": return "该账号已被暂停登录"
		"captcha_failed": return "登录安全验证未通过"
		"email_provider_disabled", "provider_disabled": return "邮箱密码登录暂未开放"
		"email_address_invalid", "validation_failed": return "邮箱或登录信息格式不正确"
	if reason.begins_with("network_error:"):
		match int(reason.get_slice(":", 1)):
			HTTPRequest.RESULT_TIMEOUT: return "连接登录服务超时，请重试"
			HTTPRequest.RESULT_CANT_RESOLVE: return "无法解析登录服务地址"
			HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: return "登录服务的安全连接失败"
			HTTPRequest.RESULT_BODY_DECOMPRESS_FAILED, HTTPRequest.RESULT_CHUNKED_BODY_SIZE_MISMATCH:
				return "登录服务响应不完整，请重试"
		return "无法连接登录服务，请检查网络"
	if reason.begins_with("request_failed:") or reason == "no_scene_tree":
		return "登录请求未能发出，请刷新后重试"
	if reason in ["invalid_json", "invalid_auth_response", "missing_auth_fields"]:
		return "登录服务返回的信息不完整"
	if status > 0:
		return "登录服务拒绝请求（HTTP %d）" % status
	return "登录未完成，请重试"

# 把 Supabase 的英文错误码转成能看懂的提示
func _auth_reason_text(reason: String) -> String:
	var lowered := reason.to_lower()
	if lowered.contains("already registered") or lowered.contains("user already exists"):
		return "这个邮箱已经注册过，请直接登录"
	if lowered.contains("password") and (lowered.contains("weak") or lowered.contains("short")):
		return "密码太短，至少 6 位"
	if lowered.contains("invalid") and lowered.contains("email"):
		return "邮箱格式不正确"
	if lowered.contains("rate limit") or lowered.contains("too many"):
		return "操作太频繁，请稍后再试"
	if lowered.is_empty():
		return "未知错误，请稍后再试"
	return reason

func _auth_otp_field_create() -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = "邮件里的验证码"
	field.position = Vector2(58, 330)
	field.size = Vector2(424, 56)
	# Supabase 的 Email OTP Length 决定位数（当前项目为 8），这里留到 12 兼容改配置
	field.max_length = 12
	field.add_theme_font_size_override("font_size", 32)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	field.add_theme_stylebox_override("normal", box)
	field.add_theme_stylebox_override("focus", box)
	field.add_theme_color_override("font_color", Color("f5f5f7"))
	field.add_theme_color_override("font_placeholder_color", Color("5c5c61"))
	field.add_theme_color_override("caret_color", Color("6fd3e8"))
	hotspot_layer.add_child(field)
	_attach_caret_hint(field, "otp")
	# The gateway input for OTP is type=text, so focusin reports "text".
	_caret_fields["text"] = field
	auth_otp_field = field
	return field

func _verify_otp() -> void:
	_web_vk_blur()
	# 验证码按字符串处理，前导零不能丢
	var code := str(preview.auth_otp).strip_edges()
	if code.length() < 4:
		preview.auth_otp_error = "请输入邮件里的验证码"
		preview.queue_redraw()
		return
	preview.auth_otp_error = "验证中…"
	preview.queue_redraw()
	var result: Dictionary = await supabase.verify_signup_otp(preview.auth_pending_email, code)
	if bool(result.get("ok", false)):
		preview.auth_step = 0
		preview.auth_otp = ""
		preview.auth_otp_error = ""
		_web_vk_clear("otp")
		_auth_succeeded()
		return
	var reason := str(result.get("reason", ""))
	var lowered := reason.to_lower()
	# Supabase 对"输错"和"过期"返回同一句 "Token has expired or is invalid"，
	# 有意不区分（防枚举）。这里不能假装能分辨，只能给一句同时成立的话。
	if lowered.contains("expired") or lowered.contains("invalid") or lowered.contains("token"):
		preview.auth_otp_error = "验证码不正确或已过期，请核对后重试，或点下方重发"
	elif lowered.contains("rate limit") or lowered.contains("too many"):
		preview.auth_otp_error = "尝试太频繁，等一分钟再试"
	elif lowered.contains("network") or lowered.contains("request_failed"):
		preview.auth_otp_error = "网络不通，检查连接后重试"
	else:
		preview.auth_otp_error = "验证失败：%s" % reason
	preview.queue_redraw()

func _resend_otp() -> void:
	if preview.auth_resend_wait > 0:
		_notice("请等待 %d 秒后再重发" % preview.auth_resend_wait)
		return
	preview.auth_otp_error = "正在重发…"
	preview.queue_redraw()
	var result: Dictionary = await supabase.resend_signup_otp(preview.auth_pending_email)
	if bool(result.get("ok", false)):
		preview.auth_otp_error = ""
		_start_resend_cooldown(60)
		# 200 只代表 Supabase 受理了请求，不代表邮件真的送达（SMTP 退信不会回传到客户端）。
		# 所以这里不写"已发送"，只如实说"已请求"。
		_notice("已请求重发，请检查收件箱和垃圾箱")
	else:
		preview.auth_otp_error = "重发失败：%s" % _auth_reason_text(str(result.get("reason", "")))
		preview.queue_redraw()

func _auth_back_to_email() -> void:
	preview.auth_step = 0
	preview.auth_otp = ""
	preview.auth_otp_error = ""
	preview.auth_error = ""
	_web_vk_clear("otp")
	_refresh_auth_page()

func _start_resend_cooldown(seconds: int) -> void:
	preview.auth_resend_wait = seconds
	if auth_resend_timer == null:
		auth_resend_timer = Timer.new()
		auth_resend_timer.wait_time = 1.0
		auth_resend_timer.timeout.connect(func():
			if preview.auth_resend_wait > 0:
				preview.auth_resend_wait -= 1
				preview.queue_redraw()
		)
		add_child(auth_resend_timer)
	auth_resend_timer.start()
	preview.queue_redraw()

func _toggle_auth_mode() -> void:
	if _login_started_ms >= 0: return
	preview.auth_mode = 1 - preview.auth_mode
	preview.auth_error = ""
	# 重建控件以便输入框 placeholder 与按钮文案跟着模式变
	_refresh_auth_page()

func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(profile_file) == OK:
		var section := _profile_section()
		var migrated := _migrate_profile_section(cfg)
		var changed := migrated
		# Fixed defaults (not current values) so a different account's name never leaks.
		display_name = str(cfg.get_value(section, "name", "星澜"))
		signature = str(cfg.get_value(section, "signature", "在群星之间，等待下一次碰撞。"))
		player_id = str(cfg.get_value(section, "player_id", ""))
		my_avatar_key = str(cfg.get_value(section, "avatar_key", ""))
		# Only mint a random id for guests; logged-in identity comes from supabase.
		if player_id.is_empty() and section == "guest":
			player_id = Crypto.new().generate_random_bytes(16).hex_encode()
			cfg.set_value(section, "player_id", player_id)
			changed = true
		if changed:
			cfg.save(profile_file)
	var avatar := _avatar_path()
	if FileAccess.file_exists(avatar):
		var img: Image = Image.load_from_file(avatar)
		if img != null and not img.is_empty(): avatar_textures[0] = ImageTexture.create_from_image(img)

func _save_profile() -> void:
	var name_value := profile_name_input.text.strip_edges()
	if name_value.length() < 2 or name_value.length() > 12:
		_notice("昵称需为 2–12 个字符")
		return
	display_name = name_value
	signature = profile_signature_input.text.strip_edges()
	var cfg := ConfigFile.new()
	cfg.load(profile_file) # Load first so other accounts' sections are preserved.
	var section := _profile_section()
	_migrate_profile_section(cfg)
	cfg.set_value(section, "name", display_name)
	cfg.set_value(section, "signature", signature)
	if player_id.is_empty(): player_id = Crypto.new().generate_random_bytes(16).hex_encode()
	cfg.set_value(section, "player_id", player_id)
	var error := cfg.save(profile_file)
	if error != OK:
		_notice("本地资料保存失败（%d）" % error)
		return
	profile_changed.emit(display_name)
	# Coroutine push must be deferred; _save_profile stays synchronous for the click handler.
	if supabase.session_valid():
		call_deferred("_push_profile_to_cloud")
	if not network_url.is_empty():
		# 保存资料后按"有房间号进那一桌、没有就去大厅"决定，别在没房间号时硬连
		# （不带 ?room= 会被网关分流到 rooms[0]，可能直接进错桌）。
		_enter_room_or_lobby()
		return
	if not pending_invite.is_empty():
		room_label = "邀请房间 #%s" % pending_invite
		room_is_host = false
		pending_invite = ""
		_route("waiting_room")
	else:
		_route("lobby" if page.begins_with("first_profile") else "profile")

func _clear(node: Node) -> void:
	# The chat invite overlays live in hotspot_layer. Once the layer is rebuilt,
	# the old signature must not make _refresh_chat_invite_hits skip recreating
	# them — reopening a conversation would otherwise leave a dead invite bubble.
	if node == hotspot_layer:
		_chat_hits_signature = ""
		_chat_invite_hits.clear()
		# 观战席加号常驻：清了热区就必须忘掉旧引用，等下次绑定重建，
		# 不然会抱着一个已经 queue_free 的按钮（is_instance_valid 仍为真）。
		_spectator_plus_hit = null
	# Closing a dialog must also drop the DOM inputs laid over its fields,
	# otherwise an invisible <input> keeps stealing taps on mobile.
	if node == dialog_layer:
		if is_instance_valid(_room_music_panel):
			_room_music_panel = null
			_room_music_eval("gesture(null)")
		_web_dyn_hide_all()
		_web_dyn_fields.clear()
		call_deferred("_sync_web_match_chat")
		# 好友私聊的覆盖层在弹层打开时被藏起来了，关掉后要放回来
		call_deferred("_sync_web_friend_chat")
	# Forget caret registrations that lived under the node being cleared.
	for key in _caret_fields.keys():
		var registered: Variant = _caret_fields[key]
		if not (registered is LineEdit):
			_caret_fields.erase(key)
			continue
		var field: LineEdit = registered
		if not is_instance_valid(field) or node.is_ancestor_of(field):
			_caret_fields.erase(key)
	_active_caret_field = null
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
	if node == dialog_layer and node.get_parent() == music_modal_layer:
		dialog_layer.reparent(self, false)
		move_child(dialog_layer, hotspot_layer.get_index() + 1)
		dialog_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Hand the caret to whoever is still alive, so a page never goes caret-less.
	for key in _caret_fields.keys():
		var remaining: Variant = _caret_fields[key]
		if remaining is LineEdit and is_instance_valid(remaining):
			_set_active_caret(remaining)
			break

func _route(next_page: String) -> void:
	# 记住"从哪里点进登录页的"，登录成功后按原路返回。
	if next_page == "auth" and page != "auth" and page != "match":
		auth_return_page = page
	# 单机模式借的是"等待房"这一屏，但不联网：不需要房间号，也不要求登录。
	var solo_local := solo_room and next_page == "waiting_room"
	# Leaving the room (match start, lobby, result) must not leave the invite
	# window floating over the next page.
	if next_page != "waiting_room" and invite_panel_open:
		_end_invite_panel()
	# 没有房间号就进等待房，WS 会不带 ?room= 连到网关的 rooms[0]——那可能是别人的桌，
	# 表现就是"两个人各自在房间里等"。宁可退到大厅选桌，也不静默进错房间。
	if next_page == "waiting_room" and not solo_local and not network_url.is_empty() and room_code.is_empty():
		next_page = "lobby"
	if page == "match" and next_page != "match" and match_scene != null:
		_match_leave_pending = false
		_hide_web_match_chat()
		_stop_solo_loop()
		match_scene.cancel_local_aim()
		match_scene.clear_network_aim()
		match_scene.process_mode = Node.PROCESS_MODE_DISABLED
		match_scene.visible = false
		match_scene.formal_hud.hide()
		match_ui.visible = false
	# Auth guard: protected pages need a valid session, else divert to auth and
	# remember the destination. auth/match/result_flow/first_profile* are not guarded.
	# profile/badges stay open so the account entry is reachable while logged out.
	# waiting_room 也在守卫内：房间必须是真实账号身份，guest 路径已彻底关闭。
	if next_page in ["waiting_room", "friends", "chat", "lobby"] and not solo_local and require_account_gate and not supabase.session_valid():
		pending_route = next_page
		_route("auth")
		return
	page = next_page
	# The music room lives as long as "this player is still in this match". Online
	# compares room_code; solo has no room_code, so it keys off solo_room — otherwise
	# the first frame of the match would look like a room change and disconnect us.
	if not _room_music_room.is_empty():
		var keep_music := page in ["waiting_room", "match", "result_flow"]
		if _room_music_solo:
			keep_music = keep_music and solo_room
		else:
			keep_music = keep_music and room_code == _room_music_room
		if not keep_music:
			_leave_room_music()
	if chat_poll_timer != null and next_page != "chat":
		chat_poll_timer.stop()
	if next_page != "chat":
		_hide_web_friend_chat()
	# Unread badge: poll only while a page that draws the bottom bar is open.
	# Entering such a page refreshes immediately instead of waiting one tick.
	if unread_poll_timer != null:
		if page in UNREAD_PAGES and supabase != null and supabase.session_valid():
			if unread_poll_timer.is_stopped():
				unread_poll_timer.start()
			call_deferred("_refresh_unread")
		else:
			unread_poll_timer.stop()
	# 大厅里每 3 秒拉一次房间列表；离开大厅就停，别在房间里空转
	if next_page == "lobby":
		_start_room_poll()
	elif room_poll_timer != null:
		room_poll_timer.stop()
	# 通知页面层的 DOM 输入代理显示/隐藏（移动端软键盘靠它，不依赖 Godot 的 virtual_keyboard_show）
	_notify_web_vk_page()
	# Every navigation is a user action: check right away whether another device
	# has taken the account over, instead of waiting for the 5s timer.
	_check_session_now()
	preview.visible = next_page != "match"
	preview.page = next_page
	preview.display_name = display_name
	preview.signature = signature
	preview.room_ready = local_ready
	preview.room_opponent_ready = opponent_ready
	preview.room_blue_name = _team_name(0)
	preview.room_red_name = _team_name(1)
	preview.room_label = room_label
	preview.room_is_host = room_is_host
	preview.room_is_solo = solo_room
	preview.room_list_error = room_list_error
	preview.match_mode = match_mode
	preview.room_intro = room_intro
	preview.room_phase = room_phase
	var connecting: bool = network_client != null and not network_client.connected
	preview.room_connecting = connecting
	preview.room_spectator = not connecting and network_client != null and local_role == "spectator"
	preview.room_spectators = room_spectators
	preview.room_spectator_scroll = spectator_scroll
	# View index of my own seat: 2p = blue(0)/red(1); 4p = my slot. -1 when unknown/spectating.
	if network_client != null and local_role == "spectator":
		preview.local_seat = -1
	elif match_mode == 1:
		preview.local_seat = local_slot
	else:
		preview.local_seat = 0 if local_team == 0 else 1
	preview.chat_messages = chat_messages
	preview.chat_state = chat_state
	preview.chat_last_error = chat_last_error
	preview.chat_self_id = supabase.current_user_id() if supabase != null else ""
	preview.unread_by_friend = unread_by_friend
	preview.invite_url = invite_url
	preview.my_level = my_level
	preview.view_player_name = view_player_name
	preview.view_player_signature = view_player_signature
	preview.view_player_level = view_player_level
	preview.view_player_state = view_player_state
	preview.view_player_error = view_player_error
	preview.view_player_relation = view_player_relation
	preview.view_player_portrait = view_player_portrait
	preview.auth_signed_in = supabase.session_valid()
	preview.auth_identity = _auth_identity_label()
	preview.account_email = supabase.account_email()
	if supabase.session_valid():
		preview.account_uid_short = supabase.current_user_id().left(8).to_upper()
	else:
		preview.account_uid_short = ""
	preview.profile_sync_text = _profile_sync_text()
	if next_page == "result_flow" and match_scene != null:
		preview.result_names = match_scene.formal_hud.player_names
		preview.result_portraits = match_scene.formal_hud.player_portraits
	preview.queue_redraw()
	_clear(hotspot_layer)
	_clear(dialog_layer)
	# 热区节点刚被全部释放，签名也要作废：否则在大厅里再点一次"房间列表"
	# 会因为"列表没变"跳过重建，整排房间行就点不动了。
	lobby_room_buttons.clear()
	lobby_room_signature = ""
	if next_page == "match":
		_start_match()
		return
	if next_page in ["lobby", "friends", "chat", "profile", "badges"]: _tabs()
	# Invited room: connect on entry, so signing in first gives the room the right
	# identity instead of the guest one we used before login.
	if next_page == "waiting_room" and not solo_local and not network_url.is_empty() and network_client == null:
		_connect_network()
	match next_page:
		"auth":
			preview.auth_error = ""
			_build_auth_hotspots()
		"first_profile", "first_profile_invite", "edit_profile": _profile_form()
		"lobby":
			# 三按钮：单人模式在最左（本地热座测试，不联网），真人对战仍是主按钮
			_hit(Rect2(20, 257, 156, 53), "单人模式（本地热座）", _enter_solo_room)
			_hit(Rect2(192, 257, 156, 53), "创建私人房间", _create_room)
			_hit(Rect2(364, 257, 156, 53), "输入房间号", _join_dialog)
			_bind_lobby_room_hits()
		"friends":
			_build_friends_hotspots()
			# Coroutines: deferred from this sync router, never called bare.
			call_deferred("_heartbeat_tick", false)
			call_deferred("_refresh_friend_data")
		"chat": _chat_field()
		"profile":
			_hit(Rect2(20, 180, 500, 160), "编辑个人资料", func(): _route("edit_profile"))
			_hit(Rect2(20, 400, 500, 56), "账号登录", func(): _route("auth"))
			if supabase.session_valid():
				_hit(Rect2(20, 460, 500, 56), "修改密码", _change_password_dialog)
			# Opening the profile re-pulls cloud data (nickname, signature, level and
			# the avatar from Storage), so a change made on another device shows up.
			call_deferred("_sync_profile_from_cloud")
		"badges": _hit(Rect2(20, 160, 500, 560), "预览升级弹窗", func(): _route("level_up"))
		"player_profile": _build_player_profile_hotspots()
		"level_up": _hit(Rect2(123, 593, 294, 43), "收下奖励预览", func(): _route("profile"))
		"waiting_room":
			_hit(Rect2(416, 24, 104, 88), "离开房间", _leave_room)
			if solo_room:
				# 单机：没有邀请、没有模式切换、没有对手资料、没有房间聊天，
				# 只留"准备并开始"和"离开"，点一下就进本地热座。
				_hit(Rect2(20, 860, 500, 88), "准备并开始单机对局", _ready_or_start)
			else:
				# 坐标来自 AppShellPreviewV1 的等待房绘制：观战席与邀请等宽并排。
				_hit(PREVIEW.INVITE_RECT, "邀请好友", _invite_friend)
				if room_is_host:
					_hit(Rect2(20, 124, 500, 40), "编辑房间介绍", _edit_room_intro, 44)
					_hit(Rect2(20, 256, 245, 88), "切换为双人模式", func(): _set_match_mode(0))
					_hit(Rect2(275, 256, 245, 88), "切换为四人模式", func(): _set_match_mode(1))
				else:
					# 非房主：模式是只读的；点了给出明确原因，而不是一个没反应的死区。
					_hit(Rect2(20, 256, 500, 88), "模式由房主设置", func(): _notice("只有房主可以修改模式和房间介绍"))
				if network_client != null: _hit(Rect2(300, 20, 100, 44), "网络诊断", _network_diagnostics)
				_bind_room_seat_hits()
				_bind_spectator_strip_hits()
				# 全员就绪时服务端正在开局：这一条不再挂热区，避免"点了没反应"。
				# 观众没有参赛席，底部是纯说明，不给假按钮；socket 未就绪时也一样。
				var room_connecting: bool = network_client != null and not network_client.connected
				if network_client == null or not _room_all_ready():
					if not room_connecting and not (network_client != null and local_role == "spectator"):
						_hit(Rect2(20, 860, 500, 88), "取消准备" if local_ready else "准备", _primary_room_action)
				_build_room_chat()
		"result_flow":
			_hit(Rect2(94, 488, 352, 46), "返回等待房间", _back_to_room)
			# 离开房间必须走 _leave_room：直接 _route("lobby") 会把 WS 留在旧桌上，
			# 下次建房/进桌时 _connect_network 看见 client 非空就不重连了。
			_hit(Rect2(300, 610, 120, 110), "离开房间返回大厅", _leave_room)
		"join_error": _hit(Rect2(123, 525, 294, 43), "返回房间列表", _leave_room)
	# 退出对局这件事要一句说明，但它必须活过紧随其后的重绘：
	# 宿主的 room 广播会让 waiting_room 再 _route 一次，而 _route 会清弹层。
	# 所以提示挂在这里，页面建完再弹；2.5 秒内允许被下一次重绘重新挂上，
	# 超过就丢掉，避免用户关掉之后又被旧提示弹一次。
	if page == "waiting_room" and not _pending_room_notice.is_empty():
		if Time.get_ticks_msec() <= _pending_room_notice_until:
			_notice(_pending_room_notice)
		else:
			_pending_room_notice = ""

# A seat binds its ready hotspot only when occupied. In local hotseat the slot
# name array is empty and default names apply, so every seat stays occupied.
func _seat_occupied(seat_view_index: int) -> bool:
	if preview == null:
		return true
	var slot_index: int = preview.seat_slot_for_row(seat_view_index)
	if slot_index >= 0 and slot_index < preview.room_slot_names.size():
		return not preview.room_slot_names[slot_index].is_empty()
	return true


# --- 等待房：自由入座 / 退到观战 / 观战抽屉 / 房间介绍 -----------------------
func _seat_caption(slot: int) -> String:
	var team := "蓝队" if slot < 2 else "红队"
	return "%s %d 号位" % [team, (slot % 2) + 1]


func _bind_room_seat_hits() -> void:
	if preview == null:
		return
	var my_id := _network_identity()
	for row in range(2 if match_mode == 0 else 4):
		var slot: int = preview.seat_slot_for_row(row)
		if slot < 0:
			continue
		var y: float = 360.0 + float(row) * 88.0
		var occupant := _occupant_for_slot(slot)
		var pid := str(occupant.get("player_id", ""))
		if pid.is_empty():
			# 空位：整行可点，直接入座或换到这一队。
			_hit(Rect2(20, y, 500, 88), "入座 %s" % _seat_caption(slot), func(): _claim_seat(slot))
		elif pid == my_id:
			# 自己的座位：整行打开小菜单（准备 / 让座），不抢底部主按钮。
			_hit(Rect2(20, y, 500, 88), "我的座位", _open_my_seat_dialog)
		else:
			# 别人的座位：点头像看资料；点行内空白只解释规则，绝不挤走别人。
			var who := str(occupant.get("name", "玩家"))
			_hit(Rect2(36, y + 16, 56, 56), "查看玩家资料", func(): _open_player_profile(pid, who), 0)
			_hit(Rect2(108, y, 412, 88), "这个位置已经有人了",
				func(): _notice("这个位置已经有人了。等他让座，或先到观战席"), 0)


func _claim_seat(slot: int) -> void:
	if network_client == null:
		return
	if not network_client.connected:
		_notice("还在连接房间，请稍候")
		return
	if local_role == "player" and local_slot == slot:
		return
	network_client.send_seat(slot)


func _open_my_seat_dialog() -> void:
	if local_role != "player" or local_slot < 0:
		return
	_open_dialog("我的座位", _seat_caption(local_slot), [
		{"label": "取消准备" if local_ready else "准备", "action": func(): _clear(dialog_layer); _toggle_ready()},
		{"label": "退到观战席", "action": _become_spectator},
	])


func _become_spectator() -> void:
	if network_client == null:
		return
	network_client.send_spectate()
	_clear(dialog_layer)


func _edit_room_intro() -> void:
	if network_client == null or not room_is_host:
		_notice("只有房主可以修改房间介绍")
		return
	var field := _text_dialog("房间介绍", "最多 40 字，房主保存后同步到大厅", "比如：新手友好，随便打")
	field.text = room_intro
	field.max_length = 40
	_dialog_button("保存介绍", func():
		if network_client == null:
			return
		network_client.send_intro(field.text.strip_edges())
		_clear(dialog_layer)
	)


func _clear_spectator_plus_hit() -> void:
	if _spectator_plus_hit != null and is_instance_valid(_spectator_plus_hit):
		_spectator_plus_hit.queue_free()
	_spectator_plus_hit = null


# 观战席常显，只有一个可点目标：条内最右端的空心加号。
# 参赛者点它让座转观众（服务端 spectate）；观众点它没有可去的座位，
# 但也不能没反应，直接说明入座要走下面的空位。
#
# 这个按钮只建一次、位置永不变：以前它跟着名单尾部走，名单一变就要重建，
# 手指按下的那一帧正好重建时点击会落到别的控件上（甚至弹出一张玩家资料卡）。
# 现在位置由条带几何算，身份在按下的瞬间才读，名单怎么变都只可能走到同一个入口。
func _bind_spectator_strip_hits() -> void:
	if page != "waiting_room" or preview == null or solo_room:
		_clear_spectator_plus_hit()
		return
	var rect := _spectator_plus_rect()
	# hotspot_layer 每次换页都会被清空；被 queue_free 的旧引用仍算"有效"，
	# 必须连父节点一起校验，否则会一直抱着一个已经不在树上的死按钮。
	if _spectator_plus_hit == null or not is_instance_valid(_spectator_plus_hit) \
			or _spectator_plus_hit.is_queued_for_deletion() \
			or _spectator_plus_hit.get_parent() != hotspot_layer:
		_spectator_plus_hit = _hit(rect, "观战席加号", _on_spectator_plus_pressed, 0)
	_spectator_plus_hit.position = rect.position
	_spectator_plus_hit.size = rect.size
	# 连接还没建立/正在连接：加号不画，热区也一起停用，绝不留一张点了没反应的透明按钮。
	var live: bool = network_client != null and network_client.connected and not preview.room_connecting
	_spectator_plus_hit.visible = live
	_spectator_plus_hit.mouse_filter = Control.MOUSE_FILTER_STOP if live else Control.MOUSE_FILTER_IGNORE


func _on_spectator_plus_pressed() -> void:
	if page != "waiting_room" or solo_room or preview == null:
		return
	if network_client == null or not network_client.connected:
		_notice("还在连接房间，请稍候")
		return
	# 身份在读这一行时才判定：落座/起身都由服务端裁定，不能用点下去之前的缓存。
	if local_role != "player":
		_notice("你已经在观战席 · 点下方空位入座")
		return
	_become_spectator()


# 加号格的屏幕位置：条内最右 60px 固定一格，不随名单长度和滚动偏移移动。
func _spectator_plus_rect() -> Rect2:
	var strip: Rect2 = PREVIEW.SPECTATOR_STRIP
	return Rect2(strip.end.x - PREVIEW.SPECTATOR_PLUS_ZONE, strip.position.y,
		PREVIEW.SPECTATOR_PLUS_ZONE, strip.size.y)


func _spectator_scroll_max() -> float:
	return PREVIEW.spectator_max_scroll(room_spectators.size())


# 对局页观众气泡的滚动范围：展开后由 HUD 按头像数算，收起时不可滚。
# 几何只信 HUD 一处，页面层不再自己算一遍宽度。
func _match_spectator_scroll_max() -> float:
	if match_scene == null or match_scene.formal_hud == null:
		return 0.0
	return match_scene.formal_hud.spectator_max_scroll()


# 当前气泡的屏幕矩形（收起 52×52 / 展开 184×52），由 HUD 给出。
func _match_spectator_rect() -> Rect2:
	if match_scene == null or match_scene.formal_hud == null:
		return Rect2()
	return match_scene.formal_hud.spectator_strip_rect()


# 观众名单推给对局 HUD。参赛者和观众都渲染同一份 HUD，天然都能看到；
# 对局只展示，不挂任何点击热区（换席只在等待房）。
func _push_match_spectators() -> void:
	if match_scene == null: return
	var hud: Control = match_scene.formal_hud
	if hud == null: return
	if hud.has_method("set_spectator_rows"):
		hud.set_spectator_rows(room_spectators)
	if hud.has_method("set_spectator_expanded"):
		hud.set_spectator_expanded(match_spectator_expanded)
	if hud.has_method("set_spectator_scroll"):
		hud.set_spectator_scroll(match_spectator_scroll)


# 点一下气泡：收起 ↔ 展开。零观众也能展开（空态写明"暂无观众"），
# 收起时把横滑归零，下次展开仍从最左边第一个头像开始。
func _toggle_match_spectators() -> void:
	match_spectator_expanded = not match_spectator_expanded
	if not match_spectator_expanded:
		match_spectator_scroll = 0.0
	_push_match_spectators()


func _scroll_spectators(delta: float) -> void:
	var next := clampf(spectator_scroll + delta, 0.0, _spectator_scroll_max())
	if is_equal_approx(next, spectator_scroll):
		return
	spectator_scroll = next
	preview.room_spectator_scroll = spectator_scroll
	preview.queue_redraw()
	# 加号已经固定在条内最右端，滚动不需要也不允许再动它的热区。


func _hit(rect: Rect2, label: String, action: Callable, min_touch_h: float = 66.0) -> Button:
	var button := Button.new()
	button.text = ""
	button.tooltip_text = label
	button.accessibility_name = label
	var touch_rect := rect
	if min_touch_h > 0.0 and touch_rect.size.y < min_touch_h:
		var extra: float = min_touch_h - touch_rect.size.y
		touch_rect.position.y -= extra * 0.5
		touch_rect.size.y = min_touch_h
	button.position = touch_rect.position
	button.size = touch_rect.size
	button.focus_mode = Control.FOCUS_NONE
	button.modulate.a = 0.0
	button.pressed.connect(action)
	hotspot_layer.add_child(button)
	return button

# 大厅里真正要显示的房间（备胎 open=false，不出现）。
func _lobby_visible_rooms() -> Array:
	var out: Array = []
	if preview == null: return out
	for r in preview.room_list:
		if bool(r.get("open", false)) or int(r.get("players", 0)) > 0:
			out.append(r)
	return out

func _lobby_max_scroll() -> float:
	var total := float(_lobby_visible_rooms().size()) * LOBBY_ROW_H
	var view := LOBBY_LIST_BOTTOM - LOBBY_LIST_TOP
	return maxf(0.0, total - view + 16.0)

func _scroll_lobby(delta: float) -> void:
	var next := clampf(lobby_scroll + delta, 0.0, _lobby_max_scroll())
	if is_equal_approx(next, lobby_scroll): return
	lobby_scroll = next
	_sync_lobby_scroll()

func _sync_lobby_scroll() -> void:
	if preview != null:
		preview.lobby_scroll = lobby_scroll
		preview.queue_redraw()
	_layout_lobby_buttons()

# 行按钮一次性全建好（含屏幕外的），滚动时只改 y 和可见性，
# 不重建节点——重建会打断正在按下的手指，也每帧分配一堆 Button。
func _layout_lobby_buttons() -> void:
	for b in lobby_room_buttons:
		if not is_instance_valid(b): continue
		var row := int(b.get_meta("row", 0))
		var y := LOBBY_LIST_TOP + float(row) * LOBBY_ROW_H - lobby_scroll
		b.position.y = y
		var on_screen: bool = (y + 88.0 > LOBBY_LIST_TOP - 8.0) and (y < LOBBY_LIST_BOTTOM)
		b.visible = on_screen
		b.mouse_filter = Control.MOUSE_FILTER_STOP if on_screen else Control.MOUSE_FILTER_IGNORE

func _input(event: InputEvent) -> void:
	if preview == null: return
	if page == "lobby":
		_handle_lobby_scroll(event)
		return
	# 弹层打开时不要把事件吞在顶栏里：遮罩要靠点空白处关闭。
	var dialog_open := dialog_layer != null and dialog_layer.get_child_count() > 0
	if page == "waiting_room" and not solo_room:
		if dialog_open: return
		# 横滑起点只认头像区：条内最右的加号是独立控件，在它上面按下去不该滚动名单。
		var strip: Rect2 = PREVIEW.SPECTATOR_STRIP
		var scroll_area := Rect2(strip.position,
			Vector2(strip.size.x - PREVIEW.SPECTATOR_PLUS_ZONE, strip.size.y))
		_handle_spectator_strip_scroll(event, false, scroll_area)
		return
	if page == "match" and match_scene != null:
		if dialog_open: return
		# 观众席气泡：收起/展开都要响应，零观众也要能点开看空态。
		# 轻点 = 收起/展开；横滑 = 翻名单（只在展开时真的有得翻）。
		_handle_spectator_strip_scroll(event, true, _match_spectator_rect(), _toggle_match_spectators)


# 横滑条手势：等待房观战席与对局观众名单共用一套判定。
# 按下点必须落在条带内并且当场吞掉：不吞的话棋盘也会收到同一次按下，
# 变成"滑动观众名单时顺手开了一杆瞄准"，松手还要再点一次才能真正出杆。
# 横移超过 10px 才算拖动并吞事件，松手时再吞一次，避免手指划过加号或棋盘时误触。
# on_tap 只在"按下又在原地松手"时触发（对局里用它切换气泡展开状态）。
func _handle_spectator_strip_scroll(event: InputEvent, on_match: bool, area: Rect2, on_tap := Callable()) -> void:
	if event is InputEventMouseButton and event.pressed and area.has_point(event.position):
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll_strip(-SPECTATOR_WHEEL_STEP, on_match)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll_strip(SPECTATOR_WHEEL_STEP, on_match)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		if event.pressed:
			_strip_press_x = event.position.x if area.has_point(event.position) else -1.0
			_strip_press_y = event.position.y
			_strip_last_x = event.position.x
			_strip_dragging = false
			if _strip_press_x >= 0.0:
				get_viewport().set_input_as_handled()
			return
		if _strip_dragging:
			_snap_strip(on_match)
			get_viewport().set_input_as_handled()
		elif _strip_press_x >= 0.0:
			# 轻点不滚动，但把停下来的位置吸回整格，边缘不会留半张脸。
			_snap_strip(on_match)
			# 只有"原地松手"才算轻点：纵向甩出去的拖动不该顺手把气泡折叠掉。
			if on_tap.is_valid() and absf(event.position.y - _strip_press_y) < 24.0:
				on_tap.call()
		_strip_dragging = false
		_strip_press_x = -1.0
		return
	var dx := 0.0
	if event is InputEventScreenDrag:
		dx = event.position.x - _strip_last_x
		_strip_last_x = event.position.x
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		dx = event.position.x - _strip_last_x
		_strip_last_x = event.position.x
	if dx == 0.0 or _strip_press_x < 0.0: return
	if not _strip_dragging and absf(_strip_last_x - _strip_press_x) > 10.0:
		_strip_dragging = true
	if not _strip_dragging: return
	_scroll_strip(-dx, on_match)
	get_viewport().set_input_as_handled()


func _strip_scroll_max(on_match: bool) -> float:
	if on_match:
		return _match_spectator_scroll_max()
	return _spectator_scroll_max()


func _scroll_strip(delta: float, on_match: bool) -> void:
	if on_match:
		var limit := _match_spectator_scroll_max()
		var next := clampf(match_spectator_scroll + delta, 0.0, limit)
		if is_equal_approx(next, match_spectator_scroll):
			return
		match_spectator_scroll = next
		_push_match_spectators()
		return
	_scroll_spectators(delta)


func _snap_strip(on_match: bool) -> void:
	var step: float = MATCH_SPECTATOR_STEP if on_match else PREVIEW.SPECTATOR_STEP
	var current: float = match_spectator_scroll if on_match else spectator_scroll
	var limit: float = _strip_scroll_max(on_match)
	var snapped: float = clampf(roundf(current / step) * step, 0.0, limit)
	var changed := not is_equal_approx(snapped, current)
	if on_match:
		if changed:
			match_spectator_scroll = snapped
		_push_match_spectators()
		return
	if changed:
		spectator_scroll = snapped
		preview.room_spectator_scroll = spectator_scroll
		preview.queue_redraw()
	# 吸附会移动加号；按钮被滚出条带时已被收掉，这里负责在它回到可视区后重建。
	if changed or _spectator_plus_hit == null:
		_bind_spectator_strip_hits()

func _handle_lobby_scroll(event: InputEvent) -> void:
	var in_list := func(y: float) -> bool:
		return y >= LOBBY_LIST_TOP - 20.0 and y <= LOBBY_LIST_BOTTOM
	# 滚轮（桌面调试、带触摸板的笔记本）
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and in_list.call(event.position.y):
			_scroll_lobby(-LOBBY_ROW_H * 2.0)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and in_list.call(event.position.y):
			_scroll_lobby(LOBBY_ROW_H * 2.0)
			get_viewport().set_input_as_handled()
			return
	# 按下：只有落在列表区里的手势才算拖动，点按钮栏/底栏不受影响
	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		if event.pressed:
			lobby_drag_start_y = event.position.y if in_list.call(event.position.y) else -1.0
			lobby_drag_last_y = event.position.y
			lobby_dragging = false
			return
		if lobby_dragging:
			# 拖动结束时吞掉这次松手，否则手指划过某一行会顺手进错房间
			get_viewport().set_input_as_handled()
		lobby_dragging = false
		lobby_drag_start_y = -1.0
		_layout_lobby_buttons()
		return
	# 拖动：超过 12px 才算滚动，轻点是点击
	var dy := 0.0
	if event is InputEventScreenDrag:
		dy = event.position.y - lobby_drag_last_y
		lobby_drag_last_y = event.position.y
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		dy = event.position.y - lobby_drag_last_y
		lobby_drag_last_y = event.position.y
	if dy == 0.0 or lobby_drag_start_y < 0.0: return
	if not lobby_dragging and absf(lobby_drag_last_y - lobby_drag_start_y) > 12.0:
		lobby_dragging = true
	if not lobby_dragging: return
	_scroll_lobby(-dy)
	for b in lobby_room_buttons:
		if is_instance_valid(b): b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_viewport().set_input_as_handled()

# 大厅房间行热区：列表每次变化都要重挂一次。
# 用 signature 做脏检查，列表没变就不动，免得每 3 秒把用户正按着的按钮拆掉。
func _bind_lobby_room_hits() -> void:
	if preview == null: return
	var lobby_rooms: Array = _lobby_visible_rooms()
	var signature := ""
	for room in lobby_rooms:
		signature += "%s:%d:%d:%s:%s|" % [str(room.get("code", "")), int(room.get("players", 0)),
			int(room.get("mode", 0)), str(room.get("phase", "")), str(room.get("intro", ""))]
	if signature == lobby_room_signature and not lobby_room_buttons.is_empty():
		return
	lobby_room_signature = signature
	for button in lobby_room_buttons:
		if is_instance_valid(button): button.queue_free()
	lobby_room_buttons.clear()
	for i in range(lobby_rooms.size()):
		var row_code := str(lobby_rooms[i].get("code", ""))
		if row_code.is_empty():
			continue
		var row_host := str(lobby_rooms[i].get("host", ""))
		# 满座/对局中都可以进：服务端会自动把来客放到观战席。
		# 旧版在这里弹"这桌已满"，等于把观战功能整条堵死。
		var row_status: String = str(preview.lobby_room_status(lobby_rooms[i]))
		var row_label_text := "%s · %s" % [("进入 " + row_code) if row_host.is_empty() else ("进入 %s（%s 的房间）" % [row_code, row_host]), row_status]
		var btn := _hit(Rect2(20, LOBBY_LIST_TOP, 500, 88), row_label_text, func(): _enter_room(row_code))
		btn.set_meta("row", i)
		lobby_room_buttons.append(btn)
	lobby_scroll = clampf(lobby_scroll, 0.0, _lobby_max_scroll())
	_sync_lobby_scroll()

func _tabs() -> void:
	# Matches the redesigned nav bar: y=848, height 112, three 180px slots.
	_hit(Rect2(0, 848, 180, 112), "房间列表", func(): _route("lobby"))
	_hit(Rect2(180, 848, 180, 112), "好友与聊天", func(): _route("friends"))
	_hit(Rect2(360, 848, 180, 112), "个人资料", func(): _route("profile"))

func _profile_form() -> void:
	profile_name_input = LineEdit.new()
	profile_name_input.text = display_name
	profile_name_input.position = Vector2(76, 453)
	profile_name_input.size = Vector2(388, 52)
	profile_name_input.max_length = 12
	_style_bare_input(profile_name_input, 28)
	hotspot_layer.add_child(profile_name_input)
	_attach_caret_hint(profile_name_input)
	profile_signature_input = LineEdit.new()
	profile_signature_input.text = signature
	profile_signature_input.position = Vector2(76, 556)
	profile_signature_input.size = Vector2(388, 52)
	profile_signature_input.max_length = 80
	_style_bare_input(profile_signature_input, 20)
	hotspot_layer.add_child(profile_signature_input)
	_attach_caret_hint(profile_signature_input)
	_hit(Rect2(171, 345, 198, 39), "选择并裁剪头像", _select_avatar)
	_hit(Rect2(76, 688, 388, 48), "保存资料", _save_profile)
	if page == "edit_profile": _hit(Rect2(410, 84, 110, 56), "取消编辑", func(): _route("profile"))


# Underline-only inputs: the preview draws the hairline, the field must stay bare.
func _style_bare_input(field: LineEdit, font_size: int) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	field.add_theme_stylebox_override("normal", sb)
	field.add_theme_stylebox_override("focus", sb)
	field.add_theme_font_size_override("font_size", font_size)
	field.add_theme_color_override("font_color", Color("f5f5f7"))
	field.add_theme_color_override("font_placeholder_color", Color("8e8e93"))
	field.add_theme_color_override("caret_color", Color("6fd3e8"))

# Exactly one caret on screen: the one in the field the player is typing into.
# Godot has no "hide the native caret" switch — caret_blink=false only makes it
# stay on — so the native one is painted fully transparent and BlinkingCaret
# draws the single visible one.
func _attach_caret_hint(field: LineEdit, web_key: String = "") -> void:
	if field == null:
		return
	field.caret_blink = false
	field.add_theme_color_override("caret_color", Color(0, 0, 0, 0))
	var caret: Control = CARET_HINT.new()
	caret.name = "CaretHint"
	caret.color = Color("ffffff")
	caret.mouse_filter = Control.MOUSE_FILTER_IGNORE
	field.add_child(caret)
	var key := web_key
	if key.is_empty():
		key = "field_%d" % _caret_fields.size()
	_caret_fields[key] = field
	field.focus_entered.connect(func() -> void: _set_active_caret(field))
	# First field of a freshly built page owns the caret until something else
	# takes it, so the page never opens with no caret at all.
	if _active_caret_field == null or not is_instance_valid(_active_caret_field):
		_set_active_caret(field)

func _set_active_caret(field: LineEdit) -> void:
	_active_caret_field = field
	for key in _caret_fields.keys():
		var registered: Variant = _caret_fields[key]
		if not (registered is LineEdit):
			continue
		var candidate: LineEdit = registered
		if not is_instance_valid(candidate):
			continue
		var hint: Node = candidate.get_node_or_null("CaretHint")
		if hint is Control:
			hint.active = (candidate == field)

# Web: the DOM <input> that actually holds focus tells us which field is active.
# Without this a tap on the password box would leave the caret sitting in email.
func _on_web_caret_focus(args: Array) -> void:
	if args.is_empty():
		return
	var key := str(args[0])
	var registered: Variant = _caret_fields.get(key)
	if registered is LineEdit and is_instance_valid(registered):
		_set_active_caret(registered)

func _select_avatar() -> void:
	if OS.has_feature("web"):
		_web_pick_avatar()
		return
	if file_dialog == null:
		file_dialog = FileDialog.new()
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; 图片文件"])
		file_dialog.file_selected.connect(_avatar_file_selected)
		add_child(file_dialog)
	file_dialog.popup_centered(Vector2i(600, 420))

# --- Web avatar picking ---------------------------------------------------
# Godot's FileDialog does not exist on Web. A hidden <input type=file> is
# created once and reused; the picked file is downscaled to 512px in a canvas
# before it crosses into GDScript, because a raw phone photo would be tens of
# megabytes of base64 and would stall the single-threaded build.
func _web_pick_avatar() -> void:
	if web_avatar_callback == null:
		# Keep the reference on the instance: a local Callable gets collected and
		# the JS side then calls into nothing, silently.
		web_avatar_callback = JavaScriptBridge.create_callback(_on_web_avatar_picked)
		JavaScriptBridge.get_interface("window").arenaAvatarPicked = web_avatar_callback
	JavaScriptBridge.eval("""
(function () {
	if (!window.__arenaPickAvatar) {
		var input = document.createElement('input');
		input.type = 'file';
		input.accept = 'image/*';
		input.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;opacity:0;';
		document.body.appendChild(input);
		window.__arenaPickAvatar = function () { input.value = ''; input.click(); };
		input.addEventListener('change', function () {
			var file = input.files && input.files[0];
			if (!file) return;
			var url = URL.createObjectURL(file);
			var img = new Image();
			img.onload = function () {
				var limit = 512;
				var w = img.naturalWidth || limit;
				var h = img.naturalHeight || limit;
				var scale = Math.min(1, limit / Math.max(w, h));
				var cw = Math.max(1, Math.round(w * scale));
				var ch = Math.max(1, Math.round(h * scale));
				var canvas = document.createElement('canvas');
				canvas.width = cw;
				canvas.height = ch;
				canvas.getContext('2d').drawImage(img, 0, 0, cw, ch);
				URL.revokeObjectURL(url);
				if (window.arenaAvatarPicked) window.arenaAvatarPicked(canvas.toDataURL('image/png'));
			};
			img.onerror = function () {
				URL.revokeObjectURL(url);
				if (window.arenaAvatarPicked) window.arenaAvatarPicked('');
			};
			img.src = url;
		});
	}
	window.__arenaPickAvatar();
})();
""", true)

func _on_web_avatar_picked(args: Array) -> void:
	if args.is_empty():
		return
	var data_url := str(args[0])
	var comma := data_url.find(",")
	if comma < 0:
		_notice("图片读取失败，换一张试试")
		return
	var bytes := Marshalls.base64_to_raw(data_url.substr(comma + 1))
	if bytes.is_empty():
		_notice("图片读取失败，换一张试试")
		return
	var source := Image.new()
	if source.load_png_from_buffer(bytes) != OK or source.is_empty():
		_notice("这张图片读不出来，试试 png 或 jpg")
		return
	_open_avatar_crop(source)

func _avatar_file_selected(path: String) -> void:
	var source: Image = Image.load_from_file(path)
	if source == null or source.is_empty():
		_notice("图片无法读取")
		return
	_open_avatar_crop(source)

# Shared by desktop and Web: crop, persist locally, then push to Storage.
func _open_avatar_crop(source: Image) -> void:
	var crop: Control = CROP_DIALOG.new()
	_clear(dialog_layer)
	dialog_layer.add_child(crop)
	crop.theme = theme
	crop.set_source(source)
	crop.confirmed.connect(func(image: Image):
		var err := image.save_png(_avatar_path())
		if err == OK:
			avatar_textures[0] = ImageTexture.create_from_image(image)
			_refresh_own_portrait_views()
			# Coroutine: deferred from this signal handler.
			call_deferred("_upload_avatar_to_cloud", image)
		else: _notice("头像保存失败（%d）" % err)
		_clear(dialog_layer)
	)
	crop.cancelled.connect(func(): _clear(dialog_layer))

# 建房已改为走网关 /api/rooms/claim（见下方 _create_room 的实现）

func _join_dialog() -> void:
	var field := _text_dialog("输入房间号", "房间号，或直接粘贴完整邀请链接", "房间号或邀请链接")
	_dialog_button("加入房间", func():
		var resolved := _resolve_join_room_code(field.text)
		if not bool(resolved.get("ok", false)):
			_notice(str(resolved.get("message", "房间号格式不正确")))
			return
		var code := str(resolved.get("code", ""))
		# 实时校验一次：大厅列表最多 3 秒前的，刚开好的桌在缓存里还查不到，
		# 拿缓存校验会把"刚开的房"误判成"房间不存在"。
		_fetch_rooms_once(func(rooms: Array, ok: bool):
			if not ok:
				_notice("网络异常，请重试")
				return
			for candidate in rooms:
				if str(candidate.get("code", "")).to_upper() != code:
					continue
				# 只在"已开桌"的房间里找：预热备胎 open=false 且没人，不能被房间号搜到
				if not bool(candidate.get("open", false)) and int(candidate.get("players", 0)) == 0:
					continue
				# 满座不再是拒绝理由：进去自动坐观战席，对局中也能看。
				_enter_room(code)
				return
			_notice("房间不存在或已解散")
		)
	)

# One parser for both inputs the dialog promises: a bare room code, or a full
# invite link this game produced ("...?invite=...&room=ABC123"). Returns
# {ok: bool, code: String} on success, {ok: false, message: String} otherwise.
func _resolve_join_room_code(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if text.is_empty():
		return {"ok": false, "message": "请输入房间号，或粘贴邀请链接"}
	var code := ""
	if text.contains("room="):
		code = _extract_room_code(text)
		if code.is_empty():
			return {"ok": false, "message": "链接里的房间号不完整，请让房主重新复制"}
	elif text.contains("://") or text.contains("invite=") or text.contains("/?"):
		return {"ok": false, "message": "这条链接里没有房间号，请让房主重新复制邀请链接"}
	else:
		code = text.to_upper()
	if not _is_room_code(code):
		return {"ok": false, "message": "房间号是 4–8 位字母或数字，请检查后重试"}
	return {"ok": true, "code": code}

func _is_room_code(value: String) -> bool:
	if value.length() < 4 or value.length() > 8:
		return false
	for ch in value:
		if not "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(ch):
			return false
	return true

func _open_friend_chat(id: String, name: String) -> void:
	active_friend_id = id
	active_friend_name = name
	chat_messages = []
	chat_state = ""
	chat_last_error = ""
	if preview != null:
		preview.active_friend_name = name
		preview.active_friend_portrait = friend_avatar_textures.get(id) if friend_avatar_textures.has(id) else null
		preview.chat_messages = []
		preview.chat_state = ""
		preview.chat_scroll = 0.0
		preview.queue_redraw()
	_route("chat")
	# Coroutines must be deferred from this sync handler.
	call_deferred("_load_chat", false)
	if chat_poll_timer != null:
		chat_poll_timer.start()


# Coroutine: pull the newest 30 messages of the open conversation.
func _load_chat(quiet: bool = false) -> void:
	if active_friend_id.is_empty():
		chat_state = "failed"
		chat_last_error = "未选择聊天对象"
		_apply_chat_state()
		return
	if supabase == null or not supabase.session_valid():
		chat_state = "failed"
		chat_last_error = "登录状态已失效"
		_apply_chat_state()
		return
	if not quiet:
		chat_state = "loading"
		_apply_chat_state()
	var res: Dictionary = await supabase.list_messages(active_friend_id, 30)
	if bool(res.get("ok", false)):
		chat_messages = res.get("rows", [])
		chat_state = "ready"
		chat_last_error = ""
	else:
		chat_state = "failed"
		chat_last_error = str(res.get("reason", "unknown"))
	_apply_chat_state()


func _apply_chat_state() -> void:
	if preview == null:
		return
	preview.chat_messages = chat_messages
	preview.chat_state = chat_state
	preview.chat_last_error = chat_last_error
	preview.chat_self_id = supabase.current_user_id() if supabase != null else ""
	_update_chat_invite()
	# Only a conversation that actually rendered clears its badge. A failed load
	# leaves the unread count alone instead of pretending the messages were read.
	if chat_state == "ready" and page == "chat" and not active_friend_id.is_empty():
		_mark_chat_read(active_friend_id, chat_messages)
	preview.queue_redraw()
	call_deferred("_refresh_chat_invite_hits")


func _on_chat_poll() -> void:
	if page == "chat" and not chat_sending:
		call_deferred("_load_chat", true)


# --- Unread badge ----------------------------------------------------------
# Read state lives on this device, not on the server: `messages` has no read_at
# column and no UPDATE policy by design. That also means a second device keeps
# its own badge until that conversation is opened there.

func _on_unread_poll() -> void:
	if page in UNREAD_PAGES:
		call_deferred("_refresh_unread")


func _read_state_key() -> String:
	if supabase != null and supabase.session_valid():
		return supabase.current_user_id()
	return ""


# Load the on-disk watermark table once, then hand out the current account's
# slice. Another account must never inherit the previous one's read state.
func _ensure_read_state() -> void:
	var key := _read_state_key()
	if _read_state_loaded and key == _read_state_uid:
		return
	_read_state_uid = key
	chat_read_cursors = {}
	unread_by_friend = {}
	_read_state_seeded = true
	if not _read_state_loaded:
		_read_state_loaded = true
		if FileAccess.file_exists(CHAT_READ_STATE_PATH):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CHAT_READ_STATE_PATH))
			if typeof(parsed) == TYPE_DICTIONARY:
				_read_state_all = parsed
	if key.is_empty():
		_apply_unread_state()
		return
	var section: Variant = _read_state_all.get(key, null)
	if typeof(section) == TYPE_DICTIONARY:
		chat_read_cursors = section
		_read_state_seeded = not chat_read_cursors.is_empty()
	else:
		# Brand-new account for this device: history gets adopted on the first
		# poll instead of being counted as unread.
		_read_state_seeded = false
	_read_state_all[key] = chat_read_cursors
	_apply_unread_state()


func _save_read_state() -> void:
	var key := _read_state_key()
	if key.is_empty():
		return
	_read_state_all[key] = chat_read_cursors
	var file := FileAccess.open(CHAT_READ_STATE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(_read_state_all))
	file.close()


# True when `row` is newer than the watermark. created_at is the server's UTC
# RFC3339 string with microsecond precision, so a string compare is enough; an
# exact tie counts as already read, never as a phantom unread.
func _msg_after_cursor(row: Dictionary, cursor: Dictionary) -> bool:
	var stamp := str(row.get("created_at", ""))
	if stamp.is_empty():
		return false
	var mark := str(cursor.get("t", ""))
	if mark.is_empty():
		return true
	return stamp > mark


func _apply_unread_state() -> void:
	if preview == null:
		return
	preview.unread_by_friend = unread_by_friend
	preview.queue_redraw()


func _reset_unread_state() -> void:
	unread_by_friend = {}
	chat_read_cursors = {}
	_read_state_uid = ""
	_read_state_seeded = true
	if unread_poll_timer != null:
		unread_poll_timer.stop()
	_apply_unread_state()


# Coroutine: newest incoming messages across all friends -> per-friend counts.
# Recomputed from scratch on every tick, so overlapping polls, a reconnect or a
# page reload all end at the same number instead of stacking up.
func _refresh_unread() -> void:
	if _unread_busy or supabase == null or not supabase.session_valid():
		return
	if not (page in UNREAD_PAGES):
		return
	_unread_busy = true
	_ensure_read_state()
	var res: Dictionary = await supabase.list_incoming_messages(UNREAD_FETCH_LIMIT)
	_unread_busy = false
	if not bool(res.get("ok", false)):
		# A failed poll keeps the last known counts: silently zeroing the badge
		# would claim "nothing new" while the network is down.
		return
	if not supabase.session_valid():
		return
	var me: String = supabase.current_user_id()
	var rows: Array = res.get("rows", [])
	if not _read_state_seeded:
		# First look at this account on this device: watermark every friend at
		# their newest incoming message. Messages read before this build shipped
		# must not pop up as unread.
		for entry in rows:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var seed_row: Dictionary = entry
			if str(seed_row.get("to_user", me)) != me:
				continue
			var seed_friend := str(seed_row.get("from_user", ""))
			if seed_friend.is_empty() or seed_friend == me or chat_read_cursors.has(seed_friend):
				continue
			chat_read_cursors[seed_friend] = {"t": str(seed_row.get("created_at", ""))}
		_read_state_seeded = true
		unread_by_friend = {}
		_save_read_state()
		_apply_unread_state()
		return
	var counts: Dictionary = {}
	for entry in rows:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry
		var friend := str(row.get("from_user", ""))
		if friend.is_empty() or friend == me:
			continue
		# Belt and braces: RLS already limits the feed to my own pairs.
		if str(row.get("to_user", me)) != me:
			continue
		# The open conversation is about to render this row on its own 3s tick and
		# clears its badge on load; counting it here would only flicker a badge on
		# a chat that is already on screen.
		if page == "chat" and friend == active_friend_id and chat_state == "ready":
			continue
		var cursor: Dictionary = chat_read_cursors.get(friend, {})
		if not _msg_after_cursor(row, cursor):
			continue
		counts[friend] = int(counts.get(friend, 0)) + 1
	unread_by_friend = counts
	_apply_unread_state()


# Rendering a conversation is what clears that friend's badge — opening the
# friends list or the chat page alone does not.
func _mark_chat_read(friend_id: String, messages: Array) -> void:
	if friend_id.is_empty() or supabase == null or not supabase.session_valid():
		return
	_ensure_read_state()
	var me: String = supabase.current_user_id()
	var newest: Dictionary = {}
	for entry in messages:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry
		if str(row.get("from_user", "")) == me or str(row.get("to_user", "")) != me:
			continue
		if _msg_after_cursor(row, newest):
			newest = row
	if newest.is_empty():
		return
	var known: Dictionary = chat_read_cursors.get(friend_id, {})
	if not _msg_after_cursor(newest, known):
		return
	chat_read_cursors[friend_id] = {"t": str(newest.get("created_at", ""))}
	unread_by_friend.erase(friend_id)
	_save_read_state()
	_apply_unread_state()


# Coroutine: real send. Nothing is echoed locally unless the server accepted it.
func _send_chat_message(text: String) -> void:
	if chat_sending:
		return
	chat_sending = true
	var res: Dictionary = await supabase.send_message(active_friend_id, text)
	chat_sending = false
	if bool(res.get("ok", false)):
		await _load_chat(true)
		return
	if chat_input != null and chat_input.text.strip_edges().is_empty():
		chat_input.text = text
		_web_friend_chat_set(text)
	_notice("消息未发送：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))


# Coroutine: open another player's read-only card. `fallback_name` shows instantly
# while the cloud row is in flight, so the header is never blank.
func _open_player_profile(uid: String, fallback_name: String) -> void:
	view_player_id = uid
	view_player_name = fallback_name
	view_player_signature = ""
	view_player_level = 1
	view_player_state = "loading"
	view_player_error = ""
	view_player_portrait = null
	_route("player_profile")
	call_deferred("_load_player_profile")


func _load_player_profile() -> void:
	if view_player_id.is_empty():
		view_player_state = "failed"
		view_player_error = "没有这位玩家的身份信息"
		_apply_player_profile()
		return
	if supabase == null or not supabase.session_valid():
		view_player_state = "failed"
		view_player_error = "登录状态已失效"
		_apply_player_profile()
		return
	var res: Dictionary = await supabase.fetch_profile_by_id(view_player_id)
	if not bool(res.get("ok", false)):
		view_player_state = "failed"
		view_player_error = _friend_reason_text(str(res.get("reason", "unknown")))
		_apply_player_profile()
		return
	var uname := str(res.get("username", "")).strip_edges()
	if not uname.is_empty():
		view_player_name = uname
	view_player_signature = str(res.get("signature", ""))
	view_player_level = int(res.get("level", 1))
	var key := str(res.get("avatar_key", ""))
	if not key.is_empty():
		view_player_portrait = await _fetch_avatar_texture(view_player_id, key)
	view_player_state = "ready"
	view_player_relation = await supabase.friend_status(view_player_id)
	_apply_player_profile()


func _apply_player_profile() -> void:
	if preview == null:
		return
	preview.view_player_name = view_player_name
	preview.view_player_signature = view_player_signature
	preview.view_player_level = view_player_level
	preview.view_player_state = view_player_state
	preview.view_player_error = view_player_error
	preview.view_player_relation = view_player_relation
	preview.view_player_portrait = view_player_portrait
	preview.queue_redraw()
	if page == "player_profile":
		_build_player_profile_hotspots()


func _build_player_profile_hotspots() -> void:
	_clear(hotspot_layer)
	_hit(Rect2(10, 70, 56, 56), "返回房间", func(): _route("waiting_room"))
	# Only the two actionable states get a hot zone; "requested" is plain text.
	if view_player_state == "ready":
		if view_player_relation == "none":
			_hit(Rect2(20, 620, 500, 66), "加好友", _add_friend_from_profile)
		elif view_player_relation == "incoming":
			_hit(Rect2(20, 620, 500, 66), "接受好友申请", _accept_incoming_friend)
		elif view_player_relation == "friend":
			_hit(Rect2(20, 620, 500, 66), "删除好友", _confirm_remove_friend)

func _add_friend_from_profile() -> void:
	if view_player_id.is_empty():
		return
	var res: Dictionary = await supabase.send_friend_request(view_player_id)
	if bool(res.get("ok", false)):
		view_player_relation = "requested"
		_apply_player_profile()
		_notice("好友申请已发送，等对方接受")
		call_deferred("_refresh_friend_data", true)
	else:
		_notice("申请未发送：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))

# Coroutine: the other side asked first; this tap accepts their request.
func _accept_incoming_friend() -> void:
	if view_player_id.is_empty():
		return
	var ok: bool = await supabase.accept_friend_request_from(view_player_id)
	if ok:
		view_player_relation = "friend"
		_apply_player_profile()
		_notice("已添加好友")
		call_deferred("_refresh_friend_data", true)
	else:
		_notice("接受失败：申请可能已被对方撤回")

func _confirm_remove_friend() -> void:
	if view_player_id.is_empty():
		return
	_open_dialog("删除好友", "删除后要重新申请才能再成为好友", [
		{"label": "确认删除", "action": func(): call_deferred("_do_remove_friend")},
	])

# Coroutine: deferred from the confirm dialog, never called bare.
func _do_remove_friend() -> void:
	_clear(dialog_layer)
	var ok: bool = await supabase.remove_friend(view_player_id)
	if ok:
		view_player_relation = "none"
		_apply_player_profile()
		call_deferred("_refresh_friend_data", true)
		_notice("已删除好友")
	else:
		_notice("删除失败：可能没有权限，或对方已不在好友列表")


func _occupant_for_slot(slot_index: int) -> Dictionary:
	for occupant in network_players:
		if typeof(occupant) != TYPE_DICTIONARY:
			continue
		if int((occupant as Dictionary).get("slot", -1)) == slot_index:
			return occupant
	return {}


func _friend_search() -> void:
	var field := _text_dialog("搜索玩家", "按昵称搜索云端已注册玩家", "玩家昵称")
	_dialog_button("搜索", func():
		var q := field.text.strip_edges()
		if q.is_empty():
			_notice("请输入玩家昵称")
			return
		call_deferred("_run_friend_search", q)
	)


# Coroutine: real cloud lookup. Shows the raw server reason when it fails.
# Capped at 4 hits: the dialog is a fixed-height VBox, more buttons would overflow.
func _run_friend_search(query: String) -> void:
	if not supabase.session_valid():
		_notice("登录状态已失效，请重新登录")
		return
	var res: Dictionary = await supabase.search_profiles(query, 4)
	if not bool(res.get("ok", false)):
		_notice("搜索失败：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))
		return
	var rows: Array = res.get("rows", [])
	if rows.is_empty():
		_notice("没有找到昵称包含“%s”的玩家" % query)
		return
	var subtitle := "共 %d 位玩家 · 点击发送好友申请" % rows.size()
	if rows.size() >= 4:
		subtitle = "显示前 4 位 · 昵称更精确可缩小范围"
	var actions: Array[Dictionary] = []
	for entry in rows:
		var uid := str((entry as Dictionary).get("id", ""))
		var uname := str((entry as Dictionary).get("username", ""))
		actions.append({"label": "加为好友 · %s" % uname, "action": func(): call_deferred("_send_friend_request_to", uid, uname)})
	_open_dialog("搜索结果", subtitle, actions)


# Coroutine: never reports success unless the server really created the row.
func _send_friend_request_to(uid: String, name: String) -> void:
	if friend_busy:
		return
	friend_busy = true
	var res: Dictionary = await supabase.send_friend_request(uid)
	friend_busy = false
	if bool(res.get("ok", false)):
		_notice("好友申请已发送给 %s\n对方接受后才会出现在好友列表" % name)
		call_deferred("_refresh_friend_data")
	else:
		_notice("申请未发送：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))


func _friend_inbox() -> void:
	call_deferred("_show_friend_inbox")


# Coroutine: incoming requests, each with accept / reject.
func _show_friend_inbox() -> void:
	if not supabase.session_valid():
		_notice("登录状态已失效，请重新登录")
		return
	var res: Dictionary = await supabase.list_pending_requests()
	if not bool(res.get("ok", false)):
		_notice("读取申请失败：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))
		return
	var rows: Array = res.get("rows", [])
	if rows.is_empty():
		_open_dialog("好友申请", "暂时没有待处理的申请", [
			{"label": "刷新", "action": func(): call_deferred("_show_friend_inbox")},
		])
		return
	var actions: Array[Dictionary] = []
	# Capped at 3 requests (6 buttons + close): the dialog is a fixed-height VBox.
	var shown: Array = rows.slice(0, 3)
	for entry in shown:
		var rid := str((entry as Dictionary).get("id", ""))
		var uname := str((entry as Dictionary).get("username", ""))
		actions.append({"label": "接受 · %s" % uname, "action": func(): call_deferred("_respond_request", rid, true, uname)})
		actions.append({"label": "拒绝 · %s" % uname, "action": func(): call_deferred("_respond_request", rid, false, uname)})
	var subtitle := "共 %d 条待处理 · 接受后成为好友" % rows.size()
	if rows.size() > 3:
		subtitle = "共 %d 条 · 仅显示最新 3 条，处理后刷新" % rows.size()
	_open_dialog("好友申请", subtitle, actions)


# Coroutine: accept keeps the row (status=accepted) and ensures the friendship;
# reject deletes the row because the schema has no 'rejected' status.
func _respond_request(request_id: String, accept: bool, who: String) -> void:
	var res: Dictionary = await supabase.respond_request(request_id, accept)
	if bool(res.get("ok", false)):
		_notice(("已接受 %s 的好友申请" if accept else "已拒绝 %s 的好友申请") % who)
		call_deferred("_refresh_friend_data")
	else:
		_notice("操作失败：%s" % _friend_reason_text(str(res.get("reason", "unknown"))))


# Coroutine: pull friends + pending count from Supabase and mirror it into the view.
func _on_heartbeat() -> void:
	call_deferred("_heartbeat_tick", true)


# Coroutine: refresh last_seen. When the friend list is open, re-read it quietly
# so presence ages and the online count stay truthful.
func _heartbeat_tick(refresh_list: bool) -> void:
	# A 5s timer plus action-triggered checks can overlap while a request is in
	# flight; one beat at a time is enough to notice a takeover.
	if _heartbeat_busy:
		return
	_heartbeat_busy = true
	await _heartbeat_once(refresh_list)
	_heartbeat_busy = false

# Re-check the session right away on any user action, so a taken-over device is
# kicked the moment it is touched instead of waiting for the next timer tick.
func _check_session_now() -> void:
	if my_session_id.is_empty() or not _session_claimed:
		return
	var now := Time.get_ticks_msec()
	if now - _session_check_ms < 1500:
		return
	_session_check_ms = now
	call_deferred("_heartbeat_tick", false)

func _heartbeat_once(refresh_list: bool) -> void:
	if supabase == null or not supabase.session_valid():
		return
	# Retry a failed claim roughly every 20s; the first attempt happens at login.
	if not _session_claimed and not my_session_id.is_empty():
		_session_retry_ticks += 1
		if _session_retry_ticks % 4 == 1:
			await _claim_my_session()
	# Only filter by session once the claim actually landed; otherwise the very
	# first heartbeat after login would match nothing and kick ourselves out.
	var sid := my_session_id if _session_claimed else ""
	var ok: bool = await supabase.heartbeat(sid)
	if not ok:
		if supabase.last_heartbeat_reason == "superseded":
			_force_sign_out("账号已在其他设备登录")
		return
	if refresh_list and page == "friends":
		call_deferred("_refresh_friend_data", true)

# Coroutine: claim the account for this device. Failure is reported once: it
# usually means profiles.session_id is missing, and silently ignoring that would
# mean pretending multi-device login is blocked when it is not.
func _claim_my_session() -> void:
	if my_session_id.is_empty() or supabase == null or not supabase.session_valid():
		return
	var ok: bool = await supabase.claim_session(my_session_id)
	if ok:
		_session_claimed = true
		print("SESSION_CLAIMED id=%s" % my_session_id.left(8))
		_start_realtime()
		return
	_session_claimed = false
	print("SESSION_CLAIM_FAIL")
	if not _session_claim_failed_once:
		_session_claim_failed_once = true
		_notice("当前无法限制多端登录（云端 session_id 未就绪）")

# Subscribe to this account's profile row so a login elsewhere arrives as a push
# instead of being noticed on the next poll.
func _start_realtime() -> void:
	var uid: String = supabase.current_user_id()
	if uid.is_empty():
		return
	if realtime == null:
		realtime = REALTIME.new()
		realtime.name = "SupabaseRealtime"
		add_child(realtime)
		realtime.record_changed.connect(_on_profile_record)
	# The supplier is re-read on every reconnect so a refreshed JWT is picked up.
	realtime.subscribe(uid, supabase.access_token(), Callable(supabase, "access_token"))

func _stop_realtime() -> void:
	if realtime == null:
		return
	if realtime.has_method("unsubscribe"):
		realtime.unsubscribe()
	realtime.queue_free()
	realtime = null

func _realtime_status_text() -> String:
	if my_session_id.is_empty():
		return ""
	if realtime == null:
		return "实时通道：未启动"
	if realtime.has_method("is_live") and bool(realtime.call("is_live")):
		return "实时通道：已连接"
	var err := ""
	if realtime.has_method("last_error"):
		err = str(realtime.call("last_error"))
	if err.is_empty():
		return "实时通道：连接中…"
	return "实时通道：失败 %s" % err

func _on_profile_record(record: Dictionary) -> void:
	var remote := str(record.get("session_id", ""))
	if remote.is_empty() or my_session_id.is_empty():
		return
	if remote == my_session_id:
		return
	# Another device stamped its own id: this one is stale. Deferred, because the
	# teardown must not run inside the websocket's own _process.
	print("SESSION_SUPERSEDED_PUSH")
	call_deferred("_force_sign_out", "账号已在其他设备登录")

# Every room/transport failure a player can hit, in words they can act on.
# Unknown tokens are passed through unchanged on purpose: inventing a friendly
# sentence for an unmapped code would hide the real cause from whoever debugs it.
func _network_reason_text(code: String) -> String:
	match code:
		"unknown_room", "room_not_found", "bad_room":
			return "房间不存在或已解散"
		"no_room_available":
			return "当前没有可用的房间"
		"room_full":
			return "这桌已满，换一桌吧"
		"missing_origin", "origin_rejected":
			return "连接来源校验失败，请刷新页面重试"
		"unauthorized_upgrade", "unauthorized", "forbidden":
			return "登录已过期，请重新登录"
		"idle_timeout", "ghost_reaped":
			return "长时间无操作，已离开房间"
		"resume_expired", "seat_expired":
			return "座位已过期，请重新进房"
		"host_closed", "room_closed":
			return "房主解散了房间"
	if code.is_empty():
		return "连接已断开"
	return code

# Kicked out by a newer login: drop the session, the socket and the local page.
func _force_sign_out(reason: String) -> void:
	# Clearing the session first doubles as the re-entry guard: a second push
	# arriving while the page is being rebuilt just sees an empty id.
	if my_session_id.is_empty() and not supabase.session_valid():
		return
	my_session_id = ""
	_session_claimed = false
	player_id = ""
	_reset_unread_state()
	if heartbeat_timer != null:
		heartbeat_timer.stop()
	_stop_realtime()
	if network_client != null:
		var stale := network_client
		network_client = null
		stale.queue_free()
	supabase.sign_out()
	_load_profile()
	# Rebuild on the next idle frame. Doing it inline is what froze the client:
	# this runs from the websocket callback, and tearing down the UI tree while
	# the socket is still being polled left the page half-updated.
	call_deferred("_show_kicked_message", reason)

func _show_kicked_message(reason: String) -> void:
	if preview != null:
		preview.display_name = display_name
		preview.portraits = avatar_textures
		preview.realtime_text = ""
		preview.profile_sync_text = ""
	_route("auth")
	_notice(reason)


# Coroutine: pull friends + pending count from Supabase and mirror it into the view.
func _refresh_friend_data(quiet: bool = false) -> void:
	if supabase == null:
		return
	if not supabase.session_valid():
		friend_rows = []
		friend_pending_count = 0
		friend_cloud_state = "failed"
		friend_last_error = "登录状态已失效"
		_apply_friend_state()
		return
	if not quiet:
		friend_cloud_state = "loading"
		_apply_friend_state()
	var friends: Dictionary = await supabase.list_friends()
	if bool(friends.get("ok", false)):
		friend_rows = friends.get("rows", [])
		friend_cloud_state = "synced"
		friend_last_error = ""
	else:
		friend_rows = []
		friend_cloud_state = "failed"
		friend_last_error = str(friends.get("reason", "unknown"))
	var inbox: Dictionary = await supabase.list_pending_requests()
	friend_pending_count = (inbox.get("rows", []) as Array).size() if bool(inbox.get("ok", false)) else 0
	_apply_friend_state()
	_load_friend_avatars()


# Download avatars only when the stored key changed: egress is the scarce resource.
func _load_friend_avatars() -> void:
	for entry in friend_rows:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = entry
		var uid := str(row.get("id", ""))
		var key := str(row.get("avatar_key", ""))
		if uid.is_empty() or key.is_empty():
			continue
		if str(friend_avatar_keys.get(uid, "")) == key and friend_avatar_textures.has(uid):
			continue
		if avatar_loading.has(uid):
			continue
		avatar_loading[uid] = true
		call_deferred("_download_friend_avatar", uid, key)


# Coroutine: fetch one avatar and cache it. Returns null when it cannot be loaded.
func _fetch_avatar_texture(uid: String, key: String) -> Texture2D:
	if friend_avatar_textures.has(uid) and str(friend_avatar_keys.get(uid, "")) == key:
		return friend_avatar_textures[uid]
	var res: Dictionary = await supabase.download_bytes(SupabaseClient.avatar_public_url(uid, key))
	if not bool(res.get("ok", false)):
		return null
	var image := Image.new()
	if image.load_png_from_buffer(res.get("bytes", PackedByteArray())) != OK:
		return null
	image.resize(192, 192, Image.INTERPOLATE_LANCZOS)
	var texture := ImageTexture.create_from_image(image)
	friend_avatar_textures[uid] = texture
	friend_avatar_keys[uid] = key
	return texture


# Coroutine: fetch one avatar and cache it at display size (54px circle).
func _download_friend_avatar(uid: String, key: String) -> void:
	avatar_loading.erase(uid)
	var texture: Texture2D = await _fetch_avatar_texture(uid, key)
	if texture == null:
		return
	if preview != null and active_friend_id == uid and page == "chat":
		preview.active_friend_portrait = texture
	_apply_friend_state()


# Coroutine: push the freshly cropped avatar to Storage, then stamp profiles.avatar_key.
func _upload_avatar_to_cloud(image: Image) -> void:
	if supabase == null or not supabase.session_valid():
		avatar_sync_state = "failed"
		avatar_sync_error = "no_session"
		_notice("头像已存本地；未登录，没有同步到云端")
		return
	avatar_sync_state = "sending"
	avatar_sync_error = ""
	# 256px keeps uploads small (egress is the plan's scarce quota).
	var upload := Image.new()
	upload.copy_from(image)
	upload.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	var res: Dictionary = await supabase.upload_avatar(upload.save_png_to_buffer())
	if bool(res.get("ok", false)):
		avatar_sync_state = "ok"
		my_avatar_key = str(res.get("avatar_key", ""))
		# Remember the stamp so this device does not re-download its own upload.
		var cfg := ConfigFile.new()
		cfg.load(profile_file)
		cfg.set_value(_profile_section(), "avatar_key", my_avatar_key)
		cfg.save(profile_file)
		_notice("头像已保存并同步到云端")
	else:
		avatar_sync_state = "failed"
		avatar_sync_error = str(res.get("reason", "unknown"))
		_notice("头像已存本地，同步云端失败：%s" % _friend_reason_text(avatar_sync_error))

# Coroutine: pull this account's avatar from Storage and cache it on disk.
# Without this a second device has no user://avatar_<uid>.png and shows the
# default portrait forever, even though Storage already has the real one.
func _adopt_cloud_avatar(key: String) -> void:
	if supabase == null or not supabase.session_valid():
		return
	if key == my_avatar_key and FileAccess.file_exists(_avatar_path()):
		return
	var uid: String = supabase.current_user_id()
	if uid.is_empty():
		return
	var res: Dictionary = await supabase.download_bytes(SupabaseClient.avatar_public_url(uid, key))
	if not bool(res.get("ok", false)):
		print("AVATAR_ADOPT_FAIL reason=%s" % str(res.get("reason", "")))
		return
	var image := Image.new()
	if image.load_png_from_buffer(res.get("bytes", PackedByteArray())) != OK:
		return
	image.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	var saved := image.save_png(_avatar_path())
	my_avatar_key = key
	if avatar_textures.size() > 0:
		avatar_textures[0] = ImageTexture.create_from_image(image)
	_refresh_own_portrait_views()
	var cfg := ConfigFile.new()
	cfg.load(profile_file)
	cfg.set_value(_profile_section(), "avatar_key", key)
	cfg.save(profile_file)
	print("AVATAR_ADOPT key=%s saved=%d" % [key.left(16), saved])


func _apply_friend_state() -> void:
	if preview == null:
		return
	preview.friend_rows = friend_rows
	preview.friend_pending_count = friend_pending_count
	preview.friend_state_text = _friend_state_text()
	preview.friend_failed = friend_cloud_state == "failed"
	preview.friend_portraits = friend_avatar_textures
	preview.queue_redraw()
	if page == "friends":
		_build_friends_hotspots()
	# Presence and avatars arrive after the window opens; rebuild only when the
	# rows actually changed so an open scroll list is not reset every refresh.
	if invite_panel_open and page == "waiting_room":
		_refresh_invite_panel()


func _friend_state_text() -> String:
	match friend_cloud_state:
		"loading":
			return "正在同步云端好友…"
		"synced":
			return "云端好友 · 共 %d 位" % friend_rows.size()
		"failed":
			return "同步失败：%s" % friend_last_error
	return "云端好友 · 尚未同步"


# Hotspots depend on how many friend rows came back, so they are rebuilt whenever
# the data changes (and never duplicated: the layer is cleared first).
func _build_friends_hotspots() -> void:
	_clear(hotspot_layer)
	_tabs()
	_hit(Rect2(20, 166, 500, 56), "搜索玩家", _friend_search)
	_hit(Rect2(20, 224, 500, 52), "好友申请", _friend_inbox)
	if friend_cloud_state == "failed":
		# The design shows "检查网络后重试" as plain text; make that block tappable.
		_hit(Rect2(20, 330, 500, 110), "重试同步好友", func(): call_deferred("_refresh_friend_data"))
	var shown := mini(friend_rows.size(), 6)
	for i in range(shown):
		var fid := str((friend_rows[i] as Dictionary).get("id", ""))
		var fname := str((friend_rows[i] as Dictionary).get("username", ""))
		_hit(Rect2(20, 286 + i * 88, 500, 88), "打开好友聊天", func(): _open_friend_chat(fid, fname))
		# Avatar opens the profile card, same split as the waiting room. Added
		# after the row hit zone so it wins over it in input order.
		_hit(Rect2(20, 286 + i * 88, 72, 88), "查看好友资料", func(): _open_player_profile(fid, fname))


# Maps a server reason to user-facing text. Unknown reasons are shown verbatim so
# a failure is never disguised as success.
func _friend_reason_text(reason: String) -> String:
	match reason:
		"self":
			return "不能添加自己为好友"
		"already_friend":
			return "你们已经是好友了"
		"already_pending":
			return "你已经发过申请，等对方处理"
		"incoming_pending":
			return "对方已向你发过申请，去“好友申请”里接受"
		"empty_target":
			return "请先选择一位玩家"
		"empty_query":
			return "请输入玩家昵称"
		"no_session":
			return "登录状态已失效，请重新登录"
		"request_not_found_or_not_permitted":
			return "这条申请已被处理，或无权操作"
		"friendship_failed":
			return "已接受申请，但写入好友关系失败，请刷新重试"
		"body_empty":
			return "消息不能为空"
		"body_too_long":
			return "消息太长，最多 500 字"
		"avatar_key_not_saved":
			return "头像图已上传，但资料没更新，请重试"
	return "服务器返回 %s" % reason

# Real invite flow: pick from cloud friends, send one chat message carrying the
# room link. The other side taps it in their chat to join — no fake local roster.
func _invite_friend() -> void:
	if solo_room or room_code.is_empty():
		_notice("当前没有可邀请的房间")
		return
	invite_panel_open = true
	invite_panel_signature = ""
	_refresh_invite_panel(true)
	if invite_refresh_timer != null:
		invite_refresh_timer.start()
	# The dialog opens from the last known friend list, then quietly refreshes:
	# presence must not be a stale guess from minutes ago.
	call_deferred("_refresh_friend_data", true)

# Leave the room -> forget who was invited here. The badges are per-room truth,
# not a permanent "I once invited this person" flag.
func _reset_room_invites() -> void:
	invited_friend_ids.clear()
	invite_last_copied = ""
	_end_invite_panel()

func _end_invite_panel(clear_dialog: bool = true) -> void:
	var was_open := invite_panel_open
	invite_panel_open = false
	invite_panel_signature = ""
	invite_panel_busy.clear()
	invite_panel_error.clear()
	invite_panel_note.clear()
	if invite_refresh_timer != null:
		invite_refresh_timer.stop()
	if clear_dialog and was_open and dialog_layer != null and dialog_layer.get_child_count() > 0:
		_clear(dialog_layer)

func _on_invite_refresh() -> void:
	if not invite_panel_open or page != "waiting_room" or solo_room:
		if invite_refresh_timer != null:
			invite_refresh_timer.stop()
		return
	call_deferred("_refresh_friend_data", true)

func _friend_online(entry: Dictionary) -> bool:
	if preview == null:
		return false
	return preview.is_online(str(entry.get("last_seen", "")))

# One source of truth for the right-hand button. Kept pure so the test can ask
# "what would this row offer?" without building a Control tree.
func _invite_row_action(entry: Dictionary) -> Dictionary:
	var fid := str(entry.get("id", ""))
	var link := _room_invite_link()
	if invited_friend_ids.has(fid):
		return {"text": "已发送邀请", "enabled": false, "kind": "sent"}
	if bool(invite_panel_busy.get(fid, false)):
		return {"text": "发送中…", "enabled": false, "kind": "busy"}
	# No web entry (desktop/LAN): an in-game DM would carry a link that opens a
	# different server, so offer the room code instead of faking an invite.
	if not _friend_online(entry) or link.is_empty():
		return {"text": "复制链接" if not link.is_empty() else "复制房间号", "enabled": true, "kind": "copy"}
	if invite_panel_error.has(fid):
		return {"text": "重试", "enabled": true, "kind": "invite"}
	return {"text": "邀请", "enabled": true, "kind": "invite"}

func _invite_panel_state_signature(link: String) -> String:
	var parts: Array[String] = [room_code, link, "1" if supabase != null and supabase.session_valid() else "0"]
	for raw in friend_rows:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		var fid := str(entry.get("id", ""))
		# A "link copied" hint is only useful while the friend is offline. Once
		# they show up, the row should read 在线 and offer 邀请 again.
		var note := str(invite_panel_note.get(fid, ""))
		if _friend_online(entry) and (note.begins_with("邀请链接已复制") or note.begins_with("房间号已复制")):
			invite_panel_note.erase(fid)
			note = ""
		parts.append("%s|%s|%s|%s|%s|%s|%s|%s" % [
			fid,
			"1" if _friend_online(entry) else "0",
			"1" if invited_friend_ids.has(fid) else "0",
			"1" if bool(invite_panel_busy.get(fid, false)) else "0",
			str(invite_panel_error.get(fid, "")),
			note,
			"1" if friend_avatar_textures.has(fid) else "0",
			str(friend_avatar_keys.get(fid, "")),
		])
	return "\n".join(parts)

func _refresh_invite_panel(force: bool = false) -> void:
	if not invite_panel_open or page != "waiting_room":
		return
	var link := _room_invite_link()
	var signature := _invite_panel_state_signature(link)
	if not force and signature == invite_panel_signature:
		return
	invite_panel_signature = signature
	var subtitle := "房间 #%s · 在线好友直接邀请，离线好友可复制链接" % room_code
	if link.is_empty():
		subtitle = "房间 #%s · 局域网模式：复制房间号给朋友" % room_code
	if supabase == null or not supabase.session_valid():
		subtitle = "登录状态已失效，只能复制链接转发"
	var body := _dialog_frame("邀请好友", subtitle)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	# Empty state needs room for both the hint and the copy row; a list of N
	# friends needs N*72. Both cap at 420 so six-plus friends scroll.
	var list_height := 150.0 if friend_rows.is_empty() else float(friend_rows.size()) * 72.0
	scroll.custom_minimum_size = Vector2(0, clampf(list_height, 78.0, 420.0))
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 0)
	scroll.add_child(rows)
	if friend_rows.is_empty():
		var empty := Label.new()
		empty.text = "还没有好友，先用下面的链接或房间号发给朋友"
		if friend_cloud_state == "loading" or friend_cloud_state.is_empty():
			empty.text = "正在同步好友列表…"
		elif friend_cloud_state == "failed":
			empty.text = "好友列表读取失败：%s。先用下面的链接发给朋友" % friend_last_error
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size = Vector2(0, 70)
		empty.add_theme_font_size_override("font_size", 16)
		empty.add_theme_color_override("font_color", Color("8e8e93"))
		rows.add_child(empty)
		var copy := _dialog_row(rows, "复制邀请链接" if not link.is_empty() else "复制房间号")
		copy.pressed.connect(func(): call_deferred("_copy_invite_for_friend", "", ""))
	else:
		for raw in friend_rows:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			_build_invite_friend_row(rows, raw, link)
	var close := _dialog_row(body, "关闭")
	close.pressed.connect(func():
		_end_invite_panel(false)
		_clear(dialog_layer)
	)
	_fit_dialog()

func _build_invite_friend_row(parent: VBoxContainer, entry: Dictionary, link: String) -> void:
	var fid := str(entry.get("id", ""))
	var fname := str(entry.get("username", "好友"))
	var online := _friend_online(entry)
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 72)
	var row_sb := StyleBoxFlat.new()
	row_sb.bg_color = Color.TRANSPARENT
	row_sb.border_color = Color("1e1e22")
	row_sb.border_width_bottom = 1
	row_sb.content_margin_left = 4
	row_sb.content_margin_right = 4
	row_sb.content_margin_top = 8
	row_sb.content_margin_bottom = 8
	row.add_theme_stylebox_override("panel", row_sb)
	parent.add_child(row)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	line.add_child(_invite_avatar(entry))
	var text_col := VBoxContainer.new()
	text_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text_col.add_theme_constant_override("separation", 2)
	line.add_child(text_col)
	var name_label := Label.new()
	name_label.text = fname
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", Color("f5f5f7"))
	text_col.add_child(name_label)
	var status_label := Label.new()
	var status := ""
	var status_color := Color("8e8e93")
	if invite_panel_error.has(fid):
		status = "未发送：" + str(invite_panel_error[fid])
		status_color = Color("e08b8b")
	elif invite_panel_note.has(fid):
		status = str(invite_panel_note[fid])
		status_color = Color("6fd3e8")
	elif online:
		status = "在线"
		status_color = Color("6fd3e8")
		if link.is_empty():
			status = "在线 · 局域网无可分享链接"
	elif preview != null:
		# Do not print "2520 天前在线" for an account that has been away for years:
		# offline is the useful fact, the exact age is noise.
		var age: int = int(preview._last_seen_age(str(entry.get("last_seen", ""))))
		status = "离线" if age < 0 or age >= 86400 else preview.presence_text(str(entry.get("last_seen", "")))
	status_label.text = status
	status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", status_color)
	text_col.add_child(status_label)
	var action := _invite_row_action(entry)
	var btn := Button.new()
	btn.text = str(action["text"])
	btn.disabled = not bool(action["enabled"])
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(112, 44)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("17191b")
	normal.border_color = Color("2a2a2f")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(8)
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color("1f2124")
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color("26282b")
	var disabled: StyleBoxFlat = normal.duplicate()
	disabled.bg_color = Color.TRANSPARENT
	disabled.border_color = Color("1e1e22")
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_font_size_override("font_size", 16)
	btn.add_theme_color_override("font_color", Color("6fd3e8") if str(action["kind"]) == "invite" else Color("f5f5f7"))
	btn.add_theme_color_override("font_hover_color", Color("ffffff"))
	btn.add_theme_color_override("font_disabled_color", Color("5c5c61"))
	line.add_child(btn)
	var kind := str(action["kind"])
	btn.pressed.connect(func():
		if kind == "invite":
			call_deferred("_send_room_invite", fid, fname)
		elif kind == "copy":
			call_deferred("_copy_invite_for_friend", fid, fname)
	)

func _invite_avatar(entry: Dictionary) -> Control:
	var fid := str(entry.get("id", ""))
	var fname := str(entry.get("username", "?"))
	var texture: Texture2D = friend_avatar_textures.get(fid) if friend_avatar_textures.has(fid) else null
	if texture != null:
		var image := TextureRect.new()
		image.texture = texture
		image.custom_minimum_size = Vector2(44, 44)
		image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		return image
	var fallback := PanelContainer.new()
	fallback.custom_minimum_size = Vector2(44, 44)
	var sb := StyleBoxFlat.new()
	sb.bg_color = preview.friend_tint(fname) if preview != null else Color("2a2a2f")
	sb.set_corner_radius_all(22)
	fallback.add_theme_stylebox_override("panel", sb)
	var glyph := Label.new()
	glyph.text = fname.substr(0, 1).to_upper() if not fname.is_empty() else "?"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 20)
	glyph.add_theme_color_override("font_color", Color("f5f5f7"))
	fallback.add_child(glyph)
	return fallback

func _copy_invite_for_friend(fid: String, fname: String) -> void:
	var link := _room_invite_link()
	var value := link if not link.is_empty() else room_code
	if value.is_empty():
		return
	DisplayServer.clipboard_set(value)
	invite_last_copied = value
	if not fid.is_empty():
		invite_panel_note[fid] = "房间号已复制" if link.is_empty() else "邀请链接已复制，可转发给 %s" % fname
		invite_panel_error.erase(fid)
	_refresh_invite_panel(true)

# Link the invitee can tap: keep the gateway-provided ?invite= token and append
# the room. No token means this build has no shareable web entry (desktop/LAN):
# returning "" is deliberate — inventing https://tacticbrawl.com/ here used to
# hand out a link that pointed at a different gateway and silently failed.
func _room_invite_link() -> String:
	if room_code.is_empty():
		return ""
	var base := invite_url.strip_edges()
	if base.is_empty() or not (base.begins_with("http://") or base.begins_with("https://")):
		return ""
	# Strip any stale room parameter before appending ours.
	var kept: Array[String] = []
	for part in base.split("&", false):
		if part.contains("room="):
			continue
		kept.append(part)
	base = "&".join(kept)
	return base + ("&" if base.contains("?") else "?") + "room=" + room_code

# Coroutine: send the invite message. Never pretends it was delivered: the
# button only flips to 已发送邀请 after Supabase accepted the row, and a failure
# leaves a retry action in place of a fake success.
func _send_room_invite(fid: String, fname: String) -> void:
	if invited_friend_ids.has(fid):
		return
	if bool(invite_panel_busy.get(fid, false)):
		return
	var link := _room_invite_link()
	if link.is_empty():
		invite_panel_error[fid] = "局域网模式没有可分享链接，请复制房间号"
		_refresh_invite_panel(true)
		return
	if supabase == null or not supabase.session_valid():
		invite_panel_error[fid] = "登录状态已失效，请重新登录"
		_refresh_invite_panel(true)
		return
	var invite_room := room_code
	invite_panel_busy[fid] = true
	invite_panel_error.erase(fid)
	invite_panel_note.erase(fid)
	_refresh_invite_panel(true)
	var res: Dictionary = await supabase.send_message(fid, "邀请你加入对局：" + link)
	# The player may have left for another room while the request was in flight.
	# Do not stamp "已发送邀请" onto a room this message does not belong to.
	if room_code != invite_room:
		return
	invite_panel_busy.erase(fid)
	if bool(res.get("ok", false)):
		if not invited_friend_ids.has(fid):
			invited_friend_ids.append(fid)
		invite_panel_error.erase(fid)
		invite_panel_note[fid] = "已发送，等对方在私信里点进来"
	else:
		invite_panel_error[fid] = _friend_reason_text(str(res.get("reason", "unknown")))
	_refresh_invite_panel(true)

# Pull the first room code out of invite text, e.g. "...?invite=x&room=236AE4".
func _extract_room_code(text: String) -> String:
	var idx := text.find("room=")
	if idx < 0:
		return ""
	var code := ""
	for i in range(idx + 5, text.length()):
		var ch := text.substr(i, 1)
		if ch == "&" or ch == " " or ch == "\n" or ch == "#":
			break
		code += ch
	code = code.strip_edges()
	if code.length() < 4 or code.length() > 8:
		return ""
	for ch in code:
		if not "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".contains(ch):
			return ""
	return code.to_upper()

# Newest invite wins: the chat header offers one "join room" action, not a
# per-bubble button grid (the chat list is pure _draw and has no hit zones).
func _update_chat_invite() -> void:
	var code := ""
	for i in range(chat_messages.size() - 1, -1, -1):
		var entry: Variant = chat_messages[i]
		if not (entry is Dictionary):
			continue
		var body := str((entry as Dictionary).get("body", ""))
		if not body.contains("room="):
			continue
		code = _extract_room_code(body)
		if not code.is_empty():
			break
	if preview != null:
		preview.chat_invite_code = code

# The chat list is pure _draw, so invite bubbles get transparent buttons laid over
# the rects the preview recorded this frame. Rebuilt on a timer because the list
# re-lays out whenever a message arrives.
func _refresh_chat_invite_hits() -> void:
	if page != "chat" or preview == null:
		return
	var rects: Array = preview.chat_message_rects
	# Only rebuild when the bubbles actually moved: freeing a button while the
	# player is pressing it would swallow the tap.
	var sig := ""
	for i in range(mini(rects.size(), chat_messages.size())):
		var entry: Variant = chat_messages[i]
		if not (entry is Dictionary):
			continue
		var body := str((entry as Dictionary).get("body", ""))
		if not body.contains("room="):
			continue
		sig += str(rects[i]) + _extract_room_code(body) + ";"
	if sig == _chat_hits_signature:
		return
	_chat_hits_signature = sig
	for button in _chat_invite_hits:
		if is_instance_valid(button):
			button.queue_free()
	_chat_invite_hits.clear()
	for i in range(mini(rects.size(), chat_messages.size())):
		var entry: Variant = chat_messages[i]
		if not (entry is Dictionary):
			continue
		var body := str((entry as Dictionary).get("body", ""))
		if not body.contains("room="):
			continue
		var code := _extract_room_code(body)
		if code.is_empty():
			continue
		var rect: Rect2 = rects[i]
		if rect.size.y <= 1.0:
			continue
		# 精确等于气泡的可见矩形：不放大到 66px，也不外扩，否则列表底部的
		# 邀请会盖住输入框和发送键。
		_chat_invite_hits.append(_hit(rect, "进入房间 #" + code, func(): _enter_room(code), 0.0))

# Web touch path: the DOM history layer owns the touch and forwards a tap's
# design-space point here. Resolve it against the same buttons the desktop click
# uses, so both input paths join through one code path. Returns true when a
# bubble was hit.
func _activate_chat_invite_at(point: Vector2) -> bool:
	if page != "chat":
		return false
	_refresh_chat_invite_hits()
	for button in _chat_invite_hits:
		if not is_instance_valid(button):
			continue
		if button.get_global_rect().has_point(point):
			button.pressed.emit()
			return true
	return false

func _chat_field() -> void:
	# Back arrow lives in the chat header now; without it the page is a dead end.
	_hit(Rect2(10, 70, 56, 56), "返回好友", func(): _route("friends"))
	# Header avatar opens the friend's profile card — the only way to reach it
	# from a conversation without going back to the friends list.
	if not active_friend_id.is_empty():
		_hit(Rect2(70, 76, 64, 56), "查看好友资料", func(): _open_player_profile(active_friend_id, active_friend_name))
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "输入消息…"
	chat_input.position = Vector2(20, 762)
	chat_input.size = Vector2(400, 60)
	chat_input.max_length = SupabaseClient.MESSAGE_MAX_CHARS
	_style_bare_input(chat_input, 28)
	hotspot_layer.add_child(chat_input)
	_attach_caret_hint(chat_input)
	chat_input.text_submitted.connect(func(_text: String): _submit_chat())
	_hit(Rect2(448, 766, 72, 56), "发送消息", _submit_chat)
	# Web: 把 DOM 覆盖层贴到输入框位置（键盘弹起时会自己浮上去）
	_friend_chat_dom_warned = false
	call_deferred("_sync_web_friend_chat")


func _submit_chat() -> void:
	if chat_input == null:
		return
	var text := chat_input.text.strip_edges()
	if text.is_empty():
		return
	chat_input.clear()
	_web_friend_chat_clear()
	# 发完自己的消息自动回到底部，不然接着看旧消息会错过刚发出去的那条
	if preview != null:
		preview.chat_scroll = 0.0
	# Coroutine: deferred, never called bare.
	call_deferred("_send_chat_message", text)

func _toggle_ready() -> void:
	if solo_room:
		# 单机没有服务器，也没有第二个玩家要等：点一下准备就直接开。
		_start_solo_match()
		return
	if network_client != null and not network_client.connected:
		_notice("还在连接房间，请稍候")
		return
	if network_client != null and local_role == "spectator":
		_notice("观战中 · 先点上方一个空位入座")
		return
	# 全员就绪的瞬间服务端已经在开局；这时再发 ready=false 只会和 start 抢时序。
	if _room_all_ready():
		return
	local_ready = not local_ready
	if network_client != null: network_client.send_ready(local_ready)
	ready_changed.emit(local_ready)
	preview.room_ready = local_ready
	preview.queue_redraw()

func _set_match_mode(new_mode: int) -> void:
	if new_mode != 0 and new_mode != 1: return
	if match_mode == new_mode: return
	# 在线房间的模式是房主权限：其他人点了只解释，不发请求。
	if network_client != null and not room_is_host:
		_notice("只有房主可以修改模式")
		return
	match_mode = new_mode
	local_ready = false
	opponent_ready = false
	if network_client != null:
		network_client.send_ready(false)
		# 把模式切换同步给服务器，房间内所有人一起变（服务端会重排座位）
		network_client.send_mode(new_mode)
	preview.match_mode = match_mode
	preview.room_ready = false
	preview.room_opponent_ready = false
	preview.queue_redraw()
	if network_client == null and page == "waiting_room":
		call_deferred("_route", "waiting_room")

func _toggle_opponent_ready() -> void:
	opponent_ready = not opponent_ready
	preview.room_opponent_ready = opponent_ready
	preview.queue_redraw()

# Bottom bar in an online room: one honest toggle. The old "准备或开始" could
# only ever arm ready and then answered taps with a notice, which read as a
# dead button. Solo and local hotseat keep their existing entry points.
func _primary_room_action() -> void:
	if network_client == null:
		_ready_or_start()
		return
	if local_role == "spectator":
		_notice("观战中 · 先点上方一个空位入座")
		return
	_toggle_ready()

# Server truth: enough occupied seats and every one of them ready. Spectators
# have no seat, so they never count toward (or block) the start condition.
func _room_all_ready() -> bool:
	if network_client == null:
		return false
	var needed: int = 2 if match_mode == 0 else 4
	var occupied := 0
	var ready := 0
	for entry in network_players:
		if not entry is Dictionary:
			continue
		var occupant: Dictionary = entry
		if str(occupant.get("role", "player")) != "player": continue
		if int(occupant.get("slot", -1)) < 0: continue
		occupied += 1
		if bool(occupant.get("ready", false)):
			ready += 1
	return occupied >= needed and ready >= needed

func _ready_or_start() -> void:
	if solo_room:
		_start_solo_match()
		return
	if not local_ready: _toggle_ready()
	elif network_client != null: _notice("已准备，等待对手和服务器开始对局")
	elif not opponent_ready: _notice("请先让第二位玩家在本机点击准备")
	else:
		match_start_requested.emit()
		_route("match")

func _back_to_room() -> void:
	local_ready = false
	opponent_ready = false
	_route("waiting_room")

# --- 单机本地回环：一个人也能跑联机那条链路 ---------------------------------
# 屏幕上的 match_scene 变成纯客户端（只做插值、特效重放、音效重放），
# 物理跑在另一个隐藏的权威实例里，两者之间按 50ms 传一次跟联机一模一样的快照。

func _read_solo_loop_flag() -> bool:
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("new URLSearchParams(location.search).get('solo_net')==='1'", true))
	for arg in OS.get_cmdline_user_args():
		if arg == "--solo-net": return true
	return false

func _start_solo_loop() -> void:
	_stop_solo_loop()
	if match_scene == null: return
	var host: Node = load("res://main.tscn").instantiate()
	host.authoritative_host = true
	# 权威实例一个像素都不该画：HUD 在 CanvasLayer 里，Node2D 的 visible 管不到它。
	host.visible = false
	# 也绝不能吃输入：两个实例都响应 _unhandled_input 的话，一拖动就双份 begin()。
	host.set_process_unhandled_input(false)
	add_child(host)
	if host.formal_hud != null:
		host.formal_hud.visible = false
		host.formal_hud.set_process(false)
	if host.developer_panel != null:
		host.developer_panel.visible = false
	# 它只负责把事件写进快照，出声交给客户端。
	if host.sfx != null:
		host.sfx.set("muted", true)
	host.set_match_mode(match_mode)
	host.reset_game(perf_match_seed)
	host.set_player_owners("hotseat-blue", "hotseat-red")
	solo_loop_host = host
	solo_loop_seq = 0
	solo_loop_accum = 0.0
	match_scene.network_client_mode = true
	match_scene.input_team_id = -1
	# 客户端视角/名字/头像要按"客户端"重算一遍（上面那次 _apply_local_team 还是旧模式）。
	_apply_local_team()
	if not match_scene.shot_requested.is_connected(_solo_loop_shot):
		match_scene.shot_requested.connect(_solo_loop_shot)
	# 先推一帧：客户端在第一次 apply 前没有快照，画面会是空的。
	_solo_loop_push_snapshot()

func _stop_solo_loop() -> void:
	if match_scene != null and match_scene.shot_requested.is_connected(_solo_loop_shot):
		match_scene.shot_requested.disconnect(_solo_loop_shot)
	if solo_loop_host != null:
		solo_loop_host.queue_free()
		solo_loop_host = null
	solo_loop_accum = 0.0

# 玩家的出手转发给"服务器"。nonce 由快照同步，正常情况下必然匹配；
# 不匹配就打印出来而不是偷偷重试——回环是用来暴露问题的，不是掩盖问题。
func _solo_loop_shot(team_id: int, slot: int, shot_pull: Vector2, nonce: int) -> void:
	if solo_loop_host == null:
		if match_scene != null: match_scene.mark_shot_send_failed("solo_host_missing")
		return
	if not solo_loop_host.request_shot(team_id, slot, shot_pull, nonce):
		if match_scene != null: match_scene.mark_shot_rejected("solo_nonce")
		print("SOLO_LOOP_SHOT_REJECTED team=%d slot=%d nonce=%d/%d" % [team_id, slot, nonce, solo_loop_host.turn_manager.turn_nonce])

func _solo_loop_push_snapshot() -> void:
	if solo_loop_host == null or match_scene == null: return
	solo_loop_seq += 1
	var state: Dictionary = solo_loop_host.make_network_snapshot()
	state["seq"] = solo_loop_seq
	state["host_ms"] = Time.get_ticks_msec()
	state["paused"] = false
	match_scene.apply_network_snapshot(state)

func _start_match() -> void:
	preview.result_winner = ""
	if match_scene == null:
		match_scene = load("res://main.tscn").instantiate()
		add_child(match_scene)
		move_child(match_scene, 0)
		if match_scene.developer_panel != null: match_scene.developer_panel.hide()
		ball_portrait_overlay = BALL_PORTRAITS.new()
		ball_portrait_overlay.game = match_scene
		match_scene.add_child(ball_portrait_overlay)
	# 进棋盘前重读本账号头像，并刷新座位头像表：改名/换头像后不能还用旧脸。
	_reload_local_avatar_texture()
	if network_client != null: _refresh_slot_portraits()
	match_scene.set_match_mode(match_mode)
	# 先定观战身份再算视角/输入：spectator_mode 会同时关掉瞄准与击球。
	match_scene.spectator_mode = network_client != null and local_role == "spectator"
	_apply_local_team()
	match_scene.formal_hud.show()
	match_chat_log.clear()
	_update_match_chat_hud()
	match_scene.reset_game(perf_match_seed)
	if network_client != null:
		match_scene.network_client_mode = true
		match_scene.input_team_id = local_team if local_team >= 0 else -1
		if not match_scene.aim_state_requested.is_connected(network_client.send_aim_state):
			match_scene.aim_state_requested.connect(network_client.send_aim_state)
		if not match_scene.shot_requested.is_connected(_send_network_shot):
			match_scene.shot_requested.connect(_send_network_shot)
		# 这一杆本地算不了时向宿主订阅兜底轨迹（按需，宿主每杆清零）。
		if not match_scene.trajectory_needed.is_connected(_network_want_trajectory):
			match_scene.trajectory_needed.connect(_network_want_trajectory)
	else:
		# 进单机前必须清掉上一局联网留下的状态：network_client_mode 还是 true 的话，
		# PrototypeMatch 不会本地跑物理，只会等永远不会来的 snapshot——画面直接冻住。
		match_scene.network_client_mode = false
		match_scene.input_team_id = -1
		match_scene.spectator_mode = false
		match_scene.set_player_owners("hotseat-blue", "hotseat-red")
		# 开了本地回环就把上面这套换掉：隐藏权威实例跑物理，屏幕上的实例当客户端。
		if solo_loop_enabled:
			_start_solo_loop()
		# --solo goes straight into the match without passing the waiting room, so ask
		# for the solo music room here too (the function is idempotent).
		_join_solo_music()
	match_scene.visible = true
	match_scene.process_mode = Node.PROCESS_MODE_INHERIT
	match_ui.visible = true
	_build_match_ui()
	# 每局从收起态开始：顶栏只留一颗气泡，不抢棋盘上方的视线。
	match_spectator_expanded = false
	match_spectator_scroll = 0.0
	# formal_hud 在 _start_match 里才创建：观众名单必须在这里补推一次，
	# 否则 match_started 时写进去的那一份会落空，观众要等下一次 roster 才出现。
	_push_match_spectators()

func set_local_team(team: int) -> void:
	# -1 is a real value now: this connection watches instead of playing.
	if team != 0 and team != 1 and team != -1: return
	local_team = team
	if network_client != null:
		local_slot = network_client.assigned_slot
		# welcome 里已经带了角色/房主/介绍，先用它把首屏填对；
		# 随后到达的 room 状态会再校验一次。
		if network_client.connected:
			room_is_host = network_client.is_host
			local_role = network_client.role
			room_intro = network_client.room_intro
	if match_scene != null: _apply_local_team()

# The identity this connection is registered under on the server. Must stay in
# sync with _connect_network: the room keys seats by Supabase uid when signed in.
func _network_identity() -> String:
	if supabase != null and supabase.session_valid():
		var uid: String = supabase.current_user_id()
		if not uid.is_empty(): return uid
	return player_id

func _decode_avatar_png(encoded: String) -> Texture2D:
	if encoded.is_empty(): return null
	var image := Image.new()
	if image.load_png_from_buffer(Marshalls.base64_to_raw(encoded)) != OK: return null
	return ImageTexture.create_from_image(image)

# Rebuild slot_portraits from the roster. Only two sources are trusted: this
# device's own portrait for the local seat, and the PNG each occupant uploaded.
# Nothing is copied between slots, so a guest can never inherit the host's face.
func _refresh_slot_portraits() -> void:
	var next: Array[Texture2D] = [null, null, null, null]
	var sig := PackedStringArray(["", "", "", ""])
	var my_identity := _network_identity()
	for occupant in network_players:
		var seat: int = int(occupant.get("slot", -1))
		if seat < 0 or seat > 3: continue
		var pid := str(occupant.get("player_id", ""))
		var encoded := str(occupant.get("avatar", ""))
		sig[seat] = "%s|%d|%d" % [pid, encoded.length(), encoded.hash()]
		if not my_identity.is_empty() and pid == my_identity:
			# Our own face comes straight from the local profile, no round trip.
			next[seat] = avatar_textures[0] if avatar_textures.size() > 0 else null
		elif not encoded.is_empty():
			# The roster rebroadcasts on every ready tap; only inflate the PNG when
			# the payload really changed.
			if sig[seat] == slot_avatar_sig[seat] and slot_portraits[seat] != null:
				next[seat] = slot_portraits[seat]
			else:
				next[seat] = _decode_avatar_png(encoded)
	slot_avatar_sig = sig
	slot_portraits = next

# Portrait for one seat, or null when that player has no real image.
# Never borrow avatar_textures[1]/[3] here: those are this device's preset faces,
# identical on every client, so every unanswered seat used to look like the host.
# Null means "draw the initial instead" (FormalHud / waiting room already do).
func _seat_portrait(seat: int) -> Texture2D:
	if seat >= 0 and seat < slot_portraits.size() and slot_portraits[seat] != null:
		return slot_portraits[seat]
	return null

# Board portraits, in world slot order (0/1 blue, 2/3 red). Same array for both
# clients — the board already has fixed sides, no view rotation belongs here.
func _match_portraits() -> Array[Texture2D]:
	var out: Array[Texture2D] = [null, null, null, null]
	if network_client == null:
		# Local hotseat: only this account owns a real portrait. The on-device
		# opponent has no account, so its seats stay null and render as initials.
		var mine: Texture2D = avatar_textures[0] if avatar_textures.size() > 0 else null
		var blue: Texture2D = mine if local_team == 0 else null
		var red: Texture2D = mine if local_team != 0 else null
		out[0] = blue
		out[1] = blue
		out[2] = red
		out[3] = red
	elif match_mode == 1:
		for seat in range(4):
			out[seat] = _seat_portrait(seat)
	else:
		# Two-player: the second seat on each side stays empty, mirror the occupied one.
		var blue_seat: Texture2D = _seat_portrait(0)
		var red_seat: Texture2D = _seat_portrait(2)
		out[0] = blue_seat
		out[1] = blue_seat
		out[2] = red_seat
		out[3] = red_seat
	return out

# The local portrait just changed: repaint the local-gallery views and the board.
# Waiting-room rows never read portraits — they draw initials — so that array stays
# "the local gallery" (index 0 = me) for the profile card and the lobby, while the
# board reads slot_portraits. Online the seat table is rebuilt first, otherwise the
# local seat keeps the old texture until the next roster broadcast.
func _refresh_own_portrait_views() -> void:
	if network_client != null:
		_refresh_slot_portraits()
	if preview != null:
		preview.portraits = avatar_textures
		preview.queue_redraw()
	if match_scene != null: _apply_local_team()

func _apply_local_team() -> void:
	if match_scene == null: return
	_build_match_slot_names()
	var portraits: Array[Texture2D] = _match_portraits()
	var names: PackedStringArray = match_slot_names.duplicate()
	var watching: bool = network_client != null and local_role == "spectator"
	match_scene.spectator_mode = watching
	if watching:
		# 观众从不控制球，视角固定蓝方；输入过滤器留给引擎当"无归属"。
		match_scene.assign_local_player(0)
		match_scene.input_slot_filter = -1
	elif match_mode == 1:
		# 视角按自己的球槽决定（slot 0/1 蓝方视角、2/3 红方视角），并只允许操作自己的球
		var view_slot: int = local_slot if local_slot >= 0 else (0 if local_team == 0 else 2)
		match_scene.assign_local_player(view_slot)
		match_scene.input_slot_filter = local_slot
	else:
		match_scene.assign_local_player(0 if local_team == 0 else 2)
		match_scene.input_slot_filter = -1
	match_scene.formal_hud.player_portraits = portraits
	match_scene.formal_hud.player_names = names
	ball_portrait_overlay.portraits = portraits
	ball_portrait_overlay.queue_redraw()

# 对局 HUD 的四个座位名，按球槽绑定真实昵称。
# 联机以服务端 roster 为准（每个 slot 就是本人名字）；单机热座蓝方是自己、红方是本机对手。
# 双人模式一队只有一个人，本队两个球共用这一个名字——不能给空槽编"玩家 2"。
func _build_match_slot_names() -> void:
	var by_slot := {}
	for occupant in network_players:
		var seat: int = int(occupant.get("slot", -1))
		if seat < 0 or seat > 3: continue
		var who := str(occupant.get("name", "")).strip_edges()
		by_slot[seat] = who if not who.is_empty() else "玩家 %d" % (seat + 1)
	var names := PackedStringArray(["", "", "", ""])
	if network_client != null:
		if match_mode == 1:
			for seat in range(4):
				names[seat] = str(by_slot.get(seat, "玩家 %d" % (seat + 1)))
		else:
			var blue := str(by_slot.get(0, ""))
			if blue.is_empty(): blue = str(by_slot.get(1, ""))
			var red := str(by_slot.get(2, ""))
			if red.is_empty(): red = str(by_slot.get(3, ""))
			names[0] = blue if not blue.is_empty() else "蓝方"
			names[1] = names[0]
			names[2] = red if not red.is_empty() else "红方"
			names[3] = names[2]
	else:
		var mine := display_name.strip_edges()
		if mine.is_empty(): mine = "我"
		var blue_local := mine if local_team == 0 else "本地对手"
		var red_local := "本地对手" if local_team == 0 else mine
		names = PackedStringArray([blue_local, blue_local, red_local, red_local])
	# 四人局同昵称很常见（默认名/同一批测试号），四个座位写同一个字根本分不清人。
	# 只对真正重名的第 2 人起追加序号，正常昵称不受影响。
	if match_mode == 1:
		var seen := {}
		for seat in range(4):
			var who := names[seat]
			if who.is_empty(): continue
			var nth := int(seen.get(who, 0)) + 1
			seen[who] = nth
			if nth > 1: names[seat] = "%s%d" % [who, nth]
	match_slot_names = names

# 进对局前重读一次本账号头像：在别的屏换过头像、或在另一台设备登录后刚拉下来，
# 都不能让棋盘继续用旧脸。
func _reload_local_avatar_texture() -> void:
	var path := _avatar_path()
	if not FileAccess.file_exists(path): return
	var image: Image = Image.load_from_file(path)
	if image == null or image.is_empty(): return
	if avatar_textures.is_empty(): return
	avatar_textures[0] = ImageTexture.create_from_image(image)

func _team_name(team: int) -> String:
	# 单机热座没有网络名单，但 HUD 上的红方不能是空白
	if solo_room: return display_name if team == 0 else "本地对手"
	for occupant in network_players:
		if int(occupant.get("team", -1)) == team: return str(occupant.get("name", "玩家"))
	# 对方没进房间时不能编名字。原来 fallback 硬编码返回"绯月"，
	# 结果单人也能看到"红方有人"，是纯假数据。
	if local_team == team: return display_name
	return ""

# --- 重载后找回座位：房间号存 sessionStorage（只在当前标签页有效） ---
# 手机切后台被系统回收时页面是重新加载的：user:// 里的 resume_key 还在，
# 但内存里的 room_code 会没。没有房间号，客户端只会落到大厅，服务端留的座位就白等了。
func _read_saved_room() -> String:
	if not OS.has_feature("web"): return ""
	var value: Variant = JavaScriptBridge.eval(
		"(function(){try{return sessionStorage.getItem('%s')||''}catch(e){return ''}})()" % ROOM_STORE_KEY)
	return str(value).strip_edges().to_upper()

func _save_room(code: String) -> void:
	if not OS.has_feature("web"): return
	# 只保留 A-Z0-9，避免把引号之类的字符拼进 JS 字符串
	var safe := ""
	for ch in code.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			safe += ch
	var script := "(function(){try{var v='%s';if(v){sessionStorage.setItem('%s',v)}else{sessionStorage.removeItem('%s')}}catch(e){}})()" % [safe, ROOM_STORE_KEY, ROOM_STORE_KEY]
	JavaScriptBridge.eval(script)

func _leave_room(notify_server := true) -> void:
	_reset_room_invites()
	# 主动退出先告诉网关一声：确认没人后立即回收房间。
	# 掉线（断网/切后台）不会走这里，网关按 90 秒宽限保留，人回来还能接上。
	if notify_server and not room_code.is_empty():
		_notify_room_leave(room_code)
	# 断开连接再回大厅：留着 client 会顶着旧身份继续占座位
	if network_client != null:
		network_client.queue_free()
		network_client = null
	room_code = ""
	_save_room("")
	restored_room_code = ""
	solo_room = false
	room_label = ""
	room_is_host = false
	room_host_id = ""
	local_role = "player"
	local_slot = -1
	local_team = -1
	room_intro = ""
	room_phase = "waiting"
	room_spectators = []
	spectator_portraits.clear()
	spectator_avatar_sig.clear()
	match_spectator_scroll = 0.0
	spectator_scroll = 0.0
	_room_roster_signature = ""
	room_chat_log.clear()
	if preview != null: preview.set_meta("room_chat_messages", [])
	local_ready = false
	opponent_ready = false
	_route("lobby")

# 网关据此判断"这桌是主动散了"而不是"有人掉线在等回来"。
# 请求失败无所谓：最坏退化成按 90 秒宽限回收，不影响任何玩法。
func _notify_room_leave(code: String) -> void:
	var base := _api_base()
	if base.is_empty(): return
	var http := HTTPRequest.new()
	http.timeout = 4.0
	add_child(http)
	http.request_completed.connect(func(_result, _code, _headers, _body): http.queue_free())
	http.request(base + "/api/rooms/leave", ["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"code": code}))

# --- 多房间：网关 /api/rooms 提供列表与建房 ---
func _api_base() -> String:
	if not api_base_url.is_empty():
		return api_base_url.strip_edges().trim_suffix("/")
	# network_url 形如 wss://host/ws 或 ws://host/ws
	if network_url.is_empty(): return ""
	var base := network_url.replace("wss://", "https://").replace("ws://", "http://")
	var cut := base.find("/ws")
	if cut > 0: base = base.substr(0, cut)
	return base

func _start_room_poll() -> void:
	if room_poll_timer == null:
		room_poll_timer = Timer.new()
		room_poll_timer.wait_time = 3.0
		room_poll_timer.timeout.connect(_fetch_rooms)
		add_child(room_poll_timer)
	room_poll_timer.start()
	_fetch_rooms()

func _parse_rooms(body: PackedByteArray) -> Array:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if parsed is Dictionary and parsed.get("rooms") is Array:
		return parsed.get("rooms")
	return []

func _fetch_rooms() -> void:
	var base := _api_base()
	if base.is_empty(): return
	var http := HTTPRequest.new()
	# 不复用会堆：每 3 秒一个请求，遇到卡死就一直挂在那里。8 秒后让 Godot 自己 abort。
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(_result, code, _headers, body):
		if code == 200 and preview != null:
			room_list_error = ""
			preview.room_list = _parse_rooms(body)
			preview.room_list_error = ""
			preview.queue_redraw()
			# 列表一变就重挂行热区：只在 _route("lobby") 里建一次的话，
			# 后出现的桌子只有文字没有按钮，点了完全没反应（跨网测试时必踩）。
			if page == "lobby": _bind_lobby_room_hits()
		elif preview != null:
			# 请求失败和"真没人开桌"必须能分开看，否则排查时完全瞎。
			room_list_error = "房间列表加载失败（%d）" % code if code > 0 else "房间列表加载失败 · 网络异常"
			preview.room_list_error = room_list_error
			preview.queue_redraw()
		http.queue_free()
	)
	http.request(base + "/api/rooms")

# 只拉一次的版本：输房间号 / 恢复上次房间时用，别信 3 秒前的缓存列表。
# on_done(rooms, ok)：ok=false 表示"没拿到"，不能当成"房间不存在"。
func _fetch_rooms_once(on_done: Callable) -> void:
	var base := _api_base()
	if base.is_empty():
		on_done.call([], false)
		return
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(func(_result, code, _headers, body):
		var ok: bool = code == 200
		var rooms: Array = _parse_rooms(body) if ok else []
		if is_instance_valid(http): http.queue_free()
		on_done.call(rooms, ok)
	)
	http.request(base + "/api/rooms")

func _create_room() -> void:
	var base := _api_base()
	if base.is_empty():
		_notice("未连接到服务器")
		return
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, code, _headers, body):
		if code == 200:
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary and not str(parsed.get("code", "")).is_empty():
				_room_music_eval("storeOwner(%s,%s)" % [JSON.stringify(str(parsed.code)), JSON.stringify(str(parsed.get("music_owner", "")))])
				_enter_room(str(parsed.get("code")))
			else:
				_notice("创建房间失败")
		else:
			_notice("创建房间失败（%d）" % code)
		http.queue_free()
	)
	http.request(base + "/api/rooms/claim", ["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"host": display_name}))

func _enter_room(code: String) -> void:
	_reset_room_invites()
	solo_room = false
	# 换桌必须换 socket。旧 client 还活着的话，_route 里的 "network_client == null"
	# 守卫会跳过重连：界面显示新房间号、邀请链接也是新码，但 WS 还连在上一桌，
	# 对方按新码进来后两边互相看不见（表现就是"进桌只有自己"）。
	if network_client != null:
		network_client.queue_free()
		network_client = null
	room_code = code.to_upper()
	_save_room(room_code)
	restored_room_code = ""
	room_label = "房间 #%s" % room_code
	# 房主/角色都以服务端的 room 状态为准；在它到达之前先按"观众"显示，
	# 不给一个可能并不存在的准备按钮。
	room_is_host = false
	room_host_id = ""
	local_role = "spectator"
	local_slot = -1
	local_team = -1
	room_intro = ""
	room_phase = "waiting"
	room_spectators = []
	spectator_portraits.clear()
	spectator_avatar_sig.clear()
	match_spectator_scroll = 0.0
	spectator_scroll = 0.0
	_room_roster_signature = ""
	local_ready = false
	opponent_ready = false
	_route("waiting_room")

# 本地单机：不建连、不占网关端口、不需要房间号，只借"等待房"这一屏确认开局。
# 真正的对局走本地热座（蓝红两边都由这一台操作），和 --solo 启动是同一条路径。
func _enter_solo_room() -> void:
	_reset_room_invites()
	solo_room = true
	if network_client != null:
		network_client.queue_free()
		network_client = null
	room_code = ""
	room_label = "单机测试"
	room_is_host = true
	match_mode = 0
	local_role = "player"
	local_team = 0
	local_slot = -1
	room_host_id = ""
	room_intro = ""
	room_phase = "waiting"
	room_spectators = []
	match_spectator_scroll = 0.0
	spectator_scroll = 0.0
	local_ready = false
	opponent_ready = false
	room_chat_log.clear()
	if preview != null:
		preview.set_meta("room_chat_messages", [])
		preview.room_slot_names = PackedStringArray([display_name, "", "", ""])
		preview.room_slot_ready = [false, false, false, false]
		# 单人房只有自己一座：座位头像直接用自己的账号头像，别画成占位。
		_reload_local_avatar_texture()
		var solo_faces: Array[Texture2D] = [null, null, null, null]
		if avatar_textures.size() > 0: solo_faces[0] = avatar_textures[0]
		preview.room_slot_portraits = solo_faces
		preview.room_ready = false
		preview.room_opponent_ready = false
	_join_solo_music()
	_route("waiting_room")

func _start_solo_match() -> void:
	local_ready = true
	match_start_requested.emit()
	_route("match")

# 启动时进哪个页面，只在这里判断：带 room= 的链接直达，重载恢复的房间先验一次。
func _enter_room_or_lobby() -> void:
	if room_code.is_empty():
		_route("lobby")
		return
	room_label = "房间 #%s" % room_code
	if restored_room_code.is_empty():
		_route("waiting_room")
		if page == "waiting_room": _connect_network()
		return
	# 恢复的房间可能已经被网关回收（空桌 60 秒就杀实例）。先看一眼列表：
	# 直接连的话 WS 会被 404，客户端会对着死房间重试 88 秒，用户只看到"一直连不上"。
	_route("lobby")
	_verify_restored_room(restored_room_code)

func _verify_restored_room(code: String) -> void:
	_fetch_rooms_once(func(rooms: Array, ok: bool):
		if not ok:
			# 网络/登录失败不代表房间没了：保留 sessionStorage 里的房间号，
			# 别把"这次没查到"当成"房间解散了"。
			_notice("网络异常，暂时无法确认上次的房间，请稍后从大厅重进")
			return
		restored_room_code = ""
		for candidate in rooms:
			if str(candidate.get("code", "")).to_upper() != code: continue
			if not bool(candidate.get("open", false)) and int(candidate.get("players", 0)) == 0: continue
			_enter_room(code)
			return
		_save_room("")
		_notice("上一桌已经结束，已回到大厅")
	)

func _build_room_chat() -> void:
	room_chat_input = LineEdit.new()
	room_chat_input.placeholder_text = "说点什么…"
	# 坐标与 _waiting_room_v3_chat() 的 input_rect 保持一致
	room_chat_input.position = Vector2(20, 764)
	room_chat_input.size = Vector2(348, 88)
	room_chat_input.max_length = 80
	room_chat_input.add_theme_font_size_override("font_size", 28)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	room_chat_input.add_theme_stylebox_override("normal", box)
	room_chat_input.add_theme_stylebox_override("focus", box)
	room_chat_input.add_theme_color_override("font_color", Color("f5f5f7"))
	room_chat_input.add_theme_color_override("font_placeholder_color", Color("5c5c61"))
	room_chat_input.add_theme_color_override("caret_color", Color("6fd3e8"))
	room_chat_input.text_submitted.connect(func(_text): _send_room_chat())
	hotspot_layer.add_child(room_chat_input)
	_attach_caret_hint(room_chat_input)
	_hit(Rect2(380, 764, 140, 88), "发送消息", _send_room_chat)

func _send_room_chat() -> void:
	# 节点可能在 _clear(hotspot_layer) 后失效，free 过的引用不等于 null
	if not is_instance_valid(room_chat_input): return
	var body := room_chat_input.text.strip_edges()
	if body.is_empty(): return
	if network_client == null:
		_notice("未连接到房间，无法发送")
		return
	network_client.send_room_chat(body.left(80))
	room_chat_input.text = ""

func _init_web_match_chat() -> void:
	if not OS.has_feature("web"):
		return
	web_match_chat_callback = JavaScriptBridge.create_callback(_on_web_match_chat)
	web_chat_media_callback = JavaScriptBridge.create_callback(_on_web_chat_media_picked)
	JavaScriptBridge.get_interface("window").arenaMatchChatAction = web_match_chat_callback
	JavaScriptBridge.get_interface("window").arenaChatMediaPicked = web_chat_media_callback
	JavaScriptBridge.eval(r"""
(function () {
	if (window.arenaMatchChat) return;
	var ios = /iPad|iPhone|iPod/.test(navigator.userAgent)
		|| (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
	var wechat = /MicroMessenger/i.test(navigator.userAgent);
	var touchKeyboard = ios || window.matchMedia('(any-pointer: coarse)').matches;
	var form = document.createElement('form');
	form.style.cssText = 'position:absolute;display:none;z-index:2147482999;box-sizing:border-box;align-items:stretch;gap:4px;margin:0;';
	var input = document.createElement('input');
	input.maxLength = 80;
	input.autocomplete = 'off';
	input.setAttribute('enterkeyhint', 'send');
	input.setAttribute('aria-label', '对局聊天');
	// Set the minimum font size before the first focus to avoid iOS input zoom.
	input.style.cssText = 'flex:1;min-width:0;box-sizing:border-box;font-size:16px;border:1px solid #6a4fb8;border-radius:8px;padding:0 8px;outline:none;color:#fff;-webkit-text-fill-color:#fff;caret-color:#fff;background:transparent;';
	var plus = document.createElement('label');
	var send = document.createElement('button');
	for (var button of [plus, send]) {
		button.style.cssText = 'display:none;flex:none;min-width:44px;box-sizing:border-box;margin:0;padding:0 7px;border:1px solid #6a4fb8;border-radius:8px;color:#fff;background:#18112d;touch-action:manipulation;';
	}
	plus.style.position = 'relative';
	plus.style.alignItems = plus.style.justifyContent = 'center';
	plus.textContent = '＋';
	var fileInput = document.createElement('input');
	fileInput.type = 'file';
	fileInput.accept = 'image/jpeg,image/png,image/gif,image/webp,image/heic,image/heif';
	fileInput.setAttribute('aria-label', '选择图片或动图');
	fileInput.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;margin:0;opacity:0;cursor:pointer;';
	plus.appendChild(fileInput);
	send.type = 'submit';
	send.textContent = '发送';
	send.addEventListener('mousedown', function (event) {
		// Preserve the input focus through click so the keyboard cannot move the button mid-tap.
		if (document.activeElement === input) event.preventDefault();
	});
	var status = document.createElement('div');
	status.setAttribute('role', 'status');
	status.style.cssText = 'position:absolute;left:0;bottom:100%;margin-bottom:2px;border-radius:4px;padding:3px 6px;background:#18112d;color:#fff;font:14px sans-serif;pointer-events:none;';
	status.hidden = true;
	var tapToEdit = null;
	var field = input;
	if (ios) {
		field = document.createElement('div');
		field.style.cssText = 'position:relative;display:flex;flex:1;min-width:0;';
		tapToEdit = document.createElement('button');
		tapToEdit.type = 'button';
		tapToEdit.setAttribute('aria-label', '输入聊天消息');
		tapToEdit.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;padding:0;border:0;background:transparent;touch-action:manipulation;';
		tapToEdit.addEventListener('click', focusIOSInput);
		field.append(input, tapToEdit);
	}
	form.append(plus, field, send, status);
	var history = document.createElement('div');
	history.setAttribute('aria-label', '对局聊天记录');
	history.style.cssText = 'position:fixed;display:none;z-index:2147482998;overflow:hidden;touch-action:none;user-select:none;';
	if (ios) history.style.position = 'absolute';
	document.body.appendChild(history);
	document.body.appendChild(form);
	var viewer = document.createElement('dialog');
	viewer.setAttribute('aria-label', '聊天图片预览');
	viewer.style.cssText = 'position:fixed;inset:0;margin:0;padding:42px 16px 18px;box-sizing:border-box;width:100%;height:100%;max-width:none;max-height:none;overflow:hidden;background:rgba(9,6,16,.94);border:0;';
	var nativeDialog = typeof viewer.showModal === 'function';
	if (!nativeDialog) {
		viewer.style.display = 'none';
		viewer.style.zIndex = '2147483000';
		viewer.setAttribute('role', 'dialog');
		viewer.setAttribute('aria-modal', 'true');
	}
	var viewerContent = document.createElement('div');
	viewerContent.style.cssText = 'display:grid;place-items:center;width:100%;height:100%;pointer-events:none;';
	var thumbnailStyle = 'position:absolute;display:none;cursor:zoom-in;';
	var previewedImage = null;
	var pressedBackdrop = false;
	var closeViewer = document.createElement('button');
	closeViewer.type = 'button';
	closeViewer.autofocus = true;
	closeViewer.textContent = '×';
	closeViewer.setAttribute('aria-label', '关闭图片预览');
	closeViewer.style.cssText = 'position:absolute;top:max(8px,env(safe-area-inset-top));right:max(8px,env(safe-area-inset-right));width:44px;height:44px;border:0;border-radius:22px;color:white;background:#18112d;font:28px system-ui;';
	viewer.append(viewerContent, closeViewer);
	document.body.appendChild(viewer);
	closeViewer.addEventListener('click', closeImagePreview);
	viewer.addEventListener('pointerdown', function (event) { pressedBackdrop = event.target === viewer; });
	viewer.addEventListener('pointercancel', function () { pressedBackdrop = false; });
	viewer.addEventListener('click', function (event) {
		var close = pressedBackdrop && event.target === viewer;
		pressedBackdrop = false;
		if (close) closeImagePreview();
	});
	viewer.addEventListener('cancel', function (event) {
		event.preventDefault();
		closeImagePreview();
	});
	function closeImagePreview() {
		if (nativeDialog) viewer.close();
		else {
			viewer.removeAttribute('open');
			viewer.style.display = 'none';
		}
		if (!previewedImage) return;
		var image = previewedImage;
		previewedImage = null;
		for (var thumbnail of images.values()) {
			if (thumbnail.element !== image) continue;
			image.style.cssText = thumbnailStyle;
			history.appendChild(image);
			layout();
			return;
		}
		image.remove();
	}
	function layoutViewer() {
		if (!viewer.hasAttribute('open') || !previewedImage) return;
		var viewport = window.visualViewport;
		viewer.style.left = ((viewport && viewport.offsetLeft) || 0) + 'px';
		viewer.style.top = ((viewport && viewport.offsetTop) || 0) + 'px';
		viewer.style.width = (viewport ? viewport.width : window.innerWidth) + 'px';
		viewer.style.height = (viewport ? viewport.height : window.innerHeight) + 'px';
		var bounds = viewerContent.getBoundingClientRect();
		var width = previewedImage.naturalWidth;
		var height = previewedImage.naturalHeight;
		if (!width || !height) return;
		var scale = Math.min(bounds.width / width, bounds.height / height);
		previewedImage.style.width = (width * scale) + 'px';
		previewedImage.style.height = (height * scale) + 'px';
	}
	function openImage(image) {
		if (!visible || viewer.hasAttribute('open')) return;
		dismissKeyboard();
		// Reuse the loaded image so opening a large preview doesn't start another decode.
		pressedBackdrop = false;
		previewedImage = image;
		image.style.cssText = 'display:block;max-width:100%;max-height:100%;object-fit:contain;pointer-events:auto;';
		viewerContent.appendChild(image);
		if (nativeDialog) viewer.showModal();
		else {
			viewer.setAttribute('open', '');
			viewer.style.display = 'block';
			closeViewer.focus();
		}
		layoutViewer();
	}
	var rect = null;
	var historyRect = null;
	var historyScale = 1;
	var dragPointer = null;
	var dragY = 0;
	var dragX = 0;
	var tappedImage = null;
	var room = null;
	var images = new Map();
	var labels = [];
	var visible = false;
	var canPick = true;
	var textSize = 20;
	var composing = false;
	var selection = null;
	var iosStage = null;
	var iosOpeningInput = false;
	var layoutFrame = 0;
	var viewportSettleTimer;
	var viewportSettleTimer2;
	var statusTimer;
	function scheduleLayout() {
		if (layoutFrame) return;
		layoutFrame = requestAnimationFrame(function () {
			layoutFrame = 0;
			layout();
		});
	}
	function dismissKeyboard() {
		var active = document.activeElement;
		if (form.contains(active)) active.blur();
	}
	function settleLayout() {
		scheduleLayout();
		if (!ios) return;
		// The first viewport event can arrive before the keyboard animation settles.
		clearTimeout(viewportSettleTimer);
		clearTimeout(viewportSettleTimer2);
		viewportSettleTimer = setTimeout(scheduleLayout, 260);
		viewportSettleTimer2 = setTimeout(scheduleLayout, 680);
	}
	function focusIOSInput() {
		if (!visible) return;
		// Position the editor near the top before the trusted tap opens the keyboard.
		// Focusing the field at its resting position can make WebKit pan the whole page.
		iosOpeningInput = true;
		layout();
		input.focus({preventScroll:true});
		iosOpeningInput = false;
		layout();
		settleLayout();
	}
	function anchorIOSBoard(canvas, viewLeft, viewTop, viewHeight, inputFocused) {
		var width = canvas.clientWidth;
		var height = canvas.clientHeight;
		var scale = Math.min(width / 540, height / 960);
		if (!scale) return false;
		var designX = (width - 540 * scale) / 2;
		var designY = (height - 960 * scale) / 2;
		var keyboardVisible = iosStage && viewHeight + 72 < iosStage.viewHeight;
		if (iosStage && (!visible || (!inputFocused && !iosOpeningInput
			&& (!keyboardVisible || window.innerWidth !== iosStage.windowWidth)))) {
			canvas.style.transform = iosStage.transform;
			canvas.style.transformOrigin = iosStage.transformOrigin;
			iosStage = null;
			keyboardVisible = false;
		}
		if (!iosStage && visible && (inputFocused || iosOpeningInput)) {
			iosStage = {
				x:canvas.offsetLeft + designX - viewLeft,
				y:canvas.offsetTop + designY - viewTop,
				scale:scale,
				viewHeight:viewHeight,
				windowWidth:window.innerWidth,
				transform:canvas.style.transform,
				transformOrigin:canvas.style.transformOrigin
			};
			canvas.style.transformOrigin = '0 0';
		}
		if (iosStage) {
			// Keep the pre-keyboard playfield rectangle even if Godot resizes its canvas.
			var ratio = iosStage.scale / scale;
			var x = viewLeft + iosStage.x - canvas.offsetLeft - designX * ratio;
			var y = viewTop + iosStage.y - canvas.offsetTop - designY * ratio;
			var next = x || y || ratio !== 1
				? 'translate(' + x + 'px,' + y + 'px) scale(' + ratio + ')'
				: iosStage.transform;
			if (canvas.style.transform !== next) canvas.style.transform = next;
		}
		return !!keyboardVisible;
	}
	function layout() {
		layoutViewer();
		var canvas = document.getElementById('canvas');
		if (!canvas) return;
		var inputFocused = document.activeElement === input;
		var editing = form.contains(document.activeElement) && document.activeElement !== tapToEdit;
		var viewport = window.visualViewport;
		var viewLeft = viewport ? viewport.offsetLeft : 0;
		var viewTop = viewport ? viewport.offsetTop : 0;
		var viewWidth = viewport ? viewport.width : window.innerWidth;
		var viewHeight = viewport ? Math.min(viewport.height, window.innerHeight) : window.innerHeight;
		var documentX = 0;
		var documentY = 0;
		var keyboardVisible = false;
		if (ios) {
			var bodyBounds = document.body.getBoundingClientRect();
			documentX = -bodyBounds.left;
			documentY = -bodyBounds.top;
			// pageTop can include WebKit's native keyboard adjustment. Using it again
			// can push the playfield down behind the keyboard.
			var scroll = document.scrollingElement;
			viewLeft = Math.max(0, (viewLeft + (scroll ? scroll.scrollLeft : window.scrollX)) || documentX);
			viewTop = Math.max(0, (viewTop + (scroll ? scroll.scrollTop : window.scrollY)) || documentY);
			keyboardVisible = anchorIOSBoard(canvas, viewLeft, viewTop, viewHeight, inputFocused);
			tapToEdit.hidden = inputFocused || iosOpeningInput;
		}
		if (!visible || !rect) return;
		var bounds = canvas.getBoundingClientRect();
		if (!bounds.width || !bounds.height) return;
		var scale = Math.min(bounds.width / 540, bounds.height / 960);
		var x = bounds.left + documentX + (bounds.width - 540 * scale) / 2;
		var y = bounds.top + documentY + (bounds.height - 960 * scale) / 2;
		var expanded = editing || iosOpeningInput || !!input.value;
		var directPicker = canPick && (ios || wechat);
		var height = Math.max(rect[3] * scale, (expanded || directPicker) ? 44 : 0);
		var left = x + rect[0] * scale;
		var top = y + rect[1] * scale;
		var width = rect[2] * scale;
		if (touchKeyboard || editing) {
			width = Math.min(width, Math.max(0, viewWidth - 8));
			left = Math.max(viewLeft + 4, Math.min(left, viewLeft + viewWidth - width - 4));
			top = Math.max(viewTop + 4, Math.min(top, viewTop + viewHeight - height - 4));
		}
		if (iosStage) {
			// Dock only the composer. The keyboard may cover the bottom of the board.
			if (keyboardVisible) top = Math.max(viewTop + 4, viewTop + viewHeight - height - 12);
			else if (inputFocused || iosOpeningInput) top = viewTop + 12;
		}
		form.style.left = (left + (ios ? 0 : window.scrollX)) + 'px';
		form.style.top = (top + (ios ? 0 : window.scrollY)) + 'px';
		form.style.width = width + 'px';
		form.style.height = height + 'px';
		historyScale = scale;
		history.style.left = (x + historyRect[0] * scale) + 'px';
		history.style.top = (y + historyRect[1] * scale) + 'px';
		history.style.width = (historyRect[2] * scale) + 'px';
		history.style.height = (historyRect[3] * scale) + 'px';
		input.style.background = expanded ? '#18112d' : 'transparent';
		for (var control of [input, plus, send]) control.style.fontSize = Math.max(16, textSize * scale) + 'px';
		plus.style.display = (directPicker || (expanded && canPick)) ? 'flex' : 'none';
		send.style.display = expanded ? 'block' : 'none';
		for (var image of images.values()) {
			if (image.element === previewedImage) continue;
			var tile = image.rect;
			image.element.style.left = (tile[0] * scale) + 'px';
			image.element.style.top = (tile[1] * scale) + 'px';
			image.element.style.width = (tile[2] * scale) + 'px';
			image.element.style.height = (tile[3] * scale) + 'px';
			image.element.style.display = 'block';
		}
		for (var label of labels) {
			label.element.style.left = ((label.left || 0) * scale) + 'px';
			label.element.style.top = (label.top * scale) + 'px';
			label.element.style.width = (label.width * scale) + 'px';
			label.element.style.fontSize = (label.fontSize * scale) + 'px';
			label.element.style.lineHeight = ((label.lineHeight || 24) * scale) + 'px';
		}
	}
	function submit() {
		if (visible && !composing && input.value.trim() && window.arenaMatchChatAction) {
			window.arenaMatchChatAction('send', input.value);
		}
	}
	input.addEventListener('compositionstart', function () { composing = true; });
	input.addEventListener('compositionend', function () { composing = false; });
	input.addEventListener('input', layout);
	input.addEventListener('keydown', function (event) {
		event.stopPropagation();
		if (event.key !== 'Enter' || event.isComposing || event.keyCode === 229 || composing) return;
		event.preventDefault();
		if (!event.repeat) submit();
	});
	form.addEventListener('submit', function (event) { event.preventDefault(); submit(); });
	form.addEventListener('focusin', function () { layout(); settleLayout(); });
	form.addEventListener('focusout', settleLayout);
	var imageLimit = 2 * 1024 * 1024;
	function readImageBlob(blob, headerOnly) {
		return new Promise(function (resolve, reject) {
			var reader = new FileReader();
			reader.onload = function () { resolve(reader.result); };
			reader.onerror = reader.onabort = reject;
			if (headerOnly) reader.readAsArrayBuffer(blob.slice(0, 8));
			else reader.readAsDataURL(blob);
		});
	}
	function imageMime(header) {
		var bytes = new Uint8Array(header);
		if (bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255) return 'image/jpeg';
		if (bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71
			&& bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10) return 'image/png';
		if (bytes[0] === 71 && bytes[1] === 73 && bytes[2] === 70 && bytes[3] === 56
			&& (bytes[4] === 55 || bytes[4] === 57) && bytes[5] === 97) return 'image/gif';
		return '';
	}
	function photoAsJpeg(file) {
		return new Promise(function (resolve, reject) {
			var url = URL.createObjectURL(file);
			var photo = new Image();
			photo.onload = function () {
				URL.revokeObjectURL(url);
				try {
					var scale = Math.min(1, 1440 / Math.max(photo.naturalWidth, photo.naturalHeight));
					var canvas = document.createElement('canvas');
					canvas.width = Math.max(1, Math.round(photo.naturalWidth * scale));
					canvas.height = Math.max(1, Math.round(photo.naturalHeight * scale));
					var context = canvas.getContext('2d', {alpha:false});
					context.fillStyle = '#fff';
					context.fillRect(0, 0, canvas.width, canvas.height);
					context.drawImage(photo, 0, 0, canvas.width, canvas.height);
					canvas.toBlob(resolve, 'image/jpeg', 0.85);
				} catch (error) {
					reject(error);
				}
			};
			photo.onerror = function () { URL.revokeObjectURL(url); reject(); };
			photo.src = url;
		});
	}
	fileInput.addEventListener('click', function () {
		selection = { room:room };
		fileInput.value = '';
	});
	fileInput.addEventListener('change', async function () {
		var file = fileInput.files && fileInput.files[0];
		var picked = selection;
		if (!file || !picked || !visible || !canPick || picked.room !== room) return;
		if (touchKeyboard) dismissKeyboard();
		function deliver(data, mime) {
			if (visible && canPick && selection === picked && window.arenaChatMediaPicked) {
				window.arenaChatMediaPicked(data, mime);
			}
		}
		try {
			// Some mobile pickers supply an empty or incorrect MIME type.
			var mime = imageMime(await readImageBlob(file, true));
			if (mime && file.size <= imageLimit) {
				return deliver(await readImageBlob(file.slice(0, file.size, mime), false), mime);
			}
			if (mime === 'image/gif') return deliver('', 'gif_size');
			var convertible = mime || /^image\/(heic|heif|webp)$/i.test(file.type)
				|| /\.(heic|heif|webp)$/i.test(file.name);
			if (!convertible) return deliver('', 'type');
			if (file.size > 32 * 1024 * 1024) return deliver('', 'photo_size');
			var jpeg;
			try {
				jpeg = await photoAsJpeg(file);
			} catch (error) {
				return deliver('', 'decode');
			}
			if (!jpeg || jpeg.type !== 'image/jpeg') return deliver('', 'read');
			if (jpeg.size > imageLimit) return deliver('', 'photo_size');
			deliver(await readImageBlob(jpeg, false), jpeg.type);
		} catch (error) {
			deliver('', 'read');
		}
	});
	function scrollHistory(delta) {
		if (visible && window.arenaMatchChatAction) window.arenaMatchChatAction('scroll', delta);
	}
	// The history layer sits above the canvas (it has to, or it could not own
	// native scrolling), so every touch inside the message list lands here and
	// never reaches the transparent Godot buttons underneath. Treat a press that
	// did not move as a tap and forward its design-space point to the app; the
	// app resolves it against the same bubble rects it draws.
	var tapStartX = 0, tapStartY = 0, tapMoved = false;
	history.addEventListener('pointerdown', function (event) {
		if (!event.isPrimary || event.button !== 0) return;
		event.preventDefault();
		dragPointer = event.pointerId;
		dragY = event.clientY;
		dragX = event.clientX;
		tapStartX = event.clientX;
		tapStartY = event.clientY;
		tapMoved = false;
		tappedImage = event.target.tagName === 'IMG' ? event.target : null;
		history.setPointerCapture(dragPointer);
	});
	history.addEventListener('pointermove', function (event) {
		if (event.pointerId !== dragPointer) return;
		if (!tapMoved && Math.hypot(event.clientX - tapStartX, event.clientY - tapStartY) > 8) tapMoved = true;
		var delta = event.clientY - dragY;
		if (tappedImage && Math.hypot(delta, event.clientX - dragX) < 8) return;
		tappedImage = null;
		dragY = event.clientY;
		scrollHistory(delta / historyScale);
	});
	history.addEventListener('pointerup', function (event) {
		if (event.pointerId !== dragPointer) return;
		if (tappedImage && history.contains(tappedImage)
			&& Math.hypot(event.clientY - dragY, event.clientX - dragX) < 8) {
			openImage(tappedImage);
		} else if (!tapMoved && window.arenaMatchChatAction) {
			var box = history.getBoundingClientRect();
			var scale = historyScale || 1;
			window.arenaMatchChatAction('tap',
				historyRect[0] + (event.clientX - box.left) / scale,
				historyRect[1] + (event.clientY - box.top) / scale);
		}
		dragPointer = tappedImage = null;
	});
	history.addEventListener('pointercancel', function () { dragPointer = tappedImage = null; });
	history.addEventListener('lostpointercapture', function () { dragPointer = tappedImage = null; });
	history.addEventListener('wheel', function (event) {
		event.preventDefault();
		var delta = event.deltaMode === 0 ? event.deltaY / historyScale : event.deltaY * (event.deltaMode === 1 ? 24 : historyRect[3]);
		scrollHistory(-delta);
	}, {passive:false});
	window.addEventListener('resize', scheduleLayout);
	window.addEventListener('scroll', scheduleLayout, {passive:true});
	window.addEventListener('pageshow', settleLayout);
	document.addEventListener('visibilitychange', function () {
		if (document.visibilityState === 'visible') settleLayout();
	});
	if (window.visualViewport) {
		window.visualViewport.addEventListener('resize', scheduleLayout);
		window.visualViewport.addEventListener('scroll', scheduleLayout);
	}
	window.arenaMatchChat = {
		show: function (nextRoom, x, y, w, h, nextHistoryRect, nextCanPick, nextTextSize, nextMaxChars) {
			var nextRect = [x, y, w, h];
			var pickEnabled = nextCanPick !== false;
			var nextFont = nextTextSize || 20;
			var maxChars = nextMaxChars || 80;
			// The friend screen may call show each frame.
			if (visible && room === nextRoom && pickEnabled === canPick && nextFont === textSize
				&& input.maxLength === maxChars && nextRect.every(function (value, i) { return rect[i] === value; })
				&& nextHistoryRect.every(function (value, i) { return historyRect[i] === value; })) return;
			canPick = pickEnabled;
			textSize = nextFont;
			input.maxLength = maxChars;
			if (room !== nextRoom) {
				room = nextRoom;
				selection = null;
				input.value = '';
				status.hidden = true;
			}
			rect = nextRect;
			historyRect = nextHistoryRect;
			if (!visible) {
				form.style.left = (window.scrollX + 16) + 'px';
				form.style.top = (window.scrollY + Math.max(16, window.innerHeight - (h + 120))) + 'px';
				form.style.width = Math.min(w, Math.max(0, window.innerWidth - 32)) + 'px';
				form.style.height = h + 'px';
			}
			visible = true;
			form.style.display = 'flex';
			history.style.display = 'block';
			layout();
		},
		isShown: function () {
			return visible;
		},
		hide: function () {
			visible = false;
			composing = false;
			selection = null;
			dragPointer = tappedImage = null;
			if (viewer.hasAttribute('open')) closeImagePreview();
			dismissKeyboard();
			form.style.display = 'none';
			history.style.display = 'none';
			if (ios) settleLayout();
		},
		setHistory: function (tiles, textTiles) {
			var active = new Set(tiles.map(function (tile) { return tile.id; }));
			for (var entry of images) {
				if (active.has(entry[0])) continue;
				if (entry[1].element !== previewedImage) entry[1].element.remove();
				images.delete(entry[0]);
			}
			for (var tile of tiles) {
				var image = images.get(tile.id);
				if (!image) {
					var element = document.createElement('img');
					// 页面开了 Cross-Origin-Embedder-Policy: require-corp，
					// 跨域图片不加 crossorigin 会被浏览器直接拦掉（表现为裂图）。
					element.crossOrigin = 'anonymous';
					element.alt = '放大聊天图片';
					element.draggable = false;
					element.addEventListener('error', function (event) {
						// 加载失败就别留一行 alt 文字，空着比裂图干净
						event.currentTarget.style.display = 'none';
					});
					element.tabIndex = 0;
					element.setAttribute('role', 'button');
					element.style.cssText = thumbnailStyle;
					element.src = tile.src;
					element.addEventListener('load', function (event) {
						if (event.currentTarget === previewedImage) layoutViewer();
					});
					element.addEventListener('keydown', function (event) {
						if (event.key !== 'Enter' && event.key !== ' ') return;
						event.preventDefault();
						event.stopPropagation();
						openImage(event.currentTarget);
					});
					history.appendChild(element);
					image = {element:element};
					images.set(tile.id, image);
				}
				image.rect = tile.rect;
			}
			while (labels.length > textTiles.length) labels.pop().element.remove();
			for (var i = 0; i < textTiles.length; i++) {
				var textTile = textTiles[i];
				var label = labels[i];
				if (!label) {
					var element = document.createElement('div');
					element.style.cssText = 'position:absolute;left:0;overflow:hidden;white-space:pre;text-overflow:ellipsis;pointer-events:none;color:rgba(255,255,255,.95);'
						+ 'font-family:system-ui,"Apple Color Emoji","Segoe UI Emoji","Noto Color Emoji",sans-serif;';
					history.appendChild(element);
					label = {element:element};
					labels.push(label);
				}
				if (label.element.textContent !== textTile.text) label.element.textContent = textTile.text;
				label.left = textTile.left || 0;
				label.top = textTile.top;
				label.width = textTile.width;
				label.fontSize = textTile.font_size;
				label.lineHeight = textTile.line_height || 24;
			}
			layout();
		},
		setValue: function (text) {
			input.value = text || '';
			layout();
		},
		clear: function () {
			input.value = '';
			status.hidden = true;
			if (touchKeyboard) dismissKeyboard();
			layout();
			settleLayout();
		},
		status: function (message) {
			clearTimeout(statusTimer);
			status.textContent = message;
			status.hidden = !message;
			if (message) statusTimer = setTimeout(function () { status.hidden = true; }, 3500);
		}
	};
})();
""", true)


func _on_web_match_chat(args: Array) -> void:
	if args.size() < 2:
		return
	# 同一个 DOM 覆盖层被两处复用：对局聊天和好友私聊，按当前页面分流。
	if page == "chat":
		match str(args[0]):
			"input":
				if is_instance_valid(chat_input):
					chat_input.text = str(args[1]).left(SupabaseClient.MESSAGE_MAX_CHARS)
			"send":
				if is_instance_valid(chat_input):
					chat_input.text = str(args[1])
				_submit_chat()
			"scroll":
				_scroll_friend_chat(float(args[1]))
			"tap":
				if args.size() >= 3:
					_activate_chat_invite_at(Vector2(float(args[1]), float(args[2])))
		return
	if page != "match":
		return
	match str(args[0]):
		"send":
			_submit_match_chat(str(args[1]))
		"scroll":
			_scroll_match_chat(float(args[1]))


func _sync_web_match_chat() -> void:
	if not OS.has_feature("web") or page != "match" or not is_instance_valid(match_chat_input):
		return
	if not match_ui.visible or dialog_layer.get_child_count() > 0:
		_hide_web_match_chat()
		return
	var rect := match_chat_input.get_global_rect()
	var history: Rect2 = match_scene.formal_hud.CHAT_VIEWPORT
	JavaScriptBridge.eval("window.arenaMatchChat.show(%s, %f, %f, %f, %f, %s, %s)" % [
		JSON.stringify(room_code), rect.position.x, rect.position.y, rect.size.x, rect.size.y,
		JSON.stringify([history.position.x, history.position.y, history.size.x, history.size.y]),
		JSON.stringify(not room_code.is_empty()),
	], true)


# 好友私聊复用对局聊天的 DOM 覆盖层：只有真 <input> 才能唤出系统输入法（含 emoji），
# 位置由 visualViewport 换算，键盘弹起时整条浮到键盘上方，边打字边看得见。
const FRIEND_CHAT_INPUT_RECT := Rect2(20, 762, 400, 60)
const FRIEND_CHAT_HISTORY_RECT := Rect2(20, 176, 500, 552)
var _friend_chat_tiles_signature := ""
var _friend_chat_dom_warned := false


func _sync_web_friend_chat() -> void:
	if not OS.has_feature("web") or page != "chat" or not is_instance_valid(chat_input):
		return
	if dialog_layer.get_child_count() > 0:
		_hide_web_friend_chat()
		return
	JavaScriptBridge.eval("window.arenaMatchChat.show(%s, %f, %f, %f, %f, %s, %s, 28, %d)" % [
		JSON.stringify("dm:" + active_friend_id),
		FRIEND_CHAT_INPUT_RECT.position.x, FRIEND_CHAT_INPUT_RECT.position.y,
		FRIEND_CHAT_INPUT_RECT.size.x, FRIEND_CHAT_INPUT_RECT.size.y,
		JSON.stringify([FRIEND_CHAT_HISTORY_RECT.position.x, FRIEND_CHAT_HISTORY_RECT.position.y,
			FRIEND_CHAT_HISTORY_RECT.size.x, FRIEND_CHAT_HISTORY_RECT.size.y]),
		JSON.stringify(not active_friend_id.is_empty()),
		SupabaseClient.MESSAGE_MAX_CHARS,
	], true)
	_push_friend_chat_tiles()
	# 覆盖层没显示出来时不再静默：给一句提示，用户至少知道该刷新，而不是以为功能没做
	var shown: Variant = JavaScriptBridge.eval("!!(window.arenaMatchChat && window.arenaMatchChat.isShown && window.arenaMatchChat.isShown())")
	if not bool(shown) and not _friend_chat_dom_warned:
		_friend_chat_dom_warned = true
		print("FRIEND_CHAT_DOM_NOT_SHOWN")
		_notice("聊天输入层未就绪，刷新页面重试")


func _hide_web_friend_chat() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.arenaMatchChat && window.arenaMatchChat.hide()", true)


# 气泡文字交给浏览器渲染：game_zh.ttf 是 GB2312 子集，emoji 一律缺口。
func _push_friend_chat_tiles() -> void:
	if not OS.has_feature("web") or page != "chat" or preview == null:
		return
	var images: Array[Dictionary] = []
	for item in preview.chat_image_tiles_out:
		images.append({
			"id": str(item.get("id", "")),
			"src": str(item.get("url", "")),
			"rect": [
				float(item.get("left", 0.0)) - FRIEND_CHAT_HISTORY_RECT.position.x,
				float(item.get("top", 0.0)) - FRIEND_CHAT_HISTORY_RECT.position.y,
				float(item.get("width", 0.0)), float(item.get("height", 0.0)),
			],
		})
	var tiles: Array[Dictionary] = []
	for item in preview.chat_text_tiles_out:
		var tile: Dictionary = {
			"text": str(item.get("text", "")),
			"left": float(item.get("left", 0.0)) - FRIEND_CHAT_HISTORY_RECT.position.x,
			"top": float(item.get("top", 0.0)) - FRIEND_CHAT_HISTORY_RECT.position.y,
			"width": float(item.get("width", 300.0)),
			"font_size": int(item.get("font_size", 20)),
			"line_height": int(item.get("line_height", 26)),
		}
		tiles.append(tile)
	var signature := JSON.stringify(images) + JSON.stringify(tiles)
	if signature == _friend_chat_tiles_signature:
		return
	_friend_chat_tiles_signature = signature
	JavaScriptBridge.eval("window.arenaMatchChat && window.arenaMatchChat.setHistory(%s, %s)" % [
		JSON.stringify(images), JSON.stringify(tiles),
	], true)


func _web_friend_chat_set(text: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("window.arenaMatchChat && window.arenaMatchChat.setValue(%s)" % JSON.stringify(text), true)


# 清空并收起键盘：发完消息不该还要用户自己点一下屏幕才关输入法
func _web_friend_chat_clear() -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("window.arenaMatchChat && window.arenaMatchChat.clear()", true)


func _hide_web_match_chat() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.arenaMatchChat && window.arenaMatchChat.hide()", true)


func _match_chat_notice(message: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.arenaMatchChat.status(%s)" % JSON.stringify(message), true)
	elif not message.is_empty():
		_notice(message)


func _match_chat_layout() -> void:
	if not is_instance_valid(match_chat_input):
		return
	var typing: bool = match_chat_input.has_focus()
	if is_instance_valid(match_plus_btn):
		match_plus_btn.visible = typing
	if is_instance_valid(match_send_btn):
		match_send_btn.visible = typing
	if typing:
		match_chat_input.position = Vector2(80, 892)
		match_chat_input.size = Vector2(318, 56)
	else:
		match_chat_input.position = Vector2(20, 892)
		match_chat_input.size = Vector2(454, 56)

# 消息列表滚动：DOM 层负责手势，这里只改偏移量，布局由预览层重算
func _scroll_friend_chat(delta: float) -> void:
	if preview == null:
		return
	var next: float = clampf(preview.chat_scroll + delta, 0.0, preview.chat_scroll_max)
	if is_equal_approx(next, preview.chat_scroll):
		return
	preview.chat_scroll = next
	preview.queue_redraw()
	_push_friend_chat_tiles()


# 私聊图片：传到 Supabase Storage，再把公开 URL 塞进消息体
func _upload_and_send_friend_media(bytes: PackedByteArray, mime: String) -> void:
	var target := active_friend_id
	if target.is_empty():
		_notice("没有选中的好友")
		return
	# 先读宽高：对方不用下载就知道该留多大的格子，动图也按第一帧算
	var width := 4
	var height := 3
	var probe := Image.new()
	if probe.load_from_buffer(bytes) == OK and probe.get_width() > 0:
		width = probe.get_width()
		height = probe.get_height()
	_notice("正在上传图片…")
	var res: Dictionary = await supabase.upload_chat_media(bytes, mime)
	if not bool(res.get("ok", false)):
		_notice("图片上传失败：%s" % _friend_reason_text(str(res.get("reason", "upload_failed"))))
		return
	if page != "chat" or active_friend_id != target:
		return
	var body := "[[img:%dx%d]]%s" % [width, height, str(res.get("url", ""))]
	var sent: Dictionary = await supabase.send_message(target, body)
	if not bool(sent.get("ok", false)):
		_notice("图片消息未发送：%s" % _friend_reason_text(str(sent.get("reason", "unknown"))))
		return
	if preview != null:
		preview.chat_scroll = 0.0
	await _load_chat(true)


func _match_chat_plus() -> void:
	if room_code.is_empty():
		_match_chat_notice("不在房间里，无法发送图片")
		return
	_notice("当前平台暂不支持选图，请在网页版使用")


func _on_web_chat_media_picked(args: Array) -> void:
	if args.size() < 2 or not (page in ["match", "chat"]):
		return
	var in_match: bool = page == "match"
	var data_url := str(args[0])
	var mime := str(args[1])
	if data_url.is_empty():
		var why := ""
		match mime:
			"gif_size":
				why = "GIF 超过 2MB，换一张小点的"
			"photo_size":
				why = "照片太大，换一张小点的"
			"type":
				why = "请选择 JPG、PNG、GIF、WebP 或 HEIC 照片"
			"decode":
				why = "当前浏览器无法读取这张照片，试试 JPG、PNG 或截图"
			_:
				why = "图片读取失败，再试一次"
		if in_match:
			_match_chat_notice(why)
		else:
			_notice(why)
		return
	var comma := data_url.find(",")
	if comma < 0:
		if in_match:
			_match_chat_notice("图片读取失败，再试一次")
		else:
			_notice("图片读取失败，再试一次")
		return
	var bytes := Marshalls.base64_to_raw(data_url.substr(comma + 1))
	if bytes.is_empty():
		if in_match:
			_match_chat_notice("图片读取失败，再试一次")
		else:
			_notice("图片读取失败，再试一次")
		return
	if in_match:
		call_deferred("_upload_and_send_media", bytes, mime)
	else:
		call_deferred("_upload_and_send_friend_media", bytes, mime)

# 上传到网关（同源 HTTPS），拿到附件 ID 后再用房间广播告诉其他人
func _upload_and_send_media(bytes: PackedByteArray, mime: String) -> void:
	if network_client == null or not network_client.connected or room_code.is_empty():
		_match_chat_notice("房间正在重连，连接恢复后再发送图片")
		return
	var upload_room := room_code
	_match_chat_notice("正在上传图片…")
	var http := HTTPRequest.new()
	http.timeout = 20.0
	add_child(http)
	var url := "%s/api/chat/upload?room=%s" % [_gateway_http_base(), upload_room]
	var headers := PackedStringArray(["Content-Type: " + mime])
	var err := http.request_raw(url, headers, HTTPClient.METHOD_POST, bytes)
	if err != OK:
		http.queue_free()
		_match_chat_notice("上传请求发送失败")
		return
	var response: Array = await http.request_completed
	http.queue_free()
	if page != "match" or room_code != upload_room:
		return
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS:
		_match_chat_notice("上传失败：网络中断")
		return
	var code: int = int(response[1])
	var text: String = (response[3] as PackedByteArray).get_string_from_utf8()
	if code < 200 or code >= 300:
		_match_chat_notice("上传被拒绝（%d）：%s" % [code, text.left(40)])
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_match_chat_notice("服务器返回的上传结果有误")
		return
	var att := str((parsed as Dictionary).get("id", ""))
	var real_mime := str((parsed as Dictionary).get("type", mime))
	if att.is_empty():
		_match_chat_notice("上传失败：未收到附件编号")
		return
	if network_client == null or not network_client.send_chat_media(att, real_mime):
		_match_chat_notice("连接已断开，图片没有发出去")
		return
	_match_chat_notice("")
	_append_media_message(display_name, att, real_mime, bytes)


func _append_media_message(who: String, att: String, mime: String, bytes: PackedByteArray) -> void:
	if mime == "image/gif":
		if OS.has_feature("web") and bytes.size() >= 10:
			var dimensions := Vector2(bytes.decode_u16(6), bytes.decode_u16(8))
			if dimensions.x > 0 and dimensions.y > 0:
				_append_web_chat_media(who, att, mime, bytes, dimensions)
		return
	var image := Image.new()
	var result := ERR_FILE_UNRECOGNIZED
	match mime:
		"image/png":
			result = image.load_png_from_buffer(bytes)
		"image/jpeg":
			result = image.load_jpg_from_buffer(bytes)
	if result != OK:
		return
	if OS.has_feature("web"):
		_append_web_chat_media(who, att, mime, bytes, Vector2(image.get_size()))
	else:
		_append_match_chat({"nickname": who, "tex": ImageTexture.create_from_image(image), "attachment": att})


func _append_web_chat_media(who: String, att: String, mime: String, bytes: PackedByteArray, dimensions: Vector2) -> void:
	_append_match_chat({
		"nickname": who, "attachment": att, "media_size": dimensions,
		"media_src": "data:%s;base64,%s" % [mime, Marshalls.raw_to_base64(bytes)],
	})

func _gateway_http_base() -> String:
	var base := network_url
	base = base.replace("wss://", "https://").replace("ws://", "http://")
	var cut := base.find("/ws")
	if cut >= 0:
		base = base.substr(0, cut)
	return base

func _append_match_chat(entry: Dictionary) -> void:
	match_chat_log.append(entry)
	if match_chat_log.size() > MATCH_CHAT_HISTORY_LIMIT:
		match_chat_log.remove_at(0)
	_update_match_chat_hud(true)


func _update_match_chat_hud(appended := false) -> void:
	if match_scene == null or match_scene.formal_hud == null:
		return
	match_scene.formal_hud.set_chat_lines(match_chat_log, appended)
	_sync_web_match_history()


func _scroll_match_chat(delta: float) -> void:
	if match_scene.formal_hud.scroll_chat(delta):
		_sync_web_match_history()


func _sync_web_match_history() -> void:
	if not OS.has_feature("web"):
		return
	var tiles: Array[Dictionary] = match_scene.formal_hud.chat_media_tiles(_web_match_chat_media_ids)
	_web_match_chat_media_ids.clear()
	for tile in tiles:
		_web_match_chat_media_ids[tile.id] = true
	JavaScriptBridge.eval("window.arenaMatchChat.setHistory(%s, %s)" % [
		JSON.stringify(tiles), JSON.stringify(match_scene.formal_hud.chat_text_tiles()),
	], true)


func _on_match_chat_history_input(event: InputEvent) -> void:
	if event is InputEventScreenDrag:
		_scroll_match_chat(event.relative.y)
	elif event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_scroll_match_chat(24.0 * event.factor)
			MOUSE_BUTTON_WHEEL_DOWN:
				_scroll_match_chat(-24.0 * event.factor)

# 收到别人的图片：只拿到附件 ID，字节再单独下载
func _on_chat_media(data: Dictionary) -> void:
	var att := str(data.get("att", ""))
	var mime := str(data.get("mime", ""))
	var who := str(data.get("nickname", "玩家"))
	if att.is_empty() or match_chat_log.any(func(entry): return entry.get("attachment", "") == att):
		return
	notify_media_received(who, att, mime)

func notify_media_received(who: String, att: String, mime: String) -> void:
	var download_room := room_code
	var http := HTTPRequest.new()
	add_child(http)
	var url := "%s/api/chat/att/%s" % [_gateway_http_base(), att]
	var err := http.request(url)
	if err != OK:
		http.queue_free()
		return
	var response: Array = await http.request_completed
	http.queue_free()
	if page != "match" or room_code != download_room or int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		return
	_append_media_message(who, att, mime, response[3])

# 对局内发送：走房间广播通道，和等待房同一个接口，不落库
func _send_match_chat() -> void:
	if not is_instance_valid(match_chat_input): return
	_submit_match_chat(match_chat_input.text)


func _submit_match_chat(text: String) -> void:
	var body := text.strip_edges()
	if body.is_empty(): return
	if network_client == null:
		_match_chat_notice("未连接房间，草稿已保留")
		return
	if not network_client.send_room_chat(body.left(80)):
		_match_chat_notice("暂时无法发送，草稿已保留")
		return
	match_chat_input.text = ""
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.arenaMatchChat.clear()", true)
	elif DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		match_chat_input.release_focus()
		DisplayServer.virtual_keyboard_hide()

func _on_room_chat(data: Dictionary) -> void:
	var speaker := str(data.get("nickname", "玩家"))
	var said := str(data.get("body", ""))
	room_chat_log.append({"nickname": speaker, "body": said})
	if room_chat_log.size() > 30:
		room_chat_log = room_chat_log.slice(room_chat_log.size() - 30)
	_append_match_chat({"nickname": speaker, "body": said})
	if preview != null:
		preview.set_meta("room_chat_messages", room_chat_log)
		preview.queue_redraw()

func _copy_invite_link() -> void:
	if room_code.is_empty():
		_notice("还没有房间号，先创建或加入一张桌子")
		return
	var link := _room_invite_link()
	if link.is_empty():
		# Never copy a fabricated public URL here: on LAN/desktop it would point
		# at a different gateway and the friend would land in someone else's room.
		_notice("局域网模式没有可分享的链接，复制房间号 #%s 发给朋友" % room_code)
		return
	DisplayServer.clipboard_set(link)
	_notice("邀请链接已复制 · 房间号 #%s" % room_code)

func _show_qr_placeholder() -> void:
	var link := _room_invite_link()
	var body := _dialog_frame("邀请链接", "游戏内二维码待接入；这条链接可以直接发给朋友，点开直达本房间")
	var link_label := Label.new()
	link_label.text = link if not link.is_empty() else "当前无邀请链接"
	link_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	link_label.custom_minimum_size = Vector2(0, 60)
	body.add_child(link_label)
	var close := _dialog_row(body, "知道了")
	close.pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()

func _connect_network() -> void:
	if network_client != null: return
	# 没有房间号就是"还没选桌"。不带 ?room= 连上去会被网关分流到 rooms[0]，
	# 那张桌子可能是别人的——两端各自以为在同一桌，实际根本不在一起。
	# 这里宁可不连，由调用方先回大厅选桌。
	if room_code.is_empty():
		push_warning("NET_CONNECT_NO_ROOM")
		return
	# 兜底：身份为空时服务端的 _receive_hello 会静默 return（不回欢迎也不回错误），
	# 客户端只能干等到超时，日志里连一条 HELLO 都不会出现。
	if player_id.is_empty():
		player_id = Crypto.new().generate_random_bytes(16).hex_encode()
	if OS.has_feature("web"): print("ARENA_NET connect url=%s id_len=%d" % [network_url, player_id.length()])
	network_client = LAN_CLIENT.new()
	network_client.process_priority = -1
	add_child(network_client)
	network_client.assigned.connect(func(team: int): set_local_team(team))
	# Mode/roster/host/intro arrive together in the authoritative room state.
	# The old mode_changed handler is gone: applying a mode before its seat
	# reassignment made the board/HUD briefly read the wrong slots.
	network_client.room_state_received.connect(_network_room_state)
	network_client.action_denied.connect(func(reason: String): _notice(reason))
	network_client.room_chat_received.connect(_on_room_chat)
	network_client.music_ticket_received.connect(_join_room_music)
	network_client.chat_media_received.connect(_on_chat_media)
	network_client.match_started.connect(_network_match_started)
	network_client.snapshot_received.connect(_network_snapshot)
	network_client.trajectory_received.connect(func(state: Dictionary):
		if page == "match" and match_scene != null: match_scene.apply_trajectory_chunk(state)
	)
	network_client.shot_event_received.connect(func(state: Dictionary):
		if page == "match" and match_scene != null: match_scene.apply_remote_shot(state)
	)
	network_client.aim_state_received.connect(func(state: Dictionary):
		if page == "match" and match_scene != null: match_scene.apply_remote_aim(state)
	)
	network_client.transport_lost.connect(func():
		_room_music_eval("suspend()")
		if page == "match" and match_scene != null:
			match_scene.mark_shot_offline("transport_lost")
			match_scene.network_paused = true
			match_scene.clear_network_aim()
	)
	network_client.disconnected.connect(_network_disconnected)
	network_client.match_ended.connect(_network_match_ended)
	network_client.reconnecting.connect(func(attempt: int):
		if attempt == 1 and page != "match": _notice("网络波动，正在自动重连，请稍候...")
	)
	network_client.reconnected.connect(func():
		if page != "match": _notice("已重新连上房间")
	)
	network_client.shot_rejected.connect(func():
		# 被拒时立刻收掉"等待确认"，改成明确的拒绝态。
		if match_scene != null: match_scene.mark_shot_rejected("server")
		match String(network_client.last_shot_reject_reason):
			"no_seat":
				# 重连后座位已过宽限期：玩家看着还在房间里，其实已经是旁观者。
				# 这种情况再拉杆也没用，必须重新入座。
				_notice("你已是旁观状态（座位已释放），请退出房间重新加入这一桌")
			"not_owner":
				_notice("这一杆不是你的球，请等对手出杆")
			_:
				_notice("这一杆没被服务器接住（球还在飞或回合已过），已为你重新同步")
		# 无论哪种原因都补一份权威快照，避免客户端继续用过期的回合/nonce 反复被拒。
		network_client.send_resync()
	)
	var avatar_data := ""
	var avatar := _avatar_path()
	if FileAccess.file_exists(avatar):
		var network_avatar: Image = Image.load_from_file(avatar)
		if network_avatar != null and not network_avatar.is_empty():
			network_avatar.resize(96, 96, Image.INTERPOLATE_LANCZOS)
			avatar_data = Marshalls.raw_to_base64(network_avatar.save_png_to_buffer())
	# 多房间：把房间号作为查询参数带给网关，由它分流到对应的宿主实例
	var ws_url := network_url
	if not room_code.is_empty():
		ws_url += ("&" if ws_url.contains("?") else "?") + "room=" + room_code
	if OS.has_feature("web"): print("ARENA_NET room=%s url=%s" % [room_code, ws_url])
	# The id sent to the room must be the Supabase uid, not the local random one:
	# tapping a seat avatar loads that player's profile, and profiles.id is the
	# auth uid. A local id always came back as "profile not found".
	# _network_identity() is the single source of truth — seat→portrait matching
	# compares against it, and a second copy here would silently drift.
	var net_identity := _network_identity()
	var err: Error = network_client.connect_to_room(ws_url, net_identity, display_name, avatar_data)
	if err != OK: _network_disconnected("无法连接局域网服务器（%d）" % err)

# Roster -> local state. Every seat/role fact comes from the server; nothing is
# inferred from "how many people I think are here".
func _apply_room_roster(players: Array) -> void:
	network_players = players
	var my_id := _network_identity()
	local_role = "spectator"
	local_slot = -1
	local_team = -1
	local_ready = false
	opponent_ready = false
	var names := PackedStringArray(["", "", "", ""])
	var ready_flags := [false, false, false, false]
	for entry in players:
		if not entry is Dictionary:
			continue
		var occupant: Dictionary = entry
		var slot: int = int(occupant.get("slot", -1))
		var seated: bool = str(occupant.get("role", "player")) == "player" and slot >= 0 and slot < 4
		if seated:
			names[slot] = str(occupant.get("name", ""))
			ready_flags[slot] = bool(occupant.get("ready", false))
		if str(occupant.get("player_id", "")) == my_id:
			if seated:
				local_role = "player"
				local_slot = slot
				local_team = int(occupant.get("team", 0 if slot < 2 else 1))
				local_ready = bool(occupant.get("ready", false))
		elif seated and bool(occupant.get("ready", false)):
			opponent_ready = true
	preview.room_slot_names = names
	preview.room_slot_ready = ready_flags
	preview.room_ready = local_ready
	preview.room_opponent_ready = opponent_ready
	preview.room_blue_name = _team_name(0)
	preview.room_red_name = _team_name(1)
	preview.room_connecting = network_client != null and not network_client.connected
	preview.room_spectator = not preview.room_connecting and network_client != null and local_role == "spectator"
	# Portraits are resolved per seat. Never write another player's face into
	# avatar_textures: slot 0 there is the local player.
	_refresh_slot_portraits()
	preview.room_slot_portraits = slot_portraits.duplicate()
	_refresh_room_spectators(players)
	preview.queue_redraw()
	if match_scene != null: _apply_local_team()


func _refresh_room_spectators(players: Array) -> void:
	var my_id := _network_identity()
	var rows: Array = []
	var live_pids := {}
	for entry in players:
		if not entry is Dictionary:
			continue
		var occupant: Dictionary = entry
		var pid := str(occupant.get("player_id", ""))
		if pid.is_empty():
			continue
		if str(occupant.get("role", "player")) == "player" and int(occupant.get("slot", -1)) >= 0:
			continue
		var who := str(occupant.get("name", "观众"))
		var portrait: Texture2D = null
		if pid == my_id:
			portrait = avatar_textures[0] if avatar_textures.size() > 0 else null
		else:
			portrait = _spectator_portrait(pid, str(occupant.get("avatar", "")))
		rows.append({"name": who, "portrait": portrait, "me": pid == my_id})
		live_pids[pid] = true
	room_spectators = rows
	preview.room_spectators = rows
	# 离场观众的 96px 贴图不留在字典里：一局打得久会攒下几十张。
	for pid in spectator_portraits.keys():
		if live_pids.has(pid):
			continue
		spectator_portraits.erase(pid)
		spectator_avatar_sig.erase(pid)
	# 名单变短时把横向滚动收回可用范围，别停在一片空白上。
	spectator_scroll = clampf(spectator_scroll, 0.0, _spectator_scroll_max())
	preview.room_spectator_scroll = spectator_scroll
	match_spectator_scroll = clampf(match_spectator_scroll, 0.0, _match_spectator_scroll_max())
	if page == "waiting_room":
		_bind_spectator_strip_hits()
	_push_match_spectators()


func _spectator_portrait(pid: String, encoded: String) -> Texture2D:
	var sig := "%d|%d" % [encoded.length(), encoded.hash()]
	if str(spectator_avatar_sig.get(pid, "")) == sig:
		return spectator_portraits.get(pid, null) as Texture2D
	spectator_avatar_sig[pid] = sig
	if encoded.is_empty():
		spectator_portraits.erase(pid)
		return null
	var texture := _decode_avatar_png(encoded)
	if texture != null:
		spectator_portraits[pid] = texture
	else:
		spectator_portraits.erase(pid)
	return texture


func _network_room_updated(players: Array) -> void:
	# Kept as the small entry point used by match_started; the full room state
	# goes through _network_room_state below.
	_apply_room_roster(players)


func _network_room_state(state: Dictionary) -> void:
	match_mode = int(state.get("mode", match_mode))
	room_host_id = str(state.get("host", ""))
	room_is_host = not room_host_id.is_empty() and room_host_id == _network_identity()
	room_intro = str(state.get("intro", ""))
	room_phase = str(state.get("phase", "waiting"))
	preview.match_mode = match_mode
	preview.room_is_host = room_is_host
	preview.room_intro = room_intro
	preview.room_phase = room_phase
	var players: Array = state.get("players", [])
	_apply_room_roster(players)
	# 座位布局/身份/阶段变化才重建热区；准备状态和介绍文字只重绘，
	# 否则有人在房间里打字时，每次准备切换都会拆掉输入框。
	var sig := "%d|%s|%d|%s|%d|" % [match_mode, local_role, local_slot, room_phase, 1 if room_is_host else 0]
	for entry in players:
		if not entry is Dictionary:
			continue
		sig += "%s@%d;" % [str(entry.get("player_id", "")), int(entry.get("slot", -1))]
	if sig != _room_roster_signature:
		_room_roster_signature = sig
		if page == "waiting_room" and not room_code.is_empty():
			call_deferred("_route", "waiting_room")


func _network_match_started(players: Array) -> void:
	_apply_room_roster(players)
	room_phase = "playing"
	preview.room_phase = room_phase
	_route("match")

func _send_network_shot(team: int, slot: int, shot_pull: Vector2, nonce: int) -> void:
	# send_shot() returns the real transport result. A packet that never left the
	# socket must not be shown as "shot fired"; tell the match layer immediately
	# (the signal is synchronous, so the status line never flashes a lie).
	if network_client == null:
		if match_scene != null: match_scene.mark_shot_send_failed("no_client")
		return
	if not network_client.send_shot(team, slot, shot_pull, nonce):
		if match_scene != null: match_scene.mark_shot_send_failed("offline")

# 本地算不了这一杆：问宿主订阅兜底轨迹。宿主每杆开始会把订阅清零，
# 所以预演恢复正常后不会继续吃流量。
func _network_want_trajectory() -> void:
	if network_client != null:
		network_client.send_traj_want()

func _network_snapshot(state: Dictionary) -> void:	if page == "match" and match_scene != null:
		# RTT is measured by the client's ping/pong. Give the interpolator the real
		# one-way budget so a 300 ms link does not start a shot half-way through.
		if network_client != null:
			match_scene.network_rtt_ms = network_client.best_rtt_ms if network_client.best_rtt_ms >= 0 else network_client.latency_ms
		match_scene.apply_network_snapshot(state)

func _leave_room_after_disconnect(reason: String) -> void:
	# 这是"被动断开"，不是主动退出：不要通知网关，让它按 90 秒宽限保留房间，
	# 玩家还能靠重连回到原座位。
	_leave_room(false)
	_notice(reason + "，已回到大厅")

func _network_disconnected(reason: String) -> void:
	# Translate the transport code once, so every branch below shows something the
	# player can act on instead of a raw token like "unknown_room".
	reason = _network_reason_text(reason)
	# 客户端放弃重连时会把自己的 peer 置空，但对象还在。留着它会让
	# _connect_network 的 "network_client == null" 守卫永远不成立——座位还在服务端，
	# 人却再也连不回去（只能刷新页面）。这里必须释放，下一次进房才能重新建连。
	# 例外是"对局结束后被当成新玩家重新入座"：那时 peer 还活着，人其实在房里。
	var still_connected: bool = network_client != null and bool(network_client.get("connected"))
	if network_client != null and not still_connected:
		_leave_room_music()
		network_client.queue_free()
		network_client = null
	if still_connected:
		if page == "match": _back_to_room()
		local_ready = false
		opponent_ready = false
		_notice(reason)
		return
	if page == "match":
		# 对局中断：先回等待房，_route 会用同一个 resume_key 再连一次（座位可能还在）。
		# 这一次再失败就会落到下面的 waiting_room 分支，不会无限重试。
		_back_to_room()
		local_ready = false
		opponent_ready = false
		_notice(reason)
		return
	if page == "waiting_room":
		# 房间已经用不了了（被踢 / 房间解散 / 宽限到期）。停在幽灵房里没有意义：
		# 清掉房间号回大厅，重新挑一桌。
		# 延后一帧：建连失败可能是从 _route("waiting_room") 里面同步回调过来的，
		# 直接递归 _route 会把大厅热区和等待房热区叠在同一层上。
		call_deferred("_leave_room_after_disconnect", reason)
		return
	local_ready = false
	opponent_ready = false
	_notice(reason)

func _network_diagnostics() -> void:
	if page == "match" and is_instance_valid(network_debug_label):
		_clear(dialog_layer)
		network_debug_label.visible = not network_debug_label.visible
		if network_debug_label.visible: _update_network_debug()
		return
	var status := "本地热座" if network_client == null else ("已连接" if network_client.connected else "连接中 / 已断开")
	var latency := "待测" if network_client == null or network_client.latency_ms < 0 else "%d ms" % network_client.latency_ms
	var side := "未分配" if network_client == null or network_client.assigned_team < 0 else ("蓝方" if network_client.assigned_team == 0 else "红方")
	var slot: int = match_scene.turn + 1 if match_scene != null else 0
	var round_number: int = match_scene.turn_manager.round_number if match_scene != null else 0
	var recent_error: String = "无" if network_client == null or network_client.last_error.is_empty() else network_client.last_error
	var identity := player_id.left(8) if not player_id.is_empty() else "待创建"
	var session: String = network_client.session_id if network_client != null else "本地"
	_open_dialog("网络诊断", "状态：%s  ·  延迟：%s\n会话：%s  ·  ID：%s\n阵营：%s  ·  球槽：%d\nRound：%d  ·  当前球：%d\n最近错误：%s" % [status, latency, session, identity, side, slot, round_number, slot, recent_error], [])

func _update_network_debug() -> void:
	var status := "OFFLINE"
	var rtt := "-"
	var age := "-"
	var hz := 0.0
	var seq := -1
	if network_client != null:
		status = "RECONNECTING" if network_client.is_reconnecting else ("CONNECTED" if network_client.connected else "DISCONNECTED")
		if match_scene.network_paused and network_client.connected: status = "PAUSED"
		if network_client.latency_ms >= 0: rtt = "%d ms" % network_client.latency_ms
		var age_ms: int = network_client.snapshot_age_ms()
		if age_ms >= 0: age = "%d ms" % age_ms
		hz = network_client.snapshot_hz
		seq = network_client.snapshot_seq
	var sync_mode := "live"
	if match_scene != null:
		if match_scene.predict_is_active():
			sync_mode = "PREDICT"
		elif match_scene.replay_is_active():
			sync_mode = "REPLAY"
	# 渲染侧四个数：dc 高=命令太多（该烘焙静态层），dc 低但 p95 高=填充率不够。
	var dc := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prim := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var frames: Array = match_scene.frame_stats() if match_scene != null else [-1, -1]
	network_debug_label.text = "%d FPS | RTT %s | %s\nSnapshot %.1f Hz #%d | Age ~%s\nTraj %.0f fps | %s\nDraw %d dc / %d prim | proc %.1fms\ndraw %.2fms | hud %.2fms | p95 %dms max %dms\nSlot %d | Input %s" % [
		Engine.get_frames_per_second(), rtt, status, hz, seq, age,
		network_client.trajectory_hz if network_client != null else 0.0,
		sync_mode,
		dc, prim, proc_ms,
		float(match_scene.diag_draw_us) / 1000.0,
		float(match_scene.diag_hud_draw_us) / 1000.0,
		int(frames[0]), int(frames[1]),
		match_scene.turn + 1, "YES" if match_scene.can_control_current_ball() else "NO"]

func _build_match_ui() -> void:
	_clear(match_ui)
	match_hud_buttons.clear()
	hud_buttons_ignoring = false
	network_debug_label = Label.new()
	network_debug_label.position = Vector2(14, 83)
	network_debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	network_debug_label.add_theme_font_size_override("font_size", 14)
	network_debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	network_debug_label.add_theme_constant_override("shadow_offset_x", 1)
	network_debug_label.add_theme_constant_override("shadow_offset_y", 1)
	network_debug_label.hide()
	match_ui.add_child(network_debug_label)
	# 顶部系统键：视觉是 44px 圆盘（紫色星球质感），触摸区撑到 88×88。
	# 圆心仍在原来的 66×66 位置上，视觉重心和旧版一致。
	# 左上＝退出面板（继续对局 / 退出对局 / 关闭），右上＝对局菜单（三个开关 + 玩法介绍）。
	var back := _match_icon_button(Rect2(3, 7, 88, 88), MATCH_ICON.Kind.BACK, "退出对局", _match_exit_panel)
	back.name = "MatchBack"
	match_status = Label.new()
	# 回合数/击球人/读秒已经移到球盘外侧，这一行只剩"重连中 / 已发出 / 观战中"
	# 这类真实系统状态。夹在观战条下沿（77）与远端球员头像上沿（95）之间的窄带里，
	# 用 14px：够读，又不会压到头像。
	match_status.position = Vector2(86, 76)
	match_status.size = Vector2(368, 18)
	match_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match_status.add_theme_font_size_override("font_size", 14)
	match_status.add_theme_color_override("font_color", Color("8e8e93"))
	match_ui.add_child(match_status)
	match_shot_hint = Label.new()
	match_shot_hint.text = "按住屏幕往反方向拖，松手出杆"
	match_shot_hint.position = Vector2(86, 98)
	match_shot_hint.size = Vector2(368, 20)
	match_shot_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	match_shot_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match_shot_hint.add_theme_font_size_override("font_size", 15)
	match_shot_hint.add_theme_color_override("font_color", Color("8e8e93"))
	match_shot_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	match_shot_hint.hide()
	match_ui.add_child(match_shot_hint)
	var menu := _match_icon_button(Rect2(449, 7, 88, 88), MATCH_ICON.Kind.MORE, "对局菜单", _match_menu)
	menu.name = "MatchMenu"
	# Web chat uses a single DOM form; native chat keeps the LineEdit.
	match_chat_input = LineEdit.new()
	match_chat_input.placeholder_text = ""
	match_chat_input.position = Vector2(20, 892)
	match_chat_input.size = Vector2(454, 56)
	match_chat_input.max_length = 80
	match_chat_input.add_theme_font_size_override("font_size", 20)
	var chat_box := StyleBoxFlat.new()
	# 透明底 + 1px 紫描边：参考图里框内是透出棋盘背景的
	chat_box.bg_color = Color(0, 0, 0, 0)
	chat_box.border_color = Color("6a4fb8")
	chat_box.set_border_width_all(1)
	chat_box.set_corner_radius_all(10)
	chat_box.content_margin_left = 14
	chat_box.content_margin_right = 14
	match_chat_input.add_theme_stylebox_override("normal", chat_box)
	match_chat_input.add_theme_stylebox_override("focus", chat_box)
	match_chat_input.add_theme_color_override("font_color", Color("f5f5f7"))
	match_chat_input.add_theme_color_override("placeholder_color", Color("5c5c61"))
	match_chat_input.add_theme_color_override("caret_color", Color(0, 0, 0, 0))
	match_ui.add_child(match_chat_input)
	if OS.has_feature("web"):
		match_chat_input.hide()
		_sync_web_match_chat()
	else:
		var history := Control.new()
		var bounds: Rect2 = match_scene.formal_hud.CHAT_VIEWPORT
		history.position = bounds.position
		history.size = bounds.size
		history.mouse_force_pass_scroll_events = false
		history.gui_input.connect(_on_match_chat_history_input)
		match_ui.add_child(history)
		_attach_caret_hint(match_chat_input)
		match_chat_input.text_submitted.connect(func(_text: String): _send_match_chat())
		match_chat_input.focus_entered.connect(_match_chat_layout)
		match_chat_input.focus_exited.connect(_match_chat_layout)
		match_plus_btn = _visible_button(match_ui, "＋", Rect2(20, 894, 52, 52))
		match_plus_btn.custom_minimum_size = Vector2.ZERO
		match_plus_btn.size = Vector2(52, 52)
		match_plus_btn.focus_mode = Control.FOCUS_NONE
		match_plus_btn.pressed.connect(_match_chat_plus)
		match_plus_btn.hide()
		match_send_btn = _visible_button(match_ui, "发送", Rect2(406, 894, 68, 52))
		match_send_btn.custom_minimum_size = Vector2.ZERO
		match_send_btn.size = Vector2(68, 52)
		match_send_btn.focus_mode = Control.FOCUS_NONE
		match_send_btn.pressed.connect(_send_match_chat)
		match_send_btn.hide()
	var music := _visible_button(match_ui, "音乐", Rect2(480, 894, 60, 52))
	music.custom_minimum_size = Vector2.ZERO
	music.size = Vector2(60, 52)
	music.text = ""
	music.flat = true
	music.pressed.connect(_match_music)
	# Cache HUD buttons so aim drags can pass their area through to the board.
	for child in match_ui.get_children():
		if child is Button:
			match_hud_buttons.append(child)

# 左上退出面板：只列「继续对局」「退出对局」，第三行「关闭」由 _open_dialog 统一补，
# 这样"关闭"不会重复出现，也不用再写一行副标题说明。
# 退出行为不变：真退出本局并回到同一房号的准备界面。
func _match_exit_panel() -> void:
	_open_dialog("退出对局？", "", [
		{"label":"继续对局", "action":func(): _clear(dialog_layer)},
		{"label":"退出对局", "action":_leave_match_to_room},
	])


# 右上对局菜单：五个独立开关 + 玩法介绍。开关即时生效并落盘；
# 每次切换后按最新状态重开菜单，标签跟着变，不留"点了没反应"的假开关。
func _match_menu() -> void:
	_open_dialog("对局菜单", "", [
		{"label": "撞击特效：" + ("开" if SettingsStore.impact_fx_enabled else "关"), "action": _toggle_impact_fx},
		{"label": "撞击音效：" + ("开" if SettingsStore.impact_sfx_enabled else "关"), "action": _toggle_impact_sfx},
		{"label": "背景音乐：" + ("开" if SettingsStore.bgm_enabled else "关"), "action": _toggle_match_bgm},
		{"label": "降低动态效果：" + ("开" if SettingsStore.reduce_motion else "关"), "action": _toggle_reduce_motion},
		{"label": "限制为 30 帧：" + ("开" if SettingsStore.fps_limit_30 else "关"), "action": _toggle_fps_limit},
		{"label": "玩法介绍", "action": _match_how_to_play},
	])


func _toggle_impact_fx() -> void:
	SettingsStore.impact_fx_enabled = not SettingsStore.impact_fx_enabled
	SettingsStore.save_settings()
	_match_menu()


func _toggle_impact_sfx() -> void:
	SettingsStore.impact_sfx_enabled = not SettingsStore.impact_sfx_enabled
	SettingsStore.save_settings()
	_match_menu()


func _toggle_match_bgm() -> void:
	SettingsStore.bgm_enabled = not SettingsStore.bgm_enabled
	SettingsStore.save_settings()
	# 点菜单这一下就是用户手势，Web 上正好借它解锁音频；
	# 房间音乐正在播时 _apply_bgm 不会叠背景音乐。
	_apply_bgm()
	_match_menu()


# 降低动态效果：和设置页共用同一个 SettingsStore.reduce_motion。
# 对撞击特效/抖动是即时生效（_fx_allowed 每帧读），不用重开对局。
func _toggle_reduce_motion() -> void:
	SettingsStore.reduce_motion = not SettingsStore.reduce_motion
	SettingsStore.save_settings()
	_match_menu()


# 限制为 30 帧：只改本机渲染上限，切换立刻生效，选择写盘，重进游戏仍然生效。
func _toggle_fps_limit() -> void:
	SettingsStore.fps_limit_30 = not SettingsStore.fps_limit_30
	SettingsStore.save_settings()
	_apply_frame_limit()
	_match_menu()


# 玩法介绍：只写规则，不写操作提示（操作在第一次轮到自己时有那条拖拽提示）。
func _match_how_to_play() -> void:
	_open_dialog("玩法介绍", "\n".join([
		"· 双人模式一人控两球，四人模式一人一球；红蓝交替出手，每局抽签定先后。",
		"· 按住自己的球往反方向拖，松手出杆：拖得越远越重，拖满后长度锁住、还能继续转向。",
		"· 球撞对方主塔扣血；击破主塔，或打满 20 回合按剩余血量判定胜负。",
		"· 副塔上会刷出技能（连击 / 治疗 / 眩晕），全队各出手一次充满 4 格后在本队下一杆生效。",
		"· 火球撞塔双倍伤害；吸血球撞敌方塔吸血、撞己方塔回血；黑洞吞掉所有球。",
	]), [])


# 第二项：让"本人"离开这一局，回到同一房号的准备界面。
# 观众：只切页面，绝不通知宿主——观战者没有参赛席，不能停掉别人的对局。
# 参赛者：请求宿主收尾（本局结束、所有人回准备房、座位保留），收到 match_ended 才换页。
func _leave_match_to_room() -> void:
	_clear(dialog_layer)
	if page != "match":
		return
	leave_match_requested.emit()
	if network_client != null and local_role == "spectator":
		_match_leave_pending = false
		_back_to_room()
		_notice("已退出观战，仍在房间里")
		return
	if network_client == null:
		_back_to_room()
		return
	if not network_client.connected:
		_notice("连接已断开，暂时退不出去 · 请等自动重连后再试")
		return
	if not network_client.send_leave_match():
		_notice("退出请求没有发出去，请检查网络")
		return
	if _match_leave_pending:
		return
	_match_leave_pending = true
	_match_leave_sent_ms = Time.get_ticks_msec()


# 宿主宣布本局结束（有人退出 / 弃权 / 正常结算后回房）：所有人回准备房。
# 已经在别的页面（比如结果页）时不重复跳转，只清掉挂起标记。
func _network_match_ended(reason: String) -> void:
	_match_leave_pending = false
	if page != "match":
		return
	_pending_room_notice = reason
	_pending_room_notice_until = Time.get_ticks_msec() + 2500
	_back_to_room()

func _toggle_bgm_setting() -> void:
	SettingsStore.bgm_enabled = not SettingsStore.bgm_enabled
	SettingsStore.save_settings()
	_apply_bgm()
	var msg := "背景音乐已开启" if SettingsStore.bgm_enabled else "背景音乐已关闭"
	_open_dialog("提示", msg, [{"label":"知道了", "action":_match_settings}])

func _toggle_motion_setting() -> void:
	SettingsStore.reduce_motion = not SettingsStore.reduce_motion
	SettingsStore.save_settings()
	var msg := "降低动态效果已开启" if SettingsStore.reduce_motion else "降低动态效果已关闭"
	_open_dialog("提示", msg, [{"label":"知道了", "action":_match_settings}])

func _match_settings() -> void:
	SettingsStore.load_settings()
	# Opening this dialog is a user gesture; unlock Web audio so the label matches playback.
	if OS.has_feature("web") and SettingsStore.bgm_enabled and bgm_player != null and not bgm_player.playing:
		_apply_bgm()
	var bgm_label := "背景音乐：开" if SettingsStore.bgm_enabled else "背景音乐：关"
	var motion_label := "降低动态效果：开" if SettingsStore.reduce_motion else "降低动态效果：关"
	_open_dialog("设置", "音效与动态效果即时生效并保存", [
		{"label":bgm_label, "action":func(): _toggle_bgm_setting()},
		{"label":motion_label, "action":func(): _toggle_motion_setting()},
		{"label":"返回对局", "action":func(): _clear(dialog_layer)}
	])

func _refresh_chat_view(label: RichTextLabel) -> void:
	var joined := ""
	for line in local_chat_lines:
		joined += line + "\n"
	label.text = joined

func _send_local_chat(field: LineEdit, label: RichTextLabel) -> void:
	var msg := field.text.strip_edges()
	if msg.is_empty():
		return
	if msg.length() > 120:
		msg = msg.substr(0, 120)
	local_chat_lines.append("我：" + msg)
	if local_chat_lines.size() > 12:
		local_chat_lines.remove_at(0)
	_refresh_chat_view(label)
	field.text = ""
	chat_send_requested.emit(msg) # Local placeholder: no listener, never sent.

func _music_bar_text() -> String:
	var state := "播放中" if SettingsStore.bgm_enabled else "已暂停"
	var wave := "~~" if music_wave_on else "~"
	return "%s 氛围音 · %s · [点击切换]" % [wave, state]

func add_music_bar(parent: Control, y: float) -> Button:
	var bar := Button.new()
	bar.flat = true
	bar.position = Vector2(20.0, y)
	bar.custom_minimum_size = Vector2(360.0, 48.0)
	bar.text = _music_bar_text()
	parent.add_child(bar)
	bar.pressed.connect(func():
		_toggle_bgm_setting_silent()
		bar.text = _music_bar_text()
	)
	active_music_bar = bar
	return bar

func _toggle_bgm_setting_silent() -> void:
	SettingsStore.bgm_enabled = not SettingsStore.bgm_enabled
	SettingsStore.save_settings()
	_apply_bgm()

func _match_music() -> void:
	var online_music := _room_music_bridge and network_client != null and not room_code.is_empty()
	var solo_music := _room_music_bridge and _room_music_solo and not _room_music_room.is_empty()
	if online_music or solo_music:
		var room_body := _dialog_frame("房间音乐", "")
		dialog_layer.theme = theme
		dialog_layer.reparent(music_modal_layer, false)
		dialog_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		room_body.get_child(0).hide()
		room_body.get_child(1).hide()
		var panel := StyleBoxFlat.new()
		panel.bg_color = Color("0b1e2b")
		panel.border_color = Color("685778")
		panel.set_border_width_all(1)
		panel.set_corner_radius_all(18)
		panel.shadow_color = Color(0.025, 0.01, 0.06, 0.75)
		panel.shadow_size = 16
		panel.content_margin_left = 20
		panel.content_margin_right = 20
		panel.content_margin_top = 20
		panel.content_margin_bottom = 20
		room_body.get_parent().add_theme_stylebox_override("panel", panel)
		_room_music_panel = ROOM_MUSIC_PANEL.new()
		room_body.add_child(_room_music_panel)
		_room_music_panel.command.connect(_room_music_command)
		_room_music_panel.volume_changed.connect(func(value: int): _set_room_music_settings(value, SettingsStore.room_music_muted))
		_room_music_panel.mute_changed.connect(func(): _set_room_music_settings(SettingsStore.room_music_volume, not SettingsStore.room_music_muted))
		_room_music_panel.closed.connect(func(): _clear(dialog_layer))
		_room_music_panel.gesture_layout_changed.connect(_sync_room_music_gesture, CONNECT_DEFERRED)
		_refresh_room_music()
		return
	var body := _dialog_frame("本地氛围音", "")
	body.get_child(1).hide()
	add_music_bar(body, 0.0)
	var back := _dialog_row(body, "返回对局")
	back.pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()

func _init_room_music() -> void:
	if not OS.has_feature("web"): return
	_room_music_bridge = bool(JavaScriptBridge.eval("!!window.arenaRoomMusic"))
	if not _room_music_bridge: return
	_room_music_callback = JavaScriptBridge.create_callback(_on_room_music_bridge)
	JavaScriptBridge.get_interface("window").arenaRoomMusicEvent = _room_music_callback
	_push_room_music_settings()

func _room_music_eval(call: String) -> Variant:
	if not _room_music_bridge: return false
	return JavaScriptBridge.eval("window.arenaRoomMusic." + call, true)

func _join_room_music(ticket: String) -> void:
	if not _room_music_bridge or room_code.is_empty() or ticket.is_empty(): return
	_room_music_solo = false
	_room_music_room = room_code
	_room_music_error = ""
	_room_music_status = "connecting"
	_room_music_eval("join(%s,%s)" % [JSON.stringify(room_code), JSON.stringify(ticket)])
	_apply_bgm()
	_refresh_room_music()

# Solo room music: ask the gateway for a music room that only this browser can use
# (the ticket is signed there). Once it arrives we take the exact same join +
# RoomMusicPanel path as online play. On failure it silently falls back to the
# local ambient track instead of showing a fake state.
func _join_solo_music() -> void:
	if not _room_music_bridge or _room_music_solo_pending or not _room_music_room.is_empty():
		return
	var base := _api_base()
	if base.is_empty(): return
	_room_music_solo_pending = true
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(func(_result, code, _headers, body):
		_room_music_solo_pending = false
		http.queue_free()
		if code != 200: return
		var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
		if not (parsed is Dictionary): return
		var solo_code := str(parsed.get("room", ""))
		var solo_ticket := str(parsed.get("ticket", ""))
		if solo_code.is_empty() or solo_ticket.is_empty(): return
		# The player may have backed out (or switched into an online room) during the
		# round trip. The gateway already created the room, so hand it back instead of
		# joining it from the lobby and leaving a stray player behind.
		if not solo_room or page not in ["waiting_room", "match", "result_flow"]:
			_release_solo_music(solo_code)
			return
		# Record the room code before join(): the JS bridge state/status callbacks
		# filter by room code on the next frame.
		_room_music_solo = true
		_room_music_room = solo_code
		_room_music_error = ""
		_room_music_status = "connecting"
		_room_music_eval("storeOwner(%s,%s)" % [JSON.stringify(solo_code), JSON.stringify(str(parsed.get("music_owner", "")))])
		_room_music_eval("join(%s,%s)" % [JSON.stringify(solo_code), JSON.stringify(solo_ticket)])
		_apply_bgm()
		_refresh_room_music()
	)
	http.request(base + "/api/music/solo", ["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"name": display_name}))

# Nobody else shares the solo room, so let the gateway reclaim it right away
# instead of waiting for the 30 minute TTL.
func _release_solo_music(code: String) -> void:
	if code.is_empty(): return
	var base := _api_base()
	if base.is_empty(): return
	var http := HTTPRequest.new()
	http.timeout = 4.0
	add_child(http)
	http.request_completed.connect(func(_result, _code, _headers, _body): http.queue_free())
	http.request(base + "/api/music/solo/release", ["Content-Type: application/json"], HTTPClient.METHOD_POST,
		JSON.stringify({"room": code}))

func _leave_room_music() -> void:
	if _room_music_room.is_empty(): return
	var released := _room_music_room
	var was_solo := _room_music_solo
	_room_music_room = ""
	_room_music_solo = false
	_room_music_state.clear()
	_room_music_error = ""
	_room_music_status = ""
	_room_music_eval("leave()")
	if was_solo:
		_release_solo_music(released)

func _on_room_music_bridge(args: Array) -> void:
	if args.size() == 3:
		call_deferred("_on_room_music_event", str(args[0]), str(args[1]), str(args[2]))

func _on_room_music_event(code: String, event: String, payload: String) -> void:
	if _room_music_room.is_empty() or code != _room_music_room: return
	var data: Variant = JSON.parse_string(payload)
	match event:
		"state":
			if data is not Dictionary: return
			_room_music_state.merge(data, true)
		"status": _room_music_status = str(data)
		"error":
			var errors := {"queue_limit": "每位玩家最多排队 2 首", "queue_full": "队列已满", "host_only": "只有房主可以操作", "slow_down": "操作太快，请稍候"}
			_room_music_error = str(errors.get(str(data), "点歌操作暂未完成"))
		"unmute": _set_room_music_settings(SettingsStore.room_music_volume, false)
	_refresh_room_music()

func _room_music_command(action: String, track_id: String) -> void:
	_room_music_error = ""
	if not bool(_room_music_eval("command(%s,%s)" % [JSON.stringify(action), JSON.stringify(track_id)])):
		_room_music_error = "音乐服务未连接"
	_refresh_room_music()

func _set_room_music_settings(volume: int, muted: bool) -> void:
	if volume != SettingsStore.room_music_volume or muted != SettingsStore.room_music_muted:
		SettingsStore.room_music_volume = volume
		SettingsStore.room_music_muted = muted
		SettingsStore.save_settings()
	_push_room_music_settings()
	_refresh_room_music()

func _push_room_music_settings() -> void:
	_room_music_eval("settings(%f,%s)" % [float(SettingsStore.room_music_volume) / 100.0, JSON.stringify(SettingsStore.room_music_muted)])

func _refresh_room_music() -> void:
	if not is_instance_valid(_room_music_panel): return
	_room_music_panel.update_view(_room_music_state, _room_music_status, _room_music_error, SettingsStore.room_music_volume, SettingsStore.room_music_muted)
	_fit_dialog()
	_sync_room_music_gesture.call_deferred()

func _sync_room_music_gesture() -> void:
	if not is_instance_valid(_room_music_panel) or not _room_music_panel.gesture_button.is_visible_in_tree():
		_room_music_eval("gesture(null)")
		return
	var rect := _room_music_panel.gesture_button.get_global_rect()
	_room_music_eval("gesture(%s)" % JSON.stringify([rect.position.x, rect.position.y, rect.size.x, rect.size.y]))

func _visible_button(parent: Control, title: String, rect: Rect2) -> Button:
	var button := Button.new()
	button.text = title
	button.position = rect.position
	button.size = rect.size
	button.custom_minimum_size = Vector2(66, 66)
	parent.add_child(button)
	return button

# 对局顶部系统键：透明的 Button 负责 88×88 的命中区（比视觉圆盘大一倍，
# 落点在圆盘外沿也点得到），矢量图标负责清晰度，按下时只把圆盘底提亮一档。
func _match_icon_button(rect: Rect2, kind: int, label: String, action: Callable) -> Button:
	var button := _visible_button(match_ui, "", rect)
	button.flat = true
	button.custom_minimum_size = Vector2.ZERO
	button.size = rect.size
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = label
	button.accessibility_name = label
	# 图标脚本没有 class_name（避免依赖编辑器扫描出来的全局类表），按属性/方法名调用。
	var icon: Control = MATCH_ICON.new()
	icon.set("kind", kind)
	button.add_child(icon)
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	button.button_down.connect(func(): icon.call("set_hot", true))
	button.button_up.connect(func(): icon.call("set_hot", false))
	button.pressed.connect(action)
	return button

func _dialog_frame(title: String, subtitle: String) -> VBoxContainer:
	_clear(dialog_layer)
	_hide_web_match_chat()
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dialog_layer.add_child(shade)
	var panel := PanelContainer.new()
	panel.position = Vector2(20, 240)
	panel.size = Vector2(500, 480)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("101012")
	sb.border_color = Color("1e1e22")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 20
	sb.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", sb)
	dialog_layer.add_child(panel)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	panel.add_child(body)
	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 28)
	heading.add_theme_color_override("font_color", Color("f5f5f7"))
	body.add_child(heading)
	# 没副标题就整块不建：空 Label 仍占一行行高，会把只有列表的菜单撑出一段
	# 说不清来历的空白（退出面板、对局菜单都不需要说明行）。
	if not subtitle.is_empty():
		var desc := Label.new()
		desc.text = subtitle
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# Without a known width, an autowrapping label reports a huge minimum height
		# (one glyph per line), which would stretch the panel far past its content.
		desc.custom_minimum_size = Vector2(440, 0)
		desc.add_theme_font_size_override("font_size", 20)
		desc.add_theme_color_override("font_color", Color("8e8e93"))
		body.add_child(desc)
	return body


# Dialog row: flat text button with a hairline bottom border, matching the list rows.
func _dialog_row(parent: Control, title: String) -> Button:
	var button := Button.new()
	button.text = title
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 64)
	button.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.TRANSPARENT
	sb.border_color = Color("1e1e22")
	sb.border_width_bottom = 1
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	for state in ["normal", "hover", "pressed", "disabled"]:
		var variant: StyleBoxFlat = sb.duplicate()
		if state == "hover":
			variant.bg_color = Color("17191b")
		elif state == "pressed":
			variant.bg_color = Color("1f2124")
		elif state == "disabled":
			variant.bg_color = Color(0, 0, 0, 0)
		button.add_theme_stylebox_override(state, variant)
	button.add_theme_font_size_override("font_size", 20)
	button.add_theme_color_override("font_color", Color("f5f5f7"))
	button.add_theme_color_override("font_hover_color", Color("ffffff"))
	button.add_theme_color_override("font_disabled_color", Color("5c5c61"))
	parent.add_child(button)
	return button


# Shrink-wrap the panel around its rows and keep it inside the 540x960 canvas.
func _fit_dialog() -> void:
	if dialog_layer.get_child_count() < 2:
		return
	var panel: PanelContainer = dialog_layer.get_child(1)
	var needed := panel.get_combined_minimum_size()
	var height: float = minf(maxf(needed.y, 160.0), 880.0)
	panel.size = Vector2(500, height)
	panel.position = Vector2(20, clampf((960.0 - height) * 0.5, 40.0, 920.0 - height))


func _open_dialog(title: String, subtitle: String, actions: Array[Dictionary]) -> void:
	var body := _dialog_frame(title, subtitle)
	for entry in actions:
		var button := _dialog_row(body, entry.label)
		button.pressed.connect(entry.action)
	var close := _dialog_row(body, "关闭")
	close.pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()


func _text_dialog(title: String, subtitle: String, placeholder: String) -> LineEdit:
	var body := _dialog_frame(title, subtitle)
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size = Vector2(0, 56)
	# Inside a panel there is no drawn underline, so the field needs its own box.
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("17191b")
	sb.border_color = Color("2a2a2f")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	var focus: StyleBoxFlat = sb.duplicate()
	focus.border_color = Color("6fd3e8")
	field.add_theme_stylebox_override("normal", sb)
	field.add_theme_stylebox_override("focus", focus)
	field.add_theme_font_size_override("font_size", 20)
	field.add_theme_color_override("font_color", Color("f5f5f7"))
	field.add_theme_color_override("font_placeholder_color", Color("8e8e93"))
	field.add_theme_color_override("caret_color", Color("6fd3e8"))
	body.add_child(field)
	_attach_caret_hint(field)
	_fit_dialog()
	return field


func _change_password_dialog() -> void:
	var body := _dialog_frame("修改密码", "只改登录密码，昵称与头像不受影响")
	var pwd1 := LineEdit.new()
	pwd1.secret = true
	pwd1.secret_character = SECRET_CHAR
	pwd1.placeholder_text = "新密码，至少 6 位"
	pwd1.custom_minimum_size = Vector2(0, 48)
	pwd1.add_theme_font_size_override("font_size", 20)
	pwd1.set_meta("web_key", "dlg_pw1")
	body.add_child(pwd1)
	_attach_caret_hint(pwd1, "dlg_pw1")
	var pwd2 := LineEdit.new()
	pwd2.secret = true
	pwd2.secret_character = SECRET_CHAR
	pwd2.placeholder_text = "再输一次"
	pwd2.custom_minimum_size = Vector2(0, 48)
	pwd2.add_theme_font_size_override("font_size", 20)
	pwd2.set_meta("web_key", "dlg_pw2")
	body.add_child(pwd2)
	_attach_caret_hint(pwd2, "dlg_pw2")
	var hint := Label.new()
	hint.text = ""
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color("8e8e93"))
	body.add_child(hint)
	var submit := _dialog_row(body, "确认修改")
	submit.pressed.connect(func(): call_deferred("_submit_change_password", pwd1, pwd2, hint))
	var cancel := _dialog_row(body, "取消")
	cancel.pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()
	_web_bind_dialog_inputs()

# Coroutine: deferred from the button handler, never called bare.
func _submit_change_password(field1: LineEdit, field2: LineEdit, hint: Label) -> void:
	if not is_instance_valid(field1) or not is_instance_valid(field2) or not is_instance_valid(hint):
		return
	var pw := field1.text
	if pw.length() < 6:
		hint.text = "密码至少 6 位"
		return
	if pw != field2.text:
		hint.text = "两次输入不一致"
		return
	hint.text = "正在提交…"
	var res: Dictionary = await supabase.change_password(pw)
	if not is_instance_valid(hint):
		return
	if bool(res.get("ok", false)):
		_clear(dialog_layer)
		_notice("密码已修改，下次登录请用新密码")
	else:
		hint.text = "修改失败：%s" % _change_password_reason(str(res.get("reason", "")))

func _change_password_reason(code: String) -> String:
	# Supabase Auth returns an English sentence in "msg"; translate the two that
	# actually happen instead of leaking English into the dialog.
	if code.begins_with("Password should be at least") or code.begins_with("Password should contain"):
		return "密码不符合要求：至少 6 位"
	if code.begins_with("New password should be different"):
		return "新密码不能和当前密码相同"
	match code:
		"password_too_short":
			return "密码至少 6 位"
		"weak_password":
			return "密码太简单，换一个更复杂的"
		"same_password":
			return "新密码不能和当前密码相同"
		"no_session":
			return "登录状态失效，请重新登录"
		"refresh_failed":
			return "登录已过期，请重新登录"
	if code.is_empty():
		return "未知错误"
	return _localize_reason(code)

func _dialog_button(title: String, action: Callable) -> void:
	var panel: PanelContainer = dialog_layer.get_child(1)
	var body: VBoxContainer = panel.get_child(0)
	_dialog_row(body, title).pressed.connect(action)
	_dialog_row(body, "取消").pressed.connect(func(): _clear(dialog_layer))
	_fit_dialog()

func _notice(value: String) -> void:
	# A notice replaces whatever dialog is open; do not leave invite_panel_open
	# pointing at a widget tree that no longer exists.
	if invite_panel_open:
		_end_invite_panel(false)
	_open_dialog("提示", value, [{"label":"知道了", "action":func(): _clear(dialog_layer)}])
