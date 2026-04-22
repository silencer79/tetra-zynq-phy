#!/usr/bin/env python3
"""gen_ul_demod_tv.py — IQ test vectors for UL integration TBs.

For each burst:
  1. Generate 92 info bits (first 8 = burst index, rest random).
  2. SCH/HU encode → 168 type-5 bits.
  3. π/4-DQPSK modulate using PHASE_MAP (b_msb,b_lsb)→Δφ.

Two output modes for two TBs:

  (a) tb_ul_demod_sch_hu — modules 2+3 (demod + sch_hu_decoder):
      `ul_demod_iq.hex` holds only the 86 symbol-rate IQ values per burst
      (2 halves × 43 syms).  No x-seq or tails.

  (b) tb_ul_full_chain — modules 1+2+3 (capture + demod + sch_hu_decoder):
      `ul_full_iq.hex` holds the complete 103-symbol CB burst at 4 sps
      (ZOH upsample), bracketed by silence so the capture ring fills:
        N_PRE zeros + 103 syms * 4 sps + N_POST zeros = N_SAMP_PER_BURST.
      Layout per symbol (sym-rate order):
        [0..1]  tail_pre  (arbitrary dibit, π/4 increment used)
        [2..43] CB1 data (42 syms from type5[0..83])
        [44..58] x-seq (15 ETSI §9.4.4.3.3 dibits)
        [59..100] CB2 data (42 syms from type5[84..167])
        [101..102] tail_post
      CB1 differential ref = symbol #1 (2nd tail). CB2 ref = x[14] = symbol #58.

Outputs (sim_out/):
  ul_demod_iq.hex   — NBURSTS * 86   symbols * 2 hex lines (I, Q)
  ul_full_iq.hex    — NBURSTS * (N_PRE + 103*4 + N_POST) samples * 2 hex lines
  ul_demod_exp.hex  — 13 bytes/burst: [crc_ok:1][info:12]  (shared)
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sch_hu_tv import encode_sch_hu
from decode_dl import make_scramb_code

INFO       = 92
SYMS_HALF  = 43     # 1 ref + 42 data
SYMS_BURST = 2 * SYMS_HALF  # 86
DIBITS_HALF = 42
AMPLITUDE   = 30000   # ~92% of 16-bit FS; demod MSB-slice needs A ≳ 28k for
                      # non-erasure soft values (see top4/diff in to_vit_soft)

# (b_msb, b_lsb) → phase increment
PHASE_MAP = {
    (0, 0): +np.pi / 4,
    (0, 1): +3 * np.pi / 4,
    (1, 1): -3 * np.pi / 4,
    (1, 0): -np.pi / 4,
}

# ETSI EN 300 392-2 §9.4.4.3.3 x-sequence (15 symbols = 30 bits). Same as
# `ETS_REF` in rtl/rx/tetra_ul_sync_detect_os4.v, MSB-first order.
ETS_DIBITS = [
    (1,0), (0,1), (1,1), (0,1), (0,0),
    (0,0), (1,1), (1,0), (1,0), (0,1),
    (1,1), (0,1), (0,0), (0,0), (1,1),
]

# Full-burst geometry (Table 9.3 UL CB)
SPS             = 4
FULL_SYMS       = 2 + 42 + 15 + 42 + 2   # 103
FULL_PRE_SMP    = 400   # pre-silence so capture ring (228 pre) always fills
FULL_POST_SMP   = 1200  # post-silence to let decoder pipeline finish
FULL_SMP_PER_BURST = FULL_PRE_SMP + FULL_SYMS * SPS + FULL_POST_SMP


def modulate_full_burst(type5_bits):
    """Full UL CB burst — 103 symbols of π/4-DQPSK at the symbol rate.
    Returns two int16 arrays (I, Q) of length FULL_SYMS.

    Dibit order per symbol group:
      [ 0..1 ]   2 pre-tail       (arbitrary → (0,0))
      [ 2..43]   CB1 data         from type5[0..83]
      [44..58]   x-seq (15 syms)  ETS_DIBITS
      [59..100]  CB2 data         from type5[84..167]
      [101..102] 2 post-tail      (arbitrary → (0,0))

    Phase accumulates continuously; CB1 differential ref = symbol #1 and
    CB2 differential ref = symbol #58 (x[14]) — both land naturally as the
    accumulator carries through."""
    assert len(type5_bits) == 168
    dibits = []
    dibits += [(0, 0)] * 2
    for k in range(42):
        dibits.append((type5_bits[2*k], type5_bits[2*k + 1]))
    dibits += ETS_DIBITS
    for k in range(42):
        idx = 84 + 2*k
        dibits.append((type5_bits[idx], type5_bits[idx + 1]))
    dibits += [(0, 0)] * 2
    assert len(dibits) == FULL_SYMS

    phase = 0.0
    I = np.zeros(FULL_SYMS, dtype=np.int32)
    Q = np.zeros(FULL_SYMS, dtype=np.int32)
    for n, db in enumerate(dibits):
        phase += PHASE_MAP[db]
        I[n] = int(round(AMPLITUDE * np.cos(phase)))
        Q[n] = int(round(AMPLITUDE * np.sin(phase)))
    return I.astype(np.int16), Q.astype(np.int16)


def modulate_burst(type5_bits):
    """168 bits → 86 IQ symbols (43 per half). Returns int16 arrays (I, Q)."""
    assert len(type5_bits) == 168
    I = np.zeros(SYMS_BURST, dtype=np.int32)
    Q = np.zeros(SYMS_BURST, dtype=np.int32)

    for half in range(2):
        base = half * SYMS_HALF
        # Reference symbol — arbitrary phase, pick 0 for half=0, π/4 for half=1
        ref_phase = 0.0 if half == 0 else np.pi / 4
        phase = ref_phase
        I[base]     = int(round(AMPLITUDE * np.cos(phase)))
        Q[base]     = int(round(AMPLITUDE * np.sin(phase)))
        bit_base    = half * 2 * DIBITS_HALF   # 0 or 84
        for k in range(DIBITS_HALF):
            b_msb = type5_bits[bit_base + 2 * k]
            b_lsb = type5_bits[bit_base + 2 * k + 1]
            phase += PHASE_MAP[(b_msb, b_lsb)]
            I[base + 1 + k] = int(round(AMPLITUDE * np.cos(phase)))
            Q[base + 1 + k] = int(round(AMPLITUDE * np.sin(phase)))
    return I.astype(np.int16), Q.astype(np.int16)


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--cc',  type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--out-dir',   default='sim_out')
    ap.add_argument('--n-bursts',  type=int, default=4)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'scramb_init = 0x{scramb_init:08X}')

    rng = np.random.default_rng(0xDEADBEEF)
    info_patterns = []
    for b in range(args.n_bursts):
        info = rng.integers(0, 2, size=INFO, dtype=np.int8).tolist()
        for i in range(8):
            info[i] = (b >> (7 - i)) & 1
        info_patterns.append(info)

    iq_lines   = []   # symbol-rate, 86 syms/burst
    full_lines = []   # 4-sps ZOH, FULL_SMP_PER_BURST samples/burst
    exp_lines  = []

    for b_idx, info in enumerate(info_patterns):
        type5 = encode_sch_hu(info, scramb_init)

        # --- mode (a) 86-symbol IQ (demod+sch_hu TB) -----------------------
        I, Q = modulate_burst(type5)
        for k in range(SYMS_BURST):
            iq_lines.append(f"{I[k] & 0xFFFF:04X}")
            iq_lines.append(f"{Q[k] & 0xFFFF:04X}")

        # --- mode (b) full-burst IQ @ 4 sps (full-chain TB) ----------------
        Ifull, Qfull = modulate_full_burst(type5)
        for _ in range(FULL_PRE_SMP):
            full_lines.append("0000")
            full_lines.append("0000")
        for n in range(FULL_SYMS):
            ihex = f"{Ifull[n] & 0xFFFF:04X}"
            qhex = f"{Qfull[n] & 0xFFFF:04X}"
            for _ in range(SPS):            # zero-order hold
                full_lines.append(ihex)
                full_lines.append(qhex)
        for _ in range(FULL_POST_SMP):
            full_lines.append("0000")
            full_lines.append("0000")

        # --- expected info (shared between both TBs) -----------------------
        info_bytes = []
        for bs in range(0, INFO, 8):
            byte = 0
            for k in range(8):
                byte = (byte << 1) | (info[bs + k] if bs + k < INFO else 0)
            info_bytes.append(byte)
        exp_lines.append('01 ' + ' '.join(f"{x:02X}" for x in info_bytes))

    iq_path   = os.path.join(args.out_dir, 'ul_demod_iq.hex')
    full_path = os.path.join(args.out_dir, 'ul_full_iq.hex')
    exp_path  = os.path.join(args.out_dir, 'ul_demod_exp.hex')
    with open(iq_path, 'w') as f:
        f.write('\n'.join(iq_lines) + '\n')
    with open(full_path, 'w') as f:
        f.write('\n'.join(full_lines) + '\n')
    with open(exp_path, 'w') as f:
        f.write('\n'.join(exp_lines) + '\n')

    print(f'wrote {iq_path}  ({len(iq_lines)} values '
          f'= {args.n_bursts} bursts × {SYMS_BURST}×2)')
    print(f'wrote {full_path}  ({len(full_lines)} values '
          f'= {args.n_bursts} bursts × {FULL_SMP_PER_BURST}×2)')
    print(f'wrote {exp_path}  ({args.n_bursts} records)')


if __name__ == '__main__':
    main()
