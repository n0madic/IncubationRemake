class_name SequencePlayer
extends Node3D

## docs/41's `aSeqPlayer.cpp` as a state machine over the shared Charisma
## runtime: a logical id is a list of parts, a part a directory and a list of
## (model, animation) pairs played **one after another**, and a shot one body
## posed by its clip at a 30 fps clock.
##
## What the original does and this reproduces (docs/41 sections 3 and 4, as
## corrected on 2026-09-08):
##
## * the clock is `frame += delta * 30`; a shot ends at its clip's length and
##   the next pair is installed in the same update, at frame 0 -- the epoch is
##   rewritten on every update (`0x00465ACF`), so no time carries over;
## * the camera is a **part named `Cam<n>`** of the model, animated by the clip
##   like any other bone; `Switch n` picks which one, and the index resets to 1
##   with every installed pair (`0x0048023B`);
## * `Focus f` maps through the engine's preset table to a focal length in
##   pixels for a 480-row screen, then scales by the viewport's height; before
##   the first note the focal is the player's construction value, `_ftol(width
##   * 10/13)` -- 492 full screen, 398 framed -- and it is **not** reset per
##   shot, only per player;
## * a part's non-empty CD program is started when the part is installed;
##   `Seq_5`'s empty string keeps `Seq_4`'s track playing. The program is
##   announced through [signal cd_program] because the audio system is the
##   host's, not this node's;
## * `BREAK` notes are ignored here: `0x0042C5D0` has one caller, the combat
##   routine (docs/40 section 9).
##
## **The camera bone's forward axis is measured, not read.** Charisma has no
## camera record (docs/40 section 10.1); the bone is a `V100Part` like any
## other, and which of its local axes the authoring tool looked along is not
## in the data. Measured over all 130 shots at four frames each (520 poses,
## 2026-09-08): the mean joint of the drawn parts lies along the bone's
## **engine +Y** -- Godot -Z after [method WorldSpace.engine_matrix] -- in 514
## of 520, with a mean cosine of 0.90; every other axis is near 0.5. So the
## bone's frame *is* the camera's in Godot's own convention and
## [constant CAMERA_BASIS_FIX] is the identity; `test_sequence.gd` re-measures
## it. The roll about that axis is **measured too** (docs/41 section 7,
## 2026-09-09): over all 130 shots at nine frames each the median is exactly
## 0.000 degrees and 74 % of poses are within half a degree, so the bones are
## authored upright and the tail is a few dozen deliberately banked shots.
## Nothing here decides it either way -- the bone's whole basis is taken and
## [constant CAMERA_BASIS_FIX] is the identity, so whatever roll is authored
## is what is drawn.

## The clock, docs/40 section 4.8 and docs/41 section 3: `0.03` frames per
## millisecond at `0x004B157C`.
const FRAME_RATE: float = 30.0
## The `Cam<n>` naming (`0x0047F7BB`) and the per-pair default (`0x0048023B`).
const CAMERA_PREFIX: String = "Cam"
const DEFAULT_CAMERA: int = 1
## The reference height the `Focus` presets are stated for, and the ratio the
## player's starting focal is built from (`0x004B1570`, 10/13).
const FOCUS_REFERENCE_HEIGHT: int = 480
const FOCAL_NUMERATOR: int = 10
const FOCAL_DENOMINATOR: int = 13
## The preset a `Focus` value outside the table takes (`0x0048052F`).
const FOCUS_DEFAULT: int = 765
## The note verbs the dispatcher knows (`0x0047F6A0`'s `strstr` chain).
const NOTE_SWITCH: String = "Switch"
const NOTE_FOCUS: String = "Focus"
const NOTE_FADE: String = "Fade"
## Bone translations are in 1/16 of a world unit (docs/96).
const SKELETON_TO_WORLD: float = CharismaBody.SKELETON_TO_WORLD
## What turns the bone's frame into the camera's: nothing. The bone looks
## along its engine +Y, which [method WorldSpace.engine_matrix] already makes
## Godot's -Z; see the class comment for the measurement.
const CAMERA_BASIS_FIX: Basis = Basis.IDENTITY
## How far the camera sees, in metres. The scenes are a few hundred metres
## across; the default `far` of 4000 clips nothing, but is stated.
const CAMERA_NEAR: float = 0.05
const CAMERA_FAR: float = 4000.0

## The part's CD program, when a part with one is installed.
signal cd_program(program: String)

## The manifest -- `tables/sequences.json` -- and where the directories are.
var manifest: Dictionary = {}
var cache_dir: String = ""
## Which logical id is loaded, and where in it the player stands.
var logical_id: int = -1
var part: int = -1
var shot: int = -1
## The clock, in the clip's frames.
var frame: float = 0.0
## Which `Cam<n>` the shot looks through, and the focal in render pixels.
var camera_index: int = DEFAULT_CAMERA
var focal: int = 0
## `active` after [method create], `running` after [method start]
## (`0x00514270` / `0x00514274`).
var active: bool = false
var running: bool = false
## The window the player renders into, in the 640x480 plate space, and the
## render's own size. Both decide the focal: the construction focal is the
## window's width times 10/13 and a `Focus` note scales by the window's height.
var window: Rect2 = Rect2(0.0, 0.0, 640.0, 480.0)
var render: Vector2 = Vector2(640.0, 480.0)

var _parts: Array = []
var _library: SequenceLibrary = null
var _model: CharismaModel = null
var _clip: CharismaClip = null
var _body: CharismaBody = null
var _camera: Camera3D = null
## The clip's notes sorted by time, and how many have fired this shot.
var _notes: Array[Dictionary] = []
var _fired: int = 0
## `Focus f -> focal at 480`, from the manifest.
var _presets: Dictionary[int, int] = {}
## What the cache could not supply, once.
var _missing: PackedStringArray = PackedStringArray()


## `aCreateSeqPlayer` (`0x004653E0`): refuse an active player, take the
## rectangle, remember the logical id. Answers false for an id the manifest
## does not carry -- the compressed switch rejects everything but the seven.
func create(cache: String, document: Dictionary, id: int,
		viewport: Rect2, render_size: Vector2) -> bool:
	if active:
		return false
	cache_dir = cache
	manifest = document
	window = viewport
	render = render_size
	_parts = []
	for entry: Variant in DictRead.as_array(manifest.get("sequences", [])):
		var sequence: Dictionary = DictRead.as_dict(entry)
		if DictRead.as_int(sequence["id"]) == id:
			_parts = DictRead.as_array(sequence["parts"])
	if _parts.is_empty():
		return false
	_presets.clear()
	var focus: Dictionary = DictRead.as_dict(manifest.get("focus", {}))
	for entry: Variant in DictRead.as_array(focus.get("presets", [])):
		var row: Dictionary = DictRead.as_dict(entry)
		_presets[DictRead.as_int(row["focus"])] = DictRead.as_int(row["focal"])
	logical_id = id
	part = -1
	shot = -1
	focal = construction_focal(int(window.size.x))
	active = true
	running = false
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "SequenceCamera"
		_camera.near = CAMERA_NEAR
		_camera.far = CAMERA_FAR
		var environment: Environment = Environment.new()
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color.BLACK
		_camera.environment = environment
		add_child(_camera)
	return true


## `_ftol(width * 10/13)` -- what a player looks through before any `Focus`.
static func construction_focal(width: int) -> int:
	return width * FOCAL_NUMERATOR / FOCAL_DENOMINATOR


## `aStartSeqPlayer` (`0x00465B70`): refuse an inactive or running player,
## load part zero.
func start() -> bool:
	if not active or running:
		return false
	running = true
	return _install_part(0)


## One frame: `0x004658B0`. Answers false once the last part has ended,
## which is when the screen exits.
func update(delta: float) -> bool:
	if not active or not running or _clip == null:
		return false
	frame += delta * FRAME_RATE
	_fire_notes()
	if frame >= _clip.duration:
		# Return code 6: the pair ended; the next one is installed in the
		# same update, at frame 0.
		if not _install_shot(shot + 1):
			if not _install_part(part + 1):
				return false
	_pose()
	return true


## `aDestroyPlayer` (`0x00465C00`): stop, drop the scene, clear both flags.
func destroy() -> void:
	_drop_shot()
	_library = null
	running = false
	active = false


## The camera the shot looks through, current while the player runs.
func camera() -> Camera3D:
	return _camera


## What the agent's snapshot and the suite read.
func view() -> Dictionary:
	return {
		"id": logical_id,
		"part": part,
		"shot": shot,
		"frame": int(frame),
		"camera": camera_index,
		"focal": focal,
		"playing": active and running,
		"directory": _library.directory if _library != null else "",
		"clip": _clip.name if _clip != null else "",
	}


## Names the cache could not supply -- a model, a clip, a mesh, a camera.
func missing() -> PackedStringArray:
	var out: PackedStringArray = _missing.duplicate()
	if _library != null:
		out.append_array(_library.missing())
	return out


# --- parts and shots ---------------------------------------------------------

## `aSetSeqPlayerVideoPart` (`0x00465CC0`): the directory, the actor list,
## the CD program; then the first pair.
func _install_part(index: int) -> bool:
	if index < 0 or index >= _parts.size():
		return false
	var entry: Dictionary = DictRead.as_dict(_parts[index])
	var directory: String = DictRead.as_string(entry["directory"])
	_drop_shot()
	if _library == null or _library.directory != directory:
		_library = SequenceLibrary.open_directory(cache_dir, directory)
		if _library == null:
			_note_missing("sequences/" + directory)
			return false
	part = index
	# A non-empty program starts the CD; the empty one leaves it playing.
	var program: String = DictRead.as_string(entry.get("cd_program", ""))
	if program != "":
		cd_program.emit(program)
	return _install_shot(0)


## One (model, animation) pair: the body, the clip, frame 0, `Cam1`.
##
## Answers false only when the part has **run out** of pairs, so the caller's
## "install the next shot, else the next part" reads as it says. A pair the
## cache cannot supply is a hole in the middle rather than an end: it is noted
## and **skipped**, and the shots after it still play. Returning false for it
## dropped the rest of the part silently, which is the opposite of what a
## missing *mesh* does one screen down -- that one keeps its clock running.
func _install_shot(index: int) -> bool:
	var entry: Dictionary = DictRead.as_dict(_parts[part])
	var models: PackedStringArray = DictRead.to_strings(entry["models"])
	var clips: PackedStringArray = DictRead.to_strings(entry["animations"])
	# **Both lists, not one.** The manifest builds them from the same stem
	# list so they are the same length by construction, and
	# `remake_convert.py --check` requires it of every part -- but the bound
	# tested here has to be the one indexed, or a short `models` reads past
	# the end of a `PackedStringArray` instead of ending the part.
	var pairs: int = mini(models.size(), clips.size())
	if index < 0 or index >= pairs:
		return false
	_drop_shot()
	shot = index
	frame = 0.0
	camera_index = DEFAULT_CAMERA
	_fired = 0
	_model = _library.model(models[index])
	_clip = _library.clip(clips[index])
	if _model == null or _clip == null:
		_note_missing("%s/%s" % [_library.directory, clips[index]])
		return _install_shot(index + 1)
	_notes = _clip.notes.duplicate()
	_notes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return DictRead.as_float(a["time"]) < DictRead.as_float(b["time"]))
	# **The notes at frame 0 fire before the first pose.** 26 of the cache's
	# 166 notes sit at the head of their clip -- a `Switch` naming the shot's
	# camera -- and firing them from [method update] alone drew the pair's
	# first frame through `Cam1` at the old focal on every cut. `_fired`
	# moves with them, so the update does not fire them twice. UNVERIFIED
	# against the original: whether it renders one frame before the
	# dispatcher runs is not captured (docs/41 Open questions).
	_fire_notes()
	_body = CharismaBody.create(_model, _library)
	if _body == null:
		# A scene the cache has no mesh for still runs its clock, so the
		# sequence keeps its length and the camera still moves.
		_note_missing("%s/%s: no mesh" % [_library.directory, models[index]])
	else:
		add_child(_body)
	_pose()
	return true


func _drop_shot() -> void:
	if _body != null:
		remove_child(_body)
		_body.free()
	_body = null
	_model = null
	_clip = null
	_notes = []


## Fire every note whose time the clock has reached -- in one update there
## may be several, and a `Switch` and a `Focus` share a time in the corpus.
func _fire_notes() -> void:
	while _fired < _notes.size() \
			and DictRead.as_float(_notes[_fired]["time"]) <= frame:
		_apply_note(DictRead.as_string(_notes[_fired]["text"]))
		_fired += 1


## docs/40 section 9's grammar: split on CR/LF, trim, `Switch <int>` and
## `Focus <float>` read as `atoi`/`atof` do, everything else ignored.
func _apply_note(text: String) -> void:
	for raw: String in text.replace("\r", "\n").split("\n", false):
		var line: String = raw.strip_edges()
		var space: int = line.find(" ")
		if space < 0:
			continue
		var verb: String = line.substr(0, space)
		var argument: String = line.substr(space + 1).strip_edges()
		if verb == NOTE_SWITCH:
			camera_index = atoi(argument)
		elif verb == NOTE_FOCUS:
			focal = focus_focal(int(atof(argument)), int(window.size.y))


## The longest digit prefix, as C's `atoi`: `"2"` is 2, `"2x"` is 2, `""` 0.
static func atoi(text: String) -> int:
	var digits: String = ""
	for index: int in range(text.length()):
		var code: int = text.unicode_at(index)
		if code < 0x30 or code > 0x39:
			break
		digits += text[index]
	return digits.to_int() if not digits.is_empty() else 0


## `atof`'s longest numeric prefix: `"43..0"` is 43.0, `"28.0"` 28.0.
static func atof(text: String) -> float:
	var head: String = ""
	var dot: bool = false
	for index: int in range(text.length()):
		var code: int = text.unicode_at(index)
		if code >= 0x30 and code <= 0x39:
			head += text[index]
		elif text[index] == "." and not dot:
			head += "."
			dot = true
		else:
			break
	return head.to_float() if not head.trim_suffix(".").is_empty() else 0.0


## `Focus f` at `height` rows: the table's focal for `f` (or 765) scaled by
## `height / 480` and truncated -- exactly the preset at 480 rows.
func focus_focal(f: int, height: int) -> int:
	var preset: int = _presets.get(f, FOCUS_DEFAULT)
	if height == FOCUS_REFERENCE_HEIGHT:
		return preset
	return int(float(preset) * (float(height) / float(FOCUS_REFERENCE_HEIGHT)))


# --- the picture -------------------------------------------------------------

## Pose the body at the clock and put the camera on its `Cam<n>` bone.
func _pose() -> void:
	if _model == null or _clip == null:
		return
	var posed: CharismaSkeleton = CharismaSkeleton.pose(_model, _clip, frame)
	if _body != null:
		_body.apply(posed)
	if _camera == null:
		return
	var bone: String = CAMERA_PREFIX + str(camera_index)
	if not _model.bones.has(bone):
		# The engine looks the part up by name and keeps its own camera where
		# there is none; every shipped `Switch` names a bone that exists
		# (`seq_parse.py --check`), so this is a cache defect if it happens.
		_note_missing("%s/%s: %s" % [_library.directory, _clip.name, bone])
		return
	var world: PackedFloat64Array = posed.world_matrix(bone)
	world[3] *= SKELETON_TO_WORLD
	world[7] *= SKELETON_TO_WORLD
	world[11] *= SKELETON_TO_WORLD
	_camera.transform = camera_transform(world)
	CameraRig.frame_projection_focal(_camera, window, render, float(focal))


## The Godot camera transform of a `Cam<n>` bone's world matrix (engine
## layout, translation already in world units).
static func camera_transform(world: PackedFloat64Array) -> Transform3D:
	var placed: Transform3D = WorldSpace.engine_matrix(world)
	return Transform3D(placed.basis * CAMERA_BASIS_FIX, placed.origin)


func _note_missing(what: String) -> void:
	if not _missing.has(what):
		_missing.append(what)
