# IST — tetra-zynq-phy Code-State

**Stand:** 2026-05-22
**Branch:** `refactor/phase-7-groupcall`
**Letzter Commit (HEAD):** `7c8614e feat(rtl,sw): Move 3+4 — RTL-DL-Pipeline raus, SW baut komplette 432-bit PDUs`
**Working-Tree (uncommitted):** Pack B — Amplitude-Robustheit. RTL: `tetra_axi_lite_regs.v` (REG_RX_CIC_GAIN_SHF, REG_UL_RA_SYNC_THRESH, REG_UL_RA_RX_STATUS), `tetra_rx_frontend.v` (dynamische Shift+Sat mit Pipeline-Register), `tetra_rx_chain.v`, `tetra_zynq_top.v` (CDC + Wiring). SW: `sw/tetra_hal.h` (Defines), `sw/web/*` (RX-Gain/AGC-Mode + CIC-Gain-Shift + UL-RA-Sync-Threshold Controls), `board_autostart/tetra_autostart.sh` (devmem auf Boot).
**Deployed Build-Artefakt:** `build/tetra_zynq_phy.bit.bin` (Pack B Build, 2026-05-22)
**Vivado-Stand Pack B:** Slice **93.56 %**, LUT **57.03 %**, **WNS +0.018 ns** (positiv, met)
**Pack A Stufe 2b/2c (AGC-Freeze + Power-Detect):** FALSIFIZIERT 2026-05-22 (CRC-Streuung 9–39 % bei identischen Settings, revertiert).
**Pack B (Amplitude + Sync-Separation):** BREAKTHROUGH 2026-05-22. Air-Test CRC-Rate von ~27 % Baseline → **93 % reproduzierbar** mit gain_shf=4 (×16) und ul_ra_sync_thresh=15 (separat von DL-Threshold=13). Reviewer-Hypothese bestätigt: das CIC×64-Gain saturierte UL-Bursts bei AGC-Transienten; gekoppelter DL+UL-Threshold ließ noise-syncs durch.

Diese Dokumentation beschreibt was der Code **TUT**, nicht was er tun **sollte**. Keine Pläne, keine Bewertungen, keine ETSI-Spec-Vergleiche. Reiner IST-Stand zum Stichtag.

## Änderungen seit 2026-05-19 (post-E2-Phase)

**Slice-Cleanup-Phase 1E + Move 3+4:** UL-Demand-IE-Parser + RTL-DL-Pipeline +
MLE-Registration-FSM komplett nach SW verschoben. -8 RTL-Files, -7220 LUT, Slice
**98.10 % → 92.56 %** (-5.5 pp Headroom für nächste RTL-Schritte).

**Pack A RTL-Versuche 2026-05-21 (alle REVERTIERT, kein Win):**

| Versuch | Commit-Stand | Live-Befund | Status |
|---|---|---|---|
| Soft-Decisions UL (`SOFT_SHIFT=24`) | reverted | CRC 28 % ≈ Baseline 29 % | reverted, Diagnostic-Tap bleibt |
| CFO-Korrektur (CORDIC+DDS IPs) | reverted | konvergiert auf -6 kHz (27× ETSI-Spec), BFI unverändert | reverted |
| Digital AGC nach RRC im FPGA | reverted | shift saturiert → MS bucht nicht ein | reverted |
| AD9361 slow_attack/hybrid AGC | reverted | MS bucht aus | reverted |
| AD9361 FIR-Filter aktivieren | nicht umgesetzt | TETRA-Coeffs fehlen, ~2 Tage Aufwand | aufgeschoben |

**Diagnose 2026-05-22 (UL-Decoder Root-Cause):**

71 % CRC-Fail bei UL-Signaling-Decode trotz perfekter Sync (corr_peak=15/15).
Root-Cause: AD9361-AGC update-interval = 1 ms = 18 Symbole, RA-Burst = 7 ms.
→ 7 AGC-Steps mitten im Burst, 46 dB Gain-Swing zwischen Idle (rssi=120, gain=73)
und Burst-aktiv (rssi=39, gain=20). Differential-π/4-DQPSK-Demod liest verzerrte
Magnitudes → bit-flips → Viterbi commits zu falschem Pfad → CRC fail.

**AGC-Freeze-Konzept FALSIFIZIERT 2026-05-22 (revertiert):** Mehrere Varianten
gebaut (sync-trigger, Power-Detect, Power-Detect+Settle-FSM, threshold-sweep,
AD9361-update-interval). CRC-Rate schwankte 9–39 % bei identischen Settings,
nie deutlich über Baseline 27 %. AGC-Freeze-RTL + Power-Detect-RTL aus dem
Code entfernt. WebUI-Controls (RX-Gain + AGC-Mode) bleiben drin.

### Commits 2026-05-14..05-22

| Commit | Was | Wo dokumentiert |
|--------|-----|-----------------|
| `7c8614e` (2026-05-21) | **feat: Move 3+4 — RTL-DL-Pipeline raus, SW baut 432-bit PDUs** | Ch 7 (raw-PDU mailbox), Ch 9 (dl_pdu_builder.c) |
| `469bb10` (2026-05-21) | feat WIP Move 3+4 — SW DL-PDU builder + raw-PDU mailbox | Ch 9 |
| `998bdb3` (2026-05-20) | feat Phase 1E-B — RTL-Parser + parsed-Mailboxen raus, SW walkt komplett | Ch 7, Ch 9 |
| `f0e4f8f` (2026-05-20) | feat Phase 1E-A — SW-Walker reagiert direkt | Ch 9 |
| `1a4633f`, `2dc0891`, `7041ae2` (2026-05-19/20) | Phase 1A/1B/1C — ul_demand_body_mailbox + SW-Parser-Port | Ch 7 |
| `e9f06a3` (2026-05-19) | feat(debug): PTT setup-timing instrumentation | Ch 9 |
| `bdfb38e`, `f2abbf2`, `26aec22`, `2594a91`, `c396ac5` (2026-05-19) | docs sweep — IP-Korrektur, post-E2 WNS/Slice, AST-historisch | docs/* |
| `0f6d8b0`, `2ceb141` | feat(phase c): voice-channel relay pipeline (UL-NUB → DL-NDB1) + FN 1-9 gate | Ch 4 (UL voice capture), Ch 5 (vfill DL path) |
| `7e18b7b` | fix(mer): VOICE_ACTIVE_MASK gating + watchdog (MER 0 % im Idle) | Ch 9 (call_fsm), Ch 8 (REG_VOICE_ACTIVE_MASK) |
| `00228e7` | fix(mer): NUB-thresh=10 (default 8 → 10) + nub_rx-Heartbeat | Ch 9 (attach_daemon init), Ch 8 (REG_VOICE_NUB_SYNC_THRESH) |
| `e8efb31` | fix(arch): voice-relay-RTL aus DL-Pfad raus, AACH 0x32CB durchgehend FN 1-17 | Ch 5 (aach_encoder), Ch 6 (RTL relay-pipe deprecated) |
| `80986b7` | feat(phase-7-G.8): voice-slot SW-filler + D-SETUP + group/individual routing | Ch 9 (voice_filler.c, voice_pipe.c, call_fsm group_gssi), Ch 7 (filler-mailbox) |
| `8b0737e` | fix(voice): NUB-capture sample-offsets (BKN1_PRE_SMP 504→476, BKN2_OFFSET_SMP 32→0) + bit-reverse → UL voice durch | Ch 4 (ul_nub_capture sample positions), Ch 9 (read_nub_bits bit-reverse) |
| `cccf4a9` | fix(call-fsm): split channel-off (VOICE_QUIET_MS=200) vs reservation (CALL_STALE_MS=5000) | Ch 9 (call_fsm watchdog) |
| `326439d` | fix(rx): NUB_SYNC_THRESH 10→11 + VOICE_QUIET_MS 200→300ms (BFI 6→3.5 %, no mid-call rejects) | Ch 9 (attach_daemon defaults), Ch 8 (REG_VOICE_NUB_SYNC_THRESH default) |
| `8b8cb41` | fix(rtl): ul_demand_ie_parser shift-register refactor (body_buf MSB-aligned, gad_buf snapshot) → WNS -0.020 → +0.008 ns | Ch 6 (parser), Ch 11 (timing/util Vivado-Stand) |
| `d179d56` | feat(rx): soft-decision SW decode path + BFI diagnostic instrumentation | Ch 9 (`tetra_bs_tch_s_decode_softi8`, scramble_soft, deinterleave_soft) |
| `cae5108` | **feat(rx): Phase E2 — soft-decisions @ NUB-Capture** (BFI ~6%→~3% live, 7× besser stable) | Ch 4 (nub_capture sat-slice + 2-cycle pipeline), Ch 7 (mailbox 54 words), Ch 8 (REG_VOICE_NUB_READ_INDEX 6-bit) |
| `a6572e3` | fix(autostart): WebUI httpd Start (Block 13) | Ch 10 (board_autostart) |
| `47def0e` | feat(rtl): `tetra_ul_demand_body_mailbox` (Phase 1A — Slice-Cleanup prep) | Ch 7 (Mailboxen, noch nicht in zynq_top instantiiert) |
| `80c30ac` | feat(webui): persistent config + editable duplex-spacing table | Ch 10 (operations, WebUI) |
| `d0f266d` | feat(webui): Live status dashboard RSSI/BFI/MER | Ch 10 (operations, WebUI) |

Neu dokumentationswürdig (siehe entsprechende Kapitel):
- **Phase E2 Soft-Decisions** — 4-bit signed soft pro Coded-Bit aus `tetra_ul_nub_capture.v`, 54-Word-Mailbox, SW `decode_softi8()`. BFI im Median ~6 % → ~3 % im Air-Test, im Sweetspot 7× besser (Ch 4 + Ch 9)
- **Move 2 (Phase 1E)** — UL-Demand-IE-Parser + parsed-Mailboxen komplett in SW. `attach_daemon` walkt direkt die Demand-Body-Mailbox. -3 379 LUT, -0.8 pp Slice (Ch 6 deprecated, Ch 9 mm-demand walker)
- **Move 3+4** — DL-PDU-Builder (incl. MAC-Resource-Header + LLC + SCH/F-Encode) + MLE-Registration-FSM komplett in SW. 8 RTL-Files entfernt, neue raw-PDU-Push-Mailbox. -3 841 LUT, -5.08 pp Slice. (Ch 5 deprecated, Ch 7 raw-pdu mailbox, Ch 9 dl_pdu_builder.c)
- **WebUI Persistent Config + Live Dashboard** — `/root/tetra_cell.conf` ist single source of truth. Auto-Refresh-Tab mit RSSI/BFI/MER-Proxy (Ch 10). Seit 2026-05-21 erweitert um RX-Gain + AGC-Mode Live-Controls (uncommitted)
- **SW-resident BS-TCH/S codec** — `sw/etsi_codec/`, `sw/tetra_bs_tch_s.{c,h}`, `sw/tetra_voice_pipe.c`, `sw/tetra_voice_filler.c` (Ch 9)
- **Vivado-Bilanz aktuell** — Slice 92.56 %, LUT 57.43 %, WNS +0.006 ns (Ch 11)
- **AGC-Freeze (uncommitted, im Build)** — `tetra_ul_agc_freeze.v` neuer Block + IOBUF-Override `tetra_system_top.v` + BD-Port `o_ad9361_en_agc` (Ch 0 zynq_top wiring, Ch 4 sync_found taps)
- **UL-Decoder-Diagnose** — Sync findet alles (15/15), aber 71 % CRC-Fail. Root-Cause AGC-Swing mitten im Burst. Drei RTL-Versuche (Soft/CFO/Dig-AGC) reverted (Ch 4 + Ch 12)

## Kapitel-Übersicht

| # | Datei | Inhalt | Größe |
|---|-------|--------|-------|
| 0 | [00_zynq_top_overview.md](ist/00_zynq_top_overview.md) | Top-Level-Verdrahtung `tetra_zynq_top.v` — Submodule, Wires, Datenpfade, CDC | 25 KB |
| 1 | [01_clocking.md](ist/01_clocking.md) | `tetra_clk_reset.v` + Clock-Domain-Map (clk_sys/clk_lvds/clk_axi) | 4 KB |
| 2 | [02_ad9361.md](ist/02_ad9361.md) | AD9361 AXIS-Adapter + Loopback-Mux | 5 KB |
| 3 | [03_rx_datapath.md](ist/03_rx_datapath.md) | DL-style RX (frontend, timing, demod, sync, burst_demux, frame_counter, rx_chain) | 16 KB |
| 4 | [04_ul_rx.md](ist/04_ul_rx.md) | UL-spezifischer RX (ul_sync_os4, ul_burst_capture, ul_demod, sch_hu, viterbi_r14, parsers, voice_capture) | 29 KB |
| 5 | [05_tx_datapath.md](ist/05_tx_datapath.md) | DL TX (tx_chain, modulator, RRC, AACH-Encoder, SB1, Channel-Coding-Encoder, Queue, Scheduler, Dispatcher) | 36 KB |
| 6 | [06_lmac_fsms.md](ist/06_lmac_fsms.md) | Signaling-FSMs (mle_registration, pre_reply_blck, pre_reply_slotgrant, dl_nwrk_broadcast) | 19 KB |
| 7 | [07_mailboxes.md](ist/07_mailboxes.md) | PS↔PL Mailboxes (demand, grp_demand, indirect, reply, tx_pdu) + axi_dma_bridge + tetra_lmac | 14 KB |
| 8 | [08_axi_regmap.md](ist/08_axi_regmap.md) | Vollständige AXI-Register-Map (3 Banks: 0x000-0x1FC, 0x200-0x2FC, 0x400-0x63F) | 27 KB |
| 9 | [09_sw_stack.md](ist/09_sw_stack.md) | SW: Daemons (sysinfo, attach, ul_mon), PDU-Encoder/Parser, HAL, DB, Char-Dev, WebUI, Build | 43 KB |
| 10 | [10_scripts.md](ist/10_scripts.md) | Alle scripts/ — Build/Deploy/Init Shell, Vivado TCL, Decode/Analyze + Verify Python | 38 KB |
| 11 | [11_build.md](ist/11_build.md) | Vivado-Flow, Constraints, Deploy-Pipeline, Cross-Compile, ILA, CDC-Reports | 18 KB |
| 12 | [12_operational_ist.md](ist/12_operational_ist.md) | Was läuft auf Board: deployed Bitstream, Daemons, AXI-Counter, live-verifiziert vs inert | 8 KB |

**Total:** ~283 KB (~10 000 Zeilen) für die strukturierte Beschreibung von 65 RTL-Files + 22 SW-Files + 50 Scripts.

## Block-Diagramm (vereinfacht)

```
 ┌─────────────────────────────────────┐
 │ ARM PS (Linux userspace) │
 │ │
 │ ┌────────────────┐ ┌────────────┐ │
 │ │ tetra_attach_ │ │ tetra_call │ │
 │ │ daemon │ │ _fsm │ │
 │ │ (10 ms poll) │ │ (per-SSI) │ │
 │ └───┬────────────┘ └─────┬──────┘ │
 │ │ AXI4-Lite │ │
 │ ┌───▼─────────────────────▼──────┐ │
 │ │ tetra_hal (libtetra) │ │
 │ └───┬─────────────────────────────┘ │
 └──────┼──────────────────────────────┘
 │ s_axi (clk_axi)
─────── PL ────────────────────────┼──────────────────────────────
 ┌──────▼──────────────────┐
 │ tetra_axi_lite_regs │ Bank 0/1/2
 │ Bank 0: 0x000-0x1FC │ ~300 regs
 │ Bank 1: 0x200-0x2FC │ mailbox-ext
 │ Bank 2: 0x400-0x63F │ schedule-BRAM
 └──────┬──────────────────┘
 │ broadcasts to all clk_sys modules
 │ (CDC: 2-FF resync for AXI→sys)
 ┌──────────────────────────┼──────────────────────────────┐
 │ │ │
 ┌────▼─────────┐ ┌──────▼──────────┐ ┌────────▼─────────┐
 │ Mailboxes │ │ LMAC Signaling │ │ TDMA Timebase │
 │ (demand, │ │ FSMs │ │ (TN/FN/MN/HN) │
 │ grp_demand, │ │ ┌─────────────┐ │ │ slot_pulse_sys │
 │ indirect, │ │ │ MLE-Reg-FSM │ │ └────────┬─────────┘
 │ reply) │ │ │ PreReply- │ │ │
 └────┬─────────┘ │ │ blck/sg │ │ │
 │ │ │ NwrkBcast │ │ │
 │ │ └──────┬──────┘ │ │
 │ └────────┼────────┘ │
 │ │ │
 │ ▼ │
 │ ┌─────────────────┐ │
 │ │ DL Signal Queue │ MLE/CMCE/SDS-port│
 │ │ (4-entry, │ │
 │ │ strict prio) │ │
 │ └────────┬────────┘ │
 │ │ │
 │ ▼ │
 │ ┌─────────────────┐ │
 │ │ DL Signal Sched │ (head pop/frame) │
 │ └────────┬────────┘ │
 │ │ sched_blk1/2_tnK │
 │ ▼ │
 ┌────────────────────────────────────────────────┐ │
 │ RX-Pipeline (rtl/rx) TX-Pipeline (rtl/tx)│ │
 │ │ │
 │ AD9361 ── rx_frontend ──┐ ┌── slot_content_mux│◄───────────┘
 │ (clk_lvds) (CIC+RRC) │ │ (schedule BRAM-prefetch)
 │ CDC ──┘ │ │
 │ ┌──────────────────────┘ ▼
 │ │ ┌──────────────────┐
 │ ▼ │ burst_dispatcher │ (Y.3, single-stage mux)
 │ timing_recovery └─────────┬────────┘
 │ │ on-time samples 18kHz │
 │ ▼ ▼
 │ pi4dqpsk_demod ┌──────────────────┐
 │ │ dibit_out │ tx_chain │
 │ ▼ │ ├ sb1_encoder │
 │ sync_detect (DL-style) │ ├ pi4dqpsk_mod │
 │ │ │ ├ RRC filter │
 │ ▼ │ └ tx_frontend │
 │ burst_demux └────┬─────────────┘
 │ │ │
 │ ▼ ▼
 │ frame_counter ad9361_axis_adapter
 │ (TX sample+hold)
 │ ▼ DAC (clk_lvds)
 │ AD9361
 │
 │ ── parallel UL path ──
 │
 │ rx_frontend (shared) ── ul_sync_detect_os4 ── ul_burst_capture
 │ │
 │ ▼
 │ ul_pi4dqpsk_demod
 │ │
 │ ▼
 │ ul_sch_hu_decoder
 │ (RCPC+Viterbi)
 │ │
 │ ▼
 │ ul_mac_access_parser
 │ │
 │ ▼
 │ ┌──────────────────────┴──────────────┐
 │ ▼ ▼
 │ ul_demand_reassembly ul_demand_ie_parser
 │ │ │
 │ └──── AXI Mailboxes ──────────────────┘
 │ (für SW-Polling)
 │
 │ ── (Working-Tree only) Y.4.2/Y.4.3 hack ──
 │
 │ rx_chain.ul_demod_dibit_out_sys = demod_dibit_sys ← Working-Tree
 │ = ul_soft0/1[MSB] ← Deployed Bitstream
 │ │
 │ ▼
 │ ul_voice_capture
 │ (216-Dibit FSM,
 │ DL-slot-aligned)
 │ │
 │ ▼ voice_burst_valid
 │ CMCE-port-mux (zynq_top)
 │ (mit nwrk_bcast OR'd)
 │ │
 │ ▼
 │ DL signal queue
 │ (CMCE-port input)
 │
 └─────────────────────────────────────────────────────────
```

## Konsolidierte Befunde (cross-chapter)

### Tote / Inerte Pfade

| Pfad | Wo | Status |
|------|-----|--------|
| `tetra_lmac.v` TX-Datenpfad | hardwired auf 0, ARM-DMA-MM2S existiert nicht | Tot innerhalb live-Modul (Ch 7) |
| `tetra_char_dev.c` (Kernel-Modul) | nicht im deploy.sh --init-Pfad | Tot/ungenutzt (Ch 9) — behalten als Future-Debug-Tool |
| Generic-Coding-Module (crc16/scrambler/interleaver/rcpc/reed_muller) im DL-TX | RX-only, TX hat Inline-Impls | Code-Dup (Ch 5) |
| Shadow-Subscriber-Tabelle (REG_SHADOW_*) | Consumer-Audit deferred | Phase-X.4-Restdrift, unverifiziert |
| Profile-Tabelle (REG_PROFILE_*) | Consumer-Audit deferred | Phase-X.4-Restdrift, unverifiziert |

**Phase A.3.1 Cleanup (committed):** entfernt — `tetra_tx_inv_sinc.v`, `tetra_tx_pdu_mailbox.v`, `tetra_rx_burst_fifo.v`, `sw/tetra_pdu_class.h`.

**Phase A.1 Rollback (committed):** entfernt — `tetra_ul_voice_capture.v` (Y.4.2/Y.4.3-Hack), CMCE-port-Mux in `zynq_top.v`, UL-demod-Outputs in `rx_chain.v`.

**Agent-3-Claims falsifiziert (in IST baseline):** REG_NCO_PHASE_INC ist schon weg (kein Code-Rest); 0x250..0x25C ist NICHT verschwunden (Phase Y.1.f Group-Attach Reply-Mailbox, live in `axi_lite_regs.v`).

### Phase-Tags-Inventar (chronologisch durchs RTL)

- **H.0.9** — BRAM-Inferenz-Split (`slot_schedule`)
- **H.3.x** — ITSI-Attach-Fixes (MLE-Trigger, AACH-Typo, gap-slot)
- **H.6.x** — Grant-Override-Pfad in `aach_encoder`
- **H.7** — D-NWRK-BCAST autonom über RTL (war SW-Tick)
- **X.1-X.7** — Subscriber/AST/TTL/Multi-Lookup/WebUI/SW-Resident-DB
- **Y.1.x** — Group-Demand-Mailbox, Reassembly, IE-Parser
- **Y.2** — slotgrant Single-SCH/HD-Pfad
- **Y.3** — TX-Datenpfad simplifiziert (8→3 Stages, burst_dispatcher)
- **Y.4.1** — AACH FN-Rotation auf voice-slot (LIVE verifiziert)
- **Y.4.2/Y.4.3** — UL-Voice-Capture (HACK, inert)
- **Z.2/Z.3/Z.9/Z.12/Z.13** — AACH-Pattern, Slot-Side-Select, Override-Inputs entfernt
- **Phase 7 F.1-F.4** — UL-Reassembly + IE-Parser + AXI-Mailbox + WebUI Profile
- **Phase 7 G.1-G.7** — CMCE D-CONNECT Stack-Up + Daemon-Dispatch + Call-FSM

### Drift / Auffälligkeiten zum Anschauen

1. **AACH-Encoder vs Reed-Muller-Modul** — zwei verschiedene 30×14 G-Matrizen (Ch 5)
2. **`tetra_pre_reply_blck` LSB-aligned vs `pre_reply_slotgrant` MSB-aligned** im selben 432-bit Queue-Bus (Ch 6) — bewusst, aber Stolperstein
3. **`test_cmce_body` TC3 erwartet 30-bit D-CONNECT, Code emittiert 39-bit** (Ch 9) — Test ist drift
4. **`tetra_char_dev.c TETRA_STATUS_FRAME-valid` Macro mit Bindestrich** = compile-broken, aber nirgends referenziert (Ch 9)
5. **`sw/www/` vs `sw/web/` CGI-Duplikate** — leicht andere Defaults (Ch 9)
6. **`vivado_sim.tcl xc7z020clg484-1` vs `vivado_build.tcl xc7z020clg400-1`** — Package-Discrepancy (Ch 11)
7. **`add_ila_debug.tcl` Syntax-Bugs** + `extract_cdc_violations.tcl lassassign`-Tippfehler (Ch 11)
8. **`mle_registration_fsm` ignoriert alle UL-MAC-ACCESS-Inputs** (`_unused_ports`-Senke) — Logic ist in SW (Ch 6)
9. **CDC-Brücken** alle 2-FF-Synchronizer (`ASYNC_REG=TRUE`), aber RAMB18-Async-Control-Warnings in `ul_burst_capture` (pre-existing in DRC)
10. **Hardcoded Konstanten in `dl_pdu_builder`:** `usage_marker=11`, `chan_alloc=0x0027_2FD3`, `granting_delay=0` (Ch 5) — kein Mehrfach-Call-Support
11. **Phase Y.4.1 vs Y.4.2/Y.4.3 im Code wired** aber Y.4.2/Y.4.3 **on-air inert** wegen sync-gegateter Demod-Source (Ch 4, Ch 12)

### "Tot bei einmaliger Nutzung" / Forensik-Scripts (Ch 10)

- `scripts/fix_tx_instantiation.py` (2026-04-08 Refactor-Tool)
- `scripts/verify_empty_*.py`, `probe_sb_*.py`, `sim_loopback.py`, `verify_sch_f_roundtrip.py`
- `scripts/convert_bitstream.sh` (Duplikat von deploy.sh Step 2)
- `scripts/ila_autonomous_capture.tcl` (Duplikat von ila_capture.tcl)
- `scripts/generate_viterbi_ip.tcl` (IP wird nicht im aktuellen Build verwendet)

## Wie ist diese Doku zu pflegen

- IST.md ist Index — Inhalt steht in den `ist/NN_*.md` Files
- Bei Code-Änderung: das passende Kapitel-File updaten, **nicht** neue Files anlegen
- "Plans / Decisions / Sollvorstellungen" gehören **nicht** hier rein. Wenn Plan-Doku gebraucht: separate `docs/PLAN_<topic>.md` (eindeutig getrennt)
- Bei nächstem Reset: Kapitel-Files regenerieren via Agent-Run (siehe Agent-Prompts in dieser Session)
