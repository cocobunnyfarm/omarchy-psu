"""출력 자동 차단 타이머 — '켜둔 걸 잊어서 나는 사고'를 막는 안전장치.

정책만 담당한다. 기기 통신은 psu_core, 설정 저장은 psu_config에 맡긴다.

설계 (사용자와 합의):

- **설정과 상태를 다른 파일에 둔다.** 설정(enabled/default_sec)은
  config.json — 사용자가 정하는 값이라 프로필과 함께 커밋되어 백업된다.
  무장 상태(deadline)는 state.json — 초 단위로 바뀌는 런타임 값이라
  config.json에 넣으면 repo working tree가 항상 더러워진다.
- **집행 주체는 `psu status` 하나뿐이다.** 바 위젯이 팝업을 닫아둔 채로도
  refreshIntervalSec(기본 5초)마다 status를 부르므로 그 폴링이 곧 집행이다.
  omarchy-shell이 떠 있는 동안은 팝업/CLI와 무관하게 동작한다.
  (한계: 셸이 죽거나 로그아웃하면 그 시점부터 아무도 안 끈다 — 기기에
  자체 타이머 기능이 없어 완전 보장은 불가. 폴링으로 충분하다고 결정.)
- **무장은 '출력이 ON인 걸 관찰하면' 이루어진다.** psu on / GUI 토글뿐
  아니라 기기 전면 패널 조작, AC 인가 5초 후 자동 출력까지 전부 같은
  경로로 걸린다 — 켜는 경로마다 훅을 다는 것보다 빠뜨릴 구석이 없다.
  단, `timer.enabled`가 켜져 있을 때만.
- 출력이 꺼지면(누가 껐든) 타이머도 같이 내려간다.
"""
import time

import psu_config
from psu_core import PsuError

MIN_SEC = 60             # 무장 최소 (실수로 즉시 차단되는 걸 막는다)
MAX_SEC = 24 * 3600
DEFAULT_SEC = 1800       # 30분

_SETTING_DEFAULTS = {"enabled": False, "default_sec": DEFAULT_SEC}


def clamp_sec(sec):
    return max(MIN_SEC, min(MAX_SEC, int(sec)))


def settings(cfg):
    t = cfg.get("timer") or {}
    return {"enabled": bool(t.get("enabled", _SETTING_DEFAULTS["enabled"])),
            "default_sec": clamp_sec(t.get("default_sec",
                                           _SETTING_DEFAULTS["default_sec"]))}


def set_enabled(cfg, on):
    cfg.setdefault("timer", dict(_SETTING_DEFAULTS))["enabled"] = bool(on)
    if not on:
        disarm(cfg)
    psu_config.save(cfg)


def set_default(cfg, sec):
    cfg.setdefault("timer", dict(_SETTING_DEFAULTS))["default_sec"] = clamp_sec(sec)
    psu_config.save(cfg)


# ── 무장 상태 (state.json) ───────────────────────────────────────────

def _state(cfg):
    """현재 선택된 기기의 타이머 상태. 기기를 바꿨으면 이전 타이머는 무효."""
    st = psu_config.load_state()
    if st.get("device") != cfg.get("selected_device"):
        return {}
    return st


def deadline(cfg):
    return _state(cfg).get("deadline")


def arm(cfg, sec=None):
    """지금부터 sec 초 뒤로 무장 (sec 생략 시 기본 시간)."""
    sec = settings(cfg)["default_sec"] if sec is None else clamp_sec(sec)
    psu_config.save_state({"device": cfg.get("selected_device"),
                           "deadline": time.time() + sec,
                           "fired_at": None})
    return sec


def disarm(cfg, fired=False, suppress=False):
    """해제.

    fired=True  — 방금 타이머가 껐다는 표식 (UI 안내용).
    suppress=True — 사용자가 손으로 끈 것. 출력이 켜져 있는 동안은 자동
      재무장을 보류한다. 이게 없으면 '해제'를 눌러도 다음 폴링에서 곧바로
      다시 무장돼 버튼이 무의미해진다. 출력을 껐다 켜면 다시 걸린다.
    """
    psu_config.save_state({"device": cfg.get("selected_device"),
                           "deadline": None,
                           "fired_at": time.time() if fired else None,
                           "suppressed": bool(suppress)})


def extend(cfg, delta_sec):
    """남은 시간을 delta_sec 만큼 늘리거나(+) 줄인다(−).

    무장돼 있지 않으면 조정할 대상이 없다 — 호출부가 걸러야 한다.
    """
    d = deadline(cfg)
    if d is None:
        raise ValueError("무장된 타이머가 없습니다")
    return arm(cfg, max(0, d - time.time()) + delta_sec)


def snapshot(cfg):
    """UI/CLI 표시용 스냅샷. 기기 연결 없이도 읽을 수 있다."""
    s = settings(cfg)
    st = _state(cfg)
    d = st.get("deadline")
    return {"enabled": s["enabled"],
            "default_sec": s["default_sec"],
            "deadline": d,
            "remaining": max(0, int(round(d - time.time()))) if d else None,
            "fired_at": st.get("fired_at"),
            "suppressed": bool(st.get("suppressed"))}


# ── 집행 ─────────────────────────────────────────────────────────────

def sync(psu, cfg, output_on):
    """status 폴링마다 호출 — 자동 무장 / 만료 차단 / 자동 해제.

    반환: (스냅샷, 방금_껐는지, 에러문자열|None)
    차단 실패는 status 전체를 깨뜨리지 않고 에러로만 보고한다. deadline을
    남겨두므로 다음 폴링에서 자동 재시도된다.
    """
    s = settings(cfg)
    st = _state(cfg)
    d = st.get("deadline")
    dirty = d is not None or st.get("suppressed")
    fired = False
    err = None

    if not s["enabled"]:
        if dirty:
            disarm(cfg)                     # 설정을 끈 뒤 남아 있던 흔적 정리
    elif not output_on:
        if dirty:
            disarm(cfg)                     # 출력이 꺼지면 무장도 보류도 초기화
    elif d is None:
        if not st.get("suppressed"):        # 손으로 해제한 출력 세션은 존중
            arm(cfg)                        # 출력 ON 관찰 → 자동 무장
    elif time.time() >= d:
        try:
            psu.set_output(False)           # readback 검증 포함
            disarm(cfg, fired=True)
            fired = True
        except PsuError as e:
            err = f"타이머 만료 — 출력 차단 실패: {e}"

    return snapshot(cfg), fired, err


def describe(snap):
    """사람이 읽는 한 줄 요약 (CLI용)."""
    if not snap["enabled"]:
        return f"타이머: 사용 안 함 (기본 {snap['default_sec'] // 60}분)"
    head = f"타이머: 사용 (기본 {snap['default_sec'] // 60}분)"
    if snap["remaining"] is None:
        if snap.get("suppressed"):
            return head + " — 이번 출력 동안 해제됨 (껐다 켜면 다시 무장)"
        return head + " — 대기 중 (출력을 켜면 무장)"
    m, s = divmod(snap["remaining"], 60)
    at = time.strftime("%H:%M:%S", time.localtime(snap["deadline"]))
    return head + f" — {m}분 {s}초 남음 ({at} 차단 예정)"
