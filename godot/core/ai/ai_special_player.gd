class_name AISpecialPlayer
extends RefCounted

## `aAI_SpecialPlayerControl` `0x0040B2D0` -- the parabomb fuses.
##
## Runs once, before the main loop, and is three lines: a unit of type 31 owned
## by player 252 with one hit point detonates; one with more loses a point.
## Nothing shipped uses the longer fuse -- `Info.lcl` gives the `Parabomb`
## `HP max` 1, so it goes off at the start of the very next computer turn.

## docs/10 section 5.7 -- the neutral-prop owner, and the only routine that
## acts on it.
const PSEUDO_PLAYER: int = 0xFC
const PARABOMB_TYPE: int = 31
const FUSE_HP: int = 1


static func run(ctx: AIContext) -> bool:
	for slot: int in range(AISystem.UNIT_SLOTS):
		var unit: UnitState = ctx.unit_or_null(slot)
		if unit == null or unit.hp == 0:
			continue
		if unit.player != PSEUDO_PLAYER:
			continue
		if unit.type_id != PARABOMB_TYPE:
			continue
		if unit.hp != FUSE_HP:
			unit.hp -= 1
			continue
		var x: int = unit.x
		var y: int = unit.y
		var blast: AttackResult = Interact.execute_bomb(ctx.map, ctx.units,
			ctx.utab, ctx.wtab, x, y, ctx.turn.ai_level,
			ctx.turn.human_count(), ctx.turn.mode, ctx.turn, ctx.rng)
		ctx.emit(AIEvent.make("parabomb", slot, x, y, 0, 0, 0, "",
			blast.to_dict()))
		if unit.hp != 0:
			# `aRemoveUnitElement(x, y)` -- the bomb survived its own blast,
			# which docs/22 section 7's guaranteed-hit rule makes impossible
			# for the shipped `Parabomb`.
			unit.hp = 0
			UnitState.remove(ctx.map, ctx.turn, unit)
	return true
