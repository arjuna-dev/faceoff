class_name SpriteAnimationPlayer
extends Node2D

## Plays one frame-by-frame sprite animation where a fighter's rest pose stands.
## Frames come from tools/sprite_animation_workflow.py: they are aligned to the
## fighter's base image, so the animation starts from and lands in the rest pose.

signal finished(state: String)

const SPRITES_ROOT := "res://assets/fighters/%s/sprites/"

var manifest: Dictionary = {}
var animation: Dictionary = {}
var frame_index := 0
var frame_elapsed_ms := 0.0
var sprite: Sprite2D
var textures: Array[Texture2D] = []
var playing := false

static func load_manifest(sprite_set: String) -> Dictionary:
	if sprite_set.is_empty():
		return {}
	var path := (SPRITES_ROOT % sprite_set) + "index.json"
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("animations"):
		return {}
	parsed["root"] = SPRITES_ROOT % sprite_set
	return parsed

static func load_frame(path: String) -> Texture2D:
	# Imported textures in exported builds; raw PNG while developing before an import.
	if ResourceLoader.exists(path):
		return load(path)
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(image) if image else null

## Starts `state` at `feet` (the fighter's ground point), scaled so the base
## character is `character_height` pixels tall, mirrored when `facing` < 0.
func play(sprite_manifest: Dictionary, state: String, feet: Vector2, character_height: float, facing: float) -> bool:
	manifest = sprite_manifest
	animation = {}
	for entry in manifest.get("animations", []):
		if entry.get("state", "") == state:
			animation = entry
	if animation.is_empty():
		return false
	textures.clear()
	for name in animation["frames"]:
		var texture := load_frame(String(manifest["root"]) + String(name))
		if texture == null:
			return false
		textures.append(texture)
	var bbox: Array = manifest["base_bbox"]
	var scale_factor: float = character_height / maxf(1.0, float(bbox[3]) - float(bbox[1]))
	if sprite == null:
		sprite = Sprite2D.new()
		sprite.centered = false
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(sprite)
	var origin: Array = animation["origin"]
	var size: Array = animation["frame_size"]
	# Frame origin relative to the base image's feet center, in base pixels.
	var local := Vector2(float(origin[0]) - (float(bbox[0]) + float(bbox[2])) * 0.5, float(origin[1]) - float(bbox[3]))
	sprite.flip_h = facing < 0.0
	if facing < 0.0:
		local.x = -local.x - float(size[0])
	sprite.scale = Vector2.ONE * scale_factor
	sprite.position = local * scale_factor
	global_position = feet
	frame_index = 0
	frame_elapsed_ms = 0.0
	sprite.texture = textures[0]
	playing = true
	visible = true
	return true

func stop() -> void:
	playing = false
	visible = false

func _process(delta: float) -> void:
	if not playing:
		return
	frame_elapsed_ms += delta * 1000.0
	var durations: Array = animation["durations_ms"]
	while playing and frame_elapsed_ms >= float(durations[frame_index]):
		frame_elapsed_ms -= float(durations[frame_index])
		frame_index += 1
		if frame_index >= textures.size():
			stop()
			finished.emit(String(animation["state"]))
			return
		sprite.texture = textures[frame_index]
