class_name IdleScheduler
extends RefCounted

## `0x004060B0` for the four slots the 3D-view refresh runs it on (docs/42
## section 6): the idle is a **scheduler**, not a loop.
##
## Every displayed frame, for slots 1, 2, 4 and 5: a slot whose countdown is
## positive counts down and does nothing else; otherwise it frees whatever it
## held, picks a unit -- `aRandom2(0, 200)` as a unit index, one draw -- and
## requires it alive, unflagged (`+0x4F == 0`), not already animating
## (`+0x56 == 0`), with an idle clip the selector names and a model on its
## object; then starts the clip at speed 1.5 and sets the countdown to its
## length in frames. So at most four units idle at once, chosen at random;
## each plays once, in two thirds of the countdown, and holds its last frame
## for the rest. Measured in `tools/presentation_gold.py`'s `idle_random` and
## `idle_pose` phases, replayed by `tests/test_presentation_native.gd`.
##
## **The type argument is dead.** The search that should find the first live
## unit of the asked type reads unit 0's type once and compares that same byte
## two hundred times (`0x0040616C`), so it matches only when unit 0 is of the
## asked type -- and then takes unit 0 with **no draw** -- and otherwise falls
## through to the draw. The one shipped use, slot 1 asking for the boss (type
## 61) in `_C_118`, works because that mission's unit 0 *is* the boss.
##
## The draws come from the caller's [IncRandom] -- the pool's, which is the
## `aRandom2` stream the creators and the fight's coin share in the engine --
## never from [member World.rng]. Everything the guards read comes through
## callables, so a suite can drive the slots from a fixture's records.

## The slots the refresh runs, in its order.
const SLOTS: Array[int] = [1, 2, 4, 5]
## `aRandom2(0, 200)` -- the unit array's 200 records.
const UNIT_DRAW_SPAN: int = 200
## The type argument every slot passes except the one below.
const NO_TYPE: int = -1
## `push 0x3D` in the refresh for slot 1, in the one mission whose name it
## compares against (`0x004C0470`).
const BOSS_MISSION: String = "_C_118"
const BOSS_TYPE: int = 61
const BOSS_SLOT: int = 1
## The guards' answers, in the order `0x004060B0` applies them; `""` takes.
const REFUSED_NO_RECORD: String = "no record"
const REFUSED_DEAD: String = "dead"
const REFUSED_HIDDEN: String = "+0x4F"
const REFUSED_ANIMATING: String = "+0x56"
const REFUSED_SELECTOR: String = "selector"
const REFUSED_NO_MODEL: String = "no model"

## `Game.opt + 0x20` (docs/20 section 9) -- the *Cursor and animation level*
## option: at 1 the starter returns at once. The remake's setting, named.
var enabled: bool = true
## Per slot: the unit it holds (`-1` for none) and the frames left.
var entries: Dictionary[int, Dictionary] = {}
## Per slot: the type asked for.
var asked: Dictionary[int, int] = {}
## Counters, for a suite.
var ticks: int = 0
var draws: int = 0
var misses: int = 0
var starts: int = 0
var frees: int = 0
## What the last call of each slot drew, or `-1` for a countdown tick.
var last_drawn: Dictionary[int, int] = {}


func _init() -> void:
	for slot: int in SLOTS:
		entries[slot] = {"unit": -1, "countdown": 0}
		asked[slot] = NO_TYPE
		last_drawn[slot] = -1


## The one mission whose slot 1 asks for a type.
func ask_for_mission(mission: String) -> void:
	asked[BOSS_SLOT] = BOSS_TYPE if mission == BOSS_MISSION else NO_TYPE


## One displayed frame of the refresh: every slot in turn.
##
## `refuses(unit) -> String` answers the guard that refuses a unit or `""`;
## `start(unit) -> float` starts its idle and answers the clip's length;
## `free(unit)` detaches the clip a slot held. `unit0_type` is the type byte
## the dead search compares.
func tick(rng: IncRandom, unit0_type: int, refuses: Callable, start: Callable,
		free: Callable) -> void:
	if not enabled:
		return
	ticks += 1
	for slot: int in SLOTS:
		tick_slot(slot, rng, unit0_type, refuses, start, free)


## One slot's starter call, `0x004060B0(slot, type)`.
func tick_slot(slot: int, rng: IncRandom, unit0_type: int, refuses: Callable,
		start: Callable, free: Callable) -> void:
	last_drawn[slot] = -1
	var entry: Dictionary = entries[slot]
	var left: int = DictRead.as_int(entry["countdown"])
	if left > 0:
		entry["countdown"] = left - 1
		return
	var held_unit: int = DictRead.as_int(entry["unit"])
	if held_unit >= 0:
		free.call(held_unit)
		entry["unit"] = -1
		frees += 1
	var candidate: int = -1
	if asked[slot] != NO_TYPE and unit0_type == asked[slot]:
		candidate = 0
	else:
		candidate = rng.draw(0, UNIT_DRAW_SPAN)
		draws += 1
	last_drawn[slot] = candidate
	var why: String = refuses.call(candidate)
	if why != "":
		misses += 1
		return
	var length: float = start.call(candidate)
	entry["unit"] = candidate
	# The countdown is the length read back, as an integer of frames.
	entry["countdown"] = int(length)
	starts += 1


## The units the slots hold now, for a suite: never more than four.
func idling() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for slot: int in SLOTS:
		var unit: int = DictRead.as_int(entries[slot]["unit"])
		if unit >= 0:
			out.append(unit)
	return out


func countdown(slot: int) -> int:
	return DictRead.as_int(entries[slot]["countdown"])


func held(slot: int) -> int:
	return DictRead.as_int(entries[slot]["unit"])


## A slot as the engine left it, for a replay that starts mid-way.
func set_slot(slot: int, unit: int, frames: int) -> void:
	entries[slot] = {"unit": unit, "countdown": frames}
