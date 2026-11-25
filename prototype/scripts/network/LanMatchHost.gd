extends SceneTree

# Run: godot --headless --path prototype --script res://scripts/network/LanMatchHost.gd -- --port=9082
const MATCH_SCENE = preload("res://main.tscn")
const RoomSeats = preload("res://scripts/network/RoomSeats.gd")
const MAX_SEATS := 4
# 4 个参赛席 + 8 个观战席。观众只吃快照与聊天，不参与准备/开局/击球。
const MAX_MEMBERS := 12
const INTRO_MAX_CHARS := 40
const TURN_MANAGER = preload("res://scripts/game/TurnManager.gd")
# 两个人都掉线时，对局还能保留多久。必须覆盖"两台手机同时切后台 30 秒"这条验收线：
# 原来是 15 秒，两人一起切出去就会把正在打的一局判死。
const EMPTY_ROOM_TIMEOUT := 45.0
# 只有一个人掉线时，另一个人不该无限等下去（轮到他就是 3 秒跳过的垃圾回合）。
# 超过这个时间没回来，按弃权结束本局，双方回等待房。
const MATCH_ABANDON_TIMEOUT := 60.0
const ROOM_RECONNECT_GRACE := 90.0 # 等待房间阶段座位保留时长：切后台回微信再回来还赶得上
const OFFLINE_AIM_SECONDS := 3.0
# 心跳阈值分场景：对局中要快速感知掉线，等待房间要容忍手机切后台
# （浏览器在后台会冻结 requestAnimationFrame，Godot 主循环停摆，ping 发不出去，
#  25 秒阈值一定会误杀，表现就是"两端各自单人、互相看不到"）
# 对局中的心跳阈值必须大于"手机切后台 30 秒"这条验收线：浏览器在后台会冻住
# requestAnimationFrame，Godot 主循环停摆，ping 一个都发不出去。设 25 秒时，
# 切出去 30 秒回来一定被判掉线（座位还能靠 resume_key 抢回来，但那 15 秒里
# 对手看到的是"对局暂停"）。45 秒留够余量，真正关掉 App 的玩家仍会被清出去。
const HEARTBEAT_TIMEOUT_MATCH := 45.0
const HEARTBEAT_TIMEOUT_ROOM := 60.0
var peer: WebSocketMultiplayerPeer
var game: Node2D
# peer_id -> {role, slot, team, player_id, name, avatar, ready, joined_ms, last_seen, resume_key, music_chat_seen}
var players := {}
var pending_reconnects := {} # 断线玩家暂存：peer_id -> 同结构 + away_at
# 被拒绝的连接：peer_id -> 允许断开的时刻(ms)。error 包要等下一次 poll 才写出去，
# 紧接着 disconnect_peer 会把这条包一起丢掉，客户端就只看到"连接被关闭"。
var pending_rejects := {}
const SNAPSHOT_BACKLOG_BYTES := 4096
# 事件化同步之后，状态包只在"离散状态可能变了"的时候发，位置由轨迹帧负责：
# 静止期 1Hz（倒计时/心跳），球在动时 5Hz（塔血、吞噬、道具刷新要及时）。
# 旧方案是恒定 20Hz 全量快照，一局 20 分钟光同步就推掉十几 MB。
const SNAPSHOT_INTERVAL_MOVING := 200
const SNAPSHOT_INTERVAL_IDLE := 1000
# 一杆一轨迹：宿主按物理帧（60Hz）录制，每 100ms 推一段。
# 客户端攒够 LEAD 帧再起播，之后按 1.0 倍速连续播放，到达抖动只影响起播时刻。
const SHOT_TRAJECTORY = preload("res://scripts/network/ShotTrajectory.gd")
const TRAJ_CHUNK_MS := 100
const TRAJ_MAX_FRAMES_PER_PACKET := 12
const TRAJ_BACKFILL_FRAMES := 60
var next_snapshot_ms := 0
var snapshot_seq := 0
var traj_active := false
var traj_shot_id := 0
var traj_start_ms := 0
var traj_frames: Array = []
var traj_next_frame := 0
var traj_sent_upto := 0
var traj_next_chunk_ms := 0
var traj_last_physics := -1
var traj_ball_count := 0
var traj_bytes := 0
var traj_subscribers := 0
# 每房出口字节：?diag=1 判读"卡"是网络还是渲染的第四个指标。
# 由本进程自己统计，客户端无法伪造。
var bytes_out_total := 0
var bytes_out_window := 0
var bytes_out_rate := 0
var bytes_out_window_ms := 0
var bytes_log_ms := 0
var aim_seq := 0
var aim_owner_peer := 0
var aim_slot := -1
var aim_nonce := -1
var active := false
var session_id := "lan"
var music_key := PackedByteArray()
var music_feed_url := ""
var music_feed: WebSocketPeer
var music_feed_retry_ms := 0
var music_chat: Array = []
var room_mode := 0 # 0 = 双人(各控两球)，1 = 四人(各控一球)
var room_intro := ""
# 房主负责改模式与介绍。第一个进房的人成为房主；房主掉线宽限期过后转给最早加入的人。
var host_id := ""
# 大厅房间条需要的权威状态。由本进程 POST 给网关，客户端无法伪造。
var meta_url := ""
var meta_key := ""
var meta_request: HTTPRequest
var meta_busy := false
var meta_dirty := true
var meta_next_ms := 0

func _initialize() -> void:
	call_deferred("start")

func start() -> void:
	var music_secret := OS.get_environment("ARENA_INTERNAL_MUSIC_KEY")
	if music_secret.length() == 64 and music_secret.is_valid_hex_number(false):
		music_key = music_secret.hex_decode()
		music_feed_url = OS.get_environment("ARENA_INTERNAL_MUSIC_URL")
	meta_url = OS.get_environment("ARENA_ROOM_META_URL")
	meta_key = OS.get_environment("ARENA_ROOM_META_KEY")
	var port := 9082
	var bind_address := "*"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="): port = int(arg.trim_prefix("--port="))
		if arg.begins_with("--bind="): bind_address = arg.trim_prefix("--bind=")
		if arg.begins_with("--session="): session_id = arg.trim_prefix("--session=").left(32)
	game = MATCH_SCENE.instantiate()
	game.authoritative_host = true
	root.add_child(game)
	game.process_mode = Node.PROCESS_MODE_DISABLED
	peer = WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = 262144
	peer.outbound_buffer_size = 262144
	var error := peer.create_server(port, bind_address)
	if error != OK:
		push_error("WebSocket host failed on %d: %d" % [port, error])
		quit(1)
		return
	peer.peer_connected.connect(_peer_connected)
	peer.peer_disconnected.connect(_peer_disconnected)
	process_frame.connect(_tick)
	print("LAN_MATCH_HOST session=%s listening on %s:%d" % [session_id, bind_address, port])

func _send_to(id: int, message: Dictionary) -> Error:
	return _send_packet(id, JSON.stringify(message).to_utf8_buffer(), str(message.get("type", "?")))

func _send_packet(id: int, packet: PackedByteArray, kind: String) -> Error:
	peer.set_target_peer(id)
	var error := peer.put_packet(packet)
	if error != OK:
		push_warning("SEND_FAILED peer=%d type=%s error=%d" % [id, kind, error])
	else:
		bytes_out_total += packet.size()
		bytes_out_window += packet.size()
	return error

func _broadcast(message: Dictionary, except_id := 0, skip_backlog := false) -> void:
	var packet := JSON.stringify(message).to_utf8_buffer()
	var kind := str(message.get("type", "?"))
	for id in players.keys():
		if id == except_id or players[id].player_id.is_empty(): continue
		var socket: WebSocketPeer = peer.get_peer(id)
		if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN: continue
		if skip_backlog and socket.get_current_outbound_buffered_amount() >= SNAPSHOT_BACKLOG_BYTES: continue
		_send_packet(id, packet, kind)

func _send_snapshot_to(id: int) -> void:
	snapshot_seq += 1
	var state: Dictionary = game.make_network_snapshot()
	state["seq"] = snapshot_seq
	state["host_ms"] = Time.get_ticks_msec()
	state["paused"] = false
	_send_to(id, state)

func _broadcast_snapshot(force := false) -> void:
	var now := Time.get_ticks_msec()
	snapshot_seq += 1
	var state: Dictionary = game.make_network_snapshot()
	state["seq"] = snapshot_seq
	state["host_ms"] = now
	state["paused"] = false
	_broadcast(state, 0, not force)

# 二进制包（目前只有轨迹）单独走一条路：JSON 广播会把 PackedByteArray 也 stringify 一遍。
func _broadcast_packet(packet: PackedByteArray, kind: String) -> void:
	for id in players.keys():
		if players[id].player_id.is_empty(): continue
		var socket: WebSocketPeer = peer.get_peer(id)
		if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN: continue
		_send_packet(id, packet, kind)

# 轨迹是兜底通道：全员本地预演之后，正常一杆没有任何人需要它。
# 只有"这一杆没法在本地算"的客户端（中途加入、预演被拒、观战）才订阅，
# 每杆开始时订阅状态清零，避免一次失败就一直白推 20KB/杆。
func _broadcast_trajectory(packet: PackedByteArray) -> void:
	var subscribers := 0
	for id in players.keys():
		if not bool(players[id].get("traj_want", false)): continue
		var socket: WebSocketPeer = peer.get_peer(id)
		if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN: continue
		_send_packet(id, packet, "traj")
		subscribers += 1
	traj_subscribers = subscribers

# --- 一杆一轨迹 -----------------------------------------------------------
# 一杆开始时录第 0 帧（出杆前的静止状态），此后每个物理帧录一帧，杆停时收尾。
# 录的是"渲染要用的三样东西"：位置、自转角、生死；速度不下发——客户端不需要跑物理。
func _traj_reset() -> void:
	traj_active = false
	traj_frames.clear()
	traj_next_frame = 0
	traj_sent_upto = 0
	traj_bytes = 0
	traj_last_physics = -1

func _traj_begin() -> void:
	_traj_reset()
	traj_active = true
	traj_shot_id += 1
	traj_start_ms = Time.get_ticks_msec()
	traj_ball_count = game.balls.size()
	# 每杆重新决定谁需要兜底：上一杆预演失败的订阅不能顺延到这一杆。
	for occupant in players.values(): occupant["traj_want"] = false
	traj_subscribers = 0
	traj_last_physics = Engine.get_physics_frames()
	traj_next_chunk_ms = traj_start_ms + TRAJ_CHUNK_MS
	_traj_capture()

func _traj_capture() -> void:
	if not traj_active: return
	if game.balls.size() != traj_ball_count:
		# 球数在杆中途变了（不该发生）：这一杆作废，客户端会退回快照插值。
		print("TRAJ_ABORT shot=%d balls=%d/%d" % [traj_shot_id, game.balls.size(), traj_ball_count])
		_traj_reset()
		return
	var mask := 0
	var dead := 0
	var values := PackedFloat32Array()
	for i in range(traj_ball_count):
		var ball: Dictionary = game.balls[i]
		if not bool(ball.alive):
			dead |= 1 << i
			continue
		# 每颗活球每帧都发。做过"位置没变就不发"的省流版本，但轨迹是分段下发的，
		# 客户端在段首没有上一帧可以继承，静止球会瞬移到 (0,0)。
		# 一帧 9 球也才 58 字节，别为这点流量换一类定位不到的抖动。
		mask |= 1 << i
		values.append(float(ball.p.x))
		values.append(float(ball.p.y))
		values.append(float(ball.angle))
	traj_frames.append(SHOT_TRAJECTORY.encode_frame(mask, dead, values))
	traj_next_frame += 1

func _traj_frame_ms() -> float:
	return 1000.0 / maxf(1.0, float(Engine.get_physics_ticks_per_second()))

func _traj_packet(start: int, count: int) -> PackedByteArray:
	var packet := SHOT_TRAJECTORY.encode_header(traj_shot_id, traj_start_ms, start, count, traj_ball_count, _traj_frame_ms())
	for i in range(start, start + count):
		packet.append_array(traj_frames[i])
	return packet

func _traj_pump(now_ms: int) -> void:
	if not traj_active: return
	var physics_frame := Engine.get_physics_frames()
	if game.moving and physics_frame != traj_last_physics:
		# 一个空闲帧里可能追了多个物理帧（掉帧后的 catch-up）。只录当前这一帧：
		# 多录几张相同画面等于让客户端看到 16ms 的假静止。
		traj_last_physics = physics_frame
		_traj_capture()
	if now_ms < traj_next_chunk_ms: return
	traj_next_chunk_ms = now_ms + TRAJ_CHUNK_MS
	# 掉帧后可能积了不止一段：一次最多补 3 包，多余的下一帧继续。
	var guard := 0
	while traj_sent_upto < traj_frames.size() and guard < 3:
		guard += 1
		var count: int = mini(traj_frames.size() - traj_sent_upto, TRAJ_MAX_FRAMES_PER_PACKET)
		var packet := _traj_packet(traj_sent_upto, count)
		_broadcast_trajectory(packet)
		traj_sent_upto += count
		traj_bytes += packet.size() * maxi(traj_subscribers, 0)

func _traj_finish() -> void:
	if not traj_active: return
	var guard := 0
	while traj_sent_upto < traj_frames.size() and guard < 140:
		guard += 1
		var count: int = mini(traj_frames.size() - traj_sent_upto, TRAJ_MAX_FRAMES_PER_PACKET)
		var packet := _traj_packet(traj_sent_upto, count)
		_broadcast_packet(packet, "traj")
		traj_sent_upto += count
		traj_bytes += packet.size()
	print("TRAJ shot=%d frames=%d dur_ms=%d subs=%d bytes_total=%d" % [traj_shot_id,
		traj_frames.size(), int(float(traj_frames.size()) * _traj_frame_ms()), traj_subscribers, traj_bytes])
	_traj_reset()

# 中途加入 / 重连：只补最近 1 秒的帧，客户端会从最新一帧往回退 LEAD 帧起播，
# 不会把对手已经打完的半杆从头重放一遍。
func _send_trajectory_backfill(id: int) -> void:
	if not traj_active or traj_frames.is_empty(): return
	var start: int = maxi(0, traj_next_frame - TRAJ_BACKFILL_FRAMES)
	var guard := 0
	while start < traj_next_frame and guard < 8:
		guard += 1
		var count: int = mini(traj_next_frame - start, 30)
		_send_packet(id, _traj_packet(start, count), "traj")
		start += count

func _clear_aim(except_id := 0) -> void:
	if aim_owner_peer == 0: return
	aim_seq += 1
	_broadcast({"type": "aim", "kind": "cancel", "slot": aim_slot, "nonce": aim_nonce, "seq": aim_seq}, except_id)
	aim_owner_peer = 0

func _receive_aim(id: int, player: Dictionary, data: Dictionary) -> void:
	if not active or player.player_id.is_empty() or int(player.slot) < 0: return
	if data.get("player_id") != player.player_id: return
	var slot_value: Variant = data.get("slot")
	var nonce_value: Variant = data.get("nonce")
	var seq_value: Variant = data.get("seq")
	if not _is_number(slot_value) or not _is_number(nonce_value) or not _is_number(seq_value): return
	var slot := int(slot_value)
	var nonce := int(nonce_value)
	var seq := int(seq_value)
	if slot != slot_value or nonce != nonce_value or seq != seq_value or seq <= int(player.get("aim_seq", -1)): return
	if game.owner_of_slot(slot) != player.player_id or not game.can_control_current_ball(): return
	if not game.turn_manager.can_act(int(player.team), slot, nonce): return
	var kind: String = str(data.get("kind", ""))
	if kind == "cancel":
		player["aim_seq"] = seq
		if aim_owner_peer == id: _clear_aim(id)
		return
	if kind != "start" and (kind != "update" or aim_owner_peer != id or aim_nonce != nonce): return
	var direction: Variant = data.get("dir")
	var charge_value: Variant = data.get("charge")
	if not direction is Array or direction.size() != 2 or not _is_number(charge_value): return
	if not _is_number(direction[0]) or not _is_number(direction[1]): return
	var charge := float(charge_value)
	var vector := Vector2(float(direction[0]), float(direction[1]))
	if not vector.is_finite() or charge < 0.0 or charge > 1.0: return
	if charge > 0.0 and absf(vector.length_squared() - 1.0) > 0.01: return
	player["aim_seq"] = seq
	aim_owner_peer = id
	aim_slot = slot
	aim_nonce = nonce
	aim_seq += 1
	vector = vector.normalized() if charge > 0.0 else Vector2.ZERO
	_broadcast({"type": "aim", "kind": kind, "slot": slot, "nonce": nonce, "seq": aim_seq,
		"dir": [snappedf(vector.x, 0.0001), snappedf(vector.y, 0.0001)], "charge": snappedf(charge, 0.001)}, id)

func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

func _peer_connected(id: int) -> void:
	if players.size() >= MAX_MEMBERS:
		_reject_peer(id, "房间连接数已满")
		return
	# 入席前先当观众：hello 到达后再按剩余座位决定是参赛还是观战。
	# 这样"满座"永远不是拒绝连接的理由，只影响角色。
	players[id] = {"role": "spectator", "slot": -1, "team": -1, "player_id": "",
		"last_seen": Time.get_ticks_msec() / 1000.0}
	print("CONNECT peer=%d total=%d" % [id, players.size()])

func _reject_peer(id: int, reason: String) -> void:
	_send_to(id, {"type": "error", "reason": reason})
	players.erase(id)
	# 先排队再断开：延迟 300ms 关 socket，让 poll() 把 error 包真正发出去。
	# 立刻 disconnect_peer 的话这条包大概率丢在路上，客户端只会看到"连接被关闭"，
	# 于是按断线重连流程空转（等待房最长 88 秒）最后报"网络不稳定"，房满的原因看不到。
	pending_rejects[id] = Time.get_ticks_msec() + 300

func _flush_rejects(now_ms: int) -> void:
	if pending_rejects.is_empty(): return
	for id in pending_rejects.keys():
		if now_ms < int(pending_rejects[id]): continue
		pending_rejects.erase(id)
		if peer != null and peer.get_peer(id) != null: peer.disconnect_peer(id)

func _peer_disconnected(id: int) -> void:
	pending_rejects.erase(id)
	if not players.has(id): return
	var departed: Dictionary = players[id]
	players.erase(id)
	if departed.player_id.is_empty(): return
	# 对局中和等待房间走同一套座位保留，两边都能用 resume_key 拿回原 slot。
	# 差别只在宽限时长：对局中由 EMPTY_ROOM_TIMEOUT 控制，等待房间由 ROOM_RECONNECT_GRACE 控制。
	departed["away_at"] = Time.get_ticks_msec() / 1000.0
	pending_reconnects[id] = departed
	if aim_owner_peer == id: _clear_aim()
	if active:
		_limit_offline_turn()
		_broadcast_snapshot(true)
		print("AWAY peer=%d slot=%d" % [id, int(departed.slot)])
	else:
		# 等待房间阶段：保留座位与 ready 状态，不重置其他人的准备。
		# 手机锁屏/切微信会让浏览器停掉主循环，25 秒心跳超时必然触发，座位不能当场释放。
		game.process_mode = Node.PROCESS_MODE_DISABLED
		print("AWAY peer=%d slot=%d (room, %ds grace)" % [id, int(departed.slot), int(ROOM_RECONNECT_GRACE)])
	_broadcast_room()

func _tick() -> void:
	if peer == null: return
	peer.poll()
	var now_ms := Time.get_ticks_msec()
	var now := float(now_ms) / 1000.0
	while peer.get_available_packet_count() > 0:
		var id: int = peer.get_packet_peer()
		var data: Variant = JSON.parse_string(peer.get_packet().get_string_from_utf8())
		if data is Dictionary and players.has(id):
			players[id]["last_seen"] = now
			_receive(id, data)

	_update_match(now_ms)
	_update_bytes_rate(now_ms)
	_flush_rejects(now_ms)
	_poll_music_chat(now_ms)
	_push_room_meta(now_ms)

# --- 大厅房间条：权威状态直推网关 -----------------------------------------
# 客户端只知道"连了几条 socket"，模式/阶段/座位/介绍只有这里知道。
# 走网关内网端口 + 每次进程启动时生成的一次性 key，客户端无法伪造房间状态。
func _update_bytes_rate(now_ms: int) -> void:
	if bytes_out_window_ms == 0:
		bytes_out_window_ms = now_ms
		return
	var elapsed := now_ms - bytes_out_window_ms
	if elapsed < 1000: return
	bytes_out_rate = int(float(bytes_out_window) * 1000.0 / float(elapsed))
	bytes_out_window = 0
	bytes_out_window_ms = now_ms
	# 每 10 秒一条，供 journalctl 判读"卡在网络还是渲染"。只在这里打，不刷屏。
	if now_ms - bytes_log_ms >= 10000:
		bytes_log_ms = now_ms
		print("NET_RATE in_flight=%d bytes/s=%d total=%d" % [players.size(), bytes_out_rate, bytes_out_total])

func _meta_payload() -> Dictionary:
	var seated := 0
	var spectators := 0
	for occupant in players.values():
		if occupant.player_id.is_empty(): continue
		if int(occupant.slot) >= 0: seated += 1
		else: spectators += 1
	# 掉线宽限内的座位仍然被保留，新来的人坐不进去：大厅必须按"已占用"算，
	# 否则会写着「可入座」，点进去却只能观战。
	for away in pending_reconnects.values():
		if int(away.slot) >= 0: seated += 1
		else: spectators += 1
	return {"mode": room_mode, "phase": "playing" if active else "waiting",
		"seats": seated, "spectators": spectators, "intro": room_intro,
		"capacity": 2 if room_mode == 0 else 4,
		"bytes_out": bytes_out_total, "bytes_rate": bytes_out_rate}

func _push_room_meta(now_ms: int) -> void:
	if meta_url.is_empty() or meta_key.is_empty(): return
	if not meta_dirty or now_ms < meta_next_ms: return
	if meta_busy:
		meta_next_ms = now_ms + 500
		return
	meta_dirty = false
	meta_busy = true
	meta_next_ms = now_ms + 400
	if meta_request == null:
		meta_request = HTTPRequest.new()
		meta_request.timeout = 4.0
		root.add_child(meta_request)
		meta_request.request_completed.connect(_on_meta_finished)
	var headers := PackedStringArray(["Content-Type: application/json", "X-Arena-Meta-Key: " + meta_key])
	var error := meta_request.request(meta_url, headers, HTTPClient.METHOD_POST, JSON.stringify(_meta_payload()))
	if error != OK:
		meta_busy = false
		meta_dirty = true
		meta_next_ms = now_ms + 2000

func _on_meta_finished(_result: int, _code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	meta_busy = false

func _poll_music_chat(now_ms: int) -> void:
	if music_feed_url.is_empty(): return
	if music_feed == null:
		if now_ms < music_feed_retry_ms: return
		music_feed_retry_ms = now_ms + 1000
		var feed := WebSocketPeer.new()
		feed.handshake_headers = PackedStringArray(["Authorization: Bearer " + music_key.hex_encode()])
		if feed.connect_to_url(music_feed_url) != OK: return
		music_feed = feed
	music_feed.poll()
	if music_feed.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		music_feed = null
		return
	if music_feed.get_available_packet_count() == 0: return
	while music_feed.get_available_packet_count() > 0:
		var records: Variant = JSON.parse_string(music_feed.get_packet().get_string_from_utf8())
		if records is Array: music_chat = records
	for id in players.keys():
		_send_music_chat(id, players[id])

func _send_music_chat(id: int, player: Dictionary) -> void:
	if music_chat.is_empty() or player.player_id.is_empty(): return
	var socket := peer.get_peer(id)
	if socket == null or socket.get_ready_state() != WebSocketPeer.STATE_OPEN: return
	var seen: Array = player.music_chat_seen
	for entry in music_chat:
		if seen.has(entry.id): continue
		if _send_to(id, {"type": "room_chat", "nickname": entry.nickname, "body": entry.body, "player_id": entry.player_id}) != OK:
			return
		seen.append(entry.id)
		if seen.size() > 20: seen.pop_front()

func _limit_offline_turn() -> void:
	if not active or game.moving or game.finished or pending_reconnects.is_empty(): return
	var owner: String = game.owner_of_slot(game.turn)
	for away in pending_reconnects.values():
		if away.player_id == owner:
			game.timer = minf(game.timer, OFFLINE_AIM_SECONDS)
			return

func _update_match(now_ms: int) -> void:
	var now := float(now_ms) / 1000.0
	if aim_owner_peer != 0 and (game.finished or game.moving or game.turn_manager.turn_nonce != aim_nonce):
		_clear_aim()
	_limit_offline_turn()
	if active and not pending_reconnects.is_empty() and players.values().all(func(p): return p.player_id.is_empty()):
		var latest_loss := 0.0
		for away in pending_reconnects.values(): latest_loss = maxf(latest_loss, float(away.away_at))
		if now - latest_loss >= EMPTY_ROOM_TIMEOUT:
			active = false
			game.process_mode = Node.PROCESS_MODE_DISABLED
			pending_reconnects.clear()
			_traj_reset()
			meta_dirty = true
	# 单人掉线的对局要有出口：另一个人还连着的时候，上面那个"全员离线"判断永远不成立，
	# 对局会一直挂着，轮到缺席者就 3 秒跳过。超过宽限直接判本局结束。
	# 只对参赛席生效：观众掉线不该影响正在打的一局。
	if active and not pending_reconnects.is_empty():
		var abandoned := false
		for away in pending_reconnects.values():
			if int(away.slot) < 0: continue
			if now - float(away.away_at) >= MATCH_ABANDON_TIMEOUT: abandoned = true
		if abandoned:
			print("MATCH_ABANDONED pending=%d" % pending_reconnects.size())
			_broadcast({"type": "opponent_left", "reason": "对手长时间未回来，本局结束"})
			active = false
			game.process_mode = Node.PROCESS_MODE_DISABLED
			pending_reconnects.clear()
			_traj_reset()
			for player in players.values(): player["ready"] = false
			_broadcast_room()
	# 等待房间阶段：宽限到期才真正释放座位（对局中走上面的 EMPTY_ROOM_TIMEOUT）
	if not active and not pending_reconnects.is_empty():
		var released := false
		for away_id in pending_reconnects.keys():
			var away: Dictionary = pending_reconnects[away_id]
			if now - float(away.away_at) < ROOM_RECONNECT_GRACE: continue
			pending_reconnects.erase(away_id)
			released = true
			print("LEFT peer=%d slot=%d (grace expired)" % [away_id, int(away.slot)])
		if released:
			if _member_count() == 0:
				_reset_room_settings()
			else:
				_ensure_host()
			_broadcast_room()
	# 心跳超时：客户端每 2 秒 ping。对局中 45 秒，等待房间 60 秒。
	var heartbeat_limit := HEARTBEAT_TIMEOUT_MATCH if active else HEARTBEAT_TIMEOUT_ROOM
	for pid in players.keys():
		var seen := float(players[pid].last_seen)
		if now - seen > heartbeat_limit:
			print("TIMEOUT peer=%d" % pid)
			_peer_disconnected(pid)
			if peer != null: peer.disconnect_peer(pid)

	if not active: return
	# 一杆的结束边沿：先把剩余轨迹帧推完，再补一份 rest 状态。
	# rest 里 moving=false，客户端会等回放播到最后一帧才放开输入——
	# 否则球还在滚、读秒已经开始，手一抖就点到下一杆。
	if traj_active and not game.moving:
		_traj_finish()
		_broadcast_snapshot(true)
		next_snapshot_ms = now_ms + SNAPSHOT_INTERVAL_IDLE
	if traj_active:
		_traj_pump(now_ms)
	# 状态包节奏跟着"球在不在动"变。上一段静止期可能已经把下次发送排到 1 秒后，
	# 出杆瞬间必须把截止时间拉回来，否则这一杆前半秒的塔血/吞噬要等到 1 秒后才到。
	var snapshot_interval := SNAPSHOT_INTERVAL_MOVING if game.moving else SNAPSHOT_INTERVAL_IDLE
	if next_snapshot_ms > now_ms + snapshot_interval:
		next_snapshot_ms = now_ms + snapshot_interval
	if now_ms >= next_snapshot_ms or game.finished:
		if now_ms >= next_snapshot_ms:
			next_snapshot_ms = now_ms + snapshot_interval
		_broadcast_snapshot(game.finished)
		if game.finished:
			pending_reconnects.clear()
			active = false
			game.process_mode = Node.PROCESS_MODE_DISABLED
			for player in players.values(): player["ready"] = false
			_broadcast_room()

func _receive_hello(id: int, data: Dictionary) -> void:
	var player: Dictionary = players[id]
	if not player.player_id.is_empty(): return
	var identity := str(data.get("player_id", "")).left(80)
	if identity.is_empty(): return
	var resume_key := str(data.get("resume_key", ""))
	if resume_key.length() != 32 or not resume_key.is_valid_hex_number(false): resume_key = ""
	var saved: Dictionary = {}
	for other in players.keys():
		if players[other].player_id != identity: continue
		# 同一 resume_key 视为同一个客户端换了条 socket（切后台、断网重连），
		# 等待房间阶段也允许顶替，否则回来只会被"该玩家已在房间中"挡在门外。
		if resume_key.is_empty() or players[other].resume_key != resume_key:
			_reject_peer(id, "该玩家已在房间中")
			return
		# The previous socket can look connected until its heartbeat expires.
		saved = players[other]
		players.erase(other)
		if aim_owner_peer == other: _clear_aim()
		if peer != null: peer.disconnect_peer(other)
		break
	if saved.is_empty():
		for away_id in pending_reconnects.keys():
			var away: Dictionary = pending_reconnects[away_id]
			if away.player_id != identity or resume_key.is_empty() or away.resume_key != resume_key: continue
			saved = away
			pending_reconnects.erase(away_id)
			break
	var resumed := not saved.is_empty()
	# 房间彻底空了（宽限期已过）再进人，就是一张新桌：模式和介绍回到默认。
	# 还有待重连成员时不能清，否则回来的人会掉进另一个房间设定。
	if not resumed and _member_count() == 0:
		_reset_room_settings()
	var slot := int(saved.get("slot", -1))
	if not resumed:
		slot = RoomSeats.auto_slot(room_mode, _seat_members())
		if slot < 0 and not pending_reconnects.is_empty():
			# 手机反复刷新会堆出 ghost：页面重载后 resume_key 若没落盘成功，
			# 旧身份就一直占着槽位到宽限期结束，把真人挡在"房间已满"外面。真人优先。
			var victim_id := 0
			var victim_at := 0.0
			for away_id in pending_reconnects.keys():
				var away: Dictionary = pending_reconnects[away_id]
				if int(away.slot) < 0: continue
				if victim_id == 0 or float(away.away_at) < victim_at:
					victim_id = away_id
					victim_at = float(away.away_at)
			if victim_id != 0:
				var victim_slot := int(pending_reconnects[victim_id].slot)
				pending_reconnects.erase(victim_id)
				print("EVICT peer=%d slot=%d (no free slot)" % [victim_id, victim_slot])
				slot = RoomSeats.auto_slot(room_mode, _seat_members())
		# 座位满了不再是拒绝理由：自动成为观众，仍能看到对局、聊天、听歌。
		# 这一条同时修掉了旧版"双人桌第 3 人被踢回大厅"的死路。
	else:
		# 存档里的座位可能已经不属于当前模式（离线期间切了双人/四人）：
		# 与其让人坐在一个界面上看不见的槽位里，不如明确降为观众。
		if slot >= 0 and not RoomSeats.is_active_seat(room_mode, slot):
			slot = -1
	var role := "player" if slot >= 0 else "spectator"
	var joined_ms := int(saved.get("joined_ms", Time.get_ticks_msec()))
	player.merge({"player_id": identity, "resume_key": resume_key, "role": role, "slot": slot,
		"team": RoomSeats.team_of_slot(slot), "ready": bool(saved.get("ready", false)) if role == "player" else false,
		"name": str(data.get("name", "玩家")).left(24), "joined_ms": joined_ms,
		"avatar": str(data.get("avatar", "")).left(60000), "music_chat_seen": saved.get("music_chat_seen", [])}, true)
	if host_id.is_empty(): host_id = identity
	_send_to(id, {"type": "welcome", "team": player.team, "slot": slot, "role": role, "mode": room_mode,
		"session": session_id, "resumed": resumed, "host": host_id, "intro": room_intro,
		"phase": "playing" if active else "waiting"})
	_send_music_ticket(id, player)
	if active:
		# 对局中进来的（重连的老队员或新观众）都要补一条 start 才会切到棋盘，
		# 然后立刻给一帧快照 + 杆中途的轨迹尾巴，避免空白等下一个 50ms 周期。
		_send_to(id, {"type": "start", "players": _roster(), "mode": room_mode,
			"host": host_id, "intro": room_intro, "phase": "playing"})
		game.process_mode = Node.PROCESS_MODE_INHERIT
		# 中途进来的先订这一杆的兜底轨迹（他没法从杆前开始预演），下一杆再参与预演。
		player["traj_want"] = true
		_broadcast_snapshot(true)
		_send_trajectory_backfill(id)
	print("%s peer=%d slot=%d role=%s" % ["RECONNECT" if resumed else "HELLO", id, slot, role])
	_broadcast_room()
	_send_music_chat(id, player)

func _send_music_ticket(id: int, player: Dictionary) -> void:
	if music_key.is_empty(): return
	var transport := peer.get_peer(id)
	if transport == null: return
	var request_url := transport.get_requested_url()
	var marker := request_url.find("/arena-music/")
	if marker < 0: return
	var connection := request_url.substr(marker + "/arena-music/".length())
	if connection.length() != 48 or not connection.is_valid_hex_number(false): return
	var body := JSON.stringify({"connection": connection, "player": player.player_id, "name": player.name}).to_utf8_buffer()
	var signature := Crypto.new().hmac_digest(HashingContext.HASH_SHA256, music_key, body)
	_send_to(id, {"type": "music_ticket", "ticket": body.hex_encode() + "." + signature.hex_encode()})

func _receive(id: int, data: Dictionary) -> void:
	var player: Dictionary = players[id]
	match str(data.get("type", "")):
		"ping":
			if not player.player_id.is_empty():
				_send_to(id, {"type": "pong", "sent_at": data.get("sent_at", 0), "host_ms": Time.get_ticks_msec()})
				_send_music_chat(id, player)
		"hello": _receive_hello(id, data)
		"resync":
			# 客户端发现自己状态过期（被拒、重连、切后台回来）时主动要一份权威快照。
			# 只回给请求者，不广播，避免一个人抖动惊动整桌。
			# 杆中途重连还要补最近一秒轨迹，否则他要等到下一杆才看得见球在动。
			if not player.player_id.is_empty():
				_send_snapshot_to(id)
				_send_trajectory_backfill(id)
		"mode":
			# 只有房主能改模式；对局进行中不允许改。
			if active or player.player_id.is_empty(): return
			if player.player_id != host_id:
				_send_to(id, {"type": "action_denied", "reason": "只有房主可以修改模式"})
				return
			var new_mode := int(data.get("mode", -1))
			if new_mode != 0 and new_mode != 1: return
			if new_mode == room_mode: return
			room_mode = new_mode
			_apply_mode_seats()
			for occupant in players.values(): occupant["ready"] = false
			# 断线待重连的人也要清，否则他回来时带着旧的 ready 状态，开局条件会错位
			for away in pending_reconnects.values(): away["ready"] = false
			_broadcast_room()
			print("MODE -> %d" % room_mode)
		"seat":
			if player.player_id.is_empty(): return
			if active:
				_send_to(id, {"type": "action_denied", "reason": "对局进行中不能换座位"})
				return
			var target_value: Variant = data.get("slot")
			if not _is_number(target_value): return
			var target := int(target_value)
			if target != target_value: return
			var result := RoomSeats.claim(room_mode, _seat_members(), player.player_id, target)
			if not bool(result.get("ok", false)):
				_send_to(id, {"type": "seat_denied", "reason": str(result.get("reason", "这个位置不可用"))})
				return
			_apply_member_slot(player, target)
			player["ready"] = false
			print("SEAT peer=%d slot=%d" % [id, target])
			_broadcast_room()
		"spectate":
			if player.player_id.is_empty() or int(player.slot) < 0: return
			if active:
				_send_to(id, {"type": "action_denied", "reason": "对局进行中不能退出参赛席"})
				return
			_apply_member_slot(player, -1)
			player["ready"] = false
			print("SPECTATE peer=%d" % id)
			_broadcast_room()
		"leave_match":
			# 主动退出对局（顶部菜单第二项）。观众没有参赛席，只把他送回准备房，
			# 绝不因为观战者退出就停掉别人的对局。
			if player.player_id.is_empty(): return
			if int(player.slot) < 0:
				_send_to(id, {"type": "match_ended", "reason": "你正在观战，已回到准备房"})
				_broadcast_room()
				return
			if not active:
				_send_to(id, {"type": "match_ended", "reason": "本局已结束"})
				_broadcast_room()
				return
			print("LEAVE_MATCH peer=%d slot=%d" % [id, int(player.slot)])
			_end_match_for_room("%s 退出了对局，本局结束" % str(player.get("name", "玩家")))
		"intro":
			if player.player_id.is_empty(): return
			if player.player_id != host_id:
				_send_to(id, {"type": "action_denied", "reason": "只有房主可以修改房间介绍"})
				return
			room_intro = str(data.get("text", "")).strip_edges().left(INTRO_MAX_CHARS)
			print("INTRO len=%d" % room_intro.length())
			_broadcast_room()
		"ready":
			# 观众没有参赛席，准备/开局/击球都与他无关。
			if player.player_id.is_empty() or int(player.slot) < 0: return
			player.ready = bool(data.get("ready", false))
			print("READY peer=%d slot=%d value=%s" % [id, int(player.slot), str(player.ready)])
			_broadcast_room()
			var needed: int = 2 if room_mode == 0 else 4
			if not active:
				var seated := _seated_roster()
				if seated.size() == needed and seated.all(func(occupant): return bool(occupant.ready)): _start_match()
		"traj_want":
			# 这一杆本地算不了（中途加入 / 预演被拒 / 观战）：订阅兜底轨迹。
			if not player.player_id.is_empty():
				player["traj_want"] = true
				_send_trajectory_backfill(id)
		"aim": _receive_aim(id, player, data)
		"room_chat":
			# 等待房间临时聊天：只做长度/身份校验后广播，不落库、不进对局
			if player.player_id.is_empty(): return
			var body := str(data.get("body", "")).strip_edges()
			if body.is_empty() or body.length() > 80: return
			_broadcast({"type": "room_chat", "nickname": str(player.get("name", "玩家")),
				"body": body, "player_id": player.player_id})
		"chat_media":
			# 对局/房间内的图片与动图：只传附件 ID，字节永远走 HTTPS，不占对局同步带宽。
			# 发送者由连接决定，客户端自称的身份一律不采信。
			if player.player_id.is_empty(): return
			var att := str(data.get("att", "")).strip_edges()
			if att.length() < 16 or att.length() > 64: return
			var mime := str(data.get("mime", "")).strip_edges()
			if not (mime in ["image/jpeg", "image/png", "image/gif"]): return
			_broadcast({"type": "chat_media", "att": att, "mime": mime,
				"nickname": str(player.get("name", "玩家")), "player_id": player.player_id})
		"shot":
			if player.player_id.is_empty() or not active: return
			# 座位失效（重连后宽限期已过、或一直是旁观）必须明确告知，
			# 否则客户端只会看到"一直未确认"，玩家不知道自己已经没有座位。
			if int(player.slot) < 0:
				_send_to(id, {"type": "shot_rejected", "reason": "no_seat",
					"turn": game.turn + 1, "nonce": game.turn_manager.turn_nonce})
				return
			if str(data.get("player_id", "")) != player.player_id: return
			var coords: Variant = data.get("pull")
			if not coords is Array or coords.size() != 2 or not _is_number(coords[0]) or not _is_number(coords[1]): return
			var shot_slot := int(data.get("slot", -1))
			# 只有该球槽的归属玩家才能发射（四人模式防止同队代打）
			if game.owner_of_slot(shot_slot) != player.player_id:
				_send_to(id, {"type": "shot_rejected", "reason": "not_owner",
					"turn": game.turn + 1, "nonce": game.turn_manager.turn_nonce})
				return
			var shot_pull := Vector2(float(coords[0]), float(coords[1]))
			var ok: bool = game.request_shot(player.team, shot_slot, shot_pull, int(data.get("nonce", -1)))
			if ok:
				print("SHOT peer=%d team=%d slot=%d round=%d" % [id, player.team, shot_slot + 1, game.turn_manager.round_number])
				_clear_aim()
				# 出杆事件广播给其他人：他们收到就本地开跑，不必等 200ms 的轨迹回放。
				# 出杆方自己在松手那一帧就开始跑了，排除掉免得重复开球。
				# pull 发原值：三方（宿主/出杆方/其他人）必须用完全相同的输入，
				# 否则混沌放大后杆末又会跳（初值精度那次的教训）。
				_broadcast({"type": "shot_event", "player_id": player.player_id,
					"team": player.team, "slot": shot_slot,
					"pull": [shot_pull.x, shot_pull.y],
					"nonce": int(data.get("nonce", -1))}, id)
				# 第 0 帧必须在物理推进之前录：此刻所有球都还在出杆前的位置上。
				_traj_begin()
				_broadcast_snapshot(true)
			else:
				# nonce / 回合已经变了：客户端状态过期，直接补一份权威快照让它对齐，
				# 而不是让玩家反复出杆、反复被拒。
				_send_to(id, {"type": "shot_rejected", "reason": "stale_turn",
					"turn": game.turn + 1, "nonce": game.turn_manager.turn_nonce})
				_send_snapshot_to(id)

func _occupied_slots() -> Array:
	var occupied: Array = []
	for occupant in players.values():
		if occupant.player_id.is_empty(): continue
		if int(occupant.slot) >= 0: occupied.append(int(occupant.slot))
	# 等待重连的座位也算占用，否则新玩家会和老玩家抢同一个球槽
	for away in pending_reconnects.values():
		if int(away.slot) >= 0: occupied.append(int(away.slot))
	return occupied

# 供 RoomSeats 使用的成员快照：只带身份与当前座位，不含网络细节。
func _seat_members() -> Array:
	var members: Array = []
	for occupant in players.values():
		if occupant.player_id.is_empty(): continue
		members.append({"player_id": occupant.player_id, "slot": int(occupant.slot)})
	for away in pending_reconnects.values():
		members.append({"player_id": away.player_id, "slot": int(away.slot)})
	return members

func _member_count() -> int:
	var count := 0
	for occupant in players.values():
		if not occupant.player_id.is_empty(): count += 1
	count += pending_reconnects.size()
	return count

func _apply_member_slot(member: Dictionary, slot: int) -> void:
	member["slot"] = slot
	member["role"] = "player" if slot >= 0 else "spectator"
	member["team"] = RoomSeats.team_of_slot(slot)
	if slot < 0: member["ready"] = false

# 双人/四人切换时不动连接：尽量保留红蓝各一名原队员，多出来的转观战。
func _apply_mode_seats() -> void:
	var assignment := RoomSeats.seats_after_mode_change(_seat_members(), room_mode)
	for occupant in players.values():
		if occupant.player_id.is_empty(): continue
		_apply_member_slot(occupant, int(assignment.get(occupant.player_id, -1)))
	for away in pending_reconnects.values():
		_apply_member_slot(away, int(assignment.get(away.player_id, -1)))

func _reset_room_settings() -> void:
	room_mode = 0
	room_intro = ""
	host_id = ""

# 房主离开后把权限交给最早加入的参赛者（没有参赛者才交给观众），
# 避免房间永久无主，也避免一张还能开的桌被观众拿着模式开关。
func _ensure_host() -> void:
	if not host_id.is_empty():
		for occupant in players.values():
			if occupant.player_id == host_id: return
		for away in pending_reconnects.values():
			if away.player_id == host_id: return
	var best := {}
	for occupant in players.values():
		if occupant.player_id.is_empty() or int(occupant.slot) < 0: continue
		if best.is_empty() or int(occupant.get("joined_ms", 0)) < int(best.get("joined_ms", 0)):
			best = occupant
	if best.is_empty():
		for away in pending_reconnects.values():
			if int(away.slot) < 0: continue
			if best.is_empty() or int(away.get("joined_ms", 0)) < int(best.get("joined_ms", 0)):
				best = away
	if best.is_empty():
		for occupant in players.values():
			if occupant.player_id.is_empty(): continue
			if best.is_empty() or int(occupant.get("joined_ms", 0)) < int(best.get("joined_ms", 0)):
				best = occupant
	if best.is_empty():
		for away in pending_reconnects.values():
			if best.is_empty() or int(away.get("joined_ms", 0)) < int(best.get("joined_ms", 0)):
				best = away
	host_id = str(best.get("player_id", ""))
	if not host_id.is_empty(): print("HOST -> %s" % host_id.left(8))

func _roster() -> Array:
	var roster: Array = []
	for occupant in players.values():
		if occupant.player_id.is_empty(): continue
		roster.append({"player_id": occupant.player_id, "role": str(occupant.get("role", "spectator")),
			"team": int(occupant.team), "slot": int(occupant.slot), "ready": bool(occupant.get("ready", false)),
			"name": occupant.name, "avatar": occupant.avatar, "joined_ms": int(occupant.get("joined_ms", 0))})
	roster.sort_custom(func(a, b): return int(a.joined_ms) < int(b.joined_ms))
	return roster

func _seated_roster() -> Array:
	var seated: Array = []
	for occupant in _roster():
		if str(occupant.get("role", "")) == "player" and int(occupant.get("slot", -1)) >= 0:
			seated.append(occupant)
	return seated

func _broadcast_room() -> void:
	meta_dirty = true
	_broadcast({"type": "room", "players": _roster(), "mode": room_mode,
		"host": host_id, "intro": room_intro, "phase": "playing" if active else "waiting"})


# 参赛者主动退出对局：本局到此为止，所有人回同一房间的准备界面，座位全部保留。
# 不做"只抽走一个人、其余继续"：玩法层按球槽发回合（双人一人两球、四人一人一球），
# 半途空出一个参赛席还得改冻结的 PrototypeMatch 才能跳过，代价远大于收益。
# 这里复用"弃权判负"那套收尾（active=false + 停物理 + 清准备），
# 但不发 opponent_left：那条会让客户端直接断线回大厅，而我们要的是回房间。
func _end_match_for_room(reason: String) -> void:
	active = false
	game.process_mode = Node.PROCESS_MODE_DISABLED
	_traj_reset()
	for player in players.values(): player["ready"] = false
	_broadcast({"type": "match_ended", "reason": reason})
	_broadcast_room()
	print("MATCH_ENDED %s" % reason)

func _start_match() -> void:
	var seated := _seated_roster()
	game.set_match_mode(TURN_MANAGER.Mode.QUAD if room_mode == 1 else TURN_MANAGER.Mode.DUEL)
	game.reset_game()
	if room_mode == 1:
		# 四人：每个球槽一个独立玩家
		var owners := PackedStringArray(["", "", "", ""])
		for occupant in seated:
			var s := int(occupant.slot)
			if s >= 0 and s < 4: owners[s] = occupant.player_id
		game.set_slot_owners(owners)
	else:
		# 双人：蓝方两球同一人，红方两球同一人
		var blue_id := ""
		var red_id := ""
		for occupant in seated:
			if int(occupant.team) == 0 and blue_id.is_empty(): blue_id = occupant.player_id
			elif int(occupant.team) == 1 and red_id.is_empty(): red_id = occupant.player_id
		game.set_player_owners(blue_id, red_id)
	game.process_mode = Node.PROCESS_MODE_INHERIT
	active = true
	meta_dirty = true
	_traj_reset()
	next_snapshot_ms = Time.get_ticks_msec() + SNAPSHOT_INTERVAL_IDLE
	_broadcast({"type": "start", "players": _roster(), "mode": room_mode,
		"host": host_id, "intro": room_intro, "phase": "playing"})
	_broadcast_snapshot(true)
	print("START %s seated=%d" % ["2v2 quad-ball" if room_mode == 1 else "1V1 dual-ball", seated.size()])
