class_name OptionsScreen
extends CampaignScreen

## The options -- the five that are connected, and not one that is not.
##
## The original has eight, and `Txtmod_h` 50..58 are their hover hints:
## *Toggle Speaker Position*, *Set Music Volume*, *Set FX Volume*, *Set
## Difficulty Level*, *Enemy Move on/off*, *Select Cursor and Animation Level*,
## *Select Animation Resolution*, *Set Speech Volume*. Four of those have
## nothing behind them in this remake -- there is no speaker layout, no speech
## track, no cursor level and no animation-resolution switch -- and docs/92
## section 7.1 classes a control that does nothing as a defect in the remake's
## own interface rather than as a period detail. So they are **absent**, and
## the four that remain are joined by two the original had no icon for: the
## gore level of `Game.opt`'s dword 10, and the `Faithful` preset section 7.1
## puts in front of the whole first list of reproduced defects.
##
## **Difficulty is where it is writable and nowhere else.** `Txtmod_h` 58 says
## it aloud -- *Set Difficulty Level (only in main map during campaign)* -- and
## the remake has a second reason: [member TurnState.ai_level] is item 5 of the
## canonical hash, so writing it into a running mission would move the hash of
## a game in progress and a slot saved before the change would stop matching
## the world it restores. Off the campaign map the row still appears and still
## does something: it sets what the **next** new campaign starts at. In a
## paused mission it is left out entirely.

## `Txtmod_h`'s option hints, which are the captions here.
const ID_MUSIC: int = 51
const ID_FX: int = 52
const ID_DIFFICULTY: int = 53
## The one that names the restriction aloud.
const ID_DIFFICULTY_ON_MAP: int = 58

## The remake's own, for the two the original has no icon for and for the
## values every row shows beside its caption.
const OWN_DIFFICULTY: String = "shell.difficulty.%d"
const OWN_GORE: String = "shell.gore"
const OWN_GORE_LEVEL: String = "shell.gore.%d"
const OWN_FAITHFUL: String = "shell.faithful"
const OWN_FONT: String = "shell.font"
const OWN_FONT_GAME: String = "shell.font.game"
const OWN_FONT_READABLE: String = "shell.font.readable"
const OWN_LANGUAGE: String = "shell.language"
const OWN_ON: String = "shell.on"
const OWN_OFF: String = "shell.off"


var settings: GameSettings = null
## The live campaign difficulty when the player is on the campaign map, or
## [constant NO_CAMPAIGN] anywhere else. Set by the host, because whether the
## difficulty is campaign state or a default is the host's decision and not
## this screen's (docs/92 section 7.15 S6).
const NO_CAMPAIGN: int = -1
var campaign_difficulty: int = NO_CAMPAIGN
## True in the pause shell, where the difficulty row is left out altogether.
var in_mission: bool = false
## The language the cache was built for. A **line, not a control**: the cache
## carries one `text/<language>.json`, so a selector would have one entry.
var language: String = Localization.FALLBACK_LANGUAGE

## `Menu_a.lcl`'s *Leveloptions* writes a setting as two gadgets: a
## right-aligned caption (`GUI_SetText ... 2_Format`) and, beside it, the
## changeable value on its **own** small field -- `GUI_SetButton`/
## `GUI_SetTextButton (..., 6_Library, ..., 2_Width)`, which is `32 + 32` = 64
## units of the name field's pieces. Only the value is a gadget; the caption is
## text. This screen keeps that shape and widens the field to `4_Width`,
## because its values are `-40.0 dB` where the original's are `on`.
const ROW_AT: Vector2 = Vector2(60.0, 96.0)
const ROW_STEP: float = 34.0
const VALUE_X: float = 300.0
const VALUE_WIDTH: int = 4
const CAPTION_DROP: float = 8.0

var _rows: Control = null
var _row_index: int = 0


func build() -> void:
	var title: Label = make_label(strings_own(OWN_OPTIONS))
	title.position = Vector2(8.0, 0.0)
	body().add_child(title)

	_rows = gui_layer()
	refresh()

	add_button("back", BANK_MISSION, ID_BACK, 0)


func refresh() -> void:
	if _rows == null or settings == null:
		return
	clear_children(_rows)
	_row_index = 0

	_add_row("music", label_for(BANK_SQUAD, ID_MUSIC),
		_volume_text(settings.music_volume))
	_add_row("fx", label_for(BANK_SQUAD, ID_FX),
		_volume_text(settings.fx_volume))
	if not in_mission:
		var on_map: bool = campaign_difficulty != NO_CAMPAIGN
		var level: int = campaign_difficulty if on_map else settings.difficulty
		# **The short caption, with the long one as the hint.** `Txtmod_h` 58
		# is *Set Difficulty Level (only in main map during campaign)*, and
		# the caption column ends where the value field begins: the
		# parenthetical ran under the field and was cut mid-word. It is the
		# sentence a hover hint is for, which is what `Txtmod_h` 50..58 are in
		# the original anyway.
		_add_row("difficulty", label_for(BANK_SQUAD, ID_DIFFICULTY),
			_named(OWN_DIFFICULTY, level),
			"" if on_map else label_for(BANK_SQUAD, ID_DIFFICULTY_ON_MAP))
	_add_row("gore", strings_own(OWN_GORE),
		_named(OWN_GORE_LEVEL, settings.gore_level))
	_add_row("faithful", strings_own(OWN_FAITHFUL),
		strings_own(OWN_ON if settings.faithful else OWN_OFF))
	# The shipped bitmap font cannot be scaled or antialiased, so at anything
	# past the 640x480 base it is drawn at hard-edged multiples. The period
	# look is one click away and the readable one is the default -- see
	# [member GameSettings.game_font].
	_add_row("font", strings_own(OWN_FONT),
		strings_own(OWN_FONT_GAME if settings.game_font
			else OWN_FONT_READABLE))
	# The language is a line and not a row: there is exactly one catalogue in
	# the cache, and a selector with one entry is an inert control.
	var _language: Label = gui_text("%s: %s" % [strings_own(OWN_LANGUAGE),
		language], ROW_AT + Vector2(0.0, ROW_STEP * float(_row_index)
			+ CAPTION_DROP), ALIGN_LEFT, INK_LABEL, _rows)


## One setting: the caption as text, the value on its own field.
##
## Clicking the field cycles the value -- the original's own icons are
## click-to-step too, and a slider would need a mouse-drag path the rest of
## these screens do not have. *hint* is what the field says on hover, for a
## row whose caption cannot say all of it.
func _add_row(action: String, caption: String, value: String,
		hint: String = "") -> void:
	var top: float = ROW_AT.y + ROW_STEP * float(_row_index)
	var _caption: Label = gui_text(caption,
		Vector2(ROW_AT.x, top + CAPTION_DROP), ALIGN_LEFT, INK_LABEL, _rows)
	var field: Button = gui_text_button("option:" + action, value,
		Vector2(VALUE_X, top), VALUE_WIDTH, _rows, Art.BUTTON_BASE_FIELD)
	if hint != "":
		var _hint: HintControl = hint_over(field, hint)
	_row_index += 1


## How loud the row is, as a share of the range rather than as attenuation.
##
## It read `-40.0 dB`, which is the floor and inaudible, and nothing on the
## screen said so; a player who clicked once from full volume saw a number
## change and heard the game go quiet with no way to read why.
func _volume_text(hundredths: int) -> String:
	var span: int = GameSettings.VOLUME_MAX - GameSettings.VOLUME_MIN
	var share: int = roundi(float(
		hundredths - GameSettings.VOLUME_MIN) * 100.0 / float(span))
	if share <= 0:
		return strings_own(OWN_OFF)
	return "%d%%" % share


## The name of one enumerated value. **No numeric fallback**: every value that
## reaches here has been clamped into range, so a missing key is a missing
## string and must come back as the marker the suites gate on rather than as a
## number that reads like a caption.
func _named(key_pattern: String, value: int) -> String:
	return strings_own(key_pattern % value)
