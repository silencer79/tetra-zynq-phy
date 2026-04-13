#!/usr/bin/env python3
"""
decode_sb.py — TETRA Synchronization Burst decoder for RTL-SDR captures.

Decodes SYSINFO from a TETRA downlink captured with RTL-SDR.
Implements: pi/4-DQPSK demod → STS correlation → burst extraction →
descramble → de-interleave → Viterbi decode → CRC-16 check → SYSINFO parse.

Usage:
    # Capture with RTL-SDR (signal at 439.100 MHz):
    rtl_sdr -d 1 -f 439100000 -s 2400000 -g 40 -n 4800000 /tmp/capture.bin
    python3 scripts/decode_sb.py /tmp/capture.bin --sr 2400000

    # Or let this script capture automatically:
    python3 scripts/decode_sb.py --capture --freq 439100000
"""

import argparse
import sys
import struct
import numpy as np
from numpy.fft import fft, fftshift

# =============================================================================
# TETRA Constants (EN 300 392-2)
# =============================================================================

SYMBOL_RATE = 18000  # 18 ksymbol/s
CHANNEL_BW = 25000   # 25 kHz

# SB structure: FC(2) + bkn1(120) + STS(38) + bb(14) + bkn2(81) = 255 symbols
SB_FC_LEN = 2
SB_BKN1_LEN = 120
SB_STS_LEN = 38
SB_BB_LEN = 14
SB_BKN2_LEN = 81
SB_TOTAL = 255

# Synchronization Training Sequence (Table 9.14) — 38 dibits
# From burst_builder.v STS_REF, MSB-first: [75:74]=sym0 ... [1:0]=sym37
STS_DIBITS = [
    0b01, 0b11, 0b10, 0b10, 0b00, 0b11, 0b01, 0b00,
    0b10, 0b01, 0b10, 0b11, 0b01, 0b00, 0b10, 0b11,
    0b01, 0b00, 0b10, 0b01, 0b10, 0b11, 0b00, 0b10,
    0b01, 0b11, 0b01, 0b00, 0b00, 0b11, 0b10, 0b10,
    0b01, 0b11, 0b01, 0b00, 0b10, 0b11,
]

# pi/4-DQPSK phase increments for each dibit (EN 300 392-2, Table 9.1)
# dibit → differential phase increment
DIBIT_TO_DPHASE = {
    0b00: np.pi / 4,
    0b01: 3 * np.pi / 4,
    0b10: -3 * np.pi / 4,
    0b11: -np.pi / 4,
}

# RCPC encoder polynomials (K=5, rate 1/3)
# G1=0x1B (11011), G2=0x19 (11001), G3=0x15 (10101)
G1, G2, G3 = 0x1B, 0x19, 0x15

# CRC-16-CCITT polynomial
CRC_POLY = 0x1021
CRC_INIT = 0xFFFF

# BSCH channel coding: 60 type-1 → 76 type-2 → 80 type-3 → 240 type-4/5
SYSINFO_BITS = 60
BSCH_CODED_BITS = 240

# Scrambler init for BSCH = 3 (fixed, §8.2.5.2)
SCRAMB_INIT = 3


# =============================================================================
# pi/4-DQPSK Reference signal from STS dibits
# =============================================================================

def dibits_to_symbols(dibits):
    """Convert dibit sequence to complex pi/4-DQPSK symbols."""
    phase = 0.0
    symbols = []
    for d in dibits:
        phase += DIBIT_TO_DPHASE[d]
        symbols.append(np.exp(1j * phase))
    return np.array(symbols)


def build_sts_reference():
    """Build STS reference waveform for correlation."""
    return dibits_to_symbols(STS_DIBITS)


# =============================================================================
# RRC filter
# =============================================================================

def rrc_filter(ntaps, alpha, sps):
    """Root Raised Cosine filter."""
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
# pi/4-DQPSK Demodulator
# =============================================================================

def demod_pi4dqpsk(symbols):
    """Differential demodulation: compute phase difference between consecutive symbols."""
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    dibits = np.zeros(len(dphi), dtype=int)

    # Decision regions (EN 300 392-2 Table 9.1)
    for i, p in enumerate(dphi):
        if -np.pi / 2 < p <= 0:
            dibits[i] = 0b11   # -pi/4
        elif 0 < p <= np.pi / 2:
            dibits[i] = 0b00   # +pi/4
        elif np.pi / 2 < p <= np.pi:
            dibits[i] = 0b01   # +3pi/4
        else:  # -pi < p <= -pi/2
            dibits[i] = 0b10   # -3pi/4

    return dibits


# =============================================================================
# STS Correlator — find Sync Bursts
# =============================================================================

def find_sync_bursts(iq, sps, min_corr=0.5):
    """Find STS positions via differential correlation."""
    # Generate STS differential reference (phase differences)
    sts_ref = build_sts_reference()
    sts_diff = sts_ref[1:] * np.conj(sts_ref[:-1])  # 37 differential symbols

    # Compute differential of input at symbol-spaced positions
    # We slide through the IQ at every sample
    n = len(iq)
    sts_len_samples = int(SB_STS_LEN * sps)

    # Downsample-correlate approach: for each candidate offset, extract
    # symbol-spaced samples, compute differential, correlate with STS_diff
    best_corrs = []
    step = max(1, int(sps / 4))  # search at quarter-symbol resolution

    for offset in range(0, n - sts_len_samples - int(sps), step):
        # Extract symbol-spaced samples
        indices = np.round(np.arange(SB_STS_LEN) * sps + offset).astype(int)
        if indices[-1] >= n:
            break
        syms = iq[indices]
        # Differential
        diff = syms[1:] * np.conj(syms[:-1])
        # Normalize
        diff_norm = diff / (np.abs(diff) + 1e-12)
        sts_norm = sts_diff / (np.abs(sts_diff) + 1e-12)
        # Correlation
        corr = np.abs(np.sum(diff_norm * np.conj(sts_norm))) / len(sts_diff)
        best_corrs.append((offset, corr))

    if not best_corrs:
        return []

    best_corrs.sort(key=lambda x: -x[1])

    # Extract peaks above threshold, with minimum spacing
    min_spacing = int(SB_TOTAL * sps * 0.8)
    peaks = []
    for offset, corr in best_corrs:
        if corr < min_corr:
            break
        too_close = False
        for po, _ in peaks:
            if abs(offset - po) < min_spacing:
                too_close = True
                break
        if not too_close:
            peaks.append((offset, corr))

    return peaks


# =============================================================================
# Scrambler (Fibonacci LFSR, EN 300 392-2 §8.2.5)
# =============================================================================

def scrambler_seq(init, length):
    """Generate scrambler sequence (Fibonacci LFSR)."""
    lfsr = init & 0xFFFFFFFF
    if lfsr == 0:
        lfsr = 0xFFFFFFFF
    seq = np.zeros(length, dtype=int)
    # Taps: 32,26,23,22,16,12,11,10,8,7,5,4,2,1
    # ETSI tap N → bit position (32-N): 32→0, 26→6, 23→9, 22→10,
    # 16→16, 12→20, 11→21, 10→22, 8→24, 7→25, 5→27, 4→28, 2→30, 1→31
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
    """Descramble BSCH (fixed init=3)."""
    seq = scrambler_seq(SCRAMB_INIT, len(bits))
    return (bits ^ seq) & 1


# =============================================================================
# Block De-interleaver (EN 300 392-2 §8.2.4)
# =============================================================================

def deinterleave(bits, length):
    """Column-write, row-read → inverse: row-write, column-read."""
    if length == 240:
        R, C = 16, 15
    elif length == 216:
        R, C = 24, 9
    elif length == 162:
        R, C = 18, 9
    elif length == 28:
        R, C = 4, 7
    else:
        return bits.copy()

    out = np.zeros(length, dtype=int)
    for k in range(length):
        row = k % R
        col = k // R
        out[k] = bits[row * C + col]
    return out


# =============================================================================
# Viterbi Decoder (K=5, rate 1/3)
# =============================================================================

def parity(x, mask):
    """Compute parity of x & mask."""
    v = x & mask
    v ^= v >> 4
    v ^= v >> 2
    v ^= v >> 1
    return v & 1


def viterbi_decode_r13(coded_bits):
    """
    Viterbi decoder for K=5, rate 1/3, generators G1=0x1B, G2=0x19, G3=0x15.
    Hard decision.

    Shift register convention (matches tetra_hal.c encoder):
      sr = (sr << 1 | input) & 0x1F
      bit 0 = newest input, bit 4 = oldest
      state = sr & 0xF (lower 4 bits)
      For transition: sr = (old_state << 1 | inp) & 0x1F
                      new_state = sr & 0xF
    """
    n_states = 16  # 2^(K-1)
    n_coded = len(coded_bits)
    n_input = n_coded // 3

    INF = 999999

    pm = np.full(n_states, INF, dtype=int)
    pm[0] = 0
    tb_state = np.zeros((n_input, n_states), dtype=int)
    tb_input = np.zeros((n_input, n_states), dtype=int)

    for i in range(n_input):
        g1_rx = coded_bits[3 * i]
        g2_rx = coded_bits[3 * i + 1]
        g3_rx = coded_bits[3 * i + 2]

        new_pm = np.full(n_states, INF, dtype=int)

        for old_state in range(n_states):
            if pm[old_state] >= INF:
                continue

            for inp in range(2):
                sr = ((old_state << 1) | inp) & 0x1F
                new_state = sr & 0xF  # lower 4 bits

                e1 = parity(sr, G1)
                e2 = parity(sr, G2)
                e3 = parity(sr, G3)

                dist = (e1 ^ g1_rx) + (e2 ^ g2_rx) + (e3 ^ g3_rx)
                metric = pm[old_state] + dist

                if metric < new_pm[new_state]:
                    new_pm[new_state] = metric
                    tb_state[i, new_state] = old_state
                    tb_input[i, new_state] = inp

        pm = new_pm

    # Traceback from state 0 (tail bits flush encoder to zero state)
    decoded = np.zeros(n_input, dtype=int)
    state = 0
    for i in range(n_input - 1, -1, -1):
        decoded[i] = tb_input[i, state]
        state = tb_state[i, state]

    return decoded


# =============================================================================
# CRC-16-CCITT Check
# =============================================================================

def crc16_check(bits):
    """Check CRC-16-CCITT. bits = type-1 + CRC (76 bits for SYSINFO)."""
    crc = CRC_INIT
    for b in bits:
        feedback = (b & 1) ^ ((crc >> 15) & 1)
        crc = (crc << 1) & 0xFFFF
        if feedback:
            crc ^= CRC_POLY
    return crc == 0


# =============================================================================
# SYSINFO PDU Parser (EN 300 392-2 §15.3.8)
# =============================================================================

def parse_sysinfo(bits):
    """Parse 60 type-1 bits into SYSINFO fields."""
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
# Main decode pipeline
# =============================================================================

def load_rtlsdr_iq(filename):
    """Load RTL-SDR IQ file (uint8 interleaved)."""
    raw = np.fromfile(filename, dtype=np.uint8)
    iq = (raw[0::2].astype(np.float64) - 127.5) / 127.5 + \
        1j * (raw[1::2].astype(np.float64) - 127.5) / 127.5
    return iq


def estimate_freq_offset(iq, sample_rate):
    """Estimate residual frequency offset from spectral peak."""
    nfft = 8192
    spec = np.abs(fft(iq[:nfft] * np.hanning(nfft))) ** 2
    freqs = np.fft.fftfreq(nfft, 1 / sample_rate)
    # Ignore DC bin
    spec[0] = 0
    spec[1] = 0
    spec[-1] = 0
    peak = np.argmax(spec)
    f_off = freqs[peak]
    # Parabolic interpolation for sub-bin accuracy
    if 1 < peak < nfft - 1:
        alpha = np.log(spec[peak - 1] + 1e-12)
        beta = np.log(spec[peak] + 1e-12)
        gamma = np.log(spec[peak + 1] + 1e-12)
        delta = 0.5 * (alpha - gamma) / (alpha - 2 * beta + gamma)
        f_off = freqs[peak] + delta * (freqs[1] - freqs[0])
    return f_off


def estimate_freq_from_sts(iq_burst, sps, sts_offset_in_burst):
    """Estimate freq offset from STS phase slope."""
    sts_ref = build_sts_reference()
    sts_diff_ref = sts_ref[1:] * np.conj(sts_ref[:-1])

    indices = np.round(np.arange(SB_STS_LEN) * sps + sts_offset_in_burst).astype(int)
    indices = np.clip(indices, 0, len(iq_burst) - 1)
    syms = iq_burst[indices]
    diff = syms[1:] * np.conj(syms[:-1])

    # Phase error per symbol: actual_diff vs expected_diff
    phase_err = np.angle(diff * np.conj(sts_diff_ref))
    # Linear fit → slope is frequency offset in rad/symbol
    x = np.arange(len(phase_err))
    slope = np.polyfit(x, phase_err, 1)[0]
    # Also get mean phase offset
    mean_offset = np.mean(phase_err)

    return slope, mean_offset


def decode_tetra_sb(filename, sample_rate=2400000, freq_offset=0, verbose=True):
    """Full decode pipeline for TETRA SB from RTL-SDR capture."""

    print(f"=== TETRA SB Decoder ===")
    print(f"File: {filename}")
    print(f"Sample rate: {sample_rate}")

    # 1. Load IQ data
    iq = load_rtlsdr_iq(filename)
    print(f"Loaded {len(iq)} samples ({len(iq)/sample_rate:.3f}s)")

    # 2. Estimate and correct frequency offset
    if freq_offset == 0:
        freq_offset = estimate_freq_offset(iq, sample_rate)
        print(f"Estimated freq offset: {freq_offset:.1f} Hz")

    if abs(freq_offset) > 10:
        t = np.arange(len(iq)) / sample_rate
        iq *= np.exp(-1j * 2 * np.pi * freq_offset * t)
        print(f"Frequency corrected: {freq_offset:.1f} Hz")

    # 3. Low-pass filter + decimate to ~4x symbol rate
    sps_target = 4  # samples per symbol
    target_rate = SYMBOL_RATE * sps_target  # 72 kHz
    decim = max(1, int(sample_rate / target_rate))
    actual_rate = sample_rate / decim
    sps = actual_rate / SYMBOL_RATE

    # Simple CIC-like decimation with anti-alias
    if decim > 1:
        # FIR low-pass
        ntaps = decim * 8 + 1
        cutoff = target_rate / sample_rate
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2))
        h *= np.hanning(ntaps)
        h /= np.sum(h)
        iq_filt = np.convolve(iq, h, mode='same')
        iq_dec = iq_filt[::decim]
    else:
        iq_dec = iq

    print(f"Decimated: {decim}x → {actual_rate:.0f} sps, {sps:.2f} samples/symbol")

    # 4. RRC matched filter
    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = rrc_filter(rrc_ntaps, 0.35, sps)
    iq_rrc = np.convolve(iq_dec, rrc, mode='same')
    print(f"RRC filter: {rrc_ntaps} taps, α=0.35")

    # 5. Find STS (Sync Training Sequence)
    print(f"\nSearching for Sync Bursts...")
    peaks = find_sync_bursts(iq_rrc, sps, min_corr=0.35)

    if not peaks:
        print("ERROR: No sync bursts found!")
        print("Check: signal present? frequency correct? gain sufficient?")
        return False

    print(f"Found {len(peaks)} candidate SB(s):")
    for i, (off, corr) in enumerate(peaks[:5]):
        print(f"  [{i}] sample {off}, correlation {corr:.3f}")

    # 6. For each detected SB, try to decode
    decoded_any = False

    for sb_idx, (sts_offset, corr) in enumerate(peaks[:5]):
        print(f"\n--- Decoding SB #{sb_idx} (corr={corr:.3f}) ---")

        # STS starts at offset. Burst start = STS - (FC + BKN1) symbols
        burst_start = sts_offset - int((SB_FC_LEN + SB_BKN1_LEN) * sps)
        if burst_start < 0:
            print("  Burst start before capture, skipping")
            continue

        burst_end = burst_start + int(SB_TOTAL * sps)
        if burst_end > len(iq_rrc):
            print("  Burst extends beyond capture, skipping")
            continue

        # Extract symbol-spaced samples for entire burst
        # Fine timing: try sub-sample offsets around STS peak
        best_timing = 0
        best_corr = 0
        for dt in np.linspace(-0.5, 0.5, 21):
            indices = np.round(np.arange(SB_STS_LEN) * sps + sts_offset + dt * sps / sps).astype(int)
            indices = np.clip(indices, 0, len(iq_rrc) - 1)
            syms = iq_rrc[indices]
            diff = syms[1:] * np.conj(syms[:-1])
            sts_ref = build_sts_reference()
            sts_diff = sts_ref[1:] * np.conj(sts_ref[:-1])
            c = np.abs(np.sum(diff / (np.abs(diff) + 1e-12) * np.conj(sts_diff / (np.abs(sts_diff) + 1e-12)))) / len(sts_diff)
            if c > best_corr:
                best_corr = c
                best_timing = dt

        # Extract all 255 symbols with fine timing
        sym_indices = np.round(
            np.arange(SB_TOTAL) * sps + burst_start + best_timing
        ).astype(int)
        sym_indices = np.clip(sym_indices, 0, len(iq_rrc) - 1)
        burst_syms = iq_rrc[sym_indices]

        # Estimate and correct residual frequency offset using STS
        sts_start_in_burst = int((SB_FC_LEN + SB_BKN1_LEN) * sps)
        slope, mean_ph = estimate_freq_from_sts(iq_rrc[int(burst_start):int(burst_end)],
                                                 sps, sts_start_in_burst)
        # mean_ph = per-symbol differential phase error → frequency offset
        # slope = rate of change of differential phase error → chirp
        # Absolute phase correction = cumulative sum of differential errors
        freq_err_hz = mean_ph * SYMBOL_RATE / (2 * np.pi)
        if verbose:
            print(f"  STS freq err: {freq_err_hz:.1f} Hz, phase bias: {np.degrees(mean_ph):.1f}°/sym")

        n = np.arange(SB_TOTAL)
        phase_correction = mean_ph * n + 0.5 * slope * n * n
        burst_syms *= np.exp(-1j * phase_correction)

        # Demodulate
        dibits = demod_pi4dqpsk(burst_syms)
        # dibits has 254 entries (255-1 for differential)
        # First dibit corresponds to transition sym0→sym1

        # SB layout (symbol indices, 0-based):
        # FC: sym 0..1 (2 symbols)
        # BKN1: sym 2..121 (120 symbols)
        # STS: sym 122..159 (38 symbols)
        # BB: sym 160..173 (14 symbols)
        # BKN2: sym 174..254 (81 symbols)
        #
        # After differential demod (loses first symbol), dibit indices:
        # FC: dibit 0..0 (only 1 dibit from 2 FC symbols)
        # We need to be careful about the offset

        # Actually for differential demod, dibit[k] = phase(sym[k+1]) - phase(sym[k])
        # The burst has 255 symbols → 254 dibits after demod
        # FC contributes the first 2 symbols → dibit[0] is FC
        # BKN1 starts at sym 2 → dibit[1] to dibit[120]  (120 dibits)
        # STS starts at sym 122 → dibit[121] to dibit[158] (38 dibits... but first STS dibit
        #   is transition from last BKN1 symbol to first STS symbol)
        # Actually the dibit IS the symbol in pi/4-DQPSK — each symbol's dibit encodes the
        # differential phase from the previous symbol. So sym[k] carries dibit[k-1].
        # The FC symbols serve as a phase reference. After FC, BKN1 starts at dibit index 1.

        # BKN1: 120 dibits = 240 bits (type-5)
        bkn1_start = SB_FC_LEN - 1  # dibit index (differential loses 1)
        bkn1_dibits = dibits[bkn1_start:bkn1_start + SB_BKN1_LEN]

        if len(bkn1_dibits) < SB_BKN1_LEN:
            print("  Not enough dibits for BKN1")
            continue

        # Convert dibits to bits (MSB first per dibit)
        bkn1_bits = np.zeros(SB_BKN1_LEN * 2, dtype=int)
        for j, d in enumerate(bkn1_dibits):
            bkn1_bits[2 * j] = (d >> 1) & 1
            bkn1_bits[2 * j + 1] = d & 1

        print(f"  BKN1: {len(bkn1_bits)} type-5 bits extracted")

        # 7. Descramble (BSCH: fixed init=3)
        type4 = descramble_bsch(bkn1_bits)
        print(f"  Descrambled (init={SCRAMB_INIT})")

        # 8. De-interleave
        type4_deint = deinterleave(type4, BSCH_CODED_BITS)
        print(f"  De-interleaved (16×15)")

        # 9. Viterbi decode (rate 1/3, 240 → 80 bits)
        type3 = viterbi_decode_r13(type4_deint)
        print(f"  Viterbi decoded: {len(type3)} bits")

        # Remove 4 tail bits → 76 type-2 bits
        type2 = type3[:76]

        # 10. CRC-16 check
        crc_ok = crc16_check(type2)
        type1 = type2[:SYSINFO_BITS]

        if crc_ok:
            print(f"  CRC-16: PASS ✓")
            info = parse_sysinfo(type1)
            print(f"\n  ╔═══════════════════════════════════════╗")
            print(f"  ║  SYSINFO Decoded Successfully!        ║")
            print(f"  ╠═══════════════════════════════════════╣")
            print(f"  ║  MCC:          {info['MCC']:>5d}                ║")
            print(f"  ║  MNC:          {info['MNC']:>5d}                ║")
            print(f"  ║  Location Area:{info['LA']:>5d}                ║")
            print(f"  ║  Colour Code:  {info['CC']:>5d}                ║")
            print(f"  ║  TS assigned:  {info['TS_assigned']:>5d}                ║")
            print(f"  ║  DL usage:     0x{info['DL_usage']:02X}                 ║")
            print(f"  ╚═══════════════════════════════════════╝")
            decoded_any = True
        else:
            print(f"  CRC-16: FAIL ✗")
            # Show raw bits for debug
            if verbose:
                info = parse_sysinfo(type1)
                print(f"  (raw) MCC={info['MCC']} MNC={info['MNC']} LA={info['LA']} CC={info['CC']}")
                # Count bit errors by re-encoding and comparing
                print(f"  Viterbi path metric (final): likely high error rate")

    if not decoded_any:
        print("\nNo SB decoded successfully.")
        print("Possible issues:")
        print("  - Frequency offset (try --offset to compensate)")
        print("  - Weak signal (increase RTL-SDR gain)")
        print("  - Timing drift over burst")
        return False

    return True


# =============================================================================
# Entry point
# =============================================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='TETRA Sync Burst Decoder')
    parser.add_argument('input', nargs='?', default='/tmp/tetra_tx_capture.bin',
                        help='RTL-SDR IQ capture file (uint8)')
    parser.add_argument('--sr', type=int, default=2400000,
                        help='Sample rate (default 2400000)')
    parser.add_argument('--offset', type=float, default=0,
                        help='Frequency offset in Hz to correct')
    parser.add_argument('--capture', action='store_true',
                        help='Capture with RTL-SDR first')
    parser.add_argument('--freq', type=int, default=439100000,
                        help='Capture frequency (default 439100000)')
    parser.add_argument('--gain', type=float, default=40,
                        help='RTL-SDR gain (default 40)')
    parser.add_argument('--duration', type=float, default=2.0,
                        help='Capture duration in seconds (default 2)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    args = parser.parse_args()

    if args.capture:
        import subprocess
        n_samples = int(args.sr * args.duration)
        capture_file = '/tmp/tetra_tx_capture.bin'
        print(f"Capturing {args.duration}s at {args.freq/1e6:.3f} MHz...")
        subprocess.run([
            'rtl_sdr', '-d', '1',
            '-f', str(args.freq),
            '-s', str(args.sr),
            '-g', str(args.gain),
            '-n', str(n_samples),
            capture_file
        ], check=True)
        args.input = capture_file

    success = decode_tetra_sb(
        args.input,
        sample_rate=args.sr,
        freq_offset=args.offset,
        verbose=args.verbose,
    )
    sys.exit(0 if success else 1)
