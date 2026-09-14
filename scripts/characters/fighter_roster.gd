class_name FighterRoster
extends RefCounted

const IDS: Array[String] = ["batyr", "kiro", "jade", "oculon"]
const PROFILES := {
	"batyr": preload("res://data/batyr.tres"),
	"kiro": preload("res://data/kiro.tres"),
	"jade": preload("res://data/jade.tres"),
	"oculon": preload("res://data/oculon.tres"),
}
const ATLAS = preload("res://assets/fighters/arcade/fighters-atlas-v2.png")
const NEW_ATLAS = preload("res://assets/fighters/arcade/jade-oculon-atlas-v3.png")
const ATLAS_BY_ID := {
	"batyr": ATLAS,
	"kiro": ATLAS,
	"jade": NEW_ATLAS,
	"oculon": NEW_ATLAS,
}
const HEAD_REGIONS := {
	"batyr": Rect2(350, 0, 180, 270),
	"kiro": Rect2(1035, 80, 165, 190),
	"jade": Rect2(205, 10, 330, 300),
	"oculon": Rect2(1080, 65, 190, 190),
}

static func profile(id: String) -> CharacterProfile:
	return PROFILES.get(id, PROFILES["batyr"]) as CharacterProfile

static func head(id: String) -> Texture2D:
	var atlas_texture := AtlasTexture.new()
	atlas_texture.atlas = ATLAS_BY_ID.get(id, ATLAS) as Texture2D
	atlas_texture.region = HEAD_REGIONS.get(id, HEAD_REGIONS["batyr"])
	return atlas_texture
