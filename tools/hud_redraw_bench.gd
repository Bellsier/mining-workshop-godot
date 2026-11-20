extends SceneTree
## How much the workshop menu redraws while the game runs (QA-06), on any version of the HUD:
##   godot --headless --path . --fixed-fps 60 --script res://tools/hud_redraw_bench.gd
## Two craft huts crafting by themselves, a recipe crafting automatically and steel auto-selling, so gold, stock
## and the huts' progress change every tick. For each tab (제작, 판매, 납품) the menu is left open for 100 game ticks
## (10 s of game time) and the run counts:
##   - nodes put into the list (every row and control that enters the tree; a redraw that keeps the rows adds none),
##   - the time each frame took (headless, so the menu's own work, not drawing),
## and prints one JSON line per tab, then "HUD REDRAW BENCH DONE". With `--check` (after the script's arguments,
## `-- --check`), exits 1 when a tab adds more than CHECK_MAX_ADDED nodes over the 100 ticks.

const World = preload("res://scripts/world/world_state.gd")
const TICKS := 100
const CHECK_MAX_ADDED := 300

var game: Node
var eco: Node
var hud: Node
var _added := 0


func _initialize() -> void:
	call_deferred("_run")


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _on_node_added(node: Node) -> void:
	if is_instance_valid(hud) and hud._rows != null and hud._rows.is_ancestor_of(node):
		_added += 1


func _run() -> void:
	root.size = Vector2i(960, 540)
	game = root.get_node("Game")
	eco = game.workshop
	hud = game._hud
	eco._restore({"world": World.new_game(42).to_dict(), "gold": 100000.0,
		"completed_research": {"workshopBuild": true, "autoCraftDevice": true, "deliveryContract": true},
		"inventory": {"iron": 100000.0, "coal": 100000.0, "steel": 50.0, "coalBrick": 50.0}})
	eco._ensure_village()
	eco.build_hut()
	eco.build_hut()
	for w: Dictionary in eco.world.workshops:
		eco.set_hut_recipe(str(w.id), "steel")
		eco.set_hut_auto(str(w.id), true)
	eco.set_auto_craft("coalBrick", true)
	eco.state.automation.sell_owned["steel"] = true
	eco.set_auto_sell("steel", true)
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	node_added.connect(_on_node_added)
	var over_budget := false
	for tab in ["craft", "sell", "delivery"]:
		hud.open_tab(tab)
		await _frames(10)
		_added = 0
		var stats_before: Dictionary = hud.get("redraw_stats").duplicate() if hud.get("redraw_stats") != null else {}
		var times: Array[float] = []
		var frames := int(TICKS * eco.TICK * 60.0)
		var last := Time.get_ticks_usec()
		for i in frames:
			await process_frame
			var now := Time.get_ticks_usec()
			times.append((now - last) / 1000.0)
			last = now
		times.sort()
		var mean := 0.0
		for t in times:
			mean += t
		mean /= times.size()
		var line := {"tab": tab, "ticks": TICKS, "frames": frames, "nodes_added": _added,
			"frame_ms_mean": snappedf(mean, 0.01), "frame_ms_p95": snappedf(times[int(times.size() * 0.95)], 0.01),
			"frame_ms_max": snappedf(times[-1], 0.01)}
		if not stats_before.is_empty():
			for k: String in hud.redraw_stats:
				line["redraws_" + k] = int(hud.redraw_stats[k]) - int(stats_before[k])
		print(JSON.stringify(line))
		if _added > CHECK_MAX_ADDED:
			over_budget = true
		hud.close_workshop()
		await _frames(3)
	print("HUD REDRAW BENCH DONE")
	quit(1 if over_budget and "--check" in OS.get_cmdline_user_args() else 0)
