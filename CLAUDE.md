# omarchy-psu — 에이전트 인수인계 문맥

OWON SPE3102 벤치 전원공급기 원격 제어. 로버 개발 환경 원격 자동화의
일부로 `~/playground/random/remote-lab`(전체 자동화 태스크 문서)에서
2026-08-27 독립 분리. GitHub: `cocobunnyfarm/omarchy-psu` (public).
현재 v0.9.0 — 코어/GUI 모두 실기기 검증 완료, 사용자 실사용 피드백
3라운드 + 타이머 기능 반영됨.

## 하드웨어 사실 (전부 실기기 검증)

- 기기: OWON SPE3102 (30V/10A급), 펌웨어 V5.2.0
- 연결: USB → CH340(1a86:7523) → by-id `usb-1a86_USB_Serial-if00-port0`,
  **115200** 8N1, 표준 SCPI (명령 LF, 응답 CRLF)
- 포트 권한: uucp 그룹 (ted 추가됨)
- 검증된 명령: `VOLT(?)`, `CURR(?)`, `VOLT:LIM(?)`, `CURR:LIM(?)`,
  `OUTP(?)`, `MEAS:VOLT?|CURR?|POW?`, `*IDN?` — `docs/psu-api-report.md`
- **기기 한계 질의 지원**: `VOLT? MAX`=31.0 / `VOLT? MIN`=0.01,
  `CURR? MAX`=10.1, `VOLT:LIM? MAX`=32.0, `CURR:LIM? MAX`=10.2.
  ⚠️ 단축형만 동작 (`VOLTage? MAXimum`은 무시되고 현재값 반환)
- **범위 밖 값은 클램프가 아니라 조용히 거부** (설정값 유지) —
  readback 검증으로만 잡힌다
- 포트 연 직후 첫 명령 간헐 무응답 → query() 재시도 1회 필수 (제거 금지)
- PSU가 꺼져도 CH340은 USB 전원으로 살아 있어 /dev/ttyUSB0은 남는다 —
  "포트는 있는데 전 명령 무응답" = 본체 전원 꺼짐
- 기기 기능: AC 인가 5초 후 저장 설정으로 자동 출력 ON (스마트플러그 연동용)

## 아키텍처 (사용자가 확정한 원칙 — 유지할 것)

- **코어/UI 분리**: `core/` = 순수 파이썬(OS 독립, pyserial↔termios 폴백,
  포트 배타 잠금 + 최대 2초 잠금 대기 재시도). `Widget.qml` = 얇은 QML 층,
  `bin/psu`의 JSON만 그림.
- **repo 루트 = 플러그인 루트** (`omarchy plugin add` 요구사항).
- 플러그인 ID: `io.github.cocobunnyfarm.psu` — **변경 금지** (설치 참조 깨짐).
- **프로필은 부하(로버 등) 연동 개념** — 기기 내부 슬롯(*SAV/*RCL) 무시,
  `config/config.json`이 정본. `~/.config/psu` → repo `config/` 심볼릭 링크
  (프로필 수정 = repo working tree 반영 → 커밋이 곧 백업. public 유지 결정).
  ⚠️ 링크는 절대경로 대상이라 **repo 폴더를 옮기면 반드시 재연결**:
  `ln -sfn <새경로>/config ~/.config/psu`. 소비자들(CLI/위젯)은
  ~/.config/psu 만 보므로 링크만 고치면 끝. 현 위치: `~/Projects/omarchy/omarchy-psu`
- 기기 저장은 by-id 안정 경로 (ttyUSB 번호는 연결 순서 따라 바뀜).
- 기기 범위는 불변이라 config에 1회 캐시 (`psu use` 시 + status 자동 백필).
- **출력 ON은 항상 명시적 행동**: profile apply는 출력 안 건드림 + 출력 ON
  중엔 거부(--force), `psu set`은 라이브 튜닝용이라 출력 확인 없음(의도).
- **타이머(출력 자동 차단)도 코어 소유** — `core/psu_timer.py` 가 정책,
  집행은 `psu status` 안에서만 한다. 위젯이 팝업을 닫아둔 채로도 5초마다
  status를 부르므로 **그 폴링이 곧 집행**이다 (사용자가 systemd 폴백은
  불필요하다고 결정 — 셸이 꺼져 있으면 안 꺼지는 게 알려진 한계).
  무장은 '출력 ON을 관찰하면' 이뤄져 전면 패널·스마트플러그 자동 출력까지
  전부 커버된다. 켜는 경로마다 훅 달지 말 것.
  ⚠️ 설정(enabled/default_sec)은 config.json, 무장 상태(deadline)는
  **state.json 에 분리** — config에 넣으면 카운트다운마다 repo working
  tree가 더러워져 '커밋 = 백업' 원칙이 깨진다. state.json은 gitignore.
  ⚠️ 손으로 '해제'하면 `suppressed` 표식을 남긴다. 없으면 출력이 ON인 한
  다음 폴링에서 즉시 재무장돼 해제 버튼이 무의미해진다.

## 적용(apply/set)의 3단 방어 — 전부 실기기 검증됨

1. `validate_profile`: 숫자/음수/NaN, 설정값>리밋 거부 (기기 불필요)
2. `*IDN?` 연결 게이트 + **기기 범위 사전 검증** ("전압 32.0V — 기기 최대
   31.0V 초과" 식 즉시 거부)
3. 단계별 readback 검증 (`_set_verified`) — 실패 시 **이전 설정 롤백**
   (전류 5A 적용 후 리밋 33V 거부 → 완전 복구 실증)
   순서: 현재 리밋 안 설정값 → 리밋 → 설정값 확정 (상호 제약 회피)

## GUI 구조 (Widget.qml — 팝업 뷰 4개)

- **main**: 실측 히어로 / 출력 토글 / 스테퍼 4개(전압·전류·전압리밋·전류리밋)
  / 프로필·기기 네비 행. 연결 안 됨이면 컨트롤 전부 숨기고 안내+네비만.
  - **스테퍼 = 로컬 편집 버퍼** (통신 없음, accent 강조) → "변경 대기 중
    [적용][취소]" → 적용 시 `psu set`으로 바뀐 값만 일괄 전송.
    폴링은 editing 중 버퍼를 덮지 않음. 잠금 에러 UX 문제의 해법이었음.
  - 프로필 표시: `active_profile`(값 일치) 없으면 "자유 모드" —
    튜닝하면 자동으로 자유 모드가 되고 프로필은 절대 저절로 안 바뀜.
- **profiles**: 2줄 카드(이름+요약), active 강조, [적용] 명시 버튼,
  삭제 2단계 확인(×→빨간 '삭제?' 3초). 오프라인에서도 진입 가능.
- **newProfile**: 드래프트 스테퍼(기기·config 무영향), 기기 범위 힌트/클램프,
  기존 이름은 '덮어쓰기?' 2단계, 리밋<설정값이면 저장 차단.
- **devices**: 현재 기기(별칭+by-id) / 진입 시 자동 검색 / [선택]으로 전환.
- **timer**: 사용 토글 / 기본 시간 스테퍼(기기를 안 건드려 포트 잠금 걱정이
  없으므로 메인과 달리 [적용] 없이 600ms 디바운스 자동 저장) / 무장 중이면
  남은 시간 + [+5분][−5분][기본값][해제]. 무장 안 된 이유는 항상 문장으로
  설명한다. 메인에는 `타이머: 12:34 남음` 행(무장 중 accent, 60초 이하
  urgent)과 만료 안내(5분간)가 뜬다.
- 에러는 항상 맨 아래 빨간(Color.urgent) 박스.
- 모든 스테퍼는 기기 범위로 클램프.

## 워크플로

```bash
./bin/psu status / list / profile list      # CLI (기기 범위는 status --json의 range)
./scripts/install-plugin.sh                 # 로컬 개발 설치 (핫리로드)
omarchy restart shell                       # 핫리로드가 컴포넌트를 캐시해 안 먹을 때
journalctl --user | grep omarchy-shell      # QML 에러
omarchy-shell shell toggle io.github.cocobunnyfarm.psu   # 팝업 여닫기
python3 scripts/psu_test.py                 # SCPI API 전수 테스트 (비파괴)
./bin/psu timer                             # 타이머 상태/조작
PSU_CONFIG_DIR=/tmp/x python3 core/psu_cli.py timer   # 실설정 안 건드리고 시험
grim + magick crop                          # 헤드리스 GUI 검증은 스크린샷으로
```

배포 설치(다른 머신/재설치 테스트):
`omarchy plugin add https://github.com/cocobunnyfarm/omarchy-psu.git --enable`
제거: `omarchy plugin remove io.github.cocobunnyfarm.psu` (백업 .bak 생성됨).
주의: plugin add 설치본은 git clone이라 `omarchy plugin update`로 갱신되지만,
로컬 개발은 install-plugin.sh 복사본을 쓴다 — 둘을 오가면 마지막 것이 이긴다.

Omarchy 플러그인 개발 일반 지식: `~/omarchy-setup/reference/omarchy-plugin-dev/`

## 주의사항

- **파괴적 명령 금지**: `*RST`, `*SAV`/`*RCL`. 기기에 로버 세팅
  (13.8V/9.0A, 리밋 14.2V/9.2A = ROVER 프로필) 유지 중.
- 출력 ON은 실부하(로버) 주의. 켜기 전 로버 거치 확인.
- 시스템 파이썬에 pip 없음 — termios 폴백으로 충분.
- 플러그인 폴더 안 심볼릭 링크 금지 (omarchy validate 거부) — 설치는 복사.
- `psu raw`: '?'가 중간에 오는 질의(`VOLT? MAX`)도 응답을 읽는다 (수정됨).

## 상태 / 남은 것

- v0.8.0 완료: 탐색/선택, 프로필 CRUD(뷰 분리), 편집 버퍼+일괄 적용,
  잠금 재시도, 3단 검증+롤백, 기기 범위 캐시/클램프 — 사용자 승인
  ("일단 된 거 같아")
- v0.9.0: 출력 자동 차단 타이머. 코어 정책 13케이스 오프라인 검증 +
  실기기에서 자동 무장/원상복구 확인. **기본값은 `enabled: false`** —
  로버가 물린 상태에서 몰래 켜지면 안 되므로 사용자가 직접 켜야 한다.
  GUI 실사용 피드백 대기 중
- [ ] 로버 실부하 상태에서 GUI 출력 ON 실사용
- [ ] 타이머 실사용 — 실제로 만료돼 꺼지는 것까지 확인 (아직 12시간짜리
      무장/해제만 확인했고 실제 만료 차단은 오프라인 페이크로만 검증)
- [ ] (아이디어) 설정이 더 늘면 timer 뷰를 일반 '설정' 뷰로 승격
- [ ] (아이디어) 프로필 목록이 화면을 넘치면 profiles 뷰에 스크롤
- [ ] (아이디어) 폴링 대신 udev 이벤트로 즉시 연결 감지 — 복잡도 대비 보류

## 사용자 규칙

- 커밋 메시지는 한국어, **Claude 시그니처(Co-Authored-By) 금지.**
- 기기 상태를 바꾸는 테스트는 백업→검증→원상복구, 출력 OFF 상태에서.
- UX 결정은 사용자가 직접 써보고 피드백 — 1차안 만들고 비판받는 흐름.
- 관련: `~/playground/random/remote-lab` (WoL, 스마트플러그, 파이 관제탑 태스크)
