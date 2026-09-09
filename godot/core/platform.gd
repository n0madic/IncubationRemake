class_name Platform
extends RefCounted

## `aPlayPlatformSequence` (`0x00412A00`) as it changes the world, and the
## relocation it is built on -- docs/20 section 7.4, docs/22 section 9.3.
##
## Two things the script world cannot hold are here rather than in
## [LclInterpreter]: the relocation's **visibility pass**, and its **order**
## against the cell copy. `0x0047AD90` moves one unit cell to cell -- the
## map's unit index, `+0x42`/`+0x43`, the 3D object -- and then has the unit
## look around from its new cell (`aBuildVisibleMapForUnit` at `0x0047AF53`,
## a writing pass). The ride relocates every rider that way **before** any
## cell is copied (`0x00412F9A` in the unit loop, `0x00412FFB` onwards for
## the copy), so a rider's pass sees the destination block's *old* heights.
## Measured in `tools/turn_gold.py`'s `platform` phase, whose `--check` gates
## on this order and reports whether the other one would also have agreed.
##
## The pass is an exception to the rule that the interpreter records fog and
## does not perform it: a rebuild deferred to [World] would run after the
## copy, and the difference is observable.

## docs/20 section 7.4 -- `Platform`'s direction encoding, 0=N 1=W 2=S 3=E.
## `Barrier` and `FixedStatue` spell the same axis the other way round; the
## interpreter keeps both tables side by side for that reason.
const DIR_DX: Array[int] = [0, -1, 0, 1]
const DIR_DY: Array[int] = [-1, 0, 1, 0]
## The control-map type the vacated cells are left as (docs/10 section 4.2).
const CTRL_TYPE_DEEP_HOLE: int = 4


## `0x0047AD90` -- one unit, cell to cell, looking around afterwards.
##
## Returns the pass's answer, and `false` without moving anything when the
## target is off the map or occupied -- the engine refuses both with an error
## (`aUnitMap.cpp:5580`, `5590`) and leaves the unit where it was.
static func relocate(state: MapState, units: Dictionary, utab: UnitTypeTable,
		unit: UnitState, tx: int, ty: int, human_players: int,
		game_mode: int) -> bool:
	if not state.in_bounds(tx, ty):
		return false
	var target: int = state.index_of(tx, ty)
	if state.unit_at(target) != MapState.NO_UNIT:
		return false
	UnitState.vacate(state, utab, unit, unit.x, unit.y)
	UnitState.occupy(state, utab, unit, tx, ty)
	unit.x = tx
	unit.y = ty
	return Visibility.look_from(state, units, utab, unit, tx, ty,
		human_players, game_mode)


## The ride: riders first, one at a time, then the cells. Returns how many
## cells were copied, which is what the `platform` event carries.
##
## The block is walked **x outer, y inner** (`0x00412AAA`: `ebx` runs
## `x-1..x+1` and `edi` `y-1..y+1` inside it), and that is the order the
## riders move and look in.
static func ride(state: MapState, units: Dictionary, utab: UnitTypeTable,
		x: int, y: int, direction: int, dist: int, human_players: int,
		game_mode: int) -> int:
	if direction < 0 or direction >= DIR_DX.size():
		return 0
	var dx: int = DIR_DX[direction] * dist
	var dy: int = DIR_DY[direction] * dist
	var block: Array[Vector2i] = []
	for ox: int in [-1, 0, 1]:
		for oy: int in [-1, 0, 1]:
			block.append(Vector2i(x + ox, y + oy))
	var riders: Array[UnitState] = []
	for cell: Vector2i in block:
		if not state.in_bounds(cell.x, cell.y):
			continue
		var slot: int = state.unit_at(state.index_of(cell.x, cell.y))
		if slot != MapState.NO_UNIT and units.has(slot):
			riders.append(units[slot])
	# A rider whose destination is off the map or already occupied is refused
	# by [method relocate] and stays where it stands -- the engine reports an
	# error there (`aUnitMap.cpp:5590`), and what it does next is unmeasured
	# -- so its source cell keeps its link below rather than orphaning it.
	for rider: UnitState in riders:
		var _saw: bool = relocate(state, units, utab, rider, rider.x + dx,
			rider.y + dy, human_players, game_mode)
	var moved: int = 0
	for cell: Vector2i in block:
		var tx: int = cell.x + dx
		var ty: int = cell.y + dy
		if not (state.in_bounds(cell.x, cell.y) and state.in_bounds(tx, ty)):
			continue
		var src: int = state.index_of(cell.x, cell.y)
		var dst: int = state.index_of(tx, ty)
		state.set_height(dst, state.height_at(src))
		state.set_field_type(dst, state.field_type_at(src))
		state.set_field_type(src, CTRL_TYPE_DEEP_HOLE)
		moved += 1
	return moved
