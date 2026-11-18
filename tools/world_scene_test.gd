extends SceneTree
const World = preload("res://scripts/world/world_state.gd")
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var game = root.get_node("Game")
	game.workshop._restore({"world": World.new_game(42, true, 12345).to_dict()})
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await process_frame
	await process_frame
	var map = current_scene.get_node("World")
	map._fill_seeded_near(Vector2(16,0))
	var readable: bool = map.get_node("WorldUI/Region").get_theme_font("font").resource_path == "res://fonts/Galmuri9.ttf" and map.get_node("WorldUI/Toast").get_theme_font("font").resource_path == "res://fonts/Galmuri9.ttf"
	var before: int = map.ground.get_cell_source_id(Vector2i(64,0))
	map._refresh_terrain()
	map._fill_seeded_near(Vector2(16,0))
	var after: int = map.ground.get_cell_source_id(Vector2i(64,0))
	if not readable:
		printerr("WORLD SCENE FAIL Korean region and discovery labels lack the bundled font")
		quit(1)
	elif before == -1 or after != before:
		printerr("WORLD SCENE FAIL visited chunk lost after terrain refresh: ", before, " -> ", after)
		quit(1)
	else:
		print("WORLD SCENE PASS")
		quit(0)
