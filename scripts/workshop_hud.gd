extends CanvasLayer
## Inventory is available anywhere. The world controller opens the full menu at the workshop.

enum { TAB_INVENTORY, TAB_CRAFT, TAB_SELL, TAB_WORKERS, TAB_RESEARCH, TAB_DELIVERY, TAB_VILLAGE, TAB_SAVE }

const TABS := ["가방", "제작", "판매", "인부", "연구", "납품", "마을", "저장"]
const PAPER := Color("f5e5ce")
const MUTED := Color("d3bda0")

var _workshop: Node
var _theme: Theme
var _bar: PanelContainer
var _gold: Label
var _inventory_button: Button
var _action: Button
var _action_label := ""
var _action_callback := Callable()
var _context_hint: Label
var _context_hint_text := ""
var _overlay: ColorRect
var _title: Label
var _panel_gold: Label
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

func setup(workshop: Node) -> void:
	if is_instance_valid(_workshop):
		_workshop.disconnect("changed", _schedule_refresh)
		_workshop.disconnect("feedback", _show_feedback)
	_workshop = workshop
	_workshop.connect("changed", _schedule_refresh)
	_workshop.connect("feedback", _show_feedback)
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
	set_action(_action_label, _action_callback)
	set_context_hint(_context_hint_text)
	_refresh()

func open_workshop() -> void:
	_open(false)

func open_inventory() -> void:
	_open(true)

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
	_action.visible = not _action_label.is_empty()
	_context_hint.visible = not _context_hint_text.is_empty()

func is_workshop_open() -> bool:
	return is_instance_valid(_overlay) and _overlay.visible

func set_action(label: String, callback: Callable = Callable()) -> void:
	_action_label = label
	_action_callback = callback
	if is_instance_valid(_action):
		_action.text = label
		_action.visible = not label.is_empty() and not is_workshop_open()

func set_context_hint(message: String) -> void:
	_context_hint_text = message
	if is_instance_valid(_context_hint):
		_context_hint.text = message
		_context_hint.visible = not message.is_empty() and not is_workshop_open()

func _unhandled_key_input(event: InputEvent) -> void:
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
	if not is_node_ready() or not is_instance_valid(_workshop):
		return
	_active_tab = TAB_INVENTORY
	_title.text = "가방" if only_inventory else "공방"
	_panel_note.text = ""
	for index in range(_tab_buttons.size()):
		_tab_buttons[index].visible = not only_inventory or index in [TAB_INVENTORY, TAB_SAVE]
	_bar.hide()
	_action.hide()
	_context_hint.hide()
	_toast.hide()
	_overlay.show()
	_tab_buttons[0].set_pressed_no_signal(true)
	_scroll.scroll_vertical = 0
	_refresh(true)

func _build_bar(surface: Control) -> void:
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
	var state: Dictionary = _workshop.call("snapshot")
	var gold := int(state.get("gold", 0))
	_gold.text = "%d G" % gold
	_panel_gold.text = _gold.text
	if not is_workshop_open():
		return
	if _active_tab == TAB_SAVE and is_instance_valid(_save_input):
		return
	var focused := get_viewport().gui_get_focus_owner()
	if not force and focused is LineEdit and focused.has_meta("craft_target"):
		return
	if not force:
		if _active_tab == TAB_WORKERS:
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
		TAB_INVENTORY: _render_inventory(inventory)
		TAB_CRAFT: _render_recipes(recipes, inventory, automation, bool(state.get("completed_research", {}).get("autoCraftDevice", false)))
		TAB_SELL: _render_sales(resources, products, recipes, inventory, automation, gold)
		TAB_WORKERS: _render_workers(state.get("workers", []), state.get("worker_details", []), resources, gold)
		TAB_RESEARCH:
			_render_research(state.get("research", []), state.get("completed_research", {}), inventory, gold)
			_render_sites(state.get("sites", []), inventory, gold)
			_render_upgrades(state.get("upgrades", []), inventory, gold)
		TAB_DELIVERY: _render_deliveries(state.get("deliveries", state.get("delivery_offers", [])), int(state.get("reputation", 0)))
		TAB_VILLAGE: _render_village(state.get("village", {}), inventory, gold)
		TAB_SAVE: _render_save()
	if _rows.get_child_count() == 0:
		_rows.add_child(_label("가방에 아이템이 없어요." if _active_tab == TAB_INVENTORY else "지금 가능한 항목이 없어요.", 11))
	_scroll.set_deferred("scroll_vertical", scroll_position)
	var previous_button: BaseButton = _buttons_by_id.get(focused_row)
	if is_instance_valid(previous_button) and not previous_button.disabled:
		previous_button.grab_focus.call_deferred()

func _panel_key(state: Dictionary, inventory: Dictionary, recipes: Array, gold: int) -> String:
	if _active_tab == TAB_WORKERS:
		return JSON.stringify([gold, state.get("workers", []), state.get("worker_details", []), state.get("resources", [])])
	if _active_tab == TAB_DELIVERY:
		return JSON.stringify([state.get("reputation", 0), state.get("deliveries", state.get("delivery_offers", []))])
	var visible_quantities := {}
	for id in inventory:
		var quantity := floori(float(inventory[id]))
		if quantity > 0:
			visible_quantities[id] = quantity
	var automation: Dictionary = state.get("automation", {})
	var completed: Dictionary = state.get("completed_research", {})
	match _active_tab:
		TAB_INVENTORY: return JSON.stringify(visible_quantities)
		TAB_CRAFT:
			var remaining := []
			for recipe in recipes:
				remaining.append(ceili(float(recipe.get("remaining", 0))))
			return JSON.stringify([visible_quantities, automation, completed, remaining])
		TAB_SELL: return JSON.stringify([visible_quantities, automation, gold])
		TAB_RESEARCH: return JSON.stringify([visible_quantities, completed, state.get("sites", []), state.get("upgrades", []), gold])
		TAB_VILLAGE: return JSON.stringify([visible_quantities, state.get("village", {}), gold])
	return str(_active_tab)

func _render_inventory(inventory: Dictionary) -> void:
	for key in inventory:
		var quantity := int(inventory[key])
		if quantity > 0:
			_add_row(_name_for(str(key)), "%d개" % quantity)

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
		var ready := seconds == 0 and bool(recipe.get("available", true)) and _has_items(inventory, inputs)
		var description := "%s  →  %d개" % [_describe_items(inputs), count]
		if seconds > 0:
			description += " · %d초 남음" % seconds
		var actions := _add_row(_name_for(id), description, "제작", "craft", id, ready)
		if auto_craft_unlocked and automation.has("craft") and _workshop.has_method("set_auto_craft"):
			_add_toggle(actions, "자동 제작", "set_auto_craft", id, bool(auto_craft.get(id, false)))
			if _workshop.has_method("set_craft_target"):
				_add_craft_target(actions, id, int(targets.get(id, 0)))

func _render_sales(resources: Array, products: Array, recipes: Array, inventory: Dictionary, automation: Dictionary, gold: int) -> void:
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
		var quantity := int(inventory.get(id, 0))
		var actions := _add_row(_name_for(id), "보유 %d개 · 개당 %d G" % [quantity, prices[key]], "전량 판매", "sell", id, quantity > 0)
		if bool(licenses.get(id, false)) and _workshop.has_method("set_auto_sell"):
			_add_toggle(actions, "자동 판매", "set_auto_sell", id, bool(auto_sell.get(id, false)))
		elif costs != null and _workshop.has_method("buy_auto_sell"):
			var cost := int(costs.get(id, -1)) if costs is Dictionary else int(costs)
			if cost >= 0:
				var buy := _button("자동 판매 열기 · %d G" % cost, _perform.bind("buy_auto_sell", id))
				buy.disabled = gold < cost
				actions.add_child(buy)

func _render_workers(workers: Array, assigned: Array, resources: Array, gold: int) -> void:
	_rows.add_child(_label("고용 인부 %d명" % assigned.size(), 11))
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
		var actions := _add_row(str(worker.get("rating", "")) + " 인부", "배치 · " + _name_for(assigned_to))
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

func _render_research(research: Array, completed: Dictionary, inventory: Dictionary, gold: int) -> void:
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

func _render_sites(sites: Array, inventory: Dictionary, gold: int) -> void:
	if sites.is_empty() or not _workshop.has_method("open_site"):
		return
	_rows.add_child(_label("채굴 지역", 12))
	for site in sites:
		var id := _item_id(site)
		var title := str(site.get("name", id))
		if bool(site.get("unlocked", false)):
			_add_row(title, "열림")
			continue
		var cost: Variant = site.get("cost", 0)
		var money := int(cost.get("gold", 0)) if cost is Dictionary else int(cost)
		var needs: Dictionary = cost.get("products", {}) if cost is Dictionary else {}
		var details := "%d G" % money
		if not needs.is_empty():
			details += " · " + _describe_items(needs)
		var ready := gold >= money and _has_items(inventory, needs) and bool(site.get("available", true))
		_add_row(title, details, "열기", "open_site", id, ready)

func _render_deliveries(deliveries: Array, reputation: int) -> void:
	_rows.add_child(_label("납품 평판 %d" % reputation, 11))
	if deliveries.is_empty():
		_rows.add_child(_label("지금 가능한 납품이 없어요.", 11))
	for delivery in deliveries:
		var id := _item_id(delivery)
		var product_id := str(delivery.get("product", ""))
		var description := "%s %d개 · 배송비 %d G · 보상 %d G" % [
			str(delivery.get("product_name", _name_for(product_id))), int(delivery.get("qty", 0)),
			int(delivery.get("shipping_cost", 0)), int(delivery.get("gold_reward", 0)),
		]
		var company := str(delivery.get("company_name", delivery.get("company_id", "납품")))
		_add_row(company, description, "납품", "deliver", id, bool(delivery.get("can_complete", false)))

func _render_upgrades(upgrades: Array, inventory: Dictionary, gold: int) -> void:
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

func _render_village(village: Dictionary, inventory: Dictionary, gold: int) -> void:
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

func _show_feedback(message: String) -> void:
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
