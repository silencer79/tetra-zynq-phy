#!/usr/bin/env python3
"""Dumpt den RTL-emulierten 168-Soft pro realem UL-Burst aus ul_wav_iq.hex
nach ul_wav_soft.hex (Format wie ul_sch_hu_soft.hex) fuer den SW-Cross-Check."""
import os, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_ul_wav_rtl_emu import (rtl_demod, PRE_SMP, FULL_SYMS, SPS_TB,
                                   X_SYM_IDX, SMP_PER_BURST, RA_CB_SYMS, RA_X_SYMS)
with open('sim_out/ul_wav_iq.hex') as f:
    vals = [int(l.strip(),16) for l in f if l.strip()]
vals = np.array(vals, dtype=np.int64)
vals = np.where(vals >= 0x8000, vals - 0x10000, vals)
I, Q = vals[0::2], vals[1::2]
n = len(I)//SMP_PER_BURST
out = []
for b in range(n):
    base = b*SMP_PER_BURST + PRE_SMP
    I_sym = I[base:base+FULL_SYMS*SPS_TB:SPS_TB]; Q_sym = Q[base:base+FULL_SYMS*SPS_TB:SPS_TB]
    s = I_sym.astype(float)+1j*Q_sym.astype(float)
    cb1 = s[1:1+1+RA_CB_SYMS]
    cb2 = s[X_SYM_IDX+RA_X_SYMS-1 : X_SYM_IDX+RA_X_SYMS-1+1+RA_CB_SYMS]
    re1,im1 = rtl_demod(cb1); re2,im2 = rtl_demod(cb2)
    soft = np.zeros(168, dtype=np.int64)
    soft[0:2*RA_CB_SYMS:2] = im1; soft[1:2*RA_CB_SYMS:2] = re1
    soft[2*RA_CB_SYMS+0::2] = im2; soft[2*RA_CB_SYMS+1::2] = re2
    out += [f"{int(v)&0xFF:02X}" for v in soft]
open('sim_out/ul_wav_soft.hex','w').write('\n'.join(out)+'\n')
print(f'wrote sim_out/ul_wav_soft.hex ({n} bursts x 168)')
