#!/usr/bin/env python3
"""reassemble_ul_demand.py — UL fragment reassembly.

Reads UL #0 (MAC-ACCESS) + UL #1 (MAC-END-HU) info_92b, strips MAC headers,
concatenates LLC payloads, and decodes the full U-LOCATION-UPDATE-DEMAND
including all Type3 elements (GroupIdentityLocationDemand → GroupIdentityUplink
→ GSSI).

Per ETSI EN 300 392-2 §21.4.2.1 / §21.4.2.2 + BlueStation umac specs.
"""
import argparse
import sys
sys.path.insert(0, 'scripts')
from decode_pdu import (
    BitCursor, hex_to_bits, decode_mac_access, decode_llc, decode_mle,
    LOCATION_UPDATE_TYPE_NAMES, ENERGY_SAVING_MODE_NAMES,
)


def strip_mac_access_header(bits92):
    """Strip MAC-ACCESS header (1+1+1+2+24+1+...) from a 92-bit info string.
    Returns the rest of the bits (= LLC payload start)."""
    cur = BitCursor(bits92)
    mac = decode_mac_access(cur)
    if mac.get('mac_pdu_type') != 0:
        return None, mac
    return bits92[cur.pos:], mac


def strip_mac_end_hu_header(bits92):
    """Strip MAC-END-HU header (1+1+1+4 = 7 bits)."""
    cur = BitCursor(bits92)
    pdu_type = cur.read(1)
    if pdu_type != 1:
        return None, None
    fill_bits = cur.read(1)
    li_or_cap = cur.read(1)
    if li_or_cap == 0:
        length_ind = cur.read(4)
        out = {'pdu_type': pdu_type, 'fill_bits': fill_bits,
               'length_ind_or_cap_req': li_or_cap, 'length_ind': length_ind}
    else:
        res_req = cur.read(4)
        out = {'pdu_type': pdu_type, 'fill_bits': fill_bits,
               'length_ind_or_cap_req': li_or_cap, 'reservation_req': res_req}
    return bits92[cur.pos:], out


def reassemble_and_decode(ul0_info_92b, ul1_info_92b, label=''):
    """Take two consecutive UL bursts (MAC-ACCESS + MAC-END-HU) and reassemble
    the underlying LLC PDU, then decode as U-LOCATION-UPDATE-DEMAND."""
    print(f'{"="*70}')
    print(f'=== {label} ===')
    print(f'{"="*70}')

    print(f'\nUL Burst #0 (MAC-ACCESS):')
    payload0, mac0 = strip_mac_access_header(ul0_info_92b)
    print(f'  MAC-ACCESS header: {len(ul0_info_92b) - len(payload0)} bits consumed')
    print(f'  payload (LLC start): {len(payload0)} bits')
    print(f'  MAC params: pdu_type={mac0.get("mac_pdu_type")} ssi={mac0.get("ssi")} '
          f'opt={mac0.get("optional_field_flag")} cap_req={mac0.get("length_ind_or_cap_req")} '
          f'frag={mac0.get("frag_flag")} res_req={mac0.get("reservation_req")}')

    print(f'\nUL Burst #1 (MAC-END-HU):')
    payload1, mac1 = strip_mac_end_hu_header(ul1_info_92b)
    print(f'  MAC-END-HU header: {len(ul1_info_92b) - len(payload1)} bits consumed')
    print(f'  payload (LLC continuation): {len(payload1)} bits')
    print(f'  MAC-END-HU params: {mac1}')

    # Per ETSI §21.4.2: MAC-END-HU length_ind specifies LLC continuation length
    # in octets. UL #1 carries exactly length_ind*8 bits of LLC; rest is fill.
    # UL #0 (MAC-ACCESS with frag_flag=1, no length_ind) carries to slot end;
    # if mac0.fill_bits=0, all 56 bits are content.
    if mac1.get('length_ind') is not None:
        cont_bits = mac1['length_ind'] * 8
        payload1_trimmed = payload1[:cont_bits]
        print(f'  → trim UL #1 payload to length_ind*8 = {cont_bits} bits (was {len(payload1)})')
    else:
        payload1_trimmed = payload1

    # UL #0: if fill_bits, remove trailing fill (1 then 0s)
    payload0_trimmed = payload0
    if mac0.get('fill_bits') == 1:
        p = payload0_trimmed
        while p.endswith('0'):
            p = p[:-1]
        if p.endswith('1'):
            p = p[:-1]
        payload0_trimmed = p
        print(f'  → UL #0 fill_bits=1, stripped to {len(payload0_trimmed)} bits')

    combined = payload0_trimmed + payload1_trimmed
    print(f'\nCombined LLC payload: {len(combined)} bits (UL#0 {len(payload0_trimmed)} + UL#1 {len(payload1_trimmed)})')

    # Decode LLC + MLE + MM
    print()
    cur = BitCursor(combined)
    llc = decode_llc(cur)
    print(f'LLC (after MAC combine, bit 0..{cur.pos-1}):')
    for k, v in llc.items():
        print(f'  {k}: {v}')
    mle = decode_mle(cur)
    print(f'\nMLE (bit ..{cur.pos-1}):')
    for k, v in mle.items():
        print(f'  {k}: {v}')

    if mle.get('discriminator') != 1:
        print(f'  (not MM, stopping)')
        return

    print(f'\nMM PDU body (bit {cur.pos}..):')
    pdu_type = cur.read(4)
    print(f'  pdu_type: {pdu_type} (= {("UAuthentication","UItsiDetach","ULocationUpdateDemand")[pdu_type] if pdu_type < 3 else "?"})')
    if pdu_type != 2:
        print(f'  Not U-LOC-UPD-DEMAND')
        return

    # Now the full U-LOC-UPD-DEMAND body
    location_update_type = cur.read(3)
    print(f'  location_update_type: {location_update_type} ({LOCATION_UPDATE_TYPE_NAMES.get(location_update_type, "?")})')
    print(f'  request_to_append_la: {cur.read(1)}')
    cipher_control = cur.read(1)
    print(f'  cipher_control: {cipher_control}')
    if cipher_control == 1:
        print(f'  ciphering_parameters: {cur.read(10)}')
    obit = cur.read(1)
    print(f'  obit: {obit}')
    if obit == 0:
        print('  (no optional fields)')
        return

    # Type2 class_of_ms
    p = cur.read(1)
    print(f'  class_of_ms_pbit: {p}')
    if p == 1:
        cls_raw = cur.read(24)
        print(f'    class_of_ms (raw 24-bit): 0x{cls_raw:06X} = {cls_raw:024b}')

    # Type2 energy_saving_mode (3 bits)
    p = cur.read(1)
    print(f'  energy_saving_mode_pbit: {p}')
    if p == 1:
        esm = cur.read(3)
        print(f'    energy_saving_mode: {esm} ({ENERGY_SAVING_MODE_NAMES.get(esm, "?")})')

    # Type2 la_information (15 bits)
    p = cur.read(1)
    print(f'  la_information_pbit: {p}')
    if p == 1:
        la = cur.read(15)
        print(f'    la_information (15 bit raw): {la:015b}')

    # Type2 ssi (24)
    p = cur.read(1)
    print(f'  ssi_pbit: {p}')
    if p == 1:
        print(f'    ssi: {cur.read(24)}')

    # Type2 address_extension (24)
    p = cur.read(1)
    print(f'  address_extension_pbit: {p}')
    if p == 1:
        print(f'    address_extension: {cur.read(24)}')

    # Type3 elements (mbit + id + len + data)
    # group_identity_location_demand id=? (need to find from MmType34ElemIdUl)
    # GroupReportResponse=4, AuthenticationUplink=10, ExtendedCapabilities=2, Proprietary=15
    # GroupIdentityLocationDemand is named differently — let's find by m-bit + id=5 or similar
    print(f'\nType3 elements after Type2 fields (bit {cur.pos}, remaining {cur.remaining()}):')
    while cur.remaining() >= 16:
        mbit = cur.peek(1)
        if mbit is None or mbit == 0:
            break
        cur.read(1)  # consume mbit
        eid = cur.read(4)
        elen = cur.read(11)
        print(f'  Type3 element: id={eid} len={elen} bits')
        data = cur.read_bin(min(elen, cur.remaining()))
        print(f'    data ({len(data)} bits): {data}')
        # If this is GroupIdentityLocationDemand (id likely 5 or similar),
        # try to parse its inner structure (GroupIdentityUplink list)
        if eid in (5, 2, 3):
            parse_group_identity_location_demand(data)

    if cur.remaining() > 0:
        rem = cur.read_bin(cur.remaining())
        print(f'\nTrailing bits ({len(rem)}): {rem}')


def parse_group_identity_location_demand(data_bits):
    """Decode GroupIdentityLocationDemand inner content.
    Per BlueStation MM fields/group_identity_location_demand.rs (Clause 16.10.18):
      1 bit: group_identity_attach_detach_mode
      1 bit: obit
      Type4: GroupIdentityUplink list (id + 11-bit len + 6-bit count + entries)
        Each GroupIdentityUplink:
          1 bit: attach_detach_type
          5 bits: if attach: GroupIdentityAttachment (lifetime 2 + class_of_usage 3)
          2 bits: addr_type
          24 bits: gssi (if addr_type ∈ {0,1,3})
          24 bits: address_extension (if addr_type ∈ {1,3})
          24 bits: vgssi (if addr_type ∈ {2,3})
    """
    print(f'    >>> Inner GroupIdentityLocationDemand parse:')
    cur = BitCursor(data_bits)
    mode = cur.read(1)
    print(f'      group_identity_attach_detach_mode: {mode} (0=keep existing + attach new, 1=detach all + attach new)')
    reserved = cur.read(1)
    print(f'      reserved: {reserved}')
    obit = cur.read(1)
    print(f'      obit: {obit}')
    if obit == 0:
        return
    # Type4 GroupIdentityUplink
    mbit = cur.peek(1)
    if mbit == 1:
        cur.read(1)
        eid = cur.read(4)
        elen = cur.read(11)
        count = cur.read(6)
        print(f'      Type4 GroupIdentityUplink list: id={eid} len={elen} count={count}')
        for k in range(count):
            print(f'        --- GroupIdentityUplink #{k} ---')
            attach_type = cur.read(1)
            print(f'          attach_detach_type: {attach_type} (0=attach, 1=detach)')
            if attach_type == 0:
                # Attach: just 3-bit class_of_usage (NO lifetime field on UL side)
                cou = cur.read(3)
                print(f'          class_of_usage: {cou}')
            else:
                det = cur.read(2)
                print(f'          detachment_uplink: {det}')
            addr_type = cur.read(2)
            print(f'          addr_type: {addr_type} (0=GSSI, 1=GSSI+Ext, 2=VGSSI)')
            if addr_type in (0, 1):
                gssi = cur.read(24)
                print(f'          GSSI: {gssi} = 0x{gssi:06X}')
            if addr_type == 1:
                print(f'          address_extension: 0x{cur.read(24):06X}')
            if addr_type == 2:
                print(f'          VGSSI: 0x{cur.read(24):06X}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--ref', action='store_true', help='Use reference UL #0 + #1')
    ap.add_argument('--loc', action='store_true', help='Use local cell UL #0 + #1')
    ap.add_argument('--ul0', help='UL #0 info_92b bits or hex')
    ap.add_argument('--ul1', help='UL #1 info_92b bits or hex')
    args = ap.parse_args()

    ref_ul0 = '00000001010000010111111110100111000000010001001001100110001101000010000011000001001000100110'
    ref_ul1 = '11010100000111000011110000000010010000000101000000101111010011010110001100100000000000000000'
    loc_ul0 = '00000001010000010111110010001111000000010001001001100110001101000010000011000001001000100110'
    loc_ul1 = '11010100000111000011110000000010010000000101000000000000000000000000000100100000000000000000'

    if args.ref:
        reassemble_and_decode(ref_ul0, ref_ul1, label='Reference UL #0 + #1')
    elif args.loc:
        reassemble_and_decode(loc_ul0, loc_ul1, label='Local UL #0 + #1')
    elif args.ul0 and args.ul1:
        reassemble_and_decode(args.ul0, args.ul1, label='Custom')
    else:
        reassemble_and_decode(ref_ul0, ref_ul1, label='Reference UL #0 + #1')
        print()
        reassemble_and_decode(loc_ul0, loc_ul1, label='Local UL #0 + #1')
