extends TestSuite

## Oracle boundary: executable Python (`tools/inclib/movemap.py`), which is
## itself pinned to the live engine on `_C_141`.
##
## This is the slice's lead mission, `_C_115`, and the boundary is deliberately
## the weaker one: what is pinned natively is the *algorithm*, on another
## mission, not the *result* here.  Reaching `_C_115` under the debugger would
## mean driving the campaign to the thirteenth mission of the other chain, which
## is not on the critical path.
##
## It also exercises the [World] path of docs/92 section 10.2 -- load the map,
## submit a command, get a value result -- rather than calling [MoveMap]
## directly, because that boundary is part of what the slice validates.

func run(h: TestHarness) -> void:
	h.begin("move_map_slice", TestHarness.ORACLE_PYTHON)
	var document: Dictionary = MoveMapCaseRunner.load_cases("slice")
	if document.is_empty():
		h.check("fixture", false,
			"run tools/movemap_runtime.py --emit-cases godot/generated/movemap")
		return
	var ran: int = MoveMapCaseRunner.run_all(h, document)
	h.check("count", ran >= 6, "%d cases on the lead mission" % ran)
	_check_through_world(h)


## The same query, submitted as a command to a [World] built from the converted
## cache, must give the same answer as the direct call above.
func _check_through_world(h: TestHarness) -> void:
	var cache: Dictionary = CacheFixture.load_slice_world()
	if cache.is_empty():
		h.check("world.cache", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = cache["world"]
	var slots: PackedInt32Array = world.unit_slots()
	h.check("world.units", slots.size() > 0,
		"%d placed units in %s" % [slots.size(), world.resource.mission])
	var document: Dictionary = MoveMapCaseRunner.load_cases("slice")
	var cases: Array = DictRead.as_array(document["cases"])
	var matched: int = 0
	for entry: Variant in cases:
		var case: Dictionary = DictRead.as_dict(entry)
		var query: Dictionary = DictRead.as_dict(case["query"])
		if DictRead.as_bool(query["pass_friendlies"]):
			continue
		var slot: int = DictRead.as_int(query["slot"])
		if not world.has_unit(slot):
			continue
		var result: MoveMapResult = world.submit_move_query(
			MoveQueryCommand.create(slot, false))
		var expected: Dictionary = DictRead.as_dict(case["expected"])
		h.equal_bytes("world.slot%d.state" % slot, result.states(),
			DictRead.to_bytes(expected["state"]))
		h.equal_ints("world.slot%d.mp_left" % slot, result.mp_left(),
			DictRead.to_int32(expected["mp_left"]))
		matched += 1
	h.check("world.matched", matched > 0,
		"%d queries went through World.submit_move_query" % matched)
