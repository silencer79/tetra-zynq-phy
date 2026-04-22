# tetra-zynq-phy Documentation

**Project:** Full TETRA Base Station (PHY/LMAC/MAC/MLE/CMCE) on FPGA
**Target:** LibreSDR (Zynq-7020 + AD9361)
**Status:** Phase 5 COMPLETE (UL RA-decode HW-verified) → Phase 6 starting (MAC/MLE/CMCE as RTL FSMs)

---

## Quick Links

- **[BS Stack Plan](./plan_tetra_bs_stack.md)** — M1..M4 roadmap with architectural decisions
- **[Module Status Overview](./module_status.md)** — All modules with simulation results
- **[Resource Estimates](./resource_estimate.md)** — FPGA utilization tracking
- **[AXI AD9361 Integration](./axi_ad9361_integration.md)** — IP block integration guide
- **[Deployment Guide](./deployment_guide.md)** — Hardware testing procedures

---

## Project Status (2026-04-22)

### Phase 5: ✅ COMPLETE — UL RA-burst decode hardware-verified

**RTL Development:** UL burst-capture + demod + SCH/HU Viterbi + MAC-ACCESS parser
**Simulation:** tb_ul_wav_chain 5/5 CRC-OK (== Python baseline)
**Hardware:** Live-decode of MTP3550 RA-bursts on LibreSDR (SSI=523, addr_type=2)
**Timing:** WNS 0.000 ns on clk_fpga_0 (Viterbi saturation-only fix)

### Phase 6: 🚧 STARTING — MAC/MLE/CMCE as RTL FSMs

Architecture decision 2026-04-22: **FPGA-heavy stack**. MAC/MLE/CMCE run as RTL
finite-state machines in the PL. ARM holds only the subscriber/group database
and acts as admin/provisioning plane (no real-time path).

See `plan_tetra_bs_stack.md` for the M1–M4 milestone breakdown and the new RTL
module catalogue (registration FSM, shadow-BRAM, active-session table, CMCE
group-call FSM, voice-relay FIFO, paging FSM).

### Module Summary

| Category | Modules | Status |
|----------|---------|--------|
| **RX Chain** | 8 modules | ✅ All PASS |
| **TX Chain** | 6 modules | ✅ All PASS |
| **LMAC** | 8 modules | ✅ All PASS |
| **Infrastructure** | 3 modules | ✅ All PASS |
| **Integration** | Top-level + Adapter | ✅ Ready |

### Resource Utilization (Estimated)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| **LUT** | ~6,905 | 53,200 | ~13% |
| **FF** | ~11,238 | 106,400 | ~11% |
| **DSP48E1** | 3 | 220 | ~1% |
| **BRAM18k** | 0 | 280 | ~0% |

**Total Modules:** 22 RTL + 22 TB
**Lines of Code:** ~12,000 (RTL + TB)
**Test Coverage:** 100% modules with self-checking TB

---

## Architecture Highlights

### AXI AD9361 Integration

```
LibreSDR Block Design:
┌─────────────────────────────────────────┐
│ PS7 (ARM Cortex-A9)                    │
└────┬────────────────────────────────────┘
     │ AXI Interconnect
┌────┴──────────┐   ┌───────────┴──────────┐
│ axi_ad9361    │   │ tetra_zynq_top        │
│ (ADI IP)      │   │ (Custom RTL)         │
└──────┬────────┘   └─────────┬────────────┘
       │ AXI-Stream          │
       │ IQ_SAMPLES◄─────────┤
       └──────┬───────────────┘
              │ LVDS
              └─► AD9361
```

**Key Decision:** Custom LVDS interface replaced with ADI axi_ad9361 IP block
- Benefit: Proven LVDS timing, automatic AD9361 SPI config
- Adapter: `tetra_ad9361_axis_adapter.v` (7 TCs PASS)

### Clock Domains

| Domain | Frequency | Usage |
|--------|-----------|-------|
| `clk_sys` | 100 MHz | Processing pipeline |
| `clk_sample` | 72 kHz (derived) | Symbol-rate processing |
| `clk_axi` | 100 MHz | AXI bus interface |
| `l_clk` | ~4.6 MHz (DATA_CLK) | AD9361 interface |

### Signal Flow

**RX Path:**
```
AD9361 (LVDS) → tetra_ad9361_axis_adapter → rx_frontend (CIC+RRC)
  → pi4dqpsk_demod → sync_detect → burst_demux → frame_counter
  → [LMAC RX] → AXI-DMA → PS
```

**TX Path:**
```
PS → AXI-DMA → [LMAC TX] → burst_mux → burst_builder
  → pi4dqpsk_mod → rrc_filter → tx_frontend (CIC)
  → tetra_ad9361_axis_adapter → AD9361 (LVDS)
```

---

## Development Workflow

### Autonomous Agent (Ralph)

- **Communication:** `.ralph/chat.md`
- **Protocol:** `.ralph/AGENT.md`
- **Coding Rules:** `.ralph/PROMPT.md`
- **Spec:** `.ralph/CLAUDE.md`

### Quality Gates

Every module passes:
1. ✅ Code compliance (Verilog-2001 R1–R10)
2. ✅ Testbench coverage (≥3 test cases)
3. ✅ Documentation (inline + header)
4. ✅ Resource estimation (LUT/FF/DSP/BRAM)

### Testing

```bash
# Module simulation
vivado -mode batch -source scripts/vivado_sim.tcl -tclargs <module>

# Production build
vivado -mode batch -source scripts/vivado_build.tcl

# Program FPGA
vivado -mode batch -source scripts/program_fpga.tcl
```

---

## Next Steps (Phase 6 — MAC/MLE/CMCE in RTL)

Order per `plan_tetra_bs_stack.md` and `.ralph/fix_plan.md`:

1. **Subscriber-Shadow-BRAM** (`rtl/lmac/tetra_subscriber_shadow.v`) — 256 × 64 bit,
   AXI-Lite write port, FSM read port (1-cycle lookup).
2. **DB manager** (`sw/tetra_db_mgr.c`) — ARM-side subscriber/group table,
   pushes records into shadow-BRAM via AXI-Lite.
3. **Active-session table** (`rtl/lmac/tetra_active_session_table.v`) — hot-state
   BRAM (ISSI → slot allocation + state).
4. **Registration FSM** (`rtl/lmac/tetra_mle_registration_fsm.v`) — UL MAC-ACCESS
   → shadow-lookup → ACCEPT/REJECT → build D-LOC-UPDATE-ACCEPT → DL slot.
5. **D-LOCATION-UPDATE encoder** — PDU builder reusing existing channel-coding pipeline.
6. **MAC-RESOURCE encoder** — for slot allocation PDUs.
7. **Slot-content mux** (`rtl/tx/tetra_slot_content_mux.v`) — per-slot selection
   from allocation table (replaces current static filler).

**Goal:** MS completes registration without ARM being in the response path.
Success criterion = MTP3550 transitions to "registered" on hardware test.

---

## Documentation Files

| File | Purpose | Last Updated |
|------|---------|--------------|
| `README.md` | This file - Overview | 2026-04-07 |
| `module_status.md` | Detailed module status | 2026-04-07 |
| `resource_estimate.md` | FPGA utilization | 2026-04-05 |
| `architecture.md` | Design decisions | TBD |
| `axi_ad9361_integration.md` | Integration guide | TBD |
| `deployment_guide.md` | Hardware procedures | TBD |

---

## References

- **ETSI EN 300 392-2:** TETRA V+D Air Interface
- **ADI HDL Library:** `library/axi_ad9361`
- **tetra-bluestation:** Rust reference (GitHub: MidnightBlueLabs)
- **LibreSDR Schematic:** Hardware documentation
- **Xilinx UG585:** Zynq-7000 TRM

---

**Last Updated:** 2026-04-22
**Maintained by:** Ralph (autonomous FPGA agent)
**Contact:** Kevin (via `.ralph/chat.md`)
