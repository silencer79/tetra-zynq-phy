#!/usr/bin/env python3
"""check_ul_wav_rtl_emu.py — Bit-emulate RTL demod on WAV hex and decode.

Replicates tetra_ul_pi4dqpsk_demod's Re(z)/Im(z) MSB-slice soft output
(±20 range) to see whether the quantization alone loses CRC, or whether
there is a sign/order/mapping mismatch between gen script and RTL chain.
"""
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import make_scramb_code, decode_channel_soft
from decode_ul import descramble_soft_etsi

PRE_SMP      = 400
FULL_SYMS    = 103
SPS_TB       = 4
X_SYM_IDX    = 44
SMP_PER_BURST = 2012

RA_CB_SYMS = 42
RA_X_SYMS  = 15

def rtl_demod(syms):
    """Emulate RTL: per pair (ref, data) return (soft0=Re(z), soft1=Im(z))
    after MSB-slice to ±20 range."""
    prev = syms[:-1]
    cur  = syms[1:]
    z = cur * np.conj(prev)   # 32-bit signed × 32-bit → 64-bit, slice top 8
    re = z.real
    im = z.imag
    # RTL slices re_z[2*IQ_WIDTH : 2*IQ_WIDTH - SOFT_WIDTH + 1] =
    # re_z[32:25] @ 16-bit IQ. Equivalent to right-shift 25.
    shift = 25
    def slice_top(x):
        # RTL: signed arithmetic right shift (truncate, not round)
        xi = np.floor(x).astype(np.int64)
        y = xi >> shift
        y = np.clip(y, -128, 127)
        return y.astype(np.int8)
    return slice_top(re), slice_top(im)


def main():
    scramb_init = make_scramb_code(901, 9998, 49)
    with open('sim_out/ul_wav_iq.hex') as f:
        vals = [int(line.strip(), 16) for line in f if line.strip()]
    vals = np.array(vals, dtype=np.int64)
    vals = np.where(vals >= 0x8000, vals - 0x10000, vals)
    I = vals[0::2]
    Q = vals[1::2]

    n_bursts = len(I) // SMP_PER_BURST
    print(f'{n_bursts} bursts')

    for b in range(n_bursts):
        base = b * SMP_PER_BURST + PRE_SMP
        I_sym = I[base : base + FULL_SYMS * SPS_TB : SPS_TB]
        Q_sym = Q[base : base + FULL_SYMS * SPS_TB : SPS_TB]
        syms_all = I_sym.astype(np.float64) + 1j * Q_sym.astype(np.float64)

        # burst_capture extracts sym 1..43 (CB1: ref+42) and sym 58..100 (CB2: ref+42)
        cb1 = syms_all[1:1 + 1 + RA_CB_SYMS]
        cb2 = syms_all[X_SYM_IDX + RA_X_SYMS - 1 :
                        X_SYM_IDX + RA_X_SYMS - 1 + 1 + RA_CB_SYMS]

        # RTL demod per half — returns 42 pairs of (Re(z), Im(z)) 8-bit soft
        re1, im1 = rtl_demod(cb1)
        re2, im2 = rtl_demod(cb2)
        # RTL bit order in the 168-bit decoder stream: per dibit, soft_bit1 (MSB) then soft_bit0 (LSB)
        # Looking at synthetic flow: type5[2k] came from MSB (b_msb), type5[2k+1] from LSB.
        # RTL soft_bit0 = Re(z) = cos → LSB; soft_bit1 = Im(z) = sin → MSB.
        soft = np.zeros(2 * RA_CB_SYMS * 2, dtype=np.float64)
        # Half 0 (CB1)
        soft[0 : 2 * RA_CB_SYMS : 2] = im1.astype(np.float64)   # MSB
        soft[1 : 2 * RA_CB_SYMS : 2] = re1.astype(np.float64)   # LSB
        # Half 1 (CB2)
        soft[2 * RA_CB_SYMS + 0 :: 2] = im2.astype(np.float64)
        soft[2 * RA_CB_SYMS + 1 :: 2] = re2.astype(np.float64)

        # Descramble; Python convention: negative = bit 1
        K = 168
        soft_desc = descramble_soft_etsi(soft, scramb_init, K)

        # Viterbi expects: positive soft → bit 0, negative → bit 1. try_channel_decode does this.
        crc_ok, info_bits, _ = decode_channel_soft(soft_desc, K=K, a=13, info_bits_len=92)
        print(f'  burst #{b}  soft|min/mean/max| = '
              f'{np.min(np.abs(soft)):.0f}/{np.mean(np.abs(soft)):.1f}/{np.max(np.abs(soft)):.0f}  '
              f'crc={"OK" if crc_ok else "-"}  info[0:8]='
              f'{bin(sum(info_bits[i]<<(7-i) for i in range(8)))[2:].zfill(8) if info_bits is not None else "---"}')


if __name__ == '__main__':
    main()
