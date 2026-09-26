class_name AtomicFile
extends RefCounted

## A file replaced whole or not at all.
##
## The bytes are assembled beside the target under [constant TEMP_SUFFIX] and
## moved over it only after they read back exactly. A full disk, a short write
## or a crash mid-write must leave the previous file untouched, rather than
## truncate it and still report success. The campaign's save slots and the
## settings document are both written this way.

const TEMP_SUFFIX: String = ".writing"


## Replace *path* with *bytes*. The directory must exist. Answers whether the
## target now holds exactly these bytes; on `false` the old file is intact.
static func write(path: String, bytes: PackedByteArray) -> bool:
	var temporary: String = path + TEMP_SUFFIX
	if FileAccess.file_exists(temporary):
		var removed: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		if removed != OK:
			return false
	var file: FileAccess = FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	var write_error: Error = file.get_error()
	file.close()
	if write_error != OK or FileAccess.get_file_as_bytes(temporary) != bytes:
		var _discarded: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		return false
	var moved: Error = DirAccess.rename_absolute(
		ProjectSettings.globalize_path(temporary),
		ProjectSettings.globalize_path(path))
	if moved != OK:
		var _discarded: Error = DirAccess.remove_absolute(
			ProjectSettings.globalize_path(temporary))
		return false
	return true
