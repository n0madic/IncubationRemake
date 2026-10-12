extends TestSuite

## Oracle boundary: specification-only.  This is the last bullet of docs/92
## section 10.4 turned into something that fails the run.
##
## Two independent things:
##
## 1. **`game` cannot mutate `core`'s internal arrays.**  Taking a snapshot,
##    writing over every array in it and re-hashing the world must leave the
##    hash unchanged.  Type discipline alone would not settle this: in Godot
##    4.7 a `Packed*Array` returned from a function **aliases** the original,
##    which was established by running it, so every accessor duplicates and this
##    test is what keeps them doing so.
## 2. **`core` has no scene tree, rendering, audio, filesystem or engine
##    singleton dependency.**  Every `.gd` under `core/` is read as text and the
##    forbidden symbols are searched for.  A scan is cruder than a real
##    dependency analysis and that is the point: it cannot be satisfied by
##    accident.

const CORE_DIR: String = "res://core"

## Reading a file is how the scan works, so this suite is the one place under
## `tests/` that touches the filesystem; `core/` itself never may.
const FORBIDDEN: Array[String] = [
	"get_node", "extends Node", "FileAccess", "DirAccess", "ResourceLoader",
	"Engine.", "Input", "RenderingServer", "AudioServer", "OS.", "Time.",
]

## `assert(started == OK)` and `HashingContext` are legitimate in `core`; the
## scan must not trip over a substring inside a comment that names the rule.
const SCAN_SKIP_PREFIX: String = "#"


const GAME_DIR: String = "res://game"
const TESTS_DIR: String = "res://tests"
## A world of its own, and the light it must carry (see
## [method _check_own_worlds_carry_the_sun_fill]).
const OWN_WORLD_MARK: String = "own_world_3d = true"
const SUN_FILL_MARK: String = "SunShadow.fill()"


func run(h: TestHarness) -> void:
	h.begin("isolation", TestHarness.ORACLE_SPEC)
	_check_snapshot_isolation(h)
	_check_no_forbidden_symbols(h)
	_check_no_test_classes_in_shipping_code(h)
	_check_own_worlds_carry_the_sun_fill(h)
	_check_empty_result_is_sized(h)


## An unknown slot still gets a result the map's own size.  It used to return
## one that *declared* the width and height but carried zero-length arrays, so
## the ground overlay (`game/overlay/ground_sprites.gd`, once `highlight.gd`)
## -- which walks width x height -- indexed past the end for every cell of
## the map.
func _check_empty_result_is_sized(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	var result: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(999, false))
	var cells: int = world.state.cell_count()
	h.equal("empty_result.states", result.states().size(), cells)
	h.equal("empty_result.mp_left", result.mp_left().size(), cells)
	h.equal("empty_result.reachable", result.reachable_count(), 0)


func _check_snapshot_isolation(h: TestHarness) -> void:
	var world: World = TestFixtures.tiny_world()
	if world == null:
		h.check("fixture", false, "could not build the synthetic world")
		return
	var before: String = world.canonical_hash_hex()

	var snapshot: Dictionary = world.terrain_snapshot()
	var heights: PackedInt32Array = snapshot["height_map"]
	var field_types: PackedByteArray = snapshot["field_type"]
	var action_points: PackedByteArray = snapshot["action_point"]
	var units: PackedInt32Array = snapshot["unit"]
	var obstacles: PackedByteArray = snapshot["obstacle"]
	var effects: Array[PackedByteArray] = snapshot["effect"]
	heights.fill(0x7FFFFFF)
	field_types.fill(0xFF)
	action_points.fill(0xFF)
	units.fill(-99)
	obstacles.fill(0)
	for slot: PackedByteArray in effects:
		slot.fill(0xAB)
	h.equal("snapshot.hash_unchanged", world.canonical_hash_hex(), before)

	# The same for a move-map result, which is the other value that leaves core.
	var result: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(world.unit_slots()[0], false))
	var digest: String = CanonicalHash.to_hex(result.result_hash())
	var states: PackedByteArray = result.states()
	states.fill(99)
	var left: PackedInt32Array = result.mp_left()
	left.fill(-1)
	h.equal("result.hash_unchanged",
		CanonicalHash.to_hex(result.result_hash()), digest)
	h.equal("world.hash_unchanged_by_query", world.canonical_hash_hex(), before)


func _check_no_forbidden_symbols(h: TestHarness) -> void:
	var files: PackedStringArray = _core_files()
	h.check("scan.files", files.size() >= 10,
		"%d scripts under %s" % [files.size(), CORE_DIR])
	var offences: PackedStringArray = PackedStringArray()
	for path: String in files:
		var text: String = FileAccess.get_file_as_string(path)
		var line_number: int = 0
		for line: String in text.split("\n"):
			line_number += 1
			var stripped: String = line.strip_edges()
			if stripped.begins_with(SCAN_SKIP_PREFIX):
				continue
			var code: String = line
			var comment: int = code.find("#")
			if comment >= 0:
				code = code.substr(0, comment)
			for symbol: String in FORBIDDEN:
				if code.contains(symbol):
					offences.append("%s:%d %s" % [path, line_number, symbol])
	h.equal("scan.clean", ", ".join(offences), "")


## A build that compiled its scripts has no text to scan.  The export preset
## used for the suites keeps them as text precisely so that the scans above are
## not quietly skipped there.
func _core_files() -> PackedStringArray:
	return _scripts_under(CORE_DIR)


## Nothing shipped may name a class that only exists under `tests/`.
##
## The shipping export excludes `tests/`, and a `class_name` from there used in
## `game/` or `core/` stops *that* file from compiling in the exported build --
## silently, because the editor and the test export both have the directory.
## It happened once: `game/main.gd` named `TestRunner` to branch on the
## `run_tests` feature, and the shipping build would not start. It now loads the
## runner by path instead, and this check is what keeps it that way.
func _check_no_test_classes_in_shipping_code(h: TestHarness) -> void:
	var test_classes: PackedStringArray = _class_names_under(TESTS_DIR)
	h.check("test_classes.found", test_classes.size() >= 3,
		"%d class_name declarations under %s" % [test_classes.size(), TESTS_DIR])
	var offences: PackedStringArray = PackedStringArray()
	for directory: String in [CORE_DIR, GAME_DIR]:
		for path: String in _scripts_under(directory):
			var text: String = FileAccess.get_file_as_string(path)
			var line_number: int = 0
			for line: String in text.split("\n"):
				line_number += 1
				var code: String = line
				var comment: int = code.find("#")
				if comment >= 0:
					code = code.substr(0, comment)
				for name: String in test_classes:
					if code.contains(name):
						offences.append("%s:%d %s"
							% [path, line_number, name])
	h.equal("test_classes.unused_by_shipping_code", ", ".join(offences), "")


## Every [World3D] of its own carries [method SunShadow.fill] (docs/92 section
## 7.29). While a sun is up anywhere, the lit materials paint no EMISSION and
## draw their whole colour through a light's pass, so a world with no light
## draws its prototypes and bodies black -- the upgrade screen's soldier was
## that world, and the next inset is the one this keeps from repeating it.
func _check_own_worlds_carry_the_sun_fill(h: TestHarness) -> void:
	var own_worlds: PackedStringArray = PackedStringArray()
	var unlit: PackedStringArray = PackedStringArray()
	for path: String in _scripts_under(GAME_DIR):
		var text: String = FileAccess.get_file_as_string(path)
		if not text.contains(OWN_WORLD_MARK):
			continue
		own_worlds.append(path)
		if not text.contains(SUN_FILL_MARK):
			unlit.append(path)
	h.check("own_world.found", not own_worlds.is_empty(),
		"the upgrade screen's inset at least; none means nothing was scanned")
	h.equal("own_world.carries_the_sun_fill", ", ".join(unlit), "")


func _class_names_under(directory: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for path: String in _scripts_under(directory):
		for line: String in FileAccess.get_file_as_string(path).split("\n"):
			var stripped: String = line.strip_edges()
			if stripped.begins_with("class_name "):
				out.append(stripped.substr(11).split(" ")[0].strip_edges())
	return out


## **Recursive.** `core/lcl/` is a subdirectory, and a scan that stopped at the
## top level would exempt every file in it from the whole of this suite -- which
## is the shape of hole this file exists to close, not to have.
func _scripts_under(directory: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		return out
	for name: String in dir.get_files():
		if name.ends_with(".gd") or name.ends_with(".gdc"):
			out.append(directory + "/" + name)
	for sub: String in dir.get_directories():
		out.append_array(_scripts_under(directory + "/" + sub))
	out.sort()
	return out
