#!/usr/bin/env python3
"""parse_reference_decode.py — Reference-Capture full decompose.

Reads:
  /tmp/dl_full_decode.log   (decode_dl.py --dump-burst -3 — every burst)
  /tmp/ul_full_decode.log   (decode_ul.py --dump-bits — every burst)

Writes (docs/reference_decode/):
  README.md
  burst_inventory.md
  dl_full.md            — every DL burst, every channel-coding layer
  ul_full.md            — every UL burst, every layer
  action_reaction.md    — UL action ↔ DL reaction (slot-based DL-time)
  dl_events.jsonl       — machine-readable per-burst events (all 7000+)
  ul_events.jsonl       — machine-readable per-burst events (all 190+)

For every NDB1/NDB2/NUB burst we DISPLAY all four channel-coding layers:
  type-5 onair → type-4 descrambled → type-3 deinterleaved → info post-Viterbi

Channel-coding parameters (ETSI EN 300 392-2 §8.2.3):
  SCH/F  (NDB1):  K=432, a=103, info=268 bits
  SCH/HD (NDB2):  K=216, a=101, info=124 bits, per BKN
  SCH/HU (NUB) :  K=168, a=13 , info=92  bits
  SB1    (SB)  :  K=120, a=11 , info=60  bits  (BNCH SYSINFO)
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs' / 'reference_decode'
OUT.mkdir(parents=True, exist_ok=True)
DL_LOG = Path('/tmp/dl_full_decode.log')
UL_LOG = Path('/tmp/ul_full_decode.log')

WAV_DUR_DL = 103.979
WAV_DUR_UL = 109.355
SLOT_S     = 14.167e-3                 # 1 TDMA slot
SLOTS_MF   = 18 * 4                     # 72 slots / multiframe
SLOTS_HF   = 60 * SLOTS_MF              # 4320 slots / hyperframe

CORR_WINDOW_S = 3.0                     # action-reaction search window


# =============================================================================
# Layer-1 helpers: descramble + deinterleave (forensic decompose)
# =============================================================================

def cell_scrambler_seq(init: int, n: int) -> list:
    """ETSI EN 300 392-2 §8.2.5 LFSR cell-scrambler. Returns n bits."""
    seq = [0] * n
    state = init & 0xFFFFFFFF
    for i in range(n):
        bit = ((state >> 31) ^ (state >> 30) ^ (state >> 29) ^ (state >> 27)
               ^ (state >> 25) ^ (state >> 0)) & 1
        seq[i] = bit
        state = ((state << 1) | bit) & 0xFFFFFFFF
    return seq


def descramble_bits(bitstr: str, init: int) -> str:
    """XOR a binary-string with the cell-scrambler PRBS."""
    seq = cell_scrambler_seq(init, len(bitstr))
    return ''.join(str(int(b) ^ s) for b, s in zip(bitstr, seq))


def deinterleave_perm(bitstr: str, K: int, a: int) -> str:
    """ETSI multiplicative de-interleave: out[i-1] = in[((a*i) mod K)]."""
    out = ['0'] * K
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        out[i - 1] = bitstr[k - 1]
    return ''.join(out)


def bits_to_hex(bitstr: str) -> str:
    """Pack a binary-string into hex (MSB-first per nibble). Pads with 0."""
    pad = (-len(bitstr)) % 4
    bs = bitstr + '0' * pad
    out = []
    for i in range(0, len(bs), 4):
        v = (int(bs[i]) << 3) | (int(bs[i + 1]) << 2) | (int(bs[i + 2]) << 1) | int(bs[i + 3])
        out.append(f'{v:X}')
    return ''.join(out)


def short_bits(bitstr: str, head=64) -> str:
    """Truncate a long binary string for log-display (keep head bits + '…')."""
    if len(bitstr) <= head:
        return bitstr
    return bitstr[:head] + '…'


# =============================================================================
# DL log parser
# =============================================================================
# Burst header: idx, type, TN/FN/MN — optional suffix word inside brackets
# (BNCH for SB carrying SYSINFO).  Suffix tail after `]` contains AACH or
# ROUNDTRIP_DUMP_SB.
DL_HDR = re.compile(
    r'^\[#\s*(?P<idx>\d+)\]\s+'
    r'(?P<type>SB|NDB1|NDB2)\s+'
    r'\[TN=(?P<tn>\d+)\s+FN=(?P<fn>\d+)\s+MN=(?P<mn>\d+)(?:\s+(?P<suffix>\w+))?\]\s+'
    r'corr=(?P<corr>[\d.]+)'
)
DL_INLINE_AACH = re.compile(r'AACH\s+\[(?P<kind>[^\]]+)\]\s*(?P<rest>.*)$')
RAW_LINE = re.compile(r'^\s+ROUNDTRIP_DUMP(?:_SB|_HD|_AACH)?\s+(\S+)=(\S+)')
SB1CRC = re.compile(r'^SB1 CRC OK \[TMO\] MCC=(\d+) MNC=(\d+) CC=(\d+) FN\(air\)=(\d+) MF\(air\)=(\d+) TN\(air\)=(\d+)')
SCHF_MAC = re.compile(r'^\s*SCH/F\s+(MAC-\S+)\s+addr=(\S+)(?:\s+ID=(-?\d+))?(?:\s+LI=(\d+))?')
SCHHD_MAC = re.compile(r'^\s*BKN(\d)\s+SCH/HD\s+(MAC-\S+)(?:\s+(.+))?')
BKN_BCAST = re.compile(r'^\s*BKN(\d)?\s+(MAC-BROADCAST)\s+sub=(\S+)')
LLC_LINE = re.compile(r'^\s+LLC\s+(.+)$')
MLE_LINE = re.compile(r'^\s+MLE\s+disc=(\S+)(?:\s+(.+))?$')
CMCE_LINE = re.compile(r'^\s+CMCE\s+(.+)$')
MM_LINE = re.compile(r'^\s+MM\s+(.+)$')


def _new_dl_event(m):
    return {
        'idx': int(m.group('idx')),
        'type': m.group('type'),
        'tn': int(m.group('tn')),
        'fn': int(m.group('fn')),
        'mn': int(m.group('mn')),
        'suffix': m.group('suffix'),                # e.g. 'BNCH' or None
        'corr': float(m.group('corr')),
        'aach_kind': None, 'aach_raw': None, 'aach_dist': None, 'aach_extra': None,
        'sb_dibits': None, 'sb1_info_60b': None,
        'sb1_t5_onair_120b': None, 'sb1_t4_descr_120b': None, 'sb1_t3_deint_120b': None,
        'type5_onair_432b': None, 'info_268b': None, 'info_hex': None,
        'bkn1_onair_216b': None, 'bkn2_onair_216b': None,
        'bkn1_info_124b': None, 'bkn2_info_124b': None,
        'bb_raw_30b': None, 'bb_descr_30b': None, 'aach_info_14b': None,
        'scramb_code': None,
        'crc_ok': None, 'cell': None,
        'fn_air': None, 'mn_air': None, 'tn_air': None,
        'mac': [], 'llc': [], 'mle': [], 'cmce': [], 'mm': [],
        'sysinfo': None,
    }


def parse_dl():
    events = []
    cur = None
    if not DL_LOG.exists():
        print(f'WARN: {DL_LOG} not found', file=sys.stderr)
        return events
    with open(DL_LOG) as f:
        for line in f:
            line = line.rstrip('\n')
            m = DL_HDR.match(line)
            if m:
                if cur is not None:
                    events.append(cur)
                cur = _new_dl_event(m)
                tail = line[m.end():]
                inl = DL_INLINE_AACH.search(tail)
                if inl:
                    cur['aach_kind'] = inl.group('kind')
                    cur['aach_extra'] = inl.group('rest')
                    rm = re.search(r'raw=0x([0-9A-Fa-f]+)', cur['aach_extra'] or '')
                    if rm:
                        cur['aach_raw'] = '0x' + rm.group(1).upper()
                    dm = re.search(r'dist=(\d+)', cur['aach_extra'] or '')
                    if dm:
                        cur['aach_dist'] = int(dm.group(1))
                # Detect inline ROUNDTRIP_DUMP_SB on the same line as the header (SB bursts)
                rm = re.search(r'ROUNDTRIP_DUMP_SB\s+(\S+)=(\S+)', tail)
                if rm:
                    if rm.group(1) == 'sb_dibits':
                        cur['sb_dibits'] = rm.group(2)
                continue
            if cur is None:
                continue
            rm = RAW_LINE.match(line)
            if rm:
                key, val = rm.group(1), rm.group(2)
                if key == 'sb_dibits':              cur['sb_dibits'] = val
                elif key == 'sb1_info_60b':         cur['sb1_info_60b'] = val
                elif key == 'sb1_t5_onair_120b':    cur['sb1_t5_onair_120b'] = val
                elif key == 'sb1_t4_descr_120b':    cur['sb1_t4_descr_120b'] = val
                elif key == 'sb1_t3_deint_120b':    cur['sb1_t3_deint_120b'] = val
                elif key == 'type5_onair_432b':     cur['type5_onair_432b'] = val
                elif key == 'info_268b':            cur['info_268b'] = val
                elif key == 'info_hex':             cur['info_hex'] = val
                elif key == 'scramb_code':          cur['scramb_code'] = val
                elif key == 'bkn1_onair_216b':      cur['bkn1_onair_216b'] = val
                elif key == 'bkn2_onair_216b':      cur['bkn2_onair_216b'] = val
                elif key == 'bkn1_info_124b':       cur['bkn1_info_124b'] = val
                elif key == 'bkn2_info_124b':       cur['bkn2_info_124b'] = val
                elif key == 'bb_raw_30b':           cur['bb_raw_30b'] = val
                elif key == 'bb_descr_30b':         cur['bb_descr_30b'] = val
                elif key == 'aach_info_14b':        cur['aach_info_14b'] = val
                continue
            mr = SB1CRC.match(line)
            if mr:
                cur['crc_ok'] = True
                cur['cell'] = dict(mcc=int(mr.group(1)), mnc=int(mr.group(2)), cc=int(mr.group(3)))
                cur['fn_air'] = int(mr.group(4))
                cur['mn_air'] = int(mr.group(5))
                cur['tn_air'] = int(mr.group(6))
                continue
            mr = SCHF_MAC.match(line)
            if mr:
                cur['mac'].append({'fmt': 'SCH/F', 'pdu': mr.group(1), 'addr': mr.group(2),
                                   'id': mr.group(3), 'li': int(mr.group(4)) if mr.group(4) else None})
                continue
            mr = SCHHD_MAC.match(line)
            if mr:
                cur['mac'].append({'fmt': 'SCH/HD', 'bkn': int(mr.group(1)),
                                   'pdu': mr.group(2), 'rest': mr.group(3)})
                continue
            mr = BKN_BCAST.match(line)
            if mr:
                cur['mac'].append({'fmt': 'BCAST', 'bkn': mr.group(1), 'sub': mr.group(3)})
                continue
            mr = LLC_LINE.match(line)
            if mr:
                cur['llc'].append(mr.group(1))
                continue
            mr = MLE_LINE.match(line)
            if mr:
                cur['mle'].append({'disc': mr.group(1), 'msg': mr.group(2) or ''})
                continue
            mr = CMCE_LINE.match(line)
            if mr:
                cur['cmce'].append(mr.group(1))
                continue
            mr = MM_LINE.match(line)
            if mr:
                cur['mm'].append(mr.group(1))
                continue
            if 'Carrier=' in line and 'DL=' in line:
                cur['sysinfo'] = line.strip()
    if cur is not None:
        events.append(cur)
    return events


# =============================================================================
# UL log parser (rows of the SCH/HU table + post-table bits92/parsed)
# =============================================================================
UL_ROW = re.compile(
    r'^\s*(?P<i>\d+)\s+(?P<t>\d+\.\d+)\s+(?P<cx>\d+\.\d+)\s+'
    r'(?P<a>[-+\d.]+)\s+(?P<b>[-+\d.]+)\s+'
    r'(?P<crc>OK|-|SKIP)\s+(?P<flag>\S+)\s+(?P<hex>.+)$'
)
UL_SKIP_ROW = re.compile(
    r'^\s*(?P<i>\d+)\s+(?P<t>\d+\.\d+)\s+(?P<cx>\d+\.\d+)\s+SKIP\s*\((?P<reason>.+)\)\s*$'
)
UL_BITS92_PURE = re.compile(r'^\s+bits92=(\S+)')
UL_PARSED = re.compile(r"^\s+parsed=(\{.+\})\s*$")
UL_PDU_HEX = re.compile(r'^\s*#(\d+):\s+([0-9A-Fa-f ]+)\s*$')
UL_HU_DUMP = re.compile(r'^\s+ROUNDTRIP_DUMP_HU\s+(\S+)=(\S+)')


def parse_ul():
    events = []
    if not UL_LOG.exists():
        print(f'WARN: {UL_LOG} not found', file=sys.stderr)
        return events
    with open(UL_LOG) as f:
        lines = f.readlines()

    # First pass: parse table rows AND interleaved ROUNDTRIP_DUMP_HU lines.
    # The decoder emits dump lines immediately AFTER each burst's row.
    cur = None
    for line in lines:
        line = line.rstrip('\n')
        m = UL_ROW.match(line)
        if m:
            cur = {
                'idx':   int(m.group('i')),
                'time':  float(m.group('t')),
                'corrX': float(m.group('cx')),
                'A_mrad': float(m.group('a')),
                'B_mrad': float(m.group('b')),
                'crc':   m.group('crc'),
                'flag':  m.group('flag'),
                'pdu_hex_head': m.group('hex').strip(),
                'bits92': None,
                'parsed': None,
                'skip_reason': None,
                'type5_onair_168b': None,
                'type4_descr_168b': None,
                'info_92b_dump': None,
                'scramb_code': None,
                'variant': None,
            }
            events.append(cur)
            continue
        m = UL_SKIP_ROW.match(line)
        if m:
            cur = {
                'idx':   int(m.group('i')),
                'time':  float(m.group('t')),
                'corrX': float(m.group('cx')),
                'A_mrad': None,
                'B_mrad': None,
                'crc':   'SKIP',
                'flag':  None,
                'pdu_hex_head': None,
                'bits92': None,
                'parsed': None,
                'skip_reason': m.group('reason'),
                'type5_onair_168b': None,
                'type4_descr_168b': None,
                'info_92b_dump': None,
                'scramb_code': None,
                'variant': None,
            }
            events.append(cur)
            continue
        if cur is not None:
            m = UL_HU_DUMP.match(line)
            if m:
                key, val = m.group(1), m.group(2)
                if key == 'type5_onair':    cur['type5_onair_168b'] = val
                elif key == 'type4_descr':  cur['type4_descr_168b'] = val
                elif key == 'info':         cur['info_92b_dump']    = val
                elif key == 'scramb_code':  cur['scramb_code']      = val
                elif key == 'variant':      cur['variant']          = val
                continue

    # Second pass: bits92 + parsed (only printed for CRC-OK rows after the table)
    crc_ok_evs = [e for e in events if e['crc'] == 'OK']
    pdu_iter = iter(crc_ok_evs)
    cur = None
    for line in lines:
        line = line.rstrip('\n')
        m = UL_PDU_HEX.match(line)
        if m:
            try:
                cur = next(pdu_iter)
            except StopIteration:
                cur = None
            continue
        if cur is None:
            continue
        m = UL_BITS92_PURE.match(line)
        if m:
            cur['bits92'] = m.group(1)
            continue
        m = UL_PARSED.match(line)
        if m:
            try:
                cur['parsed'] = eval(m.group(1), {"__builtins__": {}}, {})
            except Exception:
                cur['parsed'] = m.group(1)
            continue
    return events


# =============================================================================
# Slot-based DL time
# =============================================================================
def _slot_id(ev):
    return (ev['mn'] - 1) * SLOTS_MF + (ev['fn'] - 1) * 4 + (ev['tn'] - 1)


def detect_dl_anchor(dl):
    """First SB/NDB1/NDB2 burst that doesn't sit alone in a different HF."""
    if len(dl) < 2:
        return 0
    s0 = _slot_id(dl[0])
    s1 = _slot_id(dl[1])
    delta_fwd = (s1 - s0) % SLOTS_HF
    if dl[0]['type'] == 'SB' and delta_fwd > SLOTS_HF // 4:
        return 1
    return 0


def build_dl_time(dl):
    """Returns dl_time(idx_or_event)→seconds and the anchor list-position."""
    if not dl:
        return (lambda _x: None), 0
    anchor = detect_dl_anchor(dl)
    abs_slot = [None] * len(dl)
    s0 = _slot_id(dl[anchor])
    abs_slot[anchor] = s0
    wrap = 0
    prev = s0
    for i in range(anchor + 1, len(dl)):
        s = _slot_id(dl[i])
        sa = s + wrap * SLOTS_HF
        if sa < prev - SLOTS_HF // 2:
            wrap += 1
            sa = s + wrap * SLOTS_HF
        abs_slot[i] = sa
        prev = sa
    pos_of_idx = {ev['idx']: i for i, ev in enumerate(dl)}
    s_ref = abs_slot[anchor]

    def dl_time(arg):
        if isinstance(arg, int):
            i = pos_of_idx.get(arg)
        else:
            i = pos_of_idx.get(arg['idx'])
        if i is None or abs_slot[i] is None:
            return None
        return (abs_slot[i] - s_ref) * SLOT_S

    return dl_time, anchor


# =============================================================================
# Pretty-print helpers
# =============================================================================
def _addr_label(m):
    parts = [m.get('pdu', '?')]
    if m.get('fmt'):
        parts.append(f"({m['fmt']})")
    if m.get('addr'):
        parts.append(f"addr={m['addr']}")
    if m.get('id'):
        parts.append(f"ID={m['id']}")
    if m.get('li') is not None:
        parts.append(f"LI={m['li']}")
    if m.get('sub'):
        parts.append(f"sub={m['sub']}")
    if m.get('rest'):
        parts.append(str(m['rest']))
    if m.get('bkn') is not None:
        parts.append(f"BKN{m['bkn']}")
    return ' '.join(str(p) for p in parts)


def is_addressed(ev):
    if ev.get('type') != 'NDB1':
        return False
    for m in (ev.get('mac') or []):
        a = m.get('addr', 'NULL')
        if a and a != 'NULL':
            return True
    return False


def is_broadcast(ev):
    for m in (ev.get('mac') or []):
        if str(m.get('id', '')) == '16777215':
            return True
    return False


# =============================================================================
# Writers
# =============================================================================
def write_jsonl(p, events):
    with open(p, 'w') as f:
        for ev in events:
            f.write(json.dumps(ev) + '\n')


def write_readme(dl, ul, dl_time):
    last_t = dl_time(dl[-1]['idx']) if dl else 0
    with open(OUT / 'README.md', 'w') as f:
        f.write(f"""# Reference Capture — Full Decompose

Bit-genaue Decompose der beiden Reference-WAVs.

## Sources

| WAV | Dauer | Bursts detected | Bursts decoded |
|---|---|---|---|
| `wavs/reference/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | {WAV_DUR_DL:.2f} s | — | {len(dl)} |
| `wavs/reference/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav` | {WAV_DUR_UL:.2f} s | — | {len(ul)} |

**Cell-Lock (TMO):** MCC=262 MNC=1010 CC=1 · Carrier=3719 · DL=392.9875 MHz · UL=382.9875 MHz · Scrambler=`0x4183F207` · MS ISSI=`0x282FF4` (2633716)

## Decoder Pipeline

```
WAV → wav_to_dibits → π/4-DQPSK soft → STS/NTS/x-seq sync → cell lock
     → per-burst phase correct → descramble → deinterleave → Viterbi → CRC
     → MAC layer → LLC layer → MLE/MM/CMCE/SDS layer
```

| Burst | Channel | K | a | info | Sync | Use |
|---|---|---|---|---|---|---|
| SB    | SB1     | 120 | 11  |  60 | STS 38-sym  | SYSINFO BNCH |
| NDB1  | SCH/F   | 432 | 103 | 268 | NTS1 11-sym | Signaling MAC-RESOURCE |
| NDB2  | SCH/HD  | 216 | 101 | 124 | NTS2 11-sym | Signaling/NULL or Voice TCH/S |
| NUB   | SCH/HU  | 168 | 13  |  92 | x-seq 15-sym| UL Signaling MAC-ACCESS |

## Files

| File | Inhalt |
|---|---|
| [burst_inventory.md](./burst_inventory.md) | Statistik DL+UL Burst-Typen, AACH-Verteilung |
| [dl_full.md](./dl_full.md) | Jeder DL-Burst, alle Layer (type-5 onair → type-4 desc → type-3 deint → info → MAC/LLC/MLE) |
| [ul_full.md](./ul_full.md) | Jeder UL-Burst, alle Layer + MAC-ACCESS Decode |
| [action_reaction.md](./action_reaction.md) | UL-Action ↔ DL-Reaction Zeit-korreliert (Slot-Time) |
| `dl_events.jsonl` / `ul_events.jsonl` | machine-readable JSONL pro Burst |

## Reproduce

```bash
python3 scripts/decode_dl.py wavs/reference/GOLD_DL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav \\
  --sr 250000 --max-bursts 10000 --dump-burst -3 > /tmp/dl_full_decode.log

python3 scripts/decode_ul.py wavs/reference/GOLD_UL_ANMELDUNG_GRUPPENWECHSEL_GRUPPENRUF.wav \\
  --cc 1 --mcc 262 --mnc 1010 --max-bursts 500 --dump-bits --cfo 0.001 > /tmp/ul_full_decode.log

python3 scripts/parse_reference_decode.py
```

## Decompose Summary

- DL bursts decoded: **{len(dl)}**, DL-time span 0..{last_t:.3f} s
- UL bursts decoded: **{len(ul)}** ({sum(1 for u in ul if u['crc']=='OK')} OK, {sum(1 for u in ul if u['crc']=='-')} FAIL, {sum(1 for u in ul if u['crc']=='SKIP')} SKIP)
""")


def write_inventory(dl, ul):
    types = {}
    aach = {}
    addr = {}
    bnch_count = 0
    for ev in dl:
        types[ev['type']] = types.get(ev['type'], 0) + 1
        if ev.get('suffix') == 'BNCH':
            bnch_count += 1
        if ev['aach_kind']:
            key = (ev['aach_kind'], ev.get('aach_raw') or 'n/a')
            aach[key] = aach.get(key, 0) + 1
        for m in ev['mac']:
            a = m.get('addr')
            if a is not None and a != 'NULL':
                addr[a] = addr.get(a, 0) + 1

    sig_ndb1 = sum(1 for ev in dl if is_addressed(ev))
    sig_addr = sum(1 for ev in dl if is_addressed(ev) and not is_broadcast(ev))
    ul_ok = sum(1 for u in ul if u['crc'] == 'OK')
    ul_fail = sum(1 for u in ul if u['crc'] == '-')
    ul_skip = sum(1 for u in ul if u['crc'] == 'SKIP')

    with open(OUT / 'burst_inventory.md', 'w') as f:
        f.write('# Burst Inventory — Reference Capture\n\n')
        f.write('## DL Statistics\n\n')
        f.write(f'- **Bursts decoded:** {len(dl)}\n')
        f.write('- **Types:** ' + ', '.join(f'{k}={v}' for k, v in sorted(types.items())) + '\n')
        f.write(f'- **SB carrying BNCH (`[... BNCH]` suffix):** {bnch_count}\n')
        f.write(f'- **NDB1 with non-NULL MAC-RESOURCE addr (signaling):** {sig_ndb1}\n')
        f.write(f'  - of these non-broadcast (real addressed): {sig_addr}\n\n')
        f.write('### AACH-Pattern Distribution\n\n')
        f.write('| Count | Kind | Raw |\n|---|---|---|\n')
        for (k, raw), v in sorted(aach.items(), key=lambda x: -x[1]):
            f.write(f'| {v} | {k} | {raw} |\n')
        f.write('\n### Addressed Bursts (non-NULL MAC-RESOURCE addr)\n\n')
        f.write('| Count | Addr |\n|---|---|\n')
        for a, c in sorted(addr.items(), key=lambda x: -x[1]):
            f.write(f'| {c} | `{a}` |\n')
        f.write('\n## UL Statistics\n\n')
        f.write(f'- **Bursts detected/parsed:** {len(ul)}\n')
        f.write(f'- **CRC OK (SCH/HU signaling):** {ul_ok}\n')
        f.write(f'- **CRC FAIL (mostly TCH/S voice payload):** {ul_fail}\n')
        f.write(f'- **SKIP (weak x-correlation):** {ul_skip}\n')


def write_dl_full(dl, dl_time):
    """Every DL burst with every channel-coding layer."""
    with open(OUT / 'dl_full.md', 'w') as f:
        f.write(f'# DL — Full Burst Decompose ({len(dl)} bursts)\n\n')
        f.write('Every burst chronologically, every channel-coding layer.\n\n')
        f.write('**Layer chain (NDB1 SCH/F, K=432, a=103, info=268):**\n\n')
        f.write('```\n')
        f.write('type-5 (onair, 432 bit) ─XOR scramb→ type-4 (descrambled, 432 bit)\n')
        f.write('                                     │\n')
        f.write('                                     ▼\n')
        f.write('   info (268 bit, post-Viterbi) ←─Viterbi K=5 r=1/4 ← type-3 (deinterleaved a=103, 432 bit)\n')
        f.write('```\n\n')
        f.write('**NDB2 SCH/HD:** zwei separate Half-Slots (BKN1+BKN2), je K=216 a=101 info=124.\n\n')
        f.write('---\n\n')
        for ev in dl:
            t = dl_time(ev['idx'])
            t_str = f't={t:.3f}s' if t is not None else 't=?'
            suffix = f' {ev["suffix"]}' if ev.get('suffix') else ''
            f.write(f'## #{ev["idx"]:5d}  {t_str}  TN{ev["tn"]} FN{ev["fn"]:02d} MN{ev["mn"]:02d}{suffix}  {ev["type"]}  corr={ev["corr"]:.3f}\n\n')

            # --- AACH (first half-slot, always present except possibly SB-init) ---
            if ev['aach_kind']:
                aach = f'`{ev["aach_kind"]}`'
                if ev['aach_raw']:
                    aach += f' raw=`{ev["aach_raw"]}`'
                if ev['aach_dist'] is not None:
                    aach += f' dist={ev["aach_dist"]}'
                if ev['aach_extra']:
                    aach += f' · {ev["aach_extra"]}'
                f.write(f'- **AACH:** {aach}\n')
            # AACH layer chain (RM(30,14), 30 onair → 30 descrambled → 14 info)
            if ev.get('bb_raw_30b'):
                f.write(f'- **AACH bb (30 bit onair):** `{ev["bb_raw_30b"]}`\n')
            if ev.get('bb_descr_30b'):
                f.write(f'- **AACH bb (30 bit descrambled):** `{ev["bb_descr_30b"]}`\n')
            if ev.get('aach_info_14b'):
                ai = ev['aach_info_14b']
                f.write(f'- **AACH info (14 bit, post-RM(30,14)):** `{ai}` (hex `0x{int(ai, 2):04X}`)\n')

            # --- SB-Sync: BNCH SYSINFO carrier info ---
            if ev['type'] == 'SB':
                if ev.get('sb_dibits'):
                    db = ev['sb_dibits']
                    f.write(f'- **SB dibits ({len(db)}):** `{db}`\n')
                if ev.get('sb1_t5_onair_120b'):
                    t5 = ev['sb1_t5_onair_120b']
                    f.write(f'- **SB1 type-5 onair (120 bit):**\n  - bin: `{t5}`\n  - hex: `0x{bits_to_hex(t5)}`\n')
                if ev.get('sb1_t4_descr_120b'):
                    t4 = ev['sb1_t4_descr_120b']
                    f.write(f'- **SB1 type-4 descrambled (BSCH init=3, 120 bit):**\n  - bin: `{t4}`\n  - hex: `0x{bits_to_hex(t4)}`\n')
                if ev.get('sb1_t3_deint_120b'):
                    t3 = ev['sb1_t3_deint_120b']
                    f.write(f'- **SB1 type-3 deinterleaved (a=11, 120 bit):**\n  - bin: `{t3}`\n  - hex: `0x{bits_to_hex(t3)}`\n')
                if ev.get('sb1_info_60b'):
                    info = ev['sb1_info_60b']
                    f.write(f'- **SB1 info (60 bit, post-Viterbi + CRC):** `{info}` (hex `0x{int(info, 2):015X}`)\n')
                if ev['cell']:
                    c = ev['cell']
                    f.write(f'- **CRC-OK [TMO]:** MCC={c["mcc"]} MNC={c["mnc"]} CC={c["cc"]} · FN(air)={ev["fn_air"]} MF(air)={ev["mn_air"]} TN(air)={ev["tn_air"]}\n')
                for m in ev['mac']:
                    f.write(f'- MAC: {_addr_label(m)}\n')
                if ev['sysinfo']:
                    f.write(f'- SYSINFO: {ev["sysinfo"]}\n')

            # --- NDB1 SCH/F: full K=432 layer chain ---
            elif ev['type'] == 'NDB1':
                if ev.get('type5_onair_432b'):
                    t5 = ev['type5_onair_432b']
                    f.write(f'- **type-5 onair (432 bit):**\n  - bin: `{t5}`\n  - hex: `0x{bits_to_hex(t5)}`\n')
                    if ev.get('scramb_code'):
                        try:
                            init = int(ev['scramb_code'], 16) if isinstance(ev['scramb_code'], str) else int(ev['scramb_code'])
                        except ValueError:
                            init = 0
                        t4 = descramble_bits(t5, init)
                        t3 = deinterleave_perm(t4, K=432, a=103)
                        f.write(f'- **type-4 descrambled (XOR scramb=`{ev["scramb_code"]}`, 432 bit):**\n  - bin: `{t4}`\n  - hex: `0x{bits_to_hex(t4)}`\n')
                        f.write(f'- **type-3 deinterleaved (a=103, 432 bit):**\n  - bin: `{t3}`\n  - hex: `0x{bits_to_hex(t3)}`\n')
                if ev.get('info_268b'):
                    info = ev['info_268b']
                    f.write(f'- **info (268 bit, post-Viterbi K=5 r=1/4 + CRC):**\n  - bin: `{info}`\n')
                if ev.get('info_hex'):
                    f.write(f'- **info_hex (268 bit packed):** `{ev["info_hex"]}`\n')
                if not ev.get('info_268b') and ev.get('type5_onair_432b'):
                    f.write(f'- **info:** _Viterbi/CRC failed — info layer not recoverable, but type-5/-4/-3 above are bit-exact._\n')
                for m in ev['mac']:
                    f.write(f'- MAC: {_addr_label(m)}\n')
                for l in ev['llc']:
                    f.write(f'- LLC: {l}\n')
                for m in ev['mle']:
                    f.write(f'- MLE: disc={m["disc"]} {m["msg"]}\n')
                for c in ev['cmce']:
                    f.write(f'- CMCE: {c}\n')
                for m in ev['mm']:
                    f.write(f'- MM: {m}\n')

            # --- NDB2 SCH/HD: 2 separate BKN K=216 chains ---
            elif ev['type'] == 'NDB2':
                init = None
                if ev.get('scramb_code'):
                    try:
                        init = int(ev['scramb_code'], 16) if isinstance(ev['scramb_code'], str) else int(ev['scramb_code'])
                    except ValueError:
                        init = None
                for bkn in (1, 2):
                    onair_key = f'bkn{bkn}_onair_216b'
                    info_key = f'bkn{bkn}_info_124b'
                    if ev.get(onair_key):
                        onair = ev[onair_key]
                        f.write(f'- **BKN{bkn} type-5 onair (216 bit):**\n  - bin: `{onair}`\n  - hex: `0x{bits_to_hex(onair)}`\n')
                        if init is not None:
                            t4 = descramble_bits(onair, init)
                            t3 = deinterleave_perm(t4, K=216, a=101)
                            f.write(f'- **BKN{bkn} type-4 descrambled (216 bit):**\n  - bin: `{t4}`\n  - hex: `0x{bits_to_hex(t4)}`\n')
                            f.write(f'- **BKN{bkn} type-3 deinterleaved (a=101, 216 bit):**\n  - bin: `{t3}`\n  - hex: `0x{bits_to_hex(t3)}`\n')
                    if ev.get(info_key):
                        info = ev[info_key]
                        f.write(f'- **BKN{bkn} info (124 bit, post-Viterbi):**\n  - bin: `{info}`\n  - hex: `0x{bits_to_hex(info)}`\n')
                for m in ev['mac']:
                    f.write(f'- MAC: {_addr_label(m)}\n')
                for l in ev['llc']:
                    f.write(f'- LLC: {l}\n')
                for m in ev['mle']:
                    f.write(f'- MLE: disc={m["disc"]} {m["msg"]}\n')
                for c in ev['cmce']:
                    f.write(f'- CMCE: {c}\n')
                for m in ev['mm']:
                    f.write(f'- MM: {m}\n')
                if ev['sysinfo']:
                    f.write(f'- SYSINFO: {ev["sysinfo"]}\n')

            f.write('\n')


def write_ul_full(ul):
    with open(OUT / 'ul_full.md', 'w') as f:
        f.write(f'# UL — Full Burst Decompose ({len(ul)} bursts)\n\n')
        ok = sum(1 for u in ul if u['crc'] == 'OK')
        fail = sum(1 for u in ul if u['crc'] == '-')
        skip = sum(1 for u in ul if u['crc'] == 'SKIP')
        f.write(f'CRC distribution: **{ok} OK** · **{fail} CRC FAIL** (mostly TCH/S voice payload) · **{skip} SKIP** (weak x-correlation).\n\n')
        f.write('**NUB SCH/HU layout (K=168, a=13, info=92):**\n\n')
        f.write('```\n')
        f.write('type-5 onair (168 bit) ─XOR scramb→ type-4 desc ─deinterleave a=13→ type-3 ─Viterbi r=2/3 K=5→ info (92 bit)\n')
        f.write('```\n\n')
        f.write('Für CRC-FAIL Bursts (Voice TCH/S) ist `info` nicht semantisch dekodierbar, '
                'aber `type-5 onair` + `type-4 descrambled` sind bit-exakte over-air-Samples.\n\n')
        f.write('---\n\n')
        for u in ul:
            tag = u['crc']
            f.write(f'## #{u["idx"]:3d}  t={u["time"]:.3f}s  corrX={u["corrX"]:.3f}  CRC={tag}\n\n')
            if u['crc'] == 'SKIP':
                f.write(f'- **Status:** SKIP — {u.get("skip_reason", "weak x-corr")}\n\n')
                continue
            f.write(f'- A={u["A_mrad"]:+.0f} mrad  B={u["B_mrad"]:+.0f} mrad  flag=`{u["flag"]}`')
            if u.get('variant'):
                f.write(f'  variant=`{u["variant"]}`')
            f.write('\n')
            f.write(f'- **PDU hex[0:6]:** `{u["pdu_hex_head"]}`\n')

            # Full channel-coding layer chain
            if u.get('type5_onair_168b'):
                t5 = u['type5_onair_168b']
                f.write(f'- **type-5 onair (168 bit):**\n  - bin: `{t5}`\n  - hex: `0x{bits_to_hex(t5)}`\n')
            if u.get('type4_descr_168b'):
                t4 = u['type4_descr_168b']
                f.write(f'- **type-4 descrambled (XOR scramb=`{u.get("scramb_code","?")}`, 168 bit):**\n  - bin: `{t4}`\n  - hex: `0x{bits_to_hex(t4)}`\n')
                # Compute type-3 deinterleaved (a=13) on the fly
                t3 = deinterleave_perm(t4, K=168, a=13)
                f.write(f'- **type-3 deinterleaved (a=13, 168 bit):**\n  - bin: `{t3}`\n  - hex: `0x{bits_to_hex(t3)}`\n')
            if u.get('bits92'):
                bits = u['bits92']
                f.write(f'- **info (92 bit, post-Viterbi r=2/3 K=5 + CRC):**\n  - bin: `{bits}`\n  - hex: `0x{bits_to_hex(bits)}`\n')
            elif u.get('info_92b_dump'):
                bits = u['info_92b_dump']
                f.write(f'- **info (92 bit, post-Viterbi r=2/3 K=5):**\n  - bin: `{bits}`\n  - hex: `0x{bits_to_hex(bits)}`\n')

            if u.get('parsed'):
                p = u['parsed']
                if isinstance(p, dict):
                    f.write(f'- **MAC-ACCESS parsed:**\n')
                    f.write(f'  - pdu_type=`{"MAC-ACCESS" if p.get("pdu_type")==0 else "MAC-END-HU"}`  fill={p.get("fill_bit")}  enc={p.get("encrypted")}\n')
                    f.write(f'  - addr_type=`{p.get("addr_type_name")}` SSI={p.get("ssi", "-")}\n')
                    if p.get('llc'):
                        l = p['llc']
                        f.write(f'  - LLC: type=`{l.get("llc_type_name")}` NS={l.get("ns", "-")} NR={l.get("nr", "-")}\n')
                    if p.get('mle'):
                        m = p['mle']
                        f.write(f'  - MLE: disc=`{m.get("mle_disc_name")}`\n')
                    if p.get('direct_mm'):
                        m = p['direct_mm']
                        f.write(f'  - MM: type=`{m.get("mm_name")}`\n')
                else:
                    f.write(f'- **parsed (raw):** `{p}`\n')
            if u['crc'] == '-':
                f.write(f'- **Status:** CRC FAIL — wahrscheinlich TCH/S Voice-Burst (ACELP-Payload, kein semantischer Decode). Bits oben sind bit-exakte over-air-Samples.\n')
            f.write('\n')


def build_action_reaction(dl, ul, dl_time):
    """UL-action ↔ DL-reaction, slot-based DL-time, ±3s window, also AACH grants."""
    dl_sig = [d for d in dl if is_addressed(d) and not is_broadcast(d)]

    # Estimate UL→DL offset from first plausible pair
    offset = 0.0
    anchor_descr = '(none)'
    ul_first = None
    for u in ul:
        if u['crc'] == 'OK' and u['pdu_hex_head'] and u['pdu_hex_head'].startswith('01 41 7F A7'):
            ul_first = u
            break
    if ul_first is None and ul:
        ul_first = next((u for u in ul if u['crc'] == 'OK'), None)
    dl_first = None
    for d in dl_sig:
        m = (d['mle'] or [{}])[0] if d['mle'] else {}
        if 'LOC-UPD' in (m.get('msg', '') or '') or 'LOC_UPD' in (m.get('msg', '') or ''):
            dl_first = d
            break
    if dl_first is None and dl_sig:
        dl_first = dl_sig[0]
    if ul_first and dl_first:
        t_dl = dl_time(dl_first['idx'])
        if t_dl is not None:
            offset = ul_first['time'] - t_dl
            mle = (dl_first['mle'] or [{}])[0]
            anchor_descr = (f"UL #{ul_first['idx']} t={ul_first['time']:.3f} `{ul_first['pdu_hex_head']}` "
                            f"↔ DL #{dl_first['idx']} dl_t={t_dl:.3f} {mle.get('disc', '?')}→{mle.get('msg', '?')}")

    def find_dl_responses(ul_t, window_s=CORR_WINDOW_S):
        target = ul_t - offset
        found = []
        for d in dl_sig:
            t = dl_time(d['idx'])
            if t is None:
                continue
            dt = t - target
            if -window_s <= dt <= window_s:
                found.append((d, t, dt))
        found.sort(key=lambda x: abs(x[2]))
        return found

    # Also: per-UL the nearest 1-2 AACH grants in DL within ±200ms
    def find_aach_grants(ul_t, window_s=0.2):
        target = ul_t - offset
        found = []
        for d in dl:
            if d['aach_kind'] not in ('DL/UL-Assign', 'CapAlloc'):
                continue
            t = dl_time(d['idx'])
            if t is None:
                continue
            dt = t - target
            if -window_s <= dt <= window_s:
                found.append((d, t, dt))
        found.sort(key=lambda x: abs(x[2]))
        return found[:3]

    out = OUT / 'action_reaction.md'
    with open(out, 'w') as f:
        f.write('# Action ↔ Reaction — UL ↔ DL\n\n')
        f.write(f'**UL→DL Capture-Offset:** `{offset:+.3f} s`\n\n')
        f.write(f'**Anker-Paar:** {anchor_descr}\n\n')
        f.write(f'**Suchfenster:** ±{CORR_WINDOW_S:.1f} s für DL-Signaling-Reaktionen, ±0.2 s für AACH-Grants.\n\n')
        f.write(f'**DL-Zeit:** TDMA-Slot 14.167 ms × (MN,FN,TN) Slot-Index (kein Drift gegenüber idx-basierter Schätzung).\n\n')
        f.write('---\n\n')

        matches_count = 0
        for u in ul:
            head_pdu = u.get('pdu_hex_head') or '—'
            f.write(f'## UL #{u["idx"]}  t={u["time"]:.3f}s  CRC={u["crc"]}  `{head_pdu}`\n\n')
            if u['crc'] == 'SKIP':
                f.write(f'- **SKIP** ({u.get("skip_reason", "weak x")})\n\n')
                continue

            # AACH grants
            grants = find_aach_grants(u['time'])
            if grants:
                f.write('**AACH-Kontext (±0.2 s):**\n\n')
                for d, t, dt in grants:
                    slot = f"TN{d['tn']} FN{d['fn']:02d} MN{d['mn']:02d}"
                    extra = d.get('aach_extra') or ''
                    f.write(f'- DL #{d["idx"]} dl_t={t:.3f}s (Δ={dt*1000:+.0f} ms) {slot} AACH `{d["aach_kind"]}` · {extra}\n')
                f.write('\n')

            # DL signaling reactions
            cands = find_dl_responses(u['time'])
            if not cands:
                f.write('_Keine DL-Signaling-Reaktion im Fenster._\n\n')
                continue
            matches_count += 1
            f.write('**DL-Signaling-Reaktion(en):**\n\n')
            for d, t, dt in cands:
                slot = f"TN{d['tn']} FN{d['fn']:02d} MN{d['mn']:02d}"
                mac = '; '.join(_addr_label(m) for m in d['mac'][:1])
                llc = '; '.join(d['llc'][:1]) if d['llc'] else '—'
                mle = '; '.join(f"{m.get('disc', '?')}→{m.get('msg', '?')}" for m in d['mle'][:1]) if d['mle'] else '—'
                f.write(f'- DL #{d["idx"]} dl_t={t:.3f}s (Δ={dt*1000:+.0f} ms) {slot} · MAC: {mac} · LLC: {llc} · {mle}\n')
            f.write('\n')

        f.write(f'---\n\n_Gesamt: {matches_count}/{sum(1 for u in ul if u["crc"] != "SKIP")} dekodierte UL-Bursts mit ≥1 DL-Signaling-Reaktion im Fenster._\n')


def main():
    print('Parsing DL log...')
    dl = parse_dl()
    print(f'  {len(dl)} DL events')
    print('Parsing UL log...')
    ul = parse_ul()
    print(f'  {len(ul)} UL events ({sum(1 for u in ul if u["crc"]=="OK")} OK / '
          f'{sum(1 for u in ul if u["crc"]=="-")} CRC FAIL / '
          f'{sum(1 for u in ul if u["crc"]=="SKIP")} SKIP)')

    write_jsonl(OUT / 'dl_events.jsonl', dl)
    write_jsonl(OUT / 'ul_events.jsonl', ul)

    dl_time, anchor = build_dl_time(dl)
    last_t = dl_time(dl[-1]['idx']) if dl else 0
    first_t = dl_time(dl[anchor]['idx']) if dl else 0
    print(f'  DL anchor=idx{anchor}, time span {first_t:.3f}..{last_t:.3f} s')

    write_readme(dl, ul, dl_time)
    write_inventory(dl, ul)
    write_dl_full(dl, dl_time)
    write_ul_full(ul)
    build_action_reaction(dl, ul, dl_time)

    # cleanup: remove legacy MDs replaced by full versions
    for legacy in ('dl_signaling_chronological.md', 'ul_chronological.md', 'dl_unsolicited.md'):
        p = OUT / legacy
        if p.exists():
            p.unlink()
            print(f'  removed legacy {legacy}')

    print('Wrote:')
    for p in sorted(OUT.iterdir()):
        sz = p.stat().st_size
        print(f'  {p.name}  {sz:>10} bytes')


if __name__ == '__main__':
    main()
