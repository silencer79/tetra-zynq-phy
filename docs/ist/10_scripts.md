# IST — Kapitel 10: Scripts
Stand: 2026-05-14

Beschreibt den aktuellen Zustand aller Skripte in `scripts/`. Reine Bestandsaufnahme — keine Vergleiche, keine Empfehlungen.

## Übersicht

55 Files in `scripts/` (ohne `__pycache__`):
- 7 Build/Deploy/Init Shell-Skripte
- 8 Vivado/TCL-Skripte
- 13 Decode/Analyze Python-Skripte
- 19 Test-Vector / Verify Python-Skripte (`gen_*` / `verify_*` / `check_*`)
- Top-Level: kein Makefile im Projekt-Root.

---

## Build / Deploy / Init (Shell)

### scripts/run_build.sh
**Aufgabe:** Minimaler Wrapper, setzt `ADI_HDL_DIR` und ruft Vivado im Batch-Modus mit `scripts/vivado_build.tcl` auf.
**Inputs:** Keine CLI-Args. Hartkodiert `ADI_HDL_DIR=/home/kevin/openwifi/openwifi-hw/adi-hdl/library`.
**Outputs:** `build/vivado_build.log` (tee'd), Bitstream-Artefakte indirekt via Vivado-TCL.
**Stages:** Eine Zeile (`exec vivado -mode batch -source scripts/vivado_build.tcl`).
**Notable Constants:** `ADI_HDL_DIR=/home/kevin/openwifi/openwifi-hw/adi-hdl/library`.

### scripts/deploy.sh
**Aufgabe:** One-Command-Pipeline für Vivado-Build → bootgen-Konvertierung → SW-Cross-Compile → SCP-Upload zum Board.
**Inputs:** CLI-Args `--no-build`, `--no-sw`, `--build-only`, `--init`, `-h`/`--help`. Env-Vars: keine. Erwartet: Vivado (auto-detect oder PATH), `arm-linux-gnueabihf-gcc`, `sshpass`, `scp`, `ssh`. Board erreichbar.
**Outputs:**
- `build/${BITSTREAM_NAME}.bit` (Vivado)
- `build/${BITSTREAM_NAME}.bit.bin` (bootgen)
- `build/vivado_build.log`
- Upload `/lib/firmware/tetra_zynq_phy.bit.bin` (md5 verified)
- Upload `/root/tetra_sysinfo`, `/root/tetra_ul_mon`, `/root/tetra_attach_daemon`, `/root/db.tsv.default`
- Optional WebUI nach `/www/index.html` + `/www/cgi-bin/*.cgi`
- Bei `--init`: startet daemons mit `setsid`, schreibt `REG_DB_POLICY=0x3` an `0x43C001AC`.

**Stages:**
1. `1/4: Vivado Build` — löscht stale `.bit`, baut über `vivado_build.tcl`, grep'd auf Phase/INFO Timing/ERROR/WARNING etc.
2. `2/4: Bitstream Conversion` — bootgen `.bit` → `.bit.bin` mit minimaler BIF-Syntax.
3. `3/4: Cross-Compile sw/` — `make -C sw all` baut `tetra_sysinfo` + `tetra_ul_mon`.
4. `4/4: Upload to ${BOARD_IP}` — killt laufende Daemons (`tetra_sysinfo`, `tetra_ul_mon`, `tetra_attach_daemon`), `pkill -f '[t]etra_db_mgr|[t]etra_dbsync|[t]etra_autoenroll'` für Phase-X.7-Cleanup, scp bitstream + binaries, md5-verifiziert, lädt WebUI hoch und startet `busybox httpd -p 80 -h /www`.

**Notable Constants:** `BOARD_IP=192.168.2.85`, `BOARD_USER=root`, `BOARD_PASS=openwifi`, `BITSTREAM_NAME=tetra_zynq_phy`, `REMOTE_FW_DIR=/lib/firmware`, `REMOTE_BIN_DIR=/root`.

**Bei `--init`:**
- `tetra_ctrl.sh full_init 428250000 438250000` (RX=428.25 MHz, TX=438.25 MHz).
- `vcxo_cal.sh --host 192.168.2.85 --dac 153`.
- `tetra_ctrl.sh rf_loopback 428250000 438250000 13 -10` (SYNC_THRESH=13, TX_ATT=-10 dB).
- Seedet `/root/db.tsv` aus `db.tsv.default` falls fehlend.
- Symlinkt `/usr/bin/busybox` → `/usr/bin/devmem` (Phase X.7 Workaround für fresh openwifi).
- Startet `tetra_sysinfo --daemon`, `tetra_ul_mon`, `tetra_attach_daemon` per `setsid`.

**Auffälligkeiten:** Bracket-Trick `'[t]etra_*'` in `pkill -f` für Phase-X.7-Cleanup (procps-pkill würde sonst seine eigene SSH-Shell killen). Inline-Doku zu Phase X.7 (Subscriber-DB SW-resident) sehr ausführlich.

### scripts/convert_bitstream.sh
**Aufgabe:** Standalone-Skript für `.bit` → `.bit.bin` (Linux FPGA-Manager-Format) via bootgen. Funktional Teilmenge von `deploy.sh` Step 2/4.
**Inputs:** Keine CLI-Args. Erwartet `build/tetra_zynq_phy.bit` und Vivado-Settings sourced.
**Outputs:** `build/tetra_zynq_phy.bit.bin` (~4 MB).
**Stages:** BIF-Datei generieren → `bootgen -w on -process_bitstream bin`.
**Notable Constants:** Hartkodiert `BITSTREAM=tetra_zynq_phy`, Empfänger-IP `192.168.2.85` in Hinweistext.
**Auffälligkeiten:** Doppelter Codepfad mit `deploy.sh` Step 2.

### scripts/hw_deploy.sh
**Aufgabe:** Vollautomatischer JTAG-Flash + AD9361-Init + ILA-Capture-Workflow (5-Schritt-Sequenz).
**Inputs:** CLI-Args `--host`, `--freq`, `--samplerate`, `--gain`, `--agc`, `--timeout`, `--no-flash`, `--no-ad9361`, `--no-ila`, `--vivado`, `--help`/`-h`. Defaults: Host=192.168.2.85, Freq=430000000, SR=4608000, Gain=40 dB, Timeout=30000 ms.
**Outputs:** `build/program_fpga.log`, `build/ila_capture.log`, `build/ila_lvds_data.csv`, `build/ila_sys_data.csv`, Python-Analyse-Output.
**Stages:**
1. Voraussetzungen (Vivado, sshpass, python3).
2. `hw_server` starten (Port 3121) falls nicht läuft.
3. Bitstream JTAG-Flash via `program_fpga.tcl`.
4. AD9361 init via `ad9361_init.sh`.
5. 2. Bitstream-Load (für MMCM-Lock).
6. ADI DAC-Core devmem-Init (`0x79024000+0x40/0x48/0x418/0x458`).
7. ILA-Capture via `ila_capture.tcl`.
8. Analyse via `analyze_ila.py`.

**Notable Constants:** `SSH_HOST="192.168.2.85"`, `BIT_FILE=build/tetra_zynq_phy.bit`, `LTX_FILE=build/tetra_zynq_phy.ltx`.
**Auffälligkeiten:** Vivado-Auto-Detect probiert mehrere Pfade (`/tools/Xilinx/`, `/opt/Xilinx/`, `~/tools/`). Farbiges Terminal-Output (`OK`/`FAIL`/`WARN`/`INFO`/`STEP`).

### scripts/ad9361_init.sh
**Aufgabe:** Lädt `ad9361_drv.ko`-Modul, bindet SPI an AD9361, konfiguriert RX-Freq/SR/Gain/BW + FDD-Mode via `iio_attr` über SSH.
**Inputs:** CLI-Args `--host`, `--freq`, `--tx-freq`, `--samplerate`, `--gain`, `--agc`. Defaults: 192.168.2.85, RX=429950000, SR=4608000, Gain=40, GAIN_MODE=fast_attack.
**Outputs:** stdout-Logging der iio_attr-Aufrufe.
**Notable Constants:** `BW_HZ=200000` (AD9361-Min, optimal für 25 kHz TETRA). TX-Freq Default = RX+10 MHz.
**Schritte:**
1. SSH-Verbindungstest.
2. `insmod /root/kernel_modules32/ad9361_drv.ko` (OpenWiFi-Kernel hat kein eingebautes ad9361).
3. SPI-Binding: `driver_override` leeren, `spi0.0 → ad9361/bind`.
4. IIO-Device suchen (`ad9361-phy`).
5. `voltage0 sampling_frequency`, `altvoltage0/1 frequency`, `voltage0 gain_control_mode`, `voltage0 rf_bandwidth`.
6. `ensm_mode fdd`.
7. `out_voltage0_hardwaregain = 0` (TX1-Default; out_voltage1 = TX2 unverbunden).
8. `calib_mode tx_quad` triggern.
9. Verify-Readback.

**Auffälligkeiten:** Inline-Hinweis: out_voltage0 = TX1 aktiv, out_voltage1 = TX2 nicht verbunden. Hardcoded sshpass.

### scripts/tetra_ctrl.sh
**Aufgabe:** TETRA-PHY-Register-Tool. AXI-Lite-Zugriff via `busybox devmem` über SSH. Multi-Command CLI.
**Commands:**
- `status` — Dump aller Register (CTRL/STATUS/VERSION/SYNC_THRESH/COLOUR_CODE/FRAME_NUM/SLOT_NUM/IRQ_STATUS).
- `enable` — CTRL=0x03 (TX_EN + RX_EN).
- `dac_init` — ADI axi_ad9361 DAC-Core release reset + fabric data-Mode (Reg 0x79024000 +0x40/+0x48/+0x418/+0x458).
- `adc_init` — ADC-Core release reset, r1_mode=0 (2R2T DDR), Channel enable + sign-extend (Reg 0x79020000).
- `full_init [RX_Hz] [TX_Hz]` — Komplette 2× Bitstream-Load + 2× AD9361-Init via FPGA-Manager (no JTAG). Defaults: 429950000, 439950000.
- `tx_monitor [Hz]` — Default 440000000 — schaltet AD9361 auf `TX_MONITOR1_2`.
- `rf_loopback [RX_Hz] [TX_Hz] [THR] [TX_ATT_dB]` — Defaults 430000000, 430000000, 15, -50. Verifizierter AGC-Sweep: -30 → AGC≈28; -40 → 40; -50 → 47 (optimal); -55 → 52; -60 → 58.
- `loopback` — CTRL=0x07 (TX_EN+RX_EN+LOOPBACK).
- `disable` — CTRL=0x00.
- `monitor` — Endless-Poll von STATUS+Counter (FE/DEMOD/SYNC_RAW@0x50/0x54/0x58) bis SYNC_LOCKED.
- `read <offset>` / `write <offset> <value>` — Einzelregister.

**Notable Constants:** `BASE_ADDR=0x43C00000`, `ADC_BASE=0x79020000`, `DAC_BASE=0x79024000`, `BOARD_IP=192.168.2.85`.
**Register-Offsets:** `CTRL=0x00`, `STATUS=0x04`, `VERSION=0x08`, `SYNC_THRESH=0x0C`, `COLOUR_CODE=0x10`, `FRAME_NUM=0x14`, `SLOT_NUM=0x18`, `IRQ_STATUS=0x28`.
**Auffälligkeiten:** Sehr ausführliche Inline-Doku zu ADI DAC/ADC-Init-Sequenz. `full_init` Step 1+3 verwendet `/sys/class/fpga_manager/fpga0/firmware`.

### scripts/vcxo_cal.sh
**Aufgabe:** Schreibt DAC5311 (8-Bit-DAC für 40-MHz-VCXO-Tuning) per PS-GPIO-EMIO-Bitbang.
**Inputs:** CLI-Args `--host` (192.168.2.85), `--dac N` (0..255), `--xo HZ`, `--read`, `--init`, `--deinit`, `--help`.
**Outputs:** stdout-Status, DAC-Wert schreiben, optional `iio_attr -d ad9361-phy xo_correction`.
**Notable Constants:** `GPIO_CS=1011`, `GPIO_CLK=1012`, `GPIO_DIN=1013` (EMIO[51:53]). DAC5311-Frame: `[15:14]=PD=00`, `[13:6]=Data`, `[5:0]=DC`.
**Stages:** `gpio_export` → 16-bit MSB-first bitbang (CS low → toggle CLK je Bit → CS high).
**Auffälligkeiten:** Verweist auf `xo_correction` Feinjustierung über AD9361 IIO.

### scripts/aach_grant_poke.sh
**Aufgabe:** Phase-H.6.3-Helper. Schreibt `REG_AACH_GRANT_HINT @ 0x43C001F4` (Bit 31 = pending, Bits [13:0] = info). HW löscht Bit 31 nach Auswurf auf TN=0-Idle-Slot.
**Inputs:** Eine optionale CLI-Arg: 14-Bit Info-Wort. Default 0x4001.
**Outputs:** Devmem-Schreiben, Readback, `UL_CONT_CNT @ 0x1B8` before/after-Vergleich.
**Notable Constants:** Board=`root@192.168.2.85`, REG_AACH_GRANT_HINT=`0x43C001F4`, REG_UL_CONT_CNT=`0x43C001B8`.
**Auffälligkeiten:** Per-burst-Test-Recipe in Kommentar.

### scripts/gen_all_vectors.sh
**Aufgabe:** Sequenzieller Wrapper für `tb/vectors/gen_*_vectors.py`-Skripte.
**Inputs:** Keine CLI-Args.
**Outputs:** `.hex`/`.txt`-Vektor-Files in `tb/vectors/`.
**Liste:** `gen_reset_vectors.py`, `gen_pi4dqpsk_vectors.py`, `gen_viterbi_vectors.py`, `gen_reed_muller_vectors.py`, `gen_scrambler_vectors.py`, `gen_burst_vectors.py`, `gen_crc16_vectors.py`.
**Auffälligkeiten:** Skipt Files, die nicht existieren. Diese werden in `tb/vectors/` erwartet (nicht in `scripts/`).

---

## Vivado / TCL

### scripts/vivado_build.tcl
**Aufgabe:** Vollständiger Build-Flow: RTL-Sourcen einlesen → Block Design erzeugen → Synth → Impl → Bitstream-Generierung.
**Inputs:** Env-Vars `ENABLE_ILA_DEBUG` (default 0), `ADI_HDL_DIR` (optional, sonst auto-detect).
**Outputs:**
- `build/tetra_zynq_phy.bit`
- `build/tetra_zynq_phy.ltx` (Debug-Probes)
- `build/post_synth.dcp`, `build/post_opt.dcp`, `build/post_route.dcp`
- `build/reports/synth_utilization.rpt`, `synth_timing.rpt`, `impl_utilization.rpt`, `impl_timing.rpt`, `clock_interaction.rpt`, `cdc_report.rpt`

**Konstanten:**
- `PROJ_NAME=tetra_zynq_phy`
- `PART=xc7z020clg400-1`
- `XPM_LIBRARIES={XPM_FIFO XPM_MEMORY}`

**Steps:**
1. `create_project` (Vivado-Project in `build/vivado/`).
2. RTL-Sourcen-Add:
 - **Infra (3):** `tetra_clk_reset.v`, `tetra_axi_lite_regs.v`, `tetra_axi_dma_bridge.v`.
 - **AD9361 Adapter:** `tetra_ad9361_axis_adapter.v` (Note: `tetra_ad9361_interface.v` referenced as kept-but-not-used).
 - **RX Chain (14):** `tetra_rx_chain.v`, `tetra_rx_frontend.v`, `tetra_pi4dqpsk_demod.v`, `tetra_timing_recovery.v`, `tetra_sync_detect.v`, `tetra_ul_sync_detect_os4.v`, `tetra_ul_burst_capture.v`, `tetra_ul_voice_capture.v`, `tetra_ul_pi4dqpsk_demod.v`, `tetra_ul_sch_hu_decoder.v`, `tetra_ul_viterbi_r14.v`, `tetra_burst_demux.v`, `tetra_frame_counter.v`, `tetra_ul_demand_reassembly.v`.
 - **TX Chain (12):** `tetra_tx_chain.v`, `tetra_tx_frontend.v`, `tetra_pi4dqpsk_mod.v`, `tetra_rrc_filter.v`, `tetra_tx_inv_sinc.v`, `tetra_burst_builder.v`, `tetra_burst_dispatcher.v`, `tetra_tdma_timebase.v`, `tetra_slot_schedule.v`, `tetra_slot_content_mux.v`, `tetra_sb1_encoder.v`, `tetra_aach_encoder.v`, `tetra_aach_rm_encoder.v`.
 - **LMAC (28):** `tetra_lmac.v`, `tetra_scrambler.v`, `tetra_interleaver.v`, `tetra_deinterleaver.v`, `tetra_depuncture_r23.v`, `tetra_rcpc_encoder.v`, `tetra_viterbi_decoder.v`, `tetra_reed_muller.v`, `tetra_crc16.v`, `tetra_steal_detect.v`, `tetra_ul_mac_access_parser.v`, `tetra_d_location_update_encoder.v`, `tetra_d_location_update_reject_encoder.v`, `tetra_sch_hd_encoder.v`, `tetra_sch_f_encoder.v`, `tetra_basic_slotgrant_encoder.v`, `tetra_chan_alloc_encoder.v`, `tetra_mac_resource_dl_builder.v`, `tetra_mac_resource_bl_ack_builder.v`, `tetra_mle_registration_fsm.v`, `tetra_dl_signal_queue.v`, `tetra_dl_signal_scheduler.v`, `tetra_ul_demand_ie_parser.v`, `tetra_dl_nwrk_broadcast.v`, `tetra_indirect_mailbox.v`, `tetra_indirect_mailbox_wr.v`, `tetra_demand_mailbox.v`, `tetra_reply_mailbox.v`, `tetra_grp_demand_mailbox.v`, `tetra_pre_reply_blck.v`, `tetra_pre_reply_slotgrant.v`, `tetra_dl_pdu_builder.v`.
 - **Top-Level:** `tetra_zynq_top.v`, `tetra_system_top.v`.
 - **Constraints:** `libresdr_tetra.xdc`, `adi_cdc_async_reg.xdc`.
 - **Header:** `rtl/include/tetra_pdu_class.vh` als `is_global_include=true`. Include-Path `rtl/include`.
3. `source scripts/create_bd.tcl` → Block-Design + Wrapper.
4. **Synth:** `synth_design -top tetra_system_top -flatten_hierarchy rebuilt -directive PerformanceOptimized -retiming`. BD-Synth-Mode `SYNTH_CHECKPOINT_MODE=None` (Global).
5. **Impl:** `opt_design`, optional ILA-Insertion (siehe ENABLE_ILA_DEBUG), `place_design -directive Auto_1`, `phys_opt_design -directive AggressiveExplore`, `route_design -directive AggressiveExplore`, `phys_opt_design -directive AggressiveExplore`. Reports: `report_utilization`, `report_timing_summary`, `report_clock_interaction`, `report_cdc`.
6. **Bitstream:** `write_bitstream` + `write_debug_probes`. WNS-Check (warn bei negativem Slack).

**ILA-Logik (bedingt durch `ENABLE_ILA_DEBUG`):** Liest `MARK_DEBUG` nets, gruppiert sie nach Domain (Endung `*_lvds` → l_clk, sonst → clk_sys), erstellt `u_ila_sys` (4096 tief). `u_ila_lvds` ist explizit DISABLED (l_clk nicht aktiv ohne AD9361-Init).

**Auffälligkeiten:** ILA per Default OFF (Production). Inline-Kommentar zur Slack-Sanierung Phase H.3.2e.

### scripts/create_bd.tcl
**Aufgabe:** Erzeugt das Block-Design `tetra_system` mit PS7, axi_ad9361 IP, AXI DMA, Interconnects und der `tetra_zynq_top` Module-Reference.
**Inputs:** Vivado-Variable `ADI_HDL_DIR` (sonst auto-detect aus `~/openwifi/openwifi-hw/adi-hdl/library`, `/opt/adi/hdl/library`, `~/hdl/library`, `/tools/adi/hdl/library`; Fallback `libresdr/ip/`).
**Outputs:** `tetra_system.bd` + `tetra_system_wrapper.v` (auto generated).

**BD-Komponenten:**
- `sys_ps7` — `xilinx.com:ip:processing_system7:5.5`. PCW_USE_M_AXI_GP0=1, PCW_USE_S_AXI_HP0=1 (64-bit), FCLK0=100 MHz, FCLK1=200 MHz, SPI0/I2C0/UART0/ENET0/SD0/GPIO EMIO 64-bit, DDR Freq 534 MHz.
- `sys_rstgen` — `proc_sys_reset:5.0` (100 MHz Domain).
- `axi_ad9361_0` — `analog.com:user:axi_ad9361:1.0`. CMOS_OR_LVDS_N=0, MIMO_ENABLE=1, TDD_DISABLE=1, DAC_DDS_DISABLE=1, ADC_INIT_DELAY=30, IODELAY_CTRL=1, DELAY_REFCLK_FREQUENCY=200.
- `axi_dma_0` — `axi_dma:7.1`. Nur S2MM (32-bit, SG enabled, c_sg_length_width=14, burst_size=256), kein MM2S.
- `axi_ic_ctrl` — `axi_interconnect:2.1`, NUM_MI=3, NUM_SI=1.
- `axi_ic_hp0` — `axi_interconnect:2.1`, NUM_MI=1, NUM_SI=2.
- `tetra_zynq_top_0` — Module reference. `set_param ips.enableInterfaceArrayInference false` davor.
- `xlconcat_irq` — `xlconcat:2.1`, NUM_PORTS=2.

**Adressmap:**
- `0x4040_0000` — AXI DMA Control (64 KB).
- `0x43C0_0000` — `tetra_zynq_top_0/s_axi/reg0` (64 KB).
- `0x7902_0000` — `axi_ad9361_0/s_axi` (64 KB).
- DMA S2MM / SG → HP0 0x00000000–0x40000000 (1 GB DDR-Fenster).

**Externe Ports:**
- LVDS-Paare des AD9361 als individuelle `make_bd_pins_external`.
- SPI_0 (`make_bd_intf_pins_external`).
- IIC_0 → umbenannt zu `iic_main`.
- GPIO_I/O/T (64-bit) → umbenannt zu `gpio_i/gpio_o/gpio_t`.
- `gpio_status` (8 bit).
- TDD-sync (nur falls Pins existieren).
- `up_enable`, `up_txnrx`, `locked` (falls vorhanden).

**Auffälligkeiten:** Generic BD-Wrapper mit `make_wrapper`. Top wird auf `tetra_system_top` gesetzt.

### scripts/vivado_sim.tcl
**Aufgabe:** Per-Modul-Behavioral-Simulation. Behält Tcl `MODULE_FILES`-Array mit pro-Modul RTL+TB-Listen.
**Inputs:** CLI-Arg `<module_name>` (über `-tclargs`).
**Outputs:** `sim_out/$MODULE/simulate.log`. PASS/FAIL via `grep` auf "RESULT: PASS"/"RESULT: FAIL".
**Notable Constants:** `xc7z020clg484-1` (Note: BD und Build verwenden `xc7z020clg400-1` — unterschiedliches Package).
**Supported Modules:** `tetra_clk_reset`, `tetra_ad9361_interface`, `tetra_pi4dqpsk_demod`, `tetra_timing_recovery`, `tetra_sync_detect`, `tetra_burst_demux`, `tetra_frame_counter`, `tetra_tdma_timebase`, `tx_slot_schedule`, `tetra_burst_dispatcher`, `tetra_bsch_encoder_integration`, `tetra_aach_encoder`, `tetra_scrambler`, `tetra_interleaver`, `tetra_rcpc_encoder`, `tetra_viterbi_decoder`, `tetra_reed_muller`, `tetra_crc16`, `tetra_loopback`.
**Auffälligkeiten:** Liste nicht synchron mit aktuellem RTL-Bestand (keine Einträge für UL-Module, Mailboxen, MLE-FSM, …). Package-Discrepancy zum Build-Script.

### scripts/export_xsa.tcl
**Aufgabe:** Lädt `build/post_route.dcp`, exportiert Hardware-Plattform (`.xsa`) mit eingebettetem Bitstream.
**Inputs:** Keine CLI-Args. Erwartet existierende `build/post_route.dcp` + `build/tetra_zynq_phy.bit`.
**Outputs:** `build/tetra_zynq_phy.xsa`.
**Auffälligkeiten:** Hinweis auf nachfolgendes `convert_bitstream.sh`.

### scripts/program_fpga.tcl
**Aufgabe:** JTAG-Programmierung über Vivado HW-Manager (localhost:3121).
**Inputs:** Erwartet `build/tetra_zynq_phy.bit`. Optional `build/tetra_zynq_phy.ltx`.
**Outputs:** Programmiert XC7Z020 über JTAG.
**Auffälligkeiten:** Hartkodiert `xc7z020_1` als Device.

### scripts/add_ila_debug.tcl
**Aufgabe:** Setzt `MARK_DEBUG=TRUE` auf eine Liste vordefinierter Signal-Pfade (`sync_found_sample`, `sync_locked_sample`, `i/q_data_sys`, `symbol_valid_sample`, `dibit_valid_sample`, `slot_valid_sample`, `rcpc_enable_sys`, `i/q_sample_lvds`, `sample_valid_lvds`).
**Inputs:** Soll im Vivado-Projekt-Context laufen.
**Outputs:** Vivado erstellt automatisch ILA-Cores während Synth.
**Auffälligkeiten:** Syntax-Fehler in mehreren Zeilen (`}]]` doppelte Klammern bei `catch`), wahrscheinlich obsolet. Hardcoded BD-Hierarchie-Pfade (`tetra_system_wrapper/i_design_1.tetra_zynq_top_0.inst`). **Vermutlich obsolet** — der aktuelle ILA-Pfad läuft direkt in `vivado_build.tcl` über `ENABLE_ILA_DEBUG`.

### scripts/ila_capture.tcl
**Aufgabe:** ILA-Trigger + Daten-Export. Lädt LTX, sucht ILA-Cores, triggert, exportiert CSV.
**Inputs:** CLI-Args `--timeout_ms` (default 30000), `--out_dir` (default `build`), `--host` (default `localhost:3121`).
**Outputs:**
- `${out_dir}/ila_lvds_data.csv` — LVDS-Domain (Trigger: `dbg_adc_valid_i0 == 1`).
- `${out_dir}/ila_sys_data.csv` — SYS-Domain (Trigger: `dbg_tx_slot_pulse == 1`).
**Auffälligkeiten:** Falls nur ein ILA-Core gefunden → wird als SYS-ILA verwendet. Trigger-Position 10% von Buffer-Depth. Encoding der Trigger-Compare-Value `eq'b1`.

### scripts/ila_autonomous_capture.tcl
**Aufgabe:** Standalone-ILA-Capture (lädt LTX, triggert auf `sync_found_sample` rising edge, 60s timeout, schreibt CSV mit Zeitstempel).
**Inputs:** Hartkodiert `build/tetra_zynq_phy.ltx`.
**Outputs:** `build/ila_capture_${YYYYMMDD_HHMMSS}.csv`.
**Notable Constants:** Trigger-Probe `sync_found_sample`, CAPTURE_DEPTH=1024, TRIGGER_POSITION=256.
**Auffälligkeiten:** Setzt sehr spezifisch `eq1_rising` als TRIGGER_COMPARE_VALUE. Wahrscheinlicher Duplikat zu `ila_capture.tcl` mit anderem Trigger.

### scripts/extract_cdc_violations.tcl
**Aufgabe:** Liest CDC-Violations aus `impl_1`, kategorisiert (Data-Bus/Counter/Control/Pulse), schreibt formatierten Report + CSV.
**Inputs:** Erwartet existierendes Projekt `build/tetra_zynq_phy.xpr`.
**Outputs:** `reports/cdc_violations_detailed.rpt`, `reports/cdc_unsafe_crossings.txt`, `reports/cdc_signal_categories.csv`.
**Kategorisierung:** Bit-Width >16 → XPM Async FIFO; 2–16 mit `*cnt*`/`*counter*`/`*num*` → Gray-Code+2FF; 1-Bit pulse → Toggle-Sync; sonst → 2FF.
**Auffälligkeiten:** Tippfehler `lassassign` in pulse_signals-CSV-Branch (Zeile 189). Vermutlich nur als Einmal-Analyse-Tool verwendet.

### scripts/generate_viterbi_ip.tcl
**Aufgabe:** Erzeugt Xilinx Viterbi v9.1 IP `vit_ul_sch_hu` für UL-SCH/HU-Decoder.
**Inputs:** Keine CLI-Args.
**Outputs:** `ip/vit_ul_sch_hu/vit_ul_sch_hu.xci`.
**Konfig:** K=5, Output_Rate=4, Code0=11000, Code1=10110, Code2=11100, Code3=11010, Soft_Width=5, Traceback=32, Parallel architecture.
**Auffälligkeiten:** Einmaliger Generator (kein Bestandteil des Build-Flows aktuell — Build verwendet die manuelle Verilog-Viterbi-Implementierung `tetra_ul_viterbi_r14.v`).

---

## Decode / Analyze (Python)

### scripts/decode_dl.py (2183 Zeilen)
**Aufgabe:** Vollständiger TETRA-Downlink-Decoder. Verarbeitet ALL Burst-Typen (SB+NDB1+NDB2) aus continuous-DL-WAV oder RTL-SDR-Capture, parsed MAC-Header / LLC / MLE / CMCE / MM / Direct-MM.
**CLI-Args:**
- `input` (positional, default `/tmp/tetra_tx_capture.bin`).
- `--sr` (default 2048000).
- `--offset` (default 0; 0=auto).
- `--max-bursts` (default 200).
- `--conjugate`, `--swap-iq` flags.
- `-v`/`--verbose`.
- `--capture` → ruft `rtl_sdr -d 0 -f $freq -s $sr...` auf.
- `--freq` (default 440106000).
- `--gain` (default 40).
- `--duration` (default 2.0).
- `--dump-burst` (default `-1`, akzeptiert Comma-Liste oder `-2` für Grid-only).

**Inputs:** WAV-Datei (stereo I/Q int16) ODER RTL-SDR uint8.bin.
**Outputs:** stdout — Burst-für-Burst Decode mit MAC/LLC/MLE-Parsing, Summary mit Counter pro PDU-Typ.

**Wichtige Funktionen (Auswahl):**
- `dibits_to_symbols`, `demod_pi4dqpsk`, `demod_pi4dqpsk_soft` — π/4-DQPSK Modulator/Demodulator.
- `dibits_to_bits` — MSB-first Konvertierung.
- `_build_diff_ref`, `_correlate_at` — Trainings-Sequenz-Korrelation.
- `rrc_filter` — Root-Raised-Cosine α=0.35.
- `scrambler_seq`, `make_scramb_code`, `make_scramb_code_dmo` — TMO/DMO Scrambler-Init.
- `crc32_check_llc` — LLC-FCS-CRC (poly 0xEDB88320, good 0xDEBB20E3).
- `crc16_check_dll` — DLL-CRC-16 (poly 0x1021, init 0xFFFF, good 0x1D0F).
- `class NetworkTime` — 1-based FN/TN/MN-Tracker mit BSCH/BNCH-Rotation, mirror der DLL-Logik.
- `frequency_calc` — TETRA Frequenz aus carrier+band+offset.
- `deinterleave_perm`, `depuncture_r23`, `viterbi_r14`, `_parity5`, `decode_channel`, `descramble_soft`, `depuncture_r23_soft`, `viterbi_r14_soft`, `decode_channel_soft` — Kanal-Dekodierung (hart + soft, ETSI-konform).
- `_build_rm_codewords`, `rm3014_decode` — Reed-Muller (30,14).
- `parse_aach` — AACH-Felder (14-bit).
- `parse_sysinfo_sb`, `sync_to_air` — SB1 / Sync-PDU.
- `parse_mac_pdu`, `_parse_mac_u_signal`, `_parse_mac_resource`, `_parse_channel_allocation`, `_parse_mac_frag_end`, `_parse_mac_broadcast`, `_parse_access_define`, `_parse_sysinfo_type2`, `_length_indicator_meaning` — kompletter MAC-Parser.
- `parse_llc`, `parse_mm_pdu`, `parse_mle`, `parse_direct_mm` — LLC + obere Schichten.
- `load_iq_file` (akzeptiert WAV + raw IQ, auto-detect), `estimate_freq_offset`, `extract_burst_symbols`, `refine_timing`, `decode_dl` — Pipeline.

**TETRA-Konstanten:** SYMBOL_RATE=18000, CHANNEL_BW=25000, DIBIT_TO_DPHASE-Map. STS/NTS1/NTS2-Dibits hartkodiert.
**Burst-Offsets:**
- SDB (continuous): TAIL1=6, PHADJ1=1, FC=40, SB1=60, STS=19, BB=15, BKN2=108, PHADJ2=1, TAIL2=5 = 255.
- NCDB (Normal Continuous): TAIL1=6, PHADJ1=1, BLK1=108, BB1=7, NTS=11, BB2=8, BLK2=108, PHADJ2=1, TAIL2=5 = 255.
- NSB (non-continuous): OFF_SB1=25, OFF_STS=85, OFF_BB=104, OFF_BKN2=119.

**Auffälligkeiten:** Größtes Skript im Repo. Mehrere Roundtrip-Dump-Hooks (`ROUNDTRIP_DUMP_HD`, `_dump_this`) für Bit-Level-Debug. Retry-Loop für NDB2 mit Timing-Jitter + Phase-Rotation. ANSI-color free.

### scripts/decode_ul.py (733 Zeilen)
**Aufgabe:** Decode MS-UL-Random-Access-Bursts aus SDR-WAV. Pipeline: Power-Threshold-Burst-Detect → x-Sequenz-Subsymbol-Refine → Demod 127 Symbole → blk1/blk2 Extraction → Descramble → SCH/HU-Decode.
**CLI-Args:**
- `wav_file` (positional).
- `--cc 49`, `--mcc 901`, `--mnc 9998`.
- `--threshold-db 15.0`.
- `--swap-iq` flag.
- `--max-bursts 50`.
- `--dump-bits` flag.
- `--cfo` (default None).

**Inputs:** WAV-Datei.
**Outputs:** stdout — Pro-Burst CRC-OK/FAIL + MAC-ACCESS-Felder.
**Wichtige Funktionen:** `estimate_freq_offset_dqpsk` (burst-gated Centroid-CFO), `refine_x_position`, `estimate_burst_cfo`, `sample_half_soft_bits`, `try_channel_decode`, `demod_pi4dqpsk_soft_etsi`, `descramble_soft_etsi`, `parse_mac_access`.
**Konstanten:** RA_CB_SYMS=42, RA_X_SYMS=15, X-Dibits aus osmo-tetra.
**Auffälligkeiten:** Importiert breit aus `decode_dl`. CFO-Logik kommentiert für burst-gated FFT-Centroid.

### scripts/decode_ul_raw.py (218 Zeilen)
**Aufgabe:** Decoder für die `raw=` hex-Ausgaben des Board-Daemons `tetra_ul_mon`. Probiert mehrere ETSI §21.4.3.3 Layout-Hypothesen parallel auf die 92-bit MAC-ACCESS-Payload.
**CLI-Args:** `hex` (nargs="*", entweder 23-char hex oder 3 Wörter), `--board` flag, `--last 3`.
**Inputs:** Hex aus stdin/args ODER `tail -F /tmp/tetra_ul_mon.log` per `--board`.
**Outputs:** stdout — pro-Layout-Hypothese: dekodierte Felder.
**Konstanten:** `MLE_PDISC`, `LOC_UPD_TYPE`, `MM_PDU_TYPE_U`, `LLC_PDU_TYPE` als dicts.

### scripts/decode_sb.py (961 Zeilen)
**Aufgabe:** Standalone-Continuous-SB-Decoder. Optimiert für SDR-DL-Captures. Multi-Layout (SDB + NSB), Multi-Try STS-Kandidaten, Multi-Encoder (internal + ETSI).
**CLI-Args:**
- `input` (default `/tmp/tetra_tx_capture.bin`).
- `--sr 2048000`, `--offset 0`, `--freq 440106000`, `--gain 40`, `--duration 2.0`, `--device 0`.
- `--capture` flag.
- `-v`, `--max-tries 5`, `--all-layouts`, `--try-bit-reverse`, `--conjugate`, `--swap-iq`, `--invert-fcs`, `--summary-bursts`.
- `--etsi` flag — schaltet auf ETSI-correct rate-1/4 conv + multiplikativer Deinterleaver.

**Outputs:** stdout — Burst-für-Burst SYSINFO-Decode + CRC-Status.
**Konstanten:** ETSI_G1..G4=0x13,0x1D,0x17,0x1B; internes G1,G2,G3=0x1B,0x19,0x15.
**Auffälligkeiten:** Hat zwei Decoder-Pfade (internal NON-ETSI für Loopback + ETSI für Real-Cell).

### scripts/decode_bnch.py (614 Zeilen)
**Aufgabe:** BNCH (bkn2)-Decoder aus WAV. Pipeline: SDB-Burst → bkn2-Extraction → Descramble → Multiplikativer Deinterleaver → ETSI rate-2/3 RCPC → CRC-16 → SYSINFO/ACCESS_DEFINE-Parse.
**CLI-Args:** `input`, `--sr 2048000`, `--max-bursts 100`, `-v`, `--swap-iq`, `--conjugate`.
**Konstanten:** BNCH_INFO_BITS=124, BNCH_CODED_BITS=216, INTERL_K=216, INTERL_A=101.
**Importiert breit aus `decode_sb`.**
**Wichtige Funktionen:** `demod_pi4dqpsk_soft` lokale Variante mit Amplituden-Gewichtung.

### scripts/wav_to_tkbits.py (441 Zeilen)
**Aufgabe:** Robust WAV→tetra-kit-Bits-Demodulator. Feedforward-STS-Korrelation → Burst-Grid-Walk → Per-burst-Refinement → ZOH-Bit-Output für `tetra-kit/decoder/decoder -i`.
**CLI-Args:**
- `wav` (positional, optional).
- `-o`/`--output`.
- `--udp`, `--udp-port 42000`, `--udp-host 127.0.0.1`.
- `--udp-in`, `--udp-in-port 42000`, `--udp-in-host 0.0.0.0`, `--udp-in-rate 48000`, `--udp-in-fmt int8`, `--udp-in-secs 10.0`.
- `--sr`, `--offset`, `--conjugate`, `--swap-iq`, `--no-fill`, `--max-bursts 100000`.

**Inputs:** WAV-Datei oder Live-UDP-IQ-Stream.
**Outputs:** Bit-File (byte-per-bit) oder UDP-Stream zu tetra-kit-Decoder.
**Konstanten:** TK_SB_STS_SYM=107, TK_NDB_NTS_SYM=122 (Match zu tetra-kit's Burst-Layout).

### scripts/wav_to_dibits.py (113 Zeilen)
**Aufgabe:** WAV → Dibit-Strom für RTL-Simulation. Output als `$readmemh`-lesbares hex-File.
**CLI-Args:** `wav_file`, `--out sim_out/ul_ra_dibits.hex`, `--swap-iq`, `--no-freq-correct`, `--start-sec 0.0`, `--end-sec`.
**Outputs:** Hex-File: 1 Dibit (0..3) pro Zeile.

### scripts/analyze_ila.py (371 Zeilen)
**Aufgabe:** Liest Vivado-ILA-CSV-Exports, prüft AD9361 ADC-Valid, RX-Frontend-Valid, Sync-Found/Locked, DMA-TVALID. Farbiges Terminal-Output.
**CLI-Args:** `--lvds build/ila_lvds_data.csv`, `--sys build/ila_sys_data.csv`, `--freq 430000000`, `--verbose`.
**Outputs:** stdout — `ok`/`warn`/`fail` pro Check, mit Counter-Statistiken (high/low/rising-transitions).
**Auffälligkeiten:** Wird vom `hw_deploy.sh` automatisch nach ILA-Capture aufgerufen.

### scripts/analyze_empty_bits.py (198 Zeilen)
**Aufgabe:** Dumpt die Bits der "empty"-klassifizierten Bursts aus WAV. Vergleicht gegen SDB/NSB/NDB-Formate, sucht Training-Seq-Matches an allen Offsets.
**Inputs:** WAV-Pfad als Arg.
**Outputs:** stdout — Bit-Identität, Burst-by-Burst Korrelations-Werte.
**Auffälligkeiten:** Importiert `_phase_correct` aus `schedule`. Wahrscheinlich Einmal-Forensik-Tool.

### scripts/probe_sb_content.py (138 Zeilen)
**Aufgabe:** Extrahiert stärksten SB1-Burst aus WAV, vergleicht gegen SW-Reference-Encoder für jede (TN,FN,MN)-Kombination, findet minimalen Hamming-Distance-Match.
**Inputs:** WAV-Pfad als Argument.
**Outputs:** stdout — Best-Match.
**Auffälligkeiten:** Importiert `sw_encode_bsch, CFG` aus `verify_sb1_encoder`. Vermutlich Einmal-Forensik-Tool.

### scripts/probe_sb_detail.py (137 Zeilen)
**Aufgabe:** Detailed bit-level mismatch-Map auf stärkstem SB-Burst.
**Inputs:** WAV-Pfad.
**Outputs:** Bit-Diff zwischen on-air und SW-Reference.
**Auffälligkeiten:** Importiert breit aus `verify_sb1_encoder`. Vermutlich Einmal-Forensik-Tool.

### scripts/schedule.py (410 Zeilen)
**Aufgabe:** Tabelliert Burst-Typ pro (FN, TN) aus einer WAV. Klassifikation per STS/NTS1/NTS2-Korrelation, Anker aus BSCH-SYNC-PDU. Kann zusätzlich einen 576-Byte-Schedule-Blob oder C-Header emittieren.
**CLI-Args:** `wav` (optional positional), `-o`/`--csv`, `--emit-blob PATH`, `--emit-c-header PATH`.
**Outputs:** stdout/CSV — pro-Burst Klassifikation + Aggregation pro (FN,TN). Mit `--emit-blob` → 576-Byte Binary, mit `--emit-c-header` → C-Header.
**Wichtige Funktionen:** `_phase_correct` (von anderen Scripts importiert), `analyze`, `gen_schedule_blob`, `gen_schedule_c_header`.

---

## Test-Vector / Verify (Python)

### scripts/check_ul_demod_tv.py (65 Zeilen)
**Aufgabe:** Sanity-Check für `sim_out/ul_demod_iq.hex`. Replays IQ durch Python-Demod, vergleicht (sign-Re, sign-Im) mit erwarteten type-5-Bits aus SCH/HU-Encoder.
**Outputs:** stdout — pro-Burst Mismatch-Counter.
**Notable Constants:** N_BURSTS=4, SYMS_HALF=43, INFO=92.

### scripts/check_ul_wav_hex.py (61 Zeilen)
**Aufgabe:** Round-Trip-Verifikation für `sim_out/ul_wav_iq.hex` durch Python-Demod + SCH/HU-Decoder; CRC-Status pro Burst.
**Konstanten:** PRE_SMP=400, POST_SMP=1200, FULL_SYMS=103, SPS_TB=4, SMP_PER_BURST=2012.

### scripts/check_ul_wav_quant.py (157 Zeilen)
**Aufgabe:** Bit-exakte RTL-Emulation der UL-Demod-Quantisierung (3-bit) + Viterbi K=5 r=1/4.
**Wichtige Funktionen:** `to_vit_soft_rtl` (replicates RTL `diff = 4 - s` clamp), `viterbi_rtl_emu`.
**Auffälligkeiten:** Genaue Replikation der RTL-Implementation für Bit-genaue Verifikation.

### scripts/check_ul_wav_rtl_emu.py (94 Zeilen)
**Aufgabe:** Emuliert RTL's `tetra_ul_pi4dqpsk_demod`-MSB-Slice-Soft-Output (±20 Range) auf WAV-IQ-Hex, prüft ob Quantization allein CRC verliert oder Sign/Mapping-Bug.
**Wichtige Funktionen:** `rtl_demod` (Re/Im signed-arithmetic-Right-Shift 25).

### scripts/gen_aach_reference.py (188 Zeilen)
**Aufgabe:** Python-Reference-Model des TETRA-AACH-Encoders. Reproduziert SW-Pfad aus `sw/tetra_hal.c` (`build_aach_capaloc` / `build_aach` + `aach_scramble`).
**CLI-Args:** `-o <file.memh>`.
**Outputs:** 4 30-bit Codewörter (TC1..TC4), pro Zeile hex.
**Test Cases:** TC1=F1 cc=9 mcc=901 mnc=9998, TC2=F18 cc=9, TC3=F1 cc=36 mcc=262 mnc=106, TC4=F18 cc=36.
**Auffälligkeiten:** RM(30,14) Generator-Matrix aus `sw/tetra_hal.c` kopiert.

### scripts/gen_d_nwrk_broadcast.py (183 Zeilen)
**Aufgabe:** Generiert statisches D-NWRK-BROADCAST-PDU (432-bit type-5 Pattern) für FPGA-ROM. Quelle: Cell Burst #423 (MN=44 FN=04 TN=1).
**CLI-Args:** `--cc 49`, `--mcc 901`, `--mnc 9998`, `-o`/`--output`.
**Outputs:** Verilog-Hex-Konstante (432-bit) für ROM, optional.memh.
**Pipeline:** 124-bit info → CRC-16 → 140 → +tail → 144 → rate-1/2 conv K=5 → 288 → matrix interleave a=11 → scramble → split 2×144.

### scripts/gen_sch_f_tv.py (99 Zeilen)
**Aufgabe:** SCH/F (268→432)-Testvektoren für `tb_sch_f_encoder`.
**Wichtige Funktionen:** `interleave_sch_f` (N=432, a=103). Importiert primitives aus `verify_sb1_encoder`.

### scripts/gen_sch_hd_tv.py (94 Zeilen)
**Aufgabe:** SCH/HD (124→216)-Testvektoren für `tb_sch_hd_encoder`. Interleaver N=216, a=101.

### scripts/gen_sch_hu_tv.py (159 Zeilen)
**Aufgabe:** Clean SCH/HU-Testvektoren für `tb_ul_sch_hu_decoder`. Soft = +127 für bit=0, -127 für bit=1.
**Outputs:** `sim_out/ul_sch_hu_soft.hex` (N_BURSTS*168 signed 8-bit), `sim_out/ul_sch_hu_exp.hex` (13 bytes per burst).
**Konstanten:** K=168, A=13, INFO=92, CRC_LEN=108, TAIL=4, MOTHER=448, SPS=112.

### scripts/gen_ul_demod_tv.py (208 Zeilen)
**Aufgabe:** Generiert IQ-Testvektoren für UL-Integration-TBs (`tb_ul_demod_sch_hu` + `tb_ul_full_chain`).
**Outputs:**
- `sim_out/ul_demod_iq.hex` (86 syms × 2 hex Zeilen pro Burst — symbol-rate IQ).
- `sim_out/ul_full_iq.hex` (103 syms × 4 sps + 400 pre + 1200 post = 2012 samples).
- `sim_out/ul_demod_exp.hex` (13 bytes/burst).
**Konstanten:** AMPLITUDE=30000, SPS=4, FULL_SYMS=103, FULL_PRE_SMP=400, FULL_POST_SMP=1200.

### scripts/gen_ul_mac_exp.py (73 Zeilen)
**Aufgabe:** Produziert `sim_out/ul_mac_access_exp.hex` für `tb_ul_mac_access_parser`. Liest `ul_wav_exp.hex` records, packt parsed MAC-Felder in 32-bit Wort.
**Layout:** `[31:30]=pdu_type`, `[29]=fill_bit`, `[28:27]=encryption_mode`, `[26]=access_ack`, `[25:23]=address_type`, `[22:13]=short_ssi(10b)`, `[12:0]=reserved`.

### scripts/gen_ul_wav_iq_stim.py (197 Zeilen)
**Aufgabe:** Real-WAV UL-Stimulus für `tb_ul_wav_chain`. Lädt WAV → CFO → RRC → Decimate → Burst-Detect → Per-burst CFO → Symbol-Sample → ZOH × 4 sps + Pre/Post-Silence.
**CLI-Args:** `wav_file`, `--cc 49`, `--mcc 901`, `--mnc 9998`, `--out-dir sim_out`, `--n-bursts 8`, `--threshold-db 15.0`, `--swap-iq`.
**Outputs:** `sim_out/ul_wav_iq.hex` (N × 2012 samples × 2 hex), `sim_out/ul_wav_exp.hex` (13 bytes/burst).
**Konstanten:** FULL_SYMS=103, FULL_PRE_SMP=400, FULL_POST_SMP=1200, FULL_SMP_PER_BURST=2012, AMPLITUDE=30000.

### scripts/verify_empty_content.py (208 Zeilen)
**Aufgabe:** Charakterisiert "empty"-klassifizierte Bursts aus WAV. Korrelations-Histogramme, Autokorrelations-Peaks, Power-Envelope pro Symbol.
**Inputs:** WAV-Pfad.
**Auffälligkeiten:** Forensik-Tool aus dem Cell-Schedule-Reverse-Engineering. **Vermutlich obsolet** (Mission erledigt — siehe `removed-memory` Memory).

### scripts/verify_empty_power.py (170 Zeilen)
**Aufgabe:** Prüft RMS(|IQ|) der "empty"-Bursts vs SB/NDB1/NDB2. Aggregation pro Burst-Klasse, Ratio empty/SB.
**Auffälligkeiten:** Wie `verify_empty_content.py` — Forensik-Tool. **Vermutlich obsolet**.

### scripts/verify_empty_sweep.py (202 Zeilen)
**Aufgabe:** Sucht in "empty"-Bursts versteckte Training-Sequenz-Position+Länge. Differential-Mean-Symbol-Vektor über 300 Bursts, Peak-Detection.
**Auffälligkeiten:** **Vermutlich obsolet** (Forensik).

### scripts/verify_sb1_encoder.py (255 Zeilen)
**Aufgabe:** SW-Reference-Encoder für BSCH (SB1). Vergleicht SW-Pfad gegen RTL-Algorithmus. Mehrere primitive helper-Funktionen (`crc16`, `conv_encode_r14`, `puncture_r23`, `scramble_bsch`, `interleave_bsch`, `build_pdu`).
**CFG (hartkodiert aus laufendem tetra_sysinfo):** mcc=901, mnc=9998, colour_code=49, system_code=2, frame_18_ext=1, ncb=3, late_entry=1.
**Auffälligkeiten:** Wird aus mehreren `probe_sb_*.py` + `verify_sch_f_roundtrip.py` als helper-Library importiert.

### scripts/verify_sch_f_roundtrip.py (119 Zeilen)
**Aufgabe:** Phase-1-Encoder-Round-Trip. WAV laden + -Burst #423 (D-NWRK-BROADCAST, NDB1, TN=1 FN=04 MN=44) finden → soft-decode info → re-encode via `gen_sch_f_tv::encode_sch_f` → Bit-für-Bit-Vergleich gegen on-air.
**Auffälligkeiten:** Verifikation für SCH/F-Path. **Vermutlich obsolet** (Mission erledigt — siehe Memory).

### scripts/verify_sch_hu_decode.py (188 Zeilen)
**Aufgabe:** Step-by-step Cross-Check des SCH/HU-Decode-Path. Drei Decoder parallel: canonical, RTL-mirror, RTL-style CRC16.
**Konstanten:** K=168, A=13, INFO=92, SCRAMB_INIT=0xE1670EC7.

### scripts/verify_training_seq.py (142 Zeilen)
**Aufgabe:** Cross-Check Trainings-Sequenz-Dibits zwischen Python-Testvektor-Definitionen (`gen_sync_detect_vectors.py`) und RTL-Konstanten (`tetra_sync_detect.v`).
**Auffälligkeiten:** Importiert aus `tb/vectors/gen_sync_detect_vectors.py`. Sanity-Check, kein Live-Tool.

### scripts/verify_ts_manual.py (99 Zeilen)
**Aufgabe:** Manual-Verifikation der Trainings-Sequenzen RTL-vs-Python. NTS RTL oldest-first hardcoded.
**Auffälligkeiten:** Sehr kurzes inspection-Skript, kein argparse. **Vermutlich obsolet** (Einmal-Sanity-Check, Aufgabe erledigt).

### scripts/verify_ul_ra_burst.py (225 Zeilen)
**Aufgabe:** Validiert dass MS-UL-RA-Bursts die ETSI §9.4.4.3.3 x-Trainings-Sequenz (30 bits / 15 Symbole) enthalten.
**CLI-Args:** `wav_file`, `--threshold-db 15.0`, weitere.
**Wichtige Konstanten:** `X_BITS`, `X_DIBITS`, `X_DIFF_REF` (von `gen_ul_wav_iq_stim.py` importiert).
**Auffälligkeiten:** Aktive Funktion `find_bursts` wird von anderen Scripts mitgenutzt.

### scripts/sim_loopback.py (679 Zeilen)
**Aufgabe:** Bit-accurate Python-Simulation des TETRA-digital-loopback-Pfads. Modelliert: pi4dqpsk_mod → TX_RRC → TX_CIC(×64) → RX_CIC(÷64) → RX_RRC → TR → demod → STS-Korrelation.
**Konstanten:** IQ_WIDTH=16, RRC_H als Q14 hartkodiert (33-tap Filter), RRC_ACC_SHIFT=14, STS_DIBITS.
**Auffälligkeiten:** Vermutlich Einmal-Tool für 50%-STS-Korrelations-Bug-Investigation aus 2026-04. **Vermutlich obsolet** (Bug gefixt).

### scripts/fix_tx_instantiation.py (147 Zeilen)
**Aufgabe:** Einmal-Skript für automatisches Pattern-Replace der TX-Chain-Instantiation in `rtl/tetra_zynq_top.v`. Aus Datum/Autor-Kommentar 2026-04-08 von "Ralph (autonomous agent)".
**Auffälligkeiten:** **Sicher obsolet** — Einmal-Refactor-Helper für RTL-Edit, Aufgabe schon längst erledigt; sollte normalerweise nicht im Repo bleiben.
