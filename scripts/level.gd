extends Node2D
## Puts the player at the Marker2D named Game.spawn_name (under Spawns) when the scene starts, and keeps the
## camera inside the painted map: the limits come from every TileMapLayer's used cells, so painting the map
## larger in the editor moves the limits with it.

func _ready() -> void:
	var game := get_node("/root/Game")
	var marker := get_node_or_null("Spawns/" + game.spawn_name)
	if marker:
		$Player.global_position = marker.global_position
	game.bind_level(self, $Player)
	var bounds := Rect2()
	var first := true
	for layer in find_children("*", "TileMapLayer", false):
		var used: Rect2i = layer.get_used_rect()
		var size := Vector2(layer.tile_set.tile_size)
		var r := Rect2(layer.position + Vector2(used.position) * size, Vector2(used.size) * size)
		bounds = r if first else bounds.merge(r)
		first = false
	var cam: Camera2D = $Player/Camera2D
	if not first:
		cam.limit_left = int(bounds.position.x)
		cam.limit_top = int(bounds.position.y)
		cam.limit_right = int(bounds.end.x)
		cam.limit_bottom = int(bounds.end.y)
	cam.reset_smoothing()
