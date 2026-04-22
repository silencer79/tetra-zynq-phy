#!/usr/bin/env python3
"""
verify_ul_ra_burst.py — Validate that MS uplink Random-Access bursts contain
the ETSI §9.4.4.3.3 extended training sequence `x` (30 bits / 15 symbols).

Pipeline:
  1. Load WAV (stereo I/Q, int16 little-endian) — typical 250 kSps from SDR#
  2. Estimate + correct residual freq offset (FFT peak)
  3. RRC matched filter (α=0.35)
  4. Power detection — find burst windows (127 sym ≈ 7.17 ms at 18 kSym/s)
  5. Per-burst differential demod (π/4-DQPSK)
  6. Sliding correlation of x_dibits across the burst
  7. Report best correlation + symbol offset; a peak near sym-offset 56
     (after rat(2) + RA-blk1(54)) confirms x_bits in the burst

Usage:
    python3 scripts/verify_ul_ra_burst.py baseband_428235864Hz_01-06-04_22-04-2026.wav
"""

import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, estimate_freq_offset, rrc_filter,
    dibits_to_symbols, _build_diff_ref, _correlate_at,
)


# ETSI §9.4.4.3.3 extended training sequence x
# osmo-tetra/src/phy/tetra_burst.c:66 (30 bits, MSB-first dibits)
X_BITS = [
    1,0, 0,1, 1,1, 0,1, 0,0, 0,0, 1,1, 1,0,
    1,0, 0,1, 1,1, 0,1, 0,0, 0,0, 1,1,
]
X_DIBITS = [(X_BITS[2*i] << 1) | X_BITS[2*i+1] for i in range(15)]
X_DIFF_REF = _build_diff_ref(X_DIBITS)

# §9.4.4.2.1 Random-Access Burst layout (127 symbols total):
#   rat(2) + RA-blk1(54) + x(15) + RA-blk2(54) + rat(2)
RA_BURST_SYMS = 127
RA_X_SYM_OFFSET = 2 + 54   # 56 — start of x within burst
RA_BLK_SYMS = 54


def find_bursts(iq, sps, threshold_db=15.0, min_gap_samples=None):
    """Power-threshold based burst detection.
    Returns list of (start_sample, length_samples) tuples."""
    if min_gap_samples is None:
        min_gap_samples = int(50 * sps)  # at least 50 symbols of gap

    power = np.abs(iq) ** 2
    # Moving average over ~1 symbol
    win = max(1, int(round(sps)))
    kernel = np.ones(win) / win
    power_smooth = np.convolve(power, kernel, mode='same')

    noise_floor = np.median(power_smooth)
    threshold = noise_floor * (10 ** (threshold_db / 10.0))

    above = power_smooth > threshold
    transitions = np.diff(above.astype(np.int8))
    starts = np.where(transitions == 1)[0] + 1
    ends = np.where(transitions == -1)[0] + 1

    if above[0]:
        starts = np.concatenate([[0], starts])
    if above[-1]:
        ends = np.concatenate([ends, [len(above)]])

    n = min(len(starts), len(ends))
    bursts = []
    for i in range(n):
        s, e = int(starts[i]), int(ends[i])
        if e - s < int(50 * sps):
            continue
        # Merge with previous if too close
        if bursts and s - (bursts[-1][0] + bursts[-1][1]) < min_gap_samples:
            ps, pl = bursts[-1]
            bursts[-1] = (ps, e - ps)
        else:
            bursts.append((s, e - s))
    return bursts, noise_floor, threshold


def analyze_burst(iq, sps, burst_start, burst_len):
    """Search for x_bits across the burst window.
    Returns (best_corr, best_sym_offset, best_sample_pos)."""
    search_start = burst_start
    search_end = burst_start + burst_len
    best_c = 0.0
    best_pos = 0
    best_sym = 0

    step = max(1, int(round(sps / 8)))  # sub-symbol search

    for pos in range(search_start, search_end - int(15 * sps), step):
        c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
        if c > best_c:
            best_c = c
            best_pos = pos

    # Refine around best_pos
    for dt in np.linspace(-sps, sps, int(4 * sps) + 1):
        c = _correlate_at(iq, best_pos + dt, sps, X_DIBITS, X_DIFF_REF)
        if c > best_c:
            best_c = c
            best_pos = best_pos + dt

    # Symbol offset within burst (relative to burst start, in symbols)
    best_sym = (best_pos - burst_start) / sps
    return best_c, best_sym, best_pos


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav_file')
    ap.add_argument('--threshold-db', type=float, default=15.0,
                    help='Power threshold above noise floor (dB)')
    ap.add_argument('--swap-iq', action='store_true')
    ap.add_argument('--max-bursts', type=int, default=50)
    ap.add_argument('--no-freq-correct', action='store_true')
    args = ap.parse_args()

    print(f"Loading {args.wav_file} ...")
    iq, sr = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    if sr is None:
        print("ERROR: .wav required with valid sample rate", file=sys.stderr)
        sys.exit(1)
    print(f"  sample rate: {sr} Hz, duration: {len(iq)/sr:.2f} s, samples: {len(iq)}")

    # Normalize
    iq = iq / (np.median(np.abs(iq)) + 1e-12)

    # Freq offset correction
    if not args.no_freq_correct:
        f_off = estimate_freq_offset(iq, sr)
        print(f"  freq offset (FFT peak): {f_off:+.1f} Hz")
        t = np.arange(len(iq)) / sr
        iq = iq * np.exp(-2j * np.pi * f_off * t)

    # Decimate to a convenient sps
    # Target: ~8 samples/symbol (144 kHz)
    sps_raw = sr / SYMBOL_RATE
    decim = max(1, int(round(sps_raw / 8)))
    if decim > 1:
        # Low-pass before decim
        from scipy.signal import decimate
        try:
            iq = decimate(iq, decim, ftype='fir')
        except ImportError:
            iq = iq[::decim]
        sr_dec = sr / decim
    else:
        sr_dec = sr
    sps = sr_dec / SYMBOL_RATE
    print(f"  after decim: sr={sr_dec:.0f} Hz, sps={sps:.3f}")

    # RRC matched filter (α=0.35)
    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0:
        ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq = np.convolve(iq, h, mode='same')

    # Burst detection
    bursts, noise_floor, thresh = find_bursts(iq, sps,
                                              threshold_db=args.threshold_db)
    print(f"  noise floor: {10*np.log10(noise_floor+1e-30):.1f} dB, "
          f"threshold: {10*np.log10(thresh+1e-30):.1f} dB")
    print(f"  {len(bursts)} bursts detected")

    if len(bursts) == 0:
        print("No bursts — try lowering --threshold-db")
        return 1

    # Per-burst analysis
    print()
    print(f"  {'#':>3} {'start_s':>9} {'len_sym':>7} "
          f"{'best_corr':>9} {'x_sym_off':>10} {'expected':>9}")
    print("  " + "-" * 56)

    corrs = []
    offsets = []
    for i, (s, l) in enumerate(bursts[:args.max_bursts]):
        c, sym_off, pos = analyze_burst(iq, sps, s, l)
        t_sec = s / sr_dec
        len_sym = l / sps
        corrs.append(c)
        offsets.append(sym_off)
        marker = " ✓" if c > 0.5 and abs(sym_off - RA_X_SYM_OFFSET) < 5 else ""
        print(f"  {i:3d} {t_sec:9.3f} {len_sym:7.1f} "
              f"{c:9.3f} {sym_off:10.1f} {RA_X_SYM_OFFSET:9d}{marker}")

    corrs = np.array(corrs)
    offsets = np.array(offsets)
    print()
    print(f"Summary over {len(corrs)} bursts:")
    print(f"  correlation: min={corrs.min():.3f} "
          f"median={np.median(corrs):.3f} max={corrs.max():.3f}")
    print(f"  x offset:    min={offsets.min():.1f} "
          f"median={np.median(offsets):.1f} max={offsets.max():.1f} "
          f"(expected {RA_X_SYM_OFFSET})")

    n_hits = int(((corrs > 0.5) &
                  (np.abs(offsets - RA_X_SYM_OFFSET) < 5)).sum())
    print(f"  bursts with x_bits at expected offset: {n_hits}/{len(corrs)}")

    if n_hits > 0:
        print()
        print("RESULT: ETSI x_bits DETECTED — confirms §9.4.4.2.1 RA-burst "
              "layout. RTL ETS_REF fix on osmo-tetra x_bits is valid path.")
        return 0
    else:
        print()
        print("RESULT: x_bits NOT found at expected offset. Either burst "
              "detection is off, layout differs, or MS uses n-sequence "
              "(CUB). Inspect individual burst correlations above.")
        return 2


if __name__ == '__main__':
    sys.exit(main())
