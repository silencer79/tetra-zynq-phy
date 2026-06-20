# IST 00 — tetra_zynq_top Übersicht
Stand: 2026-06-20 (Instanz-/Wire-Inventar reviewed)

Quelle: `rtl/tetra_zynq_top.v` (**4419 Zeilen**, war 3949 beim letzten
Voll-Review). Top-Level der PL-Logik, vom BD über `tetra_system_wrapper`
(siehe `rtl/tetra_system_top.v`, Sim-Top — NICHT Synth-Top) instanziiert.

> **Zeilennummern-Caveat:** Die `Zeile`-Spalten unten sind 2026-05-17-Baseline;
> die Datei ist seither um ~470 Zeilen gewachsen → Nummern verschoben
> (Instanz-Namen + Zweck stimmen weiter). Neu seit dem Review:
> `u_ul_schf_reassembly` (~Z. 830, generische UL-Multi-Fragment-Reassembly).

## Inhalt

- [Top-Ports](#top-ports)
- [Submodul-Instanzen](#submodul-instanzen)
- [Wichtige Top-Wires](#wichtige-top-wires)
- [Datenpfad RX](#datenpfad-rx)
- [Datenpfad TX](#datenpfad-tx)
- [TDMA-Timebase und Symbol-Tick](#tdma-timebase-und-symbol-tick)
- [DL-Signal-Queue und Scheduler](#dl-signal-queue-und-scheduler)
- [AACH-Encoder mit Z.13 Slot-Side Select](#aach-encoder-mit-z13-slot-side-select)
- [Phase Y.4 Voice-Pfad](#phase-y4-voice-pfad)
- [CDC-Brücken](#cdc-brücken)
- [Tote / Inaktive Pfade](#tote--inaktive-pfade)

## Top-Ports

Header Z. 69–182. Parameter: `IQ_WIDTH=16`, `BLOCK_BITS=216`, `BB_BITS=30`, `CORR_WIDTH=24`.

- **Clock + Reset:** `i_clk` (100 MHz), `i_arst_n` (active-low)
- **AD9361 Fabric-Interface (`l_clk` Domain):**
 - `l_clk`, `adc_valid_i0`, `adc_data_i0[15:0]`, `adc_enable_i0`,
 `adc_valid_q0`, `adc_data_q0[15:0]`, `adc_enable_q0`, `adc_r1_mode`
 - `adc_dovf` (out → 0), `dac_dunf` (out → 0)
 - `dac_valid_i0`, `dac_enable_i0`, `dac_valid_q0`, `dac_enable_q0`, `dac_r1_mode`
 - `dac_data_i0[15:0]`, `dac_data_q0[15:0]`
- **AXI4-Lite Slave (`s_axi_aclk`):** Volle AW/W/B/AR/R-Channels mit AWPROT/ARPROT.
- **AXI4-Stream Master (S2MM):** `m_axis_tvalid/tready/tdata[31:0]/tkeep[3:0]/tlast`
- **IRQ:** `o_irq`

## Submodul-Instanzen (mit Zeilennummer)

In Reihenfolge des Auftauchens in `tetra_zynq_top.v`:

| Zeile | Instanz | Modul | Zweck |
|-------|-----------------------------|--------------------------------------|----------------------------------------------------------|
| 203 | `u_clk_reset` | `tetra_clk_reset` | Reset-Synchronizer für 4 Domains |
| 298 | `u_ad9361_adapter` | `tetra_ad9361_axis_adapter` | AD9361 Fabric ↔ tetra RX/TX-Bus |
| 542 | `u_rx_chain` | `tetra_rx_chain` | RX-Pipeline (Frontend, Demod, Sync, TDMA, UL-Decoder) |
| 691 | `u_ul_demand_reassembly` | `tetra_ul_demand_reassembly` | Phase 7 F.1 — UL MAC-ACCESS Frag-1+Frag-2 Reassembly |
| 755 | `u_ul_demand_ie_parser` | `tetra_ul_demand_ie_parser` | Phase 7 F.2 — IE-Walker mm=2 + mm=7 (SW-abgelöst durch `tetra_mm_demand_parser.c`, RTL-Output A/B-Legacy) |
| ~830 | `u_ul_schf_reassembly` | `tetra_ul_schf_reassembly` | **Neu** — generische UL-Multi-Fragment-Reassembly (lange SDS / mm=7-Multi-Frag) → LSDS-Mailbox → SW |
| 843 | `u_lmac` | `tetra_lmac` | LMAC RX/TX Channel-Coding-Wrapper (TX-Pfad tot) |
| 972 | `u_dma_bridge` | `tetra_axi_dma_bridge` | S2MM-Bridge LMAC → AXI4-Stream → PS |
| 1226 | `u_slot_content_mux` | `tetra_slot_content_mux` | Phase Y.3 stripped — BRAM-Prefetch FSM für Schedule |
| 1246 | `u_burst_dispatcher` | `tetra_burst_dispatcher` | Phase Y.3 — Single-Stage Mux+Flop für Burst-Body |
| 1308 | `u_tx_chain` | `tetra_tx_chain` | TX-Pipeline (Builder, π/4-DQPSK, RRC, CIC) |
| 1841 | `u_tx_tdma_timebase` | `tetra_tdma_timebase` | Kanonischer 0-based TDMA-Counter (TN/FN/MN/HN) |
| 1921 | `u_axi_regs` | `tetra_axi_lite_regs` | AXI4-Lite Register-Bank |
| 2239 | `u_mle_registration_fsm` | `tetra_mle_registration_fsm` | MLE-Attach-FSM, baut D-LOC-UPDATE-ACCEPT |
| 2378 | `u_dl_signal_queue` | `tetra_dl_signal_queue` | 4-Entry Strict-Priority Queue (MLE/CMCE/SDS) |
| 2441 | `u_dl_signal_scheduler` | `tetra_dl_signal_scheduler` | Pop pro Frame, Per-TN Bundle für Slot-Mux |
| 2684 | `u_dl_nwrk_broadcast` | `tetra_dl_nwrk_broadcast` | Phase H.7 — D-NWRK-BCAST Auto-Fire FSM |
| 2727 | `u_pre_reply_blck` | `tetra_pre_reply_blck` | Phase X.5 — BL-ACK nach Frag-2-Reassembly |
| 2796 | `u_pre_reply_slotgrant` | `tetra_pre_reply_slotgrant` | Phase X.5b — Slot-Grant AL-SETUP nach Frag-1 |
| 2840 | `u_dl_pdu_builder` | `tetra_dl_pdu_builder` | Shared SCH/F-Encoder für MLE Final-ACCEPT |
| 2983 | `u_demand_mailbox` | `tetra_demand_mailbox` | mm=2 UL-Demand Snapshot (Phase X.1) |
| 3162 | `u_reply_mailbox` | `tetra_reply_mailbox` | SW-pulled Reply (Phase X.2) |
| 3277 | `u_grp_demand_mailbox` | `tetra_grp_demand_mailbox` | mm=7 Group-Attach Demand (Phase Y.1.b) |
| 3337 | `u_voice_filler_mailbox` | `tetra_voice_filler_mailbox` | Phase 7 G.8 — DL voice-slot SCH/F filler-Mailbox (16 × 32-bit, indirect; gated mit voice_active_mask im burst_dispatcher) |
| 3364 | `u_tx_slot_schedule` | `tetra_slot_schedule` | Dual-Port BRAM für Schedule (Port A=AXI, Port B=clk_sys) |
| 3429 | `u_voice_nub_read_mailbox` | `tetra_voice_nub_read_mailbox` | Phase C — UL NUB type-5 bits buffer für SW-poll (single-entry) |
| 3642 | `u_sb1_encoder` | `tetra_sb1_encoder` | BSCH (SB1) Encoder, 120-bit coded |

> **Hinweis 2026-05-17:** Die Y.4.2/Y.4.3 voice-capture-Hacks (`tetra_ul_voice_capture.v`, CMCE-port-Mux in zynq_top, Y.4.2 UL-demod-Outputs in `rx_chain`) sind in Phase A.1 Rollback **entfernt**. Aktueller Voice-Pfad ist Phase C: `tetra_ul_nub_capture` (in `rx_chain`, NICHT in zynq_top instanziiert) → `tetra_voice_nub_read_mailbox` → SW (`sw/tetra_voice_pipe.c`) → `tetra_voice_filler_mailbox` → `tetra_burst_dispatcher` voice-gate. Siehe Ch 4, Ch 9.
| 3752 | `u_aach_rm_slot` | `tetra_aach_rm_encoder` | Combinational AACH-RM-Encoder für Queue-Head |
| 3760 | `u_aach_encoder` | `tetra_aach_encoder` | Default-Logic AACH-Encoder (Idle/F18/Grant/Voice) |

## Wichtige Top-Wires

### Clocks und Resets
```
clk_sys = i_clk (100 MHz, Z. 190)
clk_lvds ← u_ad9361_adapter.clk_lvds (= l_clk)
rst_n_sys/_lvds/_axi ← u_clk_reset
```

### TDMA-Timebase (clk_sys, Outputs der Z. 1841 Instanz)
```
tx_tdma_state_tn_sys[1:0] — air-TN 0..3
tx_tdma_state_fn_sys[4:0] — air-FN 0..17
tx_tdma_state_mn_sys[5:0] — air-MN 0..59
tx_tdma_state_hn_sys[5:0] — air-HN 0..63
tx_tdma_state_sym_cnt_sys[7:0] — Symbol 0..254 innerhalb Slot
tx_tdma_state_slot_pulse_sys — 1-Cycle Puls pro Slot-Grenze
tx_tdma_state_tdma_tick_sys — 1-Cycle Puls pro Symbol
```

### Legacy free-running TDMA-Counter (clk_sys, Z. 1068–1104)
```
tx_sym_cnt_sys[7:0] — 0..254 Symbole/Slot
tx_slot_cnt_sys[1:0] — Slot 0..3 (1-based bei Vergleich mit ETSI? Nein, 0-based hier)
tx_frame_cnt_sys[4:0] — 1..18 (ETSI 1-based!)
tx_mf_cnt_sys[5:0] — 1..60 (ETSI 1-based!)
tx_slot_pulse_free_sys — 1-Cycle Puls auf Slot-Grenze (Free-Running)
```
**Auffällig:** Die Legacy-Counter (1-based) leben parallel zu den 0-based
timebase-Outputs. AXI `REG_TX_TDMA` (0x38) liest die LEGACY-Counter,
`REG_TX_TDMA_STATE` (0x144) die 0-based timebase.

### Symbol-Tick
```
sym_div_lvds[9:0] — clk_lvds 10-bit Zähler ÷1024 (= 18 kHz Toggle)
sym_toggle_lvds — Toggle-Signal in clk_lvds
sym_en_sys_w — 1-Cycle Puls in clk_sys (Edge-Detect nach 2-FF Resync)
```
Feeds `tetra_tdma_timebase.sym_en` + `tetra_tx_chain.sym_en_ext_sys` + Legacy-Counter.

### MLE/Reply Mailbox Field-Outputs (clk_sys, vom u_reply_mailbox @ Z. 3162)
```
mb_ssi_sys_w[23:0], mb_la_sys_w[13:0], mb_addr_type_sys_w[2:0], mb_result_sys_w[1:0],
mb_gila_gssi_sys_w[23:0], mb_gila_class_sys_w[2:0], mb_gila_lifetime_sys_w[1:0],
mb_gila_present_sys_w, mb_encryption_sys_w[1:0], mb_auth_result_sys_w[1:0],
mb_go_pulse_sys_w,
mb_raw_mode_flag_sys_w, mb_raw_mm_bits_sys_w[127:0], mb_raw_mm_len_sys_w[7:0],
mb_raw_ns_sys_w, mb_raw_nr_sys_w, mb_raw_mle_pd_sys_w[2:0]
```

### MLE FSM → Queue Producer-Slot
```
mle_req_valid_w, mle_req_coded_bits_w[431:0], mle_req_pdu_type_w[1:0],
mle_req_target_tn_w[1:0], mle_busy_w, mle_accept_pulse_w, mle_drop_pulse_w,
mle_ack_pulse_w, mle_retransmit_pulse_w, mle_lost_pulse_w, mle_detach_pulse_w,
mle_req_second_pdu_present_w, mle_req_second_pdu_nr_w,
mle_accept_build_*_w (Phase X.6 SCH/F-Builder-Request-Bus)
```

### Queue Head (vom u_dl_signal_queue @ Z. 2378)
```
queue_head_valid_w, queue_head_coded_w[431:0], queue_head_pdu_type_w[1:0],
queue_head_target_tn_w[1:0], queue_head_prio_w[1:0], queue_head_aach_pattern_w[13:0],
queue_head_second_pdu_present_w, queue_head_second_pdu_nr_w
```

### Scheduler Per-TN Bundle (vom u_dl_signal_scheduler @ Z. 2441)
```
sched_blk1_tn0_sys_w..tn3_sys_w[215:0] — 8 Bus à 216 bit
sched_blk2_tn0_sys_w..tn3_sys_w[215:0]
sched_ndb2_sys_w[3:0], sched_active_sys_w[3:0]
sig_pop_cnt_w[15:0], sig_override_cnt_w[15:0]
```

### Burst-Dispatcher Outputs (vom u_burst_dispatcher @ Z. 1246)
```
disp_block1_sys_w[215:0], disp_block2_sys_w[215:0]
disp_bb_sys_w[29:0], disp_sb1_sys_w[119:0]
disp_burst_type_sys_w, disp_ndb2_sys_w, disp_build_req_sys_w, disp_tx_busy_sys_w
```

### Schedule-BRAM Wires
```
schedule_axi_we_w, schedule_axi_re_w, schedule_axi_addr_w[7:0],
schedule_axi_wdata_w[31:0], schedule_axi_wstrb_w[3:0], schedule_axi_rdata_w[31:0]
schedule_entry_sys_w[15:0] — Port-B Output (Sync-Read)
sched_b_addr_sys_w[8:0] — Port-B Adresse vom Slot-Content-Mux
sched_entry_reg_sys0..3_w[15:0] — Latched Schedule-Entries pro TN
```

### CMCE-Queue Producer (Voice + NWRK-BCAST gemuxt, Z. 2367–2376)
```
cmce_port_wr_valid_w, cmce_port_wr_coded_w[431:0],
cmce_port_wr_pdu_type_w[1:0], cmce_port_wr_target_tn_w[1:0],
cmce_port_wr_aach_pattern_w[13:0]
```
Voice gewinnt auf gleichzeitigen Push (Voice-Burst alle ~56 ms,
NWRK-BCAST alle 10 s).

### AACH Slot-Side Output
```
aach_coded_sys_w[29:0] — vom Default u_aach_encoder
aach_coded_slot_sys_w[29:0] — Final-Select: head_match_aach ? head_aach_coded_sys_w: aach_coded_sys_w
head_match_aach_sys — Match Queue-Head-TN gegen tx_tdma_state_tn_sys ODER tx_tn_next_sys
head_aach_coded_sys_w[29:0] — vom u_aach_rm_slot (combinational RM(30,14))
aach_lfsr_init_sys_w[31:0] — Shared Scrambler-Init {MCC, MNC, CC, 2'b11}
```

### Voice-Burst Wires (Phase C + Phase 7 G.8, Stand 2026-05-17)

Die Y.4.2-Wires (`ul_demod_dibit_sys_w`, `voice_burst_*`) sind in A.1
Rollback entfernt. Aktueller Voice-Pfad:

```
voice_active_mask_sys_r1[3:0]  — CDC vom AXI 0x1EC; gated burst_dispatcher voice-slot
voice_nub_sync_thresh_sys      — CDC vom AXI 0x268; ans 2. ul_sync_detect_os4 (NUB)

UL-Pfad (in rx_chain):
  u_ul_sync_detect_os4 (NUB instance) → sync_found_sys
  → u_ul_nub_capture (NTS1-aligned BKN1+BKN2 demod)
  → voice_nub_read_mailbox (single-entry buffer, AXI 0x280..0x28C)

DL-Pfad (in zynq_top):
  voice_filler_mailbox (16-word indirect, AXI 0x270..0x27C)
  → vfill_blk1/2_sys, vfill_valid_sys → burst_dispatcher
  → burst_dispatcher overridet sched/static-Pfad falls
    voice_active_mask[tn] & vfill_valid (Phase 7 G.8)
```

### MAC-Resource SchedHD-Pre-Reply Wires
```
slotgrant_valid_sys_w, slotgrant_coded_sys_w[431:0]
slotgrant_pdu_type_sys_w[1:0], slotgrant_target_tn_sys_w[1:0]
slotgrant_push_cnt_sys_w[15:0], slotgrant_drop_cnt_sys_w[15:0]

pre_reply_blck_valid_sys_w, pre_reply_blck_coded_sys_w[431:0]
pre_reply_blck_pdu_type_sys_w[1:0], pre_reply_blck_target_tn_sys_w[1:0]
pre_reply_blck_push_cnt_sys_w[15:0], pre_reply_blck_drop_cnt_sys_w[15:0]
```

### MLE-FSM ↔ Shared Builder
```
dl_pdu_done_w, dl_pdu_coded_w[431:0], dl_pdu_busy_w
dl_pdu_grant_mle_w = mle_accept_build_req_w & ~dl_pdu_busy_w
dl_pdu_done_to_mle_w = dl_pdu_done_w (Phase Y.2: single producer)
```

### MLE-Producer-Slot Mux (Z. 2865–2888)
```
mle_slot_wr_valid_w = mle_req_valid_w | slotgrant_valid_sys_w
mle_slot_wr_coded_w = mle_req_valid_w ? mle_req_coded_bits_w: slotgrant_coded_sys_w
mle_slot_wr_pdu_type_w = mle_req_valid_w ? mle_req_pdu_type_w: slotgrant_pdu_type_sys_w
mle_slot_wr_target_tn_w = mle_req_valid_w ? mle_req_target_tn_w: slotgrant_target_tn_sys_w
mle_slot_wr_second_pdu_present_w = mle_req_valid_w ? mle_req_second_pdu_present_w: 1'b0
mle_slot_wr_second_pdu_nr_w = mle_req_valid_w ? mle_req_second_pdu_nr_w: 1'b0
mle_slot_wr_aach_pattern_w = mle_req_valid_w ? mle_accept_build_aach_pattern_w
: `PDUC_PRE_REPLY_SLOTGRANT_AACH
```

### IE-Parser → Demand-Mailbox Composition (Z. 800–809)
```
mle_demand_parsed_valid_sys = iep_parse_done_sys & iep_parse_ok_sys & (reass_mm_type_sys == 4'd2)
mle_demand_pdu_ssi_sys = iep_pdu_ssi_sys
mle_demand_gssi_count_sys = iep_gild_valid_sys ? 3'd1: 3'd0
mle_demand_gssi_array_sys = {48'd0, iep_gild_gssi_sys}
mle_demand_class_array_sys = {6'd0, iep_gild_class_sys}

grp_demand_parsed_valid_sys = iep_parse_done_sys & iep_parse_ok_sys & (reass_mm_type_sys == 4'd7)
```

### Cell-Config CDC-Outputs (clk_sys)
```
cell_cfg_sys_code_sys_r1[3:0] ← CELL_CFG_0[3:0]
cell_cfg_sharing_mode_sys_r1[1:0] ← CELL_CFG_0[5:4]
cell_cfg_ts_reserved_frames_sys_r1[2:0] ← CELL_CFG_0[8:6]
cell_cfg_uplane_dtx_sys_r1 ← CELL_CFG_0[9]
cell_cfg_frame18_ext_sys_r1 ← CELL_CFG_0[10]
cell_cfg_neigh_cell_bc_sys_r1[1:0]← CELL_CFG_0[12:11]
cell_cfg_cell_service_level_sys_r1[1:0] ← CELL_CFG_0[14:13]
cell_cfg_late_entry_support_sys_r1 ← CELL_CFG_0[15]
cell_cfg_mcc_sys_r1[9:0] ← CELL_CFG_1[9:0]
cell_cfg_mnc_sys_r1[13:0] ← CELL_CFG_1[23:10]
colour_code_sys_r1[5:0] ← COLOUR_CODE
cfg_mcch_tn_sys_r1[1:0] ← SIGNAL_TARGET_TN
cell_la_sys_r1[13:0] ← CELL_LA
db_policy_accept_unknown_sys_r1 ← DB_POLICY[0]
voice_active_mask_sys_r1[3:0] ← VOICE_ACTIVE_MASK[3:0]
aach_grant_info_sys_r1[13:0] ← AACH_GRANT_HINT[13:0]
aach_grant_pending_sys_r1 ← AACH_GRANT_HINT[31]
reass_t0_frames_axi_sys[3:0] ← REASSEMBLY_T0[3:0]
ul_scramb_init_sys[31:0] ← UL_SCRAMB_INIT
nwrk_bcast_period_mf_sys_r1[4:0] ← NWRK_BCAST_PERIOD_MF[4:0]
nwrk_bcast_payload_sys_r1[431:0] ← REG_NWRK_BCAST_DATA Storage
nwrk_bcast_trigger_sys_r1 ← REG_NWRK_BCAST_TRIGGER
```

### Lookahead-TN/FN/MN (Z. 3622–3632)
```
tx_tn_wrap_sys = (tx_tdma_state_tn_sys == 3)
tx_fn_wrap_sys = tn_wrap && (fn == 17)
tx_mn_wrap_sys = fn_wrap && (mn == 59)
tx_tn_next_sys = tn_wrap ? 0: (tn + 1)
tx_fn_next_sys = tn_wrap ? (fn_wrap ? 0: fn+1): fn
tx_mn_next_sys = fn_wrap ? (mn_wrap ? 0: mn+1): mn
```

## Datenpfad RX

```
axi_ad9361 IP → l_clk-Bus → u_ad9361_adapter (Z. 298)
 → rx_i/q_adc_lvds → Loopback-Mux (Z. 336) → rx_i/q_lvds
 → u_rx_chain (Z. 542) [Frontend, Demod, Sync, Burst-Demux, Frame-Counter]
 → rx_block1/2_sys, rx_bb_sys, rx_slot_valid_sys, rx_slot_num_sys, rx_burst_type_sys
 → u_lmac (Z. 843) [Descramble, Deinterleave, Depuncture, Viterbi, CRC, RM-Decode]
 → lmac_decoded_bit_sys/valid_sys/block_done_sys
 → Accumulator (Z. 901–922, 216-bit Shift+Latch)
 → u_dma_bridge (Z. 972) → m_axis_* zum Zynq AXI-DMA IP
```

UL-Pfad innerhalb `u_rx_chain` zusätzlich:
- `ul_pdu_valid_sys` + alle MAC-ACCESS-Felder
- `ul_continuation_*_sys` (MAC-END-HU)
- `ul_demod_dibit_sys/valid_sys` (Phase Y.4.2 für Voice)
- `ul_bl_ack_valid_sys` (M1+M4 BL-ACK Detection)
- `ul_llc_*` Felder (LLC-Walker Outputs)

## Datenpfad TX

```
u_dl_signal_queue.head_* ─┬─▶ u_dl_signal_scheduler.head_*_sys
 │ ▼
 │ sched_blk1/2_tnX_sys (Per-TN combinational fan-out)
 ▼ ▼
 u_burst_dispatcher (Z. 1246)
 (1-cycle Mux+Flop bei tx_slot_pulse_sys)
 ▼
 disp_block1/2/bb/sb1_sys + burst_type/ndb2/build_req
 ▼
 u_tx_chain (Z. 1308)
 ├ burst_builder (assembled 510-sym Burst)
 ├ pi4dqpsk_mod
 ├ rrc_filter
 ├ tx_frontend (CIC interp)
 ▼
 tx_i/q_lvds → u_ad9361_adapter → DAC-Bus → axi_ad9361 IP
```

Eingaben in den Dispatcher (Z. 1246–1294):
- Scheduler-Fanout: `sched_blk1/2_tn0..3_sys`, `sched_active_sys`, `sched_ndb2_sys`
- Schedule-Entry-Latches: `sched_entry_reg_sys0..3` (vom `u_slot_content_mux` BRAM-Prefetch)
- SW-Banks: `ndb_block1/2_data_sys`, `mcch_block1/2_data_sys`, `bnch_block1/2_data_sys`, `sb_bkn2_data_sys`
- Pre-coded: `aach_coded_slot_sys_w` (AACH, slot-side select), `sb1_coded_sys_w` (BSCH)

## TDMA-Timebase und Symbol-Tick

`u_tx_tdma_timebase` (`tetra_tdma_timebase`, Z. 1841) ist die kanonische
0-based Quelle für `tn/fn/mn/hn/sym_cnt/slot_pulse/tdma_tick`. Eingänge:
- `sym_en` = `sym_en_sys_w` (1-Cycle pulse @18 kHz aus clk_lvds-Divider)
- `sync_load_strobe` = `tx_tdma_sync_load_strobe_sys` (1-Cycle, Edge-Detect aus AXI W1S)
- `sync_tn/fn/mn/hn_in` aus AXI REG_TX_TDMA_LOAD (clk_axi, von Slave gelatcht)

Outputs werden direkt von Slot-Content-Mux, Burst-Dispatcher, AACH-Encoder,
SB1-Encoder, MLE-FSM (slot_pulse) und allen Mailbox-Demand-Triggern konsumiert.

Parallel laufen die LEGACY 1-based Counter `tx_sym_cnt_sys/tx_slot_cnt_sys/
tx_frame_cnt_sys/tx_mf_cnt_sys` (Z. 1068–1104). Diese werden NUR noch für
AXI-Status-Read `REG_TX_TDMA` (0x38) verwendet — der Datenpfad nutzt die
0-based timebase.

`mf_pulse_sys` (Z. 2138) = Multiframe-Edge-Detect auf `tx_mf_cnt_sys`-Vergleich.
Geht in `u_dl_nwrk_broadcast` als Auto-Fire-Clock.

## DL-Signal-Queue und Scheduler

`u_dl_signal_queue` (Z. 2378, `DEPTH=4`):
- **MLE Producer-Port** (Strict-Priority höchste): `mle_slot_wr_*` Mux aus MLE-FSM
 Final-ACCEPT und SlotGrant Pre-Reply.
- **CMCE Producer-Port**: gemuxt aus Voice-Burst-Forward und D-NWRK-BCAST
 (`cmce_port_wr_*`, Voice gewinnt).
- **SDS Producer-Port**: Pre-Reply BL-ACK (`pre_reply_blck_valid_sys_w`),
 AACH hardwired auf `PDUC_BL_ACK_POST_FRAG2_AACH` (=0x0249 idle).
- **Consumer (Pop)**: `u_dl_signal_scheduler.sched_pop_w`.

Stats werden CDC'd nach clk_axi und in REG_DL_QUEUE_STATS / REG_SLOTGRANT_STATS /
REG_PRE_REPLY_BLCK_STATS / REG_DL_SCHEDULER_STATS exportiert.

`u_dl_signal_scheduler` (Z. 2441): Pop bei `slot_pulse@target_tn` (nicht
unbedingt tn==3 — Phase Z.13). Fans out kombinatorisch: wenn
`queue_head_target_tn == X` → drive `sched_blk1/2_tnX_sys` = head, sonst Null-PDU.

## AACH-Encoder mit Z.13 Slot-Side Select

Phase Z.13 (Kommentar Z. 2891–2909, 3694–3737): Es gibt EINEN
linear-multiplexierten AACH-Pfad.

```
head_match_aach_sys = queue_head_valid_w &&
 ((queue_head_target_tn_w == tx_tdma_state_tn_sys) ||
 (queue_head_target_tn_w == tx_tn_next_sys))

u_aach_rm_slot (kombinatorisch RM-Encode von queue_head_aach_pattern_w)
 → head_aach_coded_sys_w

u_aach_encoder (default-logic — F18-Anchor, Idle 0x0249, Voice-Mask, Grant-Override)
 → aach_coded_sys_w

aach_coded_slot_sys_w = head_match_aach_sys ? head_aach_coded_sys_w
: aach_coded_sys_w
```

`u_aach_encoder` Inputs include `signalling_active_sys = queue_head_valid_w &&
(queue_head_target_tn_w == tx_tn_next_sys)`, plus `voice_active_mask_sys_r1`,
`grant_pending_sys_r1`, `grant_info_sys_r1`, `grant_consume_sys_w`.

## Voice-Pfad (Stand 2026-05-17)

Y.4.1 ist `REG_VOICE_ACTIVE_MASK` + AACH-Logik (LIVE). Y.4.2/Y.4.3
(UL-voice-capture + CMCE-Port-Forward) sind **entfernt** (A.1 Rollback).
Aktueller Voice-Pfad ist **Phase C (UL-NUB-Capture) + Phase 7 G.8
(DL-Voice-Filler)**, gesteuert komplett durch SW (TCH/S-Codec auf ARM,
siehe Ch 9):

- **Y.4.1 (Live, unverändert):**
 - Register `REG_VOICE_ACTIVE_MASK @ 0x1EC` (R/W 4-bit).
 - CDC → `voice_active_mask_sys_r1[3:0]`.
 - Konsumiert von `u_aach_encoder.voice_active_mask_sys` — sendet
   **`0x32CB` durchgehend FN 1-17** auf aktivem Voice-Slot (siehe Ch 5).
   Frühere Rotation 0x32CB/0x22C9/0x2049 war Drift, gefixt in `e8efb31`.

- **Phase C UL-NUB-Capture (Live, in `u_rx_chain` instanziiert):**
 - `tetra_ul_sync_detect_os4` zweite Instanz mit NTS1-Pattern → `sync_found`
 - `tetra_ul_nub_capture` → 432 type-5 Bits BKN1+BKN2 (Ch 4)
 - `u_voice_nub_read_mailbox` (Z. 3429) buffer-stellt für SW

- **Phase 7 G.8 DL-Voice-Filler (Live, top-level):**
 - `u_voice_filler_mailbox` (Z. 3337) — SW (per `sw/tetra_voice_pipe.c`)
   schreibt 432-bit re-encoded burst pro UL-NUB-Frame
 - `tetra_burst_dispatcher` overridet sched/static auf voice-slot wenn
   `voice_active_mask & vfill_valid`

Es gibt keinen RTL-Voice-Relay mehr — `tetra_voice_relay.v` ist seit
`e8efb31` aus dem DL-Pfad raus. Die `REG_VOICE_RELAY_CNT @ 0x264`-Telemetrie
bleibt als Stub (deprecated, siehe Ch 8).

## CDC-Brücken

### clk_sys → clk_axi (Sample, 2-FF)
- `sync_locked_sys` → `sync_locked_axi_r1` (Z. 1346–1356)
- `frame_num_sys` Gray→2FF→Bin (Z. 1362–1387)
- `slot_num` (`timeslot_num_sys`) Gray→2FF→Bin (Z. 1389–1408)
- DMA/CRC/sync-lost Counter direct 2-FF (Z. 1496–1530)
- DL-Signal-Queue/Pre-Reply Counters (Z. 1686–1745)
- UL-Mailbox Snapshot-Felder (Z. 1572–1678) — getriggert durch Toggle-CDC-Pulse
- MLE-FSM Statistiken (Z. 2516–2557)
- Phase H.6.1 ul_cont/schhu Counters (Z. 2574–2597)
- TX-TDMA STATE Per-Bit 2-FF (Z. 1862–1915)
- Demand/Reply Mailbox: pending, drop_cnt, data_word (Z. 3008–3030, 3193–3209, 3296–3318)

### clk_sys → clk_axi (Pulse → Toggle → 2FF + Edge)
- `irq_mac_block_sys` → `irq_mac_block_axi` (Z. 1412–1434)
- `crc_error` pulse → `irq_crc_error_axi` (Z. 1449–1471)
- `fifo_full_sys` rising → `irq_rx_fifo_full_axi` (Z. 1474–1491)
- `ul_pdu_valid_sys` → `ul_pdu_valid_axi_pulse` (Z. 1549–1570)

### clk_sys → clk_axi (1-Cycle Pulse direkt 2-FF, kein Edge)
- `demand_consume_axi_r1` ← `demand_ack_pulse_sys_w` (Z. 3038–3048)
- `reply_go_consume_axi_r1` ← `reply_go_pulse_sys_w` (Z. 3212–3222)
- `grp_demand_consume_axi_r1` ← `grp_demand_ack_pulse_sys_w` (Z. 3323–3333)
- `nwrk_bcast_consume_axi_r1` ← `nwrk_bcast_push_valid_sys_w` (Z. 2912–2928)
- `aach_grant_consume_axi_r1` ← `aach_grant_consume_sys_w` (Z. 2626–2636)

### clk_axi → clk_sys (Static config, Per-Bit 2-FF)
- Alle CELL_CFG-Felder (Z. 3425ff.)
- `colour_code_sys_r1` (Z. 3537–3543)
- `cfg_mcch_tn_sys_r1` (Z. 3544–3551)
- `cell_la_sys_r1` (Z. 3552–3559)
- `db_policy_accept_unknown_sys_r1` (Z. 3561–3568)
- `voice_active_mask_sys_r1` (Z. 3571–3580)
- `ul_scramb_init_sys` (Z. 1750–1761)
- `nwrk_bcast_payload/trigger/period_mf` (Z. 2654–2676)
- `aach_grant_info/pending_sys_r1` (Z. 2607–2623)
- `reass_t0_frames_axi_sys` (Z. 671–682)
- `reply_index/wdata_sys_r1` (Z. 3084–3100)
- `demand/grp_demand_index_sys_r1` (Z. 2954–2964, 3247–3257)

### clk_axi → clk_sys (Pulse: 2-FF + Edge-Detect → 1-Cycle pulse)
- `tx_tdma_sync_load_strobe_sys` (Z. 1815–1836)
- `reply_we_pulse_sys_w` (Z. 3107–3121)
- `reply_go_pulse_sys_w` (Z. 3124–3138)
- `demand_ack_pulse_sys_w` (Z. 2967–2981)
- `grp_demand_ack_pulse_sys_w` (Z. 3260–3275)

### clk_axi → clk_lvds (Per-Bit 2-FF)
- `ctrl_loopback_en_lvds` ← `ctrl_loopback_en_axi` (Z. 267, 1763–1771)

### clk_lvds → clk_sys (Symbol-Tick Toggle)
- `sym_toggle_lvds` → 2-FF → Edge → `sym_en_sys_w` (Z. 1030–1046)

## Tote / Inaktive Pfade

Aus IST-Sicht im aktuellen Top:

1. **LMAC TX-Pfad** (Z. 869–878): `tx_data_in_sys=0, tx_data_valid_sys=0, tx_flush_sys=0, tx_aach_in_sys=0, tx_aach_valid_sys=0`. Output `tx_block1_sys = tx_block2_sys = 0` im LMAC selbst. ARM-DMA-MM2S existiert nicht.
2. **Shadow-Schreibpfad** (Z. 445–447, 2153–2160): `shadow_wr_idx_w`, `shadow_wr_data_w`, `shadow_wr_en_w` haben keinen Consumer.
3. **Profile-Schreib-/Lese-Pfad** (Z. 449–453): `profile_wr_*_w` ohne Consumer, `profile_rd_data_axi_sys_w = 32'd0` hardwired.
4. **Steal-Detect** ist hardwired auf Slot 0 (`steal_active_w[0]`).
5. **Free-running Legacy-Counter** (`tx_slot_cnt_sys`, `tx_frame_cnt_sys`, `tx_mf_cnt_sys`): nur für `REG_TX_TDMA` (0x38) AXI-Status, nicht im Datenpfad.
6. **tetra_tx_pdu_mailbox** existiert als Datei (`rtl/infra/tetra_tx_pdu_mailbox.v`), wird aber im Top NICHT instanziiert.
7. **`adc_r1_mode | dac_r1_mode`** sind in `_unused_r1` markiert (Z. 348).
8. **`reply_use_sw_axi_w`** (REG_REPLY_USE_SW @ 0x230) ist nach Phase X.7 nur noch ein Statusbit, FPGA-Mux entfernt (`_unused_reply_use_sw` Z. 3079–3081).
9. **`mle_*_pulse_w` (ack/retransmit/lost/detach)** werden vom MLE-FSM ausgegeben aber nicht in AXI-Counter gemappt (nur `mle_accept/drop/busy` sind exportiert).

## Wichtige Top-Wires nach Suchstring `tx_tdma_state_*`

```
tx_tdma_state_tn_sys — 0-based TN, vom u_tx_tdma_timebase
tx_tdma_state_fn_sys — 0-based FN
tx_tdma_state_mn_sys — 0-based MN (6-bit, 0..59)
tx_tdma_state_hn_sys — 0-based HN (6-bit free-running)
tx_tdma_state_slot_pulse_sys — 1-Cycle Slot-Edge-Pulse
tx_tdma_state_tdma_tick_sys — 1-Cycle Symbol-Tick (kommt direkt von sym_en)
tx_tdma_state_sym_cnt_sys — 0..254 Symbol innerhalb Slot
tx_tdma_state_*_axi_r1 — 2-FF Resync-Output für REG_TX_TDMA_STATE (0x144)
tx_tdma_sync_*_axi_w — vom AXI Register REG_TX_TDMA_LOAD (0x140)
tx_tdma_sync_load_strobe_sys — Edge-Detect zum Sync-Load in den Counter
```

## Wichtige Top-Wires nach Suchstring `voice_*`

```
voice_active_mask_axi_w[31:0] — AXI-Register Wert
voice_active_mask_sys_r1[3:0] — 2-FF Resync in clk_sys
vfill_blk1/2_sys[215:0]       — vom u_voice_filler_mailbox (DL re-encoded NUB)
vfill_valid_sys               — gated mit voice_active_mask im burst_dispatcher
(UL-NUB-Capture-Wires liegen in u_rx_chain → voice_nub_read_mailbox)

# ENTFERNT (A.1-Rollback): voice_burst_* / ul_demod_dibit_* (Y.4.2 UL-voice-
# capture + CMCE-Port-Forward) existieren im heutigen Top NICHT mehr.
```
