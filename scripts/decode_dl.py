#!/usr/bin/env python3
"""
decode_dl.py — Full TETRA Downlink Decoder (all burst types + MAC/LLC/MLE)

Decodes ALL burst types from a TETRA continuous downlink capture:
  - SB  (Sync Burst)  → SYSINFO from SB1, BNCH from BKN2
  - NDB (Normal Burst) → AACH from BB, MAC PDU from BKN1+BKN2 (SCH/F)

Pipeline per burst:
  π/4-DQPSK demod → training seq correlation (STS/NTS1/NTS2) →
  burst splitting → descramble → deinterleave → Viterbi → CRC →
  MAC PDU parse → LLC → MLE/CMCE

Mirrors the SDRSharp.Tetra.dll decode pipeline for 1:1 comparison.

Usage:
    # From RTL-SDR capture:
    python3 scripts/decode_dl.py /tmp/cap.bin --sr 2048000

    # From WAV file:
    python3 scripts/decode_dl.py /tmp/cap.wav

    # Live capture + decode:
    python3 scripts/decode_dl.py --capture --freq 440106000 --sr 2048000
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

# π/4-DQPSK differential phase per dibit (§5.5.2.3)
DIBIT_TO_DPHASE = {
    0b00:  np.pi / 4,
    0b01:  3 * np.pi / 4,
    0b10: -np.pi / 4,
    0b11: -3 * np.pi / 4,
}

# Training sequences (dibits, MSB-first from Verilog literals)
# STS — 19 symbols (§9.4.4.3.4)
STS_DIBITS = [
    0b11, 0b00, 0b00, 0b01, 0b10, 0b01, 0b11, 0b00,
    0b11, 0b10, 0b10, 0b01, 0b11, 0b00, 0b00, 0b01,
    0b10, 0b01, 0b11,
]
# NTS1 — 11 symbols (§9.4.4.3.2)
NTS1_DIBITS = [
    0b11, 0b01, 0b00, 0b00, 0b11, 0b10,
    0b10, 0b01, 0b11, 0b01, 0b00,
]
# NTS2 — 11 symbols (§9.4.4.3.2 p_bits — two-logical-channel NDB)
NTS2_DIBITS = [
    0b01, 0b11, 0b10, 0b10, 0b01, 0b00,
    0b00, 0b11, 0b01, 0b11, 0b10,
]

# Burst lengths (in symbols / dibits)
BURST_SYMBOLS = 255

# --- SDB (Sync Downlink Burst, continuous DL, §9.4.4.2.6) ---
# Tail1(6) + PhAdj(1) + FC(40) + SB1(60) + STS(19) + BB(15) + BKN2(108) + PhAdj(1) + Tail2(5)
SDB_TAIL1    = 6
SDB_PHADJ1   = 1
SDB_FC       = 40
SDB_SB1      = 60   # 120 bits
SDB_STS      = 19   # 38 bits
SDB_BB       = 15   # 30 bits
SDB_BKN2     = 108  # 216 bits
SDB_PHADJ2   = 1
SDB_TAIL2    = 5

SDB_OFF_SB1  = SDB_TAIL1 + SDB_PHADJ1 + SDB_FC                    # 47
SDB_OFF_STS  = SDB_OFF_SB1 + SDB_SB1                               # 107
SDB_OFF_BB   = SDB_OFF_STS + SDB_STS                               # 126
SDB_OFF_BKN2 = SDB_OFF_BB + SDB_BB                                 # 141

# --- Non-continuous SB (§9.4.4.3.4) ---
# Tail(5) + FC(20) + SB1(60) + STS(19) + BB(15) + BKN2(108) + Tail(5) + Guard(23)
NSB_OFF_SB1  = 25   # 5 + 20
NSB_OFF_STS  = 85   # 25 + 60
NSB_OFF_BB   = 104  # 85 + 19
NSB_OFF_BKN2 = 119  # 104 + 15

# --- NCDB (Normal Continuous Downlink Burst, §9.4.4.2.5) ---
# Per osmo-tetra build_norm_c_d_burst():
#   q11..q22 (12b=6s) + HA (1s) + BLK1(108s) + BB1(7s) + NTS(11s) + BB2(8s) + BLK2(108s) + HB (1s) + q1..q10 (5s)
#   Total: 6+1+108+7+11+8+108+1+5 = 255 sym
NDB_TAIL1    = 6    # q11..q22 (12 bits = 6 sym)
NDB_PHADJ1   = 1
NDB_BLK1     = 108  # 216 bits
NDB_BB1      = 7    # 14 bits (upper 14 of 30-bit BB)
NDB_NTS      = 11   # 22 bits
NDB_BB2      = 8    # 16 bits (lower 16 of 30-bit BB)
NDB_BLK2     = 108  # 216 bits
NDB_PHADJ2   = 1
NDB_TAIL2    = 5    # q1..q10 (10 bits = 5 sym)

NDB_OFF_BLK1 = NDB_TAIL1 + NDB_PHADJ1                              # 7
NDB_OFF_BB1  = NDB_OFF_BLK1 + NDB_BLK1                             # 115
NDB_OFF_NTS  = NDB_OFF_BB1 + NDB_BB1                               # 122
NDB_OFF_BB2  = NDB_OFF_NTS + NDB_NTS                               # 133
NDB_OFF_BLK2 = NDB_OFF_BB2 + NDB_BB2                               # 141

# Channel coding constants
ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4 = 0x13, 0x1D, 0x17, 0x1B
CRC_DLL_POLY = 0x8408
CRC_DLL_GOOD = 0xF0B8

# RM(30,14) generator matrix (EN 300 392-2 §8.2.3.2, Table 8.11)
RM_GEN = [
    [1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0, 0],
    [0, 0, 1, 0, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0],
    [1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0],
    [1, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 0, 1, 0],
    [0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 1, 0],
    [0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0],
    [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1],
    [1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1],
    [0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1],
    [0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1],
    [0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1],
    [0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 1, 1],
    [0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1],
]

# =============================================================================
# π/4-DQPSK helpers
# =============================================================================

def dibits_to_symbols(dibits, phase0=0.0):
    phase = phase0
    out = np.empty(len(dibits), dtype=np.complex128)
    for i, d in enumerate(dibits):
        phase += DIBIT_TO_DPHASE[int(d)]
        out[i] = np.exp(1j * phase)
    return out


def demod_pi4dqpsk(symbols):
    """Differential demod → dibit stream (len = len(symbols)-1)."""
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    out = np.empty(len(dphi), dtype=np.int32)
    for i, p in enumerate(dphi):
        if -np.pi / 2 < p <= 0:
            out[i] = 0b10
        elif 0 < p <= np.pi / 2:
            out[i] = 0b00
        elif np.pi / 2 < p <= np.pi:
            out[i] = 0b01
        else:
            out[i] = 0b11
    return out


def dibits_to_bits(dibits):
    """Convert dibit array to bit array (MSB first per dibit)."""
    bits = np.zeros(len(dibits) * 2, dtype=np.int32)
    for j, d in enumerate(dibits):
        bits[2 * j]     = (int(d) >> 1) & 1
        bits[2 * j + 1] = int(d) & 1
    return bits


# =============================================================================
# Training sequence correlation
# =============================================================================

def _build_diff_ref(dibits):
    """Build normalized differential reference for correlation."""
    syms = dibits_to_symbols(dibits)
    diff = syms[1:] * np.conj(syms[:-1])
    return diff / (np.abs(diff) + 1e-12)


STS_DIFF_REF  = _build_diff_ref(STS_DIBITS)
NTS1_DIFF_REF = _build_diff_ref(NTS1_DIBITS)
NTS2_DIFF_REF = _build_diff_ref(NTS2_DIBITS)


def _correlate_at(iq, pos, sps, ref_dibits, ref_diff):
    """Correlation score at a given sample position."""
    n_sym = len(ref_dibits)
    indices = np.round(np.arange(n_sym) * sps + pos).astype(int)
    if indices[-1] >= len(iq) or indices[0] < 0:
        return 0.0
    syms = iq[indices]
    diff = syms[1:] * np.conj(syms[:-1])
    diff_norm = diff / (np.abs(diff) + 1e-12)
    return float(np.abs(np.sum(diff_norm * np.conj(ref_diff))) / len(ref_diff))


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
# Scrambler (§8.2.5) — 32-bit Fibonacci LFSR
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


def make_scramb_code(mcc, mnc, cc):
    """TMO cell-identity scrambler init: (MCC<<22)|(MNC<<8)|(CC<<2)|3"""
    return ((mcc & 0x3FF) << 22) | ((mnc & 0x3FFF) << 8) | ((cc & 0x3F) << 2) | 3


def make_scramb_code_dmo(mnc, src_address):
    """DMO scrambler init: (MNC<<26)|(SourceAddress<<2)|3 (DLL 2-arg form)."""
    return ((mnc & 0x3F) << 26) | ((src_address & 0xFFFFFF) << 2) | 3


# =============================================================================
# CRC-32 (LLC FCS, mirrors LlcLevel.Poly=0xEDB88320, GoodFCS=0xDEBB20E3)
# =============================================================================

CRC32_POLY = 0xEDB88320
CRC32_GOOD = 0xDEBB20E3

def crc32_check_llc(bits):
    """LLC FCS CRC-32, bit-reversed CCITT. Returns True if residual = 0xDEBB20E3."""
    crc = 0xFFFFFFFF
    for b in bits:
        feedback = (int(b) & 1) ^ (crc & 1)
        crc >>= 1
        if feedback:
            crc ^= CRC32_POLY
    return (crc & 0xFFFFFFFF) == CRC32_GOOD


# =============================================================================
# NetworkTime — 1-based FN/TN/MN tracker with BSCH/BNCH rotation
# (mirrors DLL NetworkTime class)
# =============================================================================

class NetworkTime:
    """Tracks TN (1..4), FN (1..18), MN (1..60) with automatic wrap.
    Per DLL: only TN is 0-based on air; FN/MN are already 1-based."""

    def __init__(self):
        self.tn = 1
        self.fn = 1
        self.mn = 1
        self.synced = False

    def synchronize(self, air_tn, air_fn, air_mn):
        """Load from SB. Per DLL code: +1 on TN only; FN/MN pass through."""
        t = air_tn + 1
        f = air_fn
        m = air_mn
        self.tn = 4 if t >= 5 else (1 if t <= 0 else t)
        self.fn = 18 if f >= 19 else (1 if f <= 0 else f)
        self.mn = 60 if m >= 61 else (1 if m <= 0 else m)
        self.synced = True

    def advance(self):
        """Advance one timeslot (TN wraps at 4, FN at 18, MN at 60)."""
        self.tn += 1
        if self.tn > 4:
            self.tn = 1
            self.fn += 1
        if self.fn > 18:
            self.fn = 1
            self.mn += 1
        if self.mn > 60:
            self.mn = 1

    def is_bsch(self):
        """BSCH slot = FN=18, TN = 4 - ((MN+1) % 4)."""
        return self.fn == 18 and self.tn == 4 - ((self.mn + 1) % 4)

    def is_bnch(self):
        """BNCH slot = FN=18, TN = 4 - ((MN+3) % 4)."""
        return self.fn == 18 and self.tn == 4 - ((self.mn + 3) % 4)

    def __str__(self):
        tag = ''
        if self.is_bsch():
            tag = ' BSCH'
        elif self.is_bnch():
            tag = ' BNCH'
        return f"TN={self.tn} FN={self.fn:02d} MN={self.mn:02d}{tag}"


# =============================================================================
# FrequencyCalc — SYSINFO carrier/band/offset → Hz
# =============================================================================

def frequency_calc(carrier, band, offset):
    """DLL FrequencyCalc: band*1e8 + carrier*25k + offset adj.
    offset: 0=none, 1=+6.25k, 2=-6.25k, 3=+12.5k."""
    freq = band * 100_000_000 + carrier * 25_000
    if offset == 1:
        freq += 6250
    elif offset == 2:
        freq -= 6250
    elif offset == 3:
        freq += 12500
    return freq


# =============================================================================
# Multiplicative de-interleaver (§8.2.4.1)
# =============================================================================

def deinterleave_perm(bits, K, a):
    """out[i-1] = in[k-1] with k = 1 + (a·i) mod K."""
    out = np.zeros(K, dtype=np.int32)
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        out[i - 1] = bits[k - 1]
    return out


# =============================================================================
# ETSI Depuncture + Viterbi (rate-1/4 mother, RCPC 2/3)
# =============================================================================

def depuncture_r23(bits, mother_len):
    """RCPC 2/3 depuncture: keeps positions {1,2,5} of each 8-bit mother period.
    P[1..3] = {1,2,5} (1-indexed) → 3 bits per period → rate 2/3.
    Matches decode_sb.py etsi_depuncture_r23."""
    P = [0, 1, 2, 5]  # P[0] unused, P[1]=1, P[2]=2, P[3]=5 (1-indexed positions)
    t = 3
    period = 8
    out = np.full(mother_len, 2, dtype=np.int32)  # 2 = erasure
    for j in range(1, len(bits) + 1):
        i = j
        k = period * ((i - 1) // t) + P[i - t * ((i - 1) // t)]
        out[k - 1] = bits[j - 1]
    return out


def _parity5(x):
    v = x & 0x1F
    v ^= v >> 4
    v ^= v >> 2
    v ^= v >> 1
    return v & 1


def viterbi_r14(coded_bits):
    """K=5 Viterbi, rate-1/4 mother. Erasure=2 → zero cost."""
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


def decode_channel(type5_bits, K, a, info_bits_len):
    """Full channel decode: descramble is done before calling this.
    type5 → deinterleave → depuncture → Viterbi → CRC check.
    Returns (crc_ok, info_bits, viterbi_errors)."""
    # Deinterleave
    type4 = deinterleave_perm(type5_bits, K, a)
    # Depuncture: coded_len / 3 * 8 = mother_len
    mother_len = (len(type4) // 3) * 8
    type3 = depuncture_r23(type4, mother_len)
    # Viterbi
    decoded = viterbi_r14(type3)
    # decoded = info_bits + 16 CRC + 4 tail
    crc_len = info_bits_len + 16
    info_crc = decoded[:crc_len]
    # CRC check (DLL-style)
    crc_ok = crc16_check_dll(info_crc)
    return crc_ok, info_crc[:info_bits_len], decoded


# =============================================================================
# Soft-decision π/4-DQPSK demod + Viterbi
# =============================================================================

def demod_pi4dqpsk_soft(symbols):
    """Soft differential demod → soft bit pairs.
    Returns soft_bits array (2× len(symbols)-1): positive=0, negative=1.
    Magnitude = confidence."""
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    # b1 (MSB): 0 when sin(φ)>0, 1 when sin(φ)<0  →  soft_b1 = sin(φ)
    # b0 (LSB): 0 when cos(φ)>0, 1 when cos(φ)<0  →  soft_b0 = cos(φ)
    soft = np.empty(len(dphi) * 2, dtype=np.float64)
    for i, p in enumerate(dphi):
        soft[2 * i]     = np.sin(p)   # b1 (MSB)
        soft[2 * i + 1] = np.cos(p)   # b0 (LSB)
    return soft


def descramble_soft(soft_bits, init, length):
    """Soft descramble: negate where scrambler bit = 1."""
    scr = scrambler_seq(init, length)
    return soft_bits * (1.0 - 2.0 * scr)


def depuncture_r23_soft(soft_bits, mother_len):
    """Depuncture for soft values: erasures = 0.0 (neutral)."""
    P = [0, 1, 2, 5]
    t = 3
    period = 8
    out = np.zeros(mother_len, dtype=np.float64)
    for j in range(1, len(soft_bits) + 1):
        k = period * ((j - 1) // t) + P[j - t * ((j - 1) // t)]
        out[k - 1] = soft_bits[j - 1]
    return out


def viterbi_r14_soft(coded_soft):
    """K=5 soft-decision Viterbi, rate-1/4 mother.
    coded_soft: float array, positive=0, negative=1, 0=erasure.
    Uses correlation metric (maximize)."""
    n_states = 16
    n_coded = len(coded_soft)
    n_input = n_coded // 4
    NINF = -1e18

    pm = np.full(n_states, NINF, dtype=np.float64)
    pm[0] = 0.0
    tb_state = np.zeros((n_input, n_states), dtype=np.int32)
    tb_input = np.zeros((n_input, n_states), dtype=np.int32)

    Gs = (ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4)
    for i in range(n_input):
        rx = coded_soft[4 * i : 4 * i + 4]
        new_pm = np.full(n_states, NINF, dtype=np.float64)
        for old_state in range(n_states):
            if pm[old_state] <= NINF:
                continue
            for inp in range(2):
                sr = ((old_state << 1) | inp) & 0x1F
                new_state = sr & 0xF
                metric = pm[old_state]
                for m, G in enumerate(Gs):
                    e = _parity5(sr & G)
                    expected_sign = 1.0 - 2.0 * e  # +1 for bit=0, -1 for bit=1
                    metric += float(rx[m]) * expected_sign
                if metric > new_pm[new_state]:
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


def decode_channel_soft(soft_type5, K, a, info_bits_len):
    """Soft-decision channel decode.
    soft_type5: float array (positive=0, negative=1), already soft-descrambled.
    Returns (crc_ok, info_bits, decoded)."""
    # Deinterleave (permute soft values)
    type4 = np.zeros(K, dtype=np.float64)
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        type4[i - 1] = soft_type5[k - 1]
    # Depuncture
    mother_len = (K // 3) * 8
    type3 = depuncture_r23_soft(type4, mother_len)
    # Soft Viterbi
    decoded = viterbi_r14_soft(type3)
    crc_len = info_bits_len + 16
    info_crc = decoded[:crc_len]
    crc_ok = crc16_check_dll(info_crc)
    return crc_ok, info_crc[:info_bits_len], decoded


# =============================================================================
# CRC-16 (DLL-compatible, bit-reversed CCITT)
# =============================================================================

def crc16_check_dll(bits):
    crc = 0xFFFF
    for b in bits:
        feedback = (int(b) & 1) ^ (crc & 1)
        crc >>= 1
        if feedback:
            crc ^= CRC_DLL_POLY
    return crc == CRC_DLL_GOOD


# =============================================================================
# RM(30,14) Decoder for AACH (BB)
# =============================================================================

def _build_rm_codewords():
    """Build all 2^14 = 16384 codewords for brute-force RM decode."""
    rows = []
    for i in range(14):
        # systematic: identity bit at position (13-i) in upper 14, gen in lower 16
        val = (1 << (16 + 13 - i))
        for j in range(16):
            val |= RM_GEN[i][j] << (15 - j)
        rows.append(val)
    return rows


_RM_ROWS = _build_rm_codewords()


def rm3014_decode(bits30):
    """Brute-force RM(30,14) decode: find closest codeword by Hamming distance.
    Returns (info_14bits_int, distance) or (None, 30) if too many errors."""
    # Pack received 30 bits into int
    rx = 0
    for b in bits30:
        rx = (rx << 1) | (int(b) & 1)

    best_dist = 31
    best_info = 0

    # Try all 2^14 info words
    for info_word in range(1 << 14):
        cw = 0
        for i in range(14):
            if (info_word >> (13 - i)) & 1:
                cw ^= _RM_ROWS[i]
        dist = bin(rx ^ cw).count('1')
        if dist < best_dist:
            best_dist = dist
            best_info = info_word
            if dist == 0:
                break

    if best_dist > 4:  # RM(30,14) can correct up to t=? errors, be generous
        return None, best_dist
    return best_info, best_dist


def parse_aach(info14):
    """Parse 14-bit ACCESS-ASSIGN PDU (AACH) — EN 300 392-2 §21.5.1.
    Layout: Header(2) | Field1(6) | Field2(6).
    Header values (per DLL _aachLength dict):
      00 = DL/UL-Assign  (field1 = DL_usage(3)+UL_usage(3), field2 = ColourCode)
      01 = PktData       (same sub-layout as 00)
      10 = Reserved/broadcast
      11 = Capacity allocation
    """
    header = (info14 >> 12) & 0x3
    field1 = (info14 >> 6) & 0x3F
    field2 = info14 & 0x3F

    HEADER_NAMES = {0: 'DL/UL-Assign', 1: 'PktData', 2: 'Reserved', 3: 'CapAlloc'}
    DL_NAMES = {0: 'Unalloc', 1: 'Common', 2: 'Assigned', 3: 'Reserved',
                4: 'Traffic', 5: 'Traffic', 6: 'Traffic', 7: 'Traffic'}
    UL_NAMES = {0: 'Unalloc', 1: 'Random', 2: 'Assigned', 3: 'Reserved',
                4: 'Reserved', 5: 'Reserved', 6: 'Reserved', 7: 'Reserved'}

    r = {
        'header': header,
        'header_name': HEADER_NAMES.get(header, '?'),
        'field1': field1,
        'field2': field2,
        'raw': f'0x{info14:04X}',
    }

    if header in (0, 1):
        # Sub-decode: Field1 = DL_usage(3) | UL_usage(3), Field2 = ColourCode
        dl_usage = (field1 >> 3) & 0x7
        ul_usage = field1 & 0x7
        r.update({
            'dl_usage':    dl_usage,
            'dl_name':     DL_NAMES.get(dl_usage, '?'),
            'ul_usage':    ul_usage,
            'ul_name':     UL_NAMES.get(ul_usage, '?'),
            'colour_code': field2,
        })
    elif header == 3:
        # Capacity allocation: Field1 = Slot_Granting/Alloc_type, Field2 = ColourCode or ext carrier
        r['colour_code'] = field2
    # header == 2: reserved — only raw field values

    return r


# =============================================================================
# SYSINFO parser (from SB1, 60 bits)
# =============================================================================

def extract_bits(bits, start, n):
    val = 0
    for i in range(n):
        val = (val << 1) | (int(bits[start + i]) & 1)
    return val


def parse_sysinfo_sb(bits60):
    """Parse SYNC PDU from SB1 (60 decoded bits).
    First 4 bits = Sync_PDU_type (<8 = TMO, >=8 = DMO).
    Raw TN/FN/MN are 0-based (air interface); caller should +1 for 1-based NetworkTime.
    """
    sync_type = extract_bits(bits60, 0, 4)
    is_tmo = sync_type < 8

    if is_tmo:
        return {
            'Mode':           'TMO',
            'SystemCode':     sync_type,
            'Sync_PDU_type':  sync_type,
            'ColourCode':     extract_bits(bits60, 4, 6),
            'TimeSlot':       extract_bits(bits60, 10, 2),
            'Frame':          extract_bits(bits60, 12, 5),
            'MultiFrame':     extract_bits(bits60, 17, 6),
            'SharingMode':    extract_bits(bits60, 23, 2),
            'TSReserved':     extract_bits(bits60, 25, 3),
            'UplaneDTX':      extract_bits(bits60, 28, 1),
            'Frame18Ext':     extract_bits(bits60, 29, 1),
            'Reserved':       extract_bits(bits60, 30, 1),
            'MCC':            extract_bits(bits60, 31, 10),
            'MNC':            extract_bits(bits60, 41, 14),
            'NeighCellBc':    extract_bits(bits60, 55, 2),
            'CellSvcLvl':     extract_bits(bits60, 57, 2),
            'LateEntry':      extract_bits(bits60, 59, 1),
        }
    # DMO layout (EN 300 396-2 §9.4.3): shorter address fields, no MCC
    return {
        'Mode':           'DMO',
        'Sync_PDU_type':  sync_type,
        'SystemCode':     sync_type,
        'ColourCode':     extract_bits(bits60, 4, 6),
        'TimeSlot':       extract_bits(bits60, 10, 2),
        'Frame':          extract_bits(bits60, 12, 5),
        'AirInterfaceEnc': extract_bits(bits60, 17, 2),
        'MNI':            extract_bits(bits60, 19, 24),   # DMO Mobile Network Identity
        'SourceAddress':  extract_bits(bits60, 43, 17),
    }


def sync_to_air(sysinfo):
    """Return (air_tn, air_fn, air_mn) from SYNC PDU (0-based, raw from wire)."""
    return sysinfo.get('TimeSlot', 0), sysinfo.get('Frame', 0), sysinfo.get('MultiFrame', 0)


# =============================================================================
# MAC PDU parser (mirrors DLL TmoParseMacPDU)
# =============================================================================

MAC_PDU_NAMES = {0: 'MAC-RESOURCE', 1: 'MAC-FRAG/END', 2: 'MAC-BROADCAST', 3: 'MAC-U-SIGNAL'}

def parse_mac_pdu(bits, length_bits):
    """Parse TMO MAC PDU. Returns dict with parsed fields."""
    if len(bits) < 4:
        return {'type': 'TOO_SHORT'}

    pos = 0
    pdu_type = extract_bits(bits, pos, 2); pos += 2
    result = {
        'type': pdu_type,
        'type_name': MAC_PDU_NAMES.get(pdu_type, '?'),
    }

    if pdu_type == 0:  # MAC-RESOURCE
        result.update(_parse_mac_resource(bits, pos))
    elif pdu_type == 1:  # MAC-FRAG or MAC-END
        result.update(_parse_mac_frag_end(bits, pos))
    elif pdu_type == 2:  # MAC-BROADCAST
        result.update(_parse_mac_broadcast(bits, pos))
    elif pdu_type == 3:  # MAC-U-SIGNAL
        result.update(_parse_mac_u_signal(bits, pos))

    return result


def _parse_mac_u_signal(bits, pos):
    """MAC-U-SIGNAL (type 11) — EN 300 392-2 §21.4.6.
    Carries supplementary signalling on otherwise-allocated slots."""
    r = {}
    if pos + 1 > len(bits): return r
    r['fill_bit'] = extract_bits(bits, pos, 1); pos += 1

    if pos + 2 > len(bits): return r
    r['encryption_mode'] = extract_bits(bits, pos, 2); pos += 2

    if pos + 6 > len(bits): return r
    r['length_indicator'] = extract_bits(bits, pos, 6); pos += 6
    r['length_indicator_meaning'] = _length_indicator_meaning(r['length_indicator'])

    if pos + 3 > len(bits): return r
    addr_type = extract_bits(bits, pos, 3); pos += 3
    r['address_type'] = addr_type
    ADDR_NAMES = {0: 'NULL', 1: 'SSI', 2: 'Event Label', 3: 'USSI',
                  4: 'SMI', 5: 'SSI+Event', 6: 'SSI+Usage', 7: 'SMI+Event'}
    r['address_type_name'] = ADDR_NAMES.get(addr_type, '?')

    if addr_type in (1, 3) and pos + 24 <= len(bits):
        r['SSI'] = extract_bits(bits, pos, 24); pos += 24
    elif addr_type == 2 and pos + 10 <= len(bits):
        r['event_label'] = extract_bits(bits, pos, 10); pos += 10

    r['payload_start'] = pos
    return r


def _parse_mac_resource(bits, pos):
    """MAC-RESOURCE (type 00) — EN 300 392-2 §21.4.3"""
    r = {}
    if pos + 1 > len(bits): return r
    fill_bit = extract_bits(bits, pos, 1); pos += 1
    r['fill_bit'] = fill_bit

    if pos + 1 > len(bits): return r
    position_of_grant = extract_bits(bits, pos, 1); pos += 1
    r['position_of_grant'] = position_of_grant

    if pos + 2 > len(bits): return r
    encryption_mode = extract_bits(bits, pos, 2); pos += 2
    r['encryption_mode'] = encryption_mode

    if pos + 1 > len(bits): return r
    random_access_flag = extract_bits(bits, pos, 1); pos += 1
    r['random_access_flag'] = random_access_flag

    if pos + 6 > len(bits): return r
    length_indicator = extract_bits(bits, pos, 6); pos += 6
    r['length_indicator'] = length_indicator
    r['length_indicator_meaning'] = _length_indicator_meaning(length_indicator)

    if pos + 3 > len(bits): return r
    addr_type = extract_bits(bits, pos, 3); pos += 3
    r['address_type'] = addr_type

    ADDR_NAMES = {0: 'NULL', 1: 'SSI', 2: 'Event Label', 3: 'USSI',
                  4: 'SMI', 5: 'SSI+Event', 6: 'SSI+Usage', 7: 'SMI+Event'}
    r['address_type_name'] = ADDR_NAMES.get(addr_type, '?')

    # Parse address based on type
    if addr_type == 0:
        r['address'] = 'NULL (filler PDU)'
    elif addr_type == 1:   # SSI
        if pos + 24 <= len(bits):
            r['SSI'] = extract_bits(bits, pos, 24); pos += 24
    elif addr_type == 2:   # Event label
        if pos + 10 <= len(bits):
            r['event_label'] = extract_bits(bits, pos, 10); pos += 10
    elif addr_type == 3:   # USSI
        if pos + 24 <= len(bits):
            r['USSI'] = extract_bits(bits, pos, 24); pos += 24
    elif addr_type == 4:   # SMI
        if pos + 48 <= len(bits):
            r['SMI'] = extract_bits(bits, pos, 48); pos += 48
    elif addr_type == 5:   # SSI + event label
        if pos + 24 <= len(bits):
            r['SSI'] = extract_bits(bits, pos, 24); pos += 24
        if pos + 10 <= len(bits):
            r['event_label'] = extract_bits(bits, pos, 10); pos += 10
    elif addr_type == 6:   # SSI + usage marker
        if pos + 24 <= len(bits):
            r['SSI'] = extract_bits(bits, pos, 24); pos += 24
        if pos + 6 <= len(bits):
            r['usage_marker'] = extract_bits(bits, pos, 6); pos += 6
    elif addr_type == 7:   # SMI + event label
        if pos + 48 <= len(bits):
            r['SMI'] = extract_bits(bits, pos, 48); pos += 48
        if pos + 10 <= len(bits):
            r['event_label'] = extract_bits(bits, pos, 10); pos += 10

    # NULL filler PDU: fill=1, addr=0, LI=0
    if fill_bit == 1 and addr_type == 0:
        r['is_null_pdu'] = True

    # For every non-NULL MAC-RESOURCE, three 1-bit flags follow the address:
    #   power_control_flag, slot_granting_flag, chan_alloc_flag.
    # Their optional elements follow only if the corresponding flag is set.
    # This matches BlueStation's MacResource parser and the RTL builder, both of
    # which use a minimum non-null header length of 43 bits (40-bit base + 3
    # mandatory flags). Tying these flags to pos_of_grant was wrong and shifts
    # the LLC boundary by 3 bits for ordinary addressed resources.
    if addr_type != 0 and pos + 1 <= len(bits):
        pwr_flag = extract_bits(bits, pos, 1); pos += 1
        r['power_control_flag'] = pwr_flag
        if pwr_flag == 1 and pos + 4 <= len(bits):
            r['power_control_element'] = extract_bits(bits, pos, 4); pos += 4

        if pos + 1 <= len(bits):
            slot_grant_flag = extract_bits(bits, pos, 1); pos += 1
            r['slot_granting_flag'] = slot_grant_flag
            if slot_grant_flag == 1 and pos + 8 <= len(bits):
                r['slot_granting'] = extract_bits(bits, pos, 8); pos += 8

        if pos + 1 <= len(bits):
            chan_alloc_flag = extract_bits(bits, pos, 1); pos += 1
            r['channel_allocation_flag'] = chan_alloc_flag
            if chan_alloc_flag == 1:
                ca, pos = _parse_channel_allocation(bits, pos)
                r['channel_allocation'] = ca

    r['payload_start'] = pos
    return r


def _parse_channel_allocation(bits, pos):
    """Channel Allocation Element — EN 300 392-2 §21.5.2 Table 21.73.
    Returns (dict, new_pos)."""
    ca = {}
    if pos + 2 > len(bits): return ca, pos
    alloc_type = extract_bits(bits, pos, 2); pos += 2
    ALLOC_NAMES = {0: 'Replace', 1: 'Add', 2: 'Keep', 3: 'Reserved'}
    ca['allocation_type'] = alloc_type
    ca['allocation_type_name'] = ALLOC_NAMES.get(alloc_type, '?')

    if pos + 4 > len(bits): return ca, pos
    ca['timeslot_assigned'] = extract_bits(bits, pos, 4); pos += 4

    if pos + 2 > len(bits): return ca, pos
    updn = extract_bits(bits, pos, 2); pos += 2
    UPDN_NAMES = {0: 'UL+DL', 1: 'DL only', 2: 'UL only', 3: 'Reserved'}
    ca['uplink_downlink_assigned'] = updn
    ca['uplink_downlink_assigned_name'] = UPDN_NAMES.get(updn, '?')

    if pos + 1 > len(bits): return ca, pos
    ca['clch_permission'] = extract_bits(bits, pos, 1); pos += 1

    if pos + 1 > len(bits): return ca, pos
    ca['cell_change_flag'] = extract_bits(bits, pos, 1); pos += 1

    if pos + 12 > len(bits): return ca, pos
    ca['carrier_number'] = extract_bits(bits, pos, 12); pos += 12

    if pos + 1 > len(bits): return ca, pos
    ext_flag = extract_bits(bits, pos, 1); pos += 1
    ca['extended_carrier_flag'] = ext_flag
    if ext_flag == 1 and pos + 10 <= len(bits):
        ca['frequency_band']    = extract_bits(bits, pos, 4); pos += 4
        ca['offset']            = extract_bits(bits, pos, 2); pos += 2
        ca['duplex_spacing']    = extract_bits(bits, pos, 3); pos += 3
        ca['reverse_operation'] = extract_bits(bits, pos, 1); pos += 1

    if pos + 2 > len(bits): return ca, pos
    ca['monitoring_pattern'] = extract_bits(bits, pos, 2); pos += 2

    # Frame 18 monitoring pattern (only if monitoring_pattern == 00)
    if ca['monitoring_pattern'] == 0 and pos + 2 <= len(bits):
        ca['frame18_monitoring_pattern'] = extract_bits(bits, pos, 2); pos += 2

    return ca, pos


def _parse_mac_frag_end(bits, pos):
    """MAC-FRAG/END (type 01)"""
    r = {}
    if pos + 1 > len(bits): return r
    sub_type = extract_bits(bits, pos, 1); pos += 1
    r['sub_type'] = 'MAC-END' if sub_type else 'MAC-FRAG'

    if pos + 1 > len(bits): return r
    r['fill_bit'] = extract_bits(bits, pos, 1); pos += 1

    r['payload_start'] = pos
    return r


def _parse_mac_broadcast(bits, pos):
    """MAC-BROADCAST (type 10) — EN 300 392-2 §21.4.7"""
    r = {}
    if pos + 2 > len(bits): return r
    sub_type = extract_bits(bits, pos, 2); pos += 2
    BC_NAMES = {0: 'SYSINFO', 1: 'ACCESS-DEFINE', 2: 'SYSINFO+ACCESS-DEFINE', 3: 'Reserved'}
    r['sub_type'] = sub_type
    r['sub_type_name'] = BC_NAMES.get(sub_type, '?')

    # Note: SYSINFO and ACCESS-DEFINE do NOT share the same header layout.
    # Parse each based on sub_type.
    if sub_type == 0:
        r['sysinfo'], pos = _parse_sysinfo_type2(bits, pos)
    elif sub_type == 1:
        r['access_define'], pos = _parse_access_define(bits, pos)
    elif sub_type == 2:
        # Combined: SYSINFO first, then ACCESS-DEFINE
        r['sysinfo'], pos = _parse_sysinfo_type2(bits, pos)
        r['access_define'], pos = _parse_access_define(bits, pos)

    r['payload_start'] = pos
    return r


def _parse_access_define(bits, pos):
    """ACCESS-DEFINE PDU — EN 300 392-2 §21.4.4 Table 21.18.
    Returns (dict, new_pos)."""
    a = {}
    if pos + 1 > len(bits): return a, pos
    a['common_or_assigned'] = extract_bits(bits, pos, 1); pos += 1

    if pos + 2 > len(bits): return a, pos
    a['access_code'] = extract_bits(bits, pos, 2); pos += 2

    if pos + 4 > len(bits): return a, pos
    a['imm']  = extract_bits(bits, pos, 4); pos += 4
    if pos + 4 > len(bits): return a, pos
    a['wt']   = extract_bits(bits, pos, 4); pos += 4
    if pos + 4 > len(bits): return a, pos
    a['nu']   = extract_bits(bits, pos, 4); pos += 4

    if pos + 1 > len(bits): return a, pos
    a['frame_length_factor'] = extract_bits(bits, pos, 1); pos += 1
    if pos + 4 > len(bits): return a, pos
    a['timeslot_pointer'] = extract_bits(bits, pos, 4); pos += 4
    if pos + 3 > len(bits): return a, pos
    a['min_pdu_priority'] = extract_bits(bits, pos, 3); pos += 3

    if pos + 1 > len(bits): return a, pos
    opt_flag = extract_bits(bits, pos, 1); pos += 1
    a['optional_field_flag'] = opt_flag
    if opt_flag == 1 and pos + 4 <= len(bits):
        opt_type = extract_bits(bits, pos, 4); pos += 4
        a['optional_field_type'] = opt_type
        # Subscriber class / bandwidth follow — size varies by type
        if opt_type == 0 and pos + 16 <= len(bits):   # subscriber class
            a['subscriber_class'] = extract_bits(bits, pos, 16); pos += 16
        elif opt_type == 1 and pos + 24 <= len(bits): # GSSI
            a['GSSI'] = extract_bits(bits, pos, 24); pos += 24

    return a, pos


def _parse_sysinfo_type2(bits, pos):
    """D-MLE-SYSINFO from BNCH (124 or 268 info bits).
    Returns (dict, new_pos)."""
    s = {}
    if pos + 12 > len(bits): return s, pos
    s['Main_Carrier'] = extract_bits(bits, pos, 12); pos += 12

    if pos + 4 > len(bits): return s, pos
    s['Frequency_Band'] = extract_bits(bits, pos, 4); pos += 4

    if pos + 2 > len(bits): return s, pos
    s['Offset'] = extract_bits(bits, pos, 2); pos += 2

    if pos + 3 > len(bits): return s, pos
    s['Duplex_Spacing'] = extract_bits(bits, pos, 3); pos += 3

    if pos + 1 > len(bits): return s, pos
    s['Reverse_Operation'] = extract_bits(bits, pos, 1); pos += 1

    # DL frequency (Hz) from carrier+band+offset
    s['DL_Frequency_Hz'] = frequency_calc(
        s['Main_Carrier'], s['Frequency_Band'], s['Offset'])

    if pos + 2 > len(bits): return s, pos
    s['Num_SC'] = extract_bits(bits, pos, 2); pos += 2

    if pos + 3 > len(bits): return s, pos
    s['MS_TXPwr_Max'] = extract_bits(bits, pos, 3); pos += 3

    if pos + 4 > len(bits): return s, pos
    s['RXLevel_Access_Min'] = extract_bits(bits, pos, 4); pos += 4

    if pos + 4 > len(bits): return s, pos
    s['Access_Parameter'] = extract_bits(bits, pos, 4); pos += 4

    if pos + 4 > len(bits): return s, pos
    s['Radio_DL_Timeout'] = extract_bits(bits, pos, 4); pos += 4

    if pos + 1 > len(bits): return s, pos
    hyper_cipher = extract_bits(bits, pos, 1); pos += 1
    s['Hyper_Cipher_Flag'] = hyper_cipher

    if pos + 16 > len(bits): return s, pos
    if hyper_cipher == 0:
        s['Hyperframe'] = extract_bits(bits, pos, 16); pos += 16
    else:
        s['CCK_ID'] = extract_bits(bits, pos, 16); pos += 16

    # ETSI §21.4.4.2 D-MLE-SYSINFO (matches tetra-kit mac.cc:1098):
    # Optional field flag (2) + Option value (20, always present) +
    # Location Area (14, always present).
    if pos + 2 > len(bits): return s, pos
    opt_field = extract_bits(bits, pos, 2); pos += 2
    s['Optional_Field'] = opt_field

    if pos + 20 > len(bits): return s, pos
    s['Optional_Field_Value'] = extract_bits(bits, pos, 20); pos += 20

    if pos + 14 > len(bits): return s, pos
    s['Location_Area'] = extract_bits(bits, pos, 14); pos += 14

    return s, pos


def _length_indicator_meaning(li):
    if li == 0:
        return 'NULL PDU (no TM-SDU)'
    elif 1 <= li <= 62:
        return f'{li} octets'
    elif li == 63:
        return 'second half-slot stolen'
    return '?'


# =============================================================================
# LLC parser (basic, mirrors DLL LlcLevel.Parse)
# =============================================================================

LLC_PDU_NAMES = {
    0: 'BL-ADATA', 1: 'BL-DATA', 2: 'BL-UDATA', 3: 'BL-ACK',
    4: 'BL-ADATA+FCS', 5: 'BL-DATA+FCS', 6: 'BL-UDATA+FCS', 7: 'BL-ACK+FCS',
    8: 'AL-SETUP', 9: 'AL-DATA/AR/FINAL', 10: 'AL-UDATA/UFINAL',
    11: 'AL-ACK/RNR', 12: 'AL-RECONNECT', 13: 'SUPP-LLC',
    14: 'L2SigPdu', 15: 'AL-DISC',
}

def parse_llc(bits, pos):
    """Parse LLC PDU header. Returns dict with type, payload offset, and FCS status."""
    if pos + 4 > len(bits):
        return {'llc_type': 'TOO_SHORT'}
    header_start = pos
    pdu_type = extract_bits(bits, pos, 4); pos += 4
    r = {
        'llc_type': pdu_type,
        'llc_type_name': LLC_PDU_NAMES.get(pdu_type, f'Unknown({pdu_type})'),
    }

    if pdu_type == 2:  # BL-UDATA
        r['payload_start'] = pos
    elif pdu_type == 0:  # BL-ADATA
        if pos + 1 <= len(bits):
            r['nr'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            r['ns'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_start'] = pos
    elif pdu_type == 1:  # BL-DATA
        if pos + 1 <= len(bits):
            r['ns'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_start'] = pos
    elif pdu_type == 3:  # BL-ACK
        if pos + 1 <= len(bits):
            r['nr'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_start'] = pos
    elif pdu_type == 14:  # L2SigPdu / direct MM signalling
        r['payload_start'] = pos
        r['direct_mm'] = True
    elif pdu_type in (4, 5, 6, 7):  # BL-*_FCS — CRC-32 over LLC PDU (header + payload)
        # Header layout identical to non-FCS variants
        if pdu_type == 4:   # BL-ADATA+FCS
            if pos + 1 <= len(bits): r['nr'] = extract_bits(bits, pos, 1); pos += 1
            if pos + 1 <= len(bits): r['ns'] = extract_bits(bits, pos, 1); pos += 1
        elif pdu_type == 5:  # BL-DATA+FCS
            if pos + 1 <= len(bits): r['ns'] = extract_bits(bits, pos, 1); pos += 1
        elif pdu_type == 7:  # BL-ACK+FCS
            if pos + 1 <= len(bits): r['nr'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_start'] = pos
        r['has_fcs'] = True

    # Validate FCS if present: CRC-32 over LLC PDU (header + payload), residual = GoodFCS
    if r.get('has_fcs') and len(bits) - header_start >= 32:
        r['fcs_ok'] = crc32_check_llc(bits[header_start:])

    return r


# =============================================================================
# MLE parser (basic)
# =============================================================================

MLE_PDU_NAMES = {
    0: 'Reserved', 1: 'MM', 2: 'CMCE', 3: 'Reserved',
    4: 'SNDCP', 5: 'MLE', 6: 'TETRA-Mgmt', 7: 'Testing',
}
CMCE_NAMES = {
    0: 'D-ALERT', 1: 'D-CALL-PROCEEDING', 2: 'D-CONNECT', 3: 'D-CONNECT-ACK',
    4: 'D-DISCONNECT', 5: 'D-INFO', 6: 'D-RELEASE', 7: 'D-SETUP',
    8: 'D-STATUS', 9: 'D-TX-CEASED', 10: 'D-TX-CONTINUE', 11: 'D-TX-GRANTED',
    12: 'D-TX-WAIT', 13: 'D-TX-INTERRUPT', 14: 'D-CALL-RESTORE',
    15: 'D-SDS-DATA', 16: 'D-FACILITY', 31: 'NOT-SUPPORTED',
}
MM_NAMES = {
    0: 'D-OTAR', 1: 'D-AUTH', 2: 'D-CK-CHG-DEMAND', 3: 'D-DISABLE',
    4: 'D-ENABLE', 5: 'D-LOC-UPD-ACCEPT', 6: 'D-LOC-UPD-CMD',
    7: 'D-LOC-UPD-REJ', 8: 'Reserved', 9: 'D-LOC-UPD-PROC',
    10: 'D-ATTACH-DETACH-GRP-ID', 11: 'D-ATTACH-DETACH-GRP-ID-ACK',
    12: 'D-MM-STATUS',
}

LOC_UPD_ACCEPT_NAMES = {
    0: 'Roaming',
    1: 'Migrating',
    2: 'Periodic',
    3: 'ITSI-Attach',
    4: 'Call-Restoration',
}


def parse_mm_pdu(bits, pos, mm_type):
    """Parse selected MM PDU bodies deeply enough for registration tracing."""
    r = {}

    if mm_type == 5:  # D-LOCATION UPDATE ACCEPT
        if pos + 3 > len(bits):
            return r
        upd_type = extract_bits(bits, pos, 3); pos += 3
        r['location_update_accept_type'] = upd_type
        r['location_update_accept_type_name'] = LOC_UPD_ACCEPT_NAMES.get(upd_type, f'Unknown({upd_type})')
        if pos + 1 > len(bits):
            return r
        o_bit = extract_bits(bits, pos, 1); pos += 1
        r['optional_fields_present'] = o_bit
        if o_bit == 1:
            if pos + 1 <= len(bits):
                p_ssi = extract_bits(bits, pos, 1); pos += 1
                r['ssi_present'] = p_ssi
                if p_ssi == 1 and pos + 24 <= len(bits):
                    r['ssi'] = extract_bits(bits, pos, 24); pos += 24
            if pos + 1 <= len(bits):
                p_addr_ext = extract_bits(bits, pos, 1); pos += 1
                r['address_extension_present'] = p_addr_ext
                if p_addr_ext == 1 and pos + 24 <= len(bits):
                    r['address_extension'] = extract_bits(bits, pos, 24); pos += 24
            if pos + 1 <= len(bits):
                p_subcls = extract_bits(bits, pos, 1); pos += 1
                r['subscriber_class_present'] = p_subcls
                if p_subcls == 1 and pos + 16 <= len(bits):
                    r['subscriber_class'] = extract_bits(bits, pos, 16); pos += 16
            if pos + 1 <= len(bits):
                p_esi = extract_bits(bits, pos, 1); pos += 1
                r['energy_saving_info_present'] = p_esi
                if p_esi == 1 and pos + 14 <= len(bits):
                    r['energy_saving_info'] = extract_bits(bits, pos, 14); pos += 14
            if pos + 1 <= len(bits):
                p_scch = extract_bits(bits, pos, 1); pos += 1
                r['frame18_scch_info_present'] = p_scch
                if p_scch == 1 and pos + 6 <= len(bits):
                    r['frame18_scch_info'] = extract_bits(bits, pos, 6); pos += 6
            if pos + 1 <= len(bits):
                more = extract_bits(bits, pos, 1); pos += 1
                r['more_optional_bits'] = more
                if more == 1 and pos + 15 <= len(bits):
                    r['type3_field_id'] = extract_bits(bits, pos, 4); pos += 4
                    r['type3_payload_len'] = extract_bits(bits, pos, 11); pos += 11
        r['payload_end'] = pos
        return r

    if mm_type == 9:  # D-LOCATION UPDATE PROCEEDING
        if pos + 3 <= len(bits):
            upd_type = extract_bits(bits, pos, 3); pos += 3
            r['location_update_type'] = upd_type
            r['location_update_type_name'] = LOC_UPD_ACCEPT_NAMES.get(upd_type, f'Unknown({upd_type})')
        r['payload_end'] = pos
        return r

    if mm_type == 7:  # D-LOCATION UPDATE REJECT
        if pos + 5 <= len(bits):
            r['reject_cause'] = extract_bits(bits, pos, 5); pos += 5
        r['payload_end'] = pos
        return r

    if mm_type == 11:  # D-ATTACH/DETACH GROUP ID ACK
        if pos + 1 <= len(bits):
            r['group_identity_accept_reject'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            r['optional_fields_present'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_end'] = pos
        return r

    if mm_type == 10:  # D-ATTACH/DETACH GROUP ID
        if pos + 1 <= len(bits):
            r['detach_all_flag'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            r['group_identity_report'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_end'] = pos
        return r

    if mm_type == 12:  # D-MM-STATUS
        if pos + 5 <= len(bits):
            r['status_value'] = extract_bits(bits, pos, 5); pos += 5
        r['payload_end'] = pos
        return r

    return r

def parse_mle(bits, pos):
    """Parse MLE discriminator + CMCE/MM header."""
    if pos + 3 > len(bits):
        return {'mle_type': 'TOO_SHORT'}
    disc = extract_bits(bits, pos, 3); pos += 3
    r = {
        'mle_disc': disc,
        'mle_disc_name': MLE_PDU_NAMES.get(disc, '?'),
    }

    if disc == 2:  # CMCE
        if pos + 5 <= len(bits):
            cmce_type = extract_bits(bits, pos, 5); pos += 5
            r['cmce_type'] = cmce_type
            r['cmce_name'] = CMCE_NAMES.get(cmce_type, f'Unknown({cmce_type})')
    elif disc == 1:  # MM
        if pos + 4 <= len(bits):
            mm_type = extract_bits(bits, pos, 4); pos += 4
            r['mm_type'] = mm_type
            r['mm_name'] = MM_NAMES.get(mm_type, f'Unknown({mm_type})')
            r['mm'] = parse_mm_pdu(bits, pos, mm_type)
    elif disc == 5:  # MLE protocol
        if pos + 3 <= len(bits):
            mle_type = extract_bits(bits, pos, 3); pos += 3
            MLE_PRIM = {0: 'D-NEW-CELL', 1: 'D-PREPARE', 2: 'D-NWRK-BROADCAST',
                        4: 'D-RESTORE-ACK', 5: 'D-RESTORE-FAIL'}
            r['mle_prim'] = mle_type
            r['mle_prim_name'] = MLE_PRIM.get(mle_type, f'Unknown({mle_type})')

    r['payload_start'] = pos
    return r


def parse_direct_mm(bits, pos):
    """Parse direct-MM over LLC L2SigPdu (no MLE discriminator)."""
    r = {}
    if pos + 4 > len(bits):
        return r
    mm_type = extract_bits(bits, pos, 4); pos += 4
    r['mm_type'] = mm_type
    r['mm_name'] = MM_NAMES.get(mm_type, f'Unknown({mm_type})')
    r['mm'] = parse_mm_pdu(bits, pos, mm_type)
    r['payload_start'] = pos
    return r


# =============================================================================
# IQ loading
# =============================================================================

def load_iq_file(filename, swap_iq=False):
    if filename.lower().endswith('.wav'):
        with wave.open(filename, 'rb') as wf:
            n_ch = wf.getnchannels()
            sw = wf.getsampwidth()
            sr = wf.getframerate()
            frames = wf.readframes(wf.getnframes())
        if n_ch < 2:
            raise ValueError("WAV must be stereo I/Q")
        if sw == 1:
            raw = np.frombuffer(frames, dtype=np.uint8).astype(np.float64)
            raw = (raw - 127.5) / 127.5
        elif sw == 2:
            raw = np.frombuffer(frames, dtype=np.int16).astype(np.float64) / 32768.0
        else:
            raw = np.frombuffer(frames, dtype=np.int32).astype(np.float64) / 2147483648.0
        raw = raw.reshape(-1, n_ch)
        i_idx, q_idx = (1, 0) if swap_iq else (0, 1)
        iq = raw[:, i_idx] + 1j * raw[:, q_idx]
        return iq, sr
    else:
        raw = np.fromfile(filename, dtype=np.uint8)
        iq = (raw[0::2].astype(np.float64) - 127.5) / 127.5 + \
            1j * (raw[1::2].astype(np.float64) - 127.5) / 127.5
        return iq, None


def estimate_freq_offset(iq, sample_rate):
    nfft = 8192
    spec = np.abs(fft(iq[:nfft] * np.hanning(nfft))) ** 2
    freqs = np.fft.fftfreq(nfft, 1 / sample_rate)
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
# Burst extraction helpers
# =============================================================================

def extract_burst_symbols(iq, sts_offset, sps, ts_sym_offset):
    """Extract 255 symbols from IQ, given training seq sample position
    and the symbol offset of the training seq within the burst."""
    burst_start = sts_offset - int(ts_sym_offset * sps)
    if burst_start < 0:
        return None, None
    burst_end = burst_start + int(BURST_SYMBOLS * sps)
    if burst_end > len(iq):
        return None, None
    sym_indices = np.round(np.arange(BURST_SYMBOLS) * sps + burst_start).astype(int)
    sym_indices = np.clip(sym_indices, 0, len(iq) - 1)
    return iq[sym_indices], burst_start


def refine_timing(iq, ts_offset, sps, ref_dibits, ref_diff):
    """Sub-sample timing refinement around a training seq position."""
    best_t = 0.0
    best_c = 0.0
    for dt in np.linspace(-1.0, 1.0, 41):
        c = _correlate_at(iq, ts_offset + dt, sps, ref_dibits, ref_diff)
        if c > best_c:
            best_c = c
            best_t = dt
    return best_t, best_c


# =============================================================================
# Main decoder
# =============================================================================

def decode_dl(filename, sample_rate=2048000, freq_offset=0.0,
              max_bursts=200, conjugate=False, swap_iq=False, verbose=False,
              dump_burst=-1):
    print("=" * 60)
    print(" TETRA Downlink Decoder — Full MAC/LLC/MLE")
    print("=" * 60)
    print(f"File: {filename}")

    iq, detected_rate = load_iq_file(filename, swap_iq=swap_iq)
    if detected_rate is not None:
        sample_rate = detected_rate
    print(f"Sample rate: {sample_rate} Hz")
    print(f"Samples: {len(iq)} ({len(iq)/sample_rate:.3f}s)")

    if conjugate:
        iq = np.conj(iq)

    # Freq correction
    if freq_offset == 0:
        freq_offset = estimate_freq_offset(iq, sample_rate)
        print(f"Auto freq offset: {freq_offset:+.1f} Hz")
    if abs(freq_offset) > 10:
        t = np.arange(len(iq)) / sample_rate
        iq = iq * np.exp(-1j * 2 * np.pi * freq_offset * t)

    # Decimate
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
        iq = np.convolve(iq, h, mode='same')[::decim]
    print(f"Decimated: {decim}x → {actual_rate:.0f} Hz, {sps:.2f} sps")

    # RRC filter
    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = rrc_filter(rrc_ntaps, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')

    # --- Cell acquisition: find STS peaks, try to decode each until CRC OK ---
    print("\nCell acquisition...")
    n = len(iq)
    burst_spacing = BURST_SYMBOLS * sps  # float — no int truncation!
    step = max(1, int(sps / 2))

    # Scan for all STS peaks
    scan_limit = min(n - int(BURST_SYMBOLS * sps), n)
    sts_peaks = []
    for offset in range(0, scan_limit, step):
        c = _correlate_at(iq, offset, sps, STS_DIBITS, STS_DIFF_REF)
        if c >= 0.35:
            sts_peaks.append((offset, c))

    # Deduplicate
    sts_peaks.sort(key=lambda x: -x[1])
    deduped = []
    for off, c in sts_peaks:
        if all(abs(off - po) >= burst_spacing // 2 for po, _ in deduped):
            deduped.append((off, c))
        if len(deduped) >= 50:
            break
    print(f"  Found {len(deduped)} STS candidates (best corr={deduped[0][1]:.3f})")

    # Try both layouts against top candidates.
    # SDB (continuous) first: SB1 sample position is identical for both layouts
    # (both put SB1 60 sym before STS), but `sb_off_sts` is used to anchor the
    # NDB burst grid. Using NSB's sb_off_sts=85 on a continuous cell offsets all
    # NDB decoding by 22 sym → NTS correlation drops to ~0.6 instead of ~0.95.
    LAYOUTS = [
        ('continuous',     SDB_OFF_SB1, SDB_OFF_STS, SDB_OFF_BB, SDB_OFF_BKN2),
        ('non-continuous', NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2),
    ]

    scramb_code = None
    mcc = mnc = cc = 0
    acq_sts_pos = None
    sb_off_sb1 = sb_off_sts = sb_off_bb = sb_off_bkn2 = 0
    layout = 'unknown'

    for sts_off, sts_corr in deduped:
        for lname, l_sb1, l_sts, l_bb, l_bkn2 in LAYOUTS:
            # Refine timing
            best_t = 0.0
            best_c = 0.0
            for dt in np.linspace(-1.0, 1.0, 41):
                c = _correlate_at(iq, sts_off + dt, sps, STS_DIBITS, STS_DIFF_REF)
                if c > best_c:
                    best_c = c
                    best_t = dt

            # Extract burst
            burst_start = sts_off + best_t - l_sts * sps
            sym_idx = np.round(np.arange(BURST_SYMBOLS) * sps + burst_start).astype(int)
            if sym_idx[-1] >= len(iq) or sym_idx[0] < 0:
                continue
            sym_idx = np.clip(sym_idx, 0, len(iq) - 1)
            bsyms = iq[sym_idx]

            # Phase correction from STS
            sts_ref = dibits_to_symbols(STS_DIBITS)
            sts_dr = sts_ref[1:] * np.conj(sts_ref[:-1])
            s_idx = np.arange(len(STS_DIBITS)) + l_sts
            s_idx = np.clip(s_idx, 0, BURST_SYMBOLS - 1)
            ss = bsyms[s_idx]
            sd = ss[1:] * np.conj(ss[:-1])
            pe = np.angle(sd * np.conj(sts_dr))
            if len(pe) > 1:
                sl, ic = np.polyfit(np.arange(len(pe)), pe, 1)
                nr = np.arange(BURST_SYMBOLS, dtype=np.float64) - float(l_sts)
                bsyms = bsyms * np.exp(-1j * (ic * nr + 0.5 * sl * nr * (nr - 1.0)))

            db = demod_pi4dqpsk(bsyms)
            sb1_s = l_sb1 - 1
            if sb1_s < 0 or sb1_s + SDB_SB1 > len(db):
                continue
            sb1_b = dibits_to_bits(db[sb1_s : sb1_s + SDB_SB1])
            sb1_d = (sb1_b ^ scrambler_seq(3, 120)) & 1
            ok, info, _ = decode_channel(sb1_d, 120, 11, 60)
            if ok:
                si = parse_sysinfo_sb(info)
                mode = si.get('Mode', 'TMO')
                if mode == 'TMO':
                    mcc = si['MCC']; mnc = si['MNC']; cc = si['ColourCode']
                    scramb_code = make_scramb_code(mcc, mnc, cc)
                else:
                    # DMO: scrambler uses (MNC<<26)|(SourceAddress<<2)|3
                    mcc = 0; mnc = si.get('MNI', 0) & 0x3F; cc = si['ColourCode']
                    scramb_code = make_scramb_code_dmo(mnc, si.get('SourceAddress', 0))
                sb_off_sb1 = l_sb1; sb_off_sts = l_sts
                sb_off_bb = l_bb; sb_off_bkn2 = l_bkn2
                layout = lname
                acq_sts_pos = sts_off + best_t
                air_tn, air_fn, air_mn = sync_to_air(si)
                print(f"  LOCKED [{lname} {mode}] MCC={mcc} MNC={mnc} CC={cc} "
                      f"TN(air)={air_tn} FN(air)={air_fn} MN(air)={air_mn}")
                print(f"  scrambCode=0x{scramb_code:08X}")
                break
        if scramb_code is not None:
            break

    if scramb_code is None:
        print("  Failed to acquire cell — no SB decoded successfully")
        return False

    # Build burst grid from acquisition STS — track STS positions (float)
    acq_sts_float = float(acq_sts_pos)
    sts_pos_anchor = acq_sts_float

    # Walk backwards/forwards to cover file
    sts_positions = []  # float STS sample positions
    pos = sts_pos_anchor
    while pos - burst_spacing >= 0:
        pos -= burst_spacing
    while pos < n - int(BURST_SYMBOLS * sps) and len(sts_positions) < max_bursts:
        sts_positions.append(pos)
        pos += burst_spacing
    print(f"  Grid: {len(sts_positions)} burst slots")

    # Helper: extract symbols + apply phase correction (matches decode_sb.py approach)
    def _extract_and_correct(burst_start_sample, ts_sym_offset, ts_dibits, ts_diff_ref,
                             timing_offset=0.0):
        """Extract 255 symbols and apply per-burst phase correction from training seq.
        burst_start_sample: float sample position of symbol 0.
        ts_sym_offset: symbol offset of training seq within burst.
        timing_offset: additional timing offset to apply (for retry).
        Returns (burst_syms_corrected, corr) or (None, 0)."""
        bs = burst_start_sample
        burst_end = bs + BURST_SYMBOLS * sps
        if bs < 0 or burst_end > n:
            return None, 0.0

        # Fine-tune timing: coarse search ±sps, then fine ±0.5
        ts_pos_pred = bs + ts_sym_offset * sps + timing_offset
        best_timing = 0.0
        best_corr = 0.0
        # Coarse: step ~0.5 samples
        for dt in np.linspace(-sps, sps, int(4 * sps) + 1):
            c = _correlate_at(iq, ts_pos_pred + dt, sps, ts_dibits, ts_diff_ref)
            if c > best_corr:
                best_corr = c
                best_timing = dt
        # Fine: ±0.5 around coarse peak, step 0.05
        coarse_best = best_timing
        for dt in np.linspace(coarse_best - 0.5, coarse_best + 0.5, 21):
            c = _correlate_at(iq, ts_pos_pred + dt, sps, ts_dibits, ts_diff_ref)
            if c > best_corr:
                best_corr = c
                best_timing = dt

        # Recompute burst start with refined timing
        bs_refined = bs + best_timing + timing_offset
        if bs_refined < 0 or bs_refined + BURST_SYMBOLS * sps > n:
            return None, best_corr

        # Extract symbols
        sym_indices = np.round(np.arange(BURST_SYMBOLS) * sps + bs_refined).astype(int)
        sym_indices = np.clip(sym_indices, 0, n - 1)
        burst_syms = iq[sym_indices]

        # Phase correction from training seq.
        # Linear-only: the slope estimate is noisy with short training (NTS=11 sym → 10
        # differential samples), and the quadratic extrapolation blows up at the burst
        # edges (|nr|≈130), wrecking BLK1/BLK2 Viterbi even when AACH still decodes.
        # Using just the mean residual (ic) gives 100 % NDB decode on the Gold WAV.
        ts_ref = dibits_to_symbols(ts_dibits)
        ts_dr = ts_ref[1:] * np.conj(ts_ref[:-1])
        s_idx = np.arange(len(ts_dibits)) + ts_sym_offset
        s_idx = np.clip(s_idx, 0, BURST_SYMBOLS - 1)
        ss = burst_syms[s_idx]
        sd = ss[1:] * np.conj(ss[:-1])
        pe = np.angle(sd * np.conj(ts_dr))
        if len(pe) > 1:
            ic = float(np.mean(pe))
            nr = np.arange(BURST_SYMBOLS, dtype=np.float64) - float(ts_sym_offset)
            burst_syms = burst_syms * np.exp(-1j * ic * nr)

        return burst_syms, best_corr

    # Process bursts
    print("\n" + "=" * 60)
    print(" BURST DECODE LOG")
    print("=" * 60)

    n_sb_ok = 0
    n_sb_fail = 0
    n_ndb_ok = 0
    n_ndb_fail = 0
    n_empty = 0

    # NetworkTime tracker — advanced after each slot. Initial sync from acquisition SB.
    nt = NetworkTime()
    nt.synchronize(air_tn, air_fn, air_mn)

    # MER/BER tracking (mirrors DLL Demodulator counters)
    bad_burst_counter = 0.0   # +0.5 per CRC fail, +1.0 per missing burst
    time_counter = 0
    ber_ema = 0.0
    BER_ALPHA = 0.99
    BER_BETA = 0.01

    # Helper: try SB1 decode with given burst symbols (soft-decision)
    def _try_sb1_decode(burst_syms):
        # Soft demod
        soft_bits = demod_pi4dqpsk_soft(burst_syms)
        sb1_s = (sb_off_sb1 - 1) * 2  # soft bits index (2 per dibit)
        if sb1_s < 0 or sb1_s + SDB_SB1 * 2 > len(soft_bits):
            return False, None, demod_pi4dqpsk(burst_syms)
        sb1_soft = soft_bits[sb1_s : sb1_s + SDB_SB1 * 2]
        # Soft descramble (BSCH init=3)
        sb1_soft = descramble_soft(sb1_soft, 3, 120)
        ok, info, _ = decode_channel_soft(sb1_soft, 120, 11, 60)
        return ok, info, demod_pi4dqpsk(burst_syms)

    if dump_burst == -2:
        # --dump-burst -2: dump (idx, sample_pos, time_s, type, tn, fn, mn) für jeden burst,
        # rest des Decodes wird übersprungen.  Genutzt für UL/DL-Time-Sync.
        print(f"# dump_pos sample_rate={sample_rate}")
        print(f"# columns: idx sample_pos time_s")
        for idx, grid_sts_pos in enumerate(sts_positions[:max_bursts]):
            t_s = grid_sts_pos / float(sample_rate)
            print(f"DUMPPOS {idx:>5d} {int(grid_sts_pos):>12d} {t_s:>10.4f}")
        return True

    for idx, grid_sts_pos in enumerate(sts_positions[:max_bursts]):
        burst_start_pred = grid_sts_pos - sb_off_sts * sps

        # Try SB first (STS at sb_off_sts)
        sb_syms, sb_corr = _extract_and_correct(
            burst_start_pred, sb_off_sts, STS_DIBITS, STS_DIFF_REF)

        # Try NDB (NTS1/NTS2 at NDB_OFF_NTS)
        ndb1_syms, ndb1_corr = _extract_and_correct(
            burst_start_pred, NDB_OFF_NTS, NTS1_DIBITS, NTS1_DIFF_REF)
        ndb2_syms, ndb2_corr = _extract_and_correct(
            burst_start_pred, NDB_OFF_NTS, NTS2_DIBITS, NTS2_DIFF_REF)

        # Classifier — mirrors SDRSharp.Tetra.dll Demodulator::ProcessBuffer § 4.6:
        #   if _stsMinSum >= 1.0 → BurstType.None (drop)
        #   else pick min(NDB1, NDB2, STS) sum-of-squared-errors
        # We use magnitude correlation (higher is better) so thresholds are
        # inverted: drop when the strongest correlator is below MIN_CORR.
        MIN_SB_CORR  = 0.50   # DLL equiv.: _stsMinSum < 1.0 on normalised STS match
        MIN_NDB_CORR = 0.40   # NDB uses 11-symbol NTS, noisier than 19-symbol STS
        candidates = []
        if sb_syms is not None and sb_corr >= MIN_SB_CORR:
            candidates.append((sb_corr, 'SB', sb_syms))
        if ndb1_syms is not None and ndb1_corr >= MIN_NDB_CORR:
            candidates.append((ndb1_corr, 'NDB1', ndb1_syms))
        if ndb2_syms is not None and ndb2_corr >= MIN_NDB_CORR:
            candidates.append((ndb2_corr, 'NDB2', ndb2_syms))
        if not candidates:
            n_empty += 1     # BurstType.None — slot below threshold, skip silently
            bad_burst_counter += 1.0   # DLL: missing burst = +1
            time_counter += 1
            if time_counter % 100 == 0:
                mer = 100.0 * bad_burst_counter / time_counter
                print(f"  [slot {nt}]  MER={mer:.1f}%  BER(EMA)={ber_ema:.4f}")
            nt.advance()
            continue
        corr, btype, burst_syms = max(candidates)

        # Classification-vs-predicted-slot sanity note
        slot_tag = f" [{nt}]"

        if btype == 'SB':
            # --- Sync Burst with retry ---
            sb1_crc, sb1_info, dibits = _try_sb1_decode(burst_syms)

            # Retry with timing jitter if CRC fails
            if not sb1_crc:
                for retry_dt in [-0.3, 0.3, -0.6, 0.6, -1.0, 1.0]:
                    retry_syms, retry_corr = _extract_and_correct(
                        burst_start_pred, sb_off_sts, STS_DIBITS, STS_DIFF_REF,
                        timing_offset=retry_dt)
                    if retry_syms is None:
                        continue
                    ok2, info2, db2 = _try_sb1_decode(retry_syms)
                    if ok2:
                        sb1_crc, sb1_info, dibits = ok2, info2, db2
                        burst_syms = retry_syms
                        corr = retry_corr
                        break

            print(f"\n[#{idx:3d}] SB  {slot_tag} corr={corr:.3f}  ", end='')

            if sb1_crc:
                n_sb_ok += 1
                si = parse_sysinfo_sb(sb1_info)
                mode = si.get('Mode', 'TMO')
                if mode == 'TMO':
                    mcc = si['MCC']; mnc = si['MNC']; cc = si['ColourCode']
                    scramb_code = make_scramb_code(mcc, mnc, cc)
                else:
                    mcc = 0; mnc = si.get('MNI', 0) & 0x3F; cc = si['ColourCode']
                    scramb_code = make_scramb_code_dmo(mnc, si.get('SourceAddress', 0))
                fn = si['Frame']
                air_tn, air_fn, air_mn = sync_to_air(si)
                # Re-sync NetworkTime from the air values (+1 inside)
                nt.synchronize(air_tn, air_fn, air_mn)
                mf_str = si['MultiFrame'] if mode == 'TMO' else 'n/a'
                print(f"SB1 CRC OK [{mode}] MCC={mcc} MNC={mnc} CC={cc} "
                      f"FN(air)={fn} MF(air)={mf_str} TN(air)={si['TimeSlot']} → {nt}")
            else:
                n_sb_fail += 1
                bad_burst_counter += 0.5
                print("SB1 CRC FAIL")
                time_counter += 1
                nt.advance()
                continue

            # BKN2 decode (124 info bits, K=216, a=101) — soft
            soft_bits = demod_pi4dqpsk_soft(burst_syms)
            bkn2_s = (sb_off_bkn2 - 1) * 2
            if bkn2_s + SDB_BKN2 * 2 > len(soft_bits):
                continue
            bkn2_soft = soft_bits[bkn2_s : bkn2_s + SDB_BKN2 * 2]
            bkn2_soft = descramble_soft(bkn2_soft, scramb_code, 216)
            bkn2_crc, bkn2_info, _ = decode_channel_soft(bkn2_soft, 216, 101, 124)

            if not bkn2_crc:
                # Timing retry with offsets
                for retry_dt in [0.3, -0.3, 0.6, -0.6, 1.0, -1.0]:
                    retry_syms, retry_corr = _extract_and_correct(
                        burst_start_pred, sb_off_sts, STS_DIBITS, STS_DIFF_REF,
                        timing_offset=retry_dt)
                    if retry_syms is None:
                        continue
                    rs = demod_pi4dqpsk_soft(retry_syms)
                    rb = rs[bkn2_s : bkn2_s + SDB_BKN2 * 2]
                    rb = descramble_soft(rb, scramb_code, 216)
                    rok, rinfo, _ = decode_channel_soft(rb, 216, 101, 124)
                    if rok:
                        bkn2_crc, bkn2_info = True, rinfo
                        break
                if not bkn2_crc:
                    bad_burst_counter += 0.5
                    # FN=18 with Frame18Ext=0: non-BSCH BKN2 is not guaranteed valid
                    if fn == 18 and si.get('Frame18Ext', 0) == 0:
                        print(f"  BKN2 n/a (FN=18 non-BSCH, F18ext=0)")
                    else:
                        print("  BKN2 CRC FAIL")

            if bkn2_crc:
                mac = parse_mac_pdu(bkn2_info, 124)
                _print_mac("  BKN2", mac, bkn2_info, verbose)

            # BB (AACH) decode
            bb_start = sb_off_bb - 1
            if bb_start + SDB_BB > len(dibits):
                continue
            bb_dibits = dibits[bb_start : bb_start + SDB_BB]
            bb_bits = dibits_to_bits(bb_dibits)
            bb_descr = (bb_bits ^ scrambler_seq(scramb_code, 30)) & 1
            aach_info, aach_dist = rm3014_decode(bb_descr)
            if aach_info is not None:
                aach = parse_aach(aach_info)
                _print_aach("  AACH", aach, aach_dist)
            else:
                print(f"  AACH  decode fail (dist={aach_dist})")

        else:
            # --- Normal Burst (NDB1/NDB2) ---
            dibits = demod_pi4dqpsk(burst_syms)
            soft_bits = demod_pi4dqpsk_soft(burst_syms)

            # BB (AACH) — reconstruct from bb1 + bb2 (hard, for RM decode)
            bb1_dibits = dibits[NDB_OFF_BB1 - 1 : NDB_OFF_BB1 - 1 + NDB_BB1]
            bb2_dibits = dibits[NDB_OFF_BB2 - 1 : NDB_OFF_BB2 - 1 + NDB_BB2]
            bb_dibits = np.concatenate([bb1_dibits, bb2_dibits])
            bb_bits = dibits_to_bits(bb_dibits)

            bb_descr = (bb_bits ^ scrambler_seq(scramb_code, 30)) & 1
            aach_info, aach_dist = rm3014_decode(bb_descr)
            aach = parse_aach(aach_info) if aach_info is not None else None
            dl_mode = aach.get('dl_name', '?') if aach else '?'

            print(f"\n[#{idx:3d}] {btype} {slot_tag} corr={corr:.3f}  ", end='')
            if aach:
                _print_aach("AACH", aach, aach_dist)
            else:
                print(f"AACH decode fail (dist={aach_dist})")

            # BLK1 + BLK2 — routing depends on burst type:
            #   NDB1 (n_bits training, §9.4.4.3.1): SCH/F, one logical channel,
            #                                       BLK1+BLK2 combined = 432 bits, a=103, 268 info
            #   NDB2 (p_bits training, §9.4.4.3.2 NDB_SF): two logical channels,
            #                                       BLK1 and BLK2 each = SCH/HD (216 bits, a=101, 124 info)
            blk1_s = (NDB_OFF_BLK1 - 1) * 2
            blk2_s = (NDB_OFF_BLK2 - 1) * 2
            blk1_soft = soft_bits[blk1_s : blk1_s + NDB_BLK1 * 2]
            blk2_soft = soft_bits[blk2_s : blk2_s + NDB_BLK2 * 2]

            if btype == 'NDB1':
                # SCH/F combined
                combined_soft = np.concatenate([blk1_soft, blk2_soft])

                # Phase-1 dump-hook: vor Descramble die rohen on-air type-5
                # hard-bits + nach Decode die 268 info bits ausgeben.
                if dump_burst == idx:
                    on_air_t5 = (np.concatenate([blk1_soft, blk2_soft]) < 0).astype(int).tolist()
                    print(f"  ROUNDTRIP_DUMP type5_onair_432b={''.join(str(b) for b in on_air_t5)}")
                    print(f"  ROUNDTRIP_DUMP scramb_code=0x{scramb_code:08x}")

                combined_soft = descramble_soft(combined_soft, scramb_code, 432)
                crc_ok, info_bits, _ = decode_channel_soft(combined_soft, 432, 103, 268)

                if dump_burst == idx and crc_ok:
                    info_str = ''.join(str(int(b)) for b in info_bits)
                    print(f"  ROUNDTRIP_DUMP info_268b={info_str}")
                    print(f"  ROUNDTRIP_DUMP info_hex=0x{int(info_str,2):067x}")

                if crc_ok:
                    n_ndb_ok += 1
                    mac = parse_mac_pdu(info_bits, 268)
                    _print_mac("  SCH/F", mac, info_bits, verbose)

                    if mac.get('type') == 0 and not mac.get('is_null_pdu'):
                        pstart = mac.get('payload_start', 0)
                        if pstart + 4 < len(info_bits):
                            llc = parse_llc(info_bits, pstart)
                            _print_llc("    LLC", llc)
                            if 'payload_start' in llc and llc['payload_start'] + 3 < len(info_bits):
                                if llc.get('llc_type') == 14:
                                    direct_mm = parse_direct_mm(info_bits, llc['payload_start'])
                                    _print_direct_mm("    DirectMM", direct_mm)
                                else:
                                    mle = parse_mle(info_bits, llc['payload_start'])
                                    _print_mle("    MLE", mle)
                else:
                    n_ndb_fail += 1
                    bad_burst_counter += 0.5
                    print("  SCH/F CRC FAIL")

            else:  # btype == 'NDB2' → NDB_SF, two separate SCH/HD blocks
                def _decode_halves(sbits):
                    b1 = sbits[blk1_s : blk1_s + NDB_BLK1 * 2]
                    b2 = sbits[blk2_s : blk2_s + NDB_BLK2 * 2]
                    b1d = descramble_soft(b1, scramb_code, 216)
                    c1, i1, _ = decode_channel_soft(b1d, 216, 101, 124)
                    b2d = descramble_soft(b2, scramb_code, 216)
                    c2, i2, _ = decode_channel_soft(b2d, 216, 101, 124)
                    return c1, i1, c2, i2

                crc1, info1, crc2, info2 = _decode_halves(soft_bits)

                # Phase-1 NDB2 dump-hook (SCH/HD round-trip)
                if dump_burst == idx:
                    b1 = soft_bits[blk1_s : blk1_s + NDB_BLK1 * 2]
                    b2 = soft_bits[blk2_s : blk2_s + NDB_BLK2 * 2]
                    onair_b1 = (np.asarray(b1) < 0).astype(int).tolist()
                    onair_b2 = (np.asarray(b2) < 0).astype(int).tolist()
                    print(f"  ROUNDTRIP_DUMP_HD bkn1_onair_216b={''.join(str(b) for b in onair_b1)}")
                    print(f"  ROUNDTRIP_DUMP_HD bkn2_onair_216b={''.join(str(b) for b in onair_b2)}")
                    print(f"  ROUNDTRIP_DUMP_HD scramb_code=0x{scramb_code:08x}")
                    if crc1:
                        i1s = ''.join(str(int(b)) for b in info1)
                        print(f"  ROUNDTRIP_DUMP_HD bkn1_info_124b={i1s}")
                    if crc2:
                        i2s = ''.join(str(int(b)) for b in info2)
                        print(f"  ROUNDTRIP_DUMP_HD bkn2_info_124b={i2s}")

                # Retry with timing jitter + phase rotation if either half failed.
                # NTS-only phase fit (11 sym) extrapolates poorly over 108-sym BLKs.
                if not (crc1 and crc2):
                    # Finer/wider timing grid for half-burst alignment
                    retry_dts = [-0.2, 0.2, -0.45, 0.45, -0.7, 0.7, -1.0, 1.0, -1.5, 1.5]
                    # Small residual phase offsets to counter NTS-fit extrapolation noise
                    phase_offsets = [0.0, np.pi/16, -np.pi/16, np.pi/8, -np.pi/8]
                    done = False
                    for retry_dt in retry_dts:
                        if done:
                            break
                        retry_syms, _ = _extract_and_correct(
                            burst_start_pred, NDB_OFF_NTS, NTS2_DIBITS, NTS2_DIFF_REF,
                            timing_offset=retry_dt)
                        if retry_syms is None:
                            continue
                        for pho in phase_offsets:
                            rs = demod_pi4dqpsk_soft(retry_syms * np.exp(1j * pho))
                            rc1, ri1, rc2, ri2 = _decode_halves(rs)
                            if rc1 and not crc1:
                                crc1, info1 = rc1, ri1
                            if rc2 and not crc2:
                                crc2, info2 = rc2, ri2
                            if crc1 and crc2:
                                done = True
                                break

                if crc1 or crc2:
                    n_ndb_ok += 1
                else:
                    n_ndb_fail += 1

                if crc1:
                    mac1 = parse_mac_pdu(info1, 124)
                    _print_mac("  BKN1 SCH/HD", mac1, info1, verbose)
                else:
                    print("  BKN1 SCH/HD CRC FAIL")
                    bad_burst_counter += 0.25

                # BKN2 on TN=1 FN=18 carries BNCH (SYSINFO); elsewhere SCH/HD CCH
                bkn2_is_bnch = (nt.tn == 1 and nt.fn == 18)
                bkn2_tag = "BKN2 BNCH" if bkn2_is_bnch else "BKN2 SCH/HD"
                if crc2:
                    if bkn2_is_bnch:
                        bnch_si = parse_sysinfo_sb(info2)
                        print(f"  {bkn2_tag}  {bnch_si}")
                    else:
                        mac2 = parse_mac_pdu(info2, 124)
                        _print_mac(f"  {bkn2_tag}", mac2, info2, verbose)
                else:
                    print(f"  {bkn2_tag} CRC FAIL")
                    bad_burst_counter += 0.25

        # --- End of per-burst processing: advance NetworkTime and update MER/BER ---
        time_counter += 1
        if time_counter % 100 == 0:
            mer = 100.0 * bad_burst_counter / time_counter
            print(f"  [progress] MER={mer:.1f}%  BER(EMA)={ber_ema:.4f}")
        nt.advance()

    # Summary
    total = min(len(sts_positions), max_bursts)
    total_ok = n_sb_ok + n_ndb_ok
    total_fail = n_sb_fail + n_ndb_fail
    final_mer = 100.0 * bad_burst_counter / max(1, time_counter)
    print("\n" + "=" * 60)
    print(f" SUMMARY: {total_ok} decoded, {total_fail} failed, {n_empty} empty")
    print(f"   SB:  {n_sb_ok} OK / {n_sb_ok + n_sb_fail} ({100*n_sb_ok/max(1,n_sb_ok+n_sb_fail):.0f}%)")
    print(f"   NDB: {n_ndb_ok} OK / {n_ndb_ok + n_ndb_fail} ({100*n_ndb_ok/max(1,n_ndb_ok+n_ndb_fail):.0f}%)")
    print(f"   Empty slots: {n_empty}")
    print(f"   MER (DLL-style burst error): {final_mer:.2f}%")
    print(f"   Final NetworkTime: {nt}")
    if scramb_code is not None:
        print(f" Cell: MCC={mcc} MNC={mnc} CC={cc} scrambCode=0x{scramb_code:08X}")
    print("=" * 60)
    return True


# =============================================================================
# Pretty printers
# =============================================================================

def _print_aach(prefix, aach, dist):
    hdr = aach.get('header_name', f"H={aach.get('header','?')}")
    f1 = aach.get('field1', '?')
    f2 = aach.get('field2', '?')
    if aach.get('header') in (0, 1):
        print(f"{prefix}  [{hdr}] DL={aach.get('dl_name','?')} UL={aach.get('ul_name','?')} "
              f"CC={aach.get('colour_code','?')} f1={f1} f2={f2} (dist={dist})")
    else:
        print(f"{prefix}  [{hdr}] f1={f1} f2={f2} raw={aach.get('raw','?')} (dist={dist})")


def _print_mac(prefix, mac, info_bits, verbose):
    t = mac.get('type_name', '?')
    print(f"{prefix}  {t}", end='')

    if mac.get('type') == 0:  # RESOURCE
        if mac.get('is_null_pdu'):
            print("  NULL PDU (filler)")
        else:
            addr = mac.get('address_type_name', '?')
            ssi = mac.get('SSI') or mac.get('USSI') or mac.get('SMI')
            li = mac.get('length_indicator', '?')
            print(f"  addr={addr}", end='')
            if ssi is not None:
                print(f" ID={ssi}", end='')
            if 'event_label' in mac:
                print(f" evt={mac['event_label']}", end='')
            print(f" LI={li} ({mac.get('length_indicator_meaning', '?')})")

            ca = mac.get('channel_allocation')
            if ca:
                name = ca.get('allocation_type_name', '?')
                ts = ca.get('timeslot_assigned', '?')
                updn = ca.get('uplink_downlink_assigned_name', '?')
                cn = ca.get('carrier_number', '?')
                print(f"{prefix}    ChanAlloc: {name} TS={ts} {updn} Carrier={cn}")
    elif mac.get('type') == 2:  # BROADCAST
        sub = mac.get('sub_type_name', '?')
        print(f"  sub={sub}")
        si = mac.get('sysinfo')
        if si:
            mc = si.get('Main_Carrier', '?')
            fb = si.get('Frequency_Band', '?')
            ds = si.get('Duplex_Spacing', '?')
            la = si.get('Location_Area', '?')
            dl_hz = si.get('DL_Frequency_Hz')
            hf = si.get('Hyperframe', '?')
            line = f"    Carrier={mc} Band={fb} Duplex={ds} HF={hf} LocArea={la}"
            if dl_hz is not None:
                line += f" DL={dl_hz/1e6:.4f}MHz"
            print(f"{prefix}{line}")
        ad = mac.get('access_define')
        if ad:
            c_or_a = 'common' if ad.get('common_or_assigned') == 0 else 'assigned'
            print(f"{prefix}    AccessDef: {c_or_a} code={ad.get('access_code','?')} "
                  f"IMM={ad.get('imm','?')} WT={ad.get('wt','?')} Nu={ad.get('nu','?')} "
                  f"TSptr={ad.get('timeslot_pointer','?')}")
    elif mac.get('type') == 1:  # FRAG/END
        sub = mac.get('sub_type', '?')
        print(f"  {sub}")
    elif mac.get('type') == 3:  # U-SIGNAL
        addr = mac.get('address_type_name', '?')
        li = mac.get('length_indicator', '?')
        print(f"  addr={addr} LI={li}")
    else:
        print()

    if verbose and info_bits is not None:
        hex_str = ''.join(str(int(b)) for b in info_bits[:124])
        print(f"{prefix}    bits: {hex_str}")


def _print_llc(prefix, llc):
    print(f"{prefix}  {llc.get('llc_type_name', '?')}", end='')
    if 'nr' in llc:
        print(f" NR={llc['nr']}", end='')
    if 'ns' in llc:
        print(f" NS={llc['ns']}", end='')
    if 'fcs_ok' in llc:
        print(f" FCS={'OK' if llc['fcs_ok'] else 'BAD'}", end='')
    print()


def _print_mle(prefix, mle):
    print(f"{prefix}  disc={mle.get('mle_disc_name', '?')}", end='')
    if 'cmce_name' in mle:
        print(f" → {mle['cmce_name']}", end='')
    elif 'mm_name' in mle:
        print(f" → {mle['mm_name']}", end='')
    elif 'mle_prim_name' in mle:
        print(f" → {mle['mle_prim_name']}", end='')
    print()

    mm = mle.get('mm')
    if mm:
        if 'location_update_accept_type_name' in mm:
            line = f"{prefix}    LocUpdAccept: {mm['location_update_accept_type_name']}"
            if 'ssi' in mm:
                line += f" SSI={mm['ssi']}"
            if 'address_extension' in mm:
                line += f" AddrExt={mm['address_extension']}"
            if 'subscriber_class' in mm:
                line += f" SubCls=0x{mm['subscriber_class']:04X}"
            if 'energy_saving_info' in mm:
                line += f" ESI=0x{mm['energy_saving_info']:04X}"
            if 'frame18_scch_info' in mm:
                line += f" SCCH18=0x{mm['frame18_scch_info']:02X}"
            if 'type3_field_id' in mm:
                line += f" T3id={mm['type3_field_id']} T3len={mm.get('type3_payload_len', '?')}"
            print(line)
        elif 'location_update_type_name' in mm:
            print(f"{prefix}    LocUpdType: {mm['location_update_type_name']}")
        elif 'reject_cause' in mm:
            print(f"{prefix}    RejectCause={mm['reject_cause']}")
        elif 'group_identity_accept_reject' in mm:
            print(f"{prefix}    GroupAck accept_reject={mm['group_identity_accept_reject']}")
        elif 'status_value' in mm:
            print(f"{prefix}    Status={mm['status_value']}")


def _print_direct_mm(prefix, direct_mm):
    print(f"{prefix}  {direct_mm.get('mm_name', '?')}")
    mm = direct_mm.get('mm') or {}
    if 'location_update_accept_type_name' in mm:
        line = f"{prefix}    LocUpdAccept: {mm['location_update_accept_type_name']}"
        if 'ssi' in mm:
            line += f" SSI={mm['ssi']}"
        if 'address_extension' in mm:
            line += f" AddrExt={mm['address_extension']}"
        if 'subscriber_class' in mm:
            line += f" SubCls=0x{mm['subscriber_class']:04X}"
        if 'energy_saving_info' in mm:
            line += f" ESI=0x{mm['energy_saving_info']:04X}"
        if 'frame18_scch_info' in mm:
            line += f" SCCH18=0x{mm['frame18_scch_info']:02X}"
        if 'type3_field_id' in mm:
            line += f" T3id={mm['type3_field_id']} T3len={mm.get('type3_payload_len', '?')}"
        print(line)
    elif 'location_update_type_name' in mm:
        print(f"{prefix}    LocUpdType: {mm['location_update_type_name']}")
    elif 'reject_cause' in mm:
        print(f"{prefix}    RejectCause={mm['reject_cause']}")
    elif 'group_identity_accept_reject' in mm:
        print(f"{prefix}    GroupAck accept_reject={mm['group_identity_accept_reject']}")
    elif 'status_value' in mm:
        print(f"{prefix}    Status={mm['status_value']}")


# =============================================================================
# Entry point
# =============================================================================

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='TETRA Full Downlink Decoder')
    parser.add_argument('input', nargs='?', default='/tmp/tetra_tx_capture.bin',
                        help='IQ capture file (RTL-SDR uint8 or WAV)')
    parser.add_argument('--sr', type=int, default=2048000,
                        help='Sample rate (default 2048000)')
    parser.add_argument('--offset', type=float, default=0,
                        help='Frequency offset in Hz (0=auto)')
    parser.add_argument('--max-bursts', type=int, default=200,
                        help='Max bursts to decode (default 200)')
    parser.add_argument('--conjugate', action='store_true',
                        help='Conjugate IQ (mirror spectrum)')
    parser.add_argument('--swap-iq', action='store_true',
                        help='Swap I/Q channels (WAV input)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Show raw bits')
    parser.add_argument('--capture', action='store_true',
                        help='Capture with rtl_sdr first')
    parser.add_argument('--freq', type=int, default=440106000,
                        help='Capture frequency (default 440106000)')
    parser.add_argument('--gain', type=float, default=40,
                        help='RTL-SDR gain')
    parser.add_argument('--duration', type=float, default=2.0,
                        help='Capture duration in seconds')
    parser.add_argument('--dump-burst', type=int, default=-1,
                        help='Dump 268-bit SCH/F info + 432-bit type-5 hard '
                             'bits for a single NDB1 burst index (Phase-1 '
                             'verifier hook, used by verify_sch_f_roundtrip).')
    args = parser.parse_args()

    if args.capture:
        import subprocess
        n_samples = int(args.sr * args.duration)
        capture_file = '/tmp/tetra_dl_capture.bin'
        print(f"Capturing {args.duration}s at {args.freq/1e6:.3f} MHz...")
        subprocess.run([
            'rtl_sdr', '-d', '0',
            '-f', str(args.freq),
            '-s', str(args.sr),
            '-g', str(args.gain),
            '-n', str(n_samples),
            capture_file,
        ], check=True)
        args.input = capture_file

    ok = decode_dl(args.input, sample_rate=args.sr,
                   freq_offset=args.offset, max_bursts=args.max_bursts,
                   conjugate=args.conjugate, swap_iq=args.swap_iq,
                   verbose=args.verbose, dump_burst=args.dump_burst)
    sys.exit(0 if ok else 1)
