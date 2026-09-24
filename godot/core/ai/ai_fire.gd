class_name AIFire
extends RefCounted

## `0x0040A440(u, mode, group)` -- one shot, or the reason there was none.
##
## Callers use it as `while (fire(u)) ;` -- *shoot until you cannot*. Two
## things make that loop terminate: the eligibility test `mp < ap` at the top,
## and the subtraction at the bottom, which runs **even when the shot did
## not** -- a weapon whose heat cap is 0 spends its points and draws no rolls.
## A model that skipped the subtraction on that arm would hang rather than
## answer wrongly, which is why [AISystem] carries a ceiling as well.

## `0x0040A440`'s two modes: 8 is "any enemy", 9 restricts to one group.
const FIRE_ANY: int = 8
const FIRE_GROUP: int = 9

## `0x00475340` -- the heat cap that turns the mechanic off.
const HEAT_DISABLED: int = 255
## What a shot writes into `+0x39` and `+0x41`.
const ACTED: int = 3
const ACTION_STATE_FIRED: int = 4

## docs/10 section 5.4 -- the four armour equipment ids and what each is worth
## to `0x00475490` (front) and `0x004754F0` (rear), heaviest first.
const ARMOUR_EQUIPMENT: Array[int] = [13, 12, 11, 10]
const ARMOUR_FRONT: Array[int] = [6, 5, 4, 3]
const ARMOUR_REAR: Array[int] = [4, 0, 2, 2]
## The unit-type armour column value that means "derive it from equipment".
const ARMOUR_DERIVED: int = 255

## A ceiling on one `while (fire())` loop. The engine has none and needs none;
## an implementation that lost the subtraction would spin forever, and a
## refusal is a better failure than a hang.
const LOOP_CEILING: int = 512


## `0x0040A440`'s middle stage: the numerically largest marker.
##
## Returns `{"cell": int, "marker": int, "refused": bool}`. Acceptance is
## `s >= bestScore`, so **the later cell wins a tie**, and the scan is
## row-major over the whole grid -- "later" means further down and to the
## right. There is no weighting by health, threat or value.
static func select_target(ctx: AIContext, mode: int,
		group: int) -> Dictionary:
	var best: int = -1
	var best_score: int = 0
	for index: int in range(ctx.state.size()):
		var marker: int = ctx.state[index]
		if marker < AIOverlay.MARKER_MIN or marker > AIOverlay.MARKER_MAX:
			continue
		if mode == FIRE_GROUP:
			var target: UnitState = ctx.unit_on_index(index)
			if target == null:
				# `GetUnitPtr(0xFFFF)` reports "unit id out of area" and the
				# routine returns FALSE. Reachable: weapon `special` 6 stamps
				# the target's cell of *last* turn, which may now be empty.
				ctx.refuse("group fire found a marker on an empty cell")
				return {"cell": -1, "marker": 0, "refused": true}
			if target.group != group:
				continue
		elif mode != FIRE_ANY:
			continue
		if marker >= best_score:
			best = index
			best_score = marker
	return {"cell": best, "marker": best_score, "refused": false}


static func run(ctx: AIContext, unit: UnitState, mode: int = FIRE_ANY,
		group: int = 0) -> bool:
	ctx.did(AIContext.WORK_FIRE)
	var ap: int = ctx.wtab.ap(unit.weapon)
	if unit.hp == 0:
		return false
	if unit.mp < ap:
		return false

	ctx.reset_overlay()
	AIOverlay.build(ctx, unit, ctx.turn.human_count(), ctx.turn.mode)
	AIOverlay.prune(ctx, false)

	var chosen: Dictionary = select_target(ctx, mode, group)
	if DictRead.as_bool(chosen["refused"]):
		return false
	var best: int = DictRead.as_int(chosen["cell"])
	if best < 0:
		return false
	if unit.mp == 0:
		return false

	var bx: int = ctx.cell_x(best)
	var by: int = ctx.cell_y(best)
	if ctx.may_fire:
		var cap: int = Combat.max_heat(ctx.wtab, unit)
		# The gate collapses: 255 disables the mechanic and any other non-zero
		# cap reaches the attack whether the unit is over it or not. The only
		# effect is that a weapon whose cap is 0 is never fired at all.
		var blocked: bool = cap != HEAT_DISABLED and unit.heat >= cap \
			and cap == 0
		if not blocked:
			# The overlay this pass built is what the pattern reads
			# ([constant Combat.SPECIAL_OBJECTS]).
			var attack: AttackResult = Combat.attack(ctx.map, ctx.units,
				ctx.utab, ctx.wtab, unit.x, unit.y, bx, by,
				ctx.turn.ai_level, ctx.turn.human_count(), ctx.turn.mode,
				ctx.turn, ctx.rng, false, ctx.cheats, ctx.state, ctx.ctab)
			if not attack.reason.is_empty() and not attack.fired:
				ctx.refuse(attack.reason)
			# The note is the weapon the animation was played with, not the
			# record's: a close-combat swap has been reverted by the time
			# `Combat.attack` returns ([member
			# AttackResult.presented_weapon]).
			var shown: int = attack.presented_weapon
			if shown < 0:
				shown = unit.weapon
			ctx.emit(AIEvent.make("fire", unit.slot, unit.x, unit.y, bx, by,
				DictRead.as_int(chosen["marker"]), str(shown),
				attack.to_dict()))
			unit.acted = ACTED
		else:
			ctx.emit(AIEvent.make("fire_heat_blocked", unit.slot, unit.x,
				unit.y, bx, by, cap, str(unit.weapon)))

	unit.mp = unit.mp - ap if unit.mp > ap else 0
	unit.action_state = ACTION_STATE_FIRED
	if unit.hp > 0:
		var reactions: Array[Dictionary] = Reaction.drain(ctx.map, ctx.units,
			ctx.utab, ctx.wtab, unit, ctx.turn.ai_level,
			ctx.turn.human_count(), ctx.turn.mode, ctx.turn, ctx.rng,
			ctx.journal, ctx.cheats, Callable(), ctx.ctab)
		if not reactions.is_empty():
			ctx.emit(AIEvent.make("reactions", unit.slot, unit.x, unit.y,
				0, 0, reactions.size(), "",
				{"reactions": reactions.duplicate(true)}))
	var armour: Vector2i = armour_of(ctx.utab, unit)
	unit.armour_front = armour.x
	unit.armour_rear = armour.y
	return true


## `while (fire(u, mode, group)) ;` -- how many times it answered TRUE.
static func until_empty(ctx: AIContext, unit: UnitState,
		mode: int = FIRE_ANY, group: int = 0) -> int:
	var shots: int = 0
	while run(ctx, unit, mode, group):
		shots += 1
		if shots > LOOP_CEILING:
			ctx.refuse("the fire loop did not terminate")
			break
	return shots


## `0x00475490` and `0x004754F0` -- docs/10 section 5.4, recomputed after every
## shot. The type's column wins unless it is 255; carrying no armour gives
## **0 / 0**, which is what both routines' shared idiom yields.
##
## A type the table has no row for keeps the unit's own bytes, which is what
## `inclib.ai.armour_of` does. Reading the columns anyway would take
## [method UnitTypeTable.armour_front]'s fallback of 0 and **zero a unit's
## armour after every shot it survives** -- the two implementations would then
## disagree wherever a mission places a type `Info.lcl` never defined, and no
## emitted case covers that, so the diff would not say so.
static func armour_of(utab: UnitTypeTable, unit: UnitState) -> Vector2i:
	if not utab.has(unit.type_id):
		return Vector2i(unit.armour_front, unit.armour_rear)
	var front: int = utab.armour_front(unit.type_id)
	var rear: int = utab.armour_rear(unit.type_id)
	for i: int in range(ARMOUR_EQUIPMENT.size()):
		if not unit.has_equipment(ARMOUR_EQUIPMENT[i]):
			continue
		if front == ARMOUR_DERIVED:
			front = ARMOUR_FRONT[i]
		if rear == ARMOUR_DERIVED:
			rear = ARMOUR_REAR[i]
		break
	if front == ARMOUR_DERIVED:
		front = 0
	if rear == ARMOUR_DERIVED:
		rear = 0
	return Vector2i(front, rear)
