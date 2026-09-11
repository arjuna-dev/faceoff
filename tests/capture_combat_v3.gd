extends SceneTree
func _init() -> void:
	call_deferred("run")
func capture(path: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
func run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.set_physics_process(false)
	main.player.set_physics_process(false)
	main.opponent.set_physics_process(false)
	main.player.position.x = 520
	main.player.stance_height = 20
	main.player._solve_pose()
	var foot: Vector2 = main.player.bodies.right_shin.global_position
	main.player._start_pointer_drag_at(foot, 1)
	main.player._update_pointer_drag(1, main.opponent.bodies.head.global_position, 0.16)
	main.player._end_pointer_drag(1)
	await capture("res://tests/high-kick-preview.png")
	main._reset()
	main.player._start_jump(Vector2(300,-650))
	for i in 18:
		main.player._physics_process(1.0/60.0)
	await capture("res://tests/jump-preview.png")
	quit()
