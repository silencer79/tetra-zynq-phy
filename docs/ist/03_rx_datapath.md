# IST — Kapitel 3: RX Datapath (core)
Stand: 2026-05-17
Quelle: rtl/rx/tetra_{rx_frontend,timing_recovery,pi4dqpsk_demod,sync_detect,burst_demux,frame_counter,rx_burst_fifo,rx_chain}.v

## Inhalt
1. `tetra_rx_frontend.v` — CDC LVDS→sys, 5th-order CIC R=64, 33-tap RRC
2. `tetra_timing_recovery.v` — Gardner TED + 32-bit NCO + PI-Loop
3. `tetra_pi4dqpsk_demod.v` — π/4-DQPSK CORDIC vectoring + Differenzphasen-Dibit
4. `tetra_sync_detect.v` — Sliding-Correlator NTS/ETS/STS
5. `tetra_burst_demux.v` — NDB Block1/BB/Block2 Extractor
6. `tetra_frame_counter.v` — TN/FN/MN/HF-Zähler
7. `tetra_rx_burst_fifo.v` — 16-tiefe UL-Burst-FIFO (BRAM18)
8. `tetra_rx_chain.v` — Container (instanziiert alle obigen + UL-Pfad)

---

### tetra_rx_frontend.v (791 Zeilen)
**Ports:**
- `clk_sys, rst_n_sys` (system 100 MHz domain)
- `clk_lvds, rst_n_lvds, rx_i_lvds[15:0], rx_q_lvds[15:0], rx_valid_lvds` (AD9361 LVDS-Domain)
- `loopback_en_sys` (digital loopback flag)
- → `i_out_sys[15:0], q_out_sys[15:0], out_valid_sys`

**Funktion:** Drei-Stufen-RX-Frontend mit Clock-Domain-Crossing. Schritt 1: 32-bit XPM async FIFO `u_iq_cdc_fifo` (Tiefe 16, READ_LATENCY=1) packt {I,Q} aus `clk_lvds` in `clk_sys`. Schritt 2: 5-stufiger CIC-Dezimator R=64, M=1 (interne 46-bit Akku, Gain-Shift `CIC_GAIN_SHF=6` für ×64 vor Sättigung auf 16 bit; bei `loopback_en_sys`=1 wird der Gain umgangen und unity-Slice [45:30] genutzt). Schritt 3: 33-tap RRC-Matched-Filter, α=0.35, Q14-Koeffizienten als `RRC_H00..RRC_H32` Localparams, sequenzielle MAC mit 1 DSP48 über 33 Zyklen. Ausgabe `out_valid_sys` puls je 72 kHz Symbolsample.

**State:** RRC-MAC FSM (1 bit) S_IDLE / S_MAC. `S_IDLE→S_MAC` bei `cic_valid_sys`. `S_MAC→S_IDLE` wenn `mac_cnt_sys == RRC_TAPS-1` (= 32). Akkumulator wird auf erstem MAC-Zyklus mit erstem Produkt geladen, sonst summiert.

**Pipeline-Latenz:**
- FIFO read: 2 Zyklen
- CIC integrators: 0 (kombinatorisch, registriert beim Strobe)
- CIC combs: 1
- RRC MAC: 33
- gesamt ~36 clk_sys Zyklen ADC→RRC-Out
- Gruppenlaufzeit: 16 Output-Samples = 1024 ADC-Samples

**Nachbarn:** ↑ `tetra_rx_chain` (`u_rx_frontend`); ↓ keine Submodule (nur XPM-FIFO).

**Auffälligkeiten:**
- Kommentar `loopback_en_sys`: erklärt warum CIC-Gain bei Loopback umgangen wird (Loopback ist schon full-scale).
- `unused_ok` synthesis-translate-off Konstrukt unten zur Lint-Beruhigung.
- Saturation-Logik in zwei Stufen: CIC-Ausgang (CIC_WIDE_BITS=22 → 16 bit) und RRC-Ausgang (38-bit Akku → 16 bit nach `>>> RRC_ACC_SHIFT=14`).

---

### tetra_timing_recovery.v (407 Zeilen)
**Ports:** `clk_sys, rst_n_sys, i_in_sys[15:0], q_in_sys[15:0], sample_valid_in_sys` → `i_out_sys[15:0], q_out_sys[15:0], sample_valid_out_sys, timing_locked_sys, timing_error_sys[15:0]`

**Funktion:** Gardner Symbol-Timing-Recovery aus 4×oversampleten 72 kHz Samples. Schiebt jedes Sample in 4-Tap-Register `i_s0..i_s3` (16-bit signed) und berechnet bei NCO-Overflow `e = i_s1*(i_in - i_s3) + q_s1*(q_in - q_s3)`. PI-Loop: Proportionalterm `>>> KP_SHIFT=4`, Integralterm `>>> KI_SHIFT=8`. NCO 32-bit Akkumulator, Nominalschritt `NCO_NOMINAL = 32'h4000_0000` → 4 Steps = Overflow alle 4 Eingangssamples. Bei Overflow werden `i_in, q_in` als On-Time-Sample latched und `sample_valid_out_sys` ausgegeben (18 kHz).

**State:** Keine explizite FSM. Lock-Detection registriert: `lock_cnt_sys` (8 bit, sat. bei 255) inkrementiert wenn `|TED| < LOCK_THRESH=256`, Reset auf Großfehler. `timing_locked_sys` geht hoch wenn `lock_cnt >= LOCK_COUNT=144` und gut, runter bei jedem schlechten Sample.

**Pipeline-Latenz:** `sample_valid_out_sys` 1 Zyklus nach NCO-Overflow; `i_out/q_out` synchron registriert.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_timing_recovery`); ↓ keine Submodule.

**Auffälligkeiten:**
- In `tetra_rx_chain.v` wird `timing_locked_sys` und `timing_error_sys` an OPEN (`()`) angeschlossen — beide Outputs des Timing-Rec sind nirgends verdrahtet. Der vom `pi4dqpsk_demod` ausgegebene `phase_error` wird stattdessen als chain-`phase_error_sys` exportiert.
- Output-Ports `i_out_sys`, `q_out_sys` werden auch unverändert bei Overflow latched, kein Interpolations-Filter.

---

### tetra_pi4dqpsk_demod.v (447 Zeilen)
**Ports:** `clk_sample, rst_n_sample, i_in[15:0], q_in[15:0], sample_valid` → `dibit_out[1:0], dibit_valid, phase_error[15:0]` (signed)

**Funktion:** π/4-DQPSK-Demodulator basierend auf CORDIC-Vectoring. Pro Symbol: 1 Zyklus Quadrantenkorrektur (`I<0,Q≥0` → Rotation +π/2, `I<0,Q<0` → −π/2, sonst 0), 16 Zyklen CORDIC-Iteration (ATAN-LUT als case mit 14 nicht-trivialen Werten), 1 Zyklus Entscheidung. Δφ = `cordic_z - phase_prev`. Dibit-Mapping: Δφ∈[0,+π/2)→00, [+π/2,+π)→01, (−π/2,0)→10, (−π,−π/2]→11. `phase_error = Δφ - ideal_Δφ`.

**State:** 2-bit FSM `S_IDLE/S_INIT/S_ITER/S_DECIDE`. `S_IDLE→S_INIT` bei `sample_valid`. `S_INIT→S_ITER` unbedingt. `S_ITER→S_DECIDE` wenn `iter_cnt==15`. `S_DECIDE→S_IDLE` unbedingt. `phase_locked_sample` wird in erstem `S_DECIDE` gesetzt — unterdrückt `dibit_valid`-Puls auf allererstes Symbol (kein gültiges `phase_prev`).

**Pipeline-Latenz:** 18 clk_sample Zyklen sample_valid → dibit_valid (1+16+1).

**Nachbarn:** ↑ `tetra_rx_chain` (`u_demod`); ↓ keine.

**Auffälligkeiten:**
- Kommentar erwähnt CORDIC-Gain ~1.647, daher CORDIC_WIDTH=18 (2 Guard-Bits gegen IQ_WIDTH=16).
- Konstanten `BOUND_POS=16384=+π/2`, `IDEAL_00=8192=+π/4` etc. in Q1.15-Format.

---

### tetra_sync_detect.v (466 Zeilen)
**Ports:** `clk_sample, rst_n_sample, dibit_in[1:0], dibit_valid, corr_threshold[5:0], seq_select[1:0]` → `sync_found, sync_locked, slot_position[7:0], slot_number[1:0], corr_peak[5:0]`

**Funktion:** Sliding-Correlator gegen drei Trainingssequenzen NTS (11 sym, 22 bit), ETS (15 sym, 30 bit), STS (19 sym, 38 bit). Hält 38-Symbol (76-bit) flachen Shift-Register, vergleicht beim eingehenden Dibit (`sreg_shifted = {sreg[73:0],dibit_in}`) gegen die per `seq_select` gewählte Referenz, zählt matchende Dibits in einem unrollten Adder-Tree. `sync_fire_sample = (corr >= corr_threshold) & ~holdoff & dibit_valid`. `sync_found` ist registrierte 1-Zyklus-Version davon. Holdoff-Counter 8-bit (`HOLDOFF=220`).

**State:** Lock-FSM mit 3 Zuständen `S_HUNT/S_ACQR/S_LOCK`:
- `S_HUNT→S_ACQR` bei erstem `sync_fire`
- `S_ACQR→S_LOCK` wenn `consec_cnt >= LOCK_COUNT=4` (gute Spacings hintereinander)
- `S_ACQR→S_HUNT` bei `spacing_timeout` (`> LOCK_TIMEOUT=3060`)
- `S_LOCK→S_HUNT` bei Spacing-Timeout
- `spacing_ok_sample` akzeptiert Vielfache von 1020 (1 Frame=4×255) bis 3060 (3 Frames) ±`LOCK_TOL=30` — toleriert 2 verpasste Detektionen.

**Pipeline-Latenz:** `sync_found` 1 Zyklus nach dem `dibit_valid` der das Fenster schließt.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_sync_detect`); ↓ keine.

**Auffälligkeiten:**
- Drei Referenzkonstanten `NTS_REF` (22-bit), `ETS_REF` (30-bit), `STS_REF` (38-bit) hartkodiert.
- `corr_peak` ist sticky-max seit letztem Reset — nur über `rst_n_sample` löschbar (kein dedizierter Clear-Input).
- `slot_number` inkrementiert NUR wenn `slot_position` wrap UND nicht zeitgleich `sync_fire` — Kommentar in `burst_demux.v` warnt davor.

---

### tetra_burst_demux.v (308 Zeilen)
**Ports:** `clk_sample, rst_n_sample, dibit_in[1:0], dibit_valid, sync_found, sync_locked, slot_position[7:0], slot_number[1:0], seq_select[1:0]` → `block1_data[215:0], block2_data[215:0], bb_data[29:0], slot_num_out[1:0], slot_valid, burst_type[1:0]`

**Funktion:** Extrahiert NDB-Felder aus dem Symbolstrom. Capture-Fenster nach `slot_position`:
- BB-Feld (AACH, 30 bit): pos 0..14, in `bb_shift_sample`
- Block2 (216 bit): pos 15..122, in `block2_shift_sample`
- emit-Puls: pos 123 (Block2 fertig)
- Block1 (216 bit, gehört zum NÄCHSTEN Slot): pos 125..232 in `block1_pend_sample`

Auf `sync_found` werden Block1 (das vor diesem Sync vollständig aufgesammelte) und `slot_cnt+1`, `seq_select` in `block1_lat_sample`, `slot_at_sync_sample`, `btype_at_sync_sample` gelatcht. Auf emit (pos=123) werden die Output-Register `block1_data, block2_data, bb_data, slot_num_out, burst_type` aktualisiert; `slot_valid` ist 1-Zyklus-Puls nach emit.

**State:** 2-bit FSM `S_HUNT/S_RUN`. `S_HUNT→S_RUN` bei `sync_locked=1`. `S_RUN→S_HUNT` bei `sync_locked=0`. Eigener Slot-Counter `slot_cnt_sample` inkrementiert bei jedem `sync_found` während `S_RUN` (lt. Kommentar weil `slot_number` von sync_detect bei sync@254 nicht weiterzählt).

**Pipeline-Latenz:** `slot_valid` 1 Zyklus nach emit (pos=123+1=124).

**Nachbarn:** ↑ `tetra_rx_chain` (`u_burst_demux`); ↓ keine.

**Auffälligkeiten:**
- Konstante `B1_POS_START=125` (nicht 124) — Kommentar erwähnt FreqCorr-Symbol auf pos 124 wird übersprungen.
- `block1_ready_sample` ist Promotion-Flag: nur wenn Block1 vorher vollständig aufgesammelt wurde, wird emit überhaupt zugelassen — beim ersten Burst nach Sync-Lock geht emit also nicht (Block1 fehlt noch).

---

### tetra_frame_counter.v (185 Zeilen)
**Ports:** `clk_sample, rst_n_sample, sync_locked, slot_pulse` → `timeslot_num[1:0], frame_num[4:0], multiframe_num[5:0], hyperframe_num[15:0], is_control_frame, frame_18_slot1`

**Funktion:** Zählt TETRA-TDMA-Hierarchie. Pro `slot_pulse` (= `slot_valid` aus burst_demux): `timeslot_num` 0→1→2→3→0; bei TS-Boundary (`timeslot_num==3`) `frame_num` 1..18; bei FN-Boundary (`frame_num==18`) `multiframe_num` 1..60; bei MF-Boundary (`multiframe_num==60`) `hyperframe_num++` (free-running 16-bit). `is_control_frame` HIGH solange `frame_num==18`; `frame_18_slot1` 1-Zyklus-Puls eine Frame-Cycle-Edge nachdem TN=1 von Frame 18 abgeschlossen ist.

**State:** Keine FSM, nur Counter-Register. Reset auf `!rst_n_sample` ODER `!sync_locked` setzt alle Counter auf Init (TS=0, FN=1, MF=1, HF=0).

**Pipeline-Latenz:** Counter aktualisieren synchron mit `slot_pulse`; `is_control_frame` via `next_frame_sample`-Lookahead in selber Edge; `frame_18_slot1` 1 Zyklus später.

**Nachbarn:** ↑ `tetra_rx_chain` (`u_frame_counter`); ↓ keine.

**Auffälligkeiten:**
- Frames 1-basiert (ETSI), Hyperframes 0-basiert.
- Synchroner Reset über `sync_locked=0` ist additiv zum async `rst_n_sample`.

---

### tetra_rx_burst_fifo.v (220 Zeilen)
**Ports:**
- Push A: `push_a_pulse_sys, push_a_bits_sys[91:0], push_a_ssi_sys[23:0], push_a_meta_sys[7:0]`
- Push B: `push_b_pulse_sys, push_b_bits_sys[91:0], push_b_ssi_sys[23:0], push_b_meta_sys[7:0]`
- Push-TS: `push_ts_sys[23:0]` (mf_global_cnt)
- Pop: `pop_pulse_axi` → `data0_axi[31:0], data1_axi[31:0], data2_axi[31:0], meta_axi[31:0], ts_axi[31:0], status_axi[31:0]`
- Telemetrie: `count_sys[4:0], drop_cnt_sys[15:0]`

**Funktion:** 16-tiefer BRAM-FIFO (DEPTH=16, ENTRY_WIDTH=148 bit = 92 bits + 24 SSI + 24 TS + 8 META) für UL-Bursts. Zwei Push-Ports mit Priorität A>B; bei Konflikt B verworfen mit `drop_cnt++`. Pop-Seite (clk_axi==clk_sys): `mem[rp]` ständig in `rd_q_sys` registriert, `pop_pulse_axi` advances `rp`. Status-Wort: `{drop_cnt[15:0], 8'b0, count[3:0], full, halffull, 1'b0, empty}`.

**State:** Keine FSM, nur Counter (`wp_sys`, `rp_sys`, `cnt_sys`, `drop_cnt_sys_r`).

**Pipeline-Latenz:** BRAM-Read-Latenz 1 Zyklus; Output-Daten stehen auf demselben Zyklus stabil wie der Pop-Puls (read-before-pop).

**Nachbarn:** ↑ Top-Level `tetra_zynq_top` (vermutlich; nicht in rx_chain instanziiert lt. grep — siehe Kapitel 4 Anmerkung).

**Auffälligkeiten:**
- Modul wird in `tetra_rx_chain.v` NICHT instanziiert (rx_chain hat keinen rx_burst_fifo). Es wird vermutlich in `tetra_zynq_top.v` direkt instanziiert.
- Header beschreibt Phase H.4.1, Anbindung an MAC-ACCESS/BL-ACK frag-1 (Push A) und MAC-END-HU Continuation (Push B).
- BRAM-Storage als `(* ram_style = "block" *) reg [ENTRY_WIDTH-1:0] mem_sys [0:DEPTH-1]` — Tools sollen 1× RAMB18 erkennen (2368 bits genutzt von 18 kbit).

---

### tetra_rx_chain.v (497 Zeilen)
**Ports (Container, ausgewählte Top-Signale):**
- `clk_lvds, rst_n_lvds, rx_i_lvds[15:0], rx_q_lvds[15:0], rx_valid_lvds`
- `clk_sys, rst_n_sys, corr_threshold_sys[23:0], seq_select_sys[1:0], loopback_en_sys`
- → DL: `block1_out_sys[215:0], block2_out_sys[215:0], bb_out_sys[29:0], slot_valid_sys, slot_num_out_sys[1:0], burst_type_out_sys[1:0]`
- → Frame: `timeslot_num_sys[1:0], frame_num_sys[4:0], multiframe_num_sys[5:0], hyperframe_num_sys[15:0], is_control_frame_sys, frame_18_slot1_sys`
- → Status: `sync_locked_sys, sync_found_sys, slot_position_sys[7:0], phase_error_sys[15:0], corr_peak_sys[23:0]`
- UL: `ul_reset_peak_sys, ul_scramb_init_sys[31:0]` → `ul_sync_found_sys, ul_corr_peak_sys[23:0], ul_best_phase_sys[1:0]`
- UL-PDU-Output: `ul_pdu_valid_sys, ul_pdu_count_sys[15:0], ul_pdu_type_sys, ul_fill_bit_sys, ul_encryption_mode_sys, ul_addr_type_sys[1:0], ul_issi_sys[23:0], ul_event_label_sys[9:0], ul_optional_field_flag_sys, ul_frag_flag_sys, ul_reservation_req_sys[3:0], ul_length_ind_sys[4:0], ul_mm_pdu_type_sys[3:0], ul_loc_upd_type_sys[2:0], ul_raw_info_bits_sys[91:0]`
- LLC-Flags: `ul_bl_ack_valid_sys, ul_bl_ack_nr_sys, ul_bl_ack_count_sys[15:0], ul_llc_is_bl_data_sys, ul_llc_is_bl_ack_sys, ul_llc_has_fcs_sys, ul_llc_ns_valid_sys, ul_llc_ns_sys, ul_llc_nr_valid_sys, ul_llc_nr_sys, ul_llc_is_mle_mm_sys, ul_llc_mm_pdu_type_sys[3:0], ul_llc_mm_loc_upd_type_sys[2:0], ul_llc_pdu_type_sys[3:0], ul_mle_disc_sys[2:0]`
- Continuation (Phase 7 F.1): `ul_pdu_is_continuation_sys, ul_continuation_valid_sys, ul_continuation_bits_sys[84:0], ul_continuation_ssi_sys[23:0], ul_continuation_count_sys[15:0]`
- Diag (Phase H.6.1): `schhu_attempted_sys[15:0], schhu_ok_sys[15:0]`
- ILA-Debug: `dbg_fe_valid_sys, dbg_tr_valid_sys, dbg_demod_valid_sys`
- **Phase E2 UL-NUB-Capture (Live, ab 2026-05-18 commit `cae5108`):** `voice_nub_coded_softs_sys[1727:0], voice_nub_coded_valid_sys, voice_nub_bursts_captured_sys[15:0]` plus `voice_nub_sync_thresh_sys[4:0]` config input. Soft-Output ist 432 nibble (= 4-bit signed soft pro Coded-Bit, Range [-8,+7]) statt früherem 1-bit hard. 2-stage Pipeline (DSP MREG + `i_prod_r`/`q_prod_r`) für WNS-Headroom; saturierende Slice via bitwise overflow detection (keine CARRY4-Kette). Sign-Inversion `(-i_prod_w) >>> SHIFT` für Konventions-Kongruenz zu legacy hard-path + SW-Viterbi (positive soft = bit '1'). Air-Test 4-Run-Median: BFI Soft ~3 % vs Hard ~6 % (2.1× Reduktion); im 320-Burst Sustained: Soft 1 % vs Hard 7 % (7× Reduktion). (Die Y.4.2-`ul_demod_dibit_out_sys/valid_sys`-Outputs sind seit A.1 Rollback entfernt.)

**Funktion:** Top-Container der RX-Kette. Instanziiert in Reihenfolge:
1. `u_rx_frontend` (CIC+RRC+CDC) → `fe_i_sys, fe_q_sys, fe_valid_sys` (72 kHz)
2. `u_timing_recovery` (Gardner+NCO) → `tr_i_sys, tr_q_sys, tr_valid_sys` (18 kHz)
3. `u_demod` (pi4dqpsk_demod) → `demod_dibit_sys, demod_valid_sys, demod_phase_err_sys`
4. `u_sync_detect` (sliding correlator) → `sync_found_w, sync_locked_w, slot_position_w, slot_number_w, corr_peak_w`
5. `u_ul_sync_detect` (`tetra_ul_sync_detect_os4`, SCH/HU x-seq instance) — getapt aus 72 kHz fe_*-Stream
6. `u_ul_burst_capture` + `u_ul_demod` + `u_ul_sch_hu` + `u_ul_mac_parser` (UL-RA-Burst-Pipeline)
7. **Phase C:** zweite `u_ul_sync_detect_nub` (`tetra_ul_sync_detect_os4` mit NTS1-Pattern, separate `voice_nub_sync_thresh_sys` Schwelle) + `u_ul_nub_capture` (`tetra_ul_nub_capture`, BKN1+BKN2 demod) — getapt aus demselben fe_*-Stream
8. `u_burst_demux` → block1/block2/bb/slot_valid
9. `u_frame_counter` → TN/FN/MF/HF

**State:** Reiner Container — kein eigener FSM-Code, nur Wiring + Status-Assignments + Debug-Assignments.

**Pipeline-Latenz:** Summe der Submodule (siehe oben). Die alte Y.4.2-Hack-
Verdrahtung (`ul_demod_dibit_out_sys = demod_dibit_sys`) ist mit A.1 Rollback
entfernt — Voice-NUB-Bursts laufen jetzt durch den dedizierten Phase-C-Pfad
(`u_ul_sync_detect_nub` → `u_ul_nub_capture`) mit NTS1-getriggerter
sample-aligned Demod. Siehe Ch 4 `tetra_ul_nub_capture.v`.

**Nachbarn:** ↑ `tetra_zynq_top` (Top-Level); ↓ alle obigen Submodule plus
`u_voice_nub_read_mailbox` (im Top, konsumiert die Phase-C-Outputs).

**Auffälligkeiten:**
- `timing_locked_sys` und `timing_error_sys` von `u_timing_recovery` an OPEN angeschlossen (siehe oben).
- Der UL-Pfad lebt parallel zum DL-Pfad mit demselben fe_*-Stream als Quelle (72 kHz @ 4 sps). Zwei `ul_sync_detect_os4`-Instanzen (eine für SCH/HU x-seq, eine für NUB NTS1) plus zwei separate Burst-Capture-Pfade.
- `tetra_rx_burst_fifo` ist hier NICHT instanziiert.
