extends RefCounted
## Stores the active Godot game and converts browser save JSON without changing it.

const ExactJson := preload("res://scripts/exact_json.gd")

const SAVE_PATH := "user://workshop_save.json"
const SAVE_VERSION := 1
const WEB_SAVE_VERSION := 1
## The imported web save, byte for byte (base64), its SHA-256 and how it arrived ("file" or "paste").
const LEGACY_BYTES := "legacy_web_save_bytes"
const LEGACY_SHA256 := "legacy_web_save_sha256"
const LEGACY_ORIGIN := "legacy_web_save_origin"
## Earlier builds of this branch kept the imported text here; it is read and converted to the fields above.
const LEGACY_TEXT := "legacy_web_save_source"
const EMPTY_SHA256 := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

static var _save_lock := Mutex.new()
static var _original_key := ""
static var _original_result := {}
static var _base64: RegEx


static func has_file() -> bool:
	return FileAccess.file_exists(_existing_path(SAVE_PATH))


static func load_game() -> Dictionary:
	return _load_game(_existing_path(SAVE_PATH))


## The save file's text exactly as stored (the one load_game reads), for exporting a protected save.
static func read_raw() -> String:
	var path := _existing_path(SAVE_PATH)
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""


## Moves an unreadable (corrupt or newer-version) save and its recovery copy out of the way by renaming,
## so a new save can be written without destroying them. Returns the kept paths; [] = nothing changed.
static func set_aside_protected() -> Array[String]:
	var kept: Array[String] = []
	var stamp := "%d-%s" % [int(Time.get_unix_time_from_system()), Crypto.new().generate_random_bytes(3).hex_encode()]
	_save_lock.lock()
	for path: String in [SAVE_PATH, SAVE_PATH + ".previous"]:
		if not FileAccess.file_exists(path):
			continue
		var target := "%s.protected-%s%s.json" % [SAVE_PATH.get_basename(), stamp, "" if path == SAVE_PATH else "-previous"]
		var result := DirAccess.rename_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(target))
		if result != OK:
			# Put back what was already moved; the protected files stay exactly where they were.
			for index in range(kept.size() - 1, -1, -1):
				var original := SAVE_PATH if index == 0 and not kept[index].ends_with("-previous.json") else SAVE_PATH + ".previous"
				DirAccess.rename_absolute(ProjectSettings.globalize_path(kept[index]), ProjectSettings.globalize_path(original))
			_save_lock.unlock()
			return [] as Array[String]
		kept.append(target)
	_save_lock.unlock()
	return kept


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
	var stored := state
	# The parsed copy of an imported web save is rebuilt from its original bytes on every read. It is
	# written out only when it cannot be rebuilt exactly: the original is damaged, or the two disagree.
	var original := legacy_original(state)
	if original.status == "ok" and state.get("legacy_web_save") == original.payload:
		stored = state.duplicate()
		stored.erase("legacy_web_save")
	return ExactJson.stringify({"version": SAVE_VERSION, "state": stored})


static func parse_game(text: String) -> Dictionary:
	var envelope := _parse_object(text)
	if not _is_version(envelope.get("version"), SAVE_VERSION):
		return {}
	var state: Variant = envelope.get("state")
	if not state is Dictionary:
		return {}
	if state.get(LEGACY_TEXT) is String and not state.has(LEGACY_BYTES):
		# Lossless: the stored text becomes its UTF-8 bytes. Nothing else changes.
		var bytes: PackedByteArray = state[LEGACY_TEXT].to_utf8_buffer()
		state[LEGACY_BYTES] = Marshalls.raw_to_base64(bytes)
		state[LEGACY_SHA256] = sha256_hex(bytes)
		state[LEGACY_ORIGIN] = "paste"
		state.erase(LEGACY_TEXT)
	var original := legacy_original(state)
	# A copy stored in the file is kept as it is: it was written because the original could not be trusted.
	if original.status == "ok" and not state.has("legacy_web_save"):
		state["legacy_web_save"] = original.payload.duplicate(true)
	return state


## The imported web save's original and whether it can be used:
## {"status": "none" | "ok" | "corrupt", "bytes": PackedByteArray, "payload": Dictionary, "origin": String,
##  "reason": String}. "corrupt" = not base64, SHA-256 mismatch, not UTF-8, or not a web save.
static func legacy_original(state: Dictionary) -> Dictionary:
	var encoded: Variant = state.get(LEGACY_BYTES)
	if not encoded is String:
		return {"status": "none", "bytes": PackedByteArray(), "payload": {}, "origin": "", "reason": ""}
	var key := "%s|%s|%s" % [str(state.get(LEGACY_SHA256)), str(state.get(LEGACY_ORIGIN)), encoded]
	if key == _original_key:
		return _original_result
	var result := {"status": "corrupt", "bytes": PackedByteArray(), "payload": {}, "origin": str(state.get(LEGACY_ORIGIN, "")), "reason": ""}
	if _base64 == null:
		_base64 = RegEx.create_from_string("^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
	# Checked first: Godot prints engine errors for text that is not base64.
	var text_encoded: String = encoded
	var well_formed: bool = not text_encoded.is_empty() and _base64.search(text_encoded) != null
	var bytes: PackedByteArray = Marshalls.base64_to_raw(text_encoded) if well_formed else PackedByteArray()
	if not well_formed or Marshalls.raw_to_base64(bytes) != text_encoded:
		result.reason = "base64"
	elif state.get(LEGACY_SHA256) != sha256_hex(bytes):
		result.reason = "sha256"
	else:
		result.bytes = bytes
		var text := utf8_text(bytes)
		var payload := legacy_payload(text) if not text.is_empty() else {}
		if payload.is_empty():
			result.reason = "content"
		else:
			result.status = "ok"
			result.payload = payload
	_original_key = key
	_original_result = result
	return result


## "none", "ok", "corrupt" (original unusable; the stored copy, if any, is the one in use),
## "conflict" (original and stored copy differ; the stored copy is in use), or "copy_only" (a save
## imported before originals were kept).
static func legacy_status(state: Dictionary) -> String:
	var original := legacy_original(state)
	if original.status == "none":
		return "copy_only" if state.get("legacy_web_save") is Dictionary else "none"
	if original.status == "corrupt":
		return "corrupt"
	if state.has("legacy_web_save") and state.legacy_web_save != original.payload:
		return "conflict"
	return "ok"


static func sha256_hex(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return EMPTY_SHA256
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


## The text of UTF-8 bytes (a leading byte order mark allowed), or "" if they are not exactly UTF-8 text.
static func utf8_text(bytes: PackedByteArray) -> String:
	if bytes.is_empty():
		return ""
	var text := bytes.get_string_from_utf8()
	var encoded := text.to_utf8_buffer()
	if encoded == bytes:
		return text
	if bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF and encoded == bytes.slice(3):
		return text
	return ""


## The game payload of a web save text (v1 payload, S2 snapshot or snapshot row); {} if it is not one.
static func legacy_payload(text: String) -> Dictionary:
	var payload: Variant = _parse_object(text)
	if payload.has("snapshot") and not payload.has("saveVersion"):
		payload = payload["snapshot"]
	if payload is Dictionary and payload.has("payload") and not payload.has("saveVersion"):
		if not _is_version(payload.get("format"), 1):
			return {}
		payload = payload["payload"]
	if not payload is Dictionary or not _is_version(payload.get("saveVersion"), WEB_SAVE_VERSION):
		return {}
	return payload


## Accepts the public web build's v1 payload and an S2 snapshot or snapshot row.
## Only active economy fields are projected. The original remains available for future ports: its bytes
## (S2 envelope included) are kept exactly with their SHA-256, and legacy_web_save is parsed from them.
## `bytes` are the file's bytes for a file import; pasted text is kept as its UTF-8 bytes, which may
## already differ from the file it was copied from (line endings, for one).
static func import_legacy(text: String, bytes := PackedByteArray(), origin := "paste") -> Dictionary:
	if bytes.is_empty():
		bytes = text.to_utf8_buffer()
	var payload := legacy_payload(text)
	if payload.is_empty():
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
		LEGACY_BYTES: Marshalls.raw_to_base64(bytes),
		LEGACY_SHA256: sha256_hex(bytes),
		LEGACY_ORIGIN: origin,
	}


static func _parse_object(text: String) -> Dictionary:
	var parsed := ExactJson.parse(text)
	if not parsed.ok:
		return {}
	return parsed.value if parsed.value is Dictionary else {}


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
