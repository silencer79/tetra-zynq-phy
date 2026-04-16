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

    # Real-cell decoding: try many candidates and both layouts
    python3 scripts/decode_sb.py /tmp/cell.bin --sr 2000000 \
        --max-tries 50 --all-layouts --try-bit-reverse -v
"""

import argparse
import sys
import wave
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

# Non-continuous Synchronization Burst (§9.4.4.3.4)
#   Tail1(5) + FC(20) + sb1(60) + STS(19) + bb(15) + bkn2(108) + Tail2(5) + guard(23)
#   STS begins at symbol 85 (instead of 107 as in SDB).
NSB_OFF_SB1 = 25
NSB_OFF_STS = 85
NSB_OFF_BB = 104
NSB_OFF_BKN2 = 119

# Available burst layouts (name, sb1_offset, sts_offset).
# The decoder tries each layout against every STS candidate.
BURST_LAYOUTS = (
    ("SDB (continuous)", SDB_OFF_SB1, SDB_OFF_STS),
    ("SB  (non-cont.)",  NSB_OFF_SB1, NSB_OFF_STS),
)

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
# (NON-ETSI — matches this project's internal TX; used for loopback only.)
G1, G2, G3 = 0x1B, 0x19, 0x15

# ETSI EN 300 392-2 §8.2.3.1.1 — K=5 rate-1/4 mother code
#   G1 = 1 + D + D⁴            → taps {0,1,4}      = 0x13
#   G2 = 1 + D² + D³ + D⁴      → taps {0,2,3,4}    = 0x1D
#   G3 = 1 + D + D² + D⁴       → taps {0,1,2,4}    = 0x17
#   G4 = 1 + D + D³ + D⁴       → taps {0,1,3,4}    = 0x1B
# Cross-checked against osmo-tetra src/lower_mac/tetra_conv_enc.c (Welte 2011).
ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4 = 0x13, 0x1D, 0x17, 0x1B

# CRC-16-CCITT
CRC_POLY = 0x1021
CRC_INIT = 0xFFFF
CRC_DLL_POLY = 0x8408
CRC_DLL_GOOD = 0xF0B8

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
    slope, intercept = np.polyfit(x, phase_err, 1)
    return float(slope), float(intercept)


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

def crc16_bits(info_bits):
    crc = CRC_INIT
    for b in info_bits:
        feedback = (int(b) & 1) ^ ((crc >> 15) & 1)
        crc = (crc << 1) & 0xFFFF
        if feedback:
            crc ^= CRC_POLY
    out = np.zeros(16, dtype=np.int32)
    for i in range(16):
        out[i] = (crc >> (15 - i)) & 1
    return out


def crc16_check(bits, invert_fcs=False):
    info_bits = np.asarray(bits[:SYSINFO_BITS], dtype=np.int32)
    rx_fcs = np.asarray(bits[SYSINFO_BITS:SYSINFO_BITS + 16], dtype=np.int32)
    calc_fcs = crc16_bits(info_bits)
    if invert_fcs:
        calc_fcs ^= 1
    return bool(np.array_equal(rx_fcs, calc_fcs))


def crc16_check_dll(bits):
    """Match SDRSharp.Tetra.CRC16::Process on a full info+FCS bit buffer."""
    crc = 0xFFFF
    for b in bits:
        feedback = (int(b) & 1) ^ (crc & 1)
        crc >>= 1
        if feedback:
            crc ^= CRC_DLL_POLY
    return crc == CRC_DLL_GOOD


def crc16_modes(bits):
    return {
        'raw': crc16_check(bits, invert_fcs=False),
        'inverted': crc16_check(bits, invert_fcs=True),
        'dll': crc16_check_dll(bits),
    }


# =============================================================================
# Sync-PDU parser mirrored from SDRSharp.Tetra.MacLevel::_syncInfoRulesTMO
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
        'SystemCode': extract(bits, 0, 4),
        'ColorCode': extract(bits, 4, 6),
        'TimeSlot': extract(bits, 10, 2),
        'Frame': extract(bits, 12, 5),
        'MultiFrame': extract(bits, 17, 6),
        'SharingMode': extract(bits, 23, 2),
        'TSReservedFrames': extract(bits, 25, 3),
        'UPlaneDTX': extract(bits, 28, 1),
        'Frame18Extension': extract(bits, 29, 1),
        'Reserved': extract(bits, 30, 1),
        'MCC': extract(bits, 31, 10),
        'MNC': extract(bits, 41, 14),
        'NeighbourCellBroadcast': extract(bits, 55, 2),
        'CellServiceLevel': extract(bits, 57, 2),
        'LateEntryInfo': extract(bits, 59, 1),
    }


# =============================================================================
# IQ loading and coarse frequency estimation
# =============================================================================

def _load_wav_iq(filename, swap_iq=False):
    with wave.open(filename, 'rb') as wf:
        n_channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        sample_rate = wf.getframerate()
        n_frames = wf.getnframes()

        if n_channels < 2:
            raise ValueError("WAV input must be stereo I/Q (at least 2 channels)")
        if sample_width not in (1, 2, 4):
            raise ValueError(f"Unsupported WAV sample width: {sample_width} bytes")

        frames = wf.readframes(n_frames)

    if sample_width == 1:
        raw = np.frombuffer(frames, dtype=np.uint8).astype(np.float64)
        raw = (raw - 127.5) / 127.5
    elif sample_width == 2:
        raw = np.frombuffer(frames, dtype=np.int16).astype(np.float64) / 32768.0
    else:
        raw = np.frombuffer(frames, dtype=np.int32).astype(np.float64) / 2147483648.0

    raw = raw.reshape(-1, n_channels)
    i_idx, q_idx = (1, 0) if swap_iq else (0, 1)
    iq = raw[:, i_idx] + 1j * raw[:, q_idx]
    fmt = f"WAV stereo PCM {sample_width * 8}-bit"
    if swap_iq:
        fmt += " (I/Q swapped)"
    return iq, sample_rate, fmt


def load_iq_file(filename, swap_iq=False):
    if filename.lower().endswith('.wav'):
        return _load_wav_iq(filename, swap_iq=swap_iq)

    raw = np.fromfile(filename, dtype=np.uint8)
    iq = (raw[0::2].astype(np.float64) - 127.5) / 127.5 + \
        1j * (raw[1::2].astype(np.float64) - 127.5) / 127.5
    return iq, None, "RTL-SDR uint8 IQ"


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

# =============================================================================
# ETSI-correct BSCH decode path (per osmo-tetra reference)
# =============================================================================

# BSCH block-interleaver parameters (ETSI §8.2.4.1, BSCH row in osmo-tetra
# tetra_lower_mac.c: K=120, a=11)
BSCH_INTERL_K = 120
BSCH_INTERL_A = 11


def etsi_deinterleave_bsch(bits):
    """Multiplicative block de-interleave: out[i-1] = in[k-1] with k = 1 + (a·i mod K)."""
    K, a = BSCH_INTERL_K, BSCH_INTERL_A
    out = np.zeros(K, dtype=np.int32)
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        out[i - 1] = bits[k - 1]
    return out


def etsi_depuncture_r23(bits23):
    """ETSI §8.2.3.1.3 RCPC rate 2/3 depuncture over a rate-1/4 mother code.
    120 type-3 bits → 320 mother bits (erasures = 2).
    Pattern per 8-bit mother period (encoding 2 input bits):
      positions 1, 2, 5 of {g1,g2,g3,g4 | g1,g2,g3,g4}  →  g1(a), g2(a), g1(b).
    """
    P = [0, 1, 2, 5]            # P_rate2_3 (1-indexed at positions 1..3)
    t, period = 3, 8
    n_out = 0
    # For rate 2/3 with t=3 and 80 input bits → 80 * 4 = 320 mother bits
    # encoded as 40 periods × 8 mother-bits per period.  Each period keeps 3 bits.
    # So type3 length is 40*3 = 120 ✓.
    mother_len = (len(bits23) // 3) * 8      # 120 → 320
    out = np.full(mother_len, 2, dtype=np.int32)  # 2 = erasure
    for j in range(1, len(bits23) + 1):
        i = j   # i_func_equals
        k = period * ((i - 1) // t) + P[i - t * ((i - 1) // t)]
        out[k - 1] = bits23[j - 1]
        n_out += 1
    return out


def _parity5(x):
    v = x & 0x1F
    v ^= v >> 4
    v ^= v >> 2
    v ^= v >> 1
    return v & 1


def etsi_viterbi_decode_r14_with_erasures(coded_bits):
    """K=5 Viterbi over ETSI rate-1/4 mother code.  Erasure (value 2) → zero-cost branch.

    SR convention: sr = (old_state << 1 | input) & 0x1F; new_state = sr & 0xF.
    Generators applied via parity(sr & G_i).
    """
    n_states = 16
    n_coded = len(coded_bits)
    n_input = n_coded // 4
    INF = 10 ** 9

    pm = np.full(n_states, INF, dtype=np.int64)
    pm[0] = 0
    tb_state = np.zeros((n_input, n_states), dtype=np.int32)
    tb_input = np.zeros((n_input, n_states), dtype=np.int32)

    Gs = (ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4)
    for i in range(n_input):
        rx = [int(coded_bits[4 * i + m]) for m in range(4)]
        new_pm = np.full(n_states, INF, dtype=np.int64)

        for old_state in range(n_states):
            if pm[old_state] >= INF:
                continue
            for inp in range(2):
                sr = ((old_state << 1) | inp) & 0x1F
                new_state = sr & 0xF
                metric = pm[old_state]
                for m, G in enumerate(Gs):
                    e = _parity5(sr & G)
                    if rx[m] != 2:
                        metric += (e ^ rx[m])
                if metric < new_pm[new_state]:
                    new_pm[new_state] = metric
                    tb_state[i, new_state] = old_state
                    tb_input[i, new_state] = inp
        pm = new_pm

    decoded = np.zeros(n_input, dtype=np.int32)
    state = 0
    for i in range(n_input - 1, -1, -1):
        decoded[i] = tb_input[i, state]
        state = tb_state[i, state]
    return decoded


def etsi_viterbi_decode_r23(coded_bits):
    """120 rate-2/3 bits → 80 decoded bits (ETSI rate-1/4 mother, punct P_2_3)."""
    return etsi_viterbi_decode_r14_with_erasures(etsi_depuncture_r23(coded_bits))


def _try_decode_attempt_etsi(burst_syms, sb1_offset, msb_first, verbose,
                             invert_fcs=False):
    """ETSI-correct BSCH decode.  Returns (crc_ok, info, raw_bits, crc_mode)."""
    dibits = demod_pi4dqpsk(burst_syms)
    sb1_start = sb1_offset - 1
    if sb1_start < 0 or sb1_start + SDB_SB1_LEN > len(dibits):
        return False, None, None, None
    sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]

    sb1_bits = np.zeros(SDB_SB1_LEN * 2, dtype=np.int32)
    for j, d in enumerate(sb1_dibits):
        if msb_first:
            sb1_bits[2 * j]     = (int(d) >> 1) & 1
            sb1_bits[2 * j + 1] = int(d) & 1
        else:
            sb1_bits[2 * j]     = int(d) & 1
            sb1_bits[2 * j + 1] = (int(d) >> 1) & 1

    type4 = descramble_bsch(sb1_bits)                 # scramble unchanged
    type3 = etsi_deinterleave_bsch(type4)             # multiplicative K=120/a=11
    type2 = etsi_viterbi_decode_r23(type3)            # rate-1/4 mother + RCPC 2/3
    info_crc = type2[:SYSINFO_BITS + 16]
    modes = crc16_modes(info_crc)
    crc_mode = 'dll' if modes['dll'] else \
               'inverted' if (invert_fcs and modes['inverted']) else \
               'raw' if modes['raw'] else \
               'inverted' if modes['inverted'] else None
    crc_ok = modes['dll'] or (modes['inverted'] if invert_fcs else modes['raw'])
    info = parse_sysinfo(info_crc[:SYSINFO_BITS])
    return crc_ok, info, info_crc[:SYSINFO_BITS], crc_mode


def _try_decode_attempt(burst_syms, sb1_offset, msb_first, verbose):
    """Try to decode a single sb1 block.  Returns (crc_ok, info, raw_bits, crc_mode).

    burst_syms:   255 complex symbols (already freq/phase corrected)
    sb1_offset:   symbol index where sb1 begins in the 255-symbol burst
    msb_first:    True = (dibit>>1)&1 is first bit, False = reversed packing
    """
    dibits = demod_pi4dqpsk(burst_syms)
    sb1_start = sb1_offset - 1
    if sb1_start < 0 or sb1_start + SDB_SB1_LEN > len(dibits):
        return False, None, None, None
    sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]

    sb1_bits = np.zeros(SDB_SB1_LEN * 2, dtype=np.int32)
    for j, d in enumerate(sb1_dibits):
        if msb_first:
            sb1_bits[2 * j]     = (int(d) >> 1) & 1
            sb1_bits[2 * j + 1] = int(d) & 1
        else:
            sb1_bits[2 * j]     = int(d) & 1
            sb1_bits[2 * j + 1] = (int(d) >> 1) & 1

    type4i = descramble_bsch(sb1_bits)
    type4 = deinterleave(type4i, BSCH_CODED_BITS)
    type3 = viterbi_decode_r23(type4)
    type2 = type3[:SYSINFO_BITS + 16]
    crc_ok = crc16_check(type2)
    info = parse_sysinfo(type2[:SYSINFO_BITS])
    return crc_ok, info, type2[:SYSINFO_BITS], 'raw' if crc_ok else None


def decode_tetra_sb(filename, sample_rate=2048000, freq_offset=0.0,
                    verbose=True, max_tries=5, try_all_layouts=False,
                    try_bit_reverse=False, conjugate=False, etsi=False,
                    swap_iq=False, invert_fcs=False, summary_bursts=False):
    print("=== TETRA Continuous-SB Decoder ===")
    print(f"File: {filename}")

    iq, detected_rate, input_fmt = load_iq_file(filename, swap_iq=swap_iq)
    print(f"Input format: {input_fmt}")
    if detected_rate is not None:
        if sample_rate != detected_rate:
            print(f"Sample rate override: CLI {sample_rate} -> file {detected_rate}")
        sample_rate = detected_rate
    print(f"Sample rate: {sample_rate}")

    print(f"Loaded {len(iq)} samples ({len(iq)/sample_rate:.3f}s)")
    if conjugate:
        iq = np.conj(iq)
        print("Applied I/Q conjugate (spectrum mirror)")

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

    # Build the attempt table (layouts × bit-orders)
    layouts = BURST_LAYOUTS if try_all_layouts else BURST_LAYOUTS[:1]
    bit_orders = ((True, "msb_first"), (False, "lsb_first")) if try_bit_reverse \
                 else ((True, "msb_first"),)

    candidates = peaks[:max_tries]
    decode_fn = _try_decode_attempt_etsi if etsi else _try_decode_attempt
    mode_tag = "ETSI-conv" if etsi else "project-internal"
    if etsi and invert_fcs:
        mode_tag += ", inverted-FCS"
    print(f"\nTrying {len(candidates)} candidate(s) × {len(layouts)} layout(s) × "
          f"{len(bit_orders)} bit-order(s) = "
          f"{len(candidates)*len(layouts)*len(bit_orders)} attempt(s)  [{mode_tag}]")

    summary_bits = []

    for sb_idx, (sts_offset, corr) in enumerate(candidates):
        if verbose:
            print(f"\n--- Candidate #{sb_idx}: sample {sts_offset}, STS corr {corr:.3f} ---")

        for layout_name, layout_sb1, layout_sts in layouts:
            # Burst start is layout_sts symbols before the STS position
            burst_start = sts_offset - int(layout_sts * sps)
            if burst_start < 0:
                continue
            burst_end = burst_start + int(SB_TOTAL * sps)
            if burst_end > len(iq_rrc):
                continue

            # Refine timing with sub-sample sweep
            best_timing = 0.0
            best_corr = 0.0
            sts_ref = build_sts_reference()
            sts_diff = sts_ref[1:] * np.conj(sts_ref[:-1])
            sts_norm = sts_diff / (np.abs(sts_diff) + 1e-12)
            for dt in np.linspace(-0.5, 0.5, 21):
                indices = np.round(
                    np.arange(SDB_STS_LEN) * sps + sts_offset + dt
                ).astype(int)
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
            slope, intercept = estimate_freq_from_sts(
                iq_rrc[int(burst_start):int(burst_end)], sps,
                int(layout_sts * sps) + best_timing
            )
            # phase_err[k] is measured on STS differential pairs relative to the
            # STS start, so integrate the correction around the STS origin rather
            # than around the burst start.
            freq_err_hz = intercept * SYMBOL_RATE / (2 * np.pi)
            n_rel = np.arange(SB_TOTAL, dtype=np.float64) - float(layout_sts)
            phase_correction = intercept * n_rel + 0.5 * slope * n_rel * (n_rel - 1.0)
            burst_syms_corr = burst_syms * np.exp(-1j * phase_correction)

            for msb_first, order_name in bit_orders:
                crc_ok, info, raw_bits, crc_mode = decode_fn(
                    burst_syms_corr, layout_sb1, msb_first, verbose,
                    invert_fcs=invert_fcs
                ) if etsi else decode_fn(
                    burst_syms_corr, layout_sb1, msb_first, verbose
                )
                tag = f"[{layout_name}/{order_name}]"

                if crc_ok:
                    summary_bits.append(np.asarray(raw_bits, dtype=np.int32).copy())
                    print(f"\n  {tag} #{sb_idx}  timing={best_timing:+.2f} sample"
                          f"  STS={best_corr:.3f}  Δf={freq_err_hz:+.1f} Hz")
                    print("  ╔═══════════════════════════════════════╗")
                    print("  ║  SYSINFO Decoded Successfully!        ║")
                    print("  ╠═══════════════════════════════════════╣")
                    if crc_mode is not None:
                        print(f"  ║  CRC mode:     {crc_mode:>9s}           ║")
                    print(f"  ║  System Code:  {info['SystemCode']:>5d}                ║")
                    print(f"  ║  Colour Code:  {info['ColorCode']:>5d}                ║")
                    print(f"  ║  TimeSlot:     {info['TimeSlot']:>5d}                ║")
                    print(f"  ║  Frame:        {info['Frame']:>5d}                ║")
                    print(f"  ║  MultiFrame:   {info['MultiFrame']:>5d}                ║")
                    print(f"  ║  SharingMode:  {info['SharingMode']:>5d}                ║")
                    print(f"  ║  MCC:          {info['MCC']:>5d}                ║")
                    print(f"  ║  MNC:          {info['MNC']:>5d}                ║")
                    print(f"  ║  NeighCellBc:  {info['NeighbourCellBroadcast']:>5d}                ║")
                    print(f"  ║  CellSvcLvl:   {info['CellServiceLevel']:>5d}                ║")
                    print("  ╚═══════════════════════════════════════╝")
                    decoded_any = True
                elif verbose:
                    print(f"  {tag} CRC FAIL  MCC={info['MCC']} MNC={info['MNC']} "
                          f"SC={info['SystemCode']} CC={info['ColorCode']}  STS_ref={best_corr:.3f}")

    if summary_bursts and summary_bits:
        bit_matrix = np.vstack(summary_bits).astype(np.int32)
        majority_bits = (np.mean(bit_matrix, axis=0) >= 0.5).astype(np.int32)
        majority_info = parse_sysinfo(majority_bits)
        print("\nMajority Summary Across Passing Bursts:")
        print(f"  Count: {len(summary_bits)}")
        print(f"  SystemCode={majority_info['SystemCode']} ColorCode={majority_info['ColorCode']} "
              f"TimeSlot={majority_info['TimeSlot']} Frame={majority_info['Frame']} "
              f"MultiFrame={majority_info['MultiFrame']}")
        print(f"  MCC={majority_info['MCC']} MNC={majority_info['MNC']} "
              f"NeighCellBc={majority_info['NeighbourCellBroadcast']} "
              f"CellSvcLvl={majority_info['CellServiceLevel']}")

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
    parser.add_argument('--max-tries', type=int, default=5,
                        help='Max STS candidates to attempt (default 5)')
    parser.add_argument('--all-layouts', action='store_true',
                        help='Also try non-continuous SB layout (STS @ sym 85)')
    parser.add_argument('--try-bit-reverse', action='store_true',
                        help='Also try LSB-first dibit→bit packing')
    parser.add_argument('--conjugate', action='store_true',
                        help='Conjugate I/Q (mirror spectrum) before decode')
    parser.add_argument('--swap-iq', action='store_true',
                        help='Swap I and Q channels when reading stereo WAV input')
    parser.add_argument('--invert-fcs', action='store_true',
                        help='Accept inverted BSCH CRC bits (observed on some captures)')
    parser.add_argument('--summary-bursts', action='store_true',
                        help='Print a majority-vote summary across all passing bursts')
    parser.add_argument('--etsi', action='store_true',
                        help='Use ETSI-correct BSCH decoder (rate-1/4 conv, '
                             'multiplicative deinterleave K=120/a=11) — '
                             'needed for real TETRA cells')
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
                         freq_offset=args.offset, verbose=args.verbose,
                         max_tries=args.max_tries,
                         try_all_layouts=args.all_layouts,
                         try_bit_reverse=args.try_bit_reverse,
                         conjugate=args.conjugate,
                         etsi=args.etsi,
                         swap_iq=args.swap_iq,
                         invert_fcs=args.invert_fcs,
                         summary_bursts=args.summary_bursts)
    sys.exit(0 if ok else 1)
