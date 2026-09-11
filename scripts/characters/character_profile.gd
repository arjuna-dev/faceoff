class_name CharacterProfile
extends Resource

@export var display_name: String = "Moxie"
@export var tagline: String = "all elbows, no plan"
@export var primary_color: Color = Color("#f56f61")
@export var secondary_color: Color = Color("#ffd166")
@export var accent_color: Color = Color("#8ef0c7")
@export var face_default: String = ":]"
@export var face_love: String = "<3"
@export var face_shock: String = "O_O"
@export var face_laughter: String = "xD"
@export var face_anger: String = ">:("
@export var face_confusion: String = "?"
@export var face_celebration: String = "^_^"
@export var chest_quirk: String = "HEART"
@export var quirk_line: String = "winks before falling"
@export var visual_style: String = "moxie"

func expression_face(expression_id: String) -> String:
	match expression_id:
		"love": return face_love
		"shock": return face_shock
		"laughter": return face_laughter
		"anger": return face_anger
		"confusion": return face_confusion
		"celebration": return face_celebration
		_: return face_default
