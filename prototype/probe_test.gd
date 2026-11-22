extends SceneTree
func _initialize():
	var lab = load("res://probe.gd").new()
	var damage_shots := 0
	var skips := 0
	for angle in range(0,360,5):
		lab.reset_game()
		lab.balls[0].v = Vector2.RIGHT.rotated(deg_to_rad(angle)) * 900
		for tick in range(2400): lab.step(1.0/240)
		var hp := 0
		for t in lab.towers: hp += int(t.hp)
		if hp < 600: damage_shots += 1
		skips += lab.skipped_hits
		lab.skipped_hits = 0
	print("Opening shots with damage: ",damage_shots,"/72. Armed tower contacts skipped: ",skips)
	lab.free()
	quit()
