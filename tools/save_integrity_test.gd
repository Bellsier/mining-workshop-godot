extends SceneTree
## Save integrity against the web original, in a throwaway user folder:
##   MINING_QA_ISOLATED=1 XDG_DATA_HOME=<empty temp dir> godot --headless --path . --script res://tools/save_integrity_test.gd
## - JSON numbers: 4,000+ cases produced by Node read to the same IEEE-754 bits as JSON.parse and are
##   written as JSON.stringify writes them; 1e999, NaN and broken JSON are refused.
## - P0-1 A JS/S2 save file (CRLF, Korean, emoji, with and without a byte order mark) keeps its exact bytes:
##   SHA-256 equal after import, autosave, reload, export, re-import and writing the original back out.
## - P0-2 A damaged original never removes the working copy of the JS save: normal, damaged and
##   conflicting cases, each through autosave and reload.
## - P1-4 Very large numbers display like Intl.NumberFormat, and NaN, infinity or out-of-range counts never
##   reach the game state.
## - P1-5 An active stock of 1.1500000000000001 keeps its exact value and its "1.2" display across saves.
## Prints "SAVE INTEGRITY PASS" and exits 0, or lists the failures and exits 1.

const Workshop = preload("res://scripts/workshop.gd")
const Save = preload("res://scripts/workshop_save.gd")
const ExactJson = preload("res://scripts/exact_json.gd")
const Hud = preload("res://scripts/workshop_hud.gd")
const NUMBER_CASES := "res://tests/fixtures/js_number_cases.json"
const CRLF_SAVE := "res://tests/fixtures/js_save_s2_crlf_utf8.json"
const BOM_SAVE := "res://tests/fixtures/js_save_s2_crlf_utf8_bom.json"
## sha256sum of the fixtures as committed.
const CRLF_SHA := "f73efa2928fd97d92382dc59969b004d441071352d0632334c1b1ea0a51a31b9"
const BOM_SHA := "e6da97237c2d3bb92c70c8d3bfe2483e0585a974423d843e5111f3874323bfec"
## 1.1500000000000001 in JavaScript (115/100 is 1.15, one unit in the last place below it).
const IRON_BITS := 0x3FF2666666666667

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
	var version := Engine.get_version_info()
	_check(version.major == 4 and version.minor == 4 and version.patch == 1, "runs on Godot 4.4.1 (got %s)" % version.string)
	_numbers_match_javascript()
	_clear()
	_file_bytes_round_trip(CRLF_SAVE, CRLF_SHA)
	_clear()
	_file_bytes_round_trip(BOM_SAVE, BOM_SHA)
	_clear()
	_paste_keeps_text_bytes()
	_clear()
	_normal_original()
	_clear()
	_damaged_original_keeps_copy()
	_clear()
	_conflicting_original_keeps_both()
	_clear()
	_large_and_abnormal_numbers()
	_clear()
	_exact_active_stock()
	_clear()
	if _failures.is_empty():
		print("SAVE INTEGRITY PASS")
		quit(0)
	else:
		print("SAVE INTEGRITY FAIL %d" % _failures.size())
		quit(1)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("SAVE INTEGRITY FAIL ", what)


func _clear() -> void:
	for name in DirAccess.get_files_at("user://"):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + name))


func _game(persistent := true) -> Node:
	var game: Node = Workshop.new()
	game.persistence_enabled = persistent
	root.add_child(game)
	game.set_process(false)
	return game


func _end(game: Node) -> void:
	root.remove_child(game)
	game.free()


func _write_save(state: Dictionary) -> void:
	var file := FileAccess.open(Save.SAVE_PATH, FileAccess.WRITE)
	file.store_string(ExactJson.stringify({"version": Save.SAVE_VERSION, "state": state}))
	file.close()


func _file_state() -> Dictionary:
	return ExactJson.parse(Save.read_raw()).value.state


# --- numbers ------------------------------------------------------------------------------------------

func _numbers_match_javascript() -> void:
	var corpus: Dictionary = ExactJson.parse(FileAccess.get_file_as_string(NUMBER_CASES)).value
	var wrong_bits := 0
	var wrong_text := 0
	for entry: Array in corpus.cases:
		var parsed := ExactJson.parse(entry[0])
		var bits := ExactJson._bits(parsed.value) if parsed.ok else -1
		if bits != ("0x" + entry[1]).hex_to_int():
			wrong_bits += 1
			if wrong_bits <= 5:
				_check(false, "JSON.parse(%s): bits %016x, JavaScript %s" % [entry[0], bits, entry[1]])
			continue
		var written := ExactJson.number_text(parsed.value)
		if written != entry[2]:
			wrong_text += 1
			if wrong_text <= 5:
				_check(false, "JSON.stringify(%s): %s, JavaScript %s" % [entry[0], written, entry[2]])
	_check(wrong_bits == 0 and wrong_text == 0, "%d number cases: %d read differently, %d written differently" % [corpus.cases.size(), wrong_bits, wrong_text])
	for bad: String in ["1e999", "[-1e999]", "NaN", "[Infinity]", "[1,]", "01", "1.", ".5", "\"a\u0001\"", "{\"a\" 1}", "[1] 2", "", "nul"]:
		_check(not ExactJson.parse(bad).ok, "refuses %s" % bad.c_escape())
	var text := "{\"b\":[1.1500000000000001,-0,true,null],\"a\":\"줄\\r\\n바꿈 ⛏️😀 \\\"q\\\" \\\\ \\u0001\\ud83d\\ude00\"}"
	var value: Variant = ExactJson.parse(text).value
	_check(value is Dictionary and value.a == "줄\r\n바꿈 ⛏️😀 \"q\" \\ " + char(1) + "😀", "strings and escapes read like JSON.parse")
	_check(ExactJson.stringify(value) == "{\"a\":\"줄\\r\\n바꿈 ⛏️😀 \\\"q\\\" \\\\ \\u0001😀\",\"b\":[1.1500000000000001,0,true,null]}",
		"written like JSON.stringify with sorted keys (got %s)" % ExactJson.stringify(value))
	_check(ExactJson.stringify({"a": INF}).is_empty() and ExactJson.stringify([NAN]).is_empty(), "NaN and infinity are never written")


# --- P0-1: exact bytes --------------------------------------------------------------------------------

func _file_bytes_round_trip(path: String, expected_sha: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	_check(Save.sha256_hex(bytes) == expected_sha, "%s is the committed fixture (sha %s)" % [path, Save.sha256_hex(bytes)])
	_check(bytes.find(13) >= 0 and bytes.get_string_from_utf8().contains("😀"), "%s has CRLF and emoji" % path)
	var game := _game()
	_check(game.import_save_bytes(bytes), "%s imports from the file" % path)
	_check(game.state.get(Save.LEGACY_SHA256) == expected_sha and game.state.get(Save.LEGACY_ORIGIN) == "file", "%s: SHA-256 kept on import" % path)
	_check(game.legacy_original_bytes() == bytes, "%s: original bytes equal right after import" % path)
	_check(game.state.legacy_web_save.run.futureField.note == "광산 마을 ⛏️😀 — \"따옴표\" \\ 백슬래시\r\n줄바꿈", "%s: Korean, emoji and CRLF inside text read exactly" % path)
	_check(Save.legacy_status(game.state) == "ok" and game.legacy_original_info().status == "ok", "%s: status ok" % path)
	game.state.gold = float(game.state.gold) + 1.0
	game._mark_dirty()
	game.flush(true)
	_end(game)
	var reloaded := _game()
	_check(Save.sha256_hex(reloaded.legacy_original_bytes()) == expected_sha, "%s: SHA-256 equal after autosave and reload" % path)
	var exported: String = reloaded.export_save()
	_check(reloaded.import_save(exported), "%s: the Godot export imports again" % path)
	_check(Save.sha256_hex(reloaded.legacy_original_bytes()) == expected_sha, "%s: SHA-256 equal after export and re-import" % path)
	# Writing the original back out (what "원본 JS 파일 저장" does on desktop) gives the same file.
	var out_path := "user://original-out.json"
	var hud: CanvasLayer = Hud.new()
	root.add_child(hud)
	hud.setup(reloaded)
	hud._on_original_path_chosen(ProjectSettings.globalize_path(out_path))
	_check(Save.sha256_hex(FileAccess.get_file_as_bytes(out_path)) == expected_sha, "%s: the written-out original has the same SHA-256" % path)
	root.remove_child(hud)
	hud.free()
	_end(reloaded)
	var again := _game()
	_check(Save.sha256_hex(again.legacy_original_bytes()) == expected_sha, "%s: SHA-256 equal after a second reload" % path)
	_end(again)


func _paste_keeps_text_bytes() -> void:
	var bytes := FileAccess.get_file_as_bytes(CRLF_SAVE)
	var text := bytes.get_string_from_utf8()
	var game := _game()
	_check(game.import_save(text) and game.state.get(Save.LEGACY_ORIGIN) == "paste", "pasted text imports and is marked as pasted")
	_check(game.legacy_original_bytes() == text.to_utf8_buffer(), "pasted text is kept as exactly the text received")
	_end(game)
	# What a text field does to pasted text is outside the game's control; recorded, not asserted.
	var field := TextEdit.new()
	field.text = text
	var through_field := field.text.to_utf8_buffer()
	field.free()
	print("NOTE paste through a TextEdit: %s (%d → %d bytes)" % ["unchanged" if through_field == bytes else "changed", bytes.size(), through_field.size()])


# --- P0-2: damaged and conflicting originals ----------------------------------------------------------

## A file-imported save as written by the game, plus the payload it carries.
func _imported_state() -> Array:
	var game := _game(false)
	game.import_save_bytes(FileAccess.get_file_as_bytes(CRLF_SAVE))
	var state: Dictionary = ExactJson.parse(game.export_save()).value.state
	var payload: Dictionary = game.state.legacy_web_save.duplicate(true)
	_end(game)
	return [state, payload]


func _normal_original() -> void:
	var made := _imported_state()
	_write_save(made[0])
	var game := _game()
	_check(Save.legacy_status(game.state) == "ok" and game.state.legacy_web_save == made[1], "normal: the copy is rebuilt from the original")
	game._mark_dirty()
	game.flush(true)
	_check(not _file_state().has("legacy_web_save") and _file_state().get(Save.LEGACY_SHA256) == CRLF_SHA, "normal: only the original is written")
	_end(game)


func _damaged_original_keeps_copy() -> void:
	var made := _imported_state()
	var cases := {
		"not base64": {Save.LEGACY_BYTES: "!!! not base64 !!!"},
		"SHA-256 mismatch": {Save.LEGACY_SHA256: "0".repeat(64)},
		"not a web save": {Save.LEGACY_BYTES: Marshalls.raw_to_base64("not json".to_utf8_buffer()), Save.LEGACY_SHA256: Save.sha256_hex("not json".to_utf8_buffer())},
		"old text field broken": {Save.LEGACY_TEXT: "{\"broken"},
	}
	for name: String in cases:
		var state: Dictionary = made[0].duplicate(true)
		state["legacy_web_save"] = made[1].duplicate(true)
		if name == "old text field broken":
			for key in [Save.LEGACY_BYTES, Save.LEGACY_SHA256, Save.LEGACY_ORIGIN]:
				state.erase(key)
		state.merge(cases[name], true)
		_write_save(state)
		var damaged: Variant = _file_state().get(Save.LEGACY_BYTES, _file_state().get(Save.LEGACY_TEXT))
		var game := _game()
		_check(game.save_status != "protected" and game.state.get("legacy_web_save") == made[1], "%s: the working copy is kept on load" % name)
		_check(Save.legacy_status(game.state) == "corrupt" and game.legacy_original_bytes().is_empty(), "%s: reported damaged, not offered for export" % name)
		game.state.gold = float(game.state.gold) + 1.0
		game._mark_dirty()
		game.flush(true)
		_end(game)
		var written := _file_state()
		_check(written.get("legacy_web_save") == made[1], "%s: the copy is still written after an autosave" % name)
		var kept: Variant = written.get(Save.LEGACY_BYTES)
		if name == "old text field broken":
			# Converted losslessly to bytes: the damaged text is still there, byte for byte.
			kept = Marshalls.base64_to_raw(kept).get_string_from_utf8()
		_check(kept == damaged, "%s: the damaged original is not removed or changed" % name)
		var reloaded := _game()
		_check(reloaded.state.get("legacy_web_save") == made[1], "%s: the copy survives a reload" % name)
		_end(reloaded)
		_clear()


func _conflicting_original_keeps_both() -> void:
	var made := _imported_state()
	var state: Dictionary = made[0].duplicate(true)
	var changed: Dictionary = made[1].duplicate(true)
	changed.run.gold = 777.0
	state["legacy_web_save"] = changed
	_write_save(state)
	var game := _game()
	_check(Save.legacy_status(game.state) == "conflict", "conflict: reported")
	_check(game.state.legacy_web_save.run.gold == 777.0, "conflict: the stored copy is the one in use")
	game._mark_dirty()
	game.flush(true)
	_end(game)
	var written := _file_state()
	_check(written.legacy_web_save.run.gold == 777.0 and written.get(Save.LEGACY_SHA256) == CRLF_SHA, "conflict: both are written after an autosave")
	var reloaded := _game()
	_check(reloaded.state.legacy_web_save.run.gold == 777.0 and Save.sha256_hex(reloaded.legacy_original_bytes()) == CRLF_SHA, "conflict: both survive a reload")
	_end(reloaded)


# --- P1-4: large and abnormal numbers -----------------------------------------------------------------

func _large_and_abnormal_numbers() -> void:
	# Expected strings from Intl.NumberFormat('ko-KR').format(Math.floor(n)) in Node.
	# Built exactly (a long GDScript literal can itself be read as a neighbouring double).
	var two_63 := float(1 << 62) * 2.0
	var cases := [[two_63, "9,223,372,036,854,776,000"], [pow(2.0, 70.0), "1,180,591,620,717,411,300,000"],
		[float(1 << 53), "9,007,199,254,740,992"], [ExactJson.decimal_to_double("12345678901234568", 4), "123,456,789,012,345,680,000"],
		[ExactJson.decimal_to_double("1", 21), "1,000,000,000,000,000,000,000"]]
	for entry: Array in cases:
		_check(Hud.format_quantity(entry[0]) == entry[1], "fmt(%s) = %s (got %s)" % [var_to_str(entry[0]), entry[1], Hud.format_quantity(entry[0])])
	var top := Hud.format_quantity(ExactJson._from_bits(0x7FEFFFFFFFFFFFFF))
	_check(top.begins_with("179,769,313,486,231,570,000,") and top.length() == 411, "fmt(max double) like Intl (got %d characters)" % top.length())
	_check(Hud.format_quantity(INF) == "0" and Hud.format_quantity(NAN) == "0", "fmt of NaN or infinity shows nothing harmful")
	# The bag and the gold label with huge values.
	var game := _game(false)
	var hud: CanvasLayer = Hud.new()
	root.add_child(hud)
	hud.setup(game)
	game.state.gold = ExactJson.decimal_to_double("1", 20)
	game.state.inventory["iron"] = two_63
	hud.open_inventory()
	hud._refresh(true)
	_check(hud._gold.text == "100,000,000,000,000,000,000 G", "gold label for 1e20 (got %s)" % hud._gold.text)
	var shown := []
	_labels(hud._rows, shown)
	_check(shown.has("9,223,372,036,854,776,000개"), "bag row for 2^63 iron (rows: %s)" % ", ".join(shown))
	root.remove_child(hud)
	hud.free()
	# NaN and infinity cannot be written in JSON; numbers out of range are refused, not read as infinity.
	var before: Dictionary = game.state.duplicate(true)
	_check(not game.import_save("{\"saveVersion\":1,\"run\":{\"gold\":1e999,\"resources\":{},\"products\":{}}}"), "a JS save with gold 1e999 is refused")
	_check(not game.import_save("{\"version\":1,\"state\":{\"gold\":5,\"inventory\":{\"iron\":-1e999}}}"), "a Godot save with an out-of-range amount is refused")
	_check(not game._valid_save_state({"gold": INF, "inventory": {}}) and not game._valid_save_state({"gold": 1.0, "inventory": {"iron": NAN}}), "NaN and infinity in a state are refused")
	_check(not game._valid_save_state({"gold": 1.0, "inventory": {}, "tickets": 1e300}), "a ticket count beyond 2^53 is refused")
	_check(game.state == before, "refused imports leave the game unchanged")
	# A JS save with absurd counts imports with safe values instead of int() overflow (INT64_MIN).
	var absurd := {"saveVersion": 1, "permanent": {"tickets": 1e300}, "run": {"gold": 5, "resources": {}, "products": {}, "hqLevel": 1e300, "craftFacility": 1e19}}
	_check(game.import_save(ExactJson.stringify(absurd)), "a JS save with huge counts imports")
	_check(game.state.tickets == 0 and game.state.hq_level == 0 and game.state.craft_facility == 1, "huge counts fall back to defaults (tickets %s, hq %s, facility %s)" % [game.state.tickets, game.state.hq_level, game.state.craft_facility])
	_end(game)
	# A save file holding an out-of-range number is protected, not loaded or overwritten.
	var text := "{\"version\":1,\"state\":{\"gold\":5,\"inventory\":{\"iron\":1e999}}}"
	var file := FileAccess.open(Save.SAVE_PATH, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	var protected := _game()
	_check(protected.save_status == "protected", "a save file with 1e999 is protected (status %s)" % protected.save_status)
	protected.flush(true)
	_check(Save.read_raw() == text, "the protected file is left exactly as it was")
	_end(protected)


func _labels(node: Node, into: Array) -> void:
	if node is Label:
		into.append(node.text)
	for child in node.get_children():
		_labels(child, into)


# --- P1-5: exact active stock -------------------------------------------------------------------------

func _exact_active_stock() -> void:
	var game := _game()
	_check(game.import_save_bytes(FileAccess.get_file_as_bytes(CRLF_SAVE)), "the save with 1.1500000000000001 iron imports")
	var iron: float = game.state.inventory.iron
	_check(ExactJson._bits(iron) == IRON_BITS, "iron is exactly JavaScript's 1.1500000000000001 (bits %016x)" % ExactJson._bits(iron))
	_check(Hud.format_quantity(iron) == "1.2", "iron shows 1.2 like the original's toFixed(1) (got %s)" % Hud.format_quantity(iron))
	_end(game)
	for round_index in 3:
		var reloaded := _game()
		var value: float = reloaded.state.inventory.iron
		_check(ExactJson._bits(value) == IRON_BITS and Hud.format_quantity(value) == "1.2", "reload %d: iron unchanged (bits %016x, shown %s)" % [round_index + 1, ExactJson._bits(value), Hud.format_quantity(value)])
		_check(Save.read_raw().contains("\"iron\":1.1500000000000001"), "reload %d: the file holds JavaScript's text for the value" % [round_index + 1])
		reloaded._mark_dirty()
		reloaded.flush(true)
		_end(reloaded)
