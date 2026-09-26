class_name GameSettings
extends RefCounted

## What the player chose, kept between runs -- docs/92 section 7.15.
##
## **Only what is actually connected lives here.** Section 7.1 classes a
## control that does nothing as a defect in the remake's own interface rather
## than a period detail, so the original's eight option icons are the shape of
## this screen and not its contents: the speaker position, the cursor and
## animation levels and the animation resolution have nothing behind them in
## this remake, so they are absent rather than inert. The speech volume was on
## that list until the unit speech of docs/99 section 8 shipped; it is a row
## again since 2026-09-13.
##
## The six that are connected:
##
## | Setting | Where it lands |
## |---|---|
## | music volume | mission, map and front-end `Arack` music |
## | FX volume | cues, voices and cutscene `Track` soundtracks |
## | speech volume | unit speech and nothing else, as `Game.opt +0x14` (docs/20 section 8) |
## | difficulty | [member CampaignState.difficulty], then [member TurnState.ai_level] |
## | gore level | [member World.gore_level] |
## | `Faithful` | [constant AudioEvents.COMPAT_FLAGS] and [constant GAMEPLAY_CORRECTION_FLAGS] |
## | the interface font | every [Label] and [Button] the game draws |
##
## **Difficulty is the default for a new campaign, not the live value.** The
## authority is [member CampaignState.difficulty] -- section 7.15's S6 -- and
## the reason is [CanonicalHash]: `ai_level` is item 5 of the world's canonical
## hash, so writing difficulty into a running mission would move the hash of a
## game in progress and a slot saved before the change would no longer match
## the world it restores. The campaign's own digest is a different matter: it
## already carries `difficulty` ([method CampaignState.digest_hex]), so
## changing it on the map is a lawful change of campaign state.

## Where the file goes, and **a field rather than a constant** for the same
## reason [member CampaignHost.save_dir] is one: the `macOS Tests` preset runs
## the suites inside a real build against the real `user://`.
const DEFAULT_PATH: String = "user://settings.json"
const SCHEMA: String = "incubation.settings/1"
const SCHEMA_VERSION: int = 1

## docs/23 -- `0x00460450` answers 0, 1 or 2, and [constant
## Allowance.AI_LEVELS] is the same three. The default is **normal**, which is
## also [constant Allowance.DEFAULT_AI_LEVEL] and therefore [member
## TurnState.ai_level]'s own default: the two are one engine setting, and a
## shell that defaulted them differently would move every campaign world's
## canonical hash the first time it wrote one into the other.
const DIFFICULTY_MIN: int = 0
const DIFFICULTY_MAX: int = 2
const DIFFICULTY_DEFAULT: int = Allowance.DEFAULT_AI_LEVEL

## docs/42 section 4.8.1 -- 1 puff only, 2 the computer's units bleed, 3 all.
const GORE_MIN: int = 1
const GORE_MAX: int = 3

## Hundredths of a decibel, which is `Game.opt`'s own representation and what
## [method AudioSystem.set_fx_volume] takes. 0 is unattenuated; the floor is
## the point past which [method AudioTables.attenuation] silences everything
## anyway (`_base_floor` is -2000, and this leaves room below it for a
## deliberately quiet setting to still be audible on a loud cue).
const VOLUME_MIN: int = -4000
const VOLUME_MAX: int = 0
## One slider/key step. One decibel keeps the shipped -6 dB music default on
## the scale instead of moving it merely because the options screen opened.
const VOLUME_STEP: int = 100

## Simulation choices controlled by the same user-facing preset as the audio
## flags. Unlike presentation-only audio flags, these are stored in
## [member World.compat_flags] and therefore enter saves and canonical hashes.
const GAMEPLAY_CORRECTION_FLAGS: Array[String] = [
	Interact.COMPAT_BEACOO_MINE_DEATH_BLAST,
]

var path: String = DEFAULT_PATH
var fx_volume: int = AudioSystem.DEFAULT_FX_VOLUME
var speech_volume: int = AudioSystem.DEFAULT_SPEECH_VOLUME
var music_volume: int = AudioSystem.DEFAULT_MUSIC_VOLUME
var difficulty: int = DIFFICULTY_DEFAULT
var gore_level: int = World.GORE_DEFAULT
## docs/92 section 7.1's one user-facing preset, on by default: the whole first
## list of reproduced defects, not one control per defect.
var faithful: bool = true
## Whether the interface is drawn in the game's **own** bitmap font.
##
## `font_2` is a 17 px bitmap out of the shipped `.LIB` atlas (docs/60), so it
## cannot be antialiased and cannot be scaled: at the 640x480 base the screens
## are laid out in, a window twice that wide draws every glyph at 2x with hard
## edges. Godot's vector default scales and antialiases instead.
##
## **The default is the readable one, and that is a change of the fidelity
## default made deliberately** rather than by omission: the period font stays
## one click away and every plate still uses it when asked. Nothing else in
## the remake trades fidelity for comfort by default -- this one does, because
## the alternative is text the player cannot read.
var game_font: bool = false
## Whether `aGameIntro`'s title plate has already been sat through once.
##
## The original waits for a key or a click on *Start Game* on **every** launch
## (`0x0044BCA0`). This remake shows the two shipped plates the first time and
## goes straight to the menu afterwards -- docs/92 section 7.19's I19, and the
## same trade [member game_font] makes: a period detail that costs the player
## a click every single run. Deleting the settings file brings it back.
var seen_splash: bool = false
enum ControlMode { AUTO, TOUCH, MOUSE }
var control_mode: ControlMode = ControlMode.AUTO
## Which of the cache's languages to read -- docs/92 section 7.6. **Empty
## means the cache's base language**, so a settings file written before the
## row existed, or one carried to a cache without the pack it names, reads
## exactly as it did: [CachePaths] falls back to the base by name. No schema
## bump, on the `speech_volume` precedent.
var language: String = ""


## Read the file, or keep the defaults when there is none.
##
## A file that will not parse is **not** silently replaced: the defaults are
## used for this run and `false` comes back, so the caller can say so. Deleting
## a player's settings because one byte went wrong is the kind of quiet damage
## docs/92 section 7.4 is about.
func load_from_disk() -> bool:
	if not FileAccess.file_exists(path):
		return false
	# **An instance, not `JSON.parse_string`.** The static helper reports a bad
	# document with `ERR_PRINT`, and `run_tests.sh` fails a run on any engine
	# error line -- so a suite that exercises the broken-file path would paint
	# the whole run red. The instance answers with a code and a message
	# instead, which is what a diagnosable refusal wants anyway.
	var reader: JSON = JSON.new()
	var failed: Error = reader.parse(FileAccess.get_file_as_string(path))
	if failed != OK or typeof(reader.data) != TYPE_DICTIONARY:
		push_warning("%s is not a settings document (line %d: %s); using the "
			% [path, reader.get_error_line(), reader.get_error_message()]
			+ "defaults")
		return false
	var document: Dictionary = reader.data
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		push_warning("%s is not this build's settings schema" % path)
		return false
	# Every number is clamped on the way in. A hand-edited file is the normal
	# way this one is written, and a difficulty of 7 would reach
	# [method Allowance.for_unit], which answers **zero movement points** for
	# a level it does not know.
	fx_volume = _clamp_volume(DictRead.as_int(document.get("fx_volume",
		fx_volume)))
	# **A file from before the speech row falls back to the effects volume**,
	# not to the constant: the unit lines used to play at `fx_volume`, and a
	# player who had turned that down got them back at full on the update.
	# The schema did not move for the row, so this is the only migration.
	speech_volume = _clamp_volume(DictRead.as_int(document.get("speech_volume",
		fx_volume)))
	music_volume = _clamp_volume(DictRead.as_int(document.get("music_volume",
		music_volume)))
	difficulty = clampi(DictRead.as_int(document.get("difficulty", difficulty)),
		DIFFICULTY_MIN, DIFFICULTY_MAX)
	gore_level = clampi(DictRead.as_int(document.get("gore_level", gore_level)),
		GORE_MIN, GORE_MAX)
	faithful = DictRead.as_bool(document.get("faithful", faithful))
	game_font = DictRead.as_bool(document.get("game_font", game_font))
	seen_splash = DictRead.as_bool(document.get("seen_splash", seen_splash))
	var mode: int = DictRead.as_int(document.get("control_mode", ControlMode.AUTO))
	control_mode = mode as ControlMode if mode >= ControlMode.AUTO \
		and mode <= ControlMode.MOUSE else ControlMode.AUTO
	language = DictRead.as_string(document.get("language", language))
	return true


func save_to_disk() -> bool:
	var made: Error = DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	if made != OK and made != ERR_ALREADY_EXISTS:
		return false
	# Replaced whole or not at all: a truncated document is one
	# [method load_from_disk] refuses, and every setting would go with it.
	return AtomicFile.write(path,
		JSON.stringify(view(), "  ", true, true).to_utf8_buffer())


func view() -> Dictionary:
	return {
		"schema": SCHEMA,
		"schema_version": SCHEMA_VERSION,
		"fx_volume": fx_volume,
		"speech_volume": speech_volume,
		"music_volume": music_volume,
		"difficulty": difficulty,
		"gore_level": gore_level,
		"faithful": faithful,
		"game_font": game_font,
		"seen_splash": seen_splash,
		"control_mode": int(control_mode),
		"language": language,
	}


# -- applying ------------------------------------------------------------------

## The three volumes, and the compatibility preset the sound layer holds.
##
## `events` is separate from `audio` because docs/92 section 7.11 puts the two
## audio flags in the audio layer rather than in `World.compat_flags`: they
## change what is heard and no rule, and a preset that moved the simulation's
## hash would be a worse defect than the two it reproduces.
func apply_audio(audio: AudioSystem, events: AudioEvents = null) -> void:
	if audio != null:
		audio.set_fx_volume(fx_volume)
		audio.set_speech_volume(speech_volume)
		audio.set_music_volume(music_volume)
	if events == null:
		return
	for flag: String in AudioEvents.COMPAT_FLAGS:
		var took: bool = events.set_compat(flag, faithful)
		if not took:
			push_warning("this build has no compatibility flag %s" % flag)


## What a freshly created world takes from the settings.
##
## *level* is the difficulty the caller decided -- [member
## CampaignState.difficulty] inside a campaign, and this object's own default
## outside one. It is passed rather than read so the authority stays where
## S6 put it and cannot drift into this file.
##
## Called **before** the first hand-over, so the movement allowance and the
## experience multiplier are computed at the level the mission is played at.
func apply_world(world: World, level: int) -> void:
	if world == null:
		return
	world.turn.ai_level = clampi(level, DIFFICULTY_MIN, DIFFICULTY_MAX)
	world.gore_level = clampi(gore_level, GORE_MIN, GORE_MAX)
	apply_gameplay_compat(world)


## Applies the simulation half of the Faithful preset. This is separate from
## [method apply_world] so an explicit toggle can affect the current mission;
## loading a save still restores its own named flags after world creation.
func apply_gameplay_compat(world: World) -> void:
	if world == null:
		return
	var flags: PackedStringArray = world.compat_flags.duplicate()
	for flag: String in GAMEPLAY_CORRECTION_FLAGS:
		var at: int = flags.find(flag)
		if not faithful and at < 0:
			flags.append(flag)
		elif faithful and at >= 0:
			flags.remove_at(at)
	world.compat_flags = flags


func _clamp_volume(hundredths: int) -> int:
	return clampi(hundredths, VOLUME_MIN, VOLUME_MAX)
