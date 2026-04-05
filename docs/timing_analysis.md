# Clock Domain Crossing (CDC) — Timing Analysis
# Project: tetra-zynq-phy

## Clock Domains

| Domain       | Frequency     | Source                        | Notes                          |
|--------------|---------------|-------------------------------|--------------------------------|
| `clk_sys`    | 100 MHz       | Zynq PS FCLK_CLK0             | Main processing clock          |
| `clk_axi`    | 100 MHz       | Zynq PS FCLK_CLK0             | AXI bus (same source as sys)   |
| `clk_lvds`   | ~61.44 MHz    | AD9361 DATA_CLK via LVDS      | Rate depends on AD9361 config  |
| `clk_sample` | ~72 kHz       | Derived from clk_lvds via CIC | 18 kSPS × 4 oversampling       |

> **Note:** `clk_sys` and `clk_axi` are typically sourced from the same PLL
> output but are treated as independent domains throughout this design to allow
> potential frequency divergence in future configurations.

---

## CDC Register

All clock domain crossings in the design are documented here. Every entry
must reference the source module and the synchronization method used.

| Signal              | From         | To           | Method              | Width | Module                    | Status   |
|---------------------|--------------|--------------|---------------------|-------|---------------------------|----------|
| `arst_n`            | async        | `clk_sys`    | 2-FF Reset Sync     | 1     | `tetra_clk_reset.v`       | ✅ Done  |
| `arst_n`            | async        | `clk_axi`    | 2-FF Reset Sync     | 1     | `tetra_clk_reset.v`       | ✅ Done  |
| `arst_n`            | async        | `clk_lvds`   | 2-FF Reset Sync     | 1     | `tetra_clk_reset.v`       | ✅ Done  |
| `arst_n`            | async        | `clk_sample` | 2-FF Reset Sync     | 1     | `tetra_clk_reset.v`       | ✅ Done  |
| `sync_locked`       | `clk_sample` | `clk_sys`    | 2-FF Single-bit     | 1     | `tetra_rx_chain.v`        | ⏳ TBD   |
| `frame_num[5:0]`    | `clk_sample` | `clk_sys`    | Gray + 2-FF         | 6     | `tetra_frame_counter.v`   | ⏳ TBD   |
| `mac_block_data`    | `clk_sys`    | `clk_axi`    | XPM Async FIFO      | 32    | `tetra_axi_dma_bridge.v`  | ⏳ TBD   |
| `iq_sample_i[11:0]` | `clk_lvds`   | `clk_sys`    | XPM Async FIFO      | 24    | `tetra_rx_frontend.v`     | ⏳ TBD   |
| `iq_tx_i[11:0]`     | `clk_sys`    | `clk_lvds`   | XPM Async FIFO      | 24    | `tetra_tx_frontend.v`     | ⏳ TBD   |

---

## XDC Constraints for CDC

These constraints must be present in `constraints/libresdr_tetra.xdc`:

```tcl
# Reset synchronizer false paths — first FF of each 2-FF chain
# (prevents Vivado timing closure attempt across unrelated domains)
set_false_path -to [get_cells {*rst_sync0_sys*}]
set_false_path -to [get_cells {*rst_sync0_axi*}]
set_false_path -to [get_cells {*rst_sync0_lvds*}]
set_false_path -to [get_cells {*rst_sync0_sample*}]

# Single-bit CDC (to be added when modules are implemented)
# set_false_path -to [get_cells {*sync_locked_sys_r0*}]

# Async FIFO constraints are handled by XPM internally
# No additional user constraints needed for xpm_fifo_async
```

---

## Synchronization Methods Reference

### 2-FF Reset Synchronizer (used in tetra_clk_reset.v)
```
arst_n ──────────────────────────────────────────────── (async assert)
         │                    │
         └─ D→[FF0]→[FF1] ──► rst_n_domain
              clk_domain   clk_domain
```
- Assert: asynchronous (immediate)
- Deassert: synchronous (2 clock cycles after arst_n=1)
- XDC: `set_false_path -to [get_cells {*ff0*}]`

### 2-FF Single-Bit Synchronizer
```
sig_src ──► D→[FF0]→[FF1] ──► sig_dst
             clk_dst    clk_dst
```
- Use for: control signals, status flags, pulses (with toggle wrapper)
- Constraint: `set_false_path -to [get_cells {*_r0*}]`
- Minimum width of source signal: >1 cycle of destination clock

### Gray-Code + 2-FF (for counters/pointers)
```
counter_src → gray_encode → 2-FF → gray_decode → counter_dst
              (combinational)            (combinational)
```
- Use for: FIFO pointers, frame counters crossing domains
- Constraint: `set_false_path -to [get_cells {*gray_r0*}]`

### XPM Async FIFO (for data buses)
```
wr_data ──► [xpm_fifo_async] ──► rd_data
wr_clk                            rd_clk
```
- Use for: IQ sample stream, MAC block data
- XPM handles CDC internally (CDC_SYNC_STAGES ≥ 3 recommended)
- Active-HIGH rst input: connect to `!rst_n_sys` (write side)

---

## Reset Release Order

Due to frequency differences, resets release in this order after arst_n=1:

1. `rst_n_sys`    ← first  (~20 ns after arst_n)
2. `rst_n_axi`    ← first  (~20 ns after arst_n)
3. `rst_n_lvds`   ← second (~40 ns at 50 MHz, <1 µs at real 61 MHz)
4. `rst_n_sample` ← last   (~28 µs at real 72 kHz)

**Implication:** Logic in `clk_sys` domain may start executing while
`rst_n_sample` is still asserted. Any handshake between sys and sample
domains must account for this. Use `sync_locked` flag (set by sample domain)
to gate processing in sys domain.
