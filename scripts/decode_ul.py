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


from decode_dl import scrambler_seq as scrambler_seq_etsi


def descramble_soft_etsi(soft_bits, init, length):
    """Reuse canonical osmo-tetra / decode_dl scrambler.
    ETSI §8.2.5.2 polynomial — taps per osmo-tetra tetra_scramb.c ST(x,32-y)
    convention: [0,6,9,10,16,20,21,22,24,25,27,28,30,31]."""
    scr = scrambler_seq_etsi(init, length)
    return soft_bits * (1.0 - 2.0 * scr)
from verify_ul_ra_burst import X_DIBITS, X_DIFF_REF, find_bursts


# ETSI §9.4.4.2.1 Table 9.3 — Control Uplink Burst (CB, π/4-DQPSK):
#   tail(4b=2sym) + cb1(84b=42sym) + x(30b=15sym) + cb2(84b=42sym) + tail(4b=2sym)
#   = 206 bits = 103 symbols.  cb1+cb2 = 168 bits = SCH/HU type-5.
#
# Observed: verify_ul_ra_burst x-offset ~53.3 sym from power-detected start;
# burst_len 81-116 sym.  If CB (103 sym), x expected at sym 2+42=44 from absolute
# burst start.  Offset 53.3 = 9 sym into the burst → power-detection likely
# triggers 9 sym late OR the burst is longer.  Two candidate layouts supported.
RA_CB_SYMS    = 42       # CB half-block (SCH/HU = 168 type-5 bits)
RA_NUB_SYMS   = 54       # NUB/RAB half-block (216 type-5 bits)
RA_X_SYMS     = 15
RA_TAIL_SYMS  = 2


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
    """ETSI soft π/4-DQPSK differential demod.
    Per EN 300 392-2 §5.5.1 Table 5.3 (osmo-tetra pi4map=[1,3,7,5]):
      dibit 00 → +π/4     (sin>0, cos>0)
      dibit 01 → +3π/4    (sin>0, cos<0)
      dibit 10 → −π/4     (sin<0, cos>0)
      dibit 11 → −3π/4    (sin<0, cos<0)
    → b1 (MSB) = 1 when sin(dφ)<0  →  soft_b1 = sin(dφ)
    → b0 (LSB) = 1 when cos(dφ)<0  →  soft_b0 = cos(dφ)
    Returns soft[2N-2]: positive=0, negative=1.
    """
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    soft = np.empty(len(dphi) * 2, dtype=np.float64)
    soft[0::2] = np.sin(dphi)  # b1 (MSB)
    soft[1::2] = np.cos(dphi)  # b0 (LSB)
    return soft


def sample_half_soft_bits(iq, sps, x_start_pos, half_syms):
    """Sample soft-demod bits for blk1+blk2 surrounding the x-sequence.
    x_start_pos = sample position where x-sequence begins.
    half_syms   = number of symbols per half-block (42 for CB, 54 for NUB/RAB).
    Layout (sym index relative to blk1 start):
      sym 0..half-1                      = blk1 (half_syms sym, 2*half_syms bits)
      sym half..half+14                  = x (15 sym)
      sym half+15..2*half+14             = blk2 (half_syms sym, 2*half_syms bits)
    For differential demod, sample one extra reference symbol before each block.
    Returns (blk1_soft[2*half_syms], blk2_soft[2*half_syms]).
    """
    blk1_start = x_start_pos - half_syms * sps
    blk1_idx = np.round(blk1_start - sps + np.arange(half_syms + 1) * sps).astype(int)
    blk1_idx = np.clip(blk1_idx, 0, len(iq) - 1)
    blk1_soft = demod_pi4dqpsk_soft_etsi(iq[blk1_idx])

    blk2_start = x_start_pos + RA_X_SYMS * sps
    blk2_idx = np.round(blk2_start - sps + np.arange(half_syms + 1) * sps).astype(int)
    blk2_idx = np.clip(blk2_idx, 0, len(iq) - 1)
    blk2_soft = demod_pi4dqpsk_soft_etsi(iq[blk2_idx])

    return blk1_soft, blk2_soft


def try_channel_decode(blk1_soft, blk2_soft, scramb_init, channel):
    """Try decoding the (blk1+blk2) payload under one channel hypothesis.
    channel: 'schhu' (K=168,a=13,info=92), 'schhd' (K=216,a=101,info=124),
             'schf'  (K=432,a=103,info=268).
    Runs order/polarity/scramble hypotheses; returns best result.
    """
    if channel == 'schhu':
        K, a, info = 168, 13, 92
    elif channel == 'schhd':
        K, a, info = 216, 101, 124
    elif channel == 'schf':
        K, a, info = 432, 103, 268
    else:
        raise ValueError(channel)

    len_half = len(blk1_soft)
    if 2 * len_half < K:
        return (False, None, None, None)
    # Trim to K bits from the concatenation (pad or cut)
    def cat_trim(a_, b_):
        s = np.concatenate([a_, b_])
        if len(s) >= K:
            return s[:K]
        out = np.zeros(K, dtype=np.float64)
        out[:len(s)] = s
        return out

    hypotheses = []
    for order_name, s in (('12', cat_trim(blk1_soft, blk2_soft)),
                          ('21', cat_trim(blk2_soft, blk1_soft))):
        for pol_name, pol in (('+', 1.0), ('-', -1.0)):
            for scr_name, use_scr in (('s', True), ('n', False)):
                soft_desc = pol * (descramble_soft_etsi(s, scramb_init, K) if use_scr else s)
                hypotheses.append((f'{channel}_{order_name}{pol_name}{scr_name}',
                                   soft_desc))

    best = (False, None, None, None)
    for name, soft_t5 in hypotheses:
        try:
            crc_ok, info_bits, _ = decode_channel_soft(soft_t5, K=K, a=a, info_bits_len=info)
        except Exception:
            continue
        hard = (soft_t5 < 0).astype(np.int32)
        if crc_ok:
            return True, info_bits, hard, name
        if best[1] is None:
            best = (crc_ok, info_bits, hard, name)
    return best


def try_schhu_decode(cb1_soft, cb2_soft, scramb_init):
    """Legacy entrypoint — tries SCH/HU first, then SCH/HD, then SCH/F."""
    for ch in ('schhu', 'schhd', 'schf'):
        res = try_channel_decode(cb1_soft, cb2_soft, scramb_init, ch)
        if res[0]:
            return res
    return res


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

        # Try CB layout first (42-sym half-blocks → SCH/HU 168 bit)
        blk1_cb, blk2_cb = sample_half_soft_bits(iq, sps, x_pos, RA_CB_SYMS)
        result = try_channel_decode(blk1_cb, blk2_cb, scramb_init, 'schhu')
        # Fallback: NUB layout (54-sym half-blocks → SCH/HD 216 or SCH/F 432)
        if not result[0]:
            blk1_nub, blk2_nub = sample_half_soft_bits(iq, sps, x_pos, RA_NUB_SYMS)
            r2 = try_channel_decode(blk1_nub, blk2_nub, scramb_init, 'schhd')
            if r2[0]:
                result = r2
            else:
                r3 = try_channel_decode(blk1_nub, blk2_nub, scramb_init, 'schf')
                if r3[0]:
                    result = r3
        crc_ok, info_bits, type5_hard = result[0], result[1], result[2]
        variant = result[3] if len(result) > 3 and result[3] else ''
        type5_patterns.append(type5_hard if type5_hard is not None else np.zeros(168, dtype=np.int8))

        tag = 'OK' if crc_ok else '-'
        pdu_hex = bits_to_hex(info_bits[:48])[:23] if info_bits is not None else ''
        print(f'  {i:3d} {s/sr_dec:8.3f} {x_corr:6.3f}  {tag:>4} {variant:>14}  {pdu_hex}')
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
