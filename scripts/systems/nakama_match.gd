class_name FaceoffNakamaMatch
extends Node

## Faceoff transport backed by Nakama authentication, matchmaker, and an
## authoritative realtime match handler.

signal status_changed(message: String)
signal connection_changed(connected: bool)
signal slot_assigned(slot: int)
signal remote_state_received(slot: int, state: Dictionary)
signal remote_hit_received(slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float)
signal peer_count_changed(count: int)

const ServiceType = preload("res://scripts/systems/nakama_session_service.gd")

var service: NakamaSessionService
var connected := false
var player_slot := 0
var match_id := ""

func _ready() -> void:
	service = ServiceType.new()
	service.name = "NakamaSessionService"
	add_child(service)
	service.status_changed.connect(_on_status)
	service.connection_changed.connect(_on_connection_changed)
	service.match_found.connect(_on_match_found)
	service.remote_state_received.connect(_on_remote_state)
	service.remote_hit_received.connect(_on_remote_hit)
	service.match_presence_received.connect(_on_match_presence)

func connect_to_server(endpoint: String, device_id: String = "") -> void:
	if service:
		service.connect_to_server(endpoint, device_id)

func submit_state(state: Dictionary) -> void:
	if service:
		service.submit_state(state)

func submit_hit(target_slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool = false, impact_damage: float = -1.0, attack_limb: String = "") -> void:
	if service:
		service.submit_hit(target_slot, damage, speed, region, point, blocked, impact_damage, attack_limb)

func shutdown() -> void:
	if service:
		service.shutdown()
	connected = false
	player_slot = 0
	match_id = ""

func _on_status(message: String) -> void:
	status_changed.emit(message)

func _on_connection_changed(value: bool) -> void:
	connected = value
	connection_changed.emit(value)

func _on_match_found(details: Dictionary) -> void:
	match_id = String(details.get("match_id", match_id))
	var assigned := int(details.get("slot", 0))
	if assigned > 0 and assigned != player_slot:
		player_slot = assigned
		slot_assigned.emit(player_slot)

func _on_remote_state(slot: int, state: Dictionary) -> void:
	remote_state_received.emit(slot, state)

func _on_remote_hit(slot: int, damage: float, speed: float, region: String, point: Vector2, blocked: bool, impact_damage: float) -> void:
	remote_hit_received.emit(slot, damage, speed, region, point, blocked, impact_damage)

func _on_match_presence(joins: Array, leaves: Array) -> void:
	peer_count_changed.emit(maxi(0, 1 + joins.size() - leaves.size()))
