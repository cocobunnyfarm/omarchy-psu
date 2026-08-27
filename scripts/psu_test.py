#!/usr/bin/env python3
"""OWON SPE3102 전원공급기 SCPI API 전수 테스트.

원칙:
  1. 비파괴 — *RST, *SAV, 캘리브레이션 등 기기 상태를 영구 변경하는 명령 제외.
  2. 검증 — 모든 set 명령은 readback으로 실제 반영 여부를 확인.
  3. 원상복구 — 시작 시 현재 설정(전압/전류/리밋/출력상태)을 백업하고 끝나면 복구.
  4. 안전 — 시작 시 출력이 ON이면(부하가 물려 있을 수 있음) --force 없이는
     변경 테스트를 중단. 변경 테스트는 저전압(≤2.5V)/저전류(0.1A)로만 수행.

사용: python3 psu_test.py [--force] [--port /dev/ttyUSB0]
pyserial 불필요 (표준 라이브러리 termios 사용).
"""
import argparse
import os
import sys
import termios
import time


class PSU:
    """termios 기반 SCPI 시리얼 클라이언트 (115200 8N1, LF 종결)."""

    def __init__(self, port, baud=termios.B115200):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        a = termios.tcgetattr(self.fd)
        a[0] = 0
        a[1] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] = 0
        a[4] = baud
        a[5] = baud
        termios.tcsetattr(self.fd, termios.TCSANOW, a)
        termios.tcflush(self.fd, termios.TCIOFLUSH)

    def close(self):
        os.close(self.fd)

    def send(self, cmd):
        """명령 전송 (응답 안 기다림)."""
        termios.tcflush(self.fd, termios.TCIFLUSH)
        os.write(self.fd, cmd.encode() + b"\n")
        time.sleep(0.15)  # 기기 처리 시간

    def query(self, cmd, wait=1.0):
        """질의 전송 후 응답 반환. 무응답이면 None."""
        termios.tcflush(self.fd, termios.TCIFLUSH)
        os.write(self.fd, cmd.encode() + b"\n")
        deadline = time.time() + wait
        buf = b""
        while time.time() < deadline:
            try:
                chunk = os.read(self.fd, 256)
                if chunk:
                    buf += chunk
                    if buf.endswith(b"\n"):
                        break
                    deadline = time.time() + 0.3
            except BlockingIOError:
                time.sleep(0.02)
        return buf.decode(errors="replace").strip() or None


class Report:
    def __init__(self):
        self.rows = []  # (명령, 결과, 증거)

    def add(self, cmd, ok, evidence):
        mark = {"ok": "✅", "fail": "❌", "skip": "⏭️ ", "info": "ℹ️ "}[ok]
        self.rows.append((cmd, mark, evidence))
        print(f"  {mark} {cmd:24s} {evidence}")

    def to_markdown(self, header_lines):
        out = ["# OWON SPE3102 SCPI API 테스트 결과", ""]
        out += header_lines + ["", "| 명령 | 결과 | 증거 |", "|---|---|---|"]
        for cmd, mark, ev in self.rows:
            out.append(f"| `{cmd}` | {mark} | {ev} |")
        return "\n".join(out) + "\n"


def fnum(s):
    """응답 문자열에서 숫자 파싱. 실패 시 None."""
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def approx(a, b, tol=0.02):
    return a is not None and b is not None and abs(a - b) <= tol


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--force", action="store_true",
                    help="출력이 ON 상태여도 변경 테스트 진행 (부하 없음 확인 후 사용)")
    ap.add_argument("--report", default=None, help="마크다운 리포트 저장 경로")
    args = ap.parse_args()

    psu = PSU(args.port)
    rpt = Report()
    print(f"포트 {args.port} @115200\n")

    # ── 1. 식별/시스템 질의 (읽기 전용, 항상 안전) ─────────────────────
    print("[1] 식별/시스템 질의")
    idn = psu.query("*IDN?")
    rpt.add("*IDN?", "ok" if idn else "fail", idn or "무응답")
    if not idn or "SPE" not in idn:
        print("\n⚠️ 기기 식별 실패 — 중단")
        sys.exit(1)

    for cmd in ["SYST:VERS?", "SYST:ERR?", "*OPC?"]:
        r = psu.query(cmd)
        rpt.add(cmd, "ok" if r else "fail", r or "무응답")

    # ── 2. 현재 상태 백업 (읽기 질의 테스트를 겸함) ────────────────────
    print("\n[2] 현재 상태 읽기 + 백업")
    state = {}
    for key, cmd in [("volt", "VOLT?"), ("curr", "CURR?"),
                     ("vlim", "VOLT:LIM?"), ("clim", "CURR:LIM?"),
                     ("outp", "OUTP?")]:
        r = psu.query(cmd)
        state[key] = r
        rpt.add(cmd, "ok" if r else "fail", r or "무응답")

    print("\n[3] 측정 질의")
    for cmd in ["MEAS:VOLT?", "MEAS:CURR?", "MEAS:POW?"]:
        r = psu.query(cmd)
        rpt.add(cmd, "ok" if fnum(r) is not None else "fail", r or "무응답")

    # ── 4. 출력 상태 확인 — 안전 게이트 ─────────────────────────────────
    outp_on = state["outp"] in ("1", "ON")
    if outp_on and not args.force:
        print("\n⚠️ 출력이 ON 상태 — 부하(로버?)가 물려 있을 수 있어 변경 테스트 중단.")
        print("   부하가 없거나 안전하면 --force 로 재실행하세요.")
        finish(psu, rpt, args, idn, restored=False)
        return

    # ── 5. 변경 테스트 (set → readback 검증) ───────────────────────────
    print("\n[4] 출력 OFF 확보 후 설정값 쓰기/검증")
    psu.send("OUTP OFF")
    r = psu.query("OUTP?")
    rpt.add("OUTP OFF", "ok" if r in ("0", "OFF") else "fail", f"OUTP? → {r}")

    try:
        # 전압 설정 (두 값으로 실제 변화 확인)
        for v in (1.00, 2.50):
            psu.send(f"VOLT {v:.2f}")
            rb = fnum(psu.query("VOLT?"))
            rpt.add(f"VOLT {v:.2f}", "ok" if approx(rb, v) else "fail",
                    f"VOLT? → {rb}")

        # 전류 설정
        for c in (0.10, 0.50):
            psu.send(f"CURR {c:.2f}")
            rb = fnum(psu.query("CURR?"))
            rpt.add(f"CURR {c:.2f}", "ok" if approx(rb, c) else "fail",
                    f"CURR? → {rb}")

        # 리밋 설정 (현재 리밋보다 낮되 테스트 설정값보다 높은 값 → 복구)
        vlim0, clim0 = fnum(state["vlim"]), fnum(state["clim"])
        if vlim0 and vlim0 > 5.0:
            psu.send("VOLT:LIM 5.00")
            rb = fnum(psu.query("VOLT:LIM?"))
            rpt.add("VOLT:LIM 5.00", "ok" if approx(rb, 5.0) else "fail",
                    f"VOLT:LIM? → {rb}")
        else:
            rpt.add("VOLT:LIM", "skip", f"현재 리밋({state['vlim']})이 낮아 생략")
        if clim0 and clim0 > 1.0:
            psu.send("CURR:LIM 1.00")
            rb = fnum(psu.query("CURR:LIM?"))
            rpt.add("CURR:LIM 1.00", "ok" if approx(rb, 1.0) else "fail",
                    f"CURR:LIM? → {rb}")
        else:
            rpt.add("CURR:LIM", "skip", f"현재 리밋({state['clim']})이 낮아 생략")

        # 출력 ON — 1V/0.1A 저전압 상태에서. 무부하여도 MEAS:VOLT는 설정값 근처.
        print("\n[5] 출력 ON 실측 검증 (1.00V / 0.10A)")
        psu.send("VOLT 1.00")
        psu.send("CURR 0.10")
        psu.send("OUTP ON")
        time.sleep(0.6)
        r = psu.query("OUTP?")
        mv = fnum(psu.query("MEAS:VOLT?"))
        mc = fnum(psu.query("MEAS:CURR?"))
        rpt.add("OUTP ON", "ok" if r in ("1", "ON") else "fail", f"OUTP? → {r}")
        rpt.add("MEAS:VOLT? (ON)", "ok" if approx(mv, 1.0, 0.05) else "fail",
                f"실측 {mv}V (설정 1.00V)")
        rpt.add("MEAS:CURR? (ON)", "info", f"실측 {mc}A (무부하면 ~0)")
        psu.send("OUTP OFF")

    finally:
        # ── 6. 원상복구 (리밋 먼저, 그 다음 설정값, 마지막 출력상태) ──
        print("\n[6] 원상복구")
        if fnum(state["vlim"]) is not None:
            psu.send(f"VOLT:LIM {fnum(state['vlim']):.2f}")
        if fnum(state["clim"]) is not None:
            psu.send(f"CURR:LIM {fnum(state['clim']):.2f}")
        if fnum(state["volt"]) is not None:
            psu.send(f"VOLT {fnum(state['volt']):.2f}")
        if fnum(state["curr"]) is not None:
            psu.send(f"CURR {fnum(state['curr']):.2f}")
        psu.send("OUTP ON" if outp_on else "OUTP OFF")

        ok = (approx(fnum(psu.query("VOLT?")), fnum(state["volt"])) and
              approx(fnum(psu.query("CURR?")), fnum(state["curr"])))
        rpt.add("원상복구", "ok" if ok else "fail",
                f"VOLT {state['volt']}, CURR {state['curr']}, "
                f"LIM {state['vlim']}/{state['clim']}, OUTP {state['outp']}")

    finish(psu, rpt, args, idn, restored=True)


def finish(psu, rpt, args, idn, restored):
    # 참고: 비파괴 원칙으로 제외한 명령들
    for cmd, why in [("*RST", "설정 초기화 — 파괴적"),
                     ("*SAV/*RCL", "저장 슬롯 덮어쓰기 — 파괴적"),
                     ("SYST:REM/LOC", "전면 패널 잠금 — 테스트 불필요")]:
        rpt.add(cmd, "skip", why)
    psu.close()
    if args.report:
        header = [f"- 기기: `{idn}`",
                  f"- 포트: `{args.port}` @115200, SCPI(LF 종결)",
                  f"- 원상복구: {'수행됨' if restored else '변경 없음(출력 ON으로 중단)'}"]
        with open(args.report, "w") as f:
            f.write(rpt.to_markdown(header))
        print(f"\n리포트 저장: {args.report}")


if __name__ == "__main__":
    main()
