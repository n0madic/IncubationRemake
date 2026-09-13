class_name SpeechPlayer
extends RefCounted

## Unit speech -- `aUnitMap.cpp`'s `fcn.0047B660`, docs/28 section 4.3.
##
## The original builds `Waves\Speech\<dir>\<prefix><category><index>.wav` out of
## three things: the unit's own speech id (`unit[+0x55]`, which the `.lev` and
## the campaign roster both carry), a **category** the calling event picks, and
## an **index** that is either a walked cursor or a draw. It then asks the
## filesystem, and a name that never shipped is silence rather than an error --
## which is not an edge case: every one of the four drawing arms can produce
## one, so a healthy marine says nothing to two selections in six.
##
## Two things this class owns because they are state and not a table:
##
## * **the cursors.** Four globals, and arguments 2 and 7 share one, so the two
##   sequences interleave exactly the way the two pain cursors of section 4.1
##   do. Keyed by the cursor's own address, which is what makes the sharing a
##   property of the cache rather than of this file.
## * **which draw.** The index comes from `aRandom2` `0x004638E0` -- the
##   presentation generator of docs/22 section 3.2, seeded from `GetTickCount`
##   -- and never from the simulation's `aRandom`. A line that moved
##   [member World.rng] would move the canonical hash, so this holds its own.
##
## One voice at a time: `0x0047B6F2` kills whatever the buffer holds before the
## next name is even built, so a second unit cuts the first one off.

var _tables: AudioTables = null
var _rng: IncRandom = IncRandom.new()
## Cursor address -> the value it now holds.
var _cursors: Dictionary[String, int] = {}


func setup(tables: AudioTables) -> void:
	_tables = tables
	_rng.randomize_seed(float(Time.get_ticks_msec()))


## Seed the index generator, so a suite can replay a measured sequence.
func seed_indices(value: float) -> void:
	_rng.randomize_seed(value)


func cursor(address: String) -> int:
	return _cursors.get(address, 0)


## The cue *unit* makes for *event*, or an empty dictionary for silence.
##
## *player* is the seat the speech is allowed for: `0x0047B6DF` compares the
## unit's owner with the current player and returns when they differ, so a
## replayed computer turn never speaks with the human's voice.
func line(event: String, unit: Dictionary, player: int) -> Dictionary:
	if _tables == null or unit.is_empty():
		return {}
	var owner: int = DictRead.as_int(unit["player"])
	if owner != player or owner == _tables.speech_unowned():
		return {}
	if DictRead.as_int(unit["type_id"]) == _tables.speech_mute_type():
		return {}
	var argument: int = _argument(event, unit)
	if argument < 0:
		return {}
	var pair: Vector2i = _numbers(argument)
	var set_id: int = DictRead.as_int(unit["speech"])
	var random: Dictionary = _tables.speech_random()
	if set_id == DictRead.as_int(random["set"]):
		# `0x0047BAD5`: the arm tests the id *after* the name has been built
		# and replaces both numbers, so the caller's category is thrown away.
		var draw: PackedInt32Array = random["draw"]
		pair = Vector2i(DictRead.as_int(random["category"]),
			_rng.draw(draw[0], draw[1]))
	var wave: String = _tables.speech_wave(set_id, pair.x, pair.y)
	if wave.is_empty():
		return {}
	return {"wave": wave, "volume_id": _tables.speech_volume_id(),
		"loop": false, AudioTables.CHANNEL_KEY: AudioTables.CHANNEL_SPEECH}


## Which of the event's arguments this unit's condition picks.
##
## Only `select` has two: `unit[+0x16] >= 3 and unit[+0x19] >= 3` is the first
## and anything below either is the second, so a hurt or exhausted marine
## answers out of a different category.
func _argument(event: String, unit: Dictionary) -> int:
	var arguments: PackedInt32Array = _tables.speech_arguments(event)
	if arguments.is_empty():
		return -1
	if arguments.size() == 1:
		return arguments[0]
	var threshold: int = _tables.speech_hurt_threshold()
	if DictRead.as_int(unit["hp"]) >= threshold \
			and DictRead.as_int(unit["fp"]) >= threshold:
		return arguments[0]
	return arguments[1]


## `(category, index)` for one argument, walking or drawing as its arm says.
func _numbers(argument: int) -> Vector2i:
	var arm: Dictionary = _tables.speech_arm(argument)
	if arm.is_empty():
		# The switch's own default: `0000`, which names no shipped file in any
		# set but the drawing one.
		return Vector2i.ZERO
	var category: int = DictRead.as_int(arm["category"])
	var draw: PackedInt32Array = DictRead.to_int32(arm.get("draw", []))
	if not draw.is_empty():
		return Vector2i(category, _rng.draw(draw[0], draw[1]))
	var address: String = DictRead.as_string(arm.get("cursor", ""))
	if address.is_empty():
		return Vector2i(category, 0)
	var modulus: int = DictRead.as_int(arm.get("modulus", 0))
	var value: int = cursor(address)
	# `cmp [cursor], N / jne`: the walked value is the index, and `N` wraps it
	# back to zero rather than `N + 1` -- so the sequence is `1 .. N, 0`.
	value = 0 if value == modulus else value + 1
	_cursors[address] = value
	return Vector2i(category, value)
