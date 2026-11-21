extends Node2D

const Regions := preload("res://scripts/expedition/regions.gd")
const Temple := preload("res://scripts/expedition/temple.gd")
const FONT := preload("res://fonts/Galmuri9.ttf")
const STEPS := {"up": Vector2i.UP, "down": Vector2i.DOWN, "left": Vector2i.LEFT, "right": Vector2i.RIGHT}
const KEYS := {KEY_W: "up", KEY_UP: "up", KEY_S: "down", KEY_DOWN: "down", KEY_A: "left", KEY_LEFT: "left",
	KEY_D: "right", KEY_RIGHT: "right", KEY_E: "use", KEY_SPACE: "use", KEY_R: "dose", KEY_ESCAPE: "exit"}

@onready var game: Node = get_node("/root/Game")
var region: String
var room: Node2D
var temple: RefCounted
var status: Label
var message: Label
var action: Button
var retreat: Button
var echo: AudioStreamPlayer
var finished := false

func _ready() -> void:
	region = game.expedition_region
	if not Regions.PORTALS.has(region):
		game.leave_expedition()
		return
	game._transitioning = false
	game.report("Expedition/" + region, Vector2(1, 3), "")
	if region == "temple":
		temple = Temple.new()
		temple.restore(game.workshop.world.expedition.get("temple"))
		room = preload("res://scripts/expedition/temple_view.gd").new()
		room.model = temple
	else:
		room = preload("res://scripts/expedition/topdown.gd").new()
		room.region = region
		room.progress = game.workshop.world.expedition
	add_child(room)
	status = _label(Rect2(8, 2, 464, 20), 12)
	message = _label(Rect2(150, 223, 194, 44), 10)
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if region == "temple":
		_setup_audio()
		_button("항정신제", Rect2(351, 193, 120, 28), "dose")
	_button("↑", Rect2(48, 219, 42, 24), "up")
	_button("←", Rect2(4, 245, 42, 24), "left")
	_button("↓", Rect2(48, 245, 42, 24), "down")
	_button("→", Rect2(92, 245, 42, 24), "right")
	action = _button("조사", Rect2(351, 220, 120, 25), "use")
	retreat = _button("지상으로", Rect2(351, 245, 120, 24), "exit")
	get_viewport().size_changed.connect(_center)
	_center()
	message.text = "경고 벽화를 읽자" if region == "temple" else "빛나는 조사 지점 위에서 행동"
	_refresh()

func _center() -> void:
	position = ((get_viewport_rect().size - Vector2(480, 270)) * 0.5).floor()
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(-position, get_viewport_rect().size), Color("#181e23"))

func _label(rect: Rect2, font_size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_override("font", FONT)
	label.add_theme_font_size_override("font_size", font_size)
	label.position = rect.position
	label.size = rect.size
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label

func _button(text: String, rect: Rect2, id: String) -> Button:
	var button := Button.new()
	button.name = "Action_" + id
	button.text = text
	button.position = rect.position
	button.size = rect.size
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_override("font", FONT)
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(_command.bind(id))
	add_child(button)
	return button

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or not KEYS.has(event.physical_keycode):
		return
	var id: String = KEYS[event.physical_keycode]
	if event.echo and id not in STEPS:
		return
	_command(id)
	get_viewport().set_input_as_handled()

func _command(id: String) -> void:
	if game._transitioning or (game.workshop.input_frozen() and id != "exit"):
		return
	if id == "exit":
		game.leave_expedition()
		return
	if finished:
		return
	if region == "temple":
		_temple_command(id)
	elif STEPS.has(id):
		if not room.step(STEPS[id]):
			message.text = "길이 막혀 있다"
	elif id == "use" and not room.target().is_empty():
		message.text = game.workshop.expedition_action(region, room.target())
	_refresh()

func _temple_command(id: String) -> void:
	match id:
		"up", "down":
			if temple.step(1 if id == "up" else -1):
				if temple.fear >= 20 and temple.moves % 5 == 0:
					echo.play()
				message.text = "발소리가 뒤에서 들린다" if temple.fear >= 55 else ""
				if temple.fear >= 100:
					temple.recover_at_entrance()
					message.text = "방향을 잃었다 · 입구 벽화에서 정신을 차렸다"
			else:
				message.text = "발밑에 돌벽이 닿는다"
		"left", "right":
			temple.turn(-1 if id == "left" else 1)
		"use":
			var before: int = temple.endings.size()
			message.text = temple.use()
			if temple.endings.size() > before:
				finished = true
				room.ending = temple.endings.back()
				retreat.text = "엔딩 · 지상으로"
		"dose":
			message.text = temple.medicate()
	game.workshop.record_temple(temple.checkpoint(), temple.endings)

func _refresh() -> void:
	var p: Vector2i = room.pos if temple == null else temple.pos
	if temple == null:
		var info: Dictionary = Regions.ROOMS[region]
		var target: String = room.target()
		var extra := ""
		if region == "swamp":
			extra = "  ·  배수기 가동 / 저수위" if room.progress.has("swamp_open") else "  ·  고수위"
		status.text = str(info.title) + extra
		action.text = "조사" if target.is_empty() else info.sites[target][1]
		action.disabled = target.is_empty()
	else:
		status.text = "고대 사원  |  환각 %d%%  ·  항정신제 %d  ·  봉인 %d/2" % [roundi(temple.fear), temple.doses, temple.circuit]
		action.text = Temple.MARKS.get(p, "둘러보기")
		action.disabled = finished
	room.queue_redraw()
	game.report("Expedition/" + region, Vector2(p), str(temple.facing) if temple != null else "")

func _setup_audio() -> void:
	var wave := AudioStreamWAV.new()
	wave.mix_rate = 12000
	wave.format = AudioStreamWAV.FORMAT_16_BITS
	var bytes := PackedByteArray()
	bytes.resize(18000)
	for i in range(9000):
		var time := i / 12000.0
		var envelope := sin(minf(1.0, time / 0.75) * PI)
		var tone := sin(time * TAU * (83.0 - time * 14.0)) + 0.6 * sin(time * TAU * 134.0)
		bytes.encode_s16(i * 2, roundi(tone * envelope * 1800))
	wave.data = bytes
	echo = AudioStreamPlayer.new()
	echo.stream = wave
	echo.volume_db = -17.0
	add_child(echo)
