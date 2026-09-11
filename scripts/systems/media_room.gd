class_name MediaRoom
extends Node

signal permission_error(kind: String, message: String)
signal participant_media_changed(participant_id: String, kind: String, enabled: bool)
signal connection_quality_changed(quality: String)
signal reconnection_changed(is_reconnecting: bool)

var room_name := ""
var mic_enabled := false
var camera_enabled := false
var local_preview_enabled := false

func join_room(requested_room: String, _token: String = "") -> void:
	room_name = requested_room

func leave_room() -> void:
	room_name = ""

func publish_microphone(enabled: bool) -> void:
	mic_enabled = enabled

func publish_camera(enabled: bool) -> void:
	camera_enabled = enabled

func replace_camera_track_with_processed_frames(_frames: Array[Image]) -> void:
	pass

func set_remote_volume(_participant_id: String, _volume: float) -> void:
	pass

func set_remote_muted(_participant_id: String, _muted: bool) -> void:
	pass

func enumerate_devices() -> Dictionary:
	return {"microphones": [], "cameras": []}
