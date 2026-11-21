extends Node2D
## Low, ground-level landmarks; actors and trees keep their normal depth order above them.
const Story := preload("res://scripts/world/region_story.gd")
const Expeditions := preload("res://scripts/expedition/regions.gd")
const MOSS := Color("#88b979")
const COPPER := Color("#efa976")
const IRON := Color("#30414a")
const WATER := Color("#86cdca")
const INK := Color("#263038")

var world: RefCounted

func _draw() -> void:
	if world == null or not world.tunnel_unlocked:
		return
	for id: String in Story.SITES:
		var p: Vector2 = Story.SITES[id].at * 64.0
		draw_set_transform(p)
		if p.y < 0:
			draw_rect(Rect2(-11, -3, 22, 6), Color("#465e41"))
			draw_rect(Rect2(-8, -5, 16, 3), MOSS)
		else:
			draw_set_transform(p, 0.0, Vector2(1.0, 0.32))
			if not world.story.has("repaired"):
				for offset: Vector2 in [Vector2(-14, -29), Vector2(11, -16)]:
					draw_circle(offset, 17, Color("#b3d8ce38"))
			draw_circle(Vector2.ZERO, 16, Color("#436966"))
			draw_arc(Vector2.ZERO, 15, 0.2, 2.8, 14, WATER, 1.5)
			draw_set_transform(p)
		match id:
			"tracks":
				for offset: Vector2 in [Vector2(-4, -2), Vector2(2, -7)]:
					draw_rect(Rect2(offset, Vector2(4, 6)), INK)
					draw_line(offset + Vector2(0, 4), offset + Vector2(3, 4), COPPER)
			"ledger", "incident":
				var paper := Color("#e4ca98") if id == "ledger" else Color("#bed2c8")
				draw_rect(Rect2(-7, -9, 14, 10), INK)
				draw_rect(Rect2(-6, -8, 12, 8), paper)
				draw_line(Vector2(0, -8), Vector2(0, -1), IRON)
				draw_line(Vector2(2, -5), Vector2(5, -5), IRON)
			"leaf", "wave":
				draw_rect(Rect2(-8, -12, 16, 14), INK)
				var ink := Color("#fde6a4") if world.story.has("seal") else MOSS
				if id == "leaf":
					draw_colored_polygon(PackedVector2Array([Vector2(-5, -3), Vector2(-3, -9), Vector2(5, -10), Vector2(3, -4)]), ink)
					draw_line(Vector2(-5, -2), Vector2(3, -8), IRON)
				else:
					draw_polyline(PackedVector2Array([Vector2(-6, -5), Vector2(-3, -8), Vector2(1, -4), Vector2(5, -7)]), WATER, 2)
				var lit := 3 if world.story.has("seal") else int(world.story.get("sequence", 0))
				for i in 3:
					draw_rect(Rect2(-5 + i * 4, 0, 2, 2), COPPER if i < lit else Color("#52635a"))
			"last":
				draw_rect(Rect2(-9, -7, 18, 8), INK)
				var slide := 7 if world.story.has("seal") else 0
				draw_rect(Rect2(-9 + slide, -8, 18, 6), MOSS)
				if slide > 0:
					draw_line(Vector2(-8, -4), Vector2(-4, 1), COPPER, 2)
			"coil":
				draw_rect(Rect2(-8, -8, 16, 10), IRON)
				if not world.story.has("coil"):
					for x in 3:
						draw_arc(Vector2(-4 + x * 4, -6), 3, 0.2, TAU, 10, COPPER, 2)
			"pump", "archive":
				draw_rect(Rect2(-8, -14, 16, 16), IRON)
				var lamp := WATER if world.story.has("repaired") else Color("#a25e50")
				if id == "pump":
					draw_arc(Vector2(-1, -6), 5, 0.0, TAU, 12, COPPER, 2)
					draw_line(Vector2(-1, -6), Vector2(2, -9 if world.story.has("repaired") else -3), lamp, 2)
					draw_rect(Rect2(7, -3, 7, 3), COPPER)
				else:
					draw_rect(Rect2(-5, -11, 10, 6), lamp)
					draw_line(Vector2(-4, -2), Vector2(3, -2), COPPER)
	for id: String in Expeditions.PORTALS:
		if not Expeditions.allowed(id, world.story, world.expedition):
			continue
		var at: Vector2 = Expeditions.PORTALS[id][0] * 64.0
		draw_set_transform(at)
		draw_rect(Rect2(-10, -16, 20, 17), Color("#373b3c"))
		draw_arc(Vector2(0, -5), 11.0, PI, TAU, 14, Color("#c1a589"), 3)
		draw_rect(Rect2(-6, -10, 12, 10), Color("#1d262b"))
		draw_line(Vector2(-9, 2), Vector2(9, 2), COPPER, 2)
	draw_set_transform(Vector2.ZERO)
