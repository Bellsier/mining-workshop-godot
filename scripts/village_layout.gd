extends RefCounted
## Where the village stands (web js/village.js @ 7484ccd, with the obstacle rules of js/player.js): the
## appraiser's and museum's sites, the plaza district (plaza, the player's house, the garden), the roads
## between the doors, the garden cells and every obstacle box. Placement is chosen once and saved in the
## village state (sites, district); roads and boxes are worked out from it.
##
## `world` is the WorldState (base, mines, workshops, torches, tunnel_unlocked); `village` is the village
## progress (sites, district, decor). Coordinates are world units; y grows southwards.

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const WorldGen := preload("res://scripts/world/world_gen.gd")

const ORDER := ["appraiser", "museum"]


static func V() -> Dictionary:
	return WorldData.catalog().village


static func _foot() -> Dictionary:
	return WorldData.player_foot()


## web Math.round for non-negative and negative values alike (halves go up).
static func _round(v: float) -> float:
	return floorf(v + 0.5)


static func _hypot(x: float, y: float) -> float:
	return sqrt(x * x + y * y)


static func seg_dist(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	var l2 := dx * dx + dy * dy
	var t := clampf(((px - ax) * dx + (py - ay) * dy) / l2, 0.0, 1.0) if l2 != 0.0 else 0.0
	return _hypot(px - (ax + t * dx), py - (ay + t * dy))


static func seg_poly_dist(points: Array, x: float, y: float) -> float:
	var d := INF
	for i in points.size() - 1:
		d = minf(d, seg_dist(x, y, points[i].x, points[i].y, points[i + 1].x, points[i + 1].y))
	return d


static func rect_dist(r: Dictionary, x: float, y: float) -> float:
	return _hypot(maxf(maxf(r.minX - x, 0.0), x - r.maxX), maxf(maxf(r.minY - y, 0.0), y - r.maxY))


static func rects_apart(a: Dictionary, b: Dictionary, gap: float) -> bool:
	return a.maxX + gap <= b.minX or b.maxX + gap <= a.minX or a.maxY + gap <= b.minY or b.maxY + gap <= a.minY


static func foot_overlaps(o: Dictionary, x: float, y: float) -> bool:
	var f := _foot()
	return x + f.HALF_W > o.minX and x - f.HALF_W < o.maxX and y + f.HALF_H > o.minY and y - f.HALF_H < o.maxY


# --- boxes ---------------------------------------------------------------------------------------------------

static func facility_box(key: String, x: float, y: float) -> Dictionary:
	var b: Dictionary = V().FACILITIES[key].box
	return {"kind": "village", "id": key, "minX": x + b.minX, "maxX": x + b.maxX, "minY": y + b.minY, "maxY": y + b.maxY}


static func house_box(door: Dictionary) -> Dictionary:
	var b: Dictionary = V().DISTRICT.HOUSE_BOX
	return {"kind": "house", "id": "house", "minX": door.x + b.minX, "maxX": door.x + b.maxX, "minY": door.y + b.minY, "maxY": door.y + b.maxY}


static func object_box(kind: String, x: float, y: float, id := "") -> Dictionary:
	var b: Dictionary = WorldData.obstacle_boxes()[kind]
	return {"kind": kind, "id": id, "minX": x + b.minX, "maxX": x + b.maxX, "minY": y + b.minY, "maxY": y + b.maxY}


## The village's own walls: facility sites (every stage), the house, the garden decorations (web villageObstacleBoxesNow).
static func village_boxes(village: Dictionary, carry := -1) -> Array:
	var out: Array = []
	var sites: Dictionary = village.get("sites", {})
	for key: String in ORDER:
		var s: Variant = sites.get(key)
		if s is Dictionary:
			out.append(facility_box(key, s.x, s.y))
	if village.get("district") is Dictionary:
		var parts := district_parts(village.district)
		out.append(house_box(parts.house))
		for d: Dictionary in village.get("decor", []):
			if int(d.cell) != carry:
				var box := decor_box(village, str(d.kind), int(d.cell))
				if not box.is_empty():
					out.append(box)
	return out


## Every obstacle box (web worldObstaclesScan, whole world): veins, the workshop, huts, the village, and with the
## tunnel open the solid scenery beyond.
static func obstacles(world: RefCounted, village: Dictionary, carry := -1) -> Array:
	var out: Array = []
	for m: Dictionary in world.mines:
		out.append(object_box("mine", m.x, m.y, str(m.id)))
	out.append(object_box("base", world.base.x, world.base.y, "base"))
	for w: Dictionary in world.workshops:
		out.append(object_box("workshop", w.x, w.y, str(w.id)))
	out.append_array(village_boxes(village, carry))
	if world.tunnel_unlocked:
		var sb := WorldData.scenery_boxes()
		for pr: Dictionary in WorldTerrain.scenery_for(world.mines):
			if sb.has(pr.kind):
				var b: Dictionary = sb[pr.kind]
				out.append({"kind": "scenery", "id": pr.kind, "minX": pr.x + b.minX, "maxX": pr.x + b.maxX, "minY": pr.y + b.minY, "maxY": pr.y + b.maxY})
	return out


## Boxes bucketed by unit cell of their centre, so a point looks at the few round it.
class Index:
	var buckets := {}
	var boxes: Array = []
	var foot: Dictionary

	func _init(list: Array) -> void:
		boxes = list
		foot = WorldData.player_foot()
		for o: Dictionary in list:
			var key := Vector2i(int(floor((o.minX + o.maxX) / 2.0)), int(floor((o.minY + o.maxY) / 2.0)))
			if not buckets.has(key):
				buckets[key] = []
			buckets[key].append(o)

	## Does the player's foot box at (x, y) touch a box? (Looks at the boxes centred within 2 cells.)
	func blocks(x: float, y: float) -> bool:
		var hw: float = foot.HALF_W
		var hh: float = foot.HALF_H
		var cx := int(floor(x))
		var cy := int(floor(y))
		for j in range(cy - 2, cy + 3):
			for i in range(cx - 2, cx + 3):
				var b: Variant = buckets.get(Vector2i(i, j))
				if b == null:
					continue
				for o: Dictionary in b:
					if x + hw > o.minX and x - hw < o.maxX and y + hh > o.minY and y - hh < o.maxY:
						return true
		return false

	## Boxes whose centre is within 2 cells of (x, y): every box a small foot box at (x, y) could touch.
	func near(x: float, y: float) -> Array:
		var out: Array = []
		var cx := int(floor(x))
		var cy := int(floor(y))
		for j in range(cy - 2, cy + 3):
			for i in range(cx - 2, cx + 3):
				var b: Variant = buckets.get(Vector2i(i, j))
				if b != null:
					out.append_array(b)
		return out


## Could the player stand at (x, y)? Terrain and the obstacle boxes (web playerCanStand).
static func can_stand(index: Index, tunnel_open: bool, x: float, y: float) -> bool:
	if not WorldTerrain.is_point_walkable(x, y, tunnel_open):
		return false
	return not index.blocks(x, y)


## The grid cells (j * nx + i, point (x0 + i * st, y0 + j * st)) where the player's foot box touches box `o`:
## exactly the cells foot_overlaps(o, x, y) is true for, found by testing only the cells round the box.
## With `bucket` (the box's Index cell), only points whose own cell is within 2 of it, as Index.blocks looks.
static func _cover(o: Dictionary, x0: float, y0: float, st: float, nx: int, ny: int, hw: float, hh: float,
		bucket := Vector2i(-2147483647, 0)) -> PackedInt32Array:
	var out := PackedInt32Array()
	var i0 := maxi(0, int(floor((float(o.minX) - hw - x0) / st)) - 1)
	var i1 := mini(nx - 1, int(ceil((float(o.maxX) + hw - x0) / st)) + 1)
	var j0 := maxi(0, int(floor((float(o.minY) - hh - y0) / st)) - 1)
	var j1 := mini(ny - 1, int(ceil((float(o.maxY) + hh - y0) / st)) + 1)
	var limited := bucket.x != -2147483647
	for j in range(j0, j1 + 1):
		var py := y0 + j * st
		if not (py + hh > o.minY and py - hh < o.maxY):
			continue
		if limited and absi(int(floor(py)) - bucket.y) > 2:
			continue
		for i in range(i0, i1 + 1):
			var px := x0 + i * st
			if px + hw > o.minX and px - hw < o.maxX and (not limited or absi(int(floor(px)) - bucket.x) <= 2):
				out.append(j * nx + i)
	return out


## The reach check over a rectangle, flood-filled from `start` (web villageReachArea). Returns a Callable
## (boxes: Array, doors: Array) -> bool: with the new walls, every door can still be walked to and nothing that
## could be reached before is cut off.
## Same answer as testing can_stand and foot_overlaps at every grid point; the boxes are laid onto the grid
## once instead (the web game does the per-point tests, which are slow in GDScript compiled to WebAssembly).
static func reach_area(index: Index, tunnel_open: bool, x0: float, y0: float, x1: float, y1: float, start: Dictionary) -> Callable:
	var st: float = V().SITE.GRID
	var nx := int(_round((x1 - x0) / st)) + 1
	var ny := int(_round((y1 - y0) / st)) + 1
	var n := nx * ny
	var hw: float = index.foot.HALF_W
	var hh: float = index.foot.HALF_H
	var can := PackedByteArray()
	can.resize(n)
	for j in ny:
		var py := y0 + j * st
		for i in nx:
			can[j * nx + i] = 1 if WorldTerrain.is_point_walkable(x0 + i * st, py, tunnel_open) else 0
	for key: Vector2i in index.buckets:
		for o: Dictionary in index.buckets[key]:
			for c: int in _cover(o, x0, y0, st, nx, ny, hw, hh, key):
				can[c] = 0
	var cell := func(x: float, y: float) -> int:
		var i := int(_round((x - x0) / st))
		var j := int(_round((y - y0) / st))
		return -1 if i < 0 or j < 0 or i >= nx or j >= ny else j * nx + i
	var fill := func(blocked: PackedByteArray) -> PackedByteArray:
		var seen := PackedByteArray()
		seen.resize(n)
		var s0: int = cell.call(start.x, start.y)
		if s0 < 0 or can[s0] == 0 or blocked[s0] == 1:
			return seen
		var q := PackedInt32Array([s0])
		seen[s0] = 1
		while not q.is_empty():
			var c: int = q[q.size() - 1]
			q.resize(q.size() - 1)
			var i := c % nx
			for d: int in [c - 1 if i > 0 else -1, c + 1 if i < nx - 1 else -1, c - nx, c + nx]:
				if d < 0 or d >= n or seen[d] == 1 or can[d] == 0 or blocked[d] == 1:
					continue
				seen[d] = 1
				q.append(d)
		return seen
	var none := PackedByteArray()
	none.resize(n)
	var before: PackedByteArray = fill.call(none)
	return func(boxes: Array, doors: Array) -> bool:
		var hit := PackedByteArray()
		hit.resize(n)
		for o: Dictionary in boxes:
			for c: int in _cover(o, x0, y0, st, nx, ny, hw, hh):
				hit[c] = 1
		var after: PackedByteArray = fill.call(hit)
		for d: Dictionary in doors:
			var c: int = cell.call(d.x, d.y)
			if c < 0 or after[c] == 0:
				return false
		for c in n:
			if before[c] == 1 and after[c] == 0 and hit[c] == 0:
				return false
		return true


static func _reach_grid(world: RefCounted, index: Index, reach: float) -> Callable:
	var b: Vector2i = world.base
	return reach_area(index, world.tunnel_unlocked, b.x - reach, b.y - reach, b.x + reach, b.y + reach, {"x": float(b.x), "y": b.y + 0.05})


# --- facility sites ------------------------------------------------------------------------------------------

## The simple rules for a site (web villageSiteFits).
static func site_fits(world: RefCounted, key: String, x: float, y: float, placed: Array) -> bool:
	var S: Dictionary = V().SITE
	var b: Dictionary = V().FACILITIES[key].box
	var base: Vector2i = world.base
	if WorldTerrain.region_at(x, y) != "open":
		return false
	var x0: float = x + b.minX - S.ROOM
	var x1: float = x + b.maxX + S.ROOM
	var y0: float = y + b.minY - S.ROOM
	var y1 := y + 0.5
	for g: Vector2 in [Vector2(x0, y0), Vector2(x1, y0), Vector2(x0, y1), Vector2(x1, y1), Vector2(x, y0), Vector2(x, y1), Vector2(x0, y), Vector2(x1, y)]:
		if WorldTerrain.region_at(g.x, g.y) != "open" or not WorldTerrain.is_point_walkable(g.x, g.y, world.tunnel_unlocked):
			return false
	if _hypot(x - base.x, y - base.y) < S.RMIN:
		return false
	for m: Dictionary in world.mines:
		if _hypot(m.x - x, m.y - y) < S.MINE_CLEAR:
			return false
	for c: Vector2i in WorldGen.expansion_seed_cells(base):
		if _hypot(c.x - x, c.y - y) < S.MINE_CLEAR:
			return false
	for w: Dictionary in world.workshops:
		if _hypot(w.x - x, w.y - y) < S.WORKSHOP_CLEAR:
			return false
	var t := WorldTerrain.tunnel(world.tunnel_unlocked)
	if seg_dist(x, y, base.x, base.y, t.mouth_x, t.y) < S.ROAD_CLEAR:
		return false
	for p: Dictionary in placed:
		if _hypot(p.x - x, p.y - y) < S.GAP:
			return false
	return true


static func _candidates(base: Vector2i, rmin: float, rmax: float, step: float, skip_inner: float) -> Array:
	var cands: Array = []
	var dy := -rmax
	while dy <= rmax + 1e-9:
		var dx := -rmax
		while dx <= rmax + 1e-9:
			var d := _hypot(dx, dy)
			if not (d < rmin - 1e-9 or d > rmax + 1e-9 or (skip_inner > 0.0 and d <= skip_inner + 1e-9)):
				cands.append({"x": _round((base.x + dx) * 2.0) / 2.0, "y": _round((base.y + dy) * 2.0) / 2.0, "d": d, "a": atan2(dx, dy)})
			dx += step
		dy += step
	return cands


## Gives every facility without a site one (web villageEnsureSites), then the district. Changes `village`.
## Returns true when every facility has a site.
static func ensure_sites(world: RefCounted, village: Dictionary) -> bool:
	if not village.get("sites") is Dictionary:
		village["sites"] = {}
	var sites: Dictionary = village.sites
	if ORDER.all(func(k: String) -> bool: return sites.get(k) is Dictionary):
		ensure_district(world, village)
		return true
	var S: Dictionary = V().SITE
	var base: Vector2i = world.base
	var placed: Array = []
	for k: String in ORDER:
		if sites.get(k) is Dictionary:
			placed.append(sites[k])
	var reach := Callable()
	for key: String in ORDER:
		if sites.get(key) is Dictionary:
			continue
		for rmax: float in S.RMAX:
			var cands := _candidates(base, float(S.RMIN), rmax, float(S.STEP), 0.0)
			# The web keeps the in-range check d < RMIN || d > rmax without the 1e-9 slack.
			cands = cands.filter(func(c: Dictionary) -> bool: return not (c.d < S.RMIN or c.d > rmax))
			cands.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
				if p.d != q.d: return p.d < q.d
				if absf(p.a) != absf(q.a): return absf(p.a) < absf(q.a)
				return p.a < q.a)
			for c: Dictionary in cands:
				if not site_fits(world, key, c.x, c.y, placed):
					continue
				if not reach.is_valid():
					reach = _reach_grid(world, Index.new(obstacles(world, village)), float(S.REACH))
				var walls: Array = []
				for k: String in ORDER:
					if sites.get(k) is Dictionary:
						walls.append(facility_box(k, sites[k].x, sites[k].y))
				if not reach.call([facility_box(key, c.x, c.y)] + walls, [{"x": c.x, "y": c.y + 0.1}]):
					continue
				sites[key] = {"x": c.x, "y": c.y}
				placed.append(sites[key])
				break
			if sites.get(key) is Dictionary:
				break
	var ok: bool = ORDER.all(func(k: String) -> bool: return sites.get(k) is Dictionary)
	if ok:
		ensure_district(world, village)
	return ok


# --- the district --------------------------------------------------------------------------------------------

## Plaza, house door, garden and the footprint rectangles for a plaza point and layout (web villageDistrictParts).
static func district_parts(d: Dictionary) -> Dictionary:
	var D: Dictionary = V().DISTRICT
	var layouts: Array = D.LAYOUTS
	var L: Dictionary = layouts[int(d.layout)] if int(d.layout) >= 0 and int(d.layout) < layouts.size() else layouts[0]
	var R: float = D.PLAZA_R
	var hb: Dictionary = D.HOUSE_BOX
	var hr: float = D.HOUSE_ROOM
	var gh: Dictionary = D.GARDEN_HALF
	var house := {"x": d.x + L.house.x, "y": d.y + L.house.y}
	var garden := {"x": d.x + L.garden.x, "y": d.y + L.garden.y, "hw": gh.x, "hh": gh.y}
	return {"plaza": {"x": d.x, "y": d.y, "r": R}, "house": house, "garden": garden, "rects": [
		{"minX": d.x - R, "maxX": d.x + R, "minY": d.y - R, "maxY": d.y + R},
		{"minX": house.x + hb.minX - hr, "maxX": house.x + hb.maxX + hr, "minY": house.y + hb.minY - hr, "maxY": house.y + 0.4},
		{"minX": garden.x - gh.x, "maxX": garden.x + gh.x, "minY": garden.y - gh.y, "maxY": garden.y + gh.y},
	]}


## What district_fits measures against that stays the same while one district is looked for.
static func _district_context(world: RefCounted) -> Dictionary:
	var base: Vector2i = world.base
	var veins: Array = []
	for m: Dictionary in world.mines:
		veins.append(Vector2(m.x, m.y))
	for c: Vector2i in WorldGen.expansion_seed_cells(base):
		veins.append(Vector2(c))
	var t := WorldTerrain.tunnel(world.tunnel_unlocked)
	var tunnel_road: Array = []
	for k in 41:
		tunnel_road.append(Vector2(base.x + (t.mouth_x - base.x) * k / 40.0, base.y + (t.y - base.y) * k / 40.0))
	return {"veins": veins, "tunnel_road": tunnel_road}


## Does the district fit at (x, y) with this layout (web villageDistrictFits)? Every rule must hold, so the
## cheap distance rules are checked before walking each footprint on its 0.25 grid; the answer is the same.
static func district_fits(world: RefCounted, village: Dictionary, x: float, y: float, layout: int, context := {}) -> bool:
	var D: Dictionary = V().DISTRICT
	var B := WorldData.world()
	var base: Vector2i = world.base
	var rects: Array = district_parts({"x": x, "y": y, "layout": layout}).rects
	var ctx: Dictionary = context if not context.is_empty() else _district_context(world)
	var veins: Array = ctx.veins
	var tunnel_road: Array = ctx.tunnel_road
	var sites: Dictionary = village.get("sites", {})
	for r: Dictionary in rects:
		if r.minX < B.BOUNDS_MIN_X + D.EDGE or r.maxX > B.BOUNDS_MAX_X - D.EDGE or r.minY < B.BOUNDS_MIN_Y + D.EDGE or r.maxY > B.BOUNDS_MAX_Y - D.EDGE:
			return false
		if rect_dist(r, base.x, base.y) < D.BASE_CLEAR:
			return false
		for v: Vector2 in veins:
			if rect_dist(r, v.x, v.y) < D.MINE_CLEAR:
				return false
		for w: Dictionary in world.workshops:
			if rect_dist(r, w.x, w.y) < D.HUT_CLEAR:
				return false
		for k: String in ORDER:
			var s: Variant = sites.get(k)
			if s is Dictionary and (not rects_apart(r, facility_box(k, s.x, s.y), D.FACILITY_CLEAR) or rect_dist(r, s.x, s.y + 0.1) < D.FACILITY_CLEAR):
				return false
		for p: Vector2 in tunnel_road:
			if rect_dist(r, p.x, p.y) < D.TUNNEL_ROAD_CLEAR:
				return false
		for tc: Dictionary in world.torches:
			if rect_dist(r, tc.x, tc.y) < D.TORCH_CLEAR:
				return false
	for r: Dictionary in rects:
		var px: float = r.minX
		while px <= r.maxX + 1e-9:
			var py: float = r.minY
			while py <= r.maxY + 1e-9:
				if WorldTerrain.region_at(px, py) != "open" or not WorldTerrain.is_point_walkable(px, py, world.tunnel_unlocked):
					return false
				py += 0.25
			px += 0.25
	return true


## Gives the village its plaza once (web villageEnsureDistrict). Needs the facility sites first.
static func ensure_district(world: RefCounted, village: Dictionary) -> bool:
	if village.get("district") is Dictionary:
		return true
	var sites: Dictionary = village.get("sites", {})
	if not ORDER.all(func(k: String) -> bool: return sites.get(k) is Dictionary):
		return false
	var D: Dictionary = V().DISTRICT
	var base: Vector2i = world.base
	var reach := Callable()
	var context := _district_context(world)
	var rings: Array = [D.DIST[1], D.DIST_WIDE]
	for ri in rings.size():
		var rmin: float = D.DIST[0] if ri == 0 else D.DIST[1]
		var cands := _candidates(base, rmin, float(rings[ri]), float(D.STEP), float(D.DIST[1]) if ri > 0 else 0.0)
		var ideal: float = D.IDEAL
		cands.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
			var dp := absf(p.d - ideal)
			var dq := absf(q.d - ideal)
			if dp != dq: return dp < dq
			if absf(p.a) != absf(q.a): return absf(p.a) < absf(q.a)
			return p.a < q.a)
		for c: Dictionary in cands:
			for layout in D.LAYOUTS.size():
				if not district_fits(world, village, c.x, c.y, layout, context):
					continue
				if not reach.is_valid():
					reach = _reach_grid(world, Index.new(obstacles(world, village)), float(D.REACH))
				var parts := district_parts({"x": c.x, "y": c.y, "layout": layout})
				if not reach.call([house_box(parts.house)], [{"x": parts.house.x, "y": parts.house.y + 0.1}, {"x": c.x, "y": c.y}]):
					continue
				village["district"] = {"x": c.x, "y": c.y, "layout": layout}
				return true
	return false


# --- roads ---------------------------------------------------------------------------------------------------

## Where roads lead from: the workshop door first (the main road), each facility, the house (web villageRoadEnds).
static func road_ends(world: RefCounted, village: Dictionary) -> Array:
	var ends: Array = [{"to": "workshop", "x": float(world.base.x), "y": world.base.y + 0.2}]
	var sites: Dictionary = village.get("sites", {})
	for k: String in ORDER:
		if sites.get(k) is Dictionary:
			ends.append({"to": k, "x": float(sites[k].x), "y": sites[k].y + 0.2})
	if village.get("district") is Dictionary:
		var h: Dictionary = district_parts(village.district).house
		ends.append({"to": "house", "x": float(h.x), "y": h.y + 0.2})
	return ends


## The road network (web villageRoadsCompute): [{to, points: [{x, y}, ...]}]. Each road starts at a door step
## and ends where it meets the plaza or a road laid before it: a breadth-first search on a grid of lanes round
## the walls, veins and the garden, pulled straight where the way is clear.
static func roads(world: RefCounted, village: Dictionary) -> Array:
	if not village.get("district") is Dictionary:
		return []
	var D: Dictionary = V().DISTRICT
	var B := WorldData.world()
	var parts := district_parts(village.district)
	var st: float = D.ROAD_GRID
	var ends := road_ends(world, village)
	var plaza: Dictionary = parts.plaza
	var g: Dictionary = parts.garden
	var xs: Array = ends.map(func(e: Dictionary) -> float: return e.x) + [plaza.x]
	var ys: Array = ends.map(func(e: Dictionary) -> float: return e.y) + [plaza.y]
	var x0 := maxf(B.BOUNDS_MIN_X, xs.min() - 2.0)
	var y0 := maxf(B.BOUNDS_MIN_Y, ys.min() - 2.0)
	var x1 := minf(B.BOUNDS_MAX_X, xs.max() + 2.0)
	var y1 := minf(B.BOUNDS_MAX_Y, ys.max() + 2.0)
	var nx := int(floor((x1 - x0) / st)) + 1
	var ny := int(floor((y1 - y0) / st)) + 1
	# garden pieces never change a road
	var index := Index.new(obstacles(world, village).filter(func(o: Dictionary) -> bool: return o.kind != "decor"))
	var F := _foot()
	var tunnel_open: bool = world.tunnel_unlocked
	var free_with := func(room: float) -> Callable:
		return func(x: float, y: float) -> bool:
			if WorldTerrain.region_at(x, y) != "open" or not WorldTerrain.is_point_walkable(x, y, tunnel_open):
				return false
			if absf(x - g.x) < g.hw and absf(y - g.y) < g.hh:
				return false
			for o: Dictionary in index.near(x, y):
				if x > o.minX - room - F.HALF_W and x < o.maxX + room + F.HALF_W and y > o.minY - room - F.HALF_H and y < o.maxY + room + F.HALF_H:
					return false
			return true
	var grids: Array = []
	for room: float in [float(D.ROAD_ROOM), 0.0]:
		var free: Callable = free_with.call(room)
		var ok := PackedByteArray()
		ok.resize(nx * ny)
		for j in ny:
			for i in nx:
				ok[j * nx + i] = 1 if free.call(x0 + i * st, y0 + j * st) else 0
		grids.append({"free": free, "ok": ok})
	var px := func(c: int) -> float: return _round((x0 + (c % nx) * st) * 100.0) / 100.0
	var py := func(c: int) -> float: return _round((y0 + floorf(float(c) / nx) * st) * 100.0) / 100.0
	var net := PackedByteArray()
	net.resize(nx * ny)
	var mark_disc := func(x: float, y: float, r: float) -> void:
		for j in range(maxi(0, int(floor((y - r - y0) / st))), mini(ny - 1, int(ceil((y + r - y0) / st))) + 1):
			for i in range(maxi(0, int(floor((x - r - x0) / st))), mini(nx - 1, int(ceil((x + r - x0) / st))) + 1):
				if _hypot(x0 + i * st - x, y0 + j * st - y) <= r:
					net[j * nx + i] = 1
	mark_disc.call(plaza.x, plaza.y, plaza.r - 0.2)
	var steps := [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [1, -1], [-1, 1], [-1, -1]]
	var result: Array = []
	for e: Dictionary in ends:
		for gr: Dictionary in grids:
			var ok: PackedByteArray = gr.ok
			var start := -1
			var best_d := 0.75
			for j in range(maxi(0, int(floor((e.y - 0.8 - y0) / st))), mini(ny - 1, int(ceil((e.y + 0.8 - y0) / st))) + 1):
				for i in range(maxi(0, int(floor((e.x - 0.8 - x0) / st))), mini(nx - 1, int(ceil((e.x + 0.8 - x0) / st))) + 1):
					var c := j * nx + i
					var d := _hypot(x0 + i * st - e.x, y0 + j * st - e.y)
					if ok[c] == 1 and d < best_d:
						start = c
						best_d = d
			if start < 0:
				continue
			var from := PackedInt32Array()
			from.resize(nx * ny)
			from.fill(-1)
			from[start] = start
			var hit := start if net[start] == 1 else -1
			var q := PackedInt32Array([start])
			var h := 0
			while h < q.size() and hit < 0:
				var c: int = q[h]
				h += 1
				var i := c % nx
				var j := (c - i) / nx
				for s: Array in steps:
					var di: int = s[0]
					var dj: int = s[1]
					var ii := i + di
					var jj := j + dj
					var d := jj * nx + ii
					if ii < 0 or jj < 0 or ii >= nx or jj >= ny or from[d] >= 0:
						continue
					if net[d] == 0 and ok[d] == 0:
						continue
					if di != 0 and dj != 0 and not ((ok[j * nx + ii] == 1 or net[j * nx + ii] == 1) and (ok[jj * nx + i] == 1 or net[jj * nx + i] == 1)):
						continue
					from[d] = c
					if net[d] == 1:
						hit = d
						break
					q.append(d)
			if hit < 0:
				continue
			var cells: Array = []
			var c2 := hit
			while true:
				cells.push_front({"x": px.call(c2), "y": py.call(c2)})
				if from[c2] == c2:
					break
				c2 = from[c2]
			var free: Callable = gr.free
			var clear := func(a: Dictionary, b: Dictionary) -> bool:
				var n := maxi(1, int(ceil(_hypot(b.x - a.x, b.y - a.y) / 0.05)))
				for k in n + 1:
					if not free.call(a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n):
						return false
				return true
			var pts: Array = [cells[0]]
			var i2 := 0
			while i2 < cells.size() - 1:
				var j2 := cells.size() - 1
				while j2 > i2 + 1 and not clear.call(cells[i2], cells[j2]):
					j2 -= 1
				pts.append(cells[j2])
				i2 = j2
			pts.push_front({"x": e.x, "y": e.y})
			var points: Array = []
			for k in pts.size():
				if k == 0 or pts[k].x != pts[k - 1].x or pts[k].y != pts[k - 1].y:
					points.append(pts[k])
			for k in range(1, points.size()):
				var a: Dictionary = points[k - 1]
				var b: Dictionary = points[k]
				var n := maxi(1, int(ceil(_hypot(b.x - a.x, b.y - a.y) / 0.1)))
				for m in n + 1:
					mark_disc.call(a.x + (b.x - a.x) * m / n, a.y + (b.y - a.y) * m / n, 0.12)
			result.append({"to": e.to, "points": points})
			break
	return result


## Is (x, y) on the village ground (the district or a road) within `clear`? A new craft hut keeps off it.
static func ground_near(world: RefCounted, village: Dictionary, road_list: Array, x: float, y: float, clear: float) -> bool:
	if not village.get("district") is Dictionary:
		return false
	for r: Dictionary in district_parts(village.district).rects:
		if rect_dist(r, x, y) < clear:
			return true
	for road: Dictionary in road_list:
		if seg_poly_dist(road.points, x, y) < clear:
			return true
	return false


static func site_near(village: Dictionary, x: float, y: float, dist: float) -> bool:
	var sites: Dictionary = village.get("sites", {})
	for k: String in ORDER:
		var s: Variant = sites.get(k)
		if s is Dictionary and _hypot(s.x - x, s.y - y) < dist:
			return true
	return false


# --- the garden ----------------------------------------------------------------------------------------------

static func garden_cells(village: Dictionary) -> Array:
	if not village.get("district") is Dictionary:
		return []
	var G: Dictionary = V().GARDEN
	var g: Dictionary = district_parts(village.district).garden
	var out: Array = []
	for r in int(G.ROWS):
		for c in int(G.COLS):
			out.append({"cell": r * int(G.COLS) + c, "x": _round((g.x + (c - (G.COLS - 1) / 2.0) * G.DX) * 100.0) / 100.0,
				"y": _round((g.y + (r - (G.ROWS - 1) / 2.0) * G.DY) * 100.0) / 100.0})
	return out


static func decor_def(kind: String) -> Dictionary:
	for d: Dictionary in V().DECOR:
		if d.key == kind:
			return d
	return {}


static func decor_box(village: Dictionary, kind: String, cell: int) -> Dictionary:
	var d := decor_def(kind)
	var cells := garden_cells(village)
	if d.is_empty() or cell < 0 or cell >= cells.size():
		return {}
	var at: Dictionary = cells[cell]
	return {"kind": "decor", "id": "decor%d" % cell, "minX": at.x + d.box.minX, "maxX": at.x + d.box.maxX, "minY": at.y + d.box.minY, "maxY": at.y + d.box.maxY}
