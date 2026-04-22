#!/usr/bin/env python3
"""gen_ul_mac_exp.py — Produce ul_mac_access_exp.hex for tb_ul_mac_access_parser.

Reads sim_out/ul_wav_exp.hex (13 bytes/record: crc_flag + 12 info bytes),
runs decode_ul.parse_mac_access() on each CRC-OK record, and packs the
parsed fields into one 32-bit hex word per record:

  [31:30]  pdu_type
  [29]     fill_bit
  [28:27]  encryption_mode
  [26]     access_ack
  [25:23]  address_type
  [22:13]  short_ssi (10 bits)
  [12:0]   reserved (0)

For CRC-FAIL records, writes 0 (TB skips these).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_ul import parse_mac_access


def main():
    src = 'sim_out/ul_wav_exp.hex'
    dst = 'sim_out/ul_mac_access_exp.hex'

    # $readmemh treats whitespace/newlines as separators. ul_wav_exp.hex has
    # one record per line, 13 space-separated bytes. Flatten to one byte per
    # memory address.
    bytes_flat = []
    with open(src) as f:
        for line in f:
            for tok in line.split():
                bytes_flat.append(int(tok, 16))

    n_rec = len(bytes_flat) // 13
    out_lines = []
    crc_ok_cnt = 0
    for r in range(n_rec):
        crc_flag = bytes_flat[r*13 + 0] & 1
        info_bytes = bytes_flat[r*13 + 1 : r*13 + 13]
        if not crc_flag:
            out_lines.append('00000000')
            continue
        bits92 = []
        for byte in info_bytes:
            for k in range(8):
                bits92.append((byte >> (7 - k)) & 1)
        bits92 = bits92[:92]
        parsed = parse_mac_access(bits92)
        if parsed is None:
            out_lines.append('00000000')
            continue
        val = 0
        val |= (parsed.get('pdu_type', 0)         & 0x3)  << 30
        val |= (parsed.get('fill_bit', 0)         & 0x1)  << 29
        val |= (parsed.get('encryption_mode', 0)  & 0x3)  << 27
        val |= (parsed.get('access_ack', 0)       & 0x1)  << 26
        val |= (parsed.get('addr_type', 0)        & 0x7)  << 23
        val |= (parsed.get('short_ssi_or_event_label', 0) & 0x3FF) << 13
        out_lines.append(f'{val:08X}')
        crc_ok_cnt += 1

    os.makedirs('sim_out', exist_ok=True)
    with open(dst, 'w') as f:
        f.write('\n'.join(out_lines) + '\n')
    print(f'wrote {dst}  ({n_rec} records, {crc_ok_cnt} CRC-OK)')


if __name__ == '__main__':
    main()
