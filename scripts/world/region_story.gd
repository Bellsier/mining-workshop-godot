extends RefCounted
## Field notes in two pockets of the existing land beyond the tunnel. Coordinates are world units.
## Each entry is earned once. The comparison is read from the two originals, never saved separately.

const SITES := {
	"tracks": {"at": Vector2(-7.45, -0.35), "label": "장화 자국 조사"},
	"ledger": {"at": Vector2(-8.45, -1.65), "label": "공방 기록 펼치기"},
	"leaf": {"at": Vector2(-7.55, -2.55), "label": "잎 표식 누르기"},
	"wave": {"at": Vector2(-9.55, -2.85), "label": "물결 표식 누르기"},
	"last": {"at": Vector2(-8.55, -4.15), "label": "이끼 돌턱 살피기"},
	"pump": {"at": Vector2(-7.55, 2.85), "label": "배수기 점검"},
	"coil": {"at": Vector2(-9.35, 3.45), "label": "예비 코일 회수"},
	"incident": {"at": Vector2(-7.65, 4.35), "label": "사고 일지 읽기"},
	"archive": {"at": Vector2(-8.55, 5.85), "label": "기록 단말 조회"},
}
const SEQUENCE := ["leaf", "wave", "leaf"]
# Rows are presented in field-guide order, regardless of the order the sites were visited.
const NOTES := {
	"tracks": ["이끼숲 · 수선한 장화", "밑창 한쪽에 못을 세 번 덧댄 자국. 대장이 공방에서 신던 장화와 같다. 발자국은 서북쪽의 이끼 덮인 작업대로 이어진다."],
	"ledger": ["이끼숲 · 옛 공방의 탁본", "봉인 상자를 만들었다는 고대 장인의 표식이다. 잎맥 하나가 중간에서 끊겼다. 탁본 가장자리에는 ‘잎을 적시고 다시 잎을 편다’고 새겼다. 북쪽의 두 표식판에서 잎 → 물결 → 잎 순서로 눌러 보자."],
	"seal": ["이끼숲 · 열린 돌턱", "세 번째 울림에 북쪽 돌턱의 덮개가 밀려났다. 뿌리 아래 마른 홈에 누군가 천을 끼워 두었다."],
	"last": ["이끼숲 · 대장의 매듭", "돌턱 안의 천에는 대장이 짐을 묶을 때 쓰던 매듭이 남았다. 돌바닥에서 장화 자국이 끊긴다. 상자에 손을 댔는지, 그 뒤 어디로 갔는지 알려 줄 흔적은 없다."],
	"pump": ["안개 늪지 · 멎은 배수기", "지하 문명이 설치한 배수기다. 덮개 안쪽의 코일 자리가 비어 있다. 서남쪽 부품함과 남쪽 관측대에 정비 흔적이 보인다."],
	"coil": ["안개 늪지 · 예비 코일", "부품함에서 배수기 규격에 맞는 구리 코일을 건졌다. 끝 단자는 물기를 닦을 수 있게 천으로 감겨 있다."],
	"incident": ["안개 늪지 · 연구반 사고 일지", "관측반은 침식 유물의 수치를 더 재자고 했고, 배수반은 주민 대피를 먼저 요구했다. 과열 뒤 기록 단말의 전원이 끊겼다. 정비란에는 ‘예비 코일을 배수기 귀환 단자에 연결’이라고 적혀 있다."],
	"repaired": ["안개 늪지 · 다시 도는 펌프", "귀환 단자에 코일을 끼우자 수위계 바늘이 내려갔다. 남쪽 기록 단말의 불빛이 돌아왔다."],
	"archive": ["안개 늪지 · 선발대의 사본", "후대 지하 문명의 선발대가 이미 오래된 고대 사원을 발견한 뒤 남긴 조사 목록이다. 정신체 봉인에 관한 사원 기록과 별지의 장인 표식 탁본이 따로 철해져 있다. 탁본에는 잎맥 하나가 비어 있다."],
	"comparison": ["대조 기록 · 끊어진 잎맥", "숲 작업대의 탁본과 늪지 선발대 사본에는 같은 자리에 잎맥 하나가 빠져 있다. 후대 조사자는 장인의 표식을 베껴 두었다. 이 사본에 봉인 상자의 행방을 적은 줄은 없다."],
}
const TOAST := {
	"tracks": "대장의 장화 자국! 서북쪽 작업대로",
	"ledger": "탁본 순서 · 잎 → 물결 → 잎",
	"seal": "덮개가 열렸다! 북쪽 돌턱으로",
	"last": "대장의 매듭 발견 · 가방에 기록",
	"pump": "코일이 없다 · 부품함과 관측대로",
	"coil": "예비 코일 확보 · 가방에 기록",
	"incident": "귀환 단자 도면 발견 · 배수기로",
	"repaired": "배수기 가동! 남쪽 단말 점등",
	"archive": "선발대 사본 판독 · 가방에 기록",
}

static func restore(raw: Variant) -> Dictionary:
	var progress := {}
	if not raw is Dictionary:
		return progress
	for key: String in ["tracks", "ledger", "pump", "coil", "incident"]:
		if is_same(raw.get(key), true):
			progress[key] = true
	if progress.has("ledger") and progress.has("tracks"):
		if is_same(raw.get("seal"), true):
			progress["seal"] = true
			if is_same(raw.get("last"), true):
				progress["last"] = true
		else:
			var step: Variant = raw.get("sequence")
			if (step is int or step is float) and (step == 1 or step == 2):
				progress["sequence"] = int(step)
	if ready_to_repair(progress) and is_same(raw.get("repaired"), true):
		progress["repaired"] = true
		if is_same(raw.get("archive"), true):
			progress["archive"] = true
	return progress

static func ready_to_repair(progress: Dictionary) -> bool:
	return progress.has("pump") and progress.has("coil") and progress.has("incident") and not progress.has("repaired")

static func action_label(id: String, progress: Dictionary) -> String:
	if id == "pump" and ready_to_repair(progress):
		return "귀환 단자에 코일 연결"
	return SITES[id].label

static func journal(progress: Dictionary) -> Array:
	var rows := []
	for id: String in NOTES:
		if progress.has(id) or (id == "comparison" and linked(progress)):
			rows.append({"id": id, "title": NOTES[id][0], "text": NOTES[id][1]})
	return rows

static func linked(progress: Dictionary) -> bool:
	return progress.has("last") and progress.has("archive")

static func _record(progress: Dictionary, id: String) -> String:
	if progress.has(id):
		return "이미 조사했다 · 가방에서 다시 읽기"
	progress[id] = true
	if id in ["last", "archive"] and linked(progress):
		return "두 기록의 표식이 같다! 가방에서 대조"
	return TOAST[id]

static func investigate(progress: Dictionary, id: String) -> String:
	match id:
		"leaf", "wave":
			if progress.has("seal"):
				return "덮개가 열린 북쪽 돌턱으로"
			if not progress.has("tracks") or not progress.has("ledger"):
				return "장화 자국과 공방 기록부터 조사하자"
			var step := int(progress.get("sequence", 0))
			if id != SEQUENCE[step]:
				progress.erase("sequence")
				return "엇난 울림 · 첫 잎부터 다시"
			step += 1
			if step == SEQUENCE.size():
				progress.erase("sequence")
				return _record(progress, "seal")
			progress["sequence"] = step
			return "표식이 울린다 · %d/3" % step
		"last":
			if not progress.has("seal"):
				return "덮개가 잠겼다 · 남쪽 표식판으로"
		"pump":
			if progress.has("pump"):
				if not progress.has("coil"):
					return "서남쪽 부품함에 예비 코일이 있다"
				if not progress.has("incident"):
					return "남쪽 사고 일지에서 결선을 확인하자"
				return _record(progress, "repaired")
		"archive":
			if not progress.has("repaired"):
				return "단말 전원 꺼짐 · 북쪽 배수기로"
	if SITES.has(id):
		return _record(progress, id)
	return ""
