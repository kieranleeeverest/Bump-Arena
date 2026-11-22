extends Resource
class_name ArenaTheme

@export var theme_name: String = "NEON CIRCUIT"
@export var floor_color: Color = Color("0b1e2b")
@export var inset_color: Color = Color("102a38")
@export var grid_color: Color = Color("55d9ee")
@export var border_color: Color = Color("30d8ee")
@export_range(0.0, 1.5, 0.01) var border_glow: float = 0.72
@export_range(1.0, 12.0, 0.5) var border_width: float = 3.0
@export_range(16.0, 64.0, 1.0) var grid_spacing: float = 30.0
@export var show_grid: bool = true
