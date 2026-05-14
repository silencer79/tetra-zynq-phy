# TX-Datenfluss Post-Pop (queue.head → on-air IQ)

Stand: HEAD `5b2f39c`. Quelle: jede Zeile aus dem Verilog-Code grep't (Datei:Zeile referenziert).

## ASCII-Pfaddiagramm

```
 ┌──────────────────────────────────────────────────┐
 │ tetra_dl_signal_queue.v (clk_sys) │
 │ │
 │ entry_valid[0..3] ──priority-arb──▶ head_idx │
 │ (255-302) (254-273)│
 │ │ │ │
 │ │ pop && head_valid → clear @ T+1 │ │
 │ │ (302) │ │
 │ ▼ ▼ │
 │ entry_coded[head_idx] ──assign──▶ head_coded[431:0]
 │ entry_target_tn[head_idx] ──assign▶ head_target_tn[1:0]
 │ entry_pdu_type[head_idx] ──assign▶ head_pdu_type[1:0]
 │ entry_aach_pattern[hi] ──assign▶ head_aach_pattern[13:0]
 │ head_found ──assign──▶ head_valid
 │ (alle combinational, Zeilen 274-281) │
 └────────┬─────────────────────────────────────────┘
 │
 │ wires (combinational)
 ▼
 ┌──────────────────────────────────────────────────┐
 │ tetra_dl_signal_scheduler.v (combinational) │
 │ │
 │ Inputs: head_valid_sys, head_coded_sys, │
 │ head_target_tn_sys, head_pdu_type_sys │
 │ Plus: tn_sys, slot_pulse_sys │
 │ │
 │ pop_trigger = slot_pulse_sys │
 │ & head_valid_sys │
 │ & (head_target_tn_sys==tn_sys) │
 │ (143-146) ─────▶ pop_sys ─────▶ queue.pop │
 │ │
 │ tgt_tn0 = head_valid_sys │
 │ & (head_target_tn_sys==2'd0) (160) │
 │ b_is_f = (head_pdu_type_sys==2'd0) (157) │
 │ b_is_hd = (head_pdu_type_sys==2'd1) (158) │
 │ │
 │ sched_blk1_tn0_sys = tgt_tn0 ? │
 │ head_coded_sys[431:216]: null_pdu (165) │
 │ sched_blk2_tn0_sys = (tgt_tn0 && b_is_f) ? │
 │ head_coded_sys[215:0]: sig_companion(166) │
 │ ndb2_tn0 = tgt_tn0 ? b_is_hd: 1'b1 (175) │
 │ sched_active_sys[0] = tgt_tn0 (185) │
 └────────┬─────────────────────────────────────────┘
 │
 │ wires (combinational)
 ▼
 ┌──────────────────────────────────────────────────┐
 │ tetra_slot_content_mux.v (clk_sys) │
 │ │
 │ sched_entry_reg_sys0..3 ── BRAM-Schedule │
 │ (286, 293, 300, 307) (FSM S_RD0..S_CAP3)│
 │ 6-cycle prefetch │
 │ @ slot_pulse@tn=3 │
 │ │
 │ sig_route_tn0_w = bus_is_signal(entry_reg_sys0) │
 │ | sched_active_sys[0] (329)│
 │ │
 │ blk1_mux_tn0_sys = sig_route_tn0_w │
 │ ? sched_blk1_tn0_sys │
 │: <SW-bank by class> (346/350-356)│
 │ │
 │ ndb2_tn0_w = sig_route_tn0_w │
 │ ? sched_ndb2_sys[0]: bus_is_ndb2() (420) │
 │ │
 │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
 │ FREE-RUNNING posedge clk_sys (jeder Takt) │
 │ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
 │ tx_blk1_slot0_sys <= blk1_mux_tn0_sys (461) │
 │ tx_blk2_slot0_sys <= blk2_mux_tn0_sys (477) │
 │ slot_burst_type_sys[0] <= bus_is_sdb(...) (439) │
 │ slot_en_sys[0] <= bus_is_enable(...) (449) │
 │ slot_ndb2_sys[0] <= ndb2_tn0_w (456) │
 └────────┬─────────────────────────────────────────┘
 │
 │ block1_in_sys = {tx_blk1_slot3..0_sys}
 │ block2_in_sys = {tx_blk2_slot3..0_sys}
 ▼
 ┌──────────────────────────────────────────────────┐
 │ tetra_burst_mux.v (clk_sys) │
 │ │
 │ FSM: S_IDLE ── tx_slot_pulse_sys ──▶ S_PENDING│
 │ (118-126) S_PENDING ──▶ S_REQ │
 │ S_REQ ──▶ S_IDLE │
 │ │
 │ ── @ posedge bei state==IDLE && slot_pulse: ── │
 │ slot_lat_sys <= tx_slot_num_sys (141)│
 │ slot_en_lat_sys <= slot_en_sys[tx_slot_num](149)│
 │ burst_type_lat_sys <= slot_burst_type_sys[](157)│
 │ ndb2_lat_sys <= slot_ndb2_sys[tx_slot_num] (165)│
 │ │
 │ sel_block1_w (combinational): │
 │ case(slot_lat_sys) → │
 │ block1_in_sys[slot*216 +: 216] (174) │
 │ │
 │ ── @ posedge bei (next==REQ && state==PENDING):│
 │ build_block1_sys <= slot_en_lat_sys │
 │ ? sel_block1_w: 0 (206) │
 │ build_block2_sys <= slot_en_lat_sys │
 │ ? sel_block2_w: 0 (219) │
 │ build_burst_type_sys <= burst_type_lat_sys (250)│
 │ build_ndb2_sys <= ndb2_lat_sys (260)│
 │ build_req_sys <= (next_state==S_REQ) (270)│
 └────────┬─────────────────────────────────────────┘
 │
 │ build_req_sys (1-cycle pulse)
 │ build_block1/2/burst_type/ndb2/bb_sys
 ▼
 ┌──────────────────────────────────────────────────┐
 │ tetra_burst_builder.v (clk_sys) │
 │ │
 │ ndb_burst_w = {TAIL1, PADJ, │
 │ block1_data_sys[216], ← build_block1 │
 │ bb_data_sys[14], nts_sel[22], │
 │ bb_data_sys[16], │
 │ block2_data_sys[216], ← build_block2 │
 │ PADJ, TAIL2} (195-199, 510b)│
 │ │
 │ burst_sreg_sys [509:0] LATCH: │
 │ @ build_req_sys && state==IDLE: cold start │
 │ @ sym_cnt==254 && chain_pending: chain reload │
 │ @ sym_en_w && state==SHIFT: shift left 2 bits │
 │ (208-216) │
 │ │
 │ tx_dibit_sys[1:0] <= burst_sreg_sys[509:508] │
 │ @ sym_en_w (18 kHz) (278) │
 └────────┬─────────────────────────────────────────┘
 │
 │ tx_dibit_sys + tx_dibit_valid_sys
 ▼
 ┌──────────────────────────────────────────────────┐
 │ tetra_tx_chain → AD9361 DAC (clk_lvds 18.432 MHz)│
 │ π/4-DQPSK + RRC + CIC + IQ on-air │
 └──────────────────────────────────────────────────┘
```

## Schlüssel-Timing (Cycle-genau, ein Slot)

```
Cycle T_slot (slot_pulse_sys=1, tn_sys = target_tn)

 scheduler @ T_slot pre-edge:
 pop_trigger = 1 (combinational)
 sched_blk1_tn0_sys = body (combinational from head)
 blk1_mux_tn0_sys = body (combinational from sched_blk1)

 POSEDGE T_slot:
 queue.entry_valid[head_idx] <= 0 (next-cycle visible)
 slot_content_mux.tx_blk1_slot0_sys <= blk1_mux_tn0_sys (= body, pre-edge)
 burst_mux.state_sys: IDLE → PENDING (next-cycle)
 burst_mux.slot_lat_sys <= 0 (== tn_sys)

Cycle T_slot+1 (state_sys = PENDING)

 combinational pre-edge T_slot+1:
 blk1_mux_tn0_sys reads NEW entry_valid (= 0) → null_pdu
 sel_block1_w = block1_in_sys[0] = tx_blk1_slot0_sys (post-T_slot)
 = body (latched)
 next_state_sys = REQ

 POSEDGE T_slot+1:
 tx_blk1_slot0_sys <= blk1_mux_tn0_sys (pre-edge = null_pdu) → null
 build_block1_sys <= sel_block1_w (pre-edge = body) → BODY ✓
 state_sys → REQ
 build_req_sys <= 1

Cycle T_slot+2 (state_sys = REQ)
 burst_builder reads build_block1_sys = body → loads burst_sreg
 burst_builder shifts dibits → IQ on-air for ~250 cycles
```

## Signal-Tabelle (kompakt)

| # | Signal | File:Line | Modul | Typ | Trigger |
|---|--------|-----------|-------|-----|---------|
| 1 | `pop_sys` | tetra_dl_signal_scheduler.v:147 | scheduler | wire | comb. `slot_pulse & head_valid & (tn==head_target)` |
| 2 | `entry_valid[head_idx]` | tetra_dl_signal_queue.v:302 | queue | reg bit | posedge clk wenn pop&head_valid → clear NEXT cycle |
| 3 | `head_idx` | tetra_dl_signal_queue.v:254-273 | queue | wire [2:0] | comb. priority scan über entry_valid |
| 4 | `head_valid` | tetra_dl_signal_queue.v:275 | queue | wire | comb. = head_found |
| 5 | `head_coded` | tetra_dl_signal_queue.v:276 | queue | wire [431:0] | comb. = entry_coded[head_idx] |
| 6 | `head_target_tn` | tetra_dl_signal_queue.v:278 | queue | wire [1:0] | comb. = entry_target_tn[head_idx] |
| 7 | `head_pdu_type` | tetra_dl_signal_queue.v:277 | queue | wire [1:0] | comb. |
| 8 | `head_aach_pattern` | tetra_dl_signal_queue.v:280 | queue | wire [13:0] | comb. |
| 9 | `tgt_tn0` | tetra_dl_signal_scheduler.v:160 | scheduler | wire | comb. `head_valid & (head_target==0)` |
| 10 | `b_is_f` / `b_is_hd` | tetra_dl_signal_scheduler.v:157,158 | scheduler | wire | comb. (head_pdu_type) |
| 11 | `sched_blk1_tn0_sys` | tetra_dl_signal_scheduler.v:165 | scheduler | wire [215:0] | comb. mux body vs null_pdu |
| 12 | `sched_blk2_tn0_sys` | tetra_dl_signal_scheduler.v:166 | scheduler | wire [215:0] | comb. mux body vs sig_companion |
| 13 | `sched_ndb2_sys[0]` | tetra_dl_signal_scheduler.v:179 | scheduler | wire | comb. concat |
| 14 | `sched_active_sys[0]` | tetra_dl_signal_scheduler.v:185 | scheduler | wire | comb. = tgt_tn0 |
| 15 | `pop_cnt_sys` | tetra_dl_signal_scheduler.v:194 | scheduler | reg [15:0] | posedge wenn pop_trigger |
| 16 | `sched_entry_reg_sys0..3` | tetra_slot_content_mux.v:286,293,300,307 | content_mux | reg [15:0] | posedge im FSM-State S_RD0..S_RD3 (Refresh @ slot_pulse@tn=3) |
| 17 | `sig_route_tn0_w` | tetra_slot_content_mux.v:329 | content_mux | wire | comb. `bus_is_signal(entry_reg) \| sched_active[0]` |
| 18 | `blk1_mux_tn0_sys` | tetra_slot_content_mux.v:346 | content_mux | reg [215:0] (comb @*) | sig_route ? sched_blk1: <SW-bank> |
| 19 | `blk2_mux_tn0_sys` | tetra_slot_content_mux.v:347 | content_mux | reg [215:0] (comb @*) | sig_route ? sched_blk2: <SW-bank> |
| 20 | `ndb2_tn0_w` | tetra_slot_content_mux.v:420-421 | content_mux | wire | comb. |
| 21 | **`tx_blk1_slot0_sys`** | tetra_slot_content_mux.v:461 | content_mux | reg [215:0] | **posedge clk_sys (FREE-RUNNING jeder Takt)** |
| 22 | **`tx_blk2_slot0_sys`** | tetra_slot_content_mux.v:477 | content_mux | reg [215:0] | **posedge clk_sys (FREE-RUNNING jeder Takt)** |
| 23 | `slot_burst_type_sys[0]` | tetra_slot_content_mux.v:439 | content_mux | reg | posedge clk_sys (free-running) |
| 24 | `slot_en_sys[0]` | tetra_slot_content_mux.v:449 | content_mux | reg | posedge clk_sys (free-running) |
| 25 | `slot_ndb2_sys[0]` | tetra_slot_content_mux.v:456 | content_mux | reg | posedge clk_sys (free-running) |
| 26 | `state_sys` (FSM) | tetra_burst_mux.v:129-134 | burst_mux | reg [1:0] | posedge clk → next_state_sys |
| 27 | `slot_lat_sys` | tetra_burst_mux.v:141 | burst_mux | reg [1:0] | posedge wenn `state==IDLE & slot_pulse=1` |
| 28 | `slot_en_lat_sys` | tetra_burst_mux.v:149 | burst_mux | reg | dito |
| 29 | `burst_type_lat_sys` | tetra_burst_mux.v:157 | burst_mux | reg | dito |
| 30 | `ndb2_lat_sys` | tetra_burst_mux.v:165 | burst_mux | reg | dito |
| 31 | `sel_block1_w` | tetra_burst_mux.v:174 | burst_mux | reg [215:0] (comb @*) | mux block1_in_sys[slot_lat] |
| 32 | **`build_block1_sys`** | tetra_burst_mux.v:206 | burst_mux | reg [215:0] | **posedge wenn `next_state==REQ & state==PENDING`** |
| 33 | **`build_block2_sys`** | tetra_burst_mux.v:217/219 | burst_mux | reg [215:0] | **dito** |
| 34 | `build_req_sys` | tetra_burst_mux.v:270 | burst_mux | reg | posedge wenn next_state==REQ |
| 35 | `burst_sreg_sys` | tetra_burst_builder.v:208-216 | burst_builder | reg [509:0] | cold-start @ build_req \| chain reload \| shift |
| 36 | `tx_dibit_sys` | tetra_burst_builder.v:278 | burst_builder | reg [1:0] | posedge clk wenn sym_en_w (~18 kHz) |

## Verbindungen (zynq_top.v)

```
queue.head_* → scheduler.head_*_sys (combinational fan-in)
scheduler.pop_sys → queue.pop (combinational)
scheduler.sched_blk*_tn*_sys → slot_content_mux.sched_blk*_tn*_sys (comb)
scheduler.sched_active_sys → slot_content_mux.sched_active_sys
scheduler.sched_ndb2_sys → slot_content_mux.sched_ndb2_sys
slot_content_mux.tx_blk*_slot*_sys → burst_mux.block*_in_sys (registered)
slot_content_mux.slot_*_sys → burst_mux.slot_*_sys (alle registered)
burst_mux.build_*_sys → burst_builder.* (registered)
burst_builder.tx_dibit_sys → tx_chain (clk_lvds via CDC)
```
