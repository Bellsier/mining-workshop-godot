extends RefCounted
## The world of one run: where the base is, the veins, which veins are still hidden, whether the tunnel
## through the mountain is open, and (optionally) the seeded outer world. Mirrors the web state.world
## fields so it can be saved in the web shape (to_dict / from_dict):
##   base {x, y, level}, mines [...], hiddenMineIds [...], tunnelUnlocked, and for the seeded world
##   seed, size, generatorVersion, chunkEditsVersion, chunkEdits.
## Godot adds `layoutSeed`: the seed the new-game layout was drawn with (the web used Math.random).
## `workshops` are the craft huts (제작소), kept in the web shape; their rules are in scripts/craft_huts.gd.
##
## One instance is shared by every scene through Engine meta (current / set_current), so it survives scene
## changes. Saving it is left to the save system (see docs/WORLD_MIGRATION.md).

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const WorldGen := preload("res://scripts/world/world_gen.gd")
const ChunkGen := preload("res://scripts/world/chunk_gen.gd")
const WorldRandom := preload("res://scripts/world/world_random.gd")
const Story := preload("res://scripts/world/region_story.gd")
const CraftHuts := preload("res://scripts/craft_huts.gd")
const SELF_PATH := "res://scripts/world/world_state.gd"

const META_KEY := "mining_world_state"
const SEEDED_SIZE := 256
const SEEDED_EDGE := 31.75
const LEGACY_EDGE := 12.0
const CHUNK_UNITS := 8
const CHUNK_MIN := -4
const CHUNK_MAX := 3
## The seeded world's corridor through the old east border (web WORLD_CONNECTOR).
const CONNECTOR := {"minX": 10.0, "maxX": 14.25, "minY": -0.5, "maxY": 0.5}

signal survey_completed(added: Array)
signal discovered(mine: Dictionary)
signal tunnel_opened(added: Array)

var layout_seed := 0
var base := Vector2i(2, 0)
var base_level := 1
var mines: Array = []
var hidden_ids: Array[String] = []
## Craft huts (web state.world.workshops): {id, x, y, level, recipeKey, auto, progress}.
var workshops: Array = []
## Torches the player set down (web state.world.torches): {x, y}.
var torches: Array = []
## The tunnel construction job (web state.world.tunnelContract): {startedAt (ms), durationSec}, or {} for none.
var tunnel_contract: Dictionary = {}
var story: Dictionary = {}
var tunnel_unlocked := false
var exploration_gear := false
## Seeded outer world (web 256 test world). Empty when off.
var seeded: Dictionary = {}
var _chunks := {}
var _materialized := {}
var _generated_ids := {}
var _rng: RefCounted

static func current() -> RefCounted:
	return Engine.get_meta(META_KEY) if Engine.has_meta(META_KEY) else null

static func set_current(state: RefCounted) -> void:
	if state == null:
		if Engine.has_meta(META_KEY):
			Engine.remove_meta(META_KEY)
	else:
		Engine.set_meta(META_KEY, state)
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.root.get_node_or_null("WorldSessionCleanup") == null:
			var keeper := Node.new()
			keeper.name = "WorldSessionCleanup"
			keeper.set_script(load("res://scripts/world/world_session_cleanup.gd"))
			tree.root.add_child.call_deferred(keeper)

## The shared world, created on first use. `seed_value` < 0 picks a random seed.
static func ensure_current(seed_value: int = -1) -> RefCounted:
	var s := current()
	if s == null:
		s = load(SELF_PATH).new_game(seed_value)
		set_current(s)
	return s

## A new game's world (web freshWorldState): the starter and ring veins, all but the starters hidden.
static func new_game(seed_value: int = -1, seeded_world: bool = false, world_seed: int = -1) -> RefCounted:
	var s: RefCounted = load(SELF_PATH).new()
	s.layout_seed = seed_value if seed_value >= 0 else int(randi() & 0x7FFFFFFF)
	var w := WorldData.world()
	s.base = Vector2i(int(w.START_BASE_X), int(w.START_BASE_Y))
	s._rng = WorldRandom.new(s.layout_seed)
	s.mines = WorldGen.generate_initial_mines(s.base, s._rng.source())
	for m: Dictionary in s.mines:
		if not str(m.id).begins_with("mine_start_"):
			s.hidden_ids.append(m.id)
	if seeded_world:
		s.seeded = {"seed": world_seed if world_seed >= 0 else int(randi()), "size": SEEDED_SIZE,
			"generatorVersion": 2, "chunkEditsVersion": 1, "chunkEdits": {}}
	return s

func _random() -> Callable:
	if _rng == null:
		_rng = WorldRandom.new(layout_seed ^ 0x5bd1e995)
	return _rng.source()

# --- tunnel / survey ------------------------------------------------------------------------------------

## Opens the tunnel (one way) and brings the land beyond's veins into the world, hidden.
## Returns the veins added; [] when it was already open. (web unlockTunnel + populateBeyondMines)
func unlock_tunnel() -> Array:
	if tunnel_unlocked:
		return []
	tunnel_unlocked = true
	tunnel_contract = {}
	var added := WorldGen.generate_beyond_mines(mines, _random())
	for m: Dictionary in added:
		mines.append(m)
		hidden_ids.append(m.id)
	tunnel_opened.emit(added)
	return added

## "지질 조사": hidden veins in the outer ring. Returns the veins added.
func run_survey() -> Array:
	var added := WorldGen.survey_mines(mines, base, _random())
	for m: Dictionary in added:
		mines.append(m)
		hidden_ids.append(m.id)
	survey_completed.emit(added)
	return added

# --- securing and site seeds ---------------------------------------------------------------------------

## Marks a vein secured (web secureMine; the caller checks it is found and its area open).
func secure(id: String) -> bool:
	var m := mine_by_id(id)
	if m.is_empty() or m.get("developmentState") != "unsecured":
		return false
	m.developmentState = "secured"
	_record_edit(id)
	return true

## A site's seed veins at their offsets from the base, unhidden, where no vein stands yet
## (web seedWorldMinesForSite / addMine: a taken id gets a new one). Returns the veins added.
func seed_site(site: String, seeds: Array) -> Array:
	var added: Array = []
	for seed: Dictionary in seeds:
		var x := base.x + int(seed.x)
		var y := base.y + int(seed.y)
		if mines.any(func(m: Dictionary) -> bool: return int(m.x) == x and int(m.y) == y):
			continue
		if not CraftHuts.is_valid_cell(x, "x", is_seeded()) or not CraftHuts.is_valid_cell(y, "y", is_seeded()):
			continue
		var id := "mine_%s_%s" % [site, seed.resource]
		if not mine_by_id(id).is_empty():
			var taken := {}
			for m: Dictionary in mines:
				taken[m.id] = true
			id = CraftHuts.new_id(taken, "mine_")
		var vein := {"id": id, "x": x, "y": y, "resource": str(seed.resource), "grade": int(seed.grade),
			"miningPower": int(seed.miningPower), "developmentState": "unsecured"}
		mines.append(vein)
		added.append(vein)
	return added

# --- discovery ------------------------------------------------------------------------------------------

func is_discovered(mine: Dictionary) -> bool:
	return not hidden_ids.has(str(mine.id))

func discovery_radius() -> float:
	if exploration_gear:
		return float(WorldData.research_balance().get("DISCOVERY_RADIUS", 4.0))
	return float(WorldData.world().get("DISCOVERY_RADIUS", 2.5))

func mine_by_id(id: String) -> Dictionary:
	for m: Dictionary in mines:
		if m.id == id:
			return m
	return {}

func discover(id: String) -> bool:
	if not hidden_ids.has(id):
		return false
	hidden_ids.erase(id)
	_record_edit(id)
	var m := mine_by_id(id)
	if not m.is_empty():
		discovered.emit(m)
	return true

## Reveals every hidden vein within the discovery radius of `at` (world units). Returns the veins found.
func explore(at: Vector2) -> Array:
	var r := discovery_radius()
	ensure_area(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0))
	if hidden_ids.is_empty():
		return []
	var found: Array = []
	for m: Dictionary in mines:
		if hidden_ids.has(str(m.id)) and Vector2(m.x, m.y).distance_to(at) <= r:
			found.append(m)
	for m: Dictionary in found:
		discover(m.id)
	return found

## Discovered veins within `reach` of `at`, nearest first.
func veins_near(at: Vector2, reach: float) -> Array:
	var out: Array = []
	for m: Dictionary in mines:
		if is_discovered(m) and Vector2(m.x, m.y).distance_to(at) <= reach:
			out.append(m)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return Vector2(a.x, a.y).distance_to(at) < Vector2(b.x, b.y).distance_to(at))
	return out

func discovered_count() -> int:
	return mines.size() - hidden_ids.size()

## Where `at` is: {region, zone, label}. label is the Korean name shown to the player.
func place_at(at: Vector2) -> Dictionary:
	if is_seeded() and _outside_legacy(at.x, at.y):
		return {"region": "frontier", "zone": "", "label": "개척지"}
	var region := WorldTerrain.region_at(at.x, at.y)
	var zone := WorldTerrain.beyond_zone_at(at.x, at.y)
	var label: String = {"open": "공방 앞 들판", "tunnel": "터널", "mountain": "산맥", "outside": "숲 가장자리", "beyond": "산 너머"}.get(region, region)
	if zone != "":
		label = "산 너머 · " + WorldData.zone_name(zone)
	return {"region": region, "zone": zone, "label": label}

# --- ground ---------------------------------------------------------------------------------------------

func is_seeded() -> bool:
	return not seeded.is_empty()

## The drawn world in units: legacy -12..12, seeded -32..32.
func map_rect() -> Rect2:
	if is_seeded():
		return Rect2(-32, -32, 64, 64)
	var b := WorldData.world()
	var e := WorldTerrain.EDGE_UNITS
	return Rect2(b.BOUNDS_MIN_X - e, b.BOUNDS_MIN_Y - e, b.BOUNDS_MAX_X - b.BOUNDS_MIN_X + 2 * e, b.BOUNDS_MAX_Y - b.BOUNDS_MIN_Y + 2 * e)

func _outside_legacy(x: float, y: float) -> bool:
	return x < -LEGACY_EDGE or x >= LEGACY_EDGE or y < -LEGACY_EDGE or y >= LEGACY_EDGE

static func in_connector(x: float, y: float) -> bool:
	return x >= CONNECTOR.minX and x < CONNECTOR.maxX and y >= CONNECTOR.minY and y < CONNECTOR.maxY

## Ground tile at an absolute quarter-unit tile (web tdTileAt / sampleGeneratedTile).
func tile_type(tx: int, ty: int) -> int:
	var x := (tx + 0.5) / WorldTerrain.TILES_PER_UNIT
	var y := (ty + 0.5) / WorldTerrain.TILES_PER_UNIT
	if is_seeded():
		if in_connector(x, y):
			return WorldTerrain.Tile.GRASS
		if _outside_legacy(x, y):
			var cx := int(floor(tx / 32.0))
			var cy := int(floor(ty / 32.0))
			var chunk := chunk_at(cx, cy)
			if chunk.is_empty():
				return WorldTerrain.Tile.EDGE
			return chunk.tiles[(ty - cy * 32) * 32 + tx - cx * 32]
	return WorldTerrain.tile_at(x, y, tunnel_unlocked, Vector2(base))

func chunk_at(cx: int, cy: int) -> Dictionary:
	if not is_seeded() or cx < CHUNK_MIN or cx > CHUNK_MAX or cy < CHUNK_MIN or cy > CHUNK_MAX:
		return {}
	var key := Vector2i(cx, cy)
	if not _chunks.has(key):
		_chunks[key] = ChunkGen.generate_chunk(seeded, cx, cy)
	return _chunks[key]

## Seeded world: loads the chunks overlapping `rect` (units) and puts their veins into `mines`
## (hidden unless the saved chunk edits say they were found). No-op for the legacy world.
func ensure_area(rect: Rect2) -> void:
	if not is_seeded():
		return
	for cy in range(maxi(CHUNK_MIN, int(floor(rect.position.y / CHUNK_UNITS))), mini(CHUNK_MAX, int(floor(rect.end.y / CHUNK_UNITS))) + 1):
		for cx in range(maxi(CHUNK_MIN, int(floor(rect.position.x / CHUNK_UNITS))), mini(CHUNK_MAX, int(floor(rect.end.x / CHUNK_UNITS))) + 1):
			_materialize(cx, cy)

func _materialize(cx: int, cy: int) -> void:
	var key := "%d,%d" % [cx, cy]
	if _materialized.has(key):
		return
	_materialized[key] = true
	var chunk := chunk_at(cx, cy)
	var edits: Dictionary = seeded.chunkEdits.get(key, {}).get("mines", {})
	for c: Dictionary in chunk.get("mines", []):
		var m: Dictionary = c.duplicate()
		var e: Dictionary = edits.get(m.id, {})
		m.grade = WorldGen.resource_grade(m.resource)
		m.developmentState = e.get("developmentState", "unsecured")
		_generated_ids[m.id] = true
		mines.append(m)
		if not e.get("discovered", false):
			hidden_ids.append(m.id)

func _record_edit(id: String) -> void:
	if not is_seeded() or not _generated_ids.has(id):
		return
	var m := mine_by_id(id)
	var key := "%d,%d" % [int(floor(float(m.x) / CHUNK_UNITS)), int(floor(float(m.y) / CHUNK_UNITS))]
	if not seeded.chunkEdits.has(key):
		seeded.chunkEdits[key] = {"mines": {}}
	seeded.chunkEdits[key].mines[id] = {"discovered": not hidden_ids.has(id), "developmentState": m.developmentState}

## Props of the seeded chunks already loaded (scenery of the outer world).
func generated_props() -> Array:
	var out: Array = []
	for key: Vector2i in _chunks:
		out.append_array(_chunks[key].props)
	return out

# --- save shape -----------------------------------------------------------------------------------------

## The web state.world fields this module owns. Generated (seeded-world) veins are not saved: only
## their edits are, as in the web serializeRunForSave.
func to_dict() -> Dictionary:
	var saved_mines: Array = []
	var saved_hidden: Array = []
	for m: Dictionary in mines:
		if not _generated_ids.has(m.id):
			saved_mines.append(m.duplicate())
	for id in hidden_ids:
		if not _generated_ids.has(id):
			saved_hidden.append(id)
	var d := {"layoutSeed": layout_seed, "base": {"x": base.x, "y": base.y, "level": base_level},
		"mines": saved_mines, "hiddenMineIds": saved_hidden, "tunnelUnlocked": tunnel_unlocked,
		"workshops": workshops.duplicate(true), "torches": torches.duplicate(true),
		"tunnelContract": tunnel_contract.duplicate() if not tunnel_contract.is_empty() else null}
	if not story.is_empty():
		d["regionStory"] = story.duplicate()
	if is_seeded():
		for k in seeded:
			d[k] = seeded[k].duplicate(true) if seeded[k] is Dictionary else seeded[k]
	return d

## Rebuilds a world from to_dict() output or a web save's state.world. Unknown or broken entries are
## dropped (mines must have an id, integer cells inside the bounds and a known resource).
static func from_dict(d: Dictionary) -> RefCounted:
	var s: RefCounted = load(SELF_PATH).new()
	s.story = Story.restore(d.get("regionStory"))
	s.layout_seed = int(d.get("layoutSeed", 0))
	var b: Dictionary = d.get("base", {}) if d.get("base") is Dictionary else {}
	var w := WorldData.world()
	s.base = Vector2i(int(b.get("x", w.START_BASE_X)), int(b.get("y", w.START_BASE_Y)))
	s.base_level = int(b.get("level", 1))
	var ids := {}
	for raw: Variant in d.get("mines", []):
		if not raw is Dictionary:
			continue
		var m: Dictionary = raw
		var id := str(m.get("id", ""))
		var x: Variant = m.get("x")
		var y: Variant = m.get("y")
		if id == "" or ids.has(id) or WorldData.resource(str(m.get("resource", ""))).is_empty():
			continue
		if not (x is int or x is float) or not (y is int or y is float) or floor(x) != x or floor(y) != y:
			continue
		if id.begins_with("gen:v"):
			continue
		ids[id] = true
		var clean := m.duplicate()
		clean.x = int(x)
		clean.y = int(y)
		clean.grade = int(m.get("grade", WorldGen.resource_grade(m.resource)))
		clean.miningPower = int(m.get("miningPower", 1))
		clean.developmentState = str(m.get("developmentState", "unsecured"))
		s.mines.append(clean)
	for id: Variant in d.get("hiddenMineIds", []):
		if ids.has(str(id)) and not s.hidden_ids.has(str(id)):
			s.hidden_ids.append(str(id))
	s.tunnel_unlocked = d.get("tunnelUnlocked", false) == true
	if d.get("size") == SEEDED_SIZE or d.get("size") == float(SEEDED_SIZE):
		var ctx := {"seed": d.get("seed"), "generatorVersion": int(d.get("generatorVersion", 2))}
		if ChunkGen.is_valid_context(ctx):
			s.seeded = {"seed": int(d.seed), "size": SEEDED_SIZE, "generatorVersion": ctx.generatorVersion,
				"chunkEditsVersion": 1, "chunkEdits": (d.get("chunkEdits", {}) as Dictionary).duplicate(true)}
	s.workshops = CraftHuts.sanitize(d.get("workshops", []), _recipe_table(), s.is_seeded())
	s.torches = sanitize_torches(d.get("torches", []), s.is_seeded())
	s.tunnel_contract = {} if s.tunnel_unlocked else sanitize_contract(d.get("tunnelContract"))
	return s

## web sanitizeTorches: finite points inside the world, at most TORCH.MAX, kept exactly as saved.
static func sanitize_torches(raw: Variant, seeded := false) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	var cap := int(WorldData.catalog().get("torch", {}).get("MAX", 12))
	for t: Variant in raw:
		if out.size() >= cap:
			break
		if not t is Dictionary or not _finite(t.get("x")) or not _finite(t.get("y")):
			continue
		var x := float(t.x)
		var y := float(t.y)
		if WorldTerrain.in_bounds(x, y) or (seeded and absf(x) < SEEDED_EDGE and absf(y) < SEEDED_EDGE):
			out.append({"x": x, "y": y})
	return out

## web sanitizeTunnelContract: a start time and a positive duration, or nothing.
static func sanitize_contract(raw: Variant) -> Dictionary:
	if not raw is Dictionary or not _finite(raw.get("startedAt")) or not _finite(raw.get("durationSec")):
		return {}
	if float(raw.startedAt) < 0.0 or float(raw.durationSec) <= 0.0:
		return {}
	return {"startedAt": float(raw.startedAt), "durationSec": float(raw.durationSec)}

static func _finite(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))

## Recipe rows by key, for checking a saved hut's recipe.
static func _recipe_table() -> Dictionary:
	var table := {}
	for row: Dictionary in WorldData.catalog().get("recipes", []):
		table[row.key] = row
	return table
