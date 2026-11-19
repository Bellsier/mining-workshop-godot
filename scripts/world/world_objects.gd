extends Node2D
## What stands on the world map besides the ground, the veins and the scenery (web topdown render/sprites/light):
## the village ground (plaza, roads, garden lawn), the craft huts, the appraiser and the museum by restoration
## stage, the player's house, the garden decorations and the torches, with their wall boxes (they block the
## player like the web worldObstacles), the hired workers (world_workers.gd) and the dusk light (world_light.gd).
## Drawing and collision only; the rules are in scripts/workshop.gd and scripts/village_layout.gd.

const WorldData := preload("res://scripts/world/world_data.gd")
const Layout := preload("res://scripts/village_layout.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")

const UNIT := 64.0

var economy: Node
var world: RefCounted
var player: Node2D
var _bodies: Node2D
var _bodies_key := ""
var _draw_key := ""
var light: Node2D


func setup(game_economy: Node, world_state: RefCounted, walker: Node2D) -> void:
	economy = game_economy
	world = world_state
	player = walker
	_bodies = Node2D.new()
	_bodies.name = "VillageBodies"
	add_child(_bodies)
	var workers := preload("res://scripts/world/world_workers.gd").new()
	workers.name = "Workers"
	add_child(workers)
	workers.setup(economy, world)
	light = preload("res://scripts/world/world_light.gd").new()
	light.name = "Light"
	add_child(light)
	light.setup(economy, world, player, workers)
	if economy != null:
		economy.changed.connect(_refresh)
	_refresh()


func to_px(x: float, y: float) -> Vector2:
	return Vector2(x, y) * UNIT


func _village() -> Dictionary:
	return economy.state.village if economy != null else {}


func _roads() -> Array:
	return economy.village_roads() if economy != null else []


## Rebuilds the wall boxes and the fixed lights when what they come from changed; redraws.
func _refresh() -> void:
	if world == null:
		return
	var village := _village()
	var key := JSON.stringify([world.workshops.map(func(w: Dictionary) -> Array: return [w.x, w.y]), village.get("sites"),
		village.get("district"), village.get("decor"), economy.garden_ui.carry if economy != null else -1])
	if key != _bodies_key:
		_bodies_key = key
		for child in _bodies.get_children():
			child.queue_free()
		for w: Dictionary in world.workshops:
			_add_box(Layout.object_box("workshop", w.x, w.y))
		for o: Dictionary in Layout.village_boxes(village, int(economy.garden_ui.carry) if economy != null else -1):
			_add_box(o)
	var draw_key := JSON.stringify([key, world.torches, world.workshops, village.get("stage"), economy.garden_ui if economy != null else {}])
	if draw_key != _draw_key:
		_draw_key = draw_key
		queue_redraw()


func _add_box(o: Dictionary) -> void:
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(o.maxX - o.minX, o.maxY - o.minY) * UNIT
	shape.shape = rect
	body.position = Vector2((o.minX + o.maxX) / 2.0, (o.minY + o.maxY) / 2.0) * UNIT
	body.add_child(shape)
	_bodies.add_child(body)


# --- drawing -------------------------------------------------------------------------------------------------

func _draw() -> void:
	if world == null:
		return
	var village := _village()
	_draw_ground(village)
	for w_index in world.workshops.size():
		_draw_hut(world.workshops[w_index], w_index)
	var sites: Dictionary = village.get("sites", {})
	for key: String in Layout.ORDER:
		if sites.get(key) is Dictionary:
			_draw_facility(key, sites[key], int(village.get("stage", {}).get(key, 0)))
	if village.get("district") is Dictionary:
		var parts := Layout.district_parts(village.district)
		_draw_house(parts.house)
		var cells := Layout.garden_cells(village)
		var carry := int(economy.garden_ui.carry) if economy != null else -1
		for d: Dictionary in village.get("decor", []):
			if int(d.cell) < cells.size():
				_draw_decor(str(d.kind), cells[d.cell], int(d.cell) == carry)
	for t: Dictionary in world.torches:
		_draw_torch(to_px(t.x, t.y))


func _draw_ground(village: Dictionary) -> void:
	if not village.get("district") is Dictionary:
		return
	var parts := Layout.district_parts(village.district)
	var road_half: float = Layout.V().DISTRICT.ROAD_HALF
	var dirt := Color8(176, 140, 96)
	for road: Dictionary in _roads():
		var pts: Array = road.points
		for i in pts.size() - 1:
			draw_line(to_px(pts[i].x, pts[i].y), to_px(pts[i + 1].x, pts[i + 1].y), dirt, road_half * 2.0 * UNIT)
		for p: Dictionary in pts:
			draw_circle(to_px(p.x, p.y), road_half * UNIT, dirt)
	var plaza: Dictionary = parts.plaza
	draw_circle(to_px(plaza.x, plaza.y), plaza.r * UNIT, Color8(196, 170, 128))
	draw_arc(to_px(plaza.x, plaza.y), plaza.r * UNIT, 0.0, TAU, 40, Color8(150, 122, 86), 2.0)
	# the notice board north of the plaza centre
	var board := to_px(plaza.x, plaza.y - 0.15)
	draw_rect(Rect2(board + Vector2(-9, -20), Vector2(18, 12)), Color8(132, 96, 60))
	draw_rect(Rect2(board + Vector2(-7, -18), Vector2(14, 8)), Color8(236, 220, 184))
	draw_rect(Rect2(board + Vector2(-1, -8), Vector2(2, 8)), Color8(96, 70, 44))
	var g: Dictionary = parts.garden
	draw_rect(Rect2(to_px(g.x - g.hw, g.y - g.hh), Vector2(g.hw * 2.0, g.hh * 2.0) * UNIT), Color8(92, 150, 78))
	draw_rect(Rect2(to_px(g.x - g.hw, g.y - g.hh), Vector2(g.hw * 2.0, g.hh * 2.0) * UNIT), Color8(70, 116, 60), false, 2.0)


func _label(at: Vector2, text: String) -> void:
	var width := FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
	draw_string_outline(FONT, at - Vector2(width / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color("241b19"))
	draw_string(FONT, at - Vector2(width / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("f7e1b8"))


func _draw_hut(w: Dictionary, index: int) -> void:
	var at := to_px(w.x, w.y)
	draw_rect(Rect2(at + Vector2(-16, -20), Vector2(32, 14)), Color8(126, 98, 70))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-19, -19), at + Vector2(0, -31), at + Vector2(19, -19)]), Color8(92, 116, 140))
	draw_rect(Rect2(at + Vector2(-4, -13), Vector2(8, 7)), Color8(62, 44, 30))
	# the forge window glows
	draw_rect(Rect2(at + Vector2(-13, -16), Vector2(5, 4)), Color8(255, 160, 80))
	_label(at + Vector2(0, -34), "제작소 %d" % (index + 1))


func _draw_facility(key: String, site: Dictionary, stage: int) -> void:
	var at := to_px(site.x, site.y)
	var b: Dictionary = Layout.V().FACILITIES[key].box
	var w: float = (b.maxX - b.minX) * UNIT
	var name: String = Layout.V().FACILITIES[key].name
	if stage <= 0:
		# 폐허: broken walls and rubble
		draw_rect(Rect2(at + Vector2(-w / 2.0, -14), Vector2(w * 0.35, 10)), Color8(120, 112, 104))
		draw_rect(Rect2(at + Vector2(w * 0.1, -18), Vector2(w * 0.4, 14)), Color8(110, 102, 96))
		draw_circle(at + Vector2(-4, -3), 4.0, Color8(130, 122, 112))
		draw_circle(at + Vector2(7, -2), 3.0, Color8(118, 110, 100))
	elif stage == 1:
		# 정리됨: cleared ground and a frame
		draw_rect(Rect2(at + Vector2(-w / 2.0, -8), Vector2(w, 4)), Color8(150, 122, 86))
		draw_rect(Rect2(at + Vector2(-w / 2.0, -26), Vector2(3, 20)), Color8(120, 92, 60))
		draw_rect(Rect2(at + Vector2(w / 2.0 - 3, -26), Vector2(3, 20)), Color8(120, 92, 60))
		draw_rect(Rect2(at + Vector2(-w / 2.0, -28), Vector2(w, 3)), Color8(120, 92, 60))
	else:
		var wall := Color8(196, 176, 140) if key == "museum" else Color8(170, 132, 96)
		var roof := Color8(130, 70, 60) if key == "museum" else Color8(90, 110, 80)
		var h: float = (b.maxY - b.minY) * UNIT + 4.0
		draw_rect(Rect2(at + Vector2(-w / 2.0, -6 - h), Vector2(w, h)), wall)
		draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 2.0 - 3, -5 - h), at + Vector2(0, -16 - h), at + Vector2(w / 2.0 + 3, -5 - h)]), roof)
		draw_rect(Rect2(at + Vector2(-4, -13), Vector2(8, 7)), Color8(62, 44, 30))
	_label(at + Vector2(0, -40), name)


func _draw_house(door: Dictionary) -> void:
	var at := to_px(door.x, door.y)
	draw_rect(Rect2(at + Vector2(-32, -46), Vector2(64, 40)), Color8(214, 186, 150))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-36, -45), at + Vector2(0, -64), at + Vector2(36, -45)]), Color8(160, 82, 64))
	draw_rect(Rect2(at + Vector2(-5, -18), Vector2(10, 12)), Color8(92, 62, 40))
	draw_rect(Rect2(at + Vector2(-24, -34), Vector2(10, 8)), Color8(255, 220, 150))
	draw_rect(Rect2(at + Vector2(14, -34), Vector2(10, 8)), Color8(255, 220, 150))
	_label(at + Vector2(0, -68), "내 집")


func _draw_decor(kind: String, cell: Dictionary, carried: bool) -> void:
	var at := to_px(cell.x, cell.y)
	var alpha := 0.45 if carried else 1.0
	match kind:
		"flowerPot":
			draw_rect(Rect2(at + Vector2(-5, -6), Vector2(10, 7)), Color(0.62, 0.38, 0.26, alpha))
			draw_circle(at + Vector2(-2, -9), 3.0, Color(0.94, 0.47, 0.55, alpha))
			draw_circle(at + Vector2(3, -9), 3.0, Color(0.98, 0.83, 0.38, alpha))
		"bench":
			draw_rect(Rect2(at + Vector2(-13, -8), Vector2(26, 4)), Color(0.55, 0.38, 0.24, alpha))
			draw_rect(Rect2(at + Vector2(-11, -4), Vector2(2, 5)), Color(0.4, 0.27, 0.17, alpha))
			draw_rect(Rect2(at + Vector2(9, -4), Vector2(2, 5)), Color(0.4, 0.27, 0.17, alpha))
		"lantern":
			draw_rect(Rect2(at + Vector2(-4, -16), Vector2(8, 16)), Color(0.6, 0.6, 0.58, alpha))
			draw_rect(Rect2(at + Vector2(-3, -13), Vector2(6, 5)), Color(1.0, 0.86, 0.55, alpha))
		"shrub":
			draw_circle(at + Vector2(0, -6), 8.0, Color(0.27, 0.52, 0.29, alpha))
		"oreStatue":
			draw_rect(Rect2(at + Vector2(-6, -4), Vector2(12, 4)), Color(0.5, 0.48, 0.46, alpha))
			draw_colored_polygon(PackedVector2Array([at + Vector2(-5, -4), at + Vector2(0, -20), at + Vector2(5, -4)]), Color(0.72, 0.68, 0.62, alpha))
		"crystalFountain":
			draw_circle(at + Vector2(0, -4), 12.0, Color(0.55, 0.62, 0.7, alpha))
			draw_circle(at + Vector2(0, -4), 8.0, Color(0.55, 0.8, 0.95, alpha))
			draw_colored_polygon(PackedVector2Array([at + Vector2(-3, -6), at + Vector2(0, -18), at + Vector2(3, -6)]), Color(0.75, 0.9, 1.0, alpha))
		"goldenPick":
			draw_rect(Rect2(at + Vector2(-6, -4), Vector2(12, 4)), Color(0.5, 0.48, 0.46, alpha))
			draw_line(at + Vector2(-6, -20), at + Vector2(6, -6), Color(0.95, 0.78, 0.3, alpha), 2.0)
			draw_line(at + Vector2(-9, -16), at + Vector2(-2, -22), Color(0.95, 0.78, 0.3, alpha), 3.0)


func _draw_torch(at: Vector2) -> void:
	draw_rect(Rect2(at + Vector2(-1.5, -14), Vector2(3, 14)), Color8(110, 78, 48))
	draw_circle(at + Vector2(0, -16), 3.5, Color8(255, 176, 92))
	draw_circle(at + Vector2(0, -17), 2.0, Color8(255, 236, 170))
