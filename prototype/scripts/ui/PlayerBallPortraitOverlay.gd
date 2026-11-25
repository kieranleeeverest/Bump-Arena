extends "res://design_preview/BallAvatarPreview.gd"

# Presentation only. The player-ball physics dictionaries are read, never changed.
var _redraw_accum := 0.0
const IDLE_REDRAW_INTERVAL := 1.0 / 20.0

func _process(delta: float) -> void:
	# While balls move the face must follow every frame. At rest it is a static
	# decal; 20 Hz avoids a third full-screen redraw on frames nobody can see.
	var busy: bool = game != null and (bool(game.moving) or bool(game.aiming))
	if busy:
		_redraw_accum = 0.0
		queue_redraw()
	else:
		_redraw_accum += delta
		if _redraw_accum >= IDLE_REDRAW_INTERVAL:
			_redraw_accum = 0.0
			queue_redraw()
