class_name CheatEntry
extends RefCounted

## The hidden way in to [Cheats] -- a silent code line, opened with `` ` ``.
##
## **Why not a rolling key buffer.** The classic shape -- watch the last few
## letters typed and match a word against them -- cannot work here: `W`, `A`,
## `S`, `D`, `Q`, `E`, `Y` and `G` pan and turn the camera and
## [constant HudTables.EVENT_KEYS] binds thirteen more to the interface's own
## columns, so typing a code would drive the camera across the map and press
## buttons on the way. So the entry takes the keyboard instead: while it is
## open every key reaches this and nothing else.
##
## **Silent** means silent. Nothing is drawn while a code is being typed and
## nothing is drawn for a code that does not match -- a caller reports only a
## code that did something, which is what keeps the system hidden from a
## player who has not been told it is there.
##
## Pure state: no node, no tree, no event type. [method feed] takes a key code
## and its unicode and answers what happened, so the whole thing is checked by
## a suite rather than by typing at a window.

## `` ` `` -- unbound everywhere else in the mission view, and the key every
## other game puts its console on.
const OPEN_KEY: int = KEY_QUOTELEFT
## Long enough for any code in [constant Cheats.NAMES] and short enough that a
## key held down cannot grow the buffer without bound.
const MAX_LENGTH: int = 16

## What [method feed] answers.
const IGNORED: String = ""
const OPENED: String = "opened"
const TYPED: String = "typed"
const CANCELLED: String = "cancelled"
const SUBMITTED: String = "submitted"

## What [method resolve] answers a code is.
const KIND_SWITCH: String = "switch"
const KIND_NUKE: String = "nuke"
const KIND_REPORT: String = "report"
const KIND_UNKNOWN: String = "unknown"

## The code that reports which switches are on. Not a switch itself, so it is
## outside [constant Cheats.NAMES].
const CODE_REPORT: String = "cheats"

var _open: bool = false
var _buffer: String = ""
## The code the last [constant SUBMITTED] carried, lower-cased and trimmed.
var _code: String = ""


func is_open() -> bool:
	return _open


func code() -> String:
	return _code


## What has been typed so far. For the suite: nothing draws it.
func buffer() -> String:
	return _buffer


func close() -> void:
	_open = false
	_buffer = ""


## One key press. Returns one of [constant IGNORED], [constant OPENED],
## [constant TYPED], [constant CANCELLED] or [constant SUBMITTED]; on the last
## of those [method code] holds what was typed.
##
## *unicode* is what builds the line, not *keycode*: a keyboard layout that
## puts a letter somewhere else still types that letter, which is the same
## reason the agent's synthetic keys carry one.
func feed(keycode: int, unicode: int) -> String:
	if not _open:
		if keycode != OPEN_KEY:
			return IGNORED
		_open = true
		_buffer = ""
		return OPENED
	match keycode:
		OPEN_KEY, KEY_ESCAPE:
			close()
			return CANCELLED
		KEY_ENTER, KEY_KP_ENTER:
			_code = _buffer.strip_edges().to_lower()
			close()
			return SUBMITTED
		KEY_BACKSPACE:
			if _buffer.length() > 0:
				_buffer = _buffer.substr(0, _buffer.length() - 1)
			return TYPED
	# Printable ASCII only, so a modifier or a function key cannot put a
	# control character into the line.
	if unicode >= 0x20 and unicode < 0x7F and _buffer.length() < MAX_LENGTH:
		_buffer += String.chr(unicode)
	return TYPED


## What *code* asks for, without doing it.
##
## Pure, and the one place a code word is turned into an action: [constant
## Cheats.NAMES] is the table for the switches, so a switch added there is
## typable with no change here.
##
## Returns `{"kind": String, "name": String}`; *name* is empty for everything
## but [constant KIND_SWITCH].
static func resolve(code: String) -> Dictionary:
	var word: String = code.strip_edges().to_lower()
	if word == CODE_REPORT:
		return {"kind": KIND_REPORT, "name": ""}
	if word == Cheats.ACTION_NUKE:
		return {"kind": KIND_NUKE, "name": ""}
	if Cheats.known(word):
		return {"kind": KIND_SWITCH, "name": word}
	return {"kind": KIND_UNKNOWN, "name": ""}
