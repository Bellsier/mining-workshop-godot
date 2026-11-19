extends CanvasLayer
## Inventory is available anywhere. The world controller opens the full menu at the workshop.

enum { TAB_INVENTORY, TAB_MINING, TAB_CRAFT, TAB_SELL, TAB_WORKERS, TAB_RESEARCH, TAB_DELIVERY, TAB_VILLAGE, TAB_SAVE }

const ExactJson := preload("res://scripts/exact_json.gd")
const TABS := ["가방", "채굴", "제작", "판매", "인부", "연구", "납품", "마을", "저장"]
const PAPER := Color("f5e5ce")
const MUTED := Color("d3bda0")

var _workshop: Node
var _theme: Theme
var _bar: PanelContainer
var _gold: Label
var _inventory_button: Button
var _action: Button
## The phone's torch button (web tdTorchNow): next to the action button on touch screens, in the world.
var _torch: Button
var _torch_callback := Callable()
## The garden button (web tdDecor): "장식 회수" or "다음 장식" near the garden.
var _garden: Button
var _garden_callback := Callable()
var _action_label := ""
var _action_callback := Callable()
var _context_hint: Label
var _context_hint_text := ""
var _overlay: ColorRect
var _title: Label
var _panel_gold: Label
var _save_indicator: Label
var _panel_save_indicator: Label
var _panel_note: Label
var _tabs: HBoxContainer
var _tab_buttons: Array[Button] = []
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _toast: PanelContainer
var _toast_text: Label
var _toast_timer: Timer
var _save_input: TextEdit
var _save_draft := ""
var _buttons_by_id := {}
var _names := {}
var _active_tab := 0
var _refresh_pending := false
var _render_key := ""
var _worker_pickers: Array[OptionButton] = []
var _recovery: ColorRect
var _recovery_title: Label
var _recovery_message: Label
var _recovery_actions: HFlowContainer
var _recovery_text: TextEdit
var _recovery_status := ""
var _save_tab_key := ""

const SAVE_LABELS := {
	"loading": "저장 불러오는 중…", "pending": "저장 예정", "saving": "저장 중…",
	"importing": "가져온 저장 기록 중…", "saved": "저장됨", "saved_basic": "저장됨 · 기본 보장",
	"failed": "저장 실패 · 곧 다시 시도", "quota": "저장 공간 부족 · 백업 필요",
	"conflict": "다른 곳에서 저장됨 · 저장 멈춤", "other_tab": "다른 탭 사용 중 · 저장 안 됨",
	"protected": "기존 저장 보호 중 · 저장 안 됨", "unavailable": "저장 불가 · 저장 탭 확인",
}
const SAVE_ATTENTION := ["failed", "quota", "conflict", "other_tab", "protected", "unavailable"]

func setup(workshop: Node) -> void:
	if is_instance_valid(_workshop):
		_workshop.disconnect("changed", _schedule_refresh)
		_workshop.disconnect("feedback", _show_feedback)
		_workshop.disconnect("save_status_changed", _show_save_status)
	_workshop = workshop
	_workshop.connect("changed", _schedule_refresh)
	_workshop.connect("feedback", _show_feedback)
	_workshop.connect("save_status_changed", _show_save_status)
	_show_save_status(_workshop.save_status)
	if is_node_ready():
		_refresh()

func _ready() -> void:
	layer = 12
	_theme = _make_theme()
	var surface := Control.new()
	surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.theme = _theme
	add_child(surface)
	surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_bar(surface)
	_build_overlay(surface)
	_build_toast(surface)
	_build_recovery(surface)
	set_action(_action_label, _action_callback)
	set_context_hint(_context_hint_text)
	_refresh()

func open_workshop() -> void:
	_open(false)

func open_inventory() -> void:
	_open(true)

## Opens the workshop menu on a tab by name: "craft" (huts and recipes), "village", "mining", ...
func open_tab(tab: String) -> void:
	var index: int = {"mining": TAB_MINING, "craft": TAB_CRAFT, "sell": TAB_SELL, "workers": TAB_WORKERS,
		"research": TAB_RESEARCH, "delivery": TAB_DELIVERY, "village": TAB_VILLAGE, "save": TAB_SAVE}.get(tab, TAB_INVENTORY)
	open_workshop()
	if not is_workshop_open():
		return
	_active_tab = index
	_tab_buttons[index].set_pressed_no_signal(true)
	_scroll.scroll_vertical = 0
	_refresh(true)

func toggle_workshop() -> void:
	if is_workshop_open():
		close_workshop()
	else:
		open_workshop()

func close_workshop() -> void:
	if not is_workshop_open():
		return
	_overlay.hide()
	_bar.show()
	_save_indicator.show()
	_action.visible = not _action_label.is_empty()
	_torch.visible = _torch_callback.is_valid()
	_garden.visible = not _garden.text.is_empty()
	_context_hint.visible = not _context_hint_text.is_empty()

func is_workshop_open() -> bool:
	return is_instance_valid(_overlay) and _overlay.visible

func set_action(label: String, callback: Callable = Callable()) -> void:
	_action_label = label
	_action_callback = callback
	if is_instance_valid(_action):
		_action.text = label
		_action.visible = not label.is_empty() and not is_workshop_open()

## Shows the garden button with `label` ("" hides it); pressing it calls `callback`.
func set_garden(label: String, callback: Callable = Callable()) -> void:
	_garden_callback = callback
	if is_instance_valid(_garden):
		_garden.text = label
		_garden.visible = not label.is_empty() and not is_workshop_open()

## Shows the torch button on touch screens while `callback` is valid (the world map), hides it otherwise.
func set_torch(callback: Callable) -> void:
	_torch_callback = callback if DisplayServer.is_touchscreen_available() else Callable()
	if is_instance_valid(_torch):
		_torch.visible = _torch_callback.is_valid() and not is_workshop_open()

func set_context_hint(message: String) -> void:
	_context_hint_text = message
	if is_instance_valid(_context_hint):
		_context_hint.text = message
		_context_hint.visible = not message.is_empty() and not is_workshop_open()

func _unhandled_key_input(event: InputEvent) -> void:
	if not is_instance_valid(_workshop) or _workshop.input_frozen():
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var editing_save := is_instance_valid(_save_input) and get_viewport().gui_get_focus_owner() == _save_input
	if key.physical_keycode == KEY_I and not editing_save:
		if is_workshop_open():
			close_workshop()
		else:
			open_inventory()
		get_viewport().set_input_as_handled()
	elif key.is_action_pressed("ui_cancel") and is_workshop_open():
		close_workshop()
		get_viewport().set_input_as_handled()

func _open(only_inventory: bool) -> void:
	if not is_node_ready() or not is_instance_valid(_workshop) or _workshop.input_frozen():
		return
	_active_tab = TAB_INVENTORY
	_title.text = "가방" if only_inventory else "공방"
	_panel_note.text = ""
	for index in range(_tab_buttons.size()):
		_tab_buttons[index].visible = not only_inventory or index in [TAB_INVENTORY, TAB_SAVE]
	_bar.hide()
	_save_indicator.hide()
	_action.hide()
	_torch.hide()
	_garden.hide()
	_context_hint.hide()
	_toast.hide()
	_overlay.show()
	_tab_buttons[0].set_pressed_no_signal(true)
	_scroll.scroll_vertical = 0
	_refresh(true)

func _build_bar(surface: Control) -> void:
	_save_indicator = _label("", 10)
	_save_indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_save_indicator.add_theme_color_override("font_outline_color", Color("211c18"))
	_save_indicator.add_theme_constant_override("outline_size", 4)
	surface.add_child(_save_indicator)
	_save_indicator.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_save_indicator.offset_left = -200
	_save_indicator.offset_right = -5
	_save_indicator.offset_top = 4
	_bar = PanelContainer.new()
	surface.add_child(_bar)
	_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_bar.offset_left = -109
	_bar.offset_top = 21
	_bar.offset_right = -5
	var contents := HBoxContainer.new()
	contents.add_theme_constant_override("separation", 4)
	_bar.add_child(contents)
	_gold = _label("", 10)
	_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gold.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	contents.add_child(_gold)
	_inventory_button = _button("가방", open_inventory)
	_inventory_button.tooltip_text = "가방 열기 (I)"
	_inventory_button.custom_minimum_size = Vector2(33, 20)
	contents.add_child(_inventory_button)
	_action = _button("", _activate_context)
	surface.add_child(_action)
	_garden = _button("", func() -> void: if _garden_callback.is_valid(): _garden_callback.call())
	_garden.hide()
	surface.add_child(_garden)
	_garden.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_garden.offset_left = -164
	_garden.offset_top = -74
	_garden.offset_right = -8
	_garden.offset_bottom = -44
	_torch = _button("횃불", func() -> void: if _torch_callback.is_valid(): _torch_callback.call())
	_torch.hide()
	surface.add_child(_torch)
	_torch.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_torch.offset_left = -164
	_torch.offset_top = -38
	_torch.offset_right = -116
	_torch.offset_bottom = -8
	_action.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_action.offset_left = -112
	_action.offset_top = -38
	_action.offset_right = -8
	_action.offset_bottom = -8
	_context_hint = _label("", 10)
	_context_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_context_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_context_hint.add_theme_constant_override("outline_size", 4)
	_context_hint.add_theme_color_override("font_outline_color", Color("211c18"))
	surface.add_child(_context_hint)
	_context_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_context_hint.offset_left = -177
	_context_hint.offset_top = -57
	_context_hint.offset_right = -8
	_context_hint.offset_bottom = -40

func _build_overlay(surface: Control) -> void:
	_overlay = ColorRect.new()
	_overlay.color = Color(0.04, 0.05, 0.06, 0.64)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.hide()
	surface.add_child(_overlay)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color("292521"), Color("9e7956"), 8))
	_overlay.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 12
	panel.offset_top = 10
	panel.offset_right = -12
	panel.offset_bottom = -10
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 5)
	panel.add_child(layout)
	var header := HBoxContainer.new()
	layout.add_child(header)
	_title = _label("공방", 15)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	_panel_save_indicator = _label("", 9)
	header.add_child(_panel_save_indicator)
	_panel_gold = _label("", 11)
	_panel_gold.add_theme_color_override("font_color", Color("f1c577"))
	header.add_child(_panel_gold)
	var close_button := _button("닫기", close_workshop)
	close_button.tooltip_text = "공방 메뉴 닫기 (Esc)"
	close_button.custom_minimum_size.x = 44
	header.add_child(close_button)
	_tabs = HBoxContainer.new()
	layout.add_child(_tabs)
	var group := ButtonGroup.new()
	for index in range(TABS.size()):
		var tab_button := _button(TABS[index], _select_tab.bind(index))
		tab_button.toggle_mode = true
		tab_button.button_group = group
		tab_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tab_buttons.append(tab_button)
		_tabs.add_child(tab_button)
	_scroll = ScrollContainer.new()
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_scroll)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows.add_theme_constant_override("separation", 4)
	_scroll.add_child(_rows)
	_panel_note = _label("", 10)
	_panel_note.add_theme_color_override("font_color", Color("f1c577"))
	_panel_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	layout.add_child(_panel_note)

func _build_toast(surface: Control) -> void:
	_toast = PanelContainer.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.hide()
	surface.add_child(_toast)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.offset_left = -143
	_toast.offset_right = 143
	_toast.offset_top = -65
	_toast.offset_bottom = -43
	_toast_text = _label("", 10)
	_toast_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_toast.add_child(_toast_text)
	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(_toast.hide)
	add_child(_toast_timer)

func _activate_context() -> void:
	if _action_callback.is_valid():
		_action_callback.call()

func _select_tab(index: int) -> void:
	if _active_tab == index:
		return
	_active_tab = index
	_scroll.scroll_vertical = 0
	_refresh(true)

func _schedule_refresh() -> void:
	if not is_node_ready() or _refresh_pending:
		return
	_refresh_pending = true
	_refresh.call_deferred()

func _refresh(force := false) -> void:
	_refresh_pending = false
	if not is_instance_valid(_workshop):
		return
	# With the panel closed only the gold line shows: read it alone. (The full snapshot works out every tab,
	# the next craft hut's spot among them, and this runs on every change of the game.)
	_gold.text = format_quantity(float(_workshop.get("state").get("gold", 0))) + " G"
	_panel_gold.text = _gold.text
	if not is_workshop_open():
		return
	var state: Dictionary = _workshop.call("snapshot")
	var gold := float(state.get("gold", 0))
	if _active_tab == TAB_SAVE and is_instance_valid(_save_input):
		return
	var focused := get_viewport().gui_get_focus_owner()
	if not force and focused is LineEdit and focused.has_meta("craft_target"):
		return
	if not force:
		if _active_tab in [TAB_WORKERS, TAB_CRAFT, TAB_DELIVERY]:
			for picker in _worker_pickers:
				if picker.get_popup().visible:
					return
		if is_instance_valid(focused) and focused.has_meta("target_input"):
			return
	var resources: Array = state.get("resources", [])
	var recipes: Array = state.get("recipes", [])
	var products: Array = state.get("products", [])
	var inventory: Dictionary = state.get("inventory", {})
	var next_key := _panel_key(state, inventory, recipes, gold)
	if not force and next_key == _render_key:
		return
	_render_key = next_key
	var focused_row := ""
	if is_instance_valid(focused) and focused.has_meta("row_id"):
		focused_row = str(focused.get_meta("row_id"))
	var scroll_position := _scroll.scroll_vertical
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_save_input = null
	_buttons_by_id.clear()
	_worker_pickers.clear()
	var automation: Dictionary = state.get("automation", {})
	_names.clear()
	for item in resources + products + recipes:
		var id := _item_id(item)
		_names[id] = str(item.get("name", id))
		var output := str(item.get("output", id))
		if output != id and not _names.has(output):
			_names[output] = _names[id]
	match _active_tab:
		TAB_INVENTORY:
			_render_inventory(inventory)
			if not _log.is_empty():
				_rows.add_child(_label("기록", 12))
				for line in _log:
					var entry := _label(line, 10)
					entry.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
					entry.add_theme_color_override("font_color", MUTED)
					_rows.add_child(entry)
		TAB_MINING: _render_mining(state.get("mining", {}), str(state.get("hint", "")), inventory, gold)
		TAB_CRAFT:
			var auto_unlocked := bool(state.get("completed_research", {}).get("autoCraftDevice", false))
			_render_huts(state.get("huts", {}), recipes, inventory, gold, auto_unlocked)
			_render_upgrades(state.get("upgrades", []).filter(func(u: Dictionary) -> bool: return u.id in ["hq_level", "craft_facility"]), inventory, gold)
			_render_recipes(recipes, inventory, automation, auto_unlocked)
		TAB_SELL: _render_sales(resources, products, recipes, inventory, automation, gold)
		TAB_WORKERS:
			_render_workers(state.get("workers", []), state.get("worker_details", []), resources, gold, int(state.get("worker_cap", 0)), str(state.get("last_pull", "")))
		TAB_RESEARCH:
			_render_tunnel(state.get("tunnel", {}), state.get("completed_research", {}), inventory, gold)
			_render_research(state.get("research", []), state.get("completed_research", {}), inventory, gold)
		TAB_DELIVERY: _render_deliveries(state.get("deliveries", state.get("delivery_offers", [])), int(state.get("reputation", 0)),
			state.get("companies", {}), recipes, float(state.get("multiplier", 1.0)))
		TAB_VILLAGE:
			_render_village(state.get("village", {}), inventory, gold)
			_render_garden(state.get("garden", {}))
		TAB_SAVE: _render_save()
	if _rows.get_child_count() == 0:
		_rows.add_child(_label("가방에 아이템이 없어요." if _active_tab == TAB_INVENTORY else "지금 가능한 항목이 없어요.", 11))
	_scroll.set_deferred("scroll_vertical", scroll_position)
	var previous_button: BaseButton = _buttons_by_id.get(focused_row)
	if is_instance_valid(previous_button) and not previous_button.disabled:
		previous_button.grab_focus.call_deferred()

func _panel_key(state: Dictionary, inventory: Dictionary, recipes: Array, gold: float) -> String:
	if _active_tab == TAB_WORKERS:
		return JSON.stringify([floorf(gold), state.get("workers", []), state.get("worker_details", []), state.get("resources", []), state.get("last_pull", ""), state.get("worker_cap", 0)])
	if _active_tab == TAB_DELIVERY:
		return JSON.stringify([state.get("reputation", 0), state.get("deliveries", state.get("delivery_offers", [])), state.get("companies", {}),
			_ship_choice, floorf(float(state.get("gold", 0)))])
	var visible_quantities := {}
	for id in inventory:
		var quantity := floorf(float(inventory[id]))
		if quantity > 0.0:
			visible_quantities[id] = quantity
	# Inventory and sales show amounts as text, so they redraw when that text changes (0.5 → 0.6).
	var shown_quantities := {}
	for id in inventory:
		if float(inventory[id]) > 0.0:
			shown_quantities[id] = format_quantity(float(inventory[id]))
	var automation: Dictionary = state.get("automation", {})
	var completed: Dictionary = state.get("completed_research", {})
	match _active_tab:
		TAB_INVENTORY: return JSON.stringify([shown_quantities, _log.size(), _log.front() if not _log.is_empty() else ""])
		TAB_MINING: return JSON.stringify([state.get("mining", {}), state.get("hint", ""), floorf(gold)])
		TAB_CRAFT:
			var remaining := []
			for recipe in recipes:
				remaining.append(ceili(float(recipe.get("remaining", 0))))
			var huts: Array = []
			for hut: Dictionary in state.get("huts", {}).get("list", []):
				# Seconds left in tenths, like the web hut card; the rest only when it changes.
				var upgrade_gold := float(hut.get("upgrade", {}).get("gold", INF))
				huts.append([hut.id, hut.level, hut.recipe, hut.auto, hut.status, ceili(float(hut.progress) * 10.0), gold >= upgrade_gold])
			return JSON.stringify([visible_quantities, automation, completed, remaining, huts, state.get("huts", {}).get("block", ""), state.get("upgrades", []), floorf(gold)])
		TAB_SELL: return JSON.stringify([shown_quantities, automation, gold])
		TAB_RESEARCH: return JSON.stringify([state.get("tunnel", {}), visible_quantities, completed, floorf(gold)])
		TAB_VILLAGE: return JSON.stringify([visible_quantities, state.get("village", {}), state.get("garden", {}), floorf(gold)])
	return str(_active_tab)

func _render_inventory(inventory: Dictionary) -> void:
	for key in inventory:
		var quantity := float(inventory[key])
		if quantity > 0.0:
			_add_row(_name_for(str(key)), "%s개" % format_quantity(quantity))

## The original's fmt(): "0" for nothing, one decimal below 10 when fractional, else whole units with
## thousands separators. A 0.5 iron stays visible as "0.5" instead of rounding down to nothing.
@warning_ignore("integer_division")
static func format_quantity(value: float) -> String:
	if not is_finite(value) or value <= 0.0:
		return "0"
	if value < 10.0 and value != floorf(value):
		# toFixed(1) on the exact stored value, ties up (0.25 → "0.3", 9.96 → "10.0", 1.15 → "1.1").
		# value × 10 in floating point can round across the .x5 boundary, so this works in integers:
		# value = mantissa / 2^shift exactly, and tenths = floor((10·mantissa + 2^(shift-1)) / 2^shift).
		if value < 0.04:
			return "0.0"
		var mantissa := value
		var shift := 0
		while mantissa != floorf(mantissa):
			mantissa *= 2.0
			shift += 1
		var scale := 1 << shift
		var tenths := (int(mantissa) * 10 + scale / 2) / scale
		return "%d.%d" % [tenths / 10, tenths % 10]
	var whole := floorf(value)
	var digits := str(int(whole))
	if whole >= ExactJson.TWO_53:
		# Like Intl.NumberFormat: the shortest digits of the double, then zeros (int() would overflow).
		var shortest := ExactJson.shortest_digits(whole)
		digits = shortest[0] + "0".repeat(shortest[1])
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return digits + grouped

const HUT_STATUS := {"noRecipe": "레시피를 선택하세요", "full": "목표 재고 도달 · 쉬는 중", "waiting": "대기 중"}

## The craft huts (web renderWorkshopBuild / renderWorkshops): a build button, then one card per hut with its
## recipe picker, a craft button, the upgrade and the automatic switch.
func _render_huts(huts: Dictionary, recipes: Array, inventory: Dictionary, gold: float, auto_unlocked: bool) -> void:
	if huts.is_empty() or not _workshop.has_method("build_hut"):
		return
	var list: Array = huts.get("list", [])
	_rows.add_child(_label("제작소 %d / %d곳" % [list.size(), int(huts.get("max", 0))], 12))
	var block := str(huts.get("block", ""))
	if block == "research":
		_rows.add_child(_label("제작소를 지으려면 연구 탭에서 \"제작소 건설\"을 연구하세요.", 10))
	elif block == "limit":
		_rows.add_child(_label("제작소를 더 지을 수 없어요. (최대 %d곳)" % int(huts.get("max", 0)), 10))
	else:
		var cost: Dictionary = huts.get("cost", {})
		var parts: Dictionary = cost.get("products", {})
		var details := "%s G" % format_quantity(float(cost.get("gold", 0)))
		if not parts.is_empty():
			details += " · " + _describe_items(parts)
		if block == "spot":
			details += " · 공방 주변에 빈 자리가 없어요"
		_add_row("제작소 짓기", details, "짓기", "build_hut", "build_hut", block.is_empty())
	# web bottleneckHtml: which huts stand idle and what they lack
	if not list.is_empty():
		var idle: Array = huts.get("idle", [])
		if idle.is_empty():
			_rows.add_child(_label("모든 제작소가 일하고 있어요.", 10))
		else:
			var missing: Array = huts.get("missing", [])
			if not missing.is_empty():
				var names := PackedStringArray()
				for m: Dictionary in missing:
					names.append("%s (%d곳)" % [m.name, int(m.huts)])
				_rows.add_child(_label("가장 필요한 재료: " + ", ".join(names), 10))
			for w: Dictionary in idle:
				var why: String = {"noRecipe": "레시피를 정하지 않았어요", "waiting": "재료는 있지만 제작을 시작하지 않았어요",
					"full": "목표 재고에 도달해 쉬고 있어요"}.get(str(w.status), "")
				if str(w.status) == "blocked":
					var parts := PackedStringArray()
					for sh: Dictionary in w.shortages:
						parts.append("%s %d개 부족" % [_name_for(str(sh.id)), int(float(sh.need) - float(sh.have))])
					why = "%s — %s" % [_name_for(str(w.recipe)), ", ".join(parts)]
				var line := _label("제작소 %d: %s" % [int(w.number), why], 10)
				line.add_theme_color_override("font_color", MUTED)
				_rows.add_child(line)
	var options: Array = []
	for recipe in recipes:
		options.append(recipe)
	for hut: Dictionary in list:
		var recipe_id := str(hut.recipe)
		var label: String = HUT_STATUS.get(str(hut.status), "")
		if str(hut.status) == "working":
			label = "제작 중... %.1f초" % float(hut.progress) if float(hut.progress) > 0.0 else ("자동 제작 중" if hut.auto else "대기 중")
		elif str(hut.status) == "blocked":
			label = "자동 제작 중 · 재료 부족" if hut.auto else "재료 부족"
		var title := "제작소 %d Lv.%d" % [int(hut.number), int(hut.level)]
		var row_id := "craft_hut:" + str(hut.id)
		var inputs: Dictionary = {}
		for recipe in options:
			if _item_id(recipe) == recipe_id:
				inputs = recipe.get("inputs", recipe.get("need", {}))
		var ready := not recipe_id.is_empty() and float(hut.progress) <= 0.0 and _has_items(inventory, inputs)
		var actions := _add_row(title, "위치 (%d, %d) · %s" % [int(hut.x), int(hut.y), label], "제작", "craft_hut", str(hut.id), ready)
		var picker := OptionButton.new()
		picker.custom_minimum_size = Vector2(96, 26)
		picker.add_item("레시피 없음")
		var keys := PackedStringArray([""])
		for recipe in options:
			var id := _item_id(recipe)
			if id == recipe_id or not bool(recipe.get("locked", false)):
				keys.append(id)
				picker.add_item(_name_for(id))
		picker.select(maxi(0, keys.find(recipe_id)))
		picker.disabled = float(hut.progress) > 0.0
		picker.item_selected.connect(_choose_hut_recipe.bind(str(hut.id), keys))
		picker.get_popup().popup_hide.connect(_schedule_refresh)
		picker.set_meta("row_id", row_id)
		_buttons_by_id[row_id] = picker
		_worker_pickers.append(picker)
		actions.add_child(picker)
		var upgrade: Dictionary = hut.get("upgrade", {})
		if upgrade.is_empty():
			actions.add_child(_label("최대 레벨", 10))
		else:
			var needs: Dictionary = upgrade.get("products", {})
			var caption := "업그레이드 Lv.%d · %s G" % [int(hut.level) + 1, format_quantity(float(upgrade.gold))]
			if not needs.is_empty():
				caption += " + " + _describe_items(needs)
			var button := _button(caption, _perform.bind("upgrade_hut", str(hut.id)))
			button.disabled = gold < float(upgrade.gold) or not _has_items(inventory, needs)
			actions.add_child(button)
		if auto_unlocked and not recipe_id.is_empty():
			_add_toggle(actions, "자동 제작", "set_hut_auto", str(hut.id), bool(hut.auto))
		elif not auto_unlocked:
			actions.add_child(_label("자동 제작 (연구: 자동 제작 장치)", 9))

func _choose_hut_recipe(index: int, hut_id: String, keys: PackedStringArray) -> void:
	_workshop.call("set_hut_recipe", hut_id, keys[index])
	_schedule_refresh()

func _render_recipes(recipes: Array, inventory: Dictionary, automation: Dictionary, auto_craft_unlocked: bool) -> void:
	var auto_craft: Dictionary = automation.get("craft", {})
	var targets: Dictionary = automation.get("target", {})
	if automation.has("craft") and not auto_craft_unlocked:
		_rows.add_child(_label("자동 제작은 연구에서 열 수 있어요.", 10))
	for recipe in recipes:
		var id := _item_id(recipe)
		var inputs: Dictionary = recipe.get("inputs", recipe.get("need", {}))
		var count := int(recipe.get("count", recipe.get("out", 1)))
		var seconds := ceili(float(recipe.get("remaining", 0)))
		var hut_only := bool(recipe.get("hut_only", false))
		var ready := seconds == 0 and not hut_only and bool(recipe.get("available", true)) and _has_items(inventory, inputs)
		var description := "%s  →  %d개" % [_describe_items(inputs), count]
		if hut_only:
			description += " · 제작소 전용"
		if seconds > 0:
			description += " · %d초 남음" % seconds
		var actions := _add_row(_name_for(id), description, "제작", "craft", id, ready)
		if auto_craft_unlocked and automation.has("craft") and _workshop.has_method("set_auto_craft") and not hut_only:
			_add_toggle(actions, "자동 제작", "set_auto_craft", id, bool(auto_craft.get(id, false)))
			if _workshop.has_method("set_craft_target"):
				_add_craft_target(actions, id, int(targets.get(id, 0)))

func _render_sales(resources: Array, products: Array, recipes: Array, inventory: Dictionary, automation: Dictionary, gold: float) -> void:
	var prices := {}
	var automatic_costs := {}
	for item in resources + products + recipes:
		var price := int(item.get("sell_price", item.get("sell", item.get("price", 0))))
		var id := str(item.get("output", _item_id(item)))
		if price > 0:
			prices[id] = price
		if item.has("auto_sell_cost") and not bool(item.get("workshop_only", false)):
			automatic_costs[id] = int(item.auto_sell_cost)
	var auto_sell: Dictionary = automation.get("sell", {})
	var licenses: Dictionary = automation.get("sell_owned", {})
	var costs: Variant = automation.get("sell_cost", automatic_costs)
	for key in prices:
		var id := str(key)
		var quantity := float(inventory.get(id, 0))
		var actions := _add_row(_name_for(id), "보유 %s개 · 개당 %d G" % [format_quantity(quantity), prices[key]], "전량 판매", "sell", id, quantity > 0.0)
		if bool(licenses.get(id, false)) and _workshop.has_method("set_auto_sell"):
			_add_toggle(actions, "자동 판매", "set_auto_sell", id, bool(auto_sell.get(id, false)))
		elif costs != null and _workshop.has_method("buy_auto_sell"):
			var cost := int(costs.get(id, -1)) if costs is Dictionary else int(costs)
			if cost >= 0:
				var buy := _button("자동 판매 열기 · %d G" % cost, _perform.bind("buy_auto_sell", id))
				buy.disabled = gold < cost
				actions.add_child(buy)

func _render_workers(workers: Array, assigned: Array, resources: Array, gold: float, cap := 0, last_pull := "") -> void:
	_rows.add_child(_label("고용 인부 %d / %d명" % [assigned.size(), cap] if cap > 0 else "고용 인부 %d명" % assigned.size(), 11))
	if not last_pull.is_empty():
		_rows.add_child(_label(last_pull, 10))
	for worker in workers:
		var id := _item_id(worker)
		var cost := int(worker.get("cost", 0))
		var label := str(worker.get("name", id))
		var tickets := int(worker.get("tickets", 0))
		var uses_ticket: bool = worker.has("tickets")
		var description := "가챠권 %d장 보유" % tickets if uses_ticket else "%d G" % cost
		var can_hire := tickets > 0 if uses_ticket else gold >= cost
		_add_row(label, description, "고용", "hire", id, can_hire and bool(worker.get("available", true)))
	if not _workshop.has_method("assign_worker"):
		return
	for worker in assigned:
		var id := _item_id(worker)
		var assigned_to := str(worker.get("resource", ""))
		var number := assigned.find(worker) + 1
		var details := "배치 · " + _name_for(assigned_to)
		var stats: Dictionary = worker.get("stats", {})
		if not stats.is_empty():
			details += " · 종합 +%.2f/초" % float(worker.get("effective", 0))
		var actions := _add_row("%s #%d" % [str(worker.get("rating", "")), number], details)
		for stat: String in stats:
			var st: Dictionary = stats[stat]
			var at_max := int(st.level) >= int(st.max)
			var caption := "%s %.1f · %s" % [st.label, float(st.value), "최대" if at_max else "강화 %d G" % int(st.cost)]
			var button := _button(caption, _perform2.bind("upgrade_worker", id, stat))
			button.disabled = at_max or gold < float(st.cost)
			actions.add_child(button)
		var picker := OptionButton.new()
		picker.custom_minimum_size = Vector2(84, 26)
		var available_resources := PackedStringArray()
		for resource in resources:
			var resource_id := _item_id(resource)
			if bool(resource.get("unlocked", false)):
				available_resources.append(resource_id)
				picker.add_item(_name_for(resource_id))
		if available_resources.is_empty():
			picker.free()
			continue
		picker.select(available_resources.find(assigned_to))
		picker.item_selected.connect(_assign_worker.bind(id, available_resources))
		picker.get_popup().popup_hide.connect(_schedule_refresh)
		picker.set_meta("row_id", id)
		_buttons_by_id[id] = picker
		_worker_pickers.append(picker)
		actions.add_child(picker)

func _assign_worker(index: int, worker_id: String, available_resources: PackedStringArray) -> void:
	_workshop.call("assign_worker", worker_id, available_resources[index])
	_schedule_refresh()

func _render_research(research: Array, completed: Dictionary, inventory: Dictionary, gold: float) -> void:
	for study in research:
		var id := _item_id(study)
		var title := str(study.get("name", id))
		if bool(completed.get(id, false)):
			_add_row(title, "연구 완료")
			continue
		var cost: Variant = study.get("cost", 0)
		var money := int(cost.get("gold", 0)) if cost is Dictionary else int(cost)
		var needs: Dictionary = cost.get("products", {}) if cost is Dictionary else {}
		var ready := gold >= money and _has_items(inventory, needs) and bool(study.get("available", true))
		var details := "%d G" % money
		if not needs.is_empty():
			details += " · " + _describe_items(needs)
		for requirement in study.get("requires", []):
			if not bool(completed.get(str(requirement), false)):
				details += " · 선행 연구 필요"
				ready = false
				break
		_add_row(title, details, "연구", "unlock", id, ready)

## Free delivery choices per company (product and quantity), kept while the tab redraws.
var _ship_choice := {}

## The 납품 tab (web renderReputation, renderDelivery): reputation and its effects, then one card per company with
## its open orders and free delivery.
func _render_deliveries(deliveries: Array, reputation: int, view: Dictionary = {}, recipes: Array = [], multiplier := 1.0) -> void:
	_rows.add_child(_label("명성 %d · 현재 배율 ×%.2f" % [reputation, multiplier], 12))
	for effect: Dictionary in view.get("effects", []):
		var line := _label("%s %s — %s" % [effect.name, effect.text, effect.desc], 10)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.add_theme_color_override("font_color", PAPER if effect.open else MUTED)
		_rows.add_child(line)
	if view.is_empty():
		for delivery in deliveries:
			_render_order(delivery)
		return
	for card: Dictionary in view.get("companies", []):
		var actions := _add_row(str(card.name), str(card.desc) + ("" if card.open else "\n" + str(card.closed)))
		if not card.open:
			continue
		var info := _label("%s\n좋아하는 것: %s (★ 점수 ×1.5)" % [card.score, ", ".join(PackedStringArray(card.favorites))], 10)
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_theme_color_override("font_color", MUTED)
		_rows.add_child(info)
		for delivery in deliveries:
			if str(delivery.get("company_id", "")) == str(card.id):
				_render_order(delivery)
		_render_free_delivery(card, recipes, actions)

func _render_order(delivery: Dictionary) -> void:
	var id := _item_id(delivery)
	var product_id := str(delivery.get("product", ""))
	var reward := "명성 +%d" % int(delivery.get("reputation", 0)) if int(delivery.get("index", -1)) >= 0 \
		else "보상 %s G" % format_quantity(float(delivery.get("gold_reward", 0)))
	var description := "%s %d개 · 배송비 %d G · %s" % [
		str(delivery.get("product_name", _name_for(product_id))), int(delivery.get("qty", 0)), int(delivery.get("shipping_cost", 0)), reward]
	_add_row("수주 · " + str(delivery.get("company_name", "")), description, "납품", "deliver", id, bool(delivery.get("can_complete", false)))

func _render_free_delivery(card: Dictionary, recipes: Array, actions: VBoxContainer) -> void:
	var id := str(card.id)
	var choice: Dictionary = _ship_choice.get(id, {})
	var keys := PackedStringArray()
	var picker := OptionButton.new()
	picker.custom_minimum_size = Vector2(96, 26)
	for recipe in recipes:
		if bool(recipe.get("locked", false)):
			continue
		var key := _item_id(recipe)
		keys.append(key)
		picker.add_item(_name_for(key) + (" ★" if _name_for(key) in card.favorites else ""))
	if keys.is_empty():
		picker.free()
		return
	var product: String = choice.get("product", keys[0])
	if not keys.has(product):
		product = keys[0]
	var qty := int(choice.get("qty", 1))
	picker.select(keys.find(product))
	picker.set_meta("row_id", "ship_product:" + id)
	picker.item_selected.connect(func(index: int) -> void:
		_ship_choice[id] = {"product": keys[index], "qty": qty}
		_refresh(true))
	picker.get_popup().popup_hide.connect(_schedule_refresh)
	_worker_pickers.append(picker)
	actions.add_child(picker)
	var field := LineEdit.new()
	field.custom_minimum_size = Vector2(60, 25)
	field.max_length = 6
	field.text = str(qty)
	field.set_meta("target_input", true)
	field.text_submitted.connect(func(_t: String) -> void: field.release_focus())
	field.focus_exited.connect(func() -> void:
		var n := clampi(int(field.text) if field.text.is_valid_int() else 1, 1, 999999)
		_ship_choice[id] = {"product": product, "qty": n}
		_schedule_refresh())
	actions.add_child(field)
	var preview: Dictionary = _workshop.call("delivery_preview", id, product, qty)
	if not preview.is_empty():
		var text := _label("보유 %s개 · 배송비 %d G · 점수 +%s" % [format_quantity(float(preview.have)), int(preview.cost), format_quantity(float(preview.score))], 9)
		text.add_theme_color_override("font_color", MUTED)
		actions.add_child(text)
	var send := _button("자유 납품", func() -> void:
		_workshop.call("ship_free", id, product, qty)
		_schedule_refresh())
	send.disabled = preview.is_empty() or float(preview.have) < qty
	actions.add_child(send)

func _render_upgrades(upgrades: Array, inventory: Dictionary, gold: float) -> void:
	if upgrades.is_empty():
		return
	_rows.add_child(_label("시설과 인력 강화", 12))
	for upgrade: Dictionary in upgrades:
		var title := "%s Lv.%d" % [upgrade.name, int(upgrade.level)]
		if int(upgrade.level) >= int(upgrade.limit):
			_add_row(title, "최대 레벨")
			continue
		var cost: Dictionary = upgrade.cost
		var money := int(cost.get("gold", 0))
		var needs: Dictionary = cost.get("products", {})
		var details := "%d G" % money if needs.is_empty() else _describe_items(needs)
		_add_row(title, details, "강화", "upgrade", upgrade.id, gold >= money and _has_items(inventory, needs))

func _render_village(village: Dictionary, inventory: Dictionary, gold: float) -> void:
	if village.is_empty():
		return
	for facility: Dictionary in village.facilities:
		var step: Dictionary = facility.step
		if step.is_empty():
			var caption := str(facility.stage) if facility.open else "감정소를 먼저 복구하세요."
			_add_row(facility.name, caption)
			continue
		var money := int(step.cost.get("gold", 0))
		var needs: Dictionary = step.cost.get("products", {})
		var cost_text := "%d G" % money
		if not needs.is_empty():
			cost_text += " · " + _describe_items(needs)
		_add_row(facility.name, cost_text, step.name, "restore_facility", facility.id, gold >= money and _has_items(inventory, needs))
	_add_row("미감정 유물", "%d개 보유" % village.unidentified, "감정", "appraise_relic", "appraiser", village.can_appraise)
	if village.museum:
		_rows.add_child(_label("박물관 전시 %d / %d" % [village.donations, village.total], 12))
		if int(village.discount) > 0:
			_rows.add_child(_label("연구 비용 %d%% 할인" % village.discount, 10))
	for relic: Dictionary in village.relics:
		if relic.donated:
			_add_row(relic.name, "전시 중")
		else:
			_add_row(relic.name, "%d개 보유" % relic.quantity, "기증", "donate_relic", relic.id, village.museum and relic.quantity > 0)
	for specimen: Dictionary in village.specimens:
		var title := _name_for(specimen.id) + " 표본"
		if specimen.donated:
			_add_row(title, "전시 중")
		else:
			_add_row(title, "%d개 필요" % specimen.quantity, "기증", "donate_specimen", specimen.id,
				float(inventory.get(specimen.id, 0)) >= float(specimen.quantity))

## The garden's decorations to choose from and the museum's collection rewards (web villageGardenCard,
## villageRewardSection).
func _render_garden(garden: Dictionary) -> void:
	if garden.is_empty():
		return
	_rows.add_child(_label("정원 · 장식 %d / %d칸" % [int(garden.placed), int(garden.cells)], 12))
	var tip := _label("정원 칸 앞에서 E로 놓고, 다시 E로 들어 옮겨요. R은 회수, Q는 다음 장식이에요." if garden.has_garden else "마을 광장 자리를 찾는 중이에요.", 10)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_color_override("font_color", MUTED)
	_rows.add_child(tip)
	for kind: Dictionary in garden.kinds:
		var title := ("▶ " if kind.selected else "") + str(kind.name)
		_add_row(title, str(kind.desc) if kind.unlocked else "박물관 보상으로 해금돼요.", "고르기", "decor_select", str(kind.id),
			bool(kind.unlocked) and not bool(kind.selected))
	_rows.add_child(_label("수집 보상 · 수집 %d / %d" % [int(garden.collected), int(garden.total)], 12))
	for r: Dictionary in garden.rewards:
		var line := _label("%s%d점 %s" % ["✓ " if r.earned else "", int(r.need), r.name], 10)
		line.add_theme_color_override("font_color", Color("f1c577") if r.earned else MUTED)
		_rows.add_child(line)
	var note := _label("박물관 보상은 골드를 주지 않아요. 연구 보너스는 연구의 골드 비용에만 적용돼요.", 10)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", MUTED)
	_rows.add_child(note)

func _render_save() -> void:
	if not _workshop.has_method("import_save"):
		return
	var explanation := _label("웹판에서 내보낸 저장 JSON을 붙여넣으세요. 가져오면 현재 진행이 바뀝니다.", 11)
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(explanation)
	_save_input = TextEdit.new()
	_save_input.placeholder_text = "저장 JSON"
	_save_input.text = _save_draft
	_save_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_save_input.custom_minimum_size.y = 87
	_save_input.add_theme_font_size_override("font_size", 10)
	_save_input.text_changed.connect(_on_save_input_changed)
	_rows.add_child(_save_input)
	var actions := HBoxContainer.new()
	_rows.add_child(actions)
	actions.add_child(_button("가져오기", _import_save))
	if _workshop.has_method("export_save"):
		actions.add_child(_button("내보내기", _export_save))
		actions.add_child(_button("텍스트 전체 선택", _select_save_text))
	if _workshop.has_method("import_save_bytes"):
		_render_original_controls()
	_render_save_status()

## File import keeps a web save's exact bytes; pasting may not (see the note shown here).
func _render_original_controls() -> void:
	var files := HBoxContainer.new()
	_rows.add_child(files)
	files.add_child(_button("파일에서 가져오기", _import_save_file))
	var info: Dictionary = _workshop.call("legacy_original_info")
	var export_original := _button("원본 JS 파일 저장", _export_original_file)
	export_original.disabled = str(info.status) not in ["ok", "conflict"]
	files.add_child(export_original)
	var lines: PackedStringArray = ["붙여넣기는 줄바꿈(CRLF)이나 일부 문자가 바뀐 채 들어올 수 있어요. 원본 바이트를 그대로 보존하려면 '파일에서 가져오기'를 쓰세요."]
	match str(info.status):
		"ok", "conflict":
			lines.append("보관 중인 JS 원본: %s · %d바이트 · SHA-256 %s…" % ["파일 그대로" if info.origin == "file" else "붙여넣은 텍스트 기준", int(info.size), str(info.sha256).left(12)])
			if info.status == "conflict":
				lines.append("원본과 게임이 쓰는 사본이 달라 사본을 쓰고 있어요. 둘 다 보존합니다.")
		"corrupt":
			lines.append("보관 중인 JS 원본이 손상되어 게임은 저장된 사본을 쓰고 있어요. 원본 데이터는 지우지 않고 그대로 둡니다.")
		"copy_only":
			lines.append("이전 버전에서 가져온 저장이라 원본 바이트가 없어요. 원본이 필요하면 JS 저장 파일을 다시 가져오세요.")
	var note := _label("\n".join(lines), 10)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(note)

func _import_save_file() -> void:
	if OS.has_feature("web"):
		if not bool(_workshop.call("request_import_file")):
			_show_feedback("이 브라우저에서는 파일을 열 수 없어요.")
		return
	_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, _on_import_file_chosen)

func _on_import_file_chosen(path: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		_show_feedback("파일을 읽지 못했어요.")
		return
	_workshop.call("import_save_bytes", bytes)

func _export_original_file() -> void:
	if OS.has_feature("web"):
		if not bool(_workshop.call("download_legacy_original")):
			_show_feedback("보관 중인 JS 원본이 없어요.")
		return
	_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, _on_original_path_chosen)

func _on_original_path_chosen(path: String) -> void:
	var bytes: PackedByteArray = _workshop.call("legacy_original_bytes")
	var file := FileAccess.open(path, FileAccess.WRITE) if not bytes.is_empty() else null
	if file == null:
		_show_feedback("JS 원본을 저장하지 못했어요.")
		return
	file.store_buffer(bytes)
	file.close()
	_show_feedback("JS 원본을 그대로 저장했어요.")

func _file_dialog(mode: FileDialog.FileMode, chosen: Callable) -> void:
	var dialog := FileDialog.new()
	dialog.file_mode = mode
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.filters = PackedStringArray(["*.json ; 저장 JSON", "* ; 모든 파일"])
	dialog.file_selected.connect(chosen)
	dialog.file_selected.connect(func(_path: String) -> void: dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered_ratio(0.8)

## Below the import/export controls: what is guaranteed now, and the recovery actions on offer.
func _render_save_status() -> void:
	if not _workshop.has_method("save_notice"):
		return
	var notice: Dictionary = _workshop.call("save_notice")
	var status := str(notice.status)
	var lines: PackedStringArray = ["저장 상태: " + str(SAVE_LABELS.get(status, status))]
	if not str(notice.title).is_empty():
		lines.append(str(notice.title) + " — " + str(notice.message))
	if status == "saved_basic":
		lines.append("이 브라우저는 저장이 디스크까지 기록됐는지 확인해 주지 않아요. 중요한 진행은 JSON으로 백업하세요.")
	var persisted := str(_workshop.get("storage_persisted"))
	if persisted == "no":
		lines.append("브라우저가 공간이 부족할 때 사이트 데이터를 정리할 수 있어요. '저장 공간 보호 요청'이나 JSON 백업을 권해요.")
	elif persisted == "yes":
		lines.append("브라우저가 이 사이트의 저장 공간을 보호하고 있어요(사이트 데이터 삭제 시에는 사라져요).")
	var summary := _label("\n".join(lines), 10)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rows.add_child(summary)
	var extra := HFlowContainer.new()
	extra.add_theme_constant_override("h_separation", 6)
	_rows.add_child(extra)
	var list: Array = notice.get("actions", []).duplicate()
	if OS.has_feature("web"):
		list.append({"id": "download", "label": "파일로 내려받기", "enabled": true})
		if persisted in ["no", ""]:
			list.append({"id": "persist", "label": "저장 공간 보호 요청", "enabled": true})
	_fill_save_actions(extra, list)
	_save_tab_key = _save_notice_key(notice)

func _on_save_input_changed() -> void:
	_save_draft = _save_input.text

func _import_save() -> void:
	if _save_input.text.strip_edges().is_empty():
		_show_feedback("가져올 저장 JSON을 입력하세요.")
		return
	_workshop.call("import_save", _save_input.text)

func _export_save() -> void:
	var exported := str(_workshop.call("export_save"))
	if exported.is_empty():
		_show_feedback("내보낼 저장 데이터가 없어요.")
		return
	_save_input.text = exported
	_save_draft = exported
	_select_save_text()
	_show_feedback("선택된 저장 텍스트를 복사할 수 있어요.")

func _download_save() -> void:
	if not bool(_workshop.call("download_save")):
		_show_feedback("내보낼 저장 데이터가 없어요.")

func _select_save_text() -> void:
	_save_input.grab_focus()
	_save_input.select_all()

func _add_toggle(actions: VBoxContainer, caption: String, method: String, id: String, enabled: bool) -> void:
	var toggle := CheckButton.new()
	toggle.text = caption
	toggle.custom_minimum_size.y = 24
	toggle.set_pressed_no_signal(enabled)
	for style in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		toggle.add_theme_color_override(style, PAPER)
	var key := "%s:%s" % [method, id]
	toggle.set_meta("row_id", key)
	_buttons_by_id[key] = toggle
	toggle.toggled.connect(_toggle_automation.bind(method, id))
	actions.add_child(toggle)

func _toggle_automation(enabled: bool, method: String, id: String) -> void:
	_workshop.call(method, id, enabled)
	_schedule_refresh()

func _add_craft_target(actions: VBoxContainer, id: String, target: int) -> void:
	var field := LineEdit.new()
	field.placeholder_text = "목표 (0 = 무제한)"
	field.custom_minimum_size = Vector2(100, 25)
	field.max_length = 6
	field.text = str(target)
	field.set_meta("craft_target", true)
	field.text_submitted.connect(func(_text: String) -> void: field.release_focus())
	field.focus_exited.connect(_commit_craft_target.bind(field, id, target))
	actions.add_child(field)

func _commit_craft_target(field: LineEdit, id: String, previous: int) -> void:
	var value := field.text.strip_edges()
	if not value.is_empty() and not value.is_valid_int():
		field.text = str(previous)
		_show_feedback("목표 수량은 숫자로 입력하세요.")
		return
	var amount := clampi(int(value), 0, 999999)
	if amount != previous:
		_workshop.call("set_craft_target", id, amount)
	_schedule_refresh()

func _add_row(title: String, details: String, action := "", method := "", id := "", available := true) -> VBoxContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color("352d27"), Color("514236"), 4))
	_rows.add_child(card)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 6)
	card.add_child(line)
	var text_column := VBoxContainer.new()
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_column.add_theme_constant_override("separation", 2)
	line.add_child(text_column)
	var heading := _label(title, 12)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_column.add_child(heading)
	var description := _label(details, 10)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.add_theme_color_override("font_color", MUTED)
	text_column.add_child(description)
	var actions := VBoxContainer.new()
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(actions)
	if not action.is_empty():
		var button := _button(action, _perform.bind(method, id))
		button.custom_minimum_size = Vector2(48, 27)
		button.disabled = not available
		button.set_meta("row_id", id)
		_buttons_by_id[id] = button
		actions.add_child(button)
	return actions

func _perform(method: String, id: String) -> void:
	_workshop.call(method, id)

func _perform2(method: String, id: String, value: String) -> void:
	_workshop.call(method, id, value)

## The 채굴 tab (web 채굴 panel): the next step, the base, the found veins and the mining lines.
func _render_mining(mining: Dictionary, hint: String, inventory: Dictionary, gold: float) -> void:
	if mining.is_empty():
		return
	if not hint.is_empty():
		var tip := _label(hint, 10)
		tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tip.add_theme_color_override("font_color", Color("f1c577"))
		_rows.add_child(tip)
	var base: Dictionary = mining.base
	var next: Dictionary = base.get("next", {})
	var where := "위치 (%d, %d) · 인부 정원 %d명" % [int(base.x), int(base.y), int(base.worker_cap)]
	if next.is_empty():
		_add_row("거점 Lv.%d" % int(base.level), where + " · 모든 지역을 개척했어요.")
	else:
		var cost: Dictionary = next.cost
		_add_row("거점 Lv.%d" % int(base.level), where + " · 다음 지역 확장: %s (%s)" % [next.name, _cost_text(cost)],
			"확장", "expand_base", "expand_base", gold >= float(cost.gold) and _has_items(inventory, cost.products))
	_rows.add_child(_label("월드 광맥", 12))
	var veins: Array = mining.get("veins", [])
	if veins.is_empty() and int(mining.get("hidden", 0)) == 0:
		_rows.add_child(_label("아직 발견된 광맥이 없어요.", 10))
	for vein: Dictionary in veins:
		var secured := str(vein.action) == "mine"
		var details := "위치 (%d, %d) · 등급 %d · 채굴력 %d · %s초당 +%s" % [int(vein.x), int(vein.y), int(vein.grade), int(vein.power),
			"확보 완료 · " if secured else "미확보 · 확보하면 ", format_quantity(float(vein.rate))]
		var caption := "확보됨" if secured else ("잠김 · %s 해금 필요" % vein.site_name if vein.action == "locked" else "광맥 확보")
		var actions := _add_row(str(vein.name), details, caption, "secure_vein", str(vein.id), str(vein.action) == "secure")
		var mine_button := _button("채굴하기 (+%s)" % format_quantity(float(vein.haul)), _perform.bind("mine_vein", str(vein.id)))
		mine_button.disabled = not secured
		actions.add_child(mine_button)
	if int(mining.get("hidden", 0)) > 0:
		var note := _label("미발견 광맥 %d개 — 걸어 다니며 가까이 가면 발견돼요." % int(mining.hidden), 10)
		note.add_theme_color_override("font_color", MUTED)
		_rows.add_child(note)
	_rows.add_child(_label("채굴장", 12))
	for group: Dictionary in mining.get("lines", []):
		if not group.unlocked:
			var names := PackedStringArray()
			for row: Dictionary in group.resources:
				names.append(str(row.name))
			var text := "아직 탐사하지 않은 채굴장이에요. 고유 광물: %s" % ", ".join(names)
			if not group.recipes.is_empty():
				text += " · 관련 제작품: " + ", ".join(PackedStringArray(group.recipes))
			var cost: Dictionary = group.cost
			_add_row("잠김 · " + str(group.name), text, "탐사 (%s)" % _cost_text(cost), "open_site", str(group.id),
				gold >= float(cost.gold) and _has_items(inventory, cost.products))
			continue
		for row: Dictionary in group.resources:
			var auto := float(row.auto)
			var rate := "자동 +%.1f/초" % auto if auto > 0.0 else "수동 채굴만 가능"
			var actions := _add_row("%s · %s" % [group.name, row.name], "보유 %s · %s" % [format_quantity(float(row.amount)), rate],
				"채굴 +%.1f" % float(row.manual), "mine", str(row.id), true)
			for kind: String in ["facility", "workforce"]:
				var lever: Dictionary = row[kind]
				var at_max := int(lever.level) >= int(lever.max)
				var label := "채굴 도구" if kind == "facility" else "인력"
				var button := _button("%s Lv.%d · %s" % [label, int(lever.level), "최대" if at_max else "%s %d개" % [row.name, int(lever.cost)]],
					_perform.bind("upgrade", "%s:%s" % [kind, row.id]))
				button.disabled = at_max or float(row.amount) < float(lever.cost)
				actions.add_child(button)

func _cost_text(cost: Dictionary) -> String:
	var text := "%s G" % format_quantity(float(cost.get("gold", 0)))
	var parts: Dictionary = cost.get("products", {})
	if not parts.is_empty():
		text += " + " + _describe_items(parts)
	return text

func _show_save_status(status: String) -> void:
	if not is_instance_valid(_save_indicator):
		return
	var label: String = SAVE_LABELS.get(status, "")
	var detail := str(_workshop.get("save_detail")) if is_instance_valid(_workshop) else ""
	if status == "loading" and not detail.is_empty():
		label += " (%s)" % detail
	var attention := status in SAVE_ATTENTION
	for indicator in [_save_indicator, _panel_save_indicator]:
		indicator.text = label
		indicator.add_theme_color_override("font_color", Color("ffc18c") if attention else PAPER)
	# Keep the import UI and its draft visible until the transaction answers.
	_overlay.process_mode = Node.PROCESS_MODE_DISABLED if status == "importing" else Node.PROCESS_MODE_INHERIT
	_update_recovery()
	# Re-render the save tab only when what it offers changed, not on every routine save, so a
	# selection being copied is not lost.
	if is_workshop_open() and _active_tab == TAB_SAVE and _workshop.has_method("save_notice"):
		if _save_notice_key(_workshop.call("save_notice")) != _save_tab_key:
			_rerender_save_tab()

# --- save recovery ------------------------------------------------------------------------------------

func _build_recovery(surface: Control) -> void:
	_recovery = ColorRect.new()
	_recovery.color = Color(0.03, 0.03, 0.04, 0.78)
	_recovery.mouse_filter = Control.MOUSE_FILTER_STOP
	_recovery.hide()
	surface.add_child(_recovery)
	_recovery.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color("2c2420"), Color("e0a36b"), 8))
	_recovery.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 24
	panel.offset_top = 18
	panel.offset_right = -24
	panel.offset_bottom = -18
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 6)
	panel.add_child(layout)
	_recovery_title = _label("", 14)
	_recovery_title.add_theme_color_override("font_color", Color("ffc18c"))
	layout.add_child(_recovery_title)
	_recovery_message = _label("", 11)
	_recovery_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_recovery_message)
	_recovery_actions = HFlowContainer.new()
	_recovery_actions.add_theme_constant_override("h_separation", 6)
	_recovery_actions.add_theme_constant_override("v_separation", 4)
	layout.add_child(_recovery_actions)
	_recovery_text = TextEdit.new()
	_recovery_text.editable = false
	_recovery_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_recovery_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_recovery_text.add_theme_font_size_override("font_size", 10)
	_recovery_text.placeholder_text = "내보낸 저장이 여기에 나타나요. 전체 선택 후 복사해 보관하세요."
	_recovery_text.hide()
	layout.add_child(_recovery_text)

func _update_recovery() -> void:
	if not is_instance_valid(_recovery) or not is_instance_valid(_workshop) or not _workshop.has_method("save_notice"):
		return
	var notice: Dictionary = _workshop.call("save_notice")
	if not bool(notice.get("modal", false)):
		_recovery.hide()
		_recovery_status = ""
		_recovery_text.text = ""
		_recovery_text.hide()
		return
	if is_workshop_open():
		close_workshop()
	if _recovery_status != str(notice.status):
		_recovery_text.text = ""
		_recovery_text.hide()
	_recovery_status = str(notice.status)
	_recovery_title.text = str(notice.title)
	_recovery_message.text = str(notice.message)
	_fill_save_actions(_recovery_actions, notice.get("actions", []))
	_recovery.show()

func _fill_save_actions(container: Container, actions: Array) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()
	for action: Dictionary in actions:
		var button := _button(str(action.label), _on_save_action.bind(str(action.id), container == _recovery_actions))
		button.disabled = not bool(action.get("enabled", true))
		button.set_meta("save_action", str(action.id))
		container.add_child(button)

func _on_save_action(id: String, from_recovery: bool) -> void:
	if id == "download":
		_download_save()
		return
	var text := str(_workshop.call("save_action", id))
	if text.is_empty():
		_update_recovery()
		return
	if from_recovery:
		_recovery_text.text = text
		_recovery_text.show()
		_recovery_text.grab_focus()
		_recovery_text.select_all()
	elif is_instance_valid(_save_input):
		_save_input.text = text
		_save_draft = text
		_select_save_text()
	_show_feedback("선택된 저장 텍스트를 복사해 보관하세요." + (" 파일로도 내려받았어요." if OS.has_feature("web") and id == "export_raw" else ""))
	_update_recovery()

func _save_notice_key(notice: Dictionary) -> String:
	var status := str(notice.get("status", ""))
	if status in ["pending", "saving", "saved", "importing", "loading", "idle"]:
		status = "ok"
	return status + "|" + JSON.stringify(notice.get("actions", [])) + "|" + str(_workshop.get("storage_persisted"))

func _rerender_save_tab() -> void:
	_save_input = null
	_refresh(true)

## The last messages, newest first (web log(): the 기록 list keeps 40).
var _log: Array[String] = []

func _show_feedback(message: String) -> void:
	if not message.is_empty():
		_log.push_front(message)
		if _log.size() > 40:
			_log.resize(40)
	if not is_node_ready():
		return
	if is_workshop_open():
		_panel_note.text = message
	else:
		_toast_text.text = message
		_toast.visible = not message.is_empty()
		_toast_timer.start(2.6)

func _item_id(item: Dictionary) -> String:
	return str(item.get("id", item.get("key", "")))

func _name_for(id: String) -> String:
	return str(_names.get(id, id))

func _has_items(inventory: Dictionary, required: Dictionary) -> bool:
	for id in required:
		if int(inventory.get(id, 0)) < int(required[id]):
			return false
	return true

func _describe_items(items: Dictionary) -> String:
	if items.is_empty():
		return "재료 없음"
	var parts := PackedStringArray()
	for id in items:
		parts.append("%s %d개" % [_name_for(str(id)), int(items[id])])
	return ", ".join(parts)

func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	return label

func _button(value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 24
	button.pressed.connect(callback)
	return button

func _make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = preload("res://fonts/Galmuri9.ttf")
	theme.default_font_size = 11
	theme.set_color("font_color", "Label", PAPER)
	theme.set_color("font_color", "Button", PAPER)
	theme.set_color("font_hover_color", "Button", PAPER)
	theme.set_color("font_pressed_color", "Button", Color("fff4e1"))
	theme.set_color("font_focus_color", "Button", PAPER)
	theme.set_color("font_disabled_color", "Button", Color("a39282"))
	theme.set_stylebox("panel", "PanelContainer", _box(Color("292521"), Color("695241"), 3))
	theme.set_stylebox("normal", "Button", _box(Color("4b392d"), Color("866349"), 3))
	theme.set_stylebox("hover", "Button", _box(Color("604737"), Color("c39668"), 3))
	theme.set_stylebox("pressed", "Button", _box(Color("76563e"), Color("e4b77d"), 3))
	theme.set_stylebox("disabled", "Button", _box(Color("372d26"), Color("635044"), 3))
	theme.set_stylebox("focus", "Button", _box(Color.TRANSPARENT, Color("efc47d"), 3))
	return theme

func _box(fill: Color, border: Color, padding: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		box.set_content_margin(side, padding)
	return box

func _render_tunnel(tunnel: Dictionary, completed: Dictionary, inventory: Dictionary, gold: float) -> void:
	if tunnel.is_empty():
		return
	if tunnel.open:
		_add_row("산맥 터널", "개통 완료 · 산 너머로 걸어갈 수 있어요.")
	elif bool(tunnel.get("building", int(tunnel.remaining) > 0)):
		var left := int(tunnel.remaining)
		_add_row("터널 공사 중", "%d:%02d 남음 · 게임을 꺼 두어도 공사는 계속돼요." % [left / 60, left % 60])
	else:
		var cost: Dictionary = tunnel.cost
		_add_row("터널 공사 의뢰", "%d G · %s · %d초 · 터널 굴착 연구 필요" % [cost.COMMISSION_GOLD, _describe_items(cost.COMMISSION_PRODUCTS), cost.DURATION_SEC],
			"의뢰", "order_tunnel", "tunnel", bool(completed.get("tunnelWork", false)) and gold >= cost.COMMISSION_GOLD and _has_items(inventory, cost.COMMISSION_PRODUCTS))
