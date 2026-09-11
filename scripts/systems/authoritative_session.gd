class_name AuthoritativeSession
extends Node

signal snapshot_ready(snapshot: Dictionary)
signal session_event(event: Dictionary)

@export var tick_rate := 60
var server_tick := 0
var input_by_player := {}
var sequence_by_player := {}
var snapshot_accumulator := 0.0

func submit_input(player_id: String, packet: Dictionary) -> bool:
	if not FaceoffNetworkProtocol.validate_input(packet):
		return false
	var sequence := int(packet.get("sequence", -1))
	if sequence <= int(sequence_by_player.get(player_id, -1)):
		return false
	sequence_by_player[player_id] = sequence
	input_by_player[player_id] = packet
	return true

func _physics_process(delta: float) -> void:
	snapshot_accumulator += delta
	server_tick += 1
	if snapshot_accumulator >= 1.0 / float(tick_rate):
		snapshot_accumulator = 0.0
		snapshot_ready.emit(FaceoffNetworkProtocol.make_snapshot(server_tick, 0, [], []))
