extends SceneTree

const World := preload("res://scripts/world/world_state.gd")
const Regions := preload("res://scripts/expedition/regions.gd")
const Temple := preload("res://scripts/expedition/temple.gd")
const SURFACE := "res://scenes/world/world_map.tscn"
const GATE := Vector2i(6, 3)
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, context: String) -> void:
	if not value:
		failures += 1
		printerr("EXPEDITION FAIL: ", context)

func _run() -> void:
	var workshop = root.get_node("Game").workshop
	if not workshop.has_method("expedition_action"):
		check(false, "expedition actions are missing")
		quit(1)
		return
	_test_regions(workshop)
	_test_temple(workshop)
	await _test_surface()
	print("EXPEDITION PASS" if failures == 0 else "EXPEDITION FAILED")
	quit(int(failures > 0))

func _test_regions(workshop: Node) -> void:
	var old: Dictionary = World.new_game(42).to_dict()
	old.erase("expedition")
	workshop._restore({"world": old, "gold": 700})
	check(workshop.world.expedition.is_empty(), "old save defaults")
	check(workshop.expedition_action("forest", "tracks") == "", "closed tunnel")
	workshop.world.unlock_tunnel()
	check(workshop.expedition_action("forest", "marks") == "", "surface trace needed")
	workshop.world.story = {"tracks": true, "ledger": true, "seal": true, "last": true,
		"pump": true, "coil": true, "incident": true, "repaired": true, "archive": true}
	check(not Regions.can_walk("forest", GATE, workshop.world.expedition), "root initially closed")
	check(not Regions.can_walk("swamp", GATE, workshop.world.expedition), "flooded causeway closed")
	check(not Regions.can_walk("crystal", GATE, workshop.world.expedition), "crystal passage closed")
	workshop.expedition_action("forest", "marks")
	workshop.expedition_action("forest", "root")
	check(not workshop.world.expedition.has("forest_step"), "wrong first press resets")
	workshop.expedition_action("forest", "moss")
	_reload(workshop)
	check(workshop.world.expedition.get("forest_step") == 1, "partial forest puzzle saves")
	workshop.expedition_action("forest", "root")
	workshop.expedition_action("forest", "moss")
	check(Regions.can_walk("forest", GATE, workshop.world.expedition), "forest gate opens")
	check(not Regions.allowed("crystal", workshop.world.story, workshop.world.expedition), "inspect the area beyond a gate first")
	workshop.expedition_action("swamp", "diagram")
	workshop.expedition_action("swamp", "return")
	check(not workshop.world.expedition.has("swamp_step"), "swamp wrong order")
	for id in ["ground", "return", "supply"]:
		workshop.expedition_action("swamp", id)
	check(Regions.can_walk("swamp", GATE, workshop.world.expedition), "swamp water drains")
	workshop.expedition_action("swamp", "swamp_path")
	workshop.expedition_action("crystal", "shutter")
	check(not workshop.world.expedition.has("rescued"), "shutter does not skip discovery")
	workshop.expedition_action("crystal", "signal")
	workshop.expedition_action("crystal", "west")
	workshop.expedition_action("crystal", "east")
	check(not workshop.world.expedition.has("crystal_open"), "incorrect reflection")
	workshop.expedition_action("crystal", "east")
	check(Regions.can_walk("crystal", GATE, workshop.world.expedition), "both mirrors aligned")
	workshop.expedition_action("crystal", "shutter")
	_reload(workshop)
	check(workshop.world.expedition.has("alive") and not workshop.world.expedition.has("rescued"), "confirmed alive before rescue")
	workshop.expedition_action("crystal", "shutter")
	workshop.expedition_action("village", "table")
	for id in ["drainage", "observatory", "table", "lab", "lab"]:
		workshop.expedition_action("village", id)
	_reload(workshop)
	check(workshop.world.expedition.has("research") and workshop.world.expedition.has("calibration"), "scientist and village research")
	var corrupt := Regions.restore({"forest_open": true, "research": true, "crystal_open": true,
		"swamp_step": "bad", "west": 1.5, "rescued": true, "unknown": true})
	check(corrupt.is_empty(), "impossible or malformed progress is safely discarded")
	check(workshop.state.gold == 700 and workshop.state.inventory.is_empty(), "existing economy untouched")

func _test_temple(workshop: Node) -> void:
	var model := Temple.new()
	check(not model.is_floor(Vector2i(0, 0)), "walls block")
	check(model.use().contains("벽화"), "starting warning")
	model.turn(1)
	_reload(workshop)
	check(model.step(1), "walk down the first corridor")
	workshop.record_temple(model.checkpoint(), model.endings)
	_reload(workshop)
	var resumed := Temple.new()
	resumed.restore(workshop.world.expedition.get("temple"))
	check(resumed.pos == model.pos and resumed.facing == model.facing, "checkpoint round trip")
	model.fear = 50.0
	model.medicate()
	check(model.fear < 50.0 and model.doses < 2, "finite medication reduces hallucination")
	model.pos = model.MIRROR
	check(not model.use().is_empty() and model.endings.is_empty(), "ending needs the circuit")
	model.pos = model.CIRCUIT_A
	model.use()
	model.pos = model.CIRCUIT_B
	model.use()
	model.pos = model.MIRROR
	model.use()
	model.pos = model.PILLAR
	model.use()
	check(model.endings == ["mirror", "pillar"], "both endings recorded once")
	model.use()
	check(model.endings.size() == 2, "revisiting cannot duplicate ending")
	workshop.record_temple(model.checkpoint(), model.endings)
	_reload(workshop)
	check(workshop.world.expedition.has("mirror") and workshop.world.expedition.has("pillar"), "endings survive save")
	check(Temple.clean_checkpoint({"x": 2, "y": 2}).x == 1, "invalid checkpoint resets to entry")
	var lost := Temple.new()
	lost.fear = 64.0
	lost.facing = 1
	lost.moves = 3
	check(not lost.step(1) and lost.step(1), "distorted input that hits a wall can be retried")
	lost.shadow = Vector2i(3, 1)
	lost.pos = Vector2i(1, 1)
	lost.facing = 0
	lost.fear = 0.0
	lost.moves = 2
	lost.step(1)
	check(lost.fear >= 20.0, "pursuer closes the gap and contact raises hallucination")
	lost.recover_at_entrance()
	check(lost.pos == Temple.ENTRY and lost.fear < 60, "recovery at a walkable entrance")

func _reload(w: Node) -> void:
	w._restore(w.Save.parse_game(w.export_save()))

func _test_surface() -> void:
	var game = root.get_node("Game")
	var workshop = game.workshop
	check(Regions.allowed("forest", {"last": true}, {}), "forest can be first")
	check(Regions.allowed("swamp", {"archive": true}, {}), "swamp can be first")
	for seed: int in [42, 31415, 2026]:
		var old := World.new_game(seed)
		old.unlock_tunnel()
		var restored: Dictionary = workshop.Save.parse_game(workshop.export_save())
		var layout: Dictionary = old.to_dict()
		layout["regionStory"] = restored.world.regionStory
		layout["expedition"] = restored.world.expedition
		workshop._restore({"world": layout})
		change_scene_to_file(SURFACE)
		await _frames()
		var map = current_scene.get_node("World")
		var player = current_scene.get_node("Player")
		var queue: Array[Vector2i] = [Vector2i(-416, 64)]
		var visited := {queue[0]: true}
		var found := {}
		var index := 0
		var bounds := Rect2i(-640, -630, 256, 1260)
		while index < queue.size() and found.size() < Regions.PORTALS.size():
			var point := queue[index]
			index += 1
			var target: Dictionary = map.find_target(Vector2(point) / 64.0, "down")
			if target.get("type") == "expedition":
				found[target.id] = point
			for direction: Vector2i in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
				var step := direction * 8
				var next := point + step
				if bounds.has_point(next) and not visited.has(next) and not player.test_move(Transform2D(0, Vector2(point)), Vector2(step)):
					visited[next] = true
					queue.append(next)
		check(found.size() == Regions.PORTALS.size(), "reachable entrances for seed %d: %s" % [seed, found.keys()])
		if seed == 42 and found.has("temple"):
			var return_to := Vector2(found.temple)
			player.position = return_to
			var context: String = map.context_at(player.position)
			map.interact(context)
			await _frames()
			check(current_scene.name == "Expedition" and game.workshop.player == null and not game._hud.visible,
				"portal opens isolated mode")
			current_scene._command("exit")
			await _frames()
			check(current_scene.name == "WorldMap" and game.workshop.player.position.distance_to(return_to) < 0.1 and game._hud.visible,
				"exact safe return to surface")

func _frames() -> void:
	for i in 4:
		await process_frame
		await physics_frame
