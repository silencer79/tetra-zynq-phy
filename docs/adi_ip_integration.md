# AD9361 Interface Architecture Decision

**Date:** 2026-04-06
**Status:** Implemented
**Decision:** Use ADI `axi_ad9361` IP block instead of custom LVDS interface

---

## Context

The TETRA baseband engine needs to interface with the Analog Devices AD9361 RF transceiver on the LibreSDR board. Two approaches were considered:

1. **Custom LVDS Interface** (`tetra_ad9361_interface.v`) - Manual IBUFDS/IDDR/ODDR instantiation
2. **ADI AXI IP Block** (`axi_ad9361`) - Analog Devices reference IP with internal LVDS handling

## Decision

**Chosen:** ADI `axi_ad9361` IP block with fabric-side adapter (`tetra_ad9361_axis_adapter.v`)

## Rationale

### Advantages of ADI IP

1. **LVDS Timing Robustness**
   - ADI IP handles DDR capture internally with calibrated I/O
   - Proven in production (used in OpenWifi, BladeRF, ADI reference designs)
   - Reduces risk of timing violations at higher sample rates

2. **AD9361 Configuration Integration**
   - IP block integrates with ADI's `util_ad9361` support infrastructure
   - SPI configuration, calibration, and status monitoring handled by IP
   - Easier integration with libiio and ADI tools

3. **Maintainability**
   - ADI maintains IP across Vivado versions
   - Community support from ADI HDL library users
   - Less custom RTL to debug

4. **Future Flexibility**
   - Supports 2R2T mode (future expansion to MIMO)
   - Automatic adaptation to different AD9361 sample rates
   - Built-in TDD support

### Trade-offs

**Advantages:**
- ✅ More robust LVDS interface
- ✅ ADI support ecosystem
- ✅ Less custom debug effort
- ✅ Easier integration with existing ADI-based projects

**Disadvantages:**
- ❌ Less flexibility in I/O timing (bound to ADI IP constraints)
- ❌ Additional IP repository dependency (`adi-hdl` submodule)
- ❌ Slightly higher resource usage (IP includes debug infrastructure)

---

## Implementation

### Module Structure

```
Block Design (Vivado BD):
├── axi_ad9361_0 (ADI IP)
│   ├── LVDS DDR I/O (rx_clk_in_p/n, rx_frame_in_p/n, rx_data_in_p/n[5:0])
│   ├── AXI-Lite control interface (0x7902_0000)
│   └── Fabric ADC/DAC buses (adc_data_i0/q0, dac_data_i0/q0, l_clk)
│
└── tetra_zynq_top_0 (our PL design)
    └── tetra_ad9361_axis_adapter
        ├── Input:  adc_data_i0/q0, adc_valid_i0, l_clk
        └── Output: rx_i/q_lvds, rx_valid_lvds (tetra convention)

RTL Hierarchy:
  rtl/tetra_ad9361_axis_adapter.v  ← ACTIVE (adapter for ADI IP)
  deprecated/tetra_ad9361_interface.v  ← ARCHIVED (custom LVDS)
```

### Adapter Design

**File:** `rtl/tetra_ad9361_axis_adapter.v`

The adapter provides a thin translation layer between the ADI IP fabric interface and the TETRA RX/TX chains:

- **RX Path:** Combinatorial pass-through (`adc_data_i0` → `rx_i_lvds`)
- **TX Path:** Registered sample-and-hold (`tx_i_lvds` → `dac_data_i0`)
- **Clock:** `l_clk` from ADI IP (DATA_CLK) drives `clk_lvds` domain
- **Reset:** Active-low `rst_n_lvds` synchronous to `l_clk`

**Resource Estimate:** ~5 LUT, ~32 FF (RX is wire; TX is 2× 16-bit registers)

### Clock Domain Crossing

- `clk_lvds` (from ADI IP `l_clk`) → `clk_sys` (100 MHz): Handled by XPM async FIFO in `tetra_rx_frontend.v`
- No CDC needed for control signals (AXI-Lite registers in `clk_axi` domain run synchronous to `clk_sys`)

---

## Migration Path

**From Custom Interface to ADI IP:**

1. ✅ Adapter module written and tested (`tetra_ad9361_axis_adapter.v`)
2. ✅ Block Design updated to use `axi_ad9361_0` IP
3. ✅ `tetra_zynq_top.v` instantiates adapter (not custom interface)
4. ✅ All RTL modules expect `*_lvds` signals (clock domain naming)
5. ✅ Old interface archived in `deprecated/` directory

**Files Changed:**
- `rtl/tetra_ad9361_interface.v` → archived
- `rtl/tetra_ad9361_axis_adapter.v` → active
- `scripts/vivado_build.tcl` → excludes old interface, includes ADI IP repo
- `.ralph/PROMPT.md` → updated module priorities
- `.ralph/CLAUDE.md` → updated architecture description

---

## References

- ADI HDL Library: `adi-hdl/library/axi_ad9361/` (Apache-2.0)
- AD9361 Reference Manual: UG-570, §5 (Parallel Data Port)
- Xilinx UG585: Zynq-7000 Technical Reference Manual
- OpenWifi Project: `libresdr/system_top.v` (verified hardware integration)

---

## Notes

**Why `_lvds` Suffix?**

The signal names `rx_i_lvds`, `tx_q_lvds` etc. use the `_lvds` suffix to indicate the **clock domain** (`clk_lvds`), not the source of the signals. This follows the project's naming convention:

- `_lvds` = `clk_lvds` domain (DATA_CLK from ADI IP)
- `_sys` = `clk_sys` domain (100 MHz processing clock)
- `_sample` = `clk_sample` domain (18 kHz symbol clock)

While potentially confusing (signals don't come directly from LVDS pins), this maintains consistency across all modules and testbenches.
