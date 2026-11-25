extends Node
## 撞击音效（v2 音效包，四段采样）。
##
## 音色分工按作者标注：
##   ball    —— 03 台球声：球撞球（含撞到火球/吸血球）、球撞墙、普通球撞塔
##   fire    —— 02 火焰声：火球撞塔**并造成伤害**时
##   vampire —— 01 滋滋声：吸血球撞塔**并造成伤害**时
##   hole    —— 04 闷响：球被黑洞吞掉
##
## 火球和吸血球的专用音只认"打到塔且真的掉了血"这一个条件。
## 玩家球撞到火球/吸血球、或它们互相碰撞，一律是普通台球声——
## 否则每杆都在响特效音，分不清是球球碰撞还是塔被打了。
##
## 力度分三档（轻 / 中 / 重），档位取自八音效那版的连续曲线，各取三点：
##   球    lerp(-10, +2, t)  →  -8 / -4 /  0
##   塔    lerp(-12, +2, d)  → -10 / -5 /  0
##   墙    lerp(-18, -6, t)  → -16 / -12 / -8
## 上限卡在 0 dB 而不是 +2：v2 四段的峰值都已归一化到 -1 dBFS，再往上会削波。

const SETTINGS = preload("res://scripts/data/SettingsStore.gd")
const STREAMS := {
	"ball": preload("res://assets/sfx/03_ball_hit.wav"),
	"fire": preload("res://assets/sfx/02_fire_tower.wav"),
	"vampire": preload("res://assets/sfx/01_vampire_sizzle.wav"),
	"hole": preload("res://assets/sfx/04_blackhole_absorb.wav"),
	"burn": preload("res://assets/sfx/05_hole_burn.wav"),
}

# 每个采样自己的电平修正。四段的峰值都在 -1 dBFS 附近，但平均电平差了 11 dB：
# 03 是 -19.0、02 是 -13.1、04 是 -15.4、01 是 -7.7。
# 不修正的话滋滋声会盖住一切、台球声几乎听不见。这里按"和最早那版球撞球等响"对齐。
# 三段特效音都被截短过（0.58 / 0.62 / 0.72 秒），截短会抬高平均电平，所以修正值跟着重算过。
const STREAM_TRIM_DB := {
	# 台球声换成用户实录的塑料麻将：0.22s、峰值 -1.5dB、平均 -21.5dB。
	# 它比上一版那个 0.08s 的极短 click 多了牌身的余音，同样的峰值会更响，
	# 所以取 -4.0（峰值档 -5.5dBFS、平均 -25.5dBFS），听感和上一版持平但更"实"。
	"ball": -4.0,
	"fire": -5.9,
	"vampire": -11.7,
	# 黑洞：0.26s 的 B5（低频提升 1.2x）。2026-11-24 23:50 用户确认要的就是这一版，
	# 之前试的 0.32s(C) 是他听错了。素材 `sfx_inbox/hole_cut/B5_026_low.wav`。
	# 实测平均 -12.7dB、峰值 -1.5dBFS；trim 按"所有采样输出平均锁定 -22.3dBFS"反算：
	#   trim = -20.3 - mean_db = -20.3 - (-12.7) = -7.6
	# 换任何采样都要照这个式子重算，否则同一档位会比别的响。
	"hole": -7.6,
	# 黑洞被火球烧掉：晶体谐波上扬 330→620Hz、0.38s，合成素材。
	# 2026-11-24 23:58 用户在 D/F 短版候选里选的 D1（sfx_inbox/hole_burn/D1_crystal_short.wav）。
	# 实测平均 -11.8dB，trim = -20.3 - (-11.8) = -8.5；pick 的基础值取 0.0，
	# 所以播放 -8.5dB —— 比吞噬(-9.6)响约 1dB，但仍低于火球撞塔满档(-5.9)。
	"burn": -8.5,
}

# 三档 dB（档位值，不含上面的 trim）
const BALL_STAGE_DB := [-8.0, -4.0, 0.0]
const TOWER_STAGE_DB := [-10.0, -5.0, 0.0]
const WALL_STAGE_DB := [-16.0, -12.0, -8.0]
# 三档的分界：接触速度归一化后 <0.34 轻、<0.67 中，其余重
const TIER_EDGE_LOW := 0.34
const TIER_EDGE_HIGH := 0.67

# 满力一杆的接触速度基准（和伤害公式同一个 600 px/s 口径）
const FULL_SPEED := 600.0
# 一次满力普通球打掉的血量，用作撞塔的满档基准
const TOWER_FULL_DAMAGE := 20.0

# 轻碰不出声：球贴着别的球慢慢滚，不该一直"嗒"。
const MIN_HIT_SPEED := 35.0
# 撞墙门槛更高：只有实打实的一下才响，擦墙滚过去静音。
const MIN_WALL_SPEED := 120.0

# 同一采样在这段时间内不重复触发。三段特效音都降到 0.72s 以内，
# 但滋滋声仍是里面最长的（0.58s），单独放宽到 400ms 免得同一杆里叠两层。
const COOLDOWN_MS := {
	"ball": 60,
	"fire": 60,
	"vampire": 400,
	"hole": 120,
	# 烧洞整局最多 3 次，冷却只用来吃掉同一帧的重复触发。
	"burn": 150,
}
const VOICE_COUNT := 6

var _voices: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _last_play_ms: Dictionary = {}
var _bus_ready := false
## 本地回环（单机模拟联机）里的隐藏权威实例只负责"把事件写进快照"，
## 出声统一交给屏幕上那个客户端。不静音的话同一击会响两遍、还带几十毫秒错位。
var muted := false


func _ready() -> void:
	# 播放器先建好，但**总线名留到第一次真正播放时再解析**。
	# Web 端引擎启动阶段 AudioServer 还没完全接上，那时 add_bus() 建出来的
	# 总线不会路由到 Master，表现就是"桌面有声、浏览器完全静音"。
	for i in range(VOICE_COUNT):
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		_voices.append(voice)


# 惰性初始化：第一次要出声时才建总线，并显式接到 Master。
# 万一 add_bus 失败，播放器保持默认的 Master，最坏只是丢了分组，不会静音。
func _ensure_bus() -> void:
	if _bus_ready: return
	_bus_ready = true
	# Web 上一个必踩的 Godot bug（4.3+，含 4.6/4.7）：只要 AudioServer 里有第二条总线，
	# AudioServer.add_bus() 在 JS 侧走 Bus.addAt(-1)，会把 JS 的总线数组打乱，
	# Master 的 send 被改到别的总线上，Bus.connect() 于是把 Master 与
	# AudioContext.destination 断开 —— 表现是 playing=true、音量正常、但整个游戏一点声音都没有。
	# 桌面完全不受影响，所以本地测永远发现不了。见 godotengine/godot#119026。
	# 结论：Web 上一条新总线都不要建，直接用 Master。
	if OS.has_feature("web"):
		print("MATCH_SFX_BUS web=master buses=%d" % AudioServer.bus_count)
		return
	var idx := AudioServer.get_bus_index("MatchSfx")
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, "MatchSfx")
	if idx >= 0:
		AudioServer.set_bus_send(idx, &"Master")
		for voice in _voices:
			voice.bus = &"MatchSfx"
		print("MATCH_SFX_BUS ok index=%d" % idx)
	else:
		print("MATCH_SFX_BUS fallback=Master")


static func _stage(t: float) -> int:
	if t < TIER_EDGE_LOW:
		return 0
	if t < TIER_EDGE_HIGH:
		return 1
	return 2


## 球撞球：不分球种，一律台球声。火球/吸血球的专用音只属于"打塔掉血"。
static func pick_ball_hit(speed: float) -> Dictionary:
	if speed < MIN_HIT_SPEED:
		return {}
	var stream := "ball"
	var t := clampf(speed / FULL_SPEED, 0.0, 1.0)
	var db: float = BALL_STAGE_DB[_stage(t)] + float(STREAM_TRIM_DB[stream])
	return {"name": stream, "db": db, "pitch": randf_range(0.97, 1.03)}


## 球撞塔。响度按实际伤害分三档，擦一下掉 2 血就压到最低档。
## damage <= 0 表示没造成伤害（比如吸血球撞自己塔是回血）：这时不出专用音，
## 只留普通的台球撞击声，音色不能替玩家编造"打到东西了"。
static func pick_tower_hit(kind: String, damage: float) -> Dictionary:
	if damage <= 0.0:
		# 契约就是"没伤害也要有一声普通台球撞击"，不能静默：
		# 吸血球撞自己塔只回血（dealt = 0）时，玩家要能听到球确实碰到了塔。
		return {"name": "ball", "db": float(BALL_STAGE_DB[0]) + float(STREAM_TRIM_DB["ball"]), "pitch": randf_range(0.97, 1.03)}
	var stream := "ball"
	if kind == "fire":
		stream = "fire"
	elif kind == "vampire":
		stream = "vampire"
	var t := clampf(damage / TOWER_FULL_DAMAGE, 0.0, 1.0)
	var db: float = TOWER_STAGE_DB[_stage(t)] + float(STREAM_TRIM_DB[stream])
	return {"name": stream, "db": db, "pitch": randf_range(0.97, 1.03)}


## 球撞边界墙。压得比球撞球更低，且只认实撞。
static func pick_wall_hit(speed: float) -> Dictionary:
	if speed < MIN_WALL_SPEED:
		return {}
	var t := clampf(speed / FULL_SPEED, 0.0, 1.0)
	var db: float = WALL_STAGE_DB[_stage(t)] + float(STREAM_TRIM_DB["ball"])
	return {"name": "ball", "db": db, "pitch": randf_range(0.95, 1.05)}


## 球被黑洞吞掉。一次性事件，不分档。
static func pick_swallow() -> Dictionary:
	return {"name": "hole", "db": -2.0 + float(STREAM_TRIM_DB["hole"]), "pitch": randf_range(0.98, 1.02)}


## 火球把黑洞烧掉：洞消失、火球也消失的一瞬间。
## 设计意图是"穿过去"而不是"炸开"，所以用上扬的晶体谐波，音高落在人耳最舒服的中频。
## 比吞噬响 1dB 左右：这是"洞没了"的信号，但要留在撞塔声之下。
static func pick_hole_burn() -> Dictionary:
	return {"name": "burn", "db": 0.0 + float(STREAM_TRIM_DB["burn"]), "pitch": randf_range(0.99, 1.01)}


## 诊断用：最近真正播出去的三条音效名（最新在前）。
## Web 上撞塔声和吞噬声常常只隔几十毫秒，人耳会以为是"播错了"。
## ?diag=1 角标里看这个就能确认到底是哪几个在叠。
var recent_plays: PackedStringArray = []


## 真正出声。冷却只作用在本地，不影响其他玩家听到的那一份。
func play(sound_name: String, volume_db: float, pitch: float) -> void:
	if muted:
		return
	# 右上三点菜单的"撞击音效"开关：本地即时生效，重放对端事件也走这里，
	# 所以一次判断就同时管住自己打的和别人打的。
	if not SETTINGS.impact_sfx_enabled:
		return
	if not STREAMS.has(sound_name) or _voices.is_empty():
		return
	_ensure_bus()
	var now := Time.get_ticks_msec()
	var cooldown: int = int(COOLDOWN_MS.get(sound_name, 60))
	if now - int(_last_play_ms.get(sound_name, -100000)) < cooldown:
		return
	_last_play_ms[sound_name] = now
	recent_plays.insert(0, sound_name)
	if recent_plays.size() > 3:
		recent_plays.resize(3)
	var voice := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	voice.stream = STREAMS[sound_name]
	voice.volume_db = volume_db
	voice.pitch_scale = clampf(pitch, 0.5, 2.0)
	voice.play()


## 换局时把冷却清掉，免得新一局第一下被上一局的冷却吃掉。
func reset_cooldowns() -> void:
	_last_play_ms.clear()

## 诊断用：当前有几个声道真的在播。
## ?diag=1 角标里 voices>0 却听不到声音，就说明播放器在跑但输出被断了（见 _ensure_bus）。
func active_voice_count() -> int:
	var count := 0
	for voice in _voices:
		if voice.playing: count += 1
	return count
