#!/usr/bin/env python3
"""verify_empty_power.py — Prüft, ob "empty"-Bursts echtes RF-Stille sind
(non-continuous DL) oder nur Zero-Payload-Füller (continuous DL).

Methode:
  - anchor per BSCH wie in schedule.py
  - pro Burst: RMS(|IQ|) über 255 Symbol-Samples
  - aggregieren nach Klasse (SB / NDB1 / NDB2 / empty)
  - Verhältnis empty_RMS / SB_RMS → echtes Silence oder Filler?
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
    if layout is None:
        print("cell lock failed")
        return
    print(f"layout = {layout}")

    l_sts = SDB_OFF_STS if layout == 'continuous' else NSB_OFF_STS
    pos = anchor_sts_pos
    while pos - burst_spacing >= 0:
        pos -= burst_spacing
    grid = []
    while pos < n - int(BURST_SYMBOLS * sps):
        grid.append(pos)
        pos += burst_spacing

    burst_len = int(BURST_SYMBOLS * sps)
    sb_thresh, nts_thresh = 0.5, 0.55
    per_class = {'SB': [], 'NDB1': [], 'NDB2': [], 'empty': []}
    for gpos in grid:
        burst_start = gpos - l_sts * sps
        i0 = int(max(0, burst_start))
        i1 = int(min(n, i0 + burst_len))
        if i1 - i0 < burst_len // 2:
            continue
        seg = iq[i0:i1]
        rms = float(np.sqrt(np.mean(np.abs(seg) ** 2)))

        nts_pred = gpos + (NDB_OFF_NTS - l_sts) * sps
        _, s_c, _ = _phase_correct(iq, gpos, sps, l_sts,
                                    STS_DIBITS, STS_DIFF_REF)
        _, n1_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS1_DIBITS, NTS1_DIFF_REF)
        _, n2_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS2_DIBITS, NTS2_DIFF_REF)
        best_nts = max(n1_c, n2_c)
        if s_c >= best_nts and s_c >= sb_thresh:
            cls = 'SB'
        elif best_nts >= nts_thresh:
            cls = 'NDB1' if n1_c >= n2_c else 'NDB2'
        else:
            cls = 'empty'
        per_class[cls].append(rms)

    # Noise floor from long stretch between grid bursts (if any):
    print()
    print("Per-class burst RMS (|IQ|):")
    print(f"{'class':8s} {'count':>6s} {'mean':>10s} {'median':>10s} {'p10':>10s} {'p90':>10s}")
    for cls in ('SB', 'NDB1', 'NDB2', 'empty'):
        a = np.array(per_class[cls])
        if len(a) == 0:
            print(f"{cls:8s} {0:6d}")
            continue
        print(f"{cls:8s} {len(a):6d} {np.mean(a):10.4f} "
              f"{np.median(a):10.4f} {np.percentile(a, 10):10.4f} "
              f"{np.percentile(a, 90):10.4f}")

    if per_class['SB'] and per_class['empty']:
        r_sb = np.median(per_class['SB'])
        r_em = np.median(per_class['empty'])
        print()
        print(f"empty/SB median ratio = {r_em/r_sb:.3f}  "
              f"({20*np.log10(r_em/r_sb):+.1f} dB)")
        if r_em / r_sb < 0.3:
            print(">> echtes RF-Silence (non-continuous DL)")
        elif r_em / r_sb > 0.7:
            print(">> Filler-Burst mit voller RF-Energie (continuous DL)")
        else:
            print(">> teilweise gedämpft / Übergang")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    args = ap.parse_args()
    analyze(args.wav)
