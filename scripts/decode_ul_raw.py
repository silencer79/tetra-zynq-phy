#!/usr/bin/env python3
"""decode_ul_raw.py — full MAC-ACCESS + TM-SDU layout decoder for UL RA PDUs
captured by tetra_ul_mon (board daemon).

Usage:
    # From the log line "raw=6448304 2C664880 F13E8280" you can paste either
    # the concatenated form (as printed) or the three-word hex form:
    python3 scripts/decode_ul_raw.py 64483042C664880F13E8280
    python3 scripts/decode_ul_raw.py 6448304 2C664880 F13E8280
    # Or tail the board log directly (reads last N raw lines):
    python3 scripts/decode_ul_raw.py --board --last 5

Why this script:
    tetra_ul_mon decodes only the MAC-ACCESS header (first 19 bits) and prints
    the remaining 73 bits as raw hex.  The Location-Update-Type field (the
    one that MUST match the D-LOCATION-UPDATE-ACCEPT we send back) lives
    somewhere inside that 73-bit tail.  This script tries several plausible
    ETSI §21.4.3.3 layouts in parallel and shows what each yields so we can
    tell which is real.

Conventions:
    - info_bits[i] = ETSI bit i = i-th bit on air (MSB-first per §21.4.3.3).
    - Packed into three registers by the RTL:
        RAW_0 (32b) = info_bits[31:0]   — bit i of reg == ETSI bit i
        RAW_1 (32b) = info_bits[63:32]
        RAW_2 (28b) = info_bits[91:64]
"""
from __future__ import annotations
import sys
import argparse

MLE_PDISC = {
    0: "Reserved", 1: "MM", 2: "CMCE", 3: "Reserved",
    4: "SNDCP",    5: "MLE", 6: "MGMT", 7: "Testing",
}
# ETSI §16.10.37 — U-/D- Location update (accept) type share values
LOC_UPD_TYPE = {
    0: "Roaming",           1: "Temporary",
    2: "Periodic",          3: "ITSI attach",
    4: "Call restoration",  5: "Migrating",
    6: "Demand",            7: "Disabled MS",
}
MM_PDU_TYPE_U = {
    # §16.10.39 uplink
    0x0: "U-OTAR",            0x1: "U-AUTHENTICATION",
    0x2: "U-CK CHANGE RESP",  0x3: "U-DISABLE STATUS",
    0x4: "U-LOC UPDATE DEMAND", 0x5: "U-MM STATUS",
    0x8: "U-ATTACH/DETACH GRP ID",
    0x9: "U-ATTACH/DETACH GRP ID ACK",
    0xc: "U-TEI PROVIDE",
    0xf: "U-MM PDU / FUNCTION NOT SUPPORTED",
}
LLC_PDU_TYPE = {
    0x0: "BL-ADATA",       0x1: "BL-DATA",
    0x2: "BL-UDATA",       0x3: "BL-ACK",
    0x4: "BL-ADATA+FCS",   0x5: "BL-DATA+FCS",
    0x6: "BL-UDATA+FCS",   0x7: "BL-ACK+FCS",
    0xc: "SL-DATA",        0xd: "SL-FINAL",
    0xe: "SL-BLOCK-ACK",
}

def parse_hex_args(args: list[str]) -> list[int]:
    """Accept either one 23-char hex string or three words."""
    tok = [a.replace(" ", "").replace(",", "").replace("_", "") for a in args]
    joined = "".join(tok).lower()
    joined = joined.lstrip("0x")
    if len(joined) == 23:
        r2 = int(joined[0:7],  16)
        r1 = int(joined[7:15], 16)
        r0 = int(joined[15:23], 16)
        return [r2, r1, r0]
    if len(tok) == 3:
        return [int(tok[0], 16), int(tok[1], 16), int(tok[2], 16)]
    raise ValueError(f"cannot parse hex args: {args!r}")

def to_bits(r2: int, r1: int, r0: int) -> list[int]:
    bits = [0] * 92
    for i in range(32):
        bits[i]    = (r0 >> i) & 1
        bits[32+i] = (r1 >> i) & 1
    for i in range(28):
        bits[64+i] = (r2 >> i) & 1
    return bits

def field(bits: list[int], start: int, n: int) -> int:
    v = 0
    for i in range(n):
        v = (v << 1) | bits[start + i]
    return v

def bits_to_hex_msb(bits: list[int], start: int, n: int) -> str:
    """Show bits[start:start+n] as 0bXXX and hex."""
    s = ''.join(str(b) for b in bits[start:start+n])
    pad = '0' * ((-n) % 4)
    return f"0b{s} = 0x{int(s+pad, 2) >> len(pad):0{(n+3)//4}X}" if n else "∅"

def parse(r2: int, r1: int, r0: int) -> None:
    bits = to_bits(r2, r1, r0)
    print(f"  raw: r2=0x{r2:07X} r1=0x{r1:08X} r0=0x{r0:08X}")
    print(f"  92 bits (MSB-first, | every 8):")
    print("    " + " | ".join(
        ''.join(str(b) for b in bits[i:i+8]) for i in range(0, 92, 8)))

    # --- MAC-ACCESS header (fixed per tetra_ul_mac_access_parser.v) ---
    pdu_type    = field(bits, 0, 2)
    fill_bit    = bits[2]
    enc_mode    = field(bits, 3, 2)
    access_ack  = bits[5]
    addr_type   = field(bits, 6, 3)
    # addr content depends on addr_type; for at=2 (Event Label) it's 10 bits
    ADDR_WIDTH = {0: 0, 1: 24, 2: 10, 3: 24, 4: 48, 5: 34, 6: 30, 7: 58}
    addr_w = ADDR_WIDTH.get(addr_type, 10)
    addr_val = field(bits, 9, addr_w)
    pos_after_addr = 9 + addr_w
    print(f"  MAC-ACCESS hdr:")
    print(f"    pdu_type    = {pdu_type}  (0=MAC-ACCESS)")
    print(f"    fill_bit    = {fill_bit}")
    print(f"    enc_mode    = {enc_mode}")
    print(f"    access_ack  = {access_ack}")
    print(f"    addr_type   = {addr_type}  ({['NULL','SSI','Event','USSI','SMI','SSI+EV','SSI+US','SMI+EV'][addr_type]})")
    print(f"    addr ({addr_w}b) = {addr_val}  (0x{addr_val:X})")
    print(f"  -> header end at bit {pos_after_addr}, TM-SDU has {92-pos_after_addr} bits")
    print()

    # --- Hypotheses for TM-SDU layout ---
    pos = pos_after_addr
    remaining = 92 - pos
    print("  === Hypothesis A: direct MLE-PD + MM (no LI, no LLC) ===")
    hA_mle   = field(bits, pos,   3)
    hA_mmpdu = field(bits, pos+3, 4)
    hA_lut   = field(bits, pos+7, 3)
    print(f"    MLE PDisc     [bit {pos}..]   = {hA_mle}  ({MLE_PDISC.get(hA_mle,'?')})")
    print(f"    MM PDU-type   [bit {pos+3}..] = {hA_mmpdu} ({MM_PDU_TYPE_U.get(hA_mmpdu,'?')})")
    print(f"    LocUpd type   [bit {pos+7}..] = {hA_lut}  ({LOC_UPD_TYPE.get(hA_lut,'?')})")

    print("  === Hypothesis B: 6-bit LI, then MLE-PD + MM ===")
    hB_li    = field(bits, pos,   6)
    hB_mle   = field(bits, pos+6, 3)
    hB_mmpdu = field(bits, pos+9, 4)
    hB_lut   = field(bits, pos+13, 3)
    print(f"    Length Ind    [bit {pos}..]   = {hB_li}")
    print(f"    MLE PDisc     [bit {pos+6}..] = {hB_mle}  ({MLE_PDISC.get(hB_mle,'?')})")
    print(f"    MM PDU-type   [bit {pos+9}..] = {hB_mmpdu} ({MM_PDU_TYPE_U.get(hB_mmpdu,'?')})")
    print(f"    LocUpd type   [bit {pos+13}..]= {hB_lut}  ({LOC_UPD_TYPE.get(hB_lut,'?')})")

    print("  === Hypothesis C: LLC BL-ADATA (4+1+1), then MLE-PD + MM ===")
    hC_llc   = field(bits, pos,   4)
    hC_nr    = bits[pos+4]
    hC_ns    = bits[pos+5]
    hC_mle   = field(bits, pos+6, 3)
    hC_mmpdu = field(bits, pos+9, 4)
    hC_lut   = field(bits, pos+13, 3)
    print(f"    LLC PDU-type  [bit {pos}..]   = 0x{hC_llc:X} ({LLC_PDU_TYPE.get(hC_llc,'?')})")
    print(f"    NR/NS         [bit {pos+4}..] = {hC_nr}/{hC_ns}")
    print(f"    MLE PDisc     [bit {pos+6}..] = {hC_mle}  ({MLE_PDISC.get(hC_mle,'?')})")
    print(f"    MM PDU-type   [bit {pos+9}..] = {hC_mmpdu} ({MM_PDU_TYPE_U.get(hC_mmpdu,'?')})")
    print(f"    LocUpd type   [bit {pos+13}..]= {hC_lut}  ({LOC_UPD_TYPE.get(hC_lut,'?')})")

    print("  === Hypothesis D: 6-bit LI, direct MM (no MLE, no LLC) ===")
    hD_li    = field(bits, pos,   6)
    hD_mmpdu = field(bits, pos+6, 4)
    hD_lut   = field(bits, pos+10, 3)
    print(f"    Length Ind    [bit {pos}..]   = {hD_li}")
    print(f"    MM PDU-type   [bit {pos+6}..] = {hD_mmpdu} ({MM_PDU_TYPE_U.get(hD_mmpdu,'?')})")
    print(f"    LocUpd type   [bit {pos+10}..]= {hD_lut}  ({LOC_UPD_TYPE.get(hD_lut,'?')})")

    print("  === Hypothesis E (ETSI §21.4.3.3 match): 4-bit aux + MM direct ===")
    #   bits 19-22: aux/reservation-requirement/pres-flags (4 bits)
    #   bits 23-26: MM PDU-type (4 bit, upper-layer)
    #   bits 27-29: Location update type (3 bit)
    hE_aux   = field(bits, pos,   4)
    hE_mmpdu = field(bits, pos+4, 4)
    hE_lut   = field(bits, pos+8, 3)
    print(f"    Aux/flags     [bit {pos}..{pos+3}]   = 0x{hE_aux:X} (pres-flags / reservation-req)")
    print(f"    MM PDU-type   [bit {pos+4}..{pos+7}] = 0x{hE_mmpdu:X} ({MM_PDU_TYPE_U.get(hE_mmpdu,'?')})")
    print(f"    LocUpd type   [bit {pos+8}..{pos+10}]= {hE_lut}  ({LOC_UPD_TYPE.get(hE_lut,'?')})")
    if hE_mmpdu == 4:  # U-LOCATION-UPDATE-DEMAND
        print(f"    ** MATCH: MS requests LocUpdType={hE_lut} ({LOC_UPD_TYPE.get(hE_lut,'?')}) **")
    print()

def read_board_log(last: int) -> list[tuple[int,int,int]]:
    import subprocess
    cmd = ["sshpass", "-p", "openwifi", "ssh",
           "-o", "StrictHostKeyChecking=no",
           "root@192.168.2.180",
           f"grep -Eo 'raw=[0-9A-Fa-f]+' /tmp/tetra_ul_mon.log | tail -{last}"]
    out = subprocess.check_output(cmd, text=True, timeout=15)
    result = []
    for line in out.splitlines():
        line = line.strip().removeprefix("raw=")
        if len(line) == 23:
            r2 = int(line[0:7], 16)
            r1 = int(line[7:15], 16)
            r0 = int(line[15:23], 16)
            result.append((r2, r1, r0))
    return result

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hex", nargs="*", help="raw hex (23-char or three words)")
    ap.add_argument("--board", action="store_true",
                    help="ssh to board and read last N raw lines from /tmp/tetra_ul_mon.log")
    ap.add_argument("--last", type=int, default=3,
                    help="with --board: how many recent raw lines to decode (default 3)")
    args = ap.parse_args()
    if args.board:
        for i, (r2,r1,r0) in enumerate(read_board_log(args.last)):
            print(f"=== Board raw #{i+1} ===")
            parse(r2, r1, r0)
    elif args.hex:
        r2, r1, r0 = parse_hex_args(args.hex)
        parse(r2, r1, r0)
    else:
        ap.print_help()
        sys.exit(1)

if __name__ == "__main__":
    main()
