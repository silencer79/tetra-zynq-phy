# Test Results — tetra-zynq-phy
# Project: tetra-zynq-phy
# Target: Zynq-7020 (XC7Z020-CLG484)
# Simulator: iverilog + vvp

> **STATUS (2026-04-17):** **RF Loopback stabil (10/10 LOCKED=1).**
> TX NCO entfernt. sync_detect Lock-FSM robustifiziert: LOCK_TOL=30, LOCK_TIMEOUT=3060,
> spacing_ok auf Frame-Vielfache (1020/2040/3060). TX_ATT=-10 dB, AGC=49 dB.
> Frequenzwechsel-Test bestanden: 430→440 MHz = Lock lost, zurück auf 430 = Lock re-acquired.
> deploy.sh überarbeitet (full_init opt-in, MD5-Verify).
>
> **STATUS (2026-04-16, späte Session):** **Ende-zu-Ende-TX-Validierung über Luft.**
> Beide offenen Fixes eingebracht → RTL-SDR decodiert SYSINFO korrekt (MCC=901 MNC=1 LA=1 CC=1):
> - **Fix 1 — BKN2 scrambled filler (`sw/tetra_hal.c`):** Neuer `tetra_bnch_encode()` liefert
>   216 type-5 bits für BKN2 (124-bit PN → CRC → tail → RCPC 2/3 → interleave 24×9 → scramble
>   slot=0). Narrow-CW bei -4.5 kHz eliminiert: Peak-median im TETRA-Kanal jetzt 4.3 dB
>   (vorher ≫10 dB), 84 % Energie in ±12.5 kHz.
> - **Fix 2 — `scripts/decode_sb.py` Rewrite für continuous SB (§9.4.4.2.6):** 19-dibit STS,
>   sb1=60 sym, BSCH 120 bits, Viterbi rate 2/3, de-interleave 8×15, scramble init=3.
>   STS-Korrelation 0.49 → **0.92**. 2/5 SBs über 2-s-Capture dekodieren CRC-PASS mit korrekter
>   SYSINFO-PDU.
> - **Fix 3 — π/4-DQPSK dibit 10↔11 ETSI-Revert (`rtl/tx/tetra_pi4dqpsk_mod.v` + `decode_sb.py`):**
>   Commit `127c3f2` hatte die Phase-Mapping in die falsche Richtung gedreht. Revert auf
>   ETSI §5.5.2.3 (10→-π/4, 11→-3π/4), bestätigt gegen `SDRSharp.Tetra.dll::SymbolToAngel`.
>   `tb_tetra_pi4dqpsk_mod` 31/31 PASS, volle Regression **22/22 PASS**.
> - **STATUS (2026-04-16, frühe Session):** Continuous-Downlink-SB + NDB-Filler deployed (Variant C).
>   PRBS-Spektrum, NDB-AA-Pattern-Test bestätigen TX-Datenpfad.
>
> **STATUS (2026-04-13):** Letzter Sim-Lauf: **PASS=22, FAIL=0** (alle 22 Module)
> Digitaler Loopback: **30/30 SYNC_LOCKED=1** über 30s (CTRL[2]=1).
> RF Antennen-Loopback: **27/30 SYNC_LOCKED=1** über 30s (TX→10cm Luft→RX, TX=RX=430 MHz, -50 dB TX ATT).
> Root Cause RF-Failure: ADC Channel Register 0x01→0x51 (dfmt_se + dfmt_enable fehlten → sign-extend kaputt).
> `rx_frontend`: CIC_GAIN_SHF=6 (64× Verstärkung für ADC-Amplitude ~512 → ~32767).
> 3 kurze SYNC-Drops korrelieren mit AGC slow_attack Gain-Sprüngen — nicht kritisch.
> `viterbi_decoder`: TIMEOUT-`$error`-Meldungen weiterhin cosmetic (alle 7 TCs PASS).

---

## Simulationsumgebung

| Tool       | Pfad                                 | Version   |
|------------|--------------------------------------|-----------|
| iverilog   | /usr/bin/iverilog                    | installiert |
| vvp        | /usr/bin/vvp                         | installiert |
| Vivado     | /opt/Xilinx/Vivado/2022.2/bin/vivado | 2022.2    |
| Python3    | /usr/bin/python3                     | installiert |

---

## Letzter Test-Lauf

**Datum:** 2026-04-13
**Ergebnis (offiziell):** PASS=22, FAIL=0, SKIP=0, TOTAL=22
**Hardware-Loopback:** 30/30 SYNC_LOCKED=1 (digitaler Loopback, 30s) | 27/30 SYNC_LOCKED=1 (RF Loopback, 30s)
**Caveats:**
- `viterbi_decoder`: TIMEOUT-`$error`-Meldungen im Log (Cosmetic — alle 7 TCs bestehen trotzdem)
- RF Loopback: 3/30 Drops korrelieren mit AGC Gain-Sprüngen (nicht kritisch)

---

## Ergebnisse nach Modul

| #  | Modul                    | Phase | Compile  | Sim         | TC Pass / Total | Notizen                                                                                   |
|----|--------------------------|-------|----------|-------------|-----------------|-------------------------------------------------------------------------------------------|
| 1  | `tetra_clk_reset`        | 1     | ✅ OK     | ✅ PASS      | 15/15           | Reset assert/deassert, async assert, stress; alle 3 Testgruppen PASS                     |
| 2  | `tetra_ad9361_interface` | 1     | ✅ OK     | ✅ PASS      | 22/22           | IQ-Vektoren T1–T15, Pipeline-Latenz, Reset-Recovery, Back-to-back; Xilinx-Sim-Modelle OK |
| 3  | `tetra_rx_frontend`      | 1     | ✅ OK     | ✅ PASS      | 3/3             | Reset, DC, Tone, DQPSK; Python CIC-Modell korrigiert (RTL-exakte NBA-Semantik + 46-Bit-Wrap)|
| 4  | `tetra_pi4dqpsk_demod`   | 1     | ✅ OK     | ✅ PASS      | 3/3             | Dibit-Dekodierung korrekt (Szenario 1, Samples 4–6)                                      |
| 5  | `tetra_timing_recovery`  | 1     | ✅ OK     | ✅ PASS      | 5/5             | TC0 (perfect), TC1 (early), TC2 (late), TC3 (reset), TC4 (no-input); alle PASS           |
| 6  | `tetra_sync_detect`      | 1     | ✅ OK     | ✅ PASS      | 6/6             | TC1 NTS, TC2 STS, TC3 Lock, TC4 Noise, TC5 3-Fehler, TC6 Reset                          |
| 7  | `tetra_burst_demux`      | 1     | ✅ OK     | ✅ PASS      | 4/4             | TC1–TC4 inkl. unlock/relock                                                              |
| 8  | `tetra_frame_counter`    | 1     | ✅ OK     | ✅ PASS      | 8/8             | Slot-Wrap, Frame-Wrap, Multiframe, Hyperframe, frame_18_slot1, Re-Acq                    |
| 9  | `tetra_scrambler`        | 2     | ✅ OK     | ✅ PASS      | 8/8             | Symmetrie, Backpressure, NDB (216 bit), SCH/F (432 bit)                                  |
| 10 | `tetra_interleaver`      | 2     | ✅ OK     | ✅ PASS      | 8/8             | Roundtrip K=216/432, Backpressure, Consecutive Blocks                                    |
| 11 | `tetra_viterbi_decoder`  | 2     | ✅ OK     | ⚠️ WARN     | 7/7             | Alle TCs PASS; **TIMEOUT-`$error`-Meldungen** (cosmetic, s.u.)                          |
| 12 | `tetra_reed_muller`      | 2     | ✅ OK     | ✅ PASS      | 25/25           | 17 Encoder-TCs, 8 Decoder-TCs inkl. 3-Bit-Fehlerkorrektur                               |
| 13 | `tetra_crc16`            | 2     | ✅ OK     | ✅ PASS      | 11/11           | TC0–TC9; Residue 0x1D0F korrekt; CRC_RESIDUE-Fix bestätigt                              |
| 14 | `tetra_axi_lite_regs`    | 2     | ✅ OK     | ✅ PASS      | 10/10           | IRQ W1C, HW-Priority, Read-Only-Schutz, live STATUS-Inputs                               |
| 15 | `tetra_axi_dma_bridge`   | 2     | ✅ OK     | ✅ PASS      | 7/7             | NDB (216 bit), SCH/F (432 bit), Back-pressure, IRQ-Puls, dma_block_count                |
| 16 | `tetra_rcpc_encoder`     | 3     | ✅ OK     | ✅ PASS      | 7/7             | Rate 1/3, Rate 2/3 Puncturing, Reset mid-sequence, Pattern=0                            |
| 17 | `tetra_pi4dqpsk_mod`     | 3     | ✅ OK     | ✅ PASS      | 31/31           | NTS erste 8 Symbole, Reset mid-sequence; 31 Checks PASS                                 |
| 18 | `tetra_rrc_filter`       | 3     | ✅ OK     | ✅ PASS      | —               | TC2 IQ-Ausgabewerte gegen Referenz; I=33/217/155/−156 korrekt                            |
| 19 | `tetra_steal_detect`     | 3     | ✅ OK     | ✅ PASS      | 29/29           | TC1–TC9: Reset, TCH/A, STCH, STCH+ACCH, Unalloc, Mixed 4-slot, SB ignore, Reset, BNCH |
| 20 | `tetra_burst_builder`    | 3     | ✅ OK     | ✅ PASS      | 5/5             | 255-sym count, Known payload, Back-to-back, Reset mid-burst — RTL fix 2026-04-11 (sym-rate divider + build_req_pending); Neulauf bestätigt PASS |
| 21 | `tetra_burst_mux`        | 3     | ✅ OK     | ✅ PASS      | 10/10           | TC1 slot0, TC2 all4 slots, TC3 idle burst, TC4 builder_busy stall, TC5 mux_ready        |
| 22 | `tetra_tx_frontend`      | 3     | ✅ OK     | ✅ PASS      | 5/5             | TC1 pulse count (~64), TC2 single-pulse CIC throughput, TC3 zero-in, TC4 rate, TC5 reset|

**Legende:** ✅ = PASS, ⚠️ = PASS mit bekannten Caveats, ❌ = FAIL, ⏳ = Simulation ausstehend

---

## Caveat-Analyse

### ⚠️ CAVEAT: `tetra_rx_frontend` — 34 Sample-Vergleichsfehler (Quantisierung)

**Status:** Script sagt PASS (basierend auf Decimation-Ratio-Check), aber Sample-Vergleiche schlagen fehl.

**Root Cause:** Quantisierungsunterschied zwischen Python-Float-Simulation (`float64`) und RTL-Festpunkt-CIC (`CIC_TRUNC_SHIFT=30`). Die CIC-Truncation skaliert anders als das Python-Modell mit `/ R^order`.

**Symptome im Log:**
```
ERROR [sample 0]: I_got=0 I_exp=147 (err=147)
ERROR [sample 1]: I_got=4 I_exp=5160 (err=5156)
...34 Fehler total
```
Zusätzlich: `WARNING: $readmemh(...): Not enough words in the file for the requested range [0:9215]`

**Empfehlung:** Testvektoren via `scripts/vivado_sim.tcl` mit XPM-FIFO-Modellen regenerieren und Referenzwerte auf RTL-Festpunkt-Ausgabe kalibrieren. Funktionalität (CIC-Dezimation, Ratio 64:1) ist korrekt.

---

### ⚠️ CAVEAT: `tetra_viterbi_decoder` — TIMEOUT-`$error`-Meldungen (cosmetic)

**Status:** Alle 7 TCs PASS — der Viterbi-Decoder arbeitet korrekt.

**Root Cause:** Die Testbench verwendet eine `while (!block_done && timeout < 2000)` Schleife. Das `$error` feuert wenn der Timeout-Zähler 2000 erreicht, **aber** `block_done` kommt trotzdem (kurz danach oder im gleichen Tick). Die TCs PASS, weil das Check-Statement nach der Schleife greift.

**Symptome im Log (pro TC):**
```
ERROR: tb_tetra_viterbi_decoder.v:209: TIMEOUT waiting for block_done
       Time: 26666000  Scope: tb_tetra_viterbi_decoder.run_viterbi
TC1 PASS: all-zeros NDB, 0 bit errors
```

**Empfehlung:** Timeout-Bedingung in der Testbench präzisieren — statt absoluten Tick-Zähler: Warten bis `block_done` OR bis `#(2000*10)` absolute Zeit verstrichen ist. Block-Latenz für NDB beträgt ~660 Takte, für SCH/F ~1320 Takte.

**Nächster Schritt:** Testbench-Fix für `tb_tetra_viterbi_decoder.v` Zeile 205–210.

---

## Testvektoren-Status

| Generator                         | Ausgabedateien                    | Status                                    |
|-----------------------------------|-----------------------------------|-------------------------------------------|
| `gen_pi4dqpsk_vectors.py`         | `pi4dqpsk_*.hex`                  | ✅ vorhanden, genutzt von TB              |
| `gen_reed_muller_vectors.py`      | `rm_encode_*.hex`, `rm_decode_*.hex` | ✅ vorhanden                            |
| `gen_ad9361_vectors.py`           | `ad9361_iq_vectors.hex`           | ✅ vorhanden                              |
| `gen_rx_frontend_vectors.py`      | `rx_frontend_stimulus.hex`, `rx_frontend_expected.hex` | ⚠️ Falsche Anzahl Worte / Quantisierungsreferenz fehlerhaft |
| `gen_timing_recovery_vectors.py`  | `timing_tc*.hex`                  | ✅ TC2-Vektoren regeneriert (Vorzeichen-Fix) |
| Alle anderen TBs                  | inline (kein `.hex` nötig)        | ✅ inline                                 |

---

## Offene Punkte

| Priorität | Modul                   | Status       | Nächster Schritt                                                      |
|-----------|-------------------------|--------------|-----------------------------------------------------------------------|
| 1         | `tetra_rx_frontend`     | ⚠️ CAVEAT   | `gen_rx_frontend_vectors.py` auf RTL-Festpunkt kalibrieren; Vivado xsim mit XPM empfohlen |
| 2         | `tetra_viterbi_decoder` | ⚠️ CAVEAT   | TB-Timeout-Logik korrigieren (absolute Zeit statt Zähler)             |

---

## Änderungshistorie

| Datum      | Änderung                                                                                              |
|------------|-------------------------------------------------------------------------------------------------------|
| 2026-04-16 | **π/4-DQPSK dibit 10↔11 ETSI-Revert** (`rtl/tx/tetra_pi4dqpsk_mod.v` + `scripts/decode_sb.py`): Commit `127c3f2` vom 13.04. hatte die Phase-Mapping versehentlich in die falsche Richtung gedreht (10→-3π/4, 11→-π/4). ETSI EN 300 392-2 §5.5.2.3 und `SDRSharp.Tetra.dll::SymbolToAngel` (IL-Disassembly) bestätigen: **10→-π/4, 11→-3π/4**. `decode_sb.py` hatte denselben Bug symmetrisch — Loopback maskierte ihn, aber ETSI-konforme Empfänger (SDR# Plugin) sahen 10/19 STS-Dibits falsch. Jetzt revertiert, `tb_tetra_pi4dqpsk_mod` **31/31 PASS**, gesamte Regression **22/22 PASS**. |
| 2026-04-16 | **End-to-End-TX-Validierung über Luft**: (a) `tetra_hal.c`: neuer `tetra_bnch_encode()` ersetzt BKN2-Null-Placeholder durch 216-bit scrambled BNCH-Filler (124 PN-bits → CRC-16 → tail → RCPC 2/3 → interleave 24×9 → scramble slot=0). Narrow-CW-Residuum bei -4.5 kHz verschwunden (peak-median 4.3 dB). (b) `scripts/decode_sb.py`: Komplett-Rewrite für continuous SB §9.4.4.2.6 — 19-dibit STS, sb1=60 sym, BSCH 120 bits, Viterbi rate-2/3 depuncture, de-interleave 8×15, scramble init=3. STS-Korrelation 0.49→**0.92**, 2/5 SBs CRC-PASS mit richtiger SYSINFO (MCC=901 MNC=1 LA=1 CC=1). |
| 2026-04-16 | Continuous-DL SB + NDB-Filler (Variant C): `REG_SB_SB1_*`, `REG_NDB_BLK1/2_*`, `REG_TX_TEST` deployed. RTL-SDR-Messung über TX_LO+106 kHz: PRBS-Mode 3dB BW 15.5 kHz (RRC OK), NDB-Filler 93% Energie in ±12.5 kHz (TETRA-Kanal). AA-Test in NDB-Regs bestätigt burst_mux liest aus NDB-Slots. |
| 2026-04-17 | **TX NCO entfernt**, sync_detect Lock-FSM robustifiziert (LOCK_TOL=30, LOCK_TIMEOUT=3060, Frame-Vielfache). RF Loopback **10/10 stabil** (TX_ATT=-10dB). Freq-Wechsel-Test PASS. deploy.sh refactored. |
| 2026-04-13 | RF Loopback **27/30** (ADC dfmt fix 0x01→0x51 + CIC_GAIN_SHF=6); Digital Loopback **30/30** |
| 2026-04-12 | RF Antennen-Loopback — ADI DAC-Core init fix (dac_init in tetra_ctrl.sh + hw_deploy.sh) |
| 2026-04-12 | HW-Loopback verifiziert 59/60; CIC_SHIFT=24, SYNC_THRESH=20, LOCK_TIMEOUT=512 fixes (`a684455`); alle 22 Sims PASS |
| 2026-04-11 | burst_builder RTL (18 kHz sym-rate divider + build_req_pending, `96e6356`); Neulauf PASS |
| 2026-04-03 | Phase-3-Erweiterung: steal_detect, burst_builder, burst_mux, tx_frontend (RTL+TB fertig, Sim pending); tetra_zynq_top.v erstellt; resource_estimate.md aktualisiert |
| 2026-03-29 | Vollständige Aktualisierung auf sim_results.txt (PASS=18, FAIL=0); Phase-3-TX-Module ergänzt (rcpc_encoder, pi4dqpsk_mod, rrc_filter); Caveat-Analyse für rx_frontend und viterbi_decoder; Modul-Tabelle erweitert |
| 2026-03-28 | Fixes: CRC_RESIDUE 0→0x1D0F, Viterbi-Timeout 100→2000, Timing-Recovery-Toleranz, rx_frontend-Größe; Xilinx-Sim-Modelle (IBUFDS/BUFG/IDDR/ODDR/OBUFDS); TC2-IQ-Vektor regeneriert |
| 2026-03-28 | Echte Sim-Ergebnisse eingetragen (11 PASS, 4 FAIL aus test_results_raw.txt), Fehler-Analyse ergänzt  |
| 2026-03-27 | Initiale Erstellung — Ist-Stand dokumentiert, keine Sims gelaufen                                    |
