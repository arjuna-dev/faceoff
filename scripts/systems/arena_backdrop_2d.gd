class_name ArenaBackdrop2D
extends Node2D

const MARKET_TEXTURE := preload("res://assets/backgrounds/thailand_marketplace.png")

@export var ambient_motion_enabled := true
var elapsed := 0.0

func _ready() -> void:
	z_index = -20
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()

func _process(delta: float) -> void:
	if ambient_motion_enabled:
		elapsed += delta
	queue_redraw()

func _draw() -> void:
	draw_texture_rect(MARKET_TEXTURE, Rect2(0, 0, 960, 540), false)
	# Warm lantern pulse: visual-only, cheap, and disabled with ambient_motion_enabled.
	var pulse_time := elapsed if ambient_motion_enabled else 0.0
	var lanterns := [Vector2(315, 118), Vector2(389, 122), Vector2(454, 126), Vector2(536, 124), Vector2(621, 121)]
	for index in lanterns.size():
		var glow := 0.055 + sin(pulse_time * 2.1 + index * 0.8) * 0.018
		draw_circle(lanterns[index], 14.0, Color(1.0, 0.43, 0.12, glow))
	# Steam uses small alpha circles instead of particles to stay deterministic on mobile.
	for index in 5:
		var travel := fmod(pulse_time * 19.0 + index * 17.0, 72.0)
		var drift := sin(pulse_time * 1.7 + index) * 5.0
		var alpha := (1.0 - travel / 72.0) * 0.16
		draw_circle(Vector2(603 + drift, 295 - travel), 7.0 + index * 1.4, Color(0.92, 0.89, 0.78, alpha))
	# Two highlighted awning tips sway by only a few pixels, keeping motion peripheral.
	var sway := sin(pulse_time * 1.35) * 3.0
	draw_line(Vector2(258, 184), Vector2(270 + sway, 194), Color(0.96, 0.36, 0.3, 0.7), 3.0)
	draw_line(Vector2(676, 190), Vector2(666 - sway, 201), Color(0.18, 0.68, 0.63, 0.7), 3.0)
	# The collision floor remains readable without covering the generated marketplace art.
	draw_line(Vector2(18, 462), Vector2(942, 462), Color("#ffd166"), 2.0)
	draw_line(Vector2(18, 468), Vector2(942, 468), Color("#ff5aa7"), 1.0)
