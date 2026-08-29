class_name MoveMapResult
extends RefCounted

## The overlay a fill leaves behind, as an immutable value.
##
## The original writes it into the cells themselves -- `cell[+0x00]` and
## `cell[+0x0C]` (docs/23 section 7) -- and the remake returns it instead, so
## that `game` can highlight a result without holding a handle on simulation
## state.  For a 33x30 map that is 990 bytes plus 3960, about 5 KiB a query.

## docs/10 section 4.5 -- the three overlay values.
const STATE_NONE: int = 0
const STATE_REACHABLE: int = 10
const STATE_WARP: int = 60

var width: int = 0
var height: int = 0
var mp: int = 0
var any_friendly_blocked: bool = false
var waves: int = 0

var _state: PackedByteArray = PackedByteArray()
var _mp_left: PackedInt32Array = PackedInt32Array()


static func create(w: int, h: int, mover_mp: int, state: PackedByteArray,
		mp_left: PackedInt32Array, blocked: bool, wave_count: int) -> MoveMapResult:
	var result: MoveMapResult = MoveMapResult.new()
	result.width = w
	result.height = h
	result.mp = mover_mp
	result._state = state.duplicate()
	result._mp_left = mp_left.duplicate()
	result.any_friendly_blocked = blocked
	result.waves = wave_count
	return result


func index_of(x: int, y: int) -> int:
	return y * width + x


func state_at(index: int) -> int:
	return _state[index]


func is_reachable(x: int, y: int) -> bool:
	return _state[index_of(x, y)] == STATE_REACHABLE


func is_warp_target(x: int, y: int) -> bool:
	return _state[index_of(x, y)] == STATE_WARP


func mp_left_at(x: int, y: int) -> int:
	return _mp_left[index_of(x, y)]


## What the step to this cell cost in total.  Only meaningful where the cell is
## reachable; a cell reached with zero left reports the mover's whole allowance.
func cost_to(x: int, y: int) -> int:
	return mp - _mp_left[index_of(x, y)]


func reachable_count() -> int:
	var n: int = 0
	for value: int in _state:
		if value == STATE_REACHABLE:
			n += 1
	return n


func warp_count() -> int:
	var n: int = 0
	for value: int in _state:
		if value == STATE_WARP:
			n += 1
	return n


func states() -> PackedByteArray:
	return _state.duplicate()


func mp_left() -> PackedInt32Array:
	return _mp_left.duplicate()


## The diff and trace shape, shared with `inclib/movemap.py`'s `to_dict`.
func to_dict() -> Dictionary:
	return {
		"width": width,
		"height": height,
		"state": _state.duplicate(),
		"mp_left": _mp_left.duplicate(),
		"any_friendly_blocked": any_friendly_blocked,
		"waves": waves,
	}


func result_hash() -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)
	ctx.update(PackedInt32Array([width, height, mp, waves]).to_byte_array())
	ctx.update(_state)
	ctx.update(_mp_left.to_byte_array())
	ctx.update(PackedByteArray([1 if any_friendly_blocked else 0]))
	return ctx.finish()
