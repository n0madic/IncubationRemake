extends SceneTree

## Slice G's control harness: the slice driven from outside, one command file
## at a time, with a screenshot and a state dump written back for each.
##
##     godot --path godot --script res://tour.gd --resolution 1280x800 -- \
##         --dir=/absolute/path/tour --mission=_C_140
##
## It exists because the by-hand pass the plan's slice G asks for cannot be
## played by hand here: there is no one at the keyboard. Every command below
## goes in through [method Viewport.push_input], so [SliceMain]'s
## `_unhandled_input`, `_pick` and `_may_command_now` run exactly as they do
## under a real mouse and a real key -- what is synthetic is the hand, not the
## path. Nothing under `game/` or `core/` knows this file exists, and the
## shipping preset excludes it beside `shot.gd`.
##
## **The directory is the whole protocol.** The driver waits for
## `cmd-0001.txt`, runs its lines, writes `res-0001.json` beside it, and then
## waits for `cmd-0002.txt`. Write each command file with `mv` from a
## neighbouring temporary name, so a half-written file is never read.
##
## | Line | What it does |
## |---|---|
## | `key NAME` | one press and release of a key `_unhandled_input` knows |
## | `click X Y` | a left click on the centre of map cell `(X, Y)` |
## | `click_unit SLOT` | a left click on the cell a unit stands on |
## | `click_screen X Y` | a left click at raw viewport pixels |
## | `hover X Y` | a mouse motion at raw viewport pixels |
## | `buttons` | every button on the screen that is up, with its rectangle |
## | `press CAPTION` | push the button whose caption contains CAPTION |
## | `map_click X Y` | a click on one map field of a screen's own window |
## | `walk_to X Y` | a left click on the reachable cell nearest `(X, Y)` |
## | `cell X Y` | the control map's cell: height, field type, action point |
## | `blobs` | every live blob: kind, class, model, position, velocity, rotation |
## | `watch N` | `blobs` on each of the next N drawn frames |
## | `chance A B` | `core`'s hit chance for unit A shooting unit B |
## | `wait N` | N drawn frames |
## | `idle [MAX]` | frames until the picture is idle, at most MAX |
## | `shot NAME` | writes `NAME.png` beside the command files |
## | `note TEXT` | one line in the reply's log |
## | `menu [NAME]` | raise the shell at one of its screens, or toggle it |
## | `slot N [load\|save]` | read or write one of the eight numbered slots |
## | `option NAME VALUE` | set one option and apply it |
## | `quit` | leaves the game |
##
## A line starting with `#` is a comment. Every reply carries the whole state
## the pass reports on -- the units, the queue, the pool by kind, the overlay,
## the camera and the status line -- so what a screenshot is claimed to show
## can be read as numbers beside it.

## `cmd-%04d.txt` / `res-%04d.json`.
const COMMAND_NAME: String = "cmd-%04d.txt"
const REPLY_NAME: String = "res-%04d.json"

## `idle` without an argument.
const IDLE_DEFAULT: int = 600

## The driver leaves rather than hanging when nothing writes a command file.
const SILENCE_LIMIT_MSEC: int = 20 * 60 * 1000

## Frames to give `main.tscn` before the first command file is looked for.
const BOOT_LIMIT: int = 900

## The keys `SliceMain._unhandled_input` reads, by the name a command uses.
const KEYS: Dictionary[String, int] = {
	"TAB": KEY_TAB,
	"F5": KEY_F5,
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
	"B": KEY_B,
	"BACKSPACE": KEY_BACKSPACE,
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
}

var _main: SliceMain = null
var _dir: String = ""
var _index: int = 1
var _frame: int = 0
var _boot: int = 0
var _wait: int = 0
var _watch: int = 0
var _idle_left: int = 0
var _queue: PackedStringArray = PackedStringArray()
var _log: Array[String] = []
var _shots: PackedStringArray = PackedStringArray()
var _running_reply: bool = false
var _last_seen_msec: int = 0
var _leaving: bool = false


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--dir="):
			_dir = arg.substr(6)
	if _dir.is_empty():
		_dir = ProjectSettings.globalize_path("user://tour")
	var made: Error = DirAccess.make_dir_recursive_absolute(_dir)
	if made != OK and made != ERR_ALREADY_EXISTS:
		printerr("tour: cannot make %s (%d)" % [_dir, made])
	var packed: PackedScene = load("res://game/main.tscn") as PackedScene
	_main = packed.instantiate() as SliceMain
	root.add_child(_main)
	_last_seen_msec = Time.get_ticks_msec()
	print("tour: dir=", _dir)


func _process(_delta: float) -> bool:
	_frame += 1
	if _leaving:
		return true
	if _main == null:
		return true
	# **A raised plate counts as booted.** The game no longer starts in a
	# mission unless `--mission=` says so, so waiting only for a world made
	# every scenario time out on the main menu -- 900 frames of a driver
	# staring at a screen it was never going to be given. The test is any
	# screen and not only a shell one: between missions the campaign flow owns
	# the picture, and its map is as much "the game is up" as a mission is.
	if _main.world == null and _main.screen_shown() == null:
		_boot += 1
		if _boot < BOOT_LIMIT:
			return false
		printerr("tour: neither a world nor a screen after %d frames" % _boot)
		return true
	# Reset, so the allowance is per wait and not per session: a driver that
	# sat on the menu for a while would otherwise have spent it.
	_boot = 0
	if _wait > 0:
		_wait -= 1
		return false
	if _watch > 0:
		_watch -= 1
		_blobs()
		return false
	if _idle_left > 0:
		_idle_left -= 1
		if _busy():
			return false
		_idle_left = 0
	if not _queue.is_empty():
		var line: String = _queue[0]
		_queue.remove_at(0)
		_run(line)
		if not _leaving:
			return false
		# `quit` still answers: a command file that is never replied to looks
		# to the sender exactly like a driver that died.
		if _running_reply:
			_reply()
		return true
	if _running_reply:
		_reply()
		return _leaving
	return _poll()


## True while the picture still owes the command something -- a queued set
## piece, a walk, a combat clip, a flight, or the computer's turn being shown.
func _busy() -> bool:
	return _main._picture_busy() or _main._playback.is_running()


## Looks for the next command file, and gives up after a long silence.
func _poll() -> bool:
	var path: String = "%s/%s" % [_dir, COMMAND_NAME % _index]
	if not FileAccess.file_exists(path):
		if Time.get_ticks_msec() - _last_seen_msec > SILENCE_LIMIT_MSEC:
			print("tour: nothing to do for %d minutes; leaving"
				% (SILENCE_LIMIT_MSEC / 60000))
			return true
		return false
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("tour: cannot read %s" % path)
		return true
	var text: String = file.get_as_text()
	file.close()
	_last_seen_msec = Time.get_ticks_msec()
	_queue = PackedStringArray()
	for raw: String in text.split("\n"):
		var line: String = raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		_queue.append(line)
	_log = []
	_shots = PackedStringArray()
	_running_reply = true
	return false


## Writes the reply for the command file just finished and moves on.
func _reply() -> void:
	var document: Dictionary = {
		"index": _index,
		"frame": _frame,
		"log": _log,
		"shots": _shots,
		"state": _state(),
	}
	var path: String = "%s/%s" % [_dir, REPLY_NAME % _index]
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("tour: cannot write %s" % path)
		_leaving = true
		return
	file.store_string(JSON.stringify(document, "  "))
	file.close()
	_running_reply = false
	_index += 1


func _run(line: String) -> void:
	var parts: PackedStringArray = line.split(" ", false)
	if parts.is_empty():
		return
	var verb: String = parts[0]
	match verb:
		"key":
			_key(parts[1] if parts.size() > 1 else "")
		"click":
			if parts.size() > 2:
				_click_cell(parts[1].to_int(), parts[2].to_int())
			else:
				_log.append("click: wants X and Y")
		"hover":
			# `hover X Y` -- a mouse **motion** at raw viewport pixels. The
			# location map answers a hover with a name and a ring, and a
			# driver that could only click could not photograph either.
			if parts.size() > 2:
				_hover(parts[1].to_float(), parts[2].to_float())
			else:
				_log.append("hover: wants X and Y in pixels")
		"click_screen":
			if parts.size() > 2:
				_click_screen(parts[1].to_float(), parts[2].to_float())
			else:
				_log.append("click_screen: wants X and Y in pixels")
		"buttons":
			_buttons()
		"press":
			# `press CAPTION` -- push the button whose caption contains
			# CAPTION. A screen's buttons are laid out in the plate's own
			# units and the window is not, so clicking one by pixel means
			# reproducing the stretch; naming it does not.
			if parts.size() > 1:
				_press(line.substr(6).strip_edges())
			else:
				_log.append("press: wants part of a caption")
		"map_click":
			# `map_click X Y` -- a click on a map **field** in the window of a
			# screen drawn around one, which is what the location map and the
			# deploy screen take. The ray is what a mouse goes through; this
			# is the same answer handed straight to the screen.
			if parts.size() > 2:
				_map_click(parts[1].to_int(), parts[2].to_int())
			else:
				_log.append("map_click: wants a cell X and Y")
		"click_unit":
			_click_unit(parts[1].to_int() if parts.size() > 1 else -1)
		"markers":
			# `markers` -- every cell the ground overlay drew on, with its
			# library and element (docs/43 section 3), so a screenshot's
			# digits can be read against the fill behind them.
			_markers()
		"hud":
			# `hud event N`, `hud pad N`, `hud ring N`, `hud radar +1|-1`:
			# the interface's own controls, pressed by number rather than by
			# pixel -- the plate's units are not the window's (docs/43).
			if parts.size() > 2:
				_hud(parts[1], parts[2])
			else:
				_log.append("hud: wants event|pad|ring|radar and a number")
		"blobs":
			_blobs()
		"watch":
			_watch = maxi(1, parts[1].to_int() if parts.size() > 1 else 20)
			_log.append("watch %d frames" % _watch)
		"cell":
			if parts.size() > 2:
				_cell(parts[1].to_int(), parts[2].to_int())
			else:
				_log.append("cell: wants X and Y")
		"chance":
			if parts.size() > 2:
				_chance(parts[1].to_int(), parts[2].to_int())
			else:
				_log.append("chance: wants a shooter and a target")
		"walk_to":
			if parts.size() > 2:
				_walk_to(parts[1].to_int(), parts[2].to_int())
			else:
				_log.append("walk_to: wants X and Y")
		"wait":
			_wait = maxi(1, parts[1].to_int() if parts.size() > 1 else 1)
			_log.append("wait %d" % _wait)
		"idle":
			_idle_left = maxi(1,
				parts[1].to_int() if parts.size() > 1 else IDLE_DEFAULT)
			_log.append("idle up to %d" % _idle_left)
		"shot":
			_shoot(parts[1] if parts.size() > 1 else "shot-%d" % _index)
		"campaign":
			_campaign(parts[1].to_int() if parts.size() > 1 else 2)
		"location":
			_location(parts[1].to_int() if parts.size() > 1 else 0)
		"deploy":
			if parts.size() > 3:
				_deploy(parts[1].to_int(), parts[2].to_int(),
					parts[3].to_int())
			else:
				_log.append("deploy: wants SLOT X Y")
		"menu":
			# The shell, by the name of one of its screens: `menu`,
			# `campaign_select`, `mission_select`, `slots`, `options`. With no
			# argument it toggles, which is what `ESC` does.
			_menu(parts[1] if parts.size() > 1 else "")
		"slot":
			_slot(parts[1].to_int() if parts.size() > 1 else 0,
				parts[2] if parts.size() > 2 else ShellHost.MODE_SAVE)
		"option":
			if parts.size() > 2:
				_option(parts[1], parts[2])
			else:
				_log.append("option: wants NAME VALUE")
		"screen":
			_screen(parts[1] if parts.size() > 1 else "")
		"ui":
			# Put one campaign screen up. The flow itself reaches them through
			# `location` and the buttons; this is how a driver photographs one.
			# `ui map` takes the mission down: the location map is a
			# picture of the chain's own `.lev` and two 3D scenes cannot
			# share a root.
			if parts.size() > 1:
				var shown: CampaignScreen = _main.show_campaign_screen(parts[1])
				_log.append("ui %s: %s" % [parts[1],
					"up" if shown != null else "no such screen"])
			else:
				_main.close_campaign_screen()
				_log.append("ui: closed")
		"gamecontrol":
			# `SetGameControl` -- what a mission script writes to end a
			# mission (docs/20 section 7). Writing it here is the same act,
			# and it is how a driver reaches a **won** debriefing without
			# playing a mission to its end.
			if parts.size() <= 2:
				_log.append("gamecontrol: wants SLOT VALUE")
			elif _main.world == null:
				_log.append("gamecontrol: no mission is up")
			else:
				_main.world.game_control.set_slot(parts[1].to_int(),
					parts[2].to_int())
				_log.append("gamecontrol %s = %s" % [parts[1], parts[2]])
		"enter":
			# A debugging entry past the location map, the way `--mission=` is
			# a debugging entry past the campaign. The flow itself goes through
			# `location`.
			if parts.size() <= 1:
				_log.append("enter: wants a mission name")
			elif _main.campaign == null or _main.campaign.state == null:
				_log.append("enter: no campaign is running")
			else:
				_main.campaign.state.mission = parts[1]
				_enter(parts[1])
		"note":
			_log.append(line.substr(5))
		"quit":
			_log.append("quit")
			_leaving = true
		_:
			_log.append("unknown command: %s" % line)


func _key(name: String) -> void:
	var upper: String = name.to_upper()
	if not KEYS.has(upper):
		_log.append("key: no such key %s" % name)
		return
	var press: InputEventKey = InputEventKey.new()
	press.keycode = KEYS[upper] as Key
	press.physical_keycode = press.keycode
	press.pressed = true
	root.push_input(press, true)
	var release: InputEventKey = InputEventKey.new()
	release.keycode = press.keycode
	release.physical_keycode = press.keycode
	release.pressed = false
	root.push_input(release, true)
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


## A left click at raw viewport pixels.
##
## The same press-and-release [method Viewport.push_input] a map click uses,
## without the projection: a plate's buttons are `Control`s and are hit by
## where they are on screen, not by which cell is under them. It is how a
## scenario presses a shell button through the game's own input path rather
## than by calling the handler behind it.
func _click_screen(x: float, y: float) -> void:
	_push_click(Vector2(x, y))
	_log.append("click_screen (%.0f, %.0f)" % [x, y])


func _hover(x: float, y: float) -> void:
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = Vector2(x, y)
	motion.global_position = motion.position
	root.push_input(motion, true)
	_wait = 1
	_log.append("hover (%.0f, %.0f)" % [x, y])


func _push_click(at: Vector2) -> void:
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	root.push_input(press, true)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	root.push_input(release, true)
	_wait = 1


## Clicks the reachable cell nearest to `(x, y)`.
##
## The convenience is the harness's, not the game's: it reads the fill the
## selection already published and clicks one of its cells, so what reaches
## `SliceMain` is still a left click on a highlighted square.
func _walk_to(x: int, y: int) -> void:
	var query: MoveMapResult = _main._last_query
	if query == null:
		_log.append("walk_to: nothing selected")
		return
	var best: Vector2i = Vector2i(-1, -1)
	var best_distance: int = 1 << 30
	for cy: int in range(query.height):
		for cx: int in range(query.width):
			if not query.is_reachable(cx, cy):
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


## Every live blob, field by field -- kind, class, model, position, velocity
## and the rotation triple. What a projectile is actually doing is not
## readable from a screenshot, and the pool is where the answer is.
func _blobs() -> void:
	var pool: BlobPool = _main._fx
	if pool == null:
		_log.append("blobs: no pool")
		return
	var queue: SequenceQueue = _main._sequences
	_log.append("-- frame %d, %d live, stage %s" % [_frame, pool.live(),
		queue.current() if queue != null else ""])
	for blob: Blob in pool.blobs():
		_log.append(("blob kind %d class %d model %d at (%d, %d, %d) "
			+ "v (%d, %d, %d) rot (%d, %d, %d) life %d aux %d")
			% [blob.kind, blob.class_id, blob.model, blob.x, blob.y, blob.z,
				blob.vx, blob.vy, blob.vz, blob.rot_x, blob.rot_y, blob.rot_z,
				blob.life, blob.aux])


## One cell of the control map, as `core` holds it -- the height, the field
## type, the action point and the unit on it. It is how a terrain change is
## read back: a crushed wall, an opened door, a fire written into a cell.
func _cell(x: int, y: int) -> void:
	if _main.world == null:
		_log.append("cell: no mission is up")
		return
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


## What `core` says one unit's chance of hitting another is, so a run of
## misses can be read against the number behind them rather than guessed at.
func _chance(shooter: int, target: int) -> void:
	if _main.world == null:
		_log.append("chance: no mission is up")
		return
	_log.append("chance %d -> %d: %d%%"
		% [shooter, target, _main.world.hit_chance(shooter, target)])


func _click_unit(slot: int) -> void:
	if _main.world == null:
		_log.append("click_unit: no mission is up")
		return
	var view: Dictionary = _main.world.unit_view(slot)
	if view.is_empty():
		_log.append("click_unit %d: no such unit" % slot)
		return
	_click_cell(DictRead.as_int(view["x"]), DictRead.as_int(view["y"]))


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


func _shoot(name: String) -> void:
	# **Force the frame first.** `root.get_texture()` hands back whatever is
	# in the framebuffer, and inside `_process` that is a frame the renderer
	# may not have redrawn since the last capture: every screenshot after the
	# first in a session came back byte-identical to it, so a transition
	# looked like a screen that had not changed when the tree said it had.
	RenderingServer.force_draw(false)
	var texture: ViewportTexture = root.get_texture()
	if texture == null:
		_log.append("shot %s: no viewport texture" % name)
		return
	var image: Image = texture.get_image()
	if image == null:
		_log.append("shot %s: no image" % name)
		return
	var path: String = "%s/%s.png" % [_dir, name]
	var saved: Error = image.save_png(path)
	if saved != OK:
		_log.append("shot %s: save failed (%d)" % [name, saved])
		return
	_shots.append(path)
	_log.append("shot %s" % path)


# --- the campaign ------------------------------------------------------------

## `campaign N` -- begin a new campaign in chain N and load its first mission.
##
## Chain 1 opens at `_C_100` with Bratt, West and Maxon in the roster; chain 2
## opens at `_C_140` with an empty one, which is what makes `_C_140`'s own four
## placed units the squad that reaches the pool at its debriefing.
func _campaign(number: int) -> void:
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
func _location(id: int) -> void:
	if _main.campaign == null:
		_log.append("location: the host is not ready")
		return
	var clicked: Dictionary = _main.campaign.click_location(id)
	var kind: String = DictRead.as_string(clicked["kind"])
	var target: String = DictRead.as_string(clicked["target"])
	_log.append("location %d: %s %s" % [id, kind, target])
	if kind == CampaignMap.KIND_BATTLE and target != "":
		_enter(target)


## Load a mission and take the entry snapshot, as `SelectUnits` does.
func _enter(mission: String) -> void:
	# The shell would otherwise sit over the mission this just built and eat
	# every key and click after it. `_enter` is already a debugging entry
	# past the campaign's own screens, so taking the shell down with them is
	# the same act rather than a new one.
	_main.shell.close()
	_main.close_campaign_screen()
	_main._build(mission)
	if _main.world == null:
		_log.append("enter %s: the cache does not carry it" % mission)
		return
	_main.campaign.begin_mission(_main.world)
	var cells: Array[Vector2i] = _main.campaign.deployment_cells()
	var names: Array = []
	for cell: Vector2i in cells:
		names.append([cell.x, cell.y])
	_log.append("enter %s: %d deployment cell(s) %s"
		% [mission, cells.size(), str(names)])


## `deploy SLOT X Y` -- put one roster record on a deployment cell.
func _deploy(slot: int, x: int, y: int) -> void:
	if _main.campaign == null:
		_log.append("deploy: the host is not ready")
		return
	var placed: Dictionary = _main.campaign.deploy(slot, x, y)
	var outcome: String = DictRead.as_string(placed["result"])
	if outcome != World.DEPLOY_OK:
		# **Named, not silent** -- docs/92 section 7.4 applies to deployment
		# too, and a refusal a driver could not see would look like a hang.
		_log.append("deploy %d at %d,%d refused: %s" % [slot, x, y, outcome])
		return
	_log.append("deploy %d at %d,%d -> unit slot %d"
		% [slot, x, y, DictRead.as_int(placed["slot"])])
	_main._refresh_after_deploy()


## `screen NAME` -- drive the campaign flow past a screen this slice has no
## picture for yet: `debriefing`, `advance`, `replay`, `recruit`, `save`,
## `load`.
func _screen(name: String) -> void:
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
			_log.append("save: %s" % str(host.save(_main.world)))
		"load":
			var decoded: Dictionary = host.load_save()
			_log.append("load: %s, mission %s, roster %d"
				% [CampaignCodec.result_name(DictRead.as_int(decoded["result"])),
				host.state.mission if host.state != null else "-",
				host.state.roster.used_slots() if host.state != null else 0])
		_:
			_log.append("screen: no such step %s" % name)


# --- what a reply reports ----------------------------------------------------

func _state() -> Dictionary:
	var world: World = _main.world
	# **The world half is conditional now.** The shell means the game can be
	# up with no mission behind it, and this used to read `world.turn`
	# unconditionally -- so the first reply written on the menu would have
	# taken the driver down rather than reporting where it was.
	var document: Dictionary = {
		"mission": _main._mission,
		"frame": _frame,
		"status": _main._status.text if _main._status != null else "",
		"note": _main._ai_note,
		"busy": _busy(),
		"picture": _picture(),
		"pool": _pool(),
		"overlay": _overlay(),
		"camera": _camera(),
		"shell": _shell(),
		"campaign": _main.campaign.view() if _main.campaign != null else {},
		"settings": _main.settings.view(),
	}
	if world == null:
		return document
	document["turn"] = world.turn.turn
	document["player"] = world.turn.current_player
	document["selected"] = _main.selected_slot()
	document["hud"] = _main.hud_view()
	document["markers"] = _drawn_markers()
	document["visible_rect"] = _visible_rect()
	# Whether a body is on its way. The world moves in one call and the
	# picture does not: a walk that never played looks exactly like a walk
	# that finished if only the endpoint is read.
	document["walking"] = _main._units != null and _main._units.is_walking()
	# Whether the computer's turn is being replayed. The interface refuses
	# every press while it is (docs/43 section 5.2), which is invisible from
	# the world alone.
	document["replay"] = _main._playback.is_running()
	document["gore_level"] = world.gore_level
	document["ai_level"] = world.turn.ai_level
	document["units"] = _units()
	document["reachable"] = _query(false)
	document["warp"] = _query(true)
	document["hash"] = world.canonical_hash_hex()
	return document


## Which screen is up: the shell's own, or the campaign flow's.
func _shell() -> Dictionary:
	var view: Dictionary = _main.shell.view()
	view["campaign_screen"] = _main.campaign.screen \
		if _main.campaign != null else ""
	view["screen_class"] = _main.screen_up()
	# How many plates are actually on the tree. One is right; more than one
	# means a screen was taken down in the tree and not on the screen.
	var plates: Array[String] = []
	for child: Node in _main.get_children():
		var plate: CampaignScreen = child as CampaignScreen
		if plate != null:
			plates.append("%s in_tree=%s visible=%s" % [child.name,
				str(plate.is_inside_tree()), str(plate.visible)])
	view["plates"] = plates
	return view


## The viewport's visible rectangle in the units events and the interface
## use: 640x480 on 4:3, wider or taller elsewhere (docs/43 section 7).
func _visible_rect() -> Array:
	var size: Vector2 = root.get_visible_rect().size
	return [size.x, size.y]


## What the ground overlay drew, as `[x, y, library, element]` rows.
func _drawn_markers() -> Array:
	var out: Array = []
	var ground: GroundSprites = _main.ground_overlay()
	if ground == null:
		return out
	for cell: Vector2i in ground.drawn_cells():
		for sprite: Variant in ground.drawn_at(cell):
			var pair: Array = DictRead.as_array(sprite)
			out.append([cell.x, cell.y, pair[0], pair[1]])
	return out


func _markers() -> void:
	for row: Array in _drawn_markers():
		_log.append("marker %d,%d %s[%d]" % [row[0], row[1], row[2], row[3]])


## `hud KIND N` -- a column event, a pad command, a ring record or a radar
## step, through the same paths a click takes.
func _hud(kind: String, argument: String) -> void:
	var number: int = argument.to_int()
	match kind:
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
		_:
			_log.append("hud: unknown kind %s" % kind)
	_wait = 1


## The cells the last selection's fill marked, as `[x, y]` pairs -- the walk
## targets a click may name, and the Jet Pack's jump targets beside them.
func _query(warp: bool) -> Array:
	var out: Array = []
	var query: MoveMapResult = _main._last_query
	if query == null:
		return out
	for y: int in range(query.height):
		for x: int in range(query.width):
			var marked: bool = query.is_warp_target(x, y) if warp \
				else query.is_reachable(x, y)
			if marked:
				out.append([x, y])
	return out


## Every button the screen that is up carries, with the rectangle it occupies.
##
## This is what makes `click_screen` usable from outside: a scenario reads the
## centres out of one reply and clicks them in the next, so the coordinates
## come from the layout rather than from a guess that would rot the first time
## a row moved.
func _buttons() -> void:
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


## `press CAPTION` -- the button a player would click, by its own caption.
func _press(caption: String) -> void:
	var screen: CampaignScreen = _main.screen_shown()
	if screen == null:
		_log.append("press: no screen is up")
		return
	var wanted: String = caption.to_lower()
	for control: Button in _buttons_in(screen):
		if control.disabled or not control.text.to_lower().contains(wanted):
			continue
		_log.append("press %s" % control.text)
		control.pressed.emit()
		_wait = 1
		return
	_log.append("press: no enabled button matches %s" % caption)


## `map_click X Y` -- a click on one map field of the screen's own window.
func _map_click(x: int, y: int) -> void:
	var screen: CampaignScreen = _main.screen_shown()
	if screen == null or not screen.takes_world_clicks():
		_log.append("map_click: no screen with a map window is up")
		return
	screen.world_click(Vector2i(x, y))
	_log.append("map_click (%d, %d) on %s" % [x, y, _main.screen_up()])
	_wait = 1


func _buttons_in(node: Node) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in node.get_children():
		var button: Button = child as Button
		if button != null:
			out.append(button)
		out.append_array(_buttons_in(child))
	return out


## `menu [NAME]` -- raise the shell at one of its screens, or toggle it.
func _menu(name: String) -> void:
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


## `slot N [load|save]` -- write or read one of the eight numbered slots.
func _slot(slot: int, mode: String) -> void:
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
	var stamp: Dictionary = CampaignHost.stamp_now()
	var written: bool = _main.campaign.save(_main.world, slot,
		DictRead.as_int(stamp["when"]),
		DictRead.as_string(stamp["when_text"]))
	var header: Dictionary = _main.campaign.slot_header(slot)
	_log.append("slot %d save: %s, header %s" % [slot, str(written),
		JSON.stringify(header)])


## `option NAME VALUE` -- set one option and apply it, without the click path.
##
## The values are the same numbers the screen cycles through, so a scenario
## can put the game in a known configuration rather than clicking a row an
## unknown number of times.
func _option(name: String, value: String) -> void:
	var settings: GameSettings = _main.settings
	match name:
		"music":
			settings.music_volume = value.to_int()
		"fx":
			settings.fx_volume = value.to_int()
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
		_:
			_log.append("option: no such setting %s" % name)
			return
	settings.apply_audio(_main._audio, _main._events)
	var written: bool = settings.save_to_disk()
	_log.append("option %s = %s (written %s)" % [name, value, str(written)])


func _units() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world: World = _main.world
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		out.append({
			"slot": slot,
			"player": DictRead.as_int(view["player"]),
			"type": DictRead.as_int(view["type_id"]),
			"x": DictRead.as_int(view["x"]),
			"y": DictRead.as_int(view["y"]),
			"hp": DictRead.as_int(view["hp"]),
			"mp": DictRead.as_int(view["mp"]),
			"weapon": DictRead.as_int(view["weapon"]),
			"facing": DictRead.as_int(view["facing"]),
			"visibility": DictRead.as_int(view["visibility"]),
			"acted": DictRead.as_int(view["acted"]),
		})
	return out


func _picture() -> Dictionary:
	var units: UnitsView = _main.units_view()
	var playing: PackedInt32Array = PackedInt32Array()
	if units != null:
		for slot: int in units.states:
			if units.is_playing(slot):
				playing.append(slot)
	var queue: SequenceQueue = _main._sequences
	return {
		"sequence": queue.current() if queue != null else "",
		"sequence_frames": queue.remaining() if queue != null else 0,
		"walking": units != null and units.is_walking(),
		"firing": units != null and units.any_busy(),
		"playing": playing,
		"dying": units.dying() if units != null else PackedInt32Array(),
		"suppressed": units.suppressed() if units != null \
			else PackedInt32Array(),
		"idle_starts": units.scheduler.starts if units != null else 0,
		"idle_frees": units.scheduler.frees if units != null else 0,
		"idle_slots": units.scheduler.entries.keys().size() \
			if units != null else 0,
		"playback": _main._playback.is_running(),
		"scenery": _main.scenery_count(),
		"special_objects": _main._special.live_count() \
			if _main._special != null else 0,
	}


func _pool() -> Dictionary:
	var kinds: Dictionary[int, int] = {}
	var live: int = 0
	var pool: BlobPool = _main._fx
	if pool == null:
		return {"live": 0, "kinds": kinds}
	for blob: Blob in pool.blobs():
		live += 1
		kinds[blob.kind] = kinds.get(blob.kind, 0) + 1
	return {"live": live, "kinds": kinds}


func _overlay() -> Dictionary:
	var texts: FloatingTexts = _main._texts
	if texts == null:
		return {}
	return {
		"entries": texts.entries(),
		"caption": texts.caption(),
		"fading": texts.is_fading(),
	}


func _camera() -> Dictionary:
	var rig: CameraRig = _main.camera_rig()
	if rig == null:
		return {}
	var eye: Vector3i = rig.eye()
	var target: Vector3i = rig.target()
	return {
		"eye": [eye.x, eye.y, eye.z],
		"target": [target.x, target.y, target.z],
		"quadrant": rig.quadrant(),
		"flying": rig.is_flying(),
		"view": int(rig.view_mode()),
	}
