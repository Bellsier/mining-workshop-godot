extends Node2D
## The player's house inside (web village.js VILLAGE.HOME, villageHomeTick / villageHomeTarget): a small room in
## room units (the same size as world units; x right, y down, the door gap in the bottom wall) with fixed
## furniture. Walking out through the door gap, or E at the door, goes back out onto the door step.
## Being inside is not saved: the saved position stays on the house's door step in the world.

const WorldData := preload("res://scripts/world/world_data.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")
const UNIT := 64.0
const WORLD_SCENE := "res://scenes/world/world_map.tscn"

var H: Dictionary
var player: Node2D
var _leaving := false


func _ready() -> void:
	H = WorldData.catalog().village.HOME
	player = get_parent().get_node_or_null("Player")
	var spawns := get_parent().get_node_or_null("Spawns")
	if spawns != null and spawns.get_node_or_null("Start") != null:
		spawns.get_node("Start").position = Vector2(H.START.x, H.START.y) * UNIT
	var w: float = H.ROOM.w
	var h: float = H.ROOM.h
	var door_x: float = H.DOOR.x
	var half: float = H.DOOR.half
	# walls (web villageHomeCanStand): the sides, the back wall band and the bottom wall either side of the door gap
	_wall(Rect2(-1.0, -1.0, 1.04, h + 2.0))
	_wall(Rect2(w - 0.04, -1.0, 1.04, h + 2.0))
	_wall(Rect2(-1.0, -1.0, w + 2.0, 1.22))
	_wall(Rect2(-1.0, h - 0.02, door_x - half + 1.0, 1.0))
	_wall(Rect2(door_x + half, h - 0.02, w - door_x - half + 1.0, 1.0))
	_wall(Rect2(door_x - half - 0.1, H.EXIT_Y + 0.3, half * 2.0 + 0.2, 0.3))
	for f: Dictionary in H.FURNITURE:
		if f.get("box") is Dictionary:
			_wall(Rect2(f.x + f.box.minX, f.y + f.box.minY, f.box.maxX - f.box.minX, f.box.maxY - f.box.minY))
	var cam := player.get_node_or_null("Camera2D") as Camera2D if player != null else null
	if cam != null:
		cam.limit_left = int(-1.0 * UNIT)
		cam.limit_top = int(-1.5 * UNIT)
		cam.limit_right = int((w + 1.0) * UNIT)
		cam.limit_bottom = int((h + 1.0) * UNIT)
	queue_redraw()


func _wall(r: Rect2) -> void:
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = r.size * UNIT
	shape.shape = rect
	body.position = (r.position + r.size / 2.0) * UNIT
	body.add_child(shape)
	add_child(body)


func _physics_process(_delta: float) -> void:
	if player == null or _leaving:
		return
	# walked out through the door gap
	if player.position.y / UNIT >= float(H.EXIT_Y):
		leave()


func leave() -> void:
	if _leaving:
		return
	_leaving = true
	get_node("/root/Game").go(WORLD_SCENE, "FromHouse")


# --- Game's interaction hooks ------------------------------------------------------------------------------------

func context_at(point: Vector2) -> String:
	var at := point / UNIT
	return "homeDoor:door" if at.distance_to(Vector2(H.DOOR.x, H.ROOM.h)) <= 0.8 else ""


func action_label(id: String) -> String:
	return "밖으로 나가기" if id == "homeDoor:door" else ""


func interact(id: String) -> String:
	if id == "homeDoor:door":
		leave()
	return ""


# --- drawing -------------------------------------------------------------------------------------------------

func _draw() -> void:
	var w: float = H.ROOM.w * UNIT
	var h: float = H.ROOM.h * UNIT
	draw_rect(Rect2(-200, -200, w + 400, h + 400), Color8(24, 20, 18))
	draw_rect(Rect2(-float(H.SIDE_PX), -float(H.BACK_PX), w + 2.0 * H.SIDE_PX, h + H.BACK_PX + H.BOTTOM_PX), Color8(118, 86, 60))
	draw_rect(Rect2(-float(H.SIDE_PX), -float(H.BACK_PX), w + 2.0 * H.SIDE_PX, float(H.BACK_PX)), Color8(196, 170, 136))
	draw_rect(Rect2(0, 0, w, h), Color8(170, 128, 88))
	for i in int(h / 16.0) + 1:
		draw_line(Vector2(0, i * 16.0), Vector2(w, i * 16.0), Color8(150, 110, 74), 1.0)
	var door := Vector2(H.DOOR.x, H.ROOM.h) * UNIT
	draw_rect(Rect2(door.x - H.DOOR.half * UNIT, h - 2, H.DOOR.half * 2.0 * UNIT, float(H.BOTTOM_PX) + 2.0), Color8(70, 50, 34))
	var rug: Dictionary = H.RUG
	draw_rect(Rect2((rug.x - rug.w / 2.0) * UNIT, (rug.y - rug.h / 2.0) * UNIT, rug.w * UNIT, rug.h * UNIT), Color8(160, 72, 66))
	draw_rect(Rect2((rug.x - rug.w / 2.0) * UNIT + 4, (rug.y - rug.h / 2.0) * UNIT + 4, rug.w * UNIT - 8, rug.h * UNIT - 8), Color8(214, 168, 96), false, 1.0)
	for f: Dictionary in H.FURNITURE:
		_draw_furniture(f)


func _draw_furniture(f: Dictionary) -> void:
	var at := Vector2(f.x, f.y) * UNIT
	var b: Dictionary = f.get("box") if f.get("box") is Dictionary else {"minX": -0.1, "maxX": 0.1, "minY": -0.1, "maxY": 0.0}
	var r := Rect2(at.x + b.minX * UNIT, at.y + b.minY * UNIT, (b.maxX - b.minX) * UNIT, (b.maxY - b.minY) * UNIT)
	match str(f.key):
		"bed":
			draw_rect(r, Color8(120, 84, 56))
			draw_rect(r.grow(-3), Color8(226, 222, 210))
			draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8, 14)), Color8(244, 240, 230))
			draw_rect(Rect2(r.position + Vector2(3, r.size.y * 0.45), Vector2(r.size.x - 6, r.size.y * 0.5)), Color8(96, 132, 180))
		"shelf":
			draw_rect(Rect2(r.position + Vector2(0, -26), Vector2(r.size.x, r.size.y + 26)), Color8(110, 76, 50))
			for i in 3:
				draw_rect(Rect2(r.position + Vector2(4 + i * 18, -22), Vector2(6, 14)), [Color8(170, 60, 60), Color8(70, 110, 160), Color8(200, 170, 80)][i])
		"table":
			draw_rect(r, Color8(140, 98, 62))
			draw_rect(Rect2(r.position + Vector2(4, 2), Vector2(r.size.x - 8, 3)), Color8(170, 124, 82))
		"stool":
			draw_rect(r, Color8(126, 88, 56))
		"stove":
			draw_rect(Rect2(r.position + Vector2(0, -10), r.size + Vector2(0, 10)), Color8(70, 66, 64))
			draw_rect(Rect2(r.position + Vector2(6, -2), Vector2(r.size.x - 12, 8)), Color8(255, 150, 70))
		"chest":
			draw_rect(r, Color8(140, 96, 52))
			draw_rect(Rect2(r.position + Vector2(0, r.size.y * 0.4), Vector2(r.size.x, 2)), Color8(90, 60, 30))
		"plant":
			draw_rect(r, Color8(160, 96, 64))
			draw_circle(r.position + Vector2(r.size.x / 2.0, -6), 9.0, Color8(80, 140, 80))
