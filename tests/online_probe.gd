extends SceneTree

const OnlineMatchType = preload("res://scripts/systems/online_match.gd")

var online: FaceoffOnlineMatch
var elapsed := 0.0
var sent_hit := false
var saw_state := false
var saw_hit := false
var requested_url := "ws://127.0.0.1:9100"
var probe_label := "probe"
var duration := 8.0

func _init() -> void:
	for argument in OS.get_cmdline_user_args():
		if String(argument).begins_with("--url="):
			requested_url = String(argument).trim_prefix("--url=")
		elif String(argument).begins_with("--label="):
			probe_label = String(argument).trim_prefix("--label=")
		elif String(argument).begins_with("--duration="):
			duration = maxf(1.0, float(String(argument).trim_prefix("--duration=")))
	call_deferred("_run")

func _run() -> void:
	online = OnlineMatchType.new()
	online.name = "OnlineMatch"
	var network_root := Node.new()
	network_root.name = "Faceoff"
	root.add_child(network_root)
	network_root.add_child(online)
	online.status_changed.connect(func(message: String): print("%s status=%s" % [probe_label, message]))
	online.slot_assigned.connect(func(slot: int): print("%s slot=%d" % [probe_label, slot]))
	online.remote_state_received.connect(_on_remote_state)
	online.remote_hit_received.connect(_on_remote_hit)
	online.connect_to_server(requested_url)
	while elapsed < duration:
		elapsed += 0.05
		if online and online.player_slot > 0:
			var slot := online.player_slot
			online.submit_state({
				"position": Vector2(280.0 + slot * 40.0, 420.0),
				"movement": Vector2.RIGHT if slot == 1 else Vector2.LEFT,
				"health": 100.0,
				"held_targets": {},
			})
			if slot == 1 and not sent_hit and saw_state:
				sent_hit = true
				online.submit_hit(2, 1.0, 100.0, "right_forearm", Vector2.ZERO)
		await create_timer(0.05).timeout
	print("%s result state=%s hit=%s" % [probe_label, saw_state, saw_hit])
	quit(0 if saw_state or probe_label == "one" else 1)

func _on_remote_state(_slot: int, _state: Dictionary) -> void:
	saw_state = true

func _on_remote_hit(_attacker_slot: int, _damage: float, _speed: float, _region: String, _point: Vector2, _blocked: bool, _impact_damage: float) -> void:
	saw_hit = true
