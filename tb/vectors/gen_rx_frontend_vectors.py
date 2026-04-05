#!/usr/bin/env python3
# =============================================================================
# gen_rx_frontend_vectors.py
# Project:  tetra-zynq-phy
# Module:   tetra_rx_frontend
#
# Generates test vectors for the RX frontend (CIC decimation + RRC matched
# filter) using FIXED-POINT integer arithmetic that matches the RTL exactly.
#
# CIC model (matches tetra_rx_frontend.v Section 3):
#   - Input: int16 (quantised from float before simulation)
#   - 5 integrators running on every input sample (gated by in_valid)
#   - Decimation strobe fires after R=64 input samples (dec_cnt == R-1)
#   - Decimate by taking integrator value at index R-1 of each block
#     → Python: y5[R-1::R]  (NOT y5[::R] which would be off-by-63 samples)
#   - 5 comb stages: running differences of successive decimated values
#   - Output truncation: >> CIC_TRUNC = 30 (arithmetic right-shift)
#   - Saturation: clip to int16 range (CIC_BITS=46 ensures no internal overflow)
#
# RRC model (matches tetra_rx_frontend.v Section 4):
#   - Coefficients: Q14 signed (same hardcoded values as the RTL localparams)
#   - Shift register of 33 most-recent CIC outputs (int16)
#   - MAC: acc = sum(sr[k] * h[k]) for k=0..32, acc is int64
#   - Output: acc >> RRC_ACC_SHIFT = 14, saturated to int16
#
# Output files (in same directory as this script):
#   rx_frontend_stimulus.hex   — IQ pairs at ADC rate (32-bit: I[31:16] Q[15:0])
#   rx_frontend_expected.hex   — Filtered IQ at CIC output rate (32-bit: same)
#   rrc_coefficients.hex       — 33 × Q14 coefficients (16-bit signed)
#
# Sizes (must match localparam MAX_STIM/MAX_EXP in tb_tetra_rx_frontend.v):
#   Stimulus:  9088 words  (Test1=2944 + Test2=3456 + Test3=2688)
#   Expected:    34 words  (Test1=8    + Test2=16   + Test3=10)
#
# Ref: ETSI EN 300 392-2 §9.5 (RRC pulse shaping)
#      Hogenauer, "An Economical Class of Digital Filters" (1981)
# =============================================================================

import numpy as np
import os

# ---------------------------------------------------------------------------
# Parameters (must match rtl/rx/tetra_rx_frontend.v)
# ---------------------------------------------------------------------------
IQ_WIDTH        = 16
CIC_ORDER       = 5
CIC_R           = 64           # decimation ratio
CIC_M           = 1            # differential delay (unused in this model)
RRC_TAPS        = 33           # must be odd
RRC_ALPHA       = 0.35         # TETRA roll-off
SAMPLES_PER_SYM = 4            # oversampling factor after CIC

CIC_BITS        = IQ_WIDTH + CIC_ORDER * int(np.ceil(np.log2(CIC_R * CIC_M)))
# = 16 + 5*6 = 46
CIC_TRUNC       = CIC_BITS - IQ_WIDTH   # = 30
RRC_ACC_SHIFT   = 14                    # remove Q14 fractional bits

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# RRC coefficients — Q14 signed, SAME VALUES as hardcoded in the RTL
# (tetra_rx_frontend.v localparams RRC_H00..RRC_H32)
# h[k] is symmetric: h[k] == h[32-k]
# ---------------------------------------------------------------------------
RRC_Q14 = np.array([
     17,   109,    78,   -78,  -209,  -121,   210,   535,
    468,  -181, -1108, -1545,  -694,  1696,  4979,  7844,
   8978,  7844,  4979,  1696,  -694, -1545, -1108,  -181,
    468,   535,   210,  -121,  -209,   -78,    78,   109,
     17,
], dtype=np.int64)
assert len(RRC_Q14) == RRC_TAPS, "RRC_Q14 length must equal RRC_TAPS"

# ---------------------------------------------------------------------------
# Helper: clamp to int16 range
# ---------------------------------------------------------------------------
def clamp16(x):
    return int(np.clip(x, -32768, 32767))

def to_int16(x):
    """Clamp float array to [-1, 1-2^-15] and scale to signed int16."""
    x = np.clip(x, -1.0, 1.0 - 2**-15)
    return np.round(x * 32768).astype(np.int32)

# ---------------------------------------------------------------------------
# Fixed-point CIC decimator  (matches RTL exactly)
#
# RTL timing:
#   dec_cnt counts 0..R-1 on each valid input sample.
#   cic_strobe fires one cycle after dec_cnt wraps (registered).
#   At cic_strobe: all 5 comb z1 registers latch current comb outputs
#   simultaneously from OLD values; simultaneously cic_out captures comb5.
#
# Python equivalent:
#   1. 5× np.cumsum on int16 input array, with 46-bit 2's-complement wrap
#      after each stage (matching CIC_BITS=46 in tetra_rx_frontend.v).
#      This is the critical step: the RTL accumulator wraps modulo 2^46
#      (Hogenauer 1981 — intentional modular wrap preserves correctness
#      because the comb differences cancel the wrapped growth).
#   2. Decimate: take element at index R-1 of each block → y[R-1::R]
#      (NOT y[::R] — that would be off by R-1 input samples)
#   3. 5× np.diff(prepend=0) for comb stages, each with 46-bit wrap
#   4. Arithmetic right-shift by CIC_TRUNC=30; saturate to int16
# ---------------------------------------------------------------------------

# CIC accumulator mask for 46-bit two's-complement wrap
_CIC_MASK  = (1 << CIC_BITS) - 1      # 0x3FFFFFFFFFFF
_CIC_SIGN  = 1 << (CIC_BITS - 1)      # bit 45


def _wrap46(y: np.ndarray) -> np.ndarray:
    """Truncate to 46-bit two's-complement, result in int64."""
    y = y & _CIC_MASK                          # unsigned mod 2^46
    y = (y ^ _CIC_SIGN) - _CIC_SIGN           # sign-extend bit 45
    return y.astype(np.int64)


def simulate_cic_fixed(i_in, q_in):
    """
    Fixed-point CIC decimation matching tetra_rx_frontend.v RTL.

    The critical detail: in the Verilog all always-blocks execute with the
    OLD registered values (non-blocking assignment semantics).  So at each
    clock edge:
        int1[n] = int1[n-1] + x[n]          (sees current input)
        int2[n] = int2[n-1] + int1[n-1]      (sees OLD int1, not the just-updated value)
        int3[n] = int3[n-1] + int2[n-1]
        int4[n] = int4[n-1] + int3[n-1]
        int5[n] = int5[n-1] + int4[n-1]

    Stages 2..5 therefore implement z^{-1}/(1-z^{-1}) rather than 1/(1-z^{-1}),
    introducing 4 extra input-sample delays.  A simple cascade of np.cumsum()
    would give 1/(1-z^{-1})^5 (wrong).

    Correct numpy formulation for stage k >= 2:
        y_k[n] = cumsum(y_{k-1} shifted right by 1, prepend 0)
    All wrapped to CIC_BITS=46.
    """
    def cic_channel(x):
        y = _wrap46(np.cumsum(x.astype(np.int64)))  # stage 1: normal cumsum

        for _ in range(CIC_ORDER - 1):               # stages 2..5
            # Stage k uses stage k-1's OLD (previous-cycle) value:
            #   y_k[n] = y_k[n-1] + y_{k-1}[n-1]
            # → cumsum of y_{k-1} shifted right by one sample (prepend 0)
            y_prev = np.concatenate([[np.int64(0)], y[:-1]])
            y = _wrap46(np.cumsum(y_prev))

        # Decimation: take the LAST sample of each R-input block.
        y = y[CIC_R - 1 :: CIC_R]

        # 5 comb stages: first-difference filter (z^-1 delays start at 0)
        for _ in range(CIC_ORDER):
            y = _wrap46(np.diff(y, prepend=np.int64(0)))

        # Truncation: bits [45:30] of the 46-bit accumulator = >> 30
        y = y >> CIC_TRUNC

        # Saturate to int16
        return np.clip(y, -32768, 32767).astype(np.int16)

    return cic_channel(i_in), cic_channel(q_in)


# ---------------------------------------------------------------------------
# Fixed-point RRC matched filter  (matches RTL exactly)
#
# RTL structure: flat 528-bit shift register (33 × 16-bit, newest at SR[15:0]).
#   On cic_valid: shift left by IQ_WIDTH, insert new sample at bottom.
#   MAC: sequential loop k=0..32, acc += SR[k*16 +: 16] * RRC_H[k].
#   Output = acc >> RRC_ACC_SHIFT, saturated to int16.
#
# RTL tap ordering (from comments in tetra_rx_frontend.v):
#   tap 0 = SR[15:0]    = newest sample = h[0] (= 17)
#   tap 32 = SR[527:512] = oldest sample = h[32] (= 17)
#   Since RRC is symmetric (h[0]=h[32]=17) the ordering makes no difference,
#   but we replicate it exactly: newest sample multiplied by h[0].
# ---------------------------------------------------------------------------
def simulate_rrc_fixed(i_in, q_in):
    """
    Fixed-point RRC MAC filter matching tetra_rx_frontend.v RTL.

    Args:
        i_in, q_in: numpy int16 arrays (CIC-rate output)

    Returns:
        (i_out, q_out): numpy int16 arrays of same length
    """
    def rrc_channel(x):
        n = len(x)
        out = np.zeros(n, dtype=np.int16)
        # Shift register: newest at index 0, oldest at index RRC_TAPS-1
        sr = np.zeros(RRC_TAPS, dtype=np.int64)

        for k in range(n):
            # Shift in new sample (discard oldest)
            sr[1:] = sr[:-1]
            sr[0] = int(x[k])

            # MAC: newest sample × h[0], oldest × h[32]
            acc = np.int64(0)
            for t in range(RRC_TAPS):
                acc += sr[t] * RRC_Q14[t]

            # Truncate and saturate
            out_val = int(acc >> RRC_ACC_SHIFT)
            out[k] = clamp16(out_val)

        return out

    return rrc_channel(i_in.astype(np.int64)), rrc_channel(q_in.astype(np.int64))


# ---------------------------------------------------------------------------
# π/4-DQPSK modulator (for Test 3 stimulus generation)
# ---------------------------------------------------------------------------
DQPSK_DELTA = {
    0b00: +np.pi / 4,
    0b01: +3 * np.pi / 4,
    0b10: -np.pi / 4,
    0b11: -3 * np.pi / 4,
}

def pi4dqpsk_modulate(dibits, sps):
    phase = 0.0
    i_all, q_all = [], []
    for db in dibits:
        phase += DQPSK_DELTA[int(db) & 0x3]
        for _ in range(sps):
            i_all.append(np.cos(phase))
            q_all.append(np.sin(phase))
    return np.array(i_all), np.array(q_all)


# ---------------------------------------------------------------------------
# RRC coefficients (float) for stimulus generation
# ---------------------------------------------------------------------------
def rrc_taps_float(num_taps, sps, alpha):
    N, L, half = num_taps, sps, (num_taps - 1) // 2
    h = np.zeros(N)
    for i in range(N):
        t = (i - half) / L
        if t == 0.0:
            h[i] = 1.0 - alpha + 4.0 * alpha / np.pi
        elif abs(t) == 1.0 / (4.0 * alpha):
            h[i] = (alpha / np.sqrt(2.0)) * (
                (1.0 + 2.0 / np.pi) * np.sin(np.pi / (4.0 * alpha))
                + (1.0 - 2.0 / np.pi) * np.cos(np.pi / (4.0 * alpha))
            )
        else:
            num = (np.sin(np.pi * t * (1.0 - alpha))
                   + 4.0 * alpha * t * np.cos(np.pi * t * (1.0 + alpha)))
            den = np.pi * t * (1.0 - (4.0 * alpha * t) ** 2)
            h[i] = num / den
    h /= np.sqrt(np.sum(h * h))
    return h

rrc_float = rrc_taps_float(RRC_TAPS, SAMPLES_PER_SYM, RRC_ALPHA)


# ---------------------------------------------------------------------------
# Test vector accumulation
# ---------------------------------------------------------------------------
stimulus_i  = []
stimulus_q  = []
expected_i  = []
expected_q  = []
test_labels = []

def add_test(label, adc_i, adc_q, sym_count):
    """
    Add one test case.

    adc_i/q:   float arrays (ADC-rate, amplitude ≤ 1.0)
    sym_count: number of expected output samples to record

    Simulation uses quantised int16 inputs and fixed-point arithmetic
    matching the RTL — so expected values match RTL output within 1 LSB.
    """
    # Quantise to int16 (what the RTL actually receives)
    i16 = to_int16(adc_i).astype(np.int16)
    q16 = to_int16(adc_q).astype(np.int16)

    # Fixed-point CIC + RRC matching RTL arithmetic
    cic_i, cic_q = simulate_cic_fixed(i16, q16)
    rrc_i, rrc_q = simulate_rrc_fixed(cic_i, cic_q)

    # Expected: first sym_count outputs (index 0 = first valid RTL output,
    # which includes the startup transient — matches RTL comparison from sample 0)
    assert len(rrc_i) >= sym_count, \
        f"Test '{label}': only {len(rrc_i)} CIC outputs, need {sym_count}"
    exp_i_arr = rrc_i[:sym_count].astype(np.int16)
    exp_q_arr = rrc_q[:sym_count].astype(np.int16)

    stimulus_i.extend(i16.tolist())
    stimulus_q.extend(q16.tolist())
    expected_i.extend(exp_i_arr.tolist())
    expected_q.extend(exp_q_arr.tolist())
    test_labels.append((label, len(i16), sym_count))
    print(f"  Test '{label}': {len(i16)} ADC samples → {sym_count} expected outputs "
          f"  I[0..3]={list(exp_i_arr[:4])}  Q[0..3]={list(exp_q_arr[:4])}")


# ---------------------------------------------------------------------------
# Test 1: DC  — I = 0.5, Q = 0
# Verifies CIC DC gain and RRC passband; startup transient visible.
# SYM_COUNT_DC=8 output symbols requested.
# adc_len = (SYM_COUNT + FLUSH_SYMBOLS) * CIC_R where
#   FLUSH_SYMBOLS = (RRC_TAPS + CIC_ORDER) = 38 ensures the RRC has 38 outputs
#   before we start collecting expected values — BUT we request from index 0
#   so the first 38 are startup, then 8 are the "interesting" steady-state.
# ---------------------------------------------------------------------------
SYM_COUNT_DC  = 8
FLUSH_SYMBOLS = (RRC_TAPS + CIC_ORDER)      # = 38
adc_len_dc    = (SYM_COUNT_DC + FLUSH_SYMBOLS) * CIC_R   # = 46 * 64 = 2944

adc_i_dc = np.full(adc_len_dc, 0.5)
adc_q_dc = np.zeros(adc_len_dc)
print("\nTest 1: DC (I=0.5, Q=0)")
add_test("DC", adc_i_dc, adc_q_dc, SYM_COUNT_DC)

# ---------------------------------------------------------------------------
# Test 2: 1 kHz complex tone — within TETRA 25 kHz channel
# Verifies CIC alias rejection and RRC passband response.
# ---------------------------------------------------------------------------
SYM_COUNT_TONE = 16
adc_len_tone   = (SYM_COUNT_TONE + FLUSH_SYMBOLS) * CIC_R   # = 54 * 64 = 3456
t_tone = np.arange(adc_len_tone) / 4.608e6     # time at 4.608 MHz ADC rate
TONE_FREQ      = 1000.0                          # 1 kHz, well within 25 kHz channel
adc_i_tone = 0.7 * np.cos(2 * np.pi * TONE_FREQ * t_tone)
adc_q_tone = 0.7 * np.sin(2 * np.pi * TONE_FREQ * t_tone)
print("\nTest 2: 1 kHz complex tone")
add_test("TONE_1kHz", adc_i_tone, adc_q_tone, SYM_COUNT_TONE)

# ---------------------------------------------------------------------------
# Test 3: π/4-DQPSK matched-filter output
# 10 DQPSK symbols, TX-RRC pulse-shaped at CIC output rate (1 SPS), then
# upsampled to ADC rate.  After RX CIC+RRC matched filter the output should
# approximate the original DQPSK IQ constellation.
# ---------------------------------------------------------------------------
SYM_COUNT_DQPSK = 10
np.random.seed(42)
dibits = np.random.randint(0, 4, SYM_COUNT_DQPSK)

# TX: modulate at 1 SPS then apply RRC pulse shaping (float model for stimulus)
tx_i_sym, tx_q_sym = pi4dqpsk_modulate(dibits, sps=1)   # 10 samples at CIC rate
tx_rrc_i = np.convolve(tx_i_sym, rrc_float, mode='full')  # 42 samples
tx_rrc_q = np.convolve(tx_q_sym, rrc_float, mode='full')

# Upsample to ADC rate (insert CIC_R-1 zeros between samples)
n_tx = len(tx_rrc_i)
adc_i_dqpsk = np.zeros(n_tx * CIC_R)
adc_q_dqpsk = np.zeros(n_tx * CIC_R)
adc_i_dqpsk[::CIC_R] = tx_rrc_i
adc_q_dqpsk[::CIC_R] = tx_rrc_q

# Normalise to avoid saturation
mx = max(np.max(np.abs(adc_i_dqpsk)), np.max(np.abs(adc_q_dqpsk)), 1e-9)
adc_i_dqpsk /= mx
adc_q_dqpsk /= mx

print("\nTest 3: π/4-DQPSK with RRC pulse shaping")
add_test("DQPSK", adc_i_dqpsk, adc_q_dqpsk, SYM_COUNT_DQPSK)

# ---------------------------------------------------------------------------
# Write stimulus and expected files
# ---------------------------------------------------------------------------
stim_path = os.path.join(SCRIPT_DIR, "rx_frontend_stimulus.hex")
exp_path  = os.path.join(SCRIPT_DIR, "rx_frontend_expected.hex")

with open(stim_path, "w") as fs, open(exp_path, "w") as fe:
    for i_s, q_s in zip(stimulus_i, stimulus_q):
        i_u = int(i_s) & 0xFFFF
        q_u = int(q_s) & 0xFFFF
        fs.write(f"{(i_u << 16) | q_u:08X}\n")

    for i_s, q_s in zip(expected_i, expected_q):
        i_u = int(i_s) & 0xFFFF
        q_u = int(q_s) & 0xFFFF
        fe.write(f"{(i_u << 16) | q_u:08X}\n")

total_stim = len(stimulus_i)
total_exp  = len(expected_i)
print(f"\nWrote {stim_path}  ({total_stim} ADC samples)")
print(f"Wrote {exp_path}  ({total_exp} output samples)")

# ---------------------------------------------------------------------------
# Write RRC coefficients file (for reference; not loaded by testbench)
# ---------------------------------------------------------------------------
coeff_path = os.path.join(SCRIPT_DIR, "rrc_coefficients.hex")
with open(coeff_path, "w") as f:
    for c in RRC_Q14:
        f.write(f"{int(c) & 0xFFFF:04X}\n")
print(f"Wrote {coeff_path}")

# ---------------------------------------------------------------------------
# Write manifest (for documentation; not parsed by testbench)
# ---------------------------------------------------------------------------
manifest_path = os.path.join(SCRIPT_DIR, "rx_frontend_manifest.txt")
with open(manifest_path, "w") as f:
    f.write("# rx_frontend test manifest — fixed-point reference\n")
    f.write(f"# CIC_R={CIC_R}  CIC_ORDER={CIC_ORDER}  CIC_TRUNC={CIC_TRUNC}\n")
    f.write(f"# RRC_TAPS={RRC_TAPS}  RRC_ACC_SHIFT={RRC_ACC_SHIFT}\n")
    f.write(f"# Decimation: y[R-1::R] — NOT y[::R]\n\n")
    f.write(f"MAX_STIM={total_stim}  # update localparam in tb_tetra_rx_frontend.v\n")
    f.write(f"MAX_EXP={total_exp}   # update localparam in tb_tetra_rx_frontend.v\n\n")
    stim_off, exp_off = 0, 0
    for label, adc_n, sym_n in test_labels:
        f.write(f"TEST {label}\n")
        f.write(f"  STIM_OFFSET={stim_off}  STIM_LEN={adc_n}\n")
        f.write(f"  EXP_OFFSET={exp_off}    EXP_LEN={sym_n}\n\n")
        stim_off += adc_n
        exp_off  += sym_n
print(f"Wrote {manifest_path}")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print("\n=== Summary ===")
print(f"CIC internal bit width : {CIC_BITS}")
print(f"CIC truncation shift   : {CIC_TRUNC}")
print(f"RRC acc output shift   : {RRC_ACC_SHIFT}")
print(f"sum(RRC_Q14)           : {int(np.sum(RRC_Q14))} (DC gain = {int(np.sum(RRC_Q14))/16384:.4f})")
print(f"Total stimulus samples : {total_stim}")
print(f"Total expected samples : {total_exp}")
print(f"\nTestbench localparams to match:")
print(f"  localparam MAX_STIM = {total_stim};")
print(f"  localparam MAX_EXP  = {total_exp};")
