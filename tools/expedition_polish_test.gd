extends SceneTree

const World := preload("res://scripts/world/world_state.gd")
const Temple := preload("res://scripts/expedition/temple.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var w = root.get_node("Game").workshop
	if not w.snapshot().has("expedition_goals"):
		check(false, "journal has no current objectives")
		quit(1)
		return
	check(_goal(w, "tunnel").id == "open_tunnel", "old game has a tunnel objective")
	w.world.unlock_tunnel()
	check(_goal(w, "tunnel").is_empty(), "opened tunnel objective disappears")
	check(_goal(w, "forest").id == "tracks" and _goal(w, "swamp").id == "pump", "both directions are available")
	check(_goal(w, "crystal").is_empty(), "crystal is not advertised before it is accessible")
	for id in ["tracks", "ledger", "leaf", "wave", "leaf", "last"]:
		w.investigate_landmark(id)
	check(_goal(w, "forest").id == "marks", "forest entry follows the last surface clue")
	w.expedition_action("forest", "marks")
	w.expedition_action("forest", "moss")
	_reload(w)
	check(_goal(w, "forest").id == "root", "restored partial puzzle points at the next actuator")
	w.expedition_action("forest", "root")
	w.expedition_action("forest", "moss")
	w.expedition_action("forest", "forest_path")
	check(_goal(w, "forest").is_empty() and _goal(w, "crystal").id == "signal", "record opens the route to the crystal")
	for id in ["signal", "east", "east", "west", "shutter"]:
		w.expedition_action("crystal", id)
	_reload(w)
	check(_goal(w, "crystal").id == "rescue", "restored scientist rescue stage")
	w.expedition_action("crystal", "shutter")
	for id in ["pump", "coil", "incident", "pump", "archive"]:
		w.investigate_landmark(id)
	for id in ["diagram", "ground", "return", "supply", "swamp_path"]:
		w.expedition_action("swamp", id)
	w.expedition_action("village", "drainage")
	_reload(w)
	check(_goal(w, "village").id == "observatory", "restored facility changes village goal")
	for id in ["observatory", "table", "lab", "lab"]:
		w.expedition_action("village", id)
	var model := Temple.new()
	model.circuit = 2
	model.pos = Temple.MIRROR
	model.use()
	w.record_temple(model.checkpoint(), model.endings)
	_reload(w)
	check(_goal(w, "temple").id == "pillar", "only the missing ending is suggested")
	var resumed: RefCounted = Temple.new()
	resumed.restore(w.world.expedition.temple, w.world.expedition)
	check(resumed.pos == Temple.MIRROR and resumed.use().contains("이미"), "recorded ending is not granted again")
	resumed.pos = Temple.PILLAR
	resumed.use()
	w.record_temple(resumed.checkpoint(), resumed.endings)
	_reload(w)
	check(w.snapshot().expedition_goals.is_empty(), "completed game shows no repeated task")
	check(w.snapshot().expedition_stamps.size() == 5, "one stamp per region")
	var reward: Array = w.snapshot().expedition_stamps
	var state: Dictionary = w.world.expedition.duplicate(true)
	w.expedition_action("village", "lab")
	_reload(w)
	check(w.snapshot().expedition_stamps == reward and w.world.expedition == state, "revisiting does not duplicate rewards")
	check(w.state.gold == 0 and w.state.inventory.is_empty(), "non-economic rewards")
	print("EXPEDITION POLISH PASS" if failures == 0 else "EXPEDITION POLISH FAILED")
	quit(int(failures > 0))

func check(ok: bool, context: String) -> void:
	if not ok:
		failures += 1
		printerr("EXPEDITION POLISH FAIL: ", context)

func _goal(w: Node, region: String) -> Dictionary:
	for row: Dictionary in w.snapshot().expedition_goals:
		if row.region == region:
			return row
	return {}

func _reload(w: Node) -> void:
	var text: String = w.export_save()
	var envelope: Dictionary = JSON.parse_string(text)
	check(envelope.version == 1, "save stays v1")
	w._restore(w.Save.parse_game(text))
