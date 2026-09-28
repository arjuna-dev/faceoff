extends SceneTree
## Render the saved, script-free inspection scene and each visibility preset.
class JointOverlay extends Node2D:
	var bones: Array = []
	func _draw() -> void:
		for bone in bones:
			var point: Vector2 = bone.global_position
			draw_arc(point, 5, 0, TAU, 24, Color.CYAN, 1.5)
			for child in bone.get_children():
				if child is Bone2D:
					draw_line(point, child.global_position, Color(0,1,1,0.65), 1)

func _init() -> void:
	call_deferred("_run")

func _find_bones(node: Node, found: Array) -> void:
	if node is Bone2D:
		found.append(node)
	for child in node.get_children():
		_find_bones(child, found)

func _run() -> void:
	var scene_path := ""
	var directory := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scene="):
			scene_path = argument.trim_prefix("--scene=")
		if argument.begins_with("--output-dir="):
			directory = argument.trim_prefix("--output-dir=")
	if DisplayServer.get_name() == "headless" or scene_path.is_empty() or directory.is_empty():
		push_error("Supply a real renderer, --scene and --output-dir")
		quit(1)
		return
	RenderingServer.set_default_clear_color(Color("20252d"))
	var packed: PackedScene = load(scene_path)
	var scene := packed.instantiate()
	root.add_child(scene)
	var overlay := JointOverlay.new()
	overlay.z_index = 100
	root.add_child(overlay)
	DirAccess.make_dir_recursive_absolute(directory)
	for name in ["GameGuard", "RearArmOnly", "SourceRest"]:
		for group in scene.get_children():
			group.visible = group.name == name
		overlay.bones.clear()
		_find_bones(scene.get_node(name), overlay.bones)
		overlay.queue_redraw()
		await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		var image := root.get_texture().get_image()
		if image.save_png(directory.path_join(name+".png")) != OK:
			push_error("Inspection capture failed")
			quit(1)
			return
	scene.free()
	overlay.free()
	print("Inspection scene captures: "+directory)
	quit()
