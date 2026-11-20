extends RefCounted

const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const WorldData := preload("res://scripts/world/world_data.gd")

static func load_progress(source: Variant) -> Dictionary:
	var input: Dictionary = source if source is Dictionary else {}
	var result := {"stage": {}, "unidentified": 0, "digProgress": 0, "appraised": 0,
		"owned": {}, "codex": [], "donated": [], "specimens": []}
	for key: String in result:
		var value: Variant = input.get(key)
		if value is Dictionary and result[key] is Dictionary:
			result[key] = value.duplicate(true)
		elif value is Array and result[key] is Array:
			result[key] = value.duplicate(true)
		elif (value is int or value is float) and result[key] is int:
			result[key] = maxi(0, int(value))
	# Where the village stands (web sanitizeVillageSite / District / Decor). Missing = chosen again on load.
	var sites: Dictionary = input.get("sites") if input.get("sites") is Dictionary else {}
	result["sites"] = {"appraiser": _site(sites.get("appraiser")), "museum": _site(sites.get("museum"))}
	result["district"] = _district(input.get("district"))
	result["decor"] = _decor(input.get("decor"))
	return result

static func _site(raw: Variant) -> Variant:
	if not raw is Dictionary or not _finite(raw.get("x")) or not _finite(raw.get("y")) or not WorldTerrain.in_bounds(float(raw.x), float(raw.y)):
		return null
	return {"x": float(raw.x), "y": float(raw.y)}

static func _district(raw: Variant) -> Variant:
	var site: Variant = _site(raw)
	if site == null:
		return null
	var layout: Variant = raw.get("layout")
	var layouts: int = WorldData.catalog().village.DISTRICT.LAYOUTS.size()
	if not _finite(layout) or floorf(float(layout)) != float(layout) or float(layout) < 0.0 or float(layout) >= layouts:
		return null
	return {"x": site.x, "y": site.y, "layout": int(layout)}

static func _decor(raw: Variant) -> Array:
	var out: Array = []
	if not raw is Array:
		return out
	var V: Dictionary = WorldData.catalog().village
	var kinds: Array = V.DECOR.map(func(d: Dictionary) -> String: return d.key)
	var cells := int(V.GARDEN.COLS) * int(V.GARDEN.ROWS)
	var used := {}
	for d: Variant in raw:
		if not d is Dictionary or not d.get("kind") is String or not d.kind in kinds or not _finite(d.get("cell")):
			continue
		var cell := float(d.cell)
		if floorf(cell) != cell or cell < 0.0 or cell >= cells or used.has(int(cell)):
			continue
		used[int(cell)] = true
		out.append({"kind": d.kind, "cell": int(cell)})
	return out

static func _finite(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))

static func is_open(data: Dictionary, progress: Dictionary, id: String) -> bool:
	var facility: Dictionary = data.village.FACILITIES.get(id, {})
	return not facility.is_empty() and int(progress.stage.get(id, 0)) >= facility.stages.size()

static func next_stage(data: Dictionary, progress: Dictionary, id: String) -> Dictionary:
	var facility: Dictionary = data.village.FACILITIES.get(id, {})
	if facility.is_empty() or is_open(data, progress, id):
		return {}
	var requirement: Variant = facility.get("requires")
	if requirement is String and not is_open(data, progress, requirement):
		return {}
	return facility.stages[clampi(int(progress.stage.get(id, 0)), 0, facility.stages.size() - 1)]

static func mine(data: Dictionary, progress: Dictionary, id: String, beyond := false) -> bool:
	var rules: Dictionary = data.village.RELIC
	if int(progress.unidentified) >= int(rules.MAX_UNIDENTIFIED):
		return false
	var step := int(rules.RELIC_VEIN_STEP if id == "relic" else rules.BEYOND_STEP if beyond else rules.STEP)
	progress.digProgress += step
	if progress.digProgress < rules.EVERY:
		return false
	progress.digProgress -= int(rules.EVERY)
	progress.unidentified += 1
	return true

static func appraise(data: Dictionary, progress: Dictionary) -> Dictionary:
	if not is_open(data, progress, "appraiser") or progress.unidentified <= 0:
		return {}
	var weights: Array[int] = []
	var total := 0
	for relic: Dictionary in data.village_relics:
		var weight := int(relic.weight) * (1 if relic.key in progress.codex else int(data.village.RELIC.NEW_BOOST))
		weights.append(weight)
		total += weight
	var roll := _hash_01(progress.appraised) * total
	for index: int in weights.size():
		roll -= weights[index]
		if roll < 0.0:
			var relic: Dictionary = data.village_relics[index]
			progress.unidentified -= 1
			progress.appraised += 1
			progress.owned[relic.key] = int(progress.owned.get(relic.key, 0)) + 1
			if relic.key not in progress.codex:
				progress.codex.append(relic.key)
			return relic
	return {}

static func specimen_keys(progress: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for row in progress.specimens:
		if row is Dictionary and row.get("key") is String and row.key not in keys:
			keys.append(row.key)
	return keys

static func research_discount(data: Dictionary, progress: Dictionary) -> int:
	var discount := 0
	var count: int = progress.donated.size() + specimen_keys(progress).size()
	for reward: Dictionary in data.village_museum_rewards:
		if reward.type == "research" and count >= int(reward.need):
			discount = maxi(discount, int(reward.percent))
	return discount

static func snapshot(data: Dictionary, progress: Dictionary) -> Dictionary:
	var facilities: Array = []
	var relics: Array = []
	var specimens: Array = []
	var specimen_ids := specimen_keys(progress)
	var museum := is_open(data, progress, "museum")
	for id: String in data.village.ORDER:
		var facility: Dictionary = data.village.FACILITIES[id]
		var stage := clampi(int(progress.stage.get(id, 0)), 0, facility.stages.size())
		var step := next_stage(data, progress, id)
		facilities.append({"id": id, "name": facility.name, "stage": data.village.STAGE_NAMES[stage],
			"step": step, "open": is_open(data, progress, id)})
	for relic: Dictionary in data.village_relics:
		if relic.key in progress.codex or relic.key in progress.donated:
			relics.append({"id": relic.key, "name": relic.name, "quantity": progress.owned.get(relic.key, 0),
				"donated": relic.key in progress.donated})
	if museum:
		for specimen: Dictionary in data.village_specimens:
			specimens.append({"id": specimen.key, "quantity": specimen.qty, "donated": specimen.key in specimen_ids})
	return {"facilities": facilities, "can_appraise": is_open(data, progress, "appraiser") and progress.unidentified > 0,
		"unidentified": progress.unidentified, "relics": relics, "specimens": specimens, "museum": museum,
		"donations": progress.donated.size() + specimen_ids.size(), "total": data.village_relics.size() + data.village_specimens.size(),
		"discount": research_discount(data, progress)}

static func _hash_01(value: int) -> float:
	var bits := _multiply_32((value + 1) ^ 0x9e3779b9, 2654435761)
	bits = _multiply_32(bits ^ (bits >> 15), 2246822519)
	return float(bits ^ (bits >> 13)) / 4294967296.0

static func _multiply_32(a: int, b: int) -> int:
	return (((a & 0xffff) * b) + ((((a >> 16) & 0xffff) * (b & 0xffff)) << 16)) & 0xffffffff
