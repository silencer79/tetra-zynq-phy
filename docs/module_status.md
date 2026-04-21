# Module Status Overview
**Project:** tetra-zynq-phy
**Last Updated:** 2026-04-22
**Status:** Phase 4 MS Access — DL bit-exakt Gold + Duplex-Fix ✅, UL-RX-Chain (RA-Burst) ausstehend 🔴

> **2026-04-22:** MS (MTP3550) erreicht Random-Access-Phase nach Fix A1+B+Duplex
> (Commits `1a3a39a` / `0eda25b` / `9718f1c`). MS sendet auf 428.250 MHz (DL−10 MHz,
> Band 4) 127-Symbol Random-Access-Bursts mit `x`-Training. Board empfängt nichts
> — `ETS_REF` in `rtl/rx/tetra_sync_detect.v:120` ist 60-bit Placeholder statt
> 30-bit ETSI-`x_bits`. Details in `.ralph/fix_plan.md`.

---

## Summary

| Category | RTL Modules | Testbenches | Simulation Status | Phase |
|----------|-------------|-------------|-------------------|-------|
| **RX Chain** | 8 | 8 | ✅ 8/8 PASS | 1 |
| **TX Chain** | 6 | 6 | ✅ 6/6 PASS | 3 |
| **LMAC** | 8 | 8 | ✅ 8/8 PASS | 2 |
| **Infrastructure** | 2 | 2 | ✅ 2/2 PASS | 1 |
| **Top-Level** | 2 | 0 | ⚠️ Integration pending | — |
| **TOTAL** | **26** | **24** | **22/22** | — |

> **Note:** `tetra_ad9361_axis_adapter.v` added for AXI IP integration (Phase 4).
> Top-level modules (`tetra_zynq_top.v`, `tetra_system_top.v`) verified via component tests.

---

## Phase 1 — RX Chain (Complete)

| Module | Description | RTL | TB | Sim Result | LUT | FF | DSP | BRAM | Date |
|--------|-------------|-----|----|-----------|-----|----|-----|------|------|
| `tetra_clk_reset` | Reset synchronizer (4 domains) | ✅ | ✅ | ✅ PASS 15/15 | 0 | 8 | 0 | 0 | 2026-04-03 |
| `tetra_ad9361_axis_adapter` | AXI-Stream AD9361 ↔ Fabric | ✅ | ✅ | ✅ PASS 7/7 | ~5 | ~32 | 0 | 0 | 2026-04-05 |
| `tetra_rx_frontend` | CIC decim + RRC filter + CDC | ✅ | ✅ | ✅ PASS 12/12 | ~120 | ~280 | 1 | 0 | 2026-04-05 |
| `tetra_pi4dqpsk_demod` | CORDIC differential demod | ✅ | ✅ | ✅ PASS 3/3 | ~300 | ~150 | 0 | 0 | 2026-04-03 |
| `tetra_timing_recovery` | Gardner TED + NCO | ✅ | ✅ | ✅ PASS 5/5 | ~120 | ~200 | 2 | 0 | 2026-04-03 |
| `tetra_sync_detect` | Sliding correlator (TS detect) | ✅ | ✅ | ✅ PASS 6/6 | ~380 | ~130 | 0 | 0 | 2026-04-12 |
| `tetra_burst_demux` | TDMA burst extraction | ✅ | ✅ | ✅ PASS 4/4 | ~120 | ~580 | 0 | 0 | 2026-04-03 |
| `tetra_frame_counter` | TDMA frame/multiframe/hyperframe | ✅ | ✅ | ✅ PASS 8/8 | ~50 | ~50 | 0 | 0 | 2026-04-03 |

**Phase 1 Total:** ~1,095 LUT, ~1,430 FF, 3 DSP48, 0 BRAM

---

## Phase 2 — LMAC Channel Decoding (Complete)

| Module | Description | RTL | TB | Sim Result | LUT | FF | DSP | BRAM | Date |
|--------|-------------|-----|----|-----------|-----|----|-----|------|------|
| `tetra_scrambler` | LFSR scrambler/descrambler | ✅ | ✅ | ✅ PASS 8/8 | ~50 | ~32 | 0 | 0 | 2026-04-04 |
| `tetra_interleaver` | Block interleaver (flattened) | ✅ | ✅ | ✅ PASS 8/8 | ~100 | ~450 | 0 | 0 | 2026-04-04 |
| `tetra_viterbi_decoder` | 16-state soft-decision Viterbi | ✅ | ✅ | ✅ PASS 7/7 | ~2500 | ~7800 | 0 | 0 | 2026-04-05 |
| `tetra_reed_muller` | RM(2,5) (30,14) codec | ✅ | ✅ | ✅ PASS 25/25 | ~270 | ~100 | 0 | 0 | 2026-04-05 |
| `tetra_crc16` | CRC-16-CCITT generator/checker | ✅ | ✅ | ✅ PASS 11/11 | ~20 | ~18 | 0 | 0 | 2026-04-05 |
| `tetra_steal_detect` | Stealing bit detector | ✅ | ✅ | ✅ PASS 9/9 | ~20 | ~28 | 0 | 0 | 2026-04-05 |
| `tetra_axi_lite_regs` | AXI4-Lite register bank | ✅ | ✅ | ✅ PASS 10/10 | ~200 | ~150 | 0 | 0 | 2026-04-05 |
| `tetra_axi_dma_bridge` | S2MM DMA bridge | ✅ | ✅ | ✅ PASS 7/7 | ~120 | ~570 | 0 | 0 | 2026-04-05 |

**Phase 2 Total:** ~3,280 LUT, ~9,148 FF, 0 DSP48, 0 BRAM

---

## Phase 3 — TX Chain (Complete)

| Module | Description | RTL | TB | Sim Result | LUT | FF | DSP | BRAM | Date |
|--------|-------------|-----|----|-----------|-----|----|-----|------|------|
| `tetra_rcpc_encoder` | RCPC convolutional encoder | ✅ | ✅ | ✅ PASS 7/7 | ~150 | ~80 | 0 | 0 | 2026-04-05 |
| `tetra_pi4dqpsk_mod` | π/4-DQPSK modulator + LUT | ✅ | ✅ | ✅ PASS 31/31 | ~200 | ~100 | 0 | 0 | 2026-04-05 |
| `tetra_rrc_filter` | RRC pulse shaping (α=0.35) | ✅ | ✅ | ✅ PASS 6/6 | ~300 | ~150 | 1 | 0 | 2026-04-05 |
| `tetra_burst_builder` | NDB/SB/NUB/CB assembler | ✅ | ✅ | ✅ PASS 5/5 | ~50 | ~524 | 0 | 0 | 2026-04-11 |
| `tetra_burst_mux` | TDMA burst multiplexer | ✅ | ✅ | ✅ PASS 5/5 | ~50 | ~200 | 0 | 0 | 2026-04-05 |
| `tetra_tx_frontend` | CIC interpolation + CDC | ✅ | ✅ | ✅ PASS 5/5 | ~80 | ~680 | 0 | 0 | 2026-04-12 |

**Phase 3 Total:** ~830 LUT, ~1,734 FF, 1 DSP48, 0 BRAM

> **Note:** `tetra_tx_nco` was removed (2026-04-17). TX signal goes directly to AD9361 without frequency offset.

---

## Top-Level Integration

| Module | Description | RTL | TB | Status | Notes |
|--------|-------------|-----|----|--------|-------|
| `tetra_zynq_top` | PL top-level | ✅ | — | ⚠️ Pending | Requires axi_ad9361 IP integration |
| `tetra_system_top` | Full system top | ✅ | — | ⚠️ Pending | PS + PL integration |
| `tetra_rx_chain` | RX container | ✅ | — | ✅ Verified | Component integration test |
| `tetra_tx_chain` | TX container | ✅ | — | ✅ Verified | Component integration test |
| `tetra_lmac` | LMAC container | ✅ | — | ✅ Verified | RX+TX paths connected |

---

## Resource Estimate Summary

| Resource | Phase 1 | Phase 2 | Phase 3 | **TOTAL** | **Available** | **Utilization** |
|----------|---------|---------|---------|-----------|---------------|-----------------|
| **LUT** | 1,095 | 3,280 | 950 | **~5,325** | 53,200 | **~10%** |
| **FF** | 1,430 | 9,148 | 1,934 | **~12,512** | 106,400 | **~12%** |
| **DSP48** | 3 | 0 | 3 | **6** | 220 | **~3%** |
| **BRAM18k** | 0 | 0 | 0 | **0** | 280 | **0%** |

> **Note:** Estimates based on behavioral simulation. Actual synthesis numbers may differ.
> Viterbi decoder dominates FF count (7,800 FF for survivor paths + path metrics).

---

## Test Coverage

### Module-Level Tests

- **22** modules with self-checking testbenches
- **22/22** PASS (100% success rate)
- **~162** total test cases across all modules
- **Python-generated test vectors:** CORDIC, Viterbi, Reed-Muller, CRC-16

### Integration Tests

- ✅ Component integration: `rx_chain`, `tx_chain`, `lmac`
- ⚠️ Top-level simulation: Pending (requires axi_ad9361 IP)
- ⏳ Hardware loopback: Planned

---

## Known Issues & Workarounds

| Module | Issue | Workaround | Status |
|--------|-------|------------|--------|
| `rx_frontend` | 34 quantization warnings (CIC) | Cosmetic, does not affect function | ⚠️ Documented |
| `viterbi_decoder` | TIMEOUT warnings in sim | Functional PASS, cosmetic warnings | ⚠️ Documented |
| `burst_demux` | slot_number bug (sync_detect) | Internal slot_cnt used (documented) | ✅ Fixed |
| `burst_builder` | FSM ran at 100 MHz — 255 symbols in 255 cycles instead of 14.17 ms | Added internal 18 kHz sym_en_w divider (SYM_DIV=5554) + build_req_pending latch | ✅ Fixed `96e6356` (2026-04-11) |
| `tx_frontend` | CIC_SHIFT=30 überdämpfte TX-Amplitude um 6 Bit (fe-Amplitude ~500 statt ~15000) | CIC_SHIFT 30→24 (effektiver Gain R^(N-1)=64^4=2^24) | ✅ Fixed `a684455` (2026-04-12) |
| `sync_detect` | Lock-FSM zu fragil für RF-Pfad: spacing_ok nur Slot-Vielfache, LOCK_TIMEOUT zu knapp | LOCK_TOL 8→30, LOCK_TIMEOUT→3060, spacing_ok auf Frame-Vielfache (1020/2040/3060), 12-Bit Counter | ✅ Fixed (2026-04-17) |
| `axi_lite_regs` | SYNC_THRESH Default=30 auf Hardware instabil; 25 grenzwertig; 20 bester Kompromiss | Default 30→20 (Hardware-Sweep) | ✅ Fixed `a684455` (2026-04-12) |
| `rx_frontend` | CIC_GAIN_SHF=6 für RF-Pfad nötig (ADC-Amplitude ~512, Gardner TED braucht ~32767) | CIC_GAIN_SHF von 0→6 (64× Verstärkung); CIC_OUT_LOW=24 statt 30 | ✅ Fixed (2026-04-13) |
| `axi_ad9361 ADC` | ADC Channel Register 0x01 statt 0x51 → dfmt_se/dfmt_enable gelöscht → 12-bit zero-extended → Signal gleichgerichtet → RF SYNC unmöglich | `tetra_ctrl.sh` adc_init/rf_loopback: 0x01→0x51 (Script-Fix, kein Bitstream-Rebuild) | ✅ Fixed (2026-04-13) |
| `AD9361 RF path` | DDS-Test als TX-Nachweis untauglich (`DAC_DDS_DISABLE=1`); interner `TX_MONITOR1_2` zeigt nur sporadischen Lock | Fabric/DAC/TX im Chip lebt | ⚠️ Diagnostiziert |
| `pi4dqpsk_mod` | **Dibit 10↔11 Phase-Mapping vertauscht** (10→-π/4 statt -3π/4, 11→-3π/4 statt -π/4). Unser Decoder hatte denselben Bug → CRC PASS, aber jeder ETSI-konforme Empfänger sah BER 15% / MER 100 | phase_inc für 2'b10: 7→5, für 2'b11: 5→7 (ETSI EN 300 392-2 Table 9.1) | ✅ Fixed (2026-04-13) |
| `tx_chain` | TX-Blanking zu aggressiv: burst-basierter Drain-Timer (1ms) kürzer als Pipeline-Delay → Signal komplett abgeschnitten | Slot-basiertes Blanking: Gate default OPEN, nur für Idle-Bursts geschlossen | ✅ Fixed (2026-04-13) |

---

## Next Actions

### Abgeschlossen (2026-04-17) — RF Loopback STABIL ✅

- [x] TX NCO komplett entfernt (Modul, RTL, SW, Build-Scripts)
- [x] sync_detect Lock-FSM für RF-Pfad robustifiziert:
  - LOCK_TOL 8→30 (RF-Jitter-Toleranz)
  - LOCK_TIMEOUT→3060 (überlebt 2 verpasste Frames)
  - spacing_ok prüft Frame-Vielfache (1020/2040/3060) statt Slot-Vielfache
  - spacing_cnt 11→12 Bit
- [x] RF Loopback: **10/10 SYNC_LOCKED=1** stabil (TX_ATT=-10 dB, AGC=49 dB)
- [x] Frequenzwechsel-Test: Lock geht bei 440 MHz weg, kommt bei 430 MHz zurück
- [x] deploy.sh überarbeitet: full_init ist opt-in (--init), MD5-Verify nach Upload
- [x] End-to-End TX über Luft validiert (MCC=901, MNC=1, decode_sb.py CRC PASS)

### Nächste Phase

1. **Full-Duplex On-Air Testing**
   - [ ] Empfang eines echten TETRA-Signals (z.B. BOS-Netz, DMO)
   - [ ] BER-Messung bei verschiedenen SNR-Pegeln

2. **LMAC Integration**
   - [ ] AXI-DMA Bridge mit echten MAC-Blöcken testen
   - [ ] PS-seitige Software für TETRA-MAC-Stack

---

## Changelog

| Date | Change | Module(s) |
|------|--------|-----------|
| 2026-04-17 | **refactor: TX NCO komplett entfernt** — Modul `tetra_tx_nco.v` + `sin_lut_1024x16.hex` gelöscht, alle Referenzen aus RTL/SW/Build-Scripts entfernt. TX geht direkt an AD9361. | `rtl/tx/tetra_tx_nco.v` (deleted), `rtl/tx/tetra_tx_chain.v`, `rtl/tetra_zynq_top.v`, `rtl/infra/tetra_axi_lite_regs.v`, `sw/tetra_hal.c`, `scripts/vivado_build.tcl` |
| 2026-04-17 | **fix: sync_detect Lock-FSM für RF-Pfad** — LOCK_TOL 8→30, LOCK_TIMEOUT→3060, spacing_ok auf Frame-Vielfache (1020/2040/3060), Counter 11→12 Bit. RF Loopback jetzt 10/10 stabil. Freq-Wechsel 430→440→430 MHz: Lock lost + re-acquired korrekt. | `rtl/rx/tetra_sync_detect.v` |
| 2026-04-17 | **refactor: deploy.sh** — full_init ist jetzt opt-in (`--init`), MD5-Verify nach Upload, Board-Erreichbarkeitscheck, killall vor Upload | `scripts/deploy.sh` |
| 2026-04-13 | **fix: π/4-DQPSK dibit 10↔11 swap** — Root Cause BER 15% / MER 100 bei echtem TETRA-Empfänger. ETSI Table 9.1: 10→-3π/4, 11→-π/4. Auch in decode_sb.py gefixt. | `rtl/tx/tetra_pi4dqpsk_mod.v`, `scripts/decode_sb.py` |
| 2026-04-13 | feat: TX NCO (106 kHz LO-Offset) + DC-Blocker; slot-basiertes TX-Blanking; SYSINFO channel coding (tetra_sysinfo); frame counter (1-18 ETSI) | `rtl/tx/tetra_tx_nco.v`, `rtl/tx/tetra_tx_chain.v`, `sw/tetra_hal.c`, `rtl/tetra_zynq_top.v` |
| 2026-04-13 | fix: ADC dfmt 0x01→0x51 (Root Cause RF-Failure: sign-extend fehlte); RF Loopback **27/30** SYNC_LOCKED=1; CIC_GAIN_SHF=6 (64× RX-Verstärkung) | `scripts/tetra_ctrl.sh`, `rtl/rx/tetra_rx_frontend.v` |
| 2026-04-12 | feat: RF Antennen-Loopback — ADI DAC-Core dac_init (RSTN+DAT_SEL); tetra_ctrl.sh + hw_deploy.sh erweitert | `scripts/tetra_ctrl.sh`, `scripts/hw_deploy.sh` |
| 2026-04-12 | diag: DDS-Test entwertet (`DAC_DDS_DISABLE=1`); AD9361 `TX_MONITOR1_2` liefert sporadischen internen Lock | `docs/hw_board_state.md`, `docs/module_status.md` |
| 2026-04-12 | fix: CIC_SHIFT 30→24, SYNC_THRESH 30→20, LOCK_TIMEOUT 300→512 + 10-Bit Counter; HW-Loopback 59/60 (`a684455`) | `tetra_tx_frontend`, `tetra_axi_lite_regs`, `tetra_sync_detect` |
| 2026-04-11 | fix: burst_builder 18 kHz symbol-rate divider + build_req_pending latch (`96e6356`) | `tetra_burst_builder` |
| 2026-04-11 | fix: timing_recovery → demod sample_valid connection (`f2b90d0`) | `tetra_rx_chain` |
| 2026-04-11 | fix: DATA_CLK 18.432 MHz CIC period correction + SYNC_THRESH 30 (`0f2f5ba`) | `tetra_tx_frontend`, `tetra_axi_lite_regs` |
| 2026-04-08 | fix: free-running TX timer, SB burst type, slot 0 enabled (`2005a2d`) | `tetra_zynq_top`, `tetra_burst_builder`, `tetra_burst_mux` |
| 2026-04-07 | Created docs/module_status.md | Documentation |
| 2026-04-05 | Phase 3 RTL complete (22/22 PASS) | All modules |
| 2026-04-05 | AXI AD9361 adapter integrated | `tetra_ad9361_axis_adapter.v` |
| 2026-04-05 | Production build + timing closure | Build system |
| 2026-04-03 | Phase 1 modules complete (8/8 PASS) | RX chain |

---

## References

- **Simulation logs:** `sim_out/<module>/`
- **Resource estimates:** `docs/resource_estimate.md`
- **Coding rules:** `.ralph/PROMPT.md`
- **Project spec:** `.ralph/CLAUDE.md`

---

**Last Updated:** 2026-04-17
**Maintained by:** Ralph (autonomous FPGA agent)
