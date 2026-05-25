# IST — Kapitel 12: Operational State
Stand: 2026-05-19

Was läuft AKTUELL auf dem Board, was ist live verifiziert, was ist offen.

## Deployed Bitstream

| Item | Value |
|------|-------|
| Local `build/tetra_zynq_phy.bit.bin` MD5 | `44af4da62168a89f2bc4e87ab22bd833` |
| Build-Zeit local | 2026-05-18 ~20:20 (Phase E2 rebuild) |
| HEAD-Commit | `2594a91 docs: correct outdated Reassembly + AST references` (Bitstream-relevanter Letzter: `cae5108 feat(rx): Phase E2 — soft-decisions @ NUB-Capture`) |
| Slice-Utilization (impl) | **98.10 %** (LUT 71.04 %, Reg 43.61 %) |
| Timing | Setup WNS **+0.114 ns** / Hold WNS +0.024 ns (0 failing endpoints) |

## Working-Tree State

`refactor/phase-7-groupcall`, clean (außer Submodule `tetra-bluestation`
dirty mit Cargo.toml-Edits + `bins/tch-s-test/`-Untracked, `sw/test_bs_codec.c`
+ `tetra-kit/` untracked — keine RTL/SW-Diff zum HEAD).

## Running Daemons auf Board

Via SSH `pgrep -al tetra` (Beispiel-Stand 2026-05-17 17:42 nach `--init`):

| PID | Process | Log |
|-----|---------|-----|
| ~21936 | `/root/tetra_sysinfo --daemon` | `/tmp/tetra_sysinfo.log` |
| ~21970 | `/root/tetra_ul_mon` | `/tmp/tetra_ul_mon.log` |
| ~22107 | `/root/tetra_attach_daemon` | `/tmp/tetra_attach_daemon.log` |

Alle drei via `scripts/deploy.sh --init` Step "daemons gestartet" (setsid +
nohup-äquivalent durch detached-Stdio).

`tetra_attach_daemon` ist der zentrale Worker: schreibt bei Boot
`REG_VOICE_NUB_SYNC_THRESH = 11` (Boot-Default, ersetzt RTL-Default 8),
treibt `tetra_call_fsm_tick` (mit Voice-Pipe-Tick pro aktivem Slot)
+ Demand-Mailbox-Service. `tetra_sysinfo` baut SYSINFO-Burst + treibt HN-Advance.
`tetra_ul_mon` ist Read-only-Monitor für UL-PDU-Inspect.

## AXI-Counter (Beispiel frisch nach `--init` 2026-05-17 17:42)

| Reg | Wert | Layout / Bedeutung |
|-----|------|-------------------|
| 0x190 | `0x00010001` | `{accept_cnt[15:0], ul_req_cnt[15:0]}` = 1/1 (sehr frisch) |
| 0x194 | `0x00010000` | `{15'b0, busy_sticky, drop_cnt[15:0]}` = drop=0, busy=1 |
| 0x198 | `0x0000000F` | `{clear_cnt[15:0], inject_cnt[15:0]}` = inject=15 (boot-filler-fills) |
| 0x1EC | `0x00000000` | `REG_VOICE_ACTIVE_MASK` = 0 (idle, kein aktiver Call) |
| 0x260 | RO | `REG_VOICE_NUB_RX_CNT` (Call-FSM-Heartbeat) |
| 0x268 | `0x0000000B` | `REG_VOICE_NUB_SYNC_THRESH = 11` (Boot-Default vom Daemon gesetzt) |

## Live verifiziert (PTT-Air-Test 2026-05-17)

### Voice-Pfad (Phase C + Phase 7 G.8 + SW-TCH/S-Codec) — funktioniert

3-Run-PTT-Test (kurz, ~3 s je), MS1 → MS2-Group, gleicher Test 10× wiederholt
für längeren PTT (~10-15 s):
- **Voice-Pipeline durchläuft kontinuierlich** für Dauer des PTT
 (~16-19 NUB-Bursts/s, voice_pipe-Heartbeat-Log alle 8 Bursts).
- **BFI 3-7 %** im Stable-Stand (thresh=11, fast_attack AGC) — bestätigt
 dass UL-NUB-Capture-Sample-Offsets + Bit-Reverse korrekt sind
 (`8b0737e` fix).
- **OpenEAR-Audio-Decoder hört Sprache sauber durch** (Stand 2026-05-17,
 Setup via RTL-SDR, siehe [reference_audio_monitoring_setup](../../.claude/...)).
- **Mid-Call-Cuts vom 200-ms-Watchdog beseitigt** durch `VOICE_QUIET_MS=300`
 (commit `326439d`).

### Call-Setup (CMCE Phase 7 G.7/G.8) — funktioniert mit Variabilität

10-Run-Messung U-SETUP → first voice burst:
- 7/10 Runs: 0.5 – 1.8 s (median ~0.75 s) — normale TETRA-Setup-Latenz
- 3/10 Runs: 1.3 / 1.8 / **3.6 s** — MS hat erstes U-SETUP nicht ge-ACKed
 bekommen, retransmit ein- bis zweimal.

Retransmit-Rate ist offene Baustelle, gehört in den D-CONNECT/AACH-Scheduling-
Pfad (`tetra_dl_pdu_builder`, `tetra_pre_reply_*`) — NICHT in den
ul_demand_ie_parser-Refactor. Siehe Memory
`project_d_connect_retransmit_rate`.

### Signaling (Vorgängerverifikationen weiterhin gültig)

1. **Sync-Broadcast (SB/SCH-S)** auf TN=2/3/4 — 100 % CRC OK
2. **NDB2 NULL-PDU + SYSINFO** auf MCCH (TN=1) — 100 % CRC OK
3. **F18-Anchor** (BNCH-DMO Pattern) auf TN=0 FN=18
4. **MS-Attach** (ITSI-Register, MM-Body) — `tetra_attach_daemon.log:`
 `serviced #1 — ssi=… result=0 gila_gssi=…`
5. **Group-Switch** (mm=7 Frag-1+Frag-2 → IE-Parser-GAD-Walker → Reply)
6. **CMCE Group-Call-Setup** D-CONNECT[3/3] + D-SETUP
7. **AACH-FN-Rotation auf voice-slot** — `0x32CB` durchgehend FN 1-17
 während aktivem Call (commit `e8efb31`, ersetzt frühere Y.4.1-Rotation
 0x32CB/0x22C9/0x2049)

## Test-Setup-Hinweis

**Nur 1 MS pro BS im aktiven Setup**, Audio-Monitoring läuft via RTL-SDR
+ Software-Decoder (OpenEAR + SDR# TETRA Plugin). KEIN zweites MS-Endgerät
als Audio-Empfänger im Test-Loop. Für valide DL-Audio-Aussagen gilt
**OpenEAR als Referenz** — das SDR# TETRA Plugin hat eigene Limits
(Stand 2026-05-17 z.B. Sync-Drop nach 5 s sichtbar, OpenEAR liefert weiter).
Details: Memory `reference_audio_monitoring_setup`.

## Verifizierte WAV-Captures

| Datei | Inhalt | Notiz |
|-------|--------|-------|
| `wavs/local_cell_425-440mhz/DL_baseband_438343750Hz_14-16-32_17-05-2026.wav` | 30 s DL @ 250 kHz | 759 decoded, 161 voice-frames (Vlast-Slot-NDB1 = TCH/S, CRC-FAIL by-design, ~10 s durchgehend) |
| `wavs/local_cell_425-440mhz/UL_baseband_428156250Hz_14-16-33_17-05-2026.wav` | 30 s UL @ 250 kHz | 3 PDUs (U-ITSI-DETACH, U-DISABLE-STATUS) — wenig UL-Signaling im Capture-Fenster |

## Operatorische Konstanten

| Parameter | Wert |
|-----------|------|
| Board IP | **192.168.2.90** (Stand 2026-05-17, ändert sich per DHCP nach Reboot — Memory `reference_board_ip`) |
| Board SSH | root / openwifi |
| AXI Base | 0x43C00000 |
| RX LO | 428.249998 MHz (UL band — BS hört MS) |
| TX LO | 438.249998 MHz (DL band — BS sendet) |
| Sample-Rate | 4 607 999 sps (~4.608 MSPS) |
| RF-Bandwidth | 200 kHz (AD9361-Minimum, hardware-clamp) |
| RX-Gain-Mode | `fast_attack` (manual/slow_attack 2026-05-17 verworfen — BFI 46-58 %) |
| Cell-Params | MCC=901 MNC=9998 CC=49 LA=1 Carrier=1530 |
| Init-Script | `scripts/deploy.sh --init` (full pipeline) oder `--no-build --init` (nur SW-redeploy) |
| Daemon-Logs | `/tmp/tetra_{sysinfo,ul_mon,attach_daemon}.log` |
| WebUI | http://192.168.2.90/ |
