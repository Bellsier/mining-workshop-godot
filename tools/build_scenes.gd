extends SceneTree
## One-time builder for the trial's TileSet and scenes. Run from the project folder:
##   godot --headless --path . --script res://tools/build_scenes.gd
## After that, edit the scenes in the editor; running this again overwrites them.

const T := 16
enum { GRASS, PATH, ROCK, ROCK_TOP, MOUTH, TFLOOR, TWALL, FLOWERS }
const SOLID := [ROCK, ROCK_TOP, TWALL]

func _init() -> void:
	var ts := _tileset()
	ResourceSaver.save(ts, "res://art/tileset.tres")
	ts = load("res://art/tileset.tres")
	_save(_player(), "res://scenes/player.tscn")
	_save(_overworld(ts), "res://scenes/overworld.tscn")
	_save(_tunnel(ts), "res://scenes/tunnel.tscn")
	print("scenes built")
	quit()

func _tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(T, T)
	ts.add_physics_layer()
	var src := TileSetAtlasSource.new()
	src.texture = load("res://art/tiles.png")
	src.texture_region_size = Vector2i(T, T)
	ts.add_source(src, 0)
	for i in 8:
		src.create_tile(Vector2i(i, 0))
		if i in SOLID:
			var td := src.get_tile_data(Vector2i(i, 0), 0)
			td.add_collision_polygon(0)
			td.set_collision_polygon_points(0, 0, PackedVector2Array([Vector2(-8, -8), Vector2(8, -8), Vector2(8, 8), Vector2(-8, 8)]))
	return ts

func _own(node: Node, root: Node) -> void:
	for c in node.get_children():
		c.owner = root
		if c.scene_file_path == "":
			_own(c, root)

func _save(root: Node, path: String) -> void:
	_own(root, root)
	var ps := PackedScene.new()
	ps.pack(root)
	ResourceSaver.save(ps, path)

func _player() -> Node:
	var p := CharacterBody2D.new()
	p.name = "Player"
	p.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	p.set_script(load("res://scripts/player.gd"))
	var frames := SpriteFrames.new()
	frames.remove_animation("default")
	var sheet: Texture2D = load("res://art/player.png")
	for row in 4:
		var dir: String = ["down", "left", "right", "up"][row]
		for kind in ["idle_", "walk_"]:
			var anim: String = kind + dir
			frames.add_animation(anim)
			frames.set_animation_speed(anim, 8.0)
			for f in (1 if kind == "idle_" else 4):
				var at := AtlasTexture.new()
				at.atlas = sheet
				at.region = Rect2(f * 16, row * 24, 16, 24)
				frames.add_frame(anim, at)
	var spr := AnimatedSprite2D.new()
	spr.name = "Sprite"
	spr.sprite_frames = frames
	spr.animation = "idle_down"
	spr.offset = Vector2(0, -12)   # feet at the node origin
	p.add_child(spr)
	var col := CollisionShape2D.new()
	col.name = "Feet"
	var r := RectangleShape2D.new()
	r.size = Vector2(10, 6)
	col.shape = r
	col.position = Vector2(0, -3)
	p.add_child(col)
	var cam := Camera2D.new()
	cam.name = "Camera2D"
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 6.0
	p.add_child(cam)
	return p

func _layer(name: String, ts: TileSet) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = name
	l.tile_set = ts
	return l

func _ui(root: Node, hint: String) -> void:
	var ui := CanvasLayer.new()
	ui.name = "UI"
	root.add_child(ui)
	var label := Label.new()
	label.name = "Hint"
	label.text = hint
	label.position = Vector2(6, 4)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 3)
	ui.add_child(label)
	var stick := Control.new()
	stick.name = "TouchStick"
	stick.set_script(load("res://scripts/touch_stick.gd"))
	ui.add_child(stick)

func _spawn(root: Node, name: String, pos: Vector2) -> void:
	var m := Marker2D.new()
	m.name = name
	m.position = pos
	root.get_node("Spawns").add_child(m)

func _door(name: String, pos: Vector2, size: Vector2, scene: String, spawn: String) -> Area2D:
	var a := Area2D.new()
	a.name = name
	a.position = pos
	a.set_script(load("res://scripts/door.gd"))
	a.set("target_scene", scene)
	a.set("target_spawn", spawn)
	var c := CollisionShape2D.new()
	c.name = "Shape"
	var r := RectangleShape2D.new()
	r.size = size
	c.shape = r
	a.add_child(c)
	return a

func _overworld(ts: TileSet) -> Node:
	var W := 60
	var H := 24
	var root := Node2D.new()
	root.name = "Overworld"
	root.set_script(load("res://scripts/level.gd"))
	var ground := _layer("Ground", ts)
	var mountains := _layer("Mountains", ts)
	root.add_child(ground)
	root.add_child(mountains)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for y in H:
		for x in W:
			ground.set_cell(Vector2i(x, y), 0, Vector2i(FLOWERS if rng.randf() < 0.06 else GRASS, 0))
	for x in range(10, 46):          # road west from the workshop to the mountain mouth
		ground.set_cell(Vector2i(x, 14), 0, Vector2i(PATH, 0))
	for y in range(11, 15):          # path from the workshop door down to the road
		ground.set_cell(Vector2i(45, y), 0, Vector2i(PATH, 0))
	# Western mountains: columns 0..9; the face (column 9) has snow ridges; the tunnel mouth is at (9, 14).
	for y in H:
		for x in 10:
			mountains.set_cell(Vector2i(x, y), 0, Vector2i(ROCK_TOP if x == 9 else ROCK, 0))
	mountains.set_cell(Vector2i(9, 14), 0, Vector2i(MOUTH, 0))
	for x in range(10, W):           # a low ridge closes the top and bottom edges
		mountains.set_cell(Vector2i(x, 0), 0, Vector2i(ROCK_TOP, 0))
		mountains.set_cell(Vector2i(x, H - 1), 0, Vector2i(ROCK, 0))
	for y in H:
		mountains.set_cell(Vector2i(W - 1, y), 0, Vector2i(ROCK, 0))
	var ws := StaticBody2D.new()
	ws.name = "Workshop"
	ws.position = Vector2(45 * T + 8, 10 * T)
	var sprite := Sprite2D.new()
	sprite.name = "Sprite"
	sprite.texture = load("res://art/workshop.png")
	sprite.offset = Vector2(0, -8)
	ws.add_child(sprite)
	var wc := CollisionShape2D.new()
	wc.name = "Shape"
	var wr := RectangleShape2D.new()
	wr.size = Vector2(36, 16)
	wc.shape = wr
	wc.position = Vector2(0, 4)
	ws.add_child(wc)
	root.add_child(ws)
	# The tunnel entrance: move this Area2D (and set the mouth tile) to move the entrance.
	# The area is wider than the one-tile mouth (24x40) so a player a few pixels off the road still gets in.
	root.add_child(_door("TunnelEntrance", Vector2(9 * T + 12, 14 * T + 8), Vector2(24, 40), "res://scenes/tunnel.tscn", "FromOutside"))
	var spawns := Node2D.new()
	spawns.name = "Spawns"
	root.add_child(spawns)
	_spawn(root, "Start", Vector2(45 * T + 8, 12 * T + 8))
	_spawn(root, "FromTunnel", Vector2(11 * T + 8, 14 * T + 12))
	var player: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(player)
	_ui(root, "공방 앞 → 서쪽 산맥의 터널로 가 보세요 · WASD/방향키 · 휴대폰: 왼쪽 화면을 끌기")
	return root

func _tunnel(ts: TileSet) -> Node:
	var W := 40
	var H := 19
	var root := Node2D.new()
	root.name = "Tunnel"
	root.set_script(load("res://scripts/level.gd"))
	var floor_layer := _layer("Floor", ts)
	var walls := _layer("Walls", ts)
	root.add_child(floor_layer)
	root.add_child(walls)
	for y in H:
		for x in W:
			if y >= 8 and y <= 10 and x >= 1:
				floor_layer.set_cell(Vector2i(x, y), 0, Vector2i(TFLOOR, 0))
			else:
				walls.set_cell(Vector2i(x, y), 0, Vector2i(TWALL, 0))
	var mod := CanvasModulate.new()
	mod.name = "Dark"
	mod.color = Color(0.72, 0.68, 0.78)
	root.add_child(mod)
	var sign := Label.new()
	sign.name = "Sign"
	sign.text = "공사 중 · 이 너머는 다음 시험판에서"
	sign.position = Vector2(2 * T, 7 * T - 2)
	sign.add_theme_font_size_override("font_size", 10)
	root.add_child(sign)
	root.add_child(_door("Exit", Vector2(39 * T + 8, 9 * T + 8), Vector2(12, 3 * T), "res://scenes/overworld.tscn", "FromTunnel"))
	var spawns := Node2D.new()
	spawns.name = "Spawns"
	root.add_child(spawns)
	_spawn(root, "FromOutside", Vector2(37 * T, 9 * T + 12))
	var player: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(player)
	_ui(root, "터널 안 · 오른쪽(동쪽) 입구로 나가면 산맥 앞으로 돌아갑니다")
	return root

