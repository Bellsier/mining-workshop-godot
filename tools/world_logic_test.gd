extends SceneTree
## Headless parity test for the world port: every value is compared with the ORIGINAL web code's output
## (tests/world/web_world_fixtures.json, made by tools/world/make_web_fixtures.cjs from the web source).
##   godot --headless --path . --script res://tools/world_logic_test.gd
## Prints "WORLD LOGIC PASS" and exits 0, or lists the mismatches and exits 1.

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldRandom := preload("res://scripts/world/world_random.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const WorldGen := preload("res://scripts/world/world_gen.gd")
const ChunkGen := preload("res://scripts/world/chunk_gen.gd")
const WorldState := preload("res://scripts/world/world_state.gd")

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)
		printerr("WORLD FAIL ", what)

func _same_text(got: String, want: String, what: String) -> void:
	if got == want:
		_expect(true, what)
		return
	var i := 0
	while i < mini(got.length(), want.length()) and got[i] == want[i]:
		i += 1
	_expect(false, "%s differs at %d (got '%s' want '%s', lengths %d/%d)" % [what, i, got.substr(i, 12), want.substr(i, 12), got.length(), want.length()])

func _near(a: float, b: float, what: String, eps: float = 1e-6) -> void:
	_expect(absf(a - b) <= eps, "%s: %s != %s" % [what, a, b])

func _pack(mines: Array) -> String:
	var parts: PackedStringArray = []
	for m: Dictionary in mines:
		parts.append("%s@%d,%d:%s/%d" % [m.id, int(m.x), int(m.y), m.resource, int(m.grade)])
	return " ".join(parts)

func _pack_fixture(rows: Array) -> String:
	var parts: PackedStringArray = []
	for r: Array in rows:
		parts.append("%s@%d,%d:%s/%d" % [r[0], int(r[1]), int(r[2]), r[3], int(r[4])])
	return " ".join(parts)

func _run() -> void:
	var fx: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/world/web_world_fixtures.json"))
	_expect(not WorldData.catalog().is_empty(), "catalog loads")
	_expect(is_inf(WorldData.world_gen().RINGS[3].maxDist), "infinity restored in the catalog")

	var rng := WorldRandom.new(7)
	for v: float in fx.mulberry32_seed7:
		_near(rng.next_float(), v, "mulberry32", 1e-15)

	_terrain(fx.terrain)
	_scenery(fx)
	_layouts(fx.worlds)
	_chunks(fx)
	_state(fx.worlds[0])

	for line in _failures.slice(0, 20):
		print("WORLD ", line)
	if _failures.is_empty():
		print("WORLD LOGIC PASS (%d checks)" % _checks)
		quit(0)
	else:
		print("WORLD LOGIC FAIL %d of %d checks" % [_failures.size(), _checks])
		quit(1)

func _terrain(t: Dictionary) -> void:
	var code := {"outside": "x", "open": "o", "tunnel": "t", "mountain": "m", "beyond": "b"}
	var zcode := {"deepForest": "f", "rockyGround": "r", "halfDugMine": "h", "rareDeep": "d"}
	var regions := ""
	var zones := ""
	var walk_open := ""
	var walk_closed := ""
	for ty in range(-48, 48):
		for tx in range(-48, 48):
			var x := (tx + 0.5) / 4.0
			var y := (ty + 0.5) / 4.0
			regions += code[WorldTerrain.region_at(x, y)]
			var z := WorldTerrain.beyond_zone_at(x, y)
			zones += zcode[z] if z != "" else "."
			walk_open += "1" if WorldTerrain.is_point_walkable(x, y, true) else "0"
			walk_closed += "1" if WorldTerrain.is_point_walkable(x, y, false) else "0"
	_same_text(regions, t.regions, "regions")
	_same_text(zones, t.zones, "beyond zones")
	_same_text(walk_open, t.walk_open, "walkable, tunnel open")
	_same_text(walk_closed, t.walk_closed, "walkable, tunnel closed")
	for open in [false, true]:
		var tiles := ""
		for ty in range(-48, 48):
			for tx in range(-48, 48):
				tiles += str(WorldTerrain.tile_at((tx + 0.5) / 4.0, (ty + 0.5) / 4.0, open, Vector2(2, 0)))
		_same_text(tiles, t.tiles_open if open else t.tiles_closed, "ground tiles, tunnel %s" % ("open" if open else "closed"))
	var tc := WorldTerrain.tunnel(false)
	_near(tc.mouth_x, t.tunnel_closed.mouthX, "tunnel mouth")
	_near(tc.gate_x, t.tunnel_closed.gateX, "tunnel gate")
	_expect(tc.locked == true and WorldTerrain.tunnel(true).locked == false, "tunnel lock flag")
	var exit := WorldTerrain.tunnel_exit()
	_near(exit.x, t.exit.x, "tunnel exit x")
	_near(exit.y, t.exit.y, "tunnel exit y")
	var mine_cells := ""
	var beyond_cells := ""
	for y in range(-10, 11):
		for x in range(-10, 11):
			mine_cells += "1" if WorldTerrain.is_cell_open_for_mines(x, y) else "0"
			beyond_cells += "1" if WorldTerrain.is_cell_open_for_beyond_mines(x, y) else "0"
	_same_text(mine_cells, t.cells_open_for_mines, "cells open for mines")
	_same_text(beyond_cells, t.cells_open_for_beyond_mines, "cells open for beyond mines")
	for open in [false, true]:
		var got := WorldTerrain.peaks(open)
		var want: Array = t.peaks_open if open else t.peaks_closed
		_expect(got.size() == want.size(), "peak count (open %s)" % open)
		for i in mini(got.size(), want.size()):
			_near(got[i].x, want[i][0], "peak %d x" % i)
			_near(got[i].y, want[i][1], "peak %d y" % i)
			_near(got[i].size, want[i][2], "peak %d size" % i)

func _scenery(fx: Dictionary) -> void:
	var props := WorldTerrain.beyond_props()
	var want: Array = fx.beyond_props
	_expect(props.size() == want.size(), "beyond props: %d vs %d" % [props.size(), want.size()])
	for i in mini(props.size(), want.size()):
		var p: Dictionary = props[i]
		_expect(p.kind == want[i][0] and p.zone == want[i][3], "prop %d kind/zone %s/%s" % [i, p.kind, p.zone])
		_near(p.x, want[i][1], "prop %d x" % i)
		_near(p.y, want[i][2], "prop %d y" % i)
		_near(p.size, want[i][4], "prop %d size" % i)
	var kept := WorldTerrain.scenery_base()
	_expect(kept.size() == fx.scenery_kept.size(), "kept scenery %d vs %d" % [kept.size(), fx.scenery_kept.size()])

func _layouts(worlds: Array) -> void:
	for w: Dictionary in worlds:
		var rng := WorldRandom.new(int(w.seed))
		var src := rng.source()
		var base := Vector2i(2, 0)
		var initial := WorldGen.generate_initial_mines(base, src)
		_same_text(_pack(initial), _pack_fixture(w.initial), "new-game veins, seed %d" % int(w.seed))
		var beyond := WorldGen.generate_beyond_mines(initial, src)
		_same_text(_pack(beyond), _pack_fixture(w.beyond), "beyond veins, seed %d" % int(w.seed))
		var all := initial + beyond
		var survey := WorldGen.survey_mines(all, base, src)
		_same_text(_pack(survey), _pack_fixture(w.survey), "survey veins, seed %d" % int(w.seed))

func _chunks(fx: Dictionary) -> void:
	for row: Array in fx.chunk_hash:
		_expect(ChunkGen.chunk_hash(int(row[0]), int(row[1]), int(row[2]), int(row[3])) == int(row[4]), "chunk hash %s" % [row])
	for row: Array in fx.chunk_noise:
		_expect(ChunkGen.noise(int(row[0]), int(row[1]), int(row[2])) == int(row[3]), "chunk noise %s" % [row])
	for c: Dictionary in fx.chunks:
		var ctx := {"seed": int(c.seed), "generatorVersion": int(c.version)}
		var what := "chunk seed %d v%d (%d,%d)" % [int(c.seed), int(c.version), int(c.cx), int(c.cy)]
		var got := ChunkGen.generate_chunk(ctx, int(c.cx), int(c.cy))
		var tiles := ""
		for v in got.tiles:
			tiles += str(v)
		_same_text(tiles, c.tiles, what + " tiles")
		var mines := ""
		for m: Dictionary in got.mines:
			mines += "%s@%d,%d:%s " % [m.id, int(m.x), int(m.y), m.resource]
		var want_mines := ""
		for m: Array in c.mines:
			want_mines += "%s@%d,%d:%s " % [m[0], int(m[1]), int(m[2]), m[3]]
		_same_text(mines, want_mines, what + " veins")
		_expect(got.props.size() == c.props.size(), what + " prop count %d vs %d" % [got.props.size(), c.props.size()])
		for i in mini(got.props.size(), c.props.size()):
			var p: Dictionary = got.props[i]
			_expect(p.id == c.props[i][0] and p.kind == c.props[i][1], what + " prop %d" % i)
			_near(p.x, c.props[i][2], what + " prop x")
			_near(p.size, c.props[i][4], what + " prop size")

func _state(w: Dictionary) -> void:
	var s: RefCounted = WorldState.new_game(int(w.seed))
	_same_text(_pack(s.mines), _pack_fixture(w.initial), "state new game")
	_expect(s.hidden_ids.size() == s.mines.size() - 2 and not s.hidden_ids.has("mine_start_iron"), "only the starters are discovered")
	_expect(s.place_at(Vector2(2, 0)).region == "open" and s.place_at(Vector2(-8, 1)).label.begins_with("산 너머"), "place labels")
	var added: Array = s.unlock_tunnel()
	_same_text(_pack(added), _pack_fixture(w.beyond), "state tunnel opening")
	_expect(s.tunnel_unlocked and s.unlock_tunnel().is_empty(), "the tunnel opens once")
	var exit := WorldTerrain.tunnel_exit()
	var found: Array = s.explore(exit + Vector2(-1.5, 0))
	_expect(not found.is_empty(), "walking beyond the exit discovers a vein")
	for m: Dictionary in found:
		_expect(str(m.id).begins_with("mine_beyond_"), "found %s beyond" % m.id)
	var copy: RefCounted = WorldState.from_dict(JSON.parse_string(JSON.stringify(s.to_dict())))
	_same_text(_pack(copy.mines), _pack(s.mines), "save round trip veins")
	_expect(copy.hidden_ids == s.hidden_ids and copy.tunnel_unlocked, "save round trip hidden list and tunnel")
	# seeded outer world: the connector and generated chunks
	var seeded: RefCounted = WorldState.new_game(5, true, 12345)
	_expect(seeded.tile_type(4 * 12, 0) == WorldTerrain.Tile.GRASS, "seeded connector is open ground")
	var before: int = seeded.mines.size()
	seeded.ensure_area(Rect2(14, -4, 8, 8))
	_expect(seeded.mines.size() > before, "seeded chunks bring their veins")
	var kept_mines: Array = seeded.to_dict().mines
	_expect(kept_mines.size() == before, "generated veins are not saved")
