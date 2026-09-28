extends SceneTree

const MainScene = preload("res://scenes/main.tscn")
const PoseCases = preload("res://tests/rig_pose_cases.gd")
var failures := 0
var images := {}
var reference_reach := -1.0
var coordinate_checks := 0
var coordinate_max_error := 0.0
const COORDINATE_TOLERANCE := 0.001


func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		if failures <= 40:
			push_error("FAIL: " + message)


func covers(skin: SkeletonRigSkin, part_name: String, point: Vector2, radius: float = 3.0) -> bool:
	var sprite: Sprite2D = skin.sprites[part_name]
	var key := skin.fighter_id + part_name
	if not images.has(key):
		images[key] = sprite.texture.get_image()
	var pixels: Image = images[key]
	for offset in [Vector2.ZERO, Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var local := sprite.to_local(skin.skeleton.to_global(point + offset * radius)) + sprite.texture.get_size()*0.5
		var pixel := Vector2i(local.floor())
		if not Rect2i(Vector2i.ZERO, pixels.get_size()).has_point(pixel) or pixels.get_pixelv(pixel).a < 0.5:
			return false
	return true


func check_pose(fighter: RagdollCharacter, label: String) -> void:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	for point in fighter.joints.values():
		check(point is Vector2, "combat joint map contains only positions")
	for part_name in skin.PART_ORDER:
		var definition: Dictionary = skin.parts[part_name]
		var sprite: Sprite2D = skin.sprites[part_name]
		var pivot := skin._vector(definition.pivot) - skin._slot_origin(definition.source_slot) - sprite.texture.get_size()*0.5
		var tip := skin._vector(definition.tip) - skin._slot_origin(definition.source_slot) - sprite.texture.get_size()*0.5
		var target := skin._target_segment(part_name, fighter.joints)
		check(sprite.to_global(pivot).distance_to(skin.skeleton.to_global(target[0])) < 0.01, label+" "+part_name+" pivot")
		check(sprite.to_global(tip).distance_to(skin.skeleton.to_global(target[1])) < 0.01, label+" "+part_name+" tip")
		check(covers(skin, part_name, target[0]), label+" "+part_name+" visible pivot coverage")
		check(covers(skin, part_name, target[1]), label+" "+part_name+" visible tip coverage")
		check(skin.bones[part_name].scale.is_equal_approx(Vector2.ONE), "bone scale must not depend on source pixels")
		if skin.preserves_proportions():
			check(is_equal_approx(sprite.transform.x.length(), skin.pixel_scale) and is_equal_approx(sprite.transform.y.length(), skin.pixel_scale), label+" "+part_name+" preserves the common uniform scale")
			check(absf(sprite.transform.x.dot(sprite.transform.y)) < 0.0001, label+" "+part_name+" has no shear")
			check(absf(target[0].distance_to(target[1])-skin.segment_length(part_name, 0.0)) < 0.01, label+" "+part_name+" keeps its source length")
	for side in ["left", "right"]:
		var shin := skin._target_segment(side+"_shin", fighter.joints)
		var boot := skin._target_segment(side+"_boot", fighter.joints)
		check(shin[1].is_equal_approx(boot[0]), label+" shared ankle cuff")
		check(skin.bones[side+"_thigh"].z_index > skin.bones.torso.z_index, label+" thigh draws over torso")
		check(skin.bones[side+"_shin"].z_index > skin.bones.torso.z_index, label+" shin draws over torso")
		check(skin.bones[side+"_shin"].z_index > skin.bones[side+"_boot"].z_index, label+" shin draws over foot")
		check(skin.bones[side+"_thigh"].z_index > skin.bones[side+"_shin"].z_index, label+" thigh draws over shin")
		if skin.preserves_proportions() and skin.parts.torso.has("shoulders"):
			var torso: Sprite2D = skin.sprites.torso
			var landmark := skin._vector(skin.parts.torso.shoulders[0 if side == "left" else 1])
			var local := landmark - skin._slot_origin("torso") - torso.texture.get_size()*0.5
			var authored_shoulder := torso.to_global(local)
			var arm_root: Vector2 = skin.bones[side+"_upper_arm"].global_position
			check(authored_shoulder.distance_to(arm_root) < 0.01, label+" "+side+" arm attaches to the extracted torso shoulder")
		check(covers(skin, "torso", fighter.joints[side+"_shoulder"]), label+" "+side+" shoulder inside visible torso")
		check(covers(skin, "torso", fighter.joints[side+"_hip"]), label+" "+side+" hip inside visible torso")
	check(covers(skin, "torso", skin._target_segment("head", fighter.joints)[0]), label+" neck inside visible torso")
	check(covers(skin, "head", fighter.joints.head), label+" head hit target inside visible head")
	if skin.uses_authored_shoulders():
		var coordinate_audit := PoseCases.coordinate_evidence(fighter)
		check(coordinate_audit.point_count == 29, label+" all 22 extracted and seven calculated points audited")
		for item in coordinate_audit.points:
			coordinate_checks += 1
			coordinate_max_error = maxf(coordinate_max_error, float(item.error))
			check(float(item.error) < COORDINATE_TOLERANCE, label+" "+item.key+" renderer matches original coordinate reference")
		var separation: float = fighter.joints.left_shoulder.distance_to(fighter.joints.right_shoulder)
		var authored: float = skin._vector(skin.parts.torso.shoulders[0]).distance_to(skin._vector(skin.parts.torso.shoulders[1])) * skin.pixel_scale
		check(absf(separation-authored) < 0.01, label+" shoulder separation matches the source markers")
		check(separation > 0.01, label+" arms have distinct shoulder pivots")


func _init() -> void:
	call_deferred("_run")

func check_authored_pointer_controls(fighter: RagdollCharacter) -> void:
	var skin: SkeletonRigSkin = fighter.skeleton_skin
	if not skin.uses_authored_shoulders():
		return
	for facing in [-1.0, 1.0]:
		fighter.facing_direction = facing
		for side in ["left", "right"]:
			PoseCases.apply(fighter, "guard")
			var limb: String = side+"_forearm"
			var start: Vector2 = fighter.bodies[limb].global_position
			fighter._start_pointer_drag_at(start, 900)
			check(fighter.dragging_limb == limb, side+" hand can be picked with authored shoulders")
			var desired: Vector2 = fighter.joints.shoulder + Vector2(1000, 0)
			desired.x *= facing
			fighter._update_pointer_drag(900, fighter.to_global(fighter._pose_transform()*desired), 1.0/60.0)
			fighter._end_pointer_drag(900)
			var reach: float = fighter.joints[side+"_hand"].x - fighter.joints.shoulder.x
			check(absf(reach-skin.arm_control_reach(fighter.ARM_REACH)) < 0.01, side+" pointer drag reaches the shared torso-centered limit")
			check_pose(fighter, side+" pointer drag / "+str(facing))


func _run() -> void:
	var main := MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("batyr", "oculon")
	await process_frame
	for fighter in [main.player, main.opponent]:
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--rig-dir="):
				if not PoseCases.install_candidate(fighter, argument.trim_prefix("--rig-dir=")):
					quit(2)
					return
		var pose_root: Node = fighter.get_node_or_null("SkeletonRigSkin/RigPose")
		var skeleton: Node = fighter.get_node_or_null("SkeletonRigSkin/RigPose/Skeleton2D")
		check(pose_root != null, "%s creates the rig pose root" % fighter.profile.display_name)
		check(skeleton is Skeleton2D, "%s creates a Skeleton2D" % fighter.profile.display_name)
		var skin = fighter.skeleton_skin
		if skin.uses_authored_shoulders():
			var rest_audit := PoseCases.rest_coordinate_evidence(fighter)
			for key in rest_audit.errors:
				check(float(rest_audit.errors[key]) < COORDINATE_TOLERANCE, key+" rest pose matches original coordinates")
			var profile: Dictionary = skin._read_json(skin.rig_directory.path_join("profile.json"))
			var original: Dictionary = skin._read_json(skin.rig_directory.path_join("extracted_pivots.json"))
			profile.parts.left_upper_arm.pivot[0] += 1.0
			check(not skin._coordinate_contract_valid(profile, original), "runtime rejects a compiled marker moved one pixel")
		check(skin.bones.size() == 12, "twelve attachments loaded")
		check(skin.bones.left_forearm.get_parent() == skin.bones.left_upper_arm, "elbow hierarchy")
		for shape in skin.body_type_names():
			skin.body_type = shape
			for facing in [-1.0, 1.0]:
				fighter.facing_direction = facing
				for pose in PoseCases.NAMES:
					PoseCases.apply(fighter, pose)
					check_pose(fighter, "%s/%s/%s/%s" % [skin.fighter_id, shape, facing, pose])
				PoseCases.apply(fighter, "guard")
				fighter.held_targets.left_forearm = Vector2(97, 0)
				fighter.held_targets.right_forearm = Vector2(97, 0)
				fighter._solve_pose()
				for part_name in skin.PART_ORDER:
					var definition: Dictionary = skin.parts[part_name]
					var sprite: Sprite2D = skin.sprites[part_name]
					check(sprite.texture != null, "imported texture available")
					var pivot: Vector2 = skin._vector(definition.pivot) - skin._slot_origin(part_name) - sprite.texture.get_size() * 0.5
					var tip: Vector2 = skin._vector(definition.tip) - skin._slot_origin(part_name) - sprite.texture.get_size() * 0.5
					var target = skin._target_segment(part_name, fighter.joints)
					check(sprite.to_global(pivot).distance_to(skin.skeleton.to_global(target[0])) < 0.01, "%s %s pivot remains attached" % [shape, part_name])
					check(sprite.to_global(tip).distance_to(skin.skeleton.to_global(target[1])) < 0.01, "%s %s distal joint remains attached" % [shape, part_name])
				check(is_equal_approx(fighter.joints.left_hand.x, fighter.joints.right_hand.x), "equal forward arm reach")
				var reach: float = fighter.joints.left_hand.x - fighter.joints.shoulder.x
				var expected_reach: float = skin.arm_control_reach(fighter.ARM_REACH) if skin.uses_authored_shoulders() else float(skin.contract.shoulder_x)+fighter.ARM_REACH
				check(is_equal_approx(reach, expected_reach), "both arms reach the shared forward limit")
				if reference_reach < 0:
					reference_reach = reach
				check(is_equal_approx(reach, reference_reach), "body type does not change maximum forward reach")
				for offset in [Vector2.ZERO, Vector2(1,0), Vector2(1000,0), Vector2(0,-1000)]:
					fighter.lean = 55
					for side in ["left","right"]:
						fighter.held_targets[side+"_forearm"] = offset
					fighter._solve_pose()
					for side in ["left","right"]:
						var shoulder: Vector2 = fighter.joints[side+"_shoulder"]
						var elbow: Vector2 = fighter.joints[side+"_elbow"]
						var hand: Vector2 = fighter.joints[side+"_hand"]
						check(absf(shoulder.distance_to(elbow)-skin.segment_length(side+"_upper_arm", fighter.ARM_UPPER_LENGTH)) < 0.01, "upper arm keeps its length at extreme targets")
						check(absf(elbow.distance_to(hand)-skin.segment_length(side+"_forearm", fighter.ARM_FOREARM_LENGTH)) < 0.01, "forearm keeps its length at extreme targets")
						var reach_origin: Vector2 = fighter.joints.shoulder if skin.preserves_proportions() and skin.parts.torso.has("shoulders") else shoulder
						check(reach_origin.distance_to(hand) <= fighter.ARM_REACH+0.01, "lean cannot extend combat reach")
		check_authored_pointer_controls(fighter)
		fighter.facing_direction = 1.0
		PoseCases.apply(fighter, "guard")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--report="):
			var path := argument.trim_prefix("--report=")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var report := PoseCases.evidence([main.player, main.opponent])
			report.shoulder_attachments = [PoseCases.shoulder_evidence(main.player), PoseCases.shoulder_evidence(main.opponent)]
			report.coordinate_audit = [PoseCases.coordinate_evidence(main.player), PoseCases.coordinate_evidence(main.opponent)]
			report.rest_coordinate_audit = [PoseCases.rest_coordinate_evidence(main.player), PoseCases.rest_coordinate_evidence(main.opponent)]
			report.coordinate_validation = {"point_evaluations": coordinate_checks, "maximum_error": coordinate_max_error, "tolerance": COORDINATE_TOLERANCE}
			report.passed = failures == 0
			report.failures = failures
			FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(report,"  ")+"\n")
	main.queue_free()
	await process_frame
	print("Skeleton rig: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
