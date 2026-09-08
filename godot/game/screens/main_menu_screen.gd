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

## The action that leaves a running mission for the boot menu.
##
## The original's pause menu has no such entry -- its `Exit` leaves the
## *program* -- but this remake's shell is the only way back to a chain
## chooser or a save slot, and `ESC` over a mission used to offer nothing
## between going on and quitting the game altogether. The question it asks is
## the shipped one: `Txtmod_d` 60, *Back to the Main Menu without saving?*
const MAIN_MENU: String = "main_menu"

## Where the question and its two answers go. Not in the cascade: that is
## `Menu_a.lcl`'s table for a *menu*, and it runs a question's answers
## diagonally away from each other and the question itself into the screen's
## own name at (500, 50).
const QUESTION_AT: Vector2 = Vector2(0.0, 170.0)
const QUESTION_SIZE: Vector2 = Vector2(640.0, 24.0)
const ANSWER_AT: Vector2 = Vector2(225.0, 210.0)
const ANSWER_STEP: Vector2 = Vector2(0.0, 40.0)

## `Menu_a.lcl`'s own cascade, read out of the `:MainMenu` block. The plate is
## 640x480 and so is the window, so these are screen coordinates.
const TITLE_AT: Vector2 = Vector2(500.0, 50.0)
const FIRST_AT: Vector2 = Vector2(280.0, 80.0)
const STEP: Vector2 = Vector2(30.0, 40.0)
## The last of the six sits lower than the step alone would put it.
const LAST_AT: Vector2 = Vector2(425.0, 300.0)
## How many rows `Menu_a.lcl` writes.
##
## **A shorter menu takes the bottom of the cascade, not the top.** This one
## has five rows where the original has six, and starting at row 0 left the
## first button across *Time is running out* on the title art and a two-row
## hole above the last. Ending on the shipped `(425, 300)` and counting back
## puts every button on one of the block's own six coordinates and clears the
## logo, without inventing a position.
const SLOT_COUNT: int = 6
## Six tiles wide, which is what the block's width field says.
const BUTTON_SIZE: Vector2 = Vector2(190.0, 30.0)
## What the last entry keeps clear of the one above it.
const LAST_GAP: float = 4.0

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

## The cascade, so a confirmation can rebuild it without taking the plate's
## own frame and title down with it.
var _entries: Control = null


func plate_name() -> String:
	return PLATE if paused else TITLE_PLATE


func build() -> void:
	# On the root rather than in the body: `Menu_a.lcl`'s coordinates are of
	# the whole 640x480 window, and the body is inset by the frame's margins.
	var title: Label = make_label(label_for(BANK_MENU, ID_TITLE))
	root().add_child(title)
	place_on_plate(title, TITLE_AT)

	_entries = Control.new()
	_entries.set_anchors_preset(Control.PRESET_FULL_RECT)
	_entries.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root().add_child(_entries)
	_show_actions()


## Leaving a mission for the boot menu drops it, and the campaign with it.
func needs_confirming(action: String) -> bool:
	return action == MAIN_MENU


func _show_actions() -> void:
	if _entries == null:
		return
	clear_children(_entries)
	var entries: Array[Array] = []
	if pending == MAIN_MENU:
		var question: Label = make_label(label_for(BANK_REPORT, ID_CONFIRM))
		question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		question.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_entries.add_child(question)
		place_on_plate(question, QUESTION_AT, QUESTION_SIZE)
		entries.append([CANCEL, label_for(BANK_REPORT, ID_NO)])
		entries.append([MAIN_MENU, label_for(BANK_REPORT, ID_YES)])
	else:
		# The way back comes first whenever there is anything to go back to --
		# a running mission **or** a campaign whose map is behind the plate.
		# Without it the menu reached from the map offered only to start a new
		# campaign over the one being played.
		if paused or behind:
			entries.append(["resume", label_for(BANK_MISSION, ID_CONTINUE)])
		if paused:
			entries.append(["save", label_for(BANK_SQUAD, ID_SAVE_GAME)])
		else:
			entries.append(["campaign",
				label_for(BANK_MENU, ID_START_CAMPAIGN)])
			entries.append(["instant",
				label_for(BANK_MENU, ID_INSTANT_ACTION)])
		if has_any_save:
			entries.append(["load", label_for(BANK_MENU, ID_MENU_LOAD_GAME)])
		entries.append(["options", strings_own(OWN_OPTIONS)])
		# Only where there is something to leave: at the boot menu this **is**
		# the main menu, and a button that led back to the screen it is on is
		# the inert control section 7.1 forbids.
		if paused or behind:
			entries.append([MAIN_MENU, label_for(BANK_MENU, ID_TITLE)])
		entries.append(["quit", label_for(BANK_MENU, ID_EXIT)])

	# Where in the shipped six this menu's rows start, so the last one lands
	# on the block's own last coordinate. A menu longer than six begins at row
	# 0 and runs past the bottom, which the guard below catches.
	var lead: int = maxi(SLOT_COUNT - entries.size(), 0)
	for index: int in range(entries.size()):
		var row: Array = entries[index]
		var button: Button = make_button(DictRead.as_string(row[0]),
			DictRead.as_string(row[1]))
		var at: Vector2 = FIRST_AT + STEP * float(lead + index)
		if pending != "":
			at = ANSWER_AT + ANSWER_STEP * float(index)
		elif index == entries.size() - 1:
			# The cascade's last entry sits lower than the step alone would
			# put it -- that is `Menu_a.lcl`'s own table. It is only *lower*,
			# though: a seven-entry cascade reaches y 280 by itself and the
			# fixed 300 would then overlap the row above it, which the shipped
			# faces made plain.
			var above: float = FIRST_AT.y + STEP.y * float(lead + index - 1)
			at = Vector2(LAST_AT.x,
				maxf(LAST_AT.y, above + BUTTON_SIZE.y + LAST_GAP))
		_entries.add_child(button)
		place_on_plate(button, at, BUTTON_SIZE)
