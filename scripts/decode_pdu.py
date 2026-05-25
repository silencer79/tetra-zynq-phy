#!/usr/bin/env python3
"""decode_pdu.py — bit-exakte Dekodierung beliebiger DL-Signaling-PDUs
                    aus dem info_hex eines NDB1 SCH/F-Bursts.

Folgt der `tetra-bluestation/crates/tetra-pdus/` Spec (ETSI EN 300 392-2).

Aktuell supported:
  CMCE: D-CONNECT (Clause 14.7.1.4)
  MM  : D-LOCATION-UPDATE-ACCEPT (Clause 16.9.2.7)
"""
import argparse


# =============================================================================
# Enums
# =============================================================================
ADDR_NAMES = {0: 'NULL', 1: 'SSI', 2: 'EventLabel', 3: 'USSI',
              4: 'SMI', 5: 'SSI+Event', 6: 'SSI+Usage', 7: 'SMI+Event'}
LLC_NAMES = {0: 'BL-ADATA', 1: 'BL-DATA', 2: 'BL-UDATA', 3: 'BL-ACK',
             4: 'BL-ADATA+FCS', 5: 'BL-DATA+FCS', 6: 'BL-UDATA+FCS',
             7: 'BL-ACK+FCS', 14: 'L2SigPdu'}
MLE_DISC_NAMES = {0: 'Reserved', 1: 'MM', 2: 'CMCE', 3: 'Reserved',
                  4: 'SNDCP', 5: 'MLE', 6: 'TETRA-Mgmt', 7: 'Testing'}
CMCE_PDU_TYPE_NAMES = {
    0: 'DAlert', 1: 'DCallProceeding', 2: 'DConnect', 3: 'DConnectAcknowledge',
    4: 'DDisconnect', 5: 'DInfo', 6: 'DRelease', 7: 'DSetup', 8: 'DStatus',
    9: 'DTxCeased', 10: 'DTxContinue', 11: 'DTxGranted', 12: 'DTxWait',
    13: 'DTxInterrupt', 14: 'DCallRestore', 15: 'DSdsData', 16: 'DFacility',
    31: 'CmceFunctionNotSupported',
}
MM_PDU_TYPE_NAMES = {
    0: 'DOtar', 1: 'DAuthentication', 2: 'DCkChangeDemand', 3: 'DDisable',
    4: 'DEnable', 5: 'DLocationUpdateAccept', 6: 'DLocationUpdateCommand',
    7: 'DLocationUpdateReject', 9: 'DLocationUpdateProceeding',
    10: 'DAttachDetachGroupIdentity', 11: 'DAttachDetachGroupIdentityAck',
    12: 'DMmStatus', 15: 'MmPduFunctionNotSupported',
}
CALL_TIMEOUT_NAMES = {
    0: 'Infinite', 1: '30s', 2: '45s', 3: '60s', 4: '2m', 5: '3m',
    6: '4m', 7: '5m', 8: '6m', 9: '8m', 10: '10m', 11: '12m',
    12: '15m', 13: '20m', 14: '30m', 15: 'Reserved',
}
TRANSMISSION_GRANT_NAMES = {
    0: 'Granted', 1: 'NotGranted', 2: 'RequestQueued', 3: 'GrantedToOtherUser',
}
CIRCUIT_MODE_NAMES = {
    0: 'TchS (Speech 7.2)', 1: 'TchS-half', 2: 'TchS-quarter',
    3: 'Tch7.2', 4: 'Tch4.8N=1', 5: 'Tch4.8N=4', 6: 'Tch4.8N=8',
    7: 'Tch2.4N=1',
}
COMM_TYPE_NAMES = {
    0: 'point-to-point', 1: 'point-to-multipoint',
    2: 'point-to-multipoint acknowledged', 3: 'broadcast',
}
CMCE_TYPE3_ELEM_NAMES = {
    1: 'Dtmf', 2: 'ExtSubscriberNum', 3: 'Facility',
    4: 'PollResponseAddr', 5: 'TempAddr', 6: 'DmMsAddr', 15: 'Proprietary',
}
LOCATION_UPDATE_TYPE_NAMES = {
    0: 'RoamingLocationUpdating', 1: 'MigratingLocationUpdating',
    2: 'PeriodicLocationUpdating', 3: 'ItsiAttach',
    4: 'ServiceRestorationRoaming', 5: 'ServiceRestorationMigrating',
    6: 'DemandLocationUpdating', 7: 'DisabledMsUpdating',
}
ENERGY_SAVING_MODE_NAMES = {
    0: 'StayAlive', 1: 'Eg1', 2: 'Eg2', 3: 'Eg3',
    4: 'Eg4', 5: 'Eg5', 6: 'Eg6', 7: 'Eg7',
}
MM_TYPE34_ELEM_NAMES_DL = {
    1: 'DefaultGroupAttachLifetime', 2: 'NewRegisteredArea',
    3: 'SecurityDownlink', 4: 'GroupReportResponse',
    5: 'GroupIdentityLocationAccept', 6: 'DmMsAddress',
    7: 'GroupIdentityDownlink', 10: 'AuthenticationDownlink',
    12: 'GroupIdentitySecurityRelatedInformation',
    13: 'CellTypeControl', 15: 'Proprietary',
}


# =============================================================================
# BitCursor
# =============================================================================
class BitCursor:
    def __init__(self, bitstr):
        self.bits = bitstr
        self.pos = 0

    def read(self, n, name=None):
        if self.pos + n > len(self.bits):
            return None
        chunk = self.bits[self.pos : self.pos + n]
        v = int(chunk, 2) if chunk else 0
        self.pos += n
        return v

    def read_bin(self, n):
        chunk = self.bits[self.pos : self.pos + n]
        self.pos += n
        return chunk

    def peek(self, n):
        if self.pos + n > len(self.bits):
            return None
        return int(self.bits[self.pos : self.pos + n], 2)

    def remaining(self):
        return len(self.bits) - self.pos


def hex_to_bits(hex_str, nbits=None):
    hex_str = hex_str.lower()
    if hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    n_hex = len(hex_str)
    val = int(hex_str, 16) if hex_str else 0
    total_bits = n_hex * 4
    bits = bin(val)[2:].rjust(total_bits, '0')
    if nbits is not None:
        bits = bits.ljust(nbits, '0')[:nbits]
    return bits


# =============================================================================
# Generic Type2/Type3/Type4 helpers (Clause 14.8.x for CMCE / 16.10.x for MM)
# =============================================================================
def read_pbit_and_value(cur, obit, nbits, label):
    """Type2 generic: 1 p-bit + nbits if p=1."""
    if not obit:
        return None, None
    p = cur.read(1)
    if p == 1:
        v = cur.read(nbits)
        return p, v
    return p, None


def read_type3_if_matches(cur, obit, expected_id, id_bits=4):
    """Peek m-bit + id; if match, consume and read len + data."""
    if not obit:
        return None
    mbit = cur.peek(1)
    if mbit != 1:
        return None
    id_val = cur.peek(1 + id_bits)
    if id_val is None:
        return None
    # extract id from second-onwards bits
    actual_id = id_val & ((1 << id_bits) - 1)
    if actual_id != expected_id:
        return None
    # Consume
    cur.read(1)             # mbit
    fid = cur.read(id_bits)
    flen = cur.read(11)
    data_bits = cur.read_bin(min(flen, 256))
    return {'id': fid, 'len': flen, 'data_bin': data_bits}


def read_type4_if_matches(cur, obit, expected_id, id_bits=4):
    """Type4: m-bit + id + 11-bit total-len + 6-bit num-elems + data."""
    if not obit:
        return None
    mbit = cur.peek(1)
    if mbit != 1:
        return None
    id_val = cur.peek(1 + id_bits)
    if id_val is None:
        return None
    actual_id = id_val & ((1 << id_bits) - 1)
    if actual_id != expected_id:
        return None
    cur.read(1)             # mbit
    fid = cur.read(id_bits)
    flen = cur.read(11)
    elems = cur.read(6)
    data_bits = cur.read_bin(min(flen - 6, 256))
    return {'id': fid, 'len': flen, 'num_elems': elems, 'data_bin': data_bits}


# =============================================================================
# MAC layer
# =============================================================================
def decode_mac_resource(cur):
    out = {}
    out['pdu_type'] = cur.read(2)
    if out['pdu_type'] != 0:
        out['_ERROR'] = f'Not MAC-RESOURCE (got pdu_type={out["pdu_type"]})'
        return out
    out['fill_bit'] = cur.read(1)
    out['position_of_grant'] = cur.read(1)
    out['encryption_mode'] = cur.read(2)
    out['random_access_flag'] = cur.read(1)
    out['length_indicator'] = cur.read(6)
    addr_type = cur.read(3)
    out['address_type'] = addr_type
    out['address_type_name'] = ADDR_NAMES.get(addr_type, '?')

    if addr_type in (1, 3):
        out['ssi'] = cur.read(24)
    elif addr_type == 2:
        out['event_label'] = cur.read(10)
    elif addr_type == 4:
        out['smi'] = cur.read(48)
    elif addr_type == 5:
        out['ssi'] = cur.read(24)
        out['event_label'] = cur.read(10)
    elif addr_type == 6:
        out['ssi'] = cur.read(24)
        out['usage_marker'] = cur.read(6)
    elif addr_type == 7:
        out['smi'] = cur.read(48)
        out['event_label'] = cur.read(10)

    if addr_type != 0:
        out['power_control_flag'] = cur.read(1)
        if out['power_control_flag'] == 1:
            out['power_control_element'] = cur.read(4)
        out['slot_granting_flag'] = cur.read(1)
        if out['slot_granting_flag'] == 1:
            out['slot_granting'] = cur.read(8)
        out['channel_allocation_flag'] = cur.read(1)
        if out['channel_allocation_flag'] == 1:
            out['channel_allocation'] = decode_channel_allocation(cur)
    return out


def decode_channel_allocation(cur):
    ca = {}
    ca['allocation_type'] = cur.read(2)
    ca['timeslot_assigned'] = cur.read(4)
    ca['uplink_downlink_assigned'] = cur.read(2)
    ca['clch_permission'] = cur.read(1)
    ca['cell_change_flag'] = cur.read(1)
    ca['carrier_number'] = cur.read(12)
    ext = cur.read(1)
    ca['extended_carrier_flag'] = ext
    if ext == 1:
        ca['frequency_band'] = cur.read(4)
        ca['offset'] = cur.read(2)
        ca['duplex_spacing'] = cur.read(3)
        ca['reverse_operation'] = cur.read(1)
    ca['monitoring_pattern'] = cur.read(2)
    if ca['monitoring_pattern'] == 0:
        ca['frame18_monitoring_pattern'] = cur.read(2)
    return ca


def decode_llc(cur):
    out = {}
    t = cur.read(4)
    out['llc_type'] = t
    out['llc_type_name'] = LLC_NAMES.get(t, f'?({t})')
    if t in (0, 4):    # BL-ADATA(+FCS)
        out['nr'] = cur.read(1)
        out['ns'] = cur.read(1)
    elif t in (1, 5):  # BL-DATA(+FCS)
        out['ns'] = cur.read(1)
    elif t in (3, 7):  # BL-ACK(+FCS)
        out['nr'] = cur.read(1)
    # BL-UDATA(+FCS): no extra; L2SigPdu(14): no extra
    return out


def decode_mle(cur):
    out = {}
    out['discriminator'] = cur.read(3)
    out['discriminator_name'] = MLE_DISC_NAMES.get(out['discriminator'], '?')
    return out


# =============================================================================
# CMCE D-CONNECT body
# =============================================================================
def decode_d_connect_body(cur):
    out = {'_start': cur.pos}
    out['pdu_type'] = cur.read(5)
    out['pdu_type_name'] = CMCE_PDU_TYPE_NAMES.get(out['pdu_type'], '?')
    if out['pdu_type'] != 2:
        out['_ERROR'] = f'Not D-CONNECT (pdu_type={out["pdu_type"]})'
        return out
    out['call_identifier'] = cur.read(14)
    out['call_time_out'] = cur.read(4)
    out['call_time_out_name'] = CALL_TIMEOUT_NAMES.get(out['call_time_out'], '?')
    out['hook_method_selection'] = cur.read(1)
    out['simplex_duplex_selection'] = cur.read(1)
    out['transmission_grant'] = cur.read(2)
    out['transmission_grant_name'] = TRANSMISSION_GRANT_NAMES.get(out['transmission_grant'], '?')
    out['transmission_request_permission'] = cur.read(1)
    out['call_ownership'] = cur.read(1)
    obit = cur.read(1)
    out['obit'] = obit
    if obit == 0:
        out['_no_optional_fields'] = True
        return out

    # Type2 call_priority
    p, v = read_pbit_and_value(cur, True, 4, 'call_priority')
    out['call_priority_pbit'] = p
    if v is not None:
        out['call_priority'] = v

    # Type2 basic_service_information
    p = cur.read(1)
    out['basic_service_information_pbit'] = p
    if p == 1:
        bsi = {}
        cmt = cur.read(3)
        bsi['circuit_mode_type'] = cmt
        bsi['circuit_mode_type_name'] = CIRCUIT_MODE_NAMES.get(cmt, f'?({cmt})')
        bsi['encryption_flag'] = cur.read(1)
        ct = cur.read(2)
        bsi['communication_type'] = ct
        bsi['communication_type_name'] = COMM_TYPE_NAMES.get(ct, '?')
        if cmt == 0:
            bsi['speech_service'] = cur.read(2)
        else:
            bsi['slots_per_frame'] = cur.read(2)
        out['basic_service_information'] = bsi

    # Type2 temporary_address
    p, v = read_pbit_and_value(cur, True, 24, 'temporary_address')
    out['temporary_address_pbit'] = p
    if v is not None:
        out['temporary_address'] = v

    # Type2 notification_indicator
    p, v = read_pbit_and_value(cur, True, 6, 'notification_indicator')
    out['notification_indicator_pbit'] = p
    if v is not None:
        out['notification_indicator'] = v

    # Type3 facility (id=3)
    f = read_type3_if_matches(cur, True, 3)
    if f:
        out['facility'] = f
    # Type3 proprietary (id=15)
    f = read_type3_if_matches(cur, True, 15)
    if f:
        out['proprietary'] = f

    if cur.peek(1) is not None:
        out['trailing_mbit'] = cur.read(1)
    return out


# =============================================================================
# MM D-LOCATION-UPDATE-ACCEPT body
# =============================================================================
def decode_d_loc_upd_accept_body(cur):
    out = {'_start': cur.pos}
    out['pdu_type'] = cur.read(4)
    out['pdu_type_name'] = MM_PDU_TYPE_NAMES.get(out['pdu_type'], '?')
    if out['pdu_type'] != 5:
        out['_ERROR'] = f'Not D-LOC-UPD-ACCEPT (pdu_type={out["pdu_type"]})'
        return out

    out['location_update_accept_type'] = cur.read(3)
    out['location_update_accept_type_name'] = LOCATION_UPDATE_TYPE_NAMES.get(out['location_update_accept_type'], '?')

    obit = cur.read(1)
    out['obit'] = obit
    if obit == 0:
        out['_no_optional_fields'] = True
        return out

    # Type2 ssi (24)
    p, v = read_pbit_and_value(cur, True, 24, 'ssi')
    out['ssi_pbit'] = p
    if v is not None:
        out['ssi'] = v

    # Type2 address_extension (24)
    p, v = read_pbit_and_value(cur, True, 24, 'address_extension')
    out['address_extension_pbit'] = p
    if v is not None:
        out['address_extension'] = v

    # Type2 subscriber_class (16)
    p, v = read_pbit_and_value(cur, True, 16, 'subscriber_class')
    out['subscriber_class_pbit'] = p
    if v is not None:
        out['subscriber_class'] = v

    # Type2 energy_saving_information (struct)
    p = cur.read(1)
    out['energy_saving_information_pbit'] = p
    if p == 1:
        esi = {}
        esi['energy_saving_mode'] = cur.read(3)
        esi['energy_saving_mode_name'] = ENERGY_SAVING_MODE_NAMES.get(esi['energy_saving_mode'], '?')
        esi['frame_number'] = cur.read(5)
        esi['multiframe_number'] = cur.read(6)
        out['energy_saving_information'] = esi

    # Type2 scch_info_18thframe (6)
    p, v = read_pbit_and_value(cur, True, 6, 'scch_information_and_distribution_on_18th_frame')
    out['scch_info_pbit'] = p
    if v is not None:
        out['scch_information_and_distribution_on_18th_frame'] = v

    # Type4 new_registered_area (id=2)
    f = read_type4_if_matches(cur, True, 2)
    if f:
        out['new_registered_area'] = f

    # Type3 security_downlink (id=3)
    f = read_type3_if_matches(cur, True, 3)
    if f:
        out['security_downlink'] = f

    # Type3 group_identity_location_accept (id=5) — has its own structure
    if cur.peek(1) == 1:
        peek_id_val = cur.peek(5)
        if peek_id_val is not None and (peek_id_val & 0xF) == 5:
            cur.read(1)         # mbit
            fid = cur.read(4)
            flen = cur.read(11)
            start_pos = cur.pos
            gila = {}
            gila['group_identity_accept_reject'] = cur.read(1)
            gila['reserved'] = cur.read(1)
            gila['obit'] = cur.read(1)
            # type4 group_identity_downlink (id=7)
            if gila['obit'] == 1 and cur.peek(1) == 1:
                peek_id_val = cur.peek(5)
                if peek_id_val is not None and (peek_id_val & 0xF) == 7:
                    cur.read(1)
                    gid_fid = cur.read(4)
                    gid_flen = cur.read(11)
                    gid_elems = cur.read(6)
                    data = cur.read_bin(min(gid_flen - 6, 256))
                    gila['group_identity_downlink'] = {
                        'id': gid_fid, 'len': gid_flen, 'num_elems': gid_elems,
                        'data_bin': data,
                    }
                gila['trailing_mbit'] = cur.read(1)
            out['group_identity_location_accept'] = {
                'id': fid, 'len': flen, 'parsed': gila,
            }

    # Type3 default_group_attachment_lifetime (id=1)
    f = read_type3_if_matches(cur, True, 1)
    if f:
        out['default_group_attachment_lifetime'] = f

    # Type3 authentication_downlink (id=10)
    f = read_type3_if_matches(cur, True, 10)
    if f:
        out['authentication_downlink'] = f

    # Type4 group_identity_security_related_information (id=12)
    f = read_type4_if_matches(cur, True, 12)
    if f:
        out['group_identity_security_related_information'] = f

    # Type3 cell_type_control (id=13)
    f = read_type3_if_matches(cur, True, 13)
    if f:
        out['cell_type_control'] = f

    # Type3 proprietary (id=15)
    f = read_type3_if_matches(cur, True, 15)
    if f:
        out['proprietary'] = f

    if cur.peek(1) is not None:
        out['trailing_mbit'] = cur.read(1)
    return out


# =============================================================================
# Top-level orchestration
# =============================================================================
RESERVATION_REQ_NAMES = {
    0: 'NoFurtherRequirement', 1: '1ReservedSlot', 2: '2ReservedSlots',
    3: '3ReservedSlots', 4: '4ReservedSlots', 5: '5ReservedSlots',
    6: '6ReservedSlots', 7: '7ReservedSlots',
    # 8..15 reserved
}


# =============================================================================
# UL MAC-ACCESS (Clause 21.4.2.1, BlueStation umac/mac_access.rs)
# =============================================================================
def decode_mac_access(cur):
    out = {}
    out['mac_pdu_type'] = cur.read(1)  # 0 = MAC-ACCESS, 1 = MAC-END-HU
    if out['mac_pdu_type'] != 0:
        out['_note'] = 'mac_pdu_type=1 → MAC-END-HU (different layout)'
        return out
    out['fill_bits'] = cur.read(1)
    out['encrypted'] = cur.read(1)
    addr_type = cur.read(2)
    out['addr_type'] = addr_type
    UL_ADDR_NAMES = {0: 'Ssi(ISSI)', 1: 'EventLabel', 2: 'Ussi', 3: 'Smi'}
    out['addr_type_name'] = UL_ADDR_NAMES.get(addr_type, '?')
    if addr_type == 0:
        out['ssi'] = cur.read(24)
    elif addr_type == 1:
        out['event_label'] = cur.read(10)
    elif addr_type == 2:
        out['ussi'] = cur.read(24)
    elif addr_type == 3:
        out['smi'] = cur.read(24)
    out['optional_field_flag'] = cur.read(1)
    if out['optional_field_flag'] == 1:
        out['length_ind_or_cap_req'] = cur.read(1)
        if out['length_ind_or_cap_req'] == 0:
            out['length_ind'] = cur.read(5)
        else:
            out['frag_flag'] = cur.read(1)
            out['reservation_req'] = cur.read(4)
            out['reservation_req_name'] = RESERVATION_REQ_NAMES.get(out['reservation_req'], '?')
    return out


# =============================================================================
# UL MM PDU bodies
# =============================================================================
def decode_u_itsi_detach_body(cur):
    out = {'_start': cur.pos}
    out['pdu_type'] = cur.read(4)
    UL_MM_NAMES = {
        0: 'UAuthentication', 1: 'UItsiDetach', 2: 'ULocationUpdateDemand',
        3: 'UMmStatus', 4: 'UCkChangeResult', 5: 'UOtar', 6: 'UInformationProvide',
        7: 'UAttachDetachGroupIdentity', 8: 'UAttachDetachGroupIdentityAck',
        9: 'UTeiProvide', 11: 'UDisableStatus', 15: 'MmPduFunctionNotSupported',
    }
    out['pdu_type_name'] = UL_MM_NAMES.get(out['pdu_type'], '?')
    if out['pdu_type'] != 1:
        out['_ERROR'] = f'Not U-ITSI-DETACH (pdu_type={out["pdu_type"]})'
        return out
    out['obit'] = cur.read(1)
    if out['obit'] == 0:
        return out
    p, v = read_pbit_and_value(cur, True, 24, 'address_extension')
    out['address_extension_pbit'] = p
    if v is not None:
        out['address_extension'] = v
    f = read_type3_if_matches(cur, True, 15)  # proprietary id=15
    if f:
        out['proprietary'] = f
    if cur.peek(1) is not None:
        out['trailing_mbit'] = cur.read(1)
    return out


def decode_u_loc_upd_demand_body(cur):
    out = {'_start': cur.pos}
    out['pdu_type'] = cur.read(4)
    UL_MM_NAMES = {
        0: 'UAuthentication', 1: 'UItsiDetach', 2: 'ULocationUpdateDemand',
        3: 'UMmStatus', 4: 'UCkChangeResult', 5: 'UOtar', 6: 'UInformationProvide',
        7: 'UAttachDetachGroupIdentity', 8: 'UAttachDetachGroupIdentityAck',
        9: 'UTeiProvide', 11: 'UDisableStatus', 15: 'MmPduFunctionNotSupported',
    }
    out['pdu_type_name'] = UL_MM_NAMES.get(out['pdu_type'], '?')
    if out['pdu_type'] != 2:
        out['_ERROR'] = f'Not U-LOC-UPD-DEMAND (pdu_type={out["pdu_type"]})'
        return out
    out['location_update_type'] = cur.read(3)
    out['location_update_type_name'] = LOCATION_UPDATE_TYPE_NAMES.get(out['location_update_type'], '?')
    out['request_to_append_la'] = cur.read(1)
    out['cipher_control'] = cur.read(1)
    if out['cipher_control'] == 1:
        out['ciphering_parameters'] = cur.read(10)
    out['obit'] = cur.read(1)
    if out['obit'] == 0:
        return out

    # Type2 class_of_ms (struct) — peek pbit
    p = cur.read(1)
    out['class_of_ms_pbit'] = p
    if p == 1:
        # ClassOfMs struct: depends on length, basic decoded as raw 24 bits per spec
        # Actual struct: complex; just dump raw 24 for now
        out['class_of_ms_raw_24b'] = cur.read_bin(24)

    p, v = read_pbit_and_value(cur, True, 3, 'energy_saving_mode')
    out['energy_saving_mode_pbit'] = p
    if v is not None:
        out['energy_saving_mode'] = v
        out['energy_saving_mode_name'] = ENERGY_SAVING_MODE_NAMES.get(v, '?')

    p, v = read_pbit_and_value(cur, True, 15, 'la_information')
    out['la_information_pbit'] = p
    if v is not None:
        out['la_information_raw_15b'] = v

    p, v = read_pbit_and_value(cur, True, 24, 'ssi')
    out['ssi_pbit'] = p
    if v is not None:
        out['ssi'] = v

    p, v = read_pbit_and_value(cur, True, 24, 'address_extension')
    out['address_extension_pbit'] = p
    if v is not None:
        out['address_extension'] = v

    # Type3 group_identity_location_demand id=? per MmType34ElemIdUl
    # For UL, GroupIdentityLocationDemand id varies — try common id=5 (group_identity_location_accept-style is DL; for UL it might differ)
    # Skipping detailed type3 parsing — dump remaining bits
    if cur.remaining() > 0:
        out['_remaining_bits'] = cur.read_bin(cur.remaining())
    return out


UL_CMCE_PDU_NAMES = {
    0: 'UAlert', 2: 'UConnect', 4: 'UDisconnect', 5: 'UInfo',
    6: 'URelease', 7: 'USetup', 8: 'UStatus', 9: 'UTxCeased',
    10: 'UTxDemand', 14: 'UCallRestore', 15: 'USdsData',
    16: 'UFacility', 31: 'CmceFunctionNotSupported',
}
PARTY_TYPE_NAMES = {
    0: 'SNA', 1: 'SSI', 2: 'TSI (SSI+Ext)', 3: 'Reserved',
}


def decode_u_setup_body(cur):
    """U-SETUP — ETSI EN 300 392-2 §14.7.2.10, BlueStation u_setup.rs."""
    out = {'_start': cur.pos}
    out['pdu_type'] = cur.read(5)
    out['pdu_type_name'] = UL_CMCE_PDU_NAMES.get(out['pdu_type'], '?')
    if out['pdu_type'] != 7:
        out['_ERROR'] = f'Not U-SETUP (pdu_type={out["pdu_type"]})'
        return out

    out['area_selection'] = cur.read(4)
    out['hook_method_selection'] = cur.read(1)
    out['simplex_duplex_selection'] = cur.read(1)

    # BasicServiceInformation (8 bits)
    bsi = {}
    cmt = cur.read(3)
    bsi['circuit_mode_type'] = cmt
    bsi['circuit_mode_type_name'] = CIRCUIT_MODE_NAMES.get(cmt, f'?({cmt})')
    bsi['encryption_flag'] = cur.read(1)
    ct = cur.read(2)
    bsi['communication_type'] = ct
    bsi['communication_type_name'] = COMM_TYPE_NAMES.get(ct, '?')
    if cmt == 0:
        bsi['speech_service'] = cur.read(2)
    else:
        bsi['slots_per_frame'] = cur.read(2)
    out['basic_service_information'] = bsi

    out['request_to_transmit_send_data'] = cur.read(1)
    out['call_priority'] = cur.read(4)
    out['clir_control'] = cur.read(2)

    cpti = cur.read(2)
    out['called_party_type_identifier'] = cpti
    out['called_party_type_identifier_name'] = PARTY_TYPE_NAMES.get(cpti, '?')
    if cpti == 0:
        out['called_party_short_number_address'] = cur.read(8)
    elif cpti == 1:
        out['called_party_ssi'] = cur.read(24)
    elif cpti == 2:
        out['called_party_ssi'] = cur.read(24)
        out['called_party_extension'] = cur.read(24)

    obit = cur.read(1)
    out['obit'] = obit
    if obit == 0:
        return out

    # Type3 elements
    f = read_type3_if_matches(cur, True, 2)  # ExternalSubscriberNum
    if f:
        out['external_subscriber_number'] = f
    f = read_type3_if_matches(cur, True, 3)  # Facility
    if f:
        out['facility'] = f
    f = read_type3_if_matches(cur, True, 6)  # DmMsAddr
    if f:
        out['dm_ms_address'] = f
    f = read_type3_if_matches(cur, True, 15)  # Proprietary
    if f:
        out['proprietary'] = f

    if cur.peek(1) is not None:
        out['trailing_mbit'] = cur.read(1)
    return out


PDU_BODY_DECODERS = {
    ('CMCE', 'D-CONNECT'): decode_d_connect_body,
    ('MM', 'D-LOC-UPD-ACCEPT'): decode_d_loc_upd_accept_body,
    ('UL-MM', 'U-ITSI-DETACH'): decode_u_itsi_detach_body,
    ('UL-MM', 'U-LOC-UPD-DEMAND'): decode_u_loc_upd_demand_body,
    ('UL-CMCE', 'U-SETUP'): decode_u_setup_body,
}


def decode_burst(info_hex_or_bits, expected_pdu=('CMCE', 'D-CONNECT'), label=''):
    nbits_default = 92 if expected_pdu[0] == 'UL-MM' else 268
    if all(c in '01' for c in info_hex_or_bits):
        bits = info_hex_or_bits
    else:
        bits = hex_to_bits(info_hex_or_bits, nbits=nbits_default)

    cur = BitCursor(bits)
    title = f'=== {label} ===' if label else '=== PDU ==='
    print(title)
    print(f'info bits ({len(bits)}): {bits[:80]}…')
    print()

    is_ul = expected_pdu[0] == 'UL-MM' or expected_pdu[0] == 'UL-CMCE'
    if is_ul:
        mac = decode_mac_access(cur)
        print(f'MAC-ACCESS (bit 0..{cur.pos-1}):')
    else:
        mac = decode_mac_resource(cur)
        print(f'MAC-RESOURCE (bit 0..{cur.pos-1}):')
    for k, v in mac.items():
        if isinstance(v, dict):
            print(f'  {k}:')
            for kk, vv in v.items():
                print(f'    {kk}: {vv}')
        else:
            print(f'  {k}: {v}')

    llc = decode_llc(cur)
    print(f'\nLLC (bit ..{cur.pos-1})')
    for k, v in llc.items():
        print(f'  {k}: {v}')

    mle = decode_mle(cur)
    print(f'\nMLE (bit ..{cur.pos-1})')
    for k, v in mle.items():
        print(f'  {k}: {v}')

    body_decoder = PDU_BODY_DECODERS.get(expected_pdu)
    if body_decoder is None:
        print(f'\nNo decoder for {expected_pdu}, stopping')
        return {'mac': mac, 'llc': llc, 'mle': mle}
    body = body_decoder(cur)
    pdu_name = expected_pdu[1]
    print(f'\n{expected_pdu[0]} {pdu_name} body (bit {body.get("_start","?")}..):')
    for k, v in body.items():
        if isinstance(v, dict):
            print(f'  {k}:')
            for kk, vv in v.items():
                if isinstance(vv, dict):
                    print(f'    {kk}:')
                    for kkk, vvv in vv.items():
                        print(f'      {kkk}: {vvv}')
                else:
                    print(f'    {kk}: {vv}')
        else:
            print(f'  {k}: {v}')

    return {'mac': mac, 'llc': llc, 'mle': mle, 'body': body, 'final_pos': cur.pos}


def cmp_dict(name, ref_d, loc_d, indent=''):
    keys = list(ref_d.keys())
    for k in loc_d.keys():
        if k not in keys:
            keys.append(k)
    for k in keys:
        rv = ref_d.get(k, '<missing>')
        lv = loc_d.get(k, '<missing>')
        if isinstance(rv, dict) or isinstance(lv, dict):
            print(f'{indent}{name}.{k}:')
            if isinstance(rv, dict) and isinstance(lv, dict):
                cmp_dict(name, rv, lv, indent + '  ')
            else:
                print(f'{indent}  ref: {rv}')
                print(f'{indent}  loc: {lv}')
        else:
            if rv == lv:
                print(f'{indent}    {name}.{k}: {rv}')
            else:
                print(f'{indent}⚠️ {name}.{k}: ref={rv}  loc={lv}')


def diff_two(ref_hex, loc_hex, expected_pdu):
    ref = decode_burst(ref_hex, expected_pdu, label=f'Reference {expected_pdu[1]}')
    print('\n' + '=' * 70 + '\n')
    loc = decode_burst(loc_hex, expected_pdu, label=f'Local {expected_pdu[1]}')

    print('\n' + '=' * 70)
    print('=== Bit-für-Bit Vergleich ===\n')
    cmp_dict('MAC', ref['mac'], loc['mac'])
    print()
    cmp_dict('LLC', ref['llc'], loc['llc'])
    print()
    cmp_dict('MLE', ref['mle'], loc['mle'])
    print()
    cmp_dict(expected_pdu[1], ref['body'], loc['body'])


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--pdu', choices=['d-connect', 'd-loc-upd-accept',
                                       'u-itsi-detach', 'u-loc-upd-demand', 'u-setup'],
                    default='d-connect')
    ap.add_argument('--ref')
    ap.add_argument('--loc')
    ap.add_argument('--single', help='Decode only one info_hex (no diff)')
    args = ap.parse_args()

    if args.pdu == 'd-connect':
        ref = args.ref or '0x007e282ff42c89dd0ec9080080031021fe2f4d642c12380100026194a0bfd100000'
        loc = args.loc or '0x007e282f912c89cbf4c908001003108000000000000000000000000000000000000'
        expected = ('CMCE', 'D-CONNECT')
    elif args.pdu == 'd-loc-upd-accept':
        ref = args.ref or '0x20a9282ff440009571000150746e0981302f4d63200010800000000000000000000'
        loc = args.loc or '0x20a9282f9140001511000150746e098130000001200000000000000000000000000'
        expected = ('MM', 'D-LOC-UPD-ACCEPT')
    elif args.pdu == 'u-itsi-detach':
        # UL #0 from both captures — info_92b
        ref = args.ref or '00000001010000010111111110100111000000010001001001100110001101000010000011000001001000100110'
        loc = args.loc or '00000001010000010111110010001111000000010001001001100110001101000010000011000001001000100110'
        expected = ('UL-MM', 'U-ITSI-DETACH')
    elif args.pdu == 'u-loc-upd-demand':
        ref = args.ref or '00000001010000010111111110100111000000010001001001100110001101000010000011000001001000100110'
        loc = args.loc or '00000001010000010111110010001111000000010001001001100110001101000010000011000001001000100110'
        expected = ('UL-MM', 'U-LOC-UPD-DEMAND')
    elif args.pdu == 'u-setup':
        # Ref UL #22 (`41 41 7F A0 48 E0...`), Local UL #3 (`41 41 7C 88 68 E0...`)
        ref = args.ref or '01000001010000010111111110100000010010001110000000000010000000000100101111010011010110010001'
        loc = args.loc or '01000001010000010111110010001000011010001110000000000010000000000100000000000000000000000101'
        expected = ('UL-CMCE', 'U-SETUP')

    if args.single:
        decode_burst(args.single, expected, label='single')
    else:
        diff_two(ref, loc, expected)
