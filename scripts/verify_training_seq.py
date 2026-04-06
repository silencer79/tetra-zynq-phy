#!/usr/bin/env python3
"""
verify_training_seq.py — Cross-check training sequence dibit values
================================================================================
Compare Python test vector definitions (gen_sync_detect_vectors.py)
against RTL constants (tetra_sync_detect.v) and verify consistency.

Reference: ETSI EN 300 392-2 Tables 9.11 / 9.12 / 9.14
"""

import sys
import os

# Add tb/vectors to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tb', 'vectors'))

try:
    from gen_sync_detect_vectors import NTS_DIBITS, ETS_DIBITS, STS_DIBITS
except ImportError:
    print("ERROR: Could not import training sequences from gen_sync_detect_vectors.py")
    sys.exit(1)

# ---------------------------------------------------------------------------------------------------------------------
# RTL Reference Constants (from tetra_sync_detect.v)
# These are defined as concatenated binary literals: {2'bXX, 2'bYY, ...}
# Bit ordering: [1:0] = newest dibit, [2*N-1:2*N-2] = oldest dibit
# ---------------------------------------------------------------------------------------------------------------------

# NTS — 22 symbols (44 bits), Table 9.11
# RTL lines 105-111:
# localparam [43:0] NTS_REF = {
#     2'b00, 2'b11,  // symbols 21..20 (oldest)
#     2'b01, 2'b10, 2'b01, 2'b11, 2'b10, 2'b10,
#     2'b00, 2'b11, 2'b01, 2'b00, 2'b10, 2'b01,
#     2'b10, 2'b00, 2'b11, 2'b01, 2'b00, 2'b00,
#     2'b11, 2'b01   // symbols 1..0 (newest)
# };

nts_bits_rtl = '00110110111010001101101000011101000110011101'

# ETS — 30 symbols (60 bits), Table 9.12
# RTL lines 114-121:
ets_bits_rtl = '01110100101101010011010001111010001101000010011101' + '00111101'  # 60 bits total

# STS — 38 symbols (76 bits), Table 9.14
# RTL lines 124-132:
sts_bits_rtl = ('01111010001101001011010010110100110010011101' +
                '0010011011010000111001101110100010011011')

def bits_to_dibits(bitstring):
    """Convert concatenated 2-bit binary string to list of integer dibits."""
    dibits = []
    for i in range(0, len(bitstring), 2):
        dibit_str = bitstring[i:i+2]
        dibit_val = int(dibit_str, 2)
        dibits.append(dibit_val)
    return dibits

def compare_sequence(name, bits_rtl, dibits_python):
    """
    Compare RTL binary representation against Python dibit list.
    Returns True if matching, False otherwise.
    """
    print(f"\n{'='*80}")
    print(f"Training Sequence: {name}")
    print(f"{'='*80}")

    # Convert RTL bits to dibits
    dibits_rtl = bits_to_dibits(bits_rtl)

    print(f"RTL length:    {len(dibits_rtl)} symbols ({len(bits_rtl)} bits)")
    print(f"Python length: {len(dibits_python)} symbols")

    # Check length
    if len(dibits_rtl) != len(dibits_python):
        print(f"❌ MISMATCH: Length differs!")
        return False

    # Compare dibit-by-dibit
    all_match = True
    for i, (rtl_val, py_val) in enumerate(zip(dibits_rtl, dibits_python)):
        if rtl_val != py_val:
            print(f"  Symbol {i:2d}: RTL={rtl_val:02b} (0b{rtl_val:02b}), Python={py_val:02b} (0b{py_val:02b}) ❌")
            all_match = False

    if all_match:
        print(f"✅ PASS: All {len(dibits_rtl)} dibits match!")
        print(f"   RTL bits:    {bits_rtl}")
        print(f"   Python list: {' '.join(f'{d:02b}' for d in dibits_python[:10])} ...")
    else:
        print(f"❌ FAIL: Dibit mismatches found")

    return all_match

def main():
    print("Training Sequence Verification")
    print("Reference: ETSI EN 300 392-2 Tables 9.11 / 9.12 / 9.14")

    results = {}

    # Check NTS (Normal Training Sequence)
    results['NTS'] = compare_sequence(
        'NTS (Normal Training Sequence, 22 symbols)',
        nts_bits_rtl,
        NTS_DIBITS
    )

    # Check ETS (Extended Training Sequence)
    results['ETS'] = compare_sequence(
        'ETS (Extended Training Sequence, 30 symbols)',
        ets_bits_rtl,
        ETS_DIBITS
    )

    # Check STS (Synchronisation Training Sequence)
    results['STS'] = compare_sequence(
        'STS (Synchronisation Training Sequence, 38 symbols)',
        sts_bits_rtl,
        STS_DIBITS
    )

    # Summary
    print(f"\n{'='*80}")
    print("SUMMARY")
    print(f"{'='*80}")
    for name, passed in results.items():
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"  {name}: {status}")

    all_pass = all(results.values())
    if all_pass:
        print("\n✅ All training sequences verified successfully!")
        print("   RTL constants match Python test vector definitions.")
        print("   TODO comment can be removed from gen_sync_detect_vectors.py")
        return 0
    else:
        print("\n❌ Training sequence verification FAILED!")
        print("   Check ETSI EN 300 392-2 Tables 9.11 / 9.12 / 9.14")
        return 1

if __name__ == '__main__':
    sys.exit(main())
