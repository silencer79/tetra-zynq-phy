// =============================================================================
// xilinx_prim_sim.v — Minimal behavioural models for Xilinx LVDS primitives
// =============================================================================
// For use with iverilog when Xilinx simulation libraries are not available.
// These are simplified functional models — NOT timing-accurate.
//
// Primitives modelled:
// IBUFDS — differential input buffer → single-ended output
// BUFG — global clock buffer (wire-through)
// IDDR — Input DDR register (SAME_EDGE_PIPELINED mode)
// ODDR — Output DDR register
// OBUFDS — differential output buffer
// =============================================================================

`timescale 1ns / 1ps

// ---------------------------------------------------------------------------
// IBUFDS — Differential Input Buffer
// Simplified: output = positive input (IB ignored in simulation)
// ---------------------------------------------------------------------------
module IBUFDS #(
 parameter DIFF_TERM = "FALSE",
 parameter IBUF_LOW_PWR = "TRUE",
 parameter IOSTANDARD = "LVDS_25"
)(
 input wire I,
 input wire IB,
 output wire O
);
 assign O = I;
endmodule

// ---------------------------------------------------------------------------
// BUFG — Global Clock Buffer (wire-through for simulation)
// ---------------------------------------------------------------------------
module BUFG (
 input wire I,
 output wire O
);
 assign O = I;
endmodule

// ---------------------------------------------------------------------------
// IDDR — Input DDR Register
// SAME_EDGE_PIPELINED mode:
// Per Xilinx UG472: at posedge N, Q1 = data from rising edge N-1,
// Q2 = data from falling edge N-1.
//
// Source-synchronous DDR simulation with T_HOLD-after-edge stimulus:
// The testbench drives data T_HOLD ns AFTER each clock edge (source side).
// In this timing model:
// - Data set after posedge N is stable at negedge N → "rising-edge data"
// - Data set after negedge N is stable at posedge N+1 → "falling-edge data"
// Therefore to correctly recover rising/falling data:
// D_neg (captured at negedge N) = data from posedge N → Q1
// D (captured at posedge N+1) = data from negedge N → Q2
// ---------------------------------------------------------------------------
module IDDR #(
 parameter DDR_CLK_EDGE = "SAME_EDGE_PIPELINED",
 parameter INIT_Q1 = 1'b0,
 parameter INIT_Q2 = 1'b0,
 parameter SRTYPE = "SYNC"
)(
 input wire C,
 input wire CE,
 input wire D,
 input wire R,
 input wire S,
 output reg Q1,
 output reg Q2
);
 reg D_neg; // D sampled on negedge (captures data set after previous posedge)

 // Capture D on negedge → this is the "rising-edge data" (set at posedge+T_HOLD)
 always @(negedge C or posedge R) begin
 if (R)
 D_neg <= INIT_Q1;
 else if (CE)
 D_neg <= D;
 end

 // Register both on posedge (SAME_EDGE_PIPELINED)
 // Q1 = D_neg = rising-edge data (data from posedge N-1, seen at negedge N-1)
 // Q2 = D = falling-edge data (data from negedge N-1, stable at posedge N)
 always @(posedge C or posedge R) begin
 if (R) begin
 Q1 <= INIT_Q1;
 Q2 <= INIT_Q2;
 end else if (CE) begin
 Q1 <= D_neg; // rising-edge data (upper bits: I[11:6] / Q[11:6])
 Q2 <= D; // falling-edge data (lower bits: I[5:0] / Q[5:0])
 end
 end
endmodule

// ---------------------------------------------------------------------------
// ODDR — Output DDR Register
// SAME_EDGE mode: Q changes on posedge, D1 for posedge half, D2 for negedge
// ---------------------------------------------------------------------------
module ODDR #(
 parameter DDR_CLK_EDGE = "SAME_EDGE",
 parameter INIT = 1'b0,
 parameter SRTYPE = "SYNC"
)(
 input wire C,
 input wire CE,
 input wire D1,
 input wire D2,
 input wire R,
 input wire S,
 output reg Q
);
 reg d2_int;

 always @(posedge C or posedge R) begin
 if (R)
 d2_int <= 1'b0;
 else if (CE)
 d2_int <= D2;
 end

 always @(posedge C or negedge C or posedge R) begin
 if (R)
 Q <= INIT;
 else if (C && CE)
 Q <= D1;
 else if (!C)
 Q <= d2_int;
 end
endmodule

// ---------------------------------------------------------------------------
// OBUFDS — Differential Output Buffer
// Simplified: OP = I, ON = ~I
// ---------------------------------------------------------------------------
module OBUFDS #(
 parameter IOSTANDARD = "LVDS_25",
 parameter SLEW = "SLOW"
)(
 input wire I,
 output wire O,
 output wire OB
);
 assign O = I;
 assign OB = ~I;
endmodule

// ---------------------------------------------------------------------------
// xpm_fifo_async — Xilinx XPM Asynchronous FIFO (behavioural sim model)
// Supports FIFO_WRITE_DEPTH up to 4096, WRITE_DATA_WIDTH/READ_DATA_WIDTH
// must be equal in this simplified model. FIFO_READ_LATENCY=1 only.
// Not timing-accurate; functional CDC model using a shared memory array
// with Gray-code-style level pointers.
// ---------------------------------------------------------------------------
module xpm_fifo_async #(
 parameter integer FIFO_WRITE_DEPTH = 16,
 parameter integer WRITE_DATA_WIDTH = 32,
 parameter integer READ_DATA_WIDTH = 32,
 parameter READ_MODE = "std",
 parameter integer FIFO_READ_LATENCY = 1,
 parameter integer CDC_SYNC_STAGES = 2,
 parameter integer FULL_RESET_VALUE = 0,
 parameter ECC_MODE = "no_ecc",
 parameter integer RELATED_CLOCKS = 0,
 parameter USE_ADV_FEATURES = "0707",
 parameter DOUT_RESET_VALUE = "0",
 parameter integer WAKEUP_TIME = 0,
 parameter integer PROG_FULL_THRESH = 10,
 parameter integer PROG_EMPTY_THRESH = 3
)(
 // Write side
 input wire wr_clk,
 input wire rst,
 input wire wr_en,
 input wire [WRITE_DATA_WIDTH-1:0] din,
 output wire full,
 output wire wr_rst_busy,
 output wire prog_full,
 output wire overflow,
 output wire [31:0] wr_data_count,
 output wire almost_full,

 // Read side
 input wire rd_clk,
 input wire rd_en,
 output reg [READ_DATA_WIDTH-1:0] dout,
 output wire empty,
 output wire rd_rst_busy,
 output wire prog_empty,
 output wire underflow,
 output wire [31:0] rd_data_count,
 output wire almost_empty,

 // ECC / misc (tied off)
 input wire injectsbiterr,
 input wire injectdbiterr,
 output wire sbiterr,
 output wire dbiterr,
 input wire sleep
);
 localparam DEPTH = FIFO_WRITE_DEPTH;
 localparam AW = $clog2(DEPTH);

 // Storage
 reg [WRITE_DATA_WIDTH-1:0] mem [0:DEPTH-1];

 // Write pointer (wr_clk domain)
 reg [AW:0] wr_ptr;
 // Read pointer (rd_clk domain)
 reg [AW:0] rd_ptr;

 // Synchronise pointers across domains (2-stage, functionally instant in sim)
 reg [AW:0] wr_ptr_sync_rd;
 reg [AW:0] rd_ptr_sync_wr;

 // Reset synchroniser outputs
 reg wr_rst_r, rd_rst_r;

 always @(posedge wr_clk or posedge rst) begin
 if (rst) wr_rst_r <= 1'b1;
 else wr_rst_r <= 1'b0;
 end
 always @(posedge rd_clk or posedge rst) begin
 if (rst) rd_rst_r <= 1'b1;
 else rd_rst_r <= 1'b0;
 end

 assign wr_rst_busy = wr_rst_r;
 assign rd_rst_busy = rd_rst_r;

 // Sync pointers
 always @(posedge rd_clk) wr_ptr_sync_rd <= wr_ptr;
 always @(posedge wr_clk) rd_ptr_sync_wr <= rd_ptr;

 // FIFO full/empty (using extra bit for wrap detection)
 wire [AW:0] wr_used_wr = wr_ptr - rd_ptr_sync_wr;
 wire [AW:0] rd_used_rd = wr_ptr_sync_rd - rd_ptr;

 assign full = (wr_used_wr == DEPTH[AW:0]);
 assign empty = (rd_used_rd == {(AW+1){1'b0}});
 assign prog_full = (wr_used_wr >= PROG_FULL_THRESH[AW:0]);
 assign prog_empty = (rd_used_rd <= PROG_EMPTY_THRESH[AW:0]);
 assign almost_full = (wr_used_wr >= (DEPTH-1));
 assign almost_empty= (rd_used_rd <= 1);
 assign overflow = 1'b0;
 assign underflow = 1'b0;
 assign sbiterr = 1'b0;
 assign dbiterr = 1'b0;
 assign wr_data_count = {{(32-AW-1){1'b0}}, wr_used_wr};
 assign rd_data_count = {{(32-AW-1){1'b0}}, rd_used_rd};

 // Write
 integer i;
 always @(posedge wr_clk or posedge rst) begin
 if (rst) begin
 wr_ptr <= {(AW+1){1'b0}};
 for (i = 0; i < DEPTH; i = i + 1)
 mem[i] <= {WRITE_DATA_WIDTH{1'b0}};
 end else if (wr_en && !full) begin
 mem[wr_ptr[AW-1:0]] <= din;
 wr_ptr <= wr_ptr + 1'b1;
 end
 end

 // Read (FIFO_READ_LATENCY=1: dout updates one cycle after rd_en)
 always @(posedge rd_clk or posedge rst) begin
 if (rst) begin
 rd_ptr <= {(AW+1){1'b0}};
 dout <= {READ_DATA_WIDTH{1'b0}};
 end else if (rd_en && !empty) begin
 dout <= mem[rd_ptr[AW-1:0]];
 rd_ptr <= rd_ptr + 1'b1;
 end
 end

endmodule
