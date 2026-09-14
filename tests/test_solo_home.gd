extends SceneTree

const SoloHomeType = preload("res://scripts/ui/solo_home.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var screen: SoloHome = SoloHomeType.new()
	root.add_child(screen)
	await process_frame
	var demo: Button
	var quick: Button
	for child in screen.get_children():
		if child is Button and child.text == "DEMO FIGHT":
			demo = child
		if child is Button and child.text.begins_with("QUICK FIGHT"):
			quick = child
	check(is_instance_valid(demo), "Chats screen exposes a Demo fight button")
	if is_instance_valid(demo):
		check(demo.pressed.get_connections().size() > 0, "Demo fight is wired to the demo action")
	check(is_instance_valid(quick), "Chats screen exposes a Quick Fight button")
	if is_instance_valid(quick):
		check(quick.pressed.get_connections().size() > 0, "Quick Fight is wired to matchmaking")
	print("Solo home: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
