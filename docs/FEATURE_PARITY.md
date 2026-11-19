# 기능 대조표 — 원본 JS ↔ Godot (2026-11-19)

원본: `Bellsier/gacha-factory-development` @ `7484ccd` (js/ 30개 파일, 약 11,000줄)
Godot: `Bellsier/mining-workshop-godot` 브랜치 `claude/modest-mendel-yvz6iv` (Godot 4.4.1)

원본의 `js/` 전체 함수 목록을 파일별로 대조했다. 상태:

- **완료**: 같은 규칙으로 이식했고, 수치는 원본 JS를 Node로 실행해 만든 기준값과 비트 단위로 비교한다(테스트 이름 표기).
- **부분**: 동작은 있으나 원본과 일부 다르다(차이 명시).
- **미구현**: 이식하지 않았다(이유와 후속 조치 명시).
- **해당 없음**: 원본에서도 플레이 기능이 아니다(개발용 URL 스위치, 시험 월드 등).

## A. 채굴·광맥·경제

| 원본 기능 | 원본 위치 | 상태 | Godot 위치 · 검증 |
|---|---|---|---|
| 수동 채굴 (base + 채굴 도구) × 배율 | systems.js `mineResource`, `manualAmount` | 완료 | `workshop.gd mine()` · 채굴 탭 · economy_parity_test |
| 광맥 발견 (반경 2.5, 탐사 장비 4.0) | systems.js `tickExploration` | 완료 | `world_state.gd explore` · world_logic_test |
| 광맥 확보 (발견 + 지역 해금 필요) | factory.js `secureMine` | 완료 | `secure_vein` · E 키·채굴 탭 · economy_parity_test |
| 확보한 광맥 직접 채굴 (채굴력 × 배율) · 유물 발견 | factory.js `mineMine`, village.js `villageOnManualMine` | 완료 | `mine_vein` (산 너머·유물 광맥 가중치 포함) |
| 확보 광맥 자동 산출 (채굴력 × 등급 × 0.4/초) | systems.js `mineBaseRate`, `autoRate` | 완료 | `auto_rate` · 70틱 비트 일치 |
| 일꾼·인력 강화 자동 산출, 틱 합산 순서 | systems.js `tickMining` | 완료 | `_tick` (rate / TICKS_PER_SECOND) |
| 채굴 도구·인력 강화 (상한 12) | systems.js `upgradeFacility/Workforce` | 완료 | 채굴 탭 |
| 본사 투자 (상한 12)·제작 시설 강화 (상한 15) | systems.js `investHQ`, `upgradeCraftFacility` | 완료 | 제작 탭 (원본 개발 탭 위치) |
| 지역 탐사(해금)와 시드 광맥 배치 | systems.js `unlockSite`, `seedWorldMinesForSite` | 완료 | `open_site` · economy_parity_test |
| 거점 확장 (다음 지역 + 거점 레벨) | systems.js `expandBase` | 완료 | `expand_base` · 채굴 탭 |
| 판매·자동 판매 (제작소 전용 제외) | systems.js `sellAll`, `tickAutoSell` | 완료 | 레시피 순서·거래 뒤 실행 |
| 레시피 제작·대기열·자동 제작·목표 재고 | systems.js `startCraft`, `tickCrafting` | 완료 | 레시피 순서, 끝난 틱에 재시작 안 함 |
| 첫 가챠권(50G)·45초 지급 | systems.js `checkFirstGachaMilestone`, `ticketTrickle` | 완료 | parity_fixes_test |
| 납품: 고정 수주·반복 수주·정기 거래·명성·명성 효과 | delivery.js | 완료 | `workshop_delivery.gd` · 명성 배율 합산 순서 수정 |
| 납품 탭: 회사 카드·닫힌 이유·점수·정기 거래 상태·자유 납품·명성 효과 | ui.js `renderDelivery`, `renderReputation` | 완료 | 납품 탭 |
| 연구 9종·효과·선행 조건·박물관 할인 | research.js | 완료 | 연구 탭 |
| 오래된 저장의 연구 인정 | research.js `researchSyncFromState` | 완료 | 제작소·자동 제작 사용 시 |
| 오프라인 진행 | — | 해당 없음 | 원본은 오프라인 진행이 없다(`tickClock`: 자리를 비운 시간은 재생하지 않음). 실시간으로 도는 것은 터널 공사뿐 → D 참조 |

## B. 일꾼·자동화

| 원본 기능 | 원본 위치 | 상태 | Godot 위치 · 검증 |
|---|---|---|---|
| 고용 (가챠권·골드), 등급 확률, 해금 자원 배치 | systems.js `pullGacha`, ui.js | 완료 | 인부 탭 |
| 일꾼 정원 (8 + 거점 레벨당 4) | systems.js `workerCap` | 완료 | economy_parity_test |
| 일꾼 능력 강화 (3종 × 3단계) | systems.js `upgradeWorkerStat` | 완료 | 인부 탭 |
| 재배치, 방금 뽑은 일꾼, 철·석탄 자동화 안내 | systems.js `reassignWorker`, `checkDualAutomation`, ui.js `renderLastPull` | 완료 | 인부 탭·기록 |
| 일꾼이 서는 자리 (확보 광맥 우선, 마당 대기) | workers.js `tdComputeWorkerPlacements` | 완료 | `world_workers.gd` · village_layout_test (6개 월드 일치) |
| 일꾼 걷기: 공방 문 출발, 터널 경유, 비켜 가기 | workers.js `tdWorkerSimStep` | 완료 | 화면 전용(원본도 저장 안 함) · world_objects_test |
| 256 시험 월드의 A* 길찾기 | worldnavigation.js | 해당 없음 | 시험 월드(`?worldgen=256`) 전용. 일반 플레이 월드는 원본도 A* 미사용 |

## C. 제작소·건물·마을

| 원본 기능 | 원본 위치 | 상태 | Godot 위치 · 검증 |
|---|---|---|---|
| 제작소 건설·레시피·수동·자동 제작·업그레이드·전용 레시피 | factory.js | 완료 | `craft_huts.gd` · craft_hut_test (40단계 비트 일치) |
| 제작소 자리 (마을·도로 회피 포함) | factory.js `workshopBuildSpot` | 완료 | village_layout_test |
| 제작소 월드 표시·충돌·E로 카드 열기·병목 보고 | render/sprites/interact.js, ui.js `bottleneckHtml` | 완료 | `world_objects.gd` · 제작 탭 |
| 감정소·박물관 자리 (도달성 검사 포함) | village.js `villageEnsureSites` | 완료 | `village_layout.gd` · 사이트 좌표 일치 |
| 마을 광장·집·정원 구역과 도로망 | village.js `villageEnsureDistrict`, `villageRoadsCompute` | 완료 | 도로 점 단위 일치 |
| 시설 복구 2단계·감정·기증·표본·박물관 보상 | village.js | 완료 | 마을 탭·E 키 |
| 집 안 (방·가구·문으로 나가기, 안에서 저장 위치 = 문 앞) | village.js `VILLAGE.HOME` | 완료 | `scenes/world/house.tscn` · world_objects_test |
| 정원 장식 놓기·옮기기·회수·종류 선택, 보상 장식 해금 | village.js garden | 완료 | E / R / Q · 마을 탭 |
| 광장 안내판 → 마을 탭 | interact.js | 완료 | |
| 정원 장식 버튼 (회수·다음 장식, PC는 [R]/[Q] 표시) | app.js `tdGardenButton` | 완료 | 행동 버튼 위 |

## D. 월드·탐험

| 원본 기능 | 원본 위치 | 상태 | Godot 위치 · 검증 |
|---|---|---|---|
| 지역·지형·통행·산 너머 구역·풍경 충돌 | terrain.js, player.js | 완료 | world_logic_test (1122개 값) |
| 새 게임 광맥 배치·산 너머 광맥·지질 조사 | worldgen.js | 완료 | world_logic_test |
| 터널 공사: 실시간(종료 중에도 진행), 시계를 되돌리면 지금부터 | factory.js `tunnelContract` | 완료 | `_tick_tunnel` · world_integration_test |
| 상호작용 대상 고르기 (1.15 범위, 문 앞 가산, 바라보는 방향) | interact.js `tdInteractTarget` | 완료 | `world_map.gd find_target` |
| 횃불 놓기·줍기 (최대 12, 간격·문·광맥 규칙) | player.js `torchAct` | 완료 | T 키·터치 버튼 |
| 빛: 8분 해질녘 순환, 등불·창·대장간·광맥·횃불·등롱·랜턴 빛 | light.js | 완료 | CanvasModulate + PointLight2D |
| 구름 그림자·반딧불·풀 흔들림 | light.js `tdCloudShadows`, `tdFireflies`, render.js `tdSway` | **미구현** | 순수 장식 효과. 후속 그래픽 단계 |
| 미니맵 | render.js `tdRenderMinimap` | 완료 | `world_minimap.gd` |
| 플레이어 이동 속도 3단위/초 | balance.js `PLAYER_SPEED` | 완료 | 72 → 192 px/s |
| 모서리 미끄러짐(CORNER_SLIP) | player.js `worldStepFoot` | **부분** | Godot 물리(move_and_slide)로 미끄러짐. 수치 동일성은 미보장 |
| 256 시험 월드 | worldchunks.js | 해당 없음 | Godot에 생성기는 있음(시험용), 일반 플레이에서 노출 안 함 |

## E. UI·조작·그래픽

| 원본 기능 | 원본 위치 | 상태 | Godot 위치 |
|---|---|---|---|
| 탭: 채굴·개발·인부·연구·납품·마을 | index.html | 완료 | 가방·채굴·제작·판매·인부·연구·납품·마을·저장 (개발 = 제작+판매) |
| 다음 할 일 안내 | ui.js `updateNextHint` | 완료 | 채굴 탭 위 |
| 기록(최근 40개) | systems.js `log` | 완료 | 가방 탭 아래 |
| 키보드: 이동·E/Space·T·R·Q·Esc·I | app.js | 완료 | |
| 터치: 이동 스틱·행동 버튼·횃불 버튼·정원 버튼 | app.js | 완료 | |
| 클래식 화면의 월드 클릭 정보 패널 | ui.js `renderWorldInfo` | 해당 없음 | 원본 클래식 화면 전용. 탑다운 화면은 E 대상 표시로 대신함 |
| 캐릭터·건물·광맥 그림 | sprites.js, style.js, hires.js | **부분** | 코드로 그린 단순 도형. 원본 픽셀 스프라이트와 시각 일치는 후속 그래픽 단계 |
| 저장 · 마을 메뉴: 마을 여러 개, 마을별 자동 저장, 수동 슬롯 5개 | save-runtime.js, save-engine.js (S2) | **미구현** | Godot는 단일 슬롯 + 가져오기·내보내기·보호 저장. 여러 슬롯은 저장 구조 변경이라 디렉터 결정 필요 |
| 화면 크기·방향 대응 | style.css | 부분 | 480×270 확대(expand). 세로 화면 별도 배치 없음 |

## 저장 호환성

| 데이터 | 처리 |
|---|---|
| JS `run.world.workshops / torches / tunnelContract / player` | 그대로 복원(원본 sanitize 규칙). 이전 Godot 저장에는 보관된 JS 원본에서 복원 |
| JS `run.village.sites / district / decor` | 그대로 복원. 이전 Godot 저장(sites 없음)은 보관된 JS 원본에서 복원, 없으면 원본 규칙으로 새로 배치 |
| JS `run.lastPull / autoLineLogged` | 복원 |
| 이전 Godot `tunnel_remaining` | 남은 시간 그대로 실시간 공사로 전환 |
| JS 원본 바이트 | 변경 없음 (SHA-256 보존) |
