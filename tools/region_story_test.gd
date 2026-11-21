extends SceneTree

const World := preload("res://scripts/world/world_state.gd")
const MAP := "res://scenes/world/world_map.tscn"
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, detail: String) -> void:
	if not ok:
		failures += 1
		printerr("REGION STORY FAIL: ", detail)

func _run() -> void:
	var game = root.get_node("Game")
	var workshop = game.workshop
	workshop.persistence_enabled = false
	var legacy: Dictionary = World.new_game(42).to_dict()
	legacy.erase("regionStory")
	workshop._restore({"world": legacy, "gold": 721})
	if not workshop.has_method("investigate_landmark"):
		check(false, "world investigations unavailable")
		quit(1)
		return
	check(workshop.world.story.is_empty(), "older save starts with an empty journal")
	check(workshop.investigate_landmark("tracks") == "" and workshop.world.story.is_empty(), "closed tunnel")
	var broken := legacy.duplicate(true)
	broken.regionStory = {"last": true, "archive": true, "sequence": "bad", "coil": [], "noise": true}
	check(World.from_dict(broken).story.is_empty(), "malformed progress can be replayed")
	for forest_first in [false, true]:
		workshop._restore({"world": legacy, "gold": 721})
		workshop.world.unlock_tunnel()
		if forest_first:
			_forest(workshop)
			check(not _linked(workshop), "forest alone")
			_marsh(workshop)
		else:
			_marsh(workshop)
			check(not _linked(workshop), "marsh alone")
			_forest(workshop)
		check(_linked(workshop), "both trails unlock the comparison")
		var finished: Dictionary = workshop.world.story.duplicate()
		var journal: Array = workshop.snapshot().story_journal
		for id in ["last", "pump", "archive", "leaf", "coil", "tracks"]:
			workshop.investigate_landmark(id)
		check(finished == workshop.world.story and journal == workshop.snapshot().story_journal, "revisits are idempotent")
		check(workshop.state.gold == 721 and workshop.state.inventory.is_empty(), "no economy rewards or costs")
		workshop._restore(workshop.Save.parse_game(workshop.export_save()))
		check(finished == workshop.world.story and journal == workshop.snapshot().story_journal, "export and load restore all records")
	change_scene_to_file(MAP)
	while current_scene == null:
		await process_frame
	var map = current_scene.get_node("World")
	await physics_frame
	await physics_frame
	_check_reachable(map, current_scene.get_node("Player"))
	game._hud.open_inventory()
	await process_frame
	var titles := []
	for label: Label in game._hud._rows.find_children("*", "Label", true, false):
		titles.append(label.text)
	for entry: Dictionary in workshop.snapshot().story_journal:
		check(titles.has(entry.title) and titles.has(entry.text), "readable notebook entry " + entry.id)
	print("REGION STORY PASS" if failures == 0 else "REGION STORY FAILED")
	quit(0 if failures == 0 else 1)

func _linked(w: Node) -> bool:
	for entry in w.snapshot().story_journal:
		if entry.id == "comparison":
			return true
	return false

func _forest(w: Node) -> void:
	w.investigate_landmark("last")
	w.investigate_landmark("leaf")
	check(not w.world.story.has("last") and not w.world.story.has("sequence"), "locked forest devices")
	w.investigate_landmark("ledger")
	w.investigate_landmark("tracks")
	w.investigate_landmark("leaf")
	check(w.world.story.get("sequence") == 1, "first tone")
	w.investigate_landmark("leaf")
	check(not w.world.story.has("sequence"), "wrong tone resets with retry")
	w.investigate_landmark("leaf")
	w._restore(w.Save.parse_game(w.export_save()))
	check(w.world.story.get("sequence") == 1, "partial sequence survives load")
	w.investigate_landmark("wave")
	w.investigate_landmark("leaf")
	w.investigate_landmark("last")
	check(w.world.story.get("last") == true, "final forest trace")

func _marsh(w: Node) -> void:
	w.investigate_landmark("archive")
	w.investigate_landmark("pump")
	w.investigate_landmark("pump")
	check(not w.world.story.has("repaired") and not w.world.story.has("archive"), "repair needs both clues")
	w.investigate_landmark("coil")
	w._restore(w.Save.parse_game(w.export_save()))
	w.investigate_landmark("incident")
	w.investigate_landmark("pump")
	w.investigate_landmark("archive")
	check(w.world.story.get("archive") == true, "repair restores access to the register")

## Flood the actual collision shapes with the player's body from the tunnel exit. A marker only
## counts if the regular context selector picks it from a reachable standing position.
func _check_reachable(map: Node, player: CharacterBody2D) -> void:
	var sites: Dictionary = World.Story.SITES
	var found := {}
	var start := Vector2i(-416, 64)
	var queue: Array[Vector2i] = [start]
	var visited := {start: true}
	var head := 0
	while head < queue.size() and found.size() < sites.size():
		var point := queue[head]
		head += 1
		var target: Dictionary = map.find_target(Vector2(point) / 64.0, "down")
		if target.get("type") == "story":
			found[target.id] = true
		for delta: Vector2i in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var next := point + 8 * delta
			if visited.has(next) or not Rect2i(-640, -384, 256, 850).has_point(next):
				continue
			if not player.test_move(Transform2D(0, Vector2(point)), Vector2(8 * delta)):
				visited[next] = true
				queue.append(next)
	for id: String in sites:
		check(found.has(id), "reachable through the open tunnel: " + id)
