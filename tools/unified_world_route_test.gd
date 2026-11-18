extends SceneTree
const World = preload("res://scripts/world/world_state.gd")
var step := 0
var frames := 0
func _initialize() -> void:
	call_deferred("_start")
func _start() -> void:
	var game = root.get_node("Game")
	game.workshop._restore({"world": World.new_game(42).to_dict()})
	change_scene_to_file("res://scenes/world/world_map.tscn")
func _hold(a: String) -> void:
	for key in ["move_up", "move_down", "move_left", "move_right"]:
		if key == a: Input.action_press(key)
		else: Input.action_release(key)
func _physics_process(_dt: float) -> bool:
	if current_scene == null: return false
	frames += 1
	var p = current_scene.get_node("Player")
	var g = root.get_node("Game").workshop
	match step:
		0:
			_hold("move_down")
			if p.position.y >= 96:
				step = 1
				frames = 0
		1:
			_hold("move_left")
			if frames > 450:
				if p.position.x < -400: return _fail("closed tunnel is passable")
				print("UNIFIED closed tunnel blocks at ", p.position)
				_hold("")
				g.state.gold = 6000.0
				g.state.inventory["alloy"] = 5.0
				if not g.unlock("tunnelWork") or not g.order_tunnel(): return _fail("commission")
				for i in 6000: g._tick()
				step = 2
				frames = 0
		2:
			if frames < 3: return false
			_hold("move_left")
			if p.position.x < -500:
				if current_scene.name != "WorldMap": return _fail("scene changed")
				print("UNIFIED beyond ", p.position)
				step = 3
				frames = 0
			elif frames > 700: return _fail("completed tunnel remains blocked at " + str(p.position))
		3:
			_hold("move_right")
			if p.position.x >= 128:
				_hold("")
				print("UNIFIED WORLD ROUTE PASS")
				quit(0)
			elif frames > 900: return _fail("return blocked")
	return false
func _fail(msg: String) -> bool:
	_hold("")
	printerr("UNIFIED WORLD ROUTE FAIL ", msg)
	quit(1)
	return false
