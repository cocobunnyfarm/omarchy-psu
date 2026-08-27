#!/usr/bin/env python3
"""psu — OWON SPE 전원공급기 CLI (psu_core의 얇은 껍데기).

사용 예:
  psu status --json          # 전체 상태 (JSON) — GUI/스크립트용
  psu status                 # 사람이 읽는 형식
  psu on / off / toggle      # 출력 제어
  psu volt 13.8              # 전압 설정 (readback 검증 포함)
  psu curr 9.0               # 전류 제한 설정
  psu vlim 14.2 / clim 9.2   # 과전압/과전류 리밋
  psu idn                    # 기기 식별
  psu raw 'MEAS:VOLT?'       # 임의 SCPI (?로 끝나면 응답 출력)

포트: --port 또는 환경변수 PSU_PORT (기본 /dev/ttyUSB0)
종료 코드: 0 정상, 1 통신/검증 실패, 2 사용법 오류
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psu_core import DEFAULT_BAUD, DEFAULT_PORT, OwonSPE, PsuError  # noqa: E402


def human_status(s):
    out = "ON" if s["output"] else "OFF"
    st, m = s["set"], s["meas"]
    return (f"{s['idn']}\n"
            f"출력: {out}\n"
            f"설정: {st['volt']}V / {st['curr']}A  (리밋 {st['vlim']}V / {st['clim']}A)\n"
            f"실측: {m['volt']}V / {m['curr']}A / {m['pow']}W")


def main():
    p = argparse.ArgumentParser(prog="psu", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", default=DEFAULT_PORT)
    p.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    sub = p.add_subparsers(dest="cmd", required=True)

    st = sub.add_parser("status", help="전체 상태")
    st.add_argument("--json", action="store_true")
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
    want_json = getattr(args, "json", False)

    try:
        with OwonSPE(args.port, args.baud) as psu:
            if args.cmd == "status":
                s = psu.status()
                print(json.dumps(s, ensure_ascii=False) if want_json
                      else human_status(s))
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
