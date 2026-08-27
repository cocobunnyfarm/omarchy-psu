# OWON SPE3102 SCPI API 테스트 결과

- 기기: `OWON,SPE3102,26180149,FV:V5.2.0`
- 포트: `/dev/ttyUSB0` @115200, SCPI(LF 종결)
- 원상복구: 수행됨

| 명령 | 결과 | 증거 |
|---|---|---|
| `*IDN?` | ✅ | OWON,SPE3102,26180149,FV:V5.2.0 |
| `SYST:VERS?` | ✅ | V1.0.0 |
| `SYST:ERR?` | ✅ | 0x0000 |
| `*OPC?` | ✅ | V2.12.2B.1C.D |
| `VOLT?` | ✅ | 13.800 |
| `CURR?` | ✅ | 9.000 |
| `VOLT:LIM?` | ✅ | 14.200 |
| `CURR:LIM?` | ✅ | 9.200 |
| `OUTP?` | ✅ | OFF |
| `MEAS:VOLT?` | ✅ | 0.000 |
| `MEAS:CURR?` | ✅ | 0.000 |
| `MEAS:POW?` | ✅ | 0.000 |
| `OUTP OFF` | ✅ | OUTP? → OFF |
| `VOLT 1.00` | ✅ | VOLT? → 1.0 |
| `VOLT 2.50` | ✅ | VOLT? → 2.5 |
| `CURR 0.10` | ✅ | CURR? → 0.1 |
| `CURR 0.50` | ✅ | CURR? → 0.5 |
| `VOLT:LIM 5.00` | ✅ | VOLT:LIM? → 5.0 |
| `CURR:LIM 1.00` | ✅ | CURR:LIM? → 1.0 |
| `OUTP ON` | ✅ | OUTP? → ON |
| `MEAS:VOLT? (ON)` | ❌ | 실측 0.85V (설정 1.00V) |
| `MEAS:CURR? (ON)` | ℹ️  | 실측 0.0A (무부하면 ~0) |
| `원상복구` | ✅ | VOLT 13.800, CURR 9.000, LIM 14.200/9.200, OUTP OFF |
| `*RST` | ⏭️  | 설정 초기화 — 파괴적 |
| `*SAV/*RCL` | ⏭️  | 저장 슬롯 덮어쓰기 — 파괴적 |
| `SYST:REM/LOC` | ⏭️  | 전면 패널 잠금 — 테스트 불필요 |
