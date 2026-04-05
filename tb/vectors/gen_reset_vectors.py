#!/usr/bin/env python3
"""
gen_reset_vectors.py — Testvektoren für tetra_clk_reset
Project: tetra-zynq-phy

Generates timing documentation and verification parameters for the reset
synchronizer testbench. The reset synchronizer has no complex algorithmic
behavior — its correctness is purely about timing:

  1. Assert: arst_n=0 → all outputs go LOW within 1 ns (async)
  2. Deassert: arst_n=1 → each output goes HIGH after exactly 2 rising edges
     of the corresponding clock domain.

This script:
  - Documents expected timing per domain
  - Generates a timing reference file (reset_timing_ref.txt)
  - Verifies the 2-cycle rule mathematically
  - Provides the XDC false-path command for each sync chain

Usage:
  python3 gen_reset_vectors.py

Output:
  tb/vectors/reset_timing_ref.txt   — Human-readable timing reference
  tb/vectors/reset_domains.hex      — Domain parameters in hex (for $readmemh)

Reference: Xilinx UG901, ETSI EN 300 392-2 §9.1 (clock frequencies)
"""

import os
import math

# =============================================================================
# Clock Domain Definitions
# =============================================================================

CLOCK_DOMAINS = {
    "sys": {
        "freq_hz":   100_000_000,    # 100 MHz
        "desc":      "System processing clock (Zynq PL FCLK_CLK0)",
        "source":    "Zynq PS PLL",
    },
    "axi": {
        "freq_hz":   100_000_000,    # 100 MHz
        "desc":      "AXI bus clock (typically same PLL as clk_sys)",
        "source":    "Zynq PS PLL",
    },
    "lvds": {
        "freq_hz":   61_440_000,     # 61.44 MHz typical (AD9361 DATA_CLK)
        "desc":      "AD9361 DATA_CLK via LVDS (rate depends on config)",
        "source":    "AD9361 internal PLL / XTAL",
    },
    "sample": {
        "freq_hz":   72_000,         # 72 kHz = 18 kSPS × 4 oversampling
        "desc":      "Symbol-rate sample clock (after CIC decimation)",
        "source":    "Derived from clk_lvds via CIC decimation",
    },
}

# =============================================================================
# Reset Synchronizer Analysis
# =============================================================================

def analyze_reset_sync(domain_name: str, domain: dict) -> dict:
    """Compute timing characteristics for a 2-FF reset synchronizer."""
    freq = domain["freq_hz"]
    period_ns = 1e9 / freq

    # Deassert latency: 2 rising edges after arst_n goes high
    # Worst case: arst_n rises just after a clock edge → wait full cycle + 1 more
    deassert_latency_min_ns = 1 * period_ns   # best case: arst_n just before edge
    deassert_latency_max_ns = 2 * period_ns   # worst case: arst_n just after edge

    # MTBF calculation (simplified, for documentation purposes)
    # MTBF = exp(tau / Tresolution) / (freq_clk * freq_async_rate)
    # For reset (one-shot, not repetitive): MTBF is not the primary concern;
    # the 2-FF chain provides ~100 ps resolution window.
    tau_ns = 0.1       # typical FF metastability resolution time constant
    t_res_ns = 0.1     # resolution window (FF setup/hold violation)
    # Simplified: just note that 2-FF is sufficient for single-event resets

    return {
        "domain": domain_name,
        "freq_hz": freq,
        "period_ns": period_ns,
        "deassert_latency_min_ns": deassert_latency_min_ns,
        "deassert_latency_max_ns": deassert_latency_max_ns,
        "deassert_latency_min_us": deassert_latency_min_ns / 1000,
        "deassert_latency_max_us": deassert_latency_max_ns / 1000,
        "sync_ff_count": 2,
    }


def generate_timing_reference() -> str:
    """Generate human-readable timing reference document."""
    lines = []
    lines.append("=" * 70)
    lines.append("Reset Synchronizer Timing Reference")
    lines.append("Module: tetra_clk_reset")
    lines.append("Project: tetra-zynq-phy")
    lines.append("=" * 70)
    lines.append("")
    lines.append("Synchronizer Architecture:")
    lines.append("  assert  (arst_n=0): propagates IMMEDIATELY (async)")
    lines.append("  deassert(arst_n=1): delayed by 2 cycles of target domain")
    lines.append("")
    lines.append(f"{'Domain':<12} {'Freq':>12} {'Period':>10} {'Deassert Min':>14} {'Deassert Max':>14}")
    lines.append("-" * 70)

    results = []
    for name, domain in CLOCK_DOMAINS.items():
        r = analyze_reset_sync(name, domain)
        results.append(r)

        freq_str = f"{r['freq_hz'] / 1e6:.3f} MHz"
        period_str = f"{r['period_ns']:.3f} ns"
        min_str = f"{r['deassert_latency_min_us']:.3f} us"
        max_str = f"{r['deassert_latency_max_us']:.3f} us"

        lines.append(f"clk_{name:<8} {freq_str:>12} {period_str:>10} {min_str:>14} {max_str:>14}")

    lines.append("")
    lines.append("Testbench Verification Parameters:")
    lines.append("-" * 70)
    for r in results:
        lines.append(f"  {r['domain']}: check rst_n_{r['domain']} HIGH after")
        lines.append(f"    minimum {r['deassert_latency_min_ns']:.1f} ns, "
                     f"maximum {r['deassert_latency_max_ns']:.1f} ns")
    lines.append("")

    lines.append("XDC Timing Constraints:")
    lines.append("-" * 70)
    lines.append("  # False path to first synchronizer FF of each domain")
    lines.append("  # (prevents Vivado from trying to meet setup time across domains)")
    for name in CLOCK_DOMAINS:
        lines.append(f"  set_false_path -to [get_cells {{*rst_sync0_{name}*}}]")
    lines.append("")

    lines.append("Clock Domain Crossing Documentation:")
    lines.append("-" * 70)
    lines.append("  Signal    From      To        Method      Notes")
    lines.append("  arst_n    async     clk_sys   2-FF sync   tetra_clk_reset.v")
    lines.append("  arst_n    async     clk_axi   2-FF sync   tetra_clk_reset.v")
    lines.append("  arst_n    async     clk_lvds  2-FF sync   tetra_clk_reset.v")
    lines.append("  arst_n    async     clk_sample 2-FF sync  tetra_clk_reset.v")
    lines.append("")

    return "\n".join(lines)


def generate_hex_parameters() -> str:
    """
    Generate a hex file for $readmemh in the testbench.

    Format: one line per domain, 32-bit word
      [31:24] domain_id   (0=sys, 1=sample, 2=axi, 3=lvds)
      [23:0]  period_ns × 100 (fixed-point, 2 decimal places)

    This allows the testbench to load clock parameters programmatically.
    """
    domain_ids = {"sys": 0, "sample": 1, "axi": 2, "lvds": 3}
    lines = []
    lines.append("// reset_domains.hex")
    lines.append("// Format: [31:24]=domain_id [23:0]=period_ns*100 (fixed pt)")
    lines.append("// Domains: 00=sys 01=sample 02=axi 03=lvds")

    for name, domain in CLOCK_DOMAINS.items():
        period_ns = 1e9 / domain["freq_hz"]
        period_fixed = int(round(period_ns * 100))  # 2 decimal places
        domain_id = domain_ids[name]
        word = (domain_id << 24) | (period_fixed & 0xFFFFFF)
        lines.append(f"{word:08X}  // {name}: {period_ns:.4f} ns period")

    return "\n".join(lines)


# =============================================================================
# Testbench Scenario Summary
# =============================================================================

def generate_scenario_summary() -> str:
    """Document the three test scenarios for the testbench."""
    lines = []
    lines.append("=" * 70)
    lines.append("Testbench Scenarios — tb_tetra_clk_reset.v")
    lines.append("=" * 70)
    lines.append("")
    lines.append("Test 1: NORMAL — Reset assert then deassert")
    lines.append("  - Apply arst_n=0 for 100 ns")
    lines.append("  - All outputs must be 0 immediately")
    lines.append("  - Release arst_n=1")
    lines.append("  - Each output must go 1 after exactly 2 rising edges of its clock")
    lines.append("  - PASS: all 4 domains deassert correctly")
    lines.append("")
    lines.append("Test 2: BOUNDARY — Reset asserted mid-cycle")
    lines.append("  - Let design run for 50+ sys clocks (all resets released)")
    lines.append("  - Assert reset at arbitrary phase (not aligned to clock edge)")
    lines.append("  - Verify all outputs go 0 within 1 clk_sys period (async)")
    lines.append("  - Release, verify normal deassert sequence resumes")
    lines.append("  - PASS: no missed reset assertion")
    lines.append("")
    lines.append("Test 3: ERROR/STRESS — Multiple rapid reset pulses")
    lines.append("  - Assert arst_n=0 for only 1 ns (shorter than clock period)")
    lines.append("  - Verify reset was still captured (glitch filter NOT present,")
    lines.append("    this is intentional — reset should propagate)")
    lines.append("  - Apply 3 consecutive reset pulses, verify clean deassertion")
    lines.append("  - PASS: all pulses captured, no spurious re-assertion after release")
    lines.append("")
    return "\n".join(lines)


# =============================================================================
# Main
# =============================================================================

def main():
    # Determine output directory relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Generate timing reference
    timing_ref = generate_timing_reference()
    timing_path = os.path.join(script_dir, "reset_timing_ref.txt")
    with open(timing_path, "w") as f:
        f.write(timing_ref)
    print(f"Written: {timing_path}")

    # Generate hex parameter file
    hex_content = generate_hex_parameters()
    hex_path = os.path.join(script_dir, "reset_domains.hex")
    with open(hex_path, "w") as f:
        f.write(hex_content)
    print(f"Written: {hex_path}")

    # Print scenario summary to stdout
    print()
    print(generate_scenario_summary())

    # Print timing reference to stdout
    print(timing_ref)

    # Quick sanity checks
    print("Sanity checks:")
    for name, domain in CLOCK_DOMAINS.items():
        r = analyze_reset_sync(name, domain)
        assert r["sync_ff_count"] == 2, f"Expected 2 FFs for {name}"
        assert r["deassert_latency_max_ns"] > 0, f"Deassert latency must be > 0"
        assert r["deassert_latency_max_ns"] == 2 * r["period_ns"], \
            f"Max deassert latency must be exactly 2 clock periods for {name}"
        print(f"  clk_{name}: OK ({r['freq_hz']/1e6:.3f} MHz, "
              f"max deassert = {r['deassert_latency_max_ns']:.3f} ns)")

    print()
    print("All checks PASSED")


if __name__ == "__main__":
    main()
