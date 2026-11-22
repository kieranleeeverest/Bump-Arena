extends Window

var game: Node2D
var status_label: Label
var view_picker: OptionButton
var collision_check: CheckButton
var bounds_check: CheckButton

func _ready() -> void:
	title = "Cosmic Bump Arena · 开发调试"
	size = Vector2i(320, 730)
	min_size = Vector2i(290, 600)
	visible = false
	close_requested.connect(func(): game.set_debug_mode(false))
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(294, 0)
	column.add_theme_constant_override("separation", 10)
	scroll.add_child(column)
	column.add_child(_label("电脑开发调试面板"))
	column.add_child(_label("左侧游戏窗口保持 540 × 960 逻辑视口"))
	status_label = _label("")
	column.add_child(status_label)
	column.add_child(_label("本地玩家视角"))
	view_picker = OptionButton.new()
	view_picker.add_item("蓝队在下", 0)
	view_picker.add_item("红队在下", 1)
	view_picker.selected = game.get_view_side()
	view_picker.item_selected.connect(func(index): game.set_preview_side(index))
	column.add_child(view_picker)
	collision_check = CheckButton.new()
	collision_check.text = "碰撞轮廓 / 接触点"
	collision_check.toggled.connect(func(checked): game.set_collision_debug(checked))
	column.add_child(collision_check)
	bounds_check = CheckButton.new()
	bounds_check.text = "HUD 安全区域与布局边框"
	bounds_check.toggled.connect(func(checked): game.set_ui_bounds_debug(checked))
	column.add_child(bounds_check)
	column.add_child(_label("Seed：当前单机原型尚未接入"))
	var seed_field := LineEdit.new()
	seed_field.placeholder_text = "待未来刷新机制接入"
	seed_field.editable = false
	column.add_child(seed_field)
	for entry in [["POWER", "power", 2.0, 9.0], ["DRAG", "drag", 0.2, 2.0], ["BOUNCE", "bounce", 0.2, 1.0]]:
		column.add_child(_label(entry[0]))
		var slider := HSlider.new()
		slider.min_value = entry[2]
		slider.max_value = entry[3]
		slider.step = 0.05
		slider.value = game.get(entry[1])
		var property_name: String = entry[1]
		slider.value_changed.connect(func(value): game.set(property_name, value))
		column.add_child(slider)
	var spawn_button := Button.new()
	spawn_button.text = "球体刷新测试（待接入）"
	spawn_button.disabled = true
	column.add_child(spawn_button)
	var black_hole_button := Button.new()
	black_hole_button.text = "黑洞测试（待接入）"
	black_hole_button.disabled = true
	column.add_child(black_hole_button)
	var reset_button := Button.new()
	reset_button.text = "重置比赛"
	reset_button.pressed.connect(func(): game.reset_game())
	column.add_child(reset_button)
	var preview_button := Button.new()
	preview_button.text = "开启正式预览（F3）"
	preview_button.pressed.connect(func(): game.set_debug_mode(false))
	column.add_child(preview_button)
	column.add_child(_label("F3 预览/调试    F4 布局框    F5 阵营视角"))
	var pulse := Timer.new()
	pulse.wait_time = 0.25
	pulse.autostart = true
	pulse.timeout.connect(refresh_status)
	add_child(pulse)
	refresh_status()

func _label(value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func refresh_status() -> void:
	if game == null or status_label == null: return
	status_label.text = "Turn %d/4 · %s · %.1f 秒\nFPS %.0f · 物理 %.2f ms\n本地视角：%s" % [game.turn + 1, "运动中" if game.moving else "待操作", game.timer, Engine.get_frames_per_second(), game.debug_frame_ms, "蓝队" if game.get_view_side() == 0 else "红队"]
	if view_picker != null and view_picker.selected != game.get_view_side(): view_picker.select(game.get_view_side())
	if collision_check != null and collision_check.button_pressed != game.debug_collisions: collision_check.set_pressed_no_signal(game.debug_collisions)
	if bounds_check != null and bounds_check.button_pressed != game.show_ui_bounds: bounds_check.set_pressed_no_signal(game.show_ui_bounds)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		game.handle_developer_key(event.keycode)
