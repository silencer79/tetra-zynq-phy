#!/usr/bin/env python3
"""
decode_ul_nub.py — UL Normal Up-link Burst (NUB) decoder

Companion to decode_ul.py which only handles Control-Uplink-Bursts (RA/CB).
NUB carries voice (TCH/S) and FACCH-during-voice signalling; uses NTS1 as
mid-amble (11 dibits @ symbols 110..120) instead of x-sequence.

NUB layout per ETSI EN 300 392-2 § 9.4.4.2.5 (cross-checked against
`rtl/rx/tetra_ul_nub_capture.v`):
  sym   0..  1   phase-adjust (2)
  sym   2..109   BKN1 (108 sym = 216 bits)
  sym 110..120   NTS1 (11 sym, mid-amble — sync anchor on sym 120 = NTS1[10])
  sym 121..228   BKN2 (108 sym = 216 bits)
  sym 229..230   tail (2)
Total = 231 sym × 4 sps @ 72 kHz baseband = 924 samples.

Pipeline:
  1. Load WAV (250 kHz native), decimate to 72 kHz (4 sps), RRC filter
  2. NTS1 sliding correlation → list of anchor positions (= NTS1[10])
  3. Per anchor: differential demod BKN1 (sym −118..−12 around anchor) and
     BKN2 (sym +1..+108), giving 432 raw type-5 bits
  4. Descramble with cell scrambling code (from --mcc/--mnc/--cc)
  5. Try SCH/F channel decode on each block — if CRC OK, that block is FACCH
  6. Parse FACCH MAC/LLC/MLE/CMCE/MM via tetra_cmce / tetra_mm

Usage:
    python3 scripts/decode_ul_nub.py <wavfile> [--mcc 901 --mnc 9998 --cc 49]
                                              [--threshold-db 12.0]
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, rrc_filter, dibits_to_bits, make_scramb_code,
    decode_channel_soft, NTS1_DIBITS, NTS1_DIFF_REF, _correlate_at,
    extract_bits,
)
from decode_ul import (
    estimate_freq_offset_dqpsk, demod_pi4dqpsk_soft_etsi,
    descramble_soft_etsi, scrambler_seq_etsi, parse_mac_access, format_parsed_mac_access,
)


# NUB layout in symbol counts relative to NTS1[10] anchor
NUB_BKN1_DIFFREF_OFF_SYM = -119   # symbol BEFORE BKN1[0] (= diff reference)
NUB_BKN1_FIRST_SYM       = -118
NUB_BKN1_LAST_SYM        = -11
NUB_NTS1_LAST_SYM        = 0      # anchor
NUB_BKN2_DIFFREF_OFF_SYM = 0      # anchor itself = BKN2 diff reference
NUB_BKN2_FIRST_SYM       = 1
NUB_BKN2_LAST_SYM        = 108


def correlate_nts1_grid(iq, sps, search_step_sym=1):
    """Slide NTS1 reference across the IQ stream at symbol resolution.

    Returns array of (pos_samples, correlation) tuples for peaks
    above threshold.
    """
    nts1_dibits = NTS1_DIBITS
    nts1_diff = NTS1_DIFF_REF
    # NTS1 reference spans 11 dibits — diff-correlation uses 10 pairs.
    # _correlate_at expects pos = first dibit position of the sequence.
    n_iq = len(iq)
    # NUB needs 119 syms before anchor and 108 after; we anchor at NTS1[10].
    # NTS1 starts at NTS1[10] - 10 sym; first dibit at NTS1[0] = anchor - 10 sym.
    # We pre-pad: leave room for BKN1 = 119 sym before NTS1[0] anchor.
    margin_sym = 130
    start_pos = int(margin_sym * sps)
    end_pos = n_iq - int((NUB_BKN2_LAST_SYM + 10) * sps)
    if end_pos <= start_pos:
        return np.array([])
    step = max(1, int(round(sps * search_step_sym)))
    corrs = []
    for pos in range(start_pos, end_pos, step):
        # pos = NTS1[0] location; _correlate_at uses 11-dibit window
        c = _correlate_at(iq, pos, sps, nts1_dibits, nts1_diff)
        corrs.append((pos, c))
    return np.array(corrs)


def refine_nts1(iq, sps, coarse_pos, search_syms=2):
    """Sub-symbol refinement of NTS1[0] position."""
    best_c = 0.0
    best_pos = coarse_pos
    step = max(1, sps / 16.0)
    n = int(round(2 * search_syms * sps / step))
    for k in range(-n // 2, n // 2 + 1):
        pos = coarse_pos + k * step
        c = _correlate_at(iq, pos, sps, NTS1_DIBITS, NTS1_DIFF_REF)
        if c > best_c:
            best_c = c
            best_pos = pos
    return best_pos, best_c


def find_nub_bursts(iq, sps, threshold=0.5, min_separation_sym=200):
    """Find NUB-burst NTS1[0] anchor positions.

    Returns list of (anchor_sample_pos, correlation, refined).
    min_separation_sym suppresses double-detections within a single burst
    (NUB length = 231 sym).
    """
    grid = correlate_nts1_grid(iq, sps, search_step_sym=1)
    if len(grid) == 0:
        return []
    # peak threshold = correlation above absolute threshold
    sel = grid[:, 1] > threshold
    if not np.any(sel):
        return []
    cand = grid[sel]
    # Non-maximum suppression
    cand_sorted = cand[np.argsort(-cand[:, 1])]
    accepted = []
    min_sep_smp = int(min_separation_sym * sps)
    for pos, c in cand_sorted:
        if all(abs(int(pos) - int(ap)) > min_sep_smp for ap, _, _ in accepted):
            ref_pos, ref_c = refine_nts1(iq, sps, pos)
            accepted.append((int(ref_pos), float(ref_c), float(c)))
    accepted.sort(key=lambda x: x[0])
    return accepted


def demod_nub_burst(iq, sps, nts1_pos, scramb_init=None):
    """Demod one NUB burst given NTS1[0] sample position.

    Returns dict with:
      bkn1_soft  — 216 soft bits (signed float, neg=1)
      bkn2_soft  — 216 soft bits
      bkn1_hard  — 216 hard bits
      bkn2_hard  — 216 hard bits
      nts1_corr  — correlation at refined position
      nts1_pos   — refined sample position of NTS1[0]
    Soft-bits are descrambled if `scramb_init` provided.
    """
    # NTS1[0] = nts1_pos. NTS1[10] (anchor) = nts1_pos + 10 sym.
    anchor = nts1_pos + 10 * sps
    bkn1_diffref_pos = anchor + NUB_BKN1_DIFFREF_OFF_SYM * sps  # = anchor − 119 sym
    bkn2_diffref_pos = anchor + NUB_BKN2_DIFFREF_OFF_SYM * sps  # = anchor

    # Sample 109 symbols centred on each block (1 ref + 108 data = 109)
    # to support differential demod with diff-ref preceding BKN[0].
    def sample_block(diffref_pos, n_data_sym):
        # n_data_sym+1 samples needed (diff-ref + 108 data syms)
        out = np.empty(n_data_sym + 1, dtype=np.complex128)
        for k in range(n_data_sym + 1):
            p = diffref_pos + k * sps
            ip = int(round(p))
            if 0 <= ip < len(iq):
                out[k] = iq[ip]
            else:
                out[k] = 0.0
        return out

    bkn1_syms = sample_block(bkn1_diffref_pos, 108)  # 109 syms total
    bkn2_syms = sample_block(bkn2_diffref_pos, 108)

    soft1 = demod_pi4dqpsk_soft_etsi(bkn1_syms)  # 216 soft bits (108 pairs × 2)
    soft2 = demod_pi4dqpsk_soft_etsi(bkn2_syms)

    if scramb_init is not None:
        # NUB descrambling: 432-bit stream (BKN1 || BKN2) XORed with one
        # scrambler run starting at sym 0. We descramble the concat then
        # split back.
        concat = np.concatenate([soft1, soft2])
        seq = scrambler_seq_etsi(scramb_init, 432)
        seq_arr = np.array([1 if b else 0 for b in seq])
        descr = concat * (1.0 - 2.0 * seq_arr)
        soft1 = descr[:216]
        soft2 = descr[216:432]

    hard1 = [1 if s < 0 else 0 for s in soft1]
    hard2 = [1 if s < 0 else 0 for s in soft2]
    # Refined correlation at landed position
    nts1_corr = _correlate_at(iq, nts1_pos, sps, NTS1_DIBITS, NTS1_DIFF_REF)

    return {
        "nts1_pos": float(nts1_pos),
        "nts1_corr": float(nts1_corr),
        "bkn1_soft": soft1,
        "bkn2_soft": soft2,
        "bkn1_hard": hard1,
        "bkn2_hard": hard2,
    }


def bits_to_hex(bits):
    """Pack bits MSB-first into hex bytes."""
    out = []
    for i in range(0, len(bits), 8):
        chunk = bits[i:i + 8]
        if len(chunk) < 8:
            chunk = chunk + [0] * (8 - len(chunk))
        v = 0
        for b in chunk:
            v = (v << 1) | (b & 1)
        out.append(f"{v:02X}")
    return " ".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav_file")
    ap.add_argument("--cc", type=int, default=49)
    ap.add_argument("--mcc", type=int, default=901)
    ap.add_argument("--mnc", type=int, default=9998)
    ap.add_argument("--threshold", type=float, default=0.5,
                    help="NTS1 correlation threshold (0..1)")
    ap.add_argument("--swap-iq", action="store_true")
    ap.add_argument("--max-bursts", type=int, default=200)
    ap.add_argument("--cfo", type=float, default=None,
                    help="Manual CFO override in Hz (skip auto-detection)")
    ap.add_argument("--dump-bits", action="store_true",
                    help="Print descrambled bits per burst")
    args = ap.parse_args()

    print(f"=== decode_ul_nub: {args.wav_file} ===")
    iq, sample_rate = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    print(f"  Loaded {len(iq)} samples @ {sample_rate} Hz ({len(iq)/sample_rate:.2f}s)")

    # CFO
    if args.cfo is not None:
        cfo = args.cfo
    else:
        cfo = estimate_freq_offset_dqpsk(iq, sample_rate)
    print(f"  CFO estimate: {cfo:+.1f} Hz")
    if cfo != 0:
        t = np.arange(len(iq)) / sample_rate
        iq = iq * np.exp(-1j * 2 * np.pi * cfo * t)

    # Decimate to ~8 sps (matches decode_ul.py convention)
    sps_raw = sample_rate / SYMBOL_RATE
    decim = max(1, int(round(sps_raw / 8)))
    if decim > 1:
        from scipy.signal import decimate
        iq = decimate(iq, decim, ftype='fir')
        sample_rate_dec = sample_rate / decim
    else:
        sample_rate_dec = sample_rate
    sps = sample_rate_dec / SYMBOL_RATE  # ~8 expected
    print(f"  Decimated by {decim} → {sample_rate_dec} Hz  sps={sps:.3f}")

    # RRC matched filter
    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0:
        ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq = np.convolve(iq, h, mode='same')

    # NTS1 burst detection
    scramb = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f"  ScrambCode: 0x{scramb:08X}")
    print(f"  Searching for NUB bursts via NTS1 correlation (thresh={args.threshold})...")
    bursts = find_nub_bursts(iq, sps, threshold=args.threshold)
    print(f"  {len(bursts)} NUB-burst candidates found")

    # Per-burst demod + FACCH-decode attempt
    facch_count = 0
    voice_count = 0
    for i, (pos, corr, _raw_c) in enumerate(bursts[:args.max_bursts]):
        t_s = pos / sample_rate_dec
        result = demod_nub_burst(iq, sps, pos, scramb_init=scramb)
        soft1 = result["bkn1_soft"]
        soft2 = result["bkn2_soft"]
        b1 = result["bkn1_hard"]
        b2 = result["bkn2_hard"]

        # Try SCH/F (full slot, K=432, a=103, info=268) on BKN1+BKN2 concat
        soft_concat = np.concatenate([soft1, soft2])
        ok_f, info_f, _ = decode_channel_soft(soft_concat, K=432, a=103, info_bits_len=268)
        # Try SCH/HD (half slot, K=216, a=101, info=124) on each block
        ok_hd1, info_hd1, _ = decode_channel_soft(soft1, K=216, a=101, info_bits_len=124)
        ok_hd2, info_hd2, _ = decode_channel_soft(soft2, K=216, a=101, info_bits_len=124)

        flag = ""
        decoded_info = None
        if ok_f:
            flag = "FACCH-SCH/F"
            decoded_info = info_f
        elif ok_hd1:
            flag = "FACCH-SCH/HD(BKN1)"
            decoded_info = info_hd1
        elif ok_hd2:
            flag = "FACCH-SCH/HD(BKN2)"
            decoded_info = info_hd2

        if flag:
            facch_count += 1
            print(f"-- NUB #{i:3d}  t={t_s:7.3f}s  corr={corr:.3f}  pos={pos}  {flag} --")
            # Convert numpy soft to int hard bits for parsing
            info_hard = [int(b) for b in decoded_info]
            print(f"  info[{len(info_hard)}]: {bits_to_hex(info_hard)}")
            # Parse as MAC-ACCESS PDU (FACCH carries MAC-RESOURCE / MAC-DATA on DL,
            # MAC-DATA / MAC-END-HU on UL — here we're decoding UL bursts).
            try:
                parsed = parse_mac_access(info_hard[:92])
                summary = format_parsed_mac_access(parsed)
                print(f"  {summary}")
            except Exception as e:
                print(f"  parse error: {e}")
        else:
            voice_count += 1
            if args.dump_bits:
                print(f"-- NUB #{i:3d}  t={t_s:7.3f}s  corr={corr:.3f} VOICE/noise --")
                print(f"  BKN1: {bits_to_hex(b1)}")
                print(f"  BKN2: {bits_to_hex(b2)}")

    print()
    print(f"=== Summary: {facch_count} FACCH PDU(s), {voice_count} voice/noise NUB-bursts ===")


if __name__ == "__main__":
    main()
