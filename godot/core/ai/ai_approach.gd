class_name AIApproach
extends RefCounted

## `0x0040ADC0(target, *best, myUnitIndex)` -- stand *next to* a cell.
##
## The eight neighbours of the target, and for a **large** mover the eight
## neighbours of each of those instead: a second ring, with the first ring
## itself never a candidate.  A cell already holding the mover returns at once
## with [constant OWN_CELL_SCORE].
##
## **The two rings do not break ties the same way, and the asymmetry is the
## engine's**: the small path accepts `mp >= best`, so a later cell wins, and
## the large path requires `mp > best`, so the incumbent keeps it. `jl` against
## `jle`, one instruction apart in the listing.

## The height difference an approach cell may have from the target, after the
## divide by 1600. Looser than the movement rule's 1.
const CLIMB_MAX: int = 2
## What the scan returns for the cell the mover is already standing on.
const OWN_CELL_SCORE: int = 10000


## Returns `{"cell": int, "best": int}`; `cell` is -1 for no candidate.
static func pick(ctx: AIContext, target: int, best: int,
		my_slot: int) -> Dictionary:
	var mover: UnitState = ctx.unit_or_null(my_slot)
	if mover == null:
		return {"cell": -1, "best": best}
	var large: bool = ctx.utab.unit_size(mover.type_id) \
		== UnitTypeTable.SIZE_LARGE
	var tx: int = ctx.cell_x(target)
	var ty: int = ctx.cell_y(target)
	var target_height: int = ctx.map.height_at(target)
	var found: int = -1
	var running: int = best

	for dir: int in range(AIScore.DIR_DX.size()):
		var nx: int = tx + AIScore.DIR_DX[dir]
		var ny: int = ty + AIScore.DIR_DY[dir]
		if not ctx.map.in_bounds(nx, ny):
			continue
		if not large:
			var one: Dictionary = _candidate(ctx, nx, ny, target_height,
				running, my_slot, false)
			if DictRead.as_bool(one["own"]):
				return {"cell": ctx.map.index_of(nx, ny),
					"best": OWN_CELL_SCORE}
			running = DictRead.as_int(one["best"])
			if DictRead.as_int(one["cell"]) >= 0:
				found = DictRead.as_int(one["cell"])
			continue
		for inner: int in range(AIScore.DIR_DX.size()):
			var mx: int = nx + AIScore.DIR_DX[inner]
			var my: int = ny + AIScore.DIR_DY[inner]
			if not ctx.map.in_bounds(mx, my):
				continue
			var two: Dictionary = _candidate(ctx, mx, my, target_height,
				running, my_slot, true)
			if DictRead.as_bool(two["own"]):
				return {"cell": ctx.map.index_of(mx, my),
					"best": OWN_CELL_SCORE}
			running = DictRead.as_int(two["best"])
			if DictRead.as_int(two["cell"]) >= 0:
				found = DictRead.as_int(two["cell"])
	return {"cell": found, "best": running}


static func _candidate(ctx: AIContext, x: int, y: int, target_height: int,
		best: int, my_slot: int, large: bool) -> Dictionary:
	var index: int = ctx.map.index_of(x, y)
	var standing: int = ctx.map.unit_at(index)
	if standing == my_slot:
		return {"cell": index, "best": OWN_CELL_SCORE, "own": true}
	if standing != MapState.NO_UNIT:
		return {"cell": -1, "best": best, "own": false}
	if IncInt.climb_quotient(ctx.map.height_at(index) - target_height) \
			> CLIMB_MAX:
		return {"cell": -1, "best": best, "own": false}
	var left: int = ctx.mp_left[index]
	# The one place the two rings differ: `jle` for a large mover, `jl` for a
	# small one.
	if left < best or (large and left == best):
		return {"cell": -1, "best": best, "own": false}
	var marker: int = ctx.state[index]
	if marker != MoveMapResult.STATE_REACHABLE \
			and marker != MoveMapResult.STATE_WARP:
		return {"cell": -1, "best": best, "own": false}
	return {"cell": index, "best": left, "own": false}
