#!/usr/bin/env python3
"""probe_sb_detail.py — detailed bit-level mismatch map on strongest SB burst."""
import sys, numpy as np
sys.path.insert(0, 'scripts')
import decode_dl as dd
from verify_sb1_encoder import sw_encode_bsch, CFG, scramble_bsch, interleave_bsch, puncture_r23, conv_encode_r14, crc16, build_pdu

def load_and_filter(path):
    iq, sr = dd.load_iq_file(path)
    cfo = dd.estimate_freq_offset(iq, sr)
    t = np.arange(len(iq)) / sr
    iq = iq * np.exp(-2j * np.pi * cfo * t)
    sps = sr / dd.SYMBOL_RATE
    rrc = dd.rrc_filter(int(6*sps)*2+1, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')
    return iq, sr, sps

def get_sb1_bits(iq, sts_off, sps):
    l_sts = dd.SDB_OFF_STS; l_sb1 = dd.SDB_OFF_SB1
    best_t = 0.0; best_c = 0.0
    for dt in np.linspace(-1.0, 1.0, 41):
        c = dd._correlate_at(iq, sts_off + dt, sps, dd.STS_DIBITS, dd.STS_DIFF_REF)
        if c > best_c: best_c = c; best_t = dt
    burst_start = sts_off + best_t - l_sts * sps
    sym_idx = np.round(np.arange(dd.BURST_SYMBOLS) * sps + burst_start).astype(int)
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
    sb1_b = dd.dibits_to_bits(db[l_sb1-1 : l_sb1-1 + dd.SDB_SB1])
    return sb1_b, best_c

def main(path):
    iq, sr, sps = load_and_filter(path)
    # Scan for strongest STS
    n = len(iq)
    step = max(1, int(sps / 2))
    scan_limit = min(n - int(dd.BURST_SYMBOLS * sps), n)
    sts_peaks = []
    for offset in range(0, scan_limit, step):
        c = dd._correlate_at(iq, offset, sps, dd.STS_DIBITS, dd.STS_DIFF_REF)
        if c >= 0.5: sts_peaks.append((offset, c))
    sts_peaks.sort(key=lambda x: -x[1])
    bs = dd.BURST_SYMBOLS * sps
    deduped = []
    for off, c in sts_peaks:
        if all(abs(off - po) >= bs/2 for po, _ in deduped): deduped.append((off, c))
        if len(deduped) >= 20: break

    # Aggregate over 10 best bursts: for each (TN,FN,MN) find bit positions that match
    print(f"Top {len(deduped)} STS; probing...")

    # Stage-level probes: compare air bits to reference at each stage
    # Stages in reverse: type5 (post-scramble) → type4i (post-interleave) →
    #                    type4 (post-puncture) → type3 (80 bit) → type2 (76 bit)
    best_matches = []
    for sts_off, sts_corr in deduped[:10]:
        sb1_b, corr = get_sb1_bits(iq, sts_off, sps)
        # Find best (TN,FN,MN) by matching to post-scramble reference
        best = (121, None)
        for tn in range(4):
            for fn in range(1, 19):
                for mn in range(1, 61):
                    ref5 = np.array(sw_encode_bsch(CFG, tn, fn, mn))
                    d = int(np.sum(sb1_b != ref5))
                    if d < best[0]: best = (d, (tn, fn, mn))
        best_matches.append((sts_off, corr, best[0], best[1], sb1_b))

    # Pick burst with lowest BER
    best_matches.sort(key=lambda x: x[2])
    sts_off, corr, ber, (tn, fn, mn), sb1_b = best_matches[0]
    print(f"\nBest burst: STS={sts_off} corr={corr:.3f} BER={ber}/120 TN={tn} FN={fn} MN={mn}")

    # Compute each reference stage
    pdu  = build_pdu(CFG, tn, fn, mn)                     # 60 bits
    t2   = crc16(pdu)                                      # 76 bits
    t3   = t2 + [0, 0, 0, 0]                              # 80 bits
    mother = conv_encode_r14(t3)                          # 320 bits
    t4   = puncture_r23(mother)                           # 120 bits
    t4i  = interleave_bsch(t4)                            # 120 bits
    t5   = scramble_bsch(t4i)                             # 120 bits

    # Compare air sb1_b directly to each stage
    sb1_d = sb1_b ^ dd.scrambler_seq(3, 120)              # air descrambled
    stages = [
        ('type5 (post-scramble)  [air raw]',  sb1_b, t5),
        ('type4i (post-interleave) [air descr]', sb1_d, t4i),
    ]
    for label, a, b in stages:
        d = int(np.sum(np.array(a) != np.array(b)))
        print(f"  {label:50s}  BER={d}/120")

    # Find specific bits that differ (post-scramble compare)
    diffs = [(i, int(sb1_b[i]), int(t5[i])) for i in range(120) if sb1_b[i] != t5[i]]
    print(f"\nDiff positions (sb1_b vs type5):")
    print("  " + " ".join(str(i) for i, _, _ in diffs))

    # Bit map: '.'=match, 'X'=mismatch
    bitmap = ''.join('X' if sb1_b[i] != t5[i] else '.' for i in range(120))
    print("  " + bitmap)

    # Find specific positions after deinterleaving (inverse permutation)
    # De-interleave the bitmap: where mismatches come from in t4 (pre-interleave)
    print("\nPre-interleave mismatch map (120 bits = rate-2/3 output):")
    # For bit at pos j in t4i, originates from k where j = 1 + (11*k)%120
    # So inverse: for pos k in t4, ends up at j
    # We want to see diffs in t4 space: air_descr vs t4
    t4_diffs = [i for i in range(120) if sb1_d[i] != t4i[i]]
    # Reverse the interleave: find the k that produced each j
    # interleave: out[j-1] = in[k-1], j = 1 + (11*k) % 120
    air_t4 = [0]*120
    ref_t4 = [0]*120
    for k in range(1, 121):
        j = 1 + (11*k) % 120
        air_t4[k-1] = int(sb1_d[j-1])
        ref_t4[k-1] = t4[k-1]
    bm_t4 = ''.join('X' if air_t4[i] != ref_t4[i] else '.' for i in range(120))
    print("  " + bm_t4)

    # Now split into mother-code triplets (g1a, g2a, g1b): positions 3*i, 3*i+1, 3*i+2
    print("\nPer triplet (g1_even, g2_even, g1_odd) mismatches:")
    for i in range(0, 120, 3):
        trip = bm_t4[i:i+3]
        if 'X' in trip:
            print(f"  pos {i:3d}: {trip}  air={air_t4[i:i+3]} ref={ref_t4[i:i+3]}")

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'baseband_438347180Hz_10-23-54_21-04-2026.wav')
