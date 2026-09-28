extends SceneTree
## Export the real renderer's native nodes, not a second coordinate implementation.
const RigSkin = preload("res://scripts/characters/skeleton_rig_skin.gd")
const Fighter = preload("res://scripts/characters/ragdoll_character.gd")
const Cases = preload("res://tests/rig_pose_cases.gd")

func _init() -> void:
	call_deferred("_run")

func _own(node: Node, scene: Node) -> void:
	node.owner = scene
	for child in node.get_children():
		_own(child, scene)

func _copy_pose(skin: Node, scene: Node2D, title: String, shown: bool, rear_only: bool = false) -> Node2D:
	var group := Node2D.new()
	group.name = title
	group.position = Vector2(480, 460)
	group.scale = Vector2(1.5, 1.5)
	group.visible = shown
	scene.add_child(group)
	var pose: Node2D = skin.pose_root.duplicate(0)
	group.add_child(pose)
	for part in RigSkin.PART_ORDER:
		var bone: Bone2D = pose.get_node(NodePath(String(skin.pose_root.get_path_to(skin.bones[part]))))
		var sprite: Sprite2D = pose.get_node(NodePath(String(skin.pose_root.get_path_to(skin.sprites[part]))))
		bone.set_meta("source_part", part)
		bone.set_meta("source_page_pivot", skin.parts[part].pivot)
		bone.set_meta("source_page_tip", skin.parts[part].tip)
		sprite.set_meta("source_rect", skin.parts[part].rect)
		sprite.set_meta("uniform_pixel_scale", skin.pixel_scale)
		sprite.set_meta("crop_local_pivot", [skin.parts[part].pivot[0]-skin.parts[part].rect[0], skin.parts[part].pivot[1]-skin.parts[part].rect[1]])
		if rear_only:
			sprite.visible = part in ["left_upper_arm", "left_forearm"]
	_own(group, scene)
	return group

func _verify_nodes(node: Node, counts: Dictionary) -> bool:
	if node.get_script() != null:
		return false
	if node is Bone2D:
		counts.bones += 1
	if node is Sprite2D:
		counts.sprites += 1
	for child in node.get_children():
		if not _verify_nodes(child, counts):
			return false
	return true

func _run() -> void:
	var directory := ""
	var output := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--rig-dir="):
			directory = argument.trim_prefix("--rig-dir=")
		if argument.begins_with("--output="):
			output = argument.trim_prefix("--output=")
	if directory.is_empty() or output.is_empty() or FileAccess.file_exists(output):
		push_error("Supply --rig-dir and a new --output .tscn path; existing scenes are never overwritten")
		quit(1)
		return
	var profile: Dictionary = RigSkin._read_json(directory.path_join("profile.json"))
	if not RigSkin.valid_profile(directory, profile.get("fighter_id", "")):
		push_error("Invalid candidate profile")
		quit(1)
		return
	var fighter := Fighter.new()
	fighter.profile = CharacterProfile.new()
	fighter.profile.visual_style = profile.fighter_id
	fighter.profile.body_type = profile.get("body_type", "standard")
	root.add_child(fighter)
	fighter.setup(fighter.profile, 1, 1.0)
	fighter.set_physics_process(false)
	if not Cases.install_candidate(fighter, directory):
		quit(1)
		return
	Cases.apply(fighter, "guard")
	if not fighter.joints.has("right_shoulder") or not fighter.joints.has("left_shoulder"):
		push_error("The production guard pose did not produce both shoulders; no scene will be saved")
		quit(1)
		return
	var skin: Node = fighter.skeleton_skin
	var scene := Node2D.new()
	scene.name = "RigInspection"
	root.add_child(scene)
	scene.set_meta("source_directory", directory)
	scene.set_meta("instructions", "GameGuard is the production pose. Hide it and show RearArmOnly to inspect occlusion, or SourceRest for the authored rest pose. Expand RigPose/Skeleton2D/torsoBone. Hide only torsoSprite, never torsoBone, to reveal arms in the assembled rig. This script-free scene is a sandbox; edits do not update game source.json.")
	var guard := _copy_pose(skin, scene, "GameGuard", true)
	_copy_pose(skin, scene, "RearArmOnly", false, true)
	var rest_skin := RigSkin.new()
	root.add_child(rest_skin)
	rest_skin.configure(profile.fighter_id, profile.get("body_type", "standard"), directory)
	_copy_pose(rest_skin, scene, "SourceRest", false)
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var packed := PackedScene.new()
	var error := packed.pack(scene)
	if error == OK:
		error = ResourceSaver.save(packed, output)
	if error != OK:
		push_error("Scene export failed: "+str(error))
		quit(1)
		return
	var loaded: PackedScene = ResourceLoader.load(output, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var instance := loaded.instantiate()
	var counts := {"bones": 0, "sprites": 0}
	var verified: bool = _verify_nodes(instance, counts) and counts.bones == 36 and counts.sprites == 36
	var saved_pose: Node2D = instance.get_node("GameGuard/RigPose")
	var maximum := 0.0
	for part in RigSkin.PART_ORDER:
		for live in [skin.bones[part], skin.sprites[part]]:
			var path: NodePath = skin.pose_root.get_path_to(live)
			var saved: Node2D = saved_pose.get_node(path)
			maximum = maxf(maximum, saved.position.distance_to(live.position))
			maximum = maxf(maximum, absf(saved.rotation-live.rotation))
			maximum = maxf(maximum, saved.scale.distance_to(live.scale))
			verified = verified and saved.z_index == live.z_index
			if saved is Sprite2D:
				verified = verified and saved.texture.resource_path == live.texture.resource_path
	verified = verified and maximum <= 0.001 and guard.visible
	var shoulders: Dictionary = Cases.shoulder_evidence(fighter)
	var report := {"passed": verified, "scene": output, "native_bones": counts.bones, "sprites": counts.sprites, "script_free": true, "maximum_serialization_error": maximum, "shoulders": shoulders, "rear_arm_z": skin.bones.left_upper_arm.z_index, "torso_z": skin.bones.torso.z_index}
	FileAccess.open(output+".audit.json", FileAccess.WRITE).store_string(JSON.stringify(report,"  ")+"\n")
	print(JSON.stringify(report,"  "))
	instance.free()
	scene.free()
	rest_skin.free()
	fighter.free()
	quit(0 if verified else 1)
