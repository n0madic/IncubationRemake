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

## The ids in `Txtmod_d`, the debriefing module (docs/27 section 6.1 builds the
## end-of-mission screen from it), that the result panel puts on screen.
##
## 15, 16 and 17 are the three win grades in order, and they sit directly after
## 14, so a table indexed by docs/27 section 6.3's mission result reads
## `{1: 19, 2: 15, 3: 16, 4: 17, 5: 14}`. **Which of the module's two defeat
## lines the engine picks is untraced** -- 18, "You have lost.", is the other
## candidate, and the reading taken here is that it belongs with the 40..46
## match-report block the way 14 belongs with 15..17. Marked rather than
## presented as settled.
const ID_REPORT_TITLE: int = 10
const ID_REPORT_DEFEATED: int = 14
const ID_REPORT_SUCCESS: int = 15
const ID_REPORT_OUTSTANDING: int = 16
const ID_REPORT_GLORIOUS: int = 17
const ID_REPORT_RUNNING: int = 19
## "Turns", "Equipment Points" and "Commendations" are labels from the module's
## match-report block, which is where the two payout labels live together;
## the single-mission block has only "Commendations" (22) of the three.
const ID_REPORT_TURNS: int = 41
const ID_REPORT_EQUIPMENT: int = 45
const ID_REPORT_COMMENDATIONS: int = 46

## The remake's own strings, by key and then by language. English is the only
## one the shipped data guarantees -- `DATA/TXT/` contains whatever the
## installation was sold with -- so it is also the fallback.
const FALLBACK_LANGUAGE: String = "English"
const OWN: Dictionary = {
	"hud.no_selection": {"English": "nothing selected"},
	"hud.overwatch": {"English": "on overwatch"},
	"hud.reactions": {"English": "reaction shots"},
	"hud.not_yours": {"English": "not your unit"},
	"hud.no_points": {"English": "no movement points left"},
	"hud.ai_turn": {"English": "the aliens are moving"},
	"hud.ai_skip": {"English": "any key skips the replay"},
	"ai.move": {"English": "advances"},
	"ai.warp": {"English": "jumps"},
	"ai.fire": {"English": "fires"},
	"ai.fire_heat_blocked": {"English": "cannot fire"},
	"ai.door": {"English": "opens a door"},
	"ai.parabomb": {"English": "a parabomb goes off"},
	"ai.reactions": {"English": "draws reaction fire"},
	"ai.promote_order": {"English": "changes its orders"},
	# The shell (docs/92 section 7.15). Everything the original's own front
	# end says is read out of `Txtmod_a`, `Txtmod_d`, `Txtmod_f` and
	# `Txtmod_h`; these are the few things it never had to say, because it
	# reached its options through hover-hinted icons inside a mission and had
	# no screen to title, no slot metadata to head and no chain to choose
	# between by name.
	"shell.options": {"English": "Options"},
	# The pause menu's *Main Map* question. `Txtmod_d` 60 is the shipped
	# data's only question and it names the main menu, which is the other
	# way out of a mission and the one that drops the campaign too.
	"shell.abandon_mission":
		{"English": "Back to the Main Map without saving?"},
	"shell.difficulty.0": {"English": "Easy"},
	"shell.difficulty.1": {"English": "Normal"},
	"shell.difficulty.2": {"English": "Hard"},
	"shell.gore": {"English": "Blood and Debris"},
	"shell.gore.1": {"English": "None"},
	"shell.gore.2": {"English": "Aliens only"},
	"shell.gore.3": {"English": "Everyone"},
	"shell.faithful": {"English": "Faithful to the original"},
	"shell.font": {"English": "Interface font"},
	# Short enough for the row's own field, which is `2_Width` widened to 4 --
	# *the game's own* ran off the end of it.
	"shell.font.game": {"English": "original"},
	"shell.font.readable": {"English": "readable"},
	"shell.language": {"English": "Language"},
	"shell.campaign": {"English": "Campaign %d"},
	"shell.slot": {"English": "Slot %d"},
	# The name field of the save screen. The original never says it because
	# its rows are eight pictures and it has no field at all.
	"shell.name_hint": {
		"English": "pick a slot, type a name and press Enter"},
	"shell.name_over": {"English": "overwriting  %s"},
	"shell.on": {"English": "on"},
	"shell.off": {"English": "off"},
	"shell.no_mission": {"English": "between missions"},
	# The deployment screen, which used to refuse in total silence -- see
	# `SelectUnitsScreen`. The original says none of this because its screen
	# is a picture of the map with the squad on it; a list needs telling.
	"deploy.hint": {"English": "pick a soldier, then a landing position"},
	"deploy.pick_a_soldier": {
		"English": "pick a soldier first, then a landing position"},
	"deploy.need_one": {
		"English": "put at least one soldier on the map before starting"},
	"deploy.not_a_deployment_cell": {"English": "not a landing position"},
	"deploy.cell_occupied": {"English": "somebody is standing there"},
	"deploy.no_free_unit_slot": {"English": "the map is full"},
	"deploy.empty_roster_record": {"English": "that roster slot is empty"},
	# The three windows of docs/27 section 5. Every caption on them is
	# shipped; these are only the refusals, which the original makes by
	# greying a button and saying nothing (docs/92 section 7.4).
	"roster.empty": {"English": "nobody in the squad -- recruit somebody"},
	"catalogue.empty": {"English": "nothing at this tech level"},
	"recruit.empty": {"English": "no unit type in this category"},
	"upgrade.nobody": {"English": "nobody to equip"},
	"upgrade.no_unit": {"English": "nobody selected"},
	"upgrade.bad_id": {"English": "no such item"},
	"upgrade.not_enough_equipment_points": {
		"English": "not enough equipment points"},
	"upgrade.not_enough_skill_points": {"English": "not enough skill points"},
	"upgrade.already_carried": {"English": "already carried"},
	"upgrade.jet_pack_already_scans": {
		"English": "the Jet Pack already carries a scanner"},
	"upgrade.rename": {"English": "a hero keeps the name he earned"},
	"upgrade.commend": {
		"English": "no commendation to award, or none left to earn"},
	# The end-of-mission transfer (docs/27 section 6). Both of
	# `aTransferAllUnitsFromMapToPool`'s refusals are silent in the engine --
	# it returns TRUE and the unit is simply gone -- and docs/92 section 7.4
	# keeps the rule while dropping the silence. **A guest is not a loss**:
	# every one of the 26 records a shipped campaign mission places for
	# player 0 with `pool_flag == 0` is a named story character -- Chainsaw
	# Steele, Simon, Harvey, Cpt. Rutherford, the ComBot, Dr. Reich -- so the
	# line says so in words and in the ordinary ink. A full squad is a real
	# loss and keeps the alert ramp.
	"debriefing.guest": {"English": "guest, does not join the squad"},
	"debriefing.squad_full": {"English": "the squad is full, left behind"},
	# The one thing the roll of docs/101 section 14 says that Blue Byte did
	# not write. It is appended after the shipped bank's last line, in the
	# roll's own grammar -- a heading and a name -- and is deliberately the
	# **only** invented text on that screen: everything above it is
	# `Txtmod_a` 161..338 verbatim.
	"credits.remake": {"English": "Remake:"},
	"credits.remake_by": {"English": "n0madic"},
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
