class_name SpecialObjects
extends Node3D

## The environment that moves by itself -- docs/42 section 9.1.
##
## The cell-owned objects [CellObjects] places are drawn here and animated
## every displayed frame, the way `aRefreshView` `0x00406FC0` does:
##
## [codeblock]
## state 1  the two flame billboards get a random heading each  (fire)
## state 2  triple 0 turns by +51                               (mine)
## state 3  +25 / +51 / +102 by subtype 1 / 2 / other           (shield)
## state 4  triple 0 turns by aRandom2(0, 4096)                 (glow)
## [/codeblock]
##
## The state and the subtype are cell bytes, so this class owns no state of its
## own beyond the last snapshot it drew: an object exists exactly while a cell
## says it does, which is what makes the picture a function of `core` rather
## than an accumulation of edits. The draw itself is [BlobModels]: a special
## object is a record of the same shape with the same three joint triples.
##
## The **positions are the engine's**, not the remake's: the placers scatter
## the object inside its cell with two `aRandom2` draws each, and
## [method CellObjects.object_position] is that arithmetic. The eight
## `special_*` phases read every record's `+0x10`/`+0x14`/`+0x18` back and
## compare all three, with the draw count checked against the seed either side
## of the call (docs/97 section 37).

## The per-frame turn of each animated state, in 4096ths of a turn.
const MINE_STEP: int = 51
const SHIELD_STEP_SUBTYPE_1: int = 25
const SHIELD_STEP_SUBTYPE_2: int = 51
const SHIELD_STEP_OTHER: int = 102
## `aRandom2(0, 4096)` -- the glow's heading and the fire's two, drawn fresh
## every frame rather than stepped.
const HEADING_RANGE: int = 4096

var _models: BlobModels = null
var _rng: IncRandom = null
## Object id -> `{cell, model, state, subtype, angle}`.
var _live: Dictionary[int, Dictionary] = {}
## The effect planes as they were when [method sync] last ran.
var _drawn: Array[PackedByteArray] = []
var _width: int = 0
var _height: int = 0


func setup(prototypes: Dictionary, textures: Dictionary,
		index: Dictionary[String, int], rng: IncRandom) -> void:
	for child: Node in get_children():
		remove_child(child)
		child.free()
	_models = BlobModels.new()
	_models.name = "Meshes"
	add_child(_models)
	_models.setup(prototypes, textures, index)
	_rng = rng
	_live.clear()
	_drawn = []
	_width = 0
	_height = 0


func live_count() -> int:
	return _live.size()


## Rebuild the object list from a terrain snapshot.
##
## Cheap when nothing changed: six `PackedByteArray` compares, which Godot does
## as a memcmp. Answers the cells whose effect bytes moved, so the caller can
## repaint their overlay too.
func sync(snapshot: Dictionary) -> PackedInt32Array:
	if snapshot.is_empty():
		return PackedInt32Array()
	var effects: Array = DictRead.as_array(snapshot["effect"])
	var width: int = DictRead.as_int(snapshot["width"])
	var height: int = DictRead.as_int(snapshot["height"])
	var changed: PackedInt32Array = _changed_cells(effects, width, height)
	if changed.is_empty():
		return changed
	for index: int in changed:
		_rebuild_cell(effects, snapshot, index)
	_drawn = []
	for plane: Variant in effects:
		var bytes: PackedByteArray = plane
		_drawn.append(bytes.duplicate())
	_width = width
	_height = height
	return changed


## One displayed frame of the refresh, and how many objects it turned.
func advance() -> int:
	var keep: Dictionary = {}
	for oid: int in _live:
		var entry: Dictionary = _live[oid]
		var state: int = DictRead.as_int(entry["state"])
		var triples: Array[Vector3i] = [Vector3i.ZERO, Vector3i.ZERO,
			Vector3i.ZERO]
		if state == MapState.OBSTACLE_FIRE:
			# Two flame billboards, a new heading each every frame.
			triples[1] = Vector3i(0, 0, _heading())
			triples[2] = Vector3i(0, 0, _heading())
		else:
			var step: int = 0
			if state == MapState.OBSTACLE_MINE:
				step = MINE_STEP
			elif state == MapState.OBSTACLE_SHIELD:
				step = _shield_step(DictRead.as_int(entry["subtype"]))
			elif state == MapState.DECAL_GLOW:
				step = _heading()
			entry["angle"] = (DictRead.as_int(entry["angle"]) + step) \
				% HEADING_RANGE
			triples[0] = Vector3i(0, 0, DictRead.as_int(entry["angle"]))
		if _models.place(oid, DictRead.as_string(entry["model"]),
				DictRead.as_vector3i(entry["at"]), triples):
			keep[oid] = true
	return _models.keep_only(keep)


## `+25 / +51 / +102 by subtype 1 / 2 / other` -- a fresh shield carries 2, and
## the round tick counts it down to 1, so it slows as it expires.
static func _shield_step(subtype: int) -> int:
	if subtype == 1:
		return SHIELD_STEP_SUBTYPE_1
	if subtype == 2:
		return SHIELD_STEP_SUBTYPE_2
	return SHIELD_STEP_OTHER


func _heading() -> int:
	if _rng == null:
		return 0
	return _rng.draw(0, HEADING_RANGE)


func _changed_cells(effects: Array, width: int,
		height: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var count: int = width * height
	if _drawn.size() != effects.size() or _width != width \
			or _height != height:
		out.resize(count)
		for i: int in range(count):
			out[i] = i
		return out
	var same: bool = true
	for slot: int in range(effects.size()):
		var plane: PackedByteArray = effects[slot]
		if plane != _drawn[slot]:
			same = false
			break
	if same:
		return out
	for i: int in range(count):
		for slot: int in range(effects.size()):
			var plane: PackedByteArray = effects[slot]
			if plane[i] != _drawn[slot][i]:
				out.append(i)
				break
	return out


## What one cell owns after a change: at most one obstacle object and one glow.
func _rebuild_cell(effects: Array, snapshot: Dictionary, index: int) -> void:
	for oid: int in _live.keys():
		if DictRead.as_int(DictRead.as_dict(_live[oid])["cell"]) == index:
			_live.erase(oid)
	var obstacle: PackedByteArray = effects[MapState.OBSTACLE_SLOT]
	var timer: PackedByteArray = effects[MapState.TIMER_SLOT]
	var object_slot: PackedByteArray = effects[MapState.OBJECT_SLOT]
	var decal_state: PackedByteArray = effects[MapState.DECAL_STATE_SLOT]
	var decal_phase: PackedByteArray = effects[MapState.DECAL_PHASE_SLOT]
	var decal_object: PackedByteArray = effects[MapState.DECAL_OBJECT_SLOT]
	var state: int = obstacle[index]
	var origin: Vector3i = origin_of(snapshot, index)
	if state == MapState.OBSTACLE_FIRE or state == MapState.OBSTACLE_MINE \
			or state == MapState.OBSTACLE_SHIELD:
		var model: String = CellObjects.MINE_MODEL
		if state == MapState.OBSTACLE_FIRE:
			model = CellObjects.fire_model(timer[index])
		elif state == MapState.OBSTACLE_SHIELD:
			model = CellObjects.SHIELD_MODEL
		_live[object_slot[index]] = {"cell": index, "model": model,
			"state": state, "subtype": timer[index], "angle": 0,
			"at": CellObjects.object_position(origin, state, _rng)}
	if decal_state[index] == MapState.DECAL_GLOW:
		var model: String = CellObjects.GLOW_MODEL_LIT \
			if decal_phase[index] == CellObjects.GLOW_PHASE_LIT \
			else CellObjects.GLOW_MODEL_FRESH
		_live[decal_object[index]] = {"cell": index, "model": model,
			"state": MapState.DECAL_GLOW, "subtype": decal_phase[index],
			"angle": 0, "at": CellObjects.object_position(
				origin, MapState.DECAL_GLOW, _rng)}


## The cell's own object -- `aGetSymbolObjectPtr(cell[+0x05])`, which is what
## every placer positions around.
##
## **Measured, and it is the cell's corner.** The D00 capture read symbol 998,
## the object of cell (12, 29), at `(38400, 92800, 0)` = `(12·3200, 29·3200)`
## -- so `x · 3200` and not `x · 3200 + 1600`. That is the same point
## `_death_inputs` hands the death creators (docs/97 section 22), and the
## suite asserts the two agree rather than leaving it to a comment.
func origin_of(snapshot: Dictionary, index: int) -> Vector3i:
	var width: int = DictRead.as_int(snapshot["width"])
	var heights: PackedInt32Array = snapshot["height_map"]
	var x: int = index % width
	var y: int = index / width
	return Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
		y * WorldSpace.WORLD_UNITS_PER_FIELD, heights[index])
