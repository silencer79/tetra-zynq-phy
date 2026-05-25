#!/usr/bin/env python3
"""
gen_d_nwrk_broadcast.py — Build a static D-NWRK-BROADCAST PDU as 432-bit
type-5 pattern for the FPGA periodic-broadcast ROM.

Source pattern: -Cell capture
  wavs/reference/reference-DL.wav
  Burst #423 (MN=44 FN=04 TN=1) — first sampled D-NWRK-BROADCAST.
  124-bit MAC-RESOURCE + LLC=BL-UDATA + MLE-disc=MLE → D-NWRK-BROADCAST
  addr=SSI ID=0xFFFFFF (broadcast), LI=16 (16 octets).

Pipeline:
  124 bit info  →  CRC-16 (16 bit)  →  140 bit  →  4 bit tail (zero)
  →  144 bit type-2  →  rate-1/2 conv-coding (k=5)  →  288 bit type-3
  →  matrix interleave (a=11, k=288)  →  288 bit type-4
  →  scramble (cell scrambler)  →  288 bit type-5
  →  split into 2 × 144 bit (BB1 + BB2 for SCH/F NDB1 burst)

Output: 432-bit Verilog hex constant for the ROM.

Usage:
    python3 scripts/gen_d_nwrk_broadcast.py [--cc CC] [--mcc MCC] [--mnc MNC]
"""
import argparse
import sys


# ---------------------------------------------------------------------------
# Static 124-bit D-NWRK-BROADCAST info from  #423 (MSB-first on air)
# ---------------------------------------------------------------------------
REF_INFO_124 = (
    "0010000010000001"  # 16  byte 0-1 MAC-RESOURCE header start
    "11111111"          # 24  addr_type=SSI bits
    "11111111"          # 32
    "11111111"          # 40
    "11111111"          # 48  SSI=0xFFFFFF
    "00000101"          # 56
    "01010010"          # 64  LLC pdu_type, NS bits
    "10110010"          # 72
    "10101001"          # 80  MLE-disc + payload start
    "10001111"          # 88
    "11001110"          # 96
    "11111100"          # 104 variabler 24-bit Counter region
    "10000100"          # 112
    "00100011"          # 120
    "1111"              # 124
)
assert len(REF_INFO_124) == 124, f"info len={len(REF_INFO_124)}"


# ---------------------------------------------------------------------------
# CRC-16 per ETSI EN 300 392-2 §B.2 (CCITT poly 0x11021)
# ---------------------------------------------------------------------------
def tetra_crc16(bits):
    poly = 0x11021  # x^16+x^12+x^5+1
    crc = 0xFFFF
    for b in bits:
        crc ^= (int(b) << 15)
        for _ in range(1):
            if crc & 0x10000:
                crc = ((crc << 1) ^ poly) & 0x1FFFF
            else:
                crc = (crc << 1) & 0x1FFFF
    crc ^= 0xFFFF
    return [(crc >> (15 - i)) & 1 for i in range(16)]


# ---------------------------------------------------------------------------
# Rate-1/2 K=5 convolutional encoder per ETSI §8.2.3.1.2
# G1 = 1 + D + D^2 + D^4 (octal 27 = 0b10111)
# G2 = 1 + D^3 + D^4    (octal 31 = 0b11001)
# Output: G1, G2 alternating
# ---------------------------------------------------------------------------
def conv_encode_k5(bits_in):
    sr = [0, 0, 0, 0]
    out = []
    for b in bits_in:
        b = int(b)
        # G1 = b XOR sr[0] XOR sr[1] XOR sr[3]
        # G2 = b XOR sr[2] XOR sr[3]
        g1 = b ^ sr[0] ^ sr[1] ^ sr[3]
        g2 = b ^ sr[2] ^ sr[3]
        out.append(g1)
        out.append(g2)
        sr = [b] + sr[:3]
    return out


# ---------------------------------------------------------------------------
# Matrix-block interleaver per ETSI §8.2.4.1
#   k = block size, a = step
#   y[i] = x[ ((a * i) mod k) ]
# For SCH/F type-3 → type-4: k=288, a=11 (per §8.2.4.1 Table 8.x)
# ---------------------------------------------------------------------------
def interleave(bits_in, a):
    k = len(bits_in)
    out = [0] * k
    for i in range(k):
        out[i] = bits_in[(a * i) % k]
    return out


# ---------------------------------------------------------------------------
# Cell scrambler per ETSI §8.2.5
# 32-bit Fibonacci LFSR with feedback poly:
#   bits 0,6,9,10,16,20,21,22,24,25,27,28,30,31
# init = MCC[10] | MNC[14] | CC[6] | "11"
# ---------------------------------------------------------------------------
def cell_scramble(bits_in, mcc, mnc, cc):
    lfsr = ((mcc & 0x3FF) << 22) | ((mnc & 0x3FFF) << 8) | ((cc & 0x3F) << 2) | 0x3
    if lfsr == 0:
        lfsr = 0xFFFFFFFF
    out = []
    for b in bits_in:
        fb = ((lfsr >> 0) ^ (lfsr >> 6) ^ (lfsr >> 9) ^ (lfsr >> 10) ^
              (lfsr >> 16) ^ (lfsr >> 20) ^ (lfsr >> 21) ^ (lfsr >> 22) ^
              (lfsr >> 24) ^ (lfsr >> 25) ^ (lfsr >> 27) ^ (lfsr >> 28) ^
              (lfsr >> 30) ^ (lfsr >> 31)) & 1
        out.append(int(b) ^ fb)
        lfsr = ((lfsr >> 1) | (fb << 31)) & 0xFFFFFFFF
    return out


# ---------------------------------------------------------------------------
# Build pipeline
# ---------------------------------------------------------------------------
def build_d_nwrk_type5(info124, cc, mcc, mnc):
    info_bits = [int(b) for b in info124]
    crc = tetra_crc16(info_bits)
    type2 = info_bits + crc + [0, 0, 0, 0]            # 144 bits (124 + 16 + 4 tail)
    assert len(type2) == 144

    type3 = conv_encode_k5(type2)                      # 288 bits
    assert len(type3) == 288

    # Puncturing: per §8.2.3.1.3 SCH/F uses no puncturing for the basic
    # rate-1/2 (288-bit type-3 → 288-bit type-4 directly).  Adjust if a
    # different rate is required.
    type4 = interleave(type3, 11)                      # block interleave
    assert len(type4) == 288

    type5 = cell_scramble(type4, mcc, mnc, cc)         # 288 bits scrambled
    return type5


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cc",  type=int, default=49,    help="Colour Code (default 49)")
    ap.add_argument("--mcc", type=int, default=901,   help="MCC (default 901)")
    ap.add_argument("--mnc", type=int, default=9998,  help="MNC (default 9998)")
    ap.add_argument("-o", "--output", help="Write .memh ROM file")
    args = ap.parse_args()

    type5 = build_d_nwrk_type5(REF_INFO_124, args.cc, args.mcc, args.mnc)

    print(f"D-NWRK-BROADCAST type-5 (288 bits) — CC={args.cc} MCC={args.mcc} MNC={args.mnc}")
    print()
    # Dump as hex (288 bits = 72 hex digits = 36 byte)
    bs = "".join(str(b) for b in type5)
    hex_full = "".join(f"{int(bs[i:i+4], 2):X}" for i in range(0, 288, 4))
    print(f"  hex : {hex_full}")
    print()

    # SCH/F bursts split: BB1 = type5[0..143], BB2 = type5[144..287]
    bb1 = bs[:144]
    bb2 = bs[144:]
    print(f"  BB1 (144b) hex : {''.join(f'{int(bb1[i:i+4],2):X}' for i in range(0,144,4))}")
    print(f"  BB2 (144b) hex : {''.join(f'{int(bb2[i:i+4],2):X}' for i in range(0,144,4))}")

    if args.output:
        with open(args.output, "w") as f:
            f.write("// D-NWRK-BROADCAST type-5 ROM, generated by\n")
            f.write("// scripts/gen_d_nwrk_broadcast.py\n")
            for i in range(0, 288, 32):
                word = int(bs[i:i+32].ljust(32, "0"), 2)
                f.write(f"{word:08x}\n")
        print(f"\nWrote {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
