class_name DefendCommand
extends RefCounted

## "Put this unit on overwatch" -- the **Def** button, docs/25 section 6.
##
## Pressing it twice is not a no-op: `0x00478500` zeroes the remaining movement
## points of a unit that was already waiting, so the command is submitted again
## and the world says what it cost.

var unit_slot: int = -1


static func create(slot: int) -> DefendCommand:
	var command: DefendCommand = DefendCommand.new()
	command.unit_slot = slot
	return command
