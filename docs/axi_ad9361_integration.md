# AXI AD9361 Integration Guide
**Project:** tetra-zynq-phy
**Date:** 2026-04-07
**Status:** Architecture designed, implementation pending

---

## Overview

This document describes the integration of the Analog Devices `axi_ad9361` IP block with the TETRA PHY/LMAC design, replacing the custom LVDS interface.

---

## Architecture Decision

### Previous Design (Custom LVDS)

```
tetra_ad9361_interface.v (CUSTOM)
  └─► Direct LVDS DDR I/O handling
  └─► AD9361 SPI configuration in PL
  └─► Frame alignment + sign extension
```

**Problems:**
- Complex DDR timing closure
- Manual AD9361 register config
- Debugging difficulty
- Reinvent proven solution

### New Design (ADI IP Block)

```
axi_ad9361 (ADI IP) ──► tetra_ad9361_axis_adapter ──► rx_chain / tx_chain
  ├─► LVDS DDR handled by proven IP
  ├─► Automatic AD9361 SPI config
  └─► AXI-Stream fabric interface
```

**Benefits:**
- ✅ Proven timing closure (openwifi, LibreSDR)
- ✅ AD9361 SPI config automated
- ✅ Simpler debug (ILA in fabric)
- ✅ Reduced development risk

---

## Integration Components

### 1. AXI AD9361 IP (Analog Devices)

**Source:** `adi-hdl/library/axi_ad9361`
**License:** Apache-2.0

**Ports:**
| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `l_clk` | Output | 1 | DATA_CLK (fabric clock) |
| `adc_*` | Output | 16-bit | ADC I/Q data + valid/enable |
| `dac_*` | Input | 16-bit | DAC I/Q data + valid/enable |
| `s_axi_*` | — | — | AXI-Lite configuration interface |
| `enable` | Input | 1 | IP enable (from PS GPIO) |

**Configuration:**
- Sampling rate: 4.608 MSPS (TETRA × 256)
- LVDS mode: DDR, CMOS compatible
- Data format: 12-bit → 16-bit sign-extended

### 2. tetra_ad9361_axis_adapter.v

**Purpose:** AXI-Stream ↔ TETRA internal interface

**RX Path (Combinatorial):**
```
adc_data_i0/q0 → rx_i/q_lvds (no registers)
adc_valid_i0 → rx_valid_lvds
```

**TX Path (Registered Hold):**
```
tx_i/q_lvds + tx_valid → dac_data_i0/q0 (sample-and-hold)
```

**Test Results:**
- ✅ 7/7 test cases PASS
- ✅ RX compositional passthrough verified
- ✅ TX hold behavior verified
- ✅ Reset behavior verified

**Resources:**
- ~5 LUT, ~32 FF, 0 DSP, 0 BRAM

---

## Vivado Block Design Integration

### Step 1: Add axi_ad9361 IP

1. **Repository Setup:**
   ```tcl
   set_property ip_repo_paths {\
     ad936_hdl/library \
   } [current_project]
   update_ip_catalog
   ```

2. **Add IP:**
   - Right-click Block Design → Add IP
   - Search: `axi_ad9361`
   - Double-click to add

### Step 2: Configure IP

**Parameters:**
| Parameter | Value | Notes |
|-----------|-------|-------|
| `ID` | 0 | Single AD9361 |
| `DEVICE_TYPE` | 0 | AD9361 (not AD9364) |
| `ADC_DATAFORMAT_DISABLE` | 0 | Enable data format |
| `ADCDDRCLKEDGE` | 1 | DDR edge selection |
| `DACDDRCLKEDGE` | 1 | DDR edge selection |

### Step 3: Connect Fabric Interface

**Clock:** `l_clk` → PL fabric clock (DATA_CLK)
**AXI-Stream:**
```
axi_ad9361.adc_0 ──► tetra_ad9361_axis_adapter (RX)
tetra_ad9361_axis_adapter ──► axi_ad9361.dac_0 (TX)
```

### Step 4: Connect PS Interface

- **AXI-Lite:** PS M_AXI_GP0 → AXI Interconnect → axi_ad9361.s_axi
- **GPIO:** PS GPIO → axi_ad9361.enable
- **Interrupt:** axi_ad9361.irq → PS IRQ controller

### Step 5: External Ports

- **LVDS:** `rx_clk_p/n`, `rx_data_p/n[5:0]`, `tx_clk_p/n`, `tx_data_p/n[5:0]`
- **Connect to LibreSDR pins** (see `constraints/libresdr_tetra.xdc`)

---

## Timing Constraints

### DATA_CLK Domain

**Clock Definition:**
```tcl
create_generated_clock -name l_clk \
  -source [get_pins axi_ad9361_inst/l_clk] \
  [get_pins axi_ad9361_inst/l_clk]
```

**Constraints:**
- Period: ~217 ns (4.608 MHz)
- Fabric processing: 100 MHz (clk_sys)
- CDC handled by XPM async FIFOs

### Removal of Custom Constraints

**Delete from XDC:**
```tcl
# REMOVE: Custom LVDS timing (now handled by IP)
# - rx_clk_p/n constraints
# - tx_clk_p/n constraints
# - DATA_CLK PLL constraints
```

---

## Software Interface

### AD9361 Configuration (via axi_ad9361)

**No manual SPI writes needed!**

The axi_ad9361 IP handles:
- PLL locking
- Filter configuration
- Gain control
- TX attenuation

**PS Software only needs to:**
1. Enable IP (GPIO high)
2. Check PLL locked status
3. Configure TETRA-specific parameters (via AXI-Lite register bank)

### AXI-Lite Register Access

**Base Address:** `0x4000_0000` (configurable)

**TETRA Registers:** See `docs/register_map.md` (to be created)

---

## Testing Strategy

### Simulation

1. **axi_ad9361 IP Model:**
   - Use ADI behavioral model (included)
   - Simulates AD9361 ADC/DAC data interface

2. **Integration Test:**
   - `tb_tetra_ad9361_axis_adapter.v` (✅ PASS)
   - `tb_tetra_rx_chain.v` (component test)
   - `tb_tetra_tx_chain.v` (component test)

### Hardware Testing

1. **ILA Probes:**
   - `sync_locked_sys`
   - `burst_valid_sys`
   - `rx_valid_lvds`
   - `tx_valid_lvds`

2. **Test Procedure:**
   - Program FPGA
   - Enable AD9361 IP (GPIO)
   - Check PLL status
   - Capture ILA during RX burst
   - Verify sync_locked assertion

---

## Resource Impact

### Removed

- `tetra_ad9361_interface.v` (custom LVDS)
- ~150 LUT, ~100 FF

### Added

- `axi_ad9361` IP (ADI)
- `tetra_ad9361_axis_adapter.v`
- ~5 LUT, ~32 FF

### Net Change

- **LUT:** -145 (custom) + IP resources
- **FF:** -68 (custom) + IP resources
- **DSP:** No change (0)
- **BRAM:** IP uses ~2 BRAM18k (internal FIFOs)

---

## Migration Checklist

### Phase 1: Simulation (Week 1)

- [x] Create `tetra_ad9361_axis_adapter.v`
- [x] Write adapter testbench (✅ PASS)
- [ ] Update top-level instantiation
- [ ] Test rx_chain with adapter
- [ ] Test tx_chain with adapter

### Phase 2: Vivado Integration (Week 1)

- [ ] Import ADI IP repository
- [ ] Create Block Design
- [ ] Add axi_ad9361 IP
- [ ] Connect fabric interface
- [ ] Update constraints

### Phase 3: Hardware Testing (Week 2)

- [ ] Synthesize + implement
- [ ] Verify timing closure
- [ ] Program LibreSDR
- [ ] Capture ILA traces
- [ ] Verify RX path

### Phase 4: Full-Duplex (Week 3)

- [ ] Enable TX path
- [ ] Full-duplex test
- [ ] Performance measurement

---

## Known Issues

| Issue | Impact | Mitigation |
|-------|--------|------------|
| ADI IP documentation sparse | Integration effort | Reference openwifi project |
| Timing constraints change | Constraint update | Use ADI example designs |
| Resource overhead (BRAM) | ~2 BRAM18k used | Acceptable (280 available) |

---

## References

| Document | Source |
|----------|--------|
| ADI HDL Library | `adi-hdl/library/axi_ad9361` |
| openwifi Project | GitHub: open-sdr/openwifi |
| AD9361 Reference Manual | Analog Devices UG-570 |
| LibreSDR Block Design | `scripts/create_bd.tcl` |
| Adapter Testbench | `tb/tb_tetra_ad9361_axis_adapter.v` |

---

## Questions for Kevin

1. **IP Repository Path:** Confirm `adi-hdl` submodule location
2. **Block Design:** Create new or modify existing LibreSDR design?
3. **AD9361 Config:** Use LibreSDR defaults or TETRA-specific profile?
4. **Testing:** Start with RX-only or full-duplex from the start?

---

**Last Updated:** 2026-04-07
**Maintained by:** Ralph (autonomous FPGA agent)
**Contact:** Kevin (via `.ralph/chat.md`)
