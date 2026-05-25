#!/usr/bin/env python3
"""verify_empty_sweep.py — Sucht in den "empty"-Bursts die Position & Länge
einer versteckten Training-Sequenz. Keine Interpretation, nur Peaks.

Methode:
  - Alle empty-Bursts auf ein Symbol-Raster demodulieren
  - Differentieller Mean-Symbol-Vektor über 300 Bursts (fixe Content → hoher |z|)
  - Peak-Detection: welche Symbol-Positionen sind fix, welche random?
  - STS/NTS1/NTS2-Korrelation an *jeder* Offset-Position (0..254) testen
"""
import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, BURST_SYMBOLS,
    SDB_OFF_SB1, SDB_OFF_STS, SDB_SB1,
    NSB_OFF_SB1, NSB_OFF_STS,
    NDB_OFF_NTS,
    STS_DIBITS, STS_DIFF_REF,
    NTS1_DIBITS, NTS1_DIFF_REF,
    NTS2_DIBITS, NTS2_DIFF_REF,
    dibits_to_symbols, demod_pi4dqpsk,
    _correlate_at,
    load_iq_file, estimate_freq_offset, rrc_filter,
    scrambler_seq, decode_channel, parse_sysinfo_sb,
)
from schedule import _phase_correct


def analyze(wav_path):
    iq, sr = load_iq_file(wav_path)
    iq = iq.astype(np.complex64)
    fo = estimate_freq_offset(iq, sr)
    if abs(fo) > 10:
        t = np.arange(len(iq)) / sr
        iq = iq * np.exp(-1j * 2 * np.pi * fo * t)
    sps_target = 8
    target_rate = SYMBOL_RATE * sps_target
    decim = max(1, int(sr / target_rate))
    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sr
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2)) * np.hanning(ntaps)
        h /= np.sum(h)
        iq = np.convolve(iq, h, mode='same')[::decim]
    sps = (sr / decim) / SYMBOL_RATE
    rrc = rrc_filter(int(6 * sps) * 2 + 1, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')

    n = len(iq)
    burst_spacing = BURST_SYMBOLS * sps
    step = max(1, int(sps / 2))
    scan_limit = min(n - int(BURST_SYMBOLS * sps), n)
    peaks = []
    for off in range(0, scan_limit, step):
        c = _correlate_at(iq, off, sps, STS_DIBITS, STS_DIFF_REF)
        if c >= 0.35:
            peaks.append((off, c))
    peaks.sort(key=lambda x: -x[1])
    deduped = []
    for off, c in peaks:
        if all(abs(off - po) >= burst_spacing // 2 for po, _ in deduped):
            deduped.append((off, c))
        if len(deduped) >= 30:
            break

    layout = None
    anchor_sts_pos = None
    for sts_off, _ in deduped:
        for lname, l_sb1, l_sts in [('non-continuous', NSB_OFF_SB1, NSB_OFF_STS),
                                     ('continuous', SDB_OFF_SB1, SDB_OFF_STS)]:
            bsyms, _, ts_pos = _phase_correct(iq, sts_off, sps, l_sts,
                                               STS_DIBITS, STS_DIFF_REF)
            if bsyms is None:
                continue
            db = demod_pi4dqpsk(bsyms)
            s = l_sb1 - 1
            if s < 0 or s + SDB_SB1 > len(db):
                continue
            sb1_bits = np.zeros(SDB_SB1 * 2, dtype=np.int32)
            sb1_bits[0::2] = (db[s:s+SDB_SB1] >> 1) & 1
            sb1_bits[1::2] = db[s:s+SDB_SB1] & 1
            sb1_d = (sb1_bits ^ scrambler_seq(3, 120)) & 1
            ok, info, _ = decode_channel(sb1_d, 120, 11, 60)
            if ok:
                layout = lname
                anchor_sts_pos = ts_pos
                break
        if layout:
            break
    print(f"layout = {layout}")

    l_sts = SDB_OFF_STS if layout == 'continuous' else NSB_OFF_STS
    pos = anchor_sts_pos
    while pos - burst_spacing >= 0:
        pos -= burst_spacing
    grid = []
    while pos < n - int(BURST_SYMBOLS * sps):
        grid.append(pos)
        pos += burst_spacing

    # Classify & collect empty bursts
    sb_thresh, nts_thresh = 0.5, 0.55
    empty_gpos = []
    for gpos in grid:
        nts_pred = gpos + (NDB_OFF_NTS - l_sts) * sps
        _, s_c, _ = _phase_correct(iq, gpos, sps, l_sts,
                                    STS_DIBITS, STS_DIFF_REF)
        _, n1_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS1_DIBITS, NTS1_DIFF_REF)
        _, n2_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS2_DIBITS, NTS2_DIFF_REF)
        best_nts = max(n1_c, n2_c)
        if s_c < sb_thresh and best_nts < nts_thresh:
            empty_gpos.append(gpos)
    print(f"empty bursts: {len(empty_gpos)}")

    # Extract symbols at a fixed phase alignment using one burst as phase anchor
    # We use the STS-region's timing from the grid, even though empty bursts
    # lack STS. The grid_spacing anchored to SB burst gives us phase lock.
    burst_len = int(BURST_SYMBOLS * sps)
    syms_per_burst = []
    for gpos in empty_gpos[:400]:
        start = int(gpos - l_sts * sps)
        if start < 0 or start + burst_len > n:
            continue
        seg = iq[start:start + burst_len]
        sidx = np.round(np.arange(BURST_SYMBOLS) * sps).astype(int)
        sidx = np.clip(sidx, 0, len(seg) - 1)
        s = seg[sidx]
        # Normalize amplitude
        a = np.abs(s).mean() + 1e-12
        s = s / a
        syms_per_burst.append(s)
    syms_per_burst = np.array(syms_per_burst)  # (N, 255) complex
    print(f"phase-anchor sample count: {len(syms_per_burst)}")

    # Differential symbols
    diff = syms_per_burst[:, 1:] * np.conj(syms_per_burst[:, :-1])
    # Mean over bursts (complex avg): |z| close to 1 → fixed pattern
    mean_diff = np.mean(diff, axis=0)
    abs_mean = np.abs(mean_diff)

    print("\n|mean(diff)| per symbol-diff position (high → deterministic):")
    print("pos : |z|  angle(deg)")
    # Print all positions with |z| > 0.3, plus known STS/NTS offsets
    for i in range(len(abs_mean)):
        if abs_mean[i] > 0.3 or i in (85, 106, 107, 120, 121):
            ang = np.degrees(np.angle(mean_diff[i]))
            print(f"  {i:3d}  {abs_mean[i]:.3f}  {ang:+7.1f}°")

    # Segment-deterministic: find runs of >= 5 consecutive positions with |z|>0.5
    runs = []
    i = 0
    thr = 0.5
    while i < len(abs_mean):
        if abs_mean[i] >= thr:
            j = i
            while j < len(abs_mean) and abs_mean[j] >= thr:
                j += 1
            if j - i >= 5:
                runs.append((i, j - 1, j - i, float(np.mean(abs_mean[i:j]))))
            i = j
        else:
            i += 1
    print("\nDeterministische Runs (len>=5, |z|>=0.5):")
    for a, b, l, v in runs:
        print(f"  diff-pos {a:3d}..{b:3d}  len={l:3d}  mean|z|={v:.3f}")

    # Test known STS/NTS sequences at ALL offsets:
    print("\nSTS/NTS-Korrelation (offset sweep 0..230):")
    best_sts = (0, 0); best_n1 = (0, 0); best_n2 = (0, 0)
    # Pick one representative empty burst for offset scan
    gpos = empty_gpos[0]
    start = int(gpos - l_sts * sps)
    seg = iq[start:start + burst_len]
    sidx = np.round(np.arange(BURST_SYMBOLS) * sps).astype(int)
    sidx = np.clip(sidx, 0, len(seg) - 1)
    s = seg[sidx]
    # Build diff chain for the whole burst
    bd = s[1:] * np.conj(s[:-1])
    bd /= np.abs(bd) + 1e-12
    for name, ref in [("STS", STS_DIFF_REF), ("NTS1", NTS1_DIFF_REF),
                       ("NTS2", NTS2_DIFF_REF)]:
        ref_n = np.array(ref, dtype=np.complex128) / np.abs(np.array(ref)) + 1e-12
        L = len(ref_n)
        best = 0.0; best_off = 0
        for off in range(0, len(bd) - L):
            c = np.abs(np.mean(bd[off:off+L] * np.conj(ref_n)))
            if c > best:
                best = c; best_off = off
        print(f"  {name:5s}  peak at diff-pos {best_off:3d} → |corr|={best:.3f}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    args = ap.parse_args()
    analyze(args.wav)
