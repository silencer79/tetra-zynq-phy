#!/usr/bin/env python3
"""
Bit-accurate Python simulation of TETRA digital loopback path.
Models: pi4dqpsk_mod → TX_RRC → TX_CIC(×64) → RX_CIC(÷64) → RX_RRC → TR → demod → STS_corr

Goal: Find root cause of 50% STS correlation (9-10/19) in digital loopback.
"""
import numpy as np
import sys

# =============================================================================
# Constants
# =============================================================================
IQ_WIDTH = 16
MAX_VAL = (1 << (IQ_WIDTH - 1)) - 1   # 32767
MIN_VAL = -(1 << (IQ_WIDTH - 1))      # -32768

# RRC coefficients (Q14, from RTL)
RRC_H = np.array([
    17, 109, 78, -78, -209, -121, 210, 535, 468,
    -181, -1108, -1545, -694, 1696, 4979, 7844, 8978,
    7844, 4979, 1696, -694, -1545, -1108, -181, 468,
    535, 210, -121, -209, -78, 78, 109, 17
], dtype=np.int64)

RRC_ACC_SHIFT = 14

# STS training sequence (19 symbols, MSB-first = first transmitted)
STS_DIBITS = [
    0b11, 0b00, 0b00, 0b01, 0b10, 0b01, 0b11, 0b00,
    0b11, 0b10, 0b10, 0b01, 0b11, 0b00, 0b00, 0b01,
    0b10, 0b01, 0b11
]

# SDB burst structure (§8.2.3.1): 510 symbols total
# TAIL1(6)+HC(1)+FC(40)+sb1(60)+STS(19)+bb(15)+bkn2(108)+HD(1)+TAIL2(5) = 255 dibits??
# Actually: each "symbol" in TETRA is a dibit. SDB = 510 symbols.
# For simplicity, generate a test burst with known STS location.

# =============================================================================
# π/4-DQPSK Modulator (matches RTL tetra_pi4dqpsk_mod)
# =============================================================================
# Phase mapping per ETSI EN 300 392-2 §9.5
PHASE_MAP = {
    0b00: np.pi/4,     # +π/4
    0b01: 3*np.pi/4,   # +3π/4
    0b10: -np.pi/4,    # -π/4 (= 7π/4)
    0b11: -3*np.pi/4,  # -3π/4 (= 5π/4)
}

def pi4dqpsk_mod(dibits):
    """Modulate dibits to IQ samples (one sample per symbol)."""
    phase = 0.0  # accumulated phase
    i_out = []
    q_out = []
    for d in dibits:
        phase += PHASE_MAP[d]
        # Output as signed 16-bit integers (scale by 0.9 * 32767 to avoid clipping)
        scale = 0.9 * MAX_VAL
        i_val = int(round(np.cos(phase) * scale))
        q_val = int(round(np.sin(phase) * scale))
        i_val = max(MIN_VAL, min(MAX_VAL, i_val))
        q_val = max(MIN_VAL, min(MAX_VAL, q_val))
        i_out.append(i_val)
        q_out.append(q_val)
    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# TX RRC Filter — Polyphase ×4 interpolator (matches RTL tetra_rrc_filter)
# =============================================================================
def tx_rrc_filter(i_in, q_in):
    """
    Polyphase RRC interpolation ×4.
    For each input symbol, produce 4 output samples using polyphase decomposition.
    """
    # Polyphase decomposition of 33-tap filter into 4 phases of 9 taps each
    # Phase k uses coefficients h[k], h[k+4], h[k+8], ..., h[k+32]
    n_phases = 4
    taps_per_phase = 9  # ceil(33/4)

    # Build polyphase filter banks
    poly_h = np.zeros((n_phases, taps_per_phase), dtype=np.int64)
    for phase in range(n_phases):
        for tap in range(taps_per_phase):
            idx = phase + tap * n_phases
            if idx < len(RRC_H):
                poly_h[phase, tap] = RRC_H[idx]

    n_sym = len(i_in)
    i_out = []
    q_out = []

    # Symbol shift register (9 deep)
    sr_i = np.zeros(taps_per_phase, dtype=np.int64)
    sr_q = np.zeros(taps_per_phase, dtype=np.int64)

    for n in range(n_sym):
        # Shift in new symbol
        sr_i = np.roll(sr_i, 1)
        sr_i[0] = i_in[n]
        sr_q = np.roll(sr_q, 1)
        sr_q[0] = q_in[n]

        # Compute 4 phases
        for phase in range(n_phases):
            # MAC: sum of h[k]*sr[k] for k=0..8
            acc_i = np.sum(poly_h[phase] * sr_i)
            acc_q = np.sum(poly_h[phase] * sr_q)

            # Right-shift by RRC_ACC_SHIFT (Q14 → integer)
            out_i = acc_i >> RRC_ACC_SHIFT
            out_q = acc_q >> RRC_ACC_SHIFT

            # Saturate to 16-bit
            out_i = max(MIN_VAL, min(MAX_VAL, int(out_i)))
            out_q = max(MIN_VAL, min(MAX_VAL, int(out_q)))

            i_out.append(out_i)
            q_out.append(out_q)

    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# CIC Interpolator ×64, Order 5 (matches RTL tetra_tx_frontend)
# =============================================================================
def tx_cic_interp(i_in, q_in, R=64, N=5, CIC_SHIFT=24, CIC_ACC_BITS=48):
    """
    CIC interpolator: comb → zero-stuff → integrate.
    R=64, N=5, gain = R^(N-1) = 64^4 = 2^24.
    Output shift: CIC_SHIFT=24.
    """
    n_in = len(i_in)

    # Comb section (N stages, at input rate)
    # Each comb: y[n] = x[n] - x[n-1]
    comb_i = [np.zeros(1, dtype=np.int64) for _ in range(N+1)]
    comb_q = [np.zeros(1, dtype=np.int64) for _ in range(N+1)]
    comb_delay_i = [np.int64(0)] * N
    comb_delay_q = [np.int64(0)] * N

    # Integrator state (N stages)
    intg_i = [np.int64(0)] * N
    intg_q = [np.int64(0)] * N

    i_out = []
    q_out = []

    for n in range(n_in):
        # Comb section at input rate
        ci = np.int64(i_in[n])
        cq = np.int64(q_in[n])
        for s in range(N):
            prev_ci, prev_cq = ci, cq
            ci = ci - comb_delay_i[s]
            cq = cq - comb_delay_q[s]
            comb_delay_i[s] = prev_ci
            comb_delay_q[s] = prev_cq

        # Zero-stuff and integrate: insert comb output at position 0, zeros elsewhere
        for k in range(R):
            inp_i = ci if k == 0 else np.int64(0)
            inp_q = cq if k == 0 else np.int64(0)

            for s in range(N):
                if s == 0:
                    intg_i[s] = intg_i[s] + inp_i
                    intg_q[s] = intg_q[s] + inp_q
                else:
                    intg_i[s] = intg_i[s] + intg_i[s-1]
                    intg_q[s] = intg_q[s] + intg_q[s-1]

            # Output: shift and saturate
            oi = int(intg_i[N-1]) >> CIC_SHIFT
            oq = int(intg_q[N-1]) >> CIC_SHIFT
            oi = max(MIN_VAL, min(MAX_VAL, oi))
            oq = max(MIN_VAL, min(MAX_VAL, oq))
            i_out.append(oi)
            q_out.append(oq)

    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# CIC Decimator ÷64, Order 5 (matches RTL tetra_rx_frontend)
# =============================================================================
def rx_cic_decim(i_in, q_in, R=64, N=5, loopback=True):
    """
    CIC decimator: integrate → decimate → comb.
    R=64, N=5, gain = R^N = 64^5 = 2^30.
    Output: bits [45:30] for loopback (unity gain), bits [45:24] for RF (×64 gain).
    """
    CIC_BITS = 46  # 16 + 5*6
    CIC_TRUNC = 30  # = CIC_BITS - IQ_WIDTH
    CIC_GAIN_SHF = 6
    CIC_OUT_LOW = CIC_TRUNC - CIC_GAIN_SHF  # 24

    n_in = len(i_in)

    # Integrators (N stages, at input rate)
    intg_i = [np.int64(0)] * N
    intg_q = [np.int64(0)] * N

    # Comb section (N stages, at decimated rate)
    comb_delay_i = [np.int64(0)] * N
    comb_delay_q = [np.int64(0)] * N

    i_out = []
    q_out = []

    dec_cnt = 0

    for n in range(n_in):
        # Sign-extend input to CIC_BITS (Python ints are arbitrary precision, but
        # we simulate 46-bit wrapping)
        xi = np.int64(i_in[n])
        xq = np.int64(q_in[n])

        # Integrators at input rate
        for s in range(N):
            if s == 0:
                intg_i[s] = intg_i[s] + xi
                intg_q[s] = intg_q[s] + xq
            else:
                intg_i[s] = intg_i[s] + intg_i[s-1]
                intg_q[s] = intg_q[s] + intg_q[s-1]

        dec_cnt += 1
        if dec_cnt == R:
            dec_cnt = 0

            # Comb section at decimated rate
            ci = intg_i[N-1]
            cq = intg_q[N-1]
            for s in range(N):
                prev_ci, prev_cq = ci, cq
                ci = ci - comb_delay_i[s]
                cq = cq - comb_delay_q[s]
                comb_delay_i[s] = prev_ci
                comb_delay_q[s] = prev_cq

            # Output extraction
            if loopback:
                # Unity gain: bits [45:30] = top 16 bits after removing R^N gain
                oi = int(ci) >> CIC_TRUNC
                oq = int(cq) >> CIC_TRUNC
            else:
                # RF mode: bits [45:24] with saturation
                oi = int(ci) >> CIC_OUT_LOW
                oq = int(cq) >> CIC_OUT_LOW

            # Saturate to IQ_WIDTH
            oi = max(MIN_VAL, min(MAX_VAL, oi))
            oq = max(MIN_VAL, min(MAX_VAL, oq))

            i_out.append(oi)
            q_out.append(oq)

    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# RX RRC Filter — 33-tap sequential MAC (matches RTL tetra_rx_frontend)
# =============================================================================
def rx_rrc_filter(i_in, q_in):
    """Direct-form FIR, 33-tap RRC matched filter, Q14 coefficients."""
    n_in = len(i_in)
    sr_i = np.zeros(33, dtype=np.int64)
    sr_q = np.zeros(33, dtype=np.int64)
    i_out = []
    q_out = []

    for n in range(n_in):
        # Shift left (oldest exits at top, newest enters at bottom)
        sr_i[1:] = sr_i[:-1]
        sr_i[0] = i_in[n]
        sr_q[1:] = sr_q[:-1]
        sr_q[0] = q_in[n]

        # MAC
        acc_i = np.sum(RRC_H * sr_i)
        acc_q = np.sum(RRC_H * sr_q)

        # Right-shift by RRC_ACC_SHIFT
        oi = int(acc_i) >> RRC_ACC_SHIFT
        oq = int(acc_q) >> RRC_ACC_SHIFT

        # Saturate
        oi = max(MIN_VAL, min(MAX_VAL, oi))
        oq = max(MIN_VAL, min(MAX_VAL, oq))

        i_out.append(oi)
        q_out.append(oq)

    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# Gardner Timing Recovery (simplified — matches RTL tetra_timing_recovery)
# =============================================================================
def timing_recovery_ideal(i_in, q_in, sps=4):
    """
    Ideal timing recovery: brute-force best sampling offset.
    """
    n = len(i_in)
    best_energy = -1
    best_offset = 0
    skip = 32 * sps

    for offset in range(sps):
        indices = np.arange(skip + offset, n, sps)
        if len(indices) == 0:
            continue
        energy = np.sum(i_in[indices]**2 + q_in[indices]**2)
        if energy > best_energy:
            best_energy = energy
            best_offset = offset

    indices = np.arange(best_offset, n, sps)
    return i_in[indices], q_in[indices]


def timing_recovery(i_in, q_in, sps=4, verbose=False):
    """
    Gardner TED with NCO — matches RTL tetra_timing_recovery.
    NCO_NOMINAL = 2^30 (for sps=4, overflows 32-bit NCO every 4 samples).
    KP_SHIFT=8, KI_SHIFT=12.
    LOCK_THRESH=256, LOCK_COUNT=144.
    """
    NCO_WIDTH = 32
    NCO_NOMINAL = 1 << 30   # 0x40000000
    NCO_MAX = (1 << NCO_WIDTH) - 1
    KP_SHIFT = 8
    KI_SHIFT = 12
    LOCK_THRESH = 256
    LOCK_COUNT = 144

    n = len(i_in)

    # NCO state
    nco_phase = np.uint32(0)
    nco_freq = np.uint32(NCO_NOMINAL)

    # Gardner TED state: need current, mid, and previous symbol samples
    # The NCO overflow generates symbol strobes; the midpoint is the sample
    # halfway between two consecutive overflows.
    prev_i = np.int64(0)
    prev_q = np.int64(0)
    mid_i = np.int64(0)
    mid_q = np.int64(0)
    curr_i = np.int64(0)
    curr_q = np.int64(0)

    # Sample counter within symbol (0..3 nominally)
    sample_cnt = 0
    last_overflow = False

    i_out = []
    q_out = []

    # Track TED values for diagnostics
    ted_values = []
    lock_counter = 0
    locked = False
    sym_count = 0

    for k in range(n):
        # NCO update
        old_phase = int(nco_phase)
        new_phase = (old_phase + int(nco_freq)) & NCO_MAX
        overflow = new_phase < old_phase  # MSB rollover
        nco_phase = np.uint32(new_phase)

        # Track samples for Gardner TED
        # NCO overflows mark symbol points; midpoint is when bit 31 transitions
        msb_curr = (new_phase >> 31) & 1
        msb_prev = (old_phase >> 31) & 1
        midpoint = (msb_curr != msb_prev) and not overflow

        if midpoint:
            mid_i = i_in[k]
            mid_q = q_in[k]

        if overflow:
            prev_i = curr_i
            prev_q = curr_q
            curr_i = i_in[k]
            curr_q = q_in[k]

            # Output symbol sample
            i_out.append(int(curr_i))
            q_out.append(int(curr_q))
            sym_count += 1

            # Gardner TED: e = (prev - curr) * mid
            # For complex signal: e_i = (prev_i - curr_i) * mid_i + (prev_q - curr_q) * mid_q
            ted_i = int(prev_i - curr_i) * int(mid_i) + int(prev_q - curr_q) * int(mid_q)
            # Scale to 16-bit range
            ted = ted_i >> 16  # rough scaling

            ted_values.append(ted)

            # PI loop filter
            kp_term = ted >> KP_SHIFT
            ki_term = ted >> KI_SHIFT

            # Update NCO frequency (integral term)
            new_freq = int(nco_freq) + ki_term
            new_freq = max(0, min(NCO_MAX, new_freq))
            nco_freq = np.uint32(new_freq)

            # Update NCO phase (proportional term — adjust current phase)
            adj_phase = (int(nco_phase) + kp_term) & NCO_MAX
            nco_phase = np.uint32(adj_phase)

            # Lock detection
            if abs(ted) < LOCK_THRESH:
                lock_counter = min(lock_counter + 1, LOCK_COUNT + 1)
            else:
                lock_counter = 0
            locked = lock_counter >= LOCK_COUNT

            if verbose and sym_count <= 60:
                print(f"    TR[{sym_count:3d}] ted={ted:6d} freq=0x{int(nco_freq):08X} "
                      f"lock_cnt={lock_counter:3d} {'LOCKED' if locked else ''}")

    if verbose:
        print(f"    Total symbols: {sym_count}, locked at sample: "
              f"{next((i for i,v in enumerate(ted_values) if abs(v) < LOCK_THRESH), 'never')}")
        if ted_values:
            abs_ted = [abs(v) for v in ted_values]
            print(f"    TED range: [{min(ted_values)}, {max(ted_values)}], "
                  f"final 20 avg abs: {np.mean(abs_ted[-20:]):.1f}")

    return np.array(i_out, dtype=np.int64), np.array(q_out, dtype=np.int64)


# =============================================================================
# π/4-DQPSK Demodulator (matches RTL tetra_pi4dqpsk_demod)
# =============================================================================
def pi4dqpsk_demod(i_in, q_in):
    """Differential demodulation: compute phase difference between consecutive symbols."""
    n = len(i_in)
    dibits = []

    for k in range(1, n):
        # Phase of current and previous symbol
        phase_curr = np.arctan2(float(q_in[k]), float(i_in[k]))
        phase_prev = np.arctan2(float(q_in[k-1]), float(i_in[k-1]))

        # Phase difference
        dphase = phase_curr - phase_prev
        # Normalize to [-π, π]
        while dphase > np.pi:
            dphase -= 2*np.pi
        while dphase < -np.pi:
            dphase += 2*np.pi

        # Map to dibit (same as RTL)
        # +π/4 (0..π/2)     → 00
        # +3π/4 (π/2..π)    → 01
        # -π/4 (-π/2..0)    → 10
        # -3π/4 (-π..-π/2)  → 11
        if 0 <= dphase < np.pi/2:
            dibits.append(0b00)
        elif np.pi/2 <= dphase <= np.pi:
            dibits.append(0b01)
        elif -np.pi/2 <= dphase < 0:
            dibits.append(0b10)
        else:  # -π <= dphase < -π/2
            dibits.append(0b11)

    return dibits


# =============================================================================
# STS Correlation
# =============================================================================
def sts_correlate(dibits, sts=STS_DIBITS):
    """Sliding window correlation with STS. Returns (max_corr, position)."""
    n_sts = len(sts)
    max_corr = 0
    max_pos = 0
    all_corr = []

    for i in range(len(dibits) - n_sts + 1):
        window = dibits[i:i+n_sts]
        corr = sum(1 for a, b in zip(window, sts) if a == b)
        all_corr.append(corr)
        if corr > max_corr:
            max_corr = corr
            max_pos = i

    return max_corr, max_pos, all_corr


# =============================================================================
# Generate test burst
# =============================================================================
def generate_sdb_burst():
    """
    Generate a simplified SDB burst with known data.
    Structure: TAIL(6) + pad(121) + STS(19) + pad(109) = 255 symbols
    """
    # TAIL1: 6 symbols, all zero
    tail1 = [0b11] * 6

    # Padding before STS (HC=1 + FC=40 + sb1=60 = 101 dibits, plus adjust for exact STS position)
    # In SDB: STS starts at symbol position 127 (0-indexed)
    # TAIL1(6) + HC(1) + FC(40) + sb1(60) + STS(19) + bb(15) + bkn2(108) + HD(1) + TAIL2(5)
    # Total: 6+1+40+60+19+15+108+1+5 = 255

    hc = [0b00]  # 1 symbol
    fc = [0b10] * 40  # 40 symbols (dummy)
    sb1 = [0b01] * 60  # 60 symbols (dummy)
    sts = STS_DIBITS  # 19 symbols
    bb = [0b00] * 15  # 15 symbols (dummy)
    bkn2 = [0b11] * 108  # 108 symbols (dummy)
    hd = [0b00]  # 1 symbol
    tail2 = [0b11] * 5  # 5 symbols

    burst = tail1 + hc + fc + sb1 + sts + bb + bkn2 + hd + tail2
    assert len(burst) == 255, f"Burst length {len(burst)} != 255"

    return burst


# =============================================================================
# Main simulation
# =============================================================================
def main():
    print("=" * 70)
    print("TETRA Digital Loopback Simulation")
    print("=" * 70)

    # Generate 4 bursts (need multiple for sync detection)
    burst = generate_sdb_burst()
    # Inter-burst gap: 255 symbols per slot, no gap in continuous mode
    all_dibits = burst * 4  # 4 bursts, 1020 symbols total
    n_sym = len(all_dibits)
    print(f"\nInput: {n_sym} symbols ({n_sym//255} bursts)")

    # STS position within burst: after TAIL1(6)+HC(1)+FC(40)+sb1(60) = 107
    sts_pos = 107
    print(f"STS position in burst: symbol {sts_pos}")

    # ---- Step 1: π/4-DQPSK Modulation ----
    mod_i, mod_q = pi4dqpsk_mod(all_dibits)
    print(f"\n1. Modulator: {len(mod_i)} IQ samples")
    print(f"   Amplitude range: I=[{mod_i.min()}, {mod_i.max()}], Q=[{mod_q.min()}, {mod_q.max()}]")

    # ---- Step 2: TX RRC (×4 interpolation) ----
    rrc_i, rrc_q = tx_rrc_filter(mod_i, mod_q)
    print(f"\n2. TX RRC: {len(rrc_i)} samples (×4)")
    print(f"   Amplitude range: I=[{rrc_i.min()}, {rrc_i.max()}], Q=[{rrc_q.min()}, {rrc_q.max()}]")

    # ---- Bypass path: skip CIC pair, go straight to timing recovery ----
    print("\n--- BYPASS PATH (no CIC, no RX RRC) ---")
    print("  Gardner TED:")
    bp_i, bp_q = timing_recovery(rrc_i, rrc_q, sps=4, verbose=True)
    print(f"3b. Timing recovery: {len(bp_i)} symbols")
    bp_dibits = pi4dqpsk_demod(bp_i, bp_q)
    print(f"4b. Demodulator: {len(bp_dibits)} dibits")
    bp_corr, bp_pos, bp_all = sts_correlate(bp_dibits)
    print(f"5b. STS correlation: max={bp_corr}/19 at position {bp_pos}")
    bp_high = [(i, c) for i, c in enumerate(bp_all) if c >= 15]
    print(f"    Positions with corr>=15: {bp_high[:10]}")

    # Also check with ideal timing recovery
    bp_ideal_i, bp_ideal_q = timing_recovery_ideal(rrc_i, rrc_q, sps=4)
    bp_ideal_dibits = pi4dqpsk_demod(bp_ideal_i, bp_ideal_q)
    bp_ideal_corr, _, _ = sts_correlate(bp_ideal_dibits)
    print(f"    (Ideal TR: {bp_ideal_corr}/19)")

    # ---- Full loopback path ----
    print("\n--- FULL LOOPBACK PATH (TX_CIC → RX_CIC → RX_RRC) ---")

    # Step 3: TX CIC interpolation ×64
    cic_tx_i, cic_tx_q = tx_cic_interp(rrc_i, rrc_q, R=64, N=5, CIC_SHIFT=24)
    print(f"\n3. TX CIC: {len(cic_tx_i)} samples (×64)")
    print(f"   Amplitude range: I=[{cic_tx_i.min()}, {cic_tx_i.max()}], Q=[{cic_tx_q.min()}, {cic_tx_q.max()}]")

    # Step 4: RX CIC decimation ÷64 (loopback mode = unity gain)
    cic_rx_i, cic_rx_q = rx_cic_decim(cic_tx_i, cic_tx_q, R=64, N=5, loopback=True)
    print(f"\n4. RX CIC: {len(cic_rx_i)} samples (÷64)")
    print(f"   Amplitude range: I=[{cic_rx_i.min()}, {cic_rx_i.max()}], Q=[{cic_rx_q.min()}, {cic_rx_q.max()}]")

    # Compare CIC roundtrip to TX RRC output
    min_len = min(len(rrc_i), len(cic_rx_i))
    # CIC pair has group delay — find alignment by cross-correlation
    if min_len > 100:
        # Find the delay
        max_cc = 0
        best_delay = 0
        for d in range(0, min(200, min_len)):
            cc = np.sum(rrc_i[0:min_len-d].astype(float) * cic_rx_i[d:min_len].astype(float))
            if cc > max_cc:
                max_cc = cc
                best_delay = d
        print(f"   CIC pair group delay: ~{best_delay} samples")

        # Compare aligned samples
        if best_delay > 0 and best_delay < min_len - 100:
            diff_i = rrc_i[0:min_len-best_delay] - cic_rx_i[best_delay:min_len]
            rms_diff = np.sqrt(np.mean(diff_i.astype(float)**2))
            rms_sig = np.sqrt(np.mean(rrc_i[0:min_len-best_delay].astype(float)**2))
            print(f"   CIC roundtrip RMS error: {rms_diff:.1f} (signal RMS: {rms_sig:.1f})")
            print(f"   SNR: {20*np.log10(rms_sig/max(rms_diff, 1)):.1f} dB")

    # Step 5: RX RRC filter
    rx_rrc_i, rx_rrc_q = rx_rrc_filter(cic_rx_i, cic_rx_q)
    print(f"\n5. RX RRC: {len(rx_rrc_i)} samples")
    print(f"   Amplitude range: I=[{rx_rrc_i.min()}, {rx_rrc_i.max()}], Q=[{rx_rrc_q.min()}, {rx_rrc_q.max()}]")

    # Step 6: Timing recovery (Gardner TED)
    print("\n6. Timing recovery (Gardner TED):")
    tr_i, tr_q = timing_recovery(rx_rrc_i, rx_rrc_q, sps=4, verbose=True)
    print(f"   Output: {len(tr_i)} symbols")

    # Step 7: Demodulation
    fl_dibits = pi4dqpsk_demod(tr_i, tr_q)
    print(f"\n7. Demodulator: {len(fl_dibits)} dibits")

    # Step 8: STS correlation
    fl_corr, fl_pos, fl_all = sts_correlate(fl_dibits)
    print(f"\n8. STS correlation: max={fl_corr}/19 at position {fl_pos}")
    fl_high = [(i, c) for i, c in enumerate(fl_all) if c >= 10]
    print(f"   Positions with corr>=10: {fl_high[:20]}")

    # Also with ideal timing recovery
    tr_ideal_i, tr_ideal_q = timing_recovery_ideal(rx_rrc_i, rx_rrc_q, sps=4)
    fl_ideal_dibits = pi4dqpsk_demod(tr_ideal_i, tr_ideal_q)
    fl_ideal_corr, _, _ = sts_correlate(fl_ideal_dibits)
    print(f"   (Ideal TR: {fl_ideal_corr}/19)")

    # ---- Also try full path WITHOUT RX RRC ----
    print("\n--- FULL PATH WITHOUT RX RRC (TX_CIC → RX_CIC → TR → demod) ---")
    tr2_i, tr2_q = timing_recovery(cic_rx_i, cic_rx_q, sps=4)
    fl2_dibits = pi4dqpsk_demod(tr2_i, tr2_q)
    fl2_corr, fl2_pos, fl2_all = sts_correlate(fl2_dibits)
    print(f"   STS correlation: max={fl2_corr}/19 at position {fl2_pos}")
    fl2_high = [(i, c) for i, c in enumerate(fl2_all) if c >= 10]
    print(f"   Positions with corr>=10: {fl2_high[:20]}")

    # ---- Diagnostic: compare bypass and full path dibits ----
    print("\n--- DIBIT COMPARISON (first burst, around STS) ---")
    # In bypass path, STS should be near position sts_pos-1 (demod produces n-1 dibits)
    # Account for filter group delays
    if len(bp_dibits) > sts_pos + 19 and len(fl_dibits) > 50:
        print(f"Bypass STS region (pos {sts_pos-5} to {sts_pos+25}):")
        region = bp_dibits[max(0,sts_pos-5):sts_pos+25]
        print(f"  {''.join(format(d, '02b') for d in region)}")
        print(f"Expected STS:  {''.join(format(d, '02b') for d in STS_DIBITS)}")

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"Bypass path:          STS max corr = {bp_corr}/19")
    print(f"Full path (with RRC): STS max corr = {fl_corr}/19")
    print(f"Full path (no RRC):   STS max corr = {fl2_corr}/19")

    if fl_corr < 15:
        print(f"\n*** PROBLEM REPRODUCED: Full path correlation {fl_corr}/19 < 15/19 ***")
        if fl2_corr >= 15:
            print("*** ROOT CAUSE: RX RRC filter is corrupting the signal ***")
        elif bp_corr >= 15 and fl2_corr < 15:
            print("*** ROOT CAUSE: CIC pair is corrupting the signal ***")
        else:
            print("*** Need further investigation ***")
    else:
        print(f"\nFull path works in Python sim ({fl_corr}/19) — issue may be in:")
        print("  - RTL-specific bit-width truncation")
        print("  - CDC FIFO timing")
        print("  - Hardware-specific clock domain effects")


if __name__ == "__main__":
    main()
