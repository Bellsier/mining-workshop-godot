extends SceneTree
## The world's look and feedback (graphics and play-feel pass):
##   godot --headless --path . --fixed-fps 60 --script res://tools/world_effects_test.gd
## 1. Cloud shadows, fireflies and swaying match the original web code value by value
##    (tests/fixtures/effects_web_fixtures.json, made by tools/parity/make_effects_fixtures.cjs).
## 2. The pixel sprites are painted as the web paints them (sizes, a few known pixels, see-through shadows).
## 3. In the world scene: the sway layer, the cloud shadows and the fireflies are there; securing and mining a vein
##    with the real interaction raises "광맥 확보!" and "+1 철광석", a second press adds up (+2), and the effect
##    quality's lowest step stops the sway, clouds and fireflies.
## 4. The cabin hides the player standing behind it (and not one at its door or beside it); in a dense village
##    (every craft hut built), between two overlapping buildings only the one the player is behind is over them;
##    workers and trees are in the same ground order (a worker in front of the cabin is over it while the player
##    is behind it); a building's name fades where it crosses the player.
## 5. The "다음 할 일" card: shown with the menu closed, hidden while it is open; the first step says the first E
##    secures a vein.
## Prints "WORLD EFFECTS PASS" and exits 0, or the failures and exits 1.

const World := preload("res://scripts/world/world_state.gd")
const Light := preload("res://scripts/world/world_light.gd")
const Sway := preload("res://scripts/world/world_sway.gd")
const Sprites := preload("res://scripts/world/world_sprites.gd")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failures.append(what)
		printerr("WORLD EFFECTS FAIL " + what)


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= 1e-9 * maxf(1.0, absf(b))


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	_parity()
	_sprites()
	await _scene()
	if _failures.is_empty():
		print("WORLD EFFECTS PASS (%d checks)" % _checks)
		quit(0)
	else:
		printerr("WORLD EFFECTS FAIL %d of %d" % [_failures.size(), _checks])
		quit(1)


func _parity() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/effects_web_fixtures.json"))
	var rect := Rect2(data.rect[0], data.rect[1], data.rect[2], data.rect[3])
	for c: Dictionary in data.cases:
		var now: float = c.now
		var clouds := Light.cloud_shadows(rect, now)
		var same: bool = clouds.size() == c.clouds.size()
		for i in mini(clouds.size(), c.clouds.size()):
			same = same and _near(clouds[i].x, c.clouds[i].x) and _near(clouds[i].y, c.clouds[i].y) and _near(clouds[i].r, c.clouds[i].r)
		_check(same, "cloud shadows at %s match the web (%s / %s)" % [now, clouds, c.clouds])
		for open in [false, true]:
			var flies := Light.fireflies(float(data.base[0]), float(data.base[1]), open, now, 0.3)
			var want: Array = c.fliesOpen if open else c.fliesClosed
			var ok: bool = flies.size() == want.size()
			for i in mini(flies.size(), want.size()):
				ok = ok and _near(flies[i].x, want[i].x) and _near(flies[i].y, want[i].y) and _near(flies[i].glow, want[i].glow)
			_check(ok, "fireflies at %s (tunnel %s) match the web" % [now, "open" if open else "closed"])
		_check(Light.fireflies(float(data.base[0]), float(data.base[1]), false, now, 0.15).size() == int(c.fliesDay), "no fireflies in daylight at %s" % now)
		for s: Dictionary in c.sway:
			_check(_near(Sway.lean(now, s.x, s.y, s.kind), s.lean), "sway of %s at %s matches the web" % [s.kind, now])


func _pixel(t: Texture2D, x: int, y: int) -> Color:
	return t.get_image().get_pixel(x, y)


func _sprites() -> void:
	var cabin := Sprites.base()
	_check(cabin.get_size() == Vector2(64, 58), "the workshop cabin is 64 x 58 like the web's")
	_check(_pixel(cabin, 35, 41).is_equal_approx(Color("e2b23c")), "the cabin's door handle is where the web paints it")
	_check(_pixel(cabin, 12, 33).is_equal_approx(Color("f7e2a0")) or _pixel(cabin, 12, 33).is_equal_approx(Color("f3d27a")), "the cabin has warm window glass")
	_check(absf(_pixel(cabin, 5, 56).a - 0.22) < 0.01, "the cabin's shadow is see-through (22 %)")
	var tree := Sprites.prop("bigTree")
	_check(tree.get_size() == Vector2(32, 42), "a big tree is 32 x 42")
	_check(_pixel(tree, 16, 2).is_equal_approx(Color("2f5634")) and _pixel(tree, 12, 10).is_equal_approx(Color("5a8e57")), "a big tree's crown is shaded dark to light")
	_check(Sprites.prop("grass").get_size() == Vector2(12, 8), "a grass tuft is 12 x 8")
	_check(Sprites.prop("somethingNew").get_size() == Vector2(8, 8), "an unknown prop is a pebble, as on the web")
	var hidden := Sprites.ore("iron", "undiscovered")
	var found := Sprites.ore("mana", "discovered")
	var staked := Sprites.ore("mana", "secured")
	_check(hidden.get_size() == Vector2(24, 20) and _pixel(hidden, 14, 8).is_equal_approx(Color("5f7d4e")), "a hidden vein is a mossy rock")
	_check(_pixel(found, 8, 9).is_equal_approx(Color("c4a2ff")) and _pixel(found, 9, 9).is_equal_approx(Color("8a5cd6")), "a found mana vein shows its ore colours")
	_check(_pixel(staked, 20, 6).is_equal_approx(Color("3fc9b0")) and _pixel(found, 20, 6).a == 0.0, "a secured vein has a staked flag, a found one has none")
	_check(Sprites.ore("iron", "undiscovered") == Sprites.ore("coal", "undiscovered"), "sprites are painted once and kept")


func _scene() -> void:
	var game: Node = root.get_node("Game")
	var eco: Node = game.workshop
	eco._restore({"world": World.new_game(42).to_dict()})
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	var map: Node2D = current_scene.get_node("World")
	var light: Node = map.objects.light
	_check(map.get_node_or_null("Sway") != null and map.get_child(0).name == "Sway", "the sway layer is drawn right after the world's own drawing")
	_check(light.get_node_or_null("CloudShadows") != null and light.get_node_or_null("Fireflies") != null, "cloud shadows and fireflies are in the world")
	_check(map.floats != null, "the world has floating texts")
	# secure and mine the starter iron vein with the real interaction
	var vein: Dictionary = map.state.mine_by_id("mine_start_iron")
	var player: Node2D = map.player
	player.position = map.to_px(Vector2(vein.x, vein.y + 0.8))
	player.set("facing", "up")
	await _frames(2)
	var hud: Node = game._hud
	hud._refresh(true)
	_check(hud._hint_card.visible and str(hud._hint_text.text).contains("확보"), "the first step says E secures a vein first (%s)" % hud._hint_text.text)
	await _frames(2)
	_check(hud._hint_text.get_visible_line_count() >= 1 and hud._hint_text.size.y > 10.0, "the card's text is laid out and shown (%d lines, %s)" % [hud._hint_text.get_visible_line_count(), hud._hint_text.size])
	var id: String = map.context_at(player.position)
	map.interact(id)
	_check(map.state.mine_by_id(vein.id).developmentState == "secured", "E at the iron vein secures it")
	_check(map.floats.floats.any(func(f: Dictionary) -> bool: return f.text == "광맥 확보!"), "securing raises 광맥 확보! over the vein")
	await _frames(2)
	hud._refresh(true)
	_check(not str(hud._hint_text.text).contains("확보"), "once a vein is secured the hint says to mine (%s)" % hud._hint_text.text)
	id = map.context_at(player.position)
	map.interact(id)
	id = map.context_at(player.position)
	map.interact(id)
	var mined: Array = map.floats.floats.filter(func(f: Dictionary) -> bool: return str(f.text).ends_with("철광석"))
	_check(mined.size() == 1 and mined[0].text == "+2 철광석", "two presses add up in one float (%s)" % [mined.map(func(f): return f.text)])
	# the menu hides the card
	hud.open_tab("mining")
	await _frames(2)
	_check(not hud._hint_card.visible, "the card is hidden while the menu is open")
	hud.close_workshop()
	await _frames(2)
	_check(hud._hint_card.visible, "the card is back when the menu closes")
	# a building hides the player behind it, not one in front of it or beside it
	var objects: Node2D = map.objects
	var cabin_at: Vector2 = map.to_px(Vector2(map.state.base))
	var cases := [[Vector2(0, -34), true, "behind the cabin (north of its wall)"], [Vector2(0, 2), false, "at the cabin's door"],
		[Vector2(70, -34), false, "beside the cabin"]]
	for c: Array in cases:
		player.position = cabin_at + c[0]
		await _frames(2)
		var over: bool = objects._front.size() == 1 and (objects._occluders[objects._front[0]].rect as Rect2).has_point(cabin_at + Vector2(0, -20))
		_check(over == c[1] and objects.player_behind() == c[1], "player %s: the cabin is %s the player" % [c[2], "over" if c[1] else "under"])
	_check(objects.buildings.z_index < player.z_index and player.z_index < objects.buildings_front.z_index,
		"the player is between the buildings under them and the ones over them (%d < %d < %d)" % [objects.buildings.z_index, player.z_index, objects.buildings_front.z_index])
	# workers and trees in ground order with the buildings and the player: hire one worker and put them, and a tree,
	# in front of and behind the cabin
	eco.state.gold = 1000.0
	eco.hire("gold")
	eco.assign_worker(str(eco.state.characters[0].id), "iron")
	await _frames(3)
	var crew: Node = objects.workers
	var sim: Dictionary = crew._sim.values()[0]
	sim.delay = 0.0
	var tree := {"kind": "bigTree", "x": float(map.state.base.x) + 1.6, "y": float(map.state.base.y) + 1.0, "size": 1.0}
	# the order is checked right after sorting, with the worker and the player where they are put (the worker's
	# own walk and the map's redraws would move them on between frames)
	var order := func(kind: String) -> int:
		for i in objects._standing.size():
			if objects._standing[i].kind == kind:
				return i
		return -1
	var cabin_index := func() -> int:
		for i in objects._standing.size():
			var it: Dictionary = objects._standing[i]
			if it.kind == "building" and objects._occluders[it.id].name[1] == "공방":
				return i
		return -1
	for c: Array in [[Vector2(0, -34), Vector2(10, 4), "the player behind the cabin, a worker in front of it"],
			[Vector2(0, 8), Vector2(-10, -34), "the player in front of the cabin, a worker behind it"]]:
		player.position = cabin_at + c[0]
		sim.mode = "wait"
		sim.route = []
		sim.x = (cabin_at.x + c[1].x) / 64.0
		sim.y = (cabin_at.y + c[1].y) / 64.0
		sim.hidden = false
		objects._sort_standing()
		var w: int = order.call("worker")
		var cab: int = cabin_index.call()
		var worker_front: bool = c[1].y > -6.4
		_check(w >= 0 and cab >= 0 and (w > cab) == worker_front, "%s: the worker is drawn %s the cabin (worker %d, cabin %d)" % [c[2], "over" if worker_front else "under", w, cab])
		_check(((w >= objects._split) == (c[1].y > c[0].y)), "%s: the worker is on the %s side of the player" % [c[2], "front" if c[1].y > c[0].y else "back"])
	var tree_at: Vector2 = map.to_px(Vector2(float(map.state.base.x) + 1.6, float(map.state.base.y) + 1.0))
	for c: Array in [[Vector2(0, -10), true, "behind the tree"], [Vector2(0, 6), false, "in front of the tree"]]:
		player.position = tree_at + c[0]
		map.scenery_now = [tree]
		objects._sort_standing()
		var t: int = order.call("tree")
		_check(t >= 0 and (t >= objects._split) == c[1], "the player %s: the tree is drawn %s the player" % [c[2], "over" if c[1] else "under"])
	# the cabin's name fades where it crosses the player, and only there
	player.position = cabin_at + Vector2(0, -34)
	await _frames(2)
	var cabin_occ := -1
	for i in objects._occluders.size():
		if objects._occluders[i].name[1] == "공방":
			cabin_occ = i
	player.position = cabin_at + Vector2(0, -58)
	await _frames(1)
	_check(objects.name_faint(cabin_occ), "the cabin's name is faint over the player's head behind the roof")
	player.position = cabin_at + Vector2(0, 8)
	await _frames(1)
	_check(not objects.name_faint(cabin_occ), "the cabin's name is drawn fully when the player is elsewhere")
	_check(objects.names.z_index > objects.buildings_front.z_index, "names are drawn over the buildings")
	# the lowest effect quality stops the effects
	light.quality = 2
	light.force_darkness = 0.34
	await _frames(3)
	_check(map.get_node("Sway")._still(), "the sway stops at the lowest quality")
	await _dense(game, eco)


## Buildings close together (seed 1 with every craft hut built): wherever the player stands between two buildings
## whose pictures both overlap theirs, the one they are behind is over them and the one they are in front of is not.
func _dense(game: Node, eco: Node) -> void:
	eco._restore({"world": World.new_game(1).to_dict(), "gold": 1.0e9,
		"inventory": {"steel": 1.0e6, "ironTool": 1.0e6, "steelGear": 1.0e6, "manaEngine": 1.0e6, "precisionMachine": 1.0e6},
		"completed_research": {"workshopBuild": true, "workshopExpansion": true}})
	eco._ensure_village()
	while eco.build_hut():
		pass
	change_scene_to_file("res://scenes/world/world_map.tscn")
	await _frames(6)
	var map: Node2D = current_scene.get_node("World")
	var objects: Node2D = map.objects
	var player: Node2D = map.player
	var occ: Array = objects._occluders
	_check(eco.world.workshops.size() >= 6, "the dense village has its craft huts (%d)" % eco.world.workshops.size())
	var ordered := true
	for i in range(1, occ.size()):
		ordered = ordered and float(occ[i - 1].foot) <= float(occ[i].foot)
	_check(ordered, "buildings are drawn north to south")
	# every place in the village where two building pictures overlap the player's with the player between them
	var spots: Array = []
	var area := Rect2(occ[0].rect.position, Vector2.ZERO)
	for o: Dictionary in occ:
		area = area.merge(o.rect)
	var y := area.position.y
	while y < area.end.y + 24.0:
		var x := area.position.x
		while x < area.end.x:
			var body := Rect2(Vector2(x, y) + Vector2(-8, -24), Vector2(16, 24))
			var ahead := false
			var behind := false
			for o: Dictionary in occ:
				if (o.rect as Rect2).intersects(body):
					if y < float(o.foot):
						behind = true
					else:
						ahead = true
			if ahead and behind:
				spots.append(Vector2(x, y))
			x += 4.0
		y += 4.0
	_check(not spots.is_empty(), "the dense village has places between two overlapping buildings (%d)" % spots.size())
	var wrong := 0
	for at: Vector2 in spots:
		player.position = at
		await _frames(1)
		var body := Rect2(at + Vector2(-8, -24), Vector2(16, 24))
		for i in occ.size():
			var o: Dictionary = occ[i]
			if (o.rect as Rect2).intersects(body) and ((i in objects._front) != (at.y < float(o.foot))):
				wrong += 1
	_check(wrong == 0, "between two buildings, only the one the player is behind is over the player (%d wrong of %d places)" % [wrong, spots.size()])
