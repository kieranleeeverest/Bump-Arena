extends Resource
class_name BallVisualProfile

enum SurfacePattern { PLAYER, METAL, FLAME, VEINS, REFRESH }

@export var profile_id: StringName = &"steel"
@export var display_name: String = "Steel"
@export var body_color: Color = Color("aebdce")
@export var rim_color: Color = Color("eff8ff")
@export var eye_color: Color = Color("55c7ff")
@export_range(12.0, 64.0, 1.0) var radius: float = 26.0
@export_range(0.0, 1.5, 0.01) var glow: float = 0.48
@export_range(0.0, 20.0, 0.1) var spin_speed: float = 5.0
@export_range(0.0, 8.0, 0.05) var spin_friction: float = 1.4
@export_range(0.25, 5.0, 0.05) var blink_interval: float = 1.0
@export_range(0.2, 0.7, 0.01) var eye_scale: float = 0.43
@export var show_eye: bool = true
@export var pattern: SurfacePattern = SurfacePattern.METAL
@export var artwork: Texture2D
