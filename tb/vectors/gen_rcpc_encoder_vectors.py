#!/usr/bin/env python3
"""
gen_rcpc_encoder_vectors.py — TETRA RCPC Encoder Test Vector Generator

Rate 1/3 mother code, K=5, Constraint Length 5, 16 states
Generator polynomials (octal): G1=33 (0x1B), G2=31 (0x19), G3=25 (0x15)
  G1 = 0b11011 — taps: input,sr[3],sr[1],sr[0]
  G2 = 0b11001 — taps: input,sr[3],sr[0]
  G3 = 0b10101 — taps: input,sr[2],sr[0]

State convention: sr[3]=newest, sr[0]=oldest
Transition: new_sr = {input, sr[3:1]}  (matches tetra_viterbi_decoder.v)

ETSI EN 300 392-2 §8.2.3
"""

G1 = 0x1B  # 0b11011
G2 = 0x19  # 0b11001
G3 = 0x15  # 0b10101
K  = 5


def encode_bit(sr, bit):
    """
    Encode one bit.
    sr: 4-bit integer, sr[3]=newest stored, sr[0]=oldest stored
    Returns (new_sr, g1_out, g2_out, g3_out)
    Full 5-bit register: (bit << 4) | sr
    """
    full_sr = (bit << 4) | sr
    g1_out  = bin(full_sr & G1).count('1') & 1
    g2_out  = bin(full_sr & G2).count('1') & 1
    g3_out  = bin(full_sr & G3).count('1') & 1
    new_sr  = (full_sr >> 1) & 0xF   # shift right: bit absorbed into sr[3]
    return (new_sr, g1_out, g2_out, g3_out)


def encode_block(data_bits, tail=True):
    """
    Encode list of bits. If tail=True, append K-1=4 zero tail bits.
    Returns list of (g1, g2, g3) tuples and final state.
    """
    sr = 0
    output = []
    bits = list(data_bits)
    if tail:
        bits += [0] * (K - 1)
    for bit in bits:
        sr, g1, g2, g3 = encode_bit(sr, bit)
        output.append((g1, g2, g3))
    return output, sr


def puncture_rate2_3(triplets):
    """Rate 2/3: keep G1,G2 per triplet; drop G3. Returns list of (g1,g2) pairs."""
    return [(g1, g2) for (g1, g2, g3) in triplets]


# ---------------------------------------------------------------------------
# Print test cases
# ---------------------------------------------------------------------------

def print_separator():
    print("# " + "=" * 60)


def print_trellis_table():
    """Full trellis table for hardware verification."""
    print_separator()
    print("# Trellis transition table (state, input) -> (next_state, g1, g2, g3)")
    print("# Format: state inp -> next  G1 G2 G3")
    for s in range(16):
        for inp in range(2):
            ns, g1, g2, g3 = encode_bit(s, inp)
            print(f"# {s:2d}  {inp}  ->  {ns:2d}   {g1}  {g2}  {g3}")


def run_tc(name, data_bits, tail=True, punct=None):
    """
    Run one test case and print expected results.
    punct: None = no puncturing; '2/3' = rate 2/3
    Returns (coded_triplets_with_tail, final_sr)
    """
    triplets, final_sr = encode_block(data_bits, tail=tail)
    print_separator()
    print(f"# Test Case: {name}")
    print(f"# Input ({len(data_bits)} bits): {''.join(str(b) for b in data_bits)}")
    if tail:
        n_tail = K - 1
        n_total = len(data_bits) + n_tail
        print(f"# With {n_tail} tail bits: {n_total} total trellis stages")
    else:
        print(f"# No tail bits: {len(data_bits)} trellis stages")
    print(f"# Final SR state: {final_sr} (0x{final_sr:X})"
          + ("  [OK: returned to 0]" if final_sr == 0 and tail else ""))
    print("#")
    print("# Encoded output (1 cycle latency — output appears cycle AFTER input):")
    print("# Stage  Input  G1  G2  G3  coded_bits[2:0]={G3,G2,G1}")
    for i, (g1, g2, g3) in enumerate(triplets):
        input_bit = data_bits[i] if i < len(data_bits) else 0
        tag = "  [tail]" if i >= len(data_bits) else ""
        coded = (g3 << 2) | (g2 << 1) | g1
        print(f"# {i:3d}     {input_bit}      {g1}   {g2}   {g3}   3'b{coded:03b}{tag}")
    if punct == '2/3':
        pairs = puncture_rate2_3(triplets)
        print("#")
        print("# Rate 2/3 punctured output (drop G3): punct_out_bits={G2,G1}")
        for i, (g1, g2) in enumerate(pairs):
            punct_bits = (g2 << 1) | g1
            print(f"# {i:3d}  punct_out_bits = 2'b{punct_bits:02b}")
    return triplets, final_sr


# ---------------------------------------------------------------------------
# TC1: Short block [1,0,1,1] — no tail, simple verification
# ---------------------------------------------------------------------------
run_tc("TC1_short_4bit_no_tail",
       [1, 0, 1, 1],
       tail=False)

# ---------------------------------------------------------------------------
# TC2: Short block [1,0,1,1] + 4 tail zeros (full flush)
# ---------------------------------------------------------------------------
run_tc("TC2_short_4bit_with_tail",
       [1, 0, 1, 1],
       tail=True)

# ---------------------------------------------------------------------------
# TC3: All-zeros block (8 bits) — output should be all zeros
# ---------------------------------------------------------------------------
run_tc("TC3_all_zeros_8bit",
       [0] * 8,
       tail=False)

# ---------------------------------------------------------------------------
# TC4: All-ones block (8 bits)
# ---------------------------------------------------------------------------
run_tc("TC4_all_ones_8bit",
       [1] * 8,
       tail=False)

# ---------------------------------------------------------------------------
# TC5: 8-bit block, rate 2/3 puncturing
# ---------------------------------------------------------------------------
run_tc("TC5_8bit_rate2_3",
       [1, 0, 1, 1, 0, 1, 0, 0],
       tail=False,
       punct='2/3')

# ---------------------------------------------------------------------------
# TC6: Longer block 16 bits with tail — verify SR returns to 0
# ---------------------------------------------------------------------------
run_tc("TC6_16bit_with_tail",
       [1,1,0,1,0,1,0,0,1,0,1,1,0,0,1,0],
       tail=True)

# ---------------------------------------------------------------------------
# TC7: NDB-sized block (216 bits of alternating pattern) + tail
# ---------------------------------------------------------------------------
data7 = [(i & 1) for i in range(216)]
run_tc("TC7_ndb_216bit_alternating_with_tail",
       data7,
       tail=True)

# ---------------------------------------------------------------------------
# Full trellis table
# ---------------------------------------------------------------------------
print()
print_trellis_table()

# ---------------------------------------------------------------------------
# Summary of key expected values for testbench inline use
# ---------------------------------------------------------------------------
print()
print_separator()
print("# KEY VALUES FOR INLINE TESTBENCH VERIFICATION:")
print("#")
print("# TC1: Input [1,0,1,1], SR start=0, no tail")
sr = 0
for bit in [1, 0, 1, 1]:
    sr, g1, g2, g3 = encode_bit(sr, bit)
    coded = (g3 << 2) | (g2 << 1) | g1
    print(f"#   in={bit} -> coded_bits=3'b{coded:03b} (G3G2G1={g3}{g2}{g1}), new_sr={sr}")

print("#")
print("# TC2: Flush after [1,0,1,1] — 4 tail zeros, final_sr must be 0")
sr_after_data = 0
for bit in [1, 0, 1, 1]:
    sr_after_data, _, _, _ = encode_bit(sr_after_data, bit)
print(f"#   SR after data = {sr_after_data} (0x{sr_after_data:X})")
sr = sr_after_data
print(f"#   Tail zeros starting from SR={sr}:")
for i in range(K - 1):
    sr, g1, g2, g3 = encode_bit(sr, 0)
    coded = (g3 << 2) | (g2 << 1) | g1
    print(f"#     tail[{i}]: coded_bits=3'b{coded:03b}, new_sr={sr}")
print(f"#   Final SR={sr} {'[PASS: returned to 0]' if sr == 0 else '[FAIL!]'}")
