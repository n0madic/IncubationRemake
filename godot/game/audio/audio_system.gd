class_name AudioSystem
extends Node

## The one class in the remake that opens a stream and makes a noise.
##
## Everything above it is decision and bookkeeping: [AudioTables] says what to
## play and how loud, [AudioEvents] says which event plays what, [AudioPool]
## says which of the twenty slots a sound may have, [MusicPlayer] says what
## comes next. All four are plain `RefCounted` with no audio server in them, so
## `tests/test_sound.gd` can replay the whole layer headless. This node is the
## thin edge where those decisions become sound, and it is deliberately the
## only file in the layer that would need a device to test.
##
## **Streams come out of the cache, not out of `res://`.** The cache lives in
## `user://` and never goes through Godot's import pipeline, so the waves are
## opened with `AudioStreamWAV.load_from_buffer` (through [method
## with_pad_counted], which is why it is not `load_from_file`) and the music
## with `AudioStreamOggVorbis.load_from_file`. Each is loaded once and kept: the
## whole wave set is about 2.6 MiB and a firefight would otherwise re-read the
## same file several times a second.
##
## **A sound's lifetime is its sequence's** (docs/28 section 1.4). A cue that
## loops is started when its sequence starts and killed when the sequence ends
## -- never when the sample runs out -- so [method stop_tag] is not a
## convenience, it is the rule.

## The FX volume the options record holds, in hundredths of a decibel: 0 is
## full scale. Every cue is scaled from this by its own volume-control id.
## docs/20 section 8 owns the options record; until the remake has an options
## screen this is its default.
const DEFAULT_FX_VOLUME: int = 0
const DEFAULT_MUSIC_VOLUME: int = -600
## How long [method shutdown] lets the audio server run before quitting, in
## milliseconds. Fifty was the measured threshold headless; this is twice it,
## and it is spent once, on the way out.
const SHUTDOWN_WAIT_MS: int = 100

## `"RIFF"` read as a little-endian dword, and the one byte a padded wave is
## longer than its own header claims.
const RIFF_MAGIC: int = 0x46464952
const RIFF_PAD: int = 1

var _tables: AudioTables = null
var _events: AudioEvents = null
var _pool: AudioPool = null
## The tag that tells a `CDTrackProgram` from a mission name in
## [method music_source].
const MUSIC_PROGRAM: String = "program:"

var _music: MusicPlayer = null
## What the playlist now loaded was asked for by -- a mission's name, or
## [constant MUSIC_PROGRAM] and a `CDTrackProgram` string. Held here rather
## than by the caller so that **every** way music stops clears it: a caller's
## own copy goes stale the moment the shell silences the mixer, and the map
## then declines to restart the track it thinks is already playing.
var _music_source: String = ""
## Which family [member _music]'s numbers index.
var _music_family: String = AudioTables.FAMILY_ARACK
var _fx_volume: int = DEFAULT_FX_VOLUME
var _music_volume: int = DEFAULT_MUSIC_VOLUME
var _streams: Dictionary[String, AudioStream] = {}
## The looping copy of a wave, made once and kept beside the one-shot.
##
## A wave may be asked for both ways -- `crush.wav` is a one-shot in the bomb
## run and a loop in nothing, `door.wav` the other way about -- so the loop
## flag cannot be written onto the shared stream.
var _loop_streams: Dictionary[String, AudioStream] = {}
var _players: Array[AudioStreamPlayer] = []
var _music_player: AudioStreamPlayer = null
## Names that failed to open, reported once each rather than per play.
var _unopenable: Dictionary[String, bool] = {}


func setup(tables: AudioTables, events: AudioEvents) -> void:
	_tables = tables
	_events = events
	_pool = AudioPool.with_slots(tables.play_slots())
	for index: int in range(_pool.size()):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "slot_%d" % index
		add_child(player)
		_players.append(player)
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "music"
	add_child(_music_player)
	_music_player.finished.connect(_on_music_finished)


## Release everything, and **give the audio server the frames it needs to
## agree**. Await this before quitting; see [method release] for why.
##
## Returns the number of frames it waited, so a caller can report it.
func shutdown() -> int:
	release()
	var tree: SceneTree = get_tree()
	if tree == null:
		return 0
	var started: int = Time.get_ticks_msec()
	var frames: int = 0
	while Time.get_ticks_msec() - started < SHUTDOWN_WAIT_MS:
		await tree.process_frame
		frames += 1
	return frames


## Stop every sound, drop every stream, and empty the decoded-stream cache.
##
## Synchronous and complete on its own terms -- but **not sufficient on its
## own**, which is the whole point of [method shutdown]. Reproduced in a
## twenty-five-line project outside this repository: an `AudioStreamPlayer`
## that has played an Ogg leaks four objects at exit -- the stream, its
## `OggPacketSequence` and both playbacks -- if the process quits in the same
## frame the stream is released. It is the audio server that still holds the
## playback, and it lets go on its next mix; loading the stream and never
## playing it leaks nothing, and playing it and then running a handful of
## frames before quitting leaks nothing either. Six process frames were enough
## headless, so [constant SHUTDOWN_WAIT_MS] is a wall-clock wait comfortably
## past that rather than a frame count tuned to one driver.
##
## This is why `_exit_tree` cannot fix it and did not: by the time the tree is
## being torn down there is no frame left to run.
func release() -> void:
	stop_music()
	stop_all()
	if _music_player != null:
		_music_player.stream = null
	for player: AudioStreamPlayer in _players:
		player.stream = null
	_streams.clear()
	_loop_streams.clear()


## The belt to [method shutdown]'s braces. A build that exits without awaiting
## `shutdown` still stops making noise here; it just reports the four objects.
func _exit_tree() -> void:
	release()


func pool() -> AudioPool:
	return _pool


func tables() -> AudioTables:
	return _tables


func events() -> AudioEvents:
	return _events


func set_fx_volume(hundredths: int) -> void:
	_fx_volume = hundredths


func set_music_volume(hundredths: int) -> void:
	_music_volume = hundredths
	if _music_player != null:
		_music_player.volume_db = AudioTables.volume_db(hundredths)


# --- playing ----------------------------------------------------------------

## Play one cue, and answer the slot it took or `-1` when it was dropped.
##
## A drop is the original's own behaviour on a full pool and is counted rather
## than reported: `aDirectSoundLoadSoundBuffer` hands back a slot the play
## routine refuses, and the sound is simply not heard.
func play_cue(cue: Dictionary, tag: String = "") -> int:
	if _pool == null or cue.is_empty():
		return -1
	var wave: String = DictRead.as_string(cue["wave"])
	var volume_id: int = DictRead.as_int(cue["volume_id"])
	var volume: int = _tables.scaled_volume(_fx_volume, volume_id)
	if volume == AudioTables.REFUSED:
		return -1
	var loop: bool = DictRead.as_bool(cue.get("loop", false))
	# **A `DSBPLAY_LOOPING` cue needs a stream that loops.** `AudioStreamWAV`
	# repeats only when its own `loop_mode` says so, and the shipped waves
	# carry none: every one of the nine looping sites was heard exactly once
	# and then stopped, while its sequence ran on. The bomber's engine is the
	# one that shows it -- `bomber.wav` is a couple of seconds against a
	# fly-past of `0x0042A8E0`'s 150 ticks -- but the door, the lift, the
	# platform and the drawbridge were all as short.
	var stream: AudioStream = _loop_stream_for(wave) if loop \
		else _stream_for(wave)
	if stream == null:
		return -1
	var slot: int = _pool.load_wave(wave, volume, volume_id, tag)
	if slot < 0:
		return -1
	_pool.play(slot, loop)
	var player: AudioStreamPlayer = _players[slot]
	player.stream = stream
	player.volume_db = AudioTables.volume_db(volume)
	# A one-shot frees its slot when the sample ends; a looping one does not,
	# because its sequence decides.
	arm_slot_end(player, _on_slot_finished.bind(slot), loop)
	player.play()
	return slot


## Arm (or disarm) the "this slot's sample ended" connection for one player.
##
## The connection is `CONNECT_ONE_SHOT`, and one-shot means *disconnected when
## the signal fires* -- not when the sound stops. `AudioStreamPlayer.stop()`
## does not emit `finished`, so every cue that was cut short by [method
## stop_slot] or [method stop_tag] -- which is every sound a sequence owns
## (docs/28 section 1.4) -- leaves its connection behind. The next cue the pool
## puts on that slot then connects the **same** bound callable a second time,
## and Godot refuses it with an error from inside the shot sequence.
##
## So the pending connection is dropped before a new one is made, which also
## covers the other order: a looping cue landing on a slot whose one-shot
## connection is still armed would have been freed under its own sequence the
## moment the previous sample would have ended.
static func arm_slot_end(player: AudioStreamPlayer, on_end: Callable,
		loop: bool) -> void:
	if player.finished.is_connected(on_end):
		player.finished.disconnect(on_end)
	if not loop:
		player.finished.connect(on_end, CONNECT_ONE_SHOT)


## Play every cue an event starts, and answer the slots they took.
func play_cues(cues: Array[Dictionary], tag: String = "") -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	for cue: Dictionary in cues:
		out.append(play_cue(cue, tag))
	return out


## Whether a slot handed out earlier is still sounding.
##
## What `IDirectSoundBuffer::Play` answers by doing nothing: a routine that
## owns a fixed set of buffers ([method SetpieceCamera.enqueue]'s bomb run)
## asks this before it plays into one again.
func slot_playing(slot: int) -> bool:
	if _pool == null:
		return false
	var record: Dictionary = _pool.slot(slot)
	return not record.is_empty() and DictRead.as_bool(record["playing"])


func stop_slot(slot: int) -> void:
	if _pool == null or not _pool.kill(slot):
		return
	if slot >= 0 and slot < _players.size():
		_players[slot].stop()
		_players[slot].stream = null


## End every sound one sequence started -- docs/28 section 1.4's rule.
func stop_tag(tag: String) -> int:
	if _pool == null:
		return 0
	var slots: PackedInt32Array = _pool.tagged(tag)
	for slot: int in slots:
		stop_slot(slot)
	return slots.size()


## End every looping buffer. What a skipped replay owes: a one-shot is already
## shorter than the picture, a loop would outlive it as a stuck hum.
func stop_looping() -> int:
	if _pool == null:
		return 0
	var slots: PackedInt32Array = _pool.looping()
	for slot: int in slots:
		stop_slot(slot)
	return slots.size()


func stop_all() -> void:
	if _pool == null:
		return
	for slot: int in _pool.live():
		stop_slot(slot)


func _on_slot_finished(slot: int) -> void:
	# Only if it is still the same sound: the slot may have been killed and
	# handed to something else between the sample ending and the signal.
	if _pool != null and not _pool.slot(slot).is_empty() \
			and not DictRead.as_bool(_pool.slot(slot)["looping"]):
		stop_slot(slot)


# --- music ------------------------------------------------------------------

func start_music(mission: String) -> int:
	if _tables == null:
		return -1
	_music = MusicPlayer.for_mission(_tables, mission)
	_music_family = AudioTables.FAMILY_ARACK
	_music_source = mission
	return _play_track(_music.first_playable())


## The same, from a `CDTrackProgram` string rather than from a mission name.
##
## The campaign map is a script and not a mission: the cache keys its playlist
## under `_C_XXX` like any other, but the map's `InitMap` is run for its
## `CreateBGB` lines anyway, and taking the programme out of the same run is
## what makes the two halves of that block one thing. It also works for a map
## the converter has no playlist row for.
## *family* names which of the two shipped families the numbers index:
## [constant AudioTables.FAMILY_ARACK] for a mission and the front end,
## [constant AudioTables.FAMILY_TRACK] for a cutscene (docs/92 section 7.19).
func start_program(program: String,
		family: String = AudioTables.FAMILY_ARACK) -> int:
	if _tables == null or program.is_empty():
		return -1
	_music = MusicPlayer.from_program(program, _tables.tracks_of(family))
	_music_family = family
	_music_source = program_source(program, family)
	return _play_track(_music.first_playable())


## What [method music_source] answers while *program* of *family* plays --
## so a caller asking "is this already playing" builds the same string.
static func program_source(program: String,
		family: String = AudioTables.FAMILY_ARACK) -> String:
	return MUSIC_PROGRAM + family + ":" + program


## Play one wave the cache carries under `audio/`, by its cache-relative path
## -- a briefing voice-over or the static extro's soundtrack, which no table
## names -- on a pool slot under *tag*. Answers the slot or -1.
func play_file(relative: String, tag: String = "") -> int:
	if _pool == null or _tables == null:
		return -1
	var stream: AudioStream = _stream_at(_tables.audio_path(relative), relative)
	if stream == null:
		return -1
	var volume: int = _fx_volume
	var slot: int = _pool.load_wave(relative, volume, 0, tag)
	if slot < 0:
		return -1
	_pool.play(slot, false)
	var player: AudioStreamPlayer = _players[slot]
	player.stream = stream
	player.volume_db = AudioTables.volume_db(volume)
	arm_slot_end(player, _on_slot_finished.bind(slot), false)
	player.play()
	return slot


func _on_music_finished() -> void:
	if _music != null:
		_play_track(_music.next_playable())


func _play_track(track: int) -> int:
	if track < 0 or _music_player == null:
		return -1
	var path: String = _tables.music_path(track, _music_family)
	var stream: AudioStream = _music_stream(path)
	if stream == null:
		return -1
	_music_player.stream = stream
	_music_player.volume_db = AudioTables.volume_db(_music_volume)
	_music_player.play()
	return track


func stop_music() -> void:
	_music_source = ""
	if _music_player != null:
		_music_player.stop()


func music() -> MusicPlayer:
	return _music


## What [method start_music] or [method start_program] was last given, or `""`
## when nothing is playing. A caller asks this instead of remembering.
func music_source() -> String:
	return _music_source


## What is on the music player right now -- the source string, the track the
## playlist stands on, the family it comes from and whether a stream is
## actually running. A driver that only read [method music_source] could not
## tell a programme that was asked for from one that reached a file.
func music_view() -> Dictionary:
	return {
		"source": _music_source,
		"family": _music_family,
		"track": _music.current() if _music != null else -1,
		"playing": _music_player != null and _music_player.playing,
		"volume": _music_volume,
	}


# --- streams ----------------------------------------------------------------

func _stream_for(wave: String) -> AudioStream:
	return _stream_at(_tables.wave_path(wave), wave)


## The same wave with its loop points set, made once and kept.
##
## `null` when the wave will not open or is not a sample this can loop --
## the caller then falls back to nothing rather than to a one-shot, which is
## the same answer a wave the cache does not carry already gets.
func _loop_stream_for(wave: String) -> AudioStream:
	if _loop_streams.has(wave):
		return _loop_streams[wave]
	var base: AudioStream = _stream_for(wave)
	if base == null:
		return null
	if not is_instance_of(base, AudioStreamWAV):
		return base
	var sample: AudioStreamWAV = base
	var looped: AudioStreamWAV = looping_copy(sample)
	if looped == null:
		return base
	_loop_streams[wave] = looped
	return looped


## A copy of `sample` that repeats from its first frame to its last.
##
## The end point is **counted**, not left at zero: `loop_end` is a frame
## number and a zero one is a loop of no length rather than "all of it".
## Static so the suite can check the arithmetic without a cache to load from.
static func looping_copy(sample: AudioStreamWAV) -> AudioStreamWAV:
	if sample == null:
		return null
	var copy: AudioStreamWAV = sample.duplicate()
	var frames: int = frame_count(copy)
	if frames <= 0:
		return null
	copy.loop_mode = AudioStreamWAV.LOOP_FORWARD
	copy.loop_begin = 0
	copy.loop_end = frames
	return copy


## How many frames a PCM sample holds: its bytes over the width of one frame.
##
## Answers 0 for a compressed format, whose byte count is not a frame count --
## nothing the cache carries is one, and a wrong loop point would be worse
## than no loop.
static func frame_count(sample: AudioStreamWAV) -> int:
	if sample == null:
		return 0
	var width: int = 0
	if sample.format == AudioStreamWAV.FORMAT_8_BITS:
		width = 1
	elif sample.format == AudioStreamWAV.FORMAT_16_BITS:
		width = 2
	if width == 0:
		return 0
	if sample.stereo:
		width *= 2
	return sample.data.size() / width


## One wave at *path*, cached under *key*.
func _stream_at(path: String, key: String) -> AudioStream:
	var wave: String = key
	if _streams.has(wave):
		return _streams[wave]
	if _unopenable.has(wave):
		return null
	if not FileAccess.file_exists(path):
		_unopenable[wave] = true
		push_warning("audio: %s is not in the cache" % wave)
		return null
	var stream: AudioStreamWAV = AudioStreamWAV.load_from_buffer(
		with_pad_counted(FileAccess.get_file_as_bytes(path)))
	if stream == null:
		_unopenable[wave] = true
		push_warning("audio: %s did not open" % wave)
		return null
	_streams[wave] = stream
	return stream


## A wave whose header counts the byte the file actually ends with.
##
## **125 of the 407 shipped `.wav` files are one byte longer than their `RIFF`
## size claims**, and all 125 for the same reason: the `data` chunk has an odd
## length, RIFF requires a pad byte after it, and the writer left the `RIFF`
## size at `36 + data` without counting that byte. The file is what a player
## expects -- `sp_hum_1.wav`, `w_lcg_0.wav` and fourteen more of the eighty-one
## the cache carries are in that set -- but Godot's loader compares the buffer
## against `RIFF size + 8` and prints a warning per file, from inside the shot
## sequence, every time one is opened.
##
## So the header is corrected in memory rather than the sample being touched:
## the decoded frames, mix rate, format, channel count and loop mode are
## identical either way, and nothing in the cache changes. **Only the exact
## one-byte case**, so a truncated file, a file with trailing rubbish or one
## that is not RIFF at all still reaches the loader as it is and still reports
## itself. Trimming the pad byte off instead is what does not work: the loader
## then seeks past the end of its own buffer and turns the warning into an
## error.
static func with_pad_counted(bytes: PackedByteArray) -> PackedByteArray:
	if bytes.size() < 12 or bytes.decode_u32(0) != RIFF_MAGIC:
		return bytes
	if bytes.size() != bytes.decode_u32(4) + 8 + RIFF_PAD:
		return bytes
	var fixed: PackedByteArray = bytes.duplicate()
	fixed.encode_u32(4, fixed.size() - 8)
	return fixed


func _music_stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	if _unopenable.has(path) or not FileAccess.file_exists(path):
		_unopenable[path] = true
		return null
	var stream: AudioStreamOggVorbis = AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		_unopenable[path] = true
		return null
	_streams[path] = stream
	return stream
