class_name FaceoffSocialController
extends Node

signal call_updated(call: Dictionary)
signal profile_updated(profile: Dictionary)
signal contacts_updated(contacts: Array[Dictionary])
signal message_received(peer: String, text: String)
signal status_changed(text: String)

var service: NakamaSessionService
var current_call: Dictionary = {}
var phone_contacts: Array[Dictionary] = []
var verified := false
var _polling := false
var _elapsed := 0.0
var _seen := {}
var _reconnect_elapsed := 0.0
var pending_invite_token := ""

func initialize(value: NakamaSessionService) -> void:
	var seen_file := ConfigFile.new()
	if seen_file.load(SocialStorage.path("notifications.cfg")) == OK:
		_seen = seen_file.get_value("notifications", "seen", {})
	service = value
	service.social_only = true
	service.connection_changed.connect(_connection)
	service.notification_received.connect(_receive_notification)
	service.network_error.connect(func(text): status_changed.emit(text))
	var saved := ConfigFile.new()
	if saved.load(SocialStorage.path("contacts.cfg")) == OK:
		phone_contacts.assign(saved.get_value("contacts", "items", []))
		# Membership must be revalidated, never assume cached accounts are online.
		for contact in phone_contacts:
			contact.erase("user_id")
	var invite_file := ConfigFile.new()
	if invite_file.load(SocialStorage.path("invite.cfg")) == OK:
		pending_invite_token = String(invite_file.get_value("invite", "token", ""))
	contacts_updated.emit(phone_contacts)

func _connection(connected: bool) -> void:
	if not connected:
		status_changed.emit("Disconnected. Reconnecting...")
		return
	var result := await service.social_rpc("faceoff_profile")
	if _error(result):
		return
	var profile: Dictionary = result.profile if result.get("profile") is Dictionary else {}
	if not profile.is_empty():
		profile["user_id"] = String(result.get("user_id", service.user_id))
		profile["handle"] = _profile_handle(profile)
	verified = not profile.is_empty()
	profile_updated.emit(profile)
	status_changed.emit("Connected" if verified else "Set up your phone account in Profile")
	if verified:
		await _claim_pending_invite()
		await discover()
		# Persist the server cursor so a long history cannot hide new messages.
		var cursor_file := ConfigFile.new()
		cursor_file.load(SocialStorage.path("notification_cursor.cfg"))
		var cursor: String = cursor_file.get_value(service.user_id, "cursor", "")
		for page in 20:
			var notifications = await service.client.list_notifications_async(service.session, 100, cursor if not cursor.is_empty() else null)
			if notifications == null or notifications.is_exception():
				break
			for notification in notifications.notifications:
				service._on_notification(notification)
			var next_cursor := String(notifications.cacheable_cursor)
			if next_cursor.is_empty() or next_cursor == cursor:
				break
			cursor = next_cursor
			cursor_file.set_value(service.user_id, "cursor", cursor)
			cursor_file.save(SocialStorage.path("notification_cursor.cfg"))
			if notifications.notifications.size() < 100:
				break

func send_code(number: String) -> void:
	status_changed.emit("Requesting verification code...")
	var result := await service.social_rpc("faceoff_phone_send", {"phone": number})
	if not _error(result):
		var channel := String(result.get("channel", "sms")).to_lower()
		var channel_label := "WhatsApp" if channel == "whatsapp" else "SMS"
		if bool(result.get("budget_alert", false)):
			status_changed.emit("Code sent via %s. Verification budget alert reached €6; requests stop at €10." % channel_label)
		else:
			status_changed.emit("Code sent via %s. Enter it below." % channel_label)

func verify(number: String, code: String, player_name: String) -> void:
	status_changed.emit("Verifying phone number...")
	var result := await service.verify_phone(number, code, player_name)
	if _error(result):
		return
	var profile: Dictionary = result.profile if result.get("profile") is Dictionary else {}
	if not profile.is_empty():
		profile["user_id"] = String(result.get("user_id", service.user_id))
		profile["handle"] = _profile_handle(profile)
	verified = not profile.is_empty()
	if verified:
		await _claim_pending_invite()
	profile_updated.emit(profile)
	if verified:
		status_changed.emit("Phone verified. Invite your friends from Settings.")
		await discover()

func import_contacts(contacts: Array[Dictionary]) -> void:
	phone_contacts = contacts
	var saved := ConfigFile.new()
	saved.set_value("contacts", "items", phone_contacts)
	saved.save(SocialStorage.path("contacts.cfg"))
	contacts_updated.emit(phone_contacts)
	if verified:
		await discover()
	else:
		status_changed.emit("Contacts saved. Verify your phone to find friends on Faceoff.")

func discover() -> void:
	var numbers: Array = []
	var seen_numbers := {}
	for c in phone_contacts:
		var number := String(c.get("phone", "")).strip_edges()
		if not number.is_empty() and not seen_numbers.has(number):
			seen_numbers[number] = true
			numbers.append(number)
	var found := {}
	var batch: Array = []
	for number in numbers:
		batch.append(number)
		if batch.size() < 250:
			continue
		if not await _discover_batch(batch, found):
			return
		batch = []
	if not batch.is_empty() and not await _discover_batch(batch, found):
		return
	for c in phone_contacts:
		if c.has("phone"):
			c.erase("user_id")
		if found.has(c.get("phone", "")):
			c.user_id = found[c.phone]
	var inbox := await service.social_rpc("faceoff_inbox")
	for c in inbox.get("contacts", []):
		_upsert_peer(String(c.user_id), String(c.get("name", "Friend")), String(c.get("phone", "")))
	contacts_updated.emit(phone_contacts)
	status_changed.emit("%d friends on Faceoff. Call a friend or invite more." % found.size())

## Creates a short-lived server-side invite handle for a phone contact. The
## recipient's number is never put into the SMS body or URI, and resolving the
## handle only pre-fills Profile. Phone ownership still requires a fresh OTP.
func create_invite_link(contact: Dictionary) -> Dictionary:
	if service == null or not service.connected:
		return {"error": "Connecting to server. Please try again shortly."}
	var number := String(contact.get("phone", "")).strip_edges()
	if number.is_empty():
		return {"error": "This contact has no phone number"}
	status_changed.emit("Preparing a secure invite...")
	var result := await service.social_rpc("faceoff_invite_link", {"phone": number})
	if _error(result):
		return result
	return result

## Resolves an invite received from the faceoff://invite/<token> deep link.
## This is deliberately separate from phone verification so an invite cannot
## authenticate or create a call by itself.
func resolve_invite_token(token: String) -> Dictionary:
	if service == null or not service.connected:
		return {"error": "Connecting to server. Please try again shortly."}
	var value := token.strip_edges()
	if value.is_empty():
		return {"error": "Invite link is invalid"}
	var result := await service.social_rpc("faceoff_invite_resolve", {"token": value})
	if _error(result):
		return result
	pending_invite_token = value
	_save_pending_invite()
	return result

func _claim_pending_invite() -> void:
	if pending_invite_token.is_empty() or service == null or not service.connected or not verified:
		return
	var result := await service.social_rpc("faceoff_invite_claim", {"token": pending_invite_token})
	if not result.has("error"):
		pending_invite_token = ""
		_save_pending_invite()
		return
	# A stale or mismatched invite should not be retried forever. Transient
	# connection failures keep the token so the next reconnect can retry.
	var error_text := String(result.get("error", "")).to_lower()
	if not error_text.contains("connect") and not error_text.contains("server"):
		pending_invite_token = ""
		_save_pending_invite()

func _save_pending_invite() -> void:
	var invite_file := ConfigFile.new()
	if not pending_invite_token.is_empty():
		invite_file.set_value("invite", "token", pending_invite_token)
	else:
		invite_file.set_value("invite", "token", "")
	invite_file.save(SocialStorage.path("invite.cfg"))

func _discover_batch(numbers: Array, found: Dictionary) -> bool:
	var result := await service.social_rpc("faceoff_contacts", {"phones": numbers})
	if _error(result):
		return false
	for contact in result.get("contacts", []):
		found[String(contact.get("phone", ""))] = String(contact.get("user_id", ""))
	return true

func invite(contact: Dictionary) -> void:
	if not current_call.is_empty():
		status_changed.emit("Finish the current call first")
		return
	var result := await service.social_rpc("faceoff_call_invite", {"target": contact.get("user_id", ""), "kind": "call"})
	if _error(result):
		return
	result["contact_name"] = contact.get("name", "Contact")
	current_call = result
	call_updated.emit(current_call)

func action(value: String) -> void:
	if current_call.is_empty():
		return
	var result := await service.social_rpc("faceoff_call_action", {"id": current_call.id, "action": value})
	if _error(result):
		return
	_apply_call(result)

func _process(delta: float) -> void:
	if service == null:
		return
	if not service.connected and not service.endpoint.is_empty():
		_reconnect_elapsed += delta
		if _reconnect_elapsed >= 15:
			_reconnect_elapsed = 0
			service.connect_to_server(service.endpoint)
		return
	_reconnect_elapsed = 0
	_elapsed += delta
	if _elapsed < 2 or _polling or current_call.is_empty() or not service.connected:
		return
	_elapsed = 0
	_polling = true
	await action("status")
	_polling = false

func _receive_notification(data: Dictionary) -> void:
	if data.get("type") == "call":
		var call: Dictionary = data.get("call", {})
		if call.is_empty():
			return
		# A stale persistent ringing notification must never revive a closed call.
		var result := await service.social_rpc("faceoff_call_action", {"id": call.id, "action": "status"})
		if result.has("error"):
			return
		if current_call.is_empty() and result.get("status") != "ringing":
			return
		if not current_call.is_empty() and current_call.id != result.id:
			return
		_apply_call(result)
	elif data.get("type") == "contact":
		_upsert_peer(String(data.get("user_id", "")), String(data.get("name", "Friend")), String(data.get("phone", "")))
		_save_contacts()
		contacts_updated.emit(phone_contacts)
	elif data.get("type") in ["message", "ping"]:
		var key := String(data.get("id", JSON.stringify(data)))
		if _seen.has(key):
			return
		_seen[key] = true
		var saved := ConfigFile.new()
		saved.set_value("notifications", "seen", _seen)
		saved.save(SocialStorage.path("notifications.cfg"))
		_upsert_peer(String(data.get("sender", "")), String(data.get("name", "Friend")))
		contacts_updated.emit(phone_contacts)
		message_received.emit(String(data.get("sender", "")), "%s: %s" % [data.get("name", "Friend"), data.get("text", "")])

func _apply_call(value: Dictionary) -> void:
	value["contact_name"] = current_call.get("contact_name", value.get("caller_name", "Contact"))
	current_call = value
	call_updated.emit(value)
	if value.get("status") in ["declined", "cancelled", "expired", "ended"]:
		current_call = {}

func send_message(contact: Dictionary, text: String, ping: bool) -> void:
	var target := String(contact.get("user_id", ""))
	var result := await service.social_rpc("faceoff_message", {"target": target, "text": text, "ping": ping})
	if not _error(result):
		message_received.emit(target, "You: " + text)

func _error(result: Dictionary) -> bool:
	if result.has("error"):
		status_changed.emit(String(result.error))
		return true
	return false

func _upsert_peer(id: String, name_value: String, phone_value := "") -> void:
	for c in phone_contacts:
		if c.get("user_id") == id or c.get("id") == id or (not phone_value.is_empty() and String(c.get("phone", "")) == phone_value):
			c.user_id = id
			c.name = name_value
			if not phone_value.is_empty():
				c.phone = phone_value
			return
	var peer := {"id": id, "user_id": id, "name": name_value}
	if not phone_value.is_empty():
		peer.phone = phone_value
	phone_contacts.append(peer)

func _save_contacts() -> void:
	var saved := ConfigFile.new()
	saved.set_value("contacts", "items", phone_contacts)
	saved.save(SocialStorage.path("contacts.cfg"))

func _profile_handle(profile: Dictionary) -> String:
	var name := String(profile.get("name", "fighter")).to_lower()
	var handle := ""
	for character in name:
		if character in "abcdefghijklmnopqrstuvwxyz0123456789":
			handle += character
		elif character == " " and not handle.ends_with("_"):
			handle += "_"
	handle = handle.trim_suffix("_")
	return "@" + (handle if not handle.is_empty() else "fighter")
