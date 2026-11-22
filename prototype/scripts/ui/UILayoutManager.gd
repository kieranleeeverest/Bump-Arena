extends RefCounted

# Pure 540x960 design-space layout. No match state or physics lives here.
const DESIGN_SIZE := Vector2(540.0, 960.0)
const BOARD_REGION := Rect2(0.0, 110.0, 540.0, 666.0)
const SYSTEM_ROW_Y := 50.0
const ENEMY_ROW_Y := 91.0
const ALLY_ROW_Y := 729.0
const PLAYER_X := [145.0, 395.0]
const SOCIAL_ROW_Y := 871.0
const TOUCH_SIZE := 44.0
const STATUS_RECT := Rect2(204.0, 29.0, 132.0, 42.0)
const CHAT_RECT := Rect2(28.0, 871.0, 298.0, 44.0)
const BACK_CENTER := Vector2(46.0, 50.0)
const MENU_CENTER := Vector2(494.0, 50.0)
const MUSIC_CENTER := Vector2(374.0, 893.0)
const EMOJI_CENTER := Vector2(462.0, 893.0)
const SIDE_TOWER_BAR := Vector2(34.0, 3.0)
const MAIN_TOWER_BAR := Vector2(52.0, 3.0)

static func board_screen_center() -> Vector2:
	return BOARD_REGION.get_center()

static func board_transform(board_local_center: Vector2, blue_at_bottom: bool) -> Transform2D:
	var angle := PI if blue_at_bottom else 0.0
	var offset := board_screen_center() - board_local_center.rotated(angle)
	return Transform2D(angle, offset)

static func player_row_top(is_ally: bool) -> float:
	return ALLY_ROW_Y if is_ally else ENEMY_ROW_Y

static func player_center_x(slot: int) -> float:
	return PLAYER_X[clampi(slot, 0, 1)]

static func safe_design_inset(device_inset_px: float, uniform_scale: float, minimum: float = 28.0) -> float:
	return maxf(minimum, device_inset_px / maxf(uniform_scale, 0.001))

static func safe_adjusted_layout(uniform_scale: float, top_inset_px: float, bottom_inset_px: float) -> Dictionary:
	# Design-only projection. The game world and board transform never follow keyboard height.
	var top: float = safe_design_inset(top_inset_px, uniform_scale)
	var bottom: float = safe_design_inset(bottom_inset_px, uniform_scale)
	var top_shift: float = maxf(0.0, top - 28.0)
	var bottom_shift: float = maxf(0.0, bottom - 28.0)
	return {
		"system_y": SYSTEM_ROW_Y + top_shift,
		"enemy_row_y": ENEMY_ROW_Y + top_shift,
		"ally_row_y": ALLY_ROW_Y - bottom_shift,
		"social_rect": Rect2(CHAT_RECT.position + Vector2(0.0, -bottom_shift), CHAT_RECT.size),
		"board_center": board_screen_center()
	}
