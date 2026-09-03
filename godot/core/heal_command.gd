class_name HealCommand
extends RefCounted

## "Use this unit's medic kit" -- docs/29 section 1.1's button 2, the heal
## command `0x00470890` under the pad arm at `0x004733BB`. The kit is not
## consumed; the press costs one movement point when it healed something and
## marks the unit as acted either way (docs/97 section 31).

var unit_slot: int = -1


static func create(slot: int) -> HealCommand:
	var command: HealCommand = HealCommand.new()
	command.unit_slot = slot
	return command
