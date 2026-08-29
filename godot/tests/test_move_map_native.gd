extends TestSuite

## Oracle boundary: **native runtime**.  `aBuildMoveMap` (`0x00430A40`) called
## inside a running `Incubation.exe` on `_C_141`, loaded from save slot 6.
##
## The strongest evidence this repository can produce, and the only check whose
## oracle is the shipped engine.  Sixty fills, 28 of the mission as it loads and
## 32 with a field written into the live process -- movement points, a Jet Pack,
## a type's `special`, a cell's obstacle byte -- so that the warp pass, both
## refusals and all three transient obstacles are covered natively rather than
## only synthetically.
##
## See `tests/fixtures/movemap/README.md` for how the capture is taken and what
## it corrected in the specs.

func run(h: TestHarness) -> void:
	h.begin("move_map_native", TestHarness.ORACLE_NATIVE)
	var document: Dictionary = MoveMapCaseRunner.load_cases("native")
	if document.is_empty():
		h.check("fixture", false,
			"run tools/movemap_gold.py --game-copy ... then --emit-cases")
		return
	h.equal("oracle", DictRead.as_string(document["oracle"]),
		TestHarness.ORACLE_NATIVE)
	var ran: int = MoveMapCaseRunner.run_all(h, document)
	h.check("count", ran >= 28, "%d native fills" % ran)
