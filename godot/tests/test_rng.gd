extends TestSuite

## Oracle boundary: **native runtime**.
##
## `aRandomize(1.0)` and sixty-four `aRandom(0, 100)` called inside a running
## `Incubation.exe`, with the raw eight bytes of the global seed at
## `0x00514078` read back after every draw.  The values below are that capture,
## and `tools/blob_runtime.py`'s `ARandom` reproduces them exactly.
##
## The capture settles a question no amount of reasoning could: docs/92
## section 2.1 called the generator "easier in 64-bit, because the intermediate
## product fits", but `seed * 62089911.0` reaches 1.33e17 -- past 2^53 -- so
## the rounding of the double multiply is part of the sequence.  Sixty-four
## agreeing draws **and** the agreeing raw seed show that the shipped FPU
## control word gives 53-bit significands, so IEEE doubles here are equivalent
## and an integer port would not be.

## The draws, in order, after `aRandomize(1.0)`.
const EXPECTED_DRAWS: Array[int] = [
	2, 39, 49, 85, 25, 52, 89, 60, 41, 5, 12, 34, 65, 66, 35, 55,
	73, 65, 98, 96, 2, 59, 17, 61, 48, 67, 5, 47, 82, 31, 43, 19,
	74, 41, 32, 45, 90, 98, 81, 94, 35, 83, 11, 15, 26, 98, 56, 65,
	53, 98, 32, 75, 5, 17, 93, 45, 18, 47, 48, 35, 31, 64, 84, 99,
]

## `0x00514078` after the last draw, as the eight raw little-endian bytes.
const EXPECTED_SEED_BYTES: String = "0000800642f7df41"
## `0x00514080` and `0x00514084` -- the call count and the running sum, which
## `aRandomize` clears and nothing in either binary ever reads.
const EXPECTED_CALLS: int = 64
const EXPECTED_SUM: int = 3315


func run(h: TestHarness) -> void:
	h.begin("rng", TestHarness.ORACLE_NATIVE)

	# Zero is a fixed point, and reproducing that is reproducing the game: the
	# retail globals live in the zeroed tail of `.data`.
	var unseeded: IncRandom = IncRandom.new()
	h.equal("zero.fixed_point", unseeded.draw(7, 100), 7)
	h.equal("zero.stays", unseeded.seed, 0.0)

	var rng: IncRandom = IncRandom.new()
	rng.randomize_seed(1.0)
	h.equal("randomize.clears_calls", rng.calls, 0)
	var got: PackedInt32Array = PackedInt32Array()
	for _i: int in range(EXPECTED_DRAWS.size()):
		got.append(rng.draw(0, 100))
	var want: PackedInt32Array = PackedInt32Array()
	for value: int in EXPECTED_DRAWS:
		want.append(value)
	h.equal_ints("draws", got, want)
	h.equal("seed_bytes", rng.seed_bytes().hex_encode(), EXPECTED_SEED_BYTES)
	h.equal("calls", rng.calls, EXPECTED_CALLS)
	h.equal("sum", rng.sum, EXPECTED_SUM)

	# The state shape later trace comparisons use (docs/92 section 10.3 item 2).
	var restored: IncRandom = IncRandom.from_state(rng.state())
	h.equal("state.round_trip", restored.seed, rng.seed)
	h.equal("state.round_trip_calls", restored.calls, rng.calls)
	h.equal("state.round_trip_sum", restored.sum, rng.sum)
	h.equal("state.next_draw_matches", restored.draw(0, 100), _peek(rng))


## Draws once from a copy, so the comparison above does not advance `rng`.
func _peek(rng: IncRandom) -> int:
	return IncRandom.from_state(rng.state()).draw(0, 100)
