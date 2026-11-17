extends RefCounted
## Stores the active Godot game and converts browser save JSON without changing it.

const SAVE_PATH := "user://workshop_save.json"
const SAVE_VERSION := 1
const WEB_SAVE_VERSION := 1

static var _save_lock := Mutex.new()


static func load_game() -> Dictionary:
	return _load_game(_existing_path(SAVE_PATH))


## State must contain JSON-compatible values. Empty dictionaries are reserved for failed loads.
static func save_game(state: Dictionary) -> Error:
	var text := export_game(state)
	if text.is_empty():
		return ERR_INVALID_DATA
	_save_lock.lock()
	var result := _write_game(text, SAVE_PATH)
	_save_lock.unlock()
	return result


static func export_game(state: Dictionary) -> String:
	if state.is_empty() or not _is_json_value(state):
		return ""
	return JSON.stringify({"version": SAVE_VERSION, "state": state}, "", true, true)


static func parse_game(text: String) -> Dictionary:
	var envelope := _parse_object(text)
	if not _is_version(envelope.get("version"), SAVE_VERSION):
		return {}
	var state: Variant = envelope.get("state")
	return state if state is Dictionary else {}


## Accepts the public web build's v1 payload and an S2 snapshot or snapshot row.
## Only active economy fields are projected. The original payload remains available for future ports.
static func import_legacy(text: String) -> Dictionary:
	var payload: Variant = _parse_object(text)
	if payload.has("snapshot") and not payload.has("saveVersion"):
		payload = payload["snapshot"]
	if payload is Dictionary and payload.has("payload") and not payload.has("saveVersion"):
		if not _is_version(payload.get("format"), 1):
			return {}
		payload = payload["payload"]
	if not payload is Dictionary or not _is_version(payload.get("saveVersion"), WEB_SAVE_VERSION):
		return {}
	var run: Variant = payload.get("run")
	if not run is Dictionary:
		return {}
	var gold: Variant = run.get("gold")
	var resources: Variant = run.get("resources")
	var products: Variant = run.get("products")
	if not _is_quantity(gold) or not resources is Dictionary or not products is Dictionary:
		return {}
	var inventory := _quantity_map(resources)
	inventory.merge(_quantity_map(products))
	var completed_research := {}
	var research: Variant = run.get("research")
	if research is Dictionary:
		for key: String in research:
			if research[key] is bool and research[key]:
				completed_research[key] = true
	return {
		"gold": gold,
		"inventory": inventory,
		"completed_research": completed_research,
		"legacy_web_save": payload,
	}


static func _parse_object(text: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {}
	var parsed: Variant = parser.data
	return parsed if parsed is Dictionary else {}


static func _load_game(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return parse_game(FileAccess.get_file_as_string(path))


static func _existing_path(path: String) -> String:
	return path if FileAccess.file_exists(path) else path + ".previous"


static func _write_game(text: String, path: String) -> Error:
	# Corrupt or newer saves require explicit recovery. Autosave must keep the file intact.
	var existing_path := _existing_path(path)
	if FileAccess.file_exists(existing_path) and _load_game(existing_path).is_empty():
		return ERR_FILE_UNRECOGNIZED
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var temporary_path := "%s.%s.tmp" % [path, token]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var written := file.store_string(text)
	file.flush()
	var result := file.get_error()
	file.close()
	var absolute_temporary_path := ProjectSettings.globalize_path(temporary_path)
	if not written or result != OK:
		DirAccess.remove_absolute(absolute_temporary_path)
		return result if result != OK else ERR_FILE_CANT_WRITE
	if FileAccess.get_file_as_string(temporary_path) != text:
		DirAccess.remove_absolute(absolute_temporary_path)
		return ERR_FILE_CANT_WRITE
	var absolute_path := ProjectSettings.globalize_path(path)
	# Windows can remove the destination before renaming, so keep a recovery copy.
	if existing_path == path:
		result = DirAccess.copy_absolute(absolute_path, absolute_path + ".previous")
	if result == OK:
		result = DirAccess.rename_absolute(absolute_temporary_path, absolute_path)
	if result != OK:
		DirAccess.remove_absolute(absolute_temporary_path)
	return result


static func _is_json_value(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return true
		TYPE_FLOAT:
			return is_finite(value)
		TYPE_ARRAY:
			for item: Variant in value:
				if not _is_json_value(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not key is String or not _is_json_value(value[key]):
					return false
			return true
	return false


static func _is_quantity(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(value) and value >= 0


static func _is_version(value: Variant, expected: int) -> bool:
	return (value is int or value is float) and value == expected


static func _quantity_map(values: Dictionary) -> Dictionary:
	var quantities := {}
	for key: String in values:
		if _is_quantity(values[key]):
			quantities[key] = values[key]
	return quantities
