class_name FighterVoice
extends Node

## Bounded mono voice packets travel only inside a two-person accepted match.
## No recording is persisted. Muting stops capture; leaving destroys buffers.
signal microphone_status(text: String)
var permission_pending := false

const SAMPLE_RATE := 16000.0
const PACKET_SAMPLES := 800
var service: NakamaSessionService
var capture: AudioEffectCapture
var recorder: AudioStreamPlayer
var speaker: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback
var active := false
var microphone_enabled := true
var samples := PackedByteArray()
var _sample_phase := 0.0
var _bus := -1

func initialize(value: NakamaSessionService) -> void:
	service = value
	service.voice_received.connect(_receive)

func start(enabled: bool) -> void:
	stop()
	active = true
	microphone_enabled = enabled
	permission_pending = false
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = 0.3
	speaker = AudioStreamPlayer.new()
	speaker.stream = generator
	add_child(speaker)
	speaker.play()
	playback = speaker.get_stream_playback()

func set_microphone(enabled: bool) -> void:
	microphone_enabled = enabled
	if recorder:
		recorder.stream_paused = not enabled
	if capture:
		capture.clear_buffer()
	samples.clear()

func _process(_delta: float) -> void:
	if not active or not microphone_enabled:
		return
	if OS.has_feature("android") and not "android.permission.RECORD_AUDIO" in OS.get_granted_permissions():
		if not permission_pending:
			permission_pending = true
			microphone_status.emit("Allow mic")
		return
	if permission_pending:
		permission_pending = false
		microphone_status.emit("Mic on")
	if not recorder:
		_bus = AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(_bus, "FighterVoiceCapture")
		AudioServer.set_bus_mute(_bus, true)
		capture = AudioEffectCapture.new()
		capture.buffer_length = 0.2
		AudioServer.add_bus_effect(_bus, capture)
		recorder = AudioStreamPlayer.new()
		recorder.stream = AudioStreamMicrophone.new()
		recorder.bus = "FighterVoiceCapture"
		add_child(recorder)
		recorder.play()
	var frames := capture.get_buffer(capture.get_frames_available())
	for frame in frames:
		_sample_phase += SAMPLE_RATE
		if _sample_phase < AudioServer.get_mix_rate():
			continue
		_sample_phase -= AudioServer.get_mix_rate()
		var sample := int(clampf((frame.x + frame.y) * 0.5, -1.0, 1.0) * 32767)
		samples.append(sample & 255)
		samples.append((sample >> 8) & 255)
		if samples.size() == PACKET_SAMPLES * 2:
			service.send_voice(samples)
			samples.clear()

func _receive(bytes: PackedByteArray) -> void:
	if not active or not playback or bytes.size() != PACKET_SAMPLES * 2:
		return
	if playback.get_frames_available() < PACKET_SAMPLES:
		return
	var frames := PackedVector2Array()
	for i in range(0, bytes.size(), 2):
		var sample := bytes.decode_s16(i) / 32768.0
		frames.append(Vector2(sample, sample))
	playback.push_buffer(frames)

func stop() -> void:
	active = false
	for node in [recorder, speaker]:
		if is_instance_valid(node):
			node.stop()
			node.queue_free()
	recorder = null
	speaker = null
	playback = null
	capture = null
	samples.clear()
	_sample_phase = 0.0
	if _bus >= 0:
		AudioServer.remove_bus(_bus)
		_bus = -1
