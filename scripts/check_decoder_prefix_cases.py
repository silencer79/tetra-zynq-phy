#!/usr/bin/env python3
"""check_decoder_prefix_cases.py — Selbsttest der Blockkennung in Schichtzeilen.

Prueft scripts/testdata/decoder_prefix_cases.txt gegen

  a) die HEUTIGEN Aggregatormuster aus scripts/parse_reference_decode.py
     (per AST gezogen, nicht importiert - das Modul wertet beim Import
     argparse aus; dieselbe Technik nutzt scripts/gold_coverage.py), und
  b) die Muster VOR dem Fix (unten als historischer Stand festgehalten).

Damit ist beides belegt: die neuen Muster treffen die echten Decoderzeilen,
und die alten haetten sie NICHT getroffen.

Aufruf:  python3 scripts/check_decoder_prefix_cases.py [-v]
Rueckgabe: 0 = alle Faelle wie erwartet, 1 = Abweichung, 2 = Werkzeugfehler.
"""
import argparse
import ast
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AGG = os.path.join(HERE, 'parse_reference_decode.py')
CASES = os.path.join(HERE, 'testdata', 'decoder_prefix_cases.txt')

# Stand VOR dem Fix (Commit-Stand vor dieser Aenderung), woertlich:
#   SCHHD_MAC verlangte Leerraum direkt nach "SCH/HD" -> "SCH/HD-FACCH" fiel raus
#   LLC_LINE / MLE_LINE waren praefixlos verankert -> Halbschlitz-Zweig fiel raus
OLD_PATTERNS = {
    'SCHHD_MAC': r'^\s*BKN(\d)\s+SCH/HD\s+(MAC-\S+)(?:\s+(.+))?',
    'LLC_LINE':  r'^\s+LLC\s+(.+)$',
    'MLE_LINE':  r'^\s+MLE\s+disc=(\S+)(?:\s+(.+))?$',
}


def load_current_patterns(path):
    """NAME = re.compile('...') aus dem Aggregator ziehen (AST, kein Import)."""
    with open(path, encoding='utf-8') as fh:
        tree = ast.parse(fh.read(), filename=path)
    out = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        tgt = node.targets[0]
        val = node.value
        if not isinstance(tgt, ast.Name):
            continue
        if not (isinstance(val, ast.Call) and getattr(val.func, 'attr', None) == 'compile'):
            continue
        arg = val.args[0] if val.args else None
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
            out[tgt.id] = re.compile(arg.value)
    return out


def load_cases(path):
    cases, cur = [], {}
    with open(path, encoding='utf-8') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            if line.startswith('#'):
                continue
            if not line.strip():
                if cur:
                    cases.append(cur)
                    cur = {}
                continue
            if line.startswith('line:'):
                # ALLES nach "line:" ist Nutzdaten, Einrueckung inklusive.
                cur['line'] = line[len('line:'):]
                continue
            if ':' not in line:
                raise ValueError('unverstaendliche Zeile: %r' % line)
            key, _, val = line.partition(':')
            cur[key.strip()] = val.strip()
    if cur:
        cases.append(cur)
    return cases


def expected_groups(spec):
    """"blk=SCH/F, body=BL-UDATA" -> [('blk','SCH/F'), ('body','BL-UDATA')]."""
    if not spec:
        return []
    out = []
    for part in spec.split(', '):
        name, _, val = part.partition('=')
        out.append((name.strip(), None if val == '-' else val))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('-v', '--verbose', action='store_true',
                    help='jeden Fall einzeln listen')
    args = ap.parse_args(argv)

    for p in (AGG, CASES):
        if not os.path.exists(p):
            print('FEHLER: %s nicht gefunden' % p, file=sys.stderr)
            return 2

    new = load_current_patterns(AGG)
    old = dict((k, re.compile(v)) for k, v in OLD_PATTERNS.items())
    cases = load_cases(CASES)

    fails = []
    n_new_only = 0
    for c in cases:
        name = c.get('case', '?')
        pname = c['pattern']
        line = c['line']
        rx_new = new.get(pname)
        if rx_new is None:
            fails.append('%s: Aggregator hat kein Muster %s' % (name, pname))
            continue
        m_new = rx_new.match(line)
        m_old = old[pname].match(line) if pname in old else None

        want_new = c['expect_new'] == 'match'
        want_old = c['expect_old'] == 'match'
        if bool(m_new) != want_new:
            fails.append('%s: heutiges %s %s die Zeile, erwartet war %s'
                         % (name, pname, 'trifft' if m_new else 'trifft NICHT',
                            c['expect_new']))
        if bool(m_old) != want_old:
            fails.append('%s: altes %s %s die Zeile, erwartet war %s'
                         % (name, pname, 'trifft' if m_old else 'trifft NICHT',
                            c['expect_old']))
        if m_new:
            for gname, gval in expected_groups(c.get('expect')):
                try:
                    got = m_new.group(gname)
                except IndexError:
                    fails.append('%s: Muster %s hat keine Gruppe "%s"'
                                 % (name, pname, gname))
                    continue
                if got != gval:
                    fails.append('%s: Gruppe %s = %r, erwartet %r'
                                 % (name, gname, got, gval))
        if want_new and not want_old:
            n_new_only += 1
        if args.verbose:
            print('  %-28s %-10s neu=%-8s alt=%-8s %s'
                  % (name, pname, 'match' if m_new else 'nomatch',
                     'match' if m_old else 'nomatch', repr(line)))

    print('SELBSTTEST Blockkennung (%s)' % os.path.relpath(CASES, os.path.dirname(HERE)))
    print('  Faelle geprueft ................................ %d' % len(cases))
    print('  davon: neu erkannt, alt NICHT erkannt .......... %d' % n_new_only)
    print('  Abweichungen .................................. %d' % len(fails))
    if fails:
        print('')
        print('FEHLGESCHLAGEN:')
        for f in fails:
            print('  - %s' % f)
        return 1
    print('')
    print('BESTANDEN: die heutigen Muster treffen die echten Decoderzeilen,')
    print('die Muster vor dem Fix haetten die neuen Faelle nicht getroffen.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
