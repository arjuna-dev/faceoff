extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
const ArcadeSkinType = preload("res://scripts/characters/arcade_skin.gd")
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
	main._on_demo_requested()
	await process_frame
	var screen: FighterSelect = main.fighter_select
	check(screen.visible, "demo opens the fighter selection screen")
	check(screen.card_buttons.size() == FighterRosterType.IDS.size(), "selection screen shows the live roster")
	check(screen.player_id == "batyr" and screen.opponent_id == "kiro", "selection screen provides sensible defaults")
	screen.card_buttons["jade"].emit_signal("pressed")
	check(screen.player_id == "jade", "first card selection assigns P1")
	screen.card_buttons["oculon"].emit_signal("pressed")
	check(screen.opponent_id == "oculon", "second card selection assigns P2")
	screen.start_button.emit_signal("pressed")
	await process_frame
	check(main.player.profile.display_name == "Jade", "Jade profile reaches the player fighter")
	check(main.opponent.profile.display_name == "Oculon", "Oculon profile reaches the opponent fighter")
	check(ArcadeSkinType.atlas_for(main.player.profile.visual_style) == ArcadeSkinType.NEW_ATLAS, "Jade uses the replacement atlas")
	check(ArcadeSkinType.atlas_for(main.opponent.profile.visual_style) == ArcadeSkinType.NEW_ATLAS, "Oculon uses the replacement atlas")
	check(main.arena_hud_layer.visible and main.player.input_enabled and main.opponent.input_enabled, "starting selection opens the playable demo")
	main._leave_online()
	main.accepted_match = "selection-test"
	main.assigned_slot = 1
	main.arena_peer_count = 1
	main._open_online_fighter_select()
	await process_frame
	check(screen.visible and screen.online_mode, "online opens the same selection screen")
	check(not screen.p2_button.visible, "online selection only asks for the local fighter")
	screen.card_buttons["oculon"].emit_signal("pressed")
	check(screen.online_fighter_id == "oculon" and not screen.start_button.disabled, "online selection enables READY after one choice")
	screen.start_button.emit_signal("pressed")
	await process_frame
	check(main.online_local_fighter_id == "oculon" and screen.online_waiting, "online selection sends the local choice and waits")
	check(not main.arena_hud_layer.visible, "online selection waits before opening the arena")
	print("Fighter selection: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
