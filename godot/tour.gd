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
## | `walk_to X Y` | a left click on the reachable cell nearest `(X, Y)` |
## | `cell X Y` | the control map's cell: height, field type, action point |
## | `blobs` | every live blob: kind, class, model, position, velocity, rotation |
## | `watch N` | `blobs` on each of the next N drawn frames |
## | `chance A B` | `core`'s hit chance for unit A shooting unit B |
## | `wait N` | N drawn frames |
## | `idle [MAX]` | frames until the picture is idle, at most MAX |
## | `shot NAME` | writes `NAME.png` beside the command files |
## | `note TEXT` | one line in the reply's log |
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
	"SPACE": KEY_SPACE,
	"Q": KEY_Q,
	"E": KEY_E,
	"T": KEY_T,
	"G": KEY_G,
	"U": KEY_U,
	"D": KEY_D,
	"H": KEY_H,
	"1": KEY_1,
	"2": KEY_2,
	"3": KEY_3,
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
	if _main.world == null:
		_boot += 1
		if _boot < BOOT_LIMIT:
			return false
		printerr("tour: no world after %d frames" % _boot)
		return true
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
		"click_unit":
			_click_unit(parts[1].to_int() if parts.size() > 1 else -1)
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
		"screen":
			_screen(parts[1] if parts.size() > 1 else "")
		"enter":
			# A debugging entry past the location map, the way `--mission=` is
			# a debugging entry past the campaign. The flow itself goes through
			# `location`.
			if parts.size() > 1:
				_main.campaign.state.mission = parts[1]
				_enter(parts[1])
			else:
				_log.append("enter: wants a mission name")
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
	_log.append("click %d,%d at (%.0f, %.0f)" % [x, y, at.x, at.y])
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
	_log.append("chance %d -> %d: %d%%"
		% [shooter, target, _main.world.hit_chance(shooter, target)])


func _click_unit(slot: int) -> void:
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
	var cell: Dictionary = _main.world.cell_view(x, y)
	if cell.is_empty():
		return Vector2(-1.0, -1.0)
	var centre: Vector3 = WorldSpace.cell_centre(x, y,
		DictRead.as_int(cell["height"]))
	if camera.is_position_behind(centre):
		return Vector2(-1.0, -1.0)
	return camera.unproject_position(centre)


func _shoot(name: String) -> void:
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
	return {
		"mission": _main._mission,
		"frame": _frame,
		"turn": world.turn.turn,
		"player": world.turn.current_player,
		"selected": _main.selected_slot(),
		"gore_level": world.gore_level,
		"status": _main._status.text if _main._status != null else "",
		"note": _main._ai_note,
		"busy": _busy(),
		"units": _units(),
		"reachable": _query(false),
		"warp": _query(true),
		"picture": _picture(),
		"pool": _pool(),
		"overlay": _overlay(),
		"camera": _camera(),
		"campaign": _main.campaign.view() if _main.campaign != null else {},
	}


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
