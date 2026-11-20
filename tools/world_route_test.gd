extends SceneTree
## Headless exploration route: stage-1 tunnel -> its new west door -> the world map beyond the mountain
## (tunnel opened, beyond veins placed) -> walk west and discover a vein -> back east through the passage
## into the stage-1 tunnel -> out to the workshop overworld. Also opens the world map at the workshop.
##   godot --headless --path . --fixed-fps 60 --script res://tools/world_route_test.gd
## Prints "WORLD ROUTE PASS" and exits 0, or "WORLD ROUTE FAIL <why>" and exits 1.

const WorldState := preload("res://scripts/world/world_state.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")

var step := -1
var frames := 0
var notes: Array[String] = []
var world: RefCounted
var found_before := 0

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	var game := root.get_node_or_null("Game")
	if game == null:
		game = load("res://scripts/game.gd").new()
		game.name = "Game"
		root.add_child(game)
	world = WorldState.new_game(42)
	world.unlock_tunnel() # fixture: completed construction, not entry-based unlock
	WorldState.set_current(world)
	game.spawn_name = "FromOutside"
	change_scene_to_file("res://scenes/tunnel.tscn")
	step = 0

func _hold(actions: Array) -> void:
	for a in ["move_left", "move_right", "move_up", "move_down"]:
		if a in actions:
			Input.action_press(a)
		else:
			Input.action_release(a)

func _physics_process(_d: float) -> bool:
	if step < 0:
		return false
	frames += 1
	var s := current_scene
	if s == null or not s.has_node("Player"):
		return false
	var p: Node2D = s.get_node("Player")
	match step:
		0:
			_hold(["move_left"])
			if s.name == "WorldMap":
				notes.append("tunnel west door -> world map after %d frames at %s" % [frames, p.position])
				if not world.tunnel_unlocked:
					return _fail("arriving from the tunnel did not open it")
				var beyond: Array = world.mines.filter(func(m: Dictionary) -> bool: return str(m.id).begins_with("mine_beyond_"))
				if beyond.size() != 8:
					return _fail("expected 8 beyond veins, got %d" % beyond.size())
				var spot: Vector2 = p.position / 64.0
				if WorldTerrain.region_at(spot.x, spot.y) != "beyond":
					return _fail("arrived outside the land beyond: %s" % spot)
				found_before = world.discovered_count()
				step = 1
				frames = 0
			elif frames > 900:
				return _fail("did not reach the west door: %s in %s" % [p.position, s.name])
		1:
			_hold(["move_left"])
			if frames > 150:
				var label: String = s.get_node("World/WorldUI/Region").text
				notes.append("walked west to %s (%s); veins found %d -> %d" % [p.position / 64.0, label.replace("\n", " / "), found_before, world.discovered_count()])
				if world.discovered_count() <= 2:
					return _fail("no beyond vein discovered while exploring")
				if not label.begins_with("산 너머"):
					return _fail("region label: %s" % label)
				step = 2
				frames = 0
		2:
			_hold(["move_right"])
			if s.name == "Tunnel":
				notes.append("passage door -> stage-1 tunnel at %s" % p.position)
				if p.position.x > 120:
					return _fail("expected the west end of the tunnel, got %s" % p.position)
				step = 3
				frames = 0
			elif frames > 900:
				return _fail("did not walk back into the passage: %s" % (p.position / 64.0))
		3:
			_hold(["move_right"])
			if s.name == "Overworld":
				notes.append("back at the workshop overworld at %s" % p.position)
				root.get_node("Game").spawn_name = "Start"
				change_scene_to_file("res://scenes/world/world_map.tscn")
				step = 4
				frames = 0
			elif frames > 1200:
				return _fail("did not get out of the tunnel: %s" % p.position)
		4:
			_hold([])
			if s.name == "WorldMap" and frames > 5:
				var at: Vector2 = p.position / 64.0
				notes.append("world map from the workshop start at %s, region %s" % [at, WorldTerrain.region_at(at.x, at.y)])
				if at.distance_to(Vector2(world.base)) > 0.1:
					return _fail("start is not at the workshop: %s" % at)
				step = 5
				frames = 0
		5:
			_hold(["move_up"])
			if frames > 60:
				_hold([])
				for n in notes:
					print("WORLD ROUTE ", n)
				print("WORLD ROUTE PASS")
				quit(0)
	return false

func _fail(msg: String) -> bool:
	_hold([])
	for n in notes:
		print("WORLD ROUTE ", n)
	print("WORLD ROUTE FAIL ", msg)
	quit(1)
	return false
