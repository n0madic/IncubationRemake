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
## `[` / `]` step through them at run time in a debug build.
## `_C_140` is the mission this stage plays: the first one whose squad, aliens
## and win conditions are all in the `.lev`, so it can be won without the
## campaign layer (docs/94).
const DEFAULT_MISSION: String = "_C_140"
const MISSION_ARG: String = "--mission="
## `--campaign=N` -- start chain N and go straight to its map, past the menu.
## The campaign's own equivalent of `--mission=`, and a supported way in
## rather than a side effect (docs/92 section 7.15 S5).
const CAMPAIGN_ARG: String = "--campaign="
## `--sequence=N` -- play logical sequence N full screen from a bare launch,
## with no campaign behind it: how a cutscene is photographed and compared
## (docs/92 section 7.19). The screen exits to the shell's menu.
const SEQUENCE_ARG: String = "--sequence="
## `--cheats=god,ammo` -- turn switches on before the first mission is built.
## The way a level is actually walked: the hidden code line ([CheatEntry]) is
## for a session already in progress.
const CHEATS_ARG: String = "--cheats="
## `--credits` -- open the credits roll straight from a bare launch, with no
## campaign behind it and nothing to win first (docs/101 section 14). The
## roll is three minutes of moving text and the only way into it in the game
## is to finish a chain, so photographing it or watching it move needed four
## debugging commands and a twenty-five second wait. *Back* leaves for the
## menu, exactly as it does after an ending.
const CREDITS_ARG: String = "--credits"
## `--language=Russian` -- which of the cache's languages to read, over the
## settings file and under the restart's own choice (docs/92 section 7.6).
const LANGUAGE_ARG: String = "--language="
## Where a language switch parks the choice across the scene reload, on the
## root [Window]'s metadata: it is the one node that survives
## `reload_current_scene`. Read once at boot and cleared.
const LANGUAGE_META: StringName = &"incubation_language"
## What [method shell_entry] answers.
const SHELL_SPLASH: String = "splash"
const SHELL_MENU: String = "menu"
## What [method boot_choice] answers.
const BOOT_MISSION: String = "mission"
const BOOT_CAMPAIGN: String = "campaign"
const BOOT_SHELL: String = "shell"
const BOOT_SEQUENCE: String = "sequence"
const BOOT_CREDITS: String = "credits"
## What [method show_campaign_screen] answers `credits` with: the roll, raised
## without a campaign. A debugging entry past the two endings, the way
## `--mission=` is one past the campaign.
const SCREEN_CREDITS: String = "credits"
## The seven logical ids `aCreateSeqPlayer`'s compressed switch accepts
## (docs/41 section 2). Here as a constant so the command line is checked
## without a cache: the manifest carries the same seven.
const SEQUENCE_IDS: Array[int] = [0, 1, 2, 3, 7, 14, 15]
## The logo hold when the cache has no front-end document: `aGameIntro`'s
## own 1500 ms (`0x0044BCF1`).
const SplashScreen_LOGO_MS: int = 1500
## The pool tag the briefing's voice-over plays under, so leaving the page
## stops it and nothing else.
const VOICE_TAG: String = "briefing_voice"
## The upgrade base's arrival flight, `0x00417000` read whole (docs/27
## section 2.7). It was once a constant 20 units a frame; 20 is only what the
## **first** frame steps, and the law is an exponential approach:
##
## * the flight is limited to **20 frames a second** -- the front end's own
##   frame function `0x0040b6f0` ends on `0x0047f2e0(10, 20)`, which busy-waits
##   until `1000 / 20` ms have passed;
## * the target velocity is `_ftol(direction * 800)` where the direction is
##   normalised so that the **larger** of its two horizontal components is one
##   (`0x0046d400`), and its vertical is `((goal.z >> 3) - (eye.z >> 3))`
##   over the horizontal distance **taken in eighths as well**, so the two
##   cancel and the vertical is the plain gradient;
## * the velocity approaches that target by `(target - velocity) / n` with `n`
##   starting at **40** on every leg and falling by one a frame to a floor of
##   **5**, so the eye accelerates from 20 units a frame toward 800 and the
##   whole flight lasts three to thirteen seconds;
## * a leg ends when the eye is within **3200** of its waypoint on every axis;
## * on the **last** leg only, `800 * remaining / leg` is a countdown and the
##   flight lands when it falls under **80** -- a tenth of the leg -- which is
##   why the eye comes to rest *near* the last waypoint rather than on it;
## * `0x004fcbdc`, set by any key or click, lands it early.
const FLY_FPS: float = 20.0
const FLY_SPEED: int = 800
const FLY_SMOOTH_START: int = 40
const FLY_SMOOTH_FLOOR: int = 5
const FLY_ARRIVAL: int = 3200
const FLY_LANDED_SHARE: int = 80
const FLY_DIRECTION_SHIFT: int = 3
## Why a sequence is playing, which decides what follows it.
const SEQUENCE_DEBUG: String = "debug"
const SEQUENCE_DIALOGUE: String = "dialogue"
## The self-contained Android package has no first-run conversion step: its
## verified cache is read directly from the installed PCK. Keeping this apart
## from `generated/` prevents a desktop export made after an Android build from
## silently shipping test fixtures.
const ANDROID_CACHE: String = "res://android_payload/cache"
## Where a development run finds the same bytes production reads from `user://`.
const DEV_CACHE: String = "res://generated/cache"

var world: World = null
## **The picture's own world, one command behind the truth.**
##
## `core` resolves a whole command -- and the whole computer turn -- before it
## returns, so [member world] always stands at the *end* of the last one. This
## is a clone of it, advanced one event delta at a time at the moment each
## animation reaches the change it is drawing ([EventJournal]). Every reader
## of the picture -- the bodies, the fog, the terrain, the interface, the
## radar, the click pick and the agent's snapshot -- reads this; [member world]
## is read to submit a command and to ask whether one is allowed.
##
## The standing check is that the two hashes agree once the last delta has
## landed; [method _check_mirror] says so at the drain and resynchronises
## rather than drawing a world nobody can name.
var _shown: World = null
## What the picture may see, over [member _shown]. See [PictureFog].
var _fog: PictureFog = PictureFog.new()
## How many times the mirror had to be resynchronised because a delta did not
## carry everything. Zero is the contract; the agent's snapshot reports it.
var _desyncs: int = 0
## What the player chose, read once at start-up and written by the options
## screen. Never `null` after [method _ready]: a run with no file on disk uses
## the defaults rather than having no settings at all.
var settings: GameSettings = GameSettings.new()
var _touch: TouchInputController = null
## The level tester's switches, held **here** rather than on a world so they
## survive a mission change, a load and a return to the shell. Every world
## [method _build] makes is handed this same object; the picture's mirror
## takes a copy of it ([method World.clone]). See [Cheats].
var cheats: Cheats = Cheats.new()
## The hidden code line, and the reason it is a member: it owns the keyboard
## between the key that opens it and the one that submits.
var _cheat_entry: CheatEntry = CheatEntry.new()
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
## `Events.txt` -- what a pickup says, and which action point says it
## (docs/26 section 3). Empty when the cache predates the document.
var _info: InfoText = null
## The magnifying glass: `[0x005106CC]`, the mode event 13 toggles
## (docs/43 section 5.2). While it is on, a click on a visible alien opens
## that type's page out of `Data.txt` and does nothing else at all.
## `0x00450C2D` clears it when a mission is built, and so does [method _clear].
var _magnifier: bool = false

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
## The bodies the Upgrade Menu turns, opened once per campaign map.
var _campaign_bodies: CharismaLibrary = null
## The four shipped faces, by `fntID`. Cleared when the font option changes.
var _faces: Array[FontFile] = []
var _backdrop_world: World = null
var _backdrop_rig: CameraRig = null
var _backdrop_mission: String = ""
## An upgrade base's own marines, docs/27 section 2.7.1. Null behind the two
## chain maps, which place nobody.
var _backdrop_bodies: BackdropBodies = null
## The draw for each marine's starting clip time. The original's is
## `aRandom2`, seeded from `GetTickCount` -- cosmetic, outside every hash, and
## deliberately different every run ([constant BackdropBodies.START_MAX]).
var _backdrop_rng: RandomNumberGenerator = RandomNumberGenerator.new()
## The backdrop's own camera as `[eye, target]`, or empty for the chain map.
## See [method _read_camera_path].
var _backdrop_view: Array[Vector3i] = []
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
## The upgrade base's fly-in (docs/27 section 2.7, `0x00417000`): every
## `mode 1` waypoint in script order, and which one the eye is heading for.
## Empty for the chain map, whose eye comes from its location preset. Zero
## when the flight has come to rest on the last waypoint.
var _backdrop_waypoints: Array[Vector3i] = []
var _fly_next: int = 0
## The flight's own state: the eye's velocity, the smoothing divisor `n`, the
## eye the current leg started from, whether the next step is the flight's
## first, whether the landing countdown has run out, the 20 fps accumulator
## and what to raise once the eye has come to rest.
var _fly_velocity: Vector3i = Vector3i.ZERO
var _fly_smooth: int = FLY_SMOOTH_START
var _fly_leg_from: Vector3i = Vector3i.ZERO
var _fly_first: bool = true
var _fly_landed: bool = false
var _fly_clock: float = 0.0
var _fly_then: Callable = Callable()
## `tables/frontend.json` and `tables/sequences.json` -- the holds, the CD
## programs and the cutscene manifest (docs/92 section 7.19). Empty on a cache
## published before 0.29.0, and every reader falls back to "no such step".
var _frontend: Dictionary = {}
var _sequence_manifest: Dictionary = {}
## The cutscene being played, and why -- one of [CampaignHost]'s `OPENING_*`
## kinds, [constant SEQUENCE_DIALOGUE] or [constant SEQUENCE_DEBUG].
var _sequence: SequencePlayer = null
var _sequence_kind: String = ""
## The three `Sleep` holds of the original's front end, as a countdown in
## [method _process] rather than a timer, so the agent's `wait` sees them and
## a suite can step them. `_hold_then` runs when the countdown reaches zero.
var _hold_left: float = 0.0
var _hold_then: Callable = Callable()
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
## Whether the last overlay refresh was the far view, so a camera crossing
## the zoom gate redraws it.
var _far_drawn: bool = false
## Which mission each interface save slot holds, so the two undo buttons and
## *Recall position* are not lit for another mission's autosave. See
## [method _slot_holds_this_mission].
var _slot_owner: Dictionary[int, String] = {}
## Autosave slots waiting for the sequence queue to drain -- see
## [method _autosave].
var _autosaves_pending: PackedInt32Array = PackedInt32Array()
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
## How far from a cell's centre a click's ray may land and still count as a
## click on the body standing there, in Godot units -- a cell is two of them
## across. The remake's own tolerance: the engine picks over drawn objects.
const PICK_RADIUS: float = 1.2
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
## A release-visible startup failure. This is deliberately separate from the
## developer status line: hiding diagnostics must never turn a refused cache
## into an unexplained black window.
var _fatal_status: Label = null
## Godot's build kind, captured once so every on-screen and keyboard debugging
## surface has the same boundary. Tests replace it to exercise both sides;
## production code never promotes a release build at run time.
var _debug_build: bool = OS.is_debug_build()
## The second line of the developer status: whatever the last caller of
## [method _refresh_status] gave it. Kept so a **redraw** can put it back --
## a caller with something to say passes it, and one with nothing clears it.
var _status_note: String = ""
## What the command now being played back should say when it drains. The note
## is decided where the command was given and shown when the picture has
## caught up with it, which is where [method _after_command] now runs.
var _command_note: String = ""
## Whether the report panel is being held down while the picture that ended
## the mission is still on screen ([method _check_mission_end]).
var _result_held: bool = false
## The local battle currently running, or empty outside Instant Action. The
## CampaignState remains alive so the existing save container can persist the
## session; this latch keeps its result out of the campaign map/debriefing flow.
var _instant_action_mission: String = ""
## Set when the squad ran out of movement points, cleared when the turn is
## handed over ([method _auto_end_turn_wanted]).
var _auto_end_pending: bool = false
## The eye's offset from the target, and the view mode, as the player had them
## when they ended the turn ([method _restore_camera_on]).
var _camera_offset_before_turn: Vector3i = Vector3i.ZERO
var _camera_mode_before_turn: CameraRig.View = CameraRig.View.UNIT
var _hud: MissionHud = null
var _strings: Localization = null
var _selected: int = -1
## What was selected when the player ended their turn, for [method
## _resume_selection] to hand back. The engine keeps the selection in a global
## across the whole computer turn (`[0x005162F0]`); this is that global,
## carried over the window in which the remake has the interface down.
var _selection_before_turn: int = -1
## The place interface's selected pool soldier while the mission is on turn
## 0 -- `[0x514064]`, docs/43 section 5.5 -- as a **roster slot**, or
## [constant Roster.NO_SLOT]. Interface state and not the campaign's: the
## original keeps it beside the pool it indexes and clears it on the
## hand-over (`0x0041DA20` cmd 2).
var _deploy_slot: int = Roster.NO_SLOT
var _cache_dir: String = ""
## Which language every language-dependent file is read for (docs/92
## section 7.6). Neutral-only readers -- missions, geometry, textures, the
## tables -- keep reading [member _cache_dir] directly.
var _paths: CachePaths = null
## `tables/balance.json` with the chosen language's names overlaid, read once
## and handed to every world and screen that names a unit or an item.
var _balance: Dictionary = {}
var _geometry: Dictionary = {}
var _textures: Dictionary = {}
## The computer's turn, played back one event at a time. `core` decided the
## whole thing before this exists; the playback only shows it.
var _playback: EventPlayback = EventPlayback.new()
var _ai_note: String = ""

## The fifth slice's two presentation layers. Both are `game`'s alone: `core`
## emits the events they read and knows about neither, which is docs/28
## section 8's structural fact -- effects are driven by the animation
## routines, and the simulation only calls those.
var _audio: AudioSystem = null
## The voices of docs/28 section 4.3. Its cursors and its index generator are
## the mission's, so it lives beside [member _audio] and not inside it.
var _speech: SpeechPlayer = null
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
## The last `MoveUnit` outcome the picture was handed, by whichever seam --
## the player's walk or jump, or the computer's replay -- as `ran`, the
## names of its events and a running `count` of outcomes presented. The
## agent snapshot's `picture.script`: a driven session has no other way to
## see that a hook fired for a move whose effect is invisible, which is
## every `_C_131` jump, and the count is what tells a computer turn's
## hooks apart from the player's own when both answer `ran` and nothing.
var _last_script: Dictionary = {}
## True once a close or a restart has been accepted, so a second one is
## ignored while the audio server is being given its frames -- and so no
## option, shell choice or key is acted on in that window.
var _leaving: bool = false
## A close asked for while a restart is already leaving: the restart quits
## instead of reloading, so a window close is never turned into a reload.
var _quit_pending: bool = false
## What [method _restart] calls once the audio is down and the agent's reply
## has left: `reload_current_scene` by default, a seam so a suite can count
## the call without reloading the tree under itself.
var reload_hook: Callable = Callable()
## The language [method _restart] was asked for, kept so a suite can read it
## back where no root [Window] exists to park it on.
var restart_language: String = ""
## Slot -> the walk cue that slot's type set up, kept for as long as the walk
## lasts so every step of one walk sounds the same.
var _footstep_cues: Dictionary[int, Dictionary] = {}
## Whether a delta has landed on the mirror since the picture was last built
## from it. The rebuild is deferred to [method _flush_picture] -- once per
## frame, or at the moment a presenter needs the picture current -- because
## the quiet events between two shown ones land several deltas in one frame
## and a full rebuild per delta was most of the cost of a command.
var _picture_stale: bool = false
## An overlay refresh asked for while a set piece was drawing, owed to the
## drain (see [method _refresh_overlay]).
var _overlay_stale: bool = false
## A terrain repaint asked for while a set piece was drawing, owed to the
## drain the same way (see [method _redraw_terrain]). It is a flag of its own
## and not [member _picture_stale] because a presenter that lands its delta
## at a moment inside its own sequence ([method _land_current_delta]) clears
## that one while the terrain half is still deferred: without this the owed
## repaint was simply lost, and a mine that went off under a walker kept its
## model and its tint on the cell until some later delta happened to ask for
## another repaint.
var _terrain_stale: bool = false
## Whether the playback on the go is the computer's turn, which is what
## [method end_turn] started, as against a player's own command. The two
## finish differently: only the turn hands the selection back.
var _playing_turn: bool = false
## Whether the hand-over being drawn actually gave the computer a turn to
## take -- [member TurnResult.ai_result], which is null when the rotation
## reached the computer's seat with the planner gated off. See
## [method _watching_the_computer], the one thing that reads it.
var _computer_played: bool = true


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
## The `Use` results that are staged as set pieces of their own (docs/42
## section 8.3): the lever's handle and the supply box's lid. The thirteen
## pickup arms all reach `0x00410780`, `message_only` included.
const LEVER_USE_KIND: String = "lever"
const PICKUP_USE_KINDS: Array[String] = ["full_munition", "equipment_points",
	"weapon_skills", "condition", "technical", "equipment", "class",
	"message_only"]
## The tag every spoken line takes, so the next one can end it: the original
## keeps speech in one buffer and kills it before the next name (docs/28 4.3).
const SPEECH_TAG: String = "speech"
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
## `CreateCameraPath`, which is the whole of an upgrade base's `INIT MAP`
## (docs/27 section 2.7). Mode 0 is the look-at target and mode 1 appends a
## waypoint; both are stored shifted left by four, the file-unit-to-world-unit
## factor of docs/30 section 2.5.
const CREATE_CAMERA_PATH: String = "create_camera_path"
const CAMERA_PATH_SCALE: int = 16
const CAMERA_PATH_TARGET_MODE: int = 0
const CAMERA_PATH_WAYPOINT_MODE: int = 1
## What the test build's own window says while it is not the game.
const TEST_CAPTION: String = \
	"Incubation - Remake -- the test harness, not the game\n\n" \
	+ "%d / %d suites -- running %s\n\nabout two minutes, then it quits"


func _bundled_cache_dir() -> String:
	# Prefer the package payload so a local Android export exercises precisely
	# the bytes an installed app reads. Editor fixtures remain the fallback for
	# desktop development and tests.
	# **The manifest, not the directory.** An interrupted `make android-cache`
	# leaves the payload directory standing with nothing in it, and choosing it
	# on that alone made a plain desktop run die in [method CacheLoader.verify]
	# with the intact fixtures sitting beside it.
	for candidate: String in [ANDROID_CACHE, DEV_CACHE]:
		if FileAccess.file_exists(candidate + "/manifest.json"):
			return candidate
	return ""


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
	# Android's Back has its own automatic-quit gate, separate from window close.
	get_tree().quit_on_go_back = false
	_install_debug_status()

	# **The published cache is verified exactly once, inside
	# [method CacheLoader.open_active].**  That call reads and SHA-256s every
	# file the manifest declares, and this used to re-read the manifest and
	# sweep the whole inventory a second time straight after it -- two full
	# passes over 100 MB for a campaign publish, on every start-up, for one
	# answer.  The manifest `open_active` already parsed is the same document.
	var opened: Dictionary = CacheLoader.open_active()
	var manifest: Dictionary = DictRead.as_dict(opened["manifest"])
	if DictRead.as_bool(opened["ok"]):
		_cache_dir = DictRead.as_string(opened["cache_dir"])
	else:
		var fallback_cache: String = _bundled_cache_dir()
		if fallback_cache.is_empty():
			_fail(DictRead.as_string(opened["reason"]))
			return
		# Neither a packaged cache nor the development tree has `active.json`, so
		# `open_active` cannot reach them. This branch always validates the
		# manifest before any loader reads a file from either location.
		_cache_dir = fallback_cache
		manifest = CacheLoader.read_json(
			_cache_dir + "/" + CacheLoader.MANIFEST_NAME)
		var problems: PackedStringArray = CacheLoader.verify(_cache_dir,
			manifest)
		if not problems.is_empty():
			_fail("cache refused: " + ", ".join(problems))
			return
	_missions = _missions_in(manifest)
	if _missions.is_empty():
		_fail("the cache at %s contains no missions" % _cache_dir)
		return
	# **Before the first thing that reads one.** `interface_font()` is a
	# setting, and reading it below while the file was still unread gave the
	# HUD the default face and every plate built afterwards the chosen one --
	# the exact inconsistency `interface_font()` exists to prevent. The
	# language is a setting too, and every loader from here on reads through
	# it, so the file comes first of all.
	var _had_settings: bool = settings.load_from_disk()
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var wanted_language: String = _language_choice(args, settings.language)
	_paths = CachePaths.create(_cache_dir, manifest, wanted_language)
	if _paths.fallback:
		push_warning("the cache has no language %s; reading %s"
			% [wanted_language, _paths.language])
	# The strings come before anything that says one. docs/92 section 7.6: a
	# localization seam retrofitted later means finding every literal.
	_strings = Localization.from_cache(_paths)
	_balance = _paths.apply_balance_names(
		CacheLoader.read_json(_cache_dir + "/tables/balance.json"))
	# docs/60 -- the game's own bitmap font, the 17 px one. A cache built by an
	# older converter has no fonts and the HUD stays on Godot's default.
	var font: FontFile = interface_font()
	_texts = FloatingTexts.new()
	_texts.use_font(font)
	add_child(_texts)
	_shot_host = MainShotHost.new(self)
	# The campaign layer. `--mission=` still enters a mission directly, past
	# the campaign, which is what it has always been for; the host is what the
	# campaign flow drives, and the agent server reaches it by name.
	_art = Art.open(_paths)
	_info = InfoText.load_from(_paths)
	# The battle interface (docs/43): the plate, the columns, the pad, the
	# panel and the radar, drawn on the shipped art and captioned from
	# `Txtmod_h`. Its one plate face is the `font_0` bitmap font (docs/43 D7).
	_hud = MissionHud.new()
	_hud.name = "MissionHud"
	_hud.setup(_art, _strings, font,
		GameFont.load_from(_paths, MissionHud.TEXT_FONT),
		GameFont.load_from(_paths, MissionHud.SMALL_FONT), _paths, _balance)
	_hud.event.connect(_on_hud_event)
	_hud.command.connect(_on_pad_command)
	_hud.panel_cycled.connect(func(step: int) -> void:
		var _cycled: bool = cycle_deploy_slot(step))
	# The two hover ticks (docs/28 section 2.5): `click_1` when the pointer
	# lands on a lit column slot (`fcn.004518E0`) or pad socket
	# (`fcn.004723E0`). The third tick, over a legal cell while a command is
	# armed, is [method _update_hover]'s.
	_hud.column_hovered.connect(func() -> void:
		_play_interface(AudioTables.INTERFACE_COLUMN_HOVER))
	_hud.pad_hovered.connect(func() -> void:
		_play_interface(AudioTables.INTERFACE_PAD_HOVER))
	_hud.ring.record_pressed.connect(func(record: int) -> void:
		var _chosen: bool = choose_ring_record(record))
	_hud.radar_rescaled.connect(func(_fields: int) -> void: _refresh_status())
	add_child(_hud)
	_touch = TouchInputController.new()
	_touch.host = self
	add_child(_touch)
	get_viewport().size_changed.connect(_on_canvas_resized)
	campaign = CampaignHost.create(_cache_dir, _balance, _strings)
	_frontend = CacheLoader.read_json(_cache_dir + "/tables/frontend.json")
	_sequence_manifest = CacheLoader.read_json(
		_cache_dir + "/tables/sequences.json")
	_boot()
	_start_agent()


## Installs the developer status overlay only when this is a debug build.
## Keeping the gate at creation means a release has no hidden label for later
## refreshes, failures or cheat reports to accidentally reveal.
func _install_debug_status() -> void:
	if not _debug_build:
		return
	_status = Label.new()
	_status.name = "DebugStatus"
	# Below the HUD, which owns the top of the screen.
	_status.position = Vector2(12.0, STATUS_FALLBACK_Y)
	# The developer line wraps too; [method _refresh_status] then puts it
	# under whatever height the HUD's own wrapped hints came to. It is
	# smaller than the HUD: it is a diagnostic, not something to play by.
	_status.size = Vector2(CampaignScreen.PLATE_SIZE.x - 24.0, 0.0)
	_status.add_theme_font_size_override("font_size", STATUS_FONT_SIZE)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "DebugOverlay"
	layer.add_child(_status)
	add_child(layer)


## Shows the one error state that can exist before the shell and localization
## have loaded. Unlike [member _status], this is player-facing in every build.
func _show_fatal_error(reason: String) -> void:
	if _fatal_status == null:
		_fatal_status = Label.new()
		_fatal_status.name = "FatalError"
		_fatal_status.position = Vector2(40.0, 140.0)
		_fatal_status.size = Vector2(560.0, 200.0)
		_fatal_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_fatal_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_fatal_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_fatal_status.add_theme_font_size_override("font_size", 18)
		var layer: CanvasLayer = CanvasLayer.new()
		layer.name = "FatalErrorOverlay"
		layer.add_child(_fatal_status)
		add_child(layer)
	_fatal_status.text = "Incubation could not start.\n\n" + reason


## The control server, when the command line asks for one (docs/92 section
## 7.16).
##
## Inert without `--agent-port=`, and bound to the loopback address only: it
## ships with the game, so what keeps it from being a hole is that nothing is
## listening unless somebody on this machine asked for it. A port that cannot
## be bound is a warning and not a refusal to start -- a game must never fail
## to come up because a socket was taken.
func _start_agent() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	var port: int = AgentBridge.port_from_args(args)
	if port == 0:
		var refused: String = AgentBridge.port_warning(args)
		if refused != "":
			push_warning(refused)
		return
	var bridge: AgentBridge = AgentBridge.new()
	bridge.name = "AgentBridge"
	# After `SliceMain._process`, so a snapshot read in this frame is this
	# frame's and not the last one's.
	bridge.process_priority = AgentBridge.PRIORITY
	add_child(bridge)
	var opened: Error = bridge.begin(self, port,
		AgentBridge.dir_from_args(args))
	if opened != OK:
		push_warning("agent: cannot listen on 127.0.0.1:%d (%d)"
			% [port, opened])
		bridge.queue_free()


## The three ways in, and all three stay open (docs/92 section 7.15 S5).
##
## `--mission=NAME` builds a mission **immediately** and never raises the
## shell, which is what it has always done and what `shot.gd`, the agent
## server's scenarios and every screenshot depend on. `--campaign=N` is the campaign's equivalent:
## the chain starts and its map comes up, past the menu. With neither, the
## shell opens -- which is the whole of this slice.
func _boot() -> void:
	var args: PackedStringArray = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	# **Before the mission is built**, so a world never exists with the
	# switches off that the command line asked to have on.
	for line: String in apply_cheat_args(args, cheats):
		push_warning(line)
	var choice: Dictionary = boot_choice(args, _missions, DEFAULT_MISSION)
	for line: String in DictRead.to_strings(choice["warnings"]):
		push_warning(line)
	match DictRead.as_string(choice["kind"]):
		BOOT_MISSION:
			_build(DictRead.as_string(choice["mission"]))
			# Past the campaign, so there is no pool and nothing to place:
			# `0x0041A073`'s silent arm (docs/98 section 12).
			_skip_deployment_turn()
		BOOT_CAMPAIGN:
			var _started: CampaignState = campaign.start_new(
				DictRead.as_int(choice["campaign"]), settings.difficulty)
			var _map: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_MAP)
		BOOT_CREDITS:
			var _roll: CampaignScreen = _show_credits()
		BOOT_SEQUENCE:
			# The fallback is the `--campaign=` arm's: a cache with no
			# cutscenes in it answers `null` here, and without this the game
			# came up with no screen at all -- a black window with no way out.
			# `boot_choice` cannot catch it, because whether a logical id
			# *plays* is the cache's answer and not the command line's.
			if play_sequence(DictRead.as_int(choice["sequence"]), true,
					SEQUENCE_DEBUG) == null:
				var _fallback: CampaignScreen = open_shell(
					ShellHost.SCREEN_MENU)
				_play_frontend_program("menu")
		_:
			# `aGameIntro` `0x0044BCA0`: the logo, the hold, the title plate
			# until a key, then the menu (docs/92 section 7.19) -- on the
			# first launch. See [method shell_entry].
			if shell_entry(settings.seen_splash) == SHELL_MENU:
				var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)
				_play_frontend_program("menu")
			else:
				_show_splash(SplashScreen.STAGE_LOGO)
				hold(hold_ms("logo", SplashScreen_LOGO_MS),
					_show_splash.bind(SplashScreen.STAGE_TITLE))


## Where a run with no argument opens: the splash, or the menu.
##
## **The original always plays `aGameIntro`** -- `0x0044BCA0` shows the logo,
## holds 1500 ms, puts the title plate up and waits for a key or a click on
## *Start Game*, every launch. The wait is the part that costs something: the
## two plates are a second and a half, the click is unbounded and the player
## pays it every time they start the game. So the remake shows the sequence
## once and remembers ([member GameSettings.seen_splash]) -- docs/92
## section 7.19's I19.
##
## **Static and pure for the same reason [method boot_choice] is**: which
## entry a build takes is a decision a suite can pin, and this one is
## otherwise only reachable by deleting a file and launching a window.
static func shell_entry(seen_splash: bool) -> String:
	return SHELL_MENU if seen_splash else SHELL_SPLASH


## Which of the three entries the command line names.
##
## **Static and pure**, so the decision is checked by a suite rather than only
## by hand: a build's arguments cannot be injected, and "does `--mission=`
## still bypass the shell" is exactly the kind of thing that would otherwise
## be verified once and then quietly broken (docs/92 section 7.15 S5).
##
## Returns `{"kind": String, "mission": String, "campaign": int,
## "sequence": int, "warnings": PackedStringArray}`. An unknown mission name
## still falls back to *fallback* and still warns -- the cache is the authority
## on what exists -- and an unknown chain or an unknown logical sequence id
## opens the shell rather than starting nothing.
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
				"sequence": -1, "warnings": warnings}
		if arg.begins_with(CAMPAIGN_ARG):
			var chain: int = arg.substr(CAMPAIGN_ARG.length()).to_int()
			if not CampaignState.FIRST_MISSION.has(chain):
				warnings.append("no campaign %d; opening the menu" % chain)
				return {"kind": BOOT_SHELL, "mission": "", "campaign": 0,
					"sequence": -1, "warnings": warnings}
			return {"kind": BOOT_CAMPAIGN, "mission": "", "campaign": chain,
				"sequence": -1, "warnings": warnings}
		if arg == CREDITS_ARG:
			return {"kind": BOOT_CREDITS, "mission": "", "campaign": 0,
				"sequence": -1, "warnings": warnings}
		if arg.begins_with(SEQUENCE_ARG):
			var id: int = arg.substr(SEQUENCE_ARG.length()).to_int()
			if not SEQUENCE_IDS.has(id):
				warnings.append("no sequence %d; opening the menu" % id)
				return {"kind": BOOT_SHELL, "mission": "", "campaign": 0,
					"sequence": -1, "warnings": warnings}
			return {"kind": BOOT_SEQUENCE, "mission": "", "campaign": 0,
				"sequence": id, "warnings": warnings}
	return {"kind": BOOT_SHELL, "mission": "", "campaign": 0, "sequence": -1,
		"warnings": warnings}


## `--language=NAME` on the command line, or `""` when absent. The last one
## wins, as every other flag here does.
##
## **Static and pure, like [method boot_choice]**: a launch flag that quietly
## stopped working is exactly the kind of thing that is verified once by hand
## and then broken.
static func language_from_args(args: PackedStringArray) -> String:
	var chosen: String = ""
	for arg: String in args:
		if arg.begins_with(LANGUAGE_ARG):
			chosen = arg.substr(LANGUAGE_ARG.length())
	return chosen


## Which language to open in, by precedence: the restart's own choice parked
## on the root [Window] (consumed here), then `--language=`, then the settings
## file, then the cache's base language (an empty answer).
func _language_choice(args: PackedStringArray, from_settings: String) -> String:
	var root: Window = get_tree().root if is_inside_tree() else null
	if root != null and root.has_meta(LANGUAGE_META):
		var parked: String = DictRead.as_string(root.get_meta(LANGUAGE_META))
		root.remove_meta(LANGUAGE_META)
		if parked != "":
			return parked
	var from_args: String = language_from_args(args)
	if from_args != "":
		return from_args
	return from_settings


## `--cheats=god,ammo` -- turn the named switches on in *into*, and answer the
## warnings a caller should print.
##
## **Static, like [method boot_choice], and for the same reason**: a launch
## flag that quietly stopped working is exactly the kind of thing that is
## verified once by hand and then broken. The last `--cheats=` on the line
## wins, so a wrapper script can append one over another; a name outside
## [constant Cheats.NAMES] warns and is skipped rather than refusing the
## whole flag.
static func apply_cheat_args(args: PackedStringArray,
		into: Cheats) -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if into == null:
		return warnings
	var text: String = ""
	var given: bool = false
	for arg: String in args:
		if arg.begins_with(CHEATS_ARG):
			text = arg.substr(CHEATS_ARG.length())
			given = true
	if not given:
		return warnings
	var parsed: Dictionary = Cheats.parse_list(text)
	for name: String in DictRead.to_strings(parsed["unknown"]):
		warnings.append("no cheat %s; known: %s"
			% [name, ", ".join(Cheats.NAMES)])
	for name: String in DictRead.to_strings(parsed["names"]):
		var _on: bool = into.set_enabled(name, true)
	return warnings


## One key press while the hidden code line has the keyboard ([CheatEntry]).
func _on_cheat_key(key: InputEventKey) -> void:
	if _cheat_entry.feed(key.keycode, key.unicode) == CheatEntry.SUBMITTED:
		var _did: bool = apply_cheat_code(_cheat_entry.code())


## Run one typed code. Answers whether it did anything.
##
## **A code that matches nothing says nothing.** The whole point of the entry
## being hidden is that a player who has not been told it exists cannot
## discover it by pressing keys, so only a code that did something reports.
func apply_cheat_code(code: String) -> bool:
	var found: Dictionary = CheatEntry.resolve(code)
	match DictRead.as_string(found["kind"]):
		CheatEntry.KIND_SWITCH:
			var name: String = DictRead.as_string(found["name"])
			var on: bool = cheats.toggle(name)
			_refresh_status("cheat %s %s" % [name, "on" if on else "off"])
			return true
		CheatEntry.KIND_REPORT:
			var live: PackedStringArray = cheats.active()
			_refresh_status("cheats: %s"
				% ("none" if live.is_empty() else ", ".join(live)))
			return true
		CheatEntry.KIND_NUKE:
			# The one code that writes the world, so it is the one with a
			# gate: under a playback the mirror is mid-replay, and
			# resynchronising it from here would leave `EventPlayback`
			# landing the deltas of a turn that has been overwritten -- the
			# units it just killed would come back. Every other code writes
			# nothing but a switch and is safe at any moment.
			if world == null or _playback.is_running():
				return false
			var killed: int = world.cheat_kill_enemies()
			# The world was written and nothing was marked, so the mirror is
			# resynchronised rather than advanced -- and the bodies, the fog
			# and the radar are all rebuilt from it.
			_refresh_after_deploy()
			_refresh_status("cheat nuke: %d killed" % killed)
			return true
	return false


## The difficulty the next world is built at -- docs/92 section 7.15's S6.
##
## **The saved session is the authority when there is one.** [member
## CampaignState.difficulty] is already inside that object's own digest, for a
## campaign and Instant Action alike. A bare `--mission=` has no state to ask,
## so the settings' default is the whole answer.
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
	if not settings.game_font or _paths == null:
		return null
	return GameFont.load_from(_paths, GAME_FONT)


## The four shipped faces, indexed by `Menu_b.lcl`'s `fntID` column.
##
## Built once and kept: the campaign screens are rebuilt on every click and a
## bitmap font is an atlas plus 224 glyph rectangles. Empty while the readable
## face is chosen, so that option keeps behaving as one font for everything.
func interface_faces() -> Array[FontFile]:
	if not settings.game_font:
		return []
	if _faces.is_empty() and _paths != null:
		for index: int in range(GAME_FACES.size()):
			_faces.append(GameFont.load_from(_paths, GAME_FACES[index]))
	return _faces


## Redraw after a deployment put a unit on the map or took one off it.
##
## `UnitsView.build` frees every unit node and rebuilds from the world, which
## is what a newly placed record needs; the overlay follows because deployment
## rebuilds visibility and the fog it draws is now a different one.
func _refresh_after_deploy() -> void:
	if world == null or _units == null:
		return
	# The terrain overlay is not rebuilt: deployment changes no cell. What it
	# does change is visibility, and that is `UnitsView.build`'s to redraw.
	# **The mirror first**: a placement moves the truth with no delta anybody
	# can replay, and the bodies and the dots below are drawn from the mirror.
	_resync_shown()
	_units.build(shown(), _geometry, _textures, _picture_fog())
	# The ground overlay carries the landing dots (docs/29 section 1.2's
	# states 70..73), on every deployment cell whether or not somebody
	# stands on it -- a dot under a placed soldier is the click that takes
	# him back. It reads the mirror's turn, so a load into a mission in
	# progress draws none.
	_refresh_overlay()
	_refresh_status()



# --- the quick save ----------------------------------------------------------

## `F5` -- write the campaign and, when a mission is up, the mission inside it.
##
## The quick save has a file of its own beside the numbered slots
## (docs/92 section 7.15 S1), so `F5` cannot cost the player a slot they meant
## to keep. The mission blob is [SaveCodec]'s and stays opaque to the
## container, because that codec refuses a blob whose map name is not the
## world's -- right for a mission, wrong for a campaign that outlives one
## (D10).
func quick_save(slot: int = CampaignHost.QUICK_SLOT) -> bool:
	if campaign == null or campaign.state == null:
		_refresh_status("no campaign to save")
		return false
	if _mid_sequence():
		_refresh_status("wait for the sequence to finish")
		return false
	var written: bool = _save_mission_to(slot, world)
	_refresh_status("saved" if written else "save failed")
	return written


## Whether a set piece is half drawn -- the sequence queue is running, or
## the computer's replay that feeds it.
##
## **A save is refused while it is**, and the reason is the original's own
## shape rather than caution: every routine of docs/42 section 8 runs its
## frames inside the command, calling the frame service itself
## (`0x0040B6F0`), so the engine reaches no input and writes no save until
## the bridge has fallen. The remake spreads those frames over real ones,
## which opens a window the original does not have -- and a save taken in it
## would hold a state no `.sav` can: `core` has already dropped the riders
## and flipped the cells, while [method Scenery.remove_objects] has not yet
## run, so the block would come back standing over its own hole. The queue
## is short and ends by itself; refusing is the whole fix, and it is why
## [method Scenery.pose_record] carries no mid-fall pose.
##
## It is **not** [method _picture_busy], which is the wider "is anything
## moving" that gates a command: a walking body and a flying camera change
## nothing a save holds -- [method CameraRig.state] carries the flight's
## goal, not where it has got to -- and the turn's own autosave runs while
## the camera is on its way to the first unit.
func _mid_sequence() -> bool:
	if _playback != null and _playback.is_running():
		return true
	return _sequences != null and _sequences.is_running()


## Write the campaign and `mission_world` into `slot`, stamped now, with the
## scenery's pose record and the camera beside the simulation -- an opened
## hatch, a lowered bridge, a crushed wall's empty cell, and the view the
## player left them under -- so a load shows the mission as it was left
## rather than as the `.lev` authored it (docs/42 section 8.3).
##
## The camera field has been in the header since the first save and was
## written empty until 2026-09-06, so nothing had ever come back through it;
## [method _resume_loaded_mission] is the other half.
##
## *mission_world* is the caller's to choose, and a save taken **from a
## screen** must choose it through [method world_to_save]: `F5` and the turn's
## own autosave are only reachable from inside a mission and hand this the
## world plainly, while the slot screen can be standing over a finished one.
func _save_mission_to(slot: int, mission_world: World,
		name: String = "") -> bool:
	if campaign == null or _mid_sequence():
		return false
	var stamp: Dictionary = CampaignHost.stamp_now()
	var poses: Dictionary = {}
	var camera: Dictionary = {}
	if mission_world != null and _scenery != null:
		poses = _scenery.pose_record()
	if mission_world != null and _rig != null:
		camera = _rig.state()
	var written: bool = campaign.save(mission_world, slot,
		DictRead.as_int(stamp["when"]), DictRead.as_string(stamp["when_text"]),
		poses, camera, name)
	# **Every writer records what it wrote**, not only the autosave. The
	# ownership cache is read once per slot and remembered ([method
	# _slot_holds_this_mission]), so a slot this session wrote and did not
	# record kept whatever header was on disk when the interface first asked
	# -- which left *Recall position* dark right after `F1` had written it,
	# and would have offered *Undo mission* for a mission the player is not
	# in. Found by driving a real build (docs/92 section 7.16), where the
	# button stayed dark after a save that had plainly happened.
	if written and campaign.state != null:
		_slot_owner[slot] = campaign.state.mission
	return written


## What a loaded mission blob leaves for the picture to do: the terrain the
## save changed is redrawn against the authored one [method _build] drew,
## which derives the door's leaves and the lever's handle from the state;
## then the scenery's own poses come back from the save's record; then the
## camera goes back where the save was taken from.
##
## The camera comes **last** and before [method _refresh_after_deploy],
## which rebuilds the bodies and lays no view of its own -- so nothing moves
## it afterwards. An empty record leaves the built mission's own opening
## view, which is what a save written before the field was filled carries.
##
## **The mirror is thrown away first, and that is not housekeeping.** The
## picture reads [method shown] and not [member world] (docs/100), and the
## clone [method _build] took describes the mission as the `.lev` authored
## it -- `world.load_save` then moved the truth with no delta anybody can
## replay. Redrawing against that stale mirror compares the authored terrain
## with itself, finds nothing changed and moves nothing: a save taken with a
## lift 44 steps up came back with the deck at the bottom and its rider
## standing on air (`_C_115`, slot 17). [method _refresh_after_deploy]
## resyncs too, but it runs after this and only the bodies are its to redraw.
func _resume_loaded_mission() -> void:
	_resync_shown()
	# **The selection [method _build] made is the authored map's.** It was
	# taken before the save replaced the world, so its unit, its move map and
	# its overlay were a turn-1 squad on a mission the save may be ten turns
	# into. Dropped and taken again from the loaded world -- before the
	# camera below, so the saved view wins over the select's own move.
	# Behind the plate, because `test_effects.gd` drives this with a host
	# that has a world, a rig and scenery and nothing to select on.
	if _hud != null:
		_deselect()
		_resume_selection()
	var _redrawn: int = _redraw_terrain_now()
	if _scenery != null and world != null:
		var _restored: int = _scenery.restore_poses(world.restored_scenery(),
			world.terrain_snapshot())
	if _rig != null and world != null:
		_rig.apply_state(world.restored_camera())


## **A save taken at turn 0 loads back into the place interface.** That is
## what *Undo mission* restores: `_31_.sav` carries the squad still in the
## pool and the counter at 0 (docs/11 section 5.8), and a load re-enters
## `aInitBattleGround` (`0x0041DABD` -> `0x0042E811` -> `0x00419D90`), whose
## two arms are the same two a fresh mission has: with somebody still in the
## pool the placement interface goes up, and `0x0041A073` sets the counter
## to 1 outright when nobody is. The first hand-over is then owed the way it
## is on a fresh entry -- [method World.load_save] restores the re-entry
## latch as `turn != 0` -- and *Next player* pays it, `NEXT TURN` and all.
##
## The silent arm pays it here: [method World.open_mission] is the
## `handOver(1)` arm that runs no script, exactly what [method _build] does
## for a fresh map, and the skip must follow it (see [method
## World.skip_deployment_turn] for why the order is forced). It is reached
## only by a save the player took on turn 0 after placing everybody -- the
## mission-start autosave is written with the pool full -- and **that save
## lands on turn 1 with no `NEXT TURN`**, `0x0041A073`'s own answer
## (docs/43 section 5.5, open question 4).
##
## Separate from [method _resume_loaded_mission], and after
## [method _refresh_after_deploy], for two reasons: that one is the picture's
## own work and is called with a half-built host by `test_effects.gd`, and
## the deployment this raises reads the mirror that one took.
func _open_after_load() -> void:
	if world == null or not world.deploying():
		return
	if _may_skip_deployment():
		var _opened: TurnResult = world.open_mission()
		_skip_deployment_turn()
		_begin_mission_view()
		return
	_enter_deployment()


## The interface's own autosaves (docs/43 section 5): the mission's start
## (slot 31, *Undo mission*) and each turn's start (slot 33, *Undo last
## turn*), written the way `0x0041DA20`'s commands write them. They are silent.
## Instant Action uses the same container now that its local CampaignState is
## retained; its mode keeps loading and mission-end routing out of the campaign.
## The mission's start, saved twice: *Undo mission* returns here, and so does
## *Undo last turn* until a turn has been played.
func _autosave_mission_start() -> void:
	_autosave(HudTables.SLOT_UNDO_MISSION)
	_autosave(HudTables.SLOT_UNDO_TURN)


func _autosave(slot: int) -> void:
	if campaign == null or campaign.state == null or world == null:
		return
	# **Deferred, not dropped.** A script that fires a set piece at the top
	# of a turn is holding the queue when this runs, and [method
	# _save_mission_to] refuses mid-sequence -- but *Undo last turn* is a
	# promise about every turn, so the slot waits for the queue instead of
	# going unwritten.
	if _mid_sequence():
		if not _autosaves_pending.has(slot):
			_autosaves_pending.append(slot)
		return
	var _written: bool = _save_mission_to(slot, world)


## Take the deferred autosaves now the queue has drained.
func _flush_autosaves() -> void:
	if _autosaves_pending.is_empty() or _mid_sequence():
		return
	var waiting: PackedInt32Array = _autosaves_pending.duplicate()
	_autosaves_pending.clear()
	for slot: int in waiting:
		_autosave(slot)


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
	# The loaded session does not own result routing until its nested world has
	# passed SaveCodec's map/schema checks below.
	_instant_action_mission = ""
	var blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	if blob.is_empty():
		close_campaign_screen()
		var _map: CampaignScreen = show_campaign_screen(
			_screen_between_missions())
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
	_remember_loaded_session()
	close_campaign_screen()
	campaign.enter_mission(world)
	_resume_loaded_mission()
	_refresh_after_deploy()
	_open_after_load()
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
	# **A pending hold does not raise a screen over this one.** The three
	# `Sleep`s are drawn time and whatever raises a screen while one is
	# counting has overtaken it, so its callback is stale: the original's
	# `Sleep` blocks and nothing else can run at all, and the nearest thing to
	# that here is to drop the countdown rather than let it fire late. Found
	# through the control server, whose `wait` counts frames while a hold
	# counts seconds -- one screen was replaced a moment after it went up.
	# [method _tick_hold] clears the callback before it calls it, so a hold
	# that raises a screen itself is not cancelling itself here.
	_hold_left = 0.0
	_hold_then = Callable()
	# **Before the campaign guard, and deliberately.** The roll needs no
	# campaign state and is reached in the game only by finishing a chain, so
	# `ui credits` is the way a driver gets at it without playing one.
	if name == SCREEN_CREDITS:
		return _show_credits()
	if campaign == null:
		return null
	# **Mission control's entry runs the gate first** (`0x00456FC0(-1)`,
	# docs/41 section 5): the intro once on a new campaign 1, and the two
	# endings instead of a map that is never drawn for them.
	if name == CampaignHost.SCREEN_MAP and campaign.state != null:
		var opening: Dictionary = campaign.opening_sequence()
		var kind: String = DictRead.as_string(opening["kind"])
		if kind == CampaignHost.OPENING_STATIC_EXTRO:
			return _show_static_extro()
		if kind != CampaignHost.OPENING_NONE:
			# **The mission comes down first**, exactly as it does for the
			# static extro two lines up. Mission control's entry is reached
			# from a *finished* mission, and [method _drop_sequence] gives
			# `_scene_root` its visibility and its camera back -- so without
			# this the four-second hold after the animated extro showed the
			# battlefield the player had just left instead of the black the
			# original holds. It is a no-op for the intro, which has no
			# mission behind it.
			_clear_mission()
			var played: CampaignScreen = play_sequence(
				DictRead.as_int(opening["sequence"]),
				DictRead.as_bool(opening["full_screen"]), kind)
			if played != null:
				return played
			# A cache without the cutscenes plays nothing and goes on: the
			# intro is skipped, an ending goes straight to its credits.
			if kind == CampaignHost.OPENING_EXTRO:
				return _show_credits()
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
			# `B` on the map is the mission's own `B0` block
			# ([method CampaignMapScreen.toggle_short_briefing]).
			map.paths = _paths
			map.document = _briefing_document(campaign.current_mission())
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
			briefing.mission = campaign.current_mission()
			briefing.paths = _paths
			briefing.document = _briefing_document(campaign.current_mission())
			# Raised over a running mission by `B`, it is a page to read and
			# close, not a step of the campaign -- see [member
			# BriefingScreen.over_mission]. A mission still on turn 0 is
			# running: its own *Continue* would re-enter the mission, which
			# rebuilds the scene under a squad already standing on it.
			briefing.over_mission = in_mission()
			# `%smb%daif.wav` (`0x004CA8D8`): the mission's voice-over,
			# played with the page and stopped with it.
			briefing.voice = _briefing_voice(campaign.current_mission())
			if not briefing.over_mission:
				_play_voice(briefing.voice)
			screen = briefing
		CampaignHost.SCREEN_HQ:
			# The Unit Menu, the Item List and the Recruit window are all
			# `plate_3` with the frame's window left clear -- the plate
			# `aInitGUI` loads once and none of those windows replaces. So the
			# chain's own map goes up behind them, exactly as it does behind
			# the location screen.
			_raise_hq_backdrop()
			var roster: UnitMenuScreen = UnitMenuScreen.new()
			roster.host = campaign
			roster.selected = campaign.upgrade_slot
			screen = roster
		CampaignHost.SCREEN_RECRUIT:
			_raise_hq_backdrop()
			var hire: RecruitScreen = RecruitScreen.new()
			hire.host = campaign
			screen = hire
		CampaignHost.SCREEN_ITEMS:
			_raise_hq_backdrop()
			var items: ItemListScreen = ItemListScreen.new()
			items.host = campaign
			items.kind = campaign.item_kind
			items.slot = campaign.upgrade_slot
			screen = items
		CampaignHost.SCREEN_UPGRADE:
			# `plate_6` is opaque and has no window, so this one needs no
			# picture behind it -- but it does need the bodies, and those come
			# from the same world set the chain's map is built from.
			_raise_hq_backdrop()
			var upgrade: UpgradeScreen = UpgradeScreen.new()
			upgrade.host = campaign
			upgrade.library = _hq_library()
			upgrade.descriptions = _item_descriptions()
			upgrade.paths = _paths
			upgrade.item_kind = campaign.item_kind
			upgrade.item_id = campaign.item_id
			screen = upgrade
		CampaignHost.SCREEN_DEBRIEFING:
			var debriefing: DebriefingScreen = DebriefingScreen.new()
			debriefing.report = campaign.last_report
			debriefing.board = campaign.mission_board()
			# `0x0045D671`: the debriefing has a CD program of its own.
			_play_frontend_program("debriefing")
			screen = debriefing
	if screen == null:
		return null
	screen.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	screen.chose.connect(_on_campaign_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()
	# The dots go on **after** the screen is up, because which ones there are
	# is the screen's own question: the map's are its open locations.
	match name:
		CampaignHost.SCREEN_MAP:
			_show_markers(CampaignMapScreen.marks_for(campaign,
				_location_cells))
			_frame_map()
		CampaignHost.SCREEN_HQ, CampaignHost.SCREEN_ITEMS, \
				CampaignHost.SCREEN_RECRUIT:
			# The same window as the map's, and **no dots**: these three are
			# lists over a picture, not a picture that is clicked.
			_show_markers({})
			if campaign.is_instant_action():
				_frame_deployment()
			else:
				_frame_map()
	# The Upgrade Menu opens on whoever the Unit Menu had picked, which is also
	# where its *Undo* snapshot is taken.
	var upgrade_screen: UpgradeScreen = screen as UpgradeScreen
	if upgrade_screen != null:
		upgrade_screen.select(_upgrade_target())
	return screen


## Whichever roster slot the campaign is equipping, defaulting to the first
## occupied one so the screen is never opened on nobody by accident.
func _upgrade_target() -> int:
	if campaign == null or campaign.state == null:
		return Roster.NO_SLOT
	var slots: PackedInt32Array = campaign.state.roster.occupied_slots()
	if slots.has(campaign.upgrade_slot):
		return campaign.upgrade_slot
	return slots[0] if not slots.is_empty() else Roster.NO_SLOT


## The chain's own map behind the three windows that leave a hole in the plate.
##
## Split out of the location screen's arm because all four want the same two
## calls, and because the mission has to come down first either way: two 3D
## scenes under one root render into each other.
func _raise_map_backdrop() -> void:
	_clear_mission()
	_build_backdrop(_backdrop_for_location())


## What stands behind the HQ's four screens. A campaign's is an upgrade
## base's own map ([method _raise_map_backdrop]); Instant Action has no map
## and the original frames the mission's own scene, loaded before `aInitGUI`
## ran -- so the mission [method _start_instant_action] built stays where it
## is and nothing is raised over it.
func _raise_hq_backdrop() -> void:
	if campaign != null and campaign.is_instant_action():
		return
	_raise_map_backdrop()


## The bodies the Upgrade Menu turns: the chain map's in a campaign, the
## mission's own in Instant Action, where the mission is the backdrop.
func _hq_library() -> CharismaLibrary:
	if campaign != null and campaign.is_instant_action():
		return _units.library if _units != null else null
	return _campaign_library()


## What stands behind the four screens an upgrade location opens.
##
## **The location's own map, not the chain's.** docs/27 section 2.4 pairs each
## upgrade location with a `Missions/upgrade_N.lev`, and `CampaignMap` has
## carried the table since the sixth slice; what was behind these plates was
## the chain map `_C_XXX` instead -- a bright city in daylight where the
## original shows the base's own dim interior. The chain map is the fallback,
## for a location that names no upgrade scene and for a cache published without
## `--campaign-maps`.
func _backdrop_for_location() -> String:
	if campaign == null:
		return ""
	var own: String = campaign.tables.upgrade_map(campaign.location) \
		if campaign.tables != null else ""
	if own == "" or not FileAccess.file_exists(
			"%s/missions/%s/map.json" % [_cache_dir, own]):
		return campaign.map_mission()
	return own


## The bodies the Upgrade Menu turns, opened against the chain map's world set.
##
## Built on demand and kept, because a `.cho` parse and its meshes are the
## same cost here as in a mission and this screen is opened and closed a great
## deal more often.
func _campaign_library() -> CharismaLibrary:
	if _campaign_bodies != null:
		return _campaign_bodies
	# `campaign` was implied by the one caller this had -- the Upgrade Menu --
	# and is not by [method _build_backdrop], which stands an upgrade base's
	# marines up with it.
	if _backdrop_world == null or campaign == null:
		return null
	var map_document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, _backdrop_for_location()])
	if map_document.is_empty():
		return null
	var header: Dictionary = DictRead.as_dict(map_document["header"])
	var world_set: String = DictRead.as_string(header["world_set"])
	_campaign_bodies = CharismaLibrary.open(_cache_dir,
		_textures_for(world_set), campaign.map_mission())
	return _campaign_bodies


## The deployment cells nobody is standing on yet -- what the agent and the
## touch run ask for. [method World.deployment_cells] answers the cells the
## *map* offers, and the overlay dots every one of them, occupied or not:
## a dot under a placed soldier is the click that takes him back.
func _free_landings() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if world == null:
		return out
	for cell: Vector2i in _landing_cells():
		var view: Dictionary = world.cell_view(cell.x, cell.y)
		if DictRead.as_int(view["unit"]) == MapState.NO_UNIT:
			out.append(cell)
	return out


## The cells the map offers player 0, read from the same side of the fence
## [method _deploying] reads: the host's with a campaign begun, the world's
## own for a turn-0 world without one. One source for the centre, the free
## list and `/state`, so the dots the overlay draws and the cells the agent
## is told can never disagree.
func _landing_cells() -> Array[Vector2i]:
	if world == null:
		return []
	if campaign != null and campaign.state != null:
		return campaign.deployment_cells()
	return world.deployment_cells(0)


## Put the camera over the cells the squad is about to be put on -- the
## counter-0 arm of `aInitBattleGround`: the map view with no placement
## (`fcn.00452940`) and the eye on the landing zone (`fcn.00452420`, docs/43
## section 4.5).
##
## [method _frame_units] cannot: it frames a **unit**, and at this point the
## player has none on the map. So the deployment area is framed instead, on
## the cell nearest its own middle, because the middle itself is not
## somewhere anyone can stand.
func _frame_deployment() -> void:
	_set_deploy_view(CameraRig.View.MAP)


## The deployment cell nearest the middle of the deployment area, or `(-1, -1)`.
##
## The middle itself is not where anybody can stand, and the original's own
## camera routines all take a cell.
func _deployment_centre() -> Vector2i:
	var cells: Array[Vector2i] = _landing_cells()
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


# --- the place interface, turn 0 (docs/43 section 5.5) -----------------------

## The `deploy.*` lines the interface speaks, by their catalogue suffix
## ([Localization]); a [World] or [CampaignHost] refusal name is one too.
const DEPLOY_LINE_PREFIX: String = "deploy.%s"
const DEPLOY_LINE_HINT: String = "hint"
const DEPLOY_LINE_NEED_ONE: String = "need_one"
const DEPLOY_LINE_POOL_EMPTY: String = "pool_empty"


## Whether the place interface is up -- `fcn.00463380`'s own gate, the turn
## counter, and with a campaign the host's ([method CampaignHost.deploying]),
## which also asks for the mission to be the screen: *Instant Action*'s HQ
## frames a turn-0 world it is not deploying into yet.
func _deploying() -> bool:
	if world == null:
		return false
	if campaign != null and campaign.state != null:
		return campaign.deploying()
	return world.deploying()


## `0x0041A073`'s skip -- `gameMode() == 1 && poolCount == 0 && turn == 0`
## -- plus the remake's own fourth test, somebody to start with (docs/43
## section 5.5). *Instant Action* is not a campaign game and takes the place
## interface even over an empty pool ([method World.skip_deployment_turn]
## would do nothing there, and a load would land in neither state).
func _may_skip_deployment() -> bool:
	return campaign != null and campaign.state != null and world != null \
		and world.turn.mode == TurnState.MODE_CAMPAIGN \
		and campaign.nobody_to_deploy() and campaign.may_start()


## Whether *Next player* may leave turn 0: somebody of player 0 on the map.
## The campaign's own test where there is a campaign; a mission entered past
## it ([method first_friendly_slot]) otherwise.
func _may_leave_deployment() -> bool:
	if campaign != null and campaign.state != null:
		return campaign.may_start()
	return first_friendly_slot(world) >= 0


## The two arms of `aInitBattleGround` once the mission is built and the
## campaign has entered it: `0x0041A073`'s silent skip to turn 1 when the
## pool has nobody to place **and** the map already carries a squad, else
## the place interface.
##
## **After `begin_mission`**, which is what put the live roster back: the
## pool this asks about is the one the panel draws from, and reading it
## before the restore made a re-entered mission -- the briefing's own
## *Continue* over a deployment -- take the silent arm on an empty row.
## Where the pool is empty and the mission has no squad either, the
## interface still goes up, because then there really is nothing to start
## and the map with its dots is what says so.
##
## **Without a campaign there is no pool at all**, and the mission takes
## the silent arm the way `--mission=` does: the agent's `enter` and the
## `"enter"` result both reach this from the shell, and leaving the world
## on turn 0 there gave a map whose every click [method _pick] routed to
## the place interface and whose every arm refused without a word.
func _open_deployment_or_start() -> void:
	if world == null:
		return
	close_campaign_screen()
	# [method close_campaign_screen] syncs the HUD only when a screen was
	# up; the agent's `enter` reaches this with none, and the mission's
	# view is what the interface is drawn over.
	_sync_hud()
	if campaign == null or campaign.state == null:
		_skip_deployment_turn()
		_begin_mission_view()
		return
	# **Here, before anybody is placed**, which is where the engine writes
	# it: the retail `_31_.sav` carries turn 0 with the squad still in the
	# live row beside its entry snapshot (`tests/fixtures/saves`, docs/11
	# section 5.8). *Undo mission* therefore returns to the place interface
	# with the whole pool to place again, and its way out is the hand-over
	# -- `NEXT TURN` and all -- never `0x0041A073`'s silent arm.
	_autosave_mission_start()
	if _may_skip_deployment():
		_skip_deployment_turn()
		_begin_mission_view()
		return
	_enter_deployment()


## `aInitPlaceInterface` `0x004632E0`: the pool's first record is selected
## when there is one (`0x00463355..64`), the camera goes over the landing
## zone, and the line says what a click does. Nothing is selected on the
## map -- `fcn.00471E00` refuses before the first hand-over.
func _enter_deployment() -> void:
	_deploy_slot = Roster.NO_SLOT
	if campaign != null and campaign.state != null:
		var slots: PackedInt32Array = campaign.state.roster.occupied_slots()
		if not slots.is_empty():
			_deploy_slot = slots[0]
	_deselect()
	_frame_deployment()
	_say_deploy(DEPLOY_LINE_HINT if _deploy_slot != Roster.NO_SLOT
		else DEPLOY_LINE_POOL_EMPTY)
	_refresh_overlay()
	_refresh_status()


## The pool record on the panel while deploying, or `null`. A clone, read and
## let go: the roster hands out copies.
func _deploy_record() -> UnitState:
	if not _deploying() or _deploy_slot == Roster.NO_SLOT \
			or campaign == null or campaign.state == null:
		return null
	return campaign.state.roster.record(_deploy_slot)


## One line on the HUD's caption label, `deploy.<name>` -- the interface's
## hint and every refusal, spoken (docs/92 section 7.4). A name the
## catalogue has no line for comes back as the marker rather than as a
## blank, so a new refusal is visible instead of silent.
func _say_deploy(name: String) -> void:
	if _hud == null or _strings == null:
		return
	_hud.set_line(_strings.text(DEPLOY_LINE_PREFIX % name))


## The place interface's click on the world (`fcn.00463380`'s window arm):
## the cell under the pointer, then [method deploy_cell] with the click's
## own position for the facing.
func _deploy_click(screen: Vector2) -> void:
	if _rig == null or _rig.camera() == null or world == null:
		return
	# The whole cell, not the third of it a click on a body wants: the
	# original's `fcn.0042f730` answers the cell under the pointer.
	var cell: Vector2i = cell_under(_rig.camera(), world, screen, 1.0)
	var _done: bool = deploy_cell(cell, screen)


## A click on *cell* while deploying, *at* being where on the viewport it
## landed: a soldier standing there comes back into the pool if he is a pool
## candidate (`0x00463485`); an empty deployment cell takes the selected
## pool soldier, facing by the quadrant of the click (`0x00463552..94`);
## anything else is refused with a line. Public so a suite can place without
## projecting a cell onto a camera. Answers whether the map changed.
func deploy_cell(cell: Vector2i, at: Vector2) -> bool:
	if not _deploying():
		return false
	if cell.x < 0 or not world.state.in_bounds(cell.x, cell.y):
		_say_deploy(World.DEPLOY_NOT_A_CELL)
		return false
	# A turn-0 world without a campaign has no pool: nothing to place and
	# nowhere to take anybody back to. Said, not swallowed (docs/92
	# section 7.4).
	if campaign == null or campaign.state == null:
		_say_deploy(DEPLOY_LINE_POOL_EMPTY)
		return false
	# The truth, not the mirror: whether the click is allowed is the one
	# question the truth answers (docs/100).
	var view: Dictionary = world.cell_view(cell.x, cell.y)
	if DictRead.as_int(view["unit"]) != MapState.NO_UNIT:
		var taken: Dictionary = recall_at(cell.x, cell.y)
		if DictRead.as_string(taken["result"]) != World.RECALL_OK:
			return false
		_play_interface(AudioTables.INTERFACE_DEPLOY_PLACE)
		return true
	if _deploy_slot == Roster.NO_SLOT:
		_say_deploy(DEPLOY_LINE_POOL_EMPTY)
		return false
	var placed: Dictionary = place_from_roster(_deploy_slot, cell.x, cell.y,
		Deployment.facing_for(at, _viewport_size()))
	if DictRead.as_string(placed["result"]) != World.DEPLOY_OK:
		return false
	_play_interface(AudioTables.INTERFACE_DEPLOY_PLACE)
	return true


## A placement with the interface's bookkeeping -- the host's answer, and on
## success the picture, the selection clamped as `0x004635E3..0x00463605`
## and the line; a refusal is spoken. The click places the selected record;
## the agent's `deploy` names any slot, so the clamp is measured from where
## the *selection* stood and keeps it while it is still in the pool.
func place_from_roster(slot: int, x: int, y: int, facing: int) -> Dictionary:
	if campaign == null or campaign.state == null:
		return {"result": World.DEPLOY_EMPTY_RECORD, "slot": MapState.NO_UNIT}
	var position: int = campaign.state.roster.occupied_slots().find(_deploy_slot)
	var placed: Dictionary = campaign.deploy(slot, x, y, facing)
	var result: String = DictRead.as_string(placed["result"])
	if result != World.DEPLOY_OK:
		_say_deploy(result)
		return placed
	_refresh_after_deploy()
	var slots: PackedInt32Array = campaign.state.roster.occupied_slots()
	if slot == _deploy_slot or not slots.has(_deploy_slot):
		_deploy_slot = Deployment.after_placement(slots, position)
	_say_deploy(DEPLOY_LINE_HINT if _deploy_slot != Roster.NO_SLOT
		else DEPLOY_LINE_POOL_EMPTY)
	_refresh_status()
	return placed


## A take-back with the interface's bookkeeping, `0x004634C7..0x004634F8`:
## the host's answer, and on success the picture, an empty selection made
## the first record, and the line; a refusal is spoken.
func recall_at(x: int, y: int) -> Dictionary:
	if campaign == null or campaign.state == null:
		return {"result": World.RECALL_NO_UNIT, "slot": Roster.NO_SLOT}
	var taken: Dictionary = campaign.recall(x, y)
	var outcome: String = DictRead.as_string(taken["result"])
	if outcome != World.RECALL_OK:
		_say_deploy(outcome)
		return taken
	_refresh_after_deploy()
	_deploy_slot = Deployment.after_recall(
		campaign.state.roster.occupied_slots(), _deploy_slot)
	_say_deploy(DEPLOY_LINE_HINT)
	_refresh_status()
	return taken


## The panel band's halves, `fcn.004637c0`: *step* is [constant
## Deployment.PREV] or [constant Deployment.NEXT]. Nothing happens with no
## selection -- the original's `je 0x46371d` -- and the click is `click_2`.
## Answers whether the selection moved.
func cycle_deploy_slot(step: int) -> bool:
	if not _deploying() or _deploy_slot == Roster.NO_SLOT \
			or campaign == null or campaign.state == null:
		return false
	var slots: PackedInt32Array = campaign.state.roster.occupied_slots()
	var next: int = Deployment.cycle(slots, _deploy_slot, step)
	if next == Roster.NO_SLOT:
		return false
	_play_interface(AudioTables.INTERFACE_DEPLOY_CYCLE)
	_deploy_slot = next
	_refresh_status()
	return true


## The place interface as the agent reads it (`/state`'s `deployment`).
func deployment_view() -> Dictionary:
	var out: Dictionary = {
		"active": _deploying(),
		"selected_slot": _deploy_slot,
		"roster": [],
		"cells": [],
		"free_cells": [],
	}
	if not _deploying():
		return out
	if campaign != null and campaign.state != null:
		out["roster"] = Array(campaign.state.roster.occupied_slots())
	var cells: Array = []
	for cell: Vector2i in _landing_cells():
		cells.append([cell.x, cell.y])
	out["cells"] = cells
	var free: Array = []
	for cell: Vector2i in _free_landings():
		free.append([cell.x, cell.y])
	out["free_cells"] = free
	return out


## The viewport's size, or the plate's when there is no tree yet.
func _viewport_size() -> Vector2:
	if is_inside_tree():
		return get_viewport().get_visible_rect().size
	return Vector2(HudTables.PLATE_SIZE)


# --- the shell ---------------------------------------------------------------

## Raise the shell at one of its screens, over the mission when there is one.
##
## The shell and the campaign screens share [member _screen]: only one plate is
## ever up, and a shell raised over a campaign screen would leave the campaign
## one unreachable behind it. That is why `ESC` only opens the shell from a
## mission view (see [method _unhandled_input]).
func open_shell(name: String = ShellHost.SCREEN_MENU) -> CampaignScreen:
	# The same rule as [method show_campaign_screen]: a hold that has been
	# overtaken does not get to raise anything.
	_hold_left = 0.0
	_hold_then = Callable()
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


## Carry the slot list's page over the rebuild a write causes.
##
## Both ways of turning it come through here -- the two arrows and the wheel --
## because the wheel does not go through [method _on_shell_choice] at all, and
## a page turned with it used to snap back to whatever the arrows last set.
func _remember_slot_page() -> void:
	var slots: SaveSlotsScreen = _screen as SaveSlotsScreen
	if slots != null:
		shell.slot_page = slots.first_row


## The world a save taken **from a screen** should carry, which is the one
## being played and nothing at all when the screen stands over a finished one.
##
## **Written once, and read by both writers that need it.** The campaign map is
## drawn over the *last* mission's view and that world is still in memory, so
## `world` alone put a finished mission's blob in a between-missions save and
## a load came back into it. `world != null` is not the question;
## [method in_mission] is.
func world_to_save() -> World:
	return world if in_mission() else null


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
			# **A mission with a campaign screen behind it, not any mission**:
			# `--mission=` clears the campaign state, and there is nothing to
			# go back to. Instant Action goes back to the HQ its squad was
			# hired in, under the *Back* caption -- since the deployment
			# moved into the mission (docs/43 section 5.5) this entry is the
			# one way off a turn-0 map.
			menu.may_abandon = in_mission() and campaign != null \
				and campaign.state != null
			menu.abandon_to_hq = campaign != null \
				and campaign.is_instant_action()
			menu.behind = shell.behind
			menu.has_any_save = _any_slot_used()
			menu.has_instant_action = not _instant_action_missions().is_empty()
			screen = menu
		ShellHost.SCREEN_CAMPAIGN_SELECT:
			var chains: CampaignSelectScreen = CampaignSelectScreen.new()
			chains.host = campaign
			screen = chains
		ShellHost.SCREEN_MISSION_SELECT:
			var list: MissionSelectScreen = MissionSelectScreen.new()
			list.missions = _instant_action_missions()
			screen = list
		ShellHost.SCREEN_SLOTS:
			var slots: SaveSlotsScreen = SaveSlotsScreen.new()
			slots.host = campaign
			slots.mode = shell.slot_mode
			slots.may_save = campaign != null and campaign.state != null
			slots.first_row = shell.slot_page
			screen = slots
		ShellHost.SCREEN_OPTIONS:
			var options: OptionsScreen = OptionsScreen.new()
			options.settings = settings
			options.in_mission = in_mission()
			if _campaign_difficulty_writable():
				options.campaign_difficulty = campaign.state.difficulty
			options.language = _strings.language if _strings != null \
				else Localization.FALLBACK_LANGUAGE
			if _paths != null:
				options.languages = _paths.languages()
			options.volume_changed.connect(_set_option_volume)
			screen = options
	if screen == null:
		return null
	screen.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	screen.chose.connect(_on_shell_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()
	return screen


## Whether any numbered slot holds something, which is what decides whether
## the menu offers *Load Game*.
##
## The quick save is deliberately not counted. It is not one of them (S1),
## and counting it meant a player who had only ever pressed `F5` was offered a
## list every row of which refused the click -- the inert control
## section 7.1 forbids, reached by the very button that exists to avoid it.
## `F9` is how a quick save comes back.
func _any_slot_used() -> bool:
	if campaign == null:
		return false
	for slot: int in range(CampaignHost.SLOT_COUNT):
		if campaign.has_save(slot):
			return true
	return false


## The single maps the cache carries, read once (see
## [method _instant_action_missions]).
var _instant_missions: PackedStringArray = PackedStringArray()
var _instant_missions_read: bool = false


## The retail map header's type is the boundary, not a filename convention.
## Type 2 is `Single`; type 1 is campaign, 3/5 need the multiplayer/coop
## protocol the remake does not implement, and type 4 includes the campaign
## backdrops and upgrade screens.  Showing any of those under a local one-seat
## ArenaMode was the source of the former "loaded but unplayable" maps.
func _instant_action_missions() -> PackedStringArray:
	if _instant_missions_read:
		return _instant_missions.duplicate()
	var out: PackedStringArray = PackedStringArray()
	for mission: String in _missions:
		var document: Dictionary = CacheLoader.read_json(
			"%s/missions/%s/map.json" % [_cache_dir, mission])
		var header: Dictionary = DictRead.as_dict(document.get("header", {}))
		if DictRead.as_int(header.get("map_type", -1)) == 2:
			out.append(mission)
	# **Read once.** The answer opens a document per mission -- 92 of them in a
	# campaign cache -- and the main menu asks for it every time it is built.
	# The cache cannot change under a running process.
	_instant_missions = out
	_instant_missions_read = true
	return out.duplicate()


## What a shell button means. The host owns the transitions; this turns one
## into a call, exactly as [method _on_campaign_choice] does for the campaign.
func _on_shell_choice(action: String) -> void:
	if _leaving:
		return
	if action.begins_with("slot:"):
		_use_slot(action.substr(5).to_int())
		return
	if action.begins_with("start:"):
		_start_campaign(action.substr(6).to_int())
		return
	if action.begins_with("select_mission:"):
		var list: MissionSelectScreen = _screen as MissionSelectScreen
		if list != null:
			list.select_mission(action.substr(15))
		return
	if action == "scroll_up" or action == "scroll_down":
		# The catalogue is 92 long with the campaign in the cache and the slot
		# list is 24, and a shipped listbox is paged by its two arrows rather
		# than scrolled.
		var step: int = -1 if action == "scroll_up" else 1
		var paged: MissionSelectScreen = _screen as MissionSelectScreen
		if paged != null:
			paged.scroll(step)
		var paged_slots: SaveSlotsScreen = _screen as SaveSlotsScreen
		if paged_slots != null:
			paged_slots.scroll(step)
			_remember_slot_page()
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
		"instant_start":
			var selected: MissionSelectScreen = _screen as MissionSelectScreen
			if selected != null and selected.selected != "":
				_start_instant_action(selected.selected)
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
		MainMenuScreen.MAIN_MAP:
			# The narrower way out: the mission goes and the campaign stays.
			# **The guard is not the button's**: the button is offered only
			# with a campaign behind it ([method _show_shell_screen]), but
			# the control server's `menu` and `press` verbs reach this table
			# without one, and [method CampaignHost.abandon_mission] would
			# then leave the shell down over a mission it had not dropped.
			if campaign != null and campaign.state != null:
				shell.close()
				_leave_mission_for_map()
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


## Leave a mission without finishing it and put the location map back, with the
## campaign standing.
##
## The pause menu's ([constant MainMenuScreen.MAIN_MAP]), whether the sortie
## is still on turn 0 or has been played; the deployment screen that used to
## carry a second button for the first case is gone (docs/43 section 5.5).
##
## The squad comes back off the map first: the location screen frees the
## mission's whole scene, and anyone already deployed had been taken out of
## the pool to stand on it. [method CampaignHost.abandon_mission] does that
## and sets the screen, and [method show_campaign_screen] tears the mission
## down -- including a turn still being replayed, which
## [method _clear_mission] cancels rather than skips.
func _leave_mission_for_map() -> void:
	if campaign == null or campaign.state == null:
		return
	# Instant Action has no map: the Upgrade Menu's *Exit* and the pause
	# menu's way out both land in the HQ. From a mission the squad has to
	# come off the map first, which is the `hq` action's own arm.
	if campaign.is_instant_action():
		if campaign.screen == CampaignHost.SCREEN_MISSION:
			_return_to_instant_action_hq()
		else:
			var _hq: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_HQ)
		return
	campaign.abandon_mission()
	var _to_map: CampaignScreen = show_campaign_screen(
		CampaignHost.SCREEN_MAP)


## Drop the campaign and whatever is on the screen, and come back at the boot
## menu.
##
## Reached from two buttons -- the map's *End game* and the pause menu's *Main
## Menu* -- and written once, because they mean the same thing and the second
## of them was added by copying the first. Both ask `Txtmod_d` 60 first; this
## is only what happens after the answer.
func _end_campaign() -> void:
	_instant_action_mission = ""
	_drop_sequence()
	_hold_left = 0.0
	if campaign != null:
		campaign.end()
	_clear_backdrop()
	_clear_mission()
	if _audio != null:
		var _stopped: int = _audio.stop_tag(ExtroScreen.CONTINUE)
	var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)
	_play_frontend_program("menu")


# --- the briefing around a mission -- docs/24 section 7.1 -------------------

## `text/briefing/<mission>.json` for the chosen language, or `{}`.
func _briefing_document(mission: String) -> Dictionary:
	if _paths == null or mission.is_empty():
		return {}
	return CacheLoader.read_json(_paths.path("text/briefing/%s.json" % mission))


## `audio/briefing/<mission>.wav`, lower-cased as the converter writes it, or
## `""` when the cache has no voice for the mission. The chosen language's
## dub when its pack carries one -- resolved by [CachePaths], as every wave
## is ([method AudioTables.audio_path]).
func _briefing_voice(mission: String) -> String:
	if _paths == null or mission.is_empty():
		return ""
	var relative: String = "audio/briefing/%s.wav" % mission.to_lower()
	if not FileAccess.file_exists(_paths.path(relative)):
		return ""
	return relative


func _play_voice(relative: String) -> void:
	if relative.is_empty():
		return
	var audio: AudioSystem = interface_audio()
	if audio == null:
		return
	var _stopped: int = audio.stop_tag(VOICE_TAG)
	var _slot: int = audio.play_file(relative, VOICE_TAG)


# --- the front end between the screens -- docs/92 section 7.19 -------------

## One of the three `Sleep` holds, in milliseconds, from the cache's front-end
## document, or *fallback* when the cache predates it.
func hold_ms(name: String, fallback: int) -> int:
	var holds: Dictionary = DictRead.as_dict(_frontend.get("holds_ms", {}))
	return DictRead.as_int(holds.get(name, fallback))


## Wait *ms* of drawn time, then run *then*. One hold at a time: a second one
## replaces the first, as the original's `Sleep`s never overlap.
func hold(ms: int, then: Callable) -> void:
	if ms <= 0:
		_hold_left = 0.0
		_hold_then = Callable()
		if then.is_valid():
			then.call()
		return
	_hold_left = float(ms) / 1000.0
	_hold_then = then


## Whether a hold is counting down -- the agent's snapshot and the suite.
func holding() -> bool:
	return _hold_left > 0.0


func _tick_hold(delta: float) -> void:
	if _hold_left <= 0.0:
		return
	_hold_left -= delta
	if _hold_left > 0.0:
		return
	_hold_left = 0.0
	var then: Callable = _hold_then
	_hold_then = Callable()
	if then.is_valid():
		then.call()


## One of the front end's CD programs -- `menu`, `credits`, `debriefing` --
## started unless it is already the one playing, so a screen rebuilt behind a
## click does not restart the track.
func _play_frontend_program(name: String) -> void:
	var programs: Dictionary = DictRead.as_dict(_frontend.get("cd_programs", {}))
	var program: String = DictRead.as_string(programs.get(name, ""))
	if program.is_empty() or _cache_dir.is_empty():
		return
	var audio: AudioSystem = interface_audio()
	if audio == null or audio.music_source() == AudioSystem.program_source(
			program):
		return
	var _track: int = audio.start_program(program)


## `aGameIntro`'s two plates.
##
## The flag is written when the **title** plate goes up, not at boot: a run
## killed on the logo is a run that never showed the player anything to skip.
func _show_splash(stage: int) -> void:
	if stage == SplashScreen.STAGE_TITLE and not settings.seen_splash:
		settings.seen_splash = true
		var _written: bool = settings.save_to_disk()
	close_campaign_screen()
	var splash: SplashScreen = SplashScreen.new()
	splash.stage = stage
	splash.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	splash.chose.connect(_on_campaign_choice)
	add_child(splash)
	_screen = splash
	_sync_hud()


## `aPrintMessageScreen`: *Please Wait...* for at least one drawn frame, then
## *then* -- which puts up whatever comes next and so takes this down.
func _show_message_then(then: Callable) -> void:
	close_campaign_screen()
	var message: MessageScreen = MessageScreen.new()
	message.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	add_child(message)
	_screen = message
	_sync_hud()
	# Two frames, as [method _run_tests_and_quit] does: the first draws the
	# plate, the second makes sure it is on the screen before the main thread
	# stops answering for the build's length.
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_inside_tree():
		return
	then.call()
	# Whatever *then* raised replaced this; if it raised nothing -- a mission
	# view -- the plate has to come down by hand.
	if _screen == message:
		close_campaign_screen()


## Play logical sequence *id* -- full screen or framed over `plate_7` -- for
## *kind*, and answer the screen, or `null` when the cache has no cutscenes.
##
## The player is a [Node3D] under this node with a camera of its own, drawn
## through the plate's hole like the campaign map is; the map's own root is
## hidden meanwhile so the two scenes do not render into each other.
func play_sequence(id: int, full: bool, kind: String) -> CampaignScreen:
	_drop_sequence()
	_hold_left = 0.0
	if _sequence_manifest.is_empty():
		return null
	var window: Rect2 = Rect2(Vector2.ZERO, CampaignScreen.PLATE_SIZE) \
		if full else CampaignScreen.PLATE_WINDOW
	var player: SequencePlayer = SequencePlayer.new()
	player.name = "Sequence"
	if not player.create(_cache_dir, _sequence_manifest, id, window,
			CampaignScreen.PLATE_SIZE):
		player.free()
		return null
	player.cd_program.connect(_on_sequence_program)
	add_child(player)
	if not player.start():
		remove_child(player)
		player.free()
		return null
	_sequence = player
	_sequence_kind = kind
	if _backdrop_root != null:
		_backdrop_root.visible = false
	if _scene_root != null:
		_scene_root.visible = false
	player.camera().current = true
	close_campaign_screen()
	var screen: SequenceScreen = SequenceScreen.new()
	screen.full = full
	screen.player = player
	screen.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	screen.chose.connect(_on_campaign_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()
	for line: String in player.missing():
		push_warning("sequence %d: %s" % [id, line])
	return screen


## A part's CD program -- the `Track` family, the one that covers 9..19
## (docs/92 section 7.19).
func _on_sequence_program(program: String) -> void:
	if _cache_dir.is_empty():
		return
	var audio: AudioSystem = interface_audio()
	if audio != null:
		var _track: int = audio.start_program(program, AudioTables.FAMILY_TRACK)


func _tick_sequence(delta: float) -> void:
	if _sequence == null or not _sequence.running:
		return
	var still: bool = _sequence.update(delta)
	var screen: SequenceScreen = _screen as SequenceScreen
	if screen != null:
		screen.hide_caption()
	if not still:
		_finish_sequence()


## The player's view for the agent's snapshot: empty when nothing plays.
func sequence_view() -> Dictionary:
	if _sequence == null:
		return {}
	var out: Dictionary = _sequence.view()
	out["kind"] = _sequence_kind
	return out


## Take the player down and put the picture back, with no follow-up.
func _drop_sequence() -> void:
	if _sequence == null:
		return
	_sequence.destroy()
	remove_child(_sequence)
	_sequence.free()
	_sequence = null
	_sequence_kind = ""
	if _backdrop_root != null:
		_backdrop_root.visible = true
		if _backdrop_rig != null and _backdrop_rig.camera() != null:
			_backdrop_rig.camera().current = true
	if _scene_root != null:
		_scene_root.visible = true
		if _rig != null and _rig.camera() != null:
			_rig.camera().current = true
	if _audio != null and _audio.music_source().begins_with(
			AudioSystem.program_source("", AudioTables.FAMILY_TRACK)):
		_audio.stop_music()


## Enter an upgrade base: its own scene, the arrival flight, then the menu.
##
## `aLocationHandling`'s upgrade arm calls `aPlayLocationAnimation_Upgrade`
## `0x00417510` **before** mission control raises any window, and that routine
## blocks in the flight (docs/27 section 2.7). So the base opens with the
## camera coming down over it behind `plate_7`, and the Upgrade Menu is what
## the flight hands over to. A base with no path of its own -- or a cache with
## no `upgrade_N` in it -- goes straight to the menu.
func _enter_upgrade_location() -> void:
	_raise_map_backdrop()
	if not _start_fly_in(func() -> void:
			var _menu: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_UPGRADE)):
		var _up: CampaignScreen = show_campaign_screen(
			CampaignHost.SCREEN_UPGRADE)
		return
	close_campaign_screen()
	var screen: FlyInScreen = FlyInScreen.new()
	screen.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	screen.chose.connect(_on_campaign_choice)
	add_child(screen)
	_screen = screen
	_sync_hud()


## `0x00457180`: the sequence is over -- its last part ended, or a key or a
## click -- and what follows depends on why it played.
func _finish_sequence() -> void:
	# **Nothing is playing, so there is nothing to finish.** The screen stays
	# up over the hold that follows -- black, as the original's `Sleep` leaves
	# it -- and its `_unhandled_input` is still live, so a second key emits
	# `DONE` again. Without this guard that ran the arm below with an empty
	# `kind`, which for the animated extro re-entered `show_campaign_screen`
	# and replayed the whole thing: mission 255 arms `opening_sequence()`
	# every time, unlike the intro's once-only flag, so the credits could not
	# be reached while the player kept pressing keys. The original cannot be
	# re-entered because its `Sleep` blocks.
	if _sequence == null:
		return
	var kind: String = _sequence_kind
	_drop_sequence()
	match kind:
		CampaignHost.OPENING_EXTRO:
			# Mission id 255: `Sleep(4000)`, then the credits flag; the
			# plate stays up, black, for the hold.
			hold(hold_ms("after_extro", 4000), func() -> void:
				var _credits: CampaignScreen = _show_credits())
		CampaignHost.OPENING_INTRO, SEQUENCE_DIALOGUE:
			# `Sleep(1000)`, then mission control's map.
			hold(hold_ms("after_sequence", 1000), func() -> void:
				var _map: CampaignScreen = show_campaign_screen(
					CampaignHost.SCREEN_MAP))
		_:
			# `--sequence=` and the agent's `sequence N`: back to whatever
			# was there -- the map when a campaign is running, else the menu.
			close_campaign_screen()
			if campaign != null and campaign.state != null:
				var _map: CampaignScreen = show_campaign_screen(campaign.screen)
			elif not in_mission():
				var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)
				_play_frontend_program("menu")


## The static extro of mission id 180 (`0x00457430`): `Ship.bmp`,
## `extro.wav`, *Continue*.
func _show_static_extro() -> CampaignScreen:
	_drop_sequence()
	close_campaign_screen()
	_clear_mission()
	if _backdrop_root != null:
		_backdrop_root.visible = false
	var extro: ExtroScreen = ExtroScreen.new()
	extro.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	extro.chose.connect(_on_campaign_choice)
	add_child(extro)
	_screen = extro
	_sync_hud()
	var audio: AudioSystem = interface_audio()
	if audio != null:
		audio.stop_music()
		var _slot: int = audio.play_file(ExtroScreen.WAVE, ExtroScreen.CONTINUE)
	return extro


## The credits, after either ending: `Credits.bmp`, CD program `"8"`.
func _show_credits() -> CampaignScreen:
	close_campaign_screen()
	if _backdrop_root != null:
		_backdrop_root.visible = false
	var credits: CreditsScreen = CreditsScreen.new()
	credits.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	credits.chose.connect(_on_campaign_choice)
	add_child(credits)
	_screen = credits
	_sync_hud()
	_play_frontend_program("credits")
	return credits


## docs/92 section 7.15 S4, closed by section 7.19: the intro is not a step
## of its own. `start_new` arms [member CampaignState.intro_pending] for
## campaign 1, and the gate at the top of [method show_campaign_screen] plays
## `Video/Seq_1` (logical id 0) once, at the first entry to mission control --
## exactly where `0x00456FC0(-1)` reads `[0x00510D48]`.
func _start_campaign(chain: int) -> void:
	if campaign == null or not CampaignState.FIRST_MISSION.has(chain):
		return
	_instant_action_mission = ""
	var _state: CampaignState = campaign.start_new(chain, settings.difficulty)
	shell.close()
	# `aInitMissionControl` prints *Please Wait...* (`0x00454007`) on the way
	# in, and the first map takes a moment to build.
	_show_message_then(func() -> void:
		var _map: CampaignScreen = show_campaign_screen(
			CampaignHost.SCREEN_MAP))


## One mission, past the campaign -- what `--mission=` reaches, from a list.
##
## The campaign state is **cleared**, not left over: a mission played this way
## has no roster, no scoreboard and no next mission, and a stale campaign
## behind it would send its debriefing somewhere the player never was.
func _start_instant_action(mission: String) -> void:
	if not _instant_action_missions().has(mission):
		_refresh_status("Instant Action has no playable " + mission)
		return
	if campaign == null:
		_refresh_status("Instant Action needs the campaign tables")
		return
	var document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, mission])
	var header: Dictionary = DictRead.as_dict(document.get("header", {}))
	campaign.start_instant_action(mission, header, settings.difficulty)
	shell.close()
	close_campaign_screen()
	# The `.lev` is loaded before `aInitGUI` runs, and the HQ that opens over
	# it frames the mission's own scene in `plate_3`'s window -- so the
	# mission is built first and the HQ goes up over it, with nobody hired
	# yet. *Deploy units* is what takes the entry snapshot ([method
	# _deploy_instant_action]).
	_build(mission)
	if world != null:
		_instant_action_mission = mission
		campaign.frame_mission(world)
		var _hq: CampaignScreen = show_campaign_screen(
			CampaignHost.SCREEN_HQ)


## The HQ's *Deploy units* in Instant Action -- `Menu_b` window 0's gadget 2,
## which `0x004579A3` keeps off while the pool is empty. The mission's scene
## is already standing behind the HQ; what changes hands is the roster.
func _deploy_instant_action() -> void:
	if campaign == null or campaign.state == null \
			or campaign.nobody_to_deploy():
		return
	if world == null:
		_build(campaign.current_mission())
	if world == null:
		return
	campaign.begin_mission(world)
	_open_deployment_or_start()


## Back from an Instant Action mission: the squad returns to the pool and
## the HQ comes up over a mission built afresh, because whoever was already
## placed is standing on the old one.
func _return_to_instant_action_hq() -> void:
	if campaign == null or campaign.state == null:
		return
	campaign.abandon_mission()
	_build(campaign.current_mission())
	if world != null:
		campaign.frame_mission(world)
	var _hq: CampaignScreen = show_campaign_screen(CampaignHost.SCREEN_HQ)


## The name the slot screen is holding, or `""` when what is up is not one.
##
## **Static and pure, so it can be checked.** It is the one link between the
## field the player types in and the file that is written, and the rest of
## that path only runs with a whole [SliceMain] on a tree -- a cast that
## silently answered `""` would lose every name and no suite would see it.
static func slot_name_of(screen: CampaignScreen) -> String:
	var named: SaveSlotsScreen = screen as SaveSlotsScreen
	return named.typed_name if named != null else ""


## Load or save the numbered slot the player clicked.
func _use_slot(slot: int) -> void:
	if campaign == null:
		return
	if shell.slot_mode == ShellHost.MODE_SAVE:
		if campaign.state == null:
			_refresh_status("no campaign to save")
			return
		var written: bool = _save_mission_to(slot, world_to_save(),
			slot_name_of(_screen))
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
	# As in quick-load, do not arm local result routing for a nested mission
	# blob that may still be refused.
	_instant_action_mission = ""
	var blob: PackedByteArray = DictRead.to_bytes(decoded["mission"])
	if blob.is_empty():
		shell.close()
		close_campaign_screen()
		var _map: CampaignScreen = show_campaign_screen(
			_screen_between_missions())
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
	_remember_loaded_session()
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
	campaign.enter_mission(world)
	_resume_loaded_mission()
	_refresh_after_deploy()
	_open_after_load()
	_refresh_status("loaded slot %d" % (slot + 1))
	return true


## Restore the one piece of shell routing that is deliberately not part of a
## save's deterministic state. `CampaignState.mode` is persisted, so it is the
## authority after both quick-load and numbered-slot load; without rebuilding
## the latch, a loaded local battle ended through the campaign debriefing path.
## Where a session with no mission in it stands: a campaign on its map, an
## Instant Action squad in its HQ. A save with no nested blob is one of these,
## and Instant Action's HQ needs its mission standing behind it, so the load
## also arms the result route and builds the map the way the level list does.
func _screen_between_missions() -> String:
	_remember_loaded_session()
	if campaign != null and campaign.is_instant_action():
		campaign.settle_after_load()
		_build(campaign.current_mission())
		if world != null:
			campaign.frame_mission(world)
		return CampaignHost.SCREEN_HQ
	return CampaignHost.SCREEN_MAP


func _remember_loaded_session() -> void:
	if campaign != null and campaign.is_instant_action():
		_instant_action_mission = campaign.current_mission()
	else:
		_instant_action_mission = ""


## Step one option to its next value, apply it, and write the file.
##
## Every row here is click-to-cycle, which is also what the original's own
## option icons are. The write is immediate rather than on leaving the screen:
## a settings file that only appeared on a clean exit would lose the choice of
## anyone who closed the window.
func _step_option(name: String) -> void:
	if _leaving:
		return
	match name:
		"language":
			# The next of the cache's languages, written and then **loaded**:
			# every font, catalogue, plate and wave was read for the old one,
			# so the scene is rebuilt from the top rather than patched. The
			# row is offered only out of a mission ([OptionsScreen]), so
			# nothing unsaved is dropped by the reload.
			if _paths == null:
				return
			var offered: PackedStringArray = _paths.languages()
			if offered.size() < 2:
				return
			var at: int = offered.find(_paths.language)
			var next: String = offered[(at + 1) % offered.size()]
			settings.language = "" if next == _paths.base_language() else next
			var _saved: bool = settings.save_to_disk()
			_restart(next)
			return
		"controls":
			settings.control_mode = ((int(settings.control_mode) + 1) % 3) as GameSettings.ControlMode
			if _touch != null:
				_touch.cancel()
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
			# Audio changes are immediate already; the simulation half must be
			# equally real or this row becomes a partly inert control. The named
			# flags are saved with the world and included in its canonical hash.
			# The picture is a lagging clone, not an event consumer for settings,
			# so update both halves or the next completed command reports a false
			# mirror desync.
			settings.apply_gameplay_compat(world)
			settings.apply_gameplay_compat(_shown)
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


## Apply a slider movement while the thumb is still under the pointer, and
## write it immediately for the same reason the enumerated options are: a
## window closed without visiting `Back` must not lose the choice.
func _set_option_volume(channel: String, hundredths: int) -> void:
	var value: int = clampi(hundredths, GameSettings.VOLUME_MIN,
		GameSettings.VOLUME_MAX)
	match channel:
		"music":
			settings.music_volume = value
		"fx":
			settings.fx_volume = value
		"speech":
			settings.speech_volume = value
		_:
			return
	settings.apply_audio(_audio, _events)
	var _written: bool = settings.save_to_disk()


## Put the chosen font on everything that is already on screen.
##
## The screens take theirs at `setup` and the HUD at `_ready`, so a change made
## while one is up has to reach them. The plate that is up is rebuilt rather
## than patched: its labels were made with the old font and a screen is cheap.
## `font_0` .. `font_3`, in `fntID` order.
const GAME_FACES: Array[String] = ["font_0", "font_1", "font_2", "font_3"]


func _reapply_font() -> void:
	_faces = []
	var font: FontFile = interface_font()
	if _hud != null:
		_hud.use_font(font)
	if _texts != null:
		_texts.use_font(font)
	if _screen != null and shell.is_up():
		var _again: CampaignScreen = _show_shell_screen()
	elif _screen != null and campaign != null:
		var _back: CampaignScreen = show_campaign_screen(campaign.screen)


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
	if _audio != null:
		var _voice_stopped: int = _audio.stop_tag(VOICE_TAG)
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
	_apply_cursor()
	_frame_mission_camera()


## The mission camera's projection for the window the screen has now.
##
## With the interface up the window is what the plate leaves: `(60, 34)` by
## the canvas less 120 by the canvas less 140 (docs/43 section 8), and the
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
		# A plate over the mission -- the briefing read over a turn-0 map --
		# keeps the mission's own window, `0x0041A49E`'s 520 x 340.
		CameraRig.frame_projection(_rig.camera(), Rect2(HudTables.WINDOW),
			CampaignScreen.PLATE_SIZE)
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
		var slot: int = action.substr(5).to_int()
		var roster: UnitMenuScreen = _screen as UnitMenuScreen
		if roster != null:
			roster.pick(slot)
			campaign.upgrade_slot = slot
			# **And go there.** The Unit Menu's selection feeds one screen and
			# one only -- the Upgrade Menu opens on whichever soldier it names
			# -- so picking a row that then sat there doing nothing was the
			# screen keeping a secret. The Item List's own rows have the same
			# shape: choose, and the chooser closes behind you. The original
			# settles nothing here, `Menu_b.lcl` defining no layout for window
			# 4 at all, so this is the remake's call.
			var _to_upgrade: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_UPGRADE)
		return
	if action.begins_with("item:"):
		# The Item List is a chooser: it names the item and the Upgrade Menu
		# is where it is bought.
		campaign.item_id = action.substr(5).to_int()
		var listing: ItemListScreen = _screen as ItemListScreen
		if listing != null:
			campaign.item_kind = listing.kind
		var _back_to_upgrade: CampaignScreen = show_campaign_screen(
			CampaignHost.SCREEN_UPGRADE)
		return
	if action.begins_with("drop:"):
		# `buttons.LIB` 52 is a red cross, one per roster row: it dismisses
		# **that** soldier, and `Undo` beside the list puts the row back.
		var dismissing: UnitMenuScreen = _screen as UnitMenuScreen
		if dismissing != null:
			dismissing.remember()
			var _paid: int = campaign.dismiss(action.substr(5).to_int())
			campaign.upgrade_slot = Roster.NO_SLOT
			dismissing.selected = Roster.NO_SLOT
			dismissing.refresh()
		return
	if action.begins_with("category:"):
		var hiring: RecruitScreen = _screen as RecruitScreen
		if hiring != null:
			hiring.choose(action.substr(9).to_int())
		return
	if action.begins_with("hire:"):
		var hired: Dictionary = campaign.recruit_preset(
			action.substr(5).to_int())
		var window: RecruitScreen = _screen as RecruitScreen
		if window != null:
			window.refresh()
			# The engine's refusal is a red, disabled row (`0x00455EDF`);
			# the screen does that too, and says why (docs/27 section 3.2).
			var result: String = DictRead.as_string(hired["result"])
			if result != Upgrade.OK:
				window.say(window.strings_own(RecruitScreen.OWN_REFUSAL
					% result))
		return
	if action.begins_with("location:"):
		var parts: PackedStringArray = action.split(":")
		if parts.size() >= 3 and parts[2] == CampaignMap.KIND_BATTLE:
			var _shown: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_BRIEFING)
		elif parts.size() >= 3 and parts[2] == CampaignMap.KIND_UPGRADE:
			_enter_upgrade_location()
		elif parts.size() >= 3 and parts[2] == CampaignMap.KIND_DIALOGUE:
			# The dialogue arm of `aLocationHandling`: the framed sequence
			# screen on the logical id the location passes (docs/41
			# section 5); D5 is closed.
			var id: int = campaign.tables.dialogue_number(parts[1].to_int())
			var _dialogue: CampaignScreen = play_sequence(id, false,
				SEQUENCE_DIALOGUE)
		return
	match action:
		FlyInScreen.DONE:
			# `0x004fcbdc`: a key or a click lands the flight where it is,
			# and the Upgrade Menu follows exactly as it does when the eye
			# arrives by itself.
			_land_fly_in()
		SequenceScreen.DONE:
			_finish_sequence()
		SplashScreen.DONE:
			# The title dismissed: the menu, and its music.
			_hold_left = 0.0
			close_campaign_screen()
			var _menu: CampaignScreen = open_shell(ShellHost.SCREEN_MENU)
			_play_frontend_program("menu")
		CreditsScreen.BACK:
			_end_campaign()
		CreditsScreen.QUIT:
			_quit()
		ExtroScreen.CONTINUE:
			# `0x0045BD7F`: the wave stops with the screen and the credits
			# follow.
			if _audio != null:
				var _stopped: int = _audio.stop_tag(ExtroScreen.CONTINUE)
			var _credits: CampaignScreen = _show_credits()
		"enter":
			# `_build` takes the campaign map down. The mission is read
			# through [method CampaignHost.current_mission] because this arm
			# is one of the agent's debugging entries and can be reached from
			# the shell, where there is no campaign state to read.
			_build(campaign.current_mission())
			if world != null:
				campaign.begin_mission(world)
			_open_deployment_or_start()
		"debriefing":
			var _report: Dictionary = campaign.finish_mission(world)
			var _screen_up: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_DEBRIEFING)
		"instant_levels":
			_instant_action_mission = ""
			if campaign != null:
				campaign.abandon_mission()
				campaign.end()
			_clear_mission()
			shell.open(ShellHost.SCREEN_MISSION_SELECT, false)
			var _levels: CampaignScreen = _show_shell_screen()
		"instant_replay":
			var instant_mission: String = _instant_action_mission
			if instant_mission != "":
				_start_instant_action(instant_mission)
		"advance":
			var target: String = campaign.advance()
			if target != "":
				# `0x0045D436`: the debriefing's exit prints *Please Wait...*
				# while the map comes up.
				_show_message_then(func() -> void:
					var _map: CampaignScreen = show_campaign_screen(
						CampaignHost.SCREEN_MAP))
		"replay":
			var _again: String = campaign.replay()
			var _back: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_MAP)
		"resume":
			# The briefing read over a running mission, closed. Nothing else
			# changes: the mission is still standing behind it, on turn 0
			# or later.
			close_campaign_screen()
		"map":
			_leave_mission_for_map()
		"deploy":
			_deploy_instant_action()
		"options":
			# Into the shell, over the map. Leaving it puts the map back --
			# see [method close_shell] -- and the difficulty row is the
			# campaign's here rather than the settings' default.
			var _options: CampaignScreen = open_shell(
				ShellHost.SCREEN_OPTIONS)
		"hq":
			# From an Instant Action mission, the squad goes back to the
			# pool first; from the Upgrade Menu it is a change of screen.
			if campaign.is_instant_action() and in_mission():
				_return_to_instant_action_hq()
			else:
				var _hq: CampaignScreen = show_campaign_screen(
					CampaignHost.SCREEN_HQ)
		"recruit":
			# `0x0045B7F8`: in campaign mode the button hires on the spot and
			# the Recruit window is never raised.
			if campaign.recruits_through_a_screen():
				var _window: CampaignScreen = show_campaign_screen(
					CampaignHost.SCREEN_RECRUIT)
			else:
				var hired: UnitMenuScreen = _screen as UnitMenuScreen
				if hired != null:
					hired.remember()
				var _slot: int = campaign.recruit()
				if hired != null:
					hired.refresh()
		"roster_undo":
			var roster_screen: UnitMenuScreen = _screen as UnitMenuScreen
			if roster_screen != null:
				roster_screen.undo()
		"scroll_up", "scroll_down":
			var scrolled: UnitMenuScreen = _screen as UnitMenuScreen
			if scrolled != null:
				scrolled.scroll(-1 if action == "scroll_up" else 1)
		"upgrade", "select_unit":
			# One button either way: the Unit Menu's *Build squad* opens the
			# Upgrade Menu on the picked soldier, and the Upgrade Menu's
			# *Select Unit* goes back to the list to pick another.
			var target: String = CampaignHost.SCREEN_UPGRADE \
				if action == "upgrade" else CampaignHost.SCREEN_HQ
			var leaving: UpgradeScreen = _screen as UpgradeScreen
			if leaving != null:
				campaign.upgrade_slot = leaving.selected
			var _moved: CampaignScreen = show_campaign_screen(target)
		"select_weapon", "select_equipment":
			var from: UpgradeScreen = _screen as UpgradeScreen
			if from != null:
				campaign.upgrade_slot = from.selected
			campaign.item_kind = CampaignHost.KIND_WEAPONS \
				if action == "select_weapon" else CampaignHost.KIND_EQUIPMENT
			var _list: CampaignScreen = show_campaign_screen(
				CampaignHost.SCREEN_ITEMS)
		"toggle":
			var listing: ItemListScreen = _screen as ItemListScreen
			if listing != null:
				listing.toggle()
				campaign.item_kind = listing.kind
		"back":
			# The Item List's and the Recruit window's own way out, which is
			# back to whatever opened them.
			var target_screen: String = CampaignHost.SCREEN_UPGRADE \
				if _screen is ItemListScreen else CampaignHost.SCREEN_HQ
			var _returned: CampaignScreen = show_campaign_screen(target_screen)
		"buy", "undo", "commend", "prev_unit", "next_unit", "prev_item", \
				"next_item", "info", "rename":
			_upgrade_action(action)
		"save":
			# **Into the shell, over the map**, exactly as the *Options*
			# button above goes. It used to write the quick save and say
			# nothing at all -- the one file `F9` overwrites without asking --
			# so the button the map offers for saving looked broken and cost
			# the player the save they had taken with `F5`.
			shell.go_slots(ShellHost.MODE_SAVE)
			var _saving: CampaignScreen = open_shell(ShellHost.SCREEN_SLOTS)
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


## The Upgrade Menu's own buttons -- `0x0045A770`'s cases, which all act on the
## screen that is up rather than on the campaign's flow.
func _upgrade_action(action: String) -> void:
	var screen: UpgradeScreen = _screen as UpgradeScreen
	if screen == null:
		return
	match action:
		"buy":
			screen.buy()
		"undo":
			screen.undo()
		"commend":
			screen.commend()
		"prev_unit":
			screen.step_unit(-1)
		"next_unit":
			screen.step_unit(1)
		"prev_item":
			screen.step_item(-1)
		"next_item":
			screen.step_item(1)
		"info":
			screen.hints = not screen.hints
			screen.refresh()
		"rename":
			screen.begin_rename()
	campaign.upgrade_slot = screen.selected
	campaign.item_kind = screen.item_kind
	campaign.item_id = screen.item_id


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
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_go_back()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit()


## Android's *Back*, which must always mean something.
##
## `ESC` is [method _toggle_shell] and can afford to do nothing -- a desktop
## window has its own close button. `Back` is the only one the platform gives,
## and `quit_on_go_back` is off, so a `Back` that refused left no way out of the
## application at all: [method _toggle_shell] returns at once whenever the shell
## is up with nothing behind it, which is the boot menu **and** everything the
## boot menu leads to.
##
## So inside the shell this is the shell's own *Back* button, asked through
## [method ShellHost.back_from]; where that answers "stay put" -- the boot menu,
## with nothing behind and nowhere to go -- it leaves, which is what the
## notification did unconditionally before the shell existed.
func _go_back() -> void:
	if _touch != null:
		_touch.cancel()
	if shell.is_up():
		if not shell.behind and shell.back_from(shell.screen) == shell.screen:
			_quit()
		else:
			_on_shell_choice("back")
		return
	# With a campaign screen up and no shell this still does nothing, exactly
	# as `ESC` does: the screens carry their own way out and none of them is
	# named here.
	_toggle_shell()


func _quit() -> void:
	if _leaving:
		# A restart is on its way out over its own frames; it quits instead
		# of reloading once its audio and reply have been seen off.
		_quit_pending = true
		return
	_leaving = true
	if _audio != null:
		var _frames: int = await _audio.shutdown()
	get_tree().quit()


## Reload the whole scene in *language* -- the language switch's second half.
##
## [method _quit]'s recipe, with a reload where the quit is: the audio is
## shut down over its own frames first, or the Ogg stream it holds leaks
## (docs/97 section 14). **The agent's reply lands first.** `AgentBridge` is
## a child of this node and the reload frees it, which stops the server with
## the `press option:language` reply still parked -- so the bridge is given
## the same grace a `quit` gets ([method AgentBridge.wait_delivered]) before
## the tree goes. The choice rides on the root [Window]'s metadata, which the
## next `_ready` consumes first of all ([method _language_choice]).
func _restart(language: String) -> void:
	if _leaving:
		return
	_leaving = true
	restart_language = language
	if is_inside_tree():
		get_tree().root.set_meta(LANGUAGE_META, language)
	if _audio != null:
		var _frames: int = await _audio.shutdown()
	var bridge: AgentBridge = null
	var child: Node = get_node_or_null("AgentBridge")
	if child is AgentBridge:
		bridge = child
	if bridge != null:
		var _left: bool = await bridge.wait_delivered()
	if _quit_pending:
		get_tree().quit()
		return
	if reload_hook.is_valid():
		reload_hook.call()
		return
	if not is_inside_tree():
		return
	var reloaded: Error = get_tree().reload_current_scene()
	if reloaded != OK:
		push_error("language switch: reload_current_scene failed (%d)" % reloaded)


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
	if _status != null:
		_status.text = reason
	else:
		_show_fatal_error(reason)
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
## `missions/<mission>/map.json` with the chosen language's unit names
## written over the base's -- the one helper both [method World.create] sites
## go through, so a backdrop's marines and a mission's squad are named alike.
## Names enter no hash, so the overlay moves nothing a save pins.
func _map_document(mission: String) -> Dictionary:
	var document: Dictionary = CacheLoader.read_json(
		"%s/missions/%s/map.json" % [_cache_dir, mission])
	if _paths == null or document.is_empty():
		return document
	return _paths.apply_unit_names(mission, document)


func _build_backdrop(mission: String) -> void:
	if _backdrop_root != null and _backdrop_mission == mission:
		return
	_clear_backdrop()
	var balance: Dictionary = _balance
	var map_document: Dictionary = _map_document(mission)
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
	# No [method World.load_sweep] here: this is a backdrop, not a battle map,
	# and the sweep reads *session* state -- who is playing -- which nothing
	# behind a plate has. The units themselves are another matter: `_C_XXX` and
	# `_C_YYY` really are 200 free slots each, but every `upgrade_N` places two
	# or three marines and the original walks them ([BackdropBodies]).
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

	# The base's own marines, docs/27 section 2.7.1. `_C_XXX`/`_C_YYY` place
	# nobody, so this is one code path and not a branch on the kind of map.
	_backdrop_bodies = BackdropBodies.new()
	_backdrop_bodies.name = "Marines"
	_backdrop_root.add_child(_backdrop_bodies)
	var _marines: int = _backdrop_bodies.build(_backdrop_world,
		_campaign_library(), _backdrop_rng)

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

	_backdrop_view = _read_camera_path(opening)
	_backdrop_waypoints = _read_camera_waypoints(opening)
	_build_backdrop_fires(mission, geometry, textures, opening)


## The camera an upgrade base's own script asks for -- `[eye, target]`, or
## empty where the scene names none.
##
## **This is what an upgrade location looks at, and it is per base.** Every
## `upgrade_N.lcl`'s whole `INIT MAP` is three or four `CreateCameraPath`
## lines: one `mode 0` look-at target and two to four `mode 1` waypoints
## (docs/20 section 10 item 2 has the record). `aPlayLocationAnimation_Upgrade`
## `0x00417510` builds the scene and hands it to `0x00417000`, which flies the
## eye down the waypoints with `aSetCameraPosition` `0x00403560` and makes one
## last call when the path runs out -- so the fly-in **comes to rest on the
## last waypoint**. Its caller then reads the camera back with `0x00403780`
## into `0x00510D2C..0x00510D40`, and `0x00455A40(0)` pushes those same six
## into `aSetCameraPosition` on every Mission Control frame. So the still view
## the HQ, the Unit Menu, the Item List and the Upgrade Menu sit over is the
## end of that flight.
##
## The chain map keeps the eye `0x0045D130` selects for the current mission's
## location: `_C_XXX.lcl` and `_C_YYY.lcl` set no camera themselves.
func _read_camera_path(opening: Dictionary) -> Array[Vector3i]:
	var target: Vector3i = Vector3i.ZERO
	var eye: Vector3i = Vector3i.ZERO
	var seen_target: bool = false
	var seen_eye: bool = false
	for entry: Variant in DictRead.as_array(opening.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if AudioEvents.name_of(event) != CREATE_CAMERA_PATH:
			continue
		var values: PackedInt32Array = SetpieceDriver._numbers(event)
		if values.size() < 5:
			continue
		var at: Vector3i = Vector3i(values[2], values[3], values[4]) \
			* CAMERA_PATH_SCALE
		if values[1] == CAMERA_PATH_TARGET_MODE:
			target = at
			seen_target = true
		elif values[1] == CAMERA_PATH_WAYPOINT_MODE:
			# The last one wins: that is where the flight stops.
			eye = at
			seen_eye = true
	if not seen_target or not seen_eye:
		return []
	return [eye, target]


## Every `mode 1` waypoint of an upgrade base's `INIT MAP`, in script order --
## the path `0x00417000` flies down before it rests on the last one.
func _read_camera_waypoints(opening: Dictionary) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for entry: Variant in DictRead.as_array(opening.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if AudioEvents.name_of(event) != CREATE_CAMERA_PATH:
			continue
		var values: PackedInt32Array = SetpieceDriver._numbers(event)
		if values.size() < 5 or values[1] != CAMERA_PATH_WAYPOINT_MODE:
			continue
		out.append(Vector3i(values[2], values[3], values[4]) * CAMERA_PATH_SCALE)
	return out


## Begin an upgrade base's arrival flight, and answer whether there is one.
##
## The eye opens on the **first** waypoint looking at the target, exactly as
## `0x00417000` does after its two opening `aGetCameraPath` calls, and steps
## down the rest. A base whose script names fewer than two waypoints has
## nothing to fly and goes straight to its resting view.
func _start_fly_in(then: Callable) -> bool:
	if _backdrop_rig == null or _backdrop_waypoints.size() < 2 \
			or _backdrop_view.size() != 2:
		return false
	_backdrop_rig.set_now(_backdrop_waypoints[0], _backdrop_view[1])
	_fly_next = 1
	_fly_leg_from = _backdrop_waypoints[0]
	_fly_velocity = Vector3i.ZERO
	_fly_smooth = FLY_SMOOTH_START
	_fly_first = true
	_fly_landed = false
	_fly_clock = 0.0
	_fly_then = then
	return true


## The flight's clock. `0x00417000` steps once per drawn frame and the front
## end draws at 20, so the step is counted rather than scaled by delta -- the
## arithmetic below is the engine's integer arithmetic and does not survive
## being run at 165 frames a second.
func _tick_fly_in(delta: float) -> void:
	if _fly_next <= 0:
		return
	_fly_clock += delta * FLY_FPS
	while _fly_clock >= 1.0 and _fly_next > 0:
		_fly_clock -= 1.0
		_fly_step()


## One drawn frame of the flight -- the body of `0x00417000`'s inner loop.
##
## The arithmetic is [method fly_advance]'s; what is left here is the path's
## own bookkeeping, which is the half that needs a rig and a screen.
func _fly_step() -> void:
	if _backdrop_rig == null or _fly_next >= _backdrop_waypoints.size():
		# The path ran out: `0x00417167`'s last `aSetCameraPosition` sets the
		# eye it already has, so the rest is wherever the flight stopped.
		_land_fly_in()
		return
	var step: Dictionary = fly_advance({
		"eye": _backdrop_rig.eye(),
		"velocity": _fly_velocity,
		"smooth": _fly_smooth,
		"leg_from": _fly_leg_from,
		"first": _fly_first,
		"landed": _fly_landed,
	}, _backdrop_waypoints[_fly_next],
		_fly_next == _backdrop_waypoints.size() - 1)
	_fly_velocity = DictRead.as_vector3i(step["velocity"])
	_fly_smooth = DictRead.as_int(step["smooth"])
	_fly_leg_from = DictRead.as_vector3i(step["leg_from"])
	_fly_first = DictRead.as_bool(step["first"])
	_fly_landed = DictRead.as_bool(step["landed"])
	if DictRead.as_bool(step["arrived"]):
		_fly_next += 1
		if _fly_next >= _backdrop_waypoints.size():
			_land_fly_in()
		return
	if DictRead.as_bool(step["stop"]):
		_land_fly_in()
		return
	_backdrop_rig.set_now(DictRead.as_vector3i(step["eye"]), _backdrop_view[1])


## One frame of the flight as arithmetic alone: the state in, the state out.
##
## **Static and pure so the suite runs this copy** and not a second
## transcription of the same law. `state` carries the eye, the velocity, the
## smoothing divisor, the leg's starting eye and the two flags; the answer
## carries those again, plus `arrived` -- the leg was reached on this frame,
## and the caller moves to the next waypoint -- and `stop`, the last leg's
## countdown having run out. `eye` in the answer is where the camera goes, and
## is the eye that came in on either of those two frames.
##
## `last_leg` is `local_50`, the flag `aGetCameraPath` sets on the final
## waypoint: only that leg counts itself down.
static func fly_advance(state: Dictionary, goal: Vector3i,
		last_leg: bool) -> Dictionary:
	var eye: Vector3i = DictRead.as_vector3i(state["eye"])
	var out: Dictionary = {
		"eye": eye,
		"velocity": state["velocity"],
		"smooth": state["smooth"],
		"leg_from": state["leg_from"],
		"first": state["first"],
		"landed": state["landed"],
		"arrived": false,
		"stop": false,
	}
	var away: Vector3i = goal - eye
	# The arrival test comes **before** the landing flag, as in the original:
	# a leg that is reached on the same frame the countdown ran out still
	# hands over to the next one.
	if absi(away.x) <= FLY_ARRIVAL and absi(away.y) <= FLY_ARRIVAL \
			and absi(away.z) <= FLY_ARRIVAL:
		out["leg_from"] = eye
		out["smooth"] = FLY_SMOOTH_START
		out["arrived"] = true
		return out
	if DictRead.as_bool(state["landed"]):
		out["stop"] = true
		return out
	var speed: int = FLY_SPEED
	if last_leg:
		var leg: int = _manhattan(DictRead.as_vector3i(state["leg_from"]), goal)
		speed = _manhattan(eye, goal) * FLY_SPEED / leg if leg > 0 else 0
		if speed < FLY_LANDED_SHARE:
			out["landed"] = true
	var direction: Vector3 = fly_direction(eye, goal)
	var want: Vector3i = Vector3i(int(direction.x * float(speed)),
		int(direction.y * float(speed)), int(direction.z * float(speed)))
	var velocity: Vector3i = DictRead.as_vector3i(state["velocity"])
	var smooth: int = DictRead.as_int(state["smooth"])
	if DictRead.as_bool(state["first"]):
		velocity = want / smooth
		out["first"] = false
	else:
		velocity += (want - velocity) / smooth
	if smooth > FLY_SMOOTH_FLOOR:
		smooth -= 1
	out["velocity"] = velocity
	out["smooth"] = smooth
	out["eye"] = eye + velocity
	return out


## The direction `0x0046d400` hands the flight, which is **not** a unit
## vector: the two horizontal components are divided by the larger of them, so
## the dominant axis is exactly one and the eye's speed is read off that axis
## alone. The vertical is the height difference over the horizontal distance
## with **all six coordinates in eighths** -- the arm the flight takes (its
## last argument is `push 1` at `0x004172b1`) runs `sar 3` over both z, both x
## and both y before it asks `0x0044ae10` for the hypotenuse, so the run is in
## eighths as well as the rise and the two eighths cancel. Shifting only the
## rise, as this did until 2026-09-09, divides by eight times the distance and
## leaves the eye crawling along the ground for the whole flight.
##
## Each coordinate is shifted **on its own**, as the original does: `sar` is an
## arithmetic shift and floors, so `(a >> 3) - (b >> 3)` is not `(a - b) >> 3`
## wherever the two remainders cross. GDScript's `>>` floors the same way, and
## the suite pins that on a negative coordinate -- nine of the fifteen bases
## carry one in their first waypoint.
static func fly_direction(eye: Vector3i, goal: Vector3i) -> Vector3:
	var dx: int = goal.x - eye.x
	var dy: int = goal.y - eye.y
	var across: float = 0.0
	if dx > 0:
		across = 1.0
	elif dx < 0:
		across = -1.0
	# `dVar2` is left at 1.0 when the two x are equal, so a purely vertical
	# leg takes the slope's own sign and the x component falls out as zero.
	var slope: float = 1.0 if dx == 0 else absf(float(dy) / float(dx))
	var along: float = 0.0
	if dy > 0:
		along = slope
	elif dy < 0:
		along = -slope
	var out: Vector3 = Vector3.ZERO
	var scale: float = maxf(absf(across), absf(along))
	if scale > 0.0:
		out.x = across / scale
		out.y = along / scale
	# `0x0044ae10(eye.x >> 3, eye.y >> 3, goal.x >> 3, goal.y >> 3)`. The
	# equal-height test in front of it is on the **unshifted** z, as at
	# `0x0046d4bc`.
	var run_x: int = (eye.x >> FLY_DIRECTION_SHIFT) \
		- (goal.x >> FLY_DIRECTION_SHIFT)
	var run_y: int = (eye.y >> FLY_DIRECTION_SHIFT) \
		- (goal.y >> FLY_DIRECTION_SHIFT)
	var flat: int = int(sqrt(float(run_x * run_x + run_y * run_y)))
	# The original divides here whatever the distance is; a leg short enough
	# for this to be zero is one the arrival test has already ended, so the
	# guard is the port's and nothing reaches it.
	if goal.z != eye.z and flat != 0:
		out.z = float((goal.z >> FLY_DIRECTION_SHIFT)
			- (eye.z >> FLY_DIRECTION_SHIFT)) / float(flat)
	return out


static func _manhattan(from: Vector3i, to: Vector3i) -> int:
	return absi(to.x - from.x) + absi(to.y - from.y) + absi(to.z - from.z)


## The flight is over. Where it stopped **is** the base's still view: its
## caller reads the camera back with `0x00403780` into `0x00510D2C..0x510D40`
## and mission control pushes those six back on every frame, so the Unit Menu,
## the Item List and the Upgrade Menu all sit over the last frame of the
## flight rather than over the last waypoint.
func _land_fly_in() -> void:
	_fly_next = 0
	_fly_clock = 0.0
	_fly_landed = false
	if _backdrop_rig != null and _backdrop_view.size() == 2:
		_backdrop_view[0] = _backdrop_rig.eye()
	var then: Callable = _fly_then
	_fly_then = Callable()
	if then.is_valid():
		then.call()


## Whether the base's camera is still on its way down the path.
func flying_in() -> bool:
	return _fly_next > 0



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
## `0x0045D130` maps the current mission's location to an authored eye, and
## [constant CameraRig.CAMPAIGN_TARGET] is shared by all of them. This is a
## table lookup and not a fit over whichever locations happen to be open.
##
## Still called every time the map is raised rather than once when the picture
## is built, because the mission's own rig takes the camera in between.
func _frame_map() -> void:
	if _backdrop_rig == null:
		return
	# `0x004554C9` zeroes the accumulator when the map is raised, so a turn
	# does not survive the mission that was entered from it.
	var location: int = campaign.tables.location_of(
		campaign.tables.mission_id(campaign.current_mission()))
	_backdrop_rig.reset_map_swing(location)
	_swing_carry = Vector2.ZERO
	# An upgrade base looks where its own `CreateCameraPath` left the flight,
	# and `0x004558F0` -- the turn -- is the *map's* frame callback alone, so
	# a base does not swing.
	if _backdrop_view.size() == 2:
		# A base's still view is where its arrival flight came to rest
		# ([method _land_fly_in]), and `0x00455A40(0)` pushes exactly that
		# back on every mission-control frame. The flight itself runs once,
		# when the location is entered, and not again when the player steps
		# between the base's screens.
		if _fly_next <= 0:
			_backdrop_rig.set_now(_backdrop_view[0], _backdrop_view[1])
		return
	_backdrop_rig.set_now(CameraRig.campaign_eye(location),
		CameraRig.CAMPAIGN_TARGET)


func _clear_backdrop() -> void:
	if _markers != null and _markers.get_parent() == _backdrop_root:
		_markers = null
	if _backdrop_root != null:
		remove_child(_backdrop_root)
		_backdrop_root.free()
	_backdrop_root = null
	_backdrop_view = []
	_backdrop_waypoints = []
	_fly_next = 0
	_fly_then = Callable()
	# The Upgrade Menu's bodies are opened against the backdrop's world set, so
	# a new chain has to open its own rather than draw the last one's meshes.
	_campaign_bodies = null
	_backdrop_rig = null
	_backdrop_world = null
	_backdrop_mission = ""
	# The pool and the sprites were children of the root that has just been
	# freed; the handles go with them, or the next frame ticks a freed node.
	_backdrop_bodies = null
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
	# The place interface's selection and its line are the mission's: a
	# refusal spoken on turn 0 would otherwise stand on the caption of the
	# next mission loaded, or of a mid-mission save.
	_deploy_slot = Roster.NO_SLOT
	if _hud != null:
		_hud.set_line("")
	# A save deferred past a sequence belongs to the mission that queued it
	# ([method _autosave]); the next mission's first idle frame would
	# otherwise take it.
	_autosaves_pending.clear()
	# The last turn's hand-back state belongs to the mission that is going
	# away: a second mission loaded after a turn was played would have taken
	# the *previous* mission's camera offset as the player's arrangement.
	_fog.clear()
	_shown = null
	_camera_offset_before_turn = Vector3i.ZERO
	_camera_mode_before_turn = CameraRig.View.UNIT
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
	_picture_stale = false
	_terrain_stale = false
	_playing_turn = false
	# A turn still being drawn when the mission goes -- `ESC`, *Main Menu*
	# -- is dropped, not skipped: `skip()` would land deltas on a mirror
	# that is about to go and finish into `_after_command` with no world.
	_playback.cancel()
	_ai_note = ""
	_drawn_terrain = {}
	_last_query = null
	world = null
	_selected = -1
	_selection_before_turn = -1
	# `0x00450C2D` clears the magnifier where the interface is built, so it
	# never carries from one mission into the next -- and the pointer goes
	# back with it, the shell's screens having no use for a crosshair.
	_magnifier = false
	_apply_cursor()
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
	_drop_sequence()
	_clear_backdrop()
	_clear_mission()
	_mission = mission

	var balance: Dictionary = _balance
	var map_document: Dictionary = _map_document(mission)
	if balance.is_empty() or map_document.is_empty():
		# **Not [method _fail].** That one raises the fatal overlay when the
		# status line is not up -- the release build -- and nothing takes it
		# down again, so a campaign that reached a mission the cache lacks
		# carried "Incubation could not start." over its map, its shell and
		# every mission after. A missing mission stops the campaign where it
		# stands (docs/92); the callers all test `world == null` and say so.
		var reason: String = "cache does not contain %s" % mission
		push_error(reason)
		_refresh_status(reason)
		return

	# The world set's placer models come from the geometry document, because
	# that is where the converter records which prototypes the set has: a
	# `SetGroundFire` outside `World_D00` must write nothing, exactly as the
	# engine's constructor refuses the name (docs/42 section 9.1).
	var set_name: String = DictRead.as_string(
		DictRead.as_dict(map_document["header"])["world_set"])
	world = World.create(map_document, balance, 1.0,
		DictRead.to_strings(_geometry_for(set_name).get("special_models", [])))
	# `ArenaMode` accepted a local session before `Leveloptions` loads its map.
	# The post-load sweep reads this session state, so it must be installed
	# before the sweep removes out-of-session records and recomputes survivors.
	# A direct `--mission=` keeps the historic no-campaign defaults instead.
	if campaign != null and campaign.is_instant_action():
		world.turn.mode = TurnState.MODE_LOCAL
		world.turn.player_count = campaign.state.player_count
		world.turn.player_kind = campaign.state.player_kind.duplicate()
	# The **same object**, not a copy: a switch flipped mid-mission has to
	# reach the world that is being played, and one turned on before the
	# first build has to reach every world after it.
	world.cheats = cheats
	# `0x00417D18` -- what `aLoadBattleMap`'s caller does with the map it has
	# just loaded, before anything else touches it: the units of players who
	# are not in the session come off, and every record left is handed to the
	# full derived-stat recompute. A `.lev`'s own ammunition, hit-point,
	# movement, fitness, armour, absorber and stimulant bytes are authored
	# values the engine overwrites here ([method World.load_sweep]).
	var _swept: int = world.load_sweep()
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
	# **The map has loaded; the mission has not started.** This is the view
	# player's first `aNextPlayerHandling`, and it is here rather than at any
	# entry site because the fog it leaves is what the deployment and
	# everything built below this line are drawn from.
	#
	# **The other half of the opening is the caller's**, because this one
	# cannot know it: `0x0041A073`'s arm turns on whether there is anybody in
	# the pool to place, and on the campaign's own path the live roster is
	# still in its mission-entry snapshot at this point -- `begin_mission`
	# restores it *after* this returns. So each entry calls
	# [method World.skip_deployment_turn] for itself once it knows, and a
	# mission the player deploys into stays on turn 0 until *Next player*
	# hands over (the place interface's exit, [method _on_hud_event]).
	#
	# **And the order is forced, not a convenience.** The engine's own first
	# `aNextPlayerHandling` calls `resetGameControl` `0x0043B770`, whose
	# `mov byte [0x509E1D], bl` zeroes the turn counter -- so
	# `aInitBattleGround`'s `setTurn(1)` cannot precede it and be seen. The
	# controller reaches the view player before the battle ground for exactly
	# that reason, and this pair is in the same order.
	#
	# **Fresh per mission**, because it describes the hand-over being drawn
	# and not the game: a mission entered while the last one's opening had
	# left it false would suppress the watched player's screen on the first
	# computer turn after it.
	_computer_played = true
	var _opened: TurnResult = world.open_mission()
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
	# **From here the picture reads the mirror.** The journal starts recording
	# after `INIT MAP`, whose own set pieces are presented above, so the first
	# clone is the mission as the player first sees it.
	world.enable_journal()
	_resync_shown()

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
	# **A mission opens with a unit selected**, as `aInitBattleGround` does:
	# `0x0041A738` asks `fcn.00471E00(1)` for one, and on the first turn
	# (`0x0041A74D`) puts the camera on it with `fcn.004510A0`'s `(8, 7, 0)` --
	# which is what [method _frame_units] just did. See [method
	# _resume_selection] for the same thing at the other end of a turn.
	_resume_selection()

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
## `Data.txt`'s blocks, built once and kept.
##
## The Upgrade Menu's *i* asks for them by the record's own letter, and so does
## the battle interface's magnifying glass ([method magnifier_page]) -- the
## same file, the unit family's digit instead of an item's. A cache made before
## the converter grew the document answers nothing, which is the *i* showing an
## empty box rather than the screen failing to open.
var _item_texts: InfoText = null


func _item_descriptions() -> InfoText:
	if _item_texts == null and _paths != null:
		_item_texts = InfoText.load_from(_paths, InfoText.DATA_DOCUMENT)
	return _item_texts


## What the plates click with, or null before a cache is open.
##
## **Not [method _open_audio].** That one stops everything that is sounding
## when it is asked quietly, and a screen is rebuilt on every button press --
## so raising a screen would have cut the music every time.
func interface_audio() -> AudioSystem:
	# **Opened here if nothing else has.** The sound layer used to be built
	# only for a mission and for the map's music, so the shell's own menu --
	# the first screen anybody sees -- had no buffers to click with.
	if _audio == null and not _cache_dir.is_empty():
		var opened: AudioSystem = _open_audio(false)
		settings.apply_audio(opened, _events)
	return _audio


func _open_audio(quiet: bool) -> AudioSystem:
	var tables: AudioTables = AudioTables.open(_paths)
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
	if _speech == null:
		_speech = SpeechPlayer.new()
	_speech.setup(tables)
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
			== AudioSystem.program_source(_backdrop_music):
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
	# What a seeker reads its target from (docs/28 section 7.7.1): the
	# **mirror's** unit map, because the picture is what the effect flies
	# through, and a unit the truth has already killed is still standing in
	# the frame the grenade is drawn in.
	arm_hooks.unit_map = Callable(self, "_seeker_target")
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
	# A debugging step past every screen, so nothing deploys into it and
	# nothing else will hand over: the silent arm, or the mission would sit
	# on turn 0 for good with no computer turn and a `0` on the plate.
	_skip_deployment_turn()


## Submits the movement query for one slot and highlights the answer.
## Public because a screenshot or a demo run drives the same path a click does;
## the scene never becomes the source of the selection either way.
func select_unit(slot: int, pass_friendlies: bool,
		event: String = "select", replace_view: bool = false) -> MoveMapResult:
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
	# fcn.004533D0 re-applies the current view on a successful selection:
	# the unit placement, eyes or map view, or the map's centre for overview.
	# It resets the distance accumulated while following a long walk.
	#
	# *replace_view* asks for [method _restore_camera_on] instead, and the
	# hand-back from the computer's turn is the one caller that does: what the
	# rig holds by then is not the player's arrangement but whatever the
	# replay's last shot camera left.
	if replace_view:
		_restore_camera_on(slot)
	elif _director != null:
		var _flight: float = _director.select(world, slot)
	# **`select.wav` is the camera's, not the click's** (docs/28 section 2.5):
	# `fcn.004533D0` re-applies the view mode on the new selection's cell and
	# the placer it picks plays it from inside that -- the unit view's
	# `fcn.004510A0` or the map view's `fcn.00450F60`; the eyes and the
	# overview are silent.
	_play_view_cue()
	# And the marine answers: argument 0 or 8 for a click, 1 for the cycle.
	_speak(event, slot)
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
## Selection re-applies the current camera mode, just as a click does.
## Returns the slot, or -1 when there is none.
func cycle_friendly() -> int:
	var slot: int = next_friendly_slot(world, _selected)
	if slot < 0:
		return -1
	var _map: MoveMapResult = select_unit(slot, false, "cycle")
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
## is the player's, on Left and Right.
##
## Nothing here is authoritative and nothing here is simulation: a camera that
## opened somewhere else would change no hash and no result.
## Which slots are still drawn with the visibility they had before the
## computer's turn -- [member UnitsView._held_visibility]'s set.
##
## Everybody is in it when the replay opens, and each slot leaves it once an
## event of its own has been **shown**: `current` is the slot the event now on
## screen belongs to, and it stays in the hold for the length of that event so
## that a walker keeps the answer it set off with. A slot the replay never
## names -- a marine standing still, an alien with nothing to do -- keeps its
## pre-turn answer for the whole replay, which is what the fog rule of
## docs/22 section 9 says: the pass runs on the hand-over and not in between.
##
## **The one exception is `aExecuteMove`'s mode 3**, the self-reveal at
## `0x0046E4BB`: a computer mover that can see somebody from the cell it
## starts on marks *itself* visible **before the first step**, and nothing
## rebuilds the fog until the hand-over, so it stays visible for the whole of
## its walk however the walk ends. `revealed` is that write, taken off the
## event's own [member MoveResult.seen_source]; the answer is forced to
## [constant Visibility.FULL] rather than released, because releasing would
## hand the slot the **end** of the turn -- and a walker that shows itself and
## then leaves the room ends the turn hidden.
## The hand-back's camera: the player's own arrangement when it still stands,
## and the view mode's own placement when it does not.
##
## The replay leaves the eye wherever docs/42 section 4.3's shot and reaction
## placements put it -- a metre and a half behind the alien that fired last,
## or across the map from it -- so a hand-back that kept the eye's offset from
## the target, as selection used to do, handed the turn back inside a
## marine's boots or off the
## edge of the level. The offset the player had is remembered instead
## ([method end_turn]) and put back, which changes nothing about a turn where
## the camera never moved.
##
## `fcn.004533D0` -- [method CameraDirector.apply_view_mode] -- is the fallback
## and the faithful reading: the eyes view has no offset of its own to keep,
## and an offset that would now put the eye inside the map's own heights is
## not an arrangement worth restoring.
func _restore_camera_on(slot: int) -> void:
	if _rig == null or _director == null or world == null:
		return
	# Overview is anchored to the map's centre, never to the selected unit.
	# Re-apply it even if the replay temporarily chose another view mode.
	if _camera_mode_before_turn == CameraRig.View.SCRIPT:
		var _overview: float = _director.view_overview()
		return
	var inputs: Dictionary = CameraDirector.unit_inputs(shown(), slot)
	var offset: Vector3i = _camera_offset_before_turn
	if inputs.is_empty() or offset == Vector3i.ZERO \
			or _camera_mode_before_turn == CameraRig.View.EYES:
		var _placed: float = _director.apply_view_mode(shown(), slot)
		return
	var obj: Vector3i = DictRead.as_vector3i(inputs["obj"])
	if not _rig.eye_is_inside(obj + offset):
		var _fallback: float = _director.apply_view_mode(shown(), slot)
		return
	_rig.set_view_mode(_camera_mode_before_turn)
	var _frames: int = _rig.fly(obj + offset, obj)


## The first frame of a mission the player has just deployed into --
## `aInitBattleGround`'s counter-1 arm (docs/43 section 4.5).
##
## The deployment is docs/42 section 2.4's **map** view, straight down,
## and it leaves the rig in it: a mission started from it opened on a top-down
## picture with nothing selected, so the panel was empty, the pad was dark and
## the camera keys answered in the same top-down view -- and the first thing
## that put any of it right was the hand-back at the end of the turn.
##
## `0x0041A738` asks `fcn.00471E00(1)` for a selection and `0x0041A74D`
## applies `fcn.004510A0`, the unit view, to it. The view mode is written
## **first** because it is what [method _restore_camera_on] re-applies: left
## on the deployment's map it would place the camera straight down again.
func _begin_mission_view() -> void:
	if world == null or _rig == null:
		return
	_rig.set_view_mode(CameraRig.View.UNIT)
	_frame_units(world)
	_resume_selection()


## The camera pan, from wherever it was asked for: the middle-button drag
## and the four keys of docs/42 section 2.5.
func _pan_by(pixels: Vector2) -> void:
	if _rig == null or not is_inside_tree():
		return
	_rig.pan(pixels, get_viewport().get_visible_rect().size.x)


func _frame_units(mission_world: World) -> void:
	# **One unit's cell, not the squad's centroid.** The centroid is not a cell
	# anybody stands on: on `_C_140` the mean of four marines lands inside the
	# wall between them, and the camera opens in the dark. A unit's own cell is
	# somewhere the simulation has already agreed is standable and open.
	#
	# The placement is the engine's "on the unit" view, `(8, 7, 0)` from the
	# current quadrant with the free-position search (docs/42 section 2.3),
	# settled at once because there is no previous view to fly from.
	# **The engine's own first unit**, so the unit the view opens on and the
	# unit the interface opens with selected are the same one.
	var slot: int = first_friendly_slot(mission_world)
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


## The current player's first selectable unit -- `fcn.00477CE0`, the search
## `0x004721F0` runs whenever the interface is asked to move the selection and
## there is none.
##
## **Two passes, and the second one drops the movement test.** The first takes
## the lowest-numbered live unit of the side that still has movement points;
## only if the side has none does it take the lowest-numbered live one. That
## second pass is why the original always has somebody selected even at the
## end of a turn on which everything has moved. Returns -1 when the side has
## no live unit at all, which is `0x00477CE0`'s own `0xFFFF`.
static func first_friendly_slot(mission_world: World) -> int:
	if mission_world == null:
		return -1
	for slot: int in mission_world.unit_slots():
		if mission_world.may_select(slot):
			return slot
	for slot: int in mission_world.unit_slots():
		if mission_world.may_command(slot):
			return slot
	return -1


## Put the selection back when the turn comes back to the player.
##
## **The engine never drops the selection.** `[0x005162F0]` is written to
## `0xFFFF` in exactly two places -- `fcn.004710E0`, once, from
## `aInitBattleGround`, and the arm of `0x004721F0` that finds the side has no
## unit at all -- and the hand-over is neither, so the marine the player last
## had is still selected when the computer is done. Anything that asks to move
## the selection while there is none takes [method first_friendly_slot]
## instead (`0x004721F0`'s own first branch), so the interface is never left
## with nothing.
##
## The remake clears the selection for the length of the replay, because the
## watched screen has no panel, no pad and no overlay to show it on
## (docs/43 section 7). This puts it back: the same unit if the computer left
## it alive and able to move, and the side's first otherwise.
##
## **It moves the camera onto the unit**, through [method select_unit], which
## is what a select does in the original: `fcn.004533D0` re-applies the current
## view mode on the new selection's cell. [constant COMPAT_CAMERA_RETURNS] is
## a different thing -- the remake's own camera return with *no* selection
## behind it -- and stays off by default.
func _resume_selection() -> void:
	if world == null or shown().game_control.mission_ended():
		return
	# **Nothing before the first hand-over.** `fcn.00471E00` refuses while
	# the counter is 0 (docs/43 section 4.5), so a mission opens on turn 0
	# with nobody selected; the place interface's own pick is the pool's.
	if world.deploying():
		return
	var slot: int = hand_back_slot(shown(), _selected, _selection_before_turn)
	_selection_before_turn = -1
	if slot < 0:
		return
	# The **ask** speaks only for a unit that has not moved: `0x00471F44` sits
	# behind `unit[+0x15] >= fcn.00475160(unit)` inside `fcn.00471E00`, so a
	# marine that spent part of its allowance last turn is picked in silence
	# (docs/28 section 4.3). The click site has no such gate.
	var moved: bool = DictRead.as_int(shown().unit_view(slot)["mp"]) \
		!= shown().movement_allowance(slot, shown().turn.ai_level)
	var _map: MoveMapResult = select_unit(slot, false,
		"" if moved else "select", true)


## The whole hand-back rule, as one pure function: which unit to select now,
## or -1 for "leave it alone".
##
## **A selection that already stands is left alone.** The hand-back runs from
## the playback's finish callback whether the turn drew anything or not, and
## re-running the select on a standing selection would put the camera on a
## second unit and speak over the first line.
static func hand_back_slot(mission_world: World, selected: int,
		previous: int) -> int:
	if selected >= 0:
		return -1
	return resumed_slot(mission_world, previous)


## Which unit the turn comes back on: *previous* while the computer left it
## alive and able to move -- the engine's global, which no hand-over writes --
## and [method first_friendly_slot] otherwise, which is `0x004721F0`'s own
## answer to an empty selection. -1 when the side has nobody at all.
##
## Static and pure so the rule can be checked against a real world without a
## scene: it is the whole of the fix, and the branch that matters is the one a
## drive cannot stage on demand -- the previously selected marine being dead.
static func resumed_slot(mission_world: World, previous: int) -> int:
	if mission_world == null:
		return -1
	if previous >= 0 and mission_world.may_select(previous):
		return previous
	return first_friendly_slot(mission_world)


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
## The zoom and the yaw are **not** touched. They are the player's, on Left,
## Right and the wheel; only [method _frame_units] sets them, and only at load.
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


## Present one journal event: the body it is about, the sequence it queues,
## the sound it makes.
##
## **One arm per kind the journal marks** (docs/100 section 3). The event
## brought everything the picture needs -- a `move` its route, a `fire` its
## weapon as it was when the trigger was pulled, a `reaction` its reactor and
## the mover that drew it, a `mine` its blast -- because by the time the
## playback reaches event *i* the truth is at the end of the command and the
## mirror has not yet landed the events before *i*. Nothing is re-derived.
##
## Returns how long the event needs on screen: the walk's own length, the
## shot's deterministic frames, the set piece's frames. Zero for an arm that
## queued nothing -- the playback then goes straight on -- and zero for the
## `use` and `heal` events, whose set pieces are queued by the command that
## submitted them and hold the playback through the picture's own `busy`.
func _play_event_body(event: Dictionary, kind: String) -> float:
	var slot: int = DictRead.as_int(event["slot"])
	var payload: Dictionary = DictRead.as_dict(event["payload"])
	var at_x: int = DictRead.as_int(event["x"])
	var at_y: int = DictRead.as_int(event["y"])
	var to_x: int = DictRead.as_int(event["tx"])
	var to_y: int = DictRead.as_int(event["ty"])
	match kind:
		"move":
			if _units == null or not payload.has("path"):
				return 0.0
			# docs/42 section 3.2: the walk's mode is decided from what the
			# mover would see -- `aBuildVisibleMapForUnit` `0x004794B0` from
			# the destination and from the source -- and the camera follows
			# from the mode. **The answers ride on the event.** They are the
			# writing passes `core` ran at the moment of the move, when every
			# unit of that moment was still standing. The player's own unit
			# walks in mode 1 whatever it sees.
			#
			# **The path's own end, not the event's `tx`/`ty`.** They are the
			# same cell on every walk but one: a walk that ended on a
			# teleporter entry reports the **exit** it was relinked to
			# (docs/97 section 41.2), and the camera has to fly to where the
			# body is about to walk, not to where it will reappear.
			var path: PackedInt32Array = DictRead.to_int32(payload["path"])
			var last: int = path[path.size() - 1] if not path.is_empty() \
				else -1
			var end_x: int = last % shown().resource.width if last >= 0 else to_x
			var end_y: int = last / shown().resource.width if last >= 0 else to_y
			var mode: CameraDirector.WalkMode = CameraDirector.walk_mode(
				_is_own(slot),
				DictRead.as_bool(payload.get("seen_source", false)),
				DictRead.as_bool(payload.get("seen_destination", false)))
			# Mode 0 draws no frames in aExecuteMove. The playback still
			# lands the delta, but must not start a walk, sound or hold.
			if mode == CameraDirector.WalkMode.NONE:
				return 0.0
			var delay: float = _camera_before_walk(slot, at_x, at_y, end_x,
				end_y, mode)
			return delay + _walk_body(slot, path,
				DictRead.as_int(payload.get("steps", 0)), delay)
		"mine":
			# The mine under the stop cell, or under the landing: `aExecuteBomb`
			# runs inside `aExecuteMove` (`0x0046EDAF`) and `aExecuteWarp`
			# (`0x0046F109`) after the last step has been drawn, and the walk
			# before it is a separate event the picture has finished with.
			return _present_blast(slot, at_x, at_y,
				DictRead.as_dict(payload.get("blast", {})))
		"teleport":
			# `0x0046EE03` is inside `aExecuteMove`, so the stream plays as
			# part of the move (docs/97 section 41.2); the walk's own events
			# name the entry and the exit.
			var events: Array[Dictionary] = []
			for entry: Variant in DictRead.as_array(payload.get("events", [])):
				events.append(DictRead.as_dict(entry))
			return float(_present_teleport(slot, events)) \
				/ SequenceQueue.FRAMES_PER_SECOND
		"warp":
			# docs/42 section 7.1: the jump, with the player's own trail and
			# waves or one of three screams for the computer's. The event's
			# cells are the routine's own arguments; the mine under the landing
			# and the `MoveUnit` hook are the events behind this one.
			var frames: int = _present_jump(slot, Vector2i(at_x, at_y),
				Vector2i(to_x, to_y), _is_own(slot))
			return float(frames) / SequenceQueue.FRAMES_PER_SECOND
		"fire":
			# **The weapon comes from the event, not from the mirror.** The
			# record no longer holds it: a jam clears it, a close-combat swap
			# has been reverted, and an alien killed by reaction fire after
			# its own shot has no view left by the end of the turn.
			# `World.submit_attack` and `AIFire` both write the weapon the
			# animation was **played with** into the note, which for a stab is
			# the bayonet and not the gun that was aimed (docs/97 section 24
			# as corrected 2026-09-09).
			return _present_attack(slot, at_x, at_y, to_x, to_y,
				DictRead.as_string(event["note"]).to_int(),
				AttackResult.from_dict(payload))
		"reaction":
			# One event per shot of the drain (docs/100 section 3): the
			# event's own cell is the reactor's, its target the mover's, and
			# the mover's slot rides in the payload for the camera. A shot
			# that emptied the magazine or hit the heat cap plays the jam
			# orbit after it (docs/42 section 7.4).
			var seconds: float = _present_attack(slot, at_x, at_y, to_x, to_y,
				DictRead.as_string(event["note"]).to_int(),
				AttackResult.from_dict(DictRead.as_dict(payload.get("attack", {}))),
				true, DictRead.as_int(payload.get("mover", MapState.NO_UNIT)))
			if DictRead.as_bool(payload.get("jammed", false)):
				_present_jam(slot)
			return seconds
		"parabomb":
			# `aAI_SpecialPlayerControl` `0x0040B2D0` is the fuse and nothing
			# else: it calls `aExecuteBomb` `0x004702C0` and
			# `aRemoveUnitElement` `0x004779C0`, and no sound routine at all.
			# So the computer's para bomb is **one blast on its own cell**,
			# shown by the presenter the walk's mine and the jump's landing
			# already use, with `Combat.BOMB_WEAPON`'s own cues. The payload
			# *is* the blast -- `AISpecialPlayer` writes `AttackResult.to_dict()`
			# straight into it -- and the blast's death stage is what takes
			# its dead off the screen.
			return _present_blast(slot, at_x, at_y, payload)
		"door":
			# The computer's opener passes real tiles too (docs/42 section 8):
			# the flight from its head to the panel, when the picture can
			# queue; the sound alone when it cannot.
			var cues: Array[Dictionary] = _events.for_event_kind("open_door") \
				if _events != null else ([] as Array[Dictionary])
			if _sequences != null and world != null:
				_queue_setpiece({"name": "open_door", "values": [to_x, to_y]},
					SetpieceDriver.DOOR_FRAMES, cues, slot)
				return float(SetpieceDriver.DOOR_FRAMES) \
					/ SequenceQueue.FRAMES_PER_SECOND
			if _audio != null and not cues.is_empty():
				var _door: PackedInt32Array = _audio.play_cues(cues, "ai")
			return 0.0
		"ground":
			# The round's ground sweep (docs/42 section 9.1): every glow that
			# reached phase 1 burns, and `aPlayGroundFireAnimation`
			# `0x004157B0` is played **on each ignited cell in turn**. `core`
			# carries each one's victims with their tiles, taken before the
			# removal, because the picture reads a map they have already
			# left.
			#
			# Nothing was drawn here at all until 2026-09-09: `_C_116` lays a
			# glow a round and the red patches simply vanished two rounds
			# later, in silence.
			return _present_ground_fire(payload)
		"fire_heat_blocked":
			# The computer's weapon at its heat cap: the jam's wave and no
			# picture (docs/23 section 6).
			if _audio != null and _events != null:
				var _jam: PackedInt32Array = _audio.play_cues(
					_events.for_event_kind("reaction_jam"), "ai")
			return 0.0
		"script":
			# Every LCL run is a boundary (docs/42 section 10): a `MoveUnit`
			# hook that dropped a footbridge, the turn's own `NEXT TURN` and
			# `NEXT PLAYER`, the tube a mission opens. The set pieces it fired
			# go on the queue and the event stays on screen for their length.
			var _shown_script: int = _present_script(payload)
			return _script_seconds(payload)
		"use":
			# docs/42 section 8: the door's flight from the user's head, the
			# lever's handle, the supply box's lid, the push's slide. The
			# payload is the use's own result and the target is the event's.
			return _present_use(slot, payload, Vector2i(to_x, to_y))
		"heal":
			# Presented by the command that submitted it: the heal orbit is
			# already on the queue, and the picture's own `busy` holds the
			# event until it has played.
			return 0.0
	return 0.0


## The round's ignited glows, one `aPlayGroundFireAnimation` each.
##
## Returns the seconds the whole sweep needs on screen -- the set pieces are
## queued in order and the queue plays them one after another, which is what
## the engine's own blocking calls do.
##
## **One cue, not two.** `EVENT_SITES["ground_fire"]` has two
## `aAnimationCreateSoundBuffer` sites because the routine makes two buffers;
## it plays exactly one of them. `test al, 1` at `0x00415AC3` reads the
## counter the 0..8 collection loop incremented **nine** times, so the branch
## is never in doubt and the second buffer is only ever killed. Playing both
## would say `gfire.wav` twice.
func _present_ground_fire(payload: Dictionary) -> float:
	var burnt: Array = DictRead.as_array(payload.get("burnt", []))
	if burnt.is_empty() or world == null:
		return 0.0
	var cues: Array[Dictionary] = _events.for_event_kind("ground_fire") \
		if _events != null else ([] as Array[Dictionary])
	if cues.size() > 1:
		cues = cues.slice(0, 1)
	var seconds: float = 0.0
	for entry: Variant in burnt:
		var lit: Dictionary = DictRead.as_dict(entry)
		var values: Array[int] = [DictRead.as_int(lit["x"]),
			DictRead.as_int(lit["y"])]
		var victims: Array = DictRead.as_array(lit.get("victims", []))
		values.append(victims.size())
		for who: Variant in victims:
			var victim: Dictionary = DictRead.as_dict(who)
			values.append_array([DictRead.as_int(victim["slot"]),
				DictRead.as_int(victim["x"]), DictRead.as_int(victim["y"])])
		if _sequences == null:
			if _audio != null and not cues.is_empty():
				var _fire: PackedInt32Array = _audio.play_cues(cues, "script")
			continue
		_queue_setpiece({"name": "ground_fire", "values": values},
			SetpieceDriver.POOL_ONLY_FRAMES, cues)
		seconds += float(SetpieceDriver.POOL_ONLY_FRAMES) \
			/ SequenceQueue.FRAMES_PER_SECOND
	return seconds


## Whether the unit is one of the player's own, as the mirror has it: the
## camera modes and the jump's cues tell the two apart (docs/42 sections 3.2
## and 7.1).
func _is_own(slot: int) -> bool:
	var view: Dictionary = shown().unit_view(slot)
	return not view.is_empty() \
		and DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN


## Walk a body along the cells a move actually entered.
##
## The duration is [constant WALK_SECONDS_PER_STEP] a step, so a long walk
## takes longer than a short one. It is presentation: the truth has already
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
	_units.start_walk(slot, route, shown().resource.width, seconds,
		_footstep_period(slot), delay)
	return seconds


## The camera before a walk (docs/42 section 3.2), and the mode remembered
## for the frames that follow. Returns how long the walk has to wait for the
## flight. A ride hides the walker for the duration, as the engine does.
func _camera_before_walk(slot: int, from_x: int, from_y: int, to_x: int,
		to_y: int, mode: CameraDirector.WalkMode) -> float:
	if _director == null or _units == null:
		return 0.0
	var view: Dictionary = shown().unit_view(slot)
	if view.is_empty():
		return 0.0
	var delay: float = _director.before_walk(shown(), view, from_x, from_y, to_x,
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
		var view: Dictionary = shown().unit_view(slot)
		var height: int = 0
		if not view.is_empty():
			height = shown().unit_types().body_height_world(
				DictRead.as_int(view["type_id"]))
		var destination: int = _units.walk_destination(slot)
		var there: Vector3i = Vector3i.ZERO
		if destination >= 0:
			there = CameraRig.cell_object(destination % shown().resource.width,
				destination / shown().resource.width,
				shown().state.height_at(destination))
		_director.track(_units.drawn_position(slot), height, mode, there)


## The step period for a walk about to start, and the cue cached beside it.
##
## Zero for the 39 silent unit types, and zero for a Squeether that walks
## before anything else has: the period is one global and it starts at zero.
func _footstep_period(slot: int) -> int:
	if _events == null or world == null:
		return 0
	var view: Dictionary = shown().unit_view(slot)
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


## The special objects still standing ([method Scenery.object_count]) and the
## cells a set piece has freed ([method Scenery.removed_count]).
##
## Both exist for the driven session: [method scenery_count] is what was
## *built*, which is a constant for the life of a mission, so a crush wall or
## a footbridge that took its object away moved no number anything outside the
## game could read.
func scenery_objects() -> int:
	return 0 if _scenery == null else _scenery.object_count()


func scenery_removed() -> int:
	return 0 if _scenery == null else _scenery.removed_count()


## [member _last_script], copied.
func last_script() -> Dictionary:
	return _last_script.duplicate(true)


static func _event_names_of(outcome: Dictionary) -> Array[String]:
	var names: Array[String] = []
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		names.append(AudioEvents.name_of(AudioEvents.as_event(entry)))
	return names


## The developer line: the cache, the scene and the hash. **Not** user-facing
## text, which is why it is not in [Localization] -- it names a mission file, a
## world set and a digest, and translating any of those would be wrong.
func _refresh_status(extra: String = "") -> void:
	_status_note = extra
	if world == null:
		# No mission, so there is no line to build -- but a message still has
		# somewhere to go, which is what the shell needs when a slot refuses
		# before any world exists.
		if extra != "" and _status != null:
			_status.text = extra
		return
	var line: String = "%s (%d/%d)  %dx%d  %s/%s  %d units  scenery %d  hash %s" % [
		world.resource.mission, _missions.find(_mission) + 1, _missions.size(),
		world.resource.width, world.resource.height,
		world.resource.world_set, world.resource.world_scene,
		world.unit_slots().size(), scenery_count(),
		world.canonical_hash_hex().substr(0, 12)]
	# **The mission names are not listed.** A cache published with
	# `--campaign-maps` carries 92 of them, and naming every one turned the
	# developer line into a wall of text across the playing screen. The
	# position in the set is already on the line above -- `(1/92)`.
	#
	# **And neither are the keys.** A second line of them used to run across
	# the playing screen; the interface has a hint line of its own at (60, 22)
	# and every key that belongs to a button is now written there, under the
	# pointer ([constant HudTables.EVENT_KEYS]).
	if extra != "":
		line += "\n" + extra
	if _status != null:
		_status.text = line
	if _hud != null:
		var axes: Array[Vector2] = _radar_axes()
		# The last argument is the same gate [method _check_mission_end]
		# makes: while the replay or the picture is still running, what ended
		# the mission has not been drawn yet, so the report panel waits.
		_hud.refresh(shown(), _selected, Callable(self, "_event_available"),
			Callable(self, "_command_available"), axes[0], axes[1], _bands,
			_magnifier, _watching(shown()),
			_playback.is_running() or _picture_busy(), _deploy_record())
		if _hud.progress_stepped():
			_play_progress()
		# **Inside the window, under the top band.** The developer line is a
		# tool and not part of the plate, so it goes where the plate is not.
		if _status != null:
			_status.position = Vector2(float(HudTables.WINDOW.position.x) + STATUS_GAP,
			_hud.bottom() + STATUS_GAP)


## One tick of `progress.wav` -- `0x0047DA6B`, the sound the original makes
## every time the watched turn's bar moves a step.
##
## It is played straight rather than through [AudioEvents]: `aInitViewPlayer`
## loads the wave into a buffer of its own and plays it with a bare zero, so
## there is no volume-control id to look up and no event table entry to read.
## One of the mission interface's own clicks (docs/28 section 2.5).
##
## The wave is the cache's: the original reaches it through the module global
## `aInitBattleGround` put the handle in, and the conversion has already done
## that join.
func _play_interface(action: String) -> void:
	if _audio == null:
		return
	var cue: Dictionary = _audio.tables().interface_cue(action)
	if cue.is_empty():
		return
	var _slot: int = _audio.play_cue(cue)


## The wave the view placer the current mode reaches plays from inside
## itself (docs/43 section 4.5's table): `select.wav` for the unit view
## (`fcn.004510A0`) and the map view (`fcn.00450F60`, also every mode's
## fallback with no selection), nothing for the eyes (`fcn.00451150`) and the
## overview (`fcn.00453410`).
static func view_cue_for(mode: CameraRig.View) -> String:
	match mode:
		CameraRig.View.UNIT:
			return AudioTables.INTERFACE_VIEW_UNIT
		CameraRig.View.MAP:
			return AudioTables.INTERFACE_VIEW_MAP
	return ""


func _play_view_cue() -> void:
	if _rig == null:
		return
	var action: String = view_cue_for(_rig.view_mode())
	if not action.is_empty():
		_play_interface(action)


## What *slot* says about *event*, if anything (docs/28 section 4.3).
##
## Silence is the common answer and is not a failure: a speech id no arm names
## -- which is what an ordinary spawn leaves behind -- and a drawn index that
## names no shipped file both end here with nothing played.
func _speak(event: String, slot: int) -> void:
	if _audio == null or _speech == null or world == null:
		return
	if slot < 0 or not shown().has_unit(slot):
		return
	# One voice at a time: `0x0047B6F2` kills the buffer **before** the next
	# name is built, so a second marine cuts the first one off -- including
	# when the name it then builds resolves to no shipped file at all, which
	# is why this is in front of the line rather than behind it.
	var _stopped: int = _audio.stop_tag(SPEECH_TAG)
	var cue: Dictionary = _speech.line(event, shown().unit_view(slot),
		shown().turn.current_player)
	if cue.is_empty():
		return
	var _slot: int = _audio.play_cue(cue, SPEECH_TAG)


func _play_progress() -> void:
	if _audio == null:
		return
	var cue: Dictionary = _audio.tables().view_player_cue(
		AudioTables.VIEW_PLAYER_PROGRESS)
	if cue.is_empty():
		return
	var _slot: int = _audio.play_cue(cue)


## The watched side's turn, for the progress bar of docs/43 section 8: empty
## while the seat is the player's own, and `{"player", "acted", "live"}` while
## the computer's turn is being drawn.
##
## The seat is the **mirror's**, not the truth's and not the playback's: the
## computer's turn runs inside [method World.submit_end_turn] and hands over
## again by itself, so `world.turn.current_player` is back on the marines
## before the first alien is drawn moving -- and the player's own commands go
## through the same playback, so "a playback is running" is not "the computer
## holds the turn". The mirror holds 255 from the hand-over that opened the
## turn until the one that closed it, which is exactly the watched span.
func _watching(at: World) -> Dictionary:
	if at == null or not _computer_played \
			or at.turn.current_player != TurnState.PLAYER_COMPUTER:
		return {}
	var player: int = at.turn.previous_player
	var counts: Vector2i = TurnProgress.tally(at, player)
	return {"player": player, "acted": counts.x, "live": counts.y}


## Whether the picture is drawing the computer's turn: the mirror's seat is
## the computer's **and** the computer was given a turn to take. The key that
## skips the turn, the note that says so and the agent's `replay` all read
## this and not the playback, which a player's own command runs through too.
##
## The second half is `0x0047D600`'s own gate: the rotation hands the computer
## its slot whether or not it may play, and `aAISystemControl` is called only
## `if (g_turn != 0)`. The mission's opening hand-over is exactly that case --
## it passes through the computer's seat at turn 0 to reach turn 1 (see the
## `"start"` arm of [method _on_campaign_choice]) -- and without this the
## first thing a deployed mission drew was `_C_106`'s platform ride under a
## bare plate captioned *the aliens are moving*, with nothing of the interface
## up and one key able to skip it.
func _watching_the_computer() -> bool:
	return world != null and _computer_played \
		and shown().turn.current_player == TurnState.PLAYER_COMPUTER


## One key press of the pan, as the pixels of middle-button drag it stands
## for ([method CameraRig.pan] scales them the way the original does).
const PAN_KEY_PIXELS: float = 24.0

enum DebugKeyAction {
	NONE,
	QUICK_SAVE,
	QUICK_LOAD,
	FIELD_TYPES,
	LATTICE,
	NEXT_MISSION,
	PREVIOUS_MISSION,
}


## The hidden keyboard tools available to a debug build. Pure so a suite can
## prove that every one maps to [constant DebugKeyAction.NONE] in release.
static func debug_key_action(keycode: int, debug_build: bool) -> int:
	if not debug_build:
		return DebugKeyAction.NONE
	match keycode:
		KEY_F5:
			return DebugKeyAction.QUICK_SAVE
		KEY_F9:
			return DebugKeyAction.QUICK_LOAD
		KEY_Y:
			return DebugKeyAction.FIELD_TYPES
		KEY_F8:
			return DebugKeyAction.LATTICE
		KEY_BRACKETRIGHT:
			return DebugKeyAction.NEXT_MISSION
		KEY_BRACKETLEFT:
			return DebugKeyAction.PREVIOUS_MISSION
	return DebugKeyAction.NONE


func _run_debug_key(action: int) -> void:
	match action:
		DebugKeyAction.QUICK_SAVE:
			quick_save()
		DebugKeyAction.QUICK_LOAD:
			quick_load()
		DebugKeyAction.FIELD_TYPES:
			_overlay.toggle()
		DebugKeyAction.LATTICE:
			_scenery.toggle_lattice()
		DebugKeyAction.NEXT_MISSION:
			show_mission(1)
		DebugKeyAction.PREVIOUS_MISSION:
			show_mission(-1)


## How far one trackpad pan event moves the zoom.  Pan deltas arrive in "lines"
## and a flick sends many, so this is deliberately small.
const PAN_ZOOM: float = 0.25
## Pinch: `factor` above 1 is a spread, which zooms in.
const MAGNIFY_ZOOM: float = 6.0


## Option/Alt provides trackpad access without a secondary-button drag.
## Gesture deltas are scroll units; their scale is the remake's binding.
static func look_delta_for(event: InputEvent) -> Vector2:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		if motion.button_mask & MOUSE_BUTTON_MASK_RIGHT \
				or (motion.alt_pressed and motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
			return motion.relative
	if event is InputEventPanGesture:
		var gesture: InputEventPanGesture = event
		if gesture.alt_pressed:
			return gesture.delta * 8.0
	return Vector2.ZERO


## How much one input moves the zoom, or zero when it is not a zoom input.
## Pure so both mouse and platform-specific trackpad events can be tested.
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


## The classic keyboard pan: arrows only. Plain Left/Right turn a quadrant in
## `_unhandled_input`; Shift makes those two arrows pan sideways.
static func pan_delta_for_key(keycode: int, shift_pressed: bool) -> Vector2:
	match keycode:
		KEY_UP:
			return Vector2(0.0, -PAN_KEY_PIXELS)
		KEY_DOWN:
			return Vector2(0.0, PAN_KEY_PIXELS)
		KEY_LEFT:
			if shift_pressed:
				return Vector2(-PAN_KEY_PIXELS, 0.0)
		KEY_RIGHT:
			if shift_pressed:
				return Vector2(PAN_KEY_PIXELS, 0.0)
	return Vector2.ZERO


func _process(delta: float) -> void:
	# The front end's own clocks: a hold between two screens, and a cutscene's
	# 30 fps frame counter. Neither has a world behind it.
	_tick_hold(delta)
	_tick_sequence(delta)
	_tick_fly_in(delta)
	# The location map is a picture with a clock of its own: no simulation
	# behind it, and nothing below this line applies to it.
	if _backdrop_bodies != null:
		_backdrop_bodies.tick(delta)
	_tick_backdrop_fires(delta)
	_tick_backdrop_swing()
	if _playback.is_running():
		var _going: bool = _playback.advance(delta, _picture_busy())
	# Whatever landed on the mirror since the last frame is drawn once, before
	# the bodies move: a delta a presenter landed mid-sequence has already
	# been flushed by it, and this is for the ones the playback landed.
	_flush_picture()
	_drain_deferred_repaints()
	if _units != null:
		_units.animate(delta, shown(), _rig != null
			and _rig.eye().z >= UnitsView.FREEZE_HEIGHT)
		_play_footsteps()
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
			# The event the queue was drawing is over: its delta lands if it
			# has not already, and the picture held for its length -- the
			# terrain, the bodies -- is redrawn from the mirror at once.
			_land_current_delta()
			# Whoever the queue was delivering has arrived.
			if _units != null:
				var _shown: int = _units.reveal_all()
				var _dropped: int = _units.drop_lifts()
	_draw_effects()
	# **After the picture, never inside a command.** The last point is often
	# spent by a walk, and ending the turn in the frame the walk was ordered
	# would start the computer's replay over a body still crossing a field.
	if _auto_end_pending and not _picture_busy() and not _playback.is_running():
		_auto_end_pending = false
		if _auto_end_turn_wanted():
			var _ended: TurnResult = end_turn()
	# Whatever the queue held a save back from, once nothing is being drawn.
	_flush_autosaves()
	_check_mission_end()


## The mission that ended reaches its own debriefing, by itself.
##
## The campaign loop docs/27 closes was open at exactly this step: the
## `"debriefing"` action had two senders, a button on a screen that is never
## up during a mission and the agent server, so a mission won in the game simply
## stopped on a dead map.
##
## `screen == SCREEN_MISSION` is the campaign once-guard -- [method
## CampaignHost.finish_mission] moves it on. Instant Action retains a saveable
## local state, so its mission-name latch takes precedence as a separate
## once-guard and raises a report whose exits lead only to replay or levels.
func _check_mission_end() -> void:
	if world == null or not _mission_over():
		_result_held = false
		return
	# The picture goes first. The shot that ended the mission is still being
	# drawn, and a plate dropped over it would cut it off mid-explosion. The
	# report panel behind the plate waits on the same test -- see
	# [method MissionHud._show_result] -- so the frame the hold lifts on is
	# also the frame the interface has to be told about.
	if _picture_busy() or _playback.is_running():
		_result_held = true
		return
	if _result_held:
		_result_held = false
		# **With the note the last command left.** A bare `_refresh_status()`
		# clears it, and this runs on the frame the mission ends -- so the
		# line the player most wants to read (`3, 1 reactions`, or why an
		# order was refused) was wiped at exactly that moment. Nothing here
		# is saying anything new; it is a redraw.
		_refresh_status(_status_note)
	if _instant_action_mission != "" and _screen == null:
		_show_instant_action_result()
		return
	if campaign == null or campaign.state == null or _screen != null:
		return
	if campaign.screen != CampaignHost.SCREEN_MISSION:
		return
	_on_campaign_choice("debriefing")


## Raise the ordinary report with Instant Action's own exits. The campaign
## scorer cannot run here: a local battle must not update campaign totals or
## recover its throw-away squad into a persistent roster.
func _show_instant_action_result() -> void:
	if world == null:
		return
	var outcome: int = world.game_control.mission_result(0)
	var board: ScoreRecord = ScoreRecord.new()
	board.result = outcome
	board.kills = world.turn.mission_kills[0]
	board.losses = world.turn.mission_lost[0]
	board.lost_to_enemy = world.turn.mission_lost_to_enemy[0]
	var result: DebriefingScreen = DebriefingScreen.new()
	result.instant_action = true
	result.report = {
		"result": outcome,
		"equipment_points": 0,
		"commendations": 0,
		"recovered": [],
		"lost": [],
	}
	result.board = board
	_play_frontend_program("debriefing")
	result.setup(_art, _strings, interface_font(), interface_faces(),
		interface_audio())
	result.chose.connect(_on_campaign_choice)
	add_child(result)
	_screen = result
	_sync_hud()


## Whether the turn should end by itself: the player holds it, the mission is
## running, and no unit of theirs has a movement point left.
##
## See [method _after_command] for what this is and is not. It answers the
## same question [method next_friendly_slot] does -- `may_select` is
## `0x00477D40`'s three tests plus the points -- so a squad with one marine
## still holding a single point keeps the turn.
##
## **Points, not commands, and that is enough.** `submit_attack` has no
## movement gate of its own: it fires and *then* subtracts the weapon's action
## points (`0x0046C308`'s 8-bit spend, and the world's clamp above it). What
## keeps a spent marine from shooting anyway is the **selection**: a unit with
## no points cannot be selected (`0x00471CB6`), [method _after_command] drops
## the selection the moment its last point goes (`0x00472B10`), and every
## order the player can give starts from a selection. So a squad with no
## points has nothing left it can be asked to do.
func _auto_end_turn_wanted() -> bool:
	if world == null or not _may_command_now() or _playback.is_running():
		return false
	if _screen != null or shell.is_up():
		return false
	# **Somebody has to be left to have spent anything.** A squad that is wiped
	# out answers "no unit with a movement point" for ever, and the
	# turn would then end itself again the moment each replay finished: the
	# rounds would run past the player as fast as the computer can play them.
	if not _has_live_unit(turn_player()):
		return false
	return next_friendly_slot(world, -1) < 0


## Whether `player` still has a unit alive on the map.
func _has_live_unit(player: int) -> bool:
	if world == null:
		return false
	for slot: int in shown().unit_slots():
		var view: Dictionary = shown().unit_view(slot)
		if view.is_empty() or DictRead.as_int(view["player"]) != player:
			continue
		if DictRead.as_int(view["hp"]) > 0:
			return true
	return false


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


## One event of a playback, the computer's turn or the player's own command:
## bring the picture level, present it, and say what it was when the player
## is watching rather than commanding.
##
## An empty dictionary means the playback is over. Nothing here touches the
## world: it has held the post-command state since `core` returned, which is
## what makes skipping free.
##
## Returns how long this event should stay on screen; see
## [method EventPlayback._step].
func _on_ai_step(event: Dictionary) -> float:
	if event.is_empty():
		_ai_note = ""
		var was_turn: bool = _playing_turn
		_playing_turn = false
		# **The mirror must be the truth by now.** Every delta of the command
		# has landed; if one did not carry something, this is where it is
		# caught and put right rather than drawn wrong for the rest of the
		# mission.
		var _level: bool = _check_mirror()
		_fog.viewer = _watching_seat()
		if was_turn:
			# The turn is the player's again. **The engine moves no camera
			# here** (docs/42 section 2.6), so neither does this unless the
			# compatibility flag asks for the remake's own return -- see
			# [method focus_on_friendly] for what that was for.
			if world != null and world.compat_flags.has(COMPAT_CAMERA_RETURNS):
				var _back: int = focus_on_friendly(_rig, world)
		_after_command(_command_note)
		_command_note = ""
		if was_turn:
			# The turn is the player's again, so somebody of theirs is
			# selected again -- `0x004721F0`'s own rule, and the reason the
			# original never hands a turn back with an empty panel.
			_resume_selection()
		return 0.0
	var kind: String = DictRead.as_string(event["kind"])
	# **The picture first.** The mirror stands where this event begins --
	# every delta before it has landed, this one has not -- and the bodies
	# are rebuilt from it before the presenter reads it: the reveals of a
	# walk's opening passes are drawn in the frame the walk starts, and the
	# casualties this event is about to make are still standing.
	_flush_picture()
	# **No camera per event here.** The pivot used to be put on every
	# event's cell, which flew the player to hidden aliens the fog was
	# keeping from them; the camera belongs to the presentation of each
	# event (docs/42 sections 3.2 and 4.3), which knows what may be seen.
	var hold: float = _play_event_body(event, kind)
	if _watching_the_computer():
		# The watcher's line, and the key that ends the watching: only while
		# the computer holds the turn. A player's own command says nothing
		# until it is over, when [method _after_command] writes its note.
		_ai_note = "%s -- %s %d  (%s)" % [_strings.text("hud.ai_turn"),
			_strings.text("ai." + kind) if _strings.has("ai." + kind) else kind,
			DictRead.as_int(event["slot"]), _strings.text("touch.skip"
				if _touch != null and _touch.enabled() else "hud.ai_skip")]
		_refresh_status(_ai_note)
	else:
		# The interface goes dark for the length of the command -- the
		# original's `aPlayFightAnimation` takes the input with it -- and
		# comes back with the note when the playback drains.
		_refresh_status(_status_note)
	return hold

func _unhandled_input(event: InputEvent) -> void:
	# Nothing is acted on while the audio is being given its frames before a
	# quit or a language restart: the scene under this key is on its way out.
	if _leaving:
		return
	# **The hidden code line goes before `ESC`**, because while it is open it
	# owns the keyboard: `ESC` has to cancel the entry rather than raise the
	# shell over a half-typed code.
	#
	# **Opening it is behind every guard below**, and that is not tidiness:
	# a line opened while the computer's turn is being drawn would swallow the
	# skip key, and a `nuke` typed into it would write the truth under a
	# playback still landing pre-nuke deltas on the mirror. So the *open* key
	# is only read when a command would be read, and [method apply_cheat_code]
	# refuses the one code that writes anything for the same reason -- the
	# control server reaches it without passing here at all.
	if _debug_build and event is InputEventKey and event.is_pressed():
		var typed: InputEventKey = event
		if _cheat_entry.is_open():
			_on_cheat_key(typed)
			return
		if typed.keycode == CheatEntry.OPEN_KEY and _screen == null \
				and _may_command_now() and not _playback.is_running() \
				and (_hud == null or not _hud.info_visible()):
			_on_cheat_key(typed)
			return
	# `ESC` goes **before** the screen guard, and that ordering is the whole
	# of the fix: the guard below returns before anything else runs, so with a
	# plate up no key reached the game at all and the shell would have been a
	# room with no door. Only `ESC` is let past; everything else still belongs
	# to whatever is on screen.
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		var pressed: InputEventKey = event
		if pressed.keycode == KEY_ESCAPE:
			_toggle_shell()
			return
	# A campaign screen owns the rest of the input while it is up: without
	# this the mouse reached the 3D pick behind the plate and selected units
	# through it. A screen drawn **around a window** wants exactly that pick
	# back, for the part of the picture its own frame does not cover.
	if _screen != null:
		# The wheel and the trackpad first: a screen with a list answers them
		# and a screen drawn around a hole does not, so the map keeps the
		# camera's zoom on exactly the same event.
		if _screen.take_scroll(event):
			_remember_slot_page()
			return
		_screen_input(event)
		return
	if world == null:
		return
	# **The pickup message holds the mission.** `0x0041BB44` asks
	# `0x0043E730` whether a text box is up and returns from the mission's
	# input handler at once when it is, so nothing else answers.
	#
	# This is the **keyboard** half of that hold. The mouse half cannot live
	# here: a `Control` answers a click before `_unhandled_input` ever sees
	# it, so the plate's own buttons would have gone on working behind the
	# message -- [member MissionHud._info_shield] is what stops them, and it
	# is what takes the message down (`0x0043F130`).
	if _hud != null and _hud.info_visible():
		return
	# A playback holds the input while it is being shown -- the original's
	# `aPlay*` routines block. During the computer's turn one key ends the
	# showing; the world does not change either way. A player's own command
	# is not skippable: the engine's blocking loops take no key, and a walk
	# the player cut short would leave nothing behind but a snapped body.
	if _playback.is_running():
		if event is InputEventKey and event.is_pressed() \
				and not event.is_echo() and _watching_the_computer():
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
	var look: Vector2 = look_delta_for(event)
	if not look.is_zero_approx():
		_rig.look_by(look)
		return
	var zoom: float = zoom_delta_for(event)
	if not is_zero_approx(zoom):
		_rig.zoom_by(zoom)
		return
	if event is InputEventKey and event.is_pressed():
		var key: InputEventKey = event
		# **The interface's own keys come from the interface's own table**
		# (docs/43 section 5): the columns' fifteen and the pad's six, and
		# the same table the hint under the pointer is drawn from. They are
		# looked up first, so a button's key reaches the button whatever else
		# this chain grows -- and pressing it is pressing the button, gate,
		# click and all, which a hand-written branch beside it was not.
		#
		# The classic binding owns D/S/W for the command pad. Camera movement
		# therefore stays on arrows and mouse, with no WASD fall-through.
		var hud_event: int = HudTables.event_for_key(key.keycode)
		var pad_command: int = HudTables.command_for_key(key.keycode)
		var debug_action: int = debug_key_action(key.keycode, _debug_build)
		var pan_delta: Vector2 = pan_delta_for_key(key.keycode, key.shift_pressed)
		# **A held key repeats only the pan.** The OS's key repeat arrives as
		# echo events, and every screen drops them (`campaign_map_screen.gd`
		# and the rest) -- here they were commands: ENTER held for a second
		# ended a turn, skipped the replay through the branch above and
		# ended the next. Panning is the one thing that *wants* the repeat,
		# having no polling of its own.
		if key.is_echo():
			if not pan_delta.is_zero_approx():
				_pan_by(pan_delta)
		elif hud_event >= 0:
			_on_hud_event(hud_event)
		elif pad_command >= 0:
			_on_pad_command(pad_command)
		elif debug_action != DebugKeyAction.NONE:
			_run_debug_key(debug_action)
		elif key.keycode == KEY_SPACE:
			_centre_camera_on_unit()
		elif not pan_delta.is_zero_approx():
			_pan_by(pan_delta)
		elif key.keycode == KEY_LEFT:
			_rig.rotate_step(-1)
		elif key.keycode == KEY_RIGHT:
			_rig.rotate_step(1)
	elif event is InputEventMouseButton and event.is_pressed():
		var click: InputEventMouseButton = event
		if click.button_index == MOUSE_BUTTON_LEFT and not click.alt_pressed and _may_command_now():
			_pick(click.position, click.shift_pressed)
	elif event is InputEventMouseMotion:
		# docs/42 section 2.5: the middle button held drags the view.
		var motion: InputEventMouseMotion = event
		if motion.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan_by(motion.relative)
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
	# Only the chain map turns. An upgrade base's camera is the resting point
	# of its own fly-in and nothing in `0x0045C7D0`'s arms calls `0x004558F0`.
	if _backdrop_view.size() == 2:
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
		# **The map turns a different way from a mission.** A mission's Left
		# and Right step the rig's quadrant; the map's fixed base eye comes from
		# `0x0045D130`, and `0x004558F0` swings it about the target by an
		# accumulated angle instead, which is a drag rather than a step -- see
		# [method _swing_backdrop].
		if on_backdrop and (key.keycode == KEY_LEFT or key.keycode == KEY_RIGHT):
			_swing_backdrop(Vector2(
				CameraRig.MAP_KEY_TURN if key.keycode == KEY_RIGHT
				else -CameraRig.MAP_KEY_TURN, 0.0))
		elif not on_backdrop and key.keycode == KEY_LEFT:
			rig.rotate_step(-1)
		elif not on_backdrop and key.keycode == KEY_RIGHT:
			rig.rotate_step(1)
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
		# **The map's own drag is the right button**, not the middle one:
		# `0x00455560` gates on `0x00511B09`, which the message pump's own
		# table `0x0040BD58` writes 1 on `WM_RBUTTONDOWN` and
		# `WM_RBUTTONDBLCLK` and 0 on `WM_RBUTTONUP` -- docs/27 section 2.6.1.
		# `0x0045558C` then reads the pointer's travel since the last frame,
		# doubles it for the turn and multiplies it by -50 for the height, and
		# warps the cursor back to where the drag began so the next frame's
		# reading is fresh again. The middle button is kept beside it because
		# docs/42 section 2.5 makes it the remake's drag everywhere else and
		# nothing on this screen answers it.
		if on_backdrop and (motion.button_mask
				& (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)) != 0:
			_swing_backdrop(motion.relative)
			return
		# docs/42 section 2.5: the middle button held drags the view, here as
		# in a mission.
		if motion.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
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
		# The campaign map raises the location's band badge over the cell
		# (docs/27 section 2.6.3); the deployment screen rings the free cell.
		var map: CampaignMapScreen = _screen as CampaignMapScreen
		if map != null:
			_markers.badge(_art, cell,
				CampaignMapScreen.badge_for(map.location_at(cell), false))
		else:
			_markers.ring(_art, cell)


## docs/42 section 2.4's three views while the mission is on turn 0.
##
## [method _set_view] cannot be used: it frames a **unit**, and until the
## first soldier is placed the player has none on the map. The deployment
## area is the subject instead, and the map view is what turn 0 opens in --
## the original deploys from above (docs/43 section 4.5's counter-0 arm).
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
	# A soldier already on the map is the better subject. Before the first is
	# placed there is nothing to frame but the landing area, so each view's
	# own placement is made over its centre instead of over a body.
	var slot: int = next_friendly_slot(world, -1)
	if slot >= 0:
		var _flown: float = _director.view_eyes(world, slot) \
			if mode == CameraRig.View.EYES else _director.view_unit(world, slot)
		_rig.settle()
		return
	var view: Dictionary = world.cell_view(at.x, at.y)
	var centre: Vector3i = CameraRig.cell_object(at.x, at.y,
		DictRead.as_int(view["height"]))
	if mode == CameraRig.View.EYES:
		var _eyes: int = _rig.view_eyes(centre, 0, Vector2i(0, 1))
		_rig.settle()
		return
	var goal: Dictionary = _rig.place_on_unit(centre, 0, Vector2i(0, 1),
		8, 7, 0)
	_rig.set_view_mode(mode)
	_rig.set_now(DictRead.as_vector3i(goal["eye"]),
		DictRead.as_vector3i(goal["target"]))
	_rig.settle()


## docs/42 section 2.4's three selected-unit views, on the original's keys 2,
## 3 and 4. Key 1 is the separate whole-map overview. The eyes and unit
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
	# The placer's own wave: `select.wav` from the unit and map placers, none
	# from the eyes (docs/28 section 2.5).
	var action: String = view_cue_for(mode)
	if not action.is_empty():
		_play_interface(action)
	_sync_hud()


## Space in the original: bring the camera back to the selected unit, using
## the other of its two close views. From eyes it goes to the on-unit view;
## from every other mode it goes to the unit's eyes (`0x0041BAB0`).
func _centre_camera_on_unit() -> void:
	if _rig == null:
		return
	_set_view(CameraRig.View.UNIT
		if _rig.view_mode() == CameraRig.View.EYES else CameraRig.View.EYES)


## Whether the mission has ended -- in which case no command is taken any more.
##
## [method World.may_command] is the rule and refuses every slot once the
## game-control slots are set; this is the same rule read once, so that a click
## on a friendly unit does not fall through to the "not yours, so shoot it"
## branch and so that the three keyed commands stop with it. Rotating, zooming
## and the two overlays keep working: the map is still worth looking at.
func _mission_over() -> bool:
	return world != null and world.game_control.mission_ended()


## Whether a command may be given at all: the mission is running **and a human
## holds the turn**.
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
##
## The question is [method TurnState.is_human] and not "is the holder 255":
## `aNextPlayerHandling` leaves view state 0 up for a **human**, and a session
## with two human seats -- which [member TurnState.player_kind] can describe and
## nothing in the remake yet builds -- would otherwise let either seat spend the
## other's turn. Player 255 still fails it, so a campaign is unchanged.
func _may_command_now() -> bool:
	if world == null or _mission_over():
		return false
	return world.turn.is_human(world.turn.current_player)


## The ray a click casts into the world, or nothing at all: no camera, or a
## direction so flat that no cell's plane meets it.
##
## Both readers of it -- [method _pick] and the magnifier -- ask the same
## question of the same ray, so a click cannot pick one unit and magnify
## another.
func _ray_at(screen: Vector2) -> PackedVector3Array:
	var camera: Camera3D = _rig.camera() if _rig != null else null
	if camera == null:
		return PackedVector3Array()
	var ray: PackedVector3Array = CameraRig.ray_through(camera, screen,
		get_viewport().get_visible_rect().size)
	if ray.size() != 2 or absf(ray[1].y) < 0.0001:
		return PackedVector3Array()
	return ray


## The unit a ray lands on, or -1: the nearest drawn body whose cell centre the
## ray passes within [constant PICK_RADIUS] of.
func _unit_under(ray: PackedVector3Array) -> int:
	if ray.size() != 2 or shown() == null:
		return -1
	var origin: Vector3 = ray[0]
	var direction: Vector3 = ray[1]
	var best_slot: int = -1
	var best_distance: float = INF
	# The **fresh** pass, the one [method UnitsView.build] draws from: the
	# stored `+0x4F` is as the last hand-over left it, and a unit walked into
	# view has to be clickable in the frame it appears in.
	var seen: Dictionary[int, int] = shown().display_visibility()
	for slot: int in shown().unit_slots():
		var view: Dictionary = shown().unit_view(slot)
		if seen.has(slot):
			view["visibility"] = seen[slot]
		# **Only what is on screen may be clicked.** The engine picks over
		# drawn *objects*, and it has fewer of them than the picture has
		# records: `aKillUnit` `0x00472920` deletes the object of whatever it
		# kills, and `aBuildVisibleMap` never gives a hidden unit one. Walking
		# every record instead cost two different clicks:
		#
		# * a corpse still in `unit_slots()` was picked in front of the live
		#   unit beside it, and since it is neither commandable nor a target
		#   ([method is_a_target] refuses no hit points) the click answered
		#   *not your unit* while the cell next to it shot perfectly well;
		# * a **hidden** alien was pickable, so a click on what looks like
		#   empty floor fired at something the player cannot see.
		#
		# A unit held past its death ([method UnitsView.is_dying]) is on
		# screen and stays pickable for as long as it is drawn.
		if not Fog.is_drawn(view):
			continue
		# The mirror keeps a casualty until the delta that killed it lands, so
		# a dead record here is one the picture has finished with.
		if DictRead.as_int(view["hp"]) == 0:
			continue
		var x: int = DictRead.as_int(view["x"])
		var y: int = DictRead.as_int(view["y"])
		var cell: Dictionary = shown().cell_view(x, y)
		var centre: Vector3 = WorldSpace.cell_centre(x, y,
			DictRead.as_int(cell["height"]))
		var t: float = (centre.y - origin.y) / direction.y
		if t <= 0.0:
			continue
		var hit: Vector3 = origin + direction * t
		var distance: float = hit.distance_to(centre)
		if distance < PICK_RADIUS and distance < best_distance:
			best_distance = distance
			best_slot = slot
	return best_slot


## Whether the magnifying glass is on -- `[0x005106CC]`, for the driver.
func magnifier_on() -> bool:
	return _magnifier


## The pointer the mode asks for.
##
## `0x0045391C` calls `0x0045F030(10)` when the mode goes on and `(0)` when it
## goes off. That routine has two paths: on the windowed one it is a Windows
## cursor -- `IDC_CROSS` `0x7F03` against `IDC_ARROW` `0x7F00`
## (`0x0045F040`/`0x0045F05A`) -- and on the other it is frame 10 of the
## engine's own cursor library. This remake draws no cursor of its own, so the
## windowed answer is the one it can give.
func _apply_cursor() -> void:
	var shape: Input.CursorShape = Input.CURSOR_ARROW
	# **Only over the mission view.** The shape is process-global, so a shell
	# screen raised over a running mission -- `ESC`, the save slots, the
	# options -- would otherwise be pointed at with a crosshair until the
	# mission was actually left. [method _sync_hud] is the seam both ways.
	if _magnifier and _screen == null:
		shape = Input.CURSOR_CROSS
	Input.set_default_cursor_shape(shape)


## The unit the magnifier answers for under this click, or -1.
##
## The engine reads the **cell's** own occupant (`0x00432AB0`: `0x0042F730`
## for the control-map element, then the unit id at its `+0x07`). This asks
## the body first and the cell second, because the remake's ordinary click
## picks bodies ([method _unit_under]) and two picks that disagreed would
## magnify one alien while the click before it selected another.
func magnifier_slot(ray: PackedVector3Array, screen: Vector2) -> int:
	var slot: int = _unit_under(ray)
	if slot < 0 and shown() != null:
		# **The mirror's cells, not the truth's.** [method _cell_under] casts
		# against [member world], whose heights run ahead of the picture while
		# a lift or a falling roof is still being drawn -- and the occupancy
		# read below is the mirror's. Asking one world both questions is the
		# whole point of this path.
		var cell: Vector2i = cell_under(_rig.camera(), shown(), screen)
		if cell.x >= 0:
			slot = shown().state.unit_at(
				shown().state.index_of(cell.x, cell.y))
	if not magnifier_answers(slot):
		return -1
	return slot


## `0x00432AB0`'s two tests on the unit it found: `+0x45` is 255 -- the
## computer's seat, which is what "a visible alien" means here -- and `+0x4F`
## is 0, fully visible. A contact beam is not an alien the player can look at,
## and neither is a marine.
func magnifier_answers(slot: int) -> bool:
	if slot < 0 or shown() == null or not shown().has_unit(slot):
		return false
	var view: Dictionary = shown().unit_view(slot)
	if DictRead.as_int(view["player"]) != TurnState.PLAYER_COMPUTER:
		return false
	# The same fresh pass [method _unit_under] picks with, **for the seat that
	# is watching** ([method _seat_of]): a pass for player 255 is the aliens'
	# own view of the map, in which every alien is a body.
	var seen: Dictionary[int, int] = shown().display_visibility(
		_seat_of(shown()))
	var state: int = DictRead.as_int(view["visibility"])
	if seen.has(slot):
		state = seen[slot]
	return state == Fog.FULL


## The page `Data.txt` holds for a unit's type, `[]` where there is none.
func magnifier_page(slot: int) -> Array:
	var texts: InfoText = _item_descriptions()
	if texts == null or shown() == null or not shown().has_unit(slot):
		return []
	var type_id: int = DictRead.as_int(shown().unit_view(slot)["type_id"])
	return texts.unit_page(shown().unit_types().info_key(type_id))


## Open that page, in the box `0x00432B20` asks for.
##
## It does **not** take itself down after five seconds the way a pickup's
## message does ([method MissionHud.show_info]): that timeout is there so a
## crate opened by mistake cannot hold the mission, and this box was asked
## for. A click anywhere still dismisses it.
func _show_magnifier_page(slot: int) -> void:
	if slot < 0 or _hud == null:
		return
	var page: Array = magnifier_page(slot)
	if page.is_empty():
		return
	# The heading is the **unit's own name**, which is what `0x00432B20`
	# hands `0x0043E850` as its eighth argument: the unit record, whose
	# `+0x00` is a `char[20]` defaulting to the type's description
	# (docs/10 section 5.2). So a named alien is named and the rest carry
	# their species.
	_hud.show_info(page, InfoText.DATA_BOX_SIZE.y, false,
		DictRead.as_string(shown().unit_view(slot)["name"]))


## Turns a screen position into a map field, then asks the world about it.
## The scene tree is used to find *which* cell was clicked and for nothing else.
func _pick(screen: Vector2, pass_friendlies: bool) -> void:
	# **Turn 0 is the place interface's.** The original runs its click
	# handler after the ordinary one (`0x0041BE0D`, then `0x0041BEC8`), but
	# the ordinary one selects nothing before the first hand-over and the
	# magnifier's arm is inside it, so the whole click is `aPI.cpp`'s.
	if _deploying():
		_deploy_click(screen)
		return
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
	var ray: PackedVector3Array = _ray_at(screen)
	if ray.is_empty():
		return
	# **The magnifier takes the whole click** (`0x0047156D`): with the mode on
	# the engine calls `0x00432AB0` and returns, so nothing is selected,
	# nothing is attacked and nothing is deselected -- and a click that finds
	# no alien is silent (docs/43 section 5.2).
	if _magnifier:
		_show_magnifier_page(magnifier_slot(ray, screen))
		return
	var best_slot: int = _unit_under(ray)
	if best_slot >= 0:
		var view: Dictionary = shown().unit_view(best_slot)
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
		if not shown().may_command(best_slot):
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
		if not shown().may_select(best_slot):
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
	# The click that raises the ring is the one that makes the noise, and all
	# three arms have a site of their own -- `0x00471622` the warp cell,
	# `0x00471675` the reachable cell and `0x00471892` the selected unit
	# clicked again (docs/28 section 2.5). Same wave, three sites; a remake
	# that played one of them for all three would be right by accident.
	var action: String = AudioTables.INTERFACE_ORDER_MOVE
	if mode == HudTables.RING_MODE_WARP:
		action = AudioTables.INTERFACE_ORDER_WARP
	elif mode == HudTables.RING_MODE_TURN:
		action = AudioTables.INTERFACE_RESELECT
	_play_interface(action)
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
	# **The facing goes with the command.** The move and the warp write it
	# after their own routine and before the playback takes the events
	# ([method _rotate_after]), so the body turns when the walk -- and the
	# return fire behind it -- is over, as the object does after the
	# original's blocking walk; a turn in place is a quiet command of its
	# own. A rotation submitted *after* `move_selected` returned used to
	# land on the journal behind a playback already running, which moved the
	# truth under the picture and had the mirror resynchronised on every
	# walk with a ring.
	match mode:
		HudTables.RING_MODE_MOVE:
			var _moved: MoveResult = move_selected(cell.x, cell.y, facing)
		HudTables.RING_MODE_WARP:
			var _jumped: WarpResult = warp_selected(cell.x, cell.y, facing)
		_:
			rotate_selected(facing)


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
func move_selected(x: int, y: int, facing: int = Combat.FACING_NONE) -> MoveResult:
	var slot: int = _selected
	_begin_command()
	var moved: MoveResult = world.submit_move(
		MoveCommand.create(slot, x, y))
	# The ring's facing is the walk's own last write (`aChangeUnitViewDirection`
	# after the blocking walk, docs/43 section 4.3): a quiet event behind the
	# walk and its return fire, so the body turns when the mirror does --
	# **before** the playback takes the events, or the rotation would move
	# the truth under a running picture and the mirror would fall behind it
	# on every walk.
	_rotate_after(slot, facing)
	# **The player's own walk marks nothing.** `aWalkMoveMap` `0x004305E0` is
	# what writes state 100 along a path, and it is reached from one place:
	# `0x00472D40`, an arm of the command dispatcher `0x0047DE90` that only
	# `0x0047C2C0` -- the redraw callback `aAISystemControl` is handed
	# (docs/23 section 2) -- calls. So the marks are how the *computer's*
	# steps are shown, and the player walks unmarked (docs/43 section 3.1).
	#
	# **The picture is the events, and the events are in order.** The routine
	# marked a boundary where the original's blocking loop would have drawn a
	# frame: the two opening visibility passes, the walk, the mine under the
	# stop cell, the teleporter, the `MoveUnit` hook, then one event per
	# reaction shot. The playback presents each in turn and lands its state on
	# the mirror when the animation reaches it -- which is what puts the blast
	# after the last step and the return fire after the blast, with no stage
	# of the remake's own to serialise them (docs/100 section 3).
	_command_note = moved.reason if not moved.ok else "%d %s" % [
		moved.reactions.size(), _strings.text("hud.reactions")]
	_play_command()
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
##
## Answers the frames it queued, and zero for a walk that reached no
## teleporter, so the `teleport` event holds for exactly the stream.
func _present_teleport(slot: int, events: Array[Dictionary]) -> int:
	var frames: int = 0
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
		frames += SetpieceDriver.TELEPORTER_FRAMES
	return frames


## The cell the walk stopped on, off the `teleporter` event the walk records.
static func _teleport_entry(events: Array[Dictionary]) -> Vector2i:
	for entry: Dictionary in events:
		if DictRead.as_string(entry.get("kind", "")) == "teleporter":
			return Vector2i(DictRead.as_int(entry["x"]),
				DictRead.as_int(entry["y"]))
	return Vector2i(-1, -1)


## How long a hook's animated set pieces keep the picture, at the queue's
## own rate: the frames [method SetpieceDriver.frames_for] answers, summed,
## because [method _present_script] queues them one after another. Zero for
## a hook that drew nothing, so a plain computer walk holds no longer than
## its own steps.
static func _script_seconds(outcome: Dictionary) -> float:
	var frames: int = 0
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		frames += SetpieceDriver.frames_for(AudioEvents.as_event(entry))
	return float(frames) / SequenceQueue.FRAMES_PER_SECOND


## One `aExecuteBomb` blast on the cell it went off on, drawn as the shot it
## is: `aExecuteBomb` calls `aPlayFightAnimation(x, y, x, y, ...)` with source
## and target on the bomb's own cell, and the routine's `sx == tx && sy == ty`
## arm reads **no shooter** and takes weapon 36 or 37 (docs/42 section 4).
## The slot is the unit standing on that cell -- the walker, the jumper, the
## para bomb's own record -- because the stages need a body to hold the
## camera on. The walk and the jump both reach it through a `mine` event
## (`0x0046EDAF`, `0x0046F109`), the computer's fuse through `parabomb`.
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
	# `0x0046C15E`, past `aAttackUnit`: the shooter says something about it.
	_speak("attack", slot)
	# `0x0047181C`: after the shot the shooter turns towards its best target
	# band -- `aGetDirectionTo(x, y, 0)`, then `aChangeUnitViewDirection`.
	if shot.fired and world.has_unit(slot):
		var facing: int = world.facing_to_target(slot)
		if facing != Combat.FACING_NONE:
			var _turned: bool = world.submit_rotate(
				RotateCommand.create(slot, facing))
	# The `fire` event first, then one per reaction shot: the drain is the
	# caller's and runs after `aAttackUnit` has played its own animation, so
	# the return fire is drawn after the shot rather than beside it.
	_command_note = shot.reason if not shot.fired \
		else "%d, %d %s" % [shot.outcomes.size(), shot.reactions.size(),
			_strings.text("hud.reactions")]
	_play_command()
	return shot


## Present a command whose events are already on the journal.
##
## Every player command ends here: the world resolved it, the journal recorded
## a boundary wherever the original's blocking loop would have drawn a frame,
## and the picture now walks them in order. [method _after_command] runs when
## the playback drains -- with the mirror on the truth -- from the playback's
## own finish callback, whether that is inside this call or frames later
## (docs/100 section 3).
##
## **No gap and no floor.** The player's command runs at the picture's own
## speed: the shot starts in this frame, the return fire follows it the frame
## the shot is over, and a command that drew nothing is over before this
## returns. The pacing is the computer's ([method end_turn]).
func _play_command() -> void:
	if world == null:
		return
	_playing_turn = false
	_playback.play(world.take_events(), Callable(self, "_on_ai_step"),
		Callable(self, "_apply_event"), 0.0, Callable(self, "_picture_busy"))


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
	var view: Dictionary = shown().unit_view(shooter)
	var own: bool = not view.is_empty() \
		and DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN
	# **The overheat orbit leads and the skill orbit follows.** They are not
	# a pair: `aCheckWeaponDamage`'s is step 1 of `aAttackUnit`
	# (docs/22 section 7.1), before the fight animation the caller runs, while
	# `0x00410190` plays **after** `aPlayFightAnimation` returns, if the
	# shooter is alive and its pool's level rose over the value saved at entry
	# (`0x0046B588`, docs/22 section 7.5). Queued together they showed the
	# player a promotion before the shot that earned it.
	_present_overheat_orbit(shooter, view, attack)
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
		"pattern": _shot_pattern(attack),
		"strings": {"missed": _strings.shipped(MODULE_FIGHT, ID_MISSED),
			"paralyzed": _strings.shipped(MODULE_FIGHT, ID_PARALYZED)},
		"cues_shot": cues_shot, "cues_impact": cues_impact,
		"cues_barrel": cues_barrel,
	}
	var frames: int = ShotSequence.enqueue(_sequences, _shot_host, shot)
	# After the shot's own stages, which is where the engine plays it.
	frames += _present_skill_orbit(shooter, view, attack)
	return float(frames) / SequenceQueue.FRAMES_PER_SECOND


## `0x0040F420` -- the overheat orbit, on the queue **ahead** of the shot.
##
## `aCheckWeaponDamage` is step 1 of `aAttackUnit` (docs/22 section 7.1), so
## this plays before the fight animation the caller runs. The orbit's own wave
## is already among the shot's cues ([method AudioEvents.overheat_cue]), so it
## plays none of its own.
func _present_overheat_orbit(shooter: int, view: Dictionary,
		attack: AttackResult) -> void:
	if view.is_empty() or not OVERHEAT_KINDS.has(attack.overheat):
		return
	var kind: int = DictRead.as_int(OVERHEAT_KINDS[attack.overheat])
	# The reactor that blew took the shooter with it -- `check_weapon_damage`
	# writes `hp = 0` for this outcome and the shooter is in nobody's
	# outcome list. The mirror still has it standing, because this command's
	# delta has not landed yet, so the orbit has a body to play on and the
	# camera has a unit to fly to.
	var _heat: int = OrbitSequence.enqueue(_queue(), _host(), shooter,
		OrbitSequence.KIND_OVERHEAT,
		_strings.shipped(MODULE_FIGHT, DictRead.as_int(ID_OVERHEAT_BY_KIND[kind])),
		[], kind)


## `0x00410190` -- the skill orbit, on the queue **after** the shot.
##
## docs/22 section 7.5: it plays once `aPlayFightAnimation` has returned, if
## the shooter is still alive, its pool's level (`+0x18 / 12`) rose over the
## value saved at entry (`0x0046B588`) and its species is 0. The routine opens
## with `call 0x0043B740 / cmp eax, 1 / jne`, so it is the campaign's and no
## other game mode's. Answers the frames it queued.
func _present_skill_orbit(shooter: int, view: Dictionary,
		attack: AttackResult) -> int:
	if view.is_empty() or attack.skill_raised <= 0:
		return 0
	if shown().turn.mode != TurnState.MODE_CAMPAIGN:
		return 0
	# "If the shooter is alive": the reactor that blew took it with it, and a
	# promotion is not shown to a body.
	if attack.overheat == Combat.OVERHEAT_DESTROYED:
		return 0
	var cues: Array[Dictionary] = []
	if _events != null:
		cues = _events.for_event_kind("skill")
	return OrbitSequence.enqueue(_queue(), _host(), shooter,
		OrbitSequence.KIND_SKILL, "%s %d" % [
			_strings.shipped(MODULE_FIGHT, ID_SKILL), attack.skill_raised],
		cues)


## `0x004104A0` after a reaction shot that jammed its reactor (docs/42
## section 7.4): *Out of ammo!* when the magazine is empty, else *Weapon
## runs hot!*.
func _present_jam(reactor: int) -> void:
	var view: Dictionary = shown().unit_view(reactor)
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
## **The shot's own outcome per cell**, as `aPlayFightAnimation`'s four
## walking arms read it back out of the control map
## ([method BlobTriggers.multi_target]).
##
## The engine does not hand the animation a list: it walks the map and reads
## `cell[+0x00]`, which `aBuildTargetPattern` marked and the resolver has since
## rewritten. `core` resolves the same shot and answers with the same per-cell
## markers, so this is that answer put back into cell order -- ascending
## `y * width + x`, which is `0x0042F730`'s index and the order the arc a
## grenade flies is assigned in.
##
## A cell whose unit was **killed** keeps both its `0x5D` and its occupant for
## this call. The removal sweep starts only after `aPlayFightAnimation`
## returns, so the two arms that test for a unit still fire at it.
func _shot_pattern(attack: AttackResult) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if attack == null:
		return out
	var state: MapState = shown().state
	var order: Array[Dictionary] = []
	for entry: Variant in attack.outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		var x: int = DictRead.as_int(outcome.get("x", 0))
		var y: int = DictRead.as_int(outcome.get("y", 0))
		if not state.in_bounds(x, y):
			continue
		var marker: int = DictRead.as_int(outcome.get("marker", 0))
		# `shown()` lags the fully resolved truth by design (docs/100), and here
		# that is the required pre-removal snapshot: the original has resolved
		# the marker but has not yet run its removal sweep.
		var cell: Dictionary = BlobTriggers.pattern_cell(Vector2i(x, y),
			_muzzle_of(x, y), _object_of(x, y), marker, _unit_byte_of(x, y))
		cell["index"] = state.index_of(x, y)
		order.append(cell)
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return DictRead.as_int(a["index"]) < DictRead.as_int(b["index"]))
	for cell: Dictionary in order:
		out.append(cell)
	return out


func _shot_targets(attack: AttackResult) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var types: UnitTypeTable = shown().unit_types()
	for entry: Variant in attack.outcomes:
		var outcome: Dictionary = DictRead.as_dict(entry)
		var slot: int = DictRead.as_int(outcome.get("slot", -1))
		# **The mirror's record, not the truth's.** A mission script's
		# `InsertUnit` reuses the slot the same turn emptied, so the truth may
		# already answer for a reinforcement; the picture's world has not been
		# told about either, and the species and the type it still carries are
		# what decide the death's creator and its scream.
		var unit: Dictionary = shown().unit_view(slot)
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
			"cell": shown().state.index_of(x, y) if shown().state.in_bounds(x, y)
				else 0})
	# `aPlayFightAnimation` first scans the finished CtrlMap with a 0x17-byte
	# stride and collects every 0x5A..0x5D cell. A repeat pass may append an
	# earlier cell to `outcomes` late, so append order is not this final order.
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return DictRead.as_int(a["cell"]) < DictRead.as_int(b["cell"]))
	return out


## docs/42 section 4.5 -- one voice by the shot's severity and the target's
## species: the pain scream for damage, the death scream for a kill.
func _shot_voice(targets: Array[Dictionary]) -> Dictionary:
	var worst: int = ShotSequence.severity(targets)
	if worst < ShotSequence.SEVERITY_DAMAGE or targets.is_empty():
		return {}
	# The species the engine reads is the last unit the sweep looked at, and
	# `targets` is already in that order. `aPlayFightAnimation` builds the
	# arrays at `0x004FBE54/72` by scanning the completed CtrlMap row-major at
	# `0x0040C549..0x0040C79C`; the later loop at `0x0040DA83` consumes them.
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
	# Facing, terrain and floor clearance belong to this replay event;
	# the truth already includes every later action of the turn.
	var picture: World = shown()
	var view: Dictionary = picture.unit_view(shooter)
	if view.is_empty():
		return 0.0
	var from: Dictionary = CameraDirector.inputs_at(picture, view, sx, sy)
	if reaction:
		return _director.reaction_shot(picture, from, _inputs_of(mover, tx, ty),
			_director.toss())
	if DictRead.as_int(view["player"]) != UnitState.PLAYER_ALIEN:
		return 0.0
	# The target cell's object with the **shooter's** height, as the engine
	# reads it; whether a victim stands there is what the shot resolved on.
	var to: Dictionary = CameraDirector.inputs_at(picture, view, tx, ty)
	return _director.computer_shot(from, to, not attack.outcomes.is_empty())


## A named unit standing on a cell as camera inputs -- the cell an event
## puts it on, not the one the world has it on now -- or the bare cell when
## there is no record to read. The record outlives the unit: a mover killed
## by the reaction being shown, or one that walked on before the playback
## reached this event, still has its type, which is what the shot cameras
## need (its height and its size); the cell is the event's.
func _inputs_of(slot: int, x: int, y: int) -> Dictionary:
	if not shown().state.in_bounds(x, y):
		return {}
	var view: Dictionary = shown().unit_view(slot) if slot >= 0 else {}
	if not view.is_empty():
		return CameraDirector.inputs_at(shown(), view, x, y)
	return {"obj": CameraRig.cell_object(x, y,
			shown().state.height_at(shown().state.index_of(x, y))),
		"height": 0, "gradient": Vector3i(0, 1, 0), "large": false,
		"x": x, "y": y}


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


## The sounds and the pictures one run of a mission script asks for.
##
## `core` has already applied every state change these events record -- the
## door is open, the lift has moved -- so what reaches here is the half the
## simulation does not own: docs/28's `aPlay*Sequence` sounds, keyed by the
## routine that owns them, and docs/42 section 8's set pieces on the queue.
## The two halves are independent: without a sound layer the set pieces
## still queue, and without a queue the cues still play.
func _present_script(outcome: Dictionary) -> int:
	if outcome.is_empty():
		return 0
	_last_script = {"ran": DictRead.as_bool(outcome.get("ran", false)),
		"events": _event_names_of(outcome),
		"count": DictRead.as_int(_last_script.get("count", 0)) + 1}
	var played: int = 0
	for entry: Variant in DictRead.as_array(outcome.get("events", [])):
		var event: Dictionary = AudioEvents.as_event(entry)
		if event.is_empty():
			continue
		# The picture does not need the sound layer: a set piece, a camera
		# flight or a barrier's turn is queued whether or not there is an
		# event table to name its cues, and a suite with no audio wired sees
		# the same queue a played mission does.
		var cues: Array[Dictionary] = _events.for_event(event) \
			if _events != null else ([] as Array[Dictionary])
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
		# `aPlayLaserBarrier` turns the emitter's part before anything else
		# it does, on both arms -- half a turn about z going off, back to
		# zero coming on -- and `barrier_off` is otherwise instant.
		if script_kind == "barrier_on" or script_kind == "barrier_off":
			var _emitter: int = _paint_barrier(event, script_kind == "barrier_off")
		var frames: int = SetpieceDriver.frames_for(event)
		if frames > 0 and _sequences != null:
			# An animated set piece: the picture is interpolated over the
			# frames the original's own loop ran for, and its sound lives for
			# exactly that long rather than for the length of its sample.
			_queue_setpiece(event, frames, cues)
			played += cues.size()
			continue
		if cues.is_empty() or _audio == null:
			continue
		var slots: PackedInt32Array = _audio.play_cues(cues, "script")
		played += slots.size()
	return played


## The barrier's emitter, turned the way `0x00413653` / `0x00413670` write
## its `+0x2A`: `0x800` when the barrier goes off, zero when it comes on.
## Answers how many parts turned.
func _paint_barrier(event: Dictionary, off: bool) -> int:
	if _scenery == null or world == null:
		return 0
	var cell: Vector2i = SetpieceDriver.cell_of(event)
	if not shown().state.in_bounds(cell.x, cell.y):
		return 0
	return _scenery.paint_joint(shown().state.index_of(cell.x, cell.y),
		SetpieceDriver.BARRIER_EMITTER_PART,
		Vector3i(0, 0, SetpieceDriver.BARRIER_EMITTER_OFF if off else 0))


## Queue one set piece: hold the cell where it was drawn, and walk it to where
## `core` has already put it.
##
## The offset is against the **drawn** snapshot, not against the authored
## height, so a lift that has moved twice starts its second trip from where the
## first one left it. `core` is never read for anything but the destination.
func _queue_setpiece(event: Dictionary, frames: int,
		cues: Array[Dictionary], about_unit: int = MapState.NO_UNIT) -> void:
	var cell: Vector2i = _block_cell(event)
	if world == null or not shown().state.in_bounds(cell.x, cell.y):
		if not cues.is_empty() and _audio != null:
			var _slots: PackedInt32Array = _audio.play_cues(cues, "script")
		return
	# **The state after the event, read now.** Everything below is about
	# where the cell is going -- the height the block travels to, whether a
	# door is opening or closing (`to < from`), the alien a roof unit has
	# inserted, the riders a platform has already relocated -- so the delta
	# of the event on screen lands here, before any of it is read. The
	# picture does not follow yet: [method _flush_picture] waits for the
	# queue, so the bodies and the terrain stand where the drawn snapshot
	# has them until the sequence has carried them across.
	var _landed: bool = _playback.apply_current()
	var index: int = shown().state.index_of(cell.x, cell.y)
	var was: PackedInt32Array = _drawn_terrain["height_map"] \
		if _drawn_terrain.has("height_map") else PackedInt32Array()
	var from: int = was[index] if index < was.size() \
		else shown().state.height_at(index)
	var to: int = shown().state.height_at(index)
	var name: String = AudioEvents.name_of(event)
	# A `RoofUnit` inserts its alien the instant the command runs, so the unit
	# is on the map before its fall has started. The body is held out of the
	# picture for the length of the sequence and shown at the end: the criterion
	# is that the unit **appears at the end of the drop, not at the beginning**,
	# and `core` is never asked to delay anything.
	if name == "roof_unit" and _units != null:
		var arriving: int = shown().state.unit_at(index)
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
		rider = shown().state.unit_at(index)
	# The unit the routine is about: the door's user (the selected unit for
	# the player's own door, none for the LCL wrapper's), the roof's cargo,
	# the ground unit's victim at its own cell.
	var about: int = about_unit
	var extra: Dictionary = _setpiece_extra(name, cell, event)
	var values: PackedInt32Array = SetpieceDriver._numbers(event)
	if name == "roof_unit":
		about = shown().state.unit_at(index)
	elif name == "ground_unit" and values.size() >= 4 \
			and shown().state.in_bounds(values[2], values[3]):
		var own: Vector2i = Vector2i(values[2], values[3])
		extra["own"] = own
		about = shown().state.unit_at(shown().state.index_of(own.x, own.y))
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
	# What the picture of this one sequence remembers between its frames:
	# the routine's name and arguments, and the joint words it found on its
	# first frame (docs/42 section 8.3) -- a bridge turns the way its halves
	# are *not* already turned, and a tube's hatch starts where the last
	# `OpenTube` left it.
	var picture: Dictionary = {"name": name, "values": values, "starts": {}}
	# The crush wall's `aDeleteLand` runs when its pool stage ends, which is
	# early when the debris is quick; the footbridge's when its fixed frames
	# run out, inside the paint.
	if name == "crush_wall":
		extra["finish"] = func() -> void:
			if _scenery != null:
				var _gone: int = _scenery.remove_objects(index)
	# The footbridge's riders: `core` has already taken them off the map
	# dead, and the delta that killed them landed above -- but the picture
	# does not follow the landing while the queue runs ([method
	# _flush_picture]), so their bodies stand, fall one map field a frame
	# under the block, and leave the picture at the drain (docs/42 section
	# 8.1), with nothing held on their behalf.
	var riders: PackedInt32Array = SetpieceDriver.riders_of(event)
	# The platform's ride: its block's objects and its riders travel
	# `0x140` a frame (docs/20 section 7.4 step 2), and the camera target
	# with them. Until 2026-09-07 nothing here moved: the sequence ran its
	# frames with the dust and the sound while the deck stayed where it was
	# authored, and the riders -- relocated by `core` the instant the
	# command ran -- stood in mid-air over the destination's hole, which is
	# how `_C_106`'s squad spent its first turn.
	var ride: Dictionary = {}
	if name == "platform":
		ride = _platform_ride(values)
		extra["travel"] = SetpieceDriver.platform_offset(values, frames)
		# From the moment the sequence is queued, not from its first painted
		# frame: the camera's flight to the block runs first, and for its
		# length the riders would otherwise stand where `core` has already
		# put them.
		_ride_platform(ride, values, 0, frames)
	var _frames: int = SetpieceCamera.enqueue(_sequences, _host(), name, frames,
		cell, from, to, about, extra,
		func(frame: int, total: int) -> void:
			_paint_setpiece(index, from, to, frame, total, picture)
			_carry_rider(rider, from, to, frame, total)
			_drop_riders(riders, frame, total)
			_ride_platform(ride, values, frame, total),
		lead, late)


## What a platform ride carries: the source block's cells -- `core` has
## already copied their heights and types away (`0x00412FFB`), but the
## picture still keys their objects there -- and the riders, read off the
## **destination** cells because `Platform.ride` relocated them before the
## command returned.
func _platform_ride(values: PackedInt32Array) -> Dictionary:
	var block: PackedInt32Array = PackedInt32Array()
	var riders: PackedInt32Array = PackedInt32Array()
	var travel: Vector2i = SetpieceDriver.platform_travel(values)
	for at: Vector2i in SetpieceDriver.platform_block(values):
		if not shown().state.in_bounds(at.x, at.y):
			continue
		block.append(shown().state.index_of(at.x, at.y))
		var landing: Vector2i = at + travel
		if not shown().state.in_bounds(landing.x, landing.y):
			continue
		var slot: int = shown().state.unit_at(
			shown().state.index_of(landing.x, landing.y))
		if slot != MapState.NO_UNIT and not riders.has(slot):
			riders.append(slot)
	return {"block": block, "riders": riders, "travel": travel}


## One frame of the ride: the block's objects `frame` steps from where they
## were authored and the riders the same distance short of where `core` has
## them; on the last frame the objects are re-keyed under the destination
## cells and the riders put down. Painted **after** [method _paint_setpiece],
## which resets the centre cell's objects to their authored place every
## frame.
func _ride_platform(ride: Dictionary, values: PackedInt32Array, frame: int,
		frames: int) -> void:
	if ride.is_empty() or _scenery == null or world == null:
		return
	var block: PackedInt32Array = ride["block"]
	var riders: PackedInt32Array = ride["riders"]
	var travel: Vector2i = ride["travel"]
	# From the fields, not from the frame count: `frames` is clamped at
	# [constant SetpieceDriver.MAX_FRAMES], and the riders must still meet
	# the deck where `core` put them.
	var whole: Vector3i = Vector3i(travel.x, travel.y, 0) \
		* WorldSpace.WORLD_UNITS_PER_FIELD
	# The marks on the block -- the bands over its riders, a digit on a
	# reachable cell -- are blitted at the projected point of each cell's
	# ground object (docs/43 section 3), and the ride moves those objects,
	# so the marks travel with the deck. The overlay was drawn before the
	# ride and is not redrawn until the drain ([method _refresh_overlay]).
	var cells: Array[Vector2i] = SetpieceDriver.platform_block(values)
	if frame < frames:
		var offset: Vector3i = SetpieceDriver.platform_offset(values, frame)
		var _objects: int = _scenery.shift_objects(block, offset)
		if _ground != null:
			var _marks: int = _ground.shift_cells(cells, offset)
		if _units != null:
			for slot: int in riders:
				_units.shift(slot, offset - whole)
		return
	var _landed: int = _scenery.move_objects(shown().terrain_snapshot(), block,
		travel.x, travel.y)
	if _ground != null:
		var _arrived: int = _ground.shift_cells(cells, whole)
	# **This ride's riders only.** The next platform on the queue has already
	# shifted its own riders back to where they ride from, and dropping every
	# carry here stood them on their destination cells until its first
	# painted frame (`_C_105`'s two consoles, each moving two platforms).
	if _units != null:
		var _down: int = _units.put_down(riders)


## The cell a set piece's object stands on. Every command names its own,
## except `FootBridge2`, whose event carries the group's cells and whose
## block -- the `L069EI00` -- stands on one of the first two: `0x00415110`
## searches beside the first cell's object, then beside the second's
## (docs/42 section 8.1), and finds it on whichever of the two carries it.
func _block_cell(event: Dictionary) -> Vector2i:
	var cell: Vector2i = SetpieceDriver.cell_of(event)
	if _scenery == null or world == null:
		return cell
	# Where the routine's object stands, which is not always the cell the
	# event leads with: `FootBridge2`'s block is on one of its group's first
	# two cells, and a `CrushWall` names any cell of the wall piece's run --
	# `core` finds the run by the cell, the way `0x00406F20`'s box search
	# would, so the node has to be found the same way or a call naming the far
	# cell would crush the cells and leave the wall standing (docs/97 section
	# 50.3).
	var candidates: Array[Vector2i] = []
	match AudioEvents.name_of(event):
		"foot_bridge2":
			var group: Array[Vector2i] = SetpieceDriver.group_cells(event)
			candidates = group.slice(0, mini(2, group.size()))
		"crush_wall":
			candidates = SetpieceDriver.footprint_cells(event)
		_:
			return cell
	for at: Vector2i in candidates:
		if world.state.in_bounds(at.x, at.y) \
				and not _scenery.objects_on(world.state.index_of(at.x, at.y)).is_empty():
			return at
	return cell


## One frame of the riders' fall: each one is placed
## [constant SetpieceDriver.FOOTBRIDGE_RIDER_DROP] lower than the frame
## before and turned by what the loop has added to its own rotation words
## ([method SetpieceDriver.rider_turn]), and after the loop
## `aRemoveUnitElement` takes it off the map -- here, out of the picture.
##
## The heading the tumble is measured from is the record's, which for a
## rider `core` has already killed is the one the mirror
## held. **The riders are turned in the order the event carries them**,
## because that is the loop's own index and its parity is the sign.
func _drop_riders(riders: PackedInt32Array, frame: int, frames: int) -> void:
	if _units == null or riders.is_empty():
		return
	for order: int in range(riders.size()):
		var slot: int = riders[order]
		if frame >= frames:
			var _was: bool = _units.hide_now(slot)
			continue
		_units.lift(slot, -SetpieceDriver.FOOTBRIDGE_RIDER_DROP * frame)
		var record: Dictionary = _unit_record(slot)
		if record.is_empty():
			continue
		var _turned: bool = _units.tumble(slot,
			DictRead.as_int(record["facing"]),
			SetpieceDriver.rider_turn(order, frame))


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
		"open_door", "foot_bridge", "foot_bridge2", "lever", "pickup":
			# The object the flight aims at: `0x00406F20`'s find beside the
			# cell's marker, which is the first **special** object on the
			# cell -- the door's panel, the footbridge's block (for
			# `FootBridge2`, `cell` is already the group cell the block
			# stands on), the lever's `L109EX00` and the supply box.
			# [method Scenery.object_origins] leaves the level's
			# own `.3DW` clones out, and it has to: they are placed first
			# and are in no table the search reads, so on `_C_142` this
			# aimed at `LEVEL01D.004` and on `_C_163` at a clone 13 760
			# units below the block.
			if _scenery != null and world != null \
					and world.state.in_bounds(cell.x, cell.y):
				var origins: Array[Vector3i] = _scenery.object_origins(
					world.state.index_of(cell.x, cell.y))
				if not origins.is_empty():
					out["object"] = origins[0]
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
		"ground_fire":
			# `[x, y, n, (slot, x, y) * n]` -- the tiles `core` took before
			# `UnitState.remove` cleared the cells.
			var burnt: Array = []
			var count: int = _at_or(values, 2, 0)
			for i: int in range(count):
				var at: int = 3 + i * 3
				if at + 2 >= values.size():
					break
				burnt.append({"slot": values[at], "x": values[at + 1],
					"y": values[at + 2]})
			out["killed"] = burnt
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
			# `core` carries the cells it changed -- the whole footprint the
			# converter projected (docs/42 section 8.2), or the command's own
			# cell where a map document carries no objects.
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
## would have had them at after `frame` of its own ticks -- and, on the
## door's family, the object's joint or rotation words at the value that
## frame reaches (docs/42 section 8.3). The cell's height still walks,
## because the land marker's z is that height; the panel does not move, and
## the joints are painted **after** the state so the finished pose the
## snapshot already holds does not show first. Every pose is `start + step
## * frame`, never accumulated: `picture["starts"]` is what the routine
## read off the object on its first frame.
func _paint_setpiece(index: int, from: int, to: int, frame: int,
		frames: int, picture: Dictionary = {}) -> void:
	if _scenery == null or world == null:
		return
	var progress: float = SetpieceDriver.progress(frame, frames)
	var at: int = from + roundi(float(to - from) * progress)
	var partial: Dictionary = shown().terrain_snapshot()
	var heights: PackedInt32Array = partial["height_map"]
	if index >= heights.size():
		return
	heights[index] = at
	partial["height_map"] = heights
	var _moved: int = _scenery.apply_state(partial, PackedInt32Array([index]))
	var name: String = DictRead.as_string(picture.get("name", ""))
	var values: PackedInt32Array = DictRead.as_int32_array(
		picture.get("values", []))
	if Interact.DOOR_IDS.has(shown().state.action_point_at(index)) \
			and (name == "" or name == "open_door"):
		# Opening drops the cell by one tile, closing raises it: the sign of
		# the height change is the sign the routine chose for `ebx`.
		var opening: bool = to < from
		var swing: int = roundi(float(Scenery.DOOR_LEAF_SWING) * progress)
		var _leaves: int = _scenery.paint_door(index,
			swing if opening else Scenery.DOOR_LEAF_SWING - swing)
		return
	if name == "":
		return
	var _parts: int = SetpieceDriver.paint_family(_scenery, index, name, values,
		frame, frames, picture, _host())


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
	var now: Dictionary = shown().terrain_snapshot()
	var _moved: int = _scenery.apply_state(now, cells)
	_overlay.rebuild_cells(now, cells)
	return cells.size()


func _redraw_terrain() -> int:
	# A queued set piece owns the cells it is animating: snapping them to the
	# finished state now would show the end of the lift before the lift.
	# `_process` drains [member _terrain_stale] when the queue empties.
	if _sequences != null and _sequences.is_running():
		_terrain_stale = true
		return 0
	return _redraw_terrain_now()


func _redraw_terrain_now() -> int:
	_terrain_stale = false
	if world == null or _scenery == null or _overlay == null:
		return 0
	var now: Dictionary = shown().terrain_snapshot()
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


## Where a shot's effects start and end -- the cell's object, lifted by the
## height of whatever is standing on it.
##
## **The unit's own height, and `0x0047AD30`'s rather than `0x0047AD70`'s.**
## `aBlob_CreateTracerBullet` `0x004247C0` -- the muzzle creator fourteen of
## the shipped weapons select -- reads the shooter's unit record, calls
## `0x0047AD30` on it (`0x004248A1`) and adds the answer to the placed
## object's `+0x18` (`0x00424996`: `mov eax, [ebp+0x18] / add eax, ebx`); the
## target end does the same with the target cell's own unit. `0x0047AD30` is
## **half** the type height plus 800 -- the eye line, chest height on a marine
## -- and not the full height `0x0047AD70` answers, which is the *top* of the
## body and is what the range curve uses instead.
##
## [constant BlobTriggers.MUZZLE_HEIGHT] stood in for it: one thousand units,
## about 0.6 m, so a round left a marine somewhere around the waist.
##
## **And the axis is the fallback, not the answer.** `0x004249AF` tests the
## shooter's `+0x56` -- the running Charisma animation handle of docs/42
## section 6.2.1, which a fight animation sets -- and where it is set
## `0x0042C660` writes the world position of a *named part of the shooter's
## Charisma model* over all three source coordinates. So an ordinary shot
## leaves the **barrel**, and the body's axis at eye height is what a body
## that is not animating gets. Which part, and therefore where, is per
## creator call and belongs to [method BlobTriggers.muzzle]; this answers the
## axis it overrides.
##
## `slot` is the unit this end belongs to, where the caller knows it. It is
## not a nicety: this runs over the shown() at the **end** of the turn, where
## the shooter may already be dead and its slot refilled by a reinforcement,
## and the cell would then answer for whoever stands there now.
func _muzzle_of(x: int, y: int, slot: int = MapState.NO_UNIT) -> Vector3i:
	return BlobTriggers.muzzle_point(x, y, _floor_of(x, y),
		_muzzle_lift(x, y, slot))


## The **placed object's** own position, without the standing unit's height.
##
## A transcribed weapon creator wants the two apart: the engine reads the
## symbol object through `aGetSymbolObjectPtr` and the unit's height through
## `0x0047AD30`, and its arms use them differently -- the span it counts its
## beam in is over the *objects* while the line it walks leaves the muzzle
## (docs/97 section 14.5). Everything else here wants only the sum.
func _object_of(x: int, y: int) -> Vector3i:
	return BlobTriggers.muzzle_point(x, y, _floor_of(x, y), 0)


func _floor_of(x: int, y: int) -> int:
	if shown() == null or not shown().state.in_bounds(x, y):
		return 0
	return shown().state.height_at(shown().state.index_of(x, y))


## How far above the cell floor an effect starts -- the standing unit's own
## eye height, or [constant BlobTriggers.MUZZLE_HEIGHT] for bare ground.
## The unit standing on a cell, as the **creator's** `aux` wants it: the low
## byte of the cell's unit id, which `aBlob_EnergyCannon` `0x004264A0` and
## `aBlob_CreateGrenade` `0x00426070` store in the record for a seeking arm to
## read back as a unit-map slot (docs/28 section 7.7.1). A cell with nobody on
## it answers zero, which is what the engine's own `byte [edx+7]` gives for an
## empty cell's `0xFFFF` truncated.
func _unit_byte_of(x: int, y: int) -> int:
	if shown() == null or not shown().state.in_bounds(x, y):
		return 0
	return shown().state.unit_at(shown().state.index_of(x, y)) & 0xFF


## The other end of [method _unit_byte_of]: the seeking arms' unit map
## ([member GameBlobHooks.unit_map]). The slot's object position, as
## `aGetStdObjectPosition` answers for the unit's own object -- the placed
## object's, without the standing height -- or `{}` when the picture has no
## unit in that slot, which is the null the arm aborts on.
func _seeker_target(slot: int) -> Dictionary:
	var view: Dictionary = _unit_record(slot)
	# `aGetUnitMapElementPtr`'s third refusal, *"unit is dead"* (`0x00477B41`:
	# the record's `+0x16`, its hit points, at zero). A dead unit stays in the
	# mirror with `hp 0` and its last cell, so this is the gate that keeps a
	# seeker off a corpse. The other two -- no such slot -- are `_unit_record`.
	if view.is_empty() or DictRead.as_int(view["hp"]) == 0:
		return {}
	return {"object": _object_of(DictRead.as_int(view["x"]),
		DictRead.as_int(view["y"]))}


func _muzzle_lift(x: int, y: int, slot: int = MapState.NO_UNIT) -> int:
	if shown() == null or not shown().state.in_bounds(x, y):
		return BlobTriggers.MUZZLE_HEIGHT
	var here: int = slot
	if here == MapState.NO_UNIT:
		here = shown().state.unit_at(shown().state.index_of(x, y))
	var view: Dictionary = _unit_record(here)
	if view.is_empty() or DictRead.as_int(view["hp"]) <= 0:
		return BlobTriggers.MUZZLE_HEIGHT
	return HitChance.eye_height(shown().unit_types(),
		DictRead.as_int(view["type_id"]))


## What the picture knows about `slot`, or the record held over its death.
##
## A slot the turn killed is gone from the truth before any of the turn is
## drawn, and a slot a reinforcement recycled answers for the wrong unit --
## which the mirror answers for, being a world the recycling has not
## reached yet.
func _unit_record(slot: int) -> Dictionary:
	if slot == MapState.NO_UNIT:
		return {}
	if shown() != null and shown().has_unit(slot):
		return shown().unit_view(slot)
	return {}


## What a death creator reads for the tiles its arguments name (docs/97
## section 22): the placed object's position -- the cell's centre at its
## height -- and the unit standing there with its type's height, plus the
## gore level and the output mode.
func _death_inputs(args: PackedInt32Array) -> BlobPrograms.Inputs:
	var inputs: BlobPrograms.Inputs = BlobPrograms.Inputs.new()
	inputs.gore = shown().gore_level
	inputs.display_mode = DISPLAY_MODE
	var types: UnitTypeTable = shown().unit_types()
	for i: int in range(0, args.size() - 1, 2):
		var x: int = args[i]
		var y: int = args[i + 1]
		if not shown().state.in_bounds(x, y):
			continue
		var index: int = shown().state.index_of(x, y)
		var height: int = shown().state.height_at(index)
		var unit: Dictionary = {}
		var slot: int = shown().state.unit_at(index)
		var view: Dictionary = shown().unit_view(slot) if slot >= 0 else {}
		if view.is_empty():
			# The casualty has left the cell in `core` (`UnitState.remove`
			# clears the link at once, where the engine's
			# `aRemoveUnitElement` runs after the animation), but its record
			# keeps its coordinates and its type -- which is what the
			# creator reads through the unit map.
			for candidate: int in shown().unit_slots():
				var dead: Dictionary = shown().unit_view(candidate)
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
	inputs.gore = shown().gore_level
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
	# The cell in front **before** the use, for the sound of a use that
	# stages nothing; the `use` event carries the same cell as its target.
	var front: Vector2i = Vector2i(-1, -1)
	var pusher: Dictionary = world.unit_view(_selected)
	var facing: int = DictRead.as_int(pusher.get("facing", -1))
	# The guard [method Interact.cell_in_front] makes before the same index.
	if not pusher.is_empty() and facing >= 0 \
			and facing < Interact.FACING_DX.size():
		front = Vector2i(DictRead.as_int(pusher["x"]) + Interact.FACING_DX[facing],
			DictRead.as_int(pusher["y"]) + Interact.FACING_DY[facing])
	# **Whose voice**, captured before the command: `_after_command` below
	# drops the selection when the use spends the unit's last movement point,
	# and the twelve speaking arms would then be silent for exactly the uses
	# that end a turn.
	var user: int = _selected
	var used: UseResult = world.submit_use(UseCommand.create(_selected))
	# The set pieces -- the door, the lever, the lid, the push -- are the
	# `use` event's own presentation ([method _present_use]), queued by the
	# playback against the state after the event; what stays here is the
	# sound of a use that stages nothing, the message and the voice.
	var staged: bool = _use_is_staged(used, front)
	_command_note = used.kind if used.ok else used.reason
	# The player's own door emits **no event** -- `Interact.toggle_door` writes
	# the state change and returns, and only the LCL `OpenDoor` path records
	# one. So the sound is driven from the result, not from the event stream,
	# and this is why [method AudioEvents.for_use] exists at all. A staged
	# use -- the door, the lever, the box -- has its cues on the queue.
	if _audio != null and _events != null and not staged:
		var _slots: PackedInt32Array = _audio.play_cues(
			_events.for_use(used), "use")
	# **The message the crate opens with** -- docs/26 section 3. Thirteen arms
	# hand a two-character label to `0x00410780`, which is what draws the box
	# and plays `box.wav`; the remake had the sound and not the box, so the
	# only thing a crate did was click. It goes up after the arm's own work,
	# as the original's does, and holds the mission until it is dismissed
	# ([method _unhandled_input]) or until
	# [constant MissionHud.INFO_AUTO_HIDE_SECONDS] have passed.
	if used.ok and _hud != null and _info != null:
		var said: Array = _info.spans_for(used.action_point)
		if not said.is_empty():
			_hud.show_info(said)
	# Twelve of the equipment switch's arms speak, all of them argument 9
	# (docs/28 section 4.3) -- and every one of them past the arm's own work,
	# so a refused use says nothing. **Twelve, not every arm**: the twelve
	# `0x0047B660` sites of `inclib.sound.SPEECH_CALLS["use"]` are all inside
	# the equipment switch, so a door, a lever, a push, the entry point and
	# the defuse are silent, and so is action point 11 -- *Found nothing* is
	# the one pickup with no voice line.
	if used.ok and _info != null and _info.speaks(used.action_point):
		_speak("use", user)
	_play_command()
	return used


## Whether a use is drawn as a set piece of its own -- the door, the lever,
## the supply box (docs/42 section 8) -- rather than as a sound.
func _use_is_staged(used: UseResult, front: Vector2i) -> bool:
	return used.ok and _sequences != null and world != null \
		and world.state.in_bounds(front.x, front.y) \
		and (used.kind == World.DOOR_USE_KIND or used.kind == LEVER_USE_KIND
			or PICKUP_USE_KINDS.has(used.kind))


## The `use` event's picture: the door's flight from the user's head and its
## leaves, the lever's handle, the supply box's lid and hold, the push's
## slide (docs/42 sections 7.2 and 8). `outcome` is the use's own result as
## the event carries it and `front` the event's target cell.
##
## Queued by the playback and not by the command, so [method _queue_setpiece]
## can land the event's delta before it reads where the cell is going: a
## door queued against the mirror's closed state turned its leaves the wrong
## way and snapped open when the delta landed. The push is the one that
## reads the mirror **before** the landing -- the pushed record has left the
## truth and the slide needs its slot.
##
## Answers the frames it queued, at the queue's own rate.
func _present_use(slot: int, outcome: Dictionary, front: Vector2i) -> float:
	var used: UseResult = UseResult.from_dict(outcome)
	if not used.ok or world == null or _sequences == null \
			or not shown().state.in_bounds(front.x, front.y):
		return 0.0
	var frames: int = 0
	if PUSH_KINDS.has(used.kind):
		var pushed: int = shown().state.unit_at(
			shown().state.index_of(front.x, front.y))
		if pushed == MapState.NO_UNIT:
			return 0.0
		var cells: Array[Vector2i] = []
		for step: PackedInt32Array in used.pushed:
			cells.append(Vector2i(step[0], step[1]))
		frames = PushSequence.enqueue(_queue(), _host(), slot, pushed, front,
			cells, used.kind == PUSH_INTO_HOLE)
		var seconds: float = float(frames) / SequenceQueue.FRAMES_PER_SECOND
		if used.kind == "push_onto_mine" and not used.blast.is_empty() \
				and not cells.is_empty():
			var at: Vector2i = cells[cells.size() - 1]
			seconds += _present_blast(pushed, at.x, at.y, used.blast)
		return seconds
	if not _use_is_staged(used, front):
		return 0.0
	var cues: Array[Dictionary] = _events.for_use(used) if _events != null \
		else ([] as Array[Dictionary])
	if used.kind == World.DOOR_USE_KIND:
		# The player's Use passes real tiles, so the door gets its flight
		# from the user's head and back; the LCL wrapper's `-1, -1` is the
		# one that does not.
		frames = SetpieceDriver.DOOR_FRAMES
		_queue_setpiece({"name": "open_door", "values": [front.x, front.y]},
			frames, cues, slot)
	elif used.kind == LEVER_USE_KIND:
		# docs/42 section 8.3: `aPlayUseLeverSequence(x, y, dir, unit)` with
		# `dir` 0 for a lever that was up -- `used.action_point` is the
		# point **before** the arm wrote the other one.
		frames = SetpieceDriver.LEVER_FRAMES
		_queue_setpiece({"name": "lever", "values": [front.x, front.y,
			1 if used.action_point == Interact.LEVER_DOWN else 0]},
			frames, cues, slot)
	else:
		# The supply box `0x00410780`: the text first, then the flight, the
		# lid and the hold under it.
		frames = SetpieceDriver.PICKUP_LID_FRAMES \
			+ SetpieceDriver.PICKUP_HOLD_FRAMES
		_queue_setpiece({"name": "pickup", "values": [front.x, front.y]},
			frames, cues, slot)
	return float(frames) / SequenceQueue.FRAMES_PER_SECOND


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
	_command_note = "heal" if DictRead.as_bool(healed["ok"]) \
		else DictRead.as_string(healed["reason"])
	_play_command()
	return healed


## The Jet Pack's jump (docs/23 section 7.5) and its picture (docs/42
## section 7.1). The reactions the landing drew are queued behind the jump
## the way a walk's are behind the walk.
func warp_selected(x: int, y: int, facing: int = Combat.FACING_NONE) -> WarpResult:
	var slot: int = _selected
	_begin_command()
	var jumped: WarpResult = world.submit_warp(WarpCommand.create(slot, x, y))
	_rotate_after(slot, facing)
	# The jump, the mine under the landing, the `MoveUnit` hook and the
	# reactions are four boundaries in that order -- `aExecuteWarp` relinks,
	# detonates at `0x0046F109`, runs `aRunLCL` at `0x0046F1D6`, and the
	# drain is the caller's.
	_command_note = jumped.reason if not jumped.ok else "%d %s" % [
		jumped.reactions.size(), _strings.text("hud.reactions")]
	_play_command()
	return jumped


## The facing the ring chose, written after the command it closed and
## before the playback: nothing for a ring with no facing, and nothing for a
## unit the command killed.
func _rotate_after(slot: int, facing: int) -> void:
	if facing < 0 or world == null or not world.has_unit(slot):
		return
	var _turned: bool = world.submit_rotate(RotateCommand.create(slot, facing))


## The ring's turn in place (docs/43 section 4.3): free, and an event like
## any other, so the mirror -- and the body drawn from it -- turns with the
## truth rather than a command later.
func rotate_selected(facing: int) -> void:
	var slot: int = _selected
	if slot < 0 or facing < 0 or world == null or not world.has_unit(slot):
		return
	_begin_command()
	_rotate_after(slot, facing)
	_command_note = ""
	_play_command()


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
	if _selected < 0 or world == null or _fx == null or not shown().has_unit(_selected):
		return
	if _units != null and not _units.scheduler.enabled:
		return
	var view: Dictionary = shown().unit_view(_selected)
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
	_command_note = _strings.text("hud.overwatch") if ticket > 0 else ""
	_play_command()
	return ticket


## Ends the current player's turn. The computer's turn runs **inside**
## [method World.submit_end_turn] now (docs/23), and hands over again by itself
## when it is done, so what comes back has already passed the rotation on. The
## loop that used to sit here would have run `NEXT PLAYER` a second time per
## round -- which on `_C_140` is the script's reinforcement roll firing twice
## as often as the mission intends.
func end_turn() -> TurnResult:
	_begin_command()
	# The seat the picture is drawn for, taken before the rotation moves on:
	# the computer's turn runs **inside** `submit_end_turn`, so by the time
	# the first event is drawn `turn.current_player` is 255 -- and a fog pass
	# for 255 is the aliens' own view of the map.
	_fog.viewer = world.turn.current_player
	# The player's own arrangement of the camera, for the hand-back: the
	# replay's shot placements are about to throw it away (see
	# [method _restore_camera_on]).
	if _rig != null:
		_camera_offset_before_turn = _rig.eye_goal() - _rig.target_goal()
		_camera_mode_before_turn = _rig.view_mode()
	var result: TurnResult = world.submit_end_turn(EndTurnCommand.create())
	# **Before the replay starts**, for the same reason the selection below is
	# taken here: the playback can finish inside its own call.
	_computer_played = result.ai_result != null
	# **Before the replay starts.** [method EventPlayback.play] finishes
	# *inside its own call* when there is nothing to show, so `_on_ai_step({})`
	# -- and the hand-back in it -- runs before anything below this line.
	# Capturing after the call gave a quiet computer turn
	# `_selection_before_turn == -1`, which is the fallback and not the
	# carry-over.
	#
	# The drop is the remake's and the engine has no such thing:
	# `[0x005162F0]` carries the selection straight through the computer's
	# turn. See [method _resume_selection].
	_selection_before_turn = _selected
	_deselect()
	# **The whole turn, as events.** The two hand-overs, the mission script's
	# runs, the ground tick and every one of the computer's actions arrive in
	# the order they happened, each carrying what it changed; the playback
	# lands them on the mirror as it draws them (docs/100 section 2). The
	# turn's own script runs are presented by the `script` arm of
	# [method _play_event_body] rather than here, because the set pieces they
	# fire belong to the frame their event is drawn in.
	#
	# **The pacing is the computer's.** [constant EventPlayback.STEP_SECONDS]
	# of free picture between two shown events is what lets a 39-alien turn
	# be followed; a player's own command passes none ([method _play_command]).
	# The finish callback hands the turn back -- the mirror check, the
	# camera's compatibility return, the selection -- so nothing is repeated
	# here whether the playback ended inside `play()` or frames later.
	_command_note = ""
	_playing_turn = true
	_playback.play(world.take_events(), Callable(self, "_on_ai_step"),
		Callable(self, "_apply_event"), EventPlayback.STEP_SECONDS,
		Callable(self, "_picture_busy"))
	# The turn's autosave, for *Undo last turn* (docs/43 section 5).
	if _may_command_now():
		_autosave(HudTables.SLOT_UNDO_TURN)
	return result


## The start of every player command.
##
## docs/97 section 34: the engine probes the fog before every player command
## (`0x00481F00`, once per command from `aViewPlayer.cpp`'s dispatcher), and
## the groups that probe wakes stay woken. The probe marks a `fog_probe`
## event, which the command's own playback lands as its quiet prefix.
func _begin_command() -> void:
	if world != null:
		var _woken: int = world.probe_fog()


## The world the **picture** reads: the mirror, or the truth before one exists.
##
## Every reader of what is on screen goes through this. [member world] is read
## to submit a command, to ask whether one is allowed, and to say what the
## rules currently are -- the mission's end, the pad's gates, the movement
## query behind the selection. See [member _shown].
func shown() -> World:
	return _shown if _shown != null else world


## Throw the mirror away and take a fresh one.
##
## Called where the truth moved without events anybody can replay: a save
## loaded, a deployment placed, the campaign entering a mission, a debug key.
## It also drops whatever the journal had recorded, because those deltas
## describe a world that no longer exists.
func _resync_shown() -> void:
	if world == null:
		_shown = null
		return
	var _dropped: Array[Dictionary] = world.take_events()
	_shown = world.clone()
	if _units != null:
		_units.shown_ref = _shown
	_fog.viewer = _watching_seat()


## The silent arm of the opening, and the mirror moved with it.
##
## `0x0041A073`: a mission with nobody to place skips the deployment turn and
## stands on turn 1 before the player sees it ([method
## World.skip_deployment_turn]). The three entries that take that arm -- a
## bare `--mission=`, the campaign's own entry into a mission with an empty
## pool, and the debugging step between missions -- all reach it **after**
## [method _build] has taken the picture's mirror, and the skip is a write to
## the truth that leaves no delta anybody can replay. Left there, the plate
## read `0` off the mirror while the truth stood on 1, and the first command
## found the two hashes apart and resynchronised with a warning: a desync
## counted against a picture that had simply never been told. So the skip is
## followed by a fresh mirror here, the way a loaded save's is ([method
## _resume_loaded_mission]), and by the status line that reads the turn.
func _skip_deployment_turn() -> void:
	if world == null:
		return
	world.skip_deployment_turn()
	_resync_shown()
	_refresh_status()


## The seat the picture is drawn for, read off the truth: for the moment a
## command is over, when the mirror has caught up with it.
func _watching_seat() -> int:
	return _seat_of(world)


## The seat the picture is drawn for, read off `at`.
##
## The human player holding the turn, and while the computer holds it the one
## that handed it over -- a fog pass for player 255 is the aliens' own view of
## the map, which would show the squad as contacts and every alien as a body.
## A `hand_over` delta asks with the **mirror**: the truth's rotation has
## already run past the computer's turn to the next human seat, and with two
## of them the whole replay would otherwise be drawn through the wrong fog.
func _seat_of(at: World) -> int:
	if at == null:
		return -1
	if at.turn.current_player != TurnState.PLAYER_COMPUTER:
		return at.turn.current_player
	if _fog.viewer >= 0:
		return _fog.viewer
	return at.turn.previous_player


## Land one event's delta on the mirror and mark the picture stale.
##
## This is where the picture catches up with the rules, and the whole design
## is in the timing of the call: the playback makes it when the animation it
## is drawing reaches the change ([method EventPlayback.apply_current]), and
## otherwise when the event's presentation is over.
##
## **Nothing is rebuilt here.** The quiet events between two shown ones land
## several deltas in one frame, and the rebuild -- every body freed and made
## again, a fog pass, the terrain diff, the overlay -- is
## [method _flush_picture]'s, once, at the moment the picture is next read.
func _apply_event(event: Dictionary) -> void:
	if _shown == null or event.is_empty():
		return
	var kind: String = DictRead.as_string(event["kind"])
	var payload: Dictionary = DictRead.as_dict(event.get("payload", {}))
	_shown.apply_delta(DictRead.as_dict(event.get("delta", {})))
	_fog.note_event(kind, DictRead.as_int(event.get("slot", -1)), payload)
	if kind == "hand_over":
		_fog.viewer = _seat_of(_shown)
	_picture_stale = true


## Draw the mirror as it now stands, if a delta has landed since it was last
## drawn: one rebuild of the bodies over a fresh fog pass, the terrain and
## the overlay. Called once a frame from [method _process], before a
## presenter reads the picture ([method _on_ai_step]), and by a presenter
## that landed a delta at a moment of its own ([method _land_current_delta]).
##
## **Deferred while a set piece runs.** A set piece is queued against the
## state *after* its event -- [method _queue_setpiece] lands the delta first,
## because a door's leaves turn towards the state the cell is going to have
## and a lift travels to the height it is going to stand at -- and the bodies
## and the terrain keep the state before it for as long as the queue draws
## the change: the footbridge's riders fall dead in the mirror, the platform's
## passengers ride from where they were. The queue's drain flushes
## ([method _process]), and a presenter with a moment of its own inside a
## sequence forces it ([method _land_current_delta]).
func _flush_picture(force: bool = false) -> void:
	if not _picture_stale:
		return
	if not force and _sequences != null and _sequences.is_running():
		return
	_picture_stale = false
	if _units != null and shown() != null:
		_units.build(shown(), _geometry, _textures, _picture_fog())
	# **A set piece owns the cells it animates.** Painting a door to its final
	# height while its ten frames are queued would snap it open, snap it shut
	# and animate it open again; the drain repaints instead. Deferring is
	# [method _redraw_terrain]'s, and so is remembering that it did -- a
	# forced flush inside a sequence has already cleared [member _picture_stale]
	# and would never come back here.
	var _cells: int = _redraw_terrain()
	_refresh_overlay(force)


## What a set piece deferred, paid the frame its queue empties.
##
## A presenter that lands its delta at a moment of its own
## ([method _land_current_delta]) forces a flush from **inside** its own
## sequence: the bodies are rebuilt from the mirror, the terrain is not --
## a set piece owns the cells it animates -- and [member _picture_stale] is
## cleared on the way out. So the terrain half has to be owed on a flag of
## its own, or nobody comes back for it. What that lost was the mine a walker
## stepped on: `core` cleared the cell and the mirror agreed, and the model
## and its tint went on standing there until an unrelated delta happened to
## ask for another repaint.
func _drain_deferred_repaints() -> void:
	if _sequences != null and _sequences.is_running():
		return
	if _terrain_stale:
		var _repainted: int = _redraw_terrain()
	if _overlay_stale:
		_refresh_overlay()


## The moment of a presenter's own: the delta of the event on screen lands
## and the picture is redrawn from it **now**, inside the sequence that
## reached the change. The death stage of a shot calls it before it takes
## the casualty's body away, so the mirror loses the record in the frame the
## blood appears and the target band over the cell goes with it; the
## teleporter calls it on the frame it moves its traveller and the roof unit
## on the first frame of its fall.
func _land_current_delta() -> void:
	var _landed: bool = _playback.apply_current()
	_flush_picture(true)


## The fog answer the whole picture reads this frame.
##
## The walkers are answered at the cell their **body** is drawn on, which is
## what makes an alien come out of the fog in the frame it comes out of the
## fog rather than when the turn changes (docs/100 section 4).
func _picture_fog() -> Dictionary[int, int]:
	if _shown == null:
		return {}
	var at: Dictionary[int, Vector2i] = {}
	if _units != null:
		at = _units.walking_cells()
	return _fog.states(_shown, at)


## The mirror and the truth must agree once every delta has landed.
##
## A field no delta carried shows up here and nowhere else, which is what
## replaces the per-mechanic holds this design removed. Resynchronising is the
## safe answer -- a picture one field behind is worse than a picture that
## jumped -- and the count is reported rather than swallowed.
func _check_mirror() -> bool:
	if world == null or _shown == null:
		return true
	_flush_picture()
	if _shown.canonical_hash_hex() == world.canonical_hash_hex():
		return true
	_desyncs += 1
	push_warning("the picture's mirror fell behind the world; resynchronised: "
		+ "; ".join(world.mirror_diff(_shown)))
	_resync_shown()
	_picture_stale = true
	_flush_picture()
	return false


func _after_command(note: String) -> void:
	_picture_stale = false
	_units.build(shown(), _geometry, _textures, _picture_fog())
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
	# **The remake's, and said so.** The engine does *not* end a turn by
	# itself: both call sites of `0x0041DA20` are inside the interface's own
	# dispatcher `fcn.0041B6E0`, and all four places that walk for the next
	# unit with points (`fcn.00471E00`) follow the walk with `fcn.004533D0`,
	# the view-mode re-apply, and nothing else. What the original does when a
	# squad runs out is drop the selection (`0x00472B10`), which leaves an
	# empty panel and a dark pad -- and that is what this is a convenience
	# over. Nothing can be commanded with no points anywhere: every pad
	# command needs at least one.
	if _auto_end_turn_wanted():
		_auto_end_pending = true


# --- the battle interface (docs/43) ---------------------------------------

## Redraw the ground overlay from the world and the selection.
## **Deferred while a set piece runs, like the bodies and the terrain**
## ([method _flush_picture]). The overlay is drawn from the mirror, which
## stands *after* the event a set piece is drawing -- a platform's riders are
## already on their destination cells -- so a refresh mid-ride (the hover,
## the far/near switch as the camera flies) would put the bands where the
## deck is going while the bodies are still on the way. It is owed to the
## drain instead; *force* is the presenter's own moment inside a sequence
## (the death stage of a shot takes the band over the casualty with it).
func _refresh_overlay(force: bool = false) -> void:
	if _ground == null or world == null:
		return
	if not force and _sequences != null and _sequences.is_running():
		_overlay_stale = true
		return
	_overlay_stale = false
	_far_drawn = _far_view()
	_ground.refresh(_art, shown(), _selected, _last_query, _hover, _bands,
		turn_player(), _far_drawn, _hover_gates_overlay(), _deploying())


## Whether the ground overlay still waits for the pointer before it draws the
## selection's reachable cells and target bands.
##
## The original's rule, and the right one for a mouse: the dots follow the
## cursor over the legal set. Under touch there is no cursor -- a hover exists
## only while a finger is down, and on the cell the finger happens to be on --
## so selecting a soldier showed no reachable set at all and a destination had
## to be guessed at. Off the gate, the set is the selection's own.
func _hover_gates_overlay() -> bool:
	return _touch == null or not _touch.enabled()


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
	# The pickup message's own clock (docs/24 section 7.2, a divergence): it
	# holds the mission the way the original's does, and takes itself down
	# after five seconds rather than waiting for a button. Not under a screen
	# the player opened over the mission -- that owns the input while it is
	# up, so it owns the clock with it.
	if _screen == null:
		_hud.tick_info(delta)
	if _far_view() != _far_drawn:
		_refresh_overlay()
	_poll_hover()


## The cell under the pointer, read when the pointer moves: inside the
## window it is the ray pick's answer, outside it none. The hovered cell
## gates the digits and wears the frame (docs/43 section 3), and the ring
## reads it for its tiers.
func _poll_hover() -> void:
	if _screen != null or not _hud.visible:
		return
	# Only when the viewport's own pointer moved: a driver's synthetic motion
	# (the agent server) sets the hover through the event, and re-reading a pointer
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
		cell = cell_under(_rig.camera(), shown(), pointer, 1.0)
	if _hud.ring.is_up():
		var _changed: bool = _hud.ring.hover(_rig.camera(), pointer)
	if cell != _hover:
		# `0x00471DC4`: the hover tick, and it is **gated on a command being
		# armed** -- `fcn.00471D10` only reaches it with the UI mode
		# `[0x516310]` at 1, 2 or 3, which is exactly the window in which the
		# ring is up. Ungated it would be a machine gun on plain mouse motion.
		if _hud.ring.is_up() and cell.x >= 0:
			_play_interface(AudioTables.INTERFACE_HOVER_CELL)
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
## paths and the briefing need a campaign, and *Jump to visible enemy* needs
## one. The original's magnifier has no test in front of it; this one has the
## cache's, because a page it cannot open is a lit button that answers nothing
## ([method InfoText.has_unit_pages]).
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
			var pages: InfoText = _item_descriptions()
			return pages != null and pages.has_unit_pages()
		HudTables.EVENT_NEXT_UNIT:
			# Dark on turn 0: `fcn.00471E00` refuses before the first
			# hand-over (docs/43 section 4.5).
			return _may_command_now() and not _deploying() \
				and next_friendly_slot(world, _selected) >= 0
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
	# **Leaving the place interface with nobody on the map is refused, and
	# refused before the click.** The button stays lit -- *Next player* has
	# no turn-0 gate in the original (`0x0041DA20` cmd 2), which hands over
	# an empty map and loses by wipeout on turn 1 -- but this remake keeps
	# the player on turn 0 and says why (docs/92 section 7.4). The refusal
	# is the remake's own, so it takes the sound of a refusal, not of a
	# press: the line, and nothing heard.
	if number == HudTables.EVENT_NEXT_PLAYER and _deploying() \
			and not _may_leave_deployment():
		_say_deploy(DEPLOY_LINE_NEED_ONE)
		return
	# `fcn.00450D70` plays `click_2` on a column slot with an event behind it,
	# past the availability gate and not in front of it -- an unavailable
	# button is silent as well as inert (docs/28 section 2.5).
	_play_interface(AudioTables.INTERFACE_COLUMN_PRESS)
	match number:
		HudTables.EVENT_FREE_CAMERA:
			# docs/43 section 2's mode 0: `fcn.00453410` sets the view mode
			# **and** flies to `fcn.004532A0`'s placement, the whole map from
			# `0x23A50` up. Setting the mode alone -- which is what stood here
			# -- left the button with nothing to show for itself.
			if _director != null:
				var _over: float = _director.view_overview()
			else:
				_rig.set_view_mode(CameraRig.View.SCRIPT)
			_sync_hud()
		HudTables.EVENT_UNIT_VIEW:
			if _deploying():
				_set_deploy_view(CameraRig.View.EYES)
			else:
				_set_view(CameraRig.View.EYES)
		HudTables.EVENT_MAP_VIEW:
			if _deploying():
				_set_deploy_view(CameraRig.View.MAP)
			else:
				_set_view(CameraRig.View.MAP)
		HudTables.EVENT_USER_VIEW:
			if _deploying():
				_set_deploy_view(CameraRig.View.UNIT)
			else:
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
			# A deliberate departure from `lKillPlayerUnits` `0x0047BC60`:
			# forfeiting stamps the computer end-state slot instead of killing
			# the squad. With the player's own slot still zero, mission_result()
			# classifies that as defeat and the normal debriefing recovers every
			# survivor. No turn is handed over and no loss is recorded.
			#
			# The truth was written and nothing was marked, so the mirror is
			# resynchronised rather than advanced -- the `nuke` cheat's own
			# shape, gate included: a resync under a running playback would
			# pull the picture out from under it. Without the resync the
			# plate read the verdict off a mirror that had none, while the
			# truth refused every command: live buttons over a dead board.
			if _playback.is_running():
				return
			world.game_control.set_slot(GameControl.END_STATE_SLOTS - 1, 1)
			_resync_shown()
			_refresh_status(_status_note)
			_check_mission_end()
		HudTables.EVENT_NEXT_PLAYER:
			# **Leaving the place interface is a hand-over.** *Next player*
			# has no turn-0 gate in the original (`0x0041DA20` cmd 2), and it
			# is the only way a deployed campaign mission reaches turn 1
			# ([method World.skip_deployment_turn] has the call graph that
			# forces it) -- which is why the ride, the reinforcement and
			# every other `NEXT TURN` of turn 1 happens before the player's
			# first command rather than after it: `_C_106` opens with the
			# platform carrying the squad down. The player presses the
			# button themselves, as the original has them do. The one
			# refusal, nobody on the map, was made above the click.
			if _deploying():
				# `0x0041DA20` cmd 2 clears the selection word and wipes
				# the panel before the hand-over runs.
				_deploy_slot = Roster.NO_SLOT
				if _hud != null:
					_hud.set_line("")
				# The unit view first, so [method _restore_camera_on]
				# re-applies it rather than the deployment's map view. No
				# autosave here: slot 31 was written when the interface went
				# up ([method _open_deployment_or_start]), with the pool
				# still full, as the retail `_31_.sav` is.
				_begin_mission_view()
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
		HudTables.EVENT_MAGNIFIER:
			# `0x0045391C`: the mode toggles and the pointer changes with it
			# -- `0x0045F030(10)` while it is on and `(0)` when it goes off.
			# The engine's own cursor is a sprite in fullscreen and
			# `IDC_CROSS` on the windowed path (`0x0045F040`); this remake
			# draws no cursor of its own, so the windowed answer is the one
			# it can give.
			_magnifier = not _magnifier
			_apply_cursor()
			# The columns learn the mode from [method _refresh_status] and
			# from nothing else -- that is the one caller of
			# [method MissionHud.refresh] -- and the caption under the
			# pointer is *Deactivate* while it is on (`0x00451815`). With
			# the note the last command left, so a redraw says nothing new.
			_refresh_status(_status_note)


## A pad socket, or its key: one of the six commands (docs/29 section 1.1).
## The gate runs here as well as on the pad, because the key has no socket.
func _on_pad_command(number: int) -> void:
	if not _command_available(number):
		return
	# `fcn.00471310` plays `click_2` once the socket's executor has run
	# (docs/28 section 2.5) -- past the gate, so a dark socket is silent.
	_play_interface(AudioTables.INTERFACE_PAD_PRESS)
	match number:
		HudTables.COMMAND_DEFEND:
			var _ticket: int = hold_fire()
		HudTables.COMMAND_HEAL:
			var _healed: Dictionary = heal_selected()
		# The three quiet commands go through the playback like every other:
		# their events have no picture, so `play()` lands them and finishes
		# inside its own call -- but a command that skipped it left the
		# events on the journal and the pad reading a mirror one command
		# behind (the stimulant's points did not show until the next walk).
		HudTables.COMMAND_STIMULANT:
			_begin_command()
			var _spent: bool = world.submit_stimulant(
				SpendStimulantCommand.create(_selected))
			_command_note = ""
			_play_command()
		HudTables.COMMAND_WEAPON_MODE:
			_begin_command()
			var _toggled: bool = world.submit_toggle_weapon(
				ToggleWeaponCommand.create(_selected))
			_command_note = ""
			_play_command()
		HudTables.COMMAND_REST:
			_begin_command()
			var _rested: bool = world.submit_stand_down(
				StandDownCommand.create(_selected))
			_command_note = ""
			_play_command()
		HudTables.COMMAND_USE:
			var _used: UseResult = use_in_front()


## The interface as scalars, for the agent server's `/state`.
func hud_view() -> Dictionary:
	return _hud.view() if _hud != null else {}


func ground_overlay() -> GroundSprites:
	return _ground


## A column button by its event, as a click on it (the agent's `hud event`).
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
	var slots: PackedInt32Array = shown().unit_slots()
	var start: int = slots.find(after) + 1
	for step: int in range(slots.size()):
		var slot: int = slots[(start + step) % slots.size()]
		var view: Dictionary = shown().unit_view(slot)
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

	func body_frames(slot: int, weapon: int = -1) -> Dictionary:
		if main._units == null:
			return {"to_break": 0, "spin": 0, "after_break": 0}
		return main._units.body_frames(slot, weapon)

	func fire_body(slot: int, tx: int, ty: int,
			weapon: int = -1) -> Dictionary:
		if main._units == null:
			return {"to_break": 0, "spin": 0, "after_break": 0}
		var _seconds: float = main._units.fire(slot, tx, ty, weapon)
		return main._units.body_frames(slot, weapon)

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

	func play_cues_slots(cues: Array[Dictionary]) -> PackedInt32Array:
		if main._audio == null or cues.is_empty():
			return PackedInt32Array()
		return main._audio.play_cues(cues, "shot")

	func sound_playing(slot: int) -> bool:
		return main._audio != null and main._audio.slot_playing(slot)

	func muzzle(weapon: int, sx: int, sy: int, tx: int, ty: int,
			shooter: int = MapState.NO_UNIT,
			pattern: Array[Dictionary] = []) -> void:
		if main._triggers == null or main._fx == null:
			return
		# The creator's own write over the flag: a round begins its flight.
		# Every creator clears `0x004FE63C` **before** it allocates -- the top
		# of `0x0042A930` is the write, ahead of its first `aGetMemory` -- so
		# a full pool leaves the flag down and the engine waits its hundred
		# frames. The *flag* reproduces that; the **stage** no longer does,
		# because it also ends when nothing the muzzle made is left in the
		# pool ([method BlobTriggers.in_flight]), and a full pool made
		# nothing. That is the divergence written down at
		# [constant ShotSequence.WAIT_FRAMES] and it applies here for the same
		# reason: the engine's hundred are rendered frames and the queue's are
		# twenty a second. The other half of the write stays as it was -- the
		# wait is cut short when nothing was made for a reason the engine could
		# not have had, a computed kind the switch does not name or a model
		# this world set does not carry, and without it the sequence burns
		# `WAIT_FRAMES` of dead screen per shot with the replay held behind it.
		var waits: bool = ShotSequence.waits_for_projectile(weapon)
		main._fx.set_arrived(not waits)
		# Every part the weapon's own call sites name, where this shooter's
		# model carries one -- weapon 12 names two and fires a burst from
		# each (docs/28 section 8.1.1).
		var joints: Dictionary[String, Vector3i] = {}
		if main._units != null and shooter != MapState.NO_UNIT:
			var parts: Array = main._triggers.joints("weapon_muzzle", weapon)
			# **And the part a creator resolves for itself.** Ten of the
			# thirteen push `"M"` inside their own body rather than taking it
			# as an argument, so the document's joint column is empty for them
			# and the shot used to leave the body axis
			# ([constant BlobTriggers.CREATOR_JOINTS]).
			for key: Variant in main._triggers.creators("weapon_muzzle",
					weapon):
				var own: String = DictRead.as_string(
					BlobTriggers.CREATOR_JOINTS.get(
						DictRead.as_string(key), ""))
				if not own.is_empty():
					parts.append(own)
			for name: Variant in parts:
				var part: String = DictRead.as_string(name)
				if not part.is_empty() and not joints.has(part) \
						and main._units.has_muzzle(shooter, part):
					joints[part] = main._units.muzzle_point(shooter, part)
		# The **shooter's** tile beside the muzzle point: the muzzle switch's
		# arms run on the source cell, and one of them reads that cell's
		# placed object rather than the point (BlobTriggers.SHOCK_WAVE_CREATOR).
		var made: int = main._triggers.muzzle(weapon,
			main._muzzle_of(sx, sy, shooter), main._muzzle_of(tx, ty), joints,
			Vector2i(sx, sy), Vector2i(tx, ty),
			main._object_of(sx, sy), main._object_of(tx, ty),
			main._unit_byte_of(tx, ty), pattern)
		# A point-blank burst asks for nested creators the constructor table
		# cannot build -- the zoom bobs and the plasma sparks its own branch
		# runs at the target (docs/28 section 8.1.1). They go in through the
		# same seam a set piece uses, so they draw from the one stream.
		made += _drain_programs()
		# **The creator's own write, which is not the same test as "it made
		# nothing"** -- the whole rule, and why, is
		# [method ShotSequence.arrived_after_muzzle]. Waiting on `made == 0`
		# alone burned the whole hundred frames on every shot at an adjacent
		# target: nothing in the pool raises the flag for a burst, so the
		# sequence sat out five seconds of dead screen before the impact
		# stage killed the victim.
		main._fx.set_arrived(ShotSequence.arrived_after_muzzle(waits,
			main._triggers.arrived_write(), made,
			main._fx.in_use() >= BlobPool.SLOTS))

	func impact(weapon: int, tx: int, ty: int,
			pattern: Array[Dictionary] = []) -> void:
		if main._triggers == null:
			return
		var _made: int = main._triggers.impact(weapon,
			main._muzzle_of(tx, ty), Vector2i(tx, ty),
			main._object_of(tx, ty), main._unit_byte_of(tx, ty), pattern)
		# **The impact end asks for creators too**, and used to drop them on
		# the floor: weapon 36's shock wave is a transcribed creator and the
		# only way it reaches the pool is this drain.
		var _ran: int = _drain_programs()

	## The tile creators the last muzzle or impact asked for, run: a creator
	## that reads a cell -- the control map, the cell's placed object -- and
	## takes the tile inputs (the shock wave, [constant
	## BlobTriggers.SHOCK_WAVE_CREATOR]).
	func _drain_programs() -> int:
		var ran: int = 0
		for request: Dictionary in main._triggers.take_programs():
			var creator: String = DictRead.as_string(request["creator"])
			var extra: PackedInt32Array = DictRead.as_int32_array(
				request["extra"])
			var tile: Vector2i = DictRead.as_vector2i(request["tile"])
			var args: PackedInt32Array = PackedInt32Array([tile.x, tile.y])
			args.append_array(extra)
			spawn_program(creator, args)
			ran += 1
		return ran

	func pool_arrived() -> bool:
		return main._fx == null or main._fx.arrived

	func pool_live() -> int:
		return 0 if main._fx == null else main._fx.live()

	func muzzle_in_flight() -> bool:
		return main._triggers != null and main._triggers.in_flight()

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

	## The casualty leaves the picture **and the mirror** in this frame: the
	## event on screen is the one that killed it, and its delta lands here
	## rather than when the playback moves on, so the band over the cell and
	## the radar's blip go with the body.
	func hide_unit(slot: int) -> void:
		main._land_current_delta()
		if main._units != null:
			var _was: bool = main._units.hide_now(slot)

	func suppress_unit(slot: int) -> void:
		if main._units != null:
			main._units.suppress(slot)

	## A body coming back is coming back **where the event put it**: the
	## teleporter's traveller on the exit cell, the roof unit's alien on its
	## landing cell, so the delta lands before the reveal.
	func show_unit(slot: int) -> void:
		main._land_current_delta()
		if main._units != null:
			main._units.reveal(slot)

	func insert_object(model: String, at: Vector3i, yaw: int = 0) -> bool:
		return main._scenery != null and main._scenery.insert_object(model, at, yaw)

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

	func free_position(eye: Vector3i, look: Vector3i) -> Vector3i:
		return eye if main._rig == null else main._rig.free_position(eye, look)

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
