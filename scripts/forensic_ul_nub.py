#!/usr/bin/env python3
"""
forensic_ul_nub.py — UL TCH/S NUB-Burst-Forensik (Phase B2)

Ziel: bit-genaue Map der TETRA UL Normal-Uplink-Burst Struktur aus
einer Gold-UL-WAV mit aktivem Voice-TX (TCH/S).

Vorgehen:
 1. WAV laden (250 kHz I/Q stereo)
 2. CFO mix-down auf 0
 3. Decimate auf ~4 sps (= 72 kHz)
 4. RRC matched-filter
 5. Envelope-Burst-Detect (kein Sync-Korrelator nötig, da Voice-TX
    klar separate Bursts erzeugt)
 6. Pro Burst: π/4-DQPSK differential demod → Dibit-Stream
 7. Korrelation des Dibit-Streams mit NTS1/NTS2-Pattern → Sync-Position
 8. Ausgabe: Burst-Layout-Map (TAIL1, BKN1, BB1, NTS, BB2, BKN2, TAIL2)

NTS-Pattern aus rtl/tx/tetra_burst_builder.v (§9.4.4.3.2/3 ETSI).
"""
import argparse
import numpy as np
import wave
import sys

SR_IN = 250000      # WAV sample rate
SYM_RATE = 18000    # TETRA symbol rate
SPS_OUT = 4         # target samples-per-symbol after decimate

# NTS dibits (MSB = first transmitted, from tetra_burst_builder.v)
# Each dibit = 2 bits (D1 D0); pi/4-DQPSK dibit mapping per ETSI.
NTS1_DIBITS = [
    (1,1), (0,1), (0,0), (0,0), (1,1), (1,0),
    (1,0), (0,1), (1,1), (0,1), (0,0),
]
NTS2_DIBITS = [
    (0,1), (1,1), (1,0), (1,0), (0,1), (0,0),
    (0,0), (1,1), (0,1), (1,1), (1,0),
]


def load_iq(filename):
    w = wave.open(filename, 'rb')
    sr = w.getframerate()
    nf = w.getnframes()
    raw = w.readframes(nf)
    data = np.frombuffer(raw, dtype='<i2').astype(np.float32)
    iq = data[0::2] + 1j * data[1::2]
    return iq, sr


def mixdown(iq, sr, cfo):
    t = np.arange(len(iq), dtype=np.float64) / sr
    return iq * np.exp(-1j * 2 * np.pi * cfo * t).astype(np.complex64)


def detect_bursts(iq, sr, window_ms=10.0, thresh_ratio=0.30):
    """Envelope-based burst detect. Returns (start_sample, end_sample) tuples."""
    win = int(window_ms * 1e-3 * sr)
    n_win = len(iq) // win
    pwr = np.array([np.mean(np.abs(iq[i * win:(i + 1) * win]) ** 2)
                    for i in range(n_win)])
    thr = thresh_ratio * np.max(pwr)
    busy = pwr > thr
    edges = np.diff(busy.astype(np.int8), prepend=0, append=0)
    rises = np.where(edges == 1)[0]
    falls = np.where(edges == -1)[0]
    bursts = [(r * win, f * win) for r, f in zip(rises, falls)]
    return bursts


def design_rrc(num_taps, sps, alpha=0.35):
    """Root-Raised-Cosine matched filter, normalized."""
    t = np.arange(-num_taps // 2, num_taps // 2 + 1) / sps
    h = np.zeros_like(t, dtype=np.float64)
    for i, ti in enumerate(t):
        if abs(ti) < 1e-9:
            h[i] = 1.0 - alpha + 4 * alpha / np.pi
        elif abs(abs(4 * alpha * ti) - 1.0) < 1e-9:
            h[i] = (alpha / np.sqrt(2)) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha)) +
                (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha))
            )
        else:
            num = (np.sin(np.pi * ti * (1 - alpha)) +
                   4 * alpha * ti * np.cos(np.pi * ti * (1 + alpha)))
            den = np.pi * ti * (1 - (4 * alpha * ti) ** 2)
            h[i] = num / den
    return h / np.sqrt(np.sum(h ** 2))


def differential_pi4_dqpsk_demod(iq_at_sym_rate):
    """Differential π/4-DQPSK: dibit from sign(Re(z)) and sign(Im(z))
    where z = current * conj(prev).
    Returns list of (d1, d0) dibits.
    """
    dibits = []
    prev = iq_at_sym_rate[0]
    for s in iq_at_sym_rate[1:]:
        z = s * np.conj(prev)
        d1 = 1 if z.imag > 0 else 0    # bit[1] = sign(Im(z))
        d0 = 1 if z.real > 0 else 0    # bit[0] = sign(Re(z))
        dibits.append((d1, d0))
        prev = s
    return dibits


def correlate_pattern(dibits, pattern):
    """Slide pattern (list of (d1,d0)) over dibits, return match scores."""
    scores = []
    for i in range(len(dibits) - len(pattern) + 1):
        m = sum(1 for j in range(len(pattern))
                if dibits[i + j] == pattern[j])
        scores.append(m)
    return scores


def fmt_dibits(dibits, width=11):
    rows = []
    for i in range(0, len(dibits), width):
        rows.append(' '.join(f'{d[0]}{d[1]}' for d in dibits[i:i + width]))
    return '\n  '.join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav')
    ap.add_argument('--cfo', type=float, required=True,
                    help='CFO in Hz (negative for signal below center)')
    ap.add_argument('--burst-skip', type=int, default=10,
                    help='which burst index to analyze (skip leading)')
    ap.add_argument('--decim', type=int, default=None,
                    help='decimation factor (default auto for 4 sps)')
    ap.add_argument('--show-bursts', type=int, default=20,
                    help='print first N detected bursts')
    args = ap.parse_args()

    print(f'Loading {args.wav} ...')
    iq, sr = load_iq(args.wav)
    print(f'  sr={sr} len={len(iq)} dur={len(iq)/sr:.2f}s')
    assert sr == SR_IN, f'expected {SR_IN}, got {sr}'

    # Mix down to baseband
    print(f'Mixing CFO {args.cfo:+.0f} Hz to 0 ...')
    iq = mixdown(iq, sr, args.cfo)

    # Decimate to ~4 sps
    decim = args.decim if args.decim else max(1, int(sr / (SPS_OUT * SYM_RATE)))
    iq_dec = iq[::decim]
    sr_dec = sr / decim
    sps = sr_dec / SYM_RATE
    print(f'  decim={decim} sr_dec={sr_dec:.0f} sps={sps:.3f}')

    # RRC matched filter (24 taps at this rate)
    rrc = design_rrc(num_taps=24, sps=sps, alpha=0.35).astype(np.float32)
    iq_filt = np.convolve(iq_dec, rrc, mode='same')

    # Detect bursts
    bursts = detect_bursts(iq_filt, sr_dec)
    print(f'\nDetected {len(bursts)} bursts. First {args.show_bursts}:')
    for i, (s, e) in enumerate(bursts[:args.show_bursts]):
        print(f'  #{i:3d}  t={s/sr_dec:.3f}..{e/sr_dec:.3f}s '
              f'dur={(e-s)/sr_dec*1000:.1f}ms samples={e-s}')

    if args.burst_skip >= len(bursts):
        print(f'ERROR: burst-skip={args.burst_skip} >= {len(bursts)}')
        sys.exit(1)

    # Analyze the selected burst
    s, e = bursts[args.burst_skip]
    # Pad each side to capture leading/trailing margin
    margin = int(0.005 * sr_dec)  # 5 ms each side
    s_ext = max(0, s - margin)
    e_ext = min(len(iq_filt), e + margin)
    chunk = iq_filt[s_ext:e_ext]
    print(f'\n=== Analyzing burst #{args.burst_skip} '
          f'(t={s/sr_dec:.3f}s, padded {(e_ext-s_ext)/sr_dec*1000:.1f}ms) ===')
    print(f'  chunk len={len(chunk)} expected ≈ {0.014*sr_dec:.0f} for 14ms NUB '
          f'+ {2*margin} margin')

    # Symbol-rate sampling — try all 4 phases, pick highest avg |z|
    # (proxy for best timing)
    best_phase = 0
    best_score = -1
    sps_int = int(round(sps))
    for ph in range(sps_int):
        sym = chunk[ph::sps_int]
        # Differential energy
        if len(sym) < 50:
            continue
        z = sym[1:] * np.conj(sym[:-1])
        score = np.sum(np.abs(z)) / len(z)
        if score > best_score:
            best_score = score
            best_phase = ph
    sym_seq = chunk[best_phase::sps_int]
    print(f'  best symbol phase: {best_phase}/{sps_int}, '
          f'avg |z|={best_score:.0f}, n_sym={len(sym_seq)}')

    # Differential π/4-DQPSK demod
    dibits = differential_pi4_dqpsk_demod(sym_seq)
    print(f'  dibits decoded: {len(dibits)}')

    # Correlate with NTS1 + NTS2
    scores_nts1 = correlate_pattern(dibits, NTS1_DIBITS)
    scores_nts2 = correlate_pattern(dibits, NTS2_DIBITS)
    best_nts1 = int(np.argmax(scores_nts1))
    best_nts2 = int(np.argmax(scores_nts2))
    print(f'\nNTS correlation (max score = 11):')
    print(f'  NTS1 (SCH/F NDB1) best @ symbol {best_nts1:3d}, '
          f'score = {scores_nts1[best_nts1]}/11')
    print(f'  NTS2 (SCH/HD NDB2) best @ symbol {best_nts2:3d}, '
          f'score = {scores_nts2[best_nts2]}/11')

    # Print top-5 positions for each
    print(f'\nTop-5 NTS1 positions:')
    top5_nts1 = np.argsort(scores_nts1)[-5:][::-1]
    for pos in top5_nts1:
        print(f'  sym {pos:3d}  score {scores_nts1[pos]}/11')
    print(f'\nTop-5 NTS2 positions:')
    top5_nts2 = np.argsort(scores_nts2)[-5:][::-1]
    for pos in top5_nts2:
        print(f'  sym {pos:3d}  score {scores_nts2[pos]}/11')

    # Dump dibit stream for visual inspection
    print(f'\n=== Full dibit stream (burst {args.burst_skip}) ===')
    print(f'  ' + fmt_dibits(dibits, width=11))

    # If NTS match strong enough, map burst structure
    nts_pos, nts_type, nts_score = (None, None, 0)
    if scores_nts1[best_nts1] >= scores_nts2[best_nts2]:
        nts_pos, nts_type, nts_score = best_nts1, 'NTS1', scores_nts1[best_nts1]
    else:
        nts_pos, nts_type, nts_score = best_nts2, 'NTS2', scores_nts2[best_nts2]

    if nts_score >= 8:
        print(f'\n=== Burst Layout Map (anchor: {nts_type} @ symbol {nts_pos}) ===')
        # NUB: TAIL1(6) + BKN1(108) + BB1(7) + NTS(11) + BB2(8) + BKN2(108) + TAIL2(5)
        # NTS starts at symbol 6+108+7 = 121
        burst_start_offset = nts_pos - 121
        print(f'  Implied burst start: symbol {burst_start_offset} (margin / pre-symbols)')
        print(f'  TAIL1:  sym {burst_start_offset+0:3d} .. {burst_start_offset+5:3d}  (6 sym, 12 bits)')
        print(f'  BKN1:   sym {burst_start_offset+6:3d} .. {burst_start_offset+113:3d}  (108 sym, 216 bits)')
        print(f'  BB1:    sym {burst_start_offset+114:3d} .. {burst_start_offset+120:3d}  (7 sym, 14 bits)')
        print(f'  {nts_type}:   sym {burst_start_offset+121:3d} .. {burst_start_offset+131:3d}  (11 sym, 22 bits)')
        print(f'  BB2:    sym {burst_start_offset+132:3d} .. {burst_start_offset+139:3d}  (8 sym, 16 bits)')
        print(f'  BKN2:   sym {burst_start_offset+140:3d} .. {burst_start_offset+247:3d}  (108 sym, 216 bits)')
        print(f'  TAIL2:  sym {burst_start_offset+248:3d} .. {burst_start_offset+252:3d}  (5 sym, 10 bits)')
        print(f'  Total:  {253} sym from burst start')
    else:
        print(f'\nWARN: NTS correlation too weak ({nts_score}/11) — burst layout '
              f'mapping not reliable.  Likely causes:')
        print(f'  - Symbol-phase locked to wrong offset')
        print(f'  - CFO incomplete (residual)')
        print(f'  - Burst is RA / signaling, not voice TCH/S')


if __name__ == '__main__':
    main()
