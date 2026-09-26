extends TestSuite

## Oracle boundary: specification-only. The mirror and the deltas that advance
## it are the remake's own construction (docs/100 section 2), so what is
## checked here is a contract rather than the engine's arithmetic: the clone is
## independent, every event carries what it changed, the boundaries fall where
## the original drew a frame, and applying every delta of a command puts the
## mirror on the truth's canonical hash.
##
## **The hash invariant is the whole point.** It replaces a family of
## per-mechanic checks: a field nobody thought to carry -- a slot a mission
## script refilled, a converted unit's new owner, the hero counter -- fails
## here deterministically, whatever mechanic introduced it.

const MISSION: String = "_C_140"


func run(h: TestHarness) -> void:
	h.begin("journal", TestHarness.ORACLE_SPEC)
	_clone(h)
	_delta_shape(h)
	_off(h)
	_bare_scalar_write(h)
	_invariant(h)
	_boundaries(h)


## Two worlds that share no storage.
func _clone(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	world.state.set_height(0, 12345)
	world.state.set_obstacle(2, MapState.OBSTACLE_MINE)
	var _drawn: int = world.rng.draw(0, 100)
	world.compat_flags = PackedStringArray(["a_flag"])
	var before: String = world.canonical_hash_hex()

	var mirror: World = world.clone()
	h.equal("clone.same_hash", mirror.canonical_hash_hex(), before,
		"a clone is the world it was taken from")
	h.check("clone.no_program_attached", mirror.script_program == null,
		"the mirror resolves nothing, so it runs no mission program")
	h.check("clone.shares_the_tables",
		mirror.unit_types() == world.unit_types()
			and mirror.weapons() == world.weapons()
			and mirror.resource == world.resource,
		"the authored tables are read-only and are shared, not copied")

	# Both directions: an aliased `Packed*Array` would make one write show up
	# in the other world, which is the bug `test_isolation` exists for.
	mirror.state.set_height(1, 999)
	mirror.rng.restore({"seed": 0.5, "calls": 40, "sum": 3})
	var _applied: bool = mirror.apply_unit_record(0, {"hp": 1})
	h.equal("clone.the_truth_is_untouched", world.canonical_hash_hex(), before,
		"writing the clone must not reach the world it came from")
	var mirror_hash: String = mirror.canonical_hash_hex()
	world.state.set_height(3, 4242)
	var _drew: int = world.rng.draw(0, 5)
	h.equal("clone.the_mirror_is_untouched", mirror.canonical_hash_hex(),
		mirror_hash, "and the other way round")
	h.check("clone.they_differ", mirror.canonical_hash_hex()
		!= world.canonical_hash_hex(), "two worlds, two states")


## What a delta holds, and what building one must not do.
func _delta_shape(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	world.enable_journal()
	var seed_before: float = world.rng.seed
	var calls_before: int = world.rng.calls
	world.state.set_height(5, 77)
	var journal: EventJournal = world.journal()
	var delta: Dictionary = journal.delta_now()
	h.equal("delta.does_not_draw", world.rng.calls, calls_before,
		"a delta reads the generator's state and never turns it")
	h.check("delta.the_seed_is_unmoved", is_equal_approx(world.rng.seed,
		seed_before), "%f" % world.rng.seed)
	var cells: Dictionary = DictRead.as_dict(delta["cells"])
	h.equal("delta.the_written_cell_is_in_it", cells.size(), 1,
		"one setter, one row")
	h.check("delta.the_row_is_the_cell", cells.has(5), str(cells.keys()))
	h.equal("delta.the_row_carries_the_height",
		DictRead.as_int(DictRead.as_dict(cells[5])["height"]), 77)
	for key: String in ["cells", "units", "turn", "game_control", "rng",
			"crand"]:
		h.check("delta.has_" + key, delta.has(key), str(delta.keys()))

	# The delta is handed to another world and must not be a window into this
	# one's arrays.
	var control: PackedInt32Array = DictRead.as_int32_array(
		delta["game_control"])
	control[0] = 4321
	h.equal("delta.arrays_do_not_alias", world.game_control.get_slot(0), 0,
		"writing a delta's array must not reach the world")

	# A second read sees nothing: the dirty set is consumed, not accumulated.
	var again: Dictionary = journal.delta_now()
	h.equal("delta.the_dirty_set_is_consumed",
		DictRead.as_dict(again["cells"]).size(), 0)

	# A packed member of a unit view moving must be seen -- `==` on two
	# dictionaries compares the nested arrays by reference in some Godot
	# builds, which would silently drop a skills or equipment write.
	var _reset: Dictionary = journal.delta_now()
	var unit: UnitState = world.units_for_ai()[0]
	unit.skills = PackedInt32Array([1, 2, 3, 4, 5, 6])
	var skilled: Dictionary = journal.delta_now()
	h.check("delta.a_skills_write_is_seen",
		DictRead.as_dict(skilled["units"]).has(0),
		"the unit diff walks the packed members")


## A world with no journal records nothing and pays nothing.
func _off(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	h.check("off.no_journal_by_default", not world.journal_enabled(),
		"the journal is opt-in")
	var _moved: MoveResult = world.submit_move(
		MoveCommand.create(0, 2, 3))
	h.equal("off.nothing_is_recorded", world.take_events().size(), 0)
	var dirty: Dictionary = world.state.take_dirty()
	h.equal("off.no_cell_is_tracked",
		DictRead.as_int32_array(dirty["cells"]).size(), 0,
		"the setters do not fill a set nobody asked for")
	var turned: TurnResult = world.submit_end_turn(EndTurnCommand.create())
	h.check("off.a_turn_still_runs", turned.code == TurnResult.OK,
		"code %d" % turned.code)


## A command that marks no event and moves only a generator still reaches the
## mirror: with nothing marked there is no last event to compare the residue
## against, and the baseline taken at the last [method EventJournal.take] is
## what stands in for it. Without it the residue was called empty and the
## generator's move was dropped, which the hash check then reported as a
## desync and put right -- a counted one, where the contract is none.
func _bare_scalar_write(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	world.enable_journal()
	var _opening: Array[Dictionary] = world.take_events()
	var mirror: World = world.clone()
	world.rng.randomize_seed(12345.0)
	var events: Array[Dictionary] = world.take_events()
	h.equal("sync.a_bare_generator_write_is_one_sync_event", events.size(), 1,
		"nothing was marked, so the residue is the whole of it")
	if not events.is_empty():
		h.equal("sync.of_the_sync_kind",
			DictRead.as_string(events[0]["kind"]), EventJournal.KIND_SYNC)
	mirror.apply_events(events)
	h.equal("sync.and_the_mirror_follows_it", mirror.canonical_hash_hex(),
		world.canonical_hash_hex(), "the generator moved on both")
	h.equal("sync.and_nothing_is_left_behind", world.take_events().size(), 0,
		"the baseline moved with the take")


## The hash invariant, on a real mission and on the fixtures the other suites
## use for the jump and the reactions.
func _invariant(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission(MISSION)
	if loaded.is_empty():
		h.check("invariant.cache_present", false,
			CacheFixture.missing_hint())
		return
	h.check("invariant.cache_present", true, MISSION)
	var world: World = loaded["world"]
	world.enable_journal()
	var mirror: World = world.clone()

	var slot: int = _first_own_unit(world)
	h.check("invariant.a_marine_is_placed", slot >= 0, "slot %d" % slot)
	if slot < 0:
		return

	var view: Dictionary = world.unit_view(slot)
	var start: Vector2i = Vector2i(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	var target: Vector2i = _reachable_cell(world, fill, start)
	h.check("invariant.a_cell_is_reachable", target != start, str(target))
	var _moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, target.x, target.y))
	var walk_events: Array[Dictionary] = world.take_events()
	h.check("invariant.the_walk_marked_events", walk_events.size() > 0,
		"%d event(s)" % walk_events.size())
	mirror.apply_events(walk_events)
	h.equal("invariant.after_move", mirror.canonical_hash_hex(),
		world.canonical_hash_hex(),
		"the mirror is the truth once every delta has landed")

	# Rotate, stand down and end the turn -- three shapes of command, and the
	# turn is the one that runs the computer, the script and the ground tick.
	var _turned: bool = world.submit_rotate(RotateCommand.create(slot, 3))
	mirror.apply_events(world.take_events())
	h.equal("invariant.after_rotate", mirror.canonical_hash_hex(),
		world.canonical_hash_hex())

	var _probed: int = world.probe_fog()
	mirror.apply_events(world.take_events())
	h.equal("invariant.after_the_fog_probe", mirror.canonical_hash_hex(),
		world.canonical_hash_hex(),
		"the probe wakes groups in the truth, so the mirror must see it")

	var turn_events: Array[Dictionary] = []
	for _round: int in range(2):
		var _end: TurnResult = world.submit_end_turn(EndTurnCommand.create())
		turn_events.append_array(world.take_events())
	h.check("invariant.the_turn_marked_events", turn_events.size() > 0,
		"%d event(s)" % turn_events.size())
	mirror.apply_events(turn_events)
	h.equal("invariant.after_end_turn", mirror.canonical_hash_hex(),
		world.canonical_hash_hex(),
		"two hand-overs, the computer's turn and the mission script")

	var carries: bool = true
	for event: Dictionary in turn_events:
		if not event.has("delta"):
			carries = false
	h.check("invariant.every_event_carries_a_delta", carries,
		"%d event(s)" % turn_events.size())

	# A command whose last write is after its own mark still reaches the
	# mirror: `submit_use` charges the movement point after the door's cells.
	var quiet: World = TestFixtures.tiny_world()
	quiet.enable_journal()
	var quiet_mirror: World = quiet.clone()
	var quiet_unit: UnitState = quiet.units_for_ai()[0]
	quiet_unit.hp = 7
	var residue: Array[Dictionary] = quiet.take_events()
	h.equal("invariant.an_empty_list_gets_a_sync", residue.size(), 1,
		"a change with no boundary is still carried")
	h.equal("invariant.the_sync_is_named",
		DictRead.as_string(residue[0]["kind"]), EventJournal.KIND_SYNC)
	quiet_mirror.apply_events(residue)
	h.equal("invariant.the_sync_carries_it", quiet_mirror.canonical_hash_hex(),
		quiet.canonical_hash_hex())


## Where the boundaries fall, and what each event's delta is worth on its own.
func _boundaries(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_mission(MISSION)
	if loaded.is_empty():
		return
	var world: World = loaded["world"]
	world.enable_journal()
	var mirror: World = world.clone()
	var slot: int = _first_own_unit(world)
	if slot < 0:
		return
	var view: Dictionary = world.unit_view(slot)
	var start: Vector2i = Vector2i(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))
	var fill: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot))
	var target: Vector2i = _reachable_cell(world, fill, start)
	var _moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, target.x, target.y))
	var events: Array[Dictionary] = world.take_events()
	var kinds: Array[String] = []
	for event: Dictionary in events:
		kinds.append(DictRead.as_string(event["kind"]))
	h.check("order.the_walk_opens_with_its_passes",
		kinds.size() >= 2 and kinds[0] == "move_begin" and kinds[1] == "move",
		str(kinds))
	h.equal("order.the_source_is_the_events_own",
		Vector2i(DictRead.as_int(events[1]["x"]),
			DictRead.as_int(events[1]["y"])), start)
	h.equal("order.the_destination_is_too",
		Vector2i(DictRead.as_int(events[1]["tx"]),
			DictRead.as_int(events[1]["ty"])), target)
	var payload: Dictionary = DictRead.as_dict(events[1]["payload"])
	h.check("order.the_walk_carries_its_path",
		DictRead.as_array(payload["path"]).size() > 0,
		"the playback cannot re-derive it against the post-turn world")

	# The picture's whole reason for the split: before the move's delta the
	# mirror still has the unit where it set off from.
	mirror.apply_delta(DictRead.as_dict(events[0]["delta"]))
	var before: Dictionary = mirror.unit_view(slot)
	h.equal("pin.the_mover_stands_on_its_source_before_its_delta",
		Vector2i(DictRead.as_int(before["x"]), DictRead.as_int(before["y"])),
		start, "the opening passes wrote no position")
	mirror.apply_delta(DictRead.as_dict(events[1]["delta"]))
	var after: Dictionary = mirror.unit_view(slot)
	h.equal("pin.and_on_the_destination_after",
		Vector2i(DictRead.as_int(after["x"]), DictRead.as_int(after["y"])),
		target)

	# A shot, its victim and the reactions it draws. The aim is a **cell**,
	# so a shot at long range still fires, still spends and still marks -- the
	# hit chance decides only what it hits.
	var shooter: int = -1
	var victim: int = -1
	var nearest: int = 1 << 30
	for own: int in world.unit_slots():
		var record: Dictionary = world.unit_view(own)
		if DictRead.as_int(record["player"]) == UnitState.PLAYER_ALIEN:
			continue
		if DictRead.as_int(record["hp"]) <= 0:
			continue
		for other: int in world.unit_slots():
			var enemy: Dictionary = world.unit_view(other)
			if DictRead.as_int(enemy["player"]) != UnitState.PLAYER_ALIEN:
				continue
			if DictRead.as_int(enemy["hp"]) <= 0:
				continue
			var dx: int = DictRead.as_int(record["x"]) \
				- DictRead.as_int(enemy["x"])
			var dy: int = DictRead.as_int(record["y"]) \
				- DictRead.as_int(enemy["y"])
			var d: int = dx * dx + dy * dy
			if d < nearest:
				nearest = d
				shooter = own
				victim = other
	h.check("order.a_shot_is_available", shooter >= 0 and victim >= 0,
		"shooter %d at %d" % [shooter, victim])
	if shooter < 0:
		return
	var enemy_view: Dictionary = world.unit_view(victim)
	var alive_before: int = DictRead.as_int(enemy_view["hp"])
	# The mirror is brought level first, so what follows is the shot alone.
	mirror.apply_events(events)
	var _shot: AttackResult = world.submit_attack(AttackCommand.create(
		shooter, DictRead.as_int(enemy_view["x"]),
		DictRead.as_int(enemy_view["y"])))
	var shot_events: Array[Dictionary] = world.take_events()
	var shot_kinds: Array[String] = []
	for event: Dictionary in shot_events:
		shot_kinds.append(DictRead.as_string(event["kind"]))
	h.check("order.the_shot_is_the_first_event",
		not shot_kinds.is_empty() and shot_kinds[0] == "fire", str(shot_kinds))
	h.check("order.reactions_is_never_a_journal_kind",
		not shot_kinds.has("reactions"),
		"the drain marks one `reaction` per shot, not a list")
	var reaction_events: int = 0
	for kind: String in shot_kinds:
		if kind == "reaction":
			reaction_events += 1
	h.equal("order.one_reaction_per_shot", reaction_events,
		_shot.reactions.size(),
		"as many events as the drain resolved shots")

	# The victim's record moves with the shot's delta and not before it.
	var still: Dictionary = mirror.unit_view(victim)
	h.equal("pin.the_victim_is_untouched_before_the_fire_delta",
		DictRead.as_int(still["hp"]), alive_before,
		"the truth resolved the shot; the mirror has not been told")
	mirror.apply_events(shot_events)
	h.equal("pin.the_victim_follows_the_fire_delta",
		DictRead.as_int(mirror.unit_view(victim).get("hp", -1)),
		DictRead.as_int(world.unit_view(victim).get("hp", -1)))
	h.equal("invariant.after_attack", mirror.canonical_hash_hex(),
		world.canonical_hash_hex())


## The first live unit the human seat owns.
static func _first_own_unit(world: World) -> int:
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		if DictRead.as_int(view["player"]) == UnitState.PLAYER_ALIEN:
			continue
		if DictRead.as_int(view["hp"]) <= 0:
			continue
		if DictRead.as_int(view["mp"]) <= 0:
			continue
		return slot
	return -1


## A cell the fill says the unit can walk to, nearest first so the walk is
## short and its events few.
static func _reachable_cell(world: World, fill: MoveMapResult,
		from: Vector2i) -> Vector2i:
	for radius: int in range(1, 4):
		for dy: int in range(-radius, radius + 1):
			for dx: int in range(-radius, radius + 1):
				var at: Vector2i = from + Vector2i(dx, dy)
				if at == from or not world.state.in_bounds(at.x, at.y):
					continue
				if not fill.is_reachable(at.x, at.y):
					continue
				if world.state.unit_at(
						world.state.index_of(at.x, at.y)) != MapState.NO_UNIT:
					continue
				return at
	return from
