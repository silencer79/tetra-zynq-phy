#!/usr/bin/env python3
"""
gen_pi4dqpsk_mod_vectors.py — PI/4-DQPSK Modulator Test Vector Generator

Maps Type-5 dibits to IQ constellation points via differential phase encoding.
ETSI EN 300 392-2 §9.3, Table 9.1

Phase index: 3-bit unsigned, 0..7, idx*pi/4 = absolute phase (mod 2pi)
IQ amplitude: 16-bit signed Q1.15, max = 32767 ≈ 1.0

Dibit → phase increment mapping:
  00 → +1 (mod 8)  = +pi/4
  01 → +3 (mod 8)  = +3pi/4
  10 → +7 (mod 8)  = -pi/4
  11 → +5 (mod 8)  = -3pi/4
"""

import math

# IQ constellation (16-bit Q1.15 scaling)
AMP_ONE  = 32767
AMP_SQ2  = round(math.cos(math.pi / 4) * 32767)   # 23170
AMP_ZERO = 0

IQ_TABLE = {
    0: ( AMP_ONE,   AMP_ZERO),   #   0° I=+1    Q=0
    1: ( AMP_SQ2,   AMP_SQ2),    #  45° I=+sq2  Q=+sq2
    2: ( AMP_ZERO,  AMP_ONE),    #  90° I=0     Q=+1
    3: (-AMP_SQ2,   AMP_SQ2),    # 135° I=-sq2  Q=+sq2
    4: (-AMP_ONE,   AMP_ZERO),   # 180° I=-1    Q=0
    5: (-AMP_SQ2,  -AMP_SQ2),   # 225° I=-sq2  Q=-sq2
    6: ( AMP_ZERO, -AMP_ONE),    # 270° I=0     Q=-1
    7: ( AMP_SQ2,  -AMP_SQ2),   # 315° I=+sq2  Q=-sq2
}

PHASE_INC = {
    0b00: 1,   # +pi/4
    0b01: 3,   # +3pi/4
    0b10: 7,   # -pi/4  (= +7 mod 8)
    0b11: 5,   # -3pi/4 (= +5 mod 8)
}


def modulate_symbol(phase_idx, dibit):
    """
    Apply dibit to current phase index. Returns (new_phase_idx, I, Q).
    phase_idx: int 0..7
    dibit: int 0..3
    """
    new_phase = (phase_idx + PHASE_INC[dibit]) % 8
    i, q = IQ_TABLE[new_phase]
    return new_phase, i, q


def modulate_block(dibits, start_phase=0):
    """
    Modulate a sequence of 2-bit dibits.
    Returns list of (phase_idx, I, Q) after each symbol.
    """
    phase = start_phase
    result = []
    for d in dibits:
        phase, i, q = modulate_symbol(phase, d)
        result.append((phase, i, q))
    return result


def signed16(x):
    """Convert to 16-bit two's complement string."""
    if x < 0:
        x = x + (1 << 16)
    return f"{x:04X}"


# ---------------------------------------------------------------------------
# Print test cases
# ---------------------------------------------------------------------------

print("# gen_pi4dqpsk_mod_vectors.py — PI/4-DQPSK Modulator Reference Vectors")
print("# ETSI EN 300 392-2 §9.3")
print(f"# AMP_ONE={AMP_ONE}, AMP_SQ2={AMP_SQ2}")
print()

def print_tc(name, dibits, start_phase=0):
    print(f"# {'='*60}")
    print(f"# TC: {name}")
    print(f"# Start phase idx={start_phase} ({start_phase*45}°)")
    result = modulate_block(dibits, start_phase)
    print(f"# Step  Dibit  New_Idx  Angle     I          Q")
    for i, (ph, iv, qv) in enumerate(result):
        d = dibits[i]
        angle = ph * 45
        print(f"# {i:3d}   {d:02b}     {ph}        {angle:3d}°    {iv:7d}    {qv:7d}")
    return result

# TC1: All same dibit (00 = +pi/4 each time)
# Starting at phase 0: sequence 0→1→2→3→4→5→6→7→0
tc1 = print_tc("TC1_all_dibit00_rotate_through_all",
               [0b00]*8, start_phase=0)
print()

# TC2: Alternating 00/11 — oscillates between +pi/4 and -3pi/4
# Phase: 0 → 1 → 6 → 7 → 4 → 5 → 2 → 3 → 0...
tc2 = print_tc("TC2_alternating_00_11",
               [0b00, 0b11, 0b00, 0b11, 0b00, 0b11, 0b00, 0b11], start_phase=0)
print()

# TC3: Training sequence NTS as dibits (Normal Training Sequence)
# NTS symbols from ETSI EN 300 392-2 §9.4.4.2
# Symbol sequence: +1,-1,+1,+1,+1,-1,-1,+1,+1,+1,+1,-1,+1,+1,-1,+1,-1,-1,-1,-1,+1,+1
# Converted to phase increments +pi/4 and -pi/4:
# +1 → dibit 00 (+pi/4), -1 → dibit 10 (-pi/4)
nts_symbols = [+1,-1,+1,+1,+1,-1,-1,+1,+1,+1,+1,-1,+1,+1,-1,+1,-1,-1,-1,-1,+1,+1]
nts_dibits  = [0b00 if s == +1 else 0b10 for s in nts_symbols]
tc3 = print_tc("TC3_NTS_training_sequence_22_symbols",
               nts_dibits, start_phase=0)
print()

# TC4: Short random-like pattern for comprehensive verification
tc4_dibits = [0b00, 0b01, 0b10, 0b11, 0b00, 0b01, 0b10, 0b11]
tc4 = print_tc("TC4_all_dibit_values_two_rounds",
               tc4_dibits, start_phase=0)
print()

# TC5: Start from non-zero phase
tc5 = print_tc("TC5_start_phase3",
               [0b01, 0b10, 0b00, 0b11], start_phase=3)
print()

# ---------------------------------------------------------------------------
# Full IQ table for inline testbench use
# ---------------------------------------------------------------------------
print("# IQ table (for direct testbench verification):")
for idx in range(8):
    i, q = IQ_TABLE[idx]
    print(f"# idx={idx} ({idx*45:3d}°): I={i:7d} ({signed16(i)}) Q={q:7d} ({signed16(q)})")
print()

# ---------------------------------------------------------------------------
# Encoder/decoder roundtrip check (modulate then check against demod rules)
# ---------------------------------------------------------------------------
print("# Roundtrip sanity: modulate TC1 [00 x8] then verify phase increments")
print("# Expected: each step adds +pi/4 = +8192 (IDEAL_00 in demod)")
phase = 0
prev_abs_phase_16bit = 0
for i, (d, (ph, iv, qv)) in enumerate(zip([0b00]*8, tc1)):
    # Simulated 16-bit absolute phase for this index
    abs_phase = ph * 8192  # 0..32767, with phase 4 = 32768 → wraps to -32768
    if abs_phase >= 32768:
        abs_phase -= 65536
    delta = abs_phase - prev_abs_phase_16bit
    # Handle wrap-around in [-32768, 32767]
    if delta > 32767:
        delta -= 65536
    if delta < -32768:
        delta += 65536
    print(f"# step {i}: phase_idx={ph} abs={abs_phase:7d} delta={delta:7d}  (expected +8192 for dibit 00)")
    prev_abs_phase_16bit = abs_phase
