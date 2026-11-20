extends SceneTree
## The 제작 tab keeps what the player is working with in place (QA: picking a hut recipe moved the list).
##   godot --headless --path . --fixed-fps 60 --script res://tools/craft_tab_layout_test.gd
## With 제작소 건설 and 자동 제작 장치 researched and one hut built, the 제작 tab is opened and scrolled so the hut's
## recipe picker sits mid-screen. 철제 공구 is picked there as a player does (the popup's item_selected, then the
## popup closing), the game ticks on, and then the player clicks where the picker was:
##   - the hut's picker is still under the pointer, at the same place (within 2 px), and is the focused control;
##   - the click lands on the picker, never on another row's button or switch: no recipe's automatic crafting
##     (강철's or any other) is switched and no iron or coal is used;
##   - the hut keeps 철제 공구, and saving and loading keep the hut's recipe and the automatic settings.
## The same is checked after the hut's automatic switch is turned on and the list is redrawn by the game alone.
## Last, with the pointer resting on 강철's automatic switch further down, the hut's card above shrinks (its recipe
## is cleared): the switch under the pointer stays the same and in place.
## Prints "CRAFT TAB LAYOUT PASS" and exits 0, or the failures and exits 1.

const World = preload("res://scripts/world/world_state.gd")
const Save = preload("res://scripts/workshop_save.gd")

var step := 0
var frames := 0
var game: Node
var eco: Node
var hud: Node
var _failures: Array[String] = []
var _hut_id := ""
var _at := Vector2.ZERO
var _rect := Rect2()
var _inventory := {}
var _auto := {}


func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	root.size = Vector2i(960, 540) # the game's 16:9 screen (480×270 canvas), not the headless window's square
	game = root.get_node("Game")
	eco = game.workshop
	hud = game._hud
	eco._restore({"world": World.new_game(42).to_dict(), "gold": 100000.0,
		"completed_research": {"workshopBuild": true, "autoCraftDevice": true},
		"inventory": {"steel": 20.0, "coalBrick": 0.0, "iron": 50.0, "coal": 50.0}})
	eco._ensure_village()
	_check(eco.build_hut(), "a hut is built")
	_hut_id = str(eco.world.workshops[0].id)
	change_scene_to_file("res://scenes/world/world_map.tscn")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("CRAFT TAB LAYOUT FAIL ", what)


func _picker() -> OptionButton:
	return hud._buttons_by_id.get("craft_hut:" + _hut_id) as OptionButton


func _row_controls() -> Array:
	return hud._rows.find_children("*", "BaseButton", true, false) + hud._rows.find_children("*", "LineEdit", true, false)


## The topmost visible control in the list under a screen point.
func _control_at(point: Vector2) -> Control:
	var hit: Control = null
	for c: Control in _row_controls():
		if c.is_visible_in_tree() and not c.is_queued_for_deletion() and c.get_global_rect().has_point(point):
			hit = c
	return hit


func _describe(c: Control) -> String:
	if c == null:
		return "nothing"
	return "%s %s \"%s\"" % [c.get_class(), c.get_meta("row_id", "?"), c.get("text") if c.get("text") != null else ""]


## Input is pushed in window pixels; the list is laid out in the game's 480-wide canvas.
func _window(point: Vector2) -> Vector2:
	return root.get_final_transform() * point


func _click(point: Vector2) -> void:
	_hover(point)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = _window(point)
		event.global_position = event.position
		root.push_input(event)


func _hover(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = _window(point)
	motion.global_position = motion.position
	root.push_input(motion)


func _auto_craft() -> Dictionary:
	return eco.state.automation.get("craft", {}).duplicate()


func _steel_auto() -> bool:
	return bool(eco.state.automation.get("craft", {}).get("steel", false))


func _process(_dt: float) -> bool:
	if current_scene == null or game == null:
		return false
	frames += 1
	match step:
		0:
			if frames < 4:
				return false
			hud.open_tab("craft")
			_next()
		1:
			if frames < 6:
				return false
			var picker := _picker()
			if picker == null:
				return _fail("the hut has no recipe picker")
			# Scroll so the picker sits in the middle of the list, as when the player scrolled to it.
			var view: Rect2 = hud._scroll.get_global_rect()
			hud._scroll.scroll_vertical += int(picker.get_global_rect().get_center().y - view.get_center().y)
			_next()
		2:
			if frames < 4:
				return false
			var picker := _picker()
			_rect = picker.get_global_rect()
			_at = _rect.get_center()
			_check(hud._scroll.get_global_rect().has_point(_at), "the picker is on screen before picking (at %s)" % _at)
			_inventory = eco.state.inventory.duplicate()
			_auto = _auto_craft()
			var index := -1
			for i in picker.item_count:
				if picker.get_item_text(i) == "철제 공구":
					index = i
			_check(index > 0, "철제 공구 is offered for the hut")
			# What the popup does when the player picks an item: the selection, then the popup closes.
			picker.grab_focus()
			picker.select(index)
			picker.item_selected.emit(index)
			picker.get_popup().popup_hide.emit()
			_next()
		3, 7:
			# Let the deferred redraw, the scroll and the game's own ticks (it keeps producing) happen.
			if frames < 40:
				return false
			var picker := _picker()
			_check(str(eco.hut_by_id(_hut_id).recipeKey) == "ironTool", "the hut keeps 철제 공구")
			_check(picker != null and picker.get_item_text(picker.selected) == "철제 공구", "the picker shows 철제 공구")
			if picker != null:
				var now := picker.get_global_rect()
				_check(now.position.distance_to(_rect.position) <= 2.0,
					"the hut's picker stays where it was (step %d: %s, was %s)" % [step, now.position, _rect.position])
				_check(hud.get_viewport().gui_get_focus_owner() == picker, "the picker keeps the focus (focus: %s)" % _describe(hud.get_viewport().gui_get_focus_owner()))
			var under := _control_at(_at)
			_check(under == picker, "under the pointer is still the hut's picker (got %s)" % _describe(under))
			_click(_at)
			_next()
		4, 8:
			if frames < 6:
				return false
			var picker := _picker()
			if picker != null and picker.get_popup().visible:
				picker.get_popup().hide()
			_check(not _steel_auto(), "clicking where the picker was does not switch on 강철's automatic crafting")
			_check(_auto_craft() == _auto, "clicking where the picker was changes no recipe's automatic crafting (%s → %s)" % [_auto, _auto_craft()])
			_check(eco.state.inventory.get("iron") == _inventory.get("iron") and eco.state.inventory.get("coal") == _inventory.get("coal"),
				"no iron or coal is used by the click (iron %s → %s, coal %s → %s)" % [_inventory.get("iron"), eco.state.inventory.get("iron"),
					_inventory.get("coal"), eco.state.inventory.get("coal")])
			if step == 8:
				_check_save()
			_next()
		5:
			if frames < 6:
				return false
			# Turn the hut's automatic crafting on, then let the game redraw the list by itself.
			var toggle: CheckButton = hud._buttons_by_id.get("set_hut_auto:" + _hut_id)
			_check(toggle != null, "the hut offers its automatic switch once it has a recipe")
			if toggle != null:
				toggle.grab_focus()
				toggle.button_pressed = true
			_next()
		9:
			if frames < 6:
				return false
			var steel: CheckButton = hud._buttons_by_id.get("set_auto_craft:steel")
			if steel == null:
				return _fail("강철 has no automatic switch")
			# Bring 강철's row on screen and rest the pointer on its switch.
			var view: Rect2 = hud._scroll.get_global_rect()
			hud._scroll.scroll_vertical += int(steel.get_global_rect().get_center().y - view.get_center().y)
			_next()
		10:
			if frames < 4:
				return false
			var steel: CheckButton = hud._buttons_by_id.get("set_auto_craft:steel")
			_rect = steel.get_global_rect()
			_at = _rect.get_center()
			_hover(_at)
			eco.set_hut_recipe(_hut_id, "") # the hut card above loses its switch and its bottleneck line changes
			_next()
		11:
			if frames < 30:
				return false
			var steel: CheckButton = hud._buttons_by_id.get("set_auto_craft:steel")
			_check(steel != null and steel.get_global_rect().position.distance_to(_rect.position) <= 2.0,
				"강철's switch under the pointer stays in place when the hut card above shrinks (%s, was %s)" % [steel.get_global_rect().position if steel else null, _rect.position])
			_check(_control_at(_at) == steel, "under the pointer is still 강철's switch (got %s)" % _describe(_control_at(_at)))
			_check(not _steel_auto(), "강철's automatic crafting is still off")
			_finish()
		6:
			if frames < 30:
				return false
			_check(bool(eco.hut_by_id(_hut_id).auto), "the hut crafts automatically")
			var picker := _picker()
			_check(picker != null, "the picker is still there")
			if picker != null:
				picker.grab_focus()
				_rect = picker.get_global_rect()
				_at = _rect.get_center()
				_inventory = eco.state.inventory.duplicate()
				_auto = _auto_craft()
				eco.changed.emit() # a game change redraws the tab
			_next()
	return false


func _check_save() -> void:
	# The settings survive a save and a load.
	var text: String = Save.export_game(eco.state)
	var loaded: Dictionary = Save.parse_game(text)
	var hut: Dictionary = {}
	for w: Dictionary in loaded.get("world", {}).get("workshops", []):
		if str(w.id) == _hut_id:
			hut = w
	_check(str(hut.get("recipeKey")) == "ironTool" and bool(hut.get("auto")), "a save keeps the hut's recipe and its automatic switch (%s)" % hut)
	_check(not bool(loaded.get("automation", {}).get("craft", {}).get("steel", false)), "a save keeps 강철's automatic crafting off")


func _finish() -> void:
	if _failures.is_empty():
		print("CRAFT TAB LAYOUT PASS")
		quit(0)
	else:
		print("CRAFT TAB LAYOUT FAIL %d" % _failures.size())
		quit(1)


func _next() -> void:
	step += 1
	frames = 0


func _fail(msg: String) -> bool:
	printerr("CRAFT TAB LAYOUT FAIL ", msg)
	quit(1)
	return false
