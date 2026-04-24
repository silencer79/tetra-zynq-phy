# OPERATIONS — Deploy, Test, Troubleshooting

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Zuletzt aktualisiert:** 2026-04-24

Ersetzt: `deployment_guide.md`, `deploy_workflow.md`, `test_results.md`,
`sim_results.txt`, `test_results_raw.txt`.

---

## 1. Quick Reference — Alltags-Kommandos

```bash
# Vollständiger Deploy (Build + Convert + Cross-Compile + Upload)
./scripts/deploy.sh

# Nur Vivado-Build (Bitstream rausfallen lassen, kein Upload)
./scripts/deploy.sh --build-only

# Re-Deploy bestehender .bit (Skip Vivado, SW neu bauen + upload)
./scripts/deploy.sh --no-build

# Full-Deploy + Board-Init + Daemons starten (empfohlen nach jedem RTL-Change)
./scripts/deploy.sh --no-build --init

# Board-Zustand prüfen
./scripts/tetra_ctrl.sh monitor
./scripts/tetra_ctrl.sh read 0x00       # CTRL
./scripts/tetra_ctrl.sh read 0x04       # STATUS
./scripts/tetra_ctrl.sh read 0x190      # MLE-Counter (accept | ul_req)

# Tail der Board-Logs
sshpass -p openwifi ssh root@192.168.2.180 'tail -20 /tmp/tetra_sysinfo.log'
sshpass -p openwifi ssh root@192.168.2.180 'tail -20 /tmp/tetra_ul_mon.log'
```

---

## 2. Deploy-Pipeline (scripts/deploy.sh)

```
Vivado Build → bootgen (.bit → .bit.bin) → Cross-Compile SW → SCP Upload → [optional: full_init + Daemons]
```

### Flags

| Flag | Wirkung | Zum Überspringen |
|------|---------|------------------|
| `(default)` | Alle 4 Schritte (Build+Convert+Compile+Upload) | — |
| `--build-only` | Nur Vivado (Schritt 1) | Convert/Compile/Upload |
| `--no-build` | Nutzt existierenden `build/tetra_zynq_phy.bit` | Vivado-Neubau |
| `--no-sw` | SW nicht neu bauen/hochladen | Schritt 3+4 SW-Teil |
| `--init` | Nach Upload: `full_init` + `tetra_sysinfo` + `tetra_ul_mon` starten | — |

### Was der Board-Init macht (`full_init`)

1. **Erster Bitstream-Load** via FPGA Manager
2. **AD9361-Init** (Sample-Rate 4.608 MSPS, LO, AGC slow_attack, FDD)
3. **Zweiter Bitstream-Load** (MMCM sieht jetzt stabilen DATA_CLK)
4. **AD9361 Re-Init** (stellt Register wieder her die Step 3 zurücksetzt)
5. **DAC-Core-Init** (RSTN + fabric data mode)
6. **ADC-Core-Init** (CH0/CH1 = 0x51 = enable + sign-extend + r1_mode=0)

**Warum 2× Bitstream:** Beim Kaltstart liefert der AD9361 noch kein DATA_CLK. Erster Load bringt Fabric hoch, zweiter konfiguriert die MMCM mit stabilem Clock-Input.

### MD5-Verify nach Upload

`deploy.sh` berechnet MD5 lokal, vergleicht gegen Board-Seite — bricht ab bei Mismatch. Debug: `md5sum build/tetra_zynq_phy.bit.bin` + `sshpass ... 'md5sum /lib/firmware/tetra_zynq_phy.bit.bin'`.

---

## 3. Board-Zugang

| Parameter | Wert |
|-----------|------|
| IP | `192.168.2.180` |
| User | `root` |
| Passwort | `openwifi` |
| SSH | `sshpass -p openwifi ssh root@192.168.2.180` |
| AXI-Base | `0x43C00000` (TETRA-PL), `0x79020000` (ADC), `0x79024000` (DAC) |

### Wichtige Pfade auf dem Board

| Pfad | Inhalt |
|------|--------|
| `/lib/firmware/tetra_zynq_phy.bit.bin` | FPGA Bitstream (persistent) |
| `/root/tetra_sysinfo` | SYSINFO/TX-Daemon (ARM binary) |
| `/root/tetra_ul_mon` | UL-MAC-ACCESS-Monitor-Daemon |
| `/tmp/tetra_sysinfo.log` | Sysinfo Log |
| `/tmp/tetra_ul_mon.log` | UL-mon Log (MS-RA-Decodes) |
| `/sys/bus/iio/devices/iio:device1/` | AD9361 IIO Sysfs |

### Kanonisches Control-Tool

`./scripts/tetra_ctrl.sh` (auf HOST) ist kanonisch — `/root/tetra_ctrl.sh` am Board ist broken (kein `sshpass`). Alle Board-Kommandos via Host-Script.

---

## 4. RF Loopback (Digital + Air-Gap)

```bash
./scripts/tetra_ctrl.sh rf_loopback [RX_Hz] [TX_Hz] [SYNC_THRESH] [TX_ATT_dB]
```

| Parameter | Default | Empfohlen | Beschreibung |
|-----------|---------|-----------|--------------|
| RX_Hz | 430000000 | 430000000 | RX LO Frequenz |
| TX_Hz | 430000000 | 430000000 | TX LO (MUSS = RX_Hz für Loopback) |
| SYNC_THRESH | 15 | 15 | Korrelator-Schwelle (max 19) |
| TX_ATT_dB | -50 | **-10** | TX-Dämpfung (0 bis -89 dB) |

### TX_ATT-Sweep (2026-04-17, 10 cm Luft-Loopback)

| TX_ATT | AGC | RSSI | Lock |
|--------|-----|------|------|
| -10 dB | 49 dB | 71 dB | ✅ stabil (10/10) |
| -30 dB | 56 dB | 76 dB | ⚠️ instabil |
| -50 dB | 73 dB | 98 dB | ❌ zu schwach |

### Sync-Lock-FSM-Parameter (`rtl/rx/tetra_sync_detect.v`)

| Parameter | Wert | Beschreibung |
|-----------|------|--------------|
| LOCK_TOL | 30 | ± Symbole Toleranz für Spacing-Check |
| LOCK_TIMEOUT | 3060 | Symbole ohne `sync_fire` → Unlock (3 Frames) |
| LOCK_COUNT | 4 | Konsekutive Hits für Lock-Akquisition |
| HOLDOFF | 220 | Symbole Sperrzeit nach `sync_fire` |

`spacing_ok` akzeptiert Frame-Vielfache: 1020 ± 30, 2040 ± 30, 3060 ± 30.

---

## 5. Testbench-Strategie

### 5.1 Unit-TBs — `iverilog` + `vvp`

**Runner:** `./run_all_tests.sh` kompiliert und simuliert alle TBs in `tb/` sequentiell.

Für einzelne Module:
```bash
iverilog -g2012 -o sim_out/<module> <RTL-Deps> tb/tb_<module>.v
vvp sim_out/<module>
```

### 5.2 Signalling/Session-TBs (manuell)

Neuere Module (MLE-FSM, MAC-RESOURCE-Builder, D-LOC-UPDATE-Encoder, DL-Signal-Queue/Scheduler) sind **nicht** in `run_all_tests.sh` — explizit aufrufen:

```bash
iverilog -g2012 -o sim_out/mac_res rtl/lmac/tetra_mac_resource_dl_builder.v tb/tb_mac_resource_dl_builder.v && vvp sim_out/mac_res

iverilog -g2012 -o sim_out/mle \
  rtl/lmac/tetra_mle_registration_fsm.v \
  rtl/lmac/tetra_active_session_table.v \
  rtl/lmac/tetra_mac_resource_dl_builder.v \
  rtl/lmac/tetra_d_location_update_encoder.v \
  rtl/lmac/tetra_sch_f_encoder.v \
  rtl/lmac/tetra_crc16.v \
  rtl/lmac/tetra_rcpc_encoder.v \
  rtl/lmac/tetra_scrambler.v \
  rtl/lmac/tetra_interleaver.v \
  tb/tb_mle_registration_fsm.v && vvp sim_out/mle
```

### 5.3 Vivado Behavioral Simulation (alt)

`scripts/vivado_sim.tcl` — PHY-Unit-TBs via Vivado xsim. Veraltet; iverilog ist aktuell der primäre Runner.

```bash
vivado -mode batch -source scripts/vivado_sim.tcl -tclargs <module_name>
```

---

## 6. Test-Status (Stand 2026-04-24)

### Letzte volle Regression

| Suite | Pass / Total | Datum |
|-------|--------------|-------|
| PHY-Unit-TBs (iverilog, 22 Module) | **22/22** | 2026-04-13 |
| Digitaler Loopback (CTRL[2]=1, 30 s) | **30/30 SYNC_LOCKED** | 2026-04-13 |
| RF Air-Loopback (10 cm, TX_ATT=-10dB) | **27/30 SYNC_LOCKED** | 2026-04-13 |
| LMAC-Signalling-TBs (manuell) | tb_mac_resource_dl_builder 6/6, tb_mle_registration_fsm 4/4, tb_d_location_update_encoder 16/16, tb_dl_signal_queue + scheduler + slot_content_mux je PASS | 2026-04-23 |
| UL RX Chain (tb_ul_demod_sch_hu, tb_ul_wav_chain) | 4/4 + 5/5 | 2026-04-22 |

### Bekannte Caveats

- **`tetra_viterbi_decoder.v`** (DL path, bit-reversed state conv): TIMEOUT-`$error`-Meldungen im Log — **cosmetic**, alle 7 TCs bestehen. Existiert ein ETSI-konformes UL-Pendant in `rtl/rx/tetra_ul_viterbi_r14.v`.
- **RF-Loopback 3/30 Drops** korrelieren mit AGC slow_attack Gain-Sprüngen — nicht kritisch für Protokoll-Tests.

### Raw-Dumps

Historische Sim-Läufe liegen archiviert in:
- `docs/sim_results.txt` (Summary)
- `docs/test_results_raw.txt` (Detail-Ausgabe pro Modul)

Beide nicht mehr aktiv gepflegt (`run_all_tests.sh` schreibt selbst neue Logs).

---

## 7. Live-Debugging — Board-seitig

### 7.1 Counter lesen (MLE/DL-Signal)

| Register | Bedeutung |
|----------|-----------|
| `0x190` | `{accept_cnt[31:16], ul_req_cnt[15:0]}` — MLE-FSM |
| `0x194` | `{drop_cnt[15:0]} + busy_sticky` |
| `0x198` | `{clear_cnt[31:16], sig_override_cnt[15:0]}` — Scheduler |
| `0x19C` | `REG_SIGNAL_TARGET_TN` (Default 0 = ETSI TN=1) |
| `0x1A0` | `REG_CELL_LA` (14-bit, default 1) |

```bash
./scripts/tetra_ctrl.sh read 0x190
```

### 7.2 UL-mon Live-Output

`tetra_ul_mon` Daemon pollt alle 10 ms die UL-MAC-ACCESS-AXI-Register und loggt jede CRC-OK RA-PDU:

```
[HH:MM:SS] #<count> pdu=0 fill=0 enc=0 ack=0 at=2 ssi=<event_label> raw=<23-hex 92-bit payload>
```

Decode-Tool für das Raw-Feld:
```bash
python3 scripts/decode_ul_raw.py <hex-blob>
# oder direkt vom Board:
python3 scripts/decode_ul_raw.py --board --last 5
```

### 7.3 DL on-air verifizieren

```bash
# Per RTL-SDR oder HackRF 60s-Capture auf DL-LO-Frequenz, dann:
python3 scripts/decode_dl.py --sr 250000 <capture.wav> --max-bursts 3000 [-v]
```

Für auto-offset-Failure (korrelation < 0.9): manuell Offset setzen —
`--offset -96625` (typischer SDR#-Offset für unser LO).

### 7.4 tetra-kit als zweiter Decoder

`scripts/wav_to_tkbits.py` konvertiert unsere WAVs in tetra-kit-kompatibles Input-Format. tetra-kit (externes Tool) lockt unabhängig auf unsere DL (0 Sync-Loss in 35 s, Ref 2026-04-20) und kann als zweiter Decoder dienen wenn `decode_dl.py` zu streng ist.

---

## 8. Troubleshooting

### Board crasht bei `full_init`
Physisch resetten. Bitstream bleibt auf `/lib/firmware/` (persistent). Erneut `full_init` versuchen — der zweite Versuch klappt fast immer.

### SYNC_LOCKED=0 trotz `corr_peak=19/19`
- `tetra_sysinfo` läuft? → `pgrep tetra_sysinfo`
- TX_ATT zu hoch? → `-10 dB` testen
- ADC-Core OK? → `dmesg | grep ad9361` (kein "Tuning RX FAILED")

### AD9361 IIO-Device nicht gefunden
- Device ist `iio:device1` (nicht device0, das ist XADC)
- `cat /sys/bus/iio/devices/iio:device1/name` → `ad9361-phy`

### decode_dl.py "Failed to acquire cell"
- Zuerst `--offset <manuell>` versuchen (typisch −96625 Hz für unser SDR#-Setup). Auto-Offset kann bei schwachem Signal schlechte Schätzung wählen.
- Signal-Stärke prüfen: `python3 -c "import wave; w=wave.open('<file>','rb'); ..."` — avg_pwr/peak_pwr im WAV. Peak/avg unter 50× = zu schwach.

### Timing-Violation im Vivado-Build
Bisherige Builds mit WNS bis −0.3 ns hatten on-air keinen Impact. Für Production-Fixes: Vivado-Strategy wechseln (`Performance_Explore`) — ca. +30 min Build-Zeit, oft schließt damit.

---

## 9. Deploy-Historie (Eskalationen)

| Datum | Bitstream-MD5 | Key-Änderung | On-air OK? |
|-------|---------------|--------------|-----------|
| 2026-04-23 21:58 | `ef75722f…` | Bug #7 (MAC-Header 3-bit shift) | ✅ decode_dl zeigt `MLE disc=MM` |
| 2026-04-23 22:15 | `a37e818b…` | Bug #8 (LocAccType echoed) | ✅ decode_dl zeigt `LocAccType=3 ITSI attach` |
| 2026-04-23 22:44 | `c656c9b5…` | Bug #9 (FCS osmo-style TL-SDU-only + pre-shift) | ✅ on-air FCS=0xB0A53869 matched osmo |

Offen: MTP3550-Registration trotz aller Fixes. Nächste Iteration s. `ARCHITECTURE.md` / `PROTOCOL.md`.

---

## 10. Script-Inventar

| Script | Zweck |
|--------|-------|
| `scripts/deploy.sh` | Build + Convert + Compile + Upload (+ optional Init) |
| `scripts/tetra_ctrl.sh` | Board-Steuerung (full_init, rf_loopback, monitor, read, write) |
| `scripts/ad9361_init.sh` | AD9361 stand-alone-Init (wird von full_init aufgerufen) |
| `scripts/decode_dl.py` | DL-Capture Decoder (MAC/LLC/MLE/MM-Parser) |
| `scripts/decode_ul.py` | UL-RA-Capture Decoder (41/42 CRC-Pass auf Live-Traces) |
| `scripts/decode_ul_raw.py` | Raw-Hex-Decoder für `tetra_ul_mon.log` Einträge |
| `scripts/wav_to_tkbits.py` | WAV → tetra-kit-Input-Format |
| `scripts/gold_schedule.py` | TX-Schedule-Generator (Gold-Preset-Loader) |
| `scripts/gen_sch_f_tv.py` | SCH/F-Test-Vektor-Generator (Python-Reference für TB-Goldens) |
| `scripts/verify_sb1_encoder.py` | BSCH-Encoder-Referenz (CRC16 + conv_enc + puncture) |
| `scripts/verify_sch_hu_decode.py` | SCH/HU-Decode-Reference (für UL RA) |
| `scripts/run_all_tests.sh` | Alle iverilog-TBs in einem Rutsch |
| `scripts/vivado_sim.tcl` | Vivado-xsim-Runner (alt, selten genutzt) |

---

## 11. Referenzen

- `ARCHITECTURE.md` — RTL/SW-Stack + Modul-Status
- `HARDWARE.md` — Board-Setup, AD9361, AXI-Regs, CDC, Timing
- `PROTOCOL.md` — TETRA-Protokoll, ETSI-Referenz, bluestation-Vergleich
- `.ralph/chat.md` — Kevin ↔ Ralph Arbeits-Kanal (separat)
