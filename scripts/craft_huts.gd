extends RefCounted
## Craft huts (제작소): the buildings round the workshop that each make one chosen recipe, by hand or
## automatically. Ported from the web original (Bellsier/gacha-factory-development @ 7484ccd):
## js/factory.js (addWorkshop .. setWorkshopRecipe, workshopStatus), js/state.js (sanitizeWorkshop),
## js/research.js (maxWorkshops, researchSyncFromState).
##
## A hut is saved exactly in the web shape, in state.world.workshops:
##   {id, x, y, level, recipeKey (String or null), auto (bool), progress (seconds left, or null)}
## so a web save's huts load unchanged and a Godot save keeps them in the same place.
##
## Only pure rules live here. Paying, stock and the tick are in workshop.gd, next to the recipe cards.
## Drawing the huts is in scripts/world/world_map.gd; the village they keep clear of in scripts/village_layout.gd.

const WorldData := preload("res://scripts/world/world_data.gd")
const WorldTerrain := preload("res://scripts/world/world_terrain.gd")
const VillageLayout := preload("res://scripts/village_layout.gd")

## The 256 test world's edge (web WORLD256.EDGE): saved cells there may reach +-31.
const SEEDED_EDGE := 31
const TWO_53 := 9007199254740992.0


## The huts of a saved world, cleaned like the web sanitizeWorkshops: entries that are not objects are
## dropped, a bad cell becomes 0, a bad level 1, an unknown recipe null, a non-boolean auto false, a progress
## that is not a positive number null, and a missing or repeated id is replaced by a new one.
static func sanitize(raw: Variant, recipes: Dictionary, seeded := false) -> Array:
	var huts: Array = []
	if not raw is Array:
		return huts
	for entry: Variant in raw:
		if not entry is Dictionary:
			continue
		var w: Dictionary = entry
		var recipe: Variant = w.get("recipeKey")
		var progress: Variant = w.get("progress")
		var hut := {
			"x": int(w.x) if is_valid_cell(w.get("x"), "x", seeded) else 0,
			"y": int(w.y) if is_valid_cell(w.get("y"), "y", seeded) else 0,
			"level": int(w.level) if _is_whole(w.get("level")) and float(w.level) >= 1.0 else 1,
			"recipeKey": recipe if recipe is String and recipes.has(recipe) else null,
			"auto": w.get("auto") if w.get("auto") is bool else false,
			"progress": float(progress) if _is_number(progress) and float(progress) > 0.0 else null,
		}
		if w.get("id") is String and not str(w.id).is_empty():
			hut["id"] = w.id
		huts.append(hut)
	var seen := {}
	for hut: Dictionary in huts:
		if not hut.has("id") or seen.has(hut.id):
			hut["id"] = new_id(seen)
		seen[hut.id] = true
	# Keys in the web order, so a hut reads the same in a saved file.
	var ordered: Array = []
	for hut: Dictionary in huts:
		ordered.append({"id": hut.id, "x": hut.x, "y": hut.y, "level": hut.level, "recipeKey": hut.recipeKey,
			"auto": hut.auto, "progress": hut.progress})
	return ordered


## web isValidWorldX/Y: an integer inside the world bounds (the 256 test world: |v| <= 31).
static func is_valid_cell(value: Variant, axis: String, seeded := false) -> bool:
	if not _is_number(value) or floorf(float(value)) != float(value):
		return false
	var v := float(value)
	if seeded:
		return absf(v) <= SEEDED_EDGE
	var b := WorldData.world()
	var low: float = b.BOUNDS_MIN_Y if axis == "y" else b.BOUNDS_MIN_X
	var high: float = b.BOUNDS_MAX_Y if axis == "y" else b.BOUNDS_MAX_X
	return v >= low and v <= high


## web makeEntityId(prefix, ...): the prefix, the time in base 36 and six random base-36 characters.
static func new_id(taken: Dictionary, prefix := "workshop_") -> String:
	var id := ""
	while id.is_empty() or taken.has(id):
		id = prefix + _base36(int(Time.get_unix_time_from_system() * 1000.0))
		for i in 6:
			id += "0123456789abcdefghijklmnopqrstuvwxyz"[randi() % 36]
	return id


# --- building -------------------------------------------------------------------------------------------

## Gold for the next hut: ceil(BUILD_COST_BASE * BUILD_COST_GROWTH ^ huts already built) (web workshopBuildCost).
static func build_cost(data: Dictionary, count: int) -> int:
	var rules: Dictionary = data.balance.workshop
	return ceili(float(rules.BUILD_COST_BASE) * pow(float(rules.BUILD_COST_GROWTH), count))


## Parts the next hut takes on top of the gold, keyed by its number ({} for the first six).
static func build_products(data: Dictionary, count: int) -> Dictionary:
	var parts: Variant = data.balance.workshop.BUILD_PRODUCTS.get(str(count + 1), {})
	return (parts as Dictionary).duplicate() if parts is Dictionary else {}


## How many huts may stand: 6, or 8 after 제작소 증축 (web maxWorkshops).
static func max_count(data: Dictionary, research: Dictionary) -> int:
	if research.get("workshopExpansion", false) == true:
		return int(data.balance.research.MAX_WORKSHOPS)
	return int(data.balance.workshop.MAX_COUNT)


## The first open cell of the rings round the base (radius 1 to 4), clear of rock, the tunnel mouth, the base,
## every vein (hidden ones too), the other huts and, with `world` and `village` given, the village sites, plaza,
## house, garden and roads (web workshopBuildSpot). While such a cell is free, a new hut is not put right behind
## the cabin nor door to door beside another hut, nor where the roads laid round the huts would cross a hut.
## `any_only` asks only whether any cell is free. Returns Vector2i, or null when there is none.
static func build_spot(base: Vector2i, mines: Array, huts: Array, seeded := false, any_only := false,
		world: RefCounted = null, village := {}) -> Variant:
	var taken := {Vector2i(base.x, base.y): true}
	for m: Dictionary in mines:
		taken[Vector2i(int(m.x), int(m.y))] = true
	for w: Dictionary in huts:
		taken[Vector2i(int(w.x), int(w.y))] = true
	var V: Dictionary = VillageLayout.V()
	var has_village := world != null and not village.is_empty()
	var roads: Array = VillageLayout.roads(world, village) if has_village else []
	for spaced: bool in ([false] if any_only else [true, false]):
		for r in range(1, 5):
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if maxi(absi(dx), absi(dy)) != r:
						continue
					var x := base.x + dx
					var y := base.y + dy
					if not is_valid_cell(x, "x", seeded) or not is_valid_cell(y, "y", seeded):
						continue
					if not WorldTerrain.is_cell_open_for_mines(x, y) or taken.has(Vector2i(x, y)):
						continue
					if has_village and (VillageLayout.site_near(village, x, y, V.SITE.WORKSHOP_CLEAR) \
							or VillageLayout.ground_near(world, village, roads, x, y, V.DISTRICT.BUILD_CLEAR)):
						continue
					if spaced and (_crowded(base, huts, x, y) or (has_village and not _roads_keep_off(world, village, x, y))):
						continue
					return Vector2i(x, y)
	return null


## With a hut at (x, y) the roads are laid round it again: they must keep off every hut (web roadsKeepOff).
static func _roads_keep_off(world: RefCounted, village: Dictionary, x: int, y: int) -> bool:
	if not village.get("district") is Dictionary:
		return true
	world.workshops.append({"id": "_spot", "x": x, "y": y})
	var roads := VillageLayout.roads(world, village)
	var clear: float = VillageLayout.V().DISTRICT.BUILD_CLEAR
	var ok := true
	for w: Dictionary in world.workshops:
		if VillageLayout.ground_near(world, village, roads, w.x, w.y, clear):
			ok = false
			break
	world.workshops.pop_back()
	return ok


static func _crowded(base: Vector2i, huts: Array, x: int, y: int) -> bool:
	if x == base.x and y == base.y - 1:
		return true
	for w: Dictionary in huts:
		if int(w.y) == y and absi(int(w.x) - x) == 1:
			return true
	return false


# --- upgrading and crafting -----------------------------------------------------------------------------

## {gold, products} to go from the hut's level to the next, or {} at the top level (web workshopUpgradeCost).
## Gold: round(UPGRADE_COST_BASE * UPGRADE_COST_GROWTH ^ (level - 1)).
static func upgrade_cost(data: Dictionary, hut: Dictionary) -> Dictionary:
	var rules: Dictionary = data.balance.workshop
	var level := int(hut.get("level", 1))
	if level >= int(rules.MAX_LEVEL):
		return {}
	var parts: Variant = rules.UPGRADE_PRODUCTS.get(str(level + 1), {})
	return {"gold": roundi(float(rules.UPGRADE_COST_BASE) * pow(float(rules.UPGRADE_COST_GROWTH), maxi(0, level - 1))),
		"products": (parts as Dictionary).duplicate() if parts is Dictionary else {}}


## Seconds one craft takes in this hut: craftTime / (level speed * (1 + craft-speed reputation)).
## Each level above 1 adds WORKSHOP_LEVEL_SPEED_PER_LEVEL (web workshopCraftTime).
static func craft_time(data: Dictionary, hut: Dictionary, recipe: Dictionary, reputation_speed: float) -> float:
	if recipe.is_empty() or float(recipe.craftTime) <= 0.0:
		return 0.0
	var speed := 1.0 + maxf(0.0, float(int(hut.level) - 1)) * float(data.balance.crafting.WORKSHOP_LEVEL_SPEED_PER_LEVEL)
	return float(recipe.craftTime) / (speed * (1.0 + reputation_speed))


## What a hut is doing (web workshopStatus): "working" | "noRecipe" | "full" (auto, craft target reached) |
## "blocked" (short of inputs) | "waiting" (could start, nobody told it to). Shortages compare whole units.
static func status(hut: Dictionary, recipe: Dictionary, inventory: Dictionary, auto_unlocked: bool, target: int) -> Dictionary:
	if hut.progress != null and not recipe.is_empty():
		return {"state": "working", "shortages": []}
	if recipe.is_empty():
		return {"state": "noRecipe", "shortages": []}
	var auto: bool = hut.auto == true and auto_unlocked
	if auto and target > 0 and float(inventory.get(recipe.key, 0)) >= target:
		return {"state": "full", "shortages": []}
	var shortages: Array = []
	for id: String in recipe.need:
		var have := floorf(float(inventory.get(id, 0)))
		if have < float(recipe.need[id]):
			shortages.append({"id": id, "need": recipe.need[id], "have": have})
	if not shortages.is_empty():
		return {"state": "blocked", "shortages": shortages}
	return {"state": "working" if auto else "waiting", "shortages": []}


## Research an older save had in use before it was needed (web researchSyncFromState, workshop parts):
## a hut means 제작소 건설 was done; an automatic hut or recipe card means 자동 제작 장치 was.
static func research_in_use(huts: Array, auto_craft: Dictionary) -> Array[String]:
	var done: Array[String] = []
	if not huts.is_empty():
		done.append("workshopBuild")
	var automatic := false
	for key in auto_craft:
		automatic = automatic or auto_craft[key] == true
	for hut: Dictionary in huts:
		automatic = automatic or hut.get("auto") == true
	if automatic:
		done.append("autoCraftDevice")
	return done


static func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


## A whole number Godot can hold as an int without change (JS keeps any integer; beyond 2^53 is not a level).
static func _is_whole(value: Variant) -> bool:
	return _is_number(value) and floorf(float(value)) == float(value) and absf(float(value)) <= TWO_53


static func _base36(value: int) -> String:
	var digits := ""
	while true:
		digits = "0123456789abcdefghijklmnopqrstuvwxyz"[value % 36] + digits
		value /= 36
		if value == 0:
			break
	return digits
