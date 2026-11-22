extends Node2D

var balls: Array = []
var towers: Array = []
var turn := 0
var moving := false
var aiming := false
var start := Vector2.ZERO
var pull := Vector2.ZERO
var timer := 15.0
var quiet := 0.0
var power := 5.0
var drag := 0.7
var bounce := 0.85
var banner := "任意空白处后拉，松开发射"
var status: Label
var font: Font
var finished := false
var skipped_hits := 0

func _ready():
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	var layer := CanvasLayer.new()
	add_child(layer)
	status = Label.new()
	status.position = Vector2(24, 12)
	status.add_theme_font_override("font", font)
	status.add_theme_font_size_override("font_size", 20)
	layer.add_child(status)
	var reset := Button.new()
	reset.text = "重置球位"
	reset.position = Vector2(390, 78)
	reset.size = Vector2(125, 42)
	reset.add_theme_font_override("font", font)
	reset.pressed.connect(reset_game)
	layer.add_child(reset)
	var settings = [["力度", 2.0, 9.0, power], ["减速", 0.2, 2.0, drag], ["反弹", 0.2, 1.0, bounce]]
	for i in range(3):
		var label := Label.new()
		label.text = settings[i][0]
		label.position = Vector2(24, 814 + i * 43)
		label.add_theme_font_override("font", font)
		layer.add_child(label)
		var slider := HSlider.new()
		slider.position = Vector2(90, 818 + i * 43)
		slider.size = Vector2(410, 28)
		slider.min_value = settings[i][1]
		slider.max_value = settings[i][2]
		slider.step = 0.05
		slider.value = settings[i][3]
		slider.value_changed.connect(func(v):
			if i == 0: power = v
			elif i == 1: drag = v
			else: bounce = v)
		layer.add_child(slider)
	reset_game()

func reset_game():
	balls.clear()
	towers.clear()
	for i in range(4):
		balls.append({"p": Vector2(170 + (i % 2) * 200, 320 + (i / 2) * 260), "v": Vector2.ZERO, "r": 22.0, "kind": "player", "id": i, "armed": false, "alive": true})
	for i in range(3):
		balls.append({"p": Vector2(150 + i * 120, 455), "v": Vector2.ZERO, "r": 24.0, "kind": "fire" if i == 2 else "iron", "id": -1, "armed": false, "alive": true})
	for side in range(2):
		for x in [65, 270, 475]:
			towers.append({"p": Vector2(x, 185 if side == 0 else 735), "hp": 100, "side": side, "main": x == 270})
	turn = 0
	moving = false
	aiming = false
	finished = false
	timer = 15.0
	banner = "任意空白处后拉，松开发射"

func _unhandled_input(e):
	if moving or finished: return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed: begin(e.position)
		else: release()
	elif e is InputEventMouseMotion and aiming: pull = (start - e.position).limit_length(180)
	elif e is InputEventScreenTouch:
		if e.pressed: begin(e.position)
		else: release()
	elif e is InputEventScreenDrag and aiming: pull = (start - e.position).limit_length(180)

func begin(p: Vector2):
	aiming = true
	start = p
	pull = Vector2.ZERO

func release():
	if not aiming: return
	aiming = false
	if pull.length() < 6: return
	balls[turn].v = pull * power
	moving = true
	quiet = 0.0
	banner = "母球须先撞球；仅撞墙不获得伤塔资格"

func next_turn():
	for b in balls:
		b.armed = false
		b.v = Vector2.ZERO
	turn = (turn + 1) % 4
	timer = 15.0
	moving = false
	aiming = false
	banner = "任意空白处后拉，松开发射"

func _physics_process(dt):
	if not moving and not finished:
		timer -= dt
		if timer <= 0: next_turn()
	if moving and not finished:
		for sub in range(4): step(dt / 4.0)
		var max_speed := 0.0
		for b in balls:
			if b.alive: max_speed = max(max_speed, b.v.length())
		quiet = quiet + dt if max_speed < 5 else 0.0
		if quiet > 0.25: next_turn()
	status.text = "弹射手感实验室 · 规则原型\n玩家 %d / 4　%s\n%s" % [turn + 1, "运动中" if moving else "%02d 秒" % ceili(timer), banner]
	queue_redraw()

func step(dt: float):
	for b in balls:
		if not b.alive: continue
		b.p += b.v * dt
		b.v *= exp(-drag * dt)
		for axis in range(2):
			var lo = 32 + b.r if axis == 0 else 150 + b.r
			var hi = 508 - b.r if axis == 0 else 770 - b.r
			if b.p[axis] < lo or b.p[axis] > hi:
				b.p[axis] = clamp(b.p[axis], lo, hi)
				b.v[axis] *= -bounce
				# 母球撞墙只能反弹，不能因此获得伤塔资格。
				if b.kind != "player": b.armed = true
	for i in range(balls.size()):
		for j in range(i + 1, balls.size()):
			var a = balls[i]
			var b = balls[j]
			if not a.alive or not b.alive: continue
			var d: Vector2 = b.p - a.p
			var distance: float = d.length()
			if distance >= a.r + b.r: continue
			var n: Vector2 = d / distance if distance > 0.001 else Vector2.RIGHT
			var overlap: float = a.r + b.r - distance
			a.p -= n * overlap * 0.5
			b.p += n * overlap * 0.5
			var approach: float = (b.v - a.v).dot(n)
			if approach < 0:
				var impulse: Vector2 = -(1 + bounce) * approach * n * 0.5
				a.v -= impulse
				b.v += impulse
				a.armed = true
				b.armed = true
	for b in balls:
		if not b.alive: continue
		for t in towers:
			if t.hp <= 0: continue
			var d: Vector2 = b.p - t.p
			var distance: float = d.length()
			if distance >= b.r + 27: continue
			var n: Vector2 = d.normalized() if distance > 0.001 else Vector2.DOWN
			b.p = t.p + n * (b.r + 27 + 0.1)
			var approach: float = b.v.dot(n)
			if approach >= 0:
				if b.armed: skipped_hits += 1
				continue
			b.v -= (1 + bounce) * approach * n
			if b.armed:
				t.hp = max(0, t.hp - (20 if b.kind == "fire" else 10))
				if t.hp == 0 and t.main:
					finished = true
					banner = "主塔被摧毁 · 点击重置再测试"
			if b.kind == "fire":
				b.alive = false
				break

func _draw():
	draw_style_box(field_style(), Rect2(32, 150, 476, 620))
	for x in range(50, 500, 30): draw_line(Vector2(x, 150), Vector2(x, 770), Color(1,1,1,0.035))
	for t in towers:
		if t.hp <= 0: continue
		var c = Color("62b9ff") if t.side == 0 else Color("ff6d88")
		draw_circle(t.p, 27, c.darkened(0.4))
		draw_arc(t.p, 27, 0, TAU, 40, c, 3)
		draw_string(font, t.p + Vector2(-12, 6), "主" if t.main else "塔", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
		draw_rect(Rect2(t.p + Vector2(-28, -40), Vector2(56 * t.hp / 100.0, 5)), c)
	for b in balls:
		if not b.alive: continue
		var c = Color("a6b4c8")
		if b.kind == "fire": c = Color("ff9c43")
		elif b.kind == "player": c = Color("62b9ff") if b.id < 2 else Color("ff6d88")
		draw_circle(b.p + Vector2(0, 4), b.r + 2, Color(0,0,0,0.25))
		draw_circle(b.p, b.r, c)
		if b.armed: draw_arc(b.p, b.r + 4, 0, TAU, 40, Color("ffe18a"), 3)
		if b.id == turn and b.kind == "player": draw_arc(b.p, b.r + 8, 0, TAU, 40, Color.WHITE, 2)
		var s = str(b.id + 1) if b.kind == "player" else ("火" if b.kind == "fire" else "铁")
		draw_string(font, b.p + Vector2(-10,7), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("132238"))
	if aiming:
		var p: Vector2 = balls[turn].p
		draw_line(p, p + pull, Color("ffe18a"), 4)
		draw_circle(p + pull, 6, Color("ffe18a"))
		draw_circle(start, 5, Color(1,1,1,0.5))

func field_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color("143b47")
	s.border_color = Color("3b6970")
	s.set_border_width_all(3)
	s.set_corner_radius_all(18)
	return s

