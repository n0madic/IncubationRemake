class_name WalkMap
extends RefCounted

## `aWalkMoveMap` (`0x004305E0`), transcribed from docs/23 section 8.
##
## Gradient **ascent** from the target back to the source over the movement
## points [MoveMap] left behind, since the source holds the maximum.
##
## **The 4/8 asymmetry is the original's and is now measured, not warned
## about.**  The fill costs only orthogonal steps; this walks eight directions
## and takes diagonals it never paid for.  Over the whole corpus that produces
## 2772 diagonal steps in 4587 reconstructed paths -- and **not one** of those
## paths leaves the region the fill highlighted, because every cell the walk
## can step onto has to carry movement points, and only the fill writes those.
## `tools/movemap_runtime.py --check` is where that number comes from.
##
## Four transcription details a paraphrase loses:
##
## 1. Acceptance is `value >= best`, so **later directions win ties** and the
##    evaluation order 0..7 is part of the answer.
## 2. The diagonal dock is `value > 1 ? value - 1 : 0` on the value already
##    shifted by four, so it breaks a tie without outranking a whole point.
## 3. The comparison is 16-bit in the original (`cmp ax, word [esp+0x14]`),
##    which is why the pointer the engine leaves in the high half of `EAX`
##    cannot reach the answer.  Masking here says so out loud.
## 4. The budget is checked **before** each step, and a walk that exhausts it
##    fails with the overlay left mid-flight -- the final sweep does not run.
##    That is what a target the fill never marked produces: the ascent wanders
##    between cells that all hold zero until the 300 steps are gone.

## `cell[+0x00]` while a path stands on it -- a fourth overlay value alongside
## `MoveMapResult.STATE_REACHABLE` and `STATE_WARP`, and the only one that
## survives the routine's own final sweep.
const STATE_PATH: int = 100
## What that sweep writes over every other cell.  It is the engine's reset
## value, not zero.
const STATE_SWEPT: int = 1

## `0x00430603` -- the step budget.
const BUDGET: int = 300

## `0x00430A20` -- all eight directions.  The first four are [MoveMap]'s;
## `aWalkMoveMap` is the only caller that enables the rest.
const DIR_DX: Array[int] = [0, -1, 0, 1, 1, -1, 1, -1]
const DIR_DY: Array[int] = [1, 0, -1, 0, -1, 1, 1, -1]
const FIRST_DIAGONAL: int = 4

## `0x004303E0` -- the two orthogonal directions bracketing each diagonal, as
## indices into [constant DIR_DX].  Both must be enterable, so a path never
## cuts a corner past a wall.
const CORNER_A: Array[int] = [2, 0, 0, 2]
const CORNER_B: Array[int] = [3, 1, 3, 1]

## `0x00430677` -- the gradient is compared in sixteenths, in sixteen bits.
const GRADIENT_SHIFT: int = 4
const GRADIENT_MASK: int = 0xFFFF


## Reconstructs the path from `(sx, sy)` to `(tx, ty)` over `result`.
##
## Returns `{"ok": bool, "steps": int, "blocked": int, "path": PackedInt32Array,
## "state": PackedByteArray}`.  `path` runs target first, source last -- the
## order the engine marks them in.  `state` is empty when `ok` is false,
## because then the engine's sweep never ran either.
static func path(state: MapState, units: Dictionary, ctab: CtrlMapTable,
		result: MoveMapResult, sx: int, sy: int, tx: int,
		ty: int) -> Dictionary:
	if not state.in_bounds(tx, ty) or not state.in_bounds(sx, sy):
		return _failed(0, 0, PackedInt32Array(), "off the map")

	var walked: PackedInt32Array = PackedInt32Array([state.index_of(tx, ty)])
	var steps: int = 0
	var blocked: int = 0
	var budget: int = BUDGET
	var x: int = tx
	var y: int = ty
	var source_unit: int = state.unit_at(state.index_of(sx, sy))
	var mp_left: PackedInt32Array = result.mp_left()

	while x != sx or y != sy:
		if budget <= 0:
			return _failed(steps, blocked, walked, "budget exhausted")
		var here: int = state.index_of(x, y)
		var best: int = (mp_left[here] << GRADIENT_SHIFT) & GRADIENT_MASK
		var best_dir: int = -1
		var bx: int = -1
		var by: int = -1
		for direction: int in range(DIR_DX.size()):
			var nx: int = x + DIR_DX[direction]
			var ny: int = y + DIR_DY[direction]
			if not state.in_bounds(nx, ny):
				continue
			var to: int = state.index_of(nx, ny)
			if IncInt.climb_quotient(
					state.height_at(to) - state.height_at(here)) > 1:
				continue
			if direction >= FIRST_DIAGONAL:
				var corner: int = direction - FIRST_DIAGONAL
				if not _corner_open(state, ctab, x, y, CORNER_A[corner],
						CORNER_B[corner]):
					continue
			var value: int = (mp_left[to] << GRADIENT_SHIFT) & GRADIENT_MASK
			if direction >= FIRST_DIAGONAL:
				value = value - 1 if value > 1 else 0
			if value < best:
				continue
			best = value
			bx = nx
			by = ny
			best_dir = direction
		if best_dir < 0:
			# The engine raises CHECK("no direction found") and returns FALSE
			# without sweeping.
			return _failed(steps, blocked, walked, "no direction found")
		steps += 1
		var index: int = state.index_of(bx, by)
		walked.append(index)
		var standing: int = state.unit_at(index)
		if standing != MapState.NO_UNIT and standing != source_unit:
			blocked += 1
		budget -= 1
		x = bx
		y = by

	if budget == 0:
		# Arriving on the very last step still fails: the test is on the
		# budget, not on having arrived.
		return _failed(steps, blocked, walked, "budget exhausted")

	var overlay: PackedByteArray = PackedByteArray()
	overlay.resize(state.cell_count())
	overlay.fill(STATE_SWEPT)
	for index: int in walked:
		overlay[index] = STATE_PATH
	return {
		"ok": true,
		"steps": steps,
		"blocked": blocked,
		"path": walked,
		"state": overlay,
		"reason": "",
	}


static func _failed(steps: int, blocked: int, walked: PackedInt32Array,
		reason: String) -> Dictionary:
	return {
		"ok": false,
		"steps": steps,
		"blocked": blocked,
		"path": walked,
		"state": PackedByteArray(),
		"reason": reason,
	}


## `0x00479C60(x, y, unitIndex)`, with the `0xFFFF` the walk passes.
##
## docs/23 section 8 describes this as the routine that treats `delay == 255`
## as not enterable, which is true and incomplete: it also refuses an occupied
## cell and both blocking obstacles.  Because the index it is asked with
## matches no slot, the occupancy test here means "must be empty".
static func is_enterable(state: MapState, ctab: CtrlMapTable, x: int,
		y: int) -> bool:
	if not state.in_bounds(x, y):
		return false
	var index: int = state.index_of(x, y)
	if state.unit_at(index) != MapState.NO_UNIT:
		return false
	if not ctab.is_enterable(state.field_type_at(index)):
		return false
	var obstacle: int = state.obstacle_at(index)
	return obstacle != MapState.OBSTACLE_FIRE \
		and obstacle != MapState.OBSTACLE_MINE


static func _corner_open(state: MapState, ctab: CtrlMapTable, x: int, y: int,
		first: int, second: int) -> bool:
	for direction: int in [first, second]:
		if not is_enterable(state, ctab, x + DIR_DX[direction],
				y + DIR_DY[direction]):
			return false
	return true
