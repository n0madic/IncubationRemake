class_name BlobHooks
extends RefCounted

## The services an update arm calls that are not part of the 88-byte record.
##
## `tools/blob_runtime.py` draws the same boundary and for the same reason:
## four of the seventy-four arms reach outside their own record -- the unit map
## and position lookup the three seekers steer by, the model lookup kinds 16
## and 17 swap through, the orientation helper, and the constructor itself.
##
## **The orientation service is measured; the rest of the adapter is not.**
## docs/28 section 12 item 1 used to record that the return data of all five
## helpers -- `0x004039A0`, `0x00403AA0`, `0x0046D400`, `0x00405100`,
## `0x00477AE0` -- had never been validated against a native trace. All five
## have been called now (`tools/blob_gold.py`'s `hooks` phase), and
## [method orient] is `0x00403AA0`'s own arithmetic through [Eng3dGeometry]
## rather than a stand-in for it.
##
## What that does **not** license: the seventy-four arms are still a
## transcription compared against a transcription, so `tests/test_blob.gd`
## keeps printing `executable-Python` and nothing here claims that a particle
## follows the original's trajectory. The model lookup and the target-map
## service stay a deterministic adapter on both sides, deliberately: making
## them read a running game would replace a reproducible diff with a replay of
## recorded returns.
##
## The one service that **is** natively pinned is the generator -- and which
## generator it is turned out to matter. The effects do **not** draw from
## `aRandom` (`0x00463870`): its seed is unmoved either side of all thirty
## creators and no creator's closure calls it. They draw from a second entry
## point, `0x004638E0`, which is `aRandom`'s body byte for byte over the seed
## at `0x00514070` and without its call counters -- docs/22 section 3.2. The
## arithmetic is identical, so [IncRandom] is the twin of both; what differs
## is the stream, and the original seeds this one from `GetTickCount()` where
## it seeds `aRandom` to the constant 1.0. Effects were never meant to repeat
## run to run, and keeping this instance off [member World.rng] -- which the
## next comment already required for the canonical hash's sake -- turns out to
## be what the engine does too.

## Where the deterministic adapter says a seeker's target is. Not a round
## number: the distance has to be irrational for the truncating divisions in
## the seek step to be exercised at all.
const DEFAULT_TARGET: Vector3i = Vector3i(2000, 3000, 4000)

## Every model name an **update arm** can ask for, in a fixed order; the index
## is the position. A pure function of the name, so the Python and GDScript
## adapters agree without a table of recorded returns passing between them.
##
## This is the *diff's* table and covers only kinds 16 and 17, which are the
## only arms that swap a model mid-flight. A running game asks for thirty more
## through [member model_index]; leaving that empty is what makes the
## comparison against `blob_runtime.py` reproducible.
const MODELS: Array[String] = ["A_BLUT5.3DI", "A_BLUT6.3DI", "A_HIT2.3DI"]

## The generator, natively pinned. **Never [member World.rng]**: a particle
## drawing from the simulation's stream would put the frame rate into the
## canonical hash, and docs/92 section 10.3 forbids presentation reaching it.
## The original keeps the two apart the same way, in two separate seeds.
var rng: IncRandom = IncRandom.new()
## The engine's own sine and arctangent tables, when a cache or a fixture
## supplied them. Null is not an error: it selects the substitute in
## [method orient] and the caller reports which one it used.
var geometry: Eng3dGeometry = null
var target: Vector3i = DEFAULT_TARGET
var has_target: bool = true
var models_present: bool = true
## The world set's own prototypes, `name -> index`, when a mission is loaded.
##
## **Empty is the diff's state, not an error.** With no table the deterministic
## [constant MODELS] answers, which is what `tests/test_blob.gd` compares
## against; with one, a real lookup happens and a name the set does not carry
## comes back `-1` -- which is how docs/28 section 7.5's four rare models are
## cancelled rather than drawn as a hole.
var model_index: Dictionary[String, int] = {}
var spawns_succeed: bool = true
var spawn_calls: Array[Dictionary] = []
var model_calls: PackedStringArray = PackedStringArray()
var target_calls: PackedInt32Array = PackedInt32Array()
## `0x00461E80`'s mode byte, which kind 59 branches on. Zero is the ordinary
## path; three takes the extra emitter.
var emitter_mode: int = 0


static func deterministic(seed_value: float) -> BlobHooks:
	var hooks: BlobHooks = BlobHooks.new()
	hooks.rng.randomize_seed(seed_value)
	return hooks


func random(base: int, span: int) -> int:
	return rng.draw(base, span)


## The x87 value `aRandom` produces **before** `__ftol` truncates it.
##
## Kind 62 compares it against the literal 5.0 rather than against the
## truncated integer, so the fractional part decides whether a spark burst
## happens. [IncRandom] only exposes the truncated draw -- it is `core`'s and
## `core` is not changing -- so the raw value is recovered from the seed the
## draw left behind, which is the same number the original multiplied.
func random_float(base: int, span: int) -> float:
	rng.draw(base, span)
	return float(base) + float(span) * (rng.seed / IncRandom.MODULUS)


## Create a child effect. The default records it and succeeds; a pool with no
## free slot returns `-1` in the original and the effect is silently dropped
## (docs/28 section 7.1), which is what clearing [member spawns_succeed] does.
func spawn(creator: int, args: Array, source: Blob) -> bool:
	spawn_calls.append({"creator": creator, "args": args.duplicate(),
		"kind": source.kind, "ok": spawns_succeed})
	return spawns_succeed


## `0x004038F0` -- name to prototype index, or `-1`.
##
## A miss is not an error: `0x004209A0` reports it and returns `-1` without
## touching the pool, so the effect does not appear. Four of the thirty blob
## models exist in one or two world sets only, and that is exactly the case
## this reproduces (docs/28 section 7.5).
func lookup_model(name: String) -> int:
	model_calls.append(name)
	if not models_present:
		return -1
	if not model_index.is_empty():
		return model_index.get(name, -1)
	return MODELS.find(name)


## `0x00477AE0` then `0x00405100` -- where the unit a seeker is chasing is, or
## an empty answer. The three seeker arms read the unit map and never write it:
## blobs are cosmetic, and damage stays in `core`.
func target_position(blob: Blob) -> Vector3i:
	target_calls.append(blob.aux)
	return target


func has_target_for(_blob: Blob) -> bool:
	return has_target


## `0x0046D400` -- how a seeker steers, and the one service of the five that
## needs no table at all.
##
## The arms pass 1, which reaches only the vertical component. This is
## [method Eng3dGeometry.direction] verbatim, so a fixture emitted with no game
## root still gets the retail answer here -- unlike [method orient], which
## falls back to a substitute and says so.
func direction(blob: Blob, at: Vector3i) -> PackedFloat64Array:
	return Eng3dGeometry.direction(Vector3i(blob.x, blob.y, blob.z), at, 1)


## `0x004039A0` -- a vector through Eng3d's three-angle matrix.
##
## Two arms reach it (kinds 14 and 37) and both spin a horizontal delta about
## the vertical. Measured when [member geometry] carries the shipped tables;
## the float stand-in below covers the same root-free case [method orient]
## does, and the fixture's `"orient": "substitute"` covers both.
func rotate(vector: Vector3i, angles: Vector3i) -> Vector3i:
	if geometry != null and geometry.is_loaded():
		return geometry.rotate(vector, angles)
	var a: float = float(-angles.x) * TAU / 4096.0
	var b: float = float(-angles.y) * TAU / 4096.0
	var c: float = float(-angles.z) * TAU / 4096.0
	var m: PackedFloat64Array = PackedFloat64Array([
		cos(b) * cos(c) - sin(a) * sin(b) * sin(c), cos(a) * sin(c),
		sin(b) * cos(c) + sin(a) * cos(b) * sin(c),
		-(cos(b) * sin(c) + sin(a) * sin(b) * cos(c)), cos(a) * cos(c),
		sin(a) * cos(b) * cos(c) - sin(b) * sin(c),
		-cos(a) * sin(b), -sin(a), cos(a) * cos(b)])
	return Vector3i(_column(m, 0, vector), _column(m, 1, vector),
		_column(m, 2, vector))


## One output component of the substitute matrix, read **by column** as the
## retail transform reads it.
static func _column(m: PackedFloat64Array, row: int,
		vector: Vector3i) -> int:
	var a: float = m[row]
	var b: float = m[row + 3]
	var c: float = m[row + 6]
	var sum: float = floor(a * float(vector.x) + b * float(vector.y)
		+ c * float(vector.z))
	return IncInt.i32(int(sum))


## `0x00403AA0` -- **measured**, when [member geometry] carries the shipped
## tables, and the documented substitute when it does not.
##
## The substitute below was an `atan2` over a 0..0xFFFF turn, invented because
## docs/28 section 12 item 1 recorded the retail routine as never having been
## called. It has been called now: `tools/blob_gold.py`'s `hooks` phase sweeps
## twenty deltas through it inside a live `Incubation.exe`, and the routine
## answers in the **4096-unit circle** with a pitch measured from level, not in
## 65536ths from the horizontal. Both numbers this substitute produces are
## therefore wrong, and it survives only for a fixture emitted with no game
## root -- which says `"orient": "substitute"` so the suite knows.
func orient(from: Vector3i, at: Vector3i) -> Vector3i:
	if geometry != null and geometry.is_loaded():
		var pair: Vector2i = geometry.orient(from, at)
		return Vector3i(pair.x & IncInt.U16_MASK, 0,
			pair.y & IncInt.U16_MASK)
	var dx: float = float(at.x - from.x)
	var dy: float = float(at.y - from.y)
	var dz: float = float(at.z - from.z)
	var horizontal: float = sqrt(dx * dx + dy * dy)
	var yaw: int = round_half_even(atan2(dy, dx) * (65536.0 / TAU)) \
		& IncInt.U16_MASK
	var pitch: int = round_half_even(atan2(dz, horizontal) * (65536.0 / TAU)) \
		& IncInt.U16_MASK
	# The retail helper stores the horizontal heading in the third word and
	# leaves the middle one alone on these arms.
	return Vector3i(pitch, 0, yaw)


## Round half to **even**, which is what an x87 store does under the default
## rounding mode -- and what Python's `round()` does, so the two sides agree.
##
## GDScript's `roundi` rounds half **away from zero**, and the difference shows
## up on exactly the half-integers. The seek step used to reach them; it no
## longer does -- it truncates through [method Eng3dGeometry.ftol] now, which
## is what `0x004AE7B6` does -- so the remaining caller is the substitute
## orientation above, where a silent one-unit divergence would surface as a
## particle drifting from the reference over a hundred ticks rather than as an
## obvious failure.
static func round_half_even(value: float) -> int:
	var floored: float = floor(value)
	var fraction: float = value - floored
	if fraction > 0.5:
		return int(floored) + 1
	if fraction < 0.5:
		return int(floored)
	var lower: int = int(floored)
	return lower if lower % 2 == 0 else lower + 1
