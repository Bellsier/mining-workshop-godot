# Godot 웹 시각 QA

`Godot migration QA`의 Chromium 작업은 같은 Actions 실행에서 만든 Godot 4.4.1 웹 빌드 산출물을 내려받습니다. Ubuntu 24.04 기반 Microsoft Playwright 1.56.1 이미지에 포함된 Chromium으로 Playwright가 빌드를 루프백에 띄우고, GitHub Actions에서 발급한 별도 서버나 외부 프리뷰 주소 없이 게임을 조작합니다. 기존 Godot 회귀 검사는 계속 실행됩니다.

## 캡처와 검증 범위

| 시나리오 | 실제 입력 | 준비 상태 |
|---|---|---|
| 데스크톱 공방 | E로 공방 열기, 마우스로 채굴·제작·판매·인부·연구·납품·마을·저장 탭 | 새 게임 |
| 데스크톱 미개통 터널 | A로 입구 접근, 같은 방향으로 계속 입력해 통과 차단 확인 | 시드 42, 닫힌 통로 앞 저장 |
| 데스크톱 산 너머 | WASD로 터널 통과와 광맥 발견, E로 광맥 확보 후 다시 E로 채굴, I로 가방 확인, 저장 반영 후 새로고침 | 시드 42, 개통 완료와 마정석 지역 해금 저장 |
| 844×390 · 568×320 | 공방 버튼 및 탭 터치, 가상 조이스틱 드래그와 해제, 채굴 버튼 터치(광맥 확보 후 채굴), 가방 확인 | 시드 42, 공방 앞 저장 |

테스트 저장은 새 브라우저 컨텍스트와 전용 루프백 주소에서 게임이 처음 만든 저장 기록(IndexedDB `mining-workshop-godot`의 `slot:main`)에만 적용됩니다. 쓰기는 `tests/web-save/store.cjs`를 거쳐 격리된 `/__qa_fixture` 페이지에서만 합니다. 준비가 끝나면 플레이어 이동과 채굴은 실제 브라우저 입력으로 진행합니다. 준비 저장에는 실제 사용자 정보가 들어 있지 않습니다. 월드 생성에 난수가 쓰이므로 새 게임 화면의 광맥 배치는 실행마다 달라질 수 있습니다.

브라우저는 개통 완료 저장으로 600초 대기를 생략합니다. Godot의 기존 `world_integration_test.gd`가 선행 연구, 중복 의뢰 방지, 600초 조건, 잔여 시간 복원과 완공 시점 개통을 별도로 검증합니다. 이 검사는 Godot의 공사 틱을 진행합니다. 확보된 광맥은 초당 등급×0.4씩 스스로 산출하므로, 채굴 검사는 한 번 누를 때 1개가 늘었는지를 그 산출을 감안해 봅니다. 시각 QA는 입력에 따른 UI 상태와 저장 복원을 검사하고, PNG는 사람이 그래픽을 검토하는 자료로 남깁니다. 골든 이미지 차이 비교와 실제 휴대폰 검증은 별도입니다.

## GitHub에 저장되는 자료

Actions 실행의 Summary에서 시나리오 결과를 확인하고 **Artifacts → godot-visual-qa**를 내려받습니다. 보관 기간은 30일입니다.

- `report.md`에는 실행 커밋, 브라우저·엔진 버전, 화면 크기, 입력과 준비 상태, 장면별 PNG 목록이 있습니다.
- `screenshots/<scenario>/*.png`에는 정렬된 시나리오별 화면이 있습니다.
- `result.json`과 `browser.log`에서 성공·실패와 브라우저 오류·콘솔을 확인할 수 있습니다. 실행이 실패하면 가능한 마지막 화면과 남은 결과도 업로드합니다.

## 로컬에서 재실행

Godot 4.4.1 Web 내보내기 결과가 있는 디렉터리를 지정합니다.

```sh
npm --prefix tests/visual ci
(cd tests/visual && npx playwright install chromium)
VISUAL_QA_WEB=/absolute/path/to/web npm --prefix tests/visual test
```

기본 출력 위치는 `tests/visual/results`입니다. `VISUAL_QA_OUTPUT`으로 변경할 수 있고, `VISUAL_QA_CHROMIUM`으로 설치된 Chromium 실행 파일을 지정할 수 있습니다.

## 일반 ChatGPT에서 결과 보기와 실시간 제어

- **자동 조작**은 위 GitHub Actions에서 수행합니다. 스크린샷과 결과 파일은 실행이 끝난 뒤에도 검토할 수 있습니다.
- **GitHub 결과 조회**는 ChatGPT GitHub 앱이 제공하는 작업과 계정 권한에 따라 달라집니다. OpenAI의 일반 ChatGPT 안내는 허용된 저장소의 소스·문서 검색을 설명하며, Actions 아티팩트 ZIP 안의 PNG 분석까지 보장하지 않습니다. ZIP을 GitHub에서 내려받아 보고서와 PNG를 ChatGPT에 첨부하면 그래픽 검토를 진행할 수 있습니다. Actions 읽기 권한이 있는 도구는 아티팩트 API로도 내려받을 수 있습니다. [ChatGPT GitHub 연결](https://help.openai.com/en/articles/11145903-connecting-github-to-chatgpt) · [GitHub 아티팩트 다운로드](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)
- **실시간 Playwright MCP**는 GitHub 결과 조회와 별개의 연결입니다. 일반 ChatGPT 웹은 로컬 stdio 서버에 직접 연결하지 않습니다. OpenAI 문서상 전체 MCP 동작은 Business·Enterprise/Edu의 지원 워크스페이스에서 사용할 수 있으며, Pro 개발자 모드는 읽기·가져오기 권한 범위입니다. 화면 탐색, 클릭, 키 입력 등 브라우저 제어 도구가 허용되는지는 요금제와 관리자 정책을 확인해야 합니다. 현재 프로젝트에는 MCP 연결을 설정하지 않았습니다. [OpenAI 사용자 지정 MCP 서버](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt)
- **서버와 권한**이 필요한 경우 브라우저가 실행될 머신의 Microsoft Playwright MCP를 호환되는 원격 HTTP MCP 엔드포인트로 연결합니다. 계정에서 허용하는 인증 방식과 관리자 권한이 필요합니다. 예를 들어 HTTPS 게이트웨이에서 OAuth와 접근 정책을 적용하거나, 지원 워크스페이스에서 Secure MCP Tunnel을 통해 비공개 서버를 연결할 수 있습니다. MCP 도구가 조작하는 브라우저는 해당 서버가 실행하거나 연결한 브라우저입니다. 별도 프로필과 네트워크 접근 범위로 격리하고 개인 계정 세션을 재사용하지 않습니다. Microsoft의 호스트·오리진 옵션만으로 격리나 인증을 대체할 수 없습니다. [Microsoft Playwright MCP](https://github.com/microsoft/playwright-mcp) · [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
