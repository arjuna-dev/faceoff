extends SceneTree
var main
var peer: NakamaSessionService
func _init():
	call_deferred("run")
func run():
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	peer = NakamaSessionService.new()
	root.add_child(peer)
	peer.social_only = true
	peer.server_key = "devserverkey"
	main.nakama_online.service.server_key = "devserverkey"
	main.nakama_online.connect_to_server("nakama://127.0.0.1:7352", OS.get_environment("FACE_OFF_TEST_A"))
	peer.connect_to_server("nakama://127.0.0.1:7352", OS.get_environment("FACE_OFF_TEST_B"))
	for i in 100:
		if main.social.verified and peer.connected: break
		await create_timer(0.1).timeout
	if not main.social.verified: return fail("main profile setup")
	await main._on_contact_call_requested({"user_id":peer.user_id,"name":"Test friend"})
	if not main.fighter_lobby.visible or main.arena_hud_layer.visible: return fail("outgoing remains in lobby")
	main.fighter_lobby._on_accept_pressed()
	if main.arena_hud_layer.visible: return fail("self acceptance")
	var call = main.social.current_call
	var accepted = await peer.social_rpc("faceoff_call_action", {"id":call.id,"action":"accept"})
	await create_timer(0.3).timeout
	if main.arena_hud_layer.visible: return fail("requires both participants")
	await peer.join_invited_match(accepted.match_id)
	await create_timer(0.4).timeout
	if not main.fighter_select.visible: return fail("accepted pair opens online fighter selection")
	main.fighter_select.card_buttons["jade"].emit_signal("pressed")
	main.fighter_select.start_button.emit_signal("pressed")
	peer.submit_fighter_selection("oculon")
	await create_timer(0.4).timeout
	if not main.online_active or not main.arena_hud_layer.visible: return fail("accepted pair enters arena")
	if main.player.profile.display_name != "Jade" and main.opponent.profile.display_name != "Jade": return fail("local online fighter is applied")
	if main.player.profile.display_name != "Oculon" and main.opponent.profile.display_name != "Oculon": return fail("remote online fighter is applied")
	if main.player.input_enabled == main.opponent.input_enabled: return fail("exactly one fighter controllable")
	if main.navigation_portrait: return fail("landscape fight")
	main._reset()
	if main.player.input_enabled == main.opponent.input_enabled: return fail("reset cannot unlock remote fighter")
	main._show_contacts_home()
	await create_timer(0.3).timeout
	if main.arena_hud_layer.visible or not main.navigation_portrait: return fail("leaving returns portrait")
	if main.player.input_enabled or main.opponent.input_enabled: return fail("menu input locked")
	main._on_demo_requested()
	await create_timer(0.1).timeout
	if not main.fighter_select.visible: return fail("demo reopens fighter selection")
	main.fighter_select.start_button.emit_signal("pressed")
	await process_frame
	if not main.player.input_enabled or not main.opponent.input_enabled: return fail("explicit demo controls both")
	main.social.set_process(false)
	await create_timer(0.5).timeout
	main.nakama_online.shutdown()
	peer.shutdown()
	main.queue_free()
	peer.queue_free()
	await process_frame
	await process_frame
	print("Main social flow: PASS (lobby, acceptance, ownership, reset, leave, portrait, demo)")
	quit()
func fail(message):
	push_error(message)
	peer.shutdown()
	main.nakama_online.shutdown()
	quit(1)
