class_name AudioTables
extends RefCounted

## What to play, and how loud -- `tables/sound.json`, and the two formulas.
##
## Nothing here is re-derived. `tools/inclib/sound.py` is the executable model
## of docs/28 sections 1 to 5 and `tools/blob_tables.py --check` compares it,
## field by field, against the tables it read out of `Incubation.exe`: the
## twenty-slot bound, the four attenuation constants, the 103 `SetVolumeCtrl`
## percentages, all 62 call sites and their partition into remake events, the
## nine looping play sites, the eight footstep arms, the two voice cursors and
## the rule that a weapon's fire sound is scaled by the weapon's own id. The
## converter copies the result. This class looks the answer up, and
## `tests/test_sound.gd` replays the same trace through it.
##
## **Case was resolved at conversion time, once.** Every wave the document
## names is already lower case and is the name of a file in `audio/waves/`, so
## the ten shipped names whose case does not match what the code asks for
## (docs/28 section 2.2) cannot fail on a case-sensitive filesystem. Nothing
## here searches.
##
## **This file touches no audio server.** The pool's bookkeeping is
## [AudioPool], the decisions are [AudioEvents], and the one class that opens a
## stream is [AudioSystem]. That split is what lets the layer be tested
## headless, which is where all of its rules actually live.

## `-1` as a volume-control id means "no scaling": the base volume passes
## through untouched. Any other id selects a percentage.
const NO_SCALING: int = -1
## DirectSound works in hundredths of a decibel; Godot's `volume_db` is in
## decibels. This is the whole of the conversion.
const HUNDREDTHS_PER_DB: float = 100.0
## What [method scaled_volume] answers for an id the table does not define.
## The load path refuses such a sound outright (`invalid volume ctrl id`), so
## the caller drops it; the value exists so the function stays total.
const REFUSED: int = -10000

var _document: Dictionary = {}
var _cache_dir: String = ""
var _volumes: Dictionary[int, int] = {}
var _footstep_by_type: Dictionary[int, Dictionary] = {}
var _base_floor: int = -2000
var _silence: int = -10000
var _offset: int = -2000
var _per_percent: int = 20
var _ceiling: int = 0
var _load_id_max: int = 119
var _set_id_max: int = 120
var _play_slots: int = 20


## Open the sound document a published cache carries.
static func open(cache_dir: String) -> AudioTables:
	return from_document(
		CacheLoader.read_json(cache_dir + "/tables/sound.json"), cache_dir)


## The same, from a document already in memory -- what the suite replays.
static func from_document(document: Dictionary,
		cache_dir: String = "") -> AudioTables:
	var tables: AudioTables = AudioTables.new()
	tables._document = document
	tables._cache_dir = cache_dir
	for key: Variant in DictRead.as_dict(document.get("volumes", {})):
		var id_text: String = DictRead.as_string(key)
		tables._volumes[id_text.to_int()] = DictRead.as_int(
			DictRead.as_dict(document["volumes"])[key])
	var attenuation: Dictionary = DictRead.as_dict(
		document.get("attenuation", {}))
	if not attenuation.is_empty():
		tables._base_floor = DictRead.as_int(attenuation["base_floor"])
		tables._silence = DictRead.as_int(attenuation["silence"])
		tables._offset = DictRead.as_int(attenuation["offset"])
		tables._per_percent = DictRead.as_int(attenuation["per_percent"])
		tables._ceiling = DictRead.as_int(attenuation["ceiling"])
		tables._load_id_max = DictRead.as_int(attenuation["load_id_max"])
		tables._set_id_max = DictRead.as_int(attenuation["set_id_max"])
	tables._play_slots = DictRead.as_int(document.get("play_slots", 20))
	for entry: Variant in DictRead.as_array(document.get("footsteps", [])):
		var arm: Dictionary = DictRead.as_dict(entry)
		for unit_type: Variant in DictRead.as_array(arm["types"]):
			tables._footstep_by_type[DictRead.as_int(unit_type)] = arm
	return tables


func is_loaded() -> bool:
	return not _document.is_empty()


func cache_dir() -> String:
	return _cache_dir


func play_slots() -> int:
	return _play_slots


# --- section 1.3: the exact attenuation ------------------------------------

## `0x00437480`, verbatim.
##
## A base volume below the floor is silence whatever the percentage; otherwise
## the percentage costs 0.2 dB a point below 100 and the result is clipped at
## zero -- which is why id 102's 101 % does nothing at all. It is a typo in
## `Info.lcl`, not a boost, and reproducing the clip is what makes that true
## here as well.
func attenuation(base_volume: int, percent: int) -> int:
	if base_volume < _base_floor:
		return _silence
	return mini(base_volume + _per_percent * percent + _offset, _ceiling)


## Whether the **load** path would accept this id. The setter and the scaler
## accept one more (0..120 against 0..119) and the difference is reproduced,
## because it is the difference between a sound that plays and one refused.
func load_id_valid(volume_id: int) -> bool:
	return volume_id == NO_SCALING or (volume_id >= 0
		and volume_id <= _load_id_max)


func set_id_valid(volume_id: int) -> bool:
	return volume_id == NO_SCALING or (volume_id >= 0
		and volume_id <= _set_id_max)


func has_volume_id(volume_id: int) -> bool:
	return volume_id == NO_SCALING or _volumes.has(volume_id)


func volume_percent(volume_id: int) -> int:
	return _volumes.get(volume_id, 100)


func volume_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in _volumes:
		out.append(id)
	out.sort()
	return out


## The volume a slot is loaded at, in hundredths of a decibel.
func scaled_volume(base_volume: int, volume_id: int) -> int:
	if volume_id == NO_SCALING:
		return base_volume
	if not load_id_valid(volume_id) or not _volumes.has(volume_id):
		return REFUSED
	return attenuation(base_volume, _volumes[volume_id])


static func volume_db(hundredths: int) -> float:
	return float(hundredths) / HUNDREDTHS_PER_DB


# --- section 2: the event table --------------------------------------------

## The cues one remake event starts, in the order the original loads them.
## Each is `{"wave": String, "volume_id": int, "loop": bool, "site": String}`.
func cues(event: String) -> Array:
	return DictRead.as_array(
		DictRead.as_dict(_document.get("events", {})).get(event, []))


func has_event(event: String) -> bool:
	return DictRead.as_dict(_document.get("events", {})).has(event)


func event_names() -> Array:
	var names: Array = DictRead.as_dict(_document.get("events", {})).keys()
	names.sort()
	return names


# --- section 3: the weapon's own fire sound --------------------------------

## `{"wave": String, "volume_id": int}`, or an empty dictionary when the name
## resolves to nothing.
##
## With `faithful` set -- the default, and what the `Faithful` preset means --
## weapon 35 comes back empty, because `Info.lcl` spells its file with a zero
## for the letter O and patches a record no `SetWeaponInfo` ever created
## (docs/28 section 3.1). Clearing the flag uses the corrected name.
func weapon_fire(weapon_id: int, faithful: bool = true) -> Dictionary:
	var row: Dictionary = DictRead.as_dict(
		DictRead.as_dict(_document.get("weapons", {})).get(str(weapon_id), {}))
	if row.is_empty():
		return {}
	var key: String = "wave" if faithful else "corrected"
	var wave: Variant = row.get(key)
	if wave == null:
		# The correction only exists for the one defective row; every other
		# weapon's `corrected` is its ordinary name, so falling back here is
		# not a second policy, it is the same one.
		wave = row.get("wave")
	if wave == null:
		return {}
	return {"wave": DictRead.as_string(wave), "volume_id": weapon_id}


func weapon_missing_sound() -> int:
	return DictRead.as_int(_document.get("weapon_missing_sound", 35))


# --- section 2.4: the watched player's screen -------------------------------

## The bar's own tick, the one of the screen's two waves a remake reaches.
const VIEW_PLAYER_PROGRESS: String = "progress"
## The network game's "it is your turn" alert. Named so the cache's own key is
## not a literal at the two places that read it; nothing plays it.
const VIEW_PLAYER_ALARM: String = "alarm"

## The cue one of `aViewPlayer.cpp`'s own buffers makes, or an empty dictionary
## when the cache is older than the closure that copies them.
##
## Neither wave goes through the volume table: the original plays them with
## `aDirectSoundPlay` and a bare zero, so their id is [constant NO_SCALING].
## `"progress"` is the turn bar's tick (docs/43 section 7.1); `"alarm"` is the
## network game's "it is your turn" alert and nothing in the remake reaches it.
func view_player_cue(name: String) -> Dictionary:
	var row: Dictionary = DictRead.as_dict(
		DictRead.as_dict(_document.get("view_player", {})).get(name, {}))
	if row.is_empty():
		return {}
	return {"wave": DictRead.as_string(row["wave"]),
		"volume_id": DictRead.as_int(row["volume_id"]), "loop": false}


# --- section 5: footsteps ---------------------------------------------------

## `{"wave": String, "volume_id": int, "period": int}` for a unit type that
## makes a walking sound, or an empty dictionary for the 39 that do not.
##
## Unit type 24 is scaled by volume id 45 -- a weapon-band id one bit away from
## the 91 its twin uses, so it walks at 100 % where the twin walks at 50 %.
## Reproduced by default; `faithful = false` gives it 91.
## What the step-period global holds before any arm has written it: zero, from
## the zero-filled tail of `.data`. See [method AudioEvents.footstep].
## The compatibility flag names the converter declared, in its order.
## [AudioEvents] compares them against the ones this build carries.
func compat_flags() -> Array:
	return DictRead.as_array(_document.get("compat_flags", [])).duplicate()


func footstep_period_initial() -> int:
	return DictRead.as_int(_document.get("footstep_period_initial", 0))


func footstep(unit_type: int, faithful: bool = true) -> Dictionary:
	var arm: Dictionary = _footstep_by_type.get(unit_type, {})
	if arm.is_empty() or arm["wave"] == null:
		return {}
	var volume_id: int = DictRead.as_int(arm["volume_id"])
	var fix: Dictionary = DictRead.as_dict(_document.get("footstep_fix", {}))
	if not faithful and not fix.is_empty() \
			and unit_type == DictRead.as_int(fix["type"]):
		volume_id = DictRead.as_int(fix["corrected"])
	return {"wave": DictRead.as_string(arm["wave"]), "volume_id": volume_id,
		"period": DictRead.as_int(arm["period"])}


# --- sections 2.3 and 8.1: the named outcome sets ---------------------------

## `jammed`, `damaged` or `destroyed` -- the three ways a weapon at its heat cap
## can end. `explosion.wav` is the one that removes the carrier from the map;
## `explosion2.wav` is a thrower's impact and is a different event entirely.
func overheat_cue(outcome: String) -> Dictionary:
	return DictRead.as_dict(
		DictRead.as_dict(_document.get("overheat", {})).get(outcome, {}))


## `ricochet`, `explosion2` or `aexplosion` -- the third weapon switch's three
## audible outcomes. Which one a weapon selects is [AudioEvents]'s to look up.
func impact_cue(name: String) -> Dictionary:
	return DictRead.as_dict(
		DictRead.as_dict(_document.get("impact", {})).get(name, {}))


# --- section 4.1: the voices ------------------------------------------------

func voices() -> Dictionary:
	return DictRead.as_dict(_document.get("voices", {}))


# --- files ------------------------------------------------------------------

## Where a named wave is, in the cache. The name is already the file name.
func wave_path(wave: String) -> String:
	return "%s/audio/waves/%s" % [_cache_dir, wave]


func music_path(track: int) -> String:
	return "%s/audio/music/%d.ogg" % [_cache_dir, track]


## The playlist a mission's `CDTrackProgram` names, as track numbers in order.
func playlist(mission: String) -> PackedInt32Array:
	var lists: Dictionary = DictRead.as_dict(_document.get("playlists", {}))
	if not lists.has(mission):
		return PackedInt32Array()
	return DictRead.to_int32(lists[mission])


## The tracks the cache actually carries. Empty after a `--no-music` run, and
## a caller has to cope: a mission with no music is quieter, not broken.
func tracks() -> PackedInt32Array:
	return DictRead.to_int32(_document.get("tracks", []))


func music_converted() -> bool:
	return DictRead.as_bool(_document.get("music_converted", false))


## `CDTrackProgram`'s argument is a dot-separated list of track numbers, and a
## malformed entry costs one track rather than the playlist.
static func parse_playlist(program: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for part: String in program.split(".", false):
		var text: String = part.strip_edges()
		# Digits only, not `is_valid_int()`: that accepts a sign, and the
		# Python twin's `str.isdigit()` does not. A track number is never
		# negative, so the two would only ever differ on malformed input --
		# which is exactly where a silent divergence would hide.
		if not text.is_empty() and _is_digits(text):
			out.append(text.to_int())
	return out


static func _is_digits(text: String) -> bool:
	for index: int in range(text.length()):
		var code: int = text.unicode_at(index)
		if code < 0x30 or code > 0x39:
			return false
	return true
