#!/usr/bin/env python3
"""
gen_crc16_vectors.py — CRC-16-CCITT Test Vector Generator
TETRA: ETSI EN 300 392-2 §8.2.6

CRC-16-CCITT parameters:
  Polynomial : 0x1021  (x^16 + x^12 + x^5 + 1)
  Initial    : 0xFFFF
  Final XOR  : none (0x0000)
  Bit order  : MSB-first (network/TETRA convention)

Output files:
  crc16_data_in.hex   — input bit strings packed into bytes, MSB first
  crc16_len_in.hex    — message length in bits (16-bit words)
  crc16_out.hex       — expected CRC-16 (16-bit, hex)

Test cases:
  TC0  Empty message (0 bits)           → CRC = 0xFFFF
  TC1  "123456789" ASCII bytes (72 bits) → known CRC-16-CCITT = 0x29B1
  TC2  All-zeros, 16 bits               → CRC = 0x1021
  TC3  All-ones, 16 bits                → CRC = 0xE2EF  (verify)
  TC4  NDB Block1 example: 216 zero bits → compute
  TC5  NDB Block1: alternating bits, 216 → compute
  TC6  Single 1-bit message             → compute
  TC7  0xABCD as 16-bit message         → compute
  TC8  TETRA SYSINFO payload stub (48 bits of known pattern)
  TC9  Flip-single-bit error detect test
"""

def crc16_ccitt(data_bits: list[int], init: int = 0xFFFF) -> int:
    """Compute CRC-16-CCITT over a list of bits (MSB-first)."""
    crc = init
    for bit in data_bits:
        top = (crc >> 15) & 1
        crc = ((crc << 1) & 0xFFFF) | bit
        if top:
            crc ^= 0x1021
    return crc


def bytes_to_bits(data: bytes) -> list[int]:
    bits = []
    for b in data:
        for i in range(7, -1, -1):
            bits.append((b >> i) & 1)
    return bits


def int_to_bits(value: int, width: int) -> list[int]:
    bits = []
    for i in range(width - 1, -1, -1):
        bits.append((value >> i) & 1)
    return bits


def bits_to_hex_bytes(bits: list[int]) -> str:
    """Pack bits into bytes (MSB first), pad with zeros, return hex string."""
    # Pad to multiple of 8
    padded = bits[:]
    rem = len(padded) % 8
    if rem:
        padded += [0] * (8 - rem)
    result = []
    for i in range(0, len(padded), 8):
        byte = 0
        for j in range(8):
            byte = (byte << 1) | padded[i + j]
        result.append(f"{byte:02X}")
    return " ".join(result)


# ── Test Case Definitions ──────────────────────────────────────────────────────

test_cases = []

# TC0: empty message
bits0 = []
test_cases.append(("TC0 empty (0 bits)", bits0, crc16_ccitt(bits0)))

# TC1: "123456789" ASCII — canonical check value for CRC-16-CCITT = 0x29B1
bits1 = bytes_to_bits(b"123456789")
crc1  = crc16_ccitt(bits1)
assert crc1 == 0x29B1, f"TC1 canonical check failed: {crc1:#06x}"
test_cases.append(("TC1 '123456789' (72 bits)", bits1, crc1))

# TC2: 16 all-zero bits
bits2 = int_to_bits(0x0000, 16)
test_cases.append(("TC2 0x0000 (16 bits)", bits2, crc16_ccitt(bits2)))

# TC3: 16 all-one bits
bits3 = int_to_bits(0xFFFF, 16)
test_cases.append(("TC3 0xFFFF (16 bits)", bits3, crc16_ccitt(bits3)))

# TC4: 216 all-zero bits (NDB block length)
bits4 = [0] * 216
test_cases.append(("TC4 216×0 (NDB block)", bits4, crc16_ccitt(bits4)))

# TC5: 216 alternating bits (NDB block)
bits5 = [i % 2 for i in range(216)]
test_cases.append(("TC5 216-bit alternating", bits5, crc16_ccitt(bits5)))

# TC6: single bit = 1
bits6 = [1]
test_cases.append(("TC6 single bit 1", bits6, crc16_ccitt(bits6)))

# TC7: 0xABCD as 16-bit message
bits7 = int_to_bits(0xABCD, 16)
test_cases.append(("TC7 0xABCD (16 bits)", bits7, crc16_ccitt(bits7)))

# TC8: 48-bit pattern (typical short PDU header stub)
payload8 = 0xDEAD_BEEF_CAFE
bits8 = int_to_bits(payload8, 48)
test_cases.append(("TC8 0xDEADBEEFCAFE (48 bits)", bits8, crc16_ccitt(bits8)))

# TC9: error-detect — take TC7 data, flip bit 3, CRC must differ
bits9 = bits7[:]
bits9[3] ^= 1
crc9 = crc16_ccitt(bits9)
assert crc9 != crc16_ccitt(bits7), "TC9 error detection failed"
test_cases.append(("TC9 0xABCD bit3-flipped error", bits9, crc9))

# ── Print summary ──────────────────────────────────────────────────────────────

print("CRC-16-CCITT Test Vectors")
print("=" * 60)
for name, bits, crc in test_cases:
    print(f"  {name:<40}  CRC={crc:#06x}  ({len(bits)} bits)")

# ── Write hex files ────────────────────────────────────────────────────────────

import os
out_dir = os.path.dirname(os.path.abspath(__file__))

# crc16_data_in.hex
# One line per test case: bits packed MSB-first into bytes, space-separated
with open(os.path.join(out_dir, "crc16_data_in.hex"), "w") as f:
    for name, bits, crc in test_cases:
        if len(bits) == 0:
            f.write("00\n")   # placeholder byte
        else:
            f.write(bits_to_hex_bytes(bits) + "\n")

# crc16_len_in.hex  (message length in bits, 16-bit hex per line)
with open(os.path.join(out_dir, "crc16_len_in.hex"), "w") as f:
    for name, bits, crc in test_cases:
        f.write(f"{len(bits):04X}\n")

# crc16_out.hex  (expected CRC per line)
with open(os.path.join(out_dir, "crc16_out.hex"), "w") as f:
    for name, bits, crc in test_cases:
        f.write(f"{crc:04X}\n")

# crc16_tc_count.txt
with open(os.path.join(out_dir, "crc16_tc_count.txt"), "w") as f:
    f.write(str(len(test_cases)) + "\n")

print(f"\nWrote {len(test_cases)} test cases to:")
print(f"  crc16_data_in.hex")
print(f"  crc16_len_in.hex")
print(f"  crc16_out.hex")
print(f"  crc16_tc_count.txt")
