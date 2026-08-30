class_name Localization
extends RefCounted

## The single source of user-facing text -- docs/92 section 7.6.
##
## "Retrofitting that seam later means finding every literal in the codebase,
## which is the expensive kind of change." So it exists before the first string
## does, and `game/` has no user-facing literal outside this file: everything on
## screen comes through [method text] or [method shipped].
##
## Two catalogues, and the difference matters:
##
## * **the game's own**, from `text/<language>.json` in the cache, which
##   `tools/inclib/brieftext.py` extracts byte-exactly from `DATA/TXT/<lang>`.
##   Keyed by module and numeric id, because that is how the shipped files are
##   keyed and inventing names for 723 strings would be a translation of its
##   own. `Txtmod_g` holds "Mission", "Turn", "Player", "Mission completed" and
##   "Mission failed" -- the words this stage needs;
## * **the remake's own**, for the handful of things the original never had to
##   say (a hint line, a key legend). Written out below rather than in a second
##   file, so that "every string" is one grep.
##
## The language comes from the cache manifest and the fallback is **explicit**:
## a missing key returns a visible marker, not an empty string. An empty string
## looks like a layout bug and a marker looks like what it is.

## The shipped GUI module this stage reads. docs/24 section 7 names them.
const MODULE_MISSION: String = "Txtmod_g"
const MODULE_REPORT: String = "Txtmod_d"

## The ids in `Txtmod_g` this stage uses, named once so the numbers do not
## spread through `game/`.
const ID_MISSION: int = 11
const ID_TURN: int = 12
const ID_PLAYER: int = 13
const ID_COMPLETED: int = 25
const ID_FAILED: int = 26

## The remake's own strings, by key and then by language. English is the only
## one the shipped data guarantees -- `DATA/TXT/` contains whatever the
## installation was sold with -- so it is also the fallback.
const FALLBACK_LANGUAGE: String = "English"
const OWN: Dictionary = {
	"hud.select": {"English": "click a unit"},
	"hud.move": {"English": "click a highlighted cell to move"},
	"hud.attack": {"English": "click an enemy to fire"},
	"hud.use": {"English": "U uses what the unit faces"},
	"hud.defend": {"English": "D holds fire until an enemy moves"},
	"hud.end_turn": {"English": "SPACE ends the turn"},
	"hud.no_selection": {"English": "nothing selected"},
	"hud.movement_points": {"English": "MP"},
	"hud.hit_points": {"English": "HP"},
	"hud.fitness": {"English": "FP"},
	"hud.ammunition": {"English": "ammo"},
	"hud.overwatch": {"English": "on overwatch"},
	"hud.computer": {"English": "the aliens"},
	"hud.reactions": {"English": "reaction shots"},
	"hud.hidden": {"English": "hidden"},
	"hud.contact": {"English": "contact"},
	"hud.not_yours": {"English": "not your unit"},
	"hud.ai_turn": {"English": "the aliens are moving"},
	"hud.ai_skip": {"English": "any key skips the replay"},
	"hud.defeat": {"English": "mission failed"},
	"hud.victory": {"English": "mission accomplished"},
	"ai.move": {"English": "advances"},
	"ai.warp": {"English": "jumps"},
	"ai.fire": {"English": "fires"},
	"ai.fire_heat_blocked": {"English": "cannot fire"},
	"ai.door": {"English": "opens a door"},
	"ai.parabomb": {"English": "a parabomb goes off"},
	"ai.reactions": {"English": "draws reaction fire"},
	"ai.promote_order": {"English": "changes its orders"},
}

## What a missing key renders as. Visible on purpose.
const MISSING_PREFIX: String = "??"

var language: String = FALLBACK_LANGUAGE
var _gui: Dictionary = {}


## Reads `text/<language>.json` out of a cache directory.
##
## A cache with no text catalogue is not an error: the mission still plays and
## every shipped string renders as its marker, which is a great deal easier to
## diagnose than a screen of blanks.
static func from_cache(cache_dir: String, manifest: Dictionary) -> Localization:
	var out: Localization = Localization.new()
	out.language = DictRead.as_string(
		manifest.get("language", FALLBACK_LANGUAGE))
	var path: String = "%s/text/%s.json" % [cache_dir, out.language]
	var document: Dictionary = CacheLoader.read_json(path)
	if not document.is_empty():
		out._gui = DictRead.as_dict(document.get("gui", {}))
	return out


func has_shipped_text() -> bool:
	return not _gui.is_empty()


## One string out of the shipped catalogue, by module and id.
func shipped(module: String, id: int) -> String:
	if not _gui.has(module):
		return "%s%s/%d" % [MISSING_PREFIX, module, id]
	var entries: Dictionary = DictRead.as_dict(_gui[module])
	var key: String = str(id)
	if not entries.has(key):
		return "%s%s/%d" % [MISSING_PREFIX, module, id]
	return DictRead.as_string(entries[key])


## Whether this catalogue defines one of the remake's own keys.
##
## The AI playback names an event kind as `ai.<kind>`, and a kind the
## catalogue has no line for renders as the kind itself rather than as a
## marker: a new event should be legible before it is translated, not
## invisible.
func has(key: String) -> bool:
	return OWN.has(key)


## One of the remake's own strings, by key.
func text(key: String) -> String:
	if not OWN.has(key):
		return MISSING_PREFIX + key
	var by_language: Dictionary = OWN[key]
	if by_language.has(language):
		return DictRead.as_string(by_language[language])
	if by_language.has(FALLBACK_LANGUAGE):
		return DictRead.as_string(by_language[FALLBACK_LANGUAGE])
	return MISSING_PREFIX + key
