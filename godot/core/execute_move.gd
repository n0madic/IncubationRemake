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
## The other half of the pair -- `0x004701B2`, `cmp byte [esi+0x0D], 0x0A`.
const FIELD_TELEPORT_OUT: int = 10

## docs/21 section 4 -- the weapon a mine would resolve as.
const MINE_WEAPON: int = 36
## `unitinfo[type].size` the ring arm is selected by -- `cmp byte [...], 1`.
const LARGE_UNIT_SIZE: int = 1

## `0x0046E357` -- `cmp byte [dest + 0x0C], 6 / jbe`: the destination's
## answer from the pass before the walk is discarded when the fill left more
## movement points than this on the cell. The mechanism is that instruction;
## the intent behind the number is an inference (docs/42 section 3.2).
const ARRIVAL_POINTS_LIMIT: int = 6

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
## `budget` is the movement points the walk may spend. **Measured, and it is
## the mover's real points**: `tools/ai_gold.py`'s plan probes hand the engine
## a path the level-2 horizon flooded with 30 points and the unit takes *one*
## step of it -- `+0x50` comes back 15, a single diagonal -- while an unbounded
## walk takes all seven. docs/23 section 5.1's horizon is a **search** radius;
## `0x0040A750` restores `u->+0x15` before it commits and the walk stops where
## those points do.
##
## -1 keeps the unbounded behaviour, which is what the player's own move wants:
## the UI never offers a cell the fill did not reach on the unit's real points,
## so the path is affordable by construction and a budget would be a second,
## redundant test.
static func run(state: MapState, ctab: CtrlMapTable, mover: UnitState,
		walked: Dictionary, budget: int = -1) -> MoveResult:
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
	result.route.append(route[0])
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
		var cost: int = (STEP_COST_DIAGONAL if diagonal
			else STEP_COST_ORTHOGONAL) \
			+ ctab.delay(state.field_type_at(index))
		if budget >= 0 and result.cost + cost > budget:
			break
		result.cost += cost
		result.walked += (STEP_TENTHS_DIAGONAL if diagonal
			else STEP_TENTHS_ORTHOGONAL)
		result.facing = FACING_OF_STEP[step]
		result.steps += 1
		result.x = nx
		result.y = ny
		result.route.append(index)
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
			# `0x0046EA73` -- the walk ends on the entry cell. The step has
			# already been charged (`0x0046EA42` subtracts the budget before
			# the test), the "keep walking" flag is not set on this arm, and
			# the epilogue calls `aExecuteTeleporter` with the position the
			# mover now holds. [method execute] is what resolves it, because
			# `0x0046EE03` sits behind the alive gate.
			result.events.append({"kind": "teleporter", "x": nx, "y": ny,
				"detail": action_point})
			result.teleporter = true
			result.ok = true
			return result

		if state.obstacle_at(index) == MapState.OBSTACLE_MINE:
			# **Measured.** The walk ends here, `+0x15` is zeroed *inside* the
			# routine and FALSE comes back with nothing written through
			# argument 5 -- so the caller's subtraction runs against a cost of
			# 0. What did not happen in the native probe is the ParaBomb: the
			# generator's seed was bit-identical either side, the mover's hit
			# points did not move, and the mine was still on the cell
			# afterwards.
			#
			# **That measurement is the guard, not the rule** (docs/26 section
			# 6.2). Every cell-based detonation runs
			# `aDeleteSpecialObject(cell[+0x0F])` first and fires only if it
			# answers non-zero; the probe wrote the effect byte onto an
			# ordinary cell and left `+0x0F` at 255, so the guard refused and
			# took the routine's FALSE exit. Since docs/97 section 37 the
			# placers write `+0x0F` beside `+0x10`, so an **authored** mine
			# passes the guard and goes off -- and a hand-written one still
			# does exactly what the capture saw.
			# **The detonation is [method execute]'s.** `0x0046EC0F` gates
			# the whole block on this flag, and `0x0046EC25` then picks the
			# arm by `unitinfo[type].size` -- which `run` has no table for.
			result.events.append({"kind": "mine", "x": nx, "y": ny,
				"detail": MINE_WEAPON})
			result.stopped_on_mine = true
			result.cost = 0
			result.movement_zeroed = true
			result.reason = "a mine ended the walk"
			return result

	# `here` is the arrival cell; keeping it named makes the loop's last write
	# visible to a reader looking for where the position comes from. It is the
	# end of the route only when the budget did not cut the walk short.
	assert(budget >= 0 or here == route[route.size() - 1])
	result.ok = true
	return result


## `aExecuteMove` with its writes: [method run] plus the three visibility
## passes the routine makes and the position the walk leaves.
##
## docs/22 section 9.3: `aBuildVisibleMapForUnit` is a **writing** pass, and
## the routine runs it from the destination before the first step
## (`0x0046E330`, every mover), from the source for a computer mover
## (`0x0046E385`), and from the arrival cell afterwards (`0x0046EE55`). The
## first two decide the walk's presentation mode -- [member MoveResult.seen_destination]
## and [member MoveResult.seen_source], the destination's answer discarded over
## [constant ARRIVAL_POINTS_LIMIT] -- and mode 3, a computer unit seen where it
## starts, opens with `aSetVisibleStateForUnit(unit, 0)` (`0x0046E4BB`): the
## walker is marked visible before it moves. Mode 3 also needs the *Enemy
## Move* option (`0x00460510`, the dword at `0x005129F4`); `enemy_move` is that
## option, on by default because the remake takes it as on (docs/92
## section 7), and `test_turn_native.gd` replays it off as well.
##
## The passes run on the world **as it stands at the call** -- the pre-walk
## ones with the mover on its source cell, the arrival one after the map and
## the record hold the new position -- which is why the apply lives here and
## not in the two callers. The `MoveUnit` event, the charge and the reaction
## drain stay the callers' (docs/23 section 5.3).
##
## `arrival_points` is the destination's `+0x0C`, the fill's movement points
## left on arrival; `aWalkMoveMap` stamps the destination 100 before its
## closing sweep and so leaves the byte alive for the test.
## The mine block of `0x0046EC0F`..`0x0046EDB7`, both arms.
##
## It runs **only** when the walk stopped on a mine, and `0x0046EC25` picks
## the arm by `unitinfo[type].size`:
##
## * a **small** mover detonates the cell it stopped on (`0x0046EDAF`);
## * a mover of size 1 sweeps its **eight neighbours** through `0x004308C0`
##   with the diagonal flag set and detonates every mine among them
##   (`0x0046ECA4`) -- the stop cell itself is not one of them.
##
## Each cell is behind the `aDeleteSpecialObject` guard of docs/26 section
## 6.2, and the ring stops the moment the mover's `+0x16` reaches zero
## (`0x0046ECB0`). The shipped campaign places no large unit next to a mine,
## so the ring is read and transcribed rather than exercised by any map;
## `test_execute_move` writes the `size` byte to reach it, the way docs/93
## section 11 reached the large-unit clearance.
static func _detonate(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, mover: UnitState, moved: MoveResult, ai_level: int,
		human_players: int, game_mode: int, turn: TurnState,
		rng: IncRandom) -> void:
	var cells: Array[Vector2i] = []
	if utab.unit_size(mover.type_id) == LARGE_UNIT_SIZE:
		for step: Vector2i in CellObjects.STEP_DELTA:
			if state.in_bounds(mover.x + step.x, mover.y + step.y):
				cells.append(Vector2i(mover.x + step.x, mover.y + step.y))
	else:
		cells.append(Vector2i(moved.x, moved.y))
	for at: Vector2i in cells:
		var index: int = state.index_of(at.x, at.y)
		if state.obstacle_at(index) != MapState.OBSTACLE_MINE:
			continue
		if not CellObjects.delete_object(
				state, state.effect_at(MapState.OBJECT_SLOT, index)):
			continue
		state.set_effect(MapState.OBJECT_SLOT, index, MapState.NO_OBJECT)
		state.set_obstacle(index, MapState.OBSTACLE_NONE)
		state.set_effect(MapState.TIMER_SLOT, index, 0)
		moved.detonate.append(at.x)
		moved.detonate.append(at.y)
		moved.blast = Interact.execute_bomb(state, units, utab, wtab, at.x,
			at.y, ai_level, human_players, game_mode, turn, rng).to_dict()
		moved.events.append({"kind": "mine_detonated", "x": at.x, "y": at.y,
			"detail": 0, "blast": moved.blast})
		# `0x0046ECB0` -- the ring stops the moment the mover is dead.
		if not mover.is_alive():
			return


## `aExecuteTeleporter` `0x00470150` -- docs/26 section 5, four instructions.
##
## The entry cell's action point (`+0x0B`, `0x00470199`) is the key; the exit
## is the **first** cell in row-major order whose field type is
## [constant FIELD_TELEPORT_OUT] and whose action point matches
## (`0x004701B2`), so two exits sharing a key make the earlier one win and two
## entries sharing an exit is legal. No exit at all and nothing happens
## (`0x004701CA`) -- which is `_C_156`'s key-104 entry, the one authoring bug
## of docs/26 section 5.1.
##
## **An occupied exit kills the traveller** (`0x004701DD`): the loss is booked
## into the scoreboard's Losses pair through `0x0043B8D0` -- a field the
## remake's save does not carry, so this books nothing, the same way
## [method LclInterpreter._fixed_statue] does not -- and `aRemoveUnitElement`
## takes the unit off the **entry** cell. The engine's own
## `mov byte [esi+0x16], 0` at `0x00470232` is redundant beside it and is not
## repeated here.
##
## Otherwise the cell link moves, `+0x42`/`+0x43` follow it, and the epilogue's
## closing visibility pass and `MoveUnit` event both see the **exit** cell.
static func _teleport(state: MapState, turn: TurnState, mover: UnitState,
		moved: MoveResult) -> void:
	var entry: int = state.index_of(moved.x, moved.y)
	var key: int = state.action_point_at(entry)
	var exit_at: int = -1
	for i: int in range(state.cell_count()):
		if state.field_type_at(i) == FIELD_TELEPORT_OUT \
				and state.action_point_at(i) == key:
			exit_at = i
			break
	if exit_at < 0:
		return
	if state.unit_at(exit_at) != MapState.NO_UNIT:
		UnitState.remove(state, turn, mover)
		moved.events.append({"kind": "teleporter_blocked", "x": moved.x,
			"y": moved.y, "detail": key})
		return
	var ex: int = exit_at % state.width
	var ey: int = exit_at / state.width
	state.set_unit(entry, MapState.NO_UNIT)
	state.set_unit(exit_at, mover.slot)
	mover.x = ex
	mover.y = ey
	moved.x = ex
	moved.y = ey
	moved.events.append({"kind": "teleported", "x": ex, "y": ey,
		"detail": key})


static func execute(state: MapState, units: Dictionary, utab: UnitTypeTable,
		ctab: CtrlMapTable, wtab: WeaponTable, mover: UnitState,
		walked: Dictionary, tx: int, ty: int, arrival_points: int,
		human_players: int, game_mode: int, ai_level: int, turn: TurnState,
		rng: IncRandom, budget: int = -1,
		enemy_move: bool = true) -> MoveResult:
	var moved: MoveResult = run(state, ctab, mover, walked, budget)
	if not moved.ok and not moved.movement_zeroed:
		return moved

	if state.in_bounds(tx, ty):
		moved.seen_destination = Visibility.look_from(state, units, utab,
			mover, tx, ty, human_players, game_mode)
	if arrival_points > ARRIVAL_POINTS_LIMIT:
		moved.seen_destination = false
	if mover.player == PLAYER_ALIEN:
		moved.seen_source = Visibility.look_from(state, units, utab, mover,
			mover.x, mover.y, human_players, game_mode)
		if moved.seen_source and enemy_move:
			Visibility.set_state(mover, Visibility.FULL)

	if moved.steps > 0:
		state.set_unit(state.index_of(mover.x, mover.y), MapState.NO_UNIT)
		state.set_unit(state.index_of(moved.x, moved.y), mover.slot)
		mover.x = moved.x
		mover.y = moved.y
		# The facing is written per step (`aChangeUnitViewDirection` inside
		# the loop), so a walk of no steps leaves it alone.
		mover.facing = moved.facing
		# `+0x50` is one byte and the engine adds into it, so it wraps rather
		# than saturating. Unreachable in practice -- the refresh zeroes it
		# every turn and 255 tenths is 25 fields of walking -- but masking is
		# what the field is, and picking a cap instead would be inventing a
		# rule.
		mover.walked = (mover.walked + moved.walked) & 0xFF
	for write: Vector2i in moved.action_point_writes:
		# `x` is the cell index and `y` the action point it becomes; the pair
		# comes from [method run] in that order.
		state.set_action_point(write.x, write.y)

	# **The mine goes off here, not in the caller.** `0x0046EDAF` is inside
	# `aExecuteMove`, between the relink and the closing pass, and the closing
	# pass is behind the mover's `+0x16`: `0x0046EDDC` reads it and returns
	# TRUE without looking when the bomb killed the walker. Firing it from the
	# caller would run the pass on a mover the mine was about to kill, and the
	# pass **writes** -- it reveals what the mover sees and wakes groups -- so
	# the order is the difference between two canonical hashes, not a detail.
	if moved.stopped_on_mine:
		_detonate(state, units, utab, wtab, mover, moved, ai_level,
			human_players, game_mode, turn, rng)
	# `0x0046EDDC` gates the teleport on the mover's `+0x16` and `0x0046EE30`
	# reads it again afterwards, so a traveller the blocked exit killed gets
	# no closing pass either.
	if mover.is_alive() and moved.teleporter:
		_teleport(state, turn, mover, moved)
	# The bomb arm returns first when the mine killed the walker
	# (`0x0046ECB5`, `0x0046EDE1`, `0x0046EE35`), so the third pass runs only
	# while the mover lives.
	if mover.is_alive():
		var _saw: bool = Visibility.look_from(state, units, utab, mover,
			mover.x, mover.y, human_players, game_mode)
	return moved
