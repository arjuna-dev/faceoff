class_name ContactsHome
extends Control

signal call_requested(contact: Dictionary)
signal message_requested(contact: Dictionary)
signal send_requested(contact: Dictionary, text: String, ping: bool)
signal demo_requested
signal import_requested
signal invite_channel_requested(channel: String)
signal invite_contact_requested(contact: Dictionary)
signal phone_code_requested(phone: String)
signal phone_verify_requested(phone: String, code: String, display_name: String)
signal tab_requested(tab: String)
signal recent_chats_updated(contacts: Array[Dictionary])
signal contact_selected(contact: Dictionary)

const TAP_MAX_MSEC := 360
const TAP_MAX_SCROLL := 12.0
const NAV_HEIGHT := 76.0

var contacts: Array[Dictionary] = []
var selected_index := 0
var portrait_mode := true
var page := "contacts"
var page_history: Array[String] = []
var verified := false
var account_profile: Dictionary = {}
var account_name := ""
var status_text := "Connect with your people. Fight together."
var rows: Array[Button] = []
var import_status: Label
var search_input: LineEdit
var manual_phone_input: LineEdit
var contacts_list: VBoxContainer
var contacts_scroll: ScrollContainer
var search_query := ""
var chat_input: LineEdit
var phone_input: LineEdit
var code_input: LineEdit
var name_input: LineEdit
var pending_phone_prefill := ""
var chat_log: RichTextLabel
var call_button: Button
var demo_button: Button
var message_button: Button
var import_button: Button
var messages: Dictionary = {}
var recent_usage: Dictionary = {}
var _rebuild_pending := false
var _scroll_guard_until_msec := 0
var _scrolling := false
var _row_press: Dictionary = {}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var saved := ConfigFile.new()
	if saved.load(SocialStorage.path("conversations.cfg")) == OK:
		messages = saved.get_value("messages", "items", {})
		recent_usage = saved.get_value("recent", "last_used", {})
	_build()

func set_layout_mode(value: bool) -> void:
	if portrait_mode == value:
		return
	portrait_mode = value
	_rebuild()

func open_friends(reset_history := true) -> void:
	page = "contacts"
	search_query = ""
	if reset_history:
		page_history.clear()
	_rebuild()

func open_all_contacts() -> void:
	_navigate("all_contacts")

func open_settings() -> void:
	page_history.clear()
	page = "settings"
	search_query = ""
	_rebuild()

func open_profile() -> void:
	page_history.clear()
	page = "profile"
	search_query = ""
	_rebuild()

func prefill_phone(number: String) -> void:
	var value := number.strip_edges()
	if value.is_empty():
		return
	pending_phone_prefill = value
	open_profile()

func open_conversation(contact: Dictionary) -> void:
	var index := _find_contact(contact)
	if index < 0:
		return
	selected_index = index
	_mark_contact_used(contacts[index])
	page_history = ["contacts"]
	page = "conversation"
	search_query = ""
	_rebuild()

func go_back() -> bool:
	if page_history.is_empty():
		if page == "contacts":
			return false
		page = "contacts"
	else:
		page = page_history.pop_back()
	search_query = ""
	_rebuild()
	return true

func faceoff_friend_count() -> int:
	var count := 0
	for contact in contacts:
		if not String(contact.get("user_id", "")).is_empty():
			count += 1
	return count

func recent_contacts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for contact in contacts:
		var used := float(recent_usage.get(_contact_key(contact), 0.0))
		if used <= 0.0 or String(contact.get("user_id", "")).is_empty():
			continue
		var item := contact.duplicate(true)
		item["last_used"] = used
		result.append(item)
	result.sort_custom(func(a: Dictionary, b: Dictionary): return float(a.get("last_used", 0.0)) > float(b.get("last_used", 0.0)))
	return result

func mark_contact_used(contact: Dictionary) -> void:
	_mark_contact_used(contact)

func mark_peer_used(peer: String) -> void:
	for contact in contacts:
		if String(contact.get("user_id", "")) == peer:
			_mark_contact_used(contact)
			return

func _rebuild() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	call_deferred("_build")

func _build() -> void:
	_rebuild_pending = false
	for child in get_children():
		remove_child(child)
		child.queue_free()
	rows.clear()
	search_input = null
	contacts_list = null
	contacts_scroll = null
	_row_press.clear()
	size = Vector2(540, 960) if portrait_mode else Vector2(960, 540)
	var width := size.x - 48.0
	var system_label := _label("FACE//OFF NETWORK  199X", Vector2(24, 10), 11, Color("78d9c6"))
	system_label.size = Vector2(width, 18)
	var heading := _label(_page_title().to_upper(), Vector2(24, 30), 30, Color("ffcb77"))
	heading.size = Vector2(size.x - 168, 48)
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if page in ["all_contacts", "conversation"]:
		_button("< BACK", Vector2(size.x - 134, 28), Vector2(110, 42), go_back)
	import_status = _label("STATUS // " + status_text, Vector2(24, 78), 13, Color("9cb5c6"))
	import_status.size = Vector2(width, 36)
	import_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if page == "settings":
		_build_settings(width)
	elif page == "profile":
		_build_profile(width)
	elif page == "conversation":
		_build_conversation(width)
	elif page == "all_contacts":
		_build_all_contacts(width)
	else:
		_build_friends(width)
	_build_bottom_navigation()
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("080a18"))
	for y in range(0, int(size.y), 6):
		draw_line(Vector2(0, y), Vector2(size.x, y), Color(0.22, 0.3, 0.55, 0.12), 1.0)
	for x in range(0, int(size.x), 54):
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color(0.2, 0.75, 0.73, 0.035), 1.0)
	draw_rect(Rect2(10, 8, size.x - 20, size.y - 18), Color("272548"), false, 2.0)
	draw_line(Vector2(24, 108), Vector2(size.x - 24, 108), Color("ff7d9c"), 2.0)

func _page_title() -> String:
	if page == "settings":
		return "Settings"
	if page == "profile":
		return "Profile"
	if page == "all_contacts":
		return "Invite Friends"
	if page == "conversation":
		return String(get_selected_contact().get("name", "Conversation"))
	return "Contacts"

func _build_friends(width: float) -> void:
	_button("+ INVITE FRIENDS", Vector2(24, 118), Vector2(width, 56), _request_import)
	_build_search("SEARCH FACE//OFF CONTACTS", 190.0, width)
	_build_scroll(258.0, size.y - NAV_HEIGHT - 274.0, width)
	_refresh_contact_rows(true)

func _build_all_contacts(width: float) -> void:
	_button("SHARE FACE//OFF", Vector2(24, 118), Vector2(width, 56), func(): invite_channel_requested.emit("more"))
	manual_phone_input = _text_field("ENTER NUMBER  +4522206992", Vector2(24, 190), width - 104)
	manual_phone_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PHONE
	_button("INVITE", Vector2(size.x - 116, 190), Vector2(92, 56), _invite_manual_phone)
	_build_search("SEARCH PHONE CONTACTS", 262.0, width)
	_build_scroll(330.0, size.y - NAV_HEIGHT - 346.0, width)
	_refresh_contact_rows(false)

func _build_search(placeholder: String, top: float, width: float) -> void:
	search_input = _text_field(placeholder, Vector2(24, top), width)
	search_input.text = search_query
	search_input.clear_button_enabled = true
	search_input.text_changed.connect(_on_search_changed)

func _build_scroll(top: float, height: float, width: float) -> void:
	contacts_scroll = ScrollContainer.new()
	contacts_scroll.position = Vector2(24, top)
	contacts_scroll.size = Vector2(width, maxf(80.0, height))
	contacts_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	contacts_scroll.scroll_deadzone = 18
	contacts_scroll.scroll_started.connect(_on_scroll_started)
	contacts_scroll.scroll_ended.connect(_on_scroll_ended)
	add_child(contacts_scroll)
	contacts_list = VBoxContainer.new()
	contacts_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contacts_list.add_theme_constant_override("separation", 6)
	contacts_scroll.add_child(contacts_list)

func _refresh_contact_rows(faceoff_only: bool) -> void:
	if not is_instance_valid(contacts_list):
		return
	for child in contacts_list.get_children():
		contacts_list.remove_child(child)
		child.queue_free()
	rows.clear()
	var filtered: Array[int] = []
	var query := search_query.strip_edges().to_lower()
	for index in contacts.size():
		var contact := contacts[index]
		var registered := not String(contact.get("user_id", "")).is_empty()
		if faceoff_only and not registered:
			continue
		if not faceoff_only and String(contact.get("phone", "")).is_empty():
			continue
		var haystack := (String(contact.get("name", "")) + " " + String(contact.get("phone", ""))).to_lower()
		if query.is_empty() or haystack.contains(query):
			filtered.append(index)
	if filtered.is_empty():
		var empty := Label.new()
		empty.text = "No matching contacts." if not query.is_empty() else ("No contacts on Faceoff yet." if faceoff_only else "No phone contacts imported yet.")
		empty.custom_minimum_size = Vector2(contacts_scroll.size.x - 12, 90)
		empty.add_theme_font_size_override("font_size", 21)
		empty.add_theme_color_override("font_color", Color("dfebf3"))
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		contacts_list.add_child(empty)
		return
	for index in filtered:
		var contact := contacts[index]
		var subtitle := "ONLINE // READY" if faceoff_only else String(contact.get("phone", ""))
		var initial := String(contact.get("name", "?")).left(1).to_upper()
		var row := _list_button("%s     %s\n       %s" % [initial, contact.get("name", "Contact"), subtitle])
		row.button_down.connect(_begin_row_press.bind(index, not faceoff_only))
		row.button_up.connect(_end_row_press.bind(index, not faceoff_only))
		contacts_list.add_child(row)
		rows.append(row)

func _build_settings(width: float) -> void:
	var card := PanelContainer.new()
	card.position = Vector2(24, 124)
	card.size = Vector2(width, 190)
	card.add_theme_stylebox_override("panel", _style(Color("162737")))
	add_child(card)
	var label := Label.new()
	label.text = "No settings yet"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color("dfebf3"))
	card.add_child(label)

func _build_profile(width: float) -> void:
	var avatar := Panel.new()
	avatar.position = Vector2((size.x - 128.0) * 0.5, 112)
	avatar.size = Vector2(128, 128)
	var avatar_style := _style(Color("397b91"))
	avatar_style.set_corner_radius_all(64)
	avatar.add_theme_stylebox_override("panel", avatar_style)
	add_child(avatar)
	var initial := _label(_profile_initial(), Vector2((size.x - 128.0) * 0.5, 120), 68, Color("fff0d1"))
	initial.size = Vector2(128, 108)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var shown_name := account_name if not account_name.is_empty() else "Your profile"
	var name_label := _label(shown_name, Vector2(24, 252), 28)
	name_label.size = Vector2(width, 42)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var button_width := (width - 12.0) * 0.5
	_button("Set photo", Vector2(24, 306), Vector2(button_width, 54), func(): set_import_status("Photo picker will be available here"))
	_button("Edit info", Vector2(36 + button_width, 306), Vector2(button_width, 54), func(): set_import_status("Profile editing will be available here"))
	var info := PanelContainer.new()
	info.position = Vector2(24, 382)
	info.size = Vector2(width, 112)
	info.add_theme_stylebox_override("panel", _style(Color("162737")))
	add_child(info)
	var info_label := Label.new()
	var phone := String(account_profile.get("phone", "Not verified"))
	info_label.text = "Mobile phone\n%s\n\n%s" % [phone, _profile_handle()]
	info_label.add_theme_font_size_override("font_size", 18)
	info_label.add_theme_color_override("font_color", Color("dfebf3"))
	info.add_child(info_label)
	if verified:
		return
	name_input = _text_field("Your name", Vector2(24, 516), width)
	phone_input = _text_field("Phone number, e.g. +491234567890", Vector2(24, 578), width)
	phone_input.text = pending_phone_prefill
	phone_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_PHONE
	_button("Send verification code", Vector2(24, 640), Vector2(width, 50), func(): phone_code_requested.emit(phone_input.text.strip_edges()))
	code_input = _text_field("6-digit verification code", Vector2(24, 702), width)
	code_input.max_length = 6
	code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_button("Verify and continue", Vector2(24, 764), Vector2(width, 50), func(): phone_verify_requested.emit(phone_input.text.strip_edges(), code_input.text.strip_edges(), name_input.text.strip_edges()))

func _build_conversation(width: float) -> void:
	var contact := get_selected_contact()
	var registered := verified and not String(contact.get("user_id", "")).is_empty()
	call_button = _button("Call", Vector2(24, 124), Vector2((width - 16) / 3, 58), func():
		_mark_contact_used(get_selected_contact())
		call_requested.emit(get_selected_contact()))
	call_button.icon = preload("res://assets/ui/phone.svg")
	call_button.disabled = not registered
	var video := _button("Video", Vector2(24 + (width + 8) / 3, 124), Vector2((width - 16) / 3, 58), func(): pass)
	video.icon = preload("res://assets/ui/video.svg")
	video.disabled = true
	video.tooltip_text = "Face video is not available yet"
	var ping := _button("Ping", Vector2(24 + 2 * (width + 8) / 3, 124), Vector2((width - 16) / 3, 58), func():
		_mark_contact_used(get_selected_contact())
		send_requested.emit(get_selected_contact(), "Ready for a fight?", true))
	ping.icon = preload("res://assets/ui/ping.svg")
	ping.disabled = not registered
	chat_log = RichTextLabel.new()
	chat_log.position = Vector2(24, 204)
	chat_log.size = Vector2(width, maxf(80, size.y - NAV_HEIGHT - 302))
	chat_log.add_theme_font_size_override("normal_font_size", 20)
	add_child(chat_log)
	_refresh_messages()
	chat_input = _text_field("Message", Vector2(24, size.y - NAV_HEIGHT - 66), width - 100)
	chat_input.editable = registered
	chat_input.text_submitted.connect(func(_value): _send_chat_message())
	message_button = _button("Send", Vector2(size.x - 116, size.y - NAV_HEIGHT - 66), Vector2(92, 56), _send_chat_message)
	message_button.icon = preload("res://assets/ui/message.svg")
	message_button.disabled = not registered

func _build_bottom_navigation() -> void:
	var top := size.y - NAV_HEIGHT
	var background := ColorRect.new()
	background.position = Vector2(0, top)
	background.size = Vector2(size.x, NAV_HEIGHT)
	background.color = Color("080a18")
	add_child(background)
	var tab_width := size.x / 4.0
	var tabs := ["CHATS", "CONTACTS", "SETTINGS", "PROFILE"]
	for i in tabs.size():
		var tab_name: String = tabs[i]
		var active := (tab_name == "CONTACTS" and page in ["contacts", "all_contacts", "conversation"]) or tab_name.to_lower() == page
		var button := Button.new()
		button.text = tab_name
		button.position = Vector2(tab_width * i, top)
		button.size = Vector2(tab_width, NAV_HEIGHT)
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_color_override("font_color", Color("ffcb77") if active else Color("71849c"))
		button.add_theme_stylebox_override("normal", _style(Color("17152c") if active else Color("080a18"), Color("78d9c6") if active else Color("272548")))
		button.add_theme_stylebox_override("pressed", _style(Color("291d3a"), Color("ff7d9c")))
		button.pressed.connect(_on_tab_pressed.bind(tab_name.to_lower()))
		add_child(button)

func _on_tab_pressed(tab: String) -> void:
	if tab == "chats":
		tab_requested.emit(tab)
	elif tab == "contacts":
		open_friends()
	elif tab == "settings":
		open_settings()
	elif tab == "profile":
		open_profile()

func _text_field(hint: String, pos: Vector2, width: float) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = hint
	field.position = pos
	field.size = Vector2(width, 56)
	field.add_theme_font_size_override("font_size", 20)
	field.add_theme_stylebox_override("normal", _style(Color("10172a"), Color("4e70a5")))
	add_child(field)
	return field

func _label(value: String, pos: Vector2, font_size: int, color := Color("dfebf3")) -> Label:
	var label := Label.new()
	label.text = value
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _style(color: Color, border := Color("272548")) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(2)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style

func _button(value: String, pos: Vector2, dimensions: Vector2, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.position = pos
	button.size = dimensions
	button.add_theme_font_size_override("font_size", 19)
	button.add_theme_stylebox_override("normal", _style(Color("18263a"), Color("4e70a5")))
	button.add_theme_stylebox_override("hover", _style(Color("213a50"), Color("78d9c6")))
	button.add_theme_stylebox_override("pressed", _style(Color("35203d"), Color("ff7d9c")))
	button.pressed.connect(action)
	add_child(button)
	return button

func _list_button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	button.custom_minimum_size = Vector2(contacts_scroll.size.x - 12, 78)
	button.add_theme_font_size_override("font_size", 20)
	button.add_theme_stylebox_override("normal", _style(Color("10172a"), Color("313b61")))
	button.add_theme_stylebox_override("hover", _style(Color("17293a"), Color("78d9c6")))
	button.add_theme_stylebox_override("pressed", _style(Color("291d3a"), Color("ffcb77")))
	return button

func _navigate(destination: String) -> void:
	if page == destination:
		return
	page_history.append(page)
	page = destination
	search_query = ""
	_rebuild()

func _request_import() -> void:
	if page != "all_contacts":
		_navigate("all_contacts")
	import_requested.emit()

func _begin_row_press(index: int, invite: bool) -> void:
	_row_press = {
		"index": index,
		"invite": invite,
		"time": Time.get_ticks_msec(),
		"scroll": contacts_scroll.scroll_vertical if is_instance_valid(contacts_scroll) else 0,
	}

func _end_row_press(index: int, invite: bool) -> void:
	if _row_press.is_empty() or int(_row_press.get("index", -1)) != index or bool(_row_press.get("invite", false)) != invite:
		return
	var elapsed := Time.get_ticks_msec() - int(_row_press.get("time", 0))
	var start_scroll := float(_row_press.get("scroll", 0.0))
	var current_scroll := float(contacts_scroll.scroll_vertical if is_instance_valid(contacts_scroll) else 0.0)
	_row_press.clear()
	if _scrolling or Time.get_ticks_msec() < _scroll_guard_until_msec or elapsed > TAP_MAX_MSEC or absf(current_scroll - start_scroll) > TAP_MAX_SCROLL:
		return
	if invite:
		_invite_contact(index)
	else:
		_select_contact(index)

func _select_contact(index: int) -> void:
	if Time.get_ticks_msec() < _scroll_guard_until_msec or index < 0 or index >= contacts.size():
		return
	selected_index = index
	_mark_contact_used(contacts[index])
	contact_selected.emit(contacts[index].duplicate(true))

func _invite_contact(index: int) -> void:
	if index < 0 or index >= contacts.size():
		return
	invite_contact_requested.emit(contacts[index])

func _invite_manual_phone() -> void:
	if not is_instance_valid(manual_phone_input):
		return
	var value := manual_phone_input.text.strip_edges()
	if value.is_empty():
		set_import_status("Enter a full international phone number first", false)
		return
	invite_contact_requested.emit({
		"id": "manual:" + value,
		"name": "Friend",
		"tag": "PHONE CONTACT",
		"presence": "INVITE",
		"phone": value,
	})
	manual_phone_input.clear()

func _on_scroll_started() -> void:
	_scrolling = true
	_scroll_guard_until_msec = Time.get_ticks_msec() + 300

func _on_scroll_ended() -> void:
	_scrolling = false
	_scroll_guard_until_msec = Time.get_ticks_msec() + 180

func _on_search_changed(value: String) -> void:
	search_query = value
	_refresh_contact_rows(page == "contacts")

func get_selected_contact() -> Dictionary:
	return contacts[selected_index] if selected_index >= 0 and selected_index < contacts.size() else {}

func set_import_status(message: String, _good := false) -> void:
	status_text = message
	if is_instance_valid(import_status):
		import_status.text = message

func set_account(profile: Dictionary) -> void:
	account_profile = profile.duplicate(true)
	verified = not profile.is_empty()
	account_name = String(profile.get("name", ""))
	if verified:
		pending_phone_prefill = ""
	_rebuild()

func add_contacts(imported: Array[Dictionary]) -> int:
	var selected_key := _contact_key(get_selected_contact())
	contacts = imported.duplicate(true)
	contacts.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.get("name", "")).naturalnocasecmp_to(String(b.get("name", ""))) < 0)
	selected_index = 0
	for i in contacts.size():
		if _contact_key(contacts[i]) == selected_key:
			selected_index = i
	_rebuild()
	recent_chats_updated.emit(recent_contacts())
	return contacts.size()

func append_message(peer: String, text: String) -> void:
	if not messages.has(peer):
		messages[peer] = []
	messages[peer].append(text)
	if messages[peer].size() > 100:
		messages[peer].pop_front()
	for contact in contacts:
		if String(contact.get("user_id", "")) == peer:
			_mark_contact_used(contact, false)
			break
	_save_conversations()
	_refresh_messages()
	recent_chats_updated.emit(recent_contacts())

func _refresh_messages() -> void:
	if is_instance_valid(chat_log):
		chat_log.text = "\n\n".join(messages.get(String(get_selected_contact().get("user_id", "")), []))

func _send_chat_message() -> void:
	if not is_instance_valid(chat_input) or chat_input.text.strip_edges().is_empty():
		return
	_mark_contact_used(get_selected_contact())
	send_requested.emit(get_selected_contact(), chat_input.text.strip_edges(), false)
	chat_input.clear()

func _mark_contact_used(contact: Dictionary, save := true) -> void:
	var key := _contact_key(contact)
	if key.is_empty():
		return
	recent_usage[key] = Time.get_unix_time_from_system()
	if save:
		_save_conversations()
	recent_chats_updated.emit(recent_contacts())

func _save_conversations() -> void:
	var saved := ConfigFile.new()
	saved.set_value("messages", "items", messages)
	saved.set_value("recent", "last_used", recent_usage)
	saved.save(SocialStorage.path("conversations.cfg"))

func _contact_key(contact: Dictionary) -> String:
	var phone := String(contact.get("phone", "")).strip_edges()
	if not phone.is_empty():
		return "phone:" + phone
	var user_id := String(contact.get("user_id", "")).strip_edges()
	if not user_id.is_empty():
		return "user:" + user_id
	return String(contact.get("id", ""))

func _find_contact(contact: Dictionary) -> int:
	var key := _contact_key(contact)
	for i in contacts.size():
		if _contact_key(contacts[i]) == key:
			return i
	return -1

func _profile_initial() -> String:
	return (account_name.left(1) if not account_name.is_empty() else "F").to_upper()

func _profile_handle() -> String:
	var provided := String(account_profile.get("handle", "")).strip_edges()
	if not provided.is_empty():
		return provided if provided.begins_with("@") else "@" + provided
	var handle := ""
	for character in account_name.to_lower():
		if character in "abcdefghijklmnopqrstuvwxyz0123456789":
			handle += character
		elif character == " " and not handle.ends_with("_"):
			handle += "_"
	handle = handle.trim_suffix("_")
	return "@" + (handle if not handle.is_empty() else "fighter")

func _process(_delta: float) -> void:
	if not OS.has_feature("android"):
		return
	position.y = 0
	if not visible:
		return
	var focused := get_viewport().gui_get_focus_owner()
	if not focused is LineEdit or not is_ancestor_of(focused):
		return
	var keyboard := DisplayServer.virtual_keyboard_get_height()
	if keyboard <= 0:
		return
	var keyboard_height := keyboard * size.y / maxf(1, DisplayServer.window_get_size().y)
	var overflow := focused.global_position.y + focused.size.y + 20 - (size.y - keyboard_height)
	position.y = -maxf(0, overflow)
