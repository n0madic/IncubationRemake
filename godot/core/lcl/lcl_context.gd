class_name LclContext
extends RefCounted

## The world one mission program can reach, with **typed** members.
##
## Deliberately not a `Dictionary`: reading `context.state` out of one yields a
## `Variant`, and `unsafe_call_argument` is an error project-wide, so every one
## of the sixty command handlers would need a narrowing local first. The class
## is that narrowing, once.
##
## Deliberately **not** the whole battle map either. The language touches four
## cell fields (docs/20 section 7.4), the unit array, the turn, the player, the
## twelve game-control slots and the next-map name. What it does not touch --
## fog, heat, ammunition beyond `SetAmmoForUnit`, the move overlay -- is
## reachable through `state` and `units` because those are the world's own
## objects, and the interpreter simply never writes them.

var state: MapState
var units: Dictionary = {}
var types: UnitTypeTable
var turn: TurnState
var control: GameControl
var rng: IncRandom
var crand: CRandom
## docs/20 section 7.4 -- what `GetPlayer` answers and what `InsertUnit`'s fog
## event names. The host's player argument for this invocation, which is not
## always [member TurnState.current_player]: `NEXT PLAYER` passes the player
## whose turn is *starting*.
var player: int = 0
## `EnterNameOfNextMap` writes it; the campaign layer reads it.
var next_map: String = ""


static func create(map_state: MapState, unit_map: Dictionary,
		unit_types: UnitTypeTable, turn_state: TurnState,
		game_control: GameControl, random: IncRandom, c_random: CRandom,
		host_player: int, map_name: String) -> LclContext:
	var context: LclContext = LclContext.new()
	context.state = map_state
	context.units = unit_map
	context.types = unit_types
	context.turn = turn_state
	context.control = game_control
	context.rng = random
	context.crand = c_random
	context.player = host_player
	context.next_map = map_name
	return context


func in_bounds(x: int, y: int) -> bool:
	return state.in_bounds(x, y)


func index(x: int, y: int) -> int:
	return state.index_of(x, y)


## The live unit standing on a cell, or `null`.
func unit_on(x: int, y: int) -> UnitState:
	if not state.in_bounds(x, y):
		return null
	var slot: int = state.unit_at(state.index_of(x, y))
	if slot < 0 or not units.has(slot):
		return null
	var unit: UnitState = units[slot]
	return unit if unit.is_alive() else null


func free_cell(x: int, y: int) -> bool:
	return state.in_bounds(x, y) and unit_on(x, y) == null


func kill(unit: UnitState) -> void:
	unit.hp = 0
	if state.in_bounds(unit.x, unit.y):
		var at: int = state.index_of(unit.x, unit.y)
		if state.unit_at(at) == unit.slot:
			state.set_unit(at, MapState.NO_UNIT)


## docs/10 section 5 -- the unit array is 200 fixed records.
const UNIT_SLOTS: int = 200


## The lowest slot holding no **live** unit.
##
## **UNVERIFIED.** docs/20 section 7.4 records everything `0x00479CF0` writes
## and not which index it writes it to; the array is 200 fixed records, so the
## lowest free one is the natural reading and it is what both implementations
## use. See [method spawn] for why the rule matters more than the answer.
func free_slot() -> int:
	for slot: int in range(UNIT_SLOTS):
		if not units.has(slot):
			return slot
		var unit: UnitState = units[slot]
		if not unit.is_alive():
			return slot
	return UNIT_SLOTS - 1


## Every cell whose action point is in the inclusive range.
func cells_with_actpt(low: int, high: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for i: int in range(state.cell_count()):
		var value: int = state.action_point_at(i)
		if low <= value and value <= high:
			out.append(i)
	return out


## `0x00479CF0` with `exact == 0` -- the form both LCL spawn commands use.
##
## docs/20 section 7.4: an occupied target cell makes it search up to eight
## neighbours, `rank * 12` goes into **both** the experience points and the
## skill-point pool, and an empty name is filled from the unit type's
## description string.
##
## The slot is the **lowest in 0..199 holding no live unit**, which is
## [method free_slot]'s rule and what `inclib/lcl_runtime.py` uses. "One past
## the highest key" would have been simpler and wrong: a `.lev` carries named
## slots whose hit points are zero -- `_C_140` has two -- so the two
## implementations would have picked 10 and 12 for the same spawn, and nothing
## downstream would have said so.
func spawn(spawn_player: int, type_id: int, name: String, rank: int,
		pool_flag: int, x: int, y: int) -> UnitState:
	var tx: int = -1
	var ty: int = -1
	if free_cell(x, y):
		tx = x
		ty = y
	else:
		for dy: int in [-1, 0, 1]:
			for dx: int in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				if tx < 0 and free_cell(x + dx, y + dy):
					tx = x + dx
					ty = y + dy
	if tx < 0:
		return null
	var unit: UnitState = UnitState.new()
	unit.slot = free_slot()
	unit.player = spawn_player
	unit.type_id = type_id
	unit.x = tx
	unit.y = ty
	unit.hp = types.hp_max(type_id)
	if unit.hp == 0:
		# `placed` is `hp != 0`, so a type with no row -- or one whose `hp_max`
		# is 0 -- would be an unplaced slot the moment it is written. One hit
		# point keeps it a unit; the exact value is for a native capture to
		# settle, not this model to guess.
		unit.hp = 1
	unit.ep = rank * 12
	unit.tp = rank * 12
	unit.pool_flag = pool_flag
	# `has` first: [method UnitTypeTable.description] answers `"type %d"` for an
	# id it does not know, and `inclib/lcl_runtime.py` answers `""`. An
	# `InsertUnit` naming a type `Info.lcl` never defines would otherwise give
	# the two models different rosters.
	if name != "":
		unit.name = name
	elif types.has(type_id):
		unit.name = types.description(type_id)
	else:
		unit.name = ""
	unit.turn_start_x = tx
	unit.turn_start_y = ty
	units[unit.slot] = unit
	state.set_unit(state.index_of(tx, ty), unit.slot)
	return unit
