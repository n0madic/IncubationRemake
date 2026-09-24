class_name Upgrade
extends RefCounted

## The Upgrade screen's rules -- docs/27 section 5.3, read out of
## `aBuyWeapon` `0x00475680`, `aBuyEquipment` `0x004755D0` and the two skill
## routines they call.
##
## **The "Skills" number beside a catalogue row is not a column of the table.**
## `0x0047A600` (weapons) and `0x0047A6E0` (equipment) walk the item's skill
## requirements against **this soldier's** and return the sum of the shortfalls;
## with their third argument set they also raise each skill to the requirement.
## So the same rifle reads `Skills 3` for a recruit and `Skills 0` for the
## veteran who already trained on it, and a screen that printed the table's
## column would be showing a different number from the one the purchase
## charges.
##
## What the purchase charges is that shortfall in **skill points**, and a skill
## point is twelve of `+0x18` (docs/10 section 5.11): `aBuyWeapon` computes
## `eax * 3 << 2` and subtracts it from the soldier's TP.
##
## The two routines read their requirements from different places and in a
## different order, which is why they are two functions here and not one:
## a weapon record carries LW/HW/TS/CON at `+0x33..+0x36` and an equipment
## record carries CON/LW/HW/TS/MS/LS at `+0x23..+0x28`.

## `0x0047A600` / `0x0047A6E0` scale the shortfall by this before subtracting
## it from `+0x18`.
const TP_PER_SKILL_POINT: int = 12
## `0x00458416` -- the enable pass greys *Commend Unit* out at or above this,
## so ten skill points is the attainable maximum.
const TP_CAP: int = 120

## The order `0x0047A600` compares a **weapon's** requirements in. It is not
## the record's own order and it is not the equipment routine's; both are
## transcribed as written so a future reading can be checked against the
## listing rather than against a tidied version of it.
const WEAPON_SKILL_ORDER: Array[int] = [UnitState.SKILL_LW, UnitState.SKILL_HW,
	UnitState.SKILL_TS, UnitState.SKILL_CON]
## The order `0x0047A6E0` compares an **equipment** record's requirements in.
const EQUIPMENT_SKILL_ORDER: Array[int] = [UnitState.SKILL_LW,
	UnitState.SKILL_HW, UnitState.SKILL_TS, UnitState.SKILL_CON,
	UnitState.SKILL_LS, UnitState.SKILL_MS]

## `aBuyEquipment`'s mutual-exclusion groups: buying one member clears every
## member of its group, so a soldier carries one scanner, one stimulant, one
## armour and one medic kit at a time.
##
## The engine writes them as four ranges -- `id <= 1`, `3 <= id <= 4`,
## `10 <= id <= 13`, `15 <= id <= 16` -- clearing a `word` or a `dword` of the
## carried-equipment bitmap at `+0x21 + id`.
const EXCLUSIVE_GROUPS: Array[Array] = [[0, 1], [3, 4], [10, 11, 12, 13],
	[15, 16]]

## `0x00475601` -- buying the Jet Pack sets the Long Range Scan bit as well.
## `Info.lcl` annotates the line itself `* warp & scan`.
const JET_PACK_ID: int = 7
const JET_PACK_GRANTS: int = 1

## `0x0045A9B6` -- and the other direction: with the Jet Pack carried, the
## purchase of `Scan Module` is refused **before the purse is touched**, the
## screen's own guard rather than `aBuyEquipment`'s.
const SCAN_MODULE_ID: int = 0

## `0x00475550` -- the decoration allowance, derived from EP alone
## (docs/10 section 5.11). Each entry is the EP at which the allowance rises.
const DECORATION_TIERS: Array[int] = [40, 60, 100]

## `0x004755DD` / `0x00475689` -- the id bounds each routine refuses past.
const EQUIPMENT_ID_MAX: int = 21
const WEAPON_ID_MAX: int = 50

## Why a purchase was refused. The engine is silent about all four -- the
## button is simply greyed by the item window's refresh, `0x00457B00`
## (equipment) and `0x00457DA0` (weapons), which re-gates gadget 0 on the row
## that is up -- and docs/92 section 7.4 keeps the rule and drops the
## silence.
const OK: String = "ok"
const NO_UNIT: String = "no_unit"
const BAD_ID: String = "bad_id"
const NO_POINTS: String = "not_enough_equipment_points"
const NO_SKILL: String = "not_enough_skill_points"
const BLOCKED_BY_JET_PACK: String = "jet_pack_already_scans"
## The item is already on the soldier. The engine toggles it off here and
## charges for the privilege, because its caller spends the points before the
## call; the remake refuses and puts removal on *Undo* instead.
const ALREADY_CARRIED: String = "already_carried"
## The Recruit window's own refusal: thirty usable pool slots, all taken.
const POOL_FULL: String = "pool_full"


## The shortfall in skill points between what *needs* asks for and what the
## soldier has, over the skills *order* names.
##
## `needs` and `has` are both indexed by [constant UnitState.SKILL_NAMES]; a
## requirement the soldier already meets contributes nothing, which is the
## `jae` in front of every one of the six blocks.
static func skill_shortfall(needs: PackedInt32Array, has: PackedInt32Array,
		order: Array[int]) -> int:
	var total: int = 0
	for skill: int in order:
		if skill >= needs.size() or skill >= has.size():
			continue
		var short: int = needs[skill] - has[skill]
		if short > 0:
			total += short
	return total


## The same walk with the third argument set: every skill below the
## requirement is **raised to it**.
##
## Returns a **new** vector rather than writing through *has*. A
## `PackedInt32Array` reached through a property is not reliably a private
## copy (`godot/tests/test_isolation.gd` is the standing check on that), and a
## rule module that quietly wrote into a record's field would be the exact
## shape of aliasing bug that suite exists for. The cost is
## [method skill_shortfall] over the same two vectors.
static func raise_skills(needs: PackedInt32Array, has: PackedInt32Array,
		order: Array[int]) -> PackedInt32Array:
	var out: PackedInt32Array = has.duplicate()
	for skill: int in order:
		if skill >= needs.size() or skill >= out.size():
			continue
		if needs[skill] > out[skill]:
			out[skill] = needs[skill]
	return out


## What a weapon costs this soldier in skill points -- `0x0047A600(id, u, 0)`.
static func weapon_skill_cost(weapon: Dictionary, unit: UnitState) -> int:
	return skill_shortfall(skills_of(weapon), unit.skills, WEAPON_SKILL_ORDER)


## What an item costs this soldier in skill points -- `0x0047A6E0(id, u, 0)`.
static func equipment_skill_cost(item: Dictionary, unit: UnitState) -> int:
	return skill_shortfall(skills_of(item), unit.skills,
		EQUIPMENT_SKILL_ORDER)


## `aBuyWeapon` `0x00475680` past its bounds check: the weapon goes on, the
## skills it asks for are raised, and `+0x18` loses twelve per point of the
## shortfall. Returns the shortfall in skill points. **No purse here** -- the
## routine never touches money; its callers do, and the Recruit window's
## preset builder `0x00476260` calls it on a record that is not even in the
## pool yet. Writes through *unit*.
##
## *charge_skills* false is the `ammo` cheat's armoury ([method
## Cheats.armoury]): the skills are raised all the same, so a carried weapon
## still never outranks its bearer, but `+0x18` is left alone and the return
## is zero.
static func apply_weapon(unit: UnitState, weapon: int,
		weapon_row: Dictionary, charge_skills: bool = true) -> int:
	var needs: PackedInt32Array = skills_of(weapon_row)
	var short: int = skill_shortfall(needs, unit.skills, WEAPON_SKILL_ORDER) \
		if charge_skills else 0
	unit.weapon = weapon
	unit.skills = raise_skills(needs, unit.skills, WEAPON_SKILL_ORDER)
	unit.tp -= short * TP_PER_SKILL_POINT
	return short


## `aBuyEquipment` `0x004755D0` past its bounds check, for an item the soldier
## does not carry: the group the item belongs to is cleared, the item goes on
## (and the Jet Pack's scan with it), the skills are raised and `+0x18` pays.
## Returns the shortfall in skill points. Purse-less, as [method apply_weapon].
static func apply_equipment(unit: UnitState, item: int,
		item_row: Dictionary) -> int:
	var needs: PackedInt32Array = skills_of(item_row)
	var short: int = skill_shortfall(needs, unit.skills, EQUIPMENT_SKILL_ORDER)
	var carried: PackedInt32Array = PackedInt32Array()
	var cleared: PackedInt32Array = cleared_by(item)
	for held: int in unit.equipment:
		if not cleared.has(held):
			carried.append(held)
	carried.append(item)
	if item == JET_PACK_ID and not carried.has(JET_PACK_GRANTS):
		carried.append(JET_PACK_GRANTS)
	unit.equipment = carried
	unit.skills = raise_skills(needs, unit.skills, EQUIPMENT_SKILL_ORDER)
	unit.tp -= short * TP_PER_SKILL_POINT
	return short


## A balance-table row's `skills` object as a [constant UnitState.SKILL_NAMES]
## vector.
##
## A weapon's row carries four of the six and an item's row all six, so a name
## the row does not have reads as zero -- which is what the record holds.
static func skills_of(row: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array([0, 0, 0, 0, 0, 0])
	var named: Dictionary = DictRead.as_dict(row.get("skills", {}))
	for index: int in range(UnitState.SKILL_NAMES.size()):
		var key: String = UnitState.SKILL_NAMES[index]
		if named.has(key):
			out[index] = DictRead.as_int(named[key])
	return out


## `0x00475550` -- how many decorations this soldier's experience allows.
static func decoration_allowance(ep: int) -> int:
	var allowed: int = 0
	for tier: int in DECORATION_TIERS:
		if ep >= tier:
			allowed += 1
	return allowed


## The **skill points** a soldier has to spend: `+0x18 / 12`, which is the
## number the Item List prints (`0x0045A170` writes it into text slot 0x9C).
static func skill_points(unit: UnitState) -> int:
	return unit.tp / TP_PER_SKILL_POINT


## Whether *Commend Unit* is offered, and why not -- `0x00458270`'s three
## gates. The hero gate is **not** one of them: `pool_flag == 2` greys gadget
## 3, the name field, and docs/10 section 5.11 read it as gadget 5.
static func may_commend(unit: UnitState, commendations: int) -> bool:
	if unit == null or commendations <= 0:
		return false
	if decoration_allowance(unit.ep) <= unit.decorations:
		return false
	return unit.tp < TP_CAP


## Whether the soldier's name may be changed -- `0x00458449`: a hero's may not.
static func may_rename(unit: UnitState) -> bool:
	return unit != null and unit.pool_flag != UnitState.HERO_POOL_FLAG


## The equipment ids buying *item* clears, **not** counting *item* itself.
static func cleared_by(item: int) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for group: Array in EXCLUSIVE_GROUPS:
		if not group.has(item):
			continue
		for member: Variant in group:
			var id: int = member
			if id != item:
				out.append(id)
	return out
