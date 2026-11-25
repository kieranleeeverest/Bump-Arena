extends RefCounted
## Pure waiting-room seat rules.
##
## No nodes, no network: the authoritative host and the unit test share this one
## implementation of "who may sit where". Slot -> team is fixed by the board:
## slots 0/1 are blue, 2/3 are red. A duo room only opens the first seat of each
## team (0 and 2), a squad room opens all four.

const DUO_SEATS := [0, 2]
const SQUAD_SEATS := [0, 1, 2, 3]
# Join order: blue1 -> red1 -> blue2 -> red2. The first two arrivals always form
# a 1v1 even if the room later grows to four players.
const SLOT_ORDER := [0, 2, 1, 3]


static func seats_for_mode(mode: int) -> Array:
	return DUO_SEATS if mode == 0 else SQUAD_SEATS


static func is_active_seat(mode: int, slot: int) -> bool:
	return seats_for_mode(mode).has(slot)


static func team_of_slot(slot: int) -> int:
	if slot < 0 or slot > 3:
		return -1
	return 0 if slot < 2 else 1


static func slot_name(slot: int) -> String:
	var team := "蓝队" if team_of_slot(slot) == 0 else "红队"
	return "%s %d 号位" % [team, (slot % 2) + 1]


## slot -> player_id for every occupied seat in `members`.
static func occupied(members: Array) -> Dictionary:
	var out := {}
	for member in members:
		if not member is Dictionary:
			continue
		var pid := str(member.get("player_id", ""))
		var slot := int(member.get("slot", -1))
		if pid.is_empty() or slot < 0 or slot > 3:
			continue
		out[slot] = pid
	return out


## First free seat in join order, or -1 when every seat of this mode is taken.
static func auto_slot(mode: int, members: Array) -> int:
	var taken := occupied(members)
	for slot in SLOT_ORDER:
		if not is_active_seat(mode, slot):
			continue
		if not taken.has(slot):
			return slot
	return -1


## Result of one seat tap: {ok, reason}. The caller applies the move only when ok.
static func claim(mode: int, members: Array, player_id: String, target: int) -> Dictionary:
	if not is_active_seat(mode, target):
		return {"ok": false, "reason": "这个位置不属于当前模式的参赛席"}
	var taken := occupied(members)
	if taken.has(target) and str(taken[target]) != player_id:
		return {"ok": false, "reason": "这个位置刚刚被别人坐了"}
	return {"ok": true, "reason": ""}


## player_id -> slot after switching the room to `mode`.
## Squad -> duo keeps one original player per team (lowest slot wins) and demotes
## everyone else to -1 (spectator). Duo -> squad keeps both seated players.
static func seats_after_mode_change(members: Array, mode: int) -> Dictionary:
	var out := {}
	if mode == 1:
		for member in members:
			if not member is Dictionary:
				continue
			var pid := str(member.get("player_id", ""))
			if pid.is_empty():
				continue
			var slot := int(member.get("slot", -1))
			out[pid] = slot if slot >= 0 and slot <= 3 else -1
		return out
	var blue := _first_pid(members, [0, 1])
	var red := _first_pid(members, [2, 3])
	for member in members:
		if not member is Dictionary:
			continue
		var pid := str(member.get("player_id", ""))
		if pid.is_empty():
			continue
		var slot := -1
		if not blue.is_empty() and pid == blue:
			slot = 0
		elif not red.is_empty() and pid == red:
			slot = 2
		out[pid] = slot
	return out


static func _first_pid(members: Array, slots: Array) -> String:
	for slot in slots:
		for member in members:
			if not member is Dictionary:
				continue
			if int(member.get("slot", -1)) != slot:
				continue
			var pid := str(member.get("player_id", ""))
			if not pid.is_empty():
				return pid
	return ""
