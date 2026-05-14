# IST — Kapitel 12: Operational State (2026-05-14)

Was läuft AKTUELL auf dem Board, was ist live verifiziert, was ist inert, was ist gar nicht erst eingebaut.

## Deployed Bitstream

| Item | Value |
|------|-------|
| Local `build/tetra_zynq_phy.bit` MD5 | `c281cd12b02f07be744e149864b30347` |
| Local `build/tetra_zynq_phy.bit.bin` MD5 | `3b4c5150b07443691924edb9e67178c4` |
| Board `/lib/firmware/tetra_zynq_phy.bit.bin` MD5 | `3b4c5150b07443691924edb9e67178c4` (match) |
| Build-Zeit local | 2026-05-14 18:45-18:46 |
| Build-Log | `/tmp/vivado_build_y43_v2.log` |
| Slice-Utilization (impl) | 96.45 % (LUT 67.58 %, Reg 39.93 %) |
| Timing | Setup WNS +0.002 ns / Hold WNS +0.018 ns (MET, knapp) |

## Working-Tree State (uncommitted)

Last commit: `def6f79 fix(aach): head_match gegen CURRENT emit-TN statt lookahead` (2026-05-13 20:07).

Uncommitted Änderungen (`git status -s`):

**RTL — modified:**
- `rtl/include/tetra_pdu_class.vh`
- `rtl/infra/tetra_axi_lite_regs.v` — REG_VOICE_ACTIVE_MASK @ 0x1EC hinzugefügt (Phase Y.4.1)
- `rtl/lmac/tetra_dl_pdu_builder.v`
- `rtl/lmac/tetra_mac_resource_dl_builder.v`
- `rtl/lmac/tetra_mle_registration_fsm.v`
- `rtl/lmac/tetra_pre_reply_slotgrant.v`
- `rtl/rx/tetra_rx_chain.v` — UL-Demod-Outputs hinzugefügt (Phase Y.4.2-Hack)
- `rtl/tetra_zynq_top.v` — voice_capture-Instanz + CMCE-Mux + voice_active_mask CDC (Phase Y.4.1+Y.4.2-Hack)
- `rtl/tx/tetra_aach_encoder.v` — Y.4.1-fix FN-Rotation (0x32CB/0x22C9/0x2049)

**RTL — new (untracked):**
- `rtl/rx/tetra_ul_voice_capture.v` — Y.4.2/Y.4.3-Hack-Modul, **inert** (siehe unten)

**Scripts — modified:**
- `scripts/decode_dl.py`
- `scripts/vivado_build.tcl` — `tetra_ul_voice_capture.v` in RX-Source-Liste

**SW — modified:**
- `sw/tetra_attach_daemon` (binary)
- `sw/tetra_call_fsm.c` + `.h` — `voice_active_mask=0x02` set bei U-SETUP, clear bei U-RELEASE
- `sw/tetra_cmce_body.c` + `.h`
- `sw/tetra_hal.h` — `REG_VOICE_ACTIVE_MASK 0x1EC`
- `sw/tetra_tx_transport.c` + `.h`

**Untracked:** `docs/ist/`, `CLAUDE.md`, `tb/tb_mle_grpack_e2e.v`, `.gen/`, `ip/`, `tetra-kit` (submodule?)

## Running Daemons auf Board

Via SSH `ps`:

| PID | Process | Log |
|-----|---------|-----|
| 22933 | `tetra_sysinfo` | `/tmp/tetra_sysinfo.log` |
| 22959 | `tetra_ul_mon` | `/tmp/tetra_ul_mon.log` |
| 23065 | `tetra_attach_daemon` | `/tmp/tetra_attach_daemon.log` |

Alle drei via `scripts/deploy.sh --init` Step "Subscriber-DB seeded + daemons" gestartet (setsid).

WebUI httpd: laut deploy.sh `WebUI httpd started → http://192.168.2.85/` — nicht in `ps` verifiziert.

## AXI-Counter (Stand 2026-05-14 20:00)

| Reg | Wert | Bedeutung |
|-----|------|-----------|
| 0x190 | 0x00100008 | `{accept_cnt=0x0010, ul_req_cnt=0x0008}` — 16 ACCEPTs / 8 ul_req — Discrepancy (mehr accepts als req?) |
| 0x194 | 0x00010000 | `{busy_sticky=0, drop_cnt=0x0001_0000}` — drop_cnt = 65536 (overflow?) |
| 0x198 | 0x000001F2 | `{clear_cnt=0x0000, sig_override_cnt=0x01F2}` — 498 sig_override events |
| 0x1A4 | 0x00000008 | `REG_AST_DETACH_CNT` = 8 detach events seit boot |
| 0x1B0 | 0x00000000 | `REG_AST_TTL_EVICT_CNT` = 0 (TTL-Sweeper hat nie evicted) |
| 0x1EC | 0x00000002 | `REG_VOICE_ACTIVE_MASK` = 0x02 → voice_active[1]=1 → TN=1 (air) = decoder-TN=2 |

Note: `voice_active_mask = 0x02` ist gerade gesetzt — SW hat ihn bei letzter U-SETUP geschrieben und nie geklärt (oder MS ist noch im Call-State).

## Live verifiziert (auf RTL-SDR-Capture decode_dl.py 2026-05-14 19:42)

Aus `wavs/local_cell_425-440mhz/DL_baseband_438343750Hz_19-42-53_14-05-2026.wav` (20 s):
- 1415 Bursts decoded, **100 % CRC OK** (1067 SB, 348 NDB)
- MCC=901 MNC=9998 CC=49, Carrier=1530, DL=438.250 MHz
- AACH-Pattern auf TN=2 (decoder) während voice_active_mask=0x02:
 - FN 1-9: `0x32CB` (Y.4.1-fix voice TCH/S pattern) ✅
 - FN 10-13: `0x22C9` (FACCH-stealing pattern) ✅
 - FN 14-17: `0x2049` (idle filler) ✅
- AACH-Encoder Y.4.1-fix FN-Rotation **funktioniert** — die korrekten 3 Pattern werden raus-emittiert.

## Was AKTUELL als Hack drinhängt aber inert ist

### `tetra_ul_voice_capture.v` (Y.4.2/Y.4.3-Versuch)

Modul ist im Bitstream instanziiert (`u_ul_voice_capture` in zynq_top.v) und konsumiert Slices, aber **pulst `voice_burst_valid_sys` nie**.

Grund: das Modul nimmt seine UL-Dibits aus `rx_chain.ul_demod_dibit_out_sys`, das im aktuellen Working-Tree-Stand **auf den DL-sync-getriggerten Haupt-Demod** verdrahtet ist (`assign ul_demod_dibit_out_sys = demod_dibit_sys`). Dieser Haupt-Demod-Output ist als Source nicht UL-spezifisch — kommt aber laut Y.4.2-Hack-Kommentar trotzdem an, weil die RX-Antenne UL-Band hört. Aber das Modul triggert seine 432-bit-Capture nur auf `tdma_slot_pulse_sys && voice_active_mask_sys[tn_sys]` — der TDMA-Slot-Pulse-Reference ist DL-side. UL-MS-Burst arrival ist offset durch Propagation + MS-Timing-Advance, also greift die FSM zwar einen 216-Dibit-Fenster, aber nicht den eigentlichen UL-Burst-Payload.

Resultat im decode: TN=2 wird weiter durch den static-schedule-Fallback (SB-SYSINFO) belegt, voice_burst_valid pulst nie, queue-CMCE-Mux fällt auf `nwrk_bcast` (10 s Cadence) → kein Voice-Relay.

### CMCE-Port-Mux in zynq_top.v

Top-Level-Mux (`cmce_port_wr_valid_w = voice_burst_valid_sys_w | nwrk_bcast_push_valid_sys_w`) ist live, aber weil voice_burst_valid nie pulst, wird er praktisch zur Pass-Through-Verbindung von nwrk_bcast zur Queue.

## Was NICHT eingebaut ist

Aus den ursprünglichen Phase-Y.4-Tags im Working-Tree-Code:
- **Echte UL-NUB-RX-Pipeline** — kein TCH/S-Sync-Korrelator, kein BKN1+BKN2-Extract (STS skip), kein UL-Frame-Counter-Aligned-Capture
- **Voice-Relay-Buffer** (1-Frame zwischen UL-RX und DL-Emit) — nicht existent
- **D-TX-CEASED / Hangtime** (FACCH-stealing am Call-Ende) — nicht implementiert
- **Voice-Channel-Allocated-State-Tracking** außerhalb von voice_active_mask — kein Reservierungsmechanismus für mehrere parallele Calls (UsageMarker hardcoded 11 in `mac_resource_dl_builder`)

## Was bestätigt funktioniert (Stand 2026-05-14)

1. **Sync-Broadcast (SB/SCH-S)** auf TN=2/3/4 — 100 % CRC OK
2. **NDB2 NULL-PDU + SYSINFO** auf MCCH (TN=1) — 100 % CRC OK
3. **F18-Anchor** (BNCH-DMO Pattern) auf TN=0 FN=18
4. **MS-Attach** (ITSI-Register, MM-Body), bestätigt via `tetra_attach_daemon.log`
5. **Group-Switch** (mm=7 Frag-1+Frag-2+Pre-Reply+Frag-3+ACK)
6. **CMCE Group-Call-Setup** bis D-CONNECT: MS akzeptiert, geht in TX-State
7. **Y.4.1-fix AACH-FN-Rotation** auf voice-slot (decoder-verifiziert)

## Was NICHT funktioniert (Air-Test 2026-05-14 19:42)

1. **Audio-Relay** zwischen zwei MS in derselben Gruppe — kein DL-Voice-Burst-Content, MS sendet zwar UL-Voice (Y.4.1-fix sorgt dafür dass MS-TX-State stabil bleibt), aber andere MS hört nichts
2. **UL-NUB-Decode** in `tetra_ul_mon` — der parst nur SCH/HU-Signaling, keine TCH/S-Voice

## Operatorische Konstanten

| Parameter | Wert |
|-----------|------|
| Board IP | 192.168.2.85 |
| Board SSH | root / openwifi |
| AXI Base | 0x43C00000 |
| RX LO | 428.249998 MHz (UL band — BS hört MS) |
| TX LO | 438.249998 MHz (DL band — BS sendet) |
| Sample-Rate | 4 607 999 sps (~4.608 MSPS) |
| RF-Bandwidth | 200 kHz |
| Gain-Mode | fast_attack |
| Cell-Params | MCC=901 MNC=9998 CC=49 LA=1 Carrier=1530 |
| Init-Script | `scripts/deploy.sh --init` |
| Daemon-Logs | `/tmp/tetra_{sysinfo,ul_mon,attach_daemon}.log` |
| WebUI | http://192.168.2.85/ |

## Letzter erfolgreicher Air-Test

WAV: `wavs/local_cell_425-440mhz/DL_baseband_438343750Hz_19-42-53_14-05-2026.wav`
- 20 s RTL-SDR-Capture, fs=250 kHz, center 438.34375 MHz
- decode_dl.py: 1415/1416 Bursts (99.93 %), 1 empty
- MER (DLL-style): 0.07 %
- Air-AACH-Pattern entspricht Y.4.1-fix-Logik
