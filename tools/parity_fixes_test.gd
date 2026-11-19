extends SceneTree
## First parity fix round against the web original (gacha-factory-development 7484ccd), in a throwaway user folder:
##   MINING_QA_ISOLATED=1 XDG_DATA_HOME=<empty temp dir> godot --headless --path . --script res://tools/parity_fixes_test.gd
## 1. Ticket trickle: 45 s interval from start, nothing before the first-ticket milestone (systems.js ticketTrickle).
## 2. The imported JS save (legacy_web_save) survives import, autosave, reload and re-export unchanged.
## 4. Auto-sell skips only workshopOnly recipes and really moves stock into gold (systems.js tickAutoSell).
## 5. A new order restarts the order timer at 0; overflow is not carried (delivery.js tickOrders).
## 6. Fractional stock such as 0.5 iron stays visible, formatted like the original's fmt().
## Prints "PARITY FIXES PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
const Delivery = preload("res://scripts/workshop_delivery.gd")
const Hud = preload("res://scripts/workshop_hud.gd")
const FIXTURE := "res://tests/fixtures/js_save_v1_full_world.json"

var _failures: Array[String] = []


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
	var version := Engine.get_version_info()
	_check(version.major == 4 and version.minor == 4 and version.patch == 1, "runs on Godot 4.4.1 (got %s)" % version.string)
	_ticket_trickle()
	_auto_sell()
	_order_timer()
	_quantity_format()
	await _fractional_stock_is_shown()
	_legacy_save_is_kept()
	if _failures.is_empty():
		print("PARITY FIXES PASS")
		quit(0)
	else:
		print("PARITY FIXES FAIL %d" % _failures.size())
		quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("PARITY FIXES FAIL ", what)


func _game(persistent := false) -> Node:
	var game: Node = Workshop.new()
	game.persistence_enabled = persistent
	root.add_child(game)
	game.set_process(false)
	return game


func _ticks(game: Node, count: int) -> void:
	for index in count:
		game._tick()


func _ticket_trickle() -> void:
	var game := _game()
	var gacha: Dictionary = game.data.balance.gacha
	var per_interval := int(round(float(gacha.TICKET_TRICKLE_MS) / 1000.0 / Workshop.TICK))
	_check(per_interval == 450, "the trickle interval is 45 s = 450 ticks")
	_check(not game.state.first_ticket and game.state.tickets == 0, "a new game has no ticket yet")
	# Before the first-ticket milestone the 45 s boundary passes without a ticket (the reported bypass).
	_ticks(game, per_interval * 3)
	_check(game.state.tickets == 0, "no trickle ticket before the first ticket (got %d)" % game.state.tickets)
	# The interval keeps running before the milestone, as setInterval does: earning the first ticket
	# 30 s into an interval means the next trickle ticket comes 15 s later, not 45 s later.
	_ticks(game, 300)
	game.state.gold = float(gacha.FIRST_TICKET_GOLD_THRESHOLD) - 1.0
	game.state.inventory["steel"] = 1.0
	_check(game.sell("steel") and game.state.first_ticket and game.state.tickets == 1, "selling past the threshold grants the first ticket")
	_ticks(game, 149)
	_check(game.state.tickets == 1, "no trickle ticket one tick before the 45 s boundary (got %d)" % game.state.tickets)
	_ticks(game, 1)
	_check(game.state.tickets == 2, "trickle ticket exactly at the 45 s boundary after the first ticket (got %d)" % game.state.tickets)
	_ticks(game, per_interval - 1)
	_check(game.state.tickets == 2, "no second trickle ticket at 44.9 s (got %d)" % game.state.tickets)
	_ticks(game, 1)
	_check(game.state.tickets == 3, "second trickle ticket exactly at 45 s (got %d)" % game.state.tickets)
	# Ten minutes of ticks must not drift past a boundary: 13 more intervals → 13 more tickets.
	_ticks(game, per_interval * 13)
	_check(game.state.tickets == 16, "no drift over 13 intervals (got %d)" % game.state.tickets)
	# The interval starts again on every load, like the original's page start.
	_ticks(game, 200)
	_check(game.import_save(game.export_save()) and is_zero_approx(float(game.state.ticket_elapsed)), "loading restarts the ticket interval")
	_ticks(game, per_interval - 1)
	_check(game.state.tickets == 16, "a load does not bring the next ticket forward (got %d)" % game.state.tickets)
	_ticks(game, 1)
	_check(game.state.tickets == 17, "first trickle ticket 45 s after a load (got %d)" % game.state.tickets)
	# An imported JS save without the milestone gets nothing; one with it keeps getting tickets.
	var before := {"saveVersion": 1, "savedAt": 1, "permanent": {"tickets": 0, "firstGachaGranted": false}, "run": {"gold": 10, "resources": {}, "products": {}}}
	_check(game.import_save(JSON.stringify(before)) and not game.state.first_ticket, "imported save before the milestone")
	_ticks(game, per_interval * 2)
	_check(game.state.tickets == 0, "imported save before the milestone gets no trickle ticket (got %d)" % game.state.tickets)
	var after := before.duplicate(true)
	after.permanent = {"tickets": 2, "firstGachaGranted": true}
	_check(game.import_save(JSON.stringify(after)) and game.state.first_ticket and game.state.tickets == 2, "imported save after the milestone")
	_ticks(game, per_interval)
	_check(game.state.tickets == 3, "imported save after the milestone gets the trickle ticket (got %d)" % game.state.tickets)
	game.queue_free()


func _auto_sell() -> void:
	var game := _game()
	var steel: Dictionary = game._tables.recipes.steel
	_check(not steel.has("workshopOnly"), "steel has no workshopOnly flag in the catalog")
	game.state.gold = 100000.0
	_check(game.buy_auto_sell("steel"), "auto-sell can be bought for a normal recipe")
	game.state.inventory["steel"] = 7.0
	var gold := float(game.state.gold)
	var expected := 7.0 * float(steel.sell) * game._multiplier()
	game._tick()
	_check(is_zero_approx(float(game.state.inventory.steel)), "auto-sell empties the steel stock (left %s)" % game.state.inventory.steel)
	_check(is_equal_approx(float(game.state.gold), gold + expected), "auto-sell pays qty × price × multiplier (%s → %s, expected +%s)" % [gold, game.state.gold, expected])
	# Turned off, it keeps the stock.
	_check(game.set_auto_sell("steel", false), "auto-sell can be switched off")
	game.state.inventory["steel"] = 3.0
	game._tick()
	_check(float(game.state.inventory.steel) == 3.0, "switched-off auto-sell keeps the stock")
	# workshopOnly products are materials: never sold automatically, even if an old save says so.
	_check(not game.buy_auto_sell("specialAlloy"), "auto-sell cannot be bought for a workshopOnly recipe")
	game.state.automation.sell_owned["specialAlloy"] = true
	game.state.automation.sell["specialAlloy"] = true
	game.state.inventory["specialAlloy"] = 4.0
	gold = float(game.state.gold)
	game._tick()
	_check(float(game.state.inventory.specialAlloy) == 4.0 and float(game.state.gold) == gold, "workshopOnly stock is not auto-sold")
	# The milestone is checked by automatic sales too (sellAll → checkFirstGachaMilestone).
	var fresh := _game()
	fresh.state.gold = 1000.0
	_check(fresh.buy_auto_sell("steel") and not fresh.state.first_ticket, "auto-sell bought before the first ticket")
	fresh.state.gold = 0.0
	fresh.state.inventory["steel"] = 10.0
	fresh._tick()
	_check(fresh.state.first_ticket and fresh.state.tickets == 1 and is_zero_approx(float(fresh.state.inventory.steel)), "an automatic sale reaching the threshold grants the first ticket")
	fresh.queue_free()
	game.queue_free()


func _order_timer() -> void:
	var game := _game()
	var data: Dictionary = game.data
	var state: Dictionary = game.state
	state.completed_research["deliveryContract"] = true
	Delivery.offers(data, state)
	var company: String = data.companies[0].key
	var progress: Dictionary = state.delivery.companies[company]
	var arrival := float(data.balance.orders.ARRIVAL_SEC_START)
	_check(Delivery.reputation(data, state) == 0, "orders start at reputation 0 (arrival %s s)" % arrival)
	# A long step past the arrival time: the original sets the timer to 0, not to the overflow.
	progress.open.clear()
	progress.orderTimer = 0.0
	Delivery.tick(data, state, arrival + 7.0, 1.0)
	_check(progress.open.size() == 1, "an order arrives after the arrival time")
	_check(float(progress.orderTimer) == 0.0, "the order timer restarts at 0 (got %s)" % progress.orderTimer)
	# With the room filled the timer stays at 0 (orderCap reached).
	Delivery.tick(data, state, 5.0, 1.0)
	_check(float(progress.orderTimer) == 0.0, "a full order list holds the timer at 0")
	# Tick by tick, two arrivals in a row take exactly as many 0.1 s ticks as the original's loop.
	var expected_ticks := 0
	var clock := 0.0
	while clock < arrival:
		clock += 1.0 / 10.0
		expected_ticks += 1
	for round_index in 2:
		progress.open.clear()
		var ticks := 0
		while progress.open.is_empty() and ticks < expected_ticks + 10:
			Delivery.tick(data, state, Workshop.TICK, 1.0)
			ticks += 1
		_check(ticks == expected_ticks, "arrival %d takes %d ticks like the original (got %d)" % [round_index + 1, expected_ticks, ticks])
		_check(float(progress.orderTimer) == 0.0, "arrival %d leaves no carried time (got %s)" % [round_index + 1, progress.orderTimer])
	game.queue_free()


func _quantity_format() -> void:
	# Expected strings come from the original fmt() run in Node (Intl ko-KR).
	var cases := [[0.0, "0"], [0.5, "0.5"], [0.25, "0.3"], [0.75, "0.8"], [0.05, "0.1"], [0.04, "0.0"],
		[9.96, "10.0"], [9.94, "9.9"], [1.0, "1"], [12.7, "12"], [1234567.8, "1,234,567"],
		[0.30000000000000004, "0.3"], [1.15, "1.1"], [2.35, "2.4"], [-1.0, "0"]]
	for case: Array in cases:
		var shown: String = Hud.format_quantity(case[0])
		_check(shown == case[1], "fmt(%s) = %s (got %s)" % [case[0], case[1], shown])


func _labels(node: Node, into: Array[String]) -> Array[String]:
	if node is Label:
		into.append(node.text)
	for child in node.get_children():
		_labels(child, into)
	return into


func _fractional_stock_is_shown() -> void:
	var game := _game()
	var hud: CanvasLayer = Hud.new()
	root.add_child(hud)
	hud.setup(game)
	game.state.inventory["iron"] = 0.5
	game.state.inventory["steel"] = 0.5
	hud.open_inventory()
	hud._refresh(true)
	var texts := _labels(hud._rows, [] as Array[String])
	_check(texts.has("0.5개"), "the bag shows 0.5 iron (rows: %s)" % ", ".join(texts))
	game.state.inventory["iron"] = 0.6
	hud._refresh()
	texts = _labels(hud._rows, [] as Array[String])
	_check(texts.has("0.6개"), "the bag redraws when 0.5 becomes 0.6 (rows: %s)" % ", ".join(texts))
	hud.open_workshop()
	hud._active_tab = Hud.TAB_SELL
	hud._refresh(true)
	texts = _labels(hud._rows, [] as Array[String])
	var shown := false
	for text in texts:
		shown = shown or text.begins_with("보유 0.5개")
	_check(shown, "the sales tab shows 0.5 steel (rows: %s)" % ", ".join(texts))
	var button: Button = hud._buttons_by_id.get("steel")
	_check(button != null and not button.disabled, "0.5 steel can be sold, as in the original (products > 0)")
	hud.queue_free()
	game.queue_free()
	await process_frame


## Numbers compare by value: JSON reads every number back as a float.
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
		for index in a.size():
			if not _same(a[index], b[index]):
				return false
		return true
	return typeof(a) == typeof(b) and a == b


func _legacy_save_is_kept() -> void:
	var text := FileAccess.get_file_as_string(FIXTURE)
	var original: Dictionary = JSON.parse_string(text)
	_check(original.run.world.workshops.size() == 2 and original.run.world.torches.size() == 2
		and original.run.village.decor.size() == 3 and original.run.world.tunnelContract.durationSec == 600,
		"the fixture carries workshops, torches, decorations and a tunnel job")
	# Import on a desktop build writes the save file at once.
	var game := _game(true)
	_check(game.import_save(text), "the JS save imports")
	_check(_same(game.state.legacy_web_save, original), "legacy_web_save equals the JS save after import")
	_check(_same(Save.load_game().get("legacy_web_save"), original), "legacy_web_save equals the JS save in the written file")
	# Play, autosave, and play again: the original payload is data, never rewritten by the game.
	game.mine("iron")
	game.state.gold = float(game.state.gold) + 5.0
	_ticks(game, 50)
	game._mark_dirty()
	game.flush(true)
	_check(_same(Save.load_game().get("legacy_web_save"), original), "legacy_web_save is unchanged after an autosave")
	game.queue_free()
	# A new session loads the file.
	var reloaded := _game(true)
	_check(_same(reloaded.state.legacy_web_save, original), "legacy_web_save is unchanged after a reload")
	_check(float(reloaded.state.inventory.get("iron", 0.0)) >= 1.5, "the reload kept the played progress")
	# Export and import the Godot save again.
	var exported: String = reloaded.export_save()
	_check(_same(Save.parse_game(exported).get("legacy_web_save"), original), "legacy_web_save is unchanged in an exported save")
	_check(reloaded.import_save(exported) and _same(reloaded.state.legacy_web_save, original), "legacy_web_save is unchanged after re-importing the export")
	reloaded.queue_free()
	var again := _game(true)
	_check(_same(again.state.legacy_web_save, original), "legacy_web_save is unchanged after a second reload")
	again.queue_free()
	# An S2 auto-save row (envelope around the same payload) keeps the same game payload.
	var row := {"id": "11111111-2222-4333-8444-555555555555", "revision": 3, "snapshot": {"format": 1,
		"id": "66666666-7777-4888-9999-000000000000", "villageId": "11111111-2222-4333-8444-555555555555",
		"name": "시험 마을", "savedAt": original.savedAt, "payload": original}}
	var s2 := _game()
	_check(s2.import_save(JSON.stringify(row)) and _same(s2.state.legacy_web_save, original), "an S2 row keeps the game payload")
	s2.queue_free()
