#!/usr/bin/env python3
"""
gen_rrc_filter_vectors.py — TX RRC Polyphase Interpolation Filter Reference Vectors

Generates expected output values for tb_tetra_rrc_filter.v using the same
polyphase decomposition as the Verilog implementation:
  - 33-tap RRC filter, α=0.35, 4 samples/symbol
  - Polyphase: L=4, SR_DEPTH=9 symbols
  - Coefficients Q14 signed (identical to tetra_rx_frontend.v)

ETSI EN 300 392-2 §9.5
"""

# ============================================================
# Q14 RRC coefficients (same as tetra_rx_frontend.v localparams)
# ============================================================
H = [
     17,   109,   78,  -78, -209, -121,  210,  535,
    468,  -181, -1108, -1545, -694, 1696, 4979, 7844,
   8978,  7844, 4979, 1696, -694, -1545, -1108, -181,
    468,   535,  210, -121, -209,  -78,   78,  109,  17
]

L          = 4          # interpolation factor
SR_DEPTH   = 9          # ceil(33/4)
ACC_SHIFT  = 14         # Q14 fractional bits
IQ_MAX     = 32767
IQ_MIN     = -32768


def q14_shift(x):
    """Arithmetic right shift by 14 (floor division by 16384), matching Verilog >>>."""
    # Python integer >> is arithmetic (floor) for both positive and negative
    return x >> ACC_SHIFT


def saturate(x, width=16):
    """Saturate x to signed width-bit range."""
    lo = -(1 << (width-1))
    hi =  (1 << (width-1)) - 1
    if x > hi:
        return hi
    if x < lo:
        return lo
    return x


def polyphase_output(sr_i, sr_q, phase):
    """
    Compute one polyphase output sample for the given phase (0..3).
    sr_i, sr_q: lists of SR_DEPTH symbols, index 0 = newest.
    Returns (i_out, q_out).
    """
    acc_i = 0
    acc_q = 0
    for tap in range(SR_DEPTH):
        h_idx = phase + L * tap
        if h_idx < len(H):
            coeff = H[h_idx]
        else:
            coeff = 0   # zero pad for phases 1..3 at tap 8
        acc_i += coeff * sr_i[tap]
        acc_q += coeff * sr_q[tap]
    return saturate(q14_shift(acc_i)), saturate(q14_shift(acc_q))


def process_symbol(sym_sr_i, sym_sr_q):
    """Process one symbol: produce 4 output samples (phases 0..3)."""
    outputs = []
    for phase in range(L):
        oi, oq = polyphase_output(sym_sr_i, sym_sr_q, phase)
        outputs.append((oi, oq))
    return outputs


def run_filter(input_i, input_q):
    """
    Full filter simulation.
    input_i, input_q: lists of symbols (same length).
    Returns list of (i_out, q_out) — 4 entries per input symbol.
    """
    sr_i = [0] * SR_DEPTH
    sr_q = [0] * SR_DEPTH
    all_outputs = []
    for s_i, s_q in zip(input_i, input_q):
        # Shift in new symbol at position 0 (newest)
        sr_i = [s_i] + sr_i[:-1]
        sr_q = [s_q] + sr_q[:-1]
        # Produce 4 output samples
        all_outputs.extend(process_symbol(sr_i, sr_q))
    return all_outputs


# ============================================================
# Print reference vectors
# ============================================================
print("# gen_rrc_filter_vectors.py — TX RRC Polyphase Interpolation Reference Vectors")
print("# ETSI EN 300 392-2 §9.5, 33-tap RRC α=0.35, L=4 interpolation")
print()
print(f"# L={L}, SR_DEPTH={SR_DEPTH}, ACC_SHIFT={ACC_SHIFT}")
print(f"# Coefficients (H[0]..H[32]): {H}")
print()


def print_tc(name, input_i, input_q, note=""):
    print(f"# {'='*60}")
    print(f"# TC: {name}")
    if note:
        print(f"# {note}")
    print(f"# Input symbols ({len(input_i)}): I={input_i}")
    print(f"# {'Sym':>4} {'Phase':>6} {'I_out':>8} {'Q_out':>8}")
    outputs = run_filter(input_i, input_q)
    for n, (oi, oq) in enumerate(outputs):
        sym = n // L
        phase = n % L
        print(f"# {sym:4d}  ph={phase}  {oi:8d}  {oq:8d}")
    return outputs


# TC1: Single impulse — I=32767, rest zeros
tc1 = print_tc(
    "TC1_single_impulse_I32767",
    [32767] + [0]*8, [0]*9,
    "One non-zero symbol; I output impulse response"
)
print()

# TC2: Two identical symbols
tc2 = print_tc(
    "TC2_two_identical_I32767",
    [32767, 32767, 0, 0, 0, 0, 0, 0, 0], [0]*9,
    "Two impulses back-to-back"
)
print()

# TC3: 9 identical symbols (DC input)
tc3 = print_tc(
    "TC3_nine_identical_I32767",
    [32767]*9, [0]*9,
    "DC input: converges to DC gain of filter"
)
print()

# TC4: I=0, Q=32767 (pure Q input)
tc4 = print_tc(
    "TC4_single_impulse_Q32767",
    [0]*9, [32767] + [0]*8,
    "I=0, one Q impulse"
)
print()

# TC5: Alternating I=+/-32767 (stress test)
tc5_i = [32767 if k % 2 == 0 else -32767 for k in range(9)]
tc5 = print_tc(
    "TC5_alternating_pm32767",
    tc5_i, [0]*9,
    "Alternating ±32767 input symbols"
)
print()

# ============================================================
# Print polyphase coefficient sets for verification
# ============================================================
print("# Polyphase subfilter coefficients:")
for phase in range(L):
    coeffs = []
    for tap in range(SR_DEPTH):
        h_idx = phase + L * tap
        coeffs.append(H[h_idx] if h_idx < len(H) else 0)
    print(f"# Phase {phase}: {coeffs}")
print()

# ============================================================
# Inline testbench values (TC1, first 4 outputs)
# ============================================================
print("# TC1 first 4 outputs (symbol=32767, SR all zeros before):")
sr_i = [32767] + [0]*(SR_DEPTH-1)
sr_q = [0]*SR_DEPTH
for phase in range(L):
    oi, oq = polyphase_output(sr_i, sr_q, phase)
    acc_i = H[phase] * 32767   # only tap 0 contributes (others = 0)
    print(f"#   phase={phase}: h[{phase}]={H[phase]} * 32767 = {acc_i}; >>14 = {q14_shift(acc_i)}; sat = {oi}")
print()

print("# TC2 second symbol (32767, SR=[32767,32767,0,...,0]):")
sr_i2 = [32767, 32767] + [0]*(SR_DEPTH-2)
for phase in range(L):
    oi, oq = polyphase_output(sr_i2, [0]*SR_DEPTH, phase)
    c0 = H[phase + 0]
    c1 = H[phase + 4] if (phase + 4) < len(H) else 0
    acc_i = c0 * 32767 + c1 * 32767
    print(f"#   phase={phase}: (h[{phase}]={c0} + h[{phase+4}]={c1}) * 32767 = {acc_i}; >>14 = {q14_shift(acc_i)}; sat = {oi}")
print()
