#!/usr/bin/env python3
"""verify_empty_content.py — Charakterisiert "empty"-klassifizierte Bursts
im WAV. Liefert harte Messungen ohne Interpretation:
  - Korrelation-Histogramme (STS / NTS1 / NTS2) über alle "empty"-Bursts
  - Autokorrelations-Peak-Positionen je Burst (zeigt versteckte Training-Seqs)
  - Power-Envelope je Symbol (prüft, ob irgendwo IQ-Lücke innerhalb Burst)
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
    demod_pi4dqpsk, _correlate_at,
    load_iq_file, estimate_freq_offset, rrc_filter,
    scrambler_seq, decode_channel, parse_sysinfo_sb,
)
from schedule import _phase_correct


def analyze(wav_path):
    iq, sr = load_iq_file(wav_path)
    iq = iq.astype(np.complex64)
    print(f"sr={sr} samples={len(iq)} ({len(iq)/sr:.2f}s)")
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

    # Classify each burst, keep the empty ones' stats
    sb_thresh, nts_thresh = 0.5, 0.55
    empty_corrs = []  # (sts_c, n1_c, n2_c, gpos)
    sb_corrs = []
    for gpos in grid:
        nts_pred = gpos + (NDB_OFF_NTS - l_sts) * sps
        _, s_c, _ = _phase_correct(iq, gpos, sps, l_sts,
                                    STS_DIBITS, STS_DIFF_REF)
        _, n1_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS1_DIBITS, NTS1_DIFF_REF)
        _, n2_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS2_DIBITS, NTS2_DIFF_REF)
        best_nts = max(n1_c, n2_c)
        if s_c >= best_nts and s_c >= sb_thresh:
            sb_corrs.append((s_c, n1_c, n2_c, gpos))
        elif best_nts >= nts_thresh:
            pass
        else:
            empty_corrs.append((s_c, n1_c, n2_c, gpos))

    empty = np.array(empty_corrs, dtype=object)
    sb = np.array(sb_corrs, dtype=object)
    print(f"\nempty count = {len(empty)}   SB count = {len(sb)}")

    def stats(arr, idx, name):
        v = np.array([a[idx] for a in arr], dtype=float)
        print(f"  {name:5s}  mean={np.mean(v):.3f}  median={np.median(v):.3f}  "
              f"p10={np.percentile(v,10):.3f}  p90={np.percentile(v,90):.3f}  "
              f"max={np.max(v):.3f}")

    print("\n--- empty bursts ---")
    stats(empty_corrs, 0, "STS")
    stats(empty_corrs, 1, "NTS1")
    stats(empty_corrs, 2, "NTS2")
    print("\n--- SB bursts ---")
    stats(sb_corrs, 0, "STS")
    stats(sb_corrs, 1, "NTS1")
    stats(sb_corrs, 2, "NTS2")

    # Power envelope per symbol across empty vs SB:
    burst_len = int(BURST_SYMBOLS * sps)
    def envelope(arr):
        per_sym = []
        sample_cnt = min(len(arr), 200)
        for a in arr[:sample_cnt]:
            gpos = int(a[3])
            start = int(gpos - l_sts * sps)
            if start < 0 or start + burst_len > n:
                continue
            seg = np.abs(iq[start:start + burst_len])
            # Bin to BURST_SYMBOLS bins
            bins = np.array_split(seg, BURST_SYMBOLS)
            e = np.array([np.mean(b) for b in bins])
            per_sym.append(e)
        per_sym = np.array(per_sym)
        return per_sym

    emp_env = envelope(empty_corrs)
    sb_env = envelope(sb_corrs)
    if len(emp_env) and len(sb_env):
        emp_mean = np.mean(emp_env, axis=0)
        sb_mean = np.mean(sb_env, axis=0)
        # Ratio empty/SB per symbol-index (early/mid/late)
        ratio = emp_mean / (sb_mean + 1e-12)
        print("\nEnvelope ratio empty/SB (per 25-symbol-block):")
        for i in range(0, BURST_SYMBOLS, 25):
            j = min(i + 25, BURST_SYMBOLS)
            print(f"  sym {i:3d}..{j-1:3d}  empty/SB = {np.mean(ratio[i:j]):.3f}")

    # Check for unknown training sequence: look at symbol correlation pattern
    # within empty bursts. If there's a constant segment, DFT of the symbol
    # differences should show a peak.
    print("\n--- Hidden-training check (differential symbol stability) ---")
    stab = []
    for a in empty_corrs[:300]:
        gpos = int(a[3])
        start = int(gpos - l_sts * sps)
        if start < 0 or start + burst_len > n:
            continue
        seg = iq[start:start + burst_len]
        sym_idx = np.round(np.arange(BURST_SYMBOLS) * sps).astype(int)
        sym_idx = np.clip(sym_idx, 0, len(seg) - 1)
        sym = seg[sym_idx]
        d = sym[1:] * np.conj(sym[:-1])
        stab.append(d)
    if stab:
        stab = np.array(stab)  # shape (N, 254)
        # For each differential position, variance of angle across bursts
        ang = np.angle(stab)
        # Circular std — training-seq positions have low std (same pattern every burst)
        z = np.mean(np.exp(1j * ang), axis=0)
        circ_std = np.sqrt(-2 * np.log(np.abs(z) + 1e-12))
        print(f"circ_std over {len(stab)} empty bursts (low → hidden training):")
        for i in range(0, len(circ_std), 20):
            lo = np.min(circ_std[i:i+20])
            print(f"  sym-diff {i:3d}..{min(i+19, len(circ_std)-1):3d}  "
                  f"min circ_std = {lo:.3f}")
        # Flag any window with median << 1.0
        med = np.median(circ_std)
        print(f"median circ_std = {med:.3f} (random≈1.48, fixed≈0)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    args = ap.parse_args()
    analyze(args.wav)
