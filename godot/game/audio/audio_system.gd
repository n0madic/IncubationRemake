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
var _music: MusicPlayer = null
var _fx_volume: int = DEFAULT_FX_VOLUME
var _music_volume: int = DEFAULT_MUSIC_VOLUME
var _streams: Dictionary[String, AudioStream] = {}
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


## The belt to [method shutdown]'s braces. A build that exits without awaiting
## `shutdown` still stops making noise here; it just reports the four objects.
func _exit_tree() -> void:
	release()


func pool() -> AudioPool:
	return _pool


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
	var stream: AudioStream = _stream_for(wave)
	if stream == null:
		return -1
	var slot: int = _pool.load_wave(wave, volume, volume_id, tag)
	if slot < 0:
		return -1
	var loop: bool = DictRead.as_bool(cue.get("loop", false))
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
	return _play_track(_music.first_playable())


func _on_music_finished() -> void:
	if _music != null:
		_play_track(_music.next_playable())


func _play_track(track: int) -> int:
	if track < 0 or _music_player == null:
		return -1
	var path: String = _tables.music_path(track)
	var stream: AudioStream = _music_stream(path)
	if stream == null:
		return -1
	_music_player.stream = stream
	_music_player.volume_db = AudioTables.volume_db(_music_volume)
	_music_player.play()
	return track


func stop_music() -> void:
	if _music_player != null:
		_music_player.stop()


func music() -> MusicPlayer:
	return _music


# --- streams ----------------------------------------------------------------

func _stream_for(wave: String) -> AudioStream:
	if _streams.has(wave):
		return _streams[wave]
	if _unopenable.has(wave):
		return null
	var path: String = _tables.wave_path(wave)
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
