#!/usr/bin/env python3
"""gen_sch_f_dec_tv.py — Clean SCH/F *decoder* test vectors for tb_ul_sch_f_decoder.

Closed-loop GATE: encode a known 268-bit info via the VERIFIED SCH/F TX chain
(`encode_sch_f` from gen_sch_f_tv.py — bit-exact against the RTL SCH/F encoder),
feed the 432 type-5 bits as clean softs to the RTL decoder, expect the same
268 info + crc_ok=1.

Produces:
  sim_out/ul_sch_f_soft.hex — N_BURSTS*432 signed 8-bit soft values (one/line)
  sim_out/ul_sch_f_exp.hex  — per burst: "01 <34 info bytes>"  (crc_ok + 268 bits)

Soft model: clean channel, bit=0 → +127, bit=1 → -127 (signed 8-bit, ETSI).
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sch_f_tv import encode_sch_f          # verified 268→432 TX chain
from decode_dl import make_scramb_code

INFO = 268
K    = 432


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--cc', type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--out-dir', default='sim_out')
    ap.add_argument('--n-bursts', type=int, default=8)
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'scramb_init = 0x{scramb_init:08X}')

    n_info_bytes = (INFO + 7) // 8   # 34
    rng = np.random.default_rng(0x5C4F0001)
    info_patterns = []
    for b in range(args.n_bursts):
        info = rng.integers(0, 2, size=INFO, dtype=np.int8).tolist()
        for i in range(8):                       # burst-index label in byte 0
            info[i] = (b >> (7 - i)) & 1
        info_patterns.append(info)

    soft_lines, exp_lines, nub_lines = [], [], []
    for info in info_patterns:
        type5 = encode_sch_f(info, scramb_init)
        assert len(type5) == K, f"type5 len {len(type5)} != {K}"
        for bit in type5:
            val = -127 if (bit & 1) else +127       # ETSI 8-bit: +127=bit0
            soft_lines.append(f"{val & 0xFF:02X}")
            # NUB 4-bit, INVERSE sign (positive = bit1): bit1→+7(0x7), bit0→-7(0x9)
            nub = 0x7 if (bit & 1) else 0x9
            nub_lines.append(f"{nub:01X}")

        info_bytes = []
        for bstart in range(0, INFO, 8):
            byte = 0
            for k in range(8):
                byte = (byte << 1) | (info[bstart + k] if bstart + k < INFO else 0)
            info_bytes.append(byte)
        assert len(info_bytes) == n_info_bytes
        exp_lines.append('01 ' + ' '.join(f"{x:02X}" for x in info_bytes))

    soft_path = os.path.join(args.out_dir, 'ul_sch_f_soft.hex')
    exp_path  = os.path.join(args.out_dir, 'ul_sch_f_exp.hex')
    nub_path  = os.path.join(args.out_dir, 'ul_sch_f_nubsoft.hex')
    with open(soft_path, 'w') as f:
        f.write('\n'.join(soft_lines) + '\n')
    with open(exp_path, 'w') as f:
        f.write('\n'.join(exp_lines) + '\n')
    with open(nub_path, 'w') as f:
        f.write('\n'.join(nub_lines) + '\n')
    print(f'wrote {soft_path}  ({len(soft_lines)} softs = {args.n_bursts}×{K})')
    print(f'wrote {exp_path}   ({args.n_bursts} records, {n_info_bytes} info bytes each)')
    print(f'wrote {nub_path}   (4-bit NUB-convention softs, {len(nub_lines)} values)')
    print(f'scramb_init = 0x{scramb_init:08X}  (TB: +SCRAMB_INIT=0x...)')


if __name__ == '__main__':
    main()
