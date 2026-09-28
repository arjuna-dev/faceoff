extends SceneTree
## Run with --main-pack from outside the project, so loose files cannot hide
## a missing exported JSON or texture. This script itself is not shipped.
const RigSkinType = preload("res://scripts/characters/skeleton_rig_skin.gd")

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var failures := 0
	for style in ["batyr", "oculon", "armk", "magician"]:
		if not RigSkinType.has_profile(style):
			push_error("Exported rig metadata is missing or invalid: "+style)
			failures += 1
			continue
		var skin := RigSkinType.new()
		root.add_child(skin)
		skin.configure(style)
		if skin.bones.size() != 12 or skin.sprites.size() != 12:
			failures += 1
		for sprite in skin.sprites.values():
			if sprite.texture == null or sprite.texture.get_size().x <= 0:
				failures += 1
		skin.queue_free()
	await process_frame
	print("Exported fighter rigs: "+("PASS" if failures == 0 else "FAIL"))
	quit(1 if failures else 0)
