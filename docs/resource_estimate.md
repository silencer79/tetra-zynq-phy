# FPGA Resource Estimates
# Project: tetra-zynq-phy
# Target: Zynq-7020 (XC7Z020-CLG484)

## Available Resources (Zynq-7020)

| Resource  | Available | Notes                               |
|-----------|-----------|-------------------------------------|
| LUT       | 53,200    | Logic LUTs (6-input)                |
| FF        | 106,400   | Flip-Flops                          |
| DSP48E1   | 220       | 25×18 multiplier + accumulator      |
| BRAM18k   | 280       | 18k-bit block RAMs (or 140 × BRAM36)|
| BUFG      | 32        | Global clock buffers                |

---

## Module Resource Estimates

| Module                    | LUT    | FF     | DSP48 | BRAM18k | RTL   | TB    | Sim (2026-04-03) | Phase |
|---------------------------|--------|--------|-------|---------|-------|-------|------------------|-------|
| `tetra_clk_reset`         | 0      | 8      | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 15/15    | 1     |
| `tetra_ad9361_interface`  | ~150   | ~100   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 22/22    | 1     |
| `tetra_ad9361_axis_adapter` | ~5   | ~32    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 7/7      | 1     |
| `tetra_rx_frontend`       | ~120   | ~280   | 1     | 0       | ✅ RTL | ✅ TB | ⚠️ PASS* (34 Quantis.-Warns) | 1 |
| `tetra_pi4dqpsk_demod`    | ~300   | ~150   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 3/3      | 1     |
| `tetra_timing_recovery`   | ~120   | ~200   | 2     | 0       | ✅ RTL | ✅ TB | ✅ PASS 5/5      | 1     |
| `tetra_sync_detect`       | ~380   | ~130   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 6/6      | 1     |
| `tetra_burst_demux`       | ~120   | ~580   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 4/4      | 1     |
| `tetra_frame_counter`     | ~50    | ~50    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 8/8      | 1     |
| `tetra_scrambler`         | ~50    | ~32    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 8/8      | 2     |
| `tetra_interleaver`       | ~100   | ~450   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 8/8      | 2     |
| `tetra_viterbi_decoder`   | ~2500  | ~7800  | 0     | 0       | ✅ RTL | ✅ TB | ⚠️ PASS 7/7 (TIMEOUT-Warns) | 2 |
| `tetra_reed_muller`       | ~270   | ~100   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 25/25    | 2     |
| `tetra_crc16`             | ~20    | ~18    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 11/11    | 2     |
| `tetra_axi_lite_regs`     | ~200   | ~150   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 10/10    | 2     |
| `tetra_axi_dma_bridge`    | ~120   | ~570   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 7/7      | 2     |
| `tetra_rcpc_encoder`      | ~150   | ~80    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 7/7      | 3     |
| `tetra_pi4dqpsk_mod`      | ~200   | ~100   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS 31/31    | 3     |
| `tetra_rrc_filter`        | ~300   | ~150   | 1     | 0       | ✅ RTL | ✅ TB | ✅ PASS          | 3     |
| `tetra_steal_detect`      | ~20    | ~28    | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS          | 3     |
| `tetra_burst_builder`     | ~50    | ~510   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS          | 3     |
| `tetra_burst_mux`         | ~50    | ~200   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS          | 3     |
| `tetra_tx_frontend`       | ~80    | ~680   | 0     | 0       | ✅ RTL | ✅ TB | ✅ PASS          | 3     |
| `tetra_zynq_top`          | —      | ~200   | 0     | 0       | ✅ RTL | —     | —                | Top   |

**Legende:** ✅ = PASS; ❌ = FAIL; ⚠️ = PASS mit Warnungen; ⏳ = ausstehend

> **Stand 2026-04-05:** 23/23 Module vollständig getestet (PASS=23, FAIL=0).
> `tetra_ad9361_axis_adapter.v` NEU für ADI axi_ad9361 IP-Block Integration.
> Phase-3-Module (steal_detect, burst_builder, burst_mux, tx_frontend) alle PASS.
> `tetra_zynq_top.v` auf axi_ad9361 fabric interface umgestellt.
| **ESTIMATED TOTAL**       | ~6905  | ~11238 | 3     | 0       |         |       |
| **Zynq-7020 Available**   | 53,200 | 106,400| 220   | 280     |         |       |
| **Estimated Utilization** | ~13%   | ~11%   | ~1%   | ~0%     |         |       |

> **Note:** All estimates are pre-synthesis approximations.
> Actual values will be updated after each Vivado implementation run.
> **Phase 3 complete (2026-04-05):** 23/23 RTL modules, 23/23 TB, 23/23 PASS.
> `tetra_ad9361_axis_adapter` added for ADI axi_ad9361 IP integration (Phase 4).

---

## Notes

### tetra_clk_reset (DONE)
- 8 FFs: 2 per domain × 4 domains
- 0 LUT: pure register chain, no logic
- ASYNC_REG attribute ensures proper placement

### tetra_ad9361_interface (DONE)
- ~100 FFs: 7 IBUFDS (I/O), 7 IDDR (I/O), 8 pipeline regs (i_raw, frame_prev,
  frame_locked, rx_i, rx_q, rx_valid, tx_state, tx_i/q_capture)
- ~150 LUT: DDR mux logic (tx), sign-extension mux, frame_fall combinatorial
- 0 DSP48, 0 BRAM (all I/O bank primitives + fabric registers)
- Note: IBUFDS/BUFG/IDDR/ODDR/OBUFDS use I/O bank resources, not counted in LUT/FF above
- Testbench: awaiting iverilog simulation run

### tetra_pi4dqpsk_demod (DONE)
- ~150 FF: 10 registers (state, iter_cnt, cordic_x/y/z 18-bit, phase_prev, phase_locked, dibit_out, dibit_valid, phase_error_reg)
- ~300 LUT: CORDIC barrel shifter (variable shift x2), combinatorial ATAN case statement, quadrant mux, dibit decision logic
- 0 DSP48: no multipliers — only additions and arithmetic shifts
- 0 BRAM18k: ATAN table inferred as LUTRAM (16 entries × 16 bits)
- Sequential CORDIC: 16 iterations, 18-cycle latency, no throughput constraint at 72 kHz
- Simulation: iverilog not available on this machine — run manually (see below)

### tetra_rx_frontend (DONE)
- ~280 FF: 10 × 46-bit CIC integrator/comb regs (460 FF) + 2 × 528-bit shift regs (66 FF) +
  misc (dec_cnt, strobes, FSM, acc, output regs) ≈ 280 FF total (Vivado will pack some)
- ~120 LUT: CIC comb chain (wire), RRC coeff case statement (ROM inferred as LUTRAM),
  tap index mux (wide read mux), saturation logic
- 1 DSP48E1: 16×16 signed MAC for RRC (both I and Q time-multiplexed on 1 DSP48)
- 0 BRAM18k: XPM async FIFO depth=16 maps to LUTRAM (< 36 words threshold)
- Notes:
  - CIC_R=64, ADC rate 4.608 MHz → 72 kHz output (4× oversampling)
  - RRC: 33-tap α=0.35, sequential MAC (33 cycles/sample, 33 << 64 inter-sample gap)
  - CDC via xpm_fifo_async (LUTRAM, 2-stage synchroniser built-in)
  - Coefficients: Q14 fixed-point, manually computed (run gen_rx_frontend_vectors.py to verify)

### tetra_timing_recovery (DONE)
- ~200 FF: 8 × 16-bit IQ shift regs (128 FF) + NCO/step/integ (96 FF) + output/status regs (~80 FF)
- ~120 LUT: NCO overflow compare, TED difference adders, PI loop arith, lock comparators
- 2 DSP48E1: two 16×17 signed multiplications for Gardner TED (prod_i, prod_q)
- 0 BRAM: no block memory needed
- Notes:
  - Gardner TED: e(k) = I_mid(I_late−I_early) + Q_mid(Q_late−Q_early)
  - 4× oversampled input (72 kHz), on-time output at 18 kHz
  - NCO: 32-bit, nominal step 0x40000000 (overflows every 4 input samples)
  - PI loop: Kp=1/16 (KP_SHIFT=4), Ki=1/256 (KI_SHIFT=8) — parameters tunable
  - Lock detection: |TED| < 256 for 144 consecutive symbols (~8 ms)
  - All clk_sys domain, no CDC

### tetra_sync_detect (DONE)
- ~130 FF: 76-bit shift reg (76 FF) + holdoff_cnt (8) + slot_position (8) + slot_number (2)
          + spacing_cnt (9) + consec_cnt (3) + lock_state (2) + sync_found/sync_locked (2) = ~110 FF
- ~380 LUT: 38+30+22 XOR compare trees (≈220 LUT) + 3 adder trees (≈80 LUT) + mux + FSM (≈80 LUT)
- 0 DSP48: no multiplications; all pure compare/adder logic
- 0 BRAM18k: all combinatorial correlation; reference sequences as localparams (LUT ROM)
- Notes:
  - 76-bit flat shift register (R3 compliance: no arrays)
  - Correlation computed combinatorially each cycle; threshold-gated by 8-bit holdoff counter
  - Lock FSM: 3-state (HUNT/ACQR/LOCK), LOCK_COUNT=4 consecutive pulses at ±8 symbols
  - sync_fire_sample (combinatorial) drives control; sync_found (registered) is 1-cycle output
  - Training sequence constants: VERIFY against ETSI EN 300 392-2 Tables 9.11/9.12/9.14

### tetra_axi_lite_regs (DONE)
- ~150 FF: 22 always blocks — CTRL(4) + SYNC_THRESH(8) + COLOUR_CODE(6) + RX_GAIN(7) +
           TX_ATT(8) + IRQ_ENABLE(5) + IRQ_STATUS(5) + SCRATCH(32) + AXI handshake regs +
           irq_out(1)
- ~200 LUT: combinatorial read mux (16-entry case, ~100 LUT) + IRQ W1C logic (~30 LUT) +
            AWREADY/WREADY/ARREADY combinatorial outputs + misc
- 0 DSP48, 0 BRAM: pure register map, no multipliers or block memory
- Testbench: 10 TCs (SCRATCH, CTRL, VERSION RO, STATUS live inputs, config regs,
              IRQ pulse, IRQ W1C, HW-set priority, FRAME_NUM/SLOT_NUM RO, counters)
- Notes:
  - AWREADY/WREADY/ARREADY are combinatorial wires (R6 compliant)
  - IRQ_STATUS: HW-set wins over simultaneous SW W1C clear
  - CTRL[3]=RESET_COUNTERS is sticky; cleared by SW write-0
  - Byte-lane strobes (WSTRB) supported for SCRATCH; other regs use byte-0 strobe

### tetra_axi_dma_bridge (DONE)
- ~570 FF: 448-bit payload_reg (448 FF) + 32-bit header_reg + 5-bit word_cnt +
           5-bit num_data_words + 4-bit last_tkeep + 16-bit dma_block_count +
           1-bit irq + 2-bit state = ~514 FF (dominant: 448-bit payload register)
- ~120 LUT: 2-state FSM + 32-bit tdata mux (word_cnt=0→header else payload variable-select) +
            TKEEP combinatorial logic + block_done logic
- 0 DSP48, 0 BRAM: flat 448-bit register replaces FIFO (Phase 2 — no backlog buffering)
- Notes:
  - PAD_WIDTH = 14×32 = 448 bits; upper 16 bits zero-padded at load time
  - Variable part-select mac_data_reg_sys[(word_cnt-1)*32 +: 32] synthesizes as 14:1 mux
  - TKEEP[last] = f(block_len mod 32): 0→4'hF, ≤8→4'h1, ≤16→4'h3, ≤24→4'h7, else 4'hF
  - TX (MM2S) path: Phase 3, not implemented
  - No FIFO: back-to-back blocks OK only if prev block fully drained (state==IDLE at mac_valid)
  - Testbench: 7 TCs (216b, 432b, 32b aligned, back-pressure, counter, IRQ pulse, reset_counters)

### tetra_viterbi_decoder (DONE — nicht simuliert)
- Implementierung: flat 256-bit Path-Metric-Register (R3-konform, KEIN Array)
- ACS: 16 unrolled Butterfly-Blöcke in generate-Schleife
- 0 DSP48: Keine Multiplikation — nur Addition + Compare (breiter als erwartet)
- 0 BRAM: Alle Survivor-Paths als flache Register (~7800 FF statt BRAM)
- ~2500 LUT: Min-Tree-Normalisierung, 16:1 Traceback-Mux, Output-Buffer
- Ressourcen-Overhead ist signifikant — Vivado Synthese erforderlich für genaue Werte
- ❓ Simulation ausstehend
- Soft-decision Viterbi (3-bit soft inputs) — K=5, G1=0x1B/G2=0x19/G3=0x15

### Resource Headroom
- DSP48: 220 - 32 = 188 remaining → sufficient for additional filtering
- BRAM: 280 - 16 = 264 remaining → good margin
- LUT: 53200 - 5700 = 47500 remaining → large margin for upper-layer features

### Dual-Protocol Note (DMR + TETRA)
If DMR Tier II repeater runs simultaneously on the same Zynq-7020:
- DMR estimate: ~4000 LUT, ~2000 FF, 16 DSP48, 8 BRAM18k
- Combined: ~10000 LUT (~19%), ~5000 FF (~5%), ~48 DSP48 (~22%), ~24 BRAM18k (~9%)
- Remains well within Zynq-7020 capacity

---

## Actual Synthesis Results (2026-04-07)

**Build:** Vivado 2022.2, Implementation Complete (Post-Route)

| Resource | Used | Available | Utilization | Status |
|----------|------|-----------|-------------|--------|
| **Slice LUTs** | 10,839 | 53,200 | **20.37%** | ✅ Good |
| **Slice Registers** | 16,535 | 106,400 | **15.54%** | ✅ Good |
| **DSP48E1** | 20 | 220 | **9.09%** | ✅ Excellent |
| **Block RAM Tile** | 4 | 140 | **2.86%** | ✅ Excellent |
| RAMB36/FIFO | 3 | 140 | 2.14% | |
| RAMB18 | 2 | 280 | 0.71% | |
| **Slices** | 5,221 | 13,300 | **39.26%** | ⚠️ Moderate |
| **Bonded IOB** | 57 | 125 | 45.60% | ✅ |

### Detailed Logic Distribution
- LUT as Logic: 10,358 (19.47%)
- LUT as Memory: 481 (2.76%)
  - LUT as Distributed RAM: 86
  - LUT as Shift Register: 395
- F7 Muxes: 188 (0.71%)
- F8 Muxes: 0

### Timing Summary
| Constraint | Status | Worst Slack | Total Violation |
|------------|--------|-------------|-----------------|
| Setup | **MET** | 0.043ns | 0.000ns |
| Hold | **MET** | 0.023ns | 0.000ns |
| Pulse Width | **MET** | 3.750ns | 0.000ns |

**Critical Path Analysis:**
- Path: `rx_frontend.mac_cnt` → DSP48E1 (MAC accumulator)
- Margin: **43ps** (very tight!)
- Data Path Delay: 5.779ns (logic 1.295ns, route 4.484ns)
- Logic Levels: 4 (LUT6×2, MUXF7×2)
- Clock Domain: `clk_fpga_0` (100 MHz)
- **Recommendation:** Pipeline RX Frontend for better timing margin

### Clock Domain Crossing (CDC) Report

| From | To | Status | Safe | Unsafe | Unknown |
|------|------|--------|------|--------|---------|
| rx_clk | clk_fpga_0 | ⚠️ CRITICAL | 101 | 0 | 74 |
| clk_fpga_0 | rx_clk | ⚠️ CRITICAL | 56 | **79** | 31 |

**CDC Issues:**
- **79 unsafe crossings** from `clk_fpga_0` → `rx_clk`
- Missing ASYNC_REG attributes on synchronizers
- **Action Required:** Review CDC redesign, add proper synchronization

### ILA Debug Cores

**Bitstream with ILA:** `build/tetra_zynq_phy.bit` (3.9 MB)
**LTX Probes File:** `build/tetra_zynq_phy.ltx` (7.0 KB)

**ILA Instances:**
- `u_ila_lvds` — 2 probes, depth 4096 (LVDS domain)
- `u_ila_sys` — 5 probes, depth 4096 (sys domain)

**Debug Signals Captured:**
- `dbg_adc_valid_i0_lvds` — ADC data valid
- `dbg_rx_valid_lvds` — RX path valid
- `dbg_sync_found_sys` — TETRA sync detected
- `dbg_sync_locked_sys` — Sync lock state
- `dbg_m_axis_tready_sys` — AXIS ready
- `dbg_m_axis_tvalid_sys` — AXIS valid
- `dbg_o_irq_sys` — IRQ output

> **Build Date:** 2026-04-06 23:37
> **Note:** Actual values from Vivado post-route implementation.
> **Phase 3 complete (2026-04-05):** 23/23 RTL modules, 23/23 TB, 23/23 PASS.
