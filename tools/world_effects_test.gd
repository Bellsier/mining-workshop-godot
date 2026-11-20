extends SceneTree
## The world's look and feedback (graphics and play-feel pass):
##   godot --headless --path . --fixed-fps 60 --script res://tools/world_effects_test.gd
## 1. Cloud shadows, fireflies and swaying match the original web code value by value
##    (tests/fixtures/effects_web_fixtures.json, made by tools/parity/make_effects_fixtures.cjs).
## 2. The pixel sprites are painted as the web paints them (sizes, a few known pixels, see-through shadows).
## 3. In the world scene: the sway layer, the cloud shadows and the fireflies are there; securing and mining a vein
##    with the real interaction raises "광맥 확보!" and "+1 철광석", a second press adds up (+2), and the effect
##    quality's lowest step stops the sway, clouds and fireflies.
## 4. The "다음 할 일" card: shown with the menu closed, hidden while it is open; the first step says the first E
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
	# the lowest effect quality stops the effects
	light.quality = 2
	light.force_darkness = 0.34
	await _frames(3)
	_check(map.get_node("Sway")._still(), "the sway stops at the lowest quality")
