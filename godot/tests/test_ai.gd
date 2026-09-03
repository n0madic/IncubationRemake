extends TestSuite

## Oracle boundary: **the Python model**, which is itself pinned to the engine.
##
## `tools/ai_runtime.py --emit-cases` runs `inclib/ai.py` over a mission and
## writes what it did: the unit records before the turn, the records after it,
## the ordered event stream with its arguments, the sweep count and the
## generator's state. This replays the same turn through `core/ai/` and diffs
## all four.
##
## The chain that makes it worth anything: `tools/ai_gold.py --check` compares
## `inclib/ai.py` against a **whole computer turn taken from a live
## `Incubation.exe`** on `_C_140` -- all 200 unit records field by field and
## `aRandom`'s seed either side, on turn 1 and turn 10 -- so agreeing with the
## Python model here is agreeing with the engine, one link removed.
##
## **The roster is applied, not assumed.** The case carries every field the
## planner reads or writes and this writes all of them over the world the cache
## loaded, so the two implementations start from bit-identical state rather
## than from two loaders that happen to agree.

const CASES: String = "res://generated/ai/ai.json"
const SCHEMA: String = "incubation.ai-cases/1"
## docs/21 section 1 -- `SetUnitInfo` accepts ids up to 100, so a scan that
## found every one of those defined would be looking at a table this cache
## does not have.
const UNKNOWN_TYPE_LIMIT: int = 101


func run(h: TestHarness) -> void:
	h.begin("ai", TestHarness.ORACLE_PYTHON)
	var document: Dictionary = CacheFixture.read_json(CASES)
	if document.is_empty():
		# The same terms as every other case-file suite: a fixture that is not
		# there is a failure, not a skip.
		h.check("cases.present", false,
			"run tools/ai_runtime.py --emit-cases "
			+ "tests/fixtures/ai/cases_ai.json --root gog_incubation")
		return
	h.equal("cases.schema", DictRead.as_string(document["schema"]), SCHEMA)
	var cases: Array = DictRead.as_array(document["cases"])
	h.check("cases.count", not cases.is_empty(), "%d case(s)" % cases.size())
	for entry: Variant in cases:
		_case(h, DictRead.as_dict(entry))
	_constants(h)
	_spores(h)
	_merge(h)
	_door_opens_the_cell(h)
	_a_mine_under_an_alien(h)


## Two computer turns inside one hand-over, merged rather than dropped.
##
## `Rotation.advance_player` re-selects player 255 when no human slot
## qualifies, so [method World.submit_end_turn] can play the computer twice
## before it returns. It used to recurse there and assign the **outer** turn's
## result over the inner one, so the first turn's events were never played
## back; the loop that replaced it merges them, and this is the merge.
##
## The bound itself -- [constant World.AI_TURNS_PER_HAND_OVER] -- is not
## exercised here: reaching it needs a mission whose script never ends while
## every human slot is out, and no shipped map is one. It turns a hang into a
## stop, which is the reason it exists rather than a behaviour to assert.
func _merge(h: TestHarness) -> void:
	var first: AITurnResult = AITurnResult.new()
	first.seed_before = 1.0
	first.seed_after = 2.0
	first.sweeps = 3
	first.add(AIEvent.make("move", 1, 0, 0, 1, 1, 0, ""))
	first.saw_order(7)
	first.refuse("a reason")
	first.did(AIContext.WORK_FILL)
	var second: AITurnResult = AITurnResult.new()
	second.seed_before = 2.0
	second.seed_after = 9.0
	second.sweeps = 4
	second.add(AIEvent.make("fire", 2, 0, 0, 2, 2, 0, ""))
	second.saw_order(7)
	second.refuse("a reason")
	second.did(AIContext.WORK_FILL)

	var merged: AITurnResult = first.followed_by(second)
	h.equal("merge.events_keep_their_order",
		[merged.events[0].kind, merged.events[1].kind], ["move", "fire"],
		"the earlier turn is replayed first")
	h.equal("merge.sweeps_add", merged.sweeps, 7)
	h.equal("merge.counters_add", _sorted(merged.counters), "fire=1, move=1")
	h.equal("merge.orders_add", merged.orders_seen_as_strings(), {"7": 2})
	h.equal("merge.refusals_add", merged.refusals, {"a reason": 2})
	h.equal("merge.work_adds", merged.work, {AIContext.WORK_FILL: 2})
	h.equal("merge.the_generator_spans_both",
		[merged.seed_before, merged.seed_after], [1.0, 9.0],
		"before the first turn and after the second")
	_armour(h)


## `0x00475490` / `0x004754F0` on a type the table has no row for.
##
## The recompute runs after every shot the unit survives, so a wrong answer
## here does not stay still -- it rewrites the record. `inclib.ai.armour_of`
## returns the unit's own bytes when the row is missing; reading the columns
## anyway takes [method UnitTypeTable]'s fallback of 0 and **zeroes the
## armour**. No mission places such a type and no emitted case carries one, so
## the scene is built: one unit, one type id the table does not define.
func _armour(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("armour.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var utab: UnitTypeTable = world.unit_types()
	var unit: UnitState = UnitState.from_view(
		world.unit_view(world.unit_slots()[0]))
	unit.armour_front = 37
	unit.armour_rear = 11
	h.check("armour.the_type_is_known", utab.has(unit.type_id),
		"type %d" % unit.type_id)
	var known: Vector2i = AIFire.armour_of(utab, unit)
	h.check("armour.a_known_type_uses_its_columns",
		known.x == utab.armour_front(unit.type_id)
		or utab.armour_front(unit.type_id) == AIFire.ARMOUR_DERIVED,
		"front %d against the column %d"
		% [known.x, utab.armour_front(unit.type_id)])

	var undefined: int = 0
	while utab.has(undefined) and undefined < UNKNOWN_TYPE_LIMIT:
		undefined += 1
	h.check("armour.an_undefined_type_exists", not utab.has(undefined),
		"type %d is not in the table" % undefined)
	unit.type_id = undefined
	h.equal("armour.an_undefined_type_keeps_the_unit_s_bytes",
		AIFire.armour_of(utab, unit), Vector2i(37, 11),
		"the columns' fallback is 0, and using it would zero the record "
		+ "after every shot the unit survives")


func _case(h: TestHarness, case: Dictionary) -> void:
	var name: String = DictRead.as_string(case["mission"])
	var loaded: Dictionary = CacheFixture.load_mission(name)
	if loaded.is_empty():
		h.check("%s.cache" % name, false, "no %s in the cache" % name)
		return
	var world: World = loaded["world"]
	world.turn.current_player = UnitState.PLAYER_ALIEN
	world.rng.randomize_seed(DictRead.as_float(case["seed"]))

	var before: Array = DictRead.as_array(case["units_before"])
	var applied: int = _apply(world, before)
	h.equal("%s.roster" % name, applied, before.size(),
		"every record in the case is a slot the cache placed")

	var ctx: AIContext = AIContext.create(world.state, world.units_for_ai(),
		world.unit_types(), world.weapons(), world.ctrlmap(), world.turn,
		world.rng)
	var result: AITurnResult = AISystem.run(ctx, UnitState.PLAYER_ALIEN)

	h.check("%s.terminal" % name, result.ok, result.reason)
	h.equal("%s.sweeps" % name, result.sweeps, DictRead.as_int(case["sweeps"]))
	h.equal("%s.seed_after" % name, result.seed_after,
		DictRead.as_float(case["seed_after"]),
		"the whole turn draws the same values in the same order")
	h.equal("%s.counters" % name, _sorted(result.counters),
		_sorted(DictRead.as_dict(case["counters"])))
	h.equal("%s.orders_seen" % name, _sorted(result.orders_seen_as_strings()),
		_sorted(DictRead.as_dict(case["orders_seen"])))

	# The events, argument by argument and in order.
	var want: Array = DictRead.as_array(case["events"])
	var got: Array[Dictionary] = result.event_dicts()
	h.equal("%s.event_count" % name, got.size(), want.size())
	var mismatched: PackedStringArray = PackedStringArray()
	for i: int in range(mini(got.size(), want.size())):
		var a: Dictionary = DictRead.as_dict(want[i])
		var b: Dictionary = got[i]
		# **`DictRead`, not `str()`.** `JSON.parse_string` makes a `float` of
		# every number, so `str(6.0)` is `"6.0"` and the whole comparison
		# fails on every integer -- the trap CLAUDE.md records for the cache
		# and which this suite walked straight into.
		if DictRead.as_string(a["kind"]) != DictRead.as_string(b["kind"]):
			mismatched.append("%d.kind %s != %s" % [i,
				DictRead.as_string(a["kind"]), DictRead.as_string(b["kind"])])
		if DictRead.as_string(a["note"]) != DictRead.as_string(b["note"]):
			mismatched.append("%d.note %s != %s" % [i,
				DictRead.as_string(a["note"]), DictRead.as_string(b["note"])])
		for key: String in ["slot", "x", "y", "tx", "ty", "detail"]:
			if DictRead.as_int(a[key]) != DictRead.as_int(b[key]):
				mismatched.append("%d.%s %d != %d"
					% [i, key, DictRead.as_int(a[key]),
						DictRead.as_int(b[key])])
		# The route a move took, cell by cell. It is the one payload field the
		# fixture carries, because it is the one nothing else diffs: an
		# `AttackResult` is pinned by `test_combat_native.gd`, but a path the
		# two implementations disagreed about would show up only as a body
		# walking through a wall during the computer's turn.
		if DictRead.as_string(a["kind"]) == "move":
			if not a.has("path"):
				# A case file emitted before the route was carried. Indexing it
				# would fail as an opaque "invalid get index" instead of saying
				# what to run.
				mismatched.append("%d.path missing from the case file; "
					% i + "run tools/ai_runtime.py --emit-cases "
					+ "tests/fixtures/ai/cases_ai.json --root gog_incubation")
				continue
			var want_path: Array = DictRead.as_array(a["path"])
			var got_path: Array = DictRead.as_array(
				DictRead.as_dict(b["payload"])["path"])
			var same: bool = want_path.size() == got_path.size()
			if same:
				for step: int in range(want_path.size()):
					if DictRead.as_int(want_path[step]) \
							!= DictRead.as_int(got_path[step]):
						same = false
						break
			if not same:
				mismatched.append("%d.path %s != %s"
					% [i, str(want_path), str(got_path)])
			# The walk's two visibility passes, run at the moment of the move
			# (docs/42 section 3.2) with the `+0x0C > 6` discard applied. The
			# Python side is a second transcription of
			# `aBuildVisibleMapForUnit`, which makes it the oracle here.
			for key: String in ["seen_source", "seen_destination"]:
				if not a.has(key):
					mismatched.append("%d.%s missing from the case file; "
						% [i, key] + "run tools/ai_runtime.py --emit-cases "
						+ "tests/fixtures/ai/cases_ai.json --root gog_incubation")
					continue
				var got_payload: Dictionary = DictRead.as_dict(b["payload"])
				if DictRead.as_int(a[key]) != DictRead.as_int(
						got_payload.get(key, -1)):
					mismatched.append("%d.%s %d != %d" % [i, key,
						DictRead.as_int(a[key]),
						DictRead.as_int(got_payload.get(key, -1))])
	h.equal("%s.events" % name, ", ".join(mismatched), "",
		"%d event(s), every argument" % want.size())

	# And the world the turn left behind.
	var after: Array = DictRead.as_array(case["units_after"])
	var bad: PackedStringArray = PackedStringArray()
	for entry: Variant in after:
		var record: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(record["slot"])
		if not world.has_unit(slot):
			bad.append("%d gone" % slot)
			continue
		var view: Dictionary = world.unit_view(slot)
		for key: String in DIFFED:
			if DictRead.as_int(view[key]) != DictRead.as_int(record[key]):
				bad.append("%d.%s %d != %d" % [slot, key,
					DictRead.as_int(record[key]), DictRead.as_int(view[key])])
	h.equal("%s.records" % name, ", ".join(bad), "",
		"%d record(s), field by field" % after.size())


## The fields a record diff compares -- every one the planner reads or writes.
## docs/94 section 8's lesson: comparing names and not arguments is how 120
## cases went unchecked for a year.
const DIFFED: Array[String] = ["x", "y", "hp", "mp", "fp", "facing", "acted",
	"action_state", "heat", "ammo", "malfunction", "armour_front",
	"armour_rear", "order", "order_param", "group", "walked"]


## The four constants the replay cannot bind, stated a second time.
##
## A mutation battery found all four: changing level 2's horizon, dropping the
## byte shift in level 1's doubling, moving the first band boundary and lowering
## the approach climb threshold each left every case above green. That is not a
## hole in the diff -- it is what the diff *is*. The cases replay two missions,
## and a constant that does not change the outcome on those two missions cannot
## be caught by comparing outcomes on them. `tools/ai_runtime.py` catches them
## with censuses over all 108 missions of the corpus; `game/` has no corpus, so
## here the tables are written out from docs/23 and compared directly, the same
## treatment `CONVERTER_VERSION` gets in two files.
func _constants(h: TestHarness) -> void:
	# docs/23 section 5.1's `0x0040AD70`. -1 is "the unit's own points".
	h.equal("const.horizon_table", AIPlan.HORIZON_MP,
		[-1, -1, 30, 50, 100, 250] as Array[int],
		"the six arms of the horizon")
	h.equal("const.horizon_passes_friendlies_at_two", AIPlan.HORIZON_PASS,
		[false, false, true, false, false, false] as Array[bool])
	# `shl al, 1` is a **byte** shift: 130 points doubled is 4, not 260. The
	# table check above cannot see this one, because level 1 is not in it.
	h.equal("const.horizon_level_1_is_a_byte_shift",
		[AIPlan.horizon_mp(1, 130), AIPlan.horizon_mp(1, 5),
			AIPlan.horizon_mp(0, 7)], [4, 10, 7])
	# docs/23 section 6's five bands. No shipped situation sits on both sides
	# of any of the four boundaries -- `ai_runtime.py`'s
	# `band.boundaries_the_corpus_leaves_open` reports the gaps -- so this is
	# the only guard either implementation has for them.
	h.equal("const.band_limits", AIOverlay.BAND_LIMITS,
		[20, 50, 70, 90] as Array[int])
	h.equal("const.band_markers", AIOverlay.BAND_MARKERS,
		[30, 31, 32, 33] as Array[int])
	h.equal("const.band_of_each_boundary",
		[AIOverlay.band_of(20), AIOverlay.band_of(21), AIOverlay.band_of(50),
			AIOverlay.band_of(51), AIOverlay.band_of(90),
			AIOverlay.band_of(91)], [30, 31, 31, 32, 33, 34])
	# docs/23 section 5.4 -- two, and not the one the obvious reading gives.
	# The native capture's ten probed targets contain no height step of
	# exactly 2, so it does not pin this either.
	h.equal("const.approach_climb_max", AIApproach.CLIMB_MAX, 2)

	# docs/22 section 7.2's sixteen families, by the weapon ids that reach
	# them. Stated a second time for the same reason the bands are: a check
	# that asks `Combat.EXPLOSIVES[0]` what weapon 17 is proves only that the
	# constant is self-consistent, and a mutation battery found exactly that.
	h.equal("const.family_explosives", Combat.EXPLOSIVES, [17] as Array[int])
	h.equal("const.family_spores", Combat.SPORES_FILTERED, [22] as Array[int])
	h.equal("const.family_radius", Combat.RADIUS_BY_RANGE, [5, 41] as Array[int])
	h.equal("const.family_line_of_sight", Combat.LINE_OF_SIGHT_FROM_AIM,
		[9] as Array[int])
	h.equal("const.family_special_objects", Combat.SPECIAL_OBJECTS,
		[11] as Array[int])
	h.equal("const.family_every_unit", Combat.EVERY_UNIT, [44] as Array[int])
	h.equal("const.family_scatter", Combat.SCATTER_18, [13] as Array[int])
	# The two unrolled rings, whose *order* is the order the damage rolls come
	# out in. A census of how many cells they stamp cannot see this.
	h.equal("const.aim_neighbour_order", Combat.AIM_NEIGHBOUR_ORDER,
		[Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(0, -1),
			Vector2i(1, -1), Vector2i(1, 1), Vector2i(1, 0),
			Vector2i(0, 1)] as Array[Vector2i])
	h.equal("const.flame_b_neighbour_order", Combat.FLAME_B_NEIGHBOUR_ORDER,
		[Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, 0),
			Vector2i(1, -1), Vector2i(1, 1), Vector2i(0, 1),
			Vector2i(-0, -1)] as Array[Vector2i])
	h.equal("const.radius_thresholds",
		[Combat.RADIUS_NEAR_LIMIT, Combat.RADIUS_MID_LIMIT,
			Combat.RADIUS_BEYOND], [2, 25, 3])


## `0x46ACCD` -- the two things `spores_filtered` does, on a scene built for it.
##
## The blast is centred on the **shooter's own cell** and not on the aim point,
## and a neighbour is stamped only when what stands on it is not owned by
## `0xFC`. The corpus counts both in `ai_runtime.py`; the five missions in the
## cache carry no such arrangement, so this builds one, the way docs/94 built a
## scene for reaction fire and this stage built one for order 3.
func _spores(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission("_C_140")
	if loaded.is_empty():
		h.check("spores.cache", false, "no _C_140 in the cache")
		return
	var world: World = loaded["world"]
	var slots: PackedInt32Array = world.unit_slots()
	h.check("spores.the_map_has_units", slots.size() >= 2,
		"%d units" % slots.size())
	if slots.size() < 2:
		return
	var state: MapState = world.state
	var shooter: UnitState = UnitState.from_view(world.unit_view(slots[0]))
	var neutral: UnitState = UnitState.from_view(world.unit_view(slots[1]))
	var units: Dictionary = {slots[0]: shooter, slots[1]: neutral}
	var sx: int = shooter.x
	var sy: int = shooter.y
	var nx: int = sx + 1 if state.in_bounds(sx + 1, sy) else sx - 1
	neutral.player = Combat.PLAYER_NEUTRAL
	neutral.x = nx
	neutral.y = sy
	# The world is freshly loaded for this suite and is not shared, so the two
	# cells are set on it directly.
	state.set_unit(state.index_of(sx, sy), slots[0])
	state.set_unit(state.index_of(nx, sy), slots[1])
	var context: PatternContext = PatternContext.create(shooter,
		world.unit_types(), world.weapons())

	# Aimed at the far corner, which is what makes the first check mean
	# something: the pattern must ignore it.
	var far: Vector2i = Vector2i(state.width - 1, state.height - 1)
	var unsupported: Array[String] = []
	var cells: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.SPORES_FILTERED[0], far.x, far.y, unsupported, context)
	h.equal("spores.pattern_is_simulated", unsupported, [] as Array[String])
	var stamped: Array[String] = []
	for cell: PackedInt32Array in cells:
		stamped.append("%d,%d" % [cell[0], cell[1]])
	h.check("spores.the_shooter_s_own_cell_is_stamped",
		stamped.has("%d,%d" % [sx, sy]), ", ".join(stamped))
	h.equal("spores.the_aim_cell_is_not",
		stamped.has("%d,%d" % [far.x, far.y]), false,
		"0x0046ACCD reads the shooter's coordinates, not the aim's")
	h.equal("spores.the_neutral_neighbour_is_not",
		stamped.has("%d,%d" % [nx, sy]), false,
		"docs/22 section 7.2: the owner test is what the family adds")
	# And with the same prop owned by anyone else, it *is* stamped -- otherwise
	# the check above would pass on an implementation that stamps nothing.
	neutral.player = UnitState.PLAYER_ALIEN
	cells = Combat.mark_cells(state, units, Combat.SPORES_FILTERED[0], far.x,
		far.y, unsupported, context)
	var again: Array[String] = []
	for cell: PackedInt32Array in cells:
		again.append("%d,%d" % [cell[0], cell[1]])
	h.check("spores.a_non_neutral_neighbour_is_stamped",
		again.has("%d,%d" % [nx, sy]), ", ".join(again))

	# The other five families that no cached mission can fire, reached the same
	# way: one weapon byte, one shot, and a count of what it stamped.
	_patterns(h, world, units, context, shooter)


## The five families a shipped map never carries, and the two corrections a
## reading of docs/22 section 7.2's table alone would miss.
func _patterns(h: TestHarness, world: World, units: Dictionary,
		context: PatternContext, shooter: UnitState) -> void:
	var state: MapState = world.state
	var unsupported: Array[String] = []
	# Weapon 44 is *not* "every unit on the map": it is every unit within four
	# fields of the aim point. Two aim points, two answers.
	var near: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.EVERY_UNIT[0], shooter.x, shooter.y, unsupported, context)
	var far: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.EVERY_UNIT[0], state.width - 1, state.height - 1, unsupported,
		context)
	h.check("pattern.every_unit_is_bounded", near.size() > far.size(),
		"%d cells near the units, %d at the far corner"
		% [near.size(), far.size()])

	# Weapon 13 draws eighteen offsets and then falls through into weapon 42's
	# arm, so the last marker is the aim cell at 0x51.
	context.rng = IncRandom.new()
	context.rng.randomize_seed(1.0)
	var scatter: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.SCATTER_18[0], shooter.x, shooter.y, unsupported, context)
	h.check("pattern.scatter_falls_through", not scatter.is_empty()
		and scatter[scatter.size() - 1][2] == Combat.MARKER_70,
		"%d cells, last marker %d" % [scatter.size(),
			0 if scatter.is_empty() else scatter[scatter.size() - 1][2]])
	# The draws are y then x, so a model that swapped them would agree on the
	# count and disagree on the cells. Replaying from the same seed is the
	# check that the order is part of the contract.
	context.rng.randomize_seed(1.0)
	var again: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.SCATTER_18[0], shooter.x, shooter.y, unsupported, context)
	h.equal("pattern.scatter_is_deterministic", again, scatter,
		"the same seed draws the same eighteen offsets")
	# And the draw order itself: y first. A model that swapped them agrees on
	# the count and on determinism and disagrees on every cell, so the offsets
	# are compared against the sequence the generator actually produces.
	var expected: IncRandom = IncRandom.new()
	expected.randomize_seed(1.0)
	var wanted: Array[String] = []
	for _i: int in range(Combat.SCATTER_COUNT):
		var dy: int = expected.draw(Combat.SCATTER_BASE, Combat.SCATTER_SPAN)
		var dx: int = expected.draw(Combat.SCATTER_BASE, Combat.SCATTER_SPAN)
		if state.in_bounds(shooter.x + dx, shooter.y + dy):
			wanted.append("%d,%d" % [shooter.x + dx, shooter.y + dy])
	wanted.append("%d,%d" % [shooter.x, shooter.y])
	var got: Array[String] = []
	for cell: PackedInt32Array in scatter:
		got.append("%d,%d" % [cell[0], cell[1]])
	h.equal("pattern.scatter_draws_y_before_x", got, wanted,
		"aTacTools.cpp lines 978 then 977 -- the arguments are evaluated "
		+ "right to left")

	# The eight neighbours in the handler's own order, which the count cannot
	# see either.
	var ring: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.AIM_AND_NEIGHBOURS[0], shooter.x, shooter.y, unsupported,
		context)
	var ring_cells: Array[String] = []
	for cell: PackedInt32Array in ring:
		ring_cells.append("%d,%d" % [cell[0], cell[1]])
	var ring_wanted: Array[String] = ["%d,%d" % [shooter.x, shooter.y]]
	for step: Vector2i in Combat.AIM_NEIGHBOUR_ORDER:
		if state.in_bounds(shooter.x + step.x, shooter.y + step.y):
			ring_wanted.append("%d,%d" % [shooter.x + step.x,
				shooter.y + step.y])
	h.equal("pattern.the_ring_is_written_in_order", ring_cells, ring_wanted,
		"0x0046AE0B writes its eight in one order and 0x0046AA66 in another")

	# Weapon 17 blasts the shooter's own cell, like weapon 22.
	var blast: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.EXPLOSIVES[0], state.width - 1, state.height - 1, unsupported,
		context)
	h.check("pattern.explosives_are_self_centred", not blast.is_empty()
		and blast[0][0] == shooter.x and blast[0][1] == shooter.y,
		"first cell %s" % ("none" if blast.is_empty()
			else "%d,%d" % [blast[0][0], blast[0][1]]))

	# The two arc sweeps and the radius refuse without a shooter, which is the
	# whole reason the context exists.
	var bare: Array[String] = []
	for weapon: int in [Combat.RADIUS_BY_RANGE[0],
			Combat.LINE_OF_SIGHT_FROM_AIM[0], Combat.SPECIAL_OBJECTS[0],
			Combat.EXPLOSIVES[0], Combat.SPORES_FILTERED[0]]:
		var refusal: Array[String] = []
		var none: Array[PackedInt32Array] = Combat.mark_cells(state, units,
			weapon, shooter.x, shooter.y, refusal)
		if refusal.is_empty() or not none.is_empty():
			bare.append(str(weapon))
	h.equal("pattern.no_shooter_is_a_refusal", bare, [] as Array[String],
		"the five families that read arguments 4, 5 and 6 say so")
	h.equal("pattern.nothing_else_refused", unsupported, [] as Array[String],
		"every family with a context resolves")


## Write the case's roster over the world's, and answer how many it matched.
static func _apply(world: World, records: Array) -> int:
	var applied: int = 0
	for entry: Variant in records:
		var record: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(record["slot"])
		if not world.has_unit(slot):
			continue
		world.apply_unit_record(slot, record)
		applied += 1
	return applied


static func _sorted(source: Dictionary) -> String:
	var keys: Array = source.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for key: Variant in keys:
		parts.append("%s=%d" % [str(key), DictRead.as_int(source[key])])
	return ", ".join(parts)

## docs/97 section 37 -- an alien that walks onto an authored mine sets it off.
##
## The aliens are the only mover the fill lets *into* a mine cell (docs/23
## section 7.3), so this arm is the rule's main consumer. The mine is laid by
## the placer and not by writing the byte: a mine with no object at `+0x0F` is
## a state the engine cannot produce and the guard would refuse it.
func _a_mine_under_an_alien(h: TestHarness) -> void:
	var alien: Dictionary = TestFixtures.unit(1, 1, 3, 0, UnitState.PLAYER_ALIEN)
	alien["order"] = 0
	var world: World = World.create(TestFixtures.map_document(7, 7,
		[TestFixtures.unit(0, 6, 6), alien]), TestFixtures.balance(), 1.0)
	var target: int = world.state.index_of(3, 3)
	h.check("ai_mine.placed",
		CellObjects.place_mine(world.state, 3, 3) >= 0,
		"the placer names an object, which is what the guard reads")
	var ctx: AIContext = AIContext.create(world.state, world.units_for_ai(),
		world.unit_types(), world.weapons(), world.ctrlmap(), world.turn,
		world.rng)
	var unit: UnitState = world.units_for_ai()[1]
	unit.mp = 6
	ctx.reset_overlay()
	var filled: bool = AIPlan.build_move_map(ctx, unit, 0)
	h.check("ai_mine.filled", filled, "the alien has a move map")
	if not filled:
		return
	var committed: bool = AIPlan.commit(ctx, unit, target)
	h.check("ai_mine.walked", committed, "the walk ran")
	h.equal("ai_mine.cell_is_clear",
		[world.state.obstacle_at(target),
		world.state.effect_at(MapState.OBJECT_SLOT, target)],
		[MapState.OBSTACLE_NONE, MapState.NO_OBJECT],
		"the guard's two writes are on its far side")
	var kinds: PackedStringArray = PackedStringArray()
	for event: AIEvent in ctx.result.events:
		if event.kind != "move":
			continue
		var payload: Dictionary = DictRead.as_dict(event.to_dict()["payload"])
		var moves: Array = DictRead.as_array(payload.get("events", []))
		for entry: Variant in moves:
			kinds.append(DictRead.as_string(DictRead.as_dict(entry)["kind"]))
	h.check("ai_mine.event_says_it_went_off", kinds.has("mine_detonated"),
		"%s -- the playback runs after the turn, so the blast rides on the "
		% [kinds] + "event")


## docs/97 section 35 -- the computer's door: it opens the cell, and the
## cells it changed ride on the event so the picture can paint them in
## that event's own frame.
func _door_opens_the_cell(h: TestHarness) -> void:
	var alien: Dictionary = TestFixtures.unit(1, 3, 3, 0, 1)
	alien["order"] = 0
	var world: World = World.create(TestFixtures.map_document(7, 7,
		[TestFixtures.unit(0, 6, 6), alien]), TestFixtures.balance(), 1.0)
	var index: int = world.state.index_of(4, 3)
	# `cmp byte [eax + 0xB], 0x1F` -- the AI opens action point 31 only, and
	# an odd id is a closed panel: opening it drops the cell to 0 and makes
	# it a Free Place.
	world.state.set_action_point(index, AIUnitTurn.ACTION_POINT_CLOSED_DOOR)
	world.state.set_height(index, Interact.DOOR_HEIGHT_STEP)
	world.state.set_field_type(index, Interact.FIELD_TYPE_WALL)
	var ctx: AIContext = AIContext.create(world.state, world.units_for_ai(),
		world.unit_types(), world.weapons(), world.ctrlmap(), world.turn,
		world.rng)
	var unit: UnitState = world.units_for_ai()[1]
	unit.mp = 4
	var opened: bool = AIUnitTurn.open_door(ctx, unit)
	h.check("ai_door.opened", opened, "a closed door one field east")
	h.equal("ai_door.action_point_flips",
		world.state.action_point_at(index),
		AIUnitTurn.ACTION_POINT_CLOSED_DOOR - 1,
		"`aDoorOpenSequence` rewrites it; `open_door` calls the sequence")
	h.equal("ai_door.height_drops", world.state.height_at(index), 0,
		"the panel goes back into the floor")
	h.equal("ai_door.field_type_opens",
		world.state.field_type_at(index), Interact.FIELD_TYPE_FREE)
	# The context's own grid is written beside the world: a second unit
	# beside the same door must not find it closed and toggle it shut
	# (docs/97 section 35).
	var again: UnitState = world.units_for_ai()[0]
	again.x = 4
	again.y = 2
	again.mp = 4
	h.check("ai_door.a_second_unit_does_not_close_it",
		not AIUnitTurn.open_door(ctx, again)
			and world.state.action_point_at(index)
				== AIUnitTurn.ACTION_POINT_CLOSED_DOOR - 1,
		"the guard reads the cell the first call left open")

	var events: Array[AIEvent] = ctx.result.events
	var last: Dictionary = events[events.size() - 1].to_dict() \
		if not events.is_empty() else {}
	h.check("ai_door.event_carries_the_cell",
		DictRead.as_int32_array(DictRead.as_dict(
			last.get("payload", {})).get("cells", [])).has(index),
		"the picture paints it in this event's frame")
