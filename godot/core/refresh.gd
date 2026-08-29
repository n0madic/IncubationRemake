class_name Refresh
extends RefCounted

## What a hand-over restores for the incoming player -- `0x004781C0`.
##
## docs/25 section 5, and the twin of `tools/inclib/turn.py`'s `refresh_player`.
## Pinned natively over 130 field comparisons on two players
## (`tools/turn_gold.py` phase 3), plus the lone `0x004759B0` on one unit with a
## sentinel written into `+0x15` first -- which is what settled that the
## movement points **are** stored and the refresh **does** restore them, the
## correction this slice made to docs/25 section 5.
##
## `aBuildVisibleMap` is the routine's first act and belongs to docs/22
## section 9; the caller runs it, because visibility is not this file's.

## docs/25 section 5 -- `+0x41` value 7, "stood down without acting".
const ACTION_STOOD_DOWN: int = 7
## docs/21 section 5 -- `FP max` is a flag, not a value: 255 means "no fitness".
const FP_NONE: int = 255
const FP_CAP_FLOOR: int = 3
const EP_PER_RANK: int = 12
## docs/25 section 5 -- the three ids that shed two points of heat, not one.
const RAPID_FIRE_WEAPONS: Array[int] = [4, 6, 41]
const HEAT_NONE: int = 255
## docs/25 section 7 -- the alternate fire modes all sit at 40 or above and
## every base is at most 14, so `>= 20` means "this is an alternate, revert it".
const WEAPON_ALTERNATE_MIN: int = 20
## docs/25 section 8 -- 255 is "spent this turn"; the refresh turns it back on.
const STIMULANT_SPENT: int = 255


## docs/25 section 5 -- the jam ladder, one rung per hand-over.
static func malfunction_step(value: int) -> int:
	match value:
		1: return 0
		2: return 1
		3: return 0
		4: return 3
		5: return 4
		_: return value


## `0x00475120` -- the fitness cap is a **flag plus the rank**.
static func max_fp(unit: UnitState, types: UnitTypeTable, ep: int) -> int:
	if not types.has(unit.type_id) or types.fp_max(unit.type_id) == FP_NONE:
		return FP_NONE
	var rank: int = ep / EP_PER_RANK
	return FP_CAP_FLOOR if rank < FP_CAP_FLOOR else rank


## docs/25 section 5 -- at most +3 in one turn, snapping to the cap.
##
## The order matters: the stand-down point is added first and only when there
## is room for it, and the Banner arm then snaps rather than overshooting.
static func regenerate_fitness(unit: UnitState, cap: int,
		banner: bool) -> void:
	if unit.fp == FP_NONE or unit.fp == cap:
		return
	if unit.action_state == ACTION_STOOD_DOWN and unit.fp + 1 < cap:
		unit.fp += 1
	if banner:
		unit.fp = unit.fp + 2 if unit.fp + 2 < cap else cap
	elif unit.fp != 0:
		unit.fp = unit.fp + 1 if unit.fp + 1 < cap else cap


## docs/25 section 5 -- heat falls by one, or by two for the rapid-fire ids.
static func cool_weapon(unit: UnitState, weapons: WeaponTable) -> void:
	if not weapons.has(unit.weapon):
		return
	if weapons.heat(unit.weapon) == HEAT_NONE:
		return
	if RAPID_FIRE_WEAPONS.has(unit.weapon):
		if unit.heat > 1:
			unit.heat -= 2
		elif unit.heat > 0:
			unit.heat -= 1
	elif unit.heat > 0:
		unit.heat -= 1


## `aToggleWeaponModes` `0x0047A8C0` behind the three sites' `>= 20`.
##
## The engine never switches *into* an alternate mode here; only the player's
## own command does, and it does not survive the hand-over.
static func revert_weapon_mode(unit: UnitState, weapons: WeaponTable) -> void:
	if unit.weapon < WEAPON_ALTERNATE_MIN:
		return
	if not weapons.has(unit.weapon):
		return
	var toggle: int = weapons.toggle(unit.weapon)
	if toggle != unit.weapon:
		unit.weapon = toggle


## `0x004759B0` -- three actions, in this order.
##
## Clear `+0x39` when it is set, ask `aGetMovePoints` and **store** the answer
## in `+0x15`, then call the effect dispatcher `0x0046F210`, which is outside
## this model. The first two are the whole reason a hand-over gives a unit its
## movement back, and docs/25 section 5 used to deny that they happen.
static func recompute_stats(unit: UnitState, types: UnitTypeTable,
		units: Dictionary, ai_level: int) -> void:
	if unit.acted > 0:
		unit.acted = 0
	unit.mp = Allowance.for_unit(unit, types, units, ai_level)


## `0x004781C0` -- the whole pass, for one player. Returns the slots it touched.
##
## `banner_of` is the Banner test `0x0046FAD0`, passed in rather than recomputed
## so a caller that already has the unit array does not pay for it twice.
static func player(state: TurnState, incoming: int, units: Dictionary,
		types: UnitTypeTable, weapons: WeaponTable,
		banner_of: Callable) -> PackedInt32Array:
	for i: int in range(state.reaction_counter.size()):
		state.reaction_counter[i] = 0

	var touched: Array[int] = []
	var slots: Array = units.keys()
	slots.sort()
	for key: Variant in slots:
		var slot: int = DictRead.as_int(key)
		var unit: UnitState = units[slot]
		if unit.player != incoming or unit.hp <= 0:
			continue
		touched.append(slot)

		var banner: bool = DictRead.as_bool(banner_of.call(slot))
		regenerate_fitness(unit, max_fp(unit, types, unit.ep), banner)

		if unit.stimulant == STIMULANT_SPENT:
			unit.stimulant = 0
		unit.turn_start_x = unit.x
		unit.turn_start_y = unit.y
		unit.walked = 0
		unit.rested = 1 if unit.action_state == ACTION_STOOD_DOWN else 0
		recompute_stats(unit, types, units, state.ai_level)
		# After the recompute, not before: `0x004759B0` reads `+0x41` through
		# `aGetMovePoints`, where states 5 and 6 zero the allowance.
		unit.action_state = 0

		cool_weapon(unit, weapons)
		unit.ticket = 0
		revert_weapon_mode(unit, weapons)
		unit.malfunction = malfunction_step(unit.malfunction)

	var out: PackedInt32Array = PackedInt32Array()
	out.resize(touched.size())
	for i: int in range(touched.size()):
		out[i] = touched[i]
	return out
