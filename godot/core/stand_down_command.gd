class_name StandDownCommand
extends RefCounted

## "This unit is finished for the turn" -- the **Def** pad's neighbour,
## docs/25 section 8.
##
## Not the same as running out of movement points. Standing down *deliberately*
## is worth one extra point of fitness at the next refresh and sets `+0x57`,
## which docs/10 section 5.5's formula turns into one extra movement point --
## so a turn spent doing nothing is worth more than a turn spent nearly doing
## something.

var unit_slot: int = -1


static func create(slot: int) -> StandDownCommand:
	var command: StandDownCommand = StandDownCommand.new()
	command.unit_slot = slot
	return command
