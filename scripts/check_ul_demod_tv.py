#!/usr/bin/env python3
"""Sanity check: replay ul_demod_iq.hex through a Python demod and compare
the resulting (sign-of-Re, sign-of-Im) sequence against the expected type-5
bits derived from the test vector info."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sch_hu_tv import encode_sch_hu
from decode_dl import make_scramb_code
import numpy as np

N_BURSTS = 4
SYMS_HALF = 43
SYMS_BURST = 86
INFO = 92

scramb_init = make_scramb_code(901, 9998, 49)
rng = np.random.default_rng(0xDEADBEEF)
info_patterns = []
for b in range(N_BURSTS):
    info = rng.integers(0, 2, size=INFO, dtype=np.int8).tolist()
    for i in range(8):
        info[i] = (b >> (7 - i)) & 1
    info_patterns.append(info)

with open('sim_out/ul_demod_iq.hex') as f:
    vals = [int(ln.strip(), 16) for ln in f if ln.strip()]
# 16-bit hex → signed
def s16(x):
    return x - 0x10000 if x & 0x8000 else x
I = np.array([s16(vals[2*k])   for k in range(len(vals)//2)], dtype=np.int32)
Q = np.array([s16(vals[2*k+1]) for k in range(len(vals)//2)], dtype=np.int32)

mismatches_total = 0
for b in range(N_BURSTS):
    type5 = encode_sch_hu(info_patterns[b], scramb_init)
    # Demod CB1 and CB2 independently
    soft_bits = []  # (b_msb_expected, b_lsb_expected, sign_re, sign_im)
    base_iq = b * SYMS_BURST
    for half in range(2):
        h_base = base_iq + half * SYMS_HALF
        for k in range(1, SYMS_HALF):
            Ik, Qk = I[h_base + k], Q[h_base + k]
            Ip, Qp = I[h_base + k - 1], Q[h_base + k - 1]
            re_z = Ik*Ip + Qk*Qp
            im_z = Qk*Ip - Ik*Qp
            # dibit[0] = sign(Re)  → corresponds to b_lsb
            # dibit[1] = sign(Im)  → corresponds to b_msb
            sign_re = 0 if re_z >= 0 else 1
            sign_im = 0 if im_z >= 0 else 1
            dibit_idx = half * 42 + (k - 1)      # 0..83
            bit_base = half * 84 + 2 * (k - 1)
            b_msb_exp = type5[bit_base]
            b_lsb_exp = type5[bit_base + 1]
            soft_bits.append((b_msb_exp, b_lsb_exp, sign_im, sign_re))
    mism = 0
    for i, (bm, bl, sim_s, sre_s) in enumerate(soft_bits):
        if bm != sim_s or bl != sre_s:
            mism += 1
            if mism <= 5:
                print(f"  burst{b} dibit{i}: exp (msb={bm},lsb={bl}) "
                      f"got (msb={sim_s},lsb={sre_s})")
    print(f"burst #{b}: {mism}/84 dibit mismatches")
    mismatches_total += mism

print(f"TOTAL: {mismatches_total} mismatches across {N_BURSTS*84} dibits")
