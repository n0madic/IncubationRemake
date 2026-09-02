class_name AIPlan
extends RefCounted

## `0x0040A750(u, kind, param, level)` -- fill, score, commit.
##
## Three stages: build a reachability map at a horizon the level chooses, score
## every cell by the kind, then move to the winner.
##
## **The answer is TRUE far more often than docs/23's C sketch suggests.** A
## dead unit, a spent unit, a walk of zero steps and a blocked path all return
## TRUE. FALSE comes back only from a failed fill, a failed path
## reconstruction, no candidate cell at all, and a failed move or warp. The
## `steps == 0` arm in particular is written as FALSE in the document and is
## `je 0x40acbc` -- `mov eax, 1; ret` -- in the code.

## docs/23 section 5.1 -- the movement points each level floods with, and
## whether it may pass through friendly units. -1 means "the unit's own", and
## level 1 doubles that.
const HORIZON_MP: Array[int] = [-1, -1, 30, 50, 100, 250]
const HORIZON_PASS: Array[bool] = [false, false, true, false, false, false]
const MAX_LEVEL: int = 5

## docs/23 section 5.2 -- `kind - 1` indexes twelve entries.
const KIND_ALLY: int = 1
const KIND_ENEMY: int = 2
const KIND_ALLY_SHORT: int = 3
const KIND_ACTION_POINT: int = 6
const KIND_GROUP: int = 7
const KIND_COVER: int = 10
const KIND_DOOR: int = 11
const KIND_ENEMY_READY: int = 12
const KIND_MIN: int = 1
const KIND_MAX: int = 12
## The four the table reserves as fall-through: 8 and 9 belong to [AIFire], and
## 4 and 5 have no code in either shipped binary.
const KIND_FALL_THROUGH: Array[int] = [4, 5, 8, 9]

## docs/10 section 4.6 -- *standard Door — CLOSED*.
const ACTION_POINT_CLOSED_DOOR: int = 31
## docs/23 section 5.3 -- what the move's caller writes into `unit[+0x39]`.
const ACTED: int = 3


## The movement points the fill pretends to at one level.
static func horizon_mp(level: int, mp: int) -> int:
	var override: int = HORIZON_MP[level]
	if override >= 0:
		return override
	# `shl al, 1` is a **byte** shift, so 130 points becomes 4, not 260.
	return IncInt.u8(mp * 2) if level == 1 else mp


## One of the six `aBuildMoveMap` calls, written into the overlay.
##
## The engine writes the fill's answer **into the cells**, over what
## `resetOverlay` just put there, which is why this copies rather than
## returning. A cell the fill never reached keeps its 1 and its 0.
static func build_move_map(ctx: AIContext, unit: UnitState,
		level: int) -> bool:
	var mp: int = horizon_mp(level, unit.mp)
	var allowance: int = Allowance.for_unit(unit, ctx.utab, ctx.units,
		ctx.turn.ai_level)
	ctx.did(AIContext.WORK_FILL)
	var fill: MoveMapResult = MoveMap.build(ctx.map, ctx.units, ctx.utab,
		ctx.ctab, unit.slot, HORIZON_PASS[level], mp, allowance)
	var states: PackedByteArray = fill.states()
	var left: PackedInt32Array = fill.mp_left()
	for i: int in range(ctx.state.size()):
		if states[i] != MoveMapResult.STATE_NONE:
			ctx.state[i] = states[i]
		ctx.mp_left[i] = left[i]
	return true


static func run(ctx: AIContext, unit: UnitState, kind: int, param: int,
		level: int) -> bool:
	ctx.did(AIContext.WORK_PLAN)
	if unit.hp == 0 or unit.mp == 0:
		return true
	var own_cell: int = ctx.map.index_of(unit.x, unit.y)
	var own_slot: int = ctx.map.unit_at(own_cell)
	ctx.reset_overlay()
	if level >= 0 and level <= MAX_LEVEL:
		if not build_move_map(ctx, unit, level):
			return false
	# A level outside 0..5 skips the fill entirely -- the switch's default arm
	# is the restore-and-scan tail -- leaving an overlay of plain cells the
	# approach scan can never accept. No handler passes one.

	var best: int = _score_cells(ctx, unit, kind, param, own_slot)
	if best < 0:
		return false
	return commit(ctx, unit, best)


## `0x0040A750`'s middle stage -- the twelve-arm scan over every cell.
static func _score_cells(ctx: AIContext, unit: UnitState, kind: int,
		param: int, own_slot: int) -> int:
	if kind < KIND_MIN or kind > KIND_MAX or KIND_FALL_THROUGH.has(kind):
		return -1
	var best_cell: int = -1
	var best: int = 0
	for index: int in range(ctx.state.size()):
		if ctx.state[index] == MoveMapResult.STATE_NONE:
			continue
		var approach: bool = false

		if kind == KIND_ENEMY or kind == KIND_ENEMY_READY:
			var other: UnitState = ctx.unit_on_index(index)
			if other == null:
				continue
			var ready: bool = (AIScore.is_enemy(ctx.utab, unit, other)
				if kind == KIND_ENEMY
				else AIScore.is_enemy_ready(ctx.utab, unit, other))
			if not ready:
				continue
			approach = true
		elif kind == KIND_ALLY or kind == KIND_ALLY_SHORT:
			var ally: UnitState = ctx.unit_on_index(index)
			if ally == null:
				continue
			var caps: Array[int] = (AIScore.ALLY_CAPS_FULL
				if kind == KIND_ALLY else AIScore.ALLY_CAPS_SHORT)
			var matched: bool = false
			for cap: int in caps:
				if AIScore.is_ally(ctx.utab, unit, ally, cap):
					matched = true
					break
			if not matched:
				continue
			approach = true
		elif kind == KIND_DOOR:
			if ctx.map.action_point_at(index) != ACTION_POINT_CLOSED_DOOR:
				continue
			approach = true
		elif kind == KIND_ACTION_POINT:
			if ctx.map.action_point_at(index) != param:
				continue
			if ctx.map.unit_at(index) != MapState.NO_UNIT:
				approach = true
			else:
				var left: int = ctx.mp_left[index]
				# `jl` -- the later cell wins a tie, and the incumbent's score
				# is doubled on the way in, so an occupied match has to beat
				# twice the free one.
				if left < best:
					continue
				best_cell = index
				best = left * 2
				continue
		elif kind == KIND_GROUP:
			var member: UnitState = ctx.unit_on_index(index)
			if member == null:
				continue
			if member.group != param:
				continue
			approach = true
		elif kind == KIND_COVER:
			var scored: Dictionary = AIScore.cover(ctx, index, unit, best)
			best = DictRead.as_int(scored["best"])
			if DictRead.as_int(scored["cell"]) >= 0:
				best_cell = DictRead.as_int(scored["cell"])
			continue

		if approach:
			var near: Dictionary = AIApproach.pick(ctx, index, best, own_slot)
			best = DictRead.as_int(near["best"])
			if DictRead.as_int(near["cell"]) >= 0:
				best_cell = DictRead.as_int(near["cell"])
	return best_cell


## `0x0040A750`'s tail -- walk to the chosen cell and pay for what happened.
static func commit(ctx: AIContext, unit: UnitState, best_cell: int) -> bool:
	var tx: int = ctx.cell_x(best_cell)
	var ty: int = ctx.cell_y(best_cell)
	var warping: bool = ctx.state[best_cell] == MoveMapResult.STATE_WARP

	var steps: int = 0
	var blocked: int = 0
	var walked: Dictionary = {}
	if warping:
		steps = unit.mp
	else:
		var overlay: MoveMapResult = MoveMapResult.create(ctx.map.width,
			ctx.map.height, unit.mp, ctx.state.duplicate(),
			ctx.mp_left.duplicate(), false, 0)
		walked = WalkMap.path(ctx.map, ctx.units, ctx.ctab, overlay, unit.x,
			unit.y, tx, ty)
		if not DictRead.as_bool(walked["ok"]):
			return false
		steps = DictRead.as_int(walked["steps"])
		blocked = DictRead.as_int(walked["blocked"])
	if steps == 0:
		# `je 0x40acbc` -- TRUE, not FALSE.
		return true

	var cost: int = 0
	if blocked == 0:
		if warping:
			if not execute_warp(ctx, unit, tx, ty):
				return false
			# A jump always ends the unit's movement.
			cost = unit.mp
		else:
			# The mover's **real** points bound the walk: `0x0040A750`
			# restores `u->+0x15` before it commits, and the wider horizons
			# are a search radius rather than a movement allowance.
			var sx: int = unit.x
			var sy: int = unit.y
			var moved: MoveResult = ExecuteMove.execute(ctx.map, ctx.units,
				ctx.utab, ctx.ctab, unit, walked, tx, ty,
				IncInt.u8(ctx.mp_left[best_cell]), ctx.turn.human_count(),
				ctx.turn.mode, unit.mp)
			if not moved.ok and not moved.movement_zeroed:
				return false
			_apply_move(ctx, unit, moved, sx, sy)
			cost = moved.cost
			if moved.movement_zeroed:
				unit.mp = 0
		unit.acted = ACTED
		if unit.hp > 0:
			var reactions: Array[Dictionary] = Reaction.drain(ctx.map,
				ctx.units, ctx.utab, ctx.wtab, unit, ctx.turn.ai_level,
				ctx.turn.human_count(), ctx.turn.mode, ctx.turn, ctx.rng)
			if not reactions.is_empty():
				ctx.emit(AIEvent.make("reactions", unit.slot, unit.x, unit.y,
					0, 0, reactions.size(), "",
					{"reactions": reactions.duplicate(true)}))
		if unit.hp == 0:
			return true
	if cost == 0:
		return true
	unit.mp = 0 if cost > unit.mp else unit.mp - cost
	return true


static func _apply_move(ctx: AIContext, unit: UnitState,
		moved: MoveResult, sx: int, sy: int) -> void:
	# `aExecuteMove`'s writes -- the position, the VictoryPoint claims and the
	# three visibility passes of docs/22 section 9.3 -- happened inside
	# [method ExecuteMove.execute]; what is left to the caller is the event.
	# The two flags are the passes' own answers, asked at the moment of the
	# move, and they ride on the event because the playback runs after the
	# turn, when the world they were asked on is gone.
	#
	# `path` is the one thing a playback cannot recover for itself. By the time
	# [AIPlayback] reaches this event the world is already at the end of the
	# turn, so re-deriving the route with [method WalkMap.path] would derive it
	# against the wrong state -- the same reason every other event carries what
	# it needs. It is the walk's own [member MoveResult.route]: source first,
	# in travel order, truncated where the walk actually stopped.
	var route: Array = []
	for index: int in moved.route:
		route.append(index)
	ctx.emit(AIEvent.make("move", unit.slot, sx, sy, moved.x, moved.y,
		moved.cost, "", {"steps": moved.steps, "facing": moved.facing,
			"path": route, "events": moved.events.duplicate(true),
			"seen_source": moved.seen_source,
			"seen_destination": moved.seen_destination}))


## `aExecuteWarp(sx, sy, tx, ty, 1)` `0x0046EF50`, reduced to its state.
##
## The routine plays a jump animation, clears the source cell's unit id,
## writes the mover's into the target's and moves the record. Its one other
## arm fires when the target carries a mine, which no shipped cell does --
## docs/23 section 7.1 measures the byte as 255 in all 184162 of them -- so it
## is named here and not simulated.
static func execute_warp(ctx: AIContext, unit: UnitState, tx: int,
		ty: int) -> bool:
	var source: int = ctx.map.index_of(unit.x, unit.y)
	if ctx.map.unit_at(source) != unit.slot:
		# "no unit on start path field" -- the routine's own refusal.
		ctx.refuse("warp from a cell that does not hold the mover")
		return false
	var target: int = ctx.map.index_of(tx, ty)
	if ctx.map.obstacle_at(target) == MapState.OBSTACLE_MINE:
		ctx.refuse("a warp onto a mine is not simulated")
	ctx.map.set_unit(source, MapState.NO_UNIT)
	ctx.map.set_unit(target, unit.slot)
	ctx.state[source] = AIOverlay.STATE_RESET
	ctx.emit(AIEvent.make("warp", unit.slot, unit.x, unit.y, tx, ty))
	unit.x = tx
	unit.y = ty
	# `0x0046F144` -- the fog is rebuilt for the warping unit's **own** player
	# on every warp its mine arm did not kill it on (docs/22 section 9.4).
	Visibility.build(ctx.map, ctx.units, ctx.utab, unit.player,
		ctx.turn.human_count(), ctx.turn.mode)
	return true
