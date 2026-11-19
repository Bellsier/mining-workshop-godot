# 《채굴 공방》 JavaScript → Godot 4.4.1 기능 대조 및 이식 계획

작성일: 2026-11-19 · 작성: Claude (분석만 수행, 코드 수정·커밋·PR 없음)

## 0. 비교 기준

| 구분 | 저장소 · 기준 | 비고 |
|---|---|---|
| 원본 | `Bellsier/gacha-factory-development` **develop `7484ccd`** (현재 develop HEAD와 동일) | `js/` 32파일 · 약 12,100줄, `index.html`, `css/style.css` |
| Godot 이식판 | `Bellsier/mining-workshop-godot` **PR #1 `codex/godot-world-integration` `f14d45d`** | `scripts/` 약 4,600줄. main(`d0f9da6`)은 1단계 시험판뿐이라 PR #1을 기준으로 삼음 |
| PR #2 | `test/godot-visual-qa` `8e83e95` (base `886d12e`) | 게임 기능 변경 없음. 시각 QA(Playwright)만 추가 |

**판정 방법**: 원본 함수와 Godot 대응 함수를 코드로 대조했습니다. 기준표는 원본 설계 문서 `docs/BLUEPRINT_V3.md` 24.2절의 "구현된 기능" 목록입니다. 실제 실행으로 확인한 것은 PR #1의 CI 테스트 범위(저장, 월드 parity, 경로)뿐입니다. 나머지 판정은 **정적 코드 대조**입니다.

**판정 기준**
- **완료**: 기능과 기본 동작이 원본과 같습니다. 화면 표현 방식이 달라도 규칙이 같으면 완료로 봅니다.
- **부분**: 구현됐지만 일부 동작이나 경로가 빠졌거나, 원본과 규칙이 다릅니다.
- **미구현**: Godot에 대응 코드가 없습니다.
- **검증 필요**: 코드는 있지만 동등성을 테스트로 확인하지 못했거나, 판정 전에 결정이 필요합니다.

**우선순위**
- **P0**: 데이터 보존 또는 핵심 루프가 원본과 어긋나는 문제
- **P1**: 핵심 게임 시스템
- **P2**: 탐험·UI 동등성
- **P3**: 연출·편의

## 1. 집계

| 판정 | 항목 수 |
|---|---:|
| 완료 | 38 |
| 부분 | 18 |
| 미구현 | 32 |
| 검증 필요 | 6 |
| 해당 없음 (원본에도 없음) | 1 |
| **합계** | **95** |

요약하면 다음과 같습니다.
- **잘 옮겨진 부분**: 경제의 숫자 규칙(채굴량·배율·제작·판매·연구·납품·명성)과 월드 생성(지형·광맥·산 너머)은 대부분 옮겨졌습니다.
- **크게 빠진 축**: 다섯 가지입니다.
  - 제작소 건물
  - 광맥 확보와 확보 광맥 수입
  - 지역 해금에 따른 광맥 시드와 거점 확장
  - 인부 능력 강화
  - 마을의 월드 배치(구역·집·정원)
- **표현 계층**: 미니맵, 조명, 일꾼 걷기, 픽셀아트는 거의 미구현입니다.

## 2. 영역별 기능 대조표

경로 표기
- 원본: `js/` 아래 파일
- Godot: `scripts/` 아래 파일, `world/`는 `scripts/world/`

### 2.1 채굴

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 손 채굴량 (기본+도구)×배율 | 완료 | systems.js `manualAmount`, `mineResource` | workshop.gd `mine` | — | — | — |
| 광맥 근접 채굴(E) | 부분 | factory.js `mineMine`, topdown/interact.js | world_map.gd `mine_near_vein` → workshop.gd `mine_vein` | 원본은 **확보한 광맥만** 캐고, 양은 `miningPower × 배율`. Godot는 발견한 광맥이면 확보 없이 손 채굴량을 줌 | 광맥 확보 | P1 |
| 채굴장 라인 원격 채굴(패널 버튼) | 미구현 | ui.js `buildLines`, systems.js `mineResource` | — | Godot는 월드 광맥 근처에서만 채굴 가능. 원본 패널의 "채굴" 버튼 없음 | 결정 D1 | P2 |
| 채굴 도구 강화(facility) | 완료 | systems.js `upgradeFacility` | workshop.gd `upgrade("facility:*")` | 비용 공식·상한 동일 | — | — |
| 인력 강화(workforce) | 완료 | systems.js `upgradeWorkforce` | workshop.gd `upgrade("workforce:*")` | — | — | — |
| 자동 채굴(일꾼+인력) | 완료 | systems.js `autoRate`, `tickMining` | workshop.gd `_tick` | — | — | — |
| **확보 광맥 초당 수입** | 미구현 | systems.js `mineBaseRate`, `mineRate` | — | `grade×miningPower×0.4`가 자동 채굴에 더해지지 않음 | 광맥 확보 | P1 |
| **광맥 확보(secure)** | 미구현 | factory.js `secureMine`, `isMineSiteUnlocked` | — | `developmentState`를 읽고 쓰는 경로가 없음. 저장 필드는 world_state.gd가 보존 | 지역 해금 | P1 |
| 미감정 유물 획득(손 채굴) | 부분 | village.js `villageOnManualMine` | workshop_village.gd `mine` | 원본은 산 너머 광맥이면 `BEYOND_STEP` 적용. Godot 호출부는 `beyond` 인자를 넘기지 않아 항상 일반 단계 | — | P2 |
| 공용 저장소 표시 | 완료 | ui.js `renderSharedStorage` | workshop_hud.gd `_render_inventory` | 원본은 자원·제품 구분, Godot는 "가방" 하나 | — | P3 |

### 2.2 지형·광맥·월드

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 산맥·터널·산 너머 4구역 | 완료 | terrain.js | world/world_terrain.gd | 원본 값 1,122개 parity 테스트 통과 | — | — |
| 새 게임 광맥(거리 링) | 완료 | worldgen.js `generateInitialWorldMines` | world/world_gen.gd | 씨드 3개 parity 통과 | — | — |
| 산 너머 광맥(터널 개통 시) | 완료 | worldgen.js `generateBeyondMines`, factory.js `populateBeyondMines` | world_gen.gd, world_state.gd `unlock_tunnel` | — | — | — |
| 지질 조사 광맥 | 완료 | research.js `surveyMines` | world_gen.gd `survey_mines` | — | — | — |
| 지역 해금 시 고정 광맥 시드 | 미구현 | systems.js `seedWorldMinesForSite`, data.js `WORLD_MINE_SEEDS` | — | 생성기는 시드 칸을 비워 두지만, 해금해도 광맥이 생기지 않음. 마정석·결정 등은 링에서만 나옴 | — | P1 |
| 산 너머 풍경과 갇힘 방지 | 완료 | terrain.js `terrainBeyondProps`, player.js `worldSceneryBase` | world_terrain.gd, world_map.gd | 규칙 동일, 그림은 임시 도형 | — | P3 |
| 이동 충돌 정밀도 | 부분 | player.js `worldStepFoot`, `CORNER_SLIP`, `PLAYER_FOOT` | 타일 충돌 + CharacterBody2D | 원본 마진 0.3·코너 미끄러짐 없음. 순수 판정 함수는 동일하지만 실제 이동은 근사 | — | P2 |
| 이동 속도 | 검증 필요 | balance.js `PLAYER_SPEED: 3` | player.gd `speed 72px/s` = 1.125단위/초 | 원본의 약 37% 속도 | 결정 D2 | P2 |
| 256 시험 월드(청크 생성기) | 부분 | chunkgen.js, worldchunks.js, worldnavigation.js | world/chunk_gen.gd, world_state.gd | 생성은 완료(parity). 시험 패널·순간이동·별도 저장 키·청크 편집 저장 UI는 없음 | 결정 D6 | P3 |
| 1단계 overworld·tunnel 장면 | 검증 필요 | (원본 없음, Godot 고유) | scenes/overworld.tscn, tunnel.tscn, workshop_world.gd | 메인 장면은 이미 world_map. 옛 장면과 고정 픽셀 광맥(workshop_world.gd)이 남아 있음. route-test만 사용 | — | P2 |

### 2.3 제작

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 레시피 18종 수동·시간 제작 | 부분 | systems.js `startCraft`, `tickCrafting` | workshop.gd `craft`, `_start_craft`, `_tick` | 원본은 `workshopOnly` 레시피를 손으로 못 만듦. Godot는 차단이 없어 상위 부품을 공방에서 바로 제작 가능(제작소 부재를 메우는 임시 동작으로 보임) | 제작소 건물 | P0 |
| 제작 시설 강화 | 완료 | systems.js `upgradeCraftFacility`, `craftSpeed` | workshop.gd `upgrade("craft_facility")` | 명성 제작속도 효과 포함 | — | — |
| 목표 재고(자동 제작 정지) | 완료 | systems.js `setCraftTarget`, `atCraftTarget` | workshop.gd `set_craft_target` | — | — | — |
| 재료 부족 사유 표시 | 부분 | ui.js `recipeNeedRows`, `recipeCraftReason` | workshop_hud.gd `_render_recipes` | 원본의 부족 재료·잠긴 자원 안내 문구가 단순화됨 | — | P3 |

### 2.4 판매·경제

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 전량 판매 | 완료 | systems.js `sellAll` | workshop.gd `sell` | — | — | — |
| 자동 판매 구매·켜고 끄기 | 완료 | systems.js `buyAutoSell`, `tickAutoSell` | workshop.gd `buy_auto_sell`, `set_auto_sell` | 제작소 전용 제외 동일 | — | — |
| 본사 투자 | 완료 | systems.js `investHQ` | workshop.gd `upgrade("hq_level")` | — | — | — |
| 첫 가챠권(50G) | 완료 | systems.js `checkFirstGachaMilestone` | workshop.gd `_check_first_ticket` | — | — | — |
| 가챠권 자동 지급(45초) | 부분 | systems.js `ticketTrickle` | workshop.gd `_tick` | 원본은 **첫 가챠권 이후에만** 지급. Godot는 게이트 없이 처음부터 지급(초반 진행 우회) | — | P0 |
| 명성 배율(채굴·판매) | 완료 | delivery.js, systems.js `mult` | workshop_delivery.gd `reputation_multiplier` | — | — | — |

### 2.5 자동화

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 자동 제작(연구 게이트) | 부분 | systems.js `tickCrafting` | workshop.gd `_tick` | 원본은 `workshopOnly` 자동 제작 제외. Godot는 포함 | 제작소 | P0 |
| 제작소 자동 제작 | 미구현 | factory.js `tickWorkshops` | — | — | 제작소 | P1 |
| 병목 표시 | 미구현 | factory.js `bottleneckReport`, ui.js `updateBottleneck` | — | — | 제작소 | P2 |
| 철·석탄 자동화 달성 안내 | 미구현 | systems.js `checkDualAutomation` | — | 일회성 안내 로그 | 기록 패널 | P3 |

### 2.6 인부(일꾼)

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 가챠(가챠권·골드, 희귀도 4단계) | 완료 | systems.js `pullGacha` | workshop.gd `hire` | — | — | — |
| 담당 자원 배치 | 완료 | systems.js `reassignWorker` | workshop.gd `assign_worker` | — | — | — |
| **능력 강화(채굴·운반·이동)** | 미구현 | systems.js `upgradeWorkerStat`, `workerUpgradeCost` | — | `miningLvl` 등 저장 필드는 보존되지만 강화 불가 | — | P1 |
| 인원 상한(거점 레벨별) | 부분 | systems.js `workerCap` | workshop.gd `hire` | Godot는 고정 8명. 원본은 거점 레벨마다 +4 | 거점 확장 | P1 |
| 최근 뽑기 표시 | 미구현 | ui.js `renderLastPull` | — | 토스트만 있음 | — | P3 |
| 월드의 일꾼 표시·걷기(A*) | 미구현 | topdown/workers.js, worldnavigation.js | — | 보기 전용(생산량 무관) | 스프라이트 | P3 |

### 2.7 건물

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 공방(거점) 위치·문 상호작용 | 완료 | state.js `freshBasePosition`, topdown/interact.js | world_map.gd `context_at`, game.gd | — | — | — |
| **거점 확장(base.level)** | 미구현 | systems.js `expandBase` | — | `base.level`은 저장되지만 오르지 않음 | 지역 해금 | P1 |
| **제작소 건설(최대 6, 증축 8)** | 미구현 | factory.js `buildWorkshop`, `workshopBuildSpot`, `workshopBuildCost` | — | 연구 "제작소 건설·증축" 효과가 없음 | — | P1 |
| 제작소 레시피 지정·업그레이드·제작 | 미구현 | factory.js `setWorkshopRecipe`, `upgradeWorkshop`, `craftWorkshop` | — | — | 제작소 건설 | P1 |
| 건물 충돌(공방·제작소 발밑 상자) | 부분 | player.js `WORLD_OBSTACLE_BOXES` | world_map.gd `_add_static_box` | 공방·광맥은 있음, 제작소·마을 건물은 없음 | 제작소·마을 | P2 |
| 마을 건물 월드 배치(감정소·박물관 부지, 벽, 문) | 미구현 | village.js `villageEnsureSites`, `villageObstacleBoxes`, `villageTargetFor` | — | Godot는 마을 탭 패널에서만 복구·감정·기증 | — | P2 |
| 설치형 횃불(최대 12) | 미구현 | player.js `placeTorch`, `removeTorch`, `torchAct` | — | catalog에 `torch` 규칙은 있음. `world.torches`는 가져오기에서 버려짐 | — | P2 |

### 2.8 연구

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 9개 연구 목록·비용·선행·즉시 완료 | 완료 | research.js `doResearch`, data.js `RESEARCH` | workshop.gd `unlock` | 박물관 연구 할인 포함 | — | — |
| 효과: 자동 제작·납품 계약·터널 굴착·탐사 장비·지질 조사·거래 확대·빠른 거래 | 완료 | research.js `RESEARCH_EFFECTS` | workshop.gd, workshop_delivery.gd, world_state.gd | — | — | — |
| 효과: 제작소 건설·제작소 증축 | 부분 | research.js | — | 연구는 살 수 있지만 쓸 곳이 없음 | 제작소 | P1 |
| 연구 갈래 그룹 표시 | 부분 | ui.js `renderResearch`, data.js `RESEARCH_BRANCHES` | workshop_hud.gd `_render_research` | 갈래별 묶음 없이 목록 하나 | — | P3 |

### 2.9 지역 해금

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| site 해금(골드+상위 부품) | 완료 | systems.js `unlockSite`, `canUnlockSite` | workshop.gd `open_site` | 비용 규칙 동일 | — | — |
| 해금 순서(거점 확장 버튼) | 미구현 | systems.js `expandBase`, ui.js `nextExpansionSite` | — | Godot는 아무 순서로 해금 가능 | 결정 D3 | P1 |
| 해금 연동 레시피 안내 | 미구현 | systems.js `siteRelatedRecipeNames` | — | 안내 문구 | — | P3 |

### 2.10 탐험

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 숨은 광맥 발견(반경 2.5→4.0) | 완료 | systems.js `tickExploration` | world_state.gd `explore` | — | — | — |
| 터널 공사(의뢰·600초·개통) | 부분 | factory.js `orderTunnelWork`, `tickTunnelWork` | workshop.gd `order_tunnel`, `_tick` | 원본은 **실제 시각** 기준이라 게임을 꺼도 진행. Godot는 실행 중 tick만 셈 | — | P1 |
| 탐험 지도·미니맵 | 미구현 | ui.js `renderExplorationMap`, topdown/render.js `tdRenderMinimap` | — | 발견한 광맥만 보이는 지도 | — | P2 |
| 월드 오브젝트 선택·정보 | 미구현 | ui.js `selectWorldObject`, `renderWorldInfo` | — | — | — | P3 |
| 현재 지역 이름 표시 | 완료(Godot 추가) | (원본 없음) | world_map.gd `_build_ui` | 원본보다 앞선 표시 | — | — |

### 2.11 주민·마을

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 시설 단계 복구(감정소→박물관) | 완료 | village.js `villageRestore` | workshop.gd `restore_facility` | 패널 방식 | — | — |
| 미감정 유물 감정·도감(12종) | 검증 필요 | village.js `villageAppraise`, `villageNextRelic`, `villageHash01` | workshop_village.gd `appraise`, `_hash_01` | 결정적 해시를 이식했지만 원본 대비 parity 테스트 없음 | — | P1 |
| 마을 구역(광장·도로·가로등·안내판) | 미구현 | village.js `villageEnsureDistrict`, `villageRoads` | — | 저장의 `village.district`·`sites`가 가져오기에서 버려짐 | 마을 월드 배치 | P2 |
| 플레이어 집(실내) | 미구현 | village.js `villageHomeEnter`, `villageHomeTick`, topdown/render.js `tdRenderHome` | — | — | 마을 구역 | P3 |
| 정원·장식 배치 | 미구현 | village.js `villageDecorPlace`, `villageDecorMove`, `villageDecorRemove` | — | 저장의 `village.decor` 미보존 | 마을 구역 | P3 |
| NPC·주민 생활 | 해당 없음 | (원본에도 미구현, 청사진 23.9) | — | 이식 대상 아님 | — | — |

### 2.12 박물관

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 유물 기증 | 완료 | village.js `villageDonate` | workshop.gd `donate_relic` | 보상 달성 안내(`villageAnnounceRewards`)는 없음 | — | — |
| 광물·보석 표본 기증 | 완료 | village.js `villageDonateSpecimen` | workshop.gd `donate_specimen` | — | — | — |
| 일괄 기증 | 미구현 | village.js `villageDonateAll` | — | — | — | P3 |
| 보상: 연구 골드 할인 3%/5% | 완료 | village.js `villageResearchDiscountPercent` | workshop_village.gd `research_discount` | — | — | — |
| 보상: 장식 해금·전시실 꾸미기 | 미구현 | village.js `villageRewardDecorUnlocked`, `villageHallLevel` | — | — | 정원·스프라이트 | P3 |
| 진열창 점등 연출 | 미구현 | topdown/sprites.js `tdVillageSprite` | — | — | 마을 월드 배치 | P3 |

### 2.13 납품·명성

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 회사 3곳·슬롯·터널 조건 | 완료 | delivery.js `companySlots`, `isCompanyOpen` | workshop_delivery.gd `_open_companies` | — | — | — |
| 고정·반복 수주, 도착 간격, 2번째 슬롯 | 완료 | delivery.js `issueOrder`, `tickOrders`, `completeOrder` | workshop_delivery.gd `offers`, `complete`, `tick` | — | — | — |
| 정기 거래(예비 재고 10 보존) | 완료 | delivery.js `tickTrades` | workshop_delivery.gd `_regular_trade` | — | — | — |
| 명성 효과 4종 | 완료 | delivery.js `reputationEffect` | workshop_delivery.gd `reputation_effect` | — | — | — |
| **자유 납품(점수 쌓기)** | 부분 | delivery.js `deliverProducts`, ui.js `renderDelivery` | workshop_delivery.gd `ship`(존재) | 함수는 있지만 workshop.gd·HUD에 경로가 없어 플레이어가 쓸 수 없음 | — | P1 |
| 명성 효과 안내 화면 | 부분 | ui.js `renderReputation` | workshop_hud.gd `_render_deliveries` | 효과 목록·다음 해금 안내 없음 | — | P3 |

### 2.14 저장

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| 자동 저장·안전 쓰기(웹·데스크톱) | 완료 | state.js `saveGame`, save-engine.js | workshop.gd, workshop_save.gd, workshop_web_save.js | PR #1로 원본 이상 보호(보호 저장·충돌·quota) | — | — |
| JS v1·S2 snapshot JSON 가져오기 | 완료 | state.js `migrateSave` | workshop_save.gd `import_legacy` | 원본 payload는 `legacy_web_save`로 보존 | — | — |
| **JS 저장의 세부 필드 반영** | 부분 | state.js `sanitizeWorldState`, `sanitizeVillageState` | workshop.gd `_restore` | 반영됨: 자원·제품·인부·연구·site·자동화·명성·광맥·숨김·터널. **반영 안 됨**: 제작소(`world.workshops`), 횃불, 마을 `sites`/`district`/`decor`, 공사 진행(`tunnelContract` 실시각), 인부 능력 레벨 사용처. 원본 JSON은 남지만 게임 상태로 살아나지 않음 | 각 기능 | P0 |
| S2 다중 마을·자동 저장 목록·수동 5슬롯 | 미구현 | save-engine.js, save-runtime.js | — | Godot는 슬롯 하나(`slot:main`) | 결정 D4 | P2 |
| 기존 웹판 저장 자동 이전(localStorage·S2 IDB) | 미구현 | storagekeys.js, save-runtime.js | — | 배포 출처가 다르면 원리상 불가. 현재는 JSON 붙여넣기만 지원 | 결정 D5 | P1 |
| 새 게임 시작(현재 저장 보존) | 미구현 | state.js `saveStartOver` | — | 보호 저장 "보관 후 새로 시작"만 있음 | — | P2 |
| 손상·미래 버전 보호 | 완료 | state.js `protectCorruptSave` | workshop.gd `_protect` | — | — | — |

### 2.15 UI·조작·연출

| 기능 | 판정 | 원본 | Godot | 누락·차이 | 의존성 | 우선 |
|---|---|---|---|---|---|---|
| HUD(골드·가방·저장 상태) | 완료 | index.html, ui.js `renderCurrencies` | workshop_hud.gd `_build_bar` | — | — | — |
| 패널 탭(가방·제작·판매·인부·연구·납품·마을·저장) | 부분 | index.html 탭(채굴·개발·인부·연구·납품·마을), ui.js | workshop_hud.gd | 원본 "채굴" 탭(거점 정보·채굴장 라인)과 "개발" 탭의 제작소 영역이 없음 | 제작소 | P2 |
| 다음 목표 힌트 | 미구현 | ui.js `updateNextHint`, `firstGoalHint`, `lateGameHint` | — | 초반 안내 | — | P2 |
| 기록(로그) 패널 | 미구현 | systems.js `log`, index.html `#log` | — | Godot는 짧은 토스트만 | — | P2 |
| 키보드 이동·E 상호작용 | 완료 | player.js, topdown/app.js | player.gd, game.gd | — | — | — |
| 휴대폰 조이스틱·행동 버튼 | 검증 필요 | topdown/app.js `tdBindStick` | touch_stick.gd, workshop_hud.gd | Chromium 에뮬레이션만 확인, 실기기 미확인 | — | P2 |
| 횃불·정원 버튼, T/R/Q 단축키 | 미구현 | topdown/app.js | — | — | 횃불·정원 | P2 |
| 조명·저녁빛·반딧불·구름·흔들림 | 미구현 | topdown/light.js | — | 보기 전용 | — | P3 |
| 픽셀아트 스프라이트(광부 4방향, 광맥 8종, 공방, 제작소 3단계) | 부분 | topdown/sprites.js, hires.js, style.js | art/player.png, world_map.gd 도형 | 광부만 스프라이트, 나머지는 임시 도형 | — | P3 |
| 2.5D 클래식 화면(`?view=classic`) | 검증 필요 | ui.js `renderWorld*` | — | 원본도 이전 화면. **이식 제외** 권고 | 결정 D7 | — |
| 시각 QA(장면별 스크린샷) | 검증 필요 | (원본 tests/playthrough) | PR #2 tests/visual | PR #1 이후 저장 위치(`/userfs`→`slot:main`)가 달라 PR #1 위에서 동작 안 함 | PR #1 병합 | P1 |

## 3. 기존 PR #1·#2와의 관계

- **PR #1 (`f14d45d`)**: 이 대조의 기준입니다. 월드 통합, 터널 공사, 탐사 연구, 저장 안정성(고정 키·보호·복구·다중 브라우저)이 들어 있습니다. 저장 구조(`slot:main`, Godot v1 envelope)는 이후 기능의 저장 필드가 얹힐 바탕입니다.
- **새 저장 필드를 추가할 때**: `world.workshops`, `world.torches`, `village.sites`/`district`/`decor` 같은 필드는 다음 두 가지를 함께 처리해야 합니다.
  - Godot `_valid_save_state`와 `_restore`의 정규화
  - JS 저장 가져오기의 필드 매핑

  PR #1의 저장 보호 규칙(미래 버전 보호, 가져오기 시 백업)은 그대로 적용됩니다.
- **PR #2**: 게임 코드 변경이 없어 기능 대조에는 영향이 없습니다. 다만 PR #1 위로 리베이스할 때 저장 읽기·쓰기를 `tests/web-save/store.cjs` 방식(`slot:main` + revision)으로 바꾸고, 준비 조건에 `__trial_save_status`를 넣어야 합니다(이전 리뷰 H1). 새 기능의 시각 QA는 PR #2 하네스를 확장해 쓰는 것을 권합니다.

## 4. 단계별 이식 계획

각 단계는 PR 하나를 기본으로 합니다. 각 PR에는 원본 대비 규칙 parity 테스트(Godot headless)를 붙이고, 기존 CI(저장 3종 브라우저, World QA)가 초록이어야 합니다.

### 1단계 · 규칙 정합성과 데이터 보존 (P0)
1. **가챠권 자동 지급 게이트**: 첫 가챠권 이후에만 지급하도록 고칩니다.
2. **제작소 전용 레시피(`workshopOnly`)**: 손·자동 제작에서 차단합니다. 단, 제작소(3단계)가 들어오기 전에 막으면 상위 부품 진행이 막히므로 **3단계와 같은 PR에서 켜는 기능 플래그**로 둡니다.
3. **가져오기 회귀 테스트**: 원본 고정 저장 `tests/fixtures/save_v1_midgame.json`으로 Godot 가져오기 테스트를 만듭니다. 아직 쓰지 않는 필드(제작소·횃불·마을 부지)도 Godot 저장에 **그대로 실어 다시 내보내도록** 보존 규칙을 정합니다(다음 단계에서 잃지 않게).
4. **parity 테스트 확장**: 경제 공식(채굴량·배율·비용 곡선·명성·수주)으로 넓힙니다. 원본 JS를 Node로 실행해 기준값을 만드는 기존 `tools/world/make_web_fixtures.cjs` 방식을 씁니다.

### 2단계 · 핵심 경제 완성 (P1)
1. **광맥 확보와 확보 광맥**
   - 확보(`secureMine`)와 확보 광맥 채굴(`mineMine`: `miningPower × 배율`)
   - 확보 광맥 초당 수입(`mineRate`)
   - 월드 상호작용 문구를 "확보 / 채굴"로 분리
2. **지역 해금 연동**
   - 해금 시 `WORLD_MINE_SEEDS` 광맥 시드
   - 거점 확장과 `base.level`, 인부 상한 +4/레벨
   - 해금 순서는 결정 D3에 따름
3. **인부 능력 강화**: 채굴·운반·이동, 상한 3
4. **자유 납품 UI**: 이미 있는 `ship`을 연결
5. **터널 공사 실시각 진행**: 원본 `tunnelContract.startedAt` 방식. 저장 필드 추가가 필요하고 JS 저장 가져오기에도 매핑
6. **감정 결과 parity 테스트**: `villageHash01`·가중치

### 3단계 · 제작소 건물 (P1)
- **건설 위치**: 위치 선정(`workshopBuildSpot`), 비용 곡선, 최대 6, 증축 연구로 8
- **제작 기능**: 레시피 지정, 업그레이드(Lv.8, 부품 비용), 제작 속도, 자동 제작, 목표 재고
- **화면·월드**:
  - 병목 표시
  - 월드 건물과 충돌
  - 문 앞 상호작용으로 개발 패널 열기
  - 원본의 "개발" 탭 구조 복원
- **함께 켤 것**: 1단계의 `workshopOnly` 플래그. 연구 "제작소 건설·증축" 효과도 이때 활성화됩니다.

### 4단계 · 탐험·UI 동등성 (P2)
- 탐험 지도·미니맵(발견한 광맥만), 월드 정보
- 다음 목표 힌트, 기록 패널(원본 로그 문구 이식)
- 설치형 횃불(규칙은 catalog `torch`에 있음), 단축키 T
- 이동 속도·충돌 정밀화(결정 D2), 패널 원격 채굴(결정 D1)
- 1단계 overworld·tunnel 장면과 `workshop_world.gd` 정리(테스트 경로 이전 포함)

### 5단계 · 마을의 월드화 (P2→P3)
- **P2**
  - 감정소·박물관 부지 선정(`villageEnsureSites`, 도달 가능 검사)
  - 건물 벽 충돌, 문 상호작용
  - 광장·도로·가로등·안내판
- **P3**
  - 플레이어 집 실내
  - 정원 4×3 장식 배치·이동·회수(Q·R)
  - 박물관 보상의 장식 해금·전시실 꾸미기·진열창 점등, 일괄 기증, 보상 달성 안내

### 6단계 · 연출과 저장 확장 (P3)
- 조명·환경 연출, 일꾼 월드 표시·걷기(A* 길찾기 이식)
- 픽셀아트 스프라이트 교체(원본 `topdown/sprites.js` 절차 생성 이식 또는 새 아트)
- S2 수준 저장 확장(결정 D4): 다중 마을·수동 5슬롯·새 게임
- 256 시험 월드 UI(결정 D6)

**권장 병렬화**
- 2단계의 1(광맥 확보)과 3단계(제작소)는 서로 독립적입니다. 저장 필드만 미리 합의하면 Claude와 Codex가 나눠 진행할 수 있습니다.
- 5단계 마을은 3단계의 건물 충돌·배치 공통 코드에 의존합니다.

## 5. 결정이 필요한 항목

| 번호 | 질문 | 영향 |
|---|---|---|
| D1 | 원본처럼 패널에서 원격 채굴 버튼을 유지할지, 월드 근접 채굴만 둘지 | 2.1, UI |
| D2 | 이동 속도를 원본 3단위/초(192px/s)로 맞출지, 현재 1.125단위/초를 유지할지 | 탐험 체감, 테스트 시간 |
| D3 | 지역 해금을 원본처럼 순서 고정(거점 확장)으로 할지 | 2.9, 인부 상한 |
| D4 | 저장을 S2처럼 다중 마을·수동 5슬롯으로 확장할지, 단일 슬롯+JSON 백업으로 갈지 | 2.14, 6단계 |
| D5 | 기존 웹판 플레이어 저장을 어떻게 옮길지: 같은 출처 배포로 자동 이전 vs JSON 내보내기·가져오기 안내 | 출시 전 필수 결정 |
| D6 | 256 시험 월드와 청사진 23장(7개 지역·대형 월드)을 Godot 이식 범위에 넣을지 | 2.2 |
| D7 | 2.5D 클래식 화면을 이식 대상에서 제외할지(권고: 제외) | 범위 |

## 6. 이 대조의 한계

- **정적 대조**: 원본과 Godot 모두 이번 분석에서 새로 실행하지 않았습니다. "완료" 판정 가운데 테스트로 뒷받침된 것은 다음뿐입니다. 나머지는 함수 단위 코드 대조에 근거합니다.
  - World parity(1,122 checks)
  - 저장 E2E(Chromium 16/16, Firefox 13/13, WebKit 16/16 재실행)
  - Godot 회귀 테스트
- **경제 수치**: 공식 비교는 코드 읽기 수준입니다. 동등성을 확정하려면 1단계의 parity 테스트 확장이 필요합니다.
- **범위 제외**: 원본 청사진 23장의 미구현 목표(7개 지역, 지하 도시, 전투, 스토리 등)는 원본에도 없으므로 이식 대상에서 뺐습니다.
