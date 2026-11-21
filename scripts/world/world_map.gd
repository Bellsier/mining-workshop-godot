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
const Expeditions := WorldState.Expeditions
const WorldTiles := preload("res://scripts/world/world_tiles.gd")
const PassageDoor := preload("res://scripts/world/world_passage_door.gd")
const WorldObjects := preload("res://scripts/world/world_objects.gd")
const Layout := preload("res://scripts/village_layout.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")
const Sprites := preload("res://scripts/world/world_sprites.gd")
const WorldSway := preload("res://scripts/world/world_sway.gd")
const WorldFloats := preload("res://scripts/world/world_floats.gd")

const UNIT := 64.0
const REACH := 0.6
## web TOPDOWN.INTERACT_RANGE: world units from the player to a vein or building to act on it.
const INTERACT_RANGE := 1.15
## web TD_DOOR: in front of a door it is picked over a nearer point to the side; behind a building it counts
## farther; facing it breaks a near tie. Only the order of what is in reach changes, never the reach.
const DOOR := {"FRONT_DEPTH": 0.9, "FRONT": 0.3, "BEHIND": 0.5, "FACING": 0.15}

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
var _target: Dictionary = {}
var objects: Node2D
## The scenery as last drawn (the sway layer draws its trees and grass from it every frame).
var scenery_now: Array = []
var landmarks: Node2D
var floats: Node2D

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
	# Trees and grass sway, so they are drawn by a layer of their own every frame, right after this node's own
	# drawing (before the huts, the village and the workers, as when they were drawn here).
	var sway := WorldSway.new()
	sway.name = "Sway"
	add_child(sway)
	move_child(sway, 0)
	objects = WorldObjects.new()
	objects.name = "Objects"
	add_child(objects)
	objects.setup(_economy(), state, player)
	sway.setup(self, objects.light)
	landmarks = preload("res://scripts/world/story_landmarks.gd").new()
	landmarks.world = state
	add_child(landmarks)
	floats = WorldFloats.new()
	floats.name = "Floats"
	add_child(floats)
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
	var economy := _economy()
	if economy != null and economy.state.village.get("district") is Dictionary:
		var door: Dictionary = Layout.district_parts(economy.state.village.district).house
		at["FromHouse"] = Vector2(door.x, door.y + 0.25)
		if spawns.get_node_or_null("FromHouse") == null:
			var marker := Marker2D.new()
			marker.name = "FromHouse"
			spawns.add_child(marker)
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
	if player == null or get_node("/root/Game").world_input_blocked():
		return
	var at := to_units(player.position)
	_fill_seeded_near(at)
	state.explore(at)
	var place: Dictionary = state.place_at(at)
	var text: String = place.label
	if state.tunnel_unlocked and place.region == "beyond":
		if at.y >= -5.25 and at.y < 0.0:
			text += " · 이끼숲"
		elif at.y > 2.0 and at.y <= 7.0:
			text += " · 안개 늪지"
		elif at.y >= 0.0 and at.y <= 2.0:
			text = "산 너머 · 북쪽 이끼숲 / 남쪽 늪지"
	text += "  ·  광맥 %d/%d" % [state.discovered_count(), state.mines.size()]
	if not _target.is_empty():
		# as on the action button: a long label's cost is shown once, on the line above the button
		var hud: Variant = get_node("/root/Game").get("_hud")
		var shown := str(_target.label)
		if hud != null and hud.has_method("action_text_for"):
			shown = hud.action_text_for(shown)
		text += "\nE  ·  " + shown
	if text != _place:
		_place = text
		_region_label.text = text
	if _toast_left > 0.0:
		_toast_left -= delta
		if _toast_left <= 0.0:
			_toast.text = ""

## E at the vein the player stands at: secures it, mines it, or says which area must open first.
func mine_near_vein() -> bool:
	if _target.get("type") != "mine":
		return false
	interact(context_id(_target))
	return true

func show_toast(text: String) -> void:
	_toast.text = text
	_toast_left = 2.5

func _on_discovered(mine: Dictionary) -> void:
	show_toast("새 광맥 발견: %s (%d, %d)" % [WorldData.resource_name(mine.resource), int(mine.x), int(mine.y)])
	# a float over the vein itself, so the find is seen where it is
	if floats != null:
		floats.add("새 광맥! " + WorldData.resource_name(mine.resource), to_px(Vector2(mine.x, mine.y)), Color("bff3ff"))
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
	var minimap: Control = preload("res://scripts/world/world_minimap.gd").new()
	minimap.name = "Minimap"
	layer.add_child(minimap)
	minimap.position = Vector2(6, 6)
	minimap.setup(state, _economy(), player)

# --- drawing --------------------------------------------------------------------------------------------

func _draw() -> void:
	for p: Dictionary in WorldTerrain.peaks(state.tunnel_unlocked):
		_draw_peak(to_px(Vector2(p.x, p.y)), p.size)
	scenery_now = _scenery()
	for p: Dictionary in scenery_now:
		if not WorldSway.sways(str(p.kind)):
			_draw_prop(p)
	for m: Dictionary in state.mines:
		_draw_vein(m)

func _draw_peak(at: Vector2, size: float) -> void:
	var w := 34.0 * size
	var h := 40.0 * size
	draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 2, 8), at + Vector2(0, 8 - h), at + Vector2(w / 2, 8)]), Color8(95, 90, 85))
	draw_colored_polygon(PackedVector2Array([at + Vector2(-w / 5, 8 - h * 0.6), at + Vector2(0, 8 - h), at + Vector2(w / 5, 8 - h * 0.6)]), Color8(232, 236, 240))

## web tdOreSprite: a mossy rock while hidden (with a "?" to say something is there), the ore's colours once
## found, a staked flag once secured; a ring round the one in reach.
func _draw_vein(m: Dictionary) -> void:
	var at := to_px(Vector2(m.x, m.y))
	var known: bool = state.is_discovered(m)
	var look := "undiscovered" if not known else "secured" if m.get("developmentState") == "secured" else "discovered"
	var sprite := Sprites.ore(str(m.resource), look)
	draw_texture(sprite, Sprites.origin(sprite, at, Sprites.ANCHOR.ore))
	if not known:
		draw_string_outline(FONT, at + Vector2(-3, -6), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color("241b19"))
		draw_string(FONT, at + Vector2(-3, -6), "?", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color8(230, 226, 214))
	elif not _near_vein.is_empty() and _near_vein.id == m.id:
		draw_arc(at + Vector2(0, -4), 14.0, 0.0, TAU, 24, Color("f0d599"), 1.0)

## web tdPropSprite, drawn at the prop's ground point (trees and grass are drawn by the sway layer).
func _draw_prop(p: Dictionary) -> void:
	var sprite := Sprites.prop(str(p.kind))
	draw_texture(sprite, Sprites.origin(sprite, to_px(Vector2(p.x, p.y)), Sprites.ANCHOR.prop))

func _economy() -> Node:
	var game := get_node_or_null("/root/Game")
	var economy: Variant = game.get("workshop") if game != null else null
	return economy if economy is Node and (economy as Node).has_method("vein_action") else null


## The id Game keeps for a target: "workshop" for the cabin, "type:id" for the rest.
static func context_id(t: Dictionary) -> String:
	if t.is_empty():
		return ""
	return "workshop" if t.type == "base" else "%s:%s" % [t.type, t.id]


func context_at(point: Vector2) -> String:
	var facing := str(player.get("facing")) if is_instance_valid(player) else "down"
	_target = find_target(to_units(point), facing)
	var vein: Dictionary = state.mine_by_id(str(_target.id)) if _target.get("type") == "mine" else {}
	if vein != _near_vein:
		_near_vein = vein
		queue_redraw()
	return context_id(_target)


func action_label(id: String) -> String:
	return str(_target.label) if not _target.is_empty() and id == context_id(_target) else ""


## What the player could act on now: the nearest target within reach (web tdInteractTarget):
## {type: mine | base | workshop | village | house | garden | plaza, id, x, y, action, label}.
func find_target(at: Vector2, facing: String) -> Dictionary:
	var economy := _economy()
	# Lambdas capture locals by value: the best target so far lives in a shared dictionary.
	var found := {"t": {}, "d": INF}
	var consider := func(t: Dictionary, d: float, bonus: float) -> void:
		var score := d - bonus
		if d <= INTERACT_RANGE and score < found.d:
			found.t = t
			found.d = score
	if state.tunnel_unlocked and WorldTerrain.region_at(at.x, at.y) == "beyond":
		for id: String in WorldState.Story.SITES:
			var site: Dictionary = WorldState.Story.SITES[id]
			var pos: Vector2 = site.at
			var d := at.distance_to(pos)
			if d <= INTERACT_RANGE:
				var label := WorldState.Story.action_label(id, state.story)
				consider.call({"type": "story", "id": id, "x": pos.x, "y": pos.y, "label": label}, d, 0.0)
		for id: String in Expeditions.PORTALS:
			if not Expeditions.allowed(id, state.story, state.expedition):
				continue
			var pos: Vector2 = Expeditions.PORTALS[id][0]
			consider.call({"type": "expedition", "id": id, "x": pos.x, "y": pos.y, "label": Expeditions.PORTALS[id][1]},
				at.distance_to(pos), 0.0)
	for m: Dictionary in state.mines:
		if not state.is_discovered(m):
			continue
		var d := at.distance_to(Vector2(m.x, m.y))
		if d > INTERACT_RANGE:
			continue
		var name := WorldData.resource_name(m.resource)
		var t := {"type": "mine", "id": str(m.id), "x": float(m.x), "y": float(m.y), "action": "mine", "label": name + " 채굴"}
		if economy != null:
			t.action = economy.vein_action(str(m.id))
			match t.action:
				"mine":
					t.label = "%s 캐기 +%s" % [name, economy.Hud.format_quantity(float(m.miningPower) * economy._multiplier())]
				"secure":
					t.label = name + " 광맥 확보"
				_:
					t.label = _site_name(str(m.resource)) + " 해금 필요"
		consider.call(t, d, 0.0)
	var fv: Vector2 = {"up": Vector2(0, -1), "down": Vector2(0, 1), "left": Vector2(-1, 0), "right": Vector2(1, 0)}.get(facing, Vector2.ZERO)
	var boxes := WorldData.obstacle_boxes()
	var b := Vector2(state.base)
	consider.call({"type": "base", "id": "base", "x": b.x, "y": b.y, "action": "open", "label": "공방 들어가기"},
		at.distance_to(b), _door_bonus(at, fv, b, boxes.base))
	for i in state.workshops.size():
		var w: Dictionary = state.workshops[i]
		var recipe := "레시피 없음"
		if w.recipeKey is String and economy != null:
			recipe = economy._label(w.recipeKey)
		consider.call({"type": "workshop", "id": str(w.id), "x": float(w.x), "y": float(w.y), "action": "open",
			"label": "제작소 %d Lv.%d · %s" % [i + 1, int(w.level), recipe]}, at.distance_to(Vector2(w.x, w.y)), _door_bonus(at, fv, Vector2(w.x, w.y), boxes.workshop))
	if economy == null:
		return found.t
	var village: Dictionary = economy.state.village
	for key: String in Layout.ORDER:
		var site: Variant = village.sites.get(key)
		if site is Dictionary:
			var vt: Dictionary = economy.village_target(key)
			consider.call({"type": "village", "id": key, "x": site.x, "y": site.y, "action": vt.action, "label": vt.label},
				at.distance_to(Vector2(site.x, site.y)), 0.0)
	if village.get("district") is Dictionary:
		var parts := Layout.district_parts(village.district)
		var house: Dictionary = parts.house
		consider.call({"type": "house", "id": "house", "x": house.x, "y": house.y, "action": "enter", "label": "내 집 · 들어가기"},
			at.distance_to(Vector2(house.x, house.y)), 0.0)
		var gt := _garden_target(economy, parts, at, fv)
		if not gt.is_empty():
			consider.call(gt, at.distance_to(Vector2(gt.x, gt.y)), 0.0)
		var plaza: Dictionary = parts.plaza
		consider.call({"type": "plaza", "id": "plaza", "x": plaza.x, "y": plaza.y - 0.15, "action": "open", "label": "마을 광장 · 안내판"},
			at.distance_to(Vector2(plaza.x, plaza.y - 0.15)), 0.0)
	return found.t


func _site_name(resource: String) -> String:
	for row: Dictionary in WorldData.sites():
		if row.key == WorldData.resource(resource).get("site", ""):
			return row.name
	return "지역"


func _door_bonus(at: Vector2, fv: Vector2, door: Vector2, box: Dictionary) -> float:
	var dx := at.x - door.x
	var dy := at.y - door.y
	var d := sqrt(dx * dx + dy * dy)
	var bonus := 0.0
	if dx >= box.minX - 0.1 and dx <= box.maxX + 0.1 and dy >= -0.05 and dy <= DOOR.FRONT_DEPTH:
		bonus += DOOR.FRONT
	elif dy < box.minY:
		bonus -= DOOR.BEHIND
	if d > 1e-6:
		bonus += DOOR.FACING * maxf(0.0, -(fv.x * dx + fv.y * dy) / d)
	return bonus


## The garden cell in front of the player (web villageGardenTarget).
func _garden_target(economy: Node, parts: Dictionary, at: Vector2, fv: Vector2) -> Dictionary:
	var G: Dictionary = Layout.V().GARDEN
	var g: Dictionary = parts.garden
	if absf(at.x - g.x) > g.hw + G.NEAR or absf(at.y - g.y) > g.hh + G.NEAR:
		return {}
	if fv == Vector2.ZERO:
		fv = Vector2(0, 1)
	var front := at + fv * float(G.AHEAD)
	var best := {}
	var best_d: float = G.CELL_REACH
	for c: Dictionary in Layout.garden_cells(economy.state.village):
		var d := front.distance_to(Vector2(c.x, c.y))
		if d <= best_d:
			best = c
			best_d = d
	if best.is_empty():
		return {}
	var t := {"type": "garden", "id": str(best.cell), "x": best.x, "y": best.y}
	var carry := int(economy.garden_ui.carry)
	var here: int = economy._decor_index(int(best.cell))
	var list: Array = economy.state.village.decor
	if carry >= 0 and economy._decor_index(carry) >= 0:
		var kind := str(list[economy._decor_index(carry)].kind)
		var name: String = Layout.decor_def(kind).name
		if int(best.cell) == carry:
			return t.merged({"action": "decorDrop", "label": name + " · 제자리에 두기"})
		var why: String = economy.decor_problem(kind, int(best.cell), carry, at, true)
		return t.merged({"action": "locked", "label": name + " · " + why} if not why.is_empty() else {"action": "decorDrop", "label": name + " · 여기로 옮기기"})
	if here >= 0:
		return t.merged({"action": "decorPick", "label": Layout.decor_def(str(list[here].kind)).name + " · 들어 옮기기"})
	var selected: String = economy.decor_selected()
	return t.merged({"action": "decorPlace", "label": "정원 · " + Layout.decor_def(selected).name + " 놓기"})


## Does the target's action (web tdInteract). Returns the HUD tab to open ("" for none).
func interact(id: String) -> String:
	if _target.is_empty() or id != context_id(_target) or get_node("/root/Game").world_input_blocked():
		return ""
	var economy := _economy()
	if economy == null:
		return ""
	var t := _target
	var feet := to_units(player.position) if is_instance_valid(player) else Vector2(t.x, t.y)
	match str(t.type):
		"expedition":
			get_node("/root/Game").enter_expedition(str(t.id))
		"story":
			show_toast(economy.investigate_landmark(str(t.id)))
			landmarks.queue_redraw()
		"mine":
			match str(t.action):
				"secure":
					if economy.secure_vein(str(t.id)):
						show_toast("확보!")
						floats.add("광맥 확보!", to_px(Vector2(t.x, t.y)))
						queue_redraw()
				"mine":
					var vein: Dictionary = state.mine_by_id(str(t.id))
					if economy.mine_vein(str(t.id)):
						var amount: float = float(vein.miningPower) * float(economy._multiplier())
						var name: String = WorldData.resource_name(vein.resource)
						floats.add("+%s %s" % [WorldFloats._format(amount), name], to_px(Vector2(t.x, t.y)), WorldFloats.OK_COLOR, 24.0, name, amount)
				_:
					show_toast(str(t.label))
		"base":
			return "workshop"
		"workshop":
			return "craft"
		"village":
			match str(t.action):
				"restore":
					economy.restore_facility(str(t.id))
				"appraise":
					economy.appraise_relic(str(t.id))
				"donate":
					var n: int = economy.donate_all_relics()
					if n > 0:
						show_toast("유물 %d점 기증 · 전시" % n)
				"locked":
					show_toast(str(t.label))
				_:
					return "village"
		"plaza":
			return "village"
		"house":
			var door: Dictionary = Layout.district_parts(economy.state.village.district).house
			economy.state.position = {"scene": scene_file_path_of_level(), "x": door.x * UNIT, "y": (door.y + 0.2) * UNIT}
			get_node("/root/Game").go("res://scenes/world/house.tscn", "Start")
		"garden":
			var cell := int(t.id)
			match str(t.action):
				"decorPlace":
					economy.decor_place(economy.decor_selected(), cell, feet)
				"decorPick":
					economy.garden_ui.carry = cell
					economy.changed.emit()
					show_toast("들었어요 · 옮길 칸에서 E")
				"decorDrop":
					var from := int(economy.garden_ui.carry)
					if from == cell or economy.decor_move(from, cell, feet):
						economy.garden_ui.carry = -1
						economy.changed.emit()
						show_toast("제자리에 두었어요" if from == cell else "옮겼어요")
				_:
					show_toast(str(t.label))
	return ""


func scene_file_path_of_level() -> String:
	return get_parent().scene_file_path


## T: picks up the torch at hand or sets one down in front (web torchAct).
func torch_act() -> void:
	var economy := _economy()
	if economy == null or not is_instance_valid(player) or get_node("/root/Game").world_input_blocked():
		return
	var r: Dictionary = economy.torch_act(to_units(player.position), str(player.get("facing")))
	show_toast(str(r.text))


## What the garden button offers now (web tdGardenButtonMode): "take", "cycle" or "".
func garden_mode() -> String:
	var economy := _economy()
	if economy == null:
		return ""
	var carrying := int(economy.garden_ui.carry) >= 0
	if _target.get("type") != "garden":
		return "take" if carrying else ""
	return "take" if carrying or _target.get("action") == "decorPick" else "cycle"


func garden_label(mode: String) -> String:
	var economy := _economy()
	var touch := DisplayServer.is_touchscreen_available()
	if mode == "take":
		return ("" if touch else "[R] ") + "장식 회수"
	if mode == "cycle" and economy != null:
		return ("" if touch else "[Q] ") + "다음 장식: " + Layout.decor_def(economy.decor_next()).name
	return ""


## R takes back the carried decoration or the one in front; Q chooses the next kind (web tdGardenButtonNow).
func garden_key(take: bool) -> void:
	var economy := _economy()
	if economy == null or get_node("/root/Game").world_input_blocked():
		return
	if not take:
		show_toast("정원 장식: " + Layout.decor_def(economy.decor_cycle()).name)
		return
	var cell := int(economy.garden_ui.carry)
	if cell < 0 and _target.get("type") == "garden" and _target.get("action") == "decorPick":
		cell = int(_target.id)
	if cell >= 0:
		var kind: String = economy.decor_remove(cell)
		if not kind.is_empty():
			show_toast(Layout.decor_def(kind).name + " 회수")


func _on_tunnel_opened(_added: Array) -> void:
	landmarks.queue_redraw()
	_refresh_terrain.call_deferred()

func _refresh_terrain() -> void:
	ground.clear()
	_filled_chunks.clear()
	_fill_legacy()
	if is_instance_valid(player):
		_fill_seeded_near(to_units(player.position))
	_sync_bodies()
	queue_redraw()
