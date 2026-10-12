class_name AgentSession
extends RefCounted

## One batch of commands at a time, stepped a line per frame.
##
## Everything here came over from the directory driver that preceded the
## control server, and it is deliberately **transport-independent**: the verbs,
## the counters and the screenshot know nothing about sockets, so the same
## table serves `POST /command` and would serve anything else.
##
## Every command goes in through [method Viewport.push_input], so
## [SliceMain]'s `_unhandled_input`, `_pick` and `_may_command_now` run exactly
## as they do under a real mouse and a real key -- what is synthetic is the
## hand, not the path.
##
## [constant VERBS] is the **one** source of truth for the command table:
## [method run_line] dispatches through [member _handlers], `GET /help` prints
## it, and `tests/test_agent.gd` requires the two to be the same set. The
## driver's own header table had already drifted to sixteen of thirty entries,
## which is the disease this cures.

## `idle` with no argument.
const IDLE_DEFAULT: int = 600

## Frames the **first** batch waits for a world or a screen before it runs
## anyway.
##
## The gate exists for one case: a `click_unit 0` sent the moment the port
## answers, before the cache has finished opening, would otherwise run against
## nothing. It must not outlive that case. A command can take the world down
## legitimately -- `ui` with no argument closes the campaign map, `location N`
## can name a mission the cache does not carry -- and a gate that kept waiting
## would park the batch for ever, hold its socket open and answer every later
## command, `quit` included, with 409. So it is bounded, and once the game has
## been up **once** it is gone for the life of the session: what it was ever
## waiting for is the start-up, and that does not happen twice.
const BOOT_LIMIT: int = 900

## Where `shot NAME` goes when `--agent-dir=` names nothing.
const DEFAULT_SHOT_DIR: String = "user://agent"

## The keys [method SliceMain._unhandled_input] reads, by the name a command
## uses.
## The one multi-character key name that still types a character.
const KEY_NAME_SPACE: String = "SPACE"
const SPACE_UNICODE: int = 0x20

const KEYS: Dictionary[String, int] = {
	"TAB": KEY_TAB,
	"F5": KEY_F5,
	"F8": KEY_F8,
	"F9": KEY_F9,
	"SPACE": KEY_SPACE,
	"Q": KEY_Q,
	"E": KEY_E,
	"T": KEY_T,
	"Y": KEY_Y,
	"G": KEY_G,
	"U": KEY_U,
	"D": KEY_D,
	"H": KEY_H,
	"R": KEY_R,
	"S": KEY_S,
	"W": KEY_W,
	"A": KEY_A,
	"F": KEY_F,
	"X": KEY_X,
	"C": KEY_C,
	"UP": KEY_UP,
	"DOWN": KEY_DOWN,
	"B": KEY_B,
	"BACKSPACE": KEY_BACKSPACE,
	"DELETE": KEY_DELETE,
	"F1": KEY_F1,
	"F2": KEY_F2,
	"F3": KEY_F3,
	"F4": KEY_F4,
	"LEFT": KEY_LEFT,
	"RIGHT": KEY_RIGHT,
	"1": KEY_1,
	"2": KEY_2,
	"3": KEY_3,
	"4": KEY_4,
	"NEXT_MISSION": KEY_BRACKETRIGHT,
	"PREV_MISSION": KEY_BRACKETLEFT,
	"ESCAPE": KEY_ESCAPE,
	# The Upgrade Menu's name box submits on it; the mission ends the turn.
	"ENTER": KEY_ENTER,
	"KP_ENTER": KEY_KP_ENTER,
	# The hidden code line and the letters its codes need ([CheatEntry]).
	# Nothing else in the mission view binds any of them: while the line is
	# open it owns the keyboard, so what is driven here is the real entry and
	# not a back door beside it.
	"BACKQUOTE": KEY_QUOTELEFT,
	"I": KEY_I,
	"K": KEY_K,
	"L": KEY_L,
	"M": KEY_M,
	"N": KEY_N,
	"O": KEY_O,
	"V": KEY_V,
}

## Verb -> the one line `GET /help` prints for it.
const VERBS: Dictionary[String, String] = {
	"key": "key NAME -- one press and release of a key _unhandled_input knows",
	"click": "click X Y -- a left click on the centre of map cell (X, Y)",
	"hover": "hover X Y -- a mouse motion at raw viewport pixels",
	"click_screen": "click_screen X Y -- a left click at raw viewport pixels",
	"wheel": "wheel N [X Y] -- N wheel notches (negative up) at raw viewport "
		+ "pixels; scrolls a list, zooms the camera over a map",
	"click_unit": "click_unit SLOT -- a left click on the cell a unit stands on",
	"buttons": "buttons -- every button on the screen, with its rectangle",
	"press": "press CAPTION -- push the button whose caption contains CAPTION",
	"map_click": "map_click X Y -- a click on one map field of a screen's window",
	"walk_to": "walk_to X Y -- a click on the reachable cell nearest (X, Y)",
	"cell": "cell X Y -- the control map's cell: height, field type, action point",
	"chance": "chance A B -- core's hit chance for unit A shooting unit B",
	"blobs": "blobs -- every live blob: kind, class, model, position, velocity",
	"watch": "watch N -- blobs on each of the next N drawn frames",
	"markers": "markers -- every cell the ground overlay drew on (docs/43 section 3)",
	"hud": "hud event|pad|ring|radar|panel N -- the battle interface's own "
		+ "controls; panel -1|1 is the place interface's previous|next",
	"wait": "wait N -- N drawn frames",
	"idle": "idle [MAX] -- frames until the picture is idle, at most MAX",
	"shot": "shot NAME -- writes NAME.png under --agent-dir=",
	"note": "note TEXT -- one line in the reply's log",
	"menu": "menu [NAME] -- raise the shell at one of its screens, or toggle it",
	"slot": "slot N [load|save [NAME...]] -- read or write one numbered slot",
	"option": "option NAME VALUE -- music|fx|speech|difficulty|gore|faithful|font|graphics|controls",
	"campaign": "campaign N -- begin chain N and load its first mission",
	"location": "location N -- click a location on the campaign map",
	"deploy": "deploy SLOT X Y [FACING] -- put one roster record on a "
		+ "deployment cell, facing 0..7 (turn 0 only)",
	"recall": "recall X Y -- take the pool candidate on a deployment cell "
		+ "back into the roster (turn 0 only)",
	"screen": "screen NAME -- drive the campaign flow past one step",
	"ui": "ui [NAME] -- put one campaign screen up, or close the one that is",
	"enter": "enter NAME -- load a mission past the location map",
	"gamecontrol": "gamecontrol SLOT VALUE -- SetGameControl (docs/20 section 7)",
	"cheat": "cheat NAME [on|off] -- a level tester's switch, or `nuke`",
	"sequence": "sequence N [framed] -- play logical sequence N full screen "
		+ "(or framed) from wherever the shell is",
	"quit": "quit -- leaves the game",
}

## `run_line` logs this for a verb outside [constant VERBS]. The suite reads
## the constant rather than the message, so the wording is free to change.
const UNKNOWN: String = "unknown command"

var _main: SliceMain = null
var _root: Window = null
var _view: AgentStateView = null
var _shot_dir: String = ""

var _index: int = 0
var _frame: int = 0
var _wait: int = 0
var _watch: int = 0
var _idle_left: int = 0
var _queue: PackedStringArray = PackedStringArray()
var _log: Array[String] = []
var _shots: PackedStringArray = PackedStringArray()
var _running: bool = false
var _leaving: bool = false
var _boot_wait: int = 0

## The game has been up at least once. **Not** reset by [method submit]: see
## [constant BOOT_LIMIT].
var _open: bool = false

## Verb -> the method that runs it. Built here rather than written as a
## `match` so the table and [constant VERBS] can be compared as sets: a verb
## with no handler, or a handler with no help line, then fails the run instead
## of being invisible.
##
## A [Callable] over a method holds an object **id**, not a reference, so this
## is not the `RefCounted` cycle that would leak the session at exit.
var _handlers: Dictionary[String, Callable] = {}


func _init(main: SliceMain, root: Window,
		shot_dir: String = DEFAULT_SHOT_DIR) -> void:
	_main = main
	_root = root
	_shot_dir = shot_dir if shot_dir != "" else DEFAULT_SHOT_DIR
	if main != null:
		_view = AgentStateView.new(main, root)
	_handlers = {
		"key": _v_key,
		"click": _v_click,
		"hover": _v_hover,
		"click_screen": _v_click_screen,
		"wheel": _v_wheel,
		"click_unit": _v_click_unit,
		"buttons": _v_buttons,
		"press": _v_press,
		"map_click": _v_map_click,
		"walk_to": _v_walk_to,
		"cell": _v_cell,
		"chance": _v_chance,
		"blobs": _v_blobs,
		"watch": _v_watch,
		"markers": _v_markers,
		"hud": _v_hud,
		"wait": _v_wait,
		"idle": _v_idle,
		"shot": _v_shot,
		"note": _v_note,
		"menu": _v_menu,
		"slot": _v_slot,
		"option": _v_option,
		"campaign": _v_campaign,
		"location": _v_location,
		"deploy": _v_deploy,
		"recall": _v_recall,
		"screen": _v_screen,
		"ui": _v_ui,
		"enter": _v_enter,
		"gamecontrol": _v_gamecontrol,
		"cheat": _v_cheat,
		"sequence": _v_sequence,
		"quit": _v_quit,
	}


# --- the batch ---------------------------------------------------------------

## Takes a batch. The caller has already refused a second one (409).
func submit(lines: PackedStringArray) -> void:
	_index += 1
	_queue = lines
	_log = []
	_shots = PackedStringArray()
	_wait = 0
	_watch = 0
	_idle_left = 0
	_running = true


func is_running() -> bool:
	return _running


## `quit` was run. The bridge answers the request first and leaves on the
## frame after: a command that is never replied to looks to the sender exactly
## like a game that died.
func is_leaving() -> bool:
	return _leaving


func frame() -> int:
	return _frame


func index() -> int:
	return _index


## One frame. Returns true on the frame the batch finishes.
##
## The gate on [method AgentStateView.booted] is what stands in for the old
## driver's 900-frame boot limit: a `click_unit 0` sent the moment the process
## is listening waits for a world rather than running against nothing. It is
## lifted for the rest of the batch as soon as the game is up, and given up on
## after [constant BOOT_LIMIT] frames -- see the constant for why a permanent
## gate is a wedge and not a wait.
func step() -> bool:
	_frame += 1
	if not _running:
		return false
	if _leaving:
		return true
	if not _open:
		if _view != null and _view.booted():
			_open = true
		else:
			_boot_wait += 1
			if _boot_wait < BOOT_LIMIT:
				return false
			_open = true
			_log.append("no world and no screen after %d frames; running anyway"
				% _boot_wait)
	if _wait > 0:
		_wait -= 1
		return false
	if _watch > 0:
		_watch -= 1
		_blobs()
		return false
	if _idle_left > 0:
		_idle_left -= 1
		if _view.busy():
			return false
		_idle_left = 0
	if not _queue.is_empty():
		var line: String = _queue[0]
		_queue.remove_at(0)
		run_line(line)
		return _leaving
	return true


## The document a finished batch answers with -- the same one the directory
## protocol wrote as `res-NNNN.json`.
func take_reply() -> Dictionary:
	_running = false
	return {
		"index": _index,
		"frame": _frame,
		"log": _log,
		"shots": _shots,
		"state": state(),
	}


## The snapshot, answerable at any moment -- including while a batch runs.
func state() -> Dictionary:
	if _view == null:
		return {}
	return _view.build(_frame)


func booted() -> bool:
	return _view != null and _view.booted()


func busy() -> bool:
	return _view != null and _view.busy()


## A command file's grammar: one verb per line, `#` a comment, blanks dropped.
static func parse_lines(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for raw: String in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		out.append(line)
	return out


## Which verbs are dispatched. Public so the suite can compare it with
## [constant VERBS] without reaching into a private member.
func handled() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for verb: String in _handlers.keys():
		out.append(verb)
	return out


func log_lines() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for line: String in _log:
		out.append(line)
	return out


## Runs one line. Public so a suite can drive a verb without a batch.
func run_line(line: String) -> void:
	var parts: PackedStringArray = line.split(" ", false)
	if parts.is_empty():
		return
	var verb: String = parts[0]
	if not _handlers.has(verb):
		_log.append("%s: %s" % [UNKNOWN, line])
		return
	var handler: Callable = _handlers[verb]
	var _answer: Variant = handler.call(parts, line)


# --- the screen --------------------------------------------------------------

## The current frame as PNG bytes, or nothing when there is no renderer.
##
## **The forced draw is the load-bearing line.** `get_texture()` hands back
## whatever is in the framebuffer, and inside `_process` that is a frame the
## renderer may not have redrawn since the last capture: every screenshot after
## the first in a session came back byte-identical to it, so a transition
## looked like a screen that had not changed when the tree said it had
## (docs/92 section 7.15).
func capture_png() -> PackedByteArray:
	if _root == null or DisplayServer.get_name() == "headless":
		return PackedByteArray()
	RenderingServer.force_draw(false)
	var texture: ViewportTexture = _root.get_texture()
	if texture == null:
		return PackedByteArray()
	var image: Image = texture.get_image()
	if image == null:
		return PackedByteArray()
	return image.save_png_to_buffer()


## Writes one capture under `--agent-dir=`. Returns the path, or "" on failure.
func save_shot(name: String) -> String:
	return write_shot(name, capture_png())


## The same, for a capture the caller already has -- `GET /shot?save=NAME`
## answers with the bytes **and** files them, and a second [method capture_png]
## would force a second draw and file a different frame from the one returned.
##
## **The name is a file name and is forced to be one.** It arrives off the
## network, and `?save=..%2Fsomething` would otherwise write outside
## `--agent-dir=` -- which now ships in the export rather than living in a
## driver the preset excluded.
func write_shot(name: String, bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	if safe_shot_name(name) != name:
		return ""
	var made: Error = DirAccess.make_dir_recursive_absolute(_shot_dir)
	if made != OK and made != ERR_ALREADY_EXISTS:
		return ""
	var path: String = "%s/%s.png" % [_shot_dir, name]
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_buffer(bytes)
	file.close()
	return ProjectSettings.globalize_path(path)


## A shot name with every path in it removed: the last segment of either
## separator, with `.` and `..` refused outright. Static and pure, so the suite
## pins the refusals without a filesystem.
static func safe_shot_name(name: String) -> String:
	var last: String = name.replace("\\", "/").get_file()
	if last == "." or last == "..":
		return ""
	return last


# --- the verbs ---------------------------------------------------------------

func _v_key(parts: PackedStringArray, _line: String) -> void:
	_key(parts[1] if parts.size() > 1 else "")


func _v_click(parts: PackedStringArray, _line: String) -> void:
	if parts.size() > 2:
		_click_cell(parts[1].to_int(), parts[2].to_int())
	else:
		_log.append("click: wants X and Y")


## `hover X Y` -- a mouse **motion** at raw viewport pixels. The location map
## answers a hover with a name and a ring, and a driver that could only click
## could not photograph either.
func _v_hover(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("hover: wants X and Y in pixels")
		return
	if _root == null:
		_log.append("hover: no window")
		return
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = Vector2(parts[1].to_float(), parts[2].to_float())
	motion.global_position = motion.position
	_root.push_input(motion, true)
	_wait = 1
	_log.append("hover (%.0f, %.0f)" % [motion.position.x, motion.position.y])


func _v_click_screen(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("click_screen: wants X and Y in pixels")
		return
	_push_click(Vector2(parts[1].to_float(), parts[2].to_float()))
	_log.append("click_screen (%s, %s)" % [parts[1], parts[2]])


## `wheel N [X Y]` -- N notches of the wheel, negative for up.
##
## It goes in through `push_input` like every other synthetic hand, so what is
## exercised is the real routing: whether the event reaches the screen at all
## depends on what `Control` the position lands on, which is exactly the
## question a list's scrolling turns on.
func _v_wheel(parts: PackedStringArray, _line: String) -> void:
	if _root == null:
		_log.append("wheel: no window")
		return
	var notches: int = parts[1].to_int() if parts.size() > 1 else 1
	var at: Vector2 = Vector2(parts[2].to_float(), parts[3].to_float()) \
		if parts.size() > 3 else _root.get_mouse_position()
	var button: int = MOUSE_BUTTON_WHEEL_DOWN if notches > 0 \
		else MOUSE_BUTTON_WHEEL_UP
	for _step: int in range(absi(notches)):
		var press: InputEventMouseButton = InputEventMouseButton.new()
		press.button_index = button as MouseButton
		press.pressed = true
		press.position = at
		press.global_position = at
		_root.push_input(press, true)
		var release: InputEventMouseButton = InputEventMouseButton.new()
		release.button_index = button as MouseButton
		release.pressed = false
		release.position = at
		release.global_position = at
		_root.push_input(release, true)
	_log.append("wheel %d at (%d, %d)" % [notches, int(at.x), int(at.y)])
	_wait = 1


func _v_click_unit(parts: PackedStringArray, _line: String) -> void:
	var slot: int = parts[1].to_int() if parts.size() > 1 else -1
	if _main.world == null:
		_log.append("click_unit: no mission is up")
		return
	var view: Dictionary = _main.world.unit_view(slot)
	if view.is_empty():
		_log.append("click_unit %d: no such unit" % slot)
		return
	_click_cell(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))


## Every button the screen that is up carries, with the rectangle it occupies.
##
## This is what makes `click_screen` usable from outside: a scenario reads the
## centres out of one reply and clicks them in the next, so the coordinates
## come from the layout rather than from a guess that would rot the first time
## a row moved.
func _v_buttons(_parts: PackedStringArray, _line: String) -> void:
	var screen: CampaignScreen = _main.screen_shown()
	if screen == null:
		_log.append("buttons: no screen is up")
		return
	for control: Button in _buttons_in(screen):
		var rect: Rect2 = control.get_global_rect()
		_log.append("button %-40s at (%.0f, %.0f) size (%.0f, %.0f) %s"
			% [control.text, rect.position.x, rect.position.y,
			rect.size.x, rect.size.y,
			"disabled" if control.disabled else "enabled"])


## `press CAPTION` -- push the button whose caption contains CAPTION. A
## screen's buttons are laid out in the plate's own units and the window is
## not, so clicking one by pixel means reproducing the stretch; naming it does
## not.
func _v_press(parts: PackedStringArray, line: String) -> void:
	if parts.size() <= 1:
		_log.append("press: wants part of a caption")
		return
	var screen: CampaignScreen = _main.screen_shown()
	if screen == null:
		_log.append("press: no screen is up")
		return
	var caption: String = line.substr(6).strip_edges()
	var wanted: String = caption.to_lower()
	for control: Button in _buttons_in(screen):
		if control.disabled or not control.text.to_lower().contains(wanted):
			continue
		_log.append("press %s" % control.text)
		control.pressed.emit()
		_wait = 1
		return
	_log.append("press: no enabled button matches %s" % caption)


## `map_click X Y` -- a click on a map **field** in the window of a screen
## drawn around one, which is what the location map takes.
## The ray is what a mouse goes through; this is the same answer handed
## straight to the screen.
func _v_map_click(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("map_click: wants a cell X and Y")
		return
	var screen: CampaignScreen = _main.screen_shown()
	if screen == null or not screen.takes_world_clicks():
		_log.append("map_click: no screen with a map window is up")
		return
	screen.world_click(Vector2i(parts[1].to_int(), parts[2].to_int()))
	_log.append("map_click (%s, %s) on %s" % [parts[1], parts[2],
		_main.screen_up()])
	_wait = 1


## Clicks the reachable cell nearest to `(x, y)`.
##
## The convenience is the harness's, not the game's: it reads the fill the
## selection already published and clicks one of its cells, so what reaches
## [SliceMain] is still a left click on a highlighted square.
func _v_walk_to(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("walk_to: wants X and Y")
		return
	var x: int = parts[1].to_int()
	var y: int = parts[2].to_int()
	var result: MoveMapResult = _main._last_query
	if result == null:
		_log.append("walk_to: nothing selected")
		return
	var best: Vector2i = Vector2i(-1, -1)
	var best_distance: int = 1 << 30
	for cy: int in range(result.height):
		for cx: int in range(result.width):
			if not result.is_reachable(cx, cy):
				continue
			var distance: int = maxi(absi(cx - x), absi(cy - y))
			if distance < best_distance:
				best_distance = distance
				best = Vector2i(cx, cy)
	if best.x < 0:
		_log.append("walk_to %d,%d: no reachable cell" % [x, y])
		return
	_log.append("walk_to %d,%d picks %d,%d (%d away)"
		% [x, y, best.x, best.y, best_distance])
	_click_cell(best.x, best.y)
	# **The click only raises the direction ring now** (docs/43 section 4):
	# the walk runs when a letter is chosen. A driver's `walk_to` still means
	# "walk there", so the ring is answered here with the direction of travel
	# -- `Combat.direction` from the unit's cell to the one picked, which is
	# the facing a straight path ends on. `hud ring N` is the command for a
	# scenario that wants to choose the facing itself.
	if _main._hud == null or not _main._hud.ring.is_up():
		return
	var slot: int = _main._selected
	if slot < 0 or _main.world == null or not _main.world.has_unit(slot):
		return
	var view: Dictionary = _main.world.unit_view(slot)
	var facing: int = Combat.direction(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]), best.x, best.y)
	if facing < 0:
		facing = 0
	var chosen: bool = _main.choose_ring_record(facing)
	_log.append("walk_to completes the ring facing %d: %s"
		% [facing, str(chosen)])


## One cell of the control map, as `core` holds it -- the height, the field
## type, the action point and the unit on it. It is how a terrain change is
## read back: a crushed wall, an opened door, a fire written into a cell.
func _v_cell(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("cell: wants X and Y")
		return
	if _main.world == null:
		_log.append("cell: no mission is up")
		return
	var x: int = parts[1].to_int()
	var y: int = parts[2].to_int()
	var view: Dictionary = _main.world.cell_view(x, y)
	if view.is_empty():
		_log.append("cell %d,%d: off the map" % [x, y])
		return
	_log.append("cell %d,%d: height %d, field type %d (%s), actpt %d, unit %d"
		% [x, y, DictRead.as_int(view["height"]),
			DictRead.as_int(view["field_type"]),
			DictRead.as_string(view["field_type_name"]),
			DictRead.as_int(view["action_point"]),
			DictRead.as_int(view["unit"])])


## What `core` says one unit's chance of hitting another is, so a run of misses
## can be read against the number behind them rather than guessed at.
func _v_chance(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("chance: wants a shooter and a target")
		return
	if _main.world == null:
		_log.append("chance: no mission is up")
		return
	var shooter: int = parts[1].to_int()
	var target: int = parts[2].to_int()
	_log.append("chance %d -> %d: %d%%"
		% [shooter, target, _main.world.hit_chance(shooter, target)])


func _v_blobs(_parts: PackedStringArray, _line: String) -> void:
	_blobs()


func _v_watch(parts: PackedStringArray, _line: String) -> void:
	_watch = maxi(1, parts[1].to_int() if parts.size() > 1 else 20)
	_log.append("watch %d frames" % _watch)


## `markers` -- every cell the ground overlay drew on, with its library and
## element (docs/43 section 3), so a screenshot's digits can be read against
## the fill behind them.
func _v_markers(_parts: PackedStringArray, _line: String) -> void:
	if _view == null:
		_log.append("markers: no game")
		return
	for row: Variant in _view.markers():
		var cells: Array = DictRead.as_array(row)
		_log.append("marker %s,%s %s[%s]"
			% [cells[0], cells[1], cells[2], cells[3]])


## `hud event N`, `hud pad N`, `hud ring N`, `hud radar +1|-1`: the interface's
## own controls, pressed by number rather than by pixel -- the plate's units
## are not the window's (docs/43).
func _v_hud(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("hud: wants event|pad|ring|radar|panel and a number")
		return
	var number: int = parts[2].to_int()
	match parts[1]:
		"event":
			_log.append("hud event %d %s" % [number,
				"pressed" if _main.press_hud_event(number) else "dark"])
		"pad":
			_log.append("hud pad %d %s" % [number,
				"pressed" if _main.press_pad_command(number) else "dark"])
		"ring":
			_log.append("hud ring %d %s" % [number,
				"chosen" if _main.choose_ring_record(number) else "no ring"])
		"radar":
			_log.append("hud radar scale %d" % _main.step_radar(number))
		"panel":
			# The band has two halves; a step outside them would land
			# wherever [method Deployment.cycle]'s modulo put it and be
			# logged as a cycle, so it is refused here rather than carried.
			if number != Deployment.PREV and number != Deployment.NEXT:
				_log.append("hud panel: N is %d|%d"
					% [Deployment.PREV, Deployment.NEXT])
			else:
				_log.append("hud panel %d %s" % [number,
					"cycled" if _main.cycle_deploy_slot(number) else "no pool"])
		_:
			_log.append("hud: unknown kind %s" % parts[1])
	_wait = 1


func _v_wait(parts: PackedStringArray, _line: String) -> void:
	_wait = maxi(1, parts[1].to_int() if parts.size() > 1 else 1)
	_log.append("wait %d" % _wait)


func _v_idle(parts: PackedStringArray, _line: String) -> void:
	_idle_left = maxi(1,
		parts[1].to_int() if parts.size() > 1 else IDLE_DEFAULT)
	_log.append("idle up to %d" % _idle_left)


func _v_shot(parts: PackedStringArray, _line: String) -> void:
	var name: String = parts[1] if parts.size() > 1 else "shot-%d" % _index
	if safe_shot_name(name) != name:
		_log.append("shot %s: a name, not a path" % name)
		return
	var path: String = save_shot(name)
	if path == "":
		_log.append("shot %s: no picture to save" % name)
		return
	_shots.append(path)
	_log.append("shot %s" % path)


func _v_note(_parts: PackedStringArray, line: String) -> void:
	_log.append(line.substr(5))


## `sequence N [framed]` -- one of the seven logical ids, from wherever the
## shell is (docs/92 section 7.19). The screen exits to what was there.
func _v_sequence(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 1:
		_log.append("sequence: wants a logical id (%s)"
			% str(SliceMain.SEQUENCE_IDS))
		return
	var id: int = parts[1].to_int()
	var framed: bool = parts.size() > 2 and parts[2] == "framed"
	var shown: CampaignScreen = _main.play_sequence(id, not framed,
		SliceMain.SEQUENCE_DEBUG)
	_log.append("sequence %d: %s" % [id,
		"playing %s" % str(_main.sequence_view()) if shown != null
		else "not in the cache, or no such id"])


func _v_quit(_parts: PackedStringArray, _line: String) -> void:
	_log.append("quit")
	_leaving = true


# --- the shell ---------------------------------------------------------------

## `menu [NAME]` -- raise the shell at one of its screens, or toggle it. With
## no argument it toggles, which is what `ESC` does.
func _v_menu(parts: PackedStringArray, _line: String) -> void:
	var name: String = parts[1] if parts.size() > 1 else ""
	if name.is_empty():
		if _main.shell.is_up():
			_main.close_shell()
			_log.append("menu: closed")
		else:
			var _up: CampaignScreen = _main.open_shell()
			_log.append("menu: %s" % _main.shell.screen)
		return
	if not ShellHost.SCREENS.has(name):
		_log.append("menu: no such screen %s" % name)
		return
	var _shown: CampaignScreen = _main.open_shell(name)
	_log.append("menu %s: %s" % [name, _main.screen_up()])


## `slot N [load|save [NAME...]]` -- write or read one numbered slot.
##
## Everything past `save` is the name the slot row shows, so a scenario can
## write the named saves the screen writes rather than only unnamed ones.
func _v_slot(parts: PackedStringArray, _line: String) -> void:
	var slot: int = parts[1].to_int() if parts.size() > 1 else 0
	var mode: String = parts[2] if parts.size() > 2 else ShellHost.MODE_SAVE
	var name: String = " ".join(parts.slice(3)) if parts.size() > 3 else ""
	if _main.campaign == null:
		_log.append("slot: the host is not ready")
		return
	if mode == ShellHost.MODE_LOAD:
		var loaded: bool = _main.load_slot(slot)
		_log.append("slot %d load: %s, mission %s" % [slot, str(loaded),
			_main.campaign.state.mission if _main.campaign.state != null
			else "-"])
		return
	if _main.campaign.state == null:
		_log.append("slot %d save: no campaign" % slot)
		return
	# **Through the game's own writer**, not through the host directly: that
	# is where the mid-sequence refusal, the `in_mission` gate on the blob,
	# the scenery pose record, the camera and the slot-ownership bookkeeping
	# live. Reaching past it wrote a save the interface would then read
	# differently from one the player had taken.
	var written: bool = _main._save_mission_to(slot,
		_main.world_to_save(), name)
	var header: Dictionary = _main.campaign.slot_header(slot)
	_log.append("slot %d save: %s, header %s" % [slot, str(written),
		JSON.stringify(header)])


## `option NAME VALUE` -- set one option and apply it, without the click path.
##
## The values are the same numbers the screen cycles through, so a scenario can
## put the game in a known configuration rather than clicking a row an unknown
## number of times.
func _v_option(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("option: wants NAME VALUE")
		return
	var name: String = parts[1]
	var value: String = parts[2]
	var settings: GameSettings = _main.settings
	match name:
		"music":
			settings.music_volume = value.to_int()
		"fx":
			settings.fx_volume = value.to_int()
		"speech":
			settings.speech_volume = value.to_int()
		"difficulty":
			settings.difficulty = clampi(value.to_int(),
				GameSettings.DIFFICULTY_MIN, GameSettings.DIFFICULTY_MAX)
			if _main.campaign != null and _main.campaign.state != null:
				_main.campaign.state.difficulty = settings.difficulty
		"gore":
			settings.gore_level = clampi(value.to_int(),
				GameSettings.GORE_MIN, GameSettings.GORE_MAX)
			if _main.world != null:
				_main.world.gore_level = settings.gore_level
		"faithful":
			settings.faithful = value.to_lower() in ["1", "true", "on", "yes"]
		"controls":
			# The one option a driven session cannot do without: the touch
			# input path is reached from nowhere else, and the screen's own row
			# cycles rather than sets.
			var mode: int = value.to_int()
			settings.control_mode = mode as GameSettings.ControlMode \
				if mode >= GameSettings.ControlMode.AUTO \
				and mode <= GameSettings.ControlMode.MOUSE \
				else GameSettings.ControlMode.AUTO
			if _main._touch != null:
				_main._touch.cancel()
		"font":
			# The one option a screenshot has to be able to set: the campaign
			# screens are laid out in the shipped plates' own units and the
			# readable face is a different size, so a picture taken under the
			# wrong one is not a picture of the layout.
			settings.game_font = value.to_lower() in ["1", "true", "on",
				"yes", "game"]
			_main._reapply_font()
		"graphics":
			# A number or a preset's name: original, smooth, enhanced.
			var named: int = ["original", "smooth", "enhanced"].find(
				value.to_lower())
			settings.graphics = GraphicsMode.clamped(named if named >= 0
				else value.to_int())
			_main.apply_graphics()
		_:
			_log.append("option: no such setting %s" % name)
			return
	settings.apply_audio(_main._audio, _main._events)
	var written: bool = settings.save_to_disk()
	_log.append("option %s = %s (written %s)" % [name, value, str(written)])


# --- the campaign ------------------------------------------------------------

## `campaign N` -- begin a new campaign in chain N and load its first mission.
##
## Chain 1 opens at `_C_100` with Bratt, West and Maxon in the roster; chain 2
## opens at `_C_140` with an empty one, which is what makes `_C_140`'s own four
## placed units the squad that reaches the pool at its debriefing.
func _v_campaign(parts: PackedStringArray, _line: String) -> void:
	var number: int = parts[1].to_int() if parts.size() > 1 else 2
	if _main.campaign == null:
		_log.append("campaign: the host is not ready")
		return
	var state: CampaignState = _main.campaign.start_new(number)
	if state == null or state.mission == "":
		_log.append("campaign %d: no such chain" % number)
		return
	_log.append("campaign %d -> %s, roster %d, open %s"
		% [number, state.mission, state.roster.used_slots(),
		str(_main.campaign.open_locations())])
	_enter(state.mission)


## `location N` -- click a location on the campaign map.
func _v_location(parts: PackedStringArray, _line: String) -> void:
	var id: int = parts[1].to_int() if parts.size() > 1 else 0
	if _main.campaign == null:
		_log.append("location: the host is not ready")
		return
	var clicked: Dictionary = _main.campaign.click_location(id)
	var kind: String = DictRead.as_string(clicked["kind"])
	var target: String = DictRead.as_string(clicked["target"])
	_log.append("location %d: %s %s" % [id, kind, target])
	if kind == CampaignMap.KIND_BATTLE and target != "":
		_enter(target)
		return
	if kind == CampaignMap.KIND_UPGRADE or kind == CampaignMap.KIND_DIALOGUE:
		# **Through the screen's own action**, not past it: a base opens with
		# its arrival flight and a dialogue with its cutscene, and a verb that
		# only moved the host's state would report a location as entered with
		# nothing on the screen (docs/27 section 2.7).
		_main._on_campaign_choice("location:%d:%s" % [id, kind])


## `deploy SLOT X Y [FACING]` -- put one roster record on a deployment cell.
func _v_deploy(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 3:
		_log.append("deploy: wants SLOT X Y [FACING]")
		return
	if _main.campaign == null:
		_log.append("deploy: the host is not ready")
		return
	var slot: int = parts[1].to_int()
	var x: int = parts[2].to_int()
	var y: int = parts[3].to_int()
	var facing: int = parts[4].to_int() if parts.size() > 4 else World.NO_FACING
	# The facing goes straight into the record (`aUI_SetUnit`'s fourth
	# argument) and from there into every direction table and the save, so
	# a number outside the ring is refused here rather than carried.
	if facing != World.NO_FACING \
			and (facing < 0 or facing >= Interact.FACING_DX.size()):
		_log.append("deploy: FACING is 0..%d" % (Interact.FACING_DX.size() - 1))
		return
	# Through the interface's own arm, so the panel's selection follows the
	# pool the way a click's would.
	var placed: Dictionary = _main.place_from_roster(slot, x, y, facing)
	var outcome: String = DictRead.as_string(placed["result"])
	if outcome != World.DEPLOY_OK:
		# **Named, not silent** -- docs/92 section 7.4 applies to deployment
		# too, and a refusal a driver could not see would look like a hang.
		_log.append("deploy %d at %d,%d refused: %s" % [slot, x, y, outcome])
		return
	_log.append("deploy %d at %d,%d -> unit slot %d"
		% [slot, x, y, DictRead.as_int(placed["slot"])])


## `recall X Y` -- the place interface's take-back, past the click.
func _v_recall(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("recall: wants X Y")
		return
	if _main.campaign == null:
		_log.append("recall: the host is not ready")
		return
	var x: int = parts[1].to_int()
	var y: int = parts[2].to_int()
	var taken: Dictionary = _main.recall_at(x, y)
	var outcome: String = DictRead.as_string(taken["result"])
	if outcome != World.RECALL_OK:
		_log.append("recall at %d,%d refused: %s" % [x, y, outcome])
		return
	_log.append("recall at %d,%d -> roster slot %d"
		% [x, y, DictRead.as_int(taken["slot"])])


## `screen NAME` -- drive the campaign flow past a screen this slice has no
## picture for: `debriefing`, `advance`, `replay`, `recruit`, `save`, `load`.
func _v_screen(parts: PackedStringArray, _line: String) -> void:
	var name: String = parts[1] if parts.size() > 1 else ""
	if _main.campaign == null:
		_log.append("screen: the host is not ready")
		return
	var host: CampaignHost = _main.campaign
	match name:
		"debriefing":
			var report: Dictionary = host.finish_mission(_main.world)
			_log.append("debriefing: score %d total %d, recovered %d, lost %s"
				% [DictRead.as_int(report["score"]),
				DictRead.as_int(report["total"]),
				(DictRead.as_array(report["recovered"])).size(),
				str(report["lost"])])
		"advance":
			var target: String = host.advance()
			_log.append("advance -> %s" % target)
			if target != "":
				_enter(target)
		"replay":
			var again: String = host.replay()
			_log.append("replay -> %s, roster %d"
				% [again, host.state.roster.used_slots()])
			if again != "":
				_enter(again)
		"recruit":
			var slot: int = host.recruit()
			_log.append("recruit -> slot %d, purse %d"
				% [slot, host.state.points(0)])
		"save":
			# Through the mission's own seam rather than [method
			# CampaignHost.save] directly: that one takes the simulation
			# alone, and a driven session must write what a played one
			# does -- the scenery's poses and the camera with it, and the
			# same refusal while a set piece is being drawn.
			_log.append("save: %s" % str(_main._save_mission_to(
				CampaignHost.QUICK_SLOT, _main.world)))
		"load":
			var decoded: Dictionary = host.load_save()
			_log.append("load: %s, mission %s, roster %d"
				% [CampaignCodec.result_name(DictRead.as_int(decoded["result"])),
				host.state.mission if host.state != null else "-",
				host.state.roster.used_slots() if host.state != null else 0])
		_:
			_log.append("screen: no such step %s" % name)


## Put one campaign screen up. The flow itself reaches them through `location`
## and the buttons; this is how a driver photographs one. `ui map` takes the
## mission down: the location map is a picture of the chain's own `.lev` and
## two 3D scenes cannot share a root.
func _v_ui(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 1:
		_main.close_campaign_screen()
		_log.append("ui: closed")
		return
	var shown: CampaignScreen = _main.show_campaign_screen(parts[1])
	_log.append("ui %s: %s" % [parts[1],
		"up" if shown != null else "no such screen"])


## A debugging entry past the location map, the way `--mission=` is a debugging
## entry past the campaign. The flow itself goes through `location`.
func _v_enter(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 1:
		_log.append("enter: wants a mission name")
		return
	if _main.campaign == null or _main.campaign.state == null:
		_log.append("enter: no campaign is running")
		return
	_main.campaign.state.mission = parts[1]
	_enter(parts[1])


## `SetGameControl` -- what a mission script writes to end a mission (docs/20
## section 7). Writing it here is the same act, and it is how a driver reaches
## a **won** debriefing without playing a mission to its end.
func _v_gamecontrol(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 2:
		_log.append("gamecontrol: wants SLOT VALUE")
		return
	if _main.world == null:
		_log.append("gamecontrol: no mission is up")
		return
	_main.world.game_control.set_slot(parts[1].to_int(), parts[2].to_int())
	_log.append("gamecontrol %s = %s" % [parts[1], parts[2]])


## `cheat NAME [on|off]` -- [Cheats] from the outside.
##
## With no second word a switch is **toggled**, which is what the typed code
## line does; `on` and `off` set it, so a scenario can put a switch into a
## known state without having read what it was. `cheat` alone reports.
func _v_cheat(parts: PackedStringArray, _line: String) -> void:
	if parts.size() <= 1:
		var live: PackedStringArray = _main.cheats.active()
		_log.append("cheat: %s"
			% ("none" if live.is_empty() else ", ".join(live)))
		return
	var name: String = parts[1].strip_edges().to_lower()
	if name == Cheats.ACTION_NUKE:
		_log.append("cheat nuke" if _main.apply_cheat_code(name)
			else "cheat nuke: no mission is up")
		return
	if not Cheats.known(name):
		_log.append("cheat: no such switch %s; known: %s"
			% [name, ", ".join(Cheats.NAMES)])
		return
	var on: bool = false
	if parts.size() > 2:
		var word: String = parts[2].strip_edges().to_lower()
		if word != "on" and word != "off":
			_log.append("cheat: wants on or off, not %s" % word)
			return
		on = word == "on"
		var _set: bool = _main.cheats.set_enabled(name, on)
	else:
		on = _main.cheats.toggle(name)
	_log.append("cheat %s %s" % [name, "on" if on else "off"])


# --- the shared helpers ------------------------------------------------------

func _key(name: String) -> void:
	if _root == null:
		_log.append("key: no window")
		return
	var upper: String = name.to_upper()
	if not KEYS.has(upper):
		_log.append("key: no such key %s" % name)
		return
	var press: InputEventKey = InputEventKey.new()
	press.keycode = KEYS[upper] as Key
	press.physical_keycode = press.keycode
	press.pressed = true
	# **A `LineEdit` types from `unicode`, not from the keycode.** Without it a
	# focused field takes the event and inserts nothing, which is what the
	# Upgrade Menu's name box did the first time it was driven from here. The
	# single-character names are exactly the printable ones, and the character
	# comes from the name **as written** -- taking it from the upper-cased
	# lookup key let the name box be typed in capitals and nothing else.
	if name.length() == 1:
		press.unicode = name.unicode_at(0)
	elif upper == KEY_NAME_SPACE:
		press.unicode = SPACE_UNICODE
	_root.push_input(press, true)
	var release: InputEventKey = InputEventKey.new()
	release.keycode = press.keycode
	release.physical_keycode = press.keycode
	release.pressed = false
	_root.push_input(release, true)
	_log.append("key %s" % upper)
	_wait = 1


## A left click at the centre of a map cell, in viewport pixels.
##
## The projection is the inverse of the pick's own ray: `_pick` casts the ray
## back and answers with the unit or the cell it lands on, so a click here is
## refused for exactly the reasons a player's would be.
func _click_cell(x: int, y: int) -> void:
	var at: Vector2 = _screen_of(x, y)
	if at.x < 0.0:
		_log.append("click %d,%d: not on screen" % [x, y])
		return
	_push_click(at)
	_log.append("click %d,%d at (%.0f, %.0f)" % [x, y, at.x, at.y])


## The press-and-release [method Viewport.push_input] a map click uses, without
## the projection: a plate's buttons are `Control`s and are hit by where they
## are on screen, not by which cell is under them.
func _push_click(at: Vector2) -> void:
	if _root == null:
		return
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	_root.push_input(press, true)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	_root.push_input(release, true)
	_wait = 1


func _screen_of(x: int, y: int) -> Vector2:
	var rig: CameraRig = _main.camera_rig()
	if rig == null:
		return Vector2(-1.0, -1.0)
	var camera: Camera3D = rig.camera()
	if camera == null or not camera.is_inside_tree():
		return Vector2(-1.0, -1.0)
	if _main.world == null:
		return Vector2(-1.0, -1.0)
	var cell: Dictionary = _main.world.cell_view(x, y)
	if cell.is_empty():
		return Vector2(-1.0, -1.0)
	var centre: Vector3 = WorldSpace.cell_centre(x, y,
		DictRead.as_int(cell["height"]))
	if camera.is_position_behind(centre):
		return Vector2(-1.0, -1.0)
	return camera.unproject_position(centre)


## Every live blob, field by field -- kind, class, model, position, velocity
## and the rotation triple. What a projectile is actually doing is not readable
## from a screenshot, and the pool is where the answer is.
func _blobs() -> void:
	var pool: BlobPool = _main._fx
	if pool == null:
		_log.append("blobs: no pool")
		return
	var queue: SequenceQueue = _main._sequences
	_log.append("-- frame %d, %d live, stage %s" % [_frame, pool.in_use(),
		queue.current() if queue != null else ""])
	for blob: Blob in pool.blobs():
		_log.append(("blob kind %d class %d model %d at (%d, %d, %d) "
			+ "v (%d, %d, %d) rot (%d, %d, %d) life %d aux %d")
			% [blob.kind, blob.class_id, blob.model, blob.x, blob.y, blob.z,
				blob.vx, blob.vy, blob.vz, blob.rot_x, blob.rot_y, blob.rot_z,
				blob.life, blob.aux])


## Load a mission and take the entry snapshot, then open it the way the
## campaign's own entry does: on turn 0 with the place interface up, or
## past it where there is nobody to place -- which, from the shell with no
## campaign started, is always: there is no pool, and the mission takes
## `--mission=`'s silent arm to turn 1.
func _enter(mission: String) -> void:
	# The shell would otherwise sit over the mission this just built and eat
	# every key and click after it. `enter` is already a debugging entry past
	# the campaign's own screens, so taking the shell down with them is the
	# same act rather than a new one.
	_main.shell.close()
	_main.close_campaign_screen()
	_main._build(mission)
	if _main.world == null:
		_log.append("enter %s: the cache does not carry it" % mission)
		return
	_main.campaign.begin_mission(_main.world)
	var cells: Array[Vector2i] = _main._landing_cells()
	var names: Array = []
	for cell: Vector2i in cells:
		names.append([cell.x, cell.y])
	_main._open_deployment_or_start()
	_log.append("enter %s: %d deployment cell(s) %s, turn %d"
		% [mission, cells.size(), str(names), _main.world.turn.turn])


func _buttons_in(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in node.get_children():
		var button: Button = child as Button
		if button != null:
			out.append(button)
		out.append_array(_buttons_in(child))
	return out
