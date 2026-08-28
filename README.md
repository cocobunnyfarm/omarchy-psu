# omarchy-psu

OWON SPE 시리즈 벤치 전원공급기 제어 — Omarchy 바 위젯 + 이식 가능한
코어 CLI. (SPE3102 실기기에서 검증)

- 바 아이콘: 플러그(대기) / 번개+실측 전압(출력 중) / 꺼진 플러그(연결 안 됨)
- 클릭 팝업 (뷰 4개):
  - **메인**: 실측 V/A/W, 출력 토글, 전압/전류/리밋 스테퍼 —
    스테퍼는 로컬 편집 버퍼라 통신 없이 조절하고 `적용` 한 번에 일괄 전송
  - **프로필 관리**: 워크로드별(로버 등) 설정 저장/적용/삭제(2단계 확인),
    기기 값과 일치하는 프로필 자동 표시 — 튜닝하면 "자유 모드"
  - **새 프로필**: 드래프트 편집(기기 무영향) + 기기 범위 힌트/클램프
  - **기기 변경**: *IDN? 프로브 탐색, by-id 안정 경로로 저장
  - **타이머**: 출력 자동 차단 — 켜두고 잊는 사고 방지. 사용 여부/기본
    시간 설정, 무장 중 남은 시간은 메인에 표시되고 +5분·해제로 조절
- 안전장치: 적용은 상식 검증 → 기기 범위 사전 검증 → readback 검증,
  중간 실패 시 이전 설정 롤백. 출력이 저절로 켜지는 경로 없음

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
  psu_config.py               ~/.config/psu/config.json (기기 선택 + 프로필
                              + 타이머 설정) / state.json (무장 상태)
  psu_timer.py                출력 자동 차단 타이머 정책
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
psu set --volt 5 --curr 1  # 여러 값을 한 번의 연결로 일괄 적용 (GUI '적용'이 사용)
psu timer                  # 타이머 상태
psu timer enable / disable # 사용 여부 (기본: 사용 안 함)
psu timer default 30       # 기본 차단 시간(분)
psu timer extend 5 / disarm # 무장 중 조절 / 이번 출력 동안 해제
psu raw 'VOLT? MAX'        # 임의 SCPI (기기 한계 질의 등)
```

## 출력 자동 차단 타이머

켜둔 걸 잊어서 나는 사고를 막는 안전장치다. `psu timer enable` 로 켜두면
**출력이 ON인 것이 관찰될 때마다** 기본 시간짜리 타이머가 자동으로 걸린다 —
`psu on`/GUI 토글뿐 아니라 기기 전면 패널 조작이나 스마트플러그 AC 인가 후
자동 출력까지 같은 경로로 커버된다. 출력을 끄면 타이머도 함께 내려간다.

집행은 바 위젯이 주기적으로 부르는 `psu status` 안에서 이뤄진다. 팝업을
닫아둬도, 셸을 재시작해도(무장 시각이 state.json 에 남으므로) 동작한다.
**한계: omarchy-shell 이 떠 있지 않으면 아무도 끄지 않는다** — 기기에 자체
타이머 기능이 없어 완전 보장은 불가능하다.

설정(`enabled`/`default_sec`)은 config.json, 무장 상태(deadline)는 초 단위로
바뀌므로 state.json 에 따로 둔다 (config/ 를 심볼릭 링크로 쓸 때 working
tree가 계속 더러워지는 걸 피하려고).

**프로필은 PSU가 아니라 부하(로버 등)에 연동된 개념**이라 기기 내부 저장
슬롯 대신 `~/.config/psu/config.json`이 정본이다. 여러 PSU를 쓰면
`psu use`로 전환하고, 프로필은 공유된다. (이 저장소에서는 `~/.config/psu`가
repo의 `config/`로 심볼릭 링크돼 있어 프로필 커밋 = 백업.)

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
