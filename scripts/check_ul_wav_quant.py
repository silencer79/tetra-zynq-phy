#!/usr/bin/env python3
"""check_ul_wav_quant.py — Bit-exact RTL emulation including 3-bit quantization."""
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import make_scramb_code, scrambler_seq, ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4
from check_ul_wav_rtl_emu import rtl_demod, RA_CB_SYMS, RA_X_SYMS, X_SYM_IDX

PRE=400; SPS=4; FULL=103; MP=2012


def to_vit_soft_rtl(s):
    """Replicate RTL to_vit_soft (post-fix): diff = 4 - s, clamp [0,7]."""
    s = int(s)
    diff = 4 - s
    if diff < 0:
        return 0
    if diff > 7:
        return 7
    return diff


def viterbi_rtl_emu(vsoft):
    """Emulate RTL Viterbi K=5 r=1/4 minimum-cost path."""
    n_states = 16
    n_coded = len(vsoft)
    n_input = n_coded // 4
    INF = 1 << 20

    pm = [INF] * n_states
    pm[0] = 0
    tb_state = np.zeros((n_input, n_states), dtype=np.int32)
    tb_input = np.zeros((n_input, n_states), dtype=np.int32)

    def parity5(x):
        y = 0
        while x:
            y ^= x & 1
            x >>= 1
        return y

    Gs = (ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4)
    for i in range(n_input):
        rx = vsoft[4 * i : 4 * i + 4]
        new_pm = [INF] * n_states
        for s in range(n_states):
            # input bit is s[0] (newest bit shifted into state)
            inp = s & 1
            P0 = s >> 1            # old with old[3]=0
            P1 = (s >> 1) | 8      # old with old[3]=1
            for old in (P0, P1):
                if pm[old] >= INF:
                    continue
                sr = ((old << 1) | inp) & 0x1F
                cost = pm[old]
                for m, G in enumerate(Gs):
                    e = parity5(sr & G)
                    cost += (7 - rx[m]) if e else rx[m]
                if cost < new_pm[s]:
                    new_pm[s] = cost
                    tb_state[i, s] = old
                    tb_input[i, s] = inp
        # Normalize (subtract min)
        mn = min(new_pm)
        pm = [p - mn if p < INF else INF for p in new_pm]

    # Traceback from state 0 (tail bits zero)
    decoded = np.zeros(n_input, dtype=np.int32)
    state = 0
    for i in range(n_input - 1, -1, -1):
        decoded[i] = tb_input[i, state]
        state = tb_state[i, state]
    return decoded


def depuncture_vit(type4_vit, mother_len):
    """Depuncture with erasure = 4."""
    P = [0, 1, 2, 5]
    t = 3
    period = 8
    out = [4] * mother_len
    for j in range(1, len(type4_vit) + 1):
        k = period * ((j - 1) // t) + P[j - t * ((j - 1) // t)]
        out[k - 1] = type4_vit[j - 1]
    return out


def crc16_check(bits):
    crc = 0xFFFF
    for b in bits:
        crc ^= int(b) << 15
        for _ in range(1):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    # Actually DLL uses bit-reversed
    # reuse decode_dl's function
    from decode_dl import crc16_check_dll
    return crc16_check_dll(bits)


def main():
    scramb_init = make_scramb_code(901, 9998, 49)
    with open('sim_out/ul_wav_iq.hex') as f:
        vals = np.array([int(l.strip(), 16) for l in f if l.strip()], dtype=np.int64)
    vals = np.where(vals >= 0x8000, vals - 0x10000, vals)
    I = vals[0::2]; Q = vals[1::2]

    n_bursts = len(I) // MP
    print(f'{n_bursts} bursts')

    for b in range(n_bursts):
        base = b * MP + PRE
        I_sym = I[base : base + FULL * SPS : SPS]
        Q_sym = Q[base : base + FULL * SPS : SPS]
        syms = I_sym.astype(np.float64) + 1j * Q_sym.astype(np.float64)
        cb1 = syms[1 : 44]
        cb2 = syms[X_SYM_IDX + RA_X_SYMS - 1 : X_SYM_IDX + RA_X_SYMS - 1 + 1 + RA_CB_SYMS]
        re1, im1 = rtl_demod(cb1)
        re2, im2 = rtl_demod(cb2)
        # Interleave per RTL buffer order: buf[0]=soft_bit1(MSB=im), buf[1]=soft_bit0(LSB=re)
        soft8 = np.zeros(168, dtype=np.int8)
        for k in range(42):
            soft8[2 * k]     = im1[k]
            soft8[2 * k + 1] = re1[k]
        for k in range(42):
            soft8[84 + 2 * k]     = im2[k]
            soft8[84 + 2 * k + 1] = re2[k]

        # Descramble: flip sign where scrambler bit = 1
        scr = scrambler_seq(scramb_init, 168)
        soft8_desc = np.where(scr == 1, -soft8.astype(np.int32), soft8.astype(np.int32))
        soft8_desc = np.clip(soft8_desc, -128, 127).astype(np.int8)

        # Deinterleave: type4[i-1] = soft_type5[(13*i) mod 168]  (match decode_channel_soft)
        type4 = np.zeros(168, dtype=np.int8)
        for i in range(1, 169):
            k = (13 * i) % 168
            type4[i - 1] = soft8_desc[k]

        # Quantize to 3-bit unsigned (RTL to_vit_soft)
        type4_vit = [to_vit_soft_rtl(v) for v in type4]

        # Depuncture
        type3 = depuncture_vit(type4_vit, 448)

        # Viterbi
        decoded = viterbi_rtl_emu(type3)
        info_crc = decoded[:108]
        ok = crc16_check(info_crc)
        print(f'  burst #{b}  crc_ok={ok}  info[0:8]={"".join(str(int(x)) for x in decoded[:8])}')


if __name__ == '__main__':
    main()
