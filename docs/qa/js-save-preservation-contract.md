# JS 저장 데이터 보존·활성 복원 계약

기준: JS 원본 `Bellsier/gacha-factory-development` develop `7484ccd` (`js/state.js`, `js/save-engine.js`, `docs/SAVE_S2.md`),
Godot PR #1 `f14d45d` + 1차 수정 브랜치 `claude/feature-parity-p0`.

## 용어

- **원본 보존**: 가져온 JSON 텍스트를 `state.legacy_web_save_source`에 **바이트 그대로** 둔다(S2 봉투 포함).
  게임 본문(`{saveVersion, savedAt, permanent, run}`)은 불러올 때마다 이 텍스트에서 다시 읽어 `state.legacy_web_save`에 둔다
  (`Save.parse_game`). 저장 파일·IndexedDB에는 텍스트만 쓰고 파싱한 사본은 쓰지 않는다(`Save.export_game`).
  Godot는 둘 다 읽기만 하고 고치지 않는다. 가져오기 → 자동 저장 → 다시 불러오기 → 내보내기 → 다시 가져오기를 거쳐도
  텍스트는 바이트 단위로, 본문은 값 단위로 같다
  (`tools/parity_fixes_test.gd`의 `_legacy_save_is_kept`, 웹은 `tests/web-save/run.cjs`의 `s2-import`).
- 텍스트로 두는 이유: Godot 4.4.1의 `JSON.stringify(..., full_precision=true)`는 숫자를 유효숫자 15자리로 쓴다
  (CI 로그: `1/3` → `0.333333333333333`, `0.30000000000000004` → `0.3`). 본문을 딕셔너리로 저장하면 원본 숫자가 바뀐다.
  같은 이유로 Godot 자체 게임 값(골드·재고 등)도 저장할 때 15자리로 반올림된다 — 게임 진행에는 영향이 없는 크기다.
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
| `run.world.workshops[]` (`id, x, y, level, recipeKey, auto, progress`) | 예 | **아니요** | 제작소 건물 미이식. 제작소 단계에서 복원 |
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

Godot `Save.import_legacy`는 `{snapshot: ...}` 행과 snapshot 자체를 받는다. 가져온 텍스트 전체가
`legacy_web_save_source`에 남고, 그 안의 `payload`가 `legacy_web_save`가 된다.

| S2 필드 | 원본 보존 | 활성 복원 | 비고 |
|---|---|---|---|
| `snapshot.payload` | 예 | 위 표대로 | 게임 본문 |
| `snapshot.format` | 예 (텍스트) | 검사만 | 1이 아니면 거부 |
| `snapshot.id` · `villageId` · `name` · `savedAt`, 행 `id` · `revision` · `slot` | 예 (텍스트) | **아니요** | Godot에서 쓰는 곳 없음 |

S2 메타데이터는 텍스트로만 남고 Godot 게임에서는 쓰지 않는다. 마을 이름 표시나 같은 마을 재가져오기 판별에
쓸지는 다음 단계에서 정한다 — 결정 필요. JS 쪽 IndexedDB 원본은 그대로 남는다.

1차 수정 이전(PR #1 `f14d45d`)에 가져온 저장에는 `legacy_web_save_source`가 없다. 그 저장의 `legacy_web_save`는
그대로 쓰지만, 위 숫자 문제 때문에 원본과 1ulp 단위로 다를 수 있고 S2 메타데이터는 이미 버려진 상태다.
원본을 바이트 단위로 보존하려면 JS 저장을 한 번 다시 가져와야 한다.

## 활성 복원 시 지킬 규칙

1. `legacy_web_save_source`와 `legacy_web_save`는 읽기 전용이다. 기능을 이식할 때 원본을 고치지 말고 새 Godot 키에 복원 결과를 쓴다.
2. 복원은 한 번만: 새 Godot 키가 이미 있으면 그것이 우선이다 (`characters`가 있으면 legacy 일꾼을 다시 넣지 않는 현재 방식과 같음).
3. JS sanitize 규칙(`sanitizeWorkshops`, `sanitizeTorches`, `sanitizeTunnelContract`, `sanitizeVillageDecor/District/Site`,
   `sanitizePlayer`)을 그대로 이식하고, 잘못된 항목만 버린다.
4. `tunnelContract.startedAt`은 벽시계(ms) 기준이다. 복원 시 남은 시간을 `durationSec - (지금 - startedAt)/1000`로 계산할지,
   가져온 시점부터 다시 셀지 정해야 한다 — 결정 필요.
5. 제작소 전용 레시피(workshopOnly) 제작 제한은 제작소 건물 복원과 함께 켠다. 이번 단계에서는 꺼 둔다.
