class_name TestSuite
extends RefCounted

## Base class for a headless test file.  `run` calls `h.begin(...)` once with
## the suite's oracle boundary and then makes its checks.
func run(_h: TestHarness) -> void:
	push_error("TestSuite.run must be overridden")
