extends SceneTree
## The world screen's action button with long labels (a facility's restoration with its cost, the museum's counts):
##   godot --headless --path . --fixed-fps 60 --script res://tools/hud_action_test.gd
## At 568x320, 740x360 and 960x540 (the game draws at 480x270 and stretches), for the labels the village really
## offers: the button stays on screen and keeps its size, its text is the action alone, the rest (the cost) is shown
## in full in the line above it, on screen, not under the torch or garden button or the "다음 할 일" card; short
## labels stay as they were on the button; E and the button still act.
## Prints "HUD ACTION PASS" and exits 0, or the failures and exits 1.

const World := preload("res://scripts/world/world_state.gd")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)
		printerr("HUD ACTION FAIL " + what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _overlap(a: Rect2, b: Rect2) -> bool:
	return a.grow(-0.5).intersects(b.grow(-0.5))


func _run() -> void:
	var game: Node = root.get_node("Game")
	var eco: Node = game.workshop
	eco._restore({"world": World.new_game(42).to_dict()})
	eco._ensure_village()
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	var hud: Node = game._hud
	# the labels the village offers: restoring the appraiser and the museum, both steps, and the museum's counts
	var labels: Array[String] = []
	for key: String in ["appraiser", "museum"]:
		for stage in [0, 1]:
			eco.state.village.stage[key] = stage
			labels.append(str(eco.village_target(key).label))
	eco.state.village.stage["appraiser"] = 2
	eco.state.village.stage["museum"] = 2
	labels.append(str(eco.village_target("museum").label))
	eco.state.village.stage = {}
	var calls := [0]
	var act := func() -> void: calls[0] += 1
	for size: Vector2i in [Vector2i(568, 320), Vector2i(740, 360), Vector2i(960, 540)]:
		root.size = size
		await _frames(3)
		var screen: Rect2 = hud.get_viewport().get_visible_rect()
		hud._torch_callback = func() -> void: pass # the touch screen's torch button, next to the action button
		hud._torch.visible = true
		for garden in [false, true]:
			hud.set_garden("다음 장식" if garden else "", func() -> void: pass)
			for label in labels:
				hud.set_action(label, act)
				hud.set_context_hint("E  ·  " + label)
				await _frames(2)
				var button: Rect2 = hud._action.get_global_rect()
				var detail: Rect2 = hud._action_detail.get_global_rect()
				var where := "%s, %s%s" % [size, label, " (garden button shown)" if garden else ""]
				_check(screen.encloses(button), "the action button stays on screen: %s (%s in %s)" % [where, button, screen])
				_check(button.size.x <= 112.0, "the action button keeps its size: %s (%s)" % [where, button.size])
				var shown := str(hud._action.text)
				var rest := str(hud._action_detail.text)
				_check(not shown.contains("G") or not label.contains("·"), "the button shows the action, not the cost: %s (%s)" % [where, shown])
				_check(label.begins_with(shown) and (shown + " · " + rest == label or shown == label), "nothing of the label is lost: %s (%s | %s)" % [where, shown, rest])
				if not rest.is_empty():
					_check(hud._action_detail.visible and screen.encloses(detail), "the rest is shown on screen: %s (%s)" % [where, detail])
					_check(hud._action_detail.get_visible_line_count() >= hud._action_detail.get_line_count(), "the rest is shown in full: %s" % where)
					for other: Array in [["torch", hud._torch], ["garden", hud._garden], ["action", hud._action], ["hint", hud._hint_card], ["bar", hud._bar]]:
						var c: Control = other[1]
						if c.visible:
							_check(not _overlap(detail, c.get_global_rect()), "the rest is not under the %s: %s (%s / %s)" % [other[0], where, detail, c.get_global_rect()])
				_check(not _overlap(button, hud._torch.get_global_rect()), "the action button does not cover the torch button: %s" % where)
				_check(str(hud._context_hint.text) == "E  ·  " + shown, "the key hint names the action: %s (%s)" % [where, hud._context_hint.text])
				_check(hud.action_text_for(label) == shown, "the world's place line names the action as the button does: %s" % where)
		hud._torch_callback = Callable()
		hud._torch.visible = false
		hud.set_garden("", Callable())
	# the world's place line at the museum's door, on each screen: next to the right-hand buttons, not under them
	var map: Node2D = current_scene.get_node("World")
	eco.state.village.stage = {"appraiser": 2, "museum": 1}
	var site: Dictionary = eco.state.village.sites.museum
	for size: Vector2i in [Vector2i(568, 320), Vector2i(740, 360), Vector2i(960, 540)]:
		root.size = size
		hud._torch_callback = func() -> void: pass
		hud._torch.visible = true
		map.player.position = map.to_px(Vector2(site.x, site.y + 0.45))
		map.player.set("facing", "up")
		await _frames(4)
		var line: Label = map.get_node("WorldUI/Region")
		var text_box := Rect2(line.get_global_position(), line.get_minimum_size())
		_check(str(line.text).contains("E  ·  박물관 건물 복구") and not str(line.text).contains("3,000G"), "the place line names the museum's next step without its cost: %s (%s)" % [size, line.text])
		for other: Array in [["torch", hud._torch], ["action", hud._action], ["cost line", hud._action_detail]]:
			var c: Control = other[1]
			if c.visible:
				_check(not _overlap(text_box, c.get_global_rect()), "the place line is not under the %s: %s (%s / %s)" % [other[0], size, text_box, c.get_global_rect()])
		_check(hud._action_detail.visible and str(hud._action_detail.text).contains("3,000G"), "the cost is shown above the button at the museum's door: %s" % size)
	hud._torch_callback = Callable()
	hud._torch.visible = false
	# a short label is left as it is
	hud.set_action("공방 들어가기", act)
	hud.set_context_hint("E  ·  공방 들어가기")
	await _frames(2)
	_check(hud._action.text == "공방 들어가기" and not hud._action_detail.visible, "a short label stays on the button alone")
	# the button still acts
	calls[0] = 0
	hud._action.pressed.emit()
	_check(calls[0] == 1, "the action button still acts")
	if _failures.is_empty():
		print("HUD ACTION PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("HUD ACTION FAIL %d of %d" % [_failures.size(), _checks])
		quit(1)
