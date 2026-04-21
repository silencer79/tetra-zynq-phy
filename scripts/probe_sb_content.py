#!/usr/bin/env python3
"""probe_sb_content.py — extract strongest SB1 burst from WAV, compare to
SW-ref encoder output for every possible (TN, FN, MN) combination.
Minimum Hamming distance localises the mismatch."""

import sys
import numpy as np

sys.path.insert(0, 'scripts')
import decode_dl as dd
from verify_sb1_encoder import sw_encode_bsch, CFG

def main(path):
    iq, sr = dd.load_iq_file(path)
    print(f"Loaded {path}: sr={sr} n={len(iq)}")

    cfo = dd.estimate_freq_offset(iq, sr)
    print(f"CFO: {cfo:+.1f} Hz")
    t = np.arange(len(iq)) / sr
    iq = iq * np.exp(-2j * np.pi * cfo * t)

    # Decimate to ~144 kHz (8 sps)
    sps_target = 8
    target_rate = dd.SYMBOL_RATE * sps_target
    decim = max(1, int(sr / target_rate))
    actual_rate = sr / decim
    sps = actual_rate / dd.SYMBOL_RATE
    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sr
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2))
        h *= np.hanning(ntaps)
        h /= np.sum(h)
        iq = np.convolve(iq, h, mode='same')[::decim]

    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = dd.rrc_filter(rrc_ntaps, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')
    print(f"After filter: sps={sps:.3f}, rate={actual_rate:.0f}")

    # STS scan
    n = len(iq)
    step = max(1, int(sps / 2))
    scan_limit = min(n - int(dd.BURST_SYMBOLS * sps), n)
    sts_peaks = []
    for offset in range(0, scan_limit, step):
        c = dd._correlate_at(iq, offset, sps, dd.STS_DIBITS, dd.STS_DIFF_REF)
        if c >= 0.5:
            sts_peaks.append((offset, c))
    sts_peaks.sort(key=lambda x: -x[1])
    burst_spacing = dd.BURST_SYMBOLS * sps
    deduped = []
    for off, c in sts_peaks:
        if all(abs(off - po) >= burst_spacing / 2 for po, _ in deduped):
            deduped.append((off, c))
        if len(deduped) >= 20:
            break
    print(f"Top STS candidates: {len(deduped)}")
    for i, (o, c) in enumerate(deduped[:5]):
        print(f"  #{i}: off={o}  corr={c:.3f}")

    # For each top candidate: extract SB1, descramble, search (TN,FN,MN)
    print("\n=== SB1 content probe (top 10 bursts) ===")
    l_sts = dd.SDB_OFF_STS
    l_sb1 = dd.SDB_OFF_SB1

    for idx, (sts_off, sts_corr) in enumerate(deduped[:10]):
        # Refine timing
        best_t = 0.0; best_c = 0.0
        for dt in np.linspace(-1.0, 1.0, 41):
            c = dd._correlate_at(iq, sts_off + dt, sps, dd.STS_DIBITS, dd.STS_DIFF_REF)
            if c > best_c:
                best_c = c; best_t = dt

        burst_start = sts_off + best_t - l_sts * sps
        sym_idx = np.round(np.arange(dd.BURST_SYMBOLS) * sps + burst_start).astype(int)
        if sym_idx[-1] >= len(iq) or sym_idx[0] < 0:
            continue
        sym_idx = np.clip(sym_idx, 0, len(iq) - 1)
        bsyms = iq[sym_idx]

        sts_ref = dd.dibits_to_symbols(dd.STS_DIBITS)
        sts_dr = sts_ref[1:] * np.conj(sts_ref[:-1])
        s_idx = np.arange(len(dd.STS_DIBITS)) + l_sts
        ss = bsyms[s_idx]
        sd = ss[1:] * np.conj(ss[:-1])
        pe = np.angle(sd * np.conj(sts_dr))
        if len(pe) > 1:
            sl, ic = np.polyfit(np.arange(len(pe)), pe, 1)
            nr = np.arange(dd.BURST_SYMBOLS, dtype=np.float64) - float(l_sts)
            bsyms = bsyms * np.exp(-1j * (ic * nr + 0.5 * sl * nr * (nr - 1.0)))

        db = dd.demod_pi4dqpsk(bsyms)
        sb1_s = l_sb1 - 1
        if sb1_s + dd.SDB_SB1 > len(db): continue
        sb1_b = dd.dibits_to_bits(db[sb1_s : sb1_s + dd.SDB_SB1])
        sb1_d = (sb1_b ^ dd.scrambler_seq(3, 120)) & 1

        # Brute match
        best = (121, None)
        for tn in range(4):
            for fn in range(1, 19):
                for mn in range(1, 61):
                    ref = sw_encode_bsch(CFG, tn, fn, mn)
                    diffs = int(np.sum(sb1_d != np.array(ref)))
                    if diffs < best[0]:
                        best = (diffs, (tn, fn, mn))
        ber, (tn, fn, mn) = best

        # Also try: without descrambling
        best_raw = 121
        for tn2 in range(4):
            for fn2 in range(1, 19):
                for mn2 in range(1, 61):
                    ref = sw_encode_bsch(CFG, tn2, fn2, mn2)
                    diffs = int(np.sum(sb1_b != np.array(ref)))
                    if diffs < best_raw:
                        best_raw = diffs

        # And: dibit-bit swap
        sb1_swap = sb1_b.copy()
        for i in range(0, len(sb1_swap)-1, 2):
            sb1_swap[i], sb1_swap[i+1] = sb1_swap[i+1], sb1_swap[i]
        sb1_swap_d = (sb1_swap ^ dd.scrambler_seq(3, 120)) & 1
        best_swap = 121
        for tn2 in range(4):
            for fn2 in range(1, 19):
                for mn2 in range(1, 61):
                    ref = sw_encode_bsch(CFG, tn2, fn2, mn2)
                    diffs = int(np.sum(sb1_swap_d != np.array(ref)))
                    if diffs < best_swap:
                        best_swap = diffs

        print(f"#{idx} corr={sts_corr:.3f}: min BER={ber}/120 at TN={tn} FN={fn} MN={mn}"
              f"  noscr={best_raw}  swap={best_swap}")

if __name__ == '__main__':
    main(sys.argv[1])
