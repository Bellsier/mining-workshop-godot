extends RefCounted
## Fixed expedition maps. Grid coordinates belong to these scenes; surface coordinates remain in world units.

const PORTALS := {
	"forest": [Vector2(-9.35, -5.15), "이끼숲 · 숨은 숲길"],
	"swamp": [Vector2(-9.45, 6.65), "안개 늪지 · 수문실"],
	"crystal": [Vector2(-9.4, -7.25), "별빛 수정 지대"],
	"temple": [Vector2(-9.25, -9.05), "고대 사원 · 들어가기"],
	"village": [Vector2(-9.35, 8.25), "지하 마을"],
}
const ROOMS := {
	"forest": {
		"title": "이끼숲 · 뿌리 수로", "color": "597655",
		"map": ["#############", "#.....#.....#", "#.....#.....#", "#.....G.....#", "#.....#.....#", "#.....#.....#", "#############"],
		"sites": {"moss": [Vector2i(4, 1), "이끼 홈에 물 붓기"], "root": [Vector2i(4, 5), "뿌리 손잡이 당기기"],
			"marks": [Vector2i(2, 4), "바닥의 물길 읽기"], "forest_path": [Vector2i(10, 3), "숨은 숲길 조사"]},
		"gate": "forest_open",
	},
	"swamp": {
		"title": "안개 늪지 · 수문실", "color": "42716e",
		"map": ["#############", "#.....#.....#", "#.....G.....#", "#.....G.....#", "#.....#.....#", "#.....#.....#", "#############"],
		"sites": {"diagram": [Vector2i(2, 3), "결선도 읽기"], "ground": [Vector2i(4, 1), "접지 연결"],
			"return": [Vector2i(5, 3), "귀환 연결"], "supply": [Vector2i(4, 5), "공급 연결"],
			"swamp_path": [Vector2i(10, 3), "배수로 점검"]},
		"gate": "swamp_open",
	},
	"crystal": {
		"title": "별빛 수정 지대", "color": "57597f",
		"map": ["#############", "#.....#.....#", "#.....#.....#", "#.....G.....#", "#.....#.....#", "#.....#.....#", "#############"],
		"sites": {"signal": [Vector2i(2, 3), "미약한 신호 추적"], "west": [Vector2i(4, 1), "서쪽 반사판 회전"],
			"east": [Vector2i(4, 5), "동쪽 반사판 회전"], "shutter": [Vector2i(10, 3), "수정화 방호문 조사"]},
		"gate": "crystal_open",
	},
	"village": {
		"title": "지하 마을", "color": "695a4e",
		"map": ["#############", "#...........#", "#...........#", "#...........#", "#...........#", "#...........#", "#############"],
		"sites": {"drainage": [Vector2i(4, 1), "배수반과 공용 수로 복구"], "observatory": [Vector2i(4, 5), "관측반과 관측소 복구"],
			"table": [Vector2i(7, 3), "공동 회의 열기"], "lab": [Vector2i(10, 3), "공동 연구대 방문"],
			"drain_resident": [Vector2i(3, 2), "배수반 주민과 대화"], "watch_resident": [Vector2i(3, 4), "관측반 주민과 대화"]},
		"gate": "",
	},
}
const NOTES := {
	"marks": ["이끼숲 · 이끼의 물길", "바닥 홈은 물을 머금은 이끼 쪽으로 기울었다. 이끼를 적시고 뿌리 손잡이를 당긴 뒤 이끼를 다시 적신다."],
	"forest_open": ["이끼숲 · 뿌리 문", "이끼가 부풀어 나무 쐐기를 밀자 뿌리 문이 들렸다. 장인의 수로가 감춰 두었던 숲길이다."],
	"forest_path": ["이끼숲 · 숨은 숲길", "숲길 끝 수로 표시 옆에 후대 조사반의 화살표가 있다. 그들은 물길의 각도를 재어 북쪽 수정 지대의 반사판 기록에 옮겼다. 대장의 발자국은 돌턱 뒤에서 끊긴다."],
	"diagram": ["안개 늪지 · 결선도", "접지를 먼저, 귀환을 다음, 공급을 마지막에. 순서가 틀리면 안전 차단기가 모든 단자를 떨어뜨린다."],
	"swamp_open": ["안개 늪지 · 수문 가동", "정비용 배수기가 수문을 구동한다. 물에 잠겼던 통로의 발판이 드러나고 흡기구가 안개를 걷어 낸다."],
	"swamp_path": ["안개 늪지 · 공용 수로 도면", "배수반이 남긴 밸브 규격은 남쪽 지하 마을의 공용 수로에도 맞는다. 여백의 정비 지도를 따라 북쪽으로 돌아가면 수정 지대의 반사판에 전력을 보내던 보조 통로가 나온다."],
	"signal": ["별빛 수정 지대 · 응답 신호", "결정 너머에서 응답이 돌아온다. 후대 조사반의 스케치에는 숲 수로 각도와 늪지 동력선이 함께 그려져 있다. 표시대로 서쪽 반사판 1칸, 동쪽 반사판 2칸을 맞춘다."],
	"crystal_open": ["별빛 수정 지대 · 안정된 공명", "양쪽 반사광이 가운데 결정에서 합쳐졌다. 진동이 멎고 수정화된 통로가 드러났다."],
	"alive": ["별빛 수정 지대 · 생존 확인", "방호문 너머에서 과학자의 육성을 들었다. 손잡이를 한 번 더 작동시키면 밖으로 나올 수 있다."],
	"rescued": ["별빛 수정 지대 · 구조 완료", "과학자를 방호실 밖으로 안내했다. 지하 마을에 자리를 마련하면 조사 기록 정리를 도울 수 있다."],
	"drainage": ["지하 마을 · 공동 수로", "배수반과 늪지 도면을 대조해 공동 수로를 복구했다."],
	"observatory": ["지하 마을 · 공동 관측소", "관측반과 수정의 공명 각도를 맞춰 관측소를 다시 열었다."],
	"accord": ["지하 마을 · 공동 회의", "두 반이 주민 대피로를 먼저 확보하고 관측 기록을 함께 관리하기로 합의했다."],
	"research": ["지하 마을 · 공동 연구대", "과학자가 수정의 반사광 기록과 배수반 도면을 연구대에 펼쳤다. 관측반은 수정의 떨림을 재고 배수반은 같은 시간의 수위를 기록하기로 했다."],
	"calibration": ["지하 마을 · 공동 관측의 첫 기록", "같은 공명에서 수면이 잦아들 때 반사광의 떨림도 줄었다. 과학자와 두 반이 각각 수위와 진동을 재고 같은 장부에 첫 값을 옮겼다."],
	"mirror": ["고대 사원 · 백미러 엔딩", "반사면 속의 발소리가 먼저 멎었다. 탐험자는 회로가 열린 틈을 따라 지상으로 돌아왔다."],
	"pillar": ["고대 사원 · 돌기둥 엔딩", "돌기둥에 잔광이 내려앉자 추적이 멎었다. 회로에 남은 빛을 따라 지상으로 돌아왔다."],
}

static func allowed(region: String, story: Dictionary, progress: Dictionary) -> bool:
	match region:
		"forest": return story.has("last")
		"swamp": return story.has("archive")
		"crystal": return progress.has("forest_path") or progress.has("swamp_path")
		"village", "temple": return true
	return false

static func restore(raw: Variant) -> Dictionary:
	var out := {}
	if not raw is Dictionary:
		return out
	for id: String in NOTES:
		if is_same(raw.get(id), true):
			out[id] = true
	for entry: Array in [["forest_step", 2], ["swamp_step", 2], ["west", 2], ["east", 2]]:
		var v: Variant = raw.get(entry[0])
		if (v is int or v is float) and v >= 1 and v <= entry[1] and floorf(v) == v:
			out[entry[0]] = int(v)
	for pair: Array in [["forest_open", "marks"], ["forest_path", "forest_open"], ["swamp_open", "diagram"],
		["swamp_path", "swamp_open"], ["crystal_open", "signal"], ["alive", "crystal_open"], ["rescued", "alive"],
		["drainage", "swamp_path"], ["observatory", "crystal_open"], ["accord", "drainage"], ["accord", "observatory"],
		["research", "accord"], ["research", "rescued"], ["calibration", "research"], ["forest_step", "marks"], ["swamp_step", "diagram"],
		["west", "signal"], ["east", "signal"]]:
		if not out.has(pair[1]):
			out.erase(pair[0])
	if out.has("forest_open"):
		out.erase("forest_step")
	if out.has("swamp_open"):
		out.erase("swamp_step")
	var checkpoint := preload("res://scripts/expedition/temple.gd").clean_checkpoint(raw.get("temple"))
	if not checkpoint.is_empty():
		out["temple"] = checkpoint
	return out

static func journal(progress: Dictionary) -> Array:
	var rows := []
	for id: String in NOTES:
		if progress.has(id):
			rows.append({"id": id, "title": NOTES[id][0], "text": NOTES[id][1]})
	return rows

static func can_walk(region: String, tile: Vector2i, progress: Dictionary) -> bool:
	var map: Array = ROOMS[region].map
	if tile.y < 0 or tile.y >= map.size() or tile.x < 0 or tile.x >= map[tile.y].length():
		return false
	match map[tile.y][tile.x]:
		"#": return false
		"G": return progress.has(ROOMS[region].gate)
	return true

static func _remember(progress: Dictionary, id: String, hint: String = "") -> String:
	if progress.has(id):
		return "이미 완료했다 · 가방의 탐사 수첩"
	progress[id] = true
	return hint if not hint.is_empty() else str(NOTES[id][0]) + " · 수첩에 기록"

static func _sequence(progress: Dictionary, id: String, order: Array, note: String, step_key: String, completed: String) -> String:
	if progress.has(completed):
		return "장치 가동 중 · 통로가 열려 있다"
	if not progress.has(note):
		return "먼저 근처 기록을 읽자"
	var step := int(progress.get(step_key, 0))
	if id != order[step]:
		progress.erase(step_key)
		return "순서가 어긋났다 · 첫 단계부터 다시"
	step += 1
	if step == order.size():
		progress.erase(step_key)
		return _remember(progress, completed)
	progress[step_key] = step
	return "연결 완료 · %d/%d" % [step, order.size()]

static func act(region: String, id: String, p: Dictionary) -> String:
	if not ROOMS.has(region) or not ROOMS[region].sites.has(id):
		return ""
	match id:
		"moss", "root":
			return _sequence(p, id, ["moss", "root", "moss"], "marks", "forest_step", "forest_open")
		"marks": return _remember(p, id, "이끼 → 뿌리 → 이끼")
		"forest_path":
			if not p.has("forest_open"): return "뿌리 문을 먼저 열자"
		"ground", "return", "supply":
			return _sequence(p, id, ["ground", "return", "supply"], "diagram", "swamp_step", "swamp_open")
		"diagram": return _remember(p, id, "접지 → 귀환 → 공급")
		"swamp_path":
			if not p.has("swamp_open"): return "수위를 먼저 낮추자"
		"signal": return _remember(p, id, "응답 포착 · 서쪽 1칸, 동쪽 2칸")
		"west", "east":
			if p.has("crystal_open"): return "공명 유지 중 · 통로가 안정되었다"
			if not p.has("signal"): return "먼저 신호를 추적하자"
			p[id] = (int(p.get(id, 0)) + 1) % 3
			if p.get("west", 0) == 1 and p.get("east", 0) == 2:
				return _remember(p, "crystal_open", "공명 안정 · 방호문으로")
			return "반사 각도 %d/2 · 빛이 아직 닿지 않는다" % int(p[id])
		"shutter":
			if not p.has("crystal_open"): return "통로가 수정화됐다 · 반사판을 맞추자"
			if not p.has("alive"): return _remember(p, "alive", "생존 응답 확인 · 손잡이를 다시 당기자")
			return _remember(p, "rescued", "구조 완료 · 지하 마을로")
		"drain_resident":
			return "배수반 · 공동 수로가 열려 이제 주민들도 이 길로 나갈 수 있어요" if p.has("drainage") else "배수반 · 연구보다 먼저 대피로를 열고 싶어요"
		"watch_resident":
			return "관측반 · 구조 신호를 담은 수정 기록과 수위표를 같이 읽고 있어요" if p.has("accord") else "관측반 · 관측소를 잃으면 사고 원인도 묻혀요"
		"drainage":
			if not p.has("swamp_path"): return "늪지 배수로의 도면이 필요하다"
		"observatory":
			if not p.has("crystal_open"): return "수정 지대에서 공명 각도를 찾자"
		"table":
			if not p.has("drainage") or not p.has("observatory"): return "두 반이 함께 쓸 시설부터 복구하자"
			return _remember(p, "accord", "두 반이 합류했다 · 주민들이 회의탁자로 이동")
		"lab":
			if not p.has("accord") or not p.has("rescued"): return "공동 회의와 과학자 구조가 필요하다"
			if p.has("research"):
				return _remember(p, "calibration", "두 반과 과학자가 첫 관측을 마쳤다 · 수첩에 기록")
			return _remember(p, "research", "과학자가 마을에 합류했다 · 연구대 개방")
	return _remember(p, id)
