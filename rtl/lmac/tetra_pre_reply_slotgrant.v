// =============================================================================
// tetra_pre_reply_slotgrant.v
//
// Phase Z.9 — Pre-Reply Slot-Grant Mini-FSM, SINGLE PATH (SCH/HD).
//
// Trigger: `frag1_pulse` (1-cycle pulse from MAC-ACCESS parser on Frag-1
// detection). Both ITSI-Attach (mm=2) AND Group-Switch (mm=7) build an
// identical 124-bit AL-SETUP MAC-RESOURCE PDU (slot_granting_flag=1,
// slot_granting_element=0x00) and SCH/HD-encode it to 216 bits. The 216
// bits are MSB-aligned in the 432-bit queue bus
// (`{coded_schhd, 216'd0}`); the scheduler picks BKN1 from
// `head_coded[431:216]` and routes BKN2 to the SYSINFO companion.
// AACH on the carrier slot is `PDUC_PRE_REPLY_SLOTGRANT_AACH=0x0009`
// (signalling-active) via the queue's per-entry AACH-pattern field.
//
// History:
// - cad69e0 (pre-Z.3): mm=2 SCH/F via shared dl_pdu_builder (sg=0x01).
// - Z.3 (regression): ALL mm-types switched to SCH/HD with sg=0x00.
// Broke mm=2 Frag-2 retrieval on the MTP3550.
// - Z.4: Dual-path — mm=2 kept on SCH/F, mm=7 on SCH/HD.
// AACH override on mm=2 SCH/F path was 0x0249 on-air
// (Drift #3) and sg_element=0x01 vs 0x00 (Drift #4).
// - Z.9: Collapse to single SCH/HD pipeline for both mm-types.
// sg_element=0x00 universally. AACH 0x0009 via PDU-class header →
// queue → scheduler. BKN2 = sig_companion_sys via existing scheduler
// scheme (head_is_f=0 routes to SYSINFO; Drift #2 OK).
// - 2026-06-10: sg_element made mm-dependent (single SCH/HD path kept).
// mm=2 (Attach) = 0x00 (Z.9 value — registration needs it; 0x30 breaks
// the attach, observed air: MS sees BS but cannot register). mm=7
// (Group / CMCE-mis-tagged long SDS) = 0x30 (cap_alloc=3 = grant 3
// slots), decoded from the 392-MHz reference DL so the long-SDS sender
// gets the SCH/F slots for its MAC-FRAG continuation.
//
// Filter:
// `mm_pdu_type` is still consumed as a defensive filter — only mm ∈ {2,7}
// triggers a push. The MAC-Resource builder constants are identical for
// both branches, but the `mm_pdu_type` check guarantees we don't push for
// unrelated UL random-access PDUs (e.g. mm=4 Detach already handled
// elsewhere; arbitrary unknown mm-types must not generate signalling).
//
// Coding rules (Verilog-2001 strict):
// R1 one always block per FSM
// R4 async active-low reset
// R10 @(*) for combinational
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tetra_pre_reply_slotgrant (
 input wire clk_sys,
 input wire rst_n_sys,

 // Frag-1 trigger from MAC-ACCESS parser (1-cycle pulse on clk_sys)
 input wire frag1_pulse,
 input wire [23:0] ul_ssi,
 // Phase Z.9 — mm-type filter. Only mm ∈ {2,7} produces a push;
 // other mm-types count as drop and stay IDLE.
 input wire [3:0] mm_pdu_type,

 // SW-Trigger (Empfänger-Slot-Grant nach langer-SDS-Zustellung): 1-Zyklus-Puls
 // + Empfänger-SSI (CDC-resynced aus AXI). Wirkt wie mm=2: sg_element=0x00
 // (1 Subslot, FirstSubslotGranted), kein AACH-Hold. Adresse = sw_grant_ssi.
 // Damit baut dieselbe FSM den Gold-#822-konformen NDB2/SCH/HD-Grant an MS-B.
 input wire sw_grant_pulse,
 input wire [23:0] sw_grant_ssi,

 // MCCH slot (CDC-resynced from AXI), pre-reply target TN
 input wire [1:0] cfg_mcch_tn,
 input wire [31:0] cfg_scramble_init,

 // Shared SCH/HD encoder interface (2026-05-17 Util-Refactor).
 //   ext_enc_req     hochzieren wenn info_bits + scramble_init ready
 //                   und encoder soll starten; halten bis ext_enc_done.
 //   ext_info_bits   124-bit PDU für encoder
 //   ext_scramble_init 32-bit DL scrambler seed
 //   ext_enc_done    1-cycle Puls vom Arbiter wenn encoder fertig
 //   ext_enc_coded   216-bit coded payload (valid alongside ext_enc_done)
 output wire ext_enc_req,
 output wire [123:0] ext_info_bits,
 output wire [31:0] ext_scramble_init,
 input wire ext_enc_done,
 input wire [215:0] ext_enc_coded,

 // DL-Signal-Queue producer (MLE slot — muxed at top.v with MLE-FSM
 // Final-ACCEPT and GroupAck). Phase Z.9: 432-bit bus carries the
 // 216-bit SCH/HD payload MSB-aligned; pdu_type fixed at SCH_HD.
 output reg wr_slotgrant_valid_sys,
 output wire [431:0] wr_slotgrant_coded_sys,
 output wire [1:0] wr_slotgrant_pdu_type_sys,
 output wire [1:0] wr_slotgrant_target_tn_sys,

 // Stats — saturating 16-bit counters
 output reg [15:0] push_cnt_sys,
 output reg [15:0] drop_cnt_sys,

 // 2026-06-10 — UL-Slot-Reservierung: 1-Cycle-Puls beim Push eines
 // cap_alloc>0-Grants (mm=7/0x30), zusammen mit der Frame-Anzahl
 // (= capacity_allocation = sg_element[7:4]). Der AACH-Encoder hält damit
 // die TN=0-Idle-AACH N Frames auf 0x0000 (Gold-Referenz: f1=0 f2=0), statt
 // sofort wieder 0x0249 (Random) zu öffnen — sonst bricht die UL-MAC-FRAG-
 // Kette nach 1 Fragment ab. mm=2 (Attach, sg_element=0x00) → kein Hold.
 output reg resv_pulse_sys,
 output reg [3:0] resv_frames_sys
);

 // -------------------------------------------------------------------------
 // Edge-detect on frag1_pulse (defensive — upstream provides 1-cyc pulse
 // already, but double-trigger protection costs nothing).
 // -------------------------------------------------------------------------
 reg frag1_pulse_q;
 wire frag1_edge_w = frag1_pulse & ~frag1_pulse_q;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) frag1_pulse_q <= 1'b0;
 else frag1_pulse_q <= frag1_pulse;
 end

 // SW-Trigger-Edge (Empfänger-Slot-Grant). Eigene Edge-Detection, damit ein
 // länger anstehender CDC-Puls nur einen Grant erzeugt.
 reg sw_grant_pulse_q;
 wire sw_grant_edge_w = sw_grant_pulse & ~sw_grant_pulse_q;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) sw_grant_pulse_q <= 1'b0;
 else sw_grant_pulse_q <= sw_grant_pulse;
 end

 // -------------------------------------------------------------------------
 // mm-type filter — accept only mm=2 (ITSI-Attach) or mm=7 (Group-Switch).
 // The body content is identical; the filter just guards against unrelated
 // UL random-access events generating spurious Pre-Replies.
 // -------------------------------------------------------------------------
 wire mm_accept_w = (mm_pdu_type == 4'd2) | (mm_pdu_type == 4'd7);

 // -------------------------------------------------------------------------
 // Latches (single SCH/HD path)
 // -------------------------------------------------------------------------
 reg [23:0] lat_ssi;
 reg [1:0] lat_target_tn;
 reg [31:0] lat_scramble_init;
 // mm-abhängiges slot_granting_element, am Trigger gelatcht (wie lat_ssi):
 //   mm=2 (ITSI-Attach / Einbuchung)  → 0x00 (FirstSubslotGranted — Attach-Frag-2,
 //                                      bewährt; 0x30 bricht die Einbuchung)
 //   mm=7 (Group-Switch / lange SDS)  → 0x30 (cap_alloc=3, ref-dekodiert, gibt dem
 //                                      MS die 3 SCH/F-Slots für die Fragment-Kette)
 reg [7:0] lat_sg_element;
 // SCH/HD coded-payload latch (216 bit).
 reg [215:0] lat_coded_schhd;

 // -------------------------------------------------------------------------
 // Internal MAC-RESOURCE 124-bit builder + SCH/HD encoder.
 // AL-SETUP, slot_granting_flag=1, sg_element = lat_sg_element (mm-dependent):
 //   mm=2 (ITSI-Attach) → 0x00 (FirstSubslotGranted) — the registration
 //     Frag-2 path; 0x30 here BREAKS the attach (MS can't complete).
 //   mm=7 (Group-Switch / long SDS, CMCE-mis-tagged mm=7) → 0x30 =
 //     capacity_allocation 3 ("grant 3 slots", ETSI §21.5.6 [7:4]) +
 //     granting_delay 0 [3:0]. Decoded from the 392-MHz reference DL
 //     (DL_…17-30-04): the BS grants the long-SDS sender 0x30, and the MS
 //     then sends its 3× SCH/F MAC-FRAG continuation that the FPGA
 //     reassembly path consumes. 0x00 (one subslot) starved the chain.
 // -------------------------------------------------------------------------
 reg builder_start;
 wire [123:0] builder_pdu_w;
 wire builder_valid_w;

 tetra_mac_resource_dl_builder #(
.PDU_BITS(124),
.LLC_BUF_BITS(16)
 ) u_mac_res (
.clk (clk_sys),
.rst_n (rst_n_sys),
.start (builder_start),
.ssi (lat_ssi),
.addr_type (`PDUC_PRE_REPLY_SLOTGRANT_ADDRTYPE),
.usage_marker (6'd0), /* SlotGrant uses SSI addr_type=1 */
.ns (1'b0),
.nr (1'b0),
.llc_pdu_type (`PDUC_PRE_REPLY_SLOTGRANT_LLC),
.random_access_flag (`PDUC_PRE_REPLY_SLOTGRANT_RA),
.power_control_flag (1'b0),
.power_control_element (4'd0),
.slot_granting_flag (1'b1),
.slot_granting_element (lat_sg_element), // mm=2→0x00 (Attach), mm=7→0x30 (SDS, cap_alloc=3)
.chan_alloc_flag (1'b0),
.chan_alloc_element (32'd0),
.chan_alloc_element_len (5'd0),
.second_pdu_valid (1'b0),
.second_pdu_length_ind (6'd0),
.second_pdu_random_access_flag(1'b0),
.second_pdu_addr_type (3'd0),
.second_pdu_ssi (24'd0),
.second_pdu_tl_sdu (80'd0),
.second_pdu_tl_sdu_len (7'd0),
.second_pdu_pc_flag (1'b0),
.second_pdu_pc_element (4'd0),
.second_pdu_sg_flag (1'b0),
.second_pdu_sg_element (8'd0),
.second_pdu_ca_flag (1'b0),
.second_pdu_ca_element (32'd0),
.second_pdu_ca_element_len (5'd0),
.mm_pdu_bits (128'd0),
.mm_pdu_len_bits (8'd0),
.mle_pd_in (3'b001), /* unused; AL-SETUP has no MM */
.pdu_bits (builder_pdu_w),
.valid (builder_valid_w)
 );

 // -------------------------------------------------------------------------
 // FSM — single SCH/HD path via shared encoder (2026-05-17 refactor).
 //
 // S_IDLE — wait for frag1_edge_w with mm ∈ {2,7}. Latch trigger
 // inputs and kick the local MAC-Resource builder.
 // S_BUILD — wait for builder_valid_w; then assert ext_enc_req.
 // S_ENC — keep ext_enc_req=1; wait for ext_enc_done from arbiter;
 // latch 216-bit ext_enc_coded.
 // S_PUSH — pulse wr_slotgrant_valid_sys for 1 cycle.
 // -------------------------------------------------------------------------
 localparam [1:0] S_IDLE = 2'd0;
 localparam [1:0] S_BUILD = 2'd1;
 localparam [1:0] S_ENC = 2'd2;
 localparam [1:0] S_PUSH = 2'd3;

 reg [1:0] state;
 reg enc_req_r;

 always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 state <= S_IDLE;
 lat_ssi <= 24'd0;
 lat_target_tn <= 2'd0;
 lat_scramble_init <= 32'd0;
 lat_sg_element <= 8'h00;
 lat_coded_schhd <= 216'd0;
 builder_start <= 1'b0;
 enc_req_r <= 1'b0;
 wr_slotgrant_valid_sys <= 1'b0;
 push_cnt_sys <= 16'd0;
 drop_cnt_sys <= 16'd0;
 resv_pulse_sys <= 1'b0;
 resv_frames_sys <= 4'd0;
 end else begin
 // Default 1-cycle strobes
 builder_start <= 1'b0;
 resv_pulse_sys <= 1'b0;
 wr_slotgrant_valid_sys <= 1'b0;

 case (state)
 S_IDLE: begin
 if (sw_grant_edge_w) begin
 // SW-getriggerter Empfänger-Slot-Grant (lange-SDS-Zustellung).
 // Wie mm=2: sg_element=0x00 (1 Subslot), kein AACH-Hold.
 // Adresse = sw_grant_ssi (Empfänger), bypasst den mm-Filter.
 lat_ssi <= sw_grant_ssi;
 lat_target_tn <= cfg_mcch_tn;
 lat_scramble_init <= cfg_scramble_init;
 lat_sg_element <= 8'h00;
 builder_start <= 1'b1;
 state <= S_BUILD;
 end else if (frag1_edge_w) begin
 if (mm_accept_w) begin
 // Latch trigger inputs and kick local SCH/HD pipeline
 // (no arbitration; pipeline is exclusive to this FSM).
 lat_ssi <= ul_ssi;
 lat_target_tn <= cfg_mcch_tn;
 lat_scramble_init <= cfg_scramble_init;
 // mm=2 (Einbuchung) → 0x00; mm=7 (SDS/Group) → 0x30
 lat_sg_element <= (mm_pdu_type == 4'd2) ? 8'h00 : 8'h30;
 builder_start <= 1'b1;
 state <= S_BUILD;
 end else begin
 // Defensive default — unknown mm-type. Count drop
 // and stay IDLE.
 if (drop_cnt_sys != 16'hFFFF)
 drop_cnt_sys <= drop_cnt_sys + 16'd1;
 end
 end
 end

 S_BUILD: begin
 if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
 drop_cnt_sys <= drop_cnt_sys + 16'd1;
 if (builder_valid_w) begin
 enc_req_r <= 1'b1;
 state <= S_ENC;
 end
 end

 S_ENC: begin
 if (frag1_edge_w && drop_cnt_sys != 16'hFFFF)
 drop_cnt_sys <= drop_cnt_sys + 16'd1;
 if (ext_enc_done) begin
 lat_coded_schhd <= ext_enc_coded;
 enc_req_r <= 1'b0;
 state <= S_PUSH;
 end
 end

 S_PUSH: begin
 wr_slotgrant_valid_sys <= 1'b1;
 if (push_cnt_sys != 16'hFFFF)
 push_cnt_sys <= push_cnt_sys + 16'd1;
 // UL-Slot-Reservierung: nur wenn cap_alloc>0 (sg_element[7:4],
 // mm=7→0x30→3). Der AACH-Encoder hält N Idle-Frames auf 0x0000.
 if (lat_sg_element[7:4] != 4'd0) begin
 resv_pulse_sys <= 1'b1;
 resv_frames_sys <= lat_sg_element[7:4];
 end
 state <= S_IDLE;
 end

 default: state <= S_IDLE;
 endcase
 end
 end

 // Shared-encoder Request-Outputs (combinational; info_bits passes through
 // from the builder while it stays asserted, scramble_init is latched).
 assign ext_enc_req = enc_req_r;
 assign ext_info_bits = builder_pdu_w;
 assign ext_scramble_init = lat_scramble_init;

 // -------------------------------------------------------------------------
 // Combinational outputs to DL-Signal-Queue
 // coded[431:0] = {lat_coded_schhd, 216'd0} (SCH/HD MSB-aligned)
 // pdu_type = PDUC_SLOTFMT_SCH_HD
 // target_tn = latched cfg_mcch_tn
 //
 // Z.8 MSB-alignment: the scheduler reads BKN1 from head_coded[431:216].
 // Pushing LSB-aligned would deliver 216 zero-bits to the slot → SCH/HD
 // CRC fail → MS drops Pre-Reply. See Z.8 commit context.
 // -------------------------------------------------------------------------
 assign wr_slotgrant_coded_sys = {lat_coded_schhd, 216'd0};
 assign wr_slotgrant_pdu_type_sys = `PDUC_PRE_REPLY_SLOTGRANT_FMT;
 assign wr_slotgrant_target_tn_sys = lat_target_tn;

endmodule

`default_nettype wire
