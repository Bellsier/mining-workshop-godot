extends SceneTree
## godot --headless --path <project> --script res://tools/save_migration_test.gd

const Save := preload("res://scripts/workshop_save.gd")

var _failures := 0


func _initialize() -> void:
	_test_legacy_import()
	_test_native_save()
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		_test_legacy_fixture(args[0])
	if _failures == 0:
		print("Save migration tests passed")
	quit(int(_failures > 0))


func _test_legacy_import() -> void:
	var payload := {
		"saveVersion": 1,
		"savedAt": 1792000000000,
		"permanent": {"tickets": 4},
		"run": {
			"gold": 153399,
			"resources": {"iron": 14, "coal": 1.5, "invalid": -1},
			"products": {"steel": 40, "invalid": false},
			"research": {"tunnelWork": true, "tradeExpansion": false},
			"world": {"tunnelUnlocked": true},
			"unmapped_progress": {"level": 7},
		},
	}
	var state := Save.import_legacy(JSON.stringify(payload))
	var inventory: Dictionary = state.get("inventory", {})
	_check(state.get("gold", 0) == 153399, "legacy gold is retained")
	_check(inventory == {"iron": 14.0, "coal": 1.5, "steel": 40.0}, "legacy inventory is combined without invalid amounts")
	_check(state.get("completed_research", {}) == {"tunnelWork": true}, "completed research retains stable keys")
	var legacy: Dictionary = state.get("legacy_web_save", {})
	var legacy_run: Dictionary = legacy.get("run", {})
	_check(legacy_run.has("unmapped_progress"), "unmapped progress is retained")
	var snapshot := {"format": 1, "payload": payload}
	var from_row := Save.import_legacy(JSON.stringify({"snapshot": snapshot}))
	from_row.erase("legacy_web_save_source")
	var from_payload := state.duplicate()
	from_payload.erase("legacy_web_save_source")
	_check(from_row == from_payload, "S2 row import")
	_check(Save.import_legacy('{"saveVersion": 2, "run": {}}').is_empty(), "future legacy version is rejected")
	_check(Save.import_legacy('{"saveVersion": "1", "run": {}}').is_empty(), "invalid legacy version is rejected")
	_check(Save.import_legacy("broken json").is_empty(), "invalid JSON is rejected")


func _test_legacy_fixture(path: String) -> void:
	var imported := Save.import_legacy(FileAccess.get_file_as_string(path))
	_check(imported.get("gold", 0) == 153399, "midgame fixture gold is retained")
	_check(imported.get("inventory", {}).get("steel", 0) == 40, "midgame fixture products are retained")
	var legacy: Dictionary = imported.get("legacy_web_save", {})
	_check(legacy.get("run", {}).get("characters", []).size() == 5, "midgame fixture workers are retained in the original payload")


func _test_native_save() -> void:
	var state := {"inventory": {"iron": 14}, "position": {"x": 13.25, "y": 20}, "unmapped": [true, null]}
	var text := Save.export_game(state)
	var parsed := Save.parse_game(text)
	_check(parsed.get("position", {}).get("x", 0) == 13.25, "native game export preserves fractional values")
	_check(parsed.get("unmapped", []) == [true, null], "native game export preserves unknown fields")
	_check(Save.export_game({"bad": Vector2.ZERO}).is_empty(), "unsupported values are rejected")
	var dir := DirAccess.create_temp("workshop-save-test")
	if dir == null:
		_check(false, "temporary test directory can be opened")
		return
	var path := dir.get_current_dir().path_join("save.json")
	_check(Save._load_game(path).is_empty(), "missing native save returns no state")
	_check(Save._write_game(text, path) == OK and Save._load_game(path) == parsed, "native save is written and reloaded")
	var update := Save.export_game({"gold": 25})
	_check(Save._write_game(update, path) == OK and Save._load_game(path).get("gold", 0) == 25, "native save can be safely replaced")
	_check(DirAccess.remove_absolute(path) == OK, "interrupted replacement can be simulated")
	_check(Save._load_game(Save._existing_path(path)) == parsed, "previous save remains recoverable if replacement was interrupted")
	var future := '{"version":2,"state":{"gold":200}}'
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_check(false, "future-version fixture can be written")
		return
	file.store_string(future)
	file.close()
	_check(Save._load_game(Save._existing_path(path)).is_empty(), "future native save is rejected even if an older backup exists")
	_check(Save._write_game(text, path) != OK and FileAccess.get_file_as_string(path) == future, "future native save is kept untouched")


func _check(condition: bool, description: String) -> void:
	if not condition:
		_failures += 1
		push_error(description)
