class_name IncRandom
extends RefCounted

## The shipped `aRandom` generator (`0x00463870`).  See docs/22 section 3.
##
## [codeblock]
## seed = (double)(int)fmod(seed * 62089911.0, 2147483647.0);
## return (int)(base + span * (seed * (1.0 / 2147483647.0)));
## [/codeblock]
##
## **This is a float generator and stays one.**  docs/92 section 2.1 called it
## "easier in 64-bit, because the intermediate product fits"; it does not.  The
## product reaches 1.33e17, past 2^53, so the rounding of the double multiply
## is part of the sequence and an integer port produces a different stream.
## Sixty-four draws captured from the running game -- with the raw eight bytes
## of the global seed read back after every one -- agree with this exactly, so
## the question of x87 extended precision is settled rather than assumed: the
## standard MSVC control word gives 53-bit significands and IEEE doubles here
## are equivalent.
##
## **Zero is a fixed point and stays one.**  The retail globals live in the
## zeroed tail of `.data`, so an unseeded generator returns `base` on every
## call, and reproducing that is part of reproducing the game.

const MULTIPLIER: float = 62089911.0
const MODULUS: float = 2147483647.0

## `0x00514078` -- the generator's whole state, plus the two counters at
## `0x00514080` and `0x00514084` that `aRandomize` clears and nothing reads.
## They are kept because the save and the canonical hash carry them: dropping a
## field because the original never reads it makes a later trace comparison
## impossible to align.
var seed: float = 0.0
var calls: int = 0
var sum: int = 0


## `aRandomize` (`0x00463820`).
func randomize_seed(value: float) -> void:
	seed = value
	calls = 0
	sum = 0


## `aRandom(base, span)` -- the result is `base .. base + span - 1`.
func draw(base: int, span: int) -> int:
	if seed != 0.0:
		seed = float(int(fmod(seed * MULTIPLIER, MODULUS)))
	var value: float = float(base) + float(span) * (seed / MODULUS)
	calls += 1
	sum += DictRead.as_int(value)
	return DictRead.as_int(value)


## The eight raw bytes of the seed, for the canonical hash.  Hashing the
## printed value would hash a formatting decision instead of the state.
func seed_bytes() -> PackedByteArray:
	var packed: PackedFloat64Array = PackedFloat64Array([seed])
	return packed.to_byte_array()


func state() -> Dictionary:
	return {"seed": seed, "calls": calls, "sum": sum}


## Write a [method state] back over this generator, in place.  The mirror
## keeps one generator for the life of the mission, so a delta writes through
## rather than replacing the object every rule holds a reference to.
func restore(data: Dictionary) -> void:
	seed = DictRead.as_float(data.get("seed", 0.0))
	calls = DictRead.as_int(data.get("calls", 0))
	sum = DictRead.as_int(data.get("sum", 0))


## An independent generator at this one's state.
func clone() -> IncRandom:
	return from_state(state())


static func from_state(data: Dictionary) -> IncRandom:
	var rng: IncRandom = IncRandom.new()
	rng.seed = DictRead.as_float(data.get("seed", 0.0))
	rng.calls = DictRead.as_int(data.get("calls", 0))
	rng.sum = DictRead.as_int(data.get("sum", 0))
	return rng
