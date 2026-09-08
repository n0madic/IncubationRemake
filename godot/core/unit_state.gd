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
const SKILL_MS: int = 4
const SKILL_LS: int = 5

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
## `+0x17`, experience. The fitness cap is `max(3, ep / 12)`, and a kill
## awards the victim type's `exp` byte (docs/22 section 7.5,
## [method Combat.award_kill]).
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
## `+0x18`, the skill-point pool. `InsertUnit` sets it to `rank * 12`, the same
## value it puts in `ep`; a kill adds to it behind the experience gate.
var tp: int = 0
## `+0x53`, the kill counter `0x0047AF90` saturates at 255. **Zero on every
## shipped record** (docs/10 section 5: all-zero on at least 1855 of them), so
## the authored map does not carry it and [method from_document] starts it
## at zero rather than reading a column that does not exist.
var kills: int = 0
## `+0x38`, the decorations awarded. Written only by the Upgrade screen's
## *Commend Unit* button and read only by the pass that greys it out
## (docs/10 section 5.11), so it is campaign state and **zero on every shipped
## record** -- which is why [method hash_into] appends it only when it is not.
var decorations: int = 0
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
	unit.kills = 0
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


## The inverse of [method view] -- one unit out of the dictionary it produced.
##
## `view()` and this are a pair, and a field added to one without the other is
## a field a save silently drops. [SaveCodec] decodes through this for that
## reason, rather than repeating the twenty-odd assignments.
static func from_view(record: Dictionary) -> UnitState:
	var unit: UnitState = UnitState.new()
	unit.slot = DictRead.as_int(record["slot"])
	unit.name = DictRead.as_string(record["name"])
	unit.type_id = DictRead.as_int(record["type_id"])
	unit.player = DictRead.as_int(record["player"])
	unit.x = DictRead.as_int(record["x"])
	unit.y = DictRead.as_int(record["y"])
	unit.mp = DictRead.as_int(record["mp"])
	unit.hp = DictRead.as_int(record["hp"])
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
	unit.absorber = DictRead.as_int(record["absorber"])
	unit.order = DictRead.as_int(record["order"])
	unit.order_param = DictRead.as_int(record["order_param"])
	unit.order2 = DictRead.as_int(record["order2"])
	unit.order2_param = DictRead.as_int(record["order2_param"])
	unit.group = DictRead.as_int(record["group"])
	unit.tp = DictRead.as_int(record["tp"])
	unit.kills = DictRead.as_int(record["kills"])
	# **`get`, not `record[...]`.** A campaign saved before the Upgrade screen
	# existed carries no such key, and a save that still loads is worth more
	# than one that reports a missing decoration count as corruption.
	unit.decorations = DictRead.as_int(record.get("decorations", 0))
	unit.pool_flag = DictRead.as_int(record["pool_flag"])
	unit.speech = DictRead.as_int(record["speech"])
	unit.skills = DictRead.to_int32(record["skills"])
	unit.equipment = DictRead.to_int32(record["equipment"])
	return unit


## docs/10 section 5 -- a slot holds a placed unit when `+0x16` is non-zero.
func is_placed() -> bool:
	return hp != 0


func is_alive() -> bool:
	return hp > 0


func is_hidden() -> bool:
	return visibility == VISIBILITY_HIDDEN


## Write the fields a case record names, leaving the rest alone.
##
## Paired with [method World.apply_unit_record]; see there for why it exists.
## The key list is explicit rather than reflective so a field that reaches the
## simulation without reaching a case is a compile-time question and not a
## silent omission.
func apply_record(record: Dictionary) -> void:
	for key: String in RECORD_FIELDS:
		if not record.has(key):
			continue
		set(key, DictRead.as_int(record[key]))
	if record.has("equipment"):
		var ids: PackedInt32Array = PackedInt32Array()
		for value: Variant in DictRead.as_array(record["equipment"]):
			ids.append(DictRead.as_int(value))
		equipment = ids
	if record.has("skills"):
		var values: PackedInt32Array = PackedInt32Array()
		for value: Variant in DictRead.as_array(record["skills"]):
			values.append(DictRead.as_int(value))
		skills = values


## The integer fields [method apply_record] will write.
const RECORD_FIELDS: Array[String] = ["type_id", "player", "x", "y", "hp",
	"mp", "fp", "facing", "acted", "action_state", "heat", "ammo",
	"malfunction", "absorber", "visibility", "armour_front", "armour_rear",
	"order", "order_param", "order2", "order2_param", "group", "weapon",
	"ticket", "walked", "turn_start_x", "turn_start_y", "ep", "tp", "kills"]


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
		"kills": kills,
		"decorations": decorations,
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
		# The kill award's counter (docs/22 section 7.5).
		kills,
		equipment.size()])
	ctx.update(scalars.to_byte_array())
	# Fixed length, so no count is needed in front of it.
	ctx.update(skills.to_byte_array())
	# **Appended only when it is not zero.** `+0x38` is campaign state -- every
	# shipped `.lev` record carries zero -- so a mission world never reaches
	# this line and the canonical hashes `test_campaign` pins do not move (D7),
	# while a decorated roster record still changes the campaign's own digest.
	# The encoding stays injective because `equipment.size()` is already in the
	# scalars above: the split between this and the payload below is fixed, and
	# a record with no decoration is four bytes shorter than one with any.
	if decorations != 0:
		ctx.update(PackedInt32Array([decorations]).to_byte_array())
	# HashingContext refuses an empty buffer, and a unit with no equipment is
	# ordinary, so the count goes in above and the payload only when there is
	# one.  Without the count two different rosters could collide.
	if not equipment.is_empty():
		ctx.update(equipment.to_byte_array())


## docs/10 section 5 -- the unit array is 200 fixed records.
const UNIT_SLOTS: int = 200
## `+0x4D` at or above this is a **hero**, and `aRemoveUnitElement` counts one
## when it takes such a unit off the map. docs/22 section 9.5.
const HERO_POOL_FLAG: int = 2
## The player record's `+0x24` is one byte, so the count the engine keeps wraps
## at 256 rather than saturating. `HeroKilled` only asks whether it is
## non-zero, so the wrap is reachable only in theory -- it is modelled because
## the field is a byte and a remake that widened it would round-trip a save
## differently.
const HERO_COUNT_WRAP: int = 256


## The lowest slot holding no **live** unit.
##
## **UNVERIFIED.** docs/20 section 7.4 records everything `0x00479CF0` writes
## and not which index it writes it to; the array is 200 fixed records, so the
## lowest free one is the natural reading and it is what both implementations
## use.  It lives here, and not in [LclContext], because the interpreter is no
## longer the only caller: [method Combat.hatch] generates a unit too.
static func free_slot(units: Dictionary) -> int:
	for slot_id: int in range(UNIT_SLOTS):
		if not units.has(slot_id):
			return slot_id
		var unit: UnitState = units[slot_id]
		if not unit.is_alive():
			return slot_id
	return UNIT_SLOTS - 1


## An in-bounds cell with no live unit on it.
static func free_cell(state: MapState, units: Dictionary, x: int,
		y: int) -> bool:
	if not state.in_bounds(x, y):
		return false
	var slot_id: int = state.unit_at(state.index_of(x, y))
	if slot_id < 0 or not units.has(slot_id):
		return true
	var unit: UnitState = units[slot_id]
	return not unit.is_alive()


## `aGenerateUnitElement` (`0x00479CF0`) -- the one routine that puts a unit
## into the array at run time, and both of its shapes.
##
## docs/20 section 7.4: `rank * 12` goes into **both** the experience points
## and the skill-point pool, and an empty name is filled from the unit type's
## description string.
##
## `exact` is the engine's own eighth argument, and the two callers differ on
## it: the LCL spawn commands pass **0** and an occupied target cell then makes
## the routine search up to eight neighbours, while `0x0046F210`'s `special` 9
## arm passes **1** and takes the cell or nothing.  Written as one function
## because it is one routine; the flag is not a remake convenience.
static func generate(state: MapState, units: Dictionary,
		types: UnitTypeTable, spawn_player: int, type_id: int, name_text: String,
		rank: int, pool_flag: int, x: int, y: int,
		exact: bool) -> UnitState:
	var tx: int = -1
	var ty: int = -1
	if free_cell(state, units, x, y):
		tx = x
		ty = y
	elif not exact:
		for dy: int in [-1, 0, 1]:
			for dx: int in [-1, 0, 1]:
				if dx == 0 and dy == 0:
					continue
				if tx < 0 and free_cell(state, units, x + dx, y + dy):
					tx = x + dx
					ty = y + dy
	if tx < 0:
		return null
	var unit: UnitState = UnitState.new()
	unit.slot = free_slot(units)
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
	if name_text != "":
		unit.name = name_text
	elif types.has(type_id):
		unit.name = types.description(type_id)
	else:
		unit.name = ""
	unit.turn_start_x = tx
	unit.turn_start_y = ty
	units[unit.slot] = unit
	state.set_unit(state.index_of(tx, ty), unit.slot)
	return unit


## `aRemoveUnitElement` (`0x004779C0`) -- the one routine that takes a unit off
## the map, and the **only** thing that ever moves the hero counter.
##
## docs/22 section 9.5. Its middle third is three instructions of bookkeeping
## that this remake had never modelled:
##
## [codeblock]
## if (unit[+0x4D] >= 2 && getTurnCounter() != 0)   /* 0x00477A3B, 0x0043B280 */
##     playerRecord(unit[+0x45])[+0x24]++;          /* 0x00477A53..0x00477A5E */
## [/codeblock]
##
## `playerRecord` is `0x0043BA00` -- base `0x00509F48`, stride 40, four
## records -- and `+0x24` is what the LCL predicate `HeroKilled` reads
## (`0x004409E0`, docs/20 section 7.4). [member TurnState.hero_killed] carried
## the field and nothing wrote it, so `HeroKilled` answered false in every
## mission that asks -- and `_C_140`, the one this slice plays, asks.
##
## **The gate is the turn counter, not the turn number of the unit.** A hero
## taken off the map before the first hand-over does not count: at that point
## `0x00509E1D` is still zero, which is the same test docs/25 section 3.1 uses
## to recognise the first hand-over.
##
## **Its last instruction kills.** `0x00477ABD` is `mov byte [esi+0x16], 0`,
## with `esi` the unit record it has held since `0x00477A38` -- the same
## record `aExecuteWarp` reads `+0x16` from to decide whether the mover is
## still alive. So "off the map" and "dead" are one state, not two: every
## caller of this routine leaves the record at zero hit points whether or not
## it wrote them itself, and [method live_unit_count]'s `+0x16` sweep
## (`0x00477BF0`) stops counting the unit for that reason alone.
##
## Returns whether the counter moved, so a caller can report it.
static func remove(state: MapState, turn: TurnState, unit: UnitState) -> bool:
	# `0x0043B8D0`, from `aAttackUnit`'s `0x0046BF6E` and ten other death
	# paths -- the set-piece killers, the bomb and the teleporter among them.
	# Every one of them ends here, so counting here counts all eleven. It is
	# **not** inside `aUI_KillUnit`: the loss counter belongs to the call
	# sites, which is why [method take_off_map] below is a routine of its own.
	turn.count_unit_lost(unit.type_id, unit.player)
	return take_off_map(state, turn, unit)


## `aUI_KillUnit` `0x004779C0` alone -- the hero counter, the cell and the
## hit-point byte, and nothing else.
##
## Split out of [method remove] for the one caller that is not a death: the
## post-load sweep `0x004783D0` ([method World.load_sweep]) takes the units of
## players who are not in the session off the map, and reaches this routine
## directly. Nothing has died there and no loss is counted -- and the hero
## counter cannot fire either, its gate being the turn counter, which at load
## is still zero.
static func take_off_map(state: MapState, turn: TurnState,
		unit: UnitState) -> bool:
	var counted: bool = false
	if unit.pool_flag >= HERO_POOL_FLAG and turn.turn != 0 \
			and unit.player >= 0 and unit.player < turn.hero_killed.size():
		turn.hero_killed[unit.player] = \
			(turn.hero_killed[unit.player] + 1) % HERO_COUNT_WRAP
		counted = true
	# The cell is cleared only when it still names this unit: a push that has
	# already moved the record, or a second removal, must not blank a cell
	# somebody else is standing on.
	if state.in_bounds(unit.x, unit.y):
		var at: int = state.index_of(unit.x, unit.y)
		if state.unit_at(at) == unit.slot:
			state.set_unit(at, MapState.NO_UNIT)
	# `0x00477ABD` -- the routine's own last write.
	unit.hp = 0
	return counted
