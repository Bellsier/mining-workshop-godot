extends SceneTree
## Craft huts (제작소) against the web original (gacha-factory-development 7484ccd), in a throwaway user folder:
##   MINING_QA_ISOLATED=1 XDG_DATA_HOME=<empty temp dir> godot --headless --path . --script res://tools/craft_hut_test.gd
## The expected values come from the original JS, run by tools/craft_huts/make_web_fixtures.cjs.
## 1. Build and upgrade costs, the hut limit and craft times equal the original's, number for number.
## 2. New huts take the same cells round the base as the original's buildWorkshop.
## 3. A 40-step play script (build, recipes, hand and auto crafting, upgrades, targets) leaves the same gold,
##    stock and hut state after every step, progress included to the last bit.
## 4. Saved huts are cleaned like sanitizeWorkshops; huts or automation in use count as researched.
## 5. Saves: a web save's huts load; a Godot save from before huts gets them back from its kept web save; a
##    Godot save's own list wins; a broken list is protected, not overwritten; progress survives exactly.
## 6. Workshop-only recipes: refused on the recipe cards, made in huts; a new game can reach them through the
##    research, the build button and the hut card, and a card craft already running still finishes.
## Prints "CRAFT HUT PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
const Hud = preload("res://scripts/workshop_hud.gd")
const CraftHuts = preload("res://scripts/craft_huts.gd")
const ExactJson = preload("res://scripts/exact_json.gd")
const WEB := "res://tests/fixtures/craft_hut_web_fixtures.json"
const JS_SAVE := "res://tests/fixtures/js_save_v1_full_world.json"

var _failures: Array[String] = []
var _web: Dictionary


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var isolated := OS.get_environment("XDG_DATA_HOME")
	if OS.get_environment("MINING_QA_ISOLATED") != "1" or isolated.is_empty() or not OS.get_user_data_dir().begins_with(isolated + "/"):
		printerr("Requires a dedicated XDG_DATA_HOME and MINING_QA_ISOLATED=1; no files touched")
		quit(1)
		return
	if not DirAccess.get_files_at("user://").is_empty():
		printerr("Refusing to run in a user folder that already has files")
		quit(1)
		return
	_web = ExactJson.parse(FileAccess.get_file_as_string(WEB)).value
	_check(str(_web.source.commit).begins_with("7484ccd"), "the fixture comes from the web original 7484ccd")
	_costs_match_web()
	_spots_match_web()
	_play_script_matches_web()
	_sanitize_matches_web()
	_research_in_use_matches_web()
	_web_save_huts_load()
	_older_godot_save_gets_huts_back()
	_godot_list_wins_and_broken_list_is_protected()
	_desktop_save_keeps_huts()
	_workshop_only_recipes()
	await _new_game_reaches_workshop_only_recipes()
	if _failures.is_empty():
		print("CRAFT HUT PASS")
		quit(0)
	else:
		print("CRAFT HUT FAIL %d" % _failures.size())
		quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("CRAFT HUT FAIL ", what)


func _game(persistent := false) -> Node:
	var game: Node = Workshop.new()
	game.persistence_enabled = persistent
	root.add_child(game)
	game.set_process(false)
	return game


## A game whose world is the web scenario's: the base, the given veins and no huts.
func _web_world(game: Node, base: Dictionary, mines: Array) -> void:
	game.world.base = Vector2i(int(base.x), int(base.y))
	game.world.mines = []
	game.world.hidden_ids.clear()
	game.world.workshops = []
	for index in mines.size():
		game.world.mines.append({"id": "m%d" % index, "x": int(mines[index].x), "y": int(mines[index].y), "resource": "iron",
			"grade": 1, "miningPower": 1, "developmentState": "unsecured"})


# --- 1. costs, limit, craft time ------------------------------------------------------------------------------

func _costs_match_web() -> void:
	var game := _game()
	for row: Dictionary in _web.build:
		var count := int(row.count)
		_check(float(CraftHuts.build_cost(game.data, count)) == float(row.gold), "build cost with %d huts: %d, web %s" % [count, CraftHuts.build_cost(game.data, count), row.gold])
		_check(_same(CraftHuts.build_products(game.data, count), row.products), "build parts with %d huts" % count)
	for row: Dictionary in _web.upgrade:
		var cost := CraftHuts.upgrade_cost(game.data, {"level": int(row.level)})
		if row.cost == null:
			_check(cost.is_empty(), "no upgrade at level %d" % int(row.level))
		else:
			_check(float(cost.get("gold", -1)) == float(row.cost.gold) and _same(cost.get("products", {}), row.cost.products),
				"upgrade cost from level %d: %s, web %s" % [int(row.level), cost, row.cost])
	_check(CraftHuts.max_count(game.data, {}) == int(_web.max.base) and CraftHuts.max_count(game.data, {"workshopExpansion": true}) == int(_web.max.expanded),
		"the hut limit is 6, and 8 after 제작소 증축")
	var wrong := 0
	for row: Dictionary in _web.craft_time:
		var recipe: Dictionary = game._tables.recipes[row.recipe]
		var seconds := CraftHuts.craft_time(game.data, {"level": int(row.level)}, recipe, float(row.reputation))
		if seconds != float(row.seconds):
			wrong += 1
			printerr("  craft time %s Lv.%d rep %s: %s, web %s" % [row.recipe, int(row.level), row.reputation, seconds, row.seconds])
	_check(wrong == 0, "%d craft times equal the web's to the bit (%d differ)" % [_web.craft_time.size(), wrong])
	game.free()


# --- 2. where huts go -----------------------------------------------------------------------------------------

func _spots_match_web() -> void:
	for scenario: Dictionary in _web.spots:
		var game := _game()
		_web_world(game, scenario.base, scenario.mines)
		game.state.gold = 1e9
		game.state.completed_research.merge({"workshopBuild": true, "workshopExpansion": true}, true)
		game.state.inventory.merge({"steelGear": 2.0, "manaEngine": 1.0}, true)
		var got: Array = []
		for step in scenario.built.size():
			var ok: bool = game.build_hut()
			var hut: Dictionary = game.world.workshops.back() if ok else {}
			got.append({"x": hut.x, "y": hut.y, "gold": game.state.gold} if ok else null)
		_check(_same(got, scenario.built), "huts in the '%s' world: %s, web %s" % [scenario.name, got, scenario.built])
		game.free()


# --- 3. play script -------------------------------------------------------------------------------------------

func _play_script_matches_web() -> void:
	for script: Dictionary in _web.scripts:
		var game := _game()
		_web_world(game, script.base, [])
		game.state.gold = float(script.start.gold)
		for key: String in script.start.resources:
			game.state.inventory[key] = float(script.start.resources[key])
		for key: String in script.start.products:
			game.state.inventory[key] = float(script.start.products[key])
		for key: String in script.start.research:
			game.state.completed_research[key] = true
		var number := 0
		for entry: Dictionary in script.steps:
			number += 1
			var step: Dictionary = entry.step
			var ok := _do_step(game, step)
			var after := _snapshot(game, entry.after)
			_check(ok == bool(entry.ok), "step %d %s returns %s like the web (%s)" % [number, step, ok, entry.ok])
			_check(_same(after, entry.after), "step %d %s leaves the web's state:\n   godot %s\n   web   %s" % [number, step, after, entry.after])
		game.free()


func _do_step(game: Node, step: Dictionary) -> bool:
	var hut_id: String = game.world.workshops[int(step.hut)].id if step.has("hut") and int(step.hut) < game.world.workshops.size() else "none"
	match str(step.op):
		"build": return game.build_hut()
		"recipe": return game.set_hut_recipe(hut_id, "" if step.key == null else str(step.key))
		"craft": return game.craft_hut(hut_id)
		"upgrade": return game.upgrade_hut(hut_id)
		"auto": return game.set_hut_auto(hut_id, bool(step.on))
		"target": return game.set_craft_target(str(step.key), int(step.value))
		"research":
			game.state.completed_research[str(step.key)] = true
			return true
		"tick":
			for i in int(step.n):
				game._tick_huts()
			return true
		"hand": return game.craft(str(step.key))
	return false


func _snapshot(game: Node, like: Dictionary) -> Dictionary:
	var stock := {}
	for key: String in like.stock:
		stock[key] = float(game.state.inventory.get(key, 0.0))
	var huts: Array = []
	for hut: Dictionary in game.world.workshops:
		huts.append({"level": hut.level, "recipeKey": hut.recipeKey, "auto": hut.auto, "progress": hut.progress,
			"status": game.hut_status(hut).state})
	return {"gold": float(game.state.gold), "stock": stock, "huts": huts}


# --- 4. cleaning and research ---------------------------------------------------------------------------------

func _sanitize_matches_web() -> void:
	var game := _game()
	var cleaned := CraftHuts.sanitize(_web.sanitize.input, game._tables.recipes)
	var shown: Array = []
	for hut: Dictionary in cleaned:
		var copy := hut.duplicate()
		copy.id = hut.id if hut.id in ["workshop_ok", "workshop_far"] else "<new>"
		shown.append(copy)
	_check(_same(shown, _web.sanitize.output), "saved huts are cleaned like the web:\n   godot %s\n   web   %s" % [shown, _web.sanitize.output])
	var ids := {}
	for hut: Dictionary in cleaned:
		ids[hut.id] = true
	_check(ids.size() == cleaned.size() and cleaned.all(func(h: Dictionary) -> bool: return str(h.id).begins_with("workshop_")),
		"cleaned huts have distinct workshop_ ids")
	for value: Variant in [null, {}, "x", 3]:
		_check(CraftHuts.sanitize(value, game._tables.recipes).is_empty(), "a saved hut list that is not a list is empty (%s)" % value)
	game.free()


func _research_in_use_matches_web() -> void:
	for case: Dictionary in _web.research_sync:
		var got := {}
		for key in CraftHuts.research_in_use(case.input.workshops, case.input.autoCraft):
			got[key] = true
		_check(_same(got, case.research), "research in use for %s: %s, web %s" % [case.input, got, case.research])


# --- 5. saves -------------------------------------------------------------------------------------------------

func _web_save_huts_load() -> void:
	var bytes := FileAccess.get_file_as_bytes(JS_SAVE)
	var original: Dictionary = ExactJson.parse(FileAccess.get_file_as_string(JS_SAVE)).value
	var game := _game()
	_check(game.import_save_bytes(bytes), "the web save imports")
	var expected := CraftHuts.sanitize(original.run.world.workshops, game._tables.recipes)
	_check(_same(game.world.workshops, expected) and game.world.workshops.size() == 2, "the web save's two huts load as saved: %s" % [game.world.workshops])
	_check(game.state.completed_research.get("workshopBuild") == true and game.state.completed_research.get("autoCraftDevice") == true,
		"the web save's research is kept")
	_check(game.legacy_original_bytes() == bytes, "the web save stays byte for byte")
	# The rest of the web world comes along: the player's spot, the torches, the tunnel job and the village layout.
	var web_world: Dictionary = original.run.world
	_check(game.state.position.get("scene") == "res://scenes/world/world_map.tscn" and float(game.state.position.x) == float(web_world.player.x) * 64.0
		and float(game.state.position.y) == float(web_world.player.y) * 64.0, "the web player's position is kept: %s" % [game.state.position])
	_check(game.world.torches.size() == web_world.torches.size() and float(game.world.torches[0].x) == float(web_world.torches[0].x), "the web torches are kept")
	var contract: Variant = web_world.tunnelContract
	_check(game.world.tunnel_contract.is_empty() if web_world.tunnelUnlocked or contract == null
		else float(game.world.tunnel_contract.startedAt) == float(contract.startedAt), "the web tunnel job is kept (none once the tunnel is open)")
	var web_village: Dictionary = original.run.village
	_check(float(game.state.village.sites.appraiser.x) == float(web_village.sites.appraiser.x) and float(game.state.village.district.x) == float(web_village.district.x)
		and game.state.village.decor.size() == web_village.decor.size(), "the web village layout and garden are kept: %s" % [game.state.village.get("district")])
	# The Godot save carries the huts, and a reload of it has them again, progress to the bit.
	game.world.workshops[0].progress = 4.579669976578771e-15
	var text: String = game.export_save()
	var again := _game()
	_check(again.import_save(text), "the Godot save with huts imports")
	_check(_same(again.world.workshops, game.world.workshops), "huts survive export and import: %s" % [again.world.workshops])
	_check(again.world.workshops[0].progress == 4.579669976578771e-15, "a tiny progress survives exactly")
	_check(again.legacy_original_bytes() == bytes, "the web save is still kept byte for byte")
	game.free()
	again.free()


## A Godot save written before huts were ported: its world has no "workshops". The huts come back from the web
## save it was imported from, and the research they need counts as done.
func _older_godot_save_gets_huts_back() -> void:
	var bytes := FileAccess.get_file_as_bytes(JS_SAVE)
	var original: Dictionary = ExactJson.parse(FileAccess.get_file_as_string(JS_SAVE)).value
	var game := _game()
	game.import_save_bytes(bytes)
	var envelope: Dictionary = ExactJson.parse(game.export_save()).value
	envelope.state.world.erase("workshops")
	envelope.state.completed_research.erase("workshopBuild")
	envelope.state.completed_research.erase("autoCraftDevice")
	var older := _game()
	_check(older.import_save(ExactJson.stringify(envelope)), "a Godot save from before huts imports")
	var expected := CraftHuts.sanitize(original.run.world.workshops, older._tables.recipes)
	_check(_same(older.world.workshops, expected), "its huts come back from the kept web save: %s" % [older.world.workshops])
	_check(older.state.completed_research.get("workshopBuild") == true and older.state.completed_research.get("autoCraftDevice") == true,
		"huts in use count as researched, like the web researchSyncFromState")
	_check(older.legacy_original_bytes() == bytes, "the kept web save is unchanged")
	_check(older.export_save().contains("\"workshops\":["), "the next save writes the huts itself")
	game.free()
	older.free()


func _godot_list_wins_and_broken_list_is_protected() -> void:
	var game := _game()
	game.import_save_bytes(FileAccess.get_file_as_bytes(JS_SAVE))
	var envelope: Dictionary = ExactJson.parse(game.export_save()).value
	envelope.state.world.workshops = []
	var emptied := _game()
	_check(emptied.import_save(ExactJson.stringify(envelope)) and emptied.world.workshops.is_empty(),
		"a Godot save's own (empty) hut list wins over the kept web save")
	envelope.state.world.workshops = "broken"
	var before: Array = game.world.workshops.duplicate(true)
	_check(not game.import_save(ExactJson.stringify(envelope)), "a Godot save with a broken hut list is refused")
	_check(_same(game.world.workshops, before), "a refused import leaves the huts in play")
	_check(not game._valid_save_state(envelope.state), "a broken hut list is not a valid Godot save (it is protected on load)")
	game.free()
	emptied.free()


func _desktop_save_keeps_huts() -> void:
	var game := _game(true)
	game.state.gold = 50000.0
	game.state.inventory.merge({"steel": 5.0, "alloy": 9.0, "coal": 9.0}, true)
	_check(game.unlock("workshopBuild") and game.build_hut(), "a desktop game researches and builds a hut")
	var id: String = game.world.workshops[0].id
	_check(game.set_hut_recipe(id, "specialAlloy") and game.craft_hut(id), "the hut makes 특수 합금")
	for i in 7:
		game._tick_huts()
	var progress: float = game.world.workshops[0].progress
	game.flush(true)
	var file_state := Save.load_game()
	_check(file_state.get("world", {}).get("workshops", []).size() == 1, "the save file has the hut")
	game.queue_free()
	var reloaded := _game(true)
	_check(reloaded.world.workshops.size() == 1 and reloaded.world.workshops[0].id == id and reloaded.world.workshops[0].progress == progress,
		"a new session has the hut, its recipe and its progress (%s)" % [reloaded.world.workshops])
	for i in 40:
		reloaded._tick_huts()
	_check(float(reloaded.state.inventory.get("specialAlloy", 0)) == 1.0 and reloaded.world.workshops[0].progress == null,
		"the craft started before the reload finishes after it")
	reloaded.queue_free()


# --- 6. workshop-only recipes ---------------------------------------------------------------------------------

func _workshop_only_recipes() -> void:
	var game := _game()
	game.state.gold = 1e7
	game.state.completed_research.merge({"workshopBuild": true, "autoCraftDevice": true, "workshopExpansion": true}, true)
	for key: String in ["iron", "coal", "mana", "crystal", "rareMetal", "relic", "cosmicShard", "plasma"]:
		game.state.inventory[key] = 1000.0
	for key: String in ["steel", "alloy", "crystalAlloy", "crystalLens", "precisionPart", "specialAlloy", "steelGear"]:
		game.state.inventory[key] = 1000.0
	var hut_only: Array[String] = []
	for row: Dictionary in game.data.recipes:
		if row.get("workshopOnly", false):
			hut_only.append(row.key)
	_check(hut_only.size() == 11, "11 recipes are workshop-only in the catalog (got %d)" % hut_only.size())
	for key in hut_only:
		var stock := float(game.state.inventory.get(key, 0))
		_check(not game.craft(key) and float(game.state.inventory.get(key, 0)) == stock and not game.state.queue.has(key),
			"%s cannot be made on the recipe card" % key)
	_check(not game.set_auto_craft("specialAlloy", true) and game.set_auto_craft("steel", true), "auto-craft on a card refuses workshop-only recipes")
	_check(game.craft("steel"), "an ordinary recipe is still made by hand")
	# An older save's card automation for a workshop-only recipe does nothing; a card craft already running finishes.
	game.state.automation.craft["specialAlloy"] = true
	game.state.queue["precisionPart"] = 0.3
	var before := float(game.state.inventory.specialAlloy)
	var parts := float(game.state.inventory.precisionPart)
	for i in 3:
		game._tick()
	_check(float(game.state.inventory.specialAlloy) == before and not game.state.queue.has("specialAlloy"), "card automation skips a workshop-only recipe")
	_check(float(game.state.inventory.precisionPart) == parts + 1.0 and not game.state.queue.has("precisionPart"),
		"a workshop-only craft already on the card (older save) still finishes")
	# Every workshop-only recipe can be made in a hut.
	for key in hut_only:
		game.world.workshops = []
		game.build_hut()
		var id: String = game.world.workshops[0].id
		var have := float(game.state.inventory.get(key, 0))
		var ok: bool = game.set_hut_recipe(id, key) and game.craft_hut(id)
		for i in 200:
			game._tick_huts()
		_check(ok and float(game.state.inventory.get(key, 0)) == have + 1.0, "%s is made in a hut" % key)
	var snapshot: Dictionary = game.snapshot()
	for recipe: Dictionary in snapshot.recipes:
		_check(bool(recipe.hut_only) == (recipe.id in hut_only), "the recipe card marks %s %s" % [recipe.id, "hut-only" if recipe.id in hut_only else "free"])
	game.free()


## From a new game: research 제작소 건설 with what the start allows, build from the 제작 tab, choose 특수 합금 on
## the hut card and make it. The way to the workshop-only recipes is open in play, not only in code.
func _new_game_reaches_workshop_only_recipes() -> void:
	var game := _game()
	var hud: CanvasLayer = Hud.new()
	root.add_child(hud)
	hud.setup(game)
	hud.open_workshop()
	hud._active_tab = Hud.TAB_CRAFT
	hud._refresh(true)
	var texts := _labels(hud._rows)
	_check(texts.any(func(t: String) -> bool: return t.contains("제작소 건설")), "the 제작 tab says to research 제작소 건설 first")
	var research: Dictionary = game._tables.research.workshopBuild
	_check(research.requires.is_empty(), "제작소 건설 needs no other research")
	# 특수 합금 is made from 마법 합금, which needs 마정석: like the web hut card, the picker offers it once
	# 마정석 광맥 is open.
	var site: Dictionary = game._tables.sites.manaVein
	game.state.gold = float(research.cost.gold) + float(site.unlockCost) + 500.0
	game.state.inventory.merge({"steel": float(research.cost.products.steel) + float(site.unlockProducts.steel), "alloy": 3.0, "coal": 3.0}, true)
	_check(game.unlock("workshopBuild"), "제작소 건설 is researched")
	_check(game.open_site("manaVein"), "마정석 광맥 is opened")
	hud._refresh(true)
	var build: Button = hud._buttons_by_id.get("build_hut")
	_check(is_instance_valid(build) and not build.disabled, "the 제작 tab offers 제작소 짓기")
	if is_instance_valid(build):
		build.pressed.emit()
	_check(game.world.workshops.size() == 1, "the button built a hut")
	if game.world.workshops.is_empty():
		hud.queue_free()
		game.free()
		return
	var id: String = game.world.workshops[0].id
	hud._refresh(true)
	var picker: OptionButton = hud._buttons_by_id.get("craft_hut:" + id)
	_check(is_instance_valid(picker), "the hut card has a recipe picker")
	if is_instance_valid(picker):
		var index := -1
		for i in picker.item_count:
			if picker.get_item_text(i) == game._label("specialAlloy"):
				index = i
		_check(index > 0, "the picker offers 특수 합금")
		picker.select(index)
		picker.item_selected.emit(index)
	_check(game.world.workshops[0].recipeKey == "specialAlloy", "the picker set the hut's recipe")
	await process_frame
	hud._refresh(true)
	var craft: Button = hud._buttons_by_id.get(id)
	_check(is_instance_valid(craft) and not craft.disabled, "the hut card's 제작 button is ready")
	if is_instance_valid(craft):
		craft.pressed.emit()
	for i in 40:
		game._tick()
	_check(float(game.state.inventory.get("specialAlloy", 0)) == 1.0, "a new game made 특수 합금 in its first hut")
	hud._refresh(true)
	texts = _labels(hud._rows)
	_check(texts.any(func(t: String) -> bool: return t.contains("제작소 전용")), "the recipe card marks workshop-only recipes")
	hud.queue_free()
	game.free()


# --- helpers --------------------------------------------------------------------------------------------------

func _labels(node: Node) -> Array[String]:
	var out: Array[String] = []
	for child in node.get_children():
		if child is Label:
			out.append(child.text)
		out.append_array(_labels(child))
	return out


## Same JSON value: numbers compare by value (a JSON read gives floats, the game keeps ints for cells and levels).
func _same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return float(a) == float(b)
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b
