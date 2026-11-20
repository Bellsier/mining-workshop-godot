extends SceneTree
## The menu's redraws keep controls without keeping stale behaviour (workshop_hud.gd _reconcile_rows, _same_shape,
## _patch):
##   godot --headless --path . --fixed-fps 60 --script res://tools/hud_reconcile_test.gd
## 1. On every tab, the game moves on (research, upgrades, a hut and its recipe, a worker, deliveries, the village)
##    while the menu redraws by keeping rows. Then every control's handlers (pressed, toggled, item_selected,
##    text_submitted, focus_exited, text_changed: the method and the values bound to it) and its text, availability
##    and choice are compared with a full redraw of the same state: a kept control must act as a new one would.
## 2. 300 random lists (rows put in, taken out, moved, retitled, gaining or losing a button, a picker gaining an
##    item, a button turning unavailable): after a redraw the list shows exactly the new rows in the new order,
##    rows of the same shape are the same objects, and nothing is left over.
## Prints "HUD RECONCILE PASS" and exits 0, or the failures and exits 1.

const World = preload("res://scripts/world/world_state.gd")

var game: Node
var eco: Node
var hud: Node
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("HUD RECONCILE FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	root.size = Vector2i(960, 540)
	game = root.get_node("Game")
	eco = game.workshop
	hud = game._hud
	eco._restore({"world": World.new_game(42).to_dict(), "gold": 500000.0,
		"completed_research": {"workshopBuild": true, "autoCraftDevice": true, "deliveryContract": true},
		"inventory": {"steel": 500.0, "coalBrick": 500.0, "iron": 500.0, "coal": 500.0, "ironTool": 50.0},
		"characters": [{"id": "w_one", "rarity": "common", "resource": "iron", "mining": 1, "carry": 1, "move": 1}]})
	eco._ensure_village()
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	await _kept_controls_act_as_new()
	_random_lists()
	if _failures.is_empty():
		print("HUD RECONCILE PASS")
		quit(0)
	else:
		print("HUD RECONCILE FAIL %d" % _failures.size())
		quit(1)


# --- 1. kept controls act as new ones -------------------------------------------------------------------------

const SIGNALS := ["pressed", "toggled", "item_selected", "text_submitted", "focus_exited", "text_changed"]


## Every control of the list by its place (row key, then child indexes): its kind, values and handlers.
func _describe_list() -> Dictionary:
	var out := {}
	var seen := {}
	for row in hud._rows.get_children():
		if row.is_queued_for_deletion():
			continue
		var key: String = hud._row_key(row)
		seen[key] = int(seen.get(key, 0)) + 1
		_describe(row, "%s#%d" % [key, seen[key]], out)
	return out


func _describe(node: Node, path: String, out: Dictionary) -> void:
	var d := {"kind": node.get_class()}
	if node is Label or node is Button or node is LineEdit:
		d.text = str(node.text)
	if node is BaseButton:
		d.disabled = node.disabled
		d.pressed = node.button_pressed if node.toggle_mode else false
	if node is OptionButton:
		d.selected = node.selected
		d.items = range(node.item_count).map(func(i: int) -> String: return node.get_item_text(i))
	var handlers: Array = []
	for sig in SIGNALS:
		if node.has_signal(sig):
			for c: Dictionary in node.get_signal_connection_list(sig):
				var cb: Callable = c.callable
				if cb.get_object() == hud:
					# A handler bound to its own control (a field committing itself) names it "self".
					var bound: Array = cb.get_bound_arguments().map(func(a: Variant) -> Variant:
						return "self" if typeof(a) == TYPE_OBJECT and a == node else (a.get_class() if typeof(a) == TYPE_OBJECT else a))
					handlers.append("%s:%s%s" % [sig, cb.get_method(), bound])
	if node is OptionButton:
		for c: Dictionary in node.get_popup().get_signal_connection_list("popup_hide"):
			if c.callable.get_object() == hud:
				handlers.append("popup_hide:" + c.callable.get_method())
	handlers.sort()
	d.handlers = handlers
	out[path] = d
	var k := 0
	for child in node.get_children():
		_describe(child, "%s/%d" % [path, k], out)
		k += 1


## Lets the menu redraw by keeping rows while `step` changes the game, then compares with a full redraw.
func _compare(tab: String, steps: Array) -> void:
	hud.open_tab(tab)
	await _frames(4)
	var full_before: int = hud.redraw_stats.full
	for step: Callable in steps:
		step.call()
		eco.changed.emit()
		await _frames(3)
	_check(hud.redraw_stats.full == full_before, "%s: the redraws kept the rows (no full redraw)" % tab)
	# The same state for both: the game is held still, the kept list redrawn once more, then a full redraw.
	eco.set_process(false)
	hud._refresh(true)
	await _frames(1)
	_check(hud.redraw_stats.full == full_before, "%s: that redraw kept the rows too" % tab)
	var kept := _describe_list()
	hud._rendered_tab = -1 # a full redraw of the same state
	hud._refresh(true)
	await _frames(2)
	var fresh := _describe_list()
	eco.set_process(true)
	_check(kept.keys() == fresh.keys(), "%s: the kept list has the same controls as a full redraw (%d vs %d)" % [tab, kept.size(), fresh.size()])
	for path: String in fresh:
		if kept.get(path) != fresh[path]:
			_check(false, "%s: %s kept %s, a full redraw has %s" % [tab, path, kept.get(path), fresh[path]])
			break


func _kept_controls_act_as_new() -> void:
	await _compare("craft", [
		func() -> void: eco.build_hut(),
		func() -> void: eco.set_hut_recipe(str(eco.world.workshops[0].id), "steel"),
		func() -> void: eco.set_hut_auto(str(eco.world.workshops[0].id), true),
		func() -> void: eco.set_auto_craft("coalBrick", true),
		func() -> void: eco.set_craft_target("coalBrick", 30),
		func() -> void: eco.state.inventory["iron"] = 0.0, # recipes turn unavailable
		func() -> void: eco.state.inventory["iron"] = 500.0,
		func() -> void: eco.upgrade("hq_level"),
		func() -> void: eco.build_hut(),
	])
	await _compare("sell", [
		func() -> void: eco.sell("steel"),
		func() -> void: eco.buy_auto_sell("coalBrick"),
		func() -> void: eco.set_auto_sell("coalBrick", true),
		func() -> void: eco.state.inventory["steel"] = 3.0,
	])
	await _compare("workers", [
		func() -> void: eco.assign_worker("w_one", "coal"),
		func() -> void: eco.upgrade_worker("w_one", "mining"),
		func() -> void: eco.state.gold = 10.0, # upgrades turn unavailable
		func() -> void: eco.state.gold = 500000.0,
	])
	await _compare("research", [
		func() -> void: eco.unlock("tunnelWork"),
		func() -> void: eco.state.gold = 100.0,
		func() -> void: eco.state.gold = 500000.0,
	])
	await _compare("delivery", [
		func() -> void: eco.ship_free("forge", "steel", 5),
		func() -> void: hud._ship_choice["forge"] = {"product": "coalBrick", "qty": 3},
		func() -> void: eco.state.inventory["coalBrick"] = 1.0,
	])
	await _compare("village", [
		func() -> void: eco.restore_facility("appraiser"),
		func() -> void: eco.restore_facility("appraiser"),
		func() -> void: eco.state.inventory["relic"] = 2.0,
	])
	await _compare("mining", [
		func() -> void: eco.state.inventory["iron"] = 1.0,
		func() -> void: eco.state.inventory["iron"] = 900.0,
	])
	hud.close_workshop()
	await _frames(2)


# --- 2. random lists ------------------------------------------------------------------------------------------

## A row as the menu draws it: a card titled `title`, with a 제작 button (id) when `button`, available or not,
## and a picker offering `items` when there are any.
func _row(spec: Dictionary) -> Control:
	var keep: Control = hud._rows
	var holder := VBoxContainer.new()
	hud._rows = holder
	var actions: VBoxContainer
	if spec.button:
		actions = hud._add_row(spec.title, spec.details, "제작", "craft", spec.id, spec.available)
	else:
		actions = hud._add_row(spec.title, spec.details)
	if spec.items > 0:
		var picker := OptionButton.new()
		var keys := PackedStringArray()
		for i in spec.items:
			picker.add_item("항목 %d" % i)
			keys.append("k%d" % i)
		picker.set_meta("row_id", "pick:" + str(spec.id))
		hud._pick_on_release(picker, keys)
		actions.add_child(picker)
	hud._rows = keep
	var card: Control = holder.get_child(0)
	holder.remove_child(card)
	holder.free()
	return card


func _random_specs(rng: RandomNumberGenerator, from: Array) -> Array:
	var specs: Array = []
	for s: Dictionary in from:
		var roll := rng.randi_range(0, 9)
		if roll == 0:
			continue # taken out
		var t := s.duplicate()
		match roll:
			1: t.title = t.title + "!" # retitled
			2: t.details = "설명 %d" % rng.randi_range(0, 99)
			3: t.available = not t.available
			4: t.items += 1 # the picker offers one more
			5: t.button = not t.button
		specs.append(t)
	for k in rng.randi_range(0, 3): # put in
		var at := rng.randi_range(0, specs.size())
		specs.insert(at, {"id": "n%d" % rng.randi(), "title": "새 행 %d" % rng.randi_range(0, 9), "details": "", "button": rng.randf() < 0.7,
			"available": true, "items": rng.randi_range(0, 2)})
	if specs.size() > 2 and rng.randf() < 0.3: # moved
		var a := rng.randi_range(0, specs.size() - 1)
		var b := rng.randi_range(0, specs.size() - 1)
		var tmp = specs[a]
		specs[a] = specs[b]
		specs[b] = tmp
	return specs


func _random_lists() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261120
	var live := VBoxContainer.new()
	root.add_child(live)
	var specs: Array = []
	for i in 8:
		specs.append({"id": "r%d" % i, "title": "행 %d" % i, "details": "", "button": i % 3 != 0, "available": true, "items": i % 4})
	for s: Dictionary in specs:
		live.add_child(_row(s))
	var bad := 0
	var patched_before: int = hud.redraw_stats.patched
	for round_ in 300:
		var next := _random_specs(rng, specs)
		var before := {}
		for row in live.get_children():
			before[hud._row_key(row)] = row
		var fresh := VBoxContainer.new()
		for s: Dictionary in next:
			fresh.add_child(_row(s))
		var want: Array = fresh.get_children().map(func(r: Node) -> String: return JSON.stringify(_shape_and_values(r)))
		var want_keys: Array = fresh.get_children().map(func(r: Node) -> String: return hud._row_key(r))
		hud._stale_rows = false
		hud._reconcile_rows(live, fresh, false, null)
		var rows := live.get_children().filter(func(r: Node) -> bool: return not r.is_queued_for_deletion())
		var got: Array = rows.map(func(r: Node) -> String: return JSON.stringify(_shape_and_values(r)))
		if got != want:
			bad += 1
			if bad <= 3:
				_check(false, "round %d: the list shows the new rows in the new order\n   got  %s\n   want %s" % [round_, rows.map(hud._row_key), want_keys])
		fresh.free()
		specs = next
	_check(bad == 0, "random lists: %d of 300 redraws differ from the new rows" % bad)
	_check(hud.redraw_stats.patched - patched_before > 300, "random lists: rows were kept and updated, not only rebuilt (%d kept)" % (hud.redraw_stats.patched - patched_before))
	live.queue_free()


## A row's kinds, texts, availability and picker items, as shown.
func _shape_and_values(node: Node) -> Array:
	var out: Array = [node.get_class()]
	if node is Label or (node is Button and not node is OptionButton):
		out.append(node.text)
	if node is BaseButton:
		out.append(node.disabled)
	if node is OptionButton:
		out.append(range(node.item_count).map(func(i: int) -> String: return node.get_item_text(i)))
		out.append(node.get_meta("keys"))
	for child in node.get_children():
		out.append(_shape_and_values(child))
	return out
