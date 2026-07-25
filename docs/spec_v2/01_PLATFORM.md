# 01 — Plattform, Clocking, Ressourcen-Budget

**Scope:** Zielhardware, PS/PL-Aufteilung auf Board-Ebene, Clock- und Reset-Architektur,
Symbol-Tick-Erzeugung, verbindliche CDC-Muster, AD9361-Fabric-Interface, RF-Konfiguration
(Bänder, DL/UL, Duplex-Tabelle, Kanalzuordnung), Board-Bring-up-Reihenfolge und das
verbindliche Ressourcen-Budget für V2.

**Nicht hier:**
Signalverarbeitung → `02_PHY_DL_RX`, `03_PHY_UL_RX`, `04_PHY_TX_TDMA`.
Kanalcodierung → `05_CHANNEL_CODING`.
Register-Adressen, Mailbox-Protokolle, IRQ-Semantik → `07_PS_PL_CONTRACT`.
TDMA-Deadlines, Reply-Fenster, DL→UL-Air-Lock → `08_TIMING`.
Vivado-Flow, Cross-Compile, Deploy-Pipeline → `15_BUILD_DEPLOY`.
V1-Bug-Katalog → `17_LESSONS_LEARNED`.

**Abhängigkeiten:** `00_OVERVIEW` (Zielbild, Architektur-Cut).

---

## 1. Anforderungen

| ID | Anforderung | Abnahmekriterium |
|---|---|---|
| R-01-01 | Zielplattform ist LibreSDR Rev.5 mit Zynq-7020 **XC7Z020-CLG400-1** und AD9361/AD9363. | Kopfzeile von `report_utilization` nennt `xc7z020clg400-1`. |
| R-01-02 | Das PL hat genau **zwei** physische Clock-Domänen: `clk_sys` (100 MHz, PS `FCLK_CLK0`) und `clk_lvds` (AD9361 `DATA_CLK`, 18,432 MHz). Eine dritte, vierte oder „sample"-Domäne existiert nicht. | `report_clocks` listet außer `clk_fpga_0` und `rx_clk` nur `clk_fpga_1`, und `clk_fpga_1` treibt ausschließlich IP-internes IDELAYCTRL. |
| R-01-03 | Der AXI4-Lite-Slave läuft in `clk_sys`. `tetra_zynq_top` hat **keinen** separaten `s_axi_aclk`-Port und keine Synchronisierer zwischen „sys" und „axi". | Portliste von `tetra_zynq_top` enthält genau einen Clock-Eingang. `grep -c ASYNC_REG` über `rtl/**` liefert nur Treffer in den CDC-Helper-Modulen (R-01-09). |
| R-01-04 | Reset ist active-low, wird asynchron asserted und pro Domäne synchron über eine 2-FF-Kette mit `ASYNC_REG` deasserted. | `report_cdc` weist für die Reset-Pfade `Safe` aus; XDC enthält `set_false_path` auf die jeweils erste Stufe. |
| R-01-05 | Der Symbol-Tick beträgt exakt 18 000,000 Hz und wird ausschließlich aus `clk_lvds` durch Teilung erzeugt — nicht aus `clk_sys`. | Simulation: 1024 `clk_lvds`-Takte pro `sym_en_sys`-Puls; Air: Slot-Zähler driftet gegen die MS-Zeitbasis über 60 s nicht messbar. |
| R-01-06 | `sym_en_sys` wird an genau **einer** Stelle im Design erzeugt und von dort verteilt. Ein zweiter Teiler auf denselben Takt ist verboten. | Netzliste: genau eine Instanz von `tetra_sym_tick`. |
| R-01-07 | Das PL misst die `clk_lvds`-Frequenz und stellt sie als Status bereit. TX bleibt gesperrt, solange die Messung außerhalb 18,432 MHz ±0,5 % liegt. | Statusregister liest den Zählerstand 1 843 200 ±9 216 pro 100-ms-Fenster (§3.4); TX-Enable wird bei künstlich gestopptem `DATA_CLK` verweigert. |
| R-01-08 | Kein Statusbit darf konstant verdrahtet sein. Ein Bit, dessen Quelle fehlt, existiert nicht. | Netzliste: kein Status-Bit mit konstantem Treiber. |
| R-01-09 | Jede Domänenüberschreitung nutzt genau eines von fünf zugelassenen Mustern (§3.5). `ASYNC_REG`-Register existieren ausschließlich in `tetra_clk_reset`, `tetra_cdc_level`, `tetra_cdc_pulse`, `tetra_cdc_bus`, `tetra_cdc_gray`. | Grep-Gate im Build: `ASYNC_REG` außerhalb dieser fünf Dateien = Build-Fehler. |
| R-01-10 | `report_cdc` weist für alle `tetra_*`-Instanzen 0 `Unsafe` und 0 `No ASYNC_REG` aus. IP-interne Restbefunde stehen mit Begründung in einer Waiver-Datei. | `build/reports/cdc_report.rpt` + `constraints/cdc_waivers.xdc`. |
| R-01-11 | Im Block Design werden nur die tatsächlich benutzten `axi_ad9361`-Fabric-Pins verbunden. Ports ohne Konsumenten werden nicht durch das PL geführt. | BD-Netzliste; `tetra_zynq_top` hat keine Ports, die im RTL nur in einem Lint-Sink landen. |
| R-01-12 | ADC-Daten sind 12-bit-Zweierkomplement, vorzeichenerweitert auf 16 bit. Die Kanalregister des ADI-Cores müssen `dfmt_enable` **und** `dfmt_se` gesetzt haben. | Bring-up-Verifikation liest die Kanalregister zurück; RX-IQ-Capture enthält negative Werte. |
| R-01-13 | Der operative TX-Pegel wird ausschließlich über `out_voltage0_hardwaregain` (TX1) gesetzt. `out_voltage1` (TX2) ist auf diesem Board wirkungslos. | Pegeländerung an `out_voltage0` ist am HF-Ausgang messbar, an `out_voltage1` nicht. |
| R-01-14 | Die Duplex-Spacing-Tabelle hat 8 Einträge (Feldwerte 0…7), ist zur Laufzeit editierbar, wird persistiert und ist die **einzige** Quelle für die UL-Frequenzberechnung `f_UL = f_DL + offset[i]`. | Änderung eines Tabelleneintrags in der WebUI verschiebt nach Übernahme die RX-LO messbar; kein zweiter Codepfad rechnet die UL-Frequenz. |
| R-01-15 | Es gibt genau eine Konfigurations-/WebUI-Implementierung. Ein zweiter `apply`-Pfad ist verboten. | Repo enthält genau ein `apply`-Skript und genau ein Config-Lese-Skript. |
| R-01-16 | Die Bring-up-Sequenz (§3.8) ist normativ, inklusive **zweimaligem** Bitstream-Load. Jeder Load wird über `fpga0/state == operating` verifiziert; sonst Abbruch. | Boot-Log enthält beide Loads mit State-Prüfung; Einzel-Load-Variante ist nicht implementiert. |
| R-01-17 | Vor `fpga0/state == operating` erfolgt kein Zugriff auf die PL-AXI-Apertur. | Boot-Log-Reihenfolge; kein `devmem` vor der State-Prüfung. |
| R-01-18 | TX ist von Boot-Beginn bis zum Health-Gate auf den Init-Dämpfungswert gesetzt und wird erst nach erfolgreichem Gate auf den operativen Pegel gebracht. | Boot-Log zeigt Init-Pegel vor und operativen Pegel nach dem Gate. |
| R-01-19 | Das Ressourcen-Budget in §3.9 ist einzuhalten. **Slice-Auslastung ist kein Kriterium** und darf in keiner Entscheidung als Grenze auftreten. | `report_utilization` + `report_timing_summary` gegen die Budget-Tabelle. |
| R-01-20 | Alle Boot-Parameter stehen in genau einer Konfigurationsdatei. Fehlt eine Pflichtvariable, bricht der Boot mit Fehlermeldung ab statt einen Default zu erfinden. | Test: Variable entfernen → Boot bricht ab, Log nennt die Variable. |
| R-01-21 | AD9361-Attribute werden im Boot-Kontext ausschließlich per direktem sysfs-Write gesetzt, nie über `iio_attr`. | Boot-Skript enthält kein `iio_attr`; Boot läuft ohne Hänger durch. |
| R-01-22 | Der programmierbare RX-FIR des AD9361 wird **nicht** benutzt (§3.10). | Kein Codepfad schreibt `in_voltage_filter_fir_en` oder lädt FIR-Koeffizienten. |
| R-01-23 | DL- und UL-Sync-Detektor haben **getrennte** Korrelator-Schwellen in zwei eigenen Registern (Namen/Adressen in `07_PS_PL_CONTRACT`). Jede Schwelle wird im RTL gegen die Sequenzlänge ihres Detektors begrenzt; ein Wert oberhalb der Sequenzlänge ist als „Match unmöglich" abzuweisen, nicht stillschweigend zu übernehmen. | Testbench: Schwelle > Sequenzlänge → Detektor meldet Fehlerstatus, nicht dauerhaft `sync_found = 0` ohne Hinweis. Board: DL-Schwelle 11 und UL-Schwelle 15 gleichzeitig setzbar; beide Detektoren locken (§4). |

---

## 2. Architektur / Aufbau

### 2.1 Zielhardware

| Komponente | Spezifikation | Beleg |
|---|---|---|
| Board | LibreSDR Rev.5 | [CODE docs/HARDWARE.md:18] |
| FPGA/SoC | Zynq-7020, Part `xc7z020clg400-1` | [CODE scripts/vivado_build.tcl:38], [BUILD 2026-07-12 build/reports/impl_utilization.rpt, Header-Zeile „Part"] |
| PL-Kapazität | 53 200 LUT, 106 400 FF, 140 BRAM-Tiles (=280 RAMB18), 220 DSP48E1, 125 nutzbare IOB | Device-Konstanten (Xilinx-7-Series-Datenblatt), im Build gegengelesen aus der Spalte „Available" [BUILD 2026-07-12 build/reports/impl_utilization.rpt §1–§5] |
| RF-Transceiver | AD9363 (1R1T bestückt), softwareseitig als AD9361 betrieben | [CODE docs/HARDWARE.md:20] |
| Referenztakt | 40 MHz VCXO, per DAC5311 (8 bit, SPI 3-wire) getrimmt | [CODE scripts/vcxo_cal.sh:7–19] |
| Netz | Gigabit Ethernet über PS ENET0 (MIO 16…27), Board-IP im Testaufbau `192.168.2.90` | [CODE scripts/create_bd.tcl:137], [CODE scripts/tetra_ctrl.sh:29] |
| Betriebssystem | OpenWiFi-Linux 5.10, AD9361-IIO-Treiber als nachladbares Modul | [CODE scripts/ad9361_init.sh:18–31] |

> **Achtung Drift:** Mehrere V1-Quellen nennen `XC7Z020-CLG484`
> ([CODE rtl/tetra_zynq_top.v:8], [CODE rtl/tetra_system_top.v:22],
> [CODE constraints/libresdr_tetra.xdc:4], [CODE docs/HARDWARE.md:19]).
> Der real gebaute Part ist **CLG400**
> — die Utilization-Reports weisen 125 nutzbare IOB aus, was zu CLG400 passt.
> V2 nennt CLG400, überall.

### 2.2 PS/PL-Aufteilung auf Board-Ebene

```
 ┌─────────────────────────── Zynq-7020 PS ───────────────────────────┐
 │ Cortex-A9 ×2  ·  DDR3 (32 bit, 534 MHz)  ·  SD0  ·  UART0  ·  ENET0 │
 │ SPI0 (EMIO) → AD9361-Register      I2C0 (EMIO) → Board-I2C          │
 │ GPIO EMIO 64 bit → AD9361-Control, LEDs, VCXO-DAC                   │
 │ FCLK_CLK0 100 MHz   FCLK_CLK1 200 MHz   FCLK_RESET0_N               │
 │ M_AXI_GP0 (Control)                                                 │
 └───────┬──────────────────────────────┬──────────────────────────────┘
         │ GP0                          │ FCLK_CLK1 (IDELAYCTRL-Referenz)
 ┌───────▼──────────────┐      ┌────────▼───────────────────────────────┐
 │  AXI-Interconnect    │      │  axi_ad9361 (ADI IP)                   │
 │  (Control, 1→2)      │      │  · LVDS-DDR-I/O 6 Paare + Frame + Clk  │
 │  M00 → tetra PL      │      │  · ad_datafmt (12→16 bit sign-extend)  │
 │  M01 → axi_ad9361    │      │  · l_clk = BUFG(IBUFGDS(DATA_CLK))     │
 └───────┬──────────────┘      └────────┬───────────────────────────────┘
         │ AXI4-Lite (clk_sys)          │ l_clk, adc_data_i0/q0, adc_valid_i0
 ┌───────▼──────────────────────────────▼───────────────────────────────┐
 │  tetra_zynq_top  (unser PL-Design)                                   │
 │   tetra_clk_reset · tetra_sym_tick · tetra_clk_monitor               │
 │   tetra_ad9361_if (Fabric-IQ + Loopback-Mux)                         │
 │   RX-Kette (02/03) · TX-Kette (04) · LMAC (05/06) · Registerbank (07)│
 └──────────────────────────────────────────────────────────────────────┘
                        │ dac_data_i0/q0
                        ▼  → axi_ad9361 → AD9361 TX1
```

**Aufteilungsregel:** Das PL macht nur, was zeitkritisch an der TDMA-Zeitbasis hängt.
Alles, was nicht innerhalb eines Slots antworten muss, läuft im PS. Die konkrete
Schnittstelle beschreibt `07_PS_PL_CONTRACT`.

**Aus V1 entfernt (nachweislich ohne Funktion — Befund je Zeile belegt):**

| Struktur | Befund | Beleg |
|---|---|---|
| Xilinx AXI-DMA (S2MM) + HP0-Interconnect | `m_axis_tvalid` ist konstant 0; kein SW-Konsument (`grep -rn "S2MM\|axidma\|dma_proxy\|REG_DMA_BLK_CNT" sw/` ohne Treffer). `REG_DMA_BLK_CNT` ist ein unbenutztes `#define`, das PL liefert dort konstant 0 | [CODE rtl/tetra_zynq_top.v:935], [CODE rtl/tetra_zynq_top.v:941], [CODE sw/tetra_hal.h:43] |
| PS-IRQ-Pfad (`o_irq` → `IRQ_F2P[1]`) + IRQ-Register | Drei der fünf Quellen sind konstant 0: `irq_mac_block_sys` [CODE rtl/tetra_zynq_top.v:940], der auf 0 gehaltene CRC-Toggle [CODE rtl/tetra_zynq_top.v:1473–1475] und `dma_fifo_full_sys` [CODE rtl/tetra_zynq_top.v:943]. Die beiden SYNC-Flankenquellen sind **live** [CODE rtl/tetra_zynq_top.v:1461,1464], bleiben aber wirkungslos: `irq_out_axi <= \|(irq_status_axi & irq_enable_axi)` bei `irq_enable_axi = 5'b0` nach Reset, und SW schreibt `REG_IRQ_ENABLE` nie (nur `#define`, keine Verwendung in `sw/*.c`). SW pollt. **Die SYNC-Ereignisse selbst bleiben** — §3.4/§3.8 B11 wertet `SYNC_LOCKED` aus; entfernt wird nur die ungenutzte Interrupt-Verdrahtung zum PS | [CODE rtl/infra/tetra_axi_lite_regs.v:1612,1622–1626,2655], [CODE sw/tetra_hal.h:41], [CODE scripts/create_bd.tcl:278,464–467] |
| `up_enable`/`up_txnrx` als BD-Ports in die ADI-IP | Der Pfad ist vorhanden, aber wirkungslos: BD-**Eingangs**ports `up_enable`/`up_txnrx` [CODE scripts/create_bd.tcl:541–544], gespeist aus `gpio_o[47]/[48]` [CODE rtl/tetra_system_top.v:320–321]. Kein Skript beschreibt Linux-GPIO 1007/1008 (`grep` über `scripts/`, `board_autostart/` ohne Treffer), beide Eingänge liegen dauerhaft auf 0, und die IP läuft mit `TDD_DISABLE = 1` (§3.1). Der ENSM wird über SPI gesteuert | [CODE scripts/create_bd.tcl:541–544], [CODE rtl/tetra_system_top.v:320–321], [CODE board_autostart/tetra_autostart.sh:121] |
| Vierte Reset-Domäne `clk_sample` | `.clk_sample(clk_sys)`, `.rst_n_sample()` offen | [CODE rtl/tetra_zynq_top.v:206,210] |
| Register für RX-Gain / TX-Attenuation im PL | Reine Scratch-Register ohne Konsument; HF-Pegel läuft über AD9361-sysfs | [CODE rtl/infra/tetra_axi_lite_regs.v:1596,1604] und keine Verwendung in `rtl/**` |

### 2.3 Board-I/O

**LVDS zum AD9361** (LVDS_25, `DIFF_TERM TRUE` auf allen Eingängen)
— 6 Datenpaare pro Richtung, DDR, plus Frame und Clock:
`rx_clk_in_p/n` (N20/P20, SRCC Bank 34), `rx_frame_in_p/n` (U18/U19),
`rx_data_in_p/n[5:0]`, `tx_clk_out_p/n` (N18/P19), `tx_frame_out_p/n` (Y16/Y17),
`tx_data_out_p/n[5:0]` [CODE constraints/libresdr_tetra.xdc:26–67].

**EMIO-GPIO-Belegung** (64 bit, Reihenfolge ist Board-Faktum, nicht frei wählbar):

| EMIO-Bit | Linux-GPIO | Richtung | Funktion | Beleg |
|---|---|---|---|---|
| 20 | 980 | O | `pl_led0` (J20) | [CODE rtl/tetra_system_top.v:154] |
| 22 | 982 | O | `pl_led1` (H20) | [CODE rtl/tetra_system_top.v:155] |
| 39:32 | 992…999 | I | `gpio_status[7:0]` ← AD9361 (T11,T14,T15,T17,T19,T20,U13,V13) | [CODE rtl/tetra_system_top.v:184] |
| 43:40 | 1000…1003 | IO | `gpio_ctl[3:0]` (IOBUF) | [CODE rtl/tetra_system_top.v:220–246] |
| 44 | 1004 | IO | `gpio_en_agc` (P16) | [CODE rtl/tetra_system_top.v:213] |
| 45 | 1005 | IO | `gpio_sync` (U20) | [CODE rtl/tetra_system_top.v:206] |
| 46 | 1006 | IO | `gpio_resetb` (N17) — AD9361-Hardware-Reset, active-low | [CODE rtl/tetra_system_top.v:199] |
| 47 | 1007 | O | AD9361 `ENABLE` (R18) | [CODE rtl/tetra_system_top.v:162] |
| 48 | 1008 | O | AD9361 `TXNRX` (P14) | [CODE rtl/tetra_system_top.v:163] |
| 51 | 1011 | O | DAC5311 `CS` (H18, active-low) | [CODE scripts/vcxo_cal.sh:11] |
| 52 | 1012 | O | DAC5311 `SCLK` (F19) | [CODE scripts/vcxo_cal.sh:12] |
| 53 | 1013 | O | DAC5311 `DIN` (F20) | [CODE scripts/vcxo_cal.sh:13] |

**ENABLE/TXNRX:** Beide Pins werden aus `gpio_o[47]/[48]` getrieben und von keinem
Skript beschrieben, liegen also dauerhaft auf 0. Der AD9361 wird ausschließlich über
SPI-ENSM gesteuert (`ensm_mode = fdd`), nicht über Pin-Control
[CODE board_autostart/tetra_autostart.sh:121]. V2 dokumentiert diesen Zustand
explizit als Entwurfsentscheidung; die EMIO-Bits bleiben verdrahtet, falls
Pin-Control später gebraucht wird.

**Weitere Board-Signale:** SPI0 (`spi_csn` P18 mit Pull-up, `spi_clk` R14,
`spi_mosi` P15, `spi_miso` R19), I2C0 (`iic_scl` M15, `iic_sda` K16, beide LVCMOS33
mit Pull-up) [CODE constraints/libresdr_tetra.xdc:78–113].

---

## 3. Detail-Spezifikation

### 3.1 Clock-Architektur

**Ableitungskette (durchgängig exakt, keine gebrochenen Verhältnisse):**

```
40,000 MHz VCXO  →  AD9361 BBPLL  →  Sample-Rate 4,608 MSPS
                                         │
                     LVDS 2R2T DDR: DATA_CLK = 4 × 4,608 MHz = 18,432 MHz
                                         │
                     IBUFGDS → BUFG (ad_data_clk)  →  clk_lvds = 18,432 MHz
                                         │
                    ┌────────────────────┴─────────────────────┐
                    │ /1024                                    │ /4
              18 000,000 Hz Symbol-Tick                  4,608 MHz DAC-Rate
                    │                                          │
              /255 → 70,588 Slots/s                     RX: /64 → 72 kHz
              (Slot = 255/18000 s = 85/6 ms)             (= 4 Samples/Symbol)
```

Belege: `DATA_CLK = 4 × sample_rate = 4 × 4,608 MSPS`
[CODE rtl/tx/tetra_tx_frontend.v:13–14]; `18 432 000 / 1024 = 18 000,000 Hz`
[CODE rtl/tetra_zynq_top.v:953–954]; CIC-Dezimation `R = 64`, `4 608 000/64 = 72 000 Hz`
[CODE rtl/rx/tetra_rx_frontend.v:74–75]; ADC-Core `r1_mode = 0` ist Pflicht für 2R2T-DDR,
sonst pulst `adc_valid_i0` nie [CODE scripts/tetra_ctrl.sh:203–219].

**ETSI-Abgleich:** 255 Phasenmodulationssymbole je Slot, jedes 1/18 ms
[ETSI §9.4.3.2]. Slot 85/6 ms [ETSI §9.3.3, Zeile „A timeslot shall have a duration of
85/6 ms"], TDMA-Frame 170/3 ms = 4 Slots [ETSI §9.3.4], Multiframe 18 Frames = 1,02 s
[ETSI §9.3.7], Hyperframe 60 Multiframes = 61,2 s [ETSI §9.3.8]. Modulationsrate
36 kbit/s bei π/4-DQPSK, also 18 000 Symbole/s [ETSI §5.3]; Roll-off α = 0,35
[ETSI §5.5, Gl. 5.4].

**Domänen-Tabelle (V2, verbindlich):**

| Domäne | Netzquelle | Frequenz | Suffix | Verbraucher |
|---|---|---|---|---|
| `clk_sys` | PS7 `FCLK_CLK0`, BUFG | 100,000 MHz | `_sys` | Alles außer LVDS-Erfassung: RX-Frontend ab FIFO, Demod, Sync, LMAC, TDMA-Zeitbasis, Registerbank, AXI4-Lite-Slave |
| `clk_lvds` | AD9361 `DATA_CLK` über `ad_data_clk` (IBUFGDS→BUFG) | 18,432 MHz | `_lvds` | `tetra_ad9361_if`, Schreibseite des RX-CDC-FIFO, Leseseite des TX-CDC-FIFO, TX-CIC-Interpolator, Symbol-Tick-Teiler |
| (`FCLK_CLK1`) | PS7 | 200,000 MHz | — | Ausschließlich `axi_ad9361.delay_clk` (IDELAYCTRL-Referenz). Kein eigenes RTL. |

Kein PLL und kein MMCM liegt im `DATA_CLK`-Pfad: `ad_data_clk` besteht aus
`IBUFGDS` + `BUFG` [CODE build/vivado/tetra_zynq_phy.gen/sources_1/bd/tetra_system/ipshared/xilinx/common/ad_data_clk.v:66,73],
instanziiert bei `USE_SSI_CLK = 1`
[CODE build/vivado/tetra_zynq_phy.gen/sources_1/bd/tetra_system/ipshared/2466/xilinx/axi_ad9361_lvds_if.v:614].
IP-Parameter `USE_SSI_CLK = 1`, `CMOS_OR_LVDS_N = 0`, `MIMO_ENABLE = 1`,
`MODE_1R1T = 0`, `TDD_DISABLE = 1`, `DAC_DDS_DISABLE = 1`, `IODELAY_CTRL = 1`,
`DELAY_REFCLK_FREQUENCY = 200`, `ADC_INIT_DELAY = 30`
[CODE build/vivado/tetra_zynq_phy.srcs/sources_1/bd/tetra_system/tetra_system.bd, Komponente `axi_ad9361_0`].

**Ein-Domänen-Entscheidung für 100 MHz.** In V1 sind `i_clk` und `s_axi_aclk` beide
mit `FCLK_CLK0` verbunden [CODE scripts/create_bd.tcl:290–311], werden aber als
unabhängige Domänen behandelt. Das kostet **3 790 FF** reine Synchronisier-Register
(1 894 bit Richtung sys, 1 896 bit Richtung axi, gezählt über alle
`ASYNC_REG`-Deklarationen in `rtl/tetra_zynq_top.v`) bei null Nutzen; das
Clock-Interaction-Report kennt ohnehin nur eine Domäne `clk_fpga_0`
[BUILD 2026-07-12 build/reports/clock_interaction.rpt]. **V2 hat eine einzige
100-MHz-Domäne.** Registerbank-Ausgänge gehen direkt an ihre Verbraucher.
Pipeline-Register aus Fanout- oder Timing-Gründen sind erlaubt, müssen aber als
Pipeline benannt und kommentiert sein (`_p0`, `_p1`), nicht als CDC.

**XDC-Vorgaben:**

- `create_clock -name rx_clk -period <P> [get_ports rx_clk_in_p]`.
  V1 setzt `P = 4` ns (250 MHz) [CODE constraints/libresdr_tetra.xdc:135] — das
  überconstraint die 18,432-MHz-Domäne um Faktor 13,6. Die Pfade halten es
  (`rx_clk` WNS +0,278 ns bei 4 ns) [BUILD 2026-07-12 build/reports/impl_timing.rpt:166],
  aber der Router investiert Aufwand in 3 752 Endpunkte, während `clk_fpga_0`
  mit WNS +0,006 ns am Limit steht. **V2 setzt `P = 20` ns** (deckt jede
  DATA_CLK-Rate bis 50 MHz, also Sample-Raten bis 12,5 MSPS in 2R2T) und
  dokumentiert die Abhängigkeit im XDC-Kommentar. [ANNAHME] — die Wirkung auf
  `clk_fpga_0`-WNS ist nicht gemessen; Messung ist Teil der Abnahme (§5).
- `set_clock_groups -asynchronous -group [get_clocks rx_clk] -group [get_clocks clk_fpga_0]`
  bleibt. Diese Direktive unterdrückt **nur die Timing-Analyse**; sie macht keine
  Überschreitung sicher. Sicherheit kommt aus §3.5.
- Multicycle-Pfade sind zulässig, aber nur mit begründeter Datenrate im Kommentar
  (V1-Muster: [CODE constraints/libresdr_tetra.xdc:164–262]). Ein Multicycle-Pfad
  ohne benannte Update-Rate ist ein Fehler.

### 3.2 Reset-Architektur — `tetra_clk_reset`

**Zweck:** Aus dem asynchronen `arst_n` (aus `proc_sys_reset.peripheral_aresetn`)
pro Clock-Domäne einen active-low-Reset erzeugen, der asynchron asserted und
synchron deasserted wird.

**Schnittstelle:**

| Signal | Breite | Richtung | Domäne | Bedeutung |
|---|---|---|---|---|
| `arst_n` | 1 | in | async | Reset-Quelle, active-low |
| `clk_sys` | 1 | in | — | 100 MHz |
| `clk_lvds` | 1 | in | — | 18,432 MHz |
| `rst_n_sys` | 1 | out | `clk_sys` | synchronisierter Reset |
| `rst_n_lvds` | 1 | out | `clk_lvds` | synchronisierter Reset |

**Verhalten:** Je Domäne zwei `(* ASYNC_REG = "TRUE" *)`-Register in Kette; beide
mit `negedge arst_n` im asynchronen Reset-Zweig. Assert-Latenz 0 Takte,
Deassert-Latenz exakt 2 steigende Flanken der Zieldomäne. Muster wie
[CODE rtl/infra/tetra_clk_reset.v:88–107], reduziert auf zwei Domänen.

**Deassert-Reihenfolge (Konsequenz der Frequenzen):** `rst_n_sys` nach 20 ns,
`rst_n_lvds` nach 108,5 ns. `clk_sys`-Logik läuft also vor der LVDS-Domäne an.
Jede Struktur, die beide Domänen berührt, muss diesen Zustand vertragen:
FIFO-Schreibseite ist bis dahin im Reset, `sym_en_sys` bleibt aus. Reset-Handshakes
über die Domänengrenze sind verboten.

**Randfall `clk_lvds` fehlt.** Kommt `DATA_CLK` nicht (AD9361 nicht initialisiert),
bleibt `rst_n_lvds` auf 0 und die gesamte LVDS-Domäne steht. Das darf `clk_sys`
nicht blockieren: `tetra_ad9361_if` und alle CDC-Strukturen müssen so ausgelegt
sein, dass ein stehender `clk_lvds` die AXI-Seite weder blockiert noch hängt
(kein Handshake mit Warten auf die LVDS-Seite; §3.5 P3 verlangt deshalb
Timeout-freie, zustandslose Leserichtung).

**Ressourcen:** 4 FF, 0 LUT [ANNAHME: aus der Struktur abgeleitet; V1 mit vier
Domänen wies 3 LUT / 6 FF aus, BUILD 2026-05-18 build/reports/impl_hier_util.rpt
`u_clk_reset`].

### 3.3 Symbol-Tick — `tetra_sym_tick`

**Zweck:** Den einzigen 18-kHz-Takt des Systems erzeugen. Die gesamte TDMA-Zeitbasis
(`04_PHY_TX_TDMA`, `08_TIMING`) hängt daran.

**Schnittstelle:**

| Signal | Breite | Richtung | Domäne | Bedeutung |
|---|---|---|---|---|
| `clk_lvds` / `rst_n_lvds` | 1 | in | `clk_lvds` | Quelltakt |
| `clk_sys` / `rst_n_sys` | 1 | in | `clk_sys` | Zieltakt |
| `sym_en_sys` | 1 | out | `clk_sys` | 1-Takt-Puls, 18 000 Hz |
| `sym_phase_lvds` | 10 | out | `clk_lvds` | Teilerstand 0…1023, für TX-Frontend-Ausrichtung |

**Parameter:** `DIV = 1024`. Bedingung: `DIV = f(clk_lvds) / 18000`. Bei
`f(clk_lvds) = 18,432 MHz` ist `DIV = 1024` exakt und jitterfrei. Ändert sich die
AD9361-Sample-Rate, ist `DIV` falsch — deshalb ist die Frequenzmessung aus §3.4
Pflicht und nicht optional.

**Verhalten:** 10-bit-Zähler in `clk_lvds`; bei `DIV-1` Rücksetzen und `sym_toggle_lvds`
invertieren. `sym_toggle_lvds` läuft über eine 2-FF-`ASYNC_REG`-Kette nach `clk_sys`,
dort Flankendetektion gegen eine dritte Stufe → 1-Takt-Puls
(Muster: [CODE rtl/tetra_zynq_top.v:959–991]).

**Timing:** Der Puls kommt 2…3 `clk_sys`-Takte (20…30 ns) nach der
`clk_lvds`-Flanke, Jitter also ±1 `clk_sys`-Takt (10 ns). Die Latenz ist **nicht**
konstant: beide Takte laufen frei, die Abtastphase zwischen ihnen ist nicht
gekoppelt, und das Toggle wird über zwei `ASYNC_REG`-Stufen plus eine dritte
Flankenerkennungsstufe abgetastet (V1-Muster:
[CODE rtl/tetra_zynq_top.v:975–977,991]). Driftfrei ist nur der **Mittelwert**, weil
die Teilung ganzzahlig ist (18 432 000/1024 = 18 000,000 Hz exakt). Bei 55,56 µs
Symboldauer sind ±10 ns 1,8·10⁻⁴ Symbol; für die Slot-Deadlines in `08_TIMING`
ist dieser Jitter als konstanter Unsicherheitsbeitrag von einem `clk_sys`-Takt
einzurechnen, nicht als Drift.

**Ressourcen:** ~14 FF, ~12 LUT [ANNAHME: 10-bit-Zähler + Komparator + 4 FF CDC].

**Verbot:** `sym_en_sys` darf nicht aus `clk_sys` heraus per Zähler nachgebildet
werden (100 MHz / 18 000 = 5555,56 — nicht ganzzahlig, ergibt Drift gegen die
Luftzeitbasis).

### 3.4 `clk_lvds`-Überwachung — `tetra_clk_monitor`

**Motivation:** V1 verdrahtet das Statusbit `PLL_LOCKED` konstant auf 1
[CODE rtl/tetra_zynq_top.v:2040 `.pll_locked_axi (1'b1)`]. Es gibt also keine
Aussage darüber, ob `DATA_CLK` läuft oder die richtige Frequenz hat — obwohl genau
das der häufigste Bring-up-Fehlerzustand ist. Die ADI-IP exportiert kein
`locked`-Signal (der BD hat keinen solchen Port; der `locked`-Ausgang von
`ad_data_clk` ist IP-intern offen gelassen
[CODE .../axi_ad9361_lvds_if.v:614–619]).

**Funktion:** Zähler in `clk_lvds` (Breite 24 bit), der über ein aus `clk_sys`
abgeleitetes Messfenster von genau 100 ms (10 000 000 `clk_sys`-Takte) gezählt
wird. Fenster-Start/-Ende werden als Toggle nach `clk_lvds` synchronisiert (P2),
der Zählerstand als Bus zurück (P3). Erwartungswert 1 843 200 ±9 216 (±0,5 %).

**Ausgänge (Registernamen und Adressen in `07_PS_PL_CONTRACT`):**
`lvds_freq_meas_sys[23:0]` (letzter gültiger Zählerstand),
`lvds_alive_sys` (mindestens ein Fensterergebnis ≠ 0 in den letzten 3 Fenstern),
`lvds_in_range_sys` (Erwartungsfenster eingehalten).

**Gate:** TX-Enable im PL wird mit `lvds_in_range_sys` UND-verknüpft. Ohne gültige
Messung sendet das Board nicht. Das ersetzt das konstante Statusbit und macht
R-01-07/R-01-08 prüfbar.

**Ressourcen:** ~40 FF, ~50 LUT [ANNAHME: 24-bit-Zähler + 24-bit-Fensterzähler +
Vergleich + CDC].

### 3.5 CDC-Grundregeln (verbindliches Muster)

**Ausgangslage V1:** `report_cdc` weist für `clk_fpga_0 → rx_clk` **146 Endpunkte,
davon 36 safe, 79 unsafe, 31 unknown** aus, für `rx_clk → clk_fpga_0` **110
Endpunkte, 36 safe, 0 unsafe, 74 unknown** [BUILD 2026-07-12 build/reports/cdc_report.rpt].
Die `set_clock_groups -asynchronous`-Direktive unterdrückt nur die Analyse; die
79 unsicheren Endpunkte bleiben unsichere Endpunkte. Ein zusätzliches XDC, das
`ASYNC_REG` per Namensmuster auf IP-interne Register setzen soll
[CODE constraints/adi_cdc_async_reg.xdc:27–60], adressiert eine andere Spalte des
Reports (`No ASYNC_REG`, dort steht 1) und ändert am Unsafe-Befund nichts. V1
unterscheidet auch nicht, welche der Endpunkte aus unserem RTL und welche aus der
ADI-IP kommen.

**V2-Regel:** Genau fünf Muster sind zugelassen. Für jedes existiert **ein**
Modul; Kopien im Design sind verboten (R-01-09).

| Muster | Modul | Wofür | Aufbau | Latenz |
|---|---|---|---|---|
| P1 Level | `tetra_cdc_level` | Einzelbit-Pegel, langsam wechselnd (Konfig, Enable, Status-Flag) | 2 `ASYNC_REG`-FF in Zieldomäne | 2 Zieltakte |
| P2 Puls | `tetra_cdc_pulse` | Einzelbit-Ereignis | Toggle in Quelle → P1 → XOR mit 3. Stufe → 1-Takt-Puls | 2–3 Zieltakte |
| P3 Bus | `tetra_cdc_bus` (Parameter `WIDTH`) | Mehrbit-Wert, kohärent | Quelle hält Daten stabil, setzt Toggle; Ziel übernimmt Daten im Puls-Takt. Daten selbst **nicht** synchronisiert | 2–3 Zieltakte |
| P4 Zähler | `tetra_cdc_gray` (Parameter `WIDTH`) | monoton um 1 inkrementierende Zähler | Gray-Kodierung, P1 pro Bit, Rückwandlung | 2 Zieltakte |
| P5 Strom | `xpm_fifo_async` | Sample-/Blockströme | `CDC_SYNC_STAGES = 2`, `READ_MODE = "std"`, `FIFO_READ_LATENCY = 1` (V1-Muster: [CODE rtl/rx/tetra_rx_frontend.v:223–238]) | FIFO-abhängig |

**Verbote:**

1. Ein Mehrbit-Bus darf **nie** bitweise über P1 laufen. Genau das erzeugt die
   `Unsafe`-Einträge: einzelne Bits kommen in unterschiedlichen Takten an, der
   Zielwert ist zwischenzeitlich ungültig. **Einzige Ausnahme ist P4:** bei
   Gray-Kodierung wechselt pro Quelltakt garantiert nur ein Bit, deshalb ist
   jeder abgetastete Zwischenwert entweder der alte oder der neue Zählerstand
   und damit gültig. Vorbedingung: der Quellzähler inkrementiert ausschließlich
   um 1, überspringt keinen Wert und wird nicht asynchron geladen. Jede
   Verletzung dieser Vorbedingung macht P4 unsicher — dann gilt P3.
2. Ein 1-Takt-Puls darf nie direkt über P1 laufen (bei `clk_lvds` ← `clk_sys`
   wäre er gar nicht sichtbar: 18,432 MHz gegen 100 MHz).
3. Kein Handshake, bei dem eine Seite auf die andere wartet. Steht `clk_lvds`,
   muss die `clk_sys`-Seite weiterlaufen (§3.2).
4. `ASYNC_REG` außerhalb der fünf Module ist ein Build-Fehler.

**Namenskonvention:** Ein Signal trägt das Suffix seiner Domäne. Der
Domänenwechsel findet ausschließlich am Ausgang eines CDC-Moduls statt, und dort
wechselt das Suffix — nirgends sonst. Beispiel:
`colour_code_sys` → `tetra_cdc_bus` → (in V2 nicht mehr nötig, da eine
100-MHz-Domäne) bzw. `sym_toggle_lvds` → `tetra_cdc_pulse` → `sym_en_sys`.

**Bestandsaufnahme, welche Crossings in V2 überhaupt bleiben:** Durch die
Ein-Domänen-Entscheidung (§3.1) verbleiben genau vier Übergänge:

| Von | Nach | Inhalt | Muster |
|---|---|---|---|
| `clk_lvds` | `clk_sys` | RX-IQ-Samples (32 bit: I,Q) | P5 |
| `clk_lvds` | `clk_sys` | Symbol-Toggle | P2 |
| `clk_lvds` | `clk_sys` | Frequenzmess-Zählerstand | P3 |
| `clk_sys` | `clk_lvds` | TX-IQ-Samples (32 bit) + Loopback-Enable | P5 + P1 |

Alles andere in V1 war sys↔axi und entfällt.

### 3.6 AD9361-Fabric-Interface — `tetra_ad9361_if`

**Zweck:** Einzige Berührungsstelle zwischen der ADI-IP und unserem Datenpfad.
Enthält zusätzlich den Digital-Loopback-Mux (in V1 im Top-Level verstreut,
[CODE rtl/tetra_zynq_top.v:342–344]).

**Schnittstelle zur IP** (Namen exakt wie am `axi_ad9361`-XCI-Rand):

| Signal | Breite | Richtung (aus PL-Sicht) | Domäne | Verwendung in V2 |
|---|---|---|---|---|
| `l_clk` | 1 | in | — | wird zu `clk_lvds` |
| `adc_data_i0` | 16 | in | `clk_lvds` | RX-I, signed, 12 bit sign-extended |
| `adc_data_q0` | 16 | in | `clk_lvds` | RX-Q, signed |
| `adc_valid_i0` | 1 | in | `clk_lvds` | einziger RX-Strobe (I und Q sind laut ADI-Interface gleichzeitig gültig) |
| `dac_data_i0` | 16 | out | `clk_lvds` | TX-I |
| `dac_data_q0` | 16 | out | `clk_lvds` | TX-Q |
| `adc_dovf` | 1 | out | `clk_lvds` | konstant 0 (im PL nicht detektierbar) |
| `dac_dunf` | 1 | out | `clk_lvds` | konstant 0 |

**Nicht verbinden** (R-01-11): `adc_valid_q0`, `adc_enable_i0`, `adc_enable_q0`,
`adc_r1_mode`, `dac_valid_i0`, `dac_valid_q0`, `dac_enable_i0`, `dac_enable_q0`,
`dac_r1_mode`. In V1 sind alle diese Ports durch das PL geführt und landen in
Lint-Sinks: die sieben Valid-/Enable-Signale in
[CODE rtl/tetra_ad9361_axis_adapter.v:148,187], die beiden `r1_mode`-Flags eine
Ebene höher, weil sie Ports von `tetra_zynq_top` und nicht des Adapters sind
[CODE rtl/tetra_zynq_top.v:102,109,354] — 9 toten Ports auf dem Top-Modul
entsprechen 9 Verbindungen im BD, die niemand pflegt.

**Schnittstelle zum Datenpfad:**

| Signal | Breite | Richtung | Domäne | Bedeutung |
|---|---|---|---|---|
| `rx_i_lvds`, `rx_q_lvds` | 16 signed | out | `clk_lvds` | RX-Samples nach Loopback-Mux |
| `rx_valid_lvds` | 1 | out | `clk_lvds` | RX-Strobe |
| `tx_i_lvds`, `tx_q_lvds` | 16 signed | in | `clk_lvds` | TX-Samples vom TX-Frontend |
| `tx_valid_lvds` | 1 | in | `clk_lvds` | TX-Strobe |
| `loopback_en_lvds` | 1 | in | `clk_lvds` | via P1 aus `clk_sys` |

**Bit-Order und Wertebereich.** `adc_data_i0[15]` ist MSB und Vorzeichen;
Zahlenformat Zweierkomplement. Der ADC liefert 12 bit; das `ad_datafmt`-Modul der
IP erweitert auf 16 bit **nur wenn** im ADC-Kanalregister `dfmt_enable` (bit 4) und
`dfmt_se` (bit 6) gesetzt sind, zusammen mit `enable` (bit 0) also Wert `0x51`
[CODE scripts/tetra_ctrl.sh:222–229]. Ohne `dfmt_se` wird nullerweitert: −512
(0xE00) wird zu +3584, das Signal ist gleichgerichtet, die Phaseninformation
zerstört, Sync unmöglich [CODE docs/HARDWARE.md:188–206 als Root-Cause-Dokumentation
des V1-Fehlers]. Der effektive Wertebereich ist damit −2048…+2047 in einem
16-bit-Container — relevant für die Skalierung in `02_PHY_DL_RX`.

**RX-Pfad:** kombinatorischer Durchgriff, 0 Takte. **TX-Pfad:** Sample-and-Hold,
ein Register je Kanal, Übernahme bei `tx_valid_lvds`, sonst Halten; 1 Takt Latenz
(V1-Muster: [CODE rtl/tetra_ad9361_axis_adapter.v:167–182]).

**Ressourcen:** ~10 LUT (Loopback-Mux, 3×16 bit), 32 FF [BUILD 2026-05-18
build/reports/impl_hier_util.rpt: `u_ad9361_adapter` 0 LUT / 24 FF ohne Mux].

### 3.7 RF-Konfiguration

**Frequenzplan (Testaufbau, konfigurierbar):**

| Parameter | Wert | Beleg |
|---|---|---|
| DL (BS-TX, `TX_FREQ_HZ`) | 438,250 MHz | [CODE board_autostart/tetra_cell.conf:7] |
| UL (BS-RX, `RX_FREQ_HZ`) | 428,250 MHz | [CODE board_autostart/tetra_cell.conf:6] |
| Duplex-Abstand im Testaufbau | 10,000 MHz (UL = DL − 10 MHz) | Differenz der beiden Werte |
| Sample-Rate | 4 608 000 Sa/s | [CODE board_autostart/tetra_cell.conf:8] |
| RF-Bandbreite RX und TX | 200 kHz (AD9361-Minimum; TETRA-Kanal 25 kHz) | [CODE scripts/ad9361_init.sh:164], [CODE board_autostart/tetra_cell.conf:9] |
| RX-Gain-Modus | `fast_attack` | [CODE board_autostart/tetra_cell.conf:10] |
| `xo_correction` | 40 000 000 Hz | [CODE board_autostart/tetra_cell.conf:18] |
| VCXO-DAC-Wert | 153 | [CODE board_autostart/tetra_cell.conf:17] |

Referenznetz zum Vergleich: kommerzielle TETRA-BS auf DL 392,9875 MHz /
UL 382,9875 MHz, also ebenfalls 10 MHz Abstand, Carrier 3719, CC 1
[GOLD docs/reference_decode/README.md:12, Zeile „Cell-Lock (TMO)"].

**Kanalzuordnung am AD9361 — in V1 eine Fehlerquelle, hier normativ:**

| Zweck | sysfs-Attribut (unter `/sys/bus/iio/devices/iio:deviceN/`) | Kanal/Port | Wirksam? |
|---|---|---|---|
| RX-LO | `out_altvoltage0_RX_LO_frequency` | — | ja |
| TX-LO | `out_altvoltage1_TX_LO_frequency` | — | ja |
| Sample-Rate (setzt BBPLL + Dezimation) | `in_voltage_sampling_frequency` | — | ja |
| RX-Gain-Modus | `in_voltage0_gain_control_mode` | RX1 | ja |
| RX-Gain (nur bei `manual`) | `in_voltage0_hardwaregain` | RX1 | ja |
| RX-AGC-Istwert (Diagnose) | `in_voltage0_hardwaregain` (lesend) | RX1 | ja |
| RX-Bandbreite | `in_voltage_rf_bandwidth` | — | ja |
| TX-Bandbreite | `out_voltage_rf_bandwidth` | — | ja |
| **TX-Dämpfung** | **`out_voltage0_hardwaregain`** | **TX1 = HF-Ausgang** | **ja** |
| TX-Dämpfung TX2 | `out_voltage1_hardwaregain` | TX2, nicht verbunden | **nein** |
| RX-Port | `in_voltage0_rf_port_select` (`A_BALANCED`) | RX1 | ja |
| Duplex-Betriebsart | `ensm_mode` = `fdd` | — | ja |
| Kalibrierung | `calib_mode` = `auto` bzw. `tx_quad` | — | ja |

Belege: TX1 = `out_voltage0` → AD9361-SPI 0x073/0x074, TX2 = `out_voltage1` →
0x075/0x076, TX2 auf dem LibreSDR nicht angeschlossen
[CODE scripts/ad9361_init.sh:186–195], [MESS 2026-04-13 docs/HARDWARE.md:159–171].
Format ist direkt dB (nicht millidB), Bereich 0…−89
[CODE scripts/tetra_ctrl.sh:295]. `rf_port_select` steht per Default auf
`A_BALANCED`; ein Schreiben kann mit EINVAL fehlschlagen, obwohl der Wert korrekt
ist — deshalb immer per Rücklesen verifizieren, nie per Exit-Code
[CODE scripts/tetra_ctrl.sh:311–320].

**Duplex-Spacing-Tabelle — harte Anforderung (R-01-14).**

ETSI kodiert im SYSINFO-PDU ein 3-bit-Feld „Duplex spacing" [ETSI §21.4.4.1,
Tabelle 21.65]. Die Berechnung ist normiert:
`f_UL = f_DL − duplex_spacing` bei „normal operation", `f_UL = f_DL + duplex_spacing`
bei „reverse operation" [ETSI §21.4.4.1]. Die **Abbildung** Feldwert → MHz ist
in EN 300 392-2 bewusst nicht enthalten: „The duplex spacing shall be dependent on
the frequency band element… defined in ETSI TS 100 392-15" [ETSI §21.4.4.1],
und Annex F verweist vollständig auf TS 100 392-15 [ETSI Annex F].

Praktische Konsequenz: **verschiedene MS-Codeplugs interpretieren dieselbe ID
unterschiedlich.** Eine feste Tabelle im Code ist deshalb funktional falsch. In V1
existieren zwei Implementierungen — eine mit konfigurierbarer Tabelle
[CODE sw/web/apply.cgi:64–103] und eine mit fest verdrahteten ETSI-Werten
[CODE sw/www/cgi-bin/apply.cgi:61–72]. Letztere ist Altlast und entfällt (R-01-15).

V2-Vorgabe:

- 8 Einträge `duplex_offset_hz[0..7]`, **signed Hz**, persistiert in der
  Konfigurationsdatei als `DUPLEX_OFFSET_HZ_0` … `DUPLEX_OFFSET_HZ_7`.
- Das gesendete SYSINFO-Feld ist `duplex_spacing` (0…7) und wird unabhängig von
  der Tabelle konfiguriert. Die Tabelle bestimmt ausschließlich, auf welche
  Frequenz die **eigene RX-LO** gesetzt wird.
- Berechnung: `f_UL = f_DL + duplex_offset_hz[duplex_spacing]`. Der Offset ist bei
  Normalbetrieb negativ. Ein explizit gesetzter `ul_freq` überschreibt die
  Tabellenrechnung [CODE sw/web/apply.cgi:87–103].
- Alle 8 Werte sind über die Bedienoberfläche editierbar und werden beim
  Seitenaufbau aus der Konfigurationsdatei vorbelegt
  [CODE sw/web/cgi-bin/config.cgi:35–42,65–74].

Aktuell hinterlegte Werte (MS-Codeplug des Testgeräts, **nicht** ETSI-Default):

| ID | Offset | Bemerkung |
|---:|---:|---|
| 0 | −10 000 000 Hz | Default |
| 1 | −45 000 000 Hz | Band 380 MHz |
| 2 | 0 Hz | DMO |
| 3 | −10 000 000 Hz | |
| 4 | −10 000 000 Hz | |
| 5 | −10 000 000 Hz | |
| 6 | −10 000 000 Hz | |
| 7 | −7 600 000 Hz | |

[CODE sw/web/apply.cgi:64–71], [MESS 2026-05-19 — Mapping am Testgerät verifiziert].

> **Verbindliche Betriebsregel:** Vor Einsatz einer anderen MS-Hardware ist das
> Mapping empirisch zu bestimmen und in die Tabelle einzutragen. Ein
> Tabellen-Eintrag ist keine ETSI-Konstante.

**Bandabdeckung.** Der Transceiver begrenzt die nutzbaren Bänder, nicht das
Design. AD9363: 325 MHz…3,8 GHz [ANNAHME — Datenblattwert, im Repo nicht belegt].
Die betriebenen Punkte (428/438 MHz) und das Referenznetz (383/393 MHz) liegen
innerhalb. Kanalraster 25 kHz, Offsets 0/+6,25/−6,25/+12,5 kHz
[ETSI §21.4.4.1, Tabelle 21.65]. Frequenzgenauigkeit der BS: besser als
±0,2 ppm (±0,1 ppm über 520 MHz), eine gemeinsame Quelle für HF-Erzeugung **und**
Zeitbasis [ETSI §7.7]. Auf dieser Plattform ist das der 40-MHz-VCXO — dieselbe
Quelle speist AD9361-LO und, über `DATA_CLK`, den Symbol-Tick (§3.1). Die Forderung
ist damit strukturell erfüllt; die absolute Genauigkeit hängt am VCXO-Trimm
(§3.8 B9) und ist nicht vermessen [ANNAHME].

### 3.8 Board-Bring-up-Reihenfolge (normativ)

**Vorbedingungen:** Bitstream als `.bit.bin` im Firmware-Verzeichnis;
Konfigurationsdatei vorhanden und lesbar; alle Pflichtvariablen gesetzt, sonst
Abbruch mit Nennung der fehlenden Variable (R-01-20; V1-Muster
[CODE board_autostart/tetra_autostart.sh:36–44]).

| Schritt | Aktion | Verifikation | Begründung / Beleg |
|---|---|---|---|
| B1 | Bitstream-Load #1 über FPGA-Manager (`flags=0`, dann Firmware-Name) | `fpga0/state == operating`, sonst Abbruch | [CODE board_autostart/tetra_autostart.sh:73–78] |
| B2 | AD9361-Treibermodul laden, `driver_override` leeren, `spi0.0` an `ad9361` binden — idempotent, überspringen wenn IIO-Device existiert | IIO-Device vorhanden | [CODE board_autostart/tetra_autostart.sh:83–98] |
| B3 | **TX stummschalten** (`TX_ATT_INIT_DB`, z. B. −89 dB) | Rücklesen | R-01-18; [CODE board_autostart/tetra_autostart.sh:103–105] |
| B4 | AD9361-Konfig #1: Sample-Rate, RX-LO, TX-LO, Gain-Modus, RF-BW (RX+TX), `ensm_mode=fdd`, `calib_mode` | Rücklesen aller Werte | [CODE board_autostart/tetra_autostart.sh:115–122] |
| B5 | **Bitstream-Load #2** | `fpga0/state == operating`, sonst Abbruch | Reihenfolgeabhängigkeit, siehe unten |
| B6 | TX erneut stumm; AD9361-Konfig #2, identisch zu B4 | Rücklesen | Load #2 setzt **alle** PL- und IP-AXI-Register auf Reset-Werte zurück [CODE board_autostart/tetra_autostart.sh:134–151] |
| B7 | `axi_ad9361`-DAC-Core: Core-/MMCM-Reset lösen, `r1_mode` im Common-Block setzen, pro Kanal `dac_data_sel = 0x2` (Fabric-Daten) | Register rücklesen | Reset-Default 0 = DDS-Modus, DDS ist deaktiviert → TX liefert Null, HF zeigt nur LO-Leakage [CODE scripts/tetra_ctrl.sh:166–198] |
| B8 | `axi_ad9361`-ADC-Core: Reset lösen, `r1_mode = 0` (2R2T-DDR!), pro Kanal `0x51` | Register rücklesen | `r1_mode = 1` → Frame-Erkennung erwartet 1R1T → `adc_valid_i0` pulst nie [CODE scripts/tetra_ctrl.sh:203–229]; `0x51` siehe §3.6 |
| B9 | VCXO: GPIO 1011–1013 exportieren und auf Output, `xo_correction` setzen, DAC5311-Frame schieben (`frame = wert << 6`, MSB first, 16 Takte, CS low umschließend) | GPIO-Zustand lesbar | [CODE board_autostart/tetra_autostart.sh:169–189], [CODE scripts/vcxo_cal.sh:15–19] |
| B10 | PL-Konfigurationsregister schreiben (Zellparameter, Schwellwerte, Policy) | Rücklesen | Registernamen/-adressen: `07_PS_PL_CONTRACT` |
| B11 | **Health-Gate:** `lvds_in_range_sys` gesetzt (§3.4), ADC-Core-Status „locked", `SYNC_LOCKED` innerhalb 3 s | alle drei erfüllt, sonst Abbruch ohne TX | R-01-07; ersetzt das konstante Statusbit aus V1 |
| B12 | TX auf operativen Pegel (`TX_ATT_OP_DB`) über `out_voltage0` | Rücklesen | R-01-13/R-01-18 |
| B13 | Dienste starten (Protokoll-Daemons, Bedienoberfläche) | Prozesse laufen | Details: `13_SW_ARCHITECTURE` |

**Warum zweimal Bitstream laden.** Ein einzelner Load führt reproduzierbar dazu,
dass das Board nach der AD9361-Konfiguration nicht mehr ansprechbar ist und
manuell neu gestartet werden muss [MESS 2026-05-17, manueller Reboot-Test]. Mit
der Sequenz B1–B6 tritt der Zustand nicht auf. Die in V1 dokumentierte Erklärung
(„MMCM kann nicht auf DATA_CLK locken") ist **nicht** haltbar: im `DATA_CLK`-Pfad
liegt kein MMCM und kein PLL, sondern `IBUFGDS` + `BUFG`
[CODE .../ad_data_clk.v:66,73]; und der AXI-Slave der ADI-IP kann den Bus nicht
blockieren, weil er nach 16 Takten ohne Ack selbst quittiert und `0xDEADDEAD`
liefert [CODE .../up_axi.v:204–205]. Die Ursache ist damit **offen** (§6, O-01-1).
Für V2 gilt: Sequenz normativ übernehmen, Begründung als „empirisch, Ursache nicht
geklärt" kennzeichnen, nicht wegoptimieren.

**Weitere Bring-up-Regeln:**

- Kein `devmem`/AXI-Zugriff auf die PL-Apertur, solange `fpga0/state` nicht
  `operating` ist (R-01-17). V1 führt das als Betriebsregel und prüft den State
  an beiden Loads [CODE board_autostart/tetra_autostart.sh:77,130]. Der als
  Begründung genannte Board-Absturz bei Verletzung ist im Repo **nicht** durch
  Log oder Messgröße belegt [ANNAHME — Regel unverändert übernommen, weil sie
  nichts kostet; der Nachweis (Zugriff vor `operating` → Verhalten) ist als
  Negativtest Teil von V-01-7].
- Im systemd-Kontext ausschließlich direkte sysfs-Writes, nie `iio_attr`: `iio_attr`
  hängt beim Schreiben der TX-LO-Frequenz in einem nicht unterbrechbaren
  Kernel-Zustand, auch SIGKILL greift nicht; direkte Writes brauchen 0,1–1,5 s pro
  Operation und funktionieren zuverlässig [MESS 2026-05-17],
  [CODE board_autostart/tetra_autostart.sh:111–114].
- Der Boot-Dienst ist ein `oneshot` mit `RemainAfterExit=yes`, `After=local-fs.target
  network.target`, und beendet im `ExecStop` alle gestarteten Daemons
  [CODE board_autostart/tetra-autostart.service:3–10].

### 3.9 Ressourcen-Budget

**Vorbemerkung, verbindlich:** Die Slice-Auslastung ist **kein** Kapazitätsmaß.
Ein 7-Series-Slice enthält 4 LUT6 und 8 FF und gilt als „used", sobald ein
Element belegt ist; der Placer verteilt Logik absichtlich über die Fläche, deshalb
sättigt der Slice-Prozentsatz früh und bleibt dort, unabhängig davon, ob Logik
hinzukommt oder wegfällt. Im letzten V1-Build stehen **98,66 % Slice** neben
**70,61 % LUT** und **47,69 % FF** — es sind real über 15 000 LUT und mehr als
55 000 FF frei [BUILD 2026-07-12 build/reports/impl_utilization.rpt §1, §2].
Slice-% darf in keiner Entscheidung, keinem Review und keinem Kapitel als Grenze
auftreten (R-01-19).

**Build-Referenzpunkt V1 (`xc7z020clg400-1`, Vivado 2022.2, Physopt postRoute)**
[BUILD 2026-07-12 build/reports/impl_utilization.rpt, build/reports/impl_timing.rpt]:

| Metrik | V1 (Tool-Ausgabe) | Kapazität | Anteil |
|---|---:|---:|---:|
| Slice LUTs | 37 567 | 53 200 | 70,61 % |
| — davon Logic | 37 259 | | |
| — davon LUTRAM | 62 | | |
| — davon SRL | 246 | | |
| Slice Registers (FF) | 50 744 | 106 400 | 47,69 % |
| BRAM-Tiles | 15,5 (10× RAMB36 + 11× RAMB18) | 140 | 11,07 % |
| DSP48E1 | 38 | 220 | 17,27 % |
| Bonded IOB | 60 | 125 | 48,00 % |
| WNS `clk_fpga_0` (10 ns) | **+0,006 ns** | > 0 | — |
| WHS | +0,049 ns | > 0 | — |
| WNS `rx_clk` (4 ns) | +0,278 ns | > 0 | — |
| WNS `clk_fpga_1` (5 ns) | +3,608 ns | > 0 | — |
| Slice (Information, **kein** Budget) | 13 122 | 13 300 | 98,66 % |

**Aufteilung V1 auf Block-Design-Ebene**
[BUILD 2026-06-20 build/reports/cur_hier_util.rpt]:

| Instanz | LUT | FF | RAMB36 | RAMB18 | DSP |
|---|---:|---:|---:|---:|---:|
| `tetra_zynq_top_0` (unser PL) | 33 178 | 42 716 | 8 | 10 | 24 |
| `axi_ad9361_0` (ADI-IP) | 2 571 | 5 173 | 0 | 0 | 14 |
| `axi_dma_0` (**entfällt in V2**) | 1 271 | 2 507 | 2 | 1 | 0 |
| `axi_ic_hp0` (**entfällt in V2**) | 996 | 1 151 | 0 | 0 | 0 |
| `axi_ic_ctrl` | 540 | 678 | 0 | 0 | 0 |
| `sys_rstgen` + `sys_ps7` | 27 | 26 | 0 | 0 | 0 |
| Summe | 38 578 | 52 251 | 10 | 11 | 38 |

**Struktureller Gewinn in V2 ohne jede Funktionsänderung** (Summe aus §2.2 und §3.1):

| Maßnahme | ΔLUT | ΔFF | ΔBRAM |
|---|---:|---:|---:|
| AXI-DMA + HP0-Interconnect entfernen | −2 267 | −3 658 | −2 RAMB36, −1 RAMB18 |
| sys↔axi-Synchronisierer entfernen | ~0 | −3 790 | 0 |
| Tote IP-Fabric-Ports und Lint-Sinks entfernen | ~−10 | 0 | 0 |
| **Summe** | **≈ −2 280** | **≈ −7 450** | **−2 RAMB36, −1 RAMB18** |

**V2-Budget (verbindlich):**

| Metrik | Budget | Hard limit (Device) | Prüfung |
|---|---:|---:|---|
| Slice LUTs | ≤ 42 000 (79 %) | 53 200 | `report_utilization` §1 |
| Slice Registers | ≤ 60 000 (56 %) | 106 400 | `report_utilization` §1 |
| BRAM-Tiles | ≤ 40 (29 %) | 140 | `report_utilization` §3 |
| DSP48E1 | ≤ 60 (27 %) | 220 | `report_utilization` §4 |
| WNS 100-MHz-Domäne | **≥ +0,250 ns** | > 0 | `report_timing_summary` |
| WHS | ≥ +0,030 ns | > 0 | `report_timing_summary` |
| `report_cdc` Unsafe (`tetra_*`) | 0 | 0 | `report_cdc` + Waiver-Datei |
| Slice-% | **kein Kriterium** | — | — |

Begründung der WNS-Schwelle: V1 schließt mit +0,006 ns, also praktisch ohne
Reserve. Jede Änderung kippt in dieser Lage das Timing über Placement- und
Routing-Kongestion, nicht über Kapazität — das erklärt paradoxe A/B-Builds, in
denen weniger LUT zu schlechterem Timing führen. Eine Mindestreserve von 0,25 ns
(2,5 % der Periode) macht inkrementelle Arbeit erst planbar. [ANNAHME — Schwellwert
gesetzt, nicht gemessen; der V1-Wert +0,006 ns ist [BUILD 2026-07-12 build/reports/impl_timing.rpt].]

**Ressourcen-Erwartung der in diesem Kapitel spezifizierten Module:**

| Modul | LUT | FF | BRAM | DSP |
|---|---:|---:|---:|---:|
| `tetra_clk_reset` | 0 | 4 | 0 | 0 |
| `tetra_sym_tick` | ~12 | ~14 | 0 | 0 |
| `tetra_clk_monitor` | ~50 | ~40 | 0 | 0 |
| `tetra_ad9361_if` | ~10 | 32 | 0 | 0 |
| `tetra_cdc_*` (je Instanz) | 0 | 2 × WIDTH | 0 | 0 |

Alle Werte [ANNAHME], aus der Struktur abgeleitet; die V1-Messwerte für
`u_clk_reset` (3 LUT / 6 FF, vier Domänen) und `u_ad9361_adapter` (0 LUT / 24 FF,
ohne Mux) stützen die Größenordnung [BUILD 2026-05-18 build/reports/impl_hier_util.rpt].

### 3.10 Bewusst ausgeschlossene Optionen

| Option | Entscheidung | Begründung |
|---|---|---|
| Programmierbarer 128-Tap-RX-FIR im AD9361 | **ausgeschlossen** | Mehrfach implementiert, mehrfach fehlgeschlagen. Beobachtete Symptome: Treiberfehler „decimation 0 in filter config" beim sysfs-Write; TETRA-RRC (α = 0,35, 25 kHz) lässt sich nicht sauber in das FIR-Frame-Format abbilden. Bandbegrenzung erfolgt in der PL-Dezimationskette (`02_PHY_DL_RX`). [ANNAHME — mehrfacher Fehlschlag in V1; beobachtete Treibermeldung wörtlich „decimation 0 in filter config" beim sysfs-Write, kein Log und kein Codepfad im Repo archiviert (`grep` nach `filter_fir`/`fir_en` über `scripts/`, `sw/`, `board_autostart/` ohne Treffer)] |
| MMCM/PLL im `DATA_CLK`-Pfad | **nicht vorhanden, nicht einführen** | `USE_SSI_CLK = 1` nutzt `IBUFGDS`+`BUFG`. Ein MMCM würde einen Lock-Zustand einführen, den es heute nicht gibt, und die Bring-up-Sequenz verkomplizieren, ohne dass der Nutzen benannt wäre. |
| Zweiter RX-Kanal (2R2T-Diversity im PL) | **nicht in Stufe 1** | Die IP läuft aus Frame-Timing-Gründen in 2R2T (§3.1), der zweite Kanal wird im PL nicht ausgewertet. MRC/Diversity braucht eine andere Plattform-Klasse. Siehe `18_ROADMAP`. |
| AXI-DMA für RX-Blöcke | **entfällt** | Kein SW-Konsument, `m_axis` konstant idle (§2.2). Falls später ein Massendatenpfad gebraucht wird, wird er in `18_ROADMAP` neu spezifiziert. |
| ENABLE/TXNRX-Pin-Control des AD9361 | **nicht benutzt** | ENSM läuft über SPI (`ensm_mode = fdd`). Die EMIO-Bits bleiben verdrahtet, aber unbeschrieben (§2.3). |

---

## 4. Empirische Werte

| Parameter | Wert | Herkunft | Was bei Abweichung passiert |
|---|---:|---|---|
| Sample-Rate AD9361 | 4 608 000 Sa/s | [CODE board_autostart/tetra_cell.conf:8] | `DATA_CLK ≠ 18,432 MHz` → Symbol-Tick-Teiler 1024 falsch → gesamte TDMA-Zeitbasis driftet gegen die Luft; MS bucht nicht ein |
| `DATA_CLK` | 18,432 MHz | [CODE rtl/tx/tetra_tx_frontend.v:13–14] | s. o. |
| ADC-Core `r1_mode` | 0 | [CODE scripts/tetra_ctrl.sh:215–220] | Bei 1: Frame-Muster passt nie, `adc_valid_i0` pulst nicht, `SYNC_LOCKED` bleibt 0 |
| ADC-Kanalregister | `0x51` | [CODE scripts/tetra_ctrl.sh:222–229] | Bei `0x01`: 12-bit-Daten nullerweitert → Signal gleichgerichtet → Sync unmöglich (Digital-Loopback bleibt unauffällig, weil er den ADC umgeht) |
| DAC `dac_data_sel` pro Kanal | `0x2` | [CODE scripts/tetra_ctrl.sh:170–188] | Bei 0 (Reset-Default): DDS-Modus, DDS ist deaktiviert → TX-Ausgang Null, HF zeigt nur LO-Leakage |
| `CIC_GAIN_SHF` (RX-Frontend) | 4 (×16) | [CODE rtl/rx/tetra_rx_frontend.v:135], [MESS 2026-05-22] | Bei 6 (×64): UL-Bursts sättigen bei AGC-Transienten, UL-CRC-Rate fällt von ~93 % auf ~27 %. Bei zu klein: Gardner-TED-Verstärkung ∝ Amplitude² → Regelkreis tot |
| Sync-Korrelator-Schwelle (`REG_SYNC_THRESH`, **gemeinsam DL+UL**) | 13 (`0x0D`) | [CODE rtl/infra/tetra_axi_lite_regs.v:1418] | Ein einziges Register speist beide Detektoren: DL-`tetra_sync_detect` [CODE rtl/rx/tetra_rx_chain.v:350] und UL-`tetra_ul_sync_detect_os4` [CODE rtl/rx/tetra_rx_chain.v:375]. Obergrenzen aus der Sequenzlänge: ≤ 19 (STS), ≤ 11 (NTS, 11 Symbole [CODE rtl/rx/tetra_sync_detect.v:76,114–117]), ≤ 15 (UL-ETS-x-Sequenz, `SYNC_LEN_SYM = 15` [CODE rtl/rx/tetra_ul_sync_detect_os4.v:54]). Zu hoch: `corr_max` erreicht die Schwelle nie [CODE rtl/rx/tetra_ul_sync_detect_os4.v:211] → `SYNC_LOCKED` bleibt 0 → Health-Gate B11 sperrt TX. Zu niedrig: Fehl-Detects. SW schreibt das Register nur bei explizitem CLI-Flag `-t` [CODE sw/tetra_hal.c:1179–1182,1683]; operativ gilt der RTL-Default 13 |
| NUB-Sync-Schwelle | 11 | [MESS 2026-05-17], [CODE board_autostart/tetra_cell.conf:21] | 10: mehr Sync-Detects (28/s) als echte Bursts (16–18/s) → BFI 6,1 % statt 4,7 %. **12: NUB-Detektor lockt nicht mehr**, PTT wird abgewiesen. 8 (RTL-Default): ~48 Fehl-Bursts/s im Idle |
| RX-Gain-Modus | `fast_attack` | [CODE scripts/ad9361_init.sh:43] | `slow_attack` reagiert in ms statt µs → Burst-Onsets werden verpasst |
| RF-Bandbreite | 200 kHz | [CODE scripts/ad9361_init.sh:164] | AD9361-Minimum; kleinere Werte werden abgelehnt |
| TX-Dämpfung Init / Betrieb | −89 dB / −10 dB | [CODE board_autostart/tetra_cell.conf:13–14] | Ohne Init-Stummschaltung sendet das Board mit undefiniertem Inhalt während der Konfiguration |
| TX-Dämpfung im HF-Loopback | −50 dB → RX-AGC ≈ 47 dB | [MESS 2026-04-13, 10 cm Luftstrecke] | −30 dB → AGC 28 dB, zu stark für stabilen Lock; −60 dB → AGC 58 dB, nahe Obergrenze |
| VCXO-DAC-Wert | 153 | [CODE board_autostart/tetra_cell.conf:17] | Verstimmt die Referenz; ETSI fordert ±0,2 ppm [ETSI §7.7] |
| `xo_correction` | 40 000 000 Hz | [CODE board_autostart/tetra_cell.conf:18] | Frequenzoffset auf allen LOs |
| Wartezeit nach Bitstream-Load | 2 s | [CODE board_autostart/tetra_autostart.sh:76,129] | Kürzer: `fpga0/state` noch nicht `operating`, Folgeschritte scheitern |
| Wartezeit nach SPI-Bind | 3 s | [CODE board_autostart/tetra_autostart.sh:95] | Kürzer: IIO-Device noch nicht angelegt |

> **Zur Zahl 15 für die UL-Korrelator-Schwelle.** Der zusammen mit
> `CIC_GAIN_SHF = 4` gemessene Sprung der UL-CRC-Rate von ~27 % auf ~93 %
> [MESS 2026-05-22] wurde mit einem **getrennten** UL-Schwellwertregister
> erreicht. Dieses Register existiert im aktuellen V1-Stand nicht (`grep` nach
> `UL_RA_SYNC_THRESH`/`ul_ra_thresh` über `rtl/` und `sw/` ohne Treffer); übrig
> ist nur die gemeinsame Schwelle 13. Auf dem **gemeinsamen** Register ist 15
> verboten: der DL-Detektor läuft mit NTS (11 Symbole) und erreicht 15 nie.
> V2 löst das über zwei getrennte Register (R-01-23), nicht über einen anderen
> Wert im gemeinsamen Register.

---

## 5. Verifikation

**V-01-1 Clock- und Reset-Struktur (Simulation).** Testbench mit
`clk_sys = 100 MHz`, `clk_lvds = 18,432 MHz`, `arst_n`-Puls. Prüft:
`rst_n_sys` deasserted nach genau 2 `clk_sys`-Flanken, `rst_n_lvds` nach genau
2 `clk_lvds`-Flanken; beide asserten innerhalb einer Delta-Zeit nach
`arst_n`-Abfall.

**V-01-2 Symbol-Tick (Simulation).** Über 10 000 Perioden: Abstand zwischen zwei
`sym_en_sys`-Pulsen ist konstant 1024 `clk_lvds`-Takte; kein Puls ausgelassen;
kein Doppelpuls. Zusatzfall: `clk_lvds` steht → kein Puls, `clk_sys`-Logik läuft
weiter, kein Deadlock.

**V-01-3 Frequenzüberwachung (Simulation + Board).** Simulation mit
`clk_lvds = 18,432 MHz` → `lvds_freq_meas = 1 843 200 ±1`; mit 16 MHz →
`lvds_in_range = 0`; mit stehendem Takt → `lvds_alive = 0`. Auf dem Board: Wert
im Statusregister nach Bring-up im Fenster.

**V-01-4 CDC-Gate (Build).** `report_cdc` nach Implementation: 0 `Unsafe` und
0 `No ASYNC_REG` für alle `tetra_*`-Instanzen. Grep-Gate: `ASYNC_REG` nur in den
fünf zugelassenen Dateien. IP-interne Restbefunde stehen namentlich in
`constraints/cdc_waivers.xdc`. Referenzwert, gegen den verbessert wird: 79 Unsafe
[BUILD 2026-07-12 build/reports/cdc_report.rpt].

**V-01-5 Timing- und Ressourcen-Gate (Build).** `report_utilization` und
`report_timing_summary` gegen die Budget-Tabelle §3.9. Der Build schlägt fehl,
wenn eine Budgetzeile überschritten oder WNS < +0,250 ns ist. Slice-% wird nicht
geprüft. Zusätzlich zu messen: Wirkung der `rx_clk`-Periode 20 ns statt 4 ns auf
`clk_fpga_0`-WNS (§3.1) — ein A/B-Build, beide Reports archiviert.

**V-01-6 AD9361-Datenformat (Board).** RX-IQ-Capture im Leerlauf und mit Signal;
das Histogramm muss negative Werte enthalten und um 0 zentriert sein. Ein
einseitiges Histogramm bedeutet fehlendes `dfmt_se` (§3.6).

**V-01-7 Bring-up-Sequenz (Board, ≥ 3 Durchläufe).** Kaltstart mit
Netztrennung. Für jeden Durchlauf gilt: beide Bitstream-Loads melden `operating`;
das Health-Gate B11 wird innerhalb 5 s erfüllt; TX geht erst danach auf den
operativen Pegel; die MS bucht ein. Negativtest 1: eine PL-Registerlesung vor
`fpga0/state == operating` (R-01-17) — protokolliert wird, ob der Zugriff
fehlschlägt, hängt oder das Board unbrauchbar macht; Ergebnis mit Datum als
`[MESS]` nachtragen, damit die Regel in §3.8 einen Beleg bekommt. Negativtest 2:
B5 auslassen → das Board darf
den TX **nicht** einschalten und muss mit klarer Fehlermeldung abbrechen (in V1
führte dieser Fall zum Hänger, der nur per Power-Cycle behebbar war
[MESS 2026-05-17]).

**V-01-8 Duplex-Tabelle (Board).** Eintrag 7 von −7,6 MHz auf −8,0 MHz ändern,
`duplex_spacing = 7` setzen, übernehmen. RX-LO muss anschließend
`f_DL − 8,0 MHz` sein (Rücklesen aus sysfs), und der Wert muss nach Reboot
erhalten sein. Zweiter Test: Es existiert kein zweiter Codepfad, der die
UL-Frequenz berechnet (Grep über das Repo).

**V-01-9 TX-Kanalzuordnung (Board).** `out_voltage0_hardwaregain` von −10 auf
−40 dB → Pegeländerung am Empfänger messbar. `out_voltage1_hardwaregain`
identisch ändern → **keine** Pegeländerung. Beide Ergebnisse sind Bestandteil der
Abnahme, weil die falsche Zuordnung in V1 wiederholt Zeit gekostet hat.

---

## 6. Offene Punkte

**O-01-1 Ursache der Zwei-Load-Abhängigkeit.** Dass ein einzelner Bitstream-Load
das Board unbrauchbar macht, ist gemessen [MESS 2026-05-17]. Die in V1 verbreitete
Erklärung („MMCM lockt nicht") ist falsifiziert: es gibt keinen MMCM im
`DATA_CLK`-Pfad [CODE .../ad_data_clk.v:66,73], und der AXI-Slave der ADI-IP
quittiert nach 16 Takten selbst [CODE .../up_axi.v:204–205]. *Empfehlung:* Sequenz
unverändert normativ übernehmen; die Ursache separat eingrenzen, indem beim
Einzel-Load nach jeder AD9361-Konfigurationsoperation genau eine PL-Registerlesung
über die serielle Konsole (nicht SSH) protokolliert wird — damit lässt sich
feststellen, ob der Hänger am AXI, am Kernel-IIO-Pfad oder am Netzwerkstack
entsteht. Bis dahin ist jede Optimierung der Sequenz verboten.

**O-01-2 `rx_clk`-Constraint-Periode.** 4 ns überconstraint die 18,432-MHz-Domäne
um Faktor 13,6 und konkurriert mit der 100-MHz-Domäne, die mit +0,006 ns am Limit
liegt. *Empfehlung:* 20 ns, per A/B-Build gegen `clk_fpga_0`-WNS belegen
(V-01-5). Wird kein Gewinn gemessen, bleibt 4 ns — dann aber mit dieser Messung
als Kommentar im XDC.

**O-01-3 DAC-Strobe-Quelle.** Das TX-Sample-and-Hold in V1 übernimmt bei einem
selbst erzeugten `tx_valid_lvds` (aus einem `/4`-Zähler im TX-Frontend), nicht
beim `dac_valid_i0` der IP. Beide laufen auf `clk_lvds`, die Phase ist aber nicht
gekoppelt; ein Sample-Slip um einen `clk_lvds`-Takt ist möglich. Der Pfad ist
air-verifiziert, und in V1 gilt die Regel, den TX-Pfad bei RX-Fehlersuche nicht
anzufassen. *Empfehlung für V2:* `dac_valid_i0` als Übernahme-Enable verwenden und
den Wechsel isoliert gegen den bestehenden Aufbau vergleichen (gleicher MER, gleiche
Nachbarkanalunterdrückung), bevor er übernommen wird.

**O-01-4 Frequenzgenauigkeit nicht vermessen.** ETSI fordert ±0,2 ppm für HF und
Zeitbasis aus einer Quelle [ETSI §7.7]. Struktur passt (§3.7), der absolute
VCXO-Trimm (DAC-Wert 153, `xo_correction` 40 000 000 Hz) ist aber nie gegen eine
Referenz gemessen worden. *Empfehlung:* einmalige Messung gegen GPSDO oder
Frequenzzähler, Ergebnis als `[MESS]` in die Konfigurationsdatei-Dokumentation;
ohne Messung bleibt die ETSI-Konformität dieses Punktes unbelegt.

**O-01-5 Doppelte Konfigurations-Implementierung.** V1 hat zwei
Web-Konfigurationsbäume (`sw/web/` mit konfigurierbarer Duplex-Tabelle,
`sw/www/cgi-bin/` mit fest verdrahteter Tabelle). *Empfehlung:* Nur `sw/web/`
übernehmen; die alte Variante existiert in V2 nicht. Vor Abschluss ist zu prüfen,
ob auf dem Board noch Reste des alten Baums installiert sind — ein überlebendes
altes `apply` würde die Tabelle stillschweigend überschreiben.

**O-01-6 DDR-Adressfenster widersprüchlich.** Der PS7 ist im Block Design auf
**512 MiB** DDR konfiguriert (`PCW_DDR_RAM_HIGHADDR = 0x1FFFFFFF`, also
0x0…0x1FFFFFFF)
[CODE build/vivado/tetra_zynq_phy.srcs/sources_1/bd/tetra_system/tetra_system.bd:472–473],
während die V1-DMA-Adressfenster für `Data_S2MM` und `Data_SG` je **1 GB** ab
0x00000000 zuweisen [CODE scripts/create_bd.tcl:587–598]. Das ist ein konkreter
V1-Widerspruch, keine offene Frage — er gehört als Zeile nach
`17_LESSONS_LEARNED`. Mit dem Entfall des DMA-Pfads (§2.2) ist er für V2
wirkungslos. *Offen bleibt nur:* ob die physische Bestückung der PS7-Konfiguration
entspricht; das ist vor jeder künftigen DDR-Nutzung durch das PL zu klären, weil
ein Zugriff jenseits des bestückten Speichers voraussichtlich keinen Fehler
liefert, den das PL auswerten könnte [ANNAHME — nicht getestet, PS7-Verhalten
außerhalb des DDR-Ausbaus nicht vermessen].

**O-01-7 Grenze der 100-MHz-Domäne.** Mit einer einzigen 100-MHz-Domäne fällt die
Möglichkeit weg, den AXI-Takt später unabhängig zu wählen. *Empfehlung:* Bewusst
akzeptieren — die Ersparnis ist mit 3 790 FF belegt, der Bedarf für getrennte
Takte war in V1 nie gegeben. Sollte ein zukünftiges Board `s_axi_aclk` aus einer
anderen Quelle treiben, ist die CDC-Schicht über `tetra_cdc_bus`/`tetra_cdc_level`
wieder einzuziehen; die Muster stehen in §3.5 bereit.
