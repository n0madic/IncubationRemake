class_name SliceMain
extends Node3D

## The slice, end to end: load the cache, build a [World], draw it, and let a
## click submit a movement query.
##
## docs/92 section 10.2 item 4: `game` renders terrain, placed scenery and
## units, then highlights the result -- and **scene nodes never become the
## authoritative position, occupancy or movement state**.  Every rebuild reads
## the world's views; nothing is read back off a node.

## The mission shown when nothing else is asked for.  Every mission the cache
## contains can be shown; `--mission=NAME` on the command line picks one, and
## `[` / `]` step through them at run time.
## `_C_140` is the mission this stage plays: the first one whose squad, aliens
## and win conditions are all in the `.lev`, so it can be won without the
## campaign layer (docs/94).
const DEFAULT_MISSION: String = "_C_140"
const MISSION_ARG: String = "--mission="
## `--campaign=N` -- start chain N and go straight to its map, past the menu.
## The campaign's own equivalent of `--mission=`, and a supported way in
## rather than a side effect (docs/92 section 7.15 S5).
const CAMPAIGN_ARG: String = "--campaign="
## What [method boot_choice] answers.
const BOOT_MISSION: String = "mission"
const BOOT_CAMPAIGN: String = "campaign"
const BOOT_SHELL: String = "shell"
## Where a development run finds the same bytes production reads from `user://`.
const DEV_CACHE: String = "res://generated/cache"

var world: World = null
## What the player chose, read once at start-up and written by the options
## screen. Never `null` after [method _ready]: a run with no file on disk uses
## the defaults rather than having no settings at all.
var settings: GameSettings = GameSettings.new()
## The campaign, or `null` until [method _ready] has read the cache. It is
## **not** part of [World]: a campaign outlives a mission, and folding it into
## the world's canonical hash would move every hash the first five slices
## pinned (D7).
var campaign: CampaignHost = null
## The campaign or shell screen that is up, or `null` when the mission view
## is. One at a time: the shell replaces a campaign screen and vice versa.
var _screen: CampaignScreen = null
## The shell's own state machine -- which of its screens is up, and whether
## there is a mission behind it.
var shell: ShellHost = ShellHost.new()
## The interface art, loaded once from the cache.
var _art: Art = null

var _missions: PackedStringArray = PackedStringArray()
var _mission: String = ""
var _geometry_cache: Dictionary = {}
var _texture_cache: Dictionary = {}
var _scene_root: Node3D = null
## The chain's own map, drawn behind the location screen's frame: `_C_XXX` or
## `_C_YYY` as a picture and nothing else. It is deliberately **not** [member
## world] -- half of `game` reads that as "a mission is being played", and the
## conflation was already a defect once (see [method in_mission]).
var _backdrop_root: Node3D = null
var _backdrop_world: World = null
var _backdrop_rig: CameraRig = null
var _backdrop_mission: String = ""
## The campaign map's own effects. Its `InitMap` is four `CreateBGB` fires and
## a CD track, and a picture built with no script at all left the city not
## burning -- which is the one thing about it a player can see moving.
var _backdrop_fx: BlobPool = null
var _backdrop_hooks: GameBlobHooks = null
var _backdrop_bgb: BgbEmitters = null
var _backdrop_sprites: BlobSprites = null
var _backdrop_carry: float = 0.0
## The map's own `CDTrackProgram` argument, taken from the same `INIT MAP`
## run its emitters come from. What is sounding now is [AudioSystem]'s to
## remember, so that every way music stops clears it.
var _backdrop_music: String = ""
## The pointer travel one frame of the map's turn should answer to, in the
## plate's own pixels. Held rather than applied at once so the decay and the
## drag are the same call.
var _swing_carry: Vector2 = Vector2.ZERO
## location -> the cell whose action point is its id, out of whichever campaign
## map is up (docs/27 section 2.1).
var _location_cells: Dictionary[int, Vector2i] = {}
## The dots on the map: the campaign's open locations, or the deployment
## screen's free cells. It hangs off whichever 3D root is up.
var _markers: MapMarkers = null
var _scenery: Scenery = null
var _overlay: TerrainOverlay = null
## The ground overlay -- the digits, bands and frames of docs/43 section 3.
var _ground: GroundSprites = null
## The map field under the pointer, `(-1, -1)` off the map or off the window.
var _hover: Vector2i = Vector2i(-1, -1)
## The selection's target overlay: cell -> hit band 30..34.
var _bands: Dictionary[Vector2i, int] = {}
## The 100 ms counter's clock and its bit 0.
var _blink_clock: float = 0.0
var _blink_odd: bool = false
## Where the pointer was when the hover was last read, so the ray pick runs
## only when it moves.
var _pointer: Vector2 = Vector2(-1.0, -1.0)
## The viewport's own pointer at the last poll, so the poll fires on a move.
var _polled: Vector2 = Vector2(-1.0, -1.0)
## A facing the ring chose that waits for the walk it followed to end
## (`aChangeUnitViewDirection` runs after the blocking walk in the original).
var _pending_turn: Dictionary = {}
## Whether the last overlay refresh was the far view, so a camera crossing
## the zoom gate redraws it.
var _far_drawn: bool = false
## Which mission each interface save slot holds, so the two undo buttons and
## *Recall position* are not lit for another mission's autosave. See
## [method _slot_holds_this_mission].
var _slot_owner: Dictionary[int, String] = {}
var _units: UnitsView = null
var _rig: CameraRig = null
## The camera's choreography -- docs/42's decisions over the rig.
var _director: CameraDirector = null
## Slot -> the [enum CameraDirector.WalkMode] its walk is shown in, for as
## long as it walks; the camera tracks or rides every entry each frame.
var _walk_cameras: Dictionary[int, CameraDirector.WalkMode] = {}
## docs/60 section 5 -- the largest of the four shipped fonts, 17 px.
const GAME_FONT: String = "font_2"
## Where the developer line sits before the HUD has a height to answer with,
## and how far under the HUD it sits once it has.
const STATUS_FALLBACK_Y: float = 120.0
const STATUS_GAP: float = 4.0
## The developer line's size in the plate's units. Smaller than the HUD's.
const STATUS_FONT_SIZE: int = 9
## How many rendered frames the engine spends crossing one map field.
##
## **Measured, and it was a guess before.** `aExecuteMove`'s two walk helpers,
## `0x0040EA30` and `0x0040EBB0`, take the vector between the two cells,
## divide each axis by **six** (`0x2AAAAAAB`, the signed magic for a division
## by 6), set a loop counter to six, and per iteration set the object's
## position and call `fcn.0040B6F0` -- the gameplay frame routine, the one the
## skip controller caps at `(10, 20)` fps (docs/40 section 4.8). A field is six
## frames, and since gameplay advances animation time by one key unit per
## rendered frame it is also six frames of the walk cycle.
const FRAMES_PER_FIELD: int = 6

## How long a body takes to cross one map field while walking.
##
## Not a taste setting any more: it is the six frames above, at the rate
## [constant CharismaState.FRAMES_PER_SECOND] plays gameplay clips, which is
## the same loop's own nominal cap. 0.3 s a field is 6.7 m/s over the 2 m a
## field is.
##
## It was 0.16 through slice 4, which is within rounding of what the original's
## **epoch bug** produced (the cap enforced every other frame, so ~40 fps and
## ~0.15 s a field). Following the bug made every walk read as a sprint.
const WALK_SECONDS_PER_STEP: float = \
	float(FRAMES_PER_FIELD) / CharismaState.FRAMES_PER_SECOND
var _status: Label = null
var _hud: MissionHud = null
var _strings: Localization = null
var _selected: int = -1
var _cache_dir: String = ""
var _geometry: Dictionary = {}
var _textures: Dictionary = {}
## The computer's turn, played back one event at a time. `core` decided the
## whole thing before this exists; the playback only shows it.
var _playback: AIPlayback = AIPlayback.new()
var _ai_note: String = ""

## The fifth slice's two presentation layers. Both are `game`'s alone: `core`
## emits the events they read and knows about neither, which is docs/28
## section 8's structural fact -- effects are driven by the animation
## routines, and the simulation only calls those.
var _audio: AudioSystem = null
var _events: AudioEvents = null
var _fx: BlobPool = null
## The pool's own hooks, kept typed: [method BlobPool.hooks] answers the base
## class and the emitter needs the game's.
var _fx_hooks: GameBlobHooks = null
## `CreateBGB`'s twenty slots -- the only effect a **script** places by itself.
var _bgb: BgbEmitters = null
var _sprites: BlobSprites = null
var _models: BlobModels = null
var _special: SpecialObjects = null
var _triggers: BlobTriggers = null
var _sequences: SequenceQueue = null
## The type-0 overlay: the fight caption and the floating numbers.
var _texts: FloatingTexts = null
## What a [ShotSequence] talks to.
var _shot_host: MainShotHost = null
## The last movement query the selection produced: the warp cells a click
## is checked against (docs/23 section 7.5), never trusted as the answer.
var _last_query: MoveMapResult = null
## `0x0050C088` -- the six numbers `SaveCamera` pushes and `LoadCamera` pops.
var _saved_cameras: Array[Array] = []
var _eng3d: Eng3dGeometry = null
var _blob_tables: Dictionary = {}
## The effect clock, in seconds carried over from the last frame. Blobs tick
## once per displayed frame in the original, and docs/92 section 7.10 measured
## that frame at 20 fps for gameplay animation -- the same frame the bodies
## use, so the two cannot drift apart.
var _fx_carry: float = 0.0
## The terrain the picture currently shows. `game` keeps it and diffs two
## immutable snapshots; `core` has no dirty flag and neither did the original.
var _drawn_terrain: Dictionary = {}
## True once the close request has been accepted, so a second one is ignored
## while the audio server is being given its frames.
var _quitting: bool = false
## Slot -> the walk cue that slot's type set up, kept for as long as the walk
## lasts so every step of one walk sounds the same.
var _footstep_cues: Dictionary[int, Dictionary] = {}
## Return fire waiting to be shown, one batch per command that drew it:
## `{"entries": Array, "x": int, "y": int}`, where the cell is the mover's.
##
## `core` resolves a whole move's reactions in one call at the end of the
## move (`World.submit_move`) and the walk that follows is only the picture,
## so the return fire is held until the picture has caught up. It is drained
## from [method _process] on a **state** test -- nothing walking, no body
## still shooting -- rather than on the edge of a walk ending, because a
## refused or zero-step move drains reactions in `core` and never walks.
var _pending_reactions: Array[Dictionary] = []


## An exported build made with the `run_tests` custom feature runs the suites
## and quits, so docs/92 section 10.4's "demonstrated in an exported build" is
## the same suites against the same cache rather than a second, weaker claim.
## The `anim` sprite atlas, by the name the texture index carries.
const ATLAS_TEXTURE: String = "anim"
## The most effect ticks one displayed frame may run. A long stall should not
## fast-forward every particle in the pool to its death.
const MAX_EFFECT_TICKS: int = 4

## How long a unit a shot killed is still drawn for, in seconds.
##
## **The remake's number, with no engine number behind it.** `aKillUnit`
## (`0x00472920`) is a network message and `aRemoveUnitElement`: the object
## goes at once and Charisma has no death clip to play instead (docs/40
## section 7.2.1). What the engine does have is the *order* -- the shot is
## drawn and then the unit is gone -- and the rebuild that drops it runs
## **before** the event that killed it is presented, so without this a marine
## vanished and the sound of what killed it arrived afterwards.
## docs/42 section 4.2 -- the text bank the fight caption reads.
const MODULE_FIGHT: String = "Txtmod_h"
const ID_MISSED: int = 10
const ID_RECEIVED: int = 17
const ID_EXPERIENCE_POINTS: int = 18
const ID_PARALYZED: int = 19
## docs/42 section 4.8 -- the barrel death adds `explosion2.wav`.
const BARREL_WAVE_EVENT: String = "explosion2"
## `Txtmod_h`'s ids the orbits format (docs/42 section 7.5): *increased
## skill level* `"%s %d"`, *increased hit points by* `"%s: %s %d"`, the
## jam's *Weapon runs hot!* / *Out of ammo!*, and the overheat's three by
## `0x0040F420`'s kind.
const ID_SKILL: int = 3
const ID_HEAL: int = 4
const ID_JAM_HOT: int = 6
const ID_JAM_AMMO: int = 7
const ID_OVERHEAT_BY_KIND: Dictionary = {1: 14, 2: 15, 3: 16}
## `0x0040F420`'s kind for each of [Combat]'s overheat outcomes (docs/22
## section 8: 1 explosion, 2 jam, 3 damage).
const OVERHEAT_KINDS: Dictionary = {Combat.OVERHEAT_DESTROYED: 1,
	Combat.OVERHEAT_JAM: 2, Combat.OVERHEAT_DAMAGE: 3}
## The jump's five cues by wave (docs/28 section 4): the two the player's
## unit plays and the three screams the computer's draws among.
const JUMP_WAVE: String = "jump.wav"
const DROP_WAVE: String = "drop.wav"
const SCREAM_WAVES: Array[String] = ["s_ali_0.wav", "s_ali_1.wav", "s_ali_2.wav"]
## The `Use` result kinds the push arm answers (docs/26 section 4).
const PUSH_KINDS: Array[String] = ["push", "push_onto_mine", "push_into_hole"]
const PUSH_INTO_HOLE: String = "push_into_hole"
## The computer's event names against the set pieces they queue.
const AI_SETPIECE_KINDS: Dictionary[String, String] = {"door": "open_door"}
## The queue stage that waits for a walk before its own epilogue -- see
## [method _hold_for_walk].
const STAGE_AFTER_WALK: String = "move.after_walk"
## docs/92 section 7.5.3, revised 2026-09-03 (docs/97 section 34): the
## engine's hand-over calls no camera routine, so neither does this by
## default. The flag restores the remake's own return to the first unit,
## which is what [method focus_on_friendly] documents and measured.
const COMPAT_CAMERA_RETURNS: String = "camera_returns_on_hand_over"
## docs/42 section 4.8.1 -- the output mode the debris loop reads
## (`0x00461E80`): 2 is the software 640x480 mode the game copy plays in, and
## **the remake's choice** of which mode it is; only mode 3 -- the 3D
## accelerator -- changes the picture, with the long debris loop.
const DISPLAY_MODE: int = 2

const TEST_FEATURE: String = "run_tests"
const TEST_RUNNER: String = "res://tests/runner.gd"
## What the interpreter calls a `CreateBGB` line
## (`core/lcl/lcl_interpreter.gd`).
const CREATE_BGB: String = "create_bgb"
## docs/20 section 7.3 -- the other command `INIT MAP` carries.
const CD_TRACK_PROGRAM: String = "cd_track_program"
## What the test build's own window says while it is not the game.
const TEST_CAPTION: String = \
	"Incubation - Remake -- the test harness, not the game\n\n" \
	+ "%d / %d suites -- running %s\n\nabout two minutes, then it quits"


func _ready() -> void:
	if OS.has_feature(TEST_FEATURE):
		var runner: GDScript = _test_runner()
		if runner != null:
			_run_tests_and_quit(runner)
			return
	# The window's close button must not end the process on the spot: the audio
	# server needs a few more frames to let go of a playing Ogg stream, and a
	# quit in the same frame leaks it. See [method AudioSystem.shutdown].
	get_tree().auto_accept_quit = false
	_status = Label.new()
	# Below the HUD, which owns the top of the screen.
	_status.position = Vector2(12.0, STATUS_FALLBACK_Y)
	# The developer line wraps too; [method _refresh_status] then puts it
	# under whatever height the HUD's own wrapped hints came to. It is
	# smaller than the HUD: it is a diagnostic, not something to play by.
	_status.size = Vector2(CampaignScreen.PLATE_SIZE.x - 24.0, 0.0)
	_status.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var layer: CanvasLayer = CanvasLayer.new()
	layer.add_child(_status)
	add_child(layer)

	var opened: Dictionary = CacheLoader.open_active()
	if DictRead.as_bool(opened["ok"]):
		_cache_dir = DictRead.as_string(opened["cache_dir"])
	elif DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(DEV_CACHE)) \
			or FileAccess.file_exists(DEV_CACHE + "/manifest.json"):
		_cache_dir = DEV_CACHE
	else:
		_fail(DictRead.as_string(opened["reason"]))
		return

	var manifest: Dictionary = CacheLoader.read_json(
		_cache_dir + "/manifest.json")
	var problems: PackedStringArray = CacheLoader.verify(_cache_dir, manifest)
	if not problems.is_empty():
		_fail("cache refused: " + ", ".join(problems))
		return
	_missions = _missions_in(manifest)
	if _missions.is_empty():
		_fail("the cache at %s contains no missions" % _cache_dir)
		return
	# The strings come before anything that says one. docs/92 section 7.6: a
	# localization seam retrofitted later means finding every literal.
	_strings = Localization.from_cache(_cache_dir, manifest)
	# **Before the first thing that reads one.** `interface_font()` is a
	# setting, and reading it two lines below this while the file was still
	# unread gave the HUD the default face and every plate built afterwards
	# the chosen one -- the exact inconsistency `interface_font()` exists to
	# prevent. The volumes and the difficulty were never affected, being
	# applied later still, but the ordering is now unconditional rather than
	# true by luck.
	var _had_settings: bool = settings.load_from_disk()
	# docs/60 -- the game's own bitmap font, the 17 px one. A cache built by an
	# older converter has no fonts and the HUD stays on Godot's default.
	var font: FontFile = interface_font()
	_texts = FloatingTexts.new()
	_texts.use_font(font)
	add_child(_texts)
	_shot_host = MainShotHost.new(self)
	# The campaign layer. `--mission=` still enters a mission directly, past
	# the campaign, which is what it has always been for; the host is what the
	# campaign flow drives, and `tour.gd` reaches it by name.
	_art = Art.open(_cache_dir)
	# The battle interface (docs/43): the plate, the columns, the pad, the
	# panel and the radar, drawn on the shipped art and captioned from
	# `Txtmod_h`. Its two plate faces are the 13 px and 10 px bitmap fonts.
	_hud = MissionHud.new()
	_hud.name = "MissionHud"
	_hud.setup(_art, _strings, font,
		GameFont.load_from(_cache_dir, MissionHud.TEXT_FONT),
		GameFont.load_from(_cache_dir, MissionHud.SMALL_FONT))
	_hud.event.connect(_on_hud_event)
	_hud.command.connect(_on_pad_command)
	_hud.radar_rescaled.connect(func(_fields: int) -> void: _refresh_status())
	add_child(_hud)
	get_viewport().size_changed.connect(_on_canvas_resized)
	campaign = CampaignHost.create(_cache_dir, CacheLoader.read_json(
		_cache_dir + "/tables/balance.json"), _strings)
	_boot()


## The three ways in, and all three stay open (docs/92 section 7.15 S5).
##
## `--mission=NAME` builds a mission **immediately** and never raises the
## shell, which is what it has always done and what `shot.gd`, `tour.gd` and
## every screenshot depend on. `--campaign=N` is the campaign's equivalent:
## the chain starts and its map comes up, past the menu. With neither, the
## shell opens -- which is the whole of this slice.
func _boot() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var choice: Dictionary = boot_choice(args, _missions, DEFAULT_MISSION)
	for line: String in DictRead.to_strings(choice["warnings"]):
		push_warning(line)
	match DictRead.as_string(choice["kind"]):
		BOOT_MISSION:
			_build(DictRead.as_string(choice["mission"]))
		BOOT_CAMPAIGN:
			var _started: CampaignState = campaign.start_new(
				DictRead.as_int(choice["campaign"]), settings.difficulty)
			var _map: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_MAP)
		_:
			var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)


## Which of the three entries the command line names.
##
## **Static and pure**, so the decision is checked by a suite rather than only
## by hand: a build's arguments cannot be injected, and "does `--mission=`
## still bypass the shell" is exactly the kind of thing that would otherwise
## be verified once and then quietly broken (docs/92 section 7.15 S5).
##
## Returns `{"kind": String, "mission": String, "campaign": int,
## "warnings": PackedStringArray}`. An unknown mission name still falls back
## to *fallback* and still warns -- the cache is the authority on what exists
## -- and an unknown chain opens the shell rather than starting nothing.
static func boot_choice(args: PackedStringArray, missions: PackedStringArray,
		fallback: String) -> Dictionary:
	var warnings: PackedStringArray = PackedStringArray()
	var landing: String = fallback if missions.has(fallback) \
		else (missions[0] if not missions.is_empty() else "")
	for arg: String in args:
		if arg.begins_with(MISSION_ARG):
			var name: String = arg.substr(MISSION_ARG.length())
			if not missions.has(name):
				warnings.append("no mission %s in the cache; showing %s"
					% [name, landing])
				name = landing
			return {"kind": BOOT_MISSION, "mission": name, "campaign": 0,
				"warnings": warnings}
		if arg.begins_with(CAMPAIGN_ARG):
			var chain: int = arg.substr(CAMPAIGN_ARG.length()).to_int()
			if not CampaignState.FIRST_MISSION.has(chain):
				warnings.append("no campaign %d; opening the menu" % chain)
				return {"kind": BOOT_SHELL, "mission": "", "campaign": 0,
					"warnings": warnings}
			return {"kind": BOOT_CAMPAIGN, "mission": "", "campaign": chain,
				"warnings": warnings}
	return {"kind": BOOT_SHELL, "mission": "", "campaign": 0,
		"warnings": warnings}


## The difficulty the next world is built at -- docs/92 section 7.15's S6.
##
## **The campaign is the authority when there is one.** [member
## CampaignState.difficulty] is campaign state, already inside that object's
## own digest, and it is what the map screen's option writes. Outside a
## campaign -- *Instant Action*, or `--mission=` -- there is no campaign state
## to ask, so the settings' default is the whole answer.
func difficulty_now() -> int:
	if campaign != null and campaign.state != null:
		return campaign.state.difficulty
	return settings.difficulty


## The font every label and button in the interface is drawn in, or `null` for
## Godot's own.
##
## One place decides, because the answer has to be the same for the HUD, the
## floating numbers and all eleven plates -- and it used to differ by accident:
## the HUD carried the shipped bitmap font and the developer line carried
## nothing, so the same screen showed both a hard-edged 2x bitmap and a smooth
## vector face. See [member GameSettings.game_font] for why the default is the
## readable one.
func interface_font() -> FontFile:
	if not settings.game_font:
		return null
	return GameFont.load_from(_cache_dir, GAME_FONT)


## Redraw after a deployment put a unit on the map.
##
## `UnitsView.build` frees every unit node and rebuilds from the world, which
## is what a newly placed record needs; the overlay follows because deployment
## rebuilds visibility and the fog it draws is now a different one.
func _refresh_after_deploy() -> void:
	if world == null or _units == null:
		return
	# The terrain overlay is not rebuilt: deployment changes no cell. What it
	# does change is visibility, and that is `UnitsView.build`'s to redraw.
	_units.build(world, _geometry, _textures)
	# One free cell fewer, so the dots are re-laid: a marker still standing on
	# an occupied cell is a control that refuses its own click.
	if campaign != null:
		_show_markers(SelectUnitsScreen.marks_for(_free_landings()))
	_refresh_status()



# --- the quick save ----------------------------------------------------------

## `F5` -- write the campaign and, when a mission is up, the mission inside it.
##
## The quick save has a file of its own beside the eight numbered slots
## (docs/92 section 7.15 S1), so `F5` cannot cost the player a slot they meant
## to keep. The mission blob is [SaveCodec]'s and stays opaque to the
## container, because that codec refuses a blob whose map name is not the
## world's -- right for a mission, wrong for a campaign that outlives one
## (D10).
func quick_save(slot: int = CampaignHost.QUICK_SLOT) -> bool:
	if campaign == null or campaign.state == null:
		_refresh_status("no campaign to save")
		return false
	var stamp: Dictionary = CampaignHost.stamp_now()
	var written: bool = campaign.save(world, slot,
		DictRead.as_int(stamp["when"]), DictRead.as_string(stamp["when_text"]))
	_refresh_status("saved" if written else "save failed")
	return written


## The interface's own autosaves (docs/43 section 5): the mission's start
## (slot 31, *Undo mission*) and each turn's start (slot 33, *Undo last
## turn*), written the way `0x0041DA20`'s commands write them. Silent: an
## *Instant Action* game has no campaign to write and the two buttons stay
## dark for it.
## The mission's start, saved twice: *Undo mission* returns here, and so does
## *Undo last turn* until a turn has been played.
func _autosave_mission_start() -> void:
	_autosave(HudTables.SLOT_UNDO_MISSION)
	_autosave(HudTables.SLOT_UNDO_TURN)


func _autosave(slot: int) -> void:
	if campaign == null or campaign.state == null or world == null:
		return
	var stamp: Dictionary = CampaignHost.stamp_now()
	var written: bool = campaign.save(world, slot,
		DictRead.as_int(stamp["when"]), DictRead.as_string(stamp["when_text"]))
	if written:
		_slot_owner[slot] = campaign.state.mission


## Whether one of the interface's own save slots holds **this** mission.
##
## The three slot numbers are fixed (docs/43 section 5.4) and nothing ever
## deletes the files, so an autosave taken in another mission -- or by another
## session, in another chain -- outlives the mission it was taken in, and the
## bare "the file is there" test offers it: *Undo mission* would then drop the
## player into a mission they are not playing, and the mission blob's own map
## check cannot catch it because the world is rebuilt from the save's own
## campaign state. The guard is the remake's; the original's slot files have
## the same staleness by construction.
##
## The header is read once per slot and remembered: this session is the only
## writer, and [method _autosave] records what it wrote.
func _slot_holds_this_mission(slot: int) -> bool:
	if campaign == null or campaign.state == null:
		return false
	if not campaign.has_save(slot):
		return false
	if not _slot_owner.has(slot):
		var header: Dictionary = campaign.slot_header(slot)
		var readable: bool = DictRead.as_int(header["result"]) \
			== CampaignCodec.Result.OK
		_slot_owner[slot] = DictRead.as_string(header["mission"]) if readable \
			else ""
	return _slot_owner[slot] == campaign.state.mission


## `F9` -- read it back, and rebuild whatever it was holding.
##
## The order matters: the campaign comes back first because it names the
## mission, then the mission is built, and only then is the mission blob handed
## to [World] -- which is the one that checks the map name.
func quick_load(slot: int = CampaignHost.QUICK_SLOT) -> bool:
	if campaign == null:
		return false
	# `has_save` is the gate, and it had no caller at all. Without it an
	# absent file came back as a refusal code and the line read "load
	# refused: TRUNCATED", which says the bytes are damaged about a file that
	# was never written.
	if not campaign.has_save(slot):
		_refresh_status("nothing quick-saved yet")
		return false
	var decoded: Dictionary = campaign.load_save(slot)
	var code: int = DictRead.as_int(decoded["result"])
	if code != CampaignCodec.Result.OK:
		_refresh_status("load refused: " + CampaignCodec.result_name(code))
		return false
	var blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	if blob.is_empty():
		close_campaign_screen()
		var _map: CampaignScreen = show_campaign_screen(CampaignHost.SCREEN_MAP)
		_refresh_status("loaded")
		return true
	_build(campaign.state.mission)
	if world == null:
		_refresh_status("loaded, but the cache has no " + campaign.state.mission)
		return false
	var restored: int = world.load_save(blob)
	if restored != SaveCodec.Result.OK:
		_refresh_status("mission refused: " + SaveCodec.result_name(restored))
		return false
	close_campaign_screen()
	campaign.enter_mission()
	_refresh_after_deploy()
	_refresh_status("loaded")
	return true


# --- the campaign screens ----------------------------------------------------

## Put one campaign screen up, taking down whatever was there.
##
## The screens are built fresh each time rather than kept and hidden: they are
## small, and a kept one would go stale against a roster the last screen sold
## a soldier out of.
func show_campaign_screen(name: String) -> CampaignScreen:
	close_campaign_screen()
	if campaign == null:
		return null
	var screen: CampaignScreen = null
	match name:
		CampaignHost.SCREEN_MAP:
			# The map is a **picture of the chain's own map**, so the mission's
			# scene comes down and `_C_XXX` or `_C_YYY` goes up behind the
			# frame. Two 3D scenes under one root would render into each other.
			_clear_mission()
			_build_backdrop(campaign.map_mission())
			var map: CampaignMapScreen = CampaignMapScreen.new()
			map.host = campaign
			map.location_cells = _location_cells
			# A cache the chain's map is not in leaves the plate whole and
			# the screen a list; the frame is drawn around a hole only when
			# there is something behind it.
			map.has_picture = _backdrop_root != null
			# The other half of the map's `INIT MAP`. Here rather than in
			# the backdrop's build, because the backdrop is kept across a
			# mission and the music is not.
			_play_map_music()
			screen = map
		CampaignHost.SCREEN_BRIEFING:
			var briefing: BriefingScreen = BriefingScreen.new()
			briefing.mission = campaign.state.mission
			briefing.cache_dir = _cache_dir
			briefing.document = CacheLoader.read_json(
				"%s/text/briefing/%s.json" % [_cache_dir,
				campaign.state.mission])
			screen = briefing
		CampaignHost.SCREEN_SELECT:
			var select: SelectUnitsScreen = SelectUnitsScreen.new()
			select.host = campaign
			screen = select
		CampaignHost.SCREEN_HQ, CampaignHost.SCREEN_RECRUIT:
			var hq: HqScreen = HqScreen.new()
			hq.host = campaign
			screen = hq
		CampaignHost.SCREEN_UPGRADE:
			var upgrade: UpgradeScreen = UpgradeScreen.new()
			upgrade.host = campaign
			screen = upgrade
		CampaignHost.SCREEN_DEBRIEFING:
			var debriefing: DebriefingScreen = DebriefingScreen.new()
			debriefing.report = campaign.last_report
			debriefing.board = campaign.state.scoreboard[0]
			screen = debriefing
	if screen == null:
		return null
	screen.setup(_art, _strings, interface_font())
	screen.chose.connect(_on_campaign_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()
	# The dots go on **after** the screen is up, because which ones there are
	# is the screen's own question: the map's are its open locations and the
	# deploy screen's the free cells.
	match name:
		CampaignHost.SCREEN_MAP:
			_show_markers(CampaignMapScreen.marks_for(campaign,
				_location_cells))
			_frame_map()
		CampaignHost.SCREEN_SELECT:
			_show_markers(SelectUnitsScreen.marks_for(_free_landings()))
			_frame_deployment()
	return screen


## The deployment cells nobody is standing on yet.
##
## [method World.deployment_cells] answers the cells the *map* offers, which
## is the right question for the rule and the wrong one for the picture: a dot
## left on an occupied cell is a control whose only answer is a refusal, and
## section 7.1 counts that as a defect.
func _free_landings() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if campaign == null or world == null:
		return out
	for cell: Vector2i in campaign.deployment_cells():
		var view: Dictionary = world.cell_view(cell.x, cell.y)
		if DictRead.as_int(view["unit"]) == MapState.NO_UNIT:
			out.append(cell)
	return out


## Put the camera over the cells the squad is about to be put on.
##
## [method _frame_units] cannot: it frames a **unit**, and at this point the
## player has none on the map -- which is the whole of what the screen is for.
## So the deployment area is framed instead, on the cell nearest its own
## middle, because the middle itself is not somewhere anyone can stand.
func _frame_deployment() -> void:
	_set_deploy_view(CameraRig.View.MAP)


## The deployment cell nearest the middle of the deployment area, or `(-1, -1)`.
##
## The middle itself is not where anybody can stand, and the original's own
## camera routines all take a cell.
func _deployment_centre() -> Vector2i:
	if campaign == null:
		return Vector2i(-1, -1)
	var cells: Array[Vector2i] = campaign.deployment_cells()
	if cells.is_empty():
		return Vector2i(-1, -1)
	var sum: Vector2i = Vector2i.ZERO
	for cell: Vector2i in cells:
		sum += cell
	var middle: Vector2 = Vector2(sum) / float(cells.size())
	var at: Vector2i = cells[0]
	for cell: Vector2i in cells:
		if Vector2(cell).distance_to(middle) < Vector2(at).distance_to(middle):
			at = cell
	return at


# --- the shell ---------------------------------------------------------------

## Raise the shell at one of its screens, over the mission when there is one.
##
## The shell and the campaign screens share [member _screen]: only one plate is
## ever up, and a shell raised over a campaign screen would leave the campaign
## one unreachable behind it. That is why `ESC` only opens the shell from a
## mission view (see [method _unhandled_input]).
func open_shell(name: String = ShellHost.SCREEN_MENU) -> CampaignScreen:
	shell.open(name, _behind_the_shell())
	return _show_shell_screen()


## Whether a mission is actually being **played**, as opposed to a world that
## merely still exists behind a campaign plate.
##
## `world != null` is not the question and using it was a real defect: the map
## screen sits over the last mission's view, so a shell raised from the map
## offered *Continue* and *Save game* and hid the difficulty row, on the
## grounds that a finished `_C_140` was still in memory. What decides is where
## the campaign flow says it is -- and a mission entered past the campaign has
## no flow, so there the world is the game.
func in_mission() -> bool:
	if world == null:
		return false
	if campaign == null or campaign.state == null:
		return true
	return campaign.screen == CampaignHost.SCREEN_MISSION


## Whether there is anything behind the shell to go back to. A different
## question from [method in_mission]: the campaign map is behind it too.
func _behind_the_shell() -> bool:
	return world != null or (campaign != null and campaign.state != null)


## Whether the difficulty the options screen writes is the **campaign's**.
##
## S6, and `Txtmod_h` 58 says it aloud: only on the main map, during a
## campaign. Written once, because the screen and the button that steps it
## must not be able to disagree about which of the two values is being
## changed.
func _campaign_difficulty_writable() -> bool:
	return campaign != null and campaign.state != null \
		and campaign.screen == CampaignHost.SCREEN_MAP and not in_mission()


## Take the shell down and go back to whatever was behind it.
func close_shell() -> void:
	shell.close()
	close_campaign_screen()
	# The campaign flow owns the picture between missions, so leaving the
	# shell there has to put its screen back rather than reveal a dead map.
	#
	# `not in_mission()` and not `world == null`: the campaign map is drawn
	# over the **last mission's** view, so a shell closed on the map with a
	# finished world still in memory used to restore nothing at all.
	if not in_mission() and campaign != null and campaign.state != null:
		var _back: CampaignScreen = show_campaign_screen(campaign.screen)


func _show_shell_screen() -> CampaignScreen:
	close_campaign_screen()
	var screen: CampaignScreen = null
	match shell.screen:
		ShellHost.SCREEN_MENU:
			var menu: MainMenuScreen = MainMenuScreen.new()
			menu.paused = in_mission()
			menu.behind = shell.behind
			menu.has_any_save = _any_slot_used()
			screen = menu
		ShellHost.SCREEN_CAMPAIGN_SELECT:
			var chains: CampaignSelectScreen = CampaignSelectScreen.new()
			chains.host = campaign
			screen = chains
		ShellHost.SCREEN_MISSION_SELECT:
			var list: MissionSelectScreen = MissionSelectScreen.new()
			list.missions = _missions
			screen = list
		ShellHost.SCREEN_SLOTS:
			var slots: SaveSlotsScreen = SaveSlotsScreen.new()
			slots.host = campaign
			slots.mode = shell.slot_mode
			slots.may_save = campaign != null and campaign.state != null
			screen = slots
		ShellHost.SCREEN_OPTIONS:
			var options: OptionsScreen = OptionsScreen.new()
			options.settings = settings
			options.in_mission = in_mission()
			if _campaign_difficulty_writable():
				options.campaign_difficulty = campaign.state.difficulty
			options.language = _strings.language if _strings != null \
				else Localization.FALLBACK_LANGUAGE
			screen = options
	if screen == null:
		return null
	screen.setup(_art, _strings, interface_font())
	screen.chose.connect(_on_shell_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()
	return screen


## Whether any of the **eight** holds something, which is what decides whether
## the menu offers *Load Game*.
##
## The quick save is deliberately not counted. It is not one of the eight (S1),
## and counting it meant a player who had only ever pressed `F5` was offered a
## list of eight rows every one of which refused the click -- the inert control
## section 7.1 forbids, reached by the very button that exists to avoid it.
## `F9` is how a quick save comes back.
func _any_slot_used() -> bool:
	if campaign == null:
		return false
	for slot: int in range(CampaignHost.SLOT_COUNT):
		if campaign.has_save(slot):
			return true
	return false


## What a shell button means. The host owns the transitions; this turns one
## into a call, exactly as [method _on_campaign_choice] does for the campaign.
func _on_shell_choice(action: String) -> void:
	if action.begins_with("slot:"):
		_use_slot(action.substr(5).to_int())
		return
	if action.begins_with("start:"):
		_start_campaign(action.substr(6).to_int())
		return
	if action.begins_with("mission:"):
		_start_instant_action(action.substr(8))
		return
	if action.begins_with("option:"):
		_step_option(action.substr(7))
		return
	match action:
		"campaign":
			shell.go(ShellHost.SCREEN_CAMPAIGN_SELECT)
			var _chains: CampaignScreen = _show_shell_screen()
		"instant":
			shell.go(ShellHost.SCREEN_MISSION_SELECT)
			var _list: CampaignScreen = _show_shell_screen()
		"load":
			shell.go_slots(ShellHost.MODE_LOAD)
			var _slots: CampaignScreen = _show_shell_screen()
		"save":
			shell.go_slots(ShellHost.MODE_SAVE)
			var _saving: CampaignScreen = _show_shell_screen()
		"options":
			shell.go(ShellHost.SCREEN_OPTIONS)
			var _options: CampaignScreen = _show_shell_screen()
		MainMenuScreen.MAIN_MENU:
			# The pause menu's own way out, and the screen has already asked
			# `Txtmod_d` 60. *Without saving* is the whole of it: the mission
			# goes and so does the campaign, exactly as *End game* does from
			# the map.
			_end_campaign()
		"resume":
			close_shell()
		"back":
			var target: String = shell.back_from(shell.screen)
			if target == ShellHost.SCREEN_NONE:
				close_shell()
			else:
				shell.go(target)
				var _up: CampaignScreen = _show_shell_screen()
		"quit":
			# **Never `get_tree().quit()` from a screen.** The audio server
			# needs its frames to let go of a playing stream, and a quit in
			# the same frame leaks it -- which `run_tests.sh` would report as
			# a runtime error and a red run (docs/92 section 7.15).
			_quit()


## Drop the campaign and whatever is on the screen, and come back at the boot
## menu.
##
## Reached from two buttons -- the map's *End game* and the pause menu's *Main
## Menu* -- and written once, because they mean the same thing and the second
## of them was added by copying the first. Both ask `Txtmod_d` 60 first; this
## is only what happens after the answer.
func _end_campaign() -> void:
	if campaign != null:
		campaign.state = null
		campaign.screen = CampaignHost.SCREEN_MAP
	_clear_backdrop()
	_clear_mission()
	var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)


## docs/92 section 7.15 S4 -- the intro, `Video/Seq_1` (logical id 0).
##
## A **named empty step**, not a forgotten one. The sequence player is a slice
## of its own (docs/41 is the spec; nothing plays one yet), and the campaign
## must be reachable before it exists. When the player lands, this is the one
## place it is called from.
##
## TODO: play `Video/Seq_1` (logical id 0) here once the sequence player of
## docs/41 exists.
func _play_intro() -> void:
	pass


func _start_campaign(chain: int) -> void:
	if campaign == null or not CampaignState.FIRST_MISSION.has(chain):
		return
	var _state: CampaignState = campaign.start_new(chain, settings.difficulty)
	_play_intro()
	shell.close()
	var _map: CampaignScreen = show_campaign_screen(CampaignHost.SCREEN_MAP)


## One mission, past the campaign -- what `--mission=` reaches, from a list.
##
## The campaign state is **cleared**, not left over: a mission played this way
## has no roster, no scoreboard and no next mission, and a stale campaign
## behind it would send its debriefing somewhere the player never was.
func _start_instant_action(mission: String) -> void:
	if not _missions.has(mission):
		_refresh_status("the cache has no " + mission)
		return
	if campaign != null:
		campaign.state = null
		campaign.screen = CampaignHost.SCREEN_MAP
	shell.close()
	close_campaign_screen()
	_build(mission)


## Load or save the numbered slot the player clicked.
func _use_slot(slot: int) -> void:
	if campaign == null:
		return
	if shell.slot_mode == ShellHost.MODE_SAVE:
		if campaign.state == null:
			_refresh_status("no campaign to save")
			return
		var stamp: Dictionary = CampaignHost.stamp_now()
		var written: bool = campaign.save(world, slot,
			DictRead.as_int(stamp["when"]),
			DictRead.as_string(stamp["when_text"]))
		_refresh_status("saved to slot %d" % (slot + 1) if written
			else "slot %d refused the write" % (slot + 1))
		var _again: CampaignScreen = _show_shell_screen()
		return
	var loaded: bool = load_slot(slot)
	if not loaded:
		var _back: CampaignScreen = _show_shell_screen()


## Read one slot back and rebuild whatever it was holding.
##
## The order is [method quick_load]'s and for the same reason: the campaign
## names the mission, so it comes back first; then the mission is built; and
## only then is the mission blob handed to [World], which is the one that
## checks the map name.
func load_slot(slot: int) -> bool:
	if campaign == null:
		return false
	var decoded: Dictionary = campaign.load_save(slot)
	var code: int = DictRead.as_int(decoded["result"])
	if code != CampaignCodec.Result.OK:
		_refresh_status("slot %d refused: %s"
			% [slot + 1, CampaignCodec.result_name(code)])
		return false
	var blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	if blob.is_empty():
		shell.close()
		close_campaign_screen()
		var _map: CampaignScreen = show_campaign_screen(CampaignHost.SCREEN_MAP)
		_refresh_status("loaded slot %d" % (slot + 1))
		return true
	_build(campaign.state.mission)
	if world == null:
		_refresh_status("loaded, but the cache has no " + campaign.state.mission)
		return false
	var restored: int = world.load_save(blob)
	if restored != SaveCodec.Result.OK:
		_refresh_status("mission refused: " + SaveCodec.result_name(restored))
		return false
	# **Only now.** Taking the shell down before the world was confirmed left
	# the slot screen on the tree with `shell.is_up()` already false, so the
	# refusal was shown on a plate the shell no longer believed it owned and
	# `Back` from it went nowhere.
	#
	# What it does **not** promise is that a refused load can be undone: by
	# this point `campaign.load_save` has already replaced the campaign and
	# `_build` the world, and the mission blob is the last thing checked
	# because [SaveCodec] needs the world to check it against. A refusal
	# therefore leaves the campaign loaded and its mission freshly built
	# rather than restored -- said in the status line, and the shell stays up
	# so another slot can be picked.
	shell.close()
	close_campaign_screen()
	campaign.enter_mission()
	_refresh_after_deploy()
	_refresh_status("loaded slot %d" % (slot + 1))
	return true


## Step one option to its next value, apply it, and write the file.
##
## Every row here is click-to-cycle, which is also what the original's own
## option icons are. The write is immediate rather than on leaving the screen:
## a settings file that only appeared on a clean exit would lose the choice of
## anyone who closed the window.
func _step_option(name: String) -> void:
	match name:
		"music":
			settings.music_volume = _step_volume(settings.music_volume)
		"fx":
			settings.fx_volume = _step_volume(settings.fx_volume)
		"difficulty":
			if _campaign_difficulty_writable():
				# On the map the campaign is the authority, and the settings
				# keep only the default for the **next** new campaign.
				campaign.state.difficulty = wrapi(
					campaign.state.difficulty + 1,
					GameSettings.DIFFICULTY_MIN,
					GameSettings.DIFFICULTY_MAX + 1)
			else:
				settings.difficulty = wrapi(settings.difficulty + 1,
					GameSettings.DIFFICULTY_MIN,
					GameSettings.DIFFICULTY_MAX + 1)
		"gore":
			settings.gore_level = wrapi(settings.gore_level + 1,
				GameSettings.GORE_MIN, GameSettings.GORE_MAX + 1)
			# The gore level is presentation and outside the canonical hash,
			# so unlike the difficulty it may be applied to a running world.
			if world != null:
				world.gore_level = settings.gore_level
		"faithful":
			settings.faithful = not settings.faithful
		"font":
			settings.game_font = not settings.game_font
			# Every plate and the HUD are rebuilt from one place, so the
			# choice cannot land on some of them and not others.
			_reapply_font()
		_:
			return
	settings.apply_audio(_audio, _events)
	var _written: bool = settings.save_to_disk()
	var options: OptionsScreen = _screen as OptionsScreen
	if options == null:
		return
	# The screen keeps its own copy of the campaign's difficulty -- it is not
	# the settings' -- so a step that wrote the campaign has to hand the new
	# value back, or the row redraws with the value it was built with and the
	# control looks dead while working perfectly.
	if _campaign_difficulty_writable():
		options.campaign_difficulty = campaign.state.difficulty
	options.refresh()


## Put the chosen font on everything that is already on screen.
##
## The screens take theirs at `setup` and the HUD at `_ready`, so a change made
## while one is up has to reach them. The plate that is up is rebuilt rather
## than patched: its labels were made with the old font and a screen is cheap.
func _reapply_font() -> void:
	var font: FontFile = interface_font()
	if _hud != null:
		_hud.use_font(font)
	if _texts != null:
		_texts.use_font(font)
	if _screen != null and shell.is_up():
		var _again: CampaignScreen = _show_shell_screen()
	elif _screen != null and campaign != null:
		var _back: CampaignScreen = show_campaign_screen(campaign.screen)


func _step_volume(hundredths: int) -> int:
	var next: int = hundredths + GameSettings.VOLUME_STEP
	if next > GameSettings.VOLUME_MAX:
		next = GameSettings.VOLUME_MIN
	return next


func close_campaign_screen() -> void:
	if _screen == null:
		return
	remove_child(_screen)
	# **`queue_free`, not `free`.** A screen is almost always taken down from
	# inside one of its own button signals, and Godot locks an object while it
	# is emitting: `free` then fails with "Attempted to free a locked object",
	# the plate stays alive off the tree, and the next screen is stacked on a
	# corpse that is still in the input path. The `remove_child` above is what
	# makes the deferred delete safe -- it is out of the picture and out of
	# the input path this frame, and gone by the end of it.
	_screen.queue_free()
	_screen = null
	_sync_hud()


## The HUD belongs to the mission view and to nothing else.
##
## It used to be left up under every plate, which cost nothing while a plate
## covered the whole screen -- and shows through the moment one has a window
## in it, as the mission's status line drawn across a campaign map.
##
## **The view does not hide it.** `fcn.0041A980` does not read the view mode
## `[0x005106D8]` at all -- corrected 2026-09-05, docs/43 section 2 -- so the
## plate is drawn through the eyes view as through any other; the one thing
## that suppresses it is an `aOptions.cpp` setting (`[0x005129F8] == 1`,
## `0x004604D0`), which this remake does not offer.
func _sync_hud() -> void:
	if _hud != null:
		_hud.visible = _screen == null and world != null
	if _status != null:
		_status.visible = _screen == null
	_frame_mission_camera()


## The mission camera's projection for the window the screen has now.
##
## With the interface up the window is what the plate leaves: `(60, 34)` by
## the canvas less 120 by the canvas less 140 (docs/43 section 7), and the
## focal length stays the original's 400 -- the one `_ftol(520 * 10 / 13)`
## gives -- however wide the window is, so a wider screen shows more world at
## the same scale rather than a larger picture. A campaign screen over the
## mission keeps its own stretched window, as before; the eyes view fills the
## render.
## The window changed shape: the camera's frustum follows it, and so does
## what the interface has already drawn.
##
## The plate's pieces and the two button columns re-anchor themselves on
## `Control.resized`, but the panel's icons and the radar's marks are placed
## where they are *drawn* -- so without this a resize leaves them at the
## anchors of the old canvas until the next command.
func _on_canvas_resized() -> void:
	_frame_mission_camera()
	if _hud != null and _hud.visible and world != null:
		_refresh_status()


func _frame_mission_camera() -> void:
	if _rig == null or _rig.camera() == null or not is_inside_tree():
		return
	var canvas: Vector2 = get_viewport().get_visible_rect().size
	if _screen != null:
		CameraRig.frame_projection(_rig.camera(),
			SelectUnitsScreen.DEPLOY_WINDOW, CampaignScreen.PLATE_SIZE)
		return
	if _hud != null and not _hud.visible:
		CameraRig.frame_projection(_rig.camera(), Rect2(Vector2.ZERO, canvas),
			canvas, 0, float(HudTables.WINDOW.size.x))
		return
	CameraRig.frame_projection(_rig.camera(), HudTables.window_for(canvas),
		canvas, 0, float(HudTables.WINDOW.size.x))


## What a screen's button means. The host owns the state machine; this only
## turns a button into a call on it.
func _on_campaign_choice(action: String) -> void:
	if campaign == null:
		return
	if action.begins_with("pick:"):
		var deploy: SelectUnitsScreen = _screen as SelectUnitsScreen
		if deploy != null:
			deploy.pick(action.substr(5).to_int())
		return
	if action.begins_with("location:"):
		var parts: PackedStringArray = action.split(":")
		if parts.size() >= 3 and parts[2] == CampaignMap.KIND_BATTLE:
			var _shown: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_BRIEFING)
		elif parts.size() >= 3 and parts[2] == CampaignMap.KIND_UPGRADE:
			var _up: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_UPGRADE)
		return
	match action:
		"enter":
			# `_build` takes the campaign map down: the mission's own view is
			# what the deploy screen's window shows.
			_build(campaign.state.mission)
			if world != null:
				campaign.begin_mission(world)
			# **A deployment with nobody to deploy is not a screen.** A chain
			# whose pool is empty and whose mission ships its own squad --
			# campaign 2 on `_C_140`, which is how it starts -- went to a
			# roster of nobody over a map of dots nobody could stand on, and
			# read as the campaign being broken. Where the pool is empty and
			# the mission has no squad either the screen still opens, because
			# then there really is nothing to start and the screen is what
			# says so.
			if campaign.nobody_to_deploy() and campaign.may_start():
				campaign.enter_mission()
				close_campaign_screen()
				_autosave_mission_start()
				return
			var _select: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_SELECT)
		"deployed":
			_refresh_after_deploy()
		"start":
			if campaign.may_start():
				campaign.enter_mission()
				close_campaign_screen()
				_autosave_mission_start()
			else:
				# **Named, not silent.** An empty map refused the button and
				# said nothing, which is what stopped a campaign being
				# startable at all by anyone who did not already know the
				# screen (docs/92 section 7.4).
				var select_screen: SelectUnitsScreen = _screen \
					as SelectUnitsScreen
				if select_screen != null:
					select_screen.say(select_screen.strings_own(
						SelectUnitsScreen.OWN_NEED_ONE))
		"debriefing":
			var _report: Dictionary = campaign.finish_mission(world)
			var _screen_up: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_DEBRIEFING)
		"advance":
			var target: String = campaign.advance()
			if target != "":
				var _map: CampaignScreen = show_campaign_screen(
					CampaignHost.SCREEN_MAP)
		"replay":
			var _again: String = campaign.replay()
			var _back: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_MAP)
		"map":
			# The squad comes back off the map first: the location screen
			# frees the mission's whole scene, and anyone already deployed
			# had been taken out of the pool to stand on it.
			campaign.abandon_mission()
			var _to_map: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_MAP)
		"options":
			# Into the shell, over the map. Leaving it puts the map back --
			# see [method close_shell] -- and the difficulty row is the
			# campaign's here rather than the settings' default.
			var _options: CampaignScreen = open_shell(
				ShellHost.SCREEN_OPTIONS)
		"hq":
			var _hq: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_HQ)
		"recruit":
			var _slot: int = campaign.recruit()
			var hq_screen: HqScreen = _screen as HqScreen
			if hq_screen != null:
				hq_screen.refresh()
		"dismiss":
			var hq: HqScreen = _screen as HqScreen
			if hq != null and hq.selected != Roster.NO_SLOT:
				var _refund: int = campaign.dismiss(hq.selected)
				hq.selected = Roster.NO_SLOT
				hq.refresh()
		"save":
			var stamp: Dictionary = CampaignHost.stamp_now()
			var _written: bool = campaign.save(
				world if campaign.screen == CampaignHost.SCREEN_MISSION
				else null, CampaignHost.QUICK_SLOT,
				DictRead.as_int(stamp["when"]),
				DictRead.as_string(stamp["when_text"]))
		"weapons", "equipment":
			var catalogue: UpgradeScreen = _screen as UpgradeScreen
			if catalogue != null:
				catalogue.catalogue_kind = action
				catalogue.refresh()
		"tips":
			# One button for both directions, because the screen is one screen
			# -- `Txtmod_b` carries *Tips* and *Briefing* for exactly this and
			# the title stays *Briefing* either way (docs/24 section 7.1).
			var brief: BriefingScreen = _screen as BriefingScreen
			if brief != null:
				brief.show_block("A0" if brief.block == "C0" else "C0")
		"end_game":
			# `Txtmod_b` 18, and the map screen has already asked.
			_end_campaign()


## The missions the manifest declares, in the order the converter emitted them.
func _missions_in(manifest: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var names: Array = DictRead.as_array(manifest.get("missions", []))
	for entry: Variant in names:
		out.append(DictRead.as_string(entry))
	return out


## The runner is loaded by path, never named as a class: the shipping preset
## excludes `tests/`, and a `TestRunner` identifier here would stop `main.gd`
## itself from compiling in that build -- which is exactly what happened once,
## and is why the shipping export is now launched as part of verifying a change.
## Closing the window, and the platform gestures that mean the same thing.
##
## `auto_accept_quit` is off (see `_ready`), so nothing quits until this does.
## The guard matters: on macOS a Cmd-Q while the shutdown is already awaiting
## delivers the notification again, and two overlapping shutdowns would call
## `quit` twice.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST \
			or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_quit()


func _quit() -> void:
	if _quitting:
		return
	_quitting = true
	if _audio != null:
		var _frames: int = await _audio.shutdown()
	get_tree().quit()


## The runner this build carries, or `null` when it carries none.
func _test_runner() -> GDScript:
	if not ResourceLoader.exists(TEST_RUNNER):
		push_warning("%s asked for tests, but %s is not in this build"
			% [TEST_FEATURE, TEST_RUNNER])
		return null
	var script: GDScript = ResourceLoader.load(TEST_RUNNER, "GDScript") \
		as GDScript
	if script == null or not script.can_instantiate():
		push_warning("%s did not load" % TEST_RUNNER)
		return null
	return script


## Run the suites **one per frame**, over a window that says what it is.
##
## The whole run used to happen inside `_ready`, which is a black frozen
## window for the forty seconds it takes -- indistinguishable from a hang, and
## reported as one. A suite between two frames costs the run nothing and gives
## the window a caption and a count that move.
##
## The runner is reached by name rather than by class: `tests/` is not in the
## shipping preset, so a direct `TestRunner.run_all()` here would stop
## `main.gd` from loading in the build that matters.
func _run_tests_and_quit(script: GDScript) -> void:
	var note: Label = Label.new()
	note.set_anchors_preset(Control.PRESET_FULL_RECT)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var layer: CanvasLayer = CanvasLayer.new()
	layer.add_child(note)
	add_child(layer)
	var count: int = DictRead.as_int(script.call("suite_count"))
	note.text = TEST_CAPTION % [0, count,
		DictRead.as_string(script.call("suite_name", 0))]
	# Two frames: the first draws the caption, the second makes sure it is on
	# the screen before the main thread stops answering for a suite's length.
	await get_tree().process_frame
	await get_tree().process_frame
	var harness: Variant = script.call("begin_run")
	for index: int in range(count):
		# The name matters as much as the number: the count stands still for
		# the length of a suite, and the longest of them is a minute.
		note.text = TEST_CAPTION % [index, count,
			DictRead.as_string(script.call("suite_name", index))]
		await get_tree().process_frame
		script.call("run_suite_at", harness, index)
	note.text = TEST_CAPTION % [count, count, ""]
	var code: int = DictRead.as_int(script.call("finish_run", harness))
	# **Not in the same frame as the last suite.** docs/97 section 14 found the
	# same shape in the audio shutdown: quitting inside the frame that let go
	# of the last reference leaves the release to the engine's own teardown.
	await get_tree().process_frame
	get_tree().quit(code)


func _fail(reason: String) -> void:
	_status.text = reason
	push_error(reason)


## Builds one mission.  Called again for every mission switch, so it frees the
## previous scene first: the whole visible tree is rebuilt from the world's
## views, and nothing is carried across.  Geometry and textures are kept per
## world set, because two of the slice's three missions share `A00`.
# --- the campaign map as a picture --------------------------------------------

## Which cell each location stands on, out of a campaign map's own action
## points (docs/27 section 2.1: *a location is an action point*).
##
## Static and taking a [World], so a suite can ask it the question without a
## scene: the answer is the whole of what makes the dots land where the chain
## says they do.
static func location_cells_of(map: World) -> Dictionary[int, Vector2i]:
	var out: Dictionary[int, Vector2i] = {}
	if map == null:
		return out
	var width: int = map.resource.width
	for y: int in range(map.resource.height):
		for x: int in range(width):
			var id: int = map.state.action_point_at(y * width + x)
			if id > 0 and not out.has(id):
				out[id] = Vector2i(x, y)
	return out


## The chain's own map as a **picture**: terrain and scenery, no script, no
## simulation and no effects.
##
## `_C_XXX` and `_C_YYY` are ordinary `.lev` files, so the mission renderer
## draws them unchanged -- but their `.lcl` is the original front end's and is
## deliberately not run, and nothing here is played, so none of `_build`'s
## simulation half applies.
func _build_backdrop(mission: String) -> void:
	if _backdrop_root != null and _backdrop_mission == mission:
		return
	_clear_backdrop()
	var balance: Dictionary = CacheLoader.read_json(
		_cache_dir + "/tables/balance.json")
	var map_document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, mission])
	if balance.is_empty() or map_document.is_empty():
		# A cache published with the six default missions carries no campaign
		# map. The screen still opens -- the frame, the buttons and the
		# locations' names are all it needs -- and the window shows nothing.
		_refresh_status("cache does not contain " + mission)
		return
	var header: Dictionary = DictRead.as_dict(map_document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = _geometry_for(world_set)
	var textures: Dictionary = _textures_for(world_set)
	_backdrop_world = World.create(map_document, balance, 1.0,
		DictRead.to_strings(geometry.get("special_models", [])))
	_backdrop_mission = mission
	_location_cells = location_cells_of(_backdrop_world)
	# **The one part of the script this picture does run.** `_C_XXX.lcl` and
	# `_C_YYY.lcl` are ordinary mission scripts whose `InitMap` is four
	# `CreateBGB` fires and a `CDTrackProgram`, and nothing else -- no camera,
	# no simulation, nothing a turn would reach. Running it is what makes the
	# city burn; the events it records are read for `create_bgb` and for
	# nothing else, so the rest of `_build`'s simulation half still does not
	# apply here.
	var opening: Dictionary = {}
	if _backdrop_world.attach_script(CacheLoader.read_json(
			"%s/missions/%s/script.json" % [_cache_dir, mission])):
		opening = _backdrop_world.run_init_map()

	_backdrop_root = Node3D.new()
	_backdrop_root.name = "Backdrop_" + mission
	add_child(_backdrop_root)

	var scenery: Scenery = Scenery.new()
	scenery.name = "Scenery"
	_backdrop_root.add_child(scenery)
	scenery.build(map_document, geometry, textures)
	var _placed: int = scenery.apply_all(_backdrop_world.terrain_snapshot())

	_backdrop_rig = CameraRig.new()
	_backdrop_rig.name = "CameraRig"
	_backdrop_rig.eng3d = _eng3d
	_backdrop_root.add_child(_backdrop_rig)
	_backdrop_rig.setup(_backdrop_world.resource.width,
		_backdrop_world.resource.height, _backdrop_world.resource.heights(),
		_backdrop_world.resource.camera_height)
	# Eng3d's own perspective for the map's 518x306 window, which is not the
	# render's centre: the plate is drawn as strips around it, so the window
	# sits thirty pixels above the middle of the picture.
	CameraRig.frame_projection(_backdrop_rig.camera(),
		CampaignScreen.PLATE_WINDOW, CampaignScreen.PLATE_SIZE)
	_backdrop_rig.camera().current = true

	var environment: WorldEnvironment = WorldEnvironment.new()
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(18, 20, 26)
	environment.environment = env
	_backdrop_root.add_child(environment)

	_build_backdrop_fires(mission, geometry, textures, opening)



## The campaign map's four burning buildings.
##
## A pool of its own, because the mission's is gone by the time this runs and
## the two never coexist. It is the sprite half only: `CreateBGB` type 7 makes
## class-3 records, which are atlas tiles, so there is no model half to build
## and no cell placers, triggers or sequences either.
##
## The seed is the map's name, as a mission's is its own, so the fires look the
## same every time the map is raised without any of it reaching a world.
func _build_backdrop_fires(mission: String, geometry: Dictionary,
		textures: Dictionary, opening: Dictionary) -> void:
	_backdrop_fx = BlobPool.create(float(hash(mission) % 1000000 + 1))
	var hooks: GameBlobHooks = GameBlobHooks.over(_backdrop_fx, null)
	hooks.rng.randomize_seed(_backdrop_fx.hooks().rng.seed)
	_backdrop_fx.set_hooks(hooks)
	_backdrop_hooks = hooks
	var prototypes: Dictionary = DictRead.as_dict(
		geometry.get("prototypes", {}))
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	hooks.model_index = index
	if _eng3d == null:
		_eng3d = Eng3dGeometry.from_cache(_cache_dir)
	hooks.geometry = _eng3d
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.gore = BlobPrograms.GORE_FULL
	inputs.display_mode = DISPLAY_MODE
	inputs.models = index
	inputs.geometry = _eng3d
	hooks.inputs = inputs

	_backdrop_bgb = BgbEmitters.create()
	var _lit: int = _register_emitters(_backdrop_bgb, opening,
		_backdrop_hooks)
	_backdrop_music = _map_music_program(opening)
	_backdrop_carry = 0.0

	_backdrop_sprites = BlobSprites.new()
	_backdrop_sprites.name = "Effects"
	_backdrop_root.add_child(_backdrop_sprites)
	var by_name: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.BY_NAME, {}))
	var plain: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.PLAIN, {}))
	var atlas_id: int = DictRead.as_int(by_name.get(ATLAS_TEXTURE, -1))
	var atlas: Texture2D = plain.get(atlas_id) if plain.has(atlas_id) else null
	if atlas != null:
		_backdrop_sprites.setup(atlas, _blob_tables)


## The `CDTrackProgram` argument out of a script run's events, or `""`.
##
## docs/20 section 7.3: the command takes one string and 111 of the shipped
## missions call it, always from `INIT MAP`. A map that calls it twice keeps
## the last, which is what the engine's own single global does.
func _map_music_program(outcome: Dictionary) -> String:
	if outcome.is_empty():
		return ""
	var program: String = ""
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if event.is_empty() or AudioEvents.name_of(event) != CD_TRACK_PROGRAM:
			continue
		var values: Array = DictRead.as_array(event.get("values", []))
		if not values.is_empty():
			program = DictRead.as_string(values[0])
	return program


## One frame of the map's own effects, on the same 20 fps clock a mission's
## run at.
func _tick_backdrop_fires(delta: float) -> void:
	if _backdrop_fx == null or _backdrop_bgb == null:
		return
	_backdrop_carry += delta * CharismaState.FRAMES_PER_SECOND
	var ticks: int = mini(int(_backdrop_carry), MAX_EFFECT_TICKS)
	_backdrop_carry -= float(int(_backdrop_carry))
	for _step: int in range(ticks):
		var _lit: int = _backdrop_bgb.tick(_backdrop_fx, _backdrop_hooks)
		var _results: Array[BlobKinds.TickResult] = _backdrop_fx.tick_all()
	if _backdrop_sprites != null and _backdrop_rig != null \
			and _backdrop_rig.camera() != null:
		var _drawn: int = _backdrop_sprites.rebuild(_backdrop_fx.blobs(),
			_backdrop_rig.camera().global_transform.basis)


## Put the map's camera where `aMissionControl.cpp` puts it.
##
## [constant CameraRig.CAMPAIGN_EYE] and [constant CameraRig.CAMPAIGN_TARGET]
## are the engine's own six numbers, so this is a set and not a fit: the
## original's campaign map is one fixed view of the city for both chains and
## for every mission in them.
##
## Still called every time the map is raised rather than once when the picture
## is built, because the mission's own rig takes the camera in between.
func _frame_map() -> void:
	if _backdrop_rig == null:
		return
	# `0x004554C9` zeroes the accumulator when the map is raised, so a turn
	# does not survive the mission that was entered from it.
	_backdrop_rig.reset_map_swing()
	_swing_carry = Vector2.ZERO
	_backdrop_rig.set_now(CameraRig.CAMPAIGN_EYE, CameraRig.CAMPAIGN_TARGET)


func _clear_backdrop() -> void:
	if _markers != null and _markers.get_parent() == _backdrop_root:
		_markers = null
	if _backdrop_root != null:
		remove_child(_backdrop_root)
		_backdrop_root.free()
	_backdrop_root = null
	_backdrop_rig = null
	_backdrop_world = null
	_backdrop_mission = ""
	# The pool and the sprites were children of the root that has just been
	# freed; the handles go with them, or the next frame ticks a freed node.
	_backdrop_fx = null
	_backdrop_hooks = null
	_backdrop_bgb = null
	_backdrop_sprites = null
	_backdrop_carry = 0.0
	_backdrop_music = ""
	_swing_carry = Vector2.ZERO
	_location_cells.clear()


## The dots on whichever 3D scene is up.
func _show_markers(marks: Dictionary[Vector2i, int]) -> void:
	var scene: Node3D = _backdrop_root if _backdrop_root != null \
		else _scene_root
	var at: World = _backdrop_world if _backdrop_root != null else world
	if scene == null or at == null:
		_markers = null
		return
	if _markers == null or _markers.get_parent() != scene:
		_markers = MapMarkers.new()
		_markers.name = "Markers"
		scene.add_child(_markers)
	_markers.show_marks(_art, marks, at.resource.heights(),
		at.resource.width)


## Take the mission's whole scene down and forget the world it drew.
##
## Called at the head of every [method _build] and by the campaign map, which
## replaces the mission's view with the chain's own: two 3D scenes under the
## same root would render into one another, and the map is drawn around a hole
## in its plate rather than over it.
func _clear_mission() -> void:
	# The dots may be the **campaign map's**, hanging off the backdrop rather
	# than off this scene; only the handle to a set that is about to be freed
	# with the scene is dropped. Nulling it either way left a second markers
	# node behind on the backdrop, drawn over the first.
	if _markers != null and _markers.get_parent() == _scene_root:
		_markers = null
	if _scene_root != null:
		remove_child(_scene_root)
		_scene_root.free()
	# `queue_free` is deferred, so the tree is torn down with `free()` -- which
	# means every handle into it is dangling the instant it returns.  They are
	# cleared here rather than only reassigned at the end, because `_build` has
	# an early return: leaving them set while `world` still held the previous
	# mission let `_unhandled_input`'s `world == null` guard pass and then call
	# into a freed node.
	_scene_root = null
	_scenery = null
	_overlay = null
	_ground = null
	_hover = Vector2i(-1, -1)
	_bands.clear()
	_pending_turn = {}
	if _hud != null:
		_hud.ring.take_down()
	_units = null
	_special = null
	_rig = null
	# **Everything [method _process] touches, not only what [method _build]
	# happened to reset first.** This used to be `_build`'s own head and so
	# only ever ran with a rebuild immediately behind it; the campaign map
	# calls it and then leaves the game with no world for as long as the map
	# is up. `_sprites` and `_models` are children of the scene that was just
	# freed, so a frame after this with either still set called a method on a
	# freed instance -- and `_fx` and `_special` would have gone on ticking a
	# pool for a mission that is not there.
	_sprites = null
	_models = null
	_fx = null
	_fx_carry = 0.0
	_triggers = null
	_sequences = null
	_director = null
	_walk_cameras.clear()
	_footstep_cues.clear()
	_pending_reactions.clear()
	_drawn_terrain = {}
	_last_query = null
	world = null
	_selected = -1
	# `SaveCamera` puts six numbers here and `LoadCamera` takes them out
	# (docs/42 section 2.4). A mission whose script saves without loading
	# would otherwise hand its coordinates to the next mission's first
	# `LoadCamera`, which is a flight to a cell on a map that is gone.
	_saved_cameras.clear()
	# `FloatingTexts` outlives `_build` -- it is a `CanvasLayer` made in
	# `_ready` -- but the queue that clears it does not, so a mission changed
	# while a damage number was rising left the Label on screen with a frozen
	# countdown.
	if _texts != null:
		_texts.clear()
		_texts.clear_caption()


func _build(mission: String) -> void:
	_clear_backdrop()
	_clear_mission()
	_mission = mission

	var balance: Dictionary = CacheLoader.read_json(
		_cache_dir + "/tables/balance.json")
	var map_document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, mission])
	if balance.is_empty() or map_document.is_empty():
		_fail("cache does not contain %s" % mission)
		return

	# The world set's placer models come from the geometry document, because
	# that is where the converter records which prototypes the set has: a
	# `SetGroundFire` outside `World_D00` must write nothing, exactly as the
	# engine's constructor refuses the name (docs/42 section 9.1).
	var set_name: String = DictRead.as_string(
		DictRead.as_dict(map_document["header"])["world_set"])
	world = World.create(map_document, balance, 1.0,
		DictRead.to_strings(_geometry_for(set_name).get("special_models", [])))
	# **Before** the script runs and before the first hand-over. `ai_level`
	# steers the movement allowance and the experience multiplier, and it is
	# item 5 of the canonical hash, so it has to be right from the world's
	# first byte rather than applied to a running one (docs/92 section 7.15).
	settings.apply_world(world, difficulty_now())
	# The mission's own program, so the turn runs the script the way the engine
	# does. A mission with none still plays: `attach_script` returns false and
	# `World`'s default runner lets every hand-over through.
	var attached: bool = world.attach_script(CacheLoader.read_json(
		"%s/missions/%s/script.json" % [_cache_dir, mission]))
	# `INIT MAP` is the entry point the loader runs once, before any turn
	# (docs/20 section 5), and it is what names the successor map.
	var opening_script: Dictionary = {}
	if attached:
		opening_script = world.run_init_map()
	var header: Dictionary = DictRead.as_dict(map_document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	var geometry: Dictionary = _geometry_for(world_set)
	var textures: Dictionary = _textures_for(world_set)
	_geometry = geometry
	_textures = textures

	_scene_root = Node3D.new()
	_scene_root.name = "Mission_" + mission
	add_child(_scene_root)

	_scenery = Scenery.new()
	_scenery.name = "Scenery"
	_scene_root.add_child(_scenery)
	_scenery.build(map_document, geometry, textures)
	# The scenery is placed from the `.lev`, so a mission resumed from a save
	# with a door already open needs the offset applied before the first
	# frame -- otherwise the picture would be right only after something
	# changed, which is the defect this closes rather than a version of it.
	var _placed: int = _scenery.apply_all(world.terrain_snapshot())

	_overlay = TerrainOverlay.new()
	_overlay.name = "TerrainOverlay"
	_scene_root.add_child(_overlay)
	_drawn_terrain = world.terrain_snapshot()
	_overlay.build(_drawn_terrain)

	_ground = GroundSprites.new()
	_ground.name = "Ground"
	_scene_root.add_child(_ground)

	_units = UnitsView.new()
	_units.name = "Units"
	# The bodies and their clips, opened once per mission. `UnitsView.build`
	# runs on every fog change, and re-parsing a 26-part body or re-building
	# its meshes each time would be a cost this slice invented for itself.
	_units.library = CharismaLibrary.open(_cache_dir, textures, mission)
	_scene_root.add_child(_units)
	_units.build(world, geometry, textures)

	_build_effects(mission, world_set, textures)
	var _emitters: int = _register_emitters(_bgb, opening_script,
		_fx_hooks)
	# `INIT MAP` is where every shipped mission puts its `CDTrackProgram`, and
	# the return value was being discarded. The set pieces it may also run are
	# applied by `core` before this point, so what is left for `game` is the
	# sound and the picture.
	_present_script(opening_script)

	_rig = CameraRig.new()
	_rig.name = "CameraRig"
	_rig.eng3d = _eng3d
	_scene_root.add_child(_rig)
	_rig.setup(world.resource.width, world.resource.height,
		world.resource.heights(), world.resource.camera_height)
	# The same rule with the **mission's** own window, `0x00419D90`'s
	# `(60, 34)` by 520x340: a focal length of 400 rather than the map's 398,
	# and an axis four pixels right and thirty-six pixels up of centre --
	# and, with the interface up, the window the plate leaves on this canvas
	# ([method _frame_mission_camera]).
	_rig.camera().current = true
	_frame_mission_camera()
	_director = CameraDirector.create(_rig)
	_walk_cameras.clear()
	_frame_units(world)

	var environment: WorldEnvironment = WorldEnvironment.new()
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color8(18, 20, 26)
	environment.environment = env
	_scene_root.add_child(environment)

	_refresh_status()


## The sound layer, opened on demand.
##
## It used to be built only by [method _build_effects], which is a mission's
## own path -- so the campaign map, which is shown before any mission and
## after every one, had no way to reach it and its `CDTrackProgram` played
## nowhere. *quiet* says whether whatever is already sounding should be cut
## first: a mission cuts the map, and the map's own arrival does not cut the
## mission it is being shown over.
func _open_audio(quiet: bool) -> AudioSystem:
	var tables: AudioTables = AudioTables.open(_cache_dir)
	_blob_tables = CacheLoader.read_json(_cache_dir + "/tables/blobs.json")
	_events = AudioEvents.open(tables, _blob_tables)
	if _audio == null:
		_audio = AudioSystem.new()
		_audio.name = "Audio"
		add_child(_audio)
		_audio.setup(tables, _events)
	elif quiet:
		_audio.stop_all()
		_audio.stop_music()
	return _audio


## The campaign map's own `CDTrackProgram`, played from the same `INIT MAP`
## run its fires come from.
##
## `_C_XXX.lcl`'s whole script is four `CreateBGB` lines and one
## `CDTrackProgram ("5.3.4.2")`; the first half was written down and consumed
## by nothing until this slice, and this is the second. Called on every
## arrival at the map rather than on the backdrop's build, because the
## backdrop survives a mission and the music does not -- but only when the
## programme is not already the one playing, so stepping in and out of a
## briefing does not restart the track.
func _play_map_music() -> void:
	if _backdrop_music.is_empty() or _cache_dir.is_empty():
		return
	if _audio != null and _audio.music_source() \
			== AudioSystem.MUSIC_PROGRAM + _backdrop_music:
		return
	var audio: AudioSystem = _open_audio(true)
	settings.apply_audio(audio, _events)
	var _track: int = audio.start_program(_backdrop_music)


## The sound layer and the blob pool, per mission.
##
## Both read the cache and nothing else; a cache converted with `--no-music`,
## or one whose world set has no `anim` texture, makes the mission quieter or
## plainer rather than making it fail. That is the same policy the original
## has for an effect whose model is missing (docs/28 section 7.5) and for a
## sound that finds no free buffer (section 7.1).
func _build_effects(mission: String, world_set: String,
		textures: Dictionary) -> void:
	var _sound: AudioSystem = _open_audio(true)
	settings.apply_audio(_audio, _events)
	# After the volumes, so the first track opens at the chosen one rather
	# than at full and then dropping.
	var _first: int = _audio.start_music(mission)

	# The pool is seeded from the mission name, so a mission's particles look
	# the same every run without any of it reaching `World.rng` -- which is
	# item 5 of the canonical hash and must not learn about the frame rate.
	_footstep_cues.clear()
	_fx = BlobPool.create(float(hash(mission) % 1000000 + 1))
	# An arm's spawn request is **run** in a mission rather than written down
	# ([GameBlobHooks]); the diff's own hooks keep recording it, which is what
	# `tests/test_blob.gd` compares. The pool's seeded stream is carried over
	# so the mission still looks the same every run.
	var arm_hooks: GameBlobHooks = GameBlobHooks.over(_fx, null)
	arm_hooks.rng.randomize_seed(_fx.hooks().rng.seed)
	_fx.set_hooks(arm_hooks)
	_fx_hooks = arm_hooks
	# `CreateBGB`'s table is the script's own effects, so it is built with the
	# pool and filled from `INIT MAP` once that has run.
	_bgb = BgbEmitters.create()
	# The pool resolves a model name against **this world set's** prototypes.
	# A blob model the set does not carry comes back -1 and the effect is
	# cancelled, which is the original's own behaviour: four of the thirty
	# exist in one or two sets only (docs/28 section 7.5).
	var prototypes: Dictionary = DictRead.as_dict(
		_geometry.get("prototypes", {}))
	var index: Dictionary[String, int] = {}
	var next_id: int = 0
	for name: Variant in prototypes:
		index[DictRead.as_string(name)] = next_id
		next_id += 1
	_fx.hooks().model_index = index
	# The engine's own sine and arctangent tables, so the orientation service
	# is `0x00403AA0`'s **measured** arithmetic -- a 4096-unit yaw and a pitch
	# measured from level -- rather than the 65536ths substitute docs/28
	# section 12 item 1 had to stand in with. Read once and shared: the tables
	# are one content across all 21 world sets.
	if _eng3d == null:
		_eng3d = Eng3dGeometry.from_cache(_cache_dir)
	_fx.hooks().geometry = _eng3d
	# What a creator an arm calls reads. Built after the model index and the
	# geometry, because it is made of them.
	arm_hooks.inputs = _position_inputs()
	# One `aRandom2` stream for the effects, the idle scheduler and the idle
	# selector's coin, as the engine keeps one (`0x00514070`).
	if _units != null:
		_units.presentation_rng = _fx.hooks().rng
		_units.scheduler.ask_for_mission(mission)
	_triggers = BlobTriggers.open(_fx, _blob_tables)
	_sequences = SequenceQueue.create(_audio)
	_fx_carry = 0.0
	_sprites = BlobSprites.new()
	_sprites.name = "Effects"
	_scene_root.add_child(_sprites)
	# The other half of the pool: the class-0 and class-1 blobs, which draw
	# geometry and -- for kinds 42 and 54 -- move their models' joints.
	_models = BlobModels.new()
	_models.name = "EffectModels"
	_scene_root.add_child(_models)
	_models.setup(prototypes, textures, index)
	# docs/42 section 9.1 -- the fires, mines, shields and glows the cell
	# placers leave. Not blobs: they live on the cell bytes and outlive every
	# frame, so they get their own node and their own refresh.
	_special = SpecialObjects.new()
	_special.name = "SpecialObjects"
	_scene_root.add_child(_special)
	_special.setup(prototypes, textures, index, _fx.hooks().rng)
	var _synced: PackedInt32Array = _special.sync(world.terrain_snapshot())
	var by_name: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.BY_NAME, {}))
	var plain: Dictionary = DictRead.as_dict(
		textures.get(MeshBuilder.PLAIN, {}))
	var atlas_id: int = DictRead.as_int(by_name.get(ATLAS_TEXTURE, -1))
	var atlas: Texture2D = plain.get(atlas_id) if plain.has(atlas_id) else null
	if atlas == null:
		push_warning("effects: %s has no '%s' texture; sprite effects will "
			% [world_set, ATLAS_TEXTURE] + "not be drawn")
	_sprites.setup(atlas, _blob_tables)


func _geometry_for(world_set: String) -> Dictionary:
	if not _geometry_cache.has(world_set):
		_geometry_cache[world_set] = CacheLoader.read_json(
			"%s/geometry/%s.json" % [_cache_dir, world_set])
	return DictRead.as_dict(_geometry_cache[world_set])


func _textures_for(world_set: String) -> Dictionary:
	if not _texture_cache.has(world_set):
		var index: Dictionary = CacheLoader.read_json(
			"%s/textures/%s/index.json" % [_cache_dir, world_set])
		_texture_cache[world_set] = MeshBuilder.load_textures(
			_cache_dir, world_set, index)
	return DictRead.as_dict(_texture_cache[world_set])


## Steps to another mission in the cache, wrapping at both ends.
func show_mission(step: int) -> void:
	if _missions.size() < 2:
		return
	var at: int = _missions.find(_mission)
	_build(_missions[posmod(at + step, _missions.size())])


## Submits the movement query for one slot and highlights the answer.
## Public because a screenshot or a demo run drives the same path a click does;
## the scene never becomes the source of the selection either way.
func select_unit(slot: int, pass_friendlies: bool) -> MoveMapResult:
	_selected = slot
	world.selected_slot = slot
	var result: MoveMapResult = world.submit_move_query(
		MoveQueryCommand.create(slot, pass_friendlies))
	_last_query = result
	# `0x00472990`: the select resets the cells, fills the move map and stamps
	# the target overlay -- the bands the ground shows and the shooter turns
	# towards.
	_bands = world.target_bands(slot)
	_hud.ring.take_down()
	_refresh_overlay()
	# docs/42 section 7.3: the select routine `0x00471E00` raises the four
	# arrows once (`0x00473920`), and they live their fifteen ticks.
	_raise_marker()
	var view: Dictionary = world.unit_view(slot)
	# docs/29 section 3's command 2 is "execute the selected-unit/map **focus**
	# path": selecting a unit puts the camera on it. The engine's own select
	# camera is not traced (docs/42 section 2.6), so this is the remake's:
	# [method CameraRig.focus_on] flies the target to the unit and keeps the
	# eye's offset, so a selection re-centres the view without throwing away
	# how the player had arranged it.
	if _director != null:
		var _flight: float = _director.select(world, slot)
	_refresh_status("slot %d %s: %d reachable, %d warp, mp %d, pf %s" % [
		slot, DictRead.as_string(view["name"]), result.reachable_count(),
		result.warp_count(), result.mp, str(pass_friendlies)])
	return result


func selected_slot() -> int:
	return _selected


## Drops the selection here and in `core`, which reads it for exactly one
## rule -- the platform's closing rebuild (docs/22 section 9.4).
func _deselect() -> void:
	_selected = -1
	_last_query = null
	_bands.clear()
	if _hud != null:
		_hud.ring.take_down()
	if world != null:
		world.selected_slot = MapState.NO_UNIT
	_refresh_overlay()


## Select the next unit the current player owns, and look at it.
##
## docs/29 section 3's command 14. It is the only way to reach a unit that is
## off screen: the view has no pan, so a squad member the camera is not
## pointing at cannot be clicked. Returns the slot, or -1 when there is none.
func cycle_friendly() -> int:
	var slot: int = next_friendly_slot(world, _selected)
	if slot < 0:
		return -1
	var _map: MoveMapResult = select_unit(slot, false)
	# docs/42 section 2.3's cycle row: `0x00453D42` places the camera on the
	# unit with `(8, 7, 0)`, which is the engine's own answer to a squad
	# member the camera is not pointing at.
	if _director != null:
		var _flight: float = _director.cycle(world, slot)
	return slot


func camera_rig() -> CameraRig:
	return _rig


func camera_director() -> CameraDirector:
	return _director


## Open the camera on the player's squad rather than on the map's centre.
##
## [method CameraRig.setup] parks the pivot on the middle cell, which is where
## the mission happens to have put its geometry and not where the player's
## units are: on `_C_140` the centre is inside a support column, so the first
## frame of the game is a close-up of a pillar.
##
## This is what the original does: on load it shows the squad, close, rather
## than the middle of the map from under the ceiling.
##
## Two things were wrong with the old opening view and each had to be fixed
## separately, which is why the first attempt made it worse rather than better:
##
## * **the pivot.** `CameraRig.setup` parks it on the middle cell, which is
##   where the mission happens to have put its geometry -- on `_C_140` that is
##   inside a support column. The squad is what the player is about to act
##   with, so the view opens there instead. It is **one unit's cell, not the
##   squad's centroid**: a centroid is not a cell anybody stands on, and the
##   mean of `_C_140`'s four marines lands inside the wall between them;
## * **the zoom.** `setup` opens at the mission's authored `camera_height`,
##   20 m on `_C_140`, and at 20 m the camera sits **above the level's roof**
##   and looks down through it -- these maps are interiors. So moving the pivot
##   alone still showed a ceiling, and 12 m still showed the dark side of one.
##   [constant OPENING_ZOOM_METRES] puts the camera under it.
##
## The maximum is untouched: the player can still pull out to what the mission
## authored. This is where the view *starts*. The yaw is left alone too -- it
## is the player's, on Q and E.
##
## Nothing here is authoritative and nothing here is simulation: a camera that
## opened somewhere else would change no hash and no result.
func _frame_units(mission_world: World) -> void:
	# **One unit's cell, not the squad's centroid.** The centroid is not a cell
	# anybody stands on: on `_C_140` the mean of four marines lands inside the
	# wall between them, and the camera opens in the dark. A unit's own cell is
	# somewhere the simulation has already agreed is standable and open.
	#
	# The placement is the engine's "on the unit" view, `(8, 7, 0)` from the
	# current quadrant with the free-position search (docs/42 section 2.3),
	# settled at once because there is no previous view to fly from.
	var slot: int = focus_on_friendly(_rig, mission_world)
	if slot < 0:
		return
	if _director != null:
		var _flight: float = _director.view_unit(mission_world, slot)
	_rig.settle()


## The next unit the current player may command, after `after` and wrapping.
##
## Interface event **12**, *Jump to the next unit* (docs/43 section 5.2):
## `0x00471E00(1)` walks the 200 slots with `0x00477D40`. `after` of -1 asks
## for the first; -1 comes back when the current player has nothing on the
## map it may select.
##
## **The gate is [method World.may_select], the same one a click goes
## through**: `0x00477D40`'s three tests are `+0x16` alive, `+0x45` the
## player it is passed and `+0x15` not zero, and `may_select` is exactly
## those over [method World.may_command]. Owner alone is not enough: a dead squad
## member stays in `unit_slots()` and the fog pass leaves an own corpse fully
## visible, so a cycle that filtered on the player byte would offer a body
## the mouse refuses -- and the hand-back below would park the camera on it.
##
## A contact is excluded on top of that even though a friendly one cannot
## occur: the rule is "a cell the player can click", and [method
## Fog.is_contact] is what decides that everywhere else.
static func next_friendly_slot(mission_world: World, after: int) -> int:
	var slots: PackedInt32Array = mission_world.unit_slots()
	var start: int = slots.find(after) + 1
	for step: int in range(slots.size()):
		var slot: int = slots[(start + step) % slots.size()]
		# `0x00477D40`: the next unit **with movement points** -- a unit that
		# has none cannot be selected (docs/43 section 4).
		if not mission_world.may_select(slot):
			continue
		var view: Dictionary = mission_world.unit_view(slot)
		if view.is_empty() or not Fog.is_drawn(view) or Fog.is_contact(view):
			continue
		return slot
	return -1


## Put the camera pivot on the current player's first unit. Returns the slot,
## or -1 when there is nothing to look at and the view is left alone.
##
## **This is what ends the computer's turn**, and it is the remake's decision
## rather than a traced one: docs/29 section 3's command 2 is the engine's
## selected-unit/map focus path, but that the engine runs it on hand-over is
## **UNVERIFIED**. What is not a decision is the problem it solves.
##
## The replay leads the camera to every alien it shows ([method _on_ai_step]),
## and there is no way to pan -- the only things that move the pivot are a
## selection and this. So a replay that finished at the far corner of the map
## left the player looking at an empty floor with their own squad off screen
## and nothing on it to click: the turn had been handed back, and the game
## looked frozen. Measured on `_C_140` with the replay driven from a script:
## from turn 4 on, **0 of 4** of the squad were inside the viewport when the
## player got the turn back, and 4 of 4 with this in place.
##
## Static, and taking the rig, so the suite can check it against a real world
## without standing a scene up.
##
## The zoom and the yaw are **not** touched. They are the player's, on Q, E and
## the wheel; only [method _frame_units] sets them, and only at load.
static func focus_on_friendly(rig: CameraRig, mission_world: World) -> int:
	if rig == null:
		return -1
	var slot: int = next_friendly_slot(mission_world, -1)
	if slot < 0:
		return -1
	var view: Dictionary = mission_world.unit_view(slot)
	var x: int = DictRead.as_int(view["x"])
	var y: int = DictRead.as_int(view["y"])
	if not mission_world.state.in_bounds(x, y):
		return -1
	var _flight: int = rig.focus_on(x, y,
		mission_world.state.height_at(mission_world.state.index_of(x, y)))
	return slot


## Give the computer's event to the body it is about.
##
## This is why the `move` event carries its route (`docs/96`): by the time the
## playback reaches event *i* the world is already at the end of the turn, so
## the path cannot be re-derived here -- it would be derived against the wrong
## state. The event brought it.
##
## It is called **after** `_on_ai_step`'s own rebuild, never before: that
## rebuild frees every unit node and clears the bodies, the states and the
## walks. The *next* event's rebuild ending this walk is the design; this
## event's rebuild ending it was a bug that made the computer's units teleport
## and never play `F`.
##
## **It owns the shot as well as the body.** The effects and the sounds of a
## shot used to be a second, partial copy in [method _present_ai_event] that
## dropped the pain screams, while the body was started here -- two owners
## for one event, and only one of them could report a length.
##
## Returns how long the event needs on screen, which for a move is its walk.
func _play_event_body(event: Dictionary, kind: String) -> float:
	var slot: int = DictRead.as_int(event["slot"])
	if kind == "move":
		if _units == null:
			return 0.0
		var payload: Dictionary = DictRead.as_dict(event["payload"])
		if payload.has("path"):
			# docs/42 section 3.2: the walk's mode is decided from what the
			# mover would see -- `aBuildVisibleMapForUnit` `0x004794B0` from the
			# destination and from the source -- and the camera follows from
			# the mode. **The answers ride on the event.** They are the writing
			# passes `core` ran at the moment of the move, when every unit of
			# that moment was still standing; the post-turn world this playback
			# runs on has lost the ones that died later in the turn.
			var from_x: int = DictRead.as_int(event["x"])
			var from_y: int = DictRead.as_int(event["y"])
			# **The path's own end, not the event's `tx`/`ty`.** They are
			# the same cell on every walk but one: a walk that ended on a
			# teleporter entry reports the **exit** it was relinked to
			# (docs/97 section 41.2), and the camera has to fly to where the
			# body is about to walk, not to where it will reappear.
			var path: PackedInt32Array = DictRead.to_int32(payload["path"])
			var last: int = path[path.size() - 1] if not path.is_empty() \
				else -1
			var to_x: int = last % world.resource.width if last >= 0 \
				else DictRead.as_int(event["tx"])
			var to_y: int = last / world.resource.width if last >= 0 \
				else DictRead.as_int(event["ty"])
			var mode: CameraDirector.WalkMode = CameraDirector.walk_mode(false,
				DictRead.as_bool(payload.get("seen_source", false)),
				DictRead.as_bool(payload.get("seen_destination", false)))
			var delay: float = _camera_before_walk(slot, from_x, from_y, to_x,
				to_y, mode)
			var walk: float = delay + _walk_body(slot,
				DictRead.to_int32(payload["path"]),
				DictRead.as_int(payload.get("steps", 0)), delay)
			# The mine an alien walked onto: the walk's own events carry the
			# blast, because the playback runs after the turn and the roster
			# has already lost whatever it killed.
			var moves: Array[Dictionary] = []
			for entry: Variant in DictRead.as_array(
					payload.get("events", [])):
				moves.append(DictRead.as_dict(entry))
			# The epilogue waits for the walk here too -- the computer's
			# aliens are the fill's only movers into a mine cell and the
			# teleporter entries are open to both sides.
			if _walk_has_epilogue(moves):
				var _held_queue: bool = _hold_for_walk(walk)
			var blast: float = _present_mine(slot, moves)
			# The same walk can end on a teleporter: `0x0046EE03` is inside
			# `aExecuteMove`, so the stream plays as part of the move
			# (docs/97 section 41.2).
			_present_teleport(slot, moves)
			return walk + blast
	elif kind == "warp":
		# docs/42 section 7.1: the computer's jump, with a scream for the
		# trail. The event's cells are the routine's own arguments.
		var frames: int = _present_jump(slot,
			Vector2i(DictRead.as_int(event["x"]), DictRead.as_int(event["y"])),
			Vector2i(DictRead.as_int(event["tx"]), DictRead.as_int(event["ty"])),
			false)
		# `AIPlan.execute_warp` puts the landing's blast in the payload; the
		# player watching the replay should see the explosion the alien
		# jumped onto.
		var landed: Dictionary = DictRead.as_dict(event["payload"])
		var blasted: float = _present_blast(slot,
			DictRead.as_int(event["tx"]), DictRead.as_int(event["ty"]),
			DictRead.as_dict(landed.get("blast", {})))
		return maxf(float(frames) / SequenceQueue.FRAMES_PER_SECOND, blasted)
	elif kind == "fire":
		# **The weapon comes from the event, not from the world.** The
		# playback runs after the turn, so an alien killed by reaction fire
		# after its own shot has no view left and the shot was presented as
		# nothing at all. `AIFire` writes the weapon into the note as it was
		# when the trigger was pulled, which is both accurate and always
		# there.
		return _present_attack(slot, DictRead.as_int(event["x"]),
			DictRead.as_int(event["y"]), DictRead.as_int(event["tx"]),
			DictRead.as_int(event["ty"]),
			DictRead.as_string(event["note"]).to_int(),
			AttackResult.from_dict(DictRead.as_dict(event["payload"])))
	elif kind == "parabomb":
		# `aAI_SpecialPlayerControl` `0x0040B2D0` is the fuse and nothing
		# else: it calls `aExecuteBomb` `0x004702C0` and `aRemoveUnitElement`
		# `0x004779C0`, and no sound routine at all. So the computer's para
		# bomb is **one blast on its own cell**, shown by the presenter the
		# walk's mine and the jump's landing already use, with
		# `Combat.BOMB_WEAPON`'s own cues. The payload *is* the blast --
		# `AISpecialPlayer` writes `AttackResult.to_dict()` straight into it.
		#
		# **And this is what takes its dead off the screen.** The casualties
		# are held from the start of the replay ([method
		# AIPlayback.pending_casualties]); the death stage of a shot is the
		# only thing that calls [method UnitsView.hide_now], so an event that
		# showed nothing left them standing to the end of the turn.
		return _present_blast(slot, DictRead.as_int(event["x"]),
			DictRead.as_int(event["y"]), DictRead.as_dict(event["payload"]))
	elif kind == "reactions":
		# The event's own cell is the **mover's**: `AIFire` and `AIPlan` emit
		# this for the unit that drew the fire, and the reactors are in the
		# payload. There is nothing to wait for the mover to do, so it is
		# shown at once and its longest clip is what the playback holds on.
		var drained: Dictionary = DictRead.as_dict(event["payload"])
		return _present_reactions(
			DictRead.as_array(drained.get("reactions", [])), slot,
			DictRead.as_int(event["x"]), DictRead.as_int(event["y"]))
	return 0.0


## Walk a body along the cells a move actually entered.
##
## The duration is [constant WALK_SECONDS_PER_STEP] a step, so a long walk
## takes longer than a short one. It is presentation: the world has already
## moved the unit, and a walk that were interrupted would leave nothing behind.
##
## Returns that duration, so the computer's playback can wait for it.
func _walk_body(slot: int, route: PackedInt32Array, steps: int,
		delay: float = 0.0) -> float:
	if _units == null or steps <= 0 or route.size() < 2:
		return 0.0
	var seconds: float = float(steps) * WALK_SECONDS_PER_STEP
	# docs/28 section 5. The wave and the volume id are the unit type's; the
	# *period* is a global the call writes, so asking for it here -- once, at
	# the start of the walk, in the order the walks happen -- is what makes the
	# Squeether's missing period behave the way the original's does.
	_units.start_walk(slot, route, world.resource.width, seconds,
		_footstep_period(slot), delay)
	return seconds


## The camera before a walk (docs/42 section 3.2), and the mode remembered
## for the frames that follow. Returns how long the walk has to wait for the
## flight. A ride hides the walker for the duration, as the engine does.
func _camera_before_walk(slot: int, from_x: int, from_y: int, to_x: int,
		to_y: int, mode: CameraDirector.WalkMode) -> float:
	if _director == null or _units == null:
		return 0.0
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return 0.0
	var delay: float = _director.before_walk(world, view, from_x, from_y, to_x,
		to_y, mode)
	if mode == CameraDirector.WalkMode.NONE:
		return delay
	_walk_cameras[slot] = mode
	if _director.rides(mode):
		_units.suppress(slot)
	return delay


## Every frame of every walk the camera is following: the target on the
## walker's head, or the ride from it. A walk that has ended releases its
## entry and, if it was ridden, shows the body again.
func _follow_walks() -> void:
	if _units == null or _director == null or _walk_cameras.is_empty():
		return
	var walking: PackedInt32Array = _units.walking_slots()
	for slot: int in _walk_cameras.keys():
		var mode: CameraDirector.WalkMode = _walk_cameras[slot]
		if not walking.has(slot):
			_walk_cameras.erase(slot)
			if _director.rides(mode):
				_units.reveal(slot)
			continue
		var view: Dictionary = world.unit_view(slot)
		var height: int = 0
		if not view.is_empty():
			height = world.unit_types().body_height_world(
				DictRead.as_int(view["type_id"]))
		var destination: int = _units.walk_destination(slot)
		var there: Vector3i = Vector3i.ZERO
		if destination >= 0:
			there = CameraRig.cell_object(destination % world.resource.width,
				destination / world.resource.width,
				world.state.height_at(destination))
		_director.track(_units.drawn_position(slot), height, mode, there)


## The step period for a walk about to start, and the cue cached beside it.
##
## Zero for the 39 silent unit types, and zero for a Squeether that walks
## before anything else has: the period is one global and it starts at zero.
func _footstep_period(slot: int) -> int:
	if _events == null or world == null:
		return 0
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return 0
	var cue: Dictionary = _events.footstep(DictRead.as_int(view["type_id"]))
	if cue.is_empty():
		return 0
	_footstep_cues[slot] = cue
	return DictRead.as_int(cue["period"])


## Play a wave for every foot that came down this frame.
##
## [method UnitsView.steps_taken] counts frames and knows nothing about sound;
## this turns each slot into the cue its type set up when the walk began. The
## cue is the one taken at `start_walk`, not a fresh lookup: the period global
## may have moved on since, and a walk sounds like what it started as.
func _play_footsteps() -> void:
	if _audio == null:
		return
	for slot: int in _units.steps_taken():
		if _footstep_cues.has(slot):
			var _played: int = _audio.play_cue(_footstep_cues[slot])


## The unit views, and through them this mission's bodies and their library.
func units_view() -> UnitsView:
	return _units


## The class name of the screen that is up, or `""`. What a driver reports, so
## that "which plate am I looking at" is answerable from the reply rather than
## only from the screenshot.
func screen_shown() -> CampaignScreen:
	return _screen


func screen_up() -> String:
	if _screen == null:
		return ""
	# Read back with an **assignment**, which is checked at run time; `as` is
	# `UNSAFE_CAST` and warnings are errors project-wide.
	var attached: Variant = _screen.get_script()
	if not (attached is GDScript):
		return ""
	var script: GDScript = attached
	return String(script.get_global_name())


func scenery_count() -> int:
	return 0 if _scenery == null else _scenery.built_count()


## The developer line: the cache, the scene and the hash. **Not** user-facing
## text, which is why it is not in [Localization] -- it names a mission file, a
## world set and a digest, and translating any of those would be wrong.
func _refresh_status(extra: String = "") -> void:
	if world == null:
		# No mission, so there is no line to build -- but a message still has
		# somewhere to go, which is what the shell needs when a slot refuses
		# before any world exists.
		if extra != "":
			_status.text = extra
		return
	var line: String = "%s (%d/%d)  %dx%d  %s/%s  %d units  scenery %d  hash %s" % [
		world.resource.mission, _missions.find(_mission) + 1, _missions.size(),
		world.resource.width, world.resource.height,
		world.resource.world_set, world.resource.world_scene,
		world.unit_slots().size(), _scenery.built_count(),
		world.canonical_hash_hex().substr(0, 12)]
	# **The mission names are not listed.** A cache published with
	# `--campaign-maps` carries 92 of them, and naming every one turned the
	# developer line into a wall of text across the playing screen. The
	# position in the set is already on the line above -- `(1/92)` -- and
	# which mission is next is what the keys are for.
	line += "\nQ/E rotate, wheel or pinch or +/- zooms, Y the field-type " \
		+ "overlay, G the editor's cell markers, [ and ] switch mission"
	if extra != "":
		line += "\n" + extra
	_status.text = line
	if _hud != null:
		var axes: Array[Vector2] = _radar_axes()
		_hud.refresh(world, _selected, Callable(self, "_event_available"),
			Callable(self, "_command_available"), axes[0], axes[1], _bands,
			false)
		# **Inside the window, under the top band.** The developer line is a
		# tool and not part of the plate, so it goes where the plate is not.
		_status.position = Vector2(float(HudTables.WINDOW.position.x) + STATUS_GAP,
			_hud.bottom() + STATUS_GAP)


## How far one trackpad pan event moves the zoom.  Pan deltas arrive in "lines"
## and a flick sends many, so this is deliberately small.
const PAN_ZOOM: float = 0.25
## Pinch: `factor` above 1 is a spread, which zooms in.
const MAGNIFY_ZOOM: float = 6.0


## How much one input moves the zoom, or zero when it is not a zoom input.
##
## Pure and static so it can be tested without a scene tree, which is the whole
## reason it is separate: the wheel worked and the trackpad did not, and the
## difference is which event class the platform sends.
static func zoom_delta_for(event: InputEvent) -> float:
	if event is InputEventMouseButton:
		var click: InputEventMouseButton = event
		if not click.pressed:
			return 0.0
		if click.button_index == MOUSE_BUTTON_WHEEL_UP:
			return -1.0
		if click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return 1.0
		return 0.0
	if event is InputEventPanGesture:
		# A wheel mouse sends WHEEL_UP/WHEEL_DOWN; a macOS trackpad and a Magic
		# Mouse send this instead, and handling only the former makes the zoom
		# look dead on exactly the hardware this was developed on.
		#
		# The sign is **measured, not derived**.  A first version reasoned from
		# the macOS backend's scroll handling that a negative `delta.y` matched
		# a wheel-up; on the hardware it is the other way round, so a
		# two-finger push away from the body zooms in.
		var pan: InputEventPanGesture = event
		return -pan.delta.y * PAN_ZOOM
	if event is InputEventMagnifyGesture:
		# `factor` above 1 is a spread, which zooms in.
		var pinch: InputEventMagnifyGesture = event
		return (1.0 - pinch.factor) * MAGNIFY_ZOOM
	if event is InputEventKey:
		var key: InputEventKey = event
		if not key.pressed:
			return 0.0
		if key.keycode == KEY_MINUS or key.keycode == KEY_KP_SUBTRACT:
			return 1.0
		if key.keycode == KEY_EQUAL or key.keycode == KEY_PLUS \
				or key.keycode == KEY_KP_ADD:
			return -1.0
	return 0.0


func _process(delta: float) -> void:
	# The location map is a picture with a clock of its own: no simulation
	# behind it, and nothing below this line applies to it.
	_tick_backdrop_fires(delta)
	_tick_backdrop_swing()
	if _playback.is_running():
		var _going: bool = _playback.advance(delta, _picture_busy())
	if _units != null:
		_units.animate(delta, world, _rig != null
			and _rig.eye().z >= UnitsView.FREEZE_HEIGHT)
		_play_footsteps()
		var _waiting: int = _drain_pending_reactions()
	# The camera after the bodies: tracking reads where a walker is drawn
	# this frame, and the flight steps at the same 20 fps the bodies use.
	_follow_walks()
	if _rig != null:
		var _flying: bool = _rig.advance(delta)
	_tick_interface(delta)
	# The pool first: a sequence that reads what a tick left -- the bomb run
	# and its *arrived* flag -- must see this frame's tick and not the last
	# one ([method _tick_effects]).
	var _ticks: int = _tick_effects(delta)
	if _sequences != null and _sequences.is_running():
		# The picture is held, never the world: `core` returned the finished
		# state before any of this was queued.
		var still: bool = _sequences.advance(delta)
		if not still:
			_redraw_terrain_now()
			# Whoever the queue was delivering has arrived.
			if _units != null:
				var _shown: int = _units.reveal_all()
				var _dropped: int = _units.drop_lifts()
	_draw_effects()
	_check_mission_end()


## The mission that ended reaches its own debriefing, by itself.
##
## The campaign loop docs/27 closes was open at exactly this step: the
## `"debriefing"` action had two senders, a button on a screen that is never
## up during a mission and `tour.gd`, so a mission won in the game simply
## stopped on a dead map.
##
## `screen == SCREEN_MISSION` is the once-guard -- [method
## CampaignHost.finish_mission] moves it on -- and it is also what keeps
## *Instant Action* out: a mission entered past the campaign has no state, no
## scoreboard to write and no next mission to go to, so it correctly gets
## nothing.
func _check_mission_end() -> void:
	if campaign == null or campaign.state == null or _screen != null:
		return
	if campaign.screen != CampaignHost.SCREEN_MISSION:
		return
	if world == null or not _mission_over():
		return
	# The picture goes first. The shot that ended the mission is still being
	# drawn, and a plate dropped over it would cut it off mid-explosion.
	if _picture_busy() or _playback.is_running():
		return
	_on_campaign_choice("debriefing")


## Whether something the replay must wait for is still on screen: a shot
## or a set piece on the queue, a walk, a body's clip, a flight.
func _picture_busy() -> bool:
	if _sequences != null and _sequences.is_running():
		return true
	if _units != null and (_units.is_walking() or _units.any_busy()):
		return true
	if _rig != null and _rig.is_flying():
		return true
	return false


## The blob pool at the engine's own frame. Answers the ticks it ran.
##
## The pool is ticked a **whole** number of times per displayed frame and the
## remainder is carried, so a slow frame runs the arms twice rather than
## stretching them: the arms count in ticks, not in seconds, and half a tick is
## not a thing any of them can do.
##
## **Before the sequences, not after.** Every `aPlay*Sequence` in the original
## is a loop whose body does its work, calls the frame tick `0x0040B6F0` and
## then reads what the tick left -- the bomb run `0x004160F0` asks
## `0x0042B480` on the instruction after its tick. A queue advanced before the
## pool would read the previous frame's answer, so a crump would land a frame
## after its bomb; drawing after both is what puts a record spawned by this
## frame's sequence on the screen in this frame rather than the next.
func _tick_effects(delta: float) -> int:
	if _fx == null:
		return 0
	_fx_carry += delta * CharismaState.FRAMES_PER_SECOND
	var ticks: int = int(_fx_carry)
	_fx_carry -= float(ticks)
	# A frame that lost a second to a rebuild should not run three hundred
	# particle ticks to catch up; the effect is cosmetic and the cap is the
	# same shape as the walk's own.
	ticks = mini(ticks, MAX_EFFECT_TICKS)
	for _step: int in range(ticks):
		# **The emitters first**, as `aCheckInBlobObjects` `0x0041E3D0` does:
		# its twenty-slot loop runs before the record sweep, so a flame lit
		# this frame is ticked this frame.
		if _bgb != null:
			var _lit: int = _bgb.tick(_fx, _fx_hooks)
		var _results: Array[BlobKinds.TickResult] = _fx.tick_all()
	# The environment turns on the same 20 fps clock the effects do, and for
	# the same number of ticks: `aRefreshView` walks the object array once a
	# displayed frame (docs/42 sections 1.3 and 9.1).
	if _special != null:
		for _step: int in range(ticks):
			var _turned: int = _special.advance()
	return ticks


## The sprite cloud and the model half of the pool, from wherever the records
## are **now** -- which is after this frame's tick and after anything this
## frame's sequences spawned.
func _draw_effects() -> void:
	if _fx == null:
		return
	if _sprites != null and _rig != null and _rig.camera() != null:
		var _drawn: int = _sprites.rebuild(_fx.blobs(),
			_rig.camera().global_transform.basis)
	if _models != null:
		var _shown: int = _models.rebuild(_fx)


## One event of the computer's turn: lead the camera to it and say what it was.
##
## An empty dictionary means the playback is over. Nothing here touches the
## world: it has held the post-turn state since [method World.submit_end_turn]
## returned, which is what makes skipping free.
##
## Returns how long this event should stay on screen; see
## [method AIPlayback._step].
func _on_ai_step(event: Dictionary) -> float:
	if event.is_empty():
		_ai_note = ""
		# The turn is the player's again. **The engine moves no camera here**
		# (docs/42 section 2.6), so neither does this unless the compatibility
		# flag asks for the remake's own return -- see [method
		# focus_on_friendly] for what that was for.
		if world != null and world.compat_flags.has(COMPAT_CAMERA_RETURNS):
			var _back: int = focus_on_friendly(_rig, world)
		# The replay is over, so nobody is held at an old cell any more. It is
		# cleared **before** the rebuild `_after_command` does, which is what
		# puts everyone back; a skipped replay comes through here too.
		if _units != null:
			_units.hold_at({} as Dictionary[int, Vector2i])
		_begin_command()
		_after_command("")
		return 0.0
	var kind: String = DictRead.as_string(event["kind"])
	var to_x: int = DictRead.as_int(event["tx"])
	var to_y: int = DictRead.as_int(event["ty"])
	var at_x: int = DictRead.as_int(event["x"])
	var at_y: int = DictRead.as_int(event["y"])
	if kind == "move" or kind == "warp":
		at_x = to_x
		at_y = to_y
	# **No camera per event here.** The pivot used to be put on every
	# event's cell, which flew the player to hidden aliens the fog was
	# keeping from them; the camera now belongs to the presentation of each
	# event (docs/42 sections 3.2 and 4.3), which knows what may be seen --
	# the jump's included, since docs/97 section 31 ([JumpSequence]).
	_ai_note = "%s -- %s %d  (%s)" % [_strings.text("hud.ai_turn"),
		_strings.text("ai." + kind) if _strings.has("ai." + kind) else kind,
		DictRead.as_int(event["slot"]), _strings.text("hud.ai_skip")]
	# **Before the rebuild**, for the same reason the player's shot does it:
	# this event's own casualties must still be on screen while the event is
	# presented, and the rebuild below is what takes them away.
	var payload: Dictionary = DictRead.as_dict(event["payload"])
	# **Every shape at once**, through the one extractor the whole replay was
	# marked with in [method end_turn]: this is the re-mark that survives a
	# rebuild, and a payload kind it did not know about was a body that never
	# came back. The `parabomb` was exactly that -- its payload *is* the
	# blast, and the branch that used to stand here had no arm for it.
	var _held: int = _mark_dying_payload(payload)
	# Where every unit whose move is still to come is standing. The world has
	# held the end of the turn since `submit_end_turn` returned, so without
	# this a unit stood at its destination until its own event came round and
	# only then walked there.
	_units.hold_at(_playback.pending_starts())
	_units.build(world, _geometry, _textures)
	# **After** the rebuild, not before. `UnitsView.build` frees every unit
	# node and clears the bodies, the states and the walks, so an event handed
	# to the bodies first started a walk on nodes that were freed microseconds
	# later: the computer's units teleported and `F` never played. The *next*
	# event's rebuild ending this one is the design; this event's rebuild
	# ending it is the bug.
	# docs/42 section 10: the terrain a computer event changed is redrawn
	# **in that event's frame**, not with the rest at the end of the replay.
	# `core` applied it when the event happened and the cells ride on the
	# event (docs/97 section 35); a door the computer walked through used to
	# open only once the whole turn had been shown.
	#
	# **A set piece owns the cells it animates**, which is the guard
	# [method _redraw_terrain] makes for the same reason: painting the door
	# to its final height here and then queueing its ten frames would snap
	# it open, snap it shut and animate it open again.
	# The computer's event names the door `"door"`; the set piece it queues
	# is `"open_door"`, so the test is on what [method _present_ai_event]
	# will actually animate.
	var as_setpiece: String = AI_SETPIECE_KINDS.get(kind, kind)
	if not SetpieceDriver.is_animated(as_setpiece):
		var _cells: int = _redraw_event_cells(payload)
	var hold: float = _play_event_body(event, kind)
	_present_ai_event(event, kind)
	_refresh_status(_ai_note)
	return hold


## The computer's door and para bomb, heard.
##
## **The shot is not here.** It was a partial copy of the player's own
## presentation -- no pain scream, and the weapon read out of the post-turn
## world -- and it returned nothing, so the playback could not wait for it.
## [method _play_event_body] owns every attack now; what is left here is the
## sound-only half of the replay.
##
## The player watching a replay should hear what they would have heard live;
## an effect that only fired on the player's own turn would be worse than
## none at all.
func _present_ai_event(event: Dictionary, kind: String) -> void:
	if _audio == null or _events == null:
		return
	match kind:
		"door":
			# The AI's opener passes real tiles too (docs/42 section 8): the
			# flight from its head to the panel, when the picture can queue.
			if _sequences != null and world != null:
				_queue_setpiece({"name": "open_door",
					"values": [DictRead.as_int(event["tx"]), DictRead.as_int(event["ty"])]},
					SetpieceDriver.DOOR_FRAMES, _events.for_event_kind("open_door"),
					DictRead.as_int(event["slot"]))
			else:
				var _door: PackedInt32Array = _audio.play_cues(
					_events.for_event_kind("open_door"), "ai")
		# **No `parabomb` arm.** It played the fly-past loop and one crump
		# together, on the reading that the computer's fuse ran the script
		# command's two routines ([constant AudioEvents.EVENT_PHASES]).
		# It does not: `0x0040B2D0` calls `aExecuteBomb` and
		# `aRemoveUnitElement` and nothing else, and the fly-past belongs to
		# `ParaBombs` `0x00470790`, which only a script fires. The blast --
		# sound, picture and death stage -- is [method _play_event_body]'s.
		"fire_heat_blocked":
			var _jam: PackedInt32Array = _audio.play_cues(
				_events.for_event_kind("reaction_jam"), "ai")


func _unhandled_input(event: InputEvent) -> void:
	# `ESC` goes **before** the screen guard, and that ordering is the whole
	# of the fix: the guard below returns before anything else runs, so with a
	# plate up no key reached the game at all and the shell would have been a
	# room with no door. Only `ESC` is let past; everything else still belongs
	# to whatever is on screen.
	if event is InputEventKey and event.is_pressed():
		var pressed: InputEventKey = event
		if pressed.keycode == KEY_ESCAPE:
			_toggle_shell()
			return
	# A campaign screen owns the rest of the input while it is up: without
	# this the mouse reached the 3D pick behind the plate and selected units
	# through it. A screen drawn **around a window** wants exactly that pick
	# back, for the part of the picture its own frame does not cover.
	if _screen != null:
		_screen_input(event)
		return
	if world == null:
		return
	# The computer's turn holds the input while it is being shown. One key
	# ends the showing; the world does not change either way.
	if _playback.is_running():
		if event is InputEventKey and event.is_pressed():
			if _sequences != null:
				_sequences.skip()
			if _texts != null:
				_texts.clear()
			if _units != null:
				var _shown: int = _units.reveal_all()
				var _dropped: int = _units.drop_lifts()
			# The bodies are snapped first: `skip()` means "stop drawing the
			# turn", and a body half way between two cells is not the state
			# the last frame would have shown.
			if _units != null:
				_units.finish_walks(world)
			# The flight is blocking in the original, so a skip lands where
			# it would have stopped.
			if _rig != null:
				_rig.settle()
			_walk_cameras.clear()
			_playback.skip()
		return
	var zoom: float = zoom_delta_for(event)
	if not is_zero_approx(zoom):
		_rig.zoom_by(zoom)
		return
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		if key.keycode == KEY_F5:
			quick_save()
		elif key.keycode == KEY_F9:
			quick_load()
		elif key.keycode == KEY_TAB:
			var _cycled: int = cycle_friendly()
		elif key.keycode == KEY_Q:
			_rig.rotate_step(-1)
		elif key.keycode == KEY_E:
			_rig.rotate_step(1)
		elif key.keycode == KEY_1:
			_set_view(CameraRig.View.EYES)
		elif key.keycode == KEY_2:
			_set_view(CameraRig.View.UNIT)
		elif key.keycode == KEY_3:
			_set_view(CameraRig.View.MAP)
		elif key.keycode == KEY_Y:
			_overlay.toggle()
		elif key.keycode == KEY_G:
			_scenery.toggle_lattice()
		# The interface's own keys (docs/43 section 5): the pad's six and the
		# columns' events, as `aMI.cpp` and `aUI.cpp` bind them.
		elif key.keycode == KEY_R:
			_on_pad_command(HudTables.COMMAND_REST)
		elif key.keycode == KEY_S:
			_on_pad_command(HudTables.COMMAND_STIMULANT)
		elif key.keycode == KEY_W:
			_on_pad_command(HudTables.COMMAND_WEAPON_MODE)
		elif key.keycode == KEY_B:
			_on_hud_event(HudTables.EVENT_BRIEFING)
		elif key.keycode == KEY_T:
			_on_hud_event(HudTables.EVENT_VISIBLE_ENEMY)
		elif key.keycode == KEY_BACKSPACE:
			_on_hud_event(HudTables.EVENT_UNDO_TURN)
		elif key.keycode == KEY_F1:
			_on_hud_event(HudTables.EVENT_REMIND_POSITION)
		elif key.keycode == KEY_F2:
			_on_hud_event(HudTables.EVENT_RECALL_POSITION)
		elif key.keycode == KEY_F3:
			_on_hud_event(HudTables.EVENT_SAVE)
		elif key.keycode == KEY_F4:
			_on_hud_event(HudTables.EVENT_LOAD)
		elif key.keycode == KEY_4:
			_on_hud_event(HudTables.EVENT_FREE_CAMERA)
		elif key.keycode == KEY_LEFT:
			_rig.rotate_step(-1)
		elif key.keycode == KEY_RIGHT:
			_rig.rotate_step(1)
		elif key.keycode == KEY_BRACKETRIGHT:
			show_mission(1)
		elif key.keycode == KEY_BRACKETLEFT:
			show_mission(-1)
		elif key.keycode == KEY_SPACE:
			if _may_command_now():
				end_turn()
		elif key.keycode == KEY_U:
			_on_pad_command(HudTables.COMMAND_USE)
		elif key.keycode == KEY_D:
			_on_pad_command(HudTables.COMMAND_DEFEND)
		elif key.keycode == KEY_H:
			_on_pad_command(HudTables.COMMAND_HEAL)
	elif event is InputEventMouseButton and event.is_pressed():
		var click: InputEventMouseButton = event
		if click.button_index == MOUSE_BUTTON_LEFT and _may_command_now():
			_pick(click.position, click.shift_pressed)
	elif event is InputEventMouseButton:
		# The right button, released: the camera turns a step, left of the
		# window's middle one way and right of it the other (`0x0041BA30`).
		var release: InputEventMouseButton = event
		if release.button_index == MOUSE_BUTTON_RIGHT and _rig != null:
			var middle: float = get_viewport().get_visible_rect().size.x * 0.5
			_rig.rotate_step(-1 if release.position.x < middle else 1)
	elif event is InputEventMouseMotion:
		# docs/42 section 2.5: the middle button held drags the view.
		var motion: InputEventMouseMotion = event
		if motion.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_rig.pan(motion.relative, get_viewport().get_visible_rect().size.x)
		else:
			# The hover cell, read off the event as well as polled: a driver's
			# synthetic motion reaches here before the viewport's own pointer
			# moves (docs/43 section 3).
			_update_hover(motion.position)


## `ESC` -- open the shell over a running mission, and close it again.
##
## Three cases and only three. The shell is up, so it goes down and whatever
## was behind it comes back. A mission is up with nothing over it, so the
## shell opens paused. A **campaign** screen is up -- the map, a briefing, the
## roster -- and `ESC` does nothing, because the shell shares [member _screen]
## with those and would take one down with no way back to it.
func _toggle_shell() -> void:
	if shell.is_up():
		# **Only when there is something behind it.** At the boot menu there
		# is not: closing it left the window blank with nothing to draw, and
		# `ESC` was then dead too -- no shell up, no plate, no mission -- so
		# the game could only be quit from the window's own close button.
		# [member ShellHost.behind] is the question, and [method
		# ShellHost.back_from] was already asking it.
		if shell.behind:
			close_shell()
		return
	if _screen != null:
		return
	if not in_mission():
		return
	var _up: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)


## A click, a hover or a camera command inside a screen's own window.
##
## The bounds test is done as a **fraction of the viewport** rather than in
## pixels: the plate is stretched to the whole of it, so a plate coordinate is
## a fraction and nothing here has to know which space the event arrived in.
##
## The camera half is deliberately a short, named list rather than a fall
## through to `_unhandled_input`'s own: a screen is up, and everything it does
## not name still belongs to the screen.
## One call of `0x004558F0` with the pointer's own travel -- docs/27 §2.6.
##
## The original reads the travel every frame with the cursor pinned to where
## the drag began, so what reaches the routine is a per-frame delta; Godot's
## `relative` already is one, and the warp is what Godot's captured mouse
## would be. What is not offered here is the capture itself: the map is a
## screen with buttons on it, and stealing the pointer to turn a picture would
## take the buttons away with it.
func _swing_backdrop(travel: Vector2) -> void:
	if _backdrop_rig == null:
		return
	# **Accumulated, not applied.** The routine runs once a frame in the
	# original -- the cursor warp is what makes each frame's reading fresh --
	# so several motion events inside one Godot frame are one request between
	# them, and applying each on arrival would both double the rise and feed
	# the decay a second request of its own size.
	_swing_carry += travel


## The decay half. `0x004558F0` is called **every frame** with a zero request,
## which is what halves the step and brings the map to rest; a frame that only
## ran while the pointer moved would stop it dead instead.
func _tick_backdrop_swing() -> void:
	if _backdrop_rig == null or _screen == null:
		return
	if _swing_carry == Vector2.ZERO and _backdrop_rig.map_step() == 0:
		return
	_apply_swing()
	_swing_carry = Vector2.ZERO


func _apply_swing() -> void:
	var eye: Vector3i = _backdrop_rig.swing_map(
		int(_swing_carry.x) * CameraRig.MAP_TURN_PER_PIXEL,
		int(_swing_carry.y) * CameraRig.MAP_RISE_PER_PIXEL)
	_backdrop_rig.set_now(eye, CameraRig.CAMPAIGN_TARGET)


func _screen_input(event: InputEvent) -> void:
	if _screen == null or not _screen.takes_world_clicks():
		return
	var on_backdrop: bool = _backdrop_root != null
	var showing: World = _backdrop_world if on_backdrop else world
	var rig: CameraRig = _backdrop_rig if on_backdrop else _rig
	if showing == null or rig == null:
		return
	var zoom: float = zoom_delta_for(event)
	if not is_zero_approx(zoom):
		rig.zoom_by(zoom)
		return
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		# **The map turns a different way from a mission.** A mission's `Q`
		# and `E` step the rig's quadrant; the map's eye is the fixed pair of
		# [constant CameraRig.CAMPAIGN_EYE] and `0x004558F0` swings it about
		# the target by an accumulated angle instead, which is a drag rather
		# than a step -- see [method _swing_backdrop].
		if on_backdrop and (key.keycode == KEY_Q or key.keycode == KEY_E):
			_swing_backdrop(Vector2(
				CameraRig.MAP_KEY_TURN if key.keycode == KEY_E
				else -CameraRig.MAP_KEY_TURN, 0.0))
		elif not on_backdrop and key.keycode == KEY_Q:
			rig.rotate_step(-1)
		elif not on_backdrop and key.keycode == KEY_E:
			rig.rotate_step(1)
		elif not on_backdrop and key.keycode == KEY_1:
			_set_deploy_view(CameraRig.View.EYES)
		elif not on_backdrop and key.keycode == KEY_2:
			_set_deploy_view(CameraRig.View.UNIT)
		elif not on_backdrop and key.keycode == KEY_3:
			_set_deploy_view(CameraRig.View.MAP)
		return
	var at: Vector2 = Vector2.ZERO
	var clicked: bool = false
	if event is InputEventMouseButton:
		var click: InputEventMouseButton = event
		if not click.pressed or click.button_index != MOUSE_BUTTON_LEFT:
			return
		at = click.position
		clicked = true
	elif event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		# docs/42 section 2.5: the middle button held drags the view, here as
		# in a mission.
		if motion.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			# On the map that same drag is the original's own: `0x0045558C`
			# reads the pointer's travel since the last frame, doubles it for
			# the turn and multiplies it by -50 for the height, and warps the
			# cursor back to where the drag started so the next frame's
			# reading is fresh again.
			if on_backdrop:
				_swing_backdrop(motion.relative)
				return
			rig.pan(motion.relative, get_viewport().get_visible_rect().size.x)
			return
		at = motion.position
	else:
		return
	var size: Vector2 = get_viewport().get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var window: Rect2 = _screen.plate_window()
	var fraction: Vector2 = at / size
	if not Rect2(window.position / CampaignScreen.PLATE_SIZE,
			window.size / CampaignScreen.PLATE_SIZE).has_point(fraction):
		# **The pointer leaving the picture is an answer too.** A name and a
		# ring left standing on the last cell the pointer crossed read as a
		# selection that was never made.
		if not clicked:
			_screen.world_hover(Vector2i(-1, -1))
			if _markers != null:
				_markers.clear_ring()
		return
	# **The dots are aimed at first.** They are overlay sprites, so what the
	# pointer is on is a sprite and not a patch of ground; the ray pick is
	# what answers for the ground the dots do not cover. On the campaign map
	# the ray meets its height plane at about six degrees and a dot was
	# unclickable without it (see [method MapMarkers.cell_at]).
	var cell: Vector2i = Vector2i(-1, -1)
	if _markers != null:
		cell = _markers.cell_at(rig.camera(), at)
	if cell.x < 0:
		cell = cell_under(rig.camera(), showing, at, 1.0)
	if clicked:
		_screen.world_click(cell)
	elif _markers != null:
		_screen.world_hover(cell)
		_markers.ring(_art, cell)


## docs/42 section 2.4's three views on the deployment screen.
##
## [method _set_view] cannot be used: it frames a **unit**, and the whole of
## what this screen is for is that the player has none on the map yet. The
## deployment area is the subject instead, and the map view is what the
## screen opens in -- the original deploys from above.
func _set_deploy_view(mode: CameraRig.View) -> void:
	if _rig == null or world == null or _director == null:
		return
	var at: Vector2i = _deployment_centre()
	if at.x < 0:
		return
	if mode == CameraRig.View.MAP:
		var _flight: float = _director.view_map(world, at.x, at.y)
		_rig.settle()
		return
	# A soldier already on the map is the better subject, and the engine's own
	# "on the unit" placement takes one. Before the first is placed there is
	# nothing to frame but the landing area, so the same placement is made
	# over the cell instead of over a body.
	var slot: int = next_friendly_slot(world, -1)
	if slot >= 0:
		var _flown: float = _director.view_unit(world, slot)
		_rig.settle()
		return
	var view: Dictionary = world.cell_view(at.x, at.y)
	var centre: Vector3i = CameraRig.cell_object(at.x, at.y,
		DictRead.as_int(view["height"]))
	var goal: Dictionary = _rig.place_on_unit(centre, 0, Vector2i(0, 1),
		8, 7, 0)
	_rig.set_view_mode(mode)
	_rig.set_now(DictRead.as_vector3i(goal["eye"]),
		DictRead.as_vector3i(goal["target"]))
	_rig.settle()


## docs/42 section 2.4's three views, on keys 1, 2 and 3 -- the remake's
## binding; docs/29 records the GUI events and no key. The eyes and unit
## views need a unit and take the selection, or the first own unit; the map
## view is over the same cell. The HUD stays: the engine's `0x0041A980(1)`
## then `(0)` around the eyes flight is a hide-and-redraw pulse, not a state.
func _set_view(mode: CameraRig.View) -> void:
	if _director == null or world == null:
		return
	var slot: int = _selected if _selected >= 0 and world.has_unit(_selected) \
		else next_friendly_slot(world, -1)
	if slot < 0:
		return
	var view: Dictionary = world.unit_view(slot)
	if view.is_empty():
		return
	var _flight: float = 0.0
	match mode:
		CameraRig.View.EYES:
			_flight = _director.view_eyes(world, slot)
		CameraRig.View.MAP:
			_flight = _director.view_map(world, DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"]))
		_:
			_flight = _director.view_unit(world, slot)
	_sync_hud()


## Whether the mission has ended -- in which case no command is taken any more.
##
## [method World.may_command] is the rule and refuses every slot once the
## game-control slots are set; this is the same rule read once, so that a click
## on a friendly unit does not fall through to the "not yours, so shoot it"
## branch and so that the three keyed commands stop with it. Rotating, zooming
## and the two overlays keep working: the map is still worth looking at.
func _mission_over() -> bool:
	return world != null and world.game_control.mission_ended()


## Whether a command may be given at all: the mission is running **and the
## turn is not the computer's**.
##
## The second half is this remake's stand-in for a thing the engine has and it
## does not. `0x0047D600` sets **view state 2** the moment the rotation reaches
## player 255 (docs/25 section 4), and `aNextPlayerHandling` only leaves the
## state that accepts input -- 0 -- when a human holds the turn. There is no
## view state here, so the same refusal is written out.
##
## It should now be unreachable through the normal rotation:
## [method World.submit_end_turn] turns until a human holds the turn, which is
## the engine's own `while (g_currentPlayer == 255 && result == 1)`. It stays
## because a **stopped** hand-over can still leave player 255 holding -- every
## player out, with no mission end behind it -- and what that used to allow was
## not a cosmetic slip: [method World.may_command] compares against whoever
## holds the turn, so the player could select the aliens and spend their turn
## for them.
func _may_command_now() -> bool:
	if world == null or _mission_over():
		return false
	return world.turn.current_player != TurnState.PLAYER_COMPUTER


## Turns a screen position into a map field, then asks the world about it.
## The scene tree is used to find *which* cell was clicked and for nothing else.
func _pick(screen: Vector2, pass_friendlies: bool) -> void:
	var camera: Camera3D = _rig.camera()
	# The ring takes every click while it is up (`0x00471AD0`): the nearest
	# of its nine records, the X cancelling.
	if _hud != null and _hud.ring.is_up():
		var record: int = _hud.ring.hit(camera, screen)
		if record == DirectionRing.CANCEL_RECORD or record < 0:
			_hud.ring.take_down()
			_refresh_status("")
		else:
			_complete_ring(record)
		return
	var ray: PackedVector3Array = CameraRig.ray_through(camera, screen,
		get_viewport().get_visible_rect().size)
	if ray.size() != 2:
		return
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	if absf(direction.y) < 0.0001:
		return
	var best_slot: int = -1
	var best_distance: float = INF
	for slot: int in world.unit_slots():
		var view: Dictionary = world.unit_view(slot)
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var cell: Dictionary = world.cell_view(x, y)
		var centre: Vector3 = WorldSpace.cell_centre(x, y,
			DictRead.as_int(cell["height"]))
		var t: float = (centre.y - origin.y) / direction.y
		if t <= 0.0:
			continue
		var hit: Vector3 = origin + direction * t
		var distance: float = hit.distance_to(centre)
		if distance < 1.2 and distance < best_distance:
			best_distance = distance
			best_slot = slot
	if best_slot >= 0:
		var view: Dictionary = world.unit_view(best_slot)
		# **Only the current player's own units can be selected.**
		# `0x00477DF0(player)` -- which `0x00453CF0`, the game's own "cycle
		# the selected friendly unit", walks -- accepts a slot on exactly
		# three tests: hit points non-zero, `+0x45` equal to
		# `aGetCurrentPlayer`, and `+0x4F` zero. Anything else is a target,
		# not a selection.
		#
		# Selection used to be unconditional, and the owner was consulted only
		# to decide "attack or select". That was invisible while the aliens
		# never acted; with docs/23's planner in place it meant a player could
		# click a purple pill and take the computer's turn for it.
		#
		# **"Cannot be commanded" is not the same as "is a target."**
		# [method World.may_command] also refuses a *friendly* record with no
		# hit points, and a dead squad member stays in `unit_slots()` and stays
		# on screen -- the fog pass leaves an own corpse fully visible. Routing
		# every refusal into the attack branch therefore let a player spend a
		# soldier's action points, and drain the reaction queue, shooting at
		# the body of the soldier who died during the alien turn. So the attack
		# branch asks the question it means: is this somebody else's live unit?
		if not world.may_command(best_slot):
			if _selected >= 0 and is_a_target(view, turn_player()):
				attack_cell(DictRead.as_int(view["x"]),
					DictRead.as_int(view["y"]))
			else:
				_refresh_status(_strings.text("hud.not_yours"))
			return
		# The selected unit clicked again raises the ring on its own cell:
		# mode 2, a turn in place (`0x004718B5`).
		if best_slot == _selected:
			_raise_ring(Vector2i(DictRead.as_int(view["x"]),
				DictRead.as_int(view["y"])), HudTables.RING_MODE_TURN)
			return
		# **A unit with no movement points cannot be selected**
		# (`0x00471CB6`): the click does nothing at all.
		if not world.may_select(best_slot):
			_refresh_status(_strings.text("hud.no_points"))
			return
		var _result: MoveMapResult = select_unit(best_slot, pass_friendlies)
		return

	# No unit under the ray: if a unit is selected and the cell is one the
	# query highlighted, walk there. `core` re-fills and re-walks; the overlay
	# is a picture and is never trusted as the answer.
	var cell: Vector2i = _cell_under(screen)
	if _selected < 0 or cell.x < 0:
		_deselect()
		_refresh_status(_strings.text("hud.no_selection"))
		return
	# A cell the query marked as a warp target is the Jet Pack's jump, not a
	# walk (docs/23 section 7.5), and a reachable one a walk; either raises
	# the ring first (`0x00471645`, `0x00471698`) and the command runs when
	# a letter is chosen. `core` re-fills before it agrees to any of it.
	if _last_query != null and _last_query.is_warp_target(cell.x, cell.y):
		_raise_ring(cell, HudTables.RING_MODE_WARP)
		return
	if _last_query != null and _last_query.is_reachable(cell.x, cell.y):
		_raise_ring(cell, HudTables.RING_MODE_MOVE)
		return
	# A band cell is a target: the enemy standing on it takes the shot.
	if _bands.has(cell):
		attack_cell(cell.x, cell.y)
		return
	_deselect()
	_refresh_status(_strings.text("hud.no_selection"))


## Raise the direction ring on *cell* for *mode* (docs/43 section 4).
func _raise_ring(cell: Vector2i, mode: int) -> void:
	if _hud == null or _selected < 0:
		return
	_hud.ring.place(_art, world, cell, mode)
	_refresh_status("")


## A ring letter was chosen: the command the ring was raised for, then the
## facing, then the reselect or the deselect (`0x00471AD0`).
func _complete_ring(record: int) -> void:
	var facing: int = DirectionRing.facing_of(record)
	var mode: int = _hud.ring.mode
	var cell: Vector2i = _hud.ring.cell
	var slot: int = _selected
	_hud.ring.take_down()
	if facing < 0 or slot < 0 or not world.has_unit(slot):
		return
	match mode:
		HudTables.RING_MODE_MOVE:
			var _moved: MoveResult = move_selected(cell.x, cell.y)
		HudTables.RING_MODE_WARP:
			var _jumped: WarpResult = warp_selected(cell.x, cell.y)
	if not world.has_unit(slot):
		return
	var _turned: bool = world.submit_rotate(RotateCommand.create(slot, facing))
	# The body turns when its walk is over, as the object does after the
	# original's blocking walk; a turn in place turns it now.
	if _units != null and _units.is_walking():
		_pending_turn = {"slot": slot, "facing": facing}
	elif _units != null:
		var _faced: bool = _units.turn_to(slot, HudTables.FACING_ANGLES[facing])
	# **No second `_after_command` here.** The move and the warp have run it
	# already, from inside `move_selected` and `warp_selected`, and it
	# rebuilds `UnitsView` -- which frees every body and clears the walk this
	# ring has just started, and overwrites the reaction count with nothing.
	# The turn that follows a move is free (`docs/43` section 4.3: no point
	# charged and no visibility rebuilt) and no band reads the shooter's
	# facing (`core/hit_chance.gd` never looks at one), so the only thing left
	# to do is to let the interface re-read the world.
	if mode == HudTables.RING_MODE_TURN and _selected == slot:
		_refresh_status("")


## Whether a picked unit is something to shoot at rather than something to
## select: alive, and not the current player's own.
##
## The owner test alone is what `game` used before docs/23's planner, and the
## liveness test is what the corpse case needs. A hidden unit never reaches
## here -- the picker only sees what is drawn.
##
## Static, and taking the player rather than reading it, so a suite can ask it
## the question directly: the rule is small enough that the only way to get it
## wrong is not to have checked it.
static func is_a_target(view: Dictionary, current_player: int) -> bool:
	if DictRead.as_int(view["hp"]) == 0:
		return false
	return DictRead.as_int(view["player"]) != current_player


## The player the world says is holding the turn, or -1 with no world.
func turn_player() -> int:
	return -1 if world == null else world.turn.current_player


## The map cell a screen ray lands on, or `(-1, -1)`.
##
## The plane is the *cell's own* height, so a ray is tested against every cell
## rather than against one flat plane -- the map is not flat, and a single-plane
## test picks the wrong cell on anything raised.
func _cell_under(screen: Vector2) -> Vector2i:
	return cell_under(_rig.camera(), world, screen)


## The same question asked of any camera over any world, which is what the
## campaign map needs: its picture is a world of its own and is drawn by a
## rig of its own.
## *tolerance* is how far from a cell's centre the ray may land, in Godot
## units, where a cell is two of them across. The mission view asks for a
## third of a cell, which is what a click on a *unit* wants; a campaign map
## asks for the whole cell, because there the cell **is** the target and the
## camera is the length of a city away from it.
static func cell_under(camera: Camera3D, at: World, screen: Vector2,
		tolerance: float = 0.7) -> Vector2i:
	if camera == null or at == null or not camera.is_inside_tree():
		return Vector2i(-1, -1)
	var ray: PackedVector3Array = CameraRig.ray_through(camera, screen,
		camera.get_viewport().get_visible_rect().size)
	if ray.size() != 2:
		return Vector2i(-1, -1)
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	if absf(direction.y) < 0.0001:
		return Vector2i(-1, -1)
	var best: Vector2i = Vector2i(-1, -1)
	var best_distance: float = INF
	# The height straight off the state rather than through `cell_view`: this
	# runs on every mouse motion over a campaign map, and building a
	# ten-field dictionary per cell to read one of them was the whole cost.
	var width: int = at.resource.width
	for y: int in range(at.resource.height):
		for x: int in range(width):
			var centre: Vector3 = WorldSpace.cell_centre(x, y,
				at.state.height_at(y * width + x))
			var t: float = (centre.y - origin.y) / direction.y
			if t <= 0.0:
				continue
			var distance: float = (origin + direction * t).distance_to(centre)
			if distance < tolerance and distance < best_distance:
				best_distance = distance
				best = Vector2i(x, y)
	return best


## Walks the selected unit. Public for the same reason [method select_unit] is:
## a demo run drives the path a click drives.
func move_selected(x: int, y: int) -> MoveResult:
	var slot: int = _selected
	_begin_command()
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, x, y))
	# **The player's own walk marks nothing.** `aWalkMoveMap` `0x004305E0` is
	# what writes state 100 along a path, and it is reached from one place:
	# `0x00472D40`, an arm of the command dispatcher `0x0047DE90` that only
	# `0x0047C2C0` -- the redraw callback `aAISystemControl` is handed
	# (docs/23 section 2) -- calls. So the marks are how the *computer's*
	# steps are shown, and the player walks unmarked (docs/43 section 3.1).
	# A move that drew return fire can lose the mover to it; the same order
	# applies, and the walk still plays because the body is still there.
	var _held: int = _mark_dying_by(moved.reactions)
	var _blasted: int = _mark_dying_by_mine(moved.events)
	_after_command(moved.reason if not moved.ok else "%d %s" % [
		moved.reactions.size(), _strings.text("hud.reactions")])
	# `MoveResult.route` is the walk's own -- source first, truncated where it
	# actually stopped rather than where it was planned to. It is not in
	# `to_dict()` and does not need to be: the player's move hands `game` the
	# object itself.
	# docs/42 section 3.2, mode 1: the target flies to the walker before the
	# first step and follows it after; the walk waits for the flight.
	var delay: float = 0.0
	if moved.ok and moved.steps > 0 and moved.route.size() >= 2:
		var width: int = world.resource.width
		delay = _camera_before_walk(slot, moved.route[0] % width,
			moved.route[0] / width, x, y, CameraDirector.WalkMode.OWN)
	var walked_for: float = _walk_body(slot, moved.route, moved.steps, delay)
	# The walk's epilogue waits for the walk, as the engine's blocking loop
	# makes it: `_hold_for_walk` is the stage that serialises the two clocks.
	if _walk_has_epilogue(moved.events):
		var _held_queue: bool = _hold_for_walk(delay + walked_for)
	# **The blast goes on the queue before the reactions**, because the engine
	# draws it before it has one: `aExecuteBomb` `0x004702C0` ends by calling
	# `aPlayFightAnimation` `0x0040BD70` itself (`0x004705F5`), and the walk
	# reaches `aExecuteBomb` from **inside** `aExecuteMove` (`0x0046EDAF`),
	# while `aExecuteFight` -- which is what drains the reactions -- is the
	# caller's and runs only after `aExecuteMove` has returned
	# (docs/23 section 5.3). So the explosion is over before the first
	# reaction shot is fired.
	var _blast: float = _present_mine(slot, moved.events)
	# `0x0046EE03` runs inside `aExecuteMove`, before the caller's
	# `aExecuteFight`, so the teleport is over before the first reaction shot
	# -- the same order the mine's blast keeps above.
	_present_teleport(slot, moved.events)
	# **After** the walk starts and after `_after_command`, which clears the
	# queue: `World.submit_move` resolves the whole move's reactions in one
	# call at its end, so the end of the walk is where the picture reaches
	# the state `core` already returned.
	_queue_reactions(moved.reactions, slot, x, y)
	return moved


## `aPlayTeleporterSequence` `0x004164F0` -- the stream, the traveller hidden
## at frame 40 of the countdown and shown again at 10 (docs/42 section 8.1).
##
## `core` has already relinked the unit (`ExecuteMove._teleport`, docs/97
## section 41.2), so this is only the picture: the sequence is queued on the
## **entry** cell with the exit as its target, which is what
## `0x0042A120(sx, sy, tx, ty)` is given, and the body is suppressed rather
## than freed because it comes back thirty frames later.
##
## The killing teleporter `0x00416840` is the `teleporter_blocked` arm: the
## traveller is already off the map, so there is nothing to hide and nothing
## to move, and only the stream is drawn.
func _present_teleport(slot: int, events: Array[Dictionary]) -> void:
	for entry: Dictionary in events:
		var kind: String = DictRead.as_string(entry.get("kind", ""))
		if kind != "teleported" and kind != "teleporter_blocked":
			continue
		var from: Vector2i = _teleport_entry(events)
		if from.x < 0:
			continue
		var to: Vector2i = Vector2i(DictRead.as_int(entry["x"]),
			DictRead.as_int(entry["y"])) if kind == "teleported" else from
		# `0x004164F0` opens `teleport.wav` and `teleport2.wav`; the killing
		# form `0x00416840` is the sound table's `warp` (docs/28's names come
		# from the routine that owns them, and that one is
		# `aPlayWarpSequence`).
		var cues: Array[Dictionary] = []
		if _events != null:
			cues = _events.for_event_kind(
				"teleporter" if kind == "teleported" else "warp")
		_queue_setpiece({"name": "teleporter",
			"values": [from.x, from.y, to.x, to.y]},
			SetpieceDriver.TELEPORTER_FRAMES, cues,
			slot if kind == "teleported" else MapState.NO_UNIT)


## The cell the walk stopped on, off the `teleporter` event the walk records.
static func _teleport_entry(events: Array[Dictionary]) -> Vector2i:
	for entry: Dictionary in events:
		if DictRead.as_string(entry.get("kind", "")) == "teleporter":
			return Vector2i(DictRead.as_int(entry["x"]),
				DictRead.as_int(entry["y"]))
	return Vector2i(-1, -1)



## The stage that puts the walk and the walk's own epilogue back in order.
##
## `aExecuteMove`'s step loop **blocks**: the mine's `aExecuteBomb`
## (`0x0046EDAF`) and the teleporter's `aExecuteTeleporter` (`0x0046EE03`) run
## after the last step has been drawn, not beside it. In the remake the body is
## walked by [UnitsView] on its own clock and the set pieces by
## [SequenceQueue], and the two clocks are independent by design (docs/92
## section 2) -- so without this the stream and the blast start while the body
## is still on its way to the cell they belong to.
##
## The bound is the walk's **own** length in frames and not a number of the
## remake's; [method UnitsView.is_walking] is what actually ends the stage, and
## it is true from [method UnitsView.start_walk] onwards, the camera flight's
## delay included. Returns whether a stage was queued.
func _hold_for_walk(seconds: float) -> bool:
	if _sequences == null or _units == null or not _units.is_walking():
		return false
	var frames: int = ceili(seconds * SequenceQueue.FRAMES_PER_SECOND)
	if frames <= 0:
		return false
	_sequences.enqueue_until(STAGE_AFTER_WALK, frames,
		func() -> bool: return not _units.is_walking())
	return true


## Whether a walk's own events carry anything [method _present_mine] or
## [method _present_teleport] will put on the queue -- the test that keeps a
## plain walk from holding the queue for nothing.
static func _walk_has_epilogue(events: Array) -> bool:
	for entry: Variant in events:
		var kind: String = DictRead.as_string(
			DictRead.as_dict(entry).get("kind", ""))
		if kind == "mine_detonated" or kind == "teleported" \
				or kind == "teleporter_blocked":
			return true
	return false

## The blast a mine under a walker left, drawn as the shot it is.
##
## `aExecuteBomb` calls `aPlayFightAnimation(x, y, x, y, ...)` with source and
## target on the bomb's own cell, and the routine's `sx == tx && sy == ty` arm
## reads **no shooter** and takes weapon 36 or 37 (docs/42 section 4). This
## passes the mover as the slot because the stages need a body to hold the
## camera on -- the mover is the unit standing on that cell -- and everything
## else is the engine's own arguments.
func _present_mine(slot: int, events: Array[Dictionary]) -> float:
	var longest: float = 0.0
	for entry: Dictionary in events:
		if DictRead.as_string(entry.get("kind", "")) != "mine_detonated":
			continue
		longest = maxf(longest, _present_blast(slot,
			DictRead.as_int(entry["x"]), DictRead.as_int(entry["y"]),
			DictRead.as_dict(entry.get("blast", {}))))
	return longest


## One `aExecuteBomb` blast on the cell it went off on. The walk reaches this
## through an event; the jump reaches it through [member WarpResult.blast],
## because `aExecuteWarp` detonates in line (`0x0046F109`) and leaves no
## event behind.
func _present_blast(slot: int, x: int, y: int, blast: Dictionary) -> float:
	if blast.is_empty():
		return 0.0
	return _present_attack(slot, x, y, x, y, ExecuteMove.MINE_WEAPON,
		AttackResult.from_dict(blast))


func attack_cell(x: int, y: int) -> AttackResult:
	var slot: int = _selected
	_begin_command()
	var shot: AttackResult = world.submit_attack(
		AttackCommand.create(slot, x, y))
	# **Before `_after_command`**, which rebuilds and would otherwise drop the
	# body this shot is about to be drawn hitting: the casualties are marked,
	# and the shot is queued so the rebuild sees a running sequence and keeps
	# the marks. The stages themselves run on later frames, after the rebuild.
	var _held: int = _mark_dying(shot.outcomes)
	var _held_back: int = _mark_dying_by(shot.reactions)
	# `0x0047181C`: after the shot the shooter turns towards its best target
	# band -- `aGetDirectionTo(x, y, 0)`, then `aChangeUnitViewDirection`.
	if shot.fired and world.has_unit(slot):
		var facing: int = world.facing_to_target(slot)
		if facing != Combat.FACING_NONE:
			var _turned: bool = world.submit_rotate(RotateCommand.create(slot, facing))
	var view: Dictionary = world.unit_view(slot)
	if not view.is_empty():
		var _hold: float = _present_attack(slot, DictRead.as_int(view["x"]),
			DictRead.as_int(view["y"]), x, y,
			DictRead.as_int(view["weapon"]), shot)
	# The reaction count belongs on screen for the same reason
	# [method move_selected] puts it there: a shot that drew return fire is
	# the player's business, and `World.submit_attack` has been filling
	# `reactions` with nobody reading it.
	_after_command(shot.reason if not shot.fired
		else "%d, %d %s" % [shot.outcomes.size(), shot.reactions.size(),
			_strings.text("hud.reactions")])
	# The shooter's own cell is where the return fire is aimed, and it is
	# queued rather than shown: the shot's own clip runs first.
	_queue_reactions(shot.reactions, slot, DictRead.as_int(view.get("x", x)),
		DictRead.as_int(view.get("y", y)))
	return shot


## Keep every unit this attack killed on screen until its shot's death stage
## hides it (docs/42 section 4.8).
##
## Called **before** the rebuild, because the rebuild is what drops them and
## for the computer's replay it runs ahead of the event's own presentation.
## Returns how many were marked, for a caller and a suite.
func _mark_dying(outcomes: Array) -> int:
	return _mark_dying_payload({"outcomes": outcomes})


## The same for a whole event payload, whatever shape it carries its dead in
## ([method AIPlayback.casualties_of]).
func _mark_dying_payload(payload: Dictionary) -> int:
	return _mark_dying_slots(AIPlayback.casualties_of(payload))


## Hold these slots on screen, the ones the world says are dead.
##
## The hit points are the filter and they are the world's: a unit an outcome
## names but that survived the hit is alive, and holding it would draw a body
## the next rebuild has to take away again.
func _mark_dying_slots(slots: PackedInt32Array) -> int:
	if _units == null or world == null:
		return 0
	var held: int = 0
	for slot: int in slots:
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) != 0:
			continue
		_units.mark_dying(slot)
		held += 1
	return held


## The same, for every reaction one command drained.
func _mark_dying_by(entries: Array) -> int:
	return _mark_dying_payload({"reactions": entries})


## The same, for the blast a mine under a walk or a landing left.
##
## The casualties of `aExecuteBomb` are in the event's own `blast`, not in the
## command's outcomes, so nothing marked them: their nodes were freed by the
## rebuild before [method _present_mine] ever queued the explosion, and the
## body vanished a frame before the shot that killed it.
func _mark_dying_by_mine(events: Array) -> int:
	return _mark_dying_payload({"events": events})

## One shot, as `aPlayFightAnimation` shows it (docs/42 section 4), queued
## on the [SequenceQueue] through [ShotSequence].
##
## **One presenter for every shot in the game** -- the player's, the
## computer's, and every reaction on either turn. `(sx, sy)` is where the
## shot came **from**, and it is passed rather than read back out of the
## world: the computer's playback runs after its turn, so the shooter may
## have moved or died since. The layers are optional separately, because a
## body animates whether or not there is an audio server behind it.
##
## What is gathered here is what the stages need and `core` does not carry:
## the targets' type columns (species, `special`, size), the caption text,
## and the cues -- the weapon's own wave and the overheat trio with the
## muzzle, one voice by the shot's severity and the target's species
## (section 4.5), the impact wave at the impact. Returns the bound on the
## seconds the shot occupies the screen, for the replay.
func _present_attack(shooter: int, sx: int, sy: int, tx: int, ty: int,
		weapon: int, attack: AttackResult, reaction: bool = false,
		mover: int = MapState.NO_UNIT) -> float:
	if attack == null or not attack.fired or world == null:
		return 0.0
	if _sequences == null:
		_sequences = SequenceQueue.create(_audio)
	if _shot_host == null:
		_shot_host = MainShotHost.new(self)
	var view: Dictionary = world.unit_view(shooter)
	var own: bool = not view.is_empty() \
		and DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN
	# The two orbits `aAttackUnit` itself plays, **before** the fight
	# animation its caller runs (docs/42 section 7.5): the overheat's from
	# `aCheckWeaponDamage`, and the skill's from the experience award.
	_present_shot_orbits(shooter, view, attack)
	var targets: Array[Dictionary] = _shot_targets(attack)
	var cues_shot: Array[Dictionary] = []
	var cues_impact: Array[Dictionary] = []
	var cues_barrel: Array[Dictionary] = []
	if _events != null:
		var fire: Dictionary = _events.weapon_fire(weapon)
		if not fire.is_empty():
			cues_shot.append(fire)
		var overheat: Dictionary = _events.overheat_cue(attack.overheat)
		if not overheat.is_empty():
			cues_shot.append(overheat)
		var voice: Dictionary = _shot_voice(targets)
		if not voice.is_empty():
			cues_shot.append(voice)
		var impact: Dictionary = _events.impact_for_weapon(weapon)
		if not impact.is_empty():
			cues_impact.append(impact)
		cues_barrel = _events.for_event_kind(BARREL_WAVE_EVENT)
	var shot: Dictionary = {
		"shooter": shooter, "sx": sx, "sy": sy, "tx": tx, "ty": ty,
		"weapon": weapon, "own": own, "reaction": reaction, "mover": mover,
		"attack": attack, "xp": attack.xp,
		"caption": _fight_caption(view, attack, own, reaction),
		"targets": targets,
		"strings": {"missed": _strings.shipped(MODULE_FIGHT, ID_MISSED),
			"paralyzed": _strings.shipped(MODULE_FIGHT, ID_PARALYZED)},
		"cues_shot": cues_shot, "cues_impact": cues_impact,
		"cues_barrel": cues_barrel,
	}
	var frames: int = ShotSequence.enqueue(_sequences, _shot_host, shot)
	return float(frames) / SequenceQueue.FRAMES_PER_SECOND


## `0x0040F420` for an overheat outcome and `0x00410190` for a skill level
## raised, on the queue ahead of the shot. The overheat's own wave is
## already among the shot's cues ([method AudioEvents.overheat_cue]), so
## the orbit here plays none of its own.
func _present_shot_orbits(shooter: int, view: Dictionary,
		attack: AttackResult) -> void:
	if view.is_empty():
		return
	if OVERHEAT_KINDS.has(attack.overheat):
		var kind: int = DictRead.as_int(OVERHEAT_KINDS[attack.overheat])
		# The reactor that blew took the shooter with it -- `check_weapon_damage`
		# writes `hp = 0` for this outcome and the shooter is in nobody's
		# outcome list, so without this the rebuild frees its node before the
		# orbit that hides it ever runs and the camera flies to a fallback.
		if kind == OrbitSequence.OVERHEAT_DESTROYED and _units != null:
			_units.mark_dying(shooter)
		var _heat: int = OrbitSequence.enqueue(_queue(), _host(), shooter,
			OrbitSequence.KIND_OVERHEAT,
			_strings.shipped(MODULE_FIGHT, DictRead.as_int(ID_OVERHEAT_BY_KIND[kind])),
			[], kind)
	# `0x00410190` opens with `call 0x0043B740 / cmp eax, 1 / jne`: the skill
	# orbit plays in the **campaign** and in no other game mode.
	if attack.skill_raised > 0 and world.turn.mode == TurnState.MODE_CAMPAIGN:
		var cues: Array[Dictionary] = []
		if _events != null:
			cues = _events.for_event_kind("skill")
		var _skill: int = OrbitSequence.enqueue(_queue(), _host(), shooter,
			OrbitSequence.KIND_SKILL, "%s %d" % [
				_strings.shipped(MODULE_FIGHT, ID_SKILL), attack.skill_raised],
			cues)


## `0x004104A0` after a reaction shot that jammed its reactor (docs/42
## section 7.4): *Out of ammo!* when the magazine is empty, else *Weapon
## runs hot!*.
func _present_jam(reactor: int) -> void:
	var view: Dictionary = world.unit_view(reactor)
	if view.is_empty():
		return
	var text_id: int = ID_JAM_AMMO if DictRead.as_int(view.get("ammo", 1)) == 0 \
		else ID_JAM_HOT
	var cues: Array[Dictionary] = []
	if _events != null:
		cues = _events.for_event_kind("reaction_jam")
	var _frames: int = OrbitSequence.enqueue(_queue(), _host(), reactor,
		OrbitSequence.KIND_JAM, _strings.shipped(MODULE_FIGHT, text_id), cues)


## docs/42 section 4.2 -- *"<name> received N experience points"* for the
## player's own unit with experience earned; the empty string otherwise.
func _fight_caption(view: Dictionary, attack: AttackResult, own: bool,
		reaction: bool) -> String:
	if not own or reaction or attack.xp <= 0 or view.is_empty():
		return ""
	return "%s %s %d %s" % [DictRead.as_string(view.get("name", "")),
		_strings.shipped(MODULE_FIGHT, ID_RECEIVED), attack.xp,
		_strings.shipped(MODULE_FIGHT, ID_EXPERIENCE_POINTS)]


## The targets of one shot with the type columns the death switch reads.
func _shot_targets(attack: AttackResult) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var types: UnitTypeTable = world.unit_types()
	for entry: Variant in attack.outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(outcome.get("slot", -1))
		var unit: Dictionary = world.unit_view(slot)
		var type_id: int = DictRead.as_int(unit.get("type_id", 0))
		var x: int = DictRead.as_int(outcome["x"])
		var y: int = DictRead.as_int(outcome["y"])
		out.append({"slot": slot, "x": x, "y": y,
			"marker": DictRead.as_int(outcome["marker"]),
			"dealt": DictRead.as_int(outcome.get("dealt", 0)),
			"stunned": DictRead.as_bool(outcome.get("stunned", false)),
			"type_id": type_id,
			"player": DictRead.as_int(unit.get("player", 0)),
			"species": types.species(type_id), "special": types.special(type_id),
			"size": types.unit_size(type_id),
			"cell": world.state.index_of(x, y) if world.state.in_bounds(x, y)
				else 0})
	return out


## docs/42 section 4.5 -- one voice by the shot's severity and the target's
## species: the pain scream for damage, the death scream for a kill.
func _shot_voice(targets: Array[Dictionary]) -> Dictionary:
	var worst: int = ShotSequence.severity(targets)
	if worst < ShotSequence.SEVERITY_DAMAGE or targets.is_empty():
		return {}
	# The species the engine reads is the last unit the sweep looked at, and
	# `targets` is already in that order: the loop at `0x0040DA83` walks the
	# **marked** arrays (`0x004FBFF8`, `0x004FBE54`, `0x004FBE72`) in the
	# order `aMarkTargetCells` filled them, and `Combat.attack` appends an
	# outcome per marked cell in the same order. Sorting by cell index --
	# which [method ShotSequence._deaths] used to do for the same local --
	# differed for every weapon whose pattern does not mark in ascending
	# order, which is most of them.
	var last: Dictionary = targets[targets.size() - 1]
	var species: int = DictRead.as_int(last.get("species", 0))
	# The type as well: `0x0040CBDF` reads `+0x4C` and silences 22, 25 and 26,
	# all of which are species 0 and would otherwise scream (docs/42 §4.5).
	var type_id: int = DictRead.as_int(last.get("type_id", -1))
	if worst == ShotSequence.SEVERITY_KILL:
		return _events.death_voice(species, type_id)
	return _events.pain(species, type_id)


## docs/42 section 4.3 -- the camera a shot gets, and how long it takes.
##
## The player's own shot moves nothing. A computer shooter is framed by
## [method CameraDirector.computer_shot]; a reaction on either turn by the
## coin toss of [method CameraDirector.reaction_shot]. The flight's seconds
## are returned so the hold covers it: the engine's flight blocks, and the
## clip stage before it is what the remake runs alongside rather than before
## -- a deviation of the clip's few frames, recorded in docs/97.
func _camera_for_shot(shooter: int, sx: int, sy: int, tx: int, ty: int,
		attack: AttackResult, reaction: bool, mover: int) -> float:
	if _director == null or _rig == null:
		return 0.0
	var view: Dictionary = world.unit_view(shooter)
	if view.is_empty():
		return 0.0
	var from: Dictionary = CameraDirector.inputs_at(world, view, sx, sy)
	if reaction:
		return _director.reaction_shot(world, from, _inputs_of(mover, tx, ty),
			_director.toss())
	if DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN:
		return 0.0
	# The target cell's object with the **shooter's** height, as the engine
	# reads it; whether a victim stands there is what the shot resolved on.
	var to: Dictionary = CameraDirector.inputs_at(world, view, tx, ty)
	return _director.computer_shot(from, to, not attack.outcomes.is_empty())


## A named unit standing on a cell as camera inputs -- the cell an event
## puts it on, not the one the world has it on now -- or the bare cell when
## there is no record to read. The record outlives the unit: a mover killed
## by the reaction being shown, or one that walked on before the playback
## reached this event, still has its type, which is what the shot cameras
## need (its height and its size); the cell is the event's.
func _inputs_of(slot: int, x: int, y: int) -> Dictionary:
	if not world.state.in_bounds(x, y):
		return {}
	var view: Dictionary = world.unit_view(slot) if slot >= 0 else {}
	if not view.is_empty():
		return CameraDirector.inputs_at(world, view, x, y)
	return {"obj": CameraRig.cell_object(x, y,
			world.state.height_at(world.state.index_of(x, y))),
		"height": 0, "gradient": Vector3i(0, 1, 0), "large": false,
		"x": x, "y": y}


## Every reaction one command drained, shown at the cell that drew them.
##
## `Reaction.drain` returns `{"reactor": slot, "ticket": int, "attack": ...}`
## and the target is always the mover, whose slot and cell the caller has --
## the cell as it was when the fire was drawn, which during the computer's
## replay is not where the world has the mover now. Returns the longest of
## the shots, so a caller pacing a replay can wait for all of them.
##
## A reactor the fog does not draw has no body this rebuild and animates
## nothing; its shot is still heard and its blobs still fly, which is what the
## player would have had from an unseen shooter in the original.
func _present_reactions(entries: Array, mover: int, tx: int,
		ty: int) -> float:
	if world == null or entries.is_empty():
		return 0.0
	var longest: float = 0.0
	for item: Variant in entries:
		var entry: Dictionary = DictRead.as_dict(item)
		var reactor: int = DictRead.as_int(entry.get("reactor", -1))
		var view: Dictionary = world.unit_view(reactor)
		if view.is_empty():
			continue
		var attack: AttackResult = AttackResult.from_dict(
			DictRead.as_dict(entry.get("attack", {})))
		longest = maxf(longest, _present_attack(reactor,
			DictRead.as_int(view["x"]), DictRead.as_int(view["y"]), tx, ty,
			DictRead.as_int(view["weapon"]), attack, true, mover))
		if DictRead.as_bool(entry.get("jammed", false)):
			_present_jam(reactor)
	return longest


## Hold return fire until the picture has caught up with what `core` did.
func _queue_reactions(entries: Array, mover: int, tx: int, ty: int) -> void:
	if entries.is_empty():
		return
	_pending_reactions.append({"entries": entries.duplicate(true),
		"mover": mover, "x": tx, "y": ty})


## Show one waiting batch of return fire, when there is room for it.
##
## The condition is a **state** test and deliberately not an edge: a move that
## was refused or that walked no steps still drained reactions in `core`, and
## an edge on a walk ending would never fire for it. Returns how many batches
## are still waiting, for a suite.
func _drain_pending_reactions() -> int:
	if _pending_reactions.is_empty() or _units == null:
		return _pending_reactions.size()
	if _units.is_walking() or _units.any_busy() \
			or (_sequences != null and _sequences.is_running()):
		return _pending_reactions.size()
	var batch: Dictionary = _pending_reactions[0]
	_pending_reactions.remove_at(0)
	var _hold: float = _present_reactions(DictRead.as_array(batch["entries"]),
		DictRead.as_int(batch["mover"]), DictRead.as_int(batch["x"]),
		DictRead.as_int(batch["y"]))
	return _pending_reactions.size()


## Fill a `CreateBGB` table from a script's outcome -- docs/28 section 8.2.
##
## The command is the one effect a **script** places by itself, and `INIT MAP`
## is where every shipped call sits: fourteen in the corpus, four of them on
## each campaign map. The interpreter records the eight arguments and nothing
## consumed them until now, which is why the burning buildings on the location
## map were not burning.
func _register_emitters(table: BgbEmitters, outcome: Dictionary,
		hooks: GameBlobHooks) -> int:
	if table == null or outcome.is_empty():
		return 0
	var made: int = 0
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if event.is_empty() or AudioEvents.name_of(event) != CREATE_BGB:
			continue
		# The hooks go in because registration is half of `CreateBGB`: types
		# 2..6 make their one object here and never tick. Without them a
		# `_C_102` warning light would be a table row and no light.
		if table.register_event(SetpieceDriver._numbers(event), hooks):
			made += 1
	return made


## The sounds one run of a mission script asks for.
##
## `core` has already applied every state change these events record -- the
## door is open, the lift has moved -- so what reaches here is the half the
## simulation does not own: docs/28's `aPlay*Sequence` sounds, keyed by the
## routine that owns them.
func _present_script(outcome: Dictionary) -> int:
	if outcome.is_empty() or _audio == null or _events == null:
		return 0
	var played: int = 0
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if event.is_empty():
			continue
		var cues: Array[Dictionary] = _events.for_event(event)
		# docs/42 section 2.4 -- the script's own camera, before its set
		# pieces: `MoveCamera` and its five siblings are flights on the same
		# queue, so a script that moves the camera twice shows both moves.
		var script_kind: String = AudioEvents.name_of(event)
		if ScriptCamera.handles(script_kind) and _sequences != null:
			var _moved: int = ScriptCamera.enqueue(_sequences, _host(),
				script_kind, SetpieceDriver._numbers(event), _saved_cameras)
			if _rig != null:
				_rig.set_view_mode(CameraRig.View.SCRIPT)
			played += cues.size()
			if not cues.is_empty() and _audio != null:
				var _s: PackedInt32Array = _audio.play_cues(cues, "script")
			continue
		var frames: int = SetpieceDriver.frames_for(event)
		if frames > 0 and _sequences != null:
			# An animated set piece: the picture is interpolated over the
			# frames the original's own loop ran for, and its sound lives for
			# exactly that long rather than for the length of its sample.
			_queue_setpiece(event, frames, cues)
			played += cues.size()
			continue
		if cues.is_empty():
			continue
		var slots: PackedInt32Array = _audio.play_cues(cues, "script")
		played += slots.size()
	return played


## Queue one set piece: hold the cell where it was drawn, and walk it to where
## `core` has already put it.
##
## The offset is against the **drawn** snapshot, not against the authored
## height, so a lift that has moved twice starts its second trip from where the
## first one left it. `core` is never read for anything but the destination.
func _queue_setpiece(event: Dictionary, frames: int,
		cues: Array[Dictionary], about_unit: int = MapState.NO_UNIT) -> void:
	var cell: Vector2i = SetpieceDriver.cell_of(event)
	if world == null or not world.state.in_bounds(cell.x, cell.y):
		if not cues.is_empty() and _audio != null:
			var _slots: PackedInt32Array = _audio.play_cues(cues, "script")
		return
	var index: int = world.state.index_of(cell.x, cell.y)
	var was: PackedInt32Array = _drawn_terrain["height_map"] \
		if _drawn_terrain.has("height_map") else PackedInt32Array()
	var from: int = was[index] if index < was.size() \
		else world.state.height_at(index)
	var to: int = world.state.height_at(index)
	var name: String = AudioEvents.name_of(event)
	# A `RoofUnit` inserts its alien the instant the command runs, so the unit
	# is on the map before its fall has started. The body is held out of the
	# picture for the length of the sequence and shown at the end: the criterion
	# is that the unit **appears at the end of the drop, not at the beginning**,
	# and `core` is never asked to delay anything.
	if name == "roof_unit" and _units != null:
		var arriving: int = world.state.unit_at(index)
		if arriving != MapState.NO_UNIT:
			_units.suppress(arriving)
	# Anyone standing on the cell rides it. `core` has already moved them to
	# the destination height, so the passenger is captured **now**, at the
	# start, and carried by the same offset the cell's objects are: without
	# this a unit on a lift is at the top before the lift has left the floor.
	# `roof_unit` is the one animated set piece whose unit is not a passenger
	# -- it is the cargo, and it is suppressed above instead.
	var rider: int = MapState.NO_UNIT
	if name != "roof_unit" and _units != null:
		rider = world.state.unit_at(index)
	# The unit the routine is about: the door's user (the selected unit for
	# the player's own door, none for the LCL wrapper's), the roof's cargo,
	# the ground unit's victim at its own cell.
	var about: int = about_unit
	var extra: Dictionary = _setpiece_extra(name, cell, event)
	var values: PackedInt32Array = SetpieceDriver._numbers(event)
	if name == "roof_unit":
		about = world.state.unit_at(index)
	elif name == "ground_unit" and values.size() >= 4 \
			and world.state.in_bounds(values[2], values[3]):
		var own: Vector2i = Vector2i(values[2], values[3])
		extra["own"] = own
		about = world.state.unit_at(world.state.index_of(own.x, own.y))
	# A command that runs two routines gets its sounds as two stages: the
	# first routine's with the set piece's opening stage, the second's with
	# the stage that stands for the second routine
	# ([constant AudioEvents.EVENT_PHASES]). `cues` is what the caller looked
	# up for the whole event, which for a phased one is every phase at once --
	# right for a sound-only path and wrong here, so the phases are taken
	# apart again rather than played together.
	var lead: Array[Dictionary] = cues
	var late: Array[Dictionary] = []
	if _events != null and AudioEvents.phases_of(name).size() > 1:
		lead = _events.for_event_phase(name, 0)
		late = _events.for_event_phase(name, 1)
	var _frames: int = SetpieceCamera.enqueue(_sequences, _host(), name, frames,
		cell, from, to, about, extra,
		func(frame: int, total: int) -> void:
			_paint_setpiece(index, from, to, frame, total)
			_carry_rider(rider, from, to, frame, total),
		lead, late)


## What each of docs/42 section 8's sequences needs beyond its cell: the
## beam's path, the cells a wall lost, the tiles a stick of bombs fell on.
##
## The paths are **re-walked here from the terrain**, not carried on the
## event: `core` records that the statue fired and who died, and the cells
## the beam crossed are a fact about the map, which `game` may read. The
## para bombs' tiles are the exception -- they are drawn from the mission's
## generator, so the interpreter puts them on the event (docs/97 section 33)
## rather than have the picture draw them a second time.
func _setpiece_extra(name: String, cell: Vector2i,
		event: Dictionary) -> Dictionary:
	var values: PackedInt32Array = SetpieceDriver._numbers(event)
	var out: Dictionary = {}
	match name:
		"statue":
			# **Carried, not re-derived** (docs/97 section 41.1). `core` walks
			# both arms and puts fifteen numbers on the event: the cell, the
			# axis `0x00413C31`'s toggle chose, each arm's endpoint and step
			# count, and each arm's victim as `slot, x, y`. Re-deriving any of
			# it here would read a byte that has already been toggled and a
			# map the victims have already left.
			var beams: Array = []
			var killed: Array = []
			for arm: int in [0, 1]:
				var cells: int = _at_or(values, 5 + arm * 3, 0)
				if cells > 0:
					beams.append({"x": _at_or(values, 3 + arm * 3, cell.x),
						"y": _at_or(values, 4 + arm * 3, cell.y),
						"cells": cells})
				var slot: int = _at_or(values, 9 + arm * 3, -1)
				if slot >= 0:
					killed.append({"slot": slot,
						"x": _at_or(values, 10 + arm * 3, cell.x),
						"y": _at_or(values, 11 + arm * 3, cell.y)})
			out["beams"] = beams
			out["killed"] = killed
		"teleporter":
			# `[entry x, entry y, exit x, exit y]`, the four numbers
			# `_present_teleport` puts on its synthetic event.
			out["tx"] = _at_or(values, 2, cell.x)
			out["ty"] = _at_or(values, 3, cell.y)
		"barrier_on":
			out["direction"] = _at_or(values, 2, 0)
			var step: Vector2i = _facing_step(_at_or(values, 2, 0))
			var cells: int = 0
			# A direction outside the table answers the zero step, which
			# would never advance the walk below: the beam is one cell long
			# and the loop is skipped.
			if step != Vector2i.ZERO:
				var at: Vector2i = cell + step
				while world.state.in_bounds(at.x, at.y) \
						and world.state.field_type_at(
							world.state.index_of(at.x, at.y)) != Interact.FIELD_TYPE_WALL:
					cells += 1
					at += step
			out["cells"] = maxi(1, cells)
			out["killed"] = []
		"crush_wall":
			# `core` carries the cells it changed -- the command's own today,
			# and whatever a footprint gives it later (docs/97 section 41.7).
			var wall: Array = []
			for i: int in range(2, values.size() - 1, 2):
				wall.append([values[i], values[i + 1]])
			out["cells"] = wall if not wall.is_empty() \
				else [[cell.x, cell.y]]
		"para_bombs":
			var tiles: Array = []
			for i: int in range(5, values.size() - 1, 2):
				tiles.append([values[i], values[i + 1]])
			out["tiles"] = tiles
	return out


## The eight barrier directions, as `core`'s own table has them.
static func _facing_step(direction: int) -> Vector2i:
	if direction < 0 or direction >= Interact.FACING_DX.size():
		return Vector2i.ZERO
	return Vector2i(Interact.FACING_DX[direction], Interact.FACING_DY[direction])


static func _at_or(values: PackedInt32Array, index: int, fallback: int) -> int:
	return values[index] if index >= 0 and index < values.size() else fallback


## Hold a unit riding a moving cell at the height the cell has reached.
##
## The offset is against where `core` already put it -- `to` -- so it starts at
## `from - to` and reaches zero on the last frame, whatever direction the lift
## went in.
func _carry_rider(slot: int, from: int, to: int, frame: int,
		frames: int) -> void:
	if slot == MapState.NO_UNIT or _units == null:
		return
	var at: int = from + roundi(float(to - from)
		* SetpieceDriver.progress(frame, frames))
	_units.lift(slot, at - to)


## One frame of a set piece: the cell's objects at the height the original
## would have had them at after `frame` of its own ticks.
func _paint_setpiece(index: int, from: int, to: int, frame: int,
		frames: int) -> void:
	if _scenery == null or world == null:
		return
	var at: int = from + roundi(float(to - from)
		* SetpieceDriver.progress(frame, frames))
	var partial: Dictionary = world.terrain_snapshot()
	var heights: PackedInt32Array = partial["height_map"]
	if index >= heights.size():
		return
	heights[index] = at
	partial["height_map"] = heights
	var _moved: int = _scenery.apply_state(partial, PackedInt32Array([index]))


## Move and repaint whatever the last command changed about the terrain.
##
## Before this, `_scenery.build` and `_overlay.build` ran **once per mission**,
## so a door that changed its cell's field type and raised it by
## [constant Interact.DOOR_HEIGHT_STEP] produced no visible change at all until
## the mission was rebuilt with `[` or `]`. That was the slice's headline
## defect, and closing it needed no new concept in `core`: two immutable
## snapshots and the difference between them.
##
## Answers how many cells changed, so a caller and a suite can tell "nothing
## moved" from "nothing was checked".
## The cells one computer event changed, painted now.
##
## The snapshot `_drawn_terrain` is deliberately **not** advanced: the
## closing [method _redraw_terrain_now] still walks the whole map, so a cell
## painted here is painted again there and nothing is lost if an event's
## list is incomplete. Answers how many cells were painted.
func _redraw_event_cells(payload: Dictionary) -> int:
	if _scenery == null or _overlay == null or world == null:
		return 0
	var cells: PackedInt32Array = DictRead.as_int32_array(
		payload.get("cells", []))
	if cells.is_empty():
		return 0
	var now: Dictionary = world.terrain_snapshot()
	var _moved: int = _scenery.apply_state(now, cells)
	_overlay.rebuild_cells(now, cells)
	return cells.size()


func _redraw_terrain() -> int:
	# A queued set piece owns the cells it is animating: snapping them to the
	# finished state now would show the end of the lift before the lift.
	# `_process` calls `_redraw_terrain_now` when the queue drains.
	if _sequences != null and _sequences.is_running():
		return 0
	return _redraw_terrain_now()


func _redraw_terrain_now() -> int:
	if world == null or _scenery == null or _overlay == null:
		return 0
	var now: Dictionary = world.terrain_snapshot()
	# **The effect planes first, and before the early return.** A weapon-42
	# mine, a shield, a `ParaBombs` drop and the round tick's decay change
	# `+0x0E`..`+0x13` and nothing else, and [TerrainDiff] deliberately does
	# not look at those -- they change what stands on a cell, not what the
	# cell is. So the objects are synced from their own six-plane diff, and
	# the cells it reports join the overlay's rebuild: a mine's tint is as
	# stale as its model would be.
	var effects: PackedInt32Array = PackedInt32Array()
	if _special != null:
		effects = _special.sync(now)
	var changed: PackedInt32Array = TerrainDiff.changed_cells(
		_drawn_terrain, now)
	if changed.is_empty() and effects.is_empty():
		return 0
	var moved: PackedInt32Array = TerrainDiff.moved_cells(_drawn_terrain, now)
	if not moved.is_empty():
		var _n: int = _scenery.apply_state(now, moved)
	for index: int in effects:
		if not changed.has(index):
			changed.append(index)
	_overlay.rebuild_cells(now, changed)
	_drawn_terrain = now
	return changed.size()


func _muzzle_of(x: int, y: int) -> Vector3i:
	var height: int = 0
	if world != null and world.state.in_bounds(x, y):
		height = world.state.height_at(world.state.index_of(x, y))
	return BlobTriggers.muzzle_point(x, y, height)


## What a death creator reads for the tiles its arguments name (docs/97
## section 22): the placed object's position -- the cell's centre at its
## height -- and the unit standing there with its type's height, plus the
## gore level and the output mode.
func _death_inputs(args: PackedInt32Array) -> BlobPrograms.Inputs:
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.gore = world.gore_level
	inputs.display_mode = DISPLAY_MODE
	var types: UnitTypeTable = world.unit_types()
	for i: int in range(0, args.size() - 1, 2):
		var x: int = args[i]
		var y: int = args[i + 1]
		if not world.state.in_bounds(x, y):
			continue
		var index: int = world.state.index_of(x, y)
		var height: int = world.state.height_at(index)
		var unit: Dictionary = {}
		var slot: int = world.state.unit_at(index)
		var view: Dictionary = world.unit_view(slot) if slot >= 0 else {}
		if view.is_empty():
			# The casualty has left the cell in `core` (`UnitState.remove`
			# clears the link at once, where the engine's
			# `aRemoveUnitElement` runs after the animation), but its record
			# keeps its coordinates and its type -- which is what the
			# creator reads through the unit map.
			for candidate: int in world.unit_slots():
				var dead: Dictionary = world.unit_view(candidate)
				if DictRead.as_int(dead.get("hp", 1)) == 0 \
						and DictRead.as_int(dead.get("x", -1)) == x \
						and DictRead.as_int(dead.get("y", -1)) == y:
					view = dead
					break
		if not view.is_empty():
			var type_id: int = DictRead.as_int(view["type_id"])
			unit = {"type": type_id, "player": DictRead.as_int(view["player"]),
				"height": types.body_height_world(type_id)}
			inputs.type_models[type_id] = types.model(type_id)
			inputs.sizes[type_id] = types.unit_size(type_id)
		inputs.tiles[Vector2i(x, y)] = {
			"object": Vector3i(x * WorldSpace.WORLD_UNITS_PER_FIELD,
				y * WorldSpace.WORLD_UNITS_PER_FIELD, height),
			"unit": unit}
	for name: Variant in _fx.hooks().model_index:
		inputs.models[DictRead.as_string(name)] = DictRead.as_int(
			_fx.hooks().model_index[name])
	inputs.geometry = _eng3d
	return inputs


## A position creator's inputs: no tile, the models and the tables alone.
func _position_inputs() -> BlobPrograms.Inputs:
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.gore = world.gore_level
	inputs.display_mode = DISPLAY_MODE
	if _fx != null:
		for name: Variant in _fx.hooks().model_index:
			inputs.models[DictRead.as_string(name)] = DictRead.as_int(
				_fx.hooks().model_index[name])
	inputs.geometry = _eng3d
	return inputs


func use_in_front() -> UseResult:
	if _selected < 0:
		return UseResult.refused("")
	_begin_command()
	# Who stands in front **before** the use: a push moves that record, and
	# the picture of the push (docs/42 section 7.2) needs its slot and its
	# first cell, which the result does not carry.
	var pushed: int = MapState.NO_UNIT
	var front: Vector2i = Vector2i(-1, -1)
	var pusher: Dictionary = world.unit_view(_selected)
	var facing: int = DictRead.as_int(pusher.get("facing", -1))
	# The guard [method Interact.cell_in_front] and [method
	# Interact.can_push] both make before the same index.
	if not pusher.is_empty() and facing >= 0 \
			and facing < Interact.FACING_DX.size():
		front = Vector2i(DictRead.as_int(pusher["x"]) + Interact.FACING_DX[facing],
			DictRead.as_int(pusher["y"]) + Interact.FACING_DY[facing])
		if world.state.in_bounds(front.x, front.y):
			pushed = world.state.unit_at(world.state.index_of(front.x, front.y))
	var used: UseResult = world.submit_use(UseCommand.create(_selected))
	if used.ok and used.kind == World.DOOR_USE_KIND and _sequences != null \
			and world.state.in_bounds(front.x, front.y):
		# docs/42 section 8: the player's Use passes real tiles, so the door
		# gets its flight from the user's head and back; the LCL wrapper's
		# `-1, -1` is the one that does not.
		var door_cues: Array[Dictionary] = []
		if _events != null:
			door_cues = _events.for_use(used)
		_queue_setpiece({"name": "open_door", "values": [front.x, front.y]},
			SetpieceDriver.DOOR_FRAMES, door_cues, _selected)
	if used.ok and PUSH_KINDS.has(used.kind) and pushed != MapState.NO_UNIT:
		var hole: bool = used.kind == PUSH_INTO_HOLE
		if hole and _units != null:
			# The record is gone from the map; the body stays for the slide.
			_units.mark_dying(pushed)
		var cells: Array[Vector2i] = []
		for step: PackedInt32Array in used.pushed:
			cells.append(Vector2i(step[0], step[1]))
		var _frames: int = PushSequence.enqueue(_queue(), _host(), _selected,
			pushed, front, cells, hole)
	_after_command(used.kind if used.ok else used.reason)
	# The player's own door emits **no event** -- `Interact.toggle_door` writes
	# the state change and returns, and only the LCL `OpenDoor` path records
	# one. So the sound is driven from the result, not from the event stream,
	# and this is why [method AudioEvents.for_use] exists at all.
	if _audio != null and _events != null and not (used.ok
			and used.kind == World.DOOR_USE_KIND and _sequences != null):
		var _slots: PackedInt32Array = _audio.play_cues(
			_events.for_use(used), "use")
	return used


## docs/29 section 1.1's button 2 -- the medic kit, and the heal orbit
## (docs/42 section 7.5) for the unit it healed. Answers [method
## World.submit_heal]'s dictionary.
func heal_selected() -> Dictionary:
	if _selected < 0:
		return {"ok": false, "reason": "no selection", "target": -1,
			"delta": 0, "self_heal": false}
	# **The gate comes first**, as it does for `Use`: the pad offers button 2
	# only past `0x0047B4C0` and `+0x15 >= 1` (`0x0047261C`), and the command
	# behind it charges a point even when it heals nothing -- a press the
	# pad never offers must not cost one here either.
	if not world.may_heal(_selected):
		return {"ok": false, "reason": "the medic kit is not offered",
			"target": -1, "delta": 0, "self_heal": false}
	_begin_command()
	var healed: Dictionary = world.submit_heal(HealCommand.create(_selected))
	if DictRead.as_bool(healed["ok"]):
		var target: int = DictRead.as_int(healed["target"])
		var view: Dictionary = world.unit_view(target)
		var caption: String = "%s: %s %d" % [DictRead.as_string(view.get("name", "")),
			_strings.shipped(MODULE_FIGHT, ID_HEAL), DictRead.as_int(healed["delta"])]
		var cues: Array[Dictionary] = []
		if _events != null:
			cues = _events.for_event_kind("heal")
		var _frames: int = OrbitSequence.enqueue(_queue(), _host(), target,
			OrbitSequence.KIND_HEAL, caption, cues)
	_after_command("heal" if DictRead.as_bool(healed["ok"])
		else DictRead.as_string(healed["reason"]))
	return healed


## The Jet Pack's jump (docs/23 section 7.5) and its picture (docs/42
## section 7.1). The reactions the landing drew are queued behind the jump
## the way a walk's are behind the walk.
func warp_selected(x: int, y: int) -> WarpResult:
	var slot: int = _selected
	_begin_command()
	var jumped: WarpResult = world.submit_warp(WarpCommand.create(slot, x, y))
	var _held: int = _mark_dying_by(jumped.reactions)
	# The mine under the landing kills before the rebuild sees it, exactly as
	# the walk's does: `aExecuteWarp` detonates in line at `0x0046F109`.
	var _blasted: int = _mark_dying(
		DictRead.as_array(DictRead.as_dict(jumped.blast).get("outcomes", [])))
	if jumped.ok:
		_present_jump(slot, Vector2i(jumped.from_x, jumped.from_y),
			Vector2i(jumped.x, jumped.y), true)
	_after_command(jumped.reason if not jumped.ok else "%d %s" % [
		jumped.reactions.size(), _strings.text("hud.reactions")])
	# Behind the jump and **ahead of the reactions**, for the reason the walk's
	# blast is: `aExecuteWarp` reaches `aExecuteBomb` at `0x0046F109` and the
	# routine plays its own fight animation before returning, while the drain
	# is the caller's.
	var _blast: float = _present_blast(slot, jumped.x, jumped.y, jumped.blast)
	_queue_reactions(jumped.reactions, slot, x, y)
	return jumped


## One jump on the queue, the player's (trail, `jump.wav`, `drop.wav`) or
## the computer's (one of three screams). Answers its deterministic frames.
func _present_jump(slot: int, from: Vector2i, to: Vector2i, own: bool) -> int:
	var jump: Array[Dictionary] = []
	var drop: Array[Dictionary] = []
	var screams: Array = [[], [], []]
	if _events != null:
		for cue: Dictionary in _events.for_event_kind("jump"):
			var wave: String = DictRead.as_string(cue["wave"]).to_lower()
			if wave == JUMP_WAVE:
				jump.append(cue)
			elif wave == DROP_WAVE:
				drop.append(cue)
			elif SCREAM_WAVES.has(wave):
				var index: int = SCREAM_WAVES.find(wave)
				var bucket: Array = screams[index]
				bucket.append(cue)
	return JumpSequence.enqueue(_queue(), _host(), slot, from, to, own, jump,
		drop, screams)


## docs/42 section 7.3 -- the four arrows round the selected unit, raised
## by the select routine and after every pad command (`0x00473920`) when
## the animation level allows; never per frame.
func _raise_marker() -> void:
	if _selected < 0 or world == null or _fx == null or not world.has_unit(_selected):
		return
	if _units != null and not _units.scheduler.enabled:
		return
	var view: Dictionary = world.unit_view(_selected)
	if view.is_empty():
		return
	_host().spawn_program(BlobPrograms.ARROWS, PackedInt32Array(
		[DictRead.as_int(view["x"]), DictRead.as_int(view["y"])]))


func _queue() -> SequenceQueue:
	if _sequences == null:
		_sequences = SequenceQueue.create(_audio)
	return _sequences


func _host() -> MainShotHost:
	if _shot_host == null:
		_shot_host = MainShotHost.new(self)
	return _shot_host


func hold_fire() -> int:
	if _selected < 0:
		return 0
	_begin_command()
	var ticket: int = world.submit_defend(DefendCommand.create(_selected))
	_after_command(_strings.text("hud.overwatch") if ticket > 0 else "")
	return ticket


## Ends the current player's turn. The computer's turn runs **inside**
## [method World.submit_end_turn] now (docs/23), and hands over again by itself
## when it is done, so what comes back has already passed the rotation on. The
## loop that used to sit here would have run `NEXT PLAYER` a second time per
## round -- which on `_C_140` is the script's reinforcement roll firing twice
## as often as the mission intends.
func end_turn() -> TurnResult:
	_begin_command()
	var result: TurnResult = world.submit_end_turn(EndTurnCommand.create())
	if result.ran_turn_script:
		var _turn_sounds: int = _present_script(result.turn_script)
	if result.ran_player_script:
		var _player_sounds: int = _present_script(result.player_script)
	if result.ai_result != null:
		_playback.play(result.ai_result, Callable(self, "_on_ai_step"))
	# **Before the rebuild `_after_command` does below.** [method
	# AIPlayback.play] does not take its first step -- that waits for
	# [constant AIPlayback.STEP_SECONDS] -- so without this every unit the
	# computer is about to walk stands at its destination for the first half
	# second of the replay, and then jumps back to walk there. That window is
	# the half of the defect that placing the body on its first cell in
	# [method UnitsView.start_walk] does not reach.
	if _units != null:
		var owed: Dictionary[int, Vector2i] = {}
		if _playback.is_running():
			owed = _playback.pending_starts()
		_units.hold_at(owed)
	# **And the other half of the same defect.** The world has held the end of
	# the turn since `submit_end_turn` returned, so the rebuild below drops
	# every unit the computer is *going* to kill -- a marine shot on the
	# fourth event vanished as the replay opened and reappeared when its own
	# event marked it, a second before it died. The whole list is held from
	# here instead; each event re-marks its own, and [method
	# UnitsView.hide_now] takes them out one at a time in the death stage.
	if _playback.is_running():
		var _doomed: int = _mark_dying_slots(_playback.pending_casualties())
	_deselect()
	# A turn with nothing to replay hands back here rather than through
	# [method _on_ai_step]; the same flag decides whether the view moves.
	if not _playback.is_running() \
			and world.compat_flags.has(COMPAT_CAMERA_RETURNS):
		var _back: int = focus_on_friendly(_rig, world)
	_after_command("")
	# The turn's autosave, for *Undo last turn* (docs/43 section 5).
	if _may_command_now():
		_autosave(HudTables.SLOT_UNDO_TURN)
	return result


## Everything a command changes is redrawn from the world, never patched.
## The start of every player command: whatever the last one left waiting
## -- return fire not yet shown, casualties marked for a shot that was never
## finished -- belongs to a command the player has moved on from. Called
## **before** the command marks its own casualties, which is why it is not
## part of [method _after_command].
func _begin_command() -> void:
	# docs/97 section 34: the engine probes the fog before every player
	# command, and the groups that probe wakes stay woken.
	if world != null:
		var _woken: int = world.probe_fog()
	_pending_reactions.clear()
	if _units != null and (_sequences == null or not _sequences.is_running()):
		_units.clear_dying()


func _after_command(note: String) -> void:
	_units.build(world, _geometry, _textures)
	_redraw_terrain()
	if _selected >= 0 and world.has_unit(_selected):
		# `0x00472B10`: a unit left with no movement points is deselected
		# after its command (docs/43 section 4).
		if DictRead.as_int(world.unit_view(_selected)["mp"]) == 0:
			_deselect()
		else:
			var again: MoveMapResult = world.submit_move_query(
				MoveQueryCommand.create(_selected))
			_last_query = again
			_bands = world.target_bands(_selected)
			# The pad raises the marker again after its command
			# (`0x00471A49`, `0x00471A72`).
			_raise_marker()
	_refresh_overlay()
	_refresh_status(note)


# --- the battle interface (docs/43) ---------------------------------------

## Redraw the ground overlay from the world and the selection.
func _refresh_overlay() -> void:
	if _ground == null or world == null:
		return
	_far_drawn = _far_view()
	_ground.refresh(_art, world, _selected, _last_query, _hover, _bands,
		turn_player(), _far_drawn)


## Whether the camera is above the zoom gate, where the overlay switches to
## the far view's flags (`0x00418343`).
func _far_view() -> bool:
	return _rig != null and _rig.eye().z >= HudTables.ZOOM_GATE


## The interface's own clock: the blink, the ring's projection, the hover,
## the far/near switch and the turn a walk owed.
func _tick_interface(delta: float) -> void:
	if world == null or _hud == null or _rig == null:
		return
	_blink_clock += delta
	if _blink_clock >= HudTables.BLINK_PERIOD_SECONDS:
		_blink_clock = fmod(_blink_clock, HudTables.BLINK_PERIOD_SECONDS)
		_blink_odd = not _blink_odd
		if _ground != null:
			_ground.tick(_blink_odd)
	_hud.ring.update(_rig.camera(), _hud.window(), _blink_odd)
	if _far_view() != _far_drawn:
		_refresh_overlay()
	if not _pending_turn.is_empty() and (_units == null or not _units.is_walking()):
		if _units != null:
			var _faced: bool = _units.turn_to(DictRead.as_int(_pending_turn["slot"]),
				HudTables.FACING_ANGLES[DictRead.as_int(_pending_turn["facing"])])
		_pending_turn = {}
	_poll_hover()


## The cell under the pointer, read when the pointer moves: inside the
## window it is the ray pick's answer, outside it none. The hovered cell
## gates the digits and wears the frame (docs/43 section 3), and the ring
## reads it for its tiers.
func _poll_hover() -> void:
	if _screen != null or not _hud.visible:
		return
	# Only when the viewport's own pointer moved: a driver's synthetic motion
	# (`tour.gd`) sets the hover through the event, and re-reading a pointer
	# that has not moved would undo it every frame.
	var pointer: Vector2 = get_viewport().get_mouse_position()
	if pointer == _polled:
		return
	_polled = pointer
	_update_hover(pointer)


func _update_hover(pointer: Vector2) -> void:
	if _screen != null or _hud == null or _rig == null or world == null:
		return
	if pointer == _pointer:
		return
	_pointer = pointer
	var cell: Vector2i = Vector2i(-1, -1)
	if _hud.window().has_point(pointer):
		cell = cell_under(_rig.camera(), world, pointer, 1.0)
	if _hud.ring.is_up():
		var _changed: bool = _hud.ring.hover(_rig.camera(), pointer)
	if cell != _hover:
		_hover = cell
		_refresh_overlay()


## The screen-space directions of the map's `+y` and `+x` as the camera shows
## them, for the radar's turn: unit vectors, y down.
func _radar_axes() -> Array[Vector2]:
	var axes: Array[Vector2] = [Vector2(0.0, -1.0), Vector2(1.0, 0.0)]
	if _rig == null or _rig.camera() == null or world == null \
			or not _rig.camera().is_inside_tree():
		return axes
	var camera: Camera3D = _rig.camera()
	var target: Vector3i = _rig.target()
	var origin: Vector3 = WorldSpace.to_godot(target.x, target.y, target.z)
	var north: Vector3 = origin + WorldSpace.to_godot_v(
		Vector3(0.0, float(WorldSpace.WORLD_UNITS_PER_FIELD), 0.0))
	var east: Vector3 = origin + WorldSpace.to_godot_v(
		Vector3(float(WorldSpace.WORLD_UNITS_PER_FIELD), 0.0, 0.0))
	if camera.is_position_behind(origin) or camera.is_position_behind(north) \
			or camera.is_position_behind(east):
		return axes
	var at: Vector2 = camera.unproject_position(origin)
	var to_north: Vector2 = camera.unproject_position(north) - at
	var to_east: Vector2 = camera.unproject_position(east) - at
	if to_north.length() > 0.0:
		axes[0] = to_north.normalized()
	if to_east.length() > 0.0:
		axes[1] = to_east.normalized()
	return axes


## Whether a column button's event can run now (docs/43 section 5): the two
## undo buttons and *Recall position* need their slot written, the four save
## paths and the briefing need a campaign, *Jump to visible enemy* needs one,
## and the magnifier -- an info page out of `Data` the cache does not carry
## -- is never offered.
func _event_available(number: int) -> bool:
	if world == null or _mission_over() or _playback.is_running():
		return false
	var has_campaign: bool = campaign != null and campaign.state != null
	match number:
		HudTables.EVENT_LOAD:
			return true
		HudTables.EVENT_SAVE, HudTables.EVENT_REMIND_POSITION, \
				HudTables.EVENT_BRIEFING:
			return has_campaign
		HudTables.EVENT_RECALL_POSITION:
			return _slot_holds_this_mission(HudTables.SLOT_REMIND)
		HudTables.EVENT_UNDO_TURN:
			return _slot_holds_this_mission(HudTables.SLOT_UNDO_TURN)
		HudTables.EVENT_UNDO_MISSION:
			return _slot_holds_this_mission(HudTables.SLOT_UNDO_MISSION)
		HudTables.EVENT_MAGNIFIER:
			return false
		HudTables.EVENT_NEXT_UNIT:
			return _may_command_now() and next_friendly_slot(world, _selected) >= 0
		HudTables.EVENT_VISIBLE_ENEMY:
			return _visible_enemy_after(-1) >= 0
		HudTables.EVENT_GIVE_UP, HudTables.EVENT_NEXT_PLAYER:
			return _may_command_now()
	return true


## Whether a pad socket is lit for the selection (`0x00472570`).
func _command_available(number: int) -> bool:
	if world == null or _selected < 0 or not _may_command_now() \
			or not world.has_unit(_selected) or _playback.is_running():
		return false
	match number:
		HudTables.COMMAND_DEFEND:
			return world.may_defend(_selected)
		HudTables.COMMAND_HEAL:
			return world.may_heal(_selected)
		HudTables.COMMAND_STIMULANT:
			return world.may_take_stimulant(_selected)
		HudTables.COMMAND_WEAPON_MODE:
			return world.may_toggle_weapon(_selected)
		HudTables.COMMAND_REST:
			return world.may_stand_down(_selected)
		HudTables.COMMAND_USE:
			return world.may_use(_selected)
	return false


## A column button, or its key: one of the sixteen interface events of
## `0x00453900` (docs/29 section 1.2, docs/43 section 5).
func _on_hud_event(number: int) -> void:
	if not _event_available(number):
		return
	match number:
		HudTables.EVENT_FREE_CAMERA:
			_rig.set_view_mode(CameraRig.View.SCRIPT)
			_sync_hud()
		HudTables.EVENT_UNIT_VIEW:
			_set_view(CameraRig.View.EYES)
		HudTables.EVENT_MAP_VIEW:
			_set_view(CameraRig.View.MAP)
		HudTables.EVENT_USER_VIEW:
			_set_view(CameraRig.View.UNIT)
		HudTables.EVENT_LOAD:
			shell.open(ShellHost.SCREEN_SLOTS, _behind_the_shell())
			shell.go_slots(ShellHost.MODE_LOAD)
			var _load: CampaignScreen = _show_shell_screen()
		HudTables.EVENT_SAVE:
			shell.open(ShellHost.SCREEN_SLOTS, _behind_the_shell())
			shell.go_slots(ShellHost.MODE_SAVE)
			var _save: CampaignScreen = _show_shell_screen()
		HudTables.EVENT_RECALL_POSITION:
			var _recalled: bool = quick_load(HudTables.SLOT_REMIND)
		HudTables.EVENT_REMIND_POSITION:
			var _reminded: bool = quick_save(HudTables.SLOT_REMIND)
		HudTables.EVENT_GIVE_UP:
			# `0x0047BC60(player)`: every unit of the player is removed, and
			# the turn goes on without them.
			var _gone: int = world.clear_units_of(turn_player())
			_deselect()
			var _turn: TurnResult = end_turn()
		HudTables.EVENT_NEXT_PLAYER:
			var _ended: TurnResult = end_turn()
		HudTables.EVENT_BRIEFING:
			var _briefing: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_BRIEFING)
		HudTables.EVENT_NEXT_UNIT:
			var _next: int = cycle_friendly()
		HudTables.EVENT_VISIBLE_ENEMY:
			_jump_to_visible_enemy()
		HudTables.EVENT_UNDO_TURN:
			var _undone: bool = quick_load(HudTables.SLOT_UNDO_TURN)
		HudTables.EVENT_UNDO_MISSION:
			var _restarted: bool = quick_load(HudTables.SLOT_UNDO_MISSION)


## A pad socket, or its key: one of the six commands (docs/29 section 1.1).
## The gate runs here as well as on the pad, because the key has no socket.
func _on_pad_command(number: int) -> void:
	if not _command_available(number):
		return
	match number:
		HudTables.COMMAND_DEFEND:
			var _ticket: int = hold_fire()
		HudTables.COMMAND_HEAL:
			var _healed: Dictionary = heal_selected()
		HudTables.COMMAND_STIMULANT:
			_begin_command()
			var _spent: bool = world.submit_stimulant(
				SpendStimulantCommand.create(_selected))
			_after_command("")
		HudTables.COMMAND_WEAPON_MODE:
			_begin_command()
			var _toggled: bool = world.submit_toggle_weapon(
				ToggleWeaponCommand.create(_selected))
			_after_command("")
		HudTables.COMMAND_REST:
			_begin_command()
			var _rested: bool = world.submit_stand_down(
				StandDownCommand.create(_selected))
			_after_command("")
		HudTables.COMMAND_USE:
			var _used: UseResult = use_in_front()


## The interface as scalars, for `tour.gd`.
func hud_view() -> Dictionary:
	return _hud.view() if _hud != null else {}


func ground_overlay() -> GroundSprites:
	return _ground


## A column button by its event, as a click on it (`tour.gd`'s `hud event`).
func press_hud_event(number: int) -> bool:
	if _hud == null or world == null:
		return false
	return _hud.columns.press_event(number)


## A pad socket by its command, as a click on it (`hud pad`).
func press_pad_command(number: int) -> bool:
	if _hud == null or world == null:
		return false
	return _hud.pad.press(number)


## A ring record by its number, as a click on its letter (`hud ring`).
func choose_ring_record(record: int) -> bool:
	if _hud == null or not _hud.ring.is_up() or not _may_command_now():
		return false
	if record == DirectionRing.CANCEL_RECORD:
		_hud.ring.take_down()
		_refresh_status("")
		return true
	if record < 0 or record >= DirectionRing.CANCEL_RECORD:
		return false
	_complete_ring(record)
	return true


## The radar's scale, stepped as a click on its screen (`hud radar`).
func step_radar(direction: int) -> int:
	if _hud == null:
		return 0
	return _hud.radar.step(direction)


## `0x00477DF0` as `0x00453CF0` walks it: the next live unit of another
## player that is fully visible, after *after* in slot order, or -1.
func _visible_enemy_after(after: int) -> int:
	if world == null:
		return -1
	var slots: PackedInt32Array = world.unit_slots()
	var start: int = slots.find(after) + 1
	for step: int in range(slots.size()):
		var slot: int = slots[(start + step) % slots.size()]
		var view: Dictionary = world.unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
			continue
		if DictRead.as_int(view["player"]) == turn_player():
			continue
		if DictRead.as_int(view["visibility"]) != AIOverlay.VISIBILITY_VISIBLE:
			continue
		return slot
	return -1


## *Jump to visible enemy* (event 14): the camera goes to the next visible
## enemy, with the placement the cycle uses (`0x00453D42`).
var _enemy_shown: int = -1
func _jump_to_visible_enemy() -> void:
	var slot: int = _visible_enemy_after(_enemy_shown)
	if slot < 0:
		return
	_enemy_shown = slot
	if _director != null:
		var _flight: float = _director.cycle(world, slot)


## [ShotHost] over this scene: the bodies, the camera, the overlay, the
## sound system and the pool, each optional.
class MainShotHost extends ShotHost:
	var main: SliceMain = null

	func _init(owner: SliceMain) -> void:
		main = owner

	func body_frames(slot: int) -> Dictionary:
		if main._units == null:
			return {"to_break": 0, "spin": 0, "after_break": 0}
		return main._units.body_frames(slot)

	func fire_body(slot: int, tx: int, ty: int) -> Dictionary:
		if main._units == null:
			return {"to_break": 0, "spin": 0, "after_break": 0}
		var _seconds: float = main._units.fire(slot, tx, ty)
		return main._units.body_frames(slot)

	func body_playing(slot: int) -> bool:
		return main._units != null and main._units.is_playing(slot)

	func resume_body(slot: int) -> int:
		return 0 if main._units == null else main._units.resume_past_break(slot)

	func rest_body(slot: int) -> void:
		if main._units != null:
			main._units.rest(slot)

	func body_type(slot: int) -> int:
		var view: Dictionary = main.world.unit_view(slot) if main.world != null else {}
		return DictRead.as_int(view.get("type_id", -1))

	func camera(shot: Dictionary) -> int:
		var attack: AttackResult = shot["attack"]
		var seconds: float = main._camera_for_shot(
			DictRead.as_int(shot["shooter"]), DictRead.as_int(shot["sx"]),
			DictRead.as_int(shot["sy"]), DictRead.as_int(shot["tx"]),
			DictRead.as_int(shot["ty"]), attack,
			DictRead.as_bool(shot.get("reaction", false)),
			DictRead.as_int(shot.get("mover", MapState.NO_UNIT)))
		return ceili(seconds * SequenceQueue.FRAMES_PER_SECOND)

	func camera_flying() -> bool:
		return main._rig != null and main._rig.is_flying()

	func set_caption(text: String) -> void:
		if main._texts != null:
			main._texts.set_caption(text)

	func clear_caption() -> void:
		if main._texts != null:
			main._texts.clear_caption()

	func clear_texts() -> void:
		if main._texts != null:
			main._texts.clear()

	func add_text(text: String, _kind: int, x: int, y: int) -> void:
		if main._texts == null or main._rig == null or main.world == null:
			return
		var at: Vector3i = main._muzzle_of(x, y)
		var on: Dictionary = main._rig.screen_point(at)
		# A failed projection draws at y 0, which is the engine's own answer.
		var where: Vector2 = Vector2(DictRead.as_float(on.get("x", 0.0)),
			DictRead.as_float(on.get("y", 0.0)))
		var _added: bool = main._texts.add_text(text, where)

	func begin_fade() -> void:
		if main._texts != null:
			main._texts.begin_fade()

	func is_fading() -> bool:
		return main._texts != null and main._texts.is_fading()

	func tick_overlay() -> void:
		if main._texts != null:
			main._texts.tick()

	func play_cues(cues: Array[Dictionary]) -> void:
		if main._audio != null and not cues.is_empty():
			var _slots: PackedInt32Array = main._audio.play_cues(cues, "shot")

	func muzzle(weapon: int, sx: int, sy: int, tx: int, ty: int) -> void:
		if main._triggers == null or main._fx == null:
			return
		# The creator's own write over the flag: a round begins its flight.
		# Every creator clears `0x004FE63C` **before** it allocates -- the top
		# of `0x0042A930` is the write, ahead of its first `aGetMemory` -- so
		# a full pool leaves the flag down and the engine waits its hundred
		# frames. That is reproduced: the wait is only cut short when nothing
		# was made for a reason the engine could not have had, which is a
		# computed kind the switch does not name or a model this world set
		# does not carry. Both are refusals of the remake's own, and without
		# this the sequence burns `WAIT_FRAMES` of dead screen per shot with
		# the computer's replay held behind it.
		var waits: bool = ShotSequence.waits_for_projectile(weapon)
		main._fx.set_arrived(not waits)
		var made: int = main._triggers.muzzle(weapon, main._muzzle_of(sx, sy),
			main._muzzle_of(tx, ty))
		if waits and made == 0 and main._fx.live() < BlobPool.SLOTS:
			main._fx.set_arrived(true)

	func impact(weapon: int, tx: int, ty: int) -> void:
		if main._triggers != null:
			var _made: int = main._triggers.impact(weapon, main._muzzle_of(tx, ty))

	func pool_arrived() -> bool:
		return main._fx == null or main._fx.arrived

	func pool_live() -> int:
		return 0 if main._fx == null else main._fx.live()

	func clear_arrived() -> void:
		if main._fx != null:
			main._fx.set_arrived(false)

	func clear_pool() -> void:
		if main._fx != null:
			main._fx.clear()

	func pool_first() -> Vector3i:
		if main._fx == null:
			return Vector3i.ZERO
		for blob: Blob in main._fx.blobs():
			return Vector3i(blob.x, blob.y, blob.z)
		return Vector3i.ZERO

	func hide_unit(slot: int) -> void:
		if main._units != null:
			var _was: bool = main._units.hide_now(slot)

	func suppress_unit(slot: int) -> void:
		if main._units != null:
			main._units.suppress(slot)

	func show_unit(slot: int) -> void:
		if main._units != null:
			main._units.reveal(slot)

	func spawn_program(creator: String, args: PackedInt32Array) -> void:
		if main._fx == null or main.world == null:
			return
		_run_program(creator, args, main._death_inputs(args))

	func spawn_at(creator: String, at: Vector3i,
			extra: PackedInt32Array = PackedInt32Array()) -> void:
		if main._fx == null or main.world == null:
			return
		var args: PackedInt32Array = PackedInt32Array([at.x, at.y, at.z])
		args.append_array(extra)
		_run_program(creator, args, main._position_inputs())

	func _run_program(creator: String, args: PackedInt32Array,
			inputs: BlobPrograms.Inputs) -> void:
		var pool: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
		var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
			main._fx.hooks().rng.seed if main._fx.hooks().rng.seed != 0.0 else 1.0)
		if not BlobPrograms.run(creator, pool, draws, args, inputs):
			return
		# The creator's own write over the *arrived* flag (docs/42 section
		# 4.6). Only the two a set piece runs carry it; the three weapon
		# projectiles that write the same zero are modelled at the muzzle
		# instead, and everything else leaves the flag alone.
		if pool.clears_arrived:
			main._fx.set_arrived(false)
		# The program drew from the pool's own generator, which is what the
		# arms will keep drawing from: one stream, as `aRandom2` is.
		main._fx.hooks().rng.randomize_seed(draws.rng.seed)
		var _made: int = BlobPrograms.spawn_into(main._fx, pool.records)

	func object_of(slot: int) -> Vector3i:
		return Vector3i.ZERO if main._units == null else main._units.drawn_position(slot)

	func cell_object(x: int, y: int) -> Vector3i:
		if main.world == null or not main.world.state.in_bounds(x, y):
			return Vector3i.ZERO
		return CameraRig.cell_object(x, y,
			main.world.state.height_at(main.world.state.index_of(x, y)))

	func unit_height(slot: int) -> int:
		if main.world == null:
			return 0
		var view: Dictionary = main.world.unit_view(slot)
		if view.is_empty():
			return 0
		return main.world.unit_types().body_height_world(
			DictRead.as_int(view["type_id"]))

	func camera_eye() -> Vector3i:
		return Vector3i.ZERO if main._rig == null else main._rig.eye()

	func camera_target() -> Vector3i:
		return Vector3i.ZERO if main._rig == null else main._rig.target()

	func fly(eye: Vector3i, target: Vector3i) -> int:
		return 0 if main._rig == null else main._rig.fly(eye, target)

	func set_camera(eye: Vector3i, target: Vector3i) -> void:
		if main._rig != null:
			main._rig.set_now(eye, target)

	func set_camera_target(target: Vector3i) -> void:
		if main._rig != null:
			main._rig.set_target_now(target)

	func rotate(v: Vector3i, angles: Vector3i) -> Vector3i:
		return v if main._eng3d == null else main._eng3d.rotate(v, angles)

	func orient(from: Vector3i, at: Vector3i) -> Vector2i:
		return Vector2i.ZERO if main._eng3d == null else main._eng3d.orient(from, at)

	func draw2(base: int, span: int) -> int:
		if main._fx == null:
			return base
		return main._fx.hooks().rng.draw(base, span)

	func place_body(slot: int, at: Vector3i) -> void:
		if main._units != null:
			var _placed: bool = main._units.place_at(slot, at)

	func turn_body(slot: int, yaw: int) -> void:
		if main._units != null:
			var _turned: bool = main._units.turn_to(slot, yaw)

	func settle_body(slot: int) -> void:
		if main._units != null:
			var _settled: bool = main._units.settle(slot)

	func set_centred_caption(text: String) -> void:
		if main._texts != null:
			main._texts.set_centred_caption(text)
