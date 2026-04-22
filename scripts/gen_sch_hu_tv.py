#!/usr/bin/env python3
"""gen_sch_hu_tv.py — Generate clean SCH/HU test vectors for tb_ul_sch_hu_decoder.

Produces:
  sim_out/ul_sch_hu_soft.hex  — N_BURSTS*168 signed 8-bit soft values (one per line)
  sim_out/ul_sch_hu_exp.hex   — 13 bytes per burst: [crc_ok:1][info_bits_packed:12]

Signal model: clean channel, soft = +127 for bit=0, -127 for bit=1.
RTL decoder receives these via tetra_ul_pi4dqpsk_demod-style soft dibits.
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    scrambler_seq, make_scramb_code,
    ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4, _parity5,
)

K       = 168
A       = 13
INFO    = 92
CRC_LEN = INFO + 16       # 108
TAIL    = 4
MOTHER  = (K // 3) * 8    # 448
SPS     = CRC_LEN + TAIL  # 112 stages


def crc16_msb(bits):
    """CRC-16 poly=0x1021, init=0xFFFF, MSB-first; NO final XOR.
    Matches rtl/lmac/tetra_crc16.v and sw/tetra_hal.c tetra_crc16()."""
    crc = 0xFFFF
    for b in bits:
        fb = ((crc >> 15) ^ (b & 1)) & 1
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x1021
    return crc


def append_fcs(info_bits):
    """TETRA FCS = ones-complement of CRC-16 remainder, MSB-first."""
    rem = crc16_msb(info_bits)
    fcs = rem ^ 0xFFFF
    bits = list(info_bits)
    for i in range(15, -1, -1):
        bits.append((fcs >> i) & 1)
    return bits  # 92 + 16 = 108


def conv_encode_r14(bits):
    """K=5 r=1/4 convolutional encoder with ETSI G1..G4.
    State = 4 bits (K-1). One input bit produces 4 output bits."""
    state = 0
    out = []
    for b in bits:
        sr = ((state << 1) | (b & 1)) & 0x1F  # 5-bit shift register
        for G in (ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4):
            out.append(_parity5(sr & G))
        state = sr & 0xF
    return out  # len = 4 * len(bits)


def puncture_r23(mother):
    """Keep positions {0,1,4} mod 8 → reduces 448 → 168 bits."""
    return [mother[i] for i in range(len(mother)) if (i % 8) in (0, 1, 4)]


def interleave_a13(bits):
    """TX interleave (a=13, K=168): out[(a*i) mod K] = in[i-1] for i=1..K.
    Inverse of decoder: type4[i-1] = soft_type5[(a*i) mod K]."""
    out = [0] * K
    for i in range(1, K + 1):
        out[(A * i) % K] = bits[i - 1]
    return out


def scramble(bits, scramb_init):
    seq = scrambler_seq(scramb_init, K)
    return [(b ^ int(s)) & 1 for b, s in zip(bits, seq)]


def encode_sch_hu(info_bits, scramb_init):
    """Full SCH/HU TX chain: 92 info → 168 type-5 bits."""
    assert len(info_bits) == INFO
    crc_bits  = append_fcs(info_bits)            # 108
    with_tail = list(crc_bits) + [0] * TAIL      # 112
    mother    = conv_encode_r14(with_tail)       # 448
    type4     = puncture_r23(mother)             # 168
    assert len(type4) == K
    type5_preinter = interleave_a13(type4)       # 168 (bit-order interleaved)
    type5          = scramble(type5_preinter, scramb_init)
    return type5


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--cc', type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--out-dir', default='sim_out')
    ap.add_argument('--n-bursts', type=int, default=4)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'scramb_init = 0x{scramb_init:08X}')

    # Create N_BURSTS distinct MAC-ACCESS-ish payloads — distinguishable 92-bit
    # info patterns so we can verify per-burst routing in the TB.
    rng = np.random.default_rng(0xDEADBEEF)
    info_patterns = []
    for b in range(args.n_bursts):
        info = rng.integers(0, 2, size=INFO, dtype=np.int8).tolist()
        # Burst-index label in the first byte (bit 0..7) for easy visual check
        for i in range(8):
            info[i] = (b >> (7 - i)) & 1
        info_patterns.append(info)

    soft_lines = []   # one signed 8-bit value per line (0x00..0xFF hex)
    exp_lines  = []   # one line per burst: "01 <24 hex chars for 92 bits>"

    for b_idx, info in enumerate(info_patterns):
        type5 = encode_sch_hu(info, scramb_init)
        # Clean soft: bit=0 → +127, bit=1 → -127 (signed 8-bit)
        for bit in type5:
            val = -127 if bit == 1 else +127
            # signed to 8-bit two's complement
            soft_lines.append(f"{val & 0xFF:02X}")

        # Expected: crc_ok = 1, info bits packed MSB-first → 12 bytes
        info_bytes = []
        for bstart in range(0, INFO, 8):
            byte = 0
            for k in range(8):
                if bstart + k < INFO:
                    byte = (byte << 1) | info[bstart + k]
                else:
                    byte = (byte << 1)
            info_bytes.append(byte)
        assert len(info_bytes) == 12
        exp_lines.append('01 ' + ' '.join(f"{x:02X}" for x in info_bytes))

    soft_path = os.path.join(args.out_dir, 'ul_sch_hu_soft.hex')
    exp_path  = os.path.join(args.out_dir, 'ul_sch_hu_exp.hex')
    with open(soft_path, 'w') as f:
        f.write('\n'.join(soft_lines) + '\n')
    with open(exp_path, 'w') as f:
        f.write('\n'.join(exp_lines) + '\n')
    print(f'wrote {soft_path}  ({len(soft_lines)} soft values = {args.n_bursts} bursts × 168)')
    print(f'wrote {exp_path}   ({args.n_bursts} expected records)')
    print(f'scramb_init = 0x{scramb_init:08X}  (pass to TB via +SCRAMB_INIT=0x...)')


if __name__ == '__main__':
    main()
