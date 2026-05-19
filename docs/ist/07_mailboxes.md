# IST 07 — Mailboxes, DMA-Bridge, LMAC-Wrapper
Stand: 2026-05-17

Quellen:
- `rtl/lmac/tetra_indirect_mailbox.v` (95 Zeilen) — generisches Read-Side
- `rtl/lmac/tetra_indirect_mailbox_wr.v` (188 Zeilen) — generisches Write-Side
- `rtl/lmac/tetra_demand_mailbox.v` (175 Zeilen) — mm=2 UL-Demand Snapshot
- `rtl/lmac/tetra_grp_demand_mailbox.v` (166 Zeilen) — mm=7 Group-Attach Demand
- `rtl/lmac/tetra_reply_mailbox.v` (160 Zeilen) — SW-pulled Reply
- `rtl/lmac/tetra_voice_filler_mailbox.v` (78 Zeilen, Phase 7 G.8) — DL voice-slot SCH/F filler
- `rtl/lmac/tetra_voice_nub_read_mailbox.v` (165 Zeilen, Phase C) — UL NUB type-5 bits SW-readable
- `rtl/infra/tetra_tx_pdu_mailbox.v` (314 Zeilen) — 4-Slot TX-PDU-Submit
- `rtl/infra/tetra_axi_dma_bridge.v` (263 Zeilen) — RX-S2MM-Bridge
- `rtl/lmac/tetra_lmac.v` (355 Zeilen) — Struktureller LMAC-Wrapper

## tetra_indirect_mailbox.v (95 Zeilen)

**Parameter:** `NUM_WORDS = 16`, `INDEX_WIDTH = 4`.

**Ports:**
- IN `clk_sys` (1), `rst_n_sys` (1)
- IN `data_words_sys` (NUM_WORDS*32) — Wrapper liefert Wortarray
- IN `push_valid_sys` (1), `push_drop_sys` (1)
- IN `index_sys` (INDEX_WIDTH), `ack_pulse_sys` (1)
- OUT `pending_sys` (1), `drop_cnt_sys` (16), `data_out_sys` (32)

**Funktion:** Geteilter Sub-Block für "RTL-Push, AXI-Pull"-Mailboxes. Hält ein
Pending-Flag, einen 16-bit-saturierenden Drop-Counter und liefert
`data_out_sys = data_words_sys[index_sys]` kombinatorisch (default 0 wenn
`index ≥ NUM_WORDS`).

**State:**
- `pending_r_sys`: 0=EMPTY, 1=FULL. Set bei `push_valid & ~pending`, Clear bei `ack_pulse`.
- `drop_cnt_r_sys[15:0]`: +1 bei `push_drop_sys`, saturiert bei `16'hFFFF`.

**Pipeline-Latenz:** Push→pending=1: 1 Zyklus. Read: 0 Zyklen (kombi).

**Nachbarn:**
- ↑ Eingebettet in `tetra_demand_mailbox` (Z. 154) und `tetra_grp_demand_mailbox` (Z. 145).
- ↓ keine.

**Auffälligkeiten:** keine; reines Hilfsmodul mit `R1/R2/R4/R10`-Compliance.

## tetra_indirect_mailbox_wr.v (188 Zeilen)

**Ports:**
- IN `clk_sys`, `rst_n_sys`
- IN `index_sys[3:0]`, `wdata_sys[31:0]`, `wr_en_sys`, `go_pulse_sys`
- OUT `rdata_sys[31:0]`, `words_flat_sys[16*32-1:0]`, `go_pulse_out_sys`

**Funktion:** 16 × 32-bit Word-Storage, AXI-getriebenes Schreiben über Index/Data
mit `wr_en_sys`. Wrapper bekommt sowohl `rdata_sys` (combinational read-mux) als
auch `words_flat_sys` (flach für Field-Slicing). `go_pulse_sys` wird direkt nach
`go_pulse_out_sys` durchgereicht.

**State:** 16 explizite `reg [31:0] w0_r_sys`..`w15_r_sys` (NICHT als Array — R3-Konformität).

**Pipeline-Latenz:** Schreiben: 1 Zyklus. Lesen: 0 Zyklen.

**Nachbarn:**
- ↑ Eingebettet in `tetra_reply_mailbox` (Z. 102).
- ↓ keine.

**Auffälligkeiten:** Header sagt explizit "NUM_WORDS fixed at 16 — generalising to N
would defeat R3 trivially".

## tetra_demand_mailbox.v (175 Zeilen)

Phase X.1 Wrapper über `tetra_indirect_mailbox`.

**Ports:**
- Push (RTL→Mailbox): `demand_parsed_valid_sys`, `demand_ul_ssi_sys[23:0]`,
 `demand_gssi_count_sys[2:0]`, `demand_gssi_array_sys[71:0]`,
 `demand_class_array_sys[8:0]`, `demand_loc_upd_type_sys[2:0]`,
 `demand_la_sys[13:0]`.
- Pull: `index_sys[3:0]`, `ack_consumed_pulse_sys`, `data_word_sys[31:0]`,
 `pending_sys`, `drop_cnt_sys[15:0]`.

**Funktion:** Beim ersten `demand_parsed_valid` ohne `pending` werden alle Felder
in Latches kopiert (`ssi_lat_sys`, `count_lat_sys`, `gssi_arr_lat_sys`,
`class_arr_lat_sys`, `loc_upd_type_lat_sys`, `la_lat_sys`). Spätere Pushes mit
`pending=1` fallen weg und inkrementieren den Drop-Counter im Sub-Block.

**Word-Layout (W0..W7, W8..W15 reserviert):**
- W0: `{8'hA5, 3'd0, count[2:0], loc_upd_type[2:0], 15'd0}` — Magic `0xA5` markiert mm=2.
- W1: `{8'd0, ssi[23:0]}`
- W2: `{18'd0, la[13:0]}`
- W3/W4/W5: gssi_array[23:0]/[47:24]/[71:48]
- W6: `{23'd0, class_array[8:0]}`
- W7: `{16'd0, drop_cnt[15:0]}`

**State:** Latches + Sub-Block-FSM (EMPTY↔FULL).

**Pipeline-Latenz:** Push→Latch+Pending=1: 1 Zyklus.

**Nachbarn:**
- ↑ `tetra_zynq_top.v:2983` (`u_demand_mailbox`).
- ↓ `tetra_indirect_mailbox`.

**Auffälligkeiten:**
- Phase X.1 Tag.
- Test-Coverage-Kommentar: "tb_demand_mailbox 32/32".

## tetra_grp_demand_mailbox.v (166 Zeilen)

Phase Y.1.b Wrapper für mm=7 U-ATTACH-DETACH-GROUP-IDENTITY.

**Ports (zusätzliche Snapshot-Felder vs mm=2):**
- `grp_rec_count_sys[1:0]`, `grp_attach_detach_mode_sys`,
 `grp_group_identity_report_sys`, `grp_adi_array_sys[2:0]`,
 `grp_at_array_sys[5:0]`.

**Word-Layout (W0..W6, W7..W15 reserviert):**
- W0: `{8'hA7, 3'd0, rec_count[1:0], atd_mode, group_identity_report, 17'd0}` — Magic `0xA7`.
- W1: `{8'd0, ssi[23:0]}`
- W2/W3/W4: gssi_array[23:0]/[47:24]/[71:48]
- W5: `{14'd0, at_array[5:0], adi_array[2:0], class_array[8:0]}`
- W6: `{16'd0, drop_cnt[15:0]}`

**State/Latenz/Nachbarn:** wie demand_mailbox; instanziiert in
`tetra_zynq_top.v:3277` als `u_grp_demand_mailbox`.

**Auffälligkeiten:** Header verweist auf ETSI EN 300 392-2 §16.10.x.

## tetra_reply_mailbox.v (160 Zeilen)

Phase X.2 SW-gepullter Reply, basiert auf `tetra_indirect_mailbox_wr`.

**Ports (zentrale Field-Outputs):**
- AXI Side: `index_sys[3:0]`, `wdata_sys[31:0]`, `wr_en_sys`, `go_pulse_sys`, `rdata_sys[31:0]`.
- Field-Outputs in clk_sys-Domain (alle aus combinational Slicing der 16 Words):
 - `mb_ssi_sys[23:0]`, `mb_la_sys[13:0]`, `mb_addr_type_sys[2:0]`, `mb_result_sys[1:0]`
 - `mb_gila_gssi_sys[23:0]`, `mb_gila_class_sys[2:0]`, `mb_gila_lifetime_sys[1:0]`, `mb_gila_present_sys`
 - `mb_encryption_sys[1:0]`, `mb_auth_result_sys[1:0]`
 - `mb_go_pulse_sys`
 - **Phase Y.2 Raw-Mode (W9..W13):**
 - `mb_raw_mode_flag_sys = W9[31]`
 - `mb_raw_mle_pd_sys[2:0] = W9[12:10]` (0=defaultMM, 1=MM, 2=CMCE — Phase 7 G.4)
 - `mb_raw_nr_sys = W9[9]`, `mb_raw_ns_sys = W9[8]`, `mb_raw_mm_len_sys = W9[7:0]`
 - `mb_raw_mm_bits_sys[127:0] = {W13, W12, W11, W10}`

**Word-Layout (verbindlich, Header Z. 17–36):**
- W0: `{8'd0, ssi[23:0]}`
- W1: `{18'd0, la[13:0]}`
- W2: `{29'd0, addr_type[2:0]}`
- W3: `{30'd0, result[1:0]}`
- W4: `{8'd0, gila_gssi[23:0]}`
- W5: `{27'd0, gila_class[2:0], gila_lifetime[1:0]}`
- W6: `{31'd0, gila_present}`
- W7: `{30'd0, encryption[1:0]}` (Reserved)
- W8: `{30'd0, auth_result[1:0]}` (Reserved)
- W9: `{raw_mode_flag, 18'd0, raw_mle_pd[2:0], raw_nr, raw_ns, raw_mm_len[7:0]}`
- W10..W13: raw_mm_bits[31:0..127:96]
- W14, W15: reserviert (32'd0).

**Funktion:** Reines Storage + Slicing. Kein Latch, kein FSM. SW schreibt
Wörter über `wr_en_sys`-Pulse + `index_sys`, dann `go_pulse_sys` → wird zu
`mb_go_pulse_sys` weitergereicht.

**State:** keine.

**Pipeline-Latenz:** Schreiben: 1 Zyklus. Field-Output: 0 Zyklen ab Write-Commit.

**Nachbarn:**
- ↑ `tetra_zynq_top.v:3162` (`u_reply_mailbox`).
- ↓ `tetra_indirect_mailbox_wr`.

**Auffälligkeiten:**
- Header sagt "Module header / behavior bit-exact preserved (tb_reply_mailbox 32/32)".
- Raw-Mode (Phase Y.2 Variante A) ist Multi-PDU-Bypass für mm=11
 D-ATTACH-DETACH-GRP-ID-ACK. Bei `raw_mode_flag=1` wird der dloc-Encoder umgangen,
 bei `=0` ist mm=2 ACCEPT bit-identisch zur Vorversion.
- Phase X.4-Kommentar: SW path ist primärer Pfad (REG_REPLY_USE_SW @0x230 default=1).

## tetra_voice_filler_mailbox.v (78 Zeilen, Phase 7 G.8)

**Zweck:** AXI-writable 16-Word-Storage hält einen pre-encoded SCH/F type-5
Burst (432 Bits) den `tetra_burst_dispatcher` im aktiven Group-Call-Voice-Slot
emittiert. SW (`sw/tetra_voice_filler.c` initial install, `sw/tetra_voice_pipe.c`
per-frame update) ist Encoder, dieses Modul ist reine Bit-Pipe.

**Wort-Layout (16 × 32-bit, indirekt via `REG_VOICE_FILLER_INDEX/DATA` @ 0x270/0x274):**
- W0..W13: type-5 bits 0..431, packed LSB-first innerhalb jedes Worts
 (W0[0]=bit 0, W0[31]=bit 31; W13[15:0]=bits 416..431, W13[31:16] padding=0)
- W14[0]: `filler_valid` (SW schreibt 1 nach Load, 0 zum Clear; HW-Reset auf 0)
- W15: reserviert

**Outputs (combinational an `burst_dispatcher`):**
- `blk1_sys[215:0]` = words_flat[215:0] (= BKN1/NDB1 type-5 bits, MSB = erstes Symbol on air)
- `blk2_sys[215:0]` = words_flat[431:216] (= BKN2)
- `valid_sys` = W14[0]
- `go_pulse_out_sys` = informationaler GO-Puls aus indirect_mailbox_wr

**Nachbarn:** ↑ `tetra_zynq_top.v` (`u_voice_filler_mailbox`). ↓ `tetra_burst_dispatcher`
(`vfill_blk1_sys`, `vfill_blk2_sys`, `vfill_valid_sys` Inputs).

**Auffälligkeiten:** keine FSM, kein Reset des Inhalts (nur W14[0] auf Reset 0).
SW kann den Inhalt jederzeit überschreiben — bei Voice-Stream wird er alle ~60 ms
durch `tetra_voice_pipe_tick` nachgefüllt mit dem dekodierten + re-encodeten
UL-NUB-Voice-Frame.

## tetra_voice_nub_read_mailbox.v (165 Zeilen, Phase E2 ab 2026-05-18)

**Zweck:** Buffer für UL-NUB-Voice-Bursts auf SW-Seite. `tetra_ul_nub_capture`
emittiert per NUB-Sync **432 × 4-bit signed Soft-Werte** (= 1728 bit total, ab
Phase E2 commit `cae5108`) + `coded_valid_sys`-Puls; dieses Modul latcht den
Burst, setzt `valid` und stellt **54 × 32-bit Words** via Indirect-Read
(`REG_VOICE_NUB_READ_INDEX/DATA` @ 0x280/0x284) bereit. INDEX-Register ist
6-bit (war 4-bit vor E2). SW pollt `REG_VOICE_NUB_READ_STATUS` @ 0x288, liest
54 Words, ACKt via 0x28C.

**Word-Layout (Phase E2):**
- 54 × 32-bit packs 432 nibbles = `coded_softs_sys`
- Word `Wn` bits `[i*4 +: 4]` = soft-value für coded-bit `Wn*8 + i` (i=0..7)
- Index-Konvention: coded_softs[431] = first BKN1 bit on air (MSB-first im RTL)
- SW liest mit bit-reverse: `softs_out[431 - coded_idx] = nib_signed`
- Siehe `sw/tetra_voice_pipe.c::read_nub_softs`

**Soft-Konvention:** positive soft = bit '1', negative = bit '0'. Wert ist
arithmetic-right-shift des differential-product `−(I_cur·I_prev + Q_cur·Q_prev)`
(I-Achse, analog für Q). Sign-Inversion ist beabsichtigt für Konventions-
Kongruenz zum SW-Viterbi.

**Outputs:** AXI-Read-Port + interner `valid`-Flag-Register. SW-ACK clearet.

**Auffälligkeiten:** Single-Buffer (kein FIFO) — wenn neuer Burst arrives bevor
SW alten ACKt, geht der alte verloren (counter `bursts_captured_sys` zählt im
NUB-Capture trotzdem hoch). Bei daemon-poll-Intervall 10 ms und NUB-Burst-
Rate ~60 ms ist das in Praxis kein Problem.

**Nachbarn:** ↑ `tetra_zynq_top.v` (`u_voice_nub_read_mailbox`). ↓ AXI-Side
(SW-Daemon `sw/tetra_voice_pipe.c`).

## tetra_ul_demand_body_mailbox.v (126 Zeilen, Phase 1A Vorbereitung, NOT IN ZYNQ_TOP)

**Status:** Modul existiert (commit `47def0e`), ist aber **noch nicht** im
`tetra_zynq_top.v` instantiiert. Vorbereitung für künftigen SW-Move von
`tetra_ul_demand_ie_parser` (~3500 LUT).

**Zweck (geplant):** Snapshot raw 129-bit MM-Body + SSI + mm_pdu_type aus
`tetra_ul_demand_reassembly` → 16 × 32-bit Indirect-Mailbox für SW-Walker.
Layout: W0 magic+mm_type+body[128], W1 ssi, W2-W5 body[127:0], W7 drop_cnt.

**Verbleibend:** zynq_top-Integration + AXI-Reg-Mapping + SW-Parser-Port.
Siehe Memory `project_fpga_slice_bottleneck` für Roadmap.

## tetra_tx_pdu_mailbox.v (314 Zeilen)

Phase H.4.2 — 4-Slot-Mailbox für ARM PS, um DL-Reply-PDUs in den TX-Pfad zu
schubsen. **Wichtige IST-Beobachtung:** Dieses Modul ist im aktuellen Top-Level
NICHT instanziiert (keine `tetra_tx_pdu_mailbox`-Instanz in `tetra_zynq_top.v`).
Datei existiert, ist aber nicht aktive Datenpfad.

**Parameter:** `PDU_WIDTH=432`, `NUM_SLOTS=4`, `SLOT_IDX_W=2`, `HINT_TN_W=2`,
`HINT_FN_W=5`, `HINT_MN_W=6`, `HINT_BT_W=2`, `PDU_WORDS=14`.

**Ports:**
- AXI-Side: `wr_data_pulse_axi` + `slot_idx_axi` + `word_idx_axi[3:0]` + `wr_data_axi[31:0]`.
 `wr_hint_pulse_axi` + `hint_slot_idx_axi` + `hint_data_axi[14:0]`.
 `wr_submit_pulse_axi` + `submit_mask_axi[3:0]`. `status_axi[31:0]` (kombi-Mux).
- TX-Side: `cur_tn_sys`, `cur_fn_sys`, `cur_mn_sys`, `cur_burst_type_sys`, `cur_query_valid_sys`.
 Outputs `pdu_match_valid_sys`, `pdu_bits_sys[431:0]`, `pdu_burst_type_sys[1:0]`,
 `pdu_slot_idx_sys[1:0]` + `pdu_consumed_sys` (Eingang).

**Storage:**
- `pdu_storage_sys [0:NUM_SLOTS-1] [PDU_WIDTH-1:0]` mit `(* ram_style = "distributed" *)`.
- `hint_storage_sys [0:NUM_SLOTS-1] [14:0]`.
- `state_sys [0:NUM_SLOTS-1] [1:0]`.

**Hint-Layout (15 bit):** `{tn[1:0], fn[4:0], mn[5:0], burst_type[1:0]}` — fn=31
und mn=63 sind Wildcards.

**State (per Slot):**
- 2'b00 = `S_EMPTY`
- 2'b01 = `S_STAGING`
- 2'b10 = `S_IN_FLIGHT`
- Transitions:
 - EMPTY → STAGING bei erster Data- oder Hint-Write auf den Slot.
 - STAGING → IN_FLIGHT bei `wr_submit_pulse_axi & submit_mask_axi[i]`.
 - IN_FLIGHT → EMPTY bei `pdu_consumed_sys & (pdu_slot_idx_sys == i)`.

**Match-Logik:** Pro Slot vier strikte Equality-Checks (TN, FN, MN, BT) plus
Wildcard auf FN=31 / MN=63. Lowest-Index-Priority-Encoder (case-Statement Slots
0..3). Sieger wird 1 Zyklus später als `pdu_match_valid_sys`-Pulse + zugehörigem
`pdu_bits/burst_type/slot_idx` ausgegeben.

**Status-Word-Layout (`status_axi`):**
- `[31:24]` reserved
- `[23:20]` slot3 status (bit0=EMPTY, bit1=STAGING, bit2=IN_FLIGHT, bit3=reserved)
- `[19:16]` slot2
- `[15:12]` slot1
- `[11:8]` slot0
- `[7:0]` reserved

**Resource-Estimate (Header):** ~1728 FF storage + ~250 LUT.

**Auffälligkeiten:**
- Header-Tag: Phase H.4.2.
- Nicht instanziiert im Top → tote Datei im aktuellen Build.

## tetra_axi_dma_bridge.v (263 Zeilen)

S2MM-Bridge (PL → PS), packt LMAC-Blöcke in AXI4-Stream.

**Parameter:** `MAX_BLOCK_BITS=432`, `MAX_DATA_WORDS=14`.

**Ports:**
- IN `clk_sys`, `rst_n_sys`
- IN `mac_data_sys[431:0]`, `mac_len_sys[9:0]`, `mac_slot_sys[1:0]`,
 `mac_burst_type_sys[1:0]`, `mac_frame_sys[15:0]`, `mac_valid_sys`
- OUT `mac_ready_sys` (= `state == IDLE`)
- AXI4-Stream Master: `m_axis_tvalid`, `m_axis_tready`, `m_axis_tdata[31:0]`,
 `m_axis_tkeep[3:0]`, `m_axis_tlast`
- OUT `dma_block_count_sys[15:0]`, `irq_mac_block_sys` (1-Cycle-Pulse pro Block),
 `fifo_empty_sys` (= `state == IDLE`), `fifo_full_sys` (= 0, hardwired)
- IN `reset_counters_sys`

**Funktion:** Bei `mac_valid_sys & state==IDLE` werden Header und Payload gelatcht.
Header (Word 0):
- `[31:30]` = `mac_slot_sys`
- `[29:28]` = `mac_burst_type_sys`
- `[27:16]` = `mac_len_sys` (12-bit Feld)
- `[15:0]` = `mac_frame_sys`

Payload: `mac_data_sys` (216 bit) wird auf 448 bit (14×32) zero-extended in
`payload_reg_sys`. Anzahl Datenwörter = `ceil(mac_len/32)`. Auf `S_SEND` werden
Header + N Datenwörter sequentiell aus dem Flat-Bus ausgegeben.

**TKEEP für letztes Wort:**
- last_bits == 0 → 4'hF
- > 24 → 4'hF
- > 16 → 4'h7
- > 8 → 4'h3
- sonst → 4'h1

**State (2-bit):**
- `S_IDLE` (00): wartet auf `mac_valid_sys`.
- `S_SEND` (01): tvalid=1, `word_cnt_sys` zählt 0..N hoch bei jedem Handshake.
 Bei `word_cnt == num_data_words & tready` → zurück zu IDLE, IRQ-Puls,
 Counter +1.

**Pipeline-Latenz:** 1 Zyklus IDLE→SEND, dann pro Wort 1 Handshake (variable
Latenz wegen `m_axis_tready`).

**Nachbarn:**
- ↑ `tetra_zynq_top.v:972` (`u_dma_bridge`). Treibt `m_axis_*` Top-Ports.
- ↓ keine.

**Auffälligkeiten:** `fifo_full_sys` ist konstant 0 (kein FIFO, direkter Stream).
TX-Pfad (MM2S, PS→PL) ist laut Header nicht implementiert.

## tetra_lmac.v (355 Zeilen)

Strukturelles Wrapper-Modul mit RX- und TX-Channel-Coding-Submodulen.

**Parameter:** `BLOCK_BITS=216`, `LFSR_WIDTH=32`.

**Ports:**
- RX-Side (alle clk_sys):
 - `rx_block1_sys[215:0]`, `rx_block2_sys[215:0]`, `rx_bb_sys[29:0]`, `rx_slot_valid_sys`
 - `lfsr_init_sys[31:0]`, `load_lfsr_sys`, `punct_pattern_sys[2:0]`
 - OUT `rx_decoded_bit_sys`, `rx_decoded_valid_sys`, `rx_block_done_sys`,
 `rx_path_metric_sys[15:0]`
 - OUT `rx_aach_data_sys[13:0]`, `rx_aach_done_sys`, `rx_aach_error_sys`
 - OUT `rx_crc_ok_sys`, `rx_crc_valid_sys`, `rx_stolen_sys`
- TX-Side:
 - IN `tx_data_in_sys`, `tx_data_valid_sys`, `tx_flush_sys`
 - IN `tx_aach_in_sys[13:0]`, `tx_aach_valid_sys`
 - OUT `tx_block1_sys[215:0]`, `tx_block2_sys[215:0]`, `tx_bb_sys[29:0]`, `tx_block_ready_sys`

**Submodule (interne Instanzen):**
- RX:
 - `u_rx_scrambler` — `tetra_scrambler` (descramble mode, MSB-first auf `rx_block1_sys`).
 - `u_rx_deinterleaver` — `tetra_deinterleaver` (`block_size=216`).
 - `u_depuncturer` — `tetra_depuncture_r23` (rate-2/3 → 4 soft per Stage).
 - `u_viterbi` — `tetra_viterbi_decoder` (`num_stages=144` fest verdrahtet für BNCH).
 - `u_rx_crc` — `tetra_crc16` (Continuous Check Mode, init bei `block_done`).
 - `u_rm` — `tetra_reed_muller(30,14)` (Decode + Encode-Dual-Use für AACH).
 - `u_steal_detect` — `tetra_steal_detect` (Slot 0 hardwired).
- TX:
 - `u_rcpc_encoder` — `tetra_rcpc_encoder(K=5)`.
 - Inline Puncture-Serializer (Z. 294–312): liefert 1-bit-Stream aus 2-bit Puncture-Output.
 - `u_tx_interleaver` — `tetra_interleaver`.
 - `u_tx_scrambler` — `tetra_scrambler` (TX-Pfad).
 - (Reed-Muller-Encode-Pfad teilt sich Instanz mit RX `u_rm`.)

**Funktion (Phase 3, Header):** RX-Pfad eines Slots:
`Block1 → Descrambler → Deinterleaver → Depuncturer → Viterbi → CRC-16` und
parallel `BB → Reed-Muller (decode) → AACH`. TX-Pfad: `Payload → RCPC → Interleaver
→ Scrambler` und `AACH → Reed-Muller (encode) → BB`. Aktueller IST-Stand:
`tx_block1_sys = tx_block2_sys = {BLOCK_BITS{1'b0}}` (Z. 351–352) — die volle
S→P-Akkumulation existiert nicht; ARM liefert vorencodierte Blöcke per AXI-DMA.

**State:** keine eigene FSM im Wrapper; nur strukturelles Verdrahten.

**Pipeline-Latenz:** Slot-pipeline (siehe Submodule). Output `tx_block1/2_sys` ist
konstant 0 — kein TX-Datenpfad aktiv über dieses Modul.

**Nachbarn:**
- ↑ `tetra_zynq_top.v:843` (`u_lmac`) — bekommt `rx_block1/2_sys/rx_bb_sys` vom
 `tetra_rx_chain`, RX-Outputs gehen an Accumulator (Z. 901ff.) → DMA-Bridge.
- ↓ tetra_scrambler (×2), tetra_deinterleaver, tetra_depuncture_r23,
 tetra_viterbi_decoder, tetra_crc16, tetra_reed_muller, tetra_steal_detect,
 tetra_rcpc_encoder, tetra_interleaver.

**Auffälligkeiten:**
- TX-Datenpfad ist tot: `tx_block1/2_sys` = 0, `tx_data_in_sys = tx_data_valid_sys
 = tx_flush_sys = 0` werden im Top-Level (Z. 869–872) als feste Konstanten
 übergeben.
- `tx_aach_in_sys = 14'd0`, `tx_aach_valid_sys = 1'b0` ebenfalls (Z. 872–873).
- `rx_stolen_sys` ist hardwired auf Slot 0 (`steal_active_w[0]`, Z. 263).
- Header-Notiz: "Phase 3 structural only" + "soft-decision requires LLR from
 the demodulator (future work)".
