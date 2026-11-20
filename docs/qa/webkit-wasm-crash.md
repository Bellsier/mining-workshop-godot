# WebKit 26.0의 WebAssembly 결함과 저장 E2E (2026-11-19)

## 증상

CI `Godot migration QA`의 `Web save durability (webkit)` 작업만 간헐적으로 실패했다.
Chromium과 Firefox는 같은 빌드에서 통과했다. 실패하는 케이스는 매번 달랐고, 엔진이 부팅 중에 죽었다.

- `RuntimeError: Out of bounds memory access (evaluating 'f(...args)')`
- `ERROR: FATAL: Index p_index = N is out of bounds (size() = N)` (`core/templates/cowdata.h:219`), 이어서 `RuntimeError: Unreachable code should not be executed`
- `FreeType: Error loading font: ''`
- WebKit 페이지 프로세스 종료 (`Target page, context or browser has been closed`)

이번 이식 전 커밋도 같은 증상을 보였다.
- 861e792는 첫 실행에서 17/17이었다. 재실행(run 44540582740, attempt 2)에서는 13/17이었고, 같은 오류가 났다.
- 이전 커밋 f3dc6a5, f14d45d도 같은 방식으로 흔들렸다.

## 재현

`LIBGL_ALWAYS_SOFTWARE=1`을 켜고, 하네스의 준비 단계만 반복했다. 준비 단계는 새 게임 → 저장 교체 → 다시 열기 순서다.
지금은 `SAVE_QA_REPEAT=<n> node run.cjs`로 같은 반복을 돌릴 수 있다.

| WebKit (Playwright) | 설정 | 반복 | 엔진 크래시 |
|---|---|---|---|
| 26.0 (1.56.1, 이전 CI) | 기본 | 20 + 30 | 2 + 2 (약 8%) |
| 26.0 | `JSC_useOMGJIT=false` (최상위 wasm 최적화 끔) | 30 + 40 | 메모리 크래시 0. 다만 셰이더 조합 오류 1 (아래) |
| 26.4 (1.59.0) | 기본 | 40 | 0 |
| 26.6 (1.63.0) | 기본 | 40 | 0 |

단순히 부팅·새로고침만 반복할 때는 26.0에서도 60번 넘게 재현되지 않았다.

## 근거

1. **같은 코드 경로에서 난다.** 크래시 스택은 매번 `callMain`(엔진 시작) 아래, 같은 wasm 함수 6452에서 끝났다.
   그 위의 상호 재귀(함수 5400↔6310) 깊이는 회마다 달랐다. GDScript 함수가 서로를 부르는 모양이다.
   같은 wasm은 Chromium·Firefox에서는 한 번도 죽지 않았다.
2. **계산값이 틀린다.** OMG를 끈 실행에서 Godot가 `USE_NINEPATCH`와 `USE_ATTRIBUTES`를 동시에 켠 캔버스 셰이더를 컴파일하려다 실패했다
   (`'vertex_base' : undeclared identifier`). `vertex_base`는 `USE_ATTRIBUTES`가 꺼진 경로에서만 선언되므로, 엔진이 정상적으로는 만들지 않는 조합이다.
   wasm 안에서 계산한 64비트 특수화 비트값이 잘못 나온 것이다.
3. **이후 WebKit에서는 사라진다.** WebKit 26.4와 26.6에서는 JIT를 켠 채로 각각 40번 모두 정상이었다.

결론: 이 게임의 스크립트나 저장 코드 결함이 아니다. WebKit 26.0의 WebAssembly 컴파일러(JavaScriptCore)가 Godot 4.4.1 wasm을 잘못 번역한 결함이고, WebKit 26.4 이전에 고쳐졌다.
오디오 워클릿 누수([godotengine/godot#107390](https://github.com/godotengine/godot/issues/107390))와는 다르다. 이 게임은 오디오를 쓰지 않는다.

## 조치

- **CI의 Playwright를 1.56.1에서 1.59.0으로 올렸다.**
  - 컨테이너는 `mcr.microsoft.com/playwright:v1.59.0-noble`이고, 브라우저는 WebKit 26.4, Chromium 147, Firefox 148이다.
  - 검증, 대기 시간, 재시도는 바꾸지 않았다.
  - 더 최신인 1.63.0(Firefox 155)은 쓰지 않았다. Firefox 155는 저장 트랜잭션 도중 새로고침하면 출처 없는 `InvalidStateError: Navigated away from page`를 콘솔에 남긴다.
    저장 결과 검증은 통과했지만, 하네스는 모든 콘솔 오류를 실패로 본다. 이 동작은 Firefox 148에서는 없다.
- **저장 상태를 즉시 내보낸다.** 게임은 `window.__trial_save_status`를 바뀌는 순간 갱신한다.
  예전에는 다음 위치 보고 때(한 프레임 뒤) 갱신했다. 그래서 자동 저장이 같은 프레임 안에 IndexedDB 쓰기까지 갔을 때, 하네스가 이전 값 `pending`을 읽을 수 있었다(WebKit 26.6에서 드러남).
- **닫힌 패널의 스냅샷 계산을 없앴다(이번 이식에서 생긴 성능 회귀).**
  - HUD는 게임이 바뀔 때마다(틱마다 최대 초당 10회) 모든 탭의 스냅샷을 만들었다. 패널이 닫혀 있어 금화 한 줄만 쓰는 때도 그랬다.
  - 제작소 자리 탐색이 마을 도로까지 보게 되면서, 이 스냅샷 한 번이 네이티브에서 67ms가 됐다. 대부분은 "다음 제작소를 지을 수 있는가" 판정(77ms)이었다.
  - 그 결과 제작소 연구를 마친 저장에서 Firefox(소프트웨어 렌더링)의 새로고침 후 첫 저장이 4초에서 12초 이상으로 늘었다. 그래서 20초 대기에 닿는 일이 생겼다.
  - 이제 닫힌 패널은 금화만 읽는다. 제작소 판정은 제작소·광맥·마을·터널이 바뀔 때만 다시 계산한다(0.05ms).
- **크래시 위치를 남긴다.** 하네스는 페이지가 `console.error`로 넘긴 Error 객체의 스택을 함께 남긴다. 그래서 다음 엔진 크래시는 wasm 함수 번호까지 로그에 남는다.
- **크래시 빈도를 잴 수 있다.** `SAVE_QA_REPEAT=<n>`으로 준비 단계만 n번 반복한다.

## 남는 위험

- Safari 26.0~26.3을 쓰는 실제 사용자도 같은 결함을 겪을 수 있다. 위 재현 조건에서는 부팅의 약 8%였다.
  26.1~26.3은 직접 시험하지 못했다(Playwright가 해당 WebKit을 배포하지 않았다).
- 실기기 Safari/iOS에서 업데이트 전후를 확인해야 한다. 26.0 사용자에게는 업데이트를 안내하는 것이 현실적이다.
