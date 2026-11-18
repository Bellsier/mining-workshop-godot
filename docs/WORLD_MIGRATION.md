# 통합 브랜치 업데이트 — 2026-11-18

`codex/godot-world-integration`은 a259e72 + Claude 417ce54를 통합한다. 아래 원본 이관 기록의 임시 연결과 현재 동작을 구분한다.

- 기본 시작은 `scenes/world/world_map.tscn`: 공방 앞, 산맥 통로, 산 너머가 하나의 지도다.
- 기존 overworld/tunnel 두 시험 씬과 시험 왕복 경로는 회귀용으로 보존한다. 기존 서쪽 문 경로는 개통 준비 상태에서만 검사한다. 입장으로 무료 개통하지 않는다.
- Workshop이 WorldState를 소유한다. 자동 저장(기존 2초), JSON 가져오기/내보내기에 배치, 숨은 광맥 ID, 월드 위치, 공사 잔여 시간이 포함된다. 저장 v1과 기존 경제 필드는 유지한다.
- 오래된 작은 시험 맵의 픽셀 위치는 새 지도 좌표와 다르므로 공방 시작점으로 이전한다. 재고·인부·연구는 유지한다.
- 터널 굴착 연구 후 연구 탭에서 공사 의뢰: 원본 비용 5,000G + 합금 5개, 600초. 완료할 때만 산 너머 광맥과 통로 충돌을 갱신한다. 오프라인 공사 가속은 추가하지 않는다.
- 탐사 장비는 발견 반경 4.0, 지질 조사는 숨은 광맥 3개 추가. 불러오기 때 연구 효과가 중복 생성되지 않는다.
- 일반 월드 입력은 Game의 E/행동 버튼으로 통일한다. 공방 메뉴가 열리면 월드 채굴을 차단한다.
- 256 시험 월드 UI/저장 전환 기능은 추가하지 않았다. 일반 플레이는 기존 24×24 월드다.

추가 검사: `tools/world_integration_test.gd`, `tools/unified_world_route_test.gd`.

---

# 월드·지역 이관 (Godot 4.4.1)

원본: `Bellsier/gacha-factory-development` @ `7484ccdca65e2e02c8a33f8160c5950562d35a5d` (develop)
범위: 지형·타일·바이옴(산 너머 4구역), 새 게임 광맥 배치(거리 고리), 터널 개통 후 산 너머 광맥, 지질 조사, 광맥 발견(탐색), 256 시험 월드 청크 생성기.

## 파일

| 파일 | 원본 | 내용 |
|---|---|---|
| `scripts/world/world_data.gd` | — | `data/web_catalog.json`을 **읽기만** 함. JSON이 담지 못한 무한대를 `INF`로 되돌림 |
| `scripts/world/world_random.gd` | — | 씨드 난수(mulberry32). 웹의 `Math.random` 자리를 씨드로 재현 |
| `scripts/world/world_terrain.gd` | `js/terrain.js`, `js/topdown/tiles.js`(tdTileAt), `js/player.js`(worldSceneryBase) | 지역·구역·보행 판정, 바닥 타일, 산 너머 풍경과 갇힘 방지 필터 |
| `scripts/world/world_gen.gd` | `js/worldgen.js`, `js/research.js`(surveyMines) | 새 게임 광맥, 산 너머 광맥, 지질 조사 광맥 |
| `scripts/world/chunk_gen.gd` | `js/chunkgen.js` | 256 시험 월드 생성기 v1/v2 (씨드·청크 32×32) |
| `scripts/world/world_state.gd` | `state.world`, `systems.js`(탐색), `factory.js`(unlockTunnel), `worldchunks.js` | 한 판의 월드: 광맥, 숨은 광맥, 터널 개통, 발견, 저장 형태 |
| `scripts/world/world_tiles.gd` | `TD_COLORS` | 코드로 그린 바닥 TileSet(충돌은 걷는 땅에 닿은 바위·가장자리에만) |
| `scripts/world/world_map.gd`, `scenes/world/world_map.tscn` | 탑다운 월드 화면 | 탐험 씬: 바닥·봉우리·공방·광맥·풍경·지역 이름·발견 알림 |
| `scripts/world/world_passage_door.gd` | — | 통로 가운데 문. 서쪽으로 들어가면 1단계 터널 동쪽 끝, 동쪽으로 들어가면 서쪽 끝 |

좌표: 웹 월드 1단위 = 64px, 바닥 타일 = 1/4단위 = 16px. 공방은 (2, 0) → (128, 0)px.

## 경로 (1단계 왕복은 그대로)

```
공방 앞(overworld) ──터널 입구──> 1단계 터널 ──동쪽 Exit──> 공방 앞      (기존, 변경 없음)
                                   └─서쪽 West 문──> 월드 지도 FromTunnel(산 너머, 터널 개통)
월드 지도 통로 문 ──동쪽으로──> 1단계 터널 FromBeyond(서쪽 끝)
```

`scenes/tunnel.tscn`의 변경(West 문, FromBeyond, 안내 문구)은 **별도 커밋**이라 따로 되돌릴 수 있습니다.
월드 지도만 열려면 편집기에서 `scenes/world/world_map.tscn`을 열고 **F6**(공방 앞 Start에서 시작). 인스펙터 `World` → `Seeded World`를 켜면 256 시험 월드(동쪽 연결 통로 너머)가 붙습니다.

## 테스트

```bash
godot --headless --path . --script res://tools/world_logic_test.gd
```
원본 웹 코드를 Node로 실행해 만든 기준값(`tests/world/web_world_fixtures.json`)과 지역·구역·보행·타일·봉우리·풍경·광맥 배치(씨드 3개)·청크(씨드/버전 3조합 × 4청크)를 값 단위로 비교 → `WORLD LOGIC PASS`.
기준값 다시 만들기: `node tools/world/make_web_fixtures.cjs <웹 저장소 체크아웃>`

```bash
godot --headless --path . --fixed-fps 60 --script res://tools/world_route_test.gd
```
1단계 터널 → 서쪽 문 → 산 너머(광맥 8개 배치 확인) → 서쪽 탐색으로 광맥 발견 → 통로 문 → 1단계 터널 → 공방 앞 → 월드 지도 Start → `WORLD ROUTE PASS`.

CI: `.github/workflows/world-qa.yml` (claude/** 푸시). 기존 `--route-test`(ROUTE PASS)도 함께 돌립니다.

## 연결 지점 (Codex 쪽 파일은 건드리지 않았습니다)

1. **저장** (`workshop_save.gd`): 저장할 때 `WorldState.current().to_dict()`를 `world`로 넣고, 불러올 때 `WorldState.set_current(WorldState.from_dict(saved.world))`. 형태는 웹 `state.world`와 같습니다(`base`, `mines`, `hiddenMineIds`, `tunnelUnlocked`, 시험 월드면 `seed/size/generatorVersion/chunkEdits`). 웹 저장의 `state.world`를 그대로 넣어도 읽힙니다. 지금은 메모리에만 있어 게임을 끄면 새 배치가 됩니다.
2. **터널 공사 완료** (연구 `tunnelWork` → 공사 의뢰 → 시간 경과): 완료 시 `WorldState.ensure_current().unlock_tunnel()` 한 줄. 지금은 1단계 터널 서쪽 문으로 들어오면 열린 것으로 봅니다.
3. **연구**: `explorationGear` 완료 → `state.exploration_gear = true`(발견 반경 2.5→4.0), `geologicalSurvey`(지질 조사) 완료 → `state.run_survey()`.
4. **채굴**: 월드 지도에서 발견한 광맥 앞 **E** → `Game.workshop.mine(resource)`를 부릅니다(잠금 판정은 공방 쪽 그대로). 광맥별 `developmentState`/등급 효과는 아직 공방에 넘기지 않습니다.
5. **HUD**: 월드 지도는 화면 왼쪽 아래에 `World/WorldUI/Region`(지역·광맥 수·E 안내)과 `Toast`를 직접 그립니다. HUD로 옮기려면 `world_map.gd`의 `_physics_process` 문구를 `Game._hud`로 넘기면 됩니다.

## 초기 이관 누락 목록

| 항목 | 원본 | 상태 |
|---|---|---|
| 마을 바닥(광장·길·정원)과 마을 시설 벽 | `village.js`, tdTileAt `village` | 미이관. `tile_at`은 마을 없이 공방 마당·터널 길만 그림 |
| 공방 증축(제작소 오두막) 위치와 벽 | `state.world.workshops` | 미이관(경제 쪽과 함께) |
| 횃불·조명 | `state.world.torches`, `topdown/light.js` | 미이관 |
| 일꾼 길찾기(A*)·광맥까지 걷기 | `worldnavigation.js`, `topdown/workers.js` | 미이관 |
| 탐색 지도(미니맵) | `topdown/render.js` 미니맵 | 미이관. 지역 이름·발견 수 표시만 |
| 터널 공사 의뢰·타이머 | `factory.js` orderTunnelWork | 공방 쪽 담당. 연결 지점 2 |
| 거점 확장 시 기본 광맥 추가 | `WORLD_MINE_SEEDS`, expandBase | 자리만 비워 둠(생성기가 피함). 추가 자체는 경제 쪽 |
| 저장/불러오기 | `save-runtime.js` | 형태만 준비(to_dict/from_dict). 연결 지점 1 |
| 정밀 이동 규칙 | `PLAYER_MARGIN 0.3`, `CORNER_SLIP`, 발 상자 0.18×0.12 | Godot 충돌로 근사: 타일 단위 벽 + 플레이어 발 10×6px. 순수 판정 `is_point_walkable`은 웹과 동일(테스트됨) |
| 이동 속도 | 웹 3단위/초 | `player.gd` 72px/s = 1.125단위/초(파일 소유자 결정 필요) |
| 고해상도 스프라이트·스타일 v2 | `topdown/sprites.js`, `hires.js`, `style.js` | 임시 도형으로 그림 |
| 256 시험 월드의 시험 패널·순간이동·별도 저장 키 | `worldchunks.js` worldTestControls | 미이관. `seeded_world` 내보내기 값으로만 켬 |
| 공방 앞 1단계 맵과 월드 지도 열린 땅의 관계 | — | **결정 필요**: 1단계 overworld를 월드 지도 열린 땅으로 대체할지, 지금처럼 두 화면을 문으로 이을지. `workshop_world.gd`의 고정 광맥 좌표와 `WorldState` 광맥도 이때 하나로 맞춰야 함 |

## 웹과 다른 점

- 새 게임 배치는 씨드(`layoutSeed`)로 뽑습니다. 같은 씨드면 웹 코드에 같은 난수를 넣은 결과와 똑같습니다(테스트로 확인).
- 터널 개통 시 산 너머 광맥과 지질 조사 광맥은 같은 씨드 흐름을 이어 씁니다(불러온 판은 `layoutSeed ^ 0x5bd1e995`).
