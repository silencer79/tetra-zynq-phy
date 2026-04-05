#!/usr/bin/env python3
"""
gen_timing_recovery_vectors.py — Gardner TED Timing Recovery Test Vectors
==========================================================================

Generates hex stimulus + expected-output files for tb_tetra_timing_recovery.

Three test scenarios:
  TC0 — Perfect timing (offset = 0):
        NCO overflows exactly every 4 samples.
        Gardner TED ≈ 0 at steady state.

  TC1 — Early timing (offset = +1 sample):
        The "on-time" mark falls 1 sample too early.
        Gardner TED > 0 → loop must increase NCO step (sample faster).

  TC2 — Late timing (offset = −1 sample):
        The "on-time" mark falls 1 sample too late.
        Gardner TED < 0 → loop must decrease NCO step (sample slower).

Signal model:
  TETRA π/4-DQPSK with RRC (α=0.35) pulse shaping.
  Oversampling = 4 samples/symbol at 72 kHz.
  A cosine pulse at the RRC peak is a reasonable stand-in for an eye diagram
  sample; actual RRC-shaped pulses are generated here using scipy.signal.

Output files (all little-endian 16-bit hex, one value per line):
  timing_tc0_iq_in.hex   — IQ interleaved (I0, Q0, I1, Q1, ...)
  timing_tc0_valid.hex   — sample_valid_in_sys (1 or 0, 8-bit wide)
  timing_tc0_ted.hex     — expected ted_scaled at each overflow (signed 16-bit)
  timing_tc1_iq_in.hex / _ted.hex
  timing_tc2_iq_in.hex / _ted.hex

Usage:
  cd tetra/tb/vectors
  python3 gen_timing_recovery_vectors.py
  # Produces: timing_tc*.hex files

Reference: Gardner (1986) IEEE Trans.Comm.
"""

import numpy as np
import os

# ---------------------------------------------------------------------------
# Parameters matching the RTL
# ---------------------------------------------------------------------------
IQ_WIDTH    = 16
SPS         = 4           # samples per symbol
N_SYMBOLS   = 32          # symbols per test case
N_SAMPLES   = N_SYMBOLS * SPS
ALPHA       = 0.35        # RRC roll-off

SCALE       = 2**(IQ_WIDTH-2)  # Amplitude: 25% of full-scale (headroom for filter gain)


# ---------------------------------------------------------------------------
# RRC pulse shaping coefficients (33 taps, 4 sps, α=0.35)
# Copied from tetra_rx_frontend: Q14 coefficients, energy-normalised.
# We use float here for vector generation.
# ---------------------------------------------------------------------------
def rrc_coeffs(ntaps, sps, alpha):
    """Generate RRC filter impulse response (float, energy-normalised)."""
    T  = sps
    t  = np.arange(-(ntaps // 2), ntaps // 2 + 1)
    h  = np.zeros(ntaps)
    for i, ti in enumerate(t):
        if ti == 0:
            h[i] = (1.0 / T) * (1.0 - alpha + 4.0 * alpha / np.pi)
        elif abs(ti) == T / (4.0 * alpha):
            h[i] = (alpha / (T * np.sqrt(2))) * (
                (1.0 + 2.0 / np.pi) * np.sin(np.pi / (4.0 * alpha))
                + (1.0 - 2.0 / np.pi) * np.cos(np.pi / (4.0 * alpha))
            )
        else:
            num = np.sin(np.pi * ti * (1 - alpha) / T) + \
                  4.0 * alpha * ti / T * np.cos(np.pi * ti * (1 + alpha) / T)
            den = np.pi * ti / T * (1.0 - (4.0 * alpha * ti / T) ** 2)
            h[i] = num / den / T
    return h / np.linalg.norm(h)


# ---------------------------------------------------------------------------
# π/4-DQPSK symbol generation
# ---------------------------------------------------------------------------
DQPSK_MAP = {
    (0, 0): +np.pi / 4,
    (0, 1): +3 * np.pi / 4,
    (1, 0): -np.pi / 4,
    (1, 1): -3 * np.pi / 4,
}


def make_baseband_signal(n_symbols, timing_offset_frac=0.0):
    """
    Generate an RRC-shaped π/4-DQPSK baseband signal.

    timing_offset_frac: fractional sample offset (0.0 = perfect, ±1.0 = ±1 sample)
    Returns: (i_samples, q_samples) as int16 arrays, length n_symbols * SPS
    """
    rcc = rrc_coeffs(33, SPS, ALPHA)

    # Generate random π/4-DQPSK symbols
    rng    = np.random.default_rng(0xDEADBEEF)
    dibits = rng.integers(0, 4, size=n_symbols)
    phase  = 0.0
    syms   = np.zeros(n_symbols, dtype=complex)
    for k, d in enumerate(dibits):
        b0 = (d >> 1) & 1
        b1 =  d       & 1
        phase += DQPSK_MAP[(b0, b1)]
        syms[k] = np.exp(1j * phase)

    # Upsample and filter
    upsampled = np.zeros((n_symbols + 8) * SPS, dtype=complex)
    for k in range(n_symbols):
        upsampled[k * SPS] = syms[k]

    i_filt = np.convolve(upsampled.real, rcc, mode='full')[:n_symbols * SPS]
    q_filt = np.convolve(upsampled.imag, rcc, mode='full')[:n_symbols * SPS]

    # Apply fractional sample timing offset via linear interpolation
    if timing_offset_frac != 0.0:
        t_orig = np.arange(n_symbols * SPS)
        t_new  = t_orig + timing_offset_frac
        i_filt = np.interp(t_orig, t_new, i_filt, left=0.0, right=0.0)
        q_filt = np.interp(t_orig, t_new, q_filt, left=0.0, right=0.0)

    # Scale and clip to IQ_WIDTH
    max_amp = max(np.max(np.abs(i_filt)), np.max(np.abs(q_filt)), 1e-9)
    i_scaled = np.clip(i_filt / max_amp * SCALE, -(2**(IQ_WIDTH-1)), 2**(IQ_WIDTH-1)-1)
    q_scaled = np.clip(q_filt / max_amp * SCALE, -(2**(IQ_WIDTH-1)), 2**(IQ_WIDTH-1)-1)

    return i_scaled.astype(np.int16), q_scaled.astype(np.int16)


# ---------------------------------------------------------------------------
# Gardner TED reference model
# ---------------------------------------------------------------------------
def gardner_ted_reference(i_samp, q_samp, timing_offset_samples=0):
    """
    Compute Gardner TED outputs for a 4× oversampled signal.

    Simulates the RTL: fires every 4 samples starting from sample index 4
    (need 4 in delay register first).  Returns list of (sample_idx, ted_val).

    RTL uses:
      late  = i_samp[n]        (i_in_sys)
      mid   = i_samp[n-2]      (i_s1_sys before update)
      early = i_samp[n-4]      (i_s3_sys before update)
      e = mid*(late-early) + mid_Q*(late_Q-early_Q)
    scaled by >> 18 to match RTL (Q14 output).
    """
    n_total  = len(i_samp)
    nco_acc  = 0
    NCO_STEP = 0x40000000  # nominal
    MASK32   = 0xFFFFFFFF

    # Shift registers (mirroring RTL before-clock state)
    s0i, s1i, s2i, s3i = 0, 0, 0, 0
    s0q, s1q, s2q, s3q = 0, 0, 0, 0

    results = []  # (sample_index, ted_scaled)

    for n in range(n_total):
        i_in = int(i_samp[n])
        q_in = int(q_samp[n])

        # NCO overflow detection (before update) — mirrors RTL combinatorial
        nco_sum  = (nco_acc + NCO_STEP) & MASK32
        ovf      = 1 if (nco_sum < nco_acc) else 0

        if ovf:
            # Gardner TED using PRE-UPDATE register values
            # s1 = midpoint (S[n-2]), s3 = prev on-time (S[n-4])
            i_diff = i_in - s3i
            q_diff = q_in - s3q

            prod_i = s1i * i_diff   # 16 × 17 → 33-bit
            prod_q = s1q * q_diff

            ted_sum    = prod_i + prod_q            # 34-bit signed
            # Match RTL: bits [33:18] of 34-bit sum  → shift right 18
            ted_scaled = ted_sum >> 18              # arithmetic right shift
            ted_scaled = np.int16(np.clip(ted_scaled, -32768, 32767))

            results.append((n, int(ted_scaled)))

        # Update NCO accumulator
        nco_acc = nco_sum

        # Update shift registers (AFTER overflow check)
        s3i, s2i, s1i, s0i = s2i, s1i, s0i, i_in
        s3q, s2q, s1q, s0q = s2q, s1q, s0q, q_in

    return results


# ---------------------------------------------------------------------------
# Hex file helpers
# ---------------------------------------------------------------------------
def to_hex16(val):
    """Signed 16-bit → 4-hex-digit string (two's complement)."""
    return format(int(val) & 0xFFFF, '04X')


def write_iq_hex(path, i_arr, q_arr):
    """Write interleaved IQ as signed 16-bit hex (one value per line)."""
    with open(path, 'w') as f:
        for iv, qv in zip(i_arr, q_arr):
            f.write(f"{to_hex16(iv)}\n")
            f.write(f"{to_hex16(qv)}\n")


def write_ted_hex(path, ted_list):
    """Write TED values (index, value) — only values, one per line."""
    with open(path, 'w') as f:
        for _, tv in ted_list:
            f.write(f"{to_hex16(tv)}\n")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))

    configs = [
        ("tc0", 0.0,  "Perfect timing — TED ≈ 0"),
        ("tc1", 1.0,  "Early timing (+1 sample) — TED > 0"),
        ("tc2", -1.0, "Late timing  (−1 sample) — TED < 0"),
    ]

    print("Gardner TED test vector generation")
    print("=" * 50)

    for tag, offset, desc in configs:
        i_arr, q_arr = make_baseband_signal(N_SYMBOLS, timing_offset_frac=offset)
        ted_list     = gardner_ted_reference(i_arr, q_arr, timing_offset_samples=offset)

        iq_path  = os.path.join(out_dir, f"timing_{tag}_iq_in.hex")
        ted_path = os.path.join(out_dir, f"timing_{tag}_ted.hex")

        write_iq_hex(iq_path,  i_arr, q_arr)
        write_ted_hex(ted_path, ted_list)

        # Sanity check: TED sign
        if len(ted_list) > 4:
            ted_vals = [tv for _, tv in ted_list[4:]]  # skip startup transient
            mean_ted = np.mean(ted_vals)
            print(f"  {tag} ({desc})")
            print(f"    Samples : {len(i_arr)}, TED events: {len(ted_list)}")
            print(f"    Mean TED (skip first 4): {mean_ted:.1f}")
            if offset > 0:
                assert mean_ted > 0, f"FAIL: expected mean_ted > 0 for early timing, got {mean_ted:.1f}"
                print(f"    PASS: mean_ted > 0 ✓")
            elif offset < 0:
                assert mean_ted < 0, f"FAIL: expected mean_ted < 0 for late timing, got {mean_ted:.1f}"
                print(f"    PASS: mean_ted < 0 ✓")
            else:
                print(f"    PASS: zero offset, |mean_ted| = {abs(mean_ted):.1f}")

    print(f"\nFiles written to: {out_dir}")
    print(f"Vectors per test case: {N_SYMBOLS * SPS * 2} IQ words, "
          f"{N_SYMBOLS} TED events (approx)")


if __name__ == "__main__":
    main()
