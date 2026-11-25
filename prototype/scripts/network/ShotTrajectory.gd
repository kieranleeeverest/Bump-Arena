extends RefCounted

# 一杆的轨迹包（二进制）。
#
# 为什么不用 JSON：一杆 2–8 秒、按物理帧 60Hz、最多 9 颗球。坐标写成 JSON
# 数字每个要 5–7 个字符，比定点二进制大三倍以上；而这段数据每 100ms 发一次。
# 控制类消息（hello / room / snapshot / aim）仍然走 JSON，只有轨迹走裸字节：
# 客户端按首字节区分，'{' 是 JSON，MAGIC 是轨迹。
#
# 包头 17 字节（小端）：
#   0  u8   0x54 'T'         magic
#   1  u8   version
#   2  u32  shot_id          宿主侧自增；客户端靠它判断"这是新的一杆"
#   6  u32  shot_start_ms    帧 0 的宿主时钟（客户端换算特效延迟用）
#  10  u16  first_frame
#  12  u16  frame_count
#  14  u8   ball_count
#  15  u16  frame_centi_ms  每帧毫秒 ×100（60Hz = 1667）。物理帧率换了也不会播快播慢。
#
# 每帧：
#   0  u16  mask    bit i = 这一帧带第 i 颗球的数据（没带的沿用上一帧）
#   2  u16  dead    bit i = 第 i 颗球已死（吞洞/阵亡），不再参与渲染
#   4  ...         按位序每颗球 6 字节：u16 x*8, u16 y*8, u16 angle
#
# 位置定点 1/8 像素：设计空间 540×960，int16 上限 ±4095，够用且误差 0.06px。
# 角度 16 位覆盖 0..TAU，量化误差 0.0001 rad。

const MAGIC := 0x54
const VERSION := 2
const HEADER_SIZE := 17
# 物理帧固定 60Hz（Godot 默认 physics_ticks_per_second），帧号 × 这个值就是毫秒。
const FRAME_MS := 1000.0 / 60.0
const POS_SCALE := 8.0
const ANGLE_STEPS := 65536.0
const MAX_BALLS := 16

static func is_trajectory(packet: PackedByteArray) -> bool:
	return packet.size() >= HEADER_SIZE and packet[0] == MAGIC

static func encode_header(shot_id: int, start_ms: int, first: int, count: int, ball_count: int, frame_ms := FRAME_MS) -> PackedByteArray:
	var packet := PackedByteArray()
	packet.resize(HEADER_SIZE)
	packet.encode_u8(0, MAGIC)
	packet.encode_u8(1, VERSION)
	packet.encode_u32(2, shot_id & 0xFFFFFFFF)
	packet.encode_u32(6, start_ms & 0xFFFFFFFF)
	packet.encode_u16(10, first & 0xFFFF)
	packet.encode_u16(12, count & 0xFFFF)
	packet.encode_u8(14, ball_count & 0xFF)
	packet.encode_u16(15, clampi(roundi(frame_ms * 100.0), 100, 2000))
	return packet

# values 是扁平的 [x, y, angle] 三元组，只包含 mask 置位的球，顺序与位序一致。
static func encode_frame(mask: int, dead: int, values: PackedFloat32Array) -> PackedByteArray:
	var ball_records := int(values.size() / 3.0)
	var packet := PackedByteArray()
	packet.resize(4 + ball_records * 6)
	packet.encode_u16(0, mask & 0xFFFF)
	packet.encode_u16(2, dead & 0xFFFF)
	var offset := 4
	var index := 0
	while index + 2 < values.size():
		packet.encode_u16(offset, _to_u16(roundi(values[index] * POS_SCALE)))
		packet.encode_u16(offset + 2, _to_u16(roundi(values[index + 1] * POS_SCALE)))
		packet.encode_u16(offset + 4, _to_u16(roundi(fposmod(values[index + 2], TAU) / TAU * ANGLE_STEPS)) & 0xFFFF)
		offset += 6
		index += 3
	return packet

static func _to_u16(value: int) -> int:
	return value & 0xFFFF

static func _from_u16(value: int) -> int:
	return value - 65536 if value >= 32768 else value

# 解出一段（可能只是整杆的一部分）轨迹帧。
# 返回 {} 表示包不可用；调用方必须把它当成"这一杆没收到"，退回快照插值。
static func decode(packet: PackedByteArray) -> Dictionary:
	if packet.size() < HEADER_SIZE: return {}
	if packet.decode_u8(0) != MAGIC: return {}
	if packet.decode_u8(1) != VERSION: return {}
	var ball_count := packet.decode_u8(14)
	if ball_count <= 0 or ball_count > MAX_BALLS: return {}
	var first := packet.decode_u16(10)
	var count := packet.decode_u16(12)
	if count == 0: return {}
	var prev_pos := PackedVector2Array()
	var prev_ang := PackedFloat32Array()
	prev_pos.resize(ball_count)
	prev_ang.resize(ball_count)
	var frames: Array = []
	var offset := HEADER_SIZE
	for i in range(count):
		if offset + 4 > packet.size(): break
		var mask := packet.decode_u16(offset)
		var dead := packet.decode_u16(offset + 2)
		offset += 4
		var pos := prev_pos.duplicate()
		var angles := prev_ang.duplicate()
		var truncated := false
		for ball_index in range(ball_count):
			if (mask & (1 << ball_index)) == 0: continue
			if offset + 6 > packet.size():
				truncated = true
				break
			pos[ball_index] = Vector2(
				float(_from_u16(packet.decode_u16(offset))) / POS_SCALE,
				float(_from_u16(packet.decode_u16(offset + 2))) / POS_SCALE)
			angles[ball_index] = float(packet.decode_u16(offset + 4)) / ANGLE_STEPS * TAU
			offset += 6
		if truncated: break
		prev_pos = pos
		prev_ang = angles
		frames.append({"k": first + i, "pos": pos, "ang": angles, "dead": dead})
	if frames.is_empty(): return {}
	var frame_ms := float(packet.decode_u16(15)) / 100.0
	if frame_ms < 5.0 or frame_ms > 250.0: frame_ms = FRAME_MS
	return {"shot_id": packet.decode_u32(2), "start_ms": packet.decode_u32(6),
		"first": first, "count": frames.size(), "ball_count": ball_count, "frame_ms": frame_ms,
		"bytes": packet.size(), "frames": frames}
