class_name AgentStateView
extends RefCounted

## What the game **is** right now, as one JSON-shaped document.
##
## The split from [AgentSession] is between what the game does and what it is:
## the session runs commands and mutates its own counters, this reads the tree
## and writes nothing. Everything here came over unchanged from the directory
## driver's reply builder, which is why the document a `POST /command` answers
## with is byte-for-byte the one `res-NNNN.json` used to carry.
##
## Every reader is conditional on the thing it reads existing. The shell means
## the game can be up with no mission behind it, and `/state` is answered from
## the first frame -- before a world, before a screen, and on the menu.

var _main: SliceMain = null
var _root: Window = null


func _init(main: SliceMain, root: Window) -> void:
	_main = main
	_root = root


## True while the picture still owes a command something -- a queued set piece,
## a walk, a combat clip, a flight, or the computer's turn being shown.
##
## It lives here rather than in the session so the `idle` countdown,
## `/health`'s `running` and `state.busy` cannot drift apart.
func busy() -> bool:
	if _main == null:
		return false
	return _main._picture_busy() or _main._playback.is_running()


## True once there is something to drive: a mission, or a screen over one.
##
## The directory driver spent 900 frames waiting for a world and then gave up,
## which put every scenario that opened on the menu into a timeout. The test is
## any screen and not only a shell one: between missions the campaign flow owns
## the picture, and its map is as much "the game is up" as a mission is.
func booted() -> bool:
	if _main == null:
		return false
	return _main.world != null or _main.screen_shown() != null


func build(frame: int) -> Dictionary:
	if _main == null:
		return {}
	var world: World = _main.world
	# **The world half is conditional.** The shell means the game can be up
	# with no mission behind it, and reading `world.turn` unconditionally would
	# take the driver down rather than report where it was.
	var document: Dictionary = {
		"mission": _main._mission,
		"frame": frame,
		"status": _main._status.text if _main._status != null else "",
		"note": _main._ai_note,
		"busy": busy(),
		"booted": booted(),
		"picture": picture(),
		"pool": pool(),
		# docs/92 section 7.29: how many effect lights the scene shader reads
		# now -- the mission's or, while it is up, the campaign map's.
		"effect_lights": effect_lights(),
		"overlay": overlay(),
		"camera": camera(),
		"shell": shell(),
		"campaign": _main.campaign.view() if _main.campaign != null else {},
		# The cutscene being played -- id, part, shot, frame, camera, focal --
		# and whether one of the front end's holds is counting down
		# (docs/92 section 7.19). Empty and false between them.
		"sequence": _main.sequence_view(),
		"holding": _main.holding(),
		"settings": _main.settings.view(),
		# The language every language-dependent file is being read for, so
		# a driven switch is observable (docs/92 section 7.6).
		"language": _main._paths.language if _main._paths != null else "",
		# **Above the `world == null` return.** A scenario that fails at the
		# shell, on the location map or on a turn-0 map has to be able
		# to say whether it was played straight too ([Cheats]).
		"cheats": Array(_main.cheats.active()),
		# What the pool holds right now, by wave: the clicks and the voices
		# of docs/28 sections 2.5 and 4.3 are single frames of sound, so a
		# drive that only read the world could not tell a silent interface
		# from a noisy one. Above the return too, since slice 9: the
		# briefing page's voice-over plays with no world behind it.
		"sounds": sounds(),
		# The music player: which programme, which family, which track and
		# whether a stream is running. A cutscene's soundtrack **is** its CD
		# track (docs/101 section 6), so a silent cutscene is invisible in a
		# snapshot that only lists the wave pool.
		"music": _main._audio.music_view() if _main._audio != null else {},
	}
	if world == null:
		return document
	document["turn"] = world.turn.turn
	document["player"] = world.turn.current_player
	document["selected"] = _main.selected_slot()
	document["hud"] = _main.hud_view()
	# The place interface while the mission is on turn 0 (docs/43 section
	# 5.5): whether it is up, the pool record on the panel, the roster's
	# slots and the landing cells, with and without somebody on them.
	document["deployment"] = _main.deployment_view()
	document["markers"] = markers()
	document["visible_rect"] = visible_rect()
	# Whether a body is on its way. The world moves in one call and the
	# picture does not: a walk that never played looks exactly like a walk
	# that finished if only the endpoint is read.
	document["walking"] = _main._units != null and _main._units.is_walking()
	# Whether the computer's turn is being drawn. The interface refuses
	# every press while it is (docs/43 section 5.2), which is invisible from
	# the world alone -- the truth is back on the marines before the first
	# alien moves. It is the **mirror's** seat, not the playback: a player's
	# own command runs through the same playback and is not a replay.
	document["replay"] = _main._watching_the_computer()
	document["gore_level"] = world.gore_level
	document["ai_level"] = world.turn.ai_level
	document["units"] = units()
	document["reachable"] = query(false)
	document["warp"] = query(true)
	document["hash"] = world.canonical_hash_hex()
	# **The picture's own world, and how far behind it is.** `hash` is the
	# truth's; `shown_hash` is the mirror's and differs while a command or a
	# computer turn is still being drawn, `pending` counts the events whose
	# deltas have not landed, and `desyncs` is how often the mirror had to be
	# resynchronised because a delta did not carry everything -- zero is the
	# contract (docs/100 section 2).
	var mirror: World = _main.shown()
	document["shown_hash"] = mirror.canonical_hash_hex() if mirror != null \
		else ""
	document["pending"] = _main._playback.remaining() \
		if _main._playback != null else 0
	document["desyncs"] = _main._desyncs
	# What differs, named, while the two hashes differ: empty otherwise, and
	# computed only then, because a driver polling every frame must not pay
	# a whole-world comparison for a level picture.
	document["mirror_diff"] = Array(world.mirror_diff(mirror)) \
		if mirror != null and mirror != world \
		and document["shown_hash"] != document["hash"] else []
	return document


## Every wave the twenty-slot pool is holding, in slot order.
func sounds() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	if _main._audio == null or _main._audio.pool() == null:
		return out
	var pool_ref: AudioPool = _main._audio.pool()
	for index: int in pool_ref.live():
		out.append(DictRead.as_string(pool_ref.slot(index)["path"]))
	return out


## Which screen is up: the shell's own, or the campaign flow's.
func shell() -> Dictionary:
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
## use: 640x480 on 4:3, wider or taller elsewhere (docs/43 section 8).
func visible_rect() -> Array:
	if _root == null:
		return []
	var size: Vector2 = _root.get_visible_rect().size
	return [size.x, size.y]


## What the ground overlay drew, as `[x, y, library, element]` rows.
func markers() -> Array:
	var out: Array = []
	var ground: GroundSprites = _main.ground_overlay()
	if ground == null:
		return out
	for cell: Vector2i in ground.drawn_cells():
		for sprite: Variant in ground.drawn_at(cell):
			var pair: Array = DictRead.as_array(sprite)
			out.append([cell.x, cell.y, pair[0], pair[1]])
	return out


## The cells the last selection's fill marked, as `[x, y]` pairs -- the walk
## targets a click may name, and the Jet Pack's jump targets beside them.
func query(warp: bool) -> Array:
	var out: Array = []
	var result: MoveMapResult = _main._last_query
	if result == null:
		return out
	for y: int in range(result.height):
		for x: int in range(result.width):
			var marked: bool = result.is_warp_target(x, y) if warp \
				else result.is_reachable(x, y)
			if marked:
				out.append([x, y])
	return out


## Every unit as the **picture** has it, which during a replay is not where
## the truth says it is: the mirror is a command behind (docs/100 section 2).
## `hash` beside it is the truth's, and `shown_hash` this world's, so a driver
## can tell the two apart.
func units() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var world: World = _main.shown()
	if world == null:
		return out
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
			"order": DictRead.as_int(view["order"]),
		})
	return out


func picture() -> Dictionary:
	var view: UnitsView = _main.units_view()
	var playing: PackedInt32Array = PackedInt32Array()
	if view != null:
		for slot: int in view.states:
			if view.is_playing(slot):
				playing.append(slot)
	var queue: SequenceQueue = _main._sequences
	return {
		"sequence": queue.current() if queue != null else "",
		"sequence_frames": queue.remaining() if queue != null else 0,
		"walking": view != null and view.is_walking(),
		"firing": view != null and view.any_busy(),
		"playing": playing,
		"suppressed": view.suppressed() if view != null \
			else PackedInt32Array(),
		"idle_starts": view.scheduler.starts if view != null else 0,
		"idle_frees": view.scheduler.frees if view != null else 0,
		"idle_slots": view.scheduler.entries.keys().size() \
			if view != null else 0,
		"playback": _main._playback.is_running(),
		"scenery": _main.scenery_count(),
		"scenery_objects": _main.scenery_objects(),
		"scenery_removed": _main.scenery_removed(),
		"script": _main.last_script(),
		"special_objects": _main._special.live_count() \
			if _main._special != null else 0,
	}


func effect_lights() -> Dictionary:
	var mission: EffectLights = _main._lights
	var backdrop: EffectLights = _main._backdrop_lights
	return {"mission": mission.lit() if mission != null else -1,
		"backdrop": backdrop.lit() if backdrop != null else -1,
		"first": (mission.describe() if mission != null and mission.lit() > 0
			else backdrop.describe() if backdrop != null else []),
		"backdrop_live": _main._backdrop_fx.blobs().size()
			if _main._backdrop_fx != null else -1}


## `live` is every record in use, by kind; `counted` is the sweep's own count
## `0x004FE640` -- classes 0 and 2 -- which is what a play-out waits on
## ([method BlobPool.live]). On `_C_102` the two are 2 and 0 at rest: the
## warning lights are in use and never counted.
func pool() -> Dictionary:
	var kinds: Dictionary[int, int] = {}
	var live: int = 0
	var blobs: BlobPool = _main._fx
	if blobs == null:
		return {"live": 0, "counted": 0, "kinds": kinds}
	for blob: Blob in blobs.blobs():
		live += 1
		kinds[blob.kind] = kinds.get(blob.kind, 0) + 1
	return {"live": live, "counted": blobs.live(), "kinds": kinds}


func overlay() -> Dictionary:
	var texts: FloatingTexts = _main._texts
	if texts == null:
		return {}
	return {
		"entries": texts.entries(),
		"caption": texts.caption(),
		"fading": texts.is_fading(),
	}


func camera() -> Dictionary:
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
