extends SceneTree
## Desktop save protection and recovery, in a throwaway user folder:
##   MINING_QA_ISOLATED=1 XDG_DATA_HOME=<empty temp dir> godot --headless --path . --script res://tools/save_recovery_test.gd
## Checks that an unreadable or newer-version save is never overwritten without an export first, that
## setting it aside keeps the original bytes, that failed writes back off and leave the last good save,
## that walking alone does not rewrite the file every autosave tick, and that what the game produces by
## itself (workers, huts) is saved by the regular autosave without showing "pending" after every tick.
## Prints "SAVE RECOVERY PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("SAVE RECOVERY FAIL ", what)

func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()

func _game() -> Node:
	var g: Node = Workshop.new()
	root.add_child(g)
	g.set_process(false)
	return g

func _user_files() -> PackedStringArray:
	return DirAccess.get_files_at("user://")

func _run() -> void:
	var isolated := OS.get_environment("XDG_DATA_HOME")
	if OS.get_environment("MINING_QA_ISOLATED") != "1" or isolated.is_empty() or not OS.get_user_data_dir().begins_with(isolated + "/"):
		printerr("Requires a dedicated XDG_DATA_HOME and MINING_QA_ISOLATED=1; no files touched")
		quit(1)
		return
	if not _user_files().is_empty():
		printerr("Refusing to run in a user folder that already has files")
		quit(1)
		return
	_protected_future_save()
	_clear_user_folder()
	_protected_corrupt_save_import()
	_clear_user_folder()
	_failed_write_backs_off()
	_clear_user_folder()
	_position_only_is_not_rewritten()
	_clear_user_folder()
	_background_production_keeps_saved_label()
	_clear_user_folder()
	if _failures.is_empty():
		print("SAVE RECOVERY PASS")
		quit(0)
	else:
		print("SAVE RECOVERY FAIL %d" % _failures.size())
		quit(1)

func _clear_user_folder() -> void:
	# Only the files this test created in the isolated folder.
	for name in _user_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + name))

func _protected_future_save() -> void:
	var future := '{"version":99,"state":{"gold":5,"inventory":{},"from":"a newer game"}}'
	_write(Save.SAVE_PATH, future)
	var g := _game()
	_check(g.save_status == "protected" and g.save_detail == "future", "a newer-version save is protected: %s/%s" % [g.save_status, g.save_detail])
	_check(g.input_frozen(), "the protected-save choice holds world input")
	var valid := Save.export_game({"gold": 42.0, "inventory": {"iron": 3.0}})
	_check(not g.import_save(valid), "import is refused before the original is exported")
	_check(not g.set_aside_protected({}), "setting aside is refused before the original is exported")
	g.flush(true)
	_check(FileAccess.get_file_as_string(Save.SAVE_PATH) == future, "nothing touched the protected file")
	var notice: Dictionary = g.save_notice()
	var set_aside_enabled := false
	for action: Dictionary in notice.actions:
		if action.id == "set_aside":
			set_aside_enabled = action.enabled
	_check(not set_aside_enabled, "the set-aside button stays disabled before export")
	_check(g.save_action("export_raw") == future, "the original is exported byte for byte")
	_check(g.set_aside_protected({}), "after export the original can be set aside")
	var kept := ""
	for name in _user_files():
		if name.contains(".protected-"):
			kept = name
	_check(not kept.is_empty() and FileAccess.get_file_as_string("user://" + kept) == future, "the original bytes are kept in %s" % kept)
	_check(Save.parse_game(FileAccess.get_file_as_string(Save.SAVE_PATH)).has("inventory"), "a new readable save replaced it")
	_check(g.save_status == "saved" and not g.input_frozen(), "saving goes on after the choice: %s" % g.save_status)
	g.free()
	var written: Dictionary = Save.load_game()
	var again := _game()
	# A loaded save may be normalized and written again ("pending"); it must not be protected or frozen.
	_check(again.save_status in ["saved", "pending"] and not again.is_protected() and not again.input_frozen(),
		"the new save loads normally: %s" % again.save_status)
	_check(float(again.state.gold) == float(written.get("gold", -1)), "the new save's values are restored")
	again.free()

func _protected_corrupt_save_import() -> void:
	var broken := '{"version":1,"state":{"gold":'
	_write(Save.SAVE_PATH, broken)
	_write(Save.SAVE_PATH + ".previous", broken)
	var g := _game()
	_check(g.save_status == "protected" and g.save_detail == "corrupt", "a corrupt save is protected: %s/%s" % [g.save_status, g.save_detail])
	var valid := Save.export_game({"gold": 77.0, "inventory": {"coal": 2.0}})
	_check(not g.import_save(valid), "a corrupt save is not replaced by an import before export")
	_check(g.export_protected() == broken, "the corrupt original is exported as stored")
	_check(g.import_save(valid), "after export an import replaces it and keeps the original")
	var kept := 0
	for name in _user_files():
		if name.contains(".protected-"):
			kept += 1
			_check(FileAccess.get_file_as_string("user://" + name) == broken, "kept copy %s is the original" % name)
	_check(kept == 2, "both the save and its recovery copy were kept (%d)" % kept)
	_check(float(Save.load_game().get("gold", 0)) == 77.0, "the imported save is on disk")
	g.free()

func _failed_write_backs_off() -> void:
	var g := _game()
	g.state.gold = 10.0
	g._mark_dirty()
	g.flush(true)
	_check(g.save_status == "saved", "a first save is written: %s" % g.save_status)
	var good := FileAccess.get_file_as_string(Save.SAVE_PATH)
	# Make the next write fail: the save's place is taken by a folder the game cannot replace.
	DirAccess.rename_absolute(ProjectSettings.globalize_path(Save.SAVE_PATH), ProjectSettings.globalize_path(Save.SAVE_PATH + ".held"))
	DirAccess.make_dir_absolute(ProjectSettings.globalize_path(Save.SAVE_PATH))
	g.state.gold = 20.0
	g._mark_dirty()
	g.flush()
	_check(g.save_status == "failed", "a failed write is reported: %s" % g.save_status)
	var retry_at: float = g._retry_at
	_check(retry_at > Time.get_ticks_msec() / 1000.0, "the next try waits (back-off)")
	g.flush()
	_check(g._retry_at == retry_at, "the ordinary autosave tick does not hammer a failing disk")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Save.SAVE_PATH))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(Save.SAVE_PATH + ".held"), ProjectSettings.globalize_path(Save.SAVE_PATH))
	_check(FileAccess.get_file_as_string(Save.SAVE_PATH) == good, "the last good save survived the failure")
	g.save_action("retry_save")
	_check(g.save_status == "saved" and float(Save.load_game().get("gold", 0)) == 20.0, "'save now' writes once the disk is back: %s" % g.save_status)
	g.free()

func _position_only_is_not_rewritten() -> void:
	var g := _game()
	g.state.gold = 1.0
	g._mark_dirty()
	g.flush(true)
	var first := FileAccess.get_file_as_string(Save.SAVE_PATH)
	g.state.position = {"scene": "res://scenes/world/world_map.tscn", "x": 300.0, "y": 0.0}
	g._mark_dirty(true)
	g.flush()
	_check(FileAccess.get_file_as_string(Save.SAVE_PATH) == first, "walking alone is not saved on every tick")
	_check(g.save_status == "pending", "the walk is still marked as unsaved: %s" % g.save_status)
	g.flush(true)
	_check(float(Save.load_game().get("position", {}).get("x", 0)) == 300.0, "a forced save (hide/close) writes the position")
	g.state.gold = 2.0
	g._mark_dirty()
	g.flush()
	_check(float(Save.load_game().get("gold", 0)) == 2.0, "gameplay changes are saved on the next tick")
	g.free()

## Workers mine every 0.1 s tick. That is written by the 2 s autosave, but it must not hold the label at
## "pending" forever (the web E2E waited for "saved" that never came while a commit outlasted a tick).
## A player action still shows "pending" until it is saved.
func _background_production_keeps_saved_label() -> void:
	var g := _game()
	g.state.unlocked_sites.abandonedMine = true
	g.state.characters.append({"id": "w1", "rarity": "common", "resource": "iron", "mining": 1, "carry": 2, "move": 1})
	g._mark_dirty()
	g.flush(true)
	_check(g.save_status == "saved", "a first save is written: %s" % g.save_status)
	var iron := float(g.state.inventory.get("iron", 0))
	for i in 5:
		g._process(0.1)
	_check(float(g.state.inventory.get("iron", 0)) > iron, "the worker mined during the ticks")
	_check(g.save_status == "saved", "background production keeps the label at saved: %s" % g.save_status)
	_check(g._dirty and g._dirty_gameplay, "background production is still waiting for the next autosave")
	g._save_elapsed = Workshop.AUTOSAVE_INTERVAL
	g._process(0.0)
	_check(float(Save.load_game().get("inventory", {}).get("iron", 0)) == float(g.state.inventory.iron),
		"the regular autosave wrote the mined iron")
	g.mine("iron")
	_check(g.save_status == "pending", "a player action shows pending: %s" % g.save_status)
	g.flush()
	_check(g.save_status == "saved", "and saved once written: %s" % g.save_status)
	g.free()
