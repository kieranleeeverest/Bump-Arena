extends RefCounted
## TurnManager — 可配置的回合调度器。
##
## 支持两种对战模式（Mode），统一由本类驱动回合流转：
##   - MODE_DUEL (双人)  ：2 名玩家，各控 2 个球，两人交替击球。
##                         队伍映射 蓝=[0,1] 红=[2,3]，玩家映射 A=[0,1] B=[2,3]。
##   - MODE_QUAD  (四人)  ：4 名玩家，各控 1 个球，两人一队，队伍交替击球。
##                         玩家映射 0→0, 1→1, 2→2, 3→3（一人一球）。
##
## 出手次序不再是固定 1→3→2→4：每局由权威方抽签（`set_order`），
## 红/蓝谁先手、每队哪位先出手都等概率，两队始终交错。四步走满 = 一总回合。
## 槽序与队伍映射两种模式相同，真正差异在“玩家↔球槽”的归属。
## 回合合法性校验仍以 (team, slot, nonce) 三元组为准，因此网络与本地逻辑无需改动。

const ORDER := [0, 2, 1, 3] # 默认次序（UI 槽 1,3,2,4）；每局会被 _draw_match_lots 抽签覆盖。

enum Mode { DUEL, QUAD }
enum Phase { WAITING_FOR_SHOT, AIMING, SHOT_IN_PROGRESS, RESOLVING, FINISHED }

var phase: Phase = Phase.WAITING_FOR_SHOT
var order_index := 0
var round_number := 1
var turn_nonce := 0
## 本局的实际出手次序（4 个球槽、两队交错）。
## 由权威方每局抽签：红/蓝谁先手、每队哪位先出手，都等概率。
var order: Array = ORDER.duplicate()

# 当前模式。切换模式必须调用 setup(mode) 或 reset() 使状态归零。
var mode: Mode = Mode.DUEL

## 每种模式下的玩家↔球槽归属，按“球 id”索引（0..3）。
## 四人模式：每个球 id 归一名独立玩家（0→0, 1→1, 2→2, 3→3）。
## 双人模式：球 id 0,1 归玩家 0；球 id 2,3 归玩家 1。
const MODE_PLAYER_OWNERS := {
	Mode.DUEL: [0, 0, 1, 1],
	Mode.QUAD: [0, 1, 2, 3],
}

func setup(new_mode: Mode) -> void:
	mode = new_mode
	reset()

func reset() -> void:
	phase = Phase.WAITING_FOR_SHOT
	order_index = 0
	round_number = 1
	turn_nonce = 0

func current_slot() -> int:
	return int(order[order_index])


## 换一份本局次序。必须是 0..3 各一次、且相邻两步分属不同队（交错出手）。
## 只换表、不动 order_index：客户端是先设表、再从快照写 order_index。
func set_order(new_order: Array) -> bool:
	if new_order.size() != 4:
		return false
	var seen := {}
	for raw in new_order:
		if not (raw is int or raw is float):
			return false
		var slot := int(raw)
		if slot < 0 or slot > 3 or seen.has(slot):
			return false
		seen[slot] = true
	for i in range(1, new_order.size()):
		if (int(new_order[i]) < 2) == (int(new_order[i - 1]) < 2):
			return false
	var typed: Array[int] = []
	for raw in new_order:
		typed.append(int(raw))
	order = typed
	return true

func current_team() -> int:
	return 0 if current_slot() < 2 else 1

## 返回当前行动球槽在本局次序中的序号（0..3）。
func current_order_pos() -> int:
	return order_index

## 返回某球槽（球 id）归属的玩家编号（依据当前模式）。
func player_for_slot(slot: int) -> int:
	var owners: Array = MODE_PLAYER_OWNERS[mode]
	return owners[slot] if slot >= 0 and slot < owners.size() else -1

## 当前行动球槽归属的玩家编号。
func current_player() -> int:
	return player_for_slot(current_slot())

func can_act(team: int, slot: int, nonce: int) -> bool:
	return phase == Phase.WAITING_FOR_SHOT and team == current_team() and slot == current_slot() and nonce == turn_nonce

func begin_aim(team: int, slot: int, nonce: int) -> bool:
	if not can_act(team, slot, nonce): return false
	phase = Phase.AIMING
	return true

func cancel_aim() -> void:
	if phase == Phase.AIMING: phase = Phase.WAITING_FOR_SHOT

func commit_shot(team: int, slot: int, nonce: int) -> bool:
	if phase != Phase.AIMING or team != current_team() or slot != current_slot() or nonce != turn_nonce: return false
	phase = Phase.SHOT_IN_PROGRESS
	return true

func begin_resolving() -> bool:
	if phase != Phase.SHOT_IN_PROGRESS: return false
	phase = Phase.RESOLVING
	return true

func advance() -> bool:
	if phase == Phase.FINISHED or phase == Phase.AIMING: return false
	if phase != Phase.WAITING_FOR_SHOT and phase != Phase.RESOLVING: return false
	order_index = (order_index + 1) % order.size()
	if order_index == 0: round_number += 1
	turn_nonce += 1
	phase = Phase.WAITING_FOR_SHOT
	return true

func finish() -> void:
	phase = Phase.FINISHED
