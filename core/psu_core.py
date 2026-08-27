"""OWON SPE 시리즈 전원공급기 제어 코어 라이브러리.

UI(오마치 플러그인, 원격 스크립트 등)와 분리된 순수 프로토콜 계층.

이식성:
- pyserial이 설치되어 있으면 사용 → Windows/macOS/Linux 전부 커버
- 없으면 POSIX termios 폴백 → 리눅스/맥에서 의존성 제로로 동작

동시 접근:
- 시리얼 포트는 한 번에 한 프로세스만 열도록 잠금 (termios: flock,
  pyserial: exclusive). 바 위젯 폴링과 수동 스크립트가 겹쳐도 안전.
"""
import os
import time

DEFAULT_PORT = os.environ.get("PSU_PORT", "/dev/ttyUSB0")
DEFAULT_BAUD = 115200

try:
    import serial as _pyserial
except ImportError:
    _pyserial = None


class PsuError(Exception):
    """통신 실패."""


class PortBusy(PsuError):
    """포트를 다른 프로세스가 잠금 — 일시적, 재시도 가치 있음."""


class _PySerialTransport:
    def __init__(self, port, baud):
        kwargs = {"timeout": 0}
        if os.name == "posix":
            kwargs["exclusive"] = True
        try:
            self._s = _pyserial.Serial(port, baud, **kwargs)
        except Exception as e:
            msg = str(e)
            if "busy" in msg.lower() or "exclusive" in msg.lower():
                raise PortBusy(f"{port} 사용 중 (다른 프로세스가 잠금)") from e
            raise PsuError(msg) from e

    def write(self, data):
        self._s.write(data)

    def read_available(self):
        return self._s.read(256)

    def flush_input(self):
        self._s.reset_input_buffer()

    def close(self):
        self._s.close()


class _TermiosTransport:
    def __init__(self, port, baud):
        import fcntl
        import termios
        self._termios = termios
        bauds = {9600: termios.B9600, 19200: termios.B19200,
                 38400: termios.B38400, 57600: termios.B57600,
                 115200: termios.B115200}
        if baud not in bauds:
            raise PsuError(f"지원하지 않는 보레이트: {baud}")
        try:
            self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        except OSError as e:
            raise PsuError(f"{port} 열기 실패: {e}") from e
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.fd)
            raise PortBusy(f"{port} 사용 중 (다른 프로세스가 잠금)") from None
        a = termios.tcgetattr(self.fd)
        a[0] = 0
        a[1] = 0
        a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        a[3] = 0
        a[4] = bauds[baud]
        a[5] = bauds[baud]
        termios.tcsetattr(self.fd, termios.TCSANOW, a)

    def write(self, data):
        os.write(self.fd, data)

    def read_available(self):
        try:
            return os.read(self.fd, 256)
        except BlockingIOError:
            return b""

    def flush_input(self):
        self._termios.tcflush(self.fd, self._termios.TCIFLUSH)

    def close(self):
        os.close(self.fd)


def open_transport(port, baud, wait_lock=2.0):
    """포트 열기. 다른 프로세스가 잠근 상태(폴링과 수동 명령의 순간 경합)면
    wait_lock 초까지 재시도 — 경합은 항상 1초 미만이라 사용자에게 잠금
    에러가 노출되는 일을 없앤다."""
    deadline = time.time() + wait_lock
    while True:
        try:
            if _pyserial is not None:
                return _PySerialTransport(port, baud)
            if os.name != "posix":
                raise PsuError("pyserial이 필요합니다: pip install pyserial")
            return _TermiosTransport(port, baud)
        except PortBusy:
            if time.time() >= deadline:
                raise
            time.sleep(0.15)


class OwonSPE:
    """OWON SPE 시리즈 SCPI 드라이버 (SPE3102에서 전수 검증됨).

    검증된 명령: *IDN?, VOLT(?), CURR(?), VOLT:LIM(?), CURR:LIM(?),
    OUTP(?), MEAS:VOLT?, MEAS:CURR?, MEAS:POW?, SYST:VERS?, SYST:ERR?
    """

    def __init__(self, port=DEFAULT_PORT, baud=DEFAULT_BAUD):
        self.t = open_transport(port, baud)

    def close(self):
        self.t.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # ── 저수준 ────────────────────────────────────────────────────────
    def send(self, cmd):
        self.t.flush_input()
        self.t.write(cmd.encode() + b"\n")
        time.sleep(0.15)  # 기기 처리 시간

    def query(self, cmd, wait=0.8, retries=1):
        # 포트를 처음 연 직후 첫 명령이 간헐적으로 무응답 → 재시도로 흡수
        for _ in range(retries + 1):
            self.t.flush_input()
            self.t.write(cmd.encode() + b"\n")
            deadline = time.time() + wait
            buf = b""
            while time.time() < deadline:
                chunk = self.t.read_available()
                if chunk:
                    buf += chunk
                    if buf.endswith(b"\n"):
                        break
                    deadline = time.time() + 0.3
                else:
                    time.sleep(0.02)
            if buf:
                return buf.decode(errors="replace").strip()
        return None

    def _qf(self, cmd):
        r = self.query(cmd)
        try:
            return float(r)
        except (TypeError, ValueError):
            return None

    def _set_verified(self, cmd, value, readback):
        self.send(f"{cmd} {value:.2f}")
        rb = self._qf(readback)
        if rb is None or abs(rb - value) > 0.02:
            raise PsuError(f"{cmd} {value:.2f} 반영 실패 (readback: {rb})")
        return rb

    # ── 공개 API ─────────────────────────────────────────────────────
    def idn(self):
        r = self.query("*IDN?")
        if r is None:
            raise PsuError("기기 무응답 (*IDN?)")
        return r

    def output(self):
        return self.query("OUTP?") in ("1", "ON")

    def set_output(self, on):
        self.send("OUTP ON" if on else "OUTP OFF")
        actual = self.output()
        if actual != bool(on):
            raise PsuError(f"출력 {'ON' if on else 'OFF'} 반영 실패")
        return actual

    def set_voltage(self, v):
        return self._set_verified("VOLT", v, "VOLT?")

    def set_current(self, a):
        return self._set_verified("CURR", a, "CURR?")

    def set_voltage_limit(self, v):
        return self._set_verified("VOLT:LIM", v, "VOLT:LIM?")

    def set_current_limit(self, a):
        return self._set_verified("CURR:LIM", a, "CURR:LIM?")

    def status(self):
        """전체 스냅샷. 첫 질의(idn)에 재시도가 걸려 있어 연결 검증을 겸함."""
        return {
            "connected": True,
            "idn": self.idn(),
            "output": self.output(),
            "set": {
                "volt": self._qf("VOLT?"),
                "curr": self._qf("CURR?"),
                "vlim": self._qf("VOLT:LIM?"),
                "clim": self._qf("CURR:LIM?"),
            },
            "meas": {
                "volt": self._qf("MEAS:VOLT?"),
                "curr": self._qf("MEAS:CURR?"),
                "pow": self._qf("MEAS:POW?"),
            },
        }


def probe(port, baud=DEFAULT_BAUD, wait=0.6):
    """포트에 *IDN? 프로브를 보내 PSU인지 판별. 응답 문자열 또는 None.

    포트 이름이 아니라 '식별 명령에 응답하는가'로 기기를 찾는다.
    (다른 시리얼 기기에는 무해한 텍스트 한 줄일 뿐이다.)
    """
    try:
        psu = OwonSPE(port, baud)
    except PsuError:
        return None
    try:
        return psu.query("*IDN?", wait=wait, retries=1)
    finally:
        psu.close()


def validate_profile(p):
    """상식 검증 (기기 접속 불필요): 숫자·음수·리밋 관계.

    UI가 막더라도 코어가 최종 방어선 — CLI 직접 사용/외부 호출 모두 커버.
    """
    for k in ("volt", "curr", "vlim", "clim"):
        v = p.get(k)
        if not isinstance(v, (int, float)) or v != v or v < 0:
            raise PsuError(f"프로필 값 오류: {k}={v!r}")
    if p["volt"] > p["vlim"] + 0.001:
        raise PsuError(f"전압({p['volt']}V)이 전압 리밋({p['vlim']}V)보다 큼")
    if p["curr"] > p["clim"] + 0.001:
        raise PsuError(f"전류({p['curr']}A)가 전류 리밋({p['clim']}A)보다 큼")


def _apply_sequence(psu, p):
    """리밋·설정값 상호 제약을 피하는 순서로 적용. 각 단계는 readback
    검증(_set_verified)이라 기기가 거부/클램프하면 즉시 PsuError."""
    cur_vlim = psu._qf("VOLT:LIM?") or float("inf")
    cur_clim = psu._qf("CURR:LIM?") or float("inf")
    if p["volt"] <= cur_vlim:
        psu.set_voltage(p["volt"])
    if p["curr"] <= cur_clim:
        psu.set_current(p["curr"])
    psu.set_voltage_limit(p["vlim"])
    psu.set_current_limit(p["clim"])
    psu.set_voltage(p["volt"])
    psu.set_current(p["curr"])


def apply_values(psu, p):
    """volt/curr/vlim/clim 적용 — 3단 방어:

    1) 사전 상식 검증 (validate_profile)
    2) 단계별 readback 검증 — 기기 지원 범위 밖 값은 기기가 거부/클램프
       하므로 readback 불일치로 잡힌다 (이게 '반드시 되는지 테스트')
    3) 중간 실패 시 이전 설정으로 롤백 시도 — 반쯤 적용된 상태로
       남겨두지 않는다
    출력은 절대 건드리지 않는다.
    """
    validate_profile(p)
    psu.idn()  # 연결 게이트 — 기기 무응답이면 여기서 명확한 에러로 종료
    backup = {"volt": psu._qf("VOLT?"), "curr": psu._qf("CURR?"),
              "vlim": psu._qf("VOLT:LIM?"), "clim": psu._qf("CURR:LIM?")}
    try:
        _apply_sequence(psu, p)
    except PsuError as e:
        if any(v is None for v in backup.values()):
            raise PsuError(f"{e} — 적용 실패 (이전 설정을 읽지 못해 복구 불가, "
                           f"기기 확인 필요)") from e
        try:
            _apply_sequence(psu, backup)
        except PsuError:
            raise PsuError(f"{e} — 적용 실패, 복구도 실패. 기기 전면 패널로 "
                           f"설정을 확인하세요") from e
        raise PsuError(f"{e} — 기기가 거부하여 이전 설정으로 복구했습니다") from e


def apply_profile(psu, p, force=False):
    """프로필 적용. 출력이 ON이면 기본 거부 (부하에 실시간 전압 변화가
    가해지므로 — 명시적 force로만 무시). 출력은 자동으로 켜지지 않는다."""
    if not force and psu.output():
        raise PsuError("출력이 ON 상태 — 끄고 적용하거나 force를 사용하세요")
    apply_values(psu, p)
