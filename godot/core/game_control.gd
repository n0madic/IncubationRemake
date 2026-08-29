class_name GameControl
extends RefCounted

## The twelve int32s at `0x00509F18` -- docs/20 section 7's game-control slots.
##
## `SetGameControl`, `IncGameControl` and `GameControlCmpNum` all address this
## one array, and a slot outside 0..11 makes the call a **no-op** rather than
## an error, which is the engine's own behaviour and not a leniency invented
## here.
##
## Only seven of the twelve are read anywhere in the binary, and this class
## does not pretend otherwise: [method mission_ended] looks at 0..4 and the two
## payout slots have accessors.  The other five are carried verbatim because a
## mission script may write them and a save has to round-trip what it wrote.

const SLOTS: int = 12
## docs/20 section 7 -- 0..3 are the human players' end-of-game state and 4 is
## the computer's.  The hand-over's short-circuit OR runs over all five.
const END_STATE_SLOTS: int = 5
## docs/20 section 7 -- the equipment-point bonus and the commendations, both
## paid out by the campaign layer, which this slice does not have.
const SLOT_EQUIPMENT_POINTS: int = 10
const SLOT_COMMENDATIONS: int = 11

var _slots: PackedInt32Array = PackedInt32Array()


static func create() -> GameControl:
	var control: GameControl = GameControl.new()
	control._slots.resize(SLOTS)
	return control


static func from_array(values: PackedInt32Array) -> GameControl:
	var control: GameControl = GameControl.create()
	for i: int in range(mini(values.size(), SLOTS)):
		control._slots[i] = values[i]
	return control


func get_slot(slot: int) -> int:
	if slot < 0 or slot >= SLOTS:
		return 0
	return _slots[slot]


## `0x0043B180`. Out of range is a no-op, not an error.
func set_slot(slot: int, value: int) -> void:
	if slot < 0 or slot >= SLOTS:
		return
	_slots[slot] = value


## `0x0043B1A0` -- an add, despite the name.
func increment(slot: int, delta: int) -> void:
	if slot < 0 or slot >= SLOTS:
		return
	_slots[slot] += delta


## `0x0047D88B`..`0x0047D8C3` -- the short-circuit OR the hand-over gates on.
## Any of slots 0..4 being non-zero ends the mission for **every** human
## player, and the grades are then put back per player from their own slot.
func mission_ended() -> bool:
	for slot: int in range(END_STATE_SLOTS):
		if _slots[slot] != 0:
			return true
	return false


func values() -> PackedInt32Array:
	return _slots.duplicate()


func clone() -> GameControl:
	return GameControl.from_array(_slots)


func hash_into(ctx: HashingContext) -> void:
	ctx.update(_slots.to_byte_array())
