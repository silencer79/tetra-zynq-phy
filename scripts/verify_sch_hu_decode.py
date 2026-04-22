#!/usr/bin/env python3
"""verify_sch_hu_decode.py — step-by-step cross-check of the SCH/HU decode path.

Runs three decoders on the same test vector:
  1. Canonical decode_channel_soft from decode_dl.py (soft in: +=0, -=1).
  2. Mirror of the RTL's exact algorithm (descramble signs → deint → depunct →
     3-bit-unsigned Viterbi with s[3]=input/s[0]=oldest convention).
  3. RTL-style CRC16 check (poly 0x1021, init 0xFFFF, NO final XOR, residue 0x1D0F).

If (1) passes but (2) fails, the RTL Viterbi algorithm (mirrored in Python) is
wrong.  If both pass, the bug is in the Verilog timing / buffering.
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    scrambler_seq, ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4, _parity5,
    decode_channel_soft, viterbi_r14_soft, depuncture_r23_soft,
    crc16_check_dll,
)

K = 168
A = 13
INFO = 92
CRC_LEN = INFO + 16
TAIL = 4
SPS = CRC_LEN + TAIL
SCRAMB_INIT = 0xE1670EC7


def load_softs(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            b = int(line, 16)
            out.append(b - 256 if b >= 128 else b)
    return out


def to_vit_soft(signed8):
    top4 = signed8 >> 4
    diff = 4 - top4
    if diff < 0:
        return 0
    if diff > 7:
        return 7
    return diff


def descramble_signs(softs, scramb_init):
    seq = scrambler_seq(scramb_init, K)
    out = []
    for i, s in enumerate(softs):
        out.append(-s if int(seq[i]) == 1 else s)
    return out


def deinterleave(buf):
    out = [0] * K
    for i in range(1, K + 1):
        out[i - 1] = buf[(A * i) % K]
    return out


def feed_vit_quads(buf_deint):
    quads = []
    kept_idx = 0
    for stage in range(SPS):
        s = []
        for g in range(4):
            mother_pos = stage * 4 + g
            if (mother_pos % 8) in (0, 1, 4):
                s.append(to_vit_soft(buf_deint[kept_idx]))
                kept_idx += 1
            else:
                s.append(4)
        quads.append(s)
    return quads


def viterbi_rtl_mirror(quads, num_stages):
    """Mirror of rtl/lmac/tetra_viterbi_decoder.v exactly."""
    # Generators P0 (predecessor-LSB=0) for each new-state s in 0..15
    gens_p0 = []
    for s in range(16):
        g1 = ((s >> 3) ^ s) & 1            # s[3]^s[0]        G1=0x13
        g2 = ((s >> 3) ^ (s >> 2) ^ (s >> 1)) & 1   # s[3]^s[2]^s[1]  G2=0x1D
        g3 = ((s >> 3) ^ (s >> 1) ^ s) & 1          # s[3]^s[1]^s[0]  G3=0x17
        g4 = ((s >> 3) ^ (s >> 2) ^ s) & 1          # s[3]^s[2]^s[0]  G4=0x1B
        gens_p0.append((g1, g2, g3, g4))

    INF = 0xFFFF
    pm = [INF] * 16
    pm[0] = 0
    surv = [[0] * num_stages for _ in range(16)]

    for t in range(num_stages):
        s0, s1, s2, s3 = quads[t]
        raw = []
        for st in range(16):
            g1, g2, g3, g4 = gens_p0[st]
            bm0 = ((7 - s0) if g1 else s0) + \
                  ((7 - s1) if g2 else s1) + \
                  ((7 - s2) if g3 else s2) + \
                  ((7 - s3) if g4 else s3)
            bm1 = 28 - bm0
            p0 = (st & 7) << 1
            p1 = p0 | 1
            c0 = pm[p0] + bm0
            c1 = pm[p1] + bm1
            if c1 < c0:
                surv[st][t] = 1
                raw.append(c1)
            else:
                surv[st][t] = 0
                raw.append(c0)
        mn = min(raw)
        pm = [min(r - mn, INF) for r in raw]

    best = pm.index(min(pm))
    out = [0] * num_stages
    st = best
    for step in range(num_stages):
        stage = num_stages - 1 - step
        out[stage] = (st >> 3) & 1
        st = ((st & 7) << 1) | surv[st][stage]
    return out[:num_stages - TAIL]


def crc16_msb_residue(bits):
    crc = 0xFFFF
    for b in bits:
        fb = ((crc >> 15) ^ (b & 1)) & 1
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x1021
    return crc


def bits_to_hex16(bits):
    v = 0
    for i in range(16):
        v = (v << 1) | bits[i]
    return v


def main():
    softs_all = load_softs('sim_out/ul_sch_hu_soft.hex')

    for burst in range(4):
        print(f'\n=== BURST {burst} ===')
        soft = softs_all[burst * K:(burst + 1) * K]

        # --- Canonical path ---
        ds = descramble_signs(soft, SCRAMB_INIT)
        ds_np = np.asarray(ds, dtype=np.float64)
        crc_ok_canonical, info_can, decoded_can = decode_channel_soft(
            ds_np, K, A, INFO
        )
        info16_can = bits_to_hex16(info_can.tolist())
        print(f'canonical  : crc_ok={bool(crc_ok_canonical)}  info[0:16]=0x{info16_can:04X}')

        # --- RTL mirror path ---
        di = deinterleave(ds)
        quads = feed_vit_quads(di)
        decoded_mirror = viterbi_rtl_mirror(quads, SPS)
        info_mirror = decoded_mirror[:INFO]
        crc_full = decoded_mirror  # 108 bits
        info16_m = bits_to_hex16(info_mirror)
        crc_residue = crc16_msb_residue(crc_full)
        crc_ok_m = (crc_residue == 0x1D0F)
        print(f'RTL-mirror : crc_ok={crc_ok_m} (residue=0x{crc_residue:04X}) info[0:16]=0x{info16_m:04X}')

        # --- Expected ---
        with open('sim_out/ul_sch_hu_exp.hex') as f:
            lines = f.readlines()
        parts = lines[burst].split()
        exp16 = (int(parts[1], 16) << 8) | int(parts[2], 16)
        print(f'expected   : info[0:16]=0x{exp16:04X}')


if __name__ == '__main__':
    main()
