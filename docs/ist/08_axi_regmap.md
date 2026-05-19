# IST 08 — AXI4-Lite Register Map
Stand: 2026-05-17

Quelle: `rtl/infra/tetra_axi_lite_regs.v` (2445 Zeilen). Modul: `tetra_axi_lite_regs`,
Slave-Base wird im BD adressiert (Headerkommentar in `tetra_zynq_top.v` nennt
`0x4000_0000`). Adressbus ist 11 Bit (Word-Adresse `[10:2]`, davon `[10:9]`
selektiert das Banking:

- `[10:9]==2'b00` → Bank-0 Register `0x000..0x1FC` (Hauptbank, decode über `[8:2]`)
- `[10:9]==2'b01` → Bank-1 Mailbox-Extension `0x200..0x2FC` (auch `[8:2]`-aliased, eigenes Decode)
- `9'h100..9'h18F` → Schedule-BRAM `0x400..0x63F`

Write-Machine: `AWREADY = !aw_latched`, `WREADY = !w_latched`, `wr_handshake`
fires bei `aw_latched & w_latched & !bvalid`. Read-Machine: 1-Cycle-Latenz für
Register-Reads, 2-Cycle für Schedule-BRAM-Reads (Port-A Sync-Read).

`BRESP`/`RRESP` immer OKAY.

## Komplette Register-Tabelle

### Bank-0 — Hauptregister (0x000..0x1FC)

| Addr | Name | Width | R/W | Default | Beschreibung / Side-effect |
|--------|----------------------------|-------|------|------------------|----------------------------|
| 0x00 | REG_CTRL | 4 | R/W | 0x0 | [0]RX_EN [1]TX_EN [2]LOOPBACK [3]RST_CNTRS — Bits sind direkt-output über `ctrl_*_axi`, CTRL[3] feedbackt nach `clk_sys` Counter-Reset |
| 0x04 | REG_STATUS | 32 | RO | - | [0]sync_locked [1]pll_locked (hardwired 1 im Top) [2]fifo_empty [3]fifo_full [7:4]slot_status[3:0] |
| 0x08 | REG_VERSION | 32 | RO | 0x0001_0000 | Konstante v1.0 |
| 0x0C | REG_SYNC_THRESH | 8 | R/W | 0x0D | Default 13 (UL-OS4 sweet-spot, ≤19 STS, ≤11 NTS) |
| 0x10 | REG_COLOUR_CODE | 6 | R/W | 6'd1 | ColourCode, geht in BSCH-Scrambler |
| 0x14 | REG_FRAME_NUM | 5 | RO | - | Live `frame_num_axi` (Gray→Bin nach 2-FF resync) |
| 0x18 | REG_SLOT_NUM | 2 | RO | - | Live `slot_num_axi` (Gray→Bin nach 2-FF resync) |
| 0x1C | REG_RX_GAIN | 7 | R/W | 0x20 | RX-Gain Stellwert (LMAC unused; Wire pro forma) |
| 0x20 | REG_TX_ATT | 8 | R/W | 0x28 | TX-Attenuation (LMAC unused; Wire pro forma) |
| 0x24 | REG_IRQ_ENABLE | 5 | R/W | 5'b0 | Bit-Maske, gated mit IRQ_STATUS für `irq_out_axi` |
| 0x28 | REG_IRQ_STATUS | 5 | R/W1C| 5'b0 | [0]MAC_BLOCK [1]SYNC_ACQ [2]SYNC_LOST [3]CRC_ERR [4]FIFO_FULL. HW-Set gewinnt bei gleichzeitigem SW-Clear |
| 0x2C | REG_DMA_BLK_CNT | 16 | RO | - | Live `dma_block_count` aus DMA-Bridge (2-FF resync) |
| 0x30 | REG_CRC_ERR_CNT | 16 | RO | - | Live `crc_err_cnt_sys` (gated von CTRL[3] resettable) |
| 0x34 | REG_SYNC_LST_CNT | 16 | RO | - | Live `sync_lost_cnt_sys` |
| 0x38 | REG_TX_TDMA | 13 | RO | - | `{tx_mf_axi[5:0], tx_frame_axi[4:0], tx_slot_axi[1:0]}` (Free-Running TX-Counter Snapshot) |
| 0x3C | REG_SCRATCH | 32 | R/W | 0 | Per-Byte-Strobe-Writes |
| 0x40 | REG_SB_SB1_0 | 32 | R/W | 0 | BSCH coded payload Word 0 |
| 0x44 | REG_SB_SB1_1 | 32 | R/W | 0 | Word 1 |
| 0x48 | REG_SB_SB1_2 | 32 | R/W | 0 | Word 2 |
| 0x4C | REG_SB_SB1_3 | 24 | R/W | 0 | Word 3 [23:0] only (120 bit total) |
| 0x50 | REG_DBG_FE_CNT | 32 | RO | - | RX-Frontend valid count |
| 0x54 | REG_DBG_DEMOD_CNT | 32 | RO | - | Demod-dibit valid count |
| 0x58 | REG_DBG_SYNC_CNT | 32 | RO | - | `{corr_peak[7:0], dbg_sync_cnt[23:0]}` (DL-Sync) |
| 0x5C | REG_DBG_SYNC_UL | 32 | RO | - | `{ul_best_phase[1:0], 6'd0, ul_corr_peak[7:0], ul_sync_cnt[15:0]}` |
| 0x60 | REG_SB_BKN2_0 | 32 | R/W | 0 | BNCH coded Word 0 |
| 0x64 | REG_SB_BKN2_1 | 32 | R/W | 0 | Word 1 |
| 0x68 | REG_SB_BKN2_2 | 32 | R/W | 0 | Word 2 |
| 0x6C | REG_SB_BKN2_3 | 32 | R/W | 0 | Word 3 |
| 0x70 | REG_SB_BKN2_4 | 32 | R/W | 0 | Word 4 |
| 0x74 | REG_SB_BKN2_5 | 32 | R/W | 0 | Word 5 |
| 0x78 | REG_SB_BKN2_6 | 24 | R/W | 0 | Word 6 [23:0] (216 bit total) |
| 0x7C | REG_SB_BB | 30 | R/W | 0 | AACH-Payload (legacy, datapath nicht aktiv) |
| 0x80 | (removed) | - | - | - | Frühere REG_NCO_PHASE_INC entfernt |
| 0x84 | REG_TX_TEST | 1 | R/W | 0 | [0]TX_PRBS_EN → ersetzt Builder-Dibit durch 15-bit LFSR |
| 0x88 | REG_NDB_BLK1_0 | 32 | R/W | 0 | NDB Block1 Word 0 |
| 0x8C | REG_NDB_BLK1_1 | 32 | R/W | 0 | Word 1 |
| 0x90 | REG_NDB_BLK1_2 | 32 | R/W | 0 | Word 2 |
| 0x94 | REG_NDB_BLK1_3 | 32 | R/W | 0 | Word 3 |
| 0x98 | REG_NDB_BLK1_4 | 32 | R/W | 0 | Word 4 |
| 0x9C | REG_NDB_BLK1_5 | 32 | R/W | 0 | Word 5 |
| 0xA0 | REG_NDB_BLK1_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0xA4 | REG_NDB_BLK2_0 | 32 | R/W | 0 | NDB Block2 Word 0 |
| 0xA8 | REG_NDB_BLK2_1 | 32 | R/W | 0 | Word 1 |
| 0xAC | REG_NDB_BLK2_2 | 32 | R/W | 0 | Word 2 |
| 0xB0 | REG_NDB_BLK2_3 | 32 | R/W | 0 | Word 3 |
| 0xB4 | REG_NDB_BLK2_4 | 32 | R/W | 0 | Word 4 |
| 0xB8 | REG_NDB_BLK2_5 | 32 | R/W | 0 | Word 5 |
| 0xBC | REG_NDB_BLK2_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0xC0 | REG_MCCH_BLK1_0 | 32 | R/W | 0 | MCCH Slot-1 Block1 Word 0 (ACCESS-DEFINE PDU) |
| 0xC4 | REG_MCCH_BLK1_1 | 32 | R/W | 0 | Word 1 |
| 0xC8 | REG_MCCH_BLK1_2 | 32 | R/W | 0 | Word 2 |
| 0xCC | REG_MCCH_BLK1_3 | 32 | R/W | 0 | Word 3 |
| 0xD0 | REG_MCCH_BLK1_4 | 32 | R/W | 0 | Word 4 |
| 0xD4 | REG_MCCH_BLK1_5 | 32 | R/W | 0 | Word 5 |
| 0xD8 | REG_MCCH_BLK1_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0xDC | REG_MCCH_BLK2_0 | 32 | R/W | 0 | MCCH Block2 Word 0 |
| 0xE0 | REG_MCCH_BLK2_1 | 32 | R/W | 0 | Word 1 |
| 0xE4 | REG_MCCH_BLK2_2 | 32 | R/W | 0 | Word 2 |
| 0xE8 | REG_MCCH_BLK2_3 | 32 | R/W | 0 | Word 3 |
| 0xEC | REG_MCCH_BLK2_4 | 32 | R/W | 0 | Word 4 |
| 0xF0 | REG_MCCH_BLK2_5 | 32 | R/W | 0 | Word 5 |
| 0xF4 | REG_MCCH_BLK2_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0xF8 | REG_BNCH_BLK1_0 | 32 | R/W | 0 | BNCH (F18) Block1 Word 0 |
| 0xFC | REG_BNCH_BLK1_1 | 32 | R/W | 0 | Word 1 |
| 0x100 | REG_BNCH_BLK1_2 | 32 | R/W | 0 | Word 2 |
| 0x104 | REG_BNCH_BLK1_3 | 32 | R/W | 0 | Word 3 |
| 0x108 | REG_BNCH_BLK1_4 | 32 | R/W | 0 | Word 4 |
| 0x10C | REG_BNCH_BLK1_5 | 32 | R/W | 0 | Word 5 |
| 0x110 | REG_BNCH_BLK1_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0x114 | REG_BNCH_BLK2_0 | 32 | R/W | 0 | BNCH Block2 Word 0 |
| 0x118 | REG_BNCH_BLK2_1 | 32 | R/W | 0 | Word 1 |
| 0x11C | REG_BNCH_BLK2_2 | 32 | R/W | 0 | Word 2 |
| 0x120 | REG_BNCH_BLK2_3 | 32 | R/W | 0 | Word 3 |
| 0x124 | REG_BNCH_BLK2_4 | 32 | R/W | 0 | Word 4 |
| 0x128 | REG_BNCH_BLK2_5 | 32 | R/W | 0 | Word 5 |
| 0x12C | REG_BNCH_BLK2_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0x130 | REG_CELL_CFG_0 | 16 | R/W | (siehe unten) | [3:0]sys_code [5:4]sharing_mode [8:6]ts_res_frames [9]uplane_dtx [10]frame18_ext [12:11]neigh_cell_bc [14:13]cell_service_level [15]late_entry_support |
| 0x134 | REG_CELL_CFG_1 | 24 | R/W | (siehe unten) | [9:0]mcc [23:10]mnc |
| 0x140 | REG_TX_TDMA_LOAD | 32 | R/W | 0 | [1:0]TN [6:2]FN [12:7]MN [18:13]HN [31]STROBE — Schreiben mit [31]=1 löst 1-Cycle Sync-Load-Pulse aus |
| 0x144 | REG_TX_TDMA_STATE | 32 | RO | - | [1:0]TN [6:2]FN [12:7]MN [18:13]HN [26:19]sym_cnt — Live-Snapshot der timebase nach 2-FF Resync |
| 0x148 | REG_NULL_PDU_0 | 32 | R/W | 0 | NULL-PDU SCH/HD-coded Word 0 |
| 0x14C | REG_NULL_PDU_1 | 32 | R/W | 0 | Word 1 |
| 0x150 | REG_NULL_PDU_2 | 32 | R/W | 0 | Word 2 |
| 0x154 | REG_NULL_PDU_3 | 32 | R/W | 0 | Word 3 |
| 0x158 | REG_NULL_PDU_4 | 32 | R/W | 0 | Word 4 |
| 0x15C | REG_NULL_PDU_5 | 32 | R/W | 0 | Word 5 |
| 0x160 | REG_NULL_PDU_6 | 24 | R/W | 0 | Word 6 [23:0] |
| 0x164 | REG_UL_PDU_STATUS | 32 | RO | - | UL MAC-ACCESS-Mailbox: [0]valid_sticky [1]pdu_type [2]fill [3]enc [5:4]addr_type [6]opt_flag [7]frag_flag [11:8]reservation_req [31:16]pdu_count |
| 0x168 | REG_UL_PDU_SSI | 24 | RO | - | issi[23:0] des letzten UL-MAC-ACCESS-PDUs |
| 0x16C | REG_UL_PDU_RAW_0 | 32 | RO | - | raw_info_bits[31:0] |
| 0x170 | REG_UL_PDU_RAW_1 | 32 | RO | - | raw_info_bits[63:32] |
| 0x174 | REG_UL_PDU_RAW_2 | 28 | RO | - | raw_info_bits[91:64], upper 4 RAZ |
| 0x178 | REG_UL_PDU_CTRL | 1 | W1C | 0 | [0] clear `ul_pdu_valid_sticky_axi` — HW-Set gewinnt |
| 0x17C | REG_UL_SCRAMB_INIT | 32 | R/W | 0 | UL-Scrambler-Seed → `tetra_ul_sch_hu_decoder` |
| 0x180 | REG_SHADOW_INDEX | 8 | R/W | 0 | Subscriber-Shadow Slot-Index 0..255 (legacy compat) |
| 0x184 | REG_SHADOW_DATA_LO | 32 | R/W | 0 | Shadow-Record [31:0] |
| 0x188 | REG_SHADOW_DATA_HI | 32 | R/W | 0 | Shadow-Record [63:32] |
| 0x18C | REG_SHADOW_CTRL | 1 | W1S | 0 (selbstclrd) | [0] commit-pulse → 1 clk_axi cycle `shadow_wr_en_axi`. **IST-Beobachtung:** Im Top-Level (Phase X.4) ist der Consumer (`shadow_wr_*_w`) tot — siehe Top-Kommentar Z. 438ff. |
| 0x190 | REG_MLE_STATS_A | 32 | RO | - | `{accept_cnt[15:0], ul_req_cnt[15:0]}` |
| 0x194 | REG_MLE_STATS_B | 32 | RO | - | `{15'b0, busy_sticky, drop_cnt[15:0]}` |
| 0x198 | REG_MLE_STATS_C | 32 | RO | - | `{clear_cnt[15:0]=queue_drop, inject_cnt[15:0]=sig_override}` |
| 0x19C | REG_SIGNAL_TARGET_TN | 2 | R/W | 2'd0 | DL-Signalling Target-TN. Default 0 muss zum schedule.py-Init passen |
| 0x1A0 | REG_CELL_LA | 14 | R/W | 14'd1 | Cell Location Area — von SW geschrieben, in `tetra_mle_registration_fsm.cfg_la` |
| 0x1A4 | REG_SLOTGRANT_STATS | 32 | RO | - | `{slotgrant_drop[15:0], slotgrant_push[15:0]}` |
| 0x1A8 | REG_PRE_REPLY_BLCK_STATS | 32 | RO | - | `{blck_drop[15:0], blck_push[15:0]}` |
| 0x1AC | REG_DB_POLICY | 32 | R/W | 0x0000_0003 | [0]accept_unknown_issi [1]accept_unknown_gssi [31:2] reserved. Default beide ON = M2-kompat |
| 0x1B0 | REG_DL_QUEUE_STATS | 32 | RO | - | `{qdrop_mle[15:8], qdrop_cmce[7:0], qdrop_sds[15:8], 8'd0}` — Layout: MLE@[31:24], CMCE@[23:16], SDS@[15:8] |
| 0x1B4 | REG_UL_PDU_STATUS_2 | 32 | RO | - | `{20'd0, ul_llc_pdu_type[3:0], 1'd0, ul_mle_disc[2:0], ul_mm_pdu_type[3:0]}` — Phase 7 F.3. `ul_mm_pdu_type` ist **LLC-wrapped** (Bits[44..47]) |
| 0x1B8 | REG_UL_CONT_CNT | 16 | RO | - | UL MAC-END-HU continuation count |
| 0x1BC | REG_SCHHU_VALID_CNT | 16 | RO | - | SCH/HU decoder produced info_valid count |
| 0x1C0 | REG_PROFILE_INDEX | 3 | R/W | 3'd0 | Profile-Slot-Index 0..5. Treibt auch `profile_rd_idx_axi` (Phase 7 F.4) |
| 0x1C4 | REG_PROFILE_DATA | 32 | R/W | 0 | Staging-Register, Per-Byte-Strobe |
| 0x1C8 | REG_PROFILE_DATA_RD | 32 | RO | - | Phase 7 F.4 — drift-frei aus `tetra_profile_table` (im aktuellen Top-Level auf 0 hardwired, siehe Top Z. 452) |
| 0x1CC | REG_PROFILE_CTRL | 1 | W1S | 0 (selbstclrd) | [0] commit-pulse → `profile_wr_en_axi`. **IST-Beobachtung:** Consumer im Top-Level tot (Phase X.4) |
| 0x1D0 | REG_NWRK_BCAST_INDEX | 4 | R/W | 4'd0 | D-NWRK-BROADCAST Payload-Word-Index 0..13 |
| 0x1D4 | REG_NWRK_BCAST_DATA | 32 | R/W | 0 (Storage init 0)| 32-bit indizierter Write in 14×32-Storage. Word 13 verwendet nur [31:16] (Bit[15:0] des 432-bit-Bus) |
| 0x1D8 | REG_NWRK_BCAST_TRIGGER | 1 | W1S | 0 | [0] Pulse → trigger persistiert bis `nwrk_bcast_consume_axi` clear |
| 0x1DC | REG_REASSEMBLY_T0 | 4 | R/W | 4'd0 | T0 in TDMA-Frames; 0 = Modul-Default (=2 frames ≈113 ms) |
| 0x1E0 | REG_REASSEMBLY_STATS | 32 | RO | - | `{reass_drop[15:0], reass_reassembled[15:0]}` |
| 0x1E4 | REG_NWRK_BCAST_CNT | 16 | RO | - | Live Push-Counter aus `tetra_dl_nwrk_broadcast` |
| 0x1E8 | REG_NWRK_BCAST_PERIOD_MF | 5 | R/W | 5'd10 | Auto-Fire-Periode in Multiframes; 0 = SW-Trigger |
| 0x1EC | REG_VOICE_ACTIVE_MASK | 32 | R/W | 0 | [3:0] aktive Voice-Slot Bitmap pro tn_sys (Phase Y.4.1) |
| 0x1F0 | REG_SCHHU_CRC_CNT | 16 | RO | - | SCH/HU info_valid + CRC ok |
| 0x1F4 | REG_AACH_GRANT_HINT | 32 | R/W | 0 | [31]pending (SW-Set, HW-Clr on consume) [13:0]info word — One-Shot UL-Slot-Grant Override |
| 0x1F8 | REG_DL_SCHEDULER_STATS | 32 | RO | - | `{sched_override_cnt[31:16], sched_pop_cnt[15:0]}` |

**Hinweis:** Offsets 0x1FC (vor Bank-1) reads as 0 (default case).

### Bank-1 — Mailbox-Extension (0x200..0x2FC)

Decode-Gate: `wr_en_x1_axi = wr_handshake & (wr_addr_axi[10:8] == 3'b010)`,
read-side `if (rd_addr_axi[10:9] == 2'b01)`. Eigenes Case-Statement über `[8:2]`.

| Addr | Name | Width | R/W | Default | Beschreibung / Side-effect |
|--------|----------------------------|-------|------|---------|----------------------------|
| 0x200 | REG_DEMAND_STATUS | 32 | RO | - | `{demand_drop_cnt[15:0], 15'd0, demand_pending}` |
| 0x204 | REG_DEMAND_INDEX | 4 | R/W | 4'd0 | Indirect-Word-Index 0..15 für mm=2 Demand-Mailbox |
| 0x208 | REG_DEMAND_DATA | 32 | RO | - | Indirect via INDEX, lebt in clk_sys (CDC durch Top) |
| 0x20C | REG_DEMAND_ACK | 1 | W1S | 0 | [0] ACK — HW-Clr durch `demand_consume_axi` |
| 0x220 | REG_REPLY_INDEX | 4 | R/W | 4'd0 | Word-Selector für Reply-Mailbox |
| 0x224 | REG_REPLY_DATA | 32 | R/W | - | Indirect-Write + Readback; `wr_en_x1` Pulse → `reply_we_axi_o` |
| 0x228 | REG_REPLY_GO | 1 | W1S | 0 | [0] GO-Pulse zum MLE-FSM, HW-Clr |
| 0x22C | REG_REPLY_STATUS | 1 | RO | - | [0]=busy-mirror (= `mle_busy_w` resynct) |
| 0x230 | REG_REPLY_USE_SW | 1 | R/W | 1'b1 | [0]=use_sw_body. Phase X.7 Stand: nur Status, FPGA-Mux entfernt |
| 0x240 | REG_GRP_DEMAND_STATUS | 32 | RO | - | `{grp_drop_cnt[15:0], 15'd0, grp_pending}` |
| 0x244 | REG_GRP_DEMAND_INDEX | 4 | R/W | 4'd0 | Word-Index für mm=7 Group-Attach Demand |
| 0x248 | REG_GRP_DEMAND_DATA | 32 | RO | - | Indirect via INDEX |
| 0x24C | REG_GRP_DEMAND_ACK | 1 | W1S | 0 | [0] ACK — HW-Clr durch `grp_demand_consume_axi` |
| 0x250..0x25C | (entfernt Phase Y.2) | - | - | - | Gruppen-Reply komplett gestrichen — SW nutzt mm=2 Reply-Pull-Mailbox mit raw-mode |

**Phase C / Phase 7 G.8 — Voice-Channel Telemetrie + Filler-Mailbox + NUB-Read-Mailbox (Bank-1 0x260..0x28C):**

| Addr | Name | Width | R/W | Default | Beschreibung / Side-effect |
|--------|----------------------------|-------|------|---------|----------------------------|
| 0x260 | REG_VOICE_NUB_RX_CNT | 32 | RO | - | `[15:0] bursts_captured_sys` von `tetra_ul_nub_capture` (Call-FSM PTT-Aktivitäts-Heartbeat) |
| 0x264 | REG_VOICE_RELAY_CNT | 32 | RO | - | `[15:0] relay_cnt_sys` von `tetra_voice_relay` (DEPRECATED-Pfad, RTL-relay aus DL raus seit `e8efb31`) |
| 0x268 | REG_VOICE_NUB_SYNC_THRESH | 32 | R/W | 8 (RTL); 11 (SW-Daemon) | `[4:0]` NTS1-Korrelator-Schwelle für NUB-Sync. **2026-05-17 Survey:** `=11` ist sweet-spot (BFI 4.7 %, no false-positives im Idle); `=10` hat höhere wackelige Locks (6 %); `=12` killt Lock komplett. SW-Daemon (`tetra_attach_daemon.c`) setzt Boot-Default auf 11. |
| 0x270 | REG_VOICE_FILLER_INDEX | 4 | R/W | 4'd0 | Word-Index für DL-Voice-Filler-Mailbox (0..15) |
| 0x274 | REG_VOICE_FILLER_DATA | 32 | R/W | - | Indirect-Write/Read via INDEX. W0..W13 = 432 type-5 bits LSB-first, W14[0] = filler_valid, W15 reserved |
| 0x278 | REG_VOICE_FILLER_GO | 1 | W1S | 0 | [0]=Commit-Puls (informativ, HW-Clr) |
| 0x27C | REG_VOICE_FILLER_STATUS | 1 | RO | - | [0]=`filler_valid` mirror (= W14[0]) |
| 0x280 | REG_VOICE_NUB_READ_INDEX | 6 | R/W | 6'd0 | Word-Index für UL-NUB-Read-Mailbox (0..53, war 4-bit vor Phase E2) |
| 0x284 | REG_VOICE_NUB_READ_DATA | 32 | RO | - | Indirect via INDEX — **432 × 4-bit signed soft-values** = 54 Words (Phase E2 commit `cae5108`) aus `tetra_ul_nub_capture` |
| 0x288 | REG_VOICE_NUB_READ_STATUS | 1 | RO | - | [0] valid (neuer Burst pending) |
| 0x28C | REG_VOICE_NUB_READ_ACK | 1 | W1S | 0 | [0] ACK — clear valid + arm next |

Bit-Layout `REG_VOICE_FILLER_*`-Mailbox: SW packt type-5 bits LSB-first im 14-Wort-Bereich (bit n = words_flat[n]). `blk1_sys = bits 0..215` (BKN1/NDB1), `blk2_sys = bits 216..431` (BKN2). RTL `tetra_voice_filler_mailbox.v` reicht das kombinatorisch an `tetra_burst_dispatcher` durch (Gating: `voice_active_mask & filler_valid`).

### Bank-2 — Schedule-BRAM (0x400..0x63F)

144 × 32-bit Worte (`9'h100 ≤ rd_word_idx < 9'h190`). Jedes Wort enthält
2 × 16-bit Schedule-Entries (siehe `rtl/tx/tetra_slot_schedule.v`).

- Schreiben: `schedule_axi_we = wr_handshake & (wr_word_idx[10:9]==2'b10 & wr_word_idx[8:7]==2'b01)` (in Wahrheit Gate auf `wr_word_idx ∈ [0x100..0x18F]`)
- Lesen: `schedule_axi_re = ar_en_axi & rd_in_sched_window`. 1 Extra-Cycle Latenz (Port-A Sync-Read), implementiert via `ar_pending_sched_axi` und `rdata_commit_axi`.

Die Tabelle pro Wort liefert `axi_rdata` aus dem BRAM, nicht aus `tetra_axi_lite_regs.v` selbst.

## Register-Block-Erklärungen mit Side-Effects

Reine Status-Reads sind durch die Tabelle vollständig beschrieben. Hier nur die
Register, die FSMs triggern oder nicht-triggerbare Side-Effects haben.

### REG_CTRL (0x00)
Schreiben aktualisiert das 4-bit `ctrl_reg_axi`. Outputs:
- `ctrl_rx_enable_axi = ctrl_reg_axi[0]` (Wire, nicht aktiv genutzt — Header notiert "PHY modules")
- `ctrl_tx_enable_axi = ctrl_reg_axi[1]`
- `ctrl_loopback_en_axi = ctrl_reg_axi[2]` — wird 2-FF in `clk_sys` und
 `clk_lvds` resynct, triggert den Loopback-Mux in tetra_zynq_top (Z. 336–338).
- `ctrl_reset_counters_axi = ctrl_reg_axi[3]` — 2-FF in clk_sys, treibt
 `dbg_fe_cnt_sys`, `dbg_demod_cnt_sys`, `dbg_sync_cnt_sys`, `dbg_ul_sync_cnt_sys`,
 `crc_err_cnt_sys`, `sync_lost_cnt_sys` und `dma_block_count`-Reset.

### REG_IRQ_STATUS (0x28) — R/W1C mit HW-Set-Priorität
Bei gleichzeitigem HW-Set und SW-Clear bleibt das Bit auf 1. Wire-Formel
(Z. 1462–1463):
```
new = (status | hw_set) & ~(sw_clr & ~hw_set)
```

### REG_SHADOW_CTRL (0x18C) — W1S → 1-Cycle Pulse
Schreiben mit `[0]=1` setzt `shadow_commit_pulse_axi` für 1 clk_axi-Cycle, das
treibt `shadow_wr_en_axi = pulse`. Storage `shadow_wr_idx_axi`/`shadow_wr_data_axi`
kommen aus den vorab geschriebenen INDEX/DATA_LO/DATA_HI Registern. Aktueller
IST-Stand: Consumer in `tetra_zynq_top` ist nach Phase X.4 tot (Wire `shadow_wr_*_w`
hat keinen RTL-Verbraucher; SW liest die Daten direkt per AXI).

### REG_PROFILE_CTRL (0x1CC) — analog Shadow-CTRL
Schreiben mit `[0]=1` → 1-Cycle `profile_commit_pulse_axi` → `profile_wr_en_axi`.
Konsumer im Top-Level: nicht mehr aktiv (Phase X.4 Migration nach SW;
`profile_rd_data_axi_sys_w` ist im Top hardwired auf `32'd0`, Z. 452).

### REG_TX_TDMA_LOAD (0x140) — STROBE Bit[31]
Schreiben mit `[31]=1` (Strobe-Byte-Lane aktiv via `wstrb[3]`) registriert
`tx_tdma_strobe_pulse_axi <= 1` für **1 clk_axi-Cycle**. Output
`tx_tdma_sync_strobe_axi` wird im Top-Level 2-FF resynct nach `clk_sys` und
edge-detected zu einem 1-Cycle-Pulse (`tx_tdma_sync_load_strobe_sys`,
`tetra_zynq_top.v:1836`), der die `tetra_tdma_timebase` zum Sync-Load
triggert. Die TN/FN/MN/HN-Felder werden bei jeder LOAD-Write gelatcht
(unabhängig von STROBE) — letzter Write gewinnt.

### REG_UL_PDU_CTRL (0x178) — W1C clear-sticky
Schreiben `[0]=1` clearct `ul_pdu_valid_sticky_axi`. HW-Set
(`ul_pdu_valid_axi` Pulse vom Parser-CDC) gewinnt bei Kollision. Die
Snapshot-Latches (SSI, raw_info_bits, mm_pdu_type etc.) werden NUR auf
`ul_pdu_valid_axi`-Pulse aktualisiert, nicht zurückgesetzt.

### REG_DEMAND_ACK (0x20C) / REG_GRP_DEMAND_ACK (0x24C) — W1S mit HW-Clr
Schreiben `[0]=1` setzt `demand_ack_trigger_r`/`grp_demand_ack_trigger_r` auf 1.
Wird durch `demand_consume_axi`/`grp_demand_consume_axi`-Pulse (vom clk_sys
zurück über CDC) gecleart. Trigger geht als Output `demand_ack_trigger_axi`
nach `tetra_demand_mailbox.ack_consumed_pulse_sys` (resynct).

### REG_REPLY_GO (0x228) — W1S mit HW-Clr
Setzt `reply_go_trigger_r=1`, cleart bei `reply_go_consume_axi`. Im clk_sys
wird daraus ein 1-Cycle-Edge-Detect-Puls `reply_go_pulse_sys_w`, der direkt
in `tetra_reply_mailbox.go_pulse_sys` läuft (= `mb_go_pulse_sys` zum MLE-FSM).

### REG_REPLY_DATA (0x224) — Write-Pulse zur Reply-Mailbox
Schreiben fired `reply_we_axi_o = wr_en_x1_axi & (addr == REG_REPLY_DATA)`. Im
Top wird daraus ein 1-Cycle-Pulse `reply_we_pulse_sys_w` und treibt
`tetra_reply_mailbox.wr_en_sys` an. `reply_index_axi_o` (vom INDEX-Register)
ist das Wort-Target. `wdata_sys = reply_wdata_axi_o = wr_data_axi`.

### REG_NWRK_BCAST_TRIGGER (0x1D8) — W1S
Schreiben `[0]=1` setzt `nwrk_bcast_trigger_r=1`, persistiert bis
`nwrk_bcast_consume_axi` cleart. `nwrk_bcast_trigger_axi`-Output geht in
`tetra_dl_nwrk_broadcast` (clk_sys-Resync).

### REG_NWRK_BCAST_DATA (0x1D4) — Indirect-Write
Per-Byte-Strobe in `nwrk_bcast_payload_axi_r[nwrk_bcast_index_axi]`. 14 ×
32-bit Storage, geht generate-Block-mapped in 432-bit Output `nwrk_bcast_payload_axi`.

### REG_AACH_GRANT_HINT (0x1F4) — SW-Set, HW-Clr
Per-Byte: `wstrb[0]` schreibt `info[7:0]`, `wstrb[1]` `info[13:8]`, `wstrb[3]`
schreibt `pending` aus `wr_data_axi[31]`. HW-Clr via `grant_consume_axi`
(clk_sys-Resync) hat niedrigere Priorität als SW-Set (Z. 1349–1364).

### REG_CELL_CFG_0 (0x130) — Reset-Default ist Field-Pack
```
{1'b1, // [15] late_entry_support = 1
 2'b00, // [14:13] cell_service_level = 0
 2'b11, // [12:11] neigh_cell_bc = 3
 1'b1, // [10] frame18_ext = 1
 1'b0, // [9] uplane_dtx = 0
 3'b000, // [8:6] ts_reserved_frames = 0
 2'b00, // [5:4] sharing_mode = 0
 4'd3} // [3:0] sys_code = 3 (V+D)
```
→ Reset-Wert `16'hC841` (1100_1000_0100_0001).

### REG_CELL_CFG_1 (0x134) — Reset-Default
```
{14'd9998, 10'd901} = 0x009C_E385 (24-bit, untere Bits)
```
(MCC=901, MNC=9998 — ITU-T E.212 Test Network)

### REG_REASSEMBLY_T0 (0x1DC)
4-bit R/W, Reset 0. Wenn 0, substituiert das Reassembly-Modul seinen
`T0_FRAMES_DEFAULT=2`. Operator kann z.B. 4 schreiben um längere
Frag-1→Frag-2-Fenster zu erlauben.

### REG_NWRK_BCAST_PERIOD_MF (0x1E8)
5-bit R/W, Reset `5'd10`. 0 = SW-Trigger-Modus (legacy), >0 = Auto-Fire alle
N Multiframes via `tetra_dl_nwrk_broadcast`-FSM.

### REG_DB_POLICY (0x1AC)
32-bit R/W, Reset `0x0000_0003`. Bit-Layout aus Modul-Header:
- [0] accept_unknown_issi — 1 → ISSI-Miss → auto-enroll; 0 → REJECT cause=0
- [1] accept_unknown_gssi — 1 → GSSI-Wunsch-Miss → auto-enroll; 0 → Profile-Default
- [31:2] reserved (auto_enroll_default_profile in späteren Phasen)

`db_policy_accept_unknown_sys_r1 = db_policy_axi[0]` (CDC in `clk_sys`,
Z. 3561–3568) wird vom Detach-Pfad konsumiert; bit[1] wird vom SW-Daemon direkt
gelesen.

### REG_VOICE_ACTIVE_MASK (0x1EC) — Phase Y.4.1
32-bit R/W (nur [3:0] funktional). Per-Byte-Strobe. Output `voice_active_mask_axi`
geht 2-FF in clk_sys (`voice_active_mask_sys_r1`, Z. 3571–3580), wird vom
`tetra_aach_encoder` (AACH-Voice-Pattern 0x32CB durchgehend FN 1-17) und vom
`tetra_burst_dispatcher` (Voice-Filler-Override-Gate via
`voice_active_mask & vfill_valid`) konsumiert. SW-Konsumenten siehe
`sw/tetra_call_fsm.c::mask_write_cached` (Ch 9). Frühere Y.4.2/Y.4.3-Consumer
(`tetra_ul_voice_capture`) sind in A.1 Rollback entfernt.

### REG_REPLY_USE_SW (0x230)
1-bit R/W, Reset `1'b1` (Phase X.4 "SW path primary"). Header und Top-Kommentar
(Z. 3077–3081) sagen: Phase X.7 hat den FPGA-Mux entfernt, das Bit ist nur noch
Status, FSM ignoriert es. `_unused_reply_use_sw` synthesis translate_off Block
markiert das.

## Auffälligkeiten / Drift-Spuren

- **REG_SHADOW_*** und **REG_PROFILE_*** Writes haben in der aktuellen RTL keinen
 Consumer mehr (Phase X.4 — siehe Top-Kommentar Z. 438ff.). AXI-Slave decoded
 und latcht, aber `shadow_wr_*_w` und `profile_wr_*_w` Wires terminieren ins
 Nichts und werden von synth ge-pruned.
- **REG_PROFILE_DATA_RD** (0x1C8) liefert immer 0x0 — `profile_rd_data_axi_sys_w`
 ist im Top hardwired (`tetra_zynq_top.v:452`).
- **REG_AST_DETACH_CNT/REG_AST_TTL_MFS/REG_AST_TTL_EVICT_CNT** waren mal an
 0x1A4/0x1A8/0x1B0 → diese Slots sind jetzt für DL-Signal-Queue-Stats
 rezykliert (siehe Tabelle).
- **REG_NCO_PHASE_INC** war historisch an 0x80, ist entfernt (Headerkommentar
 Z. 36).
- **0x250..0x25C** waren mal die GroupAck-Reply-Mailbox (Phase Y.1.d/e) und
 sind in Phase Y.2 komplett verschwunden.
- Bank-1 (`0x200..0x2FC`) hat ein **Aliasing-Risiko** mit Bank-0: Beide nutzen
 `[8:2]` als Decode-Bits. Schutz: `wr_en_axi` / `wr_en_x1_axi` qualifizieren
 über `[10:9]` (Z. 846 + 855), Read-Side über `if (rd_addr_axi[10:9] == 2'b01)`
 Override im rdata-Mux (Z. 1188–1211).
- **Phase-Tags in Kommentaren:**
 - Phase 3 — TX-Test/PRBS, RX-Pfad Setup
 - Phase 4 — TX-Pfad mit BB-Encoder
 - Phase 6 (M2.x) — Subscriber-Shadow + MLE-FSM
 - Phase H.3.x — ITSI-Attach Bugfixes
 - Phase H.6.x — UL MAC-END-HU diagnostics + AACH-Grant
 - Phase H.7 / H.7-AF — D-NWRK-BROADCAST
 - Phase X.1 — Demand-Mailbox
 - Phase X.2 — Reply-Pull-Mailbox
 - Phase X.3/X.4 — DB-Policy + AST/EntityTable Migration nach SW
 - Phase X.5/X.5b — Pre-Reply BL-ACK / SlotGrant
 - Phase X.6/X.7 — Shared DL-PDU-Builder + Reply-Use-SW-Cleanup
 - Phase Y.1.a..f — Group-Attach Demand/Reply Pipeline
 - Phase Y.2 — GroupAck-Build nach SW, Reply-Mailbox raw-mode Bypass
 - Phase Y.3 — Burst-Dispatcher / Slot-Content-Mux Refactor
 - Phase Y.4.1 — Voice-Active-Mask AACH-Override
 - ~~Phase Y.4.2/Y.4.3 — UL-Voice-Capture~~ (entfernt A.1 Rollback)
 - Phase 7 F.x — UL-Demand Reassembly + IE-Parser + Mailbox
 - Phase 7 G.x — D-CONNECT / CMCE PDU-Klassen
 - Phase C / Phase 7 G.8 — UL-NUB-Capture + DL-Voice-Filler Mailbox (siehe Bank-1 0x260..0x28C)
- **REG_DBG_SYNC_CNT (0x58)** ist NICHT plain 32-bit. Top Z. 3931:
 `dbg_sync_packed_sys = {corr_peak_sys[7:0], dbg_sync_cnt_sys[23:0]}`. Header
 Z. 26 erwähnt das nicht; nur Live-Code zeigt die Packung.
- **REG_BNCH_BLK1_2..6** liegen oberhalb 0xFF (Adresse 0x100..0x110) — die
 7-bit-Decode-Konstanten `7'h40`..`7'h44` reichen über die 0x100-Grenze hinaus,
 aber das ist OK, weil `[8:2]` 7-bit ist (deckt 0x000..0x1FC ab).
