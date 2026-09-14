class_name VirtualPad
extends Control

signal direction_changed(direction: Vector2)

@export var pad_radius := 56.0
@export var knob_radius := 20.0
var direction := Vector2.ZERO
var touching := false
var knob := Vector2.ZERO

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(150, 150)
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			touching = true
			_update_knob(event.position - global_position)
		else:
			touching = false
			_reset()
	elif event is InputEventScreenDrag:
		_update_knob(event.position - global_position)
	elif event is InputEventMouseButton and not OS.has_feature("mobile") and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			touching = true
			_update_knob(event.position)
		else:
			touching = false
			_reset()
	elif event is InputEventMouseMotion and not OS.has_feature("mobile") and touching:
		_update_knob(event.position)

func _update_knob(point: Vector2) -> void:
	var center := size * 0.5
	knob = (point - center).limit_length(pad_radius)
	direction = (knob / pad_radius).clamp(Vector2(-1, -1), Vector2(1, 1))
	direction_changed.emit(direction)
	queue_redraw()

func _reset() -> void:
	direction = Vector2.ZERO
	knob = Vector2.ZERO
	direction_changed.emit(direction)
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	draw_circle(center, pad_radius + 5.0, Color(0.09, 0.08, 0.21, 0.86))
	draw_arc(center, pad_radius + 5.0, 0.0, TAU, 32, Color(0.45, 0.36, 0.83, 0.8), 2.0)
	draw_circle(center, pad_radius, Color(0.16, 0.14, 0.31, 0.9))
	draw_circle(center + knob, knob_radius, Color(0.55, 0.92, 0.76, 0.95))
	draw_arc(center + knob, knob_radius, 0.0, TAU, 20, Color("#15132c"), 2.0)
