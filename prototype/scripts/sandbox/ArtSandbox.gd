extends Node2D

const SOURCE_PROFILES: Array[BallVisualProfile] = [
	preload("res://resources/ball_visuals/player.tres"),
	preload("res://resources/ball_visuals/steel.tres"),
	preload("res://resources/ball_visuals/fire.tres"),
	preload("res://resources/ball_visuals/vampire.tres"),
	preload("res://resources/ball_visuals/refresh.tres")
]
const SOURCE_ARENA_THEME: ArenaTheme = preload("res://resources/arena_themes/neon_circuit.tres")
const SOURCE_ARENA_LAYOUT: ArenaDefinition = preload("res://resources/arenas/training_grid.tres")
const PROFILE_KEYS := ["player", "steel", "fire", "vampire", "refresh"]

var profiles: Array[BallVisualProfile] = []
var selected_index := 0
var active_profile: BallVisualProfile
var arena_theme: ArenaTheme
var arena_layout: ArenaDefinition
var arena_view: ArenaVisual
var hero_ball: BallVisual
var thumbnails: Array[BallVisual] = []
var profile_picker: OptionButton
var ball_color_picker: ColorPickerButton
var border_color_picker: ColorPickerButton
var floor_color_picker: ColorPickerButton
var inset_color_picker: ColorPickerButton
var grid_color_picker: ColorPickerButton
var grid_toggle: CheckButton
var status_label: Label
var spin_button: Button
var glow_slider: HSlider
var spin_speed_slider: HSlider
var spin_friction_slider: HSlider
var blink_slider: HSlider
var border_glow_slider: HSlider
var font: Font

func _ready() -> void:
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Arial", "Noto Sans", "sans-serif"])
	for i in range(SOURCE_PROFILES.size()):
		var custom_path := "res://resources/custom_art_profiles/ball_%s.tres" % PROFILE_KEYS[i]
		var source_profile: BallVisualProfile = load(custom_path) if ResourceLoader.exists(custom_path) else SOURCE_PROFILES[i]
		profiles.append(source_profile.duplicate(true) as BallVisualProfile)
	var custom_theme_path := "res://resources/custom_art_profiles/arena_theme.tres"
	var source_theme: ArenaTheme = load(custom_theme_path) if ResourceLoader.exists(custom_theme_path) else SOURCE_ARENA_THEME
	arena_theme = source_theme.duplicate(true) as ArenaTheme
	arena_layout = SOURCE_ARENA_LAYOUT.duplicate(true) as ArenaDefinition
	_build_preview()
	_build_controls()
	_select_profile(0)

func _build_preview() -> void:
	arena_view = ArenaVisual.new()
	arena_view.theme = arena_theme
	arena_view.layout = arena_layout
	arena_view.stage_rect = Rect2(24.0, 112.0, 492.0, 510.0)
	add_child(arena_view)

	hero_ball = BallVisual.new()
	hero_ball.position = Vector2(270.0, 333.0)
	hero_ball.scale = Vector2(3.1, 3.1)
	add_child(hero_ball)

	for i in range(profiles.size()):
		var preview := BallVisual.new()
		preview.profile = profiles[i]
		preview.position = Vector2(69.0 + i * 100.0, 550.0)
		preview.scale = Vector2(0.50, 0.50)
		add_child(preview)
		thumbnails.append(preview)

func _build_controls() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	var header := _label(ui, "BALL ART LAB", Vector2(24, 20), 25, Color("83efff"))
	var subtitle := _label(ui, "Procedural orb materials / arena lighting preview", Vector2(24, 52), 13, Color("a9bfd0"))
	var game_button := _button(ui, "PLAY PROTOTYPE", Rect2(388, 26, 128, 38))
	game_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main.tscn"))

	var sample_titles := ["PLAYER", "STEEL", "FIRE", "VAMPIRE", "REFRESH"]
	for i in range(sample_titles.size()):
		var sample_label := _label(ui, sample_titles[i], Vector2(29 + i * 100, 580), 10, Color("9fb7c6"))
		sample_label.size = Vector2(80, 18)
		sample_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var control_title := _label(ui, "LIVE MATERIAL CONTROLS", Vector2(24, 630), 13, Color("70ddeb"))
	profile_picker = OptionButton.new()
	profile_picker.position = Vector2(24, 651)
	profile_picker.size = Vector2(190, 34)
	profile_picker.add_theme_font_override("font", font)
	profile_picker.add_theme_font_size_override("font_size", 13)
	for profile in profiles:
		profile_picker.add_item(profile.display_name)
	profile_picker.item_selected.connect(_select_profile)
	ui.add_child(profile_picker)

	ball_color_picker = ColorPickerButton.new()
	ball_color_picker.position = Vector2(230, 651)
	ball_color_picker.size = Vector2(116, 34)
	ball_color_picker.text = "BALL COLOR"
	ball_color_picker.add_theme_font_override("font", font)
	ball_color_picker.add_theme_font_size_override("font_size", 11)
	_apply_button_style(ball_color_picker)
	ball_color_picker.color_changed.connect(_on_ball_color_changed)
	ui.add_child(ball_color_picker)

	border_color_picker = ColorPickerButton.new()
	border_color_picker.position = Vector2(366, 651)
	border_color_picker.size = Vector2(150, 34)
	border_color_picker.text = "BORDER COLOR"
	border_color_picker.add_theme_font_override("font", font)
	border_color_picker.add_theme_font_size_override("font_size", 11)
	_apply_button_style(border_color_picker)
	border_color_picker.color_changed.connect(_on_border_color_changed)
	ui.add_child(border_color_picker)

	floor_color_picker = _add_color_picker(ui, "FLOOR", Rect2(24, 692, 116, 30), arena_theme.floor_color, _on_floor_color_changed)
	inset_color_picker = _add_color_picker(ui, "FIELD", Rect2(154, 692, 116, 30), arena_theme.inset_color, _on_inset_color_changed)
	grid_color_picker = _add_color_picker(ui, "GRID", Rect2(284, 692, 116, 30), arena_theme.grid_color, _on_grid_color_changed)
	grid_toggle = CheckButton.new()
	grid_toggle.text = "GRID"
	grid_toggle.position = Vector2(414, 691)
	grid_toggle.size = Vector2(100, 32)
	grid_toggle.button_pressed = arena_theme.show_grid
	grid_toggle.add_theme_font_override("font", font)
	grid_toggle.add_theme_font_size_override("font_size", 11)
	grid_toggle.toggled.connect(_on_grid_toggled)
	ui.add_child(grid_toggle)

	glow_slider = _add_slider(ui, "SURFACE DETAIL", 0.0, 1.5, 0.72, 0.01, 730, _on_glow_changed, true)
	spin_speed_slider = _add_slider(ui, "SPIN SPEED", 0.0, 18.0, 6.0, 0.1, 770, _on_spin_speed_changed)
	spin_friction_slider = _add_slider(ui, "SPIN FRICTION", 0.0, 6.0, 1.0, 0.05, 810, _on_spin_friction_changed)
	blink_slider = _add_slider(ui, "BLINK INTERVAL (SEC)", 0.25, 3.0, 1.0, 0.05, 850, _on_blink_changed)
	border_glow_slider = _add_slider(ui, "BORDER GLOW", 0.0, 1.5, 0.82, 0.01, 890, _on_border_glow_changed)

	spin_button = _button(ui, "SPIN TEST", Rect2(405, 732, 111, 32))
	spin_button.pressed.connect(_on_spin_pressed)
	var save_button := _button(ui, "SAVE PRESET", Rect2(24, 926, 150, 30))
	save_button.pressed.connect(_save_preset)
	status_label = _label(ui, "Changes are live. Save a preset when it feels right.", Vector2(188, 934), 11, Color("9fb7c6"))

func _label(parent: Node, text_value: String, pos: Vector2, size: int, tint: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = pos
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", tint)
	parent.add_child(label)
	return label

func _button(parent: Node, title: String, rect: Rect2) -> Button:
	var button := Button.new()
	button.text = title
	button.position = rect.position
	button.size = rect.size
	button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", 12)
	_apply_button_style(button)
	parent.add_child(button)
	return button

func _apply_button_style(button: Button) -> void:
	button.add_theme_color_override("font_color", Color("e8faff"))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("103448")
	normal.border_color = Color("36cfe2")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(9)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color("19536a")
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)

func _add_color_picker(parent: Node, title: String, rect: Rect2, initial: Color, callback: Callable) -> ColorPickerButton:
	var picker := ColorPickerButton.new()
	picker.text = title
	picker.position = rect.position
	picker.size = rect.size
	picker.color = initial
	picker.add_theme_font_override("font", font)
	picker.add_theme_font_size_override("font_size", 10)
	_apply_button_style(picker)
	picker.color_changed.connect(callback)
	parent.add_child(picker)
	return picker

func _add_slider(parent: Node, title: String, min_value: float, max_value: float, start_value: float, step: float, y: float, callback: Callable, short_track: bool = false) -> HSlider:
	_label(parent, title, Vector2(24, y), 11, Color("a7d7e2"))
	var slider := HSlider.new()
	slider.position = Vector2(148, y + 12)
	slider.size = Vector2(246 if short_track else 280, 22)
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = start_value
	slider.add_theme_stylebox_override("slider", _track_style())
	slider.add_theme_stylebox_override("grabber_area", _track_style())
	slider.add_theme_color_override("font_color", Color("e5faff"))
	slider.value_changed.connect(callback)
	parent.add_child(slider)
	var value_label := _label(parent, "%.2f" % start_value, Vector2(450, y), 11, Color("d5eff5"))
	slider.set_meta("value_label", value_label)
	slider.value_changed.connect(func(value: float): value_label.text = "%.2f" % value)
	return slider

func _track_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("143343")
	style.set_corner_radius_all(5)
	return style

func _select_profile(index: int) -> void:
	selected_index = clampi(index, 0, profiles.size() - 1)
	active_profile = profiles[selected_index]
	hero_ball.profile = active_profile
	ball_color_picker.color = active_profile.body_color
	profile_picker.select(selected_index)
	_refresh_slider_values()
	for i in range(thumbnails.size()):
		thumbnails[i].profile = profiles[i]

func _refresh_slider_values() -> void:
	_sync_slider(glow_slider, active_profile.glow)
	_sync_slider(spin_speed_slider, active_profile.spin_speed)
	_sync_slider(spin_friction_slider, active_profile.spin_friction)
	_sync_slider(blink_slider, active_profile.blink_interval)
	_sync_slider(border_glow_slider, arena_theme.border_glow)
	border_color_picker.color = arena_theme.border_color
	floor_color_picker.color = arena_theme.floor_color
	inset_color_picker.color = arena_theme.inset_color
	grid_color_picker.color = arena_theme.grid_color
	grid_toggle.set_pressed_no_signal(arena_theme.show_grid)
	hero_ball.stop_spin()
	spin_button.text = "SPIN TEST"

func _sync_slider(slider: HSlider, value: float) -> void:
	slider.set_value_no_signal(value)
	var value_label: Label = slider.get_meta("value_label")
	value_label.text = "%.2f" % value

func _on_ball_color_changed(color: Color) -> void:
	active_profile.body_color = color
	hero_ball.queue_redraw()
	for thumbnail in thumbnails:
		thumbnail.queue_redraw()

func _on_border_color_changed(color: Color) -> void:
	arena_theme.border_color = color
	arena_view.queue_redraw()

func _on_floor_color_changed(color: Color) -> void:
	arena_theme.floor_color = color
	arena_view.queue_redraw()

func _on_inset_color_changed(color: Color) -> void:
	arena_theme.inset_color = color
	arena_view.queue_redraw()

func _on_grid_color_changed(color: Color) -> void:
	arena_theme.grid_color = color
	arena_view.queue_redraw()

func _on_grid_toggled(pressed: bool) -> void:
	arena_theme.show_grid = pressed
	arena_view.queue_redraw()

func _on_glow_changed(value: float) -> void:
	active_profile.glow = value
	hero_ball.queue_redraw()
	for thumbnail in thumbnails:
		thumbnail.queue_redraw()

func _on_spin_speed_changed(value: float) -> void:
	active_profile.spin_speed = value
	if absf(hero_ball.angular_velocity) > 0.05:
		hero_ball.angular_velocity = value

func _on_spin_friction_changed(value: float) -> void:
	active_profile.spin_friction = value

func _on_blink_changed(value: float) -> void:
	active_profile.blink_interval = value
	hero_ball.queue_redraw()

func _on_border_glow_changed(value: float) -> void:
	arena_theme.border_glow = value
	arena_view.queue_redraw()

func _on_spin_pressed() -> void:
	if absf(hero_ball.angular_velocity) < 0.05:
		hero_ball.start_spin(active_profile.spin_speed)
		spin_button.text = "STOP SPIN"
	else:
		hero_ball.stop_spin()
		spin_button.text = "SPIN TEST"

func _save_preset() -> void:
	var folder := "res://resources/custom_art_profiles"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var profile_path := "%s/ball_%s.tres" % [folder, PROFILE_KEYS[selected_index]]
	var theme_path := "%s/arena_theme.tres" % folder
	var profile_error := ResourceSaver.save(active_profile, profile_path)
	var theme_error := ResourceSaver.save(arena_theme, theme_path)
	if profile_error == OK and theme_error == OK:
		status_label.text = "Saved: resources/custom_art_profiles/"
	else:
		status_label.text = "Save failed (%d / %d)" % [profile_error, theme_error]
