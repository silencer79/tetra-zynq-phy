# IST — Kapitel 6: LMAC Signaling FSMs
Stand: 2026-05-17  · reviewed 2026-06-20 (Delta s.u.)
Quelle: rtl/lmac/tetra_{mle_registration_fsm,pre_reply_blck,pre_reply_slotgrant,dl_nwrk_broadcast,ul_demand_ie_parser}.v

> **Hinweis 2026-05-17:** `tetra_ul_demand_ie_parser.v` ist physisch in
> `rtl/lmac/` (formal LMAC), wird aber wegen UL-Pipeline-Kontext in
> [Ch 4 / UL RX](04_ul_rx.md) gelistet. **Shift-Register-Refactor**
> (commit `8b8cb41`): body_buf MSB-aligned LEFT-SHIFT, alle Reads auf
> fixe Positionen (`body_buf[128 -: W]`), cursor wird reiner
> bits-remaining Counter. GAD-GIU-Walker bekommt eigene `gad_buf[255:0]`
> Snapshot. Resultat im Vivado-Build: WNS Setup −0.020 → +0.008 ns
> (11 failing → 0 failing endpoints). Verifikation: `tb_ul_demand_ie_parser`
> (26/26 PASS) + `tb_ul_demand_ie_parser_mm7` (44/44 PASS), on-air
> 10 PTT-Runs durch.

---

### tetra_mle_registration_fsm.v (424 Zeilen)

**Ports:**

IN:
- `clk`, `rst_n`
- UL-MAC-ACCESS (alle in X.4 ignoriert / nur `_unused_ports`-Senke):
 - `ul_req_valid`, `ul_addr_type[1:0]`, `ul_ssi[23:0]`, `ul_la[13:0]`,
 `ul_loc_upd_type[2:0]`, `ul_use_l2sig`, `ul_llc_is_bl_data`,
 `ul_llc_ns_valid`, `ul_llc_ns`
 - `bl_ack_valid`, `bl_ack_nr`, `bl_ack_issi[23:0]`
 - `slot_pulse`
- Cell-Config (AXI): `cfg_la[13:0]`, `cfg_scramble_init[31:0]`,
 `cfg_mcch_tn[1:0]`, `cfg_energy_saving_info[13:0]`
- Detach (no-op): `ul_detach_valid`, `ul_detach_ssi[23:0]`
- Reply-Pull-Mailbox (X.2): `mb_ssi[23:0]`, `mb_la[13:0]`, `mb_addr_type[2:0]`,
 `mb_result[1:0]`, `mb_gila_gssi[23:0]`, `mb_gila_class[2:0]`,
 `mb_gila_lifetime[1:0]`, `mb_gila_present`, `mb_encryption[1:0]`,
 `mb_auth_result[1:0]`, `mb_go_pulse`
- Reply-Pull-Mailbox raw mode (Y.2): `mb_raw_mode_flag`, `mb_raw_mm_bits[127:0]`,
 `mb_raw_mm_len[7:0]`, `mb_raw_ns`, `mb_raw_nr`, `mb_raw_mle_pd[2:0]`
- Builder-Handshake-Return: `accept_build_done`, `accept_build_coded[431:0]`

OUT (Build-Request-Plane an shared `tetra_dl_pdu_builder` über Top-Level-Arbiter):
- `accept_build_req` (1-cyc pulse)
- `accept_build_ssi[23:0]`, `accept_build_addr_type[2:0]`,
 `accept_build_llc_pdu_type[3:0]`, `accept_build_random_access_flag`
- `accept_build_mm_pdu_bits[127:0]`, `accept_build_mm_pdu_len_bits[7:0]`
- `accept_build_scramble_init[31:0]`, `accept_build_mle_pd[2:0]`,
 `accept_build_ns`, `accept_build_nr`, `accept_build_aach_pattern[13:0]`

OUT (DL-Signalling-Queue):
- `req_valid`, `req_coded_bits[431:0]`, `req_pdu_type[1:0]`,
 `req_target_tn[1:0]`, `req_second_pdu_present`, `req_second_pdu_nr`

OUT (Debug):
- `busy`, `accept_pulse`, `detach_pulse`
- `drop_pulse`, `ack_pulse`, `retransmit_pulse`, `lost_pulse` (alle tied 0)

**Funktion:**
Thin-Trigger-FSM für DL-Replies. SW stagiert via AXI eine Reply-Pull-Mailbox
und pulst `mb_go_pulse`. Die FSM latched die Mailbox-Felder, pulst
`accept_build_req` an den extern instanziierten `tetra_dl_pdu_builder` und
liefert die fertigen 432-bit Coded-Bits in die DL-Signalling-Queue (`req_valid`).
Zwei Modi: `lat_raw_mode_flag=0` → MM-Body kommt vom internen
`tetra_d_location_update_encoder` (mm=2 ITSI-Attach); `lat_raw_mode_flag=1` →
MM-Body kommt direkt aus `mb_raw_mm_bits` (mm=11 Group-Ack / mm=2 SW-built /
CMCE D-CONNECT bei `mb_raw_mle_pd=3'b010`). U-ITSI-Detach läuft als reiner
Telemetrie-Stub durch `S_DETACH_NOOP`.

**State-Diagramm:**
- `S_IDLE` → `S_DETACH_NOOP` wenn `ul_detach_valid` (latched `ul_detach_ssi`,
 `busy=1`)
- `S_IDLE` → `S_BUILD_ACCEPT_REQ` wenn `mb_go_pulse` (latched: `mb_ssi`,
 `mb_addr_type`, `mb_raw_mode_flag`, `mb_raw_mm_bits`, `mb_raw_mle_pd`
 (mit `000`→`001` Default-MM), `mb_raw_mm_len`, `mb_raw_ns`, `mb_raw_nr`)
- `S_DETACH_NOOP` → `S_IDLE` (`detach_pulse=1` 1 cyc)
- `S_BUILD_ACCEPT_REQ` → `S_BUILD_ACCEPT_WAIT` (`accept_build_req=1` 1 cyc)
- `S_BUILD_ACCEPT_WAIT` → `S_DELIVER_ACCEPT` wenn `accept_build_done`
 (latched `accept_build_coded` in `req_coded_bits`; `req_pdu_type =
 PDUC_FINAL_LU_ACCEPT_FMT` = SCH/F; `req_target_tn = cfg_mcch_tn`;
 `req_second_pdu_present=0`, `req_second_pdu_nr=0`)
- `S_DELIVER_ACCEPT` → `S_IDLE` (`req_valid=1` und `accept_pulse=1` für 1 cyc)
- `default` → `S_IDLE`

**Pipeline-Latenz:**
Trigger→Output: `mb_go_pulse` (Zyklus 0) → `S_BUILD_ACCEPT_REQ` (1) →
`S_BUILD_ACCEPT_WAIT` (2..N, hängt vom externen `tetra_dl_pdu_builder`,
unklar aus diesem Code) → `S_DELIVER_ACCEPT` (N+1, hier kommt `req_valid`).
Minimum: 4 Zyklen (Detach-Stub) bzw. 3 Zyklen + externe Builder-Latenz.

**Nachbarn:**
- ↑ Trigger: `mb_go_pulse` aus `tetra_reply_mailbox.v` (SW über AXI
 REG_REPLY_GO). UL-MAC-ACCESS-Inputs sind verdrahtet aber komplett
 ignoriert.
- ↓ Submodule: `tetra_d_location_update_encoder u_dloc` (single-instance,
 nicht shared). Der gesamte MAC-RESOURCE + SCH/F-Encode-Pfad wurde in
 X.6 externalisiert nach `tetra_dl_pdu_builder.v` (ausserhalb des
 Moduls) und ist via `accept_build_*`-Port-Plane angebunden.

**Auffälligkeiten:**
- Die UL-MAC-ACCESS-Inputs (`ul_req_valid`...`bl_ack_issi`, `slot_pulse`)
 sowie `cfg_la`, `cfg_energy_saving_info`, `mb_la`, `mb_result`,
 `mb_encryption`, `mb_auth_result` sind ausschliesslich in
 `_unused_ports` als OR-Reduction-Senke geführt — Header-Kommentar
 bestätigt explizit: "Phase X.4: ignored" / "kept on the port for
 top-level wiring continuity".
- `drop_pulse`, `ack_pulse`, `retransmit_pulse`, `lost_pulse` sind als
 `output reg` deklariert, werden im Reset auf 0 gesetzt und in jedem
 Cycle erneut auf 0 defaultet — nirgends auf 1 gesetzt → permanent 0.
 Kommentar markiert sie als "tied 0 in X.4".
- `cmce_path_w = lat_raw_mode_flag && (lat_raw_mle_pd == 3'b010)` schaltet
 per kombinatorischem Mux die Build-Plane zwischen LU_ACCEPT (default)
 und CMCE_D_CONNECT-Konstanten (Z.78-296). Beide Pfade aktiv, einer
 fired per FSM-Run.
- `loc_acc_type` am `u_dloc` ist hart auf `3'b000` verdrahtet (Kommentar
 Z.232-237: legacy-Latch entfernt in X.7, weil "ul_req_valid was never
 wired").
- Phase-Tags im Code: X.4, X.5, X.6, X.7, Y.2, 7 G.4, 7 G.7. Header
 beschreibt X.7-Cleanup als "use_sw_body input mux + lat_la / lat_loc_upd_type
 / lat_gila_* fallback latches are gone" — keine sichtbaren toten Latches
 mehr im aktuellen Quelltext.
- `mb_raw_mle_pd == 3'b000` wird in Z.377-378 auf `3'b001` (MM-Default)
 gemappt — Mailbox-Reset-Wert ist 0, soll als MM gelten.

**Bekannte Bugs aus Kommentaren:** keine `BUG:`/`FIXME:`/`TODO:`-Marker.

---

### tetra_pre_reply_blck.v (216 Zeilen)

**Ports:**

IN:
- `clk_sys`, `rst_n_sys`
- `trigger_valid` (1-cyc pulse; top-binding =
 `iep_parse_done_sys & iep_parse_ok_sys`)
- `ul_ssi[23:0]`
- `cfg_mcch_tn[1:0]`, `cfg_scramble_init[31:0]`

OUT:
- `wr_blck_valid_sys` (reg, 1-cyc Push-Pulse)
- `wr_blck_coded_sys[431:0]` (`{216'd0, lat_coded_blk1}` — LSB-aligned)
- `wr_blck_pdu_type_sys[1:0]` (= `PDUC_BL_ACK_POST_FRAG2_FMT` = SCH/HD)
- `wr_blck_target_tn_sys[1:0]` (= `lat_target_tn`)
- `push_cnt_sys[15:0]`, `drop_cnt_sys[15:0]` (saturating)

**Funktion:**
Phase X.5 Mini-FSM. Trigger ist ein 1-cyc Pulse nach erfolgreichem
UL-Reassembly + IE-Parse (Frag-2 fertig). Baut intern eine 124-bit
BL-ACK-MAC-RESOURCE-PDU (über `tetra_mac_resource_bl_ack_builder` mit
`addr_type=PDUC_BL_ACK_POST_FRAG2_ADDRTYPE`, `random_access_flag=
PDUC_BL_ACK_POST_FRAG2_RA`, `nr=0`), encodet sie via
`tetra_sch_hd_encoder` auf 216 bits und pusht das Ergebnis in die
DL-Signal-Queue (SDS-Producer-Slot — laut Header "was tied off").

**State-Diagramm:**
- `S_IDLE` → `S_BUILD` wenn `trigger_pulse_w = trigger_valid & ~trigger_valid_q`
 (latched `ul_ssi → lat_ssi`, `cfg_mcch_tn → lat_target_tn`,
 `builder_start=1` für 1 cyc)
- `S_BUILD` → `S_ENC` wenn `builder_valid_w` (kickt `encode_start=1`).
 Bei `trigger_pulse_w` während busy: `drop_cnt_sys++` (saturiert).
- `S_ENC` → `S_PUSH` wenn `coded_valid_w` (latched 216-bit
 `coded_w → lat_coded_blk1`). Trigger-Drops zählen weiter.
- `S_PUSH` → `S_IDLE` (`wr_blck_valid_sys=1` für 1 cyc, `push_cnt_sys++`)
- `default` → `S_IDLE`

**Pipeline-Latenz:**
Trigger (0) → `S_BUILD` (1) → builder fertig (variabel) → `S_ENC` (M) →
encoder fertig (variabel) → `S_PUSH` (N) → `req_valid` (N). Inline-Kommentar
(Z.171-176) schätzt ~500 cycles @ 100 MHz = 5 µs gesamt. Aus dem Code allein
nicht exakt herleitbar (Builder + SCH/HD-Encoder sind extern).

**Nachbarn:**
- ↑ Trigger: `mle_demand_parsed_valid_sys` aus dem IE-Parser
 (`iep_parse_done_sys & iep_parse_ok_sys`) — Top-Level-Binding laut
 Header-Kommentar (Z.10-12, Z.49-51).
- ↓ Submodule: `tetra_mac_resource_bl_ack_builder #(.PDU_BITS(124)) u_bl_ack`
 und `tetra_sch_hd_encoder u_sch_hd`. Output geht in DL-Signal-Queue auf
 den BLCK/SDS-Producer-Port.

**Auffälligkeiten:**
- Header-Kommentar (Z.16-20) dokumentiert eine eigene History: ursprünglich
 X.5-initial triggerte das Modul auf Frag-1, was Step 2 (Slot-Grant) mit
 Step 4 (BL-ACK) konflatete. Aktueller Trigger ist Post-Frag-2. Keine
 Reste der alten Logik mehr im Code.
- Coded-Output ist LSB-aligned: `{216'd0, lat_coded_blk1}` (Z.209).
 Gegensatz zu `tetra_pre_reply_slotgrant.v` (MSB-aligned, Z.264). Wird
 vom Queue/Scheduler unterschiedlich behandelt (Kommentar Z.203-205
 verweist auf `tetra_dl_signal_queue.v` Zeile 17 und Scheduler Z.122).
- AACH-Pattern wird hier NICHT konfiguriert (das Modul exportiert
 keinen `aach_pattern`-Port). Kommentar Z.22-25 sagt "AACH on that slot
 is currently 0x0249 (reserved/capacity-allocation)... existing
 AACH-Schedule is unchanged by this module" — d.h. die AACH-Konfiguration
 passiert anderswo.
- `nr=1'b0` für BL-ACK hart verdrahtet — Kommentar "first BL-ACK"
 (Z.114). Keine Resend-Logik.

**Bekannte Bugs aus Kommentaren:** keine `BUG:`/`FIXME:`/`TODO:`-Marker.

---

### tetra_pre_reply_slotgrant.v (271 Zeilen)

**Ports:**

IN:
- `clk_sys`, `rst_n_sys`
- `frag1_pulse` (1-cyc Pulse aus MAC-ACCESS-Parser bei Frag-1-Detection)
- `ul_ssi[23:0]`, `mm_pdu_type[3:0]`
- `cfg_mcch_tn[1:0]`, `cfg_scramble_init[31:0]`

OUT:
- `wr_slotgrant_valid_sys` (reg, 1-cyc Push-Pulse)
- `wr_slotgrant_coded_sys[431:0]` (`{lat_coded_schhd, 216'd0}` — MSB-aligned)
- `wr_slotgrant_pdu_type_sys[1:0]` (= `PDUC_PRE_REPLY_SLOTGRANT_FMT` = SCH/HD)
- `wr_slotgrant_target_tn_sys[1:0]` (= `lat_target_tn`)
- `push_cnt_sys[15:0]`, `drop_cnt_sys[15:0]` (saturating)

**Funktion:**
Phase Z.9 Single-SCH/HD-Pfad. Trigger ist `frag1_pulse` (UL-MAC-ACCESS
Frag-1 detected). Wenn `mm_pdu_type ∈ {2, 7}` baut die FSM intern eine
124-bit AL-SETUP-MAC-RESOURCE-PDU (`slot_granting_flag=1`,
`slot_granting_element=0x00`, `addr_type=PDUC_PRE_REPLY_SLOTGRANT_ADDRTYPE`
= SSI, `llc_pdu_type=PDUC_PRE_REPLY_SLOTGRANT_LLC`, `random_access_flag=
PDUC_PRE_REPLY_SLOTGRANT_RA=1`), encodet via `tetra_sch_hd_encoder` auf
216 bits und pusht MSB-aligned in den DL-Signal-Queue MLE-Producer-Slot.
AACH-Pattern wird per Queue-Eintrag (`PDUC_PRE_REPLY_SLOTGRANT_AACH=0x0009`)
weitergegeben — Header-Kommentar Z.13-14. Bei `mm_pdu_type ∉ {2,7}`:
`drop_cnt_sys++`, IDLE bleibt.

**State-Diagramm:**
- `S_IDLE` → `S_BUILD` wenn `frag1_edge_w = frag1_pulse & ~frag1_pulse_q`
 UND `mm_accept_w = (mm_pdu_type==4'd2) | (mm_pdu_type==4'd7)`
 (latched `ul_ssi`, `cfg_mcch_tn`, `cfg_scramble_init`, `builder_start=1`)
- `S_IDLE` (stay) wenn `frag1_edge_w` und NICHT `mm_accept_w`: `drop_cnt_sys++`
- `S_BUILD` → `S_ENC` wenn `builder_valid_w` (`encode_start=1`).
 Bei `frag1_edge_w` während busy: `drop_cnt_sys++`.
- `S_ENC` → `S_PUSH` wenn `coded_valid_w` (latched 216-bit
 `coded_w → lat_coded_schhd`). Trigger-Drops zählen weiter.
- `S_PUSH` → `S_IDLE` (`wr_slotgrant_valid_sys=1` für 1 cyc, `push_cnt_sys++`)
- `default` → `S_IDLE`

**Pipeline-Latenz:**
Trigger (0) → `S_BUILD` (1) → builder fertig (variabel) → `S_ENC` (M) →
SCH/HD-Encoder fertig (variabel) → `S_PUSH` (N) → `req_valid` (N). Aus dem
Code allein nicht exakt herleitbar (Builder + Encoder extern).

**Nachbarn:**
- ↑ Trigger: `frag1_pulse` + `mm_pdu_type` aus dem UL MAC-ACCESS-Parser.
 Top-Wiring laut Kommentar nicht hier dokumentiert.
- ↓ Submodule: `tetra_mac_resource_dl_builder #(.PDU_BITS(124),
.LLC_BUF_BITS(16)) u_mac_res` (mit allen `second_pdu_*` und
 `chan_alloc_*` auf 0; `slot_granting_flag=1`,
 `slot_granting_element=8'h00`; `mle_pd_in=3'b001` "unused; AL-SETUP
 has no MM"). Encoder: `tetra_sch_hd_encoder u_sch_hd`. Output geht in
 den MLE-Producer-Port der DL-Signal-Queue ("muxed at top.v with
 MLE-FSM Final-ACCEPT and GroupAck", Z.63-64).

**Auffälligkeiten:**
- Header-Kommentar Z.16-29 dokumentiert eine ausführliche Phasen-History:
 - cad69e0 (pre-Z.3): mm=2 nutzte shared `dl_pdu_builder` mit SCH/F + sg=0x01
 - Z.3: Regression — ALLE mm-Typen auf SCH/HD mit sg=0x00 (brach mm=2)
 - Z.4: Dual-Path — mm=2 SCH/F, mm=7 SCH/HD (mit AACH-Drift #3 und
 sg_element-Drift #4)
 - Z.9 (aktuell): Collapse zu Single-SCH/HD für BEIDE mm-Typen,
 sg_element=0x00 universell, AACH=0x0009 via PDU-Class-Header
- Keine Reste der alten Dual-Path-Logik mehr im Modul — der zweite
 Pfad ist komplett entfernt.
- MSB-aligned Coded-Output `{lat_coded_schhd, 216'd0}` (Z.264) — bewusst,
 Kommentar Z.260-263 begründet mit Scheduler-Reading `head_coded[431:216]`.
 Gegensatz zu `tetra_pre_reply_blck.v` (LSB-aligned).
- Defensive Edge-Detection (`frag1_pulse_q`) ist laut Kommentar redundant
 ("upstream provides 1-cyc pulse already, but double-trigger protection
 costs nothing").
- `mle_pd_in=3'b001` ist verdrahtet aber laut Kommentar "unused; AL-SETUP
 has no MM" — toter Wert ins Submodul. Ob das Submodul ihn tatsächlich
 ignoriert, ist aus dieser Datei nicht ableitbar (unklar aus Code).
- Phase-Tag im Header: Z.3, Z.4, Z.8, Z.9. Kein dynamischer Schalter im
 Modul — nur die Single-Path-Variante ist aktiv.

**Bekannte Bugs aus Kommentaren:**
- Z.21-23 erwähnt die Z.3-Regression als historischen Bug: "Z.3
 (regression): ALL mm-types switched to SCH/HD with sg=0x00. Broke mm=2
 Frag-2 retrieval on the MTP3550." → angeblich gefixt durch Z.9-Collapse.
- Z.23-27 listet Drift #3 (AACH 0x0249 statt 0x0009 auf mm=2 SCH/F) und
 Drift #4 (sg_element=0x01 statt 0x00) als historische Drifts in Z.4 —
 laut Kommentar "expected to auto-resolve" durch den Single-Path-Refactor.

---

### tetra_dl_nwrk_broadcast.v (126 Zeilen)

**Ports:**

IN:
- `clk_sys`, `rst_n_sys`
- `payload_sys[431:0]` (komplettes SCH/F type-5 Coded — von SW über 14 AXI
 Shadow-Register vorberechnet, Header Z.6-8)
- `trigger_sys` (1-cyc SW-Pulse, Legacy-Pfad)
- `cfg_mcch_tn_sys[1:0]`
- `cfg_period_mf[4:0]` (Auto-Fire-Periode in Multiframes; 0 = SW-Trigger-Modus)
- `mf_pulse_sys` (1-cyc Multiframe-Edge-Pulse)

OUT:
- `wr_cmce_valid_sys` (reg, 1-cyc Push-Pulse in DL-Signal-Queue CMCE-Slot)
- `wr_cmce_coded_sys[431:0]` (= `payload_sys`, kombinatorisch durchgereicht)
- `wr_cmce_pdu_type_sys[1:0]` (= `PDUC_NWRK_BCAST_FMT` = SCH/F)
- `wr_cmce_target_tn_sys[1:0]` (= `cfg_mcch_tn_sys`)
- `push_cnt_sys[15:0]` (saturating)

**Funktion:**
Periodischer D-NWRK-BROADCAST-Push. SW (sw/tetra_hal-daemon) baut das
komplette 432-bit SCH/F type-5 Payload und legt es in 14 AXI-Shadow-Regs
(via `payload_sys` ans Modul angereicht). Zwei sich ausschliessende
Trigger-Quellen, gesteuert durch `cfg_period_mf`:
- `cfg_period_mf == 0` → SW-Trigger-Modus: jeder Rising-Edge auf
 `trigger_sys` löst einen Push aus.
- `cfg_period_mf != 0` → Auto-Fire: interner 5-bit `mf_count` zählt
 `mf_pulse_sys` Pulse; bei `(mf_count + 1) >= cfg_period_mf` wird gefired
 und `mf_count` reset. SW-Edge wird in diesem Modus komplett ignoriert.

**State-Diagramm:**
Keine explizite Multi-State-FSM — eine einzige `always`-Block, der pro Cycle
`fire_v` entscheidet:
- `sw_edge_v = (cfg_period_mf == 0) & (trigger_sys & ~trigger_sys_q)`
- `auto_fire_v = (cfg_period_mf != 0) & mf_pulse_sys &
 ((mf_count + 1) >= cfg_period_mf)`
- `fire_v = sw_edge_v | auto_fire_v`
- Wenn `fire_v` → `wr_cmce_valid_sys ← 1` (NBA, also 1 cyc später) UND
 `push_cnt_sys++` (saturiert bei `16'hFFFF`)
- `mf_count`-Update:
 - `cfg_period_mf == 0` → `mf_count ← 0` (Held in Reset)
 - `cfg_period_mf != 0` und `mf_pulse_sys`:
 - bei `(mf_count + 1) >= cfg_period_mf` → `mf_count ← 0`
 - sonst → `mf_count ← mf_count + 1`

**Pipeline-Latenz:**
Auto-Fire: `mf_pulse_sys` Zyklus (Detection) → `wr_cmce_valid_sys=1` ist
NBA, kommt also exakt im selben Cycle (Z.98 `wr_cmce_valid_sys <= fire_v`,
sampling im selben posedge). Effektiv 1 Zyklus zwischen `mf_pulse` und
Queue-Push. SW-Pfad: `trigger_sys` Rising-Edge (mit `trigger_sys_q`
1-cyc Verzögerung) → ebenfalls 1 Zyklus.

**Nachbarn:**
- ↑ Trigger: entweder SW (`trigger_sys` via AXI W1S-Reg, HW-clr nach
 Consume — Header Z.65-67), oder interner Multiframe-Zähler auf
 `mf_pulse_sys` (CDC'd ins clk_sys-Domain). `payload_sys` und
 `cfg_mcch_tn_sys` ebenfalls CDC'd aus AXI.
- ↓ Submodule: KEINE. Reiner Pass-through + Trigger-Logik. Output geht
 in DL-Signal-Queue CMCE-Producer-Slot.

**Auffälligkeiten:**
- Inline-Block-Variablen (`sw_edge_v`, `auto_fire_v`, `fire_v`) deklariert
 als `reg` im Always-Block (`begin: sw_af_block` Z.81). Header
 Z.72-76 begründet das mit einem dokumentierten iverilog-Sim-Race auf
 continuous-assign-Wires bei `posedge`.
- Modus-Wechsel sind exklusiv: bei `cfg_period_mf != 0` wird `trigger_sys`
 ignoriert (im `sw_edge_v`-Term mit `cfg_period_mf == 0` geandet). Kein
 Double-Fire-Risiko aus dieser Datei ableitbar.
- `mf_count` ist 5-bit (max 31) — `cfg_period_mf` ist auch 5-bit. Bei
 `cfg_period_mf > 31` wäre der Vergleich `(mf_count + 1) >= cfg_period_mf`
 nicht erfüllbar. Aus dem Code ist nicht klar, ob SW jemals so eingestellt
 wird (unklar aus Code).
- Header-Kommentar Z.4 nennt das Modul "Phase H.7 — D-NWRK-BROADCAST
 Periodic Push". MEMORY-Eintrag verweist auf `REG_NWRK_BCAST_PERIOD_MF=10`
 als Default — dieser Default lebt aber NICHT in dieser Datei.
- Trigger-Vorzug bei gleichzeitig `cfg_period_mf == 0` und `cfg_period_mf
 != 0` ist nicht definiert (geht nicht — Werte exklusiv).
- Keine Drop-Counter — wenn zwei Trigger im selben Cycle ankommen würden,
 würden sie zu einem einzigen `fire_v=1`-Pulse kollabieren.
- `wr_cmce_valid_sys` ist OUT-Reg mit NBA → erste Cycle nach Reset ist
 garantiert 0.

**Bekannte Bugs aus Kommentaren:** keine `BUG:`/`FIXME:`/`TODO:`-Marker.
Header dokumentiert eine vergangene Sim-Race-Falle (Z.72-76) als gelöst
durch inline-Reg-Variablen.

---

> **⟳ Review-Delta 2026-06-20:** MM-/Registration-Logik ist **SW-abgelöst**: `mle_registration_fsm.v` + `ul_demand_ie_parser.v` sind noch instanziiert, aber ihr Output ist **A/B-Legacy** — der funktionale Pfad läuft in SW (`tetra_mm_demand_parser.c` + `tetra_attach_daemon.c` `react_mm2/mm7`). `pre_reply_blck`/`pre_reply_slotgrant` + `dl_nwrk_broadcast` bleiben live. Die **neue** Signalling-Logik (CMCE-Call, SDS, Gruppenwechsel, **Late Entry**) ist KOMPLETT SW (`tetra_call_fsm.c`), KEIN RTL-FSM. `d_location_update_reject_encoder.v` = Orphan (SW macht Reject).

## Querverbindungen / Drift-Spuren

- **Coded-Bus-Alignment:** Die drei Mini-FSMs schreiben unterschiedliche
 Alignments in den 432-bit Queue-Bus:
 - `tetra_pre_reply_slotgrant.v` (SCH/HD): MSB-aligned
 `{lat_coded_schhd, 216'd0}`
 - `tetra_pre_reply_blck.v` (SCH/HD): LSB-aligned
 `{216'd0, lat_coded_blk1}`
 - `tetra_dl_nwrk_broadcast.v` (SCH/F): full 432-bit, direkter Pass-through
 - `tetra_mle_registration_fsm.v` (SCH/F): vom externen Builder geliefert,
 `accept_build_coded` direkt in `req_coded_bits`
- **AACH-Pattern-Source:** `mle_registration_fsm` exportiert
 `accept_build_aach_pattern` (per cmce_path-Mux). Die drei anderen FSMs
 liefern KEIN AACH-Pattern und überlassen das der Queue / dem Scheduler
 über PDU-Class-Header.
- **Phase-Tags im Code (aktiv referenziert):** X.2, X.4, X.5, X.6, X.7,
 Y.2, Z.3, Z.4, Z.8, Z.9, 7 G.4, 7 G.7, H.7. Keine auskommentierten
 Code-Blöcke sichtbar — alle Phasen-Refactors haben den alten Pfad
 hard-entfernt.
- **`unused_ports` als OR-Senke:** Nur in `tetra_mle_registration_fsm.v`
 (Z.188-196, `synthesis translate_off`). Die anderen drei Module haben
 keine vergleichbare Senke.
- **`tetra_sch_hd_encoder` Doppel-Instanziierung** (2026-05-17 Util-Audit):
 zwei vollwertige FSM-Kopien in `tetra_pre_reply_slotgrant.v:160` und
 `tetra_pre_reply_blck.v:128` (zusammen ~2400 LUT). Encoder ist sequenziell
 (~486 Cycles/Encode bei 100 MHz = 5 µs); inter-slot-Distance ist
 ~14 ms, also könnte EINE zentrale Instanz beide Reply-Pfade locker
 serialisieren. Konsolidierung wäre ~1000 LUT save — vorgemerkt als
 nächste Util-Optimierung neben `u_slot_content_mux` Pipelining.
