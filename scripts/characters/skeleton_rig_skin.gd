class_name SkeletonRigSkin
extends Node2D
## Bones use game units. Source pixel scale belongs only to their sprites.
const CONTRACT_PATH := "res://assets/fighters/rigged/contract.json"
const WHOLE_CHARACTER := "whole_character"
## Absolute z for back attachments (wings, capes): behind every limb.
const BACK_ATTACHMENT_Z := -3
const PART_ORDER: Array[String] = ["torso", "head", "left_upper_arm", "left_forearm", "right_upper_arm", "right_forearm", "left_thigh", "right_thigh", "left_shin", "right_shin", "left_boot", "right_boot"]
# Feet tuck under shins, shins under thighs, and both legs cover the pelvis.
const Z_BY_PART := {"left_upper_arm":-2, "left_forearm":-1, "torso":0, "head":1, "left_boot":2, "right_boot":3, "left_shin":4, "right_shin":5, "left_thigh":6, "right_thigh":7, "right_upper_arm":8, "right_forearm":9}
var fighter_id := ""
var rig_directory := ""
var body_type := "standard"
var head_tilt := 0.0
var pose_root: Node2D
var skeleton: Skeleton2D
var bones: Dictionary = {}
var sprites: Dictionary = {}
var parts: Dictionary = {}
var slots: Dictionary = {}
var contract: Dictionary = {}
var torso_pixels: Image
var render_mode := ""
var pixel_scale := 1.0
var coordinate_reference: Dictionary = {}
var attachments: Dictionary = {}
var _authored_rest_cache: Dictionary = {}
## Planted feet stand this far above the node origin, like the shared stance.
const AUTHORED_FOOT_Y := -5.0
var attachment_sprites: Dictionary = {}

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

static func has_profile(style: String) -> bool:
	var directory := "res://assets/fighters/rigged/%s" % style
	var valid := valid_profile(directory, style)
	if not valid and FileAccess.file_exists(directory.path_join("profile.json")):
		push_warning("Rejected stale or invalid rig for %s. Using the previous atlas; run the rig workflow checks before exporting." % style)
	return valid

static func valid_profile(directory: String, style: String) -> bool:
	var path := directory.path_join("profile.json")
	var profile := _read_json(path)
	var spec := _read_json(CONTRACT_PATH)
	var manifest := _read_json(directory.path_join("rig.json"))
	if int(profile.get("schema_version", 0)) != 3 or profile.get("fighter_id", "") != style:
		return false
	if manifest.get("profile_sha256", "") != FileAccess.get_sha256(path) or manifest.get("contract_sha256", "") != FileAccess.get_sha256(CONTRACT_PATH):
		return false
	if not profile.get("parts", {}) is Dictionary:
		return false
	if profile.get("render_mode", "") == WHOLE_CHARACTER:
		return _valid_whole_character(directory, profile)
	var definitions: Dictionary = profile.get("parts", {})
	var preserved: bool = profile.get("render_mode", "") == "preserve_proportions"
	if preserved and (not is_finite(float(profile.get("pixel_scale", 0))) or float(profile.get("pixel_scale", 0)) <= 0):
		return false
	if definitions.size() != PART_ORDER.size():
		return false
	if preserved:
		var reference: Dictionary = profile.get("coordinate_contract", {})
		var marker_path := directory.path_join("extracted_pivots.json")
		if reference.get("marker_json", "") != "extracted_pivots.json" or reference.get("marker_json_sha256", "") != FileAccess.get_sha256(marker_path):
			return false
		if not _coordinate_contract_valid(profile, _read_json(marker_path)):
			return false
	for name in PART_ORDER:
		if not definitions.get(name, {}) is Dictionary:
			return false
		var part: Dictionary = definitions.get(name, {})
		var slot: Dictionary = spec.get("slots", {}).get(name, {})
		if part.get("source_slot", "") != name or slot.is_empty():
			return false
		if preserved:
			var rect: Array = part.get("rect", [])
			if rect.size() != 4 or rect[0] < 0 or rect[1] < 0 or rect[2] > 1024 or rect[3] > 1536 or rect[2] <= rect[0] or rect[3] <= rect[1]:
				return false
			for field in ["pivot", "tip"]:
				var point: Array = part.get(field, [])
				if point.size() != 2 or not is_finite(float(point[0])) or not is_finite(float(point[1])) or point[0] < rect[0] or point[0] >= rect[2] or point[1] < rect[1] or point[1] >= rect[3]:
					return false
			if part.pivot == part.tip:
				return false
		else:
			for field in ["rect", "pivot", "tip"]:
				if part.get(field, []) != slot[field]:
					return false
		var width := float(part.get("source_width", 0))
		if not is_finite(width) or width <= 0 or not ResourceLoader.exists(directory.path_join(name+".png")):
			return false
	return true

## Rigs published by tools/export_whole_character_rig.py: parts keep their
## source shape on the source canvas, with optional rigid attachments.
static func _valid_whole_character(directory: String, profile: Dictionary) -> bool:
	var scale := float(profile.get("pixel_scale", 0))
	var canvas: Array = profile.get("source_canvas", [])
	var definitions: Dictionary = profile.get("parts", {})
	if not is_finite(scale) or scale <= 0 or canvas.size() != 2 or definitions.size() != PART_ORDER.size():
		return false
	for name in PART_ORDER:
		var part: Variant = definitions.get(name)
		if not part is Dictionary or part.get("source_slot", "") != name:
			return false
		var rect: Array = part.get("rect", [])
		if rect.size() != 4 or rect[0] < 0 or rect[1] < 0 or rect[2] > canvas[0] or rect[3] > canvas[1] or rect[2] <= rect[0] or rect[3] <= rect[1]:
			return false
		if part.get("pivot", []).size() != 2 or part.get("tip", []).size() != 2 or part.pivot == part.tip:
			return false
		if float(part.get("source_width", 0)) <= 0 or not ResourceLoader.exists(directory.path_join(name + ".png")):
			return false
	var torso: Dictionary = definitions.torso
	if torso.get("shoulders", []).size() != 2 or torso.get("hips", []).size() != 2 or torso.get("neck", []).size() != 2:
		return false
	for attachment in profile.get("attachments", {}).values():
		if not attachment is Dictionary or not PART_ORDER.has(attachment.get("parent", "")) or attachment.get("rect", []).size() != 4:
			return false
		if not ResourceLoader.exists(directory.path_join(String(attachment.get("image", "")))):
			return false
	return true

static func _coordinate_contract_valid(profile: Dictionary, original: Dictionary) -> bool:
	var reference: Dictionary = profile.get("coordinate_contract", {})
	var points: Array = reference.get("points", [])
	if int(reference.get("schema_version", 0)) != 1 or int(reference.get("marker_count", 0)) != 22 or int(reference.get("calculated_count", 0)) != 7 or points.size() != 29:
		return false
	var original_count := 0
	for entries in original.get("pivots", {}).values():
		if not entries is Array:
			return false
		original_count += entries.size()
	if original_count != 22:
		return false
	var required := {}
	for name in PART_ORDER:
		for field in ["pivot", "tip"]:
			required[name+"."+field] = true
	for key in ["torso.neck", "torso.shoulders.0", "torso.shoulders.1", "torso.hips.0", "torso.hips.1"]:
		required[key] = true
	var seen := {}
	var originals := {}
	for item in points:
		var part_name: String = item.get("part", "")
		var field: String = item.get("field", "")
		var key: String = part_name+"."+field
		var index: Variant = item.get("index")
		if index != null:
			key += "."+str(int(index))
		if key != item.get("key", "") or not required.has(key) or seen.has(key):
			return false
		seen[key] = true
		var definition: Dictionary = profile.parts[part_name]
		var actual: Array = definition.get(field, [])
		if index != null:
			if not int(index) in [0, 1] or actual.size() != 2:
				return false
			actual = actual[int(index)]
		var page: Array = item.get("page", [])
		var rect: Array = definition.get("rect", [])
		if actual.size() != 2 or page != actual or rect.size() != 4:
			return false
		if item.get("crop_local", []) != [page[0]-rect[0], page[1]-rect[1]]:
			return false
		if item.get("kind", "") == "extracted":
			var cell: String = item.get("extraction_cell", "")
			var entries: Array = original.get("pivots", {}).get(cell, [])
			var original_index := int(item.get("original_index", -1))
			var original_key := cell+"."+str(original_index)
			if original_index < 0 or original_index >= entries.size() or originals.has(original_key):
				return false
			if entries[original_index].get("center", []) != page:
				return false
			originals[original_key] = true
		elif item.get("kind", "") != "calculated":
			return false
	if originals.size() != 22:
		return false
	var torso: Dictionary = profile.parts.torso
	for pair in [["pivot", "shoulders"], ["tip", "hips"]]:
		var landmarks: Array = torso[pair[1]]
		if torso[pair[0]] != [(landmarks[0][0]+landmarks[1][0])/2.0, (landmarks[0][1]+landmarks[1][1])/2.0]:
			return false
	return true

static func body_type_names() -> Array[String]:
	return ["small", "lean", "standard", "broad", "heavy"]

func configure(style: String, requested_body_type: String = "standard", directory: String = "") -> void:
	fighter_id = style
	if directory.is_empty():
		directory = "res://assets/fighters/rigged/%s" % style
	rig_directory = directory
	contract = _read_json(CONTRACT_PATH)
	body_type = requested_body_type if contract.body_types.has(requested_body_type) else "standard"
	var profile := _read_json(directory.path_join("profile.json"))
	parts = profile.get("parts", {})
	coordinate_reference = profile.get("coordinate_contract", {})
	render_mode = profile.get("render_mode", "")
	pixel_scale = float(profile.get("pixel_scale", 1.0))
	slots = contract.slots
	pose_root = Node2D.new()
	pose_root.name = "RigPose"
	pose_root.z_index = -1
	add_child(pose_root)
	skeleton = Skeleton2D.new()
	skeleton.name = "Skeleton2D"
	pose_root.add_child(skeleton)
	var rest_joints := {}
	for key in contract.rest_joints:
		rest_joints[key] = _vector(contract.rest_joints[key])
	if uses_authored_shoulders():
		rest_joints = _authored_rest_joints(rest_joints)
	var rest_global := {}
	for part_name in PART_ORDER:
		var definition: Dictionary = parts[part_name]
		var source_slot := String(definition.source_slot)
		var bone := Bone2D.new()
		bone.name = part_name + "Bone"
		bone.z_index = int(Z_BY_PART[part_name])
		bone.z_as_relative = false
		bone.set_autocalculate_length_and_angle(false)
		bone.set_bone_angle(0)
		var segment := _target_segment(part_name, rest_joints)
		var axis := segment[1] - segment[0]
		bone.set_length(axis.length())
		var desired := Transform2D(axis.angle(), segment[0])
		var parent_name: String = contract.parents.get(part_name, "")
		var parent_bone: Node = bones.get(parent_name, skeleton)
		parent_bone.add_child(bone)
		var parent_rest: Transform2D = rest_global.get(parent_name, Transform2D.IDENTITY)
		bone.transform = parent_rest.affine_inverse() * desired
		bone.rest = bone.transform
		rest_global[part_name] = desired
		bones[part_name] = bone
		var sprite := Sprite2D.new()
		sprite.name = part_name + "Sprite"
		sprite.texture = load(directory.path_join(source_slot+".png")) as Texture2D
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		bone.add_child(sprite)
		sprites[part_name] = sprite
	torso_pixels = sprites["torso"].texture.get_image() if sprites["torso"].texture else null
	attachments = profile.get("attachments", {})
	for attachment_name in attachments:
		_add_attachment(String(attachment_name), attachments[attachment_name], directory)
	apply_pose(rest_joints, Transform2D.IDENTITY, 1.0)

## A rigid attachment keeps its source placement relative to its parent part,
## so it moves exactly with that part's sprite.
func _add_attachment(attachment_name: String, definition: Dictionary, directory: String) -> void:
	var parent_name := String(definition.parent)
	var parent: Dictionary = parts[parent_name]
	var sprite := Sprite2D.new()
	sprite.name = attachment_name + "Sprite"
	sprite.texture = load(directory.path_join(String(definition.image))) as Texture2D
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var source_axis := _vector(parent.tip) - _vector(parent.pivot)
	var basis := Transform2D(-source_axis.angle(), Vector2.ZERO).scaled(Vector2.ONE * pixel_scale)
	var rect: Array = definition.rect
	var center := Vector2((float(rect[0]) + float(rect[2])) * 0.5, (float(rect[1]) + float(rect[3])) * 0.5)
	basis.origin = basis.basis_xform(center - _vector(parent.pivot))
	sprite.transform = basis
	if String(definition.get("layer", "")) == "back":
		sprite.z_as_relative = false
		sprite.z_index = BACK_ATTACHMENT_Z
	else:
		sprite.z_index = -1
	bones[parent_name].add_child(sprite)
	attachment_sprites[attachment_name] = sprite

func _vector(value: Variant) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))

func _slot_origin(source_slot: String) -> Vector2:
	if preserves_proportions():
		return _vector(parts[source_slot].rect)
	return _vector(slots[source_slot].rect)

## Whole-character rigs were drawn as one standing character, so their own
## drawn pose is the fighter's rest stance. Joints are in game units, facing
## right, with the node origin between the feet on the ground. Other rigs
## return {} and keep the game's shared stance.
func authored_rest() -> Dictionary:
	if render_mode != WHOLE_CHARACTER:
		return {}
	if not _authored_rest_cache.is_empty():
		return _authored_rest_cache
	var left_sole := _vector(parts.left_boot.tip)
	var right_sole := _vector(parts.right_boot.tip)
	var origin := Vector2((left_sole.x + right_sole.x) * 0.5, maxf(left_sole.y, right_sole.y))
	var game := func(point: Vector2) -> Vector2:
		return (point - origin) * pixel_scale + Vector2(0, AUTHORED_FOOT_Y)
	var rest := {"hip": game.call(_vector(parts.torso.tip)), "shoulder": game.call(_vector(parts.torso.pivot))}
	for side in ["left", "right"]:
		var shoulder: Vector2 = game.call(_vector(parts[side+"_upper_arm"].pivot))
		var elbow: Vector2 = game.call(_vector(parts[side+"_upper_arm"].tip))
		var hand: Vector2 = game.call(_vector(parts[side+"_forearm"].tip))
		var hip: Vector2 = game.call(_vector(parts[side+"_thigh"].pivot))
		var knee: Vector2 = game.call(_vector(parts[side+"_thigh"].tip))
		var ankle: Vector2 = game.call(_vector(parts[side+"_shin"].tip))
		var foot: Vector2 = game.call(_vector(parts[side+"_boot"].tip))
		rest[side+"_hand"] = hand
		rest[side+"_foot"] = foot
		rest[side+"_boot_direction"] = (foot - ankle).normalized() if foot != ankle else Vector2.DOWN
		# Which way the elbow and knee bend, in the solver's _bend convention.
		rest[side+"_elbow_bend"] = _bend_side(shoulder, hand, elbow)
		rest[side+"_knee_bend"] = _bend_side(hip, ankle, knee)
	_authored_rest_cache = rest
	return rest

static func _bend_side(root: Vector2, end: Vector2, middle: Vector2) -> float:
	var axis := (end - root).normalized()
	return -1.0 if (middle - root).dot(axis.orthogonal()) < 0.0 else 1.0

func preserves_proportions() -> bool:
	return render_mode == "preserve_proportions" or render_mode == WHOLE_CHARACTER

func uses_authored_shoulders() -> bool:
	return preserves_proportions() and parts.get("torso", {}).get("shoulders", []).size() == 2

func segment_length(part_name: String, fallback: float) -> float:
	if not preserves_proportions():
		return fallback
	return (_vector(parts[part_name].tip) - _vector(parts[part_name].pivot)).length() * pixel_scale

func _authored_rest_joints(reference: Dictionary) -> Dictionary:
	var result := reference.duplicate()
	var torso_axis: Vector2 = result.hip - result.shoulder
	torso_axis = torso_axis.normalized() * segment_length("torso", 67.0)
	result.hip = result.shoulder + torso_axis
	var source_torso_axis := _vector(parts.torso.tip) - _vector(parts.torso.pivot)
	var turn := torso_axis.angle() - source_torso_axis.angle()
	for side in ["left", "right"]:
		result[side+"_shoulder"] = result.shoulder + arm_root_offset(side, torso_axis)
		result[side+"_hip"] = result.hip + hip_offset(side, torso_axis)
		for chain in [["upper_arm", "shoulder", "elbow"], ["forearm", "elbow", "hand"], ["thigh", "hip", "knee"], ["shin", "knee", "ankle"], ["boot", "ankle", "foot"]]:
			var definition: Dictionary = parts[side+"_"+chain[0]]
			var axis := (_vector(definition.tip) - _vector(definition.pivot)).rotated(turn) * pixel_scale
			result[side+"_"+chain[2]] = result[side+"_"+chain[1]] + axis
	return result

func shape() -> Dictionary:
	return contract.body_types[body_type]

func _torso_landmark_offset(landmark: Vector2, target_axis: Vector2) -> Vector2:
	var torso_definition: Dictionary = parts.get("torso", {})
	var source_axis: Vector2 = _vector(torso_definition.get("tip", [0, 1])) - _vector(torso_definition.get("pivot", [0, 0]))
	var source_length := source_axis.length()
	var target_length := target_axis.length()
	var source_width := float(torso_definition.get("source_width", 0.0))
	if source_length <= 0.0 or target_length <= 0.0 or source_width <= 0.0:
		return Vector2.ZERO
	var source_unit := source_axis / source_length
	var target_unit := target_axis / target_length
	var source_across := source_unit.orthogonal()
	var target_across := target_unit.orthogonal()
	var offset := landmark - _vector(torso_definition.pivot)
	if preserves_proportions():
		return offset.rotated(target_axis.angle() - source_axis.angle()) * pixel_scale
	var along := offset.dot(source_unit) / source_length * target_length
	var across := offset.dot(source_across) / source_width * float(shape().torso)
	return target_unit * along + target_across * across

func arm_root_offset(side: String, torso_axis: Vector2 = Vector2.DOWN) -> Vector2:
	if uses_authored_shoulders():
		var landmark := _vector(parts.torso.shoulders[0 if side == "left" else 1])
		return _torso_landmark_offset(landmark, torso_axis)
	# Older normalized assets use their established combat-space offsets. Rotate
	# only a pronounced lean; the normal six-pixel torso slope is intentional
	# depth separation and should not move the shoulder seam.
	var offset := Vector2(float(contract.shoulder_x), 6 if side == "right" else -4)
	if absf(torso_axis.x) > 12.0 and torso_axis.length() > 0.0:
		offset = offset.rotated(Vector2.DOWN.angle_to(torso_axis.normalized()))
	return _covered_arm_root_offset(offset, torso_axis)

func arm_control_reach(maximum: float) -> float:
	if not uses_authored_shoulders():
		return maximum
	# A shared torso-centered target circle must fit inside both arms' native
	# reach circles. This keeps equal forward reach without moving shoulders or
	# stretching sprites. Shoulder rotation does not change this radius.
	var reach := maximum
	for side in ["left", "right"]:
		var length := segment_length(side+"_upper_arm", 0.0) + segment_length(side+"_forearm", 0.0)
		reach = minf(reach, length - arm_root_offset(side).length() - 0.1)
	return maxf(0.0, reach)

func _torso_image_point(offset: Vector2, torso_axis: Vector2) -> Vector2:
	var torso_definition: Dictionary = parts.get("torso", {})
	var source_axis := _vector(torso_definition.get("tip", [0, 1])) - _vector(torso_definition.get("pivot", [0, 0]))
	var source_length := source_axis.length()
	var target_length := torso_axis.length()
	var source_width := float(torso_definition.get("source_width", 0.0))
	var torso_width := float(shape().torso)
	if source_length <= 0.0 or target_length <= 0.0 or source_width <= 0.0 or torso_width <= 0.0:
		return Vector2(-INF, -INF)
	var source_unit := source_axis / source_length
	var target_unit := torso_axis / target_length
	var source_across := source_unit.orthogonal()
	var target_across := target_unit.orthogonal()
	var along_scale := target_length / source_length
	var across_scale := torso_width / source_width
	var atlas_point := _vector(torso_definition.pivot)
	if preserves_proportions():
		atlas_point += offset.rotated(source_axis.angle() - torso_axis.angle()) / pixel_scale
		return atlas_point - _slot_origin("torso")
	atlas_point += source_unit * (offset.dot(target_unit) / along_scale)
	atlas_point += source_across * (offset.dot(target_across) / across_scale)
	return atlas_point - _slot_origin(String(torso_definition.source_slot))

func _torso_covers_offset(offset: Vector2, torso_axis: Vector2) -> bool:
	if torso_pixels == null:
		return true
	for sample in [Vector2.ZERO, Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var image_point := _torso_image_point(offset + sample * 3.0, torso_axis)
		var pixel := Vector2i(image_point.floor())
		if not Rect2i(Vector2i.ZERO, torso_pixels.get_size()).has_point(pixel) or torso_pixels.get_pixelv(pixel).a < 0.5:
			return false
	return true

func _covered_arm_root_offset(requested: Vector2, torso_axis: Vector2) -> Vector2:
	if torso_axis.length() <= 0.0 or _torso_covers_offset(requested, torso_axis):
		return requested
	# Move only along the depth axis. Forward combat reach remains the exact
	# contract value while the shoulder seam moves onto authored torso pixels.
	for distance in range(1, 19):
		for direction in [-1.0, 1.0]:
			var candidate := requested + Vector2(0.0, distance * direction)
			if _torso_covers_offset(candidate, torso_axis):
				return candidate
	return requested

func hip_offset(side: String, torso_axis: Vector2 = Vector2.DOWN) -> Vector2:
	if preserves_proportions() and parts.torso.has("hips"):
		var landmark := _vector(parts.torso.hips[0 if side == "left" else 1])
		return _torso_landmark_offset(landmark, torso_axis) - torso_axis
	return torso_axis.normalized().orthogonal() * float(shape().hip_spread) * (1 if side == "right" else -1)

func guard_offset(front: bool, beat: float) -> Vector2:
	return Vector2(62 + beat, -8 - beat) if front else Vector2(38 + beat, -40 - beat)

func _target_segment(part_name: String, joints: Dictionary) -> Array[Vector2]:
	var side := "left" if part_name.begins_with("left") else "right"
	match part_name:
		"head":
			var torso_axis: Vector2 = joints.hip - joints.shoulder
			var neck: Vector2
			var torso_definition: Dictionary = parts.get("torso", {})
			if torso_definition.has("neck") and float(torso_definition.get("source_width", 0.0)) > 0.0:
				# Standardized atlases may provide a measured neck landmark in the
				# five-point torso cell. Reuse the exact same affine mapping as the
				# torso Sprite2D, keeping the head attached to the authored artwork
				# instead of imposing a character-specific pixel offset.
				neck = joints.shoulder + _torso_landmark_offset(_vector(torso_definition.neck), torso_axis)
			else:
				# Older atlas profiles do not carry the optional measured landmark.
				# Keep their established contract behavior unchanged.
				neck = joints.shoulder - torso_axis*0.38 + torso_axis.normalized().orthogonal()*4.0
			if preserves_proportions():
				var source_torso_axis := _vector(torso_definition.tip)-_vector(torso_definition.pivot)
				var source_head_axis := _vector(parts.head.tip)-_vector(parts.head.pivot)
				var turn := torso_axis.angle()-source_torso_axis.angle()+head_tilt
				return [neck, neck+source_head_axis.rotated(turn)*pixel_scale]
			return [neck, neck + Vector2(0, -segment_length("head", float(shape().head_length))).rotated(head_tilt)]
		"torso": return [joints.shoulder, joints.hip]
		"left_upper_arm", "right_upper_arm": return [joints[side+"_shoulder"], joints[side+"_elbow"]]
		"left_forearm", "right_forearm": return [joints[side+"_elbow"], joints[side+"_hand"]]
		"left_thigh", "right_thigh": return [joints[side+"_hip"], joints[side+"_knee"]]
		"left_shin", "right_shin", "left_boot", "right_boot":
			var knee: Vector2 = joints[side+"_knee"]
			var foot: Vector2 = joints[side+"_foot"]
			if preserves_proportions() and joints.has(side+"_ankle"):
				var ankle: Vector2 = joints[side+"_ankle"]
				if part_name.ends_with("boot"):
					return [ankle, foot]
				return [knee, ankle]
			var direction := (foot-knee).normalized()
			# Planted soles stay level. Raised feet turn with the lower leg.
			var lift := clampf((-foot.y - 15.0)/40.0, 0.0, 1.0)
			direction = Vector2.DOWN.rotated(lerp_angle(0.0, Vector2.DOWN.angle_to(direction), lift))
			# Both images share the cuff, including when the leg points upward.
			var cuff := foot - direction * minf(float(shape().boot_length), knee.distance_to(foot)*0.65)
			if part_name.ends_with("boot"):
				return [cuff, foot]
			return [knee, cuff]
	return [Vector2.ZERO, Vector2.RIGHT]

func apply_pose(joints: Dictionary, pose: Transform2D, facing: float, pixel_size: float = 1.0) -> void:
	pose_root.transform = pose * Transform2D(0.0, Vector2(pixel_size*facing, pixel_size), 0.0, Vector2.ZERO)
	var poses := {}
	for part_name in PART_ORDER:
		var definition: Dictionary = parts[part_name]
		var source_axis := _vector(definition.tip) - _vector(definition.pivot)
		var target := _target_segment(part_name, joints)
		var axis := target[1]-target[0]
		var desired := Transform2D(axis.angle(), target[0])
		var parent_name: String = contract.parents.get(part_name, "")
		var parent_pose: Transform2D = poses.get(parent_name, Transform2D.IDENTITY)
		var bone: Bone2D = bones[part_name]
		bone.transform = parent_pose.affine_inverse() * desired
		bone.set_length(axis.length())
		poses[part_name] = desired
		var kind := part_name.trim_prefix("left_").trim_prefix("right_")
		bone.z_index = int(Z_BY_PART[part_name])
		var fit: Transform2D
		if preserves_proportions():
			fit = Transform2D(-source_axis.angle(), Vector2.ZERO).scaled(Vector2.ONE * pixel_scale)
		else:
			fit = Transform2D(0.0, Vector2(axis.length()/source_axis.length(), float(shape()[kind])/float(definition.source_width)), 0.0, Vector2.ZERO) * Transform2D(-source_axis.angle(), Vector2.ZERO)
		var sprite: Sprite2D = sprites[part_name]
		var pivot := _vector(definition.pivot) - _slot_origin(definition.source_slot) - sprite.texture.get_size()*0.5
		fit.origin = -fit.basis_xform(pivot)
		sprite.transform = fit
