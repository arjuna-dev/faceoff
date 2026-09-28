extends RefCounted
## The same pose cases drive numeric validation and real-renderer captures.
const NAMES := ["guard", "left-punch", "right-punch", "walk", "low-kick", "high-kick", "crouch", "bow", "arch", "jump", "hop", "fall", "get-up"]

static func evidence(fighters: Array) -> Dictionary:
	var bytes := PackedByteArray()
	for path in ["scripts/characters/skeleton_rig_skin.gd", "scripts/characters/ragdoll_character.gd", "assets/fighters/rigged/contract.json", "tests/rig_pose_cases.gd"]:
		bytes.append_array(FileAccess.get_file_as_bytes("res://"+path))
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	var result := {"engine":Engine.get_version_info().string, "runtime_sha256":hashing.finish().hex_encode(), "poses":NAMES, "body_types":SkeletonRigSkin.body_type_names(), "facings":[-1,1], "rigs":{}}
	for fighter in fighters:
		var skin: SkeletonRigSkin = fighter.skeleton_skin
		result.rigs[skin.fighter_id] = FileAccess.get_sha256(skin.rig_directory.path_join("rig.json"))
	return result

static func install_candidate(fighter: RagdollCharacter, directory: String) -> bool:
	var source: Dictionary = SkeletonRigSkin._read_json(directory.path_join("profile.json"))
	var style: String = source.get("fighter_id", "")
	if not SkeletonRigSkin.valid_profile(directory, style):
		push_error("Invalid or unimported candidate rig: "+directory)
		return false
	if fighter.skeleton_skin:
		fighter.skeleton_skin.free()
	fighter.skeleton_skin = SkeletonRigSkin.new()
	fighter.skeleton_skin.name = "SkeletonRigSkin"
	fighter.add_child(fighter.skeleton_skin)
	fighter.skeleton_skin.configure(style, source.get("body_type", "standard"), directory)
	fighter._solve_pose()
	return true

static func shoulder_evidence(fighter: RagdollCharacter) -> Dictionary:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	if not skin.uses_authored_shoulders():
		return {"fighter_id": skin.fighter_id, "attachment_mode": "legacy_contract"}
	var torso: Sprite2D = skin.sprites.torso
	var result := {"fighter_id": skin.fighter_id, "attachment_mode": "extracted_markers", "source_shoulders": skin.parts.torso.shoulders, "pixel_scale": skin.pixel_scale, "shared_combat_reach": skin.arm_control_reach(fighter.ARM_REACH), "sides": {}}
	for side in ["left", "right"]:
		var landmark := skin._vector(skin.parts.torso.shoulders[0 if side == "left" else 1])
		var local := landmark - skin._slot_origin("torso") - torso.texture.get_size()*0.5
		var expected := torso.to_global(local)
		var actual: Vector2 = skin.bones[side+"_upper_arm"].global_position
		result.sides[side] = {"torso_marker_world": [expected.x, expected.y], "arm_pivot_world": [actual.x, actual.y], "error": expected.distance_to(actual)}
	var separation: float = fighter.joints.left_shoulder.distance_to(fighter.joints.right_shoulder)
	result.shoulder_separation = separation
	result.expected_shoulder_separation = skin._vector(skin.parts.torso.shoulders[0]).distance_to(skin._vector(skin.parts.torso.shoulders[1])) * skin.pixel_scale
	return result

static func coordinate_target(fighter: RagdollCharacter, item: Dictionary) -> Vector2:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	if item.field in ["pivot", "tip"]:
		var segment := skin._target_segment(item.part, fighter.joints)
		return segment[0 if item.field == "pivot" else 1]
	if item.field == "neck":
		return skin._target_segment("head", fighter.joints)[0]
	var side := "left" if int(item.index) == 0 else "right"
	return fighter.joints[side+("_shoulder" if item.field == "shoulders" else "_hip")]

static func coordinate_evidence(fighter: RagdollCharacter) -> Dictionary:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	if not skin.uses_authored_shoulders():
		return {"fighter_id": skin.fighter_id, "attachment_mode": "legacy_contract"}
	var points := []
	var maximum := 0.0
	for item in skin.coordinate_reference.points:
		var sprite: Sprite2D = skin.sprites[item.part]
		var local := skin._vector(item.crop_local) - sprite.texture.get_size()*0.5
		var actual := sprite.to_global(local)
		var target := coordinate_target(fighter, item)
		var expected := skin.skeleton.to_global(target)
		var error := actual.distance_to(expected)
		maximum = maxf(maximum, error)
		points.append({"key": item.key, "kind": item.kind, "original_page": item.page, "crop_local": item.crop_local, "game_joint": [target.x, target.y], "rendered_world": [actual.x, actual.y], "expected_world": [expected.x, expected.y], "error": error})
	return {"fighter_id": skin.fighter_id, "point_count": points.size(), "marker_count": 22, "calculated_count": 7, "maximum_error": maximum, "points": points}

static func rest_coordinate_evidence(fighter: RagdollCharacter) -> Dictionary:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	if not skin.uses_authored_shoulders():
		return {"fighter_id": skin.fighter_id, "attachment_mode": "legacy_contract"}
	var rest_poses := {}
	for name in skin.PART_ORDER:
		var parent: String = skin.contract.parents.get(name, "")
		var parent_rest: Transform2D = rest_poses.get(parent, Transform2D.IDENTITY)
		var bone: Bone2D = skin.bones[name]
		rest_poses[name] = parent_rest*bone.rest
	var points := {}
	for item in skin.coordinate_reference.points:
		var sprite: Sprite2D = skin.sprites[item.part]
		var local := skin._vector(item.crop_local)-sprite.texture.get_size()*0.5
		points[item.key] = rest_poses[item.part]*sprite.transform*local
	var links := [["head.pivot", "torso.neck"]]
	for side in ["left", "right"]:
		var index := "0" if side == "left" else "1"
		links.append([side+"_upper_arm.pivot", "torso.shoulders."+index])
		links.append([side+"_forearm.pivot", side+"_upper_arm.tip"])
		links.append([side+"_thigh.pivot", "torso.hips."+index])
		links.append([side+"_shin.pivot", side+"_thigh.tip"])
		links.append([side+"_boot.pivot", side+"_shin.tip"])
	var errors := {}
	var maximum := 0.0
	for link in links:
		var error: float = points[link[0]].distance_to(points[link[1]])
		errors[link[0]+" = "+link[1]] = error
		maximum = maxf(maximum, error)
	var source_torso := skin._vector(skin.parts.torso.tip)-skin._vector(skin.parts.torso.pivot)
	var game_torso: Vector2 = points["torso.tip"]-points["torso.pivot"]
	var turn := game_torso.angle()-source_torso.angle()
	for name in skin.PART_ORDER:
		var source_axis := skin._vector(skin.parts[name].tip)-skin._vector(skin.parts[name].pivot)
		var expected := source_axis.rotated(turn)*skin.pixel_scale
		var actual: Vector2 = points[name+".tip"]-points[name+".pivot"]
		var error := expected.distance_to(actual)
		errors[name+" source axis"] = error
		maximum = maxf(maximum, error)
	return {"fighter_id": skin.fighter_id, "maximum_error": maximum, "errors": errors}

static func apply(fighter: RagdollCharacter, pose: String) -> void:
	fighter.reset_character()
	fighter.set_physics_process(false)
	fighter.animation_time = 0.0
	match pose:
		"left-punch": fighter.held_targets.left_forearm = Vector2(97, 0)
		"right-punch": fighter.held_targets.right_forearm = Vector2(97, 0)
		"walk":
			fighter.was_walking = true
			fighter.walk_phase = 1.3
			fighter.held_targets.left_forearm = Vector2(85, -10)
		"low-kick": fighter.held_targets.right_shin = Vector2(120, 10)
		"high-kick": fighter.held_targets.right_shin = Vector2(70, -100)
		"crouch": fighter.crouch = 55
		"bow": fighter.lean = 55
		"arch": fighter.lean = -50
		"jump": fighter.jump_height = 70
		"hop":
			fighter.held_targets.right_shin = Vector2(30, -40)
			fighter.hopping = true
			fighter.hop_clock = 0.2
		"fall", "get-up":
			fighter._start_fall()
			fighter.fall_progress = 1.0 if pose == "fall" else 0.4
	fighter._solve_pose()
