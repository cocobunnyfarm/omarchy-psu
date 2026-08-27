# omarchy-psu — 에이전트 인수인계 문맥

OWON SPE3102 벤치 전원공급기 원격 제어. 로버 개발 환경 원격 자동화의
일부로, `~/playground/random/remote-lab`(전체 자동화 태스크 문서)에서
2026-08-27 독립 분리. GitHub: `cocobunnyfarm/omarchy-psu` (public).

## 하드웨어 사실 (실기기 검증됨)

- 기기: OWON SPE3102 (30V/10A), 펌웨어 V5.2.0
- 연결: USB → CH340(1a86:7523) → by-id `usb-1a86_USB_Serial-if00-port0`,
  **115200** 8N1, 표준 SCPI(명령 LF, 응답 CRLF)
- 포트 권한: uucp 그룹 (ted 추가됨)
- 검증된 명령: `VOLT(?)`, `CURR(?)`, `VOLT:LIM(?)`, `CURR:LIM(?)`,
  `OUTP(?)`, `MEAS:VOLT?|CURR?|POW?`, `*IDN?` — `docs/psu-api-report.md`
- 기기 기능: AC 인가 5초 후 저장 설정으로 자동 출력 ON (스마트플러그 연동용)

## 아키텍처 (사용자가 확정한 원칙 — 유지할 것)

- **코어/UI 분리**: `core/` = 순수 파이썬(OS 독립, pyserial↔termios 폴백,
  포트 배타 잠금). `Widget.qml` = 얇은 QML 층, `bin/psu`의 JSON만 그림.
- **repo 루트 = 플러그인 루트** (`omarchy plugin add` 요구사항).
- 플러그인 ID: `io.github.cocobunnyfarm.psu` — **공개 후 변경 금지**
  (설치자 바 설정이 깨짐).
- **프로필은 부하(로버 등) 연동 개념** — 기기 내부 슬롯(*SAV/*RCL, 이름
  불가·직접 읽기 불가)은 무시, `~/.config/psu/config.json`이 정본.
- 기기 저장은 by-id 안정 경로 (ttyUSB 번호는 연결 순서 따라 바뀜).
- 출력 ON은 항상 명시적 행동 — profile apply도 출력은 건드리지 않고,
  출력 ON 중 apply는 거부(--force로만 무시).

## 주의사항 / 함정

- **파괴적 명령 금지**: `*RST`, `*SAV`/`*RCL`. 기기에 로버 세팅
  (13.8V/9.0A, 리밋 14.2V/9.2A = ROVER 프로필) 유지 중.
- **출력 ON은 실부하 주의**: 로버가 물려 있을 수 있다.
- 포트 연 직후 첫 명령 간헐 무응답 → query() 재시도 1회 필수 (제거 금지).
- 플러그인 폴더 안 심볼릭 링크 금지 → `scripts/install-plugin.sh`가 복사.
- 시스템 파이썬에 pip 없음 — termios 폴백으로 충분.

## 워크플로

```bash
./bin/psu status / list / profile list      # CLI 확인
./scripts/install-plugin.sh                 # 플러그인 설치/갱신 (핫리로드)
journalctl --user | grep omarchy-shell      # QML 에러
omarchy-shell shell toggle io.github.cocobunnyfarm.psu   # 팝업 여닫기
python3 scripts/psu_test.py                 # API 전수 테스트 (비파괴)
```

Omarchy 플러그인 개발 일반 지식: `~/omarchy-setup/reference/omarchy-plugin-dev/`

## 상태 / TODO

- v0.2.0: 기기 탐색/선택(list/use) + 프로필 CRUD(GUI 포함) 완료, 실기기 검증됨
- [ ] 사용자 GUI 사용 후 피드백 반영 (UX 비판 예정)
- [ ] 로버 거치 후 GUI 출력 ON 실사용 테스트
- [ ] 프로필/설정 백업: ~/.config/psu/ 를 dotfiles 백업 흐름에 포함
  (omarchy-setup docs/06-dotfiles-backup.md 참고)

## 사용자 규칙

- 커밋 메시지는 한국어, **Claude 시그니처(Co-Authored-By) 금지.**
- 기기 상태를 바꾸는 테스트는 백업→검증→원상복구.
- 관련: `~/playground/random/remote-lab` (WoL, 스마트플러그, 파이 관제탑 태스크)
