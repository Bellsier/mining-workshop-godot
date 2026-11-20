extends Node2D
## What stands on the world map besides the ground, the veins and the scenery (web topdown render/sprites/light):
## the village ground (plaza, roads, garden lawn), the craft huts, the appraiser and the museum by restoration
## stage, the player's house, the garden decorations and the torches, with their wall boxes (they block the
## player like the web worldObstacles), the hired workers (world_workers.gd) and the dusk light (world_light.gd).
## Drawing and collision only; the rules are in scripts/workshop.gd and scripts/village_layout.gd.
## The buildings (the workshop cabin, the craft huts, the village facilities, the house) are drawn on two layers
## round the player, each building on its own merit (web tdDrawList's sort by the ground point): a building whose
## picture overlaps the player's and whose front wall line is south of the player's feet goes on the layer over
## the player; every other building on the layer under. North to south within a layer.

const WorldData := preload("res://scripts/world/world_data.gd")
const Sprites := preload("res://scripts/world/world_sprites.gd")
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
## The buildings under the player (z 1) and over the player (z 3); the player is z 2. The workers (z 2, drawn
## before the player) stay over the buildings, except one the player is standing behind just then.
var buildings: Node2D
var buildings_front: Node2D
## Indices into _occluders of the buildings over the player now.
var _front: Array = []
## Where the building drawing goes (the buildings' layer while it draws).
var _c: CanvasItem = self
## {rect, foot, draw}: each building's drawn area, its front wall line (world px) and how to draw it, north first.
var _occluders: Array = []


func setup(game_economy: Node, world_state: RefCounted, walker: Node2D) -> void:
	economy = game_economy
	world = world_state
	player = walker
	_bodies = Node2D.new()
	_bodies.name = "VillageBodies"
	add_child(_bodies)
	buildings = Node2D.new()
	buildings.name = "Buildings"
	buildings.z_index = 1
	buildings.draw.connect(_draw_layer.bind(false))
	add_child(buildings)
	buildings_front = Node2D.new()
	buildings_front.name = "BuildingsFront"
	buildings_front.z_index = 3
	buildings_front.draw.connect(_draw_layer.bind(true))
	add_child(buildings_front)
	if is_instance_valid(player):
		player.z_index = 2
	var workers := preload("res://scripts/world/world_workers.gd").new()
	workers.name = "Workers"
	workers.z_index = 2 # over the buildings (under the player, drawn after them), as before buildings had layers
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
	var draw_key := JSON.stringify([key, world.torches, world.workshops, village.get("stage"), economy.garden_ui if economy != null else {},
		[world.base.x, world.base.y]])
	if draw_key != _draw_key:
		_draw_key = draw_key
		_occluders = _occluder_list(village)
		_front = covering()
		queue_redraw()
		buildings.queue_redraw()
		buildings_front.queue_redraw()


## Each building's drawn area and the line of its front wall (the bottom of its wall box).
func _occluder_list(village: Dictionary) -> Array:
	var out: Array = []
	var boxes := WorldData.obstacle_boxes()
	var base := to_px(world.base.x, world.base.y)
	out.append({"rect": Rect2(base + Vector2(-32, -54), Vector2(64, 58)), "foot": base.y + float(boxes.base.maxY) * UNIT,
		"draw": _draw_cabin.bind(base)})
	for w_index in world.workshops.size():
		var w: Dictionary = world.workshops[w_index]
		var at := to_px(w.x, w.y)
		out.append({"rect": Rect2(at + Vector2(-19, -31), Vector2(38, 25)), "foot": at.y + float(boxes.workshop.maxY) * UNIT,
			"draw": _draw_hut.bind(w, w_index)})
	var sites: Dictionary = village.get("sites", {})
	for key: String in Layout.ORDER:
		if sites.get(key) is Dictionary:
			var at := to_px(sites[key].x, sites[key].y)
			var b: Dictionary = Layout.V().FACILITIES[key].box
			var w: float = (b.maxX - b.minX) * UNIT
			var h: float = (b.maxY - b.minY) * UNIT + 4.0
			out.append({"rect": Rect2(at + Vector2(-w / 2.0 - 3.0, -16.0 - h), Vector2(w + 6.0, 10.0 + h)), "foot": at.y + float(b.maxY) * UNIT,
				"draw": _draw_facility.bind(key, sites[key], int(village.get("stage", {}).get(key, 0)))})
	if village.get("district") is Dictionary:
		var door: Dictionary = Layout.district_parts(village.district).house
		var at := to_px(door.x, door.y)
		out.append({"rect": Rect2(at + Vector2(-36, -64), Vector2(72, 58)), "foot": at.y - 6.0, "draw": _draw_house.bind(door)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.foot) < float(b.foot))
	return out


## The buildings drawn over the player now (indices into _occluders): those whose picture overlaps the player's
## (16 x 24 above the feet) and whose front wall line is south of the feet.
func covering() -> Array:
	var out: Array = []
	if not is_instance_valid(player):
		return out
	var feet := player.position
	var body := Rect2(feet + Vector2(-8, -24), Vector2(16, 24))
	for i in _occluders.size():
		var o: Dictionary = _occluders[i]
		if feet.y < float(o.foot) and (o.rect as Rect2).intersects(body):
			out.append(i)
	return out


func player_behind() -> bool:
	return not covering().is_empty()


func _process(_delta: float) -> void:
	var now := covering()
	if now != _front:
		_front = now
		buildings.queue_redraw()
		buildings_front.queue_redraw()


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
	if village.get("district") is Dictionary:
		var cells := Layout.garden_cells(village)
		var carry := int(economy.garden_ui.carry) if economy != null else -1
		for d: Dictionary in village.get("decor", []):
			if int(d.cell) < cells.size():
				_draw_decor(str(d.kind), cells[d.cell], int(d.cell) == carry)
	for t: Dictionary in world.torches:
		_draw_torch(to_px(t.x, t.y))


## One of the buildings' layers: the buildings over the player (front) or the rest, north to south.
func _draw_layer(front: bool) -> void:
	if world == null:
		return
	_c = buildings_front if front else buildings
	for i in _occluders.size():
		if (i in _front) == front:
			_occluders[i].draw.call()
	_c = self


## The workshop cabin (web tdBaseSprite) and its name.
func _draw_cabin(base: Vector2) -> void:
	var cabin := Sprites.base()
	_c.draw_texture(cabin, Sprites.origin(cabin, base, Sprites.ANCHOR.base))
	_label(base + Vector2(0, -60), "공방")


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
	_c.draw_string_outline(FONT, at - Vector2(width / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color("241b19"))
	_c.draw_string(FONT, at - Vector2(width / 2.0, 0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("f7e1b8"))


func _draw_hut(w: Dictionary, index: int) -> void:
	var at := to_px(w.x, w.y)
	_c.draw_rect(Rect2(at + Vector2(-16, -20), Vector2(32, 14)), Color8(126, 98, 70))
	_c.draw_colored_polygon(PackedVector2Array([at + Vector2(-19, -19), at + Vector2(0, -31), at + Vector2(19, -19)]), Color8(92, 116, 140))
	_c.draw_rect(Rect2(at + Vector2(-4, -13), Vector2(8, 7)), Color8(62, 44, 30))
	# the forge window glows
	_c.draw_rect(Rect2(at + Vector2(-13, -16), Vector2(5, 4)), Color8(255, 160, 80))
	_label(at + Vector2(0, -34), "제작소 %d" % (index + 1))


func _draw_facility(key: String, site: Dictionary, stage: int) -> void:
	var at := to_px(site.x, site.y)
	var b: Dictionary = Layout.V().FACILITIES[key].box
	var w: float = (b.maxX - b.minX) * UNIT
	var name: String = Layout.V().FACILITIES[key].name
	if stage <= 0:
		# 폐허: broken walls and rubble
		_c.draw_rect(Rect2(at + Vector2(-w / 2.0, -14), Vector2(w * 0.35, 10)), Color8(120, 112, 104))
		_c.draw_rect(Rect2(at + Vector2(w * 0.1, -18), Vector2(w * 0.4, 14)), Color8(110, 102, 96))
		_c.draw_circle(at + Vector2(-4, -3), 4.0, Color8(130, 122, 112))
		_c.draw_circle(at + Vector2(7, -2), 3.0, Color8(118, 110, 100))
	elif stage == 1:
		# 정리됨: cleared ground and a frame
		_c.draw_rect(Rect2(at + Vector2(-w / 2.0, -8), Vector2(w, 4)), Color8(150, 122, 86))
		_c.draw_rect(Rect2(at + Vector2(-w / 2.0, -26), Vector2(3, 20)), Color8(120, 92, 60))
		_c.draw_rect(Rect2(at + Vector2(w / 2.0 - 3, -26), Vector2(3, 20)), Color8(120, 92, 60))
		_c.draw_rect(Rect2(at + Vector2(-w / 2.0, -28), Vector2(w, 3)), Color8(120, 92, 60))
	else:
		var wall := Color8(196, 176, 140) if key == "museum" else Color8(170, 132, 96)
		var roof := Color8(130, 70, 60) if key == "museum" else Color8(90, 110, 80)
		var h: float = (b.maxY - b.minY) * UNIT + 4.0
		_c.draw_rect(Rect2(at + Vector2(-w / 2.0, -6 - h), Vector2(w, h)), wall)
		_c.draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 2.0 - 3, -5 - h), at + Vector2(0, -16 - h), at + Vector2(w / 2.0 + 3, -5 - h)]), roof)
		_c.draw_rect(Rect2(at + Vector2(-4, -13), Vector2(8, 7)), Color8(62, 44, 30))
	_label(at + Vector2(0, -40), name)


func _draw_house(door: Dictionary) -> void:
	var at := to_px(door.x, door.y)
	_c.draw_rect(Rect2(at + Vector2(-32, -46), Vector2(64, 40)), Color8(214, 186, 150))
	_c.draw_colored_polygon(PackedVector2Array([at + Vector2(-36, -45), at + Vector2(0, -64), at + Vector2(36, -45)]), Color8(160, 82, 64))
	_c.draw_rect(Rect2(at + Vector2(-5, -18), Vector2(10, 12)), Color8(92, 62, 40))
	_c.draw_rect(Rect2(at + Vector2(-24, -34), Vector2(10, 8)), Color8(255, 220, 150))
	_c.draw_rect(Rect2(at + Vector2(14, -34), Vector2(10, 8)), Color8(255, 220, 150))
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
