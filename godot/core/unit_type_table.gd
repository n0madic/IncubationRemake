class_name UnitTypeTable
extends RefCounted

## `SetUnitInfo`, reduced to the columns the slice reads (docs/21 section 5).
##
## `special` is left as the raw enumerator.  The values have no names anywhere
## in the binary -- it is a hand-written switch on an integer -- and inventing
## some would be the kind of guess this project's rules forbid.

## docs/23 section 7.1 -- the two values for which the map comes back empty.
const SPECIAL_CANNOT_MOVE: Array[int] = [1, 14]
## docs/23 section 7.5 -- the innate warper.
const SPECIAL_CAN_WARP: int = 15
## docs/21 section 5 -- `unitinfo[+0x7b]`; 1 spills past its own field.
const SIZE_LARGE: int = 1
## docs/21 section 5 -- `unitinfo[+0x7c]` counts levels of this many world units.
const HEIGHT_UNIT: int = 160

var _rows: Dictionary = {}


## **This narrows, and the narrowing is the loading boundary.**
##
## `JSON.parse_string` makes a `float` of every number, so each column is
## converted once here rather than at every read (CLAUDE.md; docs/92 section
## 7). The cost is that a column absent from this list is absent from the
## table whatever the cache holds -- `armour_front` was, and
## [method UnitTypeTable.armour_front] answered its fallback of 0 for every
## type while `tables/balance.json` carried the real value all along. It
## surfaced as two wrong bytes on the two units that fired in an AI turn.
##
## `test_cache.gd` checks the published rows against the accessors' column
## list; a column added to an accessor has to be added **here** as well.
static func from_rows(rows: Array) -> UnitTypeTable:
	var table: UnitTypeTable = UnitTypeTable.new()
	for row: Variant in rows:
		var record: Dictionary = row
		table._rows[DictRead.as_int(record["id"])] = {
			"mp_max": DictRead.as_int(record["mp_max"]),
			"fp_max": DictRead.as_int(record["fp_max"]),
			"hp_max": DictRead.as_int(record["hp_max"]),
			"special": DictRead.as_int(record["special"]),
			"size": DictRead.as_int(record["size"]),
			"species": DictRead.as_int(record["species"]),
			"height": DictRead.as_int(record["height"]),
			"armour_front": DictRead.as_int(record.get("armour_front", 0)),
			"armour_rear": DictRead.as_int(record.get("armour_rear", 0)),
			"model": DictRead.as_string(record["model"]),
			"description": DictRead.as_string(record["description"]),
		}
	return table


func size() -> int:
	return _rows.size()


func has(type_id: int) -> bool:
	return _rows.has(type_id)


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
func _field(type_id: int, key: String, fallback: int) -> int:
	if not _rows.has(type_id):
		return fallback
	var record: Dictionary = _rows[type_id]
	if not record.has(key):
		return fallback
	return DictRead.as_int(record[key])


func mp_max(type_id: int) -> int:
	return _field(type_id, "mp_max", 0)


## docs/21 section 5 column 7 -- a **flag**, not a value: the shipped file sets
## it to 0 for every human type and 255 for everything else, so 255 means "this
## kind has no fitness at all" and any other value means the cap comes from the
## rank instead.
func fp_max(type_id: int) -> int:
	return _field(type_id, "fp_max", 0)


func hp_max(type_id: int) -> int:
	return _field(type_id, "hp_max", 0)


func special(type_id: int) -> int:
	return _field(type_id, "special", 0)


## docs/21 section 5 -- the front armour column, or 255 for "derive it from
## the four armour equipment items" (docs/10 section 5.4).
func armour_front(type_id: int) -> int:
	return _field(type_id, "armour_front", 0)


func armour_rear(type_id: int) -> int:
	return _field(type_id, "armour_rear", 0)


func unit_size(type_id: int) -> int:
	return _field(type_id, "size", 0)


func species(type_id: int) -> int:
	return _field(type_id, "species", 0)


## `unitinfo[+0x7c]`, in 160-world-unit levels.
func body_height(type_id: int) -> int:
	return _field(type_id, "height", 0)


## `0x0047ad70` returns `unitinfo[+0x7c] * 0xa0` as the unit's world height.
func body_height_world(type_id: int) -> int:
	return body_height(type_id) * HEIGHT_UNIT


func model(type_id: int) -> String:
	if not _rows.has(type_id):
		return ""
	var record: Dictionary = _rows[type_id]
	return DictRead.as_string(record["model"])


func description(type_id: int) -> String:
	if not _rows.has(type_id):
		return "type %d" % type_id
	var record: Dictionary = _rows[type_id]
	return DictRead.as_string(record["description"])
