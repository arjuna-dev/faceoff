extends SceneTree

const ContactsHomeType = preload("res://scripts/ui/contacts_home.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var screen: ContactsHome = ContactsHomeType.new()
	root.add_child(screen)
	await process_frame
	screen.set_account({"name": "Tester"})
	screen.add_contacts([
		{"id": "phone:1", "name": "Alice", "phone": "+49111", "user_id": "alice-user"},
		{"id": "phone:2", "name": "Bob", "phone": "+49222"},
	])
	await process_frame
	await process_frame
	check(screen.page == "contacts" and screen.rows.size() == 1, "friend list shows only registered Faceoff friends")
	check(screen.faceoff_friend_count() == 1, "friend count ignores phone-only contacts")
	check(screen.rows[0].button_down.get_connections().size() > 0, "contact names use a tappable row")

	screen._on_scroll_started()
	screen._select_contact(0)
	check(screen.page == "contacts", "a swipe gesture cannot activate a friend row")
	screen._scroll_guard_until_msec = 0
	var selected: Array[Dictionary] = []
	screen.contact_selected.connect(func(contact: Dictionary): selected.append(contact))
	screen._select_contact(0)
	await process_frame
	check(screen.page == "contacts" and selected.size() == 1, "a deliberate tap opens the arena contact action flow")
	check(String(selected[0].get("user_id", "")) == "alice-user", "the selected Faceoff contact is emitted")

	var import_events: Array[String] = []
	screen.import_requested.connect(func(): import_events.append("import"))
	screen._request_import()
	await process_frame
	await process_frame
	check(import_events.size() == 1 and screen.page == "all_contacts", "Invite friends opens All contacts and starts import")
	check(screen.contacts_list.get_child_count() == 2, "All contacts includes registered and unregistered phone contacts")
	screen._on_search_changed("bob")
	check(screen.contacts_list.get_child_count() == 1, "contact search filters the visible list")
	var invited: Array[String] = []
	screen.invite_contact_requested.connect(func(contact: Dictionary): invited.append(String(contact.get("phone", ""))))
	screen._scroll_guard_until_msec = 0
	screen._scrolling = false
	screen._begin_row_press(1, true)
	screen._end_row_press(1, true)
	check(invited == ["+49222"], "tapping an imported contact immediately requests an SMS invite")
	screen.manual_phone_input.text = "+4522206992"
	screen._invite_manual_phone()
	check(invited == ["+49222", "+4522206992"], "a number can be invited without saving it in phone contacts")

	var many: Array[Dictionary] = []
	for i in 650:
		many.append({"id": "phone:%d" % i, "name": "Contact %03d" % i, "phone": "+49%09d" % i})
	many.append({"id": "phone:z", "name": "Zara", "phone": "+49999999999"})
	screen.add_contacts(many)
	screen.open_all_contacts()
	screen._on_search_changed("")
	await process_frame
	await process_frame
	check(screen.rows.size() == 651, "all imported contacts remain visible beyond the former 500-row cutoff")
	screen._on_search_changed("zara")
	check(screen.rows.size() == 1, "search reaches contacts at the end of the alphabet")

	screen.open_settings()
	await process_frame
	check(screen.page == "settings", "Settings is a dedicated bottom-tab destination")
	screen.open_profile()
	await process_frame
	check(screen.page == "profile", "Profile is a dedicated bottom-tab destination")
	screen.set_account({})
	await process_frame
	await process_frame
	screen.prefill_phone("+4522206992")
	await process_frame
	await process_frame
	check(screen.page == "profile" and is_instance_valid(screen.phone_input) and screen.phone_input.text == "+4522206992", "invite opens Profile with the recipient phone prefilled")

	print("Contacts home: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
