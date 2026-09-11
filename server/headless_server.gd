extends SceneTree

const OnlineMatchType = preload("res://scripts/systems/online_match.gd")

var online: FaceoffOnlineMatch

func _init() -> void:
	call_deferred("_boot")

func _boot() -> void:
	var network_root := Node.new()
	network_root.name = "Faceoff"
	root.add_child(network_root)
	online = OnlineMatchType.new()
	online.name = "OnlineMatch"
	network_root.add_child(online)
	online.status_changed.connect(func(message: String): print("online " + message))
	var port := int(OS.get_environment("FACE_OFF_SERVER_PORT"))
	if port <= 0:
		port = FaceoffOnlineMatch.DEFAULT_PORT
	var result := online.start_server(port)
	if result != OK:
		push_error("Could not bind combat WebSocket on port %d" % port)
		quit(1)
	print("Faceoff combat server ready · protocol v%d · %dHz" % [FaceoffNetworkProtocol.VERSION, FaceoffNetworkProtocol.TICK_RATE])
