class_name WeaponTable
extends RefCounted

## `Info.lcl`'s `SetWeaponInfo` rows -- docs/21 section 6.
##
## The turn reads three columns of it: `heat` to know whether a weapon cools at
## all, `toggle` to revert an alternate fire mode, and `mun` for the magazine.
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


func _field(weapon_id: int, key: String, fallback: int) -> int:
	if not _rows.has(weapon_id):
		return fallback
	var row: Dictionary = _rows[weapon_id]
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
