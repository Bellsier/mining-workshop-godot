extends RefCounted
## The fixed world terrain, ported from the web game's js/terrain.js (Tasks 66-69, 89), the ground tiles of
## js/topdown/tiles.js (tdTileAt, Task 104) and the scenery filter of js/player.js (worldSceneryBase, Task 111).
## Coordinates are web world units (the base starts at (2, 0); the mountain range runs north-south west of
## it; "beyond" is the land west of the range, reached through the tunnel). Everything here is a pure
## function of the terrain data plus `tunnel_open`; nothing is saved.
##
## Regions (region_at): "outside" | "open" | "tunnel" | "mountain" | "beyond".
## Beyond zones (beyond_zone_at): deepForest -> rockyGround -> halfDugMine -> rareDeep by distance from the
## tunnel's far exit.

const WorldData := preload("res://scripts/world/world_data.gd")
const MASK := 0xFFFFFFFF

## Ground tile types. Same numbers as the web TD_TILE (and the seeded chunk generator's output).
enum Tile { GRASS = 0, BEYOND = 1, ROCK = 2, TUNNEL = 3, EDGE = 4, PATH = 5 }
const WALKABLE_TILES := [Tile.GRASS, Tile.BEYOND, Tile.TUNNEL, Tile.PATH]
const TILES_PER_UNIT := 4
## The legacy map is drawn out to this many units past the bounds (web TOPDOWN.EDGE_UNITS: -12..12).
const EDGE_UNITS := 2

static func T() -> Dictionary:
	return WorldData.terrain()

static func B() -> Dictionary:
	return WorldData.world()

## The numbers the point tests below need, read from the catalog once (they are asked for thousands of times
## per village layout and every physics step). Same values and comparisons as reading the catalog each time.
static var _cached := false
static var _min_x := 0.0
static var _max_x := 0.0
static var _min_y := 0.0
static var _max_y := 0.0
static var _face_y0 := PackedFloat64Array()
static var _face_y1 := PackedFloat64Array()
static var _face_x := PackedFloat64Array()
static var _tunnel_y := 0.0
static var _tunnel_half := 0.0
static var _tunnel_depth := 0.0
static var _range_width := 0.0
static var _margin := 0.0

static func _cache() -> void:
	var b := B()
	var t := T()
	_min_x = b.BOUNDS_MIN_X
	_max_x = b.BOUNDS_MAX_X
	_min_y = b.BOUNDS_MIN_Y
	_max_y = b.BOUNDS_MAX_Y
	for seg: Dictionary in t.FACE:
		_face_y0.append(seg.y0)
		_face_y1.append(seg.y1)
		_face_x.append(seg.x)
	_tunnel_y = t.TUNNEL.Y
	_tunnel_half = t.TUNNEL.HALF_WIDTH
	_tunnel_depth = t.TUNNEL.DEPTH
	_range_width = t.RANGE_WIDTH
	_margin = t.PLAYER_MARGIN
	_cached = true

static func in_bounds(x: float, y: float) -> bool:
	if not _cached:
		_cache()
	return x >= _min_x and x <= _max_x and y >= _min_y and y <= _max_y

## Face x of the solid rock at row y, ignoring the tunnel recess.
static func rock_face_x(y: float) -> float:
	if not _cached:
		_cache()
	for i in _face_x.size():
		if y >= _face_y0[i] and y < _face_y1[i]:
			return _face_x[i]
	return _face_x[_face_x.size() - 1]

static func in_tunnel_rows(y: float) -> bool:
	if not _cached:
		_cache()
	return absf(y - _tunnel_y) <= _tunnel_half

## Where walking stops at row y while the tunnel is closed: the rock face or the gate at the back of the recess.
static func face_x(y: float) -> float:
	var rock := rock_face_x(y)
	return rock - _tunnel_depth if in_tunnel_rows(y) else rock

static func tunnel(tunnel_open: bool) -> Dictionary:
	var t: Dictionary = T().TUNNEL
	var fx := rock_face_x(t.Y)
	return {"mouth_x": fx, "gate_x": fx - t.DEPTH, "y": float(t.Y), "half_width": float(t.HALF_WIDTH), "locked": not tunnel_open}

## West (back) edge of the range at row y: where "beyond" starts.
static func range_back_x(y: float) -> float:
	return rock_face_x(y) - _range_width

## The tunnel's far exit on the back edge of the range: the one way into "beyond".
static func tunnel_exit() -> Vector2:
	var y := float(T().TUNNEL.Y)
	return Vector2(range_back_x(y), y)

static func region_at(x: float, y: float) -> String:
	if is_nan(x) or is_nan(y) or is_inf(x) or is_inf(y) or not in_bounds(x, y):
		return "outside"
	var face := rock_face_x(y)
	if x >= face:
		return "open"
	if x >= range_back_x(y):
		return "tunnel" if in_tunnel_rows(y) else "mountain"
	return "beyond"

## Environment zone of a point beyond the range, "" elsewhere.
static func beyond_zone_at(x: float, y: float) -> String:
	if region_at(x, y) != "beyond":
		return ""
	var d := Vector2(x, y).distance_to(tunnel_exit())
	for z: Dictionary in T().BEYOND.ZONES:
		if d < z.maxDist:
			return z.key
	return ""

## Can the player stand at (x, y)? (web isWorldPointWalkable, terrain only, without obstacles.)
static func is_point_walkable(x: float, y: float, tunnel_open: bool) -> bool:
	if is_nan(x) or is_nan(y) or is_inf(x) or is_inf(y):
		return false
	if not in_bounds(x, y):
		return false
	var margin := _margin
	if x >= face_x(y) + margin:
		return true
	if not tunnel_open:
		return false
	if in_tunnel_rows(y):
		return true
	return x <= range_back_x(y) - margin

## May a new-game mine be generated on this cell? Clear of the rock and of the tunnel mouth.
static func is_cell_open_for_mines(x: float, y: float) -> bool:
	if not in_bounds(x, y):
		return false
	if x < rock_face_x(y) + T().MINE_MARGIN:
		return false
	var t := tunnel(false)
	return Vector2(x, y).distance_to(Vector2(t.mouth_x, t.y)) >= T().TUNNEL.KEEP_CLEAR

## May a beyond mine be generated on this cell? Beyond the range and clear of its back edge.
static func is_cell_open_for_beyond_mines(x: float, y: float) -> bool:
	if not in_bounds(x, y):
		return false
	if region_at(x, y) != "beyond":
		return false
	return x <= range_back_x(y) - T().MINE_MARGIN

## Moves from `from` toward `to` as far as `ok` allows (bisection), like terrainAdvance.
static func advance(from: float, to: float, ok: Callable) -> float:
	if ok.call(to):
		return to
	if not ok.call(from):
		return from
	var lo := 0.0
	var hi := 1.0
	for i in 12:
		var mid := (lo + hi) / 2.0
		if ok.call(from + (to - from) * mid):
			lo = mid
		else:
			hi = mid
	return from + (to - from) * lo

## Decorative peaks along the range: [{x, y, size, row}].
static func peaks(tunnel_open: bool) -> Array:
	var b := B()
	var out: Array = []
	var ty: float = T().TUNNEL.Y
	var y: float = b.BOUNDS_MIN_Y
	while y <= b.BOUNDS_MAX_Y:
		var face := rock_face_x(y)
		var wobble := sin(y * 1.7) * 0.5 + 0.5
		if not (absf(y - ty) < 1.6):
			out.append({"x": face - 0.7, "y": y, "size": 0.75 + wobble * 0.35, "row": "front"})
		var back_y := y + 0.5
		if not (tunnel_open and absf(back_y - ty) < 1.2):
			out.append({"x": face - 1.9, "y": back_y, "size": 1.0 + (1.0 - wobble) * 0.45, "row": "back"})
		y += 1.0
	return out

# --- ground tiles ---------------------------------------------------------------------------------------

static func _seg_dist(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	var l2 := dx * dx + dy * dy
	var t := clampf(((px - ax) * dx + (py - ay) * dy) / l2, 0.0, 1.0) if l2 != 0.0 else 0.0
	return Vector2(px, py).distance_to(Vector2(ax + t * dx, ay + t * dy))

## Ground tile at a world point (the tile's centre), web tdTileAt without the village layout.
## `base` is the workshop position (a yard and a dirt road to the tunnel mouth are drawn round it).
static func tile_at(x: float, y: float, tunnel_open: bool, base: Vector2, has_base: bool = true) -> int:
	if not in_bounds(x, y):
		return Tile.EDGE
	var region := region_at(x, y)
	if region == "mountain":
		return Tile.ROCK
	if region == "tunnel":
		if tunnel_open:
			return Tile.TUNNEL
		return Tile.TUNNEL if x >= tunnel(false).gate_x else Tile.ROCK
	if region == "beyond":
		return Tile.BEYOND
	if has_base:
		var t := tunnel(tunnel_open)
		if Vector2(x, y).distance_to(base) <= 1.05:
			return Tile.PATH
		if x >= t.mouth_x and _seg_dist(x, y, base.x, base.y, t.mouth_x, t.y) <= 0.3:
			return Tile.PATH
	return Tile.GRASS

# --- scenery beyond the range (Task 89) -----------------------------------------------------------------

static func _js_round(v: float) -> int:
	return int(floor(v + 0.5))

## The web's integer mix of a half-unit cell and a salt -> [0, 1).
static func _prop_hash(a: float, c: float, s: int) -> float:
	var h := (_js_round(a * 2.0) * 374761393 + _js_round(c * 2.0) * 668265263 + s * 2147483647) & MASK
	h = _imul(h ^ (h >> 13), 1274126177)
	h ^= h >> 16
	return float(h & MASK) / 4294967296.0

static func _imul(a: int, b: int) -> int:
	a &= MASK
	b &= MASK
	var lo := (a & 0xFFFF) * b
	var hi := ((a >> 16) * b) & 0xFFFF
	return (lo + (hi << 16)) & MASK

## The scenery of the land beyond, the same in every game: [{kind, x, y, zone, size, name}].
static func beyond_props() -> Array:
	var b := B()
	var cfg: Dictionary = T().BEYOND.PROPS
	var exit := tunnel_exit()
	var props: Array = []
	var counts := {}
	var step: float = cfg.STEP
	var y: float = b.BOUNDS_MIN_Y + 0.5
	while y <= b.BOUNDS_MAX_Y - 0.5:
		var x: float = b.BOUNDS_MIN_X + 0.4
		while x <= b.BOUNDS_MAX_X:
			_maybe_prop(props, counts, cfg, exit, x, y)
			x += step
		y += step
	return props

static func _maybe_prop(props: Array, counts: Dictionary, cfg: Dictionary, exit: Vector2, x: float, y: float) -> void:
	var b := B()
	if region_at(x, y) != "beyond":
		return
	var jx := x + (_prop_hash(x, y, 1) - 0.5) * 0.4
	var jy := y + (_prop_hash(x, y, 2) - 0.5) * 0.4
	if region_at(jx, jy) != "beyond" or (region_at(jx - 0.3, jy) != "beyond" and jx - 0.3 < b.BOUNDS_MIN_X):
		return
	if Vector2(jx, jy).distance_to(exit) < cfg.CLEAR_EXIT:
		return
	var zone := beyond_zone_at(jx, jy)
	if zone == "" or not cfg.has(zone):
		return
	var roll := _prop_hash(x, y, 3)
	var pick := ""
	for row: Dictionary in cfg[zone]:
		if roll < row.p:
			pick = row.kind
			break
		roll -= row.p
	if pick == "":
		return
	var cap: Dictionary = cfg.MAX
	if cap.has(pick) and int(counts.get(pick, 0)) >= int(cap[pick]):
		return
	counts[pick] = int(counts.get(pick, 0)) + 1
	var names: Dictionary = cfg.NAMES
	props.append({"kind": pick, "x": jx, "y": jy, "zone": zone, "size": 0.8 + _prop_hash(x, y, 4) * 0.5,
		"name": names.get(pick, "")})

## Task 111: the fixed scenery with nothing walled in. Solid pieces get a `box` (minX, maxX, minY, maxY);
## a solid piece that cuts reachable ground off from the tunnel exit is left out, as in the web game.
## Cached: the result never changes.
static func scenery_base() -> Array:
	const KEY := "mining_world_scenery_base"
	if Engine.has_meta(KEY):
		return Engine.get_meta(KEY)
	var boxes := WorldData.scenery_boxes()
	var all: Array = []
	for pr: Dictionary in beyond_props():
		var p := pr.duplicate()
		var bx: Variant = boxes.get(pr.kind)
		p.box = null if bx == null else {"minX": pr.x + bx.minX, "maxX": pr.x + bx.maxX, "minY": pr.y + bx.minY, "maxY": pr.y + bx.maxY}
		all.append(p)
	var foot := WorldData.player_foot()
	var hw: float = foot.HALF_W
	var hh: float = foot.HALF_H
	var b := B()
	var st := WorldData.scenery_fill_step()
	var x0: float = b.BOUNDS_MIN_X
	var y0: float = b.BOUNDS_MIN_Y
	var exit := tunnel_exit()
	var x1 := exit.x + 0.5
	var nx := int(floor((x1 - x0) / st)) + 1
	var ny := int(floor((b.BOUNDS_MAX_Y - y0) / st)) + 1
	var n := nx * ny
	var walk := PackedByteArray()
	walk.resize(n)
	for j in ny:
		for i in nx:
			walk[j * nx + i] = 1 if is_point_walkable(x0 + i * st, y0 + j * st, true) else 0
	var solid: Array = all.filter(func(p: Dictionary) -> bool: return p.box != null)
	var guard := 0
	while true:
		var blocked := PackedInt32Array()
		blocked.resize(n)
		for k in solid.size():
			var bx: Dictionary = solid[k].box
			var i0 := maxi(0, int(floor((bx.minX - hw - x0) / st)))
			var i1 := mini(nx - 1, int(ceil((bx.maxX + hw - x0) / st)))
			var j0 := maxi(0, int(floor((bx.minY - hh - y0) / st)))
			var j1 := mini(ny - 1, int(ceil((bx.maxY + hh - y0) / st)))
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					var px := x0 + i * st
					var py := y0 + j * st
					if px + hw > bx.minX and px - hw < bx.maxX and py + hh > bx.minY and py - hh < bx.maxY:
						blocked[j * nx + i] = k + 1
		var seen := PackedByteArray()
		seen.resize(n)
		var start := _js_round((exit.y - y0) / st) * nx + _js_round((exit.x - 0.3 - x0) / st)
		var q: Array[int] = [start]
		seen[start] = 1
		while not q.is_empty():
			var c: int = q.pop_back()
			var ci := c % nx
			for d in [c - 1 if ci > 0 else -1, c + 1 if ci < nx - 1 else -1, c - nx, c + nx]:
				if d >= 0 and d < n and seen[d] == 0 and walk[d] == 1 and blocked[d] == 0:
					seen[d] = 1
					q.append(d)
		var score := {}
		var order_keys: Array[int] = []
		for c in n:
			if walk[c] == 0 or blocked[c] != 0 or seen[c] == 1:
				continue
			var ci := c % nx
			for d in [c - 1 if ci > 0 else -1, c + 1 if ci < nx - 1 else -1, c - nx, c + nx]:
				if d >= 0 and d < n and blocked[d] != 0:
					var k := blocked[d] - 1
					if not score.has(k):
						order_keys.append(k)
					score[k] = int(score.get(k, 0)) + 1
		if score.is_empty() or guard > 200:
			break
		guard += 1
		# stable sort by count, descending (ties keep first-seen order, like JS Array.sort)
		var ranked: Array = []
		for idx in order_keys.size():
			ranked.append([order_keys[idx], score[order_keys[idx]], idx])
		ranked.sort_custom(func(a: Array, c: Array) -> bool: return a[1] > c[1] or (a[1] == c[1] and a[2] < c[2]))
		var drop := -1
		for r: Array in ranked:
			if _touches_reached(solid[r[0]].box, seen, nx, ny, x0, y0, st, hw, hh):
				drop = r[0]
				break
		if drop < 0:
			drop = ranked[0][0]
		solid.remove_at(drop)
	var kept: Array = all.filter(func(p: Dictionary) -> bool: return p.box == null or solid.has(p))
	Engine.set_meta(KEY, kept)
	return kept

static func _touches_reached(bx: Dictionary, seen: PackedByteArray, nx: int, ny: int, x0: float, y0: float, st: float, hw: float, hh: float) -> bool:
	var x: float = bx.minX - hw - st
	while x <= bx.maxX + hw + st:
		var y: float = bx.minY - hh - st
		while y <= bx.maxY + hh + st:
			var i := _js_round((x - x0) / st)
			var j := _js_round((y - y0) / st)
			if i >= 0 and j >= 0 and i < nx and j < ny and seen[j * nx + i] == 1:
				return true
			y += st
		x += st
	return false

## The scenery of a game: the fixed pieces minus those standing on a mine (web worldSceneryLegacy).
static func scenery_for(mines: Array) -> Array:
	var clear := WorldData.scenery_mine_clear()
	var out: Array = []
	for pr: Dictionary in scenery_base():
		var free := true
		for m: Dictionary in mines:
			if Vector2(m.x, m.y).distance_to(Vector2(pr.x, pr.y)) < clear:
				free = false
				break
		if free:
			out.append(pr)
	return out
