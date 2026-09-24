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
## `0x00406F20` plus `0x0042F410`: the cells the object standing on a cell
## covers, which is what `CrushWall` crushes (docs/42 section 8.2). Authored,
## so it comes straight off [MapResource]; empty for a hand-built context, and
## then every reader falls back to the cell it was given.
var object_cells: Dictionary[int, PackedInt32Array] = {}
## Each `.lev` special object's own footprint, by its table id -- the cells
## `0x0042F410` marks for **that** object, which is what `Spores` clears
## around the one it found. Objects inserted at run time have none here.
var footprints: Dictionary[int, PackedInt32Array] = {}
## `SetCtrlMapInfo`'s table, for the "may this field be entered" test
## `0x0042F6B0` makes. Null for a hand-built context, and then only a wall
## refuses ([method enterable]).
var ctrlmap: CtrlMapTable = null
## The weapon table a spawn's full recompute reads its magazine from
## ([method UnitState.generate]). Empty for a hand-built context, and then a
## spawned unit's magazine is 0.
var weapons: WeaponTable = WeaponTable.new()
## The deterministic stand-in for `aRandom2` a spawn for a player other than
## 255 draws its voice from (docs/92 D8). [World] hands its own over; a
## hand-built context gets a fresh one.
var speech: IncRandom = null


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
	context.speech = IncRandom.new()
	context.speech.randomize_seed(1.0)
	return context


## Every cell of the object standing on `index`, or just `index` itself --
## [method MapResource.object_cells_at`], reachable from a handler.
func cells_of_object_at(index: int) -> PackedInt32Array:
	if object_cells.has(index):
		return object_cells[index].duplicate()
	return PackedInt32Array([index])


## `0x0042F6B0(cell) != 0xFF` -- the field type's delay is not impassable.
func enterable(index: int) -> bool:
	var field: int = state.field_type_at(index)
	if ctrlmap == null:
		return field != Interact.FIELD_TYPE_WALL
	return ctrlmap.is_enterable(field)


## `aGetSymbolObjectPtr` of a cell: its land marker, at the cell's origin and
## its current height (docs/10 section 4.6 -- `land.z == cell[+0x01]` on every
## shipped cell).
func marker(x: int, y: int) -> Vector3i:
	return Vector3i(x * MapResource.WORLD_UNITS_PER_FIELD,
		y * MapResource.WORLD_UNITS_PER_FIELD,
		state.height_at(state.index_of(x, y)))


## The cells a table object covers: its authored footprint, or the one cell
## its position falls in.
func footprint_of(record: Dictionary) -> PackedInt32Array:
	var id: int = DictRead.as_int(record["id"])
	if footprints.has(id) and not footprints[id].is_empty():
		return footprints[id].duplicate()
	var x: int = DictRead.as_int(record["x"]) / MapResource.WORLD_UNITS_PER_FIELD
	var y: int = DictRead.as_int(record["y"]) / MapResource.WORLD_UNITS_PER_FIELD
	if not state.in_bounds(x, y):
		return PackedInt32Array()
	return PackedInt32Array([state.index_of(x, y)])


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
	UnitState.remove(state, types, turn, unit)


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
	return UnitState.generate(state, units, types, weapons, ctrlmap,
		spawn_player, type_id, name, rank, pool_flag, x, y, false,
		turn.ai_level, speech)
