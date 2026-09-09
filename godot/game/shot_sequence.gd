class_name ShotSequence
extends RefCounted

## `aPlayFightAnimation` `0x0040BD70` (docs/42 section 4) as steps of the
## [SequenceQueue]: the clip to its note, the caption, the camera, the round
## in flight, the impact, the deaths, the numbers, the resume, the play-out.
##
## The original is one blocking routine with nine stages in a fixed order;
## the remake runs the same stages on the queue's 20 fps clock, each with the
## engine's own frame count where the engine has one -- `int(len / 6) / 3`
## after the note, up to 100 frames for the round, up to 20 for the pool --
## and open-ended where the engine spins on a condition. `core` has resolved
## the whole shot before any of this is queued; nothing here changes a unit,
## and the casualties are hidden **here**, in the death stage, the way
## `0x00405320(obj, 5)` hides them, rather than by the rebuild.
##
## Everything the stages touch goes through [ShotHost], so the suite drives
## them on a recording double and the scene supplies the real thing.
##
## What the second reading of the routine corrected (2026-09-03,
## `presentation_tables.py`): the death switch branches on the **weapon**,
## not on the shot's severity -- the severity slot is zeroed before the
## muzzle switch and the muzzle arms write the value the death switch reads
## -- and the arrived flag is set by fourteen update arms and *cleared* by
## arm 45.

## `cmp ecx, 0x64` at `0x0040D4C1` -- the round is waited for this long.
##
## **A bound, not a timing -- and the two clocks are not the same one.** The
## engine's loop is `call 0x0040B6F0 / call 0x0042B480`: a message pump that
## also animates and draws (`0x0040B6F0` reaches `0x00417E10`, which calls
## `0x00406FC0`, which sweeps the blob pool through `aCheckInBlobObjects`
## `0x0041E3D0`) and then a read of the *arrived* flag `0x004FE63C`. So its
## hundred are a hundred **rendered** frames at whatever rate the machine
## runs, where the queue's hundred are a hundred at docs/42 section 1.2's
## twenty a second.
##
## That difference is invisible for every round that raises the flag, and it
## is the whole of the wait for one that never does. Fourteen update arms
## write the flag and the spore cannon's kind 22 is not among them, nor are
## the kind-23 sparks it spawns -- so weapon 25, the Cy'Coo's, spent the bound
## in full: five seconds of dead screen after a round that had already landed.
##
## The stage therefore ends on **either** the flag or the round being gone
## ([method BlobTriggers.in_flight]), and the hundred stays as the bound it
## is. The second half is the remake's own and is a deliberate divergence, in
## the same class as `blob_kinds.gd`'s guard on kind 41: the original sits out
## its hundred frames there too, only faster.
const WAIT_FRAMES: int = 100
## `cmp eax, 0x14` at `0x0040E256` -- the pool is waited for this long.
const POOL_FRAMES: int = 20
## **The remake's bound** on the two spins the engine leaves open-ended --
## the camera's flight and the play-out until the pool empties and the fade
## ends. A flight always arrives and a blob always dies, so the bound is a
## safety net and not a timing; it is named so nobody mistakes it for one.
const SAFETY_FRAMES: int = 300
## What a shot lasts when its shooter has no fight clip to measure -- see
## the `clip_frames` floor below. `EventPlayback.STEP_SECONDS` at the engine's
## own twenty frames a second.
const NO_CLIP_FRAMES: int = 9
## docs/42 section 4.6 -- the muzzle arms that write 0 over the wait flag.
const WAIT_SKIPPED_WEAPONS: Array[int] = [0x0F, 0x11, 0x14, 0x15, 0x1B, 0x1E,
	0x1F, 0x20, 0x24, 0x25]
## docs/42 section 4.8 (corrected) -- what the muzzle arm leaves for the
## death switch: 3 for the four sniper arms, 1 for five, 2 for weapon 40, and
## 0 -- the switch's default arm -- for every other weapon.
const DEATH_STYLE_BY_WEAPON: Dictionary = {15: 3, 30: 3, 31: 3, 32: 3,
	9: 1, 11: 1, 17: 1, 22: 1, 44: 1, 40: 2}
## `cmp byte [esi+0x4C], 0x37` -- the one type the resume skips.
const NO_RESUME_TYPE: int = 0x37
## The `special` column (docs/21 section 2) the death switch tests.
const SPECIAL_KILL_FIRE: int = 0x10
const SPECIAL_BARREL: int = 0x0C
const SPECIAL_CASE: int = 0x0D
## docs/21 section 2 -- the species the switch singles out.
const SPECIES_OBJECT: int = 2
const SPECIES_MACHINE: int = 3
## docs/42 section 4.4 -- *Paralyzed* is the stun of weapon 45.
const PARALYSING_WEAPON: int = 45
## docs/42 section 4.4 -- the entry types, and the severity each marker adds.
const TYPE_MISSED: int = 0
const TYPE_NO_DAMAGE: int = 1
const TYPE_DAMAGE: int = 2
const TYPE_KILLED: int = 3
const TYPE_DAMAGE_OBJECT: int = 4
const TYPE_KILLED_OBJECT: int = 5
const SEVERITY_HIT: int = 1
const SEVERITY_DAMAGE: int = 2
const SEVERITY_KILL: int = 3
## The step names, in order, for a suite.
const STAGE_CLIP: String = "shot.clip"
const STAGE_CAMERA: String = "shot.camera"
const STAGE_MUZZLE: String = "shot.muzzle"
const STAGE_FLIGHT: String = "shot.flight"
const STAGE_IMPACT: String = "shot.impact"
const STAGE_POOL: String = "shot.pool"
const STAGE_RESUME: String = "shot.resume"
const STAGE_SETTLE: String = "shot.settle"


## docs/42 section 4.4 -- the entry type of one resolved cell.
static func entry_type(marker: int, species: int) -> int:
	match marker:
		Combat.MARKER_MISS:
			return TYPE_MISSED
		Combat.MARKER_RESOLVED:
			return TYPE_NO_DAMAGE
		Combat.MARKER_HIT:
			return TYPE_DAMAGE_OBJECT if species == SPECIES_OBJECT else TYPE_DAMAGE
		Combat.MARKER_KILLED:
			return TYPE_KILLED_OBJECT if species == SPECIES_OBJECT else TYPE_KILLED
	return -1


## The highest severity over the targets: 1 for a hit, 2 for damage, 3 for a
## kill, whatever the species (`0x0040C65D`, `0x0040C6DE`, `0x0040C752`).
static func severity(targets: Array[Dictionary]) -> int:
	var worst: int = 0
	for target: Dictionary in targets:
		match DictRead.as_int(target["marker"]):
			Combat.MARKER_RESOLVED:
				worst = maxi(worst, SEVERITY_HIT)
			Combat.MARKER_HIT:
				worst = maxi(worst, SEVERITY_DAMAGE)
			Combat.MARKER_KILLED:
				worst = maxi(worst, SEVERITY_KILL)
	return worst


## The text one entry floats (section 4.4), from the caller's strings.
static func entry_text(target: Dictionary, weapon: int,
		strings: Dictionary) -> String:
	match DictRead.as_int(target["marker"]):
		Combat.MARKER_MISS:
			return DictRead.as_string(strings.get("missed", "Missed"))
		Combat.MARKER_RESOLVED:
			if DictRead.as_bool(target.get("stunned", false)) \
					and weapon == PARALYSING_WEAPON:
				return DictRead.as_string(strings.get("paralyzed", "Paralyzed"))
			return "0"
		Combat.MARKER_HIT:
			return str(DictRead.as_int(target.get("dealt", 0)))
	return ""


## Whether the routine waits for the round (section 4.6).
static func waits_for_projectile(weapon: int) -> bool:
	return not WAIT_SKIPPED_WEAPONS.has(weapon)


## What the *arrived* flag stands at once the muzzle has been made.
##
## `creator_write` is [method BlobTriggers.arrived_write]: the value the last
## burst creator stored, or [constant BlobTriggers.ARRIVED_UNWRITTEN] when no
## creator wrote one. **It wins whenever there is one**, because the engine's
## own test is `steps <= 0` and not "the creator made nothing": a point-blank
## burst writes the 1 and *then* fills the pool with zoom bobs at the target.
##
## The two fallbacks are the remake's own and neither is in the original.
## A weapon that skips the wait never looks at the flag, and a muzzle that
## made nothing at all with room to spare made nothing for a reason the engine
## could not have had -- a computed kind the switch does not name, or a model
## this world set does not carry -- so waiting on it would be waiting for a
## refusal. A **full** pool is different: the engine leaves the flag down
## there too, and so does this. What the *stage* then does with a full pool is
## not the engine's any more -- it made no record, so
## [method BlobTriggers.in_flight] is false and the flight ends at once -- for
## the reason set out at [constant WAIT_FRAMES].
static func arrived_after_muzzle(waits: bool, creator_write: int, made: int,
		pool_full: bool) -> bool:
	if not waits:
		return true
	if creator_write != BlobTriggers.ARRIVED_UNWRITTEN:
		return creator_write == 1
	return made == 0 and not pool_full


## Queue the whole shot. `shot` carries what `core` resolved and what the
## scene knows about the units on the marked cells:
## [codeblock]
## {"shooter": slot, "sx", "sy", "tx", "ty", "weapon", "own": bool,
##  "reaction": bool, "xp": int, "caption": String,
##  "targets": [{"slot", "x", "y", "marker", "dealt", "stunned",
##               "type_id", "player", "species", "special", "size",
##               "cell": row-major index}],
##  "strings": {"missed", "paralyzed"},
##  "cues_shot": [...], "cues_impact": [...], "cues_barrel": [...]}
## [/codeblock]
## Answers the frames the engine's own counts add up to -- the clip, the
## spin, the muzzle, the impact, the resume -- **not** the bounds on the
## open-ended waits: the replay waits for the picture through
## [method EventPlayback.advance]'s `busy`, and a hold that summed the bounds
## stalled every computer shot for their whole length.
static func enqueue(queue: SequenceQueue, host: ShotHost,
		shot: Dictionary) -> int:
	var shooter: int = DictRead.as_int(shot["shooter"])
	var weapon: int = DictRead.as_int(shot["weapon"])
	var tx: int = DictRead.as_int(shot["tx"])
	var ty: int = DictRead.as_int(shot["ty"])
	var targets: Array[Dictionary] = []
	for entry: Variant in DictRead.as_array(shot.get("targets", [])):
		targets.append(DictRead.as_dict(entry))
	var waits: bool = waits_for_projectile(weapon)
	var total: int = 0

	# 1. The clip to its note, then `int(len / 6) / 3` frames.
	var frames: Dictionary = host.body_frames(shooter, weapon)
	var to_break: int = DictRead.as_int(frames.get("to_break", 0))
	var spin: int = DictRead.as_int(frames.get("spin", 0))
	var after_break: int = DictRead.as_int(frames.get("after_break", 0))
	# **A shooter with no clip still takes a moment.** `aPlayFightAnimation`
	# always has a fight animation to play (docs/42 section 4), so the frames
	# to its break are what every stage after it is measured from. A shooter
	# the *fire* selector has no entry for answers zero for all three, and the
	# whole shot then collapses into about three frames: the muzzle, the
	# impact and the death stage all inside a sixth of a second, so the target
	# is hit with no attack visible at all.
	#
	# **It is a real set, not a hypothesis.** Over the six cached missions'
	# nineteen `(type, weapon, player)` triples, three reach no `fire` entry:
	# the Barrel and the Case, which carry weapon 0 and never shoot, and
	# **the Dec'Ther** -- type 52 with weapon 22 on `A_MK_0B.3DI` -- which
	# does. `docs/40` section 7.2 as amended is the rule behind it: nine unit
	# types get fewer than three clips and two get none at all.
	#
	# The floor is **the remake's own number** and is the same one
	# [constant EventPlayback.STEP_SECONDS] uses for an event's minimum, so a
	# clipless shot lasts as long as the replay's own step rather than as long
	# as nothing.
	var clip_frames: int = maxi(1, to_break + spin)
	if to_break + spin <= 0:
		clip_frames = NO_CLIP_FRAMES
	queue.enqueue(STAGE_CLIP, clip_frames,
		func(frame: int, _total: int) -> void:
			if frame == 1:
				var _started: Dictionary = host.fire_body(shooter, tx, ty,
					weapon))
	total += clip_frames

	# 2 and 3. The caption, then the camera -- after the clip, as the engine
	# orders them; the flight is open-ended and the step waits for it.
	queue.enqueue_until(STAGE_CAMERA, SAFETY_FRAMES,
		func() -> bool: return not host.camera_flying(),
		func(frame: int, _total: int) -> void:
			if frame == 1:
				host.set_caption(DictRead.as_string(shot.get("caption", "")))
				var _flight: int = host.camera(shot))

	# 5 and 6. The sounds and the muzzle; the flag is the creator's to
	# write, and the round is waited for unless the arm skips the wait.
	var cues_shot: Array[Dictionary] = _cues(shot, "cues_shot")
	queue.enqueue(STAGE_MUZZLE, 1,
		func(_frame: int, _total: int) -> void:
			host.play_cues(cues_shot)
			host.muzzle(weapon, DictRead.as_int(shot["sx"]),
				DictRead.as_int(shot["sy"]), tx, ty, shooter))
	total += 1
	if waits:
		queue.enqueue_until(STAGE_FLIGHT, WAIT_FRAMES,
			func() -> bool: return host.pool_arrived() \
				or not host.muzzle_in_flight())

	# 7 and 8. The impact, the deaths, the blood, the numbers.
	var cues_impact: Array[Dictionary] = _cues(shot, "cues_impact")
	var cues_barrel: Array[Dictionary] = _cues(shot, "cues_barrel")
	queue.enqueue(STAGE_IMPACT, 1,
		func(_frame: int, _total: int) -> void:
			host.impact(weapon, tx, ty)
			host.play_cues(cues_impact)
			var barrels: int = _deaths(host, shot, targets)
			if barrels > 0:
				host.play_cues(cues_barrel)
			_texts(host, shot, targets)
			host.begin_fade()
			host.tick_overlay())
	total += 1
	if waits:
		queue.enqueue_until(STAGE_POOL, POOL_FRAMES,
			func() -> bool: return host.pool_live() == 0,
			func(_frame: int, _total: int) -> void: host.tick_overlay())

	# 9. The resume past the note and the play-out, then the idle.
	var resumes: bool = to_break > 0 and host.body_type(shooter) != NO_RESUME_TYPE
	if resumes:
		queue.enqueue(STAGE_RESUME, maxi(1, after_break),
			func(frame: int, _total: int) -> void:
				if frame == 1:
					var _left: int = host.resume_body(shooter)
				host.tick_overlay())
		total += maxi(1, after_break)
	queue.enqueue_until(STAGE_SETTLE, SAFETY_FRAMES,
		func() -> bool: return _settled(host, shooter),
		func(frame: int, frames_total: int) -> void:
			host.tick_overlay()
			if frame == frames_total or _settled(host, shooter):
				host.rest_body(shooter)
				host.clear_texts())
	return total


## The play-out's end: the pool empty, the fade over, the clip stopped
## (`0x0040E2F2`..`0x0040E30C`).
static func _settled(host: ShotHost, shooter: int) -> bool:
	return host.pool_live() == 0 and not host.is_fading() \
		and not host.body_playing(shooter)


static func _cues(shot: Dictionary, key: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for entry: Variant in DictRead.as_array(shot.get(key, [])):
		out.append(DictRead.as_dict(entry))
	return out


## docs/42 section 4.4 -- one floating text per entry, at its cell.
static func _texts(host: ShotHost, shot: Dictionary,
		targets: Array[Dictionary]) -> void:
	var weapon: int = DictRead.as_int(shot["weapon"])
	var strings: Dictionary = DictRead.as_dict(shot.get("strings", {}))
	for target: Dictionary in targets:
		var kind: int = entry_type(DictRead.as_int(target["marker"]),
			DictRead.as_int(target.get("species", 0)))
		if kind < 0:
			continue
		host.add_text(entry_text(target, weapon, strings), kind,
			DictRead.as_int(target["x"]), DictRead.as_int(target["y"]))


## docs/42 section 4.8 -- the death switch, per entry, in cell order.
##
## Answers how many barrels flew, for the `explosion2.wav` the class-0x0C arm
## adds.
static func _deaths(host: ShotHost, shot: Dictionary,
		targets: Array[Dictionary]) -> int:
	var sx: int = DictRead.as_int(shot["sx"])
	var sy: int = DictRead.as_int(shot["sy"])
	var weapon: int = DictRead.as_int(shot["weapon"])
	var style: int = DictRead.as_int(DEATH_STYLE_BY_WEAPON.get(weapon, 0))
	# The damage arm reads **the last unit the sweep looked at** -- one local
	# for the whole switch (`[esp+0x34]`, loaded once at `0x0040DA79` and
	# written by the arms) -- so a multi-target shot sprays every damaged unit
	# by the last one's player and size.
	#
	# **In the pattern's order, not the cell array's.** The loop at
	# `0x0040DA83` walks the *marked* arrays -- the markers at `0x004FBFF8`
	# and the coordinates at `0x004FBE54`/`0x004FBE72`, indexed by `edi` up to
	# the count at `[esp+0x2C]` -- which `aMarkTargetCells` filled in the
	# weapon's own order. The whole-cell-array sweep two dozen instructions
	# above it (`0x0040DA07`) is the **hatch** pass and a different loop.
	# Sorting by cell index here disagreed with [method Main._shot_voice],
	# which models the same local; the sort was the wrong half.
	var last: Dictionary = {}
	var ordered: Array[Dictionary] = targets
	if not ordered.is_empty():
		last = ordered[ordered.size() - 1]
	var barrels: int = 0
	for target: Dictionary in ordered:
		var x: int = DictRead.as_int(target["x"])
		var y: int = DictRead.as_int(target["y"])
		var species: int = DictRead.as_int(target.get("species", 0))
		var special: int = DictRead.as_int(target.get("special", 0))
		var large: bool = DictRead.as_int(target.get("size", 0)) == 1
		var kind: int = entry_type(DictRead.as_int(target["marker"]), species)
		match kind:
			TYPE_DAMAGE:
				# `cmp byte [ebp+0x45], 0xFF`, `mov al, [ebp+0x4C]`.
				if DictRead.as_int(last.get("player", 0)) == BlobPrograms.PLAYER_COMPUTER \
						or DictRead.as_int(last.get("size", 0)) != 1:
					host.spawn_program(BlobPrograms.BLOOD_FLOOD,
						PackedInt32Array([sx, sy, x, y, 0]))
				else:
					host.spawn_program(BlobPrograms.BLOOD_SPRAY_LARGE,
						PackedInt32Array([sx, sy, x, y, 0]))
			TYPE_KILLED:
				host.hide_unit(DictRead.as_int(target["slot"]))
				if special == SPECIAL_KILL_FIRE:
					host.spawn_program(BlobPrograms.KILL_FIRE,
						PackedInt32Array([x, y, 0]))
					continue
				var machine: bool = species == SPECIES_MACHINE
				match style:
					1:
						if machine:
							host.spawn_program(BlobPrograms.FIRE_EXPLOSION,
								PackedInt32Array([x, y, 2]))
						else:
							host.spawn_program(BlobPrograms.BLOOD_FLOOD,
								PackedInt32Array([sx, sy, x, y, 2 if large else 1]))
					2:
						host.spawn_program(BlobPrograms.FIRE_DEATH,
							PackedInt32Array([x, y]))
					3:
						if machine:
							host.spawn_program(BlobPrograms.FIRE_EXPLOSION,
								PackedInt32Array([x, y, 2]))
						elif large:
							host.spawn_program(BlobPrograms.BLOOD_FLOOD,
								PackedInt32Array([sx, sy, x, y, 2]))
						else:
							host.spawn_program(BlobPrograms.BLOOD_BURST,
								PackedInt32Array([x, y]))
					_:
						if machine:
							host.spawn_program(BlobPrograms.FIRE_EXPLOSION,
								PackedInt32Array([x, y, 2]))
						elif large:
							host.spawn_program(BlobPrograms.BLOOD_FLOOD,
								PackedInt32Array([sx, sy, x, y, 2]))
							host.spawn_program(BlobPrograms.FLYING_DEBRIS,
								PackedInt32Array([x, y]))
						else:
							host.spawn_program(BlobPrograms.SPECIES_BURST,
								PackedInt32Array([x, y]))
			TYPE_KILLED_OBJECT:
				host.hide_unit(DictRead.as_int(target["slot"]))
				if special == SPECIAL_BARREL:
					var twice: int = DictRead.as_int(target.get("size", 0)) * 2
					host.spawn_program(BlobPrograms.FLYING_UNIT,
						PackedInt32Array([x, y, twice]))
					host.spawn_program(BlobPrograms.FIRE_EXPLOSION,
						PackedInt32Array([x, y, twice]))
					barrels += 1
				elif special == SPECIAL_CASE:
					host.spawn_program(BlobPrograms.BARREL_BURST,
						PackedInt32Array([x, y]))
	return barrels
