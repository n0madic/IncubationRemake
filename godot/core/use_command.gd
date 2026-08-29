class_name UseCommand
extends RefCounted

## "Use whatever this unit is facing."
##
## No target: docs/26 section 2 -- there is no reach and no selection, the whole
## input is the unit's facing byte. A command carrying coordinates would imply
## a choice the engine does not offer.

var unit_slot: int = -1


static func create(slot: int) -> UseCommand:
	var command: UseCommand = UseCommand.new()
	command.unit_slot = slot
	return command
