class_name Blob
extends RefCounted

## One 88-byte record out of `aBlobs.cpp`'s pool, in the fields the update sees.
##
## docs/28 section 7.2: the record is **not** a flat struct. Bytes `+0x04` to
## `+0x43` are an Eng3d `object_3d`, the same 64-byte record `0x00404F80`
## builds for a world object, and the blob's own fields start at `+0x44`. That
## is what fixes the layout; the names here follow
## `tools/blob_runtime.py`'s, which is the transcription this class is diffed
## against tick by tick.
##
## **The field widths are the original's, and they matter.** Position and
## velocity are signed 32-bit; rotations, atlas columns and joint angles are
## unsigned 16-bit; kind, life, delay, class and `+0x54` are bytes. GDScript
## integers are 64-bit, so every store an arm makes goes through [IncInt] --
## a rotation that wrapped at 2^63 instead of 2^16 would look right for a long
## time and then not.
##
## **`class` decides what three of these fields mean.** For classes 0 and 1 the
## blob is a `.3DI` model and `rot_x/rot_y/rot_z` are its rotation; for classes
## 2 and 3 it is a textured quad and `rot_x` is the atlas **row**, `rot_y` the
## atlas **column** and `aux` the sprite half-size. `rot_z` is read by nothing
## on the sprite path. One field, two readings, and the arms know which.

## `+0x00` -- non-zero marks the slot taken.
var in_use: bool = true
## `+0x14`, `+0x18`, `+0x1C` -- position, in world units.
var x: int = 0
var y: int = 0
var z: int = 0
## `+0x24`, `+0x26`, `+0x28` -- rotation for a model, `(row, column, unused)`
## for a sprite.
var rot_x: int = 0
var rot_y: int = 0
var rot_z: int = 0
## `+0x2A` .. `+0x34` -- the two joint-angle triples of docs/28 section 7.8,
## written by exactly two arms and read by the renderer.
var angle0: int = 0
var angle1: int = 0
var angle2: int = 0
var angle3: int = 0
var angle4: int = 0
var angle5: int = 0
## `+0x48`, `+0x4C`, `+0x50` -- three per-kind parameters, velocity for every
## ballistic kind and a target for the few that are not.
var vx: int = 0
var vy: int = 0
var vz: int = 0
## `+0x54` -- the sprite half-size for classes 2 and 3, a free counter or a
## target id otherwise.
var aux: int = 0
## `+0x44` -- selects the update arm.
var kind: int = 0
## `+0x45` -- life in ticks; `0xFF` never expires and a zero argument aborts
## the constructor before anything is allocated.
var life: int = 0
## `+0x55` -- ticks to wait before the blob starts.
var delay: int = 0
## `+0x56`.
var class_id: int = 0
## `+0x0C` -- the prototype index, or `-1` for a sprite.
var model: int = -1
## The low byte of the record's own address, which kinds 25 and 56 branch on
## to mirror an animation. In the original it is where the record happens to
## live; here it is the slot index, which is the same kind of fact and is at
## least reproducible.
var slot_tag: int = 0
## False once the pool has taken the slot back.
var alive: bool = true


static func make(fields: Dictionary) -> Blob:
	var blob: Blob = Blob.new()
	blob.apply(fields)
	return blob


## Overwrite from a dictionary of the same field names, narrowing each to the
## width the original stores it at.
func apply(fields: Dictionary) -> void:
	for key: Variant in fields:
		var name: String = DictRead.as_string(key)
		match name:
			"in_use":
				in_use = _as_flag(fields[key])
			"alive":
				alive = _as_flag(fields[key])
			"x":
				x = IncInt.i32(DictRead.as_int(fields[key]))
			"y":
				y = IncInt.i32(DictRead.as_int(fields[key]))
			"z":
				z = IncInt.i32(DictRead.as_int(fields[key]))
			"vx":
				vx = IncInt.i32(DictRead.as_int(fields[key]))
			"vy":
				vy = IncInt.i32(DictRead.as_int(fields[key]))
			"vz":
				vz = IncInt.i32(DictRead.as_int(fields[key]))
			"rot_x":
				rot_x = IncInt.u16(DictRead.as_int(fields[key]))
			"rot_y":
				rot_y = IncInt.u16(DictRead.as_int(fields[key]))
			"rot_z":
				rot_z = IncInt.u16(DictRead.as_int(fields[key]))
			"angle0":
				angle0 = IncInt.u16(DictRead.as_int(fields[key]))
			"angle1":
				angle1 = IncInt.u16(DictRead.as_int(fields[key]))
			"angle2":
				angle2 = IncInt.u16(DictRead.as_int(fields[key]))
			"angle3":
				angle3 = IncInt.u16(DictRead.as_int(fields[key]))
			"angle4":
				angle4 = IncInt.u16(DictRead.as_int(fields[key]))
			"angle5":
				angle5 = IncInt.u16(DictRead.as_int(fields[key]))
			"aux":
				aux = IncInt.u8(DictRead.as_int(fields[key]))
			"kind":
				kind = IncInt.u8(DictRead.as_int(fields[key]))
			"life":
				life = IncInt.u8(DictRead.as_int(fields[key]))
			"delay":
				delay = IncInt.u8(DictRead.as_int(fields[key]))
			"class_id":
				class_id = IncInt.u8(DictRead.as_int(fields[key]))
			"model":
				model = DictRead.as_int(fields[key])
			"slot_tag":
				slot_tag = IncInt.u8(DictRead.as_int(fields[key]))


## The record as the fixture writes it -- booleans as 0/1, because that is what
## a comparison against JSON can be exact about.
func to_dict() -> Dictionary:
	return {
		"in_use": 1 if in_use else 0,
		"x": x, "y": y, "z": z,
		"rot_x": rot_x, "rot_y": rot_y, "rot_z": rot_z,
		"angle0": angle0, "angle1": angle1, "angle2": angle2,
		"angle3": angle3, "angle4": angle4, "angle5": angle5,
		"vx": vx, "vy": vy, "vz": vz,
		"aux": aux, "kind": kind, "life": life, "delay": delay,
		"class_id": class_id, "model": model, "slot_tag": slot_tag,
		"alive": 1 if alive else 0,
	}


func duplicate_blob() -> Blob:
	return Blob.make(to_dict())


## A sprite blob draws a tile out of the atlas; a model blob draws geometry.
func is_sprite() -> bool:
	return class_id >= 2


func _as_flag(value: Variant) -> bool:
	# The fixture writes 0/1 and the game passes `true`/`false`; both mean the
	# same thing and going through `int` handles either without a branch that
	# would quietly accept a string.
	return DictRead.as_int(value) != 0 if typeof(value) != TYPE_BOOL \
		else DictRead.as_bool(value)
