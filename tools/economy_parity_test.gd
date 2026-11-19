extends SceneTree
## The economy against the web original (gacha-factory-development 7484ccd), number for number:
##   godot --headless --path . --script res://tools/economy_parity_test.gd
## Expected values come from the original JS, run by tools/parity/make_economy_fixtures.cjs.
## 1. 70 ticks of workers, workforce, secured veins, HQ and reputation multiplier, recipe cards (queue,
##    automation in recipe order, craft target, craft speed) and auto-sell: gold, stock and queue every 7 ticks.
## 2. Worker stat upgrade costs, the worker cap per base level, the manual and vein hauls.
## 3. Base expansion: the next area, the base level and the seed veins next to the base.
## 4. Securing veins: found, and the area open.
## 5. Every HUD tab renders.
## Prints "ECONOMY PARITY PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Hud = preload("res://scripts/workshop_hud.gd")
const ExactJson = preload("res://scripts/exact_json.gd")
const WEB := "res://tests/fixtures/economy_web_fixtures.json"

var _failures: Array[String] = []
var _web: Dictionary


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_web = ExactJson.parse(FileAccess.get_file_as_string(WEB)).value
	_check(str(_web.source.commit).begins_with("7484ccd"), "the fixture comes from the web original 7484ccd")
	_tick_matches_web()
	_costs_match_web()
	_expansion_matches_web()
	_securing_matches_web()
	await _every_tab_renders()
	if _failures.is_empty():
		print("ECONOMY PARITY PASS")
		quit(0)
	else:
		print("ECONOMY PARITY FAIL %d" % _failures.size())
		quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("ECONOMY PARITY FAIL ", what)


func _game() -> Node:
	var game: Node = Workshop.new()
	game.persistence_enabled = false
	root.add_child(game)
	game.set_process(false)
	return game


## A Godot game holding the web run state `run` (resources and products share the inventory).
func _load_run(game: Node, run: Dictionary, prestige: int) -> void:
	var s: Dictionary = game.state
	s.gold = float(run.gold)
	s.inventory = {}
	for key: String in run.resources:
		s.inventory[key] = float(run.resources[key])
	for key: String in run.products:
		s.inventory[key] = float(run.products[key])
	s.facility = run.facility.duplicate()
	s.workforce = run.workforce.duplicate()
	s.unlocked_sites = run.unlockedSites.duplicate()
	s.completed_research = run.research.duplicate()
	s.characters = run.characters.duplicate(true)
	s.hq_level = int(run.hqLevel)
	s.craft_facility = int(run.craftFacility)
	s.queue = {}
	for key: String in run.craftQueue:
		if run.craftQueue[key] != null:
			s.queue[key] = float(run.craftQueue[key])
	s.automation = {"craft": run.autoCraft.duplicate(), "target": run.craftTarget.duplicate(),
		"sell_owned": run.autoSell.duplicate(), "sell": run.autoSellOn.duplicate()}
	s["delivery"] = {"reputation": prestige, "companies": {}}
	s.first_ticket = true
	game.world.base = Vector2i(int(run.world.base.x), int(run.world.base.y))
	game.world.base_level = int(run.world.base.level)
	game.world.mines = run.world.mines.duplicate(true)
	game.world.hidden_ids.clear()
	for id in run.world.hiddenMineIds:
		game.world.hidden_ids.append(str(id))


# --- 1. the tick ---------------------------------------------------------------------------------------------

func _tick_matches_web() -> void:
	var game := _game()
	_load_run(game, _web.tick.start, int(_web.tick.prestige))
	_check(game._multiplier() == float(_web.tick.mult), "the multiplier equals the web mult(): %s vs %s" % [game._multiplier(), _web.tick.mult])
	for key: String in _web.tick.rates:
		_check(game.auto_rate(key) == float(_web.tick.rates[key]), "autoRate(%s): %s vs web %s" % [key, game.auto_rate(key), _web.tick.rates[key]])
	var done := 0
	for frame: Dictionary in _web.tick.frames:
		while done < int(frame.tick):
			game._tick()
			done += 1
		_check(float(game.state.gold) == float(frame.gold), "tick %d gold %s vs web %s" % [done, game.state.gold, frame.gold])
		for table in ["resources", "products"]:
			for key: String in frame[table]:
				var have := float(game.state.inventory.get(key, 0.0))
				_check(have == float(frame[table][key]), "tick %d %s %s vs web %s" % [done, key, have, frame[table][key]])
		var queue := {}
		for key: String in game.state.queue:
			queue[key] = float(game.state.queue[key])
		var expected := {}
		for key: String in frame.queue:
			expected[key] = float(frame.queue[key])
		_check(queue == expected, "tick %d craft queue %s vs web %s" % [done, queue, expected])
	game.free()


# --- 2. costs and limits -------------------------------------------------------------------------------------

func _costs_match_web() -> void:
	var game := _game()
	for row: Dictionary in _web.worker_upgrade:
		var cost: int = game.worker_upgrade_cost({row.stat + "Lvl": int(row.level)}, str(row.stat))
		_check(cost == int(row.cost), "worker %s upgrade from Lv.%d: %d vs web %d" % [row.stat, int(row.level), cost, int(row.cost)])
	for row: Dictionary in _web.worker_cap:
		game.world.base_level = int(row.level)
		_check(game.worker_cap() == int(row.cap), "worker cap at base Lv.%d: %d vs web %d" % [int(row.level), game.worker_cap(), int(row.cap)])
	game.world.base_level = 1
	var manual: Dictionary = _web.manual
	game.state.hq_level = int(manual.hq)
	game.state["delivery"] = {"reputation": int(manual.prestige), "companies": {}}
	game.state.facility = {"iron": int(manual.facility_iron)}
	_check(game._multiplier() == float(manual.mult), "mult with HQ %d and reputation %d" % [int(manual.hq), int(manual.prestige)])
	game.state.inventory = {}
	game.mine("iron")
	game.mine("coal")
	_check(float(game.state.inventory.iron) == float(manual.iron) and float(game.state.inventory.coal) == float(manual.coal),
		"manual haul: iron %s coal %s vs web %s %s" % [game.state.inventory.iron, game.state.inventory.coal, manual.iron, manual.coal])
	var vein := {"id": "v", "x": 4, "y": 0, "resource": "iron", "grade": 1, "miningPower": int(manual.vein.miningPower), "developmentState": "secured"}
	game.world.mines = [vein]
	game.world.hidden_ids.clear()
	game.state.inventory.iron = 0.0
	_check(game.mine_vein("v") and float(game.state.inventory.iron) == float(manual.vein.amount), "vein haul: %s vs web %s" % [game.state.inventory.iron, manual.vein.amount])
	# Worker upgrades pay gold and raise the stat, at most STAT_MAX_LEVEL times.
	game.state.gold = 1e6
	game.state.characters = [{"id": "w1", "rarity": "common", "resource": "iron", "mining": 1, "carry": 2, "move": 1, "miningLvl": 0, "carryLvl": 0, "moveLvl": 0}]
	for i in 3:
		_check(game.upgrade_worker("w1", "mining"), "worker mining upgrade %d" % (i + 1))
	_check(not game.upgrade_worker("w1", "mining") and float(game.state.characters[0].mining) == 4.0 and game.state.characters[0].miningLvl == 3,
		"a stat stops at its top level")
	_check(float(game.state.gold) == 1e6 - 200 - 270 - 365, "the upgrades cost 200, 270 and 365 G")
	game.free()


# --- 3. expanding the base -----------------------------------------------------------------------------------

func _expansion_matches_web() -> void:
	var game := _game()
	game.state.gold = 1e7
	game.state.inventory = {"steel": 50.0, "manaLamp": 5.0, "crystalLens": 5.0, "steelGear": 5.0, "relicOrnament": 5.0}
	game.state.unlocked_sites = {"abandonedMine": true}
	game.world.base = Vector2i(2, 0)
	game.world.base_level = 1
	game.world.mines = [{"id": "mine_x", "x": 2, "y": 6, "resource": "iron", "grade": 1, "miningPower": 1, "developmentState": "unsecured"}]
	game.world.hidden_ids.clear()
	var step := 0
	for row: Dictionary in _web.expand:
		step += 1
		var ok: bool = game.expand_base()
		_check(ok == bool(row.ok), "expansion %d returns %s like the web" % [step, ok])
		_check(game.world.base_level == int(row.level) and float(game.state.gold) == float(row.gold),
			"expansion %d: base Lv.%d, %s G (web Lv.%d, %s G)" % [step, game.world.base_level, game.state.gold, int(row.level), row.gold])
		for key: String in row.sites:
			_check(game.state.unlocked_sites.get(key, false) == row.sites[key], "expansion %d: %s open like the web" % [step, key])
		var mines: Array = []
		for m: Dictionary in game.world.mines:
			mines.append([m.id, int(m.x), int(m.y), m.resource, int(m.grade), int(m.miningPower), m.developmentState])
		var expected: Array = []
		for m: Dictionary in row.mines:
			expected.append([m.id, int(m.x), int(m.y), m.resource, int(m.grade), int(m.miningPower), m.developmentState])
		_check(mines == expected, "expansion %d veins:\n   godot %s\n   web   %s" % [step, mines, expected])
		for key: String in row.products:
			_check(float(game.state.inventory.get(key, 0)) == float(row.products[key]), "expansion %d: %s left like the web" % [step, key])
	game.free()


# --- 4. securing veins ---------------------------------------------------------------------------------------

func _securing_matches_web() -> void:
	var game := _game()
	game.state.unlocked_sites = {"abandonedMine": true}
	game.world.mines = [
		{"id": "a", "x": 4, "y": 0, "resource": "iron", "grade": 1, "miningPower": 1, "developmentState": "unsecured"},
		{"id": "b", "x": 5, "y": 0, "resource": "mana", "grade": 2, "miningPower": 1, "developmentState": "unsecured"},
		{"id": "c", "x": 6, "y": 0, "resource": "coal", "grade": 1, "miningPower": 1, "developmentState": "unsecured"},
	]
	game.world.hidden_ids.clear()
	game.world.hidden_ids.append("c")
	for row: Dictionary in _web.secure:
		var ok: bool = game.secure_vein(str(row.id))
		_check(ok == bool(row.ok) and game.world.mine_by_id(str(row.id)).developmentState == row.state,
			"securing %s: %s/%s, web %s/%s" % [row.id, ok, game.world.mine_by_id(str(row.id)).developmentState, row.ok, row.state])
	_check(game.vein_action("a") == "mine" and game.vein_action("b") == "locked" and game.vein_action("c") == "",
		"E at a vein: mine when secured, locked when its area is closed, nothing while hidden")
	game.free()


# --- 5. the HUD ----------------------------------------------------------------------------------------------

func _every_tab_renders() -> void:
	var game := _game()
	_load_run(game, _web.tick.start, int(_web.tick.prestige))
	game.state.tickets = 2
	game.hire("ticket")
	var hud: CanvasLayer = Hud.new()
	root.add_child(hud)
	hud.setup(game)
	hud.open_workshop()
	for tab in Hud.TABS.size():
		hud._active_tab = tab
		hud._refresh(true)
		await process_frame
		_check(hud._rows.get_child_count() > 0, "the %s tab shows something" % Hud.TABS[tab])
	hud._active_tab = Hud.TAB_MINING
	hud._refresh(true)
	var texts := _labels(hud._rows)
	_check(texts.any(func(t: String) -> bool: return t.begins_with("거점 Lv.")), "the 채굴 tab shows the base")
	_check(texts.any(func(t: String) -> bool: return t.contains("확보 완료")), "the 채굴 tab lists the secured veins")
	hud._active_tab = Hud.TAB_WORKERS
	hud._refresh(true)
	texts = _labels(hud._rows)
	_check(texts.any(func(t: String) -> bool: return t.contains("/ 8명")), "the 인부 tab shows the worker cap")
	_check(texts.any(func(t: String) -> bool: return t.begins_with("방금 뽑음")), "the 인부 tab shows the last pull")
	hud.queue_free()
	game.free()


func _labels(node: Node) -> Array[String]:
	var out: Array[String] = []
	for child in node.get_children():
		if child is Label:
			out.append(child.text)
		elif child is Button:
			out.append(child.text)
		out.append_array(_labels(child))
	return out
