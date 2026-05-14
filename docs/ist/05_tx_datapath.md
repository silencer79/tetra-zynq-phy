# IST — Kapitel 5: DL TX Datapath + Channel Coding
Stand: 2026-05-14
Quelle: rtl/tx/*.v + rtl/lmac/tetra_{crc16,reed_muller,interleaver,scrambler,rcpc_encoder,sch_*_encoder,mac_resource_*,dl_*,chan_alloc_encoder,basic_slotgrant_encoder,d_location_update_*}.v

## Inhaltsverzeichnis

### TDMA-Timebase + Schedule
1. tetra_tdma_timebase.v
2. tetra_slot_schedule.v
3. tetra_slot_content_mux.v

### Channel-Coding-Primitive (LMAC)
4. tetra_crc16.v
5. tetra_reed_muller.v
6. tetra_interleaver.v
7. tetra_scrambler.v
8. tetra_rcpc_encoder.v

### Channel-Encoder Top-Level (LMAC)
9. tetra_sb1_encoder.v        (BSCH 60→120)
10. tetra_sch_f_encoder.v     (268→432)
11. tetra_sch_hd_encoder.v    (124→216)
12. tetra_aach_encoder.v      (14→30, FSM-Variante)
13. tetra_aach_rm_encoder.v   (14→30, kombinatorisch)

### PDU-Builder + IE-Packer (LMAC)
14. tetra_basic_slotgrant_encoder.v
15. tetra_chan_alloc_encoder.v
16. tetra_d_location_update_encoder.v
17. tetra_d_location_update_reject_encoder.v
18. tetra_mac_resource_bl_ack_builder.v
19. tetra_mac_resource_dl_builder.v
20. tetra_dl_pdu_builder.v

### Queue + Scheduler (LMAC)
21. tetra_dl_signal_queue.v
22. tetra_dl_signal_scheduler.v

### Burst-Dispatch + Modulator + Frontend (TX)
23. tetra_burst_dispatcher.v
24. tetra_burst_builder.v
25. tetra_pi4dqpsk_mod.v
26. tetra_rrc_filter.v
27. tetra_tx_inv_sinc.v
28. tetra_tx_frontend.v
29. tetra_tx_chain.v

---

## TDMA-Timebase + Schedule

### tetra_tdma_timebase.v  (228 Zeilen)
**Ports:** `clk_sys, rst_n_sys, sym_en, sync_load_strobe, sync_tn_in[1:0], sync_fn_in[4:0], sync_mn_in[5:0], sync_hn_in[5:0] → sym_cnt[7:0], tn[1:0], fn[4:0], mn[5:0], hn[5:0], slot_pulse, tdma_tick`
**Funktion:** TX-seitige TDMA-Counter. Erzeugt 0-basierte (TN, FN, MN, HN) für den gerade aktiven Slot. Jeder `sym_en`-Strobe inkrementiert `sym_cnt`; bei 254→0 wrappt es TN, dann FN bei 3→0, MN bei 17→0, HN bei 59→0. HN wrappt frei bei 63→0.
**State:** Keine separate FSM, nur Counter. Pending-Sync-Load wird in `sync_load_pending_sys` gelatcht; auf nächstem `sym_en` (oder gleichzeitig) wird auf SW-gelieferte Werte committed (`sym_cnt <= 0`).
**Pipeline-Latenz:** `tdma_tick` registriert auf der `sym_en`-Kante, die `sym_cnt 254→0` triggert. `slot_pulse` ist `tdma_tick` um 1 clk_sys-Zyklus verzögert.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine Instanziierungen (nur Counter).
**Auffälligkeiten:** Kommentar nennt explizit "0-basierte Counter, anders als RX-side `tetra_frame_counter.v`". Auf `sync_commit_sys` wird `tdma_tick` unterdrückt (`!sync_commit_sys` Gate).

### tetra_slot_schedule.v  (206 Zeilen)
**Ports:** Port-A AXI: `clk_axi, rst_n_axi, axi_we, axi_addr[7:0], axi_wdata[31:0], axi_wstrb[3:0], axi_re → axi_rdata[31:0]`. Port-B RTL: `clk_sys, rst_n_sys, sched_b_addr_sys[8:0] → schedule_entry_sys[15:0]`.
**Funktion:** Dual-Port BRAM, 288×16 bit, addressiert über `mn[1:0]*72 + fn*4 + tn[1:0]`. Liefert 16-bit Schedule-Entry: `[15:12]=class, [11:6]=idx, [5:4]=burst_type, [3]=ndb2, [2]=enable, [1]=sys_time_inject, [0]=reserved`. AXI sieht 144 32-bit-Worte (je 2 Entries gepackt).
**State:** Keine FSM. Memory in 2 Bänken (`mem_lo[144]`, `mem_hi[144]`) split für Vivado-BRAM-Inferenz; Bank-Auswahl per `addr[0]`, Pipeline-Register für LSB.
**Pipeline-Latenz:** 1 clk_sys-Zyklus von `sched_b_addr_sys` zu `schedule_entry_sys`.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:** Kommentar dokumentiert "H.0.9 BRAM-Inferenz-Fix (2026-04-27)" — vorher single mem[288×16], Vivado-Warning Synth 8-4767 hat es als ~4900 LUTs aufgelöst. `rst_n_sys`/`rst_n_axi` sind tot (`_unused_rst_ok_*` keepalive); kein async Reset auf BRAM-Reads (Vivado-Template-Konformität).

### tetra_slot_content_mux.v  (227 Zeilen)
**Ports:** `clk_sys, rst_n_sys, tn_sys[1:0], fn_sys[4:0], mn_sys[5:0], slot_pulse_sys, tdma_tick_sys, sched_data_sys[15:0] → sched_addr_sys[8:0], sched_entry_reg_sys{0..3}[15:0], dbg_sched_entry{0..3}_sys[15:0]`.
**Funktion:** Prefetch-FSM für die 4 Schedule-Entries des nächsten Frames. Trigger: `slot_pulse_sys && tn_sys==3` (= Frame-Wrap kommt) ODER `first_refresh_pending_sys` (one-shot nach Reset). 4 Reads in S_RD0..S_RD3, Daten gelatcht in `sched_entry_reg_sys0..3_r`.
**State:** 6 Zustände `S_IDLE, S_RD0, S_RD1, S_RD2, S_RD3, S_CAP3`. `S_RD0` adressiert TN=0, lädt im darauffolgenden Zyklus in reg0; analog für TN=1..3. Adresse aus `mn_next_low2*72 + fn_next*4 + tn_for_addr`.
**Pipeline-Latenz:** 5 clk_sys nach Trigger bis alle 4 Entries gelatcht (S_RD0 → S_CAP3).
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine (instanziiert kein anderes Modul).
**Auffälligkeiten:** Header dokumentiert "Phase Y.3 — body/meta latches and SW-bank dispatch were moved into tetra_burst_dispatcher". `tdma_tick_sys` Input ist im aktuellen Code unbenutzt (`_unused_scm_sys = tdma_tick_sys` Keepalive). Modul ist nach Y.3 nur noch BRAM-Prefetch.

---

## Channel-Coding-Primitive

### tetra_crc16.v  (146 Zeilen)
**Ports:** `clk_sys, rst_n_sys, init_sys, done_in_sys, data_in_sys, data_valid_sys → crc_out_sys[15:0], crc_valid_sys, crc_ok_sys`.
**Funktion:** Serieller CRC-16-CCITT (Poly 0x1021, Init 0xFFFF). Pro `data_valid_sys` ein Bit verarbeitet. TX-Modus: nach `done_in_sys` ist `crc_out_sys` der FCS (Ones-Complement vor Aussendung beim Caller). RX-Modus: vergleicht Residue gegen `0x1D0F`, treibt `crc_ok_sys`.
**State:** Keine FSM, nur 16-bit Shift-Register.
**Pipeline-Latenz:** `crc_valid_sys` und `crc_ok_sys` fired 1 clk_sys nach `done_in_sys`.
**Nachbarn:** ↑ tetra_lmac (RX-Pfad), tetra_ul_sch_hu_decoder. ↓ Keine.
**Auffälligkeiten:** Wird NICHT direkt vom DL-TX-Pfad instanziiert — die SCH-Encoder (sb1, sch_hd, sch_f) haben CRC inline; nur RX nutzt diesen Block.

### tetra_reed_muller.v  (302 Zeilen)
**Ports:** `clk_sys, rst_n_sys, encode_data_in[13:0], encode_valid → encode_data_out[29:0], encode_done`. Decoder-Path: `decode_data_in[29:0], decode_valid → decode_data_out[13:0], decode_done, decode_error`.
**Funktion:** Generischer RM(30,14)-Codec mit Encoder + Hard-Decision-Decoder. Encoder ist kombinatorisch (Matrix-Multiply `c = u·G`), 1 Zyklus Latenz. Decoder iteriert 2^14 = 16384 Kandidaten, trackt minimalen Hamming-Abstand.
**State:** Decoder-FSM 3 Zustände `S_IDLE, S_DECODE, S_OUTPUT`. S_DECODE inkrementiert `cand_sys[13:0]`, vergleicht jeden Kandidaten gegen `r_latch_sys`, hält `best_m_sys` + `best_dist_sys`.
**Pipeline-Latenz:** Encoder: 1 clk_sys. Decoder: ~16385 clk_sys (~163 µs @100 MHz).
**Nachbarn:** ↑ tetra_lmac (RX-AACH-Decode). ↓ Keine.
**Auffälligkeiten:** Wird im DL-TX-Pfad NICHT instanziiert — `tetra_aach_encoder.v` und `tetra_aach_rm_encoder.v` haben jeweils eine eigene unrolled RM(30,14)-Funktion mit eigenen Matrix-Konstanten. Die G-Matrix dieses generischen Decoders (`G_ROW00..G_ROW13`) ist STRUKTURELL ANDERS als die Matrix im AACH-Encoder (`RM_ROW00..RM_ROW13`) — RM_ROW-Werte stammen aus `sw/tetra_hal.c` RM_30_14_GEN, G_ROW-Werte aus RM(2,5)-Shortening.

### tetra_interleaver.v  (185 Zeilen)
**Ports:** `clk_sys, rst_n_sys, block_size[8:0], data_in, data_in_valid → data_out, data_out_valid, block_done`.
**Funktion:** Bit-serieller multiplikativer Interleaver. FILL-Phase schreibt Eingangs-Bit i an `wr_addr = (a·i) mod K`. DRAIN-Phase liest 0..K-1 sequenziell. `a`-Parameter wählt aus `{11 für K=120, 101 für K=216, 103 für K=432}`.
**State:** 2 Zustände `S_FILL, S_DRAIN`. Wechselt bei `fill_done` bzw. `drain_done`.
**Pipeline-Latenz:** K clk_sys FILL + K clk_sys DRAIN; `data_out_valid` 1 Zyklus nach state==S_DRAIN.
**Nachbarn:** ↑ tetra_lmac. ↓ Keine.
**Auffälligkeiten:** Wird im DL-TX-Pfad NICHT instanziiert — die SCH-Encoder (sb1, sch_hd, sch_f) haben jeder eine eigene kombinatorische `*_interleave`-Funktion mit hardcodiertem `a` und `N`.

### tetra_scrambler.v  (135 Zeilen)
**Ports:** `clk_sys, rst_n_sys, lfsr_init[31:0], load_init, data_in, data_valid → data_out, data_out_valid`.
**Funktion:** Galois-LFSR-Scrambler, 32 bit, Polynom-Maske `0x04C11DB7`. Pro `data_valid` shiftet LFSR, XORs Output-Bit mit `data_in`. Symmetrisch (descramble = scramble).
**State:** Keine FSM, nur 32-bit LFSR.
**Pipeline-Latenz:** 1 clk_sys.
**Nachbarn:** ↑ tetra_lmac. ↓ Keine.
**Auffälligkeiten:** Wird im DL-TX-Pfad NICHT instanziiert — die SCH-Encoder haben jeweils inline Fibonacci-LFSR mit DIFFERENT TAPS (bits 0,6,9,10,16,20,21,22,24,25,27,28,30,31) und MSB-first Mask-Construction. Dieser Galois-LFSR hier nutzt ANDERE Polynom-Maske als die SCH-Encoder.

### tetra_rcpc_encoder.v  (214 Zeilen)
**Ports:** `clk_sys, rst_n_sys, data_in, data_valid, punct_pattern[2:0], flush → coded_bits[3:0], coded_valid, punct_out_bits[1:0], punct_valid, punct_out_cnt`.
**Funktion:** Rate-1/4-Mother-Code Convolutional Encoder, K=5, G1..G4. Liefert sowohl Mother-Rate-Output (4 bit) als auch Rate-2/3-Punctured-Output (G1+G2 für even, G1 für odd). Flush legt 4 Tail-Zeros nach letztem Daten-Bit.
**State:** 2 reg: `flush_active_sys`, `flush_cnt_sys[1:0]`. SR ist 4-bit Shift-Right.
**Pipeline-Latenz:** 1 clk_sys.
**Nachbarn:** ↑ tetra_lmac. ↓ Keine.
**Auffälligkeiten:** Wird im DL-TX-Pfad NICHT instanziiert — die SCH-Encoder haben inline Conv-Encoder mit eigenen `g1_w`/`g2_w` Computation und eigenem `bit_phase`-Puncturing.

---

## Channel-Encoder (LMAC)

### tetra_sb1_encoder.v  (291 Zeilen)
**Ports:** `clk_sys, rst_n_sys, cfg_system_code[3:0], cfg_colour_code[5:0], cfg_sharing_mode[1:0], cfg_ts_reserved_frames[2:0], cfg_u_plane, cfg_frame_18_ext, cfg_mcc[9:0], cfg_mnc[13:0], cfg_neighbour_cell_broadcast[1:0], cfg_cell_service_level[1:0], cfg_late_entry_info, encode_start_sys, sdb_slot_sys[1:0], frame_num_sys[4:0], multiframe_num_sys[5:0] → sb1_coded_sys[119:0], sb1_valid_sys`.
**Funktion:** BSCH-Encoder. Baut 60-bit SYNC-PDU aus Cell-Config + FN/MN, dann komplette Kette: CRC-16 → +4 Tail = 80 bit → rate-1/4 → punktiert auf rate 2/3 = 120 bit → multiplicative interleave (N=120, a=11) → Fibonacci-LFSR scramble init=3.
**State:** 5 Zustände `S_IDLE, S_CRC (60c), S_BUILD (1c), S_RCPC (80c), S_FINISH (1c)`.
**Pipeline-Latenz:** ~142 clk_sys total.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine (RCPC/Interleaver/Scrambler inline).
**Auffälligkeiten:** Scramble-Mask ist Compile-Time-Konstante (init=3 fix für BSCH). Interleaver ist Compile-Time-Funktion (Wire-Permutation). Conv-SR ist 4-bit "shift-left, oldest stored bit auf SR[3]", G-Polys als 5-bit-Masken.

### tetra_sch_f_encoder.v  (223 Zeilen)
**Ports:** `clk, rst_n, encode_start, info_bits[267:0], scramble_init[31:0] → coded_bits[431:0], coded_valid`.
**Funktion:** SCH/F-Encoder. 268-bit PDU → CRC-16 → +4 Tail = 288 bit → rate-1/4 punktiert auf 2/3 = 432 bit → multiplicative interleave (N=432, a=103) → cell-spezifischer Fibonacci-Scramble.
**State:** 6 Zustände `S_IDLE, S_CRC (268c), S_BUILD (1c), S_RCPC (288c), S_SCRAM (432c), S_FINISH (1c)`.
**Pipeline-Latenz:** ~991 clk_sys total.
**Nachbarn:** ↑ tetra_dl_pdu_builder, tetra_lmac (DL-Pfad), tetra_mle_registration_fsm, tetra_pre_reply_slotgrant. ↓ Keine.
**Auffälligkeiten:** `coded_valid` ist 1-Zyklus-Puls bei S_FINISH→S_IDLE; `coded_bits` bleibt latched bis nächstes encode. Header sagt "back-to-back encodes see independent pulses".

### tetra_sch_hd_encoder.v  (220 Zeilen)
**Ports:** `clk, rst_n, encode_start, info_bits[123:0], scramble_init[31:0] → coded_bits[215:0], coded_valid`.
**Funktion:** SCH/HD-Encoder. 124-bit PDU → CRC-16 → +4 Tail = 144 bit → rate-1/4 punktiert auf 2/3 = 216 bit → multiplicative interleave (N=216, a=101) → cell-spezifischer Fibonacci-Scramble.
**State:** 6 Zustände identisch zu sch_f, aber Counts sind `S_CRC (124c), S_RCPC (144c), S_SCRAM (216c)`.
**Pipeline-Latenz:** ~487 clk_sys total.
**Nachbarn:** ↑ tetra_lmac, tetra_pre_reply_blck. ↓ Keine.
**Auffälligkeiten:** Strukturidentisch mit sch_f, nur skaliert. Conv-Encoder + Interleaver + Scrambler-Mask alle inline.

### tetra_aach_encoder.v  (279 Zeilen)
**Ports:** `clk_sys, rst_n_sys, fn_sys[4:0], tn_sys[1:0], mn_low2_sys[1:0], colour_code_sys[5:0], mcc_sys[9:0], mnc_sys[13:0], signalling_active_sys, grant_pending_sys, grant_info_sys[13:0] → grant_consume_sys, voice_active_mask_sys[3:0], encode_start_sys → aach_coded_sys[29:0], aach_valid_sys`.
**Funktion:** Baut 14-bit AACH-Info aus FN/TN/MN%4 + Cell-Config, dann RM(30,14)-Encode + Fibonacci-LFSR-Scramble. Default-Logic-Pfad: F18 BSCH-Anker / F18 NDB2 BNCH / F18 TN!=0 SB-Slot / F1-17 TN=0 idle / F1-17 TN=0 reply / F1-17 TN!=0 traffic.
**State:** 3 Zustände `S_IDLE, S_MASK (30c), S_DONE (1c)`. S_MASK shiftet LFSR 30-mal, baut Mask-Bit für Bit.
**Pipeline-Latenz:** ~33 clk_sys total.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:** 
- Default-Logic enthält viele hardcodierte Per-Slot-Patterns (0x0049/0x0249/0x0040/0x2249/0x0009/0x2049/0x3000) mit Kommentar-Hinweisen "Gold-bit-genau 2026-05-04 Audit".
- Voice-Active-Mask-Pfad (`voice_active_mask_sys[tn_sys]`) rotiert je nach FN: 0x32CB (FN1-9), 0x22C9 (FN10-13), 0x2049 (FN14-17). Kommentar tagged als "Phase Y.4.1-fix (Gold #6100..#6168 bit-exact, 2026-05-14)".
- Grant-Override-Pfad (H.6.3): nur auf F1-17 TN=0 idle (`!signalling_active_sys`), pulst `grant_consume_sys` 1 Zyklus.
- Kommentar dokumentiert "Phase Z.13 (2026-05-04): the Z.2/Z.12 `aach_override_valid_sys` + `aach_override_info_sys` inputs were removed" — Queue-PDU-AACH läuft via tetra_aach_rm_encoder Top-Level.
- `RM_ROW`-Werte stammen aus `sw/tetra_hal.c` RM_30_14_GEN.

### tetra_aach_rm_encoder.v  (127 Zeilen)
**Ports:** `info_w[13:0], lfsr_init_w[31:0] → coded_w[29:0]`. Kein clk/rst.
**Funktion:** Reine kombinatorische RM(30,14)-Encode + 30-Step-LFSR-Mask in einem Cycle. LFSR-Iteration ist Verilog-`for`-Loop in einer Function (synthetisiert zu flacher XOR-Tree).
**State:** Keine.
**Pipeline-Latenz:** 0 (kombinatorisch).
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:** Header sagt "Phase Z.12 / Use case: the DL-Signal-Queue producers compute the AACH coded word LOCALLY at push time". Identische `RM_ROW`-Matrix wie tetra_aach_encoder.v, aber als Function (`rm_encode_f`) statt FSM. Handhabung `lfsr_init==0 → 0xFFFFFFFF` defensive identisch zu sb1/sch_f/sch_hd.

---

## PDU-Builder + IE-Packer

### tetra_basic_slotgrant_encoder.v  (53 Zeilen)
**Ports:** `capacity_allocation[3:0], granting_delay[3:0] → packed_element[7:0]`. Kein clk/rst.
**Funktion:** Packt 8-bit "basic slot-granting element" = `{capacity_allocation, granting_delay}`. MSB zuerst on-air.
**State:** Keine.
**Pipeline-Latenz:** 0.
**Nachbarn:** ↑ tetra_dl_pdu_builder, tetra_mle_registration_fsm, tetra_pre_reply_slotgrant. ↓ Keine.
**Auffälligkeiten:** Stub. Im aktuellen `tetra_dl_pdu_builder.v` hardcoded `capacity_allocation=0, granting_delay=0` (Kommentar nennt "Gold-Match per project_slot_grant_drift.md").

### tetra_chan_alloc_encoder.v  (83 Zeilen)
**Ports:** `alloc_type[1:0], ts_assigned[3:0], ul_dl_assigned[1:0], clch_permission, cell_change_flag, carrier_num[11:0], mon_pattern[1:0], frame18_mon_pattern[1:0] → packed_element[31:0], element_len[4:0]`. Kein clk/rst.
**Funktion:** Packt 25 oder 27 bit "channel allocation element". 25 bit wenn `mon_pattern != 0`, 27 bit wenn `mon_pattern == 0` (dann mit frame18_mon_pattern). Right-aligned in 32-bit Bus.
**State:** Keine.
**Pipeline-Latenz:** 0.
**Nachbarn:** ↑ tetra_mle_registration_fsm (strukturell instanziiert). ↓ Keine.
**Auffälligkeiten:** Header sagt "Today's D-LOC-UPDATE-ACCEPT path sets chan_alloc_flag=0, so this encoder is instantiated structurally in tetra_mle_registration_fsm.v but its output is ignored by the builder." Im D-CONNECT-Pfad (Phase 7 G.7) wird der ChanAlloc-Wert NICHT via dieses Modul gerechnet — `tetra_dl_pdu_builder.v` hardcoded `chan_alloc_element=32'h0027_2FD3` direkt. `ext_carrier_num_flag` hartverdrahtet auf 0.

### tetra_d_location_update_encoder.v  (217 Zeilen)
**Ports:** `pdu_reject, energy_saving_info[13:0], loc_acc_type[2:0], gila_gssi[23:0], gila_class[2:0], gila_lifetime[1:0], gila_present → pdu_bits_mm[127:0], pdu_len_bits[7:0]`. Kein clk/rst.
**Funktion:** Packt MM D-LOCATION-UPDATE-ACCEPT (oder REJECT-PDU-Type) MSB-aligned in 128-bit. Mit GILA (Phase 6 D-rev): 102 bit. Ohne GILA: 36 bit. GILA-Payload (58 bit) baut accept_reject + obit + m-bit + elem_id=7 + length=38 + num_elems=1 + Entry{lifetime,class,addr_type=00,gssi}.
**State:** Keine.
**Pipeline-Latenz:** 0.
**Nachbarn:** ↑ tetra_mle_registration_fsm. ↓ Keine.
**Auffälligkeiten:** Header dokumentiert "Phase X.7 — Legacy 124-bit pdu_bits output + its dedicated address/subscriber_class/address_extension inputs removed. Only the MM-Body wrapper output (pdu_bits_mm + pdu_len_bits) remains". Bit-Layout sehr detailliert kommentiert. Trotz `pdu_reject` Pfad: REJECT-Pfad nutzt nicht diesen Modul-Pfad, sondern den separaten `tetra_d_location_update_reject_encoder`.

### tetra_d_location_update_reject_encoder.v  (54 Zeilen)
**Ports:** `reject_cause[2:0] → pdu_bits_mm[127:0], pdu_len_bits[7:0]`. Kein clk/rst.
**Funktion:** Packt MM D-LOC-UPDATE-REJECT minimal: `{pdu_type=0111, reject_cause, o-bit=0, 120 Padding}` — total 8 meaningful bits.
**State:** Keine.
**Pipeline-Latenz:** 0.
**Nachbarn:** ↑ tetra_mle_registration_fsm. ↓ Keine.
**Auffälligkeiten:** Sehr kleiner Stub. `pdu_len_bits` hartverdrahtet auf 8.

### tetra_mac_resource_bl_ack_builder.v  (85 Zeilen)
**Ports:** `clk, rst_n, start, ssi[23:0], addr_type[2:0], random_access_flag, nr → pdu_bits[PDU_BITS-1:0], valid`. PDU_BITS=268.
**Funktion:** Baut Standalone-MAC-RESOURCE-PDU mit BL-ACK als TM-SDU. 43-bit MAC-Header + 5-bit LLC-BL-ACK = 48 bit (6 Octets), Rest Padding. LengthInd=6.
**State:** 3 Zustände `S_IDLE, S_PACK, S_DONE`. Layout in `pdu_bits_c` ist kombinatorisch.
**Pipeline-Latenz:** 3 clk_sys.
**Nachbarn:** ↑ tetra_pre_reply_blck. ↓ Keine.
**Auffälligkeiten:** Sehr knappes Modul. Keine Optional-IE-Pfade (pc/sg/ca alle hartverdrahtet 0).

### tetra_mac_resource_dl_builder.v  (790 Zeilen)
**Ports:** `clk, rst_n, start, ssi[23:0], addr_type[2:0], usage_marker[5:0], ns, nr, llc_pdu_type[3:0], random_access_flag, power_control_flag, power_control_element[3:0], slot_granting_flag, slot_granting_element[7:0], chan_alloc_flag, chan_alloc_element[31:0], chan_alloc_element_len[4:0], second_pdu_valid, second_pdu_length_ind[5:0], second_pdu_random_access_flag, second_pdu_addr_type[2:0], second_pdu_ssi[23:0], second_pdu_tl_sdu[79:0], second_pdu_tl_sdu_len[6:0], second_pdu_pc_flag, second_pdu_pc_element[3:0], second_pdu_sg_flag, second_pdu_sg_element[7:0], second_pdu_ca_flag, second_pdu_ca_element[31:0], second_pdu_ca_element_len[4:0], mm_pdu_bits[127:0], mm_pdu_len_bits[7:0], mle_pd_in[2:0] → pdu_bits[PDU_BITS-1:0], valid`. PDU_BITS=268 default, LLC_BUF_BITS=144 default.
**Funktion:** Wrappt rohe MM-PDU in MAC-RESOURCE-DL-Header + LLC-Header. Berechnet Längen kombinatorisch (`tl_sdu_len_c`, `llc_cov_len_c`, `mac_hdr_bits_c`, `mac_total_bits_c`, `mac_total_octets_c`). Layout: 40-bit Base (oder 46-bit für addr_type=6) + 3 Mandatory-Flags + optionale Elemente (PowerCtrl/SlotGrant/ChanAlloc) + LLC-Buffer-Inhalt + optional concat PDU#2.
**State:** 6 Zustände `S_IDLE, S_ASSEMBLE_INNER, S_LLC_HEAD, S_MAC_HEAD, S_PAD, S_DONE`. S_LLC_HEAD packt 4 verschiedene LLC-Header-Varianten (L2SIG / AL_SETUP / BL_ADATA / BL_UDATA / BL_DATA).
**Pipeline-Latenz:** 6 clk_sys.
**Nachbarn:** ↑ tetra_dl_pdu_builder. ↓ Keine.
**Auffälligkeiten:**
- Kommentar dokumentiert Phase 7 G.7 Erweiterung um addr_type=6 (SsiAndUsageMarker, 30-bit Slot, base header 46 bit) und LLC_PDUT_BL_UDATA.
- Hat `second_pdu_*`-Plumbing für Option-B BL-ACK-Concat (kommentiert "commit 2, 2026-04-24"), aber alle aktuellen Caller (siehe `tetra_dl_pdu_builder.v`) tied das auf 0 ab.
- Kommentar markiert TODO bei addr_type-abhängigem Address-Slot: "TODO (Group-Call phase): make the address slot addr_type-dependent" — aktuell nur addr_type 1/3/6 mit Guard `$fatal`.
- `complete_pdu_bits` ist 268-bit Output, gepackt durch Cascade von Shift-OR-Operationen in S_MAC_HEAD.
- LLC-Buf-Mappung in `S_LLC_HEAD`: BL-ADATA = 6 bit hdr + MLE-PD(3) + MM(128) = 137 → pad 7. BL-DATA = 5 bit hdr + MLE-PD(3) + MM(128) = 136 → pad 8. BL-UDATA = 4 bit hdr + MLE-PD(3) + MM(128) = 135 → pad 9. AL_SETUP = 4 bit hdr only. L2SIG = 4 bit hdr + MM(128) = 132 → pad 12.

### tetra_dl_pdu_builder.v  (294 Zeilen)
**Ports:** `clk, rst_n, req_valid, req_ssi[23:0], req_addr_type[2:0], req_llc_pdu_type[3:0], req_random_access_flag, req_mm_pdu_bits[127:0], req_mm_pdu_len_bits[7:0], req_mle_pd[2:0], req_scramble_init[31:0], req_ns, req_nr → done, coded_bits[431:0], busy`.
**Funktion:** Shared Pipeline: {basic_slotgrant_encoder (capacity=0, granting_delay=0), mac_resource_dl_builder (PDU_BITS=268, LLC_BUF_BITS=144), sch_f_encoder} chained durch eine FSM. Pro `req_valid` ein 432-bit SCH/F-Output.
**State:** 5 Zustände `S_IDLE, S_BUILD, S_PACK, S_ENC, S_DONE`. S_BUILD wartet auf builder.valid; S_PACK latcht in `lat_info_bits` und pulst `encode_start`; S_ENC wartet auf `coded_valid_w`.
**Pipeline-Latenz:** ~1000 clk_sys total (6 builder + ~991 sch_f + 3 FSM).
**Nachbarn:** ↑ tetra_lmac / tetra_zynq_top (Final-Accept), tetra_pre_reply_slotgrant. ↓ tetra_basic_slotgrant_encoder, tetra_mac_resource_dl_builder, tetra_sch_f_encoder.
**Auffälligkeiten:**
- Hardcoded für CMCE-Pfad (`lat_mle_pd == 3'b010`): `slot_granting_flag=0`, `chan_alloc_flag=1`, `chan_alloc_element=32'h0027_2FD3`, `chan_alloc_element_len=25`, `usage_marker=11`. Kommentar markiert "Phase 7 G.5+ — Gold-konformes MAC-RESOURCE-Header für CMCE".
- Für MM-Pfad (`lat_mle_pd != 010`): `slot_granting_flag=1`, `chan_alloc_flag=0`. `addr_type=6` triggert `usage_marker=11`.
- `second_pdu_valid` hartverdrahtet auf 0 (kein Concat-Pfad genutzt).
- `req_mle_pd == 3'b000 → 3'b001` Default-Mapping.

---

## Queue + Scheduler

### tetra_dl_signal_queue.v  (380 Zeilen)
**Ports:** Producer-Ports MLE/CMCE/SDS: jeweils `wr_*_valid, wr_*_coded[431:0], wr_*_pdu_type[1:0], wr_*_target_tn[1:0], wr_*_aach_pattern[13:0]`. MLE zusätzlich `wr_mle_second_pdu_present, wr_mle_second_pdu_nr`. Consumer: `pop → head_valid, head_coded[431:0], head_pdu_type[1:0], head_target_tn[1:0], head_prio[1:0], head_aach_pattern[13:0], head_second_pdu_present, head_second_pdu_nr`. Stats: `depth_valid_mask[3:0], depth_count[2:0], drop_cnt[15:0], drop_cnt_mle[7:0], drop_cnt_cmce[7:0], drop_cnt_sds[7:0]`.
**Funktion:** 4-Slot Register-Array. 3 Producer-Ports (MLE prio 00, CMCE prio 01, SDS prio 10). Pro Zyklus max 1 Write durch Arb (MLE > CMCE > SDS). Pop: strict Priority-Scan über alle Slots, niedrigste Prio gewinnt, bei Tie niedrigerer Slot-Index. Drop-Newest bei Voll. Saturating Drop-Counters (16-bit aggregate, 8-bit pro Producer).
**State:** Keine FSM, nur Register-Array + kombinatorische Arb-Logik.
**Pipeline-Latenz:** Pop ist kombinatorisch (head_* sind wires); Storage-Updates passieren auf nächstem posedge.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:**
- Header dokumentiert "Phase Z.13 (2026-05-04): the per-entry pre-coded AACH (Z.12 storage `entry_aach_coded`) was removed."
- `head_aach_pattern` ist jetzt 14-bit Pattern (statt 30-bit pre-coded), wird vom Top-Level via tetra_aach_rm_encoder kombinatorisch encoded.
- Entry-Felder: coded[432] + pdu_type[2] + target_tn[2] + prio[2] + aach_pattern[14] + second_pdu_present + second_pdu_nr + valid = ~454 bit pro Slot.
- Pop-Arb-Block: 4 separate `always @(*)` für `idx_prio0..3` mit Reverse-Scan (höhere Indizes zuerst, untere überschreiben → niedriger Slot wins).

### tetra_dl_signal_scheduler.v  (225 Zeilen)
**Ports:** `clk_sys, rst_n_sys, tn_sys[1:0], slot_pulse_sys, head_valid_sys, head_coded_sys[431:0], head_pdu_type_sys[1:0], head_target_tn_sys[1:0], head_prio_sys[1:0], head_second_pdu_present_sys, head_second_pdu_nr_sys, null_pdu_bits_sys[215:0], sig_companion_sys[215:0] → pop_sys, popped_second_pdu_present_sys, popped_second_pdu_nr_sys, sched_blk1_tn{0..3}_sys[215:0], sched_blk2_tn{0..3}_sys[215:0], sched_ndb2_sys[3:0], sched_active_sys[3:0], override_cnt_sys[15:0], pop_cnt_sys[15:0]`.
**Funktion:** Kombinatorischer Fan-Out aus queue.head zu per-TN-Bundles. Für jeden TN k: wenn `head_valid_sys && head_target_tn_sys == k`: `blk1[k] = head_coded[431:216]`, `blk2[k] = head_coded[215:0]` (SCH/F) ODER `sig_companion` (SCH/HD). `ndb2[k] = 1` für SCH/HD oder idle NULL-PDU, `= 0` für SCH/F. `active[k]` = one-hot. Pop pulst auf `slot_pulse_sys && head_target_tn == tn_sys && head_valid`.
**State:** Keine FSM. Nur 4 registrierte Counter: `pop_cnt_sys`, `override_cnt_sys`, `popped_second_pdu_present_sys`, `popped_second_pdu_nr_sys`.
**Pipeline-Latenz:** Bundles kombinatorisch; Counter +1 clk_sys nach pop_trigger.
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:**
- Header dokumentiert "Phase Z.13 (2026-05-04) refactor — clean architectural rewrite" mit Erklärung des Z.11/Z.12 bundle-latch single-cycle race und der Lösung durch "no latch at all".
- `head_prio_sys` ist als Input deklariert aber nur in `_unused_sys = |head_prio_sys` referenziert (Keepalive — Prio wird im Scheduler nicht mehr genutzt, nur im Queue selbst).
- `pop_cnt_sys` und `override_cnt_sys` zählen IDENTISCH (beide `if (pop_trigger && ...)`); Kommentar: "kept as a separate name for AXI back-compat".

---

## Burst-Dispatch + Modulator + Frontend

### tetra_burst_dispatcher.v  (295 Zeilen)
**Ports:** `clk_sys, rst_n_sys, tx_slot_pulse_sys, tx_slot_num_sys[1:0], sched_blk1_tn{0..3}_sys[215:0], sched_blk2_tn{0..3}_sys[215:0], sched_active_sys[3:0], sched_ndb2_sys[3:0], sched_entry_reg_sys{0..3}[15:0], ndb_block1_sw_sys[215:0], ndb_block2_sw_sys[215:0], mcch_block1_sw_sys[215:0], mcch_block2_sw_sys[215:0], bnch_block1_sw_sys[215:0], bnch_block2_sw_sys[215:0], sb_bkn2_sw_sys[215:0], bb_in_sys[29:0], sb_sb1_in_sys[119:0], tx_busy_sys → build_block1_sys[215:0], build_block2_sys[215:0], build_bb_sys[29:0], build_sb1_sys[119:0], build_burst_type_sys, build_ndb2_sys, build_req_sys`.
**Funktion:** Per-Slot-Selection-Mux mit 3-Stage-Pipeline (post-Y.3). Auf `tx_slot_pulse_sys` wird für `tx_slot_num_sys` der gewählte Body/Meta gelatcht und `build_req_sys` pulst 1 Zyklus. Lift-Regel: wenn `sched_active_sys[k]==1` ODER Schedule-Entry-Class==SIGNALLING, kommt Body aus scheduler-Bundle; sonst Static-Lookup aus SW-Bänken (NDB/MCCH/BNCH/SB).
**State:** Keine FSM. Pure Sel-Mux + 1-Latch-Stage.
**Pipeline-Latenz:** 1 clk_sys (slot_pulse → build_req).
**Nachbarn:** ↑ tetra_zynq_top. ↓ Keine.
**Auffälligkeiten:**
- Header dokumentiert "Phase Y.3 — flat-stage replacement for tetra_burst_mux + the per-slot tx_blk*_slot*_sys / slot_burst_type_sys / slot_en_sys / slot_ndb2_sys latches that previously lived in tetra_slot_content_mux."
- Static-Body-Lookup-Funktion `static_blk1_for(idx)` mapped idx 0..7 auf SW-Bänke. idx 3 (SB) ist explizit `{BLOCK_BITS{1'b0}}` für blk1 — SB1-Daten kommen via `sb_sb1_in_sys` (separater Port). idx 7 = empty.
- `tx_busy_sys` Input ist im Code unbenutzt (`_unused_dispatcher_sys = tx_busy_sys` Keepalive, "reserved future use").
- `default:`-Branch im `case (tx_slot_num_sys)` ist unreachable (alle 4 Werte abgedeckt) aber expliziert.
- bb_in_sys + sb_sb1_in_sys werden bei `sel_enable_w==0` zu 0 gemultiplext (Body); BB hingegen broadcasted immer (`build_bb_sys <= bb_in_sys`).

### tetra_burst_builder.v  (316 Zeilen)
**Ports:** `clk_sys, rst_n_sys, sym_en_ext_sys, block1_data_sys[215:0], block2_data_sys[215:0], bb_data_sys[29:0], sb1_data_sys[119:0], burst_type_sys, burst_ndb2_sys, build_req_sys → tx_dibit_sys[1:0], tx_dibit_valid_sys, tx_done_sys, tx_busy_sys`.
**Funktion:** Assembliert 510-bit (=255 Symbol × 2 bit) Burst-SR aus Body + BB + STS/NTS + Tail. NDB-Layout: TAIL1(6) + HA(1) + blk1(108sym=216b) + bb[29:16] + NTS1/2(11sym=22b) + bb[15:0] + blk2(216b) + HA(1) + TAIL2(5). SDB-Layout: TAIL1 + HC(1) + FC(40sym) + sb1(60sym=120b) + STS(19sym=38b) + bb(15sym=30b) + bkn2(108sym=216b) + HD(1) + TAIL2. Chaining via Shadow-Reg auf neuem `build_req` während `tx_busy`.
**State:** 3 Zustände `S_IDLE, S_SHIFT, S_DONE`. S_SHIFT zählt sym_cnt 0..254, shiftet 2 bit pro `sym_en_ext_sys`. Auf sym_cnt==254 + chain_pending → reload Shadow, zurück zu sym_cnt=0 in S_SHIFT (kein S_DONE).
**Pipeline-Latenz:** Erster `tx_dibit_valid` ist 1 sym_en_ext nach `build_req` (cold start) / 1 sym_en_ext nach sym_cnt=254 (chain).
**Nachbarn:** ↑ tetra_tx_chain. ↓ Keine.
**Auffälligkeiten:**
- Tail-Symbole hartverdrahtet aus q-Sequenz, FC_PAT = `8'hFF + 64'h0 + 8'hFF`, STS_REF/NTS1_REF/NTS2_REF als 38/22-bit Konstanten.
- Cold-Start vs Chain: `build_req_pending_sys` für cold (S_IDLE→S_SHIFT), `chain_pending_sys` für Mid-Burst-Reload.
- `nts_sel_w = burst_ndb2_sys ? NTS2_REF : NTS1_REF` (NDB1=NTS1, NDB2=NTS2).
- PADJ-Felder (Phase-Adjustment, ETSI optional) hartverdrahtet auf `2'b00` an beiden Stellen.

### tetra_pi4dqpsk_mod.v  (166 Zeilen)
**Ports:** `clk_sample, rst_n_sample, dibit_in[1:0], dibit_valid → i_out[15:0] (signed), q_out[15:0] (signed), sample_valid_out`. Parameters: IQ_WIDTH=16, PHASE_WIDTH=16 (unused), LUT_DEPTH=1024 (unused).
**Funktion:** π/4-DQPSK-Modulator. 3-bit Phase-Index, dibit-abhängiges Increment (00=+1, 01=+3, 10=+7, 11=+5 mod 8). IQ-Lookup auf 8 Punkte (cos/sin von idx*45°, skaliert auf Q1.15: 32767 / 23170 / 0).
**State:** Keine FSM. Nur 3-bit `phase_idx_sample`-Register.
**Pipeline-Latenz:** 1 clk_sample (i_out/q_out + sample_valid_out registriert).
**Nachbarn:** ↑ tetra_tx_chain. ↓ Keine.
**Auffälligkeiten:** AMP_ONE = +32767 (nicht +32768, "to avoid -32768 abs-value issue"). PHASE_WIDTH/LUT_DEPTH-Parameter sind formal aber funktional unbenutzt — der Code nutzt fest 3-bit Index und 8-Punkt-LUT.

### tetra_rrc_filter.v  (354 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in[15:0] (signed), q_in[15:0] (signed), sample_valid_in → i_out[15:0] (signed), q_out[15:0] (signed), sample_valid_out`. Parameters: IQ_WIDTH=16, RRC_ACC_SHIFT=14.
**Funktion:** 33-tap RRC-FIR (α=0.35), polyphase L=4 Interpolation. Eingang 18 ksym/s → Ausgang 72 kHz. Pro Input-Sample werden 4 Outputs sequentiell berechnet (4 Phasen × 9 Taps = 36 MACs).
**State:** 2 Zustände `S_IDLE, S_MAC`. S_MAC durchläuft 4 Phasen × 9 Taps; pro Tap multipliziert 1 IQ-Tap mit 1 Koeffizient, akkumuliert in 38-bit Acc.
**Pipeline-Latenz:** 36 clk_sys + 1 (sample_valid_out reg) pro Input-Sample.
**Nachbarn:** ↑ tetra_tx_chain. ↓ Keine (Konstanten + Mux inline).
**Auffälligkeiten:** Koeffizienten H00..H32 als 16-bit signed Konstanten, symmetrisch. 38-bit ACC mit 14-bit Right-Shift und Saturation. SR-Layout: 9 × 16-bit als 144-bit Flat-Bus (R3-konform, kein Array). 1 DSP48 für Mult inferiert.

### tetra_tx_inv_sinc.v  (169 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in[15:0] (signed), q_in[15:0] (signed), sample_valid_in → i_out[15:0] (signed), q_out[15:0] (signed), sample_valid_out`. Parameter: IQ_WIDTH=16.
**Funktion:** 7-tap symmetric inverse-sinc FIR-Filter, Koeffizienten Q14 hardcoded `[930, -3346, 2332, 16553, ...]`. Kompensiert CIC-Droop. Architektur: 7-stage Shift-Register, 3 Pre-Adder (Symmetrie), 4 parallele Multiplies + Sum (kombinatorisch), Output saturiert + registriert.
**State:** Keine FSM. Nur Shift-Register + Output-Reg.
**Pipeline-Latenz:** 1 clk_sys nach `sample_valid_in`.
**Nachbarn:** ↑ Keine. ↓ Keine.
**Auffälligkeiten:** Modul ist im Code definiert, aber im aktuellen `tetra_tx_chain.v` NICHT instanziiert — die TX-Kette geht direkt von `tetra_rrc_filter` zu `tetra_tx_frontend`. Toter Pfad (instanziert in keinem Top-Level laut grep).

### tetra_tx_frontend.v  (448 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in[15:0] (signed), q_in[15:0] (signed), sample_valid_in, clk_lvds, rst_n_lvds → tx_i_lvds[15:0] (signed), tx_q_lvds[15:0] (signed), tx_valid_lvds`. Parameters: IQ_WIDTH=16, CIC_SHIFT=24, CIC_ACC=48.
**Funktion:** TX-Frontend mit CDC (clk_sys→clk_lvds) via XPM-Async-FIFO + 5-stage CIC-Interpolator (R=64, N=5, M=1). Input 72 kHz → Output 4.608 MHz. CDC-FIFO 16 Worte tief. CIC-Architektur: Comb-Section vor Zero-Stuff (5 cascaded differentiators, update once per 128 lvds-cycles) + Integrator-Section (5 cascaded accumulators, update jeden 4. lvds-cycle).
**State:** Keine FSM. Nur 8-bit `lvds_cnt` und 10 CIC-Register-Paare (Comb + Integrator je 5 Stages × 2 IQ).
**Pipeline-Latenz:** ~256 lvds-cycles für ein vollständiges Sample-Output-Set; 1 lvds-cycle Pipeline-Delay (`intg_en_d1`).
**Nachbarn:** ↑ tetra_tx_chain. ↓ xpm_fifo_async.
**Auffälligkeiten:** Sehr lang, aber strikt linear: 5 Comb-Stages und 5 Integrator-Stages je als separate `always`-Blöcke (R1-konform). Comb-Load-Strobe `comb_load_w = (lvds_cnt == 255)`, fifo_rd_en bei `lvds_cnt == 254`, intg_en bei `lvds_cnt[1:0] == 00`. Output-Skalierung shift-right CIC_SHIFT=24 + Saturation.

### tetra_tx_chain.v  (201 Zeilen)
**Ports:** `clk_sys, rst_n_sys, build_block1_sys[215:0], build_block2_sys[215:0], build_bb_sys[29:0], build_sb1_sys[119:0], build_burst_type_sys, build_ndb2_sys, build_req_sys, tx_test_prbs_en_sys, sym_en_ext_sys, clk_lvds, rst_n_lvds → tx_i_lvds, tx_q_lvds, tx_valid_lvds, tx_busy_sys`.
**Funktion:** Container für die symbol-rate Datapath: `burst_builder → pi4dqpsk_mod → rrc_filter → tx_frontend`. Zusätzlich PRBS-Diagnostik-Mux: wenn `tx_test_prbs_en_sys==1`, ersetzt 15-bit LFSR-PRBS den Dibit vor dem Modulator.
**State:** Keine FSM, nur 15-bit PRBS-LFSR (advances on `builder_dibit_valid_sys`).
**Pipeline-Latenz:** Container, addiert keine zusätzliche.
**Nachbarn:** ↑ tetra_zynq_top. ↓ tetra_burst_builder, tetra_pi4dqpsk_mod, tetra_rrc_filter, tetra_tx_frontend.
**Auffälligkeiten:**
- Instanziiert KEINE `tetra_tx_inv_sinc` — Datenfluss geht direkt RRC → tx_frontend (CIC). Das inv-sinc-Modul ist im Repo aber unverlinkt.
- PRBS-Polynom: `x^15 + x^14 + 1`, Feedback `prbs_lfsr[14] ^ prbs_lfsr[13]`.
- `tx_busy_sys` ist Status-Output (= `builder_busy_sys`), kein interner State.

---

## Anmerkungen zur Topologie

Daten-Fluss DL-TX (Post-Y.3):

```
SW (AXI) → tetra_dl_signal_queue (DEPTH=4, prio MLE>CMCE>SDS)
              │ head_* (kombinational)
              ↓
        tetra_dl_signal_scheduler (Phase Z.13: no latch, pure fan-out)
              │ sched_blk*_tn{0..3}, sched_active, sched_ndb2
              ↓
        tetra_burst_dispatcher (1-Stage Slot-Mux)
              │ build_block{1,2}_sys, build_bb_sys, build_sb1_sys, build_burst_type/ndb2, build_req
              ↓
        tetra_burst_builder (510-bit SR + Chain)
              │ tx_dibit (18 ksym/s)
              ↓
        tetra_pi4dqpsk_mod (IQ @18 ksym/s)
              │
              ↓
        tetra_rrc_filter (IQ @72 kHz)
              │
              ↓
        tetra_tx_frontend (CIC R=64 → IQ @4.608 MHz lvds)
              │
              ↓
        AD9361 LVDS DDR
```

AACH-Pfad:

```
tetra_aach_encoder (Default-Logic, FSM) ─┐
                                          ├─→ (Top-Level-Mux) → bb_in_sys[29:0]
tetra_aach_rm_encoder (Queue-Pattern,    ─┘
                       Kombinational)
```

BSCH-Pfad:

```
tetra_sb1_encoder (FSM ~142 clk_sys) → sb_sb1_in_sys[119:0]
```

PDU-Build-Pfad (SCH/F-Signalling):

```
SW Mailbox / MLE-FSM → tetra_dl_pdu_builder (Sequencer FSM)
                            ├─→ tetra_basic_slotgrant_encoder (comb)
                            ├─→ tetra_mac_resource_dl_builder (FSM ~6 clk_sys)
                            └─→ tetra_sch_f_encoder (FSM ~991 clk_sys)
                       → coded_bits[431:0] → tetra_dl_signal_queue
```
