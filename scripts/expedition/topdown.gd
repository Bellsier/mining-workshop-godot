extends Node2D

const Regions := preload("res://scripts/expedition/regions.gd")
const PLAYER := preload("res://art/player.png")
const CELL := 25.0
const ORIGIN := Vector2(78, 30)
const ACCENT := Color("#f6cd90")
const LIGHT := Color("#bceee7")

var region: String
var pos := Vector2i(1, 3)
var progress: Dictionary
var facing := 0
var objective := ""

func step(dir: Vector2i) -> bool:
	if Regions.can_walk(region, pos + dir, progress):
		facing = [Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP].find(dir)
		pos += dir
		return true
	return false

func target() -> String:
	for id: String in Regions.ROOMS[region].sites:
		var at: Vector2i = Regions.ROOMS[region].sites[id][0]
		if pos == at:
			return id
	return ""

func _at(tile: Vector2i) -> Vector2:
	return ORIGIN + (Vector2(tile) + Vector2(0.5, 0.5)) * CELL

func _draw() -> void:
	var room: Dictionary = Regions.ROOMS[region]
	var stone := Color(room.color)
	for y in room.map.size():
		for x in room.map[y].length():
			var tile := Vector2i(x, y)
			var kind: String = room.map[y][x]
			var floor_color := stone.darkened(0.27 if (x + y) % 2 else 0.34)
			var cell_rect := Rect2(ORIGIN + Vector2(tile) * CELL, Vector2.ONE * CELL)
			match kind:
				"#":
					draw_rect(cell_rect, stone.darkened(0.68))
					draw_rect(Rect2(cell_rect.position + Vector2(1, 1), Vector2(CELL - 2, CELL - 5)), stone.darkened(0.48))
				"G":
					var open: bool = progress.has(room.gate)
					draw_rect(cell_rect, floor_color if open else stone.lightened(0.17))
					for i in 3:
						draw_line(cell_rect.position + Vector2(2, 5 + i * 8), cell_rect.position + Vector2(CELL - 2, 5 + i * 8),
							LIGHT if open else stone.darkened(0.25), 1 if open else 2)
				_:
					draw_rect(cell_rect, floor_color)
					_ground_detail(tile, cell_rect.position, stone)
	if region == "crystal" and progress.has("signal"):
		_draw_beams(room.sites)
	for id: String in room.sites:
		var at := _at(room.sites[id][0])
		if region == "swamp" and not progress.has("swamp_open") and pos.distance_to(room.sites[id][0]) > 2.5:
			continue
		var active: bool = progress.has(id) or (id == "table" and progress.has("accord")) or (id == "lab" and progress.has("research"))
		draw_rect(Rect2(at - Vector2(9, 8), Vector2(18, 15)), stone.lightened(0.26) if active else stone.darkened(0.64))
		draw_circle(at - Vector2(0, 2), 4.0, LIGHT if active else ACCENT)
		draw_line(at + Vector2(-7, 6), at + Vector2(7, 6), stone.lightened(0.4))
		if id == objective:
			draw_arc(at - Vector2(0, 2), 11, 0.0, TAU, 16, ACCENT, 1.0)
	if region == "village":
		_draw_residents()
	elif region == "crystal" and progress.has("alive"):
		var at := _at(Vector2i(10, 2) if not progress.has("rescued") else Vector2i(8, 3))
		draw_rect(Rect2(at + Vector2(-4, -6), Vector2(8, 13)), Color("#dce1e0"))
		draw_circle(at - Vector2(0, 7), 3.5, Color("#e7c9ac"))
	var p := _at(pos)
	if region == "swamp" and not progress.has("swamp_open"):
		_draw_fog(p)
	draw_circle(p + Vector2(0, 5), 7.0, Color("#293039"))
	draw_texture_rect_region(PLAYER, Rect2(p - Vector2(8, 18), Vector2(16, 24)), Rect2(0, facing * 24, 16, 24))
	if not target().is_empty():
		draw_arc(p, 11, 0, TAU, 20, Color("#f6cd90"), 1)

func _draw_beams(sites: Dictionary) -> void:
	var focus := _at(Vector2i(6, 3))
	for id: String in ["west", "east"]:
		var from := _at(sites[id][0])
		var angle := int(progress.get(id, 0))
		var correct := 1 if id == "west" else 2
		var to := focus if angle == correct else _at(Vector2i(5, 1 + angle * 2))
		draw_line(from, to, Color("#aac6f7"), 2)
	if progress.has("crystal_open"):
		draw_line(focus, _at(Vector2i(10, 3)), LIGHT, 3)
		draw_circle(focus, 6, Color("#e7faff"))

func _draw_residents() -> void:
	var meeting := progress.has("accord")
	var places := [Vector2i(6, 3), Vector2i(8, 3)] if meeting else [Vector2i(3, 1), Vector2i(3, 5)]
	if progress.has("research"):
		places.append(Vector2i(10, 2))
	for i in places.size():
		var p := _at(places[i])
		draw_rect(Rect2(p - Vector2(4, 5), Vector2(8, 11)), [Color("#9ebdb9"), Color("#ca986c"), Color("#dce1e0")][i])
		draw_circle(p - Vector2(0, 7), 3.5, Color("#e7c9ac"))

func _draw_fog(p: Vector2) -> void:
	for y in range(7):
		for x in range(13):
			var at := _at(Vector2i(x, y))
			var opacity := smoothstep(34.0, 115.0, p.distance_to(at)) * 0.80
			draw_rect(Rect2(at - Vector2.ONE * CELL * 0.5, Vector2.ONE * CELL), Color(0.30, 0.43, 0.43, opacity))

func _ground_detail(tile: Vector2i, origin: Vector2, stone: Color) -> void:
	var seed := tile.x * 23 + tile.y * 19
	if seed % 3 == 0:
		draw_rect(Rect2(origin + Vector2(5 + seed % 11, 7 + seed % 9), Vector2(3, 2)), stone.lightened(0.05))
	if tile.y not in [1, 5] or seed % 4 == 0:
		return
	var at := origin + Vector2(12, 15)
	match region:
		"forest":
			draw_polyline(PackedVector2Array([at + Vector2(-9, 7), at + Vector2(-6, -2), at + Vector2(0, 3),
				at + Vector2(4, -4), at + Vector2(9, -3)]), stone.lightened(0.16), 2)
		"swamp":
			draw_line(at - Vector2(7, 0), at + Vector2(9, 0), stone.lightened(0.16), 1)
			draw_line(at + Vector2(-2, 3), at + Vector2(6, 3), stone.lightened(0.11), 1)
		"crystal":
			draw_colored_polygon(PackedVector2Array([at + Vector2(-5, 6), at + Vector2(-2, -7),
				at + Vector2(4, -4), at + Vector2(5, 6)]), stone.lightened(0.22))
			draw_line(at + Vector2(-2, -7), at + Vector2(-1, 6), stone.lightened(0.4), 1)
		"village":
			draw_line(at - Vector2(8, 2), at + Vector2(8, -2), stone.lightened(0.13), 1)
			draw_line(at + Vector2(-8, 4), at + Vector2(8, 4), stone.lightened(0.1), 1)
