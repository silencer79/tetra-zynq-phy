// =============================================================================
// Module:  tetra_zynq_top
// Project: tetra-zynq-phy
// File:    rtl/tetra_zynq_top.v
//
// Description:
//   Top-Level Design — TETRA PHY/LMAC Baseband Engine for LibreSDR
//   (Zynq-7020 XC7Z020-CLG484 + AD9361 RF Transceiver)
//
//   Instantiates and connects all sub-modules:
//     tetra_clk_reset              — Reset synchronizer (4 clock domains)
//     tetra_ad9361_axis_adapter    — ADI axi_ad9361 IP fabric ↔ tetra IQ interface
//     tetra_rx_chain               — RX datapath (frontend → demod → sync → TDMA)
//     tetra_lmac                   — Lower MAC (scrambler/interleaver/viterbi/CRC)
//     tetra_tx_chain               — TX datapath (burst_mux → builder → mod → CIC)
//     tetra_axi_dma_bridge         — S2MM DMA bridge (LMAC → AXI-DMA → PS DDR)
//     tetra_axi_lite_regs          — AXI4-Lite register bank (PS control/status)
//
//   AD9361 LVDS I/O is handled entirely by the ADI axi_ad9361 IP in the
//   Vivado Block Design.  This module connects to the IP's fabric-side ADC/DAC
//   data buses via tetra_ad9361_axis_adapter.
//
// Clock Domains:
//   i_clk   / clk_sys   — 100 MHz PL fabric clock (Zynq PS FCLK_CLK0)
//   clk_lvds             — adc_clk from axi_ad9361 IP (DATA_CLK domain)
//   s_axi_aclk           — AXI bus clock (from PS, same source as i_clk)
//
//   NOTE: clk_sys and s_axi_aclk are assumed to originate from the same PLL
//   but are treated as independent domains. For Phase 3 single-source boards
//   where both are driven from i_clk, any residual CDC risk is negligible and
//   documented in docs/timing_analysis.md.
//
// RX Data Flow:
//   axi_ad9361 IP → axis_adapter → rx_chain (CIC+RRC+demod+sync+demux)
//   → tetra_lmac (descramble+deinterleave+viterbi+CRC+RM-decode)
//   → rx_accumulator (serial→parallel, 216 bits)
//   → tetra_axi_dma_bridge (AXI4-Stream S2MM → PS DDR)
//
// TX Data Flow (Phase 3 — loopback / register-file mode):
//   AXI-Lite registers (slot payload) → tetra_tx_chain (burst_mux → burst_builder
//   → pi4dqpsk_mod → rrc_filter → tx_frontend CIC) → AD9361 LVDS
//
//   Full PS→PL TX DMA path (MM2S): Phase 4 TODO.
//   For Phase 3 initial on-air tests, TX block data is zero (idle bursts)
//   unless written via AXI-Lite scratch registers.
//
// AXI CDC Note:
//   Status signals from clk_sys domain to s_axi_aclk domain are passed through
//   2-FF synchronizers in this top-level (sync_locked, frame/slot counters).
//   IRQ pulses from clk_sys are converted to toggle-sync pairs before forwarding.
//
// Resource estimate (sum of all sub-modules, Phase 3):
//   LUT  : ~6000   FF  : ~12000   DSP48 : 4   BRAM18k : 1
//   (~11% LUT, ~11% FF, ~2% DSP48, <1% BRAM18k of Zynq-7020)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
//   R2 exception: AXI4-Lite and AXI4-Stream port names follow Vivado naming
//                 convention without domain suffix.
//
// Ref: ETSI EN 300 392-2 (TETRA V+D Air Interface)
//      Xilinx UG585 (Zynq-7000 TRM), Xilinx UG470 (7-Series Config)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tetra_zynq_top #(
    parameter IQ_WIDTH   = 16,
    parameter BLOCK_BITS = 216,
    parameter BB_BITS    = 30,
    parameter CORR_WIDTH = 24
)(
    // -------------------------------------------------------------------------
    // PL Clock & Reset (from Zynq PS)
    // -------------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 i_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET i_arst_n, FREQ_HZ 100000000" *)
    input  wire i_clk,          // 100 MHz FCLK_CLK0 from Zynq PS
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 i_arst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire i_arst_n,       // Active-low async reset from proc_sys_reset

    // -------------------------------------------------------------------------
    // axi_ad9361 IP fabric interface — ADC/DAC data buses from/to IP
    // LVDS pins are connected directly to axi_ad9361 in the Block Design.
    // Port names and directions taken verbatim from system_axi_ad9361_0.xci
    // (libresdr/ip/system_axi_ad9361_0/system_axi_ad9361_0.xci).
    // -------------------------------------------------------------------------
    // DATA_CLK — axi_ad9361.l_clk (master clock output of IP, drives both ADC+DAC)
    input  wire         l_clk,              // DATA_CLK from axi_ad9361 IP (l_clk port)
    // ADC — axi_ad9361 → fabric, channel 0 I (direction: out from IP)
    input  wire         adc_valid_i0,       // I0 sample valid (one-cycle pulse)
    input  wire [15:0]  adc_data_i0,        // I0 sample (signed 16-bit, sign-extended by IP)
    input  wire         adc_enable_i0,      // I0 path active (DC level)
    // ADC — axi_ad9361 → fabric, channel 0 Q (direction: out from IP)
    input  wire         adc_valid_q0,       // Q0 sample valid (parallel with adc_valid_i0)
    input  wire [15:0]  adc_data_q0,        // Q0 sample (signed 16-bit)
    input  wire         adc_enable_q0,      // Q0 path active
    // ADC — informational outputs from IP
    input  wire         adc_r1_mode,        // IP flag: operating in 1R1T mode
    output wire         adc_dovf,           // ADC data overflow to IP (drive 1'b0)
    // DAC — axi_ad9361 → fabric, enables/valids are IP outputs
    input  wire         dac_valid_i0,       // IP output: requests I0 DAC data each cycle
    input  wire         dac_enable_i0,      // IP output: I0 DAC path active
    input  wire         dac_valid_q0,       // IP output: requests Q0 DAC data each cycle
    input  wire         dac_enable_q0,      // IP output: Q0 DAC path active
    input  wire         dac_r1_mode,        // IP flag: operating in 1R1T mode
    // DAC — fabric → axi_ad9361, data is input to IP
    output wire [15:0]  dac_data_i0,        // I0 sample to DAC (signed 16-bit)
    output wire [15:0]  dac_data_q0,        // Q0 sample to DAC (signed 16-bit)
    output wire         dac_dunf,           // DAC data underflow to IP (drive 1'b0)

    // -------------------------------------------------------------------------
    // AXI4-Lite Slave Interface (from Zynq PS — GP0 port)
    // Base address: 0x4000_0000 (configured in Vivado Block Design)
    // -------------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
    input  wire         s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         s_axi_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [31:0]  s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]   s_axi_awprot,       // AXI4-Lite write protection (accepted, ignored)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire         s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]  s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]   s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire         s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire         s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [31:0]  s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]   s_axi_arprot,       // AXI4-Lite read protection (accepted, ignored)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire         s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire         s_axi_rready,

    // -------------------------------------------------------------------------
    // AXI4-Stream Master Interface (to Xilinx AXI DMA IP — S2MM channel)
    // -------------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire         m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    output wire [31:0]  m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
    output wire [3:0]   m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output wire         m_axis_tlast,

    // -------------------------------------------------------------------------
    // IRQ output to Zynq PS GIC (active-high)
    // -------------------------------------------------------------------------
    output wire         o_irq
);

// =============================================================================
// Clock distribution
// =============================================================================

// clk_sys: 100 MHz, all PL logic except LVDS capture
wire clk_sys;
assign clk_sys = i_clk;

// clk_lvds: AD9361 DATA_CLK, driven by axi_ad9361 IP via axis_adapter
wire clk_lvds;

// =============================================================================
// Reset synchronizer — distributes rst_n to all clock domains
// =============================================================================

wire rst_n_sys;
wire rst_n_lvds;
wire rst_n_axi;

tetra_clk_reset u_clk_reset (
    .arst_n      (i_arst_n),
    .clk_sys     (clk_sys),
    .clk_sample  (clk_sys),     // sample domain = sys domain (strobe-based)
    .clk_axi     (s_axi_aclk),
    .clk_lvds    (clk_lvds),    // driven by axi_ad9361 via axis_adapter output
    .rst_n_sys   (rst_n_sys),
    .rst_n_sample(),            // unused — same as rst_n_sys
    .rst_n_axi   (rst_n_axi),
    .rst_n_lvds  (rst_n_lvds)
);

// =============================================================================
// AXI-Lite control register outputs (clk_axi domain)
// =============================================================================

wire        ctrl_rx_enable_axi;
wire        ctrl_tx_enable_axi;
wire        ctrl_loopback_en_axi;
wire        ctrl_reset_counters_axi;
wire [7:0]  sync_thresh_axi;
wire [5:0]  colour_code_axi;
wire [6:0]  rx_gain_axi;
wire [7:0]  tx_att_axi;

// =============================================================================
// axi_ad9361 Adapter — fabric IQ interface to/from ADI IP block
//
// The axi_ad9361 IP (in the Vivado Block Design) handles all LVDS DDR I/O,
// DDR calibration, and AD9361 SPI configuration.  This adapter translates
// its fabric-side ADC/DAC buses to the tetra_rx/tx_chain interface.
// =============================================================================

// Adapter outputs (ADC → fabric)
wire signed [IQ_WIDTH-1:0] rx_i_adc_lvds;
wire signed [IQ_WIDTH-1:0] rx_q_adc_lvds;
wire                       rx_valid_adc_lvds;

wire signed [IQ_WIDTH-1:0] tx_i_lvds;
wire signed [IQ_WIDTH-1:0] tx_q_lvds;
wire                       tx_valid_lvds;

tetra_ad9361_axis_adapter #(
    .IQ_WIDTH(IQ_WIDTH)
) u_ad9361_adapter (
    // axi_ad9361 DATA_CLK — single clock for ADC + DAC (IP port: l_clk)
    .l_clk               (l_clk),
    // axi_ad9361 ADC fabric interface — all channel 0 I/Q signals per ADI spec
    .adc_valid_i0        (adc_valid_i0),
    .adc_data_i0         (adc_data_i0),
    .adc_enable_i0       (adc_enable_i0),
    .adc_valid_q0        (adc_valid_q0),
    .adc_data_q0         (adc_data_q0),
    .adc_enable_q0       (adc_enable_q0),
    // axi_ad9361 DAC fabric interface — all channel 0 I/Q signals per ADI spec
    .dac_valid_i0        (dac_valid_i0),
    .dac_enable_i0       (dac_enable_i0),
    .dac_valid_q0        (dac_valid_q0),
    .dac_enable_q0       (dac_enable_q0),
    .dac_data_i0         (dac_data_i0),
    .dac_data_q0         (dac_data_q0),
    // Reset (l_clk domain)
    .rst_n_lvds          (rst_n_lvds),
    // tetra_rx_chain interface
    .clk_lvds            (clk_lvds),           // l_clk passthrough → tetra_clk_reset
    .rx_i_lvds           (rx_i_adc_lvds),
    .rx_q_lvds           (rx_q_adc_lvds),
    .rx_valid_lvds       (rx_valid_adc_lvds),
    // tetra_tx_chain interface
    .tx_i_lvds           (tx_i_lvds),
    .tx_q_lvds           (tx_q_lvds),
    .tx_valid_lvds       (tx_valid_lvds)
);

// Loopback mux: CTRL[2]=1 feeds TX directly into RX (digital loopback, no RF path needed).
// ctrl_loopback_en_axi is clk_sys; used combinatorially in clk_lvds — acceptable for static ctrl.
wire signed [IQ_WIDTH-1:0] rx_i_lvds;
wire signed [IQ_WIDTH-1:0] rx_q_lvds;
wire                       rx_valid_lvds;

assign rx_i_lvds     = ctrl_loopback_en_axi ? tx_i_lvds     : rx_i_adc_lvds;
assign rx_q_lvds     = ctrl_loopback_en_axi ? tx_q_lvds     : rx_q_adc_lvds;
assign rx_valid_lvds = ctrl_loopback_en_axi ? tx_valid_lvds : rx_valid_adc_lvds;

// adc_dovf / dac_dunf: overflow/underflow flags to axi_ad9361 IP.
// Our design cannot detect these at the adapter level — tie to zero.
assign adc_dovf = 1'b0;
assign dac_dunf = 1'b0;

// adc_r1_mode / dac_r1_mode: informational flags from IP (1R1T mode).
// Not used in current RTL — mark unused to suppress synthesis warnings.
// synthesis translate_off
wire _unused_r1 = adc_r1_mode | dac_r1_mode;
// synthesis translate_on

// =============================================================================
// RX Chain — CIC+RRC+DEMOD+SYNC+BURST_DEMUX+FRAME_COUNTER
// =============================================================================

wire [BLOCK_BITS-1:0] rx_block1_sys;
wire [BLOCK_BITS-1:0] rx_block2_sys;
wire [BB_BITS-1:0]    rx_bb_sys;
wire                  rx_slot_valid_sys;
wire [1:0]            rx_slot_num_sys;
wire [1:0]            rx_burst_type_sys;

wire [1:0]   timeslot_num_sys;
wire [4:0]   frame_num_sys;
wire [5:0]   multiframe_num_sys;
wire [15:0]  hyperframe_num_sys;
wire         is_control_frame_sys;
wire         frame_18_slot1_sys;

wire         sync_locked_sys;
wire         sync_found_sys;
wire [7:0]   slot_position_sys;
wire signed  [15:0] phase_error_sys;

// RX chain debug signals
wire dbg_fe_valid_sys;
wire dbg_tr_valid_sys;
wire dbg_demod_valid_sys;

tetra_rx_chain #(
    .IQ_WIDTH   (IQ_WIDTH),
    .BLOCK_BITS (BLOCK_BITS),
    .BB_BITS    (BB_BITS),
    .CORR_WIDTH (CORR_WIDTH)
) u_rx_chain (
    .clk_lvds           (clk_lvds),
    .rst_n_lvds         (rst_n_lvds),
    .rx_i_lvds          (rx_i_lvds),
    .rx_q_lvds          (rx_q_lvds),
    .rx_valid_lvds      (rx_valid_lvds),
    .clk_sys            (clk_sys),
    .rst_n_sys          (rst_n_sys),
    // config from AXI-Lite (clk_axi ≈ clk_sys — no CDC for single-source clock)
    .corr_threshold_sys ({16'd0, sync_thresh_axi}),   // zero-extend 8→24-bit
    .seq_select_sys     (2'd2),                        // STS — matches SB burst TX in BS mode
    .block1_out_sys     (rx_block1_sys),
    .block2_out_sys     (rx_block2_sys),
    .bb_out_sys         (rx_bb_sys),
    .slot_valid_sys     (rx_slot_valid_sys),
    .slot_num_out_sys   (rx_slot_num_sys),
    .burst_type_out_sys (rx_burst_type_sys),
    .timeslot_num_sys   (timeslot_num_sys),
    .frame_num_sys      (frame_num_sys),
    .multiframe_num_sys (multiframe_num_sys),
    .hyperframe_num_sys (hyperframe_num_sys),
    .is_control_frame_sys(is_control_frame_sys),
    .frame_18_slot1_sys (frame_18_slot1_sys),
    .sync_locked_sys    (sync_locked_sys),
    .sync_found_sys     (sync_found_sys),
    .slot_position_sys  (slot_position_sys),
    .phase_error_sys    (phase_error_sys),
  .dbg_fe_valid_sys (dbg_fe_valid_sys),
  .dbg_tr_valid_sys (dbg_tr_valid_sys),
  .dbg_demod_valid_sys (dbg_demod_valid_sys)
);

// =============================================================================
// LMAC — Lower MAC Channel Coding (RX: descramble/deinterleave/viterbi/CRC)
//         Lower MAC Channel Coding (TX: CRC/encode/interleave/scramble)
// =============================================================================

wire        lmac_decoded_bit_sys;
wire        lmac_decoded_valid_sys;
wire        lmac_block_done_sys;
wire [15:0] lmac_path_metric_sys;
wire [13:0] lmac_aach_data_sys;
wire        lmac_aach_done_sys;
wire        lmac_aach_error_sys;
wire        lmac_crc_ok_sys;
wire        lmac_crc_valid_sys;
wire        lmac_stolen_sys;

// TX path (Phase 3: idle — ARM provides pre-encoded blocks via AXI-DMA Phase 4)
wire [BLOCK_BITS-1:0] lmac_tx_block1_sys;
wire [BLOCK_BITS-1:0] lmac_tx_block2_sys;
wire [BB_BITS-1:0]    lmac_tx_bb_sys;
wire                  lmac_tx_block_ready_sys;

// LFSR init: {TN[1:0], MNC[13:0], MCC[9:0], CC[5:0]} per ETSI §8.2.5
// colour_code_axi[5:0] = CC; MNC/MCC = 0 for initial testing
wire [31:0] lfsr_init_sys;
assign lfsr_init_sys = {2'd0, 14'd0, 10'd0, colour_code_axi};

tetra_lmac #(
    .BLOCK_BITS(BLOCK_BITS),
    .LFSR_WIDTH(32)
) u_lmac (
    .clk_sys              (clk_sys),
    .rst_n_sys            (rst_n_sys),
    // RX input from burst_demux (slot 0 only in Phase 3)
    .rx_block1_sys        (rx_block1_sys),
    .rx_block2_sys        (rx_block2_sys),
    .rx_bb_sys            (rx_bb_sys),
    .rx_slot_valid_sys    (rx_slot_valid_sys),
    .lfsr_init_sys        (lfsr_init_sys),
    .load_lfsr_sys        (rx_slot_valid_sys),   // re-init LFSR each burst
    .punct_pattern_sys    (3'd0),                // Rate 1/3 (full rate)
    // RX decoded output
    .rx_decoded_bit_sys   (lmac_decoded_bit_sys),
    .rx_decoded_valid_sys (lmac_decoded_valid_sys),
    .rx_block_done_sys    (lmac_block_done_sys),
    .rx_path_metric_sys   (lmac_path_metric_sys),
    .rx_aach_data_sys     (lmac_aach_data_sys),
    .rx_aach_done_sys     (lmac_aach_done_sys),
    .rx_aach_error_sys    (lmac_aach_error_sys),
    .rx_crc_ok_sys        (lmac_crc_ok_sys),
    .rx_crc_valid_sys     (lmac_crc_valid_sys),
    .rx_stolen_sys        (lmac_stolen_sys),
    // TX input (Phase 3: placeholder — DMA path not yet implemented)
    .tx_data_in_sys       (1'b0),
    .tx_data_valid_sys    (1'b0),
    .tx_flush_sys         (1'b0),
    .tx_aach_in_sys       (14'd0),
    .tx_aach_valid_sys    (1'b0),
    // TX output
    .tx_block1_sys        (lmac_tx_block1_sys),
    .tx_block2_sys        (lmac_tx_block2_sys),
    .tx_bb_sys            (lmac_tx_bb_sys),
    .tx_block_ready_sys   (lmac_tx_block_ready_sys)
);

// =============================================================================
// RX Bit Accumulator — serial Viterbi output → parallel DMA block
//
// Accumulates BLOCK_BITS decoded bits into a flat register, then asserts
// mac_valid_sys to the DMA bridge when lmac_block_done_sys fires.
//
// Pipeline:
//   lmac_decoded_valid_sys → shift acc_reg_sys left, insert bit at [0]
//   lmac_block_done_sys → latch acc_reg → mac_valid_sys pulse
//
// Note: Viterbi outputs bit_0 FIRST (LSB-first). DMA bridge expects payload
// packed as received (DMA word 0 bit 0 = first decoded bit).
// =============================================================================

// R1: accumulation shift register (BLOCK_BITS bits, R3: flat register)
reg  [BLOCK_BITS-1:0] acc_reg_sys;
reg  [BLOCK_BITS-1:0] acc_latch_sys;   // stable latched copy for DMA bridge
reg                   mac_valid_r_sys; // 1-cycle pulse for DMA bridge

// R1: acc_reg — shift left, insert new bit at LSB
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        acc_reg_sys <= {BLOCK_BITS{1'b0}};
    else if (lmac_decoded_valid_sys)
        acc_reg_sys <= {acc_reg_sys[BLOCK_BITS-2:0], lmac_decoded_bit_sys};
end

// R1: acc_latch — capture accumulated block when viterbi reports block_done
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        acc_latch_sys <= {BLOCK_BITS{1'b0}};
    else if (lmac_block_done_sys)
        acc_latch_sys <= acc_reg_sys;
end

// R1: mac_valid_r_sys — 1-cycle pulse on block_done (same cycle as latch)
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        mac_valid_r_sys <= 1'b0;
    else
        mac_valid_r_sys <= lmac_block_done_sys;
end

// =============================================================================
// AXI-DMA Bridge — packs MAC blocks into AXI4-Stream for PS DMA
// =============================================================================

wire [15:0] dma_block_count_sys;
wire        irq_mac_block_sys;
wire        dma_fifo_empty_sys;
wire        dma_fifo_full_sys;

// CRC error and sync-lost counters (Phase 3: simple 16-bit saturating counters)
reg  [15:0] crc_err_cnt_sys;
reg  [15:0] sync_lost_cnt_sys;

// R1: crc_err_cnt_sys — increments when CRC fails
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        crc_err_cnt_sys <= 16'd0;
    else if (ctrl_reset_counters_axi)
        crc_err_cnt_sys <= 16'd0;
    else if (lmac_crc_valid_sys && !lmac_crc_ok_sys && !(&crc_err_cnt_sys))
        crc_err_cnt_sys <= crc_err_cnt_sys + 16'd1;
end

// R1: sync_lost_cnt_sys — increments on sync_locked falling edge
// 2-FF edge detector for sync_locked falling
reg sync_locked_d1_sys;
reg sync_locked_d2_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sync_locked_d1_sys <= 1'b0;
    else             sync_locked_d1_sys <= sync_locked_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) sync_locked_d2_sys <= 1'b0;
    else             sync_locked_d2_sys <= sync_locked_d1_sys;
end

wire sync_lost_pulse_sys = sync_locked_d2_sys & ~sync_locked_d1_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys)
        sync_lost_cnt_sys <= 16'd0;
    else if (ctrl_reset_counters_axi)
        sync_lost_cnt_sys <= 16'd0;
    else if (sync_lost_pulse_sys && !(&sync_lost_cnt_sys))
        sync_lost_cnt_sys <= sync_lost_cnt_sys + 16'd1;
end

tetra_axi_dma_bridge #(
    .MAX_BLOCK_BITS(432),
    .MAX_DATA_WORDS(14)
) u_dma_bridge (
    .clk_sys             (clk_sys),
    .rst_n_sys           (rst_n_sys),
    // MAC block input (from accumulator)
    .mac_data_sys        ({{(432-BLOCK_BITS){1'b0}}, acc_latch_sys}),
    .mac_len_sys         (10'd216),
    .mac_slot_sys        (rx_slot_num_sys),
    .mac_burst_type_sys  (rx_burst_type_sys),
    .mac_frame_sys       ({11'd0, frame_num_sys}),
    .mac_valid_sys       (mac_valid_r_sys),
    .mac_ready_sys       (),
    // AXI4-Stream master
    .m_axis_tvalid       (m_axis_tvalid),
    .m_axis_tready       (m_axis_tready),
    .m_axis_tdata        (m_axis_tdata),
    .m_axis_tkeep        (m_axis_tkeep),
    .m_axis_tlast        (m_axis_tlast),
    // Status
    .dma_block_count_sys (dma_block_count_sys),
    .irq_mac_block_sys   (irq_mac_block_sys),
    .fifo_empty_sys      (dma_fifo_empty_sys),
    .fifo_full_sys       (dma_fifo_full_sys),
    .reset_counters_sys  (ctrl_reset_counters_axi)
);

// =============================================================================
// TX Chain — burst assembly → π/4-DQPSK → RRC → CIC → AD9361
// Phase 4: Free-running TX timer + SB burst support for base station operation
// =============================================================================

// TX Self-Timer: generates slot pulses independently of RX
// 100 MHz / 18,000 sym/s × 255 sym/slot = 1,416,667 cycles per timeslot
localparam TX_SLOT_CYCLES = 21'd1_416_667;

reg [20:0] tx_timer_sys;
reg [1:0] tx_slot_cnt_sys;
reg tx_slot_pulse_free_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 tx_timer_sys <= 21'd0;
 tx_slot_cnt_sys <= 2'd0;
 tx_slot_pulse_free_sys <= 1'b0;
 end else if (tx_timer_sys == TX_SLOT_CYCLES - 21'd1) begin
 tx_timer_sys <= 21'd0;
 tx_slot_cnt_sys <= tx_slot_cnt_sys + 2'd1; // Wraps 0→1→2→3→0...
 tx_slot_pulse_free_sys <= 1'b1;
 end else begin
 tx_timer_sys <= tx_timer_sys + 21'd1;
 tx_slot_pulse_free_sys <= 1'b0;
 end
end

// Use free-running timer for TX (BUG-01 fix)
wire tx_slot_pulse_sys_w;
assign tx_slot_pulse_sys_w = tx_slot_pulse_free_sys;

// SB data for base station operation (minimal: colour_code + zeros)
// TODO: Wire to AXI-Lite registers or LMAC when available
wire [239:0] sb_bkn1_data_sys; // BSCH: 120 symbols = 240 bits
wire [215:0] sb_bkn2_data_sys; // BNCH: 108 symbols = 216 bits
wire [27:0] sb_bb_data_sys; // BB: 14 symbols = 28 bits

// Minimal SB content: colour_code in upper bits, rest zeros
assign sb_bkn1_data_sys = {colour_code_axi, 234'b0}; // BSCH with colour_code
assign sb_bkn2_data_sys = 216'b0; // BNCH empty for now
assign sb_bb_data_sys = 28'b0; // BB empty for now

// Burst type per slot: Loopback test — all slots SB so sync_fires arrive
// every 255 symbols (SLOT_SYMS=255 in sync_detect).
// For production BS: set Slot 0 SB (01), Slots 1-3 Idle (10) and
// widen spacing_cnt to 11-bit with SLOT_SYMS=1020 in tetra_sync_detect.
wire [7:0] slot_burst_type_sys; // 2 bits per slot: 0=NDB, 1=SB, 2=Idle
assign slot_burst_type_sys = 8'b01010101; // All slots: SB (01) — loopback test

tetra_tx_chain #(
        .IQ_WIDTH (IQ_WIDTH),
        .BLOCK_BITS(BLOCK_BITS),
        .BB_BITS (BB_BITS),
        .BKN1_SB_BITS(240),
        .BB_SB_BITS (28)
    ) u_tx_chain (
        .clk_sys (clk_sys),
        .rst_n_sys (rst_n_sys),
        // Slot payload buses (NDB) — zeros for now
        .block1_sys ({(4*BLOCK_BITS){1'b0}}),
        .block2_sys ({(4*BLOCK_BITS){1'b0}}),
        .bb_sys ({(4*BB_BITS){1'b0}}),
        // SB payload — used for slot 0 (base station sync burst)
        .sb_bkn1_data_sys (sb_bkn1_data_sys),
        .sb_bkn2_data_sys (sb_bkn2_data_sys),
        .sb_bb_data_sys (sb_bb_data_sys),
        // Per-slot configuration
        .slot_en_sys (4'b1111), // All slots enabled for loopback test
        .slot_burst_type_sys(slot_burst_type_sys),
        // TX timing from free-running timer (BUG-01 fix)
        .tx_slot_num_sys (tx_slot_cnt_sys),
        .tx_slot_pulse_sys(tx_slot_pulse_sys_w),
        // clk_lvds domain
        .clk_lvds (clk_lvds),
        .rst_n_lvds (rst_n_lvds),
        // TX IQ output to AD9361
        .tx_i_lvds (tx_i_lvds),
        .tx_q_lvds (tx_q_lvds),
        .tx_valid_lvds (tx_valid_lvds),
        // Status
        .tx_busy_sys ()
    );

// =============================================================================
// 2-FF synchronizers: clk_sys → s_axi_aclk domain
// (Phase 3 simplification: clk_sys and s_axi_aclk assumed same source)
// CDC documented in docs/timing_analysis.md
// =============================================================================

// Sync locked — single bit
(* ASYNC_REG = "TRUE" *) reg sync_locked_axi_r0;
(* ASYNC_REG = "TRUE" *) reg sync_locked_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) sync_locked_axi_r0 <= 1'b0;
    else             sync_locked_axi_r0 <= sync_locked_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) sync_locked_axi_r1 <= 1'b0;
    else             sync_locked_axi_r1 <= sync_locked_axi_r0;
end

// frame_num — 5-bit Gray-coded for safe CDC
// (Frame counter increments slowly relative to AXI clock — Gray encoding
//  ensures ≤1 bit flip per transition, making 2-FF sync safe.)
// R3: unrolled Gray encoder for 5-bit counter
wire [4:0] frame_num_gray_sys;
assign frame_num_gray_sys[4] = frame_num_sys[4];
assign frame_num_gray_sys[3] = frame_num_sys[4] ^ frame_num_sys[3];
assign frame_num_gray_sys[2] = frame_num_sys[3] ^ frame_num_sys[2];
assign frame_num_gray_sys[1] = frame_num_sys[2] ^ frame_num_sys[1];
assign frame_num_gray_sys[0] = frame_num_sys[1] ^ frame_num_sys[0];

(* ASYNC_REG = "TRUE" *) reg [4:0] frame_num_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [4:0] frame_num_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) frame_num_axi_r0 <= 5'd0;
    else             frame_num_axi_r0 <= frame_num_gray_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) frame_num_axi_r1 <= 5'd0;
    else             frame_num_axi_r1 <= frame_num_axi_r0;
end

// Gray → binary decode for AXI register readback
wire [4:0] frame_num_axi;
assign frame_num_axi[4] = frame_num_axi_r1[4];
assign frame_num_axi[3] = frame_num_axi_r1[4] ^ frame_num_axi_r1[3];
assign frame_num_axi[2] = frame_num_axi[3]    ^ frame_num_axi_r1[2];
assign frame_num_axi[1] = frame_num_axi[2]    ^ frame_num_axi_r1[1];
assign frame_num_axi[0] = frame_num_axi[1]    ^ frame_num_axi_r1[0];

// slot_num — 2-bit, Gray coded
wire [1:0] slot_num_gray_sys;
assign slot_num_gray_sys[1] = timeslot_num_sys[1];
assign slot_num_gray_sys[0] = timeslot_num_sys[1] ^ timeslot_num_sys[0];

(* ASYNC_REG = "TRUE" *) reg [1:0] slot_num_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] slot_num_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) slot_num_axi_r0 <= 2'd0;
    else             slot_num_axi_r0 <= slot_num_gray_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) slot_num_axi_r1 <= 2'd0;
    else             slot_num_axi_r1 <= slot_num_axi_r0;
end

wire [1:0] slot_num_axi;
assign slot_num_axi[1] = slot_num_axi_r1[1];
assign slot_num_axi[0] = slot_num_axi_r1[1] ^ slot_num_axi_r1[0];

// IRQ pulse synchronizers — toggle-based (sys → axi)
// irq_mac_block_sys pulse in clk_sys → toggle register → 2-FF → edge detect
reg  irq_mac_tgl_sys;
(* ASYNC_REG = "TRUE" *) reg irq_mac_tgl_axi_r0;
(* ASYNC_REG = "TRUE" *) reg irq_mac_tgl_axi_r1;
reg  irq_mac_tgl_axi_r2;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) irq_mac_tgl_sys <= 1'b0;
    else if (irq_mac_block_sys) irq_mac_tgl_sys <= ~irq_mac_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_mac_tgl_axi_r0 <= 1'b0;
    else             irq_mac_tgl_axi_r0 <= irq_mac_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_mac_tgl_axi_r1 <= 1'b0;
    else             irq_mac_tgl_axi_r1 <= irq_mac_tgl_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_mac_tgl_axi_r2 <= 1'b0;
    else             irq_mac_tgl_axi_r2 <= irq_mac_tgl_axi_r1;
end

wire irq_mac_block_axi = irq_mac_tgl_axi_r1 ^ irq_mac_tgl_axi_r2;  // re-pulsed

// sync_acquired: rising edge of sync_locked (axi domain, already synchronized)
wire irq_sync_acquired_axi;
reg  sync_locked_prev_axi;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) sync_locked_prev_axi <= 1'b0;
    else             sync_locked_prev_axi <= sync_locked_axi_r1;
end
assign irq_sync_acquired_axi = sync_locked_axi_r1 & ~sync_locked_prev_axi;

// sync_lost: falling edge of sync_locked (axi domain)
wire irq_sync_lost_axi = ~sync_locked_axi_r1 & sync_locked_prev_axi;

// CRC error IRQ — toggle sync from sys
reg  irq_crc_tgl_sys;
(* ASYNC_REG = "TRUE" *) reg irq_crc_tgl_axi_r0;
(* ASYNC_REG = "TRUE" *) reg irq_crc_tgl_axi_r1;
reg  irq_crc_tgl_axi_r2;

always @(posedge clk_sys or negedge rst_n_sys) begin
    if (!rst_n_sys) irq_crc_tgl_sys <= 1'b0;
    else if (lmac_crc_valid_sys && !lmac_crc_ok_sys) irq_crc_tgl_sys <= ~irq_crc_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_crc_tgl_axi_r0 <= 1'b0;
    else             irq_crc_tgl_axi_r0 <= irq_crc_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_crc_tgl_axi_r1 <= 1'b0;
    else             irq_crc_tgl_axi_r1 <= irq_crc_tgl_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) irq_crc_tgl_axi_r2 <= 1'b0;
    else             irq_crc_tgl_axi_r2 <= irq_crc_tgl_axi_r1;
end

wire irq_crc_error_axi = irq_crc_tgl_axi_r1 ^ irq_crc_tgl_axi_r2;

// DMA FIFO full IRQ — direct sync (slow signal)
(* ASYNC_REG = "TRUE" *) reg fifo_full_axi_r0;
(* ASYNC_REG = "TRUE" *) reg fifo_full_axi_r1;
(* ASYNC_REG = "TRUE" *) reg fifo_full_prev_axi;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) fifo_full_axi_r0 <= 1'b0;
    else             fifo_full_axi_r0 <= dma_fifo_full_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) fifo_full_axi_r1 <= 1'b0;
    else             fifo_full_axi_r1 <= fifo_full_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) fifo_full_prev_axi <= 1'b0;
    else             fifo_full_prev_axi <= fifo_full_axi_r1;
end

wire irq_rx_fifo_full_axi = fifo_full_axi_r1 & ~fifo_full_prev_axi;  // rising edge

// counter synchronization (16-bit, slow — gray code or snapshot capture)
// Phase 3 simplification: clk_sys ≈ s_axi_aclk; direct connection with
// ASYNC_REG FF chain is sufficient for counters that change < 1x per 100 cycles.
(* ASYNC_REG = "TRUE" *) reg [15:0] dma_blk_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] dma_blk_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) dma_blk_cnt_axi_r0 <= 16'd0;
    else             dma_blk_cnt_axi_r0 <= dma_block_count_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) dma_blk_cnt_axi_r1 <= 16'd0;
    else             dma_blk_cnt_axi_r1 <= dma_blk_cnt_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [15:0] crc_err_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] crc_err_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) crc_err_cnt_axi_r0 <= 16'd0;
    else             crc_err_cnt_axi_r0 <= crc_err_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) crc_err_cnt_axi_r1 <= 16'd0;
    else             crc_err_cnt_axi_r1 <= crc_err_cnt_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [15:0] sync_lost_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] sync_lost_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) sync_lost_cnt_axi_r0 <= 16'd0;
    else             sync_lost_cnt_axi_r0 <= sync_lost_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
    if (!rst_n_axi) sync_lost_cnt_axi_r1 <= 16'd0;
    else             sync_lost_cnt_axi_r1 <= sync_lost_cnt_axi_r0;
end

// =============================================================================
// AXI4-Lite Register Bank
// =============================================================================

tetra_axi_lite_regs u_axi_regs (
    // AXI bus
    .s_axi_aclk              (s_axi_aclk),
    .s_axi_aresetn           (s_axi_aresetn),
    .s_axi_awaddr            (s_axi_awaddr),
    .s_axi_awprot            (s_axi_awprot),
    .s_axi_awvalid           (s_axi_awvalid),
    .s_axi_awready           (s_axi_awready),
    .s_axi_wdata             (s_axi_wdata),
    .s_axi_wstrb             (s_axi_wstrb),
    .s_axi_wvalid            (s_axi_wvalid),
    .s_axi_wready            (s_axi_wready),
    .s_axi_bresp             (s_axi_bresp),
    .s_axi_bvalid            (s_axi_bvalid),
    .s_axi_bready            (s_axi_bready),
    .s_axi_araddr            (s_axi_araddr),
    .s_axi_arprot            (s_axi_arprot),
    .s_axi_arvalid           (s_axi_arvalid),
    .s_axi_arready           (s_axi_arready),
    .s_axi_rdata             (s_axi_rdata),
    .s_axi_rresp             (s_axi_rresp),
    .s_axi_rvalid            (s_axi_rvalid),
    .s_axi_rready            (s_axi_rready),
    // Status inputs (axi domain)
    .sync_locked_axi         (sync_locked_axi_r1),
    .pll_locked_axi          (1'b1),       // Phase 3: assume PLL locked
    .rx_fifo_empty_axi       (dma_fifo_empty_sys),
    .rx_fifo_full_axi        (fifo_full_axi_r1),
    .slot_status_axi         ({lmac_stolen_sys, 3'd0}),  // slot 0 steal flag
    .frame_num_axi           (frame_num_axi),
    .slot_num_axi            (slot_num_axi),
    // IRQ inputs (axi domain)
    .irq_mac_block_axi       (irq_mac_block_axi),
    .irq_sync_acquired_axi   (irq_sync_acquired_axi),
    .irq_sync_lost_axi       (irq_sync_lost_axi),
    .irq_crc_error_axi       (irq_crc_error_axi),
    .irq_rx_fifo_full_axi    (irq_rx_fifo_full_axi),
    // Counter inputs (axi domain)
    .dma_block_count_axi     (dma_blk_cnt_axi_r1),
    .crc_error_count_axi     (crc_err_cnt_axi_r1),
    .sync_lost_count_axi     (sync_lost_cnt_axi_r1),
    // Control outputs (axi domain → PHY)
    .ctrl_rx_enable_axi      (ctrl_rx_enable_axi),
    .ctrl_tx_enable_axi      (ctrl_tx_enable_axi),
    .ctrl_loopback_en_axi    (ctrl_loopback_en_axi),
    .ctrl_reset_counters_axi (ctrl_reset_counters_axi),
    .sync_thresh_axi         (sync_thresh_axi),
    .colour_code_axi         (colour_code_axi),
    .rx_gain_axi             (rx_gain_axi),
    .tx_att_axi              (tx_att_axi),
    .irq_enable_axi          (),
    .irq_out_axi             (o_irq)
);

// =============================================================================
// ILA Debug Probes — Hardware first-light verification (Phase 4)
//
// Registered probes with mark_debug="true".  Using registers (not wire aliases)
// ensures the probe nets survive synthesis flattening and opt_design.
//
// Clock domains:
//   dbg_*_lvds → l_clk  (AD9361 DATA_CLK, up to 250 MHz)
//   dbg_*_sys  → clk_sys (PL fabric, 100 MHz)
//
// Two ILA cores will be created automatically by implement_debug_core:
//   ila (l_clk):   depth 4096 — confirms AD9361 IQ delivery + adapter
//   ila (clk_sys): depth 4096 — confirms TETRA sync, DMA, IRQ
//
// Probe file written to: build/tetra_zynq_phy.ltx
// Use Vivado Hardware Manager to load .bit + .ltx for on-chip debug.
// =============================================================================

// l_clk domain probes — one always per register per coding convention R1
(* mark_debug = "true", keep = "true" *) reg dbg_adc_valid_i0_lvds;
(* mark_debug = "true", keep = "true" *) reg dbg_rx_valid_lvds;

always @(posedge l_clk) begin
    dbg_adc_valid_i0_lvds <= adc_valid_i0;
end
always @(posedge l_clk) begin
    dbg_rx_valid_lvds <= rx_valid_lvds;
end

// clk_sys domain probes
(* mark_debug = "true", keep = "true" *) reg dbg_sync_locked_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_sync_found_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_m_axis_tvalid_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_m_axis_tready_sys;

// RX datapath debug probes (clk_sys domain)
(* mark_debug = "true", keep = "true" *) reg dbg_fe_valid_ila_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_tr_valid_ila_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_demod_valid_ila_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_o_irq_sys;

// TX debug probes (clk_sys domain)
// tx_valid_lvds is in clk_lvds (~9.216 MHz); 2-FF CDC to clk_sys for debug only.
(* mark_debug = "true", keep = "true" *) reg dbg_tx_valid_r0_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_tx_valid_r1_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_tx_slot_pulse_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_loopback_en_sys;

always @(posedge clk_sys) begin
    dbg_sync_locked_sys <= sync_locked_sys;
end
always @(posedge clk_sys) begin
    dbg_sync_found_sys <= sync_found_sys;
end
always @(posedge clk_sys) begin
    dbg_m_axis_tvalid_sys <= m_axis_tvalid;
end
always @(posedge clk_sys) begin
    dbg_m_axis_tready_sys <= m_axis_tready;
end
always @(posedge clk_sys) begin
    dbg_o_irq_sys <= o_irq;
end
// TX activity: 2-FF CDC from clk_lvds (debug-only, no functional use)
always @(posedge clk_sys) begin
    dbg_tx_valid_r0_sys <= tx_valid_lvds;
end
always @(posedge clk_sys) begin
    dbg_tx_valid_r1_sys <= dbg_tx_valid_r0_sys;
end
always @(posedge clk_sys) begin
    dbg_tx_slot_pulse_sys <= tx_slot_pulse_free_sys;
end
always @(posedge clk_sys) begin
    dbg_loopback_en_sys <= ctrl_loopback_en_axi;
end

// RX datapath probes
always @(posedge clk_sys) begin
  dbg_fe_valid_ila_sys <= dbg_fe_valid_sys;
end
always @(posedge clk_sys) begin
  dbg_tr_valid_ila_sys <= dbg_tr_valid_sys;
end
always @(posedge clk_sys) begin
  dbg_demod_valid_ila_sys <= dbg_demod_valid_sys;
end

endmodule
`default_nettype wire
