class_name MoveCommand
extends RefCounted

## "Walk this unit to that cell."
##
## The sibling [MoveQueryCommand] promised: the query highlights, this one
## commits. The target must be a cell the query marked -- the world re-fills
## and re-walks rather than trusting a stale overlay, which is the mistake the
## native capture's per-probe re-fill exists to avoid.

var unit_slot: int = -1
var x: int = 0
var y: int = 0


static func create(slot: int, tx: int, ty: int) -> MoveCommand:
	var command: MoveCommand = MoveCommand.new()
	command.unit_slot = slot
	command.x = tx
	command.y = ty
	return command
