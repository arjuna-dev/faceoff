class_name RagdollCharacter
extends Node2D
## Deterministic, connected fighter rig. No physics bodies or joints.

signal limb_selected(character: RagdollCharacter, limb_name: String)
signal health_changed(character: RagdollCharacter, health: float)
signal ko_reached(character: RagdollCharacter)
signal hit_landed(character: RagdollCharacter, damage: float)
signal attack_landed(attacker: RagdollCharacter, defender: RagdollCharacter, damage: float, speed: float, region: String, blocked: bool, impact_damage: float)
signal expression_changed(character: RagdollCharacter, expression_id: String)
signal pose_changed(character: RagdollCharacter, pose_name: String)

const ArcadeSkinType = preload("res://scripts/characters/arcade_skin.gd")

const LIMBS: Array[String] = ["torso", "head", "left_forearm", "right_forearm", "left_thigh", "right_thigh", "left_shin", "right_shin"]
const ATTACK_LIMBS: Array[String] = ["left_forearm", "right_forearm", "left_thigh", "right_thigh", "left_shin", "right_shin"]
const MAX_SIMULTANEOUS_DRAGS := 5
static var pointer_owners: Dictionary = {}
var profile: CharacterProfile
var player_index := 1
var facing_direction := 1.0
var health := 100.0
var is_ko := false
var combat_enabled := true
var input_enabled := true
var opponent: RagdollCharacter
var movement_intent := Vector2.ZERO
var selected_limb_index := 0
var bodies: Dictionary = {}
var active_drags: Dictionary = {}
var held_targets: Dictionary = {}
var dragging_limb := ""
var crouch := 0.0
var lean := 0.0
var head_drop := 0.0
var walk_phase := 0.0
var animation_time := 0.0
var was_walking := false
var hit_flash := 0.0
var hit_point := Vector2.ZERO
var hit_damage := 0
var spawn_position := Vector2.ZERO
var joints: Dictionary = {}
var pose_name := "guard"
var is_fallen := false
var fall_time := 0.0
var fall_progress := 0.0
var unsupported_time := 0.0
const FALL_DURATION := 1.8
const PIXEL_SIZE := 1.0
const LEG_LENGTH := 64.0
const FOOT_REACH := 127.0
const HOP_THRESHOLD := 52.0
const HOP_MOVE_SPEED := 320.0
const HOP_RISK_CUTOFF := 16.0
const HOP_RISK_FULL_CLEARANCE := 92.0
const GUARD_CHIP_DAMAGE := 1.0
var stance_height := 0.0
var jump_height := 0.0
var jump_velocity := Vector2.ZERO
var is_jumping := false
var jump_cooldown := 0.0
var hopping := false
var hop_side := ""
var hop_clock := 0.0
var hop_steps := 0
var fall_chance := 0.05
var balance_random := RandomNumberGenerator.new()
var guard_strain: Dictionary = {}
var guard_stagger: Dictionary = {}
var last_hit_blocked := false
var last_hit_region := ""
var last_hit_force := 0.0
var last_attack_limb := ""
var body_stroke: Dictionary = {}
var body_motion_active := false
var torso_up_travel := 0.0
var network_remote := false


func return_to_guard() -> void:
	if is_fallen or is_ko:
		return
	held_targets.clear()
	_clear_drags()
	dragging_limb = ""
	crouch = 0.0
	lean = 0.0
	head_drop = 0.0
	stance_height = 0.0
	_solve_pose()

func _update_support(delta: float) -> void:
	if is_ko or is_jumping or hopping:
		unsupported_time = 0.0
		return
	if is_fallen:
		fall_time += delta
		if fall_time < 0.4:
			fall_progress = smoothstep(0.0, 0.4, fall_time)
		elif fall_time < 1.15:
			fall_progress = 1.0
		else:
			# Unfold to the guard pose during the get-up animation.
			held_targets.clear()
			fall_progress = 1.0 - smoothstep(1.15, FALL_DURATION, fall_time)
		if fall_time >= FALL_DURATION:
			is_fallen = false
			fall_progress = 0.0
			unsupported_time = 0.0
			pose_name = "guard"
		return
	# The authored walk always has a support foot. Only actual lifted feet count.
	var both_lifted: bool = joints.left_foot.y < -22.0 and joints.right_foot.y < -22.0
	unsupported_time = unsupported_time + delta if both_lifted else 0.0
	if unsupported_time >= 0.12:
		_start_fall()

func _start_fall() -> void:
	is_fallen = true
	is_jumping = false
	hopping = false
	jump_height = 0.0
	jump_velocity = Vector2.ZERO
	fall_time = 0.0
	pose_name = "fallen"
	_clear_drags()
	dragging_limb = ""
	body_stroke.clear()
	movement_intent = Vector2.ZERO
	was_walking = false
	crouch = 0.0
	lean = 0.0
	head_drop = 0.0
	stance_height = 0.0
	pose_changed.emit(self, pose_name)

func _start_jump(velocity: Vector2) -> void:
	if is_jumping or is_fallen or is_ko or jump_cooldown > 0.0:
		return
	is_jumping = true
	hopping = false
	jump_velocity = Vector2(clampf(velocity.x * 0.42, -260.0, 260.0), clampf(-velocity.y * 0.65, 360.0, 470.0))
	jump_height = 1.0
	jump_cooldown = 0.35
	unsupported_time = 0.0
	crouch = 0.0
	stance_height = 0.0
	body_motion_active = true
	pose_name = "jump"
	pose_changed.emit(self, pose_name)

func get_fall_chance() -> float:
	if hop_side.is_empty():
		return 0.0
	# A toe that is only just clear of the floor should be almost as stable as a
	# planted foot. Risk ramps in only after a meaningful clearance, then eases
	# toward a cap so a long, controlled leg extension remains playable.
	var foot_y := float(joints[hop_side + "_foot"].y)
	var clearance := maxf(0.0, -foot_y - HOP_THRESHOLD)
	var clearance_ratio := clampf((clearance - HOP_RISK_CUTOFF) / HOP_RISK_FULL_CLEARANCE, 0.0, 1.0)
	# Keep a neutral one-foot hop close to the original 1-in-20 fall rate even
	# at full clearance. Extra instability only matters after the foot is truly
	# lifted, so a toe that is barely above the floor remains nearly risk-free.
	var clearance_risk := pow(clearance_ratio, 1.65) * 0.045
	var risk_gate := clampf(clearance / 20.0, 0.0, 1.0)
	var extension := 0.0
	for side in ["left", "right"]:
		if held_targets.has(side + "_forearm"):
			extension += maxf(0.0, Vector2(held_targets[side + "_forearm"]).length() - 65.0) / 22.0
	var extension_risk := minf(extension * 0.009, 0.024) * risk_gate
	var lean_ratio := clampf(absf(lean) / 58.0, 0.0, 1.0)
	var lean_risk := pow(lean_ratio, 2.0) * 0.045 * risk_gate
	var strain := 0.0
	for value in guard_strain.values():
		strain += float(value)
	var strain_risk := minf(strain / 800.0, 0.03) * risk_gate
	var near_floor_bias := lerpf(0.0, 0.005, clampf(clearance / 20.0, 0.0, 1.0))
	return clampf(near_floor_bias + clearance_risk + extension_risk + lean_risk + strain_risk, 0.0, 0.20)

func _update_hopping(delta: float, drive: float) -> void:
	var raised: Array[String] = []
	for side in ["left", "right"]:
		if (held_targets.has(side + "_shin") or held_targets.has(side + "_thigh")) and joints[side + "_foot"].y < -HOP_THRESHOLD:
			raised.append(side)
	var should_hop := raised.size() == 1 and absf(drive) > 0.08 and not is_jumping
	if not should_hop:
		hopping = false
		hop_side = ""
		hop_clock = 0.0
		return
	hopping = true
	hop_side = raised[0]
	hop_clock += delta
	fall_chance = get_fall_chance()
	if hop_clock >= 0.42:
		hop_clock -= 0.42
		hop_steps += 1
		# Exactly one independent balance roll per completed hopping step.
		if balance_random.randf() < fall_chance:
			_start_fall()

func _pose_transform() -> Transform2D:
	var amount := 1.0 if is_ko else fall_progress
	var result := Transform2D(-PI * 0.5 * facing_direction * amount, Vector2.ZERO)
	if amount > 0.0:
		var hip: Vector2 = joints.hip * Vector2(facing_direction, 1)
		result.origin = Vector2(hip.x, lerpf(hip.y, -30.0, amount)) - result.basis_xform(hip)
		var lowest := -INF
		for joint_name in joints:
			var transformed: Vector2 = result * (Vector2(joints[joint_name]) * Vector2(facing_direction, 1))
			var radius := 8.0 if String(joint_name).ends_with("foot") else (27.0 if joint_name == "head" else 20.0)
			lowest = maxf(lowest, transformed.y + radius)
		if lowest > 0.0:
			result.origin.y -= lowest
	if amount == 0.0:
		result.origin.y -= jump_height
		if hopping:
			result.origin.y -= sin(hop_clock / 0.42 * PI) * 19.0
	return result


func setup(p_profile: CharacterProfile, index: int, facing: float, _lane: int = 0) -> void:
	balance_random.randomize()
	profile = p_profile
	player_index = index
	facing_direction = facing
	spawn_position = position
	for limb in LIMBS:
		var marker := Node2D.new()
		marker.name = limb
		add_child(marker)
		bodies[limb] = marker
	_solve_pose()

func _update_guard_recovery(delta: float) -> void:
	for limb in guard_strain.keys():
		guard_strain[limb] = maxf(0.0, float(guard_strain[limb]) - delta * 9.0)
		if guard_strain[limb] <= 0.0:
			guard_strain.erase(limb)
	for limb in guard_stagger.keys():
		guard_stagger[limb] = float(guard_stagger[limb]) - delta
		if guard_stagger[limb] <= 0.0:
			guard_stagger.erase(limb)

func _physics_process(delta: float) -> void:
	if not profile:
		return
	animation_time += delta
	hit_flash = maxf(0.0, hit_flash - delta)
	_update_guard_recovery(delta)
	if network_remote:
		_solve_pose()
		queue_redraw()
		return
	jump_cooldown = maxf(0.0, jump_cooldown - delta)
	_update_support(delta)
	if is_fallen or is_ko:
		_solve_pose()
		queue_redraw()
		return
	var before := _attack_positions()
	var drive := movement_intent.x if input_enabled else 0.0
	var torso_control := false
	for drag in active_drags.values():
		if drag.limb == "torso":
			torso_control = true
			drive = clampf((drag.target.x - get_world_center().x - drag.offset.x) / 55.0, -1.0, 1.0)
	_update_hopping(delta, drive)
	if is_fallen:
		_solve_pose()
		return
	was_walking = absf(drive) > 0.08 and not is_jumping and not hopping
	var horizontal := drive * (HOP_MOVE_SPEED if hopping else 145.0) * delta
	if is_jumping:
		jump_height += jump_velocity.y * delta
		jump_velocity.y -= 1150.0 * delta
		horizontal = jump_velocity.x * delta
		if jump_height <= 0.0:
			jump_height = 0.0
			is_jumping = false
			jump_velocity = Vector2.ZERO
			body_motion_active = false
			pose_name = "guard"
	var next_x := clampf(position.x + horizontal, 90.0, 870.0)
	if opponent and absf(next_x - opponent.position.x) < 76.0:
		next_x = opponent.position.x + signf(position.x - opponent.position.x) * 76.0
	position.x = next_x
	if was_walking:
		walk_phase += delta * 9.0
		for limb in ["left_thigh", "right_thigh", "left_shin", "right_shin"]:
			if not _is_limb_dragged(limb):
				held_targets.erase(limb)
	_solve_pose()
	if (torso_control and absf(drive) > 0.08) or (is_jumping and body_motion_active):
		_resolve_motion(before, delta, body_stroke, ATTACK_LIMBS)
	queue_redraw()

func _solve_pose() -> void:
	var bob := floorf(sin(animation_time * 5.0) * 1.5) * 2.0
	var hip := Vector2(-6, -105 + crouch * 0.65 + bob - stance_height)
	var shoulder := Vector2(lean * 0.7, -172 + crouch + bob + absf(lean) * 0.25 - stance_height)
	var head := shoulder + Vector2(8 + lean * 0.3, -30 + head_drop)
	joints = {"hip": hip, "shoulder": shoulder, "head": head}
	for side in ["left", "right"]:
		var front: bool = side == "right"
		var step := sin(walk_phase + (0.0 if front else PI)) if was_walking else 0.0
		var foot := Vector2(((36.0 if front else -43.0) * (1.0 - stance_height / 32.0 * 0.7)) + step * 22.0, -5.0 - maxf(0.0, cos(walk_phase + (0.0 if front else PI))) * 14.0 if was_walking else -5.0)
		var leg_root := hip + Vector2(10 if front else -11, 0)
		if held_targets.has(side + "_shin"):
			foot = leg_root + Vector2(held_targets[side + "_shin"])
		foot = leg_root + (foot - leg_root).limit_length(FOOT_REACH)
		var knee := _bend(leg_root, foot, LEG_LENGTH, LEG_LENGTH, 1.0)
		if held_targets.has(side + "_thigh"):
			knee = leg_root + Vector2(held_targets[side + "_thigh"]).limit_length(LEG_LENGTH - 1.0)
			# Keep the lower leg behind the raised knee, never hyperextended.
			var thigh_direction := (knee - leg_root).normalized()
			foot = knee + thigh_direction.rotated(0.85) * LEG_LENGTH
		# Authored landing pose folds the knees up while the back settles on the floor.
		var landing := 1.0 if is_ko else fall_progress
		if landing > 0.0:
			foot = foot.lerp(hip + Vector2(18 if front else 8, 80), landing)
			knee = knee.lerp(hip + Vector2(44 if front else 26, 43), landing)
		joints[side + "_hip"] = leg_root
		joints[side + "_knee"] = knee
		joints[side + "_foot"] = foot
		var arm_root := shoulder + Vector2(14 if front else -23, 6 if front else 0) if profile.visual_style == "batyr" else shoulder + Vector2(7 if front else -14, 6 if front else 0)
		var guard_beat := floorf(sin(animation_time * 5.0 + (0.0 if front else 0.8)) * 1.5) * 2.0
		var hand := shoulder + Vector2((50 if front else 22) + guard_beat, (-9 if front else -27) - guard_beat)
		if held_targets.has(side + "_forearm"):
			hand = arm_root + Vector2(held_targets[side + "_forearm"]).limit_length(87)
		hand += Vector2(lean * 0.28, head_drop * 0.22)
		var elbow := _bend(arm_root, hand, 45, 44, -1.0)
		joints[side + "_shoulder"] = arm_root
		joints[side + "_elbow"] = elbow
		joints[side + "_hand"] = hand
		_set_marker(side + "_forearm", hand)
		_set_marker(side + "_thigh", knee)
		_set_marker(side + "_shin", foot)
	_set_marker("head", head)
	_set_marker("torso", hip.lerp(shoulder, 0.55))
	var transform_pose := _pose_transform()
	for marker in bodies.values():
		marker.position = transform_pose * marker.position

func _bend(a: Vector2, b: Vector2, l1: float, l2: float, direction: float) -> Vector2:
	var diff := b - a
	var distance := clampf(diff.length(), 1.0, l1 + l2 - 0.1)
	var along := (l1 * l1 - l2 * l2 + distance * distance) / (2.0 * distance)
	return a + diff.normalized() * along + diff.normalized().orthogonal() * sqrt(maxf(0, l1 * l1 - along * along)) * direction

func _set_marker(limb: String, point: Vector2) -> void:
	bodies[limb].position = Vector2(point.x * facing_direction, point.y)

func _input(event: InputEvent) -> void:
	if not input_enabled or is_ko or is_fallen:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start_pointer_drag_at(get_global_mouse_position(), -1)
		else:
			_end_pointer_drag(-1)
	elif event is InputEventMouseMotion:
		_update_pointer_drag(-1, get_global_mouse_position())
	elif event is InputEventScreenTouch:
		if event.pressed:
			_start_pointer_drag_at(get_canvas_transform().affine_inverse() * event.position, event.index)
		else:
			_end_pointer_drag(event.index)
	elif event is InputEventScreenDrag:
		_update_pointer_drag(event.index, get_canvas_transform().affine_inverse() * event.position)

func _pick_limb_at(point: Vector2) -> String:
	var best := ""
	var score := INF
	for limb in LIMBS:
		var distance: float = bodies[limb].global_position.distance_to(point)
		var radius := 26.0 if limb == "torso" else 20.0
		if distance < radius and distance < score:
			best = limb
			score = distance
	return best

func _start_pointer_drag_at(point: Vector2, id: int = -1) -> void:
	if pointer_owners.has(id):
		var owner_node: Object = pointer_owners[id].get_ref()
		if owner_node != null and owner_node != self:
			return
	if is_ko or is_fallen or not input_enabled or active_drags.has(id) or active_drags.size() >= MAX_SIMULTANEOUS_DRAGS:
		return
	var limb := _pick_limb_at(point)
	if limb.is_empty() or _is_limb_dragged(limb):
		return
	pointer_owners[id] = weakref(self)
	selected_limb_index = LIMBS.find(limb)
	active_drags[id] = {"limb": limb, "start": point, "target": point, "offset": point - bodies[limb].global_position, "crouch": crouch, "lean": lean, "head_drop": head_drop, "travel": 0.0, "spent": false, "direction": Vector2.ZERO, "last_time": Time.get_ticks_usec(), "stance_height": stance_height, "up_travel": 0.0, "strikes": {}}
	if limb == "torso":
		body_stroke.clear()
	dragging_limb = limb
	limb_selected.emit(self, selected_limb_name())

func _update_pointer_drag(id: int, point: Vector2, sample_seconds: float = -1.0) -> void:
	if not active_drags.has(id) or is_ko or is_fallen or not input_enabled:
		return
	var drag: Dictionary = active_drags[id]
	var now := Time.get_ticks_usec()
	var elapsed := clampf(sample_seconds if sample_seconds > 0 else (now - int(drag.last_time)) / 1000000.0, 0.008, 0.25)
	drag.last_time = now
	var motion: Vector2 = point - drag.target
	var velocity := motion / elapsed
	var before := _attack_positions()
	drag.target = point
	if drag.limb == "head":
		lean = clampf(drag.lean + (point.x - drag.start.x) * facing_direction, -58.0, 62.0)
		head_drop = clampf(drag.head_drop + (point.y - drag.start.y) * 0.35, -6.0, 16.0)
	elif drag.limb == "torso":
		var vertical: float = point.y - drag.start.y
		crouch = clampf(drag.crouch + vertical, 0.0, 62.0)
		stance_height = clampf(drag.stance_height - vertical, 0.0, 20.0)
		drag.up_travel = drag.up_travel - motion.y if motion.y < 0.0 else 0.0
		if drag.up_travel >= 32.0 and velocity.y < -480.0:
			_start_jump(velocity)
			drag.up_travel = 0.0
	elif drag.limb in ATTACK_LIMBS:
		if guard_stagger.has(drag.limb):
			active_drags[id] = drag
			return
		var local := _pose_transform().affine_inverse() * to_local(point - drag.offset)
		local.x *= facing_direction
		var side: String = "left" if drag.limb.begins_with("left") else "right"
		var anchor: Vector2 = joints[side + ("_shoulder" if drag.limb.ends_with("forearm") else "_hip")]
		if drag.limb.ends_with("thigh"):
			held_targets.erase(side + "_shin")
		elif drag.limb.ends_with("shin"):
			held_targets.erase(side + "_thigh")
		held_targets[drag.limb] = (local - anchor).limit_length(87 if drag.limb.ends_with("forearm") else (LEG_LENGTH - 1.0 if drag.limb.ends_with("thigh") else FOOT_REACH))
	_solve_pose()
	var limbs: Array[String] = []
	if drag.limb in ATTACK_LIMBS:
		limbs.append(String(drag.limb))
	else:
		limbs.assign(ATTACK_LIMBS)
	_resolve_motion(before, elapsed, drag.strikes, limbs)
	if active_drags.has(id):
		active_drags[id] = drag
	queue_redraw()

func _attack_positions() -> Dictionary:
	var result: Dictionary = {}
	for limb in ATTACK_LIMBS:
		result[limb] = bodies[limb].global_position
	return result

func _resolve_motion(before: Dictionary, elapsed: float, strokes: Dictionary, limbs: Array[String]) -> void:
	for limb in limbs:
		var after: Vector2 = bodies[limb].global_position
		var movement: Vector2 = after - Vector2(before[limb])
		if movement.length() < 0.5:
			continue
		var stroke: Dictionary = strokes.get(limb, {"travel": 0.0, "spent": false, "direction": Vector2.ZERO, "speed": 0.0})
		if movement.length() > 2.0 and movement.normalized().dot(stroke.direction) < -0.45:
			stroke.travel = 0.0
			stroke.spent = false
		stroke.direction = movement.normalized()
		stroke.travel += movement.length()
		stroke.speed = movement.length() / maxf(0.008, elapsed)
		if not stroke.spent and stroke.travel >= 18.0 and stroke.speed >= 55.0:
			if _try_hit(before[limb], after, limb, stroke.speed):
				stroke.spent = true
		strokes[limb] = stroke

func damage_for_speed(limb: String, speed: float) -> float:
	var base := 10.0 if limb.ends_with("forearm") else 14.0
	return base * lerpf(0.55, 1.8, clampf((speed - 60.0) / 1100.0, 0.0, 1.0))

func _sweep_circle(from: Vector2, to: Vector2, center: Vector2, radius: float) -> float:
	var offset := from - center
	if offset.length_squared() <= radius * radius:
		return 0.0
	var path := to - from
	var a := path.length_squared()
	if a < 0.001:
		return INF
	var b := 2.0 * offset.dot(path)
	var c := offset.length_squared() - radius * radius
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return INF
	var time := (-b - sqrt(discriminant)) / (2.0 * a)
	return time if time >= 0.0 and time <= 1.0 else INF

func _joint_world(key: String) -> Vector2:
	return to_global(_pose_transform() * (Vector2(joints[key]) * Vector2(facing_direction, 1)))

func _try_hit(from: Vector2, to: Vector2, limb: String, speed: float = 450.0) -> bool:
	if is_fallen or is_ko or not combat_enabled or not opponent or opponent.is_ko:
		return false
	var first := INF
	var region := ""
	var blocked := false
	# Resolve the earliest contact, so a shield behind the face cannot block a head hit.
	for target in ["head", "torso"]:
		var time := _sweep_circle(from, to, opponent.bodies[target].global_position, 25.0 if target == "head" else 31.0)
		if time < first:
			first = time
			region = target
	for side in ["left", "right"]:
		for lower in ["forearm", "shin"]:
			var shield: String = side + "_" + lower
			if opponent.guard_stagger.has(shield) or opponent.is_fallen:
				continue
			var a := opponent._joint_world(side + ("_elbow" if lower == "forearm" else "_knee"))
			var b := opponent._joint_world(side + ("_hand" if lower == "forearm" else "_foot"))
			var samples := ceili(a.distance_to(b) / 5.0)
			for i in samples + 1:
				var time := _sweep_circle(from, to, a.lerp(b, float(i) / maxf(1, samples)), 18.0)
				if time < first:
					first = time
					region = shield
					blocked = true
	if region.is_empty():
		return false
	var damage := damage_for_speed(limb, speed)
	if region == "head":
		damage *= 1.15
	var impact_damage := damage
	last_attack_limb = limb
	opponent.last_hit_blocked = blocked
	opponent.last_hit_region = region
	opponent.last_hit_force = damage
	opponent.hit_point = opponent.to_local(from.lerp(to, first))
	if blocked:
		opponent._displace_guard(region, damage, speed, (to - from).normalized())
		# A shield absorbs the strike. It still communicates contact, but costs
		# exactly one point from the defender's 100 point bar.
		damage = GUARD_CHIP_DAMAGE
	if opponent.network_remote:
		opponent._show_remote_hit(region, damage)
		attack_landed.emit(self, opponent, damage, speed, region, blocked, impact_damage)
	else:
		opponent.receive_hit(damage, Vector2.ZERO)
	return true

func _displace_guard(limb: String, damage: float, speed: float, direction: Vector2) -> void:
	guard_strain[limb] = float(guard_strain.get(limb, 0.0)) + damage
	if speed < 850.0 and guard_strain[limb] < 32.0:
		return
	var side := "left" if limb.begins_with("left") else "right"
	var anchor: Vector2 = joints[side + ("_shoulder" if limb.ends_with("forearm") else "_hip")]
	var endpoint: Vector2 = joints[side + ("_hand" if limb.ends_with("forearm") else "_foot")]
	var local_direction := direction * Vector2(facing_direction, 1)
	held_targets[limb] = (endpoint - anchor + local_direction * 35.0 + Vector2(0, 18)).limit_length(87 if limb.ends_with("forearm") else FOOT_REACH)
	if limb.ends_with("shin"):
		held_targets.erase(side + "_thigh")
	guard_stagger[limb] = 0.45
	for id in active_drags.keys():
		if active_drags[id].limb == limb:
			_end_pointer_drag(id)
	_solve_pose()

func _end_pointer_drag(id: int) -> void:
	if pointer_owners.has(id) and pointer_owners[id].get_ref() == self:
		pointer_owners.erase(id)
	active_drags.erase(id)
	dragging_limb = "" if active_drags.is_empty() else String(active_drags.values()[0].limb)

func _is_limb_dragged(limb: String) -> bool:
	for drag in active_drags.values():
		if drag.limb == limb:
			return true
	return false

func receive_hit(damage: float, _impulse: Vector2) -> void:
	if is_ko:
		return
	health = maxf(0.0, health - maxf(0.0, damage))
	hit_flash = 0.28
	hit_damage = int(damage)
	health_changed.emit(self, health)
	hit_landed.emit(self, damage)
	if health == 0.0:
		is_ko = true
		_clear_drags()
		dragging_limb = ""
		ko_reached.emit(self)

func _show_remote_hit(region: String, damage: float) -> void:
	last_hit_blocked = region.ends_with("forearm") or region.ends_with("shin")
	last_hit_region = region
	hit_damage = int(damage)
	hit_flash = 0.28

func reset_character() -> void:
	stance_height = 0.0
	jump_height = 0.0
	jump_velocity = Vector2.ZERO
	is_jumping = false
	jump_cooldown = 0.0
	hopping = false
	hop_side = ""
	hop_clock = 0.0
	hop_steps = 0
	fall_chance = 0.05
	guard_strain.clear()
	guard_stagger.clear()
	last_hit_blocked = false
	last_hit_region = ""
	last_hit_force = 0.0
	last_attack_limb = ""
	body_stroke.clear()
	body_motion_active = false
	position = spawn_position
	health = 100.0
	is_ko = false
	is_fallen = false
	fall_time = 0.0
	fall_progress = 0.0
	unsupported_time = 0.0
	input_enabled = true
	_clear_drags()
	held_targets.clear()
	dragging_limb = ""
	crouch = 0.0
	lean = 0.0
	head_drop = 0.0
	hit_flash = 0.0
	movement_intent = Vector2.ZERO
	_solve_pose()
	health_changed.emit(self, health)

func set_movement_intent(value: Vector2) -> void:
	movement_intent = value.limit_length(1.0)

func get_network_state() -> Dictionary:
	return {
		"v": FaceoffNetworkProtocol.VERSION,
		"position": position,
		"movement": movement_intent,
		"health": health,
		"is_ko": is_ko,
		"is_fallen": is_fallen,
		"is_jumping": is_jumping,
		"jump_height": jump_height,
		"hopping": hopping,
		"hop_side": hop_side,
		"hop_steps": hop_steps,
		"walk_phase": walk_phase,
		"was_walking": was_walking,
		"crouch": crouch,
		"lean": lean,
		"head_drop": head_drop,
		"stance_height": stance_height,
		"held_targets": held_targets.duplicate(true),
		"last_hit_blocked": last_hit_blocked,
		"last_hit_region": last_hit_region,
		"hit_point": hit_point,
	}

func apply_network_state(state: Dictionary) -> void:
	if not FaceoffNetworkProtocol.validate_state(state):
		return
	var was_ko := is_ko
	var previous_health := health
	network_remote = true
	position = state.get("position", position)
	health = clampf(float(state.get("health", health)), 0.0, 100.0)
	if not is_equal_approx(previous_health, health):
		health_changed.emit(self, health)
	is_fallen = bool(state.get("is_fallen", false))
	is_jumping = bool(state.get("is_jumping", false))
	is_ko = bool(state.get("is_ko", is_ko))
	jump_height = maxf(0.0, float(state.get("jump_height", 0.0)))
	hopping = bool(state.get("hopping", false))
	hop_side = String(state.get("hop_side", ""))
	hop_steps = int(state.get("hop_steps", hop_steps))
	walk_phase = float(state.get("walk_phase", walk_phase))
	was_walking = bool(state.get("was_walking", false))
	crouch = clampf(float(state.get("crouch", crouch)), 0.0, 62.0)
	lean = clampf(float(state.get("lean", lean)), -58.0, 62.0)
	head_drop = clampf(float(state.get("head_drop", head_drop)), -6.0, 16.0)
	stance_height = clampf(float(state.get("stance_height", stance_height)), 0.0, 20.0)
	var incoming_targets: Variant = state.get("held_targets", {})
	if incoming_targets is Dictionary:
		held_targets = incoming_targets.duplicate(true)
	if network_remote:
		var incoming_disabled: Variant = state.get("guard_disabled", [])
		var disabled_now: Dictionary = {}
		if incoming_disabled is Array:
			for limb in incoming_disabled:
				var limb_name := String(limb)
				if limb_name in ["left_forearm", "right_forearm", "left_shin", "right_shin"]:
					disabled_now[limb_name] = 0.22
		elif incoming_disabled is Dictionary:
			for limb in incoming_disabled.keys():
				var limb_name := String(limb)
				if limb_name in ["left_forearm", "right_forearm", "left_shin", "right_shin"] and bool(incoming_disabled[limb]):
					disabled_now[limb_name] = 0.22
		for limb in guard_stagger.keys():
			if not disabled_now.has(limb):
				guard_stagger.erase(limb)
		for limb in disabled_now:
			guard_stagger[limb] = maxf(float(guard_stagger.get(limb, 0.0)), float(disabled_now[limb]))
	last_hit_blocked = bool(state.get("last_hit_blocked", last_hit_blocked))
	last_hit_region = String(state.get("last_hit_region", last_hit_region))
	var incoming_point: Variant = state.get("hit_point", hit_point)
	if incoming_point is Vector2:
		hit_point = incoming_point
	_solve_pose()
	queue_redraw()
	if is_ko and not was_ko:
		ko_reached.emit(self)

func selected_limb_name() -> String:
	return LIMBS[selected_limb_index].replace("forearm", "hand").replace("thigh", "knee").replace("shin", "foot").replace("_", " ").to_upper()

func get_selected_limb_node() -> Node2D:
	return bodies[LIMBS[selected_limb_index]]

func get_world_center() -> Vector2:
	return bodies["torso"].global_position

# Draw the whole connected silhouette on a 2px grid, with shared joint fills.
func _pixel(point: Vector2) -> Vector2:
	return (point / PIXEL_SIZE).round()

func _draw() -> void:
	if joints.is_empty():
		return
	var warrior := profile.visual_style == "batyr"
	draw_set_transform(Vector2.ZERO, 0, Vector2.ONE * PIXEL_SIZE)
	draw_rect(Rect2(-31 if warrior else -26, -1, 62 if warrior else 52, 3), Color(0.04, 0.03, 0.10, 0.45))
	var posed := _pose_transform()
	draw_set_transform(posed.origin, posed.get_rotation(), Vector2(PIXEL_SIZE * facing_direction, PIXEL_SIZE))
	ArcadeSkinType.draw(self, joints, warrior)
	if hit_flash > 0.0:
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE * PIXEL_SIZE)
		var p := _pixel(hit_point)
		for i in 8:
			var direction := Vector2.from_angle(i * PI / 4.0)
			draw_line(p + direction * 5, p + direction * (14 + hit_flash * 25), Color("fff1b8"), 2)
	if not dragging_limb.is_empty() and not is_ko and not is_fallen:
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE * PIXEL_SIZE)
		var p := _pixel(get_selected_limb_node().position)
		draw_rect(Rect2(p - Vector2(10, 10), Vector2(20, 20)), Color("fff1b8"), false, 1)

func _clear_drags() -> void:
	for id in active_drags.keys():
		_end_pointer_drag(id)
	dragging_limb = ""

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		_clear_drags()
