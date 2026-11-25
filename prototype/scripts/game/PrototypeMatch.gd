extends Node2D

const FIRE_ARTWORK: Texture2D = preload("res://assets/orbs/fire_lava.png")
const IRON_ARTWORK: Texture2D = preload("res://assets/orbs/durable_iron_orb.png")
const VAMPIRE_ARTWORK: Texture2D = preload("res://assets/orbs/vampire_orb.png")
const ARENA_ARTWORK: Texture2D = preload("res://assets/arena/arena_nebula_crystal_final.png")
const FORMAL_HUD = preload("res://scripts/ui/FormalHud.gd")
const DEVELOPER_PANEL = preload("res://scripts/ui/DeveloperPanel.gd")
const UI_LAYOUT = preload("res://scripts/ui/UILayoutManager.gd")
const TURN_MANAGER = preload("res://scripts/game/TurnManager.gd")
const SETTINGS = preload("res://scripts/data/SettingsStore.gd")
const HOLE_VISUAL = preload("res://scripts/visuals/HoleVisual.gd")
const HOLE_SWALLOW = preload("res://scripts/visuals/HoleSwallowFx.gd")
const MATCH_SFX = preload("res://scripts/audio/MatchSfx.gd")
signal shot_requested(team_id: int, ball_slot_id: int, shot_pull: Vector2, turn_nonce: int)
const SKIN_IMAGE_SIZE := Vector2(1024.0, 1536.0)
const SKIN_DRAW_RECT := Rect2(Vector2(0.0, 75.0), Vector2(540.0, 810.0))
# These are coordinates in the unchanged PNG, not screenshot or phone pixels.
# The corners are intersections of the six fitted laser inner-edge lines.
const FIELD_CORNERS_IMAGE = [
	Vector2(120, 347), Vector2(512, 254), Vector2(904, 347),
	Vector2(904, 1121), Vector2(512, 1230), Vector2(120, 1121)
]
const TOWER_CENTERS_IMAGE = [
	Vector2(107, 337), Vector2(512, 239), Vector2(917, 337),
	Vector2(107, 1134), Vector2(512, 1240), Vector2(917, 1134)
]
const TOWER_RADII_IMAGE = [34.0, 49.0, 34.0, 34.0, 49.0, 34.0]
const CORNER_TOWER_INDICES = [0, 1, 2, 5, 4, 3]
const BOUNDARY_ARC_STEP_IMAGE := 2.0
const BOUNDARY_MAIN_BLEND_IMAGE := 10.0
const BOUNDARY_SIDE_BLEND_IMAGE := 6.0
# Side-tower red arc in the skin's local axes: 0..70 degrees. Other corners mirror it.
const SIDE_DAMAGE_ARC_START_DEG := 0.0
const SIDE_DAMAGE_ARC_END_DEG := 70.0

@export_range(0.0, 15.0, 0.5) var side_damage_tolerance_deg := 5.0

var balls: Array = []
var towers: Array = []
var field_corners: Array[Vector2] = []
var boundary_outline := PackedVector2Array()
# 边界扫掠的预计算。原来每个球每个子步都要遍历 221 段、每段重算 normal()（带 sqrt），
# 实测是 step() 里最大的一笔开销（单次 37µs）。这里改成：
#   1) 每段的内法线/长度平方/AABB 预先算好，存进 Packed 数组（避免 Dictionary 取值）；
#   2) 按 64px 网格建索引，查询时只取覆盖到的那几格。
var bs_a := PackedVector2Array()
var bs_edge := PackedVector2Array()
var bs_inward := PackedVector2Array()
var bs_len2 := PackedFloat32Array()
var bs_min := PackedVector2Array()
var bs_max := PackedVector2Array()
var bs_grid := {}
var bs_stamp := PackedInt32Array()
var bs_epoch := 0
const BOUNDARY_CELL := 64.0
var boundary_joints := PackedVector2Array()
var tower_impacts: Array = []
var debug_collisions := false
var debug_mode := false
var show_ui_bounds := false
@export_range(0, 3, 1) var local_player_id := 2
var preview_side_override := -1
var formal_hud: Control
var developer_panel: Window
var debug_contacts: Array = []
var debug_frame_ms := 0.0
var turn := 0
var moving := false
var aiming := false
var start := Vector2.ZERO
var pull := Vector2.ZERO
# 手势线要连到真实指尖：pull 被 MAX_PULL 截断后就不再等于手指位置了。
var aim_pointer := Vector2.ZERO
var aim_pointer_valid := false
var timer := 15.0
var quiet := 0.0
var power := 11.88
var drag := 0.7
var bounce := 0.85
var banner := "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"
var font: Font
var finished := false
var last_hit := "NO IMPACTS YET"
var shot_number := 0
# 本地出手之后、服务端确认之前的等待态。交给对局状态行显示真实进度：
# RTT 400ms 的玩家松手后屏幕毫无反应，会以为"我是不是没松手"。
# 用服务端快照里的 shot_number 增长作为确认依据，不是定时器假装出来的。
var shot_pending := false
var shot_pending_slot := -1
var shot_pending_at_ms := 0
var shot_pending_number := 0
# Client-side shot submission state. "pending" is the only state that means the
# packet was handed to a live socket; rejected/timeout/offline are explicit and
# never render as "shot fired".
const SHOT_STATE_NONE := 0
const SHOT_STATE_PENDING := 1
const SHOT_STATE_REJECTED := 2
const SHOT_STATE_TIMEOUT := 3
const SHOT_STATE_OFFLINE := 4
var shot_state := SHOT_STATE_NONE
var shot_state_at_ms := 0
var shot_state_until_ms := 0
var turn_manager = TURN_MANAGER.new()
var input_team_id := -1 # -1 is local hotseat; network clients use a fixed team.
# 四人模式：只允许操作自己那一个球槽（-1 = 不限制，用于双人/热座）
var input_slot_filter := -1
# 观战视角：接收并播放快照，但绝不接受瞄准/击球输入（input_team_id=-1 表示热座，
# 光靠它挡不住观众，必须单独一个开关）。
var spectator_mode := false
var network_client_mode := false
const SNAPSHOT_BUFFER_MS := 100
# 插值缓冲。固定 100ms 在网络抖动时会失效：把渲染时间推到最新样本上，
# 球就停住等下一帧快照（FPS 仍 60，但画面一顿一顿）。改成从基础值起、
# 按到达抖动自适应，抖动越大越厚，上限 240ms。
# 2026-11-26：140 → 110。抖动估计算对之后（空闲间隔不再计入），
# 实测 jit 只有 5–19ms，140ms 的底垫纯属浪费：它直接变成"每一杆都要等"的手感延迟。
# RTT 高的链路仍由 rtt_floor（RTT×0.5+30）自动加厚，不会因此抖。
const SNAPSHOT_BUFFER_BASE_MS := 110
const SNAPSHOT_BUFFER_MAX_MS := 240
const SNAPSHOT_JITTER_GAIN := 1.6
const SNAPSHOT_BUFFER_LIMIT := 8
# A burst of 20Hz snapshots can arrive in one frame (tunnel hiccup / tab wake).
# The soft limit only trims samples the render clock has already passed; dropping
# unrendered samples here is what made a bounce disappear from an active shot.
const SNAPSHOT_BUFFER_HARD_LIMIT := 32
const AIM_INTERVAL_MS := 56 # About 18 Hz while the pull changes.
const MAX_PULL := 180.0
# 20 回合上限：到了就按血量结算，避免无限对拉
const ROUND_LIMIT := 20
# --- 道具球：每两个总回合一批 ---------------------------------------------
# 一总回合（turn_manager.round_number）= 四步走满，四人局四人各一次（双人局同一人两次）。
# 第 1 总回合只有 4 个玩家球 + 3 个铁球；之后只在第 2、4、6… 总回合刷新一批，
# 每批 1 火球 + 1 吸血球（红蓝各一颗），此后不再补铁球。
const ORB_BATCH_FIRST_ROUND := 2
# 随机采样 400 次失败后，按这个步长扫全盘找合法空位（球直径 39，留出半格容差）
const ORB_FALLBACK_STEP := 24.0
# --- 瞄准引导线 -----------------------------------------------------------
# 手势线与球端线共用同一套材质：青→金渐变 + 圆头收口。线宽统一取旧版
# 满蓄力最粗处的 7px，全长等宽、各力度等宽（旧版是 2.5→7 的锥形）。
const AIM_LINE_WIDTH := 7.0
const AIM_LINE_SEGMENTS := 16
const AIM_CAP_SEGMENTS := 24

# 结算结果（供 AppShell 的结果页读取，不再写死"演示：蓝方获胜"）
var winner_side := -1      # 0 蓝 / 1 红 / -1 平局
# #13 副塔技能：每座副塔独立 25% 概率产技能（第一轮之后），
# 产出来后要"四个玩家各出手一次"充能满，才把效果发给该塔所属队伍。
const SKILL_CHARGE_MAX := 4
const SKILL_POOL := ["double", "heal", "stun"]
const SKILL_SPAWN_CHANCE := 0.25
# 关于场地中心对称的副塔对：同一时间刷同一个技能，两队机会永远对等
const SKILL_PAIRS := [[0, 3], [2, 5]]
# 治疗技能给己方主塔回多少血
const HEAL_SKILL_AMOUNT := 10
# 眩晕持续几个"被消耗的行动位"。计量单位是行动位，不是回合：
# 每队一轮 2 个行动位，所以 2 = 正好一整轮。
# DUEL 模式一队只有 1 个真人（红队独占 slot2/slot3），4 次出手会全部砸在同一个人身上，
# 等于连续 4 杆报废、约 1 分钟不能正常操作，所以不能再往上加。
const STUN_DURATION_SHOTS := 2
# 塔受到的伤害倍率。玩家反馈"四个球围着一座塔打都打不碎"，整体翻倍；
# 速度→伤害的梯度（1..10）不变，只是最后结果 ×2。
const TOWER_DAMAGE_SCALE := 2
# 塔的血量。伤害翻倍后这里同步上调：140 血 = 满力普通球 7 下，
# 也就是"一次火球(40) + 五次普通球(5×20)"正好打碎，与原版 100 血/10 伤害的十下手感对齐。
const TOWER_HP := 140
# 黑洞：被火球烧掉后冷却 3 回合，整局最多出现 3 次
const HOLE_MAX_SPAWNS := 3
const HOLE_BURN_COOLDOWN_ROUNDS := 3
# 眩晕转向曲线：ω(t) = DRIFT + A·sin(F1·t) + B·sin(F2·t + PHASE)，积分得到角度。
# 频率比不是整数，所以转着转着会自己换方向，而且在 360° 里一直漂，不会只在一个来回里晃。
const STUN_DRIFT := 0.62
const STUN_A := 0.95
const STUN_F1 := 0.90
const STUN_B := 0.62
const STUN_F2 := 1.95
const STUN_PHASE := 1.70
# 与 towers 同索引；主塔恒为空字典。每项 {"skill": String, "charge": int}
var tower_skill: Array[Dictionary] = []
# 每队的持续效果：双倍剩余出手次数、眩晕剩余出手次数
var team_double_shots := [0, 0]
var team_stun_shots := [0, 0]
# 眩晕有可能是在"被晕方自己那一杆"的结算里激活的（_activate_tower_skill 由
# _apply_shot 里的 _charge_tower_skills 调用）。这个标记记住"这一侧刚刷新眩晕"，
# 让紧接着结束的那个行动位不扣次数，否则刚给的 2 次会立刻只剩 1 次。
# -1 表示没有待结算的刷新。
var stun_refresh_pending_side := -1
var _last_skill_round := 0
# 一次瞄准的起点（毫秒）。眩晕的转角从这一刻开始积分，松手/下一回合清空。
var _aim_wobble_start_ms := 0
var result_text := ""
signal aim_state_requested(slot: int, nonce: int, kind: String, direction: Vector2, charge: float)
# 这一杆本地没法算（预演起不来 / 中途加入 / 观战）：向宿主订阅兜底轨迹。
signal trajectory_needed
var authoritative_host := false
var network_paused := false
var snapshot_samples: Array[Dictionary] = []
var snapshot_clock_offset := 0
var snapshot_buffer_ms := float(SNAPSHOT_BUFFER_BASE_MS)
var snapshot_jitter_ms := 0.0
var last_snapshot_arrival_ms := 0
# --- 一杆一轨迹：本地回放 ---------------------------------------------------
# 服务端按物理帧（60Hz）把整杆的位置/自转/生死录成二进制帧流，客户端攒够
# REPLAY_LEAD_FRAMES 后按 1.0 倍速连续播放。旧的 20Hz 快照插值必须不断"追"
# 主机的渲染时钟，链路一抖就改播放速度，肉眼看到的就是球滚到一半停一下。
const REPLAY_LEAD_FRAMES := 12         # 200ms 起播缓冲
const REPLAY_STALL_MAX_MS := 1200      # 缓冲空了多久就认输，交给 rest 快照
var replay_shot_id := -1
var replay_closed_shot := -1
var replay_active := false
var replay_frames: Array = []
var replay_latest := -1
var replay_head := 0.0
var replay_ball_count := 0
var replay_shot_start_ms := 0
var replay_frame_ms := 1000.0 / 60.0
var replay_got_rest := false
var replay_pending_finished := false
# rest 快照里每颗球的权威状态（位置/生死/球种/血量）。回放期间先存着，
# 播到最后一帧再一次性套上去：这一杆里被吞掉的球要等此刻才复活，
# 提前套会让球在回放中途"瞬移回出生点"。
var replay_rest_balls: Array = []
var replay_stall_ms := 0
var replay_total_frames := 0
var replay_bytes := 0
# --- 出杆方本地预演（客户端预测）-------------------------------------------
# 松手瞬间就用同一份 step() 在本地开球：出杆方零延迟，非出杆方继续用轨迹回放。
# 两端从上一杆的 rest 起跑，输入 pull 相同，步长固定 1/60，而 step() 里没有随机数、
# 不刷新球、不推进回合——所以逐帧应当一致。权威 rest 到达时只做一次对账：
# 偏差通常 < 1px，直接采纳看不出来；真的分歧了才记 PREDICT_END drift=xx px。
var predict_active := false
var predict_settled := false
var predict_slot := -1
var predict_started_ms := 0
var predict_settled_ms := 0
var predict_steps := 0
var predict_drift_px := 0.0
var predict_base_shot_number := 0
var predict_backup: Array = []
var predict_backup_towers: Array = []
var predict_backup_holes: Array = []
# 最后一次"权威静止"的宿主时刻：晚到的本杆轨迹包靠它识别并丢弃，
# 否则出杆方会在预演播完之后被自己那一杆的回放倒回去重播一遍。
var last_motion_end_host_ms := 0
# 兜底轨迹的订阅节流：同一杆只请求一次。
var traj_request_ms := 0
# 网页 ?diag=1 角标用的真实网络指标。FPS 分不清"渲染慢"和"插值停"，
# 这里把样本数、渲染滞后、缓冲厚度喂给 JS，远端截图就能定位。
var web_diag_enabled := false
var diag_emit_ms := 0
# 大载荷（arenaPerf）单独降到 2s：它的 JSON.stringify + eval 会吃掉 3~5ms，
# 每 500ms 一次等于每 29 帧插一个长帧，足以把 p95 从 17ms 顶到 25ms。
# 角标只读 arenaNetDiag（6 个标量），不受影响。
var diag_perf_ms := 0
var render_time_ms := 0
var last_snapshot_seq := -1
# --- Performance diagnostics (only allocated when ?diag=1) -------------------
# Frame time alone cannot tell "render is slow" from "playback is waiting for a
# snapshot". These counters separate the two and are published to
# window.arenaPerf for the isolated Chrome A/B harness.
var network_rtt_ms := -1
var diag_snapshot_gaps: Array[int] = []
var diag_last_frame_ms := 0
var diag_motion_ms := 0
# 帧时间分布（?diag=1）：p95 判断"是不是渲染/CPU"，最长帧判断"偶发一顿"。
var diag_frame_deltas: Array[int] = []
var diag_frame_prev_ms := 0
var diag_motion_stall_ms := 0
var diag_stall_events := 0
var diag_stall_max_ms := 0
var diag_stall_episode_ms := 0
var diag_stall_active := false
var diag_moving_prev := false
var diag_shot_started_ms := 0
var diag_shot_stall_ms := 0
var diag_shot_events := 0
var diag_shot_max_stall := 0
var diag_shot_number := 0
var diag_shot_log: Array = []
var diag_render_at_edge := false
var diag_render_behind_ms := 0
var diag_slowmo_ms := 0
var diag_draw_us := 0
var diag_hud_draw_us := 0
# Presentation events are held until the interpolated ball reaches their host
# timestamp. Without this, sounds/sparks happen 140-240 ms before the collision
# is drawn, and tower HP drops before the ball touches it.
var pending_sfx_events: Array = []
var pending_fx_events: Array = []
var pending_tower_hp: Array = []
const PRESENTATION_MAX_LATE_MS := 600
const PRESENTATION_MAX_DELAY_MS := 500
# Idle board redraw cadence. Ball motion/aim/effects stay at full rate; a static
# board does not need 60 command rebuilds per second on a weak phone.
var board_redraw_accum := 0.0
const BOARD_IDLE_REDRAW_INTERVAL := 1.0 / 20.0
var remote_aim_slot := -1
var remote_aim_target := Vector2.ZERO
var remote_aim_pull := Vector2.ZERO
var remote_aim_seq := -1
var last_aim_pull := Vector2.ZERO
var last_aim_ms := 0
var slot_owner_ids := PackedStringArray(["hotseat-blue", "hotseat-blue", "hotseat-red", "hotseat-red"])
var match_mode: int = TURN_MANAGER.Mode.DUEL
var shot_elapsed := 0.0
var aim_slot := -1
var aim_nonce := -1
var aim_team := -1
const SHOT_TIMEOUT := 18.0

func _ready():
	sfx = MATCH_SFX.new()
	add_child(sfx)
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	# 网页 ?diag=1 时才往 JS 角标写网络指标，正常游玩零开销。
	if OS.has_feature("web"):
		web_diag_enabled = bool(JavaScriptBridge.eval("new URLSearchParams(location.search).get('diag')==='1'", true))
	reset_game()
	_apply_view_transform()
	_build_static_arena()
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	formal_hud = FORMAL_HUD.new()
	formal_hud.game = self
	layer.add_child(formal_hud)
	formal_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _desktop_debug_available():
		developer_panel = DEVELOPER_PANEL.new()
		developer_panel.game = self
		add_child(developer_panel)
		developer_panel.position = get_window().position + Vector2i(get_window().size.x + 12, 0)

func _desktop_debug_available() -> bool:
	return DisplayServer.get_name() != "headless" and (OS.has_feature("windows") or OS.has_feature("linux") or OS.has_feature("macos"))

func get_view_side() -> int:
	return preview_side_override if preview_side_override >= 0 else (0 if local_player_id < 2 else 1)

func assign_local_player(player_id: int) -> void:
	if player_id < 0 or player_id >= 4: return
	local_player_id = player_id
	preview_side_override = -1
	_apply_view_transform()

func set_preview_side(side: int) -> void:
	if side != 0 and side != 1: return
	preview_side_override = side
	_apply_view_transform()

func _apply_view_transform() -> void:
	# Both views pivot around the board's actual geometry, inside its allotted screen region.
	# This keeps the existing blue-side placement while leaving world physics unchanged.
	var board_center := (_skin_to_world(TOWER_CENTERS_IMAGE[1]) + _skin_to_world(TOWER_CENTERS_IMAGE[4])) * 0.5
	transform = UI_LAYOUT.board_transform(board_center, get_view_side() == 0)
	queue_redraw()
	if formal_hud != null: formal_hud.queue_redraw()

func set_debug_mode(enabled: bool) -> void:
	debug_mode = enabled
	if not enabled:
		debug_collisions = false
		show_ui_bounds = false
		debug_contacts.clear()
	if formal_hud != null:
		formal_hud.show_layout_bounds = debug_mode and show_ui_bounds
		formal_hud.queue_redraw()
	if developer_panel != null:
		developer_panel.visible = enabled
		if enabled: developer_panel.refresh_status()
	queue_redraw()

func set_collision_debug(enabled: bool) -> void:
	debug_collisions = enabled and debug_mode
	if not debug_collisions: debug_contacts.clear()
	queue_redraw()

func set_ui_bounds_debug(enabled: bool) -> void:
	show_ui_bounds = enabled and debug_mode
	if formal_hud != null:
		formal_hud.show_layout_bounds = show_ui_bounds
		formal_hud.queue_redraw()

func handle_developer_key(keycode: Key) -> bool:
	if OS.has_feature("web") or OS.has_feature("mobile"): return false
	if keycode == KEY_F3:
		set_debug_mode(not debug_mode)
		return true
	if keycode == KEY_F4:
		if debug_mode: set_ui_bounds_debug(not show_ui_bounds)
		return true
	if keycode == KEY_F5:
		set_preview_side(1 - get_view_side())
		return true
	return false

const PLAYER_HP := 55
const BALL_RADIUS := 19.5
const HOLE_RADIUS := 22.0
const FULL_DAMAGE_SPEED := 600.0
# A drag shorter than one ball radius is treated as a mis-tap: cancel the aim
# instead of firing a weak shot. Physics (power/drag/bounce) is untouched.
const MIN_SHOT_PULL := BALL_RADIUS
# 球端线画成真实拉杆的 1.2 倍长，手机上更好读。纯视觉：力度、轨迹仍按真实 pull。
# 手势线不加延长——它必须精确落在按下点和指尖上。
const AIM_BEAM_EXTEND := 1.2
# 手势线与球端引导线共用的最大长度（满蓄力 × 视觉延长）。
# 两条线在同一个长度锁死：手继续往外拖只会改变方向，不会再变长。
const AIM_MAX_LENGTH := MAX_PULL * AIM_BEAM_EXTEND
var spawn_rng := RandomNumberGenerator.new()
var match_seed := 0
# 本局抽签（出手次序 + 道具球参数）单独一条随机流：不消耗 spawn_rng，
# 不影响开局球位与黑洞判定的既有序列。
var lot_rng := RandomNumberGenerator.new()
# 每局抽签：谁先拿火球 / 每队第一次在谁出手前刷球（球槽号）
var orb_first_fire_team := 0
var orb_first_slot := [-1, -1]
# 本队上一次发起刷新的批次总回合号（失败也记，避免同一批在另一个行动位重试）
var orb_spawn_round := [-1, -1]
# 待补名额：棋盘放不下时保留旧球，等棋盘静止再补；新批次直接覆盖旧待补项。
# 每队最多一个，重复检查不会重复生成，也不会推进换人/换球。
var orb_pending_kind := ["", ""]
# 每次真正生成/替换道具球 +1，随快照下发。客户端靠它识别"同一格球被换掉了"，
# 清掉插值样本直接对齐，避免旧位置上先出现新球种、再滑到新位置。
var orb_spawn_serial := 0
# #15 黑洞：最多两个，第 3 回合起随机出现；洞里吞掉一切球
var holes: Array[Vector2] = []
# 吞噬特效实例：[{hole, entry, r, tint, age, dur}]。纯表现，不参与任何判定。
var hole_swallows: Array = []
const HOLE_SWALLOW_SECONDS := 0.75
# 火球撞洞：洞被烧掉时的一次性爆散 [{"p", "age", "dur"}]
var hole_breaks: Array = []
# 本局黑洞已经出现过几次 / 被烧掉后的冷却截止回合
var hole_spawn_count := 0
var hole_cooldown_until := 0
const HOLE_BREAK_SECONDS := 0.55
var field_bounds := Rect2()
# 撞击音效。物理只在主机跑，所以声音事件要跟着快照发出去，客户端也能听到。
var sfx: Node
var sfx_seq := 0
var sfx_events: Array = []
var last_sfx_id := 0
const SFX_BUFFER := 8
# Visual-only impact effects for ball-ball, ball-player and player-tower pairs.
# [{kind, p, n, side, strength, life, duration}]
var contact_fx: Array = []
# 撞击特效同样只在主机产生：客户端不跑物理，自己算不出"哪里撞了"。
# 和音效走同一套机制——主机记事件进快照，客户端照着在本地放一遍。
var fx_seq := 0
var fx_events: Array = []
var last_fx_id := 0
const FX_BUFFER := 12
var countdown_warned := false

func _ball(kind: String, slot: int, position: Vector2) -> Dictionary:
	return {"kind": kind, "id": slot, "p": position, "v": Vector2.ZERO, "r": BALL_RADIUS,
		"alive": true, "armed": false, "hp": PLAYER_HP if slot >= 0 else 0,
		"angle": 0.0, "spin": 0.0, "spin_kick": 0.0, "impact": 0.0, "owner_side": -1,
		# 道具球的刷新来源队伍（只用于回收/替换，不参与碰撞与伤害归属）
		"spawn_team": -1}

func _spawn_clear(p: Vector2, radius: float, ignore_ball := -1) -> bool:
	if not Geometry2D.is_point_in_polygon(p, boundary_outline): return false
	for i in range(boundary_outline.size()):
		var a := boundary_outline[i]
		var b := boundary_outline[(i + 1) % boundary_outline.size()]
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) < radius + 1: return false
	for t in towers:
		if p.distance_to(t.p) < radius + t.hit_r + 1: return false
	for i in range(balls.size()):
		# 被替换的旧球要允许"原位就地换新"，所以它本身不参与避让
		if i == ignore_ball: continue
		var ball = balls[i]
		if ball.alive and p.distance_to(ball.p) < radius + ball.r + 1: return false
	for h in holes:
		if p.distance_to(h) <= radius + HOLE_RADIUS + 1: return false
	return true

func _spawn_point(radius: float, for_hole := false) -> Vector2:
	var area := field_bounds
	if for_hole:
		area.position.y += field_bounds.size.y * 0.2 + radius
		area.size.y = field_bounds.size.y * 0.6 - 2 * radius
	for attempt in range(400):
		var p := Vector2(spawn_rng.randf_range(area.position.x, area.end.x), spawn_rng.randf_range(area.position.y, area.end.y))
		if _spawn_clear(p, radius): return p
	return Vector2.INF

func _spawn_ball(kind: String, slot := -1) -> bool:
	var point := _spawn_point(BALL_RADIUS)
	if not point.is_finite(): return false
	var ball := _ball(kind, slot, point)
	if slot >= 0 and slot < balls.size(): balls[slot] = ball
	else: balls.append(ball)
	return true

func reset_game(seed_value := -1):
	spawn_rng.randomize()
	match_seed = spawn_rng.randi() if seed_value < 0 else seed_value
	spawn_rng.seed = match_seed
	# 抽签流和开局刷球流错开种子，否则两边第一个随机数永远相同
	lot_rng.seed = match_seed ^ 0x5f356495
	orb_spawn_round = [-1, -1]
	orb_pending_kind = ["", ""]
	orb_spawn_serial = 0
	holes.clear()
	hole_swallows.clear()
	hole_breaks.clear()
	hole_spawn_count = 0
	hole_cooldown_until = 0
	sfx_events.clear()
	sfx_seq = 0
	last_sfx_id = 0
	if sfx != null and sfx.has_method("reset_cooldowns"):
		sfx.reset_cooldowns()
	team_double_shots = [0, 0]
	team_stun_shots = [0, 0]
	stun_refresh_pending_side = -1
	_last_skill_round = 0
	winner_side = -1
	result_text = ""
	balls.clear()
	snapshot_samples.clear()
	clear_network_replay()
	# 整局重来：预演状态直接丢，不做"回滚到出杆前"——新一局会重建一切。
	predict_active = false
	predict_settled = false
	predict_backup = []
	predict_backup_towers = []
	predict_backup_holes = []
	last_motion_end_host_ms = 0
	traj_request_ms = 0
	last_snapshot_seq = -1
	render_time_ms = 0
	diag_snapshot_gaps.clear()
	diag_last_frame_ms = 0
	diag_motion_ms = 0
	diag_frame_deltas.clear()
	diag_frame_prev_ms = 0
	diag_perf_ms = 0
	diag_motion_stall_ms = 0
	diag_stall_events = 0
	diag_stall_max_ms = 0
	diag_slowmo_ms = 0
	diag_draw_us = 0
	diag_hud_draw_us = 0
	pending_sfx_events.clear()
	pending_fx_events.clear()
	pending_tower_hp.clear()
	shot_pending = false
	shot_state = SHOT_STATE_NONE
	shot_state_at_ms = 0
	shot_state_until_ms = 0
	network_rtt_ms = -1
	board_redraw_accum = 0.0
	diag_stall_episode_ms = 0
	diag_stall_active = false
	diag_moving_prev = false
	diag_shot_log.clear()
	diag_shot_number = 0
	network_paused = false
	_clear_remote_aim()
	remote_aim_seq = -1
	towers.clear()
	tower_impacts.clear()
	contact_fx.clear()
	fx_events.clear()
	fx_seq = 0
	last_fx_id = 0
	countdown_warned = false
	debug_contacts.clear()
	field_corners.clear()
	for point in FIELD_CORNERS_IMAGE:
		field_corners.append(_skin_to_world(point))
	var tower_specs := [
		[Vector2(1, 1).normalized(), 0, false],
		[Vector2.DOWN, 0, true],
		[Vector2(-1, 1).normalized(), 0, false],
		[Vector2(1, -1).normalized(), 1, false],
		[Vector2.UP, 1, true],
		[Vector2(-1, -1).normalized(), 1, false]
	]
	for i in range(tower_specs.size()):
		var spec: Array = tower_specs[i]
		var main: bool = spec[2]
		var body_radius: float = TOWER_RADII_IMAGE[i] * _skin_scale()
		var mirror := Vector2(-1.0 if i == 2 or i == 5 else 1.0, -1.0 if i >= 3 else 1.0)
		towers.append({"p": _skin_to_world(TOWER_CENTERS_IMAGE[i]), "inward": spec[0], "side": spec[1], "main": main, "r": body_radius, "hit_r": body_radius, "fan_half": deg_to_rad(24.0 if main else 22.0), "damage_mirror": mirror, "hp": TOWER_HP})
	tower_skill.clear()
	for t in towers:
		# 主塔不产技能，占位保持与 towers 同索引
		tower_skill.append({} if bool(t.main) else {"skill": "", "charge": 0})
	_build_boundary_outline()
	_build_boundary_segments()
	field_bounds = Rect2(boundary_outline[0], Vector2.ZERO)
	for point in boundary_outline: field_bounds = field_bounds.expand(point)
	for slot in range(4): _spawn_ball("player", slot)
	# 开局四个玩家球 + 三个铁球；此后不再补铁球，只在第 2、4、6… 总回合刷新道具球
	for i in range(3):
		_spawn_ball("iron")
	turn_manager.setup(match_mode)
	_draw_match_lots()
	turn = turn_manager.current_slot()
	aim_slot = -1
	aim_nonce = -1
	aim_team = -1
	moving = false
	aiming = false
	finished = false
	last_hit = "NO IMPACTS YET"
	shot_number = 0
	timer = 15.0
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"

func _skin_scale() -> float:
	return SKIN_DRAW_RECT.size.x / SKIN_IMAGE_SIZE.x

func _skin_to_world(point: Vector2) -> Vector2:
	return SKIN_DRAW_RECT.position + point * _skin_scale()

func _corner_cut(corner: Vector2, neighbor: Vector2, center: Vector2, radius: float) -> Vector2:
	var direction: Vector2 = (neighbor - corner).normalized()
	var relative: Vector2 = corner - center
	var along: float = -relative.dot(direction)
	var cut_distance: float = along + sqrt(maxf(0.0, along * along + radius * radius - relative.length_squared()))
	return corner + direction * cut_distance

# 把轮廓拆成"段 + 内法线 + AABB"，并按网格建索引供 _sweep_boundary 查询。
func _build_boundary_segments() -> void:
	bs_a = PackedVector2Array()
	bs_edge = PackedVector2Array()
	bs_inward = PackedVector2Array()
	bs_len2 = PackedFloat32Array()
	bs_min = PackedVector2Array()
	bs_max = PackedVector2Array()
	bs_grid.clear()
	bs_epoch = 0
	var count := boundary_outline.size()
	if count < 3:
		bs_stamp = PackedInt32Array()
		return
	for i in range(count):
		var a: Vector2 = boundary_outline[i]
		var b: Vector2 = boundary_outline[(i + 1) % count]
		var edge: Vector2 = b - a
		var length_squared: float = edge.length_squared()
		if length_squared < 0.000001: continue
		bs_a.append(a)
		bs_edge.append(edge)
		bs_inward.append(Vector2(-edge.y, edge.x).normalized())
		bs_len2.append(length_squared)
		bs_min.append(Vector2(minf(a.x, b.x), minf(a.y, b.y)))
		bs_max.append(Vector2(maxf(a.x, b.x), maxf(a.y, b.y)))
	bs_stamp = PackedInt32Array()
	bs_stamp.resize(bs_a.size())
	bs_stamp.fill(0)
	for i in range(bs_a.size()):
		var lo: Vector2 = bs_min[i]
		var hi: Vector2 = bs_max[i]
		for cx in range(int(floor(lo.x / BOUNDARY_CELL)), int(floor(hi.x / BOUNDARY_CELL)) + 1):
			for cy in range(int(floor(lo.y / BOUNDARY_CELL)), int(floor(hi.y / BOUNDARY_CELL)) + 1):
				var key := Vector2i(cx, cy)
				if bs_grid.has(key):
					(bs_grid[key] as Array).append(i)
				else:
					bs_grid[key] = [i]

func _build_boundary_outline() -> void:
	boundary_outline.clear()
	boundary_joints.clear()
	var entries: Array[Vector2] = []
	var exits: Array[Vector2] = []
	var arc_starts: Array[Vector2] = []
	var arc_ends: Array[Vector2] = []
	var start_angles: Array[float] = []
	var end_angles: Array[float] = []
	# The field corners lie inside the visible tower circles. Both neighboring
	# rails meet the same circle; small cubic transitions make those joins G1.
	var arc_step: float = BOUNDARY_ARC_STEP_IMAGE * _skin_scale()
	for i in range(field_corners.size()):
		var corner: Vector2 = field_corners[i]
		var tower: Dictionary = towers[CORNER_TOWER_INDICES[i]]
		var center: Vector2 = tower.p
		var radius: float = tower.r
		var blend_length: float = (BOUNDARY_MAIN_BLEND_IMAGE if tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var entry: Vector2 = _corner_cut(corner, field_corners[(i - 1 + field_corners.size()) % field_corners.size()], center, radius)
		var exit_point: Vector2 = _corner_cut(corner, field_corners[(i + 1) % field_corners.size()], center, radius)
		var start_angle: float = (entry - center).angle()
		var end_angle: float = (exit_point - center).angle()
		while end_angle >= start_angle: end_angle -= TAU
		start_angle -= blend_length / radius
		end_angle += blend_length / radius
		entries.append(entry)
		exits.append(exit_point)
		start_angles.append(start_angle)
		end_angles.append(end_angle)
		arc_starts.append(center + Vector2.from_angle(start_angle) * radius)
		arc_ends.append(center + Vector2.from_angle(end_angle) * radius)
	boundary_outline.append(arc_starts[0])
	for i in range(field_corners.size()):
		var next: int = (i + 1) % field_corners.size()
		var tower: Dictionary = towers[CORNER_TOWER_INDICES[i]]
		var arc_length: float = tower.r * (start_angles[i] - end_angles[i])
		var arc_count: int = maxi(2, ceili(arc_length / arc_step))
		for arc_index in range(1, arc_count):
			var angle: float = lerpf(start_angles[i], end_angles[i], float(arc_index) / arc_count)
			boundary_outline.append(tower.p + Vector2.from_angle(angle) * tower.r)
		boundary_outline.append(arc_ends[i])
		var direction: Vector2 = (entries[next] - exits[i]).normalized()
		var blend_out: float = (BOUNDARY_MAIN_BLEND_IMAGE if tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var next_tower: Dictionary = towers[CORNER_TOWER_INDICES[next]]
		var blend_in: float = (BOUNDARY_MAIN_BLEND_IMAGE if next_tower.main else BOUNDARY_SIDE_BLEND_IMAGE) * _skin_scale()
		var line_start: Vector2 = exits[i] + direction * blend_out
		var line_end: Vector2 = entries[next] - direction * blend_in
		var tangent_out := Vector2(sin(end_angles[i]), -cos(end_angles[i]))
		_append_boundary_cubic(arc_ends[i], arc_ends[i] + tangent_out * (blend_out * 0.5), line_start - direction * (blend_out * 0.5), line_start)
		boundary_outline.append(line_end)
		var tangent_in := Vector2(sin(start_angles[next]), -cos(start_angles[next]))
		_append_boundary_cubic(line_end, line_end + direction * (blend_in * 0.5), arc_starts[next] - tangent_in * (blend_in * 0.5), arc_starts[next])
		for joint in [arc_ends[i], line_start, line_end, arc_starts[next]]: boundary_joints.append(joint)
	# The last cubic ends at the first point, which is supplied by the implicit
	# closing segment when drawing and sweeping the outline.
	boundary_outline.remove_at(boundary_outline.size() - 1)

func _append_boundary_cubic(a: Vector2, control_a: Vector2, control_b: Vector2, b: Vector2) -> void:
	var count: int = maxi(3, ceili(a.distance_to(b) / (BOUNDARY_ARC_STEP_IMAGE * _skin_scale())))
	for index in range(1, count + 1):
		var t: float = float(index) / count
		var inv: float = 1.0 - t
		boundary_outline.append(a * inv * inv * inv + control_a * 3.0 * inv * inv * t + control_b * 3.0 * inv * t * t + b * t * t * t)

func can_control_current_ball() -> bool:
	if spectator_mode: return false
	if shot_pending: return false
	if network_paused or moving or finished or turn < 0 or turn >= balls.size(): return false
	if not balls[turn].alive or (input_slot_filter >= 0 and turn != input_slot_filter): return false
	var actor_team: int = turn_manager.current_team() if input_team_id < 0 else input_team_id
	return turn_manager.can_act(actor_team, turn, turn_manager.turn_nonce) or aiming

func _unhandled_input(e):
	if e is InputEventKey and e.pressed and not e.echo:
		if handle_developer_key(e.keycode): return
		if e.keycode == KEY_ESCAPE and aiming: cancel_local_aim()
	if not can_control_current_ball(): return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed: begin(make_canvas_position_local(e.position))
		else: release()
	elif e is InputEventMouseMotion and aiming:
		_update_aim_pointer(make_canvas_position_local(e.position))
	elif e is InputEventScreenTouch:
		if e.canceled: cancel_local_aim()
		elif e.pressed: begin(make_canvas_position_local(e.position))
		else: release()
	elif e is InputEventScreenDrag and aiming:
		_update_aim_pointer(make_canvas_position_local(e.position))

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		cancel_local_aim()

func begin(p: Vector2):
	if aiming or not can_control_current_ball(): return
	var actor_team: int = turn_manager.current_team() if input_team_id < 0 else input_team_id
	if not network_client_mode and not turn_manager.begin_aim(actor_team, turn, turn_manager.turn_nonce): return
	aiming = true
	aim_slot = turn
	aim_nonce = turn_manager.turn_nonce
	aim_team = actor_team
	start = p
	pull = Vector2.ZERO
	# 手势线起点就是按下点；后续每次拖动都更新真实指尖（不受 MAX_PULL 截断影响）。
	aim_pointer = p
	aim_pointer_valid = true
	# 只在本次瞄准的第一个锚点记录：反复轻点起手不能把眩晕刷新回 0°
	if _aim_wobble_start_ms <= 0:
		_aim_wobble_start_ms = Time.get_ticks_msec()
	if network_client_mode: _send_local_aim("start")


# 拖动坐标一律先在本地画布空间解析（make_canvas_position_local 已含竖屏拉伸
# 与棋盘旋转），所以两条线和指尖永远在同一坐标系里，缩放/换边都不会错位。
func _update_aim_pointer(point: Vector2) -> void:
	aim_pointer = point
	aim_pointer_valid = true
	pull = (start - point).limit_length(MAX_PULL)

# 当前出手方是否被眩晕
func _is_stunned() -> bool:
	if turn < 0 or turn >= balls.size():
		return false
	return int(team_stun_shots[turn_manager.current_team()]) > 0


# 眩晕按"被消耗的行动位"计时：一个行动位走完就 -1，不管这一杆最后有没有真的打出去
# （超时、取消瞄准、读秒跳过都算）。由 next_turn() 统一调用。
func _consume_stun_tick(side: int) -> void:
	if side < 0 or side >= team_stun_shots.size():
		return
	if side == stun_refresh_pending_side:
		# 眩晕刚在这一侧的行动位里激活，本行动位不扣
		stun_refresh_pending_side = -1
		return
	if int(team_stun_shots[side]) > 0:
		team_stun_shots[side] = int(team_stun_shots[side]) - 1


func _team_of_slot(slot: int) -> int:
	return 0 if slot < 2 else 1


# 眩晕转角：像有人用手在屏幕上慢慢来回抚摸，方向本身在 360° 里漂。
# 用角速度的解析积分，所以曲线连续、不会一帧跳一大截。
# 这条曲线只作用于"球端视觉引导线"，绝不参与出杆计算。
func _stun_wobble() -> float:
	if not _is_stunned():
		return 0.0
	var t := 0.0
	if _aim_wobble_start_ms > 0:
		t = float(maxi(Time.get_ticks_msec() - _aim_wobble_start_ms, 0)) * 0.001
	var theta := STUN_DRIFT * t - (STUN_A / STUN_F1) * cos(STUN_F1 * t) - (STUN_B / STUN_F2) * cos(STUN_F2 * t + STUN_PHASE)
	# 减掉 t=0 的值，让"刚按下时的方向"和玩家手指的方向一致，之后才开始扭
	var theta0 := -(STUN_A / STUN_F1) - (STUN_B / STUN_F2) * cos(STUN_PHASE)
	return theta - theta0


func _send_local_aim(kind: String) -> void:
	last_aim_ms = Time.get_ticks_msec()
	last_aim_pull = pull
	var broadcast_pull := pull
	if int(team_stun_shots[turn_manager.current_team()]) > 0:
		# 被眩晕：广播给别人的"看到的线"在缓动，力度（长度）保持一致。
		# 这只是表现：真正出杆用的是未经旋转的 pull，见 release()。
		broadcast_pull = pull.rotated(_stun_wobble())
	aim_state_requested.emit(aim_slot, aim_nonce, kind, broadcast_pull.normalized(), pull.length() / MAX_PULL)

func cancel_local_aim(send_update := true) -> void:
	if not aiming: return
	aiming = false
	aim_pointer_valid = false
	if network_client_mode:
		if send_update: _send_local_aim("cancel")
	else:
		turn_manager.cancel_aim()

func clear_network_aim() -> void:
	cancel_local_aim(false)
	_clear_remote_aim()

func _clear_remote_aim() -> void:
	remote_aim_slot = -1
	remote_aim_pull = Vector2.ZERO
	remote_aim_target = Vector2.ZERO

func apply_remote_aim(state: Dictionary) -> void:
	var seq := int(state.get("seq", -1))
	if seq <= remote_aim_seq: return
	remote_aim_seq = seq
	if str(state.kind) == "cancel":
		_clear_remote_aim()
		return
	var slot := int(state.slot)
	if network_paused or moving or finished or slot != turn or int(state.nonce) != turn_manager.turn_nonce: return
	if input_team_id == turn_manager.current_team() and (input_slot_filter < 0 or slot == input_slot_filter): return
	remote_aim_slot = slot
	remote_aim_target = Vector2(float(state.dir[0]), float(state.dir[1])) * float(state.charge) * MAX_PULL

func release():
	if not aiming: return
	# 实际发射方向永远是原始拖动的反向：眩晕只晃"看到的球端线"，不改出杆角度，
	# 也不改力度。权威主机拿到的就是这一份未经旋转的 pull。
	var final_pull: Vector2 = pull
	aim_pointer_valid = false
	if network_client_mode:
		cancel_local_aim()
		if final_pull.length() >= MIN_SHOT_PULL:
			# A second release before the first is confirmed would either be a
			# duplicate (if the first arrived) or silently eat the next turn's
			# nonce. Refuse it locally and keep the explicit pending state.
			if shot_pending or shot_state == SHOT_STATE_PENDING or predict_active: return
			# 本地预演：松手这一帧就开球，不等服务端。预演起不来（状态不允许）
			# 才退回"等服务端确认"的老路径，行为与上一版一致。
			if not _predict_begin(aim_team, aim_slot, final_pull):
				# 记录出手时刻的快照编号：收到更大的 shot_number 才算服务端接手。
				shot_pending = true
				shot_pending_slot = aim_slot
				shot_pending_at_ms = Time.get_ticks_msec()
				shot_pending_number = shot_number
				_set_shot_state(SHOT_STATE_PENDING, "", 0)
			shot_requested.emit(aim_team, aim_slot, final_pull, aim_nonce)
		return
	aiming = false
	if final_pull.length() < MIN_SHOT_PULL:
		turn_manager.cancel_aim()
		return
	if not turn_manager.commit_shot(aim_team, aim_slot, aim_nonce): return
	_apply_shot(final_pull)

func request_shot(actor_team: int, slot: int, shot_pull: Vector2, nonce: int) -> bool:
	if finished or moving or slot >= balls.size() or slot < 0 or not balls[slot].alive: return false
	if not shot_pull.is_finite() or shot_pull.length() < MIN_SHOT_PULL or shot_pull.length() > MAX_PULL + 0.01: return false
	if not turn_manager.begin_aim(actor_team, slot, nonce): return false
	if not turn_manager.commit_shot(actor_team, slot, nonce): return false
	_apply_shot(shot_pull)
	return true

func _apply_shot(shot_pull: Vector2) -> void:
	# 眩晕不影响物理：球就沿玩家拖出来的方向走，只在画面上晃引导线
	if _is_stunned():
		_add_floater("被眩晕：线在晃，方向不变", Vector2(270.0, 470.0), Color("a27dea"), 24, 2.0)
	pull = shot_pull
	shot_number += 1
	_apply_shot_bookkeeping()
	# Debug replay recording. On Web, `user://` is backed by IndexedDB and writing
	# it blocks the main thread for tens of milliseconds on every shot, so skip it
	# there (this was a major source of stutter during play).
	if not authoritative_host and not OS.has_feature("web"):
		var recording := FileAccess.open("user://last_shot.json", FileAccess.WRITE)
		if recording:
			var state: Array = []
			for b in balls:
				state.append({"x": b.p.x, "y": b.p.y, "kind": b.kind, "id": b.id, "alive": b.alive, "armed": b.armed})
			recording.store_string(JSON.stringify({"shot": shot_number, "player": turn + 1, "pull": [pull.x, pull.y], "power": power, "drag": drag, "bounce": bounce, "balls": state, "tower_hp": towers.map(func(t): return t.hp)}, "  "))
			recording.close()
	balls[turn].v = pull * power
	moving = true
	quiet = 0.0
	shot_elapsed = 0.0
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"

# 出杆的"非物理"副作用：双倍消耗、副塔技能充能、吸血球归属。
# 本地预演也要执行一遍，否则杆进行中技能条和双倍标记要等 rest 才涨（肉眼可见）。
# 这几项都是幂等镜像：权威 rest 到达时会整体覆盖，不会双算。
# shot_number 刻意不在这里加——它参与 shot_pending 的确认和预演基线，只由权威推进。
func _apply_shot_bookkeeping() -> void:
	# 出手方这一杆双倍就消耗一次（双倍是 buff，超时不出手不消耗）；
	# 眩晕刻意不在这里扣：它按"被消耗的行动位"计时，见 next_turn 的 _consume_stun_tick。
	var shooter_side := turn_manager.current_team()
	if int(team_double_shots[shooter_side]) > 0:
		team_double_shots[shooter_side] = int(team_double_shots[shooter_side]) - 1
	# 这一杆算作所有副塔技能的一次充能
	_charge_tower_skills()
	for b in balls:
		if b.kind == "vampire": b.owner_side = turn_manager.current_team()

# 每局抽签（权威方执行，结果随快照下发）：
#   1) 红/蓝谁先手，50%；
#   2) 蓝队哪位先出手、红队哪位先出手，各自独立 50%；
#   3) 两队球种互补：谁先拿火球 50%，另一队第 2 轮拿吸血球；
#   4) 每队第一次刷球放在哪位队员出手前，各自独立 50%。
# 次序交错：先手队第 1 人 → 另一队第 1 人 → 先手队第 2 人 → 另一队第 2 人。
func _draw_match_lots() -> void:
	var first_team := lot_rng.randi_range(0, 1)
	var blue_first := lot_rng.randi_range(0, 1)
	var red_first := lot_rng.randi_range(0, 1)
	var blue := [blue_first, 1 - blue_first]
	var red := [2 + red_first, 3 - red_first]
	var order := ([blue[0], red[0], blue[1], red[1]] if first_team == 0
		else [red[0], blue[0], red[1], blue[1]])
	if not turn_manager.set_order(order):
		push_warning("MATCH_ORDER_INVALID %s" % str(order))
		turn_manager.set_order([0, 2, 1, 3])
	orb_first_fire_team = lot_rng.randi_range(0, 1)
	orb_first_slot = [lot_rng.randi_range(0, 1), 2 + lot_rng.randi_range(0, 1)]


# 批次只在第 2、4、6… 总回合发起；触发点是该队本批被选中队员的开始出手前。
# 成功就就地换/生成；失败保留旧球并记待补（新批次会覆盖旧的待补项）。
func _maybe_spawn_batch_orb(slot: int) -> void:
	var round_number := int(turn_manager.round_number)
	if round_number < ORB_BATCH_FIRST_ROUND or round_number % 2 != 0:
		return
	var team := _team_of_slot(slot)
	if int(orb_spawn_round[team]) == round_number:
		return
	if slot != _batch_orb_slot(team):
		return
	orb_spawn_round[team] = round_number
	_refresh_team_orb(team, _batch_orb_kind(team))


# 本批由谁触发：四人局按相邻批次在本队两名队员间严格交替；
# 双人局每队只有一名真人（两个球），只轮换球种，触发点固定在本队本轮第一个行动位。
func _batch_orb_slot(team: int) -> int:
	if match_mode != TURN_MANAGER.Mode.QUAD:
		return _team_first_slot(team)
	var first := int(orb_first_slot[team])
	var phase: int = _orb_batch_index() % 2
	return first if phase == 0 else first ^ 1


# 本队在次序里的第一个行动位（双人局两颗球都归同一人，取先出手的那颗）
func _team_first_slot(team: int) -> int:
	for raw in turn_manager.order:
		var slot := int(raw)
		if _team_of_slot(slot) == team:
			return slot
	return -1


# 0 起的批次序号：第 2 总回合 = 0，第 4 总回合 = 1……
func _orb_batch_index() -> int:
	return int(turn_manager.round_number) / 2 - 1


# 球种每批交替、两队互补：第 2 总回合谁拿火球由抽签决定，之后每批对调。
func _batch_orb_kind(team: int) -> String:
	var phase: int = _orb_batch_index() % 2
	var fire: bool = (phase == 0) == (team == orb_first_fire_team)
	return "fire" if fire else "vampire"


# 每队场上最多一颗本队刷出的道具球。能放下就"就地替换"（旧球的位置也算候选），
# 一次赋值完成回收+生成，客户端永远看不到旧球已删/新球落空或重复球。
# 放不下就保留旧球，把本批名额记成待补。
func _refresh_team_orb(team: int, kind: String) -> bool:
	var index := _team_orb_index(team)
	var point := _orb_spawn_point(index)
	if not point.is_finite():
		orb_pending_kind[team] = kind
		return false
	var ball := _ball(kind, -1, point)
	ball["spawn_team"] = team
	if index >= 0:
		balls[index] = ball
	else:
		balls.append(ball)
	orb_pending_kind[team] = ""
	orb_spawn_serial += 1
	return true


# 本队那一颗球的数组下标（活着或已被打掉都算，重刷时复用同一格，球数不增长）
func _team_orb_index(team: int) -> int:
	for i in range(balls.size()):
		if int(balls[i].get("spawn_team", -1)) == team:
			return i
	return -1


# 棋盘静止时补刷待补名额：每队最多补一次，失败就继续挂着等下一次静止。
func _retry_pending_orbs() -> void:
	for team in range(2):
		var kind := str(orb_pending_kind[team])
		if kind.is_empty():
			continue
		_refresh_team_orb(team, kind)


# 道具球落点：沿用现有合法落点规则 + 全盘随机；400 次采样失败后扫候选空位。
# ignore_index 是本队即将回收的旧球，允许新球直接落在它的位置上。
func _orb_spawn_point(ignore_index := -1, random_attempts := 400) -> Vector2:
	var area := field_bounds
	for attempt in range(random_attempts):
		var p := Vector2(spawn_rng.randf_range(area.position.x, area.end.x),
			spawn_rng.randf_range(area.position.y, area.end.y))
		if _spawn_clear(p, BALL_RADIUS, ignore_index): return p
	var spots := _orb_fallback_candidates(ignore_index)
	if spots.is_empty(): return Vector2.INF
	return spots[spawn_rng.randi_range(0, spots.size() - 1)]


# 全盘候选空位：固定步长网格，逐点用同一套合法规则判定。
func _orb_fallback_candidates(ignore_index := -1) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var step := ORB_FALLBACK_STEP
	var x := field_bounds.position.x + step * 0.5
	while x < field_bounds.end.x:
		var y := field_bounds.position.y + step * 0.5
		while y < field_bounds.end.y:
			var p := Vector2(x, y)
			if _spawn_clear(p, BALL_RADIUS, ignore_index):
				out.append(p)
			y += step
		x += step
	return out


# Roll for a hole on each eligible slot starting in round six.
func _maybe_spawn_hole() -> void:
	if turn_manager.round_number < 6:
		return
	if not holes.is_empty():
		return
	# 整局最多出现 3 次
	if hole_spawn_count >= HOLE_MAX_SPAWNS:
		return
	# 刚被火球烧掉：3 个回合内不再刷新
	if turn_manager.round_number <= hole_cooldown_until:
		return
	if spawn_rng.randf() >= 0.10:
		return
	var spot := _spawn_point(HOLE_RADIUS, true)
	if spot.is_finite():
		holes.append(spot)
		hole_spawn_count += 1

# 第一轮之后，每座还没技能的副塔各按 25% 掷一次（同一回合只掷一次）。
# 不看队伍、也不做左右对称：红队长了一个，蓝队不会因此被"配"一个。
func _maybe_spawn_tower_skill() -> void:
	if turn_manager.round_number < 2:
		return
	if turn_manager.round_number == _last_skill_round:
		return
	_last_skill_round = turn_manager.round_number
	var idle: Array[int] = []
	for i in range(SKILL_PAIRS.size()):
		if _pair_is_idle(SKILL_PAIRS[i]):
			idle.append(i)
	# 哪一对先冒是随机的，避免总是同一侧
	_shuffle_slots(idle)
	var spawned := 0
	for pi in idle:
		if spawn_rng.randf() >= SKILL_SPAWN_CHANCE:
			continue
		_spawn_skill_pair(SKILL_PAIRS[pi])
		spawned += 1
	# 第一轮之后保证至少有一对长技能，否则玩家可能整局看不到这套机制
	if spawned == 0 and turn_manager.round_number == 2 and not idle.is_empty():
		_spawn_skill_pair(SKILL_PAIRS[idle[0]])


# 用 spawn_rng 洗牌，保证主机/回放/客户端的随机序列一致
func _shuffle_slots(arr: Array[int]) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := spawn_rng.randi_range(0, i)
		var tmp := arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# 场上还没出现的技能里随机挑一个，三个都被占了才允许重复
func _pick_skill() -> String:
	var used: Array[String] = []
	for st_v in tower_skill:
		var st: Dictionary = st_v
		var s := str(st.get("skill", ""))
		if not s.is_empty() and not used.has(s):
			used.append(s)
	var options: Array[String] = []
	for s in SKILL_POOL:
		if not used.has(str(s)):
			options.append(str(s))
	if options.is_empty():
		for s in SKILL_POOL:
			options.append(str(s))
	return options[spawn_rng.randi_range(0, options.size() - 1)]


# 一对两座都空着才算"可刷"；一边还在充能时不刷，免得刷出不一样的技能
func _pair_is_idle(pair: Array) -> bool:
	for idx in pair:
		if idx >= tower_skill.size() or idx >= towers.size():
			return false
		if bool(towers[idx].main):
			return false
		if not str(tower_skill[idx].get("skill", "")).is_empty():
			return false
	return true


# 一对镜像副塔同时刷同一个技能：蓝方有，红方也一定有
func _spawn_skill_pair(pair: Array) -> void:
	var skill := _pick_skill()
	for idx in pair:
		if idx >= tower_skill.size() or idx >= towers.size():
			continue
		var st: Dictionary = tower_skill[idx]
		st["skill"] = skill
		st["charge"] = 0
		var at: Vector2 = towers[idx].p + Vector2(0.0, -towers[idx].r - 26.0)
		_add_floater("副塔技能出现", at, Color("e7c68d"), 22, 1.6)


# 每次合法出手给所有"已出现但没充满"的副塔 +1，满 4 激活
func _charge_tower_skills() -> void:
	for i in range(tower_skill.size()):
		var st: Dictionary = tower_skill[i]
		var skill := str(st.get("skill", ""))
		if skill.is_empty():
			continue
		if int(st.get("charge", 0)) >= SKILL_CHARGE_MAX:
			continue
		st["charge"] = int(st["charge"]) + 1
		if int(st["charge"]) >= SKILL_CHARGE_MAX:
			_activate_tower_skill(i, skill)


func _activate_tower_skill(index: int, skill: String) -> void:
	if index >= towers.size():
		return
	var side := int(towers[index].side)
	match skill:
		"double":
			# 该队接下来 2 次出手双倍：四人局正好覆盖同队两人
			team_double_shots[side] = maxi(int(team_double_shots[side]), 2)
		"heal":
			_heal_main_tower(side, HEAL_SKILL_AMOUNT)
		"stun":
			# 眩晕的是对面整队，持续 STUN_DURATION_SHOTS 个行动位（每队一轮 2 个，正好 1 轮）
			var stunned_side: int = 1 - side
			team_stun_shots[stunned_side] = STUN_DURATION_SHOTS
			# 只有"被晕的正是刚刚出手的这一队"时才需要免扣第一次：
			# 那个行动位马上就要结束，照扣会把刚给的 2 次立刻吃成 1 次。
			# 反过来（本方副塔在自己这一杆充满、晕的是对手）不挂标记，
			# 否则对手会白拿一个行动位，变成晕 3 格。
			# 同一杆里两侧同时被晕时两边都会走一次这里，所以这里只"挂"不"清"，
			# 免得后一次激活把先一次挂上的标记抹掉。
			if stunned_side == turn_manager.current_team():
				stun_refresh_pending_side = stunned_side
	# 塔上的技能用掉即清空，之后再从 25% 重新长
	var st: Dictionary = tower_skill[index]
	st["skill"] = ""
	st["charge"] = 0
	var at: Vector2 = towers[index].p + Vector2(0.0, -towers[index].r - 20.0)
	_add_floater("技能生效：" + _skill_label(skill), at, Color("69e7a4"), 22, 1.8)


func _skill_label(skill: String) -> String:
	match skill:
		"double":
			return "双倍伤害"
		"heal":
			return "主塔 +%d" % HEAL_SKILL_AMOUNT
		"stun":
			return "眩晕对方"
	return skill


func _kill_player_ball(b: Dictionary) -> void:
	if b.kind != "player":
		b.alive = false
		return
	b.alive = false


func _main_hp(side: int) -> int:
	for t in towers:
		if t.main and int(t.side) == side:
			return int(t.hp)
	return 0


func _side_hp_sum(side: int) -> int:
	var total := 0
	for t in towers:
		if not t.main and int(t.side) == side:
			total += int(t.hp)
	return total


# 判据顺序：主塔血量 → 副塔总血 → 平局
func _finish_by_score() -> void:
	var blue_main := _main_hp(0)
	var red_main := _main_hp(1)
	var blue_side := _side_hp_sum(0)
	var red_side := _side_hp_sum(1)
	if blue_main != red_main:
		winner_side = 0 if blue_main > red_main else 1
		result_text = "主塔血量占优，%s获胜" % ("蓝方" if winner_side == 0 else "红方")
	elif blue_side != red_side:
		winner_side = 0 if blue_side > red_side else 1
		result_text = "主塔同血，副塔总血占优，%s获胜" % ("蓝方" if winner_side == 0 else "红方")
	else:
		winner_side = -1
		result_text = "双方血量完全相同，平局"
	finished = true
	turn_manager.finish()
	banner = result_text
	print("MATCH_END round_limit winner=%d %s" % [winner_side, result_text])


func _check_round_limit() -> bool:
	if turn_manager.round_number <= ROUND_LIMIT:
		return false
	if not finished:
		_finish_by_score()
	return true


func next_turn():
	if finished: return
	if _check_round_limit(): return
	# 上一步行动位到此结束：眩晕按"被消耗的行动位"计时，这一格 -1，
	# 与本杆是否真的出手无关（超时、取消瞄准、读秒跳过都算消耗）。
	_consume_stun_tick(turn_manager.current_team())
	# 新的一杆：眩晕的转角从头开始积
	_aim_wobble_start_ms = 0
	# 每进一个新回合，给没技能的副塔各掷一次 25%
	_maybe_spawn_tower_skill()
	# 棋盘刚静止：先补上次没位置的道具球，再看这一杆是不是新批次的触发点
	_retry_pending_orbs()
	var guard := 0
	while turn_manager.advance():
		guard += 1
		if guard > balls.size() * 2:
			# 一圈下来没有任何槽能打（读秒 + 复活点被占）：交给计时器下一帧再试
			timer = 0.01
			moving = false
			return
		turn = turn_manager.current_slot()
		_maybe_spawn_batch_orb(turn)
		if not balls[turn].alive:
			_spawn_ball("player", turn)
			if balls[turn].alive:
				_add_floater("已复活", balls[turn].p + Vector2(0.0, -BALL_RADIUS - 26.0), Color("69e7a4"), 26, 2)
			_maybe_spawn_hole()
			if balls[turn].alive:
				_consume_stun_tick(turn_manager.current_team())
				continue
			# Retry on its next turn if the board is full.
			timer = 0.01
			moving = false
			return
		_maybe_spawn_hole()
		break
	for b in balls:
		b.armed = false
		b.v = Vector2.ZERO
	turn = turn_manager.current_slot()
	timer = 15.0
	moving = false
	aiming = false
	aim_pointer_valid = false
	countdown_warned = false
	banner = "READY - DRAG YOUR BALL TO AIM, THEN RELEASE"
	if not finished and turn >= 0 and turn < balls.size() and balls[turn].alive:
		_add_floater("到你啦!", balls[turn].p + Vector2(0.0, -BALL_RADIUS - 30.0), Color("6fd3e8"), 28, 2)

func _physics_process(dt):
	if network_client_mode:
		# 客户端平时不跑物理；只有出杆方在自己的预演窗口里跑。
		if predict_active: _predict_step(dt)
		return
	var debug_start_usec := Time.get_ticks_usec() if debug_collisions else 0
	if debug_collisions:
		for i in range(debug_contacts.size() - 1, -1, -1):
			debug_contacts[i].life -= dt
			if debug_contacts[i].life <= 0.0: debug_contacts.remove_at(i)
	_update_tower_impacts(dt)
	_update_contact_fx(dt)
	# 这两个特效之前只在 _process 里推进，而 _process 在主机上第一行就 return，
	# 结果主机上吞噬/爆散会永远停在第 0 帧，看着就是地上留了个圈和一朵花。
	_update_hole_swallows(dt)
	_update_hole_breaks(dt)
	if not moving and not finished:
		timer -= dt
		if timer <= 0:
			if aiming:
				aiming = false
				turn_manager.cancel_aim()
			next_turn()
		elif timer <= 5.0 and not countdown_warned:
			countdown_warned = true
			_add_floater("倒计时5秒!", Vector2(270.0, 430.0), Color("ffcf70"), 28, 2.4)
	if moving and not finished:
		shot_elapsed += dt
		for sub in range(4): step(dt / 4.0)
		var max_speed := 0.0
		for b in balls:
			if b.alive: max_speed = max(max_speed, b.v.length())
		quiet = quiet + dt if max_speed < 5 else 0.0
		if quiet > 0.25 or shot_elapsed >= SHOT_TIMEOUT:
			if turn_manager.begin_resolving(): next_turn()
	_update_orb_visuals(dt)
	if debug_collisions: debug_frame_ms = float(Time.get_ticks_usec() - debug_start_usec) / 1000.0
	if not authoritative_host: queue_redraw()

func _process(dt: float) -> void:
	if not network_client_mode: return
	# Network clients never run _physics_process, so effect lifetimes advance here.
	_update_hole_swallows(dt)
	_update_hole_breaks(dt)
	_update_contact_fx(dt)
	# 塔冲击在客户端也要推进寿命，否则重放出来的火花永远停在第 0 帧。
	_update_tower_impacts(dt)
	var now := Time.get_ticks_msec()
	# 帧时间始终采样（一次 append + 偶尔 pop_front，开销可忽略）：
	# 对局内的诊断行要能随时报 p95/最长帧，不能只在 ?diag=1 时才有。
	if diag_frame_prev_ms > 0:
		diag_frame_deltas.append(now - diag_frame_prev_ms)
		if diag_frame_deltas.size() > 180: diag_frame_deltas.pop_front()
	diag_frame_prev_ms = now
	# 有轨迹就按轨迹播（1.0 倍速、到达抖动不影响中途）；没有才退回快照插值。
	if not _replay_advance(dt):
		_interpolate_network_balls(now, dt)
	_flush_pending_presentation(now)
	_update_diag_motion(now)
	_emit_web_diag(now)
	# 预演已经停住却一直等不到权威 rest（链路半死）：别把玩家永久锁在"球停了但不能出杆"。
	if predict_active and predict_settled and predict_settled_ms > 0 and now - predict_settled_ms > 6000:
		_predict_abandon("no_rest")
	# 兜底：服务端拒绝或包全丢了，不要让状态行一直挂着"等待确认"。
	# 这里给出明确的超时态，而不是静默清掉——玩家要知道"球没动就再拉一次"。
	if shot_pending and now - shot_pending_at_ms > 3000:
		shot_pending = false
		_set_shot_state(SHOT_STATE_TIMEOUT, "no_confirm", 4000)
	if shot_state != SHOT_STATE_NONE and shot_state != SHOT_STATE_PENDING \
			and shot_state_until_ms > 0 and now > shot_state_until_ms:
		_set_shot_state(SHOT_STATE_NONE, "", 0)
	if aiming and now - last_aim_ms >= AIM_INTERVAL_MS:
		# 被眩晕时方向自己在转：哪怕手指一动不动，也得继续发，否则对面看到的是一条死线
		if pull.distance_squared_to(last_aim_pull) >= 0.25 or _is_stunned():
			_send_local_aim("update")
	if remote_aim_slot >= 0:
		remote_aim_pull = remote_aim_pull.lerp(remote_aim_target, 1.0 - exp(-dt * 24.0))
	var busy := moving or aiming or remote_aim_slot >= 0 \
		or not contact_fx.is_empty() or not tower_impacts.is_empty() \
		or not hole_swallows.is_empty() or not hole_breaks.is_empty() or not holes.is_empty()
	if busy:
		board_redraw_accum = 0.0
		queue_redraw()
	else:
		board_redraw_accum += dt
		if board_redraw_accum >= BOARD_IDLE_REDRAW_INTERVAL:
			board_redraw_accum = 0.0
			queue_redraw()

func _interpolate_network_balls(now: int, dt: float) -> void:
	if snapshot_samples.is_empty(): return
	# Use server time so burst delivery does not collapse several simulation steps into one frame.
	var buffer := int(snapshot_buffer_ms)
	var latest_sample := int(snapshot_samples.back().time_ms)
	var target_time := mini(now - snapshot_clock_offset - buffer, latest_sample)
	# Exact "waiting for the next snapshot" signal: the render clock has already
	# reached the newest sample, so it cannot advance this frame. This is the
	# condition that looks like a freeze at 60 FPS.
	diag_render_at_edge = render_time_ms >= latest_sample - 5
	diag_render_behind_ms = maxi(0, target_time - render_time_ms)
	if render_time_ms < target_time:
		# Active shot: continuity first. A 30fps frame may advance at most 45ms
		# (< one 50ms snapshot), so a bounce sample can never be stepped over.
		# 2x/4x catch-up used to advance 66/133ms and made the turn disappear.
		var gap := target_time - render_time_ms
		var covered := latest_sample - int(snapshot_samples[0].time_ms)
		if gap > 900 and covered < gap - 200:
			# Severe missing samples (long pause, nothing covering the hole):
			# use the existing resync path instead of animating stale data.
			snapshot_samples.clear()
			render_time_ms = 0
			diag_render_behind_ms = gap
			return
		var speed := 1120.0
		if gap > 120: speed = 1350.0
		var step := mini(int(dt * speed), 45)
		render_time_ms = mini(target_time, render_time_ms + maxi(1, step))
	else:
		# 超前：以前是无脑 +0.9*dt，会把渲染时间越推越远，甚至越过最新样本。
		# 只允许在"还没越过最新样本"时慢放；差距大就对齐到最新样本。
		if render_time_ms - latest_sample > 120:
			render_time_ms = latest_sample
		else:
			render_time_ms = mini(latest_sample, render_time_ms + maxi(1, int(dt * 900.0)))
	while snapshot_samples.size() > 1 and int(snapshot_samples[1].time_ms) <= render_time_ms:
		snapshot_samples.pop_front()
	# Residual backlog after this frame's catch-up (not the pre-frame gap, which
	# equals the frame delta even when perfectly in sync).
	diag_render_behind_ms = maxi(0, target_time - render_time_ms)
	var before: Dictionary = snapshot_samples[0]
	var after: Dictionary = snapshot_samples[1] if snapshot_samples.size() > 1 else before
	var span := maxi(1, int(after.time_ms) - int(before.time_ms))
	var weight := clampf(float(render_time_ms - int(before.time_ms)) / span, 0.0, 1.0)
	for i in range(balls.size()):
		var position: Vector2 = before.positions[i]
		balls[i].p = position.lerp(after.positions[i], weight)
		balls[i].angle = lerp_angle(before.angles[i], after.angles[i], weight)

func clear_shot_pending() -> void:
	shot_pending = false
	if shot_state == SHOT_STATE_PENDING:
		_set_shot_state(SHOT_STATE_NONE, "", 0)

func _set_shot_state(state: int, detail: String = "", hold_ms: int = 0) -> void:
	shot_state = state
	shot_state_at_ms = Time.get_ticks_msec()
	shot_state_until_ms = shot_state_at_ms + hold_ms if hold_ms > 0 else 0
	if state != SHOT_STATE_NONE:
		print("SHOT_STATE %d %s" % [state, detail])

# Transport refused the packet (socket not connected / no client). Never leave a
# "shot fired" claim on screen for something that never left the device.
func mark_shot_send_failed(detail: String = "offline") -> void:
	shot_pending = false
	# 包没交给 socket：预演出去的那一杆服务端根本不知道，必须立刻收回。
	_predict_rollback("send_failed")
	_set_shot_state(SHOT_STATE_OFFLINE, detail, 4500)

# Server answered with an explicit rejection (nonce/turn/owner mismatch).
func mark_shot_rejected(detail: String = "rejected") -> void:
	shot_pending = false
	_predict_rollback("rejected")
	_set_shot_state(SHOT_STATE_REJECTED, detail, 4000)

# Transport dropped while a shot was pending. The packet may or may not have
# arrived; say exactly that instead of pretending it was fired.
func mark_shot_offline(detail: String = "disconnected") -> void:
	if shot_pending:
		shot_pending = false
		_set_shot_state(SHOT_STATE_OFFLINE, detail, 4500)

func shot_state_text() -> String:
	match shot_state:
		SHOT_STATE_REJECTED:
			return "服务器未接受这一杆 · 请重新出杆"
		SHOT_STATE_TIMEOUT:
			return "服务器未确认 · 球若没动请重新出杆"
		SHOT_STATE_OFFLINE:
			return "未连接 · 这一杆没有发出"
	return ""

func shot_is_pending() -> bool:
	return shot_pending or shot_state == SHOT_STATE_PENDING

func note_hud_draw_us(us: int) -> void:
	if web_diag_enabled:
		diag_hud_draw_us = us

# 把插值状态每秒写进 window.arenaNetDiag，供 ?diag=1 角标显示。
# lag 是"最新快照时间 - 当前渲染时间"：健康值应该 >= 缓冲厚度，
# 如果 lag 掉到 50ms 以下，说明渲染已经顶到最新快照，画面就是在等包。
func _emit_web_diag(now: int) -> void:
	if not web_diag_enabled: return
	if now - diag_emit_ms < 500: return
	diag_emit_ms = now
	var lag := -1
	var sample_count := snapshot_samples.size()
	if sample_count > 0:
		lag = int(snapshot_samples.back().time_ms) - render_time_ms
	# buses 必须是 1（只有 Master）。>=2 就是踩到 godot#119026：Web 上 add_bus 会
	# 把 Master 与 destination 断开，整局静音且没有任何报错。
	var buses := AudioServer.bus_count
	var voices := 0
	var sfx_log := ""
	if sfx != null and sfx.has_method("active_voice_count"):
		voices = int(sfx.active_voice_count())
		var recent: Array = sfx.recent_plays
		sfx_log = ",".join(recent.slice(maxi(0, recent.size() - 4), recent.size()))
	# dc = 每帧绘制调用数；proc = 脚本耗时(ms)；draw_us = _draw 自身耗时。
	# 这三个是区分"填充率不够"和"脚本太慢"的关键：dc 低但 fps 低 → GPU 填充；
	# proc 高 → CPU 逻辑；draw_us 高 → 绘制 API 调用太多。
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var proc_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# proc 是空闲阶段合计（脚本 + _draw）；phys 是物理脚本。两者差太远就能定位是谁。
	JavaScriptBridge.eval("window.arenaNetDiag={samples:%d,lag:%d,buffer:%d,jitter:%d,buses:%d,voices:%d,dc:%d,proc:%.2f,phys:%.2f,draw:%.2f,hud:%.2f,sfx:'%s'};" % [
		sample_count, lag, int(snapshot_buffer_ms), int(snapshot_jitter_ms), buses, voices,
		draw_calls, proc_ms, phys_ms, float(diag_draw_us) / 1000.0,
		float(diag_hud_draw_us) / 1000.0, sfx_log], true)
	var gaps := _diag_gap_stats()
	var frame_stats := _diag_frame_stats()
	var ball_xy := Vector2(-1.0, -1.0)
	if turn >= 0 and turn < balls.size():
		ball_xy = to_global(balls[turn].p)
	var shot_log: Array = diag_shot_log.slice(maxi(0, diag_shot_log.size() - 2), diag_shot_log.size())
	if now - diag_perf_ms < 2000: return
	diag_perf_ms = now
	var payload := {
		"t": now,
		"ready": true,
		"turn": turn,
		"moving": moving,
		"aiming": aiming,
		"shot": shot_number,
		"pending": shot_pending,
		"paused": network_paused,
		"x": snappedf(ball_xy.x, 0.1),
		"y": snappedf(ball_xy.y, 0.1),
		"lag": lag,
		"buffer": int(snapshot_buffer_ms),
		"jitter": int(snapshot_jitter_ms),
		"samples": sample_count,
		"gap50": gaps[0],
		"gap95": gaps[1],
		"gapmax": gaps[2],
		"motion_ms": diag_motion_ms,
		"stall_ms": diag_motion_stall_ms,
		"stall_events": diag_stall_events,
		"stall_max": diag_stall_max_ms,
		"slowmo_ms": diag_slowmo_ms,
		"behind": diag_render_behind_ms,
		"ft50": frame_stats[0],
		"ft95": frame_stats[1],
		"ftmax": frame_stats[2],
		"draw_us": diag_draw_us,
		"hud_us": diag_hud_draw_us,
		"proc_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
		"phys_ms": snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"draw": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"prim": int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)),
		"shots": shot_log,
	}
	JavaScriptBridge.eval("window.arenaPerf=%s;" % JSON.stringify(payload), true)

# 球在运动时，若渲染时间已经顶到最新样本，就是在等下一个快照——这段时间
# 帧率可能仍是 60，但球不动。把它单独累计，才能和"渲染慢"分开。
func _update_diag_motion(now: int) -> void:
	if not web_diag_enabled: return
	var frame_ms := now - diag_last_frame_ms if diag_last_frame_ms > 0 else 0
	diag_last_frame_ms = now
	if moving and not snapshot_samples.is_empty():
		diag_motion_ms += frame_ms
		if diag_render_behind_ms > 120:
			diag_slowmo_ms += frame_ms
		if diag_render_at_edge:
			diag_motion_stall_ms += frame_ms
			diag_shot_stall_ms += frame_ms
			diag_stall_episode_ms += frame_ms
			diag_stall_max_ms = maxi(diag_stall_max_ms, diag_stall_episode_ms)
			diag_shot_max_stall = maxi(diag_shot_max_stall, diag_stall_episode_ms)
			if not diag_stall_active:
				diag_stall_active = true
				diag_stall_events += 1
				diag_shot_events += 1
		else:
			diag_stall_active = false
			diag_stall_episode_ms = 0
	if moving and not diag_moving_prev:
		diag_shot_started_ms = now
		diag_shot_stall_ms = 0
		diag_shot_events = 0
		diag_shot_max_stall = 0
		diag_shot_number = shot_number
		diag_stall_episode_ms = 0
		diag_stall_active = false
	elif not moving and diag_moving_prev and diag_shot_number > 0:
		diag_shot_log.append({
			"shot": diag_shot_number,
			"ms": maxi(0, now - diag_shot_started_ms),
			"stall": diag_shot_stall_ms,
			"events": diag_shot_events,
			"max": diag_shot_max_stall,
		})
		if diag_shot_log.size() > 20: diag_shot_log.pop_front()
	diag_moving_prev = moving

func _diag_frame_stats() -> Array:
	if diag_frame_deltas.is_empty(): return [-1, -1, -1]
	var sorted := diag_frame_deltas.duplicate()
	sorted.sort()
	var last := sorted.size() - 1
	return [sorted[last / 2], sorted[mini(last, int(float(last) * 0.95))], sorted[last]]

# 给对局内诊断行用：[p95_ms, max_ms]。只在诊断行刷新时调用（4Hz），不做每帧排序。
func frame_stats() -> Array:
	if diag_frame_deltas.is_empty(): return [-1, -1]
	var sorted := diag_frame_deltas.duplicate()
	sorted.sort()
	var last := sorted.size() - 1
	return [sorted[mini(last, int(float(last) * 0.95))], sorted[last]]

func _diag_gap_stats() -> Array:
	if diag_snapshot_gaps.is_empty(): return [-1, -1, -1]
	var sorted := diag_snapshot_gaps.duplicate()
	sorted.sort()
	var last := sorted.size() - 1
	return [sorted[last / 2], sorted[mini(last, int(float(last) * 0.95))], sorted[last]]

# Host events carry their real host timestamp. The client renders that host time
# later by buffer + one-way latency, so queue until render_time_ms catches up.
func _queue_presentation_event(queue: Array, event: Dictionary, kind: String,
		now: int, snapshot_time: int, first_snapshot: bool) -> void:
	var event_time := int(event.get("t", snapshot_time))
	var delay := 0
	if not first_snapshot and render_time_ms > 0:
		delay = clampi(event_time - render_time_ms, 0, PRESENTATION_MAX_DELAY_MS)
	if queue.size() >= 32: queue.pop_front()
	queue.append({"due": now + delay, "kind": kind, "ev": event})

func _flush_pending_presentation(now: int) -> void:
	while not pending_sfx_events.is_empty() and int(pending_sfx_events[0].due) <= now:
		var item: Dictionary = pending_sfx_events.pop_front()
		if now - int(item.due) > PRESENTATION_MAX_LATE_MS: continue
		if sfx != null:
			var ev: Dictionary = item.ev
			sfx.play(str(ev.get("n", "")), float(ev.get("db", 0.0)), float(ev.get("p", 1.0)))
	while not pending_fx_events.is_empty() and int(pending_fx_events[0].due) <= now:
		var fx_item: Dictionary = pending_fx_events.pop_front()
		if now - int(fx_item.due) > PRESENTATION_MAX_LATE_MS: continue
		_apply_remote_fx(fx_item.ev)
	for i in range(pending_tower_hp.size() - 1, -1, -1):
		var hp_item: Dictionary = pending_tower_hp[i]
		if int(hp_item.due) > now: continue
		var tower_index := int(hp_item.i)
		if tower_index >= 0 and tower_index < towers.size():
			towers[tower_index].hp = int(hp_item.hp)
		pending_tower_hp.remove_at(i)

func _queue_tower_hp(index: int, hp: int, due: int) -> void:
	for item in pending_tower_hp:
		if int(item.i) == index:
			item.hp = hp
			item.due = due
			return
	if pending_tower_hp.size() >= 8: pending_tower_hp.pop_front()
	pending_tower_hp.append({"i": index, "hp": hp, "due": due})

func _flush_pending_tower_hp() -> void:
	for item in pending_tower_hp:
		var index := int(item.i)
		if index >= 0 and index < towers.size():
			towers[index].hp = int(item.hp)
	pending_tower_hp.clear()

func set_player_owners(blue_player_id: String, red_player_id: String) -> void:
	slot_owner_ids = PackedStringArray([blue_player_id, blue_player_id, red_player_id, red_player_id])

## 四人模式：每个球槽由不同玩家持有（蓝1、蓝2、红1、红2）
func set_slot_owners(owners: PackedStringArray) -> void:
	if owners.size() != 4: return
	slot_owner_ids = owners

## 设置对战模式并立即重排回合。DUEL=双人各控两球，QUAD=四人各控一球、两人一队。
func set_match_mode(new_mode: int) -> void:
	if new_mode != TURN_MANAGER.Mode.DUEL and new_mode != TURN_MANAGER.Mode.QUAD: return
	if new_mode == match_mode and not finished and turn_manager.round_number == 1 and turn_manager.order_index == 0:
		return
	match_mode = new_mode
	turn_manager.setup(match_mode)
	turn = turn_manager.current_slot()
	aim_slot = -1
	aim_nonce = -1
	aim_team = -1
	moving = false
	aiming = false
	shot_number = 0
	timer = 15.0

## 返回当前模式下的“玩家→球槽”归属，供 UI/测试展示。结果与 TurnManager.MODE_PLAYER_OWNERS 一致。
func mode_player_owners() -> Array:
	return TURN_MANAGER.MODE_PLAYER_OWNERS[match_mode]

func owner_of_slot(slot: int) -> String:
	return slot_owner_ids[slot] if slot >= 0 and slot < 4 else ""

# 血量上限给 HUD 用：血条比例不能写死 100
func tower_hp_max() -> int:
	return TOWER_HP


# 播一次音效，同时记进快照让客户端跟着播（本地立刻响，不等网络）
func _emit_sfx(sound: Dictionary) -> void:
	if sound.is_empty() or sfx == null:
		return
	sfx.play(str(sound["name"]), float(sound["db"]), float(sound["pitch"]))
	sfx_seq += 1
	sfx_events.append({"id": sfx_seq, "t": Time.get_ticks_msec(), "n": str(sound["name"]), "db": float(sound["db"]), "p": float(sound["pitch"])})
	if sfx_events.size() > SFX_BUFFER:
		sfx_events.remove_at(0)


func make_network_snapshot() -> Dictionary:
	var ball_state: Array = []
	for b in balls:
		# 位置与速度必须发原值，不能像以前那样 snappedf(..., 0.01)。
		# 客户端拿它当本地预演的初值：台球是混沌系统，0.01px 的初值误差
		# 在几百帧碰撞里会放大到十几像素，杆末就会整盘球跳一下。
		# JSON 对 float 是无损往返的（13~17 位，能精确还原 float32）。
		ball_state.append({"kind": b.kind, "hp": b.hp, "p": [b.p.x, b.p.y], "v": [b.v.x, b.v.y], "alive": b.alive, "armed": b.armed, "angle": snappedf(b.angle, 0.001), "spin": snappedf(b.spin, 0.001), "owner_side": b.get("owner_side", -1)})
	return {"type": "snapshot", "seed": match_seed, "hole": [holes[0].x, holes[0].y] if not holes.is_empty() else [], "holes": holes.map(func(h): return [h.x, h.y]), "balls": ball_state, "tower_hp": towers.map(func(t): return t.hp), "owners": slot_owner_ids, "turn": turn, "order": turn_manager.order.duplicate(), "order_index": turn_manager.order_index, "round": turn_manager.round_number, "nonce": turn_manager.turn_nonce, "phase": turn_manager.phase, "moving": moving, "finished": finished, "winner": winner_side, "reads": [0, 0, 0, 0], "tower_skill": tower_skill.map(func(t): return {"skill": str(t.get("skill", "")), "charge": int(t.get("charge", 0))}), "double_shots": team_double_shots.duplicate(), "stun_shots": team_stun_shots.duplicate(), "sfx": sfx_events, "fx": fx_events, "sfx_seq": sfx_seq, "fx_seq": fx_seq, "result": result_text, "timer": timer, "shot_number": shot_number, "orb_serial": orb_spawn_serial, "last_hit": last_hit}

func apply_network_snapshot(state: Dictionary) -> void:
	if not network_client_mode: return
	var seq := int(state.get("seq", last_snapshot_seq + 1))
	if seq <= last_snapshot_seq: return
	var shot_stopped := not bool(state.get("moving", false))
	# 出杆方预演中：权威还在跑的这一杆对本机没信息量（本地已经跑到更前面），
	# 整包丢掉；只有 rest（moving=false）才进来做对账并推进回合。
	if predict_active:
		if not shot_stopped: return
		# 只有"服务端确实记下了这一杆"的 rest 才算数：松手那一瞬间可能正好
		# 有一份静止期心跳在路上，它的 shot_number 还是旧值，拿它当 rest 会把球拽回去。
		if int(state.get("shot_number", 0)) <= predict_base_shot_number: return
		_predict_end_from_rest(state)
	if not shot_stopped and not predict_active and not replay_active and replay_frames.is_empty():
		# 这一杆本地既没预演、也没收到轨迹帧：主动要兜底，别让画面停在杆前。
		_request_trajectory()
	if shot_stopped:
		last_motion_end_host_ms = maxi(last_motion_end_host_ms, int(state.get("host_ms", 0)))
	# 本局第一个快照：只用来对齐"事件水位"，不补播历史。
	var first_snapshot := last_snapshot_seq < 0
	var ball_state: Array = state.get("balls", [])
	if ball_state.size() < 4: return
	match_seed = int(state.get("seed", match_seed))
	var tower_skill_raw: Variant = state.get("tower_skill", [])
	if tower_skill_raw is Array:
		for i in range(mini((tower_skill_raw as Array).size(), tower_skill.size())):
			var item: Variant = (tower_skill_raw as Array)[i]
			if item is Dictionary:
				tower_skill[i] = {"skill": str((item as Dictionary).get("skill", "")),
					"charge": int((item as Dictionary).get("charge", 0))}
	var dbl_raw: Variant = state.get("double_shots", [])
	if dbl_raw is Array and (dbl_raw as Array).size() == 2:
		team_double_shots = [int((dbl_raw as Array)[0]), int((dbl_raw as Array)[1])]
	var stun_raw: Variant = state.get("stun_shots", [])
	if stun_raw is Array and (stun_raw as Array).size() == 2:
		team_stun_shots = [int((stun_raw as Array)[0]), int((stun_raw as Array)[1])]
	winner_side = int(state.get("winner", -1))
	result_text = str(state.get("result", ""))
	var holes_before: Array[Vector2] = []
	holes_before.assign(holes)
	holes.clear()
	var holes_raw: Variant = state.get("holes", [])
	if holes_raw is Array:
		for item in holes_raw:
			if item is Array and (item as Array).size() == 2:
				holes.append(Vector2(float(item[0]), float(item[1])))
	if holes.is_empty():
		# 旧服务端只发单个 hole
		var hpnt: Variant = state.get("hole", [])
		if hpnt is Array and (hpnt as Array).size() == 2:
			holes.append(Vector2(float(hpnt[0]), float(hpnt[1])))
	# 客户端靠快照对比补播"洞被火球烧掉"的爆散（物理只在主机跑）
	if network_client_mode:
		for old_hole in holes_before:
			var still_there := false
			for now_hole in holes:
				if old_hole.distance_to(now_hole) < 12.0:
					still_there = true
					break
			if not still_there:
				_add_hole_break_fx(old_hole)
	if balls.size() != ball_state.size(): snapshot_samples.clear()
	# 道具球被就地替换时球数不变，但位置会跳。靠序列号清掉插值样本，
	# 让这一帧直接对齐权威位置，不会出现"新球种停在旧位置再滑过去"。
	var orb_serial := int(state.get("orb_serial", -1))
	if orb_serial >= 0 and orb_serial != orb_spawn_serial:
		orb_spawn_serial = orb_serial
		if not first_snapshot: snapshot_samples.clear()
	while balls.size() < ball_state.size(): balls.append(_ball("iron", -1, Vector2.ZERO))
	if not replay_active:
		# 回放期间球的结构不能变：这一杆的帧是按 recording 时的球数录的，
		# 中途长出一颗新球会立刻对不上。新球等 rest 落地时一起加进来。
		balls.resize(ball_state.size())
	for i in range(4):
		if i >= balls.size() or i >= ball_state.size(): break
		if not balls[i].alive and ball_state[i].alive: snapshot_samples.clear()
	last_snapshot_seq = seq
	if state.has("owners"): slot_owner_ids = PackedStringArray(state.owners)
	var now := Time.get_ticks_msec()
	var time_ms := int(state.get("host_ms", now))
	var paused := bool(state.get("paused", false))
	# A reconnect after a long pause resumes from fresh positions instead of replaying old samples.
	if network_paused and not paused and time_ms - render_time_ms > int(snapshot_buffer_ms) * 3:
		snapshot_samples.clear()
	# 声音事件由主机产生，客户端照着播：物理只在主机跑，客户端自己算不出碰撞。
	# 关键是"按渲染时间播"：快照本身比球早到 buffer 毫秒，立刻播会让声音抢在
	# 画面前面。事件带主机时间戳 t，排队到 render_time 追上 t 时再响。
	var sfx_list: Variant = state.get("sfx", [])
	if network_client_mode and sfx != null:
		# 本局第一个快照只用来对齐水位：把主机当前的事件序号当作起点。
		# 开局就连上时水位是 0，第一条照样响；中途连上时则是 N，不会补播一串旧声音。
		if first_snapshot:
			last_sfx_id = int(state.get("sfx_seq", last_sfx_id))
		if sfx_list is Array and not (sfx_list as Array).is_empty():
			var newest := last_sfx_id
			for item in sfx_list:
				if item is Dictionary:
					newest = maxi(newest, int((item as Dictionary).get("id", 0)))
			for item in sfx_list:
				if not (item is Dictionary):
					continue
				var event: Dictionary = item
				if int(event.get("id", 0)) <= last_sfx_id:
					continue
				_queue_presentation_event(pending_sfx_events, event, "sfx", now, time_ms, first_snapshot)
			last_sfx_id = newest
	# 撞击特效：主机记事件、客户端重放。客户端不跑物理，没有这条就只剩球在动。
	var fx_list: Variant = state.get("fx", [])
	if network_client_mode:
		if first_snapshot:
			last_fx_id = int(state.get("fx_seq", last_fx_id))
		if fx_list is Array and not (fx_list as Array).is_empty():
			var newest_fx := last_fx_id
			for item in fx_list:
				if item is Dictionary:
					newest_fx = maxi(newest_fx, int((item as Dictionary).get("id", 0)))
			for item in fx_list:
				if not (item is Dictionary):
					continue
				var fx_event: Dictionary = item
				if int(fx_event.get("id", 0)) <= last_fx_id:
					continue
				_queue_presentation_event(pending_fx_events, fx_event, "fx", now, time_ms, first_snapshot)
			last_fx_id = newest_fx
	var positions := PackedVector2Array()
	var angles := PackedFloat32Array()
	positions.resize(balls.size())
	angles.resize(balls.size())
	if snapshot_samples.is_empty():
		snapshot_clock_offset = now - time_ms
		render_time_ms = time_ms - int(snapshot_buffer_ms)
	else:
		# 原来只取历史最小值：一旦遇到一次最快到达的样本，偏移就永久锁死，
		# 之后网络稍慢，渲染时间就顶到最新样本上（球停住等下一帧）。
		# 允许每个样本最多回升 1ms，让它慢慢跟上真实延迟。
		snapshot_clock_offset = mini(snapshot_clock_offset + 1, now - time_ms)
	# host 固定 50ms 发一次快照；到达间隔偏离多少，就是这条链路的抖动。
	# 抖动越大，插值缓冲越厚，避免"渲染时间追上最新样本 → 球停住"。
	if last_snapshot_arrival_ms > 0:
		var arrival_gap := float(now - last_snapshot_arrival_ms)
		# 只有"正常节奏"的到达间隔才代表链路抖动。主机在球静止时不会每 50ms 发，
		# 间隔可能拉到几百毫秒——把它当抖动会把缓冲永久顶到上限（240ms），
		# 表现就是"对方球慢半拍"。空闲期的间隔改为让抖动缓慢衰减。
		if arrival_gap > 0.0 and arrival_gap < 150.0:
			var deviation := absf(arrival_gap - 50.0)
			snapshot_jitter_ms = lerpf(snapshot_jitter_ms, deviation, 0.12)
		else:
			snapshot_jitter_ms = maxf(0.0, snapshot_jitter_ms - 2.0)
		if web_diag_enabled:
			var gap := now - last_snapshot_arrival_ms
			if gap > 0 and gap < 5000:
				diag_snapshot_gaps.append(gap)
				if diag_snapshot_gaps.size() > 64: diag_snapshot_gaps.pop_front()
	last_snapshot_arrival_ms = now
	# 缓冲厚度分方向控速：抖动变厚要快（8ms/样本 ≈ 160ms/s），否则球后半程撞塔、
	# 主机快照间隔被拉长时来不及补；网络恢复后只肯慢慢变薄（1ms/样本），
	# 避免缓冲自己抖成另一个"快进慢放"。
	# RTT 也要计入基础厚度：300ms RTT 的单程延迟就是 150ms，只靠 140ms 基础值
	# 会让第一杆从半途开始播。正常网络（RTT < 60）保持 140ms，不回退低延迟。
	var rtt_floor := 0.0
	if network_rtt_ms > 0:
		rtt_floor = clampf(float(network_rtt_ms) * 0.5 + 30.0, 0.0, 280.0)
	var base_buffer := maxf(SNAPSHOT_BUFFER_BASE_MS, rtt_floor)
	var max_buffer := maxf(SNAPSHOT_BUFFER_MAX_MS, base_buffer + 60.0)
	var wanted_buffer := clampf(base_buffer + snapshot_jitter_ms * SNAPSHOT_JITTER_GAIN,
		base_buffer, max_buffer)
	if wanted_buffer > snapshot_buffer_ms:
		snapshot_buffer_ms = minf(wanted_buffer, snapshot_buffer_ms + 8.0)
	else:
		snapshot_buffer_ms = maxf(wanted_buffer, snapshot_buffer_ms - 1.0)
	for i in range(mini(balls.size(), ball_state.size())):
		var source: Dictionary = ball_state[i]
		positions[i] = Vector2(float(source.p[0]), float(source.p[1]))
		angles[i] = float(source.angle)
		# 回放期间球的位置/生死由轨迹帧决定。这一份状态只当"到点校正"用：
		# 提前套上去会让球先死一次、再在回放里活过来。
		if replay_active: continue
		balls[i].v = Vector2(float(source.v[0]), float(source.v[1]))
		balls[i].kind = source.get("kind", balls[i].kind)
		balls[i].hp = int(source.get("hp", balls[i].hp))
		# 客户端不跑物理，看不到真实碰撞：靠"上一帧还活着、这一帧没了"补播吞噬特效
		if network_client_mode and bool(balls[i].alive) and not bool(source.alive):
			_spawn_hole_swallow(balls[i].p, _ball_tint(balls[i]), balls[i].r)
		balls[i].alive = source.alive
		balls[i].armed = source.armed
		balls[i].owner_side = source.owner_side
	if not replay_active:
		# 回放期间不攒样本：收尾时这批"杆前位置"会被当成最新一帧，把球拉回去。
		if not snapshot_samples.is_empty() and int(snapshot_samples.back().time_ms) == time_ms:
			snapshot_samples.pop_back()
		snapshot_samples.append({"time_ms": time_ms, "positions": positions, "angles": angles})
	if snapshot_samples.size() > SNAPSHOT_BUFFER_LIMIT:
		# Keep unrendered samples: a burst must not evict the bounce the ball is
		# about to reach. Only consumed samples (or a hard safety cap) are dropped.
		while snapshot_samples.size() > SNAPSHOT_BUFFER_LIMIT:
			if int(snapshot_samples[0].time_ms) <= render_time_ms or snapshot_samples.size() > SNAPSHOT_BUFFER_HARD_LIMIT:
				snapshot_samples.pop_front()
			else:
				break
	var hp_values: Array = state.get("tower_hp", [])
	if hp_values.size() == towers.size():
		var finish_now := bool(state.get("finished", false))
		var hp_delay := 0
		if not finish_now and not first_snapshot and render_time_ms > 0:
			hp_delay = clampi(time_ms - render_time_ms, 0, PRESENTATION_MAX_DELAY_MS)
		for i in range(towers.size()):
			var target_hp := int(hp_values[i])
			if int(towers[i].hp) == target_hp: continue
			# HP dropped at the host when the collision happened; show it when the
			# ball actually reaches the tower on screen, not a buffer earlier.
			if finish_now or hp_delay <= 0:
				towers[i].hp = target_hp
			else:
				_queue_tower_hp(i, target_hp, now + hp_delay)
	var previous_turn := turn
	turn = int(state.turn)
	if turn != previous_turn and not bool(state.get("finished", false)) and turn >= 0 and turn < balls.size() and balls[turn].alive:
		_add_floater("到你啦!", balls[turn].p + Vector2(0.0, -BALL_RADIUS - 30.0), Color("6fd3e8"), 28, 2)
	turn_manager.order_index = int(state.order_index)
	turn_manager.round_number = int(state.round)
	# 出手次序由权威方抽签，随快照下发：客户端先换表再对 order_index，
	# 否则 can_act/current_slot 会按旧的固定次序判，自己的回合反而点不动。
	var order_raw: Variant = state.get("order", [])
	if order_raw is Array and (order_raw as Array).size() == 4:
		turn_manager.set_order(order_raw)
	if int(state.nonce) != turn_manager.turn_nonce: clear_network_aim()
	turn_manager.turn_nonce = int(state.nonce)
	turn_manager.phase = int(state.phase) as TURN_MANAGER.Phase
	# 回放还没播完时收到 rest（moving=false）：先别放开输入、也别弹结算，
	# 等画面把最后一帧播完再落地。否则球还在滚，读秒已经开始。
	var replay_rest := network_client_mode and replay_active and shot_stopped
	if network_client_mode and shot_stopped and not replay_active and not replay_frames.is_empty():
		# 杆已经结束、回放却还没起播（杆太短或这一段链路太慢）：
		# 状态已经到终点了，再倒回去重播只会让球往回跳一下。
		replay_closed_shot = replay_shot_id
		replay_frames.clear()
		replay_latest = -1
	if replay_rest:
		replay_got_rest = true
		replay_pending_finished = bool(state.get("finished", false))
		var rest_balls: Variant = state.get("balls", [])
		if rest_balls is Array: replay_rest_balls = rest_balls
	moving = not shot_stopped
	if replay_rest: moving = true
	finished = bool(state.finished) and not replay_rest
	timer = float(state.timer)
	shot_number = int(state.shot_number)
	# 服务端已经记下这一杆（shot_number 增长），等待结束。
	if shot_pending and shot_number > shot_pending_number:
		shot_pending = false
		_set_shot_state(SHOT_STATE_NONE, "", 0)
	last_hit = str(state.last_hit)
	network_paused = paused
	if moving or finished or network_paused: clear_network_aim()
	# Once the shot has stopped, every impact is in the past: apply any HP still
	# waiting for its render timestamp so the next turn never starts with a stale bar.
	if not moving:
		_flush_pending_tower_hp()

# --- 一杆一轨迹：客户端回放 ------------------------------------------------
func replay_is_active() -> bool:
	return replay_active

func clear_network_replay() -> void:
	_replay_reset()
	replay_shot_id = -1
	replay_closed_shot = -1
	replay_shot_start_ms = 0
	replay_ball_count = 0

func _replay_reset() -> void:
	replay_active = false
	replay_frames.clear()
	replay_latest = -1
	replay_head = 0.0
	replay_got_rest = false
	replay_pending_finished = false
	replay_rest_balls = []
	replay_stall_ms = 0
	replay_total_frames = 0
	replay_bytes = 0

# 追加一段轨迹帧。帧号连续且单调，重复帧（重连补发）直接丢掉。
func apply_trajectory_chunk(state: Dictionary) -> bool:
	if not network_client_mode: return false
	# 预演期间不播回放：这一杆的画面由本地算。
	if predict_active: return false
	# 这一杆在本机已经播完了（预演或回放）：晚到的轨迹包直接丢，
	# 否则会在收尾之后把球倒回去重播一遍。开始时刻早于"最近一次权威静止"
	# 就是上一杆的东西。
	if int(state.get("start_ms", 0)) <= last_motion_end_host_ms: return false
	var shot_id := int(state.get("shot_id", -1))
	if shot_id <= 0: return false
	if shot_id == replay_closed_shot: return false
	if shot_id != replay_shot_id:
		_replay_reset()
		replay_shot_id = shot_id
		replay_shot_start_ms = int(state.get("start_ms", 0))
		replay_ball_count = int(state.get("ball_count", 0))
		if replay_ball_count != balls.size():
			# 球数对不上说明我们还停在上一杆的结构上：这一杆不播，等 rest 追平。
			replay_closed_shot = shot_id
			print("SHOT_REPLAY_SKIP shot=%d balls=%d/%d" % [shot_id, replay_ball_count, balls.size()])
			return false
	var frame_ms := float(state.get("frame_ms", replay_frame_ms))
	if frame_ms > 1.0: replay_frame_ms = frame_ms
	var frames_raw: Variant = state.get("frames", [])
	if not frames_raw is Array: return false
	var appended := 0
	for frame in frames_raw:
		if not frame is Dictionary: continue
		var frame_index := int((frame as Dictionary).get("k", -1))
		if frame_index <= replay_latest: continue
		replay_frames.append(frame)
		replay_latest = frame_index
		appended += 1
	if appended > 0:
		replay_total_frames += appended
		replay_bytes += int(state.get("bytes", 0))
	return appended > 0

# 起播缓冲随 RTT 加厚：单程延迟越大，段与段之间的空档越容易被抖动撕开。
func _replay_lead_frames() -> int:
	var extra := 0
	if network_rtt_ms > 0:
		extra = clampi(int(round(float(network_rtt_ms) / 33.0)), 0, 6)
	return REPLAY_LEAD_FRAMES + extra

# 返回 true 表示这一帧的画面由回放提供，调用方不要再跑快照插值。
func _replay_advance(dt: float) -> bool:
	if replay_frames.is_empty(): return false
	var first_index := int(replay_frames[0].k)
	var lead := _replay_lead_frames()
	if not replay_active:
		if not replay_got_rest and replay_latest - first_index < lead:
			# 还没攒够缓冲：把球钉在第一帧（就是出杆前的位置）上。
			# 这里不能放快照插值进来，否则它会按自己的时钟改 render_time_ms，
			# 撞击火花就会按错误的时刻排队。
			render_time_ms = replay_shot_start_ms + int(round(float(first_index) * replay_frame_ms))
			diag_render_at_edge = false
			var pin: Dictionary = replay_frames[0]
			_apply_replay_frame(pin, pin, 0.0)
			return true
		# 攒够缓冲再起播；整杆已经结束（rest 到了）就不再等，短杆直接播完。
		replay_head = float(maxi(first_index, replay_latest - lead))
		replay_stall_ms = 0
		replay_active = true
		# 杆前的快照样本留着会在收尾时把球拉回起点，也会污染静止诊断。
		snapshot_samples.clear()
		diag_render_at_edge = false
	var speed := 1.0
	if not replay_got_rest and float(replay_latest) - replay_head < float(lead) * 0.5:
		# 缓冲掉到一半以下：用 8% 的速度差把它悄悄补回来。
		# 不做这件事的话，一次欠载就永久吃掉一截缓冲，越抖越糟。
		speed = 1.08
	replay_head += float(dt * 1000.0) / replay_frame_ms * speed
	if replay_head > float(replay_latest):
		if replay_got_rest:
			_replay_finish()
			return false
		# 下一段还没到：停住等，而不是跳帧。缓冲正常时走不到这里。
		replay_stall_ms += int(round(dt * 1000.0))
		replay_head = float(replay_latest)
		if replay_stall_ms >= REPLAY_STALL_MAX_MS:
			_replay_finish()
			return false
	else:
		replay_stall_ms = 0
	# 丢掉已经播过、且不是下一段起点的帧
	while replay_frames.size() > 2 and int(replay_frames[1].k) <= int(replay_head):
		replay_frames.pop_front()
	var index := 0
	for i in range(replay_frames.size()):
		if int(replay_frames[i].k) <= int(replay_head): index = i
		else: break
	var before: Dictionary = replay_frames[index]
	var after: Dictionary = replay_frames[index + 1] if index + 1 < replay_frames.size() else before
	var span := maxf(1.0, float(int(after.k) - int(before.k)))
	var weight := clampf((replay_head - float(before.k)) / span, 0.0, 1.0)
	# 让特效队列知道"画面现在播到主机的哪个时刻"，否则撞击火花会晚到一拍。
	render_time_ms = replay_shot_start_ms + int(round(replay_head * replay_frame_ms))
	_apply_replay_frame(before, after, weight)
	return true

func _apply_replay_frame(before: Dictionary, after: Dictionary, weight: float) -> void:
	if replay_ball_count != balls.size(): return
	var pos_before: PackedVector2Array = before.pos
	var pos_after: PackedVector2Array = after.pos
	var ang_before: PackedFloat32Array = before.ang
	var ang_after: PackedFloat32Array = after.ang
	var count: int = mini(replay_ball_count, mini(pos_before.size(), pos_after.size()))
	for i in range(count):
		var ball: Dictionary = balls[i]
		var was_alive := bool(ball.alive)
		var dead := (int(before.dead) & (1 << i)) != 0 or (int(after.dead) & (1 << i)) != 0
		if dead:
			if was_alive:
				_spawn_hole_swallow(ball.p, _ball_tint(ball), ball.r)
			ball.alive = false
			continue
		ball.p = pos_before[i].lerp(pos_after[i], weight)
		if i < ang_before.size() and i < ang_after.size():
			ball.angle = lerp_angle(float(ang_before[i]), float(ang_after[i]), weight)
		if not was_alive: ball.alive = true

func _replay_finish() -> void:
	var shot := replay_shot_id
	replay_closed_shot = shot
	replay_active = false
	replay_frames.clear()
	replay_latest = -1
	snapshot_samples.clear()
	render_time_ms = 0
	# 先把 rest 的权威球状态套上去（复活/换球种都在这里发生），再放开输入。
	if not replay_rest_balls.is_empty():
		_apply_rest_ball_state(replay_rest_balls)
		replay_rest_balls = []
	# rest 已经把真实回合推进过了：这里只是把输入/结算的闸门放开。
	moving = false
	_flush_pending_tower_hp()
	if replay_pending_finished: finished = true
	replay_pending_finished = false
	replay_got_rest = false
	print("SHOT_REPLAY shot=%d frames=%d stall_ms=%d bytes=%d" % [shot, replay_total_frames, replay_stall_ms, replay_bytes])

func _apply_rest_ball_state(ball_state: Array) -> void:
	while balls.size() < ball_state.size(): balls.append(_ball("iron", -1, Vector2.ZERO))
	if balls.size() > ball_state.size(): balls.resize(ball_state.size())
	for i in range(balls.size()):
		if not (ball_state[i] is Dictionary): continue
		var source: Dictionary = ball_state[i]
		balls[i].p = Vector2(float(source.p[0]), float(source.p[1]))
		balls[i].angle = float(source.get("angle", balls[i].angle))
		balls[i].v = Vector2(float(source.v[0]), float(source.v[1]))
		balls[i].kind = str(source.get("kind", balls[i].kind))
		balls[i].hp = int(source.get("hp", balls[i].hp))
		balls[i].alive = bool(source.alive)
		balls[i].armed = bool(source.get("armed", false))
		balls[i].owner_side = int(source.get("owner_side", -1))

# --- 出杆方本地预演：同一份 step() 在手机上先跑 ------------------------------
func predict_is_active() -> bool:
	return predict_active

func _request_trajectory() -> void:
	if not network_client_mode: return
	var now := Time.get_ticks_msec()
	if now - traj_request_ms < 500: return
	traj_request_ms = now
	trajectory_needed.emit()

# 别人出杆：收到事件就在本地开跑，不用等 200ms 的轨迹回放。
# 状态不满足（还在上一杆、回合对不上、观战席）就安静放弃，回放会兜住。
func apply_remote_shot(state: Dictionary) -> bool:
	if not network_client_mode: return false
	if predict_active: return false
	# 观战者也参与预演：他们的球状态和参赛者来自同一份快照，起不来会自动回落放。
	var slot := int(state.get("slot", -1))
	if slot < 0 or slot >= balls.size(): return false
	var nonce_value: Variant = state.get("nonce", -1)
	if not (nonce_value is int or nonce_value is float): return false
	if int(nonce_value) != turn_manager.turn_nonce: return false
	var pull_raw: Variant = state.get("pull", [])
	if not pull_raw is Array or (pull_raw as Array).size() != 2: return false
	var pull_x: Variant = (pull_raw as Array)[0]
	var pull_y: Variant = (pull_raw as Array)[1]
	if not (pull_x is int or pull_x is float) or not (pull_y is int or pull_y is float): return false
	var shot_pull := Vector2(float(pull_x), float(pull_y))
	# 队伍由球槽推，不信客户端自称的身份。
	if not _predict_begin(0 if slot < 2 else 1, slot, shot_pull):
		# 预演起不来（还在播上一杆 / 回合对不上）：让宿主补轨迹兜底。
		_request_trajectory()
		return false
	print("REMOTE_PREDICT slot=%d" % slot)
	return true

func _predict_begin(team: int, slot: int, shot_pull: Vector2) -> bool:
	if not network_client_mode or predict_active: return false
	# 这里不再拦 spectator_mode：观战者也要零延迟。
	# 观战者无法"出杆"是靠 can_control_current_ball 里的 spectator_mode 挡的，
	# 这条路径只负责让球动起来。
	if finished or moving: return false
	if slot < 0 or slot >= balls.size() or not bool(balls[slot].alive): return false
	if not shot_pull.is_finite(): return false
	if shot_pull.length() < MIN_SHOT_PULL or shot_pull.length() > MAX_PULL + 0.01: return false
	if team != turn_manager.current_team() or slot != turn_manager.current_slot(): return false
	_predict_backup_state()
	# 只做出杆必需的那一步。shot_number / 双倍消耗 / 塔技能充能 / 吸血球归属
	# 这些副作用全部留给权威：本地抢先改一次，随后快照又把它改回去，
	# 界面上看起来就像"扣了两次"。
	pull = shot_pull
	predict_slot = slot
	predict_active = true
	predict_settled = false
	predict_steps = 0
	predict_drift_px = 0.0
	predict_started_ms = Time.get_ticks_msec()
	predict_settled_ms = 0
	predict_base_shot_number = shot_number
	# 技能充能 / 双倍消耗 / 吸血球归属：本地也走一遍，杆进行中界面才跟得上。
	# 权威 rest 会整体覆盖，不会双算；shot_number 仍然只由权威推进。
	_apply_shot_bookkeeping()
	balls[slot].v = shot_pull * power
	moving = true
	quiet = 0.0
	shot_elapsed = 0.0
	aiming = false
	aim_pointer_valid = false
	# 这一杆的画面由本地算：别让快照插值/轨迹回放插一脚。
	snapshot_samples.clear()
	_replay_reset()
	shot_pending = false
	if shot_state != SHOT_STATE_NONE: _set_shot_state(SHOT_STATE_NONE, "", 0)
	clear_network_aim()
	return true

func _predict_backup_state() -> void:
	predict_backup = []
	for ball in balls:
		predict_backup.append((ball as Dictionary).duplicate(true))
	predict_backup_towers = []
	for tower in towers:
		predict_backup_towers.append((tower as Dictionary).duplicate(true))
	predict_backup_holes = holes.duplicate()

func _predict_restore_state() -> void:
	for i in range(mini(balls.size(), predict_backup.size())):
		var target: Dictionary = balls[i]
		target.clear()
		target.merge(predict_backup[i], true)
	for i in range(mini(towers.size(), predict_backup_towers.size())):
		var target_tower: Dictionary = towers[i]
		target_tower.clear()
		target_tower.merge(predict_backup_towers[i], true)
	holes.clear()
	for hole in predict_backup_holes: holes.append(hole)
	predict_backup = []
	predict_backup_towers = []
	predict_backup_holes = []

# 只推进物理与滚动视觉：特效寿命、吞噬动画由 _process 统一推进，
# 这里再推一次会让火花消失速度快一倍。
func _predict_step(dt: float) -> void:
	if not predict_active or predict_settled: return
	if not moving: return
	shot_elapsed += dt
	for sub in range(4): step(dt / 4.0)
	_update_orb_visuals(dt)
	predict_steps += 1
	var max_speed := 0.0
	for ball in balls:
		if bool(ball.alive): max_speed = maxf(max_speed, (ball.v as Vector2).length())
	quiet = quiet + dt if max_speed < 5.0 else 0.0
	if quiet > 0.25 or shot_elapsed >= SHOT_TIMEOUT:
		# 本地判定停住了：画面冻结等权威 rest。这里绝不调用 next_turn()——
		# 推进回合要抽签、刷道具球、开洞，只有权威能做。
		predict_settled = true
		predict_settled_ms = Time.get_ticks_msec()
		for ball in balls: ball.v = Vector2.ZERO

# rest 到了：先算一次偏差（日志用），再把权威状态交给调用方覆盖。
func _predict_end_from_rest(state: Dictionary) -> void:
	if not predict_active: return
	predict_drift_px = 0.0
	var ball_state: Variant = state.get("balls", [])
	if ball_state is Array and (ball_state as Array).size() == balls.size():
		for i in range(balls.size()):
			var source: Variant = (ball_state as Array)[i]
			if not source is Dictionary: continue
			var authoritative := Vector2(float((source as Dictionary).p[0]), float((source as Dictionary).p[1]))
			predict_drift_px = maxf(predict_drift_px, (balls[i].p as Vector2).distance_to(authoritative))
	# 本地这一杆的声音与火花已经播过了：把事件水位推到权威最新，
	# 否则 rest 里带回来的同一批事件会再响一遍、再炸一次。
	last_sfx_id = int(state.get("sfx_seq", last_sfx_id))
	last_fx_id = int(state.get("fx_seq", last_fx_id))
	predict_active = false
	predict_settled = false
	predict_backup = []
	predict_backup_towers = []
	predict_backup_holes = []
	snapshot_samples.clear()
	print("PREDICT_END slot=%d steps=%d drift=%.3fpx" % [predict_slot, predict_steps, predict_drift_px])

# 服务端明确拒绝（no_seat / not_owner / stale_turn）或包根本没发出去：
# 球必须回到出杆前，否则屏幕上会留下一个服务端不存在的一杆。
func _predict_rollback(reason: String) -> void:
	if not predict_active: return
	_predict_restore_state()
	predict_active = false
	predict_settled = false
	moving = false
	quiet = 0.0
	shot_elapsed = 0.0
	snapshot_samples.clear()
	print("PREDICT_ROLLBACK reason=%s" % reason)

func clear_network_prediction() -> void:
	if not predict_active:
		predict_backup = []
		predict_backup_towers = []
		predict_backup_holes = []
		return
	_predict_restore_state()
	predict_active = false
	predict_settled = false
	moving = false
	quiet = 0.0
	shot_elapsed = 0.0
	snapshot_samples.clear()

# 预演播完却迟迟等不到权威 rest（链路半死）：保住已算出的画面，只把输入闸门放开，
# 让玩家还能继续操作；下一次快照/重连会把状态拉回权威。
func _predict_abandon(reason: String) -> void:
	if not predict_active: return
	predict_active = false
	predict_settled = false
	predict_backup = []
	predict_backup_towers = []
	predict_backup_holes = []
	moving = false
	quiet = 0.0
	shot_elapsed = 0.0
	snapshot_samples.clear()
	print("PREDICT_ABANDON reason=%s slot=%d drift=%.2fpx" % [reason, predict_slot, predict_drift_px])

func _record_debug_contact(kind: String, ball_index: int, shape_index: int, point: Vector2, normal: Vector2, speed: float, correction: float) -> void:
	if not debug_collisions: return
	if kind == "outside fan":
		for contact in debug_contacts:
			if contact.kind == kind and contact.ball == ball_index and contact.shape == shape_index:
				contact.point = point
				contact.normal = normal
				contact.life = 0.35
				return
	if debug_contacts.size() >= 32: debug_contacts.pop_front()
	debug_contacts.append({"kind": kind, "ball": ball_index, "shape": shape_index, "point": point, "normal": normal, "speed": speed, "correction": correction, "life": 0.35})

func _add_graze_spin(b: Dictionary, contact_normal: Vector2, pre_impact_velocity: Vector2) -> void:
	var tangent := Vector2(-contact_normal.y, contact_normal.x)
	var normal_speed: float = absf(pre_impact_velocity.dot(contact_normal))
	var tangent_speed: float = pre_impact_velocity.dot(tangent)
	if absf(tangent_speed) < 0.001: return
	# Spin scales with tangential speed (force gradient): a light touch barely turns,
	# a hard grazing hit spins hard. The graze factor only tilts the curve, not a flat multiplier.
	var graze: float = absf(tangent_speed) / maxf(normal_speed + absf(tangent_speed), 0.001)
	var spin_added: float = -tangent_speed / b.r * 0.5 * (0.5 + graze * 0.7)
	b.spin_kick = clampf(b.spin_kick + spin_added, -40.0, 40.0)
	b.spin = clampf(b.spin + spin_added, -40.0, 40.0)

func _update_orb_visuals(dt: float) -> void:
	for b in balls:
		if not b.alive: continue
		var velocity: Vector2 = b.v
		var target_spin := 0.0
		if velocity.length() > 4.0:
			var roll_direction := signf(velocity.x) if absf(velocity.x) >= absf(velocity.y) else -signf(velocity.y)
			target_spin = roll_direction * minf(velocity.length() / b.r * 0.5, 14.0)
		target_spin = clampf(target_spin + b.spin_kick, -40.0, 40.0)
		b.spin = lerpf(b.spin, target_spin, 1.0 - exp(-12.0 * dt))
		b.angle = fposmod(b.angle + b.spin * dt, TAU)
		b.spin_kick *= exp(-2.1 * dt)
		b.impact *= exp(-12.0 * dt)

func _update_tower_impacts(dt: float) -> void:
	for i in range(tower_impacts.size() - 1, -1, -1):
		var effect: Dictionary = tower_impacts[i]
		effect.life -= dt
		if effect.life <= 0.0:
			tower_impacts.remove_at(i)

func _add_tower_impact(ball_index: int, tower_index: int, point: Vector2, normal: Vector2, speed: float, side: int) -> void:
	for effect in tower_impacts:
		if effect.ball == ball_index and effect.tower == tower_index:
			return
	var strength := clampf((speed - 60.0) / 1200.0, 0.08, 1.0)
	var duration := 0.10 + strength * 0.10
	if tower_impacts.size() >= 12:
		tower_impacts.pop_front()
	tower_impacts.append({"ball": ball_index, "tower": tower_index, "p": point, "n": normal, "side": side, "strength": strength, "life": duration, "duration": duration})
	# 事件始终记录：别人看不看特效由别人自己的开关决定，
	# 关掉本地特效不能让对局另一端一起变哑。
	_record_fx("tower", point, normal, strength, side, ball_index, tower_index)

# --- Visual-only feedback (#5 impact sparks, #14 fading callouts) -----------
# Neither touches damage, physics or the turn flow: they only read state that
# the simulation already produced.
# 这个闸门只决定"本地画不画"，不拦事件记录 —— 否则主机关掉特效，
# 同一桌其他人也会跟着看不到撞击反馈（跨玩家串味）。
func _fx_allowed() -> bool:
	return not SETTINGS.reduce_motion and SETTINGS.impact_fx_enabled

func _add_contact_fx(kind: String, point: Vector2, normal: Vector2, strength: float, side: int) -> void:
	# One contact is sampled up to four times per frame (physics substeps).
	# Collapse copies that land within 8px of a fresh effect of the same kind.
	for existing in contact_fx:
		if str(existing.kind) == kind \
				and float(existing.duration) - float(existing.life) < 0.06 \
				and (existing.p as Vector2).distance_to(point) < 8.0:
			return
	var s: float = clampf(strength, 0.05, 1.0)
	var duration: float = 0.12 + s * 0.16
	if contact_fx.size() >= 24:
		contact_fx.pop_front()
	contact_fx.append({"kind": kind, "p": point, "n": normal, "side": side, "strength": s, "life": duration, "duration": duration})
	_record_fx(kind, point, normal, s, side, -1, -1)

# 主机把特效事件记进快照队列。键名压短：快照 20Hz，这个数组每小时都跟着发。
func _record_fx(kind: String, point: Vector2, normal: Vector2, strength: float, side: int, ball_index: int, tower_index: int) -> void:
	# 客户端只是重放者，不能把收到的事件再记一遍，否则会自己喂自己。
	if network_client_mode: return
	fx_seq += 1
	fx_events.append({
		"id": fx_seq, "t": Time.get_ticks_msec(), "k": kind,
		"p": [snappedf(point.x, 0.1), snappedf(point.y, 0.1)],
		"n": [snappedf(normal.x, 0.01), snappedf(normal.y, 0.01)],
		"s": snappedf(strength, 0.01), "sd": side,
		"b": ball_index, "tw": tower_index,
	})
	if fx_events.size() > FX_BUFFER:
		fx_events.remove_at(0)

# 客户端重放主机发来的撞击特效。life/duration 用同一套公式本地推，
# 不读主机的剩余寿命：两端帧率不同，照搬会让一边比另一边先消失。
func _apply_remote_fx(event: Dictionary) -> void:
	if not _fx_allowed(): return
	var p_raw: Variant = event.get("p", [])
	if not (p_raw is Array) or (p_raw as Array).size() != 2: return
	var point := Vector2(float((p_raw as Array)[0]), float((p_raw as Array)[1]))
	var normal := Vector2(0.0, -1.0)
	var n_raw: Variant = event.get("n", [])
	if n_raw is Array and (n_raw as Array).size() == 2:
		normal = Vector2(float((n_raw as Array)[0]), float((n_raw as Array)[1]))
	var strength := clampf(float(event.get("s", 0.3)), 0.05, 1.0)
	var side := int(event.get("sd", -1))
	var kind := str(event.get("k", "ball_ball"))
	if kind == "tower":
		var tower_life := 0.10 + strength * 0.10
		if tower_impacts.size() >= 12: tower_impacts.pop_front()
		tower_impacts.append({"ball": int(event.get("b", -1)), "tower": int(event.get("tw", -1)),
			"p": point, "n": normal, "side": side, "strength": strength,
			"life": tower_life, "duration": tower_life})
		return
	var life := 0.12 + strength * 0.16
	if contact_fx.size() >= 24: contact_fx.pop_front()
	contact_fx.append({"kind": kind, "p": point, "n": normal, "side": side, "strength": strength,
		"life": life, "duration": life})

func _update_contact_fx(dt: float) -> void:
	for i in range(contact_fx.size() - 1, -1, -1):
		var effect: Dictionary = contact_fx[i]
		effect.life -= dt
		if effect.life <= 0.0:
			contact_fx.remove_at(i)

func _draw_contact_fx() -> void:
	# 开关只管"画不画"：事件照常收发，另一端该看到的火花一点不少。
	if not _fx_allowed(): return
	for effect in contact_fx:
		var fade: float = clampf(float(effect.life) / maxf(float(effect.duration), 0.001), 0.0, 1.0)
		var point: Vector2 = effect.p
		var normal: Vector2 = effect.n
		var tangent := Vector2(-normal.y, normal.x)
		var strength: float = effect.strength
		match str(effect.kind):
			"ball_ball":
				var pale := Color(0.86, 0.93, 1.0, fade * 0.85)
				draw_circle(point, 1.5 + strength * 3.0, pale)
				for direction in [normal, -normal, tangent, -tangent]:
					draw_line(point, point + direction * (4.0 + strength * 9.0), pale, 1.0 + strength)
			"ball_player":
				var warm := Color(1.0, 0.84, 0.44, fade * 0.9)
				draw_circle(point, 2.0 + strength * 4.0, warm)
				draw_arc(point, 5.0 + strength * 10.0, 0.0, TAU, 24, Color(warm.r, warm.g, warm.b, fade * 0.55), 1.5 + strength)
			"player_tower":
				var hot := Color(1.0, 0.42, 0.46, fade * 0.85)
				draw_circle(point, 2.0 + strength * 5.0, hot)
				for direction in [-normal, (-normal + tangent * 0.8).normalized(), (-normal - tangent * 0.8).normalized()]:
					draw_line(point + direction * 2.0, point + direction * (5.0 + strength * 11.0), hot, 1.0 + strength)

func _add_floater(text: String, point: Vector2, color: Color, size_px := 28, seconds := 2.0) -> void:
	# Drawn by FormalHud: this node is rotated 180 degrees in the red-side view,
	# so text drawn in _draw() would come out upside down.
	if SETTINGS.reduce_motion:
		seconds = minf(seconds, 1.6)
	if formal_hud != null:
		formal_hud.show_floater(text, point, color, size_px, seconds)

func _side_damage_angle(t: Dictionary, radial: Vector2) -> bool:
	var local: Vector2 = radial * t.damage_mirror
	var angle: float = rad_to_deg(local.angle())
	return angle >= SIDE_DAMAGE_ARC_START_DEG - side_damage_tolerance_deg and angle <= SIDE_DAMAGE_ARC_END_DEG + side_damage_tolerance_deg

func _apply_tower_damage(b: Dictionary, tower_index: int, radial: Vector2, eligible: bool, speed: float) -> void:
	var t: Dictionary = towers[tower_index]
	if t.hp <= 0: return
	# 充能中的副塔很脆：敌方球或任何道具球碰一下，正在攒的技能立刻作废。
	# 自家球撞自己不打断，否则队友一弹就把自己的技能撞没了。
	if not bool(t.main) and tower_index < tower_skill.size():
		var charging: Dictionary = tower_skill[tower_index]
		if not str(charging.get("skill", "")).is_empty():
			var interrupt := true
			if b.kind == "player":
				interrupt = _team_of_slot(int(b.get("id", -1))) != int(t.side)
			if interrupt:
				var lost := _skill_label(str(charging["skill"]))
				charging["skill"] = ""
				charging["charge"] = 0
				_add_floater("%s被打断" % lost, t.p + Vector2(0.0, -t.r - 18.0), Color("ff8a7a"), 22, 1.6)
	var is_vampire: bool = b.kind == "vampire"
	# Fire and vampire orbs are consumed on any live-tower contact, before the
	# eligibility / angle / ownership gates decide what effect they apply.
	if b.kind == "fire" or is_vampire: b.alive = false
	var base_damage := clampi(roundi(10.0 * speed / FULL_DAMAGE_SPEED), 1, 10)
	if b.kind == "player":
		if not b.has("self_hit_latch"): b.self_hit_latch = {}
		if not b.self_hit_latch.has(tower_index):
			b.self_hit_latch[tower_index] = true
			b.hp = maxi(0, b.hp - base_damage)
			# Player ball hitting a tower: a distinct spark from a tool orb.
			_add_contact_fx("player_tower", t.p + radial * t.hit_r, -radial, float(base_damage) / 10.0, t.side)
			if b.hp == 0:
				_kill_player_ball(b)
				_add_floater("已阵亡", b.p + Vector2(0.0, -BALL_RADIUS - 22.0), Color("c9c2d6"), 24, 2)
	if not eligible: return
	if not t.main and not _side_damage_angle(t, radial): return
	if is_vampire:
		_apply_vampire_effect(b, t, tower_index, base_damage)
		return
	if not b.has("damage_latch"): b.damage_latch = {}
	if b.damage_latch.has(tower_index): return
	b.damage_latch[tower_index] = true
	var damage: int = (base_damage * 2 if b.kind == "fire" else base_damage) * TOWER_DAMAGE_SCALE
	# 副塔技能「双倍」：该队处于双倍窗口时，这一杆的塔伤害乘 2
	if int(team_double_shots[turn_manager.current_team()]) > 0:
		damage *= 2
	var dealt: int = mini(damage, t.hp)
	t.hp -= dealt
	_emit_sfx(MATCH_SFX.pick_tower_hit(str(b.kind), float(dealt)))
	last_hit = "SHOT %d: %s -%d HP (%d LEFT)" % [shot_number, "BLUE" if t.side == 0 else "RED", dealt, t.hp]
	print(last_hit)
	if t.hp == 0 and t.main:
		finished = true
		turn_manager.finish()
		winner_side = 0 if int(t.side) == 1 else 1
		result_text = "击破对方主塔，%s获胜" % ("蓝方" if winner_side == 0 else "红方")
		banner = result_text

func _apply_vampire_effect(b: Dictionary, t: Dictionary, tower_index: int, base_damage: int) -> void:
	var owner_side: int = int(b.get("owner_side", -1))
	if not b.has("damage_latch"): b.damage_latch = {}
	if b.damage_latch.has(tower_index): return
	b.damage_latch[tower_index] = true
	if owner_side < 0:
		# Unowned orb is already consumed, but has no team core to restore.
		return
	var dealt: int = 0
	if t.side != owner_side:
		dealt = mini(base_damage * TOWER_DAMAGE_SCALE, t.hp)
		t.hp -= dealt
		_emit_sfx(MATCH_SFX.pick_tower_hit(str(b.kind), float(dealt)))
		if t.hp == 0 and t.main:
			finished = true
			turn_manager.finish()
			winner_side = 0 if int(t.side) == 1 else 1
			result_text = "击破对方主塔，%s获胜" % ("蓝方" if winner_side == 0 else "红方")
			banner = result_text
	# Every owned vampire contact restores the owner's MAIN tower only,
	# whether the orb struck an own tower (main or side) or an enemy tower.
	# 吸血量与实际伤害同口径：打敌人吸 20，撞自己塔也补给 20（原来是固定 10）
	var restored: int = _heal_main_tower(owner_side, dealt if dealt > 0 else base_damage * TOWER_DAMAGE_SCALE)
	var owner_label: String = "BLUE" if owner_side == 0 else "RED"
	if dealt > 0:
		last_hit = "DRAIN: %s -%d HP / %s CORE +%d HP" % ["BLUE" if t.side == 0 else "RED", dealt, owner_label, restored]
	else:
		last_hit = "DRAIN: %s CORE +%d HP" % [owner_label, restored]
	print(last_hit)

func _heal_main_tower(side: int, amount: int) -> int:
	for tower in towers:
		if tower.side != side or not tower.main: continue
		var restored: int = mini(amount, TOWER_HP - int(tower.hp))
		tower.hp = int(tower.hp) + restored
		return restored
	return 0

func _damage_side_tower_wall_contact(b: Dictionary, point: Vector2, normal: Vector2, eligible: bool, speed: float) -> void:
	for tower_index in [0, 2, 3, 5]:
		var t: Dictionary = towers[tower_index]
		var radial: Vector2 = point - t.p
		if absf(radial.length() - t.hit_r) > 0.5: continue
		if radial.normalized().dot(normal) < 0.92: continue
		_apply_tower_damage(b, tower_index, radial.normalized(), eligible, speed)
		return

## 物理步进：一帧 4 个子步（dt/4），热路径分四段。
##
## 性能现状（本机 headless，7 球）：整步约 61µs。边界两段已网格化（原本 496µs），
## 剩下的成本主要来自下面四段里对 balls[i] 的 Dictionary 取值。
##
## 如果以后要切"并行数组"（bp/bv/br/... 取代 Array[Dictionary]），只需改这四段
## 加上 _resolve_boundary_overlap / _collide_field_walls 里的 balls[i].xxx 访问。
## 迁移清单、收益估算、验证项见 docs/物理热点与并行数组迁移清单.md。
##
## 热路径真正读写的字段只有这些：
##   p / v / r / alive / kind / hp / armed / impact / spin / spin_kick
##   owner_side（仅吸血球），self_hit_latch / damage_tower（球-塔去重）
func step(dt: float):
	var previous_positions: Array[Vector2] = []
	# ---- 段 1/4：球-洞 + 积分（含火球撞洞烧洞、吞噬特效；也是唯一推进 p 的地方）----
	for b in balls:
		previous_positions.append(b.p)
		if not b.alive: continue
		if b.has("self_hit_latch"):
			for idx in b.self_hit_latch.keys():
				if b.p.distance_to(towers[idx].p) > b.r + towers[idx].hit_r + 2: b.self_hit_latch.erase(idx)
		if b.has("damage_latch"):
			for tower_index in b.damage_latch.keys():
				var tower: Dictionary = towers[tower_index]
				if b.p.distance_to(tower.p) > b.r + tower.hit_r + 2.0: b.damage_latch.erase(tower_index)
		b.p += b.v * dt
		if not holes.is_empty():
			var from := previous_positions.back() as Vector2
			var burned := -1
			for hi in range(holes.size()):
				var h: Vector2 = holes[hi]
				var closest := from
				if not from.is_equal_approx(b.p): closest = Geometry2D.get_closest_point_to_segment(h, from, b.p)
				if closest.distance_to(h) > HOLE_RADIUS + b.r:
					continue
				# 火球是唯一能烧掉洞的东西：洞消失，火球也被烧尽
				if b.kind == "fire":
					burned = hi
					break
				# 不再弹"已被吞噬/已阵亡"这类文字，统一交给吞噬特效表现
				_spawn_hole_swallow(b.p, _ball_tint(b), b.r)
				_emit_sfx(MATCH_SFX.pick_swallow())
				if b.kind == "player":
					b.hp = 0
					_kill_player_ball(b)
					b.v = Vector2.ZERO
				else:
					# 道具球被吞：直接消失，不进读秒
					b.alive = false
					b.v = Vector2.ZERO
				break
			if burned >= 0:
				var burned_at: Vector2 = holes[burned]
				holes.remove_at(burned)
				_add_hole_break_fx(burned_at)
				# 洞被烧掉是独立事件，和"球被吞"是两种声音：这里是"穿过去了"。
				_emit_sfx(MATCH_SFX.pick_hole_burn())
				hole_cooldown_until = turn_manager.round_number + HOLE_BURN_COOLDOWN_ROUNDS
				b.alive = false
				b.v = Vector2.ZERO
		b.v *= exp(-drag * dt)
	# ---- 段 2/4：球-球（21 对 @7 球 / 36 对 @9 球，O(n²)）----
	for i in range(balls.size()):
		for j in range(i + 1, balls.size()):
			var a = balls[i]
			var b = balls[j]
			if not a.alive or not b.alive: continue
			var d: Vector2 = b.p - a.p
			var distance: float = d.length()
			if distance >= a.r + b.r: continue
			var n: Vector2 = d / distance if distance > 0.001 else Vector2.RIGHT
			var overlap: float = a.r + b.r - distance
			a.p -= n * overlap * 0.5
			b.p += n * overlap * 0.5
			var approach: float = (b.v - a.v).dot(n)
			if approach < 0:
				var tangent := Vector2(-n.y, n.x)
				var rel_tangent: float = (b.v - a.v).dot(tangent)
				var rel_normal: float = absf(approach)
				var graze: float = absf(rel_tangent) / maxf(rel_normal + absf(rel_tangent), 0.001)
				var spin_added: float = -rel_tangent / a.r * 0.5 * (0.5 + graze * 0.7)
				a.spin_kick = clampf(a.spin_kick + spin_added, -40.0, 40.0)
				b.spin_kick = clampf(b.spin_kick - spin_added, -40.0, 40.0)
				a.spin = clampf(a.spin + spin_added, -40.0, 40.0)
				b.spin = clampf(b.spin - spin_added, -40.0, 40.0)
				var impulse: Vector2 = -(1 + bounce) * approach * n * 0.5
				a.v -= impulse
				b.v += impulse
				if a.kind != "player": a.impact = maxf(a.impact, minf(-approach / 600.0, 1.0))
				if b.kind != "player": b.impact = maxf(b.impact, minf(-approach / 600.0, 1.0))
				var pair_kind := "ball_player" if (a.kind == "player" and b.kind == "player") else "ball_ball"
				_add_contact_fx(pair_kind, (a.p + b.p) * 0.5, n, -approach / 600.0, -1)
				_emit_sfx(MATCH_SFX.pick_ball_hit(-approach))
				a.armed = true
				b.armed = true
	# ---- 段 3/4：球-塔（道具球消耗、伤害结算、副塔技能打断）----
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		for tower_index in range(towers.size()):
			var t = towers[tower_index]
			if t.hp <= 0: continue
			var d: Vector2 = b.p - t.p
			var distance: float = d.length()
			var contact_radius: float = b.r + t.hit_r
			# 火球和吸血球都是消耗品：只要碰到活着的塔就消耗掉，不看扇形角度、
			# 不看是不是在往塔里飞。放到扇形门槛之前判定，否则贴着塔边擦过去会弹回来继续飞，
			# 看起来像"打塔上不消失/没打上塔"。
			if b.kind == "fire" or b.kind == "vampire":
				# 用整段位移做扫掠判定：只看当前点的话，掉帧时一帧位移 200px+
				# 会整颗跳过塔（不消耗、不掉血），黑洞每帧要画吸积盘，更容易卡出这种长帧。
				var orb_from: Vector2 = previous_positions[ball_index]
				var orb_closest := Geometry2D.get_closest_point_to_segment(t.p, orb_from, b.p)
				if orb_closest.distance_to(t.p) < contact_radius + 1.0:
					# 入射方向取"塔心指向最近点"，球已经穿进塔身时也稳定。
					var orb_radial: Vector2 = orb_closest - t.p
					if orb_radial.length() < 0.001:
						orb_radial = t.inward
					else:
						orb_radial = orb_radial.normalized()
					# 速度口径按球种分：火球任何角度撞塔都是满伤害（用速度大小，语义不变）；
					# 吸血球用径向速度大小，擦着塔边过的时候自然掉得少。
					var orb_speed: float = b.v.length() if b.kind == "fire" else absf(b.v.dot(orb_radial))
					_apply_tower_damage(b, tower_index, orb_radial, b.armed, orb_speed)
					if not b.alive: break
					continue
			var n := Vector2.ZERO
			# Test the path to the new position so a fast ball cannot cross the fan between samples.
			var from: Vector2 = previous_positions[ball_index] - t.p
			var travel: Vector2 = b.p - previous_positions[ball_index]
			var travel_squared: float = travel.length_squared()
			if from.length_squared() >= contact_radius * contact_radius and travel_squared > 0.0001:
				var along: float = from.dot(travel)
				var discriminant: float = along * along - travel_squared * (from.length_squared() - contact_radius * contact_radius)
				if discriminant >= 0.0:
					var hit_time: float = (-along - sqrt(discriminant)) / travel_squared
					if hit_time >= 0.0 and hit_time <= 1.0:
						n = (from + travel * hit_time).normalized()
			if n.dot(t.inward) < cos(t.fan_half):
				if distance >= contact_radius: continue
				n = d.normalized() if distance > 0.001 else t.inward
			if n.dot(t.inward) < cos(t.fan_half):
				continue
			var approach: float = b.v.dot(n)
			if approach >= 0:
				if distance < contact_radius: b.p = t.p + n * (contact_radius + 0.1)
				continue
			var correction: float = b.p.distance_to(t.p + n * (contact_radius + 0.1))
			b.p = t.p + n * (contact_radius + 0.1)
			_add_graze_spin(b, n, b.v)
			b.impact = maxf(b.impact, minf(-approach / 450.0, 1.0))
			b.v -= (1 + bounce) * approach * n
			_record_debug_contact("tower", ball_index, tower_index, t.p + n * t.hit_r, n, -approach, correction)
			_add_tower_impact(ball_index, tower_index, t.p + n * t.hit_r, n, -approach, t.side)
			_apply_tower_damage(b, tower_index, n, b.armed, -approach)
			if not b.alive: break
	# ---- 段 4/4：边界（网格索引，见 _sweep_boundary / _resolve_boundary_overlap）----
	_collide_field_walls(previous_positions, dt)
	if debug_collisions:
		for ball_index in range(balls.size()):
			var ball = balls[ball_index]
			if not ball.alive: continue
			for tower_index in range(towers.size()):
				var tower = towers[tower_index]
				var delta: Vector2 = ball.p - tower.p
				if delta.length() < ball.r + tower.r - 0.25:
					_record_debug_contact("outside fan", ball_index, tower_index, ball.p, delta.normalized(), ball.v.length(), 0.0)

func _sweep_boundary(origin: Vector2, travel: Vector2, radius: float) -> Dictionary:
	var best_time := 2.0
	var best := {}
	var travel_squared: float = travel.length_squared()
	if travel_squared < 0.000001: return best
	if bs_a.is_empty(): return best
	# 球这一步的扫掠胶囊包围盒：先按网格取候选段（通常十几段），再做精确数学。
	var reach_min_x: float = minf(origin.x, origin.x + travel.x) - radius
	var reach_min_y: float = minf(origin.y, origin.y + travel.y) - radius
	var reach_max_x: float = maxf(origin.x, origin.x + travel.x) + radius
	var reach_max_y: float = maxf(origin.y, origin.y + travel.y) + radius
	bs_epoch += 1
	var epoch := bs_epoch
	for cx in range(int(floor(reach_min_x / BOUNDARY_CELL)), int(floor(reach_max_x / BOUNDARY_CELL)) + 1):
		for cy in range(int(floor(reach_min_y / BOUNDARY_CELL)), int(floor(reach_max_y / BOUNDARY_CELL)) + 1):
			var cell: Variant = bs_grid.get(Vector2i(cx, cy))
			if cell == null: continue
			for candidate in (cell as Array):
				var segment_index: int = int(candidate)
				if bs_stamp[segment_index] == epoch: continue
				bs_stamp[segment_index] = epoch
				if bs_max[segment_index].x < reach_min_x or bs_min[segment_index].x > reach_max_x: continue
				if bs_max[segment_index].y < reach_min_y or bs_min[segment_index].y > reach_max_y: continue
				var a: Vector2 = bs_a[segment_index]
				var edge: Vector2 = bs_edge[segment_index]
				var length_squared: float = bs_len2[segment_index]
				var inward: Vector2 = bs_inward[segment_index]
				var velocity_normal: float = travel.dot(inward)
				if velocity_normal < -0.000001:
					var start_clearance: float = (origin - a).dot(inward)
					var time: float = (radius - start_clearance) / velocity_normal
					if time >= 0.0 and time <= 1.0 and time < best_time:
						var center: Vector2 = origin + travel * time
						var along: float = (center - a).dot(edge) / length_squared
						if along >= 0.0 and along <= 1.0:
							best_time = time
							best = {"time": time, "normal": inward, "point": a + edge * along, "segment": segment_index}
				# Swept endpoint circles close the join between neighboring segments.
				var relative: Vector2 = origin - a
				var half_b: float = relative.dot(travel)
				var discriminant: float = half_b * half_b - travel_squared * (relative.length_squared() - radius * radius)
				if discriminant < 0.0: continue
				var vertex_time: float = (-half_b - sqrt(discriminant)) / travel_squared
				if vertex_time < 0.0 or vertex_time > 1.0 or vertex_time >= best_time: continue
				var vertex_normal: Vector2 = (origin + travel * vertex_time - a).normalized()
				if travel.dot(vertex_normal) >= -0.000001: continue
				best_time = vertex_time
				best = {"time": vertex_time, "normal": vertex_normal, "point": a, "segment": segment_index}
	return best

func _resolve_boundary_overlap(ball: Dictionary, ball_index: int) -> void:
	# 只关心离球 r 以内的段：按网格取候选（通常 1~4 格），不再遍历整条 221 段的轮廓。
	var radius: float = ball.r
	for correction_pass in range(3):
		var closest_squared := INF
		var closest_point := Vector2.ZERO
		var closest_inward := Vector2.ZERO
		var point_now: Vector2 = ball.p
		bs_epoch += 1
		var epoch := bs_epoch
		for cx in range(int(floor((point_now.x - radius) / BOUNDARY_CELL)), int(floor((point_now.x + radius) / BOUNDARY_CELL)) + 1):
			for cy in range(int(floor((point_now.y - radius) / BOUNDARY_CELL)), int(floor((point_now.y + radius) / BOUNDARY_CELL)) + 1):
				var cell: Variant = bs_grid.get(Vector2i(cx, cy))
				if cell == null: continue
				for candidate in (cell as Array):
					var segment_index: int = int(candidate)
					if bs_stamp[segment_index] == epoch: continue
					bs_stamp[segment_index] = epoch
					var a: Vector2 = bs_a[segment_index]
					var edge: Vector2 = bs_edge[segment_index]
					var squared: float = bs_len2[segment_index]
					var along: float = clampf((point_now - a).dot(edge) / squared, 0.0, 1.0)
					var point: Vector2 = a + edge * along
					var distance_squared: float = point_now.distance_squared_to(point)
					if distance_squared < closest_squared:
						closest_squared = distance_squared
						closest_point = point
						closest_inward = bs_inward[segment_index]
		if closest_squared >= radius * radius: break
		var distance: float = sqrt(closest_squared)
		var normal: Vector2 = (ball.p - closest_point) / distance if distance > 0.0001 else closest_inward
		if normal.dot(closest_inward) < 0.0: normal = closest_inward
		var correction: float = radius + 0.05 - distance
		ball.p += normal * correction
		var approach: float = ball.v.dot(normal)
		if approach < 0.0:
			ball.v -= (1.0 + bounce) * approach * normal
			ball.impact = maxf(ball.impact, minf(-approach / 450.0, 1.0))

func _collide_field_walls(previous_positions: Array[Vector2] = [], dt: float = 0.0) -> void:
	if previous_positions.is_empty():
		for ball in balls: previous_positions.append(ball.p)
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		var position: Vector2 = previous_positions[ball_index]
		var travel: Vector2 = b.p - position
		for contact_index in range(4):
			var hit: Dictionary = _sweep_boundary(position, travel, b.r)
			if hit.is_empty():
				position += travel
				break
			var time: float = hit.time
			var normal: Vector2 = hit.normal
			position += travel * time + normal * 0.05
			var approach: float = b.v.dot(normal)
			if approach < 0.0:
				_add_graze_spin(b, normal, b.v)
				var eligible_before_wall: bool = b.armed
				b.v -= (1.0 + bounce) * approach * normal
				b.impact = maxf(b.impact, minf(-approach / 450.0, 1.0))
				_damage_side_tower_wall_contact(b, hit.point, normal, eligible_before_wall, -approach)
				_emit_sfx(MATCH_SFX.pick_wall_hit(-approach))
				# A player ball bouncing off a wall does not become tower-eligible.
				if b.kind != "player": b.armed = true
			_record_debug_contact("wall", ball_index, hit.segment, hit.point, normal, maxf(-approach, 0.0), 0.0)
			if not b.alive: break
			travel = b.v * dt * (1.0 - time)
		b.p = position
		_resolve_boundary_overlap(b, ball_index)

func _heal_team(side: int, amount: int) -> int:
	var target: Dictionary = {}
	for tower in towers:
		if tower.side != side or tower.hp <= 0 or tower.hp >= 100: continue
		if target.is_empty() or tower.hp < target.hp: target = tower
	if target.is_empty(): return 0
	var healed: int = mini(amount, 100 - target.hp)
	target.hp += healed
	return healed

# The arena artwork never changes. Painting it from the main _draw() rebuilt the
# same 540x810 + two mirror strips every frame (three texture commands), which is
# pure main-thread work on a weak phone. A child CanvasItem records those commands
# once; it inherits the exact same board transform, so pixels do not move.
class StaticArenaPainter extends Node2D:
	var artwork: Texture2D
	var main_rect: Rect2

	func _draw() -> void:
		draw_set_transform(Vector2(0.0, 75.0), 0.0, Vector2(1.0, -1.0))
		draw_texture_rect_region(artwork, Rect2(Vector2.ZERO, Vector2(540.0, 127.0)), Rect2(Vector2.ZERO, Vector2(1024.0, 150.0)))
		draw_set_transform(Vector2(0.0, 885.0), 0.0, Vector2(1.0, -1.0))
		draw_texture_rect_region(artwork, Rect2(Vector2(0.0, -127.0), Vector2(540.0, 127.0)), Rect2(Vector2(0.0, 1386.0), Vector2(1024.0, 150.0)))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_texture_rect(artwork, main_rect, false)

func _build_static_arena() -> void:
	for child in get_children():
		if child is StaticArenaPainter and child.has_meta("static_arena"):
			child.queue_free()
	var painter := StaticArenaPainter.new()
	painter.name = "StaticArenaPainter"
	painter.artwork = ARENA_ARTWORK
	painter.main_rect = SKIN_DRAW_RECT
	painter.z_index = -1
	painter.set_meta("static_arena", true)
	add_child(painter)

func _draw():
	var draw_started_us := Time.get_ticks_usec() if web_diag_enabled else 0
	# 黑洞视觉由 HoleVisual 负责（吸积盘 + 旋转环），玩法常量 HOLE_RADIUS 不变
	var hole_time := float(Time.get_ticks_msec()) / 1000.0
	for h in holes:
		HOLE_VISUAL.draw_hole(self, h, HOLE_RADIUS, hole_time)
	_draw_balls()
	# 吞噬特效画在球之后：球已经 alive=false 不画了，这里补上"被吸进去"的过程
	for fx in hole_swallows:
		HOLE_SWALLOW.draw_swallow(self, fx.hole, fx.entry, float(fx.r), HOLE_RADIUS,
			float(fx.age) / float(fx.dur), fx.tint)
	_draw_hole_breaks()
	# Player HP bars are drawn in FormalHud under the off-board portraits.
	_draw_tower_impacts()
	_draw_contact_fx()
	if aiming:
		# 手势线：按下点 → 真实指尖。方向与球端线正好相反（180°），
		# 而且始终忠实跟手，手停就稳。
		if aim_pointer_valid:
			_draw_gesture_aim_line(start, aim_pointer)
		# 球端线：从玩家球沿真实发射方向。中毒时只让这一条线晃。
		var ball_pull := pull
		if _is_stunned():
			ball_pull = ball_pull.rotated(_stun_wobble())
		if aim_slot >= 0 and aim_slot < balls.size() and balls[aim_slot].alive:
			_draw_ball_aim_line(balls[aim_slot].p, ball_pull)
	elif remote_aim_slot >= 0 and remote_aim_slot < balls.size() and balls[remote_aim_slot].alive:
		# 对手/观战只拿得到方向与力度，没有别人的指尖坐标，所以只画球端线。
		_draw_ball_aim_line(balls[remote_aim_slot].p, remote_aim_pull)
	if debug_mode and debug_collisions: _draw_collision_debug()
	if web_diag_enabled:
		diag_draw_us = Time.get_ticks_usec() - draw_started_us

# 球端线沿发射方向伸出，保留原有的 1.2 倍视觉延长（不影响真实力度与轨迹）。
func _draw_ball_aim_line(origin: Vector2, pull_vec: Vector2) -> void:
	if pull_vec.length() < 0.001: return
	_draw_aim_line(origin, origin + pull_vec * AIM_BEAM_EXTEND)


# 手势线：从按下点朝指尖。长度上限与球端引导线完全相同（AIM_MAX_LENGTH），
# 拖过上限后长度锁住、方向继续跟着手指转 —— 拖到屏幕边缘也不会拉成一条长线。
func _draw_gesture_aim_line(origin: Vector2, pointer: Vector2) -> void:
	var delta := pointer - origin
	var distance := delta.length()
	if distance < 0.001: return
	var length: float = minf(distance * AIM_BEAM_EXTEND, AIM_MAX_LENGTH)
	_draw_aim_line(origin, origin + delta / distance * length)


# 现有引导线的材质：青→金渐变 + 两端半圆收口。两条线共用同一外观，
# 线宽统一取旧版满蓄力最粗处的 7px，全长等宽，任何力度都不变。
# 端帽半径算在总长里：线身两端各让出一个半径，整条线恰好等于 from→to 的长度，
# 末端不会多鼓出一个圆点。
func _draw_aim_line(from: Vector2, to: Vector2) -> void:
	var delta := to - from
	var length := delta.length()
	if length < 0.001: return
	var direction := delta / length
	var cold := Color("62d7e6")
	var warm := Color("ffcf70")
	var cap_radius: float = AIM_LINE_WIDTH * 0.5
	var inset: float = minf(cap_radius, length * 0.5)
	var body_from: Vector2 = from + direction * inset
	var body_to: Vector2 = to - direction * inset
	var body_length: float = body_from.distance_to(body_to)
	if body_length > 0.01:
		var segment_length: float = body_length / float(AIM_LINE_SEGMENTS)
		var segment_start: Vector2 = body_from
		for i in range(AIM_LINE_SEGMENTS):
			# 取每段中点的色，渐变到头尾各留半段，青/金都吃得到
			var t := (float(i) + 0.5) / float(AIM_LINE_SEGMENTS)
			var segment_end: Vector2 = body_from + direction * (segment_length * float(i + 1))
			draw_line(segment_start, segment_end, cold.lerp(warm, t), AIM_LINE_WIDTH, true)
			segment_start = segment_end
	_draw_aim_cap(from, direction.angle() + PI, cap_radius, cold)
	_draw_aim_cap(to, direction.angle(), cap_radius, warm)


# 半圆端帽：直径等于线宽，弦贴着线身，过渡是平滑圆弧而不是一个鼓包。
func _draw_aim_cap(center: Vector2, facing: float, radius: float, color: Color) -> void:
	var points := PackedVector2Array()
	points.append(center)
	for i in range(AIM_CAP_SEGMENTS + 1):
		var a: float = facing - PI * 0.5 + PI * float(i) / float(AIM_CAP_SEGMENTS)
		points.append(center + Vector2.from_angle(a) * radius)
	draw_colored_polygon(points, color)

func _draw_collision_debug() -> void:
	var field_color := Color("b5ff89")
	for i in range(boundary_outline.size()):
		draw_line(boundary_outline[i], boundary_outline[(i + 1) % boundary_outline.size()], field_color, 2.0)
	for joint in boundary_joints: draw_circle(joint, 2.5, Color("ffdf75"))
	for tower_index in range(towers.size()):
		var t = towers[tower_index]
		if t.hp <= 0: continue
		var start_angle: float = t.inward.angle() - t.fan_half
		var end_angle: float = t.inward.angle() + t.fan_half
		draw_arc(t.p, t.r, 0.0, TAU, 48, Color("ffffff"), 1.5)
		draw_circle(t.p, 2.5, Color("ff765d"))
		draw_arc(t.p, t.hit_r, start_angle, end_angle, 18, Color("54e9ff"), 2.0)
		if not t.main:
			var mirror: Vector2 = t.damage_mirror
			for tolerance in [false, true]:
				var low: float = SIDE_DAMAGE_ARC_START_DEG - (side_damage_tolerance_deg if tolerance else 0.0)
				var high: float = SIDE_DAMAGE_ARC_END_DEG + (side_damage_tolerance_deg if tolerance else 0.0)
				var points := PackedVector2Array()
				for sample in range(33):
					var angle: float = deg_to_rad(lerpf(low, high, float(sample) / 32.0))
					points.append(t.p + Vector2.from_angle(angle) * mirror * (t.r + (7.0 if tolerance else 4.0)))
				draw_polyline(points, Color("ff638a") if tolerance else Color("ffd36d"), 2.0)
			for endpoint in [SIDE_DAMAGE_ARC_START_DEG, SIDE_DAMAGE_ARC_END_DEG]:
				var direction: Vector2 = Vector2.from_angle(deg_to_rad(endpoint)) * mirror
				draw_circle(t.p + direction * t.r, 2.5, Color("ff638a"))
		# Balls share BALL_RADIUS: this arc is the ball-center contact boundary.
		draw_arc(t.p, t.hit_r + BALL_RADIUS, start_angle, end_angle, 18, Color("ffcf70"), 2.0)
		for angle in [start_angle, end_angle]:
			draw_line(t.p, t.p + Vector2.from_angle(angle) * (t.hit_r + BALL_RADIUS), Color("ffcf70", 0.6), 1.0)
	for ball_index in range(balls.size()):
		var b = balls[ball_index]
		if not b.alive: continue
		draw_arc(b.p, b.r, 0.0, TAU, 40, Color("74ffad"), 1.5)
		var velocity: Vector2 = b.v
		if velocity.length_squared() > 1.0:
			var tip: Vector2 = b.p + velocity.normalized() * minf(velocity.length() * 0.045, 55.0)
			draw_line(b.p, tip, Color("ffe48c"), 2.0, true)
			draw_circle(tip, 2.5, Color("ffe48c"))
	for contact in debug_contacts:
		var point: Vector2 = contact.point
		var normal: Vector2 = contact.normal
		if contact.kind == "outside fan":
			draw_line(point + Vector2(-5, -5), point + Vector2(5, 5), Color("ff5aca"), 2.0)
			draw_line(point + Vector2(-5, 5), point + Vector2(5, -5), Color("ff5aca"), 2.0)
			continue
		var contact_color := Color("ffd26b") if contact.kind == "tower" else Color("b8a1ff")
		draw_circle(point, 3.0, contact_color)
		draw_line(point, point + normal * 22.0, contact_color, 2.0, true)

func _draw_arena():
	for edge_index in range(boundary_outline.size()):
		var a: Vector2 = boundary_outline[edge_index]
		var b: Vector2 = boundary_outline[(edge_index + 1) % boundary_outline.size()]
		draw_line(a, b, Color(0.74, 0.63, 1.0, 0.18), 2.0)

func _draw_tower_impacts() -> void:
	if not _fx_allowed(): return
	for effect in tower_impacts:
		var fade: float = clampf(effect.life / effect.duration, 0.0, 1.0)
		var strength: float = effect.strength
		var point: Vector2 = effect.p
		var normal: Vector2 = effect.n
		var tangent := Vector2(-normal.y, normal.x)
		var flash := Color("fff3d6")
		flash.a = fade * (0.35 + strength * 0.45)
		draw_circle(point, 1.5 + strength * 3.5, flash)
		var spark := Color("8de8ff") if effect.side == 0 else Color("ff9eae")
		spark.a = fade * (0.25 + strength * 0.50)
		for direction in [-normal, (-normal + tangent * 0.7).normalized(), (-normal - tangent * 0.7).normalized()]:
			draw_line(point + direction * 3.0, point + direction * (5.0 + strength * 9.0), spark, 1.0 + strength, true)

func _show_turn_halo(b: Dictionary) -> bool:
	var velocity: Vector2 = b.v
	return b.alive and b.kind == "player" and b.id == turn and not aiming and remote_aim_slot != b.id and not moving and not finished and velocity.is_zero_approx()

# 球的代表色：绘制和吞噬特效共用一份，避免两边漂移
func _ball_tint(b: Dictionary) -> Color:
	match str(b.kind):
		"fire":
			return Color("ff9b43")
		"iron":
			return Color("62d7e6")
		"vampire":
			return Color("e64ea8")
		"player":
			return Color("55c7ff") if int(b.get("id", 0)) < 2 else Color("ff6683")
	return Color("9aacbf")


# 吞噬特效入场。只有真的在洞边上才播，别的死法（打爆血量）不播。
func _spawn_hole_swallow(point: Vector2, tint: Color, ball_radius: float) -> bool:
	for h in holes:
		if point.distance_to(h) > HOLE_RADIUS + ball_radius + 14.0:
			continue
		hole_swallows.append({"hole": h, "entry": point, "r": ball_radius,
			"tint": tint, "age": 0.0, "dur": HOLE_SWALLOW_SECONDS})
		return true
	return false


func _add_hole_break_fx(point: Vector2) -> void:
	hole_breaks.append({"p": point, "age": 0.0, "dur": HOLE_BREAK_SECONDS})


func _update_hole_breaks(dt: float) -> void:
	if hole_breaks.is_empty():
		return
	var kept: Array = []
	for fx in hole_breaks:
		fx.age = float(fx.age) + dt
		if float(fx.age) < float(fx.dur):
			kept.append(fx)
	hole_breaks = kept


# 火环向外炸开 + 紫边塌缩 + 火星四散：读作"洞被烧穿了"
func _draw_hole_breaks() -> void:
	for fx in hole_breaks:
		var t := clampf(float(fx.age) / float(fx.dur), 0.0, 1.0)
		var pos: Vector2 = fx.p
		var ring := lerpf(HOLE_RADIUS * 0.35, HOLE_RADIUS * 2.1, t)
		draw_arc(pos, ring, 0.0, TAU, 36, Color(1.0, 0.61, 0.26, (1.0 - t) * 0.9), lerpf(3.2, 0.6, t), true)
		draw_arc(pos, lerpf(HOLE_RADIUS, 0.0, t), 0.0, TAU, 28, Color(0.64, 0.49, 0.92, (1.0 - t) * 0.55), 2.0, true)
		for i in range(8):
			var ang := TAU * float(i) / 8.0 + 0.4
			var dist := lerpf(HOLE_RADIUS * 0.5, HOLE_RADIUS * (1.6 + 0.5 * float(i % 3)), t)
			draw_circle(pos + Vector2.from_angle(ang) * dist, lerpf(2.6, 0.0, t),
				Color(1.0, 0.72, 0.38, (1.0 - t) * 0.95))


func _update_hole_swallows(dt: float) -> void:
	if hole_swallows.is_empty():
		return
	var kept: Array = []
	for fx in hole_swallows:
		fx.age = float(fx.age) + dt
		if float(fx.age) < float(fx.dur):
			kept.append(fx)
	hole_swallows = kept


func _draw_balls():
	for b in balls:
		if not b.alive: continue
		var c: Color = _ball_tint(b)
		var artwork: Texture2D = null
		if b.kind == "fire":
			artwork = FIRE_ARTWORK
		elif b.kind == "iron":
			artwork = IRON_ARTWORK
		elif b.kind == "vampire":
			artwork = VAMPIRE_ARTWORK
		if artwork != null:
			var art_size: float = b.r * 2.25
			if b.kind == "fire":
				var speed_ratio := clampf(b.v.length() / 500.0, 0.0, 1.0)
				if speed_ratio > 0.04:
					var trail_direction: Vector2 = b.v.normalized()
					for trail in range(3, 0, -1):
						var trail_pos: Vector2 = b.p - trail_direction * (b.r * 0.6 + float(trail) * b.r * 0.45)
						draw_circle(trail_pos, b.r * (0.55 - float(trail) * 0.1), Color(1.0, 0.30, 0.04, speed_ratio * (4.0 - float(trail)) * 0.085))
			var pulse: float = 1.0 + b.impact * 0.08
			draw_set_transform(b.p, b.angle, Vector2.ONE * pulse)
			draw_texture_rect(artwork, Rect2(Vector2.ONE * art_size * -0.5, Vector2.ONE * art_size), false)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		else:
			# Rotate the asymmetric highlights so tower contact is visible on player balls too.
			draw_set_transform(b.p, b.angle, Vector2.ONE * (1.0 + b.impact * 0.04))
			draw_circle(Vector2.ZERO, b.r + 1, c.darkened(0.55))
			draw_circle(Vector2.ZERO, b.r, c.darkened(0.06))
			draw_arc(Vector2.ZERO, b.r - 2, -PI * 0.88, PI * 0.65, 40, c.lightened(0.50), 2.0)
			draw_arc(Vector2.ZERO, b.r * 0.66, PI * 0.12, PI * 0.74, 28, c.darkened(0.35), 2.0)
			draw_circle(Vector2(-b.r * 0.32, -b.r * 0.34), max(3.0, b.r * 0.22), Color(1, 1, 1, 0.88))
			draw_circle(Vector2(b.r * 0.22, b.r * 0.30), max(2.0, b.r * 0.09), Color(1, 1, 1, 0.35))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if _show_turn_halo(b):
			# White and thicker: the ring is the only cue for whose turn it is.
			draw_arc(b.p, b.r + 2.0, 0, TAU, 56, Color(1.0, 1.0, 1.0, 0.95), 4.0)

func field_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color("0b2634")
	s.border_color = Color("27cfe0")
	s.set_border_width_all(3)
	s.set_corner_radius_all(18)
	return s
