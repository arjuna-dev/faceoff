extends SceneTree

const MainScene = preload("res://scenes/main.tscn")

var main: Node

func _init() -> void:
	call_deferred("_run")

func _capture(name: String) -> void:
	await process_frame
	await process_frame
	var texture := root.get_texture()
	if texture == null:
		push_error("A real renderer is required for navigation captures")
		quit(2)
		return
	texture.get_image().save_png("res://tests/" + name + ".png")

func _run() -> void:
	main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main.contacts_home.set_account({"name": "Alejandro", "phone": "+49 170 1234567", "handle": "@alejandro"})
	var contacts: Array[Dictionary] = [
		{"id": "phone:1", "name": "Amina", "phone": "+49111", "user_id": "amina", "presence": "ONLINE"},
		{"id": "phone:2", "name": "Bea", "phone": "+49222", "user_id": "bea", "presence": "ONLINE"},
		{"id": "phone:3", "name": "Carlos", "phone": "+49333"},
		{"id": "phone:4", "name": "Daniel", "phone": "+49444"},
		{"id": "phone:5", "name": "Elena", "phone": "+49555"},
		{"id": "phone:6", "name": "Fatima", "phone": "+49666"},
		{"id": "phone:7", "name": "Yuki", "phone": "+49777"},
		{"id": "phone:8", "name": "Zara", "phone": "+49888"},
	]
	main.contacts_home.add_contacts(contacts)
	main.contacts_home.recent_usage["phone:+49222"] = 2.0
	main.contacts_home.recent_usage["phone:+49111"] = 3.0
	main.solo_home.set_recent_chats(main.contacts_home.recent_contacts())
	main._show_solo_home()
	await _capture("app-chats")
	main._show_contacts_home()
	await _capture("app-contacts")
	main._show_contact_actions(contacts[0], "contacts")
	await _capture("app-contact-actions")
	main.fighter_lobby.set_layout_mode(false)
	main.fighter_lobby.open_for_quick_fight()
	await _capture("app-quick-fight")
	main._show_contacts_home()
	main.contacts_home.open_all_contacts()
	await _capture("app-invite-friends")
	main.contacts_home.open_settings()
	await _capture("app-settings")
	main.contacts_home.open_profile()
	await _capture("app-profile")
	quit()
