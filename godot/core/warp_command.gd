class_name WarpCommand
extends RefCounted

## "Jump this unit to that cell" -- the Jet Pack's move (docs/23 section
## 7.5), `aExecuteWarp` `0x0046EF50` under the pad arm at `0x00472F10`. The
## cell must be one the movement query marked [constant
## MoveMapResult.STATE_WARP]; the fill is the gate, as it is for a walk.

var unit_slot: int = -1
var x: int = 0
var y: int = 0


static func create(slot: int, to_x: int, to_y: int) -> WarpCommand:
	var command: WarpCommand = WarpCommand.new()
	command.unit_slot = slot
	command.x = to_x
	command.y = to_y
	return command
