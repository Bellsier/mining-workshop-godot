extends Control
## The minimap in a corner of the world view (web tdRenderMinimap): the ground, the found veins (a mark under the
## secured ones), torches, the village facilities (grey while ruined, coloured once open), the house, the
## workshop, the player and the part of the world on screen. Hidden veins never show.

const Guidance := preload("res://scripts/expedition/guidance.gd")
const WorldTiles := preload("res://scripts/world/world_tiles.gd")
const Layout := preload("res://scripts/village_layout.gd")
const VEIN := {
	"iron": Color("b6a698"), "coal": Color("707281"), "mana": Color("58c9a6"), "crystal": Color("a9dafb"),
	"rareMetal": Color("edbd64"), "relic": Color("df8b66"), "cosmicShard": Color("c99aee"), "plasma": Color("ea7ec7"),
}
const SIZE := 72.0

var world: RefCounted
var economy: Node
var player: Node2D
var _ground: ImageTexture
var _ground_key := ""
var _rect := Rect2()
var _last_goal_hash := -1
var _goal_points: Array[Vector2] = []


func setup(world_state: RefCounted, game_economy: Node, walker: Node2D) -> void:
	world = world_state
	economy = game_economy
	player = walker
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## One pixel per ground tile, painted once per tunnel state (web TD.miniBase).
func _make_ground() -> void:
	_rect = Rect2(-12, -12, 24, 24) if world.is_seeded() else world.map_rect()
	var tiles := Vector2i(int(_rect.size.x * 4), int(_rect.size.y * 4))
	var img := Image.create_empty(tiles.x, tiles.y, false, Image.FORMAT_RGBA8)
	for ty in tiles.y:
		for tx in tiles.x:
			var t: int = world.tile_type(int(_rect.position.x * 4) + tx, int(_rect.position.y * 4) + ty)
			img.set_pixel(tx, ty, WorldTiles.BASE.get(t, [Color.BLACK])[0])
	_ground = ImageTexture.create_from_image(img)


func _process(_delta: float) -> void:
	if world == null:
		return
	var key := str(world.tunnel_unlocked)
	if key != _ground_key:
		_ground_key = key
		_make_ground()
	var signature: int = hash([world.tunnel_unlocked, world.story, world.expedition])
	if signature != _last_goal_hash:
		_last_goal_hash = signature
		_goal_points = Guidance.surface_points(world.story, world.expedition) if world.tunnel_unlocked else []
	queue_redraw()


func _at(x: float, y: float) -> Vector2:
	return Vector2((x - _rect.position.x) / _rect.size.x, (y - _rect.position.y) / _rect.size.y) * SIZE


func _draw() -> void:
	if _ground == null:
		return
	draw_rect(Rect2(Vector2(-1, -1), Vector2(SIZE + 2, SIZE + 2)), Color(0, 0, 0, 0.6))
	draw_texture_rect(_ground, Rect2(Vector2.ZERO, Vector2(SIZE, SIZE)), false)
	for m: Dictionary in world.mines:
		if not world.is_discovered(m):
			continue
		var p := _at(m.x, m.y).round()
		draw_rect(Rect2(p - Vector2(1, 1), Vector2(3, 3)), VEIN.get(m.resource, Color.LIGHT_GRAY))
		if m.developmentState == "secured":
			draw_rect(Rect2(p + Vector2(-1, 2), Vector2(3, 1)), Color("3fc9b0"))
	for t: Dictionary in world.torches:
		draw_rect(Rect2(_at(t.x, t.y).round() - Vector2(1, 1), Vector2(2, 2)), Color("ffb04a"))
	for w: Dictionary in world.workshops:
		draw_rect(Rect2(_at(w.x, w.y).round() - Vector2(1, 2), Vector2(3, 3)), Color("5c7490"))
	if economy != null:
		var village: Dictionary = economy.state.village
		for k: String in Layout.ORDER:
			var site: Variant = village.sites.get(k)
			if site is Dictionary:
				var open := int(village.stage.get(k, 0)) >= 2
				var color := (Color("e6e1d8") if k == "museum" else Color("5fa0d8")) if open else Color("7a746c")
				draw_rect(Rect2(_at(site.x, site.y).round() - Vector2(2, 3), Vector2(4, 3)), color)
		if village.get("district") is Dictionary:
			var door: Dictionary = Layout.district_parts(village.district).house
			draw_rect(Rect2(_at(door.x, door.y).round() - Vector2(2, 3), Vector2(4, 3)), Color("4f8246"))
	draw_rect(Rect2(_at(world.base.x, world.base.y).round() - Vector2(2, 2), Vector2(4, 4)), Color("d68b3d"))
	for at: Vector2 in _goal_points:
		var p := _at(at.x, at.y).round()
		draw_colored_polygon(PackedVector2Array([p + Vector2(0, -3), p + Vector2(3, 0), p + Vector2(0, 3), p + Vector2(-3, 0)]), Color("#f4c87f"))
	if is_instance_valid(player):
		var u := player.position / 64.0
		draw_rect(Rect2(_at(u.x, u.y).round() - Vector2(1, 1), Vector2(3, 3)), Color.WHITE)
		# the part of the world on screen
		var view := get_viewport_rect().size / 64.0
		var a := _at(u.x - view.x / 2.0, u.y - view.y / 2.0)
		var b := _at(u.x + view.x / 2.0, u.y + view.y / 2.0)
		draw_rect(Rect2(a, b - a), Color(1, 1, 1, 0.7), false, 1.0)
