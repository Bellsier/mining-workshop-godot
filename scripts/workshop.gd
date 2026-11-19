extends Node

signal world_replaced
signal changed
signal feedback(message: String)
signal save_status_changed(status: String)

const World = preload("res://scripts/world/world_state.gd")
const Save = preload("res://scripts/workshop_save.gd")
const Delivery = preload("res://scripts/workshop_delivery.gd")
const Village = preload("res://scripts/workshop_village.gd")
const CraftHuts = preload("res://scripts/craft_huts.gd")
const VillageLayout = preload("res://scripts/village_layout.gd")
const Hud = preload("res://scripts/workshop_hud.gd")
const WorldTerrainScript = preload("res://scripts/world/world_terrain.gd")
const CATALOG := "res://data/web_catalog.json"
const TICK := 0.1
## web TICKS_PER_SECOND (1000 / TICK_MS): per-tick amounts are rate / this, bit for bit like the original.
const TICKS_PER_SECOND := 10.0
## Ten 0.1 s ticks sum to slightly less than 1 s in floating point; the boundary must not slip a tick.
const TICKET_EPSILON := 0.000001
const WEB_SAVE_SCRIPT := "res://scripts/workshop_web_save.js"
## Where an import keeps the save it replaced, and where a set-aside protected save is kept (web).
const WEB_IMPORT_BACKUP := "slot:main:before-import"
const WEB_PROTECTED_BACKUP := "slot:main:protected:"
const AUTOSAVE_INTERVAL := 2.0
## Walking alone is saved at most this often (and whenever the page is hidden or closed).
const POSITION_SAVE_INTERVAL := 15.0
const LOAD_RETRY_DELAYS := [0.5, 1.5, 3.0]
const FAILURE_RETRY_DELAYS := [2.0, 4.0, 8.0, 16.0, 30.0]
const QUOTA_RETRY_DELAYS := [15.0, 30.0, 60.0]
const LOCK_WAIT_MS := 3000
## Workshop-only recipes (catalog workshopOnly) are made only in a craft hut, as in the web original's
## startCraft. Switched on together with the huts themselves: with it off they are made on the recipe cards.
const WORKSHOP_ONLY_IN_HUTS := true
## Statuses that need the player's decision before saving can go on.
const CHOICE_STATUSES := ["unavailable", "other_tab", "protected", "conflict"]

var data: Dictionary = {}
var state: Dictionary = {}
var world: RefCounted
var player: Node2D
var persistence_enabled := true
## loading | pending | saving | saved | saved_basic | importing | failed | quota |
## unavailable | other_tab | protected | conflict | idle
var save_status := "idle"
## Extra words for the status (load attempt, error name, protected reason).
var save_detail := ""
## "strict" when the browser promised the last write reached storage, "basic" otherwise, "" before a write.
var save_durability := ""
## Browser storage persistence: yes | no | unsupported | unknown | "" (not asked yet).
var storage_persisted := ""
var _tables: Dictionary = {}
var _elapsed := 0.0
var _save_elapsed := 0.0
var _web_api: JavaScriptObject
var _web_callbacks: Dictionary = {}
var _web_revision := ""
## "" | claim | loading | autosave | import | set_aside
var _web_operation := ""
var _web_candidate: Dictionary = {}
var _migrated_from := ""
var _legacy_save: Dictionary = {}
var _legacy_present := false
var _load_attempt := 0
var _keep_session_if_missing := false
var _choice_pending := false
var _offline := false
var _protected_raw := ""
var _protected_reason := ""
var _protected_revision := ""
var _protected_source := ""
var _protected_exported := false
var _dirty := false
var _dirty_gameplay := false
var _save_error := OK
var _save_blocked := false
var _retry_at := 0.0
var _retry_count := 0
var _last_commit_at := -INF
var _flush_after_operation := false
var _web_candidate_gameplay := false
## A change the save label should show as waiting ("pending"): a player action or a move. What the game
## produces by itself every tick (workers, huts, timers) is only written by the regular autosave, as in the
## web original, whose label keeps showing the last save between its periodic saves.
var _dirty_shown := false
var _web_candidate_shown := false

func _ready() -> void:
	var catalog: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG))
	if not catalog is Dictionary:
		push_error("Could not load the web game catalog: " + CATALOG)
		set_process(false)
		return
	data = catalog
	for table in ["resources", "recipes", "research", "sites", "rarity"]:
		_tables[table] = {}
		for row: Dictionary in data[table]:
			_tables[table][row.key] = row
	var saved := Save.load_game() if persistence_enabled else {}
	var present := persistence_enabled and Save.has_file()
	if persistence_enabled and OS.has_feature("web"):
		# The first web build kept the save in Godot's user:// folder. It is only read, for migration.
		_legacy_save = saved
		_legacy_present = present
		_web_operation = "claim"
		_set_save_status("loading")
		_restore({})
		_start_web.call_deferred()
	else:
		_load_initial_state(saved, present)
		if not persistence_enabled:
			_set_save_status("idle")

## Desktop start (and the web's Godot-file fallback): a present file that cannot be read is protected.
func _load_initial_state(saved: Dictionary, present: bool) -> void:
	_clear_protected()
	_dirty = false
	_dirty_gameplay = false
	_dirty_shown = false
	if present and not _valid_save_state(saved):
		_protect(Save.read_raw(), "", ProjectSettings.globalize_path(Save.SAVE_PATH))
		_restore({})
		return
	_save_blocked = false
	_save_error = OK
	_restore(saved)
	if not present:
		_dirty = persistence_enabled
		_dirty_gameplay = persistence_enabled
	_last_commit_at = _now() if present else -INF
	# Normalizing an older save can change it; it is then saved again on the next tick.
	_set_save_status("pending" if _dirty or not present else "saved")

func input_frozen() -> bool:
	return _web_operation in ["claim", "loading", "import", "set_aside"] or _choice_pending

func _set_save_status(status: String, detail := "") -> void:
	if status == save_status and detail == save_detail:
		return
	save_status = status
	save_detail = detail
	save_status_changed.emit(status)

func _mark_dirty(position_only := false, background := false) -> void:
	_dirty = true
	if not position_only:
		_dirty_gameplay = true
	if background:
		return
	_dirty_shown = true
	if save_status in ["idle", "saved", "saved_basic"] and persistence_enabled:
		_set_save_status("pending")

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# --- web storage --------------------------------------------------------------------------------------

func _start_web() -> void:
	var source := FileAccess.get_file_as_string(WEB_SAVE_SCRIPT)
	if not source.is_empty():
		JavaScriptBridge.eval(source, true)
		_web_api = JavaScriptBridge.get_interface("miningWorkshopSave")
	if _web_api == null:
		_on_web_load(["error", "", "", "", "no-api"])
		return
	_web_api.onHide(_web_callback(_on_page_hidden))
	_web_api.persist(false, _web_callback(_on_persist))
	_claim()

## One JavaScript callback per handler, created once and kept referenced while the browser may call it.
## (Only one storage request runs at a time, so a handler never has two answers in flight.)
func _web_callback(method: Callable) -> JavaScriptObject:
	var key := method.get_method()
	if not _web_callbacks.has(key):
		_web_callbacks[key] = JavaScriptBridge.create_callback(method)
	return _web_callbacks[key]

func _claim() -> void:
	_web_operation = "claim"
	_set_save_status("loading")
	_web_api.claim(LOCK_WAIT_MS, _web_callback(_on_claim))

func _on_claim(args: Array) -> void:
	if str(args[0]) == "busy":
		_web_operation = ""
		_save_blocked = true
		_enter_choice("other_tab")
		return
	_load_attempt = 0
	_web_load()

func _web_load() -> void:
	_web_operation = "loading"
	_load_attempt += 1
	_set_save_status("loading", "%d/%d" % [_load_attempt, LOAD_RETRY_DELAYS.size() + 1] if _load_attempt > 1 else "")
	_web_api.load(JSON.stringify([OS.get_user_data_dir()]), _web_callback(_on_web_load))

func _on_web_load(args: Array) -> void:
	var status := str(args[0])
	var text := str(args[1]) if args.size() > 1 else ""
	var revision := str(args[2]) if args.size() > 2 else ""
	var source := str(args[3]) if args.size() > 3 else ""
	var detail := str(args[4]) if args.size() > 4 else ""
	if status == "error":
		if _web_api != null and _load_attempt <= LOAD_RETRY_DELAYS.size():
			# Busy disks and slow devices often answer on a second try.
			get_tree().create_timer(LOAD_RETRY_DELAYS[_load_attempt - 1]).timeout.connect(_web_load)
			_set_save_status("loading", "%d/%d" % [_load_attempt + 1, LOAD_RETRY_DELAYS.size() + 1])
			return
		# The save could not be read. It is NOT treated as empty: nothing is written until it can be.
		_web_operation = ""
		_save_blocked = true
		_save_error = ERR_CANT_OPEN
		if not _offline:
			_restore(_legacy_save if _valid_save_state(_legacy_save) else {})
		_enter_choice("unavailable", detail)
		world_replaced.emit()
		changed.emit()
		return
	_web_operation = ""
	_clear_protected()
	_offline = false
	_save_blocked = false
	_save_error = OK
	_migrated_from = ""
	_dirty = false
	_dirty_gameplay = false
	_dirty_shown = false
	match status:
		"loaded", "migrate":
			var parsed := Save.parse_game(text)
			if not _valid_save_state(parsed):
				_web_revision = revision
				_protect(text, revision, source)
				_restore({})
			else:
				_web_revision = revision
				_restore(parsed)
				if status == "migrate":
					_migrated_from = source
					_mark_dirty()
				else:
					_set_save_status("saved")
		"invalid":
			_web_revision = revision
			_protect(text, revision, source)
			_restore({})
		_:
			_web_revision = ""
			if _legacy_present:
				if _valid_save_state(_legacy_save):
					_restore(_legacy_save)
					_migrated_from = "user://" + Save.SAVE_PATH.get_file()
					_mark_dirty()
				else:
					_protect(Save.read_raw(), "", "user://" + Save.SAVE_PATH.get_file())
					_restore({})
			elif _keep_session_if_missing:
				_mark_dirty()
			else:
				_restore({})
				_mark_dirty()
	_keep_session_if_missing = false
	# What is in memory now matches the store: walking alone waits a full interval before the next write.
	_last_commit_at = _now()
	if not is_protected():
		_choice_pending = false
		_set_save_status("pending" if _dirty else "saved")
	world_replaced.emit()
	changed.emit()

func _on_page_hidden(_args: Array) -> void:
	flush(true)

func _on_persist(args: Array) -> void:
	storage_persisted = str(args[0])
	changed.emit()
	save_status_changed.emit(save_status)

# --- protected saves and recovery choices ---------------------------------------------------------------

func _protect(raw: String, revision: String, source: String) -> void:
	_protected_raw = raw
	_protected_revision = revision
	_protected_source = source
	_protected_exported = false
	var parser := JSON.new()
	var envelope: Variant = parser.data if not raw.is_empty() and parser.parse(raw) == OK else null
	var version: Variant = envelope.get("version") if envelope is Dictionary else null
	_protected_reason = "future" if (version is int or version is float) and float(version) > Save.SAVE_VERSION else "corrupt"
	_save_blocked = true
	_save_error = ERR_FILE_CORRUPT
	_enter_choice("protected", _protected_reason)

func _clear_protected() -> void:
	_protected_raw = ""
	_protected_reason = ""
	_protected_revision = ""
	_protected_source = ""
	_protected_exported = false

func _enter_choice(status: String, detail := "") -> void:
	_choice_pending = true
	_set_save_status(status, detail)
	changed.emit()

func is_protected() -> bool:
	return not _protected_source.is_empty()

## What the save UI should offer now: {status, title, message, modal, actions: [{id, label, enabled}]}.
func save_notice() -> Dictionary:
	var notice := {"status": save_status, "title": "", "message": "", "modal": _choice_pending, "actions": []}
	var actions: Array = notice.actions
	match save_status:
		"unavailable":
			notice.title = "저장을 불러오지 못했어요"
			notice.message = "브라우저 저장소가 응답하지 않아요(%s). 기존 저장은 그대로 두었고, 확인될 때까지 아무것도 덮어쓰지 않아요." % (save_detail if not save_detail.is_empty() else "원인 미상")
			if _offline:
				notice.message += " 지금 진행은 저장되지 않아요. 다시 시도해서 기존 저장을 찾으면 그 저장으로 바뀌니, 필요하면 먼저 내보내세요."
			actions.append({"id": "retry", "label": "다시 시도", "enabled": true})
			actions.append({"id": "export_current", "label": "현재 진행 내보내기", "enabled": true})
			actions.append({"id": "offline", "label": "저장 없이 계속", "enabled": _choice_pending})
		"other_tab":
			notice.title = "다른 탭에서 게임이 열려 있어요"
			notice.message = "저장이 섞이지 않도록 이 탭에서는 저장하지 않아요. 다른 탭을 닫은 뒤 다시 확인하세요. 둘러보기는 새 게임으로 열리고 저장되지 않아요."
			actions.append({"id": "retry", "label": "다시 확인", "enabled": true})
			actions.append({"id": "offline", "label": "저장 없이 둘러보기", "enabled": _choice_pending})
		"conflict":
			notice.title = "다른 곳에서 더 최근에 저장했어요"
			notice.message = "이 탭의 진행은 저장되지 않았어요. 필요하면 내보낸 뒤 최신 저장을 불러오세요."
			actions.append({"id": "export_current", "label": "이 탭 진행 내보내기", "enabled": true})
			actions.append({"id": "retry", "label": "최신 저장 불러오기", "enabled": true})
			actions.append({"id": "offline", "label": "저장 없이 계속", "enabled": _choice_pending})
		"protected":
			notice.title = "이 저장은 열 수 없어서 보호 중이에요"
			notice.message = ("더 새로운 버전의 게임에서 만든 저장이에요." if _protected_reason == "future" else "저장 내용이 손상됐거나 형식이 달라요.") + \
				" 원본은 그대로 있어요. 원본을 내보낸 뒤에만 보관 처리하고 새로 시작하거나 다른 저장을 가져올 수 있어요."
			actions.append({"id": "export_raw", "label": "원본 저장 내보내기", "enabled": true})
			actions.append({"id": "set_aside", "label": "원본 보관 후 새로 시작", "enabled": _protected_exported})
			if OS.has_feature("web"):
				actions.append({"id": "retry", "label": "다시 확인", "enabled": true})
			actions.append({"id": "offline", "label": "저장 없이 둘러보기", "enabled": _choice_pending})
		"failed", "quota":
			notice.title = "저장 공간이 부족해요" if save_status == "quota" else "자동 저장에 실패했어요"
			notice.message = "마지막으로 저장된 내용은 그대로예요. 잠시 뒤 자동으로 다시 시도해요. JSON 백업을 권해요."
			actions.append({"id": "retry_save", "label": "지금 다시 저장", "enabled": true})
			actions.append({"id": "export_current", "label": "현재 진행 내보내기", "enabled": true})
	return notice

## Runs a choice from save_notice(). Returns text to show for the export actions, "" otherwise.
func save_action(id: String) -> String:
	match id:
		"retry":
			if not OS.has_feature("web") or _web_api == null or not _web_operation.is_empty():
				return ""
			_keep_session_if_missing = _offline and _dirty_gameplay
			_choice_pending = false
			if save_status == "other_tab":
				_claim()
			else:
				_load_attempt = 0
				_web_load()
		"offline":
			_choice_pending = false
			_offline = true
			_save_blocked = true
			changed.emit()
			save_status_changed.emit(save_status)
		"export_current":
			return export_save()
		"export_raw":
			return export_protected()
		"set_aside":
			set_aside_protected({})
		"retry_save":
			_retry_at = 0.0
			flush(true)
		"persist":
			if _web_api != null:
				_web_api.persist(true, _web_callback(_on_persist))
	return ""

## The protected save exactly as stored. On the web it is also offered as a file download.
func export_protected() -> String:
	if not is_protected():
		return ""
	_protected_exported = true
	if OS.has_feature("web") and not _protected_raw.is_empty():
		var stamp := Time.get_datetime_string_from_system().replace(":", "-")
		JavaScriptBridge.download_buffer(_protected_raw.to_utf8_buffer(), "mining-workshop-protected-%s.json" % stamp, "application/json")
	changed.emit()
	save_status_changed.emit(save_status)
	return _protected_raw

## Offers the current progress as a file download (web).
func download_save() -> bool:
	var text := export_save()
	if text.is_empty() or not OS.has_feature("web"):
		return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	JavaScriptBridge.download_buffer(text.to_utf8_buffer(), "mining-workshop-save-%s.json" % stamp, "application/json")
	return true

## Keeps the protected save (renamed on desktop, moved to a backup key on the web) and starts saving
## `replacement` ({} = a new game) in its place. Requires the original to have been exported first.
func set_aside_protected(replacement: Dictionary) -> bool:
	if not is_protected():
		return false
	if not _protected_exported:
		return _reject("먼저 원본 저장을 내보내 주세요. 원본은 그대로 보호하고 있어요.")
	if not _web_operation.is_empty():
		return _reject("저장 확인 중이에요. 잠시 후 다시 시도해 주세요.")
	var old_state := state
	var old_world := world
	_restore(replacement)
	var candidate := state
	state = old_state
	world = old_world
	World.set_current(world)
	if OS.has_feature("web") and persistence_enabled:
		var backup := WEB_PROTECTED_BACKUP + (_protected_revision if not _protected_revision.is_empty() else Crypto.new().generate_random_bytes(8).hex_encode())
		var expected := _protected_revision if _protected_source == "slot:main" else ""
		_web_candidate = candidate
		if _start_web_commit("set_aside", candidate, expected, {"overwriteInvalid": true, "backupKey": backup}):
			return true
		_enter_choice("protected", _protected_reason)
		return false
	var kept := Save.set_aside_protected()
	if kept.is_empty():
		return _reject("원본 저장을 보관하지 못해서 아무것도 바꾸지 않았어요.")
	if persistence_enabled and Save.save_game(candidate) != OK:
		_report_save_failure("write")
		return _reject("원본은 %s 에 보관했지만 새 저장을 쓰지 못했어요." % kept[0].get_file())
	_clear_protected()
	_choice_pending = false
	_offline = false
	_save_blocked = false
	_apply_import(candidate, "원본 저장을 %s 로 보관했어요." % kept[0].get_file())
	return true

func _restore(source: Dictionary) -> void:
	state = {
		"gold": 0.0, "inventory": {}, "completed_research": {}, "unlocked_sites": {"abandonedMine": true},
		"characters": [], "automation": {"craft": {}, "sell_owned": {}, "sell": {}, "target": {}},
		"queue": {}, "tickets": 0, "ticket_elapsed": 0.0, "first_ticket": false,
		"hq_level": 0, "craft_facility": 1, "facility": {}, "workforce": {}, "stats": {},
		"position": {}, "tunnel_open": false, "tunnel_remaining": 0.0, "last_pull": {}, "auto_line_logged": false,
	}
	state.merge(source, true)
	# The original's ticket interval starts again at every page load; it is not carried in the save.
	state.ticket_elapsed = 0.0
	# An imported web save's parsed copy is rebuilt from its original bytes when it is not stored.
	if not state.get("legacy_web_save") is Dictionary:
		var original := Save.legacy_original(state)
		if original.status == "ok":
			state.legacy_web_save = original.payload.duplicate(true)
	var legacy: Dictionary = _dictionary(state.get("legacy_web_save"))
	var legacy_run := _dictionary(legacy.get("run"))
	var village_source: Variant = source.get("village", legacy_run.get("village"))
	# A Godot save from before the village layout was ported has no sites: those of the web save it was
	# imported from are taken from that save (the plaza, the garden and its decorations too).
	var legacy_village := _dictionary(legacy_run.get("village"))
	if village_source is Dictionary and not village_source.has("sites") and legacy_village.has("sites"):
		village_source = village_source.duplicate()
		for key in ["sites", "district", "decor"]:
			if legacy_village.has(key):
				village_source[key] = legacy_village[key]
	state["village"] = Village.load_progress(village_source)
	_village_try_key = ""
	if not legacy.is_empty() and not source.has("characters"):
		var run := legacy_run
		var permanent := _dictionary(legacy.get("permanent"))
		var records: Variant = run.get("characters", [])
		if records is Array:
			for record in records:
				if _valid_worker(record):
					state.characters.append(record.duplicate(true))
		state.unlocked_sites.merge(_dictionary(run.get("unlockedSites")), true)
		state.unlocked_sites.abandonedMine = true
		state.automation = {"craft": _dictionary(run.get("autoCraft")), "sell_owned": _dictionary(run.get("autoSell")),
			"sell": _dictionary(run.get("autoSellOn")), "target": _dictionary(run.get("craftTarget"))}
		var old_queue := _dictionary(run.get("craftQueue"))
		for id: String in old_queue:
			var time: Variant = old_queue[id]
			if (time is float or time is int) and time > 0.0 and _tables.recipes.has(id):
				state.queue[id] = float(time)
		state.tickets = _count(permanent.get("tickets"), 0)
		state.first_ticket = bool(permanent.get("firstGachaGranted", false))
		state.hq_level = _count(run.get("hqLevel"), 0)
		state.craft_facility = maxi(1, _count(run.get("craftFacility"), 1))
		state.facility = _dictionary(run.get("facility"))
		state.workforce = _dictionary(run.get("workforce"))
		state.tunnel_open = bool(_dictionary(run.get("world")).get("tunnelUnlocked", false))
		state.last_pull = _dictionary(run.get("lastPull")) if _valid_worker(run.get("lastPull")) else {}
		state.auto_line_logged = run.get("autoLineLogged") == true

	var legacy_world := _dictionary(legacy_run.get("world"))
	var world_data: Dictionary = source.get("world", legacy_world)
	# A Godot save written before huts, torches and the tunnel job were ported has none of them in its world.
	# Those of the web save it was imported from are then taken from that save, so they are not lost.
	for key in ["workshops", "torches", "tunnelContract"]:
		if not world_data.has(key) and legacy_world.has(key):
			world_data = world_data.duplicate()
			world_data[key] = legacy_world[key]
	world = World.from_dict(world_data) if world_data.has("mines") else World.new_game()
	if not world_data.has("mines"):
		world.workshops = CraftHuts.sanitize(world_data.get("workshops", []), _tables.recipes, world.is_seeded())
		world.torches = World.sanitize_torches(world_data.get("torches", []), world.is_seeded())
		world.tunnel_contract = {} if world.tunnel_unlocked else World.sanitize_contract(world_data.get("tunnelContract"))
	# Builds before the wall-clock job counted the tunnel down in play time (tunnel_remaining): that job
	# goes on from where it stood.
	var remaining_before := float(state.get("tunnel_remaining", 0.0))
	if world.tunnel_contract.is_empty() and remaining_before > 0.0 and not world.tunnel_unlocked:
		var duration := float(data.balance.tunnel.DURATION_SEC)
		world.tunnel_contract = {"startedAt": now_ms() - (duration - minf(remaining_before, duration)) * 1000.0, "durationSec": duration}
	World.set_current(world)
	# Like the web researchSyncFromState: huts or automation already in use count as researched.
	var in_use := CraftHuts.research_in_use(world.workshops, _dictionary(state.automation.get("craft")))
	if in_use.any(func(key: String) -> bool: return state.completed_research.get(key, false) != true):
		state.completed_research = _dictionary(state.completed_research)
		for key in in_use:
			state.completed_research[key] = true
	world.exploration_gear = bool(state.completed_research.get("explorationGear", false))
	if state.tunnel_open and not world.tunnel_unlocked:
		world.unlock_tunnel()
	state.tunnel_open = world.tunnel_unlocked
	world.discovered.connect(func(_mine): _mark_dirty())
	world.tunnel_opened.connect(func(_added): _mark_dirty())
	# A web save's player stands where it was (web sanitizePlayer: inside the world, on walkable ground; else the
	# base). 1 world unit is 64 px on the Godot map.
	if state.position.is_empty() and not legacy_world.is_empty() and not source.has("world"):
		var p := _dictionary(legacy_world.get("player"))
		var px: Variant = p.get("x")
		var py: Variant = p.get("y")
		if (px is float or px is int) and (py is float or py is int) and is_finite(float(px)) and is_finite(float(py)) \
				and WorldTerrainScript.is_point_walkable(float(px), float(py), world.tunnel_unlocked):
			state.position = {"scene": "res://scenes/world/world_map.tscn", "x": float(px) * 64.0, "y": float(py) * 64.0}
	# Trial-scene pixels are not coordinates on the unified world map.
	if str(state.position.get("scene", "")) in ["res://scenes/overworld.tscn", "res://scenes/tunnel.tscn"]:
		state.position = {}
	_record_world()

func _record_world(background := false) -> void:
	if world == null:
		return
	var value: Dictionary = world.to_dict()
	if state.get("world", {}) != value:
		state["world"] = value
		_mark_dirty(false, background)
	state.tunnel_open = world.tunnel_unlocked

# --- world veins (web factory.js secureMine / mineMine, interact.js) --------------------------------------

## What pressing E at a vein does: "secure" (unsecured, its area open), "mine" (secured), "locked" (its area
## is still closed) or "" (unknown or still hidden).
func vein_action(id: String) -> String:
	var vein: Dictionary = world.mine_by_id(id)
	if vein.is_empty() or not world.is_discovered(vein):
		return ""
	if vein.get("developmentState") == "secured":
		return "mine"
	return "secure" if is_resource_open(str(vein.resource)) else "locked"

## Secures a found vein whose area is open: from then on it yields miningPower * grade * MINE_RATE_PER_GRADE
## per second (times the multiplier) and can be mined by hand.
func secure_vein(id: String) -> bool:
	var vein: Dictionary = world.mine_by_id(id)
	if vein.is_empty() or vein.get("developmentState") != "unsecured" or not world.is_discovered(vein):
		return false
	if not is_resource_open(str(vein.resource)):
		var site: Dictionary = _tables.sites.get(_tables.resources.get(vein.resource, {}).get("site", ""), {})
		return _reject("%s 해금이 필요해요." % site.get("name", "지역"))
	world.secure(id)
	_record_world()
	return _updated("광맥 확보 · %s (%d, %d)" % [_label(vein.resource), int(vein.x), int(vein.y)])

## Mines a secured vein by hand: miningPower times the multiplier. Now and then an unidentified relic turns up
## (more often in a relic vein and beyond the mountains).
func mine_vein(id: String) -> bool:
	var vein: Dictionary = world.mine_by_id(id)
	if vein.is_empty() or not world.is_discovered(vein) or vein.get("developmentState") != "secured":
		return false
	if not _tables.resources.has(vein.resource) or not (float(vein.get("miningPower", 0)) > 0.0):
		return false
	var amount := float(vein.miningPower) * _multiplier()
	_add(vein.resource, amount)
	var beyond := WorldTerrainScript.region_at(float(vein.x), float(vein.y)) == "beyond"
	var relic_found := Village.mine(data, state.village, str(vein.resource), beyond)
	return _updated("%s +%s%s" % [_label(vein.resource), Hud.format_quantity(amount), " · 미감정 유물!" if relic_found else ""])

## Passive yield of one secured vein per second, before the multiplier (web mineBaseRate).
func vein_rate(vein: Dictionary) -> float:
	return float(vein.miningPower) * float(vein.grade) * float(data.balance.mining.MINE_RATE_PER_GRADE)

## Automatic income of a resource per second (web autoRate): workers, workforce and secured veins.
func auto_rate(id: String) -> float:
	var workers := 0.0
	for c: Dictionary in state.characters:
		if c.get("resource") == id:
			workers += float(c.mining) * float(c.carry) * float(c.move) / float(data.balance.worker.EFFECTIVE_DIVISOR)
	var workforce := float(state.workforce.get(id, 0)) * float(data.balance.mining.WORKFORCE_BONUS_MULTIPLIER)
	var veins := 0.0
	for m: Dictionary in world.mines:
		if m.get("resource") == id and m.get("developmentState") == "secured":
			veins += vein_rate(m)
	return (workers + workforce + veins) * _multiplier()

## The clock the tunnel job runs on (web gameNowMs: Date.now). Tests set clock_override_ms.
var clock_override_ms := -1.0

func now_ms() -> float:
	return clock_override_ms if clock_override_ms >= 0.0 else Time.get_unix_time_from_system() * 1000.0

## Seconds of tunnel work left (web tunnelWorkRemainingSec), or -1 without a job. A start time in the future
## (the clock set back) counts as just started.
func tunnel_remaining_sec() -> float:
	var job: Dictionary = world.tunnel_contract
	if job.is_empty():
		return -1.0
	var elapsed := maxf(0.0, (now_ms() - float(job.startedAt)) / 1000.0)
	return maxf(0.0, float(job.durationSec) - elapsed)

## Opens the tunnel when the work is done (web tickTunnelWork). The job runs on real time, so it also goes on
## while the game is closed. A start time in the future is moved to now. Returns true when it just opened.
func _tick_tunnel() -> bool:
	var job: Dictionary = world.tunnel_contract
	if job.is_empty():
		state.tunnel_remaining = 0.0
		return false
	var now := now_ms()
	if float(job.startedAt) > now:
		job.startedAt = now
	var left := tunnel_remaining_sec()
	state.tunnel_remaining = left
	if left > 0.0:
		return false
	world.tunnel_contract = {}
	state.tunnel_remaining = 0.0
	world.unlock_tunnel()
	_record_world()
	feedback.emit("터널이 열렸습니다. 산 너머로 갈 수 있어요.")
	return true

func order_tunnel(_id := "") -> bool:
	if world.tunnel_unlocked or not world.tunnel_contract.is_empty() or not state.completed_research.get("tunnelWork", false):
		return false
	var rules: Dictionary = data.balance.tunnel
	if not _pay({"gold": rules.COMMISSION_GOLD, "products": rules.COMMISSION_PRODUCTS}):
		return _reject("터널 공사 비용이 부족해요.")
	world.tunnel_contract = {"startedAt": now_ms(), "durationSec": float(rules.DURATION_SEC)}
	state.tunnel_remaining = float(rules.DURATION_SEC)
	_record_world()
	return _updated("터널 공사를 시작했어요.")

# --- craft huts (제작소) ----------------------------------------------------------------------------------
# The web original's factory.js workshop rules; the pure parts are in scripts/craft_huts.gd.

func hut_by_id(id: String) -> Dictionary:
	for hut: Dictionary in world.workshops:
		if hut.id == id:
			return hut
	return {}

var _village_try_key := ""

## Gives the village its facility sites and plaza when it has none yet (web villageEnsureSites, run by
## tickStep): once per world shape, since a search that found nothing is not repeated until the world changes.
## Returns true when the village changed.
func _ensure_village() -> bool:
	var v: Dictionary = state.village
	if v.sites.get("appraiser") is Dictionary and v.sites.get("museum") is Dictionary and v.get("district") is Dictionary:
		return false
	var key := "%d,%d|%d|%d|%s|%d" % [world.base.x, world.base.y, world.mines.size(), world.workshops.size(), world.tunnel_unlocked, world.torches.size()]
	if key == _village_try_key:
		return false
	var before := JSON.stringify([v.sites, v.get("district")])
	var done := VillageLayout.ensure_sites(world, v)
	_village_try_key = "" if done and v.get("district") is Dictionary else key
	return JSON.stringify([v.sites, v.get("district")]) != before

## Why the next hut cannot be built ("" when it can): research, the limit, gold and parts, then a free cell.
func hut_build_block() -> String:
	if not state.completed_research.get("workshopBuild", false):
		return "research"
	if world.workshops.size() >= CraftHuts.max_count(data, state.completed_research):
		return "limit"
	var count: int = world.workshops.size()
	if float(state.gold) < CraftHuts.build_cost(data, count) or not _has(CraftHuts.build_products(data, count)):
		return "cost"
	if not _hut_spot_free():
		return "spot"
	return ""

var _spot_key := ""
var _spot_free := false

## Is there a free cell for the next hut? Worked out again only when what it depends on changed: the search
## lays the village roads out and measures every cell round the workshop against them.
func _hut_spot_free() -> bool:
	var key := "%s|%s|%s|%s" % [_village_key(), world.base, world.is_seeded(),
		JSON.stringify(world.mines.map(func(m: Dictionary) -> Array: return [m.x, m.y]))]
	if key != _spot_key:
		_spot_key = key
		_spot_free = CraftHuts.build_spot(world.base, world.mines, world.workshops, world.is_seeded(), true, world, state.village) != null
	return _spot_free

## Builds the next hut on the first free cell round the workshop (web buildWorkshop).
func build_hut(_id := "") -> bool:
	var block := hut_build_block()
	if not block.is_empty():
		return _reject({"research": "먼저 연구에서 \"제작소 건설\"을 마쳐 주세요.", "limit": "제작소를 더 지을 수 없어요.",
			"cost": "제작소를 지을 비용이 부족해요.", "spot": "공방 주변에 제작소를 지을 빈 자리가 없어요."}[block])
	var spot: Vector2i = CraftHuts.build_spot(world.base, world.mines, world.workshops, world.is_seeded(), false, world, state.village)
	var count: int = world.workshops.size()
	var taken := {}
	for hut: Dictionary in world.workshops:
		taken[hut.id] = true
	_pay({"gold": CraftHuts.build_cost(data, count), "products": CraftHuts.build_products(data, count)})
	world.workshops.append({"id": CraftHuts.new_id(taken), "x": spot.x, "y": spot.y, "level": 1,
		"recipeKey": null, "auto": false, "progress": null})
	_record_world()
	return _updated("제작소 건설 · (%d, %d)" % [spot.x, spot.y])

## Raises one hut a level: gold, and for the top levels some high-tier parts (web upgradeWorkshop).
func upgrade_hut(id: String) -> bool:
	var hut := hut_by_id(id)
	var cost := CraftHuts.upgrade_cost(data, hut) if not hut.is_empty() else {}
	if cost.is_empty():
		return false
	if not _pay(cost):
		return _reject("제작소 업그레이드 비용이 부족해요.")
	hut.level = int(hut.level) + 1
	_record_world()
	return _updated("제작소 Lv.%d" % hut.level)

## Chooses what a hut makes ("" = nothing). Not while it is making something (web setWorkshopRecipe).
func set_hut_recipe(id: String, recipe_id: String) -> bool:
	var hut := hut_by_id(id)
	var key: Variant = null if recipe_id.is_empty() else recipe_id
	if hut.is_empty() or (key != null and not _tables.recipes.has(key)):
		return false
	if hut.progress != null:
		return _reject("제작 중에는 레시피를 바꿀 수 없어요.")
	if hut.recipeKey == key:
		return false
	hut.recipeKey = key
	_record_world()
	return _updated()

## Switches a hut's automatic crafting. Turning it on needs a recipe and 자동 제작 장치, and starts a craft
## at once when the inputs are there (the web hut card's checkbox).
func set_hut_auto(id: String, enabled: bool) -> bool:
	var hut := hut_by_id(id)
	if hut.is_empty():
		return false
	if enabled and hut.recipeKey == null:
		return _reject("먼저 레시피를 정해 주세요.")
	if enabled and not state.completed_research.get("autoCraftDevice", false):
		return _reject("자동 제작 장치 연구가 필요해요.")
	hut.auto = enabled
	if enabled:
		_start_hut(hut)
	_record_world()
	return _updated()

## Starts one craft in a hut by hand (web craftWorkshop).
func craft_hut(id: String) -> bool:
	var hut := hut_by_id(id)
	if hut.is_empty() or hut.recipeKey == null:
		return _reject("먼저 레시피를 정해 주세요.")
	if not _start_hut(hut):
		return _reject("재료가 부족하거나 제작 중이에요.")
	_record_world()
	return _updated("%s %s" % [_label(hut.recipeKey), "제작 시작" if hut.progress != null else "제작 완료"])

func _start_hut(hut: Dictionary) -> bool:
	if hut.progress != null:
		return false
	var recipe: Dictionary = _tables.recipes.get(hut.recipeKey, {}) if hut.recipeKey is String else {}
	if recipe.is_empty() or not _has(recipe.need):
		return false
	_consume(recipe.need)
	var time := CraftHuts.craft_time(data, hut, recipe, Delivery.reputation_effect(data, state, "craftSpeed"))
	if time > 0.0:
		hut.progress = time
	else:
		_add(recipe.key, float(recipe.out))
	return true

## One tick of every hut (web tickWorkshops): crafts in progress count down by exactly 0.1 s and finish at 0
## or below; then idle automatic huts start again unless their craft target is reached.
func _tick_huts() -> bool:
	var mutated := false
	for hut: Dictionary in world.workshops:
		if hut.progress == null:
			continue
		mutated = true
		var recipe: Dictionary = _tables.recipes.get(hut.recipeKey, {}) if hut.recipeKey is String else {}
		if recipe.is_empty():
			hut.progress = null
			continue
		hut.progress = float(hut.progress) - TICK
		if hut.progress <= 0.0:
			hut.progress = null
			_add(recipe.key, float(recipe.out))
	if state.completed_research.get("autoCraftDevice", false):
		for hut: Dictionary in world.workshops:
			if hut.auto != true or hut.progress != null:
				continue
			if hut.recipeKey is String and _at_craft_target(hut.recipeKey):
				continue
			mutated = _start_hut(hut) or mutated
	return mutated

func _at_craft_target(id: String) -> bool:
	var target := int(state.automation.target.get(id, 0))
	return target > 0 and float(state.inventory.get(id, 0)) >= target

func hut_status(hut: Dictionary) -> Dictionary:
	var recipe: Dictionary = _tables.recipes.get(hut.recipeKey, {}) if hut.recipeKey is String else {}
	return CraftHuts.status(hut, recipe, state.inventory, state.completed_research.get("autoCraftDevice", false) == true,
		int(state.automation.target.get(str(hut.recipeKey), 0)))

func _huts_snapshot() -> Dictionary:
	var list: Array = []
	for index in world.workshops.size():
		var hut: Dictionary = world.workshops[index]
		var st := hut_status(hut)
		list.append({"id": hut.id, "number": index + 1, "x": hut.x, "y": hut.y, "level": hut.level,
			"recipe": hut.recipeKey if hut.recipeKey != null else "", "auto": hut.auto,
			"progress": hut.progress if hut.progress != null else 0.0, "status": st.state, "shortages": st.shortages,
			"upgrade": CraftHuts.upgrade_cost(data, hut)})
	var count: int = world.workshops.size()
	# web bottleneckReport: the huts standing idle and the items the stuck ones lack, most needed first.
	var idle: Array = []
	for item: Dictionary in list:
		if item.status != "working":
			idle.append({"number": item.number, "status": item.status, "recipe": item.recipe, "shortages": item.shortages})
	return {"list": list, "max": CraftHuts.max_count(data, state.completed_research), "block": hut_build_block(),
		"idle": idle, "missing": bottleneck_items().slice(0, 3),
		"cost": {"gold": CraftHuts.build_cost(data, count), "products": CraftHuts.build_products(data, count)}}

func snapshot() -> Dictionary:
	var recipes: Array = []
	var resources: Array = []
	var research: Array = []
	var sites: Array = []
	var workers: Array = []
	var assigned: Dictionary = {}
	for record: Dictionary in state.characters:
		var resource_id := str(record.get("resource", ""))
		assigned[resource_id] = int(assigned.get(resource_id, 0)) + 1
		var stats := {}
		for stat in ["mining", "carry", "move"]:
			stats[stat] = {"value": float(record.get(stat, 0)), "level": int(record.get(stat + "Lvl", 0)),
				"max": int(data.balance.worker.STAT_MAX_LEVEL), "cost": worker_upgrade_cost(record, stat),
				"label": str(data.stat_label.get(stat, stat))}
		workers.append({"id": record.id, "resource": resource_id, "rarity": record.rarity,
			"name": _label(resource_id), "rating": _tables.rarity.get(record.rarity, {}).get("label", record.rarity),
			"stats": stats, "effective": _worker_effective(record)})
	for row: Dictionary in data.resources:
		resources.append({"id": row.key, "name": row.name, "unlocked": is_resource_open(row.key)})
	for row: Dictionary in data.recipes:
		recipes.append({"id": row.key, "name": row.name, "inputs": row.need, "output": row.key,
			"count": row.out, "sell": row.sell, "time": row.craftTime, "remaining": state.queue.get(row.key, 0),
			"workshop_only": row.get("workshopOnly", false), "auto_sell_cost": _auto_sell_cost(row),
			"locked": Delivery._needs_locked_resource(data, state, row, []), "hut_only": _hut_only(row.key)})
	for row: Dictionary in data.research:
		research.append({"id": row.key, "name": row.name, "cost": _research_cost(row), "requires": row.requires, "description": row.desc})
	for row: Dictionary in data.sites:
		sites.append({"id": row.key, "name": row.name, "cost": {"gold": row.unlockCost, "products": row.unlockProducts},
			"unlocked": state.unlocked_sites.get(row.key, false)})
	return {"gold": state.gold, "inventory": state.inventory, "resources": resources, "recipes": recipes,
		"workers": [{"id": "ticket", "name": "인부 뽑기 (가챠권)", "cost": 0, "tickets": state.tickets},
			{"id": "gold", "name": "인부 뽑기 (골드)", "cost": data.balance.gacha.PULL_COST_GOLD}],
		"owned_workers": assigned, "worker_details": workers, "tickets": state.tickets, "research": research,
		"completed_research": state.completed_research, "stats": state.stats, "automation": state.automation,
		"tunnel": {"open": world.tunnel_unlocked, "remaining": ceili(maxf(0.0, tunnel_remaining_sec())), "building": not world.tunnel_contract.is_empty(), "cost": data.balance.tunnel},
		"sites": sites, "upgrades": _upgrade_options(), "huts": _huts_snapshot(), "mining": _mining_snapshot(),
		"hint": next_hint(), "worker_cap": worker_cap(), "last_pull": _last_pull_text(), "garden": _garden_snapshot(),
		"companies": Delivery.companies_view(data, state, float(data.balance.research.TRADE_INTERVAL_SEC) if state.completed_research.get("fastTrade", false)
			else float(data.balance.delivery.TRADE_INTERVAL_SEC)), "multiplier": _multiplier(), "deliveries": Delivery.offers(data, state),
		"reputation": Delivery.reputation(data, state), "village": Village.snapshot(data, state.village), "save_error": _save_error}

func _worker_effective(worker: Dictionary) -> float:
	return float(worker.get("mining", 0)) * float(worker.get("carry", 0)) * float(worker.get("move", 0)) \
		/ float(data.balance.worker.EFFECTIVE_DIVISOR)

func _last_pull_text() -> String:
	var c: Dictionary = state.get("last_pull", {})
	if c.is_empty() or not _tables.rarity.has(c.get("rarity")):
		return ""
	return "방금 뽑음: [%s] %s 담당 (종합 +%.2f/초)" % [_tables.rarity[c.rarity].label, _label(str(c.resource)), _worker_effective(c)]

## The 채굴 tab (web renderBaseInfo, buildMines, buildLines): the base, the found veins and the mining lines.
func _mining_snapshot() -> Dictionary:
	var next := next_expansion_site()
	var base := {"level": world.base_level, "x": world.base.x, "y": world.base.y, "worker_cap": worker_cap(),
		"next": {} if next.is_empty() else {"id": next.key, "name": next.name, "cost": {"gold": next.unlockCost, "products": next.unlockProducts}}}
	var veins: Array = []
	var hidden := 0
	for m: Dictionary in world.mines:
		if not world.is_discovered(m):
			hidden += 1
			continue
		var site: Dictionary = _tables.sites.get(_tables.resources.get(m.resource, {}).get("site", ""), {})
		veins.append({"id": m.id, "resource": m.resource, "name": _label(m.resource), "x": m.x, "y": m.y, "grade": m.grade,
			"power": m.miningPower, "action": vein_action(m.id), "site_name": site.get("name", "지역"),
			"rate": vein_rate(m) * _multiplier(), "haul": float(m.miningPower) * _multiplier()})
	var lines: Array = []
	var rules: Dictionary = data.balance.mining
	for site: Dictionary in data.sites:
		var group := {"id": site.key, "name": site.name, "unlocked": state.unlocked_sites.get(site.key, false) == true,
			"cost": {"gold": site.unlockCost, "products": site.unlockProducts}, "resources": [], "recipes": []}
		for row: Dictionary in data.resources:
			if row.site != site.key:
				continue
			var facility := int(state.facility.get(row.key, 0))
			var workforce := int(state.workforce.get(row.key, 0))
			group.resources.append({"id": row.key, "name": row.name, "amount": float(state.inventory.get(row.key, 0)),
				"auto": auto_rate(row.key), "manual": (float(row.base) + facility) * _multiplier(),
				"facility": {"level": facility, "max": int(rules.FACILITY_MAX_LEVEL), "cost": _level_cost(rules.FACILITY_COST_BASE, rules.FACILITY_COST_GROWTH, facility)},
				"workforce": {"level": workforce, "max": int(rules.WORKFORCE_MAX_LEVEL), "cost": _level_cost(rules.WORKFORCE_COST_BASE, rules.WORKFORCE_COST_GROWTH, workforce)}})
		# web siteRelatedRecipeNames: recipes that use one of the site's raw resources directly.
		for recipe: Dictionary in data.recipes:
			for need: String in recipe.need:
				if _tables.resources.get(need, {}).get("site") == site.key:
					group.recipes.append(recipe.name)
					break
		lines.append(group)
	return {"base": base, "veins": veins, "hidden": hidden, "lines": lines}

## The line under the currencies (web updateNextHint / firstGoalHint / lateGameHint): what to do next.
func next_hint() -> String:
	var on := {}
	for c: Dictionary in state.characters:
		on[c.resource] = true
	var touch := DisplayServer.is_touchscreen_available()
	if not state.first_ticket:
		var progress := "%s/%dG" % [Hud.format_quantity(float(state.gold)), int(data.balance.gacha.FIRST_TICKET_GOLD_THRESHOLD)]
		var steel: Dictionary = _tables.recipes.steel
		var step := ""
		if float(state.inventory.get("steel", 0)) > 0.0 or _has(steel.need):
			step = "공방 앞에서 열기 버튼을 눌러 강철을 만들어 파세요." if touch else "공방 앞에서 E를 눌러 강철을 만들어 파세요."
		else:
			step = "광맥 앞에서 행동 버튼으로 철광석과 석탄을 캐세요." if touch else "광맥 앞에서 E를 눌러 철광석과 석탄을 캐세요."
		return step + " 첫 가챠권까지 " + progress
	if state.characters.size() < int(data.balance.worker.MIN_REQUIRED):
		return "인부 탭에서 가챠권으로 일꾼을 뽑으세요. 자동 제작은 연구 탭의 장치로 열어요." if int(state.tickets) >= 1 \
			else "인부 탭에서 일꾼을 뽑으세요. 일꾼이 있으면 광석을 자동으로 캐 줘요."
	if on.has("iron") != on.has("coal"):
		return "%s은 아직 수동입니다. 일꾼을 한 명 더 뽑으면 강철도 완전 자동화할 수 있어요." % _label("coal" if on.has("iron") else "iron")
	var auto_on: bool = state.completed_research.get("autoCraftDevice", false) == true
	if on.has("iron") and on.has("coal") and state.automation.craft.get("steel", false) != true:
		return "철광석/석탄 자동화 완료! 자동 제작을 켜면 강철도 자동으로 만들어져요." if auto_on \
			else "철광석/석탄 자동화 완료! 연구 탭에서 자동 제작 장치를 연구하면 강철도 자동으로 만들 수 있어요."
	if state.completed_research.get("deliveryContract", false) != true:
		return "연구 탭에서 \"납품 계약\"을 연구하면 회사에 제품을 보내고 명성을 얻을 수 있어요."
	return _late_game_hint()

func _late_game_hint() -> String:
	var order_hint := "납품 탭의 수주를 완수하면 명성을 얻어요. 명성이 오르면 더 많은 회사와 거래할 수 있습니다."
	if Delivery.reputation(data, state) < 1:
		return order_hint
	if state.completed_research.get("workshopBuild", false) != true:
		return "연구 탭의 \"제작소 건설\"로 제작소를 지으면 상위 제품을 따로 만들 수 있어요."
	if world.workshops.is_empty():
		return "제작 탭에서 제작소를 지어 보세요. 레시피를 정해 두면 따로 물건을 만들어 줘요."
	if world.workshops.any(func(w: Dictionary) -> bool: return w.recipeKey == null):
		return "레시피를 정하지 않은 제작소가 있어요. 제작소에 만들 제품을 골라 주세요."
	var short := bottleneck_items()
	if not short.is_empty():
		return "제작소가 재료 때문에 멈춰 있어요. 가장 필요한 재료는 %s입니다. 채굴 탭이나 일꾼 배치를 살펴보세요." % short[0].name
	var site := next_expansion_site()
	if not site.is_empty() and float(state.gold) >= float(site.unlockCost) and _has(site.unlockProducts):
		return "채굴 탭에서 %s을(를) 열 수 있어요. 새 자원으로 더 높은 제품을 만들 수 있습니다." % site.name
	if not world.tunnel_contract.is_empty() and not world.tunnel_unlocked:
		return "터널 공사가 진행 중이에요. 끝나면 산 너머로 갈 수 있습니다. 그동안 다른 일을 해 두세요."
	if state.completed_research.get("tunnelWork", false) == true and not world.tunnel_unlocked:
		return "연구 탭에서 터널 공사를 의뢰할 수 있어요. 산 너머의 희귀한 광맥으로 가는 길이 열립니다."
	if not world.tunnel_unlocked and state.completed_research.get("tunnelWork", false) != true:
		return "연구 탭의 \"터널 굴착\"으로 전문 굴착 업체와 계약하면 산 너머로 가는 길을 뚫을 수 있어요."
	if world.tunnel_unlocked and world.discovered_count() < world.mines.size():
		return "아직 발견하지 못한 광맥이 있어요. 맵을 돌아다니며 찾아보세요."
	return order_hint

## Items the stuck huts lack, most-needed first (web bottleneckReport().items): {id, name, short, huts}.
func bottleneck_items() -> Array:
	var missing := {}
	for hut: Dictionary in world.workshops:
		var st := hut_status(hut)
		for s: Dictionary in st.shortages:
			var m: Dictionary = missing.get(s.id, {"id": s.id, "name": _label(s.id), "short": 0.0, "huts": 0})
			m.short += float(s.need) - float(s.have)
			m.huts += 1
			missing[s.id] = m
	var items: Array = missing.values()
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.huts > b.huts or (a.huts == b.huts and a.short > b.short))
	return items

func is_resource_open(id: String) -> bool:
	var resource: Dictionary = _tables.resources.get(id, {})
	return not resource.is_empty() and bool(state.unlocked_sites.get(resource.site, false))

func mine(id: String) -> bool:
	if not is_resource_open(id):
		return _reject("먼저 채굴 지대를 해금하세요.")
	# The mining tab's button (web mineResource): no relic roll, that comes from mining a vein in the world.
	var amount := (float(_tables.resources[id].base) + float(state.facility.get(id, 0))) * _multiplier()
	_add(id, amount)
	return _updated("%s +%s" % [_label(id), Hud.format_quantity(amount)])

func craft(id: String) -> bool:
	if _hut_only(id):
		return _reject("제작소 전용 레시피예요. 제작소에서 만들어 주세요.")
	if not _start_craft(id):
		return _reject("재료가 부족하거나 제작 중이에요.")
	return _updated("%s %s" % [_label(id), "제작 시작" if state.queue.has(id) else "제작 완료"])

func _start_craft(id: String) -> bool:
	var recipe: Dictionary = _tables.recipes.get(id, {})
	if recipe.is_empty() or _hut_only(id) or state.queue.has(id) or not _has(recipe.need):
		return false
	_consume(recipe.need)
	if float(recipe.craftTime) > 0.0:
		state.queue[id] = float(recipe.craftTime)
	else:
		_add(id, float(recipe.out))
	return true

## Made only in a craft hut. A craft already running on the recipe card (an older save) still finishes.
func _hut_only(id: String) -> bool:
	return WORKSHOP_ONLY_IN_HUTS and _tables.recipes.get(id, {}).get("workshopOnly", false) == true

func sell(id: String) -> bool:
	var earned := _sell(id)
	if earned <= 0.0:
		return _reject("판매할 제품이 없어요.")
	return _updated("%s 판매 +%s G" % [_label(id), _quantity(earned)])

func _sell(id: String) -> float:
	var recipe: Dictionary = _tables.recipes.get(id, {})
	var qty := float(state.inventory.get(id, 0))
	if recipe.is_empty() or qty <= 0.0:
		return 0.0
	var earned := qty * float(recipe.sell) * _multiplier()
	state.inventory[id] = 0
	state.gold += earned
	_check_first_ticket()
	return earned

func hire(id: String) -> bool:
	var balance: Dictionary = data.balance.gacha
	if state.characters.size() >= worker_cap():
		return _reject("인부 정원이 가득 찼어요. 거점을 확장하면 늘어나요.")
	if id == "ticket" and int(state.tickets) >= int(balance.PULL_COST_TICKET):
		state.tickets -= int(balance.PULL_COST_TICKET)
	elif id == "gold" and float(state.gold) >= float(balance.PULL_COST_GOLD):
		state.gold -= float(balance.PULL_COST_GOLD)
	else:
		return _reject("골드나 가챠권이 부족해요.")
	var roll := randf() * 100.0
	var rarity: Dictionary = data.rarity[0]
	for row: Dictionary in data.rarity:
		roll -= float(row.chance)
		if roll <= 0.0:
			rarity = row
			break
	var available: Array = []
	for row: Dictionary in data.resources:
		if is_resource_open(row.key):
			available.append(row.key)
	var resource_id: String = available.pick_random()
	var taken := {}
	for c: Dictionary in state.characters:
		taken[c.id] = true
	var worker := {"id": _entity_id("w_", taken), "rarity": rarity.key, "resource": resource_id,
		"mining": rarity.mining, "carry": rarity.carry, "move": rarity.move, "miningLvl": 0, "carryLvl": 0, "moveLvl": 0}
	state.characters.append(worker)
	state["last_pull"] = worker.duplicate()
	_check_dual_automation()
	return _updated("%s 인부 고용 · %s 배치" % [rarity.label, _label(resource_id)])

## Workers the base holds: CAP_BASE + CAP_PER_BASE_LEVEL per base level above 1 (web workerCap).
func worker_cap() -> int:
	var rules: Dictionary = data.balance.worker
	return int(rules.CAP_BASE) + int(rules.CAP_PER_BASE_LEVEL) * maxi(0, world.base_level - 1)

## A worker stat upgrade: mining, carry or move +1 for gold, at most STAT_MAX_LEVEL times (web upgradeWorkerStat).
func worker_upgrade_cost(worker: Dictionary, stat: String) -> int:
	var rules: Dictionary = data.balance.worker
	return _level_cost(float(rules.STAT_COST_BASE[stat]), float(rules.STAT_COST_GROWTH), int(worker.get(stat + "Lvl", 0)))

func upgrade_worker(worker_id: String, stat: String) -> bool:
	if stat not in ["mining", "carry", "move"]:
		return false
	for index in state.characters.size():
		var worker: Dictionary = state.characters[index]
		if worker.id != worker_id:
			continue
		if int(worker.get(stat + "Lvl", 0)) >= int(data.balance.worker.STAT_MAX_LEVEL):
			return _reject("이미 최대로 강화했어요.")
		if not _pay({"gold": worker_upgrade_cost(worker, stat)}):
			return _reject("강화할 골드가 부족해요.")
		worker[stat] = float(worker[stat]) + float(data.balance.worker.STAT_INCREMENT_PER_UPGRADE)
		worker[stat + "Lvl"] = int(worker.get(stat + "Lvl", 0)) + 1
		var label: String = data.stat_label.get(stat, stat)
		return _updated("일꾼 강화 · #%d %s Lv.%d" % [index + 1, label, worker[stat + "Lvl"]])
	return false

## The first time iron and coal both have a worker (web checkDualAutomation): said once.
func _check_dual_automation() -> void:
	if state.get("auto_line_logged", false):
		return
	var on := {}
	for c: Dictionary in state.characters:
		on[c.resource] = true
	if on.has("iron") and on.has("coal"):
		state["auto_line_logged"] = true
		feedback.emit("철광석/석탄 자동화 완료! 연구 탭의 자동 제작 장치로 강철 생산도 자동화할 수 있어요.")

## web makeEntityId: prefix, the time in base 36 and six random base-36 characters.
func _entity_id(prefix: String, taken: Dictionary) -> String:
	return CraftHuts.new_id(taken, prefix)

func assign_worker(worker_id: String, resource_id: String) -> bool:
	if not is_resource_open(resource_id):
		return _reject("먼저 채굴 지대를 해금하세요.")
	for worker: Dictionary in state.characters:
		if worker.id == worker_id:
			worker.resource = resource_id
			return _updated("인부 배치 · " + _label(resource_id))
	return false

func unlock(id: String) -> bool:
	var row: Dictionary = _tables.research.get(id, {})
	if row.is_empty() or state.completed_research.get(id, false):
		return false
	for required: String in row.requires:
		if not state.completed_research.get(required, false):
			return _reject("선행 연구가 필요해요.")
	if not _pay(_research_cost(row)):
		return _reject("연구 비용이 부족해요.")
	state.completed_research[id] = true
	if id == "explorationGear":
		world.exploration_gear = true
	elif id == "geologicalSurvey":
		world.run_survey()
	_record_world()
	return _updated("연구 완료 · " + row.name)

func _research_cost(row: Dictionary) -> Dictionary:
	var cost: Dictionary = row.cost.duplicate()
	var discount := Village.research_discount(data, state.village)
	cost.gold = ceili(float(cost.get("gold", 0)) * (100 - discount) / 100.0)
	return cost

func restore_facility(id: String) -> bool:
	# web villageRestoreBlocker: a facility needs its site first (laid out now if it was not yet).
	if not state.village.sites.get(id) is Dictionary:
		_ensure_village()
		if not state.village.sites.get(id) is Dictionary:
			return _reject("자리를 찾는 중이에요.")
	var step := Village.next_stage(data, state.village, id)
	if step.is_empty():
		return _reject("선행 복구가 필요하거나 이미 운영 중이에요.")
	if not _pay(step.cost):
		return _reject("시설 복구 비용이 부족해요.")
	state.village.stage[id] = int(state.village.stage.get(id, 0)) + 1
	return _updated("%s · %s 완료" % [data.village.FACILITIES[id].name, step.name])

func appraise_relic(_id: String) -> bool:
	var relic := Village.appraise(data, state.village)
	if relic.is_empty():
		return _reject("감정소 복구 상태와 유물 수를 확인하세요.")
	return _updated("유물 감정 · " + relic.name)

func donate_relic(id: String) -> bool:
	var village: Dictionary = state.village
	if not Village.is_open(data, village, "museum") or id in village.donated or int(village.owned.get(id, 0)) <= 0:
		return _reject("기증할 새 유물이 없어요.")
	for relic: Dictionary in data.village_relics:
		if relic.key == id:
			village.owned[id] -= 1
			village.donated.append(id)
			return _updated("박물관 기증 · " + relic.name)
	return false

## Donates every relic the museum does not show yet (web villageDonateAll). Returns how many.
func donate_all_relics(_id := "") -> int:
	var count := 0
	for relic: Dictionary in data.village_relics:
		var village: Dictionary = state.village
		if Village.is_open(data, village, "museum") and relic.key not in village.donated and int(village.owned.get(relic.key, 0)) > 0:
			if donate_relic(relic.key):
				count += 1
	return count

# --- the village in the world (web villageTargetFor, garden, house) -------------------------------------------

## What walking up to a facility's door offers (web villageTargetFor): {action, label}.
func village_target(key: String) -> Dictionary:
	var facility: Dictionary = data.village.FACILITIES[key]
	var name: String = facility.name
	var village: Dictionary = state.village
	if not Village.is_open(data, village, key):
		var needs: Variant = facility.get("requires")
		if needs is String and not Village.is_open(data, village, needs):
			return {"action": "locked", "label": "%s · %s 먼저 복구" % [name, data.village.FACILITIES[needs].name]}
		var step := Village.next_stage(data, village, key)
		return {"action": "restore", "label": "%s %s · %s" % [name, step.name, _cost_label(step.cost)]}
	if key == "appraiser":
		var n := int(village.unidentified)
		return {"action": "appraise", "label": "%s · 유물 감정 (미감정 %d)" % [name, n]} if n > 0 else {"action": "open", "label": name + " · 감정할 유물 없음"}
	if key == "museum":
		var donatable := 0
		for relic: Dictionary in data.village_relics:
			if relic.key not in village.donated and int(village.owned.get(relic.key, 0)) > 0:
				donatable += 1
		if donatable > 0:
			return {"action": "donate", "label": "%s · 유물 기증 (%d점)" % [name, donatable]}
		return {"action": "open", "label": "%s · 전시 %d/%d · 광물·보석 %d/%d" % [name, village.donated.size(), data.village_relics.size(),
			Village.specimen_keys(village).size(), data.village_specimens.size()]}
	return {"action": "open", "label": name}

func _cost_label(cost: Dictionary) -> String:
	var parts := PackedStringArray(["%sG" % Hud.format_quantity(float(cost.get("gold", 0)))])
	var products: Dictionary = cost.get("products", {})
	for k: String in products:
		parts.append("%s %d개" % [_label(k), int(products[k])])
	return " + ".join(parts)

## Garden UI state, not saved (web VILLAGE_GARDEN_UI): the kind to set down and the cell being carried.
var garden_ui := {"selected": "flowerPot", "carry": -1}

func decor_unlocked(kind: String) -> bool:
	var d := VillageLayout.decor_def(kind)
	if d.is_empty():
		return false
	if not d.get("reward", false):
		return true
	var collected := int(state.village.donated.size()) + Village.specimen_keys(state.village).size()
	for r: Dictionary in data.village_museum_rewards:
		if r.get("decor") == kind and collected >= int(r.need):
			return true
	return false

func decor_selected() -> String:
	if not decor_unlocked(str(garden_ui.selected)):
		garden_ui.selected = data.village.DECOR[0].key
	return garden_ui.selected

## The unlocked decoration kind after the selected one (web villageDecorNext).
func decor_next() -> String:
	var keys: Array = []
	for d: Dictionary in data.village.DECOR:
		if decor_unlocked(d.key):
			keys.append(d.key)
	return keys[(keys.find(decor_selected()) + 1) % keys.size()]

## Selects the next unlocked decoration kind (web villageDecorCycle, Q).
func decor_cycle(_id := "") -> String:
	garden_ui.selected = decor_next()
	changed.emit()
	return garden_ui.selected

func decor_select(kind: String) -> bool:
	if not decor_unlocked(kind):
		return false
	garden_ui.selected = kind
	changed.emit()
	return true

func _decor_index(cell: int) -> int:
	var list: Array = state.village.decor
	for i in list.size():
		if int(list[i].cell) == cell:
			return i
	return -1

## Why a decoration of `kind` cannot stand on `cell` (web villageDecorPlaceProblem), or "". `from` is the cell it
## is moved from; `player` the player's feet (world units); `quick` skips the reach check.
func decor_problem(kind: String, cell: int, from := -1, player := Vector2(INF, INF), quick := false) -> String:
	var G: Dictionary = data.village.GARDEN
	var village: Dictionary = state.village
	var cells := VillageLayout.garden_cells(village)
	if cells.is_empty():
		return "정원 자리가 아직 없어요"
	if VillageLayout.decor_def(kind).is_empty():
		return "알 수 없는 장식"
	if not decor_unlocked(kind):
		return "아직 해금되지 않은 장식이에요"
	if cell < 0 or cell >= cells.size():
		return "정원 칸이 아니에요"
	if _decor_index(cell) >= 0 and cell != from:
		return "이미 장식이 있어요"
	var box := VillageLayout.decor_box(village, kind, cell)
	var here: Dictionary = cells[cell]
	if is_finite(player.x) and VillageLayout.foot_overlaps(box, player.x, player.y):
		return "서 있는 자리에는 놓을 수 없어요"
	var parts := VillageLayout.district_parts(village.district)
	var doors: Array = [{"x": float(world.base.x), "y": float(world.base.y)}, parts.house]
	for k: String in VillageLayout.ORDER:
		if village.sites.get(k) is Dictionary:
			doors.append(village.sites[k])
	for d: Dictionary in doors:
		if Vector2(d.x, d.y).distance_to(Vector2(here.x, here.y)) < G.DOOR_CLEAR:
			return "문 앞은 비워 둘게요"
	for road: Dictionary in village_roads():
		if VillageLayout.seg_poly_dist(road.points, here.x, here.y) < data.village.DISTRICT.ROAD_HALF + G.ROAD_CLEAR:
			return "길은 비워 둘게요"
	for t: Dictionary in world.torches:
		if VillageLayout.rect_dist(box, t.x, t.y) < 0.12:
			return "횃불이 있는 칸이에요"
	if quick:
		return ""
	var g: Dictionary = parts.garden
	var pz: Dictionary = parts.plaza
	var h: Dictionary = parts.house
	var m := 1.2
	var index := VillageLayout.Index.new(VillageLayout.obstacles(world, village, int(garden_ui.carry)))
	var reach := VillageLayout.reach_area(index, world.tunnel_unlocked,
		minf(minf(g.x - g.hw, pz.x - pz.r), h.x - 0.5) - m, minf(minf(g.y - g.hh, pz.y - pz.r), h.y - 0.5) - m,
		maxf(maxf(g.x + g.hw, pz.x + pz.r), h.x + 0.5) + m, maxf(maxf(g.y + g.hh, pz.y + pz.r), h.y + 0.5) + m, {"x": pz.x, "y": pz.y})
	if not reach.call([box], [{"x": h.x, "y": h.y + 0.1}]):
		return "길이 막히는 자리예요"
	return ""

func decor_place(kind: String, cell: int, player := Vector2(INF, INF)) -> bool:
	var why := decor_problem(kind, cell, -1, player)
	if not why.is_empty():
		return _reject(why)
	state.village.decor.append({"kind": kind, "cell": cell})
	return _updated(VillageLayout.decor_def(kind).name + " 놓기!")

func decor_move(from: int, to: int, player := Vector2(INF, INF)) -> bool:
	var i := _decor_index(from)
	if i < 0:
		return _reject("들고 있는 장식이 없어요")
	if from == to:
		return true
	var list: Array = state.village.decor
	var kind := str(list[i].kind)
	list.remove_at(i)
	var why := decor_problem(kind, to, from, player)
	list.insert(i, {"kind": kind, "cell": from if not why.is_empty() else to})
	if not why.is_empty():
		return _reject(why)
	return _updated("옮겼어요")

func decor_remove(cell: int) -> String:
	var i := _decor_index(cell)
	if i < 0:
		return ""
	var kind := str(state.village.decor[i].kind)
	state.village.decor.remove_at(i)
	if int(garden_ui.carry) == cell:
		garden_ui.carry = -1
	_updated(VillageLayout.decor_def(kind).name + " 회수")
	return kind

## The 마을 tab's garden and museum rewards (web villageGardenCard, villageRewardSection).
func _garden_snapshot() -> Dictionary:
	var kinds: Array = []
	for d: Dictionary in data.village.DECOR:
		kinds.append({"id": d.key, "name": d.name, "desc": d.desc, "unlocked": decor_unlocked(d.key), "selected": d.key == decor_selected()})
	var collected := int(state.village.donated.size()) + Village.specimen_keys(state.village).size()
	var rewards: Array = []
	for r: Dictionary in data.village_museum_rewards:
		rewards.append({"need": r.need, "name": r.name, "earned": collected >= int(r.need)})
	return {"has_garden": state.village.get("district") is Dictionary, "placed": state.village.decor.size(),
		"cells": int(data.village.GARDEN.COLS) * int(data.village.GARDEN.ROWS), "kinds": kinds, "collected": collected,
		"total": data.village_relics.size() + data.village_specimens.size(), "rewards": rewards}

var _roads_key := ""
var _roads: Array = []

## What the village roads depend on: the district, the facility sites, the veins, the huts and the tunnel.
func _village_key() -> String:
	var huts := PackedStringArray()
	for w: Dictionary in world.workshops:
		huts.append("%d,%d" % [int(w.x), int(w.y)])
	return "%s|%s|%d|%s|%s" % [JSON.stringify(state.village.get("district")), JSON.stringify(state.village.get("sites")),
		world.mines.size(), ";".join(huts), world.tunnel_unlocked]

## The village roads now, worked out again only when what they depend on changed (web villageRoads cache).
func village_roads() -> Array:
	var key := _village_key()
	if key != _roads_key:
		_roads_key = key
		_roads = VillageLayout.roads(world, state.village)
	return _roads

# --- torches (web player.js torchAct) --------------------------------------------------------------------------

## Picks up the torch at hand or sets one down in front of the player. `feet` in world units, `facing` up/down/
## left/right. Returns {ok, text}.
func torch_act(feet: Vector2, facing: String) -> Dictionary:
	# Vector2 holds 32-bit floats: the spot is worked out in doubles so it is saved like the web's (3.56, not 3.5599999).
	var T: Dictionary = data.torch
	var v: Array = {"up": [0.0, -1.0], "down": [0.0, 1.0], "left": [-1.0, 0.0], "right": [1.0, 0.0]}.get(facing, [0.0, 1.0])
	var fx := _js_hundredths(feet.x)
	var fy := _js_hundredths(feet.y)
	var sx := VillageLayout._round((fx + v[0] * float(T.AHEAD)) * 100.0) / 100.0
	var sy := VillageLayout._round((fy + v[1] * float(T.AHEAD)) * 100.0) / 100.0
	var near := _nearest_torch(sx, sy, float(T.PICK_AHEAD))
	if near < 0:
		near = _nearest_torch(fx, fy, float(T.PICK_UNDER))
	if near >= 0:
		world.torches.remove_at(near)
		_village_try_key = ""
		_record_world()
		_updated("횃불을 거뒀어요")
		return {"ok": true, "text": "횃불을 거뒀어요"}
	var why := torch_problem(sx, sy)
	if not why.is_empty():
		feedback.emit(why)
		return {"ok": false, "text": why}
	world.torches.append({"x": sx, "y": sy})
	_record_world()
	_updated("횃불을 놓았어요")
	return {"ok": true, "text": "횃불을 놓았어요"}

## A player position (a 32-bit Vector2 component) as the double nearest its value to 1e-6, so a position like
## 228 / 64 = 3.5625 stays exact and a 32-bit rounding error does not reach the torch spot.
func _js_hundredths(v: float) -> float:
	return VillageLayout._round(v * 1e6) / 1e6

func _nearest_torch(x: float, y: float, reach: float) -> int:
	var best := -1
	var best_d := reach
	for i in world.torches.size():
		var d := VillageLayout._hypot(float(world.torches[i].x) - x, float(world.torches[i].y) - y)
		if d <= best_d:
			best = i
			best_d = d
	return best

## Why a torch cannot go at `at` (web torchPlaceProblem), or "".
func torch_problem(x: float, y: float) -> String:
	var T: Dictionary = data.torch
	if world.torches.size() >= int(T.MAX):
		return "횃불은 %d개까지 놓을 수 있어요" % int(T.MAX)
	if not WorldTerrainScript.is_point_walkable(x, y, world.tunnel_unlocked):
		return "여기에는 놓을 수 없어요"
	for m: Dictionary in world.mines:
		if VillageLayout._hypot(float(m.x) - x, float(m.y) - y) < T.MINE_CLEAR:
			return "광맥과 너무 가까워요"
	var doors: Array = [[float(world.base.x), float(world.base.y)]]
	for w: Dictionary in world.workshops:
		doors.append([float(w.x), float(w.y)])
	for d: Array in doors:
		if VillageLayout._hypot(d[0] - x, d[1] - y) < T.DOOR_CLEAR:
			return "문 앞은 비워 둘게요"
	var r: float = T.ROOM
	for o: Dictionary in VillageLayout.obstacles(world, state.village, int(garden_ui.carry)):
		if x > o.minX - r and x < o.maxX + r and y > o.minY - r and y < o.maxY + r:
			return "건물이나 바위에 너무 가까워요"
	for t: Dictionary in world.torches:
		if VillageLayout._hypot(float(t.x) - x, float(t.y) - y) < T.GAP:
			return "횃불끼리 너무 가까워요"
	return ""

func donate_specimen(id: String) -> bool:
	var village: Dictionary = state.village
	if not Village.is_open(data, village, "museum") or id in Village.specimen_keys(village):
		return false
	for specimen: Dictionary in data.village_specimens:
		if specimen.key == id and _pay({"products": {id: specimen.qty}}):
			village.specimens.append({"key": id, "at": int(Time.get_unix_time_from_system() * 1000)})
			return _updated("박물관 기증 · " + _label(id))
	return _reject("기증할 표본 수가 부족해요.")

func open_site(id: String) -> bool:
	var row: Dictionary = _tables.sites.get(id, {})
	if row.is_empty() or state.unlocked_sites.get(id, false):
		return false
	if not _pay({"gold": row.unlockCost, "products": row.unlockProducts}):
		return _reject("채굴 지대 해금 비용이 부족해요.")
	state.unlocked_sites[id] = true
	_seed_site_veins(id)
	return _updated("채굴 지대 해금 · " + row.name)

## The site's seed veins next to the base, where no vein stands yet (web seedWorldMinesForSite).
func _seed_site_veins(site: String) -> void:
	world.seed_site(site, data.world_mine_seeds.get(site, []))
	_record_world()

## The next area in EXPANSION_SITE_ORDER, or {} when every area is open.
func next_expansion_site() -> Dictionary:
	for key in data.balance.world.EXPANSION_SITE_ORDER:
		if not state.unlocked_sites.get(key, false):
			return _tables.sites.get(key, {})
	return {}

## Expands the base: opens the next area and raises the base level, which makes room for more workers
## (web expandBase).
func expand_base(_id := "") -> bool:
	var site := next_expansion_site()
	if site.is_empty():
		return false
	if not open_site(str(site.key)):
		return false
	world.base_level += 1
	_record_world()
	return _updated("거점 확장 Lv.%d" % world.base_level)

func upgrade(id: String) -> bool:
	var option := _upgrade_option(id)
	if option.is_empty() or option.level >= option.limit:
		return false
	if not _pay(option.cost):
		return _reject("강화 비용이 부족해요.")
	var field: String = option.field
	var resource: String = option.get("resource", "")
	if resource.is_empty():
		state[field] += 1
	else:
		state[field][resource] = int(state[field].get(resource, 0)) + 1
	return _updated("%s Lv.%d" % [option.name, int(option.level) + 1])

func _upgrade_options() -> Array:
	var options := [_upgrade_option("hq_level"), _upgrade_option("craft_facility")]
	for resource: Dictionary in data.resources:
		if is_resource_open(resource.key):
			options.append(_upgrade_option("facility:" + str(resource.key)))
			options.append(_upgrade_option("workforce:" + str(resource.key)))
	return options

func _upgrade_option(id: String) -> Dictionary:
	if id == "hq_level":
		var rules: Dictionary = data.balance.hq
		var level := int(state.hq_level)
		return {"id": id, "field": id, "name": "본사 투자", "level": level, "limit": int(rules.MAX_LEVEL),
			"cost": {"gold": _level_cost(rules.COST_BASE, rules.COST_GROWTH, level)}}
	if id == "craft_facility":
		var rules: Dictionary = data.balance.crafting
		var level := int(state.craft_facility)
		return {"id": id, "field": id, "name": "제작 시설 강화", "level": level, "limit": int(rules.FACILITY_MAX_LEVEL),
			"cost": {"gold": _level_cost(rules.FACILITY_COST_BASE, rules.FACILITY_COST_GROWTH, level - 1)}}
	var parts := id.split(":", false, 1)
	if parts.size() != 2 or parts[0] not in ["facility", "workforce"] or not is_resource_open(parts[1]):
		return {}
	var field := parts[0]
	var resource := parts[1]
	var prefix := field.to_upper()
	var level := int(state[field].get(resource, 0))
	var rules: Dictionary = data.balance.mining
	var name := _label(resource) + (" 도구 강화" if field == "facility" else " 인력 강화")
	return {"id": id, "field": field, "resource": resource, "name": name, "level": level, "limit": int(rules[prefix + "_MAX_LEVEL"]),
		"cost": {"products": {resource: _level_cost(rules[prefix + "_COST_BASE"], rules[prefix + "_COST_GROWTH"], level)}}}

func _level_cost(base: float, growth: float, level: int) -> int:
	return roundi(base * pow(growth, maxi(0, level)))

func set_auto_craft(id: String, enabled: bool) -> bool:
	if not _tables.recipes.has(id) or not state.completed_research.get("autoCraftDevice", false):
		return _reject("자동 제작 장치 연구가 필요해요.")
	if enabled and _hut_only(id):
		return _reject("제작소 전용 레시피는 제작소에서 자동 제작을 켜 주세요.")
	state.automation.craft[id] = enabled
	return _updated()

func set_craft_target(id: String, value: int) -> bool:
	if not _tables.recipes.has(id):
		return false
	state.automation.target[id] = clampi(value, 0, 999999)
	return _updated()

func buy_auto_sell(id: String) -> bool:
	var row: Dictionary = _tables.recipes.get(id, {})
	if row.is_empty() or row.get("workshopOnly", false) or state.automation.sell_owned.get(id, false):
		return false
	if not _pay({"gold": _auto_sell_cost(row)}):
		return _reject("자동 판매를 구매할 골드가 부족해요.")
	state.automation.sell_owned[id] = true
	state.automation.sell[id] = true
	return _updated("자동 판매 구매 · " + row.name)

func set_auto_sell(id: String, enabled: bool) -> bool:
	if not state.automation.sell_owned.get(id, false):
		return false
	state.automation.sell[id] = enabled
	return _updated()

## Free delivery of `qty` of a product to a company (web deliverProducts): pays shipping, adds score.
func ship_free(company_id: String, product: String, qty: int) -> bool:
	var result := Delivery.ship(data, state, company_id, product, qty)
	if not result.get("ok", false):
		return _reject(result.get("message", "납품할 수 없어요."))
	_check_first_ticket()
	return _updated(result.get("message", "납품 완료"))

func delivery_preview(company_id: String, product: String, qty: int) -> Dictionary:
	return Delivery.preview(data, state, company_id, product, qty)

func deliver(id: String) -> bool:
	var result := Delivery.complete(data, state, id)
	if not result.get("ok", false):
		return _reject(result.get("message", "납품할 수 없어요."))
	_check_first_ticket()
	return _updated(result.get("message", "납품 완료"))

## Pasted text. A web save's original is kept as the pasted text's UTF-8 bytes: copying through the
## clipboard or a text field can already have changed it (CRLF line endings, for one). A file import
## (import_save_bytes) keeps the file's exact bytes.
func import_save(json_text: String) -> bool:
	return _import(json_text, PackedByteArray(), "paste")

## A save file's exact bytes (desktop file dialog, or the browser's file picker).
func import_save_bytes(bytes: PackedByteArray) -> bool:
	var text := Save.utf8_text(bytes)
	if text.is_empty():
		return _reject("저장 파일이 UTF-8 텍스트가 아니에요.")
	return _import(text, bytes, "file")

## Opens the browser's file picker; the chosen file's bytes are imported unchanged.
func request_import_file() -> bool:
	if not OS.has_feature("web") or _web_api == null:
		return false
	_web_api.pickFile(_web_callback(_on_import_file))
	return true

func _on_import_file(args: Array) -> void:
	var encoded := str(args[0]) if args.size() > 0 else ""
	if encoded.is_empty():
		_reject("파일을 가져오지 않았어요.")
		return
	import_save_bytes(Marshalls.base64_to_raw(encoded))

## The imported web save's original bytes, exactly as imported, or empty if there is none or it is damaged.
func legacy_original_bytes() -> PackedByteArray:
	var original := Save.legacy_original(state)
	return original.bytes if original.status == "ok" else PackedByteArray()

## "none" | "ok" | "corrupt" | "conflict" | "copy_only" (see Save.legacy_status), with its origin.
func legacy_original_info() -> Dictionary:
	var original := Save.legacy_original(state)
	return {"status": Save.legacy_status(state), "origin": original.origin,
		"sha256": str(state.get(Save.LEGACY_SHA256, "")), "size": original.bytes.size()}

## Web: downloads the original web save file unchanged.
func download_legacy_original() -> bool:
	var bytes := legacy_original_bytes()
	if bytes.is_empty() or not OS.has_feature("web"):
		return false
	JavaScriptBridge.download_buffer(bytes, "mining-workshop-js-original-%s.json" % str(state.get(Save.LEGACY_SHA256, "")).left(12), "application/json")
	return true

func _import(json_text: String, bytes: PackedByteArray, origin: String) -> bool:
	if not _web_operation.is_empty():
		return _reject("저장 확인 중이에요. 잠시 후 다시 시도해 주세요.")
	var imported := Save.import_text(json_text, bytes, origin)
	if imported.is_empty() or not _valid_save_state(imported):
		return _reject("저장 JSON 형식이나 버전을 확인해 주세요.")
	if is_protected():
		# Replacing a protected save is only allowed after its original was exported, and keeps it.
		if not _protected_exported:
			return _reject("기존 저장을 보호하는 중이에요. 먼저 원본 저장을 내보내 주세요.")
		return set_aside_protected(imported)
	if _save_blocked and persistence_enabled:
		return _reject("지금은 저장할 수 없어서 가져오기를 적용하지 않았어요. 저장 상태를 먼저 확인해 주세요.")
	var old_state := state
	var old_world := world
	# Normalize the candidate with the same rules as an on-disk save.
	_restore(imported)
	var candidate := state
	state = old_state
	world = old_world
	World.set_current(world)
	if persistence_enabled and OS.has_feature("web"):
		_web_candidate = candidate
		# The replaced save is kept under WEB_IMPORT_BACKUP in the same transaction.
		return _start_web_commit("import", candidate, _web_revision, {"backupKey": WEB_IMPORT_BACKUP})
	if persistence_enabled and Save.save_game(candidate) != OK:
		_report_save_failure("write")
		return _reject("가져온 데이터를 저장하지 못해서 적용하지 않았어요. 기존 저장은 그대로예요.")
	_apply_import(candidate)
	return true

func _apply_import(candidate: Dictionary, message := "저장 불러오기 완료") -> void:
	_restore(candidate)
	_dirty = false
	_dirty_gameplay = false
	_dirty_shown = false
	if persistence_enabled:
		_set_save_status(_saved_status())
	world_replaced.emit()
	changed.emit()
	feedback.emit(message)

func export_save() -> String:
	_record_world()
	_record_position()
	return Save.export_game(state)

func _saved_status() -> String:
	return "saved_basic" if save_durability == "basic" else "saved"

func _start_web_commit(operation: String, payload: Dictionary, expected: String, options := {}) -> bool:
	var text := Save.export_game(payload)
	if text.is_empty() or _web_api == null:
		_web_candidate = {}
		_report_save_failure("export" if text.is_empty() else "no-api")
		return false
	_web_operation = operation
	if operation in ["import", "set_aside"]:
		_set_save_status("importing")
	elif save_status not in ["failed", "quota"]:
		_set_save_status("saving")
	if not _migrated_from.is_empty():
		options["migratedFrom"] = _migrated_from
	var revision := Crypto.new().generate_random_bytes(16).hex_encode()
	_web_api.commit(expected, revision, text, JSON.stringify(options), _web_callback(_on_web_commit))
	return true

func _on_web_commit(args: Array) -> void:
	var operation := _web_operation
	if operation not in ["autosave", "import", "set_aside"]:
		return
	_web_operation = ""
	var status := str(args[0])
	var candidate := _web_candidate
	_web_candidate = {}
	if status == "saved":
		_web_revision = str(args[1])
		save_durability = "strict" if str(args[2]) == "strict" else "basic"
		_save_error = OK
		_retry_count = 0
		_retry_at = 0.0
		_last_commit_at = _now()
		_migrated_from = ""
		if operation == "import":
			_apply_import(candidate)
		elif operation == "set_aside":
			_clear_protected()
			_choice_pending = false
			_offline = false
			_save_blocked = false
			_apply_import(candidate, "원본 저장은 브라우저에 따로 보관했어요. 새 저장을 시작했어요.")
		else:
			_record_position()
			# Saved unless a player action or move came after this snapshot; what the game produced by
			# itself since then goes out with the next regular autosave.
			_set_save_status("pending" if _dirty_shown else _saved_status())
	else:
		if operation == "autosave":
			_dirty = true
			_dirty_gameplay = _dirty_gameplay or bool(_web_candidate_gameplay)
			_dirty_shown = _dirty_shown or _web_candidate_shown
		match status:
			"conflict":
				_save_blocked = true
				_save_error = ERR_BUSY
				_enter_choice("conflict")
				if operation == "set_aside":
					# Something else changed the slot: keep protecting what we saw.
					_set_save_status("conflict")
			"quota":
				_report_save_failure("quota", str(args[3]) if args.size() > 3 else "")
			_:
				_report_save_failure("write", str(args[3]) if args.size() > 3 else "")
		if operation in ["import", "set_aside"]:
			feedback.emit("가져온 데이터가 저장되지 않아 적용하지 않았어요. 기존 저장은 그대로예요.")
			if operation == "set_aside" and status != "conflict":
				_enter_choice("protected", _protected_reason)
	_web_candidate_gameplay = false
	_web_candidate_shown = false
	if _flush_after_operation:
		_flush_after_operation = false
		flush(true)


## Failed writes are retried later with a growing pause; the last saved record stays as it was.
func _report_save_failure(kind: String, detail := "") -> void:
	if _save_error == OK:
		feedback.emit("저장 공간이 부족해요. 저장 탭에서 JSON을 백업해 주세요." if kind == "quota" else "자동 저장에 실패했어요. 저장 탭에서 JSON을 백업할 수 있어요.")
	_save_error = ERR_OUT_OF_MEMORY if kind == "quota" else ERR_FILE_CANT_WRITE
	var delays: Array = QUOTA_RETRY_DELAYS if kind == "quota" else FAILURE_RETRY_DELAYS
	_retry_at = _now() + float(delays[mini(_retry_count, delays.size() - 1)])
	_retry_count += 1
	_set_save_status("quota" if kind == "quota" else "failed", detail)

## Saves when something changed. Walking alone is saved at most every POSITION_SAVE_INTERVAL seconds;
## `force` (page hidden, window closing, the retry button) saves now.
func flush(force := false) -> void:
	if not persistence_enabled or data.is_empty() or _save_blocked or _choice_pending:
		return
	if not _web_operation.is_empty():
		if force:
			_flush_after_operation = true
		return
	_record_world(true)
	_record_position()
	if not _dirty:
		return
	var now := _now()
	if not force and now < _retry_at:
		return
	if not force and not _dirty_gameplay and now - _last_commit_at < POSITION_SAVE_INTERVAL:
		return
	if OS.has_feature("web"):
		# Changes made while this transaction runs get their own snapshot.
		_web_candidate_gameplay = _dirty_gameplay
		_web_candidate_shown = _dirty_shown
		_dirty = false
		_dirty_gameplay = false
		_dirty_shown = false
		if not _start_web_commit("autosave", state, _web_revision):
			_dirty = true
			_dirty_gameplay = _web_candidate_gameplay
			_dirty_shown = _web_candidate_shown
		return
	var result := Save.save_game(state)
	if result == OK:
		_save_error = OK
		_retry_count = 0
		_retry_at = 0.0
		_dirty = false
		_dirty_gameplay = false
		_dirty_shown = false
		_last_commit_at = now
		_set_save_status("saved")
	else:
		_report_save_failure("write", error_string(result))

func _process(delta: float) -> void:
	if input_frozen():
		return
	_record_position()
	_elapsed += minf(delta, 0.5)
	_save_elapsed += delta
	var mutated := false
	while _elapsed >= TICK:
		_elapsed -= TICK
		mutated = _tick() or mutated
	if mutated:
		# Produced by the game itself: written by the regular autosave, not shown as waiting.
		_mark_dirty(false, true)
		changed.emit()
	if _save_elapsed >= AUTOSAVE_INTERVAL:
		_save_elapsed = 0.0
		flush()

func _tick() -> bool:
	var mutated := _ensure_village()
	# web tickStep runs the tunnel job last; it only reads the clock, so its place does not matter.
	if not world.tunnel_contract.is_empty():
		mutated = _tick_tunnel() or mutated
	# The original runs ticketTrickle on a fixed 45 s interval from page start and grants nothing until
	# the first-ticket milestone (firstGachaGranted). The clock keeps running before the milestone.
	state.ticket_elapsed += TICK
	var ticket_interval := float(data.balance.gacha.TICKET_TRICKLE_MS) / 1000.0
	if state.ticket_elapsed >= ticket_interval - TICKET_EPSILON:
		state.ticket_elapsed = maxf(0.0, float(state.ticket_elapsed) - ticket_interval)
		if state.first_ticket:
			state.tickets += 1
			mutated = true
	# web tickMining: every resource's autoRate (workers, workforce, secured veins, times the multiplier),
	# added as rate / TICKS_PER_SECOND.
	for row: Dictionary in data.resources:
		var rate := auto_rate(str(row.key))
		if rate > 0.0:
			_add(str(row.key), rate / TICKS_PER_SECOND)
			mutated = true
	var speed := (1.0 + maxf(0.0, float(state.craft_facility) - 1.0) * float(data.balance.crafting.FACILITY_SPEED_PER_LEVEL)) \
		* (1.0 + Delivery.reputation_effect(data, state, "craftSpeed"))
	# web tickCrafting, recipe by recipe: a running craft counts down by speed / TICKS_PER_SECOND and finishes
	# at 0 or below; otherwise its automation may start one (not in the tick a craft finished).
	var auto_unlocked: bool = state.completed_research.get("autoCraftDevice", false) == true
	for row: Dictionary in data.recipes:
		var id := str(row.key)
		if state.queue.has(id):
			state.queue[id] = float(state.queue[id]) - speed / TICKS_PER_SECOND
			if state.queue[id] <= 0.0:
				state.queue.erase(id)
				_add(id, float(row.out))
			mutated = true
		elif state.automation.craft.get(id, false) == true and auto_unlocked and not row.get("workshopOnly", false) \
				and not _at_craft_target(id):
			mutated = _start_craft(id) or mutated
	# The web tickStep order: recipe cards, the huts, regular trade, orders, then auto-sell.
	mutated = _tick_huts() or mutated
	var delivery := Delivery.tick(data, state, TICK, _multiplier())
	for message: String in delivery.get("messages", []):
		feedback.emit(message)
	for row: Dictionary in data.recipes:
		var id := str(row.key)
		# Original canAutoSell: only recipes marked workshopOnly are excluded; the flag defaults to false.
		if not row.get("workshopOnly", false) and state.automation.sell_owned.get(id, false) and state.automation.sell.get(id, false):
			mutated = (_sell(id) > 0.0) or mutated
	return bool(delivery.get("changed", false)) or mutated

func _valid_save_state(imported: Dictionary) -> bool:
	for key in [Save.LEGACY_BYTES, Save.LEGACY_SHA256, Save.LEGACY_ORIGIN, Save.LEGACY_TEXT]:
		if imported.has(key) and not imported[key] is String:
			return false
	# NaN and infinity never enter the game (the JSON reader already refuses them in text).
	if not _finite_numbers(imported, 0):
		return false
	for key in ["tickets", "hq_level", "craft_facility"]:
		if imported.has(key) and not _is_count(imported[key]):
			return false
	var legacy: Dictionary = _dictionary(imported.get("legacy_web_save"))
	var legacy_run: Dictionary = _dictionary(legacy.get("run"))
	if not imported.has("world") and legacy_run.has("world"):
		var legacy_world: Variant = legacy_run.world
		if not legacy_world is Dictionary:
			return false
		if legacy_world.has("mines"):
			if not _valid_world(legacy_world): return false
		elif not legacy_world.get("tunnelUnlocked", false) is bool:
			return false
	if imported.has("world") and not _valid_world(imported.world):
		return false
	# A Godot save always writes its huts as a list; anything else is not ours (a web save's are cleaned).
	if imported.has("world") and not imported.world.get("workshops", []) is Array:
		return false
	var remaining: Variant = imported.get("tunnel_remaining", 0.0)
	if not (remaining is int or remaining is float) or not is_finite(float(remaining)) or float(remaining) < 0.0:
		return false
	if not (imported.get("gold") is int or imported.get("gold") is float) or float(imported.gold) < 0.0:
		return false
	for key in ["inventory", "completed_research", "unlocked_sites", "automation", "queue", "facility", "workforce", "stats", "position", "legacy_web_save", "delivery", "last_pull"]:
		if imported.has(key) and not imported[key] is Dictionary:
			return false
	if not imported.get("inventory") is Dictionary:
		return false
	for id in imported.inventory:
		var qty: Variant = imported.inventory[id]
		if not (qty is int or qty is float) or float(qty) < 0.0:
			return false
	if not imported.get("characters", []) is Array:
		return false
	for worker in imported.get("characters", []):
		if not _valid_worker(worker):
			return false
	for id in imported.get("queue", {}):
		if not _tables.recipes.has(id) or not (imported.queue[id] is int or imported.queue[id] is float):
			return false
	for key in ["craft", "sell_owned", "sell", "target"]:
		if imported.has("automation") and not imported.automation.get(key) is Dictionary:
			return false
	return true

## A whole number 0..2^53 that converts to an int unchanged (int() of 1e300, INF or NaN is INT64_MIN).
func _is_count(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0 \
		and float(value) <= 9007199254740992.0 and floorf(float(value)) == float(value)

func _count(value: Variant, fallback: int) -> int:
	return int(value) if _is_count(value) else fallback

func _finite_numbers(value: Variant, depth: int) -> bool:
	if value is float:
		return is_finite(value)
	if depth > 256:
		return false
	if value is Dictionary:
		for key in value:
			if not _finite_numbers(value[key], depth + 1):
				return false
	elif value is Array:
		for item in value:
			if not _finite_numbers(item, depth + 1):
				return false
	return true

func _valid_worker(worker: Variant) -> bool:
	if not worker is Dictionary:
		return false
	for key in ["id", "rarity", "resource"]:
		if not worker.get(key) is String:
			return false
	for key in ["mining", "carry", "move"]:
		if not (worker.get(key) is int or worker.get(key) is float):
			return false
	return true

func _dictionary(value: Variant) -> Dictionary:
	return value.duplicate(true) if value is Dictionary else {}

## Scenes whose positions are not saved: inside the house the saved position stays on its door step (web).
const UNSAVED_POSITION_SCENES := ["res://scenes/world/house.tscn"]

func _record_position() -> void:
	if not is_instance_valid(player) or get_tree().current_scene == null:
		return
	if get_tree().current_scene.scene_file_path in UNSAVED_POSITION_SCENES:
		return
	var value := {"scene": get_tree().current_scene.scene_file_path, "x": player.position.x, "y": player.position.y}
	if state.position != value:
		state.position = value
		_mark_dirty(true)

func _pay(cost: Dictionary) -> bool:
	var gold := float(cost.get("gold", 0))
	var inputs: Dictionary = cost.get("products", {})
	if state.gold < gold or not _has(inputs):
		return false
	state.gold -= gold
	_consume(inputs)
	return true

func _has(inputs: Dictionary) -> bool:
	for id: String in inputs:
		if float(state.inventory.get(id, 0)) < float(inputs[id]):
			return false
	return true

func _consume(inputs: Dictionary) -> void:
	for id: String in inputs:
		_add(id, -float(inputs[id]))

func _add(id: String, amount: float) -> void:
	state.inventory[id] = float(state.inventory.get(id, 0)) + amount

func _multiplier() -> float:
	return (1.0 + float(state.hq_level) * float(data.balance.hq.MULTIPLIER_PER_LEVEL)) * Delivery.reputation_multiplier(data, state)

func _check_first_ticket() -> void:
	if not state.first_ticket and state.gold >= data.balance.gacha.FIRST_TICKET_GOLD_THRESHOLD:
		state.first_ticket = true
		state.tickets += 1

func _auto_sell_cost(row: Dictionary) -> int:
	return int(row.sell) * int(data.balance.selling.AUTO_SELL_COST_MULTIPLIER)

func _label(id: String) -> String:
	return str(_tables.resources.get(id, _tables.recipes.get(id, {})).get("name", id))

func _quantity(value: float) -> String:
	return str(snappedf(value, 0.01))

func _updated(message := "") -> bool:
	_mark_dirty()
	changed.emit()
	if not message.is_empty():
		feedback.emit(message)
	return true

func _reject(message: String) -> bool:
	feedback.emit(message)
	return false

func _valid_world(value: Variant) -> bool:
	if not value is Dictionary or not value.get("mines") is Array or not value.get("hiddenMineIds", []) is Array:
		return false
	if not value.get("base", {}) is Dictionary or not value.get("chunkEdits", {}) is Dictionary:
		return false
	for axis in ["x", "y", "level"]:
		var v: Variant = value.get("base", {}).get(axis, 0)
		if not (v is int or v is float) or not is_finite(float(v)) or floor(float(v)) != float(v) or absf(float(v)) > 9007199254740992.0:
			return false
	var layout_seed: Variant = value.get("layoutSeed", 0)
	if not (layout_seed is int or layout_seed is float) or absf(float(layout_seed)) > 9007199254740992.0:
		return false
	if not value.get("tunnelUnlocked", false) is bool:
		return false
	var ids := {}
	for m in value.mines:
		if not m is Dictionary or not m.get("id") is String or ids.has(m.id) or not _tables.resources.has(m.get("resource")):
			return false
		for axis in ["x", "y"]:
			var v: Variant = m.get(axis)
			if not (v is int or v is float) or not is_finite(float(v)) or floor(float(v)) != float(v) or absf(float(v)) > 32:
				return false
		for key in ["grade", "miningPower"]:
			if m.has(key) and not _is_count(m[key]):
				return false
		ids[m.id] = true
	for id in value.get("hiddenMineIds", []):
		if not id is String or not ids.has(id):
			return false
	return true
