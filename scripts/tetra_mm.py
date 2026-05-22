"""
tetra_mm.py — MM (Mobility Management) PDU field-level parser (Phase 2)

Mirrors BlueStation `tetra-bluestation/crates/tetra-pdus/src/mm/` PDU layouts
per ETSI EN 300 392-2 § 16. Coverage:
  - Downlink: D-OTAR, D-AUTH, D-DISABLE, D-ENABLE, D-LOC-UPD-ACCEPT,
              D-LOC-UPD-COMMAND, D-LOC-UPD-REJECT, D-LOC-UPD-PROCEEDING,
              D-ATTACH-DETACH-GROUP-IDENTITY, D-MM-STATUS,
              D-ATTACH-DETACH-GROUP-IDENTITY-ACK
  - Uplink:   U-AUTH, U-ITSI-DETACH, U-LOC-UPD-DEMAND, U-MM-STATUS,
              U-OTAR, U-INFO-PROVIDE, U-ATTACH-DETACH-GROUP-IDENTITY,
              U-ATTACH-DETACH-GROUP-IDENTITY-ACK, U-TEI-PROVIDE, U-DISABLE-STATUS

Same bit-stream convention as `tetra_cmce`: list[int] of 0/1, MSB-first.
PDU type field (4 bits for MM) is part of the buffer the dispatcher consumes.
"""
from __future__ import annotations
from typing import Optional


# ---------------------------------------------------------------------------
# Enums (BlueStation `mm/enums/`)
# ---------------------------------------------------------------------------
MM_DL = {
    0: "D-OTAR", 1: "D-AUTHENTICATION", 2: "D-CK-CHG-DEMAND",
    3: "D-DISABLE", 4: "D-ENABLE",
    5: "D-LOC-UPD-ACCEPT", 6: "D-LOC-UPD-COMMAND",
    7: "D-LOC-UPD-REJECT", 9: "D-LOC-UPD-PROCEEDING",
    10: "D-ATTACH-DETACH-GROUP-IDENTITY",
    11: "D-ATTACH-DETACH-GROUP-IDENTITY-ACK",
    12: "D-MM-STATUS",
    15: "MM-FUNCTION-NOT-SUPPORTED",
}

MM_UL = {
    0: "U-AUTHENTICATION", 1: "U-ITSI-DETACH",
    2: "U-LOC-UPD-DEMAND", 3: "U-MM-STATUS",
    4: "U-CK-CHANGE-RESULT", 5: "U-OTAR",
    6: "U-INFORMATION-PROVIDE",
    7: "U-ATTACH-DETACH-GROUP-IDENTITY",
    8: "U-ATTACH-DETACH-GROUP-IDENTITY-ACK",
    9: "U-TEI-PROVIDE", 11: "U-DISABLE-STATUS",
    15: "MM-FUNCTION-NOT-SUPPORTED",
}

LOCATION_UPDATE_TYPE = {
    0: "Roaming", 1: "Migrating", 2: "Periodic",
    3: "ItsiAttach", 4: "ServiceRestoration-Roaming",
    5: "ServiceRestoration-Migrating", 6: "Demand",
    7: "DisabledMsUpdating",
}

REJECT_CAUSE = {
    1: "ItsiAtsiUnknown", 2: "IllegalMs", 3: "LaNotAllowed",
    4: "LaUnknown", 5: "NetworkFailure", 6: "Congestion",
    7: "ForwardRegistrationFailure", 8: "ServiceNotSubscribed",
    9: "MandatoryElementError", 10: "MessageConsistencyError",
    11: "RoamingNotSupported", 12: "MigrationNotSupported",
    13: "NoCipherKsg", 14: "IdentifiedCipherKsgNotSupported",
    15: "RequestedCipherKeyTypeNotAvailable",
    16: "IdentifiedCipherKeyNotAvailable", 18: "CipheringRequired",
    19: "AuthenticationFailure", 20: "UseCaCellNotPermitted",
    21: "UseDaCellNotPermitted",
}

ENERGY_SAVING_MODE = {
    0: "OnOnly", 1: "Mode1", 2: "Mode2", 3: "Mode3",
    4: "Mode4", 5: "Mode5", 6: "Mode6", 7: "Mode7",
}

# DL MM Status (Type1 4-bit cause) per ETSI EN 300 392-2 § 16.10.10
MM_STATUS_DL = {
    0: "NoExtension", 1: "AcceptedWithoutChange",
    # rest reserved/proprietary
}


# ---------------------------------------------------------------------------
# BitReader (private, same shape as tetra_cmce._BR)
# ---------------------------------------------------------------------------
class _BR:
    __slots__ = ("bits", "pos", "end")

    def __init__(self, bits, start=0, end=None):
        self.bits = bits
        self.pos = start
        self.end = end if end is not None else len(bits)

    def remaining(self):
        return self.end - self.pos

    def read(self, n):
        if self.pos + n > self.end:
            raise ValueError(f"underrun: want {n} have {self.remaining()}")
        v = 0
        for i in range(n):
            v = (v << 1) | (self.bits[self.pos + i] & 1)
        self.pos += n
        return v

    def read_bit(self):
        return self.read(1)


def _type2_opt(br: _BR, obit: bool, n: int) -> Optional[int]:
    if not obit:
        return None
    if br.remaining() < 1:
        return None
    if not br.read_bit():
        return None
    if br.remaining() < n:
        return None
    return br.read(n)


def _class_of_ms(br: _BR) -> dict:
    """ClassOfMs Type2 struct (variable length, BlueStation `class_of_ms.rs`)."""
    # First 24 bits = capability flags. Bits beyond are version-dependent;
    # we only decode the 24 documented capability bits here.
    if br.remaining() < 24:
        return {"truncated": True}
    v = br.read(24)
    return {
        "freq_simplex_duplex": bool(v & (1 << 23)),
        "multislot_phase_mod": bool(v & (1 << 22)),
        "concurrent_multicarrier": bool(v & (1 << 21)),
        "voice": bool(v & (1 << 20)),
        "e2e_encryption_not_supported": bool(v & (1 << 19)),
        "circuit_mode_data": bool(v & (1 << 18)),
        "tetra_packet_data": bool(v & (1 << 17)),
        "fast_switching": bool(v & (1 << 16)),
        "dck_encryption": bool(v & (1 << 15)),
        "clch_needed": bool(v & (1 << 14)),
        "concurrent_circuit_mode": bool(v & (1 << 13)),
        "original_advanced_link": bool(v & (1 << 12)),
        "raw": v,
    }


# ---------------------------------------------------------------------------
# UL PDU parsers
# ---------------------------------------------------------------------------
def parse_u_itsi_detach(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-ITSI-DETACH"}
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["address_extension"] = _type2_opt(br, obit, 24)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_loc_upd_demand(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-LOC-UPD-DEMAND"}
    p["loc_upd_type"] = LOCATION_UPDATE_TYPE.get(br.read(3), "?")
    p["request_to_append_la"] = bool(br.read_bit())
    p["cipher_control"] = bool(br.read_bit())
    if p["cipher_control"]:
        p["ciphering_parameters"] = br.read(10) if br.remaining() >= 10 else None
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    # ClassOfMs as type2-struct (24-bit cap-flag block)
    if obit and br.remaining() >= 1 and br.read_bit():
        p["class_of_ms"] = _class_of_ms(br)
    esm = _type2_opt(br, obit, 3)
    p["energy_saving_mode"] = ENERGY_SAVING_MODE.get(esm, "?") if esm is not None else None
    la_raw = _type2_opt(br, obit, 15)
    if la_raw is not None:
        # BlueStation notes: 14 bits LA + 1 padding bit
        p["la_information"] = la_raw >> 1
    p["ssi"] = _type2_opt(br, obit, 24)
    p["address_extension"] = _type2_opt(br, obit, 24)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_mm_status(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-MM-STATUS"}
    p["status"] = br.read(4) if br.remaining() >= 4 else None
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_authentication(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-AUTHENTICATION"}
    if br.remaining() >= 2:
        p["auth_sub_type"] = br.read(2)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_attach_detach_group(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-ATTACH-DETACH-GROUP-IDENTITY"}
    p["group_identity_report"] = bool(br.read_bit())
    p["mode"] = "DetachAndAttach" if br.read_bit() else "Amendment"
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_attach_detach_group_ack(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-ATTACH-DETACH-GROUP-IDENTITY-ACK"}
    p["group_identity_report"] = bool(br.read_bit())
    p["mode"] = "DetachAndAttach" if br.read_bit() else "Amendment"
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_tei_provide(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-TEI-PROVIDE"}
    if br.remaining() >= 60:
        p["tei"] = br.read(60)  # 15-digit TEI = 60 bits BCD
    p["bits_consumed"] = br.pos - start
    return p


# ---------------------------------------------------------------------------
# DL PDU parsers
# ---------------------------------------------------------------------------
def parse_d_loc_upd_accept(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-LOC-UPD-ACCEPT"}
    p["loc_upd_accept_type"] = LOCATION_UPDATE_TYPE.get(br.read(3), "?")
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["ssi"] = _type2_opt(br, obit, 24)
    p["address_extension"] = _type2_opt(br, obit, 24)
    p["subscriber_class"] = _type2_opt(br, obit, 16)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_loc_upd_command(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-LOC-UPD-COMMAND"}
    p["group_identity_report"] = bool(br.read_bit())
    p["cipher_control"] = bool(br.read_bit())
    if p["cipher_control"]:
        p["ciphering_parameters"] = br.read(10) if br.remaining() >= 10 else None
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["address_extension"] = _type2_opt(br, obit, 24)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_loc_upd_reject(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-LOC-UPD-REJECT"}
    p["loc_upd_type"] = LOCATION_UPDATE_TYPE.get(br.read(3), "?")
    p["reject_cause"] = REJECT_CAUSE.get(br.read(5), "?")
    p["cipher_control"] = bool(br.read_bit())
    if p["cipher_control"]:
        p["ciphering_parameters"] = br.read(10) if br.remaining() >= 10 else None
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["address_extension"] = _type2_opt(br, obit, 24)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_loc_upd_proceeding(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-LOC-UPD-PROCEEDING"}
    p["loc_upd_type"] = LOCATION_UPDATE_TYPE.get(br.read(3), "?")
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_attach_detach_group(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-ATTACH-DETACH-GROUP-IDENTITY"}
    p["group_identity_report"] = bool(br.read_bit())
    p["ack_request"] = bool(br.read_bit())
    p["mode"] = "DetachAndAttach" if br.read_bit() else "Amendment"
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_attach_detach_group_ack(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-ATTACH-DETACH-GROUP-IDENTITY-ACK"}
    p["group_identity_report"] = bool(br.read_bit())
    p["mode"] = "DetachAndAttach" if br.read_bit() else "Amendment"
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_mm_status(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-MM-STATUS"}
    if br.remaining() >= 4:
        p["status"] = MM_STATUS_DL.get(br.read(4), "?")
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_authentication(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-AUTHENTICATION"}
    if br.remaining() >= 2:
        p["auth_sub_type"] = br.read(2)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_disable(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-DISABLE"}
    p["intent"] = br.read(1) if br.remaining() >= 1 else None
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_enable(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-ENABLE"}
    p["intent"] = br.read(1) if br.remaining() >= 1 else None
    p["bits_consumed"] = br.pos - start
    return p


# ---------------------------------------------------------------------------
# Dispatchers
# ---------------------------------------------------------------------------
_DL_DISPATCH = {
    1: parse_d_authentication,
    3: parse_d_disable,
    4: parse_d_enable,
    5: parse_d_loc_upd_accept,
    6: parse_d_loc_upd_command,
    7: parse_d_loc_upd_reject,
    9: parse_d_loc_upd_proceeding,
    10: parse_d_attach_detach_group,
    11: parse_d_attach_detach_group_ack,
    12: parse_d_mm_status,
}

_UL_DISPATCH = {
    0: parse_u_authentication,
    1: parse_u_itsi_detach,
    2: parse_u_loc_upd_demand,
    3: parse_u_mm_status,
    7: parse_u_attach_detach_group,
    8: parse_u_attach_detach_group_ack,
    9: parse_u_tei_provide,
}


def parse_mm_dl(bits, start=0) -> Optional[dict]:
    """Parse DL MM PDU. `bits[start:]` begins with 4-bit pdu_type."""
    if len(bits) - start < 4:
        return None
    pdu_type = 0
    for i in range(4):
        pdu_type = (pdu_type << 1) | (bits[start + i] & 1)
    name = MM_DL.get(pdu_type, f"unknown_dl_{pdu_type}")
    fn = _DL_DISPATCH.get(pdu_type)
    if fn is None:
        return {"pdu": name, "pdu_type_id": pdu_type, "raw": "no parser"}
    try:
        result = fn(bits, start + 4)
        result["pdu_type_id"] = pdu_type
        return result
    except (ValueError, IndexError) as e:
        return {"pdu": name, "pdu_type_id": pdu_type, "err": str(e)}


def parse_mm_ul(bits, start=0) -> Optional[dict]:
    """Parse UL MM PDU. `bits[start:]` begins with 4-bit pdu_type."""
    if len(bits) - start < 4:
        return None
    pdu_type = 0
    for i in range(4):
        pdu_type = (pdu_type << 1) | (bits[start + i] & 1)
    name = MM_UL.get(pdu_type, f"unknown_ul_{pdu_type}")
    fn = _UL_DISPATCH.get(pdu_type)
    if fn is None:
        return {"pdu": name, "pdu_type_id": pdu_type, "raw": "no parser"}
    try:
        result = fn(bits, start + 4)
        result["pdu_type_id"] = pdu_type
        return result
    except (ValueError, IndexError) as e:
        return {"pdu": name, "pdu_type_id": pdu_type, "err": str(e)}


def format_mm(p: dict) -> str:
    if not p or "pdu" not in p:
        return "<empty>"
    parts = [p["pdu"]]
    for k in ("loc_upd_type", "loc_upd_accept_type", "reject_cause", "status",
              "cipher_control", "request_to_append_la", "group_identity_report",
              "ack_request", "mode", "energy_saving_mode",
              "ssi", "address_extension", "subscriber_class", "la_information",
              "ciphering_parameters", "auth_sub_type", "intent", "tei"):
        if k in p and p[k] is not None:
            v = p[k]
            if isinstance(v, bool):
                v = int(v)
            parts.append(f"{k}={v}")
    if "class_of_ms" in p and p["class_of_ms"]:
        cm = p["class_of_ms"]
        caps = []
        if cm.get("voice"): caps.append("voice")
        if cm.get("circuit_mode_data"): caps.append("cmd")
        if cm.get("tetra_packet_data"): caps.append("pkt")
        if cm.get("e2e_encryption_not_supported"): caps.append("noE2E")
        if cm.get("dck_encryption"): caps.append("dck")
        parts.append(f"class_of_ms=[{','.join(caps) or '-'}]")
    if "err" in p:
        parts.append(f"ERR:{p['err']}")
    return " ".join(parts)
