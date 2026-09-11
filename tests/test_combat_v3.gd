extends SceneTree
const MainScene = preload("res://scenes/main.tscn")
var failures := 0
func _init() -> void:
	call_deferred("run")
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)
func advance(p: RagdollCharacter, seconds: float) -> void:
	for i in ceili(seconds * 60):
		p._physics_process(1.0 / 60.0)
func run() -> void:
	var main := MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var p: RagdollCharacter = main.player
	var o: RagdollCharacter = main.opponent
	# Slow lifting extends stance without jumping; a quick diagonal swipe launches.
	var torso := p.get_world_center()
	p._start_pointer_drag_at(torso, 1)
	p._update_pointer_drag(1, torso + Vector2(0, -20), 0.2)
	check(p.stance_height == 20 and not p.is_jumping, "slow upward torso drag straightens legs")
	p._update_pointer_drag(1, torso + Vector2(55, -80), 0.08)
	check(p.is_jumping and p.jump_velocity.x > 0, "fast upward diagonal torso drag jumps diagonally")
	p._end_pointer_drag(1)
	var x := p.position.x
	advance(p, 0.2)
	check(p.jump_height > 30 and p.position.x > x and not p.is_fallen, "jump has height, direction and support exemption")
	advance(p, 1.2)
	check(not p.is_jumping and p.jump_height == 0, "jump lands on arena floor")
	main._reset()
	# Every attack type scales damage by measured endpoint velocity.
	for limb in ["right_forearm", "right_shin", "right_thigh"]:
		check(p.damage_for_speed(limb, 1000) > p.damage_for_speed(limb, 200) * 1.8, "faster strikes do more damage")
	# A real lower-arm shield intercepts the path before the torso.
	p.position.x = 480
	o.position.x = 610
	p._solve_pose()
	o._solve_pose()
	var shield_mid := o._joint_world("right_elbow").lerp(o._joint_world("right_hand"), 0.5)
	var from := shield_mid + Vector2(-80, 0)
	var to := shield_mid + Vector2(12, 0)
	check(p._try_hit(from, to, "right_forearm", 350), "swept contact finds forearm shield")
	check(o.last_hit_blocked and is_equal_approx(o.health, 99.0), "blocking costs exactly one percent of the 100 HP bar")
	var guard_before: Vector2 = o.joints.right_hand
	for i in 4:
		p._try_hit(from, to, "right_forearm", 600)
	check(not o.guard_stagger.is_empty() and Vector2(o.joints.right_hand).distance_to(guard_before) > 8, "repeated blows displace defense")
	main._reset()
	# A powerful hit can displace defense in one blow.
	shield_mid = o._joint_world("right_elbow").lerp(o._joint_world("right_hand"), 0.5)
	p._try_hit(shield_mid + Vector2(-70, 0), shield_mid, "right_shin", 1100)
	check(not o.guard_stagger.is_empty(), "strong blow displaces guard")
	main._reset()
	# Full leg extension reaches head height when the stance is raised.
	p.position.x = 535
	p.stance_height = 20
	p._solve_pose()
	var foot: Vector2 = p.bodies.right_shin.global_position
	p._start_pointer_drag_at(foot, 2)
	p._update_pointer_drag(2, o.bodies.head.global_position, 0.15)
	check(p.bodies.right_shin.global_position.distance_to(o.bodies.head.global_position) < 26, "fully extended foot reaches opponent face")
	check(o.health < 100, "high kick lands")
	p._end_pointer_drag(2)
	main._reset()
	# Torso movement can carry a hand into a hit, without directly dragging it.
	p.position.x = 510
	p.held_targets.right_forearm = Vector2(65, 0)
	p._solve_pose()
	var before := p._attack_positions()
	p.lean = 58
	p._solve_pose()
	var strokes: Dictionary = {}
	p._resolve_motion(before, 0.08, strokes, p.ATTACK_LIMBS)
	check(o.health < 100, "core motion carries fists into regular contact")
	main._reset()
	# Multi-touch has separate pointer state for torso, hand and foot.
	for pair in [["torso", 10], ["right_forearm", 11], ["right_shin", 12]]:
		p._start_pointer_drag_at(p.bodies[pair[0]].global_position, pair[1])
	check(p.active_drags.size() == 3, "three simultaneous mobile gestures accepted")
	p._end_pointer_drag(11)
	check(p.active_drags.size() == 2 and p.active_drags.has(10) and p.active_drags.has(12), "releasing one finger leaves the others active")
	main._reset()
	# One touch cannot control both overlapping fighters.
	p._start_pointer_drag_at(p.get_world_center(), 25)
	o._start_pointer_drag_at(o.get_world_center(), 25)
	check(p.active_drags.has(25) and not o.active_drags.has(25), "touch belongs to one fighter only")
	p._end_pointer_drag(25)
	o._start_pointer_drag_at(o.get_world_center(), 25)
	check(o.active_drags.has(25), "released touch ID can be reused by other fighter")
	o._notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	check(o.active_drags.is_empty(), "focus loss releases touch ownership")
	main._reset()
	# Lower legs also act as shields.
	var shin := o._joint_world("right_knee").lerp(o._joint_world("right_foot"), 0.5)
	p._try_hit(shin + Vector2(-80,0), shin, "right_shin", 400)
	check(o.last_hit_blocked and o.last_hit_region.ends_with("shin"), "lower leg intercepts a low kick")
	main._reset()
	# Actual head drag, not a direct limb drag, drives the fists into contact.
	p.position.x = 515
	p.held_targets.right_forearm = Vector2(65,0)
	p._solve_pose()
	var head: Vector2 = p.bodies.head.global_position
	p._start_pointer_drag_at(head, 26)
	p._update_pointer_drag(26, head + Vector2(58,15), 0.08)
	check(o.health < 100, "head gesture causes consequential fist damage")
	p._end_pointer_drag(26)
	main._reset()
	# Hopping retains raised leg, travels decisively, and risk grows only after
	# the lifted foot is meaningfully clear of the floor.
	p.balance_random.seed = 123
	p.held_targets.right_shin = Vector2(55, 35)
	p._solve_pose()
	p.set_movement_intent(Vector2.RIGHT)
	advance(p, 0.2)
	check(p.hopping and p.held_targets.has("right_shin"), "walking with high foot produces one-foot hopping")
	check(p.hop_steps == 0, "no random fall roll before first completed step")
	var hop_start_x := p.position.x
	advance(p, 0.2)
	check(p.position.x > hop_start_x + 50.0, "one-foot hopping travels much farther than a careful walk")
	check(p.get_fall_chance() <= 0.01, "a barely raised foot stays at or below one percent risk")
	p.held_targets.right_shin = Vector2(55, -45)
	p._solve_pose()
	check(p.get_fall_chance() < 0.12, "an extended leg remains playable at neutral balance")
	p.lean = 55
	check(p.get_fall_chance() > 0.08, "unbalanced stance increases fall risk")
	p.lean = 0
	advance(p, 0.04)
	check(p.hop_steps == 1, "one balance roll per step")
	main._reset()
	check(not p.is_jumping and not p.hopping and p.guard_stagger.is_empty(), "rematch clears jump, hop and guard state")
	print("Combat v3: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
