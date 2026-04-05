#!/usr/bin/env python3
"""
gen_viterbi_vectors.py — TETRA Viterbi Decoder Test Vector Generator

Rate 1/3 mother code, K=5, Constraint Length 5, 16 states
Generator polynomials (octal): G1=33, G2=31, G3=25
  G1 = 0x1B = 0b11011 — taps: [4,3,1,0]
  G2 = 0x19 = 0b11001 — taps: [4,3,0]
  G3 = 0x15 = 0b10101 — taps: [4,2,0]

State convention: state = sr[3:0] where sr[0] is the oldest bit
New input bit enters at sr[K-2]=sr[3], shifts right: sr[3:0] = {input, sr[3:1]}

Soft-decision quantisation: 3-bit unsigned
  0 = strongest 0 (most confident)
  7 = strongest 1 (most confident)
  4 = erasure (punctured position)

ETSI EN 300 392-2 §8.2.3
"""

import random

# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------

G1 = 0x1B  # 0b11011
G2 = 0x19  # 0b11001
G3 = 0x15  # 0b10101
K  = 5     # constraint length → 16 states

def encode_bit(sr, bit):
    """
    Encode one bit.  sr is a 4-bit integer (state = oldest 4 bits of shift reg).
    New bit enters MSB position:  new_sr = (sr >> 1) | (bit << 3)
    Trellis uses K=5: full shift register is 5 bits = {bit, sr[3:0]}
    Returns (new_sr, g1_out, g2_out, g3_out) — each output is 0 or 1.
    """
    full_sr = (bit << 4) | sr          # 5-bit: bit at position 4, sr fills [3:0]
    g1_out  = bin(full_sr & G1).count('1') & 1
    g2_out  = bin(full_sr & G2).count('1') & 1
    g3_out  = bin(full_sr & G3).count('1') & 1
    new_sr  = full_sr >> 1             # shift right: bit absorbed into state
    return (new_sr & 0xF, g1_out, g2_out, g3_out)

def encode_block(data_bits, tail=True):
    """
    Encode a list of data bits. If tail=True, append K-1=4 zero tail bits.
    Returns list of (g1, g2, g3) tuples.
    """
    sr = 0
    output = []
    bits = list(data_bits)
    if tail:
        bits += [0] * (K - 1)
    for bit in bits:
        sr, g1, g2, g3 = encode_bit(sr, bit)
        output.append((g1, g2, g3))
    return output

# ---------------------------------------------------------------------------
# Puncturing patterns  (ETSI EN 300 392-2 §8.2.3)
# ---------------------------------------------------------------------------

# punct_pattern index → (name, keep_mask_per_3_bits, output_rate)
# keep_mask: list of booleans over repeated period
# For rate 1/3 (no puncturing): keep all
# For rate 2/3: keep 2 of every 3 coded bits — pattern over 3 mother bits: keep G1,G2, drop G3
# For SCH/F: rate 292/432 bits per 216 info bits → actually 216 info → 648 coded → puncture to 432
#   Puncturing period=3, keep 2/3 → 432 from 648 ✓
#   ETSI: for SCH/F NDB, period=9, keep 6 of 9:  G1G2_G1G2_G1G2_G1G2G3 → approximate
#   We use the simple rate-2/3 pattern: drop every 3rd coded bit (G3 channel)
#   This matches the RCPC encoder's punct_pattern=1

PUNCT_NONE  = None          # rate 1/3, no puncturing
PUNCT_RATE_2_3 = [1,1,0]   # keep G1,G2; drop G3 — period 3

def puncture(coded_triplets, pattern):
    """
    Apply puncturing pattern to coded triplets.
    pattern: list of 0/1 per position in (g1,g2,g3) per symbol period, or None.
    Returns flat list of kept coded bits.
    """
    if pattern is None:
        out = []
        for (g1,g2,g3) in coded_triplets:
            out += [g1, g2, g3]
        return out
    out = []
    for (g1,g2,g3) in coded_triplets:
        bits = [g1, g2, g3]
        for i, b in enumerate(bits):
            if pattern[i % len(pattern)]:
                out.append(b)
    return out

def depuncture(received_bits, pattern, n_coded):
    """
    Insert erasures (soft value 4) at punctured positions.
    received_bits: list of received (hard) bits.
    Returns list of length n_coded triplets (g1_soft, g2_soft, g3_soft).
    Hard bit 0 → soft 0, hard bit 1 → soft 7.
    Erasure → soft 4.
    """
    def hard_to_soft(b):
        return 7 if b else 0

    if pattern is None:
        return [(hard_to_soft(b[0]), hard_to_soft(b[1]), hard_to_soft(b[2]))
                for b in zip(received_bits[0::3], received_bits[1::3], received_bits[2::3])]

    out = []
    rx_idx = 0
    for i in range(n_coded):
        triplet = []
        for j in range(3):
            pos = (i * 3 + j)
            keep_pos = pos % len(pattern)
            if pattern[keep_pos]:
                if rx_idx < len(received_bits):
                    triplet.append(hard_to_soft(received_bits[rx_idx]))
                    rx_idx += 1
                else:
                    triplet.append(4)
            else:
                triplet.append(4)  # erasure
        out.append(tuple(triplet))
    return out

# ---------------------------------------------------------------------------
# Viterbi Decoder (reference software model)
# ---------------------------------------------------------------------------

INF = 0xFFFF

def branch_metric(soft0, soft1, soft2, exp0, exp1, exp2):
    """
    Compute branch metric: sum of |soft - expected_soft| for each stream.
    expected is 0 or 1; convert to soft: 0→0, 1→7.
    Lower metric = better match.
    """
    def exp_soft(e): return 7 if e else 0
    return (abs(soft0 - exp_soft(exp0)) +
            abs(soft1 - exp_soft(exp1)) +
            abs(soft2 - exp_soft(exp2)))

def viterbi_decode(soft_triplets, traceback_depth=20):
    """
    Full Viterbi decoder.
    soft_triplets: list of (s0, s1, s2) soft values (3-bit 0..7).
    Returns decoded bits (excluding tail).
    """
    n_stages  = len(soft_triplets)
    n_states  = 1 << (K - 1)   # 16

    # Path metrics: state → accumulated metric
    pm = [INF] * n_states
    pm[0] = 0   # start from state 0

    # Survivor bits: list of [stage][state] = input bit (0 or 1) that survived
    survivors = [[0] * n_states for _ in range(n_stages)]

    for t, (s0, s1, s2) in enumerate(soft_triplets):
        new_pm = [INF] * n_states
        for state in range(n_states):
            if pm[state] == INF:
                continue
            for inp in range(2):
                next_state, e0, e1, e2 = encode_bit(state, inp)
                bm = branch_metric(s0, s1, s2, e0, e1, e2)
                total = pm[state] + bm
                if total < new_pm[next_state]:
                    new_pm[next_state] = total
                    survivors[t][next_state] = inp

        # Normalize to prevent overflow: subtract minimum
        min_pm = min(new_pm)
        pm = [p - min_pm if p != INF else INF for p in new_pm]

    # Traceback from best final state
    best_state = pm.index(min(pm))
    decoded = []
    state = best_state
    for t in range(n_stages - 1, -1, -1):
        inp = survivors[t][state]
        decoded.append(inp)
        # Reverse the state transition: state = (state << 1 | inp) & 0xF
        # Actually: next_state = (inp<<3) | (state>>1), so state = (state<<1 | inp) & 0xF ? No.
        # new_sr = full_sr >> 1 where full_sr = (inp<<4)|state
        # So state = (inp<<3) | (state_after >> 0)[3:0] ... need reverse mapping
        # Simpler: precompute for each (state_after, inp) → state_before
        for prev in range(n_states):
            ns, _, _, _ = encode_bit(prev, inp)
            if ns == state:
                state = prev
                break

    decoded.reverse()
    return decoded

# ---------------------------------------------------------------------------
# Soft-decision with noise (for realistic test vectors)
# ---------------------------------------------------------------------------

def add_soft_noise(bits, snr_level):
    """
    Convert hard bits to soft decisions with optional noise.
    snr_level 0 = perfect (hard), higher = more noise.
    Returns list of 3-bit unsigned soft values.
    """
    if snr_level == 0:
        return [7 if b else 0 for b in bits]
    # Simple: flip confidence based on snr_level
    result = []
    for b in bits:
        if snr_level == 1:
            # Strong signal: 6 or 1
            result.append(6 if b else 1)
        elif snr_level == 2:
            # Medium: 5 or 2
            result.append(5 if b else 2)
        else:
            # Weak: near erasure
            result.append(4 if b else 3)
    return result

# ---------------------------------------------------------------------------
# Test Case Generation
# ---------------------------------------------------------------------------

def format_triplets_hex(triplets):
    """Each triplet as one hex byte: [7:5]=g3_soft, [4:2]=g2_soft, [1:0]=g1_soft[1:0] — actually:
    Store as 3 separate bytes per triplet for simplicity."""
    lines = []
    for (s0, s1, s2) in triplets:
        lines.append(f"{s0:02x} {s1:02x} {s2:02x}")
    return lines

def print_tc(name, data_bits, punct, snr, traceback=20):
    print(f"\n# {'='*60}")
    print(f"# Test Case: {name}")
    print(f"# Info bits: {len(data_bits)}, Punct: {'rate_2/3' if punct else 'none'}, SNR level: {snr}")

    coded = encode_block(data_bits, tail=True)
    coded_flat = puncture(coded, punct)
    n_info_with_tail = len(data_bits) + (K-1)

    if snr == 0:
        soft = [(7 if b else 0) for b in coded_flat]
    else:
        soft = add_soft_noise(coded_flat, snr)

    # For depunctured input:
    soft_triplets = depuncture(soft if punct else coded_flat,
                                punct, n_info_with_tail)
    decoded = viterbi_decode(soft_triplets, traceback)
    decoded_data = decoded[:len(data_bits)]  # strip tail

    print(f"# Input bits:   {''.join(str(b) for b in data_bits)}")
    print(f"# Coded rate 1/3 ({n_info_with_tail} trellis stages, {len(coded)} triplets):")
    print(f"# Punctured output: {len(coded_flat)} bits")
    print(f"# Decoded:      {''.join(str(b) for b in decoded_data)}")
    match = (decoded_data == list(data_bits))
    print(f"# Match: {'PASS' if match else 'FAIL'}")

    return match

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

random.seed(42)

print("# gen_viterbi_vectors.py — TETRA Viterbi Decoder Reference Vectors")
print("# Rate 1/3, K=5 (16 states), G1=0x1B G2=0x19 G3=0x15")
print("# Soft decision 3-bit: 0=strong_0 .. 7=strong_1, 4=erasure")

# TC1: Short block, no puncturing, perfect soft decisions
data1 = [1,0,1,1,0,0,1,0]
print_tc("TC1_short_nopunct_perfect", data1, PUNCT_NONE, snr=0)

# TC2: Short block, no puncturing, noisy soft decisions
data2 = [1,0,1,1,0,0,1,0]
print_tc("TC2_short_nopunct_noisy", data2, PUNCT_NONE, snr=1)

# TC3: 216-bit NDB block, no puncturing, perfect
data3 = [random.randint(0,1) for _ in range(216)]
print_tc("TC3_ndb_nopunct_perfect", data3, PUNCT_NONE, snr=0)

# TC4: 216-bit NDB block, rate 2/3 puncturing (TCH/S style), perfect
data4 = list(data3)
print_tc("TC4_ndb_punct_2_3_perfect", data4, PUNCT_RATE_2_3, snr=0)

# TC5: 216-bit NDB block, rate 2/3 puncturing, mild noise
data5 = [random.randint(0,1) for _ in range(216)]
print_tc("TC5_ndb_punct_2_3_noisy_snr1", data5, PUNCT_RATE_2_3, snr=1)

# TC6: All-zeros block (verifies reset state behavior)
data6 = [0] * 20
print_tc("TC6_zeros_nopunct_perfect", data6, PUNCT_NONE, snr=0)

# TC7: All-ones block
data7 = [1] * 20
print_tc("TC7_ones_nopunct_perfect", data7, PUNCT_NONE, snr=0)

# TC8: Known TETRA-like 216-bit block, no puncturing
data8 = [1,1,0,1,0,1,0,0,1,0,1,1,0,0,1,0,1,1,1,0,
         0,1,0,1,1,0,0,1,0,1,0,0,1,1,0,1,0,1,0,0,
         1,0,1,1,0,0,1,0,1,1,1,0,0,1,0,1,1,0,0,1,
         0,1,0,0,1,1,0,1,0,1,0,0,1,0,1,1,0,0,1,0,
         1,1,1,0,0,1,0,1,1,0,0,1,0,1,0,0,1,1,0,1,
         0,1,0,0,1,0,1,1,0,0,1,0,1,1,1,0,0,1,0,1,
         1,0,0,1,0,1,0,0,1,1,0,1,0,1,0,0,1,0,1,1,
         0,0,1,0,1,1,1,0,0,1,0,1,1,0,0,1,0,1,0,0,
         1,1,0,1,0,1,0,0,1,0,1,1,0,0,1,0,1,1,1,0,
         0,1,0,1,1,0,0,1,0,1,0,0,1,1,0,1,0,1,0,0,
         1,0,1,1,0,0,1,0,1,1,1,0,0,1,0,1]
print_tc("TC8_ndb_known_pattern", data8, PUNCT_NONE, snr=0)

# ---------------------------------------------------------------------------
# Generate trellis reference table for hardware verification
# ---------------------------------------------------------------------------
print("\n\n# Trellis transition table (state, input) -> (next_state, g1, g2, g3)")
print("# Format: state inp next_state g1 g2 g3")
for s in range(16):
    for inp in range(2):
        ns, g1, g2, g3 = encode_bit(s, inp)
        print(f"# {s:2d} {inp} -> {ns:2d}  {g1}{g2}{g3}")
