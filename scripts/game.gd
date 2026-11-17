extends Node
## Autoload "Game": changes scenes and remembers where the player should appear.
## A door (Area2D with door.gd) calls go(scene, spawn); the next scene puts the player at the Marker2D named spawn.

var spawn_name := "Start"
var _web_window = null
var _trace_path := ""
var _trace_at := 0

func go(scene_path: String, spawn: String) -> void:
	spawn_name = spawn
	get_tree().call_deferred("change_scene_to_file", scene_path)

func _ready() -> void:
	if OS.has_feature("web"):
		_web_window = JavaScriptBridge.get_interface("window")
	if "--trace-position" in OS.get_cmdline_user_args():
		# Test aid: writes the current scene and position to position-trace.txt next to the executable.
		var dir := OS.get_executable_path().get_base_dir() if OS.has_feature("template") else ProjectSettings.globalize_path("res://")
		_trace_path = dir.path_join("position-trace.txt")
	if "--route-test" in OS.get_cmdline_user_args():
		var t := Node.new()
		t.name = "RouteSelfTest"
		t.set_script(load("res://scripts/self_test.gd"))
		add_child(t)

## Publishes the player state for tests: window.__trial_* on the web, position-trace.txt with --trace-position.
func report(scene_name: String, pos: Vector2, facing: String) -> void:
	if _trace_path != "" and Time.get_ticks_msec() - _trace_at >= 200:
		_trace_at = Time.get_ticks_msec()
		var f := FileAccess.open(_trace_path, FileAccess.WRITE)
		if f:
			f.store_string("%s %d %d %s\n" % [scene_name, int(pos.x), int(pos.y), facing])
			f.close()
	if _web_window == null:
		return
	_web_window.__trial_scene = scene_name
	_web_window.__trial_x = pos.x
	_web_window.__trial_y = pos.y
	_web_window.__trial_facing = facing
