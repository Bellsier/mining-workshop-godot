extends RefCounted
## Mine (vein) layouts, ported from the web game's js/worldgen.js (Tasks 63-65, 69) and surveyMines in
## js/research.js (Task 80). A mine is a Dictionary shaped like the web save:
##   {id, x, y, resource, grade, miningPower, developmentState}
## with integer cells x, y in world units. `random` is a Callable returning a float in [0, 1)
## (scripts/world/world_random.gd gives a seeded one).
##
## - generate_initial_mines: new game. Two starters (iron, coal) 2-3 units from the base, then the distance
##   rings round the base (near/mid/far/outer: more, commoner veins near; fewer, rarer far away). Never on
##   the base, on a site-expansion seed cell, on the mountain or by the tunnel mouth.
## - generate_beyond_mines: once, when the tunnel opens. Each beyond zone borrows a ring's resource pool.
## - survey_mines: the "지질 조사" research adds hidden veins in the outer ring.

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")

static func all_cells() -> Array[Vector2i]:
	var b := WorldData.world()
	var cells: Array[Vector2i] = []
	for y in range(int(b.BOUNDS_MIN_Y), int(b.BOUNDS_MAX_Y) + 1):
		for x in range(int(b.BOUNDS_MIN_X), int(b.BOUNDS_MAX_X) + 1):
			cells.append(Vector2i(x, y))
	return cells

static func random_unit(random: Callable) -> float:
	var r := float(random.call())
	if is_nan(r) or is_inf(r):
		return 0.0
	return minf(maxf(r, 0.0), 0.9999999999)

static func pick(list: Array, random: Callable) -> Variant:
	if list.is_empty():
		return null
	return list[int(floor(random_unit(random) * list.size()))]

static func _is_resource(key: String) -> bool:
	return not WorldData.resource(key).is_empty()

## weights: {resource: weight}. Unknown keys and non-positive weights are ignored. "" when nothing fits.
static func pick_weighted(weights: Dictionary, random: Callable) -> String:
	var keys: Array[String] = []
	var total := 0.0
	for k: String in weights:
		var w := float(weights[k])
		if _is_resource(k) and not is_nan(w) and not is_inf(w) and w > 0.0:
			keys.append(k)
			total += w
	if keys.is_empty():
		return ""
	var t := random_unit(random) * total
	for k in keys:
		var w := float(weights[k])
		if t < w:
			return k
		t -= w
	return keys[keys.size() - 1]

## Resources of the sites open from the start (unlockCost 0: iron, coal).
static func start_resources() -> Array[String]:
	var open_sites: Array = []
	for s: Dictionary in WorldData.sites():
		if float(s.unlockCost) == 0.0:
			open_sites.append(s.key)
	var out: Array[String] = []
	for r: Dictionary in WorldData.resources():
		if open_sites.has(r.site):
			out.append(r.key)
	return out

## A mine's grade follows its resource's site tier (abandonedMine 1 .. spaceStation 4).
static func resource_grade(resource: String) -> int:
	var r := WorldData.resource(resource)
	if r.is_empty():
		return 1
	var sites := WorldData.sites()
	for i in sites.size():
		if sites[i].key == r.site:
			return i + 1
	return 1

static func expansion_seed_cells(base: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var seeds := WorldData.mine_seeds()
	for site: String in seeds:
		for s: Dictionary in seeds[site]:
			cells.append(base + Vector2i(int(s.x), int(s.y)))
	return cells

static func _is_int(v: Variant) -> bool:
	return (v is int) or (v is float and not is_inf(v) and not is_nan(v) and floor(v) == v)

## The ring's weights minus every resource whose group has reached its cap (Task 65 `limits`).
static func ring_weights(ring: Dictionary, placed: Array) -> Dictionary:
	var weights: Dictionary = ring.get("resources", {}).duplicate()
	for limit: Dictionary in ring.get("limits", []):
		var group: Array = limit.get("resources", [])
		var mx: Variant = limit.get("max")
		var cap := INF
		if _is_int(mx) and float(mx) >= 0.0:
			cap = float(mx)
		var used := 0
		for r in placed:
			if group.has(r):
				used += 1
		if used >= cap:
			for r in group:
				weights.erase(r)
	return weights

static func ring_index(distance: float, rings: Array) -> int:
	for i in rings.size():
		if distance >= rings[i].minDist and distance < rings[i].maxDist:
			return i
	return -1

static func make_mine(id: String, cell: Vector2i, resource: String) -> Dictionary:
	return {"id": id, "x": cell.x, "y": cell.y, "resource": resource, "grade": resource_grade(resource),
		"miningPower": 1, "developmentState": "unsecured"}

static func _key(c: Vector2i) -> int:
	return (c.x + 4096) * 8192 + (c.y + 4096)

static func _pos(o: Variant) -> Vector2:
	return Vector2(o) if o is Vector2i else Vector2(o.x, o.y)

## New-game mines. options (tests/tuning): rings, extra_count, extra_resources, walkable (Callable x, y -> bool).
static func generate_initial_mines(base: Vector2i, random: Callable, options: Dictionary = {}) -> Array:
	var g := WorldData.world_gen()
	var rings: Array = options.get("rings", g.RINGS)
	var open_cell: Callable = options.get("walkable", func(x: float, y: float) -> bool: return WorldTerrain.is_cell_open_for_mines(x, y))
	var cells: Array[Vector2i] = []
	for c in all_cells():
		if open_cell.call(float(c.x), float(c.y)):
			cells.append(c)
	var used := {_key(base): true}
	var reserved := expansion_seed_cells(base)
	for c in reserved:
		used[_key(c)] = true
	var mines: Array = []
	var base_f := Vector2(base)
	var pick_cell := func(candidates: Array[Vector2i], min_spacing: float) -> Variant:
		var open: Array = []
		var spaced: Array = []
		var others: Array = mines.duplicate()
		others.append_array(reserved)
		for c in candidates:
			if used.has(_key(c)):
				continue
			open.append(c)
			var ok := true
			for o in others:
				if Vector2(c).distance_to(_pos(o)) < min_spacing:
					ok = false
					break
			if ok:
				spaced.append(c)
		return pick(spaced if not spaced.is_empty() else open, random)

	# Starters: one iron and one coal close to the base.
	var starter_cells: Array[Vector2i] = []
	for c in cells:
		var d := Vector2(c).distance_to(base_f)
		if d >= g.STARTER_MIN_DIST and d <= g.STARTER_MAX_DIST:
			starter_cells.append(c)
	var ids := WorldData.starter_ids()
	for resource in ["iron", "coal"]:
		var cell: Variant = pick_cell.call(starter_cells, float(g.STARTER_MIN_SPACING))
		if cell == null:
			continue
		used[_key(cell)] = true
		mines.append(make_mine(ids[resource], cell, resource))

	# Distance rings. Starters count toward the ring they fall in.
	for ring_i in rings.size():
		var ring: Dictionary = rings[ring_i]
		var in_ring: Array[Vector2i] = []
		for c in cells:
			if ring_index(Vector2(c).distance_to(base_f), rings) == ring_i:
				in_ring.append(c)
		var placed: Array = []
		for m: Dictionary in mines:
			if ring_index(_pos(m).distance_to(base_f), rings) == ring_i:
				placed.append(m.resource)
		var count := int(ring.count) if _is_int(ring.get("count")) else 0
		var want := maxi(0, count - placed.size())
		for i in want:
			var cell: Variant = pick_cell.call(in_ring, float(g.MIN_SPACING))
			if cell == null:
				break
			var resource := pick_weighted(ring_weights(ring, placed), random)
			if resource == "":
				break
			placed.append(resource)
			used[_key(cell)] = true
			mines.append(make_mine("mine_ring_%s_%d" % [ring.key, i + 1], cell, resource))

	# Task 63 extra mines anywhere (0 by default).
	var extra := int(options.get("extra_count", g.EXTRA_MINES))
	var pool: Array = options.get("extra_resources", start_resources())
	for i in extra:
		var free: Array = []
		for c in cells:
			if not used.has(_key(c)):
				free.append(c)
		var cell: Variant = pick(free, random)
		if cell == null:
			break
		used[_key(cell)] = true
		mines.append(make_mine("mine_gen_%d" % (i + 1), cell, str(pick(pool, random))))
	return mines

## Mines for the land beyond the mountain, once, when the tunnel opens. Returns the NEW mines only;
## a zone that already holds mines is only topped up to its count.
static func generate_beyond_mines(existing: Array, random: Callable, zones_override: Array = []) -> Array:
	var g := WorldData.world_gen()
	var zones: Array = zones_override if not zones_override.is_empty() else g.BEYOND.ZONES
	var used := {}
	var used_ids := {}
	for m: Dictionary in existing:
		used[_key(Vector2i(int(m.x), int(m.y)))] = true
		used_ids[m.id] = true
	var all: Array[Vector2i] = []
	for c in all_cells():
		if WorldTerrain.is_cell_open_for_beyond_mines(c.x, c.y):
			all.append(c)
	var created: Array = []
	for cfg: Dictionary in zones:
		var ring := {}
		for r: Dictionary in g.RINGS:
			if r.key == cfg.ring:
				ring = r
		if ring.is_empty():
			continue
		var in_zone := 0
		for m: Dictionary in existing:
			if WorldTerrain.beyond_zone_at(m.x, m.y) == cfg.zone:
				in_zone += 1
		var count := int(cfg.count) if _is_int(cfg.get("count")) else 0
		var want := maxi(0, count - in_zone)
		var candidates: Array[Vector2i] = []
		for c in all:
			if WorldTerrain.beyond_zone_at(c.x, c.y) == cfg.zone:
				candidates.append(c)
		var placed: Array = []
		for i in want:
			var open: Array = []
			var spaced: Array = []
			for c in candidates:
				if used.has(_key(c)):
					continue
				open.append(c)
				var ok := true
				for o: Dictionary in existing + created:
					if Vector2(c).distance_to(_pos(o)) < g.BEYOND.MIN_SPACING:
						ok = false
						break
				if ok:
					spaced.append(c)
			var cell: Variant = pick(spaced if not spaced.is_empty() else open, random)
			if cell == null:
				break
			var resource := pick_weighted(ring_weights(ring, placed), random)
			if resource == "":
				break
			placed.append(resource)
			used[_key(cell)] = true
			var n := i + 1
			while used_ids.has("mine_beyond_%s_%d" % [cfg.zone, n]):
				n += 1
			var id := "mine_beyond_%s_%d" % [cfg.zone, n]
			used_ids[id] = true
			created.append(make_mine(id, cell, resource))
	return created

## Task 80 "지질 조사": SURVEY_MINES hidden veins in the outer ring of the start land (cosmicShard and plasma
## first when the world has none). Returns the new mines; the caller adds them (hidden).
static func survey_mines(mines: Array, base: Vector2i, random: Callable) -> Array:
	var g := WorldData.world_gen()
	var ring := {}
	for r: Dictionary in g.RINGS:
		if r.key == "outer":
			ring = r
	var used := {}
	for m: Dictionary in mines:
		used[_key(Vector2i(int(m.x), int(m.y)))] = true
	var candidates: Array[Vector2i] = []
	for c in all_cells():
		if WorldTerrain.is_cell_open_for_mines(c.x, c.y) and not used.has(_key(c)) and Vector2(c).distance_to(Vector2(base)) >= ring.minDist:
			candidates.append(c)
	var wanted: Array[String] = []
	for r in ["cosmicShard", "plasma"]:
		var have := false
		for m: Dictionary in mines:
			if m.resource == r:
				have = true
		if not have:
			wanted.append(r)
	var placed: Array = []
	var added: Array = []
	var count := int(WorldData.research_balance().get("SURVEY_MINES", 3))
	for i in count:
		var open: Array = []
		var spaced: Array = []
		for c in candidates:
			if used.has(_key(c)):
				continue
			open.append(c)
			var ok := true
			for o: Dictionary in mines + added:
				if Vector2(c).distance_to(_pos(o)) < g.MIN_SPACING:
					ok = false
					break
			if ok:
				spaced.append(c)
		var cell: Variant = pick(spaced if not spaced.is_empty() else open, random)
		if cell == null:
			break
		var resource: String = wanted.pop_front() if not wanted.is_empty() else pick_weighted(ring_weights(ring, placed), random)
		if resource == "":
			break
		placed.append(resource)
		used[_key(cell)] = true
		added.append(make_mine("mine_survey_%d" % (mines.size() + added.size() + 1), cell, resource))
	return added
