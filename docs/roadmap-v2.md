# v2 로드맵 — 기기 선택 + 워크로드 프로필 (2026-08-27 사용자와 합의)

## 결정사항

1. **리포 이름/구조**: GitHub repo `omarchy-psu` 로 생성 예정.
   manifest.json/Widget.qml 을 repo 루트로 올리고 core/, scripts/, docs/ 를
   안에 두는 구조로 재편 → 리포 하나로 개발+배포 (`omarchy plugin add`
   요구사항 = manifest가 루트. world-clock 방식). 플러그인 ID는
   `io.github.<깃헙아이디>.psu` (아이디 확인 대기 중).
2. **기기 탐색/선택**: `psu list` 가 시리얼 포트 스캔 + *IDN? 프로브로
   PSU 목록 제공. 선택은 `/dev/ttyUSBn` 이 아니라 **`/dev/serial/by-id/`
   안정 경로**로 저장 (ttyUSB 번호는 연결 순서에 따라 바뀜).
   UX: 팝업 메인 = 선택된 PSU 전용, 기기 선택은 별도 뷰/섹션.
3. **워크로드 프로필**: JSON (DB는 오버). **코어가 소유** —
   `~/.config/psu-control/config.json` 에 기기 선택 + 프로필 통합.
   CLI: `psu list` / `psu use <id>` / `psu profile save|apply|list`.
   GUI는 CLI를 부르는 버튼일 뿐 → 다른 OS에서도 프로필 재사용.
4. **프로필 적용 순서**: 리밋 먼저 → 전압/전류 → 출력은 자동으로 켜지
   않음 (안전: 출력 ON은 항상 명시적 행동).
5. **PSU 내부 저장 슬롯(*SAV/*RCL)**: 직접 읽기 불가 (recall로 현재
   설정을 덮어야만 읽힘) + 이름 못 붙임 → 무시하고 JSON 프로필이 정본.
   옵션: 1회성 임포트 명령 `psu profile import-device`
   (백업→슬롯별 *RCL→읽기→복구).

## config.json 구조 (합의안)

```json
{
  "version": 1,
  "selected_device": "usb-1a86_USB_Serial-if00-port0",
  "devices": {
    "usb-1a86_USB_Serial-if00-port0": { "alias": "책상 SPE3102", "baud": 115200 }
  },
  "profiles": {
    "ROVER": { "volt": 13.8, "curr": 9.0, "vlim": 14.2, "clim": 9.2, "note": "로버 13.8V 계통" }
  },
  "last_profile": "ROVER"
}
```

## 구현 순서 (✅ 2026-08-27 전부 완료 — v0.2.0)

- [x] repo 재편 (manifest 루트로) + ID 개명 — 깃헙 repo `omarchy-psu` 생성 후
- [x] 코어: config.json 로드/저장, `psu list`(by-id 스캔+프로브), `psu use`
- [x] 코어: `psu profile save/apply/list` (+ status --json에 프로필 정보 포함)
- [x] 위젯: 프로필 목록(클릭 적용/× 삭제/저장 입력), 기기 검색/전환 뷰
- [ ] 수동 GUI 테스트 (로버 분리 상태에서 토글/스테퍼)
