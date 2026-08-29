class_name HitChance
extends RefCounted

## `aGetHitProbability` (`0x0046A270`), transcribed from docs/22 section 5.
##
## A value, like every other result in `core/`: the range gate, the percentage,
## the distance the gate and the curve used, and the line-of-sight code.
##
## **Cover is binary.**  `blocked` is 0, 254 or 255 and `percent` never exceeds
## 100, so any obstruction zeroes the chance.  The subtraction at the end of
## [method compute] is not a partial-cover penalty; it can only ever run with
## `blocked == 0`.  It is written as a subtraction because that is what the
## engine wrote, and because reading it as a boolean is how a remake ends up
## with 254 % .

## docs/22 section 5.1 -- two adjacent cells more than 1.5 m apart vertically
## count as further apart than one field.  The rule fires only at `d == 1`.
const HEIGHT_STEP: int = 2400
## docs/22 section 5.5 -- half the body height plus this is the eye.
const EYE_BASE: int = 800
## Both height helpers answer this for a null unit.
const NULL_UNIT_HEIGHT: int = 2400
## docs/22 section 5.5 -- one field, added to **both** endpoints for an arcing
## weapon, which lifts the ray without changing its slope.  That is the whole
## indirect-fire mechanic.
const ARC_Z_OFFSET: int = 3200
## `0x0047B600` returns 1 for exactly these: the Grenade Launcher, the Mine
## Thrower Enhanced, and the B mode of each.
const ARCING_WEAPONS: Array[int] = [8, 13, 42, 46]
## docs/22 section 5.5 -- a neutral unit whose primary order is not 9 gets the
## single-ray form; everything else gets the two- or four-ray one.
const CLEVER_SMALL_UNITS_ORDER: int = 9
## docs/22 section 5.3 -- `Target System` doubles the accuracy before the curve.
const EQUIP_TARGET_SYSTEM: int = 5

var in_range: bool = false
var percent: int = 0
var distance: int = 0
var blocked: int = LineOfSight.CLEAR


static func make(gate: bool, chance: int, d: int, block: int) -> HitChance:
	var out: HitChance = HitChance.new()
	out.in_range = gate
	out.percent = chance
	out.distance = d
	out.blocked = block
	return out


func to_dict() -> Dictionary:
	return {"in_range": in_range, "percent": percent, "distance": distance,
		"blocked": blocked}


## `0x0046A35C` -- `n / 2400 + 1`, as the compiler wrote it.
##
## Written out rather than replaced by integer division because the original is
## a magic-number multiply and the corpus check in `combat_tables.py` compares
## against *this* shape over the whole shipped height range.
static func magic_div_2400_plus_1(n: int) -> int:
	var product: int = 0x1B4E81B5 * n
	var hi: int = IncInt.i32((product >> 32) & 0xFFFFFFFF) >> 8
	var sign: int = 1 if hi < 0 else ((hi & 0xFFFFFFFF) >> 31)
	return hi + sign + 1


## docs/22 section 5.4 -- `100 - ((101 - acc) / rangeMax) * d`.
##
## The slope is truncated **before** it is multiplied, which is what makes every
## weapon with `acc + rangeMax > 101` flat at 100 %, and what makes the Target
## System a no-op on most weapons.
static func percent_at(accuracy: int, range_max: int, fields: int) -> int:
	return 100 - IncInt.div_trunc(101 - accuracy, range_max) * fields


## `0x0047AD70` -- `unitType[+0x7C] * 160`; 2400 for a type nothing knows.
static func full_height(utab: UnitTypeTable, type_id: int) -> int:
	if not utab.has(type_id):
		return NULL_UNIT_HEIGHT
	return utab.body_height_world(type_id)


## `0x0047AD30` -- half the full height plus 800.
static func eye_height(utab: UnitTypeTable, type_id: int) -> int:
	if not utab.has(type_id):
		return NULL_UNIT_HEIGHT
	return IncInt.div_trunc(utab.body_height_world(type_id), 2) + EYE_BASE


## docs/22 section 5.1 -- the distance the range gate and the curve use.
##
## A large participant costs one field each, and two adjacent cells more than
## [constant HEIGHT_STEP] apart vertically count as further than one field.
static func combat_distance(state: MapState, utab: UnitTypeTable,
		wtab: WeaponTable, attacker: UnitState, defender: UnitState,
		weapon_id: int) -> int:
	var bx: int = defender.x
	var by: int = defender.y
	if wtab.special(weapon_id) == 6:
		# "attack the defender's position of the last turn" -- the only
		# consumer of unit +0x51/+0x52, and the confirmation of what they mean.
		bx = defender.turn_start_x
		by = defender.turn_start_y
	var d: int = MoveMap.distance(attacker.x, attacker.y, bx, by)
	if utab.unit_size(attacker.type_id) == UnitTypeTable.SIZE_LARGE:
		d -= 1
	if utab.unit_size(defender.type_id) == UnitTypeTable.SIZE_LARGE:
		d -= 1
	var ah: int = 0
	if state.in_bounds(attacker.x, attacker.y):
		ah = state.height_at(state.index_of(attacker.x, attacker.y))
	var bh: int = 0
	if state.in_bounds(bx, by):
		bh = state.height_at(state.index_of(bx, by))
	var dh: int = absi(ah - bh)
	if dh > HEIGHT_STEP and d == 1:
		d = magic_div_2400_plus_1(dh)
	return d


## `0x004752E0` -- the Hit (%) column, doubled by the Target System.
static func accuracy_of(wtab: WeaponTable, attacker: UnitState,
		weapon_id: int) -> int:
	var acc: int = wtab.hit(weapon_id)
	if acc > 99:
		return 100
	if attacker.has_equipment(EQUIP_TARGET_SYSTEM):
		acc *= 2
		if acc > 100:
			acc = 100
	return acc


## `aGetHitProbability` `0x0046A270` -- docs/22 section 5.
##
## `apply_los` is false inside the attack resolver: a target the marking pass
## accepted is hit without a second cover test (docs/22 section 7).
static func compute(state: MapState, units: Dictionary, utab: UnitTypeTable,
		wtab: WeaponTable, attacker: UnitState, defender: UnitState,
		weapon_id: int, apply_los: bool, human_players: int,
		game_mode: int) -> HitChance:
	var d: int = combat_distance(state, utab, wtab, attacker, defender,
		weapon_id)
	if not wtab.has(weapon_id):
		return make(false, 0, d, LineOfSight.CLEAR)
	if d < wtab.range_min(weapon_id) or d > wtab.range_max(weapon_id):
		return make(false, 0, d, LineOfSight.CLEAR)

	var chance: int = percent_at(accuracy_of(wtab, attacker, weapon_id),
		wtab.range_max(weapon_id), d)
	if not apply_los:
		return make(true, chance, d, LineOfSight.CLEAR)

	var zoff: int = ARC_Z_OFFSET if ARCING_WEAPONS.has(weapon_id) else 0
	var mode: int = 1
	if (attacker.player == UnitState.PLAYER_ALIEN
			and attacker.order != CLEVER_SMALL_UNITS_ORDER):
		mode = 0
	var az: int = eye_height(utab, attacker.type_id) + zoff \
		+ state.height_at(state.index_of(attacker.x, attacker.y))
	var bz: int = eye_height(utab, defender.type_id) + zoff \
		+ state.height_at(state.index_of(defender.x, defender.y))
	var block: int = LineOfSight.check(state, units, utab, attacker.x,
		attacker.y, az, defender.x, defender.y, bz, mode, human_players,
		game_mode)
	if chance < block:
		return make(true, 0, d, block)
	return make(true, chance - block, d, block)
