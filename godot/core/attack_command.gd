class_name AttackCommand
extends RefCounted

## "Fire this unit's weapon at that cell."
##
## The aim point is a **cell**, not a unit: `aAttackUnit` takes coordinates, and
## if a unit happens to stand there the aim point becomes that unit's own cell.
## Passing a slot instead would lose splash at an empty cell, which is how a
## grenade is thrown.

var unit_slot: int = -1
var x: int = 0
var y: int = 0


static func create(slot: int, tx: int, ty: int) -> AttackCommand:
	var command: AttackCommand = AttackCommand.new()
	command.unit_slot = slot
	command.x = tx
	command.y = ty
	return command
