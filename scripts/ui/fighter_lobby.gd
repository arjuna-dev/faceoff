class_name FighterLobby
extends Control

## Pre-match screen for a fighter call. The lobby remains a normal portrait
## navigation page until the recipient accepts, then Main switches to the arena.

signal accept_requested
signal decline_requested
signal cancel_requested
signal microphone_toggled(enabled: bool)
signal camera_toggled(enabled: bool)

enum CallDirection {
	OUTGOING,
	INCOMING,
}

var contact: Dictionary = {}
var portrait_mode := true
var call_direction := CallDirection.OUTGOING
var incoming := false
var waiting_for_acceptance := false
var connecting := false
var mic_enabled := true
var camera_enabled := false
var camera_available := false
var quick_mode := false
var title_label: Label
var mode_label: Label
var contact_name_label: Label
var contact_tag_label: Label
var contact_presence_label: Label
var state_label: Label
var connection_label: Label
var avatar_texture: TextureRect
var avatar_initials: Label
var mic_button: Button
var camera_button: Button
var accept_button: Button
var decline_button: Button
var cancel_button: Button
var info_label: Label
var footer_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 60
	size = Vector2(540, 960) if portrait_mode else Vector2(960, 540)
	_build()
	_update_contact()
	_refresh_call_state()
	_refresh_action_buttons()
	_refresh_media_buttons()
	hide()
	queue_redraw()

func set_layout_mode(value: bool) -> void:
	if is_node_ready() and portrait_mode == value:
		size = Vector2(540, 960) if value else Vector2(960, 540)
		return
	portrait_mode = value
	size = Vector2(540, 960) if portrait_mode else Vector2(960, 540)
	if not is_node_ready():
		return
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_build()
	_update_contact()
	_refresh_call_state()
	_refresh_action_buttons()
	_refresh_media_buttons()
	queue_redraw()

func open_for_call(value: Dictionary, is_incoming := false) -> void:
	connecting = false
	quick_mode = false
	contact = value.duplicate(true)
	call_direction = CallDirection.INCOMING if is_incoming else CallDirection.OUTGOING
	incoming = call_direction == CallDirection.INCOMING
	waiting_for_acceptance = false
	mic_enabled = true
	camera_enabled = false
	_refresh_media_buttons()
	show()
	title_label.text = "FIGHTER CALL"
	mode_label.text = "SECURE CALL / THE ARENA OPENS AFTER ACCEPT"
	footer_label.text = "BACK returns to contacts"
	_update_contact()
	set_connection_status("READY TO CONNECT")
	_refresh_call_state()
	_refresh_action_buttons()
	queue_redraw()

func open_for_quick_fight() -> void:
	connecting = false
	quick_mode = true
	contact = {
		"id": "quick-fight",
		"name": "OPEN CIRCUIT",
		"tag": "PUBLIC MATCHMAKER",
		"presence": "SCANNING",
		"accent": Color("ffcb77"),
	}
	call_direction = CallDirection.OUTGOING
	incoming = false
	waiting_for_acceptance = true
	mic_enabled = true
	camera_enabled = false
	title_label.text = "QUICK FIGHT"
	mode_label.text = "GUEST LINK / FIRST AVAILABLE FIGHTER"
	footer_label.text = "BACK cancels search and returns to chats"
	_refresh_media_buttons()
	show()
	_update_contact()
	set_connection_status("SEARCHING FOR PLAYER 2")
	_refresh_call_state()
	_refresh_action_buttons()
	queue_redraw()

func close_lobby() -> void:
	hide()

## Changes the call direction while keeping the current contact and controls.
## Incoming calls expose Accept and Decline; outgoing calls expose Cancel.
func set_call_direction(is_incoming: bool) -> void:
	call_direction = CallDirection.INCOMING if is_incoming else CallDirection.OUTGOING
	incoming = call_direction == CallDirection.INCOMING
	waiting_for_acceptance = false
	_refresh_call_state()
	_refresh_action_buttons()

## Updates the outgoing call progress label without changing its action set.
func set_waiting(value: bool = true) -> void:
	waiting_for_acceptance = value
	_refresh_call_state()
	_refresh_action_buttons()

## Alias for the connection status API used by call signaling integrations.
func set_status(message: String) -> void:
	set_connection_status(message)

func set_connection_status(message: String) -> void:
	if not is_instance_valid(connection_label):
		return
	connection_label.text = message
	var upper := message.to_upper()
	if upper.contains("ERROR") or upper.contains("DECLIN") or upper.contains("FAIL"):
		connection_label.add_theme_color_override("font_color", Color("ff7d9c"))
	elif upper.contains("CONNECTED") or upper.contains("READY") or upper.contains("FOUND"):
		connection_label.add_theme_color_override("font_color", Color("78d9c6"))
	else:
		connection_label.add_theme_color_override("font_color", Color("ffcb77"))

func set_peer_count(count: int) -> void:
	if not is_instance_valid(info_label):
		return
	info_label.text = "%d fighter%s in room" % [count, "" if count == 1 else "s"]

func _refresh_call_state() -> void:
	if not is_instance_valid(state_label):
		return
	if quick_mode:
		state_label.text = "MATCHMAKER ACTIVE"
		info_label.text = "Both players should press QUICK FIGHT"
		return
	if incoming:
		state_label.text = "INCOMING CALL"
		info_label.text = "Accept to enter the fighter room"
	else:
		state_label.text = "WAITING FOR ACCEPTANCE" if waiting_for_acceptance else "CALLING"
		info_label.text = "Waiting for the other fighter"

func _refresh_action_buttons() -> void:
	if quick_mode:
		accept_button.hide()
		decline_button.hide()
		cancel_button.show()
		cancel_button.disabled = false
		cancel_button.text = "CANCEL SEARCH"
		return
	if connecting:
		accept_button.hide()
		decline_button.hide()
		cancel_button.show()
		cancel_button.disabled = false
		cancel_button.text = "END CALL"
		return
	cancel_button.text = "CANCEL CALL"
	if is_instance_valid(accept_button):
		accept_button.text = "ACCEPT / JOIN"
		accept_button.visible = incoming
		accept_button.disabled = not incoming or waiting_for_acceptance
	if is_instance_valid(decline_button):
		decline_button.visible = incoming
		decline_button.disabled = not incoming or waiting_for_acceptance
	if is_instance_valid(cancel_button):
		cancel_button.visible = not incoming
		cancel_button.disabled = incoming

func _draw() -> void:
	var view_size := size if size.x > 0.0 and size.y > 0.0 else (Vector2(540, 960) if portrait_mode else Vector2(960, 540))
	draw_rect(Rect2(Vector2.ZERO, view_size), Color("080a18"))
	for y in range(0, int(view_size.y), 4):
		draw_rect(Rect2(0, y, view_size.x, 1), Color(0.2, 0.2, 0.38, 0.16))
	if portrait_mode:
		draw_rect(Rect2(18, 16, view_size.x - 36, view_size.y - 32), Color("272548"), false, 4.0)
		draw_rect(Rect2(22, 98, view_size.x - 44, 448), Color("11152b"))
		draw_rect(Rect2(22, 560, view_size.x - 44, 230), Color("11152b"))
	else:
		draw_rect(Rect2(22, 18, view_size.x - 44, view_size.y - 36), Color("272548"), false, 4.0)
		draw_rect(Rect2(32, 94, view_size.x - 64, view_size.y - 126), Color("11152b"))

func _build() -> void:
	if portrait_mode:
		_build_portrait()
	else:
		_build_landscape()

func _build_portrait() -> void:
	title_label = _label("FIGHTER CALL", Vector2(28, 27), 30, Color("ffcb77"))
	mode_label = _label("SECURE CALL / THE ARENA OPENS AFTER ACCEPT", Vector2(30, 67), 11, Color("78d9c6"))
	_build_avatar(Vector2(190, 120), Vector2(160, 160))
	contact_name_label = _label("", Vector2(28, 298), 28, Color("f5edda"))
	contact_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	contact_name_label.size = Vector2(484, 36)
	contact_tag_label = _label("", Vector2(28, 340), 12, Color("ffcb77"))
	contact_tag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	contact_tag_label.size = Vector2(484, 24)
	contact_presence_label = _label("", Vector2(28, 369), 12, Color("78d9c6"))
	contact_presence_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	contact_presence_label.size = Vector2(484, 24)
	state_label = _label("CALLING", Vector2(28, 418), 20, Color("f5edda"))
	state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	state_label.size = Vector2(484, 32)
	connection_label = _label("READY TO CONNECT", Vector2(28, 462), 12, Color("78d9c6"))
	connection_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	connection_label.size = Vector2(484, 24)
	info_label = _label("Waiting for the other fighter", Vector2(28, 502), 11, Color("9ba7d0"))
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.size = Vector2(484, 24)
	_build_controls(Vector2(28, 594), Vector2(230, 50), Vector2(282, 594), Vector2(230, 50), Vector2(28, 664), Vector2(230, 52), Vector2(282, 664), Vector2(230, 52), Vector2(28, 734), Vector2(484, 52))
	_label("Microphone starts on. Camera is unavailable on this device.", Vector2(30, 816), 10, Color("777eaa"))
	footer_label = _label("BACK returns to contacts", Vector2(30, 920), 10, Color("777eaa"))

func _build_landscape() -> void:
	title_label = _label("FIGHTER CALL", Vector2(44, 32), 28, Color("ffcb77"))
	mode_label = _label("SECURE CALL / THE ARENA OPENS AFTER ACCEPT", Vector2(46, 70), 11, Color("78d9c6"))
	_build_avatar(Vector2(70, 130), Vector2(160, 160))
	contact_name_label = _label("", Vector2(260, 136), 30, Color("f5edda"))
	contact_tag_label = _label("", Vector2(262, 180), 12, Color("ffcb77"))
	contact_presence_label = _label("", Vector2(262, 208), 12, Color("78d9c6"))
	state_label = _label("CALLING", Vector2(262, 262), 20, Color("f5edda"))
	connection_label = _label("READY TO CONNECT", Vector2(262, 298), 12, Color("78d9c6"))
	info_label = _label("Waiting for the other fighter", Vector2(262, 326), 11, Color("9ba7d0"))
	_build_controls(Vector2(510, 126), Vector2(170, 44), Vector2(694, 126), Vector2(170, 44), Vector2(510, 190), Vector2(170, 44), Vector2(694, 190), Vector2(170, 44), Vector2(510, 254), Vector2(354, 44))
	_label("Microphone starts on. Camera is unavailable on this device.", Vector2(510, 326), 10, Color("777eaa"))
	footer_label = _label("BACK returns to contacts", Vector2(46, 492), 10, Color("777eaa"))

func _build_avatar(position_value: Vector2, size_value: Vector2) -> void:
	var card := Panel.new()
	card.position = position_value
	card.size = size_value
	card.add_theme_stylebox_override("panel", _style(Color("171b37"), Color("ffcb77")))
	add_child(card)
	avatar_texture = TextureRect.new()
	avatar_texture.position = Vector2(8, 8)
	avatar_texture.size = size_value - Vector2(16, 16)
	avatar_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	avatar_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	avatar_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(avatar_texture)
	avatar_initials = Label.new()
	avatar_initials.position = Vector2(8, 48)
	avatar_initials.size = Vector2(size_value.x - 16, 64)
	avatar_initials.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	avatar_initials.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar_initials.add_theme_font_size_override("font_size", 40)
	avatar_initials.add_theme_color_override("font_color", Color("ffcb77"))
	avatar_initials.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(avatar_initials)

func _build_controls(mic_position: Vector2, mic_size: Vector2, camera_position: Vector2, camera_size: Vector2, accept_position: Vector2, accept_size: Vector2, decline_position: Vector2, decline_size: Vector2, cancel_position: Vector2, cancel_size: Vector2) -> void:
	mic_button = _button("MIC OFF", mic_position, mic_size, Color("1a2340"), Color("4e70a5"), 12)
	mic_button.pressed.connect(_on_mic_pressed)
	camera_button = _button("CAMERA OFF", camera_position, camera_size, Color("1a2340"), Color("4e70a5"), 12)
	camera_button.pressed.connect(_on_camera_pressed)
	accept_button = _button("JOIN FIGHTER ROOM", accept_position, accept_size, Color("ffcb77"), Color("ffe7ab"), 12)
	accept_button.add_theme_color_override("font_color", Color("111225"))
	accept_button.pressed.connect(_on_accept_pressed)
	decline_button = _button("DECLINE", decline_position, decline_size, Color("291d3a"), Color("ff7d9c"), 12)
	decline_button.pressed.connect(_on_decline_pressed)
	cancel_button = _button("CANCEL CALL", cancel_position, cancel_size, Color("291d3a"), Color("ff7d9c"), 12)
	cancel_button.pressed.connect(_on_cancel_pressed)

func _button(text_value: String, position_value: Vector2, size_value: Vector2, background: Color, border: Color, font_size: int) -> Button:
	var button := Button.new()
	button.text = text_value
	button.position = position_value
	button.size = size_value
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_stylebox_override("normal", _style(background, border))
	button.add_theme_stylebox_override("hover", _style(background.lightened(0.08), Color("ffffff")))
	button.add_theme_stylebox_override("pressed", _style(background.lightened(0.14), Color("ffffff")))
	add_child(button)
	return button

func _label(text_value: String, position_value: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.position = position_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color("050510"))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _style(background: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = background
	box.border_color = border
	box.set_border_width_all(2)
	box.corner_radius_top_left = 3
	box.corner_radius_top_right = 3
	box.corner_radius_bottom_left = 3
	box.corner_radius_bottom_right = 3
	return box

func _update_contact() -> void:
	if not is_instance_valid(contact_name_label):
		return
	var name_value := String(contact.get("name", "CONTACT"))
	contact_name_label.text = name_value
	contact_tag_label.text = String(contact.get("tag", "PHONE CONTACT"))
	contact_presence_label.text = "● " + String(contact.get("presence", "AVAILABLE"))
	contact_presence_label.add_theme_color_override("font_color", contact.get("accent", Color("78d9c6")))
	var initials := ""
	for part in name_value.split(" "):
		if not part.is_empty():
			initials += part.left(1).to_upper()
	avatar_initials.text = initials.left(2)
	avatar_texture.texture = _load_avatar(contact)
	avatar_initials.visible = avatar_texture.texture == null

func _load_avatar(value: Dictionary) -> Texture2D:
	var id := String(value.get("id", ""))
	if id.begins_with("phone:"):
		return null
	var path := "res://assets/fighters/%s/head.png" % id
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	return null

func _on_accept_pressed() -> void:
	if not incoming or waiting_for_acceptance:
		return
	accept_requested.emit()

func _on_decline_pressed() -> void:
	if not incoming or waiting_for_acceptance:
		return
	decline_requested.emit()

func _on_cancel_pressed() -> void:
	if incoming and not connecting:
		return
	cancel_requested.emit()

func _on_mic_pressed() -> void:
	mic_enabled = not mic_enabled
	_refresh_media_buttons()
	microphone_toggled.emit(mic_enabled)

func _on_camera_pressed() -> void:
	if not camera_available:
		return
	camera_enabled = not camera_enabled
	_refresh_media_buttons()
	camera_toggled.emit(camera_enabled)

func _refresh_media_buttons() -> void:
	if is_instance_valid(mic_button):
		mic_button.text = "MIC ON" if mic_enabled else "MIC OFF"
		mic_button.add_theme_stylebox_override("normal", _style(Color("194238") if mic_enabled else Color("1a2340"), Color("78d9c6") if mic_enabled else Color("4e70a5")))
	if is_instance_valid(camera_button):
		camera_button.disabled = not camera_available
		camera_button.focus_mode = Control.FOCUS_ALL if camera_available else Control.FOCUS_NONE
		camera_button.text = "CAMERA ON" if camera_enabled else ("CAMERA OFF" if camera_available else "CAMERA UNAVAILABLE")
		camera_button.add_theme_stylebox_override("normal", _style(Color("194238") if camera_enabled else Color("1a2340"), Color("78d9c6") if camera_enabled else Color("4e70a5")))

func set_camera_available(value: bool) -> void:
	camera_available = value
	if not camera_available:
		camera_enabled = false
	_refresh_media_buttons()

func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event.is_pressed() or event.is_echo():
		return
	if event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
		_on_accept_pressed()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE:
		_on_decline_pressed() if incoming else _on_cancel_pressed()
		get_viewport().set_input_as_handled()

func set_connecting() -> void:
	connecting = true
	state_label.text = "CONNECTING"
	info_label.text = "Waiting for both players to join"
	_refresh_action_buttons()
