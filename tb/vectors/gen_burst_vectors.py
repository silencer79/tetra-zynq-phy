#!/usr/bin/env python3
"""
gen_burst_vectors.py — TETRA NDB burst field extraction test vectors

Generates stimulus and expected-output hex files for tb_tetra_burst_demux.v.

NDB structure (EN 300 392-2 §9.4.4.3.1), 255 symbols per timeslot:
  abs   0–  1 : FreqCorr      (2 symbols = 4 bits)
  abs   2– 109: Block1        (108 symbols = 216 bits)
  abs 110– 131: Training Seq  (22 symbols, NTS)
  abs 132– 146: BB / AACH     (15 symbols = 30 bits)
  abs 147– 254: Block2        (108 symbols = 216 bits)

slot_position capture windows (value at posedge when dibit sampled):
  pos   0– 14 : BB   (15 symbols)
  pos  15–122 : Block2 (108 symbols)
  pos 123      : emit trigger (FreqCorr 1 of next slot)
  pos 125–232  : Block1 of next slot (108 symbols)

Output files:
  burst_stimulus.hex   — dibit stream for 3 complete frames (12 slots)
  burst_expected.hex   — expected (slot_num, block1, block2, bb) per valid output
"""

import sys
import struct

SYMBOLS_PER_SLOT = 255
SLOTS_PER_FRAME  = 4

# NDB absolute positions (symbol index, 0-based within slot)
FREQCORR_START = 0;   FREQCORR_END = 1      # 2 symbols
BLOCK1_START   = 2;   BLOCK1_END   = 109     # 108 symbols
TS_START       = 110; TS_END       = 131     # 22 symbols (NTS)
BB_START       = 132; BB_END       = 146     # 15 symbols
BLOCK2_START   = 147; BLOCK2_END   = 254     # 108 symbols

# NTS reference (EN 300 392-2 Table 9.11) — 22 symbols, dibit values
# IMPORTANT: verify against ETSI table; this mirrors tetra_sync_detect.v NTS_REF
# NTS_REF constant in sync_detect is newest-first; here we list oldest-first for transmission.
NTS_SYMBOLS = [
    0b01, 0b11, 0b00, 0b00, 0b01, 0b11, 0b00, 0b10,
    0b01, 0b10, 0b00, 0b11, 0b01, 0b10, 0b10, 0b11,
    0b01, 0b10, 0b10, 0b01, 0b11, 0b00
]  # 22 symbols, oldest first
assert len(NTS_SYMBOLS) == 22

FREQCORR_SYMBOL = 0b00  # FreqCorr dibit (arbitrary, not checked)


def make_slot_dibits(slot_idx: int, frame_idx: int) -> list:
    """
    Build the 255-symbol dibit list for one NDB timeslot.

    Field data is deterministic based on slot_idx and frame_idx so
    the testbench can predict expected values without additional tables.

    Encoding:
      Block1 dibits: (slot_idx*4 + frame_idx + 1) repeated  [1..12 range]
      BB    dibits:  slot_idx + 1                            [1..4 range]
      Block2 dibits: ((slot_idx + frame_idx*4) ^ 2) & 3     [0..3 range]
    """
    b1_dibit = ((slot_idx * 4 + frame_idx + 1) % 4) | 0  # 0-3 never 0: use +1 mod 4
    bb_dibit = (slot_idx + 1) % 4
    b2_dibit = ((slot_idx + frame_idx * 4 + 2) % 3) + 1  # 1-3

    dibits = [0] * SYMBOLS_PER_SLOT
    # FreqCorr
    for i in range(FREQCORR_START, FREQCORR_END + 1):
        dibits[i] = FREQCORR_SYMBOL
    # Block1
    for i in range(BLOCK1_START, BLOCK1_END + 1):
        dibits[i] = b1_dibit
    # Training Sequence (NTS)
    for idx, sym in enumerate(NTS_SYMBOLS):
        dibits[TS_START + idx] = sym
    # BB
    for i in range(BB_START, BB_END + 1):
        dibits[i] = bb_dibit
    # Block2
    for i in range(BLOCK2_START, BLOCK2_END + 1):
        dibits[i] = b2_dibit

    return dibits


def dibits_to_bits(dibit_list: list) -> list:
    """Convert list of 2-bit values to list of individual bits (MSB first)."""
    bits = []
    for d in dibit_list:
        bits.append((d >> 1) & 1)
        bits.append(d & 1)
    return bits


def bits_to_hex(bits: list, width_bits: int) -> str:
    """Pack a bit list (MSB first) into a hex string of width_bits bits."""
    assert len(bits) == width_bits, f"expected {width_bits} bits, got {len(bits)}"
    hex_digits = (width_bits + 3) // 4
    val = 0
    for b in bits:
        val = (val << 1) | b
    return f"{val:0{hex_digits}x}"


def expected_block_hex(slot_idx: int, frame_idx: int, field: str) -> str:
    """Return expected hex value for a given field."""
    dibits = make_slot_dibits(slot_idx, frame_idx)
    if field == 'block1':
        d = dibits[BLOCK1_START:BLOCK1_END + 1]   # 108 dibits
        bits = dibits_to_bits(d)
        return bits_to_hex(bits, 216)
    elif field == 'bb':
        d = dibits[BB_START:BB_END + 1]            # 15 dibits
        bits = dibits_to_bits(d)
        return bits_to_hex(bits, 30)
    elif field == 'block2':
        d = dibits[BLOCK2_START:BLOCK2_END + 1]    # 108 dibits
        bits = dibits_to_bits(d)
        return bits_to_hex(bits, 216)
    else:
        raise ValueError(f"Unknown field: {field}")


def main():
    n_frames = 3  # generate 3 complete frames (12 slots)

    stimulus_lines  = []  # one dibit per line (hex, 2-bit values 0-3)
    expected_lines  = []  # slot_num block1 block2 bb (space-separated hex)

    # Build flat dibit stream for n_frames
    all_dibits = []
    for frame_idx in range(n_frames):
        for slot_idx in range(SLOTS_PER_FRAME):
            slot_dibits = make_slot_dibits(slot_idx, frame_idx)
            all_dibits.extend(slot_dibits)

    # Write stimulus (one hex byte per dibit)
    for d in all_dibits:
        stimulus_lines.append(f"{d:02x}")

    # Expected output: first complete burst appears after 2 syncs (slot 1 of frame 0).
    # Burst N uses:
    #   Block1  from slot N (same slot's own Block1, transmitted BEFORE its TS)
    #   BB      from slot N (after its TS)
    #   Block2  from slot N (after its BB)
    # Slot 0 frame 0 cannot be output (no prior Block1 captured).
    # Slot 1 frame 0 is first output (Block1 captured during frame 0 slot 0, after that sync).
    #
    # Mapping: output for "slot K" (0-based global slot index, K=0 = frame0/slot0):
    #   The burst_demux emits for slot K after:
    #     sync K   → latches block1_pend (which was Block1 of slot K captured at pos 125-232)
    #     pos 122  → Block2 of slot K captured
    #     pos 123  → emit fires
    #
    # So output burst for slot K contains:
    #   block1 = Block1 of slot K  (captured in slot K-1 period, pos 125-232)
    #   bb     = BB of slot K
    #   block2 = Block2 of slot K
    # But capture of Block1 at pos 125-232 starts AFTER sync K-1 fires.
    # block1_pend is shifted in for the NEXT slot.
    # At sync K: block1_lat ← block1_pend (= Block1 of slot K, just captured).
    #
    # First valid output: slot K=1 (global index 1, = frame0/slot1).

    global_slot = 0
    for frame_idx in range(n_frames):
        for slot_idx in range(SLOTS_PER_FRAME):
            if global_slot >= 1:  # skip first slot (no block1_ready)
                slot_num_out = global_slot % 4  # 2-bit slot counter
                b1 = expected_block_hex(slot_idx, frame_idx, 'block1')
                bb = expected_block_hex(slot_idx, frame_idx, 'bb')
                b2 = expected_block_hex(slot_idx, frame_idx, 'block2')
                expected_lines.append(f"{slot_num_out:01x} {b1} {b2} {bb}")
            global_slot += 1

    # Write files
    import os
    out_dir = os.path.dirname(os.path.abspath(__file__))

    stim_path = os.path.join(out_dir, 'burst_stimulus.hex')
    exp_path  = os.path.join(out_dir, 'burst_expected.hex')

    with open(stim_path, 'w') as f:
        f.write('\n'.join(stimulus_lines) + '\n')

    with open(exp_path, 'w') as f:
        f.write('\n'.join(expected_lines) + '\n')

    print(f"Written {len(stimulus_lines)} dibits → {stim_path}")
    print(f"Written {len(expected_lines)} expected bursts → {exp_path}")

    # Quick sanity check
    total_slots = n_frames * SLOTS_PER_FRAME
    assert len(stimulus_lines) == total_slots * SYMBOLS_PER_SLOT, "Stimulus length mismatch"
    assert len(expected_lines) == total_slots - 1, f"Expected {total_slots-1} bursts, got {len(expected_lines)}"
    print("Sanity check passed.")

    # Print first expected entry for reference
    if expected_lines:
        print(f"\nFirst expected burst (slot 1): {expected_lines[0][:60]}...")


if __name__ == '__main__':
    main()
