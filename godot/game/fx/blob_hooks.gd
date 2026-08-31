class_name BlobHooks
extends RefCounted

## The services an update arm calls that are not part of the 88-byte record.
##
## `tools/blob_runtime.py` draws the same boundary and for the same reason:
## four of the seventy-four arms reach outside their own record -- the unit map
## and position lookup the three seekers steer by, the model lookup kinds 16
## and 17 swap through, the orientation helper, and the constructor itself.
##
## **The default adapter is deterministic and is the whole oracle boundary.**
## docs/28 section 12 item 1 records that the return data of the original's
## helpers -- `0x004039A0`, `0x00403AA0`, `0x0046D400`, `0x00405100`,
## `0x00477AE0` -- has never been validated against a native trace. So this
## class is written to be *the same* deterministic adapter the Python side
## uses, and the comparison between them is a transcription check on the arms,
## not a claim that a particle follows the original's trajectory. Anything
## stronger would have to be measured first, and it has not been.
##
## The one service that **is** natively pinned is the generator: `aRandom` is
## docs/91's Lehmer routine and [IncRandom] is its twin, seeded natively.

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
var rng: IncRandom = IncRandom.new()
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


## `0x004039A0` / `0x00403AA0` -- the portable fixed-point stand-in for the
## engine's orientation helper. Answers `(pitch, yaw, roll)` as 0..0xFFFF turn
## angles. The retail routine is the un-validated one of docs/28 section 12,
## so this is deliberately the *documented substitute* rather than a guess at
## it, and both sides of the diff use it.
func orient(blob: Blob, at: Vector3i) -> Vector3i:
	var dx: float = float(at.x - blob.x)
	var dy: float = float(at.y - blob.y)
	var dz: float = float(at.z - blob.z)
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
## GDScript's `roundi` rounds half **away from zero**. The difference shows up
## on exactly the half-integers, which the seek step's `dx * 240.0` reaches
## whenever the distance divides evenly; a silent one-unit divergence there
## would surface as a particle drifting apart from the reference over a
## hundred ticks rather than as an obvious failure.
static func round_half_even(value: float) -> int:
	var floored: float = floor(value)
	var fraction: float = value - floored
	if fraction > 0.5:
		return int(floored) + 1
	if fraction < 0.5:
		return int(floored)
	var lower: int = int(floored)
	return lower if lower % 2 == 0 else lower + 1
