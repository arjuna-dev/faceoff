class_name LiveKitMediaRoom
extends MediaRoom

## Platform adapter seam for the native LiveKit SDK.
## This intentionally fails closed until a validated GDExtension/platform bridge is installed.

var native_bridge_available := false

func join_room(requested_room: String, token: String = "") -> void:
	room_name = requested_room
	if not native_bridge_available or token.is_empty():
		permission_error.emit("media", "LiveKit native bridge is not installed; using MockMediaRoom")
		connection_quality_changed.emit("unavailable")

func publish_microphone(enabled: bool) -> void:
	if not native_bridge_available:
		permission_error.emit("microphone", "Microphone publishing requires a platform LiveKit adapter")
		return
	mic_enabled = enabled

func publish_camera(enabled: bool) -> void:
	if not native_bridge_available:
		permission_error.emit("camera", "Camera publishing requires a platform LiveKit adapter")
		return
	camera_enabled = enabled

func replace_camera_track_with_processed_frames(frames: Array[Image]) -> void:
	if not native_bridge_available:
		permission_error.emit("camera", "Processed camera tracks require native video frame access")
		return
	if frames.is_empty():
		return

func enumerate_devices() -> Dictionary:
	return {"microphones": [], "cameras": []}
