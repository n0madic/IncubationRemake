class_name ToggleWeaponCommand
extends RefCounted

## "Switch to this weapon's other firing mode" -- the pad's button 5, docs/29
## section 1.1 and docs/43 section 5.
##
## `aToggleWeaponModes` (`0x0047A8C0`) is `unit[+0x3F] = weapon[+0x3D]`: the
## toggle column is an involution (docs/25 section 7), so pressing it again
## goes back. It costs nothing; the refresh reverts the mode at the hand-over.

var unit_slot: int = -1


static func create(slot: int) -> ToggleWeaponCommand:
	var command: ToggleWeaponCommand = ToggleWeaponCommand.new()
	command.unit_slot = slot
	return command
