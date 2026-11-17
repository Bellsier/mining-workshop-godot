extends RefCounted
## The ground TileSet, painted in code from the web palette (js/topdown/tiles.js TD_COLORS), so no art file
## is needed yet. Atlas row = tile type (WorldTerrain.Tile), columns 0-3 = look variants, columns 4-7 = the
## same looks with a full-tile collision box (used for rock / edge tiles that touch walkable ground, so the
## physics stays light on the big seeded world).

const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const TILE := 16
const VARIANTS := 4
const SOLID_TILES := [WorldTerrain.Tile.ROCK, WorldTerrain.Tile.EDGE]

const BASE := {
	0: [Color8(78, 122, 70), Color8(84, 130, 74), Color8(72, 114, 66), Color8(92, 140, 80)],
	1: [Color8(58, 96, 62), Color8(63, 103, 66), Color8(53, 89, 58), Color8(70, 110, 70)],
	2: [Color8(110, 105, 98), Color8(102, 97, 91), Color8(118, 113, 106), Color8(95, 90, 85)],
	3: [Color8(86, 72, 58), Color8(80, 67, 54), Color8(92, 78, 62), Color8(86, 72, 58)],
	4: [Color8(38, 66, 44), Color8(44, 74, 48), Color8(33, 58, 39), Color8(38, 66, 44)],
	5: [Color8(150, 122, 86), Color8(143, 116, 81), Color8(158, 129, 92), Color8(150, 122, 86)],
}
const DETAIL := {
	0: Color8(107, 155, 85), 1: Color8(150, 110, 60), 2: Color8(80, 76, 72),
	3: Color8(120, 92, 60), 4: Color8(56, 92, 58), 5: Color8(176, 152, 116),
}

static func _h(a: int, b: int, salt: int) -> int:
	var h := (a * 374761393 + b * 668265263 + salt * 1013904223) & 0xFFFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
	return h ^ (h >> 16)

static func make_tileset() -> TileSet:
	var types := BASE.keys()
	var img := Image.create_empty(TILE * VARIANTS * 2, TILE * types.size(), false, Image.FORMAT_RGBA8)
	for t: int in types:
		for v in VARIANTS:
			for copy in 2:
				_paint(img, (copy * VARIANTS + v) * TILE, t * TILE, t, v)
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	var src := TileSetAtlasSource.new()
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = Vector2i(TILE, TILE)
	ts.add_source(src, 0)
	var half := TILE / 2.0
	var square := PackedVector2Array([Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	for t: int in types:
		for col in VARIANTS * 2:
			var at := Vector2i(col, t)
			src.create_tile(at)
			if col >= VARIANTS:
				var data := src.get_tile_data(at, 0)
				data.add_collision_polygon(0)
				data.set_collision_polygon_points(0, 0, square)
	return ts

static func _paint(img: Image, ox: int, oy: int, t: int, v: int) -> void:
	var base: Color = BASE[t][v]
	var detail: Color = DETAIL[t]
	for y in TILE:
		for x in TILE:
			var n := _h(x + ox, y + oy, t) % 100
			var c := base
			if n < 6:
				c = base.lightened(0.08)
			elif n < 12:
				c = base.darkened(0.08)
			img.set_pixel(ox + x, oy + y, c)
	# a few marks per look
	for k in 3 + v:
		var px := _h(v, k, t + 7) % (TILE - 2)
		var py := _h(k, v, t + 11) % (TILE - 2)
		match t:
			WorldTerrain.Tile.ROCK:
				img.set_pixel(ox + px, oy + py, detail)
				img.set_pixel(ox + px + 1, oy + py + 1, detail)
			WorldTerrain.Tile.TUNNEL:
				if k == 0:
					for x in TILE:
						img.set_pixel(ox + x, oy + 3 + v * 3, detail)
			_:
				img.set_pixel(ox + px, oy + py, detail)
				img.set_pixel(ox + px, oy + py + 1, detail)

## Atlas cell for a tile type at an absolute tile (look picked from the tile position).
static func atlas_for(tile_type: int, tx: int, ty: int, collide: bool) -> Vector2i:
	var v := _h(tx, ty, 3) % VARIANTS
	return Vector2i(v + (VARIANTS if collide else 0), tile_type)
