#!/usr/bin/env python3
"""analyze_empty_bits.py — Dumpt die Bits der -"empty"-Bursts.
Prüft Identität, vergleicht gegen ETSI-Burst-Formate (SDB/NSB/NDB),
sucht Training-Sequenz-Treffer an allen Offset-Positionen.
"""
import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, BURST_SYMBOLS,
    SDB_OFF_SB1, SDB_OFF_STS, SDB_SB1,
    NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2,
    NDB_OFF_BLK1, NDB_OFF_BB1, NDB_OFF_NTS, NDB_OFF_BLK2,
    STS_DIBITS, STS_DIFF_REF,
    NTS1_DIBITS, NTS1_DIFF_REF,
    NTS2_DIBITS, NTS2_DIFF_REF,
    dibits_to_symbols, demod_pi4dqpsk,
    _correlate_at,
    load_iq_file, estimate_freq_offset, rrc_filter,
    scrambler_seq, decode_channel, parse_sysinfo_sb,
)
from schedule import _phase_correct


def dibit_match_rate(dibits_a, dibits_ref):
    """How many dibits match at the given alignment (0..len(ref))."""
    L = min(len(dibits_a), len(dibits_ref))
    return np.sum(np.array(dibits_a[:L]) == np.array(dibits_ref[:L])) / L


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

    # Demod each empty burst to 254 dibits (255 symbols minus 1 from differential)
    burst_len = int(BURST_SYMBOLS * sps)
    dibit_bursts = []
    for gpos in empty_gpos[:200]:
        # Grid gpos is where STS would be — anchor to burst start:
        burst_start = int(gpos - l_sts * sps)
        if burst_start < 0 or burst_start + burst_len > n:
            continue
        seg = iq[burst_start:burst_start + burst_len]
        sidx = np.round(np.arange(BURST_SYMBOLS) * sps).astype(int)
        sidx = np.clip(sidx, 0, len(seg) - 1)
        syms = seg[sidx]
        dibits = demod_pi4dqpsk(syms)  # len 254
        dibit_bursts.append(dibits)
    dibit_bursts = np.array(dibit_bursts, dtype=np.int32)  # shape (N, 254)
    print(f"demoded {len(dibit_bursts)} empty bursts")

    # Check identity: majority-vote dibit, Hamming distance
    maj = np.zeros(254, dtype=np.int32)
    agreement = np.zeros(254, dtype=np.float64)
    for i in range(254):
        counts = np.bincount(dibit_bursts[:, i], minlength=4)
        maj[i] = int(np.argmax(counts))
        agreement[i] = counts.max() / dibit_bursts.shape[0]
    print(f"\nPer-position dibit agreement: min={agreement.min():.3f} "
          f"median={np.median(agreement):.3f} max={agreement.max():.3f}")
    # How many positions have >90 % agreement?
    fixed = int((agreement >= 0.90).sum())
    print(f"{fixed}/254 positions have ≥90 % dibit agreement (fixed content)")

    # Print the majority-vote dibit sequence:
    print("\nMajority-vote dibit sequence (254 dibits, '?' where agreement<0.5):")
    line = ""
    for i, (d, a) in enumerate(zip(maj, agreement)):
        c = f"{d:02b}" if a >= 0.5 else "??"
        line += c + " "
        if (i + 1) % 20 == 0:
            print(f"  {i-19:3d}: {line}")
            line = ""
    if line:
        print(f"  {254-len(line.split()):3d}: {line}")

    # Search for STS/NTS1/NTS2 matches at ANY position within the majority burst
    print("\nTraining-Seq match rate sweep against majority dibits:")
    for name, ref in [("STS", STS_DIBITS), ("NTS1", NTS1_DIBITS), ("NTS2", NTS2_DIBITS)]:
        L = len(ref)
        best_rate = 0.0; best_pos = 0
        for off in range(len(maj) - L):
            r = dibit_match_rate(maj[off:off+L], ref)
            if r > best_rate:
                best_rate = r; best_pos = off
        print(f"  {name:5s} best match at dibit-pos {best_pos:3d} → "
              f"{int(best_rate*L)}/{L} dibits ({best_rate*100:.1f} %)")

    # Check TETRA TAIL pattern at start/end:
    # Per π/4-DQPSK spec, TAIL bits are zero → dibit 0b00 (first dibit after initial phase).
    # Actually for differential demod, first dibit depends on initial phase; TAIL shows up
    # as a specific consecutive dibit pattern.  Just print the first 10 and last 10:
    print(f"\nFirst 10 dibits:  " + " ".join(f"{d:02b}" for d in maj[:10]))
    print(f"Last 10 dibits:   " + " ".join(f"{d:02b}" for d in maj[-10:]))

    # Try bit-level descrambling with various seeds against a few PDU-sized slices:
    # If this is a SYSINFO-like PDU, scrambler seed 3 (BSCH) or network-scramble(CC,MCC,MNC)
    # would decode.  Raw bits from dibits (MSB-first):
    bits = np.zeros(254 * 2, dtype=np.int32)
    bits[0::2] = (maj >> 1) & 1
    bits[1::2] = maj & 1
    print(f"\nRaw bit-stream (first 64 bits):")
    print("  " + "".join(str(b) for b in bits[:64]))
    print(f"Raw bit-stream (bits 64..128):")
    print("  " + "".join(str(b) for b in bits[64:128]))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("wav")
    args = ap.parse_args()
    analyze(args.wav)
