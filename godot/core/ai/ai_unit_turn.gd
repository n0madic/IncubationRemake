class_name AIUnitTurn
extends RefCounted

## The cheap per-unit helpers -- `0x0040B380`, `0x0040A600`, `0x0040A6E0`,
## `0x0040B210`, `0x0040B250`, `0x0047A810` and `0x0040A710`.
##
## Each is a handful of lines in the engine and each is named in docs/23
## section 3.2, where the order handlers reach for them.

## What a shot or an interaction writes into `+0x39`.
const ACTED: int = 3
## `0x0040A710` -- the two `def_mode` values that enter defence, and the action
## state that says the entry took.
const DEF_MODE_AUTOMATIC: Array[int] = [1, 4]
const ACTION_STATE_WAITING: int = 1
## `0x0040A600` -- the door opener refuses below this many movement points.
const DOOR_MIN_MP: int = 2
const DOOR_MP_COST: int = 1
## docs/10 section 4.6 -- *standard Door — CLOSED*.
const ACTION_POINT_CLOSED_DOOR: int = 31
## What the closing sweep of [AISystem] tags its events with, so a check can
## tell the turn's own calls apart from the handlers'.
const CLOSING_SWEEP: String = "closing sweep"


## `0x0040B380` -- face a direction, then zero the movement points.
##
## The facing is `0x0047A8E0(x, y, 2)` ([method Combat.end_turn_facing]), and
## `0xFF` means "nobody to turn towards", in which case the write is skipped.
## The movement points go to zero either way, which is the half every caller
## depends on.
static func end_unit_turn(ctx: AIContext, unit: UnitState,
		note: String = "") -> bool:
	if unit.hp == 0:
		return false
	var facing: int = Combat.end_turn_facing(ctx.map, ctx.units, ctx.utab,
		unit.x, unit.y, Combat.FACING_MODE_ANY_ENEMY, false, ctx.state)
	if facing != Combat.FACING_NONE:
		unit.facing = facing
	unit.mp = 0
	ctx.emit(AIEvent.make("end_unit_turn", unit.slot, unit.x, unit.y,
		0, 0, 0, note))
	return true


## `0x0040A600` -- step up to a closed door and play the sequence.
##
## The routine calls `aDoorOpenSequence` (`0x00410A20`) at `0x0040A6B5` and
## keeps its answer, so what survives is the facing, one movement point, the
## *acted* flag **and the door itself**: the sequence rewrites the action
## point and the height, which is [method Interact.toggle_door]. Modelling
## only the first three left a door the computer had walked through still
## closed in the rules (docs/97 section 35); the cells it changed ride on
## the event so the picture can apply them in the frame it shows.
##
## The fog is **not** rebuilt: both of the sequence's rebuild sites are
## guarded by `aGetCurrentPlayer() != 0xFF`, and the computer holds the turn
## here -- the same guard [method World.submit_use] reads for the player.
static func open_door(ctx: AIContext, unit: UnitState) -> bool:
	if unit.hp == 0:
		return false
	if unit.mp < DOOR_MIN_MP:
		return false
	for dir: int in range(AIScore.DIR_DX.size()):
		var nx: int = unit.x + AIScore.DIR_DX[dir]
		var ny: int = unit.y + AIScore.DIR_DY[dir]
		if not ctx.map.in_bounds(nx, ny):
			continue
		if ctx.map.action_point_at(ctx.map.index_of(nx, ny)) \
				!= ACTION_POINT_CLOSED_DOOR:
			continue
		unit.facing = Combat.direction(unit.x, unit.y, nx, ny)
		unit.acted = ACTED
		unit.mp -= DOOR_MP_COST
		var index: int = ctx.map.index_of(nx, ny)
		Interact.toggle_door(ctx.map, index)
		ctx.emit(AIEvent.make("door", unit.slot, unit.x, unit.y, nx, ny,
			ACTION_POINT_CLOSED_DOOR, "", {"cells": [index],
				"action_point": ctx.map.action_point_at(index),
				"height": ctx.map.height_at(index)}))
		return true
	return false


## `0x0040A6E0` -- order 5's wait, one turn shorter each time.
##
## At zero the secondary order is promoted; otherwise the parameter falls by
## one and **the unit's turn ends**.
static func countdown(unit: UnitState) -> bool:
	if unit.order_param == 0:
		unit.order = unit.order2
		unit.order_param = unit.order2_param
		return true
	unit.order_param = IncInt.u8(unit.order_param - 1)
	unit.mp = 0
	return true


## `0x0040B210` -- is any of the 200 slots a live member of this group?
static func group_alive(ctx: AIContext, group: int) -> bool:
	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if other.group == group:
			return true
	return false


## `0x0047A810` -- promote the secondary order of a whole squad.
static func alert_group(ctx: AIContext, group: int) -> int:
	var woken: int = 0
	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if other.group != group:
			continue
		other.order = other.order2
		other.order_param = other.order2_param
		woken += 1
	ctx.emit(AIEvent.make("alert_group", -1, 0, 0, 0, 0, group, str(woken)))
	return woken


## `0x0040B250` -- order 6's tripwire.
##
## The **first** slot of another player within `u->+0x48` fields wakes the whole
## squad and ends the scan; the parameter is a radius in fields and the
## distance is `aGetDistance`.
static func distance_trigger(ctx: AIContext, unit: UnitState) -> bool:
	for slot: int in range(AISystem.UNIT_SLOTS):
		var other: UnitState = ctx.unit_or_null(slot)
		if other == null or other.hp == 0:
			continue
		if other.player == unit.player:
			continue
		if MoveMap.distance(other.x, other.y, unit.x, unit.y) \
				<= unit.order_param:
			alert_group(ctx, unit.group)
			return true
	return false


## `0x0040A710` -- the end-of-turn overwatch pass.
##
## Only weapons whose `def_mode` column is 1 or 4 can go on overwatch; the
## entry itself is `0x00478500`. `+0x39` is set **after** the call and the
## points are zeroed only when the entry took, which `+0x41 == 1` reports.
static func defence_mode(ctx: AIContext, unit: UnitState) -> bool:
	if not DEF_MODE_AUTOMATIC.has(ctx.wtab.def_mode(unit.weapon)):
		return true
	var ticket: int = Reaction.enter_defence(ctx.turn, unit)
	unit.acted = ACTED
	if unit.action_state == ACTION_STATE_WAITING:
		unit.mp = 0
	ctx.emit(AIEvent.make("defence", unit.slot, unit.x, unit.y, 0, 0, ticket))
	return true
