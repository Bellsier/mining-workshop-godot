extends SceneTree
## Long play in the world with every effect on (full quality, dusk: sway, clouds, fireflies, rising texts):
##   godot --headless --path . --fixed-fps 60 --script res://tools/world_long_run_bench.gd [-- --check]
## The player walks back and forth past the cabin and a vein while securing and mining it every second, for
## 36,000 frames (10 minutes of game time). Every 6,000 frames it prints the node count, the object count, static
## memory and the rising texts alive; then "WORLD LONG RUN DONE". With --check it exits 1 if nodes or objects
## grew by more than 50 after the first sample, or static memory by more than 8 MiB (headless: no drawing cost,
## this is about what piles up).

const World := preload("res://scripts/world/world_state.gd")
const FRAMES := 36000
const SAMPLE := 6000


func _initialize() -> void:
	call_deferred("_run")


func _sample(frame: int, floats: int) -> Dictionary:
	return {"frame": frame, "nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"static_mib": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.01), "floats": floats}


func _run() -> void:
	var game: Node = root.get_node("Game")
	game.workshop._restore({"world": World.new_game(42).to_dict()})
	change_scene_to_file("res://scenes/world/world_map.tscn")
	for i in 8:
		await process_frame
	var map: Node2D = current_scene.get_node("World")
	var light: Node = map.objects.light
	light.force_darkness = 0.34
	var vein: Dictionary = map.state.mine_by_id("mine_start_iron")
	var player: Node2D = map.player
	var cabin: Vector2 = map.to_px(Vector2(map.state.base))
	var samples: Array = []
	for frame in FRAMES:
		light.quality = 0 # every effect on, whatever the headless frame times say
		var phase := frame % 240
		if phase == 0:
			player.position = map.to_px(Vector2(vein.x, vein.y + 0.8))
			player.set("facing", "up")
		elif phase == 120:
			player.position = cabin + Vector2(0, -34)
		if phase < 120 and phase % 60 == 1:
			var id: String = map.context_at(player.position)
			map.interact(id)
		await process_frame
		if frame % SAMPLE == 0 or frame == FRAMES - 1:
			var line := _sample(frame, map.floats.floats.size())
			samples.append(line)
			print(JSON.stringify(line))
	print("WORLD LONG RUN DONE")
	var first: Dictionary = samples[1] if samples.size() > 1 else samples[0]
	var last: Dictionary = samples[-1]
	var grew: bool = last.nodes - first.nodes > 50 or last.objects - first.objects > 50 or last.static_mib - first.static_mib > 8.0
	quit(1 if grew and "--check" in OS.get_cmdline_user_args() else 0)
