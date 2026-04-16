#!/usr/bin/env python3
"""
decode_sb.py — TETRA Continuous Synchronization Burst decoder for RTL-SDR.

Decodes SYSINFO from a TETRA downlink captured with RTL-SDR.  Targets the
**Continuous Downlink SB** (§9.4.4.2.6) emitted by this project's FPGA:

    Tail1(6) + HC(1) + FreqCor(40) + sb1(60) + STS(19) + bb(15) +
    bkn2(108) + HD(1) + Tail2(5)  =  255 symbols = 510 bits

Pipeline:
    π/4-DQPSK demod → STS correlation (19 dibits) → burst alignment →
    descramble (BSCH init=3) → de-interleave (8×15) →
    Viterbi rate 2/3 depuncture → CRC-16 → SYSINFO parse.

Usage:
    # Capture with RTL-SDR (signal at TX_LO + 106 kHz):
    rtl_sdr -d 0 -f 440106000 -s 2048000 -g 40 -n 4096000 /tmp/cap.bin
    python3 scripts/decode_sb.py /tmp/cap.bin --sr 2048000

    # Or let this script capture automatically:
    python3 scripts/decode_sb.py --capture --freq 440106000 --sr 2048000
"""

import argparse
import sys
import numpy as np
from numpy.fft import fft

# =============================================================================
# TETRA Constants (EN 300 392-2)
# =============================================================================

SYMBOL_RATE = 18000
CHANNEL_BW = 25000

# Continuous SDB structure (§9.4.4.2.6) — symbol offsets within the 255-symbol burst
SDB_TAIL1_LEN = 6
SDB_HC_LEN = 1
SDB_FC_LEN = 40      # FreqCor
SDB_SB1_LEN = 60     # sb1 (120 bits)
SDB_STS_LEN = 19     # 19 dibits (§9.4.4.3.4)
SDB_BB_LEN = 15      # bb / AACH (30 bits)
SDB_BKN2_LEN = 108   # bkn2 (216 bits)
SDB_HD_LEN = 1
SDB_TAIL2_LEN = 5
SB_TOTAL = 255

# Symbol-index boundaries inside the burst (0-based, inclusive of start)
SDB_OFF_HC = SDB_TAIL1_LEN                              # 6
SDB_OFF_FC = SDB_OFF_HC + SDB_HC_LEN                    # 7
SDB_OFF_SB1 = SDB_OFF_FC + SDB_FC_LEN                   # 47
SDB_OFF_STS = SDB_OFF_SB1 + SDB_SB1_LEN                 # 107
SDB_OFF_BB = SDB_OFF_STS + SDB_STS_LEN                  # 126
SDB_OFF_BKN2 = SDB_OFF_BB + SDB_BB_LEN                  # 141
SDB_OFF_HD = SDB_OFF_BKN2 + SDB_BKN2_LEN                # 249
SDB_OFF_TAIL2 = SDB_OFF_HD + SDB_HD_LEN                 # 250
assert SDB_OFF_TAIL2 + SDB_TAIL2_LEN == SB_TOTAL

# STS reference (19 dibits) — from rtl/tx/tetra_burst_builder.v lines 121-125.
# MSB of that Verilog literal is the first transmitted dibit.
STS_DIBITS = [
    0b11, 0b00, 0b00, 0b01, 0b10, 0b01, 0b11, 0b00,
    0b11, 0b10, 0b10, 0b01, 0b11, 0b00, 0b00, 0b01,
    0b10, 0b01, 0b11,
]
assert len(STS_DIBITS) == SDB_STS_LEN

# π/4-DQPSK differential phase per dibit (ETSI EN 300 392-2 §5.5.2.3)
DIBIT_TO_DPHASE = {
    0b00: np.pi / 4,
    0b01: 3 * np.pi / 4,
    0b10: -np.pi / 4,
    0b11: -3 * np.pi / 4,
}

# Convolutional encoder (K=5): G1=0x1B, G2=0x19, G3=0x15 — rate 1/3 mother code
G1, G2, G3 = 0x1B, 0x19, 0x15

# CRC-16-CCITT
CRC_POLY = 0x1021
CRC_INIT = 0xFFFF

# BSCH (continuous SB) coding — §9.4.4.2.6:
#     60 type-1 → CRC-16 → 76 type-2 → +4 tail → 80 type-3
#     → RCPC rate 2/3 → 120 type-4 → interleave 8×15 → scramble (init=3) → 120 type-5
SYSINFO_BITS = 60
BSCH_TYPE3_BITS = 80
BSCH_CODED_BITS = 120   # type-4 / type-5

# Scrambler init for BSCH is fixed = 3 (§8.2.5.2)
SCRAMB_INIT = 3


# =============================================================================
# π/4-DQPSK helpers
# =============================================================================

def dibits_to_symbols(dibits, phase0=0.0):
    """Convert a dibit sequence into complex π/4-DQPSK symbols."""
    phase = phase0
    out = np.empty(len(dibits), dtype=np.complex128)
    for i, d in enumerate(dibits):
        phase += DIBIT_TO_DPHASE[int(d)]
        out[i] = np.exp(1j * phase)
    return out


def build_sts_reference():
    """STS reference waveform (19 complex symbols)."""
    return dibits_to_symbols(STS_DIBITS)


def demod_pi4dqpsk(symbols):
    """Differential demodulation → dibit stream (len = len(symbols)-1).
    ETSI EN 300 392-2 §5.5.2.3 inverse mapping:
      +π/4 → 00, +3π/4 → 01, -π/4 → 10, -3π/4 → 11."""
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    out = np.empty(len(dphi), dtype=np.int32)
    for i, p in enumerate(dphi):
        if -np.pi / 2 < p <= 0:
            out[i] = 0b10         # -π/4
        elif 0 < p <= np.pi / 2:
            out[i] = 0b00         # +π/4
        elif np.pi / 2 < p <= np.pi:
            out[i] = 0b01         # +3π/4
        else:
            out[i] = 0b11         # -3π/4
    return out


# =============================================================================
# RRC matched filter
# =============================================================================

def rrc_filter(ntaps, alpha, sps):
    t = np.arange(-ntaps // 2, ntaps // 2 + 1) / sps
    h = np.zeros_like(t, dtype=float)
    for i, ti in enumerate(t):
        if ti == 0:
            h[i] = 1.0 + alpha * (4 / np.pi - 1)
        elif abs(abs(ti) - 1 / (4 * alpha)) < 1e-8:
            h[i] = alpha / np.sqrt(2) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha))
                + (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha))
            )
        else:
            num = np.sin(np.pi * ti * (1 - alpha)) + 4 * alpha * ti * np.cos(np.pi * ti * (1 + alpha))
            den = np.pi * ti * (1 - (4 * alpha * ti) ** 2)
            h[i] = num / den
    h /= np.sqrt(np.sum(h ** 2))
    return h


# =============================================================================
# STS correlation (19 dibits → 18 differential symbols)
# =============================================================================

def find_sync_bursts(iq, sps, min_corr=0.4):
    """Find positions where the 19-dibit STS pattern is present (differential)."""
    sts_ref = build_sts_reference()
    sts_diff = sts_ref[1:] * np.conj(sts_ref[:-1])             # 18 complex values
    sts_norm = sts_diff / (np.abs(sts_diff) + 1e-12)

    n = len(iq)
    sts_len_samples = int(SDB_STS_LEN * sps)
    step = max(1, int(sps / 4))

    best = []
    for offset in range(0, n - sts_len_samples - int(sps), step):
        indices = np.round(np.arange(SDB_STS_LEN) * sps + offset).astype(int)
        if indices[-1] >= n:
            break
        syms = iq[indices]
        diff = syms[1:] * np.conj(syms[:-1])
        diff_norm = diff / (np.abs(diff) + 1e-12)
        corr = np.abs(np.sum(diff_norm * np.conj(sts_norm))) / len(sts_norm)
        best.append((offset, corr))

    best.sort(key=lambda x: -x[1])

    # Deduplicate peaks within one burst length
    min_spacing = int(SB_TOTAL * sps * 0.8)
    peaks = []
    for offset, corr in best:
        if corr < min_corr:
            break
        if all(abs(offset - po) >= min_spacing for po, _ in peaks):
            peaks.append((offset, corr))
    return peaks


def estimate_freq_from_sts(iq_burst, sps, sts_offset_in_burst):
    """Residual freq/phase from STS differential phase error."""
    sts_ref = build_sts_reference()
    sts_diff_ref = sts_ref[1:] * np.conj(sts_ref[:-1])
    indices = np.round(np.arange(SDB_STS_LEN) * sps + sts_offset_in_burst).astype(int)
    indices = np.clip(indices, 0, len(iq_burst) - 1)
    syms = iq_burst[indices]
    diff = syms[1:] * np.conj(syms[:-1])
    phase_err = np.angle(diff * np.conj(sts_diff_ref))
    x = np.arange(len(phase_err))
    slope, mean_off = np.polyfit(x, phase_err, 1)
    # np.polyfit returns [slope, intercept]; use intercept + slope*mean(x) as mean_off
    mean_off = float(np.mean(phase_err))
    return slope, mean_off


# =============================================================================
# Scrambler (Fibonacci LFSR, §8.2.5) — BSCH uses fixed init=3
# =============================================================================

def scrambler_seq(init, length):
    lfsr = init & 0xFFFFFFFF
    if lfsr == 0:
        lfsr = 0xFFFFFFFF
    seq = np.zeros(length, dtype=np.int32)
    for i in range(length):
        b = (
            ((lfsr >> 0) ^ (lfsr >> 6) ^ (lfsr >> 9) ^ (lfsr >> 10) ^
             (lfsr >> 16) ^ (lfsr >> 20) ^ (lfsr >> 21) ^ (lfsr >> 22) ^
             (lfsr >> 24) ^ (lfsr >> 25) ^ (lfsr >> 27) ^ (lfsr >> 28) ^
             (lfsr >> 30) ^ (lfsr >> 31)) & 1
        )
        seq[i] = b
        lfsr = (lfsr >> 1) | (b << 31)
    return seq


def descramble_bsch(bits):
    return (bits ^ scrambler_seq(SCRAMB_INIT, len(bits))) & 1


# =============================================================================
# Block de-interleaver (§8.2.4) — continuous BSCH: 8 rows × 15 cols → 120 bits
# =============================================================================

def deinterleave(bits, length):
    if length == 120:
        R, C = 8, 15     # continuous BSCH
    elif length == 240:
        R, C = 16, 15    # non-continuous BSCH (kept for reference)
    elif length == 216:
        R, C = 24, 9
    elif length == 162:
        R, C = 18, 9
    elif length == 28:
        R, C = 4, 7
    else:
        return bits.copy()
    out = np.zeros(length, dtype=np.int32)
    for k in range(length):
        row = k % R
        col = k // R
        out[k] = bits[row * C + col]
    return out


# =============================================================================
# Viterbi — rate 2/3 depuncture to rate 1/3, then K=5 decode
# =============================================================================
#
# TETRA RCPC rate 2/3 (used for continuous BSCH): from mother rate-1/3 output
# (g1, g2, g3) per input bit, the encoder keeps the following pattern per
# period of 2 input bits:
#
#   input bit index i even → transmit g1, g2
#   input bit index i odd  → transmit g1
#
# Exactly three bits per two input bits = rate 2/3.
# This matches tetra_hal.c::tetra_rcpc_encode() case 1.

def depuncture_r23(bits23):
    """120 rate-2/3 bits → 240 rate-1/3 bits with erasures (2 = erased)."""
    n_in = len(bits23)
    # Every 2 input bits generate 3 rx bits (g1 g2 | g1)
    assert n_in % 3 == 0, f"rate-2/3 input must be multiple of 3, got {n_in}"
    n_info_pairs = n_in // 3
    n_info = n_info_pairs * 2
    out = np.full(n_info * 3, 2, dtype=np.int32)  # 2 = erasure
    rx = 0
    for p in range(n_info_pairs):
        i0 = p * 2        # even input
        i1 = i0 + 1       # odd input
        # even: g1, g2
        out[i0 * 3 + 0] = bits23[rx]; rx += 1
        out[i0 * 3 + 1] = bits23[rx]; rx += 1
        # even: g3 erased
        # odd: g1
        out[i1 * 3 + 0] = bits23[rx]; rx += 1
        # odd: g2, g3 erased
    assert rx == n_in
    return out


def parity(x, mask):
    v = x & mask
    v ^= v >> 4
    v ^= v >> 2
    v ^= v >> 1
    return v & 1


def viterbi_decode_r13_with_erasures(coded_bits):
    """
    Hard-decision Viterbi, K=5, mother rate 1/3.  Erasure value = 2 → zero-cost branch.

    Shift-register convention matches tetra_hal.c encoder:
      sr = (sr << 1 | input) & 0x1F
      new_state = sr & 0xF
    """
    n_states = 16
    n_coded = len(coded_bits)
    n_input = n_coded // 3
    INF = 10 ** 9

    pm = np.full(n_states, INF, dtype=np.int64)
    pm[0] = 0
    tb_state = np.zeros((n_input, n_states), dtype=np.int32)
    tb_input = np.zeros((n_input, n_states), dtype=np.int32)

    for i in range(n_input):
        g1_rx = int(coded_bits[3 * i])
        g2_rx = int(coded_bits[3 * i + 1])
        g3_rx = int(coded_bits[3 * i + 2])
        new_pm = np.full(n_states, INF, dtype=np.int64)

        for old_state in range(n_states):
            if pm[old_state] >= INF:
                continue
            for inp in range(2):
                sr = ((old_state << 1) | inp) & 0x1F
                new_state = sr & 0xF
                e1 = parity(sr, G1)
                e2 = parity(sr, G2)
                e3 = parity(sr, G3)
                d1 = 0 if g1_rx == 2 else (e1 ^ g1_rx)
                d2 = 0 if g2_rx == 2 else (e2 ^ g2_rx)
                d3 = 0 if g3_rx == 2 else (e3 ^ g3_rx)
                metric = pm[old_state] + d1 + d2 + d3
                if metric < new_pm[new_state]:
                    new_pm[new_state] = metric
                    tb_state[i, new_state] = old_state
                    tb_input[i, new_state] = inp
        pm = new_pm

    # Tail bits force encoder to state 0
    decoded = np.zeros(n_input, dtype=np.int32)
    state = 0
    for i in range(n_input - 1, -1, -1):
        decoded[i] = tb_input[i, state]
        state = tb_state[i, state]
    return decoded


def viterbi_decode_r23(coded_bits):
    """120 rate-2/3 bits → 80 decoded bits."""
    depunct = depuncture_r23(coded_bits)
    return viterbi_decode_r13_with_erasures(depunct)


# =============================================================================
# CRC-16-CCITT
# =============================================================================

def crc16_check(bits):
    crc = CRC_INIT
    for b in bits:
        feedback = (int(b) & 1) ^ ((crc >> 15) & 1)
        crc = (crc << 1) & 0xFFFF
        if feedback:
            crc ^= CRC_POLY
    return crc == 0


# =============================================================================
# SYSINFO parser (§15.3.8)
# =============================================================================

def parse_sysinfo(bits):
    if len(bits) < SYSINFO_BITS:
        return None

    def extract(b, start, nbits):
        val = 0
        for i in range(nbits):
            val = (val << 1) | (int(b[start + i]) & 1)
        return val

    return {
        'MCC': extract(bits, 0, 10),
        'MNC': extract(bits, 10, 14),
        'LA': extract(bits, 24, 14),
        'CC': extract(bits, 38, 6),
        'TS_assigned': extract(bits, 44, 2),
        'U_plane': extract(bits, 46, 1),
        'Frame18_countdown': extract(bits, 47, 2),
        'Access_code': extract(bits, 49, 4),
        'DL_usage': extract(bits, 53, 6),
        'Reserved': extract(bits, 59, 1),
    }


# =============================================================================
# IQ loading and coarse frequency estimation
# =============================================================================

def load_rtlsdr_iq(filename):
    raw = np.fromfile(filename, dtype=np.uint8)
    iq = (raw[0::2].astype(np.float64) - 127.5) / 127.5 + \
        1j * (raw[1::2].astype(np.float64) - 127.5) / 127.5
    return iq


def estimate_freq_offset(iq, sample_rate):
    nfft = 8192
    spec = np.abs(fft(iq[:nfft] * np.hanning(nfft))) ** 2
    freqs = np.fft.fftfreq(nfft, 1 / sample_rate)
    # Suppress DC
    spec[0] = spec[1] = spec[-1] = 0
    peak = int(np.argmax(spec))
    f_off = freqs[peak]
    if 1 < peak < nfft - 1:
        a = np.log(spec[peak - 1] + 1e-12)
        b = np.log(spec[peak] + 1e-12)
        c = np.log(spec[peak + 1] + 1e-12)
        denom = (a - 2 * b + c)
        if abs(denom) > 1e-12:
            f_off = freqs[peak] + 0.5 * (a - c) / denom * (freqs[1] - freqs[0])
    return float(f_off)


# =============================================================================
# Main decoder
# =============================================================================

def decode_tetra_sb(filename, sample_rate=2048000, freq_offset=0.0, verbose=True):
    print("=== TETRA Continuous-SB Decoder ===")
    print(f"File: {filename}")
    print(f"Sample rate: {sample_rate}")

    iq = load_rtlsdr_iq(filename)
    print(f"Loaded {len(iq)} samples ({len(iq)/sample_rate:.3f}s)")

    # Coarse frequency correction (optional)
    if freq_offset == 0:
        freq_offset = estimate_freq_offset(iq, sample_rate)
        print(f"Estimated freq offset: {freq_offset:+.1f} Hz")

    if abs(freq_offset) > 10:
        t = np.arange(len(iq)) / sample_rate
        iq = iq * np.exp(-1j * 2 * np.pi * freq_offset * t)
        print(f"Applied freq correction: {freq_offset:+.1f} Hz")

    # Decimate to ~sps_target samples/symbol
    sps_target = 8
    target_rate = SYMBOL_RATE * sps_target
    decim = max(1, int(sample_rate / target_rate))
    actual_rate = sample_rate / decim
    sps = actual_rate / SYMBOL_RATE

    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sample_rate
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2))
        h *= np.hanning(ntaps)
        h /= np.sum(h)
        iq_filt = np.convolve(iq, h, mode='same')
        iq_dec = iq_filt[::decim]
    else:
        iq_dec = iq
    print(f"Decimated: {decim}× → {actual_rate:.0f} Hz, {sps:.2f} samples/symbol")

    # RRC matched filter
    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = rrc_filter(rrc_ntaps, 0.35, sps)
    iq_rrc = np.convolve(iq_dec, rrc, mode='same')
    print(f"RRC matched filter: {rrc_ntaps} taps, α=0.35")

    # Locate STS occurrences
    print("\nSearching for Continuous SB via 19-dibit STS correlation...")
    peaks = find_sync_bursts(iq_rrc, sps, min_corr=0.35)
    if not peaks:
        print("ERROR: No STS matches above threshold.")
        return False
    print(f"Found {len(peaks)} candidate SB(s):")
    for i, (off, corr) in enumerate(peaks[:5]):
        print(f"  [{i}] sample {off}, STS corr {corr:.3f}")

    decoded_any = False

    for sb_idx, (sts_offset, corr) in enumerate(peaks[:5]):
        print(f"\n--- Decoding SB #{sb_idx} (STS corr = {corr:.3f}) ---")

        # Burst start is SDB_OFF_STS symbols before the STS position
        burst_start = sts_offset - int(SDB_OFF_STS * sps)
        if burst_start < 0:
            print("  Burst start before capture, skipping")
            continue
        burst_end = burst_start + int(SB_TOTAL * sps)
        if burst_end > len(iq_rrc):
            print("  Burst extends beyond capture, skipping")
            continue

        # Refine timing with sub-sample sweep
        best_timing = 0.0
        best_corr = 0.0
        sts_ref = build_sts_reference()
        sts_diff = sts_ref[1:] * np.conj(sts_ref[:-1])
        sts_norm = sts_diff / (np.abs(sts_diff) + 1e-12)
        for dt in np.linspace(-0.5, 0.5, 21):
            indices = np.round(np.arange(SDB_STS_LEN) * sps + sts_offset + dt).astype(int)
            indices = np.clip(indices, 0, len(iq_rrc) - 1)
            syms = iq_rrc[indices]
            diff = syms[1:] * np.conj(syms[:-1])
            diff_norm = diff / (np.abs(diff) + 1e-12)
            c = np.abs(np.sum(diff_norm * np.conj(sts_norm))) / len(sts_norm)
            if c > best_corr:
                best_corr = c
                best_timing = dt

        # Extract all 255 symbols with fine timing
        sym_indices = np.round(
            np.arange(SB_TOTAL) * sps + burst_start + best_timing
        ).astype(int)
        sym_indices = np.clip(sym_indices, 0, len(iq_rrc) - 1)
        burst_syms = iq_rrc[sym_indices]

        # Residual freq/phase correction from STS
        slope, mean_ph = estimate_freq_from_sts(
            iq_rrc[int(burst_start):int(burst_end)], sps,
            int(SDB_OFF_STS * sps) + best_timing
        )
        freq_err_hz = mean_ph * SYMBOL_RATE / (2 * np.pi)
        print(f"  Fine timing: {best_timing:+.2f} sample, STS refined corr: {best_corr:.3f}")
        print(f"  STS freq err: {freq_err_hz:+.1f} Hz")
        n = np.arange(SB_TOTAL)
        phase_correction = mean_ph * n + 0.5 * slope * n * n
        burst_syms = burst_syms * np.exp(-1j * phase_correction)

        # Differential demod → 254 dibits.
        # Convention: dibits[k] = dibit transmitted for sym[k+1] (derived from
        # the phase delta sym[k] → sym[k+1]).  First dibit of sb1 is the one
        # applied at sym[SDB_OFF_SB1], i.e. dibits[SDB_OFF_SB1 - 1].
        dibits = demod_pi4dqpsk(burst_syms)
        sb1_start = SDB_OFF_SB1 - 1
        sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]
        if len(sb1_dibits) < SDB_SB1_LEN:
            print("  Not enough dibits for sb1, skipping")
            continue

        # dibit → 2 bits (MSB first — matches tetra_hal.c bits_to_words packing)
        sb1_bits = np.zeros(SDB_SB1_LEN * 2, dtype=np.int32)
        for j, d in enumerate(sb1_dibits):
            sb1_bits[2 * j] = (int(d) >> 1) & 1
            sb1_bits[2 * j + 1] = int(d) & 1
        print(f"  sb1: {len(sb1_bits)} type-5 bits extracted")

        # Descramble (BSCH fixed init=3)
        type4i = descramble_bsch(sb1_bits)
        # De-interleave 8×15
        type4 = deinterleave(type4i, BSCH_CODED_BITS)
        print(f"  Descrambled (init=3), de-interleaved (8×15)")

        # Viterbi rate 2/3
        type3 = viterbi_decode_r23(type4)
        print(f"  Viterbi rate-2/3 decoded: {len(type3)} bits")
        assert len(type3) == BSCH_TYPE3_BITS

        # Strip 4 tail bits → 76 type-2 bits, CRC-16 check
        type2 = type3[:SYSINFO_BITS + 16]
        crc_ok = crc16_check(type2)
        type1 = type2[:SYSINFO_BITS]

        if crc_ok:
            info = parse_sysinfo(type1)
            print(f"  CRC-16: PASS ✓")
            print("\n  ╔═══════════════════════════════════════╗")
            print("  ║  SYSINFO Decoded Successfully!        ║")
            print("  ╠═══════════════════════════════════════╣")
            print(f"  ║  MCC:          {info['MCC']:>5d}                ║")
            print(f"  ║  MNC:          {info['MNC']:>5d}                ║")
            print(f"  ║  Location Area:{info['LA']:>5d}                ║")
            print(f"  ║  Colour Code:  {info['CC']:>5d}                ║")
            print(f"  ║  TS assigned:  {info['TS_assigned']:>5d}                ║")
            print(f"  ║  DL usage:     0x{info['DL_usage']:02X}                 ║")
            print("  ╚═══════════════════════════════════════╝")
            decoded_any = True
        else:
            info = parse_sysinfo(type1)
            print(f"  CRC-16: FAIL ✗  (raw) MCC={info['MCC']} MNC={info['MNC']} "
                  f"LA={info['LA']} CC={info['CC']}")

    if not decoded_any:
        print("\nNo SB decoded successfully.")
        print("Possible issues:")
        print("  - Frequency offset — try --offset to override")
        print("  - Low SNR / wrong gain")
        print("  - Timing drift across burst")
        return False
    return True


# =============================================================================
# Entry point
# =============================================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='TETRA Continuous-SB Decoder')
    parser.add_argument('input', nargs='?', default='/tmp/tetra_tx_capture.bin',
                        help='RTL-SDR IQ capture file (uint8)')
    parser.add_argument('--sr', type=int, default=2048000,
                        help='Sample rate (default 2048000)')
    parser.add_argument('--offset', type=float, default=0,
                        help='Frequency offset in Hz to correct (0 = auto)')
    parser.add_argument('--capture', action='store_true',
                        help='Capture with RTL-SDR first')
    parser.add_argument('--freq', type=int, default=440106000,
                        help='Capture frequency in Hz (default 440106000)')
    parser.add_argument('--gain', type=float, default=40,
                        help='RTL-SDR gain (default 40)')
    parser.add_argument('--duration', type=float, default=2.0,
                        help='Capture duration in seconds (default 2)')
    parser.add_argument('--device', type=int, default=0,
                        help='RTL-SDR device index (default 0)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    args = parser.parse_args()

    if args.capture:
        import subprocess
        n_samples = int(args.sr * args.duration)
        capture_file = '/tmp/tetra_tx_capture.bin'
        print(f"Capturing {args.duration}s at {args.freq/1e6:.3f} MHz (dev {args.device})...")
        subprocess.run([
            'rtl_sdr', '-d', str(args.device),
            '-f', str(args.freq),
            '-s', str(args.sr),
            '-g', str(args.gain),
            '-n', str(n_samples),
            capture_file,
        ], check=True)
        args.input = capture_file

    ok = decode_tetra_sb(args.input, sample_rate=args.sr,
                         freq_offset=args.offset, verbose=args.verbose)
    sys.exit(0 if ok else 1)
