class_name MainMenuScreen
extends CampaignScreen

## The main menu -- `aMenuSystem.cpp`'s `:MainMenu` block, minus what this
## remake does not have.
##
## `DATA/GUI/Menu_a.lcl`'s block is a flat table rather than a program: a
## window at `(0, 0, 640, 480)`, `Txtmod_a[100]` at `(500, 50)` in `font_2`,
## and six buttons in a descending cascade from `(280, 80)` to `(425, 300)`.
## The cascade is reproduced because it is a table of constants and costs
## nothing; the rest is this remake's own (docs/92 section 7.15 S3).
##
## **Two of the original's six are absent, not disabled.** `Network Game` and
## `Load PBM Game` are multiplayer, which docs/92 section 7.9 puts outside the
## programme, and section 7.1 classes a control that does nothing as a defect
## in the remake's own interface -- so a locked button would be worse than no
## button. One is added: the options, which the original reached through
## hover-hinted icons inside a mission and never from here.

## `Txtmod_a`, the menu bank (`aMenuSystem.cpp`).
const ID_TITLE: int = 100
const ID_START_CAMPAIGN: int = 101
const ID_INSTANT_ACTION: int = 103
const ID_MENU_LOAD_GAME: int = 104
const ID_EXIT: int = 105

## `Menu_a.lcl`'s own cascade, read out of the `:MainMenu` block. The plate is
## 640x480 and so is the window, so these are screen coordinates.
const TITLE_AT: Vector2 = Vector2(500.0, 50.0)
const FIRST_AT: Vector2 = Vector2(280.0, 80.0)
const STEP: Vector2 = Vector2(30.0, 40.0)
## The last of the six sits lower than the step alone would put it.
const LAST_AT: Vector2 = Vector2(425.0, 300.0)
## Six tiles wide, which is what the block's width field says.
const BUTTON_SIZE: Vector2 = Vector2(190.0, 30.0)

## `Graphics/Title.bmp`, baked since converter 0.17.0. A cache from an older
## one has no such plate and [method CampaignScreen.plate_name]'s caller falls
## back to the frame, which is why this is a name rather than an assumption.
const TITLE_PLATE: String = "title"

## Whether a mission is running behind the shell. Then this is the pause menu
## and offers the two things only a running mission can mean -- go back to it,
## and save it.
var paused: bool = false
## Whether there is anything behind the plate to go back to, which is a wider
## question than [member paused]: the campaign map is behind it too.
var behind: bool = false
## Whether any slot holds a save. *Load Game* is offered when there is
## something to load and left out when there is not: eight empty rows behind a
## button that promises a game is the inert control section 7.1 forbids.
var has_any_save: bool = false


func plate_name() -> String:
	return PLATE if paused else TITLE_PLATE


func build() -> void:
	# On the root rather than in the body: `Menu_a.lcl`'s coordinates are of
	# the whole 640x480 window, and the body is inset by the frame's margins.
	var title: Label = make_label(label_for(BANK_MENU, ID_TITLE))
	root().add_child(title)
	place_on_plate(title, TITLE_AT)

	var entries: Array[Array] = []
	# The way back comes first whenever there is anything to go back to --
	# a running mission **or** a campaign whose map is behind the plate.
	# Without it the menu reached from the map offered only to start a new
	# campaign over the one being played.
	if paused or behind:
		entries.append(["resume", label_for(BANK_MISSION, ID_CONTINUE)])
	if paused:
		entries.append(["save", label_for(BANK_SQUAD, ID_SAVE_GAME)])
	else:
		entries.append(["campaign", label_for(BANK_MENU, ID_START_CAMPAIGN)])
		entries.append(["instant", label_for(BANK_MENU, ID_INSTANT_ACTION)])
	if has_any_save:
		entries.append(["load", label_for(BANK_MENU, ID_MENU_LOAD_GAME)])
	entries.append(["options", strings_own(OWN_OPTIONS)])
	entries.append(["quit", label_for(BANK_MENU, ID_EXIT)])

	for index: int in range(entries.size()):
		var row: Array = entries[index]
		var button: Button = make_button(DictRead.as_string(row[0]),
			DictRead.as_string(row[1]))
		var at: Vector2 = FIRST_AT + STEP * float(index)
		if index == entries.size() - 1:
			at = LAST_AT
		root().add_child(button)
		place_on_plate(button, at, BUTTON_SIZE)
