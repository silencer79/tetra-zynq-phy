#!/usr/bin/env python3
"""
gen_burst_builder_vectors.py — Test vectors for tetra_burst_builder
TETRA PHY project — tetra-zynq-phy

Generates NDB burst structure for verification:
  - NDB = FreqCorr(2) + Block1(108sym) + NTS(22sym) + BB(15sym) + Block2(108sym)
  - Total = 255 symbols per timeslot

Test cases:
  TC1: All-zeros payload → verify structure (FreqCorr pattern + NTS at offset 110)
  TC2: Known payload → verify exact output symbol sequence
  TC3: Alternating 01/10 payload → verify pass-through
"""

# NTS = Normal Training Sequence, Table 9.11 EN 300 392-2
# 22 symbols listed as dibits (MSB first in the localparam NTS_REF of burst_builder)
NTS_DIBITS = [0b00, 0b11, 0b01, 0b10, 0b01, 0b11, 0b10, 0b10,
              0b00, 0b11, 0b01, 0b00, 0b10, 0b01, 0b10, 0b00,
              0b11, 0b01, 0b00, 0b00, 0b11, 0b01]

FC_DIBITS  = [0b01, 0b01]   # 2 FreqCorr symbols

BLOCK_SYMS = 108   # symbols per block
BB_SYMS    = 15    # symbols for BB/AACH
NTS_SYMS   = 22

TOTAL_SYMS = 2 + BLOCK_SYMS + NTS_SYMS + BB_SYMS + BLOCK_SYMS  # 255


def build_ndb(block1_dibits, bb_dibits, block2_dibits):
    """Assemble full NDB symbol stream (255 dibits)."""
    burst = []
    burst.extend(FC_DIBITS)
    burst.extend(block1_dibits)
    burst.extend(NTS_DIBITS)
    burst.extend(bb_dibits)
    burst.extend(block2_dibits)
    assert len(burst) == TOTAL_SYMS, f"Expected {TOTAL_SYMS} got {len(burst)}"
    return burst


def dibits_to_bits(dibits):
    """Convert dibit list to flat bit list (MSB of each dibit first)."""
    bits = []
    for d in dibits:
        bits.append((d >> 1) & 1)
        bits.append(d & 1)
    return bits


def bits_to_hex(bits, nbits=None):
    """Convert bit list to hex string (MSB first, zero-padded)."""
    if nbits is None:
        nbits = len(bits)
    assert len(bits) == nbits
    val = 0
    for b in bits:
        val = (val << 1) | b
    digits = (nbits + 3) // 4
    return format(val, f'0{digits}X')


if __name__ == '__main__':
    import os
    out = os.path.dirname(__file__)

    # TC1: all-zeros payload
    block1_z = [0b00] * BLOCK_SYMS
    block2_z = [0b00] * BLOCK_SYMS
    bb_z     = [0b00] * BB_SYMS

    burst_tc1 = build_ndb(block1_z, bb_z, block2_z)
    print(f"TC1 NDB (all-zeros payload):")
    print(f"  Sym[0..1]   = {burst_tc1[:2]}  (FreqCorr, expect [1,1])")
    print(f"  Sym[2..109] = block1 (all zeros)")
    print(f"  Sym[110..131]= NTS = {burst_tc1[110:132]}")
    print(f"  Sym[132..146]= BB (all zeros)")
    print(f"  Sym[147..254]= block2 (all zeros)")

    # Verify NTS in correct position
    assert burst_tc1[110:132] == NTS_DIBITS, "NTS mismatch"
    print("  NTS position: OK")

    # Write expected output for TC1 as flat dibit stream (255 × 2 bits = 510 bits)
    tc1_bits = dibits_to_bits(burst_tc1)
    print(f"TC1 expected output hex (510 bits = {len(tc1_bits)//4} nybbles):")

    # TC2: known ascending payload
    block1_asc = [i % 4 for i in range(BLOCK_SYMS)]
    block2_asc = [(i + 1) % 4 for i in range(BLOCK_SYMS)]
    bb_asc     = [i % 4 for i in range(BB_SYMS)]

    burst_tc2 = build_ndb(block1_asc, bb_asc, block2_asc)
    tc2_bits  = dibits_to_bits(burst_tc2)

    # Write vector files
    # Format: one hex word per line, each = 2-bit dibit (for easy TB parsing)
    fname_tc1 = os.path.join(out, 'burst_builder_tc1_expected.hex')
    fname_tc2 = os.path.join(out, 'burst_builder_tc2_expected.hex')

    with open(fname_tc1, 'w') as f:
        for d in burst_tc1:
            f.write(f'{d:02b}\n')   # 2-bit binary per line

    with open(fname_tc2, 'w') as f:
        for d in burst_tc2:
            f.write(f'{d:02b}\n')

    # Also write compact hex (bits packed, 510 bits total)
    with open(os.path.join(out, 'burst_builder_tc1_packed.hex'), 'w') as f:
        # Write 510 bits as 128 hex chars (512 bits, padded)
        val = 0
        for b in tc1_bits:
            val = (val << 1) | b
        # pad to 512 bits
        val_512 = val << 2
        f.write(format(val_512, '0128X') + '\n')

    with open(os.path.join(out, 'burst_builder_tc2_packed.hex'), 'w') as f:
        val = 0
        for b in tc2_bits:
            val = (val << 1) | b
        val_512 = val << 2
        f.write(format(val_512, '0128X') + '\n')

    # Write input vectors (block1, block2, bb as bit-packed hex)
    def dibits_to_hex_packed(dibits, total_bits):
        bits = dibits_to_bits(dibits)
        val = 0
        for b in bits:
            val = (val << 1) | b
        digits = (total_bits + 3) // 4
        return format(val & ((1 << total_bits) - 1), f'0{digits}X')

    with open(os.path.join(out, 'burst_builder_inputs.txt'), 'w') as f:
        f.write(f"# TC1: all-zeros payload\n")
        f.write(f"TC1_block1={dibits_to_hex_packed(block1_z, 216)}\n")
        f.write(f"TC1_block2={dibits_to_hex_packed(block2_z, 216)}\n")
        f.write(f"TC1_bb={dibits_to_hex_packed(bb_z, 30)}\n")
        f.write(f"\n# TC2: ascending payload\n")
        f.write(f"TC2_block1={dibits_to_hex_packed(block1_asc, 216)}\n")
        f.write(f"TC2_block2={dibits_to_hex_packed(block2_asc, 216)}\n")
        f.write(f"TC2_bb={dibits_to_hex_packed(bb_asc, 30)}\n")

    print(f"\nFiles written:")
    print(f"  {fname_tc1}")
    print(f"  {fname_tc2}")
    print(f"  burst_builder_inputs.txt")
    print(f"\nTC1 NTS reference:")
    for j, sym in enumerate(NTS_DIBITS):
        print(f"  NTS[{j:2d}] = {sym:02b} ({sym})")
