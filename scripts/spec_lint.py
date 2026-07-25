#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""spec_lint.py — Bau-Gate für die V2-Spezifikation (docs/spec_v2).

Setzt das automatische Bau-Gate aus `17_LESSONS_LEARNED.md §5.2` für die
Spezifikation selbst um, soweit es **heute** prüfbar ist. Prüfregeln sind die
Festlegungen aus `docs/spec_v2/CONVENTIONS.md`.

Rückgabewerte
    0 = keine Verstöße (Hinweise sind erlaubt)
    1 = mindestens ein Verstoß
    2 = Werkzeugfehler (Verzeichnis fehlt, Datei unlesbar, interner Fehler)

Regeln (einzeln über --only/--skip zu- und abschaltbar)
    marker    Evidenz-Marker (CONVENTIONS §3)
    regaddr   Registeradressen nur in 07_PS_PL_CONTRACT.md (CONVENTIONS §4)
    ids       Kennungen R-NN-n / V-NN-n / O-NN-n (CONVENTIONS §5)
    xref      Querverweise NN_KAPITEL und `NN §x.y`
    dangling  Hängende Bezeichner (Zähler, Register, Konfig-Schlüssel, Mailbox-Felder)
    verbote   Absolute Verbote (CONVENTIONS §6)
    slots     Zeitschlitz-Zählweise (CONVENTIONS §4) — nur HINWEIS, nie Verstoß

Was dieses Werkzeug NICHT prüft
    Die restlichen Punkte des Bau-Gates aus `17 §5.2` brauchen V2-Artefakte
    (erzeugte Registerkonstanten, V2-Quellenliste, V2-Hierarchie, beide
    Werkzeugketten). V2-Code existiert noch nicht. Diese Gates werden als
    "NICHT PRUEFBAR" mit Angabe des fehlenden Artefakts gemeldet und **nie**
    als bestanden. Siehe V2_GATES.

Bekannte Grenzen der heute laufenden Regeln (bewusst eng gefasst, damit die
Fehlalarmquote niedrig bleibt)
    - `dangling` wertet Zeilen mit V1-Bezug (`[CODE …]`, „V1") absatzweise als
      Zitat des Altsystems, nicht als V2-Verwendung. Ein echter hängender
      Bezeichner, der ausschließlich in einem V1-Absatz steht, wird dadurch
      nicht gefunden.
    - Konfigurationsschlüssel werden nur dort geprüft, wo sie in derselben
      Zeile mit `cell.conf`/„Schlüssel"/„Konfigurationsdatei" stehen und in
      Backticks gesetzt sind. Absatzweiter Kontext erzeugte in der Erprobung
      elf Fehlalarme (Verilog-Attribute, POSIX-Konstanten, Registerbitnamen)
      und ist deshalb nicht implementiert.
    - `xref` prüft nur qualifizierte Verweise (`NN_KAPITEL`, `NN §x.y`).
      Blanke `§x.y`-Verweise auf das eigene Kapitel sind nicht prüfbar, ohne
      ETSI-Paragrafen im Fließtext falsch zu treffen.
    - `slots` ist heuristisch und meldet ausschließlich HINWEIS, nie VERSTOSS.

--------------------------------------------------------------------------
Trennkriterium für Regel `regaddr` (Registeradresse vs. Bitmuster)
--------------------------------------------------------------------------
Die Spec ist voll von Hex-Literalen, die **keine** Registeradressen sind:
AACH-Infoworte (`0x32CB`), Scrambler-Startwerte (`0x4183F207`), CRC-Polynom
und -Restwert (`0x1021`, `0x1D0F`), RM(30,14)-Matrixzeilen, SDS-Statusbereiche
(`0x7C00`), AD9361-SPI-Registeradressen (`0x073`), PS-/DDR-Adressen
(`0x1FFFFFFF`) und Rücksetzwerte in Registertabellen. Ein reiner Hex-Grep wäre
zu 95 % Fehlalarm.

Als **Registeradresse** gilt ein Hex-Literal nur, wenn es im selben Textstück
namentlich an ein Register des PS↔PL-Vertrags gebunden ist. Genau drei Muster:

  A) Absolute Lage in der AXI-Apertur des Vertrags: `0x43C0xxxx`
     (Basis `0x43C0_0000` laut `07 §2.2`). Eine solche Zahl kann nichts
     anderes sein als die Adresse eines Registers dieses Vertrags.
  B) Namensbindung in einer Zeile: `REG_NAME = 0x…`, `REG_NAME @ 0x…`,
     `REG_NAME auf 0x…` bzw. umgekehrt `0x… = REG_NAME` / `0x… (REG_NAME)`.
  C) Tabellenzeile im Layout des Vertrags: eine Zelle nennt einen
     Registernamen `REG_*`, eine andere Zelle besteht **ausschließlich** aus
     Hex-Literalen, Bereichszeichen und Kommata (die Adress-Spalte).

Damit fällt heraus: `13 (0x0D)` als Schwellwert (Zelle enthält Klartext),
AD9361-SPI (`0x073` ist an keinen `REG_*`-Namen gebunden), Infoworte und
Startwerte (keine Namensbindung), Rücksetzwerte in `07` (Datei ist ohnehin
ausgenommen). Code-Blöcke (```…```) werden für diese Regel nicht gelesen.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile

# --------------------------------------------------------------------------
# Konstanten / Regelwerk
# --------------------------------------------------------------------------

RULES = ("marker", "regaddr", "ids", "xref", "dangling", "verbote", "slots")

#: CONVENTIONS §3 — zugelassene Evidenz-Marker
ALLOWED_MARKERS = {"ETSI", "CODE", "GOLD", "MESS", "BUILD", "SIM", "ANNAHME"}

#: CONVENTIONS §3 — Belege, die auf eine Werkzeugausgabe zeigen, gehören zu [BUILD]
TOOL_OUTPUT_PAT = re.compile(r"\.rpt\b|utilization|impl_timing", re.IGNORECASE)

#: Belegziel, das nur intern (Agenten-Gedächtnis) auflösbar ist.
#: Kein Treffer, wenn der Name Teil eines Dateipfads oder eines längeren
#: Bezeichners ist (`docs/reference_decode/…`, `parse_reference_decode.py`).
INTERNAL_TARGET_PAT = re.compile(
    r"(?<![\w/.\-])(?:project|feedback|reference)_[a-z0-9_]+(?![\w/.\-])"
)

#: CONVENTIONS §6.2 — die Crypto-Rekey-PDU. Bewusst nur als Kürzel geführt.
FORBIDDEN_PDU_PAT = re.compile(r"(?<![A-Za-z0-9_])" + "OT" + "AR" + r"(?![A-Za-z0-9_])",
                               re.IGNORECASE)

#: CONVENTIONS §6.3 — im FPGA eingebaute Logikanalysator-Kerne
ICE_DEBUG_PAT = re.compile(
    r"\bILA\b|ChipScope|Integrated\s+Logic\s+Analyzer|Logic[- ]Analyzer|"
    r"Logikanalysator|In-Circuit-Debug|Debug-Core|Debug-Kern|VIO-Core",
    re.IGNORECASE,
)

#: Wörter, die einen Absatz als Verbot/Absage kennzeichnen (kein Vorschlag)
NEGATION_PAT = re.compile(
    r"\bnicht\b|\bkein|\bnie\b|verbiet|verboten|unzul[äa]ssig|entf[äa]llt|"
    r"ausgeschlossen|untersagt|abgelehnt|verzicht",
    re.IGNORECASE,
)

#: Zeilen mit V1-Bezug sind Zitate des Altsystems, keine V2-Verwendung
V1_CITATION_PAT = re.compile(r"\[CODE\s|\bV1\b|Altsystem|V1-Befund|V1-Name")

#: Bezeichnerklassen für Regel `dangling`
COUNTER_PAT = re.compile(r"\b[a-z][a-z0-9_]*_cnt\b")
REGISTER_PAT = re.compile(r"\bREG_[A-Z0-9_]+\b")
MAILBOX_FIELD_PAT = re.compile(r"\bW\d{1,2}\.([a-z][a-z0-9_]*)\b")
CONFIG_KEY_PAT = re.compile(r"`([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)`")
CONFIG_CONTEXT_PAT = re.compile(r"cell\.conf|Schl[üu]ssel|Konfigurationsdatei")

#: Datei, die Konfigurationsschlüssel normativ führt
CONFIG_DEF_FILE = "13_SW_ARCHITECTURE.md"
CONFIG_DEF_SECTION = "3.7"

#: Datei, die Register und Mailbox-Felder normativ führt
CONTRACT_FILE = "07_PS_PL_CONTRACT.md"

#: Evidenz-Marker, die für einige Regeln ausmaskiert werden
MARKER_SPAN_PAT = re.compile(r"\[(?:ETSI|CODE|GOLD|MESS|BUILD|SIM|ANNAHME)[^\]]*\]")

#: Kennungen
ID_PAT = re.compile(r"\b([RVO])-(\d{2})-(\d{1,2}[a-z]?)\b")
#: Abschnitte, in denen Kennungen definiert werden (CONVENTIONS §5;
#: Kapitel 00 führt seine offenen Punkte in §9)
ID_DEF_SECTIONS = {"1", "5", "6", "9"}

#: Querverweise
FILEREF_PAT = re.compile(r"\b(\d\d)_([A-Z][A-Z0-9_]*)")
SECREF_PAT = re.compile(r"`?(\d\d)(?:_[A-Z][A-Z0-9_]*)?`?\s*§\s*(\d+(?:\.\d+)*)")

#: Zeitschlitz-Heuristik (nur Hinweise)
SLOT_HINTS = (
    (re.compile(r"\bTS\s?0\b|\bTS\s?[5-9]\b"),
     "TS-Nummer außerhalb der ETSI-Zählung 1..4 — Zählweise unklar"),
    (re.compile(r"\btn\s*=\s*[4-9]\b"),
     "tn-Wert außerhalb der RTL-Zählung 0..3 — Zählweise unklar"),
    (re.compile(r"\bZeitschlitz\s+0\b"),
     "„Zeitschlitz 0\" mischt ETSI-Wort mit 0-basierter Zählung"),
    # „ein Slot 1 416 700 clk_sys" ist eine Zahl mit Tausendergruppen, keine
    # Slot-Nummer — deshalb darf hinter der Ziffer keine weitere Ziffer folgen.
    (re.compile(r"\bSlot\s+[0-4](?![\d  ]|\s*\d)\b"
                r"(?!\s*[.,]?\s*(?:ETSI|RTL))"),
     "„Slot n\" ohne Angabe der Zählweise (ETSI 1-basiert vs. RTL 0-basiert)"),
)

# --------------------------------------------------------------------------
# Bau-Gates, die V2-Artefakte brauchen (17 §5.2). Heute nicht prüfbar.
# --------------------------------------------------------------------------

V2_GATES = (
    {
        "gate": "regmap_generat",
        "quelle": "17_LESSONS_LEARNED.md §5.2 Punkt 1 (V-17-11)",
        "prueft": "erzeugte Registerkonstanten (HDL/HAL/Testvektortabelle) "
                  "gegen die normative Tabelle in 07",
        "artefakt": ["build/generated/tetra_regs.vh",
                     "build/generated/tetra_regs.h"],
    },
    {
        "gate": "quellenliste_vs_hierarchie",
        "quelle": "17_LESSONS_LEARNED.md §5.2 Punkt 2 (V-17-8)",
        "prueft": "jedes Modul der V2-Quellenliste ist in der Hierarchie instanziiert",
        "artefakt": ["rtl_v2/sources.tcl", "build/reports/cur_hier_deep.rpt"],
    },
    {
        "gate": "literale_in_werkzeugen",
        "quelle": "17_LESSONS_LEARNED.md §5.2 Punkt 3 (V-17-6, V-17-7, V-17-10)",
        "prueft": "Schwellwert-Literale in V2-Skripten, ±1 auf Zeitbezugssignalen "
                  "außerhalb des Umrechnungsmoduls, mehrfache Codiertabellen",
        "artefakt": ["sw_v2", "rtl_v2"],
    },
    {
        "gate": "beide_werkzeugketten",
        "quelle": "17_LESSONS_LEARNED.md §5.2 Punkt 4 (V-17-15 d)",
        "prueft": "Simulator und Synthese-Parser nehmen dieselbe Quelle an",
        "artefakt": ["build/logs/xsim_parse.log", "build/logs/synth_parse.log"],
    },
)

# --------------------------------------------------------------------------
# Datenmodell
# --------------------------------------------------------------------------


class Finding:
    """Ein Befund. severity ist 'verstoss' oder 'hinweis'."""

    __slots__ = ("rule", "severity", "path", "line", "message", "detail")

    def __init__(self, rule, severity, path, line, message, detail=""):
        self.rule = rule
        self.severity = severity
        self.path = path
        self.line = line
        self.message = message
        self.detail = detail

    def as_dict(self):
        return {
            "regel": self.rule,
            "art": self.severity,
            "datei": self.path,
            "zeile": self.line,
            "meldung": self.message,
            "detail": self.detail,
        }

    def as_text(self):
        tag = "VERSTOSS" if self.severity == "verstoss" else "HINWEIS "
        pos = "%s:%d" % (self.path, self.line) if self.line else self.path
        out = "[%s] %-8s %s  %s" % (tag, self.rule, pos, self.message)
        if self.detail:
            out += "  | " + self.detail
        return out


class SpecFile:
    """Eine Spec-Datei mit vorberechneten Sichten."""

    def __init__(self, path, name, text):
        self.path = path
        self.name = name
        self.text = text
        self.lines = text.splitlines()
        m = re.match(r"(\d\d)_", name)
        self.chapter = m.group(1) if m else None
        self.is_chapter = self.chapter is not None
        self.in_code = self._code_mask()
        self.sections = self._section_index()
        self.line_section = self._line_sections()
        self.paragraphs = self._paragraphs()
        self.line_paragraph = {}
        for pi, (start, end, ptext) in enumerate(self.paragraphs):
            for ln in range(start, end + 1):
                self.line_paragraph[ln] = pi

    # -- Vorberechnung ----------------------------------------------------

    def _code_mask(self):
        """Menge der 1-basierten Zeilennummern innerhalb von ```-Blöcken."""
        mask = set()
        fence = False
        for i, line in enumerate(self.lines, 1):
            if line.lstrip().startswith("```"):
                fence = not fence
                mask.add(i)
                continue
            if fence:
                mask.add(i)
        return mask

    def _section_index(self):
        """Alle Abschnittsnummern aus Überschriften, z. B. '3', '3.1', '3.1.4'."""
        secs = set()
        for i, line in enumerate(self.lines, 1):
            if i in self.in_code:
                continue
            m = re.match(r"^#{2,6}\s+(\d+(?:\.\d+)*)\.?\s", line)
            if m:
                secs.add(m.group(1).rstrip("."))
        return secs

    def _line_sections(self):
        """Zuordnung Zeilennummer -> aktuelle oberste Abschnittsnummer."""
        out = {}
        cur = None
        for i, line in enumerate(self.lines, 1):
            if i not in self.in_code:
                m = re.match(r"^##\s+(\d+)\.?\s", line)
                if m:
                    cur = m.group(1)
            out[i] = cur
        return out

    def _paragraphs(self):
        """Absätze als (erste Zeile, letzte Zeile, Text)."""
        out = []
        start = None
        buf = []
        for i, line in enumerate(self.lines, 1):
            if line.strip() == "":
                if start is not None:
                    out.append((start, i - 1, "\n".join(buf)))
                    start, buf = None, []
                continue
            if start is None:
                start = i
            buf.append(line)
        if start is not None:
            out.append((start, len(self.lines), "\n".join(buf)))
        return out

    # -- Hilfen -----------------------------------------------------------

    def paragraph_text(self, lineno):
        pi = self.line_paragraph.get(lineno)
        if pi is None:
            return self.lines[lineno - 1] if 0 < lineno <= len(self.lines) else ""
        return self.paragraphs[pi][2]

    def table_cells(self, lineno):
        """Zellen einer Markdown-Tabellenzeile, sonst None."""
        line = self.lines[lineno - 1]
        if not line.lstrip().startswith("|"):
            return None
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if cells and all(set(c) <= set("-: ") for c in cells if c != ""):
            return None  # Trennzeile
        return cells

    def enumerate_lines(self, skip_code=False):
        for i, line in enumerate(self.lines, 1):
            if skip_code and i in self.in_code:
                continue
            yield i, line


# --------------------------------------------------------------------------
# Laden
# --------------------------------------------------------------------------


def load_spec(directory):
    """Lädt alle *.md aus dem Spec-Verzeichnis. Wirft OSError bei Problemen."""
    if not os.path.isdir(directory):
        raise OSError("Spec-Verzeichnis nicht gefunden: %s" % directory)
    files = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".md"):
            continue
        full = os.path.join(directory, name)
        with open(full, "r", encoding="utf-8") as fh:
            files.append(SpecFile(full, name, fh.read()))
    if not files:
        raise OSError("Keine .md-Dateien in %s" % directory)
    return files


def chapters(files):
    return [f for f in files if f.is_chapter]


# --------------------------------------------------------------------------
# Regel 1 — Evidenz-Marker (CONVENTIONS §3)
# --------------------------------------------------------------------------

#: Ein eckiger Klammerausdruck gilt als Beleg-Marker, wenn er eine Belegform
#: nach CONVENTIONS §3 trägt: Paragrafenzeichen, ISO-Datum oder Pfad:Zeile.
EVIDENCE_SHAPE_PAT = re.compile(r"§|\b\d{4}-\d{2}-\d{2}\b|[\w./-]+\.\w+:\d+")
BRACKET_PAT = re.compile(r"\[([A-ZÄÖÜ][A-ZÄÖÜ]{1,9})(\s[^\]]*)?\]")


def rule_marker(files):
    findings = []
    for f in files:
        if f.name == "CONVENTIONS.md":
            continue  # definiert die Marker, benutzt sie nicht als Belege
        for i, line in f.enumerate_lines():
            for m in BRACKET_PAT.finditer(line):
                token = m.group(1)
                body = (m.group(2) or "").strip()
                whole = m.group(0)
                if token in ALLOWED_MARKERS:
                    if token == "MESS" and TOOL_OUTPUT_PAT.search(body):
                        findings.append(Finding(
                            "marker", "verstoss", f.name, i,
                            "[MESS …] belegt mit einer Werkzeugausgabe — muss [BUILD] sein",
                            whole[:120]))
                    hit = INTERNAL_TARGET_PAT.search(body)
                    if hit:
                        findings.append(Finding(
                            "marker", "verstoss", f.name, i,
                            "Beleg zeigt auf ein nur intern auflösbares Ziel: %s"
                            % hit.group(0), whole[:120]))
                    continue
                # Unbekanntes Kürzel: nur melden, wenn es sich wie ein Beleg
                # verhält (Paragraf/Datum/Pfad:Zeile). „[MSB]" oder
                # „[ETR 300-1 S. 43: …]" sind Zitatklammern, keine Marker.
                if body and EVIDENCE_SHAPE_PAT.search(body):
                    findings.append(Finding(
                        "marker", "verstoss", f.name, i,
                        "unbekannter Evidenz-Marker [%s …] — zugelassen: %s"
                        % (token, ", ".join(sorted(ALLOWED_MARKERS))),
                        whole[:120]))
    return findings


# --------------------------------------------------------------------------
# Regel 2 — Registeradressen nur in 07 (CONVENTIONS §4)
# --------------------------------------------------------------------------

HEX_PAT = re.compile(r"0x[0-9A-Fa-f][0-9A-Fa-f_]*")
APERTURE_PAT = re.compile(r"\b0x43C0_?[0-9A-Fa-f]{4}\b")
BIND_PAT = re.compile(
    r"REG_[A-Z0-9_]+`?\s*(?:=|@|auf)\s*`?(0x[0-9A-Fa-f_]+)"
    r"|(0x[0-9A-Fa-f_]+)`?\s*(?:=|\()\s*`?REG_[A-Z0-9_]+"
)
HEX_ONLY_CELL_PAT = re.compile(r"^[`\s]*0x[0-9A-Fa-f_]+[`\s]*"
                               r"(?:[–\-…,/]\s*[`\s]*0x[0-9A-Fa-f_]+[`\s]*)*$")
REG_IN_CELL_PAT = re.compile(r"REG_[A-Z0-9_]")


def rule_regaddr(files):
    findings = []
    for f in chapters(files):
        if f.name == CONTRACT_FILE:
            continue
        for i, line in f.enumerate_lines(skip_code=True):
            if "0x" not in line:
                continue
            hits = []
            # V1-Zitate sind erlaubt (CONVENTIONS §4 "Register-Definitionen",
            # Geltungsbereich): ohne sie liesse sich kein Altsystem-Defekt belegen.
            # Dieselbe Kontexterkennung wie in `dangling`. Gilt NUR fuer Fliesstext-
            # Treffer — eine Registertabelle mit Adressspalte bleibt auch im
            # V1-Zusammenhang unzulaessig, weil sie als V2-Festlegung lesbar ist.
            is_v1 = bool(V1_CITATION_PAT.search(f.paragraph_text(i)))
            if not is_v1:
                for m in APERTURE_PAT.finditer(line):
                    hits.append((m.group(0), "absolute Adresse in der AXI-Apertur des Vertrags"))
                for m in BIND_PAT.finditer(line):
                    hits.append((m.group(1) or m.group(2),
                                 "Hex-Wert namentlich an ein REG_* gebunden"))
            cells = f.table_cells(i)
            if cells and len(cells) >= 2:
                has_reg = any(REG_IN_CELL_PAT.search(c) for c in cells)
                if has_reg:
                    for c in cells:
                        if HEX_ONLY_CELL_PAT.match(c) and "0x" in c:
                            for m in HEX_PAT.finditer(c):
                                hits.append((m.group(0),
                                             "Tabellenzeile Registername + reine Adress-Zelle"))
            seen = set()
            for value, why in hits:
                if value in seen:
                    continue
                seen.add(value)
                findings.append(Finding(
                    "regaddr", "verstoss", f.name, i,
                    "Registeradresse %s außerhalb von %s" % (value, CONTRACT_FILE),
                    why))
    return findings


# --------------------------------------------------------------------------
# Regel 3 — Kennungen (CONVENTIONS §5)
# --------------------------------------------------------------------------

DEF_TABLE_PAT = re.compile(r"^\|\s*[`*]*([RVO]-\d{2}-\d{1,2}[a-z]?)[`*]*\s*\|(.*)$")
DEF_BOLD_PAT = re.compile(
    r"^\s*(?:[-*+]\s+|\d+\.\s+)?\*\*[`]?([RVO]-\d{2}-\d{1,2}[a-z]?)[`]?"
    r"(?:\*\*|:|\s)")


def _id_definition(f, lineno, line):
    """Gibt (kennung, inhalt) zurück, wenn die Zeile eine Definition ist."""
    sec = f.line_section.get(lineno)
    # Kapitel 00 hat laut CONVENTIONS §2 einen eigenen Aufbau (Zielbild,
    # Architektur-Schnitt, Glossar) und führt seine Anforderungen im
    # Architektur-Abschnitt. Dort gilt die Abschnittsschranke nicht.
    if f.chapter != "00" and sec not in ID_DEF_SECTIONS:
        return None
    m = DEF_TABLE_PAT.match(line)
    if m:
        return m.group(1), " ".join(m.group(2).split())
    m = DEF_BOLD_PAT.match(line)
    if m:
        # Ein Rückverweis wie „**R-12-02:** …" in §3 fällt bereits über die
        # Abschnittsprüfung heraus; innerhalb von §1/§5/§6 ist die
        # Doppelpunkt-Schreibweise die reguläre Definitionsform (00, 17).
        return m.group(1), " ".join(line.split())
    return None


def rule_ids(files):
    findings = []
    defs = {}       # kennung -> Liste (datei, zeile, inhalt)
    uses = {}       # kennung -> Liste (datei, zeile)
    for f in chapters(files):
        for i, line in f.enumerate_lines(skip_code=True):
            d = _id_definition(f, i, line)
            if d:
                defs.setdefault(d[0], []).append((f.name, i, d[1]))
            for m in ID_PAT.finditer(line):
                ident = m.group(0)
                if d and ident == d[0]:
                    continue
                uses.setdefault(ident, []).append((f.name, i))

    # (a) Kapitelnummer der Kennung == Kapitel der Definition
    for ident, places in sorted(defs.items()):
        want = ident.split("-")[1]
        for fname, lineno, _ in places:
            if fname[:2] != want:
                findings.append(Finding(
                    "ids", "verstoss", fname, lineno,
                    "Kennung %s in Kapitel %s definiert" % (ident, fname[:2]),
                    "NN muss die Nummer des definierenden Kapitels sein"))

    # (b) doppelte Definition mit abweichendem Inhalt
    for ident, places in sorted(defs.items()):
        if len(places) > 1 and len({c for _, _, c in places}) > 1:
            where = ", ".join("%s:%d" % (fn, ln) for fn, ln, _ in places)
            findings.append(Finding(
                "ids", "verstoss", places[0][0], places[0][1],
                "Kennung %s mehrfach mit unterschiedlichem Inhalt definiert" % ident,
                where))

    # (c) zitierte, aber nicht definierte Kennung
    for ident in sorted(uses):
        if ident in defs:
            continue
        fname, lineno = uses[ident][0]
        findings.append(Finding(
            "ids", "verstoss", fname, lineno,
            "Kennung %s zitiert, aber nirgends definiert" % ident,
            "%d Fundstelle(n)" % len(uses[ident])))
    return findings


# --------------------------------------------------------------------------
# Regel 4 — Querverweise
# --------------------------------------------------------------------------


def rule_xref(files):
    findings = []
    stems = {os.path.splitext(f.name)[0] for f in files}
    secs = {f.chapter: f.sections for f in files if f.is_chapter}
    secs["CONVENTIONS"] = next(
        (f.sections for f in files if f.name == "CONVENTIONS.md"), set())
    for f in files:
        if f.name == "CONVENTIONS.md":
            continue
        for i, line in f.enumerate_lines(skip_code=True):
            masked = MARKER_SPAN_PAT.sub(lambda m: " " * len(m.group(0)), line)
            for m in FILEREF_PAT.finditer(masked):
                stem = m.group(0)
                if stem not in stems:
                    findings.append(Finding(
                        "xref", "verstoss", f.name, i,
                        "Verweis auf nicht existierende Datei %s.md" % stem))
            for m in SECREF_PAT.finditer(masked):
                nn, sec = m.group(1), m.group(2)
                if nn not in secs:
                    findings.append(Finding(
                        "xref", "verstoss", f.name, i,
                        "Verweis auf nicht existierendes Kapitel %s" % nn,
                        m.group(0).strip()))
                elif sec not in secs[nn]:
                    findings.append(Finding(
                        "xref", "verstoss", f.name, i,
                        "Verweis auf nicht existierenden Abschnitt %s §%s" % (nn, sec),
                        m.group(0).strip()))
    return findings


# --------------------------------------------------------------------------
# Regel 5 — hängende Bezeichner
# --------------------------------------------------------------------------


def _collect_names(text):
    return set(COUNTER_PAT.findall(text)) | set(REGISTER_PAT.findall(text))


def _dangling_counters_and_registers(files):
    """Definitionen sammeln, Verwendungen sammeln, Differenz melden."""
    defined = {}        # name -> (datei, zeile)
    prefixes = {}       # 'REG_FOO_' -> (datei, zeile)  aus Platzhaltern REG_FOO_*
    used = {}           # name -> Liste (datei, zeile)

    for f in chapters(files):
        for i, line in f.enumerate_lines(skip_code=True):
            cells = f.table_cells(i)
            if cells:
                # Definitionszellen: Spalte 0 und 1 führen den Namen,
                # in 07-Registerzeilen (>=4 Zellen) auch die Beschreibungsspalten
                # (dort werden Bitfelder mit Zweck und Rücksetzwert geführt).
                def_cells = cells[:2] if len(cells) < 4 else cells
                for c in def_cells:
                    for n in _collect_names(c):
                        defined.setdefault(n, (f.name, i))
                    for m in re.finditer(r"`?(REG_[A-Z0-9_]*_)\*", c):
                        prefixes.setdefault(m.group(1), (f.name, i))
                    for m in re.finditer(r"`([a-z][a-z0-9_]*_)\*`", c):
                        prefixes.setdefault(m.group(1), (f.name, i))
            # Prosa-Definition „**Zähler:** `pop_cnt` (16 bit, sättigend)"
            if re.match(r"\s*\*\*Z[äa]hler", line):
                for n in _collect_names(line):
                    defined.setdefault(n, (f.name, i))

    for f in chapters(files):
        for i, line in f.enumerate_lines(skip_code=True):
            # V1-Zitate sind keine V2-Verwendung. Der Bezug steht oft eine
            # Zeile weiter oben, deshalb absatzweise prüfen.
            if V1_CITATION_PAT.search(f.paragraph_text(i)):
                continue
            for n in _collect_names(line):
                used.setdefault(n, []).append((f.name, i))

    findings = []
    for name in sorted(used):
        if name in defined or name.endswith("_"):
            continue
        if any(name.startswith(p) for p in prefixes):
            continue
        fname, lineno = used[name][0]
        kind = "Register" if name.startswith("REG_") else "Zähler"
        findings.append(Finding(
            "dangling", "verstoss", fname, lineno,
            "%s `%s` benutzt, aber in keinem Kapitel definiert" % (kind, name),
            "%d Fundstelle(n)" % len(used[name])))
    return findings


def _dangling_mailbox_fields(files):
    findings = []
    contract = next((f for f in files if f.name == CONTRACT_FILE), None)
    if contract is None:
        return findings
    defined = set()
    for i, line in contract.enumerate_lines():
        cells = contract.table_cells(i)
        if cells:
            for c in cells[:2]:
                m = re.fullmatch(r"[`*]*([a-z][a-z0-9_]*)[`*]*", c.strip())
                if m:
                    defined.add(m.group(1))
        for m in MAILBOX_FIELD_PAT.finditer(line):
            defined.add(m.group(1))
    for f in chapters(files):
        if f.name == CONTRACT_FILE:
            continue
        for i, line in f.enumerate_lines(skip_code=True):
            if V1_CITATION_PAT.search(f.paragraph_text(i)):
                continue
            for m in MAILBOX_FIELD_PAT.finditer(line):
                if m.group(1) not in defined:
                    findings.append(Finding(
                        "dangling", "verstoss", f.name, i,
                        "Mailbox-Feld `%s` benutzt, aber in %s nicht definiert"
                        % (m.group(0), CONTRACT_FILE)))
    return findings


def _dangling_config_keys(files):
    findings = []
    src = next((f for f in files if f.name == CONFIG_DEF_FILE), None)
    if src is None:
        return findings
    defined = set()
    for i, line in src.enumerate_lines():
        sec_ok = False
        # Abschnitt 3.7 anhand der Überschriftenlage bestimmen
        for j in range(i, 0, -1):
            m = re.match(r"^#{3,6}\s+(\d+(?:\.\d+)*)\s", src.lines[j - 1])
            if m:
                sec_ok = m.group(1) == CONFIG_DEF_SECTION
                break
        if sec_ok:
            defined |= set(re.findall(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b", line))
    used = {}
    for f in chapters(files):
        for i, line in f.enumerate_lines(skip_code=True):
            masked = MARKER_SPAN_PAT.sub(" ", line)
            if not CONFIG_CONTEXT_PAT.search(masked):
                continue
            for key in CONFIG_KEY_PAT.findall(masked):
                if key.startswith("REG_") or key.startswith("TETRA_"):
                    continue  # eigene Klassen
                used.setdefault(key, []).append((f.name, i))
    for key in sorted(used):
        if key in defined:
            continue
        fname, lineno = used[key][0]
        findings.append(Finding(
            "dangling", "verstoss", fname, lineno,
            "Konfigurationsschlüssel `%s` benutzt, aber in %s §%s nicht geführt"
            % (key, CONFIG_DEF_FILE, CONFIG_DEF_SECTION)))
    return findings


def rule_dangling(files):
    out = []
    out += _dangling_counters_and_registers(files)
    out += _dangling_mailbox_fields(files)
    out += _dangling_config_keys(files)
    return out


# --------------------------------------------------------------------------
# Regel 6 — absolute Verbote (CONVENTIONS §6)
# --------------------------------------------------------------------------


def rule_verbote(files):
    findings = []
    for f in files:
        for i, line in f.enumerate_lines():
            if FORBIDDEN_PDU_PAT.search(line):
                findings.append(Finding(
                    "verbote", "verstoss", f.name, i,
                    "verbotene Crypto-Rekey-PDU erwähnt (CONVENTIONS §6.2)"))
            m = ICE_DEBUG_PAT.search(line)
            if m:
                para = f.paragraph_text(i)
                if NEGATION_PAT.search(para):
                    continue  # Absage/Verbot, keine Empfehlung
                findings.append(Finding(
                    "verbote", "verstoss", f.name, i,
                    "In-Circuit-Debug-Kern als Verifikationsmethode (CONVENTIONS §6.3)",
                    m.group(0)))
    return findings


# --------------------------------------------------------------------------
# Regel 7 — Zeitschlitz-Zählweise (heuristisch, nur Hinweise)
# --------------------------------------------------------------------------


def rule_slots(files):
    findings = []
    for f in chapters(files):
        for i, line in f.enumerate_lines(skip_code=True):
            masked = MARKER_SPAN_PAT.sub(" ", line)
            for pat, msg in SLOT_HINTS:
                m = pat.search(masked)
                if m:
                    findings.append(Finding(
                        "slots", "hinweis", f.name, i, msg, m.group(0).strip()))
    return findings


# --------------------------------------------------------------------------
# Ausführung
# --------------------------------------------------------------------------

RULE_FUNCS = {
    "marker": rule_marker,
    "regaddr": rule_regaddr,
    "ids": rule_ids,
    "xref": rule_xref,
    "dangling": rule_dangling,
    "verbote": rule_verbote,
    "slots": rule_slots,
}


def select_rules(only, skip):
    active = list(RULES)
    if only:
        wanted = [r.strip() for r in only.split(",") if r.strip()]
        unknown = [r for r in wanted if r not in RULES]
        if unknown:
            raise ValueError("unbekannte Regel(n) in --only: %s" % ", ".join(unknown))
        active = [r for r in RULES if r in wanted]
    if skip:
        unwanted = [r.strip() for r in skip.split(",") if r.strip()]
        unknown = [r for r in unwanted if r not in RULES]
        if unknown:
            raise ValueError("unbekannte Regel(n) in --skip: %s" % ", ".join(unknown))
        active = [r for r in active if r not in unwanted]
    return active


def run_rules(files, active):
    findings = []
    for name in active:
        findings.extend(RULE_FUNCS[name](files))
    findings.sort(key=lambda x: (x.severity != "verstoss", x.path, x.line, x.rule))
    return findings


def check_v2_gates(repo_root):
    """Meldet die Bau-Gates, die V2-Artefakte brauchen. Nie 'bestanden'."""
    out = []
    for gate in V2_GATES:
        missing = [a for a in gate["artefakt"]
                   if not os.path.exists(os.path.join(repo_root, a))]
        out.append({
            "gate": gate["gate"],
            "quelle": gate["quelle"],
            "prueft": gate["prueft"],
            "status": "nicht_pruefbar",
            "fehlende_artefakte": missing,
            "grund": ("V2-Artefakt fehlt: " + ", ".join(missing)) if missing else
                     ("Artefakte vorhanden, Vergleich in diesem Werkzeug nicht "
                      "implementiert — separat umzusetzen"),
        })
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="spec_lint.py",
        description="Bau-Gate für docs/spec_v2 (Regeln aus CONVENTIONS.md).")
    ap.add_argument("--spec-dir", default=None,
                    help="Spec-Verzeichnis (Vorgabe: <repo>/docs/spec_v2)")
    ap.add_argument("--only", default=None,
                    help="nur diese Regeln, kommagetrennt: " + ",".join(RULES))
    ap.add_argument("--skip", default=None,
                    help="diese Regeln auslassen, kommagetrennt")
    ap.add_argument("--json", action="store_true",
                    help="Ausgabe als JSON")
    ap.add_argument("--selftest", action="store_true",
                    help="Selbsttest mit künstlichen Eingaben")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest(args.json)

    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(here)
    spec_dir = args.spec_dir or os.path.join(repo_root, "docs", "spec_v2")

    try:
        active = select_rules(args.only, args.skip)
        files = load_spec(spec_dir)
        findings = run_rules(files, active)
    except (OSError, ValueError, re.error) as exc:
        if args.json:
            print(json.dumps({"fehler": str(exc)}, ensure_ascii=False))
        else:
            sys.stderr.write("spec_lint: Werkzeugfehler: %s\n" % exc)
        return 2

    gates = check_v2_gates(repo_root)
    violations = [f for f in findings if f.severity == "verstoss"]
    hints = [f for f in findings if f.severity == "hinweis"]

    if args.json:
        print(json.dumps({
            "werkzeug": "spec_lint",
            "spec_dir": spec_dir,
            "dateien": len(files),
            "regeln": active,
            "verstoesse": [f.as_dict() for f in violations],
            "hinweise": [f.as_dict() for f in hints],
            "nicht_pruefbar": gates,
            "zusammenfassung": {
                "verstoesse": len(violations),
                "hinweise": len(hints),
                "nicht_pruefbar": len(gates),
            },
        }, ensure_ascii=False, indent=2))
    else:
        print("spec_lint: %d Dateien, Regeln: %s" % (len(files), ",".join(active)))
        for f in violations:
            print(f.as_text())
        for f in hints:
            print(f.as_text())
        for g in gates:
            print("[NICHT PRUEFBAR] %-26s %s" % (g["gate"], g["grund"]))
            print("%s  (%s)" % (" " * 43, g["quelle"]))
        print("Zusammenfassung: verstoesse=%d hinweise=%d nicht_pruefbar=%d"
              % (len(violations), len(hints), len(gates)))

    return 1 if violations else 0


# --------------------------------------------------------------------------
# Selbsttest
# --------------------------------------------------------------------------

# Ein minimaler, regelkonformer Spec-Satz. Jeder Fall im Selbsttest baut
# darauf auf und verletzt genau eine Regel.

CLEAN_CONVENTIONS = """# Konventionen

## 3. Evidenz

Marker-Tabelle.

## 8. Sprache

Deutsch.
"""

CLEAN_07 = """# 07 — PS-PL-Vertrag

## 1. Anforderungen

| Kennung | Inhalt |
|---|---|
| **R-07-01** | Der Vertrag ist die einzige Adressquelle. |

## 3. Detail-Spezifikation

### 3.1 Register

| Adresse | Name | Zugriff | Beschreibung |
|---|---|---|---|
| `0x0000` | `REG_ID` | RO | Kennung, Rücksetzwert fest. |
| `0x0004` | `REG_SLOT_CNT` | RO | Zähler `slot_cnt`, Sollwert 70 pro Sekunde. |

### 3.3 Mailbox

| Wort | Feld | Bedeutung |
|---|---|---|
| `W14` | `target_ts` | ETSI-Zeitschlitz 1..4, Rücksetzwert 0. |

## 5. Verifikation

| Kennung | Prüfung |
|---|---|
| **V-07-1** | Testbench liest `REG_ID`. |

## 6. Offene Punkte

**O-07-1 — Nichts offen.** Platzhalter.
"""

CLEAN_13 = """# 13 — SW-Architektur

## 1. Anforderungen

| Kennung | Inhalt |
|---|---|
| **R-13-01** | Genau eine Konfigurationsdatei. |

## 3. Detail-Spezifikation

### 3.7 Konfiguration

Genau eine Datei ist die Wahrheit: `cell.conf`.

| Gruppe | Beispielschlüssel | Verbraucher |
|---|---|---|
| Zellidentität | `MCC`, `MNC` | Broadcast |

### 3.8 Zähler

| Zähler | Bedeutung / Sollwert |
|---|---|
| `db_full_cnt` | abgewiesene Einfügeversuche. Soll 0 |

Der Vertrag steht in `07 §3.1`, das Register `REG_ID` wird gelesen
[CODE sw/tetra_hal.c:12].

Das Mailbox-Feld `W14.target_ts` (`07 §3.3`) trägt den Zeitschlitz.

## 5. Verifikation

| Kennung | Prüfung |
|---|---|
| **V-13-1** | Schlüssel `MCC` wird geprüft (R-13-01). |

## 6. Offene Punkte

**O-13-1 — Nichts offen.** Platzhalter. Siehe `07` O-07-1.
"""


def _write_clean(root):
    files = {
        "CONVENTIONS.md": CLEAN_CONVENTIONS,
        "07_PS_PL_CONTRACT.md": CLEAN_07,
        "13_SW_ARCHITECTURE.md": CLEAN_13,
    }
    for name, text in files.items():
        with open(os.path.join(root, name), "w", encoding="utf-8") as fh:
            fh.write(text)


#: (Regel, Beschreibung, Datei, Zusatztext). Jeder Fall muss genau die
#: genannte Regel auslösen.
FAIL_CASES = (
    ("marker", "MESS mit Werkzeugausgabe belegt", "13_SW_ARCHITECTURE.md",
     "\nDie Auslastung ist 42 % [MESS 2026-01-01 `utilization.rpt:7`].\n"),
    ("marker", "Beleg auf internes Gedächtnisziel", "13_SW_ARCHITECTURE.md",
     "\nDer Wert ist 11 [MESS 2026-01-01, project_nub_ber_noise_floor].\n"),
    ("marker", "unbekanntes Marker-Kürzel mit Belegform", "13_SW_ARCHITECTURE.md",
     "\nDer Wert ist 7 [MESSUNG 2026-01-01, Zähler].\n"),
    ("regaddr", "absolute Aperturadresse außerhalb 07", "13_SW_ARCHITECTURE.md",
     "\nDie Oberfläche liest `0x43C00230` direkt.\n"),
    ("regaddr", "Namensbindung REG_X = 0x…", "13_SW_ARCHITECTURE.md",
     "\nEs gilt `REG_ID = 0x0008` im Kernmodul.\n"),
    ("ids", "Kennung im falschen Kapitel definiert", "13_SW_ARCHITECTURE.md",
     "\n**O-99-4 — Falsches Kapitel.** Steht in 13.\n"),
    ("ids", "Kennung doppelt mit abweichendem Inhalt", "13_SW_ARCHITECTURE.md",
     "\n## 1. Anforderungen\n\n| Kennung | Inhalt |\n|---|---|\n"
     "| **R-13-01** | Etwas ganz anderes. |\n"),
    ("regaddr", "Tabellenzeile Registername + reine Adress-Zelle",
     "13_SW_ARCHITECTURE.md",
     "\n| Fenster (`REG_ALTLAST`) | `0x180`–`0x18C` | entfallen |\n|---|---|---|\n"),
    ("ids", "zitierte Kennung existiert nicht", "13_SW_ARCHITECTURE.md",
     "\nSiehe `07` R-07-77 für Einzelheiten.\n"),
    ("xref", "Verweis auf nicht existierende Datei", "13_SW_ARCHITECTURE.md",
     "\nEinzelheiten in `42_NICHT_DA §1.1`.\n"),
    ("xref", "Verweis auf nicht existierenden Abschnitt", "13_SW_ARCHITECTURE.md",
     "\nEinzelheiten in `07 §9.9`.\n"),
    ("dangling", "unbekannter Zähler", "13_SW_ARCHITECTURE.md",
     "\nDer Zähler `dbg_phantom_cnt` steigt pro Sekunde.\n"),
    ("dangling", "unbekanntes Register", "13_SW_ARCHITECTURE.md",
     "\nDie Software liest `REG_PHANTOM_STATS` beim Start.\n"),
    ("dangling", "unbekanntes Mailbox-Feld", "13_SW_ARCHITECTURE.md",
     "\nDas Feld `W14.phantom_id` trägt die Kennung.\n"),
    ("dangling", "unbekannter Konfigurationsschlüssel", "13_SW_ARCHITECTURE.md",
     "\nDer Schlüssel `PHANTOM_MODE` steht in `cell.conf`.\n"),
    ("verbote", "Crypto-Rekey-PDU erwähnt", "13_SW_ARCHITECTURE.md",
     "\nDie " + "OT" + "AR-PDU wird ausgewertet.\n"),
    ("verbote", "Logikanalysator-Kern empfohlen", "13_SW_ARCHITECTURE.md",
     "\nZur Verifikation wird ein ILA im FPGA eingesetzt und ausgelesen.\n"),
)

#: Fälle, die bestehen MÜSSEN (typische Fehlalarm-Quellen)
PASS_CASES = (
    ("marker", "Werkzeugausgabe korrekt als BUILD belegt",
     "\nDie Auslastung ist 42 % [BUILD 2026-01-01 `utilization.rpt:7`].\n"),
    ("marker", "Dateipfad enthält reference_/parse_reference_",
     "\nGemessen [GOLD `docs/reference_decode/dl_full.md:27`], Werkzeug\n"
     "[CODE scripts/parse_reference_decode.py:124].\n"),
    ("marker", "Zitatklammer ohne Belegform",
     "\nDas höchstwertige Bit `x[MSB]` und [ETR 300-1 S. 43: „Zitat\"].\n"),
    ("regaddr", "Protokoll-Infowort und Startwert",
     "\nDas AACH-Infowort `0x32CB` und der Startwert `0x4183F207`.\n"),
    ("regaddr", "AD9361-SPI-Register",
     "\nTX1 = `out_voltage0` → AD9361-SPI 0x073/0x074, Kanalwert `0x51`.\n"),
    ("regaddr", "Schwellwert mit Hexschreibweise in Tabellenzelle",
     "\n| Schwelle (`REG_ID`) | 13 (`0x0D`) | Beleg |\n|---|---|---|\n"),
    ("ids", "Rückverweis außerhalb der Definitionsabschnitte",
     "\n## 7. Anhang\n\n**R-13-01:** Die Datei ist die Wahrheit.\n"),
    ("dangling", "V1-Zitat eines entfallenen Registers",
     "\nV1 führt zusätzlich `REG_ALTLAST_CNT`, das entfallen ist.\n"),
    ("dangling", "Zähler mit [CODE]-Beleg ist ein Zitat",
     "\nDer Zähler `fe_cnt` existiert [CODE rtl/rx/x.v:12].\n"),
    ("verbote", "Verbot des Logikanalysators ist selbst kein Verstoß",
     "\nIn-Circuit-Debug-Kerne sind als Verifikationsmethode nicht zugelassen.\n"),
    ("verbote", "ILA-Block wird entfernt",
     "\nDer gesamte ILA-Block aus V1 entfällt ersatzlos.\n"),
    ("slots", "Zahl mit Tausendergruppen ist keine Slot-Nummer",
     "\nEin Slot 1 416 700 `clk_sys` lang, das ist kein Zählweisen-Problem.\n"),
    ("slots", "TS mit ETSI-konformer Nummer",
     "\nDer Verkehr liegt auf TS2 (ETSI) = `tn=1` (RTL).\n"),
)

#: Fälle, die einen HINWEIS auslösen müssen (heuristische Regel `slots`)
HINT_CASES = (
    ("slots", "TS-Nummer außerhalb der ETSI-Zählung",
     "\nDer Verkehr liegt auf TS0 und wird weitergereicht.\n"),
    ("slots", "tn-Wert außerhalb der RTL-Zählung",
     "\nDer Burst-Verteiler prüft `tn = 4` und verwirft.\n"),
    ("slots", "„Zeitschlitz 0\" mischt die Zählweisen",
     "\nDie Zuweisung landet in Zeitschlitz 0 des Rahmens.\n"),
)


def _run_case(root, target, extra):
    _write_clean(root)
    if extra:
        with open(os.path.join(root, target), "a", encoding="utf-8") as fh:
            fh.write(extra)
    files = load_spec(root)
    return run_rules(files, list(RULES))


def selftest(as_json=False):
    results = []
    ok = True
    with tempfile.TemporaryDirectory(prefix="spec_lint_selftest_") as root:
        # 0) Der saubere Satz muss ohne Verstoß durchlaufen.
        findings = _run_case(root, None, None)
        viol = [f for f in findings if f.severity == "verstoss"]
        passed = not viol
        ok &= passed
        results.append({
            "fall": "sauberer Referenz-Satz", "regel": "*",
            "erwartet": "kein Verstoß", "bestanden": passed,
            "gefunden": [f.as_text() for f in viol],
        })

        # 1) Jeder Fehlerfall muss genau seine Regel auslösen.
        for rule, desc, target, extra in FAIL_CASES:
            findings = _run_case(root, target, extra)
            hit = [f for f in findings
                   if f.severity == "verstoss" and f.rule == rule]
            other = [f for f in findings
                     if f.severity == "verstoss" and f.rule != rule]
            passed = bool(hit) and not other
            ok &= passed
            results.append({
                "fall": desc, "regel": rule,
                "erwartet": "Verstoss (%s)" % rule, "bestanden": passed,
                "gefunden": ([f.as_text() for f in hit] or ["KEIN TREFFER"]) +
                            ["FREMDTREFFER: " + f.as_text() for f in other],
            })

        # 2) Jeder Nicht-Fehlerfall muss sauber bleiben.
        for rule, desc, extra in PASS_CASES:
            findings = _run_case(root, "13_SW_ARCHITECTURE.md", extra)
            viol = [f for f in findings if f.severity == "verstoss"]
            passed = not viol
            ok &= passed
            results.append({
                "fall": desc, "regel": rule,
                "erwartet": "kein Verstoß", "bestanden": passed,
                "gefunden": [f.as_text() for f in viol],
            })

        # 2b) Heuristische Hinweise müssen anschlagen — als Hinweis, nicht
        #     als Verstoß.
        for rule, desc, extra in HINT_CASES:
            findings = _run_case(root, "13_SW_ARCHITECTURE.md", extra)
            hint = [f for f in findings
                    if f.severity == "hinweis" and f.rule == rule]
            viol = [f for f in findings if f.severity == "verstoss"]
            passed = bool(hint) and not viol
            ok &= passed
            results.append({
                "fall": desc, "regel": rule,
                "erwartet": "Hinweis (%s), kein Verstoß" % rule,
                "bestanden": passed,
                "gefunden": ([f.as_text() for f in hint] or ["KEIN HINWEIS"]) +
                            ["FREMDVERSTOSS: " + f.as_text() for f in viol],
            })

        # 3) Die Regelauswahl muss wirken.
        _write_clean(root)
        with open(os.path.join(root, "13_SW_ARCHITECTURE.md"), "a",
                  encoding="utf-8") as fh:
            fh.write("\nDer Zähler `dbg_phantom_cnt` steigt.\n")
        files = load_spec(root)
        with_rule = [f for f in run_rules(files, ["dangling"])
                     if f.severity == "verstoss"]
        without = [f for f in run_rules(files, select_rules(None, "dangling"))
                   if f.severity == "verstoss"]
        passed = bool(with_rule) and not without
        ok &= passed
        results.append({
            "fall": "--only/--skip schaltet die Regel wirklich ab",
            "regel": "dangling", "erwartet": "an: Treffer, aus: leer",
            "bestanden": passed,
            "gefunden": [f.as_text() for f in with_rule + without],
        })

    if as_json:
        print(json.dumps({"selftest": results,
                          "bestanden": ok,
                          "faelle": len(results)},
                         ensure_ascii=False, indent=2))
    else:
        for r in results:
            mark = "OK  " if r["bestanden"] else "FEHL"
            print("[%s] %-9s %s" % (mark, r["regel"], r["fall"]))
            if not r["bestanden"]:
                for g in r["gefunden"]:
                    print("        %s" % g)
        print("Selbsttest: %d Fälle, %s"
              % (len(results), "bestanden" if ok else "FEHLGESCHLAGEN"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
    except Exception as exc:  # Werkzeugfehler, nicht Spec-Fehler
        sys.stderr.write("spec_lint: interner Fehler: %r\n" % (exc,))
        sys.exit(2)
