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
## button. Two are added: the options, which the original reached through
## hover-hinted icons inside a mission and never from here, and *Main Map*
## ([constant MAIN_MAP]).

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

## The action that leaves a running mission for the **location map**, with the
## campaign standing.
##
## The original's pause menu has no such entry either, and for the same reason
## it has no *Main Menu*: its own `Exit` leaves the program. But the two are
## not the same exit, and having only the wider one cost a campaign -- a
## mission left through *Main Menu* drops the campaign with it, and the three
## reserved autosave slots that still hold it are deliberately off the slot
## list ([constant CampaignHost.SLOT_COUNT]), so there is nothing to load it
## back from. This is the deployment screen's own *Main Map* button
## ([constant CampaignScreen.ID_MAIN_MAP]) offered from one screen further on:
## the sortie is abandoned, the squad comes back into the pool and the chain
## goes on from the map.
##
## It asks first, because the mission itself is dropped unsaved -- and with
## the remake's own question, `Txtmod_d` 60 being the shipped data's only one
## and naming the wrong destination.
const MAIN_MAP: String = "main_map"

## The question [constant MAIN_MAP] asks. See [constant CampaignScreen.OWN_OPTIONS]
## for why a key rather than a literal.
const OWN_ABANDON: String = "shell.abandon_mission"

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
## The last of the six sits lower than the step alone would put it -- which is
## the block's own version of [constant GROUP_GAP], and what that constant
## reproduces. Kept as the coordinate the arithmetic is checked against.
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

## What the whole cascade is moved left by -- **a quarter of a button**, and
## the remake's own.
##
## `Menu_a.lcl`'s table was written for the original's own menu window; this
## shell draws it on the framed plate, where the block's own last row reaches
## 615 of the plate's 640 and the frame's inner bevel is at 621. The right-hand
## end of the cascade therefore sat against the frame -- visible on the boot
## menu and worse on the pause menu, which is longer. Moving the whole cascade
## keeps the block's shape, which is what the table actually says: the start,
## the step, the descent and the lead are all still its own.
const LEFT_SHIFT: float = BUTTON_SIZE.x / 4.0

## What sets the trailing exits apart from the rows above them -- half the
## block's own step.
##
## *Main Menu* and *Exit Program* leave what every row above them does
## something inside, and a cascade of seven equal rows made the two of them
## easy to hit by mistake. The block itself makes the same distinction and
## makes it in the same direction: its own last row sits lower than the step
## alone would put it, and for a menu that fits the block's six rows this gap
## lands the last row on exactly that coordinate, [constant LAST_AT].
const GROUP_GAP: float = STEP.y / 2.0

## `Graphics/Title.bmp`, baked since converter 0.17.0. A cache from an older
## one has no such plate and [method CampaignScreen.plate_name]'s caller falls
## back to the frame, which is why this is a name rather than an assumption.
const TITLE_PLATE: String = "title"

## Whether a mission is running behind the shell. Then this is the pause menu
## and offers the things only a running mission can mean -- go back to it, and
## save it.
var paused: bool = false
## Whether that mission is a **campaign's**, which is what [constant MAIN_MAP]
## needs and [member paused] does not answer: a mission entered past the
## campaign -- *Instant Action*, `--mission=` -- has no campaign state, so
## [method CampaignHost.abandon_mission] would return at once and the button
## would be the inert control section 7.1 forbids.
var may_abandon: bool = false
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


## Both ways out of a running mission drop it unsaved -- one takes the campaign
## with it and the other leaves the campaign standing on its map.
func needs_confirming(action: String) -> bool:
	return action == MAIN_MENU or action == MAIN_MAP


## What [member pending] asks before it is let through. The shipped question
## names the main menu, so it is the one *Main Map* cannot borrow.
func _question() -> String:
	if pending == MAIN_MAP:
		return strings_own(OWN_ABANDON)
	return label_for(BANK_REPORT, ID_CONFIRM)


func _show_actions() -> void:
	if _entries == null:
		return
	clear_children(_entries)
	var entries: Array[Array] = []
	if pending != "":
		var question: Label = make_label(_question())
		question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		question.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_entries.add_child(question)
		place_on_plate(question, QUESTION_AT, QUESTION_SIZE)
		entries.append([CANCEL, label_for(BANK_REPORT, ID_NO)])
		entries.append([pending, label_for(BANK_REPORT, ID_YES)])
	else:
		# The way back comes first whenever there is anything to go back to --
		# a running mission **or** a campaign whose map is behind the plate.
		# Without it the menu reached from the map offered only to start a new
		# campaign over the one being played.
		if paused or behind:
			entries.append(["resume", label_for(BANK_MISSION, ID_CONTINUE)])
		if paused:
			entries.append(["save", label_for(BANK_SQUAD, ID_SAVE_GAME)])
			# Between the mission's own two and the shell's: it leaves the
			# mission and stays in the game, which is where it sits in the
			# cascade as well.
			if may_abandon:
				entries.append([MAIN_MAP,
					label_for(BANK_MISSION, ID_MAIN_MAP)])
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

	# Where in the shipped six this menu's rows start, so a short menu takes
	# the bottom of the cascade.
	var lead: int = maxi(SLOT_COUNT - entries.size(), 0)
	var apart: int = _exits_begin(entries) if pending == "" else -1
	for index: int in range(entries.size()):
		var row: Array = entries[index]
		var button: Button = make_button(DictRead.as_string(row[0]),
			DictRead.as_string(row[1]))
		var at: Vector2 = ANSWER_AT + ANSWER_STEP * float(index) \
			if pending != "" else _cascade_at(lead, index, apart)
		_entries.add_child(button)
		place_on_plate(button, at, BUTTON_SIZE)


## Where one row of the cascade goes: `Menu_a.lcl`'s own start, step and lead,
## moved left by [constant LEFT_SHIFT], with the rows from *apart* on pushed
## down by [constant GROUP_GAP]. *apart* is -1 for a cascade with no exits in
## it.
##
## The block's own lower last row is **not** a separate rule here: for every
## menu that fits the block's six the lead puts the last row at 280 and the
## gap lands it on [constant LAST_AT]'s 300. A seventh row goes to 340, which
## is what the block has no coordinate for -- and 40 below the row above it
## rather than the 4 the old last-row rule left, which is what put two buttons
## against each other and against the frame.
func _cascade_at(lead: int, index: int, apart: int) -> Vector2:
	var at: Vector2 = FIRST_AT + STEP * float(lead + index) \
		- Vector2(LEFT_SHIFT, 0.0)
	if apart >= 0 and index >= apart:
		at.y += GROUP_GAP
	return at


## Where the trailing run of exits begins, or -1 when the cascade ends in
## something else.
##
## Read off the entries rather than counted: which of the two are there
## depends on where the menu was raised from -- the boot menu has only *Exit
## Program*, a paused mission has both, and a confirmation has neither.
func _exits_begin(entries: Array[Array]) -> int:
	var first: int = entries.size()
	while first > 0:
		var action: String = DictRead.as_string(entries[first - 1][0])
		if action != MAIN_MENU and action != "quit":
			break
		first -= 1
	return first if first < entries.size() else -1
