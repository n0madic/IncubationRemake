extends TestSuite

## Oracle boundary: specification-only.  These are the width helpers themselves;
## their behaviour is fixed by docs/92 section 2.1, not by a captured sample.

func run(h: TestHarness) -> void:
	h.begin("int_ops", TestHarness.ORACLE_SPEC)

	h.equal("u8.wrap", IncInt.u8(0x1FF), 0xFF)
	h.equal("u8.negative", IncInt.u8(-1), 0xFF)
	h.equal("i8.high_bit", IncInt.i8(0xFF), -1)
	h.equal("i8.min", IncInt.i8(0x80), IncInt.I8_MIN)
	h.equal("u16.wrap", IncInt.u16(0x1_0001), 1)
	h.equal("i16.high_bit", IncInt.i16(0xFFFF), -1)
	h.equal("i16.min", IncInt.i16(0x8000), IncInt.I16_MIN)
	h.equal("u32.negative", IncInt.u32(-1), IncInt.U32_MASK)
	h.equal("i32.high_bit", IncInt.i32(0xFFFF_FFFF), -1)
	h.equal("i32.min", IncInt.i32(0x8000_0000), IncInt.I32_MIN)
	h.equal("i32.identity", IncInt.i32(IncInt.I32_MAX), IncInt.I32_MAX)

	# Truncation toward zero -- the property the original's `idiv` has and a
	# floor division would silently break on every negative height difference.
	h.equal("div.pos", IncInt.div_trunc(7, 2), 3)
	h.equal("div.neg_num", IncInt.div_trunc(-7, 2), -3)
	h.equal("div.neg_den", IncInt.div_trunc(7, -2), -3)
	h.equal("div.both_neg", IncInt.div_trunc(-7, -2), 3)
	h.equal("div.exact_neg", IncInt.div_trunc(-3200, 1600), -2)

	h.equal("abs.neg", IncInt.abs_i(-5), 5)
	h.equal("abs.zero", IncInt.abs_i(0), 0)
	h.equal("abs.int32_min", IncInt.abs_i(IncInt.I32_MIN), -IncInt.I32_MIN)

	# docs/23 section 7.4: the quotient must not exceed 1, so 3200 blocks and
	# 3199 does not, in both directions.
	h.equal("climb.zero", IncInt.climb_quotient(0), 0)
	h.equal("climb.1599", IncInt.climb_quotient(1599), 0)
	h.equal("climb.1600", IncInt.climb_quotient(1600), 1)
	h.equal("climb.3199", IncInt.climb_quotient(3199), 1)
	h.equal("climb.3200", IncInt.climb_quotient(3200), 2)
	h.equal("climb.neg_3200", IncInt.climb_quotient(-3200), 2)
	h.equal("climb.neg_3199", IncInt.climb_quotient(-3199), 1)
