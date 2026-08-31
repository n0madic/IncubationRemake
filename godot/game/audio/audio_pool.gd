class_name AudioPool
extends RefCounted

## Twenty buffers, allocated low-first, and a sound that finds none is dropped.
##
## `aDSound.cpp` keeps a fixed array and its four routines do not agree on how
## many slots there are: the loader hands out 0..20, the play routine rejects
## anything above 19 with `invalid soundbufferid`. So the twenty-first buffer is
## allocated, filled, freed -- and never heard. docs/28 section 1.1's own advice
## is to size the pool at twenty, which turns an inaudible sound into a dropped
## one and leaves the audible result identical.
##
## **The cap is reproduced deliberately.** docs/28 section 10 item 1 leaves it
## open, and docs/92 section 7.1 decides it: a crowded turn dropping sounds is
## output the player perceives, so `Faithful` keeps it. Drops are counted, not
## raised -- the original's constructor returns `-1` and the caller carries on.
##
## This class is bookkeeping and holds no stream. [AudioSystem] owns the
## players and asks this which slot a sound may have, which is what lets the
## twenty-slot rule be replayed headless against the Python model.

## `{"in_use": bool, "path": String, "volume": int, "volume_id": int,
## "playing": bool, "looping": bool, "tag": String}`
var _slots: Array[Dictionary] = []
var _drops: int = 0


static func with_slots(count: int) -> AudioPool:
	var pool: AudioPool = AudioPool.new()
	pool._slots.resize(count)
	for index: int in range(count):
		pool._slots[index] = _free_slot()
	return pool


static func _free_slot() -> Dictionary:
	return {"in_use": false, "path": "", "volume": 0, "volume_id": -1,
		"playing": false, "looping": false, "tag": ""}


func size() -> int:
	return _slots.size()


func drops() -> int:
	return _drops


## Claim a slot for `path` at an already-scaled `volume`, or `-1` when every
## slot is taken. `tag` is the remake's own label for what asked -- an event
## name or a unit slot -- so a caller can find its own sounds again.
func load_wave(path: String, volume: int, volume_id: int,
		tag: String = "") -> int:
	for index: int in range(_slots.size()):
		if DictRead.as_bool(_slots[index]["in_use"]):
			continue
		_slots[index] = {"in_use": true, "path": path, "volume": volume,
			"volume_id": volume_id, "playing": false, "looping": false,
			"tag": tag}
		return index
	_drops += 1
	return -1


## `aAnimationSoundPlay`; the second argument is `DSBPLAY_LOOPING`.
func play(slot: int, loop: bool) -> bool:
	if not _holds(slot):
		return false
	_slots[slot]["playing"] = true
	_slots[slot]["looping"] = loop
	return true


## `aDirectSoundKillBuffer`; a killed slot is immediately reusable.
func kill(slot: int) -> bool:
	if not _holds(slot):
		return false
	_slots[slot] = _free_slot()
	return true


func _holds(slot: int) -> bool:
	return slot >= 0 and slot < _slots.size() and DictRead.as_bool(_slots[slot]["in_use"])


func slot(index: int) -> Dictionary:
	# A copy: a `Dictionary` returned from a function aliases the original in
	# Godot 4.7, exactly as a `Packed*Array` does, and a caller that wrote
	# through the handle would be writing into the pool.
	return _free_slot() if not _holds(index) else _slots[index].duplicate()


func live() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for index: int in range(_slots.size()):
		if DictRead.as_bool(_slots[index]["in_use"]):
			out.append(index)
	return out


func looping() -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for index: int in range(_slots.size()):
		if DictRead.as_bool(_slots[index]["in_use"]) and DictRead.as_bool(_slots[index]["looping"]):
			out.append(index)
	return out


## Every slot a given caller holds, by the tag it passed.
func tagged(tag: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for index: int in range(_slots.size()):
		if DictRead.as_bool(_slots[index]["in_use"]) and DictRead.as_string(_slots[index]["tag"]) == tag:
			out.append(index)
	return out


## End every looping buffer, and answer how many there were.
##
## This is what a skipped or finished sequence owes docs/28 section 1.4: **a
## sound's lifetime is its sequence's.** The nine looping sites are all
## machinery whose sequence outlasts its sample, so one left running is a stuck
## hum rather than a tail.
func kill_looping() -> int:
	var slots: PackedInt32Array = looping()
	for index: int in slots:
		kill(index)
	return slots.size()


## End every slot a caller holds -- the same rule, scoped to one sequence.
func kill_tagged(tag: String) -> int:
	var slots: PackedInt32Array = tagged(tag)
	for index: int in slots:
		kill(index)
	return slots.size()


func kill_all() -> int:
	var count: int = live().size()
	for index: int in range(_slots.size()):
		_slots[index] = _free_slot()
	return count
