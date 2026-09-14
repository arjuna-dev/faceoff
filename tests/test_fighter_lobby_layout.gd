extends SceneTree

const FighterLobbyType = preload("res://scripts/ui/fighter_lobby.gd")

var failures := 0
var lobby: FighterLobby
var contact := {
	"id": "phone:layout-test",
	"name": "Layout Test",
	"tag": "PHONE CONTACT",
	"presence": "AVAILABLE",
}

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	lobby = FighterLobbyType.new()
	lobby.portrait_mode = true
	root.add_child(lobby)
	await process_frame
	await _exercise_orientation(true)
	await _exercise_orientation(false)
	lobby.queue_free()
	print("Fighter lobby layout: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)

func _exercise_orientation(portrait: bool) -> void:
	lobby.set_layout_mode(portrait)
	await process_frame
	var mode_name := "portrait" if portrait else "landscape"
	var expected_size := Vector2(540, 960) if portrait else Vector2(960, 540)
	var expected_action_width := 230.0 if portrait else 170.0
	var expected_accept_position := Vector2(28, 664) if portrait else Vector2(510, 190)
	var expected_decline_position := Vector2(282, 664) if portrait else Vector2(694, 190)

	check(lobby.size == expected_size, "%s lobby uses its expected viewport size" % mode_name)
	lobby.open_for_call(contact, false)
	await process_frame
	check(lobby.visible, "%s outgoing lobby opens" % mode_name)
	check(lobby.cancel_button.visible and not lobby.accept_button.visible and not lobby.decline_button.visible, "%s outgoing call exposes cancel only" % mode_name)

	lobby.open_for_call(contact, true)
	await process_frame
	check(lobby.accept_button.visible and lobby.decline_button.visible and not lobby.cancel_button.visible, "%s incoming call exposes accept and decline only" % mode_name)
	check(lobby.accept_button.position == expected_accept_position, "%s accept button uses the action column" % mode_name)
	check(lobby.decline_button.position == expected_decline_position, "%s decline button uses the second action column" % mode_name)
	check(lobby.accept_button.size.x == expected_action_width and lobby.decline_button.size.x == expected_action_width and lobby.accept_button.size.y == lobby.decline_button.size.y, "%s action buttons share the intended width and row height" % mode_name)
	check(not lobby.accept_button.get_global_rect().intersects(lobby.decline_button.get_global_rect()), "%s accept and decline buttons do not overlap" % mode_name)
