# Deployment Workflow — TETRA PHY on LibreSDR

**Last Updated:** 2026-04-17

---

## Overview

Deploy pipeline from Vivado source to running TETRA basestation on LibreSDR.

```
Vivado Build → bootgen (.bit → .bit.bin) → Cross-Compile SW → SCP Upload → full_init → RF Loopback
```

**Empfohlen:** `scripts/deploy.sh` automatisiert Build + Convert + Compile + Upload.

---

## Quick Reference

```bash
# Full pipeline: Build + Convert + Compile + Upload
./scripts/deploy.sh

# Skip Vivado build (use existing .bit)
./scripts/deploy.sh --no-build

# Skip SW compile
./scripts/deploy.sh --no-sw

# Only build, nothing else
./scripts/deploy.sh --build-only

# Include full_init + tetra_sysinfo after upload (opt-in)
./scripts/deploy.sh --init
```

Nach dem Deploy (ohne `--init`):

```bash
# Board initialisieren (2x Bitstream + 2x AD9361 + DAC/ADC)
./scripts/tetra_ctrl.sh full_init 430000000 430000000

# tetra_sysinfo starten
ssh root@192.168.2.180 'nohup /root/tetra_sysinfo > /tmp/tetra_sysinfo.log 2>&1 &'

# RF Loopback konfigurieren (TX_ATT=-10 dB empfohlen)
./scripts/tetra_ctrl.sh rf_loopback 430000000 430000000 15 -10

# Lock prüfen
./scripts/tetra_ctrl.sh monitor
```

---

## Was deploy.sh macht

| Schritt | Beschreibung | Flag zum Überspringen |
|---------|-------------|----------------------|
| 1. Vivado Build | Synthese + Implementierung + Bitstream | `--no-build` |
| 2. bootgen | `.bit` → `.bit.bin` Konvertierung | — (immer) |
| 3. Cross-Compile | `arm-linux-gnueabihf-gcc` → `tetra_sysinfo` | `--no-sw` |
| 4. Upload | SCP Bitstream + SW aufs Board, MD5-Verify | — (immer) |

**Wichtig:** `full_init` wird NICHT automatisch ausgeführt (kann Board crashen).
Opt-in mit `--init`.

---

## full_init Ablauf

`./scripts/tetra_ctrl.sh full_init [RX_Hz] [TX_Hz]`

1. **Erster Bitstream-Load** via FPGA Manager
2. **AD9361 Init** (Sample Rate 4.608 MSPS, LO, AGC slow_attack, FDD)
3. **Zweiter Bitstream-Load** (MMCM sieht jetzt stabilen DATA_CLK)
4. **AD9361 Re-Init** (stellt Register wieder her die Step 3 zurücksetzt)
5. **DAC Core Init** (RSTN + fabric data mode)
6. **ADC Core Init** (CH0/CH1 = 0x51 = enable + sign-extend)

### Warum 2x Bitstream?

Beim Kaltstart ist DATA_CLK vom AD9361 noch nicht da. Der erste Load bringt
die FPGA-Fabric hoch, aber MMCM hat keinen stabilen Clock-Input. Nach AD9361
Init liefert DATA_CLK, und der zweite Load konfiguriert die MMCM korrekt.

### Bekanntes Problem: Board-Crash

Der Bitstream-Load über FPGA Manager crasht das Board gelegentlich. Nach einem
Crash muss das Board physisch resettet werden. Der Bitstream bleibt auf dem
Dateisystem erhalten (persistenter Storage).

---

## RF Loopback Parameter

```bash
./scripts/tetra_ctrl.sh rf_loopback [RX_Hz] [TX_Hz] [SYNC_THRESH] [TX_ATT_dB]
```

| Parameter | Default | Empfohlen | Beschreibung |
|-----------|---------|-----------|--------------|
| RX_Hz | 430000000 | 430000000 | RX LO Frequenz |
| TX_Hz | 430000000 | 430000000 | TX LO (MUSS = RX für Loopback) |
| SYNC_THRESH | 15 | 15 | Korrelator-Schwelle (max 19) |
| TX_ATT_dB | -50 | **-10** | TX Dämpfung (0 bis -89 dB) |

**TX_ATT Sweep (2026-04-17, 10cm Luft-Loopback):**

| TX_ATT | AGC | RSSI | Lock |
|--------|-----|------|------|
| -10 dB | 49 dB | 71 dB | ✅ stabil (10/10) |
| -30 dB | 56 dB | 76 dB | ⚠️ instabil |
| -50 dB | 73 dB | 98 dB | ❌ zu schwach |

---

## Sync Lock FSM Parameter (tetra_sync_detect.v)

| Parameter | Wert | Beschreibung |
|-----------|------|--------------|
| LOCK_TOL | 30 | ±Symbole Toleranz für Spacing-Check |
| LOCK_TIMEOUT | 3060 | Symbole ohne sync_fire → Unlock (3 Frames) |
| LOCK_COUNT | 4 | Konsekutive Hits für Lock-Akquisition |
| HOLDOFF | 220 | Symbole Sperrzeit nach sync_fire |

spacing_ok akzeptiert Frame-Vielfache: 1020 ± 30, 2040 ± 30, 3060 ± 30.

---

## Troubleshooting

### Board crasht bei full_init
- Board physisch resetten
- Bitstream ist noch auf `/lib/firmware/` (persistent)
- Erneut `full_init` versuchen

### SYNC_LOCKED=0 trotz corr_peak=19/19
- tetra_sysinfo läuft? → `pgrep tetra_sysinfo`
- TX_ATT zu hoch? → `-10 dB` versuchen
- ADC Core OK? → `dmesg | grep ad9361` (kein "Tuning RX FAILED")

### AD9361 IIO-Device nicht gefunden
- Device ist `iio:device1` (nicht device0, das ist XADC)
- `cat /sys/bus/iio/devices/iio:device1/name` → `ad9361-phy`

---

## Dateien auf dem Board

| Pfad | Inhalt |
|------|--------|
| `/lib/firmware/tetra_zynq_phy.bit.bin` | FPGA Bitstream |
| `/root/tetra_sysinfo` | SYSINFO-Writer (ARM binary) |
| `/tmp/tetra_sysinfo.log` | Sysinfo Log-Ausgabe |

---

## Referenzen

- `scripts/deploy.sh` — Build + Deploy Pipeline
- `scripts/tetra_ctrl.sh` — Board-Steuerung (init, loopback, monitor)
- `scripts/ad9361_init.sh` — AD9361 Initialisierung
- `docs/register_map.md` — AXI-Lite Register
