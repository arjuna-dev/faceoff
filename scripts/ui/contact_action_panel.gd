class_name ContactActionPanel
extends Control

signal start_fight_requested(contact: Dictionary)
signal back_requested

var contact: Dictionary = {}
var contact_name_label: Label
var contact_status_label: Label
var start_fight_button: Button
var call_button: Button
var message_button: Button

func _ready() -> void:
	size = Vector2(960, 540)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 65
	_build()
	hide()
	queue_redraw()

func open_for_contact(value: Dictionary) -> void:
	contact = value.duplicate(true)
	var name := String(contact.get("name", "CONTACT")).strip_edges()
	contact_name_label.text = name.to_upper() if not name.is_empty() else "CONTACT"
	var presence := String(contact.get("presence", "ONLINE")).strip_edges().to_upper()
	contact_status_label.text = "LINK // %s  ID // %s" % [presence, _short_id()]
	start_fight_button.disabled = String(contact.get("user_id", "")).is_empty()
	show()
	queue_redraw()

func close_panel() -> void:
	hide()

func _build() -> void:
	_label("CONTACT TERMINAL", Vector2(554, 52), 11, Color("78d9c6"))
	contact_name_label = _label("CONTACT", Vector2(554, 74), 28, Color("ffcb77"))
	contact_name_label.size = Vector2(342, 40)
	contact_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	contact_status_label = _label("LINK // ONLINE", Vector2(554, 116), 11, Color("9ba7d0"))
	contact_status_label.size = Vector2(342, 22)
	_label("SELECT ACTION", Vector2(554, 164), 12, Color("f5edda"))
	call_button = _button("CALL", Vector2(554, 194), Vector2(342, 52), Color("10172a"), Color("313b61"))
	call_button.disabled = true
	call_button.tooltip_text = "Voice-only calls are coming later"
	start_fight_button = _button("START FIGHT  >>", Vector2(554, 258), Vector2(342, 62), Color("ffcb77"), Color("fff0d1"))
	start_fight_button.name = "StartFightButton"
	start_fight_button.add_theme_color_override("font_color", Color("111225"))
	start_fight_button.pressed.connect(func(): start_fight_requested.emit(contact.duplicate(true)))
	message_button = _button("MESSAGE", Vector2(554, 332), Vector2(342, 52), Color("10172a"), Color("313b61"))
	message_button.disabled = true
	message_button.tooltip_text = "Messaging is coming later"
	var back := _button("< BACK", Vector2(554, 408), Vector2(118, 36), Color("291d3a"), Color("ff7d9c"))
	back.pressed.connect(func(): back_requested.emit())
	var hint := _label("CALL + MESSAGE OFFLINE", Vector2(686, 416), 10, Color("71849c"))
	hint.size = Vector2(210, 20)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

func _short_id() -> String:
	var value := String(contact.get("user_id", contact.get("id", "PLAYER"))).to_upper()
	return value.left(10) if not value.is_empty() else "PLAYER"

func _draw() -> void:
	draw_rect(Rect2(536, 40, 378, 420), Color("9b3866aa"))
	draw_rect(Rect2(530, 34, 378, 420), Color("080a18ed"))
	for y in range(38, 452, 6):
		draw_line(Vector2(532, y), Vector2(906, y), Color(0.22, 0.3, 0.55, 0.11), 1.0)
	for x in range(534, 908, 32):
		draw_line(Vector2(x, 36), Vector2(x, 452), Color(0.2, 0.75, 0.73, 0.035), 1.0)
	draw_rect(Rect2(530, 34, 378, 420), Color("78d9c6"), false, 2.0)
	draw_line(Vector2(554, 148), Vector2(884, 148), Color("ff7d9c"), 2.0)
	draw_rect(Rect2(542, 46, 6, 6), Color("ffcb77"))

func _label(value: String, position_value: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = position_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color("050510"))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _button(value: String, position_value: Vector2, size_value: Vector2, background: Color, border: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.position = position_value
	button.size = size_value
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_stylebox_override("normal", _style(background, border))
	button.add_theme_stylebox_override("hover", _style(background.lightened(0.08), Color("78d9c6")))
	button.add_theme_stylebox_override("pressed", _style(background.darkened(0.08), Color("ff7d9c")))
	button.add_theme_stylebox_override("disabled", _style(Color("0b1020"), Color("272548")))
	button.add_theme_color_override("font_disabled_color", Color("59647b"))
	add_child(button)
	return button

func _style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(2)
	return style

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_pressed() and not event.is_echo() and event.keycode == KEY_ESCAPE:
		back_requested.emit()
		get_viewport().set_input_as_handled()
