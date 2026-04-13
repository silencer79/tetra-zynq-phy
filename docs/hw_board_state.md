# Hardware Board State — LibreSDR
**Project:** tetra-zynq-phy
**Letzte Verifikation:** 2026-04-13

---

## Board-Übersicht

| Eigenschaft | Wert |
|-------------|------|
| Board | LibreSDR Rev.5 |
| FPGA | Zynq-7020 (XC7Z020-CLG484) |
| RF-Chip | AD9363 (kompatibel zu AD9361) |
| IP-Adresse | 192.168.2.180 |
| SSH-User | root / openwifi |
| Hostname | analog |
| Kernel | 5.10.0-98248-g1bbe32fa5182-dirty (OpenWiFi-Kernel) |

---

## Wichtige Besonderheiten (OpenWiFi-Kernel)

### AD9361 Treiber nicht installiert

Der OpenWiFi-Kernel wurde mit `CONFIG_AD9361=m` gebaut, aber das
Modulfile fehlt in `/lib/modules/5.10.0-98248-*/`. Das Modul muss
manuell geladen werden:

```bash
# Einmalig nach jedem Neustart:
insmod /root/kernel_modules32/ad9361_drv.ko

# driver_override muss leer sein:
echo '' > /sys/bus/spi/devices/spi0.0/driver_override

# Binden:
echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind
```

Danach erscheint `ad9361-phy` als `iio:device1`.

### iio_attr Syntax (libiio 0.24)

Die Flags `-d` und `-c` sind **exklusiv** (nicht kombinierbar):

```bash
# Kanal-Attribut lesen/schreiben:
iio_attr -c ad9361-phy <channel> <attr> [value]

# Device-Attribut lesen/schreiben:
iio_attr -d ad9361-phy <attr> [value]
```

Kanalnamen: `voltage0` (RX), `voltage1` (TX), `altvoltage0` (RX_LO),
`altvoltage1` (TX_LO)

### FPGA Bitstream

Das TETRA-Bitstream liegt auf dem Board:
- `/lib/firmware/tetra_zynq_phy.bit.bin` — für FPGA-Manager

Nach **Bitstream-Reload** gilt:
- AD9361-Chip verliert Konfiguration (IIO-State zurückgesetzt)
- → `ad9361_init.sh` muss nochmals ausgeführt werden

---

## Vollständige Init-Sequenz (nach Neustart oder Bitstream-Reload)

**Empfohlen: `full_init` Script (automatisiert alle Schritte):**

```bash
./scripts/tetra_ctrl.sh full_init 430000000 430000000
```

Das Script führt automatisch aus:
1. Erster Bitstream-Load (FPGA Manager)
2. AD9361 Init (4.608 MSPS, slow_attack AGC)
3. Zweiter Bitstream-Load (MMCM sieht jetzt stabilen DATA_CLK)
4. AD9361 Re-Init (stellt AXI-Register wieder her, die Step 3 zurücksetzt)
5. DAC-Core Init (RSTN + fabric data mode)
6. ADC-Core Init (r1_mode=0, **CH0/CH1 = 0x51** = enable + sign-extend)

**Manuelle Schritte (falls full_init nicht verwendet wird):**

```bash
# 1. Bitstream laden (erster Load)
./scripts/convert_bitstream.sh
scp build/tetra_zynq_phy.bit.bin root@192.168.2.180:/lib/firmware/
ssh root@192.168.2.180 'echo 0 > /sys/class/fpga_manager/fpga0/flags && echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware'

# 2. AD9361 initialisieren
./scripts/ad9361_init.sh --agc --freq 430000000

# 3. Bitstream nochmals laden (MMCM-Lock)
ssh root@192.168.2.180 'echo tetra_zynq_phy.bit.bin > /sys/class/fpga_manager/fpga0/firmware'

# 4. AD9361 erneut initialisieren (Step 3 hat ADC-Register zurückgesetzt!)
./scripts/ad9361_init.sh --agc --freq 430000000

# 5. DAC-Core Init
./scripts/tetra_ctrl.sh dac_init

# 6. ADC-Core Init (KRITISCH: 0x51, nicht 0x01!)
./scripts/tetra_ctrl.sh adc_init
```

---

## TETRA-Konfiguration (verifiziert 2026-04-13)

| Parameter | Wert | Bemerkung |
|-----------|------|-----------|
| RX LO | 430 000 000 Hz | TETRA 70cm Amateur DE |
| TX LO | 430 000 000 Hz | = RX LO für RF-Loopback (Duplex 10 MHz im Normalbetrieb) |
| Sample Rate | 4 607 999 Hz | ≈ 4.608 MSPS |
| BBPLL | 1 179 647 997 Hz | Auto berechnet |
| ADC Rate | 36 863 999 Hz | Intern, vor Decimation |
| RXSAMP | 4 607 999 Hz | Output zur FPGA-Fabric |
| RX BW | 5 760 000 Hz | 1.25× Samplerate |
| Gain Mode | slow_attack | AGC |
| ENSM | fdd | Full-Duplex |
| RX Port | A_BALANCED | LibreSDR Standard |
| TX Attenuation | -50 dB (Loopback) | `out_voltage0_hardwaregain` — TX1. `out_voltage1` ist TX2 (ungenutzt, kein Effekt!) |
| ADI DAC DDS | deaktiviert | `CONFIG.DAC_DDS_DISABLE=1` in `scripts/create_bd.tcl` |

### KRITISCH: TX1 Dämpfung — out_voltage0, NICHT out_voltage1 (verifiziert 2026-04-13)

Das AD9361 IIO-Interface hat **zwei TX-Kanäle** in der Linux-Sysfs-Baumstruktur:

| Sysfs-Attribut | Kanal | AD9361 SPI Register | Wirkung auf LibreSDR |
|----------------|-------|---------------------|----------------------|
| `out_voltage0_hardwaregain` | TX1 | 0x073 (LSBs), 0x074 (MSB) | **Aktiver RF-Ausgang** ✓ |
| `out_voltage1_hardwaregain` | TX2 | 0x075 (LSBs), 0x076 (MSB) | Nicht verbunden — kein Effekt! ✗ |

**Alle früheren Skripte haben `out_voltage1` gesetzt → TX2 → kein Effekt auf TX-Leistung!**
Der AD9361 auf dem LibreSDR ist ein AD9363 (1Tx/1Rx), nur TX1 ist am RF-Port angeschlossen.

Schreiben des Wertes (Format: direkte dB, kein millidB):
```bash
# Auf dem Board:
SYSFS=$(grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name | head -1 | xargs dirname)
echo -50 > ${SYSFS}/out_voltage0_hardwaregain   # 50 dB Dämpfung
cat ${SYSFS}/out_voltage0_hardwaregain           # Readback: -50.000000 dB
```

**Verifizierter AGC-Sweep (2026-04-13, 10cm Luft-Loopback, RX=TX=429 MHz):**

| TX_ATT (out_voltage0) | RX AGC | Bewertung |
|-----------------------|--------|-----------|
| 0 dB | 0–1 dB | Übersteuert (sättigt RX) |
| -30 dB | 28 dB | Zu stark für stabilen Sync |
| -40 dB | 40 dB | Untergrenze OK |
| **-50 dB** | **47 dB** | **Optimal (Default)** |
| -55 dB | 52 dB | Gut |
| -60 dB | 58 dB | Nahe Obergrenze |

Via `tetra_ctrl.sh rf_loopback`: 5. Parameter = TX_ATT in dB (Default: `-50`).

---

### KRITISCH: axi_ad9361 dac_data_sel (per-Kanal, nach jedem Bitstream-Load setzen)

Der ADI `axi_ad9361`-IP hat pro DAC-Kanal ein `dac_data_sel`-Register
(Offset 0x6 im Channel-Register-Block). **Reset-Default = 0 = DDS-Modus.**

Da `DAC_DDS_DISABLE=1` gesetzt ist, liefert DDS-Modus **immer Null**.
Ergebnis: TX sendet keine FPGA-Daten → auf dem SDR nur LO-Leakage sichtbar.

**Pflicht nach jedem Bitstream-Load** (in `dac_init` enthalten):

| Register | Adresse | Wert | Bedeutung |
|----------|---------|------|-----------|
| CH0 dac_data_sel | `0x79024418` | `0x2` | I-Kanal → Fabric-Data (FPGA) |
| CH1 dac_data_sel | `0x79024458` | `0x2` | Q-Kanal → Fabric-Data (FPGA) |

Adress-Herleitung (ADI up_dac_channel Register Map):
- `up_waddr[13:8]` = `COMMON_ID=0x11`, `[7:4]` = Channel-ID (0 oder 1), `[3:0]` = `0x6` (data_sel)
- Byte-Adresse = IP-Base (`0x79020000`) + `up_waddr × 4`
- CH0: `up_waddr=0x1106` → `+0x4418` → `0x79024418`
- CH1: `up_waddr=0x1116` → `+0x4458` → `0x79024458`

### Wichtiger TX-Debug-Hinweis

Wenn auf dem SDR nur ein schmaler Träger sichtbar ist (LO-Leakage), aber
kein 25-kHz-breites TETRA-Signal:

1. `dac_init` ausführen → setzt RSTN + r1_mode + **dac_data_sel=2**
2. Mit `busybox devmem 0x79024418 32` verifizieren → muss `0x00000002` sein
3. Wenn immer noch kein Signal: TX_EN prüfen (`tetra_ctrl.sh enable`)

### AD9361-interner TX-Monitor (verifiziert 2026-04-12)

Der AD9361-Treiber stellt für den RX-Port die Quellen
`TX_MONITOR1`, `TX_MONITOR2` und `TX_MONITOR1_2` bereit. Damit lässt sich der
TX-Pfad **im Chip selbst** gegen den RX-Pfad testen, ohne Antennen oder
externen RF-Aufbau.

Verifizierter Testablauf:

```bash
# Host-Helfer: richtet RX/TX-Los, TX_MONITOR1_2, DAC-Fabric-Modus und CTRL=0x03 ein
./scripts/tetra_ctrl.sh tx_monitor
./scripts/tetra_ctrl.sh monitor
```

Beobachtung:
- `TX_MONITOR1` / `TX_MONITOR2`: kein stabiler Lock
- `TX_MONITOR1_2`: sporadisch `SYNC_LOCKED=1`

Schlussfolgerung:
- FPGA → axi_ad9361 DAC → AD9361 TX-Pfad ist **nicht tot**
- Wenn externer Antennen-Loopback gleichzeitig kein Lock liefert, liegt das
  Problem eher im RF-Außenpfad, Pegel-/Kopplungsthema oder der
  Antennen-/Port-Konfiguration als im reinen Fabric-Datenpfad

### Externer RF-Loopback (Host-Helfer)

Für den normalen RF-Pfad gibt es einen Host-Helfer, der den Boardzustand auf
einen sauberen Außenpfad zurücksetzt:

```bash
./scripts/tetra_ctrl.sh rf_loopback [rx_hz] [tx_hz] [sync_thresh] [loopback_bit] [tx_att]
```

Beispiel (verifiziert 2026-04-13, 27/30 SYNC_LOCKED=1):
```bash
./scripts/tetra_ctrl.sh rf_loopback 430000000 430000000 20 0 -50
./scripts/tetra_ctrl.sh monitor
```

Standardwirkung:
- `RX_LO=TX_LO=430 MHz` (TX=RX funktioniert mit -50 dB TX ATT)
- `rf_port_select=A_BALANCED`
- `gain_control_mode=slow_attack`
- TX-Dämpfung: `-50 dB` (5. Parameter)
- DAC-Fabricmodus aktiv
- ADC Channel Register auf `0x51` (sign-extend + enable)
- `SYNC_THRESH=20`
- Counter-Reset + `CTRL=0x03`

---

## ILA-Probes (u_ila_sys, clk_sys 100 MHz)

| Probe | Signal | Bedeutung |
|-------|--------|-----------|
| probe0 | `dbg_m_axis_tready_sys` | AXI-DMA bereit |
| probe1 | `dbg_m_axis_tvalid_sys` | AXI-DMA sendet |
| probe2 | `dbg_o_irq_sys` | IRQ-Ausgang |
| probe3 | `dbg_sync_found_sys` | TETRA Sync-Puls |
| probe4 | `dbg_sync_locked_sys` | TETRA Sync-Lock |

Trigger für TETRA-Empfang: `dbg_sync_found_sys = 1`

**Hinweis:** l_clk-ILA (LVDS-Domain) ist deaktiviert — l_clk ist erst
nach AD9361-Init stabil. Für LVDS-Debug: ENABLE_ILA_DEBUG + l_clk ILA
erst nach AD9361-Startup aktivieren.

---

## FPGA-Ressourcen (implementiert, verifiziert)

| Resource | Genutzt | Verfügbar | % |
|----------|---------|-----------|---|
| LUT | ~5 205 | 53 200 | ~10% |
| FF | ~12 298 | 106 400 | ~12% |
| DSP48 | 4 | 220 | ~2% |
| BRAM18k | ~2 | 280 | ~1% |

**Timing:** WNS = +0.006 ns (clk_sys 100 MHz) ✅

---

## KRITISCH: ADC Channel Register (dfmt) — Root Cause RF-Loopback-Failure

Der ADI `axi_ad9361` IP Block enthält pro ADC-Kanal ein `ad_datafmt`-Modul,
gesteuert über das Channel-Register (Offset 0x0 im Kanal-Block):

| Bit | Name | Funktion |
|-----|------|----------|
| 0 | `enable` | Kanal aktivieren |
| 4 | `dfmt_enable` | Datenformatierung aktivieren |
| 5 | `dfmt_type` | 0=Sign-Extend, 1=Offset-Binary |
| 6 | `dfmt_se` | 1=Sign-Extension (12→16 bit) |

**Korrekter Wert: `0x51` = bit6 + bit4 + bit0 = dfmt_se + dfmt_enable + enable.**

| Register | Adresse | Korrekter Wert |
|----------|---------|----------------|
| ADC CH0 (I) | `ADC_BASE + 0x400` | `0x51` |
| ADC CH1 (Q) | `ADC_BASE + 0x440` | `0x51` |

**Was passiert bei `0x01` (nur enable, ohne dfmt):**
- 12-bit 2's-Complement ADC-Daten werden zero-extended auf 16 bit
- Negative Werte (z.B. -512 = 0xE00) werden zu großen positiven Werten (+3584 = 0x0E00)
- Signal wird gleichgerichtet → alle Phaseninformation zerstört → SYNC unmöglich
- **Digital-Loopback war davon nicht betroffen**, weil der Loopback-Mux (CTRL[2]=1)
  in `tetra_zynq_top.v` den ADC komplett umgeht

**CIC_GAIN_SHF=6** in `tetra_rx_frontend.v`: 64× Verstärkung für ADC-Amplitude (~512
bei -12 dBFS) → ~32767 (Full-Scale). Notwendig weil Gardner TED loop gain ∝ amplitude²
— bei Amplitude 514 wäre kp_term = 514²>>4>>18 ≈ 0.

---

## Hardware-Loopback Testergebnisse

### Digitaler Loopback (2026-04-13)

| Parameter | Wert |
|-----------|------|
| Modus | Digitaler Loopback (TX-CIC-Ausgang → RX-CIC-Eingang, CTRL[2]=1) |
| Testdauer | 30 Sekunden (1-Sekunden-Polling) |
| SYNC_LOCKED=1 | **30/30 (100%)** |
| Dropouts | 0 |
| SYNC_THRESH | 0x14 = 20 (AXI-Register) |
| LOCK_TIMEOUT | 512 Symbole (~28ms bei 18 kHz) |
| CIC_GAIN_SHF | 6 (64× Verstärkung im RX CIC) |

### RF Antennen-Loopback (2026-04-13)

| Parameter | Wert |
|-----------|------|
| Modus | RF Loopback (TX-Antenne → 10cm Luft → RX-Antenne, CTRL=0x03) |
| TX LO | 430 000 000 Hz (= RX LO) |
| TX Attenuation | -50 dB (`out_voltage0_hardwaregain`) |
| RX Gain Mode | slow_attack AGC |
| RX Gain | ~47 dB (AGC aktiv) |
| Testdauer | 30 Sekunden (1-Sekunden-Polling) |
| SYNC_LOCKED=1 | **27/30 (90%)** |
| Dropouts | 3× kurze Drops (korrelieren mit AGC slow_attack Gain-Sprüngen) |
| SYNC_THRESH | 0x14 = 20 |
| LOCK_TIMEOUT | 512 Symbole |
| CIC_GAIN_SHF | 6 (64× Verstärkung im RX CIC) |
| ADC Channel | 0x51 (enable + dfmt_se + dfmt_enable) — **KRITISCH** |
| Voraussetzung | `full_init` (2× Bitstream + 2× AD9361 + DAC + ADC init) |

---

## Bekannte Probleme

| Problem | Ursache | Workaround / Fix |
|---------|---------|------------------|
| **ADC sign-extend fehlt (KRITISCH)** | `cmd_adc_init` schrieb `0x01` statt `0x51` → `dfmt_se` + `dfmt_enable` gelöscht → 12-bit ADC zero-extended statt sign-extended → negative Werte gleichgerichtet → SYNC unmöglich bei RF | **BEHOBEN:** `0x51` in `tetra_ctrl.sh` (2026-04-13). Betrifft nur RF-Pfad; Digital-Loopback umgeht ADC. |
| AD9361 kein IIO nach Boot | Modul fehlt im Kernel | `insmod /root/kernel_modules32/ad9361_drv.ko` |
| Bind schlägt fehl | driver_override=spidev | `echo '' > .../driver_override` |
| AD9361 Default nach Bitstream-Reload | Chip-Reinit durch Treiber | `full_init` nutzen (2× Bitstream + 2× AD9361) |
| TX Dämpfung ohne Wirkung | `out_voltage1_hardwaregain` → TX2 (nicht verbunden) | Immer `out_voltage0_hardwaregain` für TX1 (verifiziert 2026-04-13) |
| cf-ad9361-lpc kein IIO | AXI-DMA nicht verbunden | Kein Problem — TETRA nutzt eigenen DMA-Pfad |
| 3/30 SYNC-Drops bei RF-Loopback | AGC slow_attack Gain-Sprünge | Low priority — AGC-Tuning oder LOCK_TIMEOUT erhöhen |
| clk_lvds tot nach Reboot | axi_ad9361-MMCM braucht stabilen DATA_CLK | `full_init` (2× Bitstream-Load) |
| RF TX stumm nach Bitstream-Load | DAC-Core in Reset + dac_data_sel=0 (DDS disabled → Null) | `tetra_ctrl.sh dac_init` (in `full_init` enthalten) |

---

**Letzte Aktualisierung:** 2026-04-13 (ADC dfmt fix 0x01→0x51, RF Loopback 27/30, CIC_GAIN_SHF=6)  
**Erstellt durch:** Hardware-Deployment-Session
