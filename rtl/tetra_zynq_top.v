// =============================================================================
// Module: tetra_zynq_top
// Project: tetra-zynq-phy
// File: rtl/tetra_zynq_top.v
//
// Description:
// Top-Level Design — TETRA PHY/LMAC Baseband Engine for LibreSDR
// (Zynq-7020 XC7Z020-CLG484 + AD9361 RF Transceiver)
//
// Instantiates and connects all sub-modules:
// tetra_clk_reset — Reset synchronizer (4 clock domains)
// tetra_ad9361_axis_adapter — ADI axi_ad9361 IP fabric ↔ tetra IQ interface
// tetra_rx_chain — RX datapath (frontend → demod → sync → TDMA)
// tetra_lmac — Lower MAC (scrambler/interleaver/viterbi/CRC)
// tetra_tx_chain — TX datapath (burst_mux → builder → mod → CIC)
// tetra_axi_dma_bridge — S2MM DMA bridge (LMAC → AXI-DMA → PS DDR)
// tetra_axi_lite_regs — AXI4-Lite register bank (PS control/status)
//
// AD9361 LVDS I/O is handled entirely by the ADI axi_ad9361 IP in the
// Vivado Block Design. This module connects to the IP's fabric-side ADC/DAC
// data buses via tetra_ad9361_axis_adapter.
//
// Clock Domains:
// i_clk / clk_sys — 100 MHz PL fabric clock (Zynq PS FCLK_CLK0)
// clk_lvds — adc_clk from axi_ad9361 IP (DATA_CLK domain)
// s_axi_aclk — AXI bus clock (from PS, same source as i_clk)
//
// NOTE: clk_sys and s_axi_aclk are assumed to originate from the same PLL
// but are treated as independent domains. For Phase 3 single-source boards
// where both are driven from i_clk, any residual CDC risk is negligible and
// documented in docs/timing_analysis.md.
//
// RX Data Flow:
// axi_ad9361 IP → axis_adapter → rx_chain (CIC+RRC+demod+sync+demux)
// → tetra_lmac (descramble+deinterleave+viterbi+CRC+RM-decode)
// → rx_accumulator (serial→parallel, 216 bits)
// → tetra_axi_dma_bridge (AXI4-Stream S2MM → PS DDR)
//
// TX Data Flow (Phase 3 — loopback / register-file mode):
// AXI-Lite registers (slot payload) → tetra_tx_chain (burst_mux → burst_builder
// → pi4dqpsk_mod → rrc_filter → tx_frontend CIC) → AD9361 LVDS
//
// Full PS→PL TX DMA path (MM2S): Phase 4 TODO.
// For Phase 3 initial on-air tests, TX block data is zero (idle bursts)
// unless written via AXI-Lite scratch registers.
//
// AXI CDC Note:
// Status signals from clk_sys domain to s_axi_aclk domain are passed through
// 2-FF synchronizers in this top-level (sync_locked, frame/slot counters).
// IRQ pulses from clk_sys are converted to toggle-sync pairs before forwarding.
//
// Resource estimate (sum of all sub-modules, Phase 3):
// LUT: ~6000 FF: ~12000 DSP48: 4 BRAM18k: 1
// (~11% LUT, ~11% FF, ~2% DSP48, <1% BRAM18k of Zynq-7020)
//
// Coding rules: Verilog-2001 strict (R1–R10 per PROMPT.md)
// R2 exception: AXI4-Lite and AXI4-Stream port names follow Vivado naming
// convention without domain suffix.
//
// Ref: ETSI EN 300 392-2 (TETRA V+D Air Interface)
// Xilinx UG585 (Zynq-7000 TRM), Xilinx UG470 (7-Series Config)
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

`include "tetra_pdu_class.vh"

module tetra_zynq_top #(
 parameter IQ_WIDTH = 16,
 parameter BLOCK_BITS = 216,
 parameter BB_BITS = 30,
 parameter CORR_WIDTH = 24
)(
 // -------------------------------------------------------------------------
 // PL Clock & Reset (from Zynq PS)
 // -------------------------------------------------------------------------
 (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 i_clk CLK" *)
 (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET i_arst_n, FREQ_HZ 100000000" *)
 input wire i_clk, // 100 MHz FCLK_CLK0 from Zynq PS
 (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 i_arst_n RST" *)
 (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
 input wire i_arst_n, // Active-low async reset from proc_sys_reset

 // -------------------------------------------------------------------------
 // axi_ad9361 IP fabric interface — ADC/DAC data buses from/to IP
 // LVDS pins are connected directly to axi_ad9361 in the Block Design.
 // Port names and directions taken verbatim from system_axi_ad9361_0.xci
 // (libresdr/ip/system_axi_ad9361_0/system_axi_ad9361_0.xci).
 // -------------------------------------------------------------------------
 // DATA_CLK — axi_ad9361.l_clk (master clock output of IP, drives both ADC+DAC)
 input wire l_clk, // DATA_CLK from axi_ad9361 IP (l_clk port)
 // ADC — axi_ad9361 → fabric, channel 0 I (direction: out from IP)
 input wire adc_valid_i0, // I0 sample valid (one-cycle pulse)
 input wire [15:0] adc_data_i0, // I0 sample (signed 16-bit, sign-extended by IP)
 input wire adc_enable_i0, // I0 path active (DC level)
 // ADC — axi_ad9361 → fabric, channel 0 Q (direction: out from IP)
 input wire adc_valid_q0, // Q0 sample valid (parallel with adc_valid_i0)
 input wire [15:0] adc_data_q0, // Q0 sample (signed 16-bit)
 input wire adc_enable_q0, // Q0 path active
 // ADC — informational outputs from IP
 input wire adc_r1_mode, // IP flag: operating in 1R1T mode
 output wire adc_dovf, // ADC data overflow to IP (drive 1'b0)
 // DAC — axi_ad9361 → fabric, enables/valids are IP outputs
 input wire dac_valid_i0, // IP output: requests I0 DAC data each cycle
 input wire dac_enable_i0, // IP output: I0 DAC path active
 input wire dac_valid_q0, // IP output: requests Q0 DAC data each cycle
 input wire dac_enable_q0, // IP output: Q0 DAC path active
 input wire dac_r1_mode, // IP flag: operating in 1R1T mode
 // DAC — fabric → axi_ad9361, data is input to IP
 output wire [15:0] dac_data_i0, // I0 sample to DAC (signed 16-bit)
 output wire [15:0] dac_data_q0, // Q0 sample to DAC (signed 16-bit)
 output wire dac_dunf, // DAC data underflow to IP (drive 1'b0)

 // -------------------------------------------------------------------------
 // AXI4-Lite Slave Interface (from Zynq PS — GP0 port)
 // Base address: 0x4000_0000 (configured in Vivado Block Design)
 // -------------------------------------------------------------------------
 (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
 (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000" *)
 input wire s_axi_aclk,
 (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
 (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
 input wire s_axi_aresetn,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
 input wire [31:0] s_axi_awaddr,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
 input wire [2:0] s_axi_awprot, // AXI4-Lite write protection (accepted, ignored)
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
 input wire s_axi_awvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
 output wire s_axi_awready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
 input wire [31:0] s_axi_wdata,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
 input wire [3:0] s_axi_wstrb,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
 input wire s_axi_wvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
 output wire s_axi_wready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
 output wire [1:0] s_axi_bresp,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
 output wire s_axi_bvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
 input wire s_axi_bready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
 input wire [31:0] s_axi_araddr,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
 input wire [2:0] s_axi_arprot, // AXI4-Lite read protection (accepted, ignored)
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
 input wire s_axi_arvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
 output wire s_axi_arready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
 output wire [31:0] s_axi_rdata,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
 output wire [1:0] s_axi_rresp,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
 output wire s_axi_rvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
 input wire s_axi_rready,

 // -------------------------------------------------------------------------
 // AXI4-Stream Master Interface (to Xilinx AXI DMA IP — S2MM channel)
 // -------------------------------------------------------------------------
 (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
 output wire m_axis_tvalid,
 (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
 input wire m_axis_tready,
 (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
 output wire [31:0] m_axis_tdata,
 (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TKEEP" *)
 output wire [3:0] m_axis_tkeep,
 (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
 output wire m_axis_tlast,

 // -------------------------------------------------------------------------
 // IRQ output to Zynq PS GIC (active-high)
 // -------------------------------------------------------------------------
 output wire o_irq
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
.arst_n (i_arst_n),
.clk_sys (clk_sys),
.clk_sample (clk_sys), // sample domain = sys domain (strobe-based)
.clk_axi (s_axi_aclk),
.clk_lvds (clk_lvds), // driven by axi_ad9361 via axis_adapter output
.rst_n_sys (rst_n_sys),
.rst_n_sample(), // unused — same as rst_n_sys
.rst_n_axi (rst_n_axi),
.rst_n_lvds (rst_n_lvds)
);

// =============================================================================
// AXI-Lite control register outputs (clk_axi domain)
// =============================================================================

wire ctrl_rx_enable_axi;
wire ctrl_tx_enable_axi;
wire ctrl_loopback_en_axi;
wire ctrl_reset_counters_axi;
wire [7:0] sync_thresh_axi;
wire [5:0] colour_code_axi;
wire [6:0] rx_gain_axi;
wire [7:0] tx_att_axi;
wire tx_test_prbs_en_axi;

// Cell-Config Registers (Plan Stufe 3.5) — feed tetra_sb1_encoder (BSCH).
// Slow-changing; written once at MCU boot. Per-field 2-FF resynced into
// clk_sys below (see cell_cfg_*_sys_r1 signals).
wire [3:0] cell_cfg_sys_code_axi_w;
wire [1:0] cell_cfg_sharing_mode_axi_w;
wire [2:0] cell_cfg_ts_reserved_frames_axi_w;
wire cell_cfg_uplane_dtx_axi_w;
wire cell_cfg_frame18_ext_axi_w;
wire [1:0] cell_cfg_neigh_cell_bc_axi_w;
wire [1:0] cell_cfg_cell_service_level_axi_w;
wire cell_cfg_late_entry_support_axi_w;
wire [9:0] cell_cfg_mcc_axi_w;
wire [13:0] cell_cfg_mnc_axi_w;

// DL-signalling scheduler config — cfg_signal_target_tn (REG_SIGNAL_TARGET_TN
// @ 0x19C). Per-bit 2-FF resynced into clk_sys below as cfg_mcch_tn_sys_r1.
wire [1:0] cfg_signal_target_tn_axi_w;

// Cell Location Area — 14-bit R/W (REG_CELL_LA @ 0x1A0). SW writes the cell
// LA at boot (tetra_sysinfo info.la), RTL feeds it into the MLE FSM as
//.cfg_la so D-LOC-UPDATE-ACCEPT echoes the same LA that BNCH SYSINFO
// broadcasts. Per-bit 2-FF resynced into clk_sys below as cell_la_sys_r1.
wire [13:0] cell_la_axi_w;
// Phase 6 A: DB-Policy register (REG_DB_POLICY @ 0x1AC).
// Bit 0 = accept_unknown (CDC-resynced into clk_sys below).
wire [31:0] db_policy_axi_w;
wire [31:0] voice_active_mask_axi_w;
wire [63:0] slot_aach_axi_w; // 2026-05-24 Klasse 2 — 4×16-bit AACH per TN
wire [31:0] voice_nub_sync_thresh_axi_w;

// Phase E2 — UL-NUB capture outputs (rx_chain). Output is now 4-bit
// signed soft-values per coded bit (432 nibbles = 1728 bits), consumed
// by voice_nub_read_mailbox for SW soft-Viterbi.
wire [1727:0] voice_nub_coded_softs_sys_w;
wire voice_nub_coded_valid_sys_w;
wire [15:0] voice_nub_rx_cnt_sys_w;
wire [15:0] rx_iq_peak_i_sys_w;
wire [15:0] rx_iq_peak_q_sys_w;
// Phase 7 G.8 — relay_cnt deprecated; tied to 0 since voice_relay was
// removed. SW reads REG_VOICE_RELAY_CNT @ 0x264 = always 0.
wire [15:0] voice_relay_cnt_sys_w = 16'd0;
// Phase X.4 — REG_AST_TTL_MFS removed (AST migrated to SW).

// Synchronize static AXI control bits into the consuming clock domains.
(* ASYNC_REG = "TRUE" *) reg ctrl_loopback_lvds_r0;
(* ASYNC_REG = "TRUE" *) reg ctrl_loopback_lvds_r1;
(* ASYNC_REG = "TRUE" *) reg ctrl_reset_cnt_sys_r0;
(* ASYNC_REG = "TRUE" *) reg ctrl_reset_cnt_sys_r1;
(* ASYNC_REG = "TRUE" *) reg ctrl_loopback_sys_r0;
(* ASYNC_REG = "TRUE" *) reg ctrl_loopback_sys_r1;
(* ASYNC_REG = "TRUE" *) reg tx_test_prbs_sys_r0;
(* ASYNC_REG = "TRUE" *) reg tx_test_prbs_sys_r1;

wire ctrl_loopback_en_lvds = ctrl_loopback_lvds_r1;
wire ctrl_reset_counters_sys = ctrl_reset_cnt_sys_r1;
wire ctrl_loopback_en_sys = ctrl_loopback_sys_r1;
wire tx_test_prbs_en_sys = tx_test_prbs_sys_r1;

// =============================================================================
// axi_ad9361 Adapter — fabric IQ interface to/from ADI IP block
//
// The axi_ad9361 IP (in the Vivado Block Design) handles all LVDS DDR I/O,
// DDR calibration, and AD9361 SPI configuration. This adapter translates
// its fabric-side ADC/DAC buses to the tetra_rx/tx_chain interface.
// =============================================================================

// Adapter outputs (ADC → fabric)
wire signed [IQ_WIDTH-1:0] rx_i_adc_lvds;
wire signed [IQ_WIDTH-1:0] rx_q_adc_lvds;
wire rx_valid_adc_lvds;

wire signed [IQ_WIDTH-1:0] tx_i_lvds;
wire signed [IQ_WIDTH-1:0] tx_q_lvds;
wire tx_valid_lvds;

tetra_ad9361_axis_adapter #(
.IQ_WIDTH(IQ_WIDTH)
) u_ad9361_adapter (
 // axi_ad9361 DATA_CLK — single clock for ADC + DAC (IP port: l_clk)
.l_clk (l_clk),
 // axi_ad9361 ADC fabric interface — all channel 0 I/Q signals per ADI spec
.adc_valid_i0 (adc_valid_i0),
.adc_data_i0 (adc_data_i0),
.adc_enable_i0 (adc_enable_i0),
.adc_valid_q0 (adc_valid_q0),
.adc_data_q0 (adc_data_q0),
.adc_enable_q0 (adc_enable_q0),
 // axi_ad9361 DAC fabric interface — all channel 0 I/Q signals per ADI spec
.dac_valid_i0 (dac_valid_i0),
.dac_enable_i0 (dac_enable_i0),
.dac_valid_q0 (dac_valid_q0),
.dac_enable_q0 (dac_enable_q0),
.dac_data_i0 (dac_data_i0),
.dac_data_q0 (dac_data_q0),
 // Reset (l_clk domain)
.rst_n_lvds (rst_n_lvds),
 // tetra_rx_chain interface
.clk_lvds (clk_lvds), // l_clk passthrough → tetra_clk_reset
.rx_i_lvds (rx_i_adc_lvds),
.rx_q_lvds (rx_q_adc_lvds),
.rx_valid_lvds (rx_valid_adc_lvds),
 // tetra_tx_chain interface
.tx_i_lvds (tx_i_lvds),
.tx_q_lvds (tx_q_lvds),
.tx_valid_lvds (tx_valid_lvds)
);

// Loopback mux: CTRL[2]=1 feeds TX directly into RX (digital loopback, no RF path needed).
// The control bit originates in AXI and is synchronized into clk_lvds before use.
wire signed [IQ_WIDTH-1:0] rx_i_lvds;
wire signed [IQ_WIDTH-1:0] rx_q_lvds;
wire rx_valid_lvds;

assign rx_i_lvds = ctrl_loopback_en_lvds ? tx_i_lvds: rx_i_adc_lvds;
assign rx_q_lvds = ctrl_loopback_en_lvds ? tx_q_lvds: rx_q_adc_lvds;
assign rx_valid_lvds = ctrl_loopback_en_lvds ? tx_valid_lvds: rx_valid_adc_lvds;

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
wire [BB_BITS-1:0] rx_bb_sys;
wire rx_slot_valid_sys;
wire [1:0] rx_slot_num_sys;
wire [1:0] rx_burst_type_sys;

wire [1:0] timeslot_num_sys;
wire [4:0] frame_num_sys;
wire [5:0] multiframe_num_sys;
wire [15:0] hyperframe_num_sys;
wire is_control_frame_sys;
wire frame_18_slot1_sys;

wire sync_locked_sys;
wire sync_found_sys;
wire [7:0] slot_position_sys;
wire signed [15:0] phase_error_sys;
wire [CORR_WIDTH-1:0] corr_peak_sys;
wire ul_sync_found_sys;
wire [CORR_WIDTH-1:0] ul_corr_peak_sys;
wire [1:0] ul_best_phase_sys;

// UL MAC-ACCESS PDU parser outputs (clk_sys) — resynced to clk_axi below.
// Bit layout per bluestation `mac_access.rs::from_bitbuf`:
// addr_type 2 bits, address 24 bits (or 10-bit event_label).
wire ul_pdu_valid_sys;
wire [15:0] ul_pdu_count_sys;
wire ul_pdu_type_sys; // 1 bit (was 2)
wire ul_fill_bit_sys;
wire ul_encryption_mode_sys; // 1 bit (was 2)
wire [1:0] ul_addr_type_sys; // 2 bits (was 3 in ul_address_type_sys)
wire [23:0] ul_issi_sys; // 24-bit ISSI (replaces 10-bit short_ssi)
wire [9:0] ul_event_label_sys;
wire ul_optional_field_flag_sys;
wire ul_frag_flag_sys;
wire [3:0] ul_reservation_req_sys;
wire [4:0] ul_length_ind_sys;
wire [3:0] ul_mm_pdu_type_sys;
// Phase 7 F.3 — raw decoded LLC pdu_type + MLE protocol discriminator,
// fed by tetra_ul_mac_access_parser through tetra_rx_chain.
wire [3:0] ul_llc_pdu_type_sys;
wire [2:0] ul_mle_disc_sys;
wire [2:0] ul_loc_upd_type_sys;
wire [91:0] ul_raw_info_bits_sys;
// LLC BL-ACK (M4, 2026-04-24) — UL parser → MLE FSM wires
wire ul_bl_ack_valid_sys;
wire ul_bl_ack_nr_sys;
wire [15:0] ul_bl_ack_count_sys;
// Option B (commit 6) — UL parser LLC flags for MLE auto-BL-ACK trigger
wire ul_llc_is_bl_data_w;
wire ul_llc_is_bl_ack_w;
wire ul_llc_has_fcs_w;
wire ul_llc_ns_valid_w;
wire ul_llc_ns_w;
wire ul_llc_nr_valid_w;
wire ul_llc_nr_w;
wire ul_llc_is_mle_mm_w;
wire [3:0] ul_llc_mm_pdu_type_w;
wire [2:0] ul_llc_mm_loc_upd_type_w;

// Phase 7 F.1 — UL-Demand-Reassembly inputs/outputs. Parser → reassembly
// (MAC-END-HU continuation path), reassembly → MLE-FSM (Phase F.2 wiring).
wire ul_pdu_is_continuation_sys;
wire ul_continuation_valid_sys;
wire [84:0] ul_continuation_bits_sys;
wire [23:0] ul_continuation_ssi_sys;
wire [15:0] ul_continuation_count_sys;
// Phase H.6.1 — UL SCH/HU decoder diagnostic counters (clk_sys, free-running)
wire [15:0] schhu_attempted_sys;
wire [15:0] schhu_ok_sys;
wire reass_valid_sys;
wire [128:0] reass_body_sys;
wire [23:0] reass_ssi_sys;
wire [15:0] reass_cnt_sys;
wire [15:0] reass_drop_cnt_sys;
wire [1:0] reass_busy_slots_sys;

// Cell scrambler seed for UL SCH/HU decoder — comes from AXI reg,
// resynced clk_axi → clk_sys (see CDC block further down).
wire [31:0] ul_scramb_init_axi_w;
wire [31:0] ul_scramb_init_sys;

// Phase X.4 — EntityTable (formerly Subscriber-Shadow), ProfileTable and
// Active-Session Table moved to ARM SW. The AXI-Lite indirect-write
// windows in tetra_axi_lite_regs.v still emit `shadow_wr_*` /
// `profile_wr_*` / `profile_rd_idx_axi` strobes for SW backwards
// compatibility, so we keep dangling wire declarations here; they
// terminate at no consumer in PL and synth prunes them. Phase X.5
// will retire the AXI windows together with the legacy Pre-Reply path.
wire [7:0] shadow_wr_idx_w;
wire [63:0] shadow_wr_data_w;
wire shadow_wr_en_w;

wire [2:0] profile_wr_idx_w;
wire [31:0] profile_wr_data_w;
wire [2:0] profile_rd_idx_axi_sys_w;
wire [31:0] profile_rd_data_axi_sys_w = 32'd0; // tied to 0 (no live ProfileTable)
wire profile_wr_en_w;

// MLE-registration FSM → DL-signalling-queue request port. The MLE emits
// the full 432-bit SCH/F codeword as a queue-request; the scheduler
// pops one per frame and drives the per-TN signalling block bundle that
// tetra_slot_content_mux consumes for every class=SIGNALLING slot.
// See tetra_dl_signal_queue.v / tetra_dl_signal_scheduler.v.
wire mle_req_valid_w;
wire [431:0] mle_req_coded_bits_w;
wire [1:0] mle_req_pdu_type_w;
wire [1:0] mle_req_target_tn_w;
wire mle_req_second_pdu_present_w; // Option B telemetry (commit 6)
wire mle_req_second_pdu_nr_w;
wire mle_busy_w;
wire mle_accept_pulse_w;
wire mle_drop_pulse_w;
// M2+M3 observability (2026-04-24) — available for ILA/AXI later
wire mle_ack_pulse_w;
wire mle_retransmit_pulse_w;
wire mle_lost_pulse_w;
wire mle_detach_pulse_w; // Phase 6 B

// Phase X.6 — MLE-FSM build-request to shared tetra_dl_pdu_builder.
wire mle_accept_build_req_w;
wire [23:0] mle_accept_build_ssi_w;
wire [2:0] mle_accept_build_addr_type_w;
// Klasse 2 (2026-05-24) — UMt 4..63 (0=unallocated) für CMCE-PDUs.
wire [5:0] mle_accept_build_usage_marker_w;
// 2026-05-25 Multi-Group — ts_assigned-Bitmap MSB-first [TS1,TS2,TS3,TS4]
wire [3:0] mle_accept_build_chan_alloc_ts_bitmap_w;
wire [3:0] mb_chan_alloc_ts_bitmap_sys_w;
wire [3:0] mle_accept_build_llc_pdu_type_w;
wire mle_accept_build_random_access_flag_w;
wire [127:0] mle_accept_build_mm_pdu_bits_w;
wire [7:0] mle_accept_build_mm_pdu_len_bits_w;
wire [31:0] mle_accept_build_scramble_init_w;
// Phase Y.2 — LLC ns/nr from MLE-FSM raw-mode latches (mm=11 GROUP-ACK).
// mm=2 path drives 0/0 (bit-identical pre-Y.2).
wire mle_accept_build_ns_w;
wire mle_accept_build_nr_w;
wire [2:0] mle_accept_build_mle_pd_w;
wire [13:0] mle_accept_build_aach_pattern_w; // Phase 7 G.7

// Queue ↔ scheduler wiring
wire queue_head_valid_w;
wire [431:0] queue_head_coded_w;
wire [1:0] queue_head_pdu_type_w;
wire [1:0] queue_head_target_tn_w;
wire [1:0] queue_head_prio_w;
wire [13:0] queue_head_aach_pattern_w; // Phase Z.2 (Z.13: 14-bit only)
wire queue_head_second_pdu_present_w; // Option B telemetry (commit 6)
wire queue_head_second_pdu_nr_w;
wire popped_second_pdu_present_w; // latched for ILA probes
wire popped_second_pdu_nr_w;
wire sched_pop_w;
wire [3:0] queue_depth_mask_w;
wire [2:0] queue_depth_count_w;
wire [15:0] queue_drop_cnt_w;
// Per-producer drop attribution (8-bit saturating each) — exposed as
// REG_DL_QUEUE_STATS so we can see which producer ate the drops.
wire [7:0] queue_drop_cnt_mle_w;
wire [7:0] queue_drop_cnt_cmce_w;
wire [7:0] queue_drop_cnt_sds_w;
// Pre-Reply Slot-Grant + BL-ACK push/drop counters — forward-declared
// here so the clk_sys → clk_axi resync block (~line 1650) can sample
// them. Driven by the actual module instantiations further below.
wire [15:0] slotgrant_push_cnt_sys_w;
wire [15:0] slotgrant_drop_cnt_sys_w;
wire [15:0] pre_reply_blck_push_cnt_sys_w;
wire [15:0] pre_reply_blck_drop_cnt_sys_w;

// Scheduler → slot_content_mux per-TN bundle (NULL-PDU idle default
// when queue empty; target-TN gets coded PDU content when a PDU is queued).
wire [215:0] sched_blk1_tn0_sys_w;
wire [215:0] sched_blk2_tn0_sys_w;
wire [215:0] sched_blk1_tn1_sys_w;
wire [215:0] sched_blk2_tn1_sys_w;
wire [215:0] sched_blk1_tn2_sys_w;
wire [215:0] sched_blk2_tn2_sys_w;
wire [215:0] sched_blk1_tn3_sys_w;
wire [215:0] sched_blk2_tn3_sys_w;
wire [3:0] sched_ndb2_sys_w;
wire [15:0] sig_pop_cnt_w;
wire [15:0] sig_override_cnt_w;
// Phase Z.13 — Z.2/Z.12 per-TN AACH override + per-TN pre-coded AACH
// bundles deleted. AACH info now selected combinationally at the slot-
// encoder side from queue.head_aach_pattern (when head_target_tn matches
// tx_tn_next_sys), with a single shared tetra_aach_rm_encoder instance.

// RX chain debug signals
wire dbg_fe_valid_sys;
wire dbg_tr_valid_sys;
wire dbg_demod_valid_sys;

tetra_rx_chain #(
.IQ_WIDTH (IQ_WIDTH),
.BLOCK_BITS (BLOCK_BITS),
.BB_BITS (BB_BITS),
.CORR_WIDTH (CORR_WIDTH)
) u_rx_chain (
.clk_lvds (clk_lvds),
.rst_n_lvds (rst_n_lvds),
.rx_i_lvds (rx_i_lvds),
.rx_q_lvds (rx_q_lvds),
.rx_valid_lvds (rx_valid_lvds),
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // config from AXI-Lite (clk_axi ≈ clk_sys — no CDC for single-source clock)
.corr_threshold_sys ({16'd0, sync_thresh_axi}), // zero-extend 8→24-bit
.seq_select_sys (2'd2), // STS — DL SDB detection; UL uses tetra_ul_sync_detect_os4 (parallel)
.loopback_en_sys (ctrl_loopback_en_sys), // bypass CIC gain in digital loopback
.block1_out_sys (rx_block1_sys),
.block2_out_sys (rx_block2_sys),
.bb_out_sys (rx_bb_sys),
.slot_valid_sys (rx_slot_valid_sys),
.slot_num_out_sys (rx_slot_num_sys),
.burst_type_out_sys (rx_burst_type_sys),
.timeslot_num_sys (timeslot_num_sys),
.frame_num_sys (frame_num_sys),
.multiframe_num_sys (multiframe_num_sys),
.hyperframe_num_sys (hyperframe_num_sys),
.is_control_frame_sys(is_control_frame_sys),
.frame_18_slot1_sys (frame_18_slot1_sys),
.sync_locked_sys (sync_locked_sys),
.sync_found_sys (sync_found_sys),
.slot_position_sys (slot_position_sys),
.phase_error_sys (phase_error_sys),
.corr_peak_sys (corr_peak_sys),
 // UL oversampled sync detector
.ul_reset_peak_sys (ctrl_reset_counters_sys),
.ul_sync_found_sys (ul_sync_found_sys),
.ul_corr_peak_sys (ul_corr_peak_sys),
.ul_best_phase_sys (ul_best_phase_sys),
 // UL RA-burst decoder pipeline (Task #37)
.ul_scramb_init_sys (ul_scramb_init_sys),
.ul_pdu_valid_sys (ul_pdu_valid_sys),
.ul_pdu_count_sys (ul_pdu_count_sys),
.ul_pdu_type_sys (ul_pdu_type_sys),
.ul_fill_bit_sys (ul_fill_bit_sys),
.ul_encryption_mode_sys (ul_encryption_mode_sys),
.ul_addr_type_sys (ul_addr_type_sys),
.ul_issi_sys (ul_issi_sys),
.ul_event_label_sys (ul_event_label_sys),
.ul_optional_field_flag_sys (ul_optional_field_flag_sys),
.ul_frag_flag_sys (ul_frag_flag_sys),
.ul_reservation_req_sys (ul_reservation_req_sys),
.ul_length_ind_sys (ul_length_ind_sys),
.ul_mm_pdu_type_sys (ul_mm_pdu_type_sys),
.ul_loc_upd_type_sys (ul_loc_upd_type_sys),
.ul_raw_info_bits_sys (ul_raw_info_bits_sys),
 // LLC BL-ACK detection (M1+M4, 2026-04-24)
.ul_bl_ack_valid_sys (ul_bl_ack_valid_sys),
.ul_bl_ack_nr_sys (ul_bl_ack_nr_sys),
.ul_bl_ack_count_sys (ul_bl_ack_count_sys),
.ul_llc_is_bl_data_sys (ul_llc_is_bl_data_w),
.ul_llc_is_bl_ack_sys (ul_llc_is_bl_ack_w),
.ul_llc_has_fcs_sys (ul_llc_has_fcs_w),
.ul_llc_ns_valid_sys (ul_llc_ns_valid_w),
.ul_llc_ns_sys (ul_llc_ns_w),
.ul_llc_nr_valid_sys (ul_llc_nr_valid_w),
.ul_llc_nr_sys (ul_llc_nr_w),
.ul_llc_is_mle_mm_sys (ul_llc_is_mle_mm_w),
.ul_llc_mm_pdu_type_sys (ul_llc_mm_pdu_type_w),
.ul_llc_mm_loc_upd_type_sys (ul_llc_mm_loc_upd_type_w),
 // Phase 7 F.3 — raw LLC/MLE-disc fields for AXI mailbox + ul_mon
.ul_llc_pdu_type_sys (ul_llc_pdu_type_sys),
.ul_mle_disc_sys (ul_mle_disc_sys),
 // Phase 7 F.1 — MAC-END-HU continuation path → reassembly module
.ul_pdu_is_continuation_sys (ul_pdu_is_continuation_sys),
.ul_continuation_valid_sys (ul_continuation_valid_sys),
.ul_continuation_bits_sys (ul_continuation_bits_sys),
.ul_continuation_ssi_sys (ul_continuation_ssi_sys),
.ul_continuation_count_sys (ul_continuation_count_sys),
.schhu_attempted_sys (schhu_attempted_sys),
.schhu_ok_sys (schhu_ok_sys),
.dbg_fe_valid_sys (dbg_fe_valid_sys),
.dbg_tr_valid_sys (dbg_tr_valid_sys),
.dbg_demod_valid_sys (dbg_demod_valid_sys),
 // Phase C — UL TCH/S NUB sync + capture
.voice_nub_sync_thresh_sys (voice_nub_sync_thresh_sys_r1[4:0]),
.voice_nub_coded_softs_sys (voice_nub_coded_softs_sys_w),
.voice_nub_coded_valid_sys (voice_nub_coded_valid_sys_w),
.voice_nub_rx_cnt_sys (voice_nub_rx_cnt_sys_w),
// 2026-05-24 RX IQ peak monitor
.rx_iq_peak_i_sys (rx_iq_peak_i_sys_w),
.rx_iq_peak_q_sys (rx_iq_peak_q_sys_w)
);

// =============================================================================
// Phase 7 F.1 — UL-Demand-Reassembly
// =============================================================================
// Joins the two-burst U-LOC-UPDATE-DEMAND fragments into a 129-bit MM body.
// The output (reass_*_sys) is currently consumed only by debug paths /
// AXI-mailbox extension (Phase F.3). Phase F.2 will plug it into the
// MLE-FSM IE-parser.

// Frame-tick derivation: 1-cycle pulse on every change of frame_num_sys.
// frame_num_sys advances roughly every 56.67 ms (≈5.67M clk_sys cycles).
reg [4:0] frame_num_sys_q;
reg frame_tick_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 frame_num_sys_q <= 5'd0;
 frame_tick_sys <= 1'b0;
 end else begin
 frame_num_sys_q <= frame_num_sys;
 frame_tick_sys <= (frame_num_sys != frame_num_sys_q);
 end
end

// MAC-ACCESS frag=1 trigger. We pulse on the same cycle the parser fires
// pdu_valid_sys with frag_flag_sys=1 AND addr_type ∈ {0,2,3}. The 44-bit
// fragment-1 bus is sliced from ul_raw_info_bits_sys[48..91], MSB-first
// into the bus (bus[43] = info[48], bus[0] = info[91]).
wire frag1_pulse_w = ul_pdu_valid_sys & ul_frag_flag_sys &
 (ul_addr_type_sys != 2'b01);
wire [43:0] frag1_bits_w;
genvar gfb;
generate
 for (gfb = 0; gfb < 44; gfb = gfb + 1) begin: g_frag1_bits
 assign frag1_bits_w[43 - gfb] = ul_raw_info_bits_sys[48 + gfb];
 end
endgenerate

// T0 register from AXI (Phase 7 F.3 — REG_REASSEMBLY_T0 @ 0x1DC).
// 0 → reassembly module substitutes its T0_FRAMES_DEFAULT (=2 frames).
// CDC: 2-FF resync clk_axi → clk_sys (slow-changing operator config).
wire [3:0] reass_t0_frames_axi_w;
(* ASYNC_REG = "TRUE" *) reg [3:0] reass_t0_frames_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] reass_t0_frames_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 reass_t0_frames_sys_r0 <= 4'd0;
 reass_t0_frames_sys_r1 <= 4'd0;
 end else begin
 reass_t0_frames_sys_r0 <= reass_t0_frames_axi_w;
 reass_t0_frames_sys_r1 <= reass_t0_frames_sys_r0;
 end
end
wire [3:0] reass_t0_frames_axi_sys = reass_t0_frames_sys_r1;

// Phase Y.1.a' — mm_type for the frag-1 LLC-wrapped path. Sourced from
// the MAC-ACCESS parser's `ul_llc_mm_pdu_type_w` (decoded inside rx_chain
// LLC walker) — that is the bluestation-aligned mm_pdu_type, not the
// direct one which is for unfragmented MAC-ACCESS.
wire [3:0] frag1_mm_type_w = ul_llc_mm_pdu_type_w;
wire [3:0] reass_mm_type_sys;

tetra_ul_demand_reassembly #(
.T0_FRAMES_DEFAULT(2)
) u_ul_demand_reassembly (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.t0_frames_sys (reass_t0_frames_axi_sys),
.frame_tick_sys (frame_tick_sys),
.frag1_pulse_sys (frag1_pulse_w),
.frag1_ssi_sys (ul_issi_sys),
.frag1_bits_sys (frag1_bits_w),
.frag1_mm_type_sys (frag1_mm_type_w),
.end_hu_pulse_sys (ul_continuation_valid_sys),
.end_hu_ssi_sys (ul_continuation_ssi_sys),
.end_hu_bits_sys (ul_continuation_bits_sys),
.reassembled_valid_sys(reass_valid_sys),
.reassembled_body_sys (reass_body_sys),
.reassembled_ssi_sys (reass_ssi_sys),
.reassembled_mm_type_sys(reass_mm_type_sys),
.reassembled_cnt_sys (reass_cnt_sys),
.drop_cnt_sys (reass_drop_cnt_sys),
.busy_slots_sys (reass_busy_slots_sys)
);

// =============================================================================
// Phase 7 F.2 — UL-Demand-IE-Parser
// =============================================================================
// Walks the 129-bit reassembled MM body to extract the Type-1/2 fields
// (location_update_type, p_class_of_ms,...) and the optional
// GroupIdentityLocationDemand IE (gild_gssi/class/at). Output feeds the
// MLE registration FSM through the demand_* port group.
//
// The IE parser only fills slot 0 of the FSM's GSSI array (single-IE per
// Phase 7 sprint scope); slot 1/2 remain 0 — multi-IE bodies will land in
// M4 alongside U-ATTACH-DETACH-GROUP-IDENTITY support.

// Phase 1E-B (2026-05-20) — tetra_ul_demand_ie_parser RTL-Instanz + die
// zwei nachgelagerten "parsed-snapshot"-Mailboxen (tetra_demand_mailbox,
// tetra_grp_demand_mailbox) entfernt. Walking der 129-bit MM-Bodies passiert
// jetzt in SW (tetra_mm_demand_parser.c, gefüttert aus dem raw-Body-Mailbox
// tetra_ul_demand_body_mailbox). Pre-Reply-BL-ACK triggert weiterhin auf
// Frag-2-Done — siehe u_pre_reply_blck.trigger_valid weiter unten, dort
// direkt auf reass_valid_sys & mm_type ∈ {2,7} umgestellt.

// =============================================================================
// LMAC — Lower MAC Channel Coding (RX: descramble/deinterleave/viterbi/CRC)
// Lower MAC Channel Coding (TX: CRC/encode/interleave/scramble)
// =============================================================================

wire lmac_decoded_bit_sys;
wire lmac_decoded_valid_sys;
wire lmac_block_done_sys;
wire [15:0] lmac_path_metric_sys;
wire [13:0] lmac_aach_data_sys;
wire lmac_aach_done_sys;
wire lmac_aach_error_sys;
wire lmac_crc_ok_sys;
wire lmac_crc_valid_sys;
wire lmac_stolen_sys;

// TX path (Phase 3: idle — ARM provides pre-encoded blocks via AXI-DMA Phase 4)
wire [BLOCK_BITS-1:0] lmac_tx_block1_sys;
wire [BLOCK_BITS-1:0] lmac_tx_block2_sys;
wire [BB_BITS-1:0] lmac_tx_bb_sys;
wire lmac_tx_block_ready_sys;

// LFSR init: {TN[1:0], MNC[13:0], MCC[9:0], CC[5:0]} per ETSI §8.2.5
// colour_code_axi[5:0] = CC; MNC/MCC = 0 for initial testing
wire [31:0] lfsr_init_sys;
assign lfsr_init_sys = {2'd0, 14'd0, 10'd0, colour_code_axi};

tetra_lmac #(
.BLOCK_BITS(BLOCK_BITS),
.LFSR_WIDTH(32)
) u_lmac (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // RX input from burst_demux (slot 0 only in Phase 3)
.rx_block1_sys (rx_block1_sys),
.rx_block2_sys (rx_block2_sys),
.rx_bb_sys (rx_bb_sys),
.rx_slot_valid_sys (rx_slot_valid_sys),
.lfsr_init_sys (lfsr_init_sys),
.load_lfsr_sys (rx_slot_valid_sys), // re-init LFSR each burst
.punct_pattern_sys (3'd0), // Rate 1/3 (full rate)
 // RX decoded output
.rx_decoded_bit_sys (lmac_decoded_bit_sys),
.rx_decoded_valid_sys (lmac_decoded_valid_sys),
.rx_block_done_sys (lmac_block_done_sys),
.rx_path_metric_sys (lmac_path_metric_sys),
.rx_aach_data_sys (lmac_aach_data_sys),
.rx_aach_done_sys (lmac_aach_done_sys),
.rx_aach_error_sys (lmac_aach_error_sys),
.rx_crc_ok_sys (lmac_crc_ok_sys),
.rx_crc_valid_sys (lmac_crc_valid_sys),
.rx_stolen_sys (lmac_stolen_sys),
 // TX input (Phase 3: placeholder — DMA path not yet implemented)
.tx_data_in_sys (1'b0),
.tx_data_valid_sys (1'b0),
.tx_flush_sys (1'b0),
.tx_aach_in_sys (14'd0),
.tx_aach_valid_sys (1'b0),
 // TX output
.tx_block1_sys (lmac_tx_block1_sys),
.tx_block2_sys (lmac_tx_block2_sys),
.tx_bb_sys (lmac_tx_bb_sys),
.tx_block_ready_sys (lmac_tx_block_ready_sys)
);

// =============================================================================
// RX Bit Accumulator — serial Viterbi output → parallel DMA block
//
// Accumulates BLOCK_BITS decoded bits into a flat register, then asserts
// mac_valid_sys to the DMA bridge when lmac_block_done_sys fires.
//
// Pipeline:
// lmac_decoded_valid_sys → shift acc_reg_sys left, insert bit at [0]
// lmac_block_done_sys → latch acc_reg → mac_valid_sys pulse
//
// Note: Viterbi outputs bit_0 FIRST (LSB-first). DMA bridge expects payload
// packed as received (DMA word 0 bit 0 = first decoded bit).
// =============================================================================

// R1: accumulation shift register (BLOCK_BITS bits, R3: flat register)
reg [BLOCK_BITS-1:0] acc_reg_sys;
reg [BLOCK_BITS-1:0] acc_latch_sys; // stable latched copy for DMA bridge
reg mac_valid_r_sys; // 1-cycle pulse for DMA bridge

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
wire irq_mac_block_sys;
wire dma_fifo_empty_sys;
wire dma_fifo_full_sys;

// CRC error and sync-lost counters (Phase 3: simple 16-bit saturating counters)
reg [15:0] crc_err_cnt_sys;
reg [15:0] sync_lost_cnt_sys;

// R1: crc_err_cnt_sys — increments when CRC fails
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 crc_err_cnt_sys <= 16'd0;
 else if (ctrl_reset_counters_sys)
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
 else sync_locked_d1_sys <= sync_locked_sys;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) sync_locked_d2_sys <= 1'b0;
 else sync_locked_d2_sys <= sync_locked_d1_sys;
end

wire sync_lost_pulse_sys = sync_locked_d2_sys & ~sync_locked_d1_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 sync_lost_cnt_sys <= 16'd0;
 else if (ctrl_reset_counters_sys)
 sync_lost_cnt_sys <= 16'd0;
 else if (sync_lost_pulse_sys && !(&sync_lost_cnt_sys))
 sync_lost_cnt_sys <= sync_lost_cnt_sys + 16'd1;
end

tetra_axi_dma_bridge #(
.MAX_BLOCK_BITS(432),
.MAX_DATA_WORDS(14)
) u_dma_bridge (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // MAC block input (from accumulator)
.mac_data_sys ({{(432-BLOCK_BITS){1'b0}}, acc_latch_sys}),
.mac_len_sys (10'd216),
.mac_slot_sys (rx_slot_num_sys),
.mac_burst_type_sys (rx_burst_type_sys),
.mac_frame_sys ({11'd0, frame_num_sys}),
.mac_valid_sys (mac_valid_r_sys),
.mac_ready_sys (),
 // AXI4-Stream master
.m_axis_tvalid (m_axis_tvalid),
.m_axis_tready (m_axis_tready),
.m_axis_tdata (m_axis_tdata),
.m_axis_tkeep (m_axis_tkeep),
.m_axis_tlast (m_axis_tlast),
 // Status
.dma_block_count_sys (dma_block_count_sys),
.irq_mac_block_sys (irq_mac_block_sys),
.fifo_empty_sys (dma_fifo_empty_sys),
.fifo_full_sys (dma_fifo_full_sys),
.reset_counters_sys (ctrl_reset_counters_sys)
);

// =============================================================================
// TX Chain — burst assembly → π/4-DQPSK → RRC → CIC → AD9361
// Phase 4: Free-running TX timer + SB burst support for base station operation
// =============================================================================

// =============================================================================
// Symbol tick generator — exact 18,000 Hz from clk_lvds (AD9361 DATA_CLK)
//
// clk_lvds = 18.432 MHz (AD9361 DATA_CLK, 2× RX sample rate in 1R1T)
// 18,432,000 / 1024 = 18,000.000 Hz — exact, zero jitter.
//
// A toggle signal crosses to clk_sys via 2-FF synchronizer + edge detect,
// producing a 1-cycle sym_en pulse in clk_sys domain.
// =============================================================================
reg [9:0] sym_div_lvds;
reg sym_toggle_lvds;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
 if (!rst_n_lvds) begin
 sym_div_lvds <= 10'd0;
 sym_toggle_lvds <= 1'b0;
 end else if (sym_div_lvds == 10'd1023) begin
 sym_div_lvds <= 10'd0;
 sym_toggle_lvds <= ~sym_toggle_lvds;
 end else begin
 sym_div_lvds <= sym_div_lvds + 10'd1;
 end
end

// 2-FF CDC: toggle from clk_lvds → clk_sys
(* ASYNC_REG = "TRUE" *) reg sym_toggle_meta_sys;
(* ASYNC_REG = "TRUE" *) reg sym_toggle_sync_sys;
reg sym_toggle_prev_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 sym_toggle_meta_sys <= 1'b0;
 sym_toggle_sync_sys <= 1'b0;
 sym_toggle_prev_sys <= 1'b0;
 end else begin
 sym_toggle_meta_sys <= sym_toggle_lvds;
 sym_toggle_sync_sys <= sym_toggle_meta_sys;
 sym_toggle_prev_sys <= sym_toggle_sync_sys;
 end
end

wire sym_en_sys_w = sym_toggle_sync_sys ^ sym_toggle_prev_sys;

// Forward declarations for timebase outputs. The tetra_tdma_timebase
// instance drives these further down in the file; we declare them here
// so tx_chain (the consumer) can bind to them via the same single source
// that drives SB1/AACH encoders and content_mux. Prior to 2026-04-21 the
// tx_chain used a redundant top-level tx_slot_cnt_sys that diverged from
// timebase.tn after TX_TDMA_LOAD (only timebase accepts sync), producing
// a +1 TN mismatch between the schedule-lookup index and the SB1
// TimeSlot field — visible on-air as SB bursts on the wrong slots.
wire [1:0] tx_tdma_state_tn_sys;
wire [4:0] tx_tdma_state_fn_sys;
wire [5:0] tx_tdma_state_mn_sys;
wire [5:0] tx_tdma_state_hn_sys;
wire tx_tdma_state_slot_pulse_sys;
wire tx_tdma_state_tdma_tick_sys;
wire [7:0] tx_tdma_state_sym_cnt_sys;

// TX Slot Timer — derived from sym_en_sys_w (exact 18,000 Hz from clk_lvds)
// Counts 255 symbol ticks per slot, then pulses tx_slot_pulse.
// All TX timing is now locked to AD9361 DATA_CLK — zero drift.

reg [7:0] tx_sym_cnt_sys; // 0..254 symbols per slot
reg [1:0] tx_slot_cnt_sys;
reg [4:0] tx_frame_cnt_sys; // 1–18 (ETSI 1-based)
reg [5:0] tx_mf_cnt_sys; // 1–60 (ETSI 1-based multiframe)
reg tx_slot_pulse_free_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 tx_sym_cnt_sys <= 8'd0;
 tx_slot_cnt_sys <= 2'd0;
 tx_frame_cnt_sys <= 5'd1;
 tx_mf_cnt_sys <= 6'd1;
 tx_slot_pulse_free_sys <= 1'b0;
 end else if (sym_en_sys_w) begin
 if (tx_sym_cnt_sys == 8'd254) begin
 tx_sym_cnt_sys <= 8'd0;
 tx_slot_cnt_sys <= tx_slot_cnt_sys + 2'd1;
 tx_slot_pulse_free_sys <= 1'b1;
 if (tx_slot_cnt_sys == 2'd3) begin
 if (tx_frame_cnt_sys == 5'd18) begin
 tx_frame_cnt_sys <= 5'd1;
 if (tx_mf_cnt_sys == 6'd60)
 tx_mf_cnt_sys <= 6'd1;
 else
 tx_mf_cnt_sys <= tx_mf_cnt_sys + 6'd1;
 end else begin
 tx_frame_cnt_sys <= tx_frame_cnt_sys + 5'd1;
 end
 end
 end else begin
 tx_sym_cnt_sys <= tx_sym_cnt_sys + 8'd1;
 tx_slot_pulse_free_sys <= 1'b0;
 end
 end else begin
 tx_slot_pulse_free_sys <= 1'b0;
 end
end

// Slot pulse fires every timeslot. Burst type per slot controls what
// Continuous downlink: all 4 slots always transmit (no TX blanking).
// SDB slot rotates per multiframe (ETSI §21.4.4.1), other 3 slots = NDB.
wire tx_slot_pulse_sys_w;
assign tx_slot_pulse_sys_w = tx_slot_pulse_free_sys;

// SB data (legacy AXI-Lite path, kept for back-compat readback).
// REG_SB_SB1_* / REG_SB_BKN2_* / REG_SB_BB continue to exist in the AXI
// register bank, but after Phase Y.3 the burst dispatcher consumes only:
// * aach_coded_slot_sys_w (slot-side AACH select — head pre-coded vs
// default-encoder) — feeds dispatcher.bb_in_sys
// * sb1_coded_sys_w (RTL sb1_encoder) — feeds dispatcher.sb_sb1_in_sys
// * sb_bkn2_data_sys — still routed from the AXI register because
// the BNCH/SDB slot-2 payload is SW-computed
// (no RTL encoder).
// The legacy sb_sb1_data_axi_sys / sb_bb_data_axi_sys wires are driven
// but unused on the datapath; readback via AXI still works.
wire [119:0] sb_sb1_data_axi_sys; // legacy AXI path — unused in tx_chain
wire [215:0] sb_bkn2_data_sys; // BNCH: 108 symbols = 216 bits (still used)
wire [29:0] sb_bb_data_axi_sys; // legacy AXI path — unused in tx_chain
// NDB block1/block2 — filler for slots 0/2/3 (SYSINFO SCH/F)
wire [215:0] ndb_block1_data_sys;
wire [215:0] ndb_block2_data_sys;
// MCCH block1/block2 — dedicated for slot 1 (ACCESS-DEFINE SCH/F)
wire [215:0] mcch_block1_data_sys;
wire [215:0] mcch_block2_data_sys;
// BNCH block1/block2 — frame 18 rotating slot (SYSINFO SCH/HD)
wire [215:0] bnch_block1_data_sys;
wire [215:0] bnch_block2_data_sys;
// These wires are driven by the AXI-Lite register bank (connected below).

// =============================================================================
// Phase Y.3 — Slot Content Mux + Burst Dispatcher (3-stage post-pop pipe).
//
// tetra_slot_content_mux is now stripped: it ONLY runs the BRAM-prefetch
// FSM for the schedule entries (one 16-bit entry per TN of the upcoming
// frame). The body/meta latches that used to live here are gone — the
// dispatcher captures everything in a single mux + flop on tx_slot_pulse.
//
// tetra_burst_dispatcher takes:
// * scheduler fan-out (combinational from queue.head, per-TN body bundle)
// * the four schedule entries (from u_slot_content_mux)
// * SW payload banks (NDB / MCCH / BNCH / SB)
// * pre-coded AACH (slot-side select) and SB1
// and produces build_block1/2/bb/sb1/burst_type/ndb2/req — registered
// once on the cycle of tx_slot_pulse_sys, feeding tetra_burst_builder.
// =============================================================================

// Forward declarations — these wires are driven by module instances
// that appear LATER in the source (u_tx_slot_schedule, u_sb1_encoder,
// u_aach_encoder). Verilog-2001 allows forward wire references as long
// as the wire is declared in the same module; explicit declarations here
// avoid any ambiguity and keep `default_nettype none clean.
wire [15:0] schedule_entry_sys_w; // from u_tx_slot_schedule (Port B)
wire [119:0] sb1_coded_sys_w; // from u_sb1_encoder
wire sb1_valid_sys_w;
wire [29:0] aach_coded_sys_w; // from u_aach_encoder (default-logic)
wire aach_valid_sys_w;
// Phase Z.13 — slot AACH select (head pre-coded vs default-encoder).
// Driven by an `assign` near tetra_aach_encoder; declared here for
// `default_nettype none clean forward reference at slot_content_mux.
wire [29:0] aach_coded_slot_sys_w;

// 2-FF CDC: null_pdu_bits_axi (s_axi_aclk) → null_pdu_bits_sys (clk_sys).
// This is a slow-changing 216-bit bus (SW writes once at boot), so a
// simple 2-FF sync per bit is safe. Transient mixes are possible for
// ~2 clk_sys cycles immediately after a write, but the MCU is expected
// to finish all NULL_PDU writes before enabling TX via REG_CTRL.
wire [215:0] null_pdu_bits_axi_w;
(* ASYNC_REG = "TRUE" *) reg [215:0] null_pdu_bits_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [215:0] null_pdu_bits_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) null_pdu_bits_sys_r0 <= 216'h0;
 else null_pdu_bits_sys_r0 <= null_pdu_bits_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) null_pdu_bits_sys_r1 <= 216'h0;
 else null_pdu_bits_sys_r1 <= null_pdu_bits_sys_r0;
end

// Phase Y.3 post-pop pipeline:
// queue.head ─▶ scheduler ─▶ tetra_burst_dispatcher (single-stage)
// │
// build_*_sys + build_req_sys
// ▼
// tx_chain (burst_builder + π/4-DQPSK)
//
// The Z.13/Z.18 era 8× tx_blk*_slot*_sys + slot_*_sys latches inside
// tetra_slot_content_mux are GONE — that module is now a stripped BRAM
// prefetch only. The dispatcher does ALL slot-side body/meta selection
// in one combinational mux + one capture flop.

// Schedule BRAM Port B address — driven by content_mux, consumed by
// tetra_slot_schedule. Data returned 1 cycle later on schedule_entry_sys_w.
wire [8:0] sched_b_addr_sys_w;

// Latched schedule entries (one per TN of the upcoming frame), driven by
// content_mux's BRAM-prefetch FSM and consumed by burst_dispatcher.
wire [15:0] sched_entry_reg_sys0_w;
wire [15:0] sched_entry_reg_sys1_w;
wire [15:0] sched_entry_reg_sys2_w;
wire [15:0] sched_entry_reg_sys3_w;

// Debug probes from content_mux (alias of the entry latches).
wire [15:0] dbg_sched_entry0_sys_w;
wire [15:0] dbg_sched_entry1_sys_w;
wire [15:0] dbg_sched_entry2_sys_w;
wire [15:0] dbg_sched_entry3_sys_w;

// Burst-dispatcher → tx_chain. Every signal is registered inside
// u_burst_dispatcher on the cycle that tx_slot_pulse_sys is HIGH.
wire [BLOCK_BITS-1:0] disp_block1_sys_w;
wire [BLOCK_BITS-1:0] disp_block2_sys_w;
wire [29:0] disp_bb_sys_w;
wire [119:0] disp_sb1_sys_w;
wire disp_burst_type_sys_w;
wire disp_ndb2_sys_w;
wire disp_build_req_sys_w;
wire disp_tx_busy_sys_w;

tetra_slot_content_mux u_slot_content_mux (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.tn_sys (tx_tdma_state_tn_sys),
.fn_sys (tx_tdma_state_fn_sys),
.mn_sys (tx_tdma_state_mn_sys),
.slot_pulse_sys (tx_tdma_state_slot_pulse_sys),
.tdma_tick_sys (tx_tdma_state_tdma_tick_sys),
.sched_addr_sys (sched_b_addr_sys_w),
.sched_data_sys (schedule_entry_sys_w),
.sched_entry_reg_sys0 (sched_entry_reg_sys0_w),
.sched_entry_reg_sys1 (sched_entry_reg_sys1_w),
.sched_entry_reg_sys2 (sched_entry_reg_sys2_w),
.sched_entry_reg_sys3 (sched_entry_reg_sys3_w),
.dbg_sched_entry0_sys (dbg_sched_entry0_sys_w),
.dbg_sched_entry1_sys (dbg_sched_entry1_sys_w),
.dbg_sched_entry2_sys (dbg_sched_entry2_sys_w),
.dbg_sched_entry3_sys (dbg_sched_entry3_sys_w)
);

tetra_burst_dispatcher #(
.BLOCK_BITS(BLOCK_BITS),
.BB_BITS (BB_BITS),
.SB1_BITS (120)
) u_burst_dispatcher (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // TX timing
.tx_slot_pulse_sys (tx_tdma_state_slot_pulse_sys),
.tx_slot_num_sys (tx_tdma_state_tn_sys),
 // Scheduler fan-out (combinational from queue.head)
.sched_blk1_tn0_sys (sched_blk1_tn0_sys_w),
.sched_blk2_tn0_sys (sched_blk2_tn0_sys_w),
.sched_blk1_tn1_sys (sched_blk1_tn1_sys_w),
.sched_blk2_tn1_sys (sched_blk2_tn1_sys_w),
.sched_blk1_tn2_sys (sched_blk1_tn2_sys_w),
.sched_blk2_tn2_sys (sched_blk2_tn2_sys_w),
.sched_blk1_tn3_sys (sched_blk1_tn3_sys_w),
.sched_blk2_tn3_sys (sched_blk2_tn3_sys_w),
.sched_active_sys (sched_active_sys_w),
.sched_ndb2_sys (sched_ndb2_sys_w),
 // Static schedule entries (from BRAM prefetch in u_slot_content_mux)
.sched_entry_reg_sys0 (sched_entry_reg_sys0_w),
.sched_entry_reg_sys1 (sched_entry_reg_sys1_w),
.sched_entry_reg_sys2 (sched_entry_reg_sys2_w),
.sched_entry_reg_sys3 (sched_entry_reg_sys3_w),
 // SW payload banks (216-bit each)
.ndb_block1_sw_sys (ndb_block1_data_sys),
.ndb_block2_sw_sys (ndb_block2_data_sys),
.mcch_block1_sw_sys (mcch_block1_data_sys),
.mcch_block2_sw_sys (mcch_block2_data_sys),
.bnch_block1_sw_sys (bnch_block1_data_sys),
.bnch_block2_sw_sys (bnch_block2_data_sys),
.sb_bkn2_sw_sys (sb_bkn2_data_sys),
 // AACH / SB1 pre-coded streams (slot-side AACH select feeds bb;
 // SB1 encoder output feeds sb1).
.bb_in_sys (aach_coded_slot_sys_w),
.sb_sb1_in_sys (sb1_coded_sys_w),
 // Builder feedback (reserved)
.tx_busy_sys (disp_tx_busy_sys_w),
 // Phase 7 G.8 voice-slot filler-mailbox inputs (SW-encoded SCH/F)
.voice_active_mask_sys (voice_active_mask_sys_r1),
.voice_slot_tn_sys (voice_slot_tn_sys_w),
.tx_fn_sys (tx_tdma_state_fn_sys),
.vfill_valid_sys (vfill_valid_sys_w),
.vfill_blk1_sys (vfill_blk1_sys_w),
.vfill_blk2_sys (vfill_blk2_sys_w),
 // Outputs to tetra_tx_chain
.build_block1_sys (disp_block1_sys_w),
.build_block2_sys (disp_block2_sys_w),
.build_bb_sys (disp_bb_sys_w),
.build_sb1_sys (disp_sb1_sys_w),
.build_burst_type_sys (disp_burst_type_sys_w),
.build_ndb2_sys (disp_ndb2_sys_w),
.build_req_sys (disp_build_req_sys_w)
);

// =============================================================================
// Phase 7 G.8 — Voice-Slot DL kommt jetzt aus voice_filler_mailbox
// (u_voice_filler_mailbox unten). SW encodes SCH/F type-5 burst →
// schreibt via AXI → dispatcher emittiert in voice-FN. UL-NUB-Capture
// bleibt für künftige Phase B (dynamic UL→DL voice-relay via SW).
// =============================================================================

// Keep synth sinks on legacy AXI-driven SB wires + unused content-mux
// debug probes so opt_design does not remove the AXI write path or the
// schedule-entry latches when only the dispatcher consumes them.
(* keep = "true" *) wire _legacy_sb_keep_sys = ^sb_sb1_data_axi_sys ^
 ^sb_bb_data_axi_sys ^
 ^aach_valid_sys_w ^
 ^sb1_valid_sys_w ^
 ^dbg_sched_entry0_sys_w ^
 ^dbg_sched_entry1_sys_w ^
 ^dbg_sched_entry2_sys_w ^
 ^dbg_sched_entry3_sys_w;

wire tx_first_dibit_sys_w;

tetra_tx_chain #(
.IQ_WIDTH (IQ_WIDTH),
.BLOCK_BITS(BLOCK_BITS),
.BB_BITS (BB_BITS),
.SB1_BITS (120)
 ) u_tx_chain (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Builder payload from u_burst_dispatcher
.build_block1_sys (disp_block1_sys_w),
.build_block2_sys (disp_block2_sys_w),
.build_bb_sys (disp_bb_sys_w),
.build_sb1_sys (disp_sb1_sys_w),
.build_burst_type_sys (disp_burst_type_sys_w),
.build_ndb2_sys (disp_ndb2_sys_w),
.build_req_sys (disp_build_req_sys_w),
 // Diagnostic: replace builder dibit with 15-bit LFSR PRBS
.tx_test_prbs_en_sys (tx_test_prbs_en_sys),
 // Symbol enable — exact 18 kHz from clk_lvds ÷ 1024
.sym_en_ext_sys (sym_en_sys_w),
 // clk_lvds domain
.clk_lvds (clk_lvds),
.rst_n_lvds (rst_n_lvds),
 // TX IQ output to AD9361
.tx_i_lvds (tx_i_lvds),
.tx_q_lvds (tx_q_lvds),
.tx_valid_lvds (tx_valid_lvds),
 // Status — feeds back to dispatcher (reserved future use)
.tx_busy_sys (disp_tx_busy_sys_w),
 // Mess-Infra (2026-05-25): 1-cycle Puls am ersten Dibit jeder Burst
.first_dibit_sys (tx_first_dibit_sys_w)
 );

// =============================================================================
// 2026-05-25 Mess-Infra — TS1-Stopuhr (clk_sys, AXI nur read-only)
// =============================================================================
// 1) current_burst_is_ts1_r: gelatcht bei build_req_sys & tx_slot_num==0
// 2) ts1_pulse_sys = tx_first_dibit_sys_w & current_burst_is_ts1_r
// 3) free-running counter, latch A bei ts1_pulse, latch B bei ul_sync_found
// 4) Event-Counter inkrementiert bei jedem UL-Latch
// =============================================================================
reg current_burst_is_ts1_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 current_burst_is_ts1_sys <= 1'b0;
 else if (disp_build_req_sys_w)
 current_burst_is_ts1_sys <= (tx_tdma_state_tn_sys == 2'd0);
end

wire ts1_pulse_sys = tx_first_dibit_sys_w & current_burst_is_ts1_sys;

reg [31:0] sw_counter_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) sw_counter_sys <= 32'd0;
 else            sw_counter_sys <= sw_counter_sys + 32'd1;
end

reg [31:0] sw_ts1_latch_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) sw_ts1_latch_sys <= 32'd0;
 else if (ts1_pulse_sys) sw_ts1_latch_sys <= sw_counter_sys;
end

reg [31:0] sw_ul_latch_sys;
reg [31:0] sw_ul_evt_cnt_sys;
// 2026-05-25: Race-Fix — delta wird ATOMAR bei jedem UL-Event berechnet.
// sw_counter_sys (UL-Zeit) − sw_ts1_latch_sys (jüngster vorausgegangener TS1)
// = exakte Zykluszahl vom letzten TS1-Puls vor diesem UL-Burst. SW liest nur
// sw_delta_latch_sys + sw_ul_evt_cnt_sys, kein SW-seitiger Race mehr.
reg [31:0] sw_delta_latch_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 sw_ul_latch_sys    <= 32'd0;
 sw_ul_evt_cnt_sys  <= 32'd0;
 sw_delta_latch_sys <= 32'd0;
 end else if (ul_sync_found_sys) begin
 sw_ul_latch_sys    <= sw_counter_sys;
 sw_ul_evt_cnt_sys  <= sw_ul_evt_cnt_sys + 32'd1;
 sw_delta_latch_sys <= sw_counter_sys - sw_ts1_latch_sys;
 end
end

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
 else sync_locked_axi_r0 <= sync_locked_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sync_locked_axi_r1 <= 1'b0;
 else sync_locked_axi_r1 <= sync_locked_axi_r0;
end

// frame_num — 5-bit Gray-coded for safe CDC
// (Frame counter increments slowly relative to AXI clock — Gray encoding
// ensures ≤1 bit flip per transition, making 2-FF sync safe.)
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
 else frame_num_axi_r0 <= frame_num_gray_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) frame_num_axi_r1 <= 5'd0;
 else frame_num_axi_r1 <= frame_num_axi_r0;
end

// Gray → binary decode for AXI register readback
wire [4:0] frame_num_axi;
assign frame_num_axi[4] = frame_num_axi_r1[4];
assign frame_num_axi[3] = frame_num_axi_r1[4] ^ frame_num_axi_r1[3];
assign frame_num_axi[2] = frame_num_axi[3] ^ frame_num_axi_r1[2];
assign frame_num_axi[1] = frame_num_axi[2] ^ frame_num_axi_r1[1];
assign frame_num_axi[0] = frame_num_axi[1] ^ frame_num_axi_r1[0];

// slot_num — 2-bit, Gray coded
wire [1:0] slot_num_gray_sys;
assign slot_num_gray_sys[1] = timeslot_num_sys[1];
assign slot_num_gray_sys[0] = timeslot_num_sys[1] ^ timeslot_num_sys[0];

(* ASYNC_REG = "TRUE" *) reg [1:0] slot_num_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] slot_num_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) slot_num_axi_r0 <= 2'd0;
 else slot_num_axi_r0 <= slot_num_gray_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) slot_num_axi_r1 <= 2'd0;
 else slot_num_axi_r1 <= slot_num_axi_r0;
end

wire [1:0] slot_num_axi;
assign slot_num_axi[1] = slot_num_axi_r1[1];
assign slot_num_axi[0] = slot_num_axi_r1[1] ^ slot_num_axi_r1[0];

// IRQ pulse synchronizers — toggle-based (sys → axi)
// irq_mac_block_sys pulse in clk_sys → toggle register → 2-FF → edge detect
reg irq_mac_tgl_sys;
(* ASYNC_REG = "TRUE" *) reg irq_mac_tgl_axi_r0;
(* ASYNC_REG = "TRUE" *) reg irq_mac_tgl_axi_r1;
reg irq_mac_tgl_axi_r2;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) irq_mac_tgl_sys <= 1'b0;
 else if (irq_mac_block_sys) irq_mac_tgl_sys <= ~irq_mac_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_mac_tgl_axi_r0 <= 1'b0;
 else irq_mac_tgl_axi_r0 <= irq_mac_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_mac_tgl_axi_r1 <= 1'b0;
 else irq_mac_tgl_axi_r1 <= irq_mac_tgl_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_mac_tgl_axi_r2 <= 1'b0;
 else irq_mac_tgl_axi_r2 <= irq_mac_tgl_axi_r1;
end

wire irq_mac_block_axi = irq_mac_tgl_axi_r1 ^ irq_mac_tgl_axi_r2; // re-pulsed

// sync_acquired: rising edge of sync_locked (axi domain, already synchronized)
wire irq_sync_acquired_axi;
reg sync_locked_prev_axi;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sync_locked_prev_axi <= 1'b0;
 else sync_locked_prev_axi <= sync_locked_axi_r1;
end
assign irq_sync_acquired_axi = sync_locked_axi_r1 & ~sync_locked_prev_axi;

// sync_lost: falling edge of sync_locked (axi domain)
wire irq_sync_lost_axi = ~sync_locked_axi_r1 & sync_locked_prev_axi;

// CRC error IRQ — toggle sync from sys
reg irq_crc_tgl_sys;
(* ASYNC_REG = "TRUE" *) reg irq_crc_tgl_axi_r0;
(* ASYNC_REG = "TRUE" *) reg irq_crc_tgl_axi_r1;
reg irq_crc_tgl_axi_r2;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) irq_crc_tgl_sys <= 1'b0;
 else if (lmac_crc_valid_sys && !lmac_crc_ok_sys) irq_crc_tgl_sys <= ~irq_crc_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_crc_tgl_axi_r0 <= 1'b0;
 else irq_crc_tgl_axi_r0 <= irq_crc_tgl_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_crc_tgl_axi_r1 <= 1'b0;
 else irq_crc_tgl_axi_r1 <= irq_crc_tgl_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) irq_crc_tgl_axi_r2 <= 1'b0;
 else irq_crc_tgl_axi_r2 <= irq_crc_tgl_axi_r1;
end

wire irq_crc_error_axi = irq_crc_tgl_axi_r1 ^ irq_crc_tgl_axi_r2;

// DMA FIFO full IRQ — direct sync (slow signal)
(* ASYNC_REG = "TRUE" *) reg fifo_full_axi_r0;
(* ASYNC_REG = "TRUE" *) reg fifo_full_axi_r1;
(* ASYNC_REG = "TRUE" *) reg fifo_full_prev_axi;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) fifo_full_axi_r0 <= 1'b0;
 else fifo_full_axi_r0 <= dma_fifo_full_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) fifo_full_axi_r1 <= 1'b0;
 else fifo_full_axi_r1 <= fifo_full_axi_r0;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) fifo_full_prev_axi <= 1'b0;
 else fifo_full_prev_axi <= fifo_full_axi_r1;
end

wire irq_rx_fifo_full_axi = fifo_full_axi_r1 & ~fifo_full_prev_axi; // rising edge

// counter synchronization (16-bit, slow — gray code or snapshot capture)
// Phase 3 simplification: clk_sys ≈ s_axi_aclk; direct connection with
// ASYNC_REG FF chain is sufficient for counters that change < 1x per 100 cycles.
(* ASYNC_REG = "TRUE" *) reg [15:0] dma_blk_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] dma_blk_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) dma_blk_cnt_axi_r0 <= 16'd0;
 else dma_blk_cnt_axi_r0 <= dma_block_count_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) dma_blk_cnt_axi_r1 <= 16'd0;
 else dma_blk_cnt_axi_r1 <= dma_blk_cnt_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [15:0] crc_err_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] crc_err_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) crc_err_cnt_axi_r0 <= 16'd0;
 else crc_err_cnt_axi_r0 <= crc_err_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) crc_err_cnt_axi_r1 <= 16'd0;
 else crc_err_cnt_axi_r1 <= crc_err_cnt_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [15:0] sync_lost_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] sync_lost_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sync_lost_cnt_axi_r0 <= 16'd0;
 else sync_lost_cnt_axi_r0 <= sync_lost_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sync_lost_cnt_axi_r1 <= 16'd0;
 else sync_lost_cnt_axi_r1 <= sync_lost_cnt_axi_r0;
end

// =============================================================================
// UL MAC-ACCESS PDU mailbox CDC (Task #37) — clk_sys ↔ clk_axi
//
// Pulse: toggle-CDC on ul_pdu_valid_sys. A toggle register in clk_sys flips
// on every pdu-valid pulse; 2-FF resync into clk_axi + edge detect produces
// the 1-cycle pulse ul_pdu_valid_axi_pulse. This matches the existing
// irq_mac_tgl_* pattern above.
//
// Data: per-bit 2-FF resync of the parsed fields. The parser only mutates
// these signals on the clk_sys pulse (tetra_ul_mac_access_parser latches all
// outputs together), so by the time the toggle-resynced pulse arrives in
// clk_axi (≥2 s_axi_aclk cycles later), every data bit has had time to
// settle — the AXI reg latch is driven by the resynced pulse, not the raw
// data, so the snapshot is consistent.
// =============================================================================

// Toggle register in clk_sys
reg ul_pdu_tgl_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) ul_pdu_tgl_sys <= 1'b0;
 else if (ul_pdu_valid_sys) ul_pdu_tgl_sys <= ~ul_pdu_tgl_sys;
end

// 2-FF resync + edge detect in clk_axi → 1-cycle pulse
(* ASYNC_REG = "TRUE" *) reg ul_pdu_tgl_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_pdu_tgl_axi_r1;
reg ul_pdu_tgl_axi_r2;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 ul_pdu_tgl_axi_r0 <= 1'b0;
 ul_pdu_tgl_axi_r1 <= 1'b0;
 ul_pdu_tgl_axi_r2 <= 1'b0;
 end else begin
 ul_pdu_tgl_axi_r0 <= ul_pdu_tgl_sys;
 ul_pdu_tgl_axi_r1 <= ul_pdu_tgl_axi_r0;
 ul_pdu_tgl_axi_r2 <= ul_pdu_tgl_axi_r1;
 end
end
wire ul_pdu_valid_axi_pulse = ul_pdu_tgl_axi_r1 ^ ul_pdu_tgl_axi_r2;

// Per-bit 2-FF resync of the parsed fields (data stable when pulse fires)
(* ASYNC_REG = "TRUE" *) reg ul_pdu_type_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_pdu_type_axi_r1;
(* ASYNC_REG = "TRUE" *) reg ul_fill_bit_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_fill_bit_axi_r1;
(* ASYNC_REG = "TRUE" *) reg ul_encryption_mode_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_encryption_mode_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [1:0] ul_addr_type_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] ul_addr_type_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [23:0] ul_issi_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [23:0] ul_issi_axi_r1;
(* ASYNC_REG = "TRUE" *) reg ul_optional_field_flag_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_optional_field_flag_axi_r1;
(* ASYNC_REG = "TRUE" *) reg ul_frag_flag_axi_r0;
(* ASYNC_REG = "TRUE" *) reg ul_frag_flag_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_reservation_req_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_reservation_req_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [91:0] ul_raw_info_bits_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [91:0] ul_raw_info_bits_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] ul_pdu_count_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] ul_pdu_count_axi_r1;
// Phase 7 F.3 — decoded LLC/MLE/MM type fields, resynced clk_sys → clk_axi
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_llc_pdu_type_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_llc_pdu_type_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [2:0] ul_mle_disc_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [2:0] ul_mle_disc_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_mm_pdu_type_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] ul_mm_pdu_type_axi_r1;
// Phase 7 F.3 — reassembly counters, resynced clk_sys → clk_axi
(* ASYNC_REG = "TRUE" *) reg [15:0] reass_reassembled_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] reass_reassembled_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] reass_drop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] reass_drop_cnt_axi_r1;
// Phase C — voice-channel counters, resynced clk_sys → clk_axi
(* ASYNC_REG = "TRUE" *) reg [15:0] voice_nub_rx_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] voice_nub_rx_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] voice_relay_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] voice_relay_cnt_axi_r1;
// 2026-05-24 — RX IQ peak monitor CDC (sys→axi)
(* ASYNC_REG = "TRUE" *) reg [15:0] rx_iq_peak_i_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] rx_iq_peak_i_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] rx_iq_peak_q_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] rx_iq_peak_q_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 ul_pdu_type_axi_r0 <= 1'b0;
 ul_pdu_type_axi_r1 <= 1'b0;
 ul_fill_bit_axi_r0 <= 1'b0;
 ul_fill_bit_axi_r1 <= 1'b0;
 ul_encryption_mode_axi_r0 <= 1'b0;
 ul_encryption_mode_axi_r1 <= 1'b0;
 ul_addr_type_axi_r0 <= 2'd0;
 ul_addr_type_axi_r1 <= 2'd0;
 ul_issi_axi_r0 <= 24'd0;
 ul_issi_axi_r1 <= 24'd0;
 ul_optional_field_flag_axi_r0 <= 1'b0;
 ul_optional_field_flag_axi_r1 <= 1'b0;
 ul_frag_flag_axi_r0 <= 1'b0;
 ul_frag_flag_axi_r1 <= 1'b0;
 ul_reservation_req_axi_r0 <= 4'd0;
 ul_reservation_req_axi_r1 <= 4'd0;
 ul_raw_info_bits_axi_r0 <= 92'd0;
 ul_raw_info_bits_axi_r1 <= 92'd0;
 ul_pdu_count_axi_r0 <= 16'd0;
 ul_pdu_count_axi_r1 <= 16'd0;
 ul_llc_pdu_type_axi_r0 <= 4'd0;
 ul_llc_pdu_type_axi_r1 <= 4'd0;
 ul_mle_disc_axi_r0 <= 3'd0;
 ul_mle_disc_axi_r1 <= 3'd0;
 ul_mm_pdu_type_axi_r0 <= 4'd0;
 ul_mm_pdu_type_axi_r1 <= 4'd0;
 reass_reassembled_cnt_axi_r0 <= 16'd0;
 reass_reassembled_cnt_axi_r1 <= 16'd0;
 reass_drop_cnt_axi_r0 <= 16'd0;
 reass_drop_cnt_axi_r1 <= 16'd0;
 voice_nub_rx_cnt_axi_r0 <= 16'd0;
 voice_nub_rx_cnt_axi_r1 <= 16'd0;
 voice_relay_cnt_axi_r0 <= 16'd0;
 voice_relay_cnt_axi_r1 <= 16'd0;
 rx_iq_peak_i_axi_r0 <= 16'd0;
 rx_iq_peak_i_axi_r1 <= 16'd0;
 rx_iq_peak_q_axi_r0 <= 16'd0;
 rx_iq_peak_q_axi_r1 <= 16'd0;
 end else begin
 ul_pdu_type_axi_r0 <= ul_pdu_type_sys;
 ul_pdu_type_axi_r1 <= ul_pdu_type_axi_r0;
 ul_fill_bit_axi_r0 <= ul_fill_bit_sys;
 ul_fill_bit_axi_r1 <= ul_fill_bit_axi_r0;
 ul_encryption_mode_axi_r0 <= ul_encryption_mode_sys;
 ul_encryption_mode_axi_r1 <= ul_encryption_mode_axi_r0;
 ul_addr_type_axi_r0 <= ul_addr_type_sys;
 ul_addr_type_axi_r1 <= ul_addr_type_axi_r0;
 ul_issi_axi_r0 <= ul_issi_sys;
 ul_issi_axi_r1 <= ul_issi_axi_r0;
 ul_optional_field_flag_axi_r0 <= ul_optional_field_flag_sys;
 ul_optional_field_flag_axi_r1 <= ul_optional_field_flag_axi_r0;
 ul_frag_flag_axi_r0 <= ul_frag_flag_sys;
 ul_frag_flag_axi_r1 <= ul_frag_flag_axi_r0;
 ul_reservation_req_axi_r0 <= ul_reservation_req_sys;
 ul_reservation_req_axi_r1 <= ul_reservation_req_axi_r0;
 ul_raw_info_bits_axi_r0 <= ul_raw_info_bits_sys;
 ul_raw_info_bits_axi_r1 <= ul_raw_info_bits_axi_r0;
 ul_pdu_count_axi_r0 <= ul_pdu_count_sys;
 ul_pdu_count_axi_r1 <= ul_pdu_count_axi_r0;
 ul_llc_pdu_type_axi_r0 <= ul_llc_pdu_type_sys;
 ul_llc_pdu_type_axi_r1 <= ul_llc_pdu_type_axi_r0;
 ul_mle_disc_axi_r0 <= ul_mle_disc_sys;
 ul_mle_disc_axi_r1 <= ul_mle_disc_axi_r0;
 // Drift-Fix 2026-05-05: REG_UL_PDU_STATUS_2[11:8] muss den LLC-
 // wrapped mm_type liefern (Bits[44..47] des 92-bit-Bursts). Vorher
 // wurde der "direct mm_type" (Bits[36..39]) genutzt — der zeigt für
 // BL-DATA-wrapped MS-Demands immer "1" (=BL-DATA) statt des echten
 // mm_type. Das Group-Demand-Routing nutzt schon den richtigen Pfad
 // (ul_llc_mm_pdu_type_w → frag1_mm_type_w → IE-Parser); nur die
 // AXI-Anzeige war falsch verdrahtet.
 ul_mm_pdu_type_axi_r0 <= ul_llc_mm_pdu_type_w;
 ul_mm_pdu_type_axi_r1 <= ul_mm_pdu_type_axi_r0;
 // Phase 7 F.3 — reassembly counters; clk_sys → clk_axi
 reass_reassembled_cnt_axi_r0 <= reass_cnt_sys;
 reass_reassembled_cnt_axi_r1 <= reass_reassembled_cnt_axi_r0;
 reass_drop_cnt_axi_r0 <= reass_drop_cnt_sys;
 reass_drop_cnt_axi_r1 <= reass_drop_cnt_axi_r0;
 // Phase C — voice-channel counters; clk_sys → clk_axi
 voice_nub_rx_cnt_axi_r0 <= voice_nub_rx_cnt_sys_w;
 voice_nub_rx_cnt_axi_r1 <= voice_nub_rx_cnt_axi_r0;
 voice_relay_cnt_axi_r0 <= voice_relay_cnt_sys_w;
 voice_relay_cnt_axi_r1 <= voice_relay_cnt_axi_r0;
 // 2026-05-24 RX IQ peak monitor CDC
 rx_iq_peak_i_axi_r0 <= rx_iq_peak_i_sys_w;
 rx_iq_peak_i_axi_r1 <= rx_iq_peak_i_axi_r0;
 rx_iq_peak_q_axi_r0 <= rx_iq_peak_q_sys_w;
 rx_iq_peak_q_axi_r1 <= rx_iq_peak_q_axi_r0;
 end
end

// =============================================================================
// DL-Signal-Queue / Scheduler / Pre-Reply diagnostic counter CDC
// (clk_sys → clk_axi, 2-FF, slow-changing — per-bit gray not required).
// REG_SLOTGRANT_STATS / REG_PRE_REPLY_BLCK_STATS / REG_DL_QUEUE_STATS /
// REG_DL_SCHEDULER_STATS feed off the *_axi_r1 outputs of this block.
// =============================================================================
(* ASYNC_REG = "TRUE" *) reg [15:0] slotgrant_push_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] slotgrant_push_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] slotgrant_drop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] slotgrant_drop_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] blck_push_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] blck_push_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] blck_drop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] blck_drop_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_mle_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_mle_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_cmce_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_cmce_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_sds_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [7:0] qdrop_sds_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] sched_pop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] sched_pop_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] sched_override_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] sched_override_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 slotgrant_push_cnt_axi_r0 <= 16'd0;
 slotgrant_push_cnt_axi_r1 <= 16'd0;
 slotgrant_drop_cnt_axi_r0 <= 16'd0;
 slotgrant_drop_cnt_axi_r1 <= 16'd0;
 blck_push_cnt_axi_r0 <= 16'd0;
 blck_push_cnt_axi_r1 <= 16'd0;
 blck_drop_cnt_axi_r0 <= 16'd0;
 blck_drop_cnt_axi_r1 <= 16'd0;
 qdrop_mle_axi_r0 <= 8'd0;
 qdrop_mle_axi_r1 <= 8'd0;
 qdrop_cmce_axi_r0 <= 8'd0;
 qdrop_cmce_axi_r1 <= 8'd0;
 qdrop_sds_axi_r0 <= 8'd0;
 qdrop_sds_axi_r1 <= 8'd0;
 sched_pop_cnt_axi_r0 <= 16'd0;
 sched_pop_cnt_axi_r1 <= 16'd0;
 sched_override_cnt_axi_r0 <= 16'd0;
 sched_override_cnt_axi_r1 <= 16'd0;
 end else begin
 slotgrant_push_cnt_axi_r0 <= slotgrant_push_cnt_sys_w;
 slotgrant_push_cnt_axi_r1 <= slotgrant_push_cnt_axi_r0;
 slotgrant_drop_cnt_axi_r0 <= slotgrant_drop_cnt_sys_w;
 slotgrant_drop_cnt_axi_r1 <= slotgrant_drop_cnt_axi_r0;
 blck_push_cnt_axi_r0 <= pre_reply_blck_push_cnt_sys_w;
 blck_push_cnt_axi_r1 <= blck_push_cnt_axi_r0;
 blck_drop_cnt_axi_r0 <= pre_reply_blck_drop_cnt_sys_w;
 blck_drop_cnt_axi_r1 <= blck_drop_cnt_axi_r0;
 qdrop_mle_axi_r0 <= queue_drop_cnt_mle_w;
 qdrop_mle_axi_r1 <= qdrop_mle_axi_r0;
 qdrop_cmce_axi_r0 <= queue_drop_cnt_cmce_w;
 qdrop_cmce_axi_r1 <= qdrop_cmce_axi_r0;
 qdrop_sds_axi_r0 <= queue_drop_cnt_sds_w;
 qdrop_sds_axi_r1 <= qdrop_sds_axi_r0;
 sched_pop_cnt_axi_r0 <= sig_pop_cnt_w;
 sched_pop_cnt_axi_r1 <= sched_pop_cnt_axi_r0;
 sched_override_cnt_axi_r0 <= sig_override_cnt_w;
 sched_override_cnt_axi_r1 <= sched_override_cnt_axi_r0;
 end
end

// ul_scramb_init: clk_axi → clk_sys. Slow-changing (MCU writes once at
// boot), so per-bit 2-FF is safe — after SW writes the register every bit
// is stable indefinitely.
(* ASYNC_REG = "TRUE" *) reg [31:0] ul_scramb_init_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] ul_scramb_init_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 ul_scramb_init_sys_r0 <= 32'h0;
 ul_scramb_init_sys_r1 <= 32'h0;
 end else begin
 ul_scramb_init_sys_r0 <= ul_scramb_init_axi_w;
 ul_scramb_init_sys_r1 <= ul_scramb_init_sys_r0;
 end
end
assign ul_scramb_init_sys = ul_scramb_init_sys_r1;

always @(posedge clk_lvds or negedge rst_n_lvds) begin
 if (!rst_n_lvds) begin
 ctrl_loopback_lvds_r0 <= 1'b0;
 ctrl_loopback_lvds_r1 <= 1'b0;
 end else begin
 ctrl_loopback_lvds_r0 <= ctrl_loopback_en_axi;
 ctrl_loopback_lvds_r1 <= ctrl_loopback_lvds_r0;
 end
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 ctrl_reset_cnt_sys_r0 <= 1'b0;
 ctrl_reset_cnt_sys_r1 <= 1'b0;
 ctrl_loopback_sys_r0 <= 1'b0;
 ctrl_loopback_sys_r1 <= 1'b0;
 tx_test_prbs_sys_r0 <= 1'b0;
 tx_test_prbs_sys_r1 <= 1'b0;
 end else begin
 ctrl_reset_cnt_sys_r0 <= ctrl_reset_counters_axi;
 ctrl_reset_cnt_sys_r1 <= ctrl_reset_cnt_sys_r0;
 ctrl_loopback_sys_r0 <= ctrl_loopback_en_axi;
 ctrl_loopback_sys_r1 <= ctrl_loopback_sys_r0;
 tx_test_prbs_sys_r0 <= tx_test_prbs_en_axi;
 tx_test_prbs_sys_r1 <= tx_test_prbs_sys_r0;
 end
end

// =============================================================================
// TX TDMA Timebase (Plan Stufe 2) — canonical 0-based TDMA counter
//
// Runs in parallel with the legacy tx_{slot,frame,mf}_cnt_sys counters
// (which remain the active source for the TX chain in Phase-4 until
// Stufe 3+ retire them). This module's outputs are exposed to AXI via
// TX_TDMA_STATE (0x144) and accept a sync-load pulse from AXI via
// TX_TDMA_LOAD (0x140). No TX-chain behaviour change in Stufe 2.
//
// AXI → clk_sys pulse CDC: clk_axi and clk_sys share the same PS PLL
// source, but they are declared as independent domains in timing
// constraints. A 2-FF synchronizer on the strobe is sufficient to
// absorb any sub-cycle skew; data fields are held stable by the AXI
// register bank for the duration of the resync.
// =============================================================================

// Data bus (clk_axi domain — wires from register bank, stable)
wire [1:0] tx_tdma_sync_tn_axi_w;
wire [4:0] tx_tdma_sync_fn_axi_w;
wire [5:0] tx_tdma_sync_mn_axi_w;
wire [5:0] tx_tdma_sync_hn_axi_w;
wire tx_tdma_sync_strobe_axi_w;

// 2-FF strobe resync: clk_axi → clk_sys, then edge-detect
(* ASYNC_REG = "TRUE" *) reg tx_tdma_strobe_sys_r0;
(* ASYNC_REG = "TRUE" *) reg tx_tdma_strobe_sys_r1;
reg tx_tdma_strobe_sys_r2;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) tx_tdma_strobe_sys_r0 <= 1'b0;
 else tx_tdma_strobe_sys_r0 <= tx_tdma_sync_strobe_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) tx_tdma_strobe_sys_r1 <= 1'b0;
 else tx_tdma_strobe_sys_r1 <= tx_tdma_strobe_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) tx_tdma_strobe_sys_r2 <= 1'b0;
 else tx_tdma_strobe_sys_r2 <= tx_tdma_strobe_sys_r1;
end

// Rising-edge detect = 1-cycle sys pulse. The AXI-side strobe was a
// single clk_axi cycle; on the sys side we extend a pulse on the
// rising edge of the resynced signal. If the AXI cycle and sys cycle
// are nearly aligned (same PLL) this is effectively a 2-cycle pipeline.
wire tx_tdma_sync_load_strobe_sys = tx_tdma_strobe_sys_r1 & ~tx_tdma_strobe_sys_r2;

// Timebase instance — free-running counter synchronized to sym_en_sys_w
// (same 18 kHz tick the legacy counters use). Wire declarations moved
// above tx_chain (search: "Forward declarations for timebase outputs").
tetra_tdma_timebase u_tx_tdma_timebase (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.sym_en (sym_en_sys_w),
.sync_load_strobe (tx_tdma_sync_load_strobe_sys),
.sync_tn_in (tx_tdma_sync_tn_axi_w),
.sync_fn_in (tx_tdma_sync_fn_axi_w),
.sync_mn_in (tx_tdma_sync_mn_axi_w),
.sync_hn_in (tx_tdma_sync_hn_axi_w),
.sym_cnt (tx_tdma_state_sym_cnt_sys),
.tn (tx_tdma_state_tn_sys),
.fn (tx_tdma_state_fn_sys),
.mn (tx_tdma_state_mn_sys),
.hn (tx_tdma_state_hn_sys),
.slot_pulse (tx_tdma_state_slot_pulse_sys),
.tdma_tick (tx_tdma_state_tdma_tick_sys)
);

// 2-FF resync of the STATE snapshot: clk_sys → clk_axi (per-bit).
// Plan Stufe 2 explicitly allows transient inconsistencies between
// fields (AXI reads are best-effort snapshots for debug/IRQ-ACK).
(* ASYNC_REG = "TRUE" *) reg [1:0] tx_tdma_state_tn_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] tx_tdma_state_tn_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_tn_axi_r0 <= 2'd0;
 else tx_tdma_state_tn_axi_r0 <= tx_tdma_state_tn_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_tn_axi_r1 <= 2'd0;
 else tx_tdma_state_tn_axi_r1 <= tx_tdma_state_tn_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [4:0] tx_tdma_state_fn_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [4:0] tx_tdma_state_fn_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_fn_axi_r0 <= 5'd0;
 else tx_tdma_state_fn_axi_r0 <= tx_tdma_state_fn_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_fn_axi_r1 <= 5'd0;
 else tx_tdma_state_fn_axi_r1 <= tx_tdma_state_fn_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [5:0] tx_tdma_state_mn_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [5:0] tx_tdma_state_mn_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_mn_axi_r0 <= 6'd0;
 else tx_tdma_state_mn_axi_r0 <= tx_tdma_state_mn_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_mn_axi_r1 <= 6'd0;
 else tx_tdma_state_mn_axi_r1 <= tx_tdma_state_mn_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [5:0] tx_tdma_state_hn_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [5:0] tx_tdma_state_hn_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_hn_axi_r0 <= 6'd0;
 else tx_tdma_state_hn_axi_r0 <= tx_tdma_state_hn_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_hn_axi_r1 <= 6'd0;
 else tx_tdma_state_hn_axi_r1 <= tx_tdma_state_hn_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [7:0] tx_tdma_state_sym_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [7:0] tx_tdma_state_sym_cnt_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_sym_cnt_axi_r0 <= 8'd0;
 else tx_tdma_state_sym_cnt_axi_r0 <= tx_tdma_state_sym_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) tx_tdma_state_sym_cnt_axi_r1 <= 8'd0;
 else tx_tdma_state_sym_cnt_axi_r1 <= tx_tdma_state_sym_cnt_axi_r0;
end

// =============================================================================
// 2026-05-25 Mess-Infra: 2-FF Sync clk_sys → s_axi_aclk (same-source Annahme
// wie alle anderen Status-Regs hier).
// =============================================================================
(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ts1_latch_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ts1_latch_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ts1_latch_axi_r0 <= 32'd0;
 else            sw_ts1_latch_axi_r0 <= sw_ts1_latch_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ts1_latch_axi_r1 <= 32'd0;
 else            sw_ts1_latch_axi_r1 <= sw_ts1_latch_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ul_latch_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ul_latch_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ul_latch_axi_r0 <= 32'd0;
 else            sw_ul_latch_axi_r0 <= sw_ul_latch_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ul_latch_axi_r1 <= 32'd0;
 else            sw_ul_latch_axi_r1 <= sw_ul_latch_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ul_evt_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] sw_ul_evt_cnt_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ul_evt_cnt_axi_r0 <= 32'd0;
 else            sw_ul_evt_cnt_axi_r0 <= sw_ul_evt_cnt_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_ul_evt_cnt_axi_r1 <= 32'd0;
 else            sw_ul_evt_cnt_axi_r1 <= sw_ul_evt_cnt_axi_r0;
end

(* ASYNC_REG = "TRUE" *) reg [31:0] sw_delta_latch_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] sw_delta_latch_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_delta_latch_axi_r0 <= 32'd0;
 else            sw_delta_latch_axi_r0 <= sw_delta_latch_sys;
end
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) sw_delta_latch_axi_r1 <= 32'd0;
 else            sw_delta_latch_axi_r1 <= sw_delta_latch_axi_r0;
end

// =============================================================================
// AXI4-Lite Register Bank
// =============================================================================

tetra_axi_lite_regs u_axi_regs (
 // AXI bus
.s_axi_aclk (s_axi_aclk),
.s_axi_aresetn (s_axi_aresetn),
.s_axi_awaddr (s_axi_awaddr),
.s_axi_awprot (s_axi_awprot),
.s_axi_awvalid (s_axi_awvalid),
.s_axi_awready (s_axi_awready),
.s_axi_wdata (s_axi_wdata),
.s_axi_wstrb (s_axi_wstrb),
.s_axi_wvalid (s_axi_wvalid),
.s_axi_wready (s_axi_wready),
.s_axi_bresp (s_axi_bresp),
.s_axi_bvalid (s_axi_bvalid),
.s_axi_bready (s_axi_bready),
.s_axi_araddr (s_axi_araddr),
.s_axi_arprot (s_axi_arprot),
.s_axi_arvalid (s_axi_arvalid),
.s_axi_arready (s_axi_arready),
.s_axi_rdata (s_axi_rdata),
.s_axi_rresp (s_axi_rresp),
.s_axi_rvalid (s_axi_rvalid),
.s_axi_rready (s_axi_rready),
 // Status inputs (axi domain)
.sync_locked_axi (sync_locked_axi_r1),
.pll_locked_axi (1'b1), // Phase 3: assume PLL locked
.rx_fifo_empty_axi (dma_fifo_empty_sys),
.rx_fifo_full_axi (fifo_full_axi_r1),
.slot_status_axi ({lmac_stolen_sys, 3'd0}), // slot 0 steal flag
.frame_num_axi (frame_num_axi),
.slot_num_axi (slot_num_axi),
.tx_slot_axi (tx_slot_cnt_sys),
.tx_frame_axi (tx_frame_cnt_sys),
.tx_mf_axi (tx_mf_cnt_sys),
 // RX debug counters
.dbg_fe_cnt_axi (dbg_fe_cnt_sys),
.dbg_demod_cnt_axi (dbg_demod_cnt_sys),
.dbg_sync_cnt_axi (dbg_sync_packed_sys),
.dbg_sync_ul_axi (dbg_sync_ul_packed_sys),
 // IRQ inputs (axi domain)
.irq_mac_block_axi (irq_mac_block_axi),
.irq_sync_acquired_axi (irq_sync_acquired_axi),
.irq_sync_lost_axi (irq_sync_lost_axi),
.irq_crc_error_axi (irq_crc_error_axi),
.irq_rx_fifo_full_axi (irq_rx_fifo_full_axi),
 // Counter inputs (axi domain)
.dma_block_count_axi (dma_blk_cnt_axi_r1),
.crc_error_count_axi (crc_err_cnt_axi_r1),
.sync_lost_count_axi (sync_lost_cnt_axi_r1),
 // Control outputs (axi domain → PHY)
.ctrl_rx_enable_axi (ctrl_rx_enable_axi),
.ctrl_tx_enable_axi (ctrl_tx_enable_axi),
.ctrl_loopback_en_axi (ctrl_loopback_en_axi),
.ctrl_reset_counters_axi (ctrl_reset_counters_axi),
.sync_thresh_axi (sync_thresh_axi),
.colour_code_axi (colour_code_axi),
.rx_gain_axi (rx_gain_axi),
.tx_att_axi (tx_att_axi),
.irq_enable_axi (),
 // SB Payload registers (PS-writable broadcast data → TX chain)
.sb_sb1_axi (sb_sb1_data_axi_sys),
.sb_bkn2_axi (sb_bkn2_data_sys),
.sb_bb_axi (sb_bb_data_axi_sys),
.tx_test_prbs_en_axi (tx_test_prbs_en_axi),
 // NDB filler (slots 0/2/3) and MCCH (slot 1)
.ndb_block1_axi (ndb_block1_data_sys),
.ndb_block2_axi (ndb_block2_data_sys),
.mcch_block1_axi (mcch_block1_data_sys),
.mcch_block2_axi (mcch_block2_data_sys),
.bnch_block1_axi (bnch_block1_data_sys),
.bnch_block2_axi (bnch_block2_data_sys),
 // NULL-PDU register bank (Plan Stufe 4) — routed via 2-FF CDC below
.null_pdu_bits_axi (null_pdu_bits_axi_w),
 // Cell-Config registers (Plan Stufe 3.5) — feed tetra_sb1_encoder
.cell_cfg_sys_code_axi (cell_cfg_sys_code_axi_w),
.cell_cfg_sharing_mode_axi (cell_cfg_sharing_mode_axi_w),
.cell_cfg_ts_reserved_frames_axi (cell_cfg_ts_reserved_frames_axi_w),
.cell_cfg_uplane_dtx_axi (cell_cfg_uplane_dtx_axi_w),
.cell_cfg_frame18_ext_axi (cell_cfg_frame18_ext_axi_w),
.cell_cfg_neigh_cell_bc_axi (cell_cfg_neigh_cell_bc_axi_w),
.cell_cfg_cell_service_level_axi (cell_cfg_cell_service_level_axi_w),
.cell_cfg_late_entry_support_axi (cell_cfg_late_entry_support_axi_w),
.cell_cfg_mcc_axi (cell_cfg_mcc_axi_w),
.cell_cfg_mnc_axi (cell_cfg_mnc_axi_w),
 // TX TDMA timebase AXI ↔ clk_sys handshake (Plan Stufe 2)
.tx_tdma_sync_tn_axi (tx_tdma_sync_tn_axi_w),
.tx_tdma_sync_fn_axi (tx_tdma_sync_fn_axi_w),
.tx_tdma_sync_mn_axi (tx_tdma_sync_mn_axi_w),
.tx_tdma_sync_hn_axi (tx_tdma_sync_hn_axi_w),
.tx_tdma_sync_strobe_axi (tx_tdma_sync_strobe_axi_w),
.tx_tdma_state_tn_axi (tx_tdma_state_tn_axi_r1),
.tx_tdma_state_fn_axi (tx_tdma_state_fn_axi_r1),
.tx_tdma_state_mn_axi (tx_tdma_state_mn_axi_r1),
.tx_tdma_state_hn_axi (tx_tdma_state_hn_axi_r1),
.tx_tdma_state_sym_cnt_axi(tx_tdma_state_sym_cnt_axi_r1),
 // UL MAC-ACCESS PDU mailbox (Task #36/#37) — MAC parser outputs
 // resynced clk_sys → clk_axi in the CDC block below.
.ul_pdu_valid_axi (ul_pdu_valid_axi_pulse),
.ul_pdu_type_axi (ul_pdu_type_axi_r1),
.ul_fill_bit_axi (ul_fill_bit_axi_r1),
.ul_encryption_mode_axi (ul_encryption_mode_axi_r1),
.ul_addr_type_axi (ul_addr_type_axi_r1),
.ul_issi_axi (ul_issi_axi_r1),
.ul_optional_field_flag_axi (ul_optional_field_flag_axi_r1),
.ul_frag_flag_axi (ul_frag_flag_axi_r1),
.ul_reservation_req_axi (ul_reservation_req_axi_r1),
.ul_raw_info_bits_axi (ul_raw_info_bits_axi_r1),
.ul_pdu_count_axi (ul_pdu_count_axi_r1),
 // Phase 7 F.3 — decoded LLC/MLE/MM type fields (CDC'd above)
.ul_llc_pdu_type_axi (ul_llc_pdu_type_axi_r1),
.ul_mle_disc_axi (ul_mle_disc_axi_r1),
.ul_mm_pdu_type_axi (ul_mm_pdu_type_axi_r1),
.ul_scramb_init_axi (ul_scramb_init_axi_w),
 // Subscriber-Shadow indirect write window (Phase 6 M2.3 — 0x180..0x18C)
.shadow_wr_idx_axi (shadow_wr_idx_w),
.shadow_wr_data_axi (shadow_wr_data_w),
.shadow_wr_en_axi (shadow_wr_en_w),
 // Profile-Table indirect write window (Phase 6 D-rev — 0x1C0..0x1CC)
.profile_wr_idx_axi (profile_wr_idx_w),
.profile_wr_data_axi (profile_wr_data_w),
.profile_wr_en_axi (profile_wr_en_w),
 // Phase 7 F.4 — drift-free Profile-Table read port for CGI GET
.profile_rd_idx_axi (profile_rd_idx_axi_sys_w),
.profile_rd_data_axi (profile_rd_data_axi_sys_w),
 // MLE registration FSM debug counters (resynced below)
.mle_ul_req_cnt_axi (mle_ul_req_cnt_axi_r1),
.mle_accept_cnt_axi (mle_accept_cnt_axi_r1),
.mle_drop_cnt_axi (mle_drop_cnt_axi_r1),
.mle_busy_sticky_axi (mle_busy_sticky_axi_r1),
.mle_inject_cnt_axi (mle_inject_cnt_axi_r1),
.mle_clear_cnt_axi (mle_clear_cnt_axi_r1),
 // Phase X.4 — mle_detach_cnt_axi (REG_AST_DETACH_CNT) removed
 // DL-signalling scheduler config (R/W @ 0x19C) — resynced into clk_sys below
.cfg_signal_target_tn_axi(cfg_signal_target_tn_axi_w),
 // Cell Location Area (R/W @ 0x1A0) — resynced into clk_sys below
.cell_la_axi (cell_la_axi_w),
.db_policy_axi (db_policy_axi_w),
.voice_active_mask_axi (voice_active_mask_axi_w),
.slot_aach_axi (slot_aach_axi_w),

 // 2026-05-25 Mess-Infra: TS1-Stopuhr (Latches + atomar berechneter delta)
.sw_ts1_latch_axi    (sw_ts1_latch_axi_r1),
.sw_ul_latch_axi     (sw_ul_latch_axi_r1),
.sw_ul_evt_cnt_axi   (sw_ul_evt_cnt_axi_r1),
.sw_delta_latch_axi  (sw_delta_latch_axi_r1),
.voice_nub_rx_cnt_axi (voice_nub_rx_cnt_axi_r1),
.voice_relay_cnt_axi (voice_relay_cnt_axi_r1),
.voice_nub_sync_thresh_axi (voice_nub_sync_thresh_axi_w),
// 2026-05-24 RX IQ peak monitor
.rx_iq_peak_i_axi (rx_iq_peak_i_axi_r1),
.rx_iq_peak_q_axi (rx_iq_peak_q_axi_r1),
 // Phase X.4 — ast_ttl_multiframes_axi/ast_ttl_evict_cnt_axi removed (AST in SW)
 // Phase 7 F.3 — UL-Demand reassembly counters + T0 config
.reass_reassembled_cnt_axi (reass_reassembled_cnt_axi_r1),
.reass_drop_cnt_axi (reass_drop_cnt_axi_r1),
.reass_t0_frames_axi (reass_t0_frames_axi_w),
 // Phase H.6.1 — UL MAC-END-HU pipeline diagnostic counters
.ul_cont_cnt_axi (ul_cont_cnt_axi_r1),
.schhu_attempted_cnt_axi (schhu_attempted_axi_r1),
.schhu_ok_cnt_axi (schhu_ok_axi_r1),
 // DL-Signal-Queue / Pre-Reply / Scheduler diagnostic counters
 // (resynced 2-FF clk_sys → clk_axi just above).
.slotgrant_push_cnt_axi (slotgrant_push_cnt_axi_r1),
.slotgrant_drop_cnt_axi (slotgrant_drop_cnt_axi_r1),
.blck_push_cnt_axi (blck_push_cnt_axi_r1),
.blck_drop_cnt_axi (blck_drop_cnt_axi_r1),
.queue_drop_cnt_mle_axi (qdrop_mle_axi_r1),
.queue_drop_cnt_cmce_axi (qdrop_cmce_axi_r1),
.queue_drop_cnt_sds_axi (qdrop_sds_axi_r1),
.sched_pop_cnt_axi (sched_pop_cnt_axi_r1),
.sched_override_cnt_axi (sched_override_cnt_axi_r1),
 // Phase H.6.3 — AACH UL-Slot-Grant hint (PS-driven override)
.grant_consume_axi (aach_grant_consume_axi_r1),
.aach_grant_info_axi (aach_grant_info_axi_w),
.aach_grant_pending_axi (aach_grant_pending_axi_w),
 // Phase H.7 — D-NWRK-BROADCAST periodic push window
.nwrk_bcast_payload_axi (nwrk_bcast_payload_axi_w),
.nwrk_bcast_trigger_axi (nwrk_bcast_trigger_axi_w),
.nwrk_bcast_consume_axi (nwrk_bcast_consume_axi_r1),
.nwrk_bcast_cnt_axi (nwrk_bcast_cnt_axi_r1),
 // Phase H.7-AF — Auto-Fire period (multiframes; 0 = SW-Trigger mode)
.nwrk_bcast_period_mf_axi (nwrk_bcast_period_mf_axi_w),
 // Phase 1A — UL-Demand-Body Raw Mailbox extension window 0x250..0x25C
.uldbod_pending_axi_i (uldbod_pending_axi_r1),
.uldbod_drop_cnt_axi_i (uldbod_drop_cnt_axi_r1),
.uldbod_data_word_axi_i (uldbod_data_word_axi_w),
.uldbod_index_axi_o (uldbod_index_axi_w),
.uldbod_ack_trigger_axi (uldbod_ack_trigger_axi_w),
.uldbod_consume_axi (uldbod_consume_axi_r1),
 // Phase X.2 — Reply-Pull Mailbox extension window 0x220..0x230
.reply_index_axi_o (reply_index_axi_w),
.reply_wdata_axi_o (reply_wdata_axi_w),
.reply_we_axi_o (reply_we_axi_w),
.reply_go_trigger_axi_o (reply_go_trigger_w),
.reply_go_consume_axi (reply_go_consume_axi_r1),
.reply_rdata_axi_i (reply_rdata_axi_r1),
.reply_busy_axi_i (reply_busy_axi_r1),
.reply_use_sw_axi_o (reply_use_sw_axi_w),
 // Phase 7 G.8 — Voice-Filler Mailbox extension window 0x270..0x27C
.vfill_index_axi_o (vfill_index_axi_w),
.vfill_wdata_axi_o (vfill_wdata_axi_w),
.vfill_we_axi_o (vfill_we_axi_w),
.vfill_go_trigger_axi_o (vfill_go_trigger_w),
.vfill_go_consume_axi (vfill_go_consume_axi_r1),
.vfill_rdata_axi_i (vfill_rdata_axi_r1),
.vfill_valid_axi_i (vfill_valid_axi_r1),
 // Phase B — Voice-NUB-Read mailbox 0x280..0x28C
.vnub_index_axi_o (vnub_index_axi_w),
.vnub_ack_trigger_axi_o (vnub_ack_trigger_w),
.vnub_ack_consume_axi (vnub_ack_consume_axi_r1),
.vnub_rdata_axi_i (vnub_rdata_axi_r1),
.vnub_valid_axi_i (vnub_valid_axi_r1),
 // Schedule-BRAM AXI window (Plan Stufe 3 — 0x400..0x63F)
.schedule_axi_we (schedule_axi_we_w),
.schedule_axi_re (schedule_axi_re_w),
.schedule_axi_addr (schedule_axi_addr_w),
.schedule_axi_wdata (schedule_axi_wdata_w),
.schedule_axi_wstrb (schedule_axi_wstrb_w),
.schedule_axi_rdata (schedule_axi_rdata_w),
.irq_out_axi (o_irq)
);

// =============================================================================
// Subscriber-Shadow BRAM (Phase 6 M2.3)
//
// 256 × 64-bit BRAM-backed subscriber record table. Write port from the
// ARM via the AXI-Lite indirect window (0x180..0x18C in u_axi_regs).
// Lookup port reserved for the MLE registration FSM — not yet wired in
// (M2.3b lands that FSM); q_start tied 0 so the module sits idle and
// the BRAM still infers. clk_axi == clk_sys in this design so direct
// connect is safe.
// =============================================================================
// Phase X.4 — mle_profile_rd_idx_w / mf_global_cnt_sys removed (AST in SW).
//
// `mf_pulse_sys` is the 1-cycle pulse on every multiframe edge, kept as
// the auto-fire clock for the D-NWRK-BROADCAST scheduler.
reg [5:0] tx_mf_cnt_sys_prev;
wire mf_pulse_sys = (tx_mf_cnt_sys != tx_mf_cnt_sys_prev);
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys)
 tx_mf_cnt_sys_prev <= 6'd1;
 else
 tx_mf_cnt_sys_prev <= tx_mf_cnt_sys;
end

// Phase 6 B — U-ITSI-DETACH trigger (MM PDU type 1, MLE=MM, LLC=BL-DATA)
wire ul_itsi_detach_sys =
 ul_pdu_valid_sys &&
 ul_llc_is_bl_data_w &&
 ul_llc_is_mle_mm_w &&
 (ul_llc_mm_pdu_type_w == 4'h1);

// =============================================================================
// Phase X.4 — EntityTable, ProfileTable and Active-Session Table removed.
// All three migrated to ARM SW (sw/tetra_db.[ch] + sw/tetra_attach_daemon.c).
// AXI-Lite indirect-write windows 0x180..0x18C, 0x1C0..0x1CC remain in
// tetra_axi_lite_regs.v as compatibility no-ops; their write strobes have
// no consumer in PL after this refactor. Phase X.5 will retire those
// windows together with the legacy Pre-Reply path.
// =============================================================================

// =============================================================================
// MLE Registration FSM (Phase 6 M2.3b)
//
// Consumes UL MAC-ACCESS PDUs from the RX chain, allocates/reuses a slot
// in the active-session-table, builds a D-LOCATION-UPDATE-ACCEPT PDU
// (124 bit) + SCH/HD-encodes it (216 bit), and hands the result to the
// slot_content_mux for one-shot injection on TN=1.
//
// The MVP path accepts every UL MAC-ACCESS pulse. Filtering by PDU type
// (MM Location-Update only) can be layered in later via a gate on
// ul_req_valid; for initial bring-up an MS only transmits RA bursts when
// it wants to register, so acting on any pulse is safe.
//
// cfg_la comes from REG_CELL_LA (0x1A0) via cell_la_sys_r1 so BNCH SYSINFO
// (packed in SW from info.la) and D-LOC-UPDATE-ACCEPT (stamped by the MLE
// FSM) share the same LA value — mismatching these two used to cause the
// MS to silently reject the registration response. ul_la currently ties
// to 14'd0 because the MAC-ACCESS parser does not yet extract the LA field
// from the U-REGISTER/U-LOCATION-UPDATE payload (TODO Bug #3: add LA
// extraction in rtl/rx/tetra_mac_access_parser.v and wire through
// tetra_rx_chain as ul_location_area_sys).
// cfg_scramble_init is packed directly
// from the RTL cell-config regs so the DL SCH/HD response scrambling is
// guaranteed bit-identical to the AACH/BSCH-paired SCH/HD TX chain
// (see u_aach_encoder which derives the same pack internally). The
// packed seed — (MCC<<22)|(MNC<<8)|(CC<<2)|3 — is the cell-specific
// downlink scrambler init from ETSI §8.2.5.2 and matches the UL seed
// numerically when SW programs REG_UL_SCRAMB_INIT with the same formula.
// =============================================================================
// Real 24-bit ISSI from the corrected MAC-ACCESS parser. Used to address
// the D-LOC-UPDATE-ACCEPT reply so the MS recognises the response as its
// own (the previous 10-bit short_ssi was bit-misaligned and produced
// ssi=523 for every Motorola MS — see commit `feat(ul-parser):` for fix).
//
// Phase H.3.1 (2026-05-01) — MLE trigger moved from single-burst-bypass
// hack (mm=2/4 on Frag-1) to the reassembly + IE-parse path. The old
// hack fired BEFORE the reassembled MM body had been walked by the IE
// parser, so `lat_demand_*` were not populated when the FSM reached
// S_GSSI_QUERY_DEFAULT_DONE → MS-Wunsch-GSSI was always ignored
// (fallback to Profile-Default). The new trigger fires only when:
// - reassembly completed and IE parser finished without overrun
// (`iep_parse_done_sys & iep_parse_ok_sys`)
// - the GILD walker extracted a valid GroupIdentityLocationDemand
// (`iep_gild_valid_sys`)
// On the same clk edge the MLE-FSM's parallel `if (demand_parsed_valid)`
// block latches `lat_demand_ssi/count/gssi/class`, so the MS-Wunsch
// is available by the time the FSM reaches S_GSSI_LOOP_NEXT (many
// cycles later). SSI + loc_upd_type also come from the parser
// outputs to avoid stale values from a later unrelated burst.
// Phase H.3.2 (2026-05-02) — REVERT von H.3.1: MLE trigger zurück auf
// Frag-1-Pulse statt Reassembly+IE-Parse-Done. Begründung:
// Per -Spec (`removed-memory`) sendet die
// BS Pre-Reply LI=7 AL-SETUP exakt 1 Frame nach Frag-1-Empfang —
// BEVOR Frag-2 überhaupt gesendet wurde. Die MS sendet Frag-2 erst
// NACHDEM sie im DL die Pre-Reply (AACH=0x0009) gesehen hat.
// H.3.1 hat den Trigger auf "post-reassembly" verschoben → Pre-Reply
// feuert nie, weil ohne Pre-Reply kein Frag-2, ohne Frag-2 kein
// reassembly → MS retried Frag-1 endlos (verifiziert über UL-WAV
// 2026-05-02: 51 Frag-1 Bursts, 0 Frag-2 in 31s).
//
// AL-SETUP enthält keinen MM-Body — nur SSI nötig, das die MAC-ACCESS-
// Parser auf der Frag-1-Pulse-Cycle bereits liefert. ACCEPT-Pfad nutzt
// weiterhin den parallelen `demand_parsed_valid`-Latch (FSM zeile 773),
// der `lat_demand_*` mit IEP-Output befüllt sobald Frag-2 reassembliert
// und IE-geparst ist. Falls Frag-2 nicht rechtzeitig ankommt, fällt
// ACCEPT auf Profile-Default-GSSI zurück (= profile0_m2_guard).
wire mle_ul_req_valid_w = frag1_pulse_w;
wire [23:0] mle_ul_ssi_w = ul_issi_sys;
wire [2:0] mle_ul_loc_upd_type_w = ul_loc_upd_type_sys;
wire mle_ul_use_l2sig_w = 1'b0;

// DL scrambler seed pack — identical to tetra_aach_encoder.v line 127.
wire [31:0] mle_dl_scramb_init_sys = {cell_cfg_mcc_sys_r1,
 cell_cfg_mnc_sys_r1,
 colour_code_sys_r1,
 2'b11};

tetra_mle_registration_fsm u_mle_registration_fsm (
.clk (clk_sys),
.rst_n (rst_n_sys),
 // UL request
.ul_req_valid (mle_ul_req_valid_w),
.ul_addr_type (ul_addr_type_sys),
.ul_ssi (mle_ul_ssi_w),
 // TODO Bug #3: wire ul_location_area_sys from the MAC-ACCESS parser
 // once the LA field is extracted from U-REGISTER/U-LOCATION-UPDATE.
 // Until then we feed 14'd0 so the MLE FSM treats every request as a
 // bare registration attempt (no LA-match fast-path).
.ul_la (14'd0),
 // Location update type from MS's U-LOC-UPDATE-DEMAND (ETSI §16.10.37).
 // Parser extracts bits [27:30) of the 92-bit MAC-ACCESS payload; MLE
 // FSM echoes this into the Location-update-accept-type field of the
 // D-LOC-UPDATE-ACCEPT so the MS recognises the reply (Bug #8).
.ul_loc_upd_type (mle_ul_loc_upd_type_w),
.ul_use_l2sig (mle_ul_use_l2sig_w),
 // Option B (commit 6) — MS N(S) from UL parser for auto-BL-ACK.
.ul_llc_is_bl_data(ul_llc_is_bl_data_w),
.ul_llc_ns_valid (ul_llc_ns_valid_w),
.ul_llc_ns (ul_llc_ns_w),
 // UL LLC BL-ACK — M1+M4 post-accept flow. Parser pulses bl_ack_valid
 // when a MAC-ACCESS frame carries a BL-ACK (bl_pdu_type=11 at LLC
 // offset). MLE FSM matches against lat_ssi + outstanding_ns to close
 // the acknowledged BL-DATA transaction. bl_ack_issi carries the full
 // 24-bit ISSI from the BL-ACK frame for the per-session match.
.bl_ack_valid (ul_bl_ack_valid_sys),
.bl_ack_nr (ul_bl_ack_nr_sys),
.bl_ack_issi (ul_issi_sys),
 // Timeslot tick for the T251 retransmit timer (M3 — 16 slots to
 // timeout, N252=3 retries). tx_slot_pulse_sys pulses once per slot.
.slot_pulse (tx_tdma_state_slot_pulse_sys),
 // Cell config — REG_CELL_LA (0x1A0), 2-FF resynced from clk_axi.
 // MUST match the LA value BNCH SYSINFO broadcasts (SW writes
 // tetra_hal.c info.la into this register at boot).
.cfg_la (cell_la_sys_r1),
.cfg_scramble_init(mle_dl_scramb_init_sys),
.cfg_mcch_tn (cfg_mcch_tn_sys_r1),
 // D-LOC-UPDATE-ACCEPT MM-Body Energy-Saving-Info — defaults to
 // StayAlive (14'h0000 → mode=000, FN/MN=0). Phase X.7 cleanup:
 // cfg_address_extension / cfg_subscriber_class are gone (only the
 // legacy 124-bit pdu_bits encoder path consumed them).
.cfg_energy_saving_info(14'h0000),
 // Phase X.4 — EntityTable / ProfileTable / Active-Session Table ports
 // removed. All Multi-Lookup logic moved to ARM SW (sw/tetra_db.[ch] +
 // sw/tetra_attach_daemon.c); the FSM is now a thin SW-pulse trigger.
 //
 // Phase B — Detach is now a no-op telemetry stub (counter only). SW
 // owns AST clear in Phase X.5.
.ul_detach_valid (ul_itsi_detach_sys),
.ul_detach_ssi (ul_issi_sys),
 // DL queue-request port — emits full 432-bit SCH/F codeword, scheduler pops
.req_valid (mle_req_valid_w),
.req_coded_bits (mle_req_coded_bits_w),
.req_pdu_type (mle_req_pdu_type_w),
.req_target_tn (mle_req_target_tn_w),
.req_second_pdu_present (mle_req_second_pdu_present_w),
.req_second_pdu_nr (mle_req_second_pdu_nr_w),
.busy (mle_busy_w),
.accept_pulse (mle_accept_pulse_w),
.drop_pulse (mle_drop_pulse_w),
.ack_pulse (mle_ack_pulse_w),
.retransmit_pulse (mle_retransmit_pulse_w),
.lost_pulse (mle_lost_pulse_w),
.detach_pulse (mle_detach_pulse_w),
 // Phase X.2 — Reply-Pull Mailbox pass-through to u_dloc fields.
 // Phase X.4: SW path is primary; the encoder consumes the staged
 // ACCEPT body fields directly. mb_go_pulse is the FSM trigger.
 // Phase X.7 cleanup: use_sw_body input gone — the FPGA mux that
 // toggled between SW-mailbox and (long-dead) FSM-internal latches
 // has been removed. REG_REPLY_USE_SW @ 0x230 stays as a R/W status
 // bit for backward-compat with the SW daemon, but no longer wires
 // into MLE-FSM.
.mb_ssi (mb_ssi_sys_w),
.mb_la (mb_la_sys_w),
.mb_addr_type (mb_addr_type_sys_w),
 // Klasse 2 (2026-05-24) — UMt aus Reply-Mailbox W2[8:3].
.mb_usage_marker (mb_usage_marker_sys_w),
.mb_chan_alloc_ts_bitmap (mb_chan_alloc_ts_bitmap_sys_w),
.mb_result (mb_result_sys_w),
 // Bug-001 fix — Reply-Pull-Mailbox W3[4:2] carries MS demand
 // location_update_type echoed by SW. Encoder consumes via mb_loc_acc_type.
.mb_loc_acc_type (mb_loc_acc_type_sys_w),
.mb_gila_gssi (mb_gila_gssi_sys_w),
.mb_gila_class (mb_gila_class_sys_w),
.mb_gila_lifetime (mb_gila_lifetime_sys_w),
.mb_gila_present (mb_gila_present_sys_w),
.mb_encryption (mb_encryption_sys_w),
.mb_auth_result (mb_auth_result_sys_w),
.mb_go_pulse (mb_go_pulse_sys_w),
 // Phase Y.2 — raw-mode bypass (Variante A) for mm=11 D-ATTACH-DETACH-
 // GRP-ID-ACK. raw_mode_flag=0 => mm=2 ACCEPT path bit-identical.
.mb_raw_mode_flag (mb_raw_mode_flag_sys_w),
.mb_raw_mm_bits (mb_raw_mm_bits_sys_w),
.mb_raw_mm_len (mb_raw_mm_len_sys_w),
.mb_raw_ns (mb_raw_ns_sys_w),
.mb_raw_nr (mb_raw_nr_sys_w),
.mb_raw_mle_pd (mb_raw_mle_pd_sys_w),
 // Phase X.6 — Build-request to shared tetra_dl_pdu_builder via arbiter.
.accept_build_req (mle_accept_build_req_w),
.accept_build_ssi (mle_accept_build_ssi_w),
.accept_build_addr_type (mle_accept_build_addr_type_w),
 // Klasse 2 (2026-05-24) — UMt → arbiter → dl_pdu_builder.req_usage_marker.
.accept_build_usage_marker (mle_accept_build_usage_marker_w),
.accept_build_chan_alloc_ts_bitmap (mle_accept_build_chan_alloc_ts_bitmap_w),
.accept_build_llc_pdu_type (mle_accept_build_llc_pdu_type_w),
.accept_build_random_access_flag (mle_accept_build_random_access_flag_w),
.accept_build_mm_pdu_bits (mle_accept_build_mm_pdu_bits_w),
.accept_build_mm_pdu_len_bits (mle_accept_build_mm_pdu_len_bits_w),
.accept_build_scramble_init (mle_accept_build_scramble_init_w),
.accept_build_ns (mle_accept_build_ns_w),
.accept_build_nr (mle_accept_build_nr_w),
.accept_build_mle_pd (mle_accept_build_mle_pd_w),
.accept_build_aach_pattern (mle_accept_build_aach_pattern_w),
.accept_build_done (dl_pdu_done_to_mle_w),
.accept_build_coded (dl_pdu_coded_w)
);

// =============================================================================
// DL-signalling queue (Phase 6 M2.3b) — 4-entry strict-priority queue.
// MLE writes full 432-bit SCH/F codewords; CMCE/SDS ports tied off in MVP.
// Drop-newest on overflow; losers on same-cycle producer collisions count
// toward drop_cnt. Consumer is tetra_dl_signal_scheduler (one pop per frame).
// =============================================================================
wire [3:0] sched_active_sys_w;
wire [3:0] sched_reply_active_by_content_w = {
 (sched_blk1_tn3_sys_w != null_pdu_bits_sys_r1),
 (sched_blk1_tn2_sys_w != null_pdu_bits_sys_r1),
 (sched_blk1_tn1_sys_w != null_pdu_bits_sys_r1),
 (sched_blk1_tn0_sys_w != null_pdu_bits_sys_r1)
};

tetra_dl_signal_queue #(
.DEPTH(4)
) u_dl_signal_queue (
.clk (clk_sys),
.rst_n (rst_n_sys),
 // MLE producer — muxed (MLE-FSM Final-ACCEPT priority over Phase X.5b
 // SlotGrant Pre-Reply, see mux just above the queue instantiation).
.wr_mle_valid (mle_slot_wr_valid_w),
.wr_mle_coded (mle_slot_wr_coded_w),
.wr_mle_pdu_type (mle_slot_wr_pdu_type_w),
.wr_mle_target_tn (mle_slot_wr_target_tn_w),
.wr_mle_aach_pattern (mle_slot_wr_aach_pattern_w), // Phase Z.2
 // Option B second_pdu telemetry (commit 6): propagate MLE-FSM's
 // req_second_pdu_* so the queue entry carries the BL-ACK-present
 // flag + nr for downstream ILA / AXI visibility. SlotGrant path
 // has no concat-second-PDU → the mux above zeros these when MLE
 // inactive.
.wr_mle_second_pdu_present (mle_slot_wr_second_pdu_present_w),
.wr_mle_second_pdu_nr (mle_slot_wr_second_pdu_nr_w),
 // CMCE producer — Phase H.7 D-NWRK-BROADCAST periodic push
.wr_cmce_valid (nwrk_bcast_push_valid_sys_w),
.wr_cmce_coded (nwrk_bcast_push_coded_sys_w),
.wr_cmce_pdu_type (nwrk_bcast_push_pdu_type_sys_w),
.wr_cmce_target_tn(nwrk_bcast_push_target_tn_sys_w),
.wr_cmce_aach_pattern (`PDUC_NWRK_BCAST_AACH), // Phase Z.3 —: 0x0249 idle
 // SDS producer — repurposed for Phase X.5 Pre-Reply BL-ACK Mini-FSM.
 // The module pushes a SCH/HD-coded BL-ACK on every Frag-1 pulse so the
 // attaching MS sees an ACK on the Pre-Reply slot (1 frame after Frag-1)
 // and proceeds to send Frag-2. See rtl/lmac/tetra_pre_reply_blck.v +
 // memory `project_h32_attach_breakthrough.md` (Pre-Reply gap is the
 // remaining Restdrift in Cycle 2-3 reproducibility).
.wr_sds_valid (pre_reply_blck_valid_sys_w),
.wr_sds_coded (pre_reply_blck_coded_sys_w),
.wr_sds_pdu_type (pre_reply_blck_pdu_type_sys_w),
.wr_sds_target_tn (pre_reply_blck_target_tn_sys_w),
.wr_sds_aach_pattern (`PDUC_BL_ACK_POST_FRAG2_AACH), // Phase Z.3 —: 0x0249 idle
 // Scheduler consumer
.pop (sched_pop_w),
.head_valid (queue_head_valid_w),
.head_coded (queue_head_coded_w),
.head_pdu_type (queue_head_pdu_type_w),
.head_target_tn (queue_head_target_tn_w),
.head_prio (queue_head_prio_w),
.head_aach_pattern (queue_head_aach_pattern_w), // Phase Z.2
.head_second_pdu_present (queue_head_second_pdu_present_w),
.head_second_pdu_nr (queue_head_second_pdu_nr_w),
 // Status
.depth_valid_mask (queue_depth_mask_w),
.depth_count (queue_depth_count_w),
.drop_cnt (queue_drop_cnt_w),
.drop_cnt_mle (queue_drop_cnt_mle_w),
.drop_cnt_cmce (queue_drop_cnt_cmce_w),
.drop_cnt_sds (queue_drop_cnt_sds_w)
);

// =============================================================================
// DL-signalling scheduler (Phase 6 M2.3b) — triggers at slot_pulse && tn==3
// (identical edge to the schedule-BRAM refresh). Pops at most one PDU per
// frame and presents a registered override bundle that is stable for all
// four slots of the NEXT frame. Zero race with burst_mux capture.
// =============================================================================
tetra_dl_signal_scheduler u_dl_signal_scheduler (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.tn_sys (tx_tdma_state_tn_sys),
.slot_pulse_sys (tx_tdma_state_slot_pulse_sys),
 // Queue head + pop (Phase Z.13: pop fires at slot_pulse@target_tn,
 // not at slot_pulse@tn==3. Module no longer latches a bundle.)
.pop_sys (sched_pop_w),
.head_valid_sys (queue_head_valid_w),
.head_coded_sys (queue_head_coded_w),
.head_pdu_type_sys (queue_head_pdu_type_w),
.head_target_tn_sys (queue_head_target_tn_w),
.head_prio_sys (queue_head_prio_w),
.head_second_pdu_present_sys (queue_head_second_pdu_present_w),
.head_second_pdu_nr_sys (queue_head_second_pdu_nr_w),
.popped_second_pdu_present_sys (popped_second_pdu_present_w),
.popped_second_pdu_nr_sys (popped_second_pdu_nr_w),
 // Idle default sources (SW-driven banks, CDC-synced)
 // null_pdu_bits 216-bit SCH/HD-coded NULL-PDU (signalling filler)
 // sig_companion 216-bit companion half for BKN2 of SCH/HD slots
 // — same SYSINFO/BNCH content used for NDB2 broadcast.
.null_pdu_bits_sys (null_pdu_bits_sys_r1),
.sig_companion_sys (ndb_block2_data_sys),
 // Per-TN signalling bundle → slot_content_mux (combinational from head)
.sched_blk1_tn0_sys (sched_blk1_tn0_sys_w),
.sched_blk2_tn0_sys (sched_blk2_tn0_sys_w),
.sched_blk1_tn1_sys (sched_blk1_tn1_sys_w),
.sched_blk2_tn1_sys (sched_blk2_tn1_sys_w),
.sched_blk1_tn2_sys (sched_blk1_tn2_sys_w),
.sched_blk2_tn2_sys (sched_blk2_tn2_sys_w),
.sched_blk1_tn3_sys (sched_blk1_tn3_sys_w),
.sched_blk2_tn3_sys (sched_blk2_tn3_sys_w),
.sched_ndb2_sys (sched_ndb2_sys_w),
.sched_active_sys (sched_active_sys_w),
 // Stats
.override_cnt_sys (sig_override_cnt_w),
.pop_cnt_sys (sig_pop_cnt_w)
);

// =============================================================================
// MLE FSM debug counters (Phase 6 M2.3b) — clk_sys free-running 16-bit
// counters on ul_req / accept / drop, plus a sticky busy flag (set when
// FSM ever left S_IDLE). Per-bit 2-FF resynced into clk_axi; counters
// are slow-changing so byte-tearing is tolerable for diagnostic use.
// =============================================================================
reg [15:0] mle_ul_req_cnt_sys;
reg [15:0] mle_accept_cnt_sys;
reg [15:0] mle_drop_cnt_sys;
reg mle_busy_sticky_sys;

// Post-refactor STATS_C repurpose:
// inject_cnt → scheduler override_cnt (= queue pops delivered to the mux)
// clear_cnt → queue drop_cnt (overflow / producer-arbitration losses)
// Both are produced inside their respective modules (saturating 16-bit).
wire [15:0] mle_inject_cnt_sys = sig_override_cnt_w;
wire [15:0] mle_clear_cnt_sys = queue_drop_cnt_w;

// Phase X.4 — detach + TTL-evict counters removed (AST/Detach moved to SW).
// detach_pulse output from MLE-FSM still toggles mle_detach_pulse_w for
// optional ILA observability, but no longer feeds an AXI-mirrored counter.

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 mle_ul_req_cnt_sys <= 16'd0;
 mle_accept_cnt_sys <= 16'd0;
 mle_drop_cnt_sys <= 16'd0;
 mle_busy_sticky_sys <= 1'b0;
 end else begin
 if (mle_ul_req_valid_w) mle_ul_req_cnt_sys <= mle_ul_req_cnt_sys + 16'd1;
 if (mle_accept_pulse_w) mle_accept_cnt_sys <= mle_accept_cnt_sys + 16'd1;
 if (mle_drop_pulse_w) mle_drop_cnt_sys <= mle_drop_cnt_sys + 16'd1;
 if (mle_busy_w) mle_busy_sticky_sys <= 1'b1;
 end
end

(* ASYNC_REG = "TRUE" *) reg [15:0] mle_ul_req_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_ul_req_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_accept_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_accept_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_drop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_drop_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg mle_busy_sticky_axi_r0;
(* ASYNC_REG = "TRUE" *) reg mle_busy_sticky_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_inject_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_inject_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_clear_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] mle_clear_cnt_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 mle_ul_req_cnt_axi_r0 <= 16'd0;
 mle_ul_req_cnt_axi_r1 <= 16'd0;
 mle_accept_cnt_axi_r0 <= 16'd0;
 mle_accept_cnt_axi_r1 <= 16'd0;
 mle_drop_cnt_axi_r0 <= 16'd0;
 mle_drop_cnt_axi_r1 <= 16'd0;
 mle_busy_sticky_axi_r0 <= 1'b0;
 mle_busy_sticky_axi_r1 <= 1'b0;
 mle_inject_cnt_axi_r0 <= 16'd0;
 mle_inject_cnt_axi_r1 <= 16'd0;
 mle_clear_cnt_axi_r0 <= 16'd0;
 mle_clear_cnt_axi_r1 <= 16'd0;
 end else begin
 mle_ul_req_cnt_axi_r0 <= mle_ul_req_cnt_sys;
 mle_ul_req_cnt_axi_r1 <= mle_ul_req_cnt_axi_r0;
 mle_accept_cnt_axi_r0 <= mle_accept_cnt_sys;
 mle_accept_cnt_axi_r1 <= mle_accept_cnt_axi_r0;
 mle_drop_cnt_axi_r0 <= mle_drop_cnt_sys;
 mle_drop_cnt_axi_r1 <= mle_drop_cnt_axi_r0;
 mle_busy_sticky_axi_r0 <= mle_busy_sticky_sys;
 mle_busy_sticky_axi_r1 <= mle_busy_sticky_axi_r0;
 mle_inject_cnt_axi_r0 <= mle_inject_cnt_sys;
 mle_inject_cnt_axi_r1 <= mle_inject_cnt_axi_r0;
 mle_clear_cnt_axi_r0 <= mle_clear_cnt_sys;
 mle_clear_cnt_axi_r1 <= mle_clear_cnt_axi_r0;
 end
end

// =============================================================================
// Phase H.6.1 — UL MAC-END-HU pipeline diagnostic counters
//
// Three free-running 16-bit clk_sys counters, 2-FF resynced to clk_axi.
// Used to localise where MAC-END-HU bursts get dropped (Bug 1):
//
// ul_continuation_count_sys (parser, existing) → REG_UL_CONT_CNT @0x1B8
// schhu_attempted_sys (decoder, every info_valid) → REG_SCHHU_VALID_CNT @0x1BC
// schhu_ok_sys (decoder, info_valid + crc) → REG_SCHHU_CRC_CNT @0x1F0
//
// All three are free-running 16-bit (wrap on overflow) — sufficient for
// short live-test sweeps (~65k events ≈ ~30 min @ 36k bursts/min worst-
// case). Reset only via rst_n_sys; per-event resets via CTRL[3] would
// require touching the decoder/parser which is outside H.6.1 scope.
// =============================================================================
(* ASYNC_REG = "TRUE" *) reg [15:0] ul_cont_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] ul_cont_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] schhu_attempted_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] schhu_attempted_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] schhu_ok_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] schhu_ok_axi_r1;

always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 ul_cont_cnt_axi_r0 <= 16'd0;
 ul_cont_cnt_axi_r1 <= 16'd0;
 schhu_attempted_axi_r0 <= 16'd0;
 schhu_attempted_axi_r1 <= 16'd0;
 schhu_ok_axi_r0 <= 16'd0;
 schhu_ok_axi_r1 <= 16'd0;
 end else begin
 ul_cont_cnt_axi_r0 <= ul_continuation_count_sys;
 ul_cont_cnt_axi_r1 <= ul_cont_cnt_axi_r0;
 schhu_attempted_axi_r0 <= schhu_attempted_sys;
 schhu_attempted_axi_r1 <= schhu_attempted_axi_r0;
 schhu_ok_axi_r0 <= schhu_ok_sys;
 schhu_ok_axi_r1 <= schhu_ok_axi_r0;
 end
end

// =============================================================================
// Phase H.6.3 — AACH UL-Slot-Grant CDC
// AXI-side reg drives info[13:0] + pending → 2-FF resync to clk_sys for the
// AACH encoder. Encoder consume pulse → 2-FF resync clk_sys → clk_axi.
// =============================================================================
wire [13:0] aach_grant_info_axi_w;
wire aach_grant_pending_axi_w;

(* ASYNC_REG = "TRUE" *) reg [13:0] aach_grant_info_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [13:0] aach_grant_info_sys_r1;
(* ASYNC_REG = "TRUE" *) reg aach_grant_pending_sys_r0;
(* ASYNC_REG = "TRUE" *) reg aach_grant_pending_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 aach_grant_info_sys_r0 <= 14'd0;
 aach_grant_info_sys_r1 <= 14'd0;
 aach_grant_pending_sys_r0 <= 1'b0;
 aach_grant_pending_sys_r1 <= 1'b0;
 end else begin
 aach_grant_info_sys_r0 <= aach_grant_info_axi_w;
 aach_grant_info_sys_r1 <= aach_grant_info_sys_r0;
 aach_grant_pending_sys_r0 <= aach_grant_pending_axi_w;
 aach_grant_pending_sys_r1 <= aach_grant_pending_sys_r0;
 end
end

wire aach_grant_consume_sys_w;
(* ASYNC_REG = "TRUE" *) reg aach_grant_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg aach_grant_consume_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 aach_grant_consume_axi_r0 <= 1'b0;
 aach_grant_consume_axi_r1 <= 1'b0;
 end else begin
 aach_grant_consume_axi_r0 <= aach_grant_consume_sys_w;
 aach_grant_consume_axi_r1 <= aach_grant_consume_axi_r0;
 end
end

// =============================================================================
// Phase H.7 — D-NWRK-BROADCAST periodic push: CDC + Modul-Instance
//
// AXI side (clk_axi):
// nwrk_bcast_payload_axi_w — 432-bit shadow built by SW via INDEX/DATA
// nwrk_bcast_trigger_axi_w — W1S, set by SW write to REG_NWRK_BCAST_TRIGGER
// nwrk_bcast_consume_axi_r1 — pulse, cleared by axi_lite_regs.bcast_trigger
// nwrk_bcast_cnt_axi_r1 — push count for SW readback
//
// clk_sys side: tetra_dl_nwrk_broadcast consumes the trigger, pulses
// wr_cmce_valid into the DL-Signal-Queue, increments push_cnt_sys.
// =============================================================================
wire [431:0] nwrk_bcast_payload_axi_w;
wire nwrk_bcast_trigger_axi_w;
wire [4:0] nwrk_bcast_period_mf_axi_w;

(* ASYNC_REG = "TRUE" *) reg [431:0] nwrk_bcast_payload_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [431:0] nwrk_bcast_payload_sys_r1;
(* ASYNC_REG = "TRUE" *) reg nwrk_bcast_trigger_sys_r0;
(* ASYNC_REG = "TRUE" *) reg nwrk_bcast_trigger_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [4:0] nwrk_bcast_period_mf_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [4:0] nwrk_bcast_period_mf_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 nwrk_bcast_payload_sys_r0 <= 432'd0;
 nwrk_bcast_payload_sys_r1 <= 432'd0;
 nwrk_bcast_trigger_sys_r0 <= 1'b0;
 nwrk_bcast_trigger_sys_r1 <= 1'b0;
 nwrk_bcast_period_mf_sys_r0 <= 5'd10;
 nwrk_bcast_period_mf_sys_r1 <= 5'd10;
 end else begin
 nwrk_bcast_payload_sys_r0 <= nwrk_bcast_payload_axi_w;
 nwrk_bcast_payload_sys_r1 <= nwrk_bcast_payload_sys_r0;
 nwrk_bcast_trigger_sys_r0 <= nwrk_bcast_trigger_axi_w;
 nwrk_bcast_trigger_sys_r1 <= nwrk_bcast_trigger_sys_r0;
 nwrk_bcast_period_mf_sys_r0 <= nwrk_bcast_period_mf_axi_w;
 nwrk_bcast_period_mf_sys_r1 <= nwrk_bcast_period_mf_sys_r0;
 end
end

wire nwrk_bcast_push_valid_sys_w;
wire [431:0] nwrk_bcast_push_coded_sys_w;
wire [1:0] nwrk_bcast_push_pdu_type_sys_w;
wire [1:0] nwrk_bcast_push_target_tn_sys_w;
wire [15:0] nwrk_bcast_push_cnt_sys_w;

tetra_dl_nwrk_broadcast u_dl_nwrk_broadcast (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.payload_sys (nwrk_bcast_payload_sys_r1),
.trigger_sys (nwrk_bcast_trigger_sys_r1),
.cfg_mcch_tn_sys (cfg_mcch_tn_sys_r1),
.cfg_period_mf (nwrk_bcast_period_mf_sys_r1),
.mf_pulse_sys (mf_pulse_sys),
.wr_cmce_valid_sys (nwrk_bcast_push_valid_sys_w),
.wr_cmce_coded_sys (nwrk_bcast_push_coded_sys_w),
.wr_cmce_pdu_type_sys (nwrk_bcast_push_pdu_type_sys_w),
.wr_cmce_target_tn_sys(nwrk_bcast_push_target_tn_sys_w),
.push_cnt_sys (nwrk_bcast_push_cnt_sys_w)
);

// =============================================================================
// Phase X.5 — Pre-Reply BL-ACK Mini-FSM (post-Frag-2 BL-ACK = Step 4)
//
// Trigger: `mle_demand_parsed_valid_sys = iep_parse_done_sys & iep_parse_ok_sys`
// — fires AFTER reassembly of Frag-1+Frag-2 has completed and the IE parser
// has walked the MM body. This is Step 4 of the ITSI-Attach sequence
// (MS Frag-1 → BS slot-grant [Step 2, see u_pre_reply_slotgrant below] →
// MS Frag-2 → BS BL-ACK [Step 4, this module] → MS Frag-3 → BS ACCEPT).
//
// On every pulse the FSM builds a 124-bit BL-ACK PDU (43-bit MAC + 5-bit
// LLC, zero-padded), SCH/HD-encodes it to 216 bits, and pushes via the
// DL-Signal-Queue's SDS slot. Scheduler grabs it on the next frame
// boundary and delivers it on `cfg_mcch_tn_sys_r1`.
//
// Phase X.5 (initial) was triggered on `frag1_pulse_w` — that conflated
// Step 2 (slot-grant) with Step 4 (BL-ACK) and left no BL-ACK after
// Frag-2. The spec-conformant split is now: tetra_pre_reply_slotgrant.v
// fires on Frag-1 (Step 2), this module fires on reassembly-done (Step 4).
//
// Memory ref: `project_h32_attach_breakthrough.md` +
// `removed-memory`.
// =============================================================================
wire pre_reply_blck_valid_sys_w;
wire [431:0] pre_reply_blck_coded_sys_w;
wire [1:0] pre_reply_blck_pdu_type_sys_w;
wire [1:0] pre_reply_blck_target_tn_sys_w;
// pre_reply_blck_{push,drop}_cnt_sys_w forward-declared earlier (CDC block).

// =============================================================================
// Shared SCH/HD encoder (2026-05-17 Util-Refactor)
// Wird sowohl von u_pre_reply_blck (ch1, BL-ACK) als auch von
// u_pre_reply_slotgrant (ch0, Priorität) genutzt. Arbiter intern.
// Spart ~600 LUT vs frühere Doppel-Instanz.
// =============================================================================
wire sg_enc_req_w;
wire [123:0] sg_enc_info_w;
wire [31:0] sg_enc_scramb_w;
wire sg_enc_done_w;
wire [215:0] sg_enc_coded_w;

wire blck_enc_req_w;
wire [123:0] blck_enc_info_w;
wire [31:0] blck_enc_scramb_w;
wire blck_enc_done_w;
wire [215:0] blck_enc_coded_w;

tetra_sch_hd_shared u_sch_hd_shared (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.ch0_req (sg_enc_req_w),
.ch0_info_bits (sg_enc_info_w),
.ch0_scramble_init(sg_enc_scramb_w),
.ch0_done (sg_enc_done_w),
.ch0_coded (sg_enc_coded_w),
.ch1_req (blck_enc_req_w),
.ch1_info_bits (blck_enc_info_w),
.ch1_scramble_init(blck_enc_scramb_w),
.ch1_done (blck_enc_done_w),
.ch1_coded (blck_enc_coded_w)
);

tetra_pre_reply_blck u_pre_reply_blck (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Reassembly-Done trigger (Step 4 — post-Frag-2 BL-ACK).
 // Y.1.fix: feuert für mm=2 (ITSI-Attach) UND mm=7 (Group-Attach).
 // Memory removed-memory zeigt für beide
 // mm-Types das gleiche 5-Schritt-Pattern: Frag-1 → Frag-2 →
 // Pre-Reply BL-ACK LI=7 → MS-Frag-3 BL-ACK → finaler ACK.
 //
 // Phase 1E-B (2026-05-20): triggert direkt auf reass_valid_sys
 // (= Frag-2-Done), nicht mehr auf den entfernten IE-Parser. Effekt
 // ist identisch — Parser brauchte nur ein paar Takte, beide Pfade
 // landen im gleichen Frame.
.trigger_valid (reass_valid_sys & ((reass_mm_type_sys == 4'd2) |
                                    (reass_mm_type_sys == 4'd7))),
.ul_ssi (ul_issi_sys),
 // Target TN = MCCH slot (where the MS expects the BL-ACK).
.cfg_mcch_tn (cfg_mcch_tn_sys_r1),
 // Cell DL scrambler seed — same pack as MLE-FSM and AACH (ref-konform).
.cfg_scramble_init (mle_dl_scramb_init_sys),
 // Shared SCH/HD encoder (ch1)
.ext_enc_req (blck_enc_req_w),
.ext_info_bits (blck_enc_info_w),
.ext_scramble_init (blck_enc_scramb_w),
.ext_enc_done (blck_enc_done_w),
.ext_enc_coded (blck_enc_coded_w),
 // DL-Signal-Queue producer (SDS slot)
.wr_blck_valid_sys (pre_reply_blck_valid_sys_w),
.wr_blck_coded_sys (pre_reply_blck_coded_sys_w),
.wr_blck_pdu_type_sys (pre_reply_blck_pdu_type_sys_w),
.wr_blck_target_tn_sys(pre_reply_blck_target_tn_sys_w),
.push_cnt_sys (pre_reply_blck_push_cnt_sys_w),
.drop_cnt_sys (pre_reply_blck_drop_cnt_sys_w)
);

// =============================================================================
// Phase X.5b — Pre-Reply Slot-Grant Mini-FSM (post-Frag-1 = Step 2)
//
// Trigger: `frag1_pulse_w` (1-cycle pulse from MAC-ACCESS parser on Frag-1
// detection). Builds a 268-bit MAC-RESOURCE AL-SETUP PDU with
// slot_granting_flag=1 + slot_granting_element=0x01 (capacity_allocation=0,
// granting_delay=1 — H.3.2 Ref-Bit-Identity), SCH/F-encodes it to 432
// bits and pushes through the MLE producer slot of the DL-Signal-Queue
// (muxed against the MLE-FSM's req_* output, which only fires on
// mb_go_pulse for Final ACCEPT and is temporally separated from the
// post-Frag-1 slot-grant by ~14 ms / Frag-2-roundtrip).
//
// This restores the Step-2-of--sequence behaviour that lived in the
// MLE-FSM's S_BUILD_SHORT_* path before Phase X.4 deleted it (commit
// 75c639a, mis-interpreted as Multi-Lookup leftover). Without this the
// MS sees no slot-grant after Frag-1, never reserves a slot for Frag-2,
// and retries Frag-1 indefinitely (verified UL-WAV 2026-05-02).
//
// Mux strategy: SlotGrant valid → drives MLE producer slot. Otherwise
// MLE-FSM req_valid drives. When both fire on the same cycle (extremely
// unlikely — SlotGrant 1F after Frag-1, ACCEPT after Frag-2-reass +
// 2-frame-gap), MLE-ACCEPT wins (it's the more important Final-Reply,
// not just a Pre-Reply hint). Memory: project_arch_fpga_thin_signaling.md
// + removed-memory.
// =============================================================================
wire slotgrant_valid_sys_w;
wire [431:0] slotgrant_coded_sys_w;
wire [1:0] slotgrant_pdu_type_sys_w;
wire [1:0] slotgrant_target_tn_sys_w;
// slotgrant_{push,drop}_cnt_sys_w forward-declared earlier (CDC block).

// Phase Z.9 — SlotGrant is single SCH/HD path (internal MAC-Resource builder
// + sch_hd_encoder inside tetra_pre_reply_slotgrant). No build-request bus
// to the shared u_dl_pdu_builder anymore.
//
// Phase Y.2 — GroupAck-Build raus aus RTL (Lock-Konformität): the only
// remaining producer on the shared builder is MLE-FSM Final-ACCEPT. The
// arbiter degenerates to a direct MLE → builder pass-through.

// Shared builder wires (single producer = MLE; no arbiter mux required).
wire dl_pdu_done_w;
wire [431:0] dl_pdu_coded_w;
wire dl_pdu_busy_w;
wire dl_pdu_done_to_mle_w;

tetra_pre_reply_slotgrant u_pre_reply_slotgrant (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Frag-1 trigger from MAC-ACCESS parser (Step 2 — post-Frag-1 slot-grant).
.frag1_pulse (frag1_pulse_w),
.ul_ssi (ul_issi_sys),
 // Phase Z.9 — mm-type used as accept-filter only (mm ∈ {2,7}). Both
 // mm-types build the IDENTICAL 124-bit AL-SETUP body via the local
 // SCH/HD pipeline, so no path-switching beyond the filter.
.mm_pdu_type (frag1_mm_type_w),
.cfg_mcch_tn (cfg_mcch_tn_sys_r1),
.cfg_scramble_init (mle_dl_scramb_init_sys),
 // Shared SCH/HD encoder (ch0, Priorität)
.ext_enc_req (sg_enc_req_w),
.ext_info_bits (sg_enc_info_w),
.ext_scramble_init (sg_enc_scramb_w),
.ext_enc_done (sg_enc_done_w),
.ext_enc_coded (sg_enc_coded_w),
 // Queue-side outputs: 432-bit MSB-aligned SCH/HD coded
 // (`{coded_schhd, 216'd0}`), pdu_type fixed at PDUC_SLOTFMT_SCH_HD.
.wr_slotgrant_valid_sys (slotgrant_valid_sys_w),
.wr_slotgrant_coded_sys (slotgrant_coded_sys_w),
.wr_slotgrant_pdu_type_sys(slotgrant_pdu_type_sys_w),
.wr_slotgrant_target_tn_sys(slotgrant_target_tn_sys_w),
.push_cnt_sys (slotgrant_push_cnt_sys_w),
.drop_cnt_sys (slotgrant_drop_cnt_sys_w)
);

// =============================================================================
// Phase Y.2 — Shared DL-PDU build pipeline (single MLE producer)
//
// History:
// - Pre-X.6: each producer FSM had its own SCH/F encoder (97.65% slice).
// - X.6: {MLE Final-ACCEPT, SlotGrant} share u_dl_pdu_builder via 2-way
// arbiter (later 3-way with GroupAck added in Y.1.d).
// - Z.3..Z.9: SlotGrant moved to its own SCH/HD pipeline; arbiter on the
// shared builder was 2-way (MLE + GroupAck).
// - Y.2 (this rev): GroupAck-Build moved to SW per Lock-Decision
// (memory `project_arch_fpga_thin_signaling.md`). The shared
// builder now has a single producer (MLE Final-ACCEPT). No
// arbiter mux, no owner-tracking — req_valid is gated on
// ~dl_pdu_busy_w so the MLE-FSM can hold the request stable.
//
// SlotGrant Pre-Reply (mm=2 + mm=7) lives on its own internal SCH/HD
// pipeline inside tetra_pre_reply_slotgrant.v — no contention here.
// =============================================================================
wire dl_pdu_grant_mle_w = mle_accept_build_req_w & ~dl_pdu_busy_w;

assign dl_pdu_done_to_mle_w = dl_pdu_done_w;

tetra_dl_pdu_builder u_dl_pdu_builder (
.clk (clk_sys),
.rst_n (rst_n_sys),
.req_valid (dl_pdu_grant_mle_w),
.req_ssi (mle_accept_build_ssi_w),
.req_addr_type (mle_accept_build_addr_type_w),
 // Klasse 2 (2026-05-24) — per-Call UMt aus Reply-Mailbox.
.req_usage_marker (mle_accept_build_usage_marker_w),
.req_chan_alloc_ts_bitmap (mle_accept_build_chan_alloc_ts_bitmap_w),
.req_llc_pdu_type (mle_accept_build_llc_pdu_type_w),
.req_random_access_flag (mle_accept_build_random_access_flag_w),
.req_mm_pdu_bits (mle_accept_build_mm_pdu_bits_w),
.req_mm_pdu_len_bits (mle_accept_build_mm_pdu_len_bits_w),
.req_scramble_init (mle_accept_build_scramble_init_w),
 // Phase Y.2 — ns/nr from MLE-FSM raw-mode latches (mm=11) or 0 (mm=2).
.req_ns (mle_accept_build_ns_w),
.req_nr (mle_accept_build_nr_w),
.req_mle_pd (mle_accept_build_mle_pd_w),
.done (dl_pdu_done_w),
.coded_bits (dl_pdu_coded_w),
.busy (dl_pdu_busy_w)
);

// MLE-Producer-Slot mux: MLE-FSM Final-ACCEPT (req_valid) takes priority
// over SlotGrant Pre-Reply. Phase Y.2 removed the GroupAck producer leg —
// SW now stages mm=7 replies through the same MLE Reply-Pull-Mailbox path.
// MLE and SlotGrant fire on different events (Frag-2 reass vs Frag-1) so
// the OR is sufficient.
wire mle_slot_wr_valid_w = mle_req_valid_w | slotgrant_valid_sys_w;
wire [431:0] mle_slot_wr_coded_w =
 mle_req_valid_w ? mle_req_coded_bits_w
: slotgrant_coded_sys_w;
wire [1:0] mle_slot_wr_pdu_type_w =
 mle_req_valid_w ? mle_req_pdu_type_w
: slotgrant_pdu_type_sys_w;
wire [1:0] mle_slot_wr_target_tn_w =
 mle_req_valid_w ? mle_req_target_tn_w
: slotgrant_target_tn_sys_w;
// Only MLE-FSM uses the second_pdu_* telemetry (Option B BL-ACK piggyback).
// SlotGrant doesn't have concat-second-PDUs.
wire mle_slot_wr_second_pdu_present_w = mle_req_valid_w ? mle_req_second_pdu_present_w: 1'b0;
wire mle_slot_wr_second_pdu_nr_w = mle_req_valid_w ? mle_req_second_pdu_nr_w: 1'b0;

// Phase 7 G.7 — Per-PDU-class AACH tag (was hardcoded 0x0009 pre-Phase-7G).
// MLE-FSM exposes `accept_build_aach_pattern` driven by lat_raw_mle_pd:
// CMCE D-CONNECT (raw_mle_pd=2) → 0x0249 idle ( #5887, BL-UDATA)
// ATTACH/grpack/SlotGrant → 0x0009 signalling-active
// SlotGrant Pre-Reply tags 0x0009 directly (single source per tetra_pdu_
// class.vh PDUC_PRE_REPLY_SLOTGRANT_AACH == PDUC_FINAL_LU_ACCEPT_AACH).
wire [13:0] mle_slot_wr_aach_pattern_w =
 mle_req_valid_w ? mle_accept_build_aach_pattern_w
: `PDUC_PRE_REPLY_SLOTGRANT_AACH;

// =============================================================================
// Phase Z.13 (2026-05-04) — producer-side AACH pre-coding REMOVED.
//
// The Z.12 design instantiated three combinational tetra_aach_rm_encoder
// blocks (MLE/CMCE/SDS) at the queue write ports so each producer would
// store a pre-computed 30-bit coded AACH alongside the 432-bit body.
// The downstream race that justified this (scheduler bundle-latch vs
// AACH-encoder FSM) was itself an artefact of the Z.11 multi-latch
// design — both have been eliminated in Z.13:
//
// * scheduler bundle-latch removed → ~451 FFs back
// * per-TN aach_override latches → ~56 FFs back
// * 3× producer-side aach_rm_encoder → ~LUTs back
// * queue-entry aach_coded[29:0] field → 30*4 = 120 FFs back
//
// AACH for queued PDUs is now encoded by ONE shared tetra_aach_rm_encoder
// instance at the slot-encoder side, in the same combinational fan-out
// path as the body bundle. See `aach_coded_slot_sys_w` declaration near
// tetra_aach_encoder.
// =============================================================================

// CDC: consume pulse + counter clk_sys → clk_axi
(* ASYNC_REG = "TRUE" *) reg nwrk_bcast_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg nwrk_bcast_consume_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] nwrk_bcast_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] nwrk_bcast_cnt_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 nwrk_bcast_consume_axi_r0 <= 1'b0;
 nwrk_bcast_consume_axi_r1 <= 1'b0;
 nwrk_bcast_cnt_axi_r0 <= 16'd0;
 nwrk_bcast_cnt_axi_r1 <= 16'd0;
 end else begin
 nwrk_bcast_consume_axi_r0 <= nwrk_bcast_push_valid_sys_w;
 nwrk_bcast_consume_axi_r1 <= nwrk_bcast_consume_axi_r0;
 nwrk_bcast_cnt_axi_r0 <= nwrk_bcast_push_cnt_sys_w;
 nwrk_bcast_cnt_axi_r1 <= nwrk_bcast_cnt_axi_r0;
 end
end

// =============================================================================
// Phase 1E-B (2026-05-20) — tetra_demand_mailbox + zugehörige CDC entfernt.
// SW walkt jetzt direkt aus tetra_ul_demand_body_mailbox (unten) den 129-bit
// MM-Body, daher nicht mehr nötig. AXI-Register REG_DEMAND_* (0x200..0x20C)
// werden in tetra_axi_lite_regs.v ebenfalls entfernt.
// =============================================================================

// =============================================================================
// Phase 1A — UL-Demand-Body Raw-Mailbox: Modul-Instance + CDC
//
// Latcht das RAW 129-bit MM-Body + SSI + mm_pdu_type aus
// tetra_ul_demand_reassembly auf jedem `reass_valid_sys`-Puls. SW liest
// den rohen Body via REG_UL_DEMAND_BODY_INDEX/DATA und walkt die IE
// selbst (Ziel: tetra_ul_demand_ie_parser RTL entfernen, ~3500 LUT spare).
//
// Parallel zur bestehenden tetra_demand_mailbox (parsed snapshot) — beide
// werden vom gleichen reass_valid_sys-Puls getriggert. Erst wenn SW-Walker
// produktiv ist, kann der RTL-Parser entfernt werden.
// =============================================================================
wire [3:0] uldbod_index_axi_w;
wire uldbod_ack_trigger_axi_w;
wire [31:0] uldbod_data_word_axi_w;
wire uldbod_pending_sys_w;
wire [15:0] uldbod_drop_cnt_sys_w;
wire [31:0] uldbod_data_word_sys_w;

(* ASYNC_REG = "TRUE" *) reg [3:0] uldbod_index_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] uldbod_index_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 uldbod_index_sys_r0 <= 4'd0;
 uldbod_index_sys_r1 <= 4'd0;
 end else begin
 uldbod_index_sys_r0 <= uldbod_index_axi_w;
 uldbod_index_sys_r1 <= uldbod_index_sys_r0;
 end
end

(* ASYNC_REG = "TRUE" *) reg uldbod_ack_sys_r0;
(* ASYNC_REG = "TRUE" *) reg uldbod_ack_sys_r1;
reg uldbod_ack_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 uldbod_ack_sys_r0 <= 1'b0;
 uldbod_ack_sys_r1 <= 1'b0;
 uldbod_ack_sys_r2 <= 1'b0;
 end else begin
 uldbod_ack_sys_r0 <= uldbod_ack_trigger_axi_w;
 uldbod_ack_sys_r1 <= uldbod_ack_sys_r0;
 uldbod_ack_sys_r2 <= uldbod_ack_sys_r1;
 end
end
wire uldbod_ack_pulse_sys_w = uldbod_ack_sys_r1 & ~uldbod_ack_sys_r2;

tetra_ul_demand_body_mailbox u_ul_demand_body_mailbox (
.clk_sys                (clk_sys),
.rst_n_sys              (rst_n_sys),
.push_valid_sys         (reass_valid_sys),
.body_sys               (reass_body_sys),
.ssi_sys                (reass_ssi_sys),
.mm_pdu_type_sys        (reass_mm_type_sys),
.ack_consumed_pulse_sys (uldbod_ack_pulse_sys_w),
.index_sys              (uldbod_index_sys_r1),
.data_word_sys          (uldbod_data_word_sys_w),
.pending_sys            (uldbod_pending_sys_w),
.drop_cnt_sys           (uldbod_drop_cnt_sys_w)
);

(* ASYNC_REG = "TRUE" *) reg uldbod_pending_axi_r0;
(* ASYNC_REG = "TRUE" *) reg uldbod_pending_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [15:0] uldbod_drop_cnt_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [15:0] uldbod_drop_cnt_axi_r1;
(* ASYNC_REG = "TRUE" *) reg [31:0] uldbod_data_word_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] uldbod_data_word_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 uldbod_pending_axi_r0 <= 1'b0;
 uldbod_pending_axi_r1 <= 1'b0;
 uldbod_drop_cnt_axi_r0 <= 16'd0;
 uldbod_drop_cnt_axi_r1 <= 16'd0;
 uldbod_data_word_axi_r0 <= 32'd0;
 uldbod_data_word_axi_r1 <= 32'd0;
 end else begin
 uldbod_pending_axi_r0 <= uldbod_pending_sys_w;
 uldbod_pending_axi_r1 <= uldbod_pending_axi_r0;
 uldbod_drop_cnt_axi_r0 <= uldbod_drop_cnt_sys_w;
 uldbod_drop_cnt_axi_r1 <= uldbod_drop_cnt_axi_r0;
 uldbod_data_word_axi_r0 <= uldbod_data_word_sys_w;
 uldbod_data_word_axi_r1 <= uldbod_data_word_axi_r0;
 end
end
assign uldbod_data_word_axi_w = uldbod_data_word_axi_r1;

(* ASYNC_REG = "TRUE" *) reg uldbod_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg uldbod_consume_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 uldbod_consume_axi_r0 <= 1'b0;
 uldbod_consume_axi_r1 <= 1'b0;
 end else begin
 uldbod_consume_axi_r0 <= uldbod_ack_pulse_sys_w;
 uldbod_consume_axi_r1 <= uldbod_consume_axi_r0;
 end
end

// =============================================================================
// Phase X.2 — Reply-Pull Mailbox: Modul-Instance + CDC
//
// Phase X.7 cleanup: the use_sw_body CDC pipe (reply_use_sw_sys_r0/r1)
// has been removed — the MLE-FSM no longer consumes that bit. The AXI
// register REG_REPLY_USE_SW @ 0x230 is still decoded (lives on
// reply_use_sw_axi_w) so the SW daemon's existing read/write path stays
// compatible, but the bit is now status-only and does not gate any RTL.
//
// AXI side (clk_axi):
// reply_index_axi_w — 4-bit indirect-window word selector
// reply_wdata_axi_w — 32-bit AXI write-data passed through
// reply_we_axi_w — 1-cycle write-enable pulse on REG_REPLY_DATA write
// reply_go_trigger_w — W1S GO bit, cleared by reply_go_consume_axi pulse
// reply_use_sw_axi_w — R/W status bit, no functional effect since X.7
// reply_busy_axi_r1 — 2-FF resync of busy mirror (clk_sys)
// reply_rdata_axi_r1 — 2-FF resync of indirect read-back word (clk_sys)
//
// clk_sys side: tetra_reply_mailbox holds the 16-word shadow, exposes the
// per-field outputs (mb_*) feeding the MLE-FSM directly, and forwards
// the 1-cycle GO pulse for FSM trigger / Phase X.4.
// =============================================================================
wire [3:0] reply_index_axi_w;
wire [31:0] reply_wdata_axi_w;
wire reply_we_axi_w;
wire reply_go_trigger_w;
wire reply_use_sw_axi_w;
// X.7: reply_use_sw_axi_w is now lint-only — keep the consumer in a
// sim-only block so synthesis prunes it cleanly.
// synthesis translate_off
wire _unused_reply_use_sw = reply_use_sw_axi_w;
// synthesis translate_on

// 2-FF resync of slow-changing R/W signals: index, wdata.
(* ASYNC_REG = "TRUE" *) reg [3:0] reply_index_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] reply_index_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [31:0] reply_wdata_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] reply_wdata_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 reply_index_sys_r0 <= 4'd0;
 reply_index_sys_r1 <= 4'd0;
 reply_wdata_sys_r0 <= 32'd0;
 reply_wdata_sys_r1 <= 32'd0;
 end else begin
 reply_index_sys_r0 <= reply_index_axi_w;
 reply_index_sys_r1 <= reply_index_sys_r0;
 reply_wdata_sys_r0 <= reply_wdata_axi_w;
 reply_wdata_sys_r1 <= reply_wdata_sys_r0;
 end
end

// 2-FF resync + edge-detect of the AXI write pulse: emits a 1-cycle
// pulse on clk_sys when AXI writes a new value to REG_REPLY_DATA.
// This timing is conservative (multi-cycle re-sync) — SW issues writes
// at a few-Hz cadence, so the index already settled by the time the
// edge fires.
(* ASYNC_REG = "TRUE" *) reg reply_we_sys_r0;
(* ASYNC_REG = "TRUE" *) reg reply_we_sys_r1;
reg reply_we_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 reply_we_sys_r0 <= 1'b0;
 reply_we_sys_r1 <= 1'b0;
 reply_we_sys_r2 <= 1'b0;
 end else begin
 reply_we_sys_r0 <= reply_we_axi_w;
 reply_we_sys_r1 <= reply_we_sys_r0;
 reply_we_sys_r2 <= reply_we_sys_r1;
 end
end
wire reply_we_pulse_sys_w = reply_we_sys_r1 & ~reply_we_sys_r2;

// 2-FF resync + edge-detect of the GO trigger to a 1-cycle pulse.
(* ASYNC_REG = "TRUE" *) reg reply_go_sys_r0;
(* ASYNC_REG = "TRUE" *) reg reply_go_sys_r1;
reg reply_go_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 reply_go_sys_r0 <= 1'b0;
 reply_go_sys_r1 <= 1'b0;
 reply_go_sys_r2 <= 1'b0;
 end else begin
 reply_go_sys_r0 <= reply_go_trigger_w;
 reply_go_sys_r1 <= reply_go_sys_r0;
 reply_go_sys_r2 <= reply_go_sys_r1;
 end
end
wire reply_go_pulse_sys_w = reply_go_sys_r1 & ~reply_go_sys_r2;

// Reply-Mailbox instance (clk_sys) — 16-word indirect register file with
// per-field outputs.
wire [31:0] reply_rdata_sys_w;
wire [23:0] mb_ssi_sys_w;
wire [13:0] mb_la_sys_w;
wire [2:0] mb_addr_type_sys_w;
// Klasse 2 (2026-05-24) — Reply-Mailbox W2[8:3] UMt-Wert.
wire [5:0] mb_usage_marker_sys_w;
wire [1:0] mb_result_sys_w;
// Bug-001 fix — MS-demand location_update_type, echoed from Reply-Pull-Mailbox
// W3[4:2] into D-LOC-UPDATE-ACCEPT loc_acc_type field (ETSI §16.10.35a).
wire [2:0] mb_loc_acc_type_sys_w;
wire [23:0] mb_gila_gssi_sys_w;
wire [2:0] mb_gila_class_sys_w;
wire [1:0] mb_gila_lifetime_sys_w;
wire mb_gila_present_sys_w;
wire [1:0] mb_encryption_sys_w;
wire [1:0] mb_auth_result_sys_w;
wire mb_go_pulse_sys_w;
// Phase Y.2 — raw-mode (Variante A) MM-body bypass for mm=11 GROUP-ACK.
wire mb_raw_mode_flag_sys_w;
wire [127:0] mb_raw_mm_bits_sys_w;
wire [7:0] mb_raw_mm_len_sys_w;
wire mb_raw_ns_sys_w;
wire mb_raw_nr_sys_w;
wire [2:0] mb_raw_mle_pd_sys_w; /* Phase 7 G.4 — MLE-PD selector */

tetra_reply_mailbox u_reply_mailbox (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.index_sys (reply_index_sys_r1),
.wdata_sys (reply_wdata_sys_r1),
.wr_en_sys (reply_we_pulse_sys_w),
.go_pulse_sys (reply_go_pulse_sys_w),
.rdata_sys (reply_rdata_sys_w),
.mb_ssi_sys (mb_ssi_sys_w),
.mb_la_sys (mb_la_sys_w),
.mb_addr_type_sys (mb_addr_type_sys_w),
.mb_usage_marker_sys (mb_usage_marker_sys_w),
.mb_chan_alloc_ts_bitmap_sys (mb_chan_alloc_ts_bitmap_sys_w),
.mb_result_sys (mb_result_sys_w),
.mb_loc_acc_type_sys (mb_loc_acc_type_sys_w),
.mb_gila_gssi_sys (mb_gila_gssi_sys_w),
.mb_gila_class_sys (mb_gila_class_sys_w),
.mb_gila_lifetime_sys (mb_gila_lifetime_sys_w),
.mb_gila_present_sys (mb_gila_present_sys_w),
.mb_encryption_sys (mb_encryption_sys_w),
.mb_auth_result_sys (mb_auth_result_sys_w),
.mb_go_pulse_sys (mb_go_pulse_sys_w),
 // Phase Y.2 — raw-mode bypass field outputs
.mb_raw_mode_flag_sys (mb_raw_mode_flag_sys_w),
.mb_raw_mm_bits_sys (mb_raw_mm_bits_sys_w),
.mb_raw_mm_len_sys (mb_raw_mm_len_sys_w),
.mb_raw_ns_sys (mb_raw_ns_sys_w),
.mb_raw_nr_sys (mb_raw_nr_sys_w),
.mb_raw_mle_pd_sys (mb_raw_mle_pd_sys_w)
);

// CDC: rdata + busy clk_sys → clk_axi (busy is the OR of FSM busy-state).
// In Phase X.2 the FSM busy mirror is taken directly from mle_busy_w (already
// in clk_sys). rdata is a slow read-back path so 2-FF settles fine.
(* ASYNC_REG = "TRUE" *) reg [31:0] reply_rdata_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] reply_rdata_axi_r1;
(* ASYNC_REG = "TRUE" *) reg reply_busy_axi_r0;
(* ASYNC_REG = "TRUE" *) reg reply_busy_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 reply_rdata_axi_r0 <= 32'd0;
 reply_rdata_axi_r1 <= 32'd0;
 reply_busy_axi_r0 <= 1'b0;
 reply_busy_axi_r1 <= 1'b0;
 end else begin
 reply_rdata_axi_r0 <= reply_rdata_sys_w;
 reply_rdata_axi_r1 <= reply_rdata_axi_r0;
 reply_busy_axi_r0 <= mle_busy_w;
 reply_busy_axi_r1 <= reply_busy_axi_r0;
 end
end

// CDC: GO-consume pulse clk_sys → clk_axi to clear the W1S trigger.
(* ASYNC_REG = "TRUE" *) reg reply_go_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg reply_go_consume_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 reply_go_consume_axi_r0 <= 1'b0;
 reply_go_consume_axi_r1 <= 1'b0;
 end else begin
 reply_go_consume_axi_r0 <= reply_go_pulse_sys_w;
 reply_go_consume_axi_r1 <= reply_go_consume_axi_r0;
 end
end

// =============================================================================
// Phase 7 G.8 — Voice-Filler-Mailbox CDC + instance.
//
// Bit-pipe for SW-encoded SCH/F type-5 burst (432 bits). SW writes
// W0..W13 (432 bits packed LSB-first), W14[0]=1 to mark valid, pulses GO.
// burst_dispatcher consumes blk1_sys/blk2_sys on voice-slot + voice-FN
// when voice_active_mask + valid_sys are both set. SW is the encoder
// (CRC + conv + interleave + scramble); RTL is just bit-pipe + routing.
// =============================================================================
wire [3:0] vfill_index_axi_w;
wire [31:0] vfill_wdata_axi_w;
wire vfill_we_axi_w;
wire vfill_go_trigger_w;

// 2-FF resync: index, wdata (slow-changing, follows reply-mailbox pattern)
(* ASYNC_REG = "TRUE" *) reg [3:0] vfill_index_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] vfill_index_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [31:0] vfill_wdata_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] vfill_wdata_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 vfill_index_sys_r0 <= 4'd0;
 vfill_index_sys_r1 <= 4'd0;
 vfill_wdata_sys_r0 <= 32'd0;
 vfill_wdata_sys_r1 <= 32'd0;
 end else begin
 vfill_index_sys_r0 <= vfill_index_axi_w;
 vfill_index_sys_r1 <= vfill_index_sys_r0;
 vfill_wdata_sys_r0 <= vfill_wdata_axi_w;
 vfill_wdata_sys_r1 <= vfill_wdata_sys_r0;
 end
end

// 2-FF resync + edge-detect of we to 1-cycle clk_sys pulse.
(* ASYNC_REG = "TRUE" *) reg vfill_we_sys_r0;
(* ASYNC_REG = "TRUE" *) reg vfill_we_sys_r1;
reg vfill_we_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 vfill_we_sys_r0 <= 1'b0;
 vfill_we_sys_r1 <= 1'b0;
 vfill_we_sys_r2 <= 1'b0;
 end else begin
 vfill_we_sys_r0 <= vfill_we_axi_w;
 vfill_we_sys_r1 <= vfill_we_sys_r0;
 vfill_we_sys_r2 <= vfill_we_sys_r1;
 end
end
wire vfill_we_pulse_sys_w = vfill_we_sys_r1 & ~vfill_we_sys_r2;

// 2-FF resync + edge-detect of GO trigger.
(* ASYNC_REG = "TRUE" *) reg vfill_go_sys_r0;
(* ASYNC_REG = "TRUE" *) reg vfill_go_sys_r1;
reg vfill_go_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 vfill_go_sys_r0 <= 1'b0;
 vfill_go_sys_r1 <= 1'b0;
 vfill_go_sys_r2 <= 1'b0;
 end else begin
 vfill_go_sys_r0 <= vfill_go_trigger_w;
 vfill_go_sys_r1 <= vfill_go_sys_r0;
 vfill_go_sys_r2 <= vfill_go_sys_r1;
 end
end
wire vfill_go_pulse_sys_w = vfill_go_sys_r1 & ~vfill_go_sys_r2;

// Voice-Filler-Mailbox instance (clk_sys).
wire [31:0] vfill_rdata_sys_w;
wire [215:0] vfill_blk1_sys_w;
wire [215:0] vfill_blk2_sys_w;
wire vfill_valid_sys_w;
wire vfill_go_pulse_out_sys_w;
tetra_voice_filler_mailbox u_voice_filler_mailbox (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.index_sys (vfill_index_sys_r1),
.wdata_sys (vfill_wdata_sys_r1),
.wr_en_sys (vfill_we_pulse_sys_w),
.go_pulse_sys (vfill_go_pulse_sys_w),
.rdata_sys (vfill_rdata_sys_w),
.blk1_sys (vfill_blk1_sys_w),
.blk2_sys (vfill_blk2_sys_w),
.valid_sys (vfill_valid_sys_w),
.go_pulse_out_sys (vfill_go_pulse_out_sys_w)
);
// vfill_go_pulse_out_sys_w currently unused — reserved for future SW-FSM
// trigger pattern (e.g., one-shot voice-burst submit). Keep tied to keep
// signal alive for ILA debug.
(* keep = "true" *) wire _vfill_go_pulse_keep = vfill_go_pulse_out_sys_w;

// CDC: rdata + valid clk_sys → clk_axi.
(* ASYNC_REG = "TRUE" *) reg [31:0] vfill_rdata_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] vfill_rdata_axi_r1;
(* ASYNC_REG = "TRUE" *) reg vfill_valid_axi_r0;
(* ASYNC_REG = "TRUE" *) reg vfill_valid_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 vfill_rdata_axi_r0 <= 32'd0;
 vfill_rdata_axi_r1 <= 32'd0;
 vfill_valid_axi_r0 <= 1'b0;
 vfill_valid_axi_r1 <= 1'b0;
 end else begin
 vfill_rdata_axi_r0 <= vfill_rdata_sys_w;
 vfill_rdata_axi_r1 <= vfill_rdata_axi_r0;
 vfill_valid_axi_r0 <= vfill_valid_sys_w;
 vfill_valid_axi_r1 <= vfill_valid_axi_r0;
 end
end

// CDC: GO-consume pulse clk_sys → clk_axi.
(* ASYNC_REG = "TRUE" *) reg vfill_go_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg vfill_go_consume_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 vfill_go_consume_axi_r0 <= 1'b0;
 vfill_go_consume_axi_r1 <= 1'b0;
 end else begin
 vfill_go_consume_axi_r0 <= vfill_go_pulse_sys_w;
 vfill_go_consume_axi_r1 <= vfill_go_consume_axi_r0;
 end
end

// =============================================================================
// Phase E2 — Voice-NUB-Read-Mailbox CDC + instance.
// FPGA→SW pipe: 432 signed 4-bit soft-values (= 1728 bits = 54 × 32) per
// NUB burst, latched with valid-Flag. SW polls valid, reads W0..W53,
// then writes ACK to clear valid + arm next burst.
// =============================================================================
wire [5:0] vnub_index_axi_w;
wire vnub_ack_trigger_w;

// 2-FF resync of index AXI → sys (slow R/W, simple settle).
(* ASYNC_REG = "TRUE" *) reg [5:0] vnub_index_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [5:0] vnub_index_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 vnub_index_sys_r0 <= 6'd0;
 vnub_index_sys_r1 <= 6'd0;
 end else begin
 vnub_index_sys_r0 <= vnub_index_axi_w;
 vnub_index_sys_r1 <= vnub_index_sys_r0;
 end
end

// 2-FF resync + edge-detect of ACK trigger to 1-cycle clk_sys pulse.
(* ASYNC_REG = "TRUE" *) reg vnub_ack_sys_r0;
(* ASYNC_REG = "TRUE" *) reg vnub_ack_sys_r1;
reg vnub_ack_sys_r2;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) begin
 vnub_ack_sys_r0 <= 1'b0;
 vnub_ack_sys_r1 <= 1'b0;
 vnub_ack_sys_r2 <= 1'b0;
 end else begin
 vnub_ack_sys_r0 <= vnub_ack_trigger_w;
 vnub_ack_sys_r1 <= vnub_ack_sys_r0;
 vnub_ack_sys_r2 <= vnub_ack_sys_r1;
 end
end
wire vnub_ack_pulse_sys_w = vnub_ack_sys_r1 & ~vnub_ack_sys_r2;

// Voice-NUB-Read-Mailbox instance (clk_sys).
wire [31:0] vnub_rdata_sys_w;
wire vnub_valid_sys_w;
tetra_voice_nub_read_mailbox u_voice_nub_read_mailbox (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.coded_softs_sys (voice_nub_coded_softs_sys_w),
.coded_valid_sys (voice_nub_coded_valid_sys_w),
.ack_pulse_sys (vnub_ack_pulse_sys_w),
.index_sys (vnub_index_sys_r1),
.rdata_sys (vnub_rdata_sys_w),
.valid_sys (vnub_valid_sys_w)
);

// CDC: rdata + valid clk_sys → clk_axi.
(* ASYNC_REG = "TRUE" *) reg [31:0] vnub_rdata_axi_r0;
(* ASYNC_REG = "TRUE" *) reg [31:0] vnub_rdata_axi_r1;
(* ASYNC_REG = "TRUE" *) reg vnub_valid_axi_r0;
(* ASYNC_REG = "TRUE" *) reg vnub_valid_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 vnub_rdata_axi_r0 <= 32'd0;
 vnub_rdata_axi_r1 <= 32'd0;
 vnub_valid_axi_r0 <= 1'b0;
 vnub_valid_axi_r1 <= 1'b0;
 end else begin
 vnub_rdata_axi_r0 <= vnub_rdata_sys_w;
 vnub_rdata_axi_r1 <= vnub_rdata_axi_r0;
 vnub_valid_axi_r0 <= vnub_valid_sys_w;
 vnub_valid_axi_r1 <= vnub_valid_axi_r0;
 end
end

// CDC: ACK-consume pulse clk_sys → clk_axi to clear W1S trigger.
(* ASYNC_REG = "TRUE" *) reg vnub_ack_consume_axi_r0;
(* ASYNC_REG = "TRUE" *) reg vnub_ack_consume_axi_r1;
always @(posedge s_axi_aclk or negedge rst_n_axi) begin
 if (!rst_n_axi) begin
 vnub_ack_consume_axi_r0 <= 1'b0;
 vnub_ack_consume_axi_r1 <= 1'b0;
 end else begin
 vnub_ack_consume_axi_r0 <= vnub_ack_pulse_sys_w;
 vnub_ack_consume_axi_r1 <= vnub_ack_consume_axi_r0;
 end
end

// =============================================================================
// Phase 1E-B (2026-05-20) — tetra_grp_demand_mailbox + zugehörige CDC
// entfernt. mm=7 wird wie mm=2 jetzt aus dem raw-Body via SW gewalkt; siehe
// sw/tetra_mm_demand_parser.c + react_mm7_grpid() in attach_daemon.
// AXI-Register REG_GRP_DEMAND_* (0x240..0x24C) ebenfalls aus
// tetra_axi_lite_regs.v entfernt.
// =============================================================================

// =============================================================================
// Phase Y.2 — Group-Attach Reply Mailbox + GroupAck encoder REMOVED.
//
// SW now builds the D-ATTACH-DETACH-GRP-ID-ACK MM body in C and pushes it
// into the shared mm=2 Reply-Pull-Mailbox via a raw-mode mailbox extension
// (see sw/tetra_attach_daemon.c + sw/tetra_tx_transport.c). The legacy
// `tetra_grp_reply_mailbox` shadow + `tetra_d_attach_detach_grp_id_ack_
// encoder` instance + AXI window 0x250..0x25C are GONE per Lock-Decision
// `memory/project_arch_fpga_thin_signaling.md`.
// =============================================================================

// =============================================================================
// Slot-Schedule BRAM (Plan Stufe 3, Port B rewired in Stufe 4)
//
// Dual-port BRAM: Port A = AXI (clk_axi, write + readback); Port B =
// clk_sys synchronous read. Stufe 4: Port B's address is driven
// externally by u_slot_content_mux (sched_b_addr_sys_w), which sequences
// 4 back-to-back reads once per frame to refresh its local 4-entry
// schedule cache. BRAM returns mem[addr] one clk_sys cycle after the
// address is presented.
// =============================================================================
wire schedule_axi_we_w;
wire schedule_axi_re_w;
wire [7:0] schedule_axi_addr_w;
wire [31:0] schedule_axi_wdata_w;
wire [3:0] schedule_axi_wstrb_w;
wire [31:0] schedule_axi_rdata_w;
// schedule_entry_sys_w declared earlier as a forward reference (Stufe 4)

tetra_slot_schedule u_tx_slot_schedule (
 // Port A — AXI (clk_axi)
.clk_axi (s_axi_aclk),
.rst_n_axi (rst_n_axi),
.axi_we (schedule_axi_we_w),
.axi_addr (schedule_axi_addr_w),
.axi_wdata (schedule_axi_wdata_w),
.axi_wstrb (schedule_axi_wstrb_w),
.axi_re (schedule_axi_re_w),
.axi_rdata (schedule_axi_rdata_w),
 // Port B — clk_sys, externally-driven address (Stufe 4 Option b):
 // content_mux computes dense_idx = mn[1:0]*72 + fn*4 + tn[1:0] and
 // presents it every cycle; BRAM returns mem[addr] on the next
 // clk_sys edge.
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
.sched_b_addr_sys (sched_b_addr_sys_w),
.schedule_entry_sys (schedule_entry_sys_w)
);

// Debug probe on schedule_entry_sys — kept for ILA visibility into the
// BRAM's Port-B output. Stufe 4's real consumer is u_slot_content_mux
// (above), but this register retains the mark_debug net for hardware
// bring-up debugging.
(* mark_debug = "true", keep = "true" *) reg [15:0] dbg_schedule_entry_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_schedule_entry_sys <= 16'h0000;
 else dbg_schedule_entry_sys <= schedule_entry_sys_w;
end

// =============================================================================
// BSCH (SB1) Encoder Integration (Plan Stufe 3.5 / 4)
//
// Instantiates tetra_sb1_encoder. Stufe 4 now routes the encoder's
// output sb1_coded_sys_w into the tx_chain via tetra_slot_content_mux
// (u_slot_content_mux), replacing the legacy SW-driven REG_SB_SB1_*
// path for the SDB burst payload. The REG_SB_SB1_* registers remain
// writable/readable in the AXI register bank but are no longer on the
// datapath.
//
// CDC strategy — clk_axi → clk_sys:
// * Cell-Config fields (sys_code, sharing_mode, ts_res_frames,
// uplane_dtx, frame18_ext, neigh_cell_bc, cell_service_level,
// late_entry_support, mcc, mnc) and ColourCode are slow-changing:
// the MCU writes them once at boot and rarely touches them
// afterward. A 2-FF synchronizer per field is sufficient. There
// is NO per-field atomicity: if the MCU writes two fields back to
// back, transient mixes are possible for ~2 clk_sys cycles. The
// MCU must wait >2 clk_sys cycles after the last CELL_CFG /
// COLOUR_CODE write before triggering the first TX slot (easily
// satisfied since TX gating happens via REG_CTRL, written after
// the config).
// * Encoder trigger is driven off slot_pulse_sys — already a clk_sys
// signal from the timebase, no CDC needed.
// * Dynamic fields (TN, FN, MN) are taken straight from the timebase
// (clk_sys); FN and MN are shifted +1 to match the encoder's
// 1-based input convention.
// =============================================================================

// 2-FF resync of each Cell-Config field (clk_axi → clk_sys).
// R1: one always block per register.
(* ASYNC_REG = "TRUE" *) reg [3:0] cell_cfg_sys_code_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] cell_cfg_sys_code_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_sharing_mode_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_sharing_mode_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [2:0] cell_cfg_ts_reserved_frames_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [2:0] cell_cfg_ts_reserved_frames_sys_r1;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_uplane_dtx_sys_r0;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_uplane_dtx_sys_r1;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_frame18_ext_sys_r0;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_frame18_ext_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_neigh_cell_bc_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_neigh_cell_bc_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_cell_service_level_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] cell_cfg_cell_service_level_sys_r1;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_late_entry_support_sys_r0;
(* ASYNC_REG = "TRUE" *) reg cell_cfg_late_entry_support_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [9:0] cell_cfg_mcc_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [9:0] cell_cfg_mcc_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [13:0] cell_cfg_mnc_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [13:0] cell_cfg_mnc_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [5:0] colour_code_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [5:0] colour_code_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [1:0] cfg_mcch_tn_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [1:0] cfg_mcch_tn_sys_r1;
(* ASYNC_REG = "TRUE" *) reg [13:0] cell_la_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [13:0] cell_la_sys_r1;
// Phase 6 A — DB-Policy[0] = accept_unknown, 2-FF resynced to clk_sys
(* ASYNC_REG = "TRUE" *) reg db_policy_accept_unknown_sys_r0;
(* ASYNC_REG = "TRUE" *) reg db_policy_accept_unknown_sys_r1;
// Phase X.4 — AST TTL threshold removed (AST migrated to SW).

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_sys_code_sys_r0 <= 4'd0;
 else cell_cfg_sys_code_sys_r0 <= cell_cfg_sys_code_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_sys_code_sys_r1 <= 4'd0;
 else cell_cfg_sys_code_sys_r1 <= cell_cfg_sys_code_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_sharing_mode_sys_r0 <= 2'd0;
 else cell_cfg_sharing_mode_sys_r0 <= cell_cfg_sharing_mode_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_sharing_mode_sys_r1 <= 2'd0;
 else cell_cfg_sharing_mode_sys_r1 <= cell_cfg_sharing_mode_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_ts_reserved_frames_sys_r0 <= 3'd0;
 else cell_cfg_ts_reserved_frames_sys_r0 <= cell_cfg_ts_reserved_frames_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_ts_reserved_frames_sys_r1 <= 3'd0;
 else cell_cfg_ts_reserved_frames_sys_r1 <= cell_cfg_ts_reserved_frames_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_uplane_dtx_sys_r0 <= 1'b0;
 else cell_cfg_uplane_dtx_sys_r0 <= cell_cfg_uplane_dtx_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_uplane_dtx_sys_r1 <= 1'b0;
 else cell_cfg_uplane_dtx_sys_r1 <= cell_cfg_uplane_dtx_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_frame18_ext_sys_r0 <= 1'b0;
 else cell_cfg_frame18_ext_sys_r0 <= cell_cfg_frame18_ext_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_frame18_ext_sys_r1 <= 1'b0;
 else cell_cfg_frame18_ext_sys_r1 <= cell_cfg_frame18_ext_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_neigh_cell_bc_sys_r0 <= 2'd0;
 else cell_cfg_neigh_cell_bc_sys_r0 <= cell_cfg_neigh_cell_bc_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_neigh_cell_bc_sys_r1 <= 2'd0;
 else cell_cfg_neigh_cell_bc_sys_r1 <= cell_cfg_neigh_cell_bc_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_cell_service_level_sys_r0 <= 2'd0;
 else cell_cfg_cell_service_level_sys_r0 <= cell_cfg_cell_service_level_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_cell_service_level_sys_r1 <= 2'd0;
 else cell_cfg_cell_service_level_sys_r1 <= cell_cfg_cell_service_level_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_late_entry_support_sys_r0 <= 1'b0;
 else cell_cfg_late_entry_support_sys_r0 <= cell_cfg_late_entry_support_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_late_entry_support_sys_r1 <= 1'b0;
 else cell_cfg_late_entry_support_sys_r1 <= cell_cfg_late_entry_support_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_mcc_sys_r0 <= 10'd0;
 else cell_cfg_mcc_sys_r0 <= cell_cfg_mcc_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_mcc_sys_r1 <= 10'd0;
 else cell_cfg_mcc_sys_r1 <= cell_cfg_mcc_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_mnc_sys_r0 <= 14'd0;
 else cell_cfg_mnc_sys_r0 <= cell_cfg_mnc_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_cfg_mnc_sys_r1 <= 14'd0;
 else cell_cfg_mnc_sys_r1 <= cell_cfg_mnc_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) colour_code_sys_r0 <= 6'd0;
 else colour_code_sys_r0 <= colour_code_axi;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) colour_code_sys_r1 <= 6'd0;
 else colour_code_sys_r1 <= colour_code_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cfg_mcch_tn_sys_r0 <= 2'd0;
 else cfg_mcch_tn_sys_r0 <= cfg_signal_target_tn_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cfg_mcch_tn_sys_r1 <= 2'd0;
 else cfg_mcch_tn_sys_r1 <= cfg_mcch_tn_sys_r0;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_la_sys_r0 <= 14'd1;
 else cell_la_sys_r0 <= cell_la_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) cell_la_sys_r1 <= 14'd1;
 else cell_la_sys_r1 <= cell_la_sys_r0;
end
// Phase 6 A — accept_unknown CDC (default 1: M2 backward-compatible)
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) db_policy_accept_unknown_sys_r0 <= 1'b1;
 else db_policy_accept_unknown_sys_r0 <= db_policy_axi_w[0];
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) db_policy_accept_unknown_sys_r1 <= 1'b1;
 else db_policy_accept_unknown_sys_r1 <= db_policy_accept_unknown_sys_r0;
end

// Phase Y.4.1 — voice_active_mask CDC (4-bit, default 0 idle).
(* ASYNC_REG = "TRUE" *) reg [3:0] voice_active_mask_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [3:0] voice_active_mask_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) voice_active_mask_sys_r0 <= 4'd0;
 else voice_active_mask_sys_r0 <= voice_active_mask_axi_w[3:0];
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) voice_active_mask_sys_r1 <= 4'd0;
 else voice_active_mask_sys_r1 <= voice_active_mask_sys_r0;
end

// 2026-05-24 Klasse 2 — slot_aach CDC axi→sys (4×16-bit, default 0x3000 idle).
(* ASYNC_REG = "TRUE" *) reg [63:0] slot_aach_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [63:0] slot_aach_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) slot_aach_sys_r0 <= {4{16'h3000}};
 else slot_aach_sys_r0 <= slot_aach_axi_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) slot_aach_sys_r1 <= {4{16'h3000}};
 else slot_aach_sys_r1 <= slot_aach_sys_r0;
end

// Phase C — voice_nub_sync_thresh CDC (5-bit threshold, default 8).
(* ASYNC_REG = "TRUE" *) reg [4:0] voice_nub_sync_thresh_sys_r0;
(* ASYNC_REG = "TRUE" *) reg [4:0] voice_nub_sync_thresh_sys_r1;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) voice_nub_sync_thresh_sys_r0 <= 5'd8;
 else voice_nub_sync_thresh_sys_r0 <= voice_nub_sync_thresh_axi_w[4:0];
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) voice_nub_sync_thresh_sys_r1 <= 5'd8;
 else voice_nub_sync_thresh_sys_r1 <= voice_nub_sync_thresh_sys_r0;
end

// Phase C — voice_slot_tn = lowest set bit of voice_active_mask (MVP: 1 voice
// slot at a time per SW convention). Priority-encoder on 4 bits.
wire [1:0] voice_slot_tn_sys_w =
 voice_active_mask_sys_r1[0] ? 2'd0:
 voice_active_mask_sys_r1[1] ? 2'd1:
 voice_active_mask_sys_r1[2] ? 2'd2: 2'd3;

// Phase X.4 — AST TTL multiframes CDC removed (AST migrated to SW).

// Lookahead tuple (next-slot tn, fn, mn). The sb1/aach encoders are
// started on slot_pulse_sys of slot N but their outputs are only fully
// settled ~142 clk_sys cycles later. burst_mux latches the payload
// registers on slot_pulse+2, so a same-slot start would feed burst_mux
// with stale data from the previous encoding — the on-air SB1.TimeSlot
// field would lag the actual air slot by one TN (observed 2026-04-21
// as -1 TN shift vs ).
//
// Fix: encode the NEXT slot's PDU during the current slot. At slot
// pulse N we kick off encoding for slot N+1; by slot pulse N+1 the
// encoder has been stable for ~5414 cycles and burst_mux picks up the
// correct TimeSlot=N+1 payload.
//
// Wrap rules (0-based counters):
// tn = 3 → tn_next = 0, advance fn
// fn = 17 & tn = 3 → fn_next = 0, advance mn[5:0] (full 6-bit, not mn[1:0])
// mn = 59 & fn = 17 & tn = 3 → mn_next = 0
wire tx_tn_wrap_sys = (tx_tdma_state_tn_sys == 2'd3);
wire tx_fn_wrap_sys = tx_tn_wrap_sys && (tx_tdma_state_fn_sys == 5'd17);
wire tx_mn_wrap_sys = tx_fn_wrap_sys && (tx_tdma_state_mn_sys == 6'd59);

wire [1:0] tx_tn_next_sys = tx_tn_wrap_sys ? 2'd0: (tx_tdma_state_tn_sys + 2'd1);
wire [4:0] tx_fn_next_sys = tx_tn_wrap_sys
 ? (tx_fn_wrap_sys ? 5'd0: (tx_tdma_state_fn_sys + 5'd1))
: tx_tdma_state_fn_sys;
wire [5:0] tx_mn_next_sys = tx_fn_wrap_sys
 ? (tx_mn_wrap_sys ? 6'd0: (tx_tdma_state_mn_sys + 6'd1))
: tx_tdma_state_mn_sys;

// sb1_encoder takes 1-based FN/MN (1..18, 1..60) while the timebase is
// 0-based. Compute from the lookahead tuple so the encoded PDU names
// the slot that will actually carry it.
wire [4:0] sb1_frame_num_sys = tx_fn_next_sys + 5'd1;
wire [5:0] sb1_multiframe_num_sys = tx_mn_next_sys + 6'd1;

// Encoder output wires — declared earlier as forward references (Stufe 4)

tetra_sb1_encoder u_sb1_encoder (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Static config (clk_sys-side resynced from AXI)
.cfg_system_code (cell_cfg_sys_code_sys_r1),
.cfg_colour_code (colour_code_sys_r1),
.cfg_sharing_mode (cell_cfg_sharing_mode_sys_r1),
.cfg_ts_reserved_frames (cell_cfg_ts_reserved_frames_sys_r1),
.cfg_u_plane (cell_cfg_uplane_dtx_sys_r1),
.cfg_frame_18_ext (cell_cfg_frame18_ext_sys_r1),
.cfg_mcc (cell_cfg_mcc_sys_r1),
.cfg_mnc (cell_cfg_mnc_sys_r1),
.cfg_neighbour_cell_broadcast (cell_cfg_neigh_cell_bc_sys_r1),
.cfg_cell_service_level (cell_cfg_cell_service_level_sys_r1),
.cfg_late_entry_info (cell_cfg_late_entry_support_sys_r1),
 // Trigger — slot_pulse of CURRENT slot starts encoding for NEXT slot
.encode_start_sys (tx_tdma_state_slot_pulse_sys),
 // Dynamic fields — lookahead to the slot that will transmit this PDU
.sdb_slot_sys (tx_tn_next_sys),
.frame_num_sys (sb1_frame_num_sys),
.multiframe_num_sys (sb1_multiframe_num_sys),
 // Outputs
.sb1_coded_sys (sb1_coded_sys_w),
.sb1_valid_sys (sb1_valid_sys_w)
);

// Debug probe + keep sink so synthesis does not collapse the encoder
// before Stufe 4 wires it into the TX datapath. Registered with
// mark_debug = keep so the output survives opt_design.
(* mark_debug = "true", keep = "true" *) reg [119:0] dbg_sb1_coded_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_sb1_valid_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_sb1_coded_sys <= 120'h0;
 else if (sb1_valid_sys_w) dbg_sb1_coded_sys <= sb1_coded_sys_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_sb1_valid_sys <= 1'b0;
 else dbg_sb1_valid_sys <= sb1_valid_sys_w;
end

// =============================================================================
// Plan Stufe 3.7: AACH encoder (probe-only, parallel to legacy REG_SB_BB path)
//
// Generates 30 type-5 bits per slot from FN + ColourCode + MCC + MNC.
// Content: F1-17 = CapAlloc (14'h3000), F18 = DL/UL-Assign (14'h040).
// Verified bit-exact against sw/tetra_hal.c via scripts/gen_aach_reference.py.
// Stufe 4 (content-mux) now consumes aach_coded_sys_w and feeds it into
// tetra_tx_chain as the BB payload — the legacy REG_SB_BB path remains
// writable for back-compat readback but is no longer on the TX datapath.
// =============================================================================
// aach_coded_sys_w / aach_valid_sys_w declared earlier as forward refs

// =============================================================================
// Phase Z.13 (2026-05-04) — Single-path slot AACH select.
//
// One linear path:
// * If the queue head targets the slot being encoded (tx_tn_next_sys),
// drive the slot's AACH from a SHARED tetra_aach_rm_encoder fed by
// head_aach_pattern. Body and AACH come from the SAME queue entry,
// no latch, no bundle.
// * Otherwise the slot AACH is the default-logic output of
// tetra_aach_encoder (idle 0x0249 / TN!=0 traffic / F18 anchor /
// grant_pending).
//
// The Z.2/Z.12 layered-override design (per-TN aach_override_pattern,
// per-TN aach_coded bundle, scheduler bundle latch, atomic-bypass mux,
// 3× producer-side aach_rm_encoders) is GONE.
// =============================================================================

// Match between queue head and the slot being EMITTED right now (= the
// slot whose AACH bits the burst_dispatcher latches at tx_slot_pulse_sys).
//
// The default `tetra_aach_encoder` uses `tx_tn_next_sys` as its tn input
// because its 33-cycle FSM runs during slot N to produce AACH for slot N+1
// (consistent with sb1_encoder). The OUTPUT `aach_coded_sys_w` therefore
// already represents "AACH for current emit slot" at slot_pulse time.
//
// The override-RM-encoder `head_aach_rm_encoder` is purely combinational
// — no FSM, no latency. It must be matched against the CURRENT emit TN
// (= `tx_tdma_state_tn_sys`) so a queue.head pushed mid-slot-N (after the
// default encoder's slot-N-1 snapshot) still wins on slot_pulse@N latch.
//
// Phase 7 G call-setup race motivation: D-CALL-PROCEEDING was the first
// PDU in a previously-empty queue. At slot_pulse@N-1 the default encoder
// sampled signalling_active=0 (queue empty) → AACH committed to 0x0249
// idle for slot N. D-CALL-PROC pushed into queue during slot N-1's body
// window → burst_dispatcher latched body=PDU but AACH stayed idle → MS
// decoder treated slot as NDB2 NULL filler, ignored the LI=13 content,
// stuck in call-setup-pending state. Matching head against current TN
// closes that race: head_aach_coded is RM-encoded combinationally from
// head.aach_pattern (= 0x0009 signalling-active) and wins the mux.
wire head_match_aach_sys = queue_head_valid_w
 && (queue_head_target_tn_w == tx_tdma_state_tn_sys);

// Shared scrambler-init pack — identical to the one tetra_aach_encoder
// derives internally; we keep cell-cfg static so this pack is also
// stable. (Caller handles the lfsr=0 degeneracy inside the RM encoder.)
wire [31:0] aach_lfsr_init_sys_w = {cell_cfg_mcc_sys_r1,
 cell_cfg_mnc_sys_r1,
 colour_code_sys_r1,
 2'b11};

// Combinational RM(30,14)+scrambler — encodes the queue head's
// aach_pattern in zero cycles.
wire [29:0] head_aach_coded_sys_w;
tetra_aach_rm_encoder u_aach_rm_slot (
.info_w (queue_head_aach_pattern_w),
.lfsr_init_w (aach_lfsr_init_sys_w),
.coded_w (head_aach_coded_sys_w)
);

// Default-logic AACH encoder (idle 0x0249 / TN!=0 traffic 0x3000 / F18
// anchor / grant_pending). No override inputs in Z.13.
tetra_aach_encoder u_aach_encoder (
.clk_sys (clk_sys),
.rst_n_sys (rst_n_sys),
 // Lookahead FN/TN — same reason as sb1_encoder (see comment above
 // u_sb1_encoder). AACH payload for slot N must be ready before
 // burst_mux latches it at slot_pulse N + 2.
.fn_sys (tx_fn_next_sys),
.tn_sys (tx_tn_next_sys),
.mn_low2_sys (tx_mn_next_sys[1:0]),
.colour_code_sys (colour_code_sys_r1),
.mcc_sys (cell_cfg_mcc_sys_r1),
.mnc_sys (cell_cfg_mnc_sys_r1),
 // Quelle direkt aus der Queue.head sichten statt aus sched_blk1!=null_pdu —
 // letzteres ist kombinatorisch vom sched_blk1-Bus abhängig, der seinerseits
 // erst stabil ist wenn die queue.head bei slot_pulse-entering-TN=tx_tn_next
 // tatsächlich schon den richtigen Eintrag hat. Für isolierte Single-PDU
 // Replies (mm=11 grpack ohne SlotGrant-Bundle davor) fällt das Sample-
 // Fenster in eine Lücke und AACH bleibt 0x0249 idle, obwohl die Burst-
 // Body-Bits später noch das richtige grpack-Wort einsehen.
.signalling_active_sys (queue_head_valid_w
 && (queue_head_target_tn_w == tx_tn_next_sys)),
 // Phase H.6.3 — UL-Slot-Grant override (kept; only fires on TN=0
 // idle when head_match=0, no overlap with queued-PDU path).
.grant_pending_sys (aach_grant_pending_sys_r1),
.grant_info_sys (aach_grant_info_sys_r1),
.grant_consume_sys (aach_grant_consume_sys_w),
 /* Phase Y.4.1 — Voice-Slot AACH-Override (4-bit bitmap per tn_sys). */
.voice_active_mask_sys (voice_active_mask_sys_r1),
 /* 2026-05-24 Klasse 2 — Per-TN AACH-Wert von SW. */
.slot_aach_sys (slot_aach_sys_r1),
.encode_start_sys (tx_tdma_state_slot_pulse_sys),
.aach_coded_sys (aach_coded_sys_w),
.aach_valid_sys (aach_valid_sys_w)
);

// Single linear if/else: queued-PDU AACH wins on its target slot, else
// default-encoder output. This is the ONLY mux on the AACH path —
// no per-TN bundle, no atomic-bypass, no aach_override_info latches.
// (Wire forward-declared near `aach_coded_sys_w`.)
assign aach_coded_slot_sys_w = head_match_aach_sys
 ? head_aach_coded_sys_w
: aach_coded_sys_w;

(* mark_debug = "true", keep = "true" *) reg [29:0] dbg_aach_coded_sys;
(* mark_debug = "true", keep = "true" *) reg dbg_aach_valid_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_aach_coded_sys <= 30'h0;
 else if (aach_valid_sys_w) dbg_aach_coded_sys <= aach_coded_sys_w;
end
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_aach_valid_sys <= 1'b0;
 else dbg_aach_valid_sys <= aach_valid_sys_w;
end

// =============================================================================
// ILA Debug Probes — Hardware first-light verification (Phase 4)
//
// Registered probes with mark_debug="true". Using registers (not wire aliases)
// ensures the probe nets survive synthesis flattening and opt_design.
//
// Clock domains:
// dbg_*_lvds → l_clk (AD9361 DATA_CLK, up to 250 MHz)
// dbg_*_sys → clk_sys (PL fabric, 100 MHz)
//
// Two ILA cores will be created automatically by implement_debug_core:
// ila (l_clk): depth 4096 — confirms AD9361 IQ delivery + adapter
// ila (clk_sys): depth 4096 — confirms TETRA sync, DMA, IRQ
//
// Probe file written to: build/tetra_zynq_phy.ltx
// Use Vivado Hardware Manager to load.bit +.ltx for on-chip debug.
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
 dbg_loopback_en_sys <= ctrl_loopback_en_sys;
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

// =========================================================================
// RX Debug Counters — readable via AXI at 0x50, 0x54, 0x58
// Count valid pulses at each RX pipeline stage. Reset with CTRL[3].
// =========================================================================
reg [31:0] dbg_fe_cnt_sys;
reg [31:0] dbg_demod_cnt_sys;
reg [31:0] dbg_sync_cnt_sys;

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_fe_cnt_sys <= 32'd0;
 else if (ctrl_reset_counters_sys) dbg_fe_cnt_sys <= 32'd0;
 else if (dbg_fe_valid_sys) dbg_fe_cnt_sys <= dbg_fe_cnt_sys + 32'd1;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_demod_cnt_sys <= 32'd0;
 else if (ctrl_reset_counters_sys) dbg_demod_cnt_sys <= 32'd0;
 else if (dbg_demod_valid_sys) dbg_demod_cnt_sys <= dbg_demod_cnt_sys + 32'd1;
end

always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_sync_cnt_sys <= 32'd0;
 else if (ctrl_reset_counters_sys) dbg_sync_cnt_sys <= 32'd0;
 else if (sync_found_sys) dbg_sync_cnt_sys <= dbg_sync_cnt_sys + 32'd1;
end

// corr_peak_sys is CORR_WIDTH=24 bits from sync_detect; pack into AXI register
// Read at 0x58 as: {corr_peak[7:0], sync_cnt[23:0]} — but for simplicity,
// expose corr_peak on the existing demod_cnt upper bits.
// Actually, use the AXI register module — add a new wire to dbg_sync_cnt_axi read path.
// For now, override: pack corr_peak into bits [31:24] of sync_cnt AXI readback.
wire [31:0] dbg_sync_packed_sys = {corr_peak_sys[7:0], dbg_sync_cnt_sys[23:0]};

// =========================================================================
// UL sync_cnt + packing for AXI read at 0x5C
// Layout: {ul_best_phase[1:0], 6'd0, ul_corr_peak[7:0], ul_sync_cnt[15:0]}
// =========================================================================
reg [15:0] dbg_ul_sync_cnt_sys;
always @(posedge clk_sys or negedge rst_n_sys) begin
 if (!rst_n_sys) dbg_ul_sync_cnt_sys <= 16'd0;
 else if (ctrl_reset_counters_sys) dbg_ul_sync_cnt_sys <= 16'd0;
 else if (ul_sync_found_sys) dbg_ul_sync_cnt_sys <= dbg_ul_sync_cnt_sys + 16'd1;
end

wire [31:0] dbg_sync_ul_packed_sys = {ul_best_phase_sys, 6'd0,
 ul_corr_peak_sys[7:0],
 dbg_ul_sync_cnt_sys};

endmodule
`default_nettype wire
