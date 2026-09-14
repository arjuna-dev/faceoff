class_name FighterSelect
extends Control

signal selection_confirmed(player_id: String, opponent_id: String)
signal online_selection_confirmed(fighter_id: String)
signal cancel_requested

const RosterType = preload("res://scripts/characters/fighter_roster.gd")

var active_slot := 0
var player_id := "batyr"
var opponent_id := "kiro"
var p1_button: Button
var p2_button: Button
var active_label: Label
var start_button: Button
var title_label: Label
var subtitle_label: Label
var footer_label: Label
var card_buttons: Dictionary = {}
var card_badges: Dictionary = {}
var card_names: Dictionary = {}
var online_mode := false
var online_fighter_id := ""
var online_waiting := false

func _ready() -> void:
	size = Vector2(960, 540)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	z_index = 70
	_build()
	_refresh()
	hide()
	queue_redraw()

func open_for_demo() -> void:
	online_mode = false
	online_fighter_id = ""
	online_waiting = false
	active_slot = 0
	player_id = "batyr"
	opponent_id = "kiro"
	title_label.text = "SELECT YOUR FIGHTERS"
	subtitle_label.text = "DEMO ROOM / CHOOSE A FIGHTER FOR EACH SIDE"
	footer_label.text = "Cards auto-advance from P1 to P2. Tap the P1 or P2 tab to change sides."
	p2_button.show()
	for card in card_buttons.values():
		card.disabled = false
	_refresh()
	show()
	grab_focus()
	queue_redraw()

func open_for_online(_slot: int) -> void:
	online_mode = true
	online_fighter_id = ""
	online_waiting = false
	active_slot = 0
	player_id = ""
	opponent_id = ""
	title_label.text = "SELECT YOUR FIGHTER"
	subtitle_label.text = "ONLINE CALL / PICK ONE FIGHTER"
	footer_label.text = "Choose one fighter, press READY, then wait for the other player."
	p2_button.hide()
	for card in card_buttons.values():
		card.disabled = false
	_refresh()
	show()
	grab_focus()
	queue_redraw()

func set_online_waiting() -> void:
	if not online_mode:
		return
	online_waiting = true
	subtitle_label.text = "ONLINE CALL / WAITING FOR YOUR OPPONENT"
	_refresh()

func set_online_opponent_ready() -> void:
	if not online_mode or online_waiting:
		return
	subtitle_label.text = "ONLINE CALL / OPPONENT READY"

func close_screen() -> void:
	hide()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("080a18"))
	for y in range(0, int(size.y), 4):
		draw_rect(Rect2(0, y, size.x, 1), Color(0.2, 0.2, 0.38, 0.16))
	draw_rect(Rect2(18, 16, size.x - 36, size.y - 32), Color("272548"), false, 4.0)

func _build() -> void:
	title_label = _label("SELECT YOUR FIGHTERS", Vector2(30, 27), 28, Color("ffcb77"))
	title_label.size = Vector2(500, 36)
	subtitle_label = _label("DEMO ROOM / CHOOSE A FIGHTER FOR EACH SIDE", Vector2(32, 66), 11, Color("78d9c6"))
	p1_button = _button("P1 / BATYR", Vector2(600, 24), Vector2(150, 42), Color("211b3e"), Color("ffcb77"))
	p1_button.pressed.connect(func():
		active_slot = 0
		_refresh())
	p2_button = _button("P2 / KIRO", Vector2(766, 24), Vector2(150, 42), Color("211b3e"), Color("78d9c6"))
	p2_button.pressed.connect(func():
		active_slot = 1
		_refresh())
	active_label = _label("SELECT P1", Vector2(600, 72), 11, Color("f5edda"))
	active_label.size = Vector2(316, 20)
	active_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	for i in RosterType.IDS.size():
		var id: String = RosterType.IDS[i]
		var column := i % 2
		var row := i / 2
		var card := _button("", Vector2(30 + column * 458, 112 + row * 168), Vector2(442, 150), Color("11152b"), Color("3c456e"))
		card.name = "FighterCard_" + id
		card.pressed.connect(_on_card_pressed.bind(id))
		var head := TextureRect.new()
		head.position = Vector2(12, 16)
		head.size = Vector2(82, 108)
		head.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		head.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		head.texture = RosterType.head(id)
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(head)
		var name_label := _child_label(card, RosterType.profile(id).display_name.to_upper(), Vector2(108, 20), Vector2(170, 28), 19, Color("f5edda"))
		var tagline := _child_label(card, RosterType.profile(id).tagline, Vector2(108, 52), Vector2(168, 42), 12, Color("9ba7d0"))
		tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var swatch := ColorRect.new()
		swatch.position = Vector2(108, 105)
		swatch.size = Vector2(112, 7)
		swatch.color = RosterType.profile(id).primary_color
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(swatch)
		var badge := _child_label(card, "", Vector2(226, 109), Vector2(52, 22), 10, Color("ffcb77"))
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		card_buttons[id] = card
		card_badges[id] = badge
		card_names[id] = name_label
	start_button = _button("START DEMO FIGHT", Vector2(722, 466), Vector2(194, 42), Color("ffcb77"), Color("ffe7ab"))
	start_button.add_theme_color_override("font_color", Color("111225"))
	start_button.pressed.connect(func():
		if online_mode:
			online_selection_confirmed.emit(online_fighter_id)
		else:
			selection_confirmed.emit(player_id, opponent_id))
	var back := _button("BACK", Vector2(30, 466), Vector2(110, 42), Color("291d3a"), Color("ff7d9c"))
	back.pressed.connect(func(): cancel_requested.emit())
	footer_label = _label("Cards auto-advance from P1 to P2. Tap the P1 or P2 tab to change sides.", Vector2(154, 477), 11, Color("777eaa"))
	footer_label.size = Vector2(540, 20)

func _refresh() -> void:
	if not is_instance_valid(p1_button):
		return
	if online_mode:
		var selected_name := "CHOOSE"
		if not online_fighter_id.is_empty():
			selected_name = RosterType.profile(online_fighter_id).display_name.to_upper()
		p1_button.text = "YOU / " + selected_name
		p2_button.hide()
		active_label.text = "CHOOSE YOUR FIGHTER" if online_fighter_id.is_empty() else "READY TO SEND"
		active_label.add_theme_color_override("font_color", Color("ffcb77"))
		for id in RosterType.IDS:
			var online_card: Button = card_buttons[id]
			var online_border := Color("3c456e")
			var online_background := Color("11152b")
			var online_badge := ""
			if id == online_fighter_id:
				online_border = Color("ffcb77")
				online_background = Color("241d35")
				online_badge = "YOU"
			online_card.add_theme_stylebox_override("normal", _style(online_background, online_border))
			online_card.add_theme_stylebox_override("hover", _style(online_background.lightened(0.08), Color("ffffff")))
			online_card.add_theme_stylebox_override("pressed", _style(online_background.lightened(0.14), Color("ffffff")))
			online_card.disabled = online_waiting
			card_badges[id].text = online_badge
			card_badges[id].add_theme_color_override("font_color", online_border)
		start_button.text = "WAITING..." if online_waiting else "READY"
		start_button.disabled = online_waiting or online_fighter_id.is_empty()
		p1_button.add_theme_stylebox_override("normal", _style(Color("241d35"), Color("ffcb77")))
		queue_redraw()
		return
	var p1 := RosterType.profile(player_id)
	var p2 := RosterType.profile(opponent_id)
	p1_button.show()
	p2_button.show()
	p1_button.text = "P1 / " + p1.display_name.to_upper()
	p2_button.text = "P2 / " + p2.display_name.to_upper()
	active_label.text = "SELECT P1" if active_slot == 0 else "SELECT P2"
	active_label.add_theme_color_override("font_color", Color("ffcb77") if active_slot == 0 else Color("78d9c6"))
	for id in RosterType.IDS:
		var card: Button = card_buttons[id]
		card.disabled = false
		var border := Color("3c456e")
		var background := Color("11152b")
		var badge_text := ""
		if id == player_id:
			border = Color("ffcb77")
			background = Color("241d35")
			badge_text = "P1"
		if id == opponent_id:
			border = Color("78d9c6") if id != player_id else Color("f5edda")
			background = Color("17293a") if id != player_id else Color("2b263c")
			badge_text = "P2" if badge_text.is_empty() else "P1 + P2"
		card.add_theme_stylebox_override("normal", _style(background, border))
		card.add_theme_stylebox_override("hover", _style(background.lightened(0.08), Color("ffffff")))
		card.add_theme_stylebox_override("pressed", _style(background.lightened(0.14), Color("ffffff")))
		card_badges[id].text = badge_text
		card_badges[id].add_theme_color_override("font_color", border)
	start_button.disabled = player_id.is_empty() or opponent_id.is_empty()
	p1_button.add_theme_stylebox_override("normal", _style(Color("241d35") if active_slot == 0 else Color("211b3e"), Color("ffcb77")))
	p2_button.add_theme_stylebox_override("normal", _style(Color("17293a") if active_slot == 1 else Color("211b3e"), Color("78d9c6")))
	queue_redraw()

func _on_card_pressed(id: String) -> void:
	if online_mode:
		if online_waiting:
			return
		online_fighter_id = id
		player_id = id
		active_slot = 0
		_refresh()
		return
	if active_slot == 0:
		player_id = id
		active_slot = 1
	else:
		opponent_id = id
		active_slot = 0
	_refresh()

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

func _child_label(parent: Node, value: String, position_value: Vector2, size_value: Vector2, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.position = position_value
	label.size = size_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(value: String, position_value: Vector2, size_value: Vector2, background: Color, border: Color) -> Button:
	var button := Button.new()
	button.text = value
	button.position = position_value
	button.size = size_value
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_stylebox_override("normal", _style(background, border))
	button.add_theme_stylebox_override("hover", _style(background.lightened(0.08), Color("ffffff")))
	button.add_theme_stylebox_override("pressed", _style(background.lightened(0.14), Color("ffffff")))
	add_child(button)
	return button

func _style(background: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = background
	box.border_color = border
	box.set_border_width_all(2)
	box.set_corner_radius_all(10)
	box.content_margin_left = 12
	box.content_margin_right = 12
	return box
