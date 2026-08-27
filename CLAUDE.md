# psu-control — 에이전트 인수인계 문맥

OWON SPE3102 벤치 전원공급기 원격 제어. 로버 개발 환경의 원격 자동화
프로젝트 중 하나로, 2026-08-27에 `~/playground/random/remote-lab`(전체
자동화 태스크 문서 repo)에서 독립 프로젝트로 분리됐다.

## 하드웨어 사실 (실기기 검증됨)

- 기기: OWON SPE3102 (30V/10A), 펌웨어 V5.2.0
- 연결: USB → CH340 칩(1a86:7523) → `/dev/ttyUSB0`, **115200** 8N1
- 프로토콜: **표준 SCPI**, 명령 끝 LF(`\n`), 응답 끝 CRLF
- 포트 권한: uucp 그룹 필요 (ted는 추가됨)
- 검증된 명령: `VOLT(?)`, `CURR(?)`, `VOLT:LIM(?)`, `CURR:LIM(?)`,
  `OUTP(?)`, `MEAS:VOLT?|CURR?|POW?`, `*IDN?`, `SYST:VERS?`, `SYST:ERR?`
  — 전체 결과는 `docs/psu-api-report.md`
- 기기 기능: AC 인가 5초 후 저장된 설정으로 자동 출력 ON
  (스마트플러그 연동의 핵심 — remote-lab 태스크 참고)

## 아키텍처 (사용자가 확정한 설계 원칙)

**코어(프로토콜)와 UI를 반드시 분리 유지할 것.**

- `core/` — 순수 파이썬, OS 독립. pyserial 있으면 사용(Windows/macOS
  커버), 없으면 POSIX termios 폴백(의존성 제로). 포트에 배타 잠금.
- `omarchy-plugin/` — Omarchy 바 위젯(QML). `bin/psu`(bash 래퍼) →
  `core/psu_cli.py` 를 `Process`로 호출해 JSON만 받아 그린다.
  이 층만 리눅스/Omarchy 전용 (의도된 것).
- 다른 OS/UI에서는 core만 가져가면 된다. `python3 core/psu_cli.py ...`

## 주의사항 / 함정

- **파괴적 명령 금지**: `*RST`(설정 초기화), `*SAV`/`*RCL`(저장 슬롯
  덮어쓰기)은 쓰지 않는다. 기기에 로버용 세팅(13.8V/9.0A, 리밋
  14.2V/9.2A)이 들어 있다.
- **출력 ON은 실부하 주의**: 로버가 물려 있을 수 있다. `psu_test.py`는
  시작 시 출력이 ON이면 `--force` 없이 변경 테스트를 중단한다.
- **포트를 연 직후 첫 명령이 간헐적으로 무응답** — 코어의 query()에
  재시도 1회가 들어 있는 이유. 제거하지 말 것.
- **플러그인 폴더에 심볼릭 링크 금지** (omarchy validate가 거부) —
  그래서 `scripts/install-plugin.sh`가 복사 설치한다.
- 시스템 파이썬에 pip/pyserial 없음 — 코어의 termios 폴백으로 충분.

## 워크플로

```bash
./omarchy-plugin/bin/psu status            # CLI 동작 확인
python3 scripts/psu_test.py --report r.md  # API 전수 테스트 (비파괴)
./scripts/install-plugin.sh                # 플러그인 설치/갱신 (핫리로드)
journalctl --user | grep omarchy-shell     # QML 에러 확인
omarchy-shell shell toggle ted.psu         # 팝업 CLI로 여닫기
```

Omarchy 플러그인 개발 일반 지식(계약, 컴포넌트, 배포)은
`~/omarchy-setup/reference/omarchy-plugin-dev/` 가이드가 정본.

## TODO (README에도 있음)

1. 플러그인 ID `ted.psu` → `io.github.<깃헙아이디>.psu` 개명 —
   사용자의 깃헙 아이디 확인 필요 (이 머신 gh CLI 미인증). 바꿀 곳:
   manifest.json id / Widget.qml의 moduleName·IpcHandler target /
   install-plugin.sh dest. 개명 후 `omarchy plugin enable` 재실행.
   **공개 전에 확정해야 함** (공개 후 변경은 설치자 설정을 깬다).
2. 공유 시 omarchy-plugin/(+ core 번들)을 별도 repo로 추출 —
   manifest.json이 repo 루트에 오도록 (`omarchy plugin add` 요구사항).
3. 로버 거치 후 GUI에서 출력 ON 실사용 테스트.

## 사용자 규칙

- 커밋 메시지는 한국어, **Claude 시그니처(Co-Authored-By) 넣지 않는다.**
- 파괴적 기기 조작 전에 반드시 현재 설정 백업 → 작업 → 원상복구.
- 관련 프로젝트: `~/playground/random/remote-lab` (WoL, 스마트플러그,
  라즈베리파이 관제탑 등 전체 원격화 태스크 문서).
