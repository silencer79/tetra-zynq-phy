#!/usr/bin/env python3
"""
gen_aach_reference.py — Python reference model of the TETRA AACH encoder.

Reproduces the SW path in sw/tetra_hal.c exactly (build_aach_capaloc /
build_aach + aach_scramble), so that the RTL tetra_aach_encoder can be
verified bit-exact against it.

Usage:
    python3 scripts/gen_aach_reference.py [-o <file.memh>]

Outputs four 30-bit reference codewords, one per line in hex, matching the
four hard-coded test cases used in tb/tb_tetra_aach_encoder.v:

    TC1: F1,  cc=9,  mcc=901, mnc=9998  (CapAlloc, our own cell)
    TC2: F18, cc=9,  mcc=901, mnc=9998  (DL/UL-Assign, our own cell)
    TC3: F1,  cc=36, mcc=262, mnc=106   (CapAlloc, real cell)
    TC4: F18, cc=36, mcc=262, mnc=106   (DL/UL-Assign, real cell)

The line ordering of the .memh file matches TC1..TC4 in order.
"""

import argparse
import sys

# ---------------------------------------------------------------------------
# RM(30,14) generator matrix — copied from sw/tetra_hal.c rm_30_14_gen[][]
# ---------------------------------------------------------------------------
RM_30_14_GEN = [
    [1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0],
    [0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0],
    [1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 0],
    [0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0],
    [0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1],
    [1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1],
    [0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1],
    [0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1],
    [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1],
    [0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1],
    [0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1],
]


def build_rm_rows():
    """Replicate tetra_rm3014_init from tetra_hal.c.

    Returns a list of 14 30-bit integers.
    """
    rows = []
    for i in range(14):
        val = (1 << (16 + 13 - i))  # upper 14 bits: identity
        for j in range(16):
            val |= RM_30_14_GEN[i][j] << (15 - j)
        rows.append(val)
    return rows


RM_ROWS = build_rm_rows()


def rm3014_encode(in_word: int) -> int:
    """RM(30,14) encode of a 14-bit info word → 30-bit coded word.

    Matches tetra_rm3014_compute() in tetra_hal.c.
    Bit [29] of result corresponds to first transmitted bit.
    """
    assert 0 <= in_word < (1 << 14)
    coded = 0
    for i in range(14):
        if (in_word >> (13 - i)) & 1:
            coded ^= RM_ROWS[i]
    return coded & ((1 << 30) - 1)


# ---------------------------------------------------------------------------
# Fibonacci LFSR — taps 32/26/23/22/16/12/11/10/8/7/5/4/2/1 (MSB-numbered)
# Matches next_lfsr_bit() in sw/tetra_hal.c.  ST(lfsr, k) = (lfsr >> (32-k)) & 1.
# ---------------------------------------------------------------------------
def next_lfsr_bit(lfsr: int) -> tuple:
    """Step the 32-bit Fibonacci LFSR.  Returns (bit, new_lfsr)."""
    def ST(x, y):
        return (x >> (32 - y)) & 1

    bit = (ST(lfsr, 32) ^ ST(lfsr, 26) ^ ST(lfsr, 23) ^ ST(lfsr, 22) ^
           ST(lfsr, 16) ^ ST(lfsr, 12) ^ ST(lfsr, 11) ^ ST(lfsr, 10) ^
           ST(lfsr, 8)  ^ ST(lfsr, 7)  ^ ST(lfsr, 5)  ^ ST(lfsr, 4)  ^
           ST(lfsr, 2)  ^ ST(lfsr, 1)) & 1
    lfsr = ((lfsr >> 1) | (bit << 31)) & 0xFFFFFFFF
    return bit, lfsr


def aach_scramble(mcc: int, mnc: int, colour_code: int, coded30: int) -> int:
    """Apply the AACH scrambler to a 30-bit coded word (MSB-first).

    Matches aach_scramble() in tetra_hal.c:
        lfsr = (mcc<<22) | (mnc<<8) | (cc<<2) | 3
    """
    lfsr = (((mcc & 0x3FF) << 22) |
            ((mnc & 0x3FFF) << 8) |
            ((colour_code & 0x3F) << 2) |
            0x3) & 0xFFFFFFFF
    if lfsr == 0:
        lfsr = 0xFFFFFFFF

    out = 0
    # SW iterates bits[0..29] where bits[0] = MSB (first transmitted).
    # Our integer has [29] = MSB, so step i=0..29 xors into bit (29-i).
    for i in range(30):
        b, lfsr = next_lfsr_bit(lfsr)
        src_bit = (coded30 >> (29 - i)) & 1
        out |= ((src_bit ^ b) & 1) << (29 - i)
    return out


# ---------------------------------------------------------------------------
# AACH info-word builders — match build_aach / build_aach_capaloc in SW
# ---------------------------------------------------------------------------
def aach_info_capaloc() -> int:
    """CapAlloc (F1..F17): Header=11, Field1=0, Field2=0 → 14'h3000."""
    return 0x3000


def aach_info_dlul_assign() -> int:
    """DL/UL-Assign (F18): Header=00, DL=000, UL=001, Field2(aach_cc)=0 → 14'h040.

    Matches the SW call: build_aach(aach_cc=0, dl_usage=0, ul_usage=1, ...)
    """
    info = 0
    # pack_bits MSB-first into 14-bit word
    info = (info << 2) | (0 & 0x3)        # Header=00
    info = (info << 3) | (0 & 0x7)        # DL-usage=0
    info = (info << 3) | (1 & 0x7)        # UL-usage=1
    info = (info << 6) | (0 & 0x3F)       # Field2 aach_cc=0
    return info & 0x3FFF


def encode_aach(fn_0based: int, cc: int, mcc: int, mnc: int) -> int:
    """Full AACH encode: info → RM → scramble.  Returns 30-bit coded value."""
    if fn_0based == 17:          # ETSI FN=18
        info = aach_info_dlul_assign()
    else:                         # ETSI FN=1..17
        info = aach_info_capaloc()
    coded = rm3014_encode(info)
    coded = aach_scramble(mcc, mnc, cc, coded)
    return coded


# ---------------------------------------------------------------------------
# Test vectors
# ---------------------------------------------------------------------------
TEST_CASES = [
    ("TC1 F1  cc=9  mcc=901 mnc=9998", 0,  9,  901, 9998),
    ("TC2 F18 cc=9  mcc=901 mnc=9998", 17, 9,  901, 9998),
    ("TC3 F1  cc=36 mcc=262 mnc=106",  0,  36, 262, 106),
    ("TC4 F18 cc=36 mcc=262 mnc=106",  17, 36, 262, 106),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output",
                    help="write hex-per-line .memh output to this file")
    args = ap.parse_args()

    print("AACH reference vectors (30-bit hex, bit[29] = first transmitted)")
    print()
    lines = []
    for label, fn, cc, mcc, mnc in TEST_CASES:
        info = aach_info_dlul_assign() if fn == 17 else aach_info_capaloc()
        rm = rm3014_encode(info)
        final = aach_scramble(mcc, mnc, cc, rm)
        print(f"  {label}")
        print(f"    info14 = 0x{info:04X}  rm30 = 0x{rm:08X}  final = 0x{final:08X}")
        lines.append(f"{final:08x}")

    if args.output:
        with open(args.output, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"\nWrote {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
