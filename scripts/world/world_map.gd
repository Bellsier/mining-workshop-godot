extends Node2D
## The explorable world map (scenes/world/world_map.tscn): the web game's top-down world rebuilt from the
## ported terrain: open ground with the workshop, the mountain range with the tunnel, the land beyond and
## its zones, the veins (hidden until the player walks near), the scenery, and optionally the seeded outer
## world. 1 web world unit = UNIT pixels (a ground tile is a quarter unit, 16 px).
##
## Sits as a child of the level root (scripts/level.gd) BEFORE the Player, so the ground and the spawn
## markers are ready when the level places the player. Only completed construction opens the tunnel.
## FromTunnel is retained solely for the legacy trial-scene route.

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const WorldState := preload("res://scripts/world/world_state.gd")
const WorldTiles := preload("res://scripts/world/world_tiles.gd")
const PassageDoor := preload("res://scripts/world/world_passage_door.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")

const UNIT := 64.0
const REACH := 0.6
const VEIN_COLORS := {
	"iron": Color("b6a698"), "coal": Color("707281"), "mana": Color("58c9a6"), "crystal": Color("a9dafb"),
	"rareMetal": Color("edbd64"), "relic": Color("df8b66"), "cosmicShard": Color("c99aee"), "plasma": Color("ea7ec7"),
}

@export var seeded_world := false
@export var world_seed := 12345

var state: RefCounted
var ground: TileMapLayer
var player: CharacterBody2D
var _bodies: Node2D
var _bodied := {}
var _filled_chunks := {}
var _region_label: Label
var _toast: Label
var _toast_left := 0.0
var _place := ""
var _near_vein: Dictionary = {}

func _ready() -> void:
	var game := get_node_or_null("/root/Game")
	var entry: String = game.spawn_name if game != null else "Start"
	state = WorldState.current()
	if state == null:
		state = WorldState.new_game(-1, seeded_world, world_seed)
		WorldState.set_current(state)
	state.tunnel_opened.connect(_on_tunnel_opened)
	state.survey_completed.connect(func(_added): _sync_bodies.call_deferred())
	state.discovered.connect(_on_discovered)
	ground = get_parent().get_node("Ground")
	player = get_parent().get_node_or_null("Player")
	ground.tile_set = WorldTiles.make_tileset()
	_bodies = Node2D.new()
	_bodies.name = "Obstacles"
	add_child(_bodies)
	_fill_legacy()
	_place_spawns()
	_add_static_box("base", Vector2(state.base), WorldData.obstacle_boxes().get("base", {}))
	_sync_bodies()
	if state.tunnel_unlocked and entry == "FromTunnel":
		_add_passage_door() # legacy trial route only; normal play stays on one map
	_build_ui()
	call_deferred("_fit_camera")

func to_px(units: Vector2) -> Vector2:
	return units * UNIT

func to_units(px: Vector2) -> Vector2:
	return px / UNIT

# --- ground ---------------------------------------------------------------------------------------------

func _fill_legacy() -> void:
	var r: Rect2 = Rect2(-12, -12, 24, 24) if state.is_seeded() else state.map_rect()
	_fill_tiles(Rect2i(int(r.position.x * 4), int(r.position.y * 4), int(r.size.x * 4), int(r.size.y * 4)))
	if state.is_seeded():
		_fill_tiles(Rect2i(40, -4, 18, 6)) # the connector through the old east border

func _fill_tiles(r: Rect2i) -> void:
	for ty in range(r.position.y, r.end.y):
		for tx in range(r.position.x, r.end.x):
			var t: int = state.tile_type(tx, ty)
			var collide := false
			if t in WorldTiles.SOLID_TILES:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if state.tile_type(tx + dx, ty + dy) in WorldTerrain.WALKABLE_TILES:
							collide = true
			ground.set_cell(Vector2i(tx, ty), 0, WorldTiles.atlas_for(t, tx, ty, collide))

## Seeded world: paint the chunks round the player the first time they come near.
func _fill_seeded_near(at: Vector2) -> void:
	if not state.is_seeded():
		return
	state.ensure_area(Rect2(at - Vector2(10, 10), Vector2(20, 20)))
	for cy in range(int(floor((at.y - 10) / 8.0)), int(floor((at.y + 10) / 8.0)) + 1):
		for cx in range(int(floor((at.x - 10) / 8.0)), int(floor((at.x + 10) / 8.0)) + 1):
			var key := Vector2i(cx, cy)
			if _filled_chunks.has(key) or cx < -4 or cx > 3 or cy < -4 or cy > 3:
				continue
			_filled_chunks[key] = true
			var r := Rect2i(cx * 32, cy * 32, 32, 32)
			# the legacy middle (-12..12) is already painted
			if r.position.x >= -48 and r.end.x <= 48 and r.position.y >= -48 and r.end.y <= 48:
				continue
			_fill_tiles(r)
	_sync_bodies()

func _fit_camera() -> void:
	if player == null:
		return
	var cam := player.get_node_or_null("Camera2D") as Camera2D
	if cam == null:
		return
	var r: Rect2 = state.map_rect()
	cam.limit_left = int(r.position.x * UNIT)
	cam.limit_top = int(r.position.y * UNIT)
	cam.limit_right = int(r.end.x * UNIT)
	cam.limit_bottom = int(r.end.y * UNIT)
	cam.reset_smoothing()

# --- spawns, doors, obstacles ---------------------------------------------------------------------------

func _place_spawns() -> void:
	var spawns := get_parent().get_node_or_null("Spawns")
	if spawns == null:
		return
	var exit := WorldTerrain.tunnel_exit()
	var at := {"Start": Vector2(state.base), "FromTunnel": exit + Vector2(-0.8, 0)}
	for key: String in at:
		var m := spawns.get_node_or_null(key) as Node2D
		if m != null:
			m.position = to_px(at[key])

func _add_passage_door() -> void:
	var door := Area2D.new()
	door.name = "PassageDoor"
	door.set_script(PassageDoor)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	var t: Dictionary = WorldData.terrain().TUNNEL
	rect.size = Vector2(0.7, float(t.HALF_WIDTH) * 2.0) * UNIT
	shape.shape = rect
	door.add_child(shape)
	door.position = to_px(Vector2(WorldTerrain.range_back_x(t.Y) + 0.85, t.Y))
	add_child(door)

func _add_static_box(id: String, at: Vector2, box: Dictionary) -> void:
	if box.is_empty() or _bodied.has(id):
		return
	_bodied[id] = true
	var body := StaticBody2D.new()
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(box.maxX - box.minX, box.maxY - box.minY) * UNIT
	shape.shape = rect
	shape.position = Vector2((box.minX + box.maxX) / 2.0, (box.minY + box.maxY) / 2.0) * UNIT
	body.position = to_px(at)
	body.add_child(shape)
	_bodies.add_child(body)

## Veins and solid scenery block the player (web worldObstacles). Adds bodies for anything new.
func _sync_bodies() -> void:
	var boxes := WorldData.obstacle_boxes()
	for m: Dictionary in state.mines:
		_add_static_box("mine:" + str(m.id), Vector2(m.x, m.y), boxes.get("mine", {}))
	if state.tunnel_unlocked:
		var sb := WorldData.scenery_boxes()
		for p: Dictionary in _scenery():
			if sb.has(p.kind):
				_add_static_box("prop:%s@%.2f,%.2f" % [p.kind, p.x, p.y], Vector2(p.x, p.y), sb[p.kind])
	queue_redraw()

func _scenery() -> Array:
	var list: Array = WorldTerrain.scenery_for(state.mines) if state.tunnel_unlocked else []
	if state.is_seeded():
		list = list + state.generated_props()
	return list

# --- play -----------------------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if player == null or get_node("/root/Game").workshop_is_open():
		return
	var at := to_units(player.position)
	_fill_seeded_near(at)
	state.explore(at)
	var place: Dictionary = state.place_at(at)
	var near: Array = state.veins_near(at, REACH)
	_near_vein = near[0] if not near.is_empty() else {}
	var text: String = place.label
	text += "  ·  광맥 %d/%d" % [state.discovered_count(), state.mines.size()]
	if not _near_vein.is_empty():
		text += "\nE  ·  %s 채굴" % WorldData.resource_name(_near_vein.resource)
	if text != _place:
		_place = text
		_region_label.text = text
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			_toast.text = ""

## Mines the vein the player stands at through the workshop economy, when the game has one
## (Game.workshop.mine(resource)). Returns true when something was mined.
func mine_near_vein() -> bool:
	if _near_vein.is_empty() or get_node("/root/Game").workshop_is_open():
		return false
	var game := get_node_or_null("/root/Game")
	var economy: Variant = game.get("workshop") if game != null else null
	var res_name := WorldData.resource_name(_near_vein.resource)
	if economy == null or not (economy as Object).has_method("mine"):
		show_toast("%s 광맥 · 채굴은 공방 연결 후" % res_name)
		return false
	var ok: bool = economy.mine_vein(str(_near_vein.id))
	show_toast(("%s +1" if ok else "%s 광맥 · 아직 잠겨 있어요") % res_name)
	return ok

func show_toast(text: String) -> void:
	_toast.text = text
	_toast_left = 2.5

func _on_discovered(mine: Dictionary) -> void:
	show_toast("새 광맥 발견: %s (%d, %d)" % [WorldData.resource_name(mine.resource), int(mine.x), int(mine.y)])
	queue_redraw()

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "WorldUI"
	# Reserve the resting joystick area on touch displays.
	var text_left := 104 if DisplayServer.is_touchscreen_available() else 6
	add_child(layer)
	_region_label = Label.new()
	_region_label.name = "Region"
	_region_label.add_theme_font_override("font", FONT)
	_region_label.position = Vector2(text_left, 232)
	_region_label.add_theme_font_size_override("font_size", 10)
	_region_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_region_label.add_theme_constant_override("outline_size", 3)
	layer.add_child(_region_label)
	_toast = Label.new()
	_toast.name = "Toast"
	_toast.add_theme_font_override("font", FONT)
	_toast.position = Vector2(text_left, 216)
	_toast.add_theme_font_size_override("font_size", 10)
	_toast.add_theme_color_override("font_color", Color("f7e1b8"))
	_toast.add_theme_color_override("font_outline_color", Color.BLACK)
	_toast.add_theme_constant_override("outline_size", 3)
	layer.add_child(_toast)

# --- drawing --------------------------------------------------------------------------------------------

func _draw() -> void:
	for p: Dictionary in WorldTerrain.peaks(state.tunnel_unlocked):
		_draw_peak(to_px(Vector2(p.x, p.y)), p.size)
	_draw_base(to_px(Vector2(state.base)))
	for p: Dictionary in _scenery():
		_draw_prop(p)
	for m: Dictionary in state.mines:
		_draw_vein(m)

func _draw_peak(at: Vector2, size: float) -> void:
	var w := 34.0 * size
	var h := 40.0 * size
	draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 2, 8), at + Vector2(0, 8 - h), at + Vector2(w / 2, 8)]), Color8(95, 90, 85))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 5, 8 - h * 0.6), at + Vector2(0, 8 - h), at + Vector2(w / 5, 8 - h * 0.6)]), Color8(232, 236, 240))

func _draw_base(at: Vector2) -> void:
	draw_rect(Rect2(at + Vector2(-25, -28), Vector2(50, 22)), Color8(120, 92, 60))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-30, -27), at + Vector2(0, -44), at + Vector2(30, -27)]), Color8(150, 70, 52))
	draw_rect(Rect2(at + Vector2(-5, -18), Vector2(10, 12)), Color8(66, 48, 34))
	draw_string_outline(FONT, at + Vector2(-10, -48), "공방", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color("241b19"))
	draw_string(FONT, at + Vector2(-10, -48), "공방", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("f7e1b8"))

func _draw_vein(m: Dictionary) -> void:
	var at := to_px(Vector2(m.x, m.y))
	var known: bool = state.is_discovered(m)
	var color: Color = VEIN_COLORS.get(m.resource, Color.GRAY) if known else Color8(120, 116, 110)
	draw_colored_polygon(PackedVector2Array([at + Vector2(-9, 4), at + Vector2(-7, -5), at + Vector2(0, -9),
		at + Vector2(7, -7), at + Vector2(10, 0), at + Vector2(6, 5), at + Vector2(-6, 6)]), color.darkened(0.45))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-6, 0), at + Vector2(-3, -5), at + Vector2(3, -6),
		at + Vector2(6, -1), at + Vector2(1, 2)]), color)
	if not known:
		draw_string(FONT, at + Vector2(-3, 1), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color8(230, 226, 214))
	elif not _near_vein.is_empty() and _near_vein.id == m.id:
		draw_arc(at, 12.0, 0.0, TAU, 24, Color("f0d599"), 1.0)

func _draw_prop(p: Dictionary) -> void:
	var at := to_px(Vector2(p.x, p.y))
	var s: float = p.size
	match str(p.kind):
		"bigTree", "sparseTree":
			var r := (14.0 if p.kind == "bigTree" else 9.0) * s
			draw_rect(Rect2(at + Vector2(-2, -6), Vector2(4, 7)), Color8(60, 44, 32))
			draw_circle(at + Vector2(0, -6 - r), r, Color8(56, 92, 58) if p.kind == "bigTree" else Color8(78, 120, 68))
		"grass":
			for i in 3:
				draw_line(at + Vector2(i * 3 - 3, 0), at + Vector2(i * 3 - 4, -5 * s), Color8(107, 155, 85), 1.0)
		"rock":
			draw_colored_polygon(PackedVector2Array([at + Vector2(-6, 1) * s, at + Vector2(-3, -5) * s, at + Vector2(4, -6) * s, at + Vector2(6, 1) * s]), Color8(118, 113, 106))
		"crystal", "exposedVein":
			var c := Color8(169, 218, 251) if p.kind == "crystal" else Color8(237, 189, 100)
			draw_colored_polygon(PackedVector2Array([at + Vector2(-4, 0), at + Vector2(0, -12 * s), at + Vector2(4, 0)]), c)
		"clearing", "diggingMarks":
			draw_arc(at, 10.0 * s, 0.0, TAU, 16, Color8(150, 122, 86), 1.0)
		"timberSupport":
			draw_rect(Rect2(at + Vector2(-6, -12), Vector2(2, 12)), Color8(120, 92, 60))
			draw_rect(Rect2(at + Vector2(4, -12), Vector2(2, 12)), Color8(120, 92, 60))
			draw_rect(Rect2(at + Vector2(-7, -14), Vector2(14, 3)), Color8(96, 70, 44))
		"mineCart":
			draw_rect(Rect2(at + Vector2(-8, -8), Vector2(16, 7)), Color8(96, 90, 85))
			draw_circle(at + Vector2(-5, 0), 2.0, Color8(40, 36, 32))
			draw_circle(at + Vector2(5, 0), 2.0, Color8(40, 36, 32))
		"oldShaftEntrance":
			draw_rect(Rect2(at + Vector2(-13, -16), Vector2(26, 16)), Color8(96, 70, 44))
			draw_rect(Rect2(at + Vector2(-9, -12), Vector2(18, 12)), Color8(30, 26, 24))

func context_at(point: Vector2) -> String:
	if to_units(point).distance_to(Vector2(state.base)) <= 0.8:
		return "workshop"
	var near: Array = state.veins_near(to_units(point), REACH)
	_near_vein = near[0] if not near.is_empty() else {}
	return str(_near_vein.id) if not _near_vein.is_empty() else ""

func action_label(id: String) -> String:
	if id == "workshop":
		return "공방 열기"
	var vein: Dictionary = state.mine_by_id(id)
	return WorldData.resource_name(vein.resource) + " 채굴" if not vein.is_empty() else ""

func _on_tunnel_opened(_added: Array) -> void:
	_refresh_terrain.call_deferred()

func _refresh_terrain() -> void:
	ground.clear()
	_filled_chunks.clear()
	_fill_legacy()
	if is_instance_valid(player):
		_fill_seeded_near(to_units(player.position))
	_sync_bodies()
	queue_redraw()
