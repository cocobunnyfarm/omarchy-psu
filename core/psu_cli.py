#!/usr/bin/env python3
"""psu — OWON SPE 전원공급기 CLI (psu_core의 얇은 껍데기).

사용 예:
  psu status [--json]        # 전체 상태 (기기 + 프로필 포함)
  psu list [--json]          # 시스템에서 PSU 탐색 (*IDN? 프로브)
  psu use <번호|by-id이름>    # 사용할 PSU 선택 (config에 저장)
  psu on / off / toggle      # 출력 제어
  psu volt 13.8 / curr 9.0   # 설정 (readback 검증 포함)
  psu vlim 14.2 / clim 9.2   # 리밋
  psu profile list [--json]
  psu profile save ROVER [--volt V --curr A --vlim V --clim A] [--note ...]
                             # 값 생략 시 기기의 현재 설정을 읽어 저장
  psu profile apply ROVER    # 적용 (출력 ON이면 거부; --force로 무시)
  psu profile delete ROVER
  psu idn / psu raw 'MEAS:VOLT?'

포트 우선순위: --port > 선택된 기기(psu use) > 환경변수 PSU_PORT
설정 파일: ~/.config/psu/config.json
종료 코드: 0 정상, 1 통신/검증 실패, 2 사용법 오류
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import psu_config  # noqa: E402
from psu_core import (OwonSPE, PsuError, apply_profile, apply_values,  # noqa: E402
                      probe)


def open_psu(cfg, args):
    port, baud = psu_config.resolve_port(cfg, args.port)
    if args.baud:
        baud = args.baud
    return OwonSPE(port, baud), port


def device_info(cfg):
    sel = cfg.get("selected_device")
    entry = cfg.get("devices", {}).get(sel, {}) if sel else {}
    return {"id": sel, "alias": entry.get("alias"),
            "baud": entry.get("baud", 115200)}


def cmd_status(cfg, args):
    base = {"connected": False, "device": device_info(cfg),
            "profiles": cfg["profiles"], "last_profile": cfg["last_profile"]}
    port = None
    try:
        psu, port = open_psu(cfg, args)
        with psu:
            s = psu.status()
        base["device"]["path"] = port
        base.update(s)
    except PsuError as e:
        base["error"] = str(e)
    # active_profile: 기기의 현재 설정값이 마지막 적용 프로필과 일치할 때만.
    # 수동으로 하나라도 바꾸면 불일치 → null (= 자유 모드). 프로필이 저절로
    # 덮어써지는 경로는 없다 — 저장은 오직 명시적 `profile save <이름>` 뿐.
    base["active_profile"] = None
    lp = cfg.get("last_profile")
    prof = cfg["profiles"].get(lp) if lp else None
    if base["connected"] and prof:
        s = base["set"]
        if all(s.get(k) is not None and abs(s[k] - prof[k]) <= 0.02
               for k in ("volt", "curr", "vlim", "clim")):
            base["active_profile"] = lp
    if args.json:
        print(json.dumps(base, ensure_ascii=False))
    elif not base["connected"]:
        print(f"오류: {base['error']}", file=sys.stderr)
    else:
        st, m = base["set"], base["meas"]
        alias = base["device"]["alias"] or base["device"]["id"] or port
        print(f"{base['idn']}  [{alias}]\n"
              f"출력: {'ON' if base['output'] else 'OFF'}\n"
              f"설정: {st['volt']}V / {st['curr']}A  (리밋 {st['vlim']}V / {st['clim']}A)\n"
              f"실측: {m['volt']}V / {m['curr']}A / {m['pow']}W\n"
              f"프로필: {', '.join(base['profiles']) or '(없음)'}"
              + (f"  [마지막: {base['last_profile']}]" if base["last_profile"] else ""))
    return 0 if base["connected"] else 1


def discover(cfg):
    found = []
    for dev_id, path in psu_config.list_serial_ports():
        baud = cfg.get("devices", {}).get(dev_id, {}).get("baud", 115200)
        idn = probe(path, baud)
        if idn:
            found.append({"id": dev_id, "path": path, "idn": idn, "baud": baud,
                          "alias": cfg.get("devices", {}).get(dev_id, {}).get("alias"),
                          "selected": dev_id == cfg.get("selected_device")})
    return found


def cmd_list(cfg, args):
    found = discover(cfg)
    if args.json:
        print(json.dumps(found, ensure_ascii=False))
        return 0
    if not found:
        print("응답하는 PSU 없음 (연결/전원/권한 확인)")
        return 1
    for i, d in enumerate(found):
        mark = "»" if d["selected"] else " "
        alias = f" ({d['alias']})" if d["alias"] else ""
        print(f"{mark} [{i}] {d['idn']}{alias}\n      {d['id'] or d['path']}")
    return 0


def cmd_use(cfg, args):
    found = discover(cfg)
    target = None
    if args.device.isdigit() and int(args.device) < len(found):
        target = found[int(args.device)]
    else:
        for d in found:
            if d["id"] == args.device:
                target = d
    if not target:
        print(f"오류: '{args.device}' 를 찾지 못함 — psu list 로 확인", file=sys.stderr)
        return 1
    if not target["id"]:
        print("오류: by-id 이름이 없는 포트는 저장할 수 없음 (임시로 --port 사용)",
              file=sys.stderr)
        return 1
    cfg["selected_device"] = target["id"]
    entry = cfg["devices"].setdefault(target["id"], {})
    entry.setdefault("alias", target["idn"].split(",")[1]
                     if "," in target["idn"] else target["idn"])
    entry.setdefault("baud", target["baud"])
    psu_config.save(cfg)
    print(f"선택됨: {entry['alias']} ({target['id']})")
    return 0


def cmd_profile(cfg, args):
    if args.pcmd == "list":
        if args.json:
            print(json.dumps({"profiles": cfg["profiles"],
                              "last_profile": cfg["last_profile"]},
                             ensure_ascii=False))
        else:
            for name, p in cfg["profiles"].items():
                mark = "»" if name == cfg["last_profile"] else " "
                note = f"  — {p['note']}" if p.get("note") else ""
                print(f"{mark} {name}: {p['volt']}V/{p['curr']}A "
                      f"(리밋 {p['vlim']}V/{p['clim']}A){note}")
        return 0

    if args.pcmd == "delete":
        if cfg["profiles"].pop(args.name, None) is None:
            print(f"오류: 프로필 '{args.name}' 없음", file=sys.stderr)
            return 1
        if cfg["last_profile"] == args.name:
            cfg["last_profile"] = None
        psu_config.save(cfg)
        print(f"삭제됨: {args.name}")
        return 0

    if args.pcmd == "save":
        vals = {"volt": args.volt, "curr": args.curr,
                "vlim": args.vlim, "clim": args.clim}
        if any(v is None for v in vals.values()):
            psu, _ = open_psu(cfg, args)
            with psu:
                s = psu.status()["set"]
            for k in vals:
                if vals[k] is None:
                    vals[k] = s[k]
        p = {k: round(float(v), 2) for k, v in vals.items()}
        if args.note:
            p["note"] = args.note
        cfg["profiles"][args.name] = p
        cfg["last_profile"] = args.name
        psu_config.save(cfg)
        print(f"저장됨: {args.name} = {p['volt']}V/{p['curr']}A "
              f"(리밋 {p['vlim']}V/{p['clim']}A)")
        return 0

    if args.pcmd == "apply":
        p = cfg["profiles"].get(args.name)
        if p is None:
            print(f"오류: 프로필 '{args.name}' 없음", file=sys.stderr)
            return 1
        psu, _ = open_psu(cfg, args)
        with psu:
            apply_profile(psu, p, force=args.force)
        cfg["last_profile"] = args.name
        psu_config.save(cfg)
        print(f"적용됨: {args.name} = {p['volt']}V/{p['curr']}A "
              f"(리밋 {p['vlim']}V/{p['clim']}A) — 출력은 그대로")
        return 0
    return 2


def main():
    p = argparse.ArgumentParser(prog="psu", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", default=None)
    p.add_argument("--baud", type=int, default=None)
    sub = p.add_subparsers(dest="cmd", required=True)

    st = sub.add_parser("status", help="전체 상태 (기기+프로필 포함)")
    st.add_argument("--json", action="store_true")
    ls = sub.add_parser("list", help="PSU 탐색 (*IDN? 프로브)")
    ls.add_argument("--json", action="store_true")
    us = sub.add_parser("use", help="사용할 PSU 선택")
    us.add_argument("device", help="psu list 의 번호 또는 by-id 이름")

    pf = sub.add_parser("profile", help="워크로드 프로필 관리")
    pfsub = pf.add_subparsers(dest="pcmd", required=True)
    pl = pfsub.add_parser("list")
    pl.add_argument("--json", action="store_true")
    ps = pfsub.add_parser("save")
    ps.add_argument("name")
    for f in ("volt", "curr", "vlim", "clim"):
        ps.add_argument(f"--{f}", type=float, default=None)
    ps.add_argument("--note", default=None)
    pa = pfsub.add_parser("apply")
    pa.add_argument("name")
    pa.add_argument("--force", action="store_true",
                    help="출력 ON 상태에서도 적용")
    pd = pfsub.add_parser("delete")
    pd.add_argument("name")

    se = sub.add_parser("set", help="여러 값을 한 번의 연결로 적용 (안전 순서)")
    for f in ("volt", "curr", "vlim", "clim"):
        se.add_argument(f"--{f}", type=float, default=None)

    sub.add_parser("on", help="출력 ON")
    sub.add_parser("off", help="출력 OFF")
    sub.add_parser("toggle", help="출력 토글")
    sub.add_parser("idn", help="기기 식별")
    for name, hlp in [("volt", "전압 설정(V)"), ("curr", "전류 제한(A)"),
                      ("vlim", "전압 리밋(V)"), ("clim", "전류 리밋(A)")]:
        sp = sub.add_parser(name, help=hlp)
        sp.add_argument("value", type=float)
    rw = sub.add_parser("raw", help="임의 SCPI 명령")
    rw.add_argument("scpi")

    args = p.parse_args()
    cfg = psu_config.load()
    want_json = getattr(args, "json", False)

    try:
        if args.cmd == "status":
            sys.exit(cmd_status(cfg, args))
        if args.cmd == "list":
            sys.exit(cmd_list(cfg, args))
        if args.cmd == "use":
            sys.exit(cmd_use(cfg, args))
        if args.cmd == "profile":
            sys.exit(cmd_profile(cfg, args))

        psu, _ = open_psu(cfg, args)
        with psu:
            if args.cmd == "set":
                # 편집 버퍼 일괄 적용용: 지정 안 한 값은 현재 값 유지.
                # 라이브 튜닝이 목적이므로 출력 ON 여부는 확인하지 않는다
                # (명시적 '적용' 행동 자체가 의도 표현).
                given = {k: getattr(args, k) for k in ("volt", "curr", "vlim", "clim")}
                if all(v is None for v in given.values()):
                    print("오류: --volt/--curr/--vlim/--clim 중 하나 이상 필요",
                          file=sys.stderr)
                    sys.exit(2)
                cur = psu.status()["set"]
                target = {k: (given[k] if given[k] is not None else cur[k])
                          for k in given}
                apply_values(psu, target)
                print(f"적용됨: {target['volt']}V/{target['curr']}A "
                      f"(리밋 {target['vlim']}V/{target['clim']}A)")
            elif args.cmd == "on":
                psu.set_output(True)
                print("출력 ON")
            elif args.cmd == "off":
                psu.set_output(False)
                print("출력 OFF")
            elif args.cmd == "toggle":
                now = psu.set_output(not psu.output())
                print(f"출력 {'ON' if now else 'OFF'}")
            elif args.cmd == "idn":
                print(psu.idn())
            elif args.cmd == "volt":
                print(f"VOLT = {psu.set_voltage(args.value)}")
            elif args.cmd == "curr":
                print(f"CURR = {psu.set_current(args.value)}")
            elif args.cmd == "vlim":
                print(f"VOLT:LIM = {psu.set_voltage_limit(args.value)}")
            elif args.cmd == "clim":
                print(f"CURR:LIM = {psu.set_current_limit(args.value)}")
            elif args.cmd == "raw":
                if args.scpi.rstrip().endswith("?"):
                    print(psu.query(args.scpi))
                else:
                    psu.send(args.scpi)
    except PsuError as e:
        if want_json:
            print(json.dumps({"connected": False, "error": str(e)},
                             ensure_ascii=False))
        else:
            print(f"오류: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
