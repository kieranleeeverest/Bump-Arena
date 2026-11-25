extends SceneTree

const APP = preload("res://app_shell.tscn")
const OUT := "E:/杂项/怼球复刻/diagnostics/ui_v1_freeze_2026-11-22"

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var app: Control = APP.instantiate()
	app.profile_file = "res://design_preview/_capture_missing_profile.cfg"
	root.add_child(app)
	app.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	app._route("lobby")
	for dims in [Vector2i(360, 780), Vector2i(390, 844), Vector2i(430, 932)]:
		root.size = dims
		await process_frame
		await process_frame
		var picture := root.get_texture().get_image()
		var name := "layout_%dx%d.png" % [dims.x, dims.y]
		var error := picture.save_png(OUT + "/" + name)
		print("UI_V1_SIZE %s viewport=%s control=%s error=%d" % [name, picture.get_size(), app.size, error])
	quit(0)
