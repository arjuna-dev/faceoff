class_name FaceoffOnlineMatch
extends Node
## Small WebSocket relay used for the first Android gameplay test.
## A headless Godot instance owns the two player slots and relays validated
## state and hit events. The local fighter remains responsive between packets.

signal status_changed(message: String)
signal connection_changed(connected: bool)
signal slot_assigned(slot: int)
signal remote_state_received(slot: int, state: Dictionary)
signal remote_hit_received(slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float)
signal peer_count_changed(count: int)

const DEFAULT_PORT := 9100
const STATE_SEND_INTERVAL := 1.0 / 20.0

var peer: WebSocketMultiplayerPeer
var is_server := false
var connected := false
var player_slot := 0
var server_url := ""
var state_accumulator := 0.0
var sequence := 0
var slot_by_peer: Dictionary = {}
var peer_by_slot: Dictionary = {}
var last_sequence_by_slot: Dictionary = {}

func start_server(port: int = DEFAULT_PORT) -> int:
	shutdown()
	peer = WebSocketMultiplayerPeer.new()
	var result := peer.create_server(port)
	if result != OK:
		status_changed.emit("SERVER ERROR %s" % error_string(result))
		return result
	is_server = true
	connected = true
	player_slot = 0
	multiplayer.multiplayer_peer = peer
	_bind_multiplayer_signals()
	status_changed.emit("SERVER LISTENING ws://0.0.0.0:%d" % port)
	connection_changed.emit(true)
	return OK

func connect_to_server(url: String) -> int:
	shutdown()
	server_url = url.strip_edges()
	if server_url.is_empty():
		server_url = "ws://127.0.0.1:%d" % DEFAULT_PORT
	peer = WebSocketMultiplayerPeer.new()
	var result := peer.create_client(server_url)
	if result != OK:
		status_changed.emit("CONNECT ERROR %s" % error_string(result))
		return result
	is_server = false
	connected = false
	player_slot = 0
	multiplayer.multiplayer_peer = peer
	_bind_multiplayer_signals()
	status_changed.emit("CONNECTING %s" % server_url)
	return OK

func shutdown() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peer = null
	is_server = false
	connected = false
	player_slot = 0
	state_accumulator = 0.0
	sequence = 0
	slot_by_peer.clear()
	peer_by_slot.clear()
	last_sequence_by_slot.clear()

func _process(delta: float) -> void:
	if is_server and connected:
		# The server's MultiplayerAPI polls the WebSocket peer from the scene tree.
		# This process hook keeps the node alive and lets status consumers observe it.
		return
	if not connected:
		return
	state_accumulator = maxf(0.0, state_accumulator - delta)

func _bind_multiplayer_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

func _on_connected_to_server() -> void:
	connected = true
	status_changed.emit("CONNECTED · waiting for player slot")
	connection_changed.emit(true)

func _on_server_disconnected() -> void:
	connected = false
	player_slot = 0
	status_changed.emit("SERVER DISCONNECTED")
	connection_changed.emit(false)

func _on_peer_connected(peer_id: int) -> void:
	if not is_server:
		return
	if slot_by_peer.size() >= FaceoffNetworkProtocol.MAX_PLAYERS:
		rpc_id(peer_id, "_server_full")
		return
	var slot := 1
	while peer_by_slot.has(slot):
		slot += 1
	slot_by_peer[peer_id] = slot
	peer_by_slot[slot] = peer_id
	rpc_id(peer_id, "_assign_slot", slot)
	peer_count_changed.emit(slot_by_peer.size())
	status_changed.emit("PLAYER %d CONNECTED (%d/%d)" % [slot, slot_by_peer.size(), FaceoffNetworkProtocol.MAX_PLAYERS])

func _on_peer_disconnected(peer_id: int) -> void:
	if not is_server:
		return
	var slot := int(slot_by_peer.get(peer_id, 0))
	slot_by_peer.erase(peer_id)
	if slot > 0:
		peer_by_slot.erase(slot)
		last_sequence_by_slot.erase(slot)
	peer_count_changed.emit(slot_by_peer.size())
	status_changed.emit("PLAYER %d DISCONNECTED" % slot if slot > 0 else "PEER DISCONNECTED")

func submit_state(state: Dictionary) -> void:
	if is_server or not connected or player_slot == 0 or state_accumulator > 0.0:
		return
	state_accumulator = STATE_SEND_INTERVAL
	sequence += 1
	var packet := state.duplicate(true)
	packet["v"] = FaceoffNetworkProtocol.VERSION
	packet["sequence"] = sequence
	if FaceoffNetworkProtocol.validate_state(packet):
		_submit_state.rpc_id(1, packet)

func submit_hit(target_slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool = false, impact_damage: float = -1.0, attack_limb: String = "") -> void:
	if is_server or not connected or player_slot == 0 or target_slot == player_slot:
		return
	var event := {"kind": "hit", "target_slot": target_slot, "damage": damage, "impact_damage": impact_damage if impact_damage >= 0.0 else damage, "blocked": blocked, "speed": speed, "region": region, "point": point, "attack_limb": attack_limb}
	if FaceoffNetworkProtocol.validate_hit(event):
		_submit_event.rpc_id(1, event)

@rpc("any_peer", "call_remote", "reliable")
func _submit_state(state: Dictionary) -> void:
	if not is_server:
		return
	var sender := multiplayer.get_remote_sender_id()
	var slot := int(slot_by_peer.get(sender, 0))
	var packet_sequence := int(state.get("sequence", -1))
	if slot == 0 or packet_sequence <= int(last_sequence_by_slot.get(slot, -1)) or not FaceoffNetworkProtocol.validate_state(state):
		return
	last_sequence_by_slot[slot] = packet_sequence
	var packet := state.duplicate(true)
	packet["slot"] = slot
	for destination in peer_by_slot.keys():
		var destination_id := int(peer_by_slot[destination])
		if destination_id != sender:
			_receive_state.rpc_id(destination_id, packet)

@rpc("authority", "call_remote", "reliable")
func _receive_state(state: Dictionary) -> void:
	if is_server:
		return
	var slot := int(state.get("slot", 0))
	if slot > 0 and slot != player_slot:
		remote_state_received.emit(slot, state)

@rpc("any_peer", "call_remote", "reliable")
func _submit_event(event: Dictionary) -> void:
	if not is_server or not FaceoffNetworkProtocol.validate_hit(event):
		return
	var sender := multiplayer.get_remote_sender_id()
	var sender_slot := int(slot_by_peer.get(sender, 0))
	var target_slot := int(event.get("target_slot", 0))
	if sender_slot == 0 or target_slot == sender_slot or not peer_by_slot.has(target_slot):
		return
	var packet := event.duplicate(true)
	packet["attacker_slot"] = sender_slot
	_receive_event.rpc_id(int(peer_by_slot[target_slot]), packet)

@rpc("authority", "call_remote", "reliable")
func _receive_event(event: Dictionary) -> void:
	if is_server or String(event.get("kind", "")) != "hit":
		return
	var point: Variant = event.get("point", Vector2.ZERO)
	remote_hit_received.emit(
		int(event.get("attacker_slot", 0)),
		float(event.get("damage", 0.0)),
		float(event.get("speed", 0.0)),
		String(event.get("region", "")),
		point if point is Vector2 else Vector2.ZERO,
		bool(event.get("blocked", false)),
		float(event.get("impact_damage", event.get("damage", 0.0)))
	)

@rpc("authority", "call_remote", "reliable")
func _assign_slot(slot: int) -> void:
	if is_server:
		return
	player_slot = slot
	status_changed.emit("ONLINE PLAYER %d/%d" % [slot, FaceoffNetworkProtocol.MAX_PLAYERS])
	slot_assigned.emit(slot)

@rpc("authority", "call_remote", "reliable")
func _server_full() -> void:
	status_changed.emit("SERVER FULL · TWO PLAYERS MAX")
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
