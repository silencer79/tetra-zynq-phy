#!/usr/bin/env python3
"""
gen_interleaver_vectors.py — TETRA Block Interleaver Test Vector Generator

Generates interleaving / deinterleaving reference vectors.
ETSI EN 300 392-2 §8.2.4  (step interleaver).

Step parameters (NOTE: verify against standard and tetra-bluestation):
  STEP_TX      = 11  (interleave, all block sizes)
  STEP_RX_216  = 59  (deinterleave, K=216:  11^{-1} mod 216)
  STEP_RX_432  = 275 (deinterleave, K=432:  11^{-1} mod 432)

Output format: one bit per line (0x00 or 0x01) for easy bit-serial comparison.

Usage:
  python3 tb/vectors/gen_interleaver_vectors.py   (from project root)
"""

import os
import sys

STEP_TX     = 11
STEP_RX_216 = 59
STEP_RX_432 = 275


def step_permute(data: list, K: int, step: int) -> list:
    """
    Read buffer filled with data[0..K-1] using step permutation.
    Returns output list d where d[j] = data[(j * step) mod K].

    Equivalent to DRAIN phase: rd_addr starts at 0, steps by `step` mod K.
    The j-th output reads buf[j*step mod K].
    BUT in hardware, rd_addr is updated BEFORE reading the next bit, so:
      j=0: rd_addr starts at 0  → output = buf[0]
      j=1: rd_addr = (0+step)%K → output = buf[step]
      j=2: rd_addr = (step+step)%K → output = buf[2*step]
    This matches: d[j] = data[j * step mod K].
    """
    buf = list(data)
    out = []
    addr = 0
    for j in range(K):
        out.append(buf[addr])
        addr = (addr + step) % K
    return out


def interleave(data: list, K: int) -> list:
    return step_permute(data, K, STEP_TX)


def deinterleave(data: list, K: int) -> list:
    step_rx = STEP_RX_432 if K == 432 else STEP_RX_216
    return step_permute(data, K, step_rx)


def verify_roundtrip(data: list, K: int) -> bool:
    """Verify that deinterleave(interleave(data)) == data."""
    interleaved   = interleave(data, K)
    deinterleaved = deinterleave(interleaved, K)
    return deinterleaved == data


def bits_to_bytes(bits: list) -> list:
    """Pack list of bits (MSB first per byte) into byte values."""
    result = []
    for i in range(0, len(bits), 8):
        chunk = bits[i:i+8]
        while len(chunk) < 8:
            chunk.append(0)
        result.append(sum(b << (7 - j) for j, b in enumerate(chunk)))
    return result


def write_bit_file(path: str, bits: list) -> None:
    """Write one bit per line (00 or 01)."""
    with open(path, "w") as f:
        for b in bits:
            f.write(f"{b:02x}\n")
    print(f"  Written: {path} ({len(bits)} bits)")


def write_byte_file(path: str, data: list) -> None:
    """Write packed bytes (one per line, 2 hex digits)."""
    with open(path, "w") as f:
        for b in data:
            f.write(f"{b:02x}\n")
    print(f"  Written: {path} ({len(data)} bytes)")


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
TEST_CASES = [
    # TC1: NDB block (216 bits), interleave, alternating data
    {
        "name":       "tc1_ndb_intlv",
        "desc":       "NDB block (K=216), interleave, alternating bits",
        "K":          216,
        "mode":       "interleave",
        "data_gen":   lambda K: [i % 2 for i in range(K)],
    },
    # TC2: NDB block (216 bits), deinterleave
    {
        "name":       "tc2_ndb_deintlv",
        "desc":       "NDB block (K=216), deinterleave, same input",
        "K":          216,
        "mode":       "deinterleave",
        "data_gen":   lambda K: [i % 2 for i in range(K)],
    },
    # TC3: SCH/F block (432 bits), interleave
    {
        "name":       "tc3_schf_intlv",
        "desc":       "SCH/F block (K=432), interleave, pseudo-random",
        "K":          432,
        "mode":       "interleave",
        "data_gen":   lambda K: [(i * 7 ^ (i >> 3)) % 2 for i in range(K)],
    },
    # TC4: Roundtrip — interleave then deinterleave must recover original
    {
        "name":       "tc4_roundtrip_ndb",
        "desc":       "Roundtrip K=216: deinterleave(interleave(data)) == data",
        "K":          216,
        "mode":       "roundtrip",
        "data_gen":   lambda K: [(i * 3 + 5) % 2 for i in range(K)],
    },
    # TC5: Roundtrip SCH/F
    {
        "name":       "tc5_roundtrip_schf",
        "desc":       "Roundtrip K=432: deinterleave(interleave(data)) == data",
        "K":          432,
        "mode":       "roundtrip",
        "data_gen":   lambda K: [(i * 13 + 1) % 2 for i in range(K)],
    },
    # TC6: All-zeros
    {
        "name":       "tc6_zeros",
        "desc":       "All-zeros K=216: interleaved zeros = zeros",
        "K":          216,
        "mode":       "interleave",
        "data_gen":   lambda K: [0] * K,
    },
    # TC7: All-ones
    {
        "name":       "tc7_ones",
        "desc":       "All-ones K=216: interleaved ones = ones",
        "K":          216,
        "mode":       "interleave",
        "data_gen":   lambda K: [1] * K,
    },
]


def main():
    out_dir = os.path.join(os.path.dirname(__file__))
    os.makedirs(out_dir, exist_ok=True)

    print("TETRA Block Interleaver Test Vector Generator")
    print(f"STEP_TX={STEP_TX}  STEP_RX_216={STEP_RX_216}  STEP_RX_432={STEP_RX_432}\n")

    all_ok = True
    for tc in TEST_CASES:
        K    = tc["K"]
        data = tc["data_gen"](K)
        print(f"[{tc['name']}] {tc['desc']}")

        # Verify roundtrip property
        ok = verify_roundtrip(data, K)
        if not ok:
            print(f"  ERROR: roundtrip failed for K={K}")
            all_ok = False
        else:
            print(f"  Roundtrip check: PASS")

        if tc["mode"] == "roundtrip":
            # Generate both interleaved and recovered
            interleaved   = interleave(data, K)
            recovered     = deinterleave(interleaved, K)
            # Save: stimulus=data, expected=recovered (should equal data)
            write_bit_file(
                os.path.join(out_dir, f"interleaver_{tc['name']}_stimulus.hex"), data)
            write_bit_file(
                os.path.join(out_dir, f"interleaver_{tc['name']}_expected.hex"), recovered)
            # Also save interleaved (intermediate)
            write_bit_file(
                os.path.join(out_dir, f"interleaver_{tc['name']}_interleaved.hex"), interleaved)
        else:
            if tc["mode"] == "interleave":
                expected = interleave(data, K)
            else:
                expected = deinterleave(data, K)
            write_bit_file(
                os.path.join(out_dir, f"interleaver_{tc['name']}_stimulus.hex"), data)
            write_bit_file(
                os.path.join(out_dir, f"interleaver_{tc['name']}_expected.hex"), expected)

            # Print first 8 output bits for manual cross-check
            print(f"  Input  [0:7]: {data[:8]}")
            print(f"  Output [0:7]: {expected[:8]}")

        print()

    print("=" * 50)
    if all_ok:
        print("All test cases PASSED.")
    else:
        print("WARNING: Some test cases FAILED.")
        sys.exit(1)

    # Print permutation table for first 16 entries (K=216, TX)
    print("\nInterleave permutation (first 16 entries, K=216, STEP=11):")
    print("  j : rd_addr (j*11 mod 216) : source index")
    addr = 0
    for j in range(16):
        print(f"  {j:3d} : {addr:3d}")
        addr = (addr + STEP_TX) % 216


if __name__ == "__main__":
    main()
