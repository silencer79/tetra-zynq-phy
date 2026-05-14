# IST — Kapitel 4: UL RX (oversampled Sync + RA-Burst Decode + Reassembly + Voice-Capture-Hack)
Stand: 2026-05-14
Quelle: rtl/rx/tetra_ul_{sync_detect_os4,burst_capture,pi4dqpsk_demod,sch_hu_decoder,viterbi_r14,demand_reassembly,voice_capture}.v
 + rtl/lmac/tetra_{viterbi_decoder,deinterleaver,depuncture_r23,ul_mac_access_parser,ul_demand_ie_parser,steal_detect}.v

## Inhalt
1. `tetra_ul_sync_detect_os4.v` — 4-Phasen ETS-x-seq Detector @ 72 kHz
2. `tetra_ul_burst_capture.v` — Ring-Buffer + Phase-Align + 86-Sample-Stream
3. `tetra_ul_pi4dqpsk_demod.v` — Differential pi/4-DQPSK Demod (Soft-Dibit)
4. `tetra_viterbi_decoder.v` — Originale K=5 r=1/4 Soft-Viterbi (LMAC DL-Stil-Konvention)
5. `tetra_ul_viterbi_r14.v` — ETSI-Convention K=5 r=1/4 Soft-Viterbi (UL)
6. `tetra_deinterleaver.v` — Multiplicative Deinterleaver (a=11/101/103)
7. `tetra_depuncture_r23.v` — Rate-2/3 → Rate-1/4 Soft-Erasure-Inserter
8. `tetra_ul_sch_hu_decoder.v` — SCH/HU Komplettpipeline (Descramble→Deinterleave→Depuncture→Vit→CRC16)
9. `tetra_ul_mac_access_parser.v` — MAC-ACCESS + MAC-END-HU Header-Extraktor
10. `tetra_ul_demand_reassembly.v` — Frag-1 + Frag-2 → 129-bit MM-Body
11. `tetra_ul_demand_ie_parser.v` — mm=2 LOC-UPDATE + mm=7 ATTACH/DETACH-GROUP-IDENTITY Walker
12. `tetra_steal_detect.v` — AACH→steal-flag pro Slot
13. `tetra_ul_voice_capture.v` — Phase Y.4.2/Y.4.3 Voice-Slot-Capture (inert; siehe Auffälligkeiten)

---

### tetra_ul_sync_detect_os4.v (243 Zeilen)
**Ports:** `clk_sys, rst_n_sys, reset_peak_sys, i_in_sys[15:0], q_in_sys[15:0], valid_in_sys, corr_threshold_sys[5:0]` → `sync_found_sys, corr_peak_sys[5:0], best_phase_sys[1:0]`

**Funktion:** Oversampled (4 sps) Detector für die ETSI x-Sequenz (§9.4.4.3.3, 15 Symbole / 30 bit) auf dem post-RRC IQ-Stream bei 72 kHz. Vier parallele Phasen-Demodulatoren: `phase_cnt_sys` 0..3, jede Phase hat eigene `i_hist[k]/q_hist[k]` (Sample 1 Symbol zuvor) und eigenen 30-bit Shift-Register `sreg0..sreg3`. Pro Sample: Differentialprodukt `z = current × conj(prev[phase])` → 2-bit Dibit aus `{sign(Im),sign(Re)}`. Korrelation 4× separat, dann `max(corr0..corr3)`. `sync_fire = corr_max >= threshold & valid_in & ~holdoff`. Holdoff `HOLDOFF=50` Samples.

**State:** Keine FSM. `corr_peak_sys` ist sticky-max, clearable über `reset_peak_sys`-Puls.

**Pipeline-Latenz:** Korrelation rein kombinatorisch; `sync_found_sys` 1 Zyklus nach `sync_fire`.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_ul_sync_detect`); ↓ keine.

**Auffälligkeiten:**
- 4 DSP48 erwartet (Real- und Imaginärteil-Komponentenprodukte).
- `corr_threshold_sys` ist 6-bit Port, aber wirklich genutzt sind nur [3:0]; `zero_ext_thresh_sys = |corr_threshold_sys[CORR_WIDTH-1:4]` verhindert dass thresh > 15 jemals matched (immer FALSE).
- `best_phase_sys` wird beim sync_fire latched; vorhanden auch wenn Tie mehrere Phasen gleich gut sind (Priorität: 0 vor 1 vor 2 vor 3 dank cascadierter `>=`-Vergleiche).

---

### tetra_ul_burst_capture.v (241 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in_sys[15:0], q_in_sys[15:0], valid_in_sys, sync_found_sys, best_phase_sys[1:0]` → `i_out_sys[15:0], q_out_sys[15:0], iq_valid_sys, iq_first_sys, iq_last_sys, iq_half_sys, capture_busy_sys, bursts_captured_sys[15:0]`

**Funktion:** Ringbuffer-basierter Phase-aligned Reader. BRAM 512×16 für I und Q, kontinuierlich beschrieben auf jedem `valid_in_sys`. Bei `sync_found_sys`: Anchor berechnet (Anker = ringidx von x[14] am Winning-Phase, via `(phase_cnt-1-best_phase) mod 4`), 168 Samples Post-Wait, dann zwei Halbsequenzen je 43 Samples streamen: CB1 ab `anchor - 228` (= 57 sym × 4 sps zurück), CB2 ab Anchor. Stride SPS=4 → korrekte Symbol-Phase. Metadaten `iq_first_sys` markiert Diff-Ref jeder Hälfte; `iq_last_sys` = letztes Sample CB2; `iq_half_sys` = 0/1 für CB1/CB2.

**State:** 2-bit FSM `S_IDLE/S_WAIT_POST/S_STREAM_CB1/S_STREAM_CB2`.
- `S_IDLE→S_WAIT_POST` bei `sync_found_sys` (latcht Anchor)
- `S_WAIT_POST→S_STREAM_CB1` wenn `post_cnt_sys<=1` (172 Samples gewartet)
- `S_STREAM_CB1→S_STREAM_CB2` nach 43 Reads
- `S_STREAM_CB2→S_IDLE` nach 43 Reads, `bursts_captured++`

**Pipeline-Latenz:** BRAM-Read-Latenz 1 Zyklus; Metadaten (`iq_valid_sys`, `_first_/_last_/_half_`) sind 1 Zyklus später als rd_en-Pulse registriert.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_ul_burst_capture`); ↓ keine.

**Auffälligkeiten:**
- `RING_DEPTH=512` BRAM (2× RAMB18: ring_i + ring_q).
- Anchor-Subtraktion wraps natürlich modulo 2^RING_ADDR_W=512.

---

### tetra_ul_pi4dqpsk_demod.v (171 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in_sys[15:0], q_in_sys[15:0], iq_valid_sys, iq_first_sys, iq_last_sys, iq_half_sys` → `soft_bit0_sys[7:0], soft_bit1_sys[7:0], soft_valid_sys, soft_first_sys, soft_last_sys, soft_half_sys`

**Funktion:** Konsumiert 43 phase-aligned IQ-Samples pro Burst-Hälfte und liefert 42 Soft-Dibit-Paare. Pro Symbol k (1..42): `z = IQ(k) × conj(IQ(k-1))`. `soft_bit0 = sign+magnitude von Re(z)` (slice MSB-aligned), `soft_bit1` analog von Im(z). 3-stufige Pipeline: S1 Multipliziere (4 Produkte), S2 Summenbilden (Re=ii+qq, Im=qi-iq), S3 MSB-Slice (`SOFT_WIDTH=8`).

**State:** Keine FSM, nur Pipeline-Register + `has_prev_sys` (gesetzt auf erstem `iq_first_sys`) + `pending_first_sys` (markiert nächsten Emit als `soft_first`).

**Pipeline-Latenz:** 3 clk_sys Zyklen `iq_valid_sys → soft_valid_sys`.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_ul_demod`); ↓ keine.

**Auffälligkeiten:**
- 4 DSP48 inferred für 4 IQ*IQ-Produkte.
- Erstes Sample jeder Hälfte ist Diff-Referenz (kein Soft-Output) — Output beginnt erst bei zweitem Sample (`iq_first_sys` register-deferred).

---

### tetra_viterbi_decoder.v (500 Zeilen)
**Ports:** `clk_sys, rst_n_sys, soft_bit_0[2:0], soft_bit_1[2:0], soft_bit_2[2:0], soft_bit_3[2:0], input_valid, num_stages[8:0], punct_pattern[2:0]` → `decoded_bit, decoded_valid, block_done, path_metric_min[15:0]`

**Funktion:** 16-State Soft-Decision Viterbi für ETSI K=5 r=1/4 Mutter-Code. Generators G1=0x13, G2=0x1D, G3=0x17, G4=0x1B. Soft 3-bit unsigned (0=strong-0, 7=strong-1, 4=erasure). Trellis-Konvention: `state[3]=oldest bit`, `new_state = {input_bit, prev_state[3:1]}`. ACS rein kombinatorisch über generate-Block (16 Butterflies), Pfadmetriken in flachem 256-bit Register, Survivor-Bits in 16× MAX_STAGES-bit Flat-Regs. Argmin via 5-Level binärer Tree. FSM: `S_IDLE→S_ACS→S_TB_INIT→S_TRACEBACK→S_OUTPUT→S_IDLE`.

**State:** 3-bit `state_sys`. Next-state-Logik kombinatorisch. `stage_cnt_sys` 9-bit (0..MAX_STAGES-1). `acs_done`, `tb_done`, `out_done` kombinatorisch.

**Pipeline-Latenz:** Strikt sequentiell pro Block: `num_stages` Zyklen ACS + 1 TB_INIT + `num_stages` Traceback + (`num_stages`-TAIL) Output = ~3×num_stages + 1.

**Nachbarn:** ↑ vermutlich LMAC-DL-Decoder-Module (nicht im aktuellen Subset wirklich genutzt aus Header — Beschreibung erwähnt rate-1/4-Mutter); aktuelle UL-Pipeline nutzt `tetra_ul_viterbi_r14.v` statt dieses Moduls.
**Auffälligkeiten:**
- Header notiert `path_metric_min` als BER-Proxy.
- Trellis-Konvention `new_state = {input_bit, prev_state[3:1]}` — Hochbit (`state[3]`) = ältester Input-Bit. Das ist die "Bit-Reversed"-Konvention die nach Memory-Notiz `project_viterbi_conv_bug` nur für DL-Loopback passt, daher wurde für UL `tetra_ul_viterbi_r14.v` eingeführt.

---

### tetra_ul_viterbi_r14.v (431 Zeilen)
**Ports:** `clk_sys, rst_n_sys, soft_bit_0[2:0], soft_bit_1[2:0], soft_bit_2[2:0], soft_bit_3[2:0], input_valid, num_stages[8:0]` → `decoded_bit, decoded_valid, block_done, path_metric_min[15:0]`

**Funktion:** Strukturell wie `tetra_viterbi_decoder.v` aber mit ETSI-konformer Trellis-Konvention: `new_state = ((old_state << 1) | input) & 0xF`, also `state[0]=newest`, `state[3]=oldest`. Generators in new-state Koordinaten anders gefasst (G1_P0 = s[0]^s[1] etc). Traceback startet immer aus State 0 (Tail-Bits = 0) statt aus argmin — Header: "argmin is only correct on a converged trellis".

**State:** 3-bit `state_sys` `S_IDLE/S_ACS/S_TB_INIT/S_TRACEBACK/S_OUTPUT`. Identische FSM-Transitions wie `tetra_viterbi_decoder`.

**Pipeline-Latenz:** ~3×num_stages + 1 Zyklen pro Block (siehe oben).

**Nachbarn:** ↑ `tetra_ul_sch_hu_decoder` (`u_viterbi`); ↓ keine.

**Auffälligkeiten:**
- Parametrisierbar `SOFT_WIDTH` (Default 3), `TRACEBACK=32`, `MAX_STAGES=436` (instanziiert mit `MAX_STAGES=TRELLIS_STAGES=112` im SCH/HU-Decoder).
- `best_state_unused_w = best_state_w` als VCD-Anker — bewusst toter Pfad/Hinweis dass argmin nicht genutzt wird, Traceback startet immer bei `tb_state=4'd0`.
- Branch-Metrik `BM_BITS = SOFT_WIDTH+2`, `BM_MAX = 4*SOFT_MAX`. Saturation auf 16'hFFFF wenn cost-Add 17-bit überläuft.

---

### tetra_deinterleaver.v (181 Zeilen)
**Ports:** `clk_sys, rst_n_sys, block_size[8:0], data_in, data_in_valid` → `data_out, data_out_valid, block_done`

**Funktion:** Multiplikativer Deinterleaver per ETSI §8.2.4.1. FILL-Phase: sequenziell in `buf_data[wr_addr]` schreiben (0..K-1). DRAIN-Phase: `rd_addr` startet bei `a`, steppt um `a` mod K — pro Output-Position i=1..K liest aus `buf[(a*i) mod K]`. Konstanten: BSCH a=11 (K=120), BNCH/SCH-HD a=101 (K=216), SCH/F a=103 (K=432).

**State:** 1-bit `state` (S_FILL/S_DRAIN). `S_FILL→S_DRAIN` bei `wr_addr==K-1 & data_in_valid`. `S_DRAIN→S_FILL` bei `drain_cnt==K-1`.

**Pipeline-Latenz:** K Zyklen FILL + K Zyklen DRAIN.

**Nachbarn:** Im aktuellen Subset nicht direkt von einem Modul instanziiert (LMAC-DL nutzt es); UL nutzt eigene flat-Buffer-Logik im `sch_hu_decoder`.

**Auffälligkeiten:** Verwendet variablen Bit-Select `buf_data[rd_addr]` und `buf_data[wr_addr] <= data_in` — vollständig sequenziell ausgeführt, lt. Header ~500 LUT/460 FF.

---

### tetra_depuncture_r23.v (126 Zeilen)
**Ports:** `clk_sys, rst_n_sys, data_in, data_in_valid, block_start` → `soft_0[2:0], soft_1[2:0], soft_2[2:0], soft_3[2:0], output_valid, block_done`

**Funktion:** Rate-2/3 → Rate-1/4 Depuncturer. Für jeweils 3 Input-Bits werden 2 Trellis-Stages × 4 Soft-Werte ausgegeben:
- Stage A: g1(a)=bit0, g2(a)=bit1, g3(a)=ERASURE=4, g4(a)=ERASURE
- Stage B: g1(b)=bit2, g2(b)=ERASURE, g3(b)=ERASURE, g4(b)=ERASURE

Bit→Soft: 0→0, 1→7, Punktiert→4.

**State:** 2-bit `in_cnt_sys` (0/1/2/3). `block_start` setzt zurück. Cycle 0-2: Input bits zwischenspeichern; Cycle 2 emittiert Stage A; "Phantom"-Cycle in_cnt=3 emittiert Stage B → zurück nach 0.

**Pipeline-Latenz:** Stage A wird mit Bit 2 emittiert, Stage B 1 Zyklus später.

**Nachbarn:** Im aktuellen Subset nicht direkt instanziiert (DL-Pfad nutzt es vermutlich); SCH/HU-Decoder hat eigene Inline-Depuncture-Logik.

**Auffälligkeiten:** Wird im `sch_hu_decoder` nicht verwendet — dieser duplicates die Logik intern via `vit_is_kept_w` Check.

---

### tetra_ul_sch_hu_decoder.v (471 Zeilen)
**Ports:** `clk_sys, rst_n_sys, scramb_init_sys[31:0], soft_bit0_sys[7:0], soft_bit1_sys[7:0], soft_valid_sys, soft_first_sys, soft_last_sys, soft_half_sys` → `info_bits_sys[91:0], info_valid_sys, crc_ok_sys, decodes_attempted_sys[15:0], decodes_ok_sys[15:0]`

**Funktion:** Komplette SCH/HU-RX-Pipeline aus 168 Soft-Dibits zu 92 Info-Bits + CRC-OK-Flag. Stufen: (1) Sammle 168 Soft-Bits (`buf_soft_sys[0..167]`), parallel LFSR §8.2.5 erzeugt Scrambler-Sequenz aus `scramb_init` (Galois 32-bit, Taps 0,6,9,10,16,20,21,22,24,25,27,28,30,31). (2) Descramble: Bit für Bit Sign-Flip bei `scramb_seq=1`. (3) Deinterleave (a=13, K=168, multiplikativ — Adresse inkrementell). (4) Feed Viterbi: 112 Stages × 4 Soft-Werte, Depuncture per `vit_is_kept_w` (`(stage*4+g) mod 8 ∈ {0,1,4}`); Nicht-kept → Erasure (VIT_CENTER=8). (5) Drain Viterbi: 112 Bits in `vit_out_buf_sys`, davon ersten 108 = 92 Info + 16 FCS. (6) Feed CRC16 (Modul `tetra_crc16`). (7) Latche `info_bits_sys=vit_out_buf[91:0]` mit `crc_ok_sys`, puls `info_valid_sys`.

**State:** 4-bit FSM 8 Zustände: `S_IDLE → S_COLLECT → S_DESCRAMBLE → S_DEINTERLEAVE → S_FEED_VIT → S_DRAIN_VIT → S_FEED_CRC → S_DONE → S_IDLE`. `decodes_attempted_sys++` beim ersten `soft_valid` (Eintritt S_COLLECT); `decodes_ok_sys++` nur bei CRC-OK.

**Pipeline-Latenz:** Insgesamt ~2k Zyklen pro Burst (Collect 168 (gestreamt), Descramble 168, Deinterleave 168, Feed-Vit 448 = 112×4, Drain ~3×112+1, Feed-CRC 108). Bei 100 MHz und Burst-Spacing ≥7 ms (700k Zyklen) reichlich Margin.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_ul_sch_hu`); ↓ `tetra_ul_viterbi_r14` (`u_viterbi`, MAX_STAGES=112), `tetra_crc16` (`u_crc16`).

**Auffälligkeiten:**
- Local-Buffers `buf_soft_sys [0:N_TX-1]` und `buf_deint_sys [0:N_TX-1]` als 2D-reg arrays mit `for (idx_i...)`-Reset-Loop — kein flat-bus wie sonst.
- `to_vit_soft`-Function: signed 8-bit → unsigned `VIT_SOFT_WIDTH`-bit (default 5 via Top-Param-Wert, im Modul localparam set auf 5 via `VIT_SOFT_WIDTH=5`). Mapping: diff = CENTER - s_in, clamp [0..MAX]. Header-Kommentar erwähnt 4-bit als Default, der Source-Default ist aber 5.
- `vit_kept_idx_sys` läuft NUR vorwärts wenn `vit_is_kept_w=1`; mit Depuncture-Pattern 3/8 = 3 kept aus 8 pro Stage-Pair, gesamt 168 kept Inputs auf 448 Mother-Bits.

---

### tetra_ul_mac_access_parser.v (389 Zeilen)
**Ports:** `clk_sys, rst_n_sys, info_bits_sys[91:0], info_valid_sys, crc_ok_sys` →
- MAC-Header: `pdu_type_sys, fill_bit_sys, encryption_mode_sys, ul_addr_type_sys[1:0], ul_issi_sys[23:0], ul_event_label_sys[9:0], optional_field_flag_sys, ul_frag_flag_sys, ul_reservation_req_sys[3:0], ul_length_ind_sys[4:0]`
- TL-SDU/LLC: `mm_pdu_type_sys[3:0], loc_upd_type_sys[2:0], raw_info_bits_sys[91:0]`
- Status: `pdu_valid_sys, pdu_count_sys[15:0]`
- BL-ACK: `bl_ack_valid_sys, bl_ack_nr_sys, bl_ack_count_sys[15:0]`
- LLC-Flags: `ul_llc_is_bl_data_sys, ul_llc_is_bl_ack_sys, ul_llc_has_fcs_sys, ul_llc_ns_valid_sys, ul_llc_ns_sys, ul_llc_nr_valid_sys, ul_llc_nr_sys, ul_llc_is_mle_mm_sys, ul_llc_mm_pdu_type_sys[3:0], ul_llc_mm_loc_upd_type_sys[2:0], ul_llc_pdu_type_sys[3:0], ul_mle_disc_sys[2:0]`
- Continuation (Phase 7 F.1): `ul_pdu_is_continuation_sys, ul_continuation_valid_sys, ul_continuation_bits_sys[84:0], ul_continuation_ssi_sys[23:0], ul_continuation_count_sys[15:0]`

**Funktion:** Parst die 92 Info-Bits eines SCH/HU-CRC-OK-Frames. `info_bits[0]` = mac_pdu_type:
- `=0` → MAC-ACCESS-Pfad. Extrahiert MSB-first: fill_bit[1], encrypt[2], addr_type[3..4], address(24)[5..28], opt_flag[29], length_or_cap[30], frag_flag[31] oder length_ind[31..35], reservation_req[32..35]. TL-SDU-Start = bit 36 (opt=1) oder 30 (opt=0).
- `=1` → MAC-END-HU-Pfad. Pulse `ul_continuation_valid_sys` und packe info_bits[7..91] MSB-first in `ul_continuation_bits_sys[84:0]`. SSI ist bereits gelatcht (s.u.).

LLC-Parse (TL-SDU): 4-bit `{link_type, has_fcs, bl_pdu_type[1:0]}` an [tl_sdu+0..+3]. BL-ACK detect = link_type=0 & bl_pdu_type=11. BL-ADATA = 00, BL-DATA = 01. Für BL-DATA/ADATA wird MLE-pd (3 bit) und mm_pdu_type (4 bit) am LLC-Payload-Start gelesen. Auf MAC-ACCESS mit `frag_flag=1` AND `addr_type ∈ {0,2,3}` wird `ul_continuation_ssi_sys <= f_issi` gelatcht (=> nächste MAC-END-HU bekommt diese SSI als Tag).

**State:** Keine FSM — alle Outputs werden in einem einzigen Always-Block auf `info_valid_sys & crc_ok_sys` registriert.

**Pipeline-Latenz:** 1 Zyklus von info_valid/crc_ok zum Output-Puls.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_ul_mac_parser`); ↓ keine.

**Auffälligkeiten:**
- `f_event_label = f_issi[23:14]` (oberste 10 bit des Address-Slots).
- TL-SDU-Start hardcoded 30/36 — Kommentar: "MS bei Registrierung setzt opt_flag=1 length_or_cap=1 frag=1 → TL-SDU-Offset 36".
- "Removed: short_ssi_sys" — Kommentar dokumentiert dass früherer 10-bit-Output gelöscht wurde wegen Bit-Misalignment; alle Consumer nutzen `ul_issi_sys[23:0]`.
- Generate-Loop `g_continuation_bits` invertiert Bit-Reihenfolge: `bus[84-gci] = info_bits[7+gci]`.

---

### tetra_ul_demand_reassembly.v (243 Zeilen)
**Ports:** `clk_sys, rst_n_sys, t0_frames_sys[3:0], frame_tick_sys, frag1_pulse_sys, frag1_ssi_sys[23:0], frag1_bits_sys[43:0], frag1_mm_type_sys[3:0], end_hu_pulse_sys, end_hu_ssi_sys[23:0], end_hu_bits_sys[84:0]` → `reassembled_valid_sys, reassembled_body_sys[128:0], reassembled_ssi_sys[23:0], reassembled_mm_type_sys[3:0], reassembled_cnt_sys[15:0], drop_cnt_sys[15:0], busy_slots_sys[1:0]`

**Funktion:** Spleißt 44-bit MAC-ACCESS-Frag-1 mit 85-bit MAC-END-HU zu 129-bit MM-Body. Zwei In-Flight-Slots (s0, s1). Auf `frag1_pulse`: same-SSI Replace > erste freie Slot-Alloc > sonst drop_cnt++. Auf `end_hu_pulse` und SSI-Match: `reassembled_body_sys = {s_frag1, end_hu_bits_sys}` (MSB-first, bit 128 = erstes On-air-Bit), Slot freigeben, `reassembled_valid_sys` 1 Zyklus. T0-Timer (Default 2 Frames ≈ 113 ms) pro Slot, dekrementiert auf `frame_tick_sys`; bei 0 → Slot frei + drop_cnt++. `frag1_mm_type_sys` wird zusammen mit dem Fragment im Slot gelatcht und am Output passthrough.

**State:** Keine FSM, nur Slot-Bookkeeping-Logik (`s0_occ`, `s0_ssi`, `s0_frag1`, `s0_t0_left`, `s0_mm_type` und analog s1).

**Pipeline-Latenz:** `reassembled_valid_sys` 1 Zyklus nach `end_hu_pulse_sys & match_any`.

**Nachbarn:** ↑ `tetra_zynq_top` (vermutlich; nicht in rx_chain instanziiert); ↓ keine.

**Auffälligkeiten:**
- `s0_match` Slot 0 hat Priorität bei Tie (älter).
- `drop_new = s0_occ & s1_occ & !replace` — Verdoppelung bei zwei vollen Slots und neue SSI → silent drop + counter.

---

### tetra_ul_demand_ie_parser.v (940 Zeilen)
**Ports:** `clk_sys, rst_n_sys, start_sys, body_sys[128:0], ssi_sys[23:0], mm_pdu_type_sys[3:0]` →
- mm=2 LOC-UPDATE Felder: `location_update_type_sys[2:0], request_to_append_la_sys, cipher_control_sys, class_of_ms_sys[23:0], class_of_ms_valid_sys, energy_saving_mode_sys[2:0], energy_saving_mode_valid_sys, la_information_sys[13:0], la_information_valid_sys, ssi_field_sys[23:0], ssi_field_valid_sys, address_ext_sys[23:0], address_ext_valid_sys`
- GILD: `gild_valid_sys, gild_gssi_sys[23:0], gild_class_of_usage_sys[2:0], gild_address_type_sys[1:0]`
- pdu_ssi_sys[23:0] (passthrough)
- mm=7 ATTACH/DETACH-GROUP-ID: `gid_count_sys[1:0], gid_attach_detach_mode_sys, gid_group_identity_report_sys, gid_attach_detach_array_sys[2:0], gid_class_array_sys[8:0], gid_address_type_array_sys[5:0], gid_gssi_array_sys[71:0]`
- Status: `parse_done_sys, parse_ok_sys`

**Funktion:** Walker-FSM für das 129-bit MM-Body. Auf `start_sys`: Body in `body_buf`, cursor=129, mm_pdu_type latched → Dispatch.
- mm==2: `S_HEADER_T1` (3-bit loc_update_type, 1-bit req_to_append_la, 1-bit cipher_control; bei cipher=1 skip 10-bit cipher_params) → `S_OPT_OBIT` → Type-2-Presence-Chain (`S_T2_CLASS_P/ESM_P/LA_P/SSI_P/AE_P`) → `S_T3_M` Loop (m-bit Terminator). Für `elem_id=3` (GroupIdentityLocationDemand) snapshot `gild_buf`, dann `S_T3_PAYLOAD_GILD` decodet erstes GIU-Element. Andere elem_id → skip payload.
- mm==7: `S_GAD_HDR` (group_identity_report + atd_mode) → `S_GAD_OBIT` → `S_GAD_M_REP` (peek for GroupReportResponse elem_id=4, optional skip) → `S_GAD_M_GIU` (elem_id=8) → pipelined GIU-Walker `S_GAD_GIU_INIT/REC_HDR/REC_GSSI`, bis zu 3 GIU-Records werden in Output-Arrays geschrieben.

**State:** 5-bit FSM mit 20 Zuständen: S_IDLE, S_HEADER_T1, S_OPT_OBIT, S_T2_CLASS_P, S_T2_ESM_P, S_T2_LA_P, S_T2_SSI_P, S_T2_AE_P, S_T3_M, S_T3_HEADER, S_T3_PAYLOAD_GILD, S_DONE, S_DONE_FAIL, S_GAD_HDR, S_GAD_OBIT, S_GAD_M_REP, S_GAD_M_GIU, S_GAD_GIU_INIT, S_GAD_GIU_REC_HDR, S_GAD_GIU_REC_GSSI. Bei Stream-Underrun → S_DONE_FAIL → parse_done+parse_ok=0.

**Pipeline-Latenz:** Variable; mm=2 Demand-Body typisch ~10 Zyklen, mm=7 mit 2 Records ~5 + 3 + 4 = 12 Zyklen.

**Nachbarn:** ↑ vermutlich `tetra_zynq_top` (Top-Level); ↓ keine.

**Auffälligkeiten:**
- Header explizit: "Phase Y.1.a-fix — pipelined GIU walker": ursprünglicher One-Cycle-Walker hatte Timing-Violation (~29 logic levels @ 100 MHz). Aktueller Walker bricht record-Verarbeitung in 2 Zyklen (HDR + GSSI) auf.
- `gild_buf` ist 256-bit obwohl GILD payload max ~57 bits — Reserve für flexible Snapshot-Shift `>> (cursor - cur_elem_len)`.
- Block `S_T3_PAYLOAD_GILD: gild_decode` deklariert lokale `reg` Variablen mit Begin-End-Block (Verilog-2001-Syntax) statt Outer-Module-Regs.
- mm=7 GIU-Records werden gestackt in 3-Slot-Arrays (jedes Feld 3× breiter als Single-Record) — Limit 3 Records aus 6-bit num_elem (theoretisch bis 63).
- atd_mode in GILD-Decoder wird gelesen aber TIE-OFF: Kommentar `// future: detach path`.

---

### tetra_steal_detect.v (145 Zeilen)
**Ports:** `clk_sys, rst_n_sys, aach_data_sys[13:0], aach_valid_sys, slot_num_sys[1:0], burst_type_sys[1:0]` → `steal_active_sys[3:0], access_code0_sys[5:0], access_code1_sys[5:0], access_code2_sys[5:0], access_code3_sys[5:0]`

**Funktion:** Dekodiert AACH-Access-Code aus den oberen 6 bit des 14-bit Reed-Muller-decodierten AACH-Felds. Steal-Bedingung: `access_code[5:3] == 3'b001` (deckt STCH=001000 und STCH+ACCH=001001 ab). Nur auf NDB (`burst_type==0`) aktiv; SB/NUB ignoriert. Per-Slot Bit `steal_active_sys[slot_num]` wird gesetzt/zurückgesetzt, und der 6-bit Access-Code wird in slot-spezifisches Register kopiert (access_code0..3).

**State:** Keine FSM, nur 5 Register (`steal_active_sys`, vier `access_codeN_sys`).

**Pipeline-Latenz:** 1 Zyklus von `aach_valid_sys` zu Output-Update.

**Nachbarn:** ↑ vermutlich LMAC-Level (nicht im aktuellen Subset-rx_chain instanziiert); ↓ keine.

**Auffälligkeiten:**
- `aach_data_sys[7:0]` (Secondary Field) wird gar nicht ausgewertet — Modul fokussiert sich nur auf Access-Code.
- Default-Case `default: ;` im case auf slot_num leer (keine Update auf undefiniertem Slot).

---

### tetra_ul_voice_capture.v (135 Zeilen)
**Ports:** `clk_sys, rst_n_sys, ul_dibit_sys[1:0], ul_dibit_valid_sys, tdma_slot_pulse_sys, tdma_tn_now_sys[1:0], tdma_fn_now_sys[4:0], voice_active_mask_sys[3:0]` → `voice_burst_valid_sys, voice_burst_coded_sys[431:0], voice_burst_target_tn_sys[1:0], voice_burst_aach_sys[13:0], voice_burst_pdu_type_sys[1:0], capture_cnt_sys[15:0]`

**Funktion (laut Code):** Slot-aligned UL-Dibit-Capture. Auf jedem `tdma_slot_pulse_sys`: wenn `voice_active_mask_sys[tdma_tn_now_sys]=1` → setze `capturing_sys=1`, `dibit_idx=0`, latche TN+FN, leere `burst_buf`. Sonst → `capturing_sys=0`. Während `capturing_sys=1` UND `ul_dibit_valid_sys=1`: shift dibit in `burst_buf` MSB-first. Bei dibit 216 (= 432 Bits voll): emit `voice_burst_valid_sys`-Puls, übernimm `burst_buf` in Output, setze AACH-Wert nach FN-Mapping:
- FN 1-9 (`lat_fn_sys <= 8`) → 0x32CB (TCH/S voice)
- FN 10-13 (`<= 12`) → 0x22C9 (FACCH stealing)
- FN 14-17 (`> 12`) → 0x2049 (idle filler)

`voice_burst_pdu_type_sys` immer 0 (SCH/F NDB1). Counter `capture_cnt_sys` saturiert bei 0xFFFF.

**State:** Keine explizite FSM. Implizite states: idle, capturing. Übergang über `capturing_sys`-Flag, gesteuert über `tdma_slot_pulse_sys` und Dibit-Counter.

**Pipeline-Latenz:** 216 Dibits = 216 × (clk_sys/dibit_rate) ≈ 216 × 5556 ≈ 1.2M Zyklen (= ~12 ms bei 18 kHz Dibit-Rate).

**Nachbarn:** ↑ `tetra_zynq_top` (`u_ul_voice_capture`, instanziiert direkt im Top-Level, nicht in rx_chain); ↓ keine.

**Inputs (aktuell verdrahtet in `tetra_zynq_top.v` ab Zeile 3586):**
- `ul_dibit_sys` ← `ul_demod_dibit_sys_w` ← `tetra_rx_chain.ul_demod_dibit_out_sys` ← (im rx_chain) `demod_dibit_sys` (= Output von `u_demod` = DL-pi4dqpsk_demod)
- `ul_dibit_valid_sys` ← `ul_demod_valid_sys_w` ← `tetra_rx_chain.ul_demod_valid_out_sys` ← `demod_valid_sys`
- `tdma_slot_pulse_sys` ← `tx_tdma_state_slot_pulse_sys` (TX-TDMA, nicht RX-frame-counter)
- `tdma_tn_now_sys` ← `tx_tdma_state_tn_sys`
- `tdma_fn_now_sys` ← `tx_tdma_state_fn_sys`
- `voice_active_mask_sys` ← `voice_active_mask_sys_r1` (CDC-resync von AXI-Register `voice_active_mask_axi_w[3:0]`)

**Bedingungen, unter denen `voice_burst_valid_sys_w` pulsen würde:**
1. `voice_active_mask_sys[tdma_tn_now_sys] == 1` zum Zeitpunkt `tdma_slot_pulse_sys`
2. Innerhalb des dann begonnenen Capture-Fensters müssen 216 `ul_dibit_valid_sys`-Pulse auftreten BEVOR ein neuer `tdma_slot_pulse_sys` kommt mit `voice_slot_gate_w=0`
3. Wenn 216 Dibits gesammelt → Puls

**Was passiert im aktuellen Wiring tatsächlich:**
- Quelle des Dibit-Streams ist NICHT der UL-spezifische `u_ul_demod` (der ist SCH/HU-sync-gegated und feuert nur auf x-seq-Bursts), sondern der **DL-Hauptdemod** `u_demod` aus `tetra_rx_chain`. Sein Output `demod_dibit_sys / demod_valid_sys` wird in rx_chain direkt an `ul_demod_dibit_out_sys / ul_demod_valid_out_sys` durchgereicht (Phase-Y.4.2-Kommentar erklärt: RX-LO sei auf UL-Band, daher sei DL-demod faktisch das MS-UL-Signal).
- `u_demod` arbeitet auf `tr_i_sys/tr_q_sys`, dem Gardner-getakteten 18 kHz On-Time-Stream — das heißt: `dibit_valid` puls jedes Mal wenn der Timing-Recovery NCO überläuft, also kontinuierlich bei 18 kHz solange Signal anliegt (es gibt KEINEN sync-Gate vor dem demod).
- Die Annahme im Kommentar "demod_dibit_sys IS the MS UL signal" hängt also komplett davon ab, ob die RX-LO tatsächlich auf der UL-Frequenz liegt UND ob das Timing-Recovery auf einem MS-UL-Burst überhaupt konvergiert.
- `tdma_slot_pulse_sys / tn_now_sys / fn_now_sys` kommen von der **TX-TDMA-State-Machine**, nicht vom RX-`frame_counter`. Slot-Pulse-Timing ist daher TX-side.

**Auffälligkeiten:**
- Modul ist instanziiert (Zeilen 3586-3601 in `tetra_zynq_top.v`) und seine Outputs sind via `cmce_port_wr_valid_w = voice_burst_valid_sys_w | nwrk_bcast_push_valid_sys_w` in den CMCE-Port-Write-Pfad verdrahtet — wenn der Puls je auftritt, fließen die Daten in die DL-signal-queue als Voice-Burst.
- Header-Kommentar mehrfach "Phase Y.4.2/Y.4.3" — frisch hinzugefügter Code.
- `voice_burst_pdu_type_sys` immer `2'd0` (SCH/F NDB1), egal welcher AACH-Wert, lt. Kommentar bewusst — AACH steuert MS-Interpretation.
- Die ursprünglich erwartete UL-RX-Pipeline (`u_ul_demod` SCH/HU-aligned) wird vom voice_capture NICHT genutzt; stattdessen direkter DL-demod-Dibitstrom. Damit ist die korrekte Anordnung "kontinuierlicher post-DQPSK Dibit-Strom" nur dann, wenn:
 - RX-LO tatsächlich auf UL-Frequenz konfiguriert ist (nicht aus dem Code prüfbar, hängt von AXI-Setup)
 - Timing-Recovery auf den MS-UL-Burst konvergiert (Gardner ist nicht UL-Burst-tauglich lt. Kommentar in `tetra_ul_sync_detect_os4.v`: "isolated UL bursts are only 127 symbols long (~7 ms), the Gardner TED in the main RX chain does not converge before the burst ends")
- Aus dem Code-Verlauf direkt sichtbar: der Stream den `voice_capture` bekommt ist im DL-Stand-by exakt der DL-pi4dqpsk_demod-Strom mit DL-Symboltakt (Gardner-NCO-getrieben). Auf UL-Slot-Pulse-Edge ist der TX-TDMA-Counter aktiv, aber der Demod-Strom ist phänomenologisch nicht garantiert MS-UL.
- `voice_burst_valid_sys_w` würde funktional pulsen wenn (a) AXI `voice_active_mask` non-zero gesetzt UND (b) im TX-Slot-TN-Fenster (TX-getriggert) 216 zusammenhängende dibit_valid-Pulse anfallen. Beim aktuellen Wiring kommen die dibit_valid-Pulse aber aus dem DL-pi4dqpsk_demod, der eine 18-Zyklus-Latenz pro Symbol braucht — bei 100 MHz / 18 kHz = 5556 Zyklen pro Symbol, ist genug Zeit. Der Demod gibt seine dibit_valid weiter solange die Timing-Recovery NCO überläuft. Ob der Stream während des MS-UL-Bursts überhaupt sinnvolle Bits produziert ist aus dem RTL-Verlauf nicht entscheidbar — der DL-demod hat KEINE Gate-Bedingung mit DL-`sync_locked` oder Burst-Fenster.

**Korrektur zu Annahme im Auftrag-Text:** der Auftrag stellte fest dass rx_chain "demod_dibit_sys aus DL-Sync-gegated demod weiterleitet". Aus dem Code (`u_demod` wird mit `tr_i_sys/tr_q_sys/tr_valid_sys` direkt vom timing_recovery gefüttert, nicht von sync_detect gegated) ist diese Aussage NICHT bestätigbar — der DL-pi4dqpsk_demod feuert kontinuierlich, sobald Gardner irgendetwas hat. Es existiert kein Gating-Pfad zwischen `sync_locked_w` und `u_demod.sample_valid` im rx_chain. `voice_burst_valid_sys` ist daher NICHT durch eine fehlende DL-Sync-Bedingung blockiert.

Die wahrscheinlichsten realen Blocker für `voice_burst_valid_sys_w`-Puls sind:
- `voice_active_mask_sys_r1` ist Reset-Default 4'd0 (siehe `tetra_zynq_top.v:3574-3579`) — solange SW über AXI keine Bits setzt, gate `voice_slot_gate_w = mask[tn_now]` permanent 0 → `capturing_sys` wird nie gesetzt.
- Wenn SW Maske setzt, hängt es davon ab ob in 216 zusammenhängenden DL-pi4dqpsk_demod-Dibits ein konsistenter MS-UL-Frame liegt — Bit-Inhalt unklar; Pulse aber technisch möglich.
