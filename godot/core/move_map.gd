class_name MoveMap
extends RefCounted

## `aBuildMoveMap` (`0x00430A40`), transcribed from docs/23 section 7.
##
## Four properties are deliberate.  Each of them looks like a bug, each of them
## is what the engine does, and each has a named test behind it so that nobody
## quietly "fixes" it:
##
## 1. **The visited test is `mp_left == 0`, not a visited set.**  The engine
##    stores the movement points left on arrival in `cell[+0x0C]`, which starts
##    at zero, and treats zero as "not yet reached".  A cell entered with
##    exactly zero left stays writable, so a later wave can overwrite it.  This
##    is neither Dijkstra nor first-write-wins; it is
##    first-write-wins-except-zero, and 20544 shipped cells exercise it.
## 2. **The fill is 4-connected.**  `0x004308C0` is called with its diagonal
##    flag clear at the only call site.  Path *reconstruction* is 8-connected
##    and lives in [WalkMap]; that asymmetry is the original's, and it is
##    measured rather than argued about -- 2772 diagonal steps across 4587
##    corpus paths, and not one path leaving the region this fill marked.  Do
##    not "fix" either side to match the other.
## 3. **`any_friendly_blocked` says only that the fill never ran.**  It is the
##    scratch left by the last of *eight* directions, and the last four are the
##    refused diagonals, whose failure path clears it -- so any fill that runs
##    one wave comes back false, and true survives only from the write before
##    the loop.  Native on `_C_141`: true on exactly the 26 fills of the 74
##    whose mover had no movement points.  docs/23 section 7.6.  It is
##    reproduced, and it must not be given a meaning.
## 4. **The start cell is seeded before the shield refusal, not after.**
##    docs/23 section 7.1 has it the other way round; a native capture with a
##    shield written into the mover's own cell comes back with that cell marked
##    and holding the mover's movement points.  The `special` refusal really is
##    first: it marks nothing.
##
## `mp` and `mp_allowance` are **inputs**.  The fill spends the unit's current
## `+0x15`, and the allowance from `0x00475160` feeds only the ladder-to-ladder
## step -- which fires on no shipped cell, because no shipped cell is a Ladder.

## docs/23 section 7.3 -- the four orthogonal directions, in the order
## `0x004308C0` numbers them.
const DIR_DX: Array[int] = [0, -1, 0, 1]
const DIR_DY: Array[int] = [1, 0, -1, 0]

## How many directions `0x00430DC8` actually loops over.  The last four reach
## no cell -- `Step` refuses a diagonal because the only call site pushes a
## literal 0 for `allowDiagonal` (`0x00430BBD`) -- but they still take the
## caller to `0x00430C64`, which writes `anyFriendlyBlocked`.  Every cell's
## eight directions therefore end with that flag cleared.
const DIRECTIONS: int = 8

## docs/23 section 7.2 -- two ping-ponged arrays of 2003 entries; writing entry
## 2000 is a hard error at `0x00430DB8`.  The largest wave the whole corpus
## produces is 49.
const QUEUE_HARD_LIMIT: int = 2000

## docs/10 section 4.5 -- a warp destination's field types, and the action-point
## band it may not have: 0x50..0x59 are the multiplayer victory points.
const WARP_FIELD_TYPES: Array[int] = [0, 1, 8]
const WARP_AP_LOW: int = 0x50
const WARP_AP_HIGH: int = 0x59
## docs/23 section 7.5 -- the three ranges `0x00475380` returns.
const WARP_RANGE_JET_PACK: int = 5
const WARP_RANGE_SPECIAL: int = 7

## docs/21 section 2 -- the ladder, and the impassable delay.
const LADDER_TYPE: int = 8
const IMPASSABLE: int = 255

## `0x0047A410` -- the eight neighbours a large unit needs clear.
const CLEAR_DX: Array[int] = [-1, 0, 1, -1, 1, -1, 0, 1]
const CLEAR_DY: Array[int] = [-1, -1, -1, 0, 0, 1, 1, 1]
const CLEARANCE_FIELD_TYPES: Array[int] = [0, 1]


static func build(state: MapState, units: Dictionary, utab: UnitTypeTable,
		ctab: CtrlMapTable, unit_slot: int, pass_friendlies: bool,
		mp: int, mp_allowance: int) -> MoveMapResult:
	var mover: UnitState = units[unit_slot]
	var n: int = state.cell_count()
	var overlay: PackedByteArray = PackedByteArray()
	overlay.resize(n)
	var mp_left: PackedInt32Array = PackedInt32Array()
	mp_left.resize(n)

	# 7.1, in the original's order.
	var special: int = utab.special(mover.type_id)
	if UnitTypeTable.SPECIAL_CANNOT_MOVE.has(special):
		# Returns before touching the caller's scratch, and marks nothing.
		return MoveMapResult.create(state.width, state.height, mp, overlay,
			mp_left, false, 0)

	var blocked: bool = true
	var start: int = state.index_of(mover.x, mover.y)
	mp_left[start] = mp
	overlay[start] = MoveMapResult.STATE_REACHABLE

	if state.obstacle_at(start) == MapState.OBSTACLE_SHIELD:
		# A unit standing inside a shield cannot move at all.
		return MoveMapResult.create(state.width, state.height, mp, overlay,
			mp_left, false, 0)

	var waves: int = 0
	if mp > 0:
		var flood: Dictionary = _flood(state, units, utab, ctab, mover,
			pass_friendlies, mp, mp_allowance, overlay, mp_left, blocked)
		blocked = DictRead.as_bool(flood["blocked"])
		waves = DictRead.as_int(flood["waves"])

	_warp_pass(state, utab, mover, mp, overlay)
	return MoveMapResult.create(state.width, state.height, mp, overlay, mp_left,
		blocked, waves)


static func _flood(state: MapState, units: Dictionary, utab: UnitTypeTable,
		ctab: CtrlMapTable, mover: UnitState, pass_friendlies: bool, mp: int,
		mp_allowance: int, overlay: PackedByteArray, mp_left: PackedInt32Array,
		blocked_in: bool) -> Dictionary:
	var blocked: bool = blocked_in
	var waves: int = 0
	# `(x, y, mpLeft)` packed three to an entry, as the original's queue is.
	var wave: PackedInt32Array = PackedInt32Array([mover.x, mover.y, mp])
	var large: bool = utab.unit_size(mover.type_id) == UnitTypeTable.SIZE_LARGE

	for _pass: int in range(mp):
		if wave.is_empty():
			break
		waves += 1
		var next_wave: PackedInt32Array = PackedInt32Array()
		var at: int = 0
		while at < wave.size():
			var x: int = wave[at]
			var y: int = wave[at + 1]
			var mp_here: int = wave[at + 2]
			at += 3
			var here: int = state.index_of(x, y)
			var from_type: int = state.field_type_at(here)
			var from_height: int = state.height_at(here)
			for dir: int in range(DIRECTIONS):
				if dir >= DIR_DX.size():
					# A refused diagonal.  It reaches no cell, which is why
					# the fill is 4-connected, but its failure path clears the
					# flag -- so it is not a direction that can be skipped.
					blocked = false
					continue
				var nx: int = x + DIR_DX[dir]
				var ny: int = y + DIR_DY[dir]
				if not state.in_bounds(nx, ny):
					# `Step` failed: `to` is never dereferenced on this path,
					# and the scratch takes the "nothing in the way" value.
					blocked = false
					continue
				var to: int = state.index_of(nx, ny)
				var ok: bool = mp_left[to] == 0
				var occupant: int = state.unit_at(to)
				if occupant != MapState.NO_UNIT and not units.has(occupant):
					# `0x00430C3C` -- `aGetUnitMapElementPtr` answers NULL for
					# a slot the unit map has no record for, and the fill then
					# skips the neighbour outright without touching the
					# scratch flag.  This used to index `units[occupant]` and
					# crash; the Python twin used to default the player to 0.
					# Both were wrong, and no shipped cell reaches the arm.
					continue
				var occupancy: Dictionary = _occupancy(state, units, mover, to,
					ok, pass_friendlies, blocked)
				blocked = DictRead.as_bool(occupancy["blocked"])
				ok = DictRead.as_bool(occupancy["ok"])
				if large and not _clearance(state, mover, nx, ny):
					ok = false
				var obstacle: int = state.obstacle_at(to)
				if obstacle == MapState.OBSTACLE_FIRE:
					ok = false
				if mover.player != UnitState.PLAYER_ALIEN \
						and obstacle == MapState.OBSTACLE_MINE:
					ok = false
				if not ok:
					continue

				var to_type: int = state.field_type_at(to)
				var cost: int = ctab.delay(to_type)
				if to_type == LADDER_TYPE and from_type == LADDER_TYPE:
					# Ladder to ladder: a whole turn's movement, and the height
					# test is skipped -- which is what a ladder is for.
					cost += mp_allowance - 1
				elif cost != IMPASSABLE:
					if IncInt.climb_quotient(
							state.height_at(to) - from_height) > 1:
						cost = IMPASSABLE
				if mp_here <= cost or cost == IMPASSABLE:
					continue
				var new_mp: int = mp_here - cost - 1
				if next_wave.size() / 3 >= QUEUE_HARD_LIMIT:
					# The original aborts the process here.  A remake must not,
					# so this stops the fill and says so -- but it must not be
					# an `assert` either: Godot strips those from an exported
					# release build, which is the build docs/93 requires be
					# launched after every change, and the failure would then
					# be a silently truncated overlay.  `inclib/movemap.py`
					# raises at the same point.  **Uncovered**: the largest
					# wave the whole corpus produces is 49, and provoking 2000
					# needs a map about a thousand fields across.
					push_error("move map: a wave reached %d entries; the "
						% QUEUE_HARD_LIMIT
						+ "original aborts at 0x00430DB8")
					return {"blocked": blocked, "waves": waves}
				mp_left[to] = new_mp
				overlay[to] = MoveMapResult.STATE_REACHABLE
				next_wave.append(nx)
				next_wave.append(ny)
				next_wave.append(new_mp)
		wave = next_wave
	return {"blocked": blocked, "waves": waves}


## docs/23 section 7.3, transcribed literally including the scratch writes.
static func _occupancy(state: MapState, units: Dictionary, mover: UnitState,
		to: int, ok_in: bool, pass_friendlies: bool,
		blocked_in: bool) -> Dictionary:
	var ok: bool = ok_in
	var blocked: bool = blocked_in
	var occupant: int = state.unit_at(to)
	var hidden: bool = false
	if occupant != MapState.NO_UNIT and units.has(occupant):
		var other: UnitState = units[occupant]
		hidden = other.is_hidden()
	if not ok or occupant == MapState.NO_UNIT or hidden:
		# Nothing in the way -- and a hidden unit counts as nothing, because
		# the computer does not cheat about what it has not spotted.
		blocked = false
	else:
		if not pass_friendlies:
			ok = false
		var other: UnitState = units[occupant]
		if other.player == mover.player:
			blocked = true
		else:
			# `0x00430C60` -- an enemy clears `ok` and **leaves the flag
			# alone**; only the same-player arm at `0x00430C58` writes it.
			ok = false
	if blocked and occupant == mover.slot:
		# The mover's own cell is always passable.
		blocked = false
		ok = true
	return {"ok": ok, "blocked": blocked}


## `0x0047A410` -- all eight neighbours must exist, be empty or hold the mover,
## have field type 0 or 1, be at exactly the same height, and carry no fire.
static func _clearance(state: MapState, mover: UnitState,
		x: int, y: int) -> bool:
	var here: int = state.index_of(x, y)
	var want_height: int = state.height_at(here)
	for i: int in range(CLEAR_DX.size()):
		var nx: int = x + CLEAR_DX[i]
		var ny: int = y + CLEAR_DY[i]
		if not state.in_bounds(nx, ny):
			return false
		var index: int = state.index_of(nx, ny)
		var occupant: int = state.unit_at(index)
		if occupant != MapState.NO_UNIT and occupant != mover.slot:
			return false
		if not CLEARANCE_FIELD_TYPES.has(state.field_type_at(index)):
			return false
		if state.height_at(index) != want_height:
			return false
		if state.obstacle_at(index) == MapState.OBSTACLE_FIRE:
			return false
	return true


## `0x00475380` -- docs/10 section 4.5 and docs/23 section 7.5.
static func warp_range(mover: UnitState, utab: UnitTypeTable, mp: int) -> int:
	# The Jet Pack path additionally needs movement points left, which is why a
	# unit that has spent its turn cannot warp with it.
	if mover.has_jet_pack() and mp != 0:
		return WARP_RANGE_JET_PACK
	if utab.special(mover.type_id) == UnitTypeTable.SPECIAL_CAN_WARP:
		return WARP_RANGE_SPECIAL
	return 0


## `0x00430EE0`.  docs/10 section 4.5 lists five acceptance tests; there is a
## sixth, established from the live engine: **a cell the fill already marked
## keeps its 10.**  The test is on `cell[+0x00]`, not on `cell[+0x0C]` -- nine
## captured cells marked with zero movement points left, which the fill's own
## visited test cannot tell from unvisited, kept their 10 as well.
static func _warp_pass(state: MapState, utab: UnitTypeTable,
		mover: UnitState, mp: int, overlay: PackedByteArray) -> void:
	var reach: int = warp_range(mover, utab, mp)
	if reach == 0:
		return
	for y: int in range(state.height):
		for x: int in range(state.width):
			var index: int = state.index_of(x, y)
			if overlay[index] == MoveMapResult.STATE_REACHABLE:
				continue
			if state.unit_at(index) != MapState.NO_UNIT:
				continue
			if not WARP_FIELD_TYPES.has(state.field_type_at(index)):
				continue
			var ap: int = state.action_point_at(index)
			if ap >= WARP_AP_LOW and ap <= WARP_AP_HIGH:
				continue
			var obstacle: int = state.obstacle_at(index)
			if obstacle == MapState.OBSTACLE_FIRE \
					or obstacle == MapState.OBSTACLE_MINE:
				continue
			if distance(mover.x, mover.y, x, y) > reach:
				continue
			overlay[index] = MoveMapResult.STATE_WARP


## `aGetDistance` (`0x0044AE10`): `floor(sqrt(dx*dx + dy*dy))` in map fields.
## Euclidean with a floor, not Chebyshev -- docs/22 section 4.
static func distance(x0: int, y0: int, x1: int, y1: int) -> int:
	var dx: int = x0 - x1
	var dy: int = y0 - y1
	return int(sqrt(float(dx * dx + dy * dy)))
