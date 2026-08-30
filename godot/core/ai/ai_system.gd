class_name AISystem
extends RefCounted

## `aAISystemControl(player, pass, redraw)` `0x00409940` -- the whole computer
## turn.
##
## Two passes, six levels inside each, and a `repeat` that re-runs the sweep of
## the 200 slots whenever some unit ended it with no movement points left.
##
## Three things fall out of that shape and a remake has to get all three right:
##
## * **the pass orders ranged units before melee ones.** Pass 0 admits only
##   units whose weapon reaches further than one field, so shooters commit
##   before the things that have to walk into contact;
## * **the level is a search radius, not a difficulty.** It chooses how much
##   movement allowance [AIPlan] pretends the unit has when it floods the map,
##   and the same unit is offered the switch six times per pass with a wider
##   horizon each time;
## * **`repeat` re-runs the sweep whenever some unit ended with zero points.**
##   A sweep in which anything committed is followed by another one; the sweep
##   that changes nothing ends the level.
##
## The redraw callback is not modelled -- `core` draws nothing, and its only
## other effect, being invoked twice at each of three sites, is presentation.

const UNIT_SLOTS: int = 200
const PASSES: int = 2
const MAX_LEVEL: int = 5

## A hard ceiling on the sweeps of one turn. The engine has none and needs
## none: `repeat` is set when a unit ended a sweep with zero points, and
## movement points only ever fall, so the loop terminates. A model that got the
## condition wrong would **hang** rather than answer wrongly, which is why the
## ceiling exists and why exceeding it is an error rather than a truncation.
const SWEEP_CEILING: int = 512
const TURN_SWEEP_CEILING: int = PASSES * (MAX_LEVEL + 1) * SWEEP_CEILING


static func run(ctx: AIContext,
		player: int = UnitState.PLAYER_ALIEN) -> AITurnResult:
	var result: AITurnResult = ctx.result
	result.player = player
	result.seed_before = ctx.rng.seed

	AISpecialPlayer.run(ctx)

	for pass_index: int in range(PASSES):
		var level: int = 0
		var more: bool = true
		while more:
			var repeat: bool = true
			while repeat:
				repeat = false
				result.sweeps += 1
				if result.sweeps > TURN_SWEEP_CEILING:
					result.ok = false
					result.reason = ("the AI turn did not terminate within "
						+ str(TURN_SWEEP_CEILING) + " sweeps")
					result.seed_after = ctx.rng.seed
					return result
				for slot: int in range(UNIT_SLOTS):
					var unit: UnitState = ctx.unit_or_null(slot)
					if unit == null or unit.hp == 0:
						continue
					if unit.player != player:
						continue
					if unit.mp == 0:
						continue
					if pass_index == 0 and not _is_ranged(ctx, unit):
						continue
					AIOrders.dispatch(ctx, unit, level)
					# The common epilogue, which is also order 8's arm and the
					# out-of-range default: a unit that ended with nothing left
					# earns the sweep another run.
					if unit.mp == 0:
						repeat = true
			if level == MAX_LEVEL:
				more = false
			else:
				level += 1

	ctx.reset_overlay()
	for slot: int in range(UNIT_SLOTS):
		var unit: UnitState = ctx.unit_or_null(slot)
		if unit == null or unit.hp == 0:
			continue
		if unit.player != player or unit.mp == 0:
			continue
		AIUnitTurn.end_unit_turn(ctx, unit, AIUnitTurn.CLOSING_SWEEP)
	result.seed_after = ctx.rng.seed
	return result


## Pass 0's gate: `weaponInfo[u->weapon].rangeMax > 1`.
static func _is_ranged(ctx: AIContext, unit: UnitState) -> bool:
	return ctx.wtab.has(unit.weapon) and ctx.wtab.range_max(unit.weapon) > 1
