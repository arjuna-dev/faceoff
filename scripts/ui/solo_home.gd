class_name SoloHome
extends Control

signal call_friend_requested
signal demo_requested
signal quick_fight_requested
signal tab_requested(tab: String)
signal contact_requested(contact: Dictionary)

const PANEL_LEFT := 530.0
const NAV_TOP := 476.0

var call_button: Button
var search_input: LineEdit
var chat_scroll: ScrollContainer
var chat_list: VBoxContainer
var recent_chats: Array[Dictionary] = []
var search_query := ""

func _ready() -> void:
	size = Vector2(960, 540)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 60
	_build()

func set_recent_chats(value: Array[Dictionary]) -> void:
	recent_chats = value.duplicate(true)
	_refresh_chats()

func _build() -> void:
	var channel := _label("FACE//OFF  CHANNEL 07", Vector2(552, 43), 10, Color("78d9c6"))
	channel.size = Vector2(350, 18)
	var title := _label("CHAT LOG", Vector2(552, 59), 27, Color("ffcb77"))
	title.size = Vector2(350, 42)
	search_input = LineEdit.new()
	search_input.placeholder_text = "SEARCH CALL HISTORY"
	search_input.position = Vector2(552, 105)
	search_input.size = Vector2(354, 42)
	search_input.add_theme_font_size_override("font_size", 16)
	search_input.add_theme_stylebox_override("normal", _style(Color("10172a"), Color("4e70a5")))
	search_input.text_changed.connect(func(value: String):
		search_query = value
		_refresh_chats())
	add_child(search_input)
	chat_scroll = ScrollContainer.new()
	chat_scroll.position = Vector2(552, 158)
	chat_scroll.size = Vector2(354, 190)
	chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	chat_scroll.scroll_deadzone = 18
	add_child(chat_scroll)
	chat_list = VBoxContainer.new()
	chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chat_list.add_theme_constant_override("separation", 6)
	chat_scroll.add_child(chat_list)
	var quick_button := Button.new()
	quick_button.name = "QuickFightButton"
	quick_button.text = "QUICK FIGHT  >>"
	quick_button.position = Vector2(552, 358)
	quick_button.size = Vector2(354, 46)
	quick_button.add_theme_font_size_override("font_size", 18)
	quick_button.add_theme_color_override("font_color", Color("111225"))
	quick_button.add_theme_stylebox_override("normal", _style(Color("ffcb77"), Color("fff0d1")))
	quick_button.add_theme_stylebox_override("hover", _style(Color("ffe09b"), Color("ffffff")))
	quick_button.add_theme_stylebox_override("pressed", _style(Color("d99855"), Color("ff7d9c")))
	quick_button.tooltip_text = "Match with the next player searching. No phone verification required."
	quick_button.pressed.connect(func(): quick_fight_requested.emit())
	add_child(quick_button)
	var demo_button := Button.new()
	demo_button.name = "DemoFightButton"
	demo_button.text = "DEMO FIGHT"
	demo_button.position = Vector2(552, 414)
	demo_button.size = Vector2(354, 38)
	demo_button.add_theme_font_size_override("font_size", 15)
	demo_button.add_theme_stylebox_override("normal", _style(Color("17293a"), Color("78d9c6")))
	demo_button.add_theme_stylebox_override("pressed", _style(Color("31556a"), Color("fff0d1")))
	demo_button.pressed.connect(func(): demo_requested.emit())
	add_child(demo_button)
	_build_bottom_navigation()
	_refresh_chats()

func _refresh_chats() -> void:
	if not is_instance_valid(chat_list):
		return
	for child in chat_list.get_children():
		chat_list.remove_child(child)
		child.queue_free()
	var query := search_query.strip_edges().to_lower()
	var shown := 0
	for contact in recent_chats:
		var name := String(contact.get("name", "Contact"))
		if not query.is_empty() and not name.to_lower().contains(query):
			continue
		var row := Button.new()
		row.text = "%s\nLAST SIGNAL // READY" % name.to_upper()
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.custom_minimum_size = Vector2(338, 58)
		row.add_theme_font_size_override("font_size", 15)
		row.add_theme_stylebox_override("normal", _style(Color("10172a"), Color("313b61")))
		row.add_theme_stylebox_override("hover", _style(Color("17293a"), Color("78d9c6")))
		row.add_theme_stylebox_override("pressed", _style(Color("291d3a"), Color("ff7d9c")))
		row.pressed.connect(_open_chat.bind(contact))
		chat_list.add_child(row)
		shown += 1
	if shown == 0:
		var empty := Label.new()
		empty.text = "NO MATCHING SIGNALS" if not query.is_empty() else "NO CALLS LOGGED\nOPEN CONTACTS OR START QUICK FIGHT"
		empty.custom_minimum_size = Vector2(338, 100)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", Color("9cb5c6"))
		chat_list.add_child(empty)

func _build_bottom_navigation() -> void:
	var background := ColorRect.new()
	background.position = Vector2(0, NAV_TOP)
	background.size = Vector2(960, 64)
	background.color = Color("0b1421")
	add_child(background)
	var tabs := ["CHATS", "CONTACTS", "SETTINGS", "PROFILE"]
	for i in tabs.size():
		var tab_name: String = tabs[i]
		var button := Button.new()
		button.text = tab_name
		button.position = Vector2(240.0 * i, NAV_TOP)
		button.size = Vector2(240, 64)
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_color_override("font_color", Color("ffcb77") if tab_name == "CHATS" else Color("71849c"))
		button.add_theme_stylebox_override("normal", _style(Color("17152c") if tab_name == "CHATS" else Color("080a18"), Color("78d9c6") if tab_name == "CHATS" else Color("272548")))
		button.add_theme_stylebox_override("pressed", _style(Color("291d3a"), Color("ff7d9c")))
		if tab_name == "CONTACTS":
			button.pressed.connect(func(): call_friend_requested.emit())
		else:
			button.pressed.connect(_emit_tab.bind(tab_name.to_lower()))
		add_child(button)

func _open_chat(contact: Dictionary) -> void:
	contact_requested.emit(contact)

func _emit_tab(tab: String) -> void:
	tab_requested.emit(tab)

func _draw() -> void:
	draw_rect(Rect2(PANEL_LEFT + 6, 34, 398, 428), Color("9b3866aa"))
	draw_rect(Rect2(PANEL_LEFT, 28, 398, 434), Color("080a18ed"))
	for y in range(32, 460, 6):
		draw_line(Vector2(PANEL_LEFT + 2, y), Vector2(926, y), Color(0.22, 0.3, 0.55, 0.10), 1.0)
	for x in range(536, 928, 32):
		draw_line(Vector2(x, 30), Vector2(x, 460), Color(0.2, 0.75, 0.73, 0.035), 1.0)
	draw_rect(Rect2(PANEL_LEFT, 28, 398, 434), Color("78d9c6"), false, 2.0)
	draw_line(Vector2(552, 96), Vector2(906, 96), Color("ff7d9c"), 2.0)

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

func _style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(2)
	style.content_margin_left = 14
	style.content_margin_right = 14
	return style
