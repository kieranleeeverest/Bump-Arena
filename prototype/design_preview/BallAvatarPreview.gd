extends Node2D

# Design-only world overlay. The live ball drawing, radius and collision stay untouched.
var game: Node2D
var portraits: Array[Texture2D] = []

func _draw() -> void:
	if game == null: return
	for ball in game.balls:
		if ball.kind != "player" or not ball.alive: continue
		var id: int = ball.id
		if id >= portraits.size() or portraits[id] == null: continue
		var team_color := Color("72d9f3") if id < 2 else Color("ff8aa7")
		draw_set_transform(ball.p, ball.angle, Vector2.ONE)
		draw_circle(Vector2.ZERO, ball.r - 0.7, team_color.darkened(0.54))
		draw_texture_rect(portraits[id], Rect2(-15.7, -15.7, 31.4, 31.4), false)
		draw_arc(Vector2.ZERO, ball.r - 0.8, 0.0, TAU, 48, team_color, 2.3)
		draw_arc(Vector2(-3.0, -3.0), ball.r - 6.0, 3.7, 5.15, 15, Color(1, 1, 1, 0.30), 1.5)
		draw_set_transform()
