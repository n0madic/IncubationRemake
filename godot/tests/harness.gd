class_name TestHarness
extends RefCounted

## Minimal assert/report harness for the headless test runner.
##
## This is a deliberate deviation from docs/92 section 2, which named gdUnit4.
## gdUnit4 is a vendored third-party dependency in a repository whose stated
## discipline is zero third-party dependencies, and whose test suite is a set of
## `--check` CLIs.  Moving to gdUnit4 later is mechanical.
##
## Every test declares the oracle boundary its assertions reach, as
## docs/92 section 10.3 item 1 requires.  The boundary is printed with the
## result so a reader never has to infer it.

## docs/92 section 5 boundary names, strongest first.
const ORACLE_NATIVE: String = "native-runtime"
const ORACLE_PYTHON: String = "executable-Python"
const ORACLE_STATIC: String = "verified-static"
const ORACLE_SPEC: String = "specification-only"

## Printed as the last line of a successful run.  The shell wrapper looks for
## it, because Godot exits 0 even when the main script fails to load: an absent
## sentinel is the only way to tell a passing run from a run that never started.
const SENTINEL_OK: String = "HARNESS-RESULT: OK"
const SENTINEL_FAIL: String = "HARNESS-RESULT: FAILED"

## The fewest checks each suite must run.  A suite that ran **zero** checks
## already fails; this catches the other half of the same problem, which has
## bitten once: a stale case file shadowed a fresh one, the run silently lost
## fifty checks, and every suite still said "ok".  Raise a number here when a
## suite genuinely grows; never lower one to make a run pass.
const LEAST_CHECKS: Dictionary = {
	"core_loads": 34,
	"int_ops": 26,
	"rng": 11,
	"move_map_ref": 96,
	"move_map_native": 233,
	"move_map_slice": 55,
	"allowance": 43,
	"render": 17,
	"mesh": 44,
	"camera": 145,
	"isolation": 10,
	"turn": 60,
	"turn_native": 45,
	"execute_move": 65,
	"handover": 150,
	"combat": 185,
	"combat_native": 70,
	"lcl": 62,
	"charisma": 60,
	"sound": 35,
	"blob": 40,
	"blob_native": 6,
	"presentation_native": 150,
	"ctrl_map": 30,
	"effects": 250,
	"mission": 17,
	"game_ui": 110,
	"game_loads": 12,
	"save": 17,
	"cache": 10,
	"warnings_gate": 10,
}

var _suite: String = ""
var _boundary: String = ""
var _checks: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _total_checks: int = 0
var _total_failures: int = 0
var _suites: int = 0


func begin(suite: String, boundary: String) -> void:
	_flush()
	_suite = suite
	_boundary = boundary
	_checks = 0
	_failures = PackedStringArray()
	_suites += 1


func check(name: String, condition: bool, detail: String = "") -> bool:
	_checks += 1
	_total_checks += 1
	if not condition:
		_total_failures += 1
		var line: String = "    FAIL %s.%s" % [_suite, name]
		if detail != "":
			line += ": " + detail
		_failures.append(line)
	return condition


func equal(name: String, got: Variant, want: Variant, detail: String = "") -> bool:
	var ok: bool = _deep_equal(got, want)
	var text: String = detail
	if not ok:
		var g: String = _brief(got)
		var w: String = _brief(want)
		text = "got %s, want %s" % [g, w]
		if detail != "":
			text = detail + "; " + text
	return check(name, ok, text)


## Compares two integer arrays element by element and reports the first
## `max_report` mismatches, which is what makes a 990-cell move-map diff
## readable instead of a wall of numbers.
func equal_ints(name: String, got: PackedInt32Array, want: PackedInt32Array,
		max_report: int = 6) -> bool:
	if got.size() != want.size():
		return check(name, false, "size %d != %d" % [got.size(), want.size()])
	var bad: PackedStringArray = PackedStringArray()
	var n: int = 0
	for i: int in range(got.size()):
		if got[i] != want[i]:
			n += 1
			if bad.size() < max_report:
				bad.append("[%d] %d != %d" % [i, got[i], want[i]])
	return _report_diff(name, n, got.size(), bad, max_report)


func equal_bytes(name: String, got: PackedByteArray, want: PackedByteArray,
		max_report: int = 6) -> bool:
	if got.size() != want.size():
		return check(name, false, "size %d != %d" % [got.size(), want.size()])
	var bad: PackedStringArray = PackedStringArray()
	var n: int = 0
	for i: int in range(got.size()):
		if got[i] != want[i]:
			n += 1
			if bad.size() < max_report:
				bad.append("[%d] %d != %d" % [i, got[i], want[i]])
	return _report_diff(name, n, got.size(), bad, max_report)


func _report_diff(name: String, n: int, total: int, bad: PackedStringArray,
		max_report: int) -> bool:
	if n == 0:
		return check(name, true)
	var suffix: String = "" if n <= max_report else " (+%d more)" % (n - max_report)
	return check(name, false, "%d/%d differ: %s%s"
		% [n, total, ", ".join(bad), suffix])


func _flush() -> void:
	if _suite == "":
		return
	if _checks == 0:
		# A suite that examined nothing is not a suite that passed -- the same
		# rule every `--check` CLI in this repository follows.
		_total_failures += 1
		_failures.append("    FAIL %s: no checks ran" % _suite)
	elif LEAST_CHECKS.has(_suite) and _checks < DictRead.as_int(
			LEAST_CHECKS[_suite]):
		_total_failures += 1
		_failures.append("    FAIL %s: %d checks, at least %d expected"
			% [_suite, _checks, DictRead.as_int(LEAST_CHECKS[_suite])])
	var status: String = "ok" if _failures.is_empty() else "FAILED"
	print("  %-28s %3d checks  [%s]  %s" % [_suite, _checks, _boundary, status])
	for line: String in _failures:
		print(line)


## Fails the run if fewer suites reported than the runner intended to run.
## `check_scripts_load` adds two, and every entry of `SUITES` adds one whether
## it loaded or not -- so this catches a suite that vanished before it could
## even report a failure.
func expect_suite_count(expected: int) -> void:
	_flush()
	_suite = "suite_count"
	_boundary = ORACLE_SPEC
	_checks = 0
	_failures = PackedStringArray()
	var reported: int = _suites
	_suites += 1
	check("suites_ran", reported == expected,
		"%d suites reported, %d expected" % [reported, expected])


## Returns the process exit code: 0 when everything passed.
func finish() -> int:
	_flush()
	_suite = ""
	print("")
	print("%d suites, %d checks, %d failures"
		% [_suites, _total_checks, _total_failures])
	if _total_failures == 0 and _total_checks > 0:
		print(SENTINEL_OK)
		return 0
	if _total_checks == 0:
		print("no checks ran -- an empty run is not a passing run")
	print(SENTINEL_FAIL)
	return 1


func _deep_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	return a == b


func _brief(v: Variant) -> String:
	var s: String = str(v)
	if s.length() > 120:
		return s.substr(0, 117) + "..."
	return s
