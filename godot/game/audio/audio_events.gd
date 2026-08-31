class_name AudioEvents
extends RefCounted

## What the remake's own events sound like.
##
## docs/28 section 8 is the structural fact this whole file rests on: *effects
## are not driven by the simulation, they are driven by the animation
## routines, and the simulation only calls those.* `core` therefore emits no
## sound and knows about none; it records what happened, and this class turns
## a record into the cues the original's routine would have loaded.
##
## **Three sources, not one.** A mission script's set pieces arrive as event
## dictionaries; the computer's turn arrives as [AIEvent] dictionaries of its
## own; and the player's own commands arrive as results. The last is not a
## refinement -- `Interact.toggle_door` writes the state change and returns,
## and only the LCL `OpenDoor` path records an event, so a router that read
## events alone would give the computer's doors a sound and the player's
## silence. That is the most-demonstrated sound in this slice, so the seam is
## in the signature rather than bolted on later.
##
## Every answer is a cue: `{"wave": String, "volume_id": int, "loop": bool}`.
## An empty array means the original loads nothing there, which is a real and
## common answer -- most of the melee weapons make no impact sound at all.

## `core`'s event kinds that name a sound event of the same meaning under a
## different name. Everything not listed is looked up as itself, so this table
## holds only the genuine renames and stays short enough to read.
const EVENT_ALIASES: Dictionary[String, String] = {
	# `Statue2` is the batch form of `Statue` -- docs/20 section 7.4: it walks
	# the cell array and runs the same `0x00413a40` sequence per cell.
	"statue2": "statue",
	# `MoveFireCircles` runs `0x004131c0`, the sequence `FireCircle` itself
	# calls; `MoveSpores` runs `0x004147d0`, the one `Spores` calls.
	"move_fire_circles": "fire_circle",
	"move_spores": "move_spores",
	# `FixedStatue`'s routine is `0x00414000`, which docs/28 lists separately
	# from the rotating statue's.
	"fixed_statue_kill": "fixed_statue",
	# The barrier toggles; both directions run `aPlayLaserBarrier`.
	"barrier_on": "barrier",
	"barrier_off": "barrier",
	# `ParaBombs` runs the bomber fly-past and **then** the bomb, so one event
	# owns two routines. This alias reaches only the fly-past.
	# TODO: the set-piece driver must ask for "bomber" and then "para_bomb"
	# as two phases; until it does, `crush.wav` @89 is not played.
	"para_bombs": "bomber",
	# The computer's own names for the same two things.
	"parabomb": "bomber",
	"warp": "warp",
}

## `Combat`'s overheat outcome names against the three
## `aPlayWeaponExplosionAnimation` arms. `cleared` and `none` are silent: the
## weapon survived, and the routine is only ever reached from the three that
## did not (docs/28 section 2.3).
const OVERHEAT_CUES: Dictionary[String, String] = {
	"jam": "jammed",
	"damage": "damaged",
	"destroyed": "destroyed",
}

const SPECIES_HUMAN: int = 0
const SPECIES_ALIEN: int = 1

## docs/28 section 3.1 -- `SetWeaponInfo2` names `W_BAY0_0.wav` for weapon 35
## and no such file ships, so that weapon fires silently. Reproduced by default.
const COMPAT_WEAPON_35: String = "weapon_35_missing_sound"
## docs/28 section 5 -- unit type 24 walks at volume id 45, a weapon-band id one
## bit away from the 91 its twin uses, so it walks twice as loud. Reproduced by
## default.
const COMPAT_FOOTSTEP_24: String = "unit_24_footstep_volume_original"
## The two, in the order the cache document declares them.
const COMPAT_FLAGS: Array[String] = [COMPAT_WEAPON_35, COMPAT_FOOTSTEP_24]

var _tables: AudioTables = null
var _blobs: Dictionary = {}
## Whether every compatibility flag is on. A convenience over [member _compat],
## not a second source of truth: see [method is_faithful].
var _faithful: bool = true
## docs/92 section 7.1's stable flag names -> whether each is on.
##
## **The names are spelled out, not implied by a boolean.** An earlier draft
## carried only `_faithful`, so §7.1's "every compatibility choice gets a
## stable named flag" was satisfied on the Python side and nowhere here -- and
## `tools/blob_tables.py` now checks that these two strings appear in this
## directory, because a rename on one side alone gives the player a preset that
## toggles nothing.
var _compat: Dictionary[String, bool] = {}
## The two cursors of docs/28 section 4.1, one per species, each advancing
## 0 -> 1 -> 2 -> 0 on every use. `SP_HUM_*` shares the human one, which is
## why the two human sets interleave rather than running independently.
var _cursors: Dictionary[int, int] = {SPECIES_HUMAN: 0, SPECIES_ALIEN: 0}
## Fixed unconditionally, with no setting: scaling the alien scream by the
## human ids leaves an "alien voices" control doing nothing, which docs/92
## section 7.1 classes as a defect in the remake's own interface rather than a
## period detail.
var _fix_alien_volume: bool = true
## The single global of docs/28 section 5, zero until an arm writes it.
var _walk_period: int = 0


static func open(tables: AudioTables, blobs: Dictionary,
		faithful: bool = true) -> AudioEvents:
	var events: AudioEvents = AudioEvents.new()
	events._tables = tables
	events._blobs = blobs
	events._faithful = faithful
	for flag: String in COMPAT_FLAGS:
		events._compat[flag] = faithful
	events._walk_period = tables.footstep_period_initial()
	return events


func tables() -> AudioTables:
	return _tables


## True while **every** flag is on, which is the default and the shipped
## behaviour. Reads [member _compat] rather than the constructor's argument, so
## turning one flag off answers false.
func is_faithful() -> bool:
	for flag: String in COMPAT_FLAGS:
		if not compat(flag):
			return false
	return true


## Whether one named compatibility flag is on. An unknown name is **false**:
## a preset naming a flag this build does not have must not silently behave as
## though it were set.
func compat(flag: String) -> bool:
	return DictRead.as_bool(_compat.get(flag, false))


## Turn one named flag on or off. Answers false for a name this build does not
## carry, so a caller can report it rather than assume it took.
func set_compat(flag: String, on: bool) -> bool:
	if not COMPAT_FLAGS.has(flag):
		return false
	_compat[flag] = on
	_faithful = is_faithful()
	return true


## The flags the **cache document** declares, which is what the Python side
## emitted. Any name here that this build does not carry is a version skew the
## caller should see rather than a flag that quietly does nothing.
func unknown_compat_flags() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for entry: Variant in _tables.compat_flags():
		var name: String = DictRead.as_string(entry)
		if not COMPAT_FLAGS.has(name):
			out.append(name)
	return out


# --- events ----------------------------------------------------------------

## The cues one `core` event dictionary starts.
##
## **The two event streams spell the key differently** and both are `core`'s:
## a mission script's events are `{"name": ..., "values": [...]}`
## ([method LclInterpreter._event]) and the computer's are `{"kind": ...}`
## ([AIEvent]). Reading only one of them was a real bug in an earlier draft of
## this file -- every set-piece sound was silently missing, and nothing said
## so, because "this event names no cue" is a legitimate answer.
static func name_of(event: Dictionary) -> String:
	if event.has("name"):
		return DictRead.as_string(event["name"])
	return DictRead.as_string(event.get("kind", ""))


## One entry of an event stream as `{"name": String, "values": Array}`.
##
## **Three shapes reach this, all of them `core`'s.** A mission script's events
## are held as dictionaries and **serialised as `[name, values]` pairs**
## ([method LclOutcome.to_dict], so that the document matches
## `inclib.lcl_runtime`'s); the computer's are `{"kind": ...}`. Reading a pair
## as a dictionary yields an empty name and no cue, which is a silent and
## perfectly plausible answer -- so the normalisation happens here, once, and
## a check covers all three spellings.
static func as_event(entry: Variant) -> Dictionary:
	if typeof(entry) == TYPE_ARRAY:
		var pair: Array = DictRead.as_array(entry)
		if pair.is_empty():
			return {}
		return {"name": DictRead.as_string(pair[0]),
			"values": DictRead.as_array(pair[1]).duplicate()
				if pair.size() > 1 else []}
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	var event: Dictionary = DictRead.as_dict(entry)
	return {"name": name_of(event),
		"values": DictRead.as_array(event.get("values", [])).duplicate()}


func for_event(event: Dictionary) -> Array[Dictionary]:
	return for_event_kind(name_of(event))


func for_event_kind(kind: String) -> Array[Dictionary]:
	var name: String = EVENT_ALIASES.get(kind, kind)
	var out: Array[Dictionary] = []
	for entry: Variant in _tables.cues(name):
		out.append(_cue(DictRead.as_dict(entry)))
	return out


## The cues one of the player's own `Use` commands starts.
##
## `aExecuteUse`'s switch is docs/26 section 3, and only three of its arms make
## a sound of their own: the door, the lever and the supply box. The rest are
## silent in the original too -- a refused use makes no noise at all, which is
## the difference between a quiet interface and a broken one.
func for_use(result: UseResult) -> Array[Dictionary]:
	if result == null or not result.ok:
		return []
	match result.kind:
		"door":
			return for_event_kind("open_door")
		"lever":
			return for_event_kind("lever")
		"full_munition", "equipment_points", "weapon_skills", "condition", \
		"technical", "equipment", "class":
			return for_event_kind("pickup")
		"entry_point":
			return for_event_kind("destroy_entrypoint")
		"defuse_mine":
			return for_event_kind("destroy_mine")
		_:
			return []


## The cues one shot starts: the weapon's own fire sound, then the impact
## sound its id selects, then the overheat outcome if the weapon came apart.
##
## Order matters and is the routine's: `aPlayFightAnimation` loads the fire
## sound first (`0x0040C7C4`), the impact second, and the overheat trio is a
## different routine entirely, reached from `aCheckWeaponDamage`.
func for_attack(result: AttackResult, weapon_id: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if result == null or not result.fired:
		return out
	var fire: Dictionary = weapon_fire(weapon_id)
	if not fire.is_empty():
		out.append(fire)
	var impact: Dictionary = impact_for_weapon(weapon_id)
	if not impact.is_empty():
		out.append(impact)
	var overheat: Dictionary = overheat_cue(result.overheat)
	if not overheat.is_empty():
		out.append(overheat)
	return out


# --- section 3: the weapon's own fire sound --------------------------------

func weapon_fire(weapon_id: int) -> Dictionary:
	var row: Dictionary = _tables.weapon_fire(weapon_id,
		compat(COMPAT_WEAPON_35))
	if row.is_empty():
		return {}
	return {"wave": DictRead.as_string(row["wave"]),
		"volume_id": DictRead.as_int(row["volume_id"]), "loop": false}


# --- section 8.1: the impact sound the third switch selects ----------------

## The wave a weapon's impact makes, from `tables/blobs.json`'s transcription
## of the switch at `0x0040E4C8`. Seventeen of the 45 ids it covers select one
## of three waves and the rest select silence, which is a real answer.
func impact_for_weapon(weapon_id: int) -> Dictionary:
	var switch: Dictionary = DictRead.as_dict(
		_blobs.get("weapon_impact_sound", {}))
	var entry: Variant = switch.get(str(weapon_id))
	if entry == null:
		return {}
	var wave: String = DictRead.as_string(entry)
	for name: Variant in DictRead.as_dict(_tables_impacts()):
		var cue: Dictionary = _tables.impact_cue(DictRead.as_string(name))
		if not cue.is_empty() and DictRead.as_string(cue["wave"]) == wave:
			return _cue(cue)
	return {}


func _tables_impacts() -> Dictionary:
	return {"ricochet": true, "explosion2": true, "aexplosion": true}


# --- section 2.3: the overheat trio ----------------------------------------

func overheat_cue(outcome: String) -> Dictionary:
	if not OVERHEAT_CUES.has(outcome):
		return {}
	var cue: Dictionary = _tables.overheat_cue(OVERHEAT_CUES[outcome])
	return {} if cue.is_empty() else _cue(cue)


# --- section 4.1: the pain voice -------------------------------------------

## The scream a unit of `species` makes, or an empty dictionary -- species 0
## and 1 have three variants each and every other species is silent.
##
## The cursor advances on **every** use, including the ones whose wave is
## never played, because the original advances it in the same place.
func pain(species: int) -> Dictionary:
	var voices: Dictionary = _tables.voices()
	if voices.is_empty():
		return {}
	var key: String = "human" if species == SPECIES_HUMAN \
		else ("alien" if species == SPECIES_ALIEN else "")
	if key.is_empty():
		return {}
	var waves: Array = DictRead.as_array(voices[key])
	var modulus: int = DictRead.as_int(voices["cursor_modulus"])
	var cursor: int = _cursors[species]
	_cursors[species] = (cursor + 1) % modulus
	var ids: Array = DictRead.as_array(
		voices["alien_volume_ids"] if species == SPECIES_ALIEN
			and _fix_alien_volume else voices["volume_ids"])
	return {"wave": DictRead.as_string(waves[cursor]),
		"volume_id": DictRead.as_int(ids[cursor]), "loop": false}


## The second human set, `SP_HUM_*`, off the **human** cursor.
func second_human() -> Dictionary:
	var voices: Dictionary = _tables.voices()
	if voices.is_empty():
		return {}
	var waves: Array = DictRead.as_array(voices["second_human"])
	var ids: Array = DictRead.as_array(voices["second_human_volume_ids"])
	var modulus: int = DictRead.as_int(voices["cursor_modulus"])
	var cursor: int = _cursors[SPECIES_HUMAN]
	_cursors[SPECIES_HUMAN] = (cursor + 1) % modulus
	return {"wave": DictRead.as_string(waves[cursor]),
		"volume_id": DictRead.as_int(ids[cursor]), "loop": false}


func cursor(species: int) -> int:
	return _cursors.get(species, 0)


func reset_cursors() -> void:
	_cursors[SPECIES_HUMAN] = 0
	_cursors[SPECIES_ALIEN] = 0


# --- section 5: footsteps ---------------------------------------------------

## `{"wave", "volume_id", "loop", "period"}` for a walking unit type, or an
## empty dictionary for the 39 types that walk silently.
##
## The period is in frames and is the one piece of this layer `core` cannot
## supply: it hands over a whole path at once, while a step is 2 to 8 frames
## apart. The walk phase is the body's, so the caller is [UnitsView].
##
## **The period is one global and this call writes it** (docs/28 section 5).
## Six of the seven sounding arms of `aStartWalkAnimationSound` store an
## immediate into `0x004FAECC`; the `msqueether` arm -- unit type 54 -- writes
## its wave and its volume id and leaves the period alone, so a Squeether walks
## at whatever the last walker set. The address is past the end of `.data`'s
## raw bytes, in the tail the loader zero-fills, so before anything has walked
## the period is **zero** and a Squeether's step never repeats. All of that is
## reproduced rather than smoothed over, which is why this method is not a
## pure function of its argument.
func footstep(unit_type: int) -> Dictionary:
	var row: Dictionary = _tables.footstep(unit_type,
		compat(COMPAT_FOOTSTEP_24))
	if row.is_empty():
		return {}
	var period: int = DictRead.as_int(row["period"])
	if period > 0:
		_walk_period = period
	return {"wave": DictRead.as_string(row["wave"]),
		"volume_id": DictRead.as_int(row["volume_id"]), "loop": false,
		"period": _walk_period}


## The step period currently in force, for a caller that wants to read it
## without starting a walk.
func walk_period() -> int:
	return _walk_period


func _cue(entry: Dictionary) -> Dictionary:
	return {"wave": DictRead.as_string(entry["wave"]),
		"volume_id": DictRead.as_int(entry["volume_id"]),
		"loop": DictRead.as_bool(entry.get("loop", false))}
