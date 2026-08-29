class_name UnitState
extends RefCounted

## One live unit slot, reduced to what the slice's simulation reads.
##
## The full 91-byte record of docs/10 section 5 is not modelled: combat,
## experience, ammunition and heat are all outside the slice, and carrying
## fields nothing reads would invite treating them as validated.

const NO_UNIT: int = -1
## docs/22 section 9.1 -- a hidden unit is treated as an empty cell by the fill.
const VISIBILITY_HIDDEN: int = 3
## docs/10 section 5.7 -- the aliens; the one player a mine does not stop.
const PLAYER_ALIEN: int = 255
## docs/23 section 7.5 -- the Jet Pack, `Info.lcl`'s "warp & scan".
const JET_PACK_EQUIP_ID: int = 7

var slot: int = NO_UNIT
var name: String = ""
var type_id: int = 0
var player: int = 0
var x: int = 0
var y: int = 0
var mp: int = 0
var hp: int = 0
## `+0x19`, the per-turn stamina pool; 0 and 1 override the whole allowance.
var fp: int = 0
## `+0x57`, "did not act last turn"; the allowance adds one at 1.
var rested: int = 0
## `+0x41`; 5 and 6 zero the allowance, 7 is "stood down without acting".
var action_state: int = 0
var facing: int = 0
var visibility: int = 0
var equipment: PackedInt32Array = PackedInt32Array()


static func from_document(record: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(record["slot"])
	unit.name = DictRead.as_string(record["name"])
	unit.type_id = DictRead.as_int(record["type_id"])
	unit.player = DictRead.as_int(record["player"])
	unit.x = DictRead.as_int(record["x"])
	unit.y = DictRead.as_int(record["y"])
	unit.mp = DictRead.as_int(record["action_points"])
	unit.hp = DictRead.as_int(record["hit_points"])
	unit.fp = DictRead.as_int(record["fp"])
	unit.rested = DictRead.as_int(record["rested"])
	unit.action_state = DictRead.as_int(record["action_state"])
	unit.facing = DictRead.as_int(record["facing"])
	unit.visibility = DictRead.as_int(record["visibility"])
	var ids: Array = DictRead.as_array(record["equipment_ids"])
	unit.equipment.resize(ids.size())
	for i: int in range(ids.size()):
		unit.equipment[i] = DictRead.as_int(ids[i])
	return unit


## docs/10 section 5 -- a slot holds a placed unit when `+0x16` is non-zero.
func is_placed() -> bool:
	return hp != 0


func is_alive() -> bool:
	return hp > 0


func is_hidden() -> bool:
	return visibility == VISIBILITY_HIDDEN


func has_equipment(equip_id: int) -> bool:
	return equipment.has(equip_id)


func has_jet_pack() -> bool:
	return has_equipment(JET_PACK_EQUIP_ID)


## A fresh dictionary of scalars.  `core` never hands out a live reference:
## an `Array` or `Dictionary` held internally would be a handle on its state.
func view() -> Dictionary:
	return {
		"slot": slot,
		"name": name,
		"type_id": type_id,
		"player": player,
		"x": x,
		"y": y,
		"mp": mp,
		"hp": hp,
		"fp": fp,
		"rested": rested,
		"action_state": action_state,
		"facing": facing,
		"visibility": visibility,
		"placed": is_placed(),
		"equipment": equipment.duplicate(),
	}


func hash_into(ctx: HashingContext) -> void:
	var scalars: PackedInt32Array = PackedInt32Array(
		[slot, type_id, player, x, y, mp, hp, fp, rested, action_state,
		facing, visibility, equipment.size()])
	ctx.update(scalars.to_byte_array())
	# HashingContext refuses an empty buffer, and a unit with no equipment is
	# ordinary, so the count goes in above and the payload only when there is
	# one.  Without the count two different rosters could collide.
	if not equipment.is_empty():
		ctx.update(equipment.to_byte_array())
