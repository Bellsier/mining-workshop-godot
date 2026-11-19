extends SceneTree
const Workshop = preload("res://scripts/workshop.gd")
const World = preload("res://scripts/world/world_state.gd")
var failures := 0
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		printerr("INTEGRATION FAIL ", label)
func _run() -> void:
	var g = Workshop.new()
	g.persistence_enabled = false
	root.add_child(g)
	g.set_process(false)
	check(g.get("world") != null, "economy owns persistent world")
	if g.get("world") == null:
		g.free()
		quit(1)
		return
	var w = g.world
	var hidden: String = w.hidden_ids[0]
	check(not g.mine_vein(hidden), "hidden vein cannot be mined")
	var iron = w.mines.filter(func(m): return m.resource == "iron")[0]
	w.discover(iron.id)
	check(not g.mine_vein(iron.id) and g.vein_action(iron.id) == "secure", "a found vein is secured before it is mined (web interact)")
	check(g.secure_vein(iron.id) and g.vein_action(iron.id) == "mine", "the found iron vein is secured")
	var iron_before := float(g.state.inventory.get("iron", 0.0))
	check(g.mine_vein(iron.id) and float(g.state.inventory.iron) == iron_before + float(iron.miningPower) * g._multiplier(),
		"a secured vein mines miningPower times the multiplier")
	g.state.gold = 300000.0
	g.state.inventory.merge({"alloy": 5.0, "manaLamp": 4.0, "steelGear": 5.0, "crystalLens": 3.0}, true)
	# The tunnel job runs on real time (web tunnelContract): the test drives the game's clock.
	g.clock_override_ms = 1000000.0
	check(not g.order_tunnel(), "research required for construction")
	check(g.unlock("tunnelWork") and not w.tunnel_unlocked, "research alone does not open tunnel")
	check(g.order_tunnel() and not g.order_tunnel(), "commission paid only once")
	check(g.state.tunnel_remaining == 600.0 and g.world.tunnel_contract.startedAt == 1000000.0, "original construction duration")
	g.clock_override_ms += 100000.0
	g._tick()
	var running_save: String = g.export_save()
	var paid_gold: float = g.state.gold
	check(g.import_save(running_save), "active construction imports")
	w = g.world
	g._tick()
	check(absf(g.state.tunnel_remaining - 500.0) < 0.001 and g.state.gold == paid_gold and not g.order_tunnel(), "construction remaining time and payment survive restore")
	g.clock_override_ms += 499900.0
	g._tick()
	check(not w.tunnel_unlocked, "no early opening")
	g.clock_override_ms += 100.0
	g._tick()
	check(w.tunnel_unlocked, "completion opens world")
	check(g.unlock("explorationGear") and w.discovery_radius() == 4.0, "exploration radius")
	var before: int = w.mines.size()
	var survey_events := []
	if w.has_signal("survey_completed"):
		w.survey_completed.connect(func(added): survey_events.append(added.size()))
	check(g.unlock("geologicalSurvey") and w.mines.size() == before + 3, "survey adds three")
	check(survey_events == [3], "survey notifies rendered world once with three new veins")
	var snapshot: Dictionary = w.to_dict()
	g.state.position = {"scene": "res://scenes/world/world_map.tscn", "x": -500.5, "y": 64.25}
	var exported: String = g.export_save()
	check(not exported.is_empty(), "export is JSON serializable")
	if exported.is_empty():
		_bad(g.state, "state")
		g.free()
		quit(1)
		return
	check(g.import_save(exported), "native import")
	check(g.world.to_dict() == snapshot and g.world.discovery_radius() == 4.0, "world and research survive reload without duplicates")
	check(g.state.position.x == -500.5 and g.state.position.y == 64.25, "fractional world position restored")
	var bad: Dictionary = JSON.parse_string(exported).state
	bad.world.base.x = []
	check(not g._valid_save_state(bad), "malformed base is rejected before world restoration")
	var legacy_bad := {"saveVersion": 1, "run": {"gold": 99, "resources": {}, "products": {}, "world": {"mines": "broken"}}}
	check(not g._valid_save_state(g.Save.import_legacy(JSON.stringify(legacy_bad))), "legacy malformed world rejected before restore")
	var invalid: Dictionary = JSON.parse_string(exported)
	invalid.state.world.mines = "broken"
	check(not g.import_save(JSON.stringify(invalid)) and g.world.to_dict() == snapshot, "invalid map preserves existing world")
	var old := '{"version":1,"state":{"gold":12,"inventory":{"iron":7},"position":{"scene":"res://scenes/overworld.tscn","x":728,"y":200}}}'
	check(g.import_save(old) and g.state.inventory.iron == 7, "old economy preserved")
	check(g.state.position.is_empty(), "old trial coordinates do not leak into unified map")
	var legacy_ok := {"saveVersion": 1, "run": {"gold": 13, "resources": {"iron": 8}, "products": {}, "world": snapshot}}
	check(g.import_save(JSON.stringify(legacy_ok)) and g.world.to_dict() == snapshot and g.state.inventory.iron == 8, "valid legacy world and economy preserved")
	legacy_ok.run.world = {"tunnelUnlocked": true}
	check(g.import_save(JSON.stringify(legacy_ok)) and g.world.tunnel_unlocked and g.world.mines.size() > 2, "partial old world upgrades to a playable map")
	g.free()
	World.set_current(null)
	if failures == 0: print("WORLD INTEGRATION PASS")
	quit(int(failures > 0))

func _bad(v: Variant, path: String) -> void:
	if v is Dictionary:
		for k in v:
			if not k is String: print("BAD KEY ", path, " ", k, " type ", typeof(k))
			_bad(v[k], path + "." + str(k))
	elif v is Array:
		for item in v: _bad(item, path + "[]")
	elif not (v == null or v is bool or v is int or v is float or v is String):
		print("BAD VALUE ", path, " ", v)
