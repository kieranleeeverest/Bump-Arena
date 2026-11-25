extends SceneTree

# 合成多人压测：一次拉起 N 个客户端连同一个房间，验证"观战扇出"和座位认领。
# 不需要真人——4 人局和 8 人观战的成本全在这里量。
#
# 用法：
#   godot --headless --path prototype --script res://tools/load_test_clients.gd \
#     -- --url=ws://127.0.0.1:9182 --clients=8 --seconds=45
#
# 输出：每 5 秒一行 CLIENT_STAT，结束时一行 LOAD_SUMMARY（含每客户端收发字节）。
# 宿主侧配合看 NET_RATE（每 10 秒一条）和进程 CPU/RSS。

const LAN_CLIENT = preload("res://scripts/network/LanMatchClient.gd")

var clients: Array = []
var ready_sent: Array = []
var url := "ws://127.0.0.1:9182"
var total := 8
var seconds := 45
var started_ms := 0
var deadline_ms := 0
var next_report_ms := 0
var connected_count := 0
var room_updates := 0
var shots_seen := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="): url = arg.trim_prefix("--url=")
		if arg.begins_with("--clients="): total = int(arg.trim_prefix("--clients="))
		if arg.begins_with("--seconds="): seconds = int(arg.trim_prefix("--seconds="))
	call_deferred("start")

func start() -> void:
	started_ms = Time.get_ticks_msec()
	deadline_ms = started_ms + seconds * 1000
	next_report_ms = started_ms + 5000
	for i in range(total):
		var client: Node = LAN_CLIENT.new()
		root.add_child(client)
		ready_sent.append(false)
		client.player_id = "load_%02d" % i
		# 每个客户端一个独立身份，否则宿主会按"该玩家已在房间中"拒掉。
		client.assigned.connect(func(_team: int): connected_count += 1)
		client.room_updated.connect(_on_room_updated.bind(client, i))
		client.snapshot_received.connect(func(_state: Dictionary): pass)
		client.shot_event_received.connect(func(_state: Dictionary): shots_seen += 1)
		var error: Error = client.connect_to_room(url, "load_%02d" % i, "L%02d" % i)
		if error != OK:
			print("LOAD_CONNECT_FAIL idx=%d error=%d" % [i, error])
		clients.append(client)
	print("LOAD_START url=%s clients=%d seconds=%d" % [url, total, seconds])
	process_frame.connect(_tick)

func _on_room_updated(_players: Array, client: Node, index: int) -> void:
	room_updates += 1
	# 只有前两个会被自动分到座位；其余的会被当观战，发 ready 也不会开局。
	if index < 2 and not bool(ready_sent[index]):
		ready_sent[index] = true
		client.send_ready(true)

func _tick() -> void:
	var now := Time.get_ticks_msec()
	if now >= next_report_ms and now < deadline_ms:
		next_report_ms = now + 5000
		for i in range(clients.size()):
			var c: Node = clients[i]
			print("CLIENT_STAT t=%d idx=%d conn=%s role=%s slot=%d snap=%d bytes=%d pkts=%d traj=%d" % [
				int((now - started_ms) / 1000), i, str(c.connected),
				"player" if int(c.assigned_team) >= 0 else "spectator",
				int(c.assigned_slot), int(c.snapshot_count),
				int(c.bytes_in), int(c.packets_in), int(c.trajectory_bytes)])
	if now >= deadline_ms:
		var total_bytes := 0
		var total_packets := 0
		var seated := 0
		var spect := 0
		for i in range(clients.size()):
			var c: Node = clients[i]
			total_bytes += int(c.bytes_in)
			total_packets += int(c.packets_in)
			if int(c.assigned_team) >= 0: seated += 1
			else: spect += 1
		print("LOAD_SUMMARY clients=%d seated=%d spectator=%d room_updates=%d shots=%d recv_bytes=%d recv_pkts=%d per_client=%.0f" % [
			clients.size(), seated, spect, room_updates, shots_seen, total_bytes, total_packets,
			float(total_bytes) / maxf(1.0, float(clients.size()))])
		quit()
