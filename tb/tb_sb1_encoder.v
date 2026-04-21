`timescale 1ns / 1ps

module tb_sb1_encoder;

reg        clk, rst_n;
reg [3:0]  cfg_sc;
reg [5:0]  cfg_cc;
reg [1:0]  cfg_sm;
reg [2:0]  cfg_tsr;
reg        cfg_up, cfg_f18;
reg [9:0]  cfg_mcc;
reg [13:0] cfg_mnc;
reg [1:0]  cfg_ncb, cfg_csl;
reg        cfg_lei;
reg        encode_start;
reg [1:0]  sdb_slot;
reg [4:0]  frame_num;
reg [5:0]  mf_num;

wire [119:0] sb1_coded;
wire         sb1_valid;

tetra_sb1_encoder uut (
    .clk_sys(clk), .rst_n_sys(rst_n),
    .cfg_system_code(cfg_sc),
    .cfg_colour_code(cfg_cc),
    .cfg_sharing_mode(cfg_sm),
    .cfg_ts_reserved_frames(cfg_tsr),
    .cfg_u_plane(cfg_up),
    .cfg_frame_18_ext(cfg_f18),
    .cfg_mcc(cfg_mcc),
    .cfg_mnc(cfg_mnc),
    .cfg_neighbour_cell_broadcast(cfg_ncb),
    .cfg_cell_service_level(cfg_csl),
    .cfg_late_entry_info(cfg_lei),
    .encode_start_sys(encode_start),
    .sdb_slot_sys(sdb_slot),
    .frame_num_sys(frame_num),
    .multiframe_num_sys(mf_num),
    .sb1_coded_sys(sb1_coded),
    .sb1_valid_sys(sb1_valid)
);

always #5 clk = ~clk;  // 100 MHz

initial begin
    clk = 0; rst_n = 0; encode_start = 0;
    cfg_sc = 4'd1; cfg_cc = 6'd49; cfg_sm = 2'd0; cfg_tsr = 3'd0;
    cfg_up = 1'b0; cfg_f18 = 1'b0; cfg_mcc = 10'd901; cfg_mnc = 14'd9998;
    cfg_ncb = 2'd0; cfg_csl = 2'd0; cfg_lei = 1'b0;
    sdb_slot = 2'd1; frame_num = 5'd5; mf_num = 6'd1;

    #20 rst_n = 1;
    #10;

    // Test 1: FN=5, MN=1, TN=1
    encode_start = 1;
    #10 encode_start = 0;

    // Wait for completion
    wait(sb1_valid);
    #10;
    $display("TEST1 FN=5 MN=1 TN=1: sb1_coded = %030h", sb1_coded);

    // Test 2: FN=1, MN=2, TN=0
    sdb_slot = 2'd0; frame_num = 5'd1; mf_num = 6'd2;
    #20;
    encode_start = 1;
    #10 encode_start = 0;
    @(posedge clk);
    // Wait for S_FINISH (sb1_coded update)
    repeat(200) @(posedge clk);
    $display("TEST2 FN=1 MN=2 TN=0: sb1_coded = %030h", sb1_coded);

    // Test 3: FN=18, MN=60, TN=2
    sdb_slot = 2'd2; frame_num = 5'd18; mf_num = 6'd60;
    #20;
    encode_start = 1;
    #10 encode_start = 0;
    repeat(200) @(posedge clk);
    $display("TEST3 FN=18 MN=60 TN=2: sb1_coded = %030h", sb1_coded);

    $finish;
end

endmodule
