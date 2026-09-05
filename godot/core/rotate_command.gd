class_name RotateCommand
extends RefCounted

## "Face this way" -- the direction ring's letter, docs/43 section 4.
##
## `aChangeUnitViewDirection` (`0x004792A0`) writes `unit[+0x46]` and turns
## the placed object; it charges no movement point and rebuilds no
## visibility. The ring hands it the facing after a move, after a warp, or on
## its own when the selected unit was clicked a second time.

var unit_slot: int = -1
var facing: int = 0


static func create(slot: int, direction: int) -> RotateCommand:
	var command: RotateCommand = RotateCommand.new()
	command.unit_slot = slot
	command.facing = direction
	return command
