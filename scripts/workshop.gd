extends Node

signal changed
signal feedback(message: String)

const Save = preload("res://scripts/workshop_save.gd")
const Delivery = preload("res://scripts/workshop_delivery.gd")
const Village = preload("res://scripts/workshop_village.gd")
const CATALOG := "res://data/web_catalog.json"
const TICK := 0.1

var data: Dictionary = {}
var state: Dictionary = {}
var player: Node2D
var persistence_enabled := true
var _tables: Dictionary = {}
var _elapsed := 0.0
var _save_elapsed := 0.0
var _dirty := false
var _save_error := OK
var _save_blocked := false

func _ready() -> void:
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if not catalog is Dictionary:
		push_error("Could not load the web game catalog: " + CATALOG)
		set_process(false)
		return
	data = catalog
	for table in ["resources", "recipes", "research", "sites", "rarity"]:
		_tables[table] = {}
		for row: Dictionary in data[table]:
			_tables[table][row.key] = row
	var saved := Save.load_game() if persistence_enabled else {}
	_save_blocked = not saved.is_empty() and not _valid_save_state(saved)
	if _save_blocked:
		_save_error = ERR_FILE_CORRUPT
	_restore({} if _save_blocked else saved)

func _restore(source: Dictionary) -> void:
	state = {
		"gold": 0.0, "inventory": {}, "completed_research": {}, "unlocked_sites": {"abandonedMine": true},
		"characters": [], "automation": {"craft": {}, "sell_owned": {}, "sell": {}, "target": {}},
		"queue": {}, "tickets": 0, "ticket_elapsed": 0.0, "first_ticket": false,
		"hq_level": 0, "craft_facility": 1, "facility": {}, "workforce": {}, "stats": {},
		"position": {}, "tunnel_open": false,
	}
	state.merge(source, true)
	var legacy: Dictionary = source.get("legacy_web_save", {})
	var legacy_run := _dictionary(legacy.get("run"))
	state["village"] = Village.load_progress(source.get("village", legacy_run.get("village")))
	if not legacy.is_empty() and not source.has("characters"):
		var run := legacy_run
		var permanent := _dictionary(legacy.get("permanent"))
		var records: Variant = run.get("characters", [])
		if records is Array:
			for record in records:
				if _valid_worker(record):
					state.characters.append(record.duplicate(true))
		state.unlocked_sites.merge(_dictionary(run.get("unlockedSites")), true)
		state.unlocked_sites.abandonedMine = true
		state.automation = {"craft": _dictionary(run.get("autoCraft")), "sell_owned": _dictionary(run.get("autoSell")),
			"sell": _dictionary(run.get("autoSellOn")), "target": _dictionary(run.get("craftTarget"))}
		var old_queue := _dictionary(run.get("craftQueue"))
		for id: String in old_queue:
			var time: Variant = old_queue[id]
			if (time is float or time is int) and time > 0.0 and _tables.recipes.has(id):
				state.queue[id] = float(time)
		state.tickets = int(permanent.get("tickets", 0))
		state.first_ticket = bool(permanent.get("firstGachaGranted", false))
		state.hq_level = int(run.get("hqLevel", 0))
		state.craft_facility = int(run.get("craftFacility", 1))
		state.facility = _dictionary(run.get("facility"))
		state.workforce = _dictionary(run.get("workforce"))
		state.tunnel_open = bool(_dictionary(run.get("world")).get("tunnelUnlocked", false))

func snapshot() -> Dictionary:
	var recipes: Array = []
	var resources: Array = []
	var research: Array = []
	var sites: Array = []
	var workers: Array = []
	var assigned: Dictionary = {}
	for record: Dictionary in state.characters:
		var resource_id := str(record.get("resource", ""))
		assigned[resource_id] = int(assigned.get(resource_id, 0)) + 1
		workers.append({"id": record.id, "resource": resource_id, "rarity": record.rarity,
			"name": _label(resource_id), "rating": _tables.rarity.get(record.rarity, {}).get("label", record.rarity)})
	for row: Dictionary in data.resources:
		resources.append({"id": row.key, "name": row.name, "unlocked": is_resource_open(row.key)})
	for row: Dictionary in data.recipes:
		recipes.append({"id": row.key, "name": row.name, "inputs": row.need, "output": row.key,
			"count": row.out, "sell": row.sell, "time": row.craftTime, "remaining": state.queue.get(row.key, 0),
			"workshop_only": row.get("workshopOnly", false), "auto_sell_cost": _auto_sell_cost(row)})
	for row: Dictionary in data.research:
		research.append({"id": row.key, "name": row.name, "cost": _research_cost(row), "requires": row.requires, "description": row.desc})
	for row: Dictionary in data.sites:
		sites.append({"id": row.key, "name": row.name, "cost": {"gold": row.unlockCost, "products": row.unlockProducts},
			"unlocked": state.unlocked_sites.get(row.key, false)})
	return {"gold": state.gold, "inventory": state.inventory, "resources": resources, "recipes": recipes,
		"workers": [{"id": "ticket", "name": "인부 뽑기 (가챠권)", "cost": 0, "tickets": state.tickets},
			{"id": "gold", "name": "인부 뽑기 (골드)", "cost": data.balance.gacha.PULL_COST_GOLD}],
		"owned_workers": assigned, "worker_details": workers, "tickets": state.tickets, "research": research,
		"completed_research": state.completed_research, "stats": state.stats, "automation": state.automation,
		"sites": sites, "upgrades": _upgrade_options(), "deliveries": Delivery.offers(data, state),
		"reputation": Delivery.reputation(data, state), "village": Village.snapshot(data, state.village), "save_error": _save_error}

func is_resource_open(id: String) -> bool:
	var resource: Dictionary = _tables.resources.get(id, {})
	return not resource.is_empty() and bool(state.unlocked_sites.get(resource.site, false))

func mine(id: String) -> bool:
	if not is_resource_open(id):
		return _reject("먼저 채굴 지대를 해금하세요.")
	var amount := (float(_tables.resources[id].base) + float(state.facility.get(id, 0))) * _multiplier()
	_add(id, amount)
	var relic_found := Village.mine(data, state.village, id)
	return _updated("%s +%s%s" % [_label(id), _quantity(amount), " · 미감정 유물 발견" if relic_found else ""])

func craft(id: String) -> bool:
	if not _start_craft(id):
		return _reject("재료가 부족하거나 제작 중이에요.")
	return _updated("%s %s" % [_label(id), "제작 시작" if state.queue.has(id) else "제작 완료"])

func _start_craft(id: String) -> bool:
	var recipe: Dictionary = _tables.recipes.get(id, {})
	if recipe.is_empty() or state.queue.has(id) or not _has(recipe.need):
		return false
	_consume(recipe.need)
	if float(recipe.craftTime) > 0.0:
		state.queue[id] = float(recipe.craftTime)
	else:
		_add(id, float(recipe.out))
	return true

func sell(id: String) -> bool:
	var earned := _sell(id)
	if earned <= 0.0:
		return _reject("판매할 제품이 없어요.")
	return _updated("%s 판매 +%s G" % [_label(id), _quantity(earned)])

func _sell(id: String) -> float:
	var recipe: Dictionary = _tables.recipes.get(id, {})
	var qty := float(state.inventory.get(id, 0))
	if recipe.is_empty() or qty <= 0.0:
		return 0.0
	var earned := qty * float(recipe.sell) * _multiplier()
	state.inventory[id] = 0
	state.gold += earned
	_check_first_ticket()
	return earned

func hire(id: String) -> bool:
	var balance: Dictionary = data.balance.gacha
	if state.characters.size() >= int(data.balance.worker.CAP_BASE):
		return _reject("인부 정원이 가득 찼어요.")
	if id == "ticket" and int(state.tickets) >= int(balance.PULL_COST_TICKET):
		state.tickets -= int(balance.PULL_COST_TICKET)
	elif id == "gold" and float(state.gold) >= float(balance.PULL_COST_GOLD):
		state.gold -= float(balance.PULL_COST_GOLD)
	else:
		return _reject("골드나 가챠권이 부족해요.")
	var roll := randf() * 100.0
	var rarity: Dictionary = data.rarity[0]
	for row: Dictionary in data.rarity:
		roll -= float(row.chance)
		if roll <= 0.0:
			rarity = row
			break
	var available: Array = []
	for row: Dictionary in data.resources:
		if is_resource_open(row.key):
			available.append(row.key)
	var resource_id: String = available.pick_random()
	var worker_id := "%d-%d" % [Time.get_ticks_usec(), randi()]
	state.characters.append({"id": worker_id, "rarity": rarity.key, "resource": resource_id,
		"mining": rarity.mining, "carry": rarity.carry, "move": rarity.move, "miningLvl": 0, "carryLvl": 0, "moveLvl": 0})
	return _updated("%s 인부 고용 · %s 배치" % [rarity.label, _label(resource_id)])

func assign_worker(worker_id: String, resource_id: String) -> bool:
	if not is_resource_open(resource_id):
		return _reject("먼저 채굴 지대를 해금하세요.")
	for worker: Dictionary in state.characters:
		if worker.id == worker_id:
			worker.resource = resource_id
			return _updated("인부 배치 · " + _label(resource_id))
	return false

func unlock(id: String) -> bool:
	var row: Dictionary = _tables.research.get(id, {})
	if row.is_empty() or state.completed_research.get(id, false):
		return false
	for required: String in row.requires:
		if not state.completed_research.get(required, false):
			return _reject("선행 연구가 필요해요.")
	if not _pay(_research_cost(row)):
		return _reject("연구 비용이 부족해요.")
	state.completed_research[id] = true
	return _updated("연구 완료 · " + row.name)

func _research_cost(row: Dictionary) -> Dictionary:
	var cost: Dictionary = row.cost.duplicate()
	var discount := Village.research_discount(data, state.village)
	cost.gold = ceili(float(cost.get("gold", 0)) * (100 - discount) / 100.0)
	return cost

func restore_facility(id: String) -> bool:
	var step := Village.next_stage(data, state.village, id)
	if step.is_empty():
		return _reject("선행 복구가 필요하거나 이미 운영 중이에요.")
	if not _pay(step.cost):
		return _reject("시설 복구 비용이 부족해요.")
	state.village.stage[id] = int(state.village.stage.get(id, 0)) + 1
	return _updated("%s · %s 완료" % [data.village.FACILITIES[id].name, step.name])

func appraise_relic(_id: String) -> bool:
	var relic := Village.appraise(data, state.village)
	if relic.is_empty():
		return _reject("감정소 복구 상태와 유물 수를 확인하세요.")
	return _updated("유물 감정 · " + relic.name)

func donate_relic(id: String) -> bool:
	var village: Dictionary = state.village
	if not Village.is_open(data, village, "museum") or id in village.donated or int(village.owned.get(id, 0)) <= 0:
		return _reject("기증할 새 유물이 없어요.")
	for relic: Dictionary in data.village_relics:
		if relic.key == id:
			village.owned[id] -= 1
			village.donated.append(id)
			return _updated("박물관 기증 · " + relic.name)
	return false

func donate_specimen(id: String) -> bool:
	var village: Dictionary = state.village
	if not Village.is_open(data, village, "museum") or id in Village.specimen_keys(village):
		return false
	for specimen: Dictionary in data.village_specimens:
		if specimen.key == id and _pay({"products": {id: specimen.qty}}):
			village.specimens.append({"key": id, "at": int(Time.get_unix_time_from_system() * 1000)})
			return _updated("박물관 기증 · " + _label(id))
	return _reject("기증할 표본 수가 부족해요.")

func open_site(id: String) -> bool:
	var row: Dictionary = _tables.sites.get(id, {})
	if row.is_empty() or state.unlocked_sites.get(id, false):
		return false
	if not _pay({"gold": row.unlockCost, "products": row.unlockProducts}):
		return _reject("채굴 지대 해금 비용이 부족해요.")
	state.unlocked_sites[id] = true
	return _updated("채굴 지대 해금 · " + row.name)

func upgrade(id: String) -> bool:
	var option := _upgrade_option(id)
	if option.is_empty() or option.level >= option.limit:
		return false
	if not _pay(option.cost):
		return _reject("강화 비용이 부족해요.")
	var field: String = option.field
	var resource: String = option.get("resource", "")
	if resource.is_empty():
		state[field] += 1
	else:
		state[field][resource] = int(state[field].get(resource, 0)) + 1
	return _updated("%s Lv.%d" % [option.name, int(option.level) + 1])

func _upgrade_options() -> Array:
	var options := [_upgrade_option("hq_level"), _upgrade_option("craft_facility")]
	for resource: Dictionary in data.resources:
		if is_resource_open(resource.key):
			options.append(_upgrade_option("facility:" + str(resource.key)))
			options.append(_upgrade_option("workforce:" + str(resource.key)))
	return options

func _upgrade_option(id: String) -> Dictionary:
	if id == "hq_level":
		var rules: Dictionary = data.balance.hq
		var level := int(state.hq_level)
		return {"id": id, "field": id, "name": "본사 투자", "level": level, "limit": int(rules.MAX_LEVEL),
			"cost": {"gold": _level_cost(rules.COST_BASE, rules.COST_GROWTH, level)}}
	if id == "craft_facility":
		var rules: Dictionary = data.balance.crafting
		var level := int(state.craft_facility)
		return {"id": id, "field": id, "name": "제작 시설 강화", "level": level, "limit": int(rules.FACILITY_MAX_LEVEL),
			"cost": {"gold": _level_cost(rules.FACILITY_COST_BASE, rules.FACILITY_COST_GROWTH, level - 1)}}
	var parts := id.split(":", false, 1)
	if parts.size() != 2 or parts[0] not in ["facility", "workforce"] or not is_resource_open(parts[1]):
		return {}
	var field := parts[0]
	var resource := parts[1]
	var prefix := field.to_upper()
	var level := int(state[field].get(resource, 0))
	var rules: Dictionary = data.balance.mining
	var name := _label(resource) + (" 도구 강화" if field == "facility" else " 인력 강화")
	return {"id": id, "field": field, "resource": resource, "name": name, "level": level, "limit": int(rules[prefix + "_MAX_LEVEL"]),
		"cost": {"products": {resource: _level_cost(rules[prefix + "_COST_BASE"], rules[prefix + "_COST_GROWTH"], level)}}}

func _level_cost(base: float, growth: float, level: int) -> int:
	return roundi(base * pow(growth, maxi(0, level)))

func set_auto_craft(id: String, enabled: bool) -> bool:
	if not _tables.recipes.has(id) or not state.completed_research.get("autoCraftDevice", false):
		return _reject("자동 제작 장치 연구가 필요해요.")
	state.automation.craft[id] = enabled
	return _updated()

func set_craft_target(id: String, value: int) -> bool:
	if not _tables.recipes.has(id):
		return false
	state.automation.target[id] = clampi(value, 0, 999999)
	return _updated()

func buy_auto_sell(id: String) -> bool:
	var row: Dictionary = _tables.recipes.get(id, {})
	if row.is_empty() or row.get("workshopOnly", false) or state.automation.sell_owned.get(id, false):
		return false
	if not _pay({"gold": _auto_sell_cost(row)}):
		return _reject("자동 판매를 구매할 골드가 부족해요.")
	state.automation.sell_owned[id] = true
	state.automation.sell[id] = true
	return _updated("자동 판매 구매 · " + row.name)

func set_auto_sell(id: String, enabled: bool) -> bool:
	if not state.automation.sell_owned.get(id, false):
		return false
	state.automation.sell[id] = enabled
	return _updated()

func deliver(id: String) -> bool:
	var result := Delivery.complete(data, state, id)
	if not result.get("ok", false):
		return _reject(result.get("message", "납품할 수 없어요."))
	_check_first_ticket()
	return _updated(result.get("message", "납품 완료"))

func import_save(json_text: String) -> bool:
	if _save_blocked:
		return _reject("기존 저장을 보호하는 중이에요. 가져오기를 적용하지 않았어요.")
	var imported := Save.parse_game(json_text)
	if imported.is_empty():
		imported = Save.import_legacy(json_text)
	if imported.is_empty() or not _valid_save_state(imported):
		return _reject("저장 JSON 형식이나 버전을 확인해 주세요.")
	var old_state := state
	_restore(imported)
	if persistence_enabled and Save.save_game(state) != OK:
		state = old_state
		return _reject("기존 저장을 보호하는 중이에요. 가져오기를 적용하지 않았어요.")
	return _updated("저장 불러오기 완료")

func export_save() -> String:
	_record_position()
	return Save.export_game(state)

func flush() -> void:
	if not persistence_enabled or _save_blocked or data.is_empty():
		return
	_record_position()
	if not _dirty:
		return
	var result := Save.save_game(state)
	if result != OK and result != _save_error:
		feedback.emit("자동 저장에 실패했어요. 저장 탭에서 JSON을 백업할 수 있어요.")
	_save_error = result
	_dirty = result != OK

func _process(delta: float) -> void:
	_elapsed += minf(delta, 0.5)
	_save_elapsed += delta
	var mutated := false
	while _elapsed >= TICK:
		_elapsed -= TICK
		mutated = _tick() or mutated
	if mutated:
		_updated()
	if _save_elapsed >= 2.0:
		_save_elapsed = 0.0
		flush()

func _tick() -> bool:
	var mutated := false
	state.ticket_elapsed += TICK
	var ticket_interval := float(data.balance.gacha.TICKET_TRICKLE_MS) / 1000.0
	if state.ticket_elapsed >= ticket_interval:
		state.ticket_elapsed -= ticket_interval
		state.tickets += 1
		mutated = true
	var mining_rates: Dictionary = {}
	for worker: Dictionary in state.characters:
		var id: String = worker.resource
		var rate := float(worker.mining) * float(worker.carry) * float(worker.move) / float(data.balance.worker.EFFECTIVE_DIVISOR)
		mining_rates[id] = float(mining_rates.get(id, 0.0)) + rate
	for id: String in state.workforce:
		var bonus := float(state.workforce[id]) * float(data.balance.mining.WORKFORCE_BONUS_MULTIPLIER)
		mining_rates[id] = float(mining_rates.get(id, 0.0)) + bonus
	var multiplier := _multiplier()
	for id: String in mining_rates:
		if mining_rates[id] > 0.0 and is_resource_open(id):
			_add(id, float(mining_rates[id]) * multiplier * TICK)
			mutated = true
	var speed := (1.0 + maxf(0.0, float(state.craft_facility) - 1.0) * float(data.balance.crafting.FACILITY_SPEED_PER_LEVEL)) \
		* (1.0 + Delivery.reputation_effect(data, state, "craftSpeed"))
	for id: String in state.queue.keys():
		state.queue[id] -= speed * TICK
		if state.queue[id] <= 0.00001:
			state.queue.erase(id)
			_add(id, float(_tables.recipes[id].out))
		mutated = true
	if state.completed_research.get("autoCraftDevice", false):
		for id: String in state.automation.craft:
			var target := int(state.automation.target.get(id, 0))
			if state.automation.craft[id] and (target == 0 or float(state.inventory.get(id, 0)) < target):
				mutated = _start_craft(id) or mutated
	for id: String in state.automation.sell:
		if state.automation.sell[id] and state.automation.sell_owned.get(id, false):
			if not _tables.recipes.get(id, {}).get("workshopOnly", true):
				mutated = (_sell(id) > 0.0) or mutated
	var delivery := Delivery.tick(data, state, TICK, multiplier)
	for message: String in delivery.get("messages", []):
		feedback.emit(message)
	return bool(delivery.get("changed", false)) or mutated

func _valid_save_state(imported: Dictionary) -> bool:
	if not (imported.get("gold") is int or imported.get("gold") is float) or float(imported.gold) < 0.0:
		return false
	for key in ["inventory", "completed_research", "unlocked_sites", "automation", "queue", "facility", "workforce", "stats", "position", "legacy_web_save", "delivery"]:
		if imported.has(key) and not imported[key] is Dictionary:
			return false
	if not imported.get("inventory") is Dictionary:
		return false
	for id in imported.inventory:
		var qty: Variant = imported.inventory[id]
		if not (qty is int or qty is float) or float(qty) < 0.0:
			return false
	if not imported.get("characters", []) is Array:
		return false
	for worker in imported.get("characters", []):
		if not _valid_worker(worker):
			return false
	for id in imported.get("queue", {}):
		if not _tables.recipes.has(id) or not (imported.queue[id] is int or imported.queue[id] is float):
			return false
	for key in ["craft", "sell_owned", "sell", "target"]:
		if imported.has("automation") and not imported.automation.get(key) is Dictionary:
			return false
	return true

func _valid_worker(worker: Variant) -> bool:
	if not worker is Dictionary:
		return false
	for key in ["id", "rarity", "resource"]:
		if not worker.get(key) is String:
			return false
	for key in ["mining", "carry", "move"]:
		if not (worker.get(key) is int or worker.get(key) is float):
			return false
	return true

func _dictionary(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}

func _record_position() -> void:
	if not is_instance_valid(player) or get_tree().current_scene == null:
		return
	var value := {"scene": get_tree().current_scene.scene_file_path, "x": player.position.x, "y": player.position.y}
	if state.position != value:
		state.position = value
		_dirty = true

func _pay(cost: Dictionary) -> bool:
	var gold := float(cost.get("gold", 0))
	var inputs: Dictionary = cost.get("products", {})
	if state.gold < gold or not _has(inputs):
		return false
	state.gold -= gold
	_consume(inputs)
	return true

func _has(inputs: Dictionary) -> bool:
	for id: String in inputs:
		if float(state.inventory.get(id, 0)) < float(inputs[id]):
			return false
	return true

func _consume(inputs: Dictionary) -> void:
	for id: String in inputs:
		_add(id, -float(inputs[id]))

func _add(id: String, amount: float) -> void:
	state.inventory[id] = float(state.inventory.get(id, 0)) + amount

func _multiplier() -> float:
	return (1.0 + float(state.hq_level) * float(data.balance.hq.MULTIPLIER_PER_LEVEL)) * Delivery.reputation_multiplier(data, state)

func _check_first_ticket() -> void:
	if not state.first_ticket and state.gold >= data.balance.gacha.FIRST_TICKET_GOLD_THRESHOLD:
		state.first_ticket = true
		state.tickets += 1

func _auto_sell_cost(row: Dictionary) -> int:
	return int(row.sell) * int(data.balance.selling.AUTO_SELL_COST_MULTIPLIER)

func _label(id: String) -> String:
	return str(_tables.resources.get(id, _tables.recipes.get(id, {})).get("name", id))

func _quantity(value: float) -> String:
	return str(snappedf(value, 0.01))

func _updated(message := "") -> bool:
	_dirty = true
	changed.emit()
	if not message.is_empty():
		feedback.emit(message)
	return true

func _reject(message: String) -> bool:
	feedback.emit(message)
	return false
