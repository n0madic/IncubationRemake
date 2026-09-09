class_name ShotHost
extends RefCounted

## What a [ShotSequence] asks of the scene, and nothing more.
##
## The nine stages of `aPlayFightAnimation` (docs/42 section 4) need a body,
## a camera, an overlay, a sound system and the blob pool. They need them
## through this narrow surface so that the sequence can be driven in a
## headless suite by a recording double, and so that what the stages *do* is
## legible in one file rather than spread through `main.gd`. Every method
## here has a default that does nothing and answers "nothing to wait for",
## which is also what a scene without that layer answers.

## The frame counts of a slot's combat clip at speed 6.0 (docs/42 section
## 1.2): to its note, the spin after it, and from the note to the end. All
## zero for a body with no clip or no node.
func body_frames(_slot: int) -> Dictionary:
	return {"to_break": 0, "spin": 0, "after_break": 0}


## Turn the shooter's body and start its combat clip. Answers
## [method body_frames]' dictionary.
func fire_body(_slot: int, _tx: int, _ty: int) -> Dictionary:
	return {"to_break": 0, "spin": 0, "after_break": 0}


## Whether the body's clip is still advancing -- the play-out after the
## resume ends when it stops.
func body_playing(_slot: int) -> bool:
	return false


## `aContCHAnimation` -- run the clip on past its note. Answers the frames
## left to its end, zero when there is nothing to resume.
func resume_body(_slot: int) -> int:
	return 0


## `aStopCHAnimation` -- the body back to its idle.
func rest_body(_slot: int) -> void:
	pass


## The unit type byte of a slot's body, for the two the resume skips.
func body_type(_slot: int) -> int:
	return -1


## docs/42 section 4.3 -- the shot's camera. Answers the flight's frames.
func camera(_shot: Dictionary) -> int:
	return 0


## Whether the camera is still on its way.
func camera_flying() -> bool:
	return false


## docs/42 section 4.2 -- the caption of overlay 0.
func set_caption(_text: String) -> void:
	pass


func clear_caption() -> void:
	pass


## Every text and the caption off the screen -- the routine's end, and a
## skipped shot.
func clear_texts() -> void:
	pass


## One floating text (section 4.4) over a map cell.
func add_text(_text: String, _kind: int, _x: int, _y: int) -> void:
	pass


## Overlay type 0 is selected: the texts start to rise and fade.
func begin_fade() -> void:
	pass


func is_fading() -> bool:
	return false


## One displayed frame of overlay 0: the texts rise and fade.
func tick_overlay() -> void:
	pass


func play_cues(_cues: Array[Dictionary]) -> void:
	pass


## `play_cues`, with the buffers it took handed back.
##
## For the one routine that owns a fixed set of them: `0x00416271` creates
## **three** `crush.wav` buffers before the bomb run's loop and
## `0x00416364`..`0x004163A9` plays them in turn, so a routine has to be able
## to name a buffer again.
func play_cues_slots(_cues: Array[Dictionary]) -> PackedInt32Array:
	return PackedInt32Array()


## Whether a buffer this host handed out is still sounding.
##
## `aDirectSoundPlayBuffer` `0x00436EF0` is `IDirectSoundBuffer::Play(0, 0,
## flags)` with no `Stop` and no `SetCurrentPosition` in front of it, and Play
## on a buffer that is already running does nothing at all -- so a crump whose
## turn comes round while its own buffer still sounds is **silently dropped**,
## which is why the original's minefield is a handful of thuds and not a wall
## of them.
func sound_playing(_slot: int) -> bool:
	return false


## The muzzle switch and the projectile flag it writes.
func muzzle(_weapon: int, _sx: int, _sy: int, _tx: int, _ty: int,
		_shooter: int = -1) -> void:
	pass


## The impact switch at the target cell.
func impact(_weapon: int, _tx: int, _ty: int) -> void:
	pass


## `0x004FE63C`.
func pool_arrived() -> bool:
	return true


## `0x004FE640` -- the live-blob count the sweep maintains.
func pool_live() -> int:
	return 0


## Whether any record the muzzle switch just made is still flying.
##
## The other half of the flight stage's condition -- the reasoning is at
## [constant ShotSequence.WAIT_FRAMES]. The default is **true**, "there is
## still something to watch", against the rest of this class: [method
## pool_arrived] already defaults to "nothing to wait for" and answers first,
## so a host that implements neither must not be handed a second way to stall.
func muzzle_in_flight() -> bool:
	return true


## `0x0042B490` -- put the *arrived* flag back down.
##
## The other half of [method pool_arrived]: a sequence that acts on a landing
## must acknowledge it, or the next frame sees the same one again. The bomb
## run `0x004160F0` is the sequence that does, once per crump.
func clear_arrived() -> void:
	pass


## `aDeleteAllBlobs` `0x0041E370` -- every record dropped at once.
##
## One sequence ends with it: the bomber's fly-past `0x00415E90`, whose last
## act before returning is to empty the pool so the bomb run that follows
## starts with nothing of its own in it.
func clear_pool() -> void:
	pass


## `0x0042B4B0` -- the position of the pool's first live record, which two
## sequences point the camera's target at.
func pool_first() -> Vector3i:
	return Vector3i.ZERO


## `0x00405320(obj, 5)` -- the casualty leaves the picture in this frame.
func hide_unit(_slot: int) -> void:
	pass


## `0x00405320(obj, 5)` on a body that is **coming back**: the traveller a
## teleporter carries is hidden for thirty frames and shown again, so it must
## not be the destroying [method hide_unit] -- the two are not the same call.
func suppress_unit(_slot: int) -> void:
	pass


## `0x00405320(obj, 1)` -- a body held out of the picture is shown again.
func show_unit(_slot: int) -> void:
	pass


## Run a death or damage creator (docs/42 section 4.8) with tile arguments.
func spawn_program(_creator: String, _args: PackedInt32Array) -> void:
	pass


# --- what the unit animations of docs/42 section 7 ask on top ---------------

## The placed object's position of a slot's body, in engine units -- where
## it is **drawn**, which during a replay is not where the world has it.
func object_of(_slot: int) -> Vector3i:
	return Vector3i.ZERO


## A cell's object position: its centre at its height.
func cell_object(_x: int, _y: int) -> Vector3i:
	return Vector3i.ZERO


## `0x0047AD70` -- the unit's height in world units, for the orbits' target.
func unit_height(_slot: int) -> int:
	return 0


## The eye and the target as the routine reads them (`0x00403780`).
func camera_eye() -> Vector3i:
	return Vector3i.ZERO


func camera_target() -> Vector3i:
	return Vector3i.ZERO


## `0x0040EEE0` -- a flight; answers its frames.
func fly(_eye: Vector3i, _target: Vector3i) -> int:
	return 0


## `0x00403560` -- the camera set for this frame, no flight.
func set_camera(_eye: Vector3i, _target: Vector3i) -> void:
	pass


## The jump's camera: the eye kept, the target on the flyer.
func set_camera_target(_target: Vector3i) -> void:
	pass


## `0x004039A0` -- a vector through the three-angle matrix.
func rotate(v: Vector3i, _angles: Vector3i) -> Vector3i:
	return v


## `0x00403AA0` -- `(pitch, yaw)` from one point to another.
func orient(_from: Vector3i, _at: Vector3i) -> Vector2i:
	return Vector2i.ZERO


## Run a creator that takes a **position** rather than a tile (the trail,
## the zoom bob, the push's dust), with `extra` after the three coordinates.
func spawn_at(_creator: String, _at: Vector3i,
		_extra: PackedInt32Array = PackedInt32Array()) -> void:
	pass


## `aRandom2(base, span)` from the pool's own stream -- the computer's
## jump picks its scream with it.
func draw2(base: int, _span: int) -> int:
	return base


## The body drawn at a world position this frame, and turned to a yaw in
## 4096ths (`0x004051E0` with `0x00403AA0`'s angles).
func place_body(_slot: int, _at: Vector3i) -> void:
	pass


func turn_body(_slot: int, _yaw: int) -> void:
	pass


## The body back on its cell, as the next refresh would put it.
func settle_body(_slot: int) -> void:
	pass


## Overlay type 3 -- the centred caption of the orbits.
func set_centred_caption(_text: String) -> void:
	pass
