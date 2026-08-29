class_name EndTurnCommand
extends RefCounted

## "I am done; hand over."
##
## Carries `arg`, the engine's own second argument to `0x0047D600`: zero is an
## ordinary hand-over and non-zero is the first one of a mission, which searches
## from slot 0 rather than advancing.

var arg: int = 0


static func create(first: bool = false) -> EndTurnCommand:
	var command: EndTurnCommand = EndTurnCommand.new()
	command.arg = 1 if first else 0
	return command
