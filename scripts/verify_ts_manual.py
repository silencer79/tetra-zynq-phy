#!/usr/bin/env python3
"""
Manual verification of training sequences against RTL
"""

import sys
import os
script_dir = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(script_dir, '..', 'tb', 'vectors'))
from gen_sync_detect_vectors import NTS_DIBITS, ETS_DIBITS, STS_DIBITS

# RTL training sequences extracted from concat blocks
# RTL format: { oldest_pair, ..., newest_pair }
# Python uses newest-first ordering (dibits[0] = newest)
# RTL also stores newest at bits[1:0]

# NTS — 22 symbols (Table 9.11)
# RTL lines 105-111: symbols 21..20 (oldest) to symbols 1..0 (newest)
nts_rtl_oldest_first = [
    0b00, 0b11,  # symbols 21..20 (oldest)
    0b01, 0b10, 0b01, 0b11, 0b10, 0b10,
    0b00, 0b11, 0b01, 0b00, 0b10, 0b01,
    0b10, 0b00, 0b11, 0b01, 0b00, 0b00,
    0b11, 0b01,  # symbols 1..0 (newest)
]

# Convert to newest-first (reverse order for comparison with Python)
nts_rtl_newest_first = list(reversed(nts_rtl_oldest_first))

# ETS — 30 symbols (Table 9.12)
ets_rtl_oldest_first = [
    0b01, 0b11,  # symbols 29..28 (oldest)
    0b01, 0b00, 0b10, 0b11, 0b01, 0b10,
    0b00, 0b11, 0b01, 0b00, 0b01, 0b11,
    0b10, 0b10, 0b00, 0b11, 0b01, 0b10,
    0b10, 0b00, 0b11, 0b01, 0b00, 0b00,
    0b10, 0b01, 0b11, 0b01,  # symbols 5..0 (newest)
]
ets_rtl_newest_first = list(reversed(ets_rtl_oldest_first))

# STS — 38 symbols (Table 9.14)
sts_rtl_oldest_first = [
    0b01, 0b11,  # symbols 37..36 (oldest)
    0b10, 0b10, 0b00, 0b11, 0b01, 0b00,
    0b10, 0b01, 0b10, 0b11, 0b01, 0b00,
    0b10, 0b11, 0b01, 0b00, 0b10, 0b01,
    0b10, 0b11, 0b00, 0b10, 0b01, 0b11,
    0b01, 0b00, 0b00, 0b11, 0b10, 0b10,
    0b01, 0b11, 0b01, 0b00, 0b10, 0b11,  # symbols 1..0 (newest)
]
sts_rtl_newest_first = list(reversed(sts_rtl_oldest_first))

print("="*80)
print("Training Sequence Verification (newest-first ordering)")
print("="*80)

def compare_seq(name, rtl_seq, py_seq):
    print(f"\n{name}:")
    print(f"  RTL length:    {len(rtl_seq)} symbols")
    print(f"  Python length: {len(py_seq)} symbols")

    if len(rtl_seq) != len(py_seq):
        print(f"  ❌ LENGTH MISMATCH")
        return False

    all_match = True
    print(f"  First 10 dibits (newest first):")
    print(f"    RTL:    {' '.join(f'{d:02b}' for d in rtl_seq[:10])}")
    print(f"    Python: {' '.join(f'{d:02b}' for d in py_seq[:10])}")

    for i, (rtl_val, py_val) in enumerate(zip(rtl_seq, py_seq)):
        if rtl_val != py_val:
            if i < 10:  # Only show first 10 mismatches
                print(f"    Symbol {i}: RTL={rtl_val:02b}, Python={py_val:02b} ❌")
            all_match = False

    if all_match:
        print(f"  ✅ PASS - All dibits match!")
    else:
        print(f"  ❌ FAIL - Dibit mismatches found")

    return all_match

results = {
    'NTS': compare_seq('NTS (Normal TS, 22 symbols)', nts_rtl_newest_first, NTS_DIBITS),
    'ETS': compare_seq('ETS (Extended TS, 30 symbols)', ets_rtl_newest_first, ETS_DIBITS),
    'STS': compare_seq('STS (Sync TS, 38 symbols)', sts_rtl_newest_first, STS_DIBITS),
}

print("\n" + "="*80)
print("SUMMARY")
print("="*80)
for name, passed in results.items():
    status = "✅ PASS" if passed else "❌ FAIL"
    print(f"  {name}: {status}")

all_pass = all(results.values())
sys.exit(0 if all_pass else 1)

