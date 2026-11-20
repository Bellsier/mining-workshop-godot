extends SceneTree

const Workshop = preload("res://scripts/workshop.gd")

var _failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var game := Workshop.new()
	game.persistence_enabled = false
	root.add_child(game)
	game.set_process(false)
	var initial := game.snapshot()
	_expect(initial.resources.size() == 8 and initial.recipes.size() == 18, "source catalog")
	_expect(not game.mine("mana"), "advanced mine is gated")
	_expect(not game.craft("steel"), "materials are required")
	for index in 20:
		game.mine("iron")
	for index in 10:
		game.mine("coal")
	for index in 10:
		_expect(game.craft("steel"), "starter recipe")
	_expect(game.sell("steel") and game.state.gold == 50.0 and game.state.tickets == 1, "sales and first ticket")
	_expect(game.hire("ticket") and game.state.characters.size() == 1 and game.state.tickets == 0, "first hire")
	var worker: Dictionary = game.state.characters[0]
	_expect(game.assign_worker(worker.id, "iron"), "worker reassignment")
	game._tick()
	_expect(game.state.inventory.get("iron", 0.0) > 0.0, "worker yield")
	game.state.gold = 10000.0
	game.state.inventory.steel = 40.0
	_expect(game.open_site("manaVein") and game.mine("crystal"), "site unlock and mining")
	_expect(game.craft("crystalAlloy") and game.state.queue.has("crystalAlloy"), "timed crafting queued")
	for index in 31:
		game._tick()
	_expect(game.state.inventory.get("crystalAlloy", 0.0) >= 1.0 and not game.state.queue.has("crystalAlloy"), "timed crafting completed")
	_expect(game.unlock("autoCraftDevice") and game.set_auto_craft("steel", true), "automation research")
	game.mine("iron")
	game.mine("iron")
	game.mine("coal")
	var before := float(game.state.inventory.steel)
	game._tick()
	_expect(game.state.inventory.steel == before + 1.0, "automated craft")
	_expect(game.buy_auto_sell("coalBrick") and game.set_auto_sell("coalBrick", false), "auto-sale purchase and toggle")
	var contractual := game.unlock("deliveryContract")
	var offers: Array = game.snapshot().deliveries
	_expect(contractual and not offers.is_empty(), "delivery contract")
	if not offers.is_empty():
		var offer: Dictionary = offers[0]
		game.state.inventory[offer.product] = float(offer.qty) + 1.0
		_expect(game.deliver(offer.id), "deliver first contract")
	game.state.inventory.iron = 30.0
	game.state.gold = 10000.0
	_expect(game.upgrade("hq_level") and game.state.hq_level == 1, "headquarters upgrade")
	_expect(game.upgrade("facility:iron") and game.state.facility.iron == 1, "mining upgrade")
	_expect(not game.upgrade("facility:plasma"), "locked resource upgrade")
	_expect(game.upgrade("craft_facility") and game.state.craft_facility == 2, "craft facility upgrade")
	game.state.gold = 10000.0
	game.state.inventory.merge({"steel": 50.0, "coalBrick": 4.0, "ironTool": 5.0, "iron": 30.0}, true)
	_expect(not game.restore_facility("museum"), "museum needs appraiser")
	_expect(game.restore_facility("appraiser") and game.restore_facility("appraiser"), "appraiser restoration")
	# Relics turn up while mining a secured vein in the world (web mineMine), not from the mining tab's button.
	var vein: Dictionary = game.world.mines.filter(func(m: Dictionary) -> bool: return m.resource == "iron")[0]
	game.world.discover(vein.id)
	_expect(game.secure_vein(vein.id), "secure an iron vein")
	for index in 30:
		game.mine_vein(vein.id)
	_expect(game.state.village.unidentified > 0, "mining a vein turns up relics")
	_expect(game.appraise_relic("appraiser") and game.state.village.codex.size() == 1, "relic appraisal")
	_expect(game.restore_facility("museum") and game.restore_facility("museum"), "museum restoration")
	if not game.state.village.codex.is_empty():
		var relic: String = game.state.village.codex[0]
		_expect(game.donate_relic(relic) and not game.donate_relic(relic), "unique relic donations")
	_expect(game.donate_specimen("iron") and not game.donate_specimen("iron"), "unique specimen donations")
	var saved := game.export_save()
	_expect(not saved.is_empty(), "export save")
	_expect(game.import_save(saved) and game.state.characters.size() == 1, "save roundtrip")
	if _failures == 0:
		print("WORKSHOP MIGRATION PASS")
	game.queue_free()
	quit(_failures)

func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		printerr("WORKSHOP MIGRATION FAIL: " + label)
