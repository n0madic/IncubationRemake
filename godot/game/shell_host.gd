class_name ShellHost
extends RefCounted

## The shell's state machine -- the thing that makes six slices of work
## reachable by a player (docs/92 section 7.15).
##
## [codeblock]
## Menu -> CampaignSelect -> (the intro) -> the campaign map
##      -> MissionSelect  -> one mission, past the campaign
##      -> Slots(load)    -> whatever the slot held
##      -> Options
##      -> quit
## [/codeblock]
##
## It owns **which shell screen is up and what a button there means**, and
## nothing else: [CampaignHost] still owns the campaign and [SliceMain] still
## builds worlds and puts screens on the tree. The split is the same one
## docs/92 section 10.2 draws for the campaign -- a host that decides, a
## renderer that shows.
##
## This is deliberately not part of [World] or [CampaignState]. The shell is
## not simulation state: nothing here is saved, hashed or replayed.

const SCREEN_NONE: String = ""
const SCREEN_MENU: String = "menu"
const SCREEN_CAMPAIGN_SELECT: String = "campaign_select"
const SCREEN_MISSION_SELECT: String = "mission_select"
const SCREEN_SLOTS: String = "slots"
const SCREEN_OPTIONS: String = "options"

## Every screen this host can put up, so a caller can validate a name -- the
## `tour.gd` driver names them from outside.
const SCREENS: Array[String] = [SCREEN_MENU, SCREEN_CAMPAIGN_SELECT,
	SCREEN_MISSION_SELECT, SCREEN_SLOTS, SCREEN_OPTIONS]

## What the slot screen is for this time. The eight rows are the same eight
## either way; what changes is what clicking one does, and a screen that could
## do both from one row would sooner or later overwrite a save with a click
## meant to load it.
const MODE_LOAD: String = "load"
const MODE_SAVE: String = "save"

## The shell screen that is up, or [constant SCREEN_NONE].
var screen: String = SCREEN_NONE
## The screen the shell was **opened at**, which is where `Back` leaves from.
##
## Without it every `Back` funnelled through the menu: the campaign map's own
## *Options* button dropped the player on a boot-style menu offering to start
## a new campaign over the one they were playing, with the way back to the map
## only on `ESC`.
var entry: String = SCREEN_MENU
var slot_mode: String = MODE_LOAD
## True while there is **something behind the shell** -- a running mission, or
## a campaign whose map the shell was raised over. It decides one thing only:
## what leaving the shell does, go back to what was there or stay on the menu
## because there is nothing to go back to.
##
## It is deliberately not "a mission is being played". That is a narrower
## question, [method SliceMain.in_mission] answers it, and conflating the two
## once made the campaign map offer *Continue* and *Save game* on the grounds
## that the last mission's world was still in memory behind its plate.
var behind: bool = false


func is_up() -> bool:
	return screen != SCREEN_NONE


## Open the shell at one of its screens. *something_behind* says whether there
## is anything to go back to.
func open(name: String = SCREEN_MENU, something_behind: bool = false) -> void:
	screen = name if SCREENS.has(name) else SCREEN_MENU
	entry = screen
	behind = something_behind


func close() -> void:
	screen = SCREEN_NONE
	entry = SCREEN_MENU
	behind = false


## Move to another shell screen without leaving the shell.
func go(name: String) -> void:
	if SCREENS.has(name):
		screen = name


## Open the slot list in one of its two modes.
func go_slots(mode: String) -> void:
	slot_mode = mode if mode == MODE_SAVE else MODE_LOAD
	screen = SCREEN_SLOTS


## Where `Back` goes from *name*.
##
## `Back` leaves the shell from the screen it was **opened at** and returns to
## the menu from anywhere the menu led to. So the campaign map's *Options*
## button comes back to the map, and *Options* reached through the menu comes
## back to the menu.
##
## From the entry screen with nothing behind -- the boot menu -- `Back` stays
## put: a `Back` that quit the game from the top of the menu would be the kind
## of surprise docs/92 section 7.4 calls a silent action, and leaving the shell
## there would draw nothing at all.
func back_from(name: String) -> String:
	if name == entry:
		return SCREEN_NONE if behind else SCREEN_MENU
	return SCREEN_MENU


func view() -> Dictionary:
	return {"screen": screen, "entry": entry, "slot_mode": slot_mode,
		"behind": behind}
