"""설정 파일 관리 — 기기 선택 + 워크로드 프로필.

~/.config/psu/config.json 하나에 담는다 (코어 소유 — CLI/GUI가 공유,
다른 OS에서도 그대로). 프로필은 PSU가 아니라 '전원을 줄 대상'(로버 등)에
연동된 개념이므로 기기 내부 저장 슬롯 대신 여기가 정본이다.

구조:
{
  "version": 1,
  "selected_device": "<by-id 이름>",       # 현재 선택된 기기
  "devices": { "<by-id>": {"alias": "...", "baud": 115200} },  # 알려진 기기 전체
  "profiles": { "ROVER": {"volt":13.8,"curr":9.0,"vlim":14.2,"clim":9.2,"note":"..."} },
  "last_profile": "ROVER"                   # 마지막으로 적용/저장한 프로필
}
"""
import json
import os

CONFIG_DIR = os.environ.get(
    "PSU_CONFIG_DIR",
    os.path.join(os.environ.get("XDG_CONFIG_HOME",
                                os.path.expanduser("~/.config")), "psu"))
CONFIG_PATH = os.path.join(CONFIG_DIR, "config.json")

BY_ID_DIR = "/dev/serial/by-id"

_DEFAULTS = {
    "version": 1,
    "selected_device": None,
    "devices": {},
    "profiles": {},
    "last_profile": None,
}


def load():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        cfg = {}
    merged = dict(_DEFAULTS)
    merged.update(cfg)
    return merged


def save(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, CONFIG_PATH)


def device_path(device_id):
    """by-id 이름 → 실제 포트 경로."""
    return os.path.join(BY_ID_DIR, device_id)


def resolve_port(cfg, override=None):
    """포트 결정 우선순위: --port > 선택된 기기(by-id) > PSU_PORT 환경변수.

    반환: (포트경로, 보레이트)
    """
    if override:
        return override, 115200
    sel = cfg.get("selected_device")
    if sel:
        path = device_path(sel)
        if os.path.exists(path):
            baud = cfg.get("devices", {}).get(sel, {}).get("baud", 115200)
            return path, baud
    return os.environ.get("PSU_PORT", "/dev/ttyUSB0"), 115200


def list_serial_ports():
    """탐색 후보 포트 목록: [(by-id 이름 또는 None, 경로), ...].

    /dev/serial/by-id/ 가 정석 (연결 순서와 무관한 안정 이름).
    by-id 디렉토리가 없으면 ttyUSB*/ttyACM* 폴백.
    """
    ports = []
    if os.path.isdir(BY_ID_DIR):
        for name in sorted(os.listdir(BY_ID_DIR)):
            ports.append((name, os.path.join(BY_ID_DIR, name)))
    else:
        import glob
        for path in sorted(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*")):
            ports.append((None, path))
    return ports
