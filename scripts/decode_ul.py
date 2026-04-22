#!/usr/bin/env python3
"""
decode_ul.py — Decode MS uplink Random-Access bursts from SDR WAV.

Pipeline:
  1. Load WAV + RRC matched filter + freq offset correct (from verify_ul_ra_burst)
  2. Detect bursts via power threshold
  3. Per burst: sub-symbol refine on x-sequence → anchor
  4. Demod 127 symbols centered on anchor → 254 bits
  5. Extract blk1 (108 bits before x) + blk2 (108 bits after x)
  6. Descramble with cell scrambling code
  7. Try SCH/HU channel decode (K=168, a=13, info=92) across hypotheses
     of which 168 bits of the 216-bit payload are type-5 coded

Usage:
    python3 scripts/decode_ul.py <wavfile> [--cc 49 --mcc 901 --mnc 9998]
"""
import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, estimate_freq_offset, rrc_filter,
    dibits_to_bits, make_scramb_code,
    decode_channel_soft, demod_pi4dqpsk_soft,
    _build_diff_ref, _correlate_at,
)


def scrambler_seq_etsi(init, length):
    """ETSI EN 300 392-2 §8.2.5.2 scrambler.
    c(x) = 1 + X + X² + X⁴ + X⁵ + X⁷ + X⁸ + X¹⁰ + X¹¹ + X¹² + X¹⁶ + X²² + X²³ + X²⁶ + X³²
    Feedback taps at c_i=1 for i ∈ {1,2,4,5,7,8,10,11,12,16,22,23,26,32}.
    For a right-shift LFSR (bit 0 = most recent output, new bit enters at bit 31),
    the lfsr positions for feedback are (i-1): {0,1,3,4,6,7,9,10,11,15,21,22,25,31}.
    init: 32-bit initial state.
    Returns length bits of scrambler sequence.
    """
    lfsr = init & 0xFFFFFFFF
    if lfsr == 0:
        lfsr = 0xFFFFFFFF
    seq = np.zeros(length, dtype=np.int32)
    taps = [0, 1, 3, 4, 6, 7, 9, 10, 11, 15, 21, 22, 25, 31]
    for i in range(length):
        b = 0
        for t in taps:
            b ^= (lfsr >> t) & 1
        seq[i] = b
        lfsr = (lfsr >> 1) | (b << 31)
    return seq


def descramble_soft_etsi(soft_bits, init, length):
    scr = scrambler_seq_etsi(init, length)
    return soft_bits * (1.0 - 2.0 * scr)
from verify_ul_ra_burst import X_DIBITS, X_DIFF_REF, find_bursts


# ETSI EN 300 392-2 §9.4.4.2.1 Table 9.3 — Control Uplink Burst (CB):
#   tail(4 bits=2 sym) + cb1(84 bits=42 sym) + x(30 bits=15 sym)
#   + cb2(84 bits=42 sym) + tail(4 bits=2 sym) = 206 bits = 103 symbols
# The 168 control bits (cb1+cb2) form one SCH/HU type-5 block.
RA_CB_BITS = 84       # per half-block
RA_CB_SYMS = 42       # per half-block
RA_X_SYMS  = 15
RA_TAIL_SYMS = 2


def refine_x_position(iq, sps, coarse_pos, search_syms=5):
    """Find precise sub-symbol position of x-sequence.
    Returns (best_pos, best_corr)."""
    best_c = 0.0
    best_pos = coarse_pos
    # Fine search ±search_syms around coarse_pos, step = sps/16
    step = max(1, sps / 16.0)
    n = int(round(2 * search_syms * sps / step))
    for k in range(-n // 2, n // 2 + 1):
        pos = coarse_pos + k * step
        c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
        if c > best_c:
            best_c = c
            best_pos = pos
    return best_pos, best_c


def demod_pi4dqpsk_soft_etsi(symbols):
    """ETSI-correct soft demod (matches MS transmitter).
    Per EN 300 392-2: dibit 00→+π/4, 01→−π/4, 10→+3π/4, 11→−3π/4.
    b1 (MSB) = 1 when |dphi|>π/2 (cos<0)
    b0 (LSB) = 1 when dphi<0    (sin<0)
    Returns soft[2N-2]: positive=0, negative=1.
    """
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    soft = np.empty(len(dphi) * 2, dtype=np.float64)
    for i, p in enumerate(dphi):
        soft[2 * i]     = -np.cos(p)  # b1 (MSB): negate cos, so cos<0 → positive → bit=0 is when |dphi|<π/2
        soft[2 * i + 1] =  np.sin(p)  # b0 (LSB): sin>0 (dphi>0) → positive → bit=0
    # Wait: we want positive=0 (bit), negative=1. For b1: bit=1 when |dphi|>π/2 (i.e. cos<0).
    # If cos<0, -cos>0 → bit=0. That's wrong. Fix: flip sign.
    # Redo: b1 bit-value = (cos<0 ? 1 : 0). Soft metric positive=0: soft_b1 = cos.
    for i, p in enumerate(dphi):
        soft[2 * i]     = np.cos(p)   # b1: cos>0 (|dphi|<π/2) → 0
        soft[2 * i + 1] = np.sin(p)   # b0: sin>0 (dphi>0) → 0
    return soft


def sample_cb_soft_bits(iq, sps, x_start_pos):
    """Sample soft-demod bits for cb1+cb2 (168 bits = SCH/HU type-5).
    x_start_pos = sample position where x-sequence begins.
    Burst layout (symbol index relative to cb1 start):
      sym 0..41  = cb1 (42 sym, 84 bits)
      sym 42..56 = x (15 sym)
      sym 57..98 = cb2 (42 sym, 84 bits)
    x_start_pos ↔ sym index 42.
    For diff demod we sample one extra reference symbol before each block.
    Returns (cb1_soft[84], cb2_soft[84]).
    """
    burst_cb1_start = x_start_pos - RA_CB_SYMS * sps  # sample pos of cb1 sym 0

    # cb1: need RA_CB_SYMS+1 = 43 samples (1 ref + 42 diff dibits = 84 bits)
    # Reference sym = tail-bit sym just before cb1 (= x_start - (RA_CB_SYMS+1)*sps)
    cb1_idx = np.round(burst_cb1_start - sps + np.arange(RA_CB_SYMS + 1) * sps).astype(int)
    cb1_idx = np.clip(cb1_idx, 0, len(iq) - 1)
    cb1_syms = iq[cb1_idx]
    cb1_soft = demod_pi4dqpsk_soft_etsi(cb1_syms)  # ETSI mapping

    # cb2: starts RA_X_SYMS syms after x_start. Use last x-seq sym as reference.
    cb2_start = x_start_pos + RA_X_SYMS * sps
    cb2_idx = np.round(cb2_start - sps + np.arange(RA_CB_SYMS + 1) * sps).astype(int)
    cb2_idx = np.clip(cb2_idx, 0, len(iq) - 1)
    cb2_syms = iq[cb2_idx]
    cb2_soft = demod_pi4dqpsk_soft_etsi(cb2_syms)

    return cb1_soft, cb2_soft


def try_schhu_decode(cb1_soft, cb2_soft, scramb_init):
    """Decode SCH/HU (168 type-5 → 92 type-1 MAC-ACCESS PDU).
    Tries multiple hypotheses and returns best result.
    """
    variants = [
        ('etsi_cb1cb2', np.concatenate([cb1_soft, cb2_soft]),       descramble_soft_etsi),
        ('etsi_cb2cb1', np.concatenate([cb2_soft, cb1_soft]),       descramble_soft_etsi),
    ]
    # Also try the old decode_dl scrambler (original taps)
    from decode_dl import scrambler_seq as _scr_old
    def descramble_old(soft, init, length):
        scr = _scr_old(init, length)
        return soft * (1.0 - 2.0 * scr)
    variants.append(('old_cb1cb2', np.concatenate([cb1_soft, cb2_soft]), descramble_old))
    variants.append(('old_cb2cb1', np.concatenate([cb2_soft, cb1_soft]), descramble_old))

    best = (False, None, None, None)
    for name, soft_t5, descr in variants:
        soft_desc = descr(soft_t5, scramb_init, 168)
        try:
            crc_ok, info_bits, _ = decode_channel_soft(soft_desc, K=168, a=13, info_bits_len=92)
        except Exception:
            continue
        hard = (soft_desc < 0).astype(np.int32)
        if crc_ok:
            return True, info_bits, hard, name
        if best[1] is None:
            best = (crc_ok, info_bits, hard, name)
    return best + (None,) if len(best) == 4 else best


def bits_to_hex(bits):
    """Pack MSB-first bits to hex string."""
    bits = list(int(b) for b in bits)
    # Pad to byte boundary
    while len(bits) % 8 != 0:
        bits.append(0)
    out = []
    for i in range(0, len(bits), 8):
        byte = 0
        for b in bits[i:i+8]:
            byte = (byte << 1) | (b & 1)
        out.append(f"{byte:02X}")
    return ' '.join(out)


def parse_mac_access(bits92):
    """Crude MAC-ACCESS PDU field parser per §21.4.3.3 (minimal)."""
    if bits92 is None or len(bits92) < 20:
        return None
    b = [int(x) & 1 for x in bits92]
    def field(start, n):
        v = 0
        for i in range(n):
            v = (v << 1) | b[start + i]
        return v
    pdu_type = field(0, 2)
    fill_bit = b[2]
    # PDU type 0 = MAC-ACCESS
    out = {'pdu_type': pdu_type, 'fill_bit': fill_bit}
    if pdu_type == 0:
        out['encryption_mode'] = field(3, 2)
        out['access_ack'] = field(5, 1)
        # random ID, length indicator, address type etc. — abbreviated
        out['addr_type'] = field(6, 3)
        out['short_ssi_or_event_label'] = field(9, 10)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav_file')
    ap.add_argument('--cc', type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--threshold-db', type=float, default=15.0)
    ap.add_argument('--swap-iq', action='store_true')
    ap.add_argument('--max-bursts', type=int, default=50)
    ap.add_argument('--dump-bits', action='store_true',
                    help='Print raw descrambled bits for each burst')
    args = ap.parse_args()

    iq, sr = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    if sr is None:
        print('ERROR: wav required', file=sys.stderr); return 1
    print(f'WAV: {args.wav_file}  sr={sr}  dur={len(iq)/sr:.2f}s')

    iq = iq / (np.median(np.abs(iq)) + 1e-12)
    f_off = estimate_freq_offset(iq, sr)
    print(f'  freq offset: {f_off:+.1f} Hz')
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
    print(f'  sps={sps:.3f}')

    # RRC matched filter
    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0: ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq = np.convolve(iq, h, mode='same')

    # Find bursts
    bursts, noise, thresh = find_bursts(iq, sps, threshold_db=args.threshold_db)
    print(f'  {len(bursts)} bursts detected')
    if not bursts: return 1

    # Cell scrambling init
    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'  scrambler init: 0x{scramb_init:08X} (CC={args.cc} MCC={args.mcc} MNC={args.mnc})')
    print()

    crc_hits = 0
    decoded_pdus = []
    type5_patterns = []

    print(f'  {"#":>3} {"time_s":>8} {"corrX":>6} {"CRC":>4}  {"PDU bytes[0:6]":>20}')
    for i, (s, l) in enumerate(bursts[:args.max_bursts]):
        coarse_search_start = s
        coarse_search_end   = s + l - int(15 * sps)
        best_c = 0
        best_pos = s + int(42 * sps)  # expect x near cb1-end
        step = max(1, int(round(sps / 4)))
        for pos in range(coarse_search_start, coarse_search_end, step):
            c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
            if c > best_c:
                best_c = c
                best_pos = pos
        x_pos, x_corr = refine_x_position(iq, sps, best_pos, search_syms=2)

        if x_corr < 0.5:
            print(f'  {i:3d} {s/sr_dec:8.3f} {x_corr:6.3f}  SKIP (weak x)')
            continue

        cb1_soft, cb2_soft = sample_cb_soft_bits(iq, sps, x_pos)
        result = try_schhu_decode(cb1_soft, cb2_soft, scramb_init)
        crc_ok, info_bits, type5_hard = result[0], result[1], result[2]
        variant = result[3] if len(result) > 3 and result[3] else ''
        type5_patterns.append(type5_hard)

        tag = 'OK' if crc_ok else '-'
        pdu_hex = bits_to_hex(info_bits[:48])[:23] if info_bits is not None else ''
        print(f'  {i:3d} {s/sr_dec:8.3f} {x_corr:6.3f}  {tag:>4} {variant:>12}  {pdu_hex}')
        if crc_ok:
            crc_hits += 1
            decoded_pdus.append(info_bits)

    print()
    print(f'=== SCH/HU CRC-pass: {crc_hits} / {len(type5_patterns)} ===')

    if type5_patterns:
        arr = np.array(type5_patterns, dtype=np.int8)
        ref = arr[0]
        print()
        print('=== Descrambled type-5 (168 bit) match vs burst #0 ===')
        matches = np.mean(arr == ref, axis=1)
        for i, m in enumerate(matches[:min(20, len(matches))]):
            print(f'  #{i:3d}: {m*100:5.1f}%  hex[0:12]={bits_to_hex(arr[i][:96])}')

    if decoded_pdus:
        print()
        print('=== Decoded MAC-ACCESS PDU (92 bits) ===')
        for i, pdu in enumerate(decoded_pdus[:10]):
            parsed = parse_mac_access(pdu)
            print(f'  #{i}: {bits_to_hex(pdu)}  parsed={parsed}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
