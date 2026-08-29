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
## docs/10 section 5.3 -- `+0x1A..+0x1F`, in the order the record stores them.
## The converter emits them as a map, so the order lives here and not there.
const SKILL_NAMES: Array[String] = ["CON", "LW", "HW", "TS", "MS", "LS"]
const SKILL_CON: int = 0
const SKILL_LW: int = 1
const SKILL_HW: int = 2
const SKILL_TS: int = 3

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

# --- what the turn reads (docs/25 section 5) --------------------------------
# Added for the second slice, and still under the rule at the top of this file:
# every one of these is read or written by the hand-over refresh, and nothing
# is here because the record happens to carry it.
## `+0x39`, "has acted this turn"; the refresh clears it after the recompute,
## because the allowance reads `+0x41` and would see a stale value otherwise.
var acted: int = 0
## `+0x3D`, rounds in the magazine.
var ammo: int = 0
## `+0x3E`, the heat counter; the refresh cools it by one or two.
var heat: int = 0
## `+0x3F`, the equipped weapon id -- the heat cap and the overheat arm read it.
var weapon: int = 0
## `+0x40`, the malfunction state; the refresh walks the ladder in docs/25.
var malfunction: int = 0
## `+0x50`, distance walked this turn, in tenths: 10 orthogonal, 15 diagonal.
var walked: int = 0
## `+0x51` / `+0x52`, where the unit stood when the turn began.
var turn_start_x: int = 0
var turn_start_y: int = 0
## `+0x58`, the stimulant charge; 255 is "spent this turn".
var stimulant: int = 0
## `+0x59`, the reaction-fire ticket -- docs/25 section 6's FIFO order.
var ticket: int = 0
## `+0x1B`, experience. The fitness cap is `max(3, ep / 12)`, so the refresh
## reads it even though nothing in this slice awards any.
var ep: int = 0

# --- what combat reads (docs/22 sections 7 and 9) ---------------------------
# Same rule again: every one of these is read by the damage roll, the fog pass
# or the reaction queue.
## `+0x36` / `+0x37`, the two armour values. Which one applies is decided by
## docs/22 section 7.4's 135-degree rear arc, not by the weapon.
var armour_front: int = 0
var armour_rear: int = 0
## `+0x3A`, `Damage Absorber` charges. One charge nullifies a hit **entirely**
## (docs/22 section 7.5) -- it is not a reduction.
var absorber: int = 0
## `+0x47` / `+0x48` and `+0x49` / `+0x4A`, the primary and secondary orders.
## The fog pass promotes the second over the first for a whole AI group when a
## unit on an alerting order is seen (docs/22 section 9.3), which is what the
## secondary order in docs/10 section 5.6 is *for*.
var order: int = 0
var order_param: int = 0
var order2: int = 0
var order2_param: int = 0
## `+0x4E`, the AI group the promotion above applies to.
var group: int = 0

# --- what the mission script writes (docs/20 section 7.4) -------------------
# Nothing in the simulation *reads* these three. They are here because a
# mission script **writes** them -- `InsertUnit` sets the first two and
# `LinkChrWithGroup` the third -- and a remake that dropped them could not be
# compared with the executable model on any script that calls those commands.
## `+0x1C`, the skill-point pool. `InsertUnit` sets it to `rank * 12`, the same
## value it puts in `ep`.
var tp: int = 0
## `+0x4D`: 0 none, 1 unit-pool candidate, 2 hero.
var pool_flag: int = 0
## `+0x55`, the voice sample set.
var speech: int = 0
## `+0x1A..+0x1F` -- CON, LW, HW, TS, MS, LS (docs/10 section 5.3). The three
## implant boxes in docs/26 section 3.1 write to them.
var skills: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])


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
	unit.acted = DictRead.as_int(record["acted"])
	unit.ammo = DictRead.as_int(record["ammo"])
	unit.heat = DictRead.as_int(record["heat"])
	unit.weapon = DictRead.as_int(record["weapon"])
	unit.malfunction = DictRead.as_int(record["malfunction"])
	unit.walked = DictRead.as_int(record["walked"])
	unit.turn_start_x = DictRead.as_int(record["turn_start_x"])
	unit.turn_start_y = DictRead.as_int(record["turn_start_y"])
	unit.stimulant = DictRead.as_int(record["stimulant"])
	unit.ticket = DictRead.as_int(record["ticket"])
	unit.ep = DictRead.as_int(record["ep"])
	unit.armour_front = DictRead.as_int(record["armour_front"])
	unit.armour_rear = DictRead.as_int(record["armour_rear"])
	unit.absorber = DictRead.as_int(record["damage_absorber"])
	unit.order = DictRead.as_int(record["order"])
	unit.order_param = DictRead.as_int(record["order_param"])
	unit.order2 = DictRead.as_int(record["order2"])
	unit.order2_param = DictRead.as_int(record["order2_param"])
	unit.group = DictRead.as_int(record["group"])
	unit.tp = DictRead.as_int(record["tp"])
	unit.pool_flag = DictRead.as_int(record["pool_flag"])
	unit.speech = DictRead.as_int(record["speech"])
	var skill_map: Dictionary = DictRead.as_dict(record["skills"])
	for i: int in range(SKILL_NAMES.size()):
		unit.skills[i] = DictRead.as_int(skill_map[SKILL_NAMES[i]])
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
		# The turn's own columns.  A save that dropped these would round-trip
		# to a *different* simulation -- a cooling weapon would come back hot,
		# a spent stimulant would come back available.
		"acted": acted,
		"ammo": ammo,
		"heat": heat,
		"weapon": weapon,
		"malfunction": malfunction,
		"walked": walked,
		"turn_start_x": turn_start_x,
		"turn_start_y": turn_start_y,
		"stimulant": stimulant,
		"ticket": ticket,
		"ep": ep,
		"armour_front": armour_front,
		"armour_rear": armour_rear,
		"absorber": absorber,
		"order": order,
		"order_param": order_param,
		"order2": order2,
		"order2_param": order2_param,
		"group": group,
		"tp": tp,
		"pool_flag": pool_flag,
		"speech": speech,
		"skills": skills.duplicate(),
	}


func hash_into(ctx: HashingContext) -> void:
	var scalars: PackedInt32Array = PackedInt32Array(
		[slot, type_id, player, x, y, mp, hp, fp, rested, action_state,
		facing, visibility,
		# The turn's columns, in the order this file declares them.
		acted, ammo, heat, weapon, malfunction, walked, turn_start_x,
		turn_start_y, stimulant, ticket, ep,
		# Combat's own columns, in the order this file declares them.
		armour_front, armour_rear, absorber, order, order_param, order2,
		order2_param, group, tp, pool_flag, speech,
		equipment.size()])
	ctx.update(scalars.to_byte_array())
	# Fixed length, so no count is needed in front of it.
	ctx.update(skills.to_byte_array())
	# HashingContext refuses an empty buffer, and a unit with no equipment is
	# ordinary, so the count goes in above and the payload only when there is
	# one.  Without the count two different rosters could collide.
	if not equipment.is_empty():
		ctx.update(equipment.to_byte_array())
