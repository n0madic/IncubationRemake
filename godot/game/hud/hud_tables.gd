class_name HudTables
extends RefCounted

## The battle interface's tables, as data -- docs/43.
##
## Everything here is a transcription of `Incubation.exe`'s own dispatch
## tables and immediates: which sprite a cell state blits, which `ui.LIB`
## element a pad command wears, which interface event a button slot raises.
## `tests/fixtures/hud/cases_hud.json` carries the same tables read out of
## the binary by `tools/hud_tables.py`, and `test_hud.gd` compares the two --
## two readings of one executable that share no code (docs/92 section 5.1).
##
## Nothing in this file draws. The widgets under `game/hud/` and
## `game/overlay/` read it; a number that appears in one of them and not here
## is a number nobody checks.

# --- the ground overlay, `fcn.00417E70` -------------------------------------

## The interface libraries the overlay and the ring draw from. The digits'
## own library is named by the table below, entry by entry.
const LIB_MARKERS: String = "mp"
const LIB_FAR: String = "map"
const LIB_RING: String = "dir"

## Cell states the overlay knows (docs/23 section 10). The remake keeps them
## in [MoveMapResult] and in [method World.target_bands] rather than on the
## cell, so these are the values the two are translated to before the table
## below is consulted.
const STATE_PLAIN: int = 1
const STATE_REACHABLE: int = 10
const STATE_BAND_FIRST: int = 30
const STATE_SPECIAL_OBJECT: int = 35
const STATE_OWN_CELL: int = 50
const STATE_WARP: int = 60
const STATE_DEPLOY_LAST: int = 73

## The element a state blits, `{state: [library, element]}`. State 10 is the
## one entry whose element is the cell's own `+0x0C` -- the movement points
## left on arrival -- and is written as -1 here.
const DIGIT_FROM_CELL: int = -1
const STATE_SPRITES: Dictionary = {
	10: ["mp1", -1], 27: ["mp", 17], 30: ["mp", 43], 31: ["mp", 44],
	32: ["mp", 45], 33: ["mp", 46], 34: ["mp", 47], 35: ["mp1", 20],
	36: ["mp1", 21], 37: ["mp1", 19], 50: ["mp", 51], 60: ["mp1", 17],
	70: ["mp1", 18], 71: ["mp1", 18], 72: ["mp1", 18], 73: ["mp1", 18],
	100: ["mp", 51],
}
## The two states drawn only while the pointer is over a legal cell
## (`var_34h` at `0x00418254`/`0x00418263`).
const HOVER_GATED_STATES: Array[int] = [10, 60]
## The frame the hovered cell wears (`0x00418334`), and the two frames a unit
## standing on its own path alternates between (`0x004186BA`, `0x004186EC`).
##
## **Only the first of the three is ever drawn**, and 51 is drawn as state
## 50's element rather than as a path frame: no walk leaves a cell in state
## 100 while the overlay is blitted, so neither the path's mark nor this
## blink appears in play (docs/43 section 3.1). They stay here because they
## are the engine's own immediates and `hud_tables.py` checks them.
const HOVER_FRAME: int = 48
const PATH_FRAME: int = 51
const PATH_FRAME_ALT: int = 52
## Unit markers of the near view: the hit points as `mp[0..15]`, capped at 15
## (`0x004186D3`); `+0x41 == 1` -> 49; `+0x40 != 0` -> 50; `+0x41 == 5` -> 54.
const HP_DIGIT_MAX: int = 15
const MARKER_DEFENDING: int = 49
const MARKER_MALFUNCTION: int = 50
const MARKER_PANIC: int = 54
const ACTION_DEFENDING: int = 1
const ACTION_PANIC: int = 5
## Victory-point letters: a cell whose action point is 80..89 blits
## `mp[action_point - 63]` = 17..26 (`0x00418358`), far view only.
const VP_ACTION_POINT_LOW: int = 80
const VP_ACTION_POINT_HIGH: int = 89
const VP_LETTER_OFFSET: int = 63
## `0x17700` -- the camera height above which the far view's flags replace
## the near view's digits (`0x00418343`, `0x00418439`).
const ZOOM_GATE: int = 0x17700
## Far view: a visible unit draws `map[owner]` (players 0..3, 255 -> 4); a
## detected one draws `map[6]` at `map[4]`'s anchors (`0x00418580`, the quirk
## docs/43 section 3 records).
const FAR_FLAG_NEUTRAL: int = 4
const FAR_FLAG_HIDDEN: int = 6
const FAR_FLAG_BLINK: int = 5
const FAR_PLAYER_MAX: int = 3
## `[0x00523068]` steps every 100 ms (`fcn.0047F190`) and bit 0 is the blink.
const BLINK_PERIOD_SECONDS: float = 0.1

# --- the direction ring -----------------------------------------------------

## dir -> `dir.LIB` element: N, S, W, E and the dot on the four diagonals
## (jump table `0x00418F1C`). Element 5 is the X on the ninth record.
const RING_LETTERS: Array[int] = [0, 2, 1, 3, 4, 4, 4, 4]
const RING_CANCEL: int = 5
## The three colour tiers of `dir.LIB`: plain, hovered (+6), blocked (+12).
const RING_TIER_HOVER: int = 6
const RING_TIER_BLOCKED: int = 12
## `fcn.00406CA0` accepts the nearest record within this many pixels.
const RING_HIT_RADIUS: float = 600.0
## A hovered entry farther than this from the pointer stays dim
## (`0x00418CE0`).
const RING_HOVER_DISTANCE: float = 20.0
## World offsets of the nine records around the clicked object
## (`fcn.00406AA0`): 0xDDE along an axis, 0x93E on a diagonal, 500 down.
const RING_STRAIGHT: int = 0xDDE
const RING_DIAGONAL: int = 0x93E
const RING_DROP: int = 500
const RING_OFFSETS: Array[Vector2i] = [
	Vector2i(0, RING_STRAIGHT), Vector2i(-RING_STRAIGHT, 0),
	Vector2i(0, -RING_STRAIGHT), Vector2i(RING_STRAIGHT, 0),
	Vector2i(RING_DIAGONAL, -RING_DIAGONAL),
	Vector2i(-RING_DIAGONAL, RING_DIAGONAL),
	Vector2i(RING_DIAGONAL, RING_DIAGONAL),
	Vector2i(-RING_DIAGONAL, -RING_DIAGONAL), Vector2i(0, 0),
]
## Screen clamp: a letter is kept inside `[ox - 4, ox + w - 9]` by
## `[oy - 4, oy + h - 9]` (`0x00418CB9`).
const RING_CLAMP_LOW: int = -4
const RING_CLAMP_HIGH: int = -9
## The ring's three modes (`[0x00516310]`): after a reachable cell, after the
## selected unit itself, after a warp cell.
const RING_MODE_NONE: int = 0
const RING_MODE_MOVE: int = 1
const RING_MODE_TURN: int = 2
const RING_MODE_WARP: int = 3
## facing -> the 4096-unit angle the object turns to (`fcn.0046A6E0`).
const FACING_ANGLES: Array[int] = [0, 0xC00, 0x800, 0x400, 0x600, 0xE00,
	0x200, 0xA00]

# --- the command pad, `aUI.cpp` --------------------------------------------

## The click grid: `(404, 382)`, three columns of 30 and two rows of 48
## (`0x00473680`).
const PAD_ORIGIN: Vector2i = Vector2i(404, 382)
const PAD_STRIDE: Vector2i = Vector2i(30, 48)
const PAD_COLUMNS: int = 3
const PAD_ROWS: int = 2
## (column, row) -> command (`0x00472120`, docs/29 section 1.1).
const PAD_COMMANDS: Dictionary = {
	Vector2i(0, 0): 1, Vector2i(0, 1): 3, Vector2i(1, 0): 2,
	Vector2i(1, 1): 7, Vector2i(2, 0): 5, Vector2i(2, 1): 8,
}
## command -> `ui.LIB` element when available; hover is element + 1 and an
## unavailable command draws element 0, the empty socket (`0x00472570`).
const PAD_SPRITES: Dictionary = {1: 2, 2: 4, 3: 8, 5: 6, 7: 10, 8: 12}
const PAD_SOCKET: int = 0
## command -> `Txtmod_h` hint (`0x004720F8`).
const PAD_CAPTIONS: Dictionary = {1: 40, 2: 43, 3: 41, 5: 42, 7: 44, 8: 45}
const COMMAND_DEFEND: int = 1
const COMMAND_HEAL: int = 2
const COMMAND_STIMULANT: int = 3
const COMMAND_WEAPON_MODE: int = 5
const COMMAND_REST: int = 7
const COMMAND_USE: int = 8

# --- the button columns, `aMI.cpp` -----------------------------------------

## The two click columns `x 11..49` and `594..632`, rows of 31 from y 66 to
## 345 (`0x00451240`); the sprites are blitted at `(11 | 594, 66 + 31 row)`.
const COLUMN_X: Array[int] = [11, 594]
const COLUMN_TOP: int = 66
const COLUMN_ROW_HEIGHT: int = 31
const COLUMN_ROWS: int = 9
const COLUMN_WIDTH: int = 38
## (column, row) -> interface event of `0x00453900`; 0 is an empty slot.
const COLUMN_EVENTS: Array[Array] = [[8, 7, 6, 5, 11, 15, 16, 0, 9],
	[1, 3, 4, 2, 12, 14, 13, 0, 10]]
## event -> `mi.LIB` element when available; hover is element + 1; an empty
## or unavailable slot draws 31 (`0x00451A70`, `0x00451DBE`).
const COLUMN_SPRITES: Dictionary = {1: 20, 2: 28, 3: 24, 4: 26, 5: 4, 6: 2,
	7: 8, 8: 6, 9: 16, 10: 12, 11: 14, 12: 10, 13: 18, 14: 22, 15: 33, 16: 35}
const COLUMN_EMPTY: int = 31
## event -> `Txtmod_h` hint drawn at (60, 22) (`0x00451770`); event 13 has
## two, by the magnifier's state.
const COLUMN_CAPTIONS: Dictionary = {1: 38, 2: 34, 3: 36, 4: 35, 5: 25,
	6: 24, 7: 27, 8: 26, 9: 29, 10: 28, 11: 31, 12: 30, 13: 32, 14: 37,
	15: 39, 16: 46}
const CAPTION_MAGNIFIER_OFF: int = 33
const CAPTION_AT: Vector2i = Vector2i(60, 22)

## A hint with its key after it, or the hint alone when the button has none.
static func with_key(caption: String, key: String) -> String:
	if caption == "" or key == "":
		return caption
	return "%s  [%s]" % [caption, key]
## The sixteen events by name (docs/29 section 1.2 as corrected by docs/43).
const EVENT_FREE_CAMERA: int = 1
const EVENT_UNIT_VIEW: int = 2
const EVENT_MAP_VIEW: int = 3
const EVENT_USER_VIEW: int = 4
const EVENT_LOAD: int = 5
const EVENT_SAVE: int = 6
const EVENT_RECALL_POSITION: int = 7
const EVENT_REMIND_POSITION: int = 8
const EVENT_GIVE_UP: int = 9
const EVENT_NEXT_PLAYER: int = 10
const EVENT_BRIEFING: int = 11
const EVENT_NEXT_UNIT: int = 12
const EVENT_MAGNIFIER: int = 13
const EVENT_VISIBLE_ENEMY: int = 14
const EVENT_UNDO_TURN: int = 15
const EVENT_UNDO_MISSION: int = 16
## The save slots the four position and undo events read and write
## (`0x0041DA20`'s commands 5..8): remind/recall, the turn's autosave and the
## mission's.
## **The original's keys, and the one place the remake binds them.**
##
## `tools/hud_tables.py` reads the two keyboard translators and their switch
## tables out of `Incubation.exe`; docs/43 sections 5.1 and 5.2 print the same
## bindings. Give Up is the sole deliberate exception: the original binds it
## to Escape, while the remake keeps Escape as the menu key.
##
## They used to be written twice: once as label strings here and once as
## `keycode ==` branches in [SliceMain]'s `_unhandled_input`, with a comment
## saying "the two must be changed together" and nothing that made them. So a
## re-bound key left the interface confidently telling the player to press the
## old one. **This table is now the binding**: `_unhandled_input` dispatches
## through [method event_for_key] and [method command_for_key], and the hint
## is [method key_label] of the same number, so the key that acts and the key
## that is shown cannot differ.
##
## The hints used to be a line of running text across the playing screen,
## under the developer line, which is neither where the original puts a hint
## nor somewhere a player looks. A button that has a key says so when the
## pointer is on it; a button that has none says nothing.
const EVENT_KEYS: Dictionary[int, int] = {
	EVENT_FREE_CAMERA: KEY_1,
	EVENT_UNIT_VIEW: KEY_2,
	EVENT_MAP_VIEW: KEY_3,
	EVENT_USER_VIEW: KEY_4,
	EVENT_LOAD: KEY_F4,
	EVENT_SAVE: KEY_F3,
	EVENT_RECALL_POSITION: KEY_F2,
	EVENT_REMIND_POSITION: KEY_F1,
	EVENT_NEXT_PLAYER: KEY_ENTER,
	EVENT_BRIEFING: KEY_B,
	EVENT_NEXT_UNIT: KEY_TAB,
	EVENT_MAGNIFIER: KEY_G,
	EVENT_VISIBLE_ENEMY: KEY_T,
	EVENT_UNDO_TURN: KEY_BACKSPACE,
	EVENT_UNDO_MISSION: KEY_DELETE,
}
## The original command-pad letters. Camera movement stays on the arrows and
## mouse, so D/S/W are not shared with a second action.
const COMMAND_KEYS: Dictionary[int, int] = {
	COMMAND_DEFEND: KEY_D,
	COMMAND_HEAL: KEY_H,
	COMMAND_STIMULANT: KEY_S,
	COMMAND_WEAPON_MODE: KEY_W,
	COMMAND_REST: KEY_R,
	COMMAND_USE: KEY_U,
}


## What a key is called on the plate. Godot's own name for the code, so
## `KEY_BACKSPACE` reads `Backspace` and `KEY_SPACE` reads `Space`.
static func key_label(keycode: int) -> String:
	return "" if keycode == 0 else OS.get_keycode_string(keycode)


## The key a column button carries, as text, or `""` for one with none.
static func event_key(number: int) -> String:
	return key_label(DictRead.as_int(EVENT_KEYS.get(number, 0)))


## The same for a pad socket.
static func command_key(number: int) -> String:
	return key_label(DictRead.as_int(COMMAND_KEYS.get(number, 0)))


## The column button a key presses, or `-1`. The reverse of [constant
## EVENT_KEYS], walked rather than stored: fifteen entries, once a keystroke.
static func event_for_key(keycode: int) -> int:
	# Both Return keys become WM_CHAR 13 in the original. Godot keeps the
	# keypad key distinct, so fold it back to the key printed on the HUD.
	if keycode == KEY_KP_ENTER:
		keycode = KEY_ENTER
	for number: int in EVENT_KEYS:
		if EVENT_KEYS[number] == keycode:
			return number
	return -1


## The same for the pad's six.
static func command_for_key(keycode: int) -> int:
	for number: int in COMMAND_KEYS:
		if COMMAND_KEYS[number] == keycode:
			return number
	return -1


const SLOT_REMIND: int = 32
const SLOT_UNDO_TURN: int = 33
const SLOT_UNDO_MISSION: int = 31

# --- the radar --------------------------------------------------------------

const LIB_RADAR: String = "sm"
## The green screen the radar is clipped to (`0x00451E72`) and the point the
## picture turns about (`0x00451EF2`).
const RADAR_CLIP: Rect2i = Rect2i(501, 389, 90, 66)
const RADAR_CENTRE: Vector2i = Vector2i(546, 422)
## `ox = cx * 90 / scale + 501`, `oy = 455 - cy * 66 / scale` (`0x00451E00`):
## the scale is how many fields the screen's width spans. Default 40
## (`0x004533BD`); a click in the radar's rectangle steps it by 5 within
## 20..80, right half in, left half out (`0x00452390`).
const RADAR_SCALE_DEFAULT: int = 40
const RADAR_SCALE_STEP: int = 5
const RADAR_SCALE_MIN: int = 20
const RADAR_SCALE_MAX: int = 80
const RADAR_CLICK: Rect2i = Rect2i(501, 389, 90, 66)
const RADAR_SPLIT_X: int = 546
## The compass letters and where they sit before the turn (`0x00450C65`).
const RADAR_COMPASS: Array[Vector2i] = [Vector2i(546, 397), Vector2i(546, 447),
	Vector2i(521, 422), Vector2i(571, 422)]
const RADAR_COMPASS_SPRITES: Array[int] = [6, 7, 8, 9]
## Unit marks: own 0 (1 with no points, 4 selected), other side 2 on a plain
## cell and 3 on a marked one, detected 5.
const RADAR_OWN: int = 0
const RADAR_OWN_NO_MP: int = 1
const RADAR_OWN_SELECTED: int = 4
const RADAR_OTHER_PLAIN: int = 2
const RADAR_OTHER_MARKED: int = 3
const RADAR_DETECTED: int = 5
## The lamp at (616, 453): 11 while an enemy is visible, 10 while one is only
## detected (`0x00452329`).
const RADAR_LAMP_AT: Vector2i = Vector2i(616, 453)
const RADAR_LAMP_VISIBLE: int = 11
const RADAR_LAMP_DETECTED: int = 10

# --- the frame and the panel ------------------------------------------------

## The 3D window `(60, 34)` by 520x340 (`0x0041A49E`), and the plate's four
## strips around it.
const WINDOW: Rect2i = Rect2i(60, 34, 520, 340)
## The turn is written right-aligned at (560, 22) (`0x0041B20B`), red within
## three turns of a `SetTurnControl` par (`0x0041B1D1`).
const TURN_TEXT_AT: Vector2i = Vector2i(560, 22)
const TURN_RED_WITHIN: int = 3
## The unit panel is drawn at (60, 415) (`0x004739B9`), its name line at
## y 397, and its five blocks at these offsets (`0x004757D9`..`0x004758C9`).
const PANEL_ORIGIN: Vector2i = Vector2i(60, 415)
const PANEL_NAME_Y: int = 397
const PANEL_BLOCK_HP: Vector2i = Vector2i(0, 10)
const PANEL_BLOCK_EXPERIENCE: Vector2i = Vector2i(75, -10)
const PANEL_BLOCK_WEAPON: Vector2i = Vector2i(145, 0)
const PANEL_BLOCK_MOVEMENT: Vector2i = Vector2i(235, 15)
const PANEL_BLOCK_SKILLS: Vector2i = Vector2i(275, -10)

# --- the place interface, `aPI.cpp` (docs/43 section 5.5) -------------------

## The band of the panel a click cycles the pool in, `fcn.004637c0`: the
## pointer's y strictly between 385 and 459 (`0x004637D1`, `0x004637C5`),
## its x strictly between 47 and 220 for the *previous* soldier
## (`0x004637E9`, `0x004637DD`) and strictly between 220 and 394 for the
## *next* (`0x004637F9`, `0x00463805`). Inclusive ranges in the plate's
## units; x 220 answers nobody.
const PANEL_CLICK_Y: Vector2i = Vector2i(386, 458)
const PANEL_PREV_X: Vector2i = Vector2i(48, 219)
const PANEL_NEXT_X: Vector2i = Vector2i(221, 393)
## What the band answers (`0x004637EE`, `0x0046380C`).
const PANEL_CLICK_PREV: int = 2
const PANEL_CLICK_NEXT: int = 1
## The facing a placed soldier gets from the **screen** quadrant of the
## click -- the screen's halves (`fcn.00419a50/60` at `0x00463552/60`), not
## the window's. Keyed by `(x >= width / 2, y >= height / 2)`: the left
## column is `4 + 2 * (y < half)` (`0x00463572/75`), the right one
## `7 - 2 * (y < half)` (`0x0046358E/91`).
const DEPLOY_FACING_BY_QUADRANT: Dictionary[Vector2i, int] = {
	Vector2i(0, 1): 4, Vector2i(0, 0): 6, Vector2i(1, 0): 5, Vector2i(1, 1): 7,
}
## `markDeploymentCells` `0x00431118`: a deployment cell of player `p` is
## in state `0x46 + p` -- 70..73, which the overlay blits as `mp1[18]`.
const STATE_DEPLOY_FIRST: int = 70
## `uicons.LIB` elements the panel draws.
const LIB_ICONS: String = "uicons"
const LIB_WEAPONS: String = "uweapons"
const LIB_MUNITION: String = "umun"
const LIB_INVENTORY: String = "inv"
const ICON_HP_FRAME: int = 11
const ICON_CLASS_MARINE: int = 12
const ICON_CLASS_ALIEN: int = 13
const ICON_CLASS_ROBOT: int = 26
const ICON_ARMOUR_RUNG: int = 9
const ICON_WOUND_DOT: int = 10
const ICON_EXPERIENCE_FRAME: int = 8
const ICON_TIER_DISC: int = 18
const ICON_DECORATION_FIRST: int = 16
const ICON_WEAPON_FRAME: int = 7
const ICON_LAMP_A: int = 25
const ICON_LAMP_B: int = 24
const ICON_MALFUNCTION_FIRST: int = 21
const ICON_MOVEMENT_DISC: int = 17
## `Txtmod_h` 70..73 -- the status word after the name.
const TEXT_PANIC: int = 70
const TEXT_LIGHT_PANIC: int = 71
const TEXT_HOT: int = 72
const TEXT_NO_AMMO: int = 73
## The interface's own bank (`0x00470FE0` reads module 3).
const BANK_INTERFACE: String = "Txtmod_h"

# --- the watched player's progress bar ---------------------------------------

## `aViewPlayer.cpp`'s bar (docs/43 section 7). `fcn.0047DA00` blits
## twenty-two `vp.LIB` capsules on row 406 from x 59, one element width apart,
## and lights `fill + 1` of them where `fill = acted * 21 / live`.
const LIB_PROGRESS: String = "vp"
const PROGRESS_ORIGIN: Vector2i = Vector2i(59, 406)
const PROGRESS_SEGMENTS: int = 22
const PROGRESS_STEPS: int = 21
const PROGRESS_LIT: int = 0
const PROGRESS_DARK: int = 1
## `0x0047C03F` -- the click one step of the bar makes. **In the cache** since
## `CONVERTER_VERSION` 0.18.0 (`sound.VIEW_PLAYER_CUES`); the game reads it
## through [method AudioTables.view_player_cue] and this constant is the name
## the suites check that against.
const PROGRESS_WAVE: String = "progress.wav"

# --- the plate ---------------------------------------------------------------

const PLATE: String = "plate_5"
const PLATE_SIZE: Vector2i = Vector2i(640, 480)
## How the plate is cut (docs/43 section 8). `fixed` pieces keep their pixel
## size and their corner; a `band` is tiled across the width the canvas has
## beyond 640; a `filler` is a slice of the column tiled down the height it
## has beyond 480. The fixture carries the same list from `hud_tables.py`.
const PLATE_SEGMENTS: Array[Dictionary] = [
	{"name": "top_left", "region": Rect2i(0, 0, 200, 34),
		"anchor": "top_left", "kind": "fixed"},
	{"name": "top_band", "region": Rect2i(200, 0, 64, 34),
		"anchor": "top_left", "kind": "band"},
	{"name": "top_right", "region": Rect2i(264, 0, 376, 34),
		"anchor": "top_right", "kind": "fixed"},
	{"name": "left_column", "region": Rect2i(0, 34, 60, 340),
		"anchor": "top_left", "kind": "fixed"},
	{"name": "left_filler", "region": Rect2i(0, 205, 60, 1),
		"anchor": "top_left", "kind": "filler"},
	{"name": "right_column", "region": Rect2i(580, 34, 60, 340),
		"anchor": "top_right", "kind": "fixed"},
	{"name": "right_filler", "region": Rect2i(580, 205, 60, 1),
		"anchor": "top_right", "kind": "filler"},
	{"name": "bottom_left", "region": Rect2i(0, 374, 300, 106),
		"anchor": "bottom_left", "kind": "fixed"},
	{"name": "bottom_band", "region": Rect2i(300, 374, 40, 106),
		"anchor": "bottom_left", "kind": "band"},
	{"name": "bottom_right", "region": Rect2i(340, 374, 300, 106),
		"anchor": "bottom_right", "kind": "fixed"},
]


## The sprite a cell state draws, or an empty array for a state that draws
## nothing. *mp_left* fills in state 10's digit.
static func sprite_for_state(state: int, mp_left: int) -> Array:
	if not STATE_SPRITES.has(state):
		return []
	var entry: Array = STATE_SPRITES[state]
	var element: int = DictRead.as_int(entry[1])
	if element == DIGIT_FROM_CELL:
		element = mp_left
	return [DictRead.as_string(entry[0]), element]


## The `map.LIB` flag the far view gives a unit's owner.
static func far_flag(player: int) -> int:
	if player < 0 or player > FAR_PLAYER_MAX:
		return FAR_FLAG_NEUTRAL
	return player


## The `mp.LIB` letter of a victory-point cell, or -1 for any other.
static func vp_letter(action_point: int) -> int:
	if action_point < VP_ACTION_POINT_LOW or action_point > VP_ACTION_POINT_HIGH:
		return -1
	return action_point - VP_LETTER_OFFSET


## The command a pad click at (column, row) means, or 0 off the pad.
static func pad_command(column: int, row: int) -> int:
	return DictRead.as_int(PAD_COMMANDS.get(Vector2i(column, row), 0))


## The interface event a column slot raises, or 0 for an empty slot.
static func column_event(column: int, row: int) -> int:
	if column < 0 or column >= COLUMN_EVENTS.size():
		return 0
	var rows: Array = COLUMN_EVENTS[column]
	if row < 0 or row >= rows.size():
		return 0
	return DictRead.as_int(rows[row])


## Where a column slot's sprite is blitted, in the plate's units.
static func column_slot_at(column: int, row: int) -> Vector2i:
	return Vector2i(COLUMN_X[column], COLUMN_TOP + COLUMN_ROW_HEIGHT * row)


## Where a pad socket is blitted, in the plate's units.
static func pad_socket_at(column: int, row: int) -> Vector2i:
	return PAD_ORIGIN + Vector2i(PAD_STRIDE.x * column, PAD_STRIDE.y * row)


## The 3D window on a canvas of *canvas* units: the original's 60/34 margins
## with whatever the canvas has beyond 640x480 given to the window.
static func window_for(canvas: Vector2) -> Rect2:
	return Rect2(float(WINDOW.position.x), float(WINDOW.position.y),
		canvas.x - float(PLATE_SIZE.x - WINDOW.size.x),
		canvas.y - float(PLATE_SIZE.y - WINDOW.size.y))
