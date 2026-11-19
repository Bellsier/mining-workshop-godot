extends SceneTree
## Large saves with craft huts: the save handler stays fast and keeps everything, in a throwaway user folder:
##   MINING_QA_ISOLATED=1 XDG_DATA_HOME=<empty temp dir> godot --headless --path . --script res://tools/save_performance_test.gd
## A web save is grown with chunk edits (the 256 world's per-vein records, the largest part of a long game)
## to about 0.45 MB and 1.7 MB, with 8 huts mid-craft. For each size it is imported, autosaved, reloaded and
## exported, and the times are printed.
## 1. Nothing is lost: the huts and their exact progress, and the web save byte for byte.
## 2. Time budgets (generous for CI machines; this machine's times are printed): an autosave of the large
##    save takes at most AUTOSAVE_BUDGET_MS (the game saves every 2 s while playing), a load at most
##    LOAD_BUDGET_MS, an import at most IMPORT_BUDGET_MS, 1000 ticks of 8 huts at most HUT_TICKS_BUDGET_MS.
## 3. Growth: 4x the data costs at most SCALING_LIMIT x the time (a slip to quadratic work fails).
## 4. The fast paths are still safe: a write never replaces a damaged or newer file someone else put there,
##    and the kept web save's check remembered at import equals a fresh one.
## Prints "SAVE PERFORMANCE PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
const CraftHuts = preload("res://scripts/craft_huts.gd")
const ExactJson = preload("res://scripts/exact_json.gd")
const JS_SAVE := "res://tests/fixtures/js_save_v1_full_world.json"

const AUTOSAVE_BUDGET_MS := 400.0
const LOAD_BUDGET_MS := 4000.0
const IMPORT_BUDGET_MS := 8000.0
const HUT_TICKS_BUDGET_MS := 500.0
const SCALING_LIMIT := 10.0

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var isolated := OS.get_environment("XDG_DATA_HOME")
	if OS.get_environment("MINING_QA_ISOLATED") != "1" or isolated.is_empty() or not OS.get_user_data_dir().begins_with(isolated + "/"):
		printerr("Requires a dedicated XDG_DATA_HOME and MINING_QA_ISOLATED=1; no files touched")
		quit(1)
		return
	if not DirAccess.get_files_at("user://").is_empty():
		printerr("Refusing to run in a user folder that already has files")
		quit(1)
		return
	var small := _measure(5000)
	var large := _measure(20000)
	for key in ["autosave", "load"]:
		var ratio: float = large[key] / maxf(small[key], 1.0)
		_check(ratio <= SCALING_LIMIT, "%s grows %.1fx for 4x the data (limit %.0fx)" % [key, ratio, SCALING_LIMIT])
	_check(large.autosave <= AUTOSAVE_BUDGET_MS, "autosave of the %.1f MB save: %.0f ms (budget %.0f)" % [large.mb, large.autosave, AUTOSAVE_BUDGET_MS])
	_check(large.load <= LOAD_BUDGET_MS, "load of the %.1f MB save: %.0f ms (budget %.0f)" % [large.mb, large.load, LOAD_BUDGET_MS])
	_check(large.import <= IMPORT_BUDGET_MS, "import of the %.1f MB web save: %.0f ms (budget %.0f)" % [large.mb, large.import, IMPORT_BUDGET_MS])
	_hut_ticks()
	_fast_path_is_safe()
	if _failures.is_empty():
		print("SAVE PERFORMANCE PASS")
		quit(0)
	else:
		print("SAVE PERFORMANCE FAIL %d" % _failures.size())
		quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("SAVE PERFORMANCE FAIL ", what)


func _ms(since: int) -> float:
	return (Time.get_ticks_usec() - since) / 1000.0


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2])


func _clear_user_folder() -> void:
	for file in DirAccess.get_files_at("user://"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + file))


## The web fixture with `edits` chunk edits and the most huts there can be (8), all mid-craft.
func _large_web_save(edits: int) -> PackedByteArray:
	var payload: Dictionary = ExactJson.parse(FileAccess.get_file_as_string(JS_SAVE)).value
	var chunk_edits := {}
	for i in edits:
		chunk_edits["%d,%d" % [i % 97, i / 97]] = {"mines": {"gen:v2:%d" % i: {"discovered": true, "developmentState": "secured"}}}
	payload.run.world["chunkEdits"] = chunk_edits
	var huts: Array = []
	var recipes := ["steel", "specialAlloy", "precisionPart", "relicPart", "quantumCore", "plasmaCore", "steelGear", "manaEngine"]
	for i in 8:
		huts.append({"id": "workshop_big%d" % i, "x": -6 + i, "y": 5, "level": 1 + i, "recipeKey": recipes[i],
			"auto": i % 2 == 0, "progress": 0.1 * (i + 1) + 1e-13 * i})
	payload.run.world.workshops = huts
	payload.run.research.workshopExpansion = true
	return ExactJson.stringify(payload, false).to_utf8_buffer()


func _measure(edits: int) -> Dictionary:
	_clear_user_folder()
	var bytes := _large_web_save(edits)
	var original: Dictionary = ExactJson.parse(bytes.get_string_from_utf8()).value
	var game: Node = Workshop.new()
	root.add_child(game)
	game.set_process(false)
	var started := Time.get_ticks_usec()
	var imported: bool = game.import_save_bytes(bytes)
	var import_ms := _ms(started)
	_check(imported, "the %d-edit web save imports" % edits)
	# Import remembers the kept original's check instead of parsing the web save again: it must be the answer
	# a fresh check gives.
	var remembered: Dictionary = Save.legacy_original(game.state).duplicate(true)
	Save._original_key = ""
	var fresh := Save.legacy_original(game.state)
	_check(remembered.status == "ok" and remembered == fresh, "the remembered original equals a fresh check (%d edits)" % edits)
	var expected := CraftHuts.sanitize(original.run.world.workshops, game._tables.recipes)
	_check(game.world.workshops == expected, "the 8 huts load with their exact progress (%d edits)" % edits)
	# Autosaves while playing: something changes, the game writes.
	var saves: Array = []
	for i in 5:
		game._tick()
		game.state.gold = float(game.state.gold) + 1.0
		game._mark_dirty()
		started = Time.get_ticks_usec()
		game.flush(true)
		saves.append(_ms(started))
		_check(game.save_status == "saved", "autosave %d of the %d-edit save succeeds (%s)" % [i, edits, game.save_status])
	var huts_now: Array = game.world.workshops.duplicate(true)
	started = Time.get_ticks_usec()
	var exported: String = game.export_save()
	var export_ms := _ms(started)
	var file_size := FileAccess.get_file_as_bytes(Save.SAVE_PATH).size()
	game.free()
	# A new session reads the file.
	var loads: Array = []
	var reloaded: Node
	for i in 3:
		started = Time.get_ticks_usec()
		reloaded = Workshop.new()
		root.add_child(reloaded)
		loads.append(_ms(started))
		reloaded.set_process(false)
		if i < 2:
			reloaded.free()
	_check(reloaded.world.workshops == huts_now, "a reload has the huts as they were saved (%d edits)" % edits)
	_check(reloaded.legacy_original_bytes() == bytes, "the web save is kept byte for byte (%d edits)" % edits)
	_check(reloaded.state.legacy_web_save.run.world.chunkEdits.size() == edits, "every chunk edit of the web save is kept (%d)" % edits)
	_check(float(reloaded.state.gold) == float(ExactJson.parse(exported).value.state.gold), "a reload has the last saved gold")
	reloaded.free()
	var result := {"mb": file_size / 1048576.0, "import": import_ms, "autosave": _median(saves), "load": _median(loads), "export": export_ms}
	print("save performance: %d edits, web %.2f MB, save %.2f MB | import %.0f ms | autosave %.0f ms (median of 5) | load %.0f ms (median of 3) | export %.0f ms"
		% [edits, bytes.size() / 1048576.0, result.mb, import_ms, result.autosave, result.load, export_ms])
	return result


func _hut_ticks() -> void:
	var game: Node = Workshop.new()
	game.persistence_enabled = false
	root.add_child(game)
	game.set_process(false)
	game.state.completed_research.merge({"workshopBuild": true, "autoCraftDevice": true, "workshopExpansion": true}, true)
	game.state.gold = 1e9
	game.state.inventory.merge({"iron": 1e6, "coal": 1e6, "steelGear": 2.0, "manaEngine": 1.0}, true)
	for i in 8:
		game.build_hut()
		var hut: Dictionary = game.world.workshops.back()
		game.set_hut_recipe(hut.id, "steel" if i % 2 == 0 else "ironTool")
		game.set_hut_auto(hut.id, true)
	game.state.inventory.coalBrick = 1e5
	# The first tick lays the village out once (web villageEnsureSites; timed in village_layout_test).
	var started := Time.get_ticks_usec()
	game._tick()
	print("save performance: the first tick (village laid out once) %.0f ms" % _ms(started))
	_check(game.state.village.get("district") is Dictionary, "the first tick laid the village out")
	started = Time.get_ticks_usec()
	for i in 1000:
		game._tick()
	var ms := _ms(started)
	print("save performance: 1000 ticks with 8 automatic huts %.0f ms" % ms)
	_check(game.world.workshops.size() == 8 and float(game.state.inventory.get("ironTool", 0)) > 0.0, "8 automatic huts craft")
	_check(ms <= HUT_TICKS_BUDGET_MS, "1000 ticks with 8 huts: %.0f ms (budget %.0f)" % [ms, HUT_TICKS_BUDGET_MS])
	game.free()


## The autosave skips re-reading a file it wrote itself. Any other file is still read first: a damaged or
## newer save put there by someone else is never replaced, and a valid one is.
func _fast_path_is_safe() -> void:
	_clear_user_folder()
	var game: Node = Workshop.new()
	root.add_child(game)
	game.set_process(false)
	game.state.gold = 123.0
	_check(Save.save_game(game.state) == OK, "a first save is written")
	for damaged: String in ["{\"version\":1,\"state\":", "{\"version\":99,\"state\":{\"gold\":1}}"]:
		var file := FileAccess.open(Save.SAVE_PATH, FileAccess.WRITE)
		file.store_string(damaged)
		file.close()
		game.state.gold = float(game.state.gold) + 1.0
		_check(Save.save_game(game.state) == ERR_FILE_UNRECOGNIZED, "a write refuses to replace %s" % damaged.left(20))
		_check(FileAccess.get_file_as_string(Save.SAVE_PATH) == damaged, "the file someone else wrote is left as it was")
	var other := Save.export_game({"gold": 7.0, "inventory": {}})
	var file := FileAccess.open(Save.SAVE_PATH, FileAccess.WRITE)
	file.store_string(other)
	file.close()
	_check(Save.save_game(game.state) == OK and Save.load_game().gold == game.state.gold, "a valid save written elsewhere is replaced normally")
	game.free()
