class_name AndroidContactsImporter
extends Node

## Thin Godot-side adapter for the FaceoffContacts Android plugin.
## The plugin only reads contacts after Android grants READ_CONTACTS.

signal contacts_ready(contacts: Array[Dictionary])
signal status_changed(message: String, good: bool)
signal invite_received(url: String)

var plugin: Object
var importing := false

func _ready() -> void:
	if not OS.has_feature("android"):
		return
	if not Engine.has_singleton("FaceoffContacts"):
		return
	plugin = Engine.get_singleton("FaceoffContacts")
	if plugin and plugin.has_signal("contacts_permission_result"):
		plugin.connect("contacts_permission_result", _on_permission_result)
	if plugin and plugin.has_signal("invite_url_received"):
		plugin.connect("invite_url_received", _on_invite_url_received)
	if plugin and plugin.has_method("getInitialInviteUrl"):
		var initial := String(plugin.call("getInitialInviteUrl"))
		if not initial.is_empty():
			call_deferred("_on_invite_url_received", initial)

func auto_import_if_permitted() -> void:
	if OS.has_feature("android") and plugin != null and bool(plugin.call("hasContactsPermission")):
		_read_contacts()

func request_import() -> void:
	if importing:
		return
	if not OS.has_feature("android"):
		status_changed.emit("Phone import is available in the Android build", false)
		return
	if plugin == null:
		status_changed.emit("Android contacts bridge is unavailable in this build", false)
		return
	if bool(plugin.call("hasContactsPermission")):
		_read_contacts()
		return
	importing = true
	status_changed.emit("Allow Contacts access, then Faceoff will import your phone list", false)
	plugin.call("requestContactsPermission")

func request_media_permission(permission_name: String) -> bool:
	if not OS.has_feature("android"):
		return true
	if permission_name != "android.permission.RECORD_AUDIO":
		return false
	if plugin:
		return bool(plugin.call("requestMediaPermission", permission_name))
	return OS.request_permission(permission_name)

func _on_permission_result(granted: bool) -> void:
	importing = false
	if granted:
		_read_contacts()
	else:
		status_changed.emit("Contacts permission was declined", false)

func _read_contacts() -> void:
	if plugin == null:
		status_changed.emit("Phone contacts could not be read", false)
		return
	importing = true
	var raw := String(plugin.call("readContactsJson"))
	var parsed = JSON.parse_string(raw)
	if parsed is Dictionary and parsed.has("error"):
		importing = false
		status_changed.emit(String(parsed.get("error", "Contacts permission required")), false)
		return
	var normalized := normalize_contacts(parsed if parsed is Array else [])
	importing = false
	contacts_ready.emit(normalized)
	status_changed.emit("%d phone contact%s imported" % [normalized.size(), "" if normalized.size() == 1 else "s"], true)

func share_invite(channel: String = "more") -> void:
	var text := _invite_text("", true)
	status_changed.emit("Opening %s invite" % channel.to_upper(), true)
	if plugin:
		if plugin.has_method("shareInviteWithChannel"):
			plugin.call("shareInviteWithChannel", text, channel)
		else:
			plugin.call("shareInvite", text)
	else:
		DisplayServer.clipboard_set(text)
		status_changed.emit("Invite text copied. Share it together with the APK.", true)

func invite_contact(contact: Dictionary, invite_link: String = "") -> void:
	var phone := normalize_phone(String(contact.get("phone", "")))
	if phone.is_empty():
		status_changed.emit("Enter a full international phone number", false)
		return
	var text := _invite_text(invite_link, false)
	status_changed.emit("Opening SMS invite for %s" % contact.get("name", "contact"), true)
	if plugin and plugin.has_method("shareInviteToPhone"):
		plugin.call("shareInviteToPhone", text, phone)
	elif plugin:
		plugin.call("shareInviteWithChannel", text, "sms")
	else:
		DisplayServer.clipboard_set(text)
		status_changed.emit("Invite text copied for %s" % contact.get("name", "contact"), true)

static func normalize_phone(value: String) -> String:
	var raw := value.strip_edges()
	var compact := ""
	for character in raw:
		if character in "0123456789":
			compact += character
		elif character == "+" and compact.is_empty():
			compact += character
		elif character in " ()-.":
			continue
		else:
			return ""
	if compact.begins_with("00"):
		compact = "+" + compact.substr(2)
	if not compact.begins_with("+") or compact.length() < 9 or compact.length() > 16:
		return ""
	return compact

static func invite_url(token: String) -> String:
	var value := token.strip_edges()
	return "" if value.is_empty() else "faceoff://invite/" + value

func _invite_text(invite_link: String = "", attached_apk: bool = false) -> String:
	var url := String(ProjectSettings.get_setting("faceoff/invite_download_url", ""))
	var text := "Join me on Faceoff for a fight! "
	if not url.is_empty():
		text += "Install Faceoff: " + url
	elif attached_apk:
		text += "Install the attached Faceoff Android APK, then verify your phone number."
	else:
		text += "Install the Faceoff Android APK I send you, then verify your phone number."
	if not invite_link.strip_edges().is_empty():
		text += "\nOpen this invite after installing Faceoff to prefill your phone: " + invite_link.strip_edges()
	return text

func _on_invite_url_received(url: String) -> void:
	invite_received.emit(url.strip_edges())

static func normalize_contacts(parsed: Array) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	var seen := {}
	for item in parsed:
		if not item is Dictionary:
			continue
		var source: Dictionary = item
		var name := String(source.get("name", "PHONE CONTACT")).strip_edges()
		var phone := String(source.get("phone", "")).strip_edges()
		var key := phone.replace(" ", "").replace("-", "").replace("(", "").replace(")", "")
		if name.is_empty() or key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		normalized.append({
			"id": "phone:" + String(source.get("id", key)),
			"name": name,
			"tag": "PHONE CONTACT",
			"presence": "INVITE",
			"last_message": "Invite to Faceoff",
			"accent": Color("78d9c6"),
			"phone": phone,
			"avatar_uri": String(source.get("avatar_uri", "")),
		})
	normalized.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.get("name", "")).naturalnocasecmp_to(String(b.get("name", ""))) < 0)
	return normalized
