class_name NakamaSessionService
extends Node

## Client-side Nakama session and matchmaking service.
##
## FaceoffNakamaMatch owns the gameplay packet bridge while this node owns
## device authentication, realtime socket setup, and matchmaker lifecycle.
## The official Nakama Godot SDK is vendored under addons/.

signal notification_received(content: Dictionary)
signal voice_received(bytes: PackedByteArray)
signal arena_presence(count: int)
var social_only := false
var automatic_matchmaking := true

signal flow_changed(step: String)
signal status_changed(message: String)
signal session_ready(details: Dictionary)
signal matchmaker_ticket_ready(ticket: String)
signal match_found(details: Dictionary)
signal match_state_received(op_code: int, data: String)
signal match_presence_received(joins: Array, leaves: Array)
signal remote_state_received(slot: int, state: Dictionary)
signal remote_hit_received(slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float)
signal remote_fighter_selected(slot: int, fighter_id: String)
signal chat_message_received(message: Dictionary)
signal connection_changed(connected: bool)
signal network_error(message: String)

const FLOW_STEPS := ["startup", "authentication", "party", "mode", "communication", "matchmaking", "lobby", "game", "results"]
const MATCH_OP_STATE := 1
const MATCH_OP_HIT := 2
const MATCH_OP_ASSIGN := 3
const MATCH_OP_ROUND := 4
const MATCH_OP_FIGHTER := 7
const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 7350
const DEFAULT_SERVER_KEY := "devserverkey"

@export var default_host := DEFAULT_HOST
@export var default_port := DEFAULT_PORT
@export var server_key := DEFAULT_SERVER_KEY
@export var default_scheme := "http"

var current_step := "startup"
var session_id := ""
var display_name := ""
var user_id := ""
var session_token := ""
var refresh_token := ""
var match_id := ""
var matchmaker_ticket := ""
var player_slot := 0
var connected := false
var endpoint := ""

var client: NakamaClient
var session: NakamaSession
var socket: NakamaSocket
var _generation := 0
var _state_sequence := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var configured_server_key := String(ProjectSettings.get_setting("faceoff/online_server_key", "")).strip_edges()
	var override_key := OS.get_environment("FACE_OFF_ONLINE_SERVER_KEY")
	if not override_key.is_empty():
		configured_server_key = override_key
	if not configured_server_key.is_empty():
		server_key = configured_server_key

func configure(value: String) -> void:
	var raw := value.strip_edges()
	if raw.is_empty():
		raw = "nakama://%s:%d" % [default_host, default_port]
	var scheme := default_scheme
	for prefix in ["nakama://", "nakamas://", "http://", "https://", "ws://", "wss://"]:
		if raw.begins_with(prefix):
			scheme = "https" if prefix in ["nakamas://", "https://", "wss://"] else "http"
			raw = raw.trim_prefix(prefix)
			break
	var slash := raw.find("/")
	if slash >= 0:
		raw = raw.substr(0, slash)
	var host := raw
	var port := default_port
	var explicit_port := false
	if raw.begins_with("["):
		var close_bracket := raw.find("]")
		if close_bracket > 0:
			host = raw.substr(1, close_bracket - 1)
			var suffix := raw.substr(close_bracket + 1)
			if suffix.begins_with(":"):
				var parsed_ipv6_port := int(suffix.substr(1))
				if parsed_ipv6_port > 0:
					port = parsed_ipv6_port
					explicit_port = true
	else:
		var colon := raw.rfind(":")
		if colon > 0:
			host = raw.substr(0, colon)
			var parsed_port := int(raw.substr(colon + 1))
			if parsed_port > 0:
				port = parsed_port
				explicit_port = true
	if host.is_empty():
		host = default_host
	if not explicit_port and scheme == "https":
		port = 443
	default_host = host
	default_port = port
	default_scheme = scheme
	var endpoint_host := "[%s]" % host if host.contains(":") else host
	endpoint = "%s://%s:%d" % [scheme, endpoint_host, port]

func connect_to_server(value: String, device_id: String = "") -> void:
	shutdown()
	_generation += 1
	configure(value)
	var generation := _generation
	var resolved_device := device_id.strip_edges()
	if resolved_device.is_empty():
		resolved_device = _device_identifier()
	_authenticate_device_async(generation, resolved_device)

## Backwards-compatible entry point used by the session flow UI.
func start_device_auth(device_id: String = "") -> void:
	connect_to_server(endpoint, device_id)

func _device_identifier() -> String:
	var identifier := ""
	var sdk := _sdk_node()
	if sdk != null and sdk.has_method("get_device_id"):
		identifier = String(sdk.get_device_id()).strip_edges()
	if identifier.is_empty():
		identifier = OS.get_unique_id().strip_edges()
	if identifier.is_empty():
		identifier = "faceoff-%s" % Crypto.new().generate_random_bytes(12).hex_encode()
	return identifier

func _set_step(step: String) -> void:
	current_step = step
	flow_changed.emit(step)

func _sdk_node() -> Node:
	return get_node_or_null("/root/Nakama")

func _authenticate_device_async(generation: int, device_id: String) -> void:
	_set_step("authentication")
	var sdk := _sdk_node()
	if sdk == null:
		_fail("Nakama SDK autoload is missing")
		return
	client = sdk.create_client(server_key, default_host, default_port, default_scheme)
	client.auto_refresh = true
	var result: NakamaSession
	var saved := ConfigFile.new()
	if social_only and saved.load(SocialStorage.path("phone_session.cfg")) == OK and saved.get_value("session", "endpoint", "") == endpoint:
		var cached := NakamaSession.new(saved.get_value("session", "token", ""), false, saved.get_value("session", "refresh", ""))
		result = await client.session_refresh_async(cached)
	if result == null or result.is_exception():
		result = await client.authenticate_device_async(device_id, null, true)
	if generation != _generation:
		return
	if result == null or result.is_exception() or not result.is_valid():
		_fail(_exception_text(result, "device authentication failed"))
		return
	session = result
	if social_only and saved.get_value("session", "endpoint", "") == endpoint:
		saved.set_value("session", "token", session.token)
		saved.set_value("session", "refresh", session.refresh_token)
		saved.save(SocialStorage.path("phone_session.cfg"))
	session_token = session.token
	refresh_token = session.refresh_token
	session_id = session.user_id
	user_id = session.user_id
	display_name = session.username if not session.username.is_empty() else "Guest-%s" % device_id.left(6).to_upper()
	_set_step("lobby")
	status_changed.emit("AUTHENTICATED %s" % display_name)
	session_ready.emit({
		"session_id": session_id,
		"user_id": user_id,
		"display_name": display_name,
		"endpoint": endpoint,
		"session": session,
	})
	_connect_socket_async(generation)

func _connect_socket_async(generation: int) -> void:
	var sdk := _sdk_node()
	if sdk == null or client == null or session == null:
		_fail("Nakama session is not available")
		return
	socket = sdk.create_socket_from(client)
	socket.received_matchmaker_matched.connect(_on_matchmaker_matched)
	socket.received_match_state.connect(_on_match_state)
	socket.received_match_presence.connect(_on_match_presence)
	socket.received_notification.connect(_on_notification)
	socket.received_error.connect(_on_socket_error)
	socket.connection_error.connect(_on_socket_error)
	socket.closed.connect(_on_socket_closed)
	var result = await socket.connect_async(session, true)
	if generation != _generation:
		return
	if result == null or result.is_exception():
		_fail(_exception_text(result, "Nakama realtime connection failed"))
		return
	connected = true
	var should_matchmake := not social_only and automatic_matchmaking
	_set_step("matchmaking" if should_matchmake else "lobby")
	status_changed.emit("Searching for an opponent" if should_matchmake else "Connected")
	connection_changed.emit(true)
	if should_matchmake:
		_begin_matchmaking_async(generation)

func _begin_matchmaking_async(generation: int) -> void:
	if socket == null or not connected:
		return
	if not matchmaker_ticket.is_empty() or not match_id.is_empty():
		return
	var result = await socket.add_matchmaker_async(
		"+properties.game:faceoff +properties.protocol:1",
		2,
		2,
		{"game": "faceoff", "protocol": "1"},
		{}
	)
	if generation != _generation:
		return
	if result == null or result.is_exception():
		_fail(_exception_text(result, "matchmaking failed"))
		return
	matchmaker_ticket = String(result.ticket)
	status_changed.emit("MATCHMAKING TICKET %s" % matchmaker_ticket.left(8))
	matchmaker_ticket_ready.emit(matchmaker_ticket)

func begin_quick_fight() -> bool:
	if socket == null or not connected:
		_fail("Connect to Nakama before starting Quick Fight")
		return false
	if not match_id.is_empty() or not matchmaker_ticket.is_empty():
		return true
	_set_step("matchmaking")
	status_changed.emit("QUICK FIGHT - SEARCHING FOR PLAYER 2")
	await _begin_matchmaking_async(_generation)
	return not matchmaker_ticket.is_empty() or not match_id.is_empty()

func cancel_quick_fight() -> void:
	var old_ticket := matchmaker_ticket
	matchmaker_ticket = ""
	if socket != null and connected and not old_ticket.is_empty():
		await socket.remove_matchmaker_async(old_ticket)
	if match_id.is_empty():
		_set_step("lobby")
		status_changed.emit("QUICK FIGHT SEARCH CANCELLED")

func _on_matchmaker_matched(matched) -> void:
	matchmaker_ticket = ""
	_join_matched_async(matched)

func _join_matched_async(matched) -> void:
	if socket == null or not connected:
		return
	_set_step("game")
	status_changed.emit("OPPONENT FOUND - joining authoritative match")
	# Slot assignment can arrive before the join response. Bind its match first.
	match_id = String(matched.match_id)
	var result = await socket.join_matched_async(matched)
	if result == null or result.is_exception():
		_fail(_exception_text(result, "authoritative match join failed"))
		return
	match_id = String(result.match_id)
	match_found.emit({
		"match_id": match_id,
		"authoritative": bool(result.authoritative),
		"size": int(result.size),
		"match": result,
	})
	status_changed.emit("MATCH %s - waiting for server slot" % match_id.left(8))

func submit_state(state: Dictionary) -> void:
	if not connected or socket == null or match_id.is_empty():
		return
	_state_sequence += 1
	var packet: Dictionary = _encode_value(state)
	packet["v"] = FaceoffNetworkProtocol.VERSION
	packet["sequence"] = _state_sequence
	socket.send_match_state_async(match_id, MATCH_OP_STATE, JSON.stringify(packet))

func submit_fighter_selection(fighter_id: String) -> void:
	if not connected or socket == null or match_id.is_empty() or not FaceoffNetworkProtocol.is_valid_fighter(fighter_id):
		return
	socket.send_match_state_async(match_id, MATCH_OP_FIGHTER, JSON.stringify({
		"v": FaceoffNetworkProtocol.VERSION,
		"fighter_id": fighter_id,
	}))

func submit_hit(target_slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool = false, impact_damage: float = -1.0, attack_limb: String = "") -> void:
	if not connected or socket == null or match_id.is_empty() or target_slot == player_slot:
		return
	var full_damage := impact_damage if impact_damage >= 0.0 else damage
	var event := {
		"kind": "hit",
		"target_slot": target_slot,
		"damage": damage,
		"impact_damage": full_damage,
		"blocked": blocked,
		"speed": speed,
		"region": region,
		"point": point,
		"attack_limb": attack_limb,
	}
	socket.send_match_state_async(match_id, MATCH_OP_HIT, JSON.stringify(_encode_value(event)))

func create_or_join_party() -> void:
	_create_party_async()

func _create_party_async() -> void:
	_set_step("party")
	if socket == null or not connected:
		_fail("Nakama socket is not connected")
		return
	var result = await socket.create_party_async(true, 2)
	if result == null or result.is_exception():
		_fail(_exception_text(result, "party creation failed"))
		return
	status_changed.emit("PARTY READY %s" % String(result.party_id).left(8))

func select_mode(mode_id: String) -> void:
	_set_step("mode")
	if mode_id.is_empty():
		return
	status_changed.emit("MODE %s" % mode_id)

func set_communication_preferences(microphone: bool, camera: bool) -> void:
	_set_step("communication")
	status_changed.emit("MEDIA %s%s" % ["MIC " if microphone else "", "CAM" if camera else ""])

func send_session_chat(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	chat_message_received.emit({
		"sender": display_name,
		"text": text.left(240),
		"timestamp": Time.get_datetime_string_from_system(),
	})

func _on_match_state(message) -> void:
	if String(message.match_id) != match_id:
		return
	if int(message.op_code) == 6:
		voice_received.emit(Marshalls.base64_to_raw(String(message.data)))
		return
	var parsed = JSON.parse_string(String(message.data))
	if not parsed is Dictionary:
		return
	var payload: Dictionary = _decode_value(parsed)
	match_state_received.emit(int(message.op_code), String(message.data))
	if int(message.op_code) == MATCH_OP_ASSIGN:
		var assigned := int(payload.get("slot", 0))
		if assigned > 0:
			player_slot = assigned
			status_changed.emit("ONLINE PLAYER %d/2" % player_slot)
			match_found.emit({"match_id": match_id, "slot": player_slot, "authoritative": true})
	elif int(message.op_code) == 5:
		arena_presence.emit(int(payload.get("count", 0)))
	elif int(message.op_code) == MATCH_OP_FIGHTER:
		var slot := int(payload.get("slot", 0))
		var fighter_id := String(payload.get("fighter_id", ""))
		if slot > 0 and slot != player_slot and FaceoffNetworkProtocol.is_valid_fighter(fighter_id):
			remote_fighter_selected.emit(slot, fighter_id)
	elif int(message.op_code) == MATCH_OP_STATE:
		var slot := int(payload.get("slot", 0))
		if slot > 0 and slot != player_slot:
			remote_state_received.emit(slot, payload)
	elif int(message.op_code) == MATCH_OP_HIT:
		var hit_point: Variant = payload.get("point", Vector2.ZERO)
		var point: Vector2 = hit_point if hit_point is Vector2 else Vector2.ZERO
		remote_hit_received.emit(
			int(payload.get("attacker_slot", 0)),
			float(payload.get("damage", 0.0)),
			float(payload.get("speed", 0.0)),
			String(payload.get("region", "")),
			point,
			bool(payload.get("blocked", false)),
			float(payload.get("impact_damage", payload.get("damage", 0.0)))
		)

func _on_match_presence(event) -> void:
	match_presence_received.emit(event.joins, event.leaves)

func _on_socket_error(error) -> void:
	connected = false
	connection_changed.emit(false)
	_fail("Nakama socket error: %s" % str(error))

func _on_socket_closed() -> void:
	if not connected:
		return
	connected = false
	status_changed.emit("NAKAMA DISCONNECTED")
	connection_changed.emit(false)

func shutdown() -> void:
	_generation += 1
	var old_socket := socket
	var old_ticket := matchmaker_ticket
	var old_match := match_id
	connected = false
	player_slot = 0
	match_id = ""
	matchmaker_ticket = ""
	_state_sequence = 0
	if old_socket != null:
		if not old_ticket.is_empty():
			old_socket.remove_matchmaker_async(old_ticket)
		if not old_match.is_empty():
			old_socket.leave_match_async(old_match)
		old_socket.close()
	socket = null
	session = null
	client = null
	session_token = ""
	refresh_token = ""

func _fail(message: String) -> void:
	status_changed.emit("ERROR - " + message)
	network_error.emit(message)

func _exception_text(result, fallback: String) -> String:
	if result != null and result.is_exception():
		var exception = result.get_exception()
		if exception is NakamaException and not exception.message.is_empty():
			if exception.message.to_lower().contains("rpc function not found"):
				return "The server needs the phone-account update. Demo is available meanwhile."
			return exception.message
		return str(exception)
	return fallback

func _encode_value(value):
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value.keys():
			result[key] = _encode_value(value[key])
		return result
	if value is Array:
		var result_array: Array = []
		for item in value:
			result_array.append(_encode_value(item))
		return result_array
	return value

func _decode_value(value):
	if value is Dictionary:
		var x_value = value.get("x", null)
		var y_value = value.get("y", null)
		if value.size() == 2 and typeof(x_value) in [TYPE_FLOAT, TYPE_INT] and typeof(y_value) in [TYPE_FLOAT, TYPE_INT]:
			return Vector2(float(x_value), float(y_value))
		var result: Dictionary = {}
		for key in value.keys():
			result[key] = _decode_value(value[key])
		return result
	if value is Array:
		var result_array: Array = []
		for item in value:
			result_array.append(_decode_value(item))
		return result_array
	return value

func _on_notification(notification) -> void:
	var data = JSON.parse_string(String(notification.content))
	if data is Dictionary:
		notification_received.emit(data)

func social_rpc(id: String, data: Dictionary = {}) -> Dictionary:
	if client == null or session == null:
		return {"error": "Connecting to server. Please try again shortly."}
	var result = await client.rpc_async(session, id, JSON.stringify(data))
	if result == null or result.is_exception():
		return {"error": _exception_text(result, "Server request failed")}
	var parsed = JSON.parse_string(result.payload)
	return parsed if parsed is Dictionary else {"error": "Invalid server response"}

func verify_phone(number: String, code: String, player_name: String) -> Dictionary:
	if client == null:
		return {"error": "Connect to the server first"}
	var result = await client.authenticate_custom_async(number, null, true, {"code": code, "name": player_name})
	if result == null or result.is_exception():
		return {"error": _exception_text(result, "Phone verification failed")}
	if socket:
		connected = false
		socket.close()
	session = result
	user_id = session.user_id
	session_id = user_id
	var config := ConfigFile.new()
	config.set_value("session", "token", session.token)
	config.set_value("session", "refresh", session.refresh_token)
	config.set_value("session", "endpoint", endpoint)
	config.save(SocialStorage.path("phone_session.cfg"))
	await _connect_socket_async(_generation)
	return await social_rpc("faceoff_profile")

func join_invited_match(id: String) -> bool:
	if not connected or socket == null or id.is_empty():
		return false
	await leave_arena()
	match_id = id
	var result = await socket.join_match_async(id)
	if result == null or result.is_exception():
		match_id = ""
		_fail(_exception_text(result, "Could not join accepted call"))
		return false
	return true

func leave_arena() -> void:
	var old_id := match_id
	match_id = ""
	player_slot = 0
	_state_sequence = 0
	if socket and connected and not old_id.is_empty():
		await socket.leave_match_async(old_id)

func send_voice(bytes: PackedByteArray) -> void:
	if connected and socket and not match_id.is_empty() and bytes.size() == 1600:
		socket.send_match_state_async(match_id, 6, Marshalls.raw_to_base64(bytes))
