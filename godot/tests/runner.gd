class_name TestRunner
extends RefCounted

## The suite list and the run loop, shared by the two entry points.
##
## `tests/main.gd` is the development entry (`godot --script res://tests/main.gd`)
## and `game/main.gd` is the exported one: a build made with the `run_tests`
## custom feature runs exactly this and quits with its code, which is how
## docs/92 section 10.4's "demonstrated in an exported build, not only in the
## editor" is satisfied for the parts that are checks rather than pictures.

const CORE_DIR: String = "res://core"
const GAME_DIR: String = "res://game"

const SUITES: Array[String] = [
	"res://tests/test_int_ops.gd",
	"res://tests/test_rng.gd",
	"res://tests/test_move_map_ref.gd",
	"res://tests/test_move_map_native.gd",
	"res://tests/test_move_map_slice.gd",
	"res://tests/test_allowance.gd",
	"res://tests/test_render.gd",
	"res://tests/test_mesh.gd",
	"res://tests/test_camera.gd",
	"res://tests/test_isolation.gd",
	"res://tests/test_turn.gd",
	"res://tests/test_turn_native.gd",
	"res://tests/test_execute_move.gd",
	"res://tests/test_handover.gd",
	"res://tests/test_combat.gd",
	"res://tests/test_combat_native.gd",
	"res://tests/test_lcl.gd",
	"res://tests/test_ai.gd",
	"res://tests/test_journal.gd",
	"res://tests/test_charisma.gd",
	"res://tests/test_sound.gd",
	"res://tests/test_blob.gd",
	"res://tests/test_blob_native.gd",
	"res://tests/test_presentation_native.gd",
	"res://tests/test_ctrl_map.gd",
	"res://tests/test_effects.gd",
	"res://tests/test_mission.gd",
	"res://tests/test_campaign.gd",
	"res://tests/test_game_ui.gd",
	"res://tests/test_hud.gd",
	"res://tests/test_shell.gd",
	"res://tests/test_save.gd",
	"res://tests/test_cache.gd",
	"res://tests/test_agent.gd",
	"res://tests/test_warnings_gate.gd",
]


## Returns the process exit code.
static func run_all() -> int:
	var h: TestHarness = begin_run()
	for path: String in SUITES:
		run_suite(h, path)
	return finish_run(h)


## The three pieces `run_all` is made of, so a caller that owns a frame can put
## one suite between two of them.  The exported build does: the whole run
## inside `_ready` is a black window for the length of it, which reads as a
## hang (`game/main.gd`, [method SliceMain._run_tests_and_quit]).
static func suite_count() -> int:
	return SUITES.size()


## What a caller with a window puts on it beside the count: a suite blocks the
## main thread for its whole length, so a number alone stops moving and reads
## as a hang all over again.
static func suite_name(index: int) -> String:
	if index < 0 or index >= SUITES.size():
		return ""
	return SUITES[index].get_file().get_basename().trim_prefix("test_")


static func run_suite_at(h: TestHarness, index: int) -> void:
	if index < 0 or index >= SUITES.size():
		return
	run_suite(h, SUITES[index])


static func begin_run() -> TestHarness:
	var h: TestHarness = TestHarness.new()
	print("Incubation - Remake -- headless tests")
	print("")
	check_scripts_load(h, "core_loads", CORE_DIR, 10)
	check_scripts_load(h, "game_loads", GAME_DIR, 6)
	return h


static func run_suite(h: TestHarness, path: String) -> void:
	if not ResourceLoader.exists(path):
		# **Not a skip.**  A renamed file or a typo in SUITES used to print
		# one informational line, drop that suite's checks and still exit
		# 0 -- the same shape of silent shrinkage a stale fixture caused.
		h.begin(path.get_file(), TestHarness.ORACLE_SPEC)
		h.check("suite_present", false, "%s is not in this build" % path)
		return
	var script: GDScript = ResourceLoader.load(path, "GDScript") as GDScript
	if script == null or not script.can_instantiate():
		h.begin(path.get_file(), TestHarness.ORACLE_SPEC)
		h.check("script_loads", false,
			"script failed to parse -- typed-warning error or syntax error")
		return
	var instance: Object = script.new()
	var suite: TestSuite = instance as TestSuite
	if suite == null:
		h.begin(path.get_file(), TestHarness.ORACLE_SPEC)
		h.check("extends_test_suite", false, "not a TestSuite")
		return
	suite.run(h)


static func finish_run(h: TestHarness) -> int:
	h.expect_suite_count(SUITES.size() + 2)
	return h.finish()


## Every script in a directory must load.  A typed-warning error stops a script
## from loading rather than from running, so without this the suites that do not
## touch a broken file would still report success -- which is how a
## warnings-as-errors gate quietly stops being a gate.  `game/` is included
## because nothing else here instantiates it.
static func check_scripts_load(h: TestHarness, suite: String,
		directory: String, least: int) -> void:
	h.begin(suite, TestHarness.ORACLE_SPEC)
	var dir: DirAccess = DirAccess.open(directory)
	if dir == null:
		h.check("directory", false, "cannot open " + directory)
		return
	var names: PackedStringArray = _scripts_in(dir, directory)
	names.sort()
	var count: int = 0
	for path: String in names:
		# An exported build stores a script under its compiled name; the
		# `.gd` path still resolves through the remap, so that is what is
		# loaded either way.
		count += 1
		var script: GDScript = ResourceLoader.load(path, "GDScript") as GDScript
		h.check(path.get_file(), script != null and script.can_instantiate(),
			"failed to parse -- a typed-warning error or a syntax error")
	h.check("count", count >= least,
		"%d scripts under %s" % [count, directory])


## Every `.gd` under a directory, **including its subdirectories**.
##
## `core/lcl/` is one, and a scan that stopped at the top level would leave a
## broken file in it loading nowhere and failing nothing -- the exact shape of
## silent shrinkage the warnings gate exists to prevent.
static func _scripts_in(dir: DirAccess, directory: String
		) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for name: String in dir.get_files():
		if name.ends_with(".gd") or name.ends_with(".gdc"):
			out.append(directory + "/" + name.get_basename() + ".gd")
	for sub: String in dir.get_directories():
		var child: DirAccess = DirAccess.open(directory + "/" + sub)
		if child != null:
			out.append_array(_scripts_in(child, directory + "/" + sub))
	return out
