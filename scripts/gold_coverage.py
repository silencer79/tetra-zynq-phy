#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gold_coverage.py — Werkzeug-Gate: Abdeckungsmatrix Bursttyp x Schicht.

Setzt `docs/spec_v2/17_LESSONS_LEARNED.md §5.3` (Regel V-17-14) um und liefert
den Abdeckungsnachweis, den `docs/spec_v2/14_VERIFICATION.md §3.6.4` fuer jede
Aufzeichnung verlangt, bevor sie als Abnahmemassstab dienen darf.

Kernidee
--------
Eine leere Zelle in einer Abdeckungsmatrix hat zwei voellig verschiedene
Bedeutungen:

  (a) Das Werkzeug KANN diese Kombination auswerten, hat aber nichts gefunden
      -> echter Nullbefund.
  (b) Das Werkzeug kann diese Kombination gar nicht auswerten
      -> KEIN Befund. Die Null sagt nichts ueber die Luft aus.

In V1 wurde (b) als (a) gelesen (Fehlerklasse F10.1). Dieses Skript trennt
beide Faelle, indem es fuer jede Zelle einen *Rundlauf-Nachweis* fuehrt:

  E1  Positivkontrolle aus den Daten  — die Zelle hat mindestens einen Treffer.
  E2  Rundlauf-Nachweis aus dem Quelltext — (i) der Decoder besitzt einen
      Aufrufpfad, der diesen Bursttyp/Block bis zu dieser Schicht fuehrt, UND
      (ii) der Aggregator transportiert dessen Ausgabe nachweislich in die
      Ereignisdatei. (ii) wird FUNKTIONAL geprueft: die vom Decoder erzeugte
      Ausgabezeile wird rekonstruiert und gegen die echten Suchmuster des
      Aggregators laufen gelassen.

Ohne E1 und ohne E2 ist die Zelle "unbekannt".

Nur die Bitebenen und Schichten, die die Ereignisdateien (`*_events.jsonl`)
tragen, koennen zaehlen — die Ereignisdatei ist laut Spezifikation die primaere
Schnittstelle, die Textdatei ist Ansichtssache.

Rueckgabewerte: 0 = keine unbekannte Zelle, 1 = mindestens eine unbekannte
Zelle (Aufzeichnung als Abnahmemassstab eingeschraenkt), 2 = Werkzeugfehler.
"""

import argparse
import ast
import json
import os
import re
import sys
import tempfile

EXIT_OK = 0
EXIT_VIOLATION = 1
EXIT_TOOL_ERROR = 2

# --------------------------------------------------------------------------
# Schichten (Spalten) — Bitebene bis oberste ausgewertete Schicht.
# Reihenfolge nach 14_VERIFICATION.md §3.6.2 Punkt 2.
# --------------------------------------------------------------------------
LAYERS = ['onair', 'descr', 'deint', 'info', 'mac', 'llc', 'mle', 'app']
LAYER_LABELS = {
    'onair': 'Sendebits',
    'descr': 'entschl.',
    'deint': 'deint.',
    'info':  'Infobits',
    'mac':   'MAC',
    'llc':   'LLC',
    'mle':   'MLE',
    'app':   'MM/CMCE/SDS',
}

STATE_HIT = 'belegt'
STATE_NULL = 'null'
STATE_UNKNOWN = 'unbekannt'
STATE_NA = 'nicht_zutreffend'

STATE_SYMBOL = {
    STATE_HIT: '',        # Zahl steht fuer sich
    STATE_NULL: '0*',
    STATE_UNKNOWN: '?',
    STATE_NA: '-',
}

# --------------------------------------------------------------------------
# Zeilen der Matrix: Bursttyp x Block.
# Der Block ist Teil der Zeilenkennung, weil 14_VERIFICATION.md §3.6.4 die
# Bloecke ausdruecklich getrennt fordert (ein Bursttyp traegt bis zu drei
# unabhaengige Bloecke, die der Decoder unterschiedlich behandelt).
#
# Feldschluessel:
#   file        'dl' | 'ul'  — welche Ereignisdatei
#   btype       Wert des Feldes "type" in der Ereignisdatei (None = alle)
#   region      Quelltext-Region des Decoders (siehe DL_REGIONS/UL_REGIONS)
#   mac_arg     Regex auf den Quelltext des ersten Arguments des
#               _print_mac()-Aufrufs, der diesen Block ausgibt
#   mac_tag     Ersatzwert fuer f-String-Platzhalter im MAC-Praefix
#   bits        Schicht -> Feldname in der Ereignisdatei (None = kein Feld)
#   dumpkey     Schicht -> Schluessel im ROUNDTRIP_DUMP (falls != Feldname)
#   top         oberste erwartete Schicht (14_VERIFICATION §3.6.4)
#   na_reason   ausgeschriebene Begruendung fuer die Schichten oberhalb `top`
# --------------------------------------------------------------------------

DL_REGIONS = [
    ('SB',         r"^\s*if btype == 'SB':"),
    ('NDB_COMMON', r"^\s*#\s*---\s*Normal Burst \(NDB1/NDB2\)\s*---"),
    ('NDB1',       r"^\s*if btype == 'NDB1':"),
    ('NDB2',       r"^\s*else:\s*#\s*btype == 'NDB2'"),
]
UL_REGIONS = [
    ('UL_ALL', r"^\s*def\s+\w*decode\w*\s*\(|^\s*#\s*ROUNDTRIP_DUMP"),
]

AACH_DEINT_NA = ("Zugriffszuweisungsblock ist blockcodiert (Reed-Muller 30/14) "
                 "und wird nicht interleavt - der Decoder fuehrt "
                 "entschleierte Bits direkt in rm3014_decode(), es gibt keine "
                 "Deinterleave-Stufe [CODE scripts/decode_dl.py]")
AACH_UPPER_NA = ("Zugriffszuweisungsblock traegt ein 14-bit-Infowort, keine "
                 "MAC-PDU-Kette; erwarteter Endpunkt laut 14_VERIFICATION "
                 "§3.6.4 = 'Infowort geparst'")
BSCH_UPPER_NA = ("Broadcast-Synchronisationsblock traegt die Sync-PDU, keine "
                 "MAC-PDU-Kette; erwarteter Endpunkt laut 14_VERIFICATION "
                 "§3.6.4 = 'Systeminformation geparst'")

ROWS = [
    dict(id='SB/BSCH', burst='Synchronisations-Burst', block='Broadcast-Sync-Block',
         file='dl', btype='SB', region='SB', mac_arg=None, mac_tag=None,
         bits={'onair': 'sb1_t5_onair_120b', 'descr': 'sb1_t4_descr_120b',
               'deint': 'sb1_t3_deint_120b', 'info': 'sb1_info_60b'},
         top='info', na_reason=BSCH_UPPER_NA,
         extra_field='cell',
         extra_note='Systeminformation aus dem Sync-Block geparst (Feld "cell")'),

    dict(id='SB/BKN2', burst='Synchronisations-Burst', block='Halbschlitzblock 2',
         file='dl', btype='SB', region='SB', mac_arg=r'^"\s+BKN2"$', mac_tag=None,
         bits={'onair': 'bkn2_onair_216b', 'descr': 'bkn2_descr_216b',
               'deint': 'bkn2_deint_216b', 'info': 'bkn2_info_124b'},
         top='app', na_reason=None),

    dict(id='SB/BB', burst='Synchronisations-Burst', block='Zugriffszuweisungsblock (AACH)',
         file='dl', btype='SB', region='SB', mac_arg=None, mac_tag=None,
         bits={'onair': 'bb_raw_30b', 'descr': 'bb_descr_30b',
               'deint': None, 'info': 'aach_info_14b'},
         deint_na=AACH_DEINT_NA,
         top='info', na_reason=AACH_UPPER_NA),

    dict(id='NDB1/SCH-F', burst='Normal-Burst, Vollschlitz', block='Vollschlitzblock (SCH/F)',
         file='dl', btype='NDB1', region='NDB1', mac_arg=r'^"\s+SCH/F"$', mac_tag=None,
         bits={'onair': 'type5_onair_432b', 'descr': 'descr_432b',
               'deint': 'deint_432b', 'info': 'info_268b'},
         top='app', na_reason=None),

    dict(id='NDB1/FACCH', burst='Normal-Burst mit Kanalstehlen', block='gestohlene Haelfte (SCH/HD-FACCH)',
         file='dl', btype='NDB1', region='NDB1',
         mac_arg=r'half_tag.*SCH/HD-FACCH', mac_tag='BKN1',
         bits={'onair': 'facch_onair_216b', 'descr': 'facch_descr_216b',
               'deint': 'facch_deint_216b', 'info': 'facch_info_124b'},
         top='app', na_reason=None),

    dict(id='NDB1/BB', burst='Normal-Burst, Vollschlitz', block='Zugriffszuweisungsblock (AACH)',
         file='dl', btype='NDB1', region='NDB_COMMON', mac_arg=None, mac_tag=None,
         bits={'onair': 'bb_raw_30b', 'descr': 'bb_descr_30b',
               'deint': None, 'info': 'aach_info_14b'},
         deint_na=AACH_DEINT_NA,
         top='info', na_reason=AACH_UPPER_NA),

    dict(id='NDB2/BKN1', burst='Normal-Burst, Halbschlitz', block='Halbschlitzblock 1 (SCH/HD)',
         file='dl', btype='NDB2', region='NDB2',
         mac_arg=r'^"\s+BKN1 SCH/HD"$', mac_tag='BKN1',
         bits={'onair': 'bkn1_onair_216b', 'descr': 'bkn1_descr_216b',
               'deint': 'bkn1_deint_216b', 'info': 'bkn1_info_124b'},
         top='app', na_reason=None),

    dict(id='NDB2/BKN2', burst='Normal-Burst, Halbschlitz', block='Halbschlitzblock 2 (SCH/HD)',
         file='dl', btype='NDB2', region='NDB2',
         mac_arg=r'bkn2_tag', mac_tag='BKN2 SCH/HD',
         bits={'onair': 'bkn2_onair_216b', 'descr': 'bkn2_descr_216b',
               'deint': 'bkn2_deint_216b', 'info': 'bkn2_info_124b'},
         top='app', na_reason=None),

    dict(id='NDB2/BB', burst='Normal-Burst, Halbschlitz', block='Zugriffszuweisungsblock (AACH)',
         file='dl', btype='NDB2', region='NDB_COMMON', mac_arg=None, mac_tag=None,
         bits={'onair': 'bb_raw_30b', 'descr': 'bb_descr_30b',
               'deint': None, 'info': 'aach_info_14b'},
         deint_na=AACH_DEINT_NA,
         top='info', na_reason=AACH_UPPER_NA),

    dict(id='UL/SCH-HU', burst='Uplink-Burst', block='Halbschlitz-Uplink (SCH/HU)',
         file='ul', btype=None, region='UL_ALL', mac_arg=None, mac_tag=None,
         bits={'onair': 'type5_onair_168b', 'descr': 'type4_descr_168b',
               'deint': 'type3_deint_168b', 'info': 'info_92b_dump'},
         dumpkey={'onair': 'type5_onair', 'descr': 'type4_descr',
                  'deint': 'type3_deint', 'info': 'info'},
         top='app', na_reason=None),
]


# ==========================================================================
# Quelltext-Analyse (Rundlauf-Nachweis E2, Teil i: Aufrufpfad im Decoder)
# ==========================================================================

class SourceModel(object):
    """AST-gestuetztes Modell einer Decoder-Quelldatei."""

    def __init__(self, path):
        self.path = path
        with open(path, encoding='utf-8') as fh:
            self.text = fh.read()
        self.lines = self.text.splitlines()
        self.tree = ast.parse(self.text, filename=path)
        self.calls = {}          # name -> [ast.Call]
        self.funcdefs = {}       # name -> ast.FunctionDef
        for node in ast.walk(self.tree):
            if isinstance(node, ast.Call):
                name = _call_name(node)
                if name:
                    self.calls.setdefault(name, []).append(node)
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.funcdefs.setdefault(node.name, node)

    def regions(self, spec):
        """Regionen als {name: (start_line, end_line)} (1-basiert, inklusive)."""
        marks = []
        for name, pattern in spec:
            rx = re.compile(pattern)
            hit = None
            for i, line in enumerate(self.lines, start=1):
                if rx.search(line):
                    hit = i
                    break
            if hit is not None:
                marks.append((hit, name))
        marks.sort()
        out = {}
        for k, (start, name) in enumerate(marks):
            end = marks[k + 1][0] - 1 if k + 1 < len(marks) else len(self.lines)
            out[name] = (start, end)
        return out

    def calls_in(self, name, lo, hi):
        return [c for c in self.calls.get(name, []) if lo <= c.lineno <= hi]

    def arg_source(self, node, index=0):
        if len(node.args) <= index:
            return None
        return ast.get_source_segment(self.text, node.args[index])

    def dump_keys(self, lo, hi):
        """Alle Schluessel, die im Bereich per ROUNDTRIP_DUMP ausgegeben werden."""
        keys = {}
        for call in self.calls.get('print', []):
            if not (lo <= call.lineno <= hi):
                continue
            text = _joined_literal(call.args[0] if call.args else None, tag='X')
            if not text or 'ROUNDTRIP_DUMP' not in text:
                continue
            m = re.search(r'(ROUNDTRIP_DUMP\S*)\s+(\w+)=', text)
            if m:
                keys[m.group(2)] = (m.group(1), call.lineno, text)
        return keys


def _call_name(node):
    fn = node.func
    if isinstance(fn, ast.Name):
        return fn.id
    if isinstance(fn, ast.Attribute):
        return fn.attr
    return None


def _joined_literal(node, tag='X'):
    """Literalen Text eines str/f-string rekonstruieren; Platzhalter -> tag."""
    if node is None:
        return None
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        out = []
        for part in node.values:
            if isinstance(part, ast.Constant) and isinstance(part.value, str):
                out.append(part.value)
            else:
                out.append(tag if tag is not None else '')
        return ''.join(out)
    return None


# ==========================================================================
# Aggregator-Vertrag (Rundlauf-Nachweis E2, Teil ii: Transport in die JSONL)
# ==========================================================================

class AggregatorModel(object):
    """Die echten Suchmuster des Aggregators, aus dem Quelltext gezogen.

    Es wird NICHT importiert (das Modul wertet beim Import argparse aus),
    sondern der AST nach `NAME = re.compile(r'...')` durchsucht. Die so
    gewonnenen Muster werden anschliessend funktional gegen rekonstruierte
    Decoder-Ausgabezeilen laufen gelassen.
    """

    def __init__(self, path):
        self.path = path
        with open(path, encoding='utf-8') as fh:
            self.text = fh.read()
        tree = ast.parse(self.text, filename=path)
        self.patterns = {}
        for node in ast.walk(tree):
            if not isinstance(node, ast.Assign) or len(node.targets) != 1:
                continue
            tgt = node.targets[0]
            if not isinstance(tgt, ast.Name):
                continue
            val = node.value
            if not (isinstance(val, ast.Call) and _call_name(val) == 'compile'):
                continue
            pat = _concat_str_constants(val.args[0] if val.args else None)
            if pat is None:
                continue
            try:
                self.patterns[tgt.id] = re.compile(pat)
            except re.error:
                pass

    def has(self, name):
        return name in self.patterns

    def matches(self, name, line):
        rx = self.patterns.get(name)
        if rx is None:
            return None          # Muster existiert nicht -> nicht entscheidbar
        return bool(rx.match(line))

    def stores_field(self, field):
        """Kommt der Feldname im Aggregator ueberhaupt als Ziel vor?"""
        return ("'%s'" % field) in self.text or ('"%s"' % field) in self.text


def _concat_str_constants(node):
    """String-Literale (auch implizit konkateniert) einsammeln."""
    if node is None:
        return None
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = _concat_str_constants(node.left)
        right = _concat_str_constants(node.right)
        if left is not None and right is not None:
            return left + right
    return None


# ==========================================================================
# Rundlauf-Nachweis je Zeile/Schicht
# ==========================================================================

# Musternamen des Aggregators, die eine MAC-Zeile aufnehmen koennen.
AGG_MAC_PATTERNS = ['SCHF_MAC', 'SCHHD_MAC', 'BKN_BCAST']
# Rumpfvarianten, wie _print_mac() sie erzeugt (prefix + zwei Leerzeichen + Rumpf).
MAC_BODIES = [
    '  MAC-RESOURCE  addr=SSI ID=2633716 LI=21 (21 octets)',
    '  MAC-BROADCAST  sub=SYSINFO',
]


class RoundtripProbe(object):
    """Ermittelt fuer jede Zeile/Schicht, ob das Werkzeug sie fuehren KANN."""

    def __init__(self, dl_src, ul_src, agg):
        self.dl = dl_src
        self.ul = ul_src
        self.agg = agg
        self.dl_regions = dl_src.regions(DL_REGIONS) if dl_src else {}
        self.ul_regions = ul_src.regions(UL_REGIONS) if ul_src else {}

    def _src_for(self, row):
        return self.dl if row['file'] == 'dl' else self.ul

    def _region_for(self, row):
        table = self.dl_regions if row['file'] == 'dl' else self.ul_regions
        return table.get(row['region'])

    # ---------------- Bitebenen -------------------------------------------
    def bit_layer(self, row, layer):
        """(kann, begruendung) fuer eine Bitebene."""
        field = row.get('bits', {}).get(layer)
        if field is None:
            return False, ('die Ereignisdatei hat fuer diese Ebene kein Feld - '
                           'der Decoder gibt sie nicht aus')
        src = self._src_for(row)
        region = self._region_for(row)
        if src is None or region is None:
            return False, 'Decoder-Quelltext oder Region nicht auffindbar'
        dumpkey = row.get('dumpkey', {}).get(layer, field)
        keys = src.dump_keys(region[0], region[1])
        if dumpkey not in keys:
            return False, ('kein ROUNDTRIP_DUMP fuer "%s" in der Decoder-Region %s '
                           '(%s:%d-%d)' % (dumpkey, row['region'],
                                           os.path.basename(src.path),
                                           region[0], region[1]))
        marker, lineno, _text = keys[dumpkey]
        sample = '  %s %s=0101' % (marker, dumpkey)
        pat = 'UL_HU_DUMP' if row['file'] == 'ul' else 'RAW_LINE'
        ok = self.agg.matches(pat, sample)
        if ok is None:
            return False, 'Aggregator hat kein Muster %s' % pat
        if not ok:
            return False, ('Aggregator-Muster %s erkennt die Decoder-Zeile "%s" nicht'
                           % (pat, sample.strip()))
        if not self.agg.stores_field(field):
            return False, ('Aggregator legt das Feld "%s" nicht in der '
                           'Ereignisdatei ab' % field)
        return True, ('Dump "%s" in %s:%d, Aggregatormuster %s greift, Feld "%s" '
                      'wird abgelegt' % (dumpkey, os.path.basename(src.path),
                                         lineno, pat, field))

    # ---------------- MAC und darueber ------------------------------------
    def _mac_call(self, row):
        """Den _print_mac()-Aufruf dieses Blocks finden."""
        src = self._src_for(row)
        region = self._region_for(row)
        if src is None or region is None or not row.get('mac_arg'):
            return None
        rx = re.compile(row['mac_arg'])
        for call in src.calls_in('_print_mac', region[0], region[1]):
            arg = src.arg_source(call) or ''
            if rx.search(arg.strip()):
                return call
        return None

    def _sub_region(self, row, mac_call):
        """Zeilenbereich des Blocks: bis zum naechsten _print_mac der Region."""
        src = self._src_for(row)
        lo, hi = self._region_for(row)
        following = [c.lineno for c in src.calls_in('_print_mac', lo, hi)
                     if c.lineno > mac_call.lineno]
        end = (min(following) - 1) if following else hi
        return mac_call.lineno, end

    def _effective_lines(self, row, lo, hi):
        """Blockbereich plus Rumpf lokaler Hilfsfunktionen, die er aufruft."""
        src = self._src_for(row)
        ranges = [(lo, hi)]
        stack_tag = None
        for helper in ('_parse_full_stack',):
            for call in src.calls_in(helper, lo, hi):
                fn = src.funcdefs.get(helper)
                if fn is not None:
                    ranges.append((fn.lineno, getattr(fn, 'end_lineno', fn.lineno)))
                arg = src.arg_source(call)
                if arg:
                    stack_tag = arg.strip().strip('"\'')
        return ranges, stack_tag

    def _calls_in_ranges(self, src, name, ranges):
        out = []
        for lo, hi in ranges:
            out.extend(src.calls_in(name, lo, hi))
        return out

    def mac(self, row):
        src = self._src_for(row)
        if row['file'] == 'ul':
            return self._ul_upper(row, 'mac')
        call = self._mac_call(row)
        if call is None:
            return False, ('kein _print_mac()-Aufruf fuer diesen Block in der '
                           'Decoder-Region %s' % row['region'])
        prefix = _joined_literal(call.args[0], tag=row.get('mac_tag') or 'X')
        if prefix is None:
            return False, 'MAC-Praefix nicht rekonstruierbar'
        tried = []
        for body in MAC_BODIES:
            line = prefix + body
            tried.append(line)
            for pat in AGG_MAC_PATTERNS:
                if self.agg.matches(pat, line):
                    return True, ('Decoder gibt "%s" aus (%s:%d), Aggregatormuster '
                                  '%s greift' % (line.strip(),
                                                 os.path.basename(src.path),
                                                 call.lineno, pat))
        return False, ('Decoder gibt "%s" aus (%s:%d), aber KEIN Aggregatormuster '
                       '(%s) erkennt diese Zeile' %
                       (tried[0].strip(), os.path.basename(src.path), call.lineno,
                        ', '.join(AGG_MAC_PATTERNS)))

    def upper(self, row, layer):
        """layer in {'llc','mle','app'}."""
        if row['file'] == 'ul':
            return self._ul_upper(row, layer)
        src = self._src_for(row)
        call = self._mac_call(row)
        if call is None:
            return False, ('kein _print_mac()-Aufruf fuer diesen Block - der '
                           'Decoder erreicht schon die MAC-Schicht nicht '
                           'nachweisbar')
        lo, hi = self._sub_region(row, call)
        ranges, stack_tag = self._effective_lines(row, lo, hi)

        if layer == 'llc':
            parse_name, print_name, pattern = 'parse_llc', '_print_llc', 'LLC_LINE'
        elif layer == 'mle':
            parse_name, print_name, pattern = 'parse_mle', '_print_mle', 'MLE_LINE'
        else:
            # Die Anwendungs-PDU wird vom Decoder IN der MLE-Zeile ausgegeben
            # ("disc=MM -> D-LOC-UPD-ACCEPT"); ein eigener Ausgabepfad
            # existiert nicht. Der Nachweis ist daher: MLE-Pfad vorhanden UND
            # ein Anwendungs-Parser wird aufgerufen.
            ok_mle, why_mle = self.upper(row, 'mle')
            if not ok_mle:
                return False, 'setzt den MLE-Pfad voraus: ' + why_mle
            app_calls = []
            for nm in ('parse_mle', 'parse_direct_mm'):
                app_calls.extend(self._calls_in_ranges(src, nm, ranges))
            if not app_calls:
                return False, 'kein Aufruf eines Anwendungs-Parsers im Blockbereich'
            return True, ('Anwendungs-PDU faehrt in der MLE-Zeile mit; '
                          'MLE-Pfad nachgewiesen und Anwendungs-Parser '
                          'aufgerufen (%s:%d)' % (os.path.basename(src.path),
                                                  app_calls[0].lineno))

        parse_calls = self._calls_in_ranges(src, parse_name, ranges)
        if not parse_calls:
            return False, ('der Decoder ruft %s() fuer diesen Block nicht auf '
                           '(%s:%d-%d)' % (parse_name, os.path.basename(src.path),
                                           lo, hi))
        print_calls = self._calls_in_ranges(src, print_name, ranges)
        if not print_calls:
            return False, ('%s() wird aufgerufen, aber es gibt keinen %s()-Aufruf, '
                           'der die Ausgabezeile erzeugt' % (parse_name, print_name))
        pc = print_calls[0]
        prefix = _joined_literal(pc.args[0], tag=stack_tag or row.get('mac_tag') or 'X')
        if prefix is None:
            return False, 'Ausgabepraefix nicht rekonstruierbar'
        body = '  BL-UDATA' if layer == 'llc' else '  disc=MM -> D-LOC-UPD-ACCEPT'
        line = prefix + body
        ok = self.agg.matches(pattern, line)
        if ok is None:
            return False, 'Aggregator hat kein Muster %s' % pattern
        if not ok:
            return False, ('der Decoder ruft %s() zwar auf und gibt "%s" aus '
                           '(%s:%d), aber das Aggregatormuster %s erkennt diese '
                           'Zeile nicht - die Schicht kommt nie in der '
                           'Ereignisdatei an'
                           % (parse_name, line.strip(),
                              os.path.basename(src.path), pc.lineno, pattern))
        return True, ('%s() aufgerufen (%s:%d), Ausgabe "%s", Aggregatormuster %s '
                      'greift' % (parse_name, os.path.basename(src.path),
                                  parse_calls[0].lineno, line.strip(), pattern))

    def _ul_upper(self, row, layer):
        """Uplink: die oberen Schichten reisen als strukturiertes dict
        (`parsed={...}`) in die Ereignisdatei, nicht als Textzeile."""
        src = self.ul
        if src is None:
            return False, 'decode_ul.py nicht auffindbar'
        names = {'mac': ('parse_mac_pdu_ul', 'parse_ul_mac', 'parse_mac_pdu'),
                 'llc': ('parse_llc',),
                 'mle': ('parse_ul_mle', 'parse_mle'),
                 'app': ('parse_ul_mle', 'parse_ul_direct_mm', 'parse_direct_mm')}[layer]
        found = None
        for nm in names:
            if src.calls.get(nm):
                found = (nm, src.calls[nm][0].lineno)
                break
        if found is None and layer == 'mac':
            # MAC-Kopffelder werden im UL-Decoder inline aus den Bits gezogen;
            # Nachweis ueber die Ausgabe der geparsten Struktur.
            found = ('inline', 0)
        if found is None:
            return False, ('der Uplink-Decoder ruft keinen Parser fuer diese '
                           'Schicht auf (gesucht: %s)' % ', '.join(names))
        sample = "      parsed={'llc': {'llc_type': 1}}"
        ok = self.agg.matches('UL_PARSED', sample)
        if ok is None:
            return False, 'Aggregator hat kein Muster UL_PARSED'
        if not ok:
            return False, ('Aggregatormuster UL_PARSED erkennt die Decoder-Zeile '
                           '"%s" nicht' % sample.strip())
        return True, ('Parser %s (%s:%s) und Transport ueber parsed={...} '
                      '(Aggregatormuster UL_PARSED) nachgewiesen'
                      % (found[0], os.path.basename(src.path), found[1]))


# ==========================================================================
# Zaehlung aus den Ereignisdateien
# ==========================================================================

def load_events(path):
    events = []
    with open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError as exc:
                raise ValueError('%s:%d ist kein gueltiges JSON: %s'
                                 % (path, lineno, exc))
    return events


def _nonempty(value):
    return value not in (None, '', [], {})


def _mac_entries(row, ev):
    """MAC-Eintraege der Ereignis-Zeile, die zu diesem Block gehoeren."""
    out = []
    for m in ev.get('mac') or []:
        bkn = m.get('bkn')
        bkn = str(bkn) if bkn is not None else None
        fmt = m.get('fmt')
        rid = row['id']
        if rid == 'SB/BKN2' and bkn == '2':
            out.append(m)
        elif rid == 'NDB1/SCH-F' and fmt == 'SCH/F':
            out.append(m)
        elif rid == 'NDB1/FACCH' and fmt == 'SCH/HD-FACCH':
            out.append(m)
        elif rid == 'NDB2/BKN1' and fmt == 'SCH/HD' and bkn == '1':
            out.append(m)
        elif rid == 'NDB2/BKN2' and bkn == '2' and fmt in ('SCH/HD', 'BCAST'):
            out.append(m)
    return out


def count_cells(row, events):
    """Zaehlt je Schicht die Bursts, die sie erreicht haben."""
    sel = [e for e in events
           if row['btype'] is None or e.get('type') == row['btype']]
    counts = dict((layer, 0) for layer in LAYERS)
    counts['_bursts'] = len(sel)

    for layer in ('onair', 'descr', 'deint', 'info'):
        field = row.get('bits', {}).get(layer)
        if not field:
            continue
        counts[layer] = sum(1 for e in sel if _nonempty(e.get(field)))

    if row['file'] == 'ul':
        for e in sel:
            p = e.get('parsed')
            if not isinstance(p, dict):
                continue
            if 'pdu_type' in p or 'addr_type' in p:
                counts['mac'] += 1
            llc = p.get('llc')
            if isinstance(llc, dict) and llc:
                counts['llc'] += 1
            mle = p.get('mle')
            if isinstance(mle, dict) and mle:
                counts['mle'] += 1
            app = False
            if isinstance(mle, dict):
                app = any(k in mle for k in ('mm_name', 'cmce_name', 'sds_name'))
            dmm = p.get('direct_mm')
            if isinstance(dmm, dict) and dmm.get('mm_name'):
                app = True
            if app:
                counts['app'] += 1
        return counts

    unattributed_llc = 0
    for e in sel:
        macs = _mac_entries(row, e)
        counts['mac'] += len(macs)
        if not macs:
            if _nonempty(e.get('llc')):
                unattributed_llc += 1
            continue
        if _nonempty(e.get('llc')):
            counts['llc'] += 1
        mles = e.get('mle') or []
        if mles:
            counts['mle'] += 1
            if any((m.get('disc') or 'MLE') != 'MLE' for m in mles):
                counts['app'] += 1
        if _nonempty(e.get('cmce')) or _nonempty(e.get('mm')):
            counts['app'] = max(counts['app'], 1)
    counts['_unattributed_llc'] = unattributed_llc
    return counts


# ==========================================================================
# Matrixaufbau und Bewertung
# ==========================================================================

def build_matrix(rows, recording, probe, files):
    """files: {'dl': [events], 'ul': [events]}"""
    result = []
    for row in rows:
        events = files.get(row['file']) or []
        counts = count_cells(row, events)
        top_index = LAYERS.index(row['top'])
        cells = {}
        for idx, layer in enumerate(LAYERS):
            # 1) nicht zutreffend?
            if layer == 'deint' and row.get('deint_na'):
                cells[layer] = dict(count=0, state=STATE_NA, reason=row['deint_na'])
                continue
            if idx > top_index:
                cells[layer] = dict(count=0, state=STATE_NA,
                                    reason=row.get('na_reason') or
                                    'oberhalb des erwarteten Endpunkts')
                continue
            n = counts.get(layer, 0)
            if n > 0:
                cells[layer] = dict(count=n, state=STATE_HIT,
                                    reason='Positivkontrolle: %d Treffer in dieser '
                                           'Aufzeichnung' % n)
                continue
            # 2) kein Treffer -> Rundlauf aus dem Quelltext?
            if layer in ('onair', 'descr', 'deint', 'info'):
                ok, why = probe.bit_layer(row, layer)
            elif layer == 'mac':
                ok, why = probe.mac(row)
            else:
                ok, why = probe.upper(row, layer)
            cells[layer] = dict(count=0,
                                state=STATE_NULL if ok else STATE_UNKNOWN,
                                reason=why)

        # Fortpflanzung nach oben: erreicht schon die MAC-Zeile dieses Blocks
        # die Ereignisdatei nicht, dann ist keine daruberliegende Schicht dem
        # Block zuordenbar - ihr Nullwert ist dann ebenfalls kein Befund.
        mac_cell = cells.get('mac')
        if mac_cell and mac_cell['state'] == STATE_UNKNOWN:
            for layer in ('llc', 'mle', 'app'):
                c = cells.get(layer)
                if c and c['state'] in (STATE_NULL, STATE_HIT):
                    c['state'] = STATE_UNKNOWN
                    c['reason'] = ('die MAC-Zeile dieses Blocks erreicht die '
                                   'Ereignisdatei nicht, deshalb ist ihm keine '
                                   'obere Schicht zuordenbar - Ursache: %s'
                                   % mac_cell['reason'])
        result.append(dict(row=row, counts=counts, cells=cells))
    return result


# ==========================================================================
# Ausgabe
# ==========================================================================

HEADLINE_EXPLAIN = (
    "Lesehilfe fuer alle, die die Vorgeschichte nicht kennen:\n"
    "  Eine leere Zelle kann zweierlei heissen. Entweder das Werkzeug haette\n"
    "  etwas finden koennen und es kam nichts vor - das ist ein Befund. Oder\n"
    "  das Werkzeug konnte an dieser Stelle gar nichts finden, weil es den\n"
    "  Bursttyp nie bis zu dieser Schicht fuehrt - dann ist die Null KEIN\n"
    "  Befund, sondern eine Luecke im Werkzeug. In V1 wurde genau das\n"
    "  verwechselt: PDUs, die nachweislich auf der Luft waren, galten als\n"
    "  abwesend, weil der Referenz-Decoder sie nie ausgewertet hat.\n"
    "  Zellen mit '?' unten sind solche Luecken. Aus ihnen darf keine\n"
    "  Abwesenheit abgeleitet werden."
)


def render_text(recording, matrix, notes, unknown):
    out = []
    w = out.append
    total = sum(len(m['cells']) for m in matrix)
    w('=' * 78)
    w('WERKZEUG-GATE  Abdeckung Bursttyp x Schicht')
    w('Regel V-17-14 (17_LESSONS_LEARNED.md §5.3, 14_VERIFICATION.md §3.6.4)')
    w('Aufzeichnung: %s' % recording)
    w('=' * 78)
    if unknown:
        w('KERNAUSSAGE: %d von %d Zellen sind UNBEKANNT.' % (len(unknown), total))
        w('Fuer diese Zellen ist ein Nullbefund KEIN Befund. Die Aufzeichnung')
        w('taugt an diesen Stellen nicht als Abnahmemassstab.')
    else:
        w('KERNAUSSAGE: keine unbekannte Zelle - jede Zelle ist entweder belegt')
        w('oder als echter Nullbefund nachgewiesen.')
    w('')
    w(HEADLINE_EXPLAIN)
    w('')
    w('Legende: Zahl = Bursts, die die Schicht erreicht haben')
    w('         0*   = echter Nullbefund (Rundlauf nachgewiesen, nichts gefunden)')
    w('         ?    = UNBEKANNT (kein Rundlauf-Nachweis, Null sagt nichts aus)')
    w('         -    = nicht zutreffend (mit Begruendung, siehe unten)')
    w('')

    idw = max([len(m['row']['id']) for m in matrix] + [len('Bursttyp/Block')])
    colw = 11
    head = 'Bursttyp/Block'.ljust(idw) + ' | ' + ' | '.join(
        LAYER_LABELS[l].rjust(colw) for l in LAYERS)
    w(head)
    w('-' * len(head))
    for m in matrix:
        cells = []
        for layer in LAYERS:
            c = m['cells'][layer]
            if c['state'] == STATE_HIT:
                cells.append(str(c['count']).rjust(colw))
            else:
                cells.append(STATE_SYMBOL[c['state']].rjust(colw))
        w(m['row']['id'].ljust(idw) + ' | ' + ' | '.join(cells))
    w('-' * len(head))
    w('')

    if unknown:
        w('UNBEKANNTE ZELLEN - hier ist ein Nullbefund kein Befund:')
        for row_id, layer, reason in unknown:
            w('  [%s x %s]' % (row_id, LAYER_LABELS[layer]))
            w('      %s' % reason)
        w('')

    na = [(m['row']['id'], l, m['cells'][l]['reason'])
          for m in matrix for l in LAYERS if m['cells'][l]['state'] == STATE_NA]
    if na:
        w('NICHT ZUTREFFENDE ZELLEN (Begruendung geprueft und ausgeschrieben):')
        seen = set()
        for row_id, layer, reason in na:
            key = (row_id, reason)
            if key in seen:
                continue
            seen.add(key)
            w('  [%s] %s' % (row_id, reason))
        w('')

    nulls = [(m['row']['id'], l, m['cells'][l]['reason'])
             for m in matrix for l in LAYERS if m['cells'][l]['state'] == STATE_NULL]
    if nulls:
        w('ECHTE NULLBEFUNDE (Rundlauf nachgewiesen, in dieser Aufzeichnung leer):')
        for row_id, layer, reason in nulls:
            w('  [%s x %s] %s' % (row_id, LAYER_LABELS[layer], reason))
        w('')

    if notes:
        w('ZUSATZBEFUNDE:')
        for n in notes:
            w('  - %s' % n)
        w('')
    return '\n'.join(out)


# ==========================================================================
# Hauptlauf
# ==========================================================================

def analyse(recording, tools_dir, rows=None):
    rows = rows if rows is not None else ROWS
    dl_path = os.path.join(recording, 'dl_events.jsonl')
    ul_path = os.path.join(recording, 'ul_events.jsonl')
    files = {}
    missing = []
    for key, path in (('dl', dl_path), ('ul', ul_path)):
        if os.path.exists(path):
            files[key] = load_events(path)
        else:
            files[key] = []
            missing.append(path)

    dl_src_path = os.path.join(tools_dir, 'decode_dl.py')
    ul_src_path = os.path.join(tools_dir, 'decode_ul.py')
    agg_path = os.path.join(tools_dir, 'parse_reference_decode.py')
    for p in (dl_src_path, ul_src_path, agg_path):
        if not os.path.exists(p):
            raise IOError('Werkzeugquelle fehlt: %s' % p)

    dl_src = SourceModel(dl_src_path)
    ul_src = SourceModel(ul_src_path)
    agg = AggregatorModel(agg_path)
    probe = RoundtripProbe(dl_src, ul_src, agg)

    matrix = build_matrix(rows, recording, probe, files)

    unknown = []
    for m in matrix:
        for layer in LAYERS:
            c = m['cells'][layer]
            if c['state'] == STATE_UNKNOWN:
                unknown.append((m['row']['id'], layer, c['reason']))

    notes = []
    for p in missing:
        notes.append('Ereignisdatei fehlt: %s - alle Zeilen dieser Richtung '
                     'zaehlen 0' % p)
    # Nicht zuordenbare LLC-Zeilen: je Bursttyp einmal, ueber ALLE Bloecke
    # dieses Bursttyps gerechnet (der Aggregator fuehrt LLC/MLE in flachen
    # Listen ohne Blockbezug).
    for btype in sorted({r['btype'] for r in rows
                         if r['file'] == 'dl' and r['btype']}):
        brows = [r for r in rows if r['file'] == 'dl' and r['btype'] == btype
                 and r.get('mac_arg')]
        if not brows:
            continue
        n = 0
        for e in (files.get('dl') or []):
            if e.get('type') != btype or not _nonempty(e.get('llc')):
                continue
            if not any(_mac_entries(r, e) for r in brows):
                n += 1
        if n:
            notes.append('Bursttyp %s: %d Bursts tragen eine LLC-Zeile, die keinem '
                         'Block zugeordnet werden konnte - der Aggregator fuehrt '
                         'LLC/MLE in flachen Listen ohne Blockbezug' % (btype, n))
    dl_events = files.get('dl') or []
    if dl_events:
        n_cmce = sum(1 for e in dl_events if _nonempty(e.get('cmce')))
        n_mm = sum(1 for e in dl_events if _nonempty(e.get('mm')))
        if n_cmce == 0 and n_mm == 0:
            notes.append('Die Felder "cmce" und "mm" der Downlink-Ereignisdatei sind '
                         'ueber alle %d Bursts leer; die Anwendungs-PDU steht nur als '
                         'Text in der MLE-Zeile. Die Spalte MM/CMCE/SDS wird deshalb '
                         'aus dem MLE-Diskriminator abgeleitet.' % len(dl_events))
    for m in matrix:
        extra = m['row'].get('extra_field')
        if extra:
            evs = files.get(m['row']['file']) or []
            sel = [e for e in evs if m['row']['btype'] is None
                   or e.get('type') == m['row']['btype']]
            n = sum(1 for e in sel if _nonempty(e.get(extra)))
            notes.append('%s: %s - %d Treffer'
                         % (m['row']['id'], m['row']['extra_note'], n))

    return matrix, unknown, notes


def to_json(recording, matrix, unknown, notes, exit_code):
    return dict(
        tool='gold_coverage',
        spec='17_LESSONS_LEARNED.md §5.3 / V-17-14; 14_VERIFICATION.md §3.6.4',
        recording=recording,
        exit_code=exit_code,
        headline=('%d von %d Zellen unbekannt - dort ist ein Nullbefund kein '
                  'Befund' % (len(unknown), sum(len(m['cells']) for m in matrix)))
        if unknown else 'keine unbekannte Zelle',
        layers=LAYERS,
        unknown_cells=[dict(row=r, layer=l, reason=w) for r, l, w in unknown],
        notes=notes,
        matrix=[dict(
            id=m['row']['id'],
            burst_type=m['row']['burst'],
            block=m['row']['block'],
            bursts=m['counts'].get('_bursts', 0),
            cells=dict((l, dict(count=m['cells'][l]['count'],
                                state=m['cells'][l]['state'],
                                reason=m['cells'][l]['reason']))
                       for l in LAYERS),
        ) for m in matrix],
    )


# ==========================================================================
# Selbsttest
# ==========================================================================

def _dump_block(rows, region, marker, indent):
    """Erzeugt fuer eine Decoder-Region alle ROUNDTRIP_DUMP-Zeilen aus ROWS."""
    keys = []
    for row in rows:
        if row['region'] != region:
            continue
        for layer in ('onair', 'descr', 'deint', 'info'):
            if layer == 'deint' and row.get('deint_na'):
                continue
            field = row['bits'].get(layer)
            if not field:
                continue
            key = row.get('dumpkey', {}).get(layer, field)
            if key not in keys:
                keys.append(key)
    pad = ' ' * indent
    if not keys:
        return pad + 'pass'
    return '\n'.join('%sprint(f"  %s %s={v}", flush=True)' % (pad, marker, k)
                     for k in keys)


def _fake_dl(rows, good_prefix=True, sb_bkn2_full=True):
    """Kuenstlicher Downlink-Decoder mit denselben Quelltext-Idiomen wie der echte.

    good_prefix=False   bildet den V1-Fehler F10.1 (b) nach: der Decoder wertet
                        die oberen Schichten zwar aus, gibt sie aber mit einem
                        Praefix aus, das der Aggregator nicht erkennt.
    sb_bkn2_full=False  bildet den V1-Fehler F10.1 (a) nach: der Decoder ruft
                        die oberen Schichten fuer den Halbschlitzblock des
                        Synchronisations-Bursts gar nicht erst auf.
    """
    llc_pref = '"    LLC"' if good_prefix else 'f"    {prefix.strip()} LLC"'
    mle_pref = '"    MLE"' if good_prefix else 'f"    {prefix.strip()} MLE"'
    if sb_bkn2_full:
        sb_bkn2_dump = _dump_block(
            [r for r in rows if r['id'] == 'SB/BKN2'], 'SB', 'ROUNDTRIP_DUMP_SB', 16)
        sb_bkn2_stack = ('            llc = parse_llc(bkn2_info, pstart)\n'
                         '            _print_llc("    LLC", llc)\n'
                         '            mle = parse_mle(bkn2_info, llc_start)\n'
                         '            _print_mle("    MLE", mle)')
    else:
        sb_bkn2_dump = '                pass'
        sb_bkn2_stack = '            pass'

    sb_bsch_dump = _dump_block(
        [r for r in rows if r['id'] == 'SB/BSCH'], 'SB', 'ROUNDTRIP_DUMP_SB', 16)
    aach_dump = _dump_block(
        [r for r in rows if r['id'] == 'SB/BB'], 'SB', 'ROUNDTRIP_DUMP_AACH', 16)
    ndb_aach_dump = _dump_block(
        rows, 'NDB_COMMON', 'ROUNDTRIP_DUMP_AACH', 16)
    ndb1_dump = _dump_block(rows, 'NDB1', 'ROUNDTRIP_DUMP', 20)
    ndb2_dump = _dump_block(rows, 'NDB2', 'ROUNDTRIP_DUMP_HD', 20)

    return '''# kuenstlicher Decoder fuer den Selbsttest
def decode(bursts):
    for idx, btype in bursts:
        if btype == 'SB':
            if _dump_this(idx):
%(SB_BSCH_DUMP)s
            if _dump_this(idx):
%(AACH_DUMP)s
            if _dump_this(idx):
%(SB_BKN2_DUMP)s
            mac = parse_mac_pdu(bkn2_info, 124)
            _print_mac("  BKN2", mac, bkn2_info, verbose)
%(SB_BKN2_STACK)s
        else:
            # --- Normal Burst (NDB1/NDB2) ---
            if _dump_this(idx):
%(NDB_AACH_DUMP)s
            if btype == 'NDB1':
                if _dump_this(idx):
%(NDB1_DUMP)s
                mac = parse_mac_pdu(info_bits, 268)
                _print_mac("  SCH/F", mac, info_bits, verbose)
                llc = parse_llc(info_bits, pstart)
                _print_llc("    LLC", llc)
                mle = parse_mle(info_bits, llc_start)
                _print_mle("    MLE", mle)
                half_tag = "BKN1"
                _print_mac(f"  {half_tag} SCH/HD-FACCH", mac, info_bits, verbose)
                llc = parse_llc(info_bits, pstart)
                _print_llc("    LLC", llc)
                mle = parse_mle(info_bits, llc_start)
                _print_mle("    MLE", mle)
            else:  # btype == 'NDB2' -> NDB_SF
                if _dump_this(idx):
%(NDB2_DUMP)s

                def _parse_full_stack(prefix, mac, info_bits):
                    llc = parse_llc(info_bits, pstart)
                    _print_llc(%(LLC_PREFIX)s, llc)
                    mle = parse_mle(info_bits, llc_start)
                    _print_mle(%(MLE_PREFIX)s, mle)

                _print_mac("  BKN1 SCH/HD", mac1, info1, verbose)
                _parse_full_stack("BKN1", mac1, info1)
                bkn2_tag = "BKN2 SCH/HD"
                _print_mac(f"  {bkn2_tag}", mac2, info2, verbose)
                _parse_full_stack("BKN2", mac2, info2)
''' % dict(SB_BSCH_DUMP=sb_bsch_dump, AACH_DUMP=aach_dump,
           SB_BKN2_DUMP=sb_bkn2_dump, SB_BKN2_STACK=sb_bkn2_stack,
           NDB_AACH_DUMP=ndb_aach_dump, NDB1_DUMP=ndb1_dump, NDB2_DUMP=ndb2_dump,
           LLC_PREFIX=llc_pref, MLE_PREFIX=mle_pref)


def _fake_ul(rows):
    dump = _dump_block(rows, 'UL_ALL', 'ROUNDTRIP_DUMP_HU', 8)
    return '''# kuenstlicher Uplink-Decoder fuer den Selbsttest
def parse_ul_mle(bits, pos):
    return {}

def parse_ul_direct_mm(bits, pos):
    return {}

def decode_ul(bursts):
    for idx in bursts:
%(DUMP)s
        llc = parse_llc(b, pos)
        mle = parse_ul_mle(b, p)
        print(f'      parsed={parsed}')
''' % dict(DUMP=dump)


def _fake_agg(real_agg, rows):
    """Aggregator des Selbsttests: die ECHTEN Suchmuster (sie sind der Vertrag),
    ergaenzt um die Feldnamen, die ein vollstaendiger Aggregator ablegen wuerde."""
    fields = sorted({f for r in rows for f in r['bits'].values() if f})
    tail = ('\n\n# --- Selbsttest: Felder eines vollstaendigen Aggregators ---\n'
            'SELFTEST_FIELDS = %r\n' % (fields,))
    return real_agg + tail


def _fake_events(rows, with_upper):
    """Kuenstliche Ereignisdateien. with_upper=False -> obere Schichten leer."""
    def bits_for(btype):
        out = {}
        for row in rows:
            if row['file'] != 'dl' or row['btype'] != btype:
                continue
            for layer in ('onair', 'descr', 'deint', 'info'):
                if layer == 'deint' and row.get('deint_na'):
                    continue
                field = row['bits'].get(layer)
                if field:
                    out[field] = '0' * 16
        return out

    dl = []
    sb = dict(type='SB', cell={'mcc': 262},
              mac=[{'fmt': 'BCAST', 'bkn': '2', 'sub': 'SYSINFO'}],
              llc=[], mle=[], cmce=[], mm=[])
    sb.update(bits_for('SB'))
    if with_upper:
        sb['llc'] = ['BL-UDATA']
        sb['mle'] = [{'disc': 'MM', 'msg': '-> D-LOC-UPD-ACCEPT'}]
    dl.append(sb)

    ndb1 = dict(type='NDB1', mac=[{'fmt': 'SCH/F', 'pdu': 'MAC-RESOURCE'}],
                llc=['BL-ADATA'],
                mle=[{'disc': 'MM', 'msg': '-> D-LOC-UPD-ACCEPT'}],
                cmce=[], mm=[])
    ndb1.update(bits_for('NDB1'))
    dl.append(ndb1)

    facch = dict(type='NDB1', mac=[{'fmt': 'SCH/HD-FACCH', 'pdu': 'MAC-RESOURCE'}],
                 llc=['BL-ADATA'],
                 mle=[{'disc': 'CMCE', 'msg': '-> D-TX-CEASED'}],
                 cmce=[], mm=[])
    facch.update(bits_for('NDB1'))
    dl.append(facch)

    ndb2 = dict(type='NDB2',
                mac=[{'fmt': 'SCH/HD', 'bkn': 1, 'pdu': 'MAC-RESOURCE'},
                     {'fmt': 'SCH/HD', 'bkn': 2, 'pdu': 'MAC-RESOURCE'}],
                llc=[], mle=[], cmce=[], mm=[])
    ndb2.update(bits_for('NDB2'))
    if with_upper:
        ndb2['llc'] = ['BL-UDATA']
        ndb2['mle'] = [{'disc': 'CMCE', 'msg': '-> D-TX-CEASED'}]
    dl.append(ndb2)

    ul_row = [r for r in rows if r['file'] == 'ul'][0]
    ul = dict(idx=0,
              parsed={'pdu_type': 0, 'addr_type': 0,
                      'llc': {'llc_type': 1},
                      'mle': {'mle_disc': 1, 'mm_name': 'U-LOC-UPD-DEMAND'}})
    for layer in ('onair', 'descr', 'deint', 'info'):
        field = ul_row['bits'].get(layer)
        if field:
            ul[field] = '0' * 16
    return dl, [ul]


def _write_case(base, name, dl_src, ul_src, agg_src, dl_events, ul_events):
    root = os.path.join(base, name)
    tools = os.path.join(root, 'tools')
    rec = os.path.join(root, 'rec')
    os.makedirs(tools)
    os.makedirs(rec)
    for fname, text in (('decode_dl.py', dl_src), ('decode_ul.py', ul_src),
                        ('parse_reference_decode.py', agg_src)):
        with open(os.path.join(tools, fname), 'w', encoding='utf-8') as fh:
            fh.write(text)
    for fname, evs in (('dl_events.jsonl', dl_events), ('ul_events.jsonl', ul_events)):
        with open(os.path.join(rec, fname), 'w', encoding='utf-8') as fh:
            for e in evs:
                fh.write(json.dumps(e) + '\n')
    return tools, rec


def selftest(tools_dir):
    """Beweist, dass die Pruefung wirklich anschlaegt.

    Der Aggregator ist in allen Faellen der ECHTE (er definiert den Vertrag,
    welche Ausgabezeilen in der Ereignisdatei landen). Variiert wird der
    Decoder und der Inhalt der Aufzeichnung.
    """
    agg_path = os.path.join(tools_dir, 'parse_reference_decode.py')
    if not os.path.exists(agg_path):
        print('SELBSTTEST FEHLER: %s nicht gefunden' % agg_path)
        return EXIT_TOOL_ERROR
    with open(agg_path, encoding='utf-8') as fh:
        real_agg = fh.read()

    failures = []
    base = tempfile.mkdtemp(prefix='gold_coverage_selftest_')
    rows = ROWS
    agg_src = _fake_agg(real_agg, rows)
    ul_src = _fake_ul(rows)

    # --- Fall 1: vollstaendiges Werkzeug, Treffer in allen Zellen -> MUSS bestehen
    dl_ev, ul_ev = _fake_events(rows, with_upper=True)
    t, r = _write_case(base, 'fall1', _fake_dl(rows, True, True), ul_src, agg_src,
                       dl_ev, ul_ev)
    m1, u1, _ = analyse(r, t)
    if u1:
        failures.append('Fall 1 (vollstaendiges Werkzeug + Treffer ueberall) haette '
                        'bestehen muessen, meldet aber %d unbekannte Zellen: %s'
                        % (len(u1), [(a, b) for a, b, _ in u1][:5]))

    # --- Fall 2: vollstaendiges Werkzeug, obere Schichten LEER -> MUSS bestehen
    #     (echter Nullbefund, weil der Rundlauf aus dem Quelltext nachgewiesen ist)
    dl_ev, ul_ev = _fake_events(rows, with_upper=False)
    t, r = _write_case(base, 'fall2', _fake_dl(rows, True, True), ul_src, agg_src,
                       dl_ev, ul_ev)
    m2, u2, _ = analyse(r, t)
    if u2:
        failures.append('Fall 2 (vollstaendiges Werkzeug, obere Schichten leer) '
                        'haette bestehen muessen, meldet aber %d unbekannte Zellen: %s'
                        % (len(u2), [(a, b) for a, b, _ in u2][:5]))
    n_null = sum(1 for m in m2 for l in LAYERS
                 if m['cells'][l]['state'] == STATE_NULL)
    if n_null == 0:
        failures.append('Fall 2 haette echte Nullbefunde (0*) ausweisen muessen, '
                        'weist aber keinen aus')

    # --- Fall 3: Decoder-Praefix passt nicht zum Aggregator, obere Schichten leer
    #     -> MUSS scheitern (genau der V1-Fehler F10.1 (b))
    dl_ev, ul_ev = _fake_events(rows, with_upper=False)
    t, r = _write_case(base, 'fall3', _fake_dl(rows, False, True), ul_src, agg_src,
                       dl_ev, ul_ev)
    m3, u3, _ = analyse(r, t)
    hit3 = [(a, b) for a, b, _ in u3 if a.startswith('NDB2/BKN')]
    if not hit3:
        failures.append('Fall 3 (Praefix-Mismatch NDB2) haette scheitern muessen, '
                        'meldet aber keine unbekannte NDB2-Zelle')

    # --- Fall 4: Decoder fuehrt SB/BKN2 nicht in die oberen Schichten und
    #     dumpt dessen Bits nicht -> MUSS scheitern (V1-Fehler F10.1 (a))
    dl_ev, ul_ev = _fake_events(rows, with_upper=False)
    sb_row = [r_ for r_ in rows if r_['id'] == 'SB/BKN2'][0]
    for e in dl_ev:
        if e['type'] == 'SB':
            for f in sb_row['bits'].values():
                if f:
                    e[f] = None
            e['mac'] = []
    t, r = _write_case(base, 'fall4', _fake_dl(rows, True, False), ul_src, agg_src,
                       dl_ev, ul_ev)
    m4, u4, _ = analyse(r, t)
    hit4 = [(a, b) for a, b, _ in u4 if a == 'SB/BKN2']
    if not hit4:
        failures.append('Fall 4 (SB/BKN2 ohne oberen Pfad) haette scheitern muessen, '
                        'meldet aber keine unbekannte SB/BKN2-Zelle')

    print('SELBSTTEST gold_coverage.py')
    print('  Fall 1  vollstaendiges Werkzeug + Treffer ueberall .... %s (%d unbekannt)'
          % ('BESTANDEN' if not u1 else 'FEHLSCHLAG', len(u1)))
    print('  Fall 2  vollstaendiges Werkzeug + leere obere Schicht . %s (%d unbekannt, '
          '%d echte Nullbefunde)'
          % ('BESTANDEN' if (not u2 and n_null) else 'FEHLSCHLAG', len(u2), n_null))
    print('  Fall 3  Praefix-Mismatch NDB2 (V1-Fehler F10.1 b) ..... %s (%d unbekannt, '
          'darunter %s)'
          % ('ERKANNT' if hit3 else 'NICHT ERKANNT', len(u3), hit3[:4]))
    print('  Fall 4  SB/BKN2 ohne oberen Pfad (V1-Fehler F10.1 a) .. %s (%d unbekannt, '
          'darunter %s)'
          % ('ERKANNT' if hit4 else 'NICHT ERKANNT', len(u4), hit4[:4]))
    print('  Arbeitsverzeichnis: %s' % base)
    if failures:
        print('')
        print('SELBSTTEST FEHLGESCHLAGEN:')
        for f in failures:
            print('  - %s' % f)
        return EXIT_VIOLATION
    print('')
    print('SELBSTTEST BESTANDEN: die Pruefung meldet gruen, wenn der Rundlauf')
    print('nachgewiesen ist, und schlaegt an, wenn er fehlt.')
    return EXIT_OK


# ==========================================================================

def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(
        description='Werkzeug-Gate: Abdeckungsmatrix Bursttyp x Schicht '
                    'ueber eine Aufzeichnung (V-17-14).')
    ap.add_argument('recording', nargs='?',
                    help='Verzeichnis der Aufzeichnung, z.B. docs/reference_decode')
    ap.add_argument('--tools-dir', default=os.path.join(repo, 'scripts'),
                    help='Verzeichnis mit decode_dl.py, decode_ul.py, '
                         'parse_reference_decode.py (Vorgabe: scripts/)')
    ap.add_argument('--json', action='store_true', help='Ausgabe als JSON')
    ap.add_argument('--selftest', action='store_true',
                    help='Selbsttest mit kuenstlich erzeugten Eingaben')
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest(args.tools_dir)

    if not args.recording:
        ap.error('Aufzeichnungsverzeichnis fehlt (oder --selftest verwenden)')
    if not os.path.isdir(args.recording):
        print('FEHLER: %s ist kein Verzeichnis' % args.recording, file=sys.stderr)
        return EXIT_TOOL_ERROR

    try:
        matrix, unknown, notes = analyse(args.recording, args.tools_dir)
    except (IOError, OSError, ValueError, SyntaxError) as exc:
        print('WERKZEUGFEHLER: %s' % exc, file=sys.stderr)
        return EXIT_TOOL_ERROR

    code = EXIT_VIOLATION if unknown else EXIT_OK
    if args.json:
        print(json.dumps(to_json(args.recording, matrix, unknown, notes, code),
                         ensure_ascii=False, indent=2))
    else:
        print(render_text(args.recording, matrix, notes, unknown))
        print('ERGEBNIS: %s (Rueckgabewert %d)'
              % ('EINGESCHRAENKT - %d unbekannte Zellen' % len(unknown)
                 if unknown else 'vollstaendig abgedeckt', code))
    return code


if __name__ == '__main__':
    sys.exit(main())
