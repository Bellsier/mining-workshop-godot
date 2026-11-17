extends SceneTree
## Headless route test: from the workshop, walk to the western tunnel, enter, come back out.
##   godot --headless --path . --script res://tools/route_test.gd
var step := 0
var frames := 0
var log := []

func _initialize() -> void:
	var game: Node = load("res://scripts/game.gd").new()
	game.name = "Game"
	root.add_child(game)
	change_scene_to_file("res://scenes/overworld.tscn")

func _hold(actions: Array) -> void:
	for a in ["move_left", "move_right", "move_up", "move_down"]:
		if a in actions:
			Input.action_press(a)
		else:
			Input.action_release(a)

func _physics_process(_d: float) -> bool:
	frames += 1
	var s := current_scene
	if s == null or not s.has_node("Player"):
		return false
	var p: Node2D = s.get_node("Player")
	match step:
		0:
			log.append("start %s %s" % [s.name, p.global_position]); step = 1
		1:  # walk down the path to the road (row 14)
			_hold(["move_down"])
			if p.global_position.y >= 14 * 16 + 6: step = 2
			if frames > 600: return _fail("could not reach the road: %s" % p.global_position)
		2:  # walk west along the road into the tunnel mouth
			_hold(["move_left"])
			if s.name == "Tunnel":
				log.append("entered tunnel after %d frames at %s, facing %s" % [frames, p.global_position, p.facing]); step = 3; frames = 0
			elif frames > 1600: return _fail("did not reach the tunnel: %s" % p.global_position)
		3:  # inside: walk west a bit (a wall stops the player), then back east to the exit
			_hold(["move_left"])
			if frames > 90: step = 4; log.append("deep in tunnel at %s" % p.global_position)
		4:
			_hold(["move_right"])
			if s.name == "Overworld":
				log.append("back outside at %s facing %s" % [p.global_position, p.facing]); step = 5; frames = 0
			elif frames > 900: return _fail("did not come back out: %s" % p.global_position)
		5:  # the mountain blocks walking further west except at the mouth: try walking up into the rock face
			_hold(["move_up"])
			if frames > 60: log.append("after walking up at the rock face: %s" % p.global_position); step = 6
		6:
			_hold([])
			for l in log: print("ROUTE ", l)
			print("ROUTE PASS")
			quit(0)
	return false

func _fail(msg: String) -> bool:
	for l in log: print("ROUTE ", l)
	print("ROUTE FAIL ", msg)
	quit(1)
	return false
