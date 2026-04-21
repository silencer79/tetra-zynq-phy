#!/usr/bin/env python3
"""
gold_schedule.py — Tabelliert Burst-Typ pro (FN, TN) aus einer WAV.

Zweck: genauen Schedule der Gold-Zelle ermitteln, damit der FPGA-TX
exakt nachgebaut werden kann ("nicht mehr und nicht weniger").

Für jede Burst-Position im 255-Symbol-Grid:
  - STS-Korrelation (SB-Typ)
  - NTS1/NTS2-Korrelation (NDB1/NDB2)
  - Klassifikation (SB / NDB1 / NDB2 / empty)
  - (FN, TN, MN) aus BSCH-SYNC-PDU-Anker zurückgerechnet

Ausgabe:
  - Per-Burst CSV (stdout oder -o)
  - Aggregations-Tabelle pro (FN, TN) → Verteilung
"""

import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, BURST_SYMBOLS,
    SDB_OFF_SB1, SDB_OFF_STS, SDB_SB1,
    NSB_OFF_SB1, NSB_OFF_STS,
    NDB_OFF_NTS,
    STS_DIBITS, STS_DIFF_REF,
    NTS1_DIBITS, NTS1_DIFF_REF,
    NTS2_DIBITS, NTS2_DIFF_REF,
    dibits_to_symbols, demod_pi4dqpsk,
    _correlate_at,
    load_iq_file, estimate_freq_offset, rrc_filter,
    scrambler_seq, decode_channel, parse_sysinfo_sb,
)


def _phase_correct(iq, ts_sample_pos, sps, output_ts_sym_offset,
                   ts_dibits, ts_diff_ref):
    """Extract 255 sym from grid position, apply linear+quadratic phase fit
    using training-seq. Returns (burst_syms, ts_corr, refined_ts_pos)."""
    n = len(iq)
    best_c = 0.0
    best_t = 0.0
    for dt in np.linspace(-sps, sps, int(4 * sps) + 1):
        c = _correlate_at(iq, ts_sample_pos + dt, sps, ts_dibits, ts_diff_ref)
        if c > best_c:
            best_c, best_t = c, dt
    for dt in np.linspace(best_t - 0.5, best_t + 0.5, 21):
        c = _correlate_at(iq, ts_sample_pos + dt, sps, ts_dibits, ts_diff_ref)
        if c > best_c:
            best_c, best_t = c, dt
    ts_pos_final = ts_sample_pos + best_t
    burst_start = ts_pos_final - output_ts_sym_offset * sps
    if burst_start < 0 or burst_start + BURST_SYMBOLS * sps >= n:
        return None, best_c, ts_pos_final
    sym_indices = np.round(np.arange(BURST_SYMBOLS) * sps + burst_start).astype(int)
    sym_indices = np.clip(sym_indices, 0, n - 1)
    burst_syms = iq[sym_indices]
    ts_ref = dibits_to_symbols(ts_dibits)
    ts_dr = ts_ref[1:] * np.conj(ts_ref[:-1])
    s_idx = np.clip(np.arange(len(ts_dibits)) + output_ts_sym_offset, 0, BURST_SYMBOLS - 1)
    ss = burst_syms[s_idx]
    sd = ss[1:] * np.conj(ss[:-1])
    pe = np.angle(sd * np.conj(ts_dr))
    if len(pe) > 1:
        sl, ic = np.polyfit(np.arange(len(pe)), pe, 1)
        nr = np.arange(BURST_SYMBOLS, dtype=np.float64) - float(output_ts_sym_offset)
        burst_syms = burst_syms * np.exp(-1j * (ic * nr + 0.5 * sl * nr * (nr - 1.0)))
    return burst_syms, best_c, ts_pos_final


def analyze(wav_path, csv_out=None, sb_thresh=0.5, nts_thresh=0.55):
    iq, sr = load_iq_file(wav_path)
    iq = iq.astype(np.complex64)
    print(f"sr={sr} samples={len(iq)} ({len(iq)/sr:.2f}s)")

    fo = estimate_freq_offset(iq, sr)
    print(f"freq_offset={fo:+.1f} Hz")
    if abs(fo) > 10:
        t = np.arange(len(iq)) / sr
        iq = iq * np.exp(-1j * 2 * np.pi * fo * t)

    sps_target = 8
    target_rate = SYMBOL_RATE * sps_target
    decim = max(1, int(sr / target_rate))
    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sr
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2)) * np.hanning(ntaps)
        h /= np.sum(h)
        iq = np.convolve(iq, h, mode='same')[::decim]
    sps = (sr / decim) / SYMBOL_RATE
    rrc = rrc_filter(int(6 * sps) * 2 + 1, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')
    print(f"decim={decim}x sps={sps:.2f}")

    n = len(iq)
    burst_spacing = BURST_SYMBOLS * sps
    step = max(1, int(sps / 2))
    scan_limit = min(n - int(BURST_SYMBOLS * sps), n)
    peaks = []
    for off in range(0, scan_limit, step):
        c = _correlate_at(iq, off, sps, STS_DIBITS, STS_DIFF_REF)
        if c >= 0.35:
            peaks.append((off, c))
    peaks.sort(key=lambda x: -x[1])
    deduped = []
    for off, c in peaks:
        if all(abs(off - po) >= burst_spacing // 2 for po, _ in deduped):
            deduped.append((off, c))
        if len(deduped) >= 30:
            break
    if not deduped:
        print("no STS peaks — aborting")
        return

    # Lock: find layout + anchor
    layout = None
    anchor_sts_pos = None
    anchor_fn = anchor_tn = anchor_mn = None
    for sts_off, _ in deduped:
        for lname, l_sb1, l_sts in [('non-continuous', NSB_OFF_SB1, NSB_OFF_STS),
                                     ('continuous', SDB_OFF_SB1, SDB_OFF_STS)]:
            bsyms, _, ts_pos = _phase_correct(iq, sts_off, sps, l_sts,
                                               STS_DIBITS, STS_DIFF_REF)
            if bsyms is None:
                continue
            db = demod_pi4dqpsk(bsyms)
            s = l_sb1 - 1
            if s < 0 or s + SDB_SB1 > len(db):
                continue
            sb1_bits = np.zeros(SDB_SB1 * 2, dtype=np.int32)
            sb1_bits[0::2] = (db[s:s+SDB_SB1] >> 1) & 1
            sb1_bits[1::2] = db[s:s+SDB_SB1] & 1
            sb1_d = (sb1_bits ^ scrambler_seq(3, 120)) & 1
            ok, info, _ = decode_channel(sb1_d, 120, 11, 60)
            if ok:
                layout = lname
                si = parse_sysinfo_sb(info)
                anchor_sts_pos = ts_pos
                anchor_fn = si['Frame']
                anchor_tn = si['TimeSlot']  # 0-based
                anchor_mn = si['MultiFrame']
                print(f"LOCKED [{lname}] MCC={si['MCC']} MNC={si['MNC']} "
                      f"CC={si['ColourCode']} FN={anchor_fn} TN={anchor_tn} MN={anchor_mn}")
                break
        if layout:
            break
    if layout is None:
        print("cell lock failed")
        return

    # Layout STS offset (tetra-kit always uses SDB layout for bit emission,
    # but for corr we use the detected layout offset)
    l_sts = SDB_OFF_STS if layout == 'continuous' else NSB_OFF_STS

    # Walk the grid from anchor
    pos = anchor_sts_pos
    while pos - burst_spacing >= 0:
        pos -= burst_spacing
    grid = []
    while pos < n - int(BURST_SYMBOLS * sps):
        grid.append(pos)
        pos += burst_spacing

    # Anchor burst_idx
    anchor_idx = int(round((anchor_sts_pos - grid[0]) / burst_spacing))

    # Per-burst classification
    rows = []
    for bi, gpos in enumerate(grid):
        # TN/FN/MN via modular walk from anchor
        delta = bi - anchor_idx
        # TETRA: burst_idx stepping by 1 advances TN by 1 (wraps FN)
        # anchor_tn is 0-based. Compute new TN/FN/MN:
        total_slots = 4
        # Convert to absolute slot index: (mn-1)*72 + (fn-1)*4 + tn
        # All 1-based except tn
        abs_slot_anchor = (anchor_mn - 1) * 18 * 4 + (anchor_fn - 1) * 4 + anchor_tn
        abs_slot = abs_slot_anchor + delta
        mn = (abs_slot // (18 * 4)) % 60 + 1
        rem = abs_slot % (18 * 4)
        fn = rem // 4 + 1
        tn = rem % 4

        nts_pred = gpos + (NDB_OFF_NTS - l_sts) * sps
        _, s_c, _ = _phase_correct(iq, gpos, sps, l_sts,
                                    STS_DIBITS, STS_DIFF_REF)
        _, n1_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS1_DIBITS, NTS1_DIFF_REF)
        _, n2_c, _ = _phase_correct(iq, nts_pred, sps, NDB_OFF_NTS,
                                     NTS2_DIBITS, NTS2_DIFF_REF)
        best_nts = max(n1_c, n2_c)
        if s_c >= best_nts and s_c >= sb_thresh:
            cls = 'SB'
        elif best_nts >= nts_thresh:
            cls = 'NDB1' if n1_c >= n2_c else 'NDB2'
        else:
            cls = 'empty'
        rows.append((bi, fn, tn, mn, cls, s_c, n1_c, n2_c))

    # CSV
    if csv_out:
        with open(csv_out, 'w') as f:
            f.write("burst_idx,FN,TN,MN,class,sts_c,nts1_c,nts2_c\n")
            for r in rows:
                f.write(f"{r[0]},{r[1]},{r[2]},{r[3]},{r[4]},{r[5]:.3f},{r[6]:.3f},{r[7]:.3f}\n")
        print(f"CSV written: {csv_out} ({len(rows)} bursts)")

    # Aggregate per (FN, TN)
    from collections import Counter, defaultdict
    tbl = defaultdict(Counter)
    for _, fn, tn, _, cls, *_ in rows:
        tbl[(fn, tn)][cls] += 1

    print()
    print("Schedule (rows=FN 1..18, cols=TN 0..3): SB / NDB1 / NDB2 / empty")
    print("FN  | TN0                  | TN1                  | TN2                  | TN3")
    print("----+" + "+".join(["-" * 22] * 4))
    for fn in range(1, 19):
        cells = []
        for tn in range(4):
            c = tbl[(fn, tn)]
            cells.append(f"{c['SB']:4d}/{c['NDB1']:4d}/{c['NDB2']:3d}/{c['empty']:3d}")
        print(f"{fn:2d}  | " + " | ".join(cells))

    # Totals
    total = Counter()
    for c in tbl.values():
        total += c
    tot = sum(total.values())
    print()
    print(f"Total bursts: {tot}")
    for k in ('SB', 'NDB1', 'NDB2', 'empty'):
        v = total[k]
        print(f"  {k:6s} {v:5d}  {100*v/tot:5.1f}%")


# ===========================================================================
# Gold preset blob — matches rtl/tx/tetra_slot_schedule.v layout.
#
# Entry layout (plan §4 Stufe 3, tetra_slot_schedule.v):
#   [15:12] payload_class  (0=STATIC_BROADCAST, 1=NULL_PDU, 2=TCH)
#   [11:6]  payload_idx    (6 bit)
#   [5:4]   burst_type     (00=NDB, 01=SDB, 10=reserved, 11=idle)
#   [3]     ndb2
#   [2]     enable
#   [1]     sys_time_inject
#   [0]     reserved
#
# Addressing (dense):
#   dense_idx = mn*72 + fn*4 + tn     (mn in 0..3, fn in 0..17, tn in 0..3)
# AXI word index:
#   word_idx  = dense_idx / 2          (0..143)
#   lower 16b = entry at dense_idx = 2*word_idx (even)
#   upper 16b = entry at dense_idx = 2*word_idx+1 (odd)
#
# Blob byte layout: 576 bytes = 144 LE 32-bit words.
# ===========================================================================

# payload_class encoding
PCLASS_STATIC_BROADCAST = 0
PCLASS_NULL_PDU         = 1
PCLASS_TCH              = 2

# burst_type encoding
BT_NDB  = 0b00
BT_SDB  = 0b01
BT_IDLE = 0b11

# payload_idx canonical values (matches TB gold_entry + SW constants)
PIDX_SB         = 3   # full synchronisation burst (SYNC + SYSINFO)
PIDX_BNCH       = 1   # BNCH / SCH-HD variant
PIDX_NULL0      = 0   # NULL PDU variant 0


def _pack_entry(payload_class, payload_idx, burst_type,
                ndb2=0, enable=1, sys_time_inject=0, reserved=0):
    assert 0 <= payload_class <= 0xF
    assert 0 <= payload_idx <= 0x3F
    assert 0 <= burst_type <= 0x3
    v  = (payload_class & 0xF) << 12
    v |= (payload_idx & 0x3F) << 6
    v |= (burst_type & 0x3) << 4
    v |= (ndb2 & 1) << 3
    v |= (enable & 1) << 2
    v |= (sys_time_inject & 1) << 1
    v |= (reserved & 1)
    return v & 0xFFFF


def gold_entry(mn, fn, tn):
    """Reference gold preset — must match tb/tb_tx_slot_schedule.v::gold_entry.

    mn : 0..3 (multiframe-mod-4 bucket)
    fn : 0..17 (internal 0-based frame; fn=17 == TETRA FN=18 special frame)
    tn : 0..3
    """
    assert 0 <= mn <= 3
    assert 0 <= fn <= 17
    assert 0 <= tn <= 3

    if tn != 0:
        # TN=1,2,3 — SDB with sys_time_inject on every slot
        return _pack_entry(PCLASS_STATIC_BROADCAST, PIDX_SB, BT_SDB,
                           ndb2=0, enable=1, sys_time_inject=1)

    # TN=0 branch
    if fn == 17 and mn == 2:
        return _pack_entry(PCLASS_STATIC_BROADCAST, PIDX_SB, BT_SDB,
                           ndb2=0, enable=1, sys_time_inject=1)
    if fn == 17:
        return _pack_entry(PCLASS_STATIC_BROADCAST, PIDX_BNCH, BT_SDB,
                           ndb2=0, enable=1, sys_time_inject=0)
    # TN=0 fn<17 — NDB2 (two standalone SCH/HD halves per burst).
    # Matches Gold cell behaviour: blk1/blk2 each carry SCH/HD BNCH
    # SYSINFO (124→216 bit), NTS2 training sequence.  NDB1 (SCH/F full
    # burst) is not used by real cells on TN=0 traffic slots.
    return _pack_entry(PCLASS_STATIC_BROADCAST, PIDX_NULL0, BT_NDB,
                       ndb2=1, enable=1, sys_time_inject=0)


def gen_gold_schedule_blob():
    """Generate the 576-byte AXI blob for the gold preset.

    Layout matches rtl/tx/tetra_slot_schedule.v: 144 little-endian 32-bit
    words, each packing two 16-bit entries (even in lower half, odd in
    upper half).  dense_idx = mn*72 + fn*4 + tn.
    """
    entries = [0] * 288
    for mn in range(4):
        for fn in range(18):
            for tn in range(4):
                dense_idx = mn * 72 + fn * 4 + tn
                entries[dense_idx] = gold_entry(mn, fn, tn)

    blob = bytearray(576)
    for word_idx in range(144):
        lo = entries[2 * word_idx]
        hi = entries[2 * word_idx + 1]
        word = (hi << 16) | lo
        blob[4 * word_idx + 0] = word & 0xFF
        blob[4 * word_idx + 1] = (word >> 8) & 0xFF
        blob[4 * word_idx + 2] = (word >> 16) & 0xFF
        blob[4 * word_idx + 3] = (word >> 24) & 0xFF
    return bytes(blob)


def gen_gold_schedule_c_header():
    """Emit a C header with `const uint32_t tetra_gold_schedule[144]`."""
    blob = gen_gold_schedule_blob()
    lines = []
    lines.append("/* Generated by scripts/gold_schedule.py --emit-c-header */")
    lines.append("/* DO NOT EDIT — regenerate to update. */")
    lines.append("#ifndef TETRA_GOLD_SCHEDULE_H")
    lines.append("#define TETRA_GOLD_SCHEDULE_H")
    lines.append("")
    lines.append("#include <stdint.h>")
    lines.append("")
    lines.append("#define TETRA_GOLD_SCHEDULE_WORDS 144u")
    lines.append("#define TETRA_GOLD_SCHEDULE_BYTES 576u")
    lines.append("")
    lines.append("static const uint32_t tetra_gold_schedule[144] = {")
    for wi in range(144):
        word = (blob[4*wi] |
                (blob[4*wi+1] << 8) |
                (blob[4*wi+2] << 16) |
                (blob[4*wi+3] << 24))
        sep = "," if wi < 143 else ""
        comment = f"  /* word {wi:3d}: entries {2*wi:3d},{2*wi+1:3d} */"
        lines.append(f"    0x{word:08x}{sep}{comment}")
    lines.append("};")
    lines.append("")
    lines.append("#endif /* TETRA_GOLD_SCHEDULE_H */")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav", nargs="?", help="WAV input (omit with --emit-blob / --emit-c-header)")
    ap.add_argument("-o", "--csv", help="CSV output path (analyze mode)")
    ap.add_argument("--emit-blob", metavar="PATH",
                    help="Write the 576-byte gold schedule blob and exit")
    ap.add_argument("--emit-c-header", metavar="PATH",
                    help="Write a C header with the gold schedule table and exit")
    args = ap.parse_args()

    if args.emit_blob:
        blob = gen_gold_schedule_blob()
        with open(args.emit_blob, "wb") as f:
            f.write(blob)
        print(f"wrote {len(blob)} bytes -> {args.emit_blob}")
        return
    if args.emit_c_header:
        hdr = gen_gold_schedule_c_header()
        with open(args.emit_c_header, "w") as f:
            f.write(hdr)
        print(f"wrote C header ({len(hdr)} chars) -> {args.emit_c_header}")
        return

    if not args.wav:
        ap.error("wav is required unless --emit-blob / --emit-c-header is used")
    analyze(args.wav, csv_out=args.csv)


if __name__ == "__main__":
    main()
