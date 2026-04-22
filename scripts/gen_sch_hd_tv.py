#!/usr/bin/env python3
"""Generate SCH/HD (124→216) test vectors for tb_sch_hd_encoder.

Reuses the primitive helpers from verify_sb1_encoder.py; the only channel
differences for SCH/HD vs BSCH are:
  - info length 124 (not 60) → type3 length 144 (not 80)
  - interleaver N=216, a=101 (not N=120, a=11)
  - scrambler seed is cell-specific (runtime) instead of fixed 3
  - scrambled block length 216 (not 120)
"""

import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from verify_sb1_encoder import crc16, conv_encode_r14, puncture_r23  # noqa: E402


def interleave_sch_hd(bits):
    N, a = 216, 101
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


def encode_sch_hd(info_bits, scramble_init):
    assert len(info_bits) == 124
    type2  = crc16(info_bits)
    type3  = type2 + [0, 0, 0, 0]
    assert len(type3) == 144
    mother = conv_encode_r14(type3)
    assert len(mother) == 576
    type4  = puncture_r23(mother)
    assert len(type4) == 216
    typeI  = interleave_sch_hd(type4)
    type5  = scramble_with_init(typeI, scramble_init)
    return type5


def bits_to_hex(bits):
    """MSB-first bit array → hex string (first bit is MSB of result)."""
    n = len(bits)
    v = 0
    for b in bits:
        v = (v << 1) | (b & 1)
    return f"{v:0{(n + 3) // 4}x}"


def info_from_hex(hexstr, nbits=124):
    v = int(hexstr, 16)
    return [(v >> (nbits - 1 - i)) & 1 for i in range(nbits)]


def main():
    vectors = [
        # (tag, info_hex, scramble_init)
        ("zeros_init_zero",   "0" * 31,                               0x00000000),
        ("zeros_init_three",  "0" * 31,                               0x00000003),
        ("ones_init_cell",    "f" * 31,                               0xE1670C03),
        # Worked example: D-LOC-UPDATE ACCEPT, SSI=523, LA=36, matching the
        # encoder TB T1 vector (pdu_type=0001 addr=001 ssi=0x00020B la=0x0024
        # result=00 enc=00 auth=01 class=0x1234 rsvd57=0)
        ("d_loc_update_t1",
         f"{(1<<120) | (1<<117) | (523<<93) | (36<<79) | (0<<77) | (0<<75) | (1<<73) | (0x1234<<57):031x}",
         0xE1670C03),
    ]

    for tag, info_hex, init in vectors:
        # left-pad to 31 hex chars = 124 bits
        info_hex = info_hex.rjust(31, "0")[-31:]
        info = info_from_hex(info_hex)
        coded = encode_sch_hd(info, init)
        print(f"// {tag}")
        print(f"// info  = 124'h{info_hex}")
        print(f"// init  = 32'h{init:08x}")
        print(f'// coded = 216\'h{bits_to_hex(coded)}')
        print()


if __name__ == "__main__":
    main()
