#!/usr/bin/env python3
"""
gen_ad9361_vectors.py — Testvektoren für tetra_ad9361_interface
Project: tetra-zynq-phy

Generates test vectors for the AD9361 LVDS DDR interface simulation.

AD9361 LVDS DDR timing (1R1T mode, 6 data lanes):
  - DATA_CLK cycle N  (RX_FRAME=1): 6 data lanes carry I sample
    - Rising edge  of cycle N: I[11:6]  (upper 6 bits)
    - Falling edge of cycle N: I[5:0]   (lower 6 bits)
  - DATA_CLK cycle N+1 (RX_FRAME=0): 6 data lanes carry Q sample
    - Rising edge  of cycle N+1: Q[11:6]
    - Falling edge of cycle N+1: Q[5:0]
  → Output rate = DATA_CLK / 2

AD9361 raw ADC width: 12 bits, two's complement.
FPGA output: 16-bit sign-extended.

Test scenarios:
  Scenario 1 — NORMAL:  typical IQ samples (mid-range values)
  Scenario 2 — BOUNDARY: min/max values (±2047, ±2048)
  Scenario 3 — STRESS:   alternating signs, consecutive valid outputs

Vector format (for $readmemh):
  ad9361_iq_vectors.hex:
    One 32-bit word per IQ pair
    [31:16] = expected I output (16-bit two's complement, sign-extended from 12-bit)
    [15:0]  = expected Q output (16-bit two's complement, sign-extended from 12-bit)
    Testbench extracts raw 12-bit: i_raw = word[27:16], q_raw = word[11:0]

Usage:
  python3 gen_ad9361_vectors.py
  → Writes: tb/vectors/ad9361_iq_vectors.hex
             tb/vectors/ad9361_timing_ref.txt

Reference: AD9361 Reference Manual UG-570, Chapter 5 (LVDS Interface)
           ETSI EN 300 392-2 §9.1 (TETRA symbol rate)
"""

import os
import struct


# =============================================================================
# AD9361 LVDS Parameter Reference
# =============================================================================

AD9361_ADC_BITS  = 12         # Native ADC resolution
AD9361_ADC_MAX   = 2047       # 12-bit signed max:  2^11 - 1
AD9361_ADC_MIN   = -2048      # 12-bit signed min: -2^11
DATA_LANES       = 6          # LVDS data lane pairs (covers 12-bit DDR)

# TETRA application parameters
SYMBOL_RATE_HZ   = 18_000     # 18 kSPS
OVERSAMPLE_FACTOR = 4         # 4× oversampling → 72 kSPS output
ADC_SAMPLE_RATE  = 520_000    # AD9361 minimum practical sample rate (Hz)
                               # (CIC decimation handles 520k → 72k)
DATA_CLK_HZ      = ADC_SAMPLE_RATE  # DATA_CLK = sample rate in 1R1T DDR mode

# IDDR pipeline latency (SAME_EDGE_PIPELINED)
IDDR_LATENCY_CYCLES = 1

# RX assembly pipeline latency (clk_lvds cycles from I-cycle start to valid)
RX_PIPELINE_LATENCY = 2


# =============================================================================
# Conversion Utilities
# =============================================================================

def to_12bit_twos_complement(value: int) -> int:
    """Convert signed integer to 12-bit two's complement (0..4095)."""
    assert AD9361_ADC_MIN <= value <= AD9361_ADC_MAX, \
        f"Value {value} out of 12-bit range [{AD9361_ADC_MIN}, {AD9361_ADC_MAX}]"
    return value & 0xFFF


def sign_extend_12_to_16(raw12: int) -> int:
    """Sign-extend 12-bit two's complement to 16-bit signed Python int."""
    if raw12 & 0x800:          # bit 11 is sign bit
        return raw12 | 0xF000  # extend sign into upper 4 bits
    return raw12 & 0x0FFF


def to_16bit_twos_complement(value: int) -> int:
    """Convert signed Python int to 16-bit two's complement (0..65535)."""
    return value & 0xFFFF


def ddr_rising_bits(raw12: int) -> int:
    """Extract bits driven on DATA_CLK rising edge: I[11:6]."""
    return (raw12 >> 6) & 0x3F


def ddr_falling_bits(raw12: int) -> int:
    """Extract bits driven on DATA_CLK falling edge: I[5:0]."""
    return raw12 & 0x3F


def reconstruct_from_ddr(rising6: int, falling6: int) -> int:
    """Reconstruct 12-bit raw from DDR rising/falling bits."""
    return ((rising6 & 0x3F) << 6) | (falling6 & 0x3F)


def expected_output_16bit(raw12: int) -> int:
    """Compute expected 16-bit output (sign-extended) from 12-bit raw."""
    return to_16bit_twos_complement(sign_extend_12_to_16(raw12))


# =============================================================================
# Test Sample Definitions
# =============================================================================

def generate_test_samples():
    """
    Generate test IQ sample pairs across three scenarios.

    Returns list of (i_val, q_val) tuples where values are signed integers
    in the 12-bit range [-2048, +2047].
    """
    samples = []

    # -------------------------------------------------------------------------
    # Scenario 1: NORMAL — typical TETRA IQ values (mid-range, various signs)
    # -------------------------------------------------------------------------
    # Simulate typical π/4-DQPSK constellation points
    # (scaled to match AD9361 output range for TETRA signal)
    #   I = ±707, Q = ±707  (unit circle at ±1/√2, scaled to ~35% of ADC range)
    normal_samples = [
        (  707,   707),   # +π/4 phase (Dibit 00)
        ( -707,   707),   # +3π/4 phase (Dibit 01)
        (  707,  -707),   # -π/4 phase (Dibit 10)
        ( -707,  -707),   # -3π/4 phase (Dibit 11)
        (  100,   200),   # arbitrary mid-range
    ]
    samples.extend(("NORMAL", i, q) for i, q in normal_samples)

    # -------------------------------------------------------------------------
    # Scenario 2: BOUNDARY — min/max ADC values
    # -------------------------------------------------------------------------
    boundary_samples = [
        ( 2047,  2047),   # both max positive
        (-2048, -2048),   # both max negative
        ( 2047, -2048),   # I max pos, Q max neg
        (-2048,  2047),   # I max neg, Q max pos
        (    1,    -1),   # near-zero
    ]
    samples.extend(("BOUNDARY", i, q) for i, q in boundary_samples)

    # -------------------------------------------------------------------------
    # Scenario 3: STRESS — rapid alternation, verify consecutive outputs
    # -------------------------------------------------------------------------
    # Fast alternating pattern to verify the pipeline handles
    # continuous back-to-back IQ pairs without data loss
    stress_samples = [
        ( 1024,  -512),
        ( -512,  1024),
        (  256,  -128),
        ( -128,   256),
        (   64,   -32),
    ]
    samples.extend(("STRESS", i, q) for i, q in stress_samples)

    return samples


# =============================================================================
# Vector Verification
# =============================================================================

def verify_ddr_roundtrip(i_val: int, q_val: int) -> bool:
    """
    Verify that the DDR encoding and decoding roundtrip is lossless.

    Simulates what the AD9361 does (encode) and what the FPGA does (decode),
    then checks the final 16-bit output matches the expected sign-extended value.
    """
    # Step 1: AD9361 converts ADC value to DDR bits
    i_raw = to_12bit_twos_complement(i_val)
    q_raw = to_12bit_twos_complement(q_val)

    # Step 2: AD9361 drives DDR pins (rising/falling edges)
    i_rise = ddr_rising_bits(i_raw)
    i_fall = ddr_falling_bits(i_raw)
    q_rise = ddr_rising_bits(q_raw)
    q_fall = ddr_falling_bits(q_raw)

    # Step 3: FPGA IDDR captures (functional model)
    i_reconstructed = reconstruct_from_ddr(i_rise, i_fall)
    q_reconstructed = reconstruct_from_ddr(q_rise, q_fall)

    # Step 4: FPGA sign-extends to 16 bits
    i_out16 = expected_output_16bit(i_reconstructed)
    q_out16 = expected_output_16bit(q_reconstructed)

    # Step 5: Verify matches original value
    i_expected = to_16bit_twos_complement(i_val)
    q_expected = to_16bit_twos_complement(q_val)

    return (i_out16 == i_expected) and (q_out16 == q_expected)


# =============================================================================
# Hex File Generation
# =============================================================================

def generate_hex_vectors(samples: list) -> str:
    """
    Generate $readmemh compatible hex vector file.

    Format per line (32-bit word):
      [31:16] expected I output (16-bit two's complement)
      [15:0]  expected Q output (16-bit two's complement)

    The testbench extracts the raw 12-bit values as:
      i_raw = word[27:16]  (i.e., i_out16[11:0])
      q_raw = word[11:0]   (i.e., q_out16[11:0])
    This works because sign extension means bits[15:12] of a 16-bit
    sign-extended value are always equal to bit[11] of the 12-bit value,
    so word[27:16] == i_raw[11:0] unchanged.
    """
    lines = []
    lines.append("// ad9361_iq_vectors.hex")
    lines.append("// Format: [31:16]=expected_I_16bit [15:0]=expected_Q_16bit")
    lines.append("// One 32-bit word per IQ sample pair")
    lines.append("// Generated by gen_ad9361_vectors.py")
    lines.append("")

    current_scenario = None
    for entry in samples:
        scenario, i_val, q_val = entry

        if scenario != current_scenario:
            lines.append(f"// --- Scenario: {scenario} ---")
            current_scenario = scenario

        i_raw  = to_12bit_twos_complement(i_val)
        q_raw  = to_12bit_twos_complement(q_val)
        i_out  = expected_output_16bit(i_raw)
        q_out  = expected_output_16bit(q_raw)
        word   = ((i_out & 0xFFFF) << 16) | (q_out & 0xFFFF)

        comment = (f"I={i_val:+5d} (0x{i_raw:03X}) "
                   f"Q={q_val:+5d} (0x{q_raw:03X}) "
                   f"→ out I=0x{i_out:04X} Q=0x{q_out:04X}")
        lines.append(f"{word:08X}  // {comment}")

    return "\n".join(lines) + "\n"


# =============================================================================
# Timing Reference
# =============================================================================

def generate_timing_reference() -> str:
    """Generate human-readable timing reference for the testbench."""
    lines = []
    lines.append("=" * 70)
    lines.append("AD9361 LVDS DDR Interface — Timing Reference")
    lines.append("Module: tetra_ad9361_interface")
    lines.append("Project: tetra-zynq-phy")
    lines.append("=" * 70)
    lines.append("")
    lines.append("AD9361 DDR LVDS data format (1R1T mode):")
    lines.append("")
    lines.append("  Cycle N   (RX_FRAME=1 / I sample):")
    lines.append(f"    Rising  edge: DATA[5:0] = I[11:6]  (upper {DATA_LANES} bits)")
    lines.append(f"    Falling edge: DATA[5:0] = I[5:0]   (lower {DATA_LANES} bits)")
    lines.append("")
    lines.append("  Cycle N+1 (RX_FRAME=0 / Q sample):")
    lines.append(f"    Rising  edge: DATA[5:0] = Q[11:6]  (upper {DATA_LANES} bits)")
    lines.append(f"    Falling edge: DATA[5:0] = Q[5:0]   (lower {DATA_LANES} bits)")
    lines.append("")
    lines.append("FPGA IDDR capture (SAME_EDGE_PIPELINED mode):")
    lines.append(f"  Latency: {IDDR_LATENCY_CYCLES} clk_lvds cycle")
    lines.append("  At rising edge N+1:")
    lines.append("    Q1 = data from rising  edge of cycle N")
    lines.append("    Q2 = data from falling edge of cycle N")
    lines.append("  Both Q1, Q2 available at the same (N+1) rising edge")
    lines.append("")
    lines.append("RX Assembly pipeline (clk_lvds domain):")
    lines.append("  Stage 0 (IDDR):    DDR capture, 1 cycle latency")
    lines.append("  Stage 1 (detect):  frame edge detection + I/Q assembly")
    lines.append(f"  Total latency: {RX_PIPELINE_LATENCY} clk_lvds cycles from I-cycle start to valid output")
    lines.append("")
    lines.append("Testbench timing (for rx_valid check):")
    lines.append("  After sending I cycle (posedge): +2 clk cycles → rx_valid pulse")
    lines.append("")
    lines.append("TETRA application context:")
    lines.append(f"  Symbol rate:     {SYMBOL_RATE_HZ:,} SPS")
    lines.append(f"  Oversampling:    {OVERSAMPLE_FACTOR}×")
    lines.append(f"  clk_sample:      {SYMBOL_RATE_HZ * OVERSAMPLE_FACTOR:,} Hz (derived from clk_lvds via CIC)")
    lines.append(f"  AD9361 rate:     {ADC_SAMPLE_RATE:,} SPS (minimum practical)")
    lines.append(f"  DATA_CLK (LVDS): {DATA_CLK_HZ:,} Hz (= AD9361 sample rate in DDR mode)")
    lines.append(f"  clk_lvds period: {1e9 / DATA_CLK_HZ:.1f} ns")
    lines.append(f"  IQ pair rate:    {DATA_CLK_HZ / 2:,} Hz (DATA_CLK / 2)")
    lines.append("")
    lines.append("Bit ordering on LVDS data lanes:")
    lines.append("  Lane 5 (MSB) → Lane 0 (LSB)")
    lines.append("  Rising  edge: bits [11:6]  (D[5]=I/Q MSB → D[0]=bit6)")
    lines.append("  Falling edge: bits [5:0]   (D[5]=bit5  → D[0]=LSB)")
    lines.append("")
    lines.append("Sign extension (12→16 bit):")
    lines.append("  rx_i_lvds[15:12] = {4{i_raw[11]}}  (replicate sign bit)")
    lines.append("  rx_i_lvds[11:0]  = i_raw[11:0]")
    lines.append("")

    # Print DDR decode table for all 4 π/4-DQPSK constellation points
    lines.append("π/4-DQPSK constellation DDR encoding example:")
    lines.append(f"  {'I_val':>7} {'I_raw':>6} {'I_rise':>7} {'I_fall':>7} "
                 f"{'Q_val':>7} {'Q_raw':>6} {'Q_rise':>7} {'Q_fall':>7} {'I_16b':>6} {'Q_16b':>6}")
    lines.append("  " + "-" * 74)
    for i_val, q_val in [(707, 707), (-707, 707), (707, -707), (-707, -707)]:
        i_raw = to_12bit_twos_complement(i_val)
        q_raw = to_12bit_twos_complement(q_val)
        i_r, i_f = ddr_rising_bits(i_raw), ddr_falling_bits(i_raw)
        q_r, q_f = ddr_rising_bits(q_raw), ddr_falling_bits(q_raw)
        i16 = expected_output_16bit(i_raw)
        q16 = expected_output_16bit(q_raw)
        lines.append(f"  {i_val:>7} 0x{i_raw:03X}  0x{i_r:02X}    0x{i_f:02X}   "
                     f"{q_val:>7} 0x{q_raw:03X}  0x{q_r:02X}    0x{q_f:02X}   "
                     f"0x{i16:04X} 0x{q16:04X}")

    lines.append("")
    lines.append("XDC constraints (no additional CDC needed for IBUFDS/BUFG path):")
    lines.append("  create_clock -period <T> -name clk_lvds [get_ports ad9361_data_clk_p]")
    lines.append("  set_input_jitter clk_lvds 0.1")
    lines.append("")

    return "\n".join(lines)


# =============================================================================
# Main
# =============================================================================

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    # Generate test samples
    samples = generate_test_samples()
    total = len(samples)

    # Verify all samples pass the DDR roundtrip test
    print("Verifying DDR roundtrip for all test samples...")
    fail_count = 0
    for scenario, i_val, q_val in samples:
        if not verify_ddr_roundtrip(i_val, q_val):
            print(f"  FAIL: {scenario} I={i_val} Q={q_val}")
            fail_count += 1
        else:
            i_raw = to_12bit_twos_complement(i_val)
            q_raw = to_12bit_twos_complement(q_val)
            i16   = expected_output_16bit(i_raw)
            q16   = expected_output_16bit(q_raw)
            print(f"  OK: {scenario:8s} I={i_val:+5d}→0x{i16:04X}  Q={q_val:+5d}→0x{q16:04X}")

    if fail_count:
        print(f"\nERROR: {fail_count} roundtrip failures!")
        raise SystemExit(1)
    print(f"All {total} samples passed roundtrip verification.\n")

    # Write hex vector file
    hex_path = os.path.join(script_dir, "ad9361_iq_vectors.hex")
    hex_content = generate_hex_vectors(samples)
    with open(hex_path, "w") as f:
        f.write(hex_content)
    print(f"Written: {hex_path}  ({total} IQ pairs)")

    # Write timing reference
    ref_path = os.path.join(script_dir, "ad9361_timing_ref.txt")
    ref_content = generate_timing_reference()
    with open(ref_path, "w") as f:
        f.write(ref_content)
    print(f"Written: {ref_path}")

    print()
    print(generate_timing_reference())

    # Sanity check: total sample count
    scenarios = {"NORMAL": 0, "BOUNDARY": 0, "STRESS": 0}
    for s, _, _ in samples:
        scenarios[s] += 1
    print("Sample counts by scenario:")
    for name, count in scenarios.items():
        print(f"  {name}: {count} IQ pairs")
    print(f"  TOTAL: {total} IQ pairs → {total * 2} DATA_CLK cycles of DDR input")
    print()
    print("Testbench: expects rx_valid_lvds pulse after each pair")
    print(f"           pipeline latency = {RX_PIPELINE_LATENCY} clk_lvds cycles from I-cycle start")
    print()
    print("All checks PASSED.")


if __name__ == "__main__":
    main()
