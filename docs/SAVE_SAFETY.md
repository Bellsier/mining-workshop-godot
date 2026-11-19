# 저장 안전 정책 (웹·데스크톱)

플레이어의 기존 저장은 **복구 가능한 상태로만** 바뀝니다. 아래 규칙은 `scripts/workshop.gd`, `scripts/workshop_web_save.js`, `scripts/workshop_save.gd`에 구현돼 있습니다.

## 웹 저장소 구조

브라우저 IndexedDB `mining-workshop-godot` / `saves`

| 키 | 내용 | 쓰는 때 |
|---|---|---|
| `slot:main` | 현재 저장 (고정 키, 프로젝트 이름과 무관) | 자동 저장·가져오기·보관 처리 |
| `slot:main:before-import` | 가져오기로 바뀌기 직전 저장 (마지막 1회분) | 가져오기와 같은 트랜잭션 |
| `slot:main:protected:<revision>` | 열 수 없어 보관 처리한 원본 | 보관 처리와 같은 트랜잭션 |
| `/userfs/...` (Godot 사용자 폴더 경로) | `8317ce2` 빌드의 저장 | 읽기만 함 (이전용, 삭제 안 함) |

Godot `user://workshop_save.json`(첫 웹 빌드)도 읽기만 하며 지우지 않습니다.

모든 쓰기는 `slot:main`의 revision을 비교하는 **한 트랜잭션**입니다. 실패·중단·시간 초과·다른 탭 충돌이면 아무것도 바뀌지 않습니다.

## 저장 완료 표시의 의미

| 상태 | 화면 | 뜻 |
|---|---|---|
| `saved` | 저장됨 | 트랜잭션 완료, 브라우저가 `durability: "strict"`를 확인함(디스크 기록 후 완료) |
| `saved_basic` | 저장됨 · 기본 보장 | 트랜잭션 완료. 브라우저가 strict를 지원·확인하지 않아 운영체제 장애 시 보장은 브라우저 기본 수준 |

두 경우 모두 **브라우저가 사이트 데이터를 정리하거나 사용자가 삭제하면 사라질 수 있습니다.** 저장 탭에서 `navigator.storage.persist()`를 요청하거나 JSON/파일 백업을 할 수 있습니다.

## 실패와 복구

| 상황 | 처리 | 기존 저장 |
|---|---|---|
| 로드 실패·지연·차단 | 0.5→1.5→3초 간격 자동 재시도(총 4회) 후 선택 패널: 다시 시도 / 현재 진행 내보내기 / 저장 없이 계속 | 덮어쓰지 않음 (확인 전까지 쓰기 금지) |
| 다른 탭이 열려 있음 (Web Locks) | 3초 대기 후 선택 패널: 다시 확인 / 저장 없이 둘러보기 | 쓰지 않음 |
| 다른 곳에서 더 최근 저장 (revision 충돌) | 선택 패널: 이 탭 진행 내보내기 / 최신 저장 불러오기 / 저장 없이 계속 | 쓰지 않음 |
| 쓰기 실패 | 2→4→8→16→30초 간격 재시도, "지금 다시 저장" 버튼 | 마지막 저장 유지 |
| 저장 공간 부족 (`QuotaExceededError`) | 15→30→60초 간격 재시도, 백업 안내 | 마지막 저장 유지 |
| 손상·미래 버전 저장 | 선택 패널: 원본 내보내기(웹은 파일 다운로드) → 그 뒤에만 "원본 보관 후 새로 시작"이나 가져오기 가능 | 원본은 보관 키/파일로 이동, 삭제 안 함 |

데스크톱 보관 파일 이름: `user://workshop_save.protected-<시각>-<난수>.json` (복구용 `.previous`도 함께 보관).

## 저장 빈도

게임 진행이 바뀌면 2초 안에 저장합니다. 걷기만 했다면 15초에 한 번 저장합니다. 페이지가 숨겨지거나 닫힐 때(`visibilitychange`, `pagehide`)와 창이 포커스를 잃을 때는 즉시 저장을 시작합니다. 페이지가 이미 닫히는 중이면 브라우저가 트랜잭션을 끝내지 못할 수 있고, 이때는 마지막 저장이 그대로 남습니다.

자동 저장은 이 게임이 마지막으로 쓰거나 정상으로 읽은 파일(SHA-256 일치)이면 다시 파싱하지 않고 덮어씁니다. 그 밖의 파일은 지금처럼 먼저 읽어 보고, 손상·미래 버전이면 쓰지 않습니다. 가져오기는 저장 텍스트를 한 번만 파싱합니다.

## 테스트

| 테스트 | 실행 | 범위 |
|---|---|---|
| `tests/web-save/store-unit.cjs` | `SAVE_QA_BROWSERS=chromium,firefox,webkit node store-unit.cjs` | JS 저장 모듈: CAS, 두 탭 경쟁, 키 이전과 실패, 보호 저장, quota(크롬은 실제 한도), 시간 초과, 차단, 잠금 |
| `tests/web-save/run.cjs` | `SAVE_QA_BROWSER=<엔진> SAVE_QA_WEB=<웹 빌드> node run.cjs` | 실제 Godot 웹 빌드 E2E |
| `tools/save_performance_test.gd` | `MINING_QA_ISOLATED=1 XDG_DATA_HOME=<빈 폴더> godot --headless --path . --script res://tools/save_performance_test.gd` | 대용량(약 0.4·1.6MB JS 저장 + 제작소 8곳) 가져오기·자동 저장·불러오기 시간 예산과 4배 데이터 증가율, 손실 없음, 빠른 경로의 안전성 |
| `tools/save_recovery_test.gd` | `MINING_QA_ISOLATED=1 XDG_DATA_HOME=<빈 폴더> godot --headless --path . --script res://tools/save_recovery_test.gd` | 데스크톱 보호·보관·재시도·저장 빈도 |
