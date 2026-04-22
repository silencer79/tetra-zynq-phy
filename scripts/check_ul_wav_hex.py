#!/usr/bin/env python3
"""check_ul_wav_hex.py — Verify WAV-stimulus hex round-trips via Python demod.

Reads sim_out/ul_wav_iq.hex (symbol-rate ZOH'd at 4 sps), extracts the 103
symbols per burst from the ZOH stream, runs Python π/4-DQPSK soft demod +
sch_hu_decoder on blk1/blk2, and reports CRC status.

If THIS fails → bug is in the gen script (CFO, scale, indexing).
If this passes but RTL TB fails → bug is in RTL chain handling real soft.
"""
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import make_scramb_code
from decode_ul import (
    demod_pi4dqpsk_soft_etsi, try_channel_decode, RA_CB_SYMS, RA_X_SYMS,
)

PRE_SMP      = 400
POST_SMP     = 1200
FULL_SYMS    = 103
SPS_TB       = 4
X_SYM_IDX    = 2 + 42
SMP_PER_BURST = PRE_SMP + FULL_SYMS * SPS_TB + POST_SMP  # 2012

def main():
    scramb_init = make_scramb_code(901, 9998, 49)
    with open('sim_out/ul_wav_iq.hex') as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]
    # 2 lines/sample (I, Q). Each entry is 16-bit unsigned → convert to signed.
    vals = np.array(vals, dtype=np.int32)
    vals = np.where(vals >= 0x8000, vals - 0x10000, vals)
    n_sample = len(vals) // 2
    I = vals[0::2]
    Q = vals[1::2]

    n_bursts = n_sample // SMP_PER_BURST
    print(f'hex: {n_sample} samples, {n_bursts} bursts')

    for b in range(n_bursts):
        base = b * SMP_PER_BURST + PRE_SMP
        # sample the first of each ZOH group of 4
        I_sym = I[base : base + FULL_SYMS * SPS_TB : SPS_TB]
        Q_sym = Q[base : base + FULL_SYMS * SPS_TB : SPS_TB]
        syms = I_sym + 1j * Q_sym

        # Build blk1 (sym 1..43 = ref + 42 data), blk2 (sym 58..100 = ref + 42 data)
        blk1 = syms[1:1 + 1 + RA_CB_SYMS]
        blk2 = syms[X_SYM_IDX + RA_X_SYMS - 1 : X_SYM_IDX + RA_X_SYMS - 1 + 1 + RA_CB_SYMS]

        blk1_soft = demod_pi4dqpsk_soft_etsi(blk1.astype(np.complex128))
        blk2_soft = demod_pi4dqpsk_soft_etsi(blk2.astype(np.complex128))

        r = try_channel_decode(blk1_soft, blk2_soft, scramb_init, 'schhu')
        crc_ok = r[0]
        print(f'  burst #{b}  |syms| min/max = {np.min(np.abs(syms)):.0f}/{np.max(np.abs(syms)):.0f}  '
              f'crc={"OK" if crc_ok else "-"}')

if __name__ == '__main__':
    main()
