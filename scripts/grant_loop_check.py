#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""grant_loop_check.py — Auswertung des Aufschaukelungs-Tests (docs/spec_v2/14_VERIFICATION.md §3.9).

ZWECK
=====
Dieses Werkzeug ist der **Auswerteteil** des Aufschaukelungs-Tests. Es erzeugt keine
Messung: es liest eine Messreihe (Laststufen-Sweep) im unten dokumentierten JSON-Format,
berechnet die Schleifenverstaerkung G und urteilt ueber die acht Bestehens-Bedingungen aus
`14 §3.9.3` (Simulationsteil S3-D). Ist die Messreihe als Luftmessung gekennzeichnet
(`"part": "luft"`), werden stattdessen die acht Bedingungen des Luftteils `14 §3.9.4` (L8)
ausgewertet — die beiden Teile haben je einen eigenen Aufbau und je einen eigenen
Bedingungssatz; der Saettigungsnachweis des Sweeps ist auf einer Luftmessreihe gar nicht
erhebbar.

GELTUNGSBEREICH — was dieses Werkzeug NICHT tut
===============================================
Der Test selbst braucht die V2-Zuweisungs-Hardware (`06 §3.9`, `07 §3.1.6`) in Simulation
plus ein Endgeraete-Verhaltensmodell (`14 §3.9.3`). Beides existiert heute nicht. Vier der
acht Bedingungen sind ausserdem *grundsaetzlich* nicht aus einer Ratenmessreihe
entscheidbar, sondern brauchen einen Testbench-Nachweis:

  * Bedingung 4 (Haelfte b): `tb_ul_grant_bound`, Zufallsstimulus ueber 10 000 Frames
    (`06 §5.1` V-06-5)
  * Bedingung 6: Reservierung im selben Staging-Zyklus (`06 §3.9.3`, V-06-4
    `tb_ul_grant_window`)
  * Bedingung 7: `tb_ul_assign_content_independence` (`07 §5.1`)
  * Bedingung 8 (Haelfte b): `tb_grant_deadline` (`08 §5.1`)

Diese Bedingungen werden als "unentscheidbar" ausgewiesen, mit Angabe des fehlenden
Nachweises. Sie zaehlen NIE als bestanden. Ein Lauf ohne diese Nachweise endet deshalb mit
dem Gesamturteil UNVOLLSTAENDIG und Rueckgabewert 1 — das Gate ist dann nicht bestanden.

EINGABEFORMAT (JSON)
====================
Ein Objekt. Alle Zaehlerfelder sind **Zuwaechse ueber das Messfenster der jeweiligen
Laststufe** (Delta, nicht Absolutstand) — die AXI-Zaehler aus `06 §3.13` sind 16 bit und
saettigend, die Differenzbildung liegt beim Erzeuger der Messreihe. Simulationszaehler und
AXI-Zaehler liefern damit dasselbe Format.

{
  "meta": {                         optional, frei; wird nur ausgegeben
    "quelle": "sim | luft | BEISPIEL",
    "datum":  "2026-07-25",
    "kommentar": "..."
  },

  "part": "simulation" | "luft",    Vorgabe "simulation". Waehlt den Bedingungssatz:
                                    "simulation" -> S3D-1..8 (14 §3.9.3),
                                    "luft"       -> L8-1..8  (14 §3.9.4).

  "params": {                       alle optional; CLI-Argumente haben Vorrang
    "grant_repeat":   2,            GRANT_REPEAT, Vorgabe 2  (06 §3.12, 07 §3.1.6)
    "grant_gap":      4,            GRANT_GAP in TDMA-Frames, Vorgabe 4 (dito)
    "frame_ms":      56.67,         Dauer einer TDMA-Frame in ms (00 §2.1)
    "wt_broadcast":   2,            das von der EIGENEN Zelle ausgesendete WT.
                                    Pflicht fuer L8-6; es gibt keinen normativen
                                    Vorgabewert (14 §6 O-14-8), deshalb wird der Grenzwert
                                    aus DIESEM Feld nachgerechnet und nicht angenommen.
    "imm": 1, "nu": 3,              nur Dokumentation der Modell-Parametrierung
    "dlq_slots": 4                  Tiefe der Signalisierungs-Warteschlange (fuer L8-4)
  },

  "steps": [                        Laststufen-Sweep, mindestens 1 Eintrag
    {
      "label":        "Stufe 1",              Pflicht (Bezeichner der Laststufe)
      "duration_s":   60.0,                   Pflicht, > 0 — Laenge des Messfensters
      "ms_count":     1,                      Zahl gleichzeitig anfordernder Endgeraete(-Modelle)
      "suppress_ack": true,                   Durchlauf mit unterdrueckter Anmeldebestaetigung
                                              (Vorgabe false). G und Saettigung werden je
                                              suppress_ack-Gruppe getrennt ausgewertet.

      "grant_trigger_cnt":     175,           REG_GRANT_TRIGGER_CNT-Zuwachs
      "grant_emit_cnt":        180,           REG_GRANT_EMIT_CNT-Zuwachs
      "grant_late_cnt":          0,           REG_GRANT_LATE_CNT-Zuwachs (Fristzaehler, 08 R-08-03)
      "open_access_subslots": 1900,           Zahl der im Messfenster als OFFEN ausgewiesenen
                                              Zufallszugriffs-Unterschlitze (06 §3.9.3)
      "resv_slot_cnt":         190,           REG_RESV_SLOT_CNT-Zuwachs
      "mcch_slot_cnt":        1059,           REG_MCCH_SLOT_CNT-Zuwachs
      "dlq_drop_total":          0,           REG_DLQ_DROP_TOTAL-Zuwachs
      "dlq_drop_by_producer": {"mm":0,"cmce":0,"sds":0},
      "dlq_depth_p99":           1,           aus REG_DLQ_STATUS
      "req_cnt": 240, "ack_cnt": 0,           fuer req_per_ack
      "ms_retry_cnt_by_addr": {"1000001": 240},   Zufallszugriffe je Teilnehmeradresse
      "ms_retry_cnt_total":    240            optional; wird sonst aus by_addr gebildet
    }
  ],

  "evidence": {                     nur part="simulation". Testbench-/Nachweislage. Fehlt
                                    ein Schluessel oder ist
                                    sein status "offen", gilt die Bedingung als NICHT
                                    entscheidbar — niemals als bestanden.
    "tb_ul_grant_bound":                  {"status":"offen","quelle":"","datum":""},
    "resv_same_staging_cycle":            {"status":"offen","quelle":"","datum":""},
    "tb_ul_assign_content_independence":  {"status":"offen","quelle":"","datum":""},
    "tb_grant_deadline":                  {"status":"offen","quelle":"","datum":""}
  },                                status ∈ {"bestanden","fehlgeschlagen","offen"}

  "air_checks": {                   nur fuer part="luft" (14 §3.9.4 Bedingungen 7 und 8)
    "registration_after_release_s":  1.2,
    "restart_observed":              false,
    "req_cnt_after_release":         3,
    "ack_cnt_after_release":         3,
    "double_registration_within_5s_cnt": 0
  }
}

SCHLEIFENVERSTAERKUNG
=====================
G = Δ grant_emit_rate / Δ ms_retry_rate zweier benachbarter Laststufen (`14 §3.9.2`,
Bedingung 1). Sonderfall Δ ms_retry_rate = 0 (Division durch Null):

  * Δ grant_emit_rate ≤ 0  → Saettigung. Die Last hat die Wiederholrate nicht weiter
    erhoeht, die Zuweisungsrate ist nicht gestiegen. Das ist genau das erwuenschte
    Verhalten (Bedingung 2) und KEIN Fehler; G bleibt undefiniert und wird nicht gewertet.
  * Δ grant_emit_rate > 0  → die Zuweisungsrate steigt OHNE zusaetzlichen Stimulus. Das
    ist die Definition der Selbstverstaerkung (die Zuweisung zieht sich selbst nach,
    `06 §3.9.3`); formal G → +∞ > 1. Das wird als Verstoss gewertet.

RUECKGABEWERTE
==============
  0  alle ausgewerteten Bedingungen bestanden
  1  mindestens eine Bedingung verletzt ODER mindestens eine nicht entscheidbar
     (Gate nicht bestanden — "nicht geprueft" ist nicht "gruen")
  2  Werkzeugfehler (Datei fehlt, JSON kaputt, Feld mit falschem Typ, ungueltiges Argument)

AUFRUF
======
  grant_loop_check.py MESSREIHE.json [--json] [--grant-repeat N] [--grant-gap N]
                                     [--frame-ms F] [--wt N] [--g-max F] [--sat-ms N]
                                     [--sat-tol F] [--resv-max F] [--dlq-p99-max N]
  grant_loop_check.py --selftest [--json]

Beispiel-Messreihen: scripts/testdata/grant_loop_example.json (Simulation),
                     scripts/testdata/grant_loop_example_air.json (Luft).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys

# ---------------------------------------------------------------------------
# Vorgabewerte. Quelle jeweils in der Spezifikation, nicht hier festgeschrieben.
# ---------------------------------------------------------------------------
DEF_GRANT_REPEAT = 2       # 06 §3.12 / 07 §3.1.6 REG_UL_ASSIGN_CFG[3:1], Reset 2
DEF_GRANT_GAP = 4          # 06 §3.12 / 07 §3.1.6 REG_UL_ASSIGN_CFG[9:4], Reset 4
DEF_FRAME_MS = 56.67       # Dauer einer TDMA-Frame, 00 §2.1
DEF_G_MAX = 1.0            # 14 §3.9.3 Bedingung 1
DEF_SAT_MS = 4             # 14 §3.9.3 Bedingung 2: "ab Stufe 4"
DEF_SAT_TOL = 0.05         # Toleranz gegen Messrauschen beim Saettigungsnachweis
DEF_RESV_MAX = 0.05        # 14 §3.9.4 Bedingung 2 / 06 §5.4 Bedingung 2
DEF_DLQ_P99_MAX = 2        # 14 §3.9.4 Bedingung 4
DEF_DLQ_SLOTS = 4          # Tiefe der Signalisierungs-Warteschlange
DEF_REG_DELAY_S = 2.0      # 14 §3.9.4 Bedingung 7
DEF_MONO_TOL = 0.02        # Toleranz auf den Monotonie-Faktor (L8-5)

EPS_RATE = 1e-9            # Schwelle, ab der eine Ratendifferenz als "ungleich 0" gilt

ST_OK = "bestanden"
ST_FAIL = "verletzt"
ST_UNDEC = "unentscheidbar"

EV_OK = "bestanden"
EV_FAIL = "fehlgeschlagen"
EV_OPEN = "offen"
EV_VALID = (EV_OK, EV_FAIL, EV_OPEN)


class ToolError(Exception):
    """Werkzeugfehler — fuehrt zu Rueckgabewert 2."""


# ---------------------------------------------------------------------------
# Hilfsfunktionen: typsichere Feldzugriffe
# ---------------------------------------------------------------------------
def _num(obj, key, where, required=False, positive=False):
    """Zahlenfeld lesen. Fehlt es, wird None geliefert (-> unentscheidbar)."""
    if key not in obj or obj[key] is None:
        if required:
            raise ToolError("%s: Pflichtfeld '%s' fehlt" % (where, key))
        return None
    val = obj[key]
    if isinstance(val, bool) or not isinstance(val, (int, float)):
        raise ToolError("%s: Feld '%s' muss eine Zahl sein, ist %r" % (where, key, val))
    if positive and val <= 0:
        raise ToolError("%s: Feld '%s' muss > 0 sein, ist %r" % (where, key, val))
    return float(val)


def _bool(obj, key, where, default=None):
    if key not in obj or obj[key] is None:
        return default
    val = obj[key]
    if not isinstance(val, bool):
        raise ToolError("%s: Feld '%s' muss true/false sein, ist %r" % (where, key, val))
    return val


def _rate(cnt, duration_s):
    return None if cnt is None else cnt / duration_s


def _fmt(val, digits=3):
    if val is None:
        return "n/a"
    if isinstance(val, float) and math.isinf(val):
        return "inf"
    return ("%%.%df" % digits) % val


# ---------------------------------------------------------------------------
# Ergebnis-Objekte
# ---------------------------------------------------------------------------
class Cond(object):
    """Ergebnis einer einzelnen Bestehens-Bedingung."""

    def __init__(self, cid, title, status, detail, missing=None, location=None,
                 values=None):
        self.cid = cid
        self.title = title
        self.status = status
        self.detail = detail
        self.missing = missing or []
        self.location = location
        self.values = values or {}

    def as_dict(self):
        return {
            "id": self.cid,
            "title": self.title,
            "status": self.status,
            "detail": self.detail,
            "missing": self.missing,
            "location": self.location,
            "values": self.values,
        }


def combine(parts):
    """Teilergebnisse zu einem Bedingungs-Status zusammenfassen.

    Reihenfolge ist bewusst: ein Verstoss schlaegt eine Luecke, eine Luecke schlaegt
    ein Bestanden. Nur wenn ALLE Teile bestanden sind, ist die Bedingung bestanden.
    """
    if any(p == ST_FAIL for p in parts):
        return ST_FAIL
    if any(p == ST_UNDEC for p in parts):
        return ST_UNDEC
    return ST_OK


# ---------------------------------------------------------------------------
# Fundstellen im Eingabedokument (Datei:Zeile)
# ---------------------------------------------------------------------------
class Locator(object):
    def __init__(self, path, raw_text):
        self.path = path
        self.lines = raw_text.splitlines() if raw_text else []

    def _find(self, *needles):
        for idx, line in enumerate(self.lines, 1):
            if all(n in line for n in needles):
                return idx
        return 0

    def step(self, label):
        line = self._find('"label"', '"%s"' % label)
        return self._loc(line)

    def key(self, key):
        return self._loc(self._find('"%s"' % key))

    def _loc(self, line):
        return "%s:%d" % (self.path, line) if line else self.path


# ---------------------------------------------------------------------------
# Einlesen und Normalisieren
# ---------------------------------------------------------------------------
class Step(object):
    def __init__(self, raw, index):
        where = "steps[%d]" % index
        if not isinstance(raw, dict):
            raise ToolError("%s: muss ein Objekt sein" % where)
        self.index = index
        self.label = raw.get("label") or ("Stufe %d" % (index + 1))
        if not isinstance(self.label, str):
            raise ToolError("%s: 'label' muss eine Zeichenkette sein" % where)
        where = "steps[%d] (%s)" % (index, self.label)

        self.duration_s = _num(raw, "duration_s", where, required=True, positive=True)
        self.ms_count = _num(raw, "ms_count", where)
        self.suppress_ack = _bool(raw, "suppress_ack", where, default=False)

        self.trigger_cnt = _num(raw, "grant_trigger_cnt", where)
        self.emit_cnt = _num(raw, "grant_emit_cnt", where)
        self.late_cnt = _num(raw, "grant_late_cnt", where)
        self.open_subslots = _num(raw, "open_access_subslots", where)
        self.resv_slot_cnt = _num(raw, "resv_slot_cnt", where)
        self.mcch_slot_cnt = _num(raw, "mcch_slot_cnt", where)
        self.dlq_drop_total = _num(raw, "dlq_drop_total", where)
        self.dlq_depth_p99 = _num(raw, "dlq_depth_p99", where)
        self.req_cnt = _num(raw, "req_cnt", where)
        self.ack_cnt = _num(raw, "ack_cnt", where)

        drops = raw.get("dlq_drop_by_producer")
        if drops is None:
            self.dlq_drop_by_producer = None
        elif isinstance(drops, dict):
            self.dlq_drop_by_producer = {}
            for name, val in drops.items():
                if isinstance(val, bool) or not isinstance(val, (int, float)):
                    raise ToolError("%s: dlq_drop_by_producer['%s'] muss eine Zahl sein"
                                    % (where, name))
                self.dlq_drop_by_producer[str(name)] = float(val)
        else:
            raise ToolError("%s: 'dlq_drop_by_producer' muss ein Objekt sein" % where)

        by_addr = raw.get("ms_retry_cnt_by_addr")
        self.retry_by_addr = None
        if by_addr is not None:
            if not isinstance(by_addr, dict):
                raise ToolError("%s: 'ms_retry_cnt_by_addr' muss ein Objekt sein" % where)
            self.retry_by_addr = {}
            for addr, val in by_addr.items():
                if isinstance(val, bool) or not isinstance(val, (int, float)):
                    raise ToolError("%s: ms_retry_cnt_by_addr['%s'] muss eine Zahl sein"
                                    % (where, addr))
                self.retry_by_addr[str(addr)] = float(val)

        total = _num(raw, "ms_retry_cnt_total", where)
        if total is None and self.retry_by_addr is not None:
            total = float(sum(self.retry_by_addr.values()))
        self.retry_cnt_total = total

        # abgeleitete Raten
        self.emit_rate = _rate(self.emit_cnt, self.duration_s)
        self.trigger_rate = _rate(self.trigger_cnt, self.duration_s)
        self.retry_rate = _rate(self.retry_cnt_total, self.duration_s)

    def retry_rate_per_addr(self):
        if self.retry_by_addr is None:
            return None
        return dict((a, c / self.duration_s) for a, c in self.retry_by_addr.items())

    def resv_ratio(self):
        if self.resv_slot_cnt is None or self.mcch_slot_cnt is None:
            return None
        if self.mcch_slot_cnt <= 0:
            raise ToolError("steps[%d] (%s): mcch_slot_cnt muss > 0 sein"
                            % (self.index, self.label))
        return self.resv_slot_cnt / self.mcch_slot_cnt

    def as_dict(self):
        return {
            "label": self.label,
            "ms_count": self.ms_count,
            "suppress_ack": self.suppress_ack,
            "duration_s": self.duration_s,
            "grant_emit_rate_per_s": self.emit_rate,
            "grant_trigger_rate_per_s": self.trigger_rate,
            "ms_retry_rate_per_s": self.retry_rate,
            "resv_ratio": self.resv_ratio(),
            "dlq_drop_total": self.dlq_drop_total,
            "dlq_depth_p99": self.dlq_depth_p99,
            "grant_late_cnt": self.late_cnt,
        }


class Series(object):
    def __init__(self, doc, path, raw_text, cli_params):
        if not isinstance(doc, dict):
            raise ToolError("%s: Wurzelelement muss ein Objekt sein" % path)
        self.path = path
        self.loc = Locator(path, raw_text)
        self.meta = doc.get("meta") if isinstance(doc.get("meta"), dict) else {}

        part = doc.get("part", "simulation")
        if part not in ("simulation", "luft", "air"):
            raise ToolError("%s: 'part' muss 'simulation' oder 'luft' sein, ist %r"
                            % (path, part))
        self.part = "luft" if part in ("luft", "air") else "simulation"

        raw_steps = doc.get("steps")
        if not isinstance(raw_steps, list) or not raw_steps:
            raise ToolError("%s: 'steps' fehlt oder ist leer — ohne Messreihe gibt es "
                            "nichts auszuwerten" % path)
        self.steps = [Step(s, i) for i, s in enumerate(raw_steps)]

        fparams = doc.get("params") or {}
        if not isinstance(fparams, dict):
            raise ToolError("%s: 'params' muss ein Objekt sein" % path)
        self.params = self._merge_params(fparams, cli_params)
        self.wt_source = ("CLI" if cli_params.get("wt_broadcast") is not None
                          else ("Messreihe" if fparams.get("wt_broadcast") is not None
                                else None))

        self.evidence = self._read_evidence(doc.get("evidence"))
        air = doc.get("air_checks")
        if air is not None and not isinstance(air, dict):
            raise ToolError("%s: 'air_checks' muss ein Objekt sein" % path)
        self.air_checks = air or {}

    def _merge_params(self, fparams, cli):
        defaults = {
            "grant_repeat": DEF_GRANT_REPEAT,
            "grant_gap": DEF_GRANT_GAP,
            "frame_ms": DEF_FRAME_MS,
            "wt_broadcast": None,
            "imm": None,
            "nu": None,
            "dlq_slots": DEF_DLQ_SLOTS,
            "g_max": DEF_G_MAX,
            "sat_ms": DEF_SAT_MS,
            "sat_tol": DEF_SAT_TOL,
            "resv_max": DEF_RESV_MAX,
            "dlq_p99_max": DEF_DLQ_P99_MAX,
        }
        out = dict(defaults)
        for key, val in fparams.items():
            if key not in defaults:
                continue  # unbekannte Schluessel sind Dokumentation, kein Fehler
            if val is None:
                continue
            if isinstance(val, bool) or not isinstance(val, (int, float)):
                raise ToolError("params.%s muss eine Zahl sein, ist %r" % (key, val))
            out[key] = float(val)
        for key, val in cli.items():
            if val is not None:
                out[key] = float(val)
        for key in ("grant_repeat", "grant_gap", "frame_ms"):
            if out[key] is None or out[key] <= 0:
                raise ToolError("params.%s muss > 0 sein, ist %r" % (key, out[key]))
        return out

    def _read_evidence(self, raw):
        if raw is None:
            return {}
        if not isinstance(raw, dict):
            raise ToolError("%s: 'evidence' muss ein Objekt sein" % self.path)
        out = {}
        for key, val in raw.items():
            if not isinstance(val, dict):
                raise ToolError("evidence.%s muss ein Objekt mit 'status' sein" % key)
            status = val.get("status", EV_OPEN)
            if status not in EV_VALID:
                raise ToolError("evidence.%s: status %r unbekannt, erlaubt sind %s"
                                % (key, status, "/".join(EV_VALID)))
            out[str(key)] = {
                "status": status,
                "quelle": val.get("quelle", ""),
                "datum": val.get("datum", ""),
            }
        return out

    def emit_rate_limit(self):
        """Formale Obergrenze aus 14 §3.9.3 Bedingung 3 / 06 §5.4 Bedingung 1.

        GRANT_REPEAT / (GRANT_GAP x Frame-Dauer). Wird aus den Parametern gerechnet,
        nicht hartkodiert; Vorgabewerte 2 / 4 / 56,67 ms ergeben 8,82/s.
        """
        return self.params["grant_repeat"] / (
            self.params["grant_gap"] * self.params["frame_ms"] / 1000.0)

    def groups(self):
        """Steps nach suppress_ack gruppieren, je Gruppe nach Last aufsteigend sortiert.

        Der Sweep laeuft je Durchlauf-Art getrennt (14 §3.9.3: "zusaetzlich laeuft je
        Stufe ein Durchlauf mit unterdrueckter Anmeldebestaetigung"). G und Saettigung
        duerfen nicht ueber diese beiden Reihen hinweg gebildet werden.
        """
        out = {}
        for step in self.steps:
            out.setdefault(bool(step.suppress_ack), []).append(step)
        for key in out:
            out[key].sort(key=lambda s: (s.ms_count if s.ms_count is not None else 0,
                                         s.index))
        return out


# ---------------------------------------------------------------------------
# Schleifenverstaerkung
# ---------------------------------------------------------------------------
def loop_gain_pairs(series):
    """G je benachbartem Laststufen-Paar, getrennt nach suppress_ack-Gruppe."""
    pairs = []
    for suppress, steps in sorted(series.groups().items()):
        for lower, upper in zip(steps, steps[1:]):
            entry = {
                "group_suppress_ack": suppress,
                "from": lower.label,
                "to": upper.label,
                "d_ms_retry_rate": None,
                "d_grant_emit_rate": None,
                "G": None,
                "kind": None,
                "note": "",
                "location": series.loc.step(upper.label),
            }
            if lower.retry_rate is None or upper.retry_rate is None:
                entry["kind"] = "unbestimmt"
                entry["note"] = ("ms_retry_cnt_by_addr/ms_retry_cnt_total fehlt in "
                                 "mindestens einer der beiden Stufen")
                pairs.append(entry)
                continue
            if lower.emit_rate is None or upper.emit_rate is None:
                entry["kind"] = "unbestimmt"
                entry["note"] = "grant_emit_cnt fehlt in mindestens einer der beiden Stufen"
                pairs.append(entry)
                continue

            d_retry = upper.retry_rate - lower.retry_rate
            d_emit = upper.emit_rate - lower.emit_rate
            entry["d_ms_retry_rate"] = d_retry
            entry["d_grant_emit_rate"] = d_emit

            if abs(d_retry) <= EPS_RATE:
                # Division durch Null. Kein Fehler des Werkzeugs, sondern eine Aussage:
                # der Stimulus hat sich zwischen den Stufen nicht geaendert.
                if d_emit > EPS_RATE:
                    # Zuweisungsrate steigt ohne zusaetzlichen Stimulus -> die Zuweisung
                    # zieht sich selbst nach. Formal G -> +inf. Das ist der Kern der
                    # Aufschaukelung (06 §3.9.3) und wird als Verstoss gewertet.
                    entry["G"] = float("inf")
                    entry["kind"] = "selbstverstaerkung"
                    entry["note"] = ("Wiederholrate unveraendert, Zuweisungsrate steigt "
                                     "um %+.3f/s — G nicht endlich" % d_emit)
                else:
                    # Wiederholrate konstant, Zuweisungsrate nicht gestiegen: Saettigung.
                    entry["kind"] = "saettigung"
                    entry["note"] = ("Wiederholrate unveraendert (Δ=0), Zuweisungsrate "
                                     "Δ=%+.3f/s — Saettigung, G nicht definiert" % d_emit)
                pairs.append(entry)
                continue

            entry["G"] = d_emit / d_retry
            entry["kind"] = "berechnet"
            pairs.append(entry)
    return pairs


# ---------------------------------------------------------------------------
# Bedingungen 14 §3.9.3 (Simulationsteil S3-D)
# ---------------------------------------------------------------------------
def cond_s3d_1(series, pairs):
    g_max = series.params["g_max"]
    bad, undec, seen = [], [], []
    for p in pairs:
        if p["kind"] == "unbestimmt":
            undec.append("%s -> %s: %s" % (p["from"], p["to"], p["note"]))
        elif p["kind"] == "selbstverstaerkung":
            bad.append("%s [%s -> %s] G unendlich: %s"
                       % (p["location"], p["from"], p["to"], p["note"]))
        elif p["kind"] == "saettigung":
            seen.append("%s -> %s: Saettigung" % (p["from"], p["to"]))
        else:
            seen.append("%s -> %s: G=%s" % (p["from"], p["to"], _fmt(p["G"])))
            if p["G"] > g_max + 1e-12:
                bad.append("%s [%s -> %s] G=%s > %s"
                           % (p["location"], p["from"], p["to"], _fmt(p["G"]),
                              _fmt(g_max, 2)))
    if not pairs:
        return Cond("S3D-1", "Schleifenverstaerkung G <= 1 ueber alle Laststufen",
                    ST_UNDEC, "Messreihe enthaelt nur eine Laststufe je Durchlauf-Art — "
                    "ein Differenzenquotient braucht zwei benachbarte Stufen.",
                    missing=["mindestens 2 Laststufen je suppress_ack-Gruppe"],
                    location=series.loc.key("steps"))
    parts = []
    if bad:
        parts.append(ST_FAIL)
    if undec:
        parts.append(ST_UNDEC)
    parts.append(ST_OK)
    status = combine(parts)
    detail = "; ".join(bad) if bad else ("; ".join(seen) if seen else "")
    if undec and not bad:
        detail = "nicht berechenbare Paare: " + "; ".join(undec)
    return Cond("S3D-1", "Schleifenverstaerkung G <= %s ueber alle Laststufen" % _fmt(g_max, 2),
                status, detail,
                missing=(["ms_retry_cnt_* / grant_emit_cnt je Laststufe"] if undec else []),
                location=series.loc.key("steps"),
                values={"g_max": g_max, "pairs": len(pairs)})


def cond_s3d_2(series):
    sat_ms = series.params["sat_ms"]
    tol = series.params["sat_tol"]
    bad, checked, undec = [], 0, []
    for suppress, steps in sorted(series.groups().items()):
        heavy = [s for s in steps if s.ms_count is not None and s.ms_count >= sat_ms]
        if len(heavy) < 2:
            undec.append("suppress_ack=%s: nur %d Laststufe(n) mit ms_count >= %d"
                         % (suppress, len(heavy), int(sat_ms)))
            continue
        base = None
        for step in heavy:
            if step.emit_rate is None:
                undec.append("%s: grant_emit_cnt fehlt" % step.label)
                continue
            if base is None:
                base = step
                continue
            if step.ms_count <= base.ms_count:
                undec.append("%s -> %s: Last steigt nicht (ms_count)"
                             % (base.label, step.label))
                base = step
                continue
            checked += 1
            limit = base.emit_rate * (1.0 + tol)
            if step.emit_rate > limit + EPS_RATE:
                bad.append("%s [%s: %s/s -> %s: %s/s] Zuwachs %.1f%% > Toleranz %.1f%%"
                           % (series.loc.step(step.label), base.label,
                              _fmt(base.emit_rate), step.label, _fmt(step.emit_rate),
                              100.0 * (step.emit_rate / base.emit_rate - 1.0)
                              if base.emit_rate > 0 else float("inf"),
                              100.0 * tol))
            base = step
    if bad:
        return Cond("S3D-2", "Saettigung: grant_emit_rate waechst ab Stufe %d nicht mehr"
                    % int(sat_ms), ST_FAIL, "; ".join(bad),
                    location=series.loc.key("steps"),
                    values={"sat_ms": sat_ms, "tolerance": tol})
    if checked == 0:
        return Cond("S3D-2", "Saettigung: grant_emit_rate waechst ab Stufe %d nicht mehr"
                    % int(sat_ms), ST_UNDEC,
                    "Kein auswertbares Stufenpaar oberhalb der Saettigungsschwelle: "
                    + "; ".join(undec),
                    missing=["mindestens 2 Laststufen mit ms_count >= %d und "
                             "grant_emit_cnt" % int(sat_ms)],
                    location=series.loc.key("steps"),
                    values={"sat_ms": sat_ms})
    status = ST_UNDEC if undec else ST_OK
    detail = "%d Stufenpaar(e) oberhalb ms_count >= %d ohne Ratenzuwachs" % (checked, int(sat_ms))
    if undec:
        detail += "; nicht auswertbar: " + "; ".join(undec)
    return Cond("S3D-2", "Saettigung: grant_emit_rate waechst ab Stufe %d nicht mehr"
                % int(sat_ms), status, detail,
                missing=(["vollstaendige Stufenreihe >= %d" % int(sat_ms)] if undec else []),
                location=series.loc.key("steps"),
                values={"sat_ms": sat_ms, "tolerance": tol, "checked_pairs": checked})


def cond_emit_rate_limit(series, cid, title):
    """Gemeinsame Auswertung fuer 14 §3.9.3 Bedingung 3 und 14 §3.9.4 Bedingung 1."""
    limit = series.emit_rate_limit()
    bad, undec = [], []
    for step in series.steps:
        if step.emit_rate is None:
            undec.append("%s: grant_emit_cnt fehlt" % step.label)
            continue
        if step.emit_rate > limit + EPS_RATE:
            bad.append("%s [%s] grant_emit_rate=%s/s > %s/s"
                       % (series.loc.step(step.label), step.label,
                          _fmt(step.emit_rate), _fmt(limit)))
    formula = ("GRANT_REPEAT/(GRANT_GAP x Frame) = %g/(%g x %g ms) = %s/s"
               % (series.params["grant_repeat"], series.params["grant_gap"],
                  series.params["frame_ms"], _fmt(limit)))
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ST_OK]
    detail = "; ".join(bad) if bad else formula
    if undec and not bad:
        detail = formula + "; nicht auswertbar: " + "; ".join(undec)
    return Cond(cid, title, combine(parts), detail,
                missing=(["grant_emit_cnt je Laststufe"] if undec else []),
                location=series.loc.key("steps"),
                values={"limit_per_s": limit,
                        "grant_repeat": series.params["grant_repeat"],
                        "grant_gap": series.params["grant_gap"],
                        "frame_ms": series.params["frame_ms"]})


def cond_s3d_4(series):
    repeat = series.params["grant_repeat"]
    bad, undec = [], []
    for step in series.steps:
        loc = series.loc.step(step.label)
        if step.emit_cnt is None or step.trigger_cnt is None:
            undec.append("%s: grant_emit_cnt/grant_trigger_cnt fehlt" % step.label)
        elif step.emit_cnt > repeat * step.trigger_cnt + 1e-9:
            bad.append("%s [%s] grant_emit_cnt=%d > GRANT_REPEAT(%g) x "
                       "grant_trigger_cnt(%d) = %g"
                       % (loc, step.label, int(step.emit_cnt), repeat,
                          int(step.trigger_cnt), repeat * step.trigger_cnt))
        if step.trigger_cnt is None or step.open_subslots is None:
            undec.append("%s: open_access_subslots/grant_trigger_cnt fehlt" % step.label)
        elif step.trigger_cnt > step.open_subslots + 1e-9:
            bad.append("%s [%s] grant_trigger_cnt=%d > offene Zufallszugriffs-"
                       "Unterschlitze=%d"
                       % (loc, step.label, int(step.trigger_cnt),
                          int(step.open_subslots)))

    ev = series.evidence.get("tb_ul_grant_bound")
    missing = []
    if ev is None or ev["status"] == EV_OPEN:
        ev_status = ST_UNDEC
        missing.append("evidence.tb_ul_grant_bound (06 §5.1 V-06-5, Zufallsstimulus "
                       "ueber 10 000 Frames)")
    elif ev["status"] == EV_FAIL:
        ev_status = ST_FAIL
        bad.append("%s evidence.tb_ul_grant_bound = fehlgeschlagen"
                   % series.loc.key("tb_ul_grant_bound"))
    else:
        ev_status = ST_OK
    if undec:
        missing.append("grant_emit_cnt / grant_trigger_cnt / open_access_subslots")

    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ev_status]
    status = combine(parts)
    if bad:
        detail = "; ".join(bad)
    else:
        detail = "Ungleichungen aus der Messreihe eingehalten"
        rest = []
        if undec:
            rest.append("Messreihe unvollstaendig: " + "; ".join(undec))
        if ev_status == ST_UNDEC:
            rest.append("Testbench-Nachweis fehlt — nicht aus dieser Messreihe "
                        "entscheidbar")
        if rest:
            detail += "; " + "; ".join(rest)
    return Cond("S3D-4", "Formale Aufschaukelungs-Sperre: emit <= GRANT_REPEAT x trigger "
                "und trigger <= offene Unterschlitze (+ tb_ul_grant_bound)",
                status, detail, missing=missing, location=series.loc.key("steps"))


def cond_dlq_drop(series, cid, title):
    """14 §3.9.3 Bedingung 5 / 14 §3.9.4 Bedingung 3 — Verwuerfe strukturell 0."""
    bad, undec = [], []
    for step in series.steps:
        loc = series.loc.step(step.label)
        if step.dlq_drop_total is None and step.dlq_drop_by_producer is None:
            undec.append("%s: dlq_drop_total/dlq_drop_by_producer fehlt" % step.label)
            continue
        if step.dlq_drop_total is not None and step.dlq_drop_total != 0:
            bad.append("%s [%s] dlq_drop_total=%d (erwartet 0 — R-06-13 verletzt: die "
                       "Zuweisung benutzt die Warteschlange)"
                       % (loc, step.label, int(step.dlq_drop_total)))
        if step.dlq_drop_by_producer:
            for name, val in sorted(step.dlq_drop_by_producer.items()):
                if val != 0:
                    bad.append("%s [%s] dlq_drop[%s]=%d (erwartet 0)"
                               % (loc, step.label, name, int(val)))
        if step.dlq_drop_total is None:
            undec.append("%s: dlq_drop_total fehlt (nur Produzenten-Aufschluesselung)"
                         % step.label)
        elif step.dlq_drop_by_producer is None:
            undec.append("%s: dlq_drop_by_producer fehlt (Summe allein deckt 'je "
                         "Produzent' nicht ab)" % step.label)
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ST_OK]
    detail = "; ".join(bad) if bad else "alle Verwurfszaehler 0"
    if undec and not bad:
        detail += "; unvollstaendig: " + "; ".join(undec)
    return Cond(cid, title, combine(parts), detail,
                missing=(["dlq_drop_total und dlq_drop_by_producer je Laststufe"]
                         if undec else []),
                location=series.loc.key("steps"))


def cond_from_evidence(series, cid, title, key, what_is_missing):
    ev = series.evidence.get(key)
    loc = series.loc.key(key)
    if ev is None or ev["status"] == EV_OPEN:
        return Cond(cid, title, ST_UNDEC,
                    "nicht aus dieser Messreihe entscheidbar — %s" % what_is_missing,
                    missing=["evidence.%s" % key], location=loc)
    if ev["status"] == EV_FAIL:
        return Cond(cid, title, ST_FAIL,
                    "%s evidence.%s = fehlgeschlagen (%s)"
                    % (loc, key, ev.get("quelle") or "ohne Quellenangabe"),
                    location=loc)
    return Cond(cid, title, ST_OK,
                "Nachweis bestanden: %s %s" % (ev.get("quelle") or key,
                                               ev.get("datum") or ""),
                location=loc)


def cond_s3d_8(series):
    """Bedingung 8: kein Software-Umlauf im Antwort-Zeitpfad.

    Zwei Haelften: der Fristzaehler ist aus der Messreihe entscheidbar, der Nachweis
    "Zuweisungsbits liegen vor dem Slot-Puls vor" braucht tb_grant_deadline (08 §5.1).
    """
    bad, undec = [], []
    for step in series.steps:
        if step.late_cnt is None:
            undec.append("%s: grant_late_cnt fehlt" % step.label)
        elif step.late_cnt != 0:
            bad.append("%s [%s] grant_late_cnt=%d (erwartet 0, 08 R-08-03)"
                       % (series.loc.step(step.label), step.label, int(step.late_cnt)))
    ev = series.evidence.get("tb_grant_deadline")
    missing = []
    if ev is None or ev["status"] == EV_OPEN:
        ev_status = ST_UNDEC
        missing.append("evidence.tb_grant_deadline (08 §5.1: Zuweisungsbits vor dem "
                       "slot_pulse des Zielslots)")
    elif ev["status"] == EV_FAIL:
        ev_status = ST_FAIL
        bad.append("%s evidence.tb_grant_deadline = fehlgeschlagen"
                   % series.loc.key("tb_grant_deadline"))
    else:
        ev_status = ST_OK
    if undec:
        missing.append("grant_late_cnt je Laststufe")
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ev_status]
    if bad:
        detail = "; ".join(bad)
    else:
        detail = "Fristzaehler grant_late_cnt = 0 in allen Laststufen"
        if undec:
            detail = "Fristzaehler unvollstaendig: " + "; ".join(undec)
        if ev_status == ST_UNDEC:
            detail += "; Testbench-Nachweis der Sendezeitpunkt-Festigkeit fehlt"
    return Cond("S3D-8", "Kein Software-Umlauf im Antwort-Zeitpfad "
                "(grant_late_cnt = 0 + tb_grant_deadline)",
                combine(parts), detail, missing=missing,
                location=series.loc.key("steps"))


def eval_s3d(series):
    pairs = loop_gain_pairs(series)
    conds = [
        cond_s3d_1(series, pairs),
        cond_s3d_2(series),
        cond_emit_rate_limit(
            series, "S3D-3",
            "grant_emit_rate <= GRANT_REPEAT/(GRANT_GAP x Framedauer)"),
        cond_s3d_4(series),
        cond_dlq_drop(series, "S3D-5",
                      "dlq_drop = 0 (strukturell, die Zuweisung benutzt die "
                      "Warteschlange nicht)"),
        cond_from_evidence(
            series, "S3D-6",
            "Zuweisung markiert ihren eigenen Unterschlitz im selben Staging-Zyklus",
            "resv_same_staging_cycle",
            "Nachweis aus Simulation/Wellenform noetig (06 §3.9.3, V-06-4 "
            "tb_ul_grant_window); eine Ratenmessreihe zeigt den Staging-Zyklus nicht"),
        cond_from_evidence(
            series, "S3D-7",
            "Zuweisungs-Entscheidung unabhaengig von Decoder-Inhalten (R-00-02)",
            "tb_ul_assign_content_independence",
            "Testbench-Nachweis noetig (07 §5.1): Decoder-Schnittstellen mit "
            "Zufallswerten getrieben"),
        cond_s3d_8(series),
    ]
    return pairs, conds


# ---------------------------------------------------------------------------
# Bedingungen 14 §3.9.4 (Luftteil L8) — nur bei part="luft"
# ---------------------------------------------------------------------------
def cond_l8_2(series):
    limit = series.params["resv_max"]
    bad, undec = [], []
    for step in series.steps:
        ratio = step.resv_ratio()
        if ratio is None:
            undec.append("%s: resv_slot_cnt/mcch_slot_cnt fehlt" % step.label)
            continue
        if ratio > limit + 1e-12:
            bad.append("%s [%s] resv_ratio=%.2f%% > %.2f%%"
                       % (series.loc.step(step.label), step.label,
                          100.0 * ratio, 100.0 * limit))
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ST_OK]
    detail = "; ".join(bad) if bad else ("alle Stufen <= %.2f%% (Zielgroesse GOLD 0,71%%)"
                                         % (100.0 * limit))
    if undec and not bad:
        detail += "; unvollstaendig: " + "; ".join(undec)
    return Cond("L8-2", "resv_ratio <= %.0f %%" % (100.0 * limit), combine(parts), detail,
                missing=(["resv_slot_cnt / mcch_slot_cnt"] if undec else []),
                location=series.loc.key("steps"))


def cond_l8_4(series):
    limit = series.params["dlq_p99_max"]
    slots = series.params["dlq_slots"]
    bad, undec = [], []
    for step in series.steps:
        if step.dlq_depth_p99 is None:
            undec.append("%s: dlq_depth_p99 fehlt" % step.label)
            continue
        if step.dlq_depth_p99 > limit + 1e-12:
            bad.append("%s [%s] dlq_depth_p99=%g > %g von %g Plaetzen"
                       % (series.loc.step(step.label), step.label,
                          step.dlq_depth_p99, limit, slots))
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ST_OK]
    detail = "; ".join(bad) if bad else "alle Stufen <= %g von %g Plaetzen" % (limit, slots)
    if undec and not bad:
        detail += "; unvollstaendig: " + "; ".join(undec)
    return Cond("L8-4", "dlq_depth_p99 <= %g von %g" % (limit, slots),
                combine(parts), detail,
                missing=(["dlq_depth_p99"] if undec else []),
                location=series.loc.key("steps"))


def cond_l8_5(series):
    """Monotonie: Verdoppelte Anforderungsrate darf grant_emit_rate hoechstens
    verdoppeln (14 §3.9.4 Bedingung 5, 06 §5.4 Bedingung 4)."""
    cands = [s for s in series.steps if s.ms_count is not None]
    base = next((s for s in sorted(cands, key=lambda s: s.ms_count)
                 if s.ms_count == 1), None)
    dbl = next((s for s in sorted(cands, key=lambda s: s.ms_count)
                if s.ms_count == 2), None)
    if base is None or dbl is None:
        return Cond("L8-5", "Monotonie: doppelte Anforderungsrate -> hoechstens "
                    "doppelte Zuweisungsrate", ST_UNDEC,
                    "Messreihe enthaelt nicht beide Durchlaeufe (ein Endgeraet und zwei "
                    "Endgeraete)",
                    missing=["Laststufen mit ms_count = 1 und ms_count = 2"],
                    location=series.loc.key("steps"))
    if base.emit_rate is None or dbl.emit_rate is None or base.emit_rate <= 0:
        return Cond("L8-5", "Monotonie: doppelte Anforderungsrate -> hoechstens "
                    "doppelte Zuweisungsrate", ST_UNDEC,
                    "grant_emit_cnt fehlt oder ist 0 in einem der beiden Durchlaeufe",
                    missing=["grant_emit_cnt > 0 fuer ms_count = 1 und 2"],
                    location=series.loc.key("steps"))
    emit_ratio = dbl.emit_rate / base.emit_rate
    if base.retry_rate is not None and dbl.retry_rate is not None and base.retry_rate > 0:
        allowed = dbl.retry_rate / base.retry_rate
        src = "gemessenes Verhaeltnis der Wiederholrate"
    else:
        allowed = 2.0
        src = "Vorgabe 2,0 (Wiederholrate nicht gemessen)"
    if emit_ratio > allowed * (1.0 + DEF_MONO_TOL):
        return Cond("L8-5", "Monotonie: doppelte Anforderungsrate -> hoechstens "
                    "doppelte Zuweisungsrate", ST_FAIL,
                    "%s Zuweisungsrate x%s bei Anforderungsrate x%s (%s) — "
                    "ueberproportional, Signatur der Selbstverstaerkung"
                    % (series.loc.step(dbl.label), _fmt(emit_ratio),
                       _fmt(allowed), src),
                    location=series.loc.step(dbl.label),
                    values={"emit_ratio": emit_ratio, "allowed": allowed})
    return Cond("L8-5", "Monotonie: doppelte Anforderungsrate -> hoechstens "
                "doppelte Zuweisungsrate", ST_OK,
                "Zuweisungsrate x%s <= zulaessig x%s (%s)"
                % (_fmt(emit_ratio), _fmt(allowed), src),
                location=series.loc.step(dbl.label),
                values={"emit_ratio": emit_ratio, "allowed": allowed})


def cond_l8_6(series):
    """ms_retry_rate je Endgeraet <= 1/(WT x Framedauer), mit dem von der eigenen Zelle
    ausgesendeten WT. Es gibt keinen normativen Vorgabewert (14 §6 O-14-8) — fehlt das
    Feld, ist die Bedingung nicht entscheidbar; ein angenommenes WT waere eine erfundene
    Grenze."""
    wt = series.params.get("wt_broadcast")
    if wt is None:
        return Cond("L8-6", "ms_retry_rate je Endgeraet <= 1/(WT x Framedauer)",
                    ST_UNDEC,
                    "params.wt_broadcast fehlt. Der Grenzwert wird mit dem tatsaechlich "
                    "ausgesendeten WT nachgerechnet, nicht angenommen (14 §6 O-14-8).",
                    missing=["params.wt_broadcast (von der eigenen Zelle ausgesendetes WT)"],
                    location=series.loc.key("params"))
    if wt <= 0:
        raise ToolError("params.wt_broadcast muss > 0 sein, ist %r" % wt)
    limit = 1.0 / (wt * series.params["frame_ms"] / 1000.0)
    bad, undec = [], []
    for step in series.steps:
        rates = step.retry_rate_per_addr()
        if not rates:
            undec.append("%s: ms_retry_cnt_by_addr fehlt (Summe reicht nicht — die "
                         "Grenze gilt je Endgeraet)" % step.label)
            continue
        for addr, rate in sorted(rates.items()):
            if rate > limit + EPS_RATE:
                bad.append("%s [%s] Teilnehmer %s: %s/s > %s/s — Versuch wird oberhalb "
                           "der MAC-Schicht neu gestartet"
                           % (series.loc.step(step.label), step.label, addr,
                              _fmt(rate), _fmt(limit)))
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if undec else []) + [ST_OK]
    detail = "; ".join(bad) if bad else ("Grenze aus WT=%g: %s/s, von allen Endgeraeten "
                                         "eingehalten" % (wt, _fmt(limit)))
    if undec and not bad:
        detail += "; unvollstaendig: " + "; ".join(undec)
    return Cond("L8-6", "ms_retry_rate je Endgeraet <= 1/(WT x Framedauer) = %s/s"
                % _fmt(limit), combine(parts), detail,
                missing=(["ms_retry_cnt_by_addr je Laststufe"] if undec else []),
                location=series.loc.key("steps"),
                values={"wt": wt, "limit_per_s": limit,
                        "wt_source": series.wt_source})


def cond_l8_7(series):
    ac = series.air_checks
    loc = series.loc.key("air_checks")
    missing, bad = [], []
    delay = ac.get("registration_after_release_s")
    restart = ac.get("restart_observed")
    req = ac.get("req_cnt_after_release")
    ack = ac.get("ack_cnt_after_release")
    if delay is None:
        missing.append("air_checks.registration_after_release_s")
    elif not isinstance(delay, (int, float)) or isinstance(delay, bool):
        raise ToolError("air_checks.registration_after_release_s muss eine Zahl sein")
    elif delay > DEF_REG_DELAY_S:
        bad.append("%s Anmeldung erst nach %.2f s (> %.1f s)" % (loc, delay, DEF_REG_DELAY_S))
    if restart is None:
        missing.append("air_checks.restart_observed")
    elif not isinstance(restart, bool):
        raise ToolError("air_checks.restart_observed muss true/false sein")
    elif restart:
        bad.append("%s Endgeraet hat neu gestartet" % loc)
    if req is None or ack is None:
        missing.append("air_checks.req_cnt_after_release / ack_cnt_after_release")
    elif ack == 0 or req != ack:
        bad.append("%s req_per_ack = %s/%s (erwartet 1 Bestaetigung je Anforderung)"
                   % (loc, req, ack))
    parts = ([ST_FAIL] if bad else []) + ([ST_UNDEC] if missing else []) + [ST_OK]
    detail = "; ".join(bad) if bad else "Anmeldung <= %.1f s, kein Neustart, 1 Bestaetigung " \
                                        "je Anforderung" % DEF_REG_DELAY_S
    if missing and not bad:
        detail = "nicht entscheidbar: Ereignisfelder fehlen"
    return Cond("L8-7", "req_per_ack nach Aufheben der Unterdrueckung", combine(parts),
                detail, missing=missing, location=loc)


def cond_l8_8(series):
    loc = series.loc.key("air_checks")
    val = series.air_checks.get("double_registration_within_5s_cnt")
    if val is None:
        return Cond("L8-8", "Kein Endgeraet meldet sich binnen 5 s zweimal an", ST_UNDEC,
                    "nicht entscheidbar aus Ratenzaehlern — Ereignisliste der Anmeldungen "
                    "noetig (Abbruchbedingung 14 §3.8.2)",
                    missing=["air_checks.double_registration_within_5s_cnt"],
                    location=loc)
    if isinstance(val, bool) or not isinstance(val, (int, float)):
        raise ToolError("air_checks.double_registration_within_5s_cnt muss eine Zahl sein")
    if val != 0:
        return Cond("L8-8", "Kein Endgeraet meldet sich binnen 5 s zweimal an", ST_FAIL,
                    "%s %d Doppelanmeldung(en) binnen 5 s" % (loc, int(val)),
                    location=loc)
    return Cond("L8-8", "Kein Endgeraet meldet sich binnen 5 s zweimal an", ST_OK,
                "0 Doppelanmeldungen", location=loc)


def eval_l8(series):
    return [
        cond_emit_rate_limit(series, "L8-1", "grant_emit_rate <= formale Obergrenze"),
        cond_l8_2(series),
        cond_dlq_drop(series, "L8-3", "dlq_drop = 0 (Summe und je Produzent)"),
        cond_l8_4(series),
        cond_l8_5(series),
        cond_l8_6(series),
        cond_l8_7(series),
        cond_l8_8(series),
    ]


# ---------------------------------------------------------------------------
# Gesamtauswertung
# ---------------------------------------------------------------------------
def evaluate(series):
    # Die beiden Teile des Tests haben je eigene acht Bedingungen und je einen eigenen
    # Aufbau: §3.9.3 ist der Laststufen-Sweep in Simulation, §3.9.4 sind zwei
    # Luftdurchlaeufe (1 und 2 Endgeraete). Der Sweep-Nachweis (Saettigung ab Stufe 4)
    # ist auf einer Luftmessreihe gar nicht erhebbar — deshalb wird je Messreihe nur der
    # zugehoerige Bedingungssatz ausgewertet, nicht beide.
    if series.part == "luft":
        pairs = loop_gain_pairs(series)
        conds = eval_l8(series)
    else:
        pairs, conds = eval_s3d(series)
    n_ok = sum(1 for c in conds if c.status == ST_OK)
    n_fail = sum(1 for c in conds if c.status == ST_FAIL)
    n_undec = sum(1 for c in conds if c.status == ST_UNDEC)
    if n_fail:
        verdict, code = "VERLETZT", 1
    elif n_undec:
        verdict, code = "UNVOLLSTAENDIG", 1
    else:
        verdict, code = "BESTANDEN", 0
    return {
        "tool": "grant_loop_check.py",
        "spec": "docs/spec_v2/14_VERIFICATION.md §3.9",
        "source": series.path,
        "meta": series.meta,
        "part": series.part,
        "params": series.params,
        "limits": {
            "grant_emit_rate_max_per_s": series.emit_rate_limit(),
            "g_max": series.params["g_max"],
        },
        "steps": [s.as_dict() for s in series.steps],
        "loop_gain": pairs,
        "conditions": [c.as_dict() for c in conds],
        "summary": {"bestanden": n_ok, "verletzt": n_fail, "unentscheidbar": n_undec,
                    "gesamt": len(conds)},
        "verdict": verdict,
        "exit_code": code,
    }


MARK = {ST_OK: "OK ", ST_FAIL: "!! ", ST_UNDEC: " ? "}


def render_text(result, out):
    p = result["params"]
    out.write("Aufschaukelungs-Test — Auswertung (14 §3.9)\n")
    out.write("Quelle : %s\n" % result["source"])
    meta = result.get("meta") or {}
    if meta.get("quelle") or meta.get("datum"):
        out.write("Herkunft: %s%s\n"
                  % (meta.get("quelle", "?"),
                     (" | %s" % meta["datum"]) if meta.get("datum") else ""))
    out.write("Teil   : %s | Laststufen: %d\n"
              % ("Simulation (S3-D), Bedingungen 14 §3.9.3"
                 if result["part"] == "simulation"
                 else "Luft (L8), Bedingungen 14 §3.9.4", len(result["steps"])))
    out.write("Param  : GRANT_REPEAT=%g GRANT_GAP=%g Frame=%g ms -> Obergrenze %s/s"
              % (p["grant_repeat"], p["grant_gap"], p["frame_ms"],
                 _fmt(result["limits"]["grant_emit_rate_max_per_s"], 2)))
    if p.get("wt_broadcast") is not None:
        out.write(" | WT=%g" % p["wt_broadcast"])
    out.write("\n\n")

    out.write("Laststufen:\n")
    for step in result["steps"]:
        out.write("  %-12s ms=%-4s emit=%s/s trigger=%s/s retry=%s/s%s\n"
                  % (step["label"],
                     "n/a" if step["ms_count"] is None else "%g" % step["ms_count"],
                     _fmt(step["grant_emit_rate_per_s"], 2),
                     _fmt(step["grant_trigger_rate_per_s"], 2),
                     _fmt(step["ms_retry_rate_per_s"], 2),
                     " [ack unterdrueckt]" if step["suppress_ack"] else ""))
    out.write("\n")

    out.write("Schleifenverstaerkung G = d(grant_emit_rate)/d(ms_retry_rate):\n")
    if not result["loop_gain"]:
        out.write("  (kein benachbartes Stufenpaar)\n")
    for pair in result["loop_gain"]:
        out.write("  %-12s -> %-12s dRetry=%s/s dEmit=%s/s  G=%s  [%s]\n"
                  % (pair["from"], pair["to"], _fmt(pair["d_ms_retry_rate"], 2),
                     _fmt(pair["d_grant_emit_rate"], 2), _fmt(pair["G"]),
                     pair["kind"]))
    out.write("\n")

    out.write("Bedingungen:\n")
    for cond in result["conditions"]:
        out.write("  [%s] %-7s %s\n" % (MARK[cond["status"]], cond["id"], cond["title"]))
        if cond["detail"]:
            out.write("        %s\n" % cond["detail"])
        for miss in cond["missing"]:
            out.write("        fehlt: %s\n" % miss)
    s = result["summary"]
    out.write("\nErgebnis: %s (%d bestanden, %d verletzt, %d unentscheidbar von %d)\n"
              % (result["verdict"], s["bestanden"], s["verletzt"], s["unentscheidbar"],
                 s["gesamt"]))
    if s["unentscheidbar"]:
        out.write("Hinweis: unentscheidbare Bedingungen zaehlen NICHT als bestanden. "
                  "Das Gate ist erst mit vollstaendigem Nachweis bestanden.\n")


# ---------------------------------------------------------------------------
# Selbsttest
# ---------------------------------------------------------------------------
def _syn_step(label, ms_count, emit, trigger, retry, duration=60.0, late=0,
              dlq_drop=0, open_subslots=2000, resv=100, mcch=1059, p99=1,
              suppress=True, addr_prefix="100000"):
    by_addr = {}
    n = int(ms_count)
    per = float(retry) / n if n else 0.0
    for i in range(n):
        by_addr["%s%d" % (addr_prefix, i + 1)] = per
    return {
        "label": label,
        "duration_s": duration,
        "ms_count": ms_count,
        "suppress_ack": suppress,
        "grant_trigger_cnt": trigger,
        "grant_emit_cnt": emit,
        "grant_late_cnt": late,
        "open_access_subslots": open_subslots,
        "resv_slot_cnt": resv,
        "mcch_slot_cnt": mcch,
        "dlq_drop_total": dlq_drop,
        "dlq_drop_by_producer": {"mm": dlq_drop, "cmce": 0, "sds": 0},
        "dlq_depth_p99": p99,
        "req_cnt": retry,
        "ack_cnt": 0,
        "ms_retry_cnt_by_addr": by_addr,
    }


def _full_evidence(status=EV_OK):
    return {
        "tb_ul_grant_bound": {"status": status, "quelle": "sim/tb_ul_grant_bound",
                              "datum": "SELBSTTEST"},
        "resv_same_staging_cycle": {"status": status, "quelle": "sim/tb_ul_grant_window",
                                    "datum": "SELBSTTEST"},
        "tb_ul_assign_content_independence": {"status": status,
                                              "quelle": "sim/tb_ul_assign_ci",
                                              "datum": "SELBSTTEST"},
        "tb_grant_deadline": {"status": status, "quelle": "sim/tb_grant_deadline",
                              "datum": "SELBSTTEST"},
    }


def _clean_series():
    """Sauberer Sweep: G < 1, Saettigung ab Stufe 4, Rate unter der Obergrenze."""
    return {
        "meta": {"quelle": "SELBSTTEST", "kommentar": "synthetisch, keine Messung"},
        "part": "simulation",
        "params": {"grant_repeat": 2, "grant_gap": 4, "frame_ms": 56.67},
        "steps": [
            # emit/s: 3,00 5,50 8,00 8,00 8,00 ; retry/s: 4 8 16 32 64
            _syn_step("Stufe 1", 1, 180, 175, 240),
            _syn_step("Stufe 2", 2, 330, 320, 480),
            _syn_step("Stufe 3", 4, 480, 460, 960),
            _syn_step("Stufe 4", 8, 480, 465, 1920),
            _syn_step("Stufe 5", 16, 480, 468, 3840),
        ],
        "evidence": _full_evidence(),
    }


def _selftest_cases():
    cases = []

    # 1) MUSS bestehen
    cases.append(("sauberer Sweep (muss bestehen)", _clean_series(), "BESTANDEN", []))

    # 2) MUSS scheitern: G > 1
    doc = _clean_series()
    # retry/s 4 -> 8 (d=4), emit/s 3,00 -> 9,00 (d=6) => G = 1,5
    doc["steps"][1]["grant_emit_cnt"] = 540
    doc["steps"][1]["grant_trigger_cnt"] = 400
    doc["steps"][2]["grant_emit_cnt"] = 540
    doc["steps"][3]["grant_emit_cnt"] = 540
    doc["steps"][4]["grant_emit_cnt"] = 540
    cases.append(("Schleifenverstaerkung G > 1 (muss scheitern)", doc, "VERLETZT",
                  ["S3D-1"]))

    # 3) MUSS scheitern: keine Saettigung
    doc = _clean_series()
    doc["steps"][3]["grant_emit_cnt"] = 600   # 8,00 -> 10,00/s
    doc["steps"][4]["grant_emit_cnt"] = 720   # -> 12,00/s
    doc["steps"][3]["grant_trigger_cnt"] = 900
    doc["steps"][4]["grant_trigger_cnt"] = 1100
    cases.append(("keine Saettigung ab Stufe 4 (muss scheitern)", doc, "VERLETZT",
                  ["S3D-2", "S3D-3"]))

    # 4) MUSS scheitern: Verwuerfe der Signalisierungs-Warteschlange
    doc = _clean_series()
    doc["steps"][2]["dlq_drop_total"] = 7
    doc["steps"][2]["dlq_drop_by_producer"] = {"mm": 7, "cmce": 0, "sds": 0}
    cases.append(("dlq_drop != 0 (muss scheitern)", doc, "VERLETZT", ["S3D-5"]))

    # 5) MUSS scheitern: formale Obergrenze ueberschritten
    doc = _clean_series()
    for idx, cnt in enumerate([600, 700, 800, 800, 800]):
        doc["steps"][idx]["grant_emit_cnt"] = cnt
        doc["steps"][idx]["grant_trigger_cnt"] = 900
    cases.append(("grant_emit_rate ueber der formalen Obergrenze (muss scheitern)",
                  doc, "VERLETZT", ["S3D-3"]))

    # 6) MUSS scheitern: emit > GRANT_REPEAT x trigger
    doc = _clean_series()
    doc["steps"][0]["grant_trigger_cnt"] = 50   # 180 > 2 x 50
    cases.append(("grant_emit_cnt > GRANT_REPEAT x grant_trigger_cnt (muss scheitern)",
                  doc, "VERLETZT", ["S3D-4"]))

    # 7) MUSS scheitern: Fristzaehler ungleich 0
    doc = _clean_series()
    doc["steps"][4]["grant_late_cnt"] = 3
    cases.append(("grant_late_cnt != 0 (muss scheitern)", doc, "VERLETZT", ["S3D-8"]))

    # 8) Sonderfall Division durch Null, gutartig: Wiederholrate konstant,
    #    Zuweisungsrate konstant -> Saettigung, KEIN Fehler
    doc = _clean_series()
    doc["steps"][4]["ms_retry_cnt_by_addr"] = dict(
        (k, v) for k, v in zip(
            ["10000%02d" % i for i in range(1, 17)],
            [1920.0 / 16] * 16))
    cases.append(("Delta(retry)=0 und Delta(emit)=0 -> Saettigung (muss bestehen)",
                  doc, "BESTANDEN", []))

    # 9) Sonderfall Division durch Null, boesartig: Wiederholrate konstant,
    #    Zuweisungsrate steigt -> Selbstverstaerkung
    doc = _clean_series()
    doc["steps"][4]["ms_retry_cnt_by_addr"] = dict(
        (k, v) for k, v in zip(
            ["10000%02d" % i for i in range(1, 17)],
            [1920.0 / 16] * 16))
    doc["steps"][4]["grant_emit_cnt"] = 520     # 8,00 -> 8,67/s ohne mehr Stimulus
    doc["steps"][4]["grant_trigger_cnt"] = 500
    cases.append(("Delta(retry)=0 aber Delta(emit)>0 -> Selbstverstaerkung "
                  "(muss scheitern)", doc, "VERLETZT", ["S3D-1"]))

    # 10) Fehlende Nachweise duerfen NIE gruen sein
    doc = _clean_series()
    doc["evidence"] = {}
    cases.append(("ohne Testbench-Nachweise (darf nicht bestehen)", doc,
                  "UNVOLLSTAENDIG", []))

    # 11) Nachweis ausdruecklich fehlgeschlagen -> Verstoss
    doc = _clean_series()
    doc["evidence"]["tb_ul_assign_content_independence"]["status"] = EV_FAIL
    cases.append(("Inhaltsunabhaengigkeits-Nachweis fehlgeschlagen (muss scheitern)",
                  doc, "VERLETZT", ["S3D-7"]))

    # 12) Luftteil: Monotonie ueberproportional -> Verstoss
    doc = {
        "meta": {"quelle": "SELBSTTEST"},
        "part": "luft",
        "params": {"grant_repeat": 2, "grant_gap": 4, "frame_ms": 56.67,
                   "wt_broadcast": 2, "dlq_slots": 4},
        "steps": [
            _syn_step("1 Endgeraet", 1, 120, 130, 240, resv=5, p99=1),
            _syn_step("2 Endgeraete", 2, 400, 420, 480, resv=8, p99=1),
        ],
        "evidence": _full_evidence(),
        "air_checks": {"registration_after_release_s": 1.1, "restart_observed": False,
                       "req_cnt_after_release": 3, "ack_cnt_after_release": 3,
                       "double_registration_within_5s_cnt": 0},
    }
    cases.append(("Luftteil: ueberproportionaler Anstieg (muss scheitern)", doc,
                  "VERLETZT", ["L8-5"]))

    # 13) Luftteil sauber
    doc = {
        "meta": {"quelle": "SELBSTTEST"},
        "part": "luft",
        "params": {"grant_repeat": 2, "grant_gap": 4, "frame_ms": 56.67,
                   "wt_broadcast": 2, "dlq_slots": 4},
        "steps": [
            _syn_step("1 Endgeraet", 1, 120, 130, 240, resv=5, p99=1),
            _syn_step("2 Endgeraete", 2, 230, 250, 480, resv=8, p99=2),
        ],
        "evidence": _full_evidence(),
        "air_checks": {"registration_after_release_s": 1.1, "restart_observed": False,
                       "req_cnt_after_release": 3, "ack_cnt_after_release": 3,
                       "double_registration_within_5s_cnt": 0},
    }
    cases.append(("Luftteil sauber (muss bestehen)", doc, "BESTANDEN", []))

    # 14) Luftteil ohne ausgesendetes WT -> L8-6 nicht entscheidbar
    doc = json.loads(json.dumps(doc))
    del doc["params"]["wt_broadcast"]
    cases.append(("Luftteil ohne ausgesendetes WT (darf nicht bestehen)", doc,
                  "UNVOLLSTAENDIG", []))

    return cases


def run_selftest(as_json, out):
    results, ok_all = [], True
    for name, doc, want_verdict, want_failed_ids in _selftest_cases():
        raw = json.dumps(doc, indent=2, ensure_ascii=False)
        try:
            series = Series(json.loads(raw), "<selftest:%s>" % name, raw, {})
            result = evaluate(series)
        except ToolError as exc:
            results.append({"case": name, "ok": False,
                            "error": "unerwarteter Werkzeugfehler: %s" % exc})
            ok_all = False
            continue
        got_verdict = result["verdict"]
        failed_ids = [c["id"] for c in result["conditions"] if c["status"] == ST_FAIL]
        ok = got_verdict == want_verdict
        for cid in want_failed_ids:
            if cid not in failed_ids:
                ok = False
        if want_verdict == "BESTANDEN" and failed_ids:
            ok = False
        results.append({
            "case": name,
            "ok": ok,
            "verdict_expected": want_verdict,
            "verdict_got": got_verdict,
            "conditions_expected_violated": want_failed_ids,
            "conditions_violated": failed_ids,
        })
        ok_all = ok_all and ok

    if as_json:
        json.dump({"tool": "grant_loop_check.py", "mode": "selftest",
                   "cases": results, "ok": ok_all,
                   "exit_code": 0 if ok_all else 1},
                  out, indent=2, ensure_ascii=False)
        out.write("\n")
    else:
        out.write("Selbsttest grant_loop_check.py — %d Faelle\n" % len(results))
        for res in results:
            if "error" in res:
                out.write("  [!! ] %s: %s\n" % (res["case"], res["error"]))
                continue
            out.write("  [%s] %-62s erwartet=%-14s erhalten=%-14s%s\n"
                      % ("OK " if res["ok"] else "!! ", res["case"],
                         res["verdict_expected"], res["verdict_got"],
                         (" verletzt=%s" % ",".join(res["conditions_violated"]))
                         if res["conditions_violated"] else ""))
        out.write("\nSelbsttest: %s (%d/%d)\n"
                  % ("bestanden" if ok_all else "FEHLGESCHLAGEN",
                     sum(1 for r in results if r.get("ok")), len(results)))
    return 0 if ok_all else 1


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def build_parser():
    ap = argparse.ArgumentParser(
        prog="grant_loop_check.py",
        description="Auswertung des Aufschaukelungs-Tests (14 §3.9): Schleifenverstaerkung "
                    "und Bestehens-Bedingungen aus einer Messreihe.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Rueckgabewerte: 0 = bestanden, 1 = Verstoss oder nicht entscheidbar, "
               "2 = Werkzeugfehler.")
    ap.add_argument("series", nargs="?", help="Messreihe im JSON-Format")
    ap.add_argument("--json", action="store_true", dest="as_json",
                    help="Ergebnis maschinenlesbar als JSON")
    ap.add_argument("--selftest", action="store_true",
                    help="Selbsttest mit synthetischen Messreihen")
    ap.add_argument("--grant-repeat", type=float, default=None,
                    help="GRANT_REPEAT ueberschreiben (Vorgabe %d, 06 §3.12)"
                         % DEF_GRANT_REPEAT)
    ap.add_argument("--grant-gap", type=float, default=None,
                    help="GRANT_GAP in Frames ueberschreiben (Vorgabe %d, 06 §3.12)"
                         % DEF_GRANT_GAP)
    ap.add_argument("--frame-ms", type=float, default=None,
                    help="Dauer einer TDMA-Frame in ms (Vorgabe %g)" % DEF_FRAME_MS)
    ap.add_argument("--wt", type=float, default=None, dest="wt_broadcast",
                    help="von der Zelle ausgesendetes WT (nur Luftteil, L8-6)")
    ap.add_argument("--g-max", type=float, default=None,
                    help="Grenze der Schleifenverstaerkung (Vorgabe %g)" % DEF_G_MAX)
    ap.add_argument("--sat-ms", type=float, default=None,
                    help="ab welcher Endgeraetezahl Saettigung gilt (Vorgabe %d)"
                         % DEF_SAT_MS)
    ap.add_argument("--sat-tol", type=float, default=None,
                    help="relative Toleranz beim Saettigungsnachweis (Vorgabe %g)"
                         % DEF_SAT_TOL)
    ap.add_argument("--resv-max", type=float, default=None,
                    help="Grenze resv_ratio, Anteil 0..1 (Vorgabe %g)" % DEF_RESV_MAX)
    ap.add_argument("--dlq-p99-max", type=float, default=None,
                    help="Grenze dlq_depth_p99 (Vorgabe %d)" % DEF_DLQ_P99_MAX)
    return ap


def main(argv=None):
    ap = build_parser()
    args = ap.parse_args(argv)
    out = sys.stdout

    if args.selftest:
        if args.series:
            sys.stderr.write("Fehler: --selftest und Messreihe schliessen sich aus\n")
            return 2
        return run_selftest(args.as_json, out)

    if not args.series:
        sys.stderr.write("Fehler: keine Messreihe angegeben. "
                         "Aufruf: grant_loop_check.py MESSREIHE.json | --selftest\n")
        return 2

    cli_params = {
        "grant_repeat": args.grant_repeat,
        "grant_gap": args.grant_gap,
        "frame_ms": args.frame_ms,
        "wt_broadcast": args.wt_broadcast,
        "g_max": args.g_max,
        "sat_ms": args.sat_ms,
        "sat_tol": args.sat_tol,
        "resv_max": args.resv_max,
        "dlq_p99_max": args.dlq_p99_max,
    }

    try:
        with open(args.series, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        sys.stderr.write("Fehler: Messreihe nicht lesbar: %s\n" % exc)
        return 2
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        sys.stderr.write("Fehler: %s ist kein gueltiges JSON: %s\n" % (args.series, exc))
        return 2

    try:
        series = Series(doc, args.series, raw, cli_params)
        result = evaluate(series)
    except ToolError as exc:
        sys.stderr.write("Fehler: %s\n" % exc)
        return 2

    if args.as_json:
        json.dump(result, out, indent=2, ensure_ascii=False)
        out.write("\n")
    else:
        render_text(result, out)
    return result["exit_code"]


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(2)
