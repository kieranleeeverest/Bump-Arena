extends Resource
class_name BallRuleProfile

@export var destroy_on_impact: bool = false
@export_range(0, 100, 1) var impact_damage: int = 0
@export var respawns: bool = true
@export_range(0, 8, 1) var respawn_lock_turns: int = 0
