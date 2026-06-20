# HARDWARE — Plattform, AD9361, Register-Map, CDC, Timing

**Projekt:** tetra-zynq-phy (LibreSDR, Zynq-7020 + AD9361)
**Zuletzt verifiziert:** 2026-04-13  · reviewed 2026-06-20 (Delta s.u.)

Ersetzt: `hw_setup.md`, `hw_board_state.md`, `adi_ip_integration.md`,
`axi_ad9361_integration.md`, `register_map.md`, `cdc_analysis.md`,
`timing_analysis.md`.

---

> **⟳ Review-Delta 2026-06-20:** Plattform (LibreSDR Zynq-7020 + AD9361, DL 438.25 / UL 428.25 MHz) unverändert. Die **aktuelle** AXI-Register-Map steht in `docs/ist/08_axi_regmap.md` (hier ggf. veraltet).

## 1. Plattform

| Komponente | Spezifikation |
|------------|---------------|
| Board | **LibreSDR Rev.5** |
| FPGA | Zynq-7020 (XC7Z020-CLG484), 85k Logic Cells, 220 DSP48E1, 4.9 Mb BRAM |
| RF-Chip | AD9363 (1Tx/1Rx, AD9361-kompatibel) |
| Power | 12 V DC, 2 A min — passiver Kühlkörper empfohlen |
| Netz | Gigabit Ethernet, IP `192.168.2.90` (OpenWiFi-Kernel) |
| Hostname | `analog` |
| Kernel | `5.10.0-98248-g1bbe32fa5182-dirty` (OpenWiFi) |
| Host-Tools | Ubuntu 20.04+, Vivado 2022.2, Python3, sshpass |

**Power-Budget (geschätzt, typischer Betrieb):** Zynq-PL ~2.5 W + PS ~1.5 W + AD9361 ~1.0 W + Peripherie ~0.5 W ≈ **5.5 W**.

---

## 2. Clock-Domänen

| Domäne | Frequenz | Quelle | Verwendung |
|--------|----------|--------|------------|
| `clk_sys` | 100 MHz | Zynq PS FCLK_CLK0 | Hauptverarbeitung (LMAC, RX/TX-Pipelines, Registers) |
| `clk_axi` | 100 MHz | Zynq PS FCLK_CLK0 (gleiche PLL-Quelle wie `clk_sys`) | AXI-Lite-Register, AXI-DMA |
| `clk_lvds` | ~61.44 MHz (DATA_CLK vom AD9361) | AD9361 via `axi_ad9361` IP | LVDS-DDR-Interface, RX/TX-Frontends |
| `clk_sample` | ~72 kHz | CIC-Dezimat von `clk_lvds` | 18 ksymbol × 4-facher Oversampling (Symbol-Rate-Domäne) |

**Hinweis:** `clk_sys` und `clk_axi` sind aus derselben PLL-Source, werden aber im Design als unabhängig behandelt (spätere Konfigurations-Flexibilität).

### 2.1 Reset-Reihenfolge

Nach `arst_n=1` releasen die Domain-Resets in dieser Reihenfolge (2-FF-Reset-Sync in `tetra_clk_reset.v`):

1. `rst_n_sys` (~20 ns)
2. `rst_n_axi` (~20 ns)
3. `rst_n_lvds` (~40 ns bei 50 MHz, <1 µs bei 61 MHz)
4. `rst_n_sample` (~28 µs bei 72 kHz)

**Konsequenz:** `clk_sys`-Logik kann starten bevor `rst_n_sample` freigegeben ist. Handshakes zwischen Sys- und Sample-Domäne müssen das berücksichtigen (`sync_locked`-Flag als Gate).

---

## 3. AD9361-Integration via `axi_ad9361` (ADI IP)

**Entscheidung 2026-04-06:** ADI `axi_ad9361` IP statt eigener LVDS-Implementierung.

### 3.1 Warum die ADI-IP

- **LVDS-Timing-Robustheit** — proven in OpenWiFi / BladeRF / LibreSDR-Referenz-Designs
- **AD9361-SPI-Konfiguration** integriert via libiio (keine eigene SPI-FSM nötig)
- **Wartbarkeit** — ADI pflegt die IP über Vivado-Versionen
- **2R2T-Option** für spätere MIMO-Erweiterung bleibt offen

Trade-off: ~5 LUT + ~32 FF Adapter-Overhead + ~2 BRAM18k interne IP-FIFOs — vernachlässigbar (280 BRAM18k verfügbar).

### 3.2 RTL-Hierarchie

```
Block Design (Vivado BD):
├── axi_ad9361_0 (ADI IP @ 0x7902_0000)
│ ├── LVDS DDR I/O (rx_clk_p/n, rx_frame_p/n, rx_data_p/n[5:0], tx_*)
│ ├── AXI-Lite control interface
│ └── Fabric-Side: adc_data_i0/q0, dac_data_i0/q0, l_clk, adc_valid, dac_valid
│
└── tetra_zynq_top_0
 └── tetra_ad9361_axis_adapter.v ← THIN wrapper
 ├── RX: adc_data_i0/q0 → rx_i/q_lvds (combinatorial pass-through)
 └── TX: tx_i/q_lvds → dac_data_i0/q0 (registered sample-and-hold)

deprecated/tetra_ad9361_interface.v ← ARCHIVED (Custom LVDS, nicht mehr aktiv)
```

**Clock-Naming-Konvention:** Suffixe zeigen Clock-Domäne, nicht Signal-Quelle:
- `_lvds` = `clk_lvds`-Domäne (DATA_CLK vom ADI-IP)
- `_sys` = `clk_sys`-Domäne (100 MHz)
- `_sample` = `clk_sample`-Domäne (72 kHz)

### 3.3 IP-Konfiguration (Vivado Block Design)

| Parameter | Wert | Hinweis |
|-----------|------|---------|
| `ID` | 0 | Einziger AD9361 |
| `DEVICE_TYPE` | 0 | AD9361 (nicht AD9364) |
| `ADC_DATAFORMAT_DISABLE` | 0 | Data-Format aktiv |
| `ADCDDRCLKEDGE` | 1 | DDR-Edge-Auswahl |
| `DACDDRCLKEDGE` | 1 | DDR-Edge-Auswahl |
| `CONFIG.DAC_DDS_DISABLE` | 1 | DDS-Generator ausgeschaltet → **MUSS** `dac_data_sel=0x2` pro Kanal nach Boot (siehe §5.3) |

### 3.4 Ressourcen-Delta

| Vorher (Custom) | Nachher (ADI-IP) |
|-----------------|------------------|
| ~150 LUT + ~100 FF | ~5 LUT + ~32 FF + ~2 BRAM18k (IP-intern) |

Netto-Einsparung am Fabric: ~145 LUT, ~68 FF. BRAM-Verbrauch innerhalb der IP ist gekapselt.

---

## 4. Board-Init-Sequenz (kritisch)

### 4.1 Empfohlener Weg — `full_init`

```bash
./scripts/tetra_ctrl.sh full_init 430000000 430000000
```

Das Script führt automatisch aus:
1. **Erster Bitstream-Load** via FPGA Manager (`/sys/class/fpga_manager/fpga0/firmware`)
2. **AD9361-Init** — Sample-Rate 4.608 MSPS, slow_attack AGC, FDD-Modus
3. **Zweiter Bitstream-Load** (MMCM bekommt jetzt stabilen DATA_CLK)
4. **AD9361 Re-Init** — stellt AXI-Register wieder her, die Step 3 zurückgesetzt hat
5. **DAC-Core-Init** — RSTN + fabric data mode + **`dac_data_sel=0x2` pro Kanal** (§5.3)
6. **ADC-Core-Init** — `r1_mode=0`, **CH0/CH1 = `0x51`** = enable + sign-extend + dfmt_enable (§5.2)

### 4.2 Warum 2× Bitstream-Load

Beim Kaltstart liefert der AD9361 noch kein stabiles `DATA_CLK`. Der erste Load bringt die FPGA-Fabric hoch, aber die MMCM hat keinen stabilen Clock-Input. Nach AD9361-Init liefert `DATA_CLK` → zweiter Load konfiguriert die MMCM mit stabilem Input.

### 4.3 AD9361-Treiber manuell laden (einmal pro Boot)

Der OpenWiFi-Kernel hat `CONFIG_AD9361=m`, aber das Modul-File fehlt in `/lib/modules/…/`. Manuell laden:

```bash
insmod /root/kernel_modules32/ad9361_drv.ko
echo '' > /sys/bus/spi/devices/spi0.0/driver_override
echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind
# Danach: ad9361-phy erscheint als iio:device1
```

### 4.4 libiio 0.24 — `iio_attr`-Syntax

Die Flags `-d` und `-c` sind **exklusiv** (nicht kombinierbar):

```bash
iio_attr -c ad9361-phy <channel> <attr> [value] # Kanal-Attribut
iio_attr -d ad9361-phy <attr> [value] # Device-Attribut
```

Kanäle: `voltage0` (RX1), `voltage1` (RX2), `altvoltage0` (RX_LO), `altvoltage1` (TX_LO). TX-Seite: `out_voltage0` (TX1 aktiv), `out_voltage1` (TX2 ungenutzt — §5.1).

---

## 5. Kritische Hardware-Findings

### 5.1 TX1 — `out_voltage0`, NICHT `out_voltage1` (verifiziert 2026-04-13)

Das AD9361-IIO-Interface hat **zwei TX-Kanäle** in der Linux-Sysfs-Baumstruktur, aber nur TX1 ist am RF-Port angeschlossen:

| Sysfs-Attribut | Kanal | AD9361 SPI Register | Wirkung |
|----------------|-------|---------------------|---------|
| `out_voltage0_hardwaregain` | **TX1** | 0x073, 0x074 | **Aktiver RF-Ausgang** ✅ |
| `out_voltage1_hardwaregain` | TX2 | 0x075, 0x076 | Nicht verbunden — kein Effekt ❌ |

Frühere Skripte haben irrtümlich `out_voltage1` gesetzt → keine TX-Leistungsänderung. Alle Tools nutzen jetzt `out_voltage0`.

**Format:** direkte dB, kein millidB:
```bash
SYSFS=$(grep -rl 'ad9361-phy' /sys/bus/iio/devices/*/name | head -1 | xargs dirname)
echo -50 > ${SYSFS}/out_voltage0_hardwaregain # -50 dB Dämpfung
cat ${SYSFS}/out_voltage0_hardwaregain # Readback: -50.000000 dB
```

**AGC-Sweep (2026-04-13, 10 cm Luft-Loopback, RX=TX=429 MHz):**

| TX_ATT | RX AGC | Bewertung |
|--------|--------|-----------|
| 0 dB | 0-1 dB | Übersteuert (RX sättigt) |
| -30 dB | 28 dB | Zu stark für stabilen Sync |
| -40 dB | 40 dB | Untergrenze OK |
| **-50 dB** | **47 dB** | **Optimal (Default für Loopback)** |
| -55 dB | 52 dB | Gut |
| -60 dB | 58 dB | Nahe Obergrenze |

Via `tetra_ctrl.sh rf_loopback`: 5. Parameter = TX_ATT (Default `-50`).

### 5.2 ADC Channel Register — `0x51`, NICHT `0x01` (Root Cause RF-Loopback-Fail vor 2026-04-13)

Der ADI-`axi_ad9361`-IP enthält pro ADC-Kanal ein `ad_datafmt`-Modul, gesteuert durch das Channel-Register (Offset 0x0 im Kanal-Block):

| Bit | Name | Funktion |
|-----|------|----------|
| 0 | `enable` | Kanal aktivieren |
| 4 | `dfmt_enable` | Datenformatierung aktiv |
| 5 | `dfmt_type` | 0 = Sign-Extend, 1 = Offset-Binary |
| 6 | `dfmt_se` | Sign-Extension (12 → 16 bit) |

**Korrekter Wert: `0x51`** = bit6 + bit4 + bit0 = dfmt_se + dfmt_enable + enable.

| Register | Adresse | Korrekter Wert |
|----------|---------|----------------|
| ADC CH0 (I) | `0x79020400` | `0x51` |
| ADC CH1 (Q) | `0x79020440` | `0x51` |

**Was passierte bei `0x01`:** 12-bit 2er-Komplement-ADC-Daten wurden zero-extended auf 16 bit. Negative Werte (−512 = 0xE00) wurden zu großen positiven Werten (+3584) → Signal gleichgerichtet → Phaseninformation zerstört → kein SYNC möglich. Digital-Loopback war nicht betroffen (Loopback-Mux in `tetra_zynq_top.v` umgeht ADC).

`CIC_GAIN_SHF=6` in `tetra_rx_frontend.v` gibt 64× Verstärkung für ADC-Amplitude (~512 @ -12 dBFS → ~32767 Full-Scale). Notwendig, da Gardner TED loop gain ∝ amplitude² — bei amplitude=514 wäre kp_term = 514²>>4>>18 ≈ 0.

### 5.3 `dac_data_sel` pro Kanal — `0x2`, nach jedem Bitstream-Load

Der ADI-`axi_ad9361`-IP hat pro DAC-Kanal ein `dac_data_sel`-Register (Offset 0x6 im Channel-Block). **Reset-Default = 0 = DDS-Modus.** Da `DAC_DDS_DISABLE=1`, liefert DDS-Modus immer Null → TX sendet keine FPGA-Daten → auf SDR nur LO-Leakage sichtbar.

**Pflicht nach jedem Bitstream-Load** (in `dac_init` enthalten):

| Register | Adresse | Wert | Bedeutung |
|----------|---------|------|-----------|
| CH0 `dac_data_sel` | `0x79024418` | `0x2` | I-Kanal → Fabric-Data |
| CH1 `dac_data_sel` | `0x79024458` | `0x2` | Q-Kanal → Fabric-Data |

Adress-Herleitung (ADI `up_dac_channel` Register-Map):
- `up_waddr[13:8] = COMMON_ID=0x11`, `[7:4] = Channel-ID`, `[3:0] = 0x6 (data_sel)`
- Byte-Adresse = IP-Base (`0x79020000`) + `up_waddr × 4`
- CH0: `up_waddr=0x1106` → offset `+0x4418` → `0x79024418`
- CH1: `up_waddr=0x1116` → offset `+0x4458` → `0x79024458`

### 5.4 TX-Debug-Strategie

Wenn auf SDR nur ein schmaler Träger sichtbar ist (LO-Leakage), aber kein 25-kHz-breites TETRA-Signal:

1. `tetra_ctrl.sh dac_init` — setzt RSTN + r1_mode + **`dac_data_sel=0x2`**
2. `busybox devmem 0x79024418 32` prüfen → muss `0x00000002` sein
3. Immer noch kein Signal: TX_EN prüfen (`tetra_ctrl.sh enable`)

### 5.5 AD9361-interner TX-Monitor (verifiziert 2026-04-12)

Der AD9361-Treiber stellt für den RX-Port die Quellen `TX_MONITOR1`, `TX_MONITOR2`, `TX_MONITOR1_2` — erlaubt TX-Pfad im Chip selbst gegen RX zu testen ohne Antennen:

```bash
./scripts/tetra_ctrl.sh tx_monitor # Host-Helper
./scripts/tetra_ctrl.sh monitor
```

Beobachtung: `TX_MONITOR1_2` liefert sporadisch `SYNC_LOCKED=1` → FPGA→DAC→AD9361-TX-Pfad ist nicht tot. Wenn gleichzeitig Antennen-Loopback kein Lock liefert, liegt's am RF-Außenpfad.

---

## 6. Clock-Domain-Crossings (CDC)

### 6.1 CDC-Register

Alle CDC-Einträge werden hier dokumentiert (Stand 2026-04-07, Hardware seitdem stabil):

| Signal | Von | Nach | Methode | Breite | Modul | Status |
|--------|-----|------|---------|--------|-------|--------|
| `arst_n` | async | `clk_sys` | 2-FF Reset Sync | 1 | `tetra_clk_reset.v` | ✅ |
| `arst_n` | async | `clk_axi` | 2-FF Reset Sync | 1 | `tetra_clk_reset.v` | ✅ |
| `arst_n` | async | `clk_lvds` | 2-FF Reset Sync | 1 | `tetra_clk_reset.v` | ✅ |
| `arst_n` | async | `clk_sample` | 2-FF Reset Sync | 1 | `tetra_clk_reset.v` | ✅ |
| `sync_locked` | `clk_sample` | `clk_sys` | 2-FF Single-bit | 1 | `tetra_rx_chain.v` | ✅ |
| `frame_num[5:0]` | `clk_sample` | `clk_sys` | Gray + 2-FF | 6 | `tetra_frame_counter.v` | ✅ |
| `mac_block_data` | `clk_sys` | `clk_axi` | XPM Async FIFO | 32 | `tetra_axi_dma_bridge.v` | ✅ |
| `iq_sample_i[11:0]` | `clk_lvds` | `clk_sys` | XPM Async FIFO | 24 | `tetra_rx_frontend.v` | ✅ |
| `iq_tx_i[11:0]` | `clk_sys` | `clk_lvds` | XPM Async FIFO | 24 | `tetra_tx_frontend.v` | ✅ |

### 6.2 CDC-Historie

2026-04-07 Vivado-CDC-Report zeigte **79 unsafe Crossings** von `clk_sys` → `clk_lvds` (primär TX-Datenpfad: `tx_block1/2_sys`, `tx_slot_en_sys`, `tx_burst_type_sys`, Timing-Signale). Diese wurden vor Hardware-Test via XPM Async FIFOs synchronisiert. Seit 2026-04-13 (erste RF-Loopback-Erfolge) keine weiteren CDC-Issues im Vivado-Report.

### 6.3 Synchronisations-Primitive

**2-FF Reset-Sync** (`tetra_clk_reset.v`):
```
arst_n ────────────────────────────── (async assert)
 │ │
 └─ D→[FF0]→[FF1] ──► rst_n_domain (sync deassert)
 clk_domain clk_domain
```
XDC: `set_false_path -to [get_cells {*rst_sync0_*}]`.

**2-FF Single-Bit** für Control/Status: `set_false_path -to [get_cells {*_r0*}]`.

**Gray-Code + 2-FF** für Counter (z.B. `frame_num`): Gray-encode vor Crossing, decode nach.

**XPM Async FIFO** für Daten (16+ bit): `xpm_fifo_async` mit internen Gray-Pointern + 3-stufigen Synchronisatoren. Keine User-XDC nötig.

### 6.4 XDC-Template

```tcl
# Reset synchronizer false paths — first FF of each 2-FF chain
set_false_path -to [get_cells {*rst_sync0_sys*}]
set_false_path -to [get_cells {*rst_sync0_axi*}]
set_false_path -to [get_cells {*rst_sync0_lvds*}]
set_false_path -to [get_cells {*rst_sync0_sample*}]

# ASYNC_REG Constraints werden pro Instance direkt per Attribut gesetzt,
# z.B. (* ASYNC_REG = "TRUE" *) reg tx_toggle_lvds_r0;
```

---

## 7. AXI-Lite Register-Map

**Base:** `0x43C0_0000` (TETRA-PL in `tetra_axi_lite_regs.v`). Alle Zugriffe 32-bit, word-aligned. Byte/Halbwort-Access nicht unterstützt.

Siehe `sw/tetra_hal.h` für C-Symbole. Adressen können sich ändern — bei Konflikten immer Header als Source-of-Truth.

### 7.1 Kern-Register

| Offset | Name | Access | Reset | Beschreibung |
|--------|------|--------|-------|--------------|
| 0x00 | `CTRL` | R/W | 0x00000000 | [0] RX_EN, [1] TX_EN, [2] LOOPBACK_EN, [3] RESET_COUNTERS |
| 0x04 | `STATUS` | RO | 0x00000000 | [0] SYNC_LOCKED, [1] PLL_LOCKED, [2] FIFO_EMPTY, [3] FIFO_FULL, [7:4] SLOT_STATUS |
| 0x08 | `VERSION` | RO | 0x00010000 | `[31:16]=major`, `[15:0]=minor` → v1.0 |
| 0x0C | `SYNC_THRESH` | R/W | 0x14 | Sync-Correlator-Schwelle (Default 20) |
| 0x10 | `COLOUR_CODE` | R/W | 0x01 | TETRA Colour Code (1-63) |
| 0x14 | `FRAME_NUM` | RO | 0 | Aktuelle TDMA-Frame-Nummer (live) |
| 0x18 | `SLOT_NUM` | RO | 0 | Aktueller Timeslot (0-3) |
| 0x1C | `RX_GAIN` | R/W | 0x20 | AD9361 RX Gain (0-76 dB) |
| 0x20 | `TX_ATT` | R/W | 0x28 | AD9361 TX Attenuation |
| 0x24 | `IRQ_ENABLE` | R/W | 0 | Interrupt-Enable-Mask |
| 0x28 | `IRQ_STATUS` | R/W1C | 0 | Interrupt-Flags — write 1 zum Clear |
| 0x2C | `DMA_BLOCK_COUNT` | RO | 0 | Empfangene MAC-Blocks |
| 0x30 | `CRC_ERROR_COUNT` | RO | 0 | CRC-Fehler |
| 0x34 | `SYNC_LOST_COUNT` | RO | 0 | Sync-Loss-Events |
| 0x38 | `TX_TDMA` | RO | 0x44 | TX-TDMA-State: `[12:7]` MF, `[6:2]` FN, `[1:0]` TN |
| 0x3C | `SCRATCH` | R/W | 0 | Test-Register (SW-Self-Test) |
| 0x84 | `TX_TEST` | R/W | 0 | `[0]` PRBS_EN (LFSR x^15+x^14+1, Seed 0x7FFF) |

### 7.2 SB/NDB Payload-Register

**SB_SB1 (BSCH 120 type-5 bits, 4 Wörter):** 0x40-0x4C. Reg-Word 0 bit 31 = erstes TX-Bit. Konkatenation `{w0, w1, w2, w3[23:0]}` → 120-bit-Bus.

**SB_BKN2 (BNCH 216 type-5 bits, 7 Wörter):** 0x60-0x78. `{w0..w5, w6[23:0]}` → 216-bit.

**SB_BB (AACH 30 type-5 bits):** 0x7C → bits `[29:0]`.

**NDB_BLK1 (216 bits, 7 Wörter):** 0x88-0xA0. SCH/F MAC-BROADCAST SYSINFO-Erste-Hälfte.

**NDB_BLK2 (216 bits, 7 Wörter):** 0xA4-0xBC. Zweite Hälfte.

### 7.3 MLE-Signalling (M2.3-Erweiterung, 2026-04-23)

| Offset | Name | Access | Beschreibung |
|--------|------|--------|--------------|
| 0x164 | `REG_UL_PDU_STATUS` | RO | UL MAC-ACCESS geparste Felder (pdu_type, fill, enc, ack, addr_type, pdu_count) |
| 0x168 | `REG_UL_PDU_SSI` | RO | short_ssi / event_label |
| 0x16C | `REG_UL_PDU_RAW_0` | RO | raw_info_bits[31:0] |
| 0x170 | `REG_UL_PDU_RAW_1` | RO | raw_info_bits[63:32] |
| 0x174 | `REG_UL_PDU_RAW_2` | RO | raw_info_bits[91:64] (28 bit) |
| 0x178 | `REG_UL_PDU_CTRL` | W1C | Clear valid sticky |
| 0x17C | `REG_UL_SCRAMB_INIT` | R/W | UL Scrambler Seed |
| 0x190 | `REG_MLE_STATS_A` | RO | `{accept_cnt[31:16], ul_req_cnt[15:0]}` |
| 0x194 | `REG_MLE_STATS_B` | RO | `{busy_sticky, drop_cnt[15:0]}` |
| 0x198 | `REG_MLE_STATS_C` | RO | `{clear_cnt[31:16], sig_override_cnt[15:0]}` |
| 0x19C | `REG_SIGNAL_TARGET_TN` | R/W | Default 0 (= ETSI TN=1) |
| 0x1A0 | `REG_CELL_LA` | R/W | Cell Location Area (14 bit, default 1) |

### 7.4 Schedule-BRAM

**0x400..0x63F** (576 Byte, 144 × 32-bit). Dual-Port-BRAM, SW schreibt pro Boot, RTL liest per Slot. Jedes Word enthält 2 Schedule-Einträge à 16 bit (siehe ARCHITECTURE.md §TDMA-Timebase).

### 7.5 Bit-Felder Highlights

**0x00 `CTRL`:**
| Bit | Name | Funktion |
|-----|------|----------|
| 0 | `RX_EN` | RX-Kette aktiv |
| 1 | `TX_EN` | TX-Kette aktiv |
| 2 | `LOOPBACK_EN` | TX→RX digitaler Loopback |
| 3 | `RESET_COUNTERS` | Zähler clearen |

**0x04 `STATUS`:**
| Bit | Name | Funktion |
|-----|------|----------|
| 0 | `SYNC_LOCKED` | Burst-Sync akquiriert |
| 1 | `PLL_LOCKED` | AD9361-PLL ok |
| 2 | `RX_FIFO_EMPTY` | Keine Daten im RX-FIFO |
| 3 | `RX_FIFO_FULL` | RX-FIFO voll — Datenverlust möglich |

**0x28 `IRQ_STATUS` (W1C):**
| Bit | Name |
|-----|------|
| 0 | `IRQ_MAC_BLOCK_RDY` |
| 1 | `IRQ_SYNC_ACQUIRED` |
| 2 | `IRQ_SYNC_LOST` |
| 3 | `IRQ_CRC_ERROR` |
| 4 | `IRQ_RX_FIFO_FULL` |

### 7.6 SW-Access-Beispiel

```c
#include "tetra_hal.h"
#define TETRA_AXI_BASE 0x43C00000

tetra_reg_write(&hal, REG_CTRL, CTRL_RX_EN | CTRL_TX_EN); // Enable beide
tetra_reg_write(&hal, REG_TX_TEST, 1); // PRBS-Mode
while (!(tetra_reg_read(&hal, REG_STATUS) & STATUS_PLL_LOCKED)); // Poll
```

---

## 8. FPGA-Ressourcen (implementiert, Stand 2026-04-13)

| Resource | Genutzt | Verfügbar | % |
|----------|---------|-----------|---|
| LUT | ~5 205 | 53 200 | ~10% |
| FF | ~12 298 | 106 400 | ~12% |
| DSP48 | 4 | 220 | ~2% |
| BRAM18k | ~2 | 280 | ~1% |

**Timing-Verlauf (WNS):**

| Datum | Build | WNS | Hinweis |
|-------|-------|-----|---------|
| 2026-04-13 | Baseline | +0.006 ns | Timing geschlossen |
| 2026-04-23 Bug #1/#2 | | -0.195 ns | on-air OK |
| 2026-04-23 Bug #7 | | -0.078 ns | on-air OK |
| 2026-04-23 Bug #8 | | -0.293 ns | on-air OK |
| 2026-04-23 Bug #9 | | -0.139 ns | on-air OK, aber MS-Reg nicht geschlossen |

Auch Builds mit negativen WNS bis -0.3 ns haben on-air stabil gefunkt. Für Produktivbuilds: Vivado-Strategy `Performance_Explore` bei Bedarf.

---

## 9. ILA-Probes (`u_ila_sys`, `clk_sys` 100 MHz)

| Probe | Signal | Bedeutung |
|-------|--------|-----------|
| 0 | `dbg_m_axis_tready_sys` | AXI-DMA ready |
| 1 | `dbg_m_axis_tvalid_sys` | AXI-DMA valid |
| 2 | `dbg_o_irq_sys` | IRQ-Ausgang |
| 3 | `dbg_sync_found_sys` | TETRA Sync-Puls |
| 4 | `dbg_sync_locked_sys` | TETRA Sync-Lock |

**Trigger für TETRA-Empfang:** `dbg_sync_found_sys = 1`.

`l_clk`-ILA (LVDS-Domäne) bleibt deaktiviert — `l_clk` ist erst nach AD9361-Init stabil. Falls LVDS-Debug nötig: `ENABLE_ILA_DEBUG` + `l_clk`-ILA erst nach AD9361-Startup aktivieren.

---

## 10. Bekannte Hardware-Probleme

| Problem | Ursache | Fix/Workaround |
|---------|---------|----------------|
| **ADC sign-extend fehlt (KRITISCH)** | `cmd_adc_init` schrieb `0x01` statt `0x51` → dfmt gelöscht → negative ADC-Werte gleichgerichtet → SYNC unmöglich bei RF (Digital-Loopback umgeht ADC) | ✅ **Behoben** (`0x51` in `tetra_ctrl.sh`, 2026-04-13) |
| AD9361 kein IIO nach Boot | Modul fehlt im Kernel | `insmod /root/kernel_modules32/ad9361_drv.ko` |
| Bind schlägt fehl | `driver_override=spidev` | `echo '' >.../driver_override` |
| AD9361-Default nach Bitstream-Reload | Chip-Reinit durch Treiber | `full_init` nutzen (2× Bitstream + 2× AD9361) |
| TX-Dämpfung ohne Wirkung | `out_voltage1_hardwaregain` → TX2 nicht verbunden | Immer `out_voltage0_hardwaregain` für TX1 |
| `cf-ad9361-lpc` kein IIO | AXI-DMA nicht verbunden | Kein Problem — TETRA nutzt eigenen DMA-Pfad |
| 3/30 SYNC-Drops bei RF-Loopback | AGC slow_attack Gain-Sprünge | Low-Prio — AGC-Tuning oder LOCK_TIMEOUT erhöhen |
| `clk_lvds` tot nach Reboot | `axi_ad9361`-MMCM braucht stabilen DATA_CLK | `full_init` mit 2× Bitstream-Load |
| RF TX stumm nach Bitstream-Load | DAC-Core in Reset + `dac_data_sel=0` (DDS disabled → Null) | `tetra_ctrl.sh dac_init` (in `full_init` enthalten) |
| Board crasht bei `full_init` | FPGA Manager kann Board hart abstürzen lassen | Physisch resetten; Bitstream bleibt auf `/lib/firmware/`; zweiter Versuch klappt |

---

## 11. TETRA-Konfiguration — verifizierte Defaults

| Parameter | Wert | Bemerkung |
|-----------|------|-----------|
| RX LO | 430 MHz (Default) / 429.95 MHz (MS-Test) | TETRA 70 cm Amateur DE |
| TX LO | 430 MHz (Loopback) / 439.95 MHz (MS-Test) | 10 MHz Duplex Band 4 |
| Sample Rate | 4.608 MSPS | AD9361 4 607 999 Hz, BBPLL 1 179 647 997 Hz |
| ADC Rate | 36.864 MSPS | intern vor Decimation |
| RXSAMP | 4 607 999 Hz | Output zur Fabric |
| RX BW | 5.76 MHz | 1.25× Sample-Rate |
| Gain Mode | `slow_attack` | AGC |
| ENSM | `fdd` | Full-Duplex |
| RX Port | `A_BALANCED` | LibreSDR-Standard |
| TX Attenuation | -50 dB (Loopback) / -10 dB (MS-Test) | `out_voltage0_hardwaregain` TX1 |
| ADI DAC DDS | deaktiviert | `CONFIG.DAC_DDS_DISABLE=1` in `scripts/create_bd.tcl` |

---

## 12. Referenzen

- **ADI HDL Library:** `adi-hdl/library/axi_ad9361/` (Apache-2.0)
- **AD9361 Reference Manual:** UG-570 §5 (Parallel Data Port)
- **Xilinx UG585:** Zynq-7000 Technical Reference Manual
- **OpenWiFi:** `libresdr/system_top.v` (verified hardware integration)
- **docs/ARCHITECTURE.md:** RTL/SW-Stack, Modul-Status
- **docs/OPERATIONS.md:** Deploy-Workflow, Test-Strategien
- **docs/PROTOCOL.md:** TETRA-Protokoll, ETSI-Referenz
