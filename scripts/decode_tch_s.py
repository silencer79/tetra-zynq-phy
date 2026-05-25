#!/usr/bin/env python3
"""decode_tch_s.py — TCH/S 7.2 Voice-Burst-Decoder (PHY → type-2 → ACELP-Frame-Felder)

Voice-Burst-Layers per ETSI EN 300 392-2 §8.3.1.2 + EN 300 395-2 Table 4:

  type-5  (432 bit)  ← on-air, scrambled+interleaved (post-modulator-demod)
  type-4  (432 bit)  = descramble(type-5, cell-scrambler-seq)
  type-3  (432 bit)  = de-interleave(type-4, block interleaver a=TCH-spec)
  type-2  (432 bit)  = type-3 (TCH/S 7.2 hat keine RCPC-Puncturing — rate-matched)

  type-2 zerteilt sich in 2× 216-bit voice-frames (1 burst = 2 codec frames @ 30 ms).
  Per Frame (216 type-2 bits → 137 type-1 codec bits):
    Class 0  unprotected   : 51 type-1 = 51 type-2 (direct, no FEC)
    Class 1  protected K=1/2 : 56 type-1 → 112 type-2 (rate-1/2 conv code)
    Class 2  protected K=2/3 : 30 type-1 →  45 type-2 (rate-2/3 conv code)
    CRC                    :  8 type-2 (8-bit parity over Class 1+2 type-1)
    Sum                    : 216 type-2 bits / frame

  Nach Viterbi-Decode der Class1+Class2 Segmente: 137 type-1 codec-frame-bits.
  Diese werden via tch_reordering (osmo-tetra) zu ACELP-Frame-Positionen 1..137
  re-arrangiert: pitch-lag-Code, fixed-codebook-indices, gain-indices, etc.

Was DIESES Modul tut:
  - Descramble + De-Interleave (rate-matched, kein Puncturing) ohne FEC-Decode
  - Per Frame: zerteile type-2 in Class0+Class1+Class2+CRC Segmente
  - Per Codec-Bit-Position: ACELP-Frame-Feld-Name (Class0/1/2 → frame-bit-index)
  - Output: strukturierte Bit-Dumps pro Layer + ACELP-frame-Position-Annotation

Was dieses Modul NICHT tut:
  - Viterbi-Decode der Class1/2-FEC-Segmente (nur Class0 ist direkt type-1 = codec)
    → vollständige 137-codec-bit Recovery braucht Class-Viterbi (separat, K=5)
  - ACELP-Synthese (kein Audio-Decoder)

Class-Positionen aus osmo-tetra/lower_mac/tch_reordering.c (ETSI EN 300 395-2).
"""
import numpy as np


# ============================================================================
# ACELP Frame Layout — Class 0/1/2 Codec-Bit-Position-Maps
# Source: osmo-tetra/src/lower_mac/tch_reordering.c
# Each entry is the ACELP frame bit position (1-based per ETSI EN 300 395-2)
# ============================================================================

# 51 unprotected bits (Class 0) — sent as type-1 = type-2 directly
ACELP_CLASS0_POSITIONS = [
    35, 36, 37,
    38, 39, 40,
    41, 42, 33,
    47, 48,
    56,
    61, 62, 63,
    65, 66, 67,
    68, 69, 70,
    74, 75,
    83,
    88,
    89, 90, 91,
    92, 93, 94,
    95, 96, 97,
    101, 102,
    110,
    115,
    116, 117, 118,
    119, 120, 121,
    122, 123, 124,
    128, 129,
    137,
]

# 56 protected-Class-1 bits (rate-1/2 conv coded)
ACELP_CLASS1_POSITIONS = [
    58, 85, 112,
    54, 81, 108, 135,
    50, 77,
    104, 131,
    45, 72, 99, 126,
    55, 82, 109, 136,
    5, 13, 34,
    8, 16, 17,
    22, 23, 24,
    25, 26,
    6, 14, 7, 15,
    60, 87, 114,
    46,
    73, 100, 127,
    44, 71, 98, 125,
    33, 49,
    76, 103, 130,
    59, 86, 113,
    57, 84, 111,
]

# 30 protected-Class-2 bits (rate-2/3 conv coded)
ACELP_CLASS2_POSITIONS = [
    18, 19, 20, 21,
    31, 32,
    53, 80, 107, 134,
    1, 2, 3, 4,
    9, 10, 11, 12,
    27, 28, 29, 30,
    52, 79, 106, 133,
    51, 78, 105, 132,
]

# ACELP-Frame field annotations per ETSI EN 300 395-2 (137-bit codec frame)
# Position → human-readable field name.  Used for per-bit semantic dump.
# Source: ETSI EN 300 395-2 Annex A (ACELP frame structure)
ACELP_FIELDS = {
    # bits 1-8   : LSP1 (8 bit) — first LSP-coefficient codebook index
    range(1, 9): 'LSP1[index]',
    # bits 9-17  : LSP2 (9 bit) — second LSP-codebook index
    range(9, 18): 'LSP2[index]',
    # bits 18-26 : LSP3 (9 bit)
    range(18, 27): 'LSP3[index]',
    # bits 27-30 : LSP4 (4 bit)
    range(27, 31): 'LSP4[index]',
    # bits 31-37 : pitch-lag for subframe 1 (7 bit)
    range(31, 38): 'subframe1.pitch_lag',
    # bits 38-42 : fixed-codebook gain s1 (5 bit)
    range(38, 43): 'subframe1.fcb_gain',
    # bits 43-44 : adaptive-codebook gain s1 (2 bit)
    range(43, 45): 'subframe1.acb_gain',
    # bits 45-67 : fixed-codebook positions s1 (23 bit)
    range(45, 68): 'subframe1.fcb_position',
    # bits 68-72 : pitch-lag s2 (5 bit, relative)
    range(68, 73): 'subframe2.pitch_lag',
    # bits 73-77 : fcb_gain s2
    range(73, 78): 'subframe2.fcb_gain',
    # bits 78-79 : acb_gain s2
    range(78, 80): 'subframe2.acb_gain',
    # bits 80-102: fcb_position s2 (23 bit)
    range(80, 103): 'subframe2.fcb_position',
    # bits 103-109: pitch-lag s3 (7 bit)
    range(103, 110): 'subframe3.pitch_lag',
    # bits 110-114: fcb_gain s3
    range(110, 115): 'subframe3.fcb_gain',
    # bits 115-116: acb_gain s3
    range(115, 117): 'subframe3.acb_gain',
    # bits 117-129: fcb_position s3 (subset, 13 bit per ETSI sub-table)
    range(117, 130): 'subframe3.fcb_position',
    # bits 130-137: subframe4 packed
    range(130, 138): 'subframe4.packed',
}


def acelp_position_to_field(pos):
    """Return ETSI EN 300 395 ACELP-frame field name for 1-based bit position."""
    for r, name in ACELP_FIELDS.items():
        if pos in r:
            return name
    return f'unknown_{pos}'


def acelp_position_to_class(pos):
    """Return 'Class0'/'Class1'/'Class2' for ACELP frame bit position (1-based)."""
    if pos in ACELP_CLASS0_POSITIONS: return 'Class0'
    if pos in ACELP_CLASS1_POSITIONS: return 'Class1'
    if pos in ACELP_CLASS2_POSITIONS: return 'Class2'
    return 'unknown'


# ============================================================================
# TCH/S de-interleave (block permutation)
# Per ETSI EN 300 392-2 §8.4.2: i ↔ (1 + a·k) mod K  with K=432, a=TCH-spec
# osmo-tetra interleave block_deinterleave uses same formula.
# TCH/S 7.2 uses same a as SCH/F (a=103) — verified by structural similarity.
# ============================================================================

def deinterleave_block(coded_bits, K=432, a=103):
    """De-interleave a length-K block.  Permutation: bit at position
    (1 + a*k) mod K in the interleaved stream maps back to position k."""
    out = np.zeros(K, dtype=coded_bits.dtype)
    for k in range(K):
        i = (1 + a * k) % K
        out[k] = coded_bits[i]
    return out


def interleave_block(input_bits, K=432, a=103):
    out = np.zeros(K, dtype=input_bits.dtype)
    for k in range(K):
        i = (1 + a * k) % K
        out[i] = input_bits[k]
    return out


# ============================================================================
# TCH/S Cell-Scrambler
# Same scrambler-init as signaling: (MCC<<22)|(MNC<<8)|(CC<<2)|0
# Generator polynomial per ETSI EN 300 392-2 §8.2.5
# ============================================================================

def cell_scrambler_seq(scramb_init, length):
    """Generate length-N pseudo-random scrambler sequence."""
    seq = np.zeros(length, dtype=np.uint8)
    state = scramb_init & 0xFFFFFFFF
    for i in range(length):
        # 32-bit LFSR per §8.2.5 — feedback per generator polynomial
        bit = ((state >> 31) ^ (state >> 30) ^ (state >> 29) ^ (state >> 27)
               ^ (state >> 25) ^ (state >> 0)) & 1
        seq[i] = bit
        state = ((state << 1) | bit) & 0xFFFFFFFF
    return seq


def descramble_tch_s(type5_bits, scramb_init):
    """Descramble 432 type-5 bits → 432 type-4 bits using cell scrambler."""
    seq = cell_scrambler_seq(scramb_init, len(type5_bits))
    return np.bitwise_xor(type5_bits, seq)


# ============================================================================
# Per-Frame Class Segmentation (within 216 type-2 bits)
# Per ETSI EN 300 392-2 §8.3.1.2 layout:
#   bits   0-50  (51): Class 0 unprotected
#   bits  51-162 (112): Class 1 rate-1/2 coded  (56 codec bits)
#   bits 163-207 (45): Class 2 rate-2/3 coded   (30 codec bits)
#   bits 208-215 (8): 8-bit CRC parity over Class 1 + Class 2 input
# ============================================================================

CLASS0_LEN_T2 = 51
CLASS1_LEN_T2 = 112
CLASS2_LEN_T2 = 45
CRC_LEN_T2    = 8
FRAME_T2_LEN  = CLASS0_LEN_T2 + CLASS1_LEN_T2 + CLASS2_LEN_T2 + CRC_LEN_T2  # 216

assert FRAME_T2_LEN == 216, f'frame t2 = {FRAME_T2_LEN}, expected 216'


def split_frame_into_classes(frame_t2_bits):
    """Slice a 216-bit type-2 voice frame into Class0/1/2/CRC segments."""
    assert len(frame_t2_bits) == FRAME_T2_LEN
    return {
        'class0_t2':  frame_t2_bits[0:51],
        'class1_t2':  frame_t2_bits[51:163],
        'class2_t2':  frame_t2_bits[163:208],
        'crc_t2':     frame_t2_bits[208:216],
    }


# ============================================================================
# Full TCH/S burst decoder (PHY → type-2 → Class segmentation + ACELP layout)
# ============================================================================

def decode_tch_s_burst(type5_bits, scramb_init):
    """Full TCH/S 7.2 burst decode.

    Args:
        type5_bits : 432-bit np.ndarray (uint8 0/1), post-demod on-air bits
        scramb_init: 32-bit cell-scrambler init (= (MCC<<22)|(MNC<<8)|(CC<<2))

    Returns dict with all layers:
        type5_hex / type4_hex / type3_hex / type2_hex (432-bit each)
        frame0 / frame1 : dicts with class0_t2_hex, class1_t2_hex, class2_t2_hex,
                          crc_t2_hex per voice frame.
        acelp_layout    : list of 137 (pos, class, field_name) for each ACELP-bit
    """
    assert len(type5_bits) == 432, f'expected 432 type-5 bits, got {len(type5_bits)}'
    t5 = np.asarray(type5_bits, dtype=np.uint8)

    # Layer 1: descramble
    t4 = descramble_tch_s(t5, scramb_init)

    # Layer 2: de-interleave (block permutation a=103 — TCH/S-specific)
    t3 = deinterleave_block(t4, K=432, a=103)

    # Layer 3: type-2 = type-3 (TCH/S 7.2 has no RCPC puncturing at this stage)
    t2 = t3

    # Layer 4: split into 2 voice frames (216 type-2 bits each)
    frame0 = split_frame_into_classes(t2[0:216])
    frame1 = split_frame_into_classes(t2[216:432])

    # ACELP-frame bit layout per ETSI EN 300 395-2 (137 codec bits / frame)
    acelp_layout = []
    for pos in range(1, 138):
        acelp_layout.append({
            'pos': pos,
            'class': acelp_position_to_class(pos),
            'field': acelp_position_to_field(pos),
        })

    def to_hex(arr):
        # pad to mult of 4 then convert
        bits = list(arr)
        while len(bits) % 4 != 0:
            bits.append(0)
        return ''.join(f'{(bits[i]<<3)|(bits[i+1]<<2)|(bits[i+2]<<1)|bits[i+3]:X}'
                       for i in range(0, len(bits), 4))

    return {
        'type5_hex': to_hex(t5),
        'type4_hex': to_hex(t4),
        'type3_hex': to_hex(t3),
        'type2_hex': to_hex(t2),
        'frame0': {
            'class0_t2_hex':  to_hex(frame0['class0_t2']),
            'class1_t2_hex':  to_hex(frame0['class1_t2']),
            'class2_t2_hex':  to_hex(frame0['class2_t2']),
            'crc_t2_hex':     to_hex(frame0['crc_t2']),
        },
        'frame1': {
            'class0_t2_hex':  to_hex(frame1['class0_t2']),
            'class1_t2_hex':  to_hex(frame1['class1_t2']),
            'class2_t2_hex':  to_hex(frame1['class2_t2']),
            'crc_t2_hex':     to_hex(frame1['crc_t2']),
        },
        'acelp_layout': acelp_layout,
        'note': 'Class1/Class2 type-2 bits are FEC-coded (rate-1/2 and -2/3 resp.). '
                'Viterbi-decoding to type-1 codec bits not implemented in this module. '
                'Class0 type-2 = type-1 codec bits directly.',
    }


# ============================================================================
# CLI for standalone test / unit run
# ============================================================================
if __name__ == '__main__':
    import sys
    # quick test: random 432 bits, scramb 0x4183F207 (Gold cell)
    np.random.seed(42)
    fake_t5 = np.random.randint(0, 2, 432, dtype=np.uint8)
    r = decode_tch_s_burst(fake_t5, scramb_init=0x4183F207)
    print('type5_hex:', r['type5_hex'][:32], '...')
    print('type4_hex:', r['type4_hex'][:32], '...')
    print('type3_hex:', r['type3_hex'][:32], '...')
    print('frame0 class0 hex:', r['frame0']['class0_t2_hex'])
    print('frame0 class1 hex:', r['frame0']['class1_t2_hex'][:24], '...')
    print('ACELP layout sample (pos 1..10):')
    for entry in r['acelp_layout'][:10]:
        print(f"  pos={entry['pos']:3d} class={entry['class']} field={entry['field']}")
