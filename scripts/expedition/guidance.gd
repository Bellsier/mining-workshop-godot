extends RefCounted
## Journal objectives and commemorations are views of the existing v1 flags.
const Story := preload("res://scripts/world/region_story.gd")
const Regions := preload("res://scripts/expedition/regions.gd")

const FOREST_DIRECTIONS := "터널 출구에서 북쪽으로 올라가 서쪽 바위벽을 따라가세요."
const SWAMP_DIRECTIONS := "터널 출구에서 남쪽으로 내려가 서쪽 물가를 따라가세요."
const CRYSTAL_DIRECTIONS := "산 너머 북쪽 벽을 따라 숲길 입구를 더 지나면 수정 입구가 나와요."
const VILLAGE_DIRECTIONS := "산 너머 남쪽 끝에서 수문실 입구보다 아래에 있어요."
const TEMPLE_DIRECTIONS := "산 너머 북쪽 끝에서 수정 입구보다 더 위에 있어요."
const TITLES := {"tunnel": "터널", "forest": "이끼숲", "swamp": "안개 늪지", "crystal": "별빛 수정 지대", "village": "지하 마을", "temple": "고대 사원"}

static func _goal(region: String, id: String, title: String, directions: String, site := "") -> Dictionary:
	return {"region": region, "id": id, "title": "%s · %s" % [TITLES[region], title], "text": directions, "site": site}


static func goals(tunnel_open: bool, building: bool, story: Dictionary, p: Dictionary) -> Array:
	if not tunnel_open:
		return [_goal("tunnel", "waiting" if building else "open_tunnel", "공사 진행 중" if building else "산 너머로 가는 길",
			"공사가 끝나면 공방 서쪽 통로를 건너세요." if building else "공방의 연구 탭에서 터널 굴착을 연구하고 공사를 의뢰하세요.")]
	var current := []
	for entry: Dictionary in [_forest(story, p), _swamp(story, p), _crystal(story, p), _village(p), _temple(p)]:
		if not entry.is_empty():
			current.append(entry)
	return current


static func _forest(s: Dictionary, p: Dictionary) -> Dictionary:
	if p.has("forest_path"): return {}
	if not s.has("tracks"): return _goal("forest", "tracks", "대장의 장화 자국 조사", "터널 출구 바로 북쪽을 살피세요.")
	if not s.has("ledger"): return _goal("forest", "ledger", "옛 공방 탁본 조사", "장화 자국에서 서북쪽으로 올라가세요.")
	if not s.has("seal"): return _goal("forest", "seal", "두 표식판 조작", "탁본보다 북쪽에 있어요. 탁본에서 조작 순서를 다시 읽을 수 있어요.")
	if not s.has("last"): return _goal("forest", "last", "열린 돌턱 조사", "두 표식판보다 더 북쪽으로 올라가세요.")
	if not p.has("marks"): return _goal("forest", "marks", "뿌리 수로의 바닥 홈 조사", FOREST_DIRECTIONS, "marks")
	if not p.has("forest_open"):
		var site: String = ["moss", "root", "moss"][int(p.get("forest_step", 0))]
		var title: String = Regions.ROOMS.forest.sites[site][1]
		return _goal("forest", site, "%d/3 %s" % [int(p.get("forest_step", 0)) + 1, title], FOREST_DIRECTIONS + " 수로의 바닥 기록에 순서가 적혀 있어요.", site)
	return _goal("forest", "forest_path", "숨은 숲길 끝 조사", FOREST_DIRECTIONS + " 열린 뿌리 문을 건너세요.", "forest_path")


static func _swamp(s: Dictionary, p: Dictionary) -> Dictionary:
	if p.has("swamp_path"): return {}
	if not s.has("pump"): return _goal("swamp", "pump", "멎은 배수기 조사", "터널 출구에서 남쪽으로 조금 내려가세요.")
	if not s.has("coil"): return _goal("swamp", "coil", "예비 코일 회수", "배수기 서남쪽의 부품함을 찾으세요.")
	if not s.has("incident"): return _goal("swamp", "incident", "사고 일지 읽기", "배수기 남쪽의 관측대를 찾으세요.")
	if not s.has("repaired"): return _goal("swamp", "repair", "배수기에 코일 연결", "코일과 일지를 확보했어요. 북쪽 배수기로 돌아가세요.")
	if not s.has("archive"): return _goal("swamp", "archive", "기록 단말 조회", "배수기 남쪽으로 이동해 불이 들어온 단말을 찾으세요.")
	if not p.has("diagram"): return _goal("swamp", "diagram", "수문실 결선도 읽기", SWAMP_DIRECTIONS, "diagram")
	if not p.has("swamp_open"):
		var site: String = ["ground", "return", "supply"][int(p.get("swamp_step", 0))]
		var title: String = Regions.ROOMS.swamp.sites[site][1]
		return _goal("swamp", site, "%d/3 %s" % [int(p.get("swamp_step", 0)) + 1, title], SWAMP_DIRECTIONS + " 결선도에서 순서를 확인하세요.", site)
	return _goal("swamp", "swamp_path", "드러난 배수로 점검", SWAMP_DIRECTIONS + " 수문을 건너세요.", "swamp_path")


static func _crystal(s: Dictionary, p: Dictionary) -> Dictionary:
	if p.has("rescued") or not Regions.allowed("crystal", s, p): return {}
	if not p.has("signal"): return _goal("crystal", "signal", "응답 신호 추적", CRYSTAL_DIRECTIONS, "signal")
	if not p.has("crystal_open"):
		var site := "west" if p.get("west", 0) != 1 else "east"
		return _goal("crystal", site, "반사판 맞추기", CRYSTAL_DIRECTIONS + " 신호 기록에 각도가 적혀 있어요.", site)
	if not p.has("alive"): return _goal("crystal", "alive", "방호문에서 생존 확인", CRYSTAL_DIRECTIONS + " 안정된 통로를 건너세요.", "shutter")
	return _goal("crystal", "rescue", "과학자 구조", CRYSTAL_DIRECTIONS + " 방호문 손잡이를 다시 당기세요.", "shutter")


static func _village(p: Dictionary) -> Dictionary:
	if p.has("calibration"): return {}
	if not p.has("drainage"):
		if not p.has("swamp_path"):
			return _goal("village", "village_plan", "공용 수로 도면 찾기", "안개 늪지의 수문실에서 물을 빼고 배수로 끝을 조사하세요.") if p.has("rescued") else {}
		return _goal("village", "drainage", "배수반과 공동 수로 복구", VILLAGE_DIRECTIONS, "drainage")
	if not p.has("observatory"):
		if p.has("crystal_open"): return _goal("village", "observatory", "관측반과 관측소 복구", VILLAGE_DIRECTIONS, "observatory")
		return _goal("village", "village_angles", "공명 각도 찾기", CRYSTAL_DIRECTIONS)
	if not p.has("accord"): return _goal("village", "accord", "두 반과 공동 회의", VILLAGE_DIRECTIONS, "table")
	if not p.has("rescued"): return _goal("village", "village_scientist", "공동 연구에 필요한 과학자 구조", CRYSTAL_DIRECTIONS)
	if not p.has("research"): return _goal("village", "research", "과학자를 공동 연구대로 맞이하기", VILLAGE_DIRECTIONS, "lab")
	return _goal("village", "calibration", "첫 공동 관측 진행", VILLAGE_DIRECTIONS, "lab")


static func _temple(p: Dictionary) -> Dictionary:
	if p.has("mirror") and p.has("pillar"): return {}
	var circuit: int = int(p.get("temple", {}).get("circuit", 0))
	if circuit < 2:
		return _goal("temple", "circuit_%d" % circuit, "첫 봉인 회로 조사" if circuit == 0 else "두 번째 봉인 회로 조사",
			TEMPLE_DIRECTIONS + " 입구 벽화에서 봉인 순서를 확인하세요.")
	var id := "pillar" if p.has("mirror") else "mirror"
	return _goal("temple", id, "돌기둥 조사" if id == "pillar" else "백미러 조사", TEMPLE_DIRECTIONS + " 회로는 이미 연결됐어요.")


static func stamps(p: Dictionary) -> Array[String]:
	var earned: Array[String] = []
	for entry: Array in [["forest_path", "뿌리길"], ["swamp_path", "배수로"], ["rescued", "구조"],
		["calibration", "공동 관측"], ["pillar", "두 봉인 기록"]]:
		if p.has(entry[0]) and (entry[0] != "pillar" or p.has("mirror")):
			earned.append(entry[1])
	return earned


static func surface_points(story: Dictionary, progress: Dictionary) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for item: Dictionary in goals(true, false, story, progress):
		if not Regions.allowed(item.region, story, progress):
			var landmark: String = "pump" if item.id == "repair" else item.id
			if Story.SITES.has(landmark):
				points.append(Story.SITES[landmark].at)
			continue
		if item.region == "village" and item.site.is_empty():
			continue
		points.append(Regions.PORTALS[item.region][0])
	return points
