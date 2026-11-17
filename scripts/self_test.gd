extends Node
## Route self-test, only when the game is started with:  <game>.exe -- --route-test   (add --headless to hide the window)
## Holds the move actions to walk from the workshop to the western tunnel, in and back out, then writes the result to
## route-test-result.txt next to the executable (or the project folder in the editor) and quits: exit code 0 = pass.

var _step := 0
var _frames := 0
var _log: Array[String] = []

func _hold(actions: Array) -> void:
	for a in ["move_left", "move_right", "move_up", "move_down"]:
		if a in actions:
			Input.action_press(a)
		else:
			Input.action_release(a)

func _physics_process(_delta: float) -> void:
	_frames += 1
	var s := get_tree().current_scene
	if s == null or not s.has_node("Player"):
		return
	var p: Node2D = s.get_node("Player")
	match _step:
		0:
			_log.append("start %s %s" % [s.name, p.global_position]); _step = 1
		1:
			_hold(["move_down"])
			if p.global_position.y >= 14 * 16 + 6: _step = 2
			elif _frames > 600: _finish(false, "could not reach the road: %s" % p.global_position)
		2:
			_hold(["move_left"])
			if s.name == "Tunnel":
				_log.append("entered the tunnel after %d frames at %s" % [_frames, p.global_position]); _step = 3; _frames = 0
			elif _frames > 1600: _finish(false, "did not reach the tunnel: %s" % p.global_position)
		3:
			_hold(["move_left"])
			if _frames > 90: _log.append("walked inside the tunnel to %s facing %s" % [p.global_position, p.facing]); _step = 4
		4:
			_hold(["move_right"])
			if s.name == "Overworld":
				_log.append("came back out at %s" % p.global_position); _finish(true, "")
			elif _frames > 1200: _finish(false, "did not come back out: %s" % p.global_position)

func _finish(ok: bool, why: String) -> void:
	_hold([])
	set_physics_process(false)
	_log.append("ROUTE PASS" if ok else "ROUTE FAIL " + why)
	var dir := OS.get_executable_path().get_base_dir() if OS.has_feature("template") else ProjectSettings.globalize_path("res://")
	var f := FileAccess.open(dir.path_join("route-test-result.txt"), FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_log) + "\n")
		f.close()
	for line in _log:
		print(line)
	get_tree().quit(0 if ok else 1)
