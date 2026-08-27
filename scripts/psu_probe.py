#!/usr/bin/env python3
"""전원공급기 프로토콜 탐색 — /dev/ttyUSB0 에 여러 방언으로 식별 명령을 보내본다.

pyserial 불필요 (표준 라이브러리 termios 사용).
사용: python3 psu_probe.py [포트] [보레이트]
"""
import os
import sys
import termios
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
BAUD = int(sys.argv[2]) if len(sys.argv) > 2 else 9600

BAUD_CONST = {9600: termios.B9600, 19200: termios.B19200,
              38400: termios.B38400, 57600: termios.B57600,
              115200: termios.B115200}

# (설명, 보낼 바이트) — 방언별 식별 명령
PROBES = [
    ("SCPI 표준 (*IDN? + LF)", b"*IDN?\n"),
    ("SCPI (CRLF)", b"*IDN?\r\n"),
    ("Korad류 (터미네이터 없음)", b"*IDN?"),
]


def open_port(port, baud):
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    # raw 모드, 8N1
    attrs[0] = 0                      # iflag
    attrs[1] = 0                      # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag
    attrs[3] = 0                      # lflag
    attrs[4] = BAUD_CONST[baud]       # ispeed
    attrs[5] = BAUD_CONST[baud]       # ospeed
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def read_reply(fd, wait=1.5):
    deadline = time.time() + wait
    buf = b""
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 256)
            if chunk:
                buf += chunk
                deadline = time.time() + 0.3  # 데이터가 오는 동안은 계속 수신
        except BlockingIOError:
            time.sleep(0.05)
    return buf


def main():
    print(f"포트: {PORT}, 보레이트: {BAUD}")
    fd = open_port(PORT, BAUD)
    try:
        for desc, cmd in PROBES:
            termios.tcflush(fd, termios.TCIOFLUSH)
            os.write(fd, cmd)
            reply = read_reply(fd)
            status = repr(reply) if reply else "(무응답)"
            print(f"  {desc:30s} -> {status}")
            if reply:
                print(f"\n✅ 응답 확인! 방언: {desc}")
                print(f"   기기 식별: {reply.decode(errors='replace').strip()}")
                return
            time.sleep(0.3)
        print("\n❌ 모든 방언 무응답. 다른 보레이트 시도:")
        print(f"   python3 {sys.argv[0]} {PORT} 115200")
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
