extends RefCounted
## Discrete movement and persistence for the first-person temple. No surface player or camera is moved.

const GRID := [
	"###########",
	"#...#.....#",
	"#.#.#.###.#",
	"#.#...#...#",
	"#.###.#.#.#",
	"#.....#.#.#",
	"###.###.#.#",
	"#...#...#.#",
	"#.#...#...#",
	"#.........#",
	"###########",
]
const ENTRY := Vector2i(1, 1)
const CIRCUIT_A := Vector2i(3, 5)
const CIRCUIT_B := Vector2i(8, 9)
const MIRROR := Vector2i(9, 1)
const PILLAR := Vector2i(1, 9)
const RELIEF := Vector2i(5, 3)
const ECHO_START := Vector2i(9, 5)
const DIR := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const MARKS := {ENTRY: "경고 벽화", CIRCUIT_A: "첫 번째 봉인 회로", CIRCUIT_B: "두 번째 봉인 회로",
	MIRROR: "백미러", PILLAR: "돌기둥", RELIEF: "벽감 · 숨 고르기"}

var pos := ENTRY
var facing := 0
var fear := 0.0
var doses := 2
var circuit := 0
var shadow := ECHO_START
var endings: Array[String] = []
var moves := 0

static func is_floor(cell: Vector2i) -> bool:
	return cell.y >= 0 and cell.y < GRID.size() and cell.x >= 0 and cell.x < GRID[cell.y].length() and GRID[cell.y][cell.x] != "#"

static func _integer(value: Variant, low: int, high: int, fallback: int) -> int:
	if (value is int or value is float) and value >= low and value <= high and floorf(value) == value:
		return int(value)
	return fallback

static func clean_checkpoint(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var x := _integer(raw.get("x"), 1, 9, 1)
	var y := _integer(raw.get("y"), 1, 9, 1)
	if not is_floor(Vector2i(x, y)):
		x = ENTRY.x
		y = ENTRY.y
	return {"x": x, "y": y, "dir": _integer(raw.get("dir"), 0, 3, 0), "fear": _integer(raw.get("fear"), 0, 99, 0),
		"doses": _integer(raw.get("doses"), 0, 2, 2), "circuit": _integer(raw.get("circuit"), 0, 2, 0)}

func restore(raw: Variant, progress: Dictionary = {}) -> void:
	endings.clear()
	for id in ["mirror", "pillar"]:
		if progress.has(id):
			endings.append(id)
	var saved := clean_checkpoint(raw)
	if not saved.is_empty():
		pos = Vector2i(saved.x, saved.y)
		facing = saved.dir
		fear = saved.fear
		doses = saved.doses
		circuit = saved.circuit
	shadow = ENTRY if pos.distance_to(ECHO_START) <= 2 and pos.distance_to(ENTRY) > 2 else ECHO_START

func checkpoint() -> Dictionary:
	return {"x": pos.x, "y": pos.y, "dir": facing, "fear": clampi(roundi(fear), 0, 99), "doses": doses, "circuit": circuit}

func recover_at_entrance() -> void:
	pos = ENTRY
	facing = 0
	fear = 28.0
	shadow = ECHO_START

func turn(direction: int) -> void:
	facing = posmod(facing + direction, DIR.size())

func step(direction: int) -> bool:
	var drift := fear >= 60.0 and moves % 4 == 3
	var heading := posmod(facing + (1 if drift else 0), DIR.size())
	var dest: Vector2i = pos + DIR[heading] * direction
	moves += 1
	if not is_floor(dest):
		return false
	pos = dest
	var near := shadow.distance_to(pos) <= 4.0
	fear += 2.0 if near else 1.0
	if moves % (3 if near else 5) == 0:
		_pursue()
	if shadow == pos:
		fear += 21.0
		shadow = ECHO_START if pos.distance_to(ECHO_START) > 3.0 else ENTRY
	return true

func _pursue() -> void:
	var queue: Array[Vector2i] = [pos]
	var visited := {pos: true}
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		for delta: Vector2i in DIR:
			var next := cell + delta
			if not is_floor(next) or visited.has(next):
				continue
			if next == shadow:
				shadow = cell
				return
			visited[next] = true
			queue.append(next)

func medicate() -> String:
	if fear <= 0:
		return "아직 환각이 없다"
	if doses == 0:
		return "항정신제가 없다 · 벽감에서 숨 고르기"
	doses -= 1
	fear = maxf(0.0, fear - 42.0)
	return "항정신제 사용 · 환각이 가라앉는다"

func use() -> String:
	match pos:
		ENTRY:
			return "경고 벽화 · 정신체가 발소리를 따라온다. 두 회로를 순서대로 잇고 반사면이나 돌기둥으로."
		CIRCUIT_A:
			circuit = maxi(circuit, 1)
			return "첫 번째 봉인 회로가 켜졌다"
		CIRCUIT_B:
			if circuit == 0: return "첫 번째 회로부터 연결하라"
			circuit = 2
			return "봉인 회로 연결 · 반사면이나 돌기둥으로"
		RELIEF:
			fear = maxf(0.0, fear - 30.0)
			return "숨을 고르자 이곳의 메아리가 잦아들었다"
		MIRROR, PILLAR:
			if circuit < 2: return "두 봉인 회로를 먼저 연결하라"
			var ending := "mirror" if pos == MIRROR else "pillar"
			if endings.has(ending):
				return "이미 본 결말 · 수첩에서 다시 읽기"
			endings.append(ending)
			return "백미러 너머에서 발소리가 멎었다" if ending == "mirror" else "돌기둥에 잔광이 내려앉았다"
	return "벽 너머에서 발소리가 한 번 울렸다"
