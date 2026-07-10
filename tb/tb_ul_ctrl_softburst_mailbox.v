// tb_ul_ctrl_softburst_mailbox.v — verifiziert Packing/Negation/Header/valid/ack
// gegen das Wire-Format von sw/tetra_ul_rx_mailbox.h. Stimuli auf negedge (race-frei).
`timescale 1ns/1ps
`default_nettype none
module tb_ul_ctrl_softburst_mailbox;
    localparam integer SOFT_IN_W = 8, SOFT_W = 4, N_SOFT = 168;
    reg clk = 0, rst_n = 0;
    reg signed [SOFT_IN_W-1:0] sb0, sb1;
    reg svalid, sfirst, slast;
    reg [1:0] tn;
    reg ack;
    reg [8:0] index;
    wire [31:0] rdata;
    wire valid;
    wire [15:0] bursts;

    tetra_ul_ctrl_softburst_mailbox #(.SOFT_IN_W(SOFT_IN_W), .SOFT_W(SOFT_W), .N_SOFT(N_SOFT)) dut (
        .clk_sys(clk), .rst_n_sys(rst_n),
        .soft_bit0_sys(sb0), .soft_bit1_sys(sb1),
        .soft_valid_sys(svalid), .soft_first_sys(sfirst), .soft_last_sys(slast),
        .timeslot_num_sys(tn), .ack_pulse_sys(ack),
        .index_sys(index), .rdata_sys(rdata), .valid_sys(valid),
        .bursts_captured_sys(bursts));

    always #5 clk = ~clk;

    integer pass = 0, fail = 0;
    task ck; input cond; input [255:0] name;
        begin if (cond) pass=pass+1; else begin fail=fail+1; $display("  FAIL: %0s", name); end end
    endtask

    function signed [SOFT_W-1:0] negsat; input signed [SOFT_IN_W-1:0] x;
        integer nx; begin nx = -x;
            if (nx > 7) negsat = 7; else if (nx < -8) negsat = -8; else negsat = nx[SOFT_W-1:0]; end
    endfunction
    function signed [SOFT_IN_W-1:0] fv1; input integer k; begin fv1 = (k%2)? 3 : -100; end endfunction
    function signed [SOFT_IN_W-1:0] fv0; input integer k; begin fv0 = (k%3)? -2 : 90; end endfunction

    // Einen Burst (84 Dibits = 168 Soft) auf negedge einspeisen.
    // SCH/HU besteht aus zwei Code-Blöcken CB1 (k=0..41) + CB2 (k=42..83),
    // JEDER mit eigenem soft_first (Start) und soft_last (Ende). Die Mailbox
    // MUSS diese ignorieren und alle 168 kontinuierlich sammeln (sonst
    // überschreibt CB2 den CB1 → nur 84 Soft). Diese Doppel-first/last-
    // Einspeisung hätte den 100%-CRC-Fail-Bug gefangen.
    task feed_burst; input integer usefn; integer k; begin
        for (k=0; k<84; k=k+1) begin
            @(negedge clk);
            sb1 = usefn ? fv1(k) : 8'sd7;
            sb0 = usefn ? fv0(k) : -8'sd7;
            svalid = 1;
            sfirst = (k==0)  || (k==42); // CB1-Start UND CB2-Start
            slast  = (k==41) || (k==83); // CB1-Ende UND CB2-Ende
        end
        @(negedge clk); svalid=0; sfirst=0; slast=0; sb1=0; sb0=0;
    end endtask

    // AXI-Read (index auf negedge setzen, rdata ist kombinatorisch)
    task rd; input [8:0] ix; output [31:0] out; begin
        @(negedge clk); index = ix; #1 out = rdata;
    end endtask

    reg [31:0] w;
    initial begin
        sb0=0; sb1=0; svalid=0; sfirst=0; slast=0; tn=2'd2; ack=0; index=0;
        repeat(3) @(posedge clk); @(negedge clk); rst_n = 1;

        // ---- Spurious soft_valid OHNE soft_first (Rausch/False-Lock): der
        //      Anker muss darauf NICHT starten (valid bleibt 0, keine Drift). ----
        @(negedge clk); sb1=5; sb0=-5; svalid=1; sfirst=0; slast=0;
        @(negedge clk); sb1=6; sb0=-6; svalid=1; sfirst=0; slast=0;
        @(negedge clk); svalid=0; sfirst=0; slast=0; sb1=0; sb0=0;
        @(posedge clk);
        ck(valid===1'b0, "spurious ohne soft_first ignoriert (valid bleibt 0)");

        // ---- Burst 1 (ankert sauber auf soft_first trotz vorangehendem Rausch) ----
        feed_burst(1);
        @(posedge clk);
        ck(valid===1'b1, "valid nach Burst");
        ck(bursts===16'd1, "bursts_captured=1");

        rd(9'd0, w);
        ck(w[1:0]===2'd2,      "hdr slot_tn=2");
        ck(w[3:2]===2'd0,      "hdr burst_type=0");
        ck(w[15:4]===12'd168,  "hdr n_soft=168");
        ck(w[31]===1'b1,       "hdr valid=1");

        rd(9'd1, w);
        ck($signed(w[3:0])===negsat(fv1(0)),  "soft0=negsat(sb1[0])");
        ck($signed(w[7:4])===negsat(fv0(0)),  "soft1=negsat(sb0[0])");
        ck($signed(w[11:8])===negsat(fv1(1)), "soft2=negsat(sb1[1])");
        ck($signed(w[15:12])===negsat(fv0(1)),"soft3=negsat(sb0[1])");

        rd(9'd21, w);
        ck($signed(w[3:0])===negsat(fv1(80)),  "soft160=negsat(sb1[80])");
        ck($signed(w[31:28])===negsat(fv0(83)),"soft167=negsat(sb0[83])");

        // ---- ACK → valid clr ----
        @(negedge clk); ack=1; @(negedge clk); ack=0;
        @(posedge clk);
        ck(valid===1'b0, "valid nach ack=0");

        // ---- Re-Arm: zweiter Burst ----
        feed_burst(0);
        @(posedge clk);
        ck(valid===1'b1, "valid nach 2. Burst (re-arm)");
        ck(bursts===16'd2, "bursts_captured=2");

        $display("tb_ul_ctrl_softburst_mailbox: %0d/%0d PASS", pass, pass+fail);
        if (fail==0) $display("RESULT: PASS"); else $display("RESULT: FAIL");
        $finish;
    end
endmodule
`default_nettype wire
