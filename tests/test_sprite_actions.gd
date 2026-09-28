extends SceneTree

const MainScene = preload("res://scenes/main.tscn")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAILED: " + message)

func _run() -> void:
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("batyr", "kiro")
	await process_frame
	var fighter: RagdollCharacter = main.local_fighter
	check(main.action_button != null and main.action_button.text == "ACTION!", "arena shows an ACTION! button")
	var manifest := SpriteAnimationPlayer.load_manifest(main._sprite_set_for(fighter))
	var states: Array = manifest.get("animations", []).map(func(entry): return entry["state"])
	check(states.has("charge") and states.has("hit-stun") and states.has("jump"), "magician sprite set lists its animations")

	main.action_button.emit_signal("pressed")
	await process_frame
	check(main.action_row.visible, "ACTION! opens the action row")
	check(main.action_buttons.size() == states.size(), "one button per animation")
	var labels: Array = main.action_buttons.map(func(button): return button.text)
	check(labels.has("CHARGE"), "buttons are labelled by animation")
	for label in main.action_hint_labels:
		check(not label.visible, "hints give the bottom bar to the action row")

	# Move a limb, then play: the fighter must be reset, hidden and locked.
	fighter.held_targets["left_forearm"] = fighter.bodies["left_forearm"].position + Vector2(40, -80)
	var charge_button: Button = main.action_buttons[labels.find("CHARGE")]
	charge_button.emit_signal("pressed")
	await process_frame
	check(not main.action_row.visible, "choosing an action closes the row")
	check(main.sprite_player.playing, "sprite animation plays")
	check(not fighter.visible, "rig is hidden while the sprite plays")
	check(not fighter.input_enabled and not fighter.combat_enabled, "player cannot drag limbs during the animation")
	check(fighter.held_targets.is_empty(), "fighter was reset to the rest pose before playing")
	check(main.sprite_player.sprite.texture != null, "first frame is shown")
	check(main.sprite_player.global_position == fighter.global_position, "animation stands where the fighter stands")
	check(main.action_button.disabled, "ACTION! is disabled while playing")

	for step in 200:
		if not main.sprite_player.playing:
			break
		main.sprite_player._process(0.1)
	check(not main.sprite_player.playing, "animation finishes")
	check(fighter.visible and fighter.input_enabled and fighter.combat_enabled, "rig returns and is playable again")
	check(fighter.held_targets.is_empty(), "rig lands in the rest pose")
	check(not main.action_button.disabled, "ACTION! is available again")

	# Rematch in the middle of an animation restores the fighter too.
	main.action_button.emit_signal("pressed")
	main.action_buttons[0].emit_signal("pressed")
	await process_frame
	main._reset()
	check(not main.sprite_player.playing and fighter.visible and fighter.input_enabled, "rematch cancels a running action")

	# Facing left mirrors the animation.
	var opponent: RagdollCharacter = main.opponent
	var player := SpriteAnimationPlayer.new()
	root.add_child(player)
	check(player.play(manifest, "jump", opponent.global_position, 300.0, opponent.facing_direction), "plays for a left-facing fighter")
	check(player.sprite.flip_h, "left-facing fighters get a mirrored animation")
	quit(1 if failures else 0)
