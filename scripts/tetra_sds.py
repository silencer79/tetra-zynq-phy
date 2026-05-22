"""
tetra_sds.py — SDS (Short Data Service) PDU + Transport-Layer decoder (Phase 4)

Coverage (BlueStation `tetra-pdus/src/cmce/pdus/{d,u}_sds_data.rs` +
`enums/sds_protocol_id.rs` + ETSI EN 300 392-2 § 14.7 / § 29):

  D-SDS-DATA / U-SDS-DATA Felder:
    calling/called party type + address, short_data_type (SDS-1/2/3/4),
    user_data with protocol_id (when SDS-4).

  SDS short-data types:
    SDS-1 — 16-bit status                    (immediate, no TL)
    SDS-2 — 32-bit user data                 (immediate, no TL)
    SDS-3 — 64-bit user data                 (immediate, no TL)
    SDS-4 — variable user data, 8-bit prot_id + payload (may carry SDS-TL)

  SDS-TL (Transport Layer, when protocol_id >= 128):
    message_type (4 bits), reference (8 bits), forward/short_form flags,
    plus protocol-specific application data.

  Text-Message decode (protocol_id == TextMessaging / TextMessagingSdsTl):
    timestamp + encoding (4 bits) + text-data.
    Encodings: GSM-7, ISO 8859-1 Latin-1, ISO 8859-{2..15}, UCS-2 BE.
"""
from __future__ import annotations
from typing import Optional


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------
SDS_PROTOCOL_ID = {
    # Immediate (no SDS-TL header)
    1: "OTAK",
    2: "SimpleTextMessaging",
    3: "SimpleLocationSystem",
    4: "WirelessDatagramProtocol",
    5: "WirelessControlMessageProtocol",
    6: "M-DMO",
    7: "PinAuthentication",
    8: "EteeMessage",
    9: "SimpleImmediateTextMessaging",
    10: "LocationInformationProtocol",
    11: "NetAssistProtocol2",
    12: "ConcatenatedSdsMessage",
    13: "DOTAM",
    14: "SimpleAgnssService",
    # SDS-TL transport-layer (with TL header)
    130: "TextMessagingSdsTl",
    131: "LocationSystemSdsTl",
    132: "WirelessDatagramProtocolSdsTl",
    133: "WirelessControlMessageProtocolSdsTl",
    134: "M-DMO-SdsTl",
    136: "EteeMessageSdsTl",
    137: "ImmediateTextMessagingSdsTl",
    138: "MessageWithUserDataHeader",
    140: "ConcatenatedSdsMessageSdsTl",
    141: "AgnssServiceSdsTl",
}

PARTY_TYPE = {
    0: "SNA", 1: "SSI", 2: "TSI", 3: "Reserved",
}

# SDS-TL message types (ETSI EN 300 392-2 § 29.4)
SDS_TL_MESSAGE_TYPE = {
    0: "OPEN-SESSION",   # actually reserved-style; varies per protocol
    1: "SDS-TRANSFER",
    2: "SDS-REPORT",
    3: "SDS-ACK",
    8: "SDS-OPEN-SESSION-ACK",
    9: "SDS-SHORT-REPORT",
}

# Text-message encoding identifier (§ 29.5.4.3 Table 29.21)
SDS_TEXT_ENCODING = {
    0: "GSM-7bit",
    1: "ISO-8859-1",
    2: "ISO-8859-2",
    3: "ISO-8859-3",
    4: "ISO-8859-4",
    5: "ISO-8859-5",
    6: "ISO-8859-6",
    7: "ISO-8859-7",
    8: "ISO-8859-8",
    9: "ISO-8859-9",
    10: "ISO-8859-10",
    11: "ISO-8859-13",
    12: "ISO-8859-14",
    13: "ISO-8859-15",
    14: "Reserved-14",
    15: "Codepage-cyr",
    16: "Codepage-arabic",
    17: "UCS-2",
    18: "Reserved-18",
    19: "Reserved-19",
}

# Short-data-type-identifier (2 bits in PDU)
SHORT_DATA_TYPE = {
    0: "SDS-1 (status, 16-bit)",
    1: "SDS-2 (32-bit)",
    2: "SDS-3 (64-bit)",
    3: "SDS-4 (variable)",
}

SHORT_REPORT_TYPE = {
    0: "ProtocolOrEncodingNotSupported",
    1: "DestinationMemoryFull",
    2: "MessageReceived",
    3: "MessageConsumed",
}


# ---------------------------------------------------------------------------
# BitReader
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


# ---------------------------------------------------------------------------
# GSM-7 decoder (default alphabet, ETSI 03.38 § 6.2.1)
# ---------------------------------------------------------------------------
_GSM7 = (
    "@\xa3$\xa5\xe8\xe9\xf9\xec\xf2\xc7\n\xd8\xf8\r\xc5\xe5"
    "Δ_ΦΓΛΩΠΨΣΘΞ"
    "\x1b\xc6\xe6\xdf\xc9"
    " !\"#\xa4%&'()*+,-./"
    "0123456789:;<=>?"
    "\xa1ABCDEFGHIJKLMNO"
    "PQRSTUVWXYZ\xc4\xd6\xd1\xdc\xa7"
    "\xbfabcdefghijklmno"
    "pqrstuvwxyz\xe4\xf6\xf1\xfc\xe0"
)


def _gsm7_decode(bits) -> str:
    """Decode septet-packed GSM-7 bits MSB-first → str."""
    out = []
    nbytes = (len(bits) + 6) // 7
    for i in range(nbytes):
        v = 0
        for j in range(7):
            idx = i * 7 + j
            if idx < len(bits):
                v = (v << 1) | (bits[idx] & 1)
            else:
                v <<= 1
        if v < len(_GSM7):
            out.append(_GSM7[v])
        else:
            out.append("?")
    return "".join(out).rstrip("@\x00")


def _decode_text(bits, encoding_id: int) -> str:
    """Decode text-message body bits → string per encoding_id."""
    if not bits:
        return ""
    enc_name = SDS_TEXT_ENCODING.get(encoding_id, f"unk_{encoding_id}")
    if enc_name == "GSM-7bit":
        return _gsm7_decode(bits)
    # Byte-oriented encodings: pack 8-bit MSB-first
    n_bytes = len(bits) // 8
    data = bytearray()
    for i in range(n_bytes):
        v = 0
        for j in range(8):
            v = (v << 1) | (bits[i * 8 + j] & 1)
        data.append(v)
    if enc_name == "UCS-2":
        try:
            return data.decode("utf-16-be", errors="replace")
        except Exception:
            return data.hex()
    iso_map = {
        "ISO-8859-1": "latin-1", "ISO-8859-2": "iso-8859-2",
        "ISO-8859-3": "iso-8859-3", "ISO-8859-4": "iso-8859-4",
        "ISO-8859-5": "iso-8859-5", "ISO-8859-6": "iso-8859-6",
        "ISO-8859-7": "iso-8859-7", "ISO-8859-8": "iso-8859-8",
        "ISO-8859-9": "iso-8859-9", "ISO-8859-10": "iso-8859-10",
        "ISO-8859-13": "iso-8859-13", "ISO-8859-14": "iso-8859-14",
        "ISO-8859-15": "iso-8859-15",
    }
    codec = iso_map.get(enc_name)
    if codec:
        try:
            return data.decode(codec, errors="replace")
        except Exception:
            return data.hex()
    return data.hex()


# ---------------------------------------------------------------------------
# SDS-TL parsing (§ 29.4)
# ---------------------------------------------------------------------------
def _parse_sds_tl(br: _BR, protocol_name: str) -> dict:
    """Parse SDS-TL header (4-bit msg-type + protocol-specific body).

    For TextMessagingSdsTl: msg_type, delivery_report_request, service_selection,
    message_reference, optional timestamp, encoding, text.
    """
    p = {"sds_tl": True}
    if br.remaining() < 4:
        return p
    msg_type = br.read(4)
    p["sds_tl_msg_type"] = SDS_TL_MESSAGE_TYPE.get(msg_type, f"unk_{msg_type}")
    p["sds_tl_msg_type_id"] = msg_type

    if protocol_name == "TextMessagingSdsTl" and msg_type == 1:  # SDS-TRANSFER
        # Delivery report request (2), Service-Selection / Short-Form-Report (1), Storage (1)
        if br.remaining() >= 4:
            p["delivery_report_request"] = br.read(2)
            p["service_selection"] = br.read_bit()
            p["storage"] = br.read_bit()
        # Message reference (8 bits)
        if br.remaining() >= 8:
            p["message_reference"] = br.read(8)
        # Protocol-id ext / TimeStamp existence — varies by version; ETSI
        # § 29.5.4 places encoding-id directly here in basic SDS-TRANSFER.
        # Encoding identifier (4 bits) + reserved (4 bits) — depends on protocol
        if br.remaining() >= 4:
            p["text_encoding"] = SDS_TEXT_ENCODING.get(br.read(4), "?")
        # Whatever bits remain are the text payload
        rest = br.bits[br.pos:br.end]
        p["text"] = _decode_text(rest, list(SDS_TEXT_ENCODING.keys())[
            list(SDS_TEXT_ENCODING.values()).index(p.get("text_encoding", "GSM-7bit"))
        ] if p.get("text_encoding") in SDS_TEXT_ENCODING.values() else 0)
        br.pos = br.end
    elif protocol_name == "TextMessagingSdsTl" and msg_type == 9:  # SHORT-REPORT
        if br.remaining() >= 2:
            p["short_report_type"] = SHORT_REPORT_TYPE.get(br.read(2), "?")
        if br.remaining() >= 8:
            p["message_reference"] = br.read(8)

    # Stash remaining bytes raw for debugging
    if br.remaining() > 0:
        n = br.remaining() // 8
        if n > 0:
            raw = []
            for i in range(n):
                v = 0
                for j in range(8):
                    v = (v << 1) | br.read_bit()
                raw.append(v)
            p["sds_tl_trailing_hex"] = " ".join(f"{b:02X}" for b in raw)
    return p


# ---------------------------------------------------------------------------
# User-data parsers (per short_data_type_identifier)
# ---------------------------------------------------------------------------
def _parse_user_data(br: _BR, sdt: int) -> dict:
    """Parse SDS user_defined_data per short_data_type_identifier."""
    if sdt == 0:  # SDS-1 — 16-bit status
        if br.remaining() < 16:
            return {"type": "SDS-1", "err": "underrun"}
        return {"type": "SDS-1", "status": br.read(16)}
    if sdt == 1:  # SDS-2 — 32-bit
        if br.remaining() < 32:
            return {"type": "SDS-2", "err": "underrun"}
        return {"type": "SDS-2", "data32": br.read(32)}
    if sdt == 2:  # SDS-3 — 64-bit
        if br.remaining() < 64:
            return {"type": "SDS-3", "err": "underrun"}
        return {"type": "SDS-3", "data64": br.read(64)}
    if sdt == 3:  # SDS-4 — variable
        if br.remaining() < 11:
            return {"type": "SDS-4", "err": "no length"}
        len_bits = br.read(11)
        d = {"type": "SDS-4", "length_bits": len_bits}
        if len_bits < 8:
            return d
        # First 8 bits = protocol_id
        prot = br.read(8)
        d["protocol_id"] = prot
        d["protocol_name"] = SDS_PROTOCOL_ID.get(prot, f"unk_{prot}")
        body_bits = len_bits - 8
        if br.remaining() < body_bits:
            body_bits = br.remaining()
        # If protocol >= 128 → SDS-TL header present
        if prot >= 128 and body_bits >= 4:
            sub_br = _BR(br.bits, br.pos, br.pos + body_bits)
            d.update(_parse_sds_tl(sub_br, d["protocol_name"]))
            br.pos += body_bits
        else:
            # Immediate protocol: try basic text-decode for SimpleTextMessaging
            if prot in (2, 9):  # SimpleTextMessaging / Immediate
                payload_bits = br.bits[br.pos:br.pos + body_bits]
                br.pos += body_bits
                # Heuristic: assume GSM-7
                d["text"] = _gsm7_decode(payload_bits)
            else:
                # Generic dump
                nb = body_bits // 8
                raw = []
                for i in range(nb):
                    v = 0
                    for j in range(8):
                        v = (v << 1) | br.read_bit()
                    raw.append(v)
                if body_bits % 8:
                    br.read(body_bits % 8)
                d["payload_hex"] = " ".join(f"{b:02X}" for b in raw)
        return d
    return {"type": f"unk_{sdt}"}


# ---------------------------------------------------------------------------
# Top-level CMCE D-/U-SDS-DATA parsers
# ---------------------------------------------------------------------------
def parse_d_sds_data(bits, start=0) -> dict:
    """Parse D-SDS-DATA body. `bits[start:]` begins AFTER 5-bit pdu_type."""
    br = _BR(bits, start)
    p = {"pdu": "D-SDS-DATA"}
    cpti = br.read(2)
    p["calling_party_type"] = PARTY_TYPE.get(cpti, "?")
    if cpti in (1, 2):
        p["calling_party_ssi"] = br.read(24) if br.remaining() >= 24 else None
    if cpti == 2:
        p["calling_party_extension"] = br.read(24) if br.remaining() >= 24 else None
    sdt = br.read(2)
    p["short_data_type"] = SHORT_DATA_TYPE.get(sdt, f"unk_{sdt}")
    p["user_data"] = _parse_user_data(br, sdt)
    p["bits_consumed"] = br.pos - start
    return p


def parse_u_sds_data(bits, start=0) -> dict:
    """Parse U-SDS-DATA body."""
    br = _BR(bits, start)
    p = {"pdu": "U-SDS-DATA"}
    p["area_selection"] = br.read(4)
    cpti = br.read(2)
    p["called_party_type"] = PARTY_TYPE.get(cpti, "?")
    if cpti == 0:
        p["called_party_sna"] = br.read(8) if br.remaining() >= 8 else None
    elif cpti in (1, 2):
        p["called_party_ssi"] = br.read(24) if br.remaining() >= 24 else None
    if cpti == 2:
        p["called_party_extension"] = br.read(24) if br.remaining() >= 24 else None
    sdt = br.read(2)
    p["short_data_type"] = SHORT_DATA_TYPE.get(sdt, f"unk_{sdt}")
    p["user_data"] = _parse_user_data(br, sdt)
    p["bits_consumed"] = br.pos - start
    return p


def format_sds(p: dict) -> str:
    if not p or "pdu" not in p:
        return "<empty>"
    parts = [p["pdu"]]
    for k in ("calling_party_type", "calling_party_ssi", "calling_party_extension",
              "called_party_type", "called_party_ssi", "called_party_sna",
              "area_selection", "short_data_type"):
        if k in p and p[k] is not None:
            parts.append(f"{k}={p[k]}")
    ud = p.get("user_data") or {}
    if ud:
        parts.append(f"[{ud.get('type', '?')}", )
        if "status" in ud:
            parts.append(f"status=0x{ud['status']:04X}")
        if "data32" in ud:
            parts.append(f"data=0x{ud['data32']:08X}")
        if "data64" in ud:
            parts.append(f"data=0x{ud['data64']:016X}")
        if "protocol_name" in ud:
            parts.append(f"prot={ud['protocol_name']}")
        if "sds_tl_msg_type" in ud:
            parts.append(f"tl={ud['sds_tl_msg_type']}")
        if "message_reference" in ud:
            parts.append(f"ref={ud['message_reference']}")
        if "text_encoding" in ud:
            parts.append(f"enc={ud['text_encoding']}")
        if "text" in ud and ud["text"]:
            txt = ud["text"][:60].replace("\n", "\\n").replace("\r", "\\r")
            parts.append(f"text='{txt}'")
        if "payload_hex" in ud:
            parts.append(f"payload=[{ud['payload_hex'][:48]}]")
        parts.append("]")
    return " ".join(parts)
