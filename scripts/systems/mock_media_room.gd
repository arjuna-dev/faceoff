class_name MockMediaRoom
extends MediaRoom

var devices := {
	"microphones": ["Mock microphone"],
	"cameras": ["Mock camera"]
}

func join_room(requested_room: String, _token: String = "") -> void:
	room_name = requested_room
	connection_quality_changed.emit("excellent")

func leave_room() -> void:
	room_name = ""
	mic_enabled = false
	camera_enabled = false

func publish_microphone(enabled: bool) -> void:
	mic_enabled = enabled
	participant_media_changed.emit("local", "audio", enabled)

func publish_camera(enabled: bool) -> void:
	camera_enabled = enabled
	participant_media_changed.emit("local", "video", enabled)

func enumerate_devices() -> Dictionary:
	return devices.duplicate(true)
