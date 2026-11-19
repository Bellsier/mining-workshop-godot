extends SceneTree
## The village layout against the web original (gacha-factory-development 7484ccd):
##   godot --headless --path . --script res://tools/village_layout_test.gd
## Expected values come from the original JS, run by tools/parity/make_village_fixtures.cjs, on new-game worlds
## from the same seeded generator: the appraiser's and museum's sites, the plaza district, the roads point for
## point, the garden cells, which points count as village ground, and where new craft huts go next to it.
## Also times the layout (it runs once per game, at the first load).
## Prints "VILLAGE LAYOUT PASS" and exits 0, or lists the failures and exits 1.

const World = preload("res://scripts/world/world_state.gd")
const Layout = preload("res://scripts/village_layout.gd")
const CraftHuts = preload("res://scripts/craft_huts.gd")
const ExactJson = preload("res://scripts/exact_json.gd")
const WEB := "res://tests/fixtures/village_web_fixtures.json"

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("VILLAGE LAYOUT FAIL ", what)


func _run() -> void:
	var web: Dictionary = ExactJson.parse(FileAccess.get_file_as_string(WEB)).value
	_check(str(web.source.commit).begins_with("7484ccd"), "the fixture comes from the web original 7484ccd")
	var slowest := 0.0
	for case: Dictionary in web.cases:
		var label := "seed %d%s" % [int(case.seed), " (huts, torch, tunnel open)" if case.tunnel else ""]
		var world: RefCounted = World.new_game(int(case.seed))
		var mines: Array = []
		for m: Dictionary in world.mines:
			mines.append([m.id, int(m.x), int(m.y), m.resource])
		var expected_mines: Array = []
		for m: Dictionary in case.mines:
			expected_mines.append([m.id, int(m.x), int(m.y), m.resource])
		_check(mines == expected_mines, "%s: the new-game veins equal the web's" % label)
		for i in case.huts.size():
			world.workshops.append({"id": "workshop_h%d" % i, "x": int(case.huts[i].x), "y": int(case.huts[i].y), "level": 1,
				"recipeKey": null, "auto": false, "progress": null})
		for t: Dictionary in case.torches:
			world.torches.append({"x": float(t.x), "y": float(t.y)})
		world.tunnel_unlocked = bool(case.tunnel)
		var village := {"sites": {}, "district": null, "decor": []}
		var started := Time.get_ticks_usec()
		var ok := Layout.ensure_sites(world, village)
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		slowest = maxf(slowest, ms)
		print("village layout %s: %.0f ms" % [label, ms])
		_check(ok == bool(case.ok), "%s: sites found like the web" % label)
		for key: String in case.sites:
			var s: Variant = village.sites.get(key)
			var e: Variant = case.sites[key]
			_check(s is Dictionary and e is Dictionary and float(s.x) == float(e.x) and float(s.y) == float(e.y),
				"%s: %s site %s, web %s" % [label, key, s, e])
		var d: Variant = village.district
		var ed: Variant = case.district
		_check(d is Dictionary and ed is Dictionary and float(d.x) == float(ed.x) and float(d.y) == float(ed.y) and int(d.layout) == int(ed.layout),
			"%s: district %s, web %s" % [label, d, ed])
		village.decor = case.decor.duplicate(true)
		var roads := Layout.roads(world, village)
		var got: Array = []
		for r: Dictionary in roads:
			got.append({"to": r.to, "points": r.points.map(func(p: Dictionary) -> Array: return [float(p.x), float(p.y)])})
		var want: Array = []
		for r: Dictionary in case.roads:
			want.append({"to": r.to, "points": r.points.map(func(p: Array) -> Array: return [float(p[0]), float(p[1])])})
		_check(got == want, "%s: roads\n   godot %s\n   web   %s" % [label, got, want])
		var cells: Array = Layout.garden_cells(village).map(func(c: Dictionary) -> Array: return [float(c.cell), float(c.x), float(c.y)])
		var want_cells: Array = case.garden.map(func(c: Array) -> Array: return [float(c[0]), float(c[1]), float(c[2])])
		_check(cells == want_cells, "%s: garden cells" % label)
		for n: Array in case.near:
			var ground := Layout.ground_near(world, village, roads, float(n[0]), float(n[1]), 0.7)
			var site := Layout.site_near(village, float(n[0]), float(n[1]), 1.6)
			_check(ground == bool(n[2]) and site == bool(n[3]), "%s: (%s, %s) village ground %s/%s, web %s/%s" % [label, n[0], n[1], ground, site, n[2], n[3]])
		# Craft huts built next to the village keep clear of it (web workshopBuildSpot).
		var built: Array = []
		for i in case.built.size():
			var spot: Variant = CraftHuts.build_spot(world.base, world.mines, world.workshops, false, false, world, village)
			if spot == null:
				built.append(null)
				continue
			world.workshops.append({"id": "workshop_b%d" % i, "x": spot.x, "y": spot.y, "level": 1, "recipeKey": null, "auto": false, "progress": null})
			built.append([float(spot.x), float(spot.y)])
		var want_built: Array = case.built.map(func(b: Variant) -> Variant: return null if b == null else [float(b[0]), float(b[1])])
		_check(built == want_built, "%s: new huts at %s, web %s" % [label, built, want_built])
	_check(slowest < 15000.0, "the layout takes %.0f ms at most (budget 15 s, once per game)" % slowest)
	if _failures.is_empty():
		print("VILLAGE LAYOUT PASS")
		quit(0)
	else:
		print("VILLAGE LAYOUT FAIL %d" % _failures.size())
		quit(1)
