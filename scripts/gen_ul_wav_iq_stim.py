#!/usr/bin/env python3
"""gen_ul_wav_iq_stim.py — Real-WAV UL stimulus for tb_ul_wav_chain.

Pipeline:
  1. Load WAV + global freq-offset correct + RRC + decimate (~8 sps).
  2. Find MS RA bursts via power threshold.
  3. Per burst — refine x-sequence position, constant CFO via x-seq pilot.
  4. Symbol-sample the 103-symbol CB (at x_pos - 44·sps through +58·sps),
     derotate with per-burst CFO, scale peak → AMPLITUDE, ZOH to 4 sps.
  5. Wrap with 400 pre-zeros + 1200 post-zeros — 2012 samples/burst, same
     layout as `scripts/gen_ul_demod_tv.py` so tb_ul_wav_chain is drop-in.
  6. Decode each burst via decode_ul.py to capture expected info+crc.

Outputs (sim_out/):
  ul_wav_iq.hex    — N × 2012 samples × 2 hex lines (I, Q 16-bit)
  ul_wav_exp.hex   — 13 bytes/burst: [crc:1][info:12]
"""
import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, estimate_freq_offset, rrc_filter,
    make_scramb_code, _correlate_at,
)
from verify_ul_ra_burst import X_DIBITS, X_DIFF_REF, find_bursts
from decode_ul import (
    refine_x_position, estimate_burst_cfo, sample_half_soft_bits,
    try_channel_decode, RA_CB_SYMS, RA_X_SYMS,
)


FULL_SYMS       = 2 + 42 + 15 + 42 + 2     # 103 (CB)
SPS_TB          = 4                         # sync_detect_os4 operates at 4 sps
FULL_PRE_SMP    = 400
FULL_POST_SMP   = 1200
FULL_SMP_PER_BURST = FULL_PRE_SMP + FULL_SYMS * SPS_TB + FULL_POST_SMP
AMPLITUDE       = 30000
X_SYM_IDX       = 2 + 42                    # 44 — x-seq start in CB


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav_file')
    ap.add_argument('--cc',  type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--out-dir', default='sim_out')
    ap.add_argument('--n-bursts', type=int, default=8)
    ap.add_argument('--threshold-db', type=float, default=15.0)
    ap.add_argument('--swap-iq', action='store_true')
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    iq, sr = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    if sr is None:
        print('ERROR: wav required', file=sys.stderr); return 1
    print(f'WAV: {args.wav_file}  sr={sr}  dur={len(iq)/sr:.2f}s')

    iq = iq / (np.median(np.abs(iq)) + 1e-12)
    f_off = estimate_freq_offset(iq, sr)
    print(f'  global freq offset: {f_off:+.1f} Hz')
    t = np.arange(len(iq)) / sr
    iq = iq * np.exp(-2j * np.pi * f_off * t)

    sps_raw = sr / SYMBOL_RATE
    decim = max(1, int(round(sps_raw / 8)))
    if decim > 1:
        from scipy.signal import decimate
        iq = decimate(iq, decim, ftype='fir')
        sr_dec = sr / decim
    else:
        sr_dec = sr
    sps = sr_dec / SYMBOL_RATE
    print(f'  decim x{decim} → sps={sps:.3f}')

    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0: ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq = np.convolve(iq, h, mode='same')

    bursts, _, _ = find_bursts(iq, sps, threshold_db=args.threshold_db)
    print(f'  {len(bursts)} bursts detected')
    if not bursts:
        return 1

    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'  scrambler init: 0x{scramb_init:08X}')

    iq_lines  = []
    exp_lines = []
    n_taken = 0
    n_crc   = 0

    for b_idx, (s, l) in enumerate(bursts):
        if n_taken >= args.n_bursts:
            break

        # Coarse x search
        coarse_end = s + l - int(RA_X_SYMS * sps)
        step = max(1, int(round(sps / 4)))
        best_c = 0.0
        best_pos = s + int(X_SYM_IDX * sps)
        for pos in range(s, coarse_end, step):
            c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
            if c > best_c:
                best_c = c; best_pos = pos
        x_pos, x_corr = refine_x_position(iq, sps, best_pos, search_syms=2)
        if x_corr < 0.5:
            continue

        burst_start_f = x_pos - X_SYM_IDX * sps
        # Guard burst fits fully in `iq`
        last_sym_pos = int(round(burst_start_f + (FULL_SYMS - 1) * sps))
        if burst_start_f < 0 or last_sym_pos >= len(iq):
            continue

        # Per-burst constant CFO
        cfo_A, _ = estimate_burst_cfo(iq, sps, x_pos, linear=False)

        # Symbol-sample 103 syms with CFO derotation
        sym_idx_vec = np.arange(FULL_SYMS, dtype=np.float64)
        samp_idx    = np.round(burst_start_f + sym_idx_vec * sps).astype(int)
        # k relative to x start (so cfo_A fit reference aligns)
        k_vec  = sym_idx_vec - X_SYM_IDX
        syms   = iq[samp_idx] * np.exp(-1j * cfo_A * k_vec)

        # Normalize each symbol to constant envelope (π/4-DQPSK is constant-
        # envelope in theory — ISI and sampling-phase error create the 50×
        # magnitude spread seen in raw samples). RTL demod slices magnitude-
        # dependent Re(z)/Im(z), so per-symbol normalization is required for
        # the MSB-slice quantizer to produce usable soft values.
        mag = np.abs(syms)
        mag[mag < 1e-9] = 1.0
        syms = syms / mag * AMPLITUDE
        Ifull = np.clip(np.round(syms.real), -32768, 32767).astype(np.int32)
        Qfull = np.clip(np.round(syms.imag), -32768, 32767).astype(np.int32)
        peak  = AMPLITUDE

        # Decode via Python for expected bits
        blk1, blk2 = sample_half_soft_bits(iq, sps, x_pos, RA_CB_SYMS, cfo_A, 0.0)
        crc_ok, info_bits, _, _ = try_channel_decode(blk1, blk2, scramb_init, 'schhu')
        if info_bits is None:
            info_bits = [0] * 92
        info_bits = list(int(b) & 1 for b in info_bits[:92])
        while len(info_bits) < 92:
            info_bits.append(0)

        # Write IQ (2012 samples: pre + 412 ZOH + post)
        for _ in range(FULL_PRE_SMP):
            iq_lines.append('0000'); iq_lines.append('0000')
        for n in range(FULL_SYMS):
            ihex = f"{Ifull[n] & 0xFFFF:04X}"
            qhex = f"{Qfull[n] & 0xFFFF:04X}"
            for _ in range(SPS_TB):
                iq_lines.append(ihex); iq_lines.append(qhex)
        for _ in range(FULL_POST_SMP):
            iq_lines.append('0000'); iq_lines.append('0000')

        # Expected record: crc flag + 12 info bytes
        info_bytes = []
        for bs in range(0, 92, 8):
            byte = 0
            for k in range(8):
                byte = (byte << 1) | (info_bits[bs + k] if bs + k < 92 else 0)
            info_bytes.append(byte)
        crc_flag = 1 if crc_ok else 0
        exp_lines.append(f"{crc_flag:02X} " + ' '.join(f"{x:02X}" for x in info_bytes))

        if crc_ok:
            n_crc += 1
        print(f'  burst #{n_taken}  src_idx={b_idx:2d}  x_corr={x_corr:.3f}  '
              f'cfo={cfo_A*1000:+7.2f}mrad  peak_raw={peak:.3f}  crc={"OK" if crc_ok else "-"}')
        n_taken += 1

    if n_taken == 0:
        print('ERROR: no usable bursts', file=sys.stderr)
        return 1

    iq_path  = os.path.join(args.out_dir, 'ul_wav_iq.hex')
    exp_path = os.path.join(args.out_dir, 'ul_wav_exp.hex')
    with open(iq_path, 'w') as f:
        f.write('\n'.join(iq_lines) + '\n')
    with open(exp_path, 'w') as f:
        f.write('\n'.join(exp_lines) + '\n')

    print()
    print(f'wrote {iq_path}   ({len(iq_lines)} values = {n_taken} × 2012 × 2)')
    print(f'wrote {exp_path}  ({n_taken} records, {n_crc} Python-CRC-OK)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
