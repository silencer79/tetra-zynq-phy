#!/usr/bin/env python3
"""gen_schf_reass_tv.py — test vectors for tb_ul_schf_reassembly.

Self-checking closed-loop for the multi-fragment accumulator:
 - build a chain: frag1 start (62 bits) + (N-1) × MAC-FRAG + 1 × MAC-END,
   with the exact MAC headers the accumulator parses
     FRAG: info[0..3] = {0,1,0,fill}              → payload info[4..267]  (264)
     END : info[0..9] = {0,1,1,fill, LI[5:0]}     → payload info[10..267] (258)
 - emit the decoded 268-bit info blocks (what tetra_ul_sch_f_decoder produces),
 - emit the expected reassembled body = frag1(62) ++ all payloads, bit per line.

Outputs (sim_out/):
  schf_reass_frag1.b  — 1 line, 62-bit binary (MSB = frag1_bits[61] = on-air bit30)
  schf_reass_frags.b  — N lines, each 268-bit binary (info[0] = MSB)
  schf_reass_exp.b    — <len> lines, one body bit each (body[0] first)
  schf_reass_meta.txt  — "N_FRAGS EXP_LEN"
"""
import os
import sys
import numpy as np

INFO = 268


def info_block(payload, is_end, fill=0, li=0):
    """Build a 268-bit MAC-FRAG/END info block. payload = list of bits."""
    b = [0] * INFO
    b[0] = 0
    b[1] = 1                       # mac_pdu_type = 01
    b[2] = 1 if is_end else 0      # subtype
    b[3] = fill & 1
    if is_end:
        for i in range(6):         # 6-bit length_ind at info[4..9]
            b[4 + i] = (li >> (5 - i)) & 1
        start = 10
    else:
        start = 4
    for i, bit in enumerate(payload):
        b[start + i] = bit & 1
    assert start + len(payload) == INFO, f"payload len {len(payload)} wrong for {'END' if is_end else 'FRAG'}"
    return b


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--out-dir', default='sim_out')
    ap.add_argument('--n-frags', type=int, default=5)   # total SCH/F frags incl. END
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    rng = np.random.default_rng(0x5C4F0002)

    frag1 = rng.integers(0, 2, size=62, dtype=np.int8).tolist()   # on-air 30..91, MSB-first
    n_frag_payload = args.n_frags - 1                              # FRAG count (rest is END)

    body = list(frag1)
    info_blocks = []
    for f in range(n_frag_payload):
        payload = rng.integers(0, 2, size=264, dtype=np.int8).tolist()
        info_blocks.append(info_block(payload, is_end=False, fill=f & 1))
        body += payload
    # final MAC-END
    end_payload = rng.integers(0, 2, size=258, dtype=np.int8).tolist()
    info_blocks.append(info_block(end_payload, is_end=True, fill=1, li=33))
    body += end_payload

    exp_len = len(body)
    assert exp_len == 62 + n_frag_payload * 264 + 258

    # Flat 1-bit-per-line (no endianness ambiguity; TB assigns bits explicitly).
    od = args.out_dir
    with open(os.path.join(od, 'schf_reass_frag1.b'), 'w') as f:
        for b in frag1:                # 62 lines: frag1[0..61]
            f.write(f"{b}\n")
    with open(os.path.join(od, 'schf_reass_frags.b'), 'w') as f:
        for blk in info_blocks:        # N*268 lines: block f, bit k = info_f[k]
            for b in blk:
                f.write(f"{b}\n")
    with open(os.path.join(od, 'schf_reass_exp.b'), 'w') as f:
        for b in body:                 # exp_len lines: body[0..]
            f.write(f"{b}\n")
    with open(os.path.join(od, 'schf_reass_meta.txt'), 'w') as f:
        f.write(f"{args.n_frags} {exp_len}\n")

    print(f"n_frags={args.n_frags} (={n_frag_payload} FRAG + 1 END), exp_len={exp_len} bits "
          f"({exp_len//8} B)")
    print(f"wrote {od}/schf_reass_frag1.b, schf_reass_frags.b ({args.n_frags} blocks), "
          f"schf_reass_exp.b ({exp_len} bits), schf_reass_meta.txt")


if __name__ == '__main__':
    main()
