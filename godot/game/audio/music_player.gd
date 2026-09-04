class_name MusicPlayer
extends RefCounted

## The mission's `CDTrackProgram` playlist, as state rather than as a device.
##
## docs/20 section 7.3: the command takes one string, a dot-separated list of
## CD track numbers, and 111 of the shipped missions call it. The engine asks
## MCI for `cdaudio`; the GOG release intercepts that in `audio.dll` and hands
## back `music/Arack%02d.ogg`. That substitution is packaging, not engine
## (docs/28 section 6), so the converter copies the Ogg files and this plays
## them in the order the mission asked for, looping the list when it runs out.
##
## **Which family plays is measured, not chosen.** `music/` ships two,
## `Track02..20` and `Arack02..14`, identical for 02..08 and different from 09
## on. `Incubation.exe`'s import descriptor names `audio.dll` where the 1997
## build named `WINMM.dll`, and that shim is the one built with `Arack`;
## `sound.dll` is the same shim built with `Track`, and no descriptor anywhere
## in the tree names it (docs/28 section 6.1). `blob_tables.py` pins both
## format strings and the descriptor, so the family the converter copies is
## checked rather than asserted here.
##
## Holds no stream: [AudioSystem] asks what to play next and plays it. That is
## what lets the order be replayed headless.

var _tracks: PackedInt32Array = PackedInt32Array()
var _index: int = 0
## Tracks the cache actually carries. A `--no-music` conversion carries none,
## and a mission whose track is absent is quieter rather than broken.
var _available: PackedInt32Array = PackedInt32Array()


static func for_mission(tables: AudioTables, mission: String) -> MusicPlayer:
	var player: MusicPlayer = MusicPlayer.new()
	player._tracks = tables.playlist(mission)
	player._available = tables.tracks()
	return player


static func from_program(program: String,
		available: PackedInt32Array = PackedInt32Array()) -> MusicPlayer:
	var player: MusicPlayer = MusicPlayer.new()
	player._tracks = AudioTables.parse_playlist(program)
	player._available = available
	return player


func tracks() -> PackedInt32Array:
	return _tracks.duplicate()


func is_empty() -> bool:
	return _tracks.is_empty()


func index() -> int:
	return _index


## The track that should be playing now, or `-1` when the playlist is empty.
func current() -> int:
	if _tracks.is_empty():
		return -1
	return _tracks[_index % _tracks.size()]


## Advance to the next entry and answer it. The list loops, which is what a
## `CDTrackProgram` of six entries on a mission that lasts forty turns means.
func advance() -> int:
	if _tracks.is_empty():
		return -1
	_index = (_index + 1) % _tracks.size()
	return current()


## The next entry the cache can actually play, skipping any it does not carry.
##
## Answers `-1` rather than looping for ever when the cache holds none of the
## playlist -- a `--no-music` conversion, or one track that failed to copy.
func next_playable() -> int:
	if _tracks.is_empty() or _available.is_empty():
		return -1
	for _step: int in range(_tracks.size()):
		var track: int = advance()
		if _available.has(track):
			return track
	return -1


## The first playable entry without advancing past it -- what a mission opens
## with, as against what the end of a track asks for.
func first_playable() -> int:
	if _tracks.is_empty() or _available.is_empty():
		return -1
	if _available.has(current()):
		return current()
	return next_playable()


func rewind() -> void:
	_index = 0
