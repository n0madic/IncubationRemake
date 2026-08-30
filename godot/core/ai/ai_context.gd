class_name AIContext
extends RefCounted

## The live state one computer turn runs against -- docs/23.
##
## `core` owns no overlay anywhere else: [MoveMap] returns a [MoveMapResult]
## and [WalkMap] returns a dictionary, precisely so a fill cannot be read back
## by accident. The AI is the one consumer that **must** read it back: the
## engine keeps `cell[+0x00]` and `cell[+0x0C]` in the cell records, the
## scoring pass reads what the fill wrote, the approach scan reads it again,
## and order 9 reads a target overlay left behind by a pass over the enemies.
## So the two arrays live here, in one object with a lifetime of one turn, and
## nothing outside `core/ai/` can see them.

## The three kinds of work worth counting -- the three the turn is made of
## and the three `bench.gd` measures the cost of one of.
const WORK_FILL: String = "fills"
const WORK_OVERLAY: String = "target_overlays"
const WORK_HIT_CHANCE: String = "hit_chances"
const WORK_PLAN: String = "plans"
const WORK_FIRE: String = "fires"


## `cell[+0x00]` -- the overlay byte.
var state: PackedByteArray = PackedByteArray()
## `cell[+0x0C]` -- the movement points left on arrival.
var mp_left: PackedInt32Array = PackedInt32Array()

var map: MapState = null
var units: Dictionary = {}
var utab: UnitTypeTable = null
var wtab: WeaponTable = null
var ctab: CtrlMapTable = null
var turn: TurnState = null
var rng: IncRandom = null
var result: AITurnResult = null

## `0x004FAE40` through `0x0040B370`. Always 1 in a shipped run: an engine
## debug global with a setter and a getter and no product option behind it.
## A field rather than a constant so a test can watch the movement alone.
var may_fire: bool = true


static func create(map_state: MapState, unit_dict: Dictionary,
		types: UnitTypeTable, weapons: WeaponTable, ctrl: CtrlMapTable,
		turn_state: TurnState, generator: IncRandom) -> AIContext:
	var ctx: AIContext = AIContext.new()
	ctx.map = map_state
	ctx.units = unit_dict
	ctx.utab = types
	ctx.wtab = weapons
	ctx.ctab = ctrl
	ctx.turn = turn_state
	ctx.rng = generator
	ctx.result = AITurnResult.new()
	ctx.state.resize(map_state.cell_count())
	ctx.mp_left.resize(map_state.cell_count())
	ctx.reset_overlay()
	return ctx


## `0x0042EE90` -- `cell[+0x00] = 1` and `cell[+0x0C] = 0`, and nothing else.
func reset_overlay() -> void:
	for i: int in range(state.size()):
		state[i] = AIOverlay.STATE_RESET
		mp_left[i] = 0


## `0x0042F790(x, y, value)` -- bounds-checked, and the only writer of the
## five target markers.
func write_marker(x: int, y: int, value: int) -> void:
	if not map.in_bounds(x, y):
		return
	state[map.index_of(x, y)] = value


func cell_x(index: int) -> int:
	return index % map.width


func cell_y(index: int) -> int:
	return index / map.width


func unit_or_null(slot: int) -> UnitState:
	if not units.has(slot):
		return null
	return units[slot]


## The unit standing on a cell, or `null`; a dead record counts as nobody.
func unit_on_index(index: int) -> UnitState:
	var slot: int = map.unit_at(index)
	if slot == MapState.NO_UNIT or not units.has(slot):
		return null
	var unit: UnitState = units[slot]
	return unit if unit.hp > 0 else null


func emit(event: AIEvent) -> void:
	result.add(event)


func refuse(reason: String) -> void:
	result.refuse(reason)


## One unit of work of a named kind. See [member AITurnResult.work].
func did(kind: String) -> void:
	result.did(kind)
