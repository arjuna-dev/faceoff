extends SceneTree

## A rig published by tools/export_whole_character_rig.py plays like any fighter.

const MainScene = preload("res://scenes/main.tscn")
const RigSkinType = preload("res://scripts/characters/skeleton_rig_skin.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAILED: " + message)

func _run() -> void:
	check(RigSkinType.has_profile("magician"), "magician whole-character rig passes validation")
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("magician", "magician")
	await process_frame
	for fighter in [main.player, main.opponent]:
		var skin = fighter.skeleton_skin
		check(skin != null, "fighter uses the rig skin")
		if skin == null:
			continue
		check(skin.render_mode == "whole_character", "rig loads in whole_character mode")
		check(skin.bones.size() == 12 and skin.sprites.size() == 12, "twelve parts")
		check(skin.attachment_sprites.has("held_item") and skin.attachment_sprites.has("back_accessory"), "staff and back layer attached")
		for sprite in skin.sprites.values():
			check(sprite.texture != null, "every part has its texture")
	var player: RagdollCharacter = main.player
	var skin = player.skeleton_skin
	# At rest every part sits exactly where it was drawn, and each imported
	# texture matches its part's rectangle (a stale import would not).
	player.set_physics_process(false)
	player.animation_time = 0.0
	player._solve_pose()
	var parts: Dictionary = skin.parts
	var ground := Vector2((parts.left_boot.tip[0] + parts.right_boot.tip[0]) * 0.5, maxf(parts.left_boot.tip[1], parts.right_boot.tip[1]))
	for name in skin.PART_ORDER:
		var rect: Array = parts[name].rect
		var sprite: Sprite2D = skin.sprites[name]
		check(sprite.texture.get_size() == Vector2(rect[2] - rect[0], rect[3] - rect[1]), name + " texture matches its rectangle")
		var drawn: Vector2 = player.global_position + (Vector2((rect[0] + rect[2]) * 0.5, (rect[1] + rect[3]) * 0.5) - ground) * skin.pixel_scale + Vector2(0, skin.AUTHORED_FOOT_Y)
		check(sprite.global_position.distance_to(drawn) < 3.0, name + " rests where it was drawn")
	var staff: Sprite2D = skin.attachment_sprites["held_item"]
	var hand_limb := String(skin.attachments["held_item"]["parent"])
	check(staff.get_parent() == skin.bones[hand_limb], "the staff rides on the hand holding it")
	var hand_before: Vector2 = skin.bones[hand_limb].global_position
	var staff_before: Vector2 = staff.global_position
	# Drag the staff hand up and forward like a player would.
	var start: Vector2 = player.bodies[hand_limb].global_position
	player._start_pointer_drag_at(start, 7)
	for step in 12:
		player._update_pointer_drag(7, start + Vector2(10, -12) * (step + 1), 0.05)
		player._physics_process(0.016)
	await process_frame
	check(staff.global_position.distance_to(staff_before) > 5.0, "dragging the hand moves the staff")
	check(skin.bones[hand_limb].global_position != hand_before or staff.global_rotation != 0.0, "the forearm follows the drag")
	player._end_pointer_drag(7)
	player.return_to_guard()
	# The magician uses his own sprite set for ACTION!.
	check(main._sprite_set_for(player) == "magician", "magician plays his own animations")
	quit(1 if failures else 0)
