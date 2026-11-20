extends Node2D

const REACH := 28.0
const FONT = preload("res://fonts/Galmuri9.ttf")
const MINES := {
	"iron": [Vector2(684, 204), Color("b6a698"), "철광석"],
	"coal": [Vector2(760, 207), Color("707281"), "석탄"],
	"mana": [Vector2(621, 191), Color("58c9a6"), "마정석"],
	"crystal": [Vector2(587, 249), Color("a9dafb"), "결정"],
	"rareMetal": [Vector2(492, 200), Color("edbd64"), "희귀 금속"],
	"relic": [Vector2(449, 249), Color("df8b66"), "고대 유물"],
	"cosmicShard": [Vector2(329, 197), Color("c99aee"), "우주 파편"],
	"plasma": [Vector2(271, 253), Color("ea7ec7"), "플라즈마"],
}

var workshop: Node
var workshop_entrance := Vector2.ZERO
var active_id := ""
var _access: Dictionary = {}

func setup(system: Node, entrance: Vector2) -> void:
	workshop = system
	workshop_entrance = entrance
	workshop.changed.connect(_refresh_access)
	_refresh_access()

func context_at(point: Vector2) -> String:
	var nearest := REACH
	var found := ""
	if workshop_entrance.distance_to(point) <= nearest:
		nearest = workshop_entrance.distance_to(point)
		found = "workshop"
	for id: String in MINES:
		var at: Vector2 = MINES[id][0]
		var distance := at.distance_to(point)
		if distance < nearest:
			nearest = distance
			found = id
	if active_id != found:
		active_id = found
		queue_redraw()
	return found

func action_label(id: String) -> String:
	if id == "workshop":
		return "공방 열기"
	if MINES.has(id):
		return "%s %s" % [MINES[id][2], "채굴" if _access.get(id, false) else "잠김"]
	return ""

func _refresh_access() -> void:
	var current: Dictionary = {}
	for id: String in MINES:
		current[id] = workshop.is_resource_open(id)
	if current != _access:
		_access = current
		queue_redraw()

func _draw() -> void:
	for id: String in MINES:
		var at: Vector2 = MINES[id][0]
		var color: Color = MINES[id][1]
		if not _access.get(id, false):
			color = color.darkened(0.52)
		draw_colored_polygon(PackedVector2Array([at + Vector2(-8, 3), at + Vector2(-6, -4), at + Vector2(0, -8),
			at + Vector2(6, -6), at + Vector2(9, 0), at + Vector2(5, 5), at + Vector2(-5, 6)]), color.darkened(0.48))
		draw_colored_polygon(PackedVector2Array([at + Vector2(-5, 0), at + Vector2(-3, -4), at + Vector2(3, -5),
			at + Vector2(5, -1), at + Vector2(1, 2)]), color)
		draw_rect(Rect2(at + Vector2(4, 1), Vector2(2, 2)), color.lightened(0.15))
		if active_id == id:
			draw_arc(at, 11.0, 0.0, TAU, 24, Color("f0d599"), 1.0)
	var sign_at := workshop_entrance + Vector2(-10, -24)
	draw_string_outline(FONT, sign_at, "공방", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color("241b19"))
	draw_string(FONT, sign_at, "공방", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("f7e1b8"))
