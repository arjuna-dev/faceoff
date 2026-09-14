class_name FaceoffNetworkProtocol
extends RefCounted

const VERSION := 1
const TICK_RATE := 60
const MAX_PLAYERS := 2
const VALID_FIGHTERS := ["batyr", "kiro", "jade", "oculon"]

static func is_valid_fighter(fighter_id: String) -> bool:
	return fighter_id in VALID_FIGHTERS

static func make_input(sequence: int, tick: int, selected_limb: String, limb_target: Vector2, movement: Vector2, assist: bool, expression_id: String) -> Dictionary:
	return {
		"v": VERSION,
		"sequence": sequence,
		"client_tick": tick,
		"selected_limb": selected_limb,
		"limb_target": limb_target.clamp(Vector2(-1, -1), Vector2(1, 1)),
		"movement": movement.clamp(Vector2(-1, -1), Vector2(1, 1)),
		"assist": assist,
		"expression": expression_id,
	}

static func validate_input(packet: Dictionary) -> bool:
	if int(packet.get("v", -1)) != VERSION:
		return false
	var movement: Vector2 = packet.get("movement", Vector2.ZERO)
	var limb_target: Vector2 = packet.get("limb_target", Vector2.ZERO)
	return absf(movement.x) <= 1.01 and absf(movement.y) <= 1.01 and absf(limb_target.x) <= 1.01 and absf(limb_target.y) <= 1.01

static func validate_state(state: Dictionary) -> bool:
	if int(state.get("v", VERSION)) != VERSION:
		return false
	var position: Variant = state.get("position", null)
	var movement: Variant = state.get("movement", Vector2.ZERO)
	if not position is Vector2 or not movement is Vector2:
		return false
	if absf((position as Vector2).x) > 1600.0 or absf((position as Vector2).y) > 1000.0:
		return false
	if (movement as Vector2).length() > 1.01:
		return false
	var held_targets: Variant = state.get("held_targets", {})
	if not held_targets is Dictionary or (held_targets as Dictionary).size() > 8:
		return false
	for target in (held_targets as Dictionary).values():
		if not target is Vector2 or (target as Vector2).length() > 180.0:
			return false
	return float(state.get("health", 100.0)) >= 0.0 and float(state.get("health", 100.0)) <= 100.0

static func validate_hit(event: Dictionary) -> bool:
	if String(event.get("kind", "")) != "hit":
		return false
	var target_slot := int(event.get("target_slot", 0))
	if target_slot < 1 or target_slot > MAX_PLAYERS:
		return false
	var damage := float(event.get("damage", -1.0))
	var impact_damage := float(event.get("impact_damage", damage))
	var speed := float(event.get("speed", -1.0))
	var region := String(event.get("region", ""))
	var attack_limb := String(event.get("attack_limb", ""))
	if not attack_limb.is_empty() and attack_limb not in ["left_forearm", "right_forearm", "left_thigh", "right_thigh", "left_shin", "right_shin"]:
		return false
	return damage >= 0.0 and damage <= 32.0 and impact_damage >= 0.0 and impact_damage <= 32.0 and speed >= 0.0 and speed <= 3000.0 and not region.is_empty()

static func make_snapshot(server_tick: int, last_processed_sequence: int, bodies: Array[Dictionary], events: Array[Dictionary] = []) -> Dictionary:
	return {
		"v": VERSION,
		"server_tick": server_tick,
		"last_processed_sequence": last_processed_sequence,
		"bodies": bodies,
		"events": events,
	}
