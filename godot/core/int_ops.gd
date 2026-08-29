class_name IncInt
extends RefCounted

## Explicit 32-bit integer semantics for the simulation core (docs/92 section 2.1).
##
## The original is 32-bit signed arithmetic throughout; GDScript integers are
## 64-bit.  Most expressions transfer unchanged, so **narrowing is applied where
## the original stores into a field of that width, not blindly after every
## expression**.  The helpers exist so that every such site is visible.
##
## Two facts about Godot 4.7 were established by running it rather than assumed:
## integer division truncates toward zero (`-7 / 2 == -3`), matching C, and
## `%` follows it (`-7 % 2 == -1`).  `div_trunc` is therefore a documented
## synonym rather than a correction -- it marks the sites the compiler's magic
## multiplies stand for, which docs/92 section 2.1 requires be written as the
## plain divisions they mean.

const I8_MIN: int = -128
const I16_MIN: int = -32768
const I32_MIN: int = -2147483648
const I32_MAX: int = 2147483647
const U8_MASK: int = 0xFF
const U16_MASK: int = 0xFFFF
const U32_MASK: int = 0xFFFFFFFF


static func u8(v: int) -> int:
	return v & U8_MASK


static func i8(v: int) -> int:
	return ((v + 0x80) & U8_MASK) - 0x80


static func u16(v: int) -> int:
	return v & U16_MASK


static func i16(v: int) -> int:
	return ((v + 0x8000) & U16_MASK) - 0x8000


static func u32(v: int) -> int:
	return v & U32_MASK


static func i32(v: int) -> int:
	return ((v + 0x80000000) & U32_MASK) - 0x80000000


## Signed division truncated toward zero, as C and the original perform it.
static func div_trunc(a: int, b: int) -> int:
	return a / b


static func abs_i(v: int) -> int:
	return -v if v < 0 else v


## The step-height limit of docs/23 section 7.4.
##
## The original is the magic multiply `0x51EB851F` with `sar edx, 9`, which is a
## signed divide by 1600; a step is blocked when the quotient exceeds 1, i.e.
## when the two cells differ by at least 3200 world units -- one map field.
## Written as the division it means, never transcribed as the multiply.
static func climb_quotient(height_delta: int) -> int:
	return div_trunc(abs_i(height_delta), 1600)
