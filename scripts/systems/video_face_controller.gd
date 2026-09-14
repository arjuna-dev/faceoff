class_name VideoFaceController
extends RefCounted

## Connects a local detector's candidates to a fighter head and an optional
## MediaRoom. The detector remains outside this class so platform code can use
## MediaPipe, CameraFeed, or another implementation.

signal tracking_changed(face: Dictionary)
signal face_texture_changed(texture: Texture2D)

var tracker := FaceTracker.new()
var processor := FaceTextureProcessor.new()
var face_target: Node
var media_room: MediaRoom
var last_texture: Texture2D

func configure(target: Node, room: MediaRoom = null) -> void:
	face_target = target
	media_room = room

func process_detected_frame(frame: Image, candidates: Array[Dictionary], delta: float) -> Dictionary:
	var state := tracker.update_faces(candidates, delta)
	# During the tracker grace period keep the last good texture. A detector
	# result is required before replacing it, which prevents a blank frame from
	# flashing onto the fighter when tracking is briefly uncertain.
	if bool(state.get("visible", false)) and not candidates.is_empty():
		var face_image := processor.crop_face(frame, state)
		if face_image:
			last_texture = ImageTexture.create_from_image(face_image)
			if face_target and face_target.has_method("set_video_face_texture"):
				face_target.set_video_face_texture(last_texture)
			if media_room:
				media_room.replace_camera_track_with_processed_frames([face_image])
			face_texture_changed.emit(last_texture)
	elif not bool(state.get("visible", false)):
		last_texture = null
		if face_target and face_target.has_method("clear_video_face_texture"):
			face_target.clear_video_face_texture()
		face_texture_changed.emit(null)
	tracking_changed.emit(state)
	return state

func set_enabled(enabled: bool) -> void:
	tracker.set_enabled(enabled)
