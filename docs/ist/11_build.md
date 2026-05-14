# IST — Kapitel 11: Build-System
Stand: 2026-05-14

Beschreibt den Vivado-TCL-Flow, die XDC-Constraints, die Run-Wrapper, die Deploy-Pipeline, die ILA-Debug-Tools und die CDC-Reports. Reine Bestandsaufnahme.

## Top-Level Übersicht

- **Kein top-level Makefile** im Projekt-Root. Build wird ausschließlich über Bash- + TCL-Skripte getrieben.
- **Tool:** Vivado 2022.2 (auto-detect: `vivado` in PATH oder `/opt/Xilinx/Vivado/2022.2/bin/vivado`).
- **Target:** XC7Z020-CLG400-1 (LibreSDR). **Achtung:** `scripts/vivado_sim.tcl` verwendet stattdessen `xc7z020clg484-1` (anderes Package).
- **Build-Output:** Alles unter `build/`.
- **Reports:** Unter `build/reports/`.
- **SW-Build:** Separat über `sw/Makefile` (Cross-Compile mit `arm-linux-gnueabihf-gcc`).

## Vivado Project Setup

### scripts/vivado_build.tcl (377 Zeilen)

Vollständiger Build-Flow, Aufruf:
```
vivado -mode batch -source scripts/vivado_build.tcl
```

**Env-Variablen:**
- `ENABLE_ILA_DEBUG` — default 0 (Production). Setzt ILA-Insertion in Impl-Phase.
- `ADI_HDL_DIR` — Pfad zur ADI HDL Library. Wenn leer: auto-detect aus `~/openwifi/openwifi-hw/adi-hdl/library`, `/opt/adi/hdl/library`, `~/hdl/library`, `/tools/adi/hdl/library`; Fallback `libresdr/ip/`.

**Konstanten:**
- `PROJ_NAME = tetra_zynq_phy`
- `PART = xc7z020clg400-1`
- `XPM_LIBRARIES = {XPM_FIFO XPM_MEMORY}` (für `xpm_fifo_async` in `tetra_zynq_top`)

**6-Stage-Flow:**

1. **Create Project** — `create_project tetra_zynq_phy build/vivado -part $PART -force`. Verilog default, `default_lib=work`, `simulator_language=Mixed`.

2. **Add RTL Sources** — siehe Detail in `docs/ist/10_scripts.md` (vivado_build.tcl-Abschnitt). Categories:
 - Infra (3 Files), AD9361-Adapter (1), RX-Chain (14), TX-Chain (12 + 1 zusätzliches `tetra_aach_rm_encoder.v`), LMAC (29), Top-Level (2).
 - **Header:** `rtl/include/tetra_pdu_class.vh` mit `is_global_include=true` + Include-Path `rtl/include` (Phase Z.3).
 - **Constraints:** `constraints/libresdr_tetra.xdc`, `constraints/adi_cdc_async_reg.xdc` (per `add_files -fileset constrs_1`).

3. **Block Design** — `source scripts/create_bd.tcl`. Erzeugt `tetra_system.bd` + Wrapper. Top wird auf `tetra_system_top` gesetzt.

4. **Synthesis:**
 ```
 synth_design -top tetra_system_top -part xc7z020clg400-1 \
 -flatten_hierarchy rebuilt \
 -directive PerformanceOptimized \
 -retiming
 ```
 BD-Synth-Mode `SYNTH_CHECKPOINT_MODE=None` (Global statt OOC). Reports: `synth_utilization.rpt`, `synth_timing.rpt`. Checkpoint: `post_synth.dcp`.

5. **Implementation:**
 - `opt_design` → `post_opt.dcp`.
 - **ILA-Logik:**
 - `get_nets -hierarchical -filter {MARK_DEBUG == "TRUE"}` Liste lesen.
 - Wenn `ENABLE_ILA_DEBUG=1` UND Nets gefunden:
 - Re-open `post_opt.dcp`.
 - Klassifikation `*_lvds` → l_clk-Domain, sonst → clk_sys-Domain.
 - Clock-Net aus bekannter Registered-Probe-Zelle (`dbg_sync_locked_sys_reg`).
 - `create_ila u_ila_sys` mit Tiefe 4096, alle clk_sys-Probes.
 - `u_ila_lvds` ist explizit DISABLED (l_clk nur aktiv nach AD9361-Init).
 - `implement_debug_core` → ILA + dbg_hub + BSCAN.
 - `place_design -directive Auto_1`.
 - `phys_opt_design -directive AggressiveExplore`.
 - `route_design -directive AggressiveExplore`.
 - `phys_opt_design -directive AggressiveExplore`.
 - Reports: `impl_utilization.rpt`, `impl_timing.rpt`, `clock_interaction.rpt`, `cdc_report.rpt`.
 - WNS-Check (warn bei negativem Slack).
 - Checkpoint: `post_route.dcp`.

6. **Bitstream:** `write_bitstream -force build/tetra_zynq_phy.bit`, `write_debug_probes -force build/tetra_zynq_phy.ltx`.

### scripts/create_bd.tcl (628 Zeilen)

Erzeugt das Block-Design `tetra_system`. Aufruf aus `vivado_build.tcl`.

**IP-Komponenten:**
| Cell | VLNV | Konfiguration |
|---------------------|-------------------------------------------------|----------------------------------------------------------------------------------------------|
| `sys_ps7` | `xilinx.com:ip:processing_system7:5.5` | FCLK0=100 MHz, FCLK1=200 MHz, GP0+HP0(64b), SPI0/I2C0/UART0/ENET0/SD0 EMIO, GPIO 64b EMIO, DDR 534 MHz |
| `sys_rstgen` | `xilinx.com:ip:proc_sys_reset:5.0` | 100 MHz, 1 Bus-Rst, 1 Perp-Rst |
| `axi_ad9361_0` | `analog.com:user:axi_ad9361:1.0` | LVDS DDR (CMOS_OR_LVDS_N=0), MIMO_ENABLE=1, TDD_DISABLE=1, DAC_DDS_DISABLE=1, ADC_INIT_DELAY=30, IODELAY_CTRL=1, DELAY_REFCLK_FREQUENCY=200 |
| `axi_dma_0` | `xilinx.com:ip:axi_dma:7.1` | Nur S2MM (32-bit, SG enabled, c_sg_length_width=14, c_s2mm_burst_size=256, c_include_s2mm_dre=1) |
| `axi_ic_ctrl` | `xilinx.com:ip:axi_interconnect:2.1` | NUM_MI=3, NUM_SI=1 |
| `axi_ic_hp0` | `xilinx.com:ip:axi_interconnect:2.1` | NUM_MI=1, NUM_SI=2 |
| `xlconcat_irq` | `xilinx.com:ip:xlconcat:2.1` | NUM_PORTS=2 |
| `tetra_zynq_top_0` | Module-Reference auf `tetra_zynq_top.v` | `set_param ips.enableInterfaceArrayInference false` davor |

**Adressmap (PS GP0 0x4000_0000–0x7FFF_FFFF):**
| Offset | Range | Slave |
|------------------|--------|------------------------------------|
| `0x4040_0000` | 64 KB | `axi_dma_0.S_AXI_LITE` |
| `0x43C0_0000` | 64 KB | `tetra_zynq_top_0.s_axi.reg0` |
| `0x7902_0000` | 64 KB | `axi_ad9361_0.s_axi` |

**HP0 (DMA Datenpfad):**
- `axi_dma_0.Data_S2MM` → `sys_ps7/S_AXI_HP0/HP0_DDR_LOWOCM` (1 GB).
- `axi_dma_0.Data_SG` → `sys_ps7/S_AXI_HP0/HP0_DDR_LOWOCM` (1 GB).

**Datenpfade:**
- LVDS RX/TX (AD9361 ↔ axi_ad9361): `rx_clk_in_p/n`, `rx_frame_in_p/n`, `rx_data_in_p/n[5:0]`, gleiche TX-Signale. Individuell als externe BD-Ports (kein Interface-Bundle).
- AD9361 ↔ tetra_zynq_top (in BD geroutet): `l_clk`, `adc_valid_i0/q0`, `adc_data_i0/q0`, `adc_enable_i0/q0`, `adc_r1_mode`, `adc_dovf`. DAC dito.
- AXI-Stream: `tetra_zynq_top_0/m_axis` → `axi_dma_0/S_AXIS_S2MM`.

**Clocks:**
- FCLK_CLK0 (100 MHz) → alle AXI-Lite-Slaves, alle ACLKs, `tetra_zynq_top_0/i_clk`, `tetra_zynq_top_0/s_axi_aclk`.
- FCLK_CLK1 (200 MHz) → `axi_ad9361_0/delay_clk`.

**Resets:**
- `sys_ps7/FCLK_RESET0_N` → `sys_rstgen/ext_reset_in`.
- `sys_rstgen/peripheral_aresetn` → alle Peripherien + `tetra_zynq_top_0/i_arst_n`.
- `sys_rstgen/interconnect_aresetn` → beide Interconnect-Areset.

**IRQs:**
- `axi_dma_0/s2mm_introut` → `xlconcat_irq/In0`.
- `tetra_zynq_top_0/o_irq` → `xlconcat_irq/In1`.
- `xlconcat_irq/dout` → `sys_ps7/IRQ_F2P`.

**Externe Ports (per `make_bd_pins_external`):**
- DDR/FIXED_IO (per `apply_bd_automation`).
- LVDS-Paare (12 Pins).
- SPI_0 Interface, IIC_0 Interface (umbenannt zu `iic_main`).
- GPIO_I/O/T 64-bit (umbenannt zu `gpio_i/o/t`).
- `gpio_status` (8 bit, manuell erstellt).
- TDD-Pins (nur falls vom IP exportiert).
- `up_enable`, `up_txnrx`, `locked` (falls vorhanden).

**Outputs:** `tetra_system.bd`, `tetra_system_wrapper.v` (via `make_wrapper -files [get_files tetra_system.bd] -top`). Top wird auf `tetra_system_top` (RTL) gesetzt.

### scripts/export_xsa.tcl (62 Zeilen)
Lädt `build/post_route.dcp`, exportiert XSA mit eingebettetem Bitstream:
```
write_hw_platform -fixed -include_bit -force -file build/tetra_zynq_phy.xsa
```
Aufruf: `vivado -mode batch -source scripts/export_xsa.tcl`.

### scripts/program_fpga.tcl (45 Zeilen)
JTAG-Programmierung über Vivado HW-Manager (`localhost:3121`). Hartkodiert `xc7z020_1` als Device. Erwartet `build/tetra_zynq_phy.bit` (optional `.ltx`).

## Run Wrapper

### scripts/run_build.sh
4 Zeilen — setzt `ADI_HDL_DIR` und ruft `vivado -mode batch -source scripts/vivado_build.tcl` mit `tee build/vivado_build.log`.

```bash
export ADI_HDL_DIR=/home/kevin/openwifi/openwifi-hw/adi-hdl/library
exec vivado -mode batch -source scripts/vivado_build.tcl 2>&1 | tee build/vivado_build.log
```

## Deploy Pipeline

### scripts/deploy.sh — 4-Stage-Pipeline

Vollständiges Detail siehe `docs/ist/10_scripts.md` Abschnitt `deploy.sh`. Kurzfassung:

**Flags:**
- `--no-build` — Skip Vivado Synth (Verwendung existierendem `.bit`/`.bit.bin`).
- `--no-sw` — Skip SW-Cross-Compile + Upload.
- `--build-only` — Nur Vivado Build, kein Upload.
- `--init` — Nach Upload zusätzlich `full_init`, `vcxo_cal`, `rf_loopback`, daemons starten.

**Stages:**
1. `1/4 Vivado Build` — invokes `vivado_build.tcl`, validiert erzeugtes `.bit`.
2. `2/4 Bitstream Conversion` — `bootgen -w on -process_bitstream bin -image <BIF> -o <bin>` über minimale BIF-Syntax. Wenn `.bit` fehlt (z.B. nach `--no-build`), wird Stage 2 übersprungen falls `.bit.bin` bereits existiert.
3. `3/4 Cross-Compile sw/` — `make -C sw all` (siehe `docs/ist/09_sw_stack.md` für Toolchain).
4. `4/4 Upload to ${BOARD_IP}` — Killt running daemons (`tetra_sysinfo/ul_mon/attach_daemon`), pkill stale Phase-X.7-Legacy (`tetra_db_mgr/dbsync/autoenroll` mit Bracket-Trick `[t]etra_*`). SCP bitstream nach `/lib/firmware/tetra_zynq_phy.bit.bin` mit MD5-Verify. SCP `/root/tetra_sysinfo`, `/root/tetra_ul_mon`, `/root/tetra_attach_daemon`, `/root/db.tsv.default`. WebUI nach `/www/index.html` + `/www/cgi-bin/*.cgi` (purge stale `profiles.cgi`). `busybox httpd -p 80 -h /www` per `setsid`.

**Mit `--init`:**
- `tetra_ctrl.sh full_init 428250000 438250000` — RX/TX-Default seit deploy.sh-Update (vorher 429.95/439.95).
- `vcxo_cal.sh --dac 153` — Sweet-Spot.
- `tetra_ctrl.sh rf_loopback 428250000 438250000 13 -10` — SYNC_THRESH=13, TX_ATT=-10 dB.
- Symlink `/usr/bin/busybox` → `/usr/bin/devmem` (X.7 Workaround).
- Seedet `/root/db.tsv` aus `db.tsv.default`.
- `devmem 0x43C001AC 32 0x3` — REG_DB_POLICY = accept_unknown_issi+gssi.
- Startet `tetra_sysinfo --daemon`, `tetra_ul_mon`, `tetra_attach_daemon` per `setsid`.

**Board-Konstanten:**
- IP=`192.168.2.85`, user=`root`, pass=`openwifi` (alle Skripte einheitlich).

## Constraints

### constraints/libresdr_tetra.xdc (269 Zeilen)

Top-Modul: `tetra_system_top`.

**Sections:**

**System Clock** — keine externe Pin-Constraint nötig (FCLK0/FCLK1 sind PS-intern, Vivado erzeugt automatisch).

**AD9361 LVDS Interface** — 13 differentielle Paare:
- `rx_clk_in_p/n` (N20/P20), `rx_frame_in_p/n` (U18/U19).
- `rx_data_in_p/n[5:0]` — V16/W16 (bit5), W18/W19, R16/R17, V20/W20, V17/V18, Y18/Y19 (bit0).
- `tx_clk_out_p/n` (N18/P19), `tx_frame_out_p/n` (Y16/Y17).
- `tx_data_out_p/n[5:0]` — V15/W15 (bit5), V12/W13, T16/U17, U14/U15, T12/U12, W14/Y14 (bit0).
- IOSTANDARD `LVDS_25`, RX mit `DIFF_TERM TRUE`.

**AD9361 Control & GPIO (LVCMOS25):**
- `enable` (R18), `txnrx` (P14).
- SPI: `spi_csn` (P18, PULLTYPE PULLUP), `spi_clk` (R14), `spi_mosi` (P15), `spi_miso` (R19).
- `gpio_status[7:0]` (T11/T14/T15/T17/T19/T20/U13/V13).
- `gpio_ctl[3:0]` (T10/Y11/V10/U9).
- `gpio_en_agc` (P16), `gpio_sync` (U20), `gpio_resetb` (N17).

**I2C0 (LVCMOS33 PULLTYPE PULLUP):**
- `iic_scl` (M15), `iic_sda` (K16).

**LEDs (LVCMOS33):**
- `pl_led0` (J20), `pl_led1` (H20).

**DAC5311 SPI (LVCMOS33, VCXO-Tuning per EMIO-Bitbang):**
- `dac_sync` (H18), `dac_sclk` (F19), `dac_din` (F20).

**Clock Constraints:**
- `create_clock -name rx_clk -period 4 [get_ports rx_clk_in_p]` (= 250 MHz, max AD9361 DATA_CLK).

**Timing Exceptions:**
- `set_false_path -to` auf alle `rst_sync0_sys/axi/lvds/sample` Synchronizer.
- `set_clock_groups -asynchronous -group rx_clk -group clk_fpga_0`.
- `set_false_path -quiet -to *sync_locked_r0*`, `*pll_locked_r0*`.

**Multicycle Paths:**
- `u_rrc_filter/mac_tap_sys_reg → q_out_reg`: setup=2, hold=1 (Duty 0.65%, ~9.95 ns Datapath).
- `u_rrc_filter/mac_tap_sys_reg → i_out_reg`: gleiches Profil (Phase H.3.2e Slack-Sanierung).
- `u_timing_recovery/nco_step_sys_reg`: setup=2, hold=1.
- `u_timing_recovery/loop_integ_sys_reg`: setup=2, hold=1.
- `u_ul_sch_hu/vit_soft[01]_sys_reg → u_viterbi/surv_s*_reg*`: setup=4, hold=3 (Symbolrate 9 kHz).
- `u_accept_builder/llc_cov_len_reg → complete_pdu_bits_reg`: setup=4, hold=3 (1× pro Attach-Reply).
- `u_rx_frontend/q_comb4_z1_sys_reg → q_cic_out_sys_reg`: setup=2, hold=1.
- `u_tx_frontend/intg_*_reg*`: setup=2, hold=1.

**Board Voltage:**
- `set_property CONFIG_VOLTAGE 3.3 [current_design]`.
- `set_property CFGBVS VCCO [current_design]`.

### constraints/adi_cdc_async_reg.xdc (114 Zeilen)

Externe ASYNC_REG-Constraints für die ADI `axi_ad9361` IP. Behebt CDC-Reporting für 79 Unsafe-Crossings clk_fpga_0 ↔ rx_clk.

**Sections:**
- ADC-Path Sync (rx_clk → clk_fpga_0).
- DAC-Path Sync (clk_fpga_0 → rx_clk).
- `up_xfer*` Control-Pfad-Synchronizer.
- Generic Fallback für `*_r0` / `*_r1` Pattern in axi_ad9361.
- IP-Instance-Specific Targeting auf `tetra_system_i/tetra_system_axi_ad9361_0_0/inst/*`.

Alle Constraints mit `-hierarchical -quiet`, damit keine Warnings, falls Cells nicht existieren.

## SW / Cross-Compile

Aufruf aus `deploy.sh` Stage 3:
```
make -C sw all
```

Cross-Toolchain: `arm-linux-gnueabihf-gcc` (Debian-Paket `gcc-arm-linux-gnueabihf`).

Targets aus dem aktuellen `sw/Makefile`:
- `tetra_sysinfo` (Status-Daemon, AXI-Reg-Driver).
- `tetra_ul_mon` (UL-Mon-Daemon, polled `0x43C0_01xx` MAC-Mailbox-Regs, schreibt `/tmp/tetra_ul_mon.log`).
- `tetra_attach_daemon` (Phase X.7 SW-resident Subscriber-DB, Builder für D-LOC-UPDATE-ACCEPT/REJECT).

Detail siehe `docs/ist/09_sw_stack.md`.

## ILA Debug

### scripts/add_ila_debug.tcl
Setzt `MARK_DEBUG=true` auf eine vordefinierte Liste von Signalen (`sync_found_sample`, `sync_locked_sample`, `i/q_data_sys`, `symbol_valid_sample`, `dibit_valid_sample`, `slot_valid_sample`, `rcpc_enable_sys`, `i/q_sample_lvds`, `sample_valid_lvds`).

**Auffälligkeiten:** Hardcodierte BD-Hierarchie-Pfade (`tetra_system_wrapper/i_design_1.tetra_zynq_top_0.inst`), Syntax-Fehler in `catch`-Klammern. **Vermutlich obsolet** — der aktuelle ILA-Pfad geht direkt durch `vivado_build.tcl` über `ENABLE_ILA_DEBUG=1` und liest dort die `MARK_DEBUG`-Markierungen, die typischerweise in den RTL-Files (`(* mark_debug = "true" *)`) attribuiert sind.

### scripts/ila_capture.tcl
ILA-Trigger + CSV-Export aus laufendem HW-Manager. Args `--timeout_ms`, `--out_dir`, `--host`.

**Outputs:**
- `build/ila_lvds_data.csv` — Trigger: `dbg_adc_valid_i0 == 1`.
- `build/ila_sys_data.csv` — Trigger: `dbg_tx_slot_pulse == 1`.

Trigger-Position 10% von CONTROL.DATA_DEPTH. Wenn nur 1 ILA-Core → wird als SYS-ILA verwendet.

### scripts/ila_autonomous_capture.tcl
Standalone-Capture (kein `hw_deploy.sh`-Wrapper). Trigger auf `sync_found_sample` rising edge, 60s Timeout, CAPTURE_DEPTH=1024, TRIGGER_POSITION=256. Output `build/ila_capture_${YYYYMMDD_HHMMSS}.csv`.

## CDC Reporting

### scripts/extract_cdc_violations.tcl

Liest CDC-Violations aus `impl_1`, kategorisiert nach Bit-Width und Signal-Namen-Heuristik:

| Bit-Width | Signal-Pattern | Kategorie | Fix-Strategie |
|-----------|------------------------|-----------------|-----------------|
| > 16 | beliebig | Data Bus | XPM Async FIFO |
| 2..16 | `*cnt*/counter*/num*` | Counter | Gray-Code + 2FF |
| 2..16 | sonst | Data Bus | XPM Async FIFO |
| 1 | `*pulse*/valid*/req*` | Pulse | Toggle-Sync |
| 1 | sonst | Control | 2FF Sync |

**Outputs:**
- `reports/cdc_violations_detailed.rpt` (full `report_cdc -details` output).
- `reports/cdc_unsafe_crossings.txt` (sortiert nach Sektion).
- `reports/cdc_signal_categories.csv` (Spreadsheet).

**Aufruf:**
```
vivado -mode batch -source scripts/extract_cdc_violations.tcl
```

**Auffälligkeiten:** Tippfehler `lassassign` (statt `lassign`) in Pulse-Signal-CSV-Branch (Zeile 189). Skript scheitert dort wahrscheinlich, falls Pulse-Signale gefunden werden. Vermutlich Einmal-Analyse-Tool und seither nicht wieder gelaufen.

## Hardware Test / JTAG Workflow

### scripts/hw_deploy.sh (324 Zeilen)

Vollautomatischer JTAG-basierter Workflow. Detail siehe `docs/ist/10_scripts.md` Abschnitt `hw_deploy.sh`. Kurzfassung der Stage-Sequenz:

1. **Voraussetzungen** — Vivado-Auto-Detect (mehrere Pfade), sshpass, python3.
2. **Schritt 1: hw_server** — startet `hw_server` auf Port 3121 falls nicht läuft.
3. **Schritt 2: Bitstream-Flash via JTAG** — ruft `program_fpga.tcl`. Anschließend 2s `sleep`.
4. **Schritt 3: AD9361-Init via SSH** — ruft `ad9361_init.sh`.
5. **Schritt 3b: Zweiter Bitstream-Load** — für axi_ad9361 MMCM-Lock.
6. **Schritt 3c: ADI DAC-Core devmem-Init** — `0x79024000` +0x40/+0x48/+0x418/+0x458.
7. **Schritt 4: ILA-Capture** — ruft `ila_capture.tcl`.
8. **Analyse** — ruft `analyze_ila.py`.

## IP-Generation

### scripts/generate_viterbi_ip.tcl
Einmal-Skript zur Generierung des Xilinx Viterbi v9.1 IP `vit_ul_sch_hu` (K=5, R=1/4, ETSI-Codepolynome, Soft=5-bit, Traceback=32). Output `ip/vit_ul_sch_hu/vit_ul_sch_hu.xci`.

**Status:** Wird vom aktuellen Build NICHT konsumiert. Der UL-SCH/HU-Decoder läuft im Build über das manuell implementierte Verilog-Modul `rtl/rx/tetra_ul_viterbi_r14.v`.

## Reports-Übersicht

Nach erfolgreichem `vivado_build.tcl` liegen in `build/reports/`:
- `synth_utilization.rpt` — Post-Synth Resource-Counts.
- `synth_timing.rpt` — Top 10 Timing-Pfade nach Synth.
- `impl_utilization.rpt` — Post-Impl Resource-Counts.
- `impl_timing.rpt` — Top 20 Timing-Pfade nach Impl.
- `clock_interaction.rpt` — Clock-Domain-Interaktion.
- `cdc_report.rpt` — CDC-Übersicht.

Optional nach `extract_cdc_violations.tcl`:
- `reports/cdc_violations_detailed.rpt`
- `reports/cdc_unsafe_crossings.txt`
- `reports/cdc_signal_categories.csv`

## Logs

- `build/vivado_build.log` (von `run_build.sh` und `deploy.sh`).
- `build/program_fpga.log` (von `hw_deploy.sh`).
- `build/ila_capture.log` (von `hw_deploy.sh`).
