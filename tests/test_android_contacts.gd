extends SceneTree

const ContactsImporterType = preload("res://scripts/systems/android_contacts.gd")

var failures := 0

func _init() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		push_error("FAIL: " + message)

func _run() -> void:
	var source: Array = []
	for i in 650:
		source.append({"id": str(i), "name": "Contact %03d" % i, "phone": "+49 %09d" % i})
	source.append({"id": "duplicate", "name": "Duplicate", "phone": "+49 000000649"})
	source.append({"id": "z", "name": "Zara", "phone": "+49 999999999"})
	var result := ContactsImporterType.normalize_contacts(source)
	check(result.size() == 651, "normalization keeps every unique contact beyond 500 rows")
	check(String(result[-1].get("name", "")) == "Zara", "alphabetical sorting reaches names after J")
	check(String(result[-1].get("phone", "")) == "+49 999999999", "the final contact keeps its phone number")
	var token := "123e4567-e89b-42d3-a456-426614174000"
	check(ContactsImporterType.invite_url(token) == "faceoff://invite/" + token, "invite tokens use the Faceoff deep-link scheme")
	var importer := ContactsImporterType.new()
	check(importer._invite_text(ContactsImporterType.invite_url(token)).contains("faceoff://invite/" + token), "SMS invite text carries the opaque app link")
	var supplied_numbers := {
		"+45 22 20 69 92": "+4522206992",
		"+49 1522 5955860": "+4915225955860",
		"+49 1516 2454451": "+4915162454451",
		"+49 1512 6624828": "+4915126624828",
		"+1 (619) 719-0641": "+16197190641",
	}
	for raw in supplied_numbers:
		check(ContactsImporterType.normalize_phone(raw) == supplied_numbers[raw], "phone formatting is normalized before SMS: %s" % raw)
	check(ContactsImporterType.normalize_phone("0049 1522 5955860") == "+4915225955860", "00-prefixed phone formatting is normalized before SMS")
	check(ContactsImporterType.normalize_phone("not-a-number").is_empty(), "invalid phone formatting is rejected")
	print("Android contacts: %s" % ("PASS" if failures == 0 else "%d failures" % failures))
	quit(1 if failures else 0)
