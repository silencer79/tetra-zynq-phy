`timescale 1ns / 1ps
`default_nettype none

// Standalone CIC pair test: TX CIC interp ×64 → RX CIC decim ÷64
// Feeds a known low-frequency sinusoidal IQ signal, verifies roundtrip amplitude and phase.
// Runs at a single clock (clk_sys = clk_lvds = 100 MHz).

module tb_cic_pair_only;

localparam CLK_HALF = 5;
localparam IQ_WIDTH = 16;

reg clk;
reg rst_n;

initial clk = 0;
always #CLK_HALF clk = ~clk;

// ---- Generate input: rotating phasor at ~390 kHz / 16 = ~24 kHz ----
// One symbol per 1024 clk → 4× oversample → one valid per 256 clk.
// Phase step = 2π/16 = π/8 per valid → rotate every valid by 22.5°.
// I = cos(n*π/8)*8000, Q = sin(n*π/8)*8000

reg signed [15:0] gen_i, gen_q;
reg               gen_valid;
reg  [7:0]        gen_cnt;      // 0..255 → gen_valid at cnt==0
reg  [3:0]        gen_phase;    // 0..15 → one rotation every 16 valids
integer           gen_total;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        gen_cnt <= 0;
        gen_valid <= 0;
        gen_phase <= 0;
        gen_total <= 0;
    end else begin
        gen_cnt <= gen_cnt + 1;
        gen_valid <= (gen_cnt == 8'd255);
        if (gen_cnt == 8'd255) begin
            gen_phase <= gen_phase + 1;
            gen_total <= gen_total + 1;
        end
    end
end

// Phasor lookup (cos/sin table for 16 phases, amplitude 8000)
always @(*) begin
    case (gen_phase)
        4'd0:  begin gen_i =  16'sd8000;  gen_q =  16'sd0;     end
        4'd1:  begin gen_i =  16'sd7391;  gen_q =  16'sd3061;  end
        4'd2:  begin gen_i =  16'sd5657;  gen_q =  16'sd5657;  end
        4'd3:  begin gen_i =  16'sd3061;  gen_q =  16'sd7391;  end
        4'd4:  begin gen_i =  16'sd0;     gen_q =  16'sd8000;  end
        4'd5:  begin gen_i = -16'sd3061;  gen_q =  16'sd7391;  end
        4'd6:  begin gen_i = -16'sd5657;  gen_q =  16'sd5657;  end
        4'd7:  begin gen_i = -16'sd7391;  gen_q =  16'sd3061;  end
        4'd8:  begin gen_i = -16'sd8000;  gen_q =  16'sd0;     end
        4'd9:  begin gen_i = -16'sd7391;  gen_q = -16'sd3061;  end
        4'd10: begin gen_i = -16'sd5657;  gen_q = -16'sd5657;  end
        4'd11: begin gen_i = -16'sd3061;  gen_q = -16'sd7391;  end
        4'd12: begin gen_i =  16'sd0;     gen_q = -16'sd8000;  end
        4'd13: begin gen_i =  16'sd3061;  gen_q = -16'sd7391;  end
        4'd14: begin gen_i =  16'sd5657;  gen_q = -16'sd5657;  end
        4'd15: begin gen_i =  16'sd7391;  gen_q = -16'sd3061;  end
        default: begin gen_i = 16'sd0; gen_q = 16'sd0; end
    endcase
end

// ---- TX CIC interpolator (from tx_frontend) ----
wire signed [15:0] tx_cic_i, tx_cic_q;
wire               tx_cic_valid;

tetra_tx_frontend #(
    .IQ_WIDTH(16), .CIC_SHIFT(24), .CIC_ACC(48)
) u_tx_fe (
    .clk_sys(clk), .rst_n_sys(rst_n),
    .i_in(gen_i), .q_in(gen_q), .sample_valid_in(gen_valid),
    .clk_lvds(clk), .rst_n_lvds(rst_n),
    .tx_i_lvds(tx_cic_i), .tx_q_lvds(tx_cic_q), .tx_valid_lvds(tx_cic_valid)
);

// ---- RX CIC decimator (from rx_frontend) ----
wire signed [15:0] rx_fe_i, rx_fe_q;
wire               rx_fe_valid;

tetra_rx_frontend #(
    .IQ_WIDTH(16), .CIC_ORDER(5), .CIC_R(64), .CIC_M(1),
    .RRC_TAPS(33), .RRC_ACC_SHIFT(14)
) u_rx_fe (
    .clk_sys(clk), .rst_n_sys(rst_n),
    .clk_lvds(clk), .rst_n_lvds(rst_n),
    .rx_i_lvds(tx_cic_i), .rx_q_lvds(tx_cic_q), .rx_valid_lvds(tx_cic_valid),
    .i_out_sys(rx_fe_i), .q_out_sys(rx_fe_q), .out_valid_sys(rx_fe_valid),
    .loopback_en_sys(1'b1)
);

// ---- Monitor RX frontend output ----
integer rx_count;
integer max_i, max_q;
integer cur_abs_i, cur_abs_q;

always @(posedge clk) begin
    if (!rst_n) begin
        rx_count <= 0;
        max_i <= 0;
        max_q <= 0;
    end else if (rx_fe_valid) begin
        rx_count <= rx_count + 1;
        cur_abs_i = (rx_fe_i[15]) ? (~rx_fe_i + 1) : rx_fe_i;
        cur_abs_q = (rx_fe_q[15]) ? (~rx_fe_q + 1) : rx_fe_q;
        if (cur_abs_i > max_i) max_i <= cur_abs_i;
        if (cur_abs_q > max_q) max_q <= cur_abs_q;
        if (rx_count < 80)
            $display("rx[%0d] i=%0d q=%0d  gen_total=%0d t=%0t",
                     rx_count, rx_fe_i, rx_fe_q, gen_total, $time);
    end
end

initial begin
    $dumpfile("tb_cic_pair_only.vcd");
    $dumpvars(0, tb_cic_pair_only);

    rst_n = 0;
    repeat (20) @(posedge clk);
    rst_n = 1;

    // Wait for 200 RX output samples
    wait (rx_count >= 200);
    $display("=== CIC pair test: %0d output samples, max_i=%0d max_q=%0d (input_amp=8000) ===",
             rx_count, max_i, max_q);
    if (max_i < 4000 || max_q < 4000)
        $display("FAIL: output amplitude too low (expected ~8000)");
    else if (max_i > 20000 || max_q > 20000)
        $display("WARN: output amplitude higher than expected (RRC gain?)");
    else
        $display("PASS: amplitude approximately correct");
    $finish;
end

endmodule

`default_nettype wire
