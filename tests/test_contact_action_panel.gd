extends SceneTree

const PanelType = preload("res://scripts/ui/contact_action_panel.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var panel: ContactActionPanel = PanelType.new()
	root.add_child(panel)
	await process_frame
	panel.open_for_contact({"name": "Amina", "user_id": "amina", "presence": "ONLINE"})
	check(panel.visible, "contact action panel opens")
	check(panel.contact_name_label.text == "AMINA", "contact identity is shown")
	check(not panel.start_fight_button.disabled, "Start Fight is enabled for a Faceoff contact")
	check(panel.call_button.disabled and panel.message_button.disabled, "future actions are visibly disabled")
	var starts: Array[String] = []
	panel.start_fight_requested.connect(func(contact: Dictionary): starts.append(String(contact.get("user_id", ""))))
	panel.start_fight_button.emit_signal("pressed")
	check(starts == ["amina"], "Start Fight emits the selected contact")
	panel.open_for_contact({"name": "Phone only"})
	check(panel.start_fight_button.disabled, "Start Fight stays disabled without a Faceoff account")
	print("Contact action panel: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
