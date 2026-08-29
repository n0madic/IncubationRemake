class_name CanonicalHash
extends RefCounted

## The one digest that says two simulation states are the same.
##
## The order is fixed here and nowhere else, so that a change to it is a change
## to this file.  What goes in:
##
## 1. `width` and `height`;
## 2. every [MapState] array, verbatim and in its documented order;
## 3. the unit scalars, by ascending slot;
## 4. the [TurnState] -- the counter, both players, the rotation's shape and
##    the difficulty level;
## 5. the RNG state -- the **raw eight bytes** of the seed, never its printed
##    form, plus the two counters;
## 6. the active compatibility flags.
##
## The turn entered the digest with the second slice, which changes it
## deliberately: docs/92 section 7.3 recorded that "campaign and turn phase
## have no representation yet because neither exists", and now the turn does.
## [constant SaveCodec.SCHEMA_VERSION] rises with it.
##
## What stays out: the camera, and anything else presentational.  docs/92
## section 10.3 item 3 requires save/load to preserve this hash and requires the
## camera not to affect it.
##
## Nothing here ever sees a value straight out of `JSON.parse_string`.  Every
## number that arrives that way is a `float`, and hashing the parsed form would
## be stable **and wrong**: the conversion to typed arrays happens at the
## loading boundary, and this only ever hashes those.

const SEED_BYTES: int = 8


static func compute(state: MapState, units: Dictionary, turn: TurnState,
		rng: IncRandom,
		compat_flags: PackedStringArray) -> PackedByteArray:
	var ctx: HashingContext = HashingContext.new()
	var started: Error = ctx.start(HashingContext.HASH_SHA256)
	assert(started == OK)

	ctx.update(PackedInt32Array([state.width, state.height]).to_byte_array())
	state.hash_into(ctx)

	var slots: Array[int] = []
	for slot: Variant in units:
		slots.append(DictRead.as_int(slot))
	slots.sort()
	ctx.update(PackedInt32Array([slots.size()]).to_byte_array())
	for slot: int in slots:
		var unit: UnitState = units[slot]
		unit.hash_into(ctx)

	# `ai_level` is in here on purpose: it steers the movement allowance for one
	# unit type and the damage roll's span, so two saves that differ only in it
	# are not the same simulation state (docs/93 section 11).
	ctx.update(PackedInt32Array([turn.turn, turn.current_player,
		turn.previous_player, turn.player_count, turn.ai_level,
		1 if turn.solo_flag else 0]).to_byte_array())
	ctx.update(turn.player_kind.to_byte_array())
	ctx.update(turn.end_state.to_byte_array())
	ctx.update(turn.reaction_counter.to_byte_array())

	var seed_bytes: PackedByteArray = rng.seed_bytes()
	assert(seed_bytes.size() == SEED_BYTES)
	ctx.update(seed_bytes)
	ctx.update(PackedInt32Array([rng.calls, rng.sum]).to_byte_array())

	var flags: PackedStringArray = compat_flags.duplicate()
	flags.sort()
	ctx.update(PackedInt32Array([flags.size()]).to_byte_array())
	for flag: String in flags:
		# The length goes in even when the flag is empty, for the same reason
		# the roster's count does: HashingContext refuses an empty buffer.
		ctx.update(PackedInt32Array([flag.length()]).to_byte_array())
		if not flag.is_empty():
			ctx.update(flag.to_utf8_buffer())
	return ctx.finish()


static func to_hex(digest: PackedByteArray) -> String:
	return digest.hex_encode()
