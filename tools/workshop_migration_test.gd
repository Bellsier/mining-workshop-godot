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
	_expect(game.unlock("deliveryContract") and not game.snapshot().deliveries.is_empty(), "delivery contract")
	var offer: Dictionary = game.snapshot().deliveries[0]
	game.state.inventory[offer.product] = float(offer.qty) + 1.0
	_expect(game.deliver(offer.id), "deliver first contract")
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
