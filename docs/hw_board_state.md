# Hardware Board State — LibreSDR
**Project:** tetra-zynq-phy
**Letzte Verifikation:** 2026-04-07

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
- `/usr/lib/firmware/tetra_zynq_phy.bit.bin` — für FPGA-Manager
- Wird per JTAG aus `build/tetra_zynq_phy.bit` geprogrammt

Nach **JTAG-Reprogram** gilt:
- AD9361-Chip bleibt konfiguriert (SPI-Config im Chip)
- Aber Kernel-Binding verliert die FPGA-Seite
- → `ad9361_init.sh` muss nochmals ausgeführt werden

---

## Vollständige Init-Sequenz (nach Neustart oder JTAG-Reprogram)

```bash
# 1. JTAG: Bitstream laden (vom Host-PC)
vivado -mode batch -source scripts/program_fpga.tcl

# 2. AD9361 initialisieren (vom Host-PC via SSH)
./scripts/ad9361_init.sh

# Oder manuell auf dem Board:
# insmod /root/kernel_modules32/ad9361_drv.ko
# echo '' > /sys/bus/spi/devices/spi0.0/driver_override
# echo spi0.0 > /sys/bus/spi/drivers/ad9361/unbind 2>/dev/null || true
# echo spi0.0 > /sys/bus/spi/drivers/ad9361/bind
# sleep 3
# iio_attr -c ad9361-phy voltage0    sampling_frequency 4608000
# iio_attr -c ad9361-phy altvoltage0 frequency          430000000
# iio_attr -c ad9361-phy altvoltage1 frequency          440000000
# iio_attr -c ad9361-phy voltage0    gain_control_mode  slow_attack
# iio_attr -c ad9361-phy voltage0    rf_bandwidth       5760000
# iio_attr -d ad9361-phy             ensm_mode          fdd
```

---

## TETRA-Konfiguration (verifiziert 2026-04-07)

| Parameter | Wert | Bemerkung |
|-----------|------|-----------|
| RX LO | 430 000 000 Hz | TETRA 70cm Amateur DE |
| TX LO | 440 000 000 Hz | 10 MHz Duplex-Abstand |
| Sample Rate | 4 607 999 Hz | ≈ 4.608 MSPS |
| BBPLL | 1 179 647 997 Hz | Auto berechnet |
| ADC Rate | 36 863 999 Hz | Intern, vor Decimation |
| RXSAMP | 4 607 999 Hz | Output zur FPGA-Fabric |
| RX BW | 5 760 000 Hz | 1.25× Samplerate |
| Gain Mode | slow_attack | AGC |
| ENSM | fdd | Full-Duplex |
| RX Port | A_BALANCED | LibreSDR Standard |

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

**Timing:** WNS = +0.017 ns (clk_sys 100 MHz) ✅

---

## Bekannte Probleme

| Problem | Ursache | Workaround |
|---------|---------|------------|
| AD9361 kein IIO nach Boot | Modul fehlt im Kernel | `insmod /root/kernel_modules32/ad9361_drv.ko` |
| Bind schlägt fehl | driver_override=spidev | `echo '' > .../driver_override` |
| AD9361 Default nach JTAG | Chip-Reinit durch Treiber | `ad9361_init.sh` nochmals ausführen |
| cf-ad9361-lpc kein IIO | AXI-DMA nicht verbunden | Kein Problem — TETRA nutzt eigenen DMA-Pfad |

---

**Letzte Aktualisierung:** 2026-04-07  
**Erstellt durch:** Hardware-Deployment-Session
