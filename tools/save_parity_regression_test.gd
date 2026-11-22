extends SceneTree
## Runs with MINING_QA_ISOLATED=1 and an empty XDG_DATA_HOME.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
const Exact = preload("res://scripts/exact_json.gd")
const FIXTURE := "res://tests/fixtures/js_save_v1_full_world.json"
const PRODUCT := "crystalAlloy"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var isolated := OS.get_environment("XDG_DATA_HOME")
	if OS.get_environment("MINING_QA_ISOLATED") != "1" or isolated.is_empty() \
			or not OS.get_user_data_dir().begins_with(isolated + "/") or not DirAccess.get_files_at("user://").is_empty():
		printerr("Requires an empty, isolated Godot data directory")
		quit(1)
		return
	_test_queue()
	_test_partial_world()
	_test_idle_timers()
	_test_delivery_boundaries()
	_test_automatic_sale()
	_test_envelopes()
	if failures.is_empty():
		print("SAVE PARITY REGRESSION PASS")
	else:
		printerr("SAVE PARITY REGRESSION FAIL ", failures.size())
	quit(0 if failures.is_empty() else 1)


func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		printerr("FAIL ", label)


func _game(persistent := false) -> Node:
	var game := Workshop.new()
	game.persistence_enabled = persistent
	root.add_child(game)
	game.set_process(false)
	return game


func _fixture() -> Dictionary:
	return Exact.parse(FileAccess.get_file_as_string(FIXTURE)).value


func _restart(game: Node) -> Node:
	game.flush(true)
	game.free()
	return _game(true)


func _test_queue() -> void:
	var payload := _fixture()
	payload.run.world.tunnelContract = null
	payload.run.craftQueue[PRODUCT] = 0
	payload.run.autoCraft[PRODUCT] = true
	payload.run.craftTarget[PRODUCT] = 61
	var game := _game(true)
	check(game.import_save(Exact.stringify(payload)), "legacy queue imports")
	game = _restart(game)
	check(game.state.queue.get(PRODUCT) == 0, "legacy zero seconds survives disk restart")
	for i in 4:
		game._process(0.1)
	game = _restart(game)
	game._process(0.1)
	check(game.state.inventory[PRODUCT] == 61 and not game.state.queue.has(PRODUCT),
		"zero seconds awards exactly once with auto-craft, including after restart")
	game.free()

	for sample in [
		{"queue": {PRODUCT: 2.0}, "running": true},
		{"queue": {PRODUCT: -1}},
		{"queue": {PRODUCT: null}},
		{"queue": {PRODUCT: "2"}},
		{"queue": null},
		{"queue": {"unknownRecipe": 0}},
		{},
	]:
		game = _game()
		var candidate := {"gold": 93, "inventory": {PRODUCT: 3}, "completed_research": {"workshopBuild": true}}
		candidate.merge(sample)
		check(game.import_save(Exact.stringify({"version": 1, "state": candidate})), "native queue recovers %s" % sample)
		if sample.get("running", false):
			game._tick()
			check(float(game.state.queue.get(PRODUCT, -1)) < 2 and float(game.state.queue.get(PRODUCT, -1)) > 0,
				"positive queue counts down normally")
		else:
			for i in 4:
				game._tick()
			check(game.state.queue.is_empty(), "invalid or empty native queue stays empty %s" % sample)
		check(game.state.gold == 93 and game.state.inventory.get(PRODUCT) == 3 and game.state.completed_research.get("workshopBuild") == true,
			"queue repair preserves inventory and research %s" % sample)
		game.free()

	game = _game(true)
	var mixed := {"gold": 1, "inventory": {PRODUCT: 3}, "queue": {PRODUCT: -1, "ironTool": 2}}
	check(game.import_save(Exact.stringify({"version": 1, "state": mixed})), "mixed native queue imports")
	game = _restart(game)
	check(game.state.queue == {"ironTool": 2.0} and game.state.inventory[PRODUCT] == 3,
		"repair only discards the damaged entry across a restart")
	game.free()


func _test_partial_world() -> void:
	var payload := _fixture()
	var game := _game(true)
	var saved_world: Dictionary = payload.run.world.duplicate(true)
	payload.run.world.erase("mines")
	payload.run.world.erase("hiddenMineIds")
	var raw := (Exact.stringify(payload) + "\r\n").to_utf8_buffer()
	check(game.import_save_bytes(raw), "legacy world without a mine list imports")
	game = _restart(game)
	check(game.world.base_level == 3 and game.world.base == Vector2i(2, 0), "prior base survives missing mines and disk restart")
	check(game.world.mines.is_empty() and game.world.hidden_ids.is_empty(), "missing mines follow the JS empty-list rule")
	check(game.world.tunnel_contract == saved_world.tunnelContract, "active tunnel work survives")
	check(game.world.workshops.size() == 2 and game.world.torches.size() == 2 and game.state.village.decor.size() == 3,
		"workshops, torches and the village layout survive")
	check(game.state.position.get("x") == 168 and game.state.position.get("y") == -28, "player position survives")
	check(game.legacy_original_bytes() == raw and game.legacy_original_info().sha256 == Save.sha256_hex(raw),
		"world recovery keeps bytes and hash")

	payload.run.world = saved_world.duplicate(true)
	payload.run.world.erase("hiddenMineIds")
	check(game.import_save(Exact.stringify(payload)) and game.world.mines.size() == saved_world.mines.size() and game.world.hidden_ids.is_empty(),
		"missing hidden list makes all existing mines discovered")
	payload.run.world.tunnelUnlocked = true
	payload.run.world.mines.append("damaged")
	payload.run.world.mines.append({"id": "outside", "x": 155, "y": 3, "resource": "iron"})
	payload.run.world.mines.append(payload.run.world.mines[0])
	payload.run.world["hiddenMineIds"] = ["outside", "missing"]
	check(game.import_save(Exact.stringify(payload)) and game.world.tunnel_unlocked and game.world.mines.size() == saved_world.mines.size()
		and game.world.hidden_ids.is_empty(), "partial mine damage keeps valid veins and the open tunnel without duplicates")
	payload.run.world.mines = "damaged list"
	check(game.import_save(Exact.stringify(payload)) and game.world.base_level == 3 and game.world.tunnel_unlocked
		and game.world.mines.is_empty(), "malformed mine list with a usable base preserves progress")
	var previous := Save.read_raw()
	payload.run.world.base.x = []
	check(not game.import_save(Exact.stringify(payload)) and Save.read_raw() == previous, "unsafe base keeps the previous disk save")
	game.free()


func _idle_payload() -> Dictionary:
	var payload := _fixture()
	for vein: Dictionary in payload.run.world.mines:
		vein.developmentState = "unsecured"
	payload.run.characters = []
	payload.run.workforce = {}
	payload.run.autoCraft = {}
	payload.run.autoSell = {}
	payload.run.products = {}
	payload.run.world.workshops = []
	payload.run.world.tunnelContract = null
	var forge: Dictionary = payload.permanent.companies.forge
	forge.score = 500
	forge.orderTimer = 30
	forge.tradeTimer = 10
	forge.open.resize(1)
	return payload


func _test_idle_timers() -> void:
	var game := _game(true)
	check(game.import_save(Exact.stringify(_idle_payload())), "idle legacy save imports")
	game.snapshot()
	game._mark_dirty()
	game.flush(true)
	for frame in 101:
		game._process(0.1)
	var live: Dictionary = game.state.delivery.companies.forge
	var durable: Dictionary = Save.load_game().delivery.companies.forge
	check(is_equal_approx(durable.orderTimer, 40) and is_equal_approx(durable.tradeTimer, 20),
		"timer-only progress autosaves before a forced flush")
	game._on_page_hidden([])
	game.free()
	game = _game(true)
	var resumed: Dictionary = game.state.delivery.companies.forge
	check(is_equal_approx(resumed.orderTimer, live.orderTimer) and is_equal_approx(resumed.tradeTimer, live.tradeTimer),
		"page hide saves idle timer progress through restart")
	game.free()


func _test_delivery_boundaries() -> void:
	var payload := _idle_payload()
	var forge: Dictionary = payload.permanent.companies.forge
	forge.tradeTimer = 59.95
	forge.orderTimer = 899.95 # at 18 reputation, second slot arrives at 900 s
	payload.run.products["steel"] = 20
	var game := _game(true)
	check(game.import_save(Exact.stringify(payload)), "delivery boundary imports")
	game = _restart(game)
	game._process(0.1)
	var bought_gold: float = game.state.gold
	check(game.state.inventory.get("steel") == 15 and game.state.delivery.companies.forge.open.size() == 2 and bought_gold > payload.run.gold,
		"trade and order trigger once after restart")
	game = _restart(game)
	for frame in 25:
		game._process(0.1)
	check(game.state.inventory.get("steel") == 15 and game.state.gold == bought_gold and game.state.delivery.companies.forge.open.size() == 2,
		"confirmed trade and order are not repeated after restart")
	game.free()



func _test_automatic_sale() -> void:
	var payload := _fixture()
	payload.run.world.tunnelContract = null
	payload.run.autoSell = {"coalBrick": true, "steel": true, "alloy": true, "specialAlloy": true}
	payload.run.autoSellOn = {"steel": false, "alloy": true, "specialAlloy": true, "manaLamp": true}
	var game := _game(true)
	check(game.import_save(Exact.stringify(payload)), "older sale settings import")
	game = _restart(game)
	game._process(0.1)
	# JS tickAutoSell with the same 7484ccd fixture and these flags.
	check(game.state.inventory.coalBrick == 0 and game.state.inventory.alloy == 0
		and game.state.inventory.steel == 40 and game.state.inventory.specialAlloy == 60 and game.state.inventory.manaLamp == 61,
		"missing/true/false/locked/workshop-only sale rules apply independently")
	check(game.state.gold == 157903.89599999998, "automatic sale gold follows source without rounding")
	game = _restart(game)
	check(game.state.automation.sell.get("steel") == false and game.state.automation.sell.get("coalBrick") == true,
		"explicit false and restored default survive native save")
	game.free()


func _test_envelopes() -> void:
	var payload := _fixture()
	payload.run.erase("resources")
	var raw := Exact.stringify(payload)
	var game := _game(true)
	check(game.import_save(raw) and not game.state.inventory.has("iron") and game.state.inventory.steel == 40,
		"plain JS v1 with missing resources retains existing products")
	payload = _fixture()
	var snapshot := {"format": 1, "savedAt": payload.savedAt, "payload": payload, "name": "공방"}
	var row := {"revision": 1, "snapshot": snapshot}
	var bytes := (Exact.stringify(row) + "\r\n").to_utf8_buffer()
	check(game.import_save_bytes(bytes) and game.legacy_original_bytes() == bytes, "S2 row and metadata round-trip exactly")
	var good := Save.read_raw()
	var archived := {"snapshot": {"format": 1, "payload": {"saveVersion": 1, "run": payload.run}}}
	var old_bytes := Exact.stringify(archived).to_utf8_buffer()
	var old_godot := Save.parse_game(good)
	old_godot[Save.LEGACY_BYTES] = Marshalls.raw_to_base64(old_bytes)
	old_godot[Save.LEGACY_SHA256] = Save.sha256_hex(old_bytes)
	old_godot["legacy_web_save"] = archived.snapshot.payload
	check(game.import_save(Save.export_game(old_godot)) and game.legacy_original_bytes() == old_bytes,
		"old native saves keep previously accepted S2 original bytes")
	var malformed := [
		{"snapshot": snapshot, "revision": 0},
		{"format": 2, "payload": payload},
		{"format": 1, "payload": {"saveVersion": 1, "run": payload.run, "savedAt": 0}},
		{"saveVersion": 1, "run": []},
		{"saveVersion": 2, "run": payload.run},
	]
	for invalid in malformed:
		var before := Save.read_raw()
		check(not game.import_save(Exact.stringify(invalid)) and Save.read_raw() == before,
			"invalid envelope does not replace active storage: %s" % [invalid.keys()])
	for text in ['{"saveVersion": 1, "run":{"gold": 1e999}}', '{"saveVersion": 1, "run": {']:
		var before := Save.read_raw()
		check(not game.import_save(text) and Save.read_raw() == before, "invalid number or JSON protects disk")
	game.free()
