extends RefCounted
## Read-only access to the web game's world data. The values were extracted from the web source
## (Bellsier/gacha-factory-development @ 7484ccd) into data/web_catalog.json; this file only reads that
## catalog (it never writes it) and turns the infinities the JSON could not hold back into INF / -INF.
## Note: JSON numbers arrive as floats, so callers convert counts and cells with int().

const CATALOG_PATH := "res://data/web_catalog.json"
const META_KEY := "mining_world_catalog"

## Read once, then kept: the terrain and village layout ask for it thousands of times per layout.
static var _catalog: Dictionary = {}

static func catalog() -> Dictionary:
	if not _catalog.is_empty():
		return _catalog
	if Engine.has_meta(META_KEY):
		_catalog = Engine.get_meta(META_KEY)
		return _catalog
	var text := FileAccess.get_file_as_string(CATALOG_PATH)
	var parsed: Variant = JSON.parse_string(text)
	var data: Dictionary = parsed if parsed is Dictionary else {}
	if data.is_empty():
		push_error("world: cannot read %s" % CATALOG_PATH)
		return data
	var source: Dictionary = data.get("source", {})
	for p: String in source.get("positive_infinity_encoded_as_null", []):
		_set_path(data, p, INF)
	for p: String in source.get("negative_infinity_encoded_as_null", []):
		_set_path(data, p, -INF)
	Engine.set_meta(META_KEY, data)
	_catalog = data
	return data

static func _set_path(root: Variant, dotted: String, value: float) -> void:
	var parts := dotted.split(".")
	var node: Variant = root
	for i in parts.size() - 1:
		node = node[int(parts[i])] if node is Array else node[parts[i]]
	var last := parts[parts.size() - 1]
	if node is Array:
		node[int(last)] = value
	else:
		node[last] = value

static func terrain() -> Dictionary:
	return catalog().get("world_terrain", {})

static func world() -> Dictionary:
	return catalog().get("balance", {}).get("world", {})

static func world_gen() -> Dictionary:
	return catalog().get("balance", {}).get("worldGen", {})

static func research_balance() -> Dictionary:
	return catalog().get("balance", {}).get("research", {})

static func resources() -> Array:
	return catalog().get("resources", [])

static func sites() -> Array:
	return catalog().get("sites", [])

static func mine_seeds() -> Dictionary:
	return catalog().get("world_mine_seeds", {})

static func starter_ids() -> Dictionary:
	return catalog().get("starter_mine_ids", {"iron": "mine_start_iron", "coal": "mine_start_coal"})

static func player_foot() -> Dictionary:
	return catalog().get("player_foot", {"HALF_W": 0.09, "HALF_H": 0.06})

static func obstacle_boxes() -> Dictionary:
	return catalog().get("world_obstacle_boxes", {})

static func scenery_boxes() -> Dictionary:
	return catalog().get("scenery_block_boxes", {})

static func scenery_fill_step() -> float:
	return float(catalog().get("scenery_fill_step", 0.05))

static func scenery_mine_clear() -> float:
	return float(catalog().get("scenery_mine_clear", 0.9))

static func resource(key: String) -> Dictionary:
	for r: Dictionary in resources():
		if r.key == key:
			return r
	return {}

static func resource_name(key: String) -> String:
	var r := resource(key)
	return str(r.get("name", key))

static func zone_name(key: String) -> String:
	for z: Dictionary in terrain().get("BEYOND", {}).get("ZONES", []):
		if z.key == key:
			return str(z.name)
	return ""
