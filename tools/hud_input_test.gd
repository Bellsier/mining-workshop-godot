extends SceneTree
## The workshop menu acts on what the player did, through the real GUI input path (QA-01, QA-02, QA-04, QA-05):
##   godot --headless --path . --fixed-fps 60 --script res://tools/hud_input_test.gd
## Mouse input is pushed into the viewport; touch goes through Input, which turns the finger into mouse events as
## a browser's touch does. The game keeps producing and auto-selling all along, so the menu keeps redrawing.
##
## 납품 · free delivery (QA-01, QA-02)
##   - 1 → 5 typed, 자유 납품 clicked (and tapped) at once without Enter: 5 are shipped, the shipping cost and score
##     are the ones the preview showed;
##   - Enter, then 자유 납품; Tab to the button, then Enter: 5 shipped each time, the button keeps the focus;
##   - 5 typed on product A, product B picked: still 5, and 5 of B are shipped;
##   - "abc", "", "0" and "-3" ship nothing (the field shows the number it would become); more than in stock ships
##     nothing; two presses in one frame ship once; quick repeats by mouse, finger and Enter each ship; stock gone
##     between the press and the shipment ships nothing.
## 판매 · 연구 · 마을 · held presses (QA-05)
##   - 전량 판매, 터널 굴착 연구 and 잔해 치우기 held 100, 300 and 500 ms while gold and stock change: each acts
##     exactly once on release;
##   - a button that becomes unavailable while held does not act; switching the tab or closing the menu during a
##     press acts on nothing.
## Kept as before
##   - a worker's picker list stays open while the game redraws the menu, and picking moves the worker (and a save
##     keeps it); the save tab's pasted draft survives redraws and a trip to another tab.
## Save tab after an import
##   - a failed import leaves the draft as it was, unmarked;
##   - after a successful file import the draft (an earlier export) stays, marked as not the game's save; 가져오기
##     with it asks first and imports on the second press; editing it drops the mark and keeps the focus.
## Swipes (QA-04, phone screen 568×320)
##   - a finger moved over a card's text, a button or a picker scrolls the list and presses nothing, opens nothing;
##   - a tap on a button acts once, a tap on a picker opens its list; the scroll bar still drags; a mouse drag
##     scrolls too.
## Prints "HUD INPUT PASS" and exits 0, or the failures and exits 1.

const World = preload("res://scripts/world/world_state.gd")
const Save = preload("res://scripts/workshop_save.gd")
const Delivery = preload("res://scripts/workshop_delivery.gd")

var game: Node
var eco: Node
var hud: Node
var _failures: Array[String] = []
var _company := ""
var _keys := PackedStringArray()
var _churn := true


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("HUD INPUT FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


## Waits real time (headless frames run faster than the clock): at least `ms` and at least one frame.
func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	await process_frame
	while Time.get_ticks_msec() < until:
		await process_frame


func _process(_dt: float) -> bool:
	# The game keeps changing: gold and stock move every frame, as with auto-selling and production.
	if _churn and eco != null:
		eco.state.gold = float(eco.state.gold) + 1.0
		eco.state.inventory["steel"] = float(eco.state.inventory.get("steel", 0)) + 0.25
		eco.changed.emit()
	return false


# --- input ----------------------------------------------------------------------------------------------------

func _window(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _mouse_move(p: Vector2, held := false) -> void:
	var e := InputEventMouseMotion.new()
	e.position = _window(p)
	e.global_position = e.position
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(e)


func _mouse_button(p: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	e.position = _window(p)
	e.global_position = e.position
	root.push_input(e)


func _click(p: Vector2) -> void:
	_mouse_move(p)
	_mouse_button(p, true)
	_mouse_button(p, false)


## A finger: Input turns it into mouse events, as the browser's touch reaches the game.
func _touch(p: Vector2, pressed: bool) -> void:
	var e := InputEventScreenTouch.new()
	e.index = 0
	e.pressed = pressed
	e.position = _window(p)
	Input.parse_input_event(e)


func _touch_move(from: Vector2, to: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = 0
	e.position = _window(to)
	e.relative = _window(to) - _window(from)
	Input.parse_input_event(e)


func _tap(p: Vector2) -> void:
	_touch(p, true)
	await _frames(2)
	_touch(p, false)
	await _frames(2)


func _key(code: Key, unicode := 0) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.unicode = unicode
		e.pressed = pressed
		root.push_input(e)


func _type(text: String) -> void:
	for ch in text:
		_key(OS.find_keycode_from_string(ch) if ch != "-" else KEY_MINUS, ch.unicode_at(0))


func _center(c: Control) -> Vector2:
	return c.get_global_rect().get_center()


func _node(id: String) -> Control:
	var c := hud._buttons_by_id.get(id) as Control
	if c != null:
		return c
	# The same controls found by what they show, for a HUD that does not index them (a run on an older HUD shows
	# what this test catches there).
	for n in hud._rows.find_children("*", "Control", true, false):
		if n.is_queued_for_deletion():
			continue
		if str(n.get_meta("row_id", "")) == id:
			return n
		if id.begins_with("ship_qty:") and n is LineEdit and n.has_meta("target_input"):
			return n
		if id.begins_with("ship_send:") and n is Button and n.text == "자유 납품":
			return n
	return null


## Scrolls so the control sits in the middle of the list.
func _show(c: Control) -> void:
	var view: Rect2 = hud._scroll.get_global_rect()
	hud._scroll.scroll_vertical += int(c.get_global_rect().get_center().y - view.get_center().y)
	await _frames(3)


# --- the game -------------------------------------------------------------------------------------------------

func _run() -> void:
	root.size = Vector2i(960, 540)
	game = root.get_node("Game")
	eco = game.workshop
	hud = game._hud
	eco._restore({"world": World.new_game(42).to_dict(), "gold": 100000.0,
		"completed_research": {"workshopBuild": true, "autoCraftDevice": true, "deliveryContract": true},
		"inventory": {"steel": 200.0, "coalBrick": 200.0, "iron": 50.0, "coal": 50.0, "relic": 5.0},
		"characters": [{"id": "w_qa", "rarity": "common", "resource": "iron", "mining": 1, "carry": 1, "move": 1}]})
	eco._ensure_village()
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	await _free_delivery()
	await _held_presses()
	await _kept_features()
	await _save_tab_import()
	await _swipes()
	if _failures.is_empty():
		print("HUD INPUT PASS")
		quit(0)
	else:
		print("HUD INPUT FAIL %d" % _failures.size())
		quit(1)


func _score() -> float:
	return float(Delivery._company_progress(eco.data, eco.state)[_company].score)


func _sent(product: String) -> float:
	return float(Delivery._company_progress(eco.data, eco.state)[_company].sent.get(product, 0))


## Types into the company's quantity field (all its text replaced), focused by a click as a player does.
func _type_qty(text: String) -> void:
	var field: LineEdit = _node("ship_qty:" + _company)
	_click(_center(field))
	await _frames(2)
	field.select_all()
	if text.is_empty():
		_key(KEY_BACKSPACE)
	else:
		_type(text)
	await _frames(1)


func _ship_case(label: String, product: String, qty: int, send: Callable) -> void:
	var have := float(eco.state.inventory.get(product, 0))
	var sent := _sent(product)
	var gold_before := float(eco.state.gold)
	var score_before := _score()
	var preview: Dictionary = eco.delivery_preview(_company, product, qty)
	_churn = false # gold must move by the shipping cost alone here
	await send.call()
	await _frames(3)
	_churn = true
	_check(_sent(product) == sent + qty and float(eco.state.inventory.get(product, 0)) == have - qty,
		"%s: %d %s shipped (sent %s → %s)" % [label, qty, product, sent, _sent(product)])
	_check(is_equal_approx(gold_before - float(eco.state.gold), float(preview.cost)),
		"%s: the shipping cost is the preview's %s (gold %s → %s)" % [label, preview.cost, gold_before, eco.state.gold])
	_check(is_equal_approx(_score() - score_before, float(preview.score)), "%s: the score is the preview's %s (got %s)" % [label, preview.score, _score() - score_before])
	await _frames(3)


func _free_delivery() -> void:
	hud.open_tab("delivery")
	await _frames(4)
	for card: Dictionary in eco.snapshot().companies.companies:
		if card.open:
			_company = str(card.id)
			break
	_check(not _company.is_empty(), "a company is open for free delivery")
	var picker: OptionButton = _node("ship_product:" + _company)
	_keys = picker.get_meta("keys", PackedStringArray())
	if _keys.is_empty():
		for r: Dictionary in eco.snapshot().recipes:
			if not r.get("locked", false):
				_keys.append(str(r.id))
	var a := _keys[0]
	var b := _keys[1]
	await _show(picker)
	var send: Button = _node("ship_send:" + _company)

	# QA-01: 1 → 5 and an immediate click
	await _type_qty("5")
	var preview_line := _preview_text()
	var expected: Dictionary = eco.delivery_preview(_company, a, 5)
	_check(preview_line.contains("배송비 %d G" % int(expected.cost)), "typing 5 updates the preview at once (%s; want cost %s)" % [preview_line, expected.cost])
	await _ship_case("typed 5, clicked at once", a, 5, func() -> void: _click(_center(_node("ship_send:" + _company))))
	# … and an immediate tap
	await _type_qty("1")
	await _frames(2)
	await _type_qty("5")
	await _ship_case("typed 5, tapped at once", a, 5, func() -> void: await _tap(_center(_node("ship_send:" + _company))))
	# Enter, then the button
	await _type_qty("5")
	_key(KEY_ENTER)
	await _frames(3)
	await _ship_case("typed 5, Enter, clicked", a, 5, func() -> void: _click(_center(_node("ship_send:" + _company))))
	# Tab to the button, then Enter
	await _type_qty("5")
	_key(KEY_TAB)
	await _frames(4)
	send = _node("ship_send:" + _company)
	_check(send.has_focus(), "Tab moves to 자유 납품 and it keeps the focus through redraws (focus: %s)" % root.gui_get_focus_owner())
	await _ship_case("typed 5, Tab, Enter", a, 5, func() -> void: _key(KEY_ENTER))
	_check(_node("ship_send:" + _company).has_focus(), "자유 납품 still has the focus after shipping")

	# QA-02: the confirmed quantity is 1; 5 is typed (not confirmed), then another product is picked
	await _type_qty("1")
	_key(KEY_ENTER)
	await _frames(4)
	await _type_qty("5")
	picker = _node("ship_product:" + _company)
	_click(_center(picker)) # opens the list (on release)
	await _frames(2)
	_check(picker.get_popup().visible, "a click on the product picker opens its list")
	var index := _keys.find(b)
	picker.select(index) # what choosing in the list does
	picker.item_selected.emit(index)
	picker.get_popup().hide()
	await _frames(4)
	var field: LineEdit = _node("ship_qty:" + _company)
	_check(field.text == "5", "the typed 5 stays when product B is picked (field %s)" % field.text)
	await _ship_case("5 kept across the product change", b, 5, func() -> void: _click(_center(_node("ship_send:" + _company))))

	# Not shipped: not a number, nothing, out of range, more than in stock
	for typed in ["abc", "", "0", "-3"]:
		await _type_qty(typed)
		var sent_a := _sent(b)
		_click(_center(_node("ship_send:" + _company)))
		await _frames(3)
		field = _node("ship_qty:" + _company)
		_check(_sent(b) == sent_a, "\"%s\" ships nothing" % typed)
		_check(field.text.is_valid_int() and int(field.text) >= 1, "\"%s\" becomes a number to confirm (field %s)" % [typed, field.text])
		await _frames(3)
	await _type_qty("999")
	await _frames(3)
	send = _node("ship_send:" + _company)
	_check(send.disabled, "more than in stock: 자유 납품 is unavailable")
	var sent_b := _sent(b)
	_click(_center(send))
	await _frames(3)
	_check(_sent(b) == sent_b, "more than in stock ships nothing")
	# Two presses in the same frame (one input delivered twice) ship once
	await _type_qty("2")
	sent_b = _sent(b)
	send = _node("ship_send:" + _company)
	_click(_center(send))
	_click(_center(send))
	await _frames(4)
	_check(_sent(b) == sent_b + 2, "two presses in one frame ship once (sent %s → %s)" % [sent_b, _sent(b)])
	# Quick repeats by the player (about 120 ms apart) each ship: mouse, finger, Enter on the focused button
	for way in ["mouse", "touch", "enter"]:
		sent_b = _sent(b)
		send = _node("ship_send:" + _company)
		for k in 2:
			match way:
				"mouse": _click(_center(send))
				"touch": await _tap(_center(send))
				"enter":
					send.grab_focus()
					_key(KEY_ENTER)
			await _wait_ms(120)
		await _frames(3)
		_check(_sent(b) == sent_b + 4, "two quick presses (%s) ship twice (sent %s → %s)" % [way, sent_b, _sent(b)])
	# Stock gone between the press and the shipment: nothing is shipped
	sent_b = _sent(b)
	var stock_b := float(eco.state.inventory.get(b, 0))
	_click(_center(_node("ship_send:" + _company)))
	eco.state.inventory[b] = 1.0 # sold or used before the shipment runs (it runs on the next frame)
	await _frames(4)
	_check(_sent(b) == sent_b and float(eco.state.inventory.get(b, 0)) == 1.0, "stock gone between the press and the shipment: nothing shipped")
	eco.state.inventory[b] = stock_b
	eco.changed.emit()
	await _frames(3)


func _preview_text() -> String:
	var send := _node("ship_send:" + _company)
	for c in send.get_parent().get_children():
		if c is Label and str(c.text).contains("배송비"):
			return c.text
	return ""


## Holds the left button (or a finger) on a control for `ms` while the game changes, then lets go.
func _hold(c: Control, ms: int, touch: bool) -> void:
	var p := _center(c)
	if touch:
		_touch(p, true)
	else:
		_mouse_move(p)
		_mouse_button(p, true)
	# held for `ms` of real time and as many frames as `ms` lasts at 60 fps, the game changing every frame
	var frames := maxi(1, ms * 60 / 1000)
	var until := Time.get_ticks_msec() + ms
	while frames > 0 or Time.get_ticks_msec() < until:
		await process_frame
		frames -= 1
	if touch:
		_touch(p, false)
	else:
		_mouse_button(p, false)
	await _frames(3)


func _held_presses() -> void:
	# 판매 · 전량 판매 (steel keeps coming in, gold keeps moving)
	hud.open_tab("sell")
	await _frames(4)
	var i := 0
	for ms in [100, 300, 500]:
		var touch := i % 2 == 1
		i += 1
		await _show(_node("steel"))
		var sell: Button = _node("steel")
		var steel_before := float(eco.state.inventory.get("steel", 0))
		var gold_before := float(eco.state.gold)
		var redraws: int = hud.get("redraw_stats").redraws if hud.get("redraw_stats") != null else -1
		await _hold(sell, ms, touch)
		if redraws >= 0:
			_check(hud.redraw_stats.redraws > redraws, "the menu redrew while 전량 판매 was held %d ms" % ms)
		_check(float(eco.state.inventory.get("steel", 0)) < 1.0, "전량 판매 held %d ms (%s) sold the steel (steel %s → %s)" % [ms, "touch" if touch else "mouse", steel_before, eco.state.inventory.get("steel")])
		_check(float(eco.state.gold) > gold_before + steel_before, "전량 판매 held %d ms paid for the steel" % ms)
		await _frames(5)
	# exactly once: what a held press earns is one sale
	_churn = false
	eco.state.inventory["steel"] = 10.0
	eco.changed.emit()
	await _frames(3)
	var gold0 := float(eco.state.gold)
	await _hold(_node("steel"), 300, false)
	var held_gain := float(eco.state.gold) - gold0
	eco.state.inventory["steel"] = 10.0
	var gold1 := float(eco.state.gold)
	eco.sell("steel")
	_check(held_gain > 0.0 and is_equal_approx(float(eco.state.gold) - gold1, held_gain), "a held press sells exactly once (%s G; one sale %s G)" % [held_gain, float(eco.state.gold) - gold1])
	eco.state.inventory["steel"] = 3.0
	eco.changed.emit()
	await _frames(3)
	# a button that becomes unavailable while held does not act
	var held: Button = _node("steel")
	var p := _center(held)
	_mouse_move(p)
	_mouse_button(p, true)
	await _frames(3)
	eco.state.inventory["steel"] = 0.0
	eco.changed.emit()
	await _frames(3)
	_check(_node("steel") == held and held.disabled, "the held 전량 판매 stays the same button and turns unavailable")
	eco.state.inventory["steel"] = 3.0 # stock is back, but the button was unavailable when let go
	var gold2 := float(eco.state.gold)
	_mouse_button(p, false)
	await _frames(1)
	_check(float(eco.state.gold) == gold2 and float(eco.state.inventory.steel) == 3.0, "a button unavailable while held does not act on release")
	# switching the tab or closing the menu during a press acts on nothing
	eco.changed.emit()
	await _frames(3)
	p = _center(_node("steel"))
	_mouse_move(p)
	_mouse_button(p, true)
	await _frames(2)
	var steel_held := float(eco.state.inventory.steel)
	var gold_held := float(eco.state.gold)
	var research_held: int = eco.state.completed_research.size()
	hud._select_tab(hud.TAB_RESEARCH)
	await _frames(2)
	_mouse_button(p, false)
	await _frames(3)
	_check(float(eco.state.inventory.steel) == steel_held and float(eco.state.gold) == gold_held and eco.state.completed_research.size() == research_held,
		"switching the tab during a press acts on nothing")
	hud.open_tab("sell")
	await _frames(3)
	p = _center(_node("steel"))
	_mouse_move(p)
	_mouse_button(p, true)
	await _frames(2)
	hud.close_workshop()
	await _frames(2)
	_mouse_button(p, false)
	await _frames(3)
	_check(float(eco.state.inventory.steel) == steel_held and float(eco.state.gold) == gold_held, "closing the menu during a press acts on nothing")
	_churn = true

	# 연구 · 터널 굴착 held while the game changes
	hud.open_tab("research")
	await _frames(4)
	await _show(_node("tunnelWork"))
	var study: Button = _node("tunnelWork")
	_check(study != null and not study.disabled, "터널 굴착 can be researched")
	var hits := [0]
	study.pressed.connect(func() -> void: hits[0] += 1)
	_check(hud._scroll.get_global_rect().has_point(_center(study)), "터널 굴착 was scrolled into view while the game kept redrawing the list")
	await _hold(study, 420, true)
	_check(hits[0] == 1, "터널 굴착 acted exactly once (%d)" % hits[0])
	_check(bool(eco.state.completed_research.get("tunnelWork", false)), "터널 굴착 held 420 ms (touch) is researched")

	# 마을 · 잔해 치우기 held while the game changes
	hud.open_tab("village")
	await _frames(4)
	var restore: Button = _node("appraiser")
	_check(restore != null and str(restore.text).contains("잔해"), "the village tab offers 잔해 치우기 (got %s)" % (restore.text if restore else "nothing"))
	if restore != null:
		await _show(restore)
		restore = _node("appraiser")
		var stage := int(eco.state.village.stage.get("appraiser", 0))
		var presses := [0]
		restore.pressed.connect(func() -> void: presses[0] += 1)
		await _hold(restore, 420, false)
		_check(presses[0] == 1, "잔해 치우기 acted exactly once (%d)" % presses[0])
		await _frames(30)
		_check(int(eco.state.village.stage.get("appraiser", 0)) == stage + 1, "잔해 치우기 held 420 ms restores one step (stage %d → %d)" % [stage, int(eco.state.village.stage.get("appraiser", 0))])


func _tunnel_button() -> Control:
	for id: String in hud._buttons_by_id:
		var c: Control = hud._buttons_by_id[id]
		if c is Button and str(c.text).contains("굴착") or (id.contains("tunnel") and c is Button):
			return c
	return null


func _swipes() -> void:
	root.size = Vector2i(568, 320) # the phone screen of the QA
	await _frames(3)
	_churn = true
	hud.open_tab("craft")
	await _frames(6)
	var list: ScrollContainer = hud._scroll
	var view := list.get_global_rect()
	# a finger on a card's text: find a description label in the middle of the list
	var start := Vector2(view.position.x + 40, view.get_center().y)
	var top := list.scroll_vertical
	var state_before := _acted()
	_churn = false
	await _swipe(start, start + Vector2(0, -80), true)
	_check(list.scroll_vertical >= top + 60, "a swipe up on a card's text scrolls the list (%d → %d)" % [top, list.scroll_vertical])
	_check(_acted() == state_before, "the swipe pressed nothing")
	# a swipe starting on a button presses nothing
	var craft: Button = _first_enabled_button()
	_check(craft != null, "an available button to swipe from")
	if craft != null:
		var at := _center(craft)
		top = list.scroll_vertical
		state_before = _acted()
		await _swipe(at, at + Vector2(0, 60), true)
		_check(list.scroll_vertical <= top - 40, "a swipe down from a button scrolls the list (%d → %d)" % [top, list.scroll_vertical])
		_check(_acted() == state_before, "a swipe from %s presses nothing" % craft.text)
	# a swipe starting on a picker opens nothing
	var picker: OptionButton = null
	for c in hud._worker_pickers:
		if c.is_visible_in_tree() and view.has_point(_center(c)):
			picker = c
	if picker == null and not hud._worker_pickers.is_empty():
		picker = hud._worker_pickers[0]
		await _show(picker)
	if picker != null:
		var at := _center(picker)
		top = list.scroll_vertical
		await _swipe(at, at + Vector2(0, -60), true)
		_check(not picker.get_popup().visible, "a swipe from a picker does not open its list")
		_check(list.scroll_vertical != top, "a swipe from a picker scrolls the list")
		# a tap on the picker opens it
		picker = hud._worker_pickers[0]
		await _show(picker)
		await _tap(_center(picker))
		_check(picker.get_popup().visible, "a tap on a picker opens its list")
		picker.get_popup().hide()
		await _frames(3)
	# a tap on a button acts once
	craft = _first_enabled_button("craft")
	if craft != null:
		var id := str(craft.get_meta("row_id"))
		var stock := JSON.stringify(eco.state.inventory)
		await _tap(_center(craft))
		await _frames(3)
		_check(JSON.stringify(eco.state.inventory) != stock, "a tap on 제작 (%s) acts" % id)
	# the scroll bar still drags
	var bar := list.get_v_scroll_bar()
	if bar.visible:
		top = list.scroll_vertical
		var grab := bar.get_global_rect().get_center()
		_mouse_move(grab)
		_mouse_button(grab, true)
		await _frames(1)
		for k in 6:
			_mouse_move(grab + Vector2(0, 8 * (k + 1)), true)
			await _frames(1)
		_mouse_button(grab + Vector2(0, 48), false)
		await _frames(3)
		_check(list.scroll_vertical != top, "dragging the scroll bar scrolls (%d → %d)" % [top, list.scroll_vertical])
	# a mouse drag on a card scrolls too
	top = list.scroll_vertical
	await _swipe(start, start + Vector2(0, -50), false)
	_check(list.scroll_vertical != top, "a mouse drag on a card scrolls the list (%d → %d)" % [top, list.scroll_vertical])
	_churn = true


func _kept_features() -> void:
	_churn = true
	hud.open_tab("workers")
	await _frames(4)
	var picker: OptionButton = _node("w_qa")
	_check(picker != null, "the worker has a picker")
	if picker != null:
		await _show(picker)
		picker = _node("w_qa")
		_click(_center(picker))
		await _frames(30) # the game redraws all along
		_check(picker.get_popup().visible and _node("w_qa") == picker, "the worker's list stays open through redraws, on the same picker")
		var keys: PackedStringArray = picker.get_meta("keys", PackedStringArray())
		var index := keys.find("coal")
		_check(index >= 0, "coal can be picked for the worker")
		picker.select(index)
		picker.item_selected.emit(index)
		picker.get_popup().hide()
		await _frames(4)
		var worker: Dictionary = eco.state.characters.filter(func(w: Dictionary) -> bool: return w.id == "w_qa")[0]
		_check(worker.resource == "coal", "picking moves the worker to coal")
		var loaded: Dictionary = Save.parse_game(Save.export_game(eco.state))
		_check(loaded.characters.filter(func(w: Dictionary) -> bool: return w.id == "w_qa")[0].resource == "coal", "a save keeps the worker on coal")
	hud.open_tab("save")
	await _frames(4)
	var draft: TextEdit = hud._save_input
	draft.text = "{\"draft\": true}"
	draft.text_changed.emit()
	await _frames(20)
	_check(hud._save_input == draft and draft.text == "{\"draft\": true}", "the save tab's draft survives redraws")
	hud._select_tab(hud.TAB_SELL)
	await _frames(3)
	hud._select_tab(hud.TAB_SAVE)
	await _frames(3)
	_check(hud._save_input.text == "{\"draft\": true}", "the draft is still there after another tab")
	hud.close_workshop()
	await _frames(2)


## What only a button of the menu changes: gold, the automatic settings, huts, research, levels and crafted
## goods (not the ore a worker digs by itself).
func _acted() -> String:
	var ores := {}
	for r: Dictionary in eco.data.resources:
		ores[r.key] = true
	var goods := {}
	for id: String in eco.state.inventory:
		if not ores.has(id):
			goods[id] = eco.state.inventory[id]
	return JSON.stringify([eco.state.gold, eco.state.automation, eco.world.workshops, eco.state.completed_research,
		eco.state.get("hq_level"), eco.state.get("facility"), eco.state.get("workforce"), eco.state.get("craft_facility"), goods, eco.state.get("queue")])


func _button_text(text: String) -> Button:
	for c in hud._rows.find_children("*", "Button", true, false):
		if c.text == text and c.is_visible_in_tree():
			return c
	return null


func _stale_note() -> bool:
	var note: Control = hud._buttons_by_id.get("save_draft_stale")
	return is_instance_valid(note) and note.is_visible_in_tree()


func _save_tab_import() -> void:
	_churn = false
	hud.open_tab("save")
	await _frames(4)
	_click(_center(_button_text("내보내기")))
	await _frames(3)
	var exported: String = hud._save_input.text
	var gold_then := float(eco.state.gold)
	_check(Save.parse_game(exported).get("gold") == gold_then, "내보내기 puts the current save in the field")
	# a failed import: the draft stays, unmarked
	eco.import_save_bytes("not a save".to_utf8_buffer())
	await _frames(3)
	_check(hud._save_input.text == exported and not _stale_note(), "a failed import leaves the draft as it was, unmarked")
	# a successful file import of another save
	var other: Dictionary = Save.parse_game(exported)
	other.gold = 7.0
	_check(eco.import_save_bytes(Save.export_game(other).to_utf8_buffer()), "another save is imported from a file")
	await _frames(6)
	hud.open_tab("save") # the world reloads after an import and the menu closes: the player opens the tab again
	await _frames(4)
	_check(float(eco.state.gold) == 7.0, "the imported save is the game now")
	_check(hud._save_input.text == exported, "the earlier export stays in the field (the player may want to keep it)")
	_check(_stale_note(), "the field is marked as not the game's save")
	# 가져오기 with that draft: asks first
	_click(_center(_button_text("가져오기")))
	await _frames(3)
	_check(float(eco.state.gold) == 7.0, "the first 가져오기 with the marked draft imports nothing")
	_check(str(hud._panel_note.text).contains("한 번 더"), "it says to press again (%s)" % hud._panel_note.text)
	# the second press lands while a save is being written (web autosave in flight): refused, the draft and the
	# confirmation stay, and the next press imports without asking again
	eco._web_operation = "autosave"
	_click(_center(_button_text("가져오기")))
	await _frames(3)
	eco._web_operation = ""
	_check(float(eco.state.gold) == 7.0 and str(hud._panel_note.text).contains("저장 확인 중"),
		"a 가져오기 while a save is being written is refused (%s)" % hud._panel_note.text)
	_click(_center(_button_text("가져오기")))
	await _frames(4)
	_check(float(eco.state.gold) == gold_then, "the next 가져오기 imports it without asking again (gold %s)" % eco.state.gold)
	await _frames(6)
	hud.open_tab("save")
	await _frames(4)
	# after that import the field (its source) is marked again; editing it drops the mark, keeping the focus
	_check(_stale_note(), "after importing it, the field is marked again")
	var field: TextEdit = hud._save_input
	_click(_center(field))
	await _frames(2)
	_key(KEY_END)
	_type(" ")
	await _frames(3)
	_check(not _stale_note() and hud._save_input == field and field.has_focus(), "editing drops the mark; the field keeps the focus")
	hud.close_workshop()
	await _frames(2)
	_churn = true


func _first_enabled_button(method := "") -> Button:
	var view: Rect2 = hud._scroll.get_global_rect()
	for id: String in hud._buttons_by_id:
		var c: Control = hud._buttons_by_id[id]
		if c is Button and not c is OptionButton and not c is CheckButton and not c.disabled and c.is_visible_in_tree() \
				and view.grow(-10).has_point(_center(c)) and (method.is_empty() or str(c.text) == "제작"):
			return c
	return null


func _swipe(from: Vector2, to: Vector2, touch: bool) -> void:
	if touch:
		_touch(from, true)
	else:
		_mouse_move(from)
		_mouse_button(from, true)
	await _frames(2)
	var steps := 8
	var last := from
	for k in steps:
		var p := from.lerp(to, float(k + 1) / steps)
		if touch:
			_touch_move(last, p)
		else:
			_mouse_move(p, true)
		last = p
		await _frames(1)
	if touch:
		_touch(to, false)
	else:
		_mouse_button(to, false)
	await _frames(4)
