# Deprecated Modules

This directory contains archived RTL modules that are no longer used in synthesis but retained for reference.

## Contents

### `rtl/tetra_ad9361_interface.v`
**Archived:** 2026-04-06
**Reason:** Replaced by ADI `axi_ad9361` IP block

This was a custom LVDS DDR interface for the AD9361, manually instantiating:
- IBUFDS differential input buffers
- IDDR (SAME_EDGE_PIPELINED) for DDR capture
- ODDR for DDR output
- OBUFDS differential output buffers
- BUFG global clock buffer

**Replaced by:**
- `axi_ad9361_0` IP (in Vivado Block Design) - handles LVDS DDR internally
- `rtl/tetra_ad9361_axis_adapter.v` - fabric-side adapter

**Why replaced:**
- ADI IP provides more robust LVDS timing (production-tested)
- Better integration with ADI tools (libiio, calibration)
- Reduced maintenance burden (ADI maintains IP)
- See `docs/adi_ip_integration.md` for full rationale

### `tb/tb_tetra_ad9361_interface.v`
**Archived:** 2026-04-06
**Reason:** Testbench for deprecated interface module

**Replaced by:**
- `tb/tb_tetra_ad9361_axis_adapter.v` - testbench for active adapter

---

## For Reference Only

These files are **not** included in:
- Synthesis build (`scripts/vivado_build.tcl` excludes them)
- Simulation runs (use the adapter testbenches instead)

They are retained for:
- Historical reference
- Comparison if future custom interface needed
- Educational purposes (shows manual DDR implementation)

---

**See also:**
- `docs/adi_ip_integration.md` - Architecture decision document
- `rtl/tetra_ad9361_axis_adapter.v` - Active replacement
