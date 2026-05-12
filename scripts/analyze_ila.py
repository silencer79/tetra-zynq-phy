#!/usr/bin/env python3
"""
analyze_ila.py — ILA-Daten auswerten: AD9361 + TETRA-Sync

Liest die von Vivado exportierten CSV-Dateien aus und prüft:
1. Ob der AD9361 IQ-Daten liefert (dbg_adc_valid_i0_lvds)
2. Ob das RX-Frontend Daten weitergibt (dbg_rx_valid_lvds)
3. Ob ein TETRA-Sync-Burst gefunden wurde (dbg_sync_found_sys)
4. Ob der Sync stabil eingerastet ist (dbg_sync_locked_sys)
5. Ob DMA-Daten fließen (dbg_m_axis_tvalid_sys)

Usage:
    python3 scripts/analyze_ila.py [--lvds build/ila_lvds_data.csv] [--sys build/ila_sys_data.csv]
"""

import csv
import sys
import os
import argparse
from pathlib import Path

# ─── Farben für Terminal-Ausgabe ─────────────────────────────────────────────
GREEN  = "\033[92m"
YELLOW = "\033[93m"
RED    = "\033[91m"
CYAN   = "\033[96m"
RESET  = "\033[0m"
BOLD   = "\033[1m"

def ok(msg):    print(f"  {GREEN}✓{RESET}  {msg}")
def warn(msg):  print(f"  {YELLOW}⚠{RESET}  {msg}")
def fail(msg):  print(f"  {RED}✗{RESET}  {msg}")
def info(msg):  print(f"  {CYAN}→{RESET}  {msg}")


def load_ila_csv(path: str) -> tuple[list[str], list[dict]]:
    """Liest Vivado ILA CSV. Gibt (header_cols, rows) zurück."""
    if not os.path.exists(path):
        return [], []

    rows = []
    header = []
    with open(path, newline='', encoding='utf-8', errors='replace') as f:
        # Vivado-CSV hat manchmal Kommentar-Zeilen am Anfang
        reader = csv.reader(f)
        for row in reader:
            if not row:
                continue
            # Header-Zeile erkennen: enthält "Sample in Buffer" oder "Name"
            line = ','.join(row)
            if any(kw in line for kw in ["Sample in Buffer", "TRIGGER", "slot"]):
                header = [c.strip() for c in row]
                break
        # Datenzeilen lesen
        for row in reader:
            if not row:
                continue
            d = {}
            for i, col in enumerate(header):
                d[col] = row[i].strip() if i < len(row) else '0'
            rows.append(d)

    return header, rows


def find_signal(header: list[str], *keywords) -> str | None:
    """Findet Spaltenname der ersten Übereinstimmung."""
    for key in keywords:
        for col in header:
            if key.lower() in col.lower():
                return col
    return None


def count_transitions(rows: list[dict], col: str, from_val: str, to_val: str) -> int:
    """Zählt Flanken (from_val → to_val) in einer Spalte."""
    if not col or not rows:
        return 0
    count = 0
    prev = None
    for row in rows:
        val = row.get(col, '0').strip().lstrip('0b').lstrip('0x') or '0'
        # Normalisieren auf '0' oder '1'
        cur = '1' if (val not in ('0', '')) else '0'
        if prev is not None and prev == from_val and cur == to_val:
            count += 1
        prev = cur
    return count


def signal_stats(rows: list[dict], col: str) -> dict:
    """Gibt high_count, low_count, transitions(0→1) zurück."""
    if not col:
        return {'high': 0, 'low': 0, 'rising': 0, 'total': 0}
    high = 0
    low = 0
    rising = 0
    prev = None
    for row in rows:
        raw = row.get(col, '0').strip()
        # Vivado exportiert u.a. "1", "0", "1'b1", "H", etc.
        if raw in ('1', "1'b1", 'H', 'h', 'TRUE', 'true'):
            cur = 1
        elif raw.startswith('0x') or raw.startswith('0b'):
            cur = 1 if int(raw, 0) != 0 else 0
        else:
            try:
                cur = 1 if int(raw) != 0 else 0
            except ValueError:
                cur = 0

        if cur:
            high += 1
        else:
            low += 1
        if prev == 0 and cur == 1:
            rising += 1
        prev = cur

    return {'high': high, 'low': low, 'rising': rising, 'total': high + low}


def analyze_lvds(csv_path: str) -> bool:
    """Analysiert LVDS-Domain ILA (AD9361 Datenfluß). Gibt True zurück wenn OK."""
    print(f"\n{BOLD}=== LVDS-Domain: AD9361 IQ-Datenfluß ==={RESET}")
    print(f"  Datei: {csv_path}")

    header, rows = load_ila_csv(csv_path)
    if not rows:
        fail(f"Datei nicht gefunden oder leer: {csv_path}")
        warn("Mögliche Ursachen: ILA nicht getriggert, Timeout, oder FPGA nicht programmiert")
        return False

    info(f"{len(rows)} Samples geladen, {len(header)} Signale")

    # Signale finden
    adc_valid_col  = find_signal(header, "adc_valid", "dbg_adc_valid")
    rx_valid_col   = find_signal(header, "rx_valid",  "dbg_rx_valid")

    # ADC Valid
    if adc_valid_col:
        s = signal_stats(rows, adc_valid_col)
        ratio = s['high'] / s['total'] * 100 if s['total'] else 0
        if s['high'] > 0:
            ok(f"AD9361 liefert IQ-Daten: {s['high']}/{s['total']} Samples HIGH ({ratio:.1f}%)")
        else:
            fail(f"AD9361 liefert KEINE Daten: {adc_valid_col} immer LOW")
            warn("→ AD9361 nicht initialisiert? iio_attr-Befehle ausgeführt?")
            warn("→ LVDS-Verbindung OK? DATA_CLK vorhanden?")
            return False
    else:
        warn(f"Signal 'dbg_adc_valid' nicht in CSV gefunden (Spalten: {header[:5]}...)")

    # RX Valid (nach CIC/RRC-Decimation)
    if rx_valid_col:
        s = signal_stats(rows, rx_valid_col)
        if s['high'] > 0:
            ok(f"RX-Frontend aktiv: {s['high']}/{s['total']} Samples HIGH")
        else:
            warn(f"RX-Frontend ({rx_valid_col}): immer LOW — CIC/RRC noch nicht aktiv?")
    else:
        info("Signal 'dbg_rx_valid' nicht in CSV — ggf. in SYS-Domain")

    return True


def analyze_sys(csv_path: str) -> bool:
    """Analysiert SYS-Domain ILA (Sync + DMA). Gibt True wenn Sync gefunden."""
    print(f"\n{BOLD}=== SYS-Domain: TETRA Sync + DMA ==={RESET}")
    print(f"  Datei: {csv_path}")

    header, rows = load_ila_csv(csv_path)
    if not rows:
        fail(f"Datei nicht gefunden oder leer: {csv_path}")
        return False

    info(f"{len(rows)} Samples geladen, {len(header)} Signale")

    sync_found_col  = find_signal(header, "sync_found",  "dbg_sync_found")
    sync_locked_col = find_signal(header, "sync_locked", "dbg_sync_locked")
    fe_valid_col    = find_signal(header, "fe_valid",    "dbg_fe_valid")
    tr_valid_col    = find_signal(header, "tr_valid",    "dbg_tr_valid")
    demod_valid_col = find_signal(header, "demod_valid", "dbg_demod_valid")
    loopback_col    = find_signal(header, "loopback_en", "dbg_loopback")
    tvalid_col      = find_signal(header, "tvalid",      "dbg_m_axis_tvalid")
    tready_col      = find_signal(header, "tready",      "dbg_m_axis_tready")
    irq_col         = find_signal(header, "irq",         "dbg_o_irq")

    sync_ok = False

    # Loopback-Enable prüfen (häufige Fehlerquelle)
    if loopback_col:
        s = signal_stats(rows, loopback_col)
        if s['high'] > 0:
            ok(f"Loopback AKTIV (loopback_en=1 in {s['high']}/{s['total']} Samples)")
        else:
            fail("Loopback NICHT aktiv (loopback_en=0 dauerhaft)")
            warn("→ tetra_ctrl.sh loopback ausführen um CTRL[2]=LOOPBACK zu setzen")

    # RX Datapath: FE → TR → Demod
    print(f"\n  {CYAN}RX Datapath:{RESET}")
    # ILA-Fenster berechnen und erwartete Aktivitaetsraten ableiten
    # TETRA: fe_valid=72kHz (4x oversampled), tr/demod_valid=18kHz
    # Bei 100 MHz ILA-Takt: fe=0.072%, tr/demod=0.018%
    # Mit mindestens 1 Puls pro Fenster als Aktivitaets-Nachweis
    ILA_CLK = 100_000_000
    FE_RATE   = 72_000  # Hz — CIC+RRC Output
    TR_RATE   = 18_000  # Hz — Timing Recovery on-time samples
    DEM_RATE  = 18_000  # Hz — Demodulator dibits

    n_samples = len(rows)
    fe_exp  = max(1.0, n_samples * FE_RATE  / ILA_CLK)
    tr_exp  = max(0.5, n_samples * TR_RATE  / ILA_CLK)
    dem_exp = max(0.5, n_samples * DEM_RATE / ILA_CLK)

    if fe_valid_col:
        s = signal_stats(rows, fe_valid_col)
        ratio = s['high'] / s['total'] * 100 if s['total'] else 0
        # Aktiv wenn >= 30% des Erwartungswerts gesehen (stat. Variation bei kleinen Fenstern)
        if s['high'] >= fe_exp * 0.3:
            ok(f"RX Frontend aktiv (fe_valid): {s['high']}/{s['total']} HIGH ({ratio:.3f}%,  erwartet ~{fe_exp:.1f})")
        elif s['high'] > 0:
            warn(f"RX Frontend schwach (fe_valid): {s['high']}/{s['total']} ({ratio:.3f}%, erwartet ~{fe_exp:.1f}) — stat. Variation oder Signal zu schwach")
        else:
            fail(f"RX Frontend INAKTIV (fe_valid): 0/{s['total']} — kein Signal am RX-Eingang")
            warn("→ Loopback aktiviert? (tetra_ctrl.sh loopback) AD9361 läuft?")
    else:
        info("Signal 'dbg_fe_valid' nicht in CSV — ggf. neue Probes hinzufügen")

    if tr_valid_col:
        s = signal_stats(rows, tr_valid_col)
        ratio = s['high'] / s['total'] * 100 if s['total'] else 0
        if s['high'] >= tr_exp * 0.3:
            ok(f"Timing Recovery aktiv (tr_valid): {s['high']}/{s['total']} HIGH ({ratio:.4f}%, erwartet ~{tr_exp:.1f})")
        elif s['high'] > 0:
            warn(f"Timing Recovery: {s['high']}/{s['total']} HIGH — stat. Variation OK bei kleinem ILA-Fenster")
        else:
            fail("Timing Recovery INAKTIV (tr_valid=0) — kein Symbol-Output")
    else:
        info("Signal 'dbg_tr_valid' nicht in CSV")

    if demod_valid_col:
        s = signal_stats(rows, demod_valid_col)
        ratio = s['high'] / s['total'] * 100 if s['total'] else 0
        if s['high'] >= dem_exp * 0.3:
            ok(f"Demodulator aktiv (demod_valid): {s['high']}/{s['total']} HIGH ({ratio:.4f}%, erwartet ~{dem_exp:.1f})")
        elif s['high'] > 0:
            warn(f"Demodulator: {s['high']}/{s['total']} HIGH — stat. Variation OK bei kleinem ILA-Fenster")
        else:
            fail("Demodulator INAKTIV (demod_valid=0) — keine Dibits")
    else:
        info("Signal 'dbg_demod_valid' nicht in CSV")

    # Sync Found
    print()
    if sync_found_col:
        s = signal_stats(rows, sync_found_col)
        if s['rising'] > 0:
            ok(f"TETRA Sync-Burst gefunden! ({s['rising']} Detektionen, {s['high']} Samples HIGH)")
            sync_ok = True
        else:
            fail(f"TETRA Sync NICHT gefunden ({sync_found_col} immer LOW)")
    else:
        warn("Signal 'dbg_sync_found' nicht in CSV")

    # Sync Locked
    if sync_locked_col:
        s = signal_stats(rows, sync_locked_col)
        if s['high'] > 0:
            ratio = s['high'] / s['total'] * 100
            ok(f"Sync LOCKED: {s['high']}/{s['total']} Samples ({ratio:.1f}% der Aufzeichnung)")
        else:
            if sync_ok:
                warn("Sync gefunden aber nicht eingerastet — zu kurze Aufzeichnung oder Frequenzabweichung")
            else:
                fail("Sync NICHT locked")

    # DMA-Datenfluß
    if tvalid_col:
        s = signal_stats(rows, tvalid_col)
        if s['high'] > 0:
            ok(f"DMA-Stream aktiv (tvalid HIGH in {s['high']}/{s['total']} Samples)")
        else:
            info("DMA-Stream noch inaktiv (tvalid=0) — normal ohne Sync")

    if tready_col:
        s = signal_stats(rows, tready_col)
        if s['high'] > 0:
            info(f"DMA-Backpressure OK (tready HIGH in {s['high']} Samples)")
        else:
            warn("tready dauerhaft LOW — PS nimmt keine DMA-Daten entgegen")

    # IRQ
    if irq_col:
        s = signal_stats(rows, irq_col)
        if s['rising'] > 0:
            ok(f"IRQ: {s['rising']} Interrupts generiert")
        else:
            info("IRQ: 0 (kein Block abgeschlossen)")

    return sync_ok


def print_diagnosis(adc_ok: bool, sync_ok: bool, rx_freq: int):
    print(f"\n{BOLD}=== Diagnose & Nächste Schritte ==={RESET}")

    if not adc_ok:
        print(f"\n{RED}PROBLEM: AD9361 liefert keine Daten{RESET}")
        print("  1. SSH zum Board:  ssh root@192.168.2.183")
        print("  2. AD9361 prüfen:  iio_info | grep -A5 ad9361")
        print("  3. Samplerate:     iio_attr -d ad9361-phy in_voltage_sampling_frequency")
        print(f"  4. Neu init:       ./scripts/ad9361_init.sh --freq {rx_freq}")
        return

    if not sync_ok:
        print(f"\n{YELLOW}Sync nicht in diesem ILA-Fenster gefunden{RESET}")
        print(f"  ILA-Fenster: 4K Samples @ 100MHz = ~41 µs")
        print(f"  TETRA-Timeslot: 14.17 ms = 1.4M Takte → ILA sieht <0.3% eines Slots!")
        print(f"  → sync_found in 4K-Fenster statistisch sehr unwahrscheinlich!")
        print(f"")
        print(f"  Empfohlen — Schritt 1: STATUS-Register pollen (kein ILA nötig):")
        print(f"    ./scripts/tetra_ctrl.sh monitor")
        print(f"    (wartet auf SYNC_LOCKED=1 im STATUS-Register)")
        print(f"")
        print(f"  Falls nach 30s kein Lock (Schritt 2): ILA-Trigger auf sync_found:")
        print(f"    → Vivado HW Manager: Trigger auf 'dbg_sync_found_sys' rising edge")
        print(f"    → ILA wartet unbegrenzt bis Sync-Event auftritt")
        print(f"")
        print(f"  Falls kein Lock nach 60s (Schritt 3): Sync-Threshold senken:")
        print(f"    ./scripts/tetra_ctrl.sh write 0x0C 0x00000050  # 80 statt 200")
        return

    print(f"\n{GREEN}{BOLD}ERFOLG: TETRA-Signal empfangen und synchronisiert!{RESET}")
    print(f"  RX-Frequenz: {rx_freq/1e6:.3f} MHz")
    print(f"  Nächste Schritte:")
    print(f"  1. Kanal-Dekodierung aktivieren (scrambler, viterbi, DMA)")
    print(f"  2. ARM-Software starten: ssh root@192.168.2.183 './tetra_test_rx'")
    print(f"  3. Vollständige Messung: --ila-depth 4096 --timeout_ms 120000")


def main():
    parser = argparse.ArgumentParser(description="ILA-Daten analysieren")
    parser.add_argument("--lvds",    default="build/ila_lvds_data.csv", help="LVDS ILA CSV")
    parser.add_argument("--sys",     default="build/ila_sys_data.csv",  help="SYS ILA CSV")
    parser.add_argument("--freq",    type=int, default=430000000,       help="RX-Frequenz Hz")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    # Pfade relativ zum Projekt-Root auflösen
    script_dir = Path(__file__).parent
    proj_dir   = script_dir.parent

    lvds_path = args.lvds if os.path.isabs(args.lvds) else str(proj_dir / args.lvds)
    sys_path  = args.sys  if os.path.isabs(args.sys)  else str(proj_dir / args.sys)

    print(f"\n{BOLD}╔══════════════════════════════════════════╗")
    print(f"║  TETRA-ILA Analyse: tetra-zynq-phy      ║")
    print(f"╚══════════════════════════════════════════╝{RESET}")
    print(f"  RX-Frequenz: {args.freq / 1e6:.3f} MHz")

    adc_ok  = analyze_lvds(lvds_path)
    sync_ok = analyze_sys(sys_path)

    print_diagnosis(adc_ok, sync_ok, args.freq)

    # Exit-Code: 0 = Sync OK, 1 = kein Sync
    sys.exit(0 if sync_ok else 1)


if __name__ == "__main__":
    main()
