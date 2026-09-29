extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
const FighterRosterType = preload("res://scripts/characters/fighter_roster.gd")
var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var main := MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var p: RagdollCharacter = main.player
	var o: RagdollCharacter = main.opponent
	var face_frame := Image.create(24, 24, false, Image.FORMAT_RGBA8)
	face_frame.fill(Color("d58f6f"))
	var face_texture := ImageTexture.create_from_image(face_frame)
	p.set_video_face_texture(face_texture)
	check(p.video_face_active and p.video_face_texture == face_texture, "processed face texture attaches to the fighter head")
	p.clear_video_face_texture()
	check(not p.video_face_active and p.video_face_texture == null, "clearing face texture restores authored head")
	var contacts: ContactsHome = main.contacts_home
	check(main.solo_home_layer.visible and p.visible and not o.visible, "app opens in the solo fighter scene")
	check(p.input_enabled and not p.combat_enabled, "solo fighter is controllable without attacking a hidden opponent")
	main._back_navigation()
	check(main.exit_confirmation.visible, "back on the first screen asks before exiting")
	main.exit_confirmation.hide()
	main._on_demo_requested()
	check(main.fighter_select.visible, "demo opens fighter selection")
	main._back_navigation()
	check(main.solo_home_layer.visible, "back from fighter selection returns to the screen that opened it")
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("batyr", "kiro")
	main._back_navigation()
	check(main.solo_home_layer.visible, "back from a demo arena returns to the screen that opened it")
	main._on_call_friend_requested()
	await process_frame
	check(contacts.visible and contacts.page == "contacts", "Call a friend opens Faceoff friends")
	main._back_navigation()
	check(main.solo_home_layer.visible and not main.exit_confirmation.visible, "back from contacts returns to the previous screen without exiting")
	main._on_call_friend_requested()
	await process_frame
	main._show_contact_actions({"name": "Test contact", "user_id": "test-user", "presence": "ONLINE"}, "contacts")
	check(main.contact_action_panel.visible and main.player.visible and not main.opponent.visible, "selecting a contact opens arena actions beside the fighter")
	check(not main.contact_action_panel.start_fight_button.disabled, "registered contacts expose Start Fight")
	check(main.contact_action_panel.call_button.disabled and main.contact_action_panel.message_button.disabled, "Call and Message remain unavailable")
	main._on_contact_action_back_requested()
	await process_frame
	var lobby: FighterLobby = main.fighter_lobby
	lobby.open_for_call({"id": "test", "name": "Test contact"}, false)
	check(not lobby.accept_button.visible and lobby.cancel_button.visible, "outgoing calls cannot self-accept")
	check(lobby.mic_enabled and not lobby.camera_available, "microphone defaults on and face camera is unavailable")
	lobby._on_camera_pressed()
	check(not lobby.camera_enabled, "unavailable camera cannot turn on")
	lobby.hide()
	lobby.set_layout_mode(false)
	lobby.open_for_quick_fight()
	check(lobby.quick_mode and lobby.cancel_button.visible and lobby.cancel_button.text == "CANCEL SEARCH", "Quick Fight exposes a cancellable matchmaker lobby")
	lobby.hide()
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("batyr", "kiro")
	check(p.input_enabled and o.input_enabled, "explicit demo controls both fighters")
	# Stable idle with no dynamic physics nodes.
	var start := p.position
	for i in 180:
		p._physics_process(1.0 / 60.0)
	check(p.position == start, "idle is planted")
	for node in p.get_children():
		check(not node is PhysicsBody2D, "fighter has no physics bodies")
	check(o.health == 100, "idle cannot attack")
	# Both arms share a torso-centered forward limit. Source-marker rigs may
	# have distinct anatomical shoulders, but depth ordering cannot change reach.
	for fighter_id in FighterRosterType.IDS:
		p.set_profile(FighterRosterType.profile(fighter_id))
		for side in ["left", "right"]:
			p.held_targets[side + "_forearm"] = Vector2(p.ARM_REACH, 0)
		p._solve_pose()
		if p.skeleton_skin and p.skeleton_skin.render_mode == "whole_character":
			# Drawn characters keep their drawn shoulders; each arm must extend
			# fully from its own shoulder instead of folding at the elbow.
			for side in ["left", "right"]:
				var length: float = p.skeleton_skin.segment_length(side + "_upper_arm", 0.0) + p.skeleton_skin.segment_length(side + "_forearm", 0.0)
				var extension: float = Vector2(p.joints[side + "_hand"]).distance_to(p.joints[side + "_shoulder"])
				check(extension >= length - 0.5, "%s %s arm extends fully" % [p.profile.display_name, side])
			continue
		var left_forward_reach: float = p.joints.left_hand.x - p.joints.shoulder.x
		var right_forward_reach: float = p.joints.right_hand.x - p.joints.shoulder.x
		check(is_equal_approx(left_forward_reach, right_forward_reach), "%s rear and front arms have equal forward reach" % p.profile.display_name)
		var expected_reach: float = p.skeleton_skin.arm_control_reach(p.ARM_REACH) if p.skeleton_skin and p.skeleton_skin.uses_authored_shoulders() else p.ARM_REACH
		check(left_forward_reach >= expected_reach-0.01, "%s rear arm reaches its full combat radius" % p.profile.display_name)
		p.held_targets.clear()
	p.set_profile(FighterRosterType.profile("batyr"))
	p._solve_pose()
	# Hand pose survives walking and leaves feet animated.
	var hand: Vector2 = p.bodies.right_forearm.global_position
	check(p.bodies.left_forearm.global_position.distance_to(p.get_world_center()) > 35.0, "rear hand starts clear of the torso")
	p._start_pointer_drag_at(hand, 4)
	check(p.dragging_limb == "right_forearm", "hand can be picked")
	p._update_pointer_drag(4, hand + Vector2(160, 0))
	check(p.joints.right_shoulder.distance_to(p.joints.right_hand) > 96.0, "arm can extend almost fully")
	check(is_equal_approx(p.joints.right_shoulder.distance_to(p.joints.right_elbow), p.ARM_UPPER_LENGTH), "upper arm stays connected at the elbow")
	check(is_equal_approx(p.joints.right_elbow.distance_to(p.joints.right_hand), p.ARM_FOREARM_LENGTH), "forearm stays connected at the elbow")
	p._end_pointer_drag(4)
	var held: Vector2 = p.held_targets.right_forearm
	var rear_hand: Vector2 = p.bodies.left_forearm.global_position
	p._start_pointer_drag_at(rear_hand, 14)
	check(p.dragging_limb == "left_forearm", "rear hand can be picked independently")
	p._update_pointer_drag(14, rear_hand + Vector2(160, 0))
	check(p.joints.left_shoulder.distance_to(p.joints.left_hand) > 96.0, "rear arm can extend almost fully")
	p._end_pointer_drag(14)
	p.held_targets.erase("left_forearm")
	p._solve_pose()
	var torso := p.get_world_center()
	p._start_pointer_drag_at(torso, 5)
	p._update_pointer_drag(5, torso + Vector2(90, 45))
	for i in 30:
		p._physics_process(1.0 / 60.0)
	check(p.position.x > start.x + 20, "torso drag walks")
	check(p.crouch > 35, "torso down crouches")
	check(p.held_targets.right_forearm == held, "walking preserves arm extension")
	check(p.was_walking, "walking animation active")
	p._end_pointer_drag(5)
	# Forward and backward head posing.
	var head: Vector2 = p.bodies.head.global_position
	p._start_pointer_drag_at(head, 6)
	p._update_pointer_drag(6, head + Vector2(45, 20))
	check(p.lean > 30, "head forward bows")
	p._update_pointer_drag(6, head + Vector2(-45, 20))
	check(p.lean < -30, "head backward arches")
	p._end_pointer_drag(6)
	main._reset()
	# Two simultaneous independent touches.
	p._start_pointer_drag_at(p.bodies.left_forearm.global_position, 10)
	p._start_pointer_drag_at(p.bodies.right_shin.global_position, 11)
	check(p.active_drags.size() == 2, "two touch controls accepted")
	p._end_pointer_drag(10)
	p._end_pointer_drag(11)
	# A fast sweep cannot tunnel through the opponent; one stroke, one hit.
	p.position.x = 500
	p._solve_pose()
	hand = p.bodies.right_forearm.global_position
	p._start_pointer_drag_at(hand, 1)
	p._update_pointer_drag(1, Vector2(640, o.get_world_center().y))
	check(o.health < 100, "manual punch damages on swept contact")
	var damaged := o.health
	p._update_pointer_drag(1, Vector2(650, o.get_world_center().y))
	for i in 60:
		p._physics_process(1.0 / 60.0)
	check(o.health == damaged, "held limb and same stroke do not repeat damage")
	p._end_pointer_drag(1)
	main._reset()
	# Out of range drags miss even with an extreme cursor position.
	hand = p.bodies.right_forearm.global_position
	p._start_pointer_drag_at(hand, 2)
	p._update_pointer_drag(2, Vector2(900, 300))
	p._end_pointer_drag(2)
	check(o.health == 100, "arm reach is bounded and distant strokes miss")
	main._reset()
	# A lifted foot reaches the torso and deals kick damage.
	p.position.x = 505
	p._solve_pose()
	var foot: Vector2 = p.bodies.right_shin.global_position
	p._start_pointer_drag_at(foot, 3)
	p._update_pointer_drag(3, o.get_world_center())
	check(o.health < 100, "manual foot kick deals speed-based damage")
	p._end_pointer_drag(3)
	main._reset()
	# Knee strikes use their own reachable endpoint.
	p.position.x = 529
	p._solve_pose()
	var knee: Vector2 = p.bodies.right_thigh.global_position
	p._start_pointer_drag_at(knee, 7)
	p._update_pointer_drag(7, o.get_world_center())
	check(o.health < 100, "manual knee strike deals speed-based damage")
	p._end_pointer_drag(7)
	main._reset()
	# Walking an extended hand into the opponent is not a strike.
	p.held_targets.right_forearm = Vector2(p.ARM_REACH, 0)
	p.set_movement_intent(Vector2.RIGHT)
	for i in 120:
		p._physics_process(1.0 / 60.0)
	check(o.health == 100, "locomotion cannot deal damage")
	check(absf(p.position.x - o.position.x) >= 76, "fighters cannot walk through each other")
	# KO locks both players, reset restores all state.
	o.receive_hit(100, Vector2.ZERO)
	check(o.is_ko and main.round_over, "zero HP ends round")
	check(not p.input_enabled and not p.combat_enabled, "round end locks attacks")
	main._reset()
	check(o.health == 100 and not o.is_ko and p.input_enabled, "rematch restores health and controls")
	check(p.position == p.spawn_position and p.held_targets.is_empty(), "rematch restores pose and position")
	if "--capture" in OS.get_cmdline_user_args():
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/fighter-preview.png")
	print("Fighter smoke: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
