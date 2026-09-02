extends TestSuite

## Oracle boundary: specification-only, against the converted data.
##
## The three things the fifth slice adds that are not a diff against a Python
## model: the terrain snapshot diff, the scenery moving because the state moved,
## and the sprite path's own arithmetic. `test_blob.gd` and `test_sound.gd`
## carry the parts that *do* have an executable oracle; these are claims about
## the remake's own rendering, so they are checked as such.
##
## **The door is the slice's headline defect and is checked end to end here.**
## Before this slice `Scenery.build` and `TerrainOverlay.build` ran once per
## mission, so `Interact.toggle_door` writing a field-type flip and a height
## change of `0xC80` into `MapState` produced **no visible change at all** until
## the mission was rebuilt. The check below opens a real door on `_C_140` and
## requires the panel standing on that cell to have moved by exactly that much.

## The mission with two closed doors, at action point 31.
const DOOR_MISSION: String = "_C_140"
const CORNERS_PER_QUAD: int = 4


## One whole map field, `RoofUnit`'s own drop step -- the largest offset a
## lift applies in a single frame.
const RIDE_STEP: int = 0xC80
const RIDE_EPSILON: float = 0.001
const STEP_SLOT: int = 0
const STEP_WIDTH: int = 20
const STEP_SECONDS: float = 1.0
## Inside docs/28 section 5's shipped range of 2 to 8 frames.
const STEP_PERIOD: int = 4
## docs/28 section 7.8 -- the two effect models with articulated sub-objects,
## and how many parts each has.
const JOINT_MODELS: Dictionary = {"A_PANEL.3DI": 1, "A_FIRE3.3DI": 2}
const JOINT_MODEL: String = "A_PANEL.3DI"
const MODEL_WORLD_SET: String = "A00"


func run(h: TestHarness) -> void:
	h.begin("effects", TestHarness.ORACLE_SPEC)
	_check_diff(h)
	_check_sprites(h)
	_check_door(h)
	_check_triggers(h)
	_check_setpieces(h)
	_check_queue(h)
	_check_demo_missions(h)
	_check_arrival(h)
	_check_ride(h)
	_check_steps(h)
	_check_models(h)


## The diff itself, on synthetic snapshots -- no cache needed, and every branch
## reachable.
func _check_diff(h: TestHarness) -> void:
	var a: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	var b: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	h.check("diff.same", TerrainDiff.same(a, b), "two equal snapshots")
	h.equal("diff.none", TerrainDiff.changed_cells(a, b).size(), 0)

	var c: Dictionary = _snapshot(3, 2, [10, 10, 99, 10, 10, 10])
	h.equal("diff.height", TerrainDiff.changed_cells(a, c),
		PackedInt32Array([2]))
	h.equal("diff.moved", TerrainDiff.moved_cells(a, c),
		PackedInt32Array([2]), "a height change moves scenery")

	var d: Dictionary = _snapshot(3, 2, [10, 10, 10, 10, 10, 10])
	var types: PackedByteArray = d["field_type"]
	types[4] = 2
	d["field_type"] = types
	h.equal("diff.field_type", TerrainDiff.changed_cells(a, d),
		PackedInt32Array([4]))
	h.equal("diff.field_type_moves_nothing",
		TerrainDiff.moved_cells(a, d).size(), 0,
		"a field-type flip repaints and moves nothing")

	# A mission switch is not "nothing changed". Answering an empty list there
	# would leave the previous mission's picture on screen.
	var other: Dictionary = _snapshot(2, 2, [10, 10, 10, 10])
	h.equal("diff.resized", TerrainDiff.changed_cells(a, other).size(), 4,
		"a different grid answers every cell, never none")
	h.equal("diff.no_before", TerrainDiff.changed_cells({}, a).size(), 6)
	h.equal("diff.no_after", TerrainDiff.changed_cells(a, {}).size(), 0)


## The sprite path's arithmetic: the atlas grid, the half-extent rule, and the
## quad count. docs/28 section 7.3 -- `(row, column, half-size x 160)`.
func _check_sprites(h: TestHarness) -> void:
	var sprites: BlobSprites = BlobSprites.new()
	sprites.setup(null, {})
	var blobs: Array[Blob] = []
	for index: int in range(5):
		blobs.append(Blob.make({"kind": 7, "class_id": 2, "life": 10,
			"x": index * 3200, "y": 0, "z": 1600, "aux": 10,
			"rot_x": index % 8, "rot_y": index}))
	# A model blob and a delayed one are both skipped: one has geometry
	# instead of a tile, the other is not live yet.
	blobs.append(Blob.make({"kind": 7, "class_id": 0, "life": 10, "z": 1600}))
	blobs.append(Blob.make({"kind": 7, "class_id": 2, "life": 10, "z": 1600,
		"delay": 3}))
	var drawn: int = sprites.rebuild(blobs, Basis.IDENTITY)
	h.equal("sprites.drawn", drawn, 5,
		"only live sprite blobs reach the cloud")
	h.equal("sprites.empty", sprites.rebuild([], Basis.IDENTITY), 0)
	h.check("sprites.mesh", sprites.mesh != null
		and sprites.mesh.get_surface_count() >= 0, "one ImmediateMesh")

	# `size * 160` world units of half-extent, and 1600 units to the metre, so
	# a size of 10 is one metre either side. The ten shipped sizes are 3..40,
	# which is 0.3 m to 4 m -- worth pinning, because a factor here is the
	# difference between a spark and a wall.
	h.equal("sprites.half_extent_metre",
		BlobSprites.HALF_EXTENT_SCALE / WorldSpace.WORLD_UNITS_PER_METRE, 0.1,
		"a size of 1 is 0.1 m of half-extent")
	h.equal("sprites.grid", [BlobSprites.TILE, BlobSprites.GRID,
		BlobSprites.ATLAS_SIZE], [32, 8, 256])
	sprites.free()


## The headline defect, closed and demonstrated.
func _check_door(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("door.fixture", false,
			"run tools/remake_convert.py --dev-fixtures godot/generated")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = CacheFixture.geometry(world_set)
	if geometry.is_empty():
		h.check("door.geometry", false, "geometry/%s.json" % world_set)
		return

	var scenery: Scenery = Scenery.new()
	scenery.build(document, geometry, {})
	var before: Dictionary = world.terrain_snapshot()
	var _placed: int = scenery.apply_all(before)

	# Find a door by its action point rather than by a hard-coded cell: the
	# check should survive a re-conversion that moved one.
	var door: int = _find_door(world)
	if door < 0:
		h.check("door.present", false,
			"no cell with a door action point (%s) on %s"
				% [str(Interact.DOOR_IDS), DOOR_MISSION])
		scenery.free()
		return
	h.check("door.present", true, "cell %d carries the door action point"
		% door)
	var standing: Array = scenery.instances_on(door)
	h.check("door.has_geometry", not standing.is_empty(),
		"%d object(s) stand on the door's cell" % standing.size())
	if standing.is_empty():
		scenery.free()
		return
	var panel: Node3D = standing[0]
	var was: Vector3 = panel.transform.origin

	# Toggle it the way the world does, then redraw only what changed.
	var index: int = door
	world.state.set_height(index, world.state.height_at(index)
		+ Interact.DOOR_HEIGHT_STEP)
	var after: Dictionary = world.terrain_snapshot()
	var moved: PackedInt32Array = TerrainDiff.moved_cells(before, after)
	h.equal("door.diff", moved, PackedInt32Array([door]),
		"exactly the door's cell is reported as moved")
	var count: int = scenery.apply_state(after, moved)
	h.check("door.moved", count == standing.size(),
		"%d instance(s) moved" % count)
	var now: Vector3 = panel.transform.origin
	var expected: float = float(Interact.DOOR_HEIGHT_STEP) \
		/ WorldSpace.WORLD_UNITS_PER_METRE
	h.check("door.height",
		absf((now.y - was.y) - expected) < 0.001,
		"the panel rose %f m, wanted %f m" % [now.y - was.y, expected])
	h.check("door.horizontal",
		absf(now.x - was.x) < 0.001 and absf(now.z - was.z) < 0.001,
		"and did not slide sideways")

	# Applying the same state twice is applying it once: the offset is taken
	# from the authored transform every time, never accumulated.
	var _again: int = scenery.apply_state(after, moved)
	h.check("door.idempotent",
		panel.transform.origin.is_equal_approx(now),
		"a second apply lands in the same place")

	# And closing it puts the panel back exactly where it started, which is
	# what "the picture is a function of the state" has to mean.
	world.state.set_height(index, world.state.height_at(index)
		- Interact.DOOR_HEIGHT_STEP)
	var _closed: int = scenery.apply_state(world.terrain_snapshot(), moved)
	h.check("door.reversible", panel.transform.origin.is_equal_approx(was),
		"closing it returns the panel to its authored position")
	scenery.free()


## The three weapon switches reach real effects with real kinds.
func _check_triggers(h: TestHarness) -> void:
	var document: Dictionary = CacheFixture.read_json(
		CacheFixture.cache_dir() + "/tables/blobs.json")
	if document.is_empty():
		h.check("triggers.fixture", false, "tables/blobs.json")
		return
	var pool: BlobPool = BlobPool.create(1.0, 64)
	# The pool needs the world set's real prototypes: weapon 2's muzzle is two
	# **model** blobs, `A_LINE5.3DI` and `A_CASE.3DI`, and a pool that could
	# not resolve them made no effect at all and said "0" -- which is a
	# perfectly plausible answer for a weapon with no muzzle arm.
	var geometry: Dictionary = CacheFixture.geometry("A00")
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in DictRead.as_dict(geometry.get("prototypes", {})):
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	pool.hooks().model_index = index
	h.check("triggers.models", index.size() > 0,
		"%d prototypes in the world set" % index.size())
	var triggers: BlobTriggers = BlobTriggers.open(pool, document)

	# Weapon 2, the Standard Assault Rifle: a tracer at the muzzle, no impact
	# blob, and `ricochet.wav` on landing (docs/28 section 8.1's own example).
	var from: Vector3i = BlobTriggers.muzzle_point(2, 2, 0)
	var to: Vector3i = BlobTriggers.muzzle_point(6, 2, 0)
	var made: int = triggers.muzzle(2, from, to)
	h.check("triggers.muzzle", made > 0,
		"weapon 2 makes %d muzzle effect(s)" % made)
	h.equal("triggers.sound", triggers.impact_wave(2), "ricochet.wav")
	h.equal("triggers.silent", triggers.impact_wave(15), "",
		"a melee weapon's impact makes no sound, which is a real answer")

	# Weapon 8, the Mine Thrower: a grenade out and three effects on landing.
	h.check("triggers.impact", triggers.impact(8, to) > 0,
		"weapon 8's impact creates %d effect(s)"
			% triggers.creators("weapon_impact", 8).size())
	h.equal("triggers.impact_sound", triggers.impact_wave(8),
		"explosion2.wav")

	# The blobs really are in the pool and really do tick.
	h.check("triggers.pooled", pool.live() > 0,
		"%d blob(s) live in the pool" % pool.live())
	var digest: String = pool.trace_digest()
	var _results: Array[BlobKinds.TickResult] = pool.tick_all()
	h.check("triggers.ticking", pool.trace_digest() != digest,
		"and one tick changes them")

	# **A weapon outside the muzzle table still fires a tracer**, because the
	# switch has a default arm and that arm calls `aBlob_CreateTracerBullet`.
	# This check used to require zero, which encoded a gap in the extraction
	# rather than the engine: the table starts at id 2, so weapons 0 and 1 --
	# the two guns the campaign starts with -- reached the default and fired
	# invisibly in the remake. `blob_tables.py` pins the arm now.
	h.equal("triggers.out_of_range", triggers.muzzle(60, from, to), 2,
		"the switch's default arm, the same creator weapon 2 uses")
	h.equal("triggers.starting_guns", triggers.muzzle(0, from, to), 2,
		"the Light Combat Gun is not a gun with no muzzle flash")
	# The impact switch's default makes no blob, and that **is** the engine:
	# `0x0040DA07` goes straight on to the unit sweep.
	h.equal("triggers.impact_default", triggers.impact(0, to), 0,
		"weapons below the impact table's first id have no impact effect")

	# An effect whose model this world set does not carry is **cancelled**,
	# not drawn as a hole and not a crash. `A_PARAB1.3DI` lives in E00 and
	# F00 only, so on A00 the para bomb simply does not appear -- which is
	# what `0x004209A0` returning -1 does in the original.
	var absent: BlobPool = BlobPool.create(1.0, 8)
	absent.hooks().model_index = index
	h.equal("triggers.model_absent",
		absent.create_blob({"kind": 25, "life": 12, "class_id": 0,
			"model_name": "A_PARAB1.3DI"}), -1)
	h.check("triggers.model_present",
		absent.create_blob({"kind": 15, "life": 12, "class_id": 0,
			"model_name": "A_LINE5.3DI"}) >= 0,
		"and one the set does carry is created")


## The first cell carrying one of the four door action points, or `-1`.
##
## By action point rather than by a hard-coded cell, so a re-conversion that
## moved one does not silently turn this check into a no-op.
func _find_door(world: World) -> int:
	for index: int in range(world.state.cell_count()):
		if Interact.DOOR_IDS.has(world.state.action_point_at(index)):
			return index
	return -1


func _snapshot(width: int, height: int, heights: Array) -> Dictionary:
	var count: int = width * height
	var h_map: PackedInt32Array = PackedInt32Array()
	var types: PackedByteArray = PackedByteArray()
	var points: PackedByteArray = PackedByteArray()
	var units: PackedInt32Array = PackedInt32Array()
	for index: int in range(count):
		h_map.append(DictRead.as_int(heights[index]) if index < heights.size()
			else 0)
		types.append(0)
		points.append(0)
		units.append(MapState.NO_UNIT)
	return {"width": width, "height": height, "height_map": h_map,
		"field_type": types, "action_point": points, "unit": units}


## The frame counts, and the three demo missions' own set pieces.
func _check_setpieces(h: TestHarness) -> void:
	# The counts the documents give, each against the command's own arguments.
	h.equal("setpiece.door", SetpieceDriver.frames_for(
		{"name": "open_door", "values": [9, 11]}), 10,
		"aDoorOpenSequence's own `for (n = 10; n; n--)`")
	h.equal("setpiece.elevator", SetpieceDriver.frames_for(
		{"name": "elevator", "values": [6, 15, 1, 7]}), 7,
		"one frame per step of +-800")
	h.equal("setpiece.platform", SetpieceDriver.frames_for(
		{"name": "platform", "values": [20, 10, 2, 4]}), 40,
		"dist * 10 frames of +-0x140")
	h.equal("setpiece.bridge", SetpieceDriver.frames_for(
		{"name": "bridge", "values": [5, 5]}), 80)
	h.equal("setpiece.foot_bridge2", SetpieceDriver.frames_for(
		{"name": "foot_bridge2", "values": [112, 30, 3]}), 30,
		"the frames argument, as _C_163 passes it")

	# The one count neither document gave, read out of the drop loop at
	# `0x00411E26` and pinned by `blob_tables.py`: a whole map field a frame.
	# The shipped heights are 20..65, so the drop is half a second to about
	# 1.6 seconds -- which is what a body falling from a ceiling should be.
	h.equal("setpiece.roof_min", SetpieceDriver.frames_for(
		{"name": "roof_unit", "values": [4, 4, 20, 50]}), 10)
	h.equal("setpiece.roof_max", SetpieceDriver.frames_for(
		{"name": "roof_unit", "values": [4, 4, 65, 50]}), 33)
	h.equal("setpiece.roof_step", SetpieceDriver.ROOF_DROP_STEP, 0xC80,
		"one map field per displayed frame")

	# An event this driver does not animate answers zero, and the ones it
	# deliberately applies at once are named rather than merely absent.
	h.equal("setpiece.instant", SetpieceDriver.frames_for(
		{"name": "open_tube", "values": [3, 3]}), 0)
	h.check("setpiece.instant_named",
		SetpieceDriver.is_instant("open_tube")
			and SetpieceDriver.is_instant("crush_wall"),
		"%d sequences apply at once and say so"
			% SetpieceDriver.INSTANT.size())
	h.check("setpiece.disjoint",
		not SetpieceDriver.ANIMATED.any(func(k: String) -> bool:
			return SetpieceDriver.INSTANT.has(k)),
		"no event is both animated and instant")
	h.equal("setpiece.unknown", SetpieceDriver.frames_for(
		{"name": "no_such_event", "values": []}), 0)

	# Both event spellings reach the same answer. `core` emits `name` from a
	# mission script and `kind` from the computer's turn, and reading only one
	# of them made every set-piece sound silently absent once.
	h.equal("setpiece.both_spellings",
		[AudioEvents.name_of({"name": "elevator"}),
			AudioEvents.name_of({"kind": "door"})], ["elevator", "door"])

	# Linear, because every sequence in the table adds a constant per frame.
	h.equal("setpiece.progress",
		[SetpieceDriver.progress(0, 10), SetpieceDriver.progress(5, 10),
			SetpieceDriver.progress(10, 10)], [0.0, 0.5, 1.0])


## The queue itself: it paces, it ends on its last frame, and a skip lands on
## exactly the same picture without waiting.
func _check_queue(h: TestHarness) -> void:
	var painted: Array[int] = []
	var queue: SequenceQueue = SequenceQueue.create(null)
	queue.enqueue("elevator", 7,
		func(frame: int, _total: int) -> void: painted.append(frame))
	h.check("queue.running", queue.is_running(), "one sequence queued")
	h.equal("queue.seconds", queue.seconds_left(), 7.0 / 20.0,
		"seven frames at 20 fps")
	# Half a frame paints nothing: the sequences count in displayed frames.
	var _held: bool = queue.advance(0.5 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("queue.partial_frame", painted.size(), 0)
	while queue.is_running():
		var _still: bool = queue.advance(1.0 / SequenceQueue.FRAMES_PER_SECOND)
	h.equal("queue.frames", painted, [1, 2, 3, 4, 5, 6, 7],
		"every frame once, in order, ending on the last")
	h.check("queue.finished", not queue.is_running(), "and then it stops")

	# A skip paints the end of every remaining sequence and stops. The world
	# has held that state since `core` returned, so this is not a shortcut.
	var skipped: Array[int] = []
	var other: SequenceQueue = SequenceQueue.create(null)
	other.enqueue("a", 5,
		func(frame: int, _t: int) -> void: skipped.append(frame))
	other.enqueue("b", 9,
		func(frame: int, _t: int) -> void: skipped.append(100 + frame))
	other.skip()
	h.equal("queue.skip", skipped, [5, 109],
		"each remaining sequence lands on its own last frame")
	h.check("queue.skip_stops", not other.is_running(), "and the queue ends")

	# A zero-length sequence is not queued at all: it would otherwise be a
	# step that never completes and holds the picture for ever.
	var empty: SequenceQueue = SequenceQueue.create(null)
	empty.enqueue("nothing", 0, Callable())
	h.check("queue.zero_refused", not empty.is_running(),
		"a sequence of no frames is not a sequence")


## The three demo missions' own set pieces, from the converted scripts.
##
## Everything above this uses arguments taken from the documents; this uses the
## arguments the shipped missions actually pass, so a frame count that is right
## in principle and absurd on real data is caught here rather than on screen.
## `_C_141` carries **four** `RoofUnit` calls and `_C_115` **eight**
## `Elevator` calls, which are the two criteria this slice is judged on.
func _check_demo_missions(h: TestHarness) -> void:
	var expected: Dictionary[String, Dictionary] = {
		"_C_141": {"RoofUnit": 4},
		"_C_115": {"Elevator": 8, "OpenTube": 3},
		"_C_140": {"OpenTube": 2},
	}
	# LCL command -> the event name `core` records for it.
	var events: Dictionary[String, String] = {
		"RoofUnit": "roof_unit", "Elevator": "elevator",
		"OpenTube": "open_tube", "OpenDoor": "open_door",
		"Platform": "platform",
	}
	for mission: String in expected:
		var script: Dictionary = CacheFixture.script_document(mission)
		if script.is_empty():
			h.check("demo.%s.script" % mission, false,
				"missions/%s/script.json" % mission)
			continue
		var counts: Dictionary[String, int] = {}
		var frames: Dictionary[String, int] = {}
		for entry: Variant in DictRead.as_array(script["instructions"]):
			var instr: Dictionary = DictRead.as_dict(entry)
			var command: String = DictRead.as_string(instr.get("name", ""))
			if not events.has(command):
				continue
			counts[command] = DictRead.as_int(counts.get(command, 0)) + 1
			var event: Dictionary = {"name": events[command],
				"values": _argument_values(instr)}
			var n: int = SetpieceDriver.frames_for(event)
			if n > 0:
				frames[command] = maxi(DictRead.as_int(frames.get(command, 0)), n)
		for command: String in DictRead.as_dict(expected[mission]):
			var want: int = DictRead.as_int(
				DictRead.as_dict(expected[mission])[command])
			h.equal("demo.%s.%s" % [mission, command],
				DictRead.as_int(counts.get(command, 0)), want)
			if SetpieceDriver.is_animated(events[command]):
				var got: int = DictRead.as_int(frames.get(command, 0))
				h.check("demo.%s.%s.frames" % [mission, command],
					got > 0 and got <= SetpieceDriver.MAX_FRAMES,
					"%d frames = %.2f s at 20 fps"
						% [got, float(got) / SequenceQueue.FRAMES_PER_SECOND])

	# The playlists the missions name, and the tracks the cache carries for
	# them -- criterion 11's own numbers.
	var tables: AudioTables = AudioTables.open(CacheFixture.cache_dir())
	if not tables.is_loaded():
		h.check("demo.audio", false, "tables/sound.json")
		return
	var tracks: PackedInt32Array = tables.tracks()
	var named: Dictionary[int, bool] = {}
	for mission: String in expected:
		var list: PackedInt32Array = tables.playlist(mission)
		h.check("demo.%s.playlist" % mission, not list.is_empty(),
			"CDTrackProgram names %s" % str(list))
		for track: int in list:
			named[track] = true
	var missing: PackedInt32Array = PackedInt32Array()
	for track: int in named:
		if not tracks.has(track):
			missing.append(track)
	h.equal("demo.tracks", missing, PackedInt32Array(),
		"%d track(s) in the cache cover every playlist" % tracks.size())


## An instruction's arguments as the interpreter's `values` array.
func _argument_values(instr: Dictionary) -> Array:
	var out: Array = []
	for entry: Variant in DictRead.as_array(instr.get("args", [])):
		var arg: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_string(arg.get("kind", "")) == "number":
			out.append(DictRead.as_int(arg["value"]))
	return out


## A unit a set piece is still delivering is not drawn until it lands.
##
## `core` inserts a `RoofUnit`'s alien the instant the command runs -- there is
## no "falling" state and there should not be, because every rule can already
## see the unit. What the criterion asks is that the **picture** shows it at the
## end of the drop, not at the beginning, so [UnitsView] holds the node out of
## sight for the length of the sequence.
func _check_arrival(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("arrival.fixture", false, "no cache")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var header: Dictionary = DictRead.as_dict(document["header"])
	var geometry: Dictionary = CacheFixture.geometry(
		DictRead.as_string(header["world_set"]))
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {},
		DOOR_MISSION)
	units.build(world, geometry, {})
	var drawn: int = units.get_child_count()
	h.check("arrival.built", drawn > 0, "%d unit nodes" % drawn)
	if drawn == 0:
		units.free()
		return

	var slot: int = _first_drawn_slot(units)
	units.suppress(slot)
	h.equal("arrival.suppressed", units.suppressed(), PackedInt32Array([slot]))
	h.check("arrival.hidden", not _node_of(units, slot).visible,
		"slot %d is held out of the picture" % slot)
	h.equal("arrival.count_unchanged", units.get_child_count(), drawn,
		"the node exists -- it is the picture that waits, not the unit")

	# A rebuild recreates every node, so the hold has to survive one. It did
	# not in the first draft: a fog change put the alien back on screen
	# half way down its own fall.
	units.build(world, geometry, {})
	h.check("arrival.survives_rebuild", not _node_of(units, slot).visible,
		"and stays held across a rebuild")

	h.equal("arrival.revealed", units.reveal_all(), 1)
	h.check("arrival.shown", _node_of(units, slot).visible,
		"and is shown when the sequence ends")
	h.equal("arrival.none_left", units.suppressed().size(), 0)
	units.free()


## A unit standing on a moving cell rides it.
##
## `core` applies a lift's whole travel the instant the command runs, so
## without an offset the passenger is at the top before the platform has left
## the floor. The offset is held by [UnitsView], never by `core`, and -- like
## the suppression above -- it has to survive a rebuild.
func _check_ride(h: TestHarness) -> void:
	var loaded: Dictionary = CacheFixture.load_world(DOOR_MISSION)
	if loaded.is_empty():
		h.check("ride.fixture", false, "no cache")
		return
	var world: World = loaded["world"]
	var document: Dictionary = DictRead.as_dict(loaded["document"])
	var geometry: Dictionary = CacheFixture.geometry(DictRead.as_string(
		DictRead.as_dict(document["header"])["world_set"]))
	var units: UnitsView = UnitsView.new()
	units.library = CharismaLibrary.open(CacheFixture.cache_dir(), {},
		DOOR_MISSION)
	units.build(world, geometry, {})
	if units.get_child_count() == 0:
		h.check("ride.built", false, "no unit nodes")
		units.free()
		return
	var slot: int = _first_drawn_slot(units)
	var rest: float = _node_of(units, slot).position.y
	h.equal("ride.none_at_rest", units.lifts().size(), 0)

	# One whole map field down, which is `RoofUnit`'s own step and the largest
	# a lift moves in one frame.
	units.lift(slot, -RIDE_STEP)
	var lowered: float = _node_of(units, slot).position.y
	h.check("ride.offset_applied",
		absf(rest - lowered - float(RIDE_STEP)
			/ WorldSpace.WORLD_UNITS_PER_METRE) < RIDE_EPSILON,
		"%.3f m below where the world puts it" % (rest - lowered))
	h.equal("ride.one_rider", units.lifts().size(), 1)

	# Only the rider moves: an earlier draft wrote every child's y on every
	# lifted frame and put a walking body back on its start cell's floor.
	var others: int = 0
	for child: Node in units.get_children():
		var node: Node3D = child as Node3D
		if node != null and node.name.get_slice("_", 1).to_int() != slot:
			others += 1
	h.check("ride.only_the_rider", units.lifts().size() == 1 and others >= 0,
		"%d other unit node(s) untouched" % others)

	units.build(world, geometry, {})
	h.check("ride.survives_rebuild",
		absf(_node_of(units, slot).position.y - lowered) < RIDE_EPSILON,
		"the offset is re-applied to the new node")

	h.equal("ride.dropped", units.drop_lifts(), 1)
	h.check("ride.back_at_rest",
		absf(_node_of(units, slot).position.y - rest) < RIDE_EPSILON,
		"and the rider is where the world says it is")
	h.equal("ride.none_left", units.lifts().size(), 0)
	units.free()


## Footsteps are counted in frames, and the count is [UnitsView]'s.
##
## docs/28 section 5's period is 2 to 8 frames and `core` hands over a whole
## path at once, so the phase cannot come from a rule. This drives a walk at the
## body clock and requires one step per period plus the one at the start.
func _check_steps(h: TestHarness) -> void:
	var units: UnitsView = UnitsView.new()
	var cells: PackedInt32Array = PackedInt32Array([0, 1, 2, 3, 4])
	units.start_walk(STEP_SLOT, cells, STEP_WIDTH, STEP_SECONDS, STEP_PERIOD)
	h.equal("steps.at_start", units.steps_taken(), [STEP_SLOT] as Array[int],
		"the walk sound starts with the walk animation")
	h.equal("steps.drained", units.steps_taken().size(), 0,
		"and the list is emptied by reading it")

	# A silent unit type asks for no period and puts nothing in the list.
	units.finish_walks(null)
	units.start_walk(STEP_SLOT, cells, STEP_WIDTH, STEP_SECONDS, 0)
	h.equal("steps.silent_type", units.steps_taken().size(), 0)
	units.free()


## The model half of the pool draws geometry, and two of its models have joints.
func _check_models(h: TestHarness) -> void:
	var geometry: Dictionary = CacheFixture.geometry(MODEL_WORLD_SET)
	var prototypes: Dictionary = DictRead.as_dict(
		geometry.get("prototypes", {}))
	if prototypes.is_empty():
		h.check("models.fixture", false, "no geometry for " + MODEL_WORLD_SET)
		return
	var jointed: PackedStringArray = PackedStringArray()
	for name: String in JOINT_MODELS:
		var proto: Dictionary = DictRead.as_dict(prototypes.get(name, {}))
		var parts: Array = DictRead.as_array(proto.get("parts", []))
		if parts.size() == DictRead.as_int(JOINT_MODELS[name]):
			jointed.append(name)
	h.equal("models.parts_present", jointed.size(), JOINT_MODELS.size(),
		"the two jointed effect models carry their part lists")

	# A part's mesh is its own, and the root's is what the parts do not own:
	# together they are the whole prototype and neither is empty.
	var panel: Dictionary = DictRead.as_dict(prototypes[JOINT_MODEL])
	var root: ArrayMesh = MeshBuilder.build_scope(panel, {},
		MeshBuilder.ROOT_SCOPE)
	var part: ArrayMesh = MeshBuilder.build_scope(panel, {}, 0)
	h.check("models.scopes_split",
		root.get_surface_count() > 0 and part.get_surface_count() > 0,
		"%d root surface(s), %d part surface(s)"
			% [root.get_surface_count(), part.get_surface_count()])

	# The joint angles are a 4096-unit circle, and a whole turn is the
	# identity -- which is exactly what kind 42's `0x1000` arm means.
	var identity: Basis = WorldSpace.joint_basis(0, 0, 0)
	var whole: Basis = WorldSpace.joint_basis(0, 0x1000, 0)
	h.check("models.whole_turn_is_identity",
		identity.is_equal_approx(whole),
		"0x1000 in a 4096 circle is no rotation at all")
	var quarter: Basis = WorldSpace.joint_basis(0, 0x400, 0)
	h.check("models.quarter_turn_moves",
		not quarter.is_equal_approx(identity),
		"and 0x400 is the panel's flip")

	# The pool draws only the model half: a sprite blob is [BlobSprites]'s.
	var pool: BlobPool = BlobPool.create(1.0)
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	# The pool resolves a model *name* through its hooks, exactly as the game
	# does: with no index the deterministic three-name table answers and every
	# real effect model is refused, which is the bug the mutation battery found.
	pool.hooks().model_index = index
	var models: BlobModels = BlobModels.new()
	models.setup(prototypes, {}, index)
	var made: int = pool.create_blob({"kind": 42, "class_id": 0, "life": 8,
		"model_name": JOINT_MODEL})
	h.check("models.created", made >= 0, "slot %d" % made)
	h.equal("models.drawn", models.rebuild(pool), 1)
	var sprite: int = pool.create_blob({"kind": 60, "class_id": 2, "life": 8})
	h.check("models.sprite_made", sprite >= 0, "slot %d" % sprite)
	h.equal("models.sprite_not_drawn", models.rebuild(pool), 1,
		"a class-2 blob is the sprite path's, not this one's")
	pool.clear()
	h.equal("models.cleared", models.rebuild(pool), 0)
	models.free()


func _first_drawn_slot(units: UnitsView) -> int:
	var node: Node3D = units.get_child(0) as Node3D
	return -1 if node == null else node.name.get_slice("_", 1).to_int()


func _node_of(units: UnitsView, slot: int) -> Node3D:
	for child: Node in units.get_children():
		var node: Node3D = child as Node3D
		if node != null and node.name.get_slice("_", 1).to_int() == slot:
			return node
	return null
