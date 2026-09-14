class_name SocialStorage
extends RefCounted

static func path(filename: String) -> String:
	var prefix := OS.get_environment("FACE_OFF_TEST_STORAGE_PREFIX").validate_filename()
	if not OS.get_environment("FACE_OFF_TEST_STORAGE_PREFIX").is_empty():
		var directory := "user://integration/" + prefix
		DirAccess.make_dir_recursive_absolute(directory)
		return directory + "/" + filename
	return "user://" + filename
