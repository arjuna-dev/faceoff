extends SceneTree

## Screenshots of the ACTION! row and a sprite animation mid-play (needs a real viewport).

const MainScene = preload("res://scenes/main.tscn")
var main: Node

func _init() -> void:
	call_deferred("_run")

func _capture(name: String) -> void:
	await process_frame
	await process_frame
	var viewport_texture := root.get_texture()
	if viewport_texture == null:
		push_error("A real viewport is required for captures.")
		quit(2)
		return
	viewport_texture.get_image().save_png("res://tests/" + name + ".png")

func _run() -> void:
	main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	main._on_demo_requested()
	main._on_fighter_selection_confirmed("batyr", "kiro")
	await process_frame
	main.action_button.emit_signal("pressed")
	for i in 20:
		await process_frame
	await _capture("sprite-actions-row")
	main.action_buttons[0].emit_signal("pressed")
	for i in 3:
		main.sprite_player._process(0.16)
	await _capture("sprite-actions-playing")
	quit(0)
