extends RefCounted

# UI-only settings. Static state, no autoload, no project.godot change.
const SETTINGS_PATH := "user://settings.cfg"

static var bgm_enabled := true
static var room_music_volume := 35
static var room_music_muted := false
static var reduce_motion := false
# 对局内两个独立开关（右上三点菜单）。跟"降低动态效果"分开：
# 那个是全局无障碍选项，这两个是玩家这一刻想不想看/听撞击反馈。
static var impact_fx_enabled := true
static var impact_sfx_enabled := true
# 本机渲染帧率上限：开 = 30，关 = 60（默认）。只影响 Engine.max_fps，
# 不动物理步进、也不动网络同步频率。跟 reduce_motion 彼此独立。
static var fps_limit_30 := false

static func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	bgm_enabled = bool(cfg.get_value("ui", "bgm_enabled", bgm_enabled))
	room_music_volume = clampi(int(cfg.get_value("ui", "room_music_volume", 35)), 0, 100)
	room_music_muted = bool(cfg.get_value("ui", "room_music_muted", false))
	reduce_motion = bool(cfg.get_value("ui", "reduce_motion", reduce_motion))
	impact_fx_enabled = bool(cfg.get_value("ui", "impact_fx_enabled", impact_fx_enabled))
	impact_sfx_enabled = bool(cfg.get_value("ui", "impact_sfx_enabled", impact_sfx_enabled))
	fps_limit_30 = bool(cfg.get_value("ui", "fps_limit_30", fps_limit_30))

static func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("ui", "bgm_enabled", bgm_enabled)
	cfg.set_value("ui", "room_music_volume", room_music_volume)
	cfg.set_value("ui", "room_music_muted", room_music_muted)
	cfg.set_value("ui", "reduce_motion", reduce_motion)
	cfg.set_value("ui", "impact_fx_enabled", impact_fx_enabled)
	cfg.set_value("ui", "impact_sfx_enabled", impact_sfx_enabled)
	cfg.set_value("ui", "fps_limit_30", fps_limit_30)
	cfg.save(SETTINGS_PATH)
