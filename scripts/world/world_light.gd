extends Node2D
## The dusk tint and its lights, drawn like web topdown/light.js tdRenderLighting: the darkness is painted into a
## small "light map" (a fraction of the screen), every light clears a soft hole in it and leaves a warm or ore
## coloured glow, and the map is laid over the world once. So any number of lights costs one small map and one
## screen pass (Godot's own 2D lights shade every pixel of everything once per light, which halved the frame
## rate of the software-rendered web build). The map shrinks by itself when frames get slow (web tdQualityFor).
## Cloud shadows drift over the land (web tdCloudShadows, not at the lowest quality) and fireflies come out at dusk
## (web tdFireflies, full quality only).
## Drawing only: no game value depends on it and nothing is saved.

const Layout := preload("res://scripts/village_layout.gd")

const UNIT := 64.0
## web TD_LIGHT
const CYCLE_MS := 8 * 60 * 1000
const MIN_DARK := 0.10
const MAX_DARK := 0.34
const AMBIENT := Color8(16, 22, 42)
const MAP_SCALE := [0.34, 0.25, 0.2]
## web TD_RES_COLORS[resource][0]: the glow colour of a found vein.
const VEIN_RGB := {
	"iron": Color8(0xb8, 0x70, 0x4f), "coal": Color8(0x2c, 0x30, 0x34), "mana": Color8(0x8a, 0x5c, 0xd6),
	"crystal": Color8(0x4f, 0xc4, 0xdc), "rareMetal": Color8(0xb9, 0xc3, 0xcc), "relic": Color8(0xc9, 0xa2, 0x4a),
	"cosmicShard": Color8(0xe0, 0x6f, 0xa8), "plasma": Color8(0xff, 0x4f, 0xcf),
}
const WARM := Color8(255, 210, 130)
## web TD_LIGHT.FIREFLY_DARK: fireflies come out above this darkness.
const FIREFLY_DARK := 0.2

## Clears the dark: dst *= (1 - a), where a is the hole's strength times its soft edge. Multiplying colour and
## alpha alike keeps the map premultiplied, as the canvas 'destination-out' of the web leaves it.
const HOLE_SHADER := """
shader_type canvas_item;
render_mode blend_mul, unshaded;
void fragment() {
	COLOR = vec4(1.0 - COLOR.a);
}
"""

var economy: Node
var world: RefCounted
var player: Node2D
var workers: Node
## Fixed darkness for tests and screenshots (web TD.forceDarkness); negative follows the clock.
var force_darkness := -1.0
var quality := 0

var _map: SubViewport
var _dark: Node2D
var _holes: Node2D
var _glows: Node2D
var _hole_tex: Texture2D
var _glow_tex: Texture2D
var _lights: Array = []
var _clouds: Node2D
var _flies: Node2D
var _cloud_tex: Texture2D
var _fly_tex: Texture2D
var _now := 0.0
var _darkness := MIN_DARK
var _frames := 0
var _frame_avg := -1.0
var _checks := 0


func setup(game_economy: Node, world_state: RefCounted, walker: Node2D, worker_node: Node) -> void:
	economy = game_economy
	world = world_state
	player = walker
	workers = worker_node
	z_index = 4000
	z_as_relative = false
	_hole_tex = _radial([[0.0, 1.0], [0.55, 0.45], [1.0, 0.0]])
	_glow_tex = _radial([[0.0, 1.0], [0.5, 0.4], [1.0, 0.0]])
	_map = SubViewport.new()
	_map.name = "LightMap"
	_map.transparent_bg = true
	_map.disable_3d = true
	_map.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_map)
	_dark = _painter("Dark", null)
	var hole_material := ShaderMaterial.new()
	hole_material.shader = Shader.new()
	hole_material.shader.code = HOLE_SHADER
	_holes = _painter("Holes", hole_material)
	_glows = _painter("Glows", null)
	_dark.draw.connect(func() -> void: _dark.draw_rect(Rect2(Vector2.ZERO, Vector2(_map.size)), Color(AMBIENT, _darkness)))
	_holes.draw.connect(_draw_holes)
	_glows.draw.connect(_draw_glows)
	var shown := CanvasItemMaterial.new()
	shown.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	material = shown
	# Cloud shadows: over the ground and everything on it, under the dusk (web tdRenderClouds before the lighting).
	_cloud_tex = _radial([[0.0, 1.0], [0.2, 1.0], [1.0, 0.0]])
	_clouds = Node2D.new()
	_clouds.name = "CloudShadows"
	_clouds.z_index = 3999
	_clouds.z_as_relative = false
	_clouds.draw.connect(_draw_clouds)
	add_child(_clouds)
	# Fireflies: added light over the dusk (web 'lighter').
	_fly_tex = _radial([[0.0, 1.0], [1.0, 0.0]])
	_flies = Node2D.new()
	_flies.name = "Fireflies"
	_flies.z_index = 4001
	_flies.z_as_relative = false
	var added := CanvasItemMaterial.new()
	added.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_flies.material = added
	_flies.draw.connect(_draw_flies)
	add_child(_flies)


## A radial fade from the centre to the edge of the square, white with these [offset, alpha] stops.
static func _radial(stops: Array) -> Texture2D:
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array(stops.map(func(s: Array) -> float: return s[0]))
	gradient.colors = PackedColorArray(stops.map(func(s: Array) -> Color: return Color(1, 1, 1, s[1])))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	texture.width = 64
	texture.height = 64
	return texture


func _painter(node_name: String, mat: Material) -> Node2D:
	var node := Node2D.new()
	node.name = node_name
	node.material = mat
	_map.add_child(node)
	return node


## web tdAmbientDarkness: a smooth cycle between MIN_DARK and MAX_DARK.
static func darkness(now_ms: float) -> float:
	var ph := fposmod(now_ms, CYCLE_MS) / CYCLE_MS
	var k := 0.5 - 0.5 * cos(ph * TAU)
	return MIN_DARK + (MAX_DARK - MIN_DARK) * k


## web tdFlicker
static func flicker(now_ms: float, seed: float) -> float:
	return 0.88 + 0.12 * sin(now_ms / 140.0 + seed) * sin(now_ms / 53.0 + seed * 1.7)


## web tdCloudShadows: three large soft shapes drifting slowly west to east, in world units {x, y, r}.
static func cloud_shadows(map_rect: Rect2, now_ms: float) -> Array:
	var span := map_rect.size.x + 12.0
	var out: Array = []
	for i in 3:
		var speed := 0.12 + i * 0.03
		var x := map_rect.position.x - 6.0 + fmod(now_ms / 1000.0 * speed + i * span / 3.0, span)
		out.append({"x": x, "y": -7.0 + i * 7.0 + sin(now_ms / 20000.0 + i) * 1.5, "r": 3.2 + i * 0.6})
	return out


## web tdFireflies: a handful of drifting motes near the workshop (and the trees beyond the tunnel once it is
## open), only at dusk, in world units {x, y, glow}.
## (Plain numbers, not Vector2, whose single precision would round the positions.)
static func fireflies(base_x: float, base_y: float, tunnel_open: bool, now_ms: float, dark: float) -> Array:
	if dark < FIREFLY_DARK:
		return []
	var anchors: Array = [[base_x + 1.2, base_y + 0.6], [base_x - 1.4, base_y + 0.9], [base_x + 0.4, base_y - 1.4]]
	if tunnel_open:
		anchors.append_array([[-7.0, -2.0], [-8.0, 3.0], [-6.5, 6.0]])
	var out: Array = []
	for i in anchors.size():
		var ax: float = anchors[i][0]
		var ay: float = anchors[i][1]
		for k in 2:
			var t := now_ms / 1000.0 + i * 3.1 + k * 7.7
			out.append({"x": ax + sin(t * 0.37 + k) * 0.9 + sin(t * 1.3) * 0.15, "y": ay + cos(t * 0.29 + k * 2) * 0.6,
				"glow": 0.5 + 0.5 * sin(t * 2.3 + k)})
	return out


## web tdQualityFor: 0 full, 1 reduced, 2 low, from the average frame time in ms.
static func quality_for(avg_ms: float, current: int) -> int:
	if avg_ms > 34.0:
		return 2
	if avg_ms > 24.0:
		return maxi(current, 1)
	if avg_ms < 19.0 and current > 0:
		return current - 1
	return current


## Every light in world units {kind, x, y, r, rgb, strength, glow} (web tdLightList with the village, plaza,
## house, garden and worker lights it is given). `at` is the player's feet, or null inside nothing.
static func light_list(world_state: RefCounted, village: Dictionary, garden_carry: int, at: Variant, now_ms: float,
		dark: float, worker_spots: Array) -> Array:
	var out: Array = []
	if at is Vector2:
		# graphics pass 2 lantern: next to nothing in full day, a soft warm pool at the darkest dusk
		var k := clampf((dark - MIN_DARK - 0.02) / (MAX_DARK - MIN_DARK - 0.02), 0.0, 1.0)
		out.append({"kind": "lantern", "x": at.x, "y": at.y - 0.22, "r": 1.1 + 0.5 * k, "rgb": Color8(255, 214, 150),
			"strength": 0.12 + 0.68 * k, "glow": 0.4 + 0.9 * k})
		out.append({"kind": "aura", "x": at.x, "y": at.y - 0.15, "r": 0.8, "rgb": Color8(255, 236, 190), "strength": 0.6})
	var b: Vector2i = world_state.base
	out.append({"kind": "lamp", "x": b.x + 0.62, "y": b.y - 0.3, "r": 1.6 * flicker(now_ms, 1), "rgb": WARM, "strength": 0.9})
	for i in 2:
		out.append({"kind": "window", "x": b.x + [-0.24, 0.26][i], "y": b.y - 0.3, "r": 0.55, "rgb": WARM, "strength": 0.5 * flicker(now_ms, 3 + i)})
	for i in world_state.workshops.size():
		var w: Dictionary = world_state.workshops[i]
		out.append({"kind": "forge", "x": w.x - 0.17, "y": w.y - 0.2, "r": 0.7 * flicker(now_ms, 7 + i), "rgb": Color8(255, 150, 70), "strength": 0.6})
	for m: Dictionary in world_state.mines:
		if not world_state.is_discovered(m):
			continue # a hidden vein never glows: light must not give it away
		var secured: bool = m.developmentState == "secured"
		out.append({"kind": "vein", "x": m.x, "y": m.y - 0.05, "r": 0.8 if secured else 0.55,
			"rgb": VEIN_RGB.get(m.resource, Color8(0xcc, 0xcc, 0xcc)), "strength": 0.5 if secured else 0.32})
	for i in world_state.torches.size():
		var t: Dictionary = world_state.torches[i]
		out.append({"kind": "torch", "x": t.x, "y": t.y - 0.25, "r": 1.35 * flicker(now_ms, 11 + i * 2.3), "rgb": Color8(255, 176, 92),
			"strength": 0.95, "glow": 2.4})
	# web tdWorkerLights: a small lamp over each worker in sight
	for p: Vector2 in worker_spots:
		out.append({"kind": "worker", "x": p.x, "y": p.y - 0.3, "r": 0.75, "rgb": Color8(255, 236, 190), "strength": 0.45})
	# web tdVillageLights: the open facilities
	var sites: Dictionary = village.get("sites", {}) if village.get("sites") is Dictionary else {}
	var stage: Dictionary = village.get("stage", {}) if village.get("stage") is Dictionary else {}
	for i in Layout.ORDER.size():
		var k: String = Layout.ORDER[i]
		var site: Variant = sites.get(k)
		if not site is Dictionary or int(stage.get(k, 0)) < 2:
			continue
		if k == "appraiser":
			out.append({"kind": "village", "x": site.x - 0.2, "y": site.y - 0.2, "r": 0.6, "rgb": WARM, "strength": 0.5 * flicker(now_ms, 20 + i)})
		else:
			var donated: int = village.get("donated", []).size()
			out.append({"kind": "village", "x": site.x, "y": site.y - 0.25, "r": 0.9, "rgb": Color8(255, 220, 150),
				"strength": 0.4 + 0.04 * mini(6, ceili(donated / 2.0))})
	if village.get("district") is Dictionary:
		var parts := Layout.district_parts(village.district)
		# web tdPlazaLights: the two plaza lamps; tdHouseLights: the house's door lantern
		for i in 2:
			out.append({"kind": "plaza", "x": parts.plaza.x + [-1, 1][i] * 0.72, "y": parts.plaza.y + 0.5 - 0.3, "r": 0.85,
				"rgb": Color8(255, 214, 140), "strength": 0.62 * flicker(now_ms, 40 + i)})
		out.append({"kind": "house", "x": parts.house.x + 0.23, "y": parts.house.y - 0.31, "r": 0.85, "rgb": Color8(255, 206, 128),
			"strength": 0.5 * flicker(now_ms, 61)})
		# web tdGardenLights: stone lanterns in the garden, not the one being carried
		var cells := Layout.garden_cells(village)
		var i := 0
		for d: Dictionary in village.get("decor", []):
			var cell := int(d.cell)
			if cell != garden_carry and cell < cells.size() and Layout.decor_def(d.kind).get("light", false):
				out.append({"kind": "garden", "x": cells[cell].x, "y": cells[cell].y - 0.2, "r": 0.6, "rgb": Color8(255, 214, 140),
					"strength": 0.45 * flicker(now_ms, 80 + cell + i)})
			i += 1
	return out


func _process(delta: float) -> void:
	if world == null:
		return
	# web: the average frame time sets the quality, checked every 30 frames, the first 20 frames not counted
	_frames += 1
	if _frames > 20:
		var dt := minf(100.0, delta * 1000.0)
		_frame_avg = dt if _frame_avg < 0.0 else _frame_avg * 0.95 + dt * 0.05
		_checks += 1
		if _checks % 30 == 0:
			quality = quality_for(_frame_avg, quality)
	var now := Time.get_unix_time_from_system() * 1000.0
	_now = now
	_darkness = force_darkness if force_darkness >= 0.0 else darkness(now)
	var spots: Array = []
	if workers != null:
		for s: Dictionary in workers._sim.values():
			if not s.get("hidden", false):
				spots.append(Vector2(s.x, s.y))
	var village: Dictionary = economy.state.village if economy != null else {}
	var carry: int = int(economy.garden_ui.carry) if economy != null else -1
	var at: Variant = player.position / UNIT if is_instance_valid(player) else null
	_lights = light_list(world, village, carry, at, now, _darkness, spots)
	var screen := get_viewport_rect().size
	var scale_k: float = MAP_SCALE[quality]
	var size := Vector2i(maxi(1, ceili(screen.x * scale_k)), maxi(1, ceili(screen.y * scale_k)))
	if _map.size != size:
		_map.size = size
	_dark.queue_redraw()
	_holes.queue_redraw()
	_glows.queue_redraw()
	_clouds.queue_redraw()
	_flies.queue_redraw()
	queue_redraw()


## Where a world point lands on the light map, and how many map pixels one world unit is.
func _to_map(x: float, y: float) -> Vector2:
	var screen := get_viewport().get_canvas_transform() * (Vector2(x, y) * UNIT)
	return screen * (Vector2(_map.size) / get_viewport_rect().size)


func _unit_on_map() -> float:
	return UNIT * get_viewport().get_canvas_transform().get_scale().x * float(_map.size.x) / get_viewport_rect().size.x


## Lights off the map are skipped (web onScreen).
func _on_map(l: Dictionary, unit: float) -> bool:
	var p := _to_map(l.x, l.y)
	var r: float = l.r * unit
	return not (p.x + r < 0.0 or p.y + r < 0.0 or p.x - r > _map.size.x or p.y - r > _map.size.y)


func _draw_holes() -> void:
	var unit := _unit_on_map()
	for l: Dictionary in _lights:
		if not _on_map(l, unit):
			continue
		var p := _to_map(l.x, l.y)
		var r: float = l.r * unit
		_holes.draw_texture_rect(_hole_tex, Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), false, Color(1, 1, 1, l.strength))


## web: soft coloured glows over the cleared dark (not for the helmet lamp, which only clears).
func _draw_glows() -> void:
	var unit := _unit_on_map()
	var k := 0.35 + _darkness * 1.4
	for l: Dictionary in _lights:
		if l.kind == "headlamp" or not _on_map(l, unit):
			continue
		var p := _to_map(l.x, l.y)
		var rr: float = l.r * unit * 0.75
		var a := minf(0.42, 0.16 * l.strength * k * float(l.get("glow", 1.0)))
		var c: Color = l.rgb
		_glows.draw_texture_rect(_glow_tex, Rect2(p - Vector2(rr, rr), Vector2(rr, rr) * 2.0), false, Color(c, a))


## The light map over the whole screen (in world coordinates, under the HUD).
func _draw() -> void:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var screen := get_viewport_rect().size
	var top_left := inverse * Vector2.ZERO
	var bottom_right := inverse * screen
	draw_texture_rect(_map.get_texture(), Rect2(top_left, bottom_right - top_left), false)


## The part of the world on screen, in world pixels, with a margin.
func _view(margin: float) -> Rect2:
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	return Rect2(inverse * Vector2.ZERO, Vector2.ZERO).expand(inverse * get_viewport_rect().size).grow(margin)


## web tdRenderClouds: soft dark ellipses (1.6 wide, 0.8 high), 10 % at the middle.
func _draw_clouds() -> void:
	if quality >= 2 or world == null:
		return
	var view := _view(0.0)
	for c: Dictionary in cloud_shadows(world.map_rect(), _now):
		var at := Vector2(c.x, c.y) * UNIT
		var r: float = c.r * UNIT
		var area := Rect2(at - Vector2(r * 1.6, r * 0.8), Vector2(r * 3.2, r * 1.6))
		if area.intersects(view):
			_clouds.draw_texture_rect(_cloud_tex, area, false, Color(10 / 255.0, 20 / 255.0, 20 / 255.0, 0.10))


## web tdRenderLighting fireflies: a pale green glow 6 px round with a one-pixel bright mote.
func _draw_flies() -> void:
	if quality != 0 or world == null:
		return
	var view := _view(20.0)
	for f: Dictionary in fireflies(float(world.base.x), float(world.base.y), world.tunnel_unlocked, _now, _darkness):
		var at := Vector2(f.x, f.y) * UNIT
		if not view.has_point(at):
			continue
		_flies.draw_texture_rect(_fly_tex, Rect2(at - Vector2(6, 6), Vector2(12, 12)), false, Color(220 / 255.0, 1.0, 140 / 255.0, 0.35 * f.glow))
		_flies.draw_rect(Rect2(at.round(), Vector2.ONE), Color(240 / 255.0, 1.0, 190 / 255.0, 0.5 + 0.5 * f.glow))
