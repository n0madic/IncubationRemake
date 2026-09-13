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
## Which base volume a cue is scaled from -- the `"channel"` key of a cue.
## Every cue rides the FX volume unless it says otherwise, and the one that
## says otherwise is unit speech: `0x0047B660` is the only reader of the
## options record's speech field (docs/20 section 8). A cue's `volume_id`
## cannot carry this, because [constant NO_SCALING] is shared with the ground
## unit's crush, the load screen's clicks and the view player's cues, all of
## which ride FX.
const CHANNEL_KEY: String = "channel"
const CHANNEL_FX: String = "fx"
const CHANNEL_SPEECH: String = "speech"

var _document: Dictionary = {}
var _paths: CachePaths = null
## The `Track` family's tracks the cache carries -- `audio/music/track/`, the
## cutscenes' 9..19 (docs/92 section 7.19). Empty after `--no-music`.
var _track_family: PackedInt32Array = PackedInt32Array()
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
##
## The two tables are neutral; *paths* decides per wave whether the chosen
## language's pack supplies it -- the 1C release dubbed 227 of the 332 waves
## and every briefing voice-over -- while the music stays the base's.
static func open(paths: CachePaths) -> AudioTables:
	var tables: AudioTables = from_document(
		CacheLoader.read_json(paths.neutral_path("tables/sound.json")), paths)
	# The cutscene tracks are the front end's document's, not the missions'.
	var frontend: Dictionary = CacheLoader.read_json(
		paths.neutral_path("tables/frontend.json"))
	tables._track_family = DictRead.to_int32(
		frontend.get("track_family_tracks", []))
	return tables


## The same, from a document already in memory -- what the suite replays.
static func from_document(document: Dictionary,
		paths: CachePaths = null) -> AudioTables:
	var tables: AudioTables = AudioTables.new()
	tables._document = document
	tables._paths = paths
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
	return _paths.cache_dir if _paths != null else ""


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
	if _paths == null:
		return "/audio/waves/%s" % wave
	return _paths.path("audio/waves/%s" % wave)


## The `Arack` family the shipped build plays for the missions and the front
## end (docs/28 section 6.1), and the `Track` family the cutscenes name.
const FAMILY_ARACK: String = "arack"
const FAMILY_TRACK: String = "track"


func music_path(track: int, family: String = FAMILY_ARACK) -> String:
	if family == FAMILY_TRACK:
		return "%s/audio/music/track/%d.ogg" % [cache_dir(), track]
	return "%s/audio/music/%d.ogg" % [cache_dir(), track]


## The tracks one family carries.
func tracks_of(family: String) -> PackedInt32Array:
	if family == FAMILY_TRACK:
		return _track_family.duplicate()
	return tracks()


## A file the cache carries under `audio/`, by its cache-relative path -- the
## briefing voice-overs and the static extro's wave, which no table names.
func audio_path(relative: String) -> String:
	if _paths == null:
		return "/%s" % relative
	return _paths.path(relative)


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


## The separators `CDTrackProgram`'s parser (`0x0042C040`) hands `strtok`,
## read at `0x004C2768`: the missions write dots, the front end and the
## sequence player commas (docs/20 section 7.3, corrected 2026-09-08).
const PLAYLIST_SEPARATORS: String = " .,|;:*+/"


## `CDTrackProgram`'s argument is a list of track numbers, and a malformed
## entry costs one track rather than the playlist.
##
## A token past the disc -- the `30` every cutscene program ends with -- is
## kept as its number: [MusicPlayer] skips a track the cache does not carry,
## which is what the engine's wrap to the first entry amounts to.
static func parse_playlist(program: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	var parts: PackedStringArray = PackedStringArray()
	var token: String = ""
	for index: int in range(program.length()):
		var ch: String = program[index]
		if PLAYLIST_SEPARATORS.contains(ch):
			if not token.is_empty():
				parts.append(token)
			token = ""
		else:
			token += ch
	if not token.is_empty():
		parts.append(token)
	for part: String in parts:
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


# --- section 2.5: the mission interface's own clicks -------------------------

## The interface actions the original makes a noise for. Names, not addresses:
## the cache carries the wave each one reaches through the module global its
## handle lives in, and docs/28 section 2.5 is the join.
const INTERFACE_ORDER_MOVE: String = "order_move"
const INTERFACE_ORDER_WARP: String = "order_warp"
const INTERFACE_RESELECT: String = "reselect"
## The command pad's socket (`fcn.00471310`, past its executor) and the tick
## when the hovered socket changes (`fcn.004723E0`).
const INTERFACE_PAD_PRESS: String = "pad_press"
const INTERFACE_PAD_HOVER: String = "pad_hover"
const INTERFACE_HOVER_CELL: String = "hover_cell"
## The button columns' slot (`fcn.00450D70`, one with an event behind it) and
## the tick when the hovered slot changes to one with a sprite
## (`fcn.004518E0`). `aMI.cpp` is the mission's *map interface* module -- the
## columns, the radar and the view placers -- not a map that is clicked.
const INTERFACE_COLUMN_PRESS: String = "column_press"
const INTERFACE_COLUMN_HOVER: String = "column_hover"
## **The sound a selection makes.** `fcn.004533D0` re-applies the view on the
## new selection's cell and the placer plays `select.wav` from inside it, so
## the click a player hears when they pick a marine is the camera's. Which
## placer is the view mode's: `view_unit` is `fcn.004510A0` (mode 2, the
## *Set user view* button), `view_map` is `fcn.00450F60` (mode 4, the *Set
## free view* button, the mode-3+ re-apply and every placer's fallback with
## no selection). The eyes (`fcn.00451150`) and the overview
## (`fcn.00453410`) play nothing.
const INTERFACE_VIEW_MAP: String = "view_map"
const INTERFACE_VIEW_UNIT: String = "view_unit"
## The place interface (`aPI.cpp`, docs/43 section 5.5) plays from the same
## two buffers: a placement and a take-back from `[0x514068]`, which
## `aInitBattleGround` fills from `[0x4FE340]` -- `click_1.wav`, the
## hover-cell buffer -- and the band's cycling from `[0x51406C]`, filled
## from `[0x4FE344]` -- `click_2.wav`, the column press. Aliases, so a reader
## of the deployment code finds the join here rather than in docs/28.
const INTERFACE_DEPLOY_PLACE: String = INTERFACE_HOVER_CELL
const INTERFACE_DEPLOY_CYCLE: String = INTERFACE_COLUMN_PRESS

## The cue one interface action makes, or an empty dictionary when the cache
## predates docs/28 section 2.5.
func interface_cue(action: String) -> Dictionary:
	var row: Dictionary = DictRead.as_dict(
		DictRead.as_dict(_document.get("mission_interface", {})).get(action, {}))
	if row.is_empty():
		return {}
	return {"wave": DictRead.as_string(row["wave"]),
		"volume_id": DictRead.as_int(row["volume_id"]), "loop": false}


# --- section 4.3: unit speech ------------------------------------------------

## `-1`: speech is never scaled by the `SetVolumeCtrl` table, only by the
## options record's own speech field (docs/20 section 8).
func speech_volume_id() -> int:
	return DictRead.as_int(_speech().get("volume_id", NO_SCALING))


## The arguments one remake event pushes, in the order the original's branch
## takes them: for `select` the healthy one first and the hurt one second.
func speech_arguments(event: String) -> PackedInt32Array:
	var events: Dictionary = DictRead.as_dict(_speech().get("events", {}))
	if not events.has(event):
		return PackedInt32Array()
	return DictRead.to_int32(events[event])


## One arm of the ten-case switch: `{"category", "cursor", "modulus", "draw"}`.
## An argument the switch sends to its own default answers empty, which is the
## `0000` that names no shipped file.
func speech_arm(argument: int) -> Dictionary:
	return DictRead.as_dict(
		DictRead.as_dict(_speech().get("arms", {})).get(str(argument), {}))


## Hit points and fitness points at or above this are the healthy argument.
func speech_hurt_threshold() -> int:
	return DictRead.as_int(_speech().get("hurt_threshold", 3))


## The unit type `0x0047B872` refuses, and the owner `0x0047B868` refuses.
func speech_mute_type() -> int:
	return DictRead.as_int(_speech().get("mute_type", 0x14))


func speech_unowned() -> int:
	return DictRead.as_int(_speech().get("unowned", 0xFF))


## `{"set": int, "category": int, "draw": [base, span]}` -- the one set whose
## arm throws the caller's category away and draws its own index.
func speech_random() -> Dictionary:
	return {"set": DictRead.as_int(_speech().get("random_set", 12)),
		"category": DictRead.as_int(_speech().get("random_category", 0)),
		"draw": DictRead.to_int32(_speech().get("random_draw", [0, 5]))}


## The cache key of one speech file, or `""` when the tree has no such file.
##
## **A miss is silence and not an error**: `0x0047BB6E` asks the filesystem
## whether the name exists and returns when it does not, and every one of the
## four drawing arms can produce a name that never shipped.
func speech_wave(set_id: int, category: int, index: int) -> String:
	var sets: Dictionary = DictRead.as_dict(_speech().get("sets", {}))
	if not sets.has(str(set_id)):
		return ""
	var row: Dictionary = DictRead.as_dict(sets[str(set_id)])
	var name: String = "%s/%s%02d%02d.wav" % [
		DictRead.as_string(row["directory"]).to_lower(),
		DictRead.as_string(row["prefix"]).to_lower(), category, index]
	if not DictRead.as_dict(_speech().get("files", {})).has(name):
		return ""
	return "speech/%s" % name


func _speech() -> Dictionary:
	return DictRead.as_dict(_document.get("speech", {}))
