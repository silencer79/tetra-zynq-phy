#!/usr/bin/env python3
"""
gen_pi4dqpsk_vectors.py — Generate test vectors for tb_tetra_pi4dqpsk_demod.v

Implements the same integer CORDIC as the Verilog module to generate
ground-truth expected outputs. Run this script before simulation.

Output files:
  pi4dqpsk_iq_in.hex    — IQ input samples (32-bit: [31:16]=Q, [15:0]=I)
  pi4dqpsk_dibit_out.hex — Expected dibit outputs (2-bit, 1 per line as 8-bit hex)

Usage: python3 gen_pi4dqpsk_vectors.py
"""

import os

# ---------------------------------------------------------------------------
# Constants matching Verilog module
# ---------------------------------------------------------------------------
ATAN_TABLE = [8192, 4836, 2556, 1297, 651, 326, 163, 81, 41, 20, 10, 5, 3, 1, 1, 0]
PHASE_WIDTH  = 16
CORDIC_WIDTH = 18   # IQ_WIDTH + 2 guard bits
IQ_WIDTH     = 16

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def to_signed(v, bits):
    """Mask to `bits` width and interpret as two's-complement signed."""
    v = v & ((1 << bits) - 1)
    if v >= (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def to_hex16(v):
    """Return 4-character hex string for a 16-bit (possibly signed) value."""
    return f"{v & 0xFFFF:04x}"


# ---------------------------------------------------------------------------
# Integer CORDIC vectoring mode (matches Verilog exactly)
# ---------------------------------------------------------------------------

def cordic_phase(i_val, q_val):
    """
    Compute absolute phase of complex sample (i_val, q_val) using integer
    CORDIC vectoring.  Returns 16-bit signed phase in the range (-32768, +32767)
    where full-scale +/-32768 represents +/-pi.
    """
    # Ensure inputs are in signed 16-bit range
    x = to_signed(i_val, IQ_WIDTH)
    y = to_signed(q_val, IQ_WIDTH)

    # --- Quadrant correction (ensures xc > 0 so CORDIC converges) ---
    if x >= 0:
        xc, yc, zc = x, y, 0
    elif y >= 0:          # x < 0, y >= 0  → rotate by -pi/2
        xc, yc, zc = y, -x, 16384      # +pi/2 offset
    else:                 # x < 0, y < 0   → rotate by +pi/2
        xc, yc, zc = -y, x, -16384     # -pi/2 offset

    # --- 16 CORDIC iterations ---
    for i in range(16):
        d = 1 if yc >= 0 else -1
        y_shr = yc >> i     # arithmetic right-shift (Python ints are signed)
        x_shr = xc >> i
        xc_new = xc + d * y_shr
        yc_new = yc - d * x_shr
        # Match RTL vectoring sign convention:
        #   y >= 0 -> z += atan
        #   y <  0 -> z -= atan
        zc_new = zc + d * ATAN_TABLE[i]
        # Clamp to hardware widths
        xc = to_signed(xc_new, CORDIC_WIDTH)
        yc = to_signed(yc_new, CORDIC_WIDTH)
        zc = to_signed(zc_new, PHASE_WIDTH)

    return zc   # 16-bit signed phase


# ---------------------------------------------------------------------------
# Dibit decision (matches Verilog S_DECIDE logic)
# ---------------------------------------------------------------------------

def decide_dibit(delta):
    """Map differential phase to dibit according to pi/4-DQPSK mapping."""
    if 0 <= delta < 16384:    return 0   # dibit 00  (+pi/4 quadrant)
    elif delta >= 16384:      return 1   # dibit 01  (+3pi/4 quadrant)
    elif delta < -16384:      return 3   # dibit 11  (-3pi/4 quadrant)
    else:                     return 2   # dibit 10  (-pi/4 quadrant)


# ---------------------------------------------------------------------------
# Scenario definitions
# ---------------------------------------------------------------------------

# Scenario A — covers all four dibits (7 samples → 6 dibits, first is init)
# Amplitude A = 24576 = 0x6000
SCENARIO_A_IQ = [
    (24576,      0),        # sample 0: phase=0        (init, no dibit)
    (17378,  17378),        # sample 1: phase=+pi/4    ΔΦ=+pi/4  → dibit 00
    (-24576,     0),        # sample 2: phase=+pi      ΔΦ=+3pi/4 → dibit 01
    (-17378, 17378),        # sample 3: phase=+3pi/4   ΔΦ=-pi/4  → dibit 10
    (24576,      0),        # sample 4: phase=0        ΔΦ=-3pi/4 → dibit 11
    (17378,  17378),        # sample 5: phase=+pi/4    ΔΦ=+pi/4  → dibit 00
    (-24576,     0),        # sample 6: phase=+pi      ΔΦ=+3pi/4 → dibit 01
]
EXPECTED_DIBITS_A = [0, 1, 2, 3, 0, 1]   # 6 dibits (00, 01, 10, 11, 00, 01)

# Scenario B — boundary angles test (5 samples → 4 dibits, first is init)
# Amplitude A = 24576; angles: 0, +30°, +150°, +30°, -30°
SCENARIO_B_IQ = [
    (24576,      0),        # sample 0: phase=0        (init, no dibit)
    (21299,  12288),        # sample 1: phase=+pi/6    ΔΦ=+pi/6  ∈ [0,pi/2) → dibit 00
    (-21299, 12288),        # sample 2: phase=+5pi/6   ΔΦ=+2pi/3 ∈ [pi/2,pi)→ dibit 01
    (21299,  12288),        # sample 3: phase=+pi/6    ΔΦ=-2pi/3 ∈(-pi,-pi/2]→dibit 11
    (21299, -12288),        # sample 4: phase=-pi/6    ΔΦ=-pi/3  ∈(-pi/2,0) → dibit 10
]
EXPECTED_DIBITS_B = [0, 1, 3, 2]   # 4 dibits (00, 01, 11, 10)


# ---------------------------------------------------------------------------
# Run CORDIC on all samples and verify decisions
# ---------------------------------------------------------------------------

def process_scenario(iq_list, expected_dibits, label):
    """Run CORDIC + decision logic on an IQ sequence; print verification."""
    phases = [cordic_phase(i, q) for (i, q) in iq_list]
    dibits = []
    errors = 0
    print(f"\n--- Scenario {label} ---")
    print(f"  {'Idx':>3}  {'I':>7}  {'Q':>7}  {'Phase':>7}  {'Delta':>7}  {'Dibit':>5}  {'Exp':>5}  Status")
    for idx in range(1, len(phases)):
        delta  = to_signed(phases[idx] - phases[idx-1], PHASE_WIDTH)
        dibit  = decide_dibit(delta)
        dibits.append(dibit)
        exp    = expected_dibits[idx - 1]
        status = "OK" if dibit == exp else f"MISMATCH (expected {exp:02b})"
        if dibit != exp:
            errors += 1
        i_val, q_val = iq_list[idx]
        print(f"  {idx:>3}  {i_val:>7}  {q_val:>7}  {phases[idx]:>7}  {delta:>7}  {dibit:>5b}  {exp:>5b}  {status}")
    print(f"  Errors: {errors}")
    return dibits, errors


dibits_a, err_a = process_scenario(SCENARIO_A_IQ, EXPECTED_DIBITS_A, "A")
dibits_b, err_b = process_scenario(SCENARIO_B_IQ, EXPECTED_DIBITS_B, "B")

# Also print absolute phases for debugging
print("\n--- Absolute phases (CORDIC output) ---")
print("Scenario A:", [cordic_phase(i, q) for i, q in SCENARIO_A_IQ])
print("Scenario B:", [cordic_phase(i, q) for i, q in SCENARIO_B_IQ])

# ---------------------------------------------------------------------------
# Write hex files
# ---------------------------------------------------------------------------

script_dir = os.path.dirname(os.path.abspath(__file__))

# --- IQ input file ---
iq_hex_path = os.path.join(script_dir, "pi4dqpsk_iq_in.hex")
with open(iq_hex_path, "w") as f:
    f.write("// pi4dqpsk_iq_in.hex — [31:16]=Q [15:0]=I, one sample per line\n")
    f.write("// Scenario A (7 samples)\n")
    for (i_val, q_val) in SCENARIO_A_IQ:
        i_hex = to_hex16(i_val)
        q_hex = to_hex16(q_val)
        f.write(f"{q_hex}{i_hex}\n")
    f.write("//\n")
    f.write("// Scenario B (5 samples)\n")
    for (i_val, q_val) in SCENARIO_B_IQ:
        i_hex = to_hex16(i_val)
        q_hex = to_hex16(q_val)
        f.write(f"{q_hex}{i_hex}\n")

# --- Dibit expected output file ---
dibit_hex_path = os.path.join(script_dir, "pi4dqpsk_dibit_out.hex")
with open(dibit_hex_path, "w") as f:
    f.write("// pi4dqpsk_dibit_out.hex — expected dibit output (0-3)\n")
    f.write("// Scenario A (6 dibits)\n")
    for d in dibits_a:
        f.write(f"{d:02x}\n")
    f.write("//\n")
    f.write("// Scenario B (4 dibits)\n")
    for d in dibits_b:
        f.write(f"{d:02x}\n")

print(f"\nWrote: {iq_hex_path}")
print(f"Wrote: {dibit_hex_path}")
print(f"\nTotal errors: {err_a + err_b}")
if err_a + err_b == 0:
    print("ALL CORDIC DECISIONS MATCH EXPECTED VALUES")
else:
    print("WARNING: Some decisions did not match — check IQ values or algorithm")
