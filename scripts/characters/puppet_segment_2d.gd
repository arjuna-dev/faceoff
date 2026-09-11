class_name PuppetSegment2D
extends Node2D

const FIGHTER_ASSETS := {
	"batyr": {
		"head": preload("res://assets/fighters/batyr/head.png"),
		"torso": preload("res://assets/fighters/batyr/torso.png"),
		"left_upper_arm": preload("res://assets/fighters/batyr/left_upper_arm.png"),
		"left_forearm": preload("res://assets/fighters/batyr/left_forearm.png"),
		"right_upper_arm": preload("res://assets/fighters/batyr/right_upper_arm.png"),
		"right_forearm": preload("res://assets/fighters/batyr/right_forearm.png"),
		"left_thigh": preload("res://assets/fighters/batyr/left_thigh.png"),
		"left_shin": preload("res://assets/fighters/batyr/left_shin.png"),
		"right_thigh": preload("res://assets/fighters/batyr/right_thigh.png"),
		"right_shin": preload("res://assets/fighters/batyr/right_shin.png"),
	},
	"kiro": {
		"head": preload("res://assets/fighters/kiro/head.png"),
		"torso": preload("res://assets/fighters/kiro/torso.png"),
		"left_upper_arm": preload("res://assets/fighters/kiro/left_upper_arm.png"),
		"left_forearm": preload("res://assets/fighters/kiro/left_forearm.png"),
		"right_upper_arm": preload("res://assets/fighters/kiro/right_upper_arm.png"),
		"right_forearm": preload("res://assets/fighters/kiro/right_forearm.png"),
		"left_thigh": preload("res://assets/fighters/kiro/left_thigh.png"),
		"left_shin": preload("res://assets/fighters/kiro/left_shin.png"),
		"right_thigh": preload("res://assets/fighters/kiro/right_thigh.png"),
		"right_shin": preload("res://assets/fighters/kiro/right_shin.png"),
	},
	"moxie": {
		"head": preload("res://assets/fighters/moxie/head.png"),
		"torso": preload("res://assets/fighters/moxie/torso.png"),
		"left_upper_arm": preload("res://assets/fighters/moxie/left_upper_arm.png"),
		"left_forearm": preload("res://assets/fighters/moxie/left_forearm.png"),
		"right_upper_arm": preload("res://assets/fighters/moxie/right_upper_arm.png"),
		"right_forearm": preload("res://assets/fighters/moxie/right_forearm.png"),
		"left_thigh": preload("res://assets/fighters/moxie/left_thigh.png"),
		"left_shin": preload("res://assets/fighters/moxie/left_shin.png"),
		"right_thigh": preload("res://assets/fighters/moxie/right_thigh.png"),
		"right_shin": preload("res://assets/fighters/moxie/right_shin.png"),
	},
	"rivet": {
		"head": preload("res://assets/fighters/rivet/head.png"),
		"torso": preload("res://assets/fighters/rivet/torso.png"),
		"left_upper_arm": preload("res://assets/fighters/rivet/left_upper_arm.png"),
		"left_forearm": preload("res://assets/fighters/rivet/left_forearm.png"),
		"right_upper_arm": preload("res://assets/fighters/rivet/right_upper_arm.png"),
		"right_forearm": preload("res://assets/fighters/rivet/right_forearm.png"),
		"left_thigh": preload("res://assets/fighters/rivet/left_thigh.png"),
		"left_shin": preload("res://assets/fighters/rivet/left_shin.png"),
		"right_thigh": preload("res://assets/fighters/rivet/right_thigh.png"),
		"right_shin": preload("res://assets/fighters/rivet/right_shin.png"),
	},
}

var segment_name := "limb"
var segment_size := Vector2(20, 60)
var primary_color := Color.WHITE
var secondary_color := Color.WHITE
var accent_color := Color.WHITE
var style_id := "moxie"
var face_text := ""
var chest_text := ""
var quirk_text := ""
var face_color := Color.WHITE
var chest_color := Color.WHITE
var video_face_active := false
var asset_texture: Texture2D
var walk_active := false
var walk_phase := 0.0

func configure(p_name: String, p_size: Vector2, p_primary: Color, p_secondary: Color, p_accent: Color, p_style_id: String = "moxie") -> void:
	segment_name = p_name
	segment_size = p_size
	primary_color = p_primary
	secondary_color = p_secondary
	accent_color = p_accent
	style_id = p_style_id
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var fighter_assets: Dictionary = FIGHTER_ASSETS.get(style_id, {})
	asset_texture = fighter_assets.get(segment_name) as Texture2D
	face_color = secondary_color
	chest_color = accent_color
	queue_redraw()

func set_face(value: String, color: Color = Color.WHITE) -> void:
	face_text = value
	if color != Color.WHITE:
		face_color = color
	queue_redraw()

func set_chest(value: String, color: Color = Color.WHITE) -> void:
	chest_text = value
	if color != Color.WHITE:
		chest_color = color
	queue_redraw()

func set_quirk(value: String, color: Color = Color.WHITE) -> void:
	quirk_text = value
	if color != Color.WHITE:
		accent_color = color
	queue_redraw()

func set_video_face_active(enabled: bool) -> void:
	video_face_active = enabled
	queue_redraw()

func set_walk_state(enabled: bool, phase: float) -> void:
	walk_active = enabled
	walk_phase = phase
	queue_redraw()

func _draw() -> void:
	var half := segment_size * 0.5
	var outline := Color("#111025")
	if asset_texture and not (segment_name == "head" and video_face_active):
		_draw_asset_texture()
		_draw_expression_overlay(half)
		_draw_walk_fx(half)
		return
	if segment_name == "head":
		_draw_head(half, outline)
	elif segment_name == "torso":
		_draw_torso(half, outline)
	else:
		_draw_limb(half, outline)

func _draw_asset_texture() -> void:
	var source_size := asset_texture.get_size()
	if source_size.y <= 0.0:
		return
	var draw_height := segment_size.y * (1.18 if segment_name == "head" else 1.12)
	var draw_size := source_size * (draw_height / source_size.y)
	var sprite_offset := Vector2.ZERO
	if walk_active and segment_name in ["torso", "head"]:
		# Quantized one-pixel bob keeps the gait visibly sprite-like without
		# disconnecting art from the authoritative physics joints.
		sprite_offset.y = roundf(sin(walk_phase * 2.0))
	var destination := Rect2(-draw_size * 0.5 + sprite_offset, draw_size)
	draw_texture_rect(asset_texture, destination, false)

func _draw_walk_fx(half: Vector2) -> void:
	if not walk_active or not segment_name.ends_with("_shin"):
		return
	var side_phase := walk_phase + (0.0 if segment_name.begins_with("left") else PI)
	if sin(side_phase) < 0.72:
		return
	var dust_color := Color(0.94, 0.72, 0.38, 0.45)
	draw_rect(Rect2(Vector2(-half.x - 5, half.y + 2), Vector2(5, 2)), dust_color)
	draw_rect(Rect2(Vector2(half.x + 1, half.y + 5), Vector2(3, 2)), dust_color)

func _draw_expression_overlay(half: Vector2) -> void:
	if segment_name == "head" and not face_text.is_empty() and face_text not in [":]", "._."]:
		draw_rect(Rect2(-half.x, half.y - 8, segment_size.x, 17), Color(0.04, 0.03, 0.12, 0.86))
		_draw_centered_text(face_text, Vector2(-half.x, half.y + 5), segment_size.x, 12, face_color)
	elif segment_name == "torso":
		if not chest_text.is_empty():
			draw_circle(Vector2(0, -4), 12.0, Color(0.04, 0.03, 0.12, 0.78))
			_draw_centered_text(chest_text, Vector2(-half.x, 2), segment_size.x, 13, chest_color)
		if not quirk_text.is_empty():
			_draw_centered_text(quirk_text, Vector2(-half.x - 26, half.y + 17), segment_size.x + 52, 8, accent_color)

func _draw_head(half: Vector2, outline: Color) -> void:
	var radius := minf(half.x, half.y) - 2.0
	if video_face_active:
		draw_circle(Vector2(0, 0), radius + 4, outline)
		draw_circle(Vector2(0, 0), radius, Color("#5de2d1"))
		draw_arc(Vector2(0, 0), radius - 4, 0.0, TAU, 12, Color("#e7fff5"), 2.0)
	else:
		draw_circle(Vector2(0, 0), radius + 4, outline)
		draw_circle(Vector2(0, 0), radius, secondary_color)
		if style_id == "moxie":
			draw_colored_polygon(PackedVector2Array([
				Vector2(-radius, -radius * 0.45), Vector2(-radius * 0.72, -radius - 8),
				Vector2(-radius * 0.2, -radius * 0.58), Vector2(radius * 0.2, -radius - 12),
				Vector2(radius * 0.72, -radius * 0.55), Vector2(radius, -radius * 0.35)
			]), primary_color)
			draw_rect(Rect2(-radius, -radius * 0.15, radius * 2.0, 7.0), accent_color)
		else:
			draw_colored_polygon(PackedVector2Array([
				Vector2(-radius, -radius * 0.55), Vector2(-radius * 0.55, -radius),
				Vector2(radius * 0.55, -radius), Vector2(radius, -radius * 0.55),
				Vector2(radius * 0.72, radius * 0.05), Vector2(-radius * 0.72, radius * 0.05)
			]), primary_color)
			draw_rect(Rect2(-radius * 0.82, -radius * 0.18, radius * 1.64, 13.0), accent_color)
			draw_line(Vector2(-radius * 0.56, -radius * 0.5), Vector2(radius * 0.56, -radius * 0.5), accent_color, 3.0)
	var text := "VIDEO" if video_face_active else face_text
	_draw_centered_text(text, Vector2(-half.x, -5), segment_size.x, 13, face_color)

func _draw_torso(half: Vector2, outline: Color) -> void:
	var body := Rect2(-half + Vector2(0, 2), segment_size - Vector2(0, 4))
	draw_rect(body.grow(4), outline)
	draw_rect(body, primary_color)
	draw_rect(Rect2(-half.x + 5, -half.y + 9, segment_size.x - 10, 5), secondary_color)
	draw_line(Vector2(0, -half.y + 18), Vector2(0, half.y - 12), accent_color, 3.0)
	if style_id == "moxie":
		draw_rect(Rect2(-half.x - 4, -half.y + 7, 8, 23), secondary_color)
		draw_rect(Rect2(half.x - 4, -half.y + 7, 8, 23), secondary_color)
		draw_line(Vector2(-half.x + 6, half.y - 17), Vector2(half.x - 6, half.y - 17), Color("#ffdc70"), 5.0)
	else:
		draw_rect(Rect2(-half.x + 8, -half.y + 27, segment_size.x - 16, 18), Color("#252047"))
		draw_line(Vector2(-half.x + 9, -half.y + 28), Vector2(half.x - 9, -half.y + 28), Color("#8de9ff"), 3.0)
	if chest_text != "":
		_draw_centered_text(chest_text, Vector2(-half.x, 7), segment_size.x, 18, chest_color)
	if quirk_text != "":
		_draw_centered_text(quirk_text, Vector2(-half.x - 18, half.y + 18), segment_size.x + 36, 9, accent_color)

func _draw_limb(half: Vector2, outline: Color) -> void:
	var radius := minf(half.x, 10.0)
	var body_height := maxf(half.y * 2.0 - radius * 2.0, 4.0)
	draw_rect(Rect2(-radius - 3, -body_height * 0.5 - 3, radius * 2.0 + 6, body_height + 6), outline)
	draw_rect(Rect2(-radius, -body_height * 0.5, radius * 2.0, body_height), primary_color)
	draw_circle(Vector2(0, -body_height * 0.5), radius, primary_color)
	draw_circle(Vector2(0, body_height * 0.5), radius, secondary_color)
	draw_line(Vector2(0, -body_height * 0.32), Vector2(0, body_height * 0.32), accent_color, 2.0)
	if segment_name.contains("forearm"):
		draw_circle(Vector2(0, body_height * 0.5 + radius * 0.5), radius + 4.0, accent_color)
	elif segment_name.contains("shin"):
		draw_rect(Rect2(-radius - 3, body_height * 0.28, radius * 2.0 + 6, 8.0), accent_color)

func _draw_centered_text(text: String, origin: Vector2, width: float, font_size: int, color: Color) -> void:
	if text.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	draw_string(font, origin, text, HORIZONTAL_ALIGNMENT_CENTER, width, font_size, color)
