class_name CtrlMapTable
extends RefCounted

## `SetCtrlMapInfo`'s movement column (docs/21 section 2).
##
## Eleven control-map types, of which the only field the fill reads is `delay`:
## a step costs `delay + 1`, and 255 means the field cannot be entered at all --
## a test `aBuildMoveMap` makes before it looks at the height.

## docs/21 section 2 -- 255 in the delay column.
const IMPASSABLE: int = 255

var _delay: PackedInt32Array = PackedInt32Array()
var _names: PackedStringArray = PackedStringArray()


static func from_rows(rows: Array) -> CtrlMapTable:
	var table: CtrlMapTable = CtrlMapTable.new()
	var highest: int = -1
	for row: Variant in rows:
		var record: Dictionary = row
		highest = maxi(highest, DictRead.as_int(record["index"]))
	table._delay.resize(highest + 1)
	table._names.resize(highest + 1)
	table._delay.fill(IMPASSABLE)
	for row: Variant in rows:
		var record: Dictionary = row
		var index: int = DictRead.as_int(record["index"])
		table._delay[index] = DictRead.as_int(record["delay"])
		table._names[index] = DictRead.as_string(record["name"])
	return table


func size() -> int:
	return _delay.size()


func delay(field_type: int) -> int:
	if field_type < 0 or field_type >= _delay.size():
		return IMPASSABLE
	return _delay[field_type]


func is_enterable(field_type: int) -> bool:
	return delay(field_type) != IMPASSABLE


func type_name(field_type: int) -> String:
	if field_type < 0 or field_type >= _names.size():
		return "type %d" % field_type
	return _names[field_type]
