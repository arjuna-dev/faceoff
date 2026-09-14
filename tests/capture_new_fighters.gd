extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
var main: Node

func _init() -> void:
	call_deferred("_run")

func _capture(name: String) -> void:
	main.player.queue_redraw()
	main.opponent.queue_redraw()
	await process_frame
	await process_frame
	var viewport_texture := root.get_texture()
	if viewport_texture == null:
		push_error("A real OpenGL viewport is required for fighter art captures; headless dummy rendering cannot validate pixels.")
		quit(2)
		return
	viewport_texture.get_image().save_png("res://tests/" + name + ".png")

func _drag(fighter: RagdollCharacter, limb: String, target: Vector2, id: int) -> void:
	var start: Vector2 = fighter.bodies[limb].global_position
	fighter._start_pointer_drag_at(start, id)
	fighter._update_pointer_drag(id, target, 0.12)
	fighter._end_pointer_drag(id)

func _reset_pose() -> void:
	main.player.reset_character()
	main.opponent.reset_character()
	main.player.set_physics_process(false)
	main.opponent.set_physics_process(false)
	await process_frame

func _run() -> void:
	main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("jade", "oculon")
	await process_frame
	main.set_physics_process(false)
	main.player.set_physics_process(false)
	main.opponent.set_physics_process(false)
	await _capture("jade-oculon-neutral")

	var jade: RagdollCharacter = main.player
	var oculon: RagdollCharacter = main.opponent
	_drag(jade, "right_forearm", jade.bodies.right_forearm.global_position + Vector2(140, -8), 1)
	await _capture("jade-punch")
	await _reset_pose()

	_drag(jade, "left_forearm", jade.bodies.left_forearm.global_position + Vector2(115, 20), 5)
	await _capture("jade-left-punch")
	await _reset_pose()

	_drag(jade, "right_forearm", jade.bodies.right_forearm.global_position + Vector2(120, -6), 6)
	jade.was_walking = true
	jade.walk_phase = 1.2
	jade._solve_pose()
	await _capture("jade-walk-held-arm")
	await _reset_pose()

	_drag(jade, "right_shin", jade.bodies.right_shin.global_position + Vector2(94, -42), 7)
	await _capture("jade-low-kick")
	await _reset_pose()

	_drag(oculon, "right_shin", jade.bodies.head.global_position, 2)
	await _capture("oculon-face-kick")
	await _reset_pose()

	_drag(jade, "torso", jade.get_world_center() + Vector2(42, 38), 3)
	await _capture("jade-crouch-walk")
	await _reset_pose()

	_drag(jade, "head", jade.bodies.head.global_position + Vector2(55, 18), 8)
	await _capture("jade-bow")
	await _reset_pose()

	_drag(jade, "head", jade.bodies.head.global_position + Vector2(-48, 14), 9)
	await _capture("jade-arch")
	await _reset_pose()

	oculon._start_jump(Vector2(-170, -700))
	oculon.jump_height = 76.0
	oculon.jump_velocity = Vector2.ZERO
	oculon._solve_pose()
	await _capture("oculon-jump")
	await _reset_pose()

	_drag(jade, "left_shin", jade.bodies.left_shin.global_position + Vector2(62, -98), 10)
	jade.hopping = true
	jade.hop_side = "left"
	jade.hop_clock = 0.21
	jade._solve_pose()
	await _capture("jade-one-foot-hop")
	await _reset_pose()

	oculon._start_fall()
	oculon.fall_progress = 1.0
	oculon._solve_pose()
	await _capture("oculon-fall")
	await _reset_pose()

	oculon._start_fall()
	oculon.fall_progress = 0.45
	oculon._solve_pose()
	await _capture("oculon-get-up")
	await _reset_pose()

	_drag(oculon, "left_forearm", oculon.bodies.left_forearm.global_position + Vector2(-105, -10), 4)
	await _capture("oculon-punch")
	if "--stay" in OS.get_cmdline_user_args():
		await create_timer(30.0).timeout
	quit()
