extends Resource
class_name ArenaDefinition

@export var map_id: StringName = &"training"
@export var display_name: String = "Training Grid"
@export var field_size: Vector2 = Vector2(476.0, 500.0)
@export var spawn_points: PackedVector2Array = PackedVector2Array()
@export var fixed_hazard_points: PackedVector2Array = PackedVector2Array()
@export var obstacle_points: PackedVector2Array = PackedVector2Array()
