extends SceneTree

const World := preload("res://scripts/world/world_state.gd")
const Temple := preload("res://scripts/expedition/temple.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var w = root.get_node("Game").workshop
	if not w.snapshot().has("expedition_goals"):
		check(false, "journal has no current objectives")
		quit(1)
		return
	check(_goal(w, "tunnel").id == "open_tunnel", "old game has a tunnel objective")
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await process_frame
	await process_frame
	var minimap = current_scene.get_node("World/WorldUI/Minimap")
	check(minimap._goal_points.is_empty(), "closed tunnel draws no unavailable regional markers")
	w.world.unlock_tunnel()
	await process_frame
	await process_frame
	check(not minimap._goal_points.is_empty(), "same minimap refreshes after the tunnel opens")
	check(_goal(w, "tunnel").is_empty(), "opened tunnel objective disappears")
	check(_goal(w, "forest").id == "tracks" and _goal(w, "swamp").id == "pump", "both directions are available")
	check(_goal(w, "crystal").is_empty(), "crystal is not advertised before it is accessible")
	var marked: Array = w.Guidance.surface_points({"tracks": true, "ledger": true, "sequence": 1}, {})
	check(marked.has(World.Story.SITES.wave.at) and not marked.has(World.Story.SITES.leaf.at), "map marks the next surface puzzle plate")
	for id in ["tracks", "ledger", "leaf", "wave", "leaf", "last"]:
		w.investigate_landmark(id)
	check(_goal(w, "forest").id == "marks", "forest entry follows the last surface clue")
	w.expedition_action("forest", "marks")
	w.expedition_action("forest", "moss")
	_reload(w)
	check(_goal(w, "forest").id == "root", "restored partial puzzle points at the next actuator")
	w.expedition_action("forest", "root")
	w.expedition_action("forest", "moss")
	w.expedition_action("forest", "forest_path")
	check(_goal(w, "forest").is_empty() and _goal(w, "crystal").id == "signal", "record opens the route to the crystal")
	marked = w.Guidance.surface_points(w.world.story, w.world.expedition)
	check(marked.has(World.Expeditions.PORTALS.crystal[0]) and not marked.has(World.Expeditions.PORTALS.forest[0]),
		"minimap replaces the completed forest marker with the accessible crystal entrance")
	for id in ["signal", "east", "east", "west", "shutter"]:
		w.expedition_action("crystal", id)
	_reload(w)
	check(_goal(w, "crystal").id == "rescue", "restored scientist rescue stage")
	check(_goal(w, "village").get("id") == "observatory", "available observatory is suggested even without the swamp path")
	var village_goal := _goal(w, "village")
	check(village_goal.get("site") == "observatory" and str(village_goal.get("local", "")).contains("마을 아래쪽")
		and str(village_goal.text).begins_with("입구"), "entrance and device have separate directions")
	check(w.Guidance.surface_points(w.world.story, w.world.expedition).has(World.Expeditions.PORTALS.village[0]),
		"an actionable observatory gets the village entrance marker")
	w.expedition_action("crystal", "shutter")
	for id in ["pump", "coil", "incident", "pump", "archive"]:
		w.investigate_landmark(id)
	for id in ["diagram", "ground", "return", "supply", "swamp_path"]:
		w.expedition_action("swamp", id)
	w.expedition_action("village", "drainage")
	_reload(w)
	check(_goal(w, "village").id == "observatory", "restored facility changes village goal")
	for id in ["observatory", "table", "lab", "lab"]:
		w.expedition_action("village", id)
	var model := Temple.new()
	model.circuit = 2
	model.pos = Temple.MIRROR
	model.use()
	model.moves = 43
	model.shadow = Vector2i(8, 1)
	model.fear = 74
	model.doses = 1
	model.facing = 2
	w.record_temple(model.checkpoint(), model.endings)
	_reload(w)
	check(_goal(w, "temple").id == "pillar", "only the missing ending is suggested")
	var resumed: RefCounted = Temple.new()
	resumed.restore(w.world.expedition.temple, w.world.expedition)
	check(resumed.pos == Temple.MIRROR and resumed.use().contains("이미"), "recorded ending is not granted again")
	check(resumed.moves == 43 and resumed.shadow == Vector2i(8, 1) and resumed.fear == 74 and resumed.doses == 1
		and resumed.facing == 2 and resumed.circuit == 2, "danger and the pursuit phase survive a save")
	var legacy := Temple.new()
	legacy.restore({"x": 9, "y": 1, "dir": 2, "fear": 54, "doses": 0}, {"mirror": true})
	check(legacy.pos == Temple.MIRROR and legacy.doses == 0 and legacy.fear == 54 and legacy.circuit == 2,
		"legacy missing fields have safe defaults without resetting completed circuits")
	var normalized := Temple.clean_checkpoint({"x": 2, "y": 2, "moves": -1, "shadowX": 0, "shadowY": 0})
	check(normalized.get("moves", -1) == 0 and normalized.get("x") == 1 and normalized.get("shadowX", 0) > 0,
		"malformed or wall coordinates normalize safely")
	resumed.pos = Temple.PILLAR
	resumed.use()
	w.record_temple(resumed.checkpoint(), resumed.endings)
	_reload(w)
	check(w.snapshot().expedition_goals.is_empty(), "completed game shows no repeated task")
	check(w.Guidance.surface_points(w.world.story, w.world.expedition).is_empty(), "all completed markers clear")
	# The alternate ending order must point to the one that remains, even in a legacy save.
	var alternative := World.Expeditions.restore({"pillar": true})
	var last_goal: Dictionary = w.Guidance.goals(true, false, {}, alternative).back()
	check(last_goal.id == "mirror", "pillar-first save keeps the other ending available")
	check(w.snapshot().expedition_stamps.size() == 5, "one stamp per region")
	var reward: Array = w.snapshot().expedition_stamps
	var state: Dictionary = w.world.expedition.duplicate(true)
	w.expedition_action("village", "lab")
	_reload(w)
	check(w.snapshot().expedition_stamps == reward and w.world.expedition == state, "revisiting does not duplicate rewards")
	check(w.state.gold == 0 and w.state.inventory.is_empty(), "non-economic rewards")
	await _test_native_touch()
	await _test_temple_entry_message()
	print("EXPEDITION POLISH PASS" if failures == 0 else "EXPEDITION POLISH FAILED")
	quit(int(failures > 0))

func check(ok: bool, context: String) -> void:
	if not ok:
		failures += 1
		printerr("EXPEDITION POLISH FAIL: ", context)

func _goal(w: Node, region: String) -> Dictionary:
	for row: Dictionary in w.snapshot().expedition_goals:
		if row.region == region:
			return row
	return {}

func _reload(w: Node) -> void:
	var text: String = w.export_save()
	var envelope: Dictionary = JSON.parse_string(text)
	check(envelope.version == 1, "save stays v1")
	w._restore(w.Save.parse_game(text))

func _test_native_touch() -> void:
	var game = root.get_node("Game")
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await process_frame
	await process_frame
	game.enter_expedition("swamp")
	await process_frame
	await process_frame
	var expedition := current_scene
	var right := expedition.get_node("Action_right") as Control
	var point := right.get_global_rect().get_center()
	var previous := Input.emulate_mouse_from_touch
	Input.emulate_mouse_from_touch = false
	_touch(2, point, true)
	check(expedition.room.pos.x == 2, "native touch starts without mouse emulation")
	expedition._process(0.35)
	check(expedition.room.pos.x == 3, "held native touch repeats")
	_touch(3, point, false)
	expedition._process(0.18)
	check(expedition.room.pos.x == 4, "unrelated finger cannot cancel the held direction")
	_drag(2, point + Vector2(0, -65))
	expedition._process(0.6)
	check(expedition.room.pos.x == 4, "leaving the button stops repeat")
	_drag(2, point)
	expedition._process(0.6)
	check(expedition.room.pos.x == 4, "re-entering while held does not restart repeat")
	_touch(2, point, false)
	_touch(2, point, true)
	_touch(2, point, false)
	expedition._process(0.6)
	check(expedition.room.pos.x == 5, "release stops repeat")
	_touch(2, point, true)
	expedition.notification(Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	expedition._process(0.6)
	check(expedition.direction_held.is_empty(), "focus loss clears direction")
	_touch(2, point, false)
	_touch(2, point, true)
	expedition._command("notebook")
	expedition._process(0.6)
	check(expedition.direction_held.is_empty(), "opening the notebook clears direction")
	game._hud.close_workshop()
	_touch(2, point, false)
	_touch(2, point, true)
	expedition._command("exit")
	check(expedition.direction_held.is_empty(), "exiting clears direction before a scene change")
	await process_frame
	await process_frame
	check(current_scene.name == "WorldMap", "surface returns after exit")
	Input.emulate_mouse_from_touch = previous

func _touch(index: int, at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = pressed
	root.push_input(event, true)

func _drag(index: int, at: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = at
	root.push_input(event, true)


## Entering the temple (again, after a save and a reload) shows the line for the saved seal progress, not the
## first visit's: 0/2, 1/2, 2/2 with no ending, one ending, both endings.
func _test_temple_entry_message() -> void:
	var game = root.get_node("Game")
	var w = game.workshop
	w.world.unlock_tunnel()
	var cases := [[0, [] as Array[String]], [1, [] as Array[String]], [2, [] as Array[String]], [2, ["mirror"] as Array[String]], [2, ["mirror", "pillar"] as Array[String]]]
	for c: Array in cases:
		for ending in ["mirror", "pillar"]:
			w.world.expedition.erase(ending)
		var model := Temple.new()
		model.restore({})
		model.circuit = c[0]
		w.record_temple(model.checkpoint(), c[1])
		_reload(w)
		change_scene_to_file("res://scenes/world/world_map.tscn")
		await process_frame
		await process_frame
		game.enter_expedition("temple")
		await process_frame
		await process_frame
		var expedition := current_scene
		var text: String = expedition.message.text
		var goal: Dictionary = w.Guidance._temple(w.world.expedition)
		var where := "seal %d/2, endings %s" % [c[0], c[1]]
		check(int(expedition.temple.circuit) == c[0], "temple restores %s" % where)
		check(text == (str(goal.local) if not goal.is_empty() else "두 결말을 모두 보았다 · 지상으로 돌아가자"), "entry line follows the journal objective at %s (%s)" % [where, text])
		check(c[0] == 0 or not text.contains("벽화"), "no warning-mural line once a seal is connected at %s (%s)" % [where, text])
		game.leave_expedition()
		await process_frame
		await process_frame
