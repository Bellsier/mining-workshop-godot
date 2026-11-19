extends SceneTree
## Things standing in the world, played through the real world map and Game (web interact.js, player.js torches,
## village.js house and garden):
##   godot --headless --path . --fixed-fps 60 --script res://tools/world_objects_test.gd
## Craft huts, the appraiser and museum, the plaza, the house and the garden are drawn and block the player;
## E at each does what the web does (the hut opens its card, a ruin is restored, the plaza opens the 마을 tab,
## the house is entered and left through its door); T sets a torch down and picks it up; E in the garden sets a
## decoration down, picks it up and moves it; R takes it back. Inside the house the saved position stays on
## the door step. Prints "WORLD OBJECTS PASS" and exits 0, or the failure and exits 1.

const World = preload("res://scripts/world/world_state.gd")
const Layout = preload("res://scripts/village_layout.gd")
const UNIT := 64.0

var step := 0
var frames := 0
var game: Node
var eco: Node
var _failures: Array[String] = []
var _house_door := Vector2.ZERO


func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	game = root.get_node("Game")
	eco = game.workshop
	eco._restore({"world": World.new_game(42).to_dict(), "gold": 100000.0,
		"completed_research": {"workshopBuild": true}, "inventory": {"steel": 20.0, "coalBrick": 10.0}})
	eco._ensure_village()
	_check(eco.state.village.district is Dictionary, "the village is laid out")
	_check(eco.build_hut() and eco.build_hut(), "two huts are built")
	change_scene_to_file("res://scenes/world/world_map.tscn")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures.append(what)
		printerr("WORLD OBJECTS FAIL ", what)


func _player() -> CharacterBody2D:
	return current_scene.get_node("Player") as CharacterBody2D


func _put(at: Vector2, facing := "up") -> void:
	var p := _player()
	p.position = at * UNIT
	p.velocity = Vector2.ZERO
	p.facing = facing


func _hold(a: String) -> void:
	for key in ["move_up", "move_down", "move_left", "move_right"]:
		if key == a:
			Input.action_press(key)
		else:
			Input.action_release(key)


func _context() -> String:
	return str(game._context)


func _physics_process(_dt: float) -> bool:
	if current_scene == null or game == null:
		return false
	frames += 1
	if frames < 4:
		return false
	match step:
		0:
			var objects: Node = current_scene.get_node("World/Objects")
			var boxes: int = objects.get_node("VillageBodies").get_child_count()
			_check(boxes == 2 + 2 + 1, "the huts, the two facilities and the house have wall boxes (got %d)" % boxes)
			var hut: Dictionary = eco.world.workshops[0]
			_put(Vector2(hut.x, hut.y + 0.3))
			_next()
		1:
			var hut: Dictionary = eco.world.workshops[0]
			_check(_context() == "workshop:" + str(hut.id), "in front of a hut its door is the target (got %s)" % _context())
			_check(str(game._context_action).begins_with("제작소 1 Lv.1"), "the hut's label names it (got %s)" % game._context_action)
			game._interact()
			_check(game._hud.is_workshop_open() and game._hud._active_tab == game._hud.TAB_CRAFT, "E at a hut opens the 제작 tab")
			game._hud.close_workshop()
			var site: Dictionary = eco.state.village.sites.appraiser
			_put(Vector2(site.x, site.y + 0.3))
			_next()
		2:
			_check(_context() == "village:appraiser", "in front of the appraiser it is the target (got %s)" % _context())
			_check(str(game._context_action).contains("잔해 치우기"), "the ruin offers its first restoration step (got %s)" % game._context_action)
			var gold := float(eco.state.gold)
			game._interact()
			_check(int(eco.state.village.stage.appraiser) == 1 and float(eco.state.gold) == gold - 100.0, "E restores the ruin and pays 100 G")
			var plaza: Dictionary = Layout.district_parts(eco.state.village.district).plaza
			_put(Vector2(plaza.x, plaza.y + 0.2))
			_next()
		3:
			_check(_context() == "plaza:plaza", "at the plaza its notice board is the target (got %s)" % _context())
			game._interact()
			_check(game._hud.is_workshop_open() and game._hud._active_tab == game._hud.TAB_VILLAGE, "the notice board opens the 마을 tab")
			game._hud.close_workshop()
			# torches: an open spot south of the workshop
			_put(Vector2(eco.world.base) + Vector2(0, 1.6), "down")
			_next()
		4:
			var before: int = eco.world.torches.size()
			current_scene.get_node("World").torch_act()
			_check(eco.world.torches.size() == before + 1, "T sets a torch down in front")
			current_scene.get_node("World").torch_act()
			_check(eco.world.torches.size() == before, "T again picks it up")
			# the garden: stand south of its first row, facing it
			var cells := Layout.garden_cells(eco.state.village)
			var free_cell := -1
			for c: Dictionary in cells:
				if eco.decor_problem("flowerPot", int(c.cell), -1, Vector2(c.x, c.y + 0.4)).is_empty():
					free_cell = int(c.cell)
					break
			_check(free_cell >= 0, "some garden cell takes a flower pot")
			set_meta("cell", free_cell)
			var cell: Dictionary = cells[maxi(free_cell, 0)]
			_put(Vector2(cell.x, cell.y + 0.4), "up")
			_next()
		5:
			var cell := int(get_meta("cell"))
			_check(_context() == "garden:%d" % cell, "facing a garden cell it is the target (got %s)" % _context())
			game._interact()
			_check(eco.state.village.decor.size() == 1 and int(eco.state.village.decor[0].cell) == cell, "E sets a flower pot down")
			_next()
		6:
			# each press is its own frame: the target follows what is on the cell now
			game._interact()
			_check(int(eco.garden_ui.carry) == int(get_meta("cell")), "E again picks it up to move it")
			_next()
		7:
			game._interact()
			_check(int(eco.garden_ui.carry) == -1 and eco.state.village.decor.size() == 1, "E on the same cell puts it back")
			_next()
		8:
			current_scene.get_node("World").garden_key(true)
			_check(eco.state.village.decor.is_empty(), "R takes the decoration back")
			var door: Dictionary = Layout.district_parts(eco.state.village.district).house
			_house_door = Vector2(door.x, door.y)
			_put(_house_door + Vector2(0, 0.3))
			_next()
		9:
			_check(_context() == "house:house", "at the house door it is the target (got %s)" % _context())
			game._interact()
			_next()
		10:
			if current_scene.scene_file_path != "res://scenes/world/house.tscn":
				if frames > 120:
					return _fail("E at the house door did not go in")
				return false
			eco._record_position()
			var saved: Dictionary = eco.state.position
			_check(str(saved.scene) == "res://scenes/world/world_map.tscn" and Vector2(saved.x, saved.y).distance_to((_house_door + Vector2(0, 0.2)) * UNIT) < 1.0,
				"inside, the saved position is the house's door step (got %s)" % saved)
			_hold("move_down")
			_next()
		11:
			if current_scene.scene_file_path != "res://scenes/world/world_map.tscn":
				if frames > 300:
					return _fail("walking out through the door gap did not leave the house")
				return false
			_hold("")
			if frames < 4:
				return false
			var p := _player()
			_check((p.position / UNIT).distance_to(_house_door + Vector2(0, 0.25)) < 0.05, "outside again on the door step (at %s)" % (p.position / UNIT))
			# a hut's walls block: walk north into the second hut from just south of it
			var hut: Dictionary = eco.world.workshops[1]
			_put(Vector2(hut.x + 0.1, hut.y + 0.05))
			_hold("move_up")
			_next()
		12:
			if frames < 40:
				return false
			_hold("")
			var hut: Dictionary = eco.world.workshops[1]
			var box: Dictionary = Layout.object_box("workshop", hut.x, hut.y)
			_check(_player().position.y / UNIT > box.maxY - 0.01, "the hut's walls stop the player (at %s)" % (_player().position / UNIT))
			# a hired worker walks out of the workshop door to its vein and works there (web workers.js)
			var vein: Dictionary = eco.world.mines.filter(func(m: Dictionary) -> bool: return m.resource == "iron")[0]
			eco.world.discover(vein.id)
			eco.state.characters.append({"id": "w_test", "rarity": "rare", "resource": "iron", "mining": 2, "carry": 3, "move": 2})
			_next()
		13:
			var workers: Node = current_scene.get_node("World/Objects/Workers")
			var sim: Dictionary = workers._sim.get("w_test", {})
			if sim.is_empty() or sim.mode == "walk":
				if frames > 900:
					return _fail("the worker never reached its vein (at %s)" % [sim])
				return false
			var placed: Dictionary = workers._placements.filter(func(p: Dictionary) -> bool: return p.id == "w_test")[0]
			_check(sim.mode == "work" and Vector2(sim.x, sim.y) == Vector2(placed.x, placed.y) and not str(placed.mine_id).is_empty(),
				"the worker works at its spot by the iron vein (%s)" % [sim])
			if _failures.is_empty():
				print("WORLD OBJECTS PASS")
				quit(0)
			else:
				print("WORLD OBJECTS FAIL %d" % _failures.size())
				quit(1)
	return false


func _next() -> void:
	step += 1
	frames = 0


func _fail(msg: String) -> bool:
	_hold("")
	printerr("WORLD OBJECTS FAIL ", msg)
	quit(1)
	return false
