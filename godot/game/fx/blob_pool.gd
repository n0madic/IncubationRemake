class_name BlobPool
extends RefCounted

## `aInitBlobs`' one block: 450 records of 88 bytes, and a create that finds no
## free slot returns `-1`.
##
## docs/28 section 7.1: the allocation is `0x9B08` = 39 688 bytes and every
## walk over it uses `cmp esi, 0x1C2` with `add edi, 0x58`. **A dropped effect
## is silent, not an error** -- the constructor reports nothing and the effect
## simply does not appear, which is the same policy [AudioPool] follows for a
## full sound pool and for the same reason.
##
## **This lives in `game/`, not in `core/`, and that is the slice's main
## decision.** Three things settle it. docs/28 section 8: effects are created
## by the animation routines, which `core` does not have -- it applies
## everything instantly. A pool in `core` would put the frame rate into the
## canonical hash and force a save-schema bump, for state **no rule reads**.
## And the original itself treats effects as optional. So the pool is
## presentation, and its correctness is bought with a per-tick diff against
## `tools/blob_runtime.py` instead of with the canonical hash.
##
## The generator is the pool's own [IncRandom], never [member World.rng].

## `cmp esi, 0x1C2` -- 450 records, plus one spare record's worth of slack.
const SLOTS: int = 450
## The class bytes the sweep counts into `0x004FE640`: `test al, al` and
## `cmp al, 2` at `0x0041E41D`/`0x0041E421`, and nothing else.
const COUNTED_CLASSES: Array[int] = [0, 2]

var _blobs: Array[Blob] = []
var _hooks: BlobHooks = null
## Effects the pool had no room for. Counted so a frame budget can be argued
## about with a number rather than with an impression.
var _drops: int = 0
## `0x004FE63C` -- the *projectile arrived* flag of docs/42 section 4.6. A
## projectile creator writes it before it returns -- 0 while a round is in
## flight, 1 when there is nothing to wait for -- and the update arms of
## fourteen kinds set it when their record lands, while arm 45 clears it on
## every tick (`mov [flag], ebp` with the sweep's zero). The fight waits on
## it for up to 100 frames. [method tick_all] applies the arms' writes in slot
## order, which is the order the sweep makes them.
var arrived: bool = true
## **The remake's own, and a deliberate divergence** (docs/92 section 7.11):
## a seeker -- kinds 26, 27 and 61 -- whose target no longer answers is
## removed instead of left where it stopped.
##
## The engine's arm aborts on `aGetUnitMapElementPtr`'s null (docs/28 section
## 7.7.1) *after* the wrapper has taken a tick of `life`, so a round whose unit
## died hangs motionless in the air until its life runs out -- a hundred ticks
## for weapon 11's arcs, five seconds at the queue's twenty a second. Weapon
## 11 makes that the ordinary case rather than a corner: its first arrival
## raises the flag, the death stage lands every casualty on the mirror, and
## the other arcs' rounds are all left standing. Off by default, so the
## per-tick diff against `tools/blob_runtime.py` still steps the engine's
## arm; the mission's pool turns it on.
var drops_orphaned_seekers: bool = false
## The three seeking kinds of docs/28 section 7.7.1. Their creators --
## `aBlob_CreateGrenade` `0x00426070` for 26 and 27, `aBlob_EnergyCannon`
## `0x004264A0` for 61 -- push a zero rotation and leave the heading to the
## arm, which turns the record along its step on every tick.
const SEEKER_KINDS: Array[int] = [26, 27, 61]


static func create(seed_value: float = 1.0, slots: int = SLOTS) -> BlobPool:
	var pool: BlobPool = BlobPool.new()
	pool._hooks = BlobHooks.deterministic(seed_value)
	pool._blobs.resize(slots)
	return pool


func hooks() -> BlobHooks:
	return _hooks


func set_hooks(value: BlobHooks) -> void:
	_hooks = value


func capacity() -> int:
	return _blobs.size()


func drops() -> int:
	return _drops


## What a projectile creator writes over the flag before it returns.
func set_arrived(value: bool) -> void:
	arrived = value


## `0x004FE640` -- the live-record count the sweep maintains, which every
## play-out spins on (docs/42 section 4.9).
##
## **It is not the number of records in use.** `aCheckInBlobObjects`
## `0x0041E3D0` zeroes the counter and then increments it once per record
## whose class byte `+0x56` is **0 or 2** (`0x0041E41A`..`0x0041E425`); a
## class-1 object -- a warning light, a computer light, a `CreateBGB` fire,
## all at `life` 255 -- and a class-3 sprite never count. Counting every
## record instead made every shot on `_C_102` wait out the whole safety bound
## (`ShotSequence.SAFETY_FRAMES`, fifteen seconds), because its two warning
## lights never die. [method in_use] is the occupancy.
func live() -> int:
	var count: int = 0
	for blob: Blob in _blobs:
		if blob != null and blob.alive and COUNTED_CLASSES.has(blob.class_id):
			count += 1
	return count


## [method live] without the records that have left the world -- **the
## remake's own**, read only by the shot's play-out (docs/92 section 7.11).
##
## A record counts while it stands inside the map's footprint widened by the
## map's longer side on every side, and no further than that side above or
## below the ground. The one population this excludes in practice is the fire
## explosion's kind 75 (docs/28 section 7.7.2): its children are given the
## parent's **position** as their velocity, so they leave the map within a
## few ticks and never come back, and the play-out would otherwise wait out
## every generation of them with nothing on screen. `width` and `height` are
## in map fields.
func live_on_map(width: int, height: int) -> int:
	var reach: int = maxi(width, height) * WorldSpace.WORLD_UNITS_PER_FIELD
	var hi_x: int = width * WorldSpace.WORLD_UNITS_PER_FIELD + reach
	var hi_y: int = height * WorldSpace.WORLD_UNITS_PER_FIELD + reach
	var count: int = 0
	for blob: Blob in _blobs:
		if blob == null or not blob.alive \
				or not COUNTED_CLASSES.has(blob.class_id):
			continue
		if blob.x < -reach or blob.x > hi_x or blob.y < -reach \
				or blob.y > hi_y or blob.z < -reach or blob.z > reach:
			continue
		count += 1
	return count


## Every record in use, whatever its class -- the occupancy the pool-full test
## reads (`create_blob` answering -1), not the sweep's counter.
func in_use() -> int:
	var count: int = 0
	for blob: Blob in _blobs:
		if blob != null and blob.alive:
			count += 1
	return count


## Every live blob, for the renderer. The array is fresh; the [Blob] objects in
## it are the pool's own, because the renderer reads them every frame and
## copying 450 records a frame to protect against a write nobody makes would be
## a cost this slice invented for itself.
func blobs() -> Array[Blob]:
	var out: Array[Blob] = []
	for blob: Blob in _blobs:
		if blob != null and blob.alive:
			out.append(blob)
	return out


func at(slot: int) -> Blob:
	if slot < 0 or slot >= _blobs.size():
		return null
	return _blobs[slot]


## `0x00420950`. Answers the slot, or `-1` when the pool is full or the
## arguments refuse the call.
##
## Two arguments refuse it outright, and both are the original's: a `life` of
## zero aborts before anything is allocated, and a class 0 or 1 whose model
## name resolves to nothing aborts as well (docs/28 section 7.5) -- which is
## how an effect whose model this world set does not carry is cancelled rather
## than drawn as a hole.
func create_blob(fields: Dictionary) -> int:
	var life: int = IncInt.u8(DictRead.as_int(fields.get("life", 0)))
	if life == 0:
		return -1
	var class_id: int = IncInt.u8(DictRead.as_int(fields.get("class_id", 0)))
	var model: int = -1
	if class_id < 2:
		var name: String = DictRead.as_string(fields.get("model_name", ""))
		model = _hooks.lookup_model(name)
		if model < 0:
			return -1
	for slot: int in range(_blobs.size()):
		if _blobs[slot] != null and _blobs[slot].alive:
			continue
		var blob: Blob = Blob.make(fields)
		blob.model = model
		blob.slot_tag = IncInt.u8(slot)
		blob.in_use = true
		blob.alive = true
		_blobs[slot] = blob
		return slot
	_drops += 1
	return -1


## One frame: every live blob ticked once, in slot order.
##
## Order is the original's -- a walk over the array from slot 0 -- and it
## matters, because an arm that spawns draws from the shared generator and a
## different order would hand different numbers to different particles.
func tick_all() -> Array[BlobKinds.TickResult]:
	var results: Array[BlobKinds.TickResult] = []
	for slot: int in range(_blobs.size()):
		var blob: Blob = _blobs[slot]
		if blob == null or not blob.alive:
			continue
		var result: BlobKinds.TickResult = BlobKinds.tick(blob, _hooks)
		if result.dispatched:
			blob.dispatched = true
		# The two writes, in the order the arms make them: a clear first
		# would be undone by a set later in the same sweep and a set first
		# by a later clear, exactly as the engine's global is.
		if result.global_signal:
			arrived = true
		if result.global_signal_clear:
			arrived = false
		if drops_orphaned_seekers and result.target_missing:
			blob.in_use = false
			blob.alive = false
			result.deleted = true
		results.append(result)
		if not blob.alive:
			_blobs[slot] = null
	return results


func clear() -> void:
	for slot: int in range(_blobs.size()):
		_blobs[slot] = null
	_drops = 0
	arrived = true


## SHA-256 over every live record, in slot order.
##
## The canonical hash covers the simulation and deliberately does not cover
## this pool. That leaves particles with no determinism guarantee at all
## unless one is bought explicitly, so this is it: the same seed and the same
## events give the same digest, and a check can say so.
func trace_digest() -> String:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	for slot: int in range(_blobs.size()):
		var blob: Blob = _blobs[slot]
		if blob == null or not blob.alive:
			continue
		var values: PackedInt32Array = PackedInt32Array([slot,
			blob.x, blob.y, blob.z, blob.rot_x, blob.rot_y, blob.rot_z,
			blob.angle0, blob.angle1, blob.angle2, blob.angle3, blob.angle4,
			blob.angle5, blob.vx, blob.vy, blob.vz, blob.aux, blob.kind,
			blob.life, blob.delay, blob.class_id, blob.model])
		ctx.update(values.to_byte_array())
	return ctx.finish().hex_encode()
