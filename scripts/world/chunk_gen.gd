extends RefCounted
## The seeded world generator, ported from the web game's js/chunkgen.js ("generator v1/v2", the 256 x 256
## tile test world of WORLD_EXPANSION_2048). Pure functions of (seed, generator version, absolute tile):
## nothing here is saved. A chunk is 32 x 32 quarter-unit tiles (8 world units).
##   tiles: 0 open ground, 2 rock (thicket), 4 edge (impassable border / the legacy map's place)
##   mines: generated veins round the outer ring (iron / coal), ids "gen:v<version>:mine:<gx>:<gy>"
##   props: scenery (grass, rock, sparseTree) on open ground, thinned so silhouettes never overlap
## The web keeps all JS uint32 / int32 arithmetic; here every value is kept as an unsigned 32-bit int.

const MASK := 0xFFFFFFFF
const CHUNK_TILES := 32

static func imul(a: int, b: int) -> int:
	a &= MASK
	b &= MASK
	var lo := (a & 0xFFFF) * b
	var hi := ((a >> 16) * b) & 0xFFFF
	return (lo + (hi << 16)) & MASK

static func mix(v: int) -> int:
	v &= MASK
	v = imul(v ^ (v >> 16), 0x7feb352d)
	v = imul(v ^ (v >> 15), 0x846ca68b)
	return (v ^ (v >> 16)) & MASK

static func chunk_hash(seed_value: int, tx: int, ty: int, channel: int) -> int:
	var h := mix((seed_value & MASK) ^ 0x9e3779b9)
	h = mix(h ^ (tx & MASK))
	h = mix(h ^ (ty & MASK))
	return mix(h ^ (channel & MASK))

static func is_valid_context(context: Dictionary) -> bool:
	var v := int(context.get("generatorVersion", 0))
	var s: Variant = context.get("seed")
	return (v == 1 or v == 2) and (s is int or s is float) and float(s) >= 0.0 and float(s) <= 4294967295.0 and floor(float(s)) == float(s)

static func _floor_div(n: int, d: int) -> int:
	return int(floor(float(n) / float(d)))

static func _js_round(v: float) -> int:
	return int(floor(v + 0.5))

static func _smooth(n: int) -> int:
	var f := float(n) / 16.0
	return _js_round(f * f * (3.0 - float(2 * n) / 16.0) * 65536.0)

static func _lerp(a: int, b: int, w: int) -> int:
	return (a * (65536 - w) + b * w) / 65536

static func noise(seed_value: int, tx: int, ty: int) -> int:
	var gx := _floor_div(tx, 16)
	var gy := _floor_div(ty, 16)
	var wx := _smooth(posmod(tx, 16))
	var wy := _smooth(posmod(ty, 16))
	var a00 := chunk_hash(seed_value, gx, gy, 1) >> 16
	var a10 := chunk_hash(seed_value, gx + 1, gy, 1) >> 16
	var a01 := chunk_hash(seed_value, gx, gy + 1, 1) >> 16
	var a11 := chunk_hash(seed_value, gx + 1, gy + 1, 1) >> 16
	return _lerp(_lerp(a00, a10, wx), _lerp(a01, a11, wx), wy)

## The vein a mine-grid cell (8 x 8 tiles) holds, or {} for none.
static func mine_candidate(context: Dictionary, gx: int, gy: int) -> Dictionary:
	var seed_value := int(context.seed)
	var tx := gx * 8 + 4
	var ty := gy * 8 + 4
	if maxi(absi(tx), absi(ty)) < 60 or absi(tx) > 120 or absi(ty) > 120:
		return {}
	if Vector2(tx - 64, ty).length() < 12.0 or chunk_hash(seed_value, gx, gy, 2) >= 0x40000000:
		return {}
	return {
		"id": "gen:v%d:mine:%d:%d" % [int(context.generatorVersion), gx, gy],
		"x": tx / 4, "y": ty / 4,
		"resource": "iron" if chunk_hash(seed_value, gx, gy, 3) < 0x80000000 else "coal",
		"grade": 1, "miningPower": 1, "developmentState": "unsecured",
	}

static func clear_tile(context: Dictionary, tx: int, ty: int) -> bool:
	var mx := posmod(tx, 32)
	var my := posmod(ty, 32)
	if mx == 15 or mx == 16 or my == 15 or my == 16:
		return true
	# spawn clearing and its connection to the nearest horizontal grid path
	if tx >= 56 and tx <= 72 and ty >= -8 and ty <= 16:
		return true
	var gx := _floor_div(tx, 8)
	var gy := _floor_div(ty, 8)
	for y in range(gy - 2, gy + 3):
		var m := mine_candidate(context, gx, y)
		if m.is_empty():
			continue
		var ax := gx * 8 + 4
		var ay := y * 8 + 4
		var line := _floor_div(ay, 32) * 32 + 16
		# v2: a vein alongside the protected forest connects outward, never into the inner ring
		if int(context.generatorVersion) == 2 and absi(ax) < 56 and absi(line) < 56:
			line = 80 if ay > 0 else -80
		if absi(tx - ax) <= 2 and absi(ty - ay) <= 2:
			return true
		if tx >= ax - 1 and tx <= ax and ty >= mini(ay, line) - 1 and ty <= maxi(ay, line):
			return true
	return false

## Tile type at an absolute quarter-unit tile.
static func sample_tile(context: Dictionary, tx: int, ty: int) -> int:
	var d := maxf(absf(tx + 0.5), absf(ty + 0.5))
	if tx < -127 or tx >= 127 or ty < -127 or ty >= 127 or d < 56.0:
		return 4
	if clear_tile(context, tx, ty):
		return 0
	return 2 if noise(int(context.seed), tx, ty) >= 51117 else 0

## One chunk: {cx, cy, tiles: PackedByteArray(1024), mines: Array, props: Array}.
static func generate_chunk(context: Dictionary, cx: int, cy: int) -> Dictionary:
	var seed_value := int(context.seed)
	var version := int(context.generatorVersion)
	var tiles := PackedByteArray()
	tiles.resize(CHUNK_TILES * CHUNK_TILES)
	for j in CHUNK_TILES:
		for i in CHUNK_TILES:
			tiles[j * CHUNK_TILES + i] = sample_tile(context, cx * CHUNK_TILES + i, cy * CHUNK_TILES + j)
	var mines: Array = []
	for gy in range(cy * 4, cy * 4 + 4):
		for gx in range(cx * 4, cx * 4 + 4):
			var m := mine_candidate(context, gx, gy)
			if not m.is_empty():
				mines.append(m)
	var props: Array = []
	for gy in range(cy * 16, cy * 16 + 16):
		for gx in range(cx * 16, cx * 16 + 16):
			var tx := gx * 2 + 1
			var ty := gy * 2 + 1
			var h := chunk_hash(seed_value, gx, gy, 4)
			if h >= 0x20000000 or sample_tile(context, tx, ty) != 0 or clear_tile(context, tx, ty):
				continue
			# stable thinning with a one-cell halo prevents overlapping silhouettes
			var keep := true
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nh := chunk_hash(seed_value, gx + dx, gy + dy, 4)
					if nh < h or (nh == h and (dy < 0 or (dy == 0 and dx < 0))):
						keep = false
			if not keep:
				continue
			var kinds := ["grass", "rock", "sparseTree"]
			props.append({
				"id": "gen:v%d:prop:%d:%d" % [version, gx, gy],
				"kind": kinds[chunk_hash(seed_value, gx, gy, 5) % 3],
				"x": (tx + 0.5) / 4.0, "y": (ty + 0.5) / 4.0,
				"zone": "deepForest",
				"size": 0.8 + float(chunk_hash(seed_value, gx, gy, 6) >> 16) / 65535.0 * 0.2,
				"name": "",
			})
	return {"cx": cx, "cy": cy, "tiles": tiles, "mines": mines, "props": props}
