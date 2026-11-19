extends Node2D
## What stands on the world map besides the ground, the veins and the scenery (web topdown render/sprites/light):
## the village ground (plaza, roads, garden lawn), the craft huts, the appraiser and the museum by restoration
## stage, the player's house, the garden decorations and the torches, with their wall boxes (they block the
## player like the web worldObstacles), and the light: a slow dusk cycle with warm lights at the workshop lamp,
## the huts' forges, the found veins, the torches, the lantern decorations and round the player.
## Drawing and collision only; the rules are in scripts/workshop.gd and scripts/village_layout.gd.

const WorldData := preload("res://scripts/world/world_data.gd")
const Layout := preload("res://scripts/village_layout.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")

const UNIT := 64.0
## web TD_LIGHT: one day-to-dusk cycle, the lightest and darkest tint and its colour.
const CYCLE_MS := 8 * 60 * 1000
const MIN_DARK := 0.10
const MAX_DARK := 0.34
const AMBIENT := Color8(16, 22, 42)
const VEIN_LIGHT := {
	"iron": Color("c8b8a8"), "coal": Color("8a8ca0"), "mana": Color("58c9a6"), "crystal": Color("a9dafb"),
	"rareMetal": Color("edbd64"), "relic": Color("df8b66"), "cosmicShard": Color("c99aee"), "plasma": Color("ea7ec7"),
}

var economy: Node
var world: RefCounted
var player: Node2D
var _bodies: Node2D
var _bodies_key := ""
var _draw_key := ""
var _modulate: CanvasModulate
var _lights: Node2D
var _light_texture: Texture2D
var _player_lights: Array[PointLight2D] = []
var _lights_key := ""
var _flicker: Array = []


func setup(game_economy: Node, world_state: RefCounted, walker: Node2D) -> void:
	economy = game_economy
	world = world_state
	player = walker
	_bodies = Node2D.new()
	_bodies.name = "VillageBodies"
	add_child(_bodies)
	_lights = Node2D.new()
	_lights.name = "Lights"
	add_child(_lights)
	var workers := preload("res://scripts/world/world_workers.gd").new()
	workers.name = "Workers"
	add_child(workers)
	workers.setup(economy, world)
	_modulate = CanvasModulate.new()
	_modulate.name = "Dusk"
	get_parent().get_parent().add_child.call_deferred(_modulate)
	_light_texture = _make_light_texture()
	for i in 2:
		var light := _light()
		_player_lights.append(light)
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
	var lights_key := JSON.stringify([key, world.torches, world.mines.filter(func(m: Dictionary) -> bool: return world.is_discovered(m)).map(
		func(m: Dictionary) -> Array: return [m.id, m.developmentState])])
	if lights_key != _lights_key:
		_lights_key = lights_key
		_build_fixed_lights()
	var draw_key := JSON.stringify([lights_key, world.workshops, village.get("stage"), economy.garden_ui if economy != null else {}])
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


# --- light ---------------------------------------------------------------------------------------------------

## web tdAmbientDarkness: a smooth cycle between MIN_DARK and MAX_DARK.
static func darkness(now_ms: float) -> float:
	var ph := fposmod(now_ms, CYCLE_MS) / CYCLE_MS
	var k := 0.5 - 0.5 * cos(ph * TAU)
	return MIN_DARK + (MAX_DARK - MIN_DARK) * k


func _make_light_texture() -> Texture2D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 128
	texture.height = 128
	return texture


func _light() -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = _light_texture
	light.blend_mode = Light2D.BLEND_MODE_ADD
	_lights.add_child(light)
	return light


## A light of radius `r` world units at (x, y) (web tdLightList entries).
func _place(light: PointLight2D, x: float, y: float, r: float, color: Color, strength: float) -> void:
	light.position = to_px(x, y)
	light.texture_scale = r
	light.color = color
	light.energy = strength * 0.55


func _build_fixed_lights() -> void:
	for child in _lights.get_children():
		if child not in _player_lights:
			child.queue_free()
	_flicker.clear()
	var warm := Color8(255, 210, 130)
	var b: Vector2i = world.base
	# [light, x, y, radius, colour, strength, flicker seed, flicker the radius (else the strength)]
	_flicker.append([_light(), b.x + 0.62, b.y - 0.3, 1.6, warm, 0.9, 1.0, true])
	_flicker.append([_light(), b.x - 0.24, b.y - 0.3, 0.55, warm, 0.5, 3.0, false])
	_flicker.append([_light(), b.x + 0.26, b.y - 0.3, 0.55, warm, 0.5, 4.0, false])
	for i in world.workshops.size():
		var w: Dictionary = world.workshops[i]
		_flicker.append([_light(), w.x - 0.17, w.y - 0.2, 0.7, Color8(255, 150, 70), 0.6, 7.0 + i, true])
	for m: Dictionary in world.mines:
		if not world.is_discovered(m):
			continue # a hidden vein never glows: light must not give it away
		var secured: bool = m.developmentState == "secured"
		_place(_light(), m.x, m.y - 0.05, 0.8 if secured else 0.55, VEIN_LIGHT.get(m.resource, Color.WHITE), 0.5 if secured else 0.32)
	for i in world.torches.size():
		var t: Dictionary = world.torches[i]
		_flicker.append([_light(), t.x, t.y - 0.25, 1.35, Color8(255, 176, 92), 0.95, 11.0 + i * 2.3, true])
	var village := _village()
	var cells := Layout.garden_cells(village)
	for d: Dictionary in village.get("decor", []):
		if Layout.decor_def(d.kind).get("light", false) and int(d.cell) < cells.size():
			_place(_light(), cells[d.cell].x, cells[d.cell].y - 0.2, 0.9, Color8(255, 214, 150), 0.6)


func _process(_delta: float) -> void:
	if world == null:
		return
	var now := Time.get_unix_time_from_system() * 1000.0
	var dark := darkness(now)
	_modulate.color = Color(1, 1, 1).lerp(AMBIENT, dark)
	# web tdFlicker: 0.88 + 0.12 sin(t / 140 + seed) sin(t / 53 + 1.7 seed)
	for f: Array in _flicker:
		var flick := 0.88 + 0.12 * sin(now / 140.0 + f[6]) * sin(now / 53.0 + f[6] * 1.7)
		_place(f[0], f[1], f[2], f[3] * (flick if f[7] else 1.0), f[4], f[5] * (1.0 if f[7] else flick))
	if is_instance_valid(player):
		var at: Vector2 = player.position / UNIT
		# web tdLanternLight: next to nothing in full day, a warm pool at the darkest dusk
		var k := clampf((dark - MIN_DARK - 0.02) / (MAX_DARK - MIN_DARK - 0.02), 0.0, 1.0)
		_place(_player_lights[0], at.x, at.y - 0.22, 1.1 + 0.5 * k, Color8(255, 214, 150), 0.12 + 0.68 * k)
		_place(_player_lights[1], at.x, at.y - 0.15, 0.8, Color8(255, 236, 190), 0.6)


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
