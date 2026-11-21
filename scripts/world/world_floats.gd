extends Node2D
## Texts that rise from where the player acted (web render.js tdAddFloat / TD_FLOAT): "+1 철광석" over the vein that
## was mined, "광맥 확보!" over the one secured. A float of the same unit still rising from the same point takes the
## new amount in (+1 → +2 철광석) instead of adding a line; at most three lines stack at one point. Drawn above the
## dusk. Drawing only: nothing here is saved.

const FONT := preload("res://fonts/Galmuri9.ttf")
## web TD_FLOAT: how long a float shows (ms), how many stack at one point, the gap between stacked lines; a float
## rises RISE world pixels as it fades.
const MS := 1200.0
const MAX_PER_POINT := 3
const LINE := 11.0
const RISE := 17.0
const OK_COLOR := Color("fff3b0")

var floats: Array = []


func _ready() -> void:
	z_index = 4002
	z_as_relative = false


## `at` in world pixels, the ground point of what was acted on; `lift` how far above it the float starts.
func add(text: String, at: Vector2, color := OK_COLOR, lift := 24.0, unit := "", amount := 0.0) -> void:
	var now := float(Time.get_ticks_msec())
	var live: Array = floats.filter(func(f: Dictionary) -> bool: return f.at == at and now - f.t0 < MS)
	if not unit.is_empty():
		for f: Dictionary in live:
			if f.unit == unit:
				f.amount += amount
				f.text = "+%s %s" % [_format(f.amount), unit]
				f.t0 = now
				return
	if live.size() >= MAX_PER_POINT:
		floats.erase(live[0])
		live.pop_front()
		for i in live.size():
			live[i].stack = i
	floats.append({"text": text, "at": at, "t0": now, "color": color, "lift": lift, "stack": live.size(), "unit": unit, "amount": amount})


static func _format(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, roundf(v)) else "%.1f" % v


func _process(_delta: float) -> void:
	if floats.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	floats = floats.filter(func(f: Dictionary) -> bool: return now - f.t0 < MS)
	queue_redraw()


func _draw() -> void:
	var now := float(Time.get_ticks_msec())
	for f: Dictionary in floats:
		var k := clampf((now - f.t0) / MS, 0.0, 1.0)
		var size := FONT.get_string_size(f.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
		var y: float = f.at.y - f.lift - f.stack * LINE - k * RISE
		var at := Vector2(roundf(f.at.x - size.x / 2.0), roundf(y))
		var c: Color = f.color
		c.a = 1.0 - k * k
		draw_string_outline(FONT, at, f.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color(0.13, 0.1, 0.09, c.a))
		draw_string(FONT, at, f.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, c)
