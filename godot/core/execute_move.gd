class_name ExecuteMove
extends RefCounted

## `aExecuteMove` (`0x0046E220`) -- walking the path [WalkMap] reconstructed.
##
## Pinned by `tools/turn_gold.py` phase 10, which walks one two-step path six
## times inside the live engine, writing one byte between the walk and the call
## each time so that all six follow the identical marked path.
##
## **The cost is reported, not spent.** docs/23 section 5.3 and docs/93 section
## 11: `u->mp` is untouched by the call and the *caller* does
## `mp = 0 if cost > mp else mp - cost` afterwards. That seam is kept here --
## this returns a [MoveResult] and mutates no unit -- because a remake that
## charged inside its own move routine would double-charge the AI's path and
## leave the player's uncharged. The one exception is the mine, and it is
## exceptional in the engine too.

## `0x0046E645` / `0x0046E63B` -- what a step costs before the entered cell's
## delay column is added.
const STEP_COST_ORTHOGONAL: int = 1
const STEP_COST_DIAGONAL: int = 2

## docs/10 section 5.10 -- `unit[+0x50]`, in tenths of a field. `0x0046E7B7`.
const STEP_TENTHS_ORTHOGONAL: int = 10
const STEP_TENTHS_DIAGONAL: int = 15

## docs/26 section 6.1 -- the VictoryPoint band and its two bases.
const VICTORY_FIRST: int = 0x50
const VICTORY_LAST: int = 0x59
const VICTORY_A_LAST: int = 0x54
const VICTORY_A_BASE: int = 0x51
const VICTORY_B_FIRST: int = 0x55
const VICTORY_B_BASE: int = 0x56
## docs/23 section 9 -- the pseudo-player claims nothing.
const PLAYER_ALIEN: int = 255

## docs/26 section 5 -- the field type that starts a teleport, and the only one
## `aExecuteMove` tests for other than through the delay column.
const FIELD_TELEPORT_IN: int = 9

## docs/21 section 4 -- the weapon a mine would resolve as.
const MINE_WEAPON: int = 36

## `inclib.lev.FACING_STEPS` inverted: a step, to the facing that takes it.
## Confirmed natively twice -- eight facings against the map edge in phase 9,
## and the facing byte after a walk in phase 10.
const FACING_OF_STEP: Dictionary = {
	Vector2i(0, 1): 0, Vector2i(1, 1): 6, Vector2i(1, 0): 3,
	Vector2i(1, -1): 4, Vector2i(0, -1): 2, Vector2i(-1, -1): 7,
	Vector2i(-1, 0): 1, Vector2i(-1, 1): 5,
}


## Walks `walked` -- a [method WalkMap.path] result -- for real.
##
## `walked.path` is in the engine's own order, target first and source last, so
## the steps are taken over the reverse of it. That reversal happens here once
## rather than at every call site, because it is where an off-by-one would live.
static func run(state: MapState, ctab: CtrlMapTable, mover: UnitState,
		walked: Dictionary) -> MoveResult:
	if not DictRead.as_bool(walked["ok"]):
		return MoveResult.failed(mover.x, mover.y, "no path to follow")
	# `duplicate()`, and it is not defensive: a `Packed*Array` read out of a
	# dictionary **aliases** the one in it, so reversing in place reversed the
	# caller's own walk result. Two calls with the same walk then disagreed,
	# and the second one looked like an off-by-one in the step loop.
	var route: PackedInt32Array = DictRead.as_int32_array(
		walked["path"]).duplicate()
	if route.is_empty():
		return MoveResult.failed(mover.x, mover.y, "no path to follow")
	route.reverse()
	if route[0] != state.index_of(mover.x, mover.y):
		return MoveResult.failed(mover.x, mover.y,
			"the path does not start where the mover stands")

	var result: MoveResult = MoveResult.new()
	result.x = mover.x
	result.y = mover.y
	var here: int = route[0]
	for i: int in range(1, route.size()):
		var index: int = route[i]
		var nx: int = index % state.width
		var ny: int = index / state.width
		var step: Vector2i = Vector2i(nx - result.x, ny - result.y)
		if not FACING_OF_STEP.has(step):
			return MoveResult.failed(result.x, result.y,
				"the path leaves the eight directions")
		var diagonal: bool = step.x != 0 and step.y != 0
		# The delay is charged on the cell **entered**, and only it: phase 10
		# wrote a delay-1 field type onto the source (+0), a cell entered and
		# then left (+1) and the destination (+1).
		result.cost += (STEP_COST_DIAGONAL if diagonal
			else STEP_COST_ORTHOGONAL) \
			+ ctab.delay(state.field_type_at(index))
		result.walked += (STEP_TENTHS_DIAGONAL if diagonal
			else STEP_TENTHS_ORTHOGONAL)
		result.facing = FACING_OF_STEP[step]
		result.steps += 1
		result.x = nx
		result.y = ny
		here = index

		var action_point: int = state.action_point_at(index)
		if action_point >= VICTORY_FIRST and action_point <= VICTORY_LAST \
				and mover.player != PLAYER_ALIEN:
			var claimed: int = action_point
			if claimed <= VICTORY_A_LAST:
				claimed = VICTORY_A_BASE + mover.player
			if claimed >= VICTORY_B_FIRST and claimed <= VICTORY_LAST:
				claimed = VICTORY_B_BASE + mover.player
			result.action_point_writes.append(Vector2i(index, claimed))
			result.events.append({"kind": "victory_point", "x": nx, "y": ny,
				"detail": claimed})

		if state.field_type_at(index) == FIELD_TELEPORT_IN:
			result.events.append({"kind": "teleporter", "x": nx, "y": ny,
				"detail": action_point})

		if state.obstacle_at(index) == MapState.OBSTACLE_MINE:
			# **Measured, and not what docs/26 section 6.1 predicted.** The
			# walk ends here, `+0x15` is zeroed *inside* the routine and FALSE
			# comes back with nothing written through argument 5 -- so the
			# caller's subtraction runs against a cost of 0. What did not
			# happen in the native probe is the ParaBomb: the generator's seed
			# was bit-identical either side, the mover's hit points did not
			# move, and the mine was still on the cell afterwards. The event
			# says a mine was reached, not that one went off.
			result.events.append({"kind": "mine", "x": nx, "y": ny,
				"detail": MINE_WEAPON})
			result.cost = 0
			result.movement_zeroed = true
			result.reason = "a mine ended the walk"
			return result

	# `here` is the arrival cell; keeping it named makes the loop's last write
	# visible to a reader looking for where the position comes from.
	assert(here == route[route.size() - 1])
	result.ok = true
	return result
