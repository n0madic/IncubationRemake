class_name WeaponTable
extends RefCounted

## `Info.lcl`'s `SetWeaponInfo` rows -- docs/21 section 6.
##
## The turn reads three columns of it: `heat` to know whether a weapon cools at
## all, `toggle` to revert an alternate fire mode, and `mun` for the magazine.
## Combat reads seven more -- the accuracy and damage the curve and the roll
## use, the two range bounds the gate uses, the type the overheat arm branches
## on, `special` 6 (attack the target's position of *last* turn) and `def_mode`,
## the overwatch flag of docs/21 section 4.
## Built the same way [UnitTypeTable] is, from the list the cache carries.

var _rows: Dictionary = {}


static func from_rows(rows: Array) -> WeaponTable:
	var table: WeaponTable = WeaponTable.new()
	for row: Variant in rows:
		var view: Dictionary = row
		table._rows[DictRead.as_int(view["id"])] = view
	return table


func size() -> int:
	return _rows.size()


func has(weapon_id: int) -> bool:
	return _rows.has(weapon_id)


## One column of one row, or `fallback`.
##
## A row is a **document**, not a struct: it comes from `tables/balance.json`
## and a hand-built fixture in `tests/` carries only the columns that fixture
## is about. So a missing key is the same answer as a missing row -- the
## accessor's own documented default -- rather than a crash in whichever suite
## happened to add a reader first.
##
## The real cache is held to the stricter standard: `test_cache.gd` asserts
## that every published row carries every column any accessor reads, so a
## converter that dropped one fails there and not silently here.
func _field(weapon_id: int, key: String, fallback: int) -> int:
	if not _rows.has(weapon_id):
		return fallback
	var row: Dictionary = _rows[weapon_id]
	if not row.has(key):
		return fallback
	return DictRead.as_int(row[key])


## `weapon[+0x3A]`. 255 disables heat for that weapon entirely.
func heat(weapon_id: int) -> int:
	return _field(weapon_id, "heat", Refresh.HEAT_NONE)


## docs/25 section 7 -- an involution: the base of every pair is at most 14 and
## the alternate at least 40.
func toggle(weapon_id: int) -> int:
	return _field(weapon_id, "toggle", weapon_id)


## The magazine size. docs/26 section 3.2: a "full munition" point **assigns**
## this rather than adding to it, so a unit that has not fired sees no change.
func magazine(weapon_id: int) -> int:
	return _field(weapon_id, "mun", 0)


## `0x004752A0` -- the rounds a record is filled to: the weapon's `mun`,
## doubled when the unit carries an Ammo Pack (`+0x27`, equipment 6).
##
## The engine stores the answer in the record's `+0x3D` **byte**, so a doubled
## 255 lands as 254 rather than saturating. Transcribed rather than guarded:
## the truncation is what the store does, and inventing a clamp here would put
## a number in the record that the original never writes.
func magazine_for(weapon_id: int, double_munition: bool) -> int:
	return fill(magazine(weapon_id), double_munition)


## [method magazine_for] over a `mun` the caller already holds -- a balance
## row, where no table is at hand. The one place the rule is written.
static func fill(mun: int, double_munition: bool) -> int:
	return (mun * 2) & 0xFF if double_munition else mun


## [method fill] for *unit*'s own kit: the rounds its record is filled to.
static func fill_for(unit: UnitState, mun: int) -> int:
	return fill(mun, unit.has_equipment(Interact.EQUIP_DOUBLE_MUNITION))


## The rounds *unit* is filled to with the weapon it carries.
func magazine_of(unit: UnitState) -> int:
	return fill_for(unit, magazine(unit.weapon))


## docs/21 section 6 -- `Hit (%)`, the accuracy the curve starts from.
func hit(weapon_id: int) -> int:
	return _field(weapon_id, "hit", 0)


## The damage a full-strength marker rolls for.
func damage(weapon_id: int) -> int:
	return _field(weapon_id, "damage", 0)


## The range gate is **inclusive at both ends**.
func range_min(weapon_id: int) -> int:
	return _field(weapon_id, "range_min", 0)


func range_max(weapon_id: int) -> int:
	# 0 would make the curve divide by zero; the one placeholder weapon that
	# has it also has no target pattern, so it can never be fired.
	return _field(weapon_id, "range_max", 1)


## The weapon type. docs/22 section 8: types 0, 2, 3 and 4 take *damage* from an
## overheat where the rest merely jam.
func type_of(weapon_id: int) -> int:
	return _field(weapon_id, "type", 0)


## The raw enumerator. 6 means "aim at where the target stood when the turn
## began", the only reader of unit `+0x51`/`+0x52`.
func special(weapon_id: int) -> int:
	return _field(weapon_id, "special", 0)


## docs/21 section 4 -- `Def Mod`. Non-zero means the weapon can go on
## overwatch; the two gates differ only on the value 4, which never ships.
func def_mode(weapon_id: int) -> int:
	return _field(weapon_id, "def_mode", 0)


## Rounds spent per shot.
func mun_per_fight(weapon_id: int) -> int:
	return _field(weapon_id, "mun_per_fight", 0)


## `weapon[+0x42]` -- the `uweapons.LIB` element the unit panel draws for
## this weapon (`0x00474354`, docs/43 section 5).
func icon(weapon_id: int) -> int:
	return _field(weapon_id, "icon", 0)


## The weapon's own name, `weapon[+0x01]` -- what the unit panel writes beside
## its frame. Empty for an id with no row.
func name_of(weapon_id: int) -> String:
	if not _rows.has(weapon_id):
		return ""
	var row: Dictionary = _rows[weapon_id]
	return DictRead.as_string(row.get("name", ""))


## `weapon[+0x3C]` -- the movement points one shot costs.
##
## docs/23 section 4: the computer's fire routine refuses before it marks
## anything when `u->mp < ap`, and subtracts this afterwards with a clamp at
## zero, so a unit is never left owing points. The fallback is 0 rather than a
## refusal because an id with no row has no cost either, and the eligibility
## test above it is what keeps such a weapon from firing.
func ap(weapon_id: int) -> int:
	return _field(weapon_id, "ap", 0)


## `weapon[+0x3F]` -- docs/21 section 6's `param`, the id a `special` names.
##
## For `special` 1 it is the **close-combat** weapon, and the pairing is
## symmetric: each of the three guns names its bayonet and each bayonet names
## the gun back, which is how `0x0046F7E0` gets away with one field for both
## directions ([method Combat.close_combat_swap]).  `special` 2 and 3 read the
## same byte for their own replacements.
##
## `aBuildTargetOverlay` `0x0042FF30` reads it a third way, and that one is
## **not** close combat: a unit whose weapon is jammed or empty falls back to
## `param` if and only if its `special` is 1, which is what
## [method AIOverlay.effective_weapon] models.  So the same field is the
## bayonet a rifle stabs with and the one it is left holding when the magazine
## is gone.
func param(weapon_id: int) -> int:
	return _field(weapon_id, "param", weapon_id)
