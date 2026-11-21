extends Node2D

const Temple := preload("res://scripts/expedition/temple.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")
const SCREEN := Rect2(0, 23, 480, 204)
const COLUMNS := 120

var model: RefCounted
var clock := 0.0
var next_redraw := 0.0
var ending := ""

func _process(delta: float) -> void:
	clock += delta
	if ending.is_empty() and model.fear > 20.0 and clock >= next_redraw:
		next_redraw = clock + 1.0 / 18.0
		queue_redraw()

func _draw() -> void:
	if not ending.is_empty():
		_draw_ending()
		return
	var strength: float = model.fear / 100.0
	var fov := 0.68
	var yaw: float = model.facing * PI / 2.0
	var eye := Vector2(model.pos) + Vector2(0.5, 0.5)
	var horizon := SCREEN.get_center().y + 3.0 * strength * sin(clock * 1.9)
	draw_rect(Rect2(0, SCREEN.position.y, 480, horizon - SCREEN.position.y), Color("#191a22"))
	draw_rect(Rect2(0, horizon, 480, SCREEN.end.y - horizon), Color("#27262b"))
	var depth := PackedFloat32Array()
	for col in COLUMNS:
		var x := float(col) / COLUMNS
		var angle := yaw + (x * 2 - 1) * fov + 0.045 * strength * sin(x * 9 + clock * 1.4)
		var ray := Vector2.from_angle(angle)
		var distance := _wall_distance(eye, ray) * cos(angle - yaw)
		depth.append(distance)
		var half_height := minf(99, 68.0 / maxf(0.16, distance))
		var shade := 1.0 / (1.0 + distance * 0.39)
		var texture := floori((eye + ray * distance).x * 13.0 + (eye + ray * distance).y * 10.0) % 4
		var color := Color("#7b7066").darkened(1.0 - shade * (1.0 if texture else 0.86))
		draw_rect(Rect2(col * 4, horizon - half_height, 4, half_height * 2), color)
	for cell: Vector2i in Temple.MARKS:
		_marker(eye, cell, yaw, fov, depth, horizon, false)
	_marker(eye, model.shadow, yaw, fov, depth, horizon, true)
	if strength > 0.28:
		var dim := clampf(strength * 0.42, 0.0, 0.42)
		draw_rect(Rect2(0, 23, 28, 204), Color(0.22, 0.12, 0.17, dim))
		draw_rect(Rect2(452, 23, 28, 204), Color(0.22, 0.12, 0.17, dim))

func _wall_distance(eye: Vector2, ray: Vector2) -> float:
	for count in range(1, 143):
		var distance := count * 0.09
		var sample := eye + ray * distance
		if not Temple.is_floor(Vector2i(sample.floor())):
			return distance
	return 13.0

func _marker(eye: Vector2, cell: Vector2i, yaw: float, fov: float, depth: PackedFloat32Array, horizon: float, threat: bool) -> void:
	var offset := Vector2(cell) + Vector2(0.5, 0.5) - eye
	var bearing := wrapf(offset.angle() - yaw, -PI, PI)
	if absf(bearing) > fov or offset.length() < 0.2:
		return
	var x := (1.0 + bearing / fov) * 240.0
	var distance := offset.length() * cos(bearing)
	if distance > depth[clampi(int(x / 4), 0, COLUMNS - 1)]:
		return
	if threat:
		var h := 84.0 / distance
		draw_set_transform(Vector2(x, horizon - h * 0.4))
		draw_colored_polygon(PackedVector2Array([Vector2(-h / 4, h), Vector2(-h / 10, 0), Vector2(h / 10, 1), Vector2(h / 4, h)]),
			Color("#29222f"))
		draw_set_transform(Vector2.ZERO)
	else:
		draw_circle(Vector2(x, horizon + 18.0 / distance), clampf(7.0 / distance, 2.0, 10.0), Color("#ecc896"))
		draw_string(FONT, Vector2(x - 45, horizon - 12.0 / distance), Temple.MARKS[cell], HORIZONTAL_ALIGNMENT_CENTER, 90, 9, Color("#f1ddbc"))

func _draw_ending() -> void:
	draw_rect(SCREEN, Color("#1a1c25"))
	var p := SCREEN.get_center()
	for i in range(5, 0, -1):
		draw_circle(p, i * 17.0, Color("#252a38").lightened((5 - i) * 0.025))
	if ending == "mirror":
		draw_rect(Rect2(p - Vector2(62, 38), Vector2(124, 57)), Color("#9c8c81"))
		draw_rect(Rect2(p - Vector2(57, 33), Vector2(114, 47)), Color("#485169"))
		draw_line(p + Vector2(-54, 6), p + Vector2(52, 6), Color("#c5c1a9"), 2)
		draw_line(p + Vector2(-11, 6), p + Vector2(-3, -11), Color("#282e3d"), 3)
	else:
		draw_rect(Rect2(p - Vector2(27, 49), Vector2(54, 92)), Color("#66605e"))
		draw_rect(Rect2(p - Vector2(17, 44), Vector2(24, 81)), Color("#9b8474"))
		draw_line(p - Vector2(38, 49), p + Vector2(38, -49), Color("#f2d6a7"), 3)
	var title := "백미러 엔딩" if ending == "mirror" else "돌기둥 엔딩"
	draw_string(FONT, Vector2(0, 204), title, HORIZONTAL_ALIGNMENT_CENTER, 480, 14, Color("#f1ddbc"))
