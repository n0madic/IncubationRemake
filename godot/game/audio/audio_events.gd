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
	# `Statue2` used to alias `statue`, and must not: since docs/97 section
	# 41.1 the interpreter runs the sequence itself once per matched cell and
	# emits a `statue` event for each, so the batch marker aliasing the same
	# cues would play `stone.wav` once more than the engine does. It is silent
	# on purpose; the cells it swept make the noise.
	# `MoveFireCircles` runs `0x004131c0`, the sequence `FireCircle` itself
	# calls; `MoveSpores` runs `0x004147d0`, the one `Spores` calls.
	"move_fire_circles": "fire_circle",
	"move_spores": "move_spores",
	# `FixedStatue`'s routine is `0x00414000`, which docs/28 lists separately
	# from the rotating statue's. Its `fixed_statue` event names that routine
	# itself and plays whether or not the beam found anyone; the kill that
	# may follow is silent, as `statue_kill` is.
	# The barrier toggles and both directions enter `aPlayLaserBarrier`, but
	# only one reaches its play site: the off arm turns the emitter's part
	# and returns at `0x00413668`, before `lbarrier.wav` is made at
	# `0x0041379F`. `barrier_off` is silent on purpose.
	"barrier_on": "barrier",
	# `ParaBombs` is **not** here: one command owns two routines, which is
	# [constant EVENT_PHASES], not a rename. Neither is the computer's own
	# `parabomb`, for the opposite reason -- its fuse `0x0040B2D0` plays no
	# sound of its own at all; what is heard is the blast's, through the
	# weapon (see [constant EVENT_PHASES]).
	"warp": "warp",
}

## The events whose one command runs **two** routines in order, and those
## routines' own names.
##
## `ParaBombs` `0x00470790` runs the fly-past `0x00415E90` to completion and
## only then the bomb run `0x004160F0` (docs/20 section 7.4), and each is a
## blocking routine with a sound of its own -- `bomber.wav` @87 looping for
## the flight, `crush.wav` @89 for the bombs. An alias can name only one
## routine, so mapping the event to the fly-past left the second sound
## unplayed however carefully the driver staged the picture.
##
## The table is the **one** place that pairing is written down: the script's
## set piece stages the phases ([SetpieceCamera]) and the computer's replay
## plays them together, and both read it from here.
##
## The value type is a plain [Array] because a `PackedStringArray` is not a
## constant expression and the file would not parse; [method phases_of] is
## what hands out the packed form.
## **Only the script command is here** (2026-09-05). The computer's own
## `parabomb` event was too, on the reading that its fuse ran the same two
## routines; `aAI_SpecialPlayerControl` `0x0040B2D0` calls `aExecuteBomb`
## `0x004702C0` and `aRemoveUnitElement` `0x004779C0` and nothing else, so a
## fuse that runs out is one blast with the bomb weapon's own cues, and the
## fly-past is the script's alone.
const EVENT_PHASES: Dictionary[String, Array] = {
	"para_bombs": ["bomber", "para_bomb"],
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
## docs/21 section 2 -- species 3, whose death is `explosion.wav`.
const SPECIES_MACHINE: int = 3

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


## Every cue an event starts, in the order its routines run.
##
## A phased event answers **all** of its phases, which is the right answer for
## a caller that cannot stage them -- the computer's replay plays the pair at
## once -- and the wrong one for a caller that can. [method for_event_phase]
## is what a driver that stages them asks instead.
func for_event_kind(kind: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for name: String in phases_of(kind):
		out.append_array(_routine_cues(name))
	return out


## The routines one event's command runs, in order. An event that is not
## phased answers its own single routine, so a caller can walk the phases of
## anything without asking whether it has more than one.
static func phases_of(kind: String) -> PackedStringArray:
	if EVENT_PHASES.has(kind):
		return PackedStringArray(EVENT_PHASES[kind])
	var name: String = EVENT_ALIASES.get(kind, kind)
	return PackedStringArray([name])


## The cues of one phase of an event, counted from zero. A phase this event
## does not have is **empty**, not an error: a driver that stages two phases
## of a one-phase event queues the second one silent.
func for_event_phase(kind: String, phase: int) -> Array[Dictionary]:
	var names: PackedStringArray = phases_of(kind)
	if phase < 0 or phase >= names.size():
		return []
	return _routine_cues(names[phase])


## The cues one docs/28 routine loads, by the name the catalogue files it
## under.
func _routine_cues(name: String) -> Array[Dictionary]:
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
		"technical", "equipment", "class", "message_only":
			# **`message_only` too.** Action points 11 and 41 touch nothing,
			# but they reach `0x00410780` like the other eleven pickups, and
			# `box.wav` is that routine's own sound (`0x0041093C`). Only the
			# *voice* line is missing from 11, and that is a different
			# routine (`0x0047B660`, [method InfoText.speaks]).
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


## `0x0040CBE2`..`0x0040CBEC` -- `cmp al, 0x16 / je`, `cmp al, 0x18 / jbe`,
## `cmp al, 0x1A / ja`: unit types 22, 25 and 26 make no sound when they are
## hit or killed (docs/42 section 4.5).
const MUTE_TYPES: Array[int] = [0x16, 0x19, 0x1A]

# --- section 4.1: the pain voice -------------------------------------------

## The scream a unit of `species` makes, or an empty dictionary.
##
## Species 0 and 1 have three variants each and every other species is silent
## -- and so are **unit types 22, 25 and 26**: `0x0040CBDF` reads `+0x4C` and
## clears the play flag for them (docs/42 section 4.5). All three have species
## 0, so the species test alone let Cpt. Rutherford, the Scout and Major
## Rutherford scream where the engine says nothing.
##
## The cursor advances on **every** use, including the ones whose wave is
## never played, because the original advances it in the same place: the type
## gate is at `0x0040CBF2`, past the round robin that picked the wave.
func pain(species: int, type_id: int = -1) -> Dictionary:
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
	if MUTE_TYPES.has(type_id):
		return {}
	var ids: Array = DictRead.as_array(
		voices["alien_volume_ids"] if species == SPECIES_ALIEN
			and _fix_alien_volume else voices["volume_ids"])
	return {"wave": DictRead.as_string(waves[cursor]),
		"volume_id": DictRead.as_int(ids[cursor]), "loop": false}


## The death scream of docs/42 section 4.5 -- what a shot of severity 3 plays.
##
## Humans and aliens scream `SP_HUM_n` off their **own** cursor -- the same
## two cursors the pain voice advances -- the human at ids 50..52 and the
## alien at 53..55, the three ids an earlier reading of docs/28 called unnamed
## (the fight loads them with `mov edi`, not a `push`). A machine (species 3)
## explodes, and an object (species 2) dies without a sound, which is a real
## answer and not a missing one.
func death_voice(species: int, type_id: int = -1) -> Dictionary:
	var voices: Dictionary = _tables.voices()
	if voices.is_empty():
		return {}
	# The mute of `MUTE_TYPES` covers the **explosion** too: every arm of the
	# cascade jumps to `0x0040CBD6` -- the machine's from `0x0040C9AC` -- and
	# the type test at `0x0040CBDB` is the next thing after it. So the gate is
	# applied once at the end, past every cursor, and not per arm.
	var cue: Dictionary = {}
	if species == SPECIES_MACHINE:
		var blast: Dictionary = DictRead.as_dict(voices.get("death_explosion", {}))
		if not blast.is_empty():
			cue = {"wave": DictRead.as_string(blast["wave"]),
				"volume_id": DictRead.as_int(blast["volume_id"]), "loop": false}
	elif species == SPECIES_HUMAN or species == SPECIES_ALIEN:
		var waves: Array = DictRead.as_array(voices["second_human"])
		var ids: Array = DictRead.as_array(
			voices["second_human_volume_ids"] if species == SPECIES_HUMAN
				else voices["death_alien_volume_ids"])
		var modulus: int = DictRead.as_int(voices["cursor_modulus"])
		var cursor: int = _cursors[species]
		_cursors[species] = (cursor + 1) % modulus
		cue = {"wave": DictRead.as_string(waves[cursor]),
			"volume_id": DictRead.as_int(ids[cursor]), "loop": false}
	if MUTE_TYPES.has(type_id):
		return {}
	return cue


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
