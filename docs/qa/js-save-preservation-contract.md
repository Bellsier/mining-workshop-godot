# JS 저장 데이터 보존·활성 복원 계약

기준: JS 원본 `Bellsier/gacha-factory-development` develop `7484ccd` (`js/state.js`, `js/save-engine.js`, `docs/SAVE_S2.md`),
Godot PR #1 `f14d45d` + 1차 수정 브랜치 `claude/feature-parity-p0`.

## 용어

- **원본 보존**: 가져온 JS/S2 저장의 **바이트**를 그대로 `state.legacy_web_save_bytes`(base64)에 두고,
  SHA-256을 `legacy_web_save_sha256`에, 들어온 경로를 `legacy_web_save_origin`(`file` | `paste`)에 둔다(S2 봉투 포함).
  게임 본문(`{saveVersion, savedAt, permanent, run}`)은 불러올 때마다 이 바이트에서 다시 읽어 `state.legacy_web_save`에 둔다
  (`Save.parse_game`). 저장 파일·IndexedDB에는 바이트만 쓰고, 파싱한 사본은 바이트로 정확히 다시 만들 수 있을 때 쓰지 않는다.
- **파일 가져오기와 붙여넣기의 차이**
  - 파일 가져오기(저장 탭 `파일에서 가져오기`: 데스크톱은 파일 대화상자, 웹은 브라우저 파일 선택): 파일 바이트 그대로.
    CRLF, BOM, 한글, 이모지가 그대로 남고 SHA-256이 원본 파일과 같다. `원본 JS 파일 저장`으로 같은 바이트를 다시 내보낼 수 있다.
  - 붙여넣기(텍스트 칸): **받은 텍스트의 UTF-8 바이트**만 보장한다. 클립보드나 텍스트 칸이 줄바꿈(CRLF→LF) 등을
    바꿨다면 그 바뀐 텍스트가 보존된다. 화면에 이 한계를 안내하고, 원본 보존이 필요하면 파일 가져오기를 권한다.
- **손상·충돌 보호** (`Save.legacy_status`)
  - `ok`: 바이트가 base64로 읽히고, SHA-256이 맞고, UTF-8이고, 웹 저장 형식이다. 사본은 바이트에서 다시 만든다.
  - `corrupt`: 위 조건 중 하나라도 어긋남. 파일에 저장된 사본이 있으면 그 사본을 계속 쓰고 저장할 때마다 다시 쓴다.
    손상된 바이트도 지우거나 고치지 않고 그대로 둔다. 원본 내보내기는 막는다.
  - `conflict`: 바이트는 정상인데 저장된 사본과 내용이 다름. 저장된 사본을 쓰고 둘 다 보존한다.
  - `copy_only`: 원본 보존 이전에 가져온 저장(사본만 있음). 사본을 그대로 쓴다.
- **숫자 정확성**: Godot 4.4.1 내장 JSON은 숫자를 정확히 왕복하지 못한다(CI 측정: `"1.1500000000000001"`을 1.15로 읽고,
  배열·딕셔너리 안 숫자를 유효숫자 15자리로 쓰며, `1e999`를 무한대로 읽는다). 저장 읽기·쓰기는 `scripts/exact_json.gd`를 쓴다.
  JS `JSON.parse`처럼 가장 가까운 double로 읽고(Node가 만든 4,171개 사례와 비트 단위 일치), JS `JSON.stringify`처럼 가장 짧게 쓴다.
  범위를 벗어난 수(`1e999`)는 무한대로 바꾸지 않고 거부한다. 게임 값(골드·재고)도 저장 후 비트 단위로 같다.
- **활성 복원**: 그 값을 Godot 게임 상태로 옮겨 실제 게임에 반영한다.
- **미복원**: 원본에는 남아 있지만 Godot 게임에는 반영되지 않는다. 해당 기능을 이식할 때 `legacy_web_save`에서 읽어 복원한다.

## 계약 (데이터별)

| JS 경로 | 원본 보존 | 활성 복원 | Godot 위치 · 비고 |
|---|---|---|---|
| `run.gold` · `run.resources` · `run.products` | 예 | 예 | `gold`, `inventory` (소수 그대로. 0.5개도 가방·판매 탭에 표시) |
| `run.research` (true인 항목) | 예 | 예 | `completed_research` |
| `run.characters` | 예 | 예 | `characters` |
| `run.unlockedSites` | 예 | 예 | `unlocked_sites` |
| `run.autoCraft` · `autoSell` · `autoSellOn` · `craftTarget` | 예 | 예 | `automation.craft/sell_owned/sell/target`. 자동 판매는 workshopOnly 레시피만 제외 |
| `run.craftQueue` | 예 | 예 | `queue` (남은 초) |
| `run.hqLevel` · `craftFacility` · `facility` · `workforce` | 예 | 예 | 같은 이름의 Godot 키 |
| `run.lastPull` · `run.autoLineLogged` | 예 | 아니요 | 화면 표시용 기록. 게임 진행에 영향 없음 |
| `run.world.base` · `mines` · `hiddenMineIds` · `tunnelUnlocked` | 예 | 예 | `world` (`WorldState.from_dict`) |
| `run.world.workshops[]` (`id, x, y, level, recipeKey, auto, progress`) | 예 | 예 | `world.workshops` (같은 모양, `sanitizeWorkshops` 규칙). 제작소 이전 Godot 저장(`world`에 `workshops` 없음)은 원본에서 다시 복원. Godot 저장에 목록이 있으면 그것이 우선. 제작소·자동 제작이 쓰이고 있으면 해당 연구 완료로 봄(`researchSyncFromState`) |
| `run.world.torches[]` (`x, y`) | 예 | **아니요** | 횃불 미이식 |
| `run.world.player` (`x, y, facing`) | 예 | **아니요** | 가져오면 공방 앞에서 시작. JS 격자 좌표와 Godot 픽셀 좌표 변환 규칙 미정 |
| `run.world.tunnelContract` (`startedAt, durationSec`) | 예 | **아니요** | 진행 중 터널 공사가 이어지지 않음. `tunnelUnlocked: true`면 개통 상태는 복원됨 |
| `run.village.stage` · `unidentified` · `digProgress` · `appraised` · `owned` · `codex` · `donated` · `specimens` | 예 | 예 | `village` (`Village.load_progress`) |
| `run.village.sites` (시설 좌표) | 예 | **아니요** | 마을 배치 미이식 |
| `run.village.district` (`x, y, layout`) | 예 | **아니요** | 마을 구역 배치 미이식 |
| `run.village.decor[]` (`kind, cell`) | 예 | **아니요** | 정원 장식 미이식 |
| `permanent.tickets` · `firstGachaGranted` | 예 | 예 | `tickets`, `first_ticket` |
| `permanent.totalPrestige` · `companies` | 예 | 예 | `delivery.reputation`, `delivery.companies` |
| `permanent.runCount` | 예 | 아니요 | 회차 기능 미이식 |
| `savedAt` | 예 | 아니요 | 원본 저장 시각. Godot 저장 시각과 별개 |
| 이후 JS 빌드가 더한 알 수 없는 필드 | 예 | 아니요 | 그대로 보존 |

## S2 저장 메타데이터

JS S2 저장은 게임 본문을 아래 봉투로 감싼다 (`js/save-engine.js`).

- snapshot: `{format: 1, id(snapshotId, UUID), villageId(UUID), name, savedAt, payload}`
- 자동 저장 행: `{id(villageId), revision, snapshot}` · 수동 저장 행: `{slot, revision, snapshot, ...}`
- 마을 행(`villages`): `{id, name, createdAt, savedAt, revision, epoch, owner, presence, source}` — 가져오기 입력에 포함되지 않음

Godot `Save.import_legacy`는 `{snapshot: ...}` 행과 snapshot 자체를 받는다. 가져온 바이트 전체가
`legacy_web_save_bytes`에 남고, 그 안의 `payload`가 `legacy_web_save`가 된다.

| S2 필드 | 원본 보존 | 활성 복원 | 비고 |
|---|---|---|---|
| `snapshot.payload` | 예 | 위 표대로 | 게임 본문 |
| `snapshot.format` | 예 (바이트) | 검사만 | 1이 아니면 거부 |
| `snapshot.id` · `villageId` · `name` · `savedAt`, 행 `id` · `revision` · `slot` | 예 (바이트) | **아니요** | Godot에서 쓰는 곳 없음 |

S2 메타데이터는 바이트로만 남고 Godot 게임에서는 쓰지 않는다. 마을 이름 표시나 같은 마을 재가져오기 판별에
쓸지는 다음 단계에서 정한다 — 결정 필요. JS 쪽 IndexedDB 원본은 그대로 남는다.

PR #1 `f14d45d`에서 가져온 저장에는 원본 바이트가 없다(`copy_only`). 그 저장의 `legacy_web_save`는 그대로 쓰지만,
위 숫자 문제 때문에 원본과 1ulp 단위로 다를 수 있고 S2 메타데이터는 이미 버려진 상태다. 원본을 바이트 단위로 보존하려면
JS 저장 파일을 `파일에서 가져오기`로 다시 가져와야 한다. 1차 수정 중간 빌드(`a62bca4`)가 쓴 `legacy_web_save_source` 텍스트는
읽을 때 그 텍스트의 UTF-8 바이트로 손실 없이 옮긴다(`origin: paste`).

## 활성 복원 시 지킬 규칙

1. `legacy_web_save_bytes`·`legacy_web_save_sha256`·`legacy_web_save`는 읽기 전용이다. 기능을 이식할 때 원본을 고치지 말고 새 Godot 키에 복원 결과를 쓴다.
2. 복원은 한 번만: 새 Godot 키가 이미 있으면 그것이 우선이다 (`characters`가 있으면 legacy 일꾼을 다시 넣지 않는 현재 방식과 같음).
3. JS sanitize 규칙(`sanitizeWorkshops`, `sanitizeTorches`, `sanitizeTunnelContract`, `sanitizeVillageDecor/District/Site`,
   `sanitizePlayer`)을 그대로 이식하고, 잘못된 항목만 버린다.
4. `tunnelContract.startedAt`은 벽시계(ms) 기준이다. 복원 시 남은 시간을 `durationSec - (지금 - startedAt)/1000`로 계산할지,
   가져온 시점부터 다시 셀지 정해야 한다 — 결정 필요.
5. 제작소 전용 레시피(workshopOnly) 제작 제한은 제작소 건물 복원과 함께 켠다. → 제작소 단계에서 켰다(`WORKSHOP_ONLY_IN_HUTS`). 레시피 카드에서 이미 돌던 제작은 끝까지 진행된다.
