#!/usr/bin/env python3
"""Verify SB1 encoder: compare SW reference vs RTL algorithm for BSCH encoding."""

# Config from running tetra_sysinfo command line
CFG = {
    'system_code': 1,
    'colour_code': 49,
    'sharing_mode': 0,
    'ts_reserved_frames': 0,
    'u_plane': 0,
    'frame_18_ext': 0,
    'mcc': 901,
    'mnc': 9998,
    'ncb': 0,
    'csl': 0,
    'late_entry': 0,
}

def parity5(x):
    """Parity of 5-bit value."""
    x ^= (x >> 4)
    x ^= (x >> 2)
    x ^= (x >> 1)
    return x & 1

def build_pdu(cfg, timeslot, frame, multiframe):
    """Build 60-bit SYNC PDU, return as list of bits (MSB first)."""
    bits = []
    def pack(val, width):
        for i in range(width-1, -1, -1):
            bits.append((val >> i) & 1)

    pack(cfg['system_code'], 4)
    pack(cfg['colour_code'], 6)
    pack(timeslot, 2)
    pack(frame, 5)
    pack(multiframe, 6)
    pack(cfg['sharing_mode'], 2)
    pack(cfg['ts_reserved_frames'], 3)
    pack(cfg['u_plane'], 1)
    pack(cfg['frame_18_ext'], 1)
    pack(0, 1)  # reserved
    pack(cfg['mcc'], 10)
    pack(cfg['mnc'], 14)
    pack(cfg['ncb'], 2)
    pack(cfg['csl'], 2)
    pack(cfg['late_entry'], 1)

    assert len(bits) == 60, f"PDU length {len(bits)} != 60"
    return bits

def crc16(bits):
    """CRC-16-CCITT over bit array. Returns 76 bits (60 data + 16 CRC)."""
    crc = 0xFFFF
    for b in bits:
        fb = (b & 1) ^ ((crc >> 15) & 1)
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x1021

    crc ^= 0xFFFF  # ones complement
    out = list(bits)
    for i in range(16):
        out.append((crc >> (15 - i)) & 1)
    return out

def conv_encode_r14(bits):
    """Rate 1/4 mother code, K=5. Returns 4*len bits."""
    sr = 0
    out = []
    for b in bits:
        sr = ((sr << 1) | (b & 1)) & 0x1F
        out.append(parity5(sr & 0x13))  # G1
        out.append(parity5(sr & 0x1D))  # G2
        out.append(parity5(sr & 0x17))  # G3
        out.append(parity5(sr & 0x1B))  # G4
    return out

def puncture_r23(mother):
    """P_2/3 puncture: per 8 mother bits, keep [0],[1],[4]."""
    out = []
    for i in range(0, len(mother), 8):
        out.append(mother[i + 0])  # g1(a)
        out.append(mother[i + 1])  # g2(a)
        out.append(mother[i + 4])  # g1(b)
    return out

def interleave_bsch(bits):
    """Multiplicative interleaver N=120, a=11."""
    N = 120
    a = 11
    out = [0] * N
    for k in range(1, N + 1):
        j = 1 + (a * k) % N
        out[j - 1] = bits[k - 1]
    return out

def scramble_bsch(bits):
    """Fibonacci LFSR scrambler, init=3, 120 bits."""
    lfsr = 3
    out = []
    for b in bits:
        # Feedback: taps at 31,25,22,21,15,11,10,9,7,6,4,3,1,0
        fb = 0
        for tap in [31, 25, 22, 21, 15, 11, 10, 9, 7, 6, 4, 3, 1, 0]:
            fb ^= (lfsr >> tap) & 1
        out.append(b ^ fb)
        lfsr = ((fb << 31) | (lfsr >> 1)) & 0xFFFFFFFF
    return out

def sw_encode_bsch(cfg, timeslot, frame, multiframe):
    """Full SW BSCH encoding chain."""
    pdu = build_pdu(cfg, timeslot, frame, multiframe)
    type2 = crc16(pdu)
    type3 = type2 + [0, 0, 0, 0]  # tail
    assert len(type3) == 80
    mother = conv_encode_r14(type3)
    assert len(mother) == 320
    type4 = puncture_r23(mother)
    assert len(type4) == 120
    type4i = interleave_bsch(type4)
    type5 = scramble_bsch(type4i)
    return type5

def rtl_encode_bsch(cfg, timeslot, frame, multiframe):
    """RTL-equivalent BSCH encoding (simulating tetra_sb1_encoder.v)."""
    pdu = build_pdu(cfg, timeslot, frame, multiframe)

    # CRC-16 (same as SW)
    crc = 0xFFFF
    for b in pdu:
        fb = (b & 1) ^ ((crc >> 15) & 1)
        crc = (crc << 1) & 0xFFFF
        if fb:
            crc ^= 0x1021

    # Type-3: PDU + ~CRC + tail
    crc_inv = crc ^ 0xFFFF
    type3_bits = list(pdu)
    for i in range(16):
        type3_bits.append((crc_inv >> (15 - i)) & 1)
    type3_bits += [0, 0, 0, 0]
    assert len(type3_bits) == 80

    # RCPC with inline puncture (RTL style)
    conv_sr = 0  # 4-bit shift register
    rcpc_out = [0] * 120
    rcpc_idx = 0
    bit_phase = 0

    for i in range(80):
        din = type3_bits[i]
        conv_full = ((conv_sr & 0xF) << 1) | (din & 1)  # {conv_sr[3:0], din}

        g1 = parity5(conv_full & 0x13)  # 10011
        g2 = parity5(conv_full & 0x1D)  # 11101

        if bit_phase == 0:  # even
            rcpc_out[rcpc_idx] = g1
            rcpc_out[rcpc_idx + 1] = g2
            rcpc_idx += 2
        else:  # odd
            rcpc_out[rcpc_idx] = g1
            rcpc_idx += 1

        bit_phase = 1 - bit_phase
        conv_sr = ((conv_sr << 1) | din) & 0xF  # shift left, 4-bit

    assert rcpc_idx == 120, f"rcpc_idx={rcpc_idx}"

    # Interleave (same as SW)
    type4i = interleave_bsch(rcpc_out)

    # Scramble (same as SW)
    type5 = scramble_bsch(type4i)
    return type5

# ---- SDB slot computation ----
def sdb_slot_sw(mn):
    """SW: BSCH_TN = 4 - ((MN + 1) % 4), then -1 for 0-based."""
    bsch_tn_1based = 4 - ((mn + 1) % 4)
    return bsch_tn_1based - 1

def sdb_slot_rtl(mn):
    """RTL: case(mn[1:0])."""
    lsb = mn & 3
    return {0: 2, 1: 1, 2: 0, 3: 3}[lsb]

# ---- Test ----
print("=== SDB slot comparison ===")
for mn in range(1, 61):
    sw = sdb_slot_sw(mn)
    rtl = sdb_slot_rtl(mn)
    if sw != rtl:
        print(f"  MISMATCH MN={mn}: SW={sw} RTL={rtl}")
print("  SDB slot: all match" if all(sdb_slot_sw(mn) == sdb_slot_rtl(mn) for mn in range(1,61)) else "  SDB slot: MISMATCHES found!")

print("\n=== Encoder comparison ===")
mismatches = 0
for fn in [1, 5, 10, 18]:
    for mn in [1, 2, 3, 4, 30, 59, 60]:
        tn = sdb_slot_sw(mn)
        sw = sw_encode_bsch(CFG, tn, fn, mn)
        rtl = rtl_encode_bsch(CFG, tn, fn, mn)

        if sw != rtl:
            mismatches += 1
            diffs = sum(1 for a, b in zip(sw, rtl) if a != b)
            print(f"  MISMATCH FN={fn:2d} MN={mn:2d} TN={tn}: {diffs}/120 bits differ")

            # Find first difference location
            for idx, (a, b) in enumerate(zip(sw, rtl)):
                if a != b:
                    print(f"    First diff at bit {idx}: SW={a} RTL={b}")
                    break

            # Check if pre-interleave differs
            # Recompute without interleave+scramble
            pdu = build_pdu(CFG, tn, fn, mn)
            type2 = crc16(pdu)
            type3 = type2 + [0,0,0,0]
            mother_sw = conv_encode_r14(type3)
            type4_sw = puncture_r23(mother_sw)

            # RTL conv
            conv_sr = 0
            rcpc_rtl = [0]*120
            rcpc_idx = 0
            bit_phase = 0
            for i in range(80):
                din = type3[i]
                conv_full = ((conv_sr & 0xF) << 1) | (din & 1)
                g1 = parity5(conv_full & 0x13)
                g2 = parity5(conv_full & 0x1D)
                if bit_phase == 0:
                    rcpc_rtl[rcpc_idx] = g1
                    rcpc_rtl[rcpc_idx+1] = g2
                    rcpc_idx += 2
                else:
                    rcpc_rtl[rcpc_idx] = g1
                    rcpc_idx += 1
                bit_phase = 1 - bit_phase
                conv_sr = ((conv_sr << 1) | din) & 0xF

            rcpc_diffs = sum(1 for a,b in zip(type4_sw, rcpc_rtl) if a != b)
            print(f"    Pre-interleave RCPC diffs: {rcpc_diffs}/120")
        else:
            print(f"  OK   FN={fn:2d} MN={mn:2d} TN={tn}")

if mismatches == 0:
    print("\n*** ALL TESTS PASSED — SW and RTL encoders produce identical output ***")
else:
    print(f"\n*** {mismatches} MISMATCHES FOUND ***")
