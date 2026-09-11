class_name NakamaSessionService
extends Node

## Client-side Nakama session and matchmaking service.
##
## FaceoffNakamaMatch owns the gameplay packet bridge while this node owns
## device authentication, realtime socket setup, and matchmaker lifecycle.
## The official Nakama Godot SDK is vendored under addons/.

signal flow_changed(step: String)
signal status_changed(message: String)
signal session_ready(details: Dictionary)
signal matchmaker_ticket_ready(ticket: String)
signal match_found(details: Dictionary)
signal match_state_received(op_code: int, data: String)
signal match_presence_received(joins: Array, leaves: Array)
signal remote_state_received(slot: int, state: Dictionary)
signal remote_hit_received(slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float)
signal chat_message_received(message: Dictionary)
signal connection_changed(connected: bool)
signal network_error(message: String)

const FLOW_STEPS := ["startup", "authentication", "party", "mode", "communication", "matchmaking", "lobby", "game", "results"]
const MATCH_OP_STATE := 1
const MATCH_OP_HIT := 2
const MATCH_OP_ASSIGN := 3
const MATCH_OP_ROUND := 4
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
	var result: NakamaSession = await client.authenticate_device_async(device_id, null, true)
	if generation != _generation:
		return
	if result == null or result.is_exception() or not result.is_valid():
		_fail(_exception_text(result, "device authentication failed"))
		return
	session = result
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
	_set_step("matchmaking")
	status_changed.emit("NAKAMA CONNECTED - searching for an opponent")
	connection_changed.emit(true)
	_begin_matchmaking_async(generation)

func _begin_matchmaking_async(generation: int) -> void:
	if socket == null or not connected:
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

func _on_matchmaker_matched(matched) -> void:
	_join_matched_async(matched)

func _join_matched_async(matched) -> void:
	if socket == null or not connected:
		return
	_set_step("game")
	status_changed.emit("OPPONENT FOUND - joining authoritative match")
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
