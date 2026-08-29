class_name SpendStimulantCommand
extends RefCounted

## "Use this unit's stimulant" -- docs/25 section 8.
##
## **Not consumed: a once-a-turn button.** `+0x58` holds 1 for a *Light
## Stimulant* and 2 for a *Heavy* one, spending it writes **255** -- "spent this
## turn" -- and the hand-over's refresh turns 255 back into the original charge.
## A remake that decremented the field would give each unit one stimulant per
## mission instead of one per turn.

var unit_slot: int = -1


static func create(slot: int) -> SpendStimulantCommand:
	var command: SpendStimulantCommand = SpendStimulantCommand.new()
	command.unit_slot = slot
	return command
