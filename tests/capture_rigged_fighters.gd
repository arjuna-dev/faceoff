extends SceneTree
## Actual production renderer; a dummy headless viewport is never accepted.
const MainScene = preload("res://scenes/main.tscn")
const PoseCases = preload("res://tests/rig_pose_cases.gd")
var main: Node
var caption: Label
var output_dir := "res://tests/rig-validation"
var candidate_dir := ""
var capture_fighter_id := "batyr"

class ShoulderOverlay extends Node2D:
	var fighters: Array = []
	var only_shoulders := true
	func _draw() -> void:
		for fighter in fighters:
			var skin: SkeletonRigSkin = fighter.skeleton_skin
			if not skin.uses_authored_shoulders():
				continue
			for item in skin.coordinate_reference.points:
				if only_shoulders and item.field != "shoulders":
					continue
				var sprite: Sprite2D = skin.sprites[item.part]
				var local := skin._vector(item.crop_local)-sprite.texture.get_size()*0.5
				var expected := sprite.get_global_transform_with_canvas()*local
				var actual := skin.skeleton.get_global_transform_with_canvas()*PoseCases.coordinate_target(fighter, item)
				draw_arc(expected, 7.0, 0.0, TAU, 32, Color.CYAN, 2.0)
				draw_line(actual-Vector2(4,0), actual+Vector2(4,0), Color.YELLOW, 2.0)
				draw_line(actual-Vector2(0,4), actual+Vector2(0,4), Color.YELLOW, 2.0)

func _init() -> void:
	call_deferred("_run")

func capture(label: String) -> Image:
	caption.text = label
	main.player.queue_redraw()
	main.opponent.queue_redraw()
	await process_frame
	await process_frame
	# A background/minimized macOS window may skip its normal draw signal.
	# Force a real renderer draw before GPU readback instead of waiting forever.
	RenderingServer.force_draw(false)
	var texture := root.get_texture()
	if texture == null:
		push_error("Real graphics output is required")
		quit(2)
		return null
	return texture.get_image()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Use OpenGL, or xvfb-run on Linux, for visual review")
		quit(2)
		return
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output-dir="):
			output_dir = argument.trim_prefix("--output-dir=")
		if argument.begins_with("--rig-dir="):
			candidate_dir = argument.trim_prefix("--rig-dir=")
	if not candidate_dir.is_empty():
		var candidate_profile: Variant = JSON.parse_string(FileAccess.get_file_as_string(candidate_dir.path_join("profile.json")))
		if candidate_profile is Dictionary and not String(candidate_profile.get("fighter_id", "")).is_empty():
			capture_fighter_id = String(candidate_profile.get("fighter_id"))
	DirAccess.make_dir_recursive_absolute(output_dir)
	main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	await process_frame
	main.fighter_select.card_buttons[capture_fighter_id].emit_signal("pressed")
	main.fighter_select.card_buttons[capture_fighter_id].emit_signal("pressed")
	await process_frame
	RenderingServer.force_draw(false)
	var selection_texture := root.get_texture()
	if selection_texture == null:
		push_error("Real graphics output is required")
		quit(2)
		return
	selection_texture.get_image().save_png(output_dir.path_join("fighter-select.png"))
	main._on_fighter_selection_confirmed(capture_fighter_id, capture_fighter_id)
	await process_frame
	main.set_physics_process(false)
	for fighter in [main.player, main.opponent]:
		fighter.set_physics_process(false)
		if not candidate_dir.is_empty():
			if not PoseCases.install_candidate(fighter, candidate_dir):
				quit(2)
				return
	var overlay := CanvasLayer.new()
	overlay.layer = 100
	root.add_child(overlay)
	caption = Label.new()
	caption.position = Vector2(250, 163)
	caption.add_theme_color_override("font_color", Color.WHITE)
	caption.add_theme_color_override("font_outline_color", Color.BLACK)
	caption.add_theme_constant_override("outline_size", 6)
	overlay.add_child(caption)
	# Close crops retain real gameplay pixels and make joints readable in review.
	var region := Rect2i(180, 110, 590, 365)
	var matrix := Image.create_empty(region.size.x*3, region.size.y*5, false, Image.FORMAT_RGBA8)
	matrix.fill(Color("202020"))
	for index in PoseCases.NAMES.size():
		var pose: String = PoseCases.NAMES[index]
		for fighter in [main.player, main.opponent]:
			PoseCases.apply(fighter, pose)
		var frame := await capture(pose)
		frame.save_png(output_dir.path_join(pose+".png"))
		matrix.blit_rect(frame, region, Vector2i((index%3)*region.size.x, (index/3)*region.size.y))
	matrix.save_png(output_dir.path_join("poses.png"))
	var shapes := SkeletonRigSkin.body_type_names()
	var shape_matrix := Image.create_empty(region.size.x*2, region.size.y*5, false, Image.FORMAT_RGBA8)
	for index in shapes.size():
		for facing_index in 2:
			for fighter in [main.player, main.opponent]:
				fighter.skeleton_skin.body_type = shapes[index]
				fighter.facing_direction = (1.0 if fighter == main.player else -1.0) * (1.0 if facing_index == 0 else -1.0)
				PoseCases.apply(fighter, "guard")
			var frame := await capture(shapes[index]+(" / inward" if facing_index == 0 else " / mirrored"))
			shape_matrix.blit_rect(frame, region, Vector2i(facing_index*region.size.x,index*region.size.y))
	shape_matrix.save_png(output_dir.path_join("body-types.png"))
	for fighter in [main.player, main.opponent]:
		fighter.skeleton_skin.body_type = "standard"
		fighter.facing_direction = 1.0 if fighter == main.player else -1.0
		PoseCases.apply(fighter, "guard")
	var shoulders := ShoulderOverlay.new()
	shoulders.fighters = [main.player, main.opponent]
	overlay.add_child(shoulders)
	var diagnostic := await capture("cyan ring: torso marker / yellow cross: arm pivot")
	diagnostic.save_png(output_dir.path_join("shoulder-diagnostics.png"))
	shoulders.only_shoulders = false
	shoulders.queue_redraw()
	var all_coordinates := await capture("29 points / cyan: source coordinates / yellow: Godot joints")
	all_coordinates.save_png(output_dir.path_join("coordinate-diagnostics.png"))
	var report := PoseCases.evidence([main.player, main.opponent])
	report.shoulder_attachments = [PoseCases.shoulder_evidence(main.player), PoseCases.shoulder_evidence(main.opponent)]
	report.coordinate_audit = [PoseCases.coordinate_evidence(main.player), PoseCases.coordinate_evidence(main.opponent)]
	report.rest_coordinate_audit = [PoseCases.rest_coordinate_evidence(main.player), PoseCases.rest_coordinate_evidence(main.opponent)]
	report.complete = true
	report.renderer = RenderingServer.get_current_rendering_method()
	FileAccess.open(output_dir.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify(report,"  ")+"\n")
	print("Visual captures: "+output_dir)
	main.queue_free()
	overlay.queue_free()
	await process_frame
	quit()
