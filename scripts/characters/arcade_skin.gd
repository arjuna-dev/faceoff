class_name ArcadeSkin
extends RefCounted
## Source-art UV patches follow the same IK anchors as combat. Overlapping patches
## retain the source alpha at elbows and knees instead of exposing socket holes.
const ATLAS = preload("res://assets/fighters/arcade/fighters-atlas-v2.png")
const NEW_ATLAS = preload("res://assets/fighters/arcade/jade-oculon-atlas-v3.png")
const ATLAS_SIZE := Vector2(1536.0, 1024.0)

static func atlas_for(visual_style: String) -> Texture2D:
	return NEW_ATLAS if visual_style in ["jade", "oculon"] else ATLAS

static func part(f: Node2D, points: Array, a: Vector2, b: Vector2, target_a: Vector2, target_b: Vector2, breadth: float = 0.27, atlas: Texture2D = ATLAS) -> void:
	var source_axis := (b - a).normalized()
	var target_axis := (target_b - target_a).normalized()
	var length_scale := target_a.distance_to(target_b) / maxf(1, a.distance_to(b))
	var vertices := PackedVector2Array()
	var uv := PackedVector2Array()
	for point in points:
		var p := Vector2(point[0], point[1])
		var relative := p - a
		vertices.append(target_a + target_axis * relative.dot(source_axis) * length_scale + target_axis.orthogonal() * relative.dot(source_axis.orthogonal()) * breadth)
		uv.append(p / ATLAS_SIZE)
	f.draw_polygon(vertices, PackedColorArray([Color.WHITE]), uv, atlas)

static func draw(f: Node2D, j: Dictionary, visual_style: String, atlas: Texture2D = ATLAS) -> void:
	if visual_style == "jade":
		jade_leg(f, j, "left", atlas)
		jade_leg(f, j, "right", atlas)
		jade_torso(f, j, atlas)
		jade_arm(f, j, "left", atlas)
		jade_head(f, j, atlas)
		jade_arm(f, j, "right", atlas)
	elif visual_style == "oculon":
		oculon_leg(f, j, "left", atlas)
		oculon_leg(f, j, "right", atlas)
		oculon_torso(f, j, atlas)
		oculon_arm(f, j, "left", atlas)
		oculon_head(f, j, atlas)
		oculon_arm(f, j, "right", atlas)
	elif visual_style == "batyr":
		warrior_leg(f, j, "left", atlas)
		warrior_leg(f, j, "right", atlas)
		warrior_arm(f, j, "left", atlas)
		part(f, [[253,177],[407,164],[518,182],[584,222],[600,282],[554,298],[558,439],[567,565],[442,568],[430,517],[307,517],[342,381],[349,319],[348,282],[276,268],[241,262]], Vector2(442,277), Vector2(448,511), j.shoulder, j.hip, 0.28, atlas)
		part(f, [[364,5],[488,5],[514,105],[518,223],[493,246],[427,233],[392,218],[367,176]], Vector2(451,141), Vector2(451,213), j.head, j.head + Vector2(0,23), 0.33, atlas)
		warrior_arm(f, j, "right", atlas)
	else:
		monk_leg(f, j, "left", atlas)
		monk_leg(f, j, "right", atlas)
		monk_arm(f, j, "left", atlas)
		part(f, [[1004,216],[1055,192],[1135,208],[1209,243],[1238,340],[1200,364],[1204,440],[1169,497],[1037,506],[1007,412],[1029,314],[1017,272],[1005,244]], Vector2(1092,276), Vector2(1100,442), j.shoulder, j.hip, 0.25, atlas)
		part(f, [[1052,99],[1136,99],[1165,127],[1165,193],[1134,218],[1134,247],[1061,248],[1050,210]], Vector2(1107,156), Vector2(1107,225), j.head, j.head + Vector2(0,24), 0.32, atlas)
		monk_arm(f, j, "right", atlas)

static func arm_root_offset(visual_style: String, side: String) -> Vector2:
	var front := side == "right"
	if visual_style == "jade":
		return Vector2(24, 4 if front else 0)
	if visual_style == "oculon":
		return Vector2(31, 4)
	return Vector2(14, 6 if front else 0) if visual_style == "batyr" else Vector2(7, 6 if front else 0)

static func guard_offset(visual_style: String, front: bool, beat: float) -> Vector2:
	if visual_style in ["jade", "oculon"]:
		return Vector2(60 + beat, 72 - beat) if front else Vector2(0 + beat, 74 - beat)
	return Vector2(52 + beat, -8 - beat) if front else Vector2(28 + beat, -54 - beat)

static func jade_torso(f: Node2D, j: Dictionary, atlas: Texture2D) -> void:
	part(f, [[282,198],[369,191],[440,192],[501,210],[524,268],[514,344],[486,383],[493,470],[454,493],[347,489],[314,464],[320,390],[289,350],[277,274]], Vector2(403,225), Vector2(408,464), j.shoulder, j.hip, 0.28, atlas)

static func jade_head(f: Node2D, j: Dictionary, atlas: Texture2D) -> void:
	part(f, [[300,10],[414,10],[498,72],[525,160],[503,229],[456,268],[350,269],[300,214],[246,306],[211,285],[229,226],[266,170]], Vector2(407,92), Vector2(420,228), j.head, j.head + Vector2(0,23), 0.32, atlas)

static func jade_arm(f: Node2D, j: Dictionary, side: String, atlas: Texture2D) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[278,215],[320,215],[333,271],[312,342],[281,408],[252,465],[207,495],[168,472],[151,439],[174,389],[202,337],[226,281]], Vector2(300,235), Vector2(221,455), a, b, 0.23, atlas)
		part(f, [[184,426],[240,438],[257,485],[242,534],[222,574],[183,575],[148,552],[151,509]], Vector2(218,452), Vector2(194,544), b, c, 0.27, atlas)
	else:
		part(f, [[491,210],[531,217],[554,270],[577,331],[609,391],[634,437],[623,476],[586,500],[552,473],[529,417],[511,350]], Vector2(508,238), Vector2(593,456), a, b, 0.23, atlas)
		part(f, [[566,431],[620,436],[640,482],[669,524],[655,563],[619,575],[590,552],[575,508]], Vector2(596,454), Vector2(637,545), b, c, 0.27, atlas)

static func jade_leg(f: Node2D, j: Dictionary, side: String, atlas: Texture2D) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[316,432],[408,440],[403,555],[370,675],[339,790],[321,861],[273,889],[210,866],[160,823],[133,773],[178,697],[220,614],[262,518]], Vector2(365,456), Vector2(286,830), a, b, 0.24, atlas)
		part(f, [[213,816],[331,820],[332,881],[295,920],[264,941],[208,928],[175,896],[180,853]], Vector2(280,831), Vector2(220,928), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[169,914],[254,908],[274,935],[270,973],[249,993],[157,991],[141,971],[146,942]], Vector2(210,952), b, c, 0.25, atlas)
	else:
		part(f, [[399,431],[492,440],[531,520],[567,610],[610,700],[658,781],[641,827],[593,870],[536,886],[483,870],[450,792],[428,681],[410,558]], Vector2(449,456), Vector2(553,830), a, b, 0.24, atlas)
		part(f, [[491,817],[616,816],[641,849],[633,895],[601,933],[548,942],[503,915],[481,871]], Vector2(552,832), Vector2(594,927), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[539,912],[621,910],[657,929],[694,950],[693,978],[665,994],[572,990],[542,971]], Vector2(612,954), b, c, 0.25, atlas)

static func oculon_torso(f: Node2D, j: Dictionary, atlas: Texture2D) -> void:
	part(f, [[1012,214],[1080,203],[1157,218],[1248,207],[1304,232],[1316,298],[1287,359],[1270,405],[1234,432],[1076,431],[1018,407],[991,354],[973,292],[981,244]], Vector2(1144,236), Vector2(1148,411), j.shoulder, j.hip, 0.26, atlas)

static func oculon_head(f: Node2D, j: Dictionary, atlas: Texture2D) -> void:
	part(f, [[1104,71],[1170,69],[1225,95],[1248,140],[1243,184],[1218,218],[1172,238],[1123,228],[1090,194],[1088,131]], Vector2(1166,105), Vector2(1170,218), j.head, j.head + Vector2(0,24), 0.31, atlas)

static func oculon_arm(f: Node2D, j: Dictionary, side: String, atlas: Texture2D) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[1004,216],[1049,216],[1070,260],[1044,319],[1018,373],[987,423],[955,437],[921,411],[923,369],[950,321],[970,269]], Vector2(1027,235), Vector2(965,414), a, b, 0.24, atlas)
		part(f, [[920,384],[981,394],[989,438],[973,487],[962,528],[948,562],[906,571],[878,545],[887,494],[900,443]], Vector2(958,411), Vector2(931,541), b, c, 0.25, atlas)
	else:
		part(f, [[1244,215],[1286,217],[1307,260],[1332,319],[1350,371],[1377,414],[1361,444],[1326,433],[1299,391],[1275,340]], Vector2(1269,237), Vector2(1345,415), a, b, 0.24, atlas)
		part(f, [[1321,390],[1375,393],[1391,433],[1405,486],[1426,527],[1407,559],[1370,570],[1343,540],[1339,491]], Vector2(1351,411), Vector2(1390,542), b, c, 0.25, atlas)

static func oculon_leg(f: Node2D, j: Dictionary, side: String, atlas: Texture2D) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[1014,408],[1118,410],[1125,514],[1092,611],[1068,710],[1043,793],[1009,830],[955,822],[916,790],[929,724],[955,655],[980,551]], Vector2(1080,432), Vector2(1002,803), a, b, 0.24, atlas)
		part(f, [[927,783],[1045,785],[1045,834],[1018,894],[1005,929],[957,938],[920,908],[915,849]], Vector2(1000,800), Vector2(972,927), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[913,913],[991,912],[1026,932],[1028,972],[1009,994],[923,994],[909,973],[911,940]], Vector2(970,957), b, c, 0.25, atlas)
	else:
		part(f, [[1162,407],[1250,411],[1289,505],[1310,609],[1340,706],[1363,780],[1345,819],[1298,835],[1255,810],[1219,748],[1190,650],[1167,535]], Vector2(1212,430), Vector2(1295,802), a, b, 0.24, atlas)
		part(f, [[1251,783],[1361,787],[1368,838],[1350,891],[1325,929],[1272,940],[1242,908],[1238,850]], Vector2(1295,800), Vector2(1314,926), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[1250,913],[1332,911],[1372,930],[1427,953],[1428,979],[1396,995],[1290,992],[1256,974]], Vector2(1340,958), b, c, 0.25, atlas)

static func draw_video_face(f: Node2D, j: Dictionary, warrior: bool, texture: Texture2D) -> void:
	# The face is drawn after the atlas head so a processed caller texture can
	# replace the facial area while the authored hair, outline, and costume stay
	# intact. The native adapter is responsible for cropping and masking pixels.
	var radius := 19.0 if warrior else 17.0
	var center: Vector2 = j.head + Vector2(0, 11)
	if texture:
		f.draw_texture_rect(texture, Rect2(center - Vector2(radius, radius), Vector2.ONE * radius * 2.0), false)
	else:
		f.draw_circle(center, radius, Color("5de2d1"))
	f.draw_arc(center, radius, 0.0, TAU, 16, Color("e7fff5"), 2.0)

static func warrior_leg(f: Node2D, j: Dictionary, side: String, atlas: Texture2D = ATLAS) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[308,491],[453,501],[451,640],[421,790],[385,812],[260,810],[235,750],[249,673]], Vector2(378,519), Vector2(324,782), a, b, 0.26, atlas)
		part(f, [[248,771],[394,774],[373,833],[342,920],[243,921],[262,849]], Vector2(321,783), Vector2(289,916), b, c - Vector2(0,9), 0.27, atlas)
		shoe(f, [[241,897],[343,897],[339,953],[328,982],[229,982],[233,935]], Vector2(285,946), b, c, 0.27, atlas)
	else:
		part(f, [[448,505],[568,502],[609,591],[648,709],[613,794],[598,812],[482,810],[455,700]], Vector2(522,528), Vector2(551,782), a, b, 0.26, atlas)
		part(f, [[479,773],[614,771],[620,857],[634,918],[528,918],[502,840]], Vector2(552,783), Vector2(578,914), b, c - Vector2(0,9), 0.27, atlas)
		shoe(f, [[522,895],[632,895],[649,912],[693,925],[694,966],[537,969]], Vector2(592,940), b, c, 0.27, atlas)

static func warrior_arm(f: Node2D, j: Dictionary, side: String, atlas: Texture2D = ATLAS) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[554,284],[594,288],[607,343],[625,379],[634,430],[578,452],[546,371]], Vector2(575,313), Vector2(601,416), a, b, 0.28, atlas)
		part(f, [[566,413],[622,389],[650,448],[675,521],[686,551],[666,582],[637,585],[614,555],[614,514],[585,468]], Vector2(601,416), Vector2(650,552), b, c, 0.28, atlas)
	else:
		part(f, [[273,252],[327,263],[350,300],[339,350],[297,405],[289,442],[209,421],[222,367],[244,327],[245,287]], Vector2(298,289), Vector2(256,412), a, b, 0.29, atlas)
		part(f, [[211,391],[276,405],[296,425],[275,492],[275,523],[289,548],[272,582],[233,588],[200,562],[200,516],[202,462]], Vector2(251,414), Vector2(244,550), b, c, 0.29, atlas)

static func monk_leg(f: Node2D, j: Dictionary, side: String, atlas: Texture2D = ATLAS) -> void:
	var a: Vector2 = j[side + "_hip"]
	var b: Vector2 = j[side + "_knee"]
	var c: Vector2 = j[side + "_foot"]
	if side == "left":
		part(f, [[1042,436],[1120,438],[1123,582],[1079,690],[1063,804],[995,818],[919,799],[902,742],[919,680],[965,608],[1008,515]], Vector2(1061,455), Vector2(979,788), a, b, 0.24, atlas)
		part(f, [[932,772],[1015,786],[1013,824],[985,923],[916,923],[923,846]], Vector2(972,793), Vector2(949,921), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[917,904],[986,904],[996,956],[977,980],[899,977],[895,944]], Vector2(948,946), b, c, 0.25, atlas)
	else:
		part(f, [[1111,437],[1201,432],[1221,496],[1244,595],[1268,675],[1287,757],[1261,809],[1170,817],[1100,792],[1083,686],[1100,566]], Vector2(1155,455), Vector2(1202,791), a, b, 0.24, atlas)
		part(f, [[1162,778],[1253,778],[1253,858],[1264,921],[1180,925],[1191,861]], Vector2(1206,793), Vector2(1226,920), b, c - Vector2(0,8), 0.25, atlas)
		shoe(f, [[1187,905],[1260,905],[1281,922],[1338,930],[1342,963],[1190,966],[1180,929]], Vector2(1251,944), b, c, 0.25, atlas)

static func monk_arm(f: Node2D, j: Dictionary, side: String, atlas: Texture2D = ATLAS) -> void:
	var a: Vector2 = j[side + "_shoulder"]
	var b: Vector2 = j[side + "_elbow"]
	var c: Vector2 = j[side + "_hand"]
	if side == "left":
		part(f, [[1196,328],[1237,336],[1254,384],[1276,423],[1238,454],[1200,418]], Vector2(1213,354), Vector2(1250,435), a, b, 0.24, atlas)
		part(f, [[1225,437],[1270,417],[1294,460],[1312,510],[1320,553],[1305,584],[1275,587],[1250,569],[1254,529],[1237,484]], Vector2(1250,438), Vector2(1285,552), b, c, 0.25, atlas)
	else:
		part(f, [[976,240],[1021,245],[1042,276],[1025,315],[1008,341],[979,389],[962,436],[895,424],[920,358],[933,307],[946,263]], Vector2(986,278), Vector2(936,417), a, b, 0.25, atlas)
		part(f, [[897,406],[948,417],[966,436],[949,486],[943,522],[952,552],[936,582],[902,591],[871,569],[873,529],[881,472]], Vector2(927,423), Vector2(914,554), b, c, 0.25, atlas)

static func shoe(f: Node2D, points: Array, center: Vector2, knee: Vector2, foot: Vector2, scale: float, atlas: Texture2D = ATLAS) -> void:
	var axis := (foot - knee).normalized() if foot.y < -30.0 else Vector2.DOWN
	part(f, points, center, center + Vector2.DOWN * 100, foot, foot + axis * 100 * scale, scale, atlas)
