class_name FaceTracker
extends RefCounted

signal tracked_face_changed(face: Dictionary)

var enabled := true
var lost_grace_seconds := 0.65
var _lost_time := 0.0
var _smoothed := {"center": Vector2(0.5, 0.5), "size": 0.42, "confidence": 0.0, "visible": false}

func update_faces(candidates: Array[Dictionary], delta: float) -> Dictionary:
	if not enabled:
		_smoothed["visible"] = false
		return _smoothed.duplicate(true)
	var largest: Dictionary = {}
	var largest_area := 0.0
	for candidate in candidates:
		var rect: Rect2 = candidate.get("rect", Rect2())
		var area := rect.size.x * rect.size.y
		if float(candidate.get("confidence", 0.0)) >= 0.55 and area > largest_area:
			largest = candidate
			largest_area = area
	if largest.is_empty():
		_lost_time += delta
		if _lost_time > lost_grace_seconds:
			_smoothed["visible"] = false
			_smoothed["confidence"] = 0.0
		tracked_face_changed.emit(_smoothed.duplicate(true))
		return _smoothed.duplicate(true)
	_lost_time = 0.0
	var rect: Rect2 = largest.get("rect", Rect2(0.25, 0.15, 0.5, 0.7))
	var target_center := rect.get_center()
	var target_size := maxf(rect.size.x, rect.size.y)
	_smoothed["center"] = ( _smoothed["center"] as Vector2).lerp(target_center, 0.22)
	_smoothed["size"] = lerpf(float(_smoothed["size"]), target_size, 0.22)
	_smoothed["confidence"] = lerpf(float(_smoothed["confidence"]), float(largest.get("confidence", 0.8)), 0.22)
	_smoothed["visible"] = true
	tracked_face_changed.emit(_smoothed.duplicate(true))
	return _smoothed.duplicate(true)

func process_frame(_frame: Image, delta: float) -> Dictionary:
	# Native MediaPipe/CameraFeed adapters call update_faces with actual landmarks.
	# The mock keeps the contract testable on desktop and in headless CI.
	return update_faces([], delta)

func set_enabled(value: bool) -> void:
	enabled = value
