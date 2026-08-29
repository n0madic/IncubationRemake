class_name MoveQueryCommand
extends RefCounted

## "Select this unit and show me where it can go."
##
## docs/92 section 10.2 item 3 asks for a *command* to be submitted, not for two
## arguments to be passed, and that is the shape kept here: the next commands --
## a move, an attack, an end of turn -- arrive as siblings of this one rather
## than as more parameters on [method World.submit_move_query].

var unit_slot: int = -1
## docs/23 section 7.3 -- whether the fill may pass through units of the same
## player.  The corpus says this is **not** monotone in reachability: passing
## can reach an intermediate cell with zero movement points left where going
## around would have arrived with one, and a cell with zero cannot expand.
var pass_friendlies: bool = false


static func create(slot: int, pass_friendly: bool = false) -> MoveQueryCommand:
	var command: MoveQueryCommand = MoveQueryCommand.new()
	command.unit_slot = slot
	command.pass_friendlies = pass_friendly
	return command
