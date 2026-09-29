extends SceneTree

## Screenshots of the whole-character magician rig in a real fight (needs a real viewport).

const MainScene = preload("res://scenes/main.tscn")
var main: Node

func _init() -> void:
	call_deferred("_run")

func _capture(name: String) -> void:
	for i in 3:
		await process_frame
	root.get_texture().get_image().save_png("res://tests/" + name + ".png")

func _drag(fighter: RagdollCharacter, limb: String, offset: Vector2) -> void:
	var start: Vector2 = fighter.bodies[limb].global_position
	fighter._start_pointer_drag_at(start, 3)
	for step in 10:
		fighter._update_pointer_drag(3, start + offset * (step + 1) / 10.0, 0.05)
		fighter._physics_process(0.016)
	fighter._end_pointer_drag(3)

func _run() -> void:
	main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("magician", "kiro")
	main.player.set_physics_process(false)
	main.opponent.set_physics_process(false)
	await _capture("magician-fight-rest")
	var p: RagdollCharacter = main.player
	var staff_hand := String(p.skeleton_skin.attachments["held_item"]["parent"])
	p.held_targets[staff_hand] = Vector2(60, -40)
	p.held_targets["left_forearm" if staff_hand == "right_forearm" else "right_forearm"] = Vector2(44, 0)
	p.held_targets["right_thigh"] = Vector2(40, -60)
	p._solve_pose()
	await _capture("magician-fight-posed")
	p.return_to_guard()
	# Rear (far) arm pulled straight forward: it should extend fully.
	p.held_targets[staff_hand] = Vector2(200, -10)
	p._solve_pose()
	await _capture("magician-fight-reach")
	p.return_to_guard()
	# Near arm raised high: the shoulder overlap must hide any gap.
	var near_hand := "left_forearm" if staff_hand == "right_forearm" else "right_forearm"
	p.held_targets[near_hand] = Vector2(10, -90)
	p._solve_pose()
	await _capture("magician-fight-raise")
	main._on_fighter_selection_confirmed("magician", "magician")
	main.player.set_physics_process(false)
	main.opponent.set_physics_process(false)
	await _capture("magician-fight-mirror")
	quit(0)
