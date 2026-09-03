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
	return UnitState.free_cell(state, units, x, y)


func kill(unit: UnitState) -> void:
	UnitState.remove(state, turn, unit)


## The lowest slot holding no **live** unit -- [method UnitState.free_slot],
## which is where the rule lives now that the interpreter is no longer its only
## caller.  See [method spawn] for why the rule matters more than the answer.
func free_slot() -> int:
	return UnitState.free_slot(units)


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
## The routine is [method UnitState.generate]; what belongs here is only the
## flag the LCL callers pass.  The slot rule it carries matters more than the
## answer: a `.lev` holds named slots whose hit points are zero -- `_C_140` has
## two -- so "one past the highest key" would have picked 10 and 12 for the
## same spawn, and nothing downstream would have said so.
func spawn(spawn_player: int, type_id: int, name: String, rank: int,
		pool_flag: int, x: int, y: int) -> UnitState:
	return UnitState.generate(state, units, types, spawn_player, type_id, name,
		rank, pool_flag, x, y, false)
