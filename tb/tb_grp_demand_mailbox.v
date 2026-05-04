// =============================================================================
// tb_grp_demand_mailbox.v — Phase Y.1.b Group-Attach Demand Mailbox regression
// =============================================================================
//
// Coverage:
//   TC1  single push (count=1, ssi=0x282FF4, gssi[0]=0x111111, adi=0, at=0,
//        class=4, atd_mode=0, grp_report=1) → verify W0..W6 bit-exact
//   TC2  push with count=3, three GSSIs/Classes/at → verify W2..W5 packing
//   TC3  push while pending=1 → drop_cnt += 1, latches unchanged
//   TC4  ack_consumed_pulse_sys clears pending → next push accepted
//
// Run:
//   iverilog -g2001 -o /tmp/tb_gdmbox tb/tb_grp_demand_mailbox.v \
//                                      rtl/lmac/tetra_grp_demand_mailbox.v \
//                                      rtl/lmac/tetra_indirect_mailbox.v
//   vvp /tmp/tb_gdmbox
//
// =============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_grp_demand_mailbox;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg        push_valid    = 1'b0;
    reg [23:0] push_ssi      = 24'd0;
    reg [1:0]  push_count    = 2'd0;
    reg        push_atd_mode = 1'b0;
    reg        push_grp_rep  = 1'b0;
    reg [71:0] push_gssi_arr = 72'd0;
    reg [8:0]  push_class    = 9'd0;
    reg [2:0]  push_adi      = 3'd0;
    reg [5:0]  push_at       = 6'd0;
    reg        ack_pulse     = 1'b0;
    reg [3:0]  index         = 4'd0;

    wire [31:0] data_word;
    wire        pending;
    wire [15:0] drop_cnt;

    tetra_grp_demand_mailbox dut (
        .clk_sys                       (clk),
        .rst_n_sys                     (rst_n),
        .grp_parsed_valid_sys          (push_valid),
        .grp_ul_ssi_sys                (push_ssi),
        .grp_rec_count_sys             (push_count),
        .grp_attach_detach_mode_sys    (push_atd_mode),
        .grp_group_identity_report_sys (push_grp_rep),
        .grp_gssi_array_sys            (push_gssi_arr),
        .grp_class_array_sys           (push_class),
        .grp_adi_array_sys             (push_adi),
        .grp_at_array_sys              (push_at),
        .ack_consumed_pulse_sys        (ack_pulse),
        .index_sys                     (index),
        .data_word_sys                 (data_word),
        .pending_sys                   (pending),
        .drop_cnt_sys                  (drop_cnt)
    );

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    reg [31:0] read_w;

    task automatic read_word;
        input  [3:0]  idx;
        output [31:0] word;
        begin
            index = idx;
            #1;
            word = data_word;
        end
    endtask

    task automatic check32;
        input [255:0] tag;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=0x%08h", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=0x%08h  expected=0x%08h",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic check_eq;
        input [255:0] tag;
        input integer got;
        input integer expected;
        begin
            if (got === expected) begin
                $display("  PASS  %0s  got=%0d", tag, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  FAIL  %0s  got=%0d  expected=%0d",
                         tag, got, expected);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    task automatic do_push;
        input [23:0] ssi_in;
        input [1:0]  cnt_in;
        input        atd_in;
        input        rep_in;
        input [71:0] g_in;
        input [8:0]  c_in;
        input [2:0]  adi_in;
        input [5:0]  at_in;
        begin
            @(posedge clk);
            push_ssi      <= ssi_in;
            push_count    <= cnt_in;
            push_atd_mode <= atd_in;
            push_grp_rep  <= rep_in;
            push_gssi_arr <= g_in;
            push_class    <= c_in;
            push_adi      <= adi_in;
            push_at       <= at_in;
            push_valid    <= 1'b1;
            @(posedge clk);
            push_valid    <= 1'b0;
            @(posedge clk);
        end
    endtask

    initial begin
        $display("=========================================================");
        $display("  tb_grp_demand_mailbox — Phase Y.1.b regression");
        $display("=========================================================");

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------------------------------------------------------------
        // TC0 — Reset baseline
        // -------------------------------------------------------------
        $display("TC0  reset baseline");
        check_eq("TC0.pending=0",   pending,  0);
        check_eq("TC0.drop_cnt=0",  drop_cnt, 0);
        read_word(4'd0, read_w);
        // W0 always carries 0xA7 magic — body fields zero at reset.
        check32 ("TC0.W0=magic_only", read_w, {8'hA7, 24'd0});
        read_word(4'd1, read_w);
        check32 ("TC0.W1=0",   read_w, 32'd0);
        read_word(4'd7, read_w);
        check32 ("TC0.W7=0",   read_w, 32'd0);
        read_word(4'd15, read_w);
        check32 ("TC0.W15=0",  read_w, 32'd0);

        // -------------------------------------------------------------
        // TC1 — single record
        // -------------------------------------------------------------
        $display("");
        $display("TC1  single push count=1 ssi=0x282FF4 gssi=0x111111 atd=0 rep=1");
        do_push(24'h282FF4, 2'd1, 1'b0, 1'b1,
                {48'd0, 24'h111111}, {6'd0, 3'b100}, 3'd0, 6'd0);

        check_eq("TC1.pending=1",   pending,  1);
        check_eq("TC1.drop_cnt=0",  drop_cnt, 0);

        read_word(4'd0, read_w);
        // W0: {0xA7, 3'd0, count=01, atd=0, rep=1, 17'd0}
        // bits [31:24]=0xA7, [23:21]=0, [20:19]=01, [18]=0, [17]=1, [16:0]=0
        check32("TC1.W0", read_w, {8'hA7, 3'd0, 2'd1, 1'b0, 1'b1, 17'd0});

        read_word(4'd1, read_w);
        check32("TC1.W1=ssi",   read_w, {8'd0, 24'h282FF4});
        read_word(4'd2, read_w);
        check32("TC1.W2=gssi0", read_w, {8'd0, 24'h111111});
        read_word(4'd3, read_w);
        check32("TC1.W3=gssi1", read_w, 32'd0);
        read_word(4'd4, read_w);
        check32("TC1.W4=gssi2", read_w, 32'd0);
        read_word(4'd5, read_w);
        check32("TC1.W5",       read_w, {14'd0, 6'd0, 3'd0, 9'd4});
        read_word(4'd6, read_w);
        check32("TC1.W6=drop=0",read_w, 32'd0);
        read_word(4'd8, read_w);
        check32("TC1.W8=resv",  read_w, 32'd0);

        // -------------------------------------------------------------
        // TC2 — count=3, full GSSI array
        // -------------------------------------------------------------
        $display("");
        $display("TC2  count=3 ssi=0xAAAAAA gssis=0x111111/0x222222/0x333333");
        ack_pulse <= 1'b1;
        @(posedge clk);
        ack_pulse <= 1'b0;
        @(posedge clk);

        do_push(24'hAAAAAA, 2'd3, 1'b1, 1'b0,
                {24'h333333, 24'h222222, 24'h111111},
                {3'd2, 3'd1, 3'd4},     // class[2]=2 class[1]=1 class[0]=4
                3'b101,                  // adi[2]=1 adi[1]=0 adi[0]=1
                {2'd2, 2'd0, 2'd1});     // at[2]=2  at[1]=0  at[0]=1

        check_eq("TC2.pending=1",  pending, 1);

        read_word(4'd0, read_w);
        check32("TC2.W0", read_w, {8'hA7, 3'd0, 2'd3, 1'b1, 1'b0, 17'd0});
        read_word(4'd2, read_w);
        check32("TC2.W2=gssi0", read_w, {8'd0, 24'h111111});
        read_word(4'd3, read_w);
        check32("TC2.W3=gssi1", read_w, {8'd0, 24'h222222});
        read_word(4'd4, read_w);
        check32("TC2.W4=gssi2", read_w, {8'd0, 24'h333333});
        read_word(4'd5, read_w);
        check32("TC2.W5", read_w, {14'd0, {2'd2, 2'd0, 2'd1}, 3'b101,
                                     {3'd2, 3'd1, 3'd4}});

        // -------------------------------------------------------------
        // TC3 — drop while pending
        // -------------------------------------------------------------
        $display("");
        $display("TC3  push while pending → drop_cnt += 1");
        do_push(24'hBBBBBB, 2'd1, 1'b0, 1'b0,
                {48'd0, 24'h444444}, 9'd0, 3'd0, 6'd0);
        check_eq("TC3.pending=1",   pending,  1);
        check_eq("TC3.drop_cnt=1",  drop_cnt, 1);
        read_word(4'd1, read_w);
        check32("TC3.W1=stale ssi (still TC2)", read_w, {8'd0, 24'hAAAAAA});

        // -------------------------------------------------------------
        // TC4 — ACK + new push accepted
        // -------------------------------------------------------------
        $display("");
        $display("TC4  ACK clears pending, next push accepted");
        ack_pulse <= 1'b1;
        @(posedge clk);
        ack_pulse <= 1'b0;
        @(posedge clk);
        check_eq("TC4.pending=0 after ACK", pending, 0);

        do_push(24'hCCCCCC, 2'd2, 1'b0, 1'b1,
                {24'd0, 24'hF0F0F0, 24'h0F0F0F}, 9'b011_010_110,
                3'd0, 6'd0);
        check_eq("TC4.pending=1 after push", pending, 1);
        read_word(4'd1, read_w);
        check32("TC4.W1=new ssi", read_w, {8'd0, 24'hCCCCCC});
        read_word(4'd2, read_w);
        check32("TC4.W2=gssi0",   read_w, {8'd0, 24'h0F0F0F});

        // -------------------------------------------------------------
        $display("");
        $display("=========================================================");
        $display("  tb_grp_demand_mailbox SUMMARY  pass=%0d  fail=%0d",
                 pass_cnt, fail_cnt);
        $display("=========================================================");
        if (fail_cnt == 0) $display("  RESULT: PASS");
        else               $display("  RESULT: FAIL");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("ERROR: TB watchdog");
        $finish;
    end

endmodule

`default_nettype wire
