#!/usr/bin/env python3
"""
gen_tx_frontend_vectors.py — Reference vectors for tetra_tx_frontend
TETRA PHY project — tetra-zynq-phy

Generates Python-side reference for CIC interpolation (R=64, N=5, M=1).

TC1: DC input (constant 1000 for I, 0 for Q)
TC2: Step input (0 → 1000 at sample 3)
TC3: Sine wave at 1 kHz (within TETRA 25 kHz channel BW)

The output is compared against the RTL output in the testbench.
Since the CIC has known gain (R^N = 2^30, compensated by >>30), the
DC output should equal the DC input after settling (N × R = 320 samples).
"""

import math

CIC_R = 64
CIC_N = 5
CIC_M = 1
CIC_SHIFT = 24   # effective gain for this interpolator structure = R^(N-1) = 64^4
IQ_WIDTH = 16

def cic_interpolate(samples_in, R=CIC_R, N=CIC_N, M=CIC_M, shift=CIC_SHIFT, width=IQ_WIDTH):
    """
    Software CIC interpolator:
      1. Comb section (N stages, M-delay differentiator)
      2. Upsample by R (zero insertion)
      3. Integrator section (N stages)
    Returns: list of (out_i, out_q) tuples
    """
    MAX_ACC = 2**(shift + width + 2)   # guard bits

    def comb_chain(samples, n, m):
        """Apply N cascaded M-delay differentiators."""
        out = list(samples)
        for _ in range(n):
            prev = [0] * m
            new_out = []
            for s in out:
                new_out.append(s - prev[0])
                prev = prev[1:] + [s]
            out = new_out
        return out

    def integrate_chain(samples, n):
        """Apply N cascaded integrators with wrap-around arithmetic."""
        out = list(samples)
        for _ in range(n):
            acc = 0
            new_out = []
            for s in out:
                acc = (acc + s) & (MAX_ACC - 1)
                # Sign-extend
                if acc >= MAX_ACC // 2:
                    acc -= MAX_ACC
                new_out.append(acc)
            out = new_out
        return out

    def upsample(samples, r):
        """Zero-insertion upsample by R."""
        out = []
        for s in samples:
            out.append(s)
            for _ in range(r - 1):
                out.append(0)
        return out

    # Step 1: separate I and Q
    i_in = [s[0] for s in samples_in]
    q_in = [s[1] for s in samples_in]

    # Step 2: Comb section
    i_comb = comb_chain(i_in, N, M)
    q_comb = comb_chain(q_in, N, M)

    # Step 3: Upsample
    i_up = upsample(i_comb, R)
    q_up = upsample(q_comb, R)

    # Step 4: Integrator section
    i_intg = integrate_chain(i_up, N)
    q_intg = integrate_chain(q_up, N)

    # Step 5: Scale (right-shift by shift, saturate)
    def scale_sat(samples, shift, width):
        out = []
        maxval = (1 << (width - 1)) - 1
        minval = -(1 << (width - 1))
        for s in samples:
            v = s >> shift
            out.append(max(minval, min(maxval, v)))
        return out

    i_out = scale_sat(i_intg, shift, width)
    q_out = scale_sat(q_intg, shift, width)

    return list(zip(i_out, q_out))


if __name__ == '__main__':
    import os
    out_dir = os.path.dirname(__file__)

    # ------------------------------------------------------------------
    # TC1: DC input I=1000, Q=0 (20 input samples → 1280 output samples)
    # After N*R=320 output samples, should settle to I=1000, Q=0
    # ------------------------------------------------------------------
    N_IN_TC1 = 20
    dc_in = [(1000, 0)] * N_IN_TC1
    dc_out = cic_interpolate(dc_in)

    print(f"TC1 DC input: I=1000, Q=0 × {N_IN_TC1} samples")
    print(f"  Output sample count: {len(dc_out)}")
    print(f"  Output[315..320]: {dc_out[315:321]}")
    print(f"  Output[1270..1280]: {dc_out[1270:1280]}")

    # Verify settling: last R outputs should be near 1000
    settled_i = [o[0] for o in dc_out[-CIC_R:]]
    settled_mean_i = sum(settled_i) / len(settled_i)
    print(f"  Settled mean I (last {CIC_R} samples): {settled_mean_i:.1f}  (exp: 1000)")

    # ------------------------------------------------------------------
    # TC2: Step input (0 → 1000 at sample 3)
    # ------------------------------------------------------------------
    step_in = [(0, 0)] * 3 + [(1000, 500)] * 17
    step_out = cic_interpolate(step_in)
    print(f"\nTC2 Step input: 3 zeros then (1000, 500) × 17")
    print(f"  Output[1150..1160] I: {[o[0] for o in step_out[1150:1160]]}")

    # ------------------------------------------------------------------
    # TC3: Check output count is exactly R × input count
    # ------------------------------------------------------------------
    test_in = [(i * 100, i * 50) for i in range(10)]
    test_out = cic_interpolate(test_in)
    print(f"\nTC3 Output count: {len(test_out)} == {CIC_R}×{len(test_in)}={CIC_R*len(test_in)}: "
          f"{'OK' if len(test_out) == CIC_R * len(test_in) else 'FAIL'}")

    # Write TC1 expected output for testbench comparison (last 64 samples)
    fname = os.path.join(out_dir, 'tx_frontend_tc1_expected.hex')
    with open(fname, 'w') as f:
        # Write last CIC_R output samples (should be settled to ~1000)
        for i_val, q_val in dc_out[-CIC_R:]:
            # Pack as 32-bit signed: {i[15:0], q[15:0]}
            i_s = i_val & 0xFFFF
            q_s = q_val & 0xFFFF
            f.write(f"{(i_s << 16) | q_s:08X}\n")
    print(f"\nWrote {fname} ({CIC_R} entries)")

    # Write a simple summary for the testbench
    fname2 = os.path.join(out_dir, 'tx_frontend_params.txt')
    with open(fname2, 'w') as f:
        f.write(f"CIC_R={CIC_R}\n")
        f.write(f"CIC_N={CIC_N}\n")
        f.write(f"CIC_SHIFT={CIC_SHIFT}\n")
        f.write(f"DC_INPUT=1000\n")
        f.write(f"DC_SETTLED_I={int(settled_mean_i)}\n")
    print(f"Wrote {fname2}")
