#!/usr/bin/env python3
"""Generate SCH/F (268→432) test vectors for tb_sch_f_encoder.

Reuses the primitive helpers from verify_sb1_encoder.py; the only channel
differences for SCH/F vs SCH/HD are:
  - info length 268 (not 124) → type3 length 288 (not 144)
  - interleaver N=432, a=103 (not N=216, a=101)
  - coded length 432 (not 216)

The Python path has been bit-exact against RTL for BSCH / SCH/HD, so we
trust it as the golden reference for the sized-up SCH/F chain.  This
matches the SW encoder `tetra_schf_encode()` in `sw/tetra_hal.c`.
"""

import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from verify_sb1_encoder import crc16, conv_encode_r14, puncture_r23  # noqa: E402


def interleave_sch_f(bits):
    """Multiplicative interleaver N=432, a=103 (ETSI Table 8.13)."""
    N, a = 432, 103
    out = [0] * N
    for k in range(1, N + 1):
        j = 1 + (a * k) % N
        out[j - 1] = bits[k - 1]
    return out


def scramble_with_init(bits, init):
    """Fibonacci LFSR, ETSI §8.2.5 taps, runtime init."""
    lfsr = init & 0xFFFFFFFF
    out = []
    for b in bits:
        fb = 0
        for tap in (0, 6, 9, 10, 16, 20, 21, 22, 24, 25, 27, 28, 30, 31):
            fb ^= (lfsr >> tap) & 1
        out.append(b ^ fb)
        lfsr = ((fb << 31) | (lfsr >> 1)) & 0xFFFFFFFF
    return out


def encode_sch_f(info_bits, scramble_init):
    assert len(info_bits) == 268
    type2 = crc16(info_bits)
    assert len(type2) == 284
    type3 = type2 + [0, 0, 0, 0]
    assert len(type3) == 288
    mother = conv_encode_r14(type3)
    assert len(mother) == 1152
    type4 = puncture_r23(mother)
    assert len(type4) == 432
    typeI = interleave_sch_f(type4)
    type5 = scramble_with_init(typeI, scramble_init)
    return type5


def bits_to_hex(bits):
    n = len(bits)
    v = 0
    for b in bits:
        v = (v << 1) | (b & 1)
    return f"{v:0{(n + 3) // 4}x}"


def info_from_hex(hexstr, nbits=268):
    v = int(hexstr, 16)
    return [(v >> (nbits - 1 - i)) & 1 for i in range(nbits)]


def main():
    # 268 bits = 67 hex chars
    H = 67
    vectors = [
        # (tag, info_hex, scramble_init)
        ("zeros_init_zero",  "0" * H, 0x00000000),
        ("zeros_init_three", "0" * H, 0x00000003),
        ("ones_cell",        "f" * H, 0xE1670EC7),
        # 0xA5 repeating pattern — lower 268 bits
        ("a5_rep_cell",
         f"{((int('a5' * 34, 16)) & ((1 << 268) - 1)):0{H}x}",
         0xE1670EC7),
    ]

    for tag, info_hex, init in vectors:
        info_hex = info_hex.rjust(H, "0")[-H:]
        info = info_from_hex(info_hex)
        coded = encode_sch_f(info, init)
        print(f"// {tag}")
        print(f"// info  = 268'h{info_hex}")
        print(f"// init  = 32'h{init:08x}")
        print(f"// coded = 432'h{bits_to_hex(coded)}")
        print()


if __name__ == "__main__":
    main()
