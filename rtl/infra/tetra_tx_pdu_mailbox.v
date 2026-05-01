// =============================================================================
// tetra_tx_pdu_mailbox.v — Phase H.4.2 — TX-PDU-Submit-Mailbox
// =============================================================================
//
// 4-slot mailbox for ARM PS to submit DL-reply PDUs to the FPGA TX path.
// SW workflow:
//   1. Choose a free slot (status[empty] == 1).
//   2. Write the 432-bit SCH/F-coded PDU bytes into the slot via 14 AXI
//      writes (TX_MAILBOX_DATA[0..13] words, low 16 bits of word 13 = bits
//      431:416; high 16 bits ignored).
//   3. Write TX_MAILBOX_HINT (target TN/FN/MN + burst type).
//   4. Pulse TX_MAILBOX_SUBMIT bit[slot] — slot transitions empty → in_flight.
//   5. FPGA waits for matching TDMA slot, fires `pdu_match_valid_sys` for
//      one cycle with the slot's PDU + burst type, then asserts
//      `pdu_consumed_sys` to release the slot back to empty.
//
// Match policy: a slot fires when ALL of (cur_tn, cur_fn, cur_mn,
// cur_burst_type) equal the slot's hint AND the slot is in_flight.  If
// multiple slots match in the same cycle, the lowest-indexed slot wins
// (others remain in_flight for the next matching opportunity).
//
// Wildcard support: setting hint.fn==31 wildcards the FN match; setting
// hint.mn==63 wildcards the MN match.  This lets SW push a "next available
// slot of TN=X, burst_type=Y" PDU without precise frame timing.
//
// Resource estimate (Zynq-7020):
//   Storage: 4 × 432 bits = 1728 bits.  Synth tools may pack into 1-2
//     LUTRAM blocks or 1 RAMB18 depending on access pattern (we read all
//     432 bits in parallel, so distributed RAM is preferred — pure FFs
//     are ~1728 FFs which is large but acceptable here).
//   Status:  4 × (15 bit hint + 2 bit state) = 68 FFs.
//   LUT:     ~250 (match logic + write decode + status mux).
//
// =============================================================================

`default_nettype none

module tetra_tx_pdu_mailbox #(
    parameter PDU_WIDTH    = 432,
    parameter NUM_SLOTS    = 4,
    parameter SLOT_IDX_W   = 2,
    parameter HINT_TN_W    = 2,
    parameter HINT_FN_W    = 5,
    parameter HINT_MN_W    = 6,
    parameter HINT_BT_W    = 2,
    parameter PDU_WORDS    = 14         // ceil(432 / 32) = 14
)(
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,

    // -------------------------------------------------------------------------
    // AXI-side staging port (clk_axi == clk_sys in this design)
    //
    // SW writes to a specific slot's PDU words via wr_data_pulse_axi:
    //   slot_idx_axi  — which of NUM_SLOTS slots to target
    //   word_idx_axi  — 0..PDU_WORDS-1 (which 32-bit slice to update)
    //   wr_data_axi   — payload (low 16 bits of word index 13 are used,
    //                   high 16 ignored — PDU is 432 bits)
    //
    // SW writes the hint via wr_hint_pulse_axi:
    //   hint_data_axi[14:0] = {tn[1:0], fn[4:0], mn[5:0], bt[1:0]}
    //
    // SW pulses submit via wr_submit_pulse_axi:
    //   submit_mask_axi[NUM_SLOTS-1:0] — bit[i]=1 → mark slot i in_flight
    //
    // Status read (combinational, presented continuously):
    //   status_axi[31:0] = packed per-slot state (see below)
    // -------------------------------------------------------------------------
    input  wire                       wr_data_pulse_axi,
    input  wire [SLOT_IDX_W-1:0]      slot_idx_axi,
    input  wire [3:0]                 word_idx_axi,
    input  wire [31:0]                wr_data_axi,

    input  wire                       wr_hint_pulse_axi,
    input  wire [SLOT_IDX_W-1:0]      hint_slot_idx_axi,
    input  wire [14:0]                hint_data_axi,

    input  wire                       wr_submit_pulse_axi,
    input  wire [NUM_SLOTS-1:0]       submit_mask_axi,

    output wire [31:0]                status_axi,

    // -------------------------------------------------------------------------
    // TX-side query port — driven by tetra_slot_content_mux upstream.
    // -------------------------------------------------------------------------
    input  wire [HINT_TN_W-1:0]       cur_tn_sys,
    input  wire [HINT_FN_W-1:0]       cur_fn_sys,
    input  wire [HINT_MN_W-1:0]       cur_mn_sys,
    input  wire [HINT_BT_W-1:0]       cur_burst_type_sys,
    input  wire                       cur_query_valid_sys,

    output reg                        pdu_match_valid_sys,
    output reg  [PDU_WIDTH-1:0]       pdu_bits_sys,
    output reg  [HINT_BT_W-1:0]       pdu_burst_type_sys,
    output reg  [SLOT_IDX_W-1:0]      pdu_slot_idx_sys,
    input  wire                       pdu_consumed_sys
);

    // -------------------------------------------------------------------------
    // Storage: per-slot PDU + hint + state.  Verilog-2001 forbids array of
    // bytes in synth code, but BRAM-inferred packed storage is the standard
    // exception (see active_session_table.v).  We use a distributed-RAM
    // attribute hint because we need fully-parallel 432-bit reads.
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *)
    reg [PDU_WIDTH-1:0]   pdu_storage_sys [0:NUM_SLOTS-1];

    reg [14:0]            hint_storage_sys [0:NUM_SLOTS-1];

    // Per-slot state: 2'b00 = EMPTY, 2'b01 = STAGING, 2'b10 = IN_FLIGHT
    // Transitions:
    //   EMPTY    → STAGING    on first wr_data_pulse_axi to that slot
    //   STAGING  → IN_FLIGHT  on submit pulse
    //   IN_FLIGHT → EMPTY     on pdu_consumed_sys (FPGA TX done)
    //   any      → EMPTY      via reset
    reg [1:0]             state_sys [0:NUM_SLOTS-1];

    localparam [1:0] S_EMPTY     = 2'b00;
    localparam [1:0] S_STAGING   = 2'b01;
    localparam [1:0] S_IN_FLIGHT = 2'b10;

    // -------------------------------------------------------------------------
    // PDU storage write — selectable 32-bit slice within the 432-bit PDU
    // -------------------------------------------------------------------------
    wire [PDU_WIDTH-1:0]  pdu_wr_mask_w;
    wire [PDU_WIDTH-1:0]  pdu_wr_data_w;

    // Build a mask covering exactly bits [word_idx*32+31 : word_idx*32]
    // (with truncation at the top — words 13 maps to bits [431:416], only
    // 16 bits valid, but the full 32-bit write still lands in storage with
    // the upper 16 bits visible if SW wrote them).
    //
    // We materialise this combinationally as a shift of a 32-bit one-pad.
    reg [PDU_WIDTH-1:0] mask_r;
    reg [PDU_WIDTH-1:0] data_r;
    always @* begin
        mask_r = {{(PDU_WIDTH-32){1'b0}}, 32'hFFFF_FFFF} << (word_idx_axi * 32);
        data_r = {{(PDU_WIDTH-32){1'b0}}, wr_data_axi}    << (word_idx_axi * 32);
    end
    assign pdu_wr_mask_w = mask_r;
    assign pdu_wr_data_w = data_r;

    // -------------------------------------------------------------------------
    // Slot-level write process — apply pdu, hint, submit, consumed events.
    // Use unrolled per-slot blocks so each register has a single always
    // (per Verilog-2001 R1).
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < NUM_SLOTS; gi = gi + 1) begin : slot_array

            // PDU storage — unique always per slot
            always @(posedge clk_sys) begin
                if (wr_data_pulse_axi && (slot_idx_axi == gi[SLOT_IDX_W-1:0])) begin
                    pdu_storage_sys[gi] <=
                        (pdu_storage_sys[gi] & ~pdu_wr_mask_w) | pdu_wr_data_w;
                end
            end

            // Hint storage
            always @(posedge clk_sys or negedge rst_n_sys) begin
                if (!rst_n_sys)
                    hint_storage_sys[gi] <= 15'd0;
                else if (wr_hint_pulse_axi && (hint_slot_idx_axi == gi[SLOT_IDX_W-1:0]))
                    hint_storage_sys[gi] <= hint_data_axi;
            end

            // State FSM — transitions described in header
            always @(posedge clk_sys or negedge rst_n_sys) begin
                if (!rst_n_sys)
                    state_sys[gi] <= S_EMPTY;
                else begin
                    case (state_sys[gi])
                        S_EMPTY: begin
                            if (wr_data_pulse_axi && (slot_idx_axi == gi[SLOT_IDX_W-1:0]))
                                state_sys[gi] <= S_STAGING;
                            else if (wr_hint_pulse_axi &&
                                     (hint_slot_idx_axi == gi[SLOT_IDX_W-1:0]))
                                state_sys[gi] <= S_STAGING;
                        end
                        S_STAGING: begin
                            if (wr_submit_pulse_axi && submit_mask_axi[gi])
                                state_sys[gi] <= S_IN_FLIGHT;
                        end
                        S_IN_FLIGHT: begin
                            if (pdu_consumed_sys && (pdu_slot_idx_sys == gi[SLOT_IDX_W-1:0]))
                                state_sys[gi] <= S_EMPTY;
                        end
                        default: state_sys[gi] <= S_EMPTY;
                    endcase
                end
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Match logic — pure combinational scan across slots.
    //
    // Wildcards: hint.fn = 5'd31 → match any FN.  hint.mn = 6'd63 → match
    // any MN.  TN and burst_type always strict.
    // -------------------------------------------------------------------------
    wire match_w  [0:NUM_SLOTS-1];
    generate
        for (gi = 0; gi < NUM_SLOTS; gi = gi + 1) begin : match_array
            wire [HINT_TN_W-1:0] h_tn = hint_storage_sys[gi][14:13];
            wire [HINT_FN_W-1:0] h_fn = hint_storage_sys[gi][12:8];
            wire [HINT_MN_W-1:0] h_mn = hint_storage_sys[gi][7:2];
            wire [HINT_BT_W-1:0] h_bt = hint_storage_sys[gi][1:0];
            assign match_w[gi] =
                (state_sys[gi] == S_IN_FLIGHT) &&
                cur_query_valid_sys &&
                (h_tn == cur_tn_sys) &&
                ((h_fn == 5'd31) || (h_fn == cur_fn_sys)) &&
                ((h_mn == 6'd63) || (h_mn == cur_mn_sys)) &&
                (h_bt == cur_burst_type_sys);
        end
    endgenerate

    // Lowest-index priority encoder (4 slots → flat case)
    reg                       any_match_r;
    reg [SLOT_IDX_W-1:0]      win_slot_r;
    reg [PDU_WIDTH-1:0]       win_pdu_r;
    reg [HINT_BT_W-1:0]       win_bt_r;
    always @* begin
        any_match_r = 1'b0;
        win_slot_r  = {SLOT_IDX_W{1'b0}};
        win_pdu_r   = {PDU_WIDTH{1'b0}};
        win_bt_r    = {HINT_BT_W{1'b0}};
        if (match_w[0]) begin
            any_match_r = 1'b1;
            win_slot_r  = 2'd0;
            win_pdu_r   = pdu_storage_sys[0];
            win_bt_r    = hint_storage_sys[0][1:0];
        end else if (match_w[1]) begin
            any_match_r = 1'b1;
            win_slot_r  = 2'd1;
            win_pdu_r   = pdu_storage_sys[1];
            win_bt_r    = hint_storage_sys[1][1:0];
        end else if (match_w[2]) begin
            any_match_r = 1'b1;
            win_slot_r  = 2'd2;
            win_pdu_r   = pdu_storage_sys[2];
            win_bt_r    = hint_storage_sys[2][1:0];
        end else if (match_w[3]) begin
            any_match_r = 1'b1;
            win_slot_r  = 2'd3;
            win_pdu_r   = pdu_storage_sys[3];
            win_bt_r    = hint_storage_sys[3][1:0];
        end
    end

    // Registered TX outputs — pdu_match_valid_sys is a 1-cycle pulse;
    // pdu_bits/pdu_burst_type/pdu_slot_idx hold for the TX consumer.
    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pdu_match_valid_sys <= 1'b0;
        else
            pdu_match_valid_sys <= any_match_r;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pdu_bits_sys <= {PDU_WIDTH{1'b0}};
        else if (any_match_r)
            pdu_bits_sys <= win_pdu_r;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pdu_burst_type_sys <= {HINT_BT_W{1'b0}};
        else if (any_match_r)
            pdu_burst_type_sys <= win_bt_r;
    end

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys)
            pdu_slot_idx_sys <= {SLOT_IDX_W{1'b0}};
        else if (any_match_r)
            pdu_slot_idx_sys <= win_slot_r;
    end

    // -------------------------------------------------------------------------
    // Status word layout — 32 bit:
    //   [31:24] reserved (0)
    //   [23:20] slot3 {in_flight, staging, empty}     (3 bit + 1 reserved)
    //   [19:16] slot2 ditto
    //   [15:12] slot1 ditto
    //   [11:8]  slot0 ditto
    //   [7:0]   reserved (0)
    //
    // For each slot: bit0=empty, bit1=staging, bit2=in_flight; bit3=reserved
    // -------------------------------------------------------------------------
    function [3:0] slot_status_w;
        input [1:0] s;
        begin
            case (s)
                S_EMPTY:     slot_status_w = 4'b0001;
                S_STAGING:   slot_status_w = 4'b0010;
                S_IN_FLIGHT: slot_status_w = 4'b0100;
                default:     slot_status_w = 4'b0000;
            endcase
        end
    endfunction

    assign status_axi = {8'b0,
                         slot_status_w(state_sys[3]),
                         slot_status_w(state_sys[2]),
                         slot_status_w(state_sys[1]),
                         slot_status_w(state_sys[0]),
                         8'b0};

endmodule

`default_nettype wire
