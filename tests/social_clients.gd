extends SceneTree
var a: NakamaSessionService
var b: NakamaSessionService
var invitation := {}
var ready_a := 0
var ready_b := 0
var got_state := false
var got_voice := false
func _init() -> void:
	call_deferred("run")
func run() -> void:
	a = NakamaSessionService.new()
	b = NakamaSessionService.new()
	root.add_child(a)
	root.add_child(b)
	for service in [a, b]:
		service.social_only = true
		service.server_key = "devserverkey"
	b.notification_received.connect(func(data):
		if data.get("type") == "call": invitation = data.call)
	a.arena_presence.connect(func(count): ready_a = count)
	b.arena_presence.connect(func(count): ready_b = count)
	b.remote_state_received.connect(func(_slot, _state): got_state = true)
	b.voice_received.connect(func(bytes): got_voice = bytes.size() == 1600)
	a.connect_to_server("nakama://127.0.0.1:7352", OS.get_environment("FACE_OFF_TEST_A"))
	b.connect_to_server("nakama://127.0.0.1:7352", OS.get_environment("FACE_OFF_TEST_B"))
	for i in 100:
		if a.connected and b.connected: break
		await create_timer(0.1).timeout
	if not a.connected or not b.connected: return fail("bootstrap sockets")
	var profile := await a.social_rpc("faceoff_profile")
	if not profile.get("profile") is Dictionary: return fail("verified profile")
	var result := await a.social_rpc("faceoff_call_invite", {"target": b.user_id})
	if result.has("error"): return fail("invite: " + String(result.error))
	await create_timer(0.25).timeout
	if invitation.get("id") != result.id: return fail("incoming notification")
	var accepted := await b.social_rpc("faceoff_call_action", {"id": result.id, "action": "accept"})
	if not accepted.has("match_id"): return fail("accept")
	if not await a.join_invited_match(accepted.match_id): return fail("caller joins")
	if not await b.join_invited_match(accepted.match_id): return fail("recipient joins")
	await create_timer(0.3).timeout
	if ready_a != 2 or ready_b != 2 or a.player_slot == 0 or b.player_slot == 0 or a.player_slot == b.player_slot: return fail("ready and distinct ownership")
	a.submit_state({"position": Vector2(355,459), "movement": Vector2.ZERO, "held_targets": {}, "health":100, "fighter":"test"})
	var bytes := PackedByteArray()
	bytes.resize(1600)
	a.send_voice(bytes)
	await create_timer(0.3).timeout
	if not got_state or not got_voice: return fail("pose and voice delivery")
	await a.social_rpc("faceoff_call_action", {"id": result.id, "action":"end"})
	a.shutdown()
	b.shutdown()
	print("Godot social clients: PASS (notification, accepted match, ownership, pose, voice)")
	quit()
func fail(reason: String) -> void:
	push_error(reason)
	if a: a.shutdown()
	if b: b.shutdown()
	quit(1)
