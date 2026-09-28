extends Node2D

const Fighter = preload("res://scripts/characters/ragdoll_character.gd")
const Backdrop = preload("res://scripts/systems/arena_backdrop_2d.gd")
const OnlineMatchType = preload("res://scripts/systems/online_match.gd")
const NakamaMatchType = preload("res://scripts/systems/nakama_match.gd")
const ContactsHomeType = preload("res://scripts/ui/contacts_home.gd")
const SoloHomeType = preload("res://scripts/ui/solo_home.gd")
const FighterLobbyType = preload("res://scripts/ui/fighter_lobby.gd")
const ContactActionPanelType = preload("res://scripts/ui/contact_action_panel.gd")
const FighterSelectType = preload("res://scripts/ui/fighter_select.gd")
const FighterRosterType = preload("res://scripts/characters/fighter_roster.gd")
const NetworkProtocolType = preload("res://scripts/systems/network_protocol.gd")
const ContactsImporterType = preload("res://scripts/systems/android_contacts.gd")
const MockMediaRoomType = preload("res://scripts/systems/mock_media_room.gd")
const SpriteAnimationPlayerType = preload("res://scripts/characters/sprite_animation_player.gd")
## Stand-in sprite set for fighters without their own, until the magician is playable.
const DEMO_SPRITE_SET := "magician"
var player: RagdollCharacter
var opponent: RagdollCharacter
var arena_backdrop: Node2D
var arena_hud_layer: CanvasLayer
var local_fighter: RagdollCharacter
var remote_fighter: RagdollCharacter
var online
var nakama_online: FaceoffNakamaMatch
var online_transport := "relay"
var online_active := false
var online_state_accumulator := 0.0
var meters: Array[ProgressBar] = []
var health_labels: Array[Label] = []
var fighter_name_labels: Array[Label] = []
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
var contacts_home: ContactsHome
var contacts_layer: CanvasLayer
var contacts_importer: AndroidContactsImporter
var solo_home: SoloHome
var solo_home_layer: CanvasLayer
var fighter_lobby: FighterLobby
var fighter_lobby_layer: CanvasLayer
var contact_action_panel: ContactActionPanel
var contact_action_layer: CanvasLayer
var fighter_select: FighterSelect
var fighter_select_layer: CanvasLayer
var media_room: MediaRoom
var navigation_portrait := false
var voice: FighterVoice
var mic_button: Button
var action_button: Button
var action_row: Control
var action_buttons: Array[Button] = []
var action_hint_labels: Array[Label] = []
var sprite_player: SpriteAnimationPlayer
var action_fighter: RagdollCharacter
var social: FaceoffSocialController
var accepted_match := ""
var arena_peer_count := 0
var assigned_slot := 0
var online_local_fighter_id := ""
var online_remote_fighter_id := ""
var online_selection_pending := false
var pending_invite_token := ""
var resolving_invite := false
var quick_fight_active := false
var quick_fight_pending := false
var contact_panel_return := "contacts"
var fighter_select_return := "solo"
var arena_return := "contacts"
var exit_confirmation: ConfirmationDialog

func _ready() -> void:
	get_tree().auto_accept_quit = false
	if _is_mobile_platform():
		DisplayServer.screen_set_orientation(DisplayServer.SCREEN_PORTRAIT)
		get_tree().root.content_scale_size = Vector2i(540, 960)
	arena_backdrop = Backdrop.new()
	add_child(arena_backdrop)
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
	media_room = MockMediaRoomType.new()
	media_room.name = "MediaRoom"
	add_child(media_room)
	_build_hud()
	_build_solo_home()
	_build_contacts_home()
	_build_contact_action_panel()
	_build_fighter_lobby()
	_build_fighter_select()
	_build_exit_confirmation()
	_build_contacts_importer()
	_build_social()
	_set_arena_visible(false)
	call_deferred("_apply_initial_navigation")

func _build_exit_confirmation() -> void:
	exit_confirmation = ConfirmationDialog.new()
	exit_confirmation.title = "Exit Faceoff?"
	exit_confirmation.dialog_text = "Are you sure you want to exit Faceoff?"
	exit_confirmation.ok_button_text = "EXIT"
	exit_confirmation.cancel_button_text = "STAY"
	exit_confirmation.exclusive = true
	exit_confirmation.confirmed.connect(_confirm_exit)
	add_child(exit_confirmation)

func _request_exit() -> void:
	if exit_confirmation.visible:
		exit_confirmation.hide()
		return
	exit_confirmation.popup_centered(Vector2i(420, 190))

func _confirm_exit() -> void:
	if nakama_online:
		nakama_online.shutdown()
	get_tree().quit()

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
	arena_hud_layer = layer
	layer.name = "ArenaHud"
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
		var name_label := _label(layer, "P%d  %s" % [i + 1, fighter.profile.display_name.to_upper()], Vector2(x, 42), 19)
		fighter_name_labels.append(name_label)
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
	action_hint_labels = [
		_label(layer, "DRAG TO STRIKE / FOREARMS + SHINS BLOCK / FASTER = STRONGER", Vector2(22, 487), 13, Color("ffcb77")),
		_label(layer, "TORSO up slowly: extend / swipe up: jump / sideways: walk    HIGH FOOT + WALK: hop", Vector2(22, 510), 11, Color("9cb5c6")),
	]
	action_button = Button.new()
	action_button.text = "ACTION!"
	action_button.position = Vector2(566, 489)
	action_button.size = Vector2(104, 38)
	action_button.pressed.connect(_toggle_action_row)
	layer.add_child(action_button)
	action_row = Control.new()
	action_row.position = Vector2.ZERO
	action_row.size = Vector2(960, 540)
	action_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	action_row.visible = false
	layer.add_child(action_row)
	var reset := Button.new()
	reset.text = "REMATCH [R]"
	reset.position = Vector2(787, 489)
	reset.size = Vector2(151, 38)
	reset.pressed.connect(_reset)
	layer.add_child(reset)
	var contacts_button := Button.new()
	contacts_button.text = "CONTACTS"
	contacts_button.position = Vector2(678, 489)
	contacts_button.size = Vector2(101, 38)
	contacts_button.pressed.connect(_show_contacts_home)
	layer.add_child(contacts_button)
	_label(layer, "A / D  walk     SPACE  guard     P  practice", Vector2(24, 151), 12, Color("b3ced5"))
	mic_button = Button.new()
	mic_button.text = "Mic on"
	mic_button.position = Vector2(790, 145)
	mic_button.size = Vector2(150, 40)
	mic_button.pressed.connect(func():
		if online_active:
			fighter_lobby.mic_enabled = not fighter_lobby.mic_enabled
			_on_lobby_microphone_toggled(fighter_lobby.mic_enabled)
			mic_button.text = "Mic on" if fighter_lobby.mic_enabled else "Mic off")
	layer.add_child(mic_button)
	var video_button := Button.new()
	video_button.icon = preload("res://assets/ui/video.svg")
	video_button.text = "Video"
	video_button.position = Vector2(660, 145)
	video_button.size = Vector2(120, 40)
	video_button.disabled = true
	video_button.tooltip_text = "Face video is not available yet"
	layer.add_child(video_button)
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
	online_status = _label(layer, "", Vector2(596, 190), 11, Color("9cb5c6"))
	for control in [online_url_edit, online_join_button, online_leave_button]:
		control.hide()
	layer.visible = false

func _build_contacts_home() -> void:
	contacts_layer = CanvasLayer.new()
	contacts_layer.name = "ContactsLayer"
	contacts_layer.layer = 5
	add_child(contacts_layer)
	contacts_home = ContactsHomeType.new()
	contacts_home.portrait_mode = true
	contacts_home.call_requested.connect(_on_contact_call_requested)
	contacts_home.message_requested.connect(_on_contact_message_requested)
	contacts_home.demo_requested.connect(_on_demo_requested)
	contacts_home.import_requested.connect(_on_import_contacts)
	contacts_home.invite_contact_requested.connect(_on_invite_contact_requested)
	contacts_home.tab_requested.connect(_on_navigation_tab_requested)
	contacts_home.recent_chats_updated.connect(_on_recent_chats_updated)
	contacts_home.contact_selected.connect(_on_contact_selected)
	contacts_layer.add_child(contacts_home)
	_set_fighter_input_enabled(false)

func _build_solo_home() -> void:
	solo_home_layer = CanvasLayer.new()
	solo_home_layer.name = "SoloHomeLayer"
	solo_home_layer.layer = 4
	add_child(solo_home_layer)
	solo_home = SoloHomeType.new()
	solo_home.call_friend_requested.connect(_on_call_friend_requested)
	solo_home.quick_fight_requested.connect(_on_quick_fight_requested)
	solo_home.demo_requested.connect(_on_demo_requested)
	solo_home.tab_requested.connect(_on_navigation_tab_requested)
	solo_home.contact_requested.connect(_on_recent_chat_requested)
	solo_home_layer.add_child(solo_home)
	solo_home_layer.hide()

func _build_contact_action_panel() -> void:
	contact_action_layer = CanvasLayer.new()
	contact_action_layer.name = "ContactActionLayer"
	contact_action_layer.layer = 6
	add_child(contact_action_layer)
	contact_action_panel = ContactActionPanelType.new()
	contact_action_panel.start_fight_requested.connect(_on_contact_start_fight_requested)
	contact_action_panel.back_requested.connect(_on_contact_action_back_requested)
	contact_action_layer.add_child(contact_action_panel)

func _build_fighter_lobby() -> void:
	fighter_lobby_layer = CanvasLayer.new()
	fighter_lobby_layer.name = "FighterLobbyLayer"
	fighter_lobby_layer.layer = 6
	add_child(fighter_lobby_layer)
	fighter_lobby = FighterLobbyType.new()
	fighter_lobby.portrait_mode = true
	fighter_lobby.accept_requested.connect(_on_lobby_accept_requested)
	fighter_lobby.decline_requested.connect(_on_lobby_decline_requested)
	fighter_lobby.cancel_requested.connect(_on_lobby_cancel_requested)
	fighter_lobby.microphone_toggled.connect(_on_lobby_microphone_toggled)
	fighter_lobby.camera_toggled.connect(_on_lobby_camera_toggled)
	fighter_lobby_layer.add_child(fighter_lobby)

func _build_fighter_select() -> void:
	fighter_select_layer = CanvasLayer.new()
	fighter_select_layer.name = "FighterSelectLayer"
	fighter_select_layer.layer = 7
	add_child(fighter_select_layer)
	fighter_select = FighterSelectType.new()
	fighter_select.selection_confirmed.connect(_on_fighter_selection_confirmed)
	fighter_select.online_selection_confirmed.connect(_on_online_fighter_selection_confirmed)
	fighter_select.cancel_requested.connect(_on_fighter_selection_cancelled)
	fighter_select_layer.add_child(fighter_select)

func _build_contacts_importer() -> void:
	contacts_importer = ContactsImporterType.new()
	contacts_importer.name = "AndroidContactsImporter"
	contacts_importer.contacts_ready.connect(_on_contacts_ready)
	contacts_importer.status_changed.connect(_on_contact_import_status)
	contacts_importer.invite_received.connect(_on_invite_received)
	add_child(contacts_importer)

func _apply_initial_navigation() -> void:
	_show_solo_home()
	if contacts_importer:
		contacts_importer.auto_import_if_permitted()

func _show_solo_home() -> void:
	if fighter_lobby:
		fighter_lobby.hide()
	if fighter_select:
		fighter_select.close_screen()
	if contacts_home:
		contacts_home.hide()
	if contact_action_panel:
		contact_action_panel.close_panel()
	_set_navigation_mode(false)
	_set_arena_visible(false)
	arena_backdrop.visible = true
	player.visible = true
	player.process_mode = Node.PROCESS_MODE_INHERIT
	opponent.visible = false
	opponent.process_mode = Node.PROCESS_MODE_DISABLED
	player.reset_character()
	player.network_remote = false
	player.combat_enabled = false
	player.input_enabled = true
	opponent.input_enabled = false
	if solo_home_layer:
		solo_home_layer.show()

func _on_call_friend_requested() -> void:
	_show_contacts_home()

func _on_quick_fight_requested() -> void:
	if quick_fight_active:
		return
	quick_fight_active = true
	quick_fight_pending = true
	accepted_match = ""
	assigned_slot = 0
	arena_peer_count = 0
	online_local_fighter_id = ""
	online_remote_fighter_id = ""
	online_selection_pending = false
	practice = false
	if contacts_home:
		contacts_home.hide()
	if contact_action_panel:
		contact_action_panel.close_panel()
	if solo_home_layer:
		solo_home_layer.hide()
	if fighter_select:
		fighter_select.close_screen()
	_set_navigation_mode(false)
	_set_arena_visible(false)
	_set_fighter_input_enabled(false)
	fighter_lobby.set_layout_mode(false)
	fighter_lobby.open_for_quick_fight()
	if nakama_online and nakama_online.service and nakama_online.service.connected:
		call_deferred("_begin_quick_matchmaking")
	elif nakama_online:
		fighter_lobby.set_connection_status("CONNECTING TO NAKAMA")
		nakama_online.connect_to_server(_configured_online_endpoint())

func _begin_quick_matchmaking() -> void:
	if not quick_fight_active or not quick_fight_pending or not nakama_online or not nakama_online.service.connected:
		return
	quick_fight_pending = false
	var started := await nakama_online.begin_quick_fight()
	if not started and quick_fight_active:
		fighter_lobby.set_connection_status("ERROR - COULD NOT START SEARCH")

func _on_navigation_tab_requested(tab: String) -> void:
	if tab == "chats":
		_show_solo_home()
	elif tab == "settings":
		_show_contacts_page("settings")
	elif tab == "profile":
		_show_contacts_page("profile")
	else:
		_show_contacts_home()

func _show_contacts_page(destination: String) -> void:
	_show_contacts_home()
	if destination == "settings":
		contacts_home.open_settings()
	elif destination == "profile":
		contacts_home.open_profile()

func _on_recent_chat_requested(contact: Dictionary) -> void:
	_show_contact_actions(contact, "chats")

func _on_recent_chats_updated(recent: Array[Dictionary]) -> void:
	if solo_home:
		solo_home.set_recent_chats(recent)

func _show_contacts_home() -> void:
	if online_active or online_selection_pending or quick_fight_active:
		if social and social.current_call.get("status", "") == "accepted":
			social.action("end")
		_leave_online()
	if fighter_lobby:
		fighter_lobby.hide()
	if fighter_select:
		fighter_select.close_screen()
	if contact_action_panel:
		contact_action_panel.close_panel()
	if contacts_home:
		contacts_home.set_layout_mode(true)
		contacts_home.open_friends()
		contacts_home.show()
	_set_navigation_mode(true)
	_set_arena_visible(false)
	_set_fighter_input_enabled(false)

func _on_contact_selected(contact: Dictionary) -> void:
	_show_contact_actions(contact, "contacts")

func _show_contact_actions(contact: Dictionary, return_page: String) -> void:
	contact_panel_return = return_page
	if contacts_home:
		contacts_home.hide()
	if solo_home_layer:
		solo_home_layer.hide()
	if fighter_lobby:
		fighter_lobby.hide()
	if fighter_select:
		fighter_select.close_screen()
	_set_navigation_mode(false)
	_set_arena_visible(false)
	arena_backdrop.visible = true
	player.visible = true
	player.process_mode = Node.PROCESS_MODE_INHERIT
	opponent.visible = false
	opponent.process_mode = Node.PROCESS_MODE_DISABLED
	player.network_remote = false
	player.combat_enabled = false
	player.input_enabled = true
	opponent.input_enabled = false
	contact_action_panel.open_for_contact(contact)

func _on_contact_start_fight_requested(contact: Dictionary) -> void:
	contact_action_panel.close_panel()
	await _on_contact_call_requested(contact)

func _on_contact_action_back_requested() -> void:
	if contact_panel_return == "chats":
		_show_solo_home()
	else:
		_show_contacts_home()

func _build_social() -> void:
	nakama_online = NakamaMatchType.new()
	add_child(nakama_online)
	_wire_online_transport(nakama_online)
	online = nakama_online
	online_transport = "nakama"
	social = FaceoffSocialController.new()
	add_child(social)
	social.contacts_updated.connect(_on_social_contacts_updated)
	social.profile_updated.connect(contacts_home.set_account)
	social.status_changed.connect(_social_status)
	social.message_received.connect(contacts_home.append_message)
	social.call_updated.connect(_on_call_updated)
	social.initialize(nakama_online.service)
	voice = FighterVoice.new()
	add_child(voice)
	voice.initialize(nakama_online.service)
	voice.microphone_status.connect(func(text): mic_button.text = text)
	contacts_home.phone_code_requested.connect(social.send_code)
	contacts_home.phone_verify_requested.connect(social.verify)
	contacts_home.send_requested.connect(social.send_message)
	contacts_home.invite_channel_requested.connect(_share_invite)
	nakama_online.service.arena_presence.connect(_on_arena_presence)
	if OS.get_environment("FACE_OFF_DISABLE_NETWORK") != "1":
		nakama_online.connect_to_server(_configured_online_endpoint())

func _share_invite(channel: String) -> void:
	contacts_importer.share_invite(channel)

func _on_invite_contact_requested(contact: Dictionary) -> void:
	if social and social.verified and social.service != null and social.service.connected:
		var result := await social.create_invite_link(contact)
		var token := String(result.get("token", ""))
		if not token.is_empty():
			contacts_importer.invite_contact(contact, ContactsImporterType.invite_url(token))
			return
	contacts_importer.invite_contact(contact)

func _on_invite_received(url: String) -> void:
	var token := _invite_token(url)
	if token.is_empty():
		return
	pending_invite_token = token
	if resolving_invite:
		return
	resolving_invite = true
	call_deferred("_resolve_incoming_invite")

func _resolve_incoming_invite() -> void:
	var token := pending_invite_token
	pending_invite_token = ""
	for _i in 80:
		if social != null and social.service != null and social.service.connected:
			break
		await get_tree().create_timer(0.25).timeout
	if social == null or social.service == null or not social.service.connected:
		if contacts_home:
			_show_contacts_home()
			contacts_home.set_import_status("Invite received. Connect to Faceoff to continue.", false)
		resolving_invite = false
		return
	var result := await social.resolve_invite_token(token)
	if result.has("error"):
		_show_contacts_home()
		resolving_invite = false
		return
	var number := String(result.get("phone", "")).strip_edges()
	if number.is_empty():
		_show_contacts_home()
		contacts_home.set_import_status("Invite link did not include a phone number.", false)
	else:
		var inviter := String(result.get("inviter_name", "Friend")).strip_edges()
		if inviter.is_empty():
			inviter = "Friend"
		_show_contacts_home()
		contacts_home.prefill_phone(number)
		contacts_home.set_import_status("Invite from %s ready. Verify this number to continue." % inviter, true)
	resolving_invite = false

func _invite_token(url: String) -> String:
	var prefix := "faceoff://invite/"
	var value := url.strip_edges()
	if not value.to_lower().begins_with(prefix):
		return ""
	var token := value.substr(prefix.length())
	var query := token.find("?")
	if query >= 0:
		token = token.substr(0, query)
	var fragment := token.find("#")
	if fragment >= 0:
		token = token.substr(0, fragment)
	return token if token.length() == 36 else ""

func _on_social_contacts_updated(updated_contacts: Array[Dictionary]) -> void:
	contacts_home.add_contacts(updated_contacts)
	if solo_home:
		solo_home.set_recent_chats(contacts_home.recent_contacts())

func _on_contact_call_requested(contact: Dictionary) -> void:
	contacts_home.mark_contact_used(contact)
	await social.invite(contact)

func _on_call_updated(call: Dictionary) -> void:
	var state := String(call.get("status", ""))
	if state in ["ringing", "accepted"] and social and social.service:
		var peer := String(call.get("caller", "")) if String(call.get("callee", "")) == social.service.user_id else String(call.get("callee", ""))
		contacts_home.mark_peer_used(peer)
	if state == "ringing":
		contacts_home.hide()
		if contact_action_panel:
			contact_action_panel.close_panel()
		_set_arena_visible(false)
		_set_fighter_input_enabled(false)
		_set_navigation_mode(true)
		var incoming: bool = call.get("callee") == social.service.user_id
		if fighter_lobby.contact.get("id") != call.id or not fighter_lobby.visible:
			fighter_lobby.open_for_call({"id": call.id, "name": call.get("contact_name", "Contact")}, incoming)
		fighter_lobby.set_connection_status("Incoming call" if incoming else "Waiting for your friend to accept")
	elif state == "accepted" and call.has("match_id") and accepted_match != call.match_id:
		accepted_match = call.match_id
		assigned_slot = 0
		arena_peer_count = 0
		online_local_fighter_id = ""
		online_remote_fighter_id = ""
		online_selection_pending = false
		practice = false
		_reset()
		_set_fighter_input_enabled(false)
		fighter_lobby.set_connecting()
		fighter_lobby.set_connection_status("Accepted. Connecting both players...")
		if not await social.service.join_invited_match(accepted_match):
			await social.action("end")
			_show_contacts_home()
		else:
			_open_online_fighter_select()
	elif state in ["declined", "cancelled", "expired", "ended"]:
		_leave_online()
		_show_contacts_home()
		contacts_home.set_import_status("Call " + state)

func _on_lobby_accept_requested() -> void:
	fighter_lobby.set_waiting(true)
	await social.action("accept")
	if social.current_call.get("status") == "ringing":
		fighter_lobby.set_waiting(false)

func _on_lobby_decline_requested() -> void:
	await social.action("decline")

func _on_lobby_cancel_requested() -> void:
	if quick_fight_active:
		_leave_online()
		_show_solo_home()
		return
	await social.action("end" if social.current_call.get("status") == "accepted" else "cancel")

func _on_arena_presence(count: int) -> void:
	arena_peer_count = count
	if count < 2:
		_set_fighter_input_enabled(false)
		if online_active:
			var was_quick := quick_fight_active
			if not was_quick:
				await social.action("end")
			_leave_online()
			if was_quick:
				_show_solo_home()
			else:
				_show_contacts_home()
	else:
		_open_online_fighter_select()
		_try_enter_arena()

func _try_enter_arena() -> void:
	if online_active:
		return
	if accepted_match.is_empty() or assigned_slot == 0 or arena_peer_count != 2:
		return
	if online_local_fighter_id.is_empty() or online_remote_fighter_id.is_empty():
		return
	arena_return = "solo" if quick_fight_active else "contacts"
	var local_profile := FighterRosterType.profile(online_local_fighter_id)
	var remote_profile := FighterRosterType.profile(online_remote_fighter_id)
	if assigned_slot == 1:
		player.set_profile(local_profile)
		opponent.set_profile(remote_profile)
	else:
		player.set_profile(remote_profile)
		opponent.set_profile(local_profile)
	fighter_name_labels[0].text = "P1  " + player.profile.display_name.to_upper()
	fighter_name_labels[1].text = "P2  " + opponent.profile.display_name.to_upper()
	_reset()
	online_active = true
	online_selection_pending = false
	if fighter_select:
		fighter_select.close_screen()
	fighter_lobby.hide()
	contacts_home.hide()
	_set_navigation_mode(false)
	_set_arena_visible(true)
	local_fighter = player if assigned_slot == 1 else opponent
	remote_fighter = opponent if assigned_slot == 1 else player
	for fighter in [player, opponent]:
		fighter.network_remote = fighter == remote_fighter
		fighter.input_enabled = fighter == local_fighter
		fighter.combat_enabled = true
	mic_button.text = "Mic on" if fighter_lobby.mic_enabled else "Mic off"
	status.text = "ONLINE - you control P%d" % assigned_slot
	voice.start(fighter_lobby.mic_enabled)
	if fighter_lobby.mic_enabled:
		contacts_importer.request_media_permission("android.permission.RECORD_AUDIO")

func _on_lobby_microphone_toggled(enabled: bool) -> void:
	if voice:
		voice.set_microphone(enabled)
	if media_room:
		media_room.publish_microphone(enabled)
	if enabled and online_active and _is_mobile_platform():
		if contacts_importer:
			contacts_importer.request_media_permission("android.permission.RECORD_AUDIO")
	if fighter_lobby:
		fighter_lobby.set_connection_status("MIC %s / READY TO CONNECT" % ("ON" if enabled else "OFF"))

func _on_lobby_camera_toggled(_enabled: bool) -> void:
	# Face video is unavailable. Never request camera permission.
	pass

func _on_import_contacts() -> void:
	if contacts_importer:
		contacts_home.set_import_status("Requesting phone Contacts permission")
		contacts_importer.request_import()

func _on_contacts_ready(imported: Array[Dictionary]) -> void:
	await social.import_contacts(imported)

func _on_contact_import_status(message: String, good: bool) -> void:
	if contacts_home:
		contacts_home.set_import_status(message, good)

func _is_mobile_platform() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios")

func _set_navigation_mode(portrait: bool) -> void:
	navigation_portrait = portrait
	if contacts_home:
		contacts_home.set_layout_mode(portrait)
	if fighter_lobby:
		fighter_lobby.set_layout_mode(portrait)
	get_tree().root.content_scale_size = Vector2i(540, 960) if portrait else Vector2i(960, 540)
	if not _is_mobile_platform():
		get_window().size = Vector2i(540, 960) if portrait else Vector2i(960, 540)
		return
	var orientation := DisplayServer.SCREEN_PORTRAIT if portrait else DisplayServer.SCREEN_LANDSCAPE
	DisplayServer.screen_set_orientation(orientation)
	get_tree().root.content_scale_size = Vector2i(540, 960) if portrait else Vector2i(960, 540)

func _sprite_set_for(fighter: RagdollCharacter) -> String:
	var own := String(fighter.profile.sprite_set) if fighter and fighter.profile else ""
	return own if not own.is_empty() else DEMO_SPRITE_SET

func _toggle_action_row() -> void:
	if action_row.visible:
		_close_action_row()
		return
	for button in action_buttons:
		button.queue_free()
	action_buttons.clear()
	var manifest := SpriteAnimationPlayerType.load_manifest(_sprite_set_for(local_fighter))
	var animations: Array = manifest.get("animations", [])
	if animations.is_empty():
		status.text = "NO ACTIONS FOR THIS FIGHTER YET"
		return
	for label in action_hint_labels:
		label.visible = false
	action_row.visible = true
	# Buttons fan out from ACTION! along the bottom bar, one per animation.
	var width := 104.0
	var gap := 10.0
	for index in animations.size():
		var entry: Dictionary = animations[index]
		var button := Button.new()
		button.text = String(entry.get("label", entry["state"]))
		button.size = Vector2(width, 38)
		button.position = action_button.position
		button.pressed.connect(_play_action.bind(String(entry["state"])))
		action_row.add_child(button)
		action_buttons.append(button)
		var target := Vector2(action_button.position.x - (index + 1) * (width + gap), action_button.position.y)
		var tween := create_tween()
		tween.tween_property(button, "position", target, 0.16 + index * 0.04).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _close_action_row() -> void:
	action_row.visible = false
	for label in action_hint_labels:
		label.visible = true

## Rest pose, then the sprite animation in place of the rig, then back to the
## rest pose so the player can take over again.
func _play_action(state: String) -> void:
	_close_action_row()
	var fighter := local_fighter
	if fighter == null or fighter.is_ko or fighter.is_fallen or (sprite_player and sprite_player.playing):
		return
	var manifest := SpriteAnimationPlayerType.load_manifest(_sprite_set_for(fighter))
	fighter.return_to_guard()
	if sprite_player == null:
		sprite_player = SpriteAnimationPlayerType.new()
		sprite_player.z_index = 5
		add_child(sprite_player)
		sprite_player.finished.connect(_on_action_finished)
	var height := _rest_height(fighter)
	if not sprite_player.play(manifest, state, fighter.global_position, height, fighter.facing_direction):
		status.text = "COULD NOT PLAY %s" % state.to_upper()
		return
	action_fighter = fighter
	fighter.input_enabled = false
	fighter.combat_enabled = false
	fighter.visible = false
	action_button.disabled = true

func _rest_height(fighter: RagdollCharacter) -> float:
	# Feet are the node origin; the head joint plus its radius is the top.
	var head: Vector2 = fighter.joints.get("head", Vector2(0, -260))
	return maxf(120.0, -head.y + 30.0)

func _cancel_action() -> void:
	if sprite_player and sprite_player.playing:
		sprite_player.stop()
		_on_action_finished("")
	if action_row and action_row.visible:
		_close_action_row()

func _on_action_finished(_state: String) -> void:
	action_button.disabled = false
	var fighter := action_fighter
	action_fighter = null
	if fighter == null:
		return
	fighter.visible = true
	fighter.input_enabled = true
	fighter.combat_enabled = true
	fighter.return_to_guard()

func _set_arena_visible(value: bool) -> void:
	if solo_home_layer:
		solo_home_layer.hide()
	if arena_backdrop:
		arena_backdrop.visible = value
	if player:
		player.visible = value
		player.process_mode = Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED
	if opponent:
		opponent.visible = value
		opponent.process_mode = Node.PROCESS_MODE_INHERIT if value else Node.PROCESS_MODE_DISABLED
	if arena_hud_layer:
		arena_hud_layer.visible = value
	if not value:
		_cancel_action()

func _on_contact_message_requested(contact: Dictionary) -> void:
	status.text = "CHAT WITH %s - CALL WHEN READY" % String(contact.get("name", "CONTACT")).to_upper()

func _on_demo_requested() -> void:
	# A demo is always local. Stop a pending or active Nakama transport first so
	# both fighters remain draggable on this device.
	if online_transport == "nakama" or online_active:
		_leave_online()
	_show_fighter_select()

func _show_fighter_select() -> void:
	fighter_select_return = "solo" if solo_home_layer and solo_home_layer.visible else "contacts"
	online_selection_pending = false
	if contacts_home:
		contacts_home.hide()
	if fighter_lobby:
		fighter_lobby.hide()
	if contact_action_panel:
		contact_action_panel.close_panel()
	_set_navigation_mode(false)
	_set_arena_visible(false)
	_set_fighter_input_enabled(false)
	if fighter_select:
		fighter_select.open_for_demo()

func _on_fighter_selection_cancelled() -> void:
	var was_quick := quick_fight_active
	if online_selection_pending:
		online_selection_pending = false
		if social and social.current_call.get("status", "") == "accepted":
			social.action("end")
		_leave_online()
	if was_quick or fighter_select_return == "solo":
		_show_solo_home()
	else:
		_show_contacts_home()

func _open_online_fighter_select() -> void:
	if online_active or accepted_match.is_empty() or assigned_slot == 0 or not fighter_select:
		return
	if online_selection_pending:
		return
	online_selection_pending = true
	if contacts_home:
		contacts_home.hide()
	if contact_action_panel:
		contact_action_panel.close_panel()
	if fighter_lobby:
		fighter_lobby.hide()
	_set_navigation_mode(false)
	_set_arena_visible(false)
	_set_fighter_input_enabled(false)
	fighter_select.open_for_online(assigned_slot)
	if not online_remote_fighter_id.is_empty():
		fighter_select.set_online_opponent_ready()

func _on_online_fighter_selection_confirmed(fighter_id: String) -> void:
	if not online_selection_pending or online_active or assigned_slot == 0:
		return
	if not NetworkProtocolType.is_valid_fighter(fighter_id):
		return
	online_local_fighter_id = fighter_id
	if fighter_select:
		fighter_select.set_online_waiting()
	if online and online.has_method("submit_fighter_selection"):
		online.submit_fighter_selection(fighter_id)
	_try_enter_arena()

func _on_fighter_selection_confirmed(player_id: String, opponent_id: String) -> void:
	arena_return = fighter_select_return
	player.set_profile(FighterRosterType.profile(player_id))
	opponent.set_profile(FighterRosterType.profile(opponent_id))
	fighter_name_labels[0].text = "P1  " + player.profile.display_name.to_upper()
	fighter_name_labels[1].text = "P2  " + opponent.profile.display_name.to_upper()
	practice = true
	_reset()
	if fighter_select:
		fighter_select.close_screen()
	if fighter_lobby:
		fighter_lobby.hide()
	if contacts_home:
		contacts_home.hide()
	for fighter in [player, opponent]:
		fighter.network_remote = false
		fighter.input_enabled = true
		fighter.combat_enabled = true
	_set_navigation_mode(false)
	_set_arena_visible(true)
	if status:
		status.text = "DEMO / %s VS %s" % [player.profile.display_name.to_upper(), opponent.profile.display_name.to_upper()]

func _set_fighter_input_enabled(enabled: bool) -> void:
	for fighter in [player, opponent]:
		fighter.input_enabled = enabled

func _configured_online_endpoint() -> String:
	var environment_value := OS.get_environment("FACE_OFF_ONLINE_ENDPOINT").strip_edges()
	if not environment_value.is_empty():
		return environment_value
	var project_value := String(ProjectSettings.get_setting("faceoff/online_endpoint", "")).strip_edges()
	if not project_value.is_empty():
		return project_value
	return "ws://127.0.0.1:9100"

func _physics_process(delta: float) -> void:
	if not arena_hud_layer.visible:
		return
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
			_end_round("DRAW" if player.health == opponent.health else (player.profile.display_name.to_upper() + " WINS" if player.health > opponent.health else opponent.profile.display_name.to_upper() + " WINS"))

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	if event.keycode == KEY_R:
		_reset()
	elif event.keycode == KEY_C:
		_show_contacts_home()
	elif event.keycode == KEY_ESCAPE:
		_back_navigation()
	elif event.keycode == KEY_SPACE and not round_over:
		for fighter in [player, opponent]:
			if fighter.input_enabled:
				fighter.return_to_guard()
	elif event.keycode == KEY_P and not online_active:
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
	if transport.has_signal("remote_fighter_selected"):
		transport.remote_fighter_selected.connect(_on_remote_fighter_selected)
	transport.connection_changed.connect(_on_online_connection_changed)
	if transport.has_signal("peer_count_changed"):
		transport.peer_count_changed.connect(_on_online_peer_count)

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

func _on_remote_fighter_selected(slot: int, fighter_id: String) -> void:
	if slot <= 0 or slot == assigned_slot or not NetworkProtocolType.is_valid_fighter(fighter_id):
		return
	online_remote_fighter_id = fighter_id
	if fighter_select and fighter_select.visible:
		fighter_select.set_online_opponent_ready()
	_try_enter_arena()

func _on_online_status(message: String) -> void:
	if online_status:
		online_status.text = message
	if fighter_lobby and fighter_lobby.visible:
		fighter_lobby.set_connection_status(message)
	if (message.contains("ERROR") or message.contains("DISCONNECTED")) and online_join_button:
		online_join_button.disabled = false

func _on_online_peer_count(count: int) -> void:
	if fighter_lobby and fighter_lobby.visible:
		fighter_lobby.set_peer_count(count)

func _on_online_connection_changed(connected: bool) -> void:
	if connected:
		if quick_fight_active and quick_fight_pending:
			call_deferred("_begin_quick_matchmaking")
		return
	if online_active or online_selection_pending or quick_fight_active or not accepted_match.is_empty() or (online_join_button and online_join_button.disabled):
		var was_quick := quick_fight_active
		_leave_online()
		if was_quick:
			_show_solo_home()
		else:
			_show_contacts_home()

func _on_online_slot_assigned(slot: int) -> void:
	assigned_slot = slot
	if quick_fight_active and accepted_match.is_empty() and nakama_online and nakama_online.service:
		accepted_match = nakama_online.service.match_id
		quick_fight_pending = false
	_open_online_fighter_select()
	_try_enter_arena()

func _join_online() -> void:
	contacts_home.set_import_status("Select a verified contact to start a call")
	_show_contacts_home()

func _leave_online() -> void:
	if voice:
		voice.stop()
	if nakama_online:
		if quick_fight_active or quick_fight_pending:
			nakama_online.cancel_quick_fight()
		nakama_online.service.leave_arena()
		nakama_online.player_slot = 0
	accepted_match = ""
	assigned_slot = 0
	arena_peer_count = 0
	online_local_fighter_id = ""
	online_remote_fighter_id = ""
	online_selection_pending = false
	online_active = false
	quick_fight_active = false
	quick_fight_pending = false
	online_state_accumulator = 0.0
	_set_fighter_input_enabled(false)


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
	if online_active:
		return
	round_seconds = 90
	round_over = false
	_cancel_action()
	player.reset_character()
	opponent.reset_character()
	player.combat_enabled = true
	opponent.combat_enabled = true
	timer.text = "--" if practice else "90"
	status.text = "PRACTICE / unlimited time, manual strikes" if practice else "FIGHT!  Drag hands, feet or knees."

	_set_fighter_input_enabled(practice and arena_hud_layer.visible)

func _social_status(message: String) -> void:
	contacts_home.set_import_status(message)
	if fighter_lobby.visible:
		fighter_lobby.set_connection_status(message)

func _back_navigation() -> void:
	if fighter_select and fighter_select.visible:
		_on_fighter_selection_cancelled()
	elif contact_action_panel and contact_action_panel.visible:
		_on_contact_action_back_requested()
	elif fighter_lobby.visible:
		if quick_fight_active:
			_on_lobby_cancel_requested()
		elif social.current_call.get("status") == "accepted":
			social.action("end")
		elif fighter_lobby.incoming:
			_on_lobby_decline_requested()
		else:
			_on_lobby_cancel_requested()
	elif arena_hud_layer.visible:
		if arena_return == "solo":
			_show_solo_home()
		else:
			_show_contacts_home()
	elif contacts_home.visible:
		if not contacts_home.go_back():
			_show_solo_home()
	elif solo_home_layer.visible:
		_request_exit()
	else:
		_show_solo_home()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back_navigation()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _is_mobile_platform():
			_request_exit()
		else:
			_confirm_exit()
