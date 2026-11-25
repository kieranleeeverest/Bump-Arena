extends SceneTree

# 验证可配置回合机制：双人模式与四人模式的回合顺序、队伍交替、错误操作拒绝与重置。

func _initialize() -> void:
	call_deferred("run_test")

func check(value: bool, label: String) -> void:
	if not value:
		push_error("FAIL: " + label)
		quit(1)
		assert(false, label)

func run_test() -> void:
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	game.set_physics_process(false)
	var TM = game.TURN_MANAGER

	# --- 双人模式（默认 DUEL）：次序每局抽签，但蓝红必须交错；玩家映射 [0,0,1,1] ---
	check(game.match_mode == TM.Mode.DUEL, "default mode is DUEL")
	check(game.mode_player_owners() == [0, 0, 1, 1], "duel player owners")
	var expected: Array = game.turn_manager.order.duplicate()
	check(expected.size() == 4, "duel order has four steps")
	var first_team: int = 0 if int(expected[0]) < 2 else 1
	for index in range(expected.size()):
		var slot: int = expected[index]
		var team: int = 0 if slot < 2 else 1
		check(team == (first_team if index % 2 == 0 else 1 - first_team), "duel alternates teams %d" % index)
		check(game.turn == slot, "duel slot %d" % index)
		check(game.turn_manager.current_team() == team, "duel team %d" % index)
		check(game.turn_manager.current_player() == game.turn_manager.player_for_slot(slot), "duel player %d" % index)
		check(not game.request_shot(1 - team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "duel wrong team blocked %d" % index)
		check(not game.request_shot(team, (slot + 1) % 4, Vector2(30, 0), game.turn_manager.turn_nonce), "duel wrong slot blocked %d" % index)
		check(game.request_shot(team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "duel valid shot %d" % index)
		check(not game.request_shot(team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "duel duplicate blocked %d" % index)
		check(game.turn_manager.begin_resolving(), "duel resolving %d" % index)
		game.next_turn()
		print("DUEL TURN %d: slot %d team %s player %d round %d" % [index + 1, slot + 1, "blue" if team == 0 else "red", game.turn_manager.current_player(), game.turn_manager.round_number])
	check(game.turn_manager.round_number == 2, "duel one round completed")

	# --- 切换到四人模式（QUAD）：同一份抽签次序，玩家映射 [0,1,2,3]，每槽一名独立玩家 ---
	game.set_match_mode(TM.Mode.QUAD)
	check(game.match_mode == TM.Mode.QUAD, "switched to QUAD")
	check(game.mode_player_owners() == [0, 1, 2, 3], "quad player owners")
	check(game.turn == game.turn_manager.order[0] and game.turn_manager.round_number == 1, "quad reset to round 1 first drawn slot")
	for index in range(expected.size()):
		var slot: int = expected[index]
		var team: int = 0 if slot < 2 else 1
		var player: int = game.turn_manager.player_for_slot(slot)
		check(game.turn == slot, "quad slot %d" % index)
		check(game.turn_manager.current_team() == team, "quad team %d" % index)
		check(game.turn_manager.current_player() == player, "quad player %d" % index)
		check(not game.request_shot(1 - team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "quad wrong team blocked %d" % index)
		check(not game.request_shot(team, (slot + 1) % 4, Vector2(30, 0), game.turn_manager.turn_nonce), "quad wrong slot blocked %d" % index)
		check(game.request_shot(team, slot, Vector2(30, 0), game.turn_manager.turn_nonce), "quad valid shot %d" % index)
		check(game.turn_manager.begin_resolving(), "quad resolving %d" % index)
		game.next_turn()
		print("QUAD TURN %d: slot %d team %s player %d round %d" % [index + 1, slot + 1, "blue" if team == 0 else "red", player, game.turn_manager.round_number])
	check(game.turn_manager.round_number == 2, "quad one round completed")

	# --- 切回双人并重置 ---
	game.set_match_mode(TM.Mode.DUEL)
	check(game.match_mode == TM.Mode.DUEL and game.turn == game.turn_manager.order[0] and game.turn_manager.round_number == 1, "back to duel reset")

	# --- 物理伤害与结算回归检查 ---
	game.reset_game()
	for other in range(1, game.balls.size()): game.balls[other].alive = false
	var main_tower: Dictionary = game.towers[4]
	game.balls[0].p = main_tower.p + main_tower.inward * (main_tower.hit_r + game.balls[0].r + 1.0)
	game.balls[0].v = -main_tower.inward * 160.0
	game.balls[0].armed = true
	game.step(0.02)
	# 当前模型：base = clamp(round(10*160/600),1,10) = 3，铁球 ×TOWER_DAMAGE_SCALE(2) = 6 → 140-6=134。
	# 这里的 97 是很早以前伤害模型的期望值（同场景下 test_two_player_turns 打印的就是 134）。
	check(game.towers[4].hp == 134, "tower contact still deals damage")

	print("PASS configurable turn system: duel + quad order, teams, players, authority, rematch, damage")
	quit()
