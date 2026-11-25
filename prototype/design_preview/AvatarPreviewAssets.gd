extends RefCounted

# Original design-only portraits; no profile storage or upload path is connected.
const PATHS := [
	"res://assets/ui_preview/avatars/blue_1.png",
	"res://assets/ui_preview/avatars/blue_2.png",
	"res://assets/ui_preview/avatars/red_1.png",
	"res://assets/ui_preview/avatars/red_2.png"
]
const NAMES := ["星澜", "北辰", "绯月", "赤霄"]

static func load_circular_textures() -> Array[Texture2D]:
	var output: Array[Texture2D] = []
	for path in PATHS:
		# Use Godot's imported texture so these portraits are available in Web builds.
		var imported: Texture2D = load(path)
		var source: Image = imported.get_image() if imported != null else null
		if source == null or source.is_empty():
			output.append(null)
			continue
		var side: int = mini(source.get_width(), source.get_height())
		var crop_side: int = roundi(side * 0.55)
		var left: int = roundi((source.get_width() - crop_side) * 0.5)
		var top: int = roundi(source.get_height() * 0.13)
		top = mini(top, source.get_height() - crop_side)
		var portrait: Image = source.get_region(Rect2i(left, top, crop_side, crop_side))
		portrait.resize(256, 256, Image.INTERPOLATE_LANCZOS)
		portrait.convert(Image.FORMAT_RGBA8)
		for y in range(256):
			for x in range(256):
				var distance: float = Vector2(x - 127.5, y - 127.5).length() / 128.0
				var pixel: Color = portrait.get_pixel(x, y)
				pixel.a *= 1.0 - smoothstep(0.94, 1.0, distance)
				portrait.set_pixel(x, y, pixel)
		output.append(ImageTexture.create_from_image(portrait))
	return output
