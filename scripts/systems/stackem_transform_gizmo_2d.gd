class_name StackemTransformGizmo2D
extends Node2D

var target: RagdollCharacter

func setup(p_target: RagdollCharacter) -> void:
	target = p_target
	z_index = 10

func _process(_delta: float) -> void:
	if not target or not is_instance_valid(target):
		return
	global_position = target.get_selected_limb_node().global_position
	queue_redraw()

func _draw() -> void:
	if not target:
		return
	var pulse := 24.0 + sin(Time.get_ticks_msec() * 0.008) * 2.0
	draw_arc(Vector2.ZERO, pulse, 0.0, TAU, 20, Color("#ffd166"), 2.0)
	draw_line(Vector2(-pulse - 7, 0), Vector2(-pulse + 1, 0), Color("#61e8db"), 2.0)
	draw_line(Vector2(pulse - 1, 0), Vector2(pulse + 7, 0), Color("#61e8db"), 2.0)
