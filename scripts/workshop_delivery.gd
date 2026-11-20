extends RefCounted
## Company progress and order rules ported from develop 7484ccd (js/delivery.js).

static func reputation(data: Dictionary, state: Dictionary) -> int:
	return int(_delivery(data, state).get("reputation", 0))


static func reputation_multiplier(data: Dictionary, state: Dictionary) -> float:
	var rules := _rules(data, "reputation")
	var points := mini(reputation(data, state), int(rules.get("MAX", 36)))
	var soft_cap := int(rules.get("MULT_SOFT_AT", 18))
	# web mult(): 1 + reputationMultiplierBonus(), the bonus summed first (floating-point addition is not associative).
	return 1.0 + (mini(points, soft_cap) * float(rules.get("MULT_PER_POINT", 0.12)) \
		+ maxi(0, points - soft_cap) * float(rules.get("MULT_PER_POINT_SOFT", 0.045)))


static func reputation_effect(data: Dictionary, state: Dictionary, id: String) -> float:
	var points := reputation(data, state)
	for effect: Dictionary in data.get("reputation_effects", []):
		if effect.get("key") == id and effect.get("unit") != "multiplier" and points >= int(effect.get("unlock", 0)):
			var cap := int(_rules(data, "reputation").get("MAX", 36))
			var amount := mini(points, cap) * float(effect.get("perPoint", 0.0))
			return minf(amount, float(effect.get("max", amount)))
	return 0.0


static func offers(data: Dictionary, state: Dictionary) -> Array:
	var companies := _company_progress(data, state)
	var result: Array = []
	var inventory: Dictionary = state.get("inventory", {})
	for company: Dictionary in _open_companies(data, state):
		var company_id := String(company["key"])
		var progress: Dictionary = companies[company_id]
		var orders: Array = progress["open"]
		for slot in orders.size():
			var order: Dictionary = orders[slot]
			var product := String(order["product"])
			var qty := int(order["qty"])
			var recipe := _recipe(data, product)
			if recipe.is_empty():
				continue
			var shipping_cost := _shipping_cost(data, state, company, recipe, qty)
			var fixed_index := int(order["index"])
			var serial := fixed_index if fixed_index >= 0 else int(progress["repeatDone"])
			var kind := "fixed" if fixed_index >= 0 else "repeat"
			result.append({
				"id": "%s:%s:%d:%s:%d" % [company_id, kind, serial, product, slot],
				"company_id": company_id, "company_name": String(company["name"]),
				"product": product, "product_name": String(recipe["name"]), "qty": qty,
				"shipping_cost": shipping_cost, "slot": slot, "index": fixed_index,
				"reputation": _order_reputation(data, recipe, qty) if fixed_index >= 0 else 0,
				"gold_reward": _repeat_pay(data, state, recipe, qty) if fixed_index < 0 else 0,
				"can_complete": float(inventory.get(product, 0)) >= qty and float(state.get("gold", 0)) >= shipping_cost,
			})
	return result


static func complete(data: Dictionary, state: Dictionary, id: String) -> Dictionary:
	for order: Dictionary in offers(data, state):
		if order["id"] != id:
			continue
		if not bool(order["can_complete"]):
			return _result(false, "납품할 제품이나 배송비가 부족합니다.")
		var companies := _company_progress(data, state)
		var progress: Dictionary = companies[order["company_id"]]
		var company := _company(data, String(order["company_id"]))
		var qty := int(order["qty"])
		var product := String(order["product"])
		_apply_shipment(data, state, company, progress, _recipe(data, product), qty, int(order["shipping_cost"]))
		var open: Array = progress["open"]
		open.remove_at(int(order["slot"]))
		var company_name := String(order["company_name"])
		if int(order["index"]) >= 0:
			progress["orderIndex"] = int(progress["orderIndex"]) + 1
			var gained := int(order["reputation"])
			var delivery := _delivery(data, state)
			delivery["reputation"] = int(delivery["reputation"]) + gained
			return _result(true, "%s의 수주 완료 · 명성 +%d" % [company_name, gained])
		progress["repeatDone"] = int(progress["repeatDone"]) + 1
		progress["lastRepeat"] = product
		var reward := float(order["gold_reward"])
		state["gold"] = float(state["gold"]) + reward
		return _result(true, "%s의 추가 수주 완료 · +%.1fG" % [company_name, reward])
	return _result(false, "현재 받을 수 있는 수주가 아닙니다.")


static func ship(data: Dictionary, state: Dictionary, company_id: String, product: String, qty: int) -> Dictionary:
	var recipe := _recipe(data, product)
	if qty <= 0 or recipe.is_empty():
		return _result(false, "납품할 제품이나 수량을 확인해 주세요.")
	for company: Dictionary in _open_companies(data, state):
		if company["key"] != company_id:
			continue
		var cost := _shipping_cost(data, state, company, recipe, qty)
		var inventory: Dictionary = state.get("inventory", {})
		if float(inventory.get(product, 0)) < qty or float(state.get("gold", 0)) < cost:
			return _result(false, "납품할 제품이나 배송비가 부족합니다.")
		var progress: Dictionary = _company_progress(data, state)[company_id]
		_apply_shipment(data, state, company, progress, recipe, qty, cost)
		return _result(true, "%s에 %s %d개를 납품했습니다." % [company["name"], recipe["name"], qty])
	return _result(false, "아직 거래할 수 없는 회사입니다.")


static func tick(data: Dictionary, state: Dictionary, delta: float, economy_multiplier: float = -1.0) -> Dictionary:
	var messages: Array = []
	if delta <= 0.0:
		return {"changed": false, "messages": messages}
	var companies := _company_progress(data, state)
	var rep := reputation(data, state)
	var rate := economy_multiplier if economy_multiplier >= 0.0 else _economy_multiplier(data, state)
	var order_rules := _rules(data, "orders")
	var max_rep := maxf(1.0, float(_rules(data, "reputation").get("MAX", 36)))
	var arrival := lerpf(float(order_rules.get("ARRIVAL_SEC_START", 1500)),
		float(order_rules.get("ARRIVAL_SEC_MIN", 300)), minf(1.0, rep / max_rep))
	var cap := 2 if rep >= int(order_rules.get("SECOND_SLOT_AT", 18)) else 1
	for company: Dictionary in _open_companies(data, state):
		var progress: Dictionary = companies[company["key"]]
		var orders: Array = progress["open"]
		if orders.size() >= cap:
			progress["orderTimer"] = 0.0
		else:
			progress["orderTimer"] = float(progress["orderTimer"]) + delta
			if float(progress["orderTimer"]) >= arrival:
				# Original tickOrders: the timer restarts at 0 when an order is issued; overflow is not carried.
				progress["orderTimer"] = 0.0
				var order := _next_order(data, state, company, progress)
				if not order.is_empty():
					orders.append(order)
					messages.append("%s의 새 수주가 도착했습니다." % company["name"])
		if float(progress["score"]) >= float(company.get("regularScore", INF)):
			var trade_message := _regular_trade(data, state, company, progress, delta, rate)
			if not trade_message.is_empty():
				messages.append(trade_message)
	return {"changed": not messages.is_empty(), "messages": messages}


static func _delivery(data: Dictionary, state: Dictionary) -> Dictionary:
	var existing: Variant = state.get("delivery")
	if existing is Dictionary and existing.get("companies") is Dictionary:
		var companies: Dictionary = existing["companies"]
		for company: Dictionary in data.get("companies", []):
			var id := String(company["key"])
			var previous := _as_dictionary(companies.get(id))
			if not previous.get("open") is Array or not previous.get("sent") is Dictionary or not previous.has_all(["score", "orderIndex", "tradeTimer", "orderTimer", "repeatDone", "lastRepeat"]):
				companies[id] = _normalize_progress(data, company, previous)
		if not existing.get("reputation") is int and not existing.get("reputation") is float:
			existing["reputation"] = 0
		return existing
	var legacy := _as_dictionary(_as_dictionary(state.get("legacy_web_save")).get("permanent"))
	var old_companies := _as_dictionary(legacy.get("companies"))
	var result := {"reputation": int(_nonnegative(legacy.get("totalPrestige"))), "companies": {}}
	for company: Dictionary in data.get("companies", []):
		var id := String(company["key"])
		var previous := _as_dictionary(old_companies.get(id))
		result["companies"][id] = _normalize_progress(data, company, previous)
	state["delivery"] = result
	return result


static func _normalize_progress(data: Dictionary, company: Dictionary, previous: Dictionary) -> Dictionary:
	var fixed: Array = company.get("orders", [])
	var index := mini(int(_nonnegative(previous.get("orderIndex"))), fixed.size())
	var orders: Array = []
	var had_fixed := false
	var old_orders: Variant = previous.get("open")
	if old_orders is Array:
		for value: Variant in old_orders:
			if not value is Dictionary or orders.size() >= 2:
				continue
			var old_index := -1
			if value.get("index") is float or value.get("index") is int:
				old_index = int(value["index"])
			if old_index >= 0:
				if not had_fixed and old_index == index and index < fixed.size():
					orders.append(_fixed_order(fixed, index))
					had_fixed = true
			elif index >= 1:
				var product: String = value["product"] if value.get("product") is String else ""
				var qty := int(_nonnegative(value.get("qty")))
				if qty > 0 and qty <= int(_rules(data, "orders").get("REPEAT_MAX_QTY", 100)) and not _recipe(data, product).is_empty():
					orders.append({"product": product, "qty": qty, "index": -1})
	elif index < fixed.size():
		orders.append(_fixed_order(fixed, index))
	var sent := _as_dictionary(previous.get("sent")).duplicate()
	for product: Variant in sent:
		sent[product] = _nonnegative(sent[product])
	return {
		"score": _nonnegative(previous.get("score")), "orderIndex": index,
		"sent": sent, "open": orders,
		"tradeTimer": _nonnegative(previous.get("tradeTimer")),
		"orderTimer": _nonnegative(previous.get("orderTimer")),
		"repeatDone": int(_nonnegative(previous.get("repeatDone"))),
		"lastRepeat": previous.get("lastRepeat"),
	}


static func _open_companies(data: Dictionary, state: Dictionary) -> Array:
	var research: Dictionary = state.get("completed_research", {})
	var result: Array = []
	if not bool(research.get("deliveryContract", false)):
		return result
	var slots := 0
	var rep := reputation(data, state)
	for threshold: Variant in _rules(data, "delivery").get("SLOT_THRESHOLDS", [0, 5, 15]):
		if rep >= int(threshold):
			slots += 1
	var companies: Array = data.get("companies", [])
	var world := _as_dictionary(state.get("world"))
	var tunnel_open := bool(state.get("tunnel_open", world.get("tunnelUnlocked", false)))
	for i in mini(maxi(1, slots), companies.size()):
		var company: Dictionary = companies[i]
		if bool(company.get("needsTunnel", false)) and not tunnel_open:
			continue
		var available := true
		for required: String in company.get("requires", []):
			available = available and bool(research.get(required, false))
		if available:
			result.append(company)
	return result


static func _next_order(data: Dictionary, state: Dictionary, company: Dictionary, progress: Dictionary) -> Dictionary:
	var order_index := int(progress["orderIndex"])
	var fixed: Array = company.get("orders", [])
	var open: Array = progress["open"]
	var has_fixed := false
	for order: Dictionary in open:
		has_fixed = has_fixed or int(order["index"]) >= 0
	if not has_fixed and order_index < fixed.size():
		return _fixed_order(fixed, order_index)
	if fixed.is_empty() or (order_index < fixed.size() and (open.is_empty() or order_index < 1)):
		return {}
	# Original repeatCandidates: favorite recipes whose raw resources are all in unlocked areas.
	# Stock does not count: a material from a locked area in the bag does not open a repeat order.
	var candidates: Array[String] = []
	for product: String in company.get("favorites", []):
		var recipe := _recipe(data, product)
		if not recipe.is_empty() and not _needs_locked_resource(data, state, recipe, []):
			candidates.append(product)
	if candidates.is_empty():
		return {}
	if candidates.size() > 1 and progress["lastRepeat"] is String:
		candidates.erase(String(progress["lastRepeat"]))
	var product: String = candidates.pick_random()
	var rules := _rules(data, "orders")
	var last: Dictionary = fixed.back()
	var last_recipe := _recipe(data, String(last["product"]))
	var sell := maxf(1.0, float(_recipe(data, product).get("sell", 0)))
	var base := maxi(1, roundi(float(rules.get("REPEAT_VALUE_SHARE", 0.3)) * int(last["qty"]) * float(last_recipe.get("sell", 0)) / sell))
	var lap := floori(float(progress["repeatDone"]) / fixed.size())
	var factor := minf(float(rules.get("REPEAT_QTY_CAP_MULT", 2)), 1.0 + float(rules.get("REPEAT_LAP_GROWTH", 0.2)) * lap)
	var qty := clampi(roundi(base * factor), 1, int(rules.get("REPEAT_MAX_QTY", 100)))
	return {"product": product, "qty": qty, "index": -1}


## recipeNeedsLockedResource: any raw resource under the recipe (sub-recipes followed once each,
## unknown keys ignored) whose site is not unlocked.
static func _needs_locked_resource(data: Dictionary, state: Dictionary, recipe: Dictionary, seen: Array) -> bool:
	var unlocked := _as_dictionary(state.get("unlocked_sites", state.get("unlockedSites")))
	for ingredient: String in _as_dictionary(recipe.get("need")):
		var resource := _resource(data, ingredient)
		if not resource.is_empty():
			if not bool(unlocked.get(String(resource.get("site", "")), false)):
				return true
			continue
		var sub := _recipe(data, ingredient)
		if not sub.is_empty() and not seen.has(ingredient):
			if _needs_locked_resource(data, state, sub, seen + [ingredient]):
				return true
	return false


static func _resource(data: Dictionary, id: String) -> Dictionary:
	for resource: Dictionary in data.get("resources", []):
		if resource.get("key") == id:
			return resource
	return {}


static func _regular_trade(data: Dictionary, state: Dictionary, company: Dictionary, progress: Dictionary, delta: float, economy_multiplier: float) -> String:
	var rules := _rules(data, "delivery")
	var research_rules := _rules(data, "research")
	var research: Dictionary = state.get("completed_research", {})
	var interval := float(research_rules.get("TRADE_INTERVAL_SEC", 40)) if research.get("fastTrade", false) else float(rules.get("TRADE_INTERVAL_SEC", 60))
	progress["tradeTimer"] = minf(interval, float(progress["tradeTimer"]) + delta)
	if float(progress["tradeTimer"]) < interval:
		return ""
	var trade_qty := int(research_rules.get("TRADE_QTY", 10)) if research.get("tradeExpansion", false) else int(rules.get("TRADE_QTY", 5))
	var reserve := int(rules.get("TRADE_RESERVE", 10))
	var inventory: Dictionary = state.get("inventory", {})
	for product: String in company.get("favorites", []):
		var qty := mini(trade_qty, floori(float(inventory.get(product, 0))) - reserve)
		var recipe := _recipe(data, product)
		if qty <= 0 or recipe.is_empty():
			continue
		var earned := qty * float(recipe["sell"]) * float(rules.get("TRADE_PRICE_MULT", 1.3)) \
			* (1.0 + reputation_effect(data, state, "tradePrice")) * economy_multiplier
		inventory[product] = float(inventory[product]) - qty
		state["gold"] = float(state.get("gold", 0)) + earned
		progress["tradeTimer"] = 0.0
		return "%s 정기 거래 · %s %d개, +%.1fG" % [company["name"], recipe["name"], qty, earned]
	return ""


static func _apply_shipment(data: Dictionary, state: Dictionary, company: Dictionary, progress: Dictionary, recipe: Dictionary, qty: int, cost: int) -> void:
	var inventory: Dictionary = state["inventory"]
	var sent: Dictionary = progress["sent"]
	var product := String(recipe["key"])
	var previous_qty := float(sent.get(product, 0))
	progress["score"] = float(progress["score"]) + _score(data, company, progress, recipe, qty)
	sent[product] = previous_qty + qty
	inventory[product] = float(inventory[product]) - qty
	state["gold"] = float(state["gold"]) - cost


## The score `qty` of a product adds for a company (web deliveryScore): each unit weighs less the more of it was
## already sent (down to REPEAT_MIN_WEIGHT), favourites count FAVORITE_MULT times.
static func _score(data: Dictionary, company: Dictionary, progress: Dictionary, recipe: Dictionary, qty: int) -> float:
	var rules := _rules(data, "delivery")
	var previous_qty := float(_as_dictionary(progress.get("sent")).get(String(recipe["key"]), 0))
	var decay := float(rules.get("REPEAT_DECAY_UNITS", 200))
	var floor_weight := float(rules.get("REPEAT_MIN_WEIGHT", 0.25))
	var weighted_units := minf(qty, maxf(0.0, decay * (1.0 - floor_weight) - previous_qty))
	var slope := weighted_units * (1.0 - previous_qty / decay) - weighted_units * (weighted_units - 1.0) / (2.0 * decay)
	var favorite := float(rules.get("FAVORITE_MULT", 1.5)) if company["favorites"].has(String(recipe["key"])) else 1.0
	return (slope + (qty - weighted_units) * floor_weight) * float(recipe["sell"]) * favorite


## The 납품 tab's company cards (web renderDelivery, companyClosedReason, companyScoreText, tradeStatusText) and
## reputation effects (renderReputation). `trade_interval` is the regular trade's interval (빠른 거래 shortens it).
static func companies_view(data: Dictionary, state: Dictionary, trade_interval: float) -> Dictionary:
	var research: Dictionary = state.get("completed_research", {})
	var open_ids := {}
	for company: Dictionary in _open_companies(data, state):
		open_ids[company["key"]] = true
	var rep := reputation(data, state)
	var thresholds: Array = _rules(data, "delivery").get("SLOT_THRESHOLDS", [0, 5, 15])
	var slots := 0
	for threshold: Variant in thresholds:
		if rep >= int(threshold):
			slots += 1
	var companies: Array = data.get("companies", [])
	slots = clampi(slots, 1, companies.size())
	var world := _as_dictionary(state.get("world"))
	var tunnel_open := bool(state.get("tunnel_open", world.get("tunnelUnlocked", false)))
	var progress_all := _company_progress(data, state)
	var reserve := float(_rules(data, "delivery").get("TRADE_RESERVE", 10))
	var inventory: Dictionary = state.get("inventory", {})
	var cards: Array = []
	for i in companies.size():
		var company: Dictionary = companies[i]
		var id := String(company["key"])
		var favorites: Array = []
		for k: String in company["favorites"]:
			favorites.append(String(_recipe(data, k).get("name", k)))
		var card := {"id": id, "name": company["name"], "desc": company["desc"], "open": open_ids.has(id), "closed": "",
			"favorites": favorites, "score": ""}
		if not card.open:
			if not bool(research.get("deliveryContract", false)):
				card.closed = "연구 탭에서 \"납품 계약\"을 연구하면 만날 수 있어요."
			elif i >= slots:
				card.closed = "명성 %d점이 되면 거래할 수 있어요. (현재 %d점)" % [int(thresholds[i]), rep]
			elif bool(company.get("needsTunnel", false)) and not tunnel_open:
				card.closed = "터널이 뚫려야 닿을 수 있어요. (연구 \"터널 굴착\" 후 공사를 의뢰하세요)"
			cards.append(card)
			continue
		var progress: Dictionary = progress_all[id]
		var score := "점수 %d / %d" % [floori(float(progress["score"])), int(company["regularScore"])]
		if float(progress["score"]) >= float(company["regularScore"]):
			var left := maxf(0.0, trade_interval - float(progress["tradeTimer"]))
			var product := ""
			for k: String in company["favorites"]:
				if float(inventory.get(k, 0)) >= reserve + 1.0:
					product = k
					break
			var when := "%d초 뒤 거래" % ceili(left) if left > 0.0 else ("곧 거래" if not product.is_empty() else "선호 제품을 기다리는 중")
			score += " · 정기 거래 중 (%s)" % when
		card.score = score
		cards.append(card)
	var effects: Array = []
	for effect: Dictionary in data.get("reputation_effects", []):
		var opened := rep >= int(effect.get("unlock", 0))
		var text := "명성 %d점에서 열려요" % int(effect.get("unlock", 0))
		if opened:
			if effect.get("unit") == "multiplier":
				text = "×%.2f" % reputation_multiplier(data, state)
			else:
				var size := reputation_effect(data, state, String(effect["key"]))
				text = ("-" if effect["key"] == "shippingDiscount" else "+") + "%d%%" % roundi(size * 100.0)
		effects.append({"name": effect["name"], "text": text, "desc": effect["desc"], "open": opened})
	return {"companies": cards, "effects": effects}


## What a free delivery of `qty` of a product to a company would cost and add (web deliveryPreviewText).
static func preview(data: Dictionary, state: Dictionary, company_id: String, product: String, qty: int) -> Dictionary:
	var recipe := _recipe(data, product)
	var company := _company(data, company_id)
	if recipe.is_empty() or company.is_empty() or qty <= 0:
		return {}
	var progress: Dictionary = _company_progress(data, state)[company_id]
	return {"cost": _shipping_cost(data, state, company, recipe, qty), "score": _score(data, company, progress, recipe, qty),
		"have": float(state.get("inventory", {}).get(product, 0))}


static func _shipping_cost(data: Dictionary, state: Dictionary, company: Dictionary, recipe: Dictionary, qty: int) -> int:
	return ceili(qty * float(recipe["sell"]) * float(_rules(data, "delivery").get("SHIPPING_RATE", 0.1)) \
		* float(company["distance"]) * (1.0 - reputation_effect(data, state, "shippingDiscount")))


static func _order_reputation(data: Dictionary, recipe: Dictionary, qty: int) -> int:
	var rules := _rules(data, "delivery")
	return clampi(floori(sqrt(qty * float(recipe["sell"]) / float(rules.get("ORDER_VALUE_DIVISOR", 100)))),
		0, int(rules.get("ORDER_REPUTATION_CAP", 4)))


static func _repeat_pay(data: Dictionary, state: Dictionary, recipe: Dictionary, qty: int) -> float:
	return qty * float(recipe["sell"]) * float(_rules(data, "orders").get("REPEAT_PAY_MULT", 1.2)) \
		* (1.0 + reputation_effect(data, state, "tradePrice")) * _economy_multiplier(data, state)


static func _economy_multiplier(data: Dictionary, state: Dictionary) -> float:
	var run := _as_dictionary(_as_dictionary(state.get("legacy_web_save")).get("run"))
	var hq_level := _nonnegative(state.get("hq_level", state.get("hqLevel", run.get("hqLevel", 0))))
	var hq_multiplier := 1.0 + hq_level * float(_rules(data, "hq").get("MULTIPLIER_PER_LEVEL", 0.08))
	return hq_multiplier * reputation_multiplier(data, state)


static func _fixed_order(fixed: Array, index: int) -> Dictionary:
	var order: Dictionary = fixed[index].duplicate()
	order["index"] = index
	return order


static func _company_progress(data: Dictionary, state: Dictionary) -> Dictionary:
	return _delivery(data, state)["companies"]


static func _recipe(data: Dictionary, id: String) -> Dictionary:
	for recipe: Dictionary in data.get("recipes", []):
		if recipe.get("key") == id:
			return recipe
	return {}


static func _company(data: Dictionary, id: String) -> Dictionary:
	for company: Dictionary in data.get("companies", []):
		if company.get("key") == id:
			return company
	return {}


static func _rules(data: Dictionary, id: String) -> Dictionary:
	return _as_dictionary(_as_dictionary(data.get("balance")).get(id))


static func _as_dictionary(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _nonnegative(value: Variant) -> float:
	if not value is float and not value is int:
		return 0.0
	var number := float(value)
	# Kept below 2^53 so the int() conversions of counts stay exact (int() of 1e300 is INT64_MIN).
	return clampf(number, 0.0, 9007199254740992.0) if is_finite(number) else 0.0


static func _result(ok: bool, message: String) -> Dictionary:
	return {"ok": ok, "message": message}
