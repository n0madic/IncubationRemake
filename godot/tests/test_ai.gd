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


## `0x46ACCD` -- the one thing `spores_filtered` adds, on a scene built for it.
##
## The corpus has 806 situations in which a neutral prop stands beside a
## reachable target and `ai_runtime.py` counts them; the five missions in the
## cache have none, so this builds one, the way docs/94 built a scene for
## reaction fire and this stage built one for order 3.
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
	# Two neighbouring cells: the target, and a prop beside it.
	var target: UnitState = UnitState.from_view(world.unit_view(slots[0]))
	var units: Dictionary = {}
	var state: MapState = world.state
	var tx: int = target.x
	var ty: int = target.y
	var nx: int = tx + 1 if state.in_bounds(tx + 1, ty) else tx - 1
	var neutral: UnitState = UnitState.from_view(world.unit_view(slots[1]))
	neutral.player = Combat.PLAYER_NEUTRAL
	neutral.x = nx
	neutral.y = ty
	units[slots[0]] = target
	units[slots[1]] = neutral
	# The world is freshly loaded for this suite and is not shared, so the two
	# cells are set on it directly.
	state.set_unit(state.index_of(tx, ty), slots[0])
	state.set_unit(state.index_of(nx, ty), slots[1])

	var unsupported: Array[String] = []
	var cells: Array[PackedInt32Array] = Combat.mark_cells(state, units,
		Combat.SPORES_FILTERED[0], tx, ty, unsupported)
	h.equal("spores.pattern_is_simulated", unsupported, [] as Array[String])
	var stamped: Array[String] = []
	for cell: PackedInt32Array in cells:
		stamped.append("%d,%d" % [cell[0], cell[1]])
	h.check("spores.the_aim_cell_is_stamped", stamped.has("%d,%d" % [tx, ty]),
		", ".join(stamped))
	h.equal("spores.the_neutral_neighbour_is_not",
		stamped.has("%d,%d" % [nx, ty]), false,
		"docs/22 section 7.2: the owner test is what the family adds")
	# And with the same prop owned by anyone else, it *is* stamped -- otherwise
	# the check above would pass on an implementation that stamps nothing.
	neutral.player = UnitState.PLAYER_ALIEN
	cells = Combat.mark_cells(state, units, Combat.SPORES_FILTERED[0], tx, ty,
		unsupported)
	var again: Array[String] = []
	for cell: PackedInt32Array in cells:
		again.append("%d,%d" % [cell[0], cell[1]])
	h.check("spores.a_non_neutral_neighbour_is_stamped",
		again.has("%d,%d" % [nx, ty]), ", ".join(again))


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


## The unit fields the diff covers. Everything the planner reads or writes;
## `ticket` and `walked` among them, because a move and a reaction are exactly
## what a wrong turn gets wrong quietly.
const DIFFED: Array[String] = ["x", "y", "hp", "mp", "fp", "facing", "acted",
	"action_state", "heat", "ammo", "malfunction", "armour_front",
	"armour_rear", "order", "order_param", "group", "walked"]


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
