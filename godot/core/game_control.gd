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


## docs/27 section 6.3 -- the five values `setMissionResult` takes.  1 is the
## reset value and means "nothing happened"; 2, 3 and 4 are the three win
## grades (+100/+200/+300); 5 is defeat (-100).
const RESULT_NOTHING: int = 1
const RESULT_WON: int = 2
const RESULT_WON_OUTSTANDING: int = 3
const RESULT_WON_GLORIOUS: int = 4
const RESULT_DEFEAT: int = 5


## What one player's mission result is, by `0x0047D600`'s own classification.
##
## The order is the part worth having: the OR chain over slots 0..4 stamps
## **5 on every human player** first, and only then does each player's own slot
## put 2/3/4 back.  So a mission that ends by *another* player's slot -- or by
## slot 4, the computer's -- leaves this player defeated, and an implementation
## that reads only its own slot and slot 4 gets that case wrong.
##
## `gc[i] > 3` is `error("unknown missionresult")` in the engine.  There is no
## error path here, and the 5 the OR chain already stamped is what stands:
## a slot the mission script set to something unaccounted for still ended the
## mission, and treating it as a win would be the worse guess.
func mission_result(player: int) -> int:
	if not mission_ended():
		return RESULT_NOTHING
	if player < 0 or player >= END_STATE_SLOTS - 1:
		return RESULT_DEFEAT
	match _slots[player]:
		1:
			return RESULT_WON
		2:
			return RESULT_WON_OUTSTANDING
		3:
			return RESULT_WON_GLORIOUS
	return RESULT_DEFEAT


## Whether the two payout slots are paid out to this player -- docs/27 section
## 6.2's `missionResult(player) != 5`.
##
## The other half of the engine's gate, `gameMode() == 1`, is the campaign
## layer and is out of this slice's scope (docs/27), so what is modelled here
## is the result test alone.
func pays_out(player: int) -> bool:
	return mission_result(player) != RESULT_DEFEAT


func values() -> PackedInt32Array:
	return _slots.duplicate()


func clone() -> GameControl:
	return GameControl.from_array(_slots)


## Write the twelve slots back in place; see [method IncRandom.restore].
func restore(values: PackedInt32Array) -> void:
	for i: int in range(SLOTS):
		_slots[i] = values[i] if i < values.size() else 0


func hash_into(ctx: HashingContext) -> void:
	ctx.update(_slots.to_byte_array())
