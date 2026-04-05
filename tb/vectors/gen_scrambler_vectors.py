#!/usr/bin/env python3
"""
gen_scrambler_vectors.py — TETRA Scrambler Test Vector Generator

Generates scrambling sequences according to ETSI EN 300 392-2 §8.2.5.

LFSR: Galois, 32-bit, shift-right, output = LSB before shift.
Polynomial: p(x) = x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11
                 + x^10 + x^8  + x^7  + x^5  + x^4  + x^2  + x + 1
Galois feedback mask: 0x04C11DB7

LFSR initialization (§8.2.5.2):
  lfsr_init[5:0]   = CC  (Colour Code, 6 bits)
  lfsr_init[15:6]  = MCC (Mobile Country Code, 10 bits)
  lfsr_init[29:16] = MNC (Mobile Network Code, 14 bits)
  lfsr_init[31:30] = TN  (Timeslot Number, 2 bits)

Output files (in tb/vectors/):
  scrambler_tc<N>_init.hex      — 32-bit init word (8 hex digits, 1 line)
  scrambler_tc<N>_stimulus.hex  — input data bytes (8 bits/line, MSB first)
  scrambler_tc<N>_expected.hex  — expected output bytes (8 bits/line)

Vector format: $readmemh compatible, one byte per line (2 hex digits).
Testbench shifts through 8 bits per entry, MSB (bit7) first.

Usage:
  python3 tb/vectors/gen_scrambler_vectors.py
  (from project root)
"""

import os
import sys

# ---------------------------------------------------------------------------
# LFSR model (matches RTL exactly)
# ---------------------------------------------------------------------------

POLY_MASK = 0x04C11DB7  # Galois feedback mask
LFSR_MASK = 0xFFFFFFFF  # 32-bit


def lfsr_step(state: int) -> tuple:
    """Advance Galois LFSR one step. Returns (new_state, output_bit)."""
    out_bit = state & 1
    state >>= 1
    if out_bit:
        state ^= POLY_MASK
    return state & LFSR_MASK, out_bit


def scramble(lfsr_init: int, data_bits: list) -> list:
    """
    Scramble (or descramble) a list of bits using the LFSR.
    Returns list of output bits.
    The LFSR advances on each bit — consistent with data_valid=1 every cycle.
    """
    state = lfsr_init & LFSR_MASK
    out = []
    for bit in data_bits:
        state, q = lfsr_step(state)
        out.append(bit ^ q)
    return out


def descramble(lfsr_init: int, scrambled: list) -> list:
    """Descramble — identical to scramble (XOR is self-inverse)."""
    return scramble(lfsr_init, scrambled)


def compute_lfsr_init(cc: int, mcc: int, mnc: int, tn: int = 0) -> int:
    """Compute LFSR init from TETRA system identifiers (ETSI §8.2.5.2)."""
    assert 0 <= cc  <= 0x3F,   f"CC out of range: {cc}"
    assert 0 <= mcc <= 0x3FF,  f"MCC out of range: {mcc}"
    assert 0 <= mnc <= 0x3FFF, f"MNC out of range: {mnc}"
    assert 0 <= tn  <= 0x3,    f"TN out of range: {tn}"
    init = (cc & 0x3F)
    init |= (mcc & 0x3FF)  << 6
    init |= (mnc & 0x3FFF) << 16
    init |= (tn  & 0x3)    << 30
    return init & LFSR_MASK


def bits_to_bytes(bits: list) -> list:
    """Pack list of bits (MSB first per byte) into list of byte values."""
    result = []
    for i in range(0, len(bits), 8):
        chunk = bits[i:i+8]
        while len(chunk) < 8:
            chunk.append(0)   # pad last byte
        byte_val = sum(b << (7 - j) for j, b in enumerate(chunk))
        result.append(byte_val)
    return result


def write_hex_file(path: str, values: list, width_bytes: int = 1) -> None:
    """Write list of integer values to $readmemh-compatible hex file."""
    fmt = f"{{:0{width_bytes * 2}x}}"
    with open(path, "w") as f:
        for v in values:
            f.write(fmt.format(v) + "\n")
    print(f"  Written: {path} ({len(values)} entries)")


def verify_symmetry(init: int, data: list) -> bool:
    """Verify that descramble(scramble(data)) == data."""
    scrambled = scramble(init, data)
    recovered = descramble(init, scrambled)
    return recovered == data


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

TEST_CASES = [
    # TC1: Nominal — realistic TETRA parameters, NDB block length (216 bits)
    {
        "name": "tc1_nominal",
        "desc": "Nominal: CC=1, MCC=1, MNC=1, TN=0, 216 bits (NDB block)",
        "cc": 0x01, "mcc": 0x001, "mnc": 0x0001, "tn": 0,
        "n_bits": 216,
        "data_gen": lambda n: [(i * 3 + 7) % 2 for i in range(n)],  # pseudo-random
    },
    # TC2: All-zeros data — output = scrambling sequence itself
    {
        "name": "tc2_zeros_data",
        "desc": "All-zeros data: output = pure scrambling sequence, 216 bits",
        "cc": 0x15, "mcc": 0x123, "mnc": 0x0ABC, "tn": 2,
        "n_bits": 216,
        "data_gen": lambda n: [0] * n,
    },
    # TC3: All-ones data, max identifiers, SCH/F block length (432 bits)
    {
        "name": "tc3_ones_schf",
        "desc": "All-ones data, max ID params, SCH/F length (432 bits)",
        "cc": 0x3F, "mcc": 0x3FF, "mnc": 0x3FFF, "tn": 3,
        "n_bits": 432,
        "data_gen": lambda n: [1] * n,
    },
    # TC4: Loopback — scramble then descramble, verify identity
    {
        "name": "tc4_loopback",
        "desc": "Loopback: scramble(descramble(data)) == data, 432 bits",
        "cc": 0x2A, "mcc": 0x155, "mnc": 0x1234, "tn": 1,
        "n_bits": 432,
        "data_gen": lambda n: [(i * 7 ^ (i >> 3)) % 2 for i in range(n)],
    },
    # TC5: Edge — near-zero init (CC=1 only, rest=0)
    {
        "name": "tc5_min_init",
        "desc": "Minimum non-zero init: CC=1, MCC=0, MNC=0, TN=0, 216 bits",
        "cc": 0x01, "mcc": 0x000, "mnc": 0x0000, "tn": 0,
        "n_bits": 216,
        "data_gen": lambda n: [(i + 1) % 2 for i in range(n)],
    },
]


def main():
    out_dir = os.path.join(os.path.dirname(__file__))
    os.makedirs(out_dir, exist_ok=True)

    print("TETRA Scrambler Test Vector Generator")
    print(f"Polynomial mask: 0x{POLY_MASK:08X}")
    print(f"Output directory: {out_dir}\n")

    all_ok = True
    for tc in TEST_CASES:
        print(f"[{tc['name']}] {tc['desc']}")

        init = compute_lfsr_init(tc["cc"], tc["mcc"], tc["mnc"], tc["tn"])
        n    = tc["n_bits"]
        data = tc["data_gen"](n)

        # Generate expected output
        expected = scramble(init, data)

        # Verify symmetry (descramble of scrambled = original)
        if not verify_symmetry(init, data):
            print(f"  ERROR: symmetry check FAILED for {tc['name']}")
            all_ok = False
        else:
            print(f"  Symmetry check: PASS")

        # Print first 8 scramble bits for manual cross-check
        lfsr_seq = scramble(init, [0] * 8)  # sequence = output when data=0
        print(f"  lfsr_init = 0x{init:08X}")
        print(f"  First 8 seq bits (data=0): {lfsr_seq}")

        # Write init file (1 word = 8 hex digits)
        write_hex_file(
            os.path.join(out_dir, f"scrambler_{tc['name']}_init.hex"),
            [init], width_bytes=4
        )

        # Write stimulus (data_in bits packed as bytes, MSB first)
        data_bytes = bits_to_bytes(data)
        write_hex_file(
            os.path.join(out_dir, f"scrambler_{tc['name']}_stimulus.hex"),
            data_bytes, width_bytes=1
        )

        # Write expected output (scrambled bits packed as bytes, MSB first)
        exp_bytes = bits_to_bytes(expected)
        write_hex_file(
            os.path.join(out_dir, f"scrambler_{tc['name']}_expected.hex"),
            exp_bytes, width_bytes=1
        )

        print()

    # Summary
    print("=" * 50)
    if all_ok:
        print("All test cases PASSED symmetry check.")
    else:
        print("WARNING: One or more test cases FAILED.")
        sys.exit(1)

    print("\nManual cross-check for TC1 (first 4 output bits):")
    tc = TEST_CASES[0]
    init = compute_lfsr_init(tc["cc"], tc["mcc"], tc["mnc"], tc["tn"])
    data_sample = tc["data_gen"](4)
    out_sample  = scramble(init, data_sample)
    print(f"  data_in  = {data_sample}")
    print(f"  data_out = {out_sample}")
    print(f"  (XOR with LFSR sequence, init=0x{init:08X})")


if __name__ == "__main__":
    main()
