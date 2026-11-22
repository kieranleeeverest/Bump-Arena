extends Resource
class_name BallPhysicsProfile

@export_range(0.05, 20.0, 0.05) var mass: float = 1.0
@export_range(6.0, 64.0, 1.0) var collision_radius: float = 22.0
@export_range(0.0, 1.0, 0.01) var friction: float = 0.7
@export_range(0.0, 1.0, 0.01) var restitution: float = 0.85
@export_range(0.0, 8.0, 0.05) var angular_friction: float = 1.0
