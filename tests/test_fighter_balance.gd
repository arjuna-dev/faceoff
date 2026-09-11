extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func advance(fighter: RagdollCharacter, frames: int) -> void:
	for i in frames:
		fighter._physics_process(1.0 / 60.0)

func lift(fighter: RagdollCharacter, side: String, pointer: int) -> void:
	var point: Vector2 = fighter.bodies[side + "_shin"].global_position
	fighter._start_pointer_drag_at(point, pointer)
	check(fighter.active_drags.has(pointer), "foot selected for lift")
	fighter._update_pointer_drag(pointer, point + Vector2(0, -110))
	fighter._end_pointer_drag(pointer)

func _run() -> void:
	var main := MainScene.instantiate()
	root.add_child(main)
	await process_frame
	for fighter in [main.player, main.opponent]:
		main._reset()
		# Both mirrored rigs bend toward the front in idle, crouch and walking.
		for crouch in [0.0, 55.0]:
			fighter.crouch = crouch
			for frame in 24:
				fighter.was_walking = frame > 0
				fighter.walk_phase = frame * TAU / 24.0
				fighter._solve_pose()
				for side in ["left", "right"]:
					var hip: Vector2 = fighter.joints[side + "_hip"]
					var foot: Vector2 = fighter.joints[side + "_foot"]
					var knee: Vector2 = fighter.joints[side + "_knee"]
					check((foot - hip).cross(knee - hip) <= 0.0, "knee bends forward in facing-local coordinates")
		main._reset()
		lift(fighter, "left", 10)
		advance(fighter, 90)
		check(not fighter.is_fallen, "one lifted foot retains support")
		lift(fighter, "right", 11)
		advance(fighter, 20)
		check(fighter.is_fallen and fighter.fall_progress > 0.0, "two lifted feet trigger animated fall")
		check(fighter.active_drags.is_empty(), "fall releases all pointers")
		fighter.return_to_guard()
		check(fighter.is_fallen, "guard cannot cancel fall")
		var position_before: Vector2 = fighter.position
		fighter.set_movement_intent(Vector2.RIGHT)
		advance(fighter, 15)
		check(fighter.position == position_before, "fall prevents walking")
		fighter._start_pointer_drag_at(fighter.bodies.right_forearm.global_position, 12)
		check(fighter.active_drags.is_empty(), "cannot attack or pose during fall")
		check(fighter.bodies.head.position.y > -65, "fallen hit targets follow rendered body to ground")
		check(fighter.health == 100, "fall alone does not deal damage")
		advance(fighter, 110)
		check(not fighter.is_fallen and fighter.fall_progress == 0.0, "automatic get-up finishes")
		check(fighter.held_targets.is_empty(), "get-up restores stable guard")
		main._reset()
		fighter.set_movement_intent(Vector2.RIGHT)
		advance(fighter, 240)
		check(not fighter.is_fallen, "normal walking never triggers unsupported fall")
		main._reset()
		# Foot dragging supersedes an older manual knee pose.
		fighter.held_targets.right_thigh = Vector2(30, -30)
		fighter._solve_pose()
		var foot: Vector2 = fighter.bodies.right_shin.global_position
		fighter._start_pointer_drag_at(foot, 13)
		fighter._update_pointer_drag(13, foot + Vector2(0, 40))
		check(not fighter.held_targets.has("right_thigh"), "foot drag replaces old knee override")
		fighter._end_pointer_drag(13)
		main._reset()
		# Raising both knees also removes foot support and a rematch cancels the fall.
		for side in ["left", "right"]:
			var knee: Vector2 = fighter.bodies[side + "_thigh"].global_position
			fighter._start_pointer_drag_at(knee, 15)
			fighter._update_pointer_drag(15, knee + Vector2(0, -100))
			fighter._end_pointer_drag(15)
		advance(fighter, 20)
		check(fighter.is_fallen, "two knee lifts remove foot support")
		main._reset()
		check(not fighter.is_fallen and fighter.fall_progress == 0.0, "rematch clears fall state")
	main._reset()
	if "--capture" in OS.get_cmdline_user_args():
		lift(main.player, "left", 21)
		lift(main.player, "right", 22)
		advance(main.player, 42)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://tests/fighter-fall-preview.png")
	print("Fighter balance: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
