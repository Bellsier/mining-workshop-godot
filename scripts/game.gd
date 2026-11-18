extends Node
## Autoload "Game": changes scenes and remembers where the player should appear.
## A door (Area2D with door.gd) calls go(scene, spawn); the next scene puts the player at the Marker2D named spawn.

var spawn_name := "Start"
var _web_window = null
var _trace_path := ""
var _trace_at := 0
var workshop: Node
var _hud: CanvasLayer
var _world: Node2D
var _context := ""
var _restoring_position := true
var _transitioning := false

func go(scene_path: String, spawn: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	spawn_name = spawn
	get_tree().call_deferred("change_scene_to_file", scene_path)

func _ready() -> void:
	if get_node_or_null("/root/Game") == self:
		workshop = preload("res://scripts/workshop.gd").new()
		workshop.name = "WorkshopEconomy"
		workshop.world_replaced.connect(_reload_world)
		workshop.persistence_enabled = DisplayServer.get_name() != "headless" and "--route-test" not in OS.get_cmdline_user_args()
		add_child(workshop)
		if not workshop.data.is_empty():
			_hud = preload("res://scripts/workshop_hud.gd").new()
			_hud.name = "WorkshopHUD"
			add_child(_hud)
			_hud.setup(workshop)
	if OS.has_feature("web"):
		_web_window = JavaScriptBridge.get_interface("window")
	if "--trace-position" in OS.get_cmdline_user_args():
		# Test aid: writes the current scene and position to position-trace.txt next to the executable.
		var dir := OS.get_executable_path().get_base_dir() if OS.has_feature("template") else ProjectSettings.globalize_path("res://")
		_trace_path = dir.path_join("position-trace.txt")
	if "--route-test" in OS.get_cmdline_user_args():
		get_tree().call_deferred("change_scene_to_file", "res://scenes/overworld.tscn")
		var t := Node.new()
		t.name = "RouteSelfTest"
		t.set_script(load("res://scripts/self_test.gd"))
		add_child(t)

func bind_level(level: Node2D, player: Node2D) -> void:
	_transitioning = false
	if _hud == null:
		return
	workshop.player = player
	_world = null
	_context = ""
	_hud.set_action("")
	_hud.set_context_hint("")
	_hud.close_workshop()
	var old_hint := level.get_node_or_null("UI/Hint") as Label
	if old_hint != null:
		old_hint.hide()
	_world = level.get_node_or_null("World")
	var building := level.get_node_or_null("Workshop") as Node2D
	if building != null:
		_world = preload("res://scripts/workshop_world.gd").new()
		_world.name = "WorkshopInteractions"
		level.add_child(_world)
		_world.setup(workshop, building.position + Vector2(0, 24))
	if _restoring_position:
		var saved: Dictionary = workshop.state.position
		var saved_scene := str(saved.get("scene", ""))
		if level.scene_file_path != saved_scene and saved_scene in ["res://scenes/tunnel.tscn", "res://scenes/world/world_map.tscn"]:
			go(saved_scene, "FromOutside")
			return
		_restoring_position = false
		var x: Variant = saved.get("x")
		var y: Variant = saved.get("y")
		if saved_scene == level.scene_file_path and (x is float or x is int) and (y is float or y is int):
			player.position = Vector2(x, y)

func _process(_delta: float) -> void:
	if _hud == null or not is_instance_valid(workshop.player) or workshop.input_frozen():
		return
	var next: String = _world.context_at(workshop.player.position) if is_instance_valid(_world) else ""
	var action: String = _world.action_label(next) if is_instance_valid(_world) else ""
	if next != _context or action != _context_action:
		_context = next
		_context_action = action
		_hud.set_action(action, _interact)
		_hud.set_context_hint("E  ·  " + action if not action.is_empty() else "")

var _context_action := ""

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		if not _context.is_empty() and not workshop_is_open():
			_interact()
			get_viewport().set_input_as_handled()

func _interact() -> void:
	if workshop.input_frozen():
		return
	if _context == "workshop":
		_hud.open_workshop()
	elif not _context.is_empty() and not workshop_is_open():
		if _world.has_method("mine_near_vein"):
			_world.mine_near_vein()
		else:
			workshop.mine(_context)

func workshop_is_open() -> bool:
	return _hud != null and _hud.is_workshop_open()

func world_input_blocked() -> bool:
	return workshop_is_open() or (is_instance_valid(workshop) and workshop.input_frozen())

func _notification(what: int) -> void:
	if is_instance_valid(workshop) and what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED]:
		workshop.flush()

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
	if is_instance_valid(workshop):
		_web_window.__trial_save_status = workshop.save_status

func _reload_world() -> void:
	workshop.player = null
	_restoring_position = true
	go("res://scenes/world/world_map.tscn", "Start")
