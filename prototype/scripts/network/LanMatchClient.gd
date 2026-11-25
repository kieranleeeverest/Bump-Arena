extends Node

const SHOT_TRAJECTORY = preload("res://scripts/network/ShotTrajectory.gd")

signal assigned(team: int)
signal mode_changed(mode: int)
signal room_updated(players: Array)
# Full authoritative room state: players (with role/slot/team), mode, host,
# intro, phase. room_updated stays for the older tests and listeners.
signal room_state_received(state: Dictionary)
# Emitted when this connection's own role/seat/host flag changes.
signal self_changed(role: String, slot: int, is_host: bool)
signal action_denied(reason: String)
signal room_chat_received(state: Dictionary)
signal music_ticket_received(ticket: String)
signal chat_media_received(state: Dictionary)
signal match_started(players: Array)
# 宿主宣布本局结束（参赛者主动退出 / 缺席判负 / 正常打完）。客户端据此回准备房，
# 不靠"快照里 finished"猜：退出的那一局没有胜负，也不需要结算页。
signal match_ended(reason: String)
signal snapshot_received(state: Dictionary)
# 出杆事件（谁、哪个球、pull、nonce）：收到就本地开跑，不必等轨迹回放。
signal shot_event_received(state: Dictionary)
# 一杆的轨迹帧（二进制包解出来的整段画面）。位置不再靠 20Hz 快照"追时间"，
# 而是攒够一小段后按 1.0 倍速连续播放，链路抖动只影响起播时刻。
signal trajectory_received(state: Dictionary)
signal aim_state_received(state: Dictionary)
signal transport_lost
signal disconnected(reason: String)
signal reconnected()
signal reconnecting(attempt: int)
signal shot_rejected

var peer: WebSocketMultiplayerPeer
var player_id := ""
var display_name := ""
var avatar_base64 := ""
var assigned_team := -1
var assigned_slot := -1
var room_mode := 0
var role := "spectator" # "player" | "spectator"
var host_id := ""
var is_host := false
var room_intro := ""
var room_phase := "waiting" # "waiting" | "playing"
var connected := false
var transport_open := false
var in_match := false
var resume_key := ""
# 最近一次 welcome 是否拿回了原座位。客户端内部本来就用这个字段决定要不要
# 立刻收起"重连中"，但以前没有留下来，界面上分不清"回到原局"和"被当成新人塞进空位"。
var resumed := false
var handshake_headers := PackedStringArray()
var attempt_started_ms := 0
var last_packet_ms := 0
var url := ""
var session_id := ""
var latency_ms := -1
var last_error := ""
var last_shot_reject_reason := ""
var ping_elapsed := 2.0
var aim_seq := 0
var snapshot_seq := -1
var snapshot_hz := 0.0
var snapshot_host_ms := -1
var host_clock_offset_ms := 0
var best_rtt_ms := -1
var snapshot_count := 0
var snapshot_window_started_ms := 0
var trajectory_count := 0
var trajectory_frames := 0
var trajectory_hz := 0.0
var trajectory_bytes := 0
# 收包计数（压测用）：证明观战扇出是不是按连接数线性放大。
var bytes_in := 0
var packets_in := 0

func snapshot_age_ms() -> int:
	if best_rtt_ms < 0 or snapshot_host_ms < 0: return -1
	return maxi(0, Time.get_ticks_msec() - host_clock_offset_ms - snapshot_host_ms)
# 自动重连：手机切后台/锁屏时 WebSocket 常被系统掐断，几秒后又能连上。
# 断线不立刻通知 UI，先在宽限期内静默重连（与服务端 RECONNECT_GRACE 对齐）。
# 等待房间比开局更宽容：服务端给 90 秒座位保留，客户端 88 秒放弃，避免"服务端还留着座位、客户端已经退出"。
# 对局中 40 秒：要覆盖"整整 30 秒连不上"这条线（地铁/电梯/切飞行模式再回来），
# 同时留出余量且不越过服务端的兜底——双人都掉线时 EMPTY_ROOM_TIMEOUT=45 秒就判死，
# 单人掉线时 MATCH_ABANDON_TIMEOUT=60 秒判弃权，40 秒放弃都不会去接一个已经被收掉的局。
const RECONNECT_GRACE := 40.0
const ROOM_RECONNECT_GRACE := 88.0
const RECONNECT_INTERVAL := 1.5
const HANDSHAKE_TIMEOUT_MS := 5000
const SERVER_SILENCE_MS := 7500
# 手机切后台时浏览器会继续把包收进缓冲，回来那一帧可能堆了 600 多个快照（30 秒 × 20Hz）。
# 一帧全排空会在手机上卡出明显停顿；限流后 60fps 下每秒能处理 1400+ 个，远高于 20Hz 的产速，
# 0.5 秒内就能追平，不会长期落后。
const MAX_PACKETS_PER_FRAME := 24
# 重连凭据必须落盘：手机浏览器切后台常被系统回收，回来是重新加载页面，
# 内存里的 resume_key 没了就会被服务端当成新玩家，座位当场丢掉。
const RESUME_KEY_PATH := "user://arena_resume_key.txt"
var is_reconnecting := false
var reconnect_started_at := 0.0
var reconnect_elapsed := 0.0
var reconnect_next := 0.0
var reconnect_attempt := 0

func connect_to_room(server_url: String, identity: String, name: String, avatar_data := "", test_headers: PackedStringArray = PackedStringArray()) -> Error:
	url = server_url
	player_id = identity
	display_name = name
	avatar_base64 = avatar_data
	handshake_headers = test_headers
	_ensure_resume_key()
	return _open_transport()

func _ensure_resume_key() -> void:
	if not resume_key.is_empty(): return
	if FileAccess.file_exists(RESUME_KEY_PATH):
		var saved := FileAccess.get_file_as_string(RESUME_KEY_PATH).strip_edges()
		if saved.length() == 32 and saved.is_valid_hex_number(false): resume_key = saved
	if not resume_key.is_empty(): return
	resume_key = Crypto.new().generate_random_bytes(16).hex_encode()
	var file := FileAccess.open(RESUME_KEY_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(resume_key)
		file.close()

func _open_transport() -> Error:
	transport_open = false
	connected = false
	attempt_started_ms = Time.get_ticks_msec()
	peer = WebSocketMultiplayerPeer.new()
	if not handshake_headers.is_empty(): peer.handshake_headers = handshake_headers
	peer.inbound_buffer_size = 262144
	peer.outbound_buffer_size = 262144
	return peer.create_client(url)

func send_ready(value: bool) -> void:
	_send({"type": "ready", "ready": value})

func send_mode(mode: int) -> void:
	_send({"type": "mode", "mode": mode})

func send_seat(slot: int) -> bool:
	return connected and _send({"type": "seat", "slot": slot}) == OK

func send_spectate() -> bool:
	return connected and _send({"type": "spectate"}) == OK

# 主动退出对局。只对参赛席有意义；宿主收到后结束本局并把所有人送回准备房。
# 返回 false = 包没交给 socket，界面不能显示"正在退出"。
func send_leave_match() -> bool:
	return connected and _send({"type": "leave_match"}) == OK

func send_intro(text: String) -> bool:
	return connected and _send({"type": "intro", "text": text.left(40)}) == OK

# 图片/动图：只发附件 ID，字节已经通过 HTTPS 传到网关了
func send_chat_media(att: String, mime: String) -> bool:
	return connected and _send({"type": "chat_media", "att": att, "mime": mime}) == OK


func send_room_chat(body: String) -> bool:
	# 等待房间临时聊天：服务端只做长度校验并广播，不落库
	return connected and _send({"type": "room_chat", "body": body}) == OK

func send_aim_state(slot: int, nonce: int, kind: String, direction: Vector2, charge: float) -> void:
	aim_seq += 1
	_send({"type": "aim", "player_id": player_id, "slot": slot, "nonce": nonce, "kind": kind,
		"seq": aim_seq, "dir": [direction.x, direction.y], "charge": charge})

func send_resync() -> void:
	# 状态过期时主动要一份权威快照（宿主只回给请求者）。
	_send({"type": "resync"})

# 这一杆本地算不了（预演起不来 / 中途加入 / 观战）：订阅兜底轨迹。
# 宿主每杆开始时会把订阅状态清零，所以这是一次性的，不会长期吃流量。
func send_traj_want() -> bool:
	if not connected: return false
	return _send({"type": "traj_want"}) == OK

func send_shot(team: int, slot: int, shot_pull: Vector2, nonce: int) -> bool:
	if team != assigned_team: return false
	return _send({"type": "shot", "player_id": player_id, "slot": slot, "pull": [shot_pull.x, shot_pull.y], "nonce": nonce}) == OK

func _send(data: Dictionary) -> Error:
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_UNAVAILABLE
	peer.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	return peer.put_packet(JSON.stringify(data).to_utf8_buffer())

func _send_hello() -> void:
	_send({"type": "hello", "player_id": player_id, "name": display_name, "avatar": avatar_base64, "resume_key": resume_key})

func _process(delta: float) -> void:
	if peer == null: return
	peer.poll()
	var now := Time.get_ticks_msec()
	var window_ms := now - snapshot_window_started_ms
	if window_ms >= 1000:
		snapshot_hz = snapshot_count * 1000.0 / window_ms
		snapshot_count = 0
		trajectory_hz = trajectory_frames * 1000.0 / window_ms
		trajectory_frames = 0
		snapshot_window_started_ms = now
	var status := peer.get_connection_status()
	if status == MultiplayerPeer.CONNECTION_CONNECTED and not transport_open:
		transport_open = true
		_send_hello()
	var drained := 0
	while peer != null and peer.get_available_packet_count() > 0 and drained < MAX_PACKETS_PER_FRAME:
		drained += 1
		var packet := peer.get_packet()
		# 首字节区分包类型：'{' 是 JSON 控制包，'T' 是一杆的轨迹帧。
		bytes_in += packet.size()
		packets_in += 1
		if SHOT_TRAJECTORY.is_trajectory(packet):
			var trajectory := SHOT_TRAJECTORY.decode(packet)
			if not trajectory.is_empty():
				last_packet_ms = now
				trajectory_count += 1
				trajectory_frames += int(trajectory.get("count", 0))
				trajectory_bytes += packet.size()
				trajectory_received.emit(trajectory)
			continue
		var data: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if data is Dictionary:
			last_packet_ms = now
			_receive(data)
	if peer == null: return
	var attempt_failed := status == MultiplayerPeer.CONNECTION_DISCONNECTED
	if connected:
		ping_elapsed += delta
		if ping_elapsed >= 2.0:
			ping_elapsed = 0.0
			_send({"type": "ping", "sent_at": now})
		attempt_failed = attempt_failed or now - last_packet_ms >= SERVER_SILENCE_MS
	if not connected or is_reconnecting:
		attempt_failed = attempt_failed or now - attempt_started_ms >= HANDSHAKE_TIMEOUT_MS
	if attempt_failed and not is_reconnecting:
		is_reconnecting = true
		reconnect_started_at = now / 1000.0
		reconnect_next = 0.0
		transport_lost.emit()
		print("LAN_CLIENT_LOST session=%s" % session_id)
	if not is_reconnecting: return
	reconnect_elapsed = now / 1000.0 - reconnect_started_at
	if reconnect_elapsed >= (RECONNECT_GRACE if in_match else ROOM_RECONNECT_GRACE):
		_end_connection("与房间服务器断开连接（重连失败）")
	elif attempt_failed:
		connected = false
		if reconnect_elapsed >= reconnect_next: try_reconnect()

func try_reconnect() -> void:
	reconnect_next = reconnect_elapsed + RECONNECT_INTERVAL
	reconnect_attempt += 1
	reconnecting.emit(reconnect_attempt)
	peer.close()
	_open_transport()

func _confirm_reconnect() -> void:
	if not is_reconnecting: return
	is_reconnecting = false
	reconnect_attempt = 0
	last_error = ""
	reconnected.emit()

# The roster is the single source of truth for "who am I in this room".
# Seat moves and mode changes both arrive here before any other handler runs.
func _sync_self_from_roster(entries: Variant) -> void:
	if not entries is Array: return
	for entry in entries:
		if not entry is Dictionary: continue
		if str(entry.get("player_id", "")) != player_id: continue
		var next_role := str(entry.get("role", role))
		var next_slot := int(entry.get("slot", assigned_slot))
		var next_team := int(entry.get("team", assigned_team))
		if next_role == role and next_slot == assigned_slot and next_team == assigned_team: return
		role = next_role
		assigned_slot = next_slot
		assigned_team = next_team
		self_changed.emit(role, assigned_slot, is_host)
		return

func _end_connection(reason: String) -> void:
	if peer != null: peer.close()
	peer = null
	connected = false
	in_match = false
	is_reconnecting = false
	reconnect_attempt = 0
	last_error = reason
	disconnected.emit(last_error)

func _receive(data: Dictionary) -> void:
	match str(data.get("type", "")):
		"welcome":
			assigned_team = int(data.get("team", -1))
			assigned_slot = int(data.get("slot", -1))
			room_mode = int(data.get("mode", 0))
			session_id = str(data.get("session", ""))
			resumed = bool(data.get("resumed", false))
			role = str(data.get("role", "spectator"))
			host_id = str(data.get("host", ""))
			is_host = not host_id.is_empty() and host_id == player_id
			room_intro = str(data.get("intro", ""))
			room_phase = str(data.get("phase", "waiting"))
			connected = true
			ping_elapsed = 2.0
			best_rtt_ms = -1
			assigned.emit(assigned_team)
			self_changed.emit(role, assigned_slot, is_host)
			print("LAN_CLIENT_OPEN session=%s role=%s slot=%d" % [session_id, role, assigned_slot])
			if is_reconnecting and not bool(data.get("resumed", false)):
				if in_match:
					in_match = false
					is_reconnecting = false
					reconnect_attempt = 0
					last_error = "对局已结束，已重新加入房间"
					disconnected.emit(last_error)
				else:
					_confirm_reconnect()
		"pong":
			var sent := int(data.get("sent_at", 0))
			var now := Time.get_ticks_msec()
			latency_ms = maxi(0, now - sent)
			if data.has("host_ms") and (best_rtt_ms < 0 or latency_ms <= best_rtt_ms):
				best_rtt_ms = latency_ms
				host_clock_offset_ms = (now + sent) / 2 - int(data.host_ms)
		"room":
			room_mode = int(data.get("mode", room_mode))
			host_id = str(data.get("host", host_id))
			is_host = not host_id.is_empty() and host_id == player_id
			room_intro = str(data.get("intro", ""))
			room_phase = str(data.get("phase", "waiting"))
			_sync_self_from_roster(data.get("players", []))
			mode_changed.emit(room_mode)
			room_updated.emit(data.get("players", []))
			room_state_received.emit(data)
			# 服务端只给"已经入座"的玩家广播 room（见 _broadcast 里跳过空身份），
			# 收到就等于身份还在。重连时如果对局已经结束、没有 snapshot 可等，
			# 靠这条收尾，不然客户端会空等 13 秒再报"重连失败"。
			if is_reconnecting and connected: _confirm_reconnect()
		"room_chat": room_chat_received.emit(data)
		"music_ticket": music_ticket_received.emit(str(data.get("ticket", "")))
		"chat_media": chat_media_received.emit(data)
		"start":
			in_match = true
			room_mode = int(data.get("mode", room_mode))
			host_id = str(data.get("host", host_id))
			is_host = not host_id.is_empty() and host_id == player_id
			room_intro = str(data.get("intro", room_intro))
			room_phase = "playing"
			_sync_self_from_roster(data.get("players", []))
			match_started.emit(data.get("players", []))
		"action_denied":
			action_denied.emit(str(data.get("reason", "操作未生效")))
		"seat_denied":
			action_denied.emit(str(data.get("reason", "这个位置不可用")))
		"snapshot":
			snapshot_seq = int(data.get("seq", snapshot_seq + 1))
			snapshot_host_ms = int(data.get("host_ms", -1))
			snapshot_count += 1
			snapshot_received.emit(data)
			if bool(data.get("finished", false)): in_match = false
			if connected: _confirm_reconnect()
		"aim": aim_state_received.emit(data)
		"shot_event":
			# 别人出杆：交给对局层决定能不能本地预演（状态不对时它会安静地放弃，
			# 由随后的轨迹回放兜底）。
			shot_event_received.emit(data)
		"match_ended":
			in_match = false
			room_phase = "waiting"
			match_ended.emit(str(data.get("reason", "本局已结束")))
		"opponent_left":
			in_match = false
			last_error = str(data.get("reason", "对手已断开"))
			disconnected.emit(last_error)
		"error":
			_end_connection(str(data.get("reason", "连接失败")))
		"shot_rejected":
			# reason: no_seat（座位失效）/ not_owner（球槽不归你）/ stale_turn（回合或 nonce 过期）
			last_shot_reject_reason = str(data.get("reason", "rejected"))
			last_error = "发射请求被服务器拒绝"
			shot_rejected.emit()
