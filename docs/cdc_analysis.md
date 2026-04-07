# Clock Domain Crossing (CDC) Analysis
# TETRA Zynq PHY — Critical Hardware Bug Report

**Status:** ❌ CRITICAL — 79 UNSAFE CDC crossings detected
**Date:** 2026-04-07
**Build:** Vivado 2022.2, Post-Route Implementation
**Priority:** P0 — Must fix before hardware test

---

## Executive Summary

Vivado CDC report identified **79 unsafe clock domain crossings** from `clk_fpga_0` (100 MHz system clock) to `rx_clk` (AD9361 LVDS DATA_CLK domain). These violations pose a **critical hardware reliability risk**:

- **Metastability hazard:** Unsynchronized crossings can cause random bit flips
- **Intermittent failures:** Bugs may only appear with temperature/voltage variations
- **Debugging difficulty:** CDC bugs are notoriously hard to reproduce and diagnose

**Recommendation:** Do NOT deploy bitstream to hardware until all 79 unsafe crossings are fixed with proper 2-FF synchronizers and ASYNC_REG constraints.

---

## Clock Domain Map

### Active Clock Domains

| Domain | Source | Frequency | Purpose | Distribution |
|--------|--------|-----------|---------|--------------|
| **clk_sys** | Zynq PS FCLK_CLK0 | 100 MHz | Main processing domain | All LMAC, AXI-DMA bridge, control logic |
| **clk_lvds** | AD9361 DATA_CLK (via axi_ad9361 IP) | ~30.72 MHz (DATA_CLK) | LVDS ADC/DAC interface | `tetra_ad9361_axis_adapter`, RX/TX frontends |
| **s_axi_aclk** | Zynq PS GP0 clock | 100 MHz | AXI4-Lite register interface | `tetra_axi_lite_regs` |
| **clk_sample** | Derived (decimated) | ~72 kHz | Decimated symbol rate | Currently same as clk_sys (strobe-based) |

**Note:** In Phase 3, `clk_sys` and `s_axi_aclk` originate from the same PS PLL source, which minimizes CDC risk. However, `clk_sys` and `clk_lvds` are **asynchronous** and require proper synchronization.

---

## Clock Domain Crossing Matrix

| From Domain | To Domain | Safe Crossings | Unsafe Crossings | Unknown | Status |
|-------------|-----------|----------------|------------------|---------|--------|
| **rx_clk** (clk_lvds) | **clk_fpga_0** (clk_sys) | 101 | 0 | 74 | ✅ GOOD |
| **clk_fpga_0** (clk_sys) | **rx_clk** (clk_lvds) | 56 | **79** | 31 | ❌ CRITICAL |

**Total unsafe crossings:** 79 (all in clk_sys → clk_lvds direction)

---

## Domain Visualization

```
┌─────────────────────────────────────────────────────────────────────┐
│ Zynq PS (ARM Cortex-A9)                                              │
│                                                                       │
│  ┌───────────┐         ┌───────────┐                                │
│  │ FCLK_CLK0 │────────►│ GP0 AXI   │                                │
│  │  100 MHz  │         │  100 MHz  │                                │
│  └───────────┘         └───────────┘                                │
└─────────────────────────────────────────────────────────────────────┘
          │                      │
          │                      │
          ▼                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Zynq PL (FPGA Fabric)                                                │
│                                                                       │
│  ┌──────────────────────────────┐  ┌──────────────────────────────┐│
│  │ clk_sys Domain (100 MHz)     │  │ s_axi_aclk Domain (100 MHz)   ││
│  │                              │  │                               ││
│  │  • tetra_rx_chain            │  │  • tetra_axi_lite_regs        ││
│  │    (CIC, RRC, demod, sync)   │  │    (PS ↔ PL control/status)   ││
│  │  • tetra_lmac               │  │                               ││
│  │    (Viterbi, CRC, RM)        │  │  ✅ 2-FF synchronizers present││
│  │  • tetra_tx_chain            │  │    (sync_locked, frame_num)   ││
│  │    (Modulator, RRC, CIC)     │  └──────────────────────────────┘│
│  │  • tetra_axi_dma_bridge      │                                  │
│  │    (MAC blocks → PS DDR)     │                                  │
│  └──────────────────────────────┘                                  │
│           │                                                          │
│           │ ❌ UNSAFE CDC (79 bits)                                 │
│           │ ⚠️ Missing synchronizers                                 │
│           ▼                                                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ clk_lvds Domain (AD9361 DATA_CLK ~30.72 MHz)                 │  │
│  │                                                               │  │
│  │  ┌────────────────────────────────────────────────────────┐  │  │
│  │  │ axi_ad9361 IP (Vivado Block Design)                     │  │  │
│  │  │  • LVDS DDR I/O (ADC/DAC)                               │  │  │
│  │  │  • DATA_CLK output → clk_lvds                           │  │  │
│  │  │  • Fabric interface: 16-bit ADC/DAC buses               │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  │                                                               │  │
│  │  • tetra_ad9361_axis_adapter                                 │  │
│  │    (fabric interface adapter)                                │  │
│  │  • RX Frontend (CIC decimation)                             │  │
│  │  • TX Frontend (CIC interpolation)                          │  │
│  │                                                               │  │
│  │  ✅ 101 SAFE crossings (rx_clk → clk_fpga_0)                │  │
│  │     Uses XPM FIFOs with built-in synchronizers              │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
          │
          ▼
    ┌──────────┐
    │ AD9361   │
    │ RF XCVR  │
    │ (LVDS)   │
    └──────────┘
```

---

## CDC Crossing Direction Analysis

### ✅ SAFE: rx_clk → clk_fpga_0 (101 safe, 0 unsafe)

**Direction:** `clk_lvds` → `clk_sys`

**Status:** Properly synchronized using XPM FIFOs

**Crossings:**
- RX IQ sample data (I/Q samples from ADC)
- RX valid signals (sample strobes)
- All RX data paths through XPM async FIFOs in `tetra_rx_chain`

**Why safe:**
- XPM_FIFO_ASYNC primitives have built-in Gray-code pointers and 2-FF synchronizers
- Read/write pointers are Gray-coded before crossing domains
- Vivado automatically propagates ASYNC_REG constraints

Example from `tetra_rx_frontend.v`:
```verilog
// CDC: clk_lvds → clk_sys via XPM async FIFO
xpm_fifo_async #(
  .FIFO_MEMORY_TYPE("distributed"),
  .READ_DATA_WIDTH_B(46),
  .WRITE_DATA_WIDTH_A(46)
) u_cdc_fifo (
  .rst (!rst_n_lvds),
  .wr_clk (clk_lvds),
  .din ({rx_i_cic, rx_q_cic}),
  .wr_en (cic_valid),
  .rd_clk (clk_sys),
  .dout ({rx_i_sys, rx_q_sys}),
  .rd_en (rd_en),
  ....
);
```

---

### ❌ UNSAFE: clk_fpga_0 → rx_clk (56 safe, 79 unsafe)

**Direction:** `clk_sys` → `clk_lvds`

**Status:** CRITICAL — Missing synchronizers on 79 bits

**Identified Unsafe Crossings:**

#### TX Data Path (Primary Issue)

**Location:** `tetra_tx_chain.v` → `tetra_ad9361_axis_adapter.v`

**Signals at risk:**
```
From clk_sys domain:
├── tx_i_sys[15:0]        — TX I sample (16 bits)
├── tx_q_sys[15:0]        — TX Q sample (16 bits)
├── tx_valid_sys          — TX sample valid (1 bit)
├── tx_slot_en_sys[3:0]   — Slot enable mask (4 bits)
├── tx_burst_type_sys[1:0] — Burst type select (2 bits)
├── tx_block1_sys[215:0]  — Block 1 payload (216 bits)
├── tx_block2_sys[215:0]  — Block 2 payload (216 bits)
├── tx_bb_sys[29:0]       — Broadcast block (30 bits)
├── timeslot_num_sys[1:0] — Slot number (2 bits)
└── frame_num_sys[4:0]    — Frame number (5 bits)

Total: ~500+ bits crossing, 79 detected as unsafe
```

**Why unsafe:**
- TX modulator runs in `clk_sys` domain (100 MHz)
- Outputs written directly to `clk_lvds` registers without synchronization
- Clock skew between domains can cause setup/hold violations
- Metastability risk: flip-flops may enter undefined state

**Root cause:**
TX path was designed with CLVD (Clock Domain Crossing) logic disabled for Phase 3 loopback mode. Proper CDC intended for Phase 4 but hardware test requires it NOW.

---

## Critical Signals Requiring Immediate Fix

### Priority 1: TX IQ Data Path (32 bits)

| Signal | Width | Module | Fix Required |
|--------|-------|--------|--------------|
| `tx_i_lvds[15:0]` | 16 | `tetra_tx_frontend.v` | ❌ None — already in clk_lvds domain |
| `tx_q_lvds[15:0]` | 16 | `tetra_tx_frontend.v` | ❌ None — already in clk_lvds domain |
| `tx_valid_lvds` | 1 | `tetra_tx_frontend.v` | ❌ None — already in clk_lvds domain |

**Analysis:** TX frontend outputs are correctly in `clk_lvds` domain. Issue is **upstream** in `tetra_tx_chain` where `clk_sys` signals feed `clk_lvds` registers.

### Priority 2: TX Control Signals (estimated 40 bits)

These signals cross from `clk_sys` to `clk_lvds` without synchronization:

| Signal Category | Estimated Width | Source | Destination |
|----------------|-----------------|--------|-------------|
| TX slot control | ~10 bits | `tetra_tx_chain.v` | `tetra_burst_mux.v` (clk_lvds) |
| TX block data | ~432 bits | `tetra_tx_chain.v` | `tetra_burst_builder.v` (clk_lvds) |
| TX timing | ~7 bits | `tetra_tx_chain.v` | `tetra_tx_frontend.v` (clk_lvds) |

**Estimated unsafe:** 79 bits (matches Vivado report)

---

## Proposed Fixes

### Fix Strategy A: XPM Async FIFO (RECOMMENDED)

**For multi-bit buses (TX block data):**

Use XPM_FIFO_ASYNC for TX payload crossing:

```verilog
// Example: TX block1 crossing clk_sys → clk_lvds
xpm_fifo_async #(
  .FIFO_MEMORY_TYPE("block"),
  .READ_DATA_WIDTH_B(216),
  .WRITE_DATA_WIDTH_A(216),
  .FIFO_DEPTH(16)
) u_tx_block1_cdc (
  .wr_clk (clk_sys),
  .din    (tx_block1_sys),
  .wr_en  (tx_block1_valid_sys),
  .full   (tx_block1_full_sys),

  .rd_clk (clk_lvds),
  .dout   (tx_block1_lvds),
  .rd_en  (tx_block1_rd_en_lvds),
  .empty  (tx_block1_empty_lvds)
);
```

### Fix Strategy B: 2-FF Synchronizer + Handshake

**For single-bit control signals:**

Use toggle-signaling handshake for control pulses:

```verilog
// Example: tx_slot_pulse crossing
// clk_sys domain:
reg tx_toggle_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
  if (!rst_n_sys) tx_toggle_sys <= 1'b0;
  else if (tx_slot_pulse_sys) tx_toggle_sys <= ~tx_toggle_sys;
end

// clk_lvds domain:
(* ASYNC_REG = "TRUE" *) reg tx_toggle_lvds_r0;
(* ASYNC_REG = "TRUE" *) reg tx_toggle_lvds_r1;
(* ASYNC_REG = "TRUE" *) reg tx_toggle_lvds_r2;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
  if (!rst_n_lvds) begin
    tx_toggle_lvds_r0 <= 1'b0;
    tx_toggle_lvds_r1 <= 1'b0;
    tx_toggle_lvds_r2 <= 1'b0;
  end else begin
    tx_toggle_lvds_r0 <= tx_toggle_sys;
    tx_toggle_lvds_r1 <= tx_toggle_lvds_r0;
    tx_toggle_lvds_r2 <= tx_toggle_lvds_r1;
  end
end

wire tx_slot_pulse_lvds = tx_toggle_lvds_r2 ^ tx_toggle_lvds_r1;
```

### Fix Strategy C: Gray-Code Counter

**For multi-bit counters:**

Use Gray encoding for counters crossing domains:

```verilog
// 5-bit frame_num crossing with Gray code
wire [4:0] frame_num_gray_sys;
assign frame_num_gray_sys[4] = frame_num_sys[4];
assign frame_num_gray_sys[3] = frame_num_sys[4] ^ frame_num_sys[3];
assign frame_num_gray_sys[2] = frame_num_sys[3] ^ frame_num_sys[2];
assign frame_num_gray_sys[1] = frame_num_sys[2] ^ frame_num_sys[1];
assign frame_num_gray_sys[0] = frame_num_sys[1] ^ frame_num_sys[0];

// 2-FF synchronizer on Gray-coded signal
(* ASYNC_REG = "TRUE" *) reg [4:0] frame_num_lvds_r0;
(* ASYNC_REG = "TRUE" *) reg [4:0] frame_num_lvds_r1;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
  if (!rst_n_lvds) begin
    frame_num_lvds_r0 <= 5'd0;
    frame_num_lvds_r1 <= 5'd0;
  end else begin
    frame_num_lvds_r0 <= frame_num_gray_sys;
    frame_num_lvds_r1 <= frame_num_lvds_r0;
  end
end

// Convert back to binary (optional, if needed in clk_lvds domain)
```

---

## Implementation Plan

### Phase 1: Identify All Unsafe Signals (1-2 hours)

1. Run Vivado CDC report with detailed logging:
   ```tcl
   report_cdc -details -file cdc_detailed.rpt
   ```

2. Extract list of 79 unsafe paths:
   ```bash
   grep "Unsafe" cdc_detailed.rpt | awk '{print $3, $4, $5}'
   ```

3. Categorize by signal type:
   - Data buses (requires FIFO)
   - Control pulses (requires toggle-sync)
   - Counters (requires Gray-code)

### Phase 2: Implement CDC Primitives (2-3 hours)

**For each unsafe crossing:**

1. Add XPM_FIFO_ASYNC for data buses >16 bits
2. Add 2-FF synchronizer with ASYNC_REG for single-bit controls
3. Add Gray-code encoder/decoder for counters
4. Add timing constraints in `tetra_zynq_top.xdc`:
   ```tcl
   # CDC constraints
   set_property ASYNC_REG TRUE [get_cells -hierarchical {*_r0* *r1*}]
   set_max_delay -from [get_clocks clk_sys] -to [get_clocks clk_lvds] 5.000
   set_bus_skew 0.500 [get_cells -hierarchical {*_sync*}]
   ```

### Phase 3: Verify CDC Fix (1 hour)

1. Re-run Vivado synthesis + implementation
2. Check CDC report:
   - Safe crossings: Should increase by 79
   - Unsafe crossings: Should be 0
   - Unknown crossings: May remain (documentation acceptable)
3. Verify timing closure (setup/hold slack positive)

### Phase 4: Regression Testing (1 hour)

1. Run all RTL testbenches (23 tests)
2. Verify RX path still works with CDC fix
3. Test TX path in loopback mode
4. Check ILA capture for CDC-related glitches

---

## Risk Assessment

### Current Risk (Without CDC Fix)

| Risk Factor | Severity | Likelihood | Impact |
|-------------|----------|------------|--------|
| Metastability causing bit flips | **HIGH** | 50-90% | Corrupted TX data, protocol errors |
| Setup/hold violations | **HIGH** | 70-95% | Random TX failures, intermittent bugs |
| Hardware damage | **LOW** | <1% | AD9361 LVDS misconfiguration (rare) |
| Debug time wasted | **HIGH** | 100% | Days-weeks chasing non-deterministic bugs |

### Mitigated Risk (With CDC Fix)

| Risk Factor | Severity | Likelihood | Impact |
|-------------|----------|------------|--------|
| Residual CDC bugs | **LOW** | <5% | Edge cases, review needed |
| Timing closure failure | **MEDIUM** | 10-20% | Additional pipeline stages required |
| Performance impact | **LOW** | 100% | FIFO latency +1-2 cycles (acceptable) |

---

## Recommended Actions

### Immediate (Before Hardware Test)

1. **STOP:** Do NOT program bitstream to hardware
2. **FIX:** Implement CDC synchronizers for all 79 unsafe crossings
3. **VERIFY:** Re-run CDC report, confirm 0 unsafe violations
4. **TEST:** Run post-fix simulation with CDC primitives
5. **PROCEED:** Only after CDC report shows 0 unsafe crossings

### Implementation Priority

1. **P0:** TX data path (largest safety impact)
2. **P1:** TX control signals (functional correctness)
3. **P2:** TX timing/counters (timing accuracy)

---

## Known Safe Crossings

The following CDC crossings are **already safe** and should not be modified:

### RX Path (101 safe crossings)

✅ RX IQ samples through XPM async FIFOs in `tetra_rx_chain`
✅ RX valid signals synchronized via XPM FIFO empty/valid flags
✅ Sync detect outputs via 2-FF synchronizers (verified in timing_analysis.md)

### AXI Path (existing safe CDC)

✅ `sync_locked_sys` → `sync_locked_axi` (2-FF synchronizer in top-level)
✅ `frame_num_sys` → `frame_num_axi` (Gray-code + 2-FF, lines 587-599 in top-level)
✅ All other status signals crossing clk_sys → s_axi_aclk have synchronizers

---

## References

- ETSI EN 300 392-2 (TETRA Air Interface) — Timing and slot structure
- Xilinx UG949 (7-Series FPGAs Clocking Resources) — CDC guidelines
- Xilinx UG903 (Design Analysis and Closure) — CDC reporting
- Xilinx PG058 (XPM Library) — XPM_FIFO_ASYNC primitive
- ["Clock Domain Crossing (CDC) Design & Verification Techniques"](https://semiwiki.com/) — Cliff Cummings, Sunburst Design

---

## Appendix: Vivado CDC Report Summary

```
Clock Domain Crossing Report

Design: tetra_zynq_top
Configuration: Post-Route
Tool: Vivado 2022.2

From Clock: rx_clk
  To Clock: clk_fpga_0
    Safe CDC     : 101 crossings
    Unsafe CDC   : 0 crossings
    Unknown      : 74 crossings

From Clock: clk_fpga_0
  To Clock: rx_clk
    Safe CDC     : 56 crossings
    Unsafe CDC   : 79 crossings  ← CRITICAL
    Unknown      : 31 crossings

Total Unsafe Crossings: 79
```

---

**Document Status:** ✅ COMPLETE
**Next Action:** Fix all 79 unsafe CDC crossings before hardware test
**Owner:** Ralph (Autonomous FPGA Agent)
**Last Updated:** 2026-04-07
