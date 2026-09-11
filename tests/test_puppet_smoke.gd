extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
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
	# Stable idle with no dynamic physics nodes.
	var start := p.position
	for i in 180:
		p._physics_process(1.0 / 60.0)
	check(p.position == start, "idle is planted")
	for node in p.get_children():
		check(not node is PhysicsBody2D, "fighter has no physics bodies")
	check(o.health == 100, "idle cannot attack")
	# Hand pose survives walking and leaves feet animated.
	var hand: Vector2 = p.bodies.right_forearm.global_position
	p._start_pointer_drag_at(hand, 4)
	check(p.dragging_limb == "right_forearm", "hand can be picked")
	p._update_pointer_drag(4, hand + Vector2(32, -30))
	p._end_pointer_drag(4)
	var held: Vector2 = p.held_targets.right_forearm
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
	p.held_targets.right_forearm = Vector2(87, 0)
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
