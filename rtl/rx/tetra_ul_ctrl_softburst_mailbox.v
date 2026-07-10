// =============================================================================
// tetra_ul_ctrl_softburst_mailbox.v — UL Control (SCH/HU) Soft-Burst → SW Mailbox
// =============================================================================
// Option B: der RTL demoduliert nur; SW dekodiert. Dieses Modul akkumuliert den
// 168-Soft-Dibit-Strom von tetra_ul_pi4dqpsk_demod (Control-Pfad), latcht die
// on-air Slot-Kennung (timeslot_num) und stellt ALLES AXI-lesbar bereit — im
// EXAKTEN Wire-Format von sw/tetra_ul_rx_mailbox.h:
//
//   W0 (Header): [1:0]=slot_tn  [3:2]=burst_type(0=SCH/HU)  [15:4]=n_soft(168)
//                [31]=valid
//   W1..W21    : 168 × SOFT_W-bit signed Soft, 8 Nibbles/Wort LSB-first
//                (soft i → Wort (1+i/8), Bits [(i%8)*SOFT_W +: SOFT_W]).
//
// Akkumulator gespiegelt von tetra_ul_sch_hu_decoder.v S_IDLE/S_COLLECT:
//   Start beim ERSTEN soft_valid (Index 0), danach je soft_valid +2 bis 168.
//   buf[2k]=soft_bit1 (=type5[2k]), buf[2k+1]=soft_bit0 (=type5[2k+1]).
//   soft_first/soft_last werden IGNORIERT — SCH/HU = CB1+CB2 (je 84 Soft),
//   jeder Block mit eigenem soft_first. Der alte Decoder zählt kontinuierlich
//   bis N_TX=168 (count-basiert); ein soft_first-Reset ließ CB2 CB1 überschreiben.
// Konvention: Demod-Soft ist ETSI (positiv=bit'0'); die SW erwartet positiv=bit'1'
//   (sw/tetra_ul_rx_mailbox.h), daher NEGIEREN wir beim Packen (+ auf SOFT_W sat).
//
// SW-Protokoll: STATUS[0]=valid pollen → W0..W21 via INDEX/DATA lesen →
//   ACK[0] pulsen (valid clr + naechster Burst scharf).
//
// Verilog-2001 strict. AXI-seitige index/ack sind bereits nach clk_sys resynct.
// =============================================================================
`default_nettype none

module tetra_ul_ctrl_softburst_mailbox #(
    parameter integer SOFT_IN_W = 8,    // Demod-Soft-Breite (signed)
    parameter integer SOFT_W    = 4,    // gepackte Mailbox-Soft-Breite (signed)
    parameter integer N_SOFT    = 168
) (
    input  wire                       clk_sys,
    input  wire                       rst_n_sys,

    // Soft-Strom von tetra_ul_pi4dqpsk_demod (Control-Pfad)
    input  wire signed [SOFT_IN_W-1:0] soft_bit0_sys,
    input  wire signed [SOFT_IN_W-1:0] soft_bit1_sys,
    input  wire                        soft_valid_sys,
    input  wire                        soft_first_sys,
    input  wire                        soft_last_sys,

    // Slot-Kennung (aus frame_counter)
    input  wire [1:0]                  timeslot_num_sys,

    // SW-ACK (clk_sys)
    input  wire                        ack_pulse_sys,

    // AXI-Read-Port
    input  wire [8:0]                  index_sys,
    output reg  [31:0]                 rdata_sys,
    output wire                        valid_sys,

    output reg  [15:0]                 bursts_captured_sys
);

    localparam integer PAYLOAD_BITS = N_SOFT * SOFT_W;         // 672
    localparam integer NUM_WORDS    = PAYLOAD_BITS / 32;       // 21
    localparam integer IDX_W        = 8;                       // 0..167 collect idx

    // ---- Negate 8-bit ETSI soft → SOFT_W-bit signed (sat), SW-Konvention ----
    // negsat(x) = clamp(-x, -2^(W-1), 2^(W-1)-1). Fuer SOFT_W=4: [-8,7].
    function signed [SOFT_W-1:0] negsat;
        input signed [SOFT_IN_W-1:0] x;
        reg signed [SOFT_IN_W:0] nx;
        begin
            nx = -x;
            if (nx >  ((1<<(SOFT_W-1)) - 1)) negsat =  ((1<<(SOFT_W-1)) - 1);
            else if (nx < -(1<<(SOFT_W-1)))  negsat = -(1<<(SOFT_W-1));
            else                             negsat = nx[SOFT_W-1:0];
        end
    endfunction

    // ---- Collect (Single-Buffer, COUNT-basiert — exakter Spiegel von
    //      tetra_ul_sch_hu_decoder.v S_IDLE/S_COLLECT):
    //   Start beim ERSTEN soft_valid (collecting=0 → Index 0); danach je
    //   soft_valid +2, bis 168 gesammelt sind (dann TN latchen + valid setzen).
    //   soft_first/soft_last werden IGNORIERT: SCH/HU besteht aus zwei
    //   Code-Blöcken (CB1+CB2, je 84 Soft), JEDER mit eigenem soft_first-Puls.
    //   Der alte Decoder zählt kontinuierlich bis N_TX=168 ohne Reset — ein
    //   soft_first-getriggerter Reset (wie zuvor) ließ CB2 den CB1 überschreiben
    //   → nur 84 Soft, Rest 0 → 100% CRC-Fail. ----
    reg [IDX_W-1:0]        idx_sys;              // naechster Buffer-Index (soft-Position)
    reg [PAYLOAD_BITS-1:0] packed_sys;          // Soft i @ [i*SOFT_W +: SOFT_W]
    reg [1:0]              tn_lat_sys;
    reg                    valid_r_sys;
    reg                    collecting_sys;       // 1 während einer laufenden Sammlung
    assign valid_sys = valid_r_sys;

    // gepackte Nibbles der zwei Softs dieses Zyklus (soft_bit1 zuerst, dann soft_bit0)
    wire signed [SOFT_W-1:0] n_b1 = negsat(soft_bit1_sys);
    wire signed [SOFT_W-1:0] n_b0 = negsat(soft_bit0_sys);
    // Schreib-Position: 0 beim Burst-Start (soft_first, idle), sonst laufender Index.
    wire [IDX_W-1:0] wpos       = collecting_sys ? idx_sys : {IDX_W{1'b0}};
    // Dieser Puls füllt das letzte Paar (166,167) → Burst komplett.
    wire             burst_done = ((wpos + 8'd2) >= N_SOFT[IDX_W-1:0]);

    // Anker: NUR bei soft_first (=CB1-Anfang) starten, wenn idle. So wird auf
    // den echten Burst-Start (nach Guard/Idle) synchronisiert statt auf ein
    // beliebiges soft_valid (Rausch/False-Lock/Partial) → driftfest wie der
    // alte Decoder (der via Decode-Pipeline-Delay re-synchronisierte).
    // Während des Sammelns wird soft_first (CB2-Anfang) IGNORIERT (do_cont).
    // soft_last bleibt ungenutzt (count-basiert bis 168).
    wire do_start = soft_valid_sys & soft_first_sys & ~collecting_sys;
    wire do_cont  = soft_valid_sys & collecting_sys;
    wire _unused_soft_last = soft_last_sys;

    always @(posedge clk_sys or negedge rst_n_sys) begin
        if (!rst_n_sys) begin
            idx_sys             <= {IDX_W{1'b0}};
            packed_sys          <= {PAYLOAD_BITS{1'b0}};
            tn_lat_sys          <= 2'd0;
            valid_r_sys         <= 1'b0;
            collecting_sys      <= 1'b0;
            bursts_captured_sys <= 16'd0;
        end else begin
            if (ack_pulse_sys) valid_r_sys <= 1'b0;

            if (do_start | do_cont) begin
                packed_sys[wpos*SOFT_W +: SOFT_W]            <= n_b1;
                packed_sys[(wpos+1'b1)*SOFT_W +: SOFT_W]     <= n_b0;
                if (burst_done) begin
                    idx_sys             <= {IDX_W{1'b0}};
                    collecting_sys      <= 1'b0;
                    tn_lat_sys          <= timeslot_num_sys;
                    valid_r_sys         <= 1'b1;
                    bursts_captured_sys <= bursts_captured_sys + 16'd1;
                end else begin
                    idx_sys             <= wpos + 8'd2;
                    collecting_sys      <= 1'b1;
                end
            end
        end
    end

    // ---- AXI-Read-Mux (kombinatorisch) ----
    // Header exakt nach sw/tetra_ul_rx_mailbox.h:
    //   [1:0]=slot_tn  [3:2]=burst_type(0=SCH/HU)  [15:4]=n_soft(168)  [31]=valid
    wire [31:0] header_w = {valid_r_sys, 15'd0, 12'd168, 2'd0, tn_lat_sys};

    always @(*) begin
        if (index_sys == 9'd0)
            rdata_sys = header_w;
        else if (index_sys <= NUM_WORDS[8:0])                 // 1..21 → Daten
            rdata_sys = packed_sys[(index_sys-9'd1)*32 +: 32];
        else
            rdata_sys = 32'd0;
    end

endmodule

`default_nettype wire
