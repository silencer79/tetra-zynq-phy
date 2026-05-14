#!/usr/bin/env python3
"""
verify_sch_f_roundtrip.py — Phase 1 Encoder-Round-Trip-Verifikation.

Workflow:
  1. WAV laden + Burst #423 (D-NWRK-BROADCAST, NDB1, TN=1 FN=04 MN=44) finden
  2. Bursts-Soft-Bits → de-scramble → de-interleave → de-puncture → viterbi
     → 268 info bits + CRC-OK
  3. Diese 268 info bits durch gen_sch_f_tv::encode_sch_f schicken
     → 432 type-5 hard bits (mein Re-Encoder-Output)
  4. -Burst-Original 432 hard bits aus dem Soft-Decode neu rekonstruieren
     (sign der Soft-Bits == Hard-Bit nach scrambling+interleave)
  5. Bit-für-Bit-Vergleich

Result PASS bedeutet: mein Encoder produziert bit-genau das was on-air ist.
Voraussetzung für SW-Builder + RTL-Modul.

Usage:
  python3 scripts/verify_sch_f_roundtrip.py
"""
import sys
import pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

# Reuse decode_dl pipeline
import decode_dl
from gen_sch_f_tv import encode_sch_f

WAV = ROOT / "wavs/reference/reference-DL.wav"
TARGET_INDEX = 423  # D-NWRK-BROADCAST burst per decode_dl_full.log


def main():
    print(f"Loading {WAV}")
    iq, sr = decode_dl.load_wav(str(WAV))
    print(f"  samples={len(iq)}, sr={sr}")

    # Run cell-acquisition + burst detection
    fo = decode_dl.estimate_freq_offset(iq, sr)
    iq = iq * np.exp(-1j * 2 * np.pi * fo / sr * np.arange(len(iq)))
    sps = decode_dl.SAMPLES_PER_SLOT * (decode_dl.SLOT_DURATION / decode_dl.SLOT_DURATION) / decode_dl.SAMPLES_PER_SLOT * sr * decode_dl.SLOT_DURATION
    # use library helper
    sps_real = sr * decode_dl.SLOT_DURATION / decode_dl.SAMPLES_PER_SLOT
    print(f"  freq_offset={fo:.1f} Hz, sps={sps_real:.4f}")

    sts_positions = decode_dl.find_sts_positions(iq, sps_real, max_bursts=8000)
    print(f"  Found {len(sts_positions)} STS candidates")

    # Cell-lock to recover scrambling code
    locked = decode_dl.lock_cell(iq, sts_positions, sps_real)
    if not locked:
        print("FAIL: Cell-lock failed")
        return 1
    scramb = locked['scramb_code']
    print(f"  scramb_code = 0x{scramb:08x}")

    # Locate target burst
    if TARGET_INDEX >= len(sts_positions):
        print(f"FAIL: target burst #{TARGET_INDEX} out of range")
        return 1

    pos = sts_positions[TARGET_INDEX]
    burst_iq = decode_dl.extract_burst(iq, pos, sps_real)
    burst_type, soft_bits, _ = decode_dl.demod_burst(burst_iq, sps_real)
    print(f"  Burst #{TARGET_INDEX}: type={burst_type}")

    if burst_type != 'NDB1':
        print(f"FAIL: expected NDB1, got {burst_type}")
        return 1

    # Combine BLK1+BLK2 = 432 soft bits for SCH/F
    blk1_s = (decode_dl.NDB_OFF_BLK1 - 1) * 2
    blk2_s = (decode_dl.NDB_OFF_BLK2 - 1) * 2
    blk1_soft = soft_bits[blk1_s : blk1_s + decode_dl.NDB_BLK1 * 2]
    blk2_soft = soft_bits[blk2_s : blk2_s + decode_dl.NDB_BLK2 * 2]
    combined_soft = np.concatenate([blk1_soft, blk2_soft])

    # Hard-bit version of original on-air type-5
    on_air_type5 = (combined_soft < 0).astype(int).tolist()
    print(f"  On-air type-5 (432 bit) hard:")
    print(f"    {''.join(str(b) for b in on_air_type5)}")

    # Soft-descramble + decode
    descrambled = decode_dl.descramble_soft(combined_soft, scramb, 432)
    crc_ok, info_bits, _ = decode_dl.decode_channel_soft(descrambled, 432, 103, 268)
    print(f"  CRC OK: {crc_ok}")
    if not crc_ok:
        print("FAIL: CRC of decoded info_bits failed")
        return 1
    info_268 = list(info_bits)
    print(f"  Decoded 268 info bits:")
    print(f"    {''.join(str(b) for b in info_268)}")
    print(f"  Hex: 0x{int(''.join(str(b) for b in info_268), 2):067x}")

    # Re-encode with gen_sch_f_tv
    re_type5 = encode_sch_f(info_268, scramb)
    print(f"  Re-encoded type-5 (432 bit) via gen_sch_f_tv:")
    print(f"    {''.join(str(b) for b in re_type5)}")

    # Bit compare
    diffs = sum(1 for a, b in zip(on_air_type5, re_type5) if a != b)
    print(f"\n=== Result ===")
    print(f"  Differences on-air ↔ re-encoded: {diffs} / 432 bits")
    if diffs == 0:
        print("  PASS — Encoder bit-identisch zu on-air. Phase 1 OK.")
        return 0
    else:
        print("  FAIL — Encoder produziert nicht das gleiche wie on-air.")
        # show first 20 diff positions
        diff_pos = [i for i,(a,b) in enumerate(zip(on_air_type5, re_type5)) if a != b][:20]
        print(f"  Erste 20 Diff-Positionen: {diff_pos}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
