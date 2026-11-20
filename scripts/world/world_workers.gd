extends Node2D
## The hired workers in the world (web js/topdown/workers.js @ 7484ccd). Each stands by a vein of the resource it
## is assigned to (secured veins first, nearest the base first) and swings a pickaxe; a worker without such a
## vein waits in the workshop yard. When the game opens or a worker is hired or moved, it walks there out of
## the workshop door, through the tunnel when the vein is beyond the mountain, round anything in its way (a side
## step, then for a moment ignoring obstacles but never the rock). Drawing only: none of it is saved, and the
## workers' output (autoRate) does not depend on it.

const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const Layout := preload("res://scripts/village_layout.gd")

const UNIT := 64.0
const SHIRT := {"common": Color("7d8a5c"), "rare": Color("4d7fd0"), "epic": Color("9a62d8"), "legend": Color("e0a83c")}
const HELMET := [Color("e2b23c"), Color("d0703a"), Color("c9ccd0"), Color("6aa0c8")]
const HAIR := [Color("5a3b28"), Color("2b2b2b"), Color("8a5a2b"), Color("c9a26a")]
const SKIN := [Color("f0c8a0"), Color("d9a982"), Color("b98a62")]
## spots round a vein (world units from its point), tried in order
const SLOTS := [[0.42, 0.08], [-0.42, 0.08], [0.5, 0.48], [-0.5, 0.48], [0.5, -0.32], [-0.5, -0.32], [0, 0.5],
	[0.85, 0.2], [-0.85, 0.2], [0.85, -0.25], [-0.85, -0.25], [0.35, 0.85], [-0.35, 0.85]]
## where workers without a vein of their resource wait: the workshop yard
const YARD := [[-0.6, 0.55], [0.6, 0.55], [-1.0, 0.3], [1.0, 0.3], [-0.25, 0.9], [0.25, 0.9], [-0.95, 0.85], [0.95, 0.85],
	[-1.35, 0.6], [1.35, 0.6], [0, 1.3], [-0.6, 1.3], [0.6, 1.3]]
const MIN_GAP := 0.34
const WALK_SPEED := 1.6
const SUB_STEP := 0.08
const START_GAP_MS := 450.0
const STUCK_MS := 900.0
const PROGRESS := 0.04
const DETOUR := 0.45
const GHOST_MS := 1400.0
const MAX_GHOSTS := 3
const LANE := 0.28
const RANK := {"common": 0, "rare": 1, "epic": 2, "legend": 3}

var economy: Node
var world: RefCounted
var _key := ""
var _placements: Array = []
var _index: Layout.Index
var _sim := {}


func setup(game_economy: Node, world_state: RefCounted) -> void:
	economy = game_economy
	world = world_state


## web tdWorkerHash: FNV-1a over the id's characters, salted, to 0..1.
static func worker_hash(id: String, salt := 0) -> float:
	var h := (2166136261 ^ salt) & 0xffffffff
	for i in id.length():
		h ^= id.unicode_at(i)
		h = (h * 16777619) & 0xffffffff
	return float(h % 100000) / 100000.0


## Where every worker works or waits (web tdComputeWorkerPlacements):
## [{id, x, y, mine_id ("" in the yard), resource, dir, rarity, phase, cycle_ms}].
static func placements(world_state: RefCounted, village: Dictionary, characters: Array) -> Array:
	var out: Array = []
	var taken: Array = []
	var index := Layout.Index.new(Layout.obstacles(world_state, village))
	var base: Vector2i = world_state.base
	var free := func(x: float, y: float) -> bool:
		if not Layout.can_stand(index, world_state.tunnel_unlocked, x, y):
			return false
		for t: Vector2 in taken:
			if Vector2(x, y).distance_to(t) < MIN_GAP:
				return false
		return true
	var groups := {}
	for c: Dictionary in characters:
		if not groups.has(c.resource):
			groups[c.resource] = []
		groups[c.resource].append(c)
	var keys: Array = groups.keys()
	keys.sort()
	for res: String in keys:
		var discovered: Array = world_state.mines.filter(func(m: Dictionary) -> bool: return m.resource == res and world_state.is_discovered(m))
		var secured: Array = discovered.filter(func(m: Dictionary) -> bool: return m.developmentState == "secured")
		var cands: Array = (secured if not secured.is_empty() else discovered).duplicate()
		cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var da := Vector2(a.x - base.x, a.y - base.y).length()
			var db := Vector2(b.x - base.x, b.y - base.y).length()
			return da < db if da != db else str(a.id) < str(b.id))
		var k := 0
		for c: Dictionary in groups[res]:
			var spot := {}
			if not cands.is_empty():
				var mine: Dictionary = cands[k % cands.size()]
				var first := k / cands.size()
				for i in SLOTS.size():
					var slot: Array = SLOTS[(first + i) % SLOTS.size()]
					if free.call(mine.x + slot[0], mine.y + slot[1]):
						spot = {"x": mine.x + slot[0], "y": mine.y + slot[1], "mine": mine}
						break
			if spot.is_empty():
				for slot: Array in YARD:
					if free.call(base.x + slot[0], base.y + slot[1]):
						spot = {"x": base.x + slot[0], "y": base.y + slot[1], "mine": {}}
						break
			if spot.is_empty():
				spot = {"x": float(base.x), "y": base.y + 1.1 + out.size() * 0.05, "mine": {}}
			taken.append(Vector2(spot.x, spot.y))
			var mine: Dictionary = spot.mine
			var dir := ("left" if spot.x > mine.x else "right") if not mine.is_empty() else ("left" if worker_hash(str(c.id), 4) < 0.5 else "right")
			out.append({"id": str(c.id), "x": float(spot.x), "y": float(spot.y), "mine_id": str(mine.get("id", "")), "resource": res, "dir": dir,
				"rarity": str(c.get("rarity", "common")), "phase": worker_hash(str(c.id), 5), "cycle_ms": 1100.0 - 90.0 * RANK.get(c.get("rarity"), 0)})
			k += 1
	return out


func _current() -> Array:
	var village: Dictionary = economy.state.village
	var key := JSON.stringify([economy.state.characters.map(func(c: Dictionary) -> String: return "%s:%s:%s" % [c.id, c.resource, c.get("rarity")]),
		world.mines.map(func(m: Dictionary) -> String: return "%s:%s:%s:%s" % [m.id, m.x, m.y, m.developmentState + str(world.is_discovered(m))]),
		world.workshops.map(func(w: Dictionary) -> Array: return [w.x, w.y]), village.get("sites"), village.get("district"), world.tunnel_unlocked])
	if key != _key:
		_key = key
		_placements = placements(world, village, economy.state.characters)
		_index = Layout.Index.new(Layout.obstacles(world, village))
	return _placements


# --- walking ---------------------------------------------------------------------------------------------------

## Which side of the mountain a point is on (web tdWorkerSide): "east" (the open land) or "west" (beyond).
func _side(x: float, y: float) -> String:
	var r := WorldTerrain.region_at(x, y)
	if r == "beyond":
		return "west"
	if r == "tunnel" or r == "mountain":
		return "west" if x < (WorldTerrain.tunnel(true).mouth_x + WorldTerrain.tunnel_exit().x) / 2.0 else "east"
	return "east"


## The waypoints there: straight on the same side of the mountain, else through the tunnel on the worker's lane.
func _route(fx: float, fy: float, tx: float, ty: float, lane: float) -> Array:
	var goal := Vector2(tx, ty)
	var a := _side(fx, fy)
	var b := _side(tx, ty)
	if a == b or not world.tunnel_unlocked:
		return [goal]
	var t := WorldTerrain.tunnel(true)
	var e := WorldTerrain.tunnel_exit()
	var mouth := Vector2(t.mouth_x + 0.6, t.y + lane)
	var exit := Vector2(e.x - 0.6, t.y + lane)
	var in_tunnel := WorldTerrain.region_at(fx, fy) == "tunnel"
	if a == "east":
		return ([] if in_tunnel else [mouth]) + [exit, goal]
	return ([] if in_tunnel else [exit]) + [mouth, goal]


func _ok(at: Vector2, ghost: bool) -> bool:
	if not WorldTerrain.is_point_walkable(at.x, at.y, world.tunnel_unlocked):
		return false
	return ghost or not _index.blocks(at.x, at.y)


func _process(delta: float) -> void:
	if economy == null or world == null:
		return
	var places := _current()
	var base: Vector2i = world.base
	var ids := {}
	var newcomers := 0
	var dt := minf(delta, 0.25) * 1000.0
	for p: Dictionary in places:
		ids[p.id] = true
		var s: Dictionary = _sim.get(p.id, {})
		if s.is_empty():
			s = {"x": base.x + (worker_hash(p.id, 7) - 0.5) * 0.2, "y": base.y + 0.08, "mode": "walk", "dir": p.dir,
				"delay": newcomers * START_GAP_MS, "walked": 0.0, "goal": "", "route": [], "lane": (worker_hash(p.id, 8) * 2.0 - 1.0) * LANE,
				"best": INF, "stuck": 0.0, "detours": 0, "ghost": 0.0, "ghosts": 0, "hidden": true}
			newcomers += 1
			_sim[p.id] = s
		var goal := "%s,%s" % [p.x, p.y]
		if s.goal != goal:
			s.goal = goal
			s.route = _route(s.x, s.y, p.x, p.y, s.lane)
			s.mode = "walk"
			s.best = INF
			s.stuck = 0.0
			s.detours = 0
			s.ghosts = 0
		if s.delay > 0.0:
			s.delay -= dt
			continue
		s.hidden = false
		if s.mode != "walk":
			continue
		_walk(s, dt)
		if s.route.is_empty():
			s.mode = "work" if not str(p.mine_id).is_empty() else "wait"
			s.dir = p.dir
			s.x = p.x
			s.y = p.y
	for id: String in _sim.keys():
		if not ids.has(id):
			_sim.erase(id)
	queue_redraw()


func _walk(s: Dictionary, dt: float) -> void:
	var budget := WALK_SPEED * dt / 1000.0
	var guard := 0
	while budget > 1e-6 and not s.route.is_empty() and guard < 40:
		guard += 1
		var wp: Vector2 = s.route[0]
		var at := Vector2(s.x, s.y)
		var d := at.distance_to(wp)
		if d < 0.02:
			s.route.pop_front()
			s.best = INF
			s.stuck = 0.0
			continue
		var length := minf(minf(budget, SUB_STEP), d)
		var u := (wp - at) / d
		var ghost: bool = s.ghost > 0.0
		# x and y separately, each as far as it is free (the player's walk)
		var nx := at.x + u.x * length
		var x := nx if _ok(Vector2(nx, at.y), ghost) else at.x
		var ny := at.y + u.y * length
		var y := ny if _ok(Vector2(x, ny), ghost) else at.y
		var moved := Vector2(x, y).distance_to(at)
		s.x = x
		s.y = y
		s.walked += moved
		budget -= length
		if absf(u.x) > 0.3:
			s.dir = "right" if u.x > 0.0 else "left"
		if moved < length * 0.3:
			break
	if s.route.is_empty():
		return
	var wp: Vector2 = s.route[0]
	var dist := Vector2(s.x, s.y).distance_to(wp)
	if dist < s.best - PROGRESS:
		s.best = dist
		s.stuck = 0.0
	else:
		s.stuck += dt
	if s.ghost > 0.0:
		s.ghost -= dt
	if s.stuck < STUCK_MS:
		return
	s.stuck = 0.0
	s.best = INF
	if s.detours < 2 and s.ghost <= 0.0:
		var det := _detour(s, wp)
		if det != Vector2.INF:
			s.detours += 1
			s.route.push_front(det)
			return
	if s.ghosts < MAX_GHOSTS:
		s.ghosts += 1
		s.ghost = GHOST_MS
		return
	s.x = wp.x
	s.y = wp.y


func _detour(s: Dictionary, wp: Vector2) -> Vector2:
	var at := Vector2(s.x, s.y)
	var d := maxf(at.distance_to(wp), 1e-6)
	var u := (wp - at) / d
	var side := 1.0 if worker_hash(str(s.get("id", "")), 6) < 0.5 else -1.0
	for k: float in [1.0, 1.6, 0.6]:
		for sgn: float in [side, -side]:
			var c := Vector2(at.x - u.y * sgn * DETOUR * k + u.x * 0.15, at.y + u.x * sgn * DETOUR * k + u.y * 0.15)
			if _ok(c, false):
				return c
	return Vector2.INF


# --- drawing ---------------------------------------------------------------------------------------------------

func _draw() -> void:
	var now := Time.get_ticks_msec()
	for p: Dictionary in _placements:
		var s: Dictionary = _sim.get(p.id, {})
		if s.is_empty() or s.hidden:
			continue
		var at := Vector2(s.x, s.y) * UNIT
		var flip := -1.0 if s.dir == "left" else 1.0
		var shirt: Color = SHIRT.get(p.rarity, SHIRT.common)
		var helmet: Color = HELMET[int(worker_hash(p.id, 1) * HELMET.size()) % HELMET.size()]
		var skin: Color = SKIN[int(worker_hash(p.id, 3) * SKIN.size()) % SKIN.size()]
		var metal := Color("e8c050") if p.rarity == "legend" else Color("9aa0a8")
		draw_rect(Rect2(at + Vector2(-5, -2), Vector2(10, 2)), Color(0, 0, 0, 0.25))
		var bob := 0.0
		if s.mode == "walk":
			bob = -1.0 if int(s.walked / 0.11) % 2 == 1 else 0.0
		draw_rect(Rect2(at + Vector2(-3, -7 + bob), Vector2(2, 5)), Color("3d4049"))
		draw_rect(Rect2(at + Vector2(1, -7 + bob), Vector2(2, 5)), Color("4a4e58"))
		draw_rect(Rect2(at + Vector2(-4, -14 + bob), Vector2(8, 7)), shirt)
		draw_rect(Rect2(at + Vector2(-3, -20 + bob), Vector2(7, 6)), skin)
		draw_rect(Rect2(at + Vector2(-4, -22 + bob), Vector2(9, 3)), helmet)
		if s.mode == "work":
			# web tdWorkerFrame: raise, overhead, strike, recover
			var frame := int((now / float(p.cycle_ms) + float(p.phase)) * 4.0) % 4
			var angle: float = [-0.6, -1.4, 0.5, 0.0][frame]
			var hand := at + Vector2(3 * flip, -12)
			var tip := hand + Vector2(cos(angle) * flip, sin(angle)) * 9.0
			draw_line(hand, tip, Color("8a6440"), 1.5)
			draw_line(tip + Vector2(-3, 1).rotated(angle) * Vector2(flip, 1), tip + Vector2(3, -1).rotated(angle) * Vector2(flip, 1), metal, 2.0)
		else:
			draw_line(at + Vector2(2 * flip, -10 + bob), at + Vector2(-4 * flip, -18 + bob), Color("8a6440"), 1.5)
			draw_rect(Rect2(at + Vector2(-6 * flip - 1, -20 + bob), Vector2(2, 4)), metal)
