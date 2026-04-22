#!/usr/bin/env python3
"""
wav_to_dibits.py — WAV → dibit-stream für RTL-Simulation.

Demoduliert die WAV bis zum Dibit-Strom (identisch zur Kette im FPGA:
freq-offset → decim → RRC → π/4-DQPSK-Differenz-Demod) und schreibt das
Ergebnis als `$readmemh`-lesbare Datei.

Format: eine hex-Ziffer pro Zeile (0..3), '//'-Kommentare erlaubt.

Usage:
    python3 scripts/wav_to_dibits.py input.wav --out sim_out/ul_ra_dibits.hex
"""

import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, estimate_freq_offset, rrc_filter,
    demod_pi4dqpsk,
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav_file')
    ap.add_argument('--out', default='sim_out/ul_ra_dibits.hex')
    ap.add_argument('--swap-iq', action='store_true')
    ap.add_argument('--no-freq-correct', action='store_true')
    ap.add_argument('--start-sec', type=float, default=0.0)
    ap.add_argument('--end-sec', type=float, default=None)
    args = ap.parse_args()

    iq, sr = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    if sr is None:
        print("ERROR: .wav required", file=sys.stderr)
        sys.exit(1)

    # Trim
    start = int(args.start_sec * sr)
    end = int(args.end_sec * sr) if args.end_sec else len(iq)
    iq = iq[start:end]
    print(f"input: {len(iq)} samples @ {sr} Hz ({len(iq)/sr:.2f}s)")

    # Normalize
    iq = iq / (np.median(np.abs(iq)) + 1e-12)

    # Freq offset
    if not args.no_freq_correct:
        f_off = estimate_freq_offset(iq, sr)
        print(f"freq offset: {f_off:+.1f} Hz")
        t = np.arange(len(iq)) / sr
        iq = iq * np.exp(-2j * np.pi * f_off * t)

    # Decimate to ~8 sps
    sps_raw = sr / SYMBOL_RATE
    decim = max(1, int(round(sps_raw / 8)))
    if decim > 1:
        from scipy.signal import decimate
        iq = decimate(iq, decim, ftype='fir')
        sr_dec = sr / decim
    else:
        sr_dec = sr
    sps = sr_dec / SYMBOL_RATE
    print(f"decim x{decim} → sr={sr_dec:.0f} Hz, sps={sps:.3f}")

    # RRC matched filter
    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0:
        ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq_f = np.convolve(iq, h, mode='same')

    # Sample at symbol rate (nearest sample, no timing recovery — good enough
    # for correlation test). Use best phase found over the first 1000 symbols.
    n_syms = int(len(iq_f) / sps) - 2
    best_phase = 0
    best_pow = -1.0
    for p in range(int(sps)):
        idx = np.round(np.arange(min(1000, n_syms)) * sps + p).astype(int)
        idx = idx[idx < len(iq_f)]
        s = iq_f[idx]
        # Prefer maximum steady-state power (avoids timing edges)
        pw = float(np.mean(np.abs(s) ** 2))
        if pw > best_pow:
            best_pow = pw
            best_phase = p
    print(f"best sample phase: {best_phase}")

    sym_idx = np.round(np.arange(n_syms) * sps + best_phase).astype(int)
    sym_idx = sym_idx[sym_idx < len(iq_f)]
    symbols = iq_f[sym_idx]

    # π/4-DQPSK differential demod
    dibits = demod_pi4dqpsk(symbols)
    print(f"demod: {len(dibits)} dibits")

    # Write hex file
    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w') as f:
        f.write(f"// wav_to_dibits.py from {os.path.basename(args.wav_file)}\n")
        f.write(f"// {len(dibits)} dibits @ {SYMBOL_RATE} sym/s "
                f"(duration {len(dibits)/SYMBOL_RATE:.3f}s)\n")
        for d in dibits:
            f.write(f"{int(d):x}\n")
    print(f"wrote {args.out} ({len(dibits)} dibits)")


if __name__ == '__main__':
    main()
