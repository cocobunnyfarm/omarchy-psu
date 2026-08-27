# psu-control

OWON SPE 시리즈 벤치 전원공급기(SPE3102에서 검증) 원격 제어.
**코어(프로토콜)와 UI(오마치 플러그인)를 분리**한 구조로, 코어는 어떤
OS/디스트로에서도 재사용할 수 있다.

```
core/                  이식 가능한 코어 — 순수 파이썬, 외부 의존성 없음
  psu_core.py            라이브러리: 전송 추상화(pyserial↔POSIX termios),
                          OWON SPE SCPI 드라이버, 포트 배타 잠금
  psu_cli.py             CLI: psu status --json / on / off / toggle /
                          volt / curr / vlim / clim / idn / raw
omarchy-plugin/        Omarchy 바 위젯 — 얇은 UI 층 (psu CLI의 JSON을 그림)
  manifest.json          플러그인 선언 (id, kinds, 진입점, 설정 스키마)
  Widget.qml             바 아이콘 + 제어 팝업 (QML)
  bin/psu                코어 위임 래퍼
scripts/
  install-plugin.sh      ~/.config/omarchy/plugins/ 로 복사 설치
  psu_probe.py           프로토콜/보레이트 탐색 (새 기기 물릴 때)
  psu_test.py            SCPI API 전수 테스트 (비파괴: 백업→검증→복구)
docs/
  psu-api-report.md      SPE3102 전수 테스트 결과
```

## 사용

```bash
# CLI (어디서든)
./omarchy-plugin/bin/psu status
./omarchy-plugin/bin/psu status --json     # GUI/스크립트용
./omarchy-plugin/bin/psu volt 13.8         # readback 검증 포함
PSU_PORT=/dev/ttyUSB0                       # 포트는 --port 또는 환경변수

# 오마치 플러그인 설치 (수정 후에도 이걸로 갱신 — 핫리로드됨)
./scripts/install-plugin.sh
omarchy plugin enable ted.psu
```

기기 연결: USB(CH340, 115200 8N1), 표준 SCPI(LF 종결). 포트 권한은
uucp 그룹 (`sudo usermod -aG uucp $USER` 후 재로그인).

## 파이썬 라이브러리로 쓰기

```python
from psu_core import OwonSPE

with OwonSPE("/dev/ttyUSB0") as psu:
    print(psu.status())
    psu.set_voltage(13.8)   # readback 검증, 실패 시 PsuError
    psu.set_output(True)
```

## TODO

- [ ] 플러그인 ID를 공개용으로 변경: `ted.psu` → `io.github.<깃헙아이디>.psu`
      (manifest.json의 id, Widget.qml의 moduleName/IpcHandler target,
      install-plugin.sh의 dest 세 곳 + `omarchy plugin enable` 재실행)
- [ ] 공유 시 omarchy-plugin/ + 번들 core를 별도 repo로 분리
      (manifest.json이 repo 루트에 오도록; 설치는 `omarchy plugin add <git-url>`)
- [ ] 로버 부하 상태에서 GUI 출력 ON 실사용 테스트
