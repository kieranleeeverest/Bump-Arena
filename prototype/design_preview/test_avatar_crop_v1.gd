extends SceneTree

const CROP = preload("res://scripts/ui/AvatarCropDialog.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var image := Image.create(512, 384, false, Image.FORMAT_RGBA8)
	image.fill(Color("aa6699"))
	var dialog: Control = CROP.new()
	root.add_child(dialog)
	dialog.set_source(image)
	dialog.zoom = 1.5
	var captured: Array[Image] = []
	dialog.confirmed.connect(func(result: Image): captured.append(result))
	dialog._confirm()
	assert(captured.size() == 1)
	assert(captured[0].get_size() == Vector2i(256, 256))
	assert(captured[0].get_pixel(0, 0).a < 0.01)
	assert(captured[0].get_pixel(128, 128).a > 0.99)
	print("UI_V1_AVATAR_CROP_PASS 256px circular alpha")
	dialog.queue_free()
	quit(0)
