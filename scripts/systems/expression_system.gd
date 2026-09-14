class_name ExpressionSystem
extends Node

signal expression_changed(expression_id: String)

var profile: CharacterProfile
var face_node: Node2D
var chest_node: Node2D
var quirk_node: Node2D
var current_expression := "default"
var time_left := 0.0
var pulse_strength := 0.0

func setup(p_profile: CharacterProfile, p_face: Node2D, p_chest: Node2D, p_quirk: Node2D) -> void:
	profile = p_profile
	face_node = p_face
	chest_node = p_chest
	quirk_node = p_quirk
	_apply_nodes()

func trigger(expression_id: String, duration: float = 2.2) -> void:
	if not profile:
		return
	current_expression = expression_id
	time_left = duration
	pulse_strength = 1.0 if expression_id == "love" else 0.45
	_apply_nodes()
	expression_changed.emit(expression_id)

func set_video_face_active(enabled: bool) -> void:
	if face_node and face_node.has_method("set_video_face_active"):
		face_node.set_video_face_active(enabled)

func set_video_face_texture(texture: Texture2D) -> void:
	if face_node and face_node.has_method("set_video_face_texture"):
		face_node.set_video_face_texture(texture)

func clear_video_face_texture() -> void:
	if face_node and face_node.has_method("clear_video_face_texture"):
		face_node.clear_video_face_texture()

func _process(delta: float) -> void:
	if time_left > 0.0:
		time_left -= delta
		if time_left <= 0.0:
			current_expression = "default"
			pulse_strength = 0.0
			_apply_nodes()
	if chest_node and pulse_strength > 0.0:
		var pulse := 1.0 + sin(Time.get_ticks_msec() * 0.012) * 0.12 * pulse_strength
		chest_node.scale = Vector2.ONE * pulse
	elif chest_node:
		chest_node.scale = Vector2.ONE

func _apply_nodes() -> void:
	if not profile or not face_node or not chest_node or not quirk_node:
		return
	if face_node.has_method("set_face"):
		face_node.set_face(profile.expression_face(current_expression), profile.secondary_color)
	if chest_node.has_method("set_chest"):
		var chest_text := ""
		var chest_color := profile.accent_color
		match current_expression:
			"love":
				chest_text = "♥"
				chest_color = Color("#ff5d8f")
			"shock":
				chest_text = "!"
				chest_color = Color("#fff1a8")
			"laughter": chest_text = "HA"
			"anger":
				chest_text = "!!"
				chest_color = Color("#ff6b6b")
			"confusion":
				chest_text = "?"
				chest_color = Color("#b8a7ff")
			"celebration": chest_text = "★"
		chest_node.set_chest(chest_text, chest_color)
	if quirk_node.has_method("set_quirk"):
		quirk_node.set_quirk("" if current_expression == "default" else "! " + current_expression.to_upper(), profile.accent_color)
