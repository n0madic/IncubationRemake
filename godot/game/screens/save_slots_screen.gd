class_name SaveSlotsScreen
extends CampaignScreen

## The numbered slots -- `aLoad.cpp`'s screen, which is what `Txtmod_f` is the
## bank for.
##
## One screen, two modes: [constant ShellHost.MODE_LOAD] and
## [constant ShellHost.MODE_SAVE]. The rows are the same either way and
## only what a click does changes -- a screen that could do both from one row
## would eventually overwrite a save with a click meant to load it.
##
## **A row is built from the container's header alone.** [method
## CampaignCodec.decode_header] reads the campaign, the mission, the score and
## the stamp without unrolling the roster, the scoreboard or the mission blob:
## a page of rows must not cost a page of campaigns.
##
## A slot this build cannot read is **shown, carrying its refusal**, not
## hidden. A save that vanished from the list because the schema moved would
## look exactly like a slot the player never used, and section 7.4 is about
## precisely that kind of silence.
##
## **A save is named before it is written.** The original's own screen has no
## name field -- its rows are eight pictures -- but its `Txtmod_f` bank is a
## load/save bank and a campaign that runs to 24 slots needs the rows to be
## told apart by something the player chose. Clicking a row in save mode
## therefore opens a field on that row rather than writing at once; `Enter`
## writes, an empty field writes the row the screen would have shown anyway,
## and leaving the field cancels. Cancelling and not committing is the whole
## difference from the Upgrade Menu's rename box: a rename can be undone by
## typing again and a save overwrites a file.

## `Txtmod_f`, the load/save bank (`aLoad.cpp`).
const BANK_SAVES: String = "Txtmod_f"
const ID_EXIT: int = 0
const ID_EMPTY: int = 1
const ID_LOAD: int = 10
const ID_SAVE: int = 11

## The remake's own: the original numbered its slots in the picture, not in a
## string, and none of the shipped banks carries a row heading.
const OWN_SLOT: String = "shell.slot"
const OWN_NO_MISSION: String = "shell.no_mission"
## What the name field is for, written under the title in save mode. The
## original never had to say it because it never had a field.
const OWN_NAME_HINT: String = "shell.name_hint"
## What the same line says while the field stands over a slot that already
## holds a save. `Enter` overwrites a file with no second question, and the
## field's placeholder -- the only other place the row is written -- goes on
## the first keystroke.
const OWN_NAME_OVER: String = "shell.name_over"

## How long a save's name may be. A named row is the name and the stamp; the
## limit is what leaves the stamp room inside a row of 12 pieces.
const NAME_LIMIT: int = 24

var host: CampaignHost = null
## [constant ShellHost.MODE_LOAD] or [constant ShellHost.MODE_SAVE].
var mode: String = ShellHost.MODE_LOAD
## True while there is a campaign to write, which is what makes the save mode
## meaningful. A row that offered to save nothing would be inert.
var may_save: bool = false

## The slot whose name field is open, or -1. Save mode only.
var naming: int = -1
## What was typed into it. [SliceMain] reads this when the row finally emits,
## so the name never has to be packed into an action string.
var typed_name: String = ""

var _list: Control = null
## The open name field and the row it stands in, so shutting it does not have
## to rebuild the list. See [method cancel_name].
var _field: LineEdit = null
var _field_row: Button = null
## The hint line under the title, in save mode. It says what the field is for,
## and while a field is open over an occupied slot it says what is in it.
var _hint: Label = null

## The list's own origin and width -- `GUI_SetListbox`'s, as `Menu_a.lcl`
## writes them for its ten level rows.
const LIST_AT: Vector2 = Vector2(60.0, 100.0)
const LIST_WIDTH: int = 12
## How many rows a page holds. Twelve fit between [constant LIST_AT] and the
## action row at [constant CampaignScreen.BUTTON_ROW_TOP]; the rest are paged,
## because a shipped listbox has no scroll bar -- it has two arrows
## ([MissionSelectScreen] pages the same way, and this is deliberately not a
## third layout).
const LIST_ROWS: int = 12
## `GUI_SetIcon (10, 30_Library, ...)` and `(11, 32_Library, ...)` -- the
## list's own two arrows, at the right of the rows.
const UP_AT: Vector2 = Vector2(480.0, 100.0)
const DOWN_AT: Vector2 = Vector2(480.0, 135.0)
const UP_INDEX: int = 30
const DOWN_INDEX: int = 32

## Where the name hint goes, above the first row.
const HINT_AT: Vector2 = Vector2(60.0, 78.0)
const HINT_SIZE: Vector2 = Vector2(520.0, 20.0)

## The first row on show.
var first_row: int = 0


func build() -> void:
	var title: Label = make_label(label_for(BANK_SAVES,
		ID_SAVE if mode == ShellHost.MODE_SAVE else ID_LOAD))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	if mode == ShellHost.MODE_SAVE:
		_hint = make_label(strings_own(OWN_NAME_HINT))
		_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root().add_child(_hint)
		place_on_plate(_hint, HINT_AT, HINT_SIZE)

	if CampaignHost.SLOT_COUNT > LIST_ROWS:
		var _up: Button = gui_icon("scroll_up", UP_INDEX, UP_AT, body())
		var _down: Button = gui_icon("scroll_down", DOWN_INDEX, DOWN_AT,
			body())

	_list = gui_layer()
	refresh()

	add_button("back", BANK_SAVES, ID_EXIT, 0)


func refresh() -> void:
	if _list == null:
		return
	# The rows are about to go, and with them whatever field stood in one.
	_field = null
	_field_row = null
	clear_children(_list)
	first_row = clampi(first_row, 0,
		maxi(0, CampaignHost.SLOT_COUNT - LIST_ROWS))
	var shown: int = mini(CampaignHost.SLOT_COUNT - first_row, LIST_ROWS)
	for index: int in range(shown):
		var slot: int = first_row + index
		var row: Button = gui_list_row("slot:%d" % slot, _caption(slot),
			LIST_AT + Vector2(0.0, LIST_ROW_HEIGHT * float(index)),
			LIST_WIDTH, index, shown, _list)
		# Loading an empty slot is the one click in this screen that can have
		# nothing behind it, so it is refused at the row rather than reported
		# afterwards.
		if mode == ShellHost.MODE_LOAD:
			row.disabled = host == null or not host.has_save(slot)
		else:
			row.disabled = not may_save
			if slot == naming and may_save:
				# The field stands **in** the row, so the row's own caption
				# comes off: the two drawn over each other were both
				# unreadable. What the row said is the field's placeholder --
				# and the placeholder goes on the first keystroke, so the
				# hint line carries it too for as long as the field is open.
				# `Enter` overwrites a file and the player is owed a sight of
				# what is in it at the moment they commit.
				row.text = ""
				_open_field(slot, row)
	_say_what_is_being_written_over()


## What the hint line says: the plain instruction, or -- while a field is open
## over a slot that already holds a save -- what that save is.
func _say_what_is_being_written_over() -> void:
	if _hint == null:
		return
	if naming >= 0 and host != null and host.has_save(naming):
		var over: String = strings_own(OWN_NAME_OVER)
		_hint.text = over % _caption(naming) if over.contains("%s") \
			else over
		return
	_hint.text = strings_own(OWN_NAME_HINT)


## One arrow, a page at a time. A page turned under an open field closes it:
## the field belongs to a row, and the row is about to be somewhere else.
func scroll(by: int) -> void:
	naming = -1
	first_row += by * LIST_ROWS
	refresh()


func scrolls() -> bool:
	return CampaignHost.SLOT_COUNT > LIST_ROWS


## The wheel, one row at a time. It closes an open field for the same reason
## the arrows do.
func step_rows(rows: int) -> void:
	naming = -1
	first_row += rows
	refresh()


## The name box on one row, with the caret in it.
##
## The recipe is [method UpgradeScreen._draw_name_field]'s, including the
## deferred and **guarded** focus: the suites build this screen with no tree at
## all, where `grab_focus` is an engine error and `run_tests.sh` fails a run on
## an error line whatever the checks say.
func _open_field(slot: int, row: Button) -> void:
	var field: LineEdit = LineEdit.new()
	field.text = typed_name
	field.placeholder_text = _caption(slot)
	field.alignment = HORIZONTAL_ALIGNMENT_LEFT
	field.max_length = NAME_LIMIT
	field.flat = true
	# **The row's own face, not the value face.** A row is drawn through
	# [method CampaignScreen.gui_text_button] in `fntID` 0, and a field in
	# any other size stood taller than the 22-unit row it sits in and spilled
	# over the one below it.
	var chosen: FontFile = face(FNT_LABEL)
	if chosen != null:
		field.add_theme_font_override("font", chosen)
	else:
		field.add_theme_font_size_override("font_size",
			readable_size(FNT_LABEL))
	field.add_theme_color_override("font_color", INK_VALUE)
	# **A lambda, not `bind`.** `Callable.bind` freezes its argument where the
	# connection is made, so a bound `field.text` would hand the commit the
	# empty string the box was opened with. Read the box when it fires.
	field.text_submitted.connect(func(typed: String) -> void:
		commit_name(slot, typed))
	# Leaving the field **cancels**, where the rename box commits: a save is a
	# write over a file, and a click meant for another row must not take it.
	field.focus_exited.connect(func() -> void:
		if is_instance_valid(field):
			cancel_name())
	field.anchor_left = row.anchor_left
	field.anchor_top = row.anchor_top
	field.anchor_right = row.anchor_right
	field.anchor_bottom = row.anchor_bottom
	field.offset_left = LIST_ROW_INSET
	field.offset_top = 0.0
	field.offset_right = -LIST_ROW_INSET
	field.offset_bottom = 0.0
	_list.add_child(field)
	_field = field
	_field_row = row
	_focus_field.call_deferred(field)


## Put the caret in the box on the next frame, if there still is one.
static func _focus_field(field: LineEdit) -> void:
	if not is_instance_valid(field) or not field.is_inside_tree():
		return
	field.grab_focus()
	field.select_all()


## Open the field on *slot*. Called for the row's own click in save mode.
func begin_naming(slot: int) -> void:
	naming = slot
	typed_name = ""
	refresh()


## Shut the field without writing anything.
##
## **It puts the row back by hand instead of calling [method refresh].** The
## field is closed by `focus_exited`, and a mouse press on another row takes
## the focus *before* that row's `pressed` fires -- so a rebuild here removed
## the row being pressed from the tree mid-press and the click was swallowed
## in silence. Every click on a slot cost two while a field was open. Only the
## field and its row change, so the rest of the list is left standing.
func cancel_name() -> void:
	if naming < 0:
		return
	var slot: int = naming
	naming = -1
	typed_name = ""
	_close_field(slot)
	_say_what_is_being_written_over()


## Take the open field down and give its row its caption back.
func _close_field(slot: int) -> void:
	if _field_row != null and is_instance_valid(_field_row):
		_field_row.text = _caption(slot)
	if _field != null and is_instance_valid(_field):
		# `remove_child` first, so the field is out of the input path in this
		# frame -- the same reason [method CampaignScreen.clear_children]
		# does it, and this runs from inside the field's own signal.
		if _field.get_parent() != null:
			_field.get_parent().remove_child(_field)
		_field.queue_free()
	_field = null
	_field_row = null


## Keep what was typed and let the row emit. [SliceMain] reads
## [member typed_name] when it handles the action.
##
## **Through `super`, not through [method _on_pressed].** This screen's own
## `_on_pressed` is what turns a row's click into an open field, so committing
## through it would open the field again on the row that had just been named
## and nothing would ever be written.
func commit_name(slot: int, typed: String) -> void:
	if naming != slot:
		return
	naming = -1
	typed_name = typed.strip_edges()
	# Down before the emit: the write rebuilds this screen from outside, and a
	# field still holding the focus would fire `focus_exited` into a screen
	# that is being taken off the tree.
	_close_field(slot)
	super._on_pressed("slot:%d" % slot)


## In save mode a row's click opens the name field first; the write happens
## when the field is submitted.
func _on_pressed(action: String) -> void:
	if mode == ShellHost.MODE_SAVE and may_save \
			and action.begins_with("slot:"):
		begin_naming(action.substr(5).to_int())
		return
	super._on_pressed(action)


## `Slot N  <its name, or what is in it>`.
func _caption(slot: int) -> String:
	var pattern: String = strings_own(OWN_SLOT)
	var name: String = pattern % (slot + 1) if pattern.contains("%d") \
		else pattern
	return "%s  %s" % [name, _row_text(slot)]


## Everything after the slot number: the name the player gave it and the
## stamp, or -- for a save with no name -- the campaign, the mission, the
## score and the stamp the screen has always shown.
func _row_text(slot: int) -> String:
	if host == null:
		return label_for(BANK_SAVES, ID_EMPTY)
	var header: Dictionary = host.slot_header(slot)
	var code: int = DictRead.as_int(header["result"])
	if code == CampaignCodec.Result.NO_FILE:
		return label_for(BANK_SAVES, ID_EMPTY)
	if code != CampaignCodec.Result.OK:
		# **Named through the matching table.** `CampaignCodec.Result` and
		# `SaveCodec.Result` do not agree numerically -- `TRUNCATED` is 3 here
		# and 1 there -- so a slot's refusal must be spelled by the codec that
		# refused it.
		return CampaignCodec.result_name(code)
	var stamp: String = DictRead.as_string(header[CampaignCodec.KEY_SAVED_AT_TEXT])
	var given: String = DictRead.as_string(
		header.get(CampaignCodec.KEY_NAME, ""))
	if not given.is_empty():
		return "%s  %s" % [given, stamp]
	var pattern_campaign: String = strings_own(
		CampaignSelectScreen.OWN_CAMPAIGN)
	var chain: int = DictRead.as_int(header["campaign"])
	var chain_text: String = pattern_campaign % chain \
		if pattern_campaign.contains("%d") else pattern_campaign
	var mission: String = DictRead.as_string(header["mission"])
	if not DictRead.as_bool(header["has_mission"]):
		# On the map, in the roster, at a briefing: the container carries the
		# campaign and no world.
		mission = "%s (%s)" % [mission, strings_own(OWN_NO_MISSION)]
	return "%s  %s  %d  %s" % [chain_text, mission,
		DictRead.as_int(header["score"]), stamp]
