extends SceneTree

## Renders a whole-character candidate scene in Godot's real renderer at rest
## and in a few bone poses. Usage (needs a window, not --headless):
##   godot --path . -s tools/capture_whole_character_scene.gd -- <res://scene.tscn> <output_dir>

const POSES := {
	"rest": {},
	"guard": {"NearUpperArmBone": -65.0, "NearForearmHandBone": -55.0, "FarUpperArmBone": 65.0, "FarForearmHandBone": 55.0},
	"high_kick": {"TorsoPelvisBone": -10.0, "HeadNeckBone": 10.0, "NearThighBone": -100.0, "NearShinBone": 35.0, "NearFootBone": 65.0},
	"victory": {"NearUpperArmBone": -165.0, "NearForearmHandBone": -20.0, "FarUpperArmBone": 160.0, "FarForearmHandBone": 25.0},
}

func _init() -> void:
	call_deferred("_run")

func _bones(node: Node, found: Dictionary) -> void:
	if node is Bone2D:
		found[node.name] = node
	for child in node.get_children():
		_bones(child, found)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: -- <res://scene.tscn> <output_dir>")
		quit(2)
		return
	var packed: PackedScene = load(args[0])
	if packed == null:
		push_error("could not load " + args[0])
		quit(1)
		return
	# An off-screen viewport, so the project's stretch settings cannot crop the capture.
	var view := SubViewport.new()
	view.size = Vector2i(1600, 1600)
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var backdrop := ColorRect.new()
	backdrop.color = Color("22252d")
	backdrop.size = Vector2(1600, 1600)
	view.add_child(backdrop)
	var rig: Node2D = packed.instantiate()
	view.add_child(rig)
	var bones := {}
	_bones(rig, bones)
	print("bones: ", bones.size())
	# Center the character: the scene is in source-canvas pixels from the origin.
	rig.scale = Vector2.ONE * 0.9
	rig.position = Vector2(180, 180)
	DirAccess.make_dir_recursive_absolute(args[1])
	for pose_name in POSES:
		for bone in bones.values():
			bone.rotation = 0.0
		var angles: Dictionary = POSES[pose_name]
		for bone_name in angles:
			if bones.has(bone_name):
				bones[bone_name].rotation_degrees = angles[bone_name]
		await process_frame
		await process_frame
		view.get_texture().get_image().save_png(args[1].path_join(pose_name + ".png"))
	quit(0)
