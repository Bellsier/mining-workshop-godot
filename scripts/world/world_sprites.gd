extends RefCounted
## Pixel sprites painted from rectangles, as the web version paints them (sprites.js tdPainter, tdPropSprite,
## tdOreSprite, tdBaseSprite): the same rectangles and colours, one sprite pixel to one world pixel (64 per unit,
## web TD_UNIT_PX at zoom 1). Each sprite is painted once and kept as a texture. Drawing only: nothing here is saved.

## web TD_RES_COLORS: [ore colour, highlight] per resource.
const RES_COLORS := {
	"iron": ["#b8704f", "#e09a72"], "coal": ["#2c3034", "#4d545a"], "mana": ["#8a5cd6", "#c4a2ff"],
	"crystal": ["#4fc4dc", "#bff3ff"], "rareMetal": ["#b9c3cc", "#f1f5f8"], "relic": ["#c9a24a", "#f2d68c"],
	"cosmicShard": ["#e06fa8", "#ffc0df"], "plasma": ["#ff4fcf", "#ffd0f4"],
}
## web tdDrawSprite anchorY: how many sprite pixels below the ground point the sprite's bottom row is.
const ANCHOR := {"prop": 2, "ore": 6, "base": 4}

static var _cache := {}


## Rectangles onto an image, with the canvas's source-over blending for see-through colours (web tdPainter).
class Painter:
	var image: Image

	func _init(w: int, h: int) -> void:
		image = Image.create(w, h, false, Image.FORMAT_RGBA8)

	func rect(x: int, y: int, w: int, h: int, color: String) -> void:
		if w <= 0 or h <= 0:
			return
		var c := WorldSprites.parse(color)
		var x0 := maxi(0, x)
		var y0 := maxi(0, y)
		var x1 := mini(image.get_width(), x + w)
		var y1 := mini(image.get_height(), y + h)
		if x1 <= x0 or y1 <= y0:
			return
		if c.a >= 1.0:
			image.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), c)
			return
		for py in range(y0, y1):
			for px in range(x0, x1):
				image.set_pixel(px, py, image.get_pixel(px, py).blend(c))

	## web P.disc: a filled pixel circle.
	func disc(cx: int, cy: int, r: int, color: String) -> void:
		for y in range(-r, r + 1):
			var hw := floori(sqrt(r * r - y * y + r * 0.6))
			rect(cx - hw, cy + y, hw * 2 + 1, 1, color)

	func texture() -> ImageTexture:
		return ImageTexture.create_from_image(image)


const WorldSprites := preload("res://scripts/world/world_sprites.gd")


## "#rrggbb" or "rgba(r,g,b,a)".
static func parse(color: String) -> Color:
	if color.begins_with("rgba("):
		var parts := color.substr(5, color.length() - 6).split(",")
		return Color8(int(parts[0]), int(parts[1]), int(parts[2]), roundi(float(parts[3]) * 255.0))
	return Color.html(color)


static func _kept(key: String, paint: Callable) -> ImageTexture:
	if not _cache.has(key):
		_cache[key] = paint.call()
	return _cache[key]


## Where a sprite is drawn so its ground point is `at` (web tdDrawSprite: centred, bottom row `anchor` px below).
static func origin(texture: Texture2D, at: Vector2, anchor: int) -> Vector2:
	return Vector2(roundf(at.x - texture.get_width() / 2.0), roundf(at.y - texture.get_height() + anchor))


## web tdPropSprite. Unknown kinds: a pebble, as on the web.
static func prop(kind: String) -> ImageTexture:
	return _kept("prop:" + kind, func() -> ImageTexture: return _paint_prop(kind))


static func _tree(w: int, h: int, r: int, cx: int, cy: int, dark: String, mid: String, light: String) -> Painter:
	var p := Painter.new(w, h)
	p.rect(cx - 6, h - 3, 12, 3, "rgba(0,0,0,0.25)")
	p.rect(cx - 2, cy + r - 2, 4, h - (cy + r - 2) - 1, "#5a4030")
	p.disc(cx, cy, r, dark)
	p.disc(cx - 1, cy - 1, r - 2, mid)
	p.disc(cx - 3, cy - 3, maxi(2, r - 6), light)
	return p


static func _paint_prop(kind: String) -> ImageTexture:
	var p: Painter
	match kind:
		"bigTree":
			p = _tree(32, 42, 13, 16, 15, "#2f5634", "#3f6e44", "#5a8e57")
		"sparseTree":
			p = _tree(24, 34, 9, 12, 12, "#3a5d36", "#4f7a46", "#6a9655")
		"grass":
			p = Painter.new(12, 8)
			p.rect(1, 5, 2, 3, "#5b8a4a"); p.rect(4, 3, 2, 5, "#6b9b55"); p.rect(7, 4, 2, 4, "#5b8a4a"); p.rect(9, 6, 2, 2, "#6b9b55")
		"rock":
			p = Painter.new(16, 12)
			p.rect(2, 10, 12, 2, "rgba(0,0,0,0.22)"); p.disc(8, 6, 5, "#77726b"); p.rect(4, 3, 4, 2, "#948e86"); p.rect(5, 9, 7, 1, "#5e5a55")
		"clearing":
			p = Painter.new(34, 16)
			for y in 16:
				var hw := floori(16.0 * sqrt(1.0 - pow((y - 7.5) / 8.0, 2)))
				p.rect(17 - hw, y, hw * 2, 1, "rgba(160,190,110,0.35)")
			p.rect(10, 6, 1, 1, "#e8d38a"); p.rect(22, 9, 1, 1, "#d98aa0")
		"exposedVein", "undevelopedVein", "rareVein":
			var c: Array = ["#e06fa8", "#ffc0df"] if kind == "rareVein" else ["#c3ccd4", "#f1f5f8"] if kind == "undevelopedVein" else ["#b8704f", "#e09a72"]
			p = Painter.new(16, 12)
			p.rect(2, 10, 12, 2, "rgba(0,0,0,0.2)"); p.disc(8, 6, 5, "#6e6a64")
			p.rect(5, 5, 2, 2, c[0]); p.rect(9, 4, 2, 2, c[0]); p.rect(8, 7, 2, 1, c[1]); p.rect(5, 5, 1, 1, c[1])
		"crystal":
			p = Painter.new(14, 18)
			p.rect(2, 15, 10, 3, "rgba(0,0,0,0.25)"); p.rect(5, 3, 4, 13, "#7fd7ec"); p.rect(6, 1, 2, 2, "#bff3ff")
			p.rect(2, 8, 3, 8, "#5fc0d8"); p.rect(9, 6, 3, 10, "#6ccbe0"); p.rect(6, 4, 1, 10, "#e8fbff")
		"oldShaftEntrance":
			p = Painter.new(30, 26)
			p.rect(2, 6, 26, 20, "#5e5a55"); p.rect(6, 10, 18, 16, "#1e1a17"); p.rect(4, 6, 3, 20, "#7a5a36")
			p.rect(23, 6, 3, 20, "#7a5a36"); p.rect(3, 5, 24, 3, "#8a6440")
		"timberSupport":
			p = Painter.new(16, 22)
			p.rect(2, 20, 12, 2, "rgba(0,0,0,0.2)"); p.rect(2, 4, 3, 17, "#7a5a36"); p.rect(11, 4, 3, 17, "#7a5a36"); p.rect(1, 2, 14, 3, "#8a6440")
		"mineCart":
			p = Painter.new(20, 16)
			p.rect(2, 14, 16, 2, "rgba(0,0,0,0.22)"); p.rect(2, 4, 16, 8, "#6a625a"); p.rect(3, 5, 14, 3, "#3a3632")
			p.rect(4, 4, 3, 2, "#b8704f"); p.rect(9, 3, 3, 2, "#2c3034"); p.rect(4, 11, 4, 4, "#2b2b2b"); p.rect(12, 11, 4, 4, "#2b2b2b")
		"diggingMarks":
			p = Painter.new(16, 10)
			p.rect(2, 3, 5, 2, "#6e5a42"); p.rect(8, 6, 6, 2, "#6e5a42"); p.rect(5, 7, 2, 1, "#8a7356")
		_:
			p = Painter.new(8, 8)
			p.rect(2, 2, 4, 4, "#888888")
	return p.texture()


## web tdOreSprite: a vein's rock, by look: "undiscovered" (mossy, no ore), "discovered", "secured" (a staked flag).
static func ore(resource: String, look: String) -> ImageTexture:
	var key := "ore:undiscovered" if look == "undiscovered" else "ore:%s:%s" % [resource, look]
	return _kept(key, func() -> ImageTexture: return _paint_ore(resource, look))


static func _paint_ore(resource: String, look: String) -> ImageTexture:
	var p := Painter.new(24, 20)
	var undiscovered := look == "undiscovered"
	var rock: Array = ["#6a6660", "#55514c", "#827d76"] if undiscovered else ["#7b766f", "#5e5a55", "#9a948c"]
	p.rect(3, 17, 18, 3, "rgba(0,0,0,0.25)")
	p.disc(12, 11, 8, rock[0])
	p.rect(5, 14, 14, 4, rock[1]); p.rect(7, 17, 10, 1, rock[1])
	p.rect(7, 5, 6, 2, rock[2]); p.rect(6, 7, 3, 2, rock[2])
	if undiscovered:
		p.rect(14, 8, 4, 2, "#5f7d4e"); p.rect(15, 7, 2, 1, "#6f8f5c") # moss
		p.rect(9, 10, 3, 1, rock[1]); p.rect(13, 13, 3, 1, rock[1])
	else:
		var colors: Array = RES_COLORS.get(resource, ["#aaaaaa", "#ffffff"])
		var k := 0
		for xy: Array in [[8, 9], [13, 7], [15, 11], [10, 13], [6, 11]]:
			p.rect(xy[0], xy[1], 2, 2, colors[0])
			if k % 2 == 0:
				p.rect(xy[0], xy[1], 1, 1, colors[1])
			k += 1
		p.rect(12, 10, 3, 2, colors[0]); p.rect(12, 10, 1, 1, colors[1])
	if look == "secured":
		p.rect(19, 6, 1, 12, "#8a6440"); p.rect(20, 6, 4, 3, "#3fc9b0"); p.rect(20, 9, 2, 1, "#2f9c88") # a staked flag
	return p.texture()


## web TD_BUILDING: door, glass and step colours shared by the buildings.
const BUILDING := {
	"doorFrame": "#4a3626", "door": "#6a4a30", "doorDark": "#553a26", "doorLight": "#7f5a3a", "strap": "#4b4440",
	"handle": "#e2b23c", "step": "#b4aaa0", "stepTop": "#cfc6bc", "glass": "#f3d27a", "glassTop": "#f7e2a0",
}


## web tdRoof: shingle courses from `y`, the ridge `w` wide at `x0`, widening `spread` px a side to the eaves.
static func _roof(p: Painter, x0: int, y: int, w: int, rows: int, spread: int, light: String, mid: String, dark: String) -> void:
	for k in rows:
		var o := floori(k * spread / float(maxi(1, rows - 1)))
		var x := x0 - o
		var rw := w + 2 * o
		var c := k % 3
		p.rect(x, y + k, rw, 1, light if c == 0 else mid if c == 1 else dark)
		if c == 1:
			var tx := x + 2 + (floori(k / 3.0) % 2) * 3
			while tx < x + rw - 1:
				p.rect(tx, y + k, 1, 1, dark)
				tx += 6


## web tdPlanks: boards with seams every 3 rows and staggered ends.
static func _planks(p: Painter, x: int, y: int, w: int, h: int, base: String, seam: String) -> void:
	p.rect(x, y, w, h, base)
	var r := 0
	while r * 3 < h:
		if r * 3 + 2 < h:
			p.rect(x, y + r * 3 + 2, w, 1, seam)
		var bx := x + 4 + (r % 2) * 7
		while bx < x + w - 1:
			p.rect(bx, y + r * 3, 1, mini(2, h - r * 3), seam)
			bx += 14
		r += 1


## web tdStones: blocks two rows high in a running bond, lit along their top.
static func _stones(p: Painter, x: int, y: int, w: int, h: int, mortar: String, stone: String, light: String) -> void:
	p.rect(x, y, w, h, mortar)
	var r := 0
	while r * 3 < h:
		var rows := mini(2, h - r * 3)
		var bx := x - (r % 2) * 3
		while bx < x + w:
			var a := maxi(x, bx)
			var b := mini(x + w, bx + 5)
			p.rect(a, y + r * 3, b - a, rows, stone)
			p.rect(a, y + r * 3, b - a, 1, light)
			bx += 6
		r += 1


## web tdDoor (without the arch).
static func _door(p: Painter, x: int, y: int, w: int, h: int) -> void:
	for r in h:
		p.rect(x, y + r, w, 1, BUILDING.doorFrame)
	for r in range(1, h):
		p.rect(x + 1, y + r, w - 2, 1, BUILDING.door)
	p.rect(x + 1, y + 2, 1, h - 2, BUILDING.doorLight)
	var px := x + 3
	while px < x + w - 2:
		p.rect(px, y + 2, 1, h - 2, BUILDING.doorDark)
		px += 3


## web tdWindow: frame, warm glass lit at the top, a mullion cross and a sill.
static func _window(p: Painter, x: int, y: int, w: int, h: int, sill: String) -> void:
	p.rect(x, y, w, h, "#5a3b28"); p.rect(x + 1, y + 1, w - 2, h - 2, BUILDING.glass); p.rect(x + 1, y + 1, w - 2, 1, BUILDING.glassTop)
	p.rect(x + floori(w / 2.0), y + 1, 1, h - 2, "#5a3b28"); p.rect(x + 1, y + floori(h / 2.0), w - 2, 1, "#5a3b28")
	p.rect(x - 1, y + h, w + 2, 1, sill)


## web tdBaseSprite: the miners' cabin (공방), 64 x 58, the door at the bottom centre.
static func base() -> ImageTexture:
	return _kept("base", _paint_base)


static func _paint_base() -> ImageTexture:
	var p := Painter.new(64, 58)
	var B := BUILDING
	p.rect(4, 54, 56, 4, "rgba(0,0,0,0.22)")
	_planks(p, 6, 27, 52, 23, "#b08a5a", "#97734a")
	_stones(p, 6, 50, 52, 4, "#6c645b", "#9a9086", "#b4aaa0")
	p.rect(6, 27, 2, 23, "#8a6440"); p.rect(6, 27, 1, 23, "#a07a50"); p.rect(56, 27, 2, 23, "#8a6440"); p.rect(57, 27, 1, 23, "#6f5034")
	p.rect(6, 27, 52, 2, "#8a6440"); p.rect(6, 29, 52, 1, "#6f5034")
	_roof(p, 11, 5, 42, 21, 8, "#b05a46", "#9a4a3a", "#7a3a2e")
	p.rect(2, 25, 60, 2, "#6a3026"); p.rect(8, 30, 48, 1, "rgba(60,30,20,0.18)")
	# the gable sign: a pickaxe and a gem
	p.rect(24, 12, 16, 8, "#5a3b28"); p.rect(25, 13, 14, 6, "#c9a26a"); p.rect(25, 13, 14, 1, "#e0bf86")
	p.rect(27, 14, 6, 1, "#5d5d63"); p.rect(27, 15, 1, 1, "#5d5d63"); p.rect(32, 15, 1, 1, "#5d5d63"); p.rect(30, 15, 1, 3, "#7a5236")
	p.rect(35, 15, 2, 2, "#4fc4dc"); p.rect(35, 15, 1, 1, "#bff3ff")
	# chimney
	p.rect(44, 1, 7, 11, "#7a6a5e"); p.rect(44, 1, 2, 11, "#958576")
	for y in range(3, 12, 3):
		p.rect(44, y, 7, 1, "#5f544b")
	p.rect(43, 0, 9, 2, "#a59585")
	_window(p, 11, 32, 11, 11, "#a07a50"); _window(p, 43, 32, 11, 11, "#a07a50")
	_door(p, 25, 32, 14, 20)
	p.rect(26, 37, 12, 1, B.strap); p.rect(26, 46, 12, 1, B.strap); p.rect(35, 41, 2, 2, B.handle)
	p.rect(23, 52, 18, 2, B.step); p.rect(23, 52, 18, 1, B.stepTop)
	p.rect(19, 40, 6, 1, "#77777e"); p.rect(19, 41, 1, 1, "#5d5d63"); p.rect(24, 41, 1, 1, "#5d5d63"); p.rect(22, 41, 1, 12, "#8a6440")
	p.rect(54, 30, 2, 15, "#866342"); p.rect(8, 30, 1, 19, "#c29a65")
	p.rect(9, 31, 14, 1, "#c7a16f"); p.rect(40, 31, 15, 1, "#b58d59")
	p.rect(9, 48, 10, 1, "#98714b"); p.rect(40, 48, 8, 1, "#98714b")
	p.rect(12, 5, 31, 1, "#ca795b"); p.rect(11, 6, 30, 1, "#bd6b50")
	p.rect(8, 14, 13, 1, "#bf6d52"); p.rect(6, 20, 16, 1, "#b9634b")
	p.rect(49, 14, 7, 1, "#854333"); p.rect(48, 21, 11, 1, "#854333")
	p.rect(3, 25, 57, 1, "#a4523d")
	p.rect(10, 43, 13, 1, "#d0a66e"); p.rect(42, 43, 13, 1, "#c59b63")
	p.rect(25, 31, 14, 1, "#d0a66e")
	p.rect(8, 44, 15, 6, "#a78053"); p.rect(40, 44, 16, 6, "#98734c")
	p.rect(8, 50, 15, 4, "#827569"); p.rect(40, 50, 18, 4, "#827569")
	p.rect(8, 47, 14, 2, "#634832"); p.rect(8, 47, 14, 1, "#d0a16a")
	p.rect(9, 49, 2, 5, "#765237"); p.rect(19, 49, 2, 5, "#60432f")
	p.rect(10, 50, 9, 1, "#98734c")
	p.rect(10, 43, 9, 1, "#c1c5c0"); p.rect(10, 44, 9, 1, "#a0aaa9")
	p.rect(13, 45, 3, 1, "#4a5156"); p.rect(12, 46, 6, 1, "#626c70")
	p.rect(19, 43, 1, 4, "#855635"); p.rect(18, 43, 4, 1, "#8f979c")
	p.rect(9, 30, 1, 6, "#60432f"); p.rect(8, 34, 3, 5, "#60432f"); p.rect(9, 35, 2, 2, "#ffd27a"); p.rect(9, 35, 2, 1, "#fff3b0")
	p.rect(44, 3, 7, 1, "#aa7350"); p.rect(44, 9, 7, 1, "#9b6547")
	p.rect(44, 2, 1, 9, "#c39566")
	p.rect(42, 46, 14, 8, "#654a34"); p.rect(43, 47, 12, 1, "#c39a63")
	p.rect(43, 49, 12, 1, "#aa8052"); p.rect(43, 52, 12, 1, "#987044")
	p.rect(43, 44, 5, 2, "#8f979c"); p.rect(49, 44, 5, 2, "#8f979c")
	p.rect(43, 44, 5, 1, "#c1c5c0"); p.rect(49, 44, 5, 1, "#c1c5c0")
	p.rect(41, 45, 1, 9, "#ad8055"); p.rect(55, 46, 1, 8, "#86613e")
	p.rect(23, 52, 18, 2, B.step); p.rect(23, 52, 18, 1, B.stepTop)
	return p.texture()
