class_name TerrainDiff
extends RefCounted

## Which cells changed between two terrain snapshots.
##
## `core` carries no dirty flag and the original has none either. Instead
## `game` keeps the last snapshot it drew and compares it with the next one:
## two immutable views, and the difference between them is `game`'s own.
## Nothing here reaches into `core`, and `core` gains no concept.
##
## **The rule this exists to serve is that the picture is a function of the
## state, not an accumulation of edits.** A cell that changed is rebuilt from
## the live snapshot; the diff only says *which*, so that a 40 × 40 map does
## not rebuild 1 600 cells because one door opened. If the diff were ever
## wrong the picture would be stale, never inconsistent -- which is the right
## failure to have.
##
## The comparison is four `Packed*Array` compares in the common case where
## nothing changed at all, which Godot does as a memcmp.

## The snapshot arrays a change in which has to be redrawn. `action_point` and
## the effect planes are deliberately **not** here: they change what the
## overlay tints, not what the scenery is, and the overlay is rebuilt whole.
const DRAWN_ARRAYS: Array[String] = ["height_map", "field_type", "unit"]


## `true` when the two snapshots would draw the same picture.
static func same(before: Dictionary, after: Dictionary) -> bool:
	if before.is_empty() or after.is_empty():
		return false
	for name: String in DRAWN_ARRAYS:
		if not before.has(name) or not after.has(name):
			return false
		if before[name] != after[name]:
			return false
	return true


## The cell indices whose height, field type or occupant changed.
##
## An empty answer means nothing moved. A snapshot of a different size -- a
## mission switch -- answers *every* cell rather than none, because "nothing
## comparable" must not read as "nothing changed".
static func changed_cells(before: Dictionary,
		after: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if after.is_empty():
		return out
	var count: int = DictRead.as_int(after["width"]) \
		* DictRead.as_int(after["height"])
	if before.is_empty() or DictRead.as_int(before["width"]) \
			!= DictRead.as_int(after["width"]) \
			or DictRead.as_int(before["height"]) \
			!= DictRead.as_int(after["height"]):
		out.resize(count)
		for index: int in range(count):
			out[index] = index
		return out
	if same(before, after):
		return out
	var heights_a: PackedInt32Array = before["height_map"]
	var heights_b: PackedInt32Array = after["height_map"]
	var types_a: PackedByteArray = before["field_type"]
	var types_b: PackedByteArray = after["field_type"]
	var units_a: PackedInt32Array = before["unit"]
	var units_b: PackedInt32Array = after["unit"]
	for index: int in range(count):
		if heights_a[index] != heights_b[index] \
				or types_a[index] != types_b[index] \
				or units_a[index] != units_b[index]:
			out.append(index)
	return out


## The cells whose **height** changed, which is the subset the scenery has to
## move. A field-type flip repaints the overlay and moves nothing.
static func moved_cells(before: Dictionary,
		after: Dictionary) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if before.is_empty() or after.is_empty():
		return out
	if not before.has("height_map") or not after.has("height_map"):
		return out
	var a: PackedInt32Array = before["height_map"]
	var b: PackedInt32Array = after["height_map"]
	if a == b or a.size() != b.size():
		return out
	for index: int in range(a.size()):
		if a[index] != b[index]:
			out.append(index)
	return out
