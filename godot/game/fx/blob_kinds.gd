class_name BlobKinds
extends RefCounted

## `aBlob_Update` (`0x0041E500`): the wrapper, and all seventy-four arms.
##
## docs/28 section 7.4 is the shape and `tools/blob_runtime.py` is the
## transcription this file is diffed against, tick by tick and field by field,
## by `tests/test_blob.gd`. The arms are short pieces of particle arithmetic
## with no names in either binary; what makes them legible is that every kind
## is named by the creators that pass it, and those creators do carry the
## developers' own names.
##
## **The wrapper's order is the original's and is load-bearing:**
##
## 1. a non-zero `delay` is decremented and the tick ends -- the blob is not
##    live yet, and its life is not touched;
## 2. a zero `life`, or a `z` that has gone negative, deletes the blob;
## 3. unless `life` is `0xFF`, it is decremented -- **before** dispatch, so
##    every arm sees the decremented value. Half the arms branch on it, so an
##    arm that saw the pre-decrement value would be off by one everywhere;
## 4. `switch (kind)` over a 78-entry table with **74** distinct destinations.
##
## **Seventy-eight kinds, seventy-four arms.** 21/24, 23/40, 48/53 and 66/70
## are aliases in the jump table, and the aliasing is reproduced explicitly
## rather than by writing the body twice: a table with 78 distinct functions
## would pass every field comparison and still be a different program.
##
## **Eleven kinds are unreachable** -- 2, 4, 21, 28, 30, 35, 45, 48, 53, 56 and
## 76. No shipped call passes them, no computed site can produce them and
## nothing morphs into them. They are ported anyway, because a partial port
## makes a partial comparison; the suite asserts their *unreachability* rather
## than their behaviour.

## `0xFF` -- a life that never expires.
const IMMORTAL: int = 0xFF
## The ballistic gravity split of docs/28 section 7.4: a blob falls hard while
## it is young and drifts once it is nearly spent.
const GRAVITY_SPLIT: int = 10
const GRAVITY_HIGH: int = -640
const GRAVITY_LOW: int = -32

## Constructor entry points, by the address the arm calls. Keeping the
## addresses makes a spawn in a remake trace comparable with a static one.
const CREATE_ZOOM_BOB: int = 0x423720
const CREATE_PARA_BOMB: int = 0x42B150
const CREATE_BARREL_DEBRIS: int = 0x42B300
const CREATE_HITTING_BLOBS: int = 0x42A410
const CREATE_HITTING_BLOBS_2: int = 0x42A480
const CREATE_HITTING_BLOBS_3: int = 0x42A7A0
const CREATE_SPORE_SPARKS: int = 0x428E30
const CREATE_PLASMA_SPARKS: int = 0x428ED0
const CREATE_PLASMA_SPARKS_2: int = 0x428F70
const CREATE_STING_SPARKS: int = 0x429430
const CREATE_SPORES: int = 0x429390
const CREATE_LASER_HIT: int = 0x42A9D0
const CREATE_EMITTER: int = 0x420950
## The scratch buffer classes 2 and 3 pass as a model name and never read.
const NAME_SCRATCH: int = 0x4FA524

## Kind 49 rewrites its own `+0x44` -- the only kind write in the whole update.
const MORPH_TO: int = 7
const MORPH_LIFE: int = 6

const KIND_COUNT: int = 78
const UNREACHABLE: Array[int] = [2, 4, 21, 28, 30, 35, 45, 48, 53, 56, 76]
## The jump table's four aliased pairs.
const ALIASES: Array[Vector2i] = [
	Vector2i(21, 24), Vector2i(23, 40), Vector2i(48, 53), Vector2i(66, 70)]


## What one tick did, beside what it wrote into the record.
##
## `delete_requested` and `deleted` are deliberately separate, exactly as they
## are in the Python reference: the original's global `0x4FE63C` signal and the
## pool-deletion call at `0x0041E320` are two different things, and an arm that
## raised the signal has not freed its slot.
class TickResult extends RefCounted:
	var ran: bool = false
	var delayed: bool = false
	var dispatched: bool = false
	var deleted: bool = false
	var delete_requested: bool = false
	var global_signal: bool = false
	var target_missing: bool = false
	var model_missing: bool = false
	var spawns: Array[Dictionary] = []
	var models: PackedStringArray = PackedStringArray()

	func to_dict() -> Dictionary:
		return {"ran": 1 if ran else 0, "delayed": 1 if delayed else 0,
			"dispatched": 1 if dispatched else 0,
			"deleted": 1 if deleted else 0,
			"delete_requested": 1 if delete_requested else 0,
			"global_signal": 1 if global_signal else 0,
			"target_missing": 1 if target_missing else 0,
			"model_missing": 1 if model_missing else 0,
			"spawns": spawns.duplicate(), "models": models.duplicate()}


## One update tick. The wrapper of docs/28 section 7.4, in its own order.
static func tick(blob: Blob, hooks: BlobHooks) -> TickResult:
	var result: TickResult = TickResult.new()
	result.ran = true
	if not blob.alive:
		return result
	if blob.delay != 0:
		blob.delay = IncInt.u8(blob.delay - 1)
		result.delayed = true
		return result
	if blob.life == 0 or blob.z < 0:
		_delete(blob, result)
		return result
	if blob.life != IMMORTAL:
		blob.life = IncInt.u8(blob.life - 1)
	result.dispatched = true
	_dispatch(blob, hooks, result)
	return result


## The 78-entry jump table. Written as a `match` over the kind rather than as
## an array of `Callable`s: the aliases have to be visible as aliases, and a
## table built by hand is the thing the suite is checking is right.
static func _dispatch(blob: Blob, h: BlobHooks, r: TickResult) -> void:
	match blob.kind:
		0: _kind_0(blob, h, r)
		1: _kind_1(blob, h, r)
		2: _kind_2(blob, h, r)
		3: _kind_3(blob, h, r)
		4: _kind_4(blob, h, r)
		5: _kind_5(blob, h, r)
		6: _kind_6(blob, h, r)
		7: _kind_7(blob, h, r)
		8: _kind_8(blob, h, r)
		9: _kind_9(blob, h, r)
		10: _kind_10(blob, h, r)
		11: _kind_11(blob, h, r)
		12: _kind_12(blob, h, r)
		13: _kind_13(blob, h, r)
		14: _kind_14(blob, h, r)
		15: _kind_15(blob, h, r)
		16: _kind_16(blob, h, r)
		17: _kind_17(blob, h, r)
		18: _kind_18(blob, h, r)
		19: _kind_19(blob, h, r)
		20: _kind_20(blob, h, r)
		21, 24: _kind_21(blob, h, r)
		22: _kind_22(blob, h, r)
		23, 40: _kind_23(blob, h, r)
		25: _kind_25(blob, h, r)
		26: _kind_26(blob, h, r)
		27: _kind_27(blob, h, r)
		28: _kind_28(blob, h, r)
		29: _kind_29(blob, h, r)
		30: _kind_30(blob, h, r)
		31: _kind_31(blob, h, r)
		32: _kind_32(blob, h, r)
		33: _kind_33(blob, h, r)
		34: _kind_34(blob, h, r)
		35: _kind_35(blob, h, r)
		36: _kind_36(blob, h, r)
		37: _kind_37(blob, h, r)
		38: _kind_38(blob, h, r)
		39: _kind_39(blob, h, r)
		41: _kind_41(blob, h, r)
		42: _kind_42(blob, h, r)
		43: _kind_43(blob, h, r)
		44: _kind_44(blob, h, r)
		45: _kind_45(blob, h, r)
		46: _kind_46(blob, h, r)
		47: _kind_47(blob, h, r)
		49: _kind_49(blob, h, r)
		50: _kind_50(blob, h, r)
		51: _kind_51(blob, h, r)
		52: _kind_52(blob, h, r)
		54: _kind_54(blob, h, r)
		55: _kind_55(blob, h, r)
		56: _kind_56(blob, h, r)
		57: _kind_57(blob, h, r)
		58: _kind_58(blob, h, r)
		59: _kind_59(blob, h, r)
		60: _kind_60(blob, h, r)
		61: _kind_61(blob, h, r)
		62: _kind_62(blob, h, r)
		63: _kind_63(blob, h, r)
		64: _kind_64(blob, h, r)
		65: _kind_65(blob, h, r)
		66, 70: _kind_66(blob, h, r)
		67: _kind_67(blob, h, r)
		68: _kind_68(blob, h, r)
		69: _kind_69(blob, h, r)
		71: _kind_71(blob, h, r)
		72: _kind_72(blob, h, r)
		73: _kind_73(blob, h, r)
		74: _kind_74(blob, h, r)
		75: _kind_75(blob, h, r)
		76: _kind_76(blob, h, r)
		77: _kind_77(blob, h, r)
		# 48 and 53 share the switch's default arm, so an out-of-range kind
		# and those two do the same nothing.
		_: _kind_53(blob, h, r)


# --- the shared steps -------------------------------------------------------

static func _move(blob: Blob, move_z: bool = true) -> void:
	blob.x = IncInt.i32(blob.x + blob.vx)
	blob.y = IncInt.i32(blob.y + blob.vy)
	if move_z:
		blob.z = IncInt.i32(blob.z + blob.vz)


static func _move_quarter(blob: Blob) -> void:
	blob.x = IncInt.i32(blob.x + IncInt.div_trunc(blob.vx, 4))
	blob.y = IncInt.i32(blob.y + IncInt.div_trunc(blob.vy, 4))
	blob.z = IncInt.i32(blob.z + IncInt.div_trunc(blob.vz, 4))


static func _add_word(value: int, delta: int) -> int:
	return IncInt.u16(value + delta)


static func _set_aux(blob: Blob, value: int) -> void:
	blob.aux = IncInt.u8(value)


static func _add_aux(blob: Blob, delta: int) -> void:
	_set_aux(blob, blob.aux + delta)


## The arm raised `0x4FE63C`. The caller owns removal; the slot is still held.
static func _request_delete(_blob: Blob, r: TickResult) -> void:
	r.global_signal = true
	r.delete_requested = true


## `aDeleteBlobObject` (`0x0041E320`) -- the slot is freed here and now.
static func _delete(blob: Blob, r: TickResult) -> void:
	blob.in_use = false
	blob.alive = false
	r.deleted = true
	r.delete_requested = true


## Kind 14's direct `mov dword [blob+0], 0`. The effect is the same as
## [method _delete]'s; the *mechanism* is not -- one is a call to the pool's
## own routine and the other is a store straight into `+0x00`. Kept as its own
## name because a future reader tracing the arm will look for it.
static func _mark_free(blob: Blob, r: TickResult) -> void:
	_delete(blob, r)


static func _spawn(blob: Blob, h: BlobHooks, r: TickResult, creator: int,
		args: Array) -> bool:
	var ok: bool = h.spawn(creator, args, blob)
	r.spawns.append({"creator": creator, "args": args.duplicate(),
		"ok": 1 if ok else 0})
	return ok


static func _set_model(blob: Blob, h: BlobHooks, r: TickResult,
		name: String) -> void:
	r.models.append(name)
	var index: int = h.lookup_model(name)
	if index < 0:
		r.model_missing = true
		return
	blob.model = index


static func _orient(blob: Blob, h: BlobHooks, at: Vector3i,
		write_y: bool = true, zero_y: bool = false) -> void:
	var angles: Vector3i = h.orient(Vector3i(blob.x, blob.y, blob.z), at)
	blob.rot_x = IncInt.u16(angles.x)
	if write_y:
		blob.rot_y = IncInt.u16(angles.y)
	if zero_y:
		blob.rot_y = 0
	blob.rot_z = IncInt.u16(angles.z)


## The unit map had nothing to point at, so the arm returned without steering.
const SEEK_NO_TARGET: int = -1
## It steered and has not arrived.
const SEEK_MISS: int = 0
## It steered and is inside the box on all three axes.
const SEEK_HIT: int = 1
## `[0x004B1238]`, the double every seeker scales the direction service by.
const SEEK_PULL: float = -240.0
## Half the width of the box that counts as an arrival, per axis.
const SEEK_BOX: int = 0x640


## The seeking step kinds 26, 27 and 61 share -- docs/28 section 7.7.1.
##
## Three things here are the engine's rather than this file's, and all three
## were wrong until `tools/blob_gold.py` stepped a kind-26 and a kind-61 record
## inside a running `Incubation.exe`:
##
## 1. the steer comes from **`0x0046D400`**, which divides by whichever of
##    `|dx|` and `|dy|` is larger -- not by the true distance. The product with
##    -240.0 is truncated by `_ftol` and **subtracted**, so the two negatives
##    make a pull;
## 2. the orientation call takes the **step** -- where the record is about to
##    be -- not the target, so a seeker points along its own path;
## 3. an arrival sets `life` to zero and nothing else. The global signal is
##    each arm's own, and kinds 26 and 61 raise it for a spent life too, while
##    kind 27 raises it only for an arrival.
static func _seek(blob: Blob, h: BlobHooks, r: TickResult,
		z_offset: int = 0) -> int:
	if not h.has_target_for(blob):
		h.target_calls.append(blob.aux)
		r.target_missing = true
		return SEEK_NO_TARGET
	var found: Vector3i = h.target_position(blob)
	var at: Vector3i = Vector3i(IncInt.i32(found.x), IncInt.i32(found.y),
		IncInt.i32(found.z + z_offset))
	var steer: PackedFloat64Array = h.direction(blob, at)
	blob.vx = IncInt.i32(blob.vx - IncInt.div_trunc(blob.vx, 6)
		- Eng3dGeometry.ftol(steer[0] * SEEK_PULL))
	blob.vy = IncInt.i32(blob.vy - IncInt.div_trunc(blob.vy, 6)
		- Eng3dGeometry.ftol(steer[1] * SEEK_PULL))
	blob.vz = IncInt.i32(blob.vz - IncInt.div_trunc(blob.vz, 6)
		- Eng3dGeometry.ftol(steer[2] * SEEK_PULL))
	var step: Vector3i = Vector3i(IncInt.i32(blob.x + blob.vx),
		IncInt.i32(blob.y + blob.vy), IncInt.i32(blob.z + blob.vz))
	_orient(blob, h, step, false, true)
	_move(blob)
	if absi(step.x - at.x) < SEEK_BOX and absi(step.y - at.y) < SEEK_BOX \
			and absi(step.z - at.z) < SEEK_BOX:
		blob.life = 0
		return SEEK_HIT
	return SEEK_MISS


# --- the arms ---------------------------------------------------------------

static func _kind_0(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	# **0x1000 here.** Only kind 8's arm pushes `0xFFF`; this one and kinds 2
	# and 29 push `0x1000`. A pass that had stepped kind 8 and not these copied
	# the literal across all four, which stepping *these* -- with a donor
	# record's kind byte rewritten -- caught (docs/97 section 20).
	b.rot_x = IncInt.u16(h.random(0, 0x1000))
	b.rot_y = IncInt.u16(h.random(0, 0x1000))
	b.rot_z = IncInt.u16(h.random(0, 0x1000))
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)


static func _kind_1(b: Blob, _h: BlobHooks, r: TickResult) -> void:
	if b.life == 0:
		_request_delete(b, r)
	_move(b)


## Unreachable, and kept executable: it falls through the same tail as kind 49.
static func _kind_2(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	# **0x1000 here.** Only kind 8's arm pushes `0xFFF`; this one and kinds 2
	# and 29 push `0x1000`. A pass that had stepped kind 8 and not these copied
	# the literal across all four, which stepping *these* -- with a donor
	# record's kind byte rewritten -- caught (docs/97 section 20).
	b.rot_x = IncInt.u16(h.random(0, 0x1000))
	b.rot_y = IncInt.u16(h.random(0, 0x1000))
	b.rot_z = IncInt.u16(h.random(0, 0x1000))
	if b.life == 0:
		_request_delete(b, r)
		b.vx = h.random(0, 0x190)
		b.vy = h.random(0, 0x190)
		b.vz = h.random(0xC8, 0x190)
		b.life = MORPH_LIFE
		b.kind = MORPH_TO


static func _kind_3(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.rot_z = _add_word(b.rot_z, 0x12C)
	b.rot_x = _add_word(b.rot_x, 0x32)
	b.rot_y = _add_word(b.rot_y, 0x32)
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x50)
	if b.life == 1:
		_spawn(b, h, r, CREATE_BARREL_DEBRIS, [b.x, b.y, b.z])


static func _kind_4(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x0A)


static func _kind_5(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.rot_x = _add_word(b.rot_x, 0x64)
	b.rot_y = _add_word(b.rot_y, 0x64)
	b.rot_z = _add_word(b.rot_z, 0x64)
	b.vz = IncInt.i32(b.vz - 0x5A)


static func _kind_6(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_spawn(b, h, r, CREATE_ZOOM_BOB, [b.x, b.y, b.z, 4, 0x0A, 8])
	_move(b)
	b.rot_x = _add_word(b.rot_x, 0x64)
	b.rot_y = _add_word(b.rot_y, 0xC8)
	b.rot_z = _add_word(b.rot_z, 0x12C)
	b.vz = IncInt.i32(b.vz - 0x28)


static func _kind_7(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	_add_aux(b, 1)


static func _kind_8(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.x = IncInt.i32(b.x + h.random(-100, 200))
	b.y = IncInt.i32(b.y + h.random(-100, 200))
	b.z = IncInt.i32(b.z + h.random(-100, 200))
	# **0xFFF, not 0x1000** -- the three literals at `0x00420543`, `0x0042055B`
	# and `0x00420576`. Stepping a kind-8 record inside the retail process found
	# this one unit high on about a quarter of its draws.
	b.rot_x = IncInt.u16(h.random(0, 0xFFF))
	b.rot_y = IncInt.u16(h.random(0, 0xFFF))
	b.rot_z = IncInt.u16(h.random(0, 0xFFF))


static func _kind_9(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x140)
	b.rot_y = IncInt.u16(7 - (b.life >> 1))


static func _kind_10(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	if b.life < 9:
		b.rot_y = IncInt.u16(7 - (b.life >> 1))


## The one arm that frees its own slot through `aDeleteBlobObject`.
static func _kind_11(b: Blob, _h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)
	b.rot_x = _add_word(b.rot_x, 0x0A)
	b.rot_y = _add_word(b.rot_y, 0x0A)
	b.rot_z = _add_word(b.rot_z, 0x0A)
	# It does **not** delete: `0x004207B6` ends `mov eax, 1 / ret`, and the
	# `aDeleteBlobObject` two instructions later belongs to the wrapper's expiry
	# path. Stepping a kind-11 record inside the retail process for eight ticks
	# found it still moving where this arm had removed it.


static func _kind_12(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.rot_y = _add_word(b.rot_y, h.random(0, 0x1000))


# `0x66666667` with `sar edx, 3` is a divide by **20**: the magic is the same
# for 5, 10 and 20 and only the shift separates them.
static func _kind_13(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.x = IncInt.i32(b.x + b.vx)
	b.y = IncInt.i32(b.y + b.vy)
	b.vx = IncInt.i32(b.vx - IncInt.div_trunc(b.vx, 20))
	b.vy = IncInt.i32(b.vy - IncInt.div_trunc(b.vy, 20))


## Not ballistic: `vx`/`vy` are a **destination**, and the record's own x/y are
## the remaining delta. That is why the arm reads them the other way round.
##
## The remaining delta is **spun about the vertical** by `0x004039A0` before it
## is added back, through an angle read off `life`: twenty per point while the
## record is not rising, ten per point past 22 while it is. This model had no
## turn at all, which nothing could notice while no creator filled kind 14.
static func _kind_14(b: Blob, h: BlobHooks, r: TickResult) -> void:
	var dx: int = IncInt.i32(b.vx - b.x)
	var dy: int = IncInt.i32(b.vy - b.y)
	if b.life > 3:
		dx = IncInt.i32(dx - IncInt.div_trunc(dx, 10))
		dy = IncInt.i32(dy - IncInt.div_trunc(dy, 10))
	if b.life == 1:
		_mark_free(b, r)
	var turn: int = IncInt.u16(b.life * 20) if b.vz == 0 \
		else IncInt.u16((b.life - 22) * 10)
	var spun: Vector3i = h.rotate(Vector3i(dx, dy, 0), Vector3i(0, 0, turn))
	b.x = IncInt.i32(spun.x + b.vx)
	b.y = IncInt.i32(spun.y + b.vy)
	var angles: Vector3i = h.orient(Vector3i(b.vx, b.vy, 0),
		Vector3i(b.x, b.y, 0))
	b.rot_x = IncInt.u16(angles.x)
	b.rot_z = IncInt.u16(angles.z)


static func _kind_15(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_ZOOM_BOB,
			[b.x, b.y, b.z, 1, h.random(5, 15)])


static func _kind_16(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.z = IncInt.i32(b.z + 0x64)
	if b.life == 2:
		_set_model(b, h, r, "A_HIT2.3DI")


static func _kind_17(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x32)
	if b.life == 5:
		_set_model(b, h, r, "A_BLUT5.3DI")
	if b.life == 3:
		_set_model(b, h, r, "A_BLUT6.3DI")


static func _kind_18(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_x = _add_word(b.rot_x, 0x8C)
	b.rot_y = _add_word(b.rot_y, 0x8C)
	b.rot_z = _add_word(b.rot_z, 0x8C)
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)


# `sar edx, 1` after the same magic: a fifth, not a tenth.
static func _kind_19(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vx = IncInt.i32(b.vx - IncInt.div_trunc(b.vx, 5))
	b.vy = IncInt.i32(b.vy - IncInt.div_trunc(b.vy, 5))
	b.vz = IncInt.i32(b.vz - IncInt.div_trunc(b.vz, 5))
	if b.life == 0:
		_spawn(b, h, r, CREATE_HITTING_BLOBS, [b.x, b.y, b.z, 1])


static func _kind_20(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x28)


static func _kind_21(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x32)


static func _kind_22(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x50)
	b.rot_y = _add_word(b.rot_y, 1) if b.rot_y < 8 else 0
	_spawn(b, h, r, CREATE_SPORE_SPARKS, [b.x, b.y, b.z, 0x0A, 0x10])


static func _kind_23(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x32)
	b.rot_y = IncInt.u16(7 - (b.life >> 1))


static func _kind_25(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.rot_z = _add_word(b.rot_z, 0x55 if (b.slot_tag & 1) != 0 else -0x55)
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_BARREL_DEBRIS,
			[b.x, b.y, IncInt.i32(b.z - 0x3200)])


# `0x0041FAF7` reads `life` back **after** the hit test, so a seeker that
# simply ran out of life signals and spawns exactly like one that arrived.
static func _kind_26(b: Blob, h: BlobHooks, r: TickResult) -> void:
	if _seek(b, h, r) == SEEK_NO_TARGET:
		return
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_ZOOM_BOB, [b.x, b.y, b.z, 0, 30, 16])
		_spawn(b, h, r, CREATE_HITTING_BLOBS_3, [b.x, b.y, b.z, 1])


# The one seeker that aims 0x640 **above** its target, and the one whose signal
# sits inside the hit branch (`0x0041FD68`): a kind-27 record that merely
# expires writes nothing global.
static func _kind_27(b: Blob, h: BlobHooks, r: TickResult) -> void:
	if _seek(b, h, r, 0x640) == SEEK_HIT:
		_request_delete(b, r)


static func _kind_28(b: Blob, _h: BlobHooks, r: TickResult) -> void:
	if b.life == 0:
		_request_delete(b, r)


static func _kind_29(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	# **0x1000 here.** Only kind 8's arm pushes `0xFFF`; this one and kinds 2
	# and 29 push `0x1000`. A pass that had stepped kind 8 and not these copied
	# the literal across all four, which stepping *these* -- with a donor
	# record's kind byte rewritten -- caught (docs/97 section 20).
	b.rot_x = IncInt.u16(h.random(0, 0x1000))
	b.rot_y = IncInt.u16(h.random(0, 0x1000))
	b.rot_z = IncInt.u16(h.random(0, 0x1000))
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x0A)


static func _kind_30(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x32)


static func _kind_31(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz + 0x190)


static func _kind_32(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.rot_y = IncInt.u16(h.random(1, 10))
	_set_aux(b, h.random(5, 0x28))
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_STING_SPARKS, [b.x, b.y, b.z, b.vx, b.vy])


static func _kind_33(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.rot_y = IncInt.u16(7 - (b.life >> 1))
	_add_aux(b, 1)


static func _kind_34(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 1)


static func _kind_35(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_z = _add_word(b.rot_z, 0x32)


static func _kind_36(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.x = IncInt.i32(b.x + b.vx)
	b.y = IncInt.i32(b.y + b.vy)
	b.z = IncInt.i32(b.z - 0xA0)
	_spawn(b, h, r, CREATE_HITTING_BLOBS_2, [b.x, b.y, b.z, 5])


## Kind 14's turn with a fixed angle and the sign flipped: the delta to the
## point in `vx`/`vy` is spun by `0x66` and **subtracted** from it.
static func _kind_37(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	var spun: Vector3i = h.rotate(
		Vector3i(IncInt.i32(b.vx - b.x), IncInt.i32(b.vy - b.y), 0),
		Vector3i(0, 0, 0x66))
	b.x = IncInt.i32(b.vx - spun.x)
	b.y = IncInt.i32(b.vy - spun.y)
	var angles: Vector3i = h.orient(Vector3i(b.vx, b.vy, 0),
		Vector3i(b.x, b.y, 0))
	b.rot_x = IncInt.u16(angles.x)
	b.rot_z = IncInt.u16(angles.z)


static func _kind_38(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.rot_y = _add_word(b.rot_y, 0x66)


static func _kind_39(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_x = _add_word(b.rot_x, 0x80)
	b.rot_z = _add_word(b.rot_z, 0x80)
	b.rot_y = _add_word(b.rot_y, 0x66)
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)


## `aBlob_CreateWarningLight`: the whole object turns, at a rate that is a
## division by its own `vx`. A zero there is a division by zero in the
## original too, so the arm is written to notice rather than to crash.
static func _kind_41(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	if b.vx == 0:
		return
	b.rot_z = _add_word(b.rot_z, IncInt.div_trunc(0x200, b.vx))


## `aBlob_CreateComputerLight`, model `A_PANEL.3DI` -- one moving part. The
## plate flips between edge-on and face-on on a 50/50 roll every tick: that is
## the flicker (docs/28 section 7.8).
static func _kind_42(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.angle1 = IncInt.u16(0x400 if h.random(0, 100) < 50 else 0x1000)
	b.angle0 = IncInt.u16(b.rot_x)
	b.angle2 = IncInt.u16(b.rot_z)


static func _kind_43(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - (0x20 if b.life <= 10 else 0x280))
	if b.life == 10:
		b.vx = h.random(-0xA0, 0x140)
		b.vy = h.random(-0xA0, 0x140)


static func _kind_44(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x3C)
	b.rot_y = IncInt.u16(7 - (b.life >> 1))
	if b.life == 0:
		_spawn(b, h, r, CREATE_PLASMA_SPARKS, [b.x, b.y, b.z, 10, 10])


static func _kind_45(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move_quarter(b)
	b.rot_y = IncInt.u16(7 - (b.life >> 1))


static func _kind_46(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move_quarter(b)
	_add_aux(b, 1)
	b.rot_y = IncInt.u16(7 - b.life)


static func _kind_47(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.x = IncInt.i32(b.x + b.vx)
	b.y = IncInt.i32(b.y + b.vy)
	b.vx = IncInt.i32(b.vx - IncInt.div_trunc(b.vx, 7))
	b.vy = IncInt.i32(b.vy - IncInt.div_trunc(b.vy, 7))
	b.rot_y = IncInt.u16(7 - (b.life >> 1))
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_SPORES, [b.x, b.y, b.z, 20])


## `aBlob_CreateFlameStream`. The only `+0x44` write in the whole update: the
## flame turns into a short-lived remnant of kind 7 rather than being deleted.
static func _kind_49(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.rot_y = IncInt.u16(mini(4, 7 - (b.life >> 1)))
	_add_aux(b, 1)
	if b.life == 0:
		_request_delete(b, r)
		b.vx = h.random(0, 0x190)
		b.vy = h.random(0, 0x190)
		b.vz = h.random(0xC8, 0x190)
		b.life = MORPH_LIFE
		b.kind = MORPH_TO


static func _kind_50(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_y = IncInt.u16(7 - b.life)


static func _kind_51(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_y = IncInt.u16(7 - (b.life >> 1))


static func _kind_52(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.rot_y = _add_word(b.rot_y, 3)
	_move(b)
	b.vx = IncInt.i32(b.vx + 0x32)
	b.vy = IncInt.i32(b.vy + 0x32)
	if h.random(0, 8) == 0:
		_spawn(b, h, r, CREATE_PARA_BOMB, [b.x, b.y, b.z])


## The switch's default arm, shared with kind 48: it does nothing at all.
static func _kind_53(_b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	pass


## `aBlob_CreateCreateFire`, model `A_FIRE3.3DI` -- two parts, each given a
## fresh heading every tick, which is why the flames never settle.
static func _kind_54(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.angle2 = IncInt.u16(h.random(0, 0x1000))
	b.angle5 = IncInt.u16(h.random(0, 0x1000))


static func _kind_55(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_z = _add_word(b.rot_z, 0x33)


static func _kind_56(b: Blob, h: BlobHooks, r: TickResult) -> void:
	var delta: int = 0x28 if (b.slot_tag & 1) != 0 else -0x3C
	b.rot_x = _add_word(b.rot_x, delta)
	b.rot_y = _add_word(b.rot_y, delta)
	b.rot_z = _add_word(b.rot_z, delta)
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)
	if b.life == 0:
		_spawn(b, h, r, CREATE_ZOOM_BOB,
			[b.x, b.y, b.z, 1, h.random(2, 5)])


static func _kind_57(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.rot_z = IncInt.u16(h.random(0, 0x1000))


static func _kind_58(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	_add_aux(b, 1)
	if b.life < 9:
		b.rot_y = IncInt.u16(7 - (b.life >> 1))


## The ground-fire emitter, which calls the constructor directly rather than a
## named creator. `emitter_mode` stands for `0x00461E80`'s returned byte.
static func _kind_59(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.z = IncInt.i32(b.z + 0x258)
	b.vz = h.random(5, 15)
	if h.emitter_mode == 3:
		var r1: int = h.random(5, 10)
		var r2: int = h.random(-100, 200)
		var r3: int = h.random(-100, 200)
		_spawn(b, h, r, CREATE_EMITTER,
			[NAME_SCRATCH, 2, b.x, b.y, b.z, 1, 0, 0, 60, 8, r3, r2, r1, 0, 0])
	var size: int = h.random(5, 20)
	var rz: int = h.random(-1000, 2000)
	var ry: int = h.random(-1000, 2000)
	var rx: int = h.random(-1000, 2000)
	_spawn(b, h, r, CREATE_EMITTER,
		[NAME_SCRATCH, 2, b.x, b.y, b.z, 1, 0, 0, 60, 8, rx, ry, rz, size, 0])


# `0x55555556` with **no** shift is a third. The seeker's damping uses the
# negated magic and is a sixth; the two are one instruction apart.
static func _kind_60(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	b.rot_y = IncInt.u16(7 - b.life)
	_move(b)
	b.vx = IncInt.i32(b.vx - IncInt.div_trunc(b.vx, 3))
	b.vy = IncInt.i32(b.vy - IncInt.div_trunc(b.vy, 3))
	b.vz = IncInt.i32(b.vz - IncInt.div_trunc(b.vz, 3))


static func _kind_61(b: Blob, h: BlobHooks, r: TickResult) -> void:
	if _seek(b, h, r) == SEEK_NO_TARGET:
		return
	if b.life == 0:
		_request_delete(b, r)


## The x87 comparison is against the literal 5.0, so the burst is taken for a
## roll strictly greater than five -- the fractional part decides, which is
## why this is the one arm that reads the raw draw rather than the truncation.
static func _kind_62(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.rot_y = IncInt.u16(b.life)
	b.z = IncInt.i32(b.z - 0xA0)
	if h.random_float(0, 10) > 5.0:
		var rz: int = h.random(-1000, 2000)
		var ry: int = h.random(-1000, 2000)
		var rx: int = h.random(-1000, 2000)
		_spawn(b, h, r, CREATE_PLASMA_SPARKS,
			[IncInt.i32(b.x + rx), IncInt.i32(b.y + ry),
			 IncInt.i32(b.z + rz), 1, 10])
	if b.life == 0:
		_spawn(b, h, r, CREATE_EMITTER,
			[NAME_SCRATCH, 2, b.x, b.y, b.z, 4, 0, 0, 10, 10,
			 0x320, 0x14, 0, 0, 0])


static func _kind_63(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)


static func _kind_64(b: Blob, _h: BlobHooks, _r: TickResult) -> void:
	_move(b)


## Not ballistic either: `vx/vy/vz` are a destination and the arm closes a
## quarter of the remaining gap while it is far, then holds and re-rolls a
## size while it is near.
static func _kind_65(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	_set_aux(b, h.random(3, 10))
	if b.life >= 0x28:
		return
	if b.life == 10:
		b.vx = h.random(-0x640, 0xC80)
		b.vy = h.random(-0x640, 0xC80)
		b.vz = h.random(-0x640, 0xC80)
	if b.life <= 10:
		b.x = IncInt.i32(b.x - b.vx)
		b.y = IncInt.i32(b.y - b.vy)
		b.z = IncInt.i32(b.z - b.vz)
		b.rot_y = 0
		return
	var dx: int = IncInt.i32(b.x - b.vx)
	var dy: int = IncInt.i32(b.y - b.vy)
	var dz: int = IncInt.i32(b.z - b.vz)
	if absi(dx) > 0x32 and absi(dy) > 0x32 and absi(dz) > 0x32:
		b.x = IncInt.i32(b.x - IncInt.div_trunc(dx, 4))
		b.y = IncInt.i32(b.y - IncInt.div_trunc(dy, 4))
		b.z = IncInt.i32(b.z - IncInt.div_trunc(dz, 4))
		b.rot_y = 3
		_set_aux(b, 5)
	else:
		b.rot_y = 0
		_set_aux(b, h.random(3, 10))


static func _kind_66(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	_set_aux(b, h.random(3, 10))


static func _kind_67(b: Blob, h: BlobHooks, r: TickResult) -> void:
	b.z = IncInt.i32(b.z + 0x190)
	b.rot_y = IncInt.u16(h.random(0, 7))
	_set_aux(b, mini(b.life, 20))
	if b.life == 0:
		var rz: int = h.random(-1000, 2000)
		var ry: int = h.random(-1000, 2000)
		var rx: int = h.random(-1000, 2000)
		_spawn(b, h, r, CREATE_PLASMA_SPARKS,
			[IncInt.i32(b.x + rx), IncInt.i32(b.y + ry),
			 IncInt.i32(b.z + rz), 1, 10])


static func _kind_68(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	b.rot_y = IncInt.u16(h.random(0, 7))
	_set_aux(b, h.random(6, 12))
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x64)


static func _kind_69(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	_set_aux(b, h.random(1, 10))
	if b.life == 0:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_ZOOM_BOB,
			[b.x, b.y, b.z, 6, h.random(5, 15)])


static func _kind_71(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_request_delete(b, r)
	_spawn(b, h, r, CREATE_LASER_HIT,
		[b.x, b.y, IncInt.i32(b.z + 0x640), 0])


static func _kind_72(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x90)
	_orient(b, h, Vector3i(IncInt.i32(b.x + b.vx), IncInt.i32(b.y + b.vy),
		IncInt.i32(b.z + b.vz)), false)


static func _kind_73(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	if b.life == 0:
		_spawn(b, h, r, CREATE_ZOOM_BOB,
			[b.x, b.y, b.z, 1, h.random(5, 15)])
		_spawn(b, h, r, CREATE_PLASMA_SPARKS_2, [b.x, b.y, b.z, 20, 30])


static func _kind_74(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	if b.life == 0 and b.aux == 10:
		_request_delete(b, r)
		_spawn(b, h, r, CREATE_PLASMA_SPARKS_2, [b.x, b.y, b.z, 20, 30])


static func _kind_75(b: Blob, h: BlobHooks, r: TickResult) -> void:
	_move(b)
	b.vz = IncInt.i32(b.vz - 0x20)
	b.rot_y = _add_word(b.rot_y, 1)
	if b.life == 0 and b.aux > 2:
		for _step: int in range(4):
			var delta: int = IncInt.i32(b.aux - IncInt.div_trunc(b.aux, 3))
			var rz: int = h.random(-0xA0, 0x140)
			var ry: int = h.random(-0x140, 0x280)
			var rx: int = h.random(-0x140, 0x280)
			var size: int = h.random(3, 10)
			_spawn(b, h, r, CREATE_EMITTER,
				[NAME_SCRATCH, 2, b.x, b.y, b.z, 0, 0, 0, 75, size,
				 IncInt.i32(b.x + rx), IncInt.i32(b.y + ry),
				 IncInt.i32(b.z + rz), delta, 0])
	elif b.life == 0:
		_spawn(b, h, r, CREATE_PLASMA_SPARKS, [b.x, b.y, b.z, 5, 5])


## It moves **twice** while it lives: the `ja` at `0x0041EB79` leaves for
## `0x0041EBCB`, which is a second plain move and a return. Only the last four
## ticks take the halved step, and there the vertical is a divide by *minus*
## three (`0x55555555` plus the `sub edx, ecx` correction) and the constant 2
## goes into the pitch.
static func _kind_76(b: Blob, h: BlobHooks, _r: TickResult) -> void:
	_move(b)
	b.rot_y = IncInt.u16(h.random(0, 7))
	_set_aux(b, h.random(5, 15))
	if b.life > 4:
		_move(b)
		return
	b.x = IncInt.i32(b.x + IncInt.div_trunc(b.vx, 2))
	b.y = IncInt.i32(b.y + IncInt.div_trunc(b.vy, 2))
	b.z = IncInt.i32(b.z - IncInt.div_trunc(b.vz, 3))
	b.rot_x = 2


## Three nearby offsets are drawn before the ballistic step, and the first draw
## is the child's own size argument -- the order matters because they come off
## one stream.
static func _kind_77(b: Blob, h: BlobHooks, r: TickResult) -> void:
	var size: int = h.random(5, 10)
	var rz: int = h.random(-20, 40)
	var ry: int = h.random(-20, 40)
	var rx: int = h.random(-20, 40)
	_spawn(b, h, r, CREATE_ZOOM_BOB,
		[IncInt.i32(b.x + rx), IncInt.i32(b.y + ry), IncInt.i32(b.z + rz),
		 5, size])
	_move(b)
	b.rot_x = _add_word(b.rot_x, 0x64)
	b.rot_y = _add_word(b.rot_y, 0x64)
	b.rot_z = _add_word(b.rot_z, 0x64)
	b.vz = IncInt.i32(b.vz - 0x28)
