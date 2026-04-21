`timescale 1ns / 1ps

module tb_scramble_mask;

function [119:0] compute_scramble_mask;
    input [31:0] init;
    reg [31:0] lfsr;
    reg        fb;
    integer    i;
    begin
        lfsr = init;
        compute_scramble_mask = 120'b0;
        for (i = 0; i < 120; i = i + 1) begin
            fb = lfsr[31] ^ lfsr[25] ^ lfsr[22] ^ lfsr[21] ^
                 lfsr[15] ^ lfsr[11] ^ lfsr[10] ^ lfsr[9]  ^
                 lfsr[7]  ^ lfsr[6]  ^ lfsr[4]  ^ lfsr[3]  ^
                 lfsr[1]  ^ lfsr[0];
            compute_scramble_mask[119 - i] = fb;
            lfsr = {fb, lfsr[31:1]};
        end
    end
endfunction

function [119:0] bsch_interleave;
    input [119:0] din;
    integer       k;
    reg [119:0]   dout;
    begin
        dout = 120'b0;
        for (k = 1; k <= 120; k = k + 1) begin
            dout[120 - (1 + (11 * k) % 120)] = din[120 - k];
        end
        bsch_interleave = dout;
    end
endfunction

localparam [119:0] MASK = compute_scramble_mask(32'h00000003);

initial begin
    $display("SCRAMBLE_MASK = %030h", MASK);

    // Quick encoder test: feed known input, check output
    // PDU for SC=1, CC=49, TN=1, FN=5, MN=39, SM=0, TSR=0, UP=0, F18=0, MCC=901, MNC=9998, NCB=0, CSL=0, LEI=0
    // = 4'h1, 6'd49, 2'd1, 5'd5, 6'd39, 2'd0, 3'd0, 1'b0, 1'b0, 1'b0, 10'd901, 14'd9998, 2'd0, 2'd0, 1'b0
    // system_code = 0001 (4 bits)
    // colour_code = 110001 (6 bits)
    // timeslot = 01 (2 bits)
    // frame = 00101 (5 bits)
    // multiframe = 100111 (6 bits)
    // sharing_mode = 00, ts_res = 000, u_plane = 0, f18ext = 0, reserved = 0
    // mcc = 1110000101 (901 decimal, 10 bits)
    // mnc = 10011100001110 (9998 decimal, 14 bits)
    // ncb = 00, csl = 00, lei = 0

    $display("Expected Python MASK = 7f4b1f43cc5bf847383a2410be1c86");
    if (MASK == 120'h7f4b1f43cc5bf847383a2410be1c86)
        $display("SCRAMBLE_MASK: MATCH");
    else
        $display("SCRAMBLE_MASK: MISMATCH!");

    // Test interleaver with a known pattern
    begin : test_interleave
        reg [119:0] test_in, test_out;
        integer i;
        test_in = 120'h0;
        for (i = 0; i < 120; i = i + 1)
            test_in[119-i] = (i < 10) ? 1'b1 : 1'b0;
        test_out = bsch_interleave(test_in);
        $display("Interleave test_in  = %030h", test_in);
        $display("Interleave test_out = %030h", test_out);
    end

    $finish;
end

endmodule
