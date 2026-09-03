extends TestSuite

## Oracle boundary: **native runtime** -- the death creators of docs/42
## section 4.8.1, replayed against the records `Incubation.exe` itself left.
##
## `tools/presentation_gold.py` calls each creator inside the running engine
## with controlled tiles and a seed written through the game's own `memcpy`,
## reads the pool back, and `--emit-death-cases` writes what the engine read
## (`BlobPrograms.Inputs`), what it was asked (`args`, the seed) and what it
## left (every record, up to the 48 the capture reads). This suite runs the
## GDScript programs from the same inputs and requires every field of every
## record to agree, and the draw count to agree with the seed the call left.
##
## **What that settles.** The blood, the debris, the flames and the flying
## barrel the remake spawns on a death are the engine's own records, not a
## sprite the remake chose; `docs/42` section 4.8's table of who gets which
## creator is the other half, pinned by `presentation_tables.py`.

const CASES: String = "res://generated/presentation/death.json"
const SCHEMA: String = "incubation.death-cases/1"
const IDLE_CASES: String = "res://generated/presentation/idle.json"
const IDLE_SCHEMA: String = "incubation.idle-cases/1"
## The kept capture's two hundred starter calls; a thinner fixture fails.
const LEAST_IDLE_CALLS: int = 200
## How many cases the kept capture holds and how many records they compare
## (`presentation_gold.DEATH_RECORDS_COMPARED`); a thinner fixture fails.
const LEAST_CASES: int = 37
const LEAST_RECORDS: int = 560
const REPORT_LIMIT: int = 5


func run(h: TestHarness) -> void:
	h.begin("presentation_native", TestHarness.ORACLE_NATIVE)
	if not FileAccess.file_exists(CASES):
		h.check("fixture", false,
			"run python3 tools/presentation_gold.py --emit-death-cases "
			+ "tests/fixtures/presentation/cases_death.json --root gog_incubation")
		return
	var document: Dictionary = CacheLoader.read_json(CASES)
	if not h.equal("schema", document.get("schema"), SCHEMA):
		return
	h.equal("oracle", DictRead.as_string(document.get("oracle", "")),
		"native-runtime")
	var fields: Array = DictRead.as_array(document["fields"])
	var cases: Array = DictRead.as_array(document["cases"])
	h.check("cases", cases.size() >= LEAST_CASES,
		"%d case(s), at least %d expected" % [cases.size(), LEAST_CASES])
	var compared: int = 0
	var creators: Dictionary = {}
	for entry: Variant in cases:
		var kase: Dictionary = DictRead.as_dict(entry)
		var name: String = DictRead.as_string(kase["name"])
		var creator: String = DictRead.as_string(kase["creator"])
		creators[creator] = true
		var inputs: BlobPrograms.Inputs = _inputs_of(
			DictRead.as_dict(kase["inputs"]))
		var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
		var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
			DictRead.as_float(kase["seed"]))
		var args: PackedInt32Array = DictRead.to_int32(kase["args"])
		var ran: bool = BlobPrograms.run(creator, pool, draws, args, inputs)
		h.check("%s.program" % name, ran, "%s is transcribed" % creator)
		if not ran:
			continue
		h.equal("%s.draws" % name, draws.count, DictRead.as_int(kase["draws"]),
			"the seed moved by exactly the program's draws")
		h.equal("%s.records_built" % name, pool.records.size(),
			DictRead.as_int(kase["records_built"]),
			"the Python program built the same number")
		var engine: Array = DictRead.as_array(kase["records"])
		var read: int = DictRead.as_int(kase["records_read"])
		h.equal("%s.record_count" % name, engine.size(),
			mini(pool.records.size(), read),
			"the engine left what the program builds, up to the %d read" % read)
		var bad: PackedStringArray = PackedStringArray()
		for index: int in range(engine.size()):
			if index >= pool.records.size():
				bad.append("%d: missing" % index)
				continue
			var want: Dictionary = DictRead.as_dict(engine[index])
			var got: Dictionary = pool.records[index]
			for field_name: Variant in fields:
				var key: String = DictRead.as_string(field_name)
				compared += 1
				if DictRead.as_int(got[key]) != DictRead.as_int(want[key]):
					bad.append("%d %s: %d != %d" % [index, key,
						DictRead.as_int(got[key]), DictRead.as_int(want[key])])
		h.check("%s.records_field_for_field" % name, bad.is_empty(),
			", ".join(bad.slice(0, REPORT_LIMIT)))
	h.check("records_compared", compared >= LEAST_RECORDS * fields.size(),
		"%d fields over the engine's records, at least %d records expected"
			% [compared, LEAST_RECORDS])
	h.check("creators_covered", creators.size() >= 10,
		"%d distinct creators replayed" % creators.size())
	_idle(h)


## docs/42 section 6 -- the idle starter, replayed call for call against the
## engine: `aStartIdleAnimation(1, 50)` two hundred times with the seed and
## slot 1's table read after each. The countdown ticks with no draw; every
## call past it draws exactly once; the drawn unit is refused by one of the
## guards or taken -- and the type argument never chooses. Then the forced
## start of `idle_pose`: length 90, speed 1.5, the clock at 67.5 after 45
## steps, at 90 after 60, held there, and the bind pose after the free.
func _idle(h: TestHarness) -> void:
	if not FileAccess.file_exists(IDLE_CASES):
		h.check("idle.fixture", false,
			"run python3 tools/presentation_gold.py --emit-idle-cases "
			+ "tests/fixtures/presentation/cases_idle.json --root gog_incubation")
		return
	var document: Dictionary = CacheLoader.read_json(IDLE_CASES)
	if not h.equal("idle.schema", document.get("schema"), IDLE_SCHEMA):
		return
	var refusals: Dictionary[int, String] = {}
	var lengths: Dictionary[int, float] = {}
	for entry: Variant in DictRead.as_array(document["units"]):
		var unit: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(unit["slot"])
		refusals[slot] = "" if unit.get("refused") == null \
			else DictRead.as_string(unit["refused"])
		lengths[slot] = DictRead.as_float(unit["idle_length"])
	var calls: Array = DictRead.as_array(document["calls"])
	h.check("idle.calls", calls.size() >= LEAST_IDLE_CALLS,
		"%d call(s), at least %d expected" % [calls.size(), LEAST_IDLE_CALLS])
	var scheduler: IdleScheduler = IdleScheduler.new()
	var read_slot: int = DictRead.as_int(document["slot_read"])
	scheduler.asked[read_slot] = DictRead.as_int(document["type_argument"])
	var first: Dictionary = DictRead.as_dict(calls[0])
	scheduler.set_slot(read_slot, -1, DictRead.as_int(first["countdown_before"]))
	var unit0_type: int = DictRead.as_int(DictRead.as_dict(
		DictRead.as_array(document["units"])[0])["type"])
	var rng: IncRandom = IncRandom.new()
	var started: Array[int] = []
	var bad: PackedStringArray = PackedStringArray()
	var ticks: int = 0
	var draws: int = 0
	for index: int in range(calls.size()):
		var call: Dictionary = DictRead.as_dict(calls[index])
		rng.randomize_seed(DictRead.as_float(call["seed_before"]))
		scheduler.tick_slot(read_slot, rng, unit0_type,
			func(unit: int) -> String: return refusals.get(unit, "no record"),
			func(unit: int) -> float:
				started.append(unit)
				return lengths.get(unit, 0.0),
			func(_unit: int) -> void: pass)
		if absf(rng.seed - DictRead.as_float(call["seed_after"])) > 0.5:
			bad.append("%d: seed %f != %f" % [index, rng.seed,
				DictRead.as_float(call["seed_after"])])
		if scheduler.countdown(read_slot) != DictRead.as_int(call["countdown_after"]):
			bad.append("%d: countdown %d != %d" % [index,
				scheduler.countdown(read_slot),
				DictRead.as_int(call["countdown_after"])])
		var active: bool = scheduler.held(read_slot) >= 0
		if active != (DictRead.as_int(call["active_after"]) != 0):
			bad.append("%d: slot active %s != %d" % [index, str(active),
				DictRead.as_int(call["active_after"])])
		var drawn: int = DictRead.as_int(call["drawn"])
		if drawn != scheduler.last_drawn[read_slot]:
			bad.append("%d: drew %d, the engine drew %d" % [index,
				scheduler.last_drawn[read_slot], drawn])
		if drawn < 0:
			ticks += 1
		else:
			draws += 1
	h.check("idle.every_call_replayed", bad.is_empty(),
		", ".join(bad.slice(0, REPORT_LIMIT)))
	var summary: Dictionary = DictRead.as_dict(document["summary"])
	h.equal("idle.countdown_ticks_draw_nothing", ticks,
		DictRead.as_int(summary["ticks"]))
	h.equal("idle.one_draw_per_call_past_countdown", draws,
		DictRead.as_int(summary["draws"]))
	h.equal("idle.starts", started.size(), DictRead.as_int(summary["starts"]),
		"the type argument never chose: every start is a draw's")
	h.check("idle.type_search_never_matched", unit0_type
		!= DictRead.as_int(document["type_argument"]),
		"unit 0 is type %d, the argument %d" % [unit0_type,
			DictRead.as_int(document["type_argument"])])

	# The forced start's clock, on the clip the cache carries.
	var pose: Dictionary = DictRead.as_dict(document["pose"])
	var library: CharismaLibrary = CharismaLibrary.open(
		CacheFixture.cache_dir(), {}, "_C_141")
	var clip: CharismaClip = library.clip(DictRead.as_string(pose["clip"]))
	h.check("idle.pose_clip_in_cache", clip != null,
		DictRead.as_string(pose["clip"]))
	if clip == null:
		return
	var state: CharismaState = CharismaState.create(null, null, null, null)
	var length: float = state.start_idle(clip)
	h.equal("idle.pose_length", length, DictRead.as_float(pose["length"]),
		"the engine's +0x60, the first movement's last key")
	var frame: float = 1.0 / CharismaState.FRAMES_PER_SECOND
	var steps: PackedInt32Array = DictRead.to_int32(pose["steps"])
	for _i: int in range(steps[0]):
		state.advance(frame)
	h.check("idle.pose_clock_after_45", absf(state._time
		- float(steps[0]) * DictRead.as_float(pose["speed"])) < 0.001,
		"%.1f, the engine read 67.5" % state._time)
	for _i: int in range(steps[1]):
		state.advance(frame)
	h.check("idle.pose_finished_at_length",
		not state.is_playing() and absf(state._time - length) < 0.001,
		"%.1f after %d more steps" % [state._time, steps[1]])
	for _i: int in range(steps[2]):
		state.advance(frame)
	h.check("idle.pose_held", state.is_idling() and absf(state._time - length) < 0.001,
		"still at %.1f two steps later: the last frame is held" % state._time)
	state.detach_idle()
	h.check("idle.pose_bind_after_free", not state.is_idling(),
		"the free detaches; the next step writes the bind matrices")
	h.check("idle.pose_parts_moved_at_end",
		DictRead.as_int(pose["parts_moved_at_end"]) > 0,
		"%d bound part(s) end away from bind, so the snap is visible"
			% DictRead.as_int(pose["parts_moved_at_end"]))


static func _inputs_of(document: Dictionary) -> BlobPrograms.Inputs:
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	for entry: Variant in DictRead.as_array(document["tiles"]):
		var tile: Dictionary = DictRead.as_dict(entry)
		var object: PackedInt32Array = DictRead.to_int32(tile["object"])
		var unit: Dictionary = {}
		if tile.get("unit") != null:
			var raw: Dictionary = DictRead.as_dict(tile["unit"])
			unit = {"type": DictRead.as_int(raw["type"]),
				"player": DictRead.as_int(raw["player"]),
				"height": DictRead.as_int(raw["height"])}
		inputs.tiles[Vector2i(DictRead.as_int(tile["x"]),
			DictRead.as_int(tile["y"]))] = {
				"object": Vector3i(object[0], object[1], object[2]),
				"unit": unit}
	inputs.gore = DictRead.as_int(document["gore"])
	inputs.display_mode = DictRead.as_int(document["display_mode"])
	for name: Variant in DictRead.as_dict(document["models"]):
		inputs.models[DictRead.as_string(name)] = DictRead.as_int(
			DictRead.as_dict(document["models"])[name])
	for type_key: Variant in DictRead.as_dict(document["type_models"]):
		inputs.type_models[DictRead.as_string(type_key).to_int()] = \
			DictRead.as_string(DictRead.as_dict(document["type_models"])[type_key])
	for type_key: Variant in DictRead.as_dict(document.get("sizes", {})):
		inputs.sizes[DictRead.as_string(type_key).to_int()] = \
			DictRead.as_int(DictRead.as_dict(document["sizes"])[type_key])
	inputs.geometry = _geometry()
	return inputs


static var _cached_geometry: Eng3dGeometry = null


## The engine's tables from the cache: the rings and the arrows' aim are its
## arithmetic, not a division of the circle.
static func _geometry() -> Eng3dGeometry:
	if _cached_geometry == null:
		_cached_geometry = Eng3dGeometry.from_cache(CacheFixture.cache_dir())
	return _cached_geometry
