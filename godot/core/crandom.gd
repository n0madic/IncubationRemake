class_name CRandom
extends RefCounted

## The Microsoft C runtime `rand()`, which `InsertUnit` draws from.
##
## docs/20 section 7.4: the spawn count comes from `rand()` at the import
## `0x005255fc` -- a **different generator** from [IncRandom], the Lehmer one at
## `0x00463870`.  A model that used `aRandom` here would produce plausible
## counts that are wrong, so the two are kept apart in the same way
## `inclib/rng.py` keeps them apart.
##
## **UNVERIFIED: whether anything seeds it.**  No `srand` call has been traced,
## which would leave every run drawing the same sequence from 1; the C
## standard's initial seed is 1 and that is what this starts from.  A caller
## that cares must say which seed it is assuming rather than inherit the
## default silently.
##
## The state is **simulation state**: `_C_140` inserts reinforcements from turn
## 4, so two saves that differ only in how far this generator has advanced are
## different missions.  It is therefore in the canonical hash and in the save.

const MULTIPLIER: int = 214013
const INCREMENT: int = 2531011
const MODULUS_MASK: int = 0xFFFFFFFF
const RAND_MAX: int = 0x7FFF

var seed: int = 1
var calls: int = 0


static func create(initial: int = 1) -> CRandom:
	var rng: CRandom = CRandom.new()
	rng.seed = initial & MODULUS_MASK
	return rng


func draw() -> int:
	seed = (seed * MULTIPLIER + INCREMENT) & MODULUS_MASK
	calls += 1
	return (seed >> 16) & RAND_MAX


func state() -> Dictionary:
	return {"seed": seed, "calls": calls}


## See [method IncRandom.restore] -- the same contract.
func restore(data: Dictionary) -> void:
	seed = DictRead.as_int(data.get("seed", 1))
	calls = DictRead.as_int(data.get("calls", 0))


func clone() -> CRandom:
	return from_state(state())


static func from_state(data: Dictionary) -> CRandom:
	var rng: CRandom = CRandom.new()
	rng.seed = DictRead.as_int(data.get("seed", 1))
	rng.calls = DictRead.as_int(data.get("calls", 0))
	return rng


func hash_into(ctx: HashingContext) -> void:
	ctx.update(PackedInt32Array([seed, calls]).to_byte_array())
