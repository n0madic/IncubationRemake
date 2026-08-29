extends TestSuite

## Oracle boundary: specification-only.  docs/92 section 10.4, last bullet.
##
## "Typed GDScript warnings selected for the core fail the build" is a claim
## about the project's settings, and a setting that is never exercised is a
## setting that can be lost in a merge.  So a deliberately violating script is
## kept under `tests/fixtures/violations/`, and this suite requires it **not**
## to load while its typed twin does.
##
## Two facts about Godot 4.7 shaped this, both established by running it:
## a warning at level 2 stops a script from *loading* rather than from running,
## and `load()` on a script that failed to parse still returns a non-null object
## -- so `can_instantiate()` is the test, not a null check.
##
## The engine also exits 0 when the main script fails to load, which is why
## `godot/run_tests.sh` gates on the harness sentinel and not on the exit code.

const VIOLATION: String = "res://tests/fixtures/violations/untyped_declaration.gd"
const TWIN: String = "res://tests/fixtures/violations/typed_twin.gd"
const EXPORT_PRESETS: String = "res://export_presets.cfg"

## The settings that have to be errors for the gate to mean anything.
const REQUIRED_ERRORS: Array[String] = [
	"debug/gdscript/warnings/untyped_declaration",
	"debug/gdscript/warnings/inference_on_variant",
	"debug/gdscript/warnings/unsafe_property_access",
	"debug/gdscript/warnings/unsafe_method_access",
	"debug/gdscript/warnings/unsafe_cast",
	"debug/gdscript/warnings/unsafe_call_argument",
]
const WARNING_LEVEL_ERROR: int = 2


func run(h: TestHarness) -> void:
	h.begin("warnings_gate", TestHarness.ORACLE_SPEC)

	h.check("settings.enabled",
		DictRead.as_bool(ProjectSettings.get_setting(
			"debug/gdscript/warnings/enable", false)),
		"GDScript warnings are on")
	for key: String in REQUIRED_ERRORS:
		h.equal("settings." + key.get_file(),
			DictRead.as_int(ProjectSettings.get_setting(key, 0)),
			WARNING_LEVEL_ERROR)

	h.check("violation.present", ResourceLoader.exists(VIOLATION),
		"the deliberately violating fixture is where it should be")
	var violation: GDScript = ResourceLoader.load(VIOLATION, "GDScript") \
		as GDScript
	h.check("violation.rejected",
		violation == null or not violation.can_instantiate(),
		"a script with an untyped declaration does not load")

	var twin: GDScript = ResourceLoader.load(TWIN, "GDScript") as GDScript
	h.check("twin.accepted", twin != null and twin.can_instantiate(),
		"its typed twin does load, so the rejection is the warning "
		+ "and not the directory")

	# Export output lives under res://export, so omitting this exclusion makes a
	# later build package resources from older .app bundles (and even itself).
	#
	# **The question has to be asked differently in an exported build.**
	# `export_presets.cfg` is an editor file and Godot never packages it, so
	# reading it there returns nothing and the `in` test is false -- which is
	# why this check failed in every exported build there has ever been, while
	# passing in the headless run beside it. In the pack the claim is about the
	# pack, so it is asked of the pack: a build that had consumed a prior
	# bundle would carry its resources under `res://export`.
	var presets: String = FileAccess.get_file_as_string(EXPORT_PRESETS)
	if presets.is_empty():
		h.check("export.excludes_output",
			not DirAccess.dir_exists_absolute("res://export"),
			"the pack carries no res://export -- asked of the build, because "
			+ "export_presets.cfg is not in it")
	else:
		h.check("export.excludes_output", "export/*" in presets,
			"shipping builds never consume prior export artifacts")
