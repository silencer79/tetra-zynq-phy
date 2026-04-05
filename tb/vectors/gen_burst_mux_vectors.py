#!/usr/bin/env python3
"""
gen_burst_mux_vectors.py — Test vectors for tetra_burst_mux
TETRA PHY project — tetra-zynq-phy

Generates slot payload vectors for 4 test cases:
  TC1: Single slot 0 active, all others disabled
  TC2: All 4 slots active, round-robin burst trigger
  TC3: Slot disabled → Idle burst (burst_type=2, payload zeros)
  TC4: Builder-busy stall — slot pulse while builder busy
"""

import struct

BLOCK_BITS = 216
BB_BITS    = 30


def make_payload(pattern):
    """Return 216-bit block filled with repeating pattern byte."""
    raw = bytes([pattern & 0xFF] * (BLOCK_BITS // 8 + 1))
    val = int.from_bytes(raw, 'big') & ((1 << BLOCK_BITS) - 1)
    return val


def hex27(v, bits=216):
    """Format value as zero-padded hex (ceil(bits/4) digits)."""
    digits = (bits + 3) // 4
    return format(v & ((1 << bits) - 1), f'0{digits}X')


def write_hex(fname, values, bits):
    with open(fname, 'w') as f:
        for v in values:
            f.write(hex27(v, bits) + '\n')


if __name__ == '__main__':
    import os
    out = os.path.join(os.path.dirname(__file__))

    # ------------------------------------------------------------------
    # TC1: Slot 0 active (NDB), slots 1-3 disabled
    # Flat buses: slot N at offset N*BLOCK_BITS
    # ------------------------------------------------------------------
    b1_tc1 = [make_payload(0xA0 + i) for i in range(4)]   # distinct per slot
    b2_tc1 = [make_payload(0xB0 + i) for i in range(4)]
    bb_tc1 = [make_payload(0xC0 + i) & ((1 << BB_BITS) - 1) for i in range(4)]
    slot_en_tc1 = 0b0001   # only slot 0

    print(f"TC1 slot0 block1 = {hex27(b1_tc1[0])}")
    print(f"TC1 slot0 block2 = {hex27(b2_tc1[0])}")
    print(f"TC1 slot0 bb     = {hex27(bb_tc1[0], BB_BITS)}")

    # ------------------------------------------------------------------
    # TC2: All 4 slots active (slot_en=0xF), sequential pulses 0→3
    # ------------------------------------------------------------------
    b1_tc2 = [make_payload(0x10 * (i + 1)) for i in range(4)]
    b2_tc2 = [make_payload(0x20 * (i + 1)) for i in range(4)]
    bb_tc2 = [make_payload(0x40 * (i + 1)) & ((1 << BB_BITS) - 1) for i in range(4)]
    slot_en_tc2 = 0b1111

    for i in range(4):
        print(f"TC2 slot{i} block1 = {hex27(b1_tc2[i])}")

    # ------------------------------------------------------------------
    # TC3: Slot 1 disabled → expect build_burst_type=2, payload zeros
    # ------------------------------------------------------------------
    b1_tc3 = [make_payload(0xDE) for _ in range(4)]
    b2_tc3 = [make_payload(0xAD) for _ in range(4)]
    bb_tc3 = [0xDEAD & ((1 << BB_BITS) - 1)] * 4
    slot_en_tc3 = 0b1101   # slot 1 disabled

    print(f"TC3 slot1 disabled → burst_type expected = 2, block1 = all zeros")

    # ------------------------------------------------------------------
    # Output summary for reference in testbench
    # ------------------------------------------------------------------
    print("\nVector summary written to console (testbench uses inline values)")
    print(f"TC1 block1_flat (slot0..slot3):")
    b1_flat = 0
    for i in range(4):
        b1_flat |= b1_tc1[i] << (i * BLOCK_BITS)
    print(f"  = 0x{b1_flat:0{4*BLOCK_BITS//4}X}")

    # Write per-slot expected output for TC1, TC2
    with open(os.path.join(out, 'burst_mux_tc1_expected.txt'), 'w') as f:
        f.write(f"# TC1: slot0 NDB\n")
        f.write(f"block1={hex27(b1_tc1[0])}\n")
        f.write(f"block2={hex27(b2_tc1[0])}\n")
        f.write(f"bb={hex27(bb_tc1[0], BB_BITS)}\n")
        f.write(f"burst_type=0\n")

    with open(os.path.join(out, 'burst_mux_tc2_expected.txt'), 'w') as f:
        f.write(f"# TC2: all slots NDB\n")
        for i in range(4):
            f.write(f"slot{i}_block1={hex27(b1_tc2[i])}\n")
            f.write(f"slot{i}_block2={hex27(b2_tc2[i])}\n")
            f.write(f"slot{i}_bb={hex27(bb_tc2[i], BB_BITS)}\n")
            f.write(f"slot{i}_burst_type=0\n")

    print("burst_mux_tc1_expected.txt written")
    print("burst_mux_tc2_expected.txt written")
