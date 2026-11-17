extends Control
## On-screen stick for phones. Shown only when the device has a touch screen. A finger that starts in the left
## half of the screen drives the move_* actions (analog strength), like the stick in the web game.

const RADIUS := 34.0
var _finger := -1
var _origin := Vector2.ZERO
var _knob := Vector2.ZERO

func _ready() -> void:
	visible = DisplayServer.is_touchscreen_available()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_origin = Vector2(56, get_viewport_rect().size.y - 56)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if get_node("/root/Game").workshop_is_open():
		if _finger != -1:
			_finger = -1
			_origin = Vector2(56, get_viewport_rect().size.y - 56)
			_apply(Vector2.ZERO)
		return
	if event is InputEventScreenTouch:
		if event.pressed and _finger == -1 and event.position.x < get_viewport_rect().size.x * 0.5:
			_finger = event.index
			_origin = event.position
			_apply(Vector2.ZERO)
		elif not event.pressed and event.index == _finger:
			_finger = -1
			_apply(Vector2.ZERO)
			_origin = Vector2(56, get_viewport_rect().size.y - 56)
	elif event is InputEventScreenDrag and event.index == _finger:
		_apply((event.position - _origin).limit_length(RADIUS))

func _apply(offset: Vector2) -> void:
	_knob = offset
	var v := offset / RADIUS
	for pair in [["move_left", -v.x], ["move_right", v.x], ["move_up", -v.y], ["move_down", v.y]]:
		if pair[1] > 0.2:
			Input.action_press(pair[0], pair[1])
		else:
			Input.action_release(pair[0])
	queue_redraw()

func _draw() -> void:
	draw_circle(_origin, RADIUS + 6, Color(0, 0, 0, 0.28))
	draw_arc(_origin, RADIUS + 6, 0, TAU, 32, Color(1, 1, 1, 0.5), 1.5)
	draw_circle(_origin + _knob, 14, Color(1, 1, 1, 0.55))
