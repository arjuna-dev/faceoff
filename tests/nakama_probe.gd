extends SceneTree

## Headless integration probe for the real Nakama transport.
## Run with a local Nakama on NAKAMA_PORT (default 7350) and two clients.

const Service = preload("res://scripts/systems/nakama_session_service.gd")

var first: NakamaSessionService
var second: NakamaSessionService
var first_state := false
var second_state := false
var first_hit := false
var second_hit := false
var first_hit_damage := -1.0
var second_hit_damage := -1.0
var first_guard_displaced := false
var second_guard_displaced := false
var first_last_state: Dictionary = {}
var second_last_state: Dictionary = {}
var elapsed := 0.0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	first = Service.new()
	second = Service.new()
	root.add_child(first)
	root.add_child(second)
	first.remote_state_received.connect(_on_first_state)
	second.remote_state_received.connect(_on_second_state)
	first.remote_hit_received.connect(_on_first_hit)
	second.remote_hit_received.connect(_on_second_hit)
	first.network_error.connect(_on_network_error.bind("one"))
	second.network_error.connect(_on_network_error.bind("two"))
	var port := int(OS.get_environment("NAKAMA_PORT"))
	if port <= 0:
		port = 7350
	var endpoint := "nakama://127.0.0.1:%d" % port
	first.connect_to_server(endpoint, "faceoff-probe-one-%d" % Time.get_ticks_msec())
	second.connect_to_server(endpoint, "faceoff-probe-two-%d" % Time.get_ticks_msec())
	while elapsed < 20.0 and (first.player_slot == 0 or second.player_slot == 0):
		await create_timer(0.1).timeout
		elapsed += 0.1
	if first.player_slot == 0 or second.player_slot == 0:
		_fail("slots were not assigned: %d/%d" % [first.player_slot, second.player_slot])
		return
	first.submit_state(_state(Vector2(360, 459)))
	second.submit_state(_state(Vector2(600, 459)))
	await create_timer(0.8).timeout
	var attacker := first if first.player_slot == 1 else second
	var defender := second if attacker == first else first
	attacker.submit_hit(defender.player_slot, 18.0, 1000.0, "head", Vector2(600, 350), false, 18.0, "right_forearm")
	await create_timer(0.8).timeout
	if not first_state or not second_state:
		_fail("remote state was not delivered: %s/%s" % [first_state, second_state])
		return
	if first.player_slot == 1:
		if not second_hit:
			_fail("hit was not delivered to slot two")
			return
	else:
		if not first_hit:
			_fail("hit was not delivered to slot one")
			return
	var unblocked_damage := second_hit_damage if attacker == first else first_hit_damage
	if unblocked_damage < 17.0:
		_fail("unblocked damage was not preserved: %.2f" % unblocked_damage)
		return
	defender.submit_state(_state(Vector2(600, 459), {"right_forearm": Vector2(55, -30)}))
	await create_timer(0.35).timeout
	attacker.submit_hit(defender.player_slot, 30.0, 1200.0, "right_forearm", Vector2(600, 390), false, 30.0)
	await create_timer(0.8).timeout
	var guard_damage := second_hit_damage if defender == second else first_hit_damage
	if guard_damage < 0.0 or guard_damage > 1.1:
		_fail("guard chip was not authoritative: %.2f" % guard_damage)
		return
	var displaced := first_guard_displaced if attacker == first else second_guard_displaced
	if not displaced:
		_fail("server did not replicate the displaced guard: first=%s second=%s" % [first_last_state, second_last_state])
		return
	print("NAKAMA PROBE PASS slots=%d/%d state=%s/%s hit=%s/%s guard_chip=%.1f guard_displaced=%s" % [first.player_slot, second.player_slot, first_state, second_state, first_hit, second_hit, guard_damage, displaced])
	_shutdown_and_quit(0)

func _state(position: Vector2, held: Dictionary = {}) -> Dictionary:
	return {
		"position": position,
		"movement": Vector2.ZERO,
		"held_targets": held,
		"health": 100.0,
		"fighter": "probe",
	}

func _on_first_state(_slot: int, state_data: Dictionary) -> void:
	first_state = true
	first_last_state = state_data
	first_guard_displaced = first_guard_displaced or _has_guard_disabled(state_data)

func _on_second_state(_slot: int, state_data: Dictionary) -> void:
	second_state = true
	second_last_state = state_data
	second_guard_displaced = second_guard_displaced or _has_guard_disabled(state_data)

func _has_guard_disabled(state_data: Dictionary) -> bool:
	var disabled: Variant = state_data.get("guard_disabled", {})
	if disabled is Array:
		return not disabled.is_empty()
	if disabled is Dictionary:
		return not disabled.is_empty()
	return false

func _on_first_hit(_slot: int, damage: float, _speed: float, _region: String, _point: Vector2, _blocked: bool, _impact_damage: float) -> void:
	first_hit = true
	first_hit_damage = damage

func _on_second_hit(_slot: int, damage: float, _speed: float, _region: String, _point: Vector2, _blocked: bool, _impact_damage: float) -> void:
	second_hit = true
	second_hit_damage = damage

func _on_network_error(message: String, label: String) -> void:
	print("NAKAMA %s ERROR %s" % [label, message])

func _fail(message: String) -> void:
	printerr("NAKAMA PROBE FAIL: " + message)
	_shutdown_and_quit(1)

func _shutdown_and_quit(code: int) -> void:
	if first:
		first.shutdown()
	if second:
		second.shutdown()
	quit(code)
