class_name FaceTextureProcessor
extends RefCounted

## Converts a tracked camera frame into a small texture that can be shown on a
## fighter head or published as a processed video track. Face detection itself
## stays in a platform adapter, so this class is usable with MediaPipe or a
## different detector without changing the game scene.

var output_size := Vector2i(64, 64)
var padding := 0.22
var mirror_x := false

func crop_face(frame: Image, tracking: Dictionary) -> Image:
	if frame == null or frame.is_empty() or frame.get_width() < 2 or frame.get_height() < 2 or not bool(tracking.get("visible", false)):
		return null
	var frame_size := Vector2(frame.get_width(), frame.get_height())
	var center: Vector2 = tracking.get("center", Vector2(0.5, 0.5))
	var tracked_size := maxf(float(tracking.get("size", 0.0)), 0.05)
	var crop_size := clampf(tracked_size * (1.0 + padding), 0.08, 1.0)
	var origin := center - Vector2.ONE * crop_size * 0.5
	var x := clampi(int(floor(origin.x * frame_size.x)), 0, frame.get_width() - 2)
	var y := clampi(int(floor(origin.y * frame_size.y)), 0, frame.get_height() - 2)
	var width := clampi(int(ceil(crop_size * frame_size.x)), 2, frame.get_width() - x)
	var height := clampi(int(ceil(crop_size * frame_size.y)), 2, frame.get_height() - y)
	var face := frame.get_region(Rect2i(x, y, width, height))
	if mirror_x:
		face.flip_x()
	face.resize(maxi(1, output_size.x), maxi(1, output_size.y), Image.INTERPOLATE_NEAREST)
	return face

func make_face_texture(frame: Image, tracking: Dictionary) -> Texture2D:
	var face := crop_face(frame, tracking)
	if face == null or face.is_empty():
		return null
	return ImageTexture.create_from_image(face)
