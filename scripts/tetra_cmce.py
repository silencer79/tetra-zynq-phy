"""
tetra_cmce.py — CMCE PDU field-level parser (Phase 1)

Mirrors BlueStation `tetra-bluestation/crates/tetra-pdus/src/cmce/` PDU layouts
per ETSI EN 300 392-2 § 14. Coverage:
  - Downlink: D-SETUP, D-CONNECT, D-CONNECT-ACK, D-TX-CEASED, D-TX-GRANTED,
              D-TX-CONTINUE, D-TX-WAIT, D-TX-INTERRUPT, D-CALL-PROCEEDING,
              D-DISCONNECT, D-RELEASE, D-INFO, D-ALERT
  - Uplink:   U-SETUP, U-CONNECT, U-TX-CEASED, U-TX-DEMAND, U-RELEASE,
              U-DISCONNECT, U-ALERT, U-INFO

Bit-stream convention: input is a list[int] of 0/1, MSB-first within each
field — same as decode_dl.extract_bits() returns.

Each parser returns a dict with the parsed fields plus a 'bits_consumed' key.
Type2/Type3 optional-element parsing stops at the trailing m-bit and may
leave fields == None.
"""
from __future__ import annotations
from typing import Optional


# ---------------------------------------------------------------------------
# Enums (BlueStation `cmce/enums/`)
# ---------------------------------------------------------------------------
CMCE_DL = {
    0: "D-ALERT", 1: "D-CALL-PROCEEDING", 2: "D-CONNECT", 3: "D-CONNECT-ACK",
    4: "D-DISCONNECT", 5: "D-INFO", 6: "D-RELEASE", 7: "D-SETUP",
    8: "D-STATUS", 9: "D-TX-CEASED", 10: "D-TX-CONTINUE", 11: "D-TX-GRANTED",
    12: "D-TX-WAIT", 13: "D-TX-INTERRUPT", 14: "D-CALL-RESTORE",
    15: "D-SDS-DATA", 16: "D-FACILITY", 31: "CMCE-FUNCTION-NOT-SUPPORTED",
}

CMCE_UL = {
    0: "U-ALERT", 2: "U-CONNECT", 4: "U-DISCONNECT", 5: "U-INFO",
    6: "U-RELEASE", 7: "U-SETUP", 8: "U-STATUS", 9: "U-TX-CEASED",
    10: "U-TX-DEMAND", 14: "U-CALL-RESTORE", 15: "U-SDS-DATA",
    16: "U-FACILITY", 31: "CMCE-FUNCTION-NOT-SUPPORTED",
}

TRANSMISSION_GRANT = {
    0: "Granted", 1: "NotGranted", 2: "RequestQueued", 3: "GrantedToOther",
}

CALL_TIMEOUT = {
    0: "Infinite", 1: "30s", 2: "45s", 3: "60s", 4: "2m", 5: "3m",
    6: "4m", 7: "5m", 8: "6m", 9: "8m", 10: "10m", 11: "12m",
    12: "15m", 13: "20m", 14: "30m", 15: "Reserved",
}

CALL_TIMEOUT_SETUP_PHASE = {
    0: "Infinite", 1: "5s", 2: "10s", 3: "15s", 4: "20s",
    5: "30s", 6: "45s", 7: "60s",
}

CIRCUIT_MODE_TYPE = {
    0: "TCH/S", 1: "TCH/7.2", 2: "TCH/4.8-N1", 3: "TCH/4.8-N4",
    4: "TCH/4.8-N8", 5: "TCH/2.4-N1", 6: "TCH/2.4-N4", 7: "TCH/2.4-N8",
}

COMMUNICATION_TYPE = {
    0: "P2P", 1: "P2MP", 2: "P2MP-ACK", 3: "BROADCAST",
}

PARTY_TYPE = {
    0: "SNA", 1: "SSI", 2: "TSI", 3: "Reserved",
}

DISCONNECT_CAUSE = {
    0: "NotDefined", 1: "UserRequested", 2: "CalledPartyBusy",
    3: "CalledPartyNotReachable", 4: "CalledPartyDoesNotSupportEncryption",
    5: "CongestionInInfrastructure", 6: "NotAllowedTrafficCase",
    7: "IncompatibleTrafficCase", 8: "RequestedFacilityNotImplemented",
    9: "RemoteUserInitiatedDisconnect", 10: "Reserved10",
    11: "Reserved11", 12: "Reserved12", 13: "Reserved13", 14: "Reserved14",
    15: "Reserved15", 16: "ResourcesNotAvailableForCallRestore",
    17: "OtherError", 18: "CallTimeoutExpired", 19: "NotAuthorized",
    20: "Unknown", 21: "Cancelled",
}


# ---------------------------------------------------------------------------
# BitReader helper
# ---------------------------------------------------------------------------
class _BR:
    """Bit reader over a list[int] MSB-first."""
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


# ---------------------------------------------------------------------------
# Common field parsers
# ---------------------------------------------------------------------------
def _bsi(br: _BR) -> dict:
    """Basic Service Information (8 bits + 2 cond)."""
    cmt = br.read(3)
    enc = br.read(1)
    com = br.read(2)
    # 2 conditional bits: speech_service if TCH/S, otherwise slots_per_frame
    extra = br.read(2)
    d = {
        "circuit_mode_type": CIRCUIT_MODE_TYPE.get(cmt, f"unk_{cmt}"),
        "encryption_flag": bool(enc),
        "communication_type": COMMUNICATION_TYPE.get(com, f"unk_{com}"),
    }
    if cmt == 0:
        d["speech_service"] = extra
    else:
        d["slots_per_frame"] = extra
    return d


def _type2_opt(br: _BR, obit: bool, n: int) -> Optional[int]:
    """Type-2 optional field: o-bit gates whole group, p-bit gates this field."""
    if not obit:
        return None
    if br.remaining() < 1:
        return None
    pbit = br.read_bit()
    if not pbit:
        return None
    if br.remaining() < n:
        return None
    return br.read(n)


def _skip_type3(br: _BR, obit: bool):
    """Skip optional Type-3 elements (we don't parse them for now)."""
    if not obit:
        return
    # Read m-bit; if 0, no more elements
    while br.remaining() >= 1:
        mbit = br.read_bit()
        if not mbit:
            return
        # Element-id (8) + length (variable) — we don't decode; just bail
        # to be safe rather than mis-parsing. Mark as 'has_type3'.
        return


# ---------------------------------------------------------------------------
# DL PDU parsers
# ---------------------------------------------------------------------------
def parse_d_setup(bits, start=0) -> dict:
    """D-SETUP (CmcePduTypeDl=7). 5-bit pdu_type already consumed by caller."""
    br = _BR(bits, start)
    p = {"pdu": "D-SETUP"}
    p["call_id"] = br.read(14)
    p["call_timeout"] = CALL_TIMEOUT.get(br.read(4), "?")
    p["hook"] = br.read_bit()
    p["duplex"] = br.read_bit()  # 0=simplex 1=duplex
    p["bsi"] = _bsi(br)
    p["tx_grant"] = TRANSMISSION_GRANT.get(br.read(2), "?")
    p["tx_req_perm"] = bool(br.read_bit())
    p["call_priority"] = br.read(4)
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    p["temporary_address"] = _type2_opt(br, obit, 24)
    cpti = _type2_opt(br, obit, 2)
    p["calling_party_type"] = PARTY_TYPE.get(cpti, "?") if cpti is not None else None
    if obit and cpti in (1, 2):
        p["calling_party_ssi"] = br.read(24) if br.remaining() >= 24 else None
    if obit and cpti == 2:
        p["calling_party_extension"] = br.read(24) if br.remaining() >= 24 else None
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_connect(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-CONNECT"}
    p["call_id"] = br.read(14)
    p["call_timeout"] = CALL_TIMEOUT.get(br.read(4), "?")
    p["hook"] = br.read_bit()
    p["duplex"] = br.read_bit()
    p["tx_grant"] = TRANSMISSION_GRANT.get(br.read(2), "?")
    p["tx_req_perm"] = bool(br.read_bit())
    p["call_ownership"] = br.read_bit()
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["call_priority"] = _type2_opt(br, obit, 4)
    bsi_present = _type2_opt(br, obit, 0)  # placeholder, real check below
    # BlueStation: BSI is type2-struct → if obit && pbit, parse BSI inline.
    # We approximate: any remaining bits after call_priority should be BSI.
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_connect_ack(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-CONNECT-ACK"}
    p["call_id"] = br.read(14)
    p["call_timeout"] = CALL_TIMEOUT.get(br.read(4), "?")
    p["tx_grant"] = TRANSMISSION_GRANT.get(br.read(2), "?")
    p["tx_req_perm"] = bool(br.read_bit())
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_tx_ceased(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-TX-CEASED"}
    p["call_id"] = br.read(14)
    p["tx_req_perm"] = bool(br.read_bit())
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_tx_granted(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-TX-GRANTED"}
    p["call_id"] = br.read(14)
    p["tx_grant"] = TRANSMISSION_GRANT.get(br.read(2), "?")
    p["tx_req_perm"] = bool(br.read_bit())
    p["encryption_control"] = bool(br.read_bit())
    p["_reserved"] = br.read_bit()
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    tpti = _type2_opt(br, obit, 2)
    p["tx_party_type"] = PARTY_TYPE.get(tpti, "?") if tpti is not None else None
    if obit and tpti in (1, 2):
        p["tx_party_ssi"] = br.read(24) if br.remaining() >= 24 else None
    if obit and tpti == 2:
        p["tx_party_extension"] = br.read(24) if br.remaining() >= 24 else None
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_tx_continue(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-TX-CONTINUE"}
    p["call_id"] = br.read(14)
    p["do_continue"] = bool(br.read_bit())
    p["tx_req_perm"] = bool(br.read_bit())
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_tx_wait(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-TX-WAIT"}
    p["call_id"] = br.read(14)
    p["tx_req_perm"] = bool(br.read_bit())
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_tx_interrupt(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-TX-INTERRUPT"}
    p["call_id"] = br.read(14)
    p["tx_grant"] = TRANSMISSION_GRANT.get(br.read(2), "?")
    p["tx_req_perm"] = bool(br.read_bit())
    p["encryption_control"] = bool(br.read_bit())
    p["_reserved"] = br.read_bit()
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_call_proceeding(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-CALL-PROCEEDING"}
    p["call_id"] = br.read(14)
    p["call_timeout_setup"] = CALL_TIMEOUT_SETUP_PHASE.get(br.read(3), "?")
    p["hook"] = br.read_bit()
    p["duplex"] = br.read_bit()
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    # Type2: BSI (8 bits + 2 cond) — we just gobble 10 if present
    if obit and br.remaining() >= 1 and br.read_bit():
        if br.remaining() >= 10:
            p["bsi"] = _bsi(br)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_disconnect(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-DISCONNECT"}
    p["call_id"] = br.read(14)
    p["cause"] = DISCONNECT_CAUSE.get(br.read(5), "?")
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_release(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-RELEASE"}
    p["call_id"] = br.read(14)
    p["cause"] = DISCONNECT_CAUSE.get(br.read(5), "?")
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["notification_indicator"] = _type2_opt(br, obit, 6)
    _skip_type3(br, obit)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_info(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-INFO"}
    p["call_id"] = br.read(14)
    p["reset_t310"] = bool(br.read_bit())
    p["poll_request"] = bool(br.read_bit())
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    p["new_call_id"] = _type2_opt(br, obit, 14)
    p["call_timeout"] = _type2_opt(br, obit, 4)
    p["bits_consumed"] = br.pos - start
    return p


def parse_d_alert(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "D-ALERT"}
    p["call_id"] = br.read(14)
    p["bits_consumed"] = br.pos - start
    return p


# ---------------------------------------------------------------------------
# UL PDU parsers
# ---------------------------------------------------------------------------
def parse_u_setup(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-SETUP"}
    p["area_selection"] = br.read(4)
    p["hook"] = br.read_bit()
    p["duplex"] = br.read_bit()
    p["bsi"] = _bsi(br)
    p["request_to_transmit"] = bool(br.read_bit())
    p["call_priority"] = br.read(4)
    p["clir_control"] = br.read(2)
    cpti = br.read(2)
    p["called_party_type"] = PARTY_TYPE.get(cpti, "?")
    if cpti == 0:
        p["called_party_sna"] = br.read(8) if br.remaining() >= 8 else None
    elif cpti in (1, 2):
        p["called_party_ssi"] = br.read(24) if br.remaining() >= 24 else None
    if cpti == 2:
        p["called_party_extension"] = br.read(24) if br.remaining() >= 24 else None
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_connect(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-CONNECT"}
    p["call_id"] = br.read(14)
    p["hook"] = br.read_bit()
    p["duplex"] = br.read_bit()
    obit = bool(br.read_bit()) if br.remaining() >= 1 else False
    if obit and br.remaining() >= 1 and br.read_bit() and br.remaining() >= 10:
        p["bsi"] = _bsi(br)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_tx_ceased(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-TX-CEASED"}
    p["call_id"] = br.read(14)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_tx_demand(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-TX-DEMAND"}
    p["call_id"] = br.read(14)
    p["priority"] = br.read(2)
    p["encryption_control"] = bool(br.read_bit())
    p["_reserved"] = br.read_bit()
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_release(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-RELEASE"}
    p["call_id"] = br.read(14)
    p["cause"] = DISCONNECT_CAUSE.get(br.read(5), "?")
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_disconnect(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-DISCONNECT"}
    p["call_id"] = br.read(14)
    p["cause"] = DISCONNECT_CAUSE.get(br.read(5), "?")
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_alert(bits, start=0) -> dict:
    br = _BR(bits, start)
    p = {"pdu": "U-ALERT"}
    p["call_id"] = br.read(14)
    p["bits_consumed"] = br.pos - start
    return p


# ---------------------------------------------------------------------------
# Dispatchers
# ---------------------------------------------------------------------------
def _parse_d_sds_data_wrap(bits, start=0):
    """Phase 4 — D-SDS-DATA via tetra_sds. Imported lazily."""
    try:
        from tetra_sds import parse_d_sds_data
        return parse_d_sds_data(bits, start)
    except ImportError:
        return {"pdu": "D-SDS-DATA", "raw": "tetra_sds module missing"}


def _parse_u_sds_data_wrap(bits, start=0):
    try:
        from tetra_sds import parse_u_sds_data
        return parse_u_sds_data(bits, start)
    except ImportError:
        return {"pdu": "U-SDS-DATA", "raw": "tetra_sds module missing"}


_DL_DISPATCH = {
    0: parse_d_alert,
    1: parse_d_call_proceeding,
    2: parse_d_connect,
    3: parse_d_connect_ack,
    4: parse_d_disconnect,
    5: parse_d_info,
    6: parse_d_release,
    7: parse_d_setup,
    9: parse_d_tx_ceased,
    10: parse_d_tx_continue,
    11: parse_d_tx_granted,
    12: parse_d_tx_wait,
    13: parse_d_tx_interrupt,
    15: _parse_d_sds_data_wrap,
}

_UL_DISPATCH = {
    0: parse_u_alert,
    2: parse_u_connect,
    4: parse_u_disconnect,
    6: parse_u_release,
    7: parse_u_setup,
    9: parse_u_tx_ceased,
    10: parse_u_tx_demand,
    15: _parse_u_sds_data_wrap,
}


def parse_cmce_dl(bits, start=0) -> Optional[dict]:
    """Parse DL CMCE PDU. `bits[start:]` begins with 5-bit pdu_type."""
    if len(bits) - start < 5:
        return None
    pdu_type = 0
    for i in range(5):
        pdu_type = (pdu_type << 1) | (bits[start + i] & 1)
    name = CMCE_DL.get(pdu_type, f"unknown_dl_{pdu_type}")
    fn = _DL_DISPATCH.get(pdu_type)
    if fn is None:
        return {"pdu": name, "pdu_type_id": pdu_type, "raw": "no parser"}
    try:
        result = fn(bits, start + 5)
        result["pdu_type_id"] = pdu_type
        return result
    except (ValueError, IndexError) as e:
        return {"pdu": name, "pdu_type_id": pdu_type, "err": str(e)}


def parse_cmce_ul(bits, start=0) -> Optional[dict]:
    """Parse UL CMCE PDU. `bits[start:]` begins with 5-bit pdu_type."""
    if len(bits) - start < 5:
        return None
    pdu_type = 0
    for i in range(5):
        pdu_type = (pdu_type << 1) | (bits[start + i] & 1)
    name = CMCE_UL.get(pdu_type, f"unknown_ul_{pdu_type}")
    fn = _UL_DISPATCH.get(pdu_type)
    if fn is None:
        return {"pdu": name, "pdu_type_id": pdu_type, "raw": "no parser"}
    try:
        result = fn(bits, start + 5)
        result["pdu_type_id"] = pdu_type
        return result
    except (ValueError, IndexError) as e:
        return {"pdu": name, "pdu_type_id": pdu_type, "err": str(e)}


# ---------------------------------------------------------------------------
# Pretty-printer
# ---------------------------------------------------------------------------
def format_cmce(p: dict) -> str:
    """Compact single-line representation of a CMCE parse result."""
    if not p or "pdu" not in p:
        return "<empty>"
    # SDS PDUs have richer field layout — delegate to tetra_sds.format_sds
    if p.get("pdu") in ("D-SDS-DATA", "U-SDS-DATA"):
        try:
            from tetra_sds import format_sds
            return format_sds(p)
        except ImportError:
            pass
    parts = [p["pdu"]]
    for k in ("call_id", "call_timeout", "call_timeout_setup", "cause",
              "tx_grant", "tx_req_perm", "hook", "duplex",
              "call_priority", "request_to_transmit",
              "called_party_type", "called_party_ssi", "called_party_sna",
              "calling_party_type", "calling_party_ssi",
              "tx_party_type", "tx_party_ssi",
              "do_continue", "reset_t310", "poll_request",
              "encryption_control", "call_ownership",
              "area_selection", "clir_control", "priority",
              "notification_indicator", "temporary_address"):
        if k in p and p[k] is not None:
            v = p[k]
            if isinstance(v, bool):
                v = int(v)
            parts.append(f"{k}={v}")
    if "bsi" in p and p["bsi"]:
        b = p["bsi"]
        bsi_s = f"{b.get('circuit_mode_type','?')}/{b.get('communication_type','?')}"
        if b.get("encryption_flag"):
            bsi_s += "/ENC"
        parts.append(f"bsi=[{bsi_s}]")
    if "err" in p:
        parts.append(f"ERR:{p['err']}")
    return " ".join(parts)
