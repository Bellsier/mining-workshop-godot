extends Node2D
## Trees and grass that lean in the wind (web render.js tdDrawSway with light.js tdSway): each sprite is skewed
## sideways about its foot, by a little more than a degree for trees and a few degrees for grass, a slow wave
## across the ground. Only what is in view is drawn, every frame (the view moves with the player). At the lowest
## effect quality (web TD.quality 2, slow frames) they stand still. Drawing only: nothing here is saved.

const Sprites := preload("res://scripts/world/world_sprites.gd")
const KINDS := ["bigTree", "sparseTree", "grass"]

var _map: Node2D
var _light: Node


static func sways(kind: String) -> bool:
	return kind in KINDS


func setup(world_map: Node2D, light: Node) -> void:
	_map = world_map
	_light = light


## web tdSway: how much a plant leans now (skew; its foot stays put).
static func lean(now_ms: float, x: float, y: float, kind: String) -> float:
	var amp := 0.07 if kind == "grass" else 0.022
	return amp * sin(now_ms / 1300.0 + x * 1.7 + y * 0.9) + amp * 0.35 * sin(now_ms / 610.0 + x * 3.1)


func _still() -> bool:
	return _light == null or int(_light.get("quality")) >= 2


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _map == null or _map.state == null:
		return
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var view := Rect2(inverse * Vector2.ZERO, Vector2.ZERO).expand(inverse * get_viewport_rect().size).grow(48.0)
	var still := _still()
	var now := float(Time.get_ticks_msec())
	for p: Dictionary in _map.scenery_now:
		var kind := str(p.kind)
		if not sways(kind):
			continue
		var at: Vector2 = _map.to_px(Vector2(p.x, p.y))
		if not view.has_point(at):
			continue
		var sprite := Sprites.prop(kind)
		var origin := Sprites.origin(sprite, at, Sprites.ANCHOR.prop)
		if still:
			draw_texture(sprite, origin)
			continue
		var k := lean(now, float(p.x), float(p.y), kind)
		var foot := at.y + Sprites.ANCHOR.prop
		draw_set_transform_matrix(Transform2D(Vector2(1, 0), Vector2(k, 1), Vector2(-k * foot, 0)))
		draw_texture(sprite, origin)
	draw_set_transform_matrix(Transform2D.IDENTITY)
