class_name ArcadeSkin
extends RefCounted
## Source-art UV patches follow the same IK anchors as combat. Overlapping patches
## retain the source alpha at elbows and knees instead of exposing socket holes.
const ATLAS = preload("res://assets/fighters/arcade/fighters-atlas.png")

static func part(f: Node2D, points: Array, a: Vector2, b: Vector2, target_a: Vector2, target_b: Vector2, breadth: float = 0.27) -> void:
	var source_axis := (b - a).normalized()
	var target_axis := (target_b - target_a).normalized()
	var length_scale := target_a.distance_to(target_b) / maxf(1, a.distance_to(b))
	var vertices := PackedVector2Array()
	var uv := PackedVector2Array()
	for point in points:
		var p := Vector2(point[0], point[1])
		var relative := p - a
		vertices.append(target_a + target_axis * relative.dot(source_axis) * length_scale + target_axis.orthogonal() * relative.dot(source_axis.orthogonal()) * breadth)
		uv.append(p / Vector2(1536, 1024))
	f.draw_polygon(vertices, PackedColorArray([Color.WHITE]), uv, ATLAS)

static func draw(f: Node2D, j: Dictionary, warrior: bool) -> void:
	if warrior:
		warrior_leg(f, j, "left")
		warrior_leg(f, j, "right")
		warrior_arm(f, j, "left")
		part(f, [[253,177],[407,164],[518,182],[584,222],[600,282],[554,298],[558,439],[567,565],[442,568],[430,517],[307,517],[342,381],[349,319],[348,282],[276,268],[241,262]], Vector2(442,277), Vector2(448,511), j.shoulder, j.hip, 0.28)
		part(f, [[364,5],[488,5],[514,105],[518,223],[493,246],[427,233],[392,218],[367,176]], Vector2(451,141), Vector2(451,213), j.head, j.head + Vector2(0,23), 0.33)
		warrior_arm(f, j, "right")
	else:
		monk_leg(f, j, "left")
		monk_leg(f, j, "right")
		monk_arm(f, j, "left")
		part(f, [[1004,216],[1055,192],[1135,208],[1209,243],[1238,340],[1200,364],[1204,440],[1169,497],[1037,506],[1007,412],[1029,314],[1017,272],[1005,244]], Vector2(1092,276), Vector2(1100,442), j.shoulder, j.hip, 0.25)
		part(f, [[1052,99],[1136,99],[1165,127],[1165,193],[1134,218],[1134,247],[1061,248],[1050,210]], Vector2(1107,156), Vector2(1107,225), j.head, j.head + Vector2(0,24), 0.32)
		monk_arm(f, j, "right")

static func warrior_leg(f: Node2D, j: Dictionary, side: String) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[308,491],[453,501],[451,640],[421,790],[385,812],[260,810],[235,750],[249,673]], Vector2(378,519), Vector2(324,782), a, b, 0.26)
		part(f, [[248,771],[394,774],[373,833],[342,920],[243,921],[262,849]], Vector2(321,783), Vector2(289,916), b, c - Vector2(0,9), 0.27)
		shoe(f, [[241,897],[343,897],[339,953],[328,982],[229,982],[233,935]], Vector2(285,946), b, c, 0.27)
	else:
		part(f, [[448,505],[568,502],[609,591],[648,709],[613,794],[598,812],[482,810],[455,700]], Vector2(522,528), Vector2(551,782), a, b, 0.26)
		part(f, [[479,773],[614,771],[620,857],[634,918],[528,918],[502,840]], Vector2(552,783), Vector2(578,914), b, c - Vector2(0,9), 0.27)
		shoe(f, [[522,895],[632,895],[649,912],[693,925],[694,966],[537,969]], Vector2(592,940), b, c, 0.27)

static func warrior_arm(f: Node2D, j: Dictionary, side: String) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[554,284],[594,288],[607,343],[625,379],[634,430],[578,452],[546,371]], Vector2(575,313), Vector2(601,416), a, b, 0.28)
		part(f, [[566,413],[622,389],[650,448],[675,521],[686,551],[666,582],[637,585],[614,555],[614,514],[585,468]], Vector2(601,416), Vector2(650,552), b, c, 0.28)
	else:
		part(f, [[273,252],[327,263],[350,300],[339,350],[297,405],[289,442],[209,421],[222,367],[244,327],[245,287]], Vector2(298,289), Vector2(256,412), a, b, 0.29)
		part(f, [[211,391],[276,405],[296,425],[275,492],[275,523],[289,548],[272,582],[233,588],[200,562],[200,516],[202,462]], Vector2(251,414), Vector2(244,550), b, c, 0.29)

static func monk_leg(f: Node2D, j: Dictionary, side: String) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[1042,436],[1120,438],[1123,582],[1079,690],[1063,804],[995,818],[919,799],[902,742],[919,680],[965,608],[1008,515]], Vector2(1061,455), Vector2(979,788), a, b, 0.24)
		part(f, [[932,772],[1015,786],[1013,824],[985,923],[916,923],[923,846]], Vector2(972,793), Vector2(949,921), b, c - Vector2(0,8), 0.25)
		shoe(f, [[917,904],[986,904],[996,956],[977,980],[899,977],[895,944]], Vector2(948,946), b, c, 0.25)
	else:
		part(f, [[1111,437],[1201,432],[1221,496],[1244,595],[1268,675],[1287,757],[1261,809],[1170,817],[1100,792],[1083,686],[1100,566]], Vector2(1155,455), Vector2(1202,791), a, b, 0.24)
		part(f, [[1162,778],[1253,778],[1253,858],[1264,921],[1180,925],[1191,861]], Vector2(1206,793), Vector2(1226,920), b, c - Vector2(0,8), 0.25)
		shoe(f, [[1187,905],[1260,905],[1281,922],[1338,930],[1342,963],[1190,966],[1180,929]], Vector2(1251,944), b, c, 0.25)

static func monk_arm(f: Node2D, j: Dictionary, side: String) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[1196,328],[1237,336],[1254,384],[1276,423],[1238,454],[1200,418]], Vector2(1213,354), Vector2(1250,435), a, b, 0.24)
		part(f, [[1225,437],[1270,417],[1294,460],[1312,510],[1320,553],[1305,584],[1275,587],[1250,569],[1254,529],[1237,484]], Vector2(1250,438), Vector2(1285,552), b, c, 0.25)
	else:
		part(f, [[976,240],[1021,245],[1042,276],[1025,315],[1008,341],[979,389],[962,436],[895,424],[920,358],[933,307],[946,263]], Vector2(986,278), Vector2(936,417), a, b, 0.25)
		part(f, [[897,406],[948,417],[966,436],[949,486],[943,522],[952,552],[936,582],[902,591],[871,569],[873,529],[881,472]], Vector2(927,423), Vector2(914,554), b, c, 0.25)

static func shoe(f: Node2D, points: Array, center: Vector2, knee: Vector2, foot: Vector2, scale: float) -> void:
	var axis := (foot - knee).normalized() if foot.y < -30.0 else Vector2.DOWN
	part(f, points, center, center + Vector2.DOWN * 100, foot, foot + axis * 100 * scale, scale)
