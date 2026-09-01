class_name Eng3dGeometry
extends RefCounted

## The engine's fixed-point geometry, measured rather than invented.
##
## `docs/28` section 12 item 1 said the five services an update arm calls
## outside its own record had never been measured, and [BlobHooks] therefore
## carried a *documented substitute* for the orientation one: an `atan2` over a
## 0..0xFFFF turn, chosen because nothing better was available. It was wrong in
## the unit and wrong in the pitch.
##
## `tools/blob_gold.py`'s `hooks` phase now calls `0x00403AA0` inside a running
## `Incubation.exe` over twenty deltas and reads what it writes. The routine:
##
## 1. takes the **yaw** straight out of the horizontal delta with the engine's
##    two-argument angle helper -- a **4096-unit circle**, `docs/70`'s binary
##    degrees, 0 along `+y` and 1024 along `+x`;
## 2. builds a Q14 rotation matrix for that yaw and turns the whole delta flat
##    with it;
## 3. takes a second angle from the two components that survive and subtracts
##    a quarter turn, which is the `sub eax, 0x400` at `0x00403B21`.
##
## So level is 0, straight up is -1024, and a delta of length 1 rounds away
## entirely. This class reproduces all twenty captured pairs exactly, and
## `tools/inclib/eng3d.py` is its twin on the Python side -- the two read the
## same shipped tables, so the diff in `tests/test_blob.gd` compares two
## transcriptions of one measurement rather than two guesses.
##
## **The tables come from the cache, not from a formula.** `docs/70`'s first
## open question is that the rounding Blue Byte generated them with is unknown;
## `tools/img_tables.py` can only show the formula agrees to within one unit,
## and one unit of a 4096-unit circle is one unit of every angle built on it.
##
## What is **not** here: Eng3d's own three-angle matrix builder behind
## `0x004039A0`. The capture holds its eight cases and no ordering of
## `Rz Rx Ry` with either rounding reproduces them, so it stays measured and
## unreproduced -- see `docs/28` section 12.

## A full turn. Binary degrees; **not** 65536ths.
const ANGLE_UNITS: int = 4096
## `ATN.IMG` is indexed by `(min / max) * 1024`.
const ATAN_INPUT_SCALE: int = 1024
## The Q14 denominator every product is divided by.
const Q14_SHIFT: int = 14
## Where the cosine window starts inside `TRIG.IMG`.
const COSINE_OFFSET: int = 1024
const TRIG_ENTRIES: int = 5120
const ATAN_ENTRIES: int = 1025
const TRIG_MASK: int = 4095

var _trig: PackedInt32Array = PackedInt32Array()
var _atn: PackedInt32Array = PackedInt32Array()


## Read `tables/trig.json` out of a published cache.
static func from_cache(cache_dir: String) -> Eng3dGeometry:
	var raw: Dictionary = CacheLoader.read_json(cache_dir + "/tables/trig.json")
	return from_document(raw)


## Narrow a parsed document into typed arrays.
##
## `JSON.parse_string` produces a `float` for every number, so the narrowing
## happens once, here, at the loading boundary -- the same rule `core/` follows
## for the cache it reads.
static func from_document(raw: Dictionary) -> Eng3dGeometry:
	var made: Eng3dGeometry = Eng3dGeometry.new()
	made._trig = _narrow(raw.get("trig", []))
	made._atn = _narrow(raw.get("atn", []))
	return made


static func _narrow(values: Variant) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if not (values is Array):
		return out
	var raw: Array = values
	for value: Variant in raw:
		out.append(DictRead.as_int(value))
	return out


## Whether both tables arrived at their shipped lengths.
##
## Empty is not an error state to paper over: a caller with no tables must use
## the substitute and **say so**. `tools/blob_runtime.py --emit-cases` writes
## `"orient": "substitute"` into the fixture when it had no game root, and
## `tests/test_blob.gd` fails on that field rather than quietly comparing two
## different orientation helpers.
func is_loaded() -> bool:
	return _trig.size() == TRIG_ENTRIES and _atn.size() == ATAN_ENTRIES


func sine(turn: int) -> int:
	return _trig[turn & TRIG_MASK]


func cosine(turn: int) -> int:
	return _trig[(turn & TRIG_MASK) + COSINE_OFFSET]


## `[0x004FA4E0]` -- the angle of `(a, b)`, measured from `+b` toward `+a`.
##
## `angle(0, 0)` is 0 and `angle(a, 0)` for a non-zero `a` is 1024; both are
## captured answers rather than conventions chosen here.
func angle(a: int, b: int) -> int:
	var quadrant: int = _first_quadrant(absi(a), absi(b))
	if a >= 0:
		return quadrant if b >= 0 else ANGLE_UNITS / 2 - quadrant
	return ANGLE_UNITS / 2 + quadrant if b < 0 else ANGLE_UNITS - quadrant


func _first_quadrant(a: int, b: int) -> int:
	if b == 0:
		return ANGLE_UNITS / 4 if a != 0 else 0
	if a <= b:
		return _atn[(a * ATAN_INPUT_SCALE) / b]
	return ANGLE_UNITS / 4 - _atn[(b * ATAN_INPUT_SCALE) / a]


## `cdq / and edx, 0x3FFF / add / sar 14` -- divide toward zero.
##
## What the **matrix builder** does. It is not what the transform does, and
## both appear inside one call to `0x00403AA0`.
static func trunc_shift(value: int) -> int:
	return -((-value) >> Q14_SHIFT) if value < 0 else value >> Q14_SHIFT


## `sar 14` -- divide toward negative infinity. What Eng3d's transform does.
static func floor_shift(value: int) -> int:
	return value >> Q14_SHIFT


## `0x004039F0` -- the two-angle Q14 matrix, row major.
##
## With both angles zero the diagonal is 16383, 16382, 16383: the engine's
## identity is not one, which is where a coordinate of 1000 becomes 999.
func matrix(a: int, b: int) -> PackedInt32Array:
	var sa: int = sine(a)
	var ca: int = cosine(a)
	var sb: int = sine(b)
	var cb: int = cosine(b)
	var out: PackedInt32Array = PackedInt32Array()
	out.append(cb)
	out.append(-trunc_shift(sb * ca))
	out.append(trunc_shift(sb * sa))
	out.append(sb)
	out.append(trunc_shift(cb * ca))
	out.append(-trunc_shift(cb * sa))
	out.append(0)
	out.append(sa)
	out.append(ca)
	return out


## Eng3d's `[0x004F84D4]` -- `m * v`, rounded the way it rounds.
static func transform(m: PackedInt32Array, v: Vector3i) -> Vector3i:
	return Vector3i(
		floor_shift(m[0] * v.x + m[1] * v.y + m[2] * v.z),
		floor_shift(m[3] * v.x + m[4] * v.y + m[5] * v.z),
		floor_shift(m[6] * v.x + m[7] * v.y + m[8] * v.z))


## `0x00403AA0` -- `(pitch, yaw)` in 4096ths, as the arms receive them.
func orient(from: Vector3i, at: Vector3i) -> Vector2i:
	var delta: Vector3i = at - from
	var yaw: int = angle(delta.x, delta.y)
	var flat: Vector3i = transform(matrix(0, yaw), delta)
	return Vector2i(angle(flat.y, flat.z) - ANGLE_UNITS / 4, yaw)
