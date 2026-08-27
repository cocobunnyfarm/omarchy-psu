# omarchy-psu

OWON SPE 시리즈 벤치 전원공급기 제어 — Omarchy 바 위젯 + 이식 가능한
코어 CLI. (SPE3102 실기기에서 검증)

- 바 아이콘: 플러그(대기) / 번개+실측 전압(출력 중) / 꺼진 플러그(연결 안 됨)
- 클릭 팝업: 실측 V/A/W, 출력 토글, 전압/전류 스테퍼,
  **워크로드 프로필**(저장/적용/삭제), PSU 탐색/선택

## 설치 (Omarchy)

```bash
omarchy plugin add https://github.com/cocobunnyfarm/omarchy-psu.git --enable
```

요구사항: 시리얼 포트 권한 — `sudo usermod -aG uucp $USER` 후 재로그인.

## 구조 — 코어/UI 분리

```
manifest.json, Widget.qml   Omarchy 플러그인 (QML UI — 얇은 층)
bin/psu                     코어 위임 래퍼
core/                       이식 가능한 코어 (순수 파이썬, 의존성 없음)
  psu_core.py                 전송 추상화(pyserial↔POSIX termios) +
                              OWON SPE SCPI 드라이버 + 포트 배타 잠금
  psu_config.py               ~/.config/psu/config.json (기기 선택 + 프로필)
  psu_cli.py                  CLI
scripts/                    로컬 개발 설치, 프로토콜 탐색, API 전수 테스트
```

UI는 `psu` CLI의 JSON을 그리기만 한다. 다른 OS/디스트로에서는 `core/`만
가져다 쓰면 된다 (Windows/macOS는 pyserial 필요, 리눅스는 의존성 제로).

## CLI

```bash
psu() { ~/.config/omarchy/plugins/io.github.cocobunnyfarm.psu/bin/psu "$@"; }

psu list                   # 시리얼 포트 스캔 + *IDN? 프로브로 PSU 탐색
psu use 0                  # 선택 (by-id 안정 경로로 저장 — 재연결에도 유지)
psu status [--json]        # 상태 + 프로필 (GUI가 쓰는 것과 동일)
psu on / off / toggle      # 출력 (안전상 자동으로 켜지는 경우는 없음)
psu volt 13.8 / curr 9.0   # 설정 (readback 검증)
psu profile save ROVER --note "로버 13.8V 계통"   # 현재 설정을 프로필로
psu profile apply ROVER    # 적용 (출력 ON이면 거부, --force로 무시)
psu profile list / delete <이름>
psu raw 'MEAS:VOLT?'       # 임의 SCPI
```

**프로필은 PSU가 아니라 부하(로버 등)에 연동된 개념**이라 기기 내부 저장
슬롯 대신 `~/.config/psu/config.json`이 정본이다. 여러 PSU를 쓰면
`psu use`로 전환하고, 프로필은 공유된다.

## 파이썬 라이브러리로 쓰기

```python
from psu_core import OwonSPE

with OwonSPE("/dev/ttyUSB0") as psu:
    print(psu.status())
    psu.set_voltage(13.8)   # readback 검증, 실패 시 PsuError
    psu.set_output(True)
```

## 로컬 개발

```bash
./scripts/install-plugin.sh    # 플러그인 폴더로 복사 (저장 = 핫리로드)
python3 scripts/psu_test.py    # SCPI API 전수 테스트 (비파괴: 백업→검증→복구)
journalctl --user | grep omarchy-shell   # QML 디버깅
```
