extends SceneTree

## Headless test runner for development.
##
##     bash godot/run_tests.sh
##
## Godot exits 0 even when the main script fails to load, so this owns the exit
## code and prints TestHarness.SENTINEL_OK as its last line.  Treat a run
## without that sentinel as a failure regardless of the process exit status.
## The same suites run inside the exported build; see [TestRunner].

func _initialize() -> void:
	quit(TestRunner.run_all())
