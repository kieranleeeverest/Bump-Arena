extends VBoxContainer

signal command(action: String, track_id: String)
signal volume_changed(value: int)
signal mute_changed
signal closed
signal gesture_layout_changed

var gesture_button: Button
var _status: Label
var _now_playing: Label
var _requester: Label
var _volume_label: Label
var _mute: Button
var _volume: HSlider
var _moderation: HBoxContainer
var _skip: Button
var _clear: Button
var _catalog_scroll: ScrollContainer
var _queue_scroll: ScrollContainer
var _catalog_items: VBoxContainer
var _queue_items: VBoxContainer
var _queue_tab: Button
var _track_buttons: Array[Button] = []
var _catalog_data: Variant = null
var _queue_data: Array = []
var _dragging := false

func _ready() -> void:
	add_theme_constant_override("separation", 10)
	var header := HBoxContainer.new()
	add_child(header)
	var title := _label(header, "房间音乐", Color("f4efff"), 34)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_button(header, "返回对局").pressed.connect(func(): closed.emit())

	var card := PanelContainer.new()
	var card_style := _style(Color("171d33"), Color("53506c"), 14, 14)
	card_style.border_color = Color("75d7e9")
	card_style.border_width_left = 3
	card_style.border_width_top = 0
	card_style.border_width_right = 0
	card_style.border_width_bottom = 0
	card_style.content_margin_top = 10
	card_style.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", card_style)
	add_child(card)
	var playback := VBoxContainer.new()
	playback.add_theme_constant_override("separation", 2)
	card.add_child(playback)
	_status = _label(playback, "正在连接房间音乐…", Color("75d7e9"))
	_now_playing = _label(playback, "房间暂无播放", Color("ffcf70"), 33)
	_requester = _label(playback, "", Color("b8aacb"))
	_requester.hide()

	var volume_row := HBoxContainer.new()
	volume_row.add_theme_constant_override("separation", 8)
	add_child(volume_row)
	_volume_label = _label(volume_row, "", Color("f4efff"))
	_volume_label.custom_minimum_size.x = 125
	_volume_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_volume = HSlider.new()
	_volume.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_volume.custom_minimum_size.y = 88
	_volume.max_value = 100
	_volume.step = 1
	var track := _style(Color("191c2e"), Color.TRANSPARENT, 6, 0)
	track.set_border_width_all(0)
	track.content_margin_top = 4
	track.content_margin_bottom = 4
	track.set_corner_radius_all(8)
	var fill: StyleBoxFlat = track.duplicate()
	fill.bg_color = Color("55b7c9")
	_volume.add_theme_stylebox_override("slider", track)
	_volume.add_theme_stylebox_override("grabber_area", fill)
	_volume.add_theme_stylebox_override("grabber_area_highlight", fill)
	_volume.drag_started.connect(func(): _dragging = true)
	_volume.drag_ended.connect(func(changed: bool):
		_dragging = false
		if changed: volume_changed.emit(int(_volume.value)))
	_volume.value_changed.connect(func(value: float):
		_volume_label.text = "音量 %d%%" % int(value)
		if not _dragging: volume_changed.emit(int(value)))
	volume_row.add_child(_volume)
	_mute = _button(volume_row, "静音")
	_mute.custom_minimum_size.x = 124
	_mute.pressed.connect(func(): mute_changed.emit())
	gesture_button = _button(self, "开启房间音乐", true)
	gesture_button.focus_mode = Control.FOCUS_NONE
	gesture_button.resized.connect(func(): gesture_layout_changed.emit())
	gesture_button.item_rect_changed.connect(func(): gesture_layout_changed.emit())
	gesture_button.hide()
	_moderation = HBoxContainer.new()
	_moderation.add_theme_constant_override("separation", 8)
	add_child(_moderation)
	_skip = _button(_moderation, "跳过当前")
	_clear = _button(_moderation, "清空队列")
	_skip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skip.pressed.connect(func(): command.emit("skip", ""))
	_clear.pressed.connect(func(): command.emit("clear", ""))
	_moderation.hide()
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	add_child(tabs)
	var group := ButtonGroup.new()
	var catalog_tab := _button(tabs, "歌单")
	_queue_tab = _button(tabs, "待播队列 0")
	for tab in [catalog_tab, _queue_tab]:
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.toggle_mode = true
		tab.button_group = group
	catalog_tab.set_pressed_no_signal(true)
	_catalog_items = _scrolling_list()
	_catalog_scroll = _catalog_items.get_parent()
	_queue_items = _scrolling_list()
	_queue_scroll = _queue_items.get_parent()
	_queue_scroll.hide()
	catalog_tab.pressed.connect(func(): _show_queue(false))
	_queue_tab.pressed.connect(func(): _show_queue(true))

func update_view(state: Dictionary, status: String, error: String, volume: int, muted: bool) -> void:
	var current: Variant = state.get("current")
	var queue: Array = state.get("queue", [])
	var catalog: Array = state.get("catalog", [])
	var queued: int = int(state.get("queued_by_me", 0))
	var available := status not in ["", "connecting", "unavailable"]
	_now_playing.text = "房间暂无播放" if current == null else str(current.track.title)
	_now_playing.tooltip_text = _now_playing.text
	_requester.visible = current != null
	_requester.text = "" if current == null else "%s 点播" % current.name
	var statuses := {"connecting": "正在连接房间音乐…", "gesture": "点击开启本机声音", "buffering": "正在缓冲…", "playing": "正在播放", "muted": "本机已静音", "media_error": "音乐加载失败", "idle": "等待点歌", "unavailable": "暂时无法连接房间音乐"}
	_status.text = error if not error.is_empty() else str(statuses.get(status, "正在连接房间音乐…"))
	_status.tooltip_text = _status.text
	_status.add_theme_color_override("font_color", Color("ffcf70") if not error.is_empty() or status == "media_error" else Color("75d7e9"))
	if not _dragging:
		_volume.set_value_no_signal(volume)
		_volume_label.text = "音量 %d%%" % volume
	_mute.text = "取消静音" if muted else "静音"
	gesture_button.text = "重试播放" if status == "media_error" else "开启房间音乐"
	gesture_button.visible = not muted and status in ["gesture", "media_error"]
	_moderation.visible = bool(state.get("is_host", false))
	_skip.disabled = not available or current == null
	_clear.disabled = not available or queue.is_empty()
	if _catalog_data != catalog:
		_update_catalog(catalog)
	for button in _track_buttons:
		button.disabled = not available or queued >= 2
	if _queue_data != [queue, queued]:
		_update_queue(queue, queued)

func _scrolling_list() -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size.y = 206
	scroll.scroll_deadzone = 10
	scroll.follow_focus = true
	add_child(scroll)
	var items := VBoxContainer.new()
	items.mouse_filter = Control.MOUSE_FILTER_PASS
	items.add_theme_constant_override("separation", 8)
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(items)
	return items

func _show_queue(show_queue: bool) -> void:
	_catalog_scroll.visible = not show_queue
	_queue_scroll.visible = show_queue

func _update_catalog(catalog: Array) -> void:
	_catalog_data = catalog
	_clear_items(_catalog_items)
	_track_buttons.clear()
	if catalog.is_empty(): _label(_catalog_items, "歌单暂无曲目", Color("b8aacb"))
	for track in catalog:
		var track_id: String = track.id
		var button := _button(_catalog_items, "+  " + str(track.title), true)
		button.mouse_filter = Control.MOUSE_FILTER_PASS
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.tooltip_text = str(track.title)
		button.pressed.connect(func(): command.emit("enqueue", track_id))
		_track_buttons.append(button)

func _update_queue(queue: Array, queued: int) -> void:
	_queue_data = [queue, queued]
	_queue_tab.text = "待播队列 %d" % queue.size()
	_clear_items(_queue_items)
	_label(_queue_items, "我的待播 %d/2" % queued, Color("75d7e9"))
	if queue.is_empty(): _label(_queue_items, "暂无待播曲目", Color("b8aacb"))
	for index in queue.size():
		var entry: Dictionary = queue[index]
		var line := _label(_queue_items, "%d. %s · %s" % [index + 1, entry.track.title, entry.name], Color("f4efff"))
		line.custom_minimum_size.y = 44
		line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line.tooltip_text = line.text

func _clear_items(items: VBoxContainer) -> void:
	for child in items.get_children():
		items.remove_child(child)
		child.queue_free()

func _label(parent: Control, value: String, color: Color, font_size := 28) -> Label:
	var label := Label.new()
	label.text = value
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _button(parent: Control, value: String, primary := false) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(88, 88)
	button.add_theme_font_size_override("font_size", 28)
	button.add_theme_color_override("font_color", Color("f4efff"))
	button.add_theme_color_override("font_disabled_color", Color("8e829e"))
	var normal_fill := Color("153542") if primary else Color("102433")
	var normal_border := Color("478095") if primary else Color("514461")
	button.add_theme_stylebox_override("normal", _style(normal_fill, normal_border, 12, 14))
	button.add_theme_stylebox_override("hover", _style(Color("202d45"), Color("75d7e9"), 12, 14))
	button.add_theme_stylebox_override("pressed", _style(Color("28304d"), Color("75d7e9"), 12, 14))
	button.add_theme_stylebox_override("disabled", _style(Color("101e2c"), Color("392e48"), 12, 14))
	parent.add_child(button)
	return button

func _style(fill: Color, border: Color, radius: int, padding: int) -> StyleBoxFlat:
	var result := StyleBoxFlat.new()
	result.bg_color = fill
	result.border_color = border
	result.set_border_width_all(1)
	result.set_corner_radius_all(radius)
	result.content_margin_left = padding
	result.content_margin_right = padding
	return result
