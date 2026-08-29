extends TestSuite

## Oracle boundary: executable Python (`tools/inclib/movemap.py`).
##
## The synthetic cases are the branches no shipped map can reach: the transient
## obstacle byte is 255 in all 184162 shipped cells, no shipped cell is a Ladder
## or an Enormous Obs, and Debris, Poison and Teleporter Entry between them
## cover 225 cells in the whole corpus.  They also pin the two behaviours that
## look like defects -- the rewrite of a cell reached with zero movement points
## left, and the 3x3 clearance a large unit needs for every step.

func run(h: TestHarness) -> void:
	h.begin("move_map_ref", TestHarness.ORACLE_PYTHON)
	var document: Dictionary = MoveMapCaseRunner.load_cases("synthetic")
	if document.is_empty():
		h.check("fixture", false,
			"run tools/movemap_runtime.py --emit-cases godot/generated/movemap")
		return
	var ran: int = MoveMapCaseRunner.run_all(h, document)
	h.check("count", ran >= 15, "%d synthetic cases" % ran)
