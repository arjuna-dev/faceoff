extends Node2D

const Fighter = preload("res://scripts/characters/ragdoll_character.gd")
const Backdrop = preload("res://scripts/systems/arena_backdrop_2d.gd")
const OnlineMatchType = preload("res://scripts/systems/online_match.gd")
const NakamaMatchType = preload("res://scripts/systems/nakama_match.gd")
var player: RagdollCharacter
var opponent: RagdollCharacter
var local_fighter: RagdollCharacter
var remote_fighter: RagdollCharacter
var online
var nakama_online: FaceoffNakamaMatch
var online_transport := "relay"
var online_active := false
var online_state_accumulator := 0.0
var meters: Array[ProgressBar] = []
var health_labels: Array[Label] = []
var status: Label
var timer: Label
var round_seconds := 90.0
var round_over := false
var practice := false
var balance_labels: Array[Label] = []
var online_url_edit: LineEdit
var online_join_button: Button
var online_leave_button: Button
var online_status: Label

func _ready() -> void:
	add_child(Backdrop.new())
	player = Fighter.new()
	player.position = Vector2(355, 459)
	add_child(player)
	player.setup(preload("res://data/batyr.tres"), 1, 1.0)
	opponent = Fighter.new()
	opponent.position = Vector2(605, 459)
	add_child(opponent)
	opponent.setup(preload("res://data/kiro.tres"), 2, -1.0)
	player.opponent = opponent
	opponent.opponent = player
	local_fighter = player
	remote_fighter = opponent
	for fighter in [player, opponent]:
		fighter.health_changed.connect(_health_changed)
		fighter.ko_reached.connect(_ko)
		fighter.hit_landed.connect(_hit)
		fighter.attack_landed.connect(_on_attack_landed)
	online = OnlineMatchType.new()
	online.name = "OnlineRelay"
	add_child(online)
	_wire_online_transport(online)
	_build_hud()

func _label(parent: Node, text: String, pos: Vector2, size: int, color: Color = Color("fff0d1")) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color("161425"))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var top := ColorRect.new()
	top.color = Color("111727")
	top.size = Vector2(960, 116)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(top)
	_label(layer, "FACE//OFF", Vector2(24, 9), 22, Color("ffcb77"))
	_label(layer, "MANUAL COMBAT / NIGHT MARKET", Vector2(610, 16), 14, Color("76d9ce"))
	for i in 2:
		var fighter: RagdollCharacter = player if i == 0 else opponent
		var x := 24.0 if i == 0 else 551.0
		_label(layer, "P%d  %s" % [i + 1, fighter.profile.display_name.to_upper()], Vector2(x, 42), 19)
		var meter := ProgressBar.new()
		meter.position = Vector2(x, 73)
		meter.size = Vector2(385, 20)
		meter.value = 100
		meter.show_percentage = false
		meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		meter.fill_mode = ProgressBar.FILL_BEGIN_TO_END if i == 0 else ProgressBar.FILL_END_TO_BEGIN
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color("49253c")
		bg.border_color = Color("eee0c0")
		bg.set_border_width_all(2)
		var fill := StyleBoxFlat.new()
		fill.bg_color = Color("ebbc62") if i == 0 else Color("78d9c6")
		meter.add_theme_stylebox_override("background", bg)
		meter.add_theme_stylebox_override("fill", fill)
		layer.add_child(meter)
		meters.append(meter)
		health_labels.append(_label(layer, "100 HP", Vector2(x + 315, 47), 14))
		balance_labels.append(_label(layer, "GUARD READY", Vector2(x, 97), 11, Color("9cb5c6")))
	timer = _label(layer, "90", Vector2(447, 44), 36, Color("ffcb77"))
	_label(layer, "ROUND 01", Vector2(439, 92), 12)
	status = _label(layer, "FIGHT!  Drag either fighter's hands or feet to strike.", Vector2(220, 124), 17)
	var bottom := ColorRect.new()
	bottom.position = Vector2(0, 480)
	bottom.size = Vector2(960, 60)
	bottom.color = Color("111727")
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bottom)
	_label(layer, "DRAG TO STRIKE / FOREARMS + SHINS BLOCK / FASTER = STRONGER", Vector2(22, 487), 13, Color("ffcb77"))
	_label(layer, "TORSO up slowly: extend / swipe up: jump / sideways: walk    HIGH FOOT + WALK: hop", Vector2(22, 510), 11, Color("9cb5c6"))
	var reset := Button.new()
	reset.text = "REMATCH [R]"
	reset.position = Vector2(787, 489)
	reset.size = Vector2(151, 38)
	reset.pressed.connect(_reset)
	layer.add_child(reset)
	_label(layer, "A / D  walk     SPACE  guard     P  practice", Vector2(24, 151), 12, Color("b3ced5"))
	_label(layer, "ONLINE TEST", Vector2(596, 151), 11, Color("ffcb77"))
	online_url_edit = LineEdit.new()
	online_url_edit.name = "OnlineServerUrl"
	online_url_edit.text = _configured_online_endpoint()
	online_url_edit.placeholder_text = "nakamas://HOST or nakama://HOST:7350"
	online_url_edit.position = Vector2(675, 145)
	online_url_edit.size = Vector2(180, 28)
	online_url_edit.add_theme_font_size_override("font_size", 11)
	online_url_edit.tooltip_text = "Use nakamas://HOST for production TLS, nakama://HOST:7350 for local Nakama, or ws://LAN_IP:9100 for the relay"
	layer.add_child(online_url_edit)
	online_join_button = Button.new()
	online_join_button.text = "JOIN"
	online_join_button.position = Vector2(861, 145)
	online_join_button.size = Vector2(42, 28)
	online_join_button.pressed.connect(_join_online)
	layer.add_child(online_join_button)
	online_leave_button = Button.new()
	online_leave_button.text = "OFF"
	online_leave_button.position = Vector2(907, 145)
	online_leave_button.size = Vector2(42, 28)
	online_leave_button.pressed.connect(_leave_online)
	layer.add_child(online_leave_button)
	online_status = _label(layer, "offline local", Vector2(596, 174), 11, Color("9cb5c6"))

func _configured_online_endpoint() -> String:
	var environment_value := OS.get_environment("FACE_OFF_ONLINE_ENDPOINT").strip_edges()
	if not environment_value.is_empty():
		return environment_value
	var project_value := String(ProjectSettings.get_setting("faceoff/online_endpoint", "")).strip_edges()
	if not project_value.is_empty():
		return project_value
	return "ws://127.0.0.1:9100"

func _physics_process(delta: float) -> void:
	for fighter in [player, opponent]:
		var label: Label = balance_labels[fighter.player_index - 1]
		if fighter.is_fallen:
			label.text = "DOWN / GETTING UP"
		elif fighter.is_jumping:
			label.text = "AIRBORNE"
		elif fighter.hopping:
			label.text = "HOP / %.0f%% FALL RISK PER STEP" % (fighter.fall_chance * 100)
		elif not fighter.guard_stagger.is_empty():
			label.text = "GUARD DISPLACED"
		else:
			label.text = "GUARD READY"
	if round_over:
		return
	if local_fighter:
		local_fighter.set_movement_intent(Vector2(Input.get_axis("move_left", "move_right"), 0))
	if online_active and online and local_fighter:
		online_state_accumulator += delta
		if online_state_accumulator >= (1.0 / 20.0):
			online_state_accumulator = 0.0
			online.submit_state(local_fighter.get_network_state())
	if not practice:
		round_seconds = maxf(0.0, round_seconds - delta)
		timer.text = "%02d" % ceili(round_seconds)
		if round_seconds == 0:
			_end_round("DRAW" if player.health == opponent.health else ("BATYR WINS" if player.health > opponent.health else "KIRO WINS"))

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if event.keycode == KEY_R:
		_reset()
	elif event.keycode == KEY_SPACE and not round_over:
		for fighter in [player, opponent]:
			fighter.return_to_guard()
	elif event.keycode == KEY_P:
		practice = not practice
		_reset()

func _health_changed(fighter: RagdollCharacter, value: float) -> void:
	var index := fighter.player_index - 1
	meters[index].value = value
	health_labels[index].text = "%d HP" % int(value)

func _on_attack_landed(attacker: RagdollCharacter, defender: RagdollCharacter, damage: float, speed: float, region: String, blocked: bool, impact_damage: float) -> void:
	if online_active and online and attacker == local_fighter and defender == remote_fighter:
		online.submit_hit(defender.player_index, damage, speed, region, defender.hit_point, blocked, impact_damage, attacker.last_attack_limb)

func _wire_online_transport(transport: Node) -> void:
	transport.status_changed.connect(_on_online_status)
	transport.slot_assigned.connect(_on_online_slot_assigned)
	transport.remote_state_received.connect(_on_remote_state)
	transport.remote_hit_received.connect(_on_remote_hit)
	transport.connection_changed.connect(_on_online_connection_changed)

func _on_remote_state(slot: int, state: Dictionary) -> void:
	if not online_active:
		return
	var fighter := player if slot == player.player_index else opponent
	if fighter == local_fighter:
		return
	fighter.apply_network_state(state)

func _on_remote_hit(attacker_slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float) -> void:
	if not online_active or not local_fighter:
		return
	local_fighter.last_hit_region = region
	local_fighter.last_hit_blocked = blocked
	local_fighter.last_hit_force = impact_damage
	local_fighter.hit_point = point
	if blocked and not region.is_empty():
		var attacker := player if attacker_slot == player.player_index else opponent
		var direction := (local_fighter.get_world_center() - attacker.get_world_center()).normalized()
		local_fighter._displace_guard(region, impact_damage, speed, direction)
	local_fighter.receive_hit(damage, Vector2.ZERO)

func _on_online_status(message: String) -> void:
	if online_status:
		online_status.text = message
	if (message.contains("ERROR") or message.contains("DISCONNECTED")) and online_join_button:
		online_join_button.disabled = false

func _on_online_connection_changed(connected: bool) -> void:
	if connected:
		return
	if online_active or (online_join_button and online_join_button.disabled):
		_leave_online()

func _on_online_slot_assigned(slot: int) -> void:
	online_active = true
	local_fighter = player if slot == player.player_index else opponent
	remote_fighter = opponent if local_fighter == player else player
	for fighter in [player, opponent]:
		fighter.network_remote = fighter == remote_fighter
		fighter.input_enabled = fighter == local_fighter
		fighter.combat_enabled = true
	if online_status:
		online_status.text = "P%d ONLINE · waiting for opponent" % slot
	if status:
		status.text = "ONLINE P%d · waiting for the second fighter" % slot

func _join_online() -> void:
	var url := online_url_edit.text.strip_edges() if online_url_edit else ""
	var use_nakama := url.begins_with("nakama://") or url.begins_with("nakamas://") or url.begins_with("http://") or url.begins_with("https://")
	if use_nakama and online_transport != "nakama":
		if online:
			online.shutdown()
		if not nakama_online:
			nakama_online = NakamaMatchType.new()
			nakama_online.name = "NakamaOnline"
			add_child(nakama_online)
			_wire_online_transport(nakama_online)
		online = nakama_online
		online_transport = "nakama"
	elif not use_nakama and online_transport != "relay":
		if online:
			online.shutdown()
		# The relay is created during _ready and remains the local fallback.
		online = get_node_or_null("OnlineRelay")
		online_transport = "relay"
	if not online:
		return
	online.connect_to_server(url)
	if online_join_button:
		online_join_button.disabled = true

func _leave_online() -> void:
	if online:
		online.shutdown()
	online_active = false
	local_fighter = player
	remote_fighter = opponent
	for fighter in [player, opponent]:
		fighter.network_remote = false
		fighter.input_enabled = true
		fighter.combat_enabled = true
	if online_join_button:
		online_join_button.disabled = false
	if online_status:
		online_status.text = "offline local"


func _hit(fighter: RagdollCharacter, damage: float) -> void:
	status.text = "%s %s  -%.1f HP" % [fighter.profile.display_name.to_upper(), "BLOCK" if fighter.last_hit_blocked else ("HEAD HIT" if fighter.last_hit_region == "head" else "HIT"), damage]

func _ko(fighter: RagdollCharacter) -> void:
	_end_round("KO!  %s WINS" % fighter.opponent.profile.display_name.to_upper())

func _end_round(message: String) -> void:
	round_over = true
	status.text = message + "   /   R TO REMATCH"
	for fighter in [player, opponent]:
		fighter.input_enabled = false
		fighter.combat_enabled = false
		fighter._clear_drags()
		fighter.dragging_limb = ""
		fighter.movement_intent = Vector2.ZERO

func _reset() -> void:
	round_seconds = 90
	round_over = false
	player.reset_character()
	opponent.reset_character()
	player.combat_enabled = true
	opponent.combat_enabled = true
	timer.text = "--" if practice else "90"
	status.text = "PRACTICE / unlimited time, manual strikes" if practice else "FIGHT!  Drag hands, feet or knees."
