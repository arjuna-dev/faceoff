extends SceneTree

const ProtocolType = preload("res://scripts/systems/network_protocol.gd")
const TrackerType = preload("res://scripts/systems/face_tracker.gd")
const NakamaServiceType = preload("res://scripts/systems/nakama_session_service.gd")

func _init() -> void:
	var valid_packet := ProtocolType.make_input(1, 12, "left_forearm", Vector2(0.2, -0.4), Vector2(1, 0), true, "love")
	_assert_true(ProtocolType.validate_input(valid_packet), "valid intent packet accepted")
	valid_packet["movement"] = Vector2(4, 0)
	_assert_true(not ProtocolType.validate_input(valid_packet), "out-of-range movement rejected")

	var tracker := TrackerType.new()
	var tracked := tracker.update_faces([
		{"rect": Rect2(0.2, 0.1, 0.25, 0.4), "confidence": 0.84},
		{"rect": Rect2(0.1, 0.1, 0.58, 0.65), "confidence": 0.88},
	], 0.016)
	_assert_true(bool(tracked["visible"]), "largest valid face is tracked")
	var grace := tracker.update_faces([], 0.2)
	_assert_true(bool(grace["visible"]), "tracking grace period preserves face")
	var lost := tracker.update_faces([], 0.8)
	_assert_true(not bool(lost["visible"]), "tracking eventually falls back")
	var nakama_service := NakamaServiceType.new()
	nakama_service.configure("nakamas://play.example.com")
	_assert_true(nakama_service.default_scheme == "https", "nakamas selects HTTPS")
	_assert_true(nakama_service.default_port == 443, "TLS endpoint defaults to port 443")
	_assert_true(nakama_service.endpoint == "https://play.example.com:443", "TLS endpoint is normalized")
	nakama_service.configure("nakamas://play.example.com:8443")
	_assert_true(nakama_service.default_port == 8443, "explicit TLS port is preserved")
	nakama_service.free()
	ProjectSettings.set_setting("faceoff/online_server_key", "production-test-key")
	var configured_service := NakamaServiceType.new()
	configured_service._ready()
	_assert_true(configured_service.server_key == "production-test-key", "production client key is loaded from project settings")
	configured_service.free()
	ProjectSettings.set_setting("faceoff/online_server_key", "")
	print("Faceoff core tests: PASS")
	quit(0)

func _assert_true(condition: bool, message: String) -> void:
	if not condition:
		push_error("FAIL: " + message)
		quit(1)
