class_name BgbEmitters
extends RefCounted

## `CreateBGB`'s twenty slots and the per-frame half that drives them --
## docs/20 section 7.3 for the command, docs/28 section 8.2 for the two
## switches.
##
## **This is the only effect a script places by itself.** Everything else in
## the pool is put there by a weapon, a death or a set piece; `CreateBGB` is a
## line in `INIT MAP` that says *there is a fire burning at this spot for the
## whole mission*. The shipped corpus has fourteen calls, and the two that
## matter here are the campaign maps' own: `_C_XXX.lcl` and `_C_YYY.lcl` each
## light four buildings and start a CD track, and that is the whole of their
## `InitMap`.
##
## The registration table is `0x004FE408`: twenty 28-byte records, `type` at
## `+0x00`, the position at `+0x04/08/0C` **shifted left by four** by the
## command wrapper, the countdown at `+0x10`, the reload `live` at `+0x11` and
## the gate's span `random` at `+0x12`.

## `0x0041E1B1` -- `cmp al, 20`, and the id a command outside it is refused
## with *"invalid bgbcreator id"*.
const SLOTS: int = 20
## docs/20 section 7.4: the command shifts the three coordinates left by four
## before it stores them, so a script's 5905 is 94480 world units.
const COORD_SHIFT: int = 4
## An empty slot. `type` 0 is an error at registration and skipped by the
## sweep.
const TYPE_NONE: int = 0
## The two types the tick drives. Types 2..6 create their object **once**, at
## registration, and are not made here -- see [member unmade].
const TYPE_SMOKE: int = 1
const TYPE_FIRE: int = 7
## `0x0041E239` -- a countdown of 255 is never decremented; it gates instead.
const HELD: int = 0xFF

## The animation level (`Game.opt` +0x20, docs/20 section 8.2) at which
## `0x0041E1A0` returns before it does anything.
##
## The tick opens `call 0x004604D0 / cmp eax, 1 / jne body`, and the
## fall-through is a bare `pop esi; ret` -- so **level 1 turns the emitters
## off** and every other value leaves them on. The shipped default is 2 and
## the accelerated renderer forces 2, so the fires burn in both. The sense is
## the easy half to get backwards, which is why `blob_tables.py` pins the
## jump's target and not only the comparison.
const LEVEL_OFF: int = 1
const LEVEL_DEFAULT: int = 2

## The creator each driven type calls, by address, as [BlobPrograms] names
## them. `TYPE_SMOKE`'s `aBlob_CreateSmoke2` `0x0042A5E0` is **not**
## transcribed: both shipped calls that ask for it are commented out in their
## own scripts, so nothing reaches it and a program written for it would be
## checked by nothing.
const CREATORS: Dictionary[int, String] = {
	TYPE_FIRE: BlobPrograms.MAIN_MAP_FIRE,
}


## One registered emitter -- the engine's 28-byte record, minus the sound
## handle at `+0x14` that only the teardown touches.
class Slot:
	var type_id: int = TYPE_NONE
	var x: int = 0
	var y: int = 0
	var z: int = 0
	var countdown: int = 0
	var live: int = 0
	var random: int = 0
	var gamma: int = 0


## The animation level this is running under, so the gate is a value and not
## an assumption. The remake has no control for it and no reason to invent
## one, so it stays at the shipped default.
var level: int = LEVEL_DEFAULT
## How many spawn requests were made for a type this file does not carry a
## creator for, by type. Counted rather than dropped: docs/92 section 7.1 --
## an effect that silently does nothing is the defect, not the absence.
var unmade: Dictionary[int, int] = {}

var _slots: Array[Slot] = []


static func create() -> BgbEmitters:
	var out: BgbEmitters = BgbEmitters.new()
	for _i: int in range(SLOTS):
		out._slots.append(Slot.new())
	return out


## `aEnterBGBCreator` `0x0041DF10`. Answers false for an id outside the table
## or a type of 0, which are the routine's own two refusals.
func register(id: int, type_id: int, x: int, y: int, z: int,
		live: int, random: int, gamma: int) -> bool:
	if id < 0 or id >= SLOTS or type_id == TYPE_NONE:
		return false
	var slot: Slot = _slots[id]
	slot.type_id = type_id
	slot.x = x << COORD_SHIFT
	slot.y = y << COORD_SHIFT
	slot.z = z << COORD_SHIFT
	# `live` reaches both the countdown and the reload, so a fresh emitter
	# spawns on its first tick rather than waiting for the gate.
	slot.countdown = live & 0xFF
	slot.live = live & 0xFF
	slot.random = random & 0xFF
	slot.gamma = gamma
	return true


## Take one `create_bgb` event straight off a script's outcome.
##
## The interpreter records the eight arguments in the command's own order
## (`core/lcl/lcl_interpreter.gd`), so this is the seam between the script and
## the pool and the only place that order is written down twice.
func register_event(numbers: PackedInt32Array) -> bool:
	if numbers.size() < 8:
		return false
	return register(numbers[0], numbers[1], numbers[2], numbers[3],
		numbers[4], numbers[5], numbers[6], numbers[7])


func clear() -> void:
	for slot: Slot in _slots:
		slot.type_id = TYPE_NONE
	unmade.clear()


func live_slots() -> int:
	var count: int = 0
	for slot: Slot in _slots:
		if slot.type_id != TYPE_NONE:
			count += 1
	return count


## The record at *id*, for a suite that wants to see what a script registered.
func slot(id: int) -> Slot:
	return _slots[id] if id >= 0 and id < SLOTS else null


## One frame of `0x0041E1A0`, over every registered slot. Returns how many
## creators were run.
##
## The cadence, which docs/28 section 8.2 only summarised: a running countdown
## spawns **every** tick and decrements; at zero the gate draws
## `aRandom2(0, random)` and lets the burst start again only on a zero, so an
## emitter is `live` frames of flame and then, on average, `random` frames of
## nothing. A `random` of zero reloads unconditionally, which is a flame that
## never stops.
func tick(pool: BlobPool, hooks: GameBlobHooks) -> int:
	if level == LEVEL_OFF or pool == null or hooks == null:
		return 0
	var made: int = 0
	for id: int in range(SLOTS):
		var slot: Slot = _slots[id]
		if slot.type_id == TYPE_NONE:
			continue
		if slot.countdown == 0 or slot.countdown == HELD:
			if slot.random != 0 and (hooks.random(0, slot.random) & 0xFF) != 0:
				continue
			slot.countdown = slot.live
		if slot.countdown != HELD:
			slot.countdown = (slot.countdown - 1) & 0xFF
		if not CREATORS.has(slot.type_id):
			unmade[slot.type_id] = unmade.get(slot.type_id, 0) + 1
			continue
		var creator: int = CREATORS[slot.type_id].hex_to_int()
		if hooks.emit(creator, [slot.x, slot.y, slot.z]):
			made += 1
	return made
