#!/usr/bin/env python3
"""
gen_reed_muller_vectors.py — TETRA (30,14) Reed-Muller test vector generator
ETSI EN 300 392-2 §8.2.4.1 — AACH/ACCH Broadcast Block Codec

Generator matrix G derived from RM(2,5) = (32,16,8) by shortening:
  - Remove rows 0 (constant "1") and 1 (x0) from RM(2,5) → 14 basis rows remaining
  - Remove columns 0 and 1 (evaluation points 00000 and 00001) → 30-bit codewords
  Shortening (not puncturing) preserves d_min ≥ 8.

Remaining basis rows (ETSI bit ordering: row 0 = LSB of message):
  row 0: x1         row 4: x0*x1     row  8: x1*x2
  row 1: x2         row 5: x0*x2     row  9: x1*x3
  row 2: x3         row 6: x0*x3     row 10: x1*x4
  row 3: x4         row 7: x0*x4     row 11: x2*x3
                                      row 12: x2*x4
                                      row 13: x3*x4

⚠ IMPORTANT: Verify G matrix against ETSI EN 300 392-2 §8.2.4.1 before use.
  This code is TETRA-compatible only if the G matrix matches the ETSI table.
  Replace G_ROWS with ETSI values if different. d_min check below verifies
  the mathematical properties but not ETSI bit-ordering.

Usage:
    python3 gen_reed_muller_vectors.py
    (run from tetra-zynq-phy project root)
"""

import sys
import os

# ---------------------------------------------------------------------------
# Generator matrix: 14 rows × 30 columns
# Derived from RM(2,5) as described in the file header.
# Values = (G_RM25_row_i >> 2) & 0x3FFFFFFF  for i in 2..15
# ⚠ Replace with ETSI EN 300 392-2 §8.2.4.1 table values if different.
# ---------------------------------------------------------------------------
N = 30   # code length
K = 14   # information bits

G_ROWS = [
    0x33333333,  # row  0: x1        (RM(2,5) row 2  >> 2)
    0x3C3C3C3C,  # row  1: x2        (RM(2,5) row 3  >> 2)
    0x3FC03FC0,  # row  2: x3        (RM(2,5) row 4  >> 2)
    0x3FFFC000,  # row  3: x4        (RM(2,5) row 5  >> 2)
    0x22222222,  # row  4: x0*x1     (RM(2,5) row 6  >> 2)
    0x28282828,  # row  5: x0*x2     (RM(2,5) row 7  >> 2)
    0x2A802A80,  # row  6: x0*x3     (RM(2,5) row 8  >> 2)
    0x2AAA8000,  # row  7: x0*x4     (RM(2,5) row 9  >> 2)
    0x30303030,  # row  8: x1*x2     (RM(2,5) row 10 >> 2)
    0x33003300,  # row  9: x1*x3     (RM(2,5) row 11 >> 2)
    0x33330000,  # row 10: x1*x4     (RM(2,5) row 12 >> 2)
    0x3C003C00,  # row 11: x2*x3     (RM(2,5) row 13 >> 2)
    0x3C3C0000,  # row 12: x2*x4     (RM(2,5) row 14 >> 2)
    0x3FC00000,  # row 13: x3*x4     (RM(2,5) row 15 >> 2)
]

MASK = (1 << N) - 1
T_MAX = 3   # floor((d_min - 1) / 2) = floor(7/2) = 3 correctable errors

# ---------------------------------------------------------------------------
# Encoder / decoder
# ---------------------------------------------------------------------------
def encode(m_int):
    """Encode K-bit integer m_int → N-bit codeword."""
    c = 0
    for i in range(K):
        if (m_int >> i) & 1:
            c ^= G_ROWS[i]
    return c & MASK

def hamming_weight(v):
    return bin(v).count('1')

def hamming_distance(a, b):
    return hamming_weight(a ^ b)

def decode(r_int):
    """Minimum-distance hard-decision decoder over all 2^K candidates."""
    best_m    = 0
    best_dist = N + 1
    for m in range(1 << K):
        c = encode(m)
        d = hamming_distance(c, r_int)
        if d < best_dist:
            best_dist = d
            best_m    = m
            if d == 0:
                break
    return best_m, best_dist

# ---------------------------------------------------------------------------
# Step 1: Verify RM(2,5) construction consistency
# ---------------------------------------------------------------------------
def build_rm25_row(row_idx):
    """Build the row_idx-th basis vector of RM(2,5) at all 32 evaluation points."""
    n = 32
    bases = []
    bases.append([1] * n)                                    # constant
    for i in range(5):                                       # x0..x4
        bases.append([(pt >> i) & 1 for pt in range(n)])
    for i in range(5):                                       # x0x1..x3x4
        for j in range(i+1, 5):
            bases.append([((pt>>i)&1) & ((pt>>j)&1) for pt in range(n)])
    row = bases[row_idx]
    val = sum(row[b] << b for b in range(n))
    return val

print("=== TETRA (30,14) Reed-Muller Code Verification ===")
print(f"N={N}, K={K}, T_MAX={T_MAX}")
print()

# Verify our G_ROWS match the RM(2,5) derivation
rm25_derived = [(build_rm25_row(i+2) >> 2) & MASK for i in range(K)]
mismatch = [(i, rm25_derived[i], G_ROWS[i])
            for i in range(K) if rm25_derived[i] != G_ROWS[i]]
if mismatch:
    print("ERROR: G_ROWS do not match RM(2,5) derivation!")
    for i, expected, got in mismatch:
        print(f"  row {i}: expected 0x{expected:08X}, got 0x{got:08X}")
    sys.exit(1)
print("✓ G_ROWS match RM(2,5) shortening derivation")

# ---------------------------------------------------------------------------
# Step 2: Verify minimum distance over all 2^K nonzero codewords
# ---------------------------------------------------------------------------
print("Checking minimum distance over all 16383 nonzero codewords...")
d_min = N
for m in range(1, 1 << K):
    c = encode(m)
    w = hamming_weight(c)
    if w < d_min:
        d_min = w

if d_min >= 8:
    print(f"✓ d_min = {d_min}  (need ≥ 8, t_max = {T_MAX})")
else:
    print(f"✗ d_min = {d_min} — WRONG, expected ≥ 8. Check G matrix!")
    print("  Do not use these vectors for synthesis.")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Step 3: Verify linear independence (rank = K)
# ---------------------------------------------------------------------------
def gf2_rank(rows):
    """Compute rank of matrix over GF(2) (rows as integers)."""
    pivot = 0
    r = list(rows)
    for col in range(N - 1, -1, -1):
        found = -1
        for row in range(pivot, len(r)):
            if (r[row] >> col) & 1:
                found = row
                break
        if found == -1:
            continue
        r[pivot], r[found] = r[found], r[pivot]
        for row in range(len(r)):
            if row != pivot and (r[row] >> col) & 1:
                r[row] ^= r[pivot]
        pivot += 1
    return pivot

rank = gf2_rank(G_ROWS)
if rank == K:
    print(f"✓ G matrix rank = {rank} (full rank, all rows independent)")
else:
    print(f"✗ G matrix rank = {rank} (expected {K}) — rows are linearly dependent!")
    sys.exit(1)

print()
print("G matrix (30-bit hex) — copy into tetra_reed_muller.v G_ROW localparams:")
for i, row in enumerate(G_ROWS):
    print(f"  G_ROW{i:02d} = 30'h{row:08X};")
print()

# ---------------------------------------------------------------------------
# Step 4: Generate test vectors
# ---------------------------------------------------------------------------
print("Generating test vectors...")

# Format: list of (m_int, r_int, expected_out, expect_error_flag, description)
# For encoder TCs: r_int = encode(m_int) (no errors injected)
# For decoder TCs: r_int may have bit-errors; expected_out = correct m_int
tc_list = []

# TC0: zero message
tc_list.append((0x0000, encode(0x0000), 0x0000, 0, "zero message (all-zero codeword)"))

# TC1..14: single-bit messages — each exercises one G matrix row
for i in range(K):
    m  = 1 << i
    c  = encode(m)
    tc_list.append((m, c, m, 0, f"single-bit m[{i}] → codeword=0x{c:08X}"))

# TC15: all-ones message
m_all = (1 << K) - 1
c_all = encode(m_all)
tc_list.append((m_all, c_all, m_all, 0, "all-ones message"))

# TC16: arbitrary message, no errors
m16 = 0x1234 & MASK
c16 = encode(m16)
tc_list.append((m16, c16, m16, 0, "no-error round-trip"))

# TC17: 1-bit error on bit 7
m17 = 0x0A5B & MASK
c17 = encode(m17)
r17 = c17 ^ (1 << 7)
m_dec, dist = decode(r17)
ok17 = "PASS" if m_dec == m17 else f"FAIL got 0x{m_dec:04X}"
tc_list.append((m17, r17, m17, 0, f"1-bit error correction ({ok17}, dist={dist})"))

# TC18: 3-bit errors (maximum correctable)
m18 = 0x1AAA & MASK
c18 = encode(m18)
r18 = c18 ^ (1 << 0) ^ (1 << 15) ^ (1 << 28)
m_dec, dist = decode(r18)
ok18 = "PASS" if m_dec == m18 else f"FAIL got 0x{m_dec:04X}"
tc_list.append((m18, r18, m18, 0, f"3-bit error correction ({ok18}, dist={dist})"))

# TC19: 4-bit errors (uncorrectable — expect decode_error=1)
m19 = 0x0F0F & MASK
c19 = encode(m19)
r19 = c19 ^ (1 << 0) ^ (1 << 5) ^ (1 << 10) ^ (1 << 20)
m_dec, dist = decode(r19)
err19 = 1 if dist > T_MAX else 0
tc_list.append((m19, r19, m_dec, err19,
                f"4-bit error, dist={dist}, expect decode_error={err19}"))

NUM_TC = len(tc_list)

# Write vector files
os.makedirs("tb/vectors", exist_ok=True)

with open("tb/vectors/rm_encode_in.hex",   "w") as fe_in,  \
     open("tb/vectors/rm_encode_out.hex",  "w") as fe_out, \
     open("tb/vectors/rm_decode_in.hex",   "w") as fd_in,  \
     open("tb/vectors/rm_decode_exp.hex",  "w") as fd_exp, \
     open("tb/vectors/rm_decode_err.hex",  "w") as fd_err:

    for m, r, exp_m, exp_err, _desc in tc_list:
        fe_in.write(f"{m:04X}\n")
        fe_out.write(f"{encode(m):08X}\n")
        fd_in.write(f"{r:08X}\n")
        fd_exp.write(f"{exp_m:04X}\n")
        fd_err.write(f"{exp_err:01X}\n")

# Write summary for testbench
with open("tb/vectors/rm_tc_count.txt", "w") as f:
    f.write(f"{NUM_TC}\n")

print(f"Wrote {NUM_TC} test vectors to tb/vectors/rm_*.hex")
print()
print("Test case summary:")
for i, (m, r, exp_m, exp_err, desc) in enumerate(tc_list):
    print(f"  TC{i:02d}: m=0x{m:04X} r=0x{r:08X} exp_m=0x{exp_m:04X} err={exp_err}  {desc}")

# ---------------------------------------------------------------------------
# Step 5: Verify decode correctness for all generated vectors
# ---------------------------------------------------------------------------
print()
print("Verifying decode of all test vectors...")
all_pass = True
for i, (m, r, exp_m, exp_err, desc) in enumerate(tc_list):
    got_m, dist = decode(r)
    got_err = 1 if dist > T_MAX else 0
    if i == 0:
        # TC0: zero message, decode(0) = 0 is special (d=0)
        pass
    ok_m   = (got_m   == exp_m)
    ok_err = (got_err == exp_err)
    if not ok_m or not ok_err:
        print(f"  FAIL TC{i:02d}: got m=0x{got_m:04X} err={got_err}, "
              f"expected m=0x{exp_m:04X} err={exp_err}  — {desc}")
        all_pass = False
    else:
        print(f"  PASS TC{i:02d}: {desc}")

print()
if all_pass:
    print("✓ All test vectors verified in Python — ready for Verilog simulation")
else:
    print("✗ Some test vectors failed — fix before simulation")
    sys.exit(1)
