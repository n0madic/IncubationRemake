class_name DictRead
extends RefCounted

## Narrowing helpers for values that arrive as `Variant`.
##
## The converted cache is JSON, and **every number `JSON.parse_string` produces
## is a `float`**.  Every value is far below 2^53 so nothing is lost, but the
## conversion has to happen at a boundary and be visible when it does: a
## canonical hash taken over parsed floats would be perfectly stable and
## perfectly wrong.
##
## With `unsafe_call_argument` as an error, `int(dictionary["k"])` does not
## compile -- which is the point.  These four lines are where the narrowing is
## allowed to happen, and every one of them is one line long, so the place a
## type is asserted is always the place it is used.

static func as_int(value: Variant) -> int:
	return value


static func as_float(value: Variant) -> float:
	return value


static func as_string(value: Variant) -> String:
	return value


static func as_bool(value: Variant) -> bool:
	return value


static func as_array(value: Variant) -> Array:
	return value


static func as_int32_array(value: Variant) -> PackedInt32Array:
	return value


static func as_dict(value: Variant) -> Dictionary:
	return value


## An `Array` of JSON numbers as a typed integer array.
static func to_int32(value: Variant) -> PackedInt32Array:
	var source: Array = as_array(value)
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(source.size())
	for i: int in range(source.size()):
		out[i] = as_int(source[i])
	return out


## An `Array` of JSON numbers as a typed byte array.
static func to_bytes(value: Variant) -> PackedByteArray:
	var source: Array = as_array(value)
	var out: PackedByteArray = PackedByteArray()
	out.resize(source.size())
	for i: int in range(source.size()):
		out[i] = as_int(source[i]) & 0xFF
	return out
