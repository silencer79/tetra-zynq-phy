// =============================================================================
// tetra_axi_lite_regs.v  —  AXI4-Lite Register Bank
// Project : tetra-zynq-phy  (Zynq-7020 + AD9361)
// Standard: N/A (infrastructure)
// =============================================================================
// Provides ARM PS with 32-bit word-aligned R/W access to PHY control and
// status registers via an AXI4-Lite slave interface.
//
// NOTE ON PORT NAMING (R2 exception):
//   AXI4-Lite ports (s_axi_awaddr, s_axi_wdata, …) follow the Vivado Block
//   Design naming convention and do NOT carry the _axi domain suffix.  All
//   *internal* signals and non-AXI ports carry the _axi suffix per Rule R2.
//
// Register Map  (base + offset, 32-bit word-aligned):
//   0x00  CTRL          R/W  [0] RX_EN [1] TX_EN [2] LOOPBACK [3] RST_CNTRS
//   0x04  STATUS        RO   [0] SYNC_LOCKED [1] PLL_LOCKED
//                            [2] FIFO_EMPTY  [3] FIFO_FULL  [7:4] SLOT_STATUS
//   0x08  VERSION       RO   0x0001_0000 (v1.0)
//   0x0C  SYNC_THRESH   R/W  [7:0]  default 0x14 (20; STS max=38)
//   0x10  COLOUR_CODE   R/W  [5:0]  default 1
//   0x14  FRAME_NUM     RO   [4:0]  live from frame_counter
//   0x18  SLOT_NUM      RO   [1:0]  live from frame_counter
//   0x1C  RX_GAIN       R/W  [6:0]  default 0x20 (32)
//   0x20  TX_ATT        R/W  [7:0]  default 0x28 (40)
//   0x24  IRQ_ENABLE    R/W  [4:0]
//   0x28  IRQ_STATUS    R/W1C [4:0]  hw-set wins over sw-clear
//   0x2C  DMA_BLK_CNT  RO   [15:0]  live from dma_bridge
//   0x30  CRC_ERR_CNT  RO   [15:0]  live from dma_bridge
//   0x34  SYNC_LST_CNT RO   [15:0]  live from dma_bridge
//   0x38  RESERVED      —    reads as 0
//   0x3C  SCRATCH       R/W  [31:0]
//   0x40–0x4C SB_SB1_0..3 R/W  BSCH coded payload, 120 bits (w3 [23:0])
//   0x60–0x78 SB_BKN2_0..6 R/W BNCH coded payload, 216 bits (w6 [23:0])
//   0x7C  SB_BB         R/W  AACH coded payload,  30 bits [29:0]
//   0x80  (removed — was NCO_PHASE_INC)
//   0x84  TX_TEST       R/W  [0] PRBS_EN
//   0x88–0xA0 NDB_BLK1_0..6 R/W NDB block1 coded payload, 216 bits (w6 [23:0])
//   0xA4–0xBC NDB_BLK2_0..6 R/W NDB block2 coded payload, 216 bits (w6 [23:0])
//   0xC0–0xD8 MCCH_BLK1_0..6 R/W MCCH block1 coded payload, 216 bits (w6 [23:0])
//   0xDC–0xF4 MCCH_BLK2_0..6 R/W MCCH block2 coded payload, 216 bits (w6 [23:0])
//   0xF8–0x110 BNCH_BLK1_0..6 R/W BNCH block1 coded payload, 216 bits (w6 [23:0])
//   0x114–0x12C BNCH_BLK2_0..6 R/W BNCH block2 coded payload, 216 bits (w6 [23:0])
//   0x130 CELL_CFG_0    R/W  [3:0]sys_code [5:4]sharing_mode [8:6]ts_res_frames
//                             [9]uplane_dtx [10]frame18_ext [12:11]neigh_cell_bc
//                             [14:13]cell_service_level [15]late_entry_support
//                             [31:16] reserved (RAZ)  — Plan Stufe 3.5
//   0x134 CELL_CFG_1    R/W  [9:0]mcc [23:10]mnc [31:24] reserved (RAZ)
//                             — Plan Stufe 3.5 (ColourCode stays at 0x10)
//   0x140 TX_TDMA_LOAD  W    [1:0]TN [6:2]FN [12:7]MN [18:13]HN [31]STROBE
//   0x144 TX_TDMA_STATE RO   [1:0]TN [6:2]FN [12:7]MN [18:13]HN [26:19]sym_cnt
//   0x148..0x160 NULL_PDU_0..6 R/W  216-bit SCH/HD-coded static NULL-PDU
//   0x164 UL_PDU_STATUS RO   [0]valid(sticky) [2:1]pdu_type [3]fill [5:4]enc
//                             [6]access_ack [9:7]addr_type [31:16]pdu_count
//   0x168 UL_PDU_SSI    RO   [9:0]short_ssi
//   0x16C UL_PDU_RAW_0  RO   raw_info_bits[31:0]
//   0x170 UL_PDU_RAW_1  RO   raw_info_bits[63:32]
//   0x174 UL_PDU_RAW_2  RO   raw_info_bits[91:64]  (28 bits, upper 4 RAZ)
//   0x178 UL_PDU_CTRL   W1C  [0] clear valid sticky (hw-set-wins)
//   0x17C UL_SCRAMB_INIT R/W 32-bit cell scrambler seed feeding
//                             tetra_ul_sch_hu_decoder (MS bursts use the
//                             BS extended scrambling sequence — MCU writes
//                             this once at boot from CC/MCC/MNC)
//   0x180 SHADOW_INDEX    R/W [7:0] subscriber-shadow slot index (0..255)
//   0x184 SHADOW_DATA_LO  R/W bits [31:0]  of 64-bit shadow record
//   0x188 SHADOW_DATA_HI  R/W bits [63:32] of 64-bit shadow record
//   0x18C SHADOW_CTRL     W1S [0] commit — writes INDEX/DATA_{HI,LO} into
//                             the shadow BRAM as a single-cycle wr_en pulse
//                             (self-clearing; reads back 0).  Issued as:
//                               write INDEX → write DATA_LO → write DATA_HI
//                               → write CTRL=1  (commit).
//                             MCU side uses sw/tetra_db_mgr.c.
//   0x400..0x63F SCHEDULE_BRAM  R/W  144 32-bit words, 2 x 16-bit entries each
//                                    (Plan Stufe 3 — word-address decode
//                                     widened from 7-bit to 9-bit for this
//                                     window.  See tetra_slot_schedule.v for
//                                     the entry layout and port-B clk_sys
//                                     read semantics.)
//
//   NOTE on TX_TDMA_LOAD/STATE offsets:
//   Plan `docs/plan_tetra_tdma_rtl_ownership.md` §4 Stufe 2 nominated
//   0xC0/0xC4 for these registers, but those offsets are already occupied
//   by MCCH_BLK1_0/MCCH_BLK1_1 in the current register map (and Stufe 3
//   also contradicts itself by planning a Schedule-BRAM window at
//   0x100..0x33F over the existing BNCH_BLK1/2 area).  To avoid breaking
//   the currently functional MCCH/BNCH payload pipeline this stage uses
//   the first unused word-address after BNCH_BLK2_6 (0x12C): 0x140/0x144.
//   The plan register-map section will be updated in Stufe 3 when the
//   broader restructure happens.
//
// IRQ_STATUS bits:
//   [0] IRQ_MAC_BLOCK_RDY   — MAC block available in DMA buffer
//   [1] IRQ_SYNC_ACQUIRED   — sync lock achieved
//   [2] IRQ_SYNC_LOST       — sync lock lost
//   [3] IRQ_CRC_ERROR       — CRC error on received block
//   [4] IRQ_RX_FIFO_FULL    — RX FIFO overflow
//
// AXI-Lite write machine:
//   AWREADY = !aw_latched_axi  (combinatorial)
//   WREADY  = !w_latched_axi   (combinatorial)
//   wr_en_axi = aw_latched & w_latched & !bvalid  (1-cycle pulse)
//   After wr_en fires: BVALID asserted, cleared on BREADY.
//
// AXI-Lite read machine:
//   ARREADY = !ar_latched_axi  (combinatorial)
//   ar_en_axi = ar_latched & !rvalid  (1-cycle pulse)
//   RVALID/RDATA asserted one cycle after ar_en.
//
// Coding Rules: Verilog-2001 strict
//   R1 : one always block per register
//   R2 : _axi suffix on all internal signals
//   R3 : no arrays
//   R4 : async active-low rst_n_axi, explicit reset values
//   R9 : no initial blocks
//   R10: @(*) for all combinatorial blocks
// =============================================================================
`default_nettype none

module tetra_axi_lite_regs (
    // ------------------------------------------------------------------
    // AXI4-Lite Clock & Reset  (Vivado BD naming — no _axi suffix here)
    // ------------------------------------------------------------------
    input  wire        s_axi_aclk,      // clk_axi  : 100 MHz AXI bus clock
    input  wire        s_axi_aresetn,   // rst_n_axi: active-low async reset

    // AXI4-Lite Write Address Channel
    input  wire [31:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,    // write protection (accepted per AXI4-Lite spec, ignored)
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,   // = !aw_latched_axi (combinatorial)

    // AXI4-Lite Write Data Channel
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,    // = !w_latched_axi  (combinatorial)

    // AXI4-Lite Write Response Channel
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Lite Read Address Channel
    input  wire [31:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,    // read protection (accepted per AXI4-Lite spec, ignored)
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,   // = !ar_latched_axi (combinatorial)

    // AXI4-Lite Read Data Channel
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ------------------------------------------------------------------
    // PHY Status Inputs  (pre-synchronized to axi domain by caller)
    // ------------------------------------------------------------------
    input  wire        sync_locked_axi,
    input  wire        pll_locked_axi,
    input  wire        rx_fifo_empty_axi,
    input  wire        rx_fifo_full_axi,
    input  wire [3:0]  slot_status_axi,   // bitmap: which slots have valid data
    input  wire [4:0]  frame_num_axi,     // from tetra_frame_counter
    input  wire [1:0]  slot_num_axi,      // from tetra_frame_counter
    input  wire [1:0]  tx_slot_axi,       // TX free-running slot (0-3)
    input  wire [4:0]  tx_frame_axi,      // TX free-running frame (1-18)
    input  wire [5:0]  tx_mf_axi,         // TX free-running multiframe (1-60)

    // RX debug counters (clk_sys domain, reset by CTRL[3])
    input  wire [31:0] dbg_fe_cnt_axi,    // RX frontend out_valid count
    input  wire [31:0] dbg_demod_cnt_axi, // Demod dibit_valid count
    input  wire [31:0] dbg_sync_cnt_axi,  // Sync found count (DL)
    input  wire [31:0] dbg_sync_ul_axi,   // UL: {ul_best_phase[1:0], 6'd0, ul_corr_peak[7:0], ul_sync_cnt[15:0]}

    // Interrupt inputs (1-cycle pulses, pre-synchronized to axi domain)
    input  wire        irq_mac_block_axi,
    input  wire        irq_sync_acquired_axi,
    input  wire        irq_sync_lost_axi,
    input  wire        irq_crc_error_axi,
    input  wire        irq_rx_fifo_full_axi,

    // Counter inputs (pre-synchronized to axi domain)
    input  wire [15:0] dma_block_count_axi,
    input  wire [15:0] crc_error_count_axi,
    input  wire [15:0] sync_lost_count_axi,

    // ------------------------------------------------------------------
    // Control Outputs  (axi domain → PHY modules)
    // ------------------------------------------------------------------
    output wire        ctrl_rx_enable_axi,        // CTRL[0]
    output wire        ctrl_tx_enable_axi,         // CTRL[1]
    output wire        ctrl_loopback_en_axi,       // CTRL[2]
    output wire        ctrl_reset_counters_axi,    // CTRL[3]
    output reg  [7:0]  sync_thresh_axi,
    output reg  [5:0]  colour_code_axi,
    output reg  [6:0]  rx_gain_axi,
    output reg  [7:0]  tx_att_axi,
    output reg  [4:0]  irq_enable_axi,

    // SB Payload Registers (PS-writable broadcast data for TX chain)
    //   sb_sb1:  BSCH coded payload, 120 bits (4 × 32, word 3 [23:0] only)
    //   sb_bkn2: BNCH coded payload, 216 bits (7 × 32, upper 8 unused)
    //   sb_bb:   AACH coded payload,  30 bits (1 × 32, upper 2 unused)
    output wire [119:0] sb_sb1_axi,
    output wire [215:0] sb_bkn2_axi,
    output wire [29:0]  sb_bb_axi,

    // TX test mode (0x84 bit 0): PRBS dibit injection for spectrum verification
    output reg         tx_test_prbs_en_axi,

    // NDB Payload Registers — block1 and block2 coded data (432 type-5 bits
    // total, split 216+216).  Same 216-bit payload is broadcast to all four
    // slots in the top-level (see tetra_zynq_top.v).  Fills NDB bursts with
    // scrambled modulated content so the spectrum is continuous instead of
    // narrow-CW from an all-zero payload.
    output wire [215:0] ndb_block1_axi,
    output wire [215:0] ndb_block2_axi,

    // MCCH (slot 1) dedicated payload registers
    output wire [215:0] mcch_block1_axi,
    output wire [215:0] mcch_block2_axi,

    // BNCH (frame 18, rotating slot) — SCH/HD encoded payload
    output wire [215:0] bnch_block1_axi,
    output wire [215:0] bnch_block2_axi,

    // NULL-PDU payload (Plan Stufe 4) — 216-bit SCH/HD-encoded static
    // PDU used by the content-mux on class=NULL_PDU schedule entries.
    output wire [215:0] null_pdu_bits_axi,

    // ------------------------------------------------------------------
    // TX TDMA Timebase (Plan Stufe 2) — AXI ↔ clk_sys TDMA counter
    // ------------------------------------------------------------------
    // Outputs (clk_axi → clk_sys): payload held stable by register,
    // strobe resynchronized to clk_sys in top-level.
    output wire [1:0]   tx_tdma_sync_tn_axi,
    output wire [4:0]   tx_tdma_sync_fn_axi,
    output wire [5:0]   tx_tdma_sync_mn_axi,
    output wire [5:0]   tx_tdma_sync_hn_axi,
    output wire         tx_tdma_sync_strobe_axi,  // 1 clk_axi cycle pulse
    // Inputs (clk_sys → clk_axi): live counter snapshot from timebase.
    // Caller is expected to 2-FF-resync each bit in the top-level so
    // these ports arrive already-synchronized to clk_axi.
    input  wire [1:0]   tx_tdma_state_tn_axi,
    input  wire [4:0]   tx_tdma_state_fn_axi,
    input  wire [5:0]   tx_tdma_state_mn_axi,
    input  wire [5:0]   tx_tdma_state_hn_axi,
    input  wire [7:0]   tx_tdma_state_sym_cnt_axi,

    // ------------------------------------------------------------------
    // ------------------------------------------------------------------
    // Cell-Config Registers (Plan Stufe 3.5) — feed tetra_sb1_encoder
    // ------------------------------------------------------------------
    // CELL_CFG_0 @ 0x130, CELL_CFG_1 @ 0x134.  Slow-changing (written once
    // at MCU boot); no per-field atomicity required.  Caller 2-FF resyncs
    // each field into clk_sys in the top-level; MCU must wait >2 clk_sys
    // cycles after the final CELL_CFG write before triggering TX.
    output wire [3:0]  cell_cfg_sys_code_axi,
    output wire [1:0]  cell_cfg_sharing_mode_axi,
    output wire [2:0]  cell_cfg_ts_reserved_frames_axi,
    output wire        cell_cfg_uplane_dtx_axi,
    output wire        cell_cfg_frame18_ext_axi,
    output wire [1:0]  cell_cfg_neigh_cell_bc_axi,
    output wire [1:0]  cell_cfg_cell_service_level_axi,
    output wire        cell_cfg_late_entry_support_axi,
    output wire [9:0]  cell_cfg_mcc_axi,
    output wire [13:0] cell_cfg_mnc_axi,

    // ------------------------------------------------------------------
    // UL MAC-ACCESS PDU Mailbox (Plan Stufe 4 — Task #36)
    // Inputs from tetra_ul_mac_access_parser (clk_sys domain).  Caller is
    // expected to 2-FF-resync each bit in the top-level before driving these
    // ports.  The ul_pdu_valid_axi pulse is also resynced (pulse-stretch or
    // rising-edge extract in top-level); on that pulse this module latches
    // a stable snapshot of the field inputs into clk_axi-domain registers.
    // ------------------------------------------------------------------
    input  wire        ul_pdu_valid_axi,       // 1-cycle pulse, clk_axi
    input  wire [1:0]  ul_pdu_type_axi,
    input  wire        ul_fill_bit_axi,
    input  wire [1:0]  ul_encryption_mode_axi,
    input  wire        ul_access_ack_axi,
    input  wire [2:0]  ul_address_type_axi,
    input  wire [9:0]  ul_short_ssi_axi,
    input  wire [91:0] ul_raw_info_bits_axi,
    input  wire [15:0] ul_pdu_count_axi,

    // UL scrambler seed — MCU programs once at boot.  Caller 2-FF-resyncs
    // axi→sys in top-level before feeding tetra_ul_sch_hu_decoder.
    output wire [31:0] ul_scramb_init_axi,

    // ------------------------------------------------------------------
    // Subscriber-Shadow BRAM indirect write window (Phase 6 M2.3)
    // 0x180 INDEX, 0x184 DATA_LO, 0x188 DATA_HI, 0x18C CTRL (commit W1S).
    // Writes INDEX + DATA_LO + DATA_HI into staging registers, then a
    // write with CTRL[0]=1 fires a single-cycle shadow_wr_en_axi pulse
    // that commits the staged {INDEX, DATA_HI, DATA_LO} into the shadow
    // BRAM.  Caller resyncs wr_en to clk_sys in top (same-clock project
    // for now — direct connect is fine).
    // ------------------------------------------------------------------
    output wire [7:0]  shadow_wr_idx_axi,
    output wire [63:0] shadow_wr_data_axi,
    output wire        shadow_wr_en_axi,

    // ------------------------------------------------------------------
    // MLE registration FSM debug counters (clk_axi domain, 2-FF resynced
    // in top-level).  Read-only. 0x190 = {accept[15:0], ul_req[15:0]},
    // 0x194 = {15'b0, busy_sticky, drop[15:0]},
    // 0x198 = {clear_cnt[15:0], inject_cnt[15:0]}.
    // ------------------------------------------------------------------
    input  wire [15:0] mle_ul_req_cnt_axi,
    input  wire [15:0] mle_accept_cnt_axi,
    input  wire [15:0] mle_drop_cnt_axi,
    input  wire        mle_busy_sticky_axi,
    input  wire [15:0] mle_inject_cnt_axi,
    input  wire [15:0] mle_clear_cnt_axi,

    // ------------------------------------------------------------------
    // Schedule-BRAM AXI Window (Plan Stufe 3) — 0x400..0x63F
    // 144 words, each word packs TWO 16-bit schedule entries.
    //   schedule_axi_we     : 1-cycle write pulse
    //   schedule_axi_re     : 1-cycle read pulse (fires the cycle before
    //                         the rdata mux expects schedule_axi_rdata).
    //   schedule_axi_addr   : 8-bit word index (0..143) within the window
    //   schedule_axi_wdata  : {upper_entry[15:0], lower_entry[15:0]}
    //   schedule_axi_wstrb  : byte strobes (halfword granularity)
    //   schedule_axi_rdata  : registered readback, valid the cycle after
    //                         schedule_axi_re, consumed by the rdata mux.
    // ------------------------------------------------------------------
    output wire        schedule_axi_we,
    output wire        schedule_axi_re,
    output wire [7:0]  schedule_axi_addr,
    output wire [31:0] schedule_axi_wdata,
    output wire [3:0]  schedule_axi_wstrb,
    input  wire [31:0] schedule_axi_rdata,

    // IRQ output to PS interrupt controller
    output reg         irq_out_axi
);

// ---------------------------------------------------------------------------
// Local clock/reset aliases for R2 compliance in internal logic
// ---------------------------------------------------------------------------
wire clk_axi   = s_axi_aclk;
wire rst_n_axi = s_axi_aresetn;

// awprot / arprot: accepted for AXI4-Lite compliance; this slave ignores
// the protection level (no secure/privileged access separation required).
// synthesis translate_off
wire _unused_prot = |s_axi_awprot | |s_axi_arprot;
// synthesis translate_on

// ---------------------------------------------------------------------------
// Register index decode  (bits [8:2] select word; [1:0] always 0)
//
// Plan Stufe 3 widens the address bus to 9 word-address bits (byte bits
// [10:2]) to accommodate the Schedule-BRAM window at 0x400..0x63F.
// Existing register-bank comparisons stay 7-bit ([8:2] == REG_*) because
// all REG_* fall inside 0x000..0x1FC; the top two bits [10:9] gate which
// window (regs vs. schedule) the handshake fires into.
// ---------------------------------------------------------------------------
localparam [6:0] REG_CTRL         = 7'h00; // 0x00
localparam [6:0] REG_STATUS       = 7'h01; // 0x04
localparam [6:0] REG_VERSION      = 7'h02; // 0x08
localparam [6:0] REG_SYNC_THRESH  = 7'h03; // 0x0C
localparam [6:0] REG_COLOUR_CODE  = 7'h04; // 0x10
localparam [6:0] REG_FRAME_NUM    = 7'h05; // 0x14
localparam [6:0] REG_SLOT_NUM     = 7'h06; // 0x18
localparam [6:0] REG_RX_GAIN      = 7'h07; // 0x1C
localparam [6:0] REG_TX_ATT       = 7'h08; // 0x20
localparam [6:0] REG_IRQ_ENABLE   = 7'h09; // 0x24
localparam [6:0] REG_IRQ_STATUS   = 7'h0A; // 0x28
localparam [6:0] REG_DMA_BLK_CNT = 7'h0B; // 0x2C
localparam [6:0] REG_CRC_ERR_CNT = 7'h0C; // 0x30
localparam [6:0] REG_SYNC_LST_CNT= 7'h0D; // 0x34
localparam [6:0] REG_TX_TDMA      = 7'h0E; // 0x38  [12:0] TX slot/frame/mf
localparam [6:0] REG_SCRATCH      = 7'h0F; // 0x3C

// SB Payload registers (0x40–0x7C)
// sb1: 120 bits in 4 words (word 3 bits [23:0] only)
localparam [6:0] REG_SB_SB1_0    = 7'h10; // 0x40
localparam [6:0] REG_SB_SB1_1    = 7'h11; // 0x44
localparam [6:0] REG_SB_SB1_2    = 7'h12; // 0x48
localparam [6:0] REG_SB_SB1_3    = 7'h13; // 0x4C  (bits [23:0] used)
// RX debug counters (read-only, reset by CTRL[3])
localparam [6:0] REG_DBG_FE_CNT   = 7'h14; // 0x50  RX frontend valid count
localparam [6:0] REG_DBG_DEMOD_CNT= 7'h15; // 0x54  Demod dibit valid count
localparam [6:0] REG_DBG_SYNC_CNT = 7'h16; // 0x58  Sync found count (DL)
localparam [6:0] REG_DBG_SYNC_UL  = 7'h17; // 0x5C  UL debug: {phase[1:0], 6'd0, peak[7:0], cnt[15:0]}
// bkn2: 216 bits in 7 words (word 6 bits [23:0] only)
localparam [6:0] REG_SB_BKN2_0   = 7'h18; // 0x60
localparam [6:0] REG_SB_BKN2_1   = 7'h19; // 0x64
localparam [6:0] REG_SB_BKN2_2   = 7'h1A; // 0x68
localparam [6:0] REG_SB_BKN2_3   = 7'h1B; // 0x6C
localparam [6:0] REG_SB_BKN2_4   = 7'h1C; // 0x70
localparam [6:0] REG_SB_BKN2_5   = 7'h1D; // 0x74
localparam [6:0] REG_SB_BKN2_6   = 7'h1E; // 0x78  (bits [23:0] used)
// bb: 30 bits in 1 word
localparam [6:0] REG_SB_BB       = 7'h1F; // 0x7C  (bits [29:0] used)

// TX test register (0x84)
//   [0] TX_PRBS_EN — replace burst_builder dibit with 15-bit LFSR-PRBS
//                    (diagnostic: forces varying π/4-DQPSK symbols so the
//                     modulation chain produces proper RRC-shaped spread
//                     spectrum instead of a degenerate CW at f_NCO).
localparam [6:0] REG_TX_TEST       = 7'h21; // 0x84

// NDB block1/block2 payload registers (0x88–0xBC)
// Each block: 216 bits in 7 × 32-bit words (word 6 bits [23:0] only).
// Broadcast to all 4 NDB slots in tetra_zynq_top.v so every slot
// sends channel-coded modulated data (no narrow-CW from all-zero payload).
localparam [6:0] REG_NDB_BLK1_0    = 7'h22; // 0x88
localparam [6:0] REG_NDB_BLK1_1    = 7'h23; // 0x8C
localparam [6:0] REG_NDB_BLK1_2    = 7'h24; // 0x90
localparam [6:0] REG_NDB_BLK1_3    = 7'h25; // 0x94
localparam [6:0] REG_NDB_BLK1_4    = 7'h26; // 0x98
localparam [6:0] REG_NDB_BLK1_5    = 7'h27; // 0x9C
localparam [6:0] REG_NDB_BLK1_6    = 7'h28; // 0xA0  (bits [23:0] used)
localparam [6:0] REG_NDB_BLK2_0    = 7'h29; // 0xA4
localparam [6:0] REG_NDB_BLK2_1    = 7'h2A; // 0xA8
localparam [6:0] REG_NDB_BLK2_2    = 7'h2B; // 0xAC
localparam [6:0] REG_NDB_BLK2_3    = 7'h2C; // 0xB0
localparam [6:0] REG_NDB_BLK2_4    = 7'h2D; // 0xB4
localparam [6:0] REG_NDB_BLK2_5    = 7'h2E; // 0xB8
localparam [6:0] REG_NDB_BLK2_6    = 7'h2F; // 0xBC  (bits [23:0] used)

// MCCH (slot 1) dedicated block1/block2 registers — ACCESS-DEFINE PDU
localparam [6:0] REG_MCCH_BLK1_0   = 7'h30; // 0xC0
localparam [6:0] REG_MCCH_BLK1_1   = 7'h31; // 0xC4
localparam [6:0] REG_MCCH_BLK1_2   = 7'h32; // 0xC8
localparam [6:0] REG_MCCH_BLK1_3   = 7'h33; // 0xCC
localparam [6:0] REG_MCCH_BLK1_4   = 7'h34; // 0xD0
localparam [6:0] REG_MCCH_BLK1_5   = 7'h35; // 0xD4
localparam [6:0] REG_MCCH_BLK1_6   = 7'h36; // 0xD8  (bits [23:0] used)
localparam [6:0] REG_MCCH_BLK2_0   = 7'h37; // 0xDC
localparam [6:0] REG_MCCH_BLK2_1   = 7'h38; // 0xE0
localparam [6:0] REG_MCCH_BLK2_2   = 7'h39; // 0xE4
localparam [6:0] REG_MCCH_BLK2_3   = 7'h3A; // 0xE8
localparam [6:0] REG_MCCH_BLK2_4   = 7'h3B; // 0xEC
localparam [6:0] REG_MCCH_BLK2_5   = 7'h3C; // 0xF0
localparam [6:0] REG_MCCH_BLK2_6   = 7'h3D; // 0xF4  (bits [23:0] used)

// BNCH (frame 18, rotating slot) block1/block2 registers (0xF8–0x12C)
// SCH/HD encoded payload — each block independently coded (216 bits each)
localparam [6:0] REG_BNCH_BLK1_0   = 7'h3E; // 0xF8
localparam [6:0] REG_BNCH_BLK1_1   = 7'h3F; // 0xFC
localparam [6:0] REG_BNCH_BLK1_2   = 7'h40; // 0x100
localparam [6:0] REG_BNCH_BLK1_3   = 7'h41; // 0x104
localparam [6:0] REG_BNCH_BLK1_4   = 7'h42; // 0x108
localparam [6:0] REG_BNCH_BLK1_5   = 7'h43; // 0x10C
localparam [6:0] REG_BNCH_BLK1_6   = 7'h44; // 0x110  (bits [23:0] used)
localparam [6:0] REG_BNCH_BLK2_0   = 7'h45; // 0x114
localparam [6:0] REG_BNCH_BLK2_1   = 7'h46; // 0x118
localparam [6:0] REG_BNCH_BLK2_2   = 7'h47; // 0x11C
localparam [6:0] REG_BNCH_BLK2_3   = 7'h48; // 0x120
localparam [6:0] REG_BNCH_BLK2_4   = 7'h49; // 0x124
localparam [6:0] REG_BNCH_BLK2_5   = 7'h4A; // 0x128
localparam [6:0] REG_BNCH_BLK2_6   = 7'h4B; // 0x12C  (bits [23:0] used)

// TX TDMA timebase AXI interface (Plan §4 Stufe 2 — offsets adjusted to
// avoid collision with existing MCCH_BLK1_0/1 at 0xC0/0xC4).
//   TX_TDMA_LOAD:   write-path for sync-load of the RTL TDMA counter.
//                   Writing bit [31]=1 pulses sync_load_strobe_sys for
//                   exactly one clk_sys cycle; the counter module then
//                   latches the (TN, FN, MN, HN) fields at its next
//                   sym_en tick.
//   TX_TDMA_STATE:  read-only snapshot of the live air-side counter
//                   outputs (TN, FN, MN, HN, sym_cnt) from the timebase
//                   module.  Snapshot is per-bit 2-FF-resynced from
//                   clk_sys → clk_axi; transient inconsistencies between
//                   fields are possible but acceptable (debug/IRQ-ACK
//                   usage — no per-field atomicity required).
// Cell-Config registers (Plan Stufe 3.5) — feed tetra_sb1_encoder (BSCH).
// Slow-changing, written once at boot.  Placed in the first free word
// pair after BNCH_BLK2_6 (0x12C) and before TX_TDMA_LOAD (0x140).
// Plan originally proposed 0xE0/0xE4, but those collide with
// MCCH_BLK2_1/2 in the current layout — moved to 0x130/0x134 to avoid
// breaking the existing MCCH payload path.
localparam [6:0] REG_CELL_CFG_0     = 7'h4C; // 0x130
localparam [6:0] REG_CELL_CFG_1     = 7'h4D; // 0x134

localparam [6:0] REG_TX_TDMA_LOAD   = 7'h50; // 0x140
localparam [6:0] REG_TX_TDMA_STATE  = 7'h51; // 0x144

// ---------------------------------------------------------------------------
// NULL-PDU Register Bank (Plan Stufe 4)
// 7 × 32-bit words at 0x148..0x160 — holds the 216-bit SCH/HD-encoded
// NULL-PDU payload (pre-computed by SW once at boot from the 124-bit
// static pattern 0x0010_8000_0000_..._0000).  The content-mux routes
// these 216 bits into NDB2 BKN1 when the schedule selects class=NULL_PDU
// (1), idx=0.  Word 6 uses bits [23:0] (216 - 6×32 = 24 bits).
// Deviation from plan §4: stored as already-encoded 216 bits rather than
// raw 124 bits — keeps SCH/HD encoding in SW (fixed at boot) and avoids
// adding a hard-coded encoder in RTL for a static pattern.
// ---------------------------------------------------------------------------
localparam [6:0] REG_NULL_PDU_0     = 7'h52; // 0x148
localparam [6:0] REG_NULL_PDU_1     = 7'h53; // 0x14C
localparam [6:0] REG_NULL_PDU_2     = 7'h54; // 0x150
localparam [6:0] REG_NULL_PDU_3     = 7'h55; // 0x154
localparam [6:0] REG_NULL_PDU_4     = 7'h56; // 0x158
localparam [6:0] REG_NULL_PDU_5     = 7'h57; // 0x15C
localparam [6:0] REG_NULL_PDU_6     = 7'h58; // 0x160  (bits [23:0] used)

// ---------------------------------------------------------------------------
// UL MAC-ACCESS PDU Mailbox (Task #36) — 0x164..0x178
// STATUS/SSI/RAW_0..2 are RO snapshots latched on ul_pdu_valid_axi pulse.
// CTRL is W1C — writing [0]=1 clears the sticky valid flag.  If the pulse
// fires the same cycle as the clear write, hw set wins (matches IRQ_STATUS).
// ---------------------------------------------------------------------------
localparam [6:0] REG_UL_PDU_STATUS   = 7'h59; // 0x164  RO  sticky valid + fields
localparam [6:0] REG_UL_PDU_SSI      = 7'h5A; // 0x168  RO  short_ssi[9:0]
localparam [6:0] REG_UL_PDU_RAW_0    = 7'h5B; // 0x16C  RO  raw_info_bits[31:0]
localparam [6:0] REG_UL_PDU_RAW_1    = 7'h5C; // 0x170  RO  raw_info_bits[63:32]
localparam [6:0] REG_UL_PDU_RAW_2    = 7'h5D; // 0x174  RO  raw_info_bits[91:64]
localparam [6:0] REG_UL_PDU_CTRL     = 7'h5E; // 0x178  W1C clear valid sticky
localparam [6:0] REG_UL_SCRAMB_INIT  = 7'h5F; // 0x17C  R/W UL scrambler seed

// Subscriber-Shadow BRAM indirect window (Phase 6 M2.3) — 0x180..0x18C
localparam [6:0] REG_SHADOW_INDEX    = 7'h60; // 0x180  R/W slot index [7:0]
localparam [6:0] REG_SHADOW_DATA_LO  = 7'h61; // 0x184  R/W record [31:0]
localparam [6:0] REG_SHADOW_DATA_HI  = 7'h62; // 0x188  R/W record [63:32]
localparam [6:0] REG_SHADOW_CTRL     = 7'h63; // 0x18C  W1S commit pulse

// MLE registration FSM debug counters (Phase 6 M2.3b)
localparam [6:0] REG_MLE_STATS_A     = 7'h64; // 0x190  RO {accept_cnt[15:0], ul_req_cnt[15:0]}
localparam [6:0] REG_MLE_STATS_B     = 7'h65; // 0x194  RO {15'b0, busy_sticky, drop_cnt[15:0]}
localparam [6:0] REG_MLE_STATS_C     = 7'h66; // 0x198  RO {clear_cnt[15:0], inject_cnt[15:0]}

// ---------------------------------------------------------------------------
// AXI Write Machine — handshake registers
// ---------------------------------------------------------------------------

// AWREADY and WREADY are combinatorial (output wire, R6 compliant)
assign s_axi_awready = !aw_latched_axi;
assign s_axi_wready  = !w_latched_axi;

// wr_handshake_axi: 1-cycle pulse when both address and data are latched,
//                   not waiting for BREADY from a prior response.  Drives
//                   BVALID + latch clears regardless of address — the
//                   slave always ACKs.
wire wr_handshake_axi = aw_latched_axi & w_latched_axi & !s_axi_bvalid;

// wr_en_axi: register-bank-gated write enable.  Fires on wr_handshake_axi
// only when the address falls inside the 0x000..0x1FC register window
// (word-address bits [10:9] == 2'b00).  All existing register writes
// below use wr_en_axi, so widening the address bus for the Schedule-BRAM
// window (0x400..0x63F) does not alias onto the register bank.
wire wr_en_axi = wr_handshake_axi & (wr_addr_axi[10:9] == 2'b00);

// wr_en_sched_axi: schedule-BRAM-gated write enable.  Fires on
// wr_handshake_axi when the address falls inside 0x400..0x63F
// (word-index 0x100..0x18F, 144 words).  Lives here because the
// Schedule-BRAM sits outside this module but uses the same handshake.
wire [8:0] wr_word_idx_axi = wr_addr_axi[10:2];
wire wr_en_sched_axi = wr_handshake_axi &
                        (wr_word_idx_axi >= 9'h100) &
                        (wr_word_idx_axi <  9'h190);

// R1: AW latch register
reg aw_latched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        aw_latched_axi <= 1'b0;
    else if (s_axi_awvalid & s_axi_awready)
        aw_latched_axi <= 1'b1;
    else if (wr_handshake_axi)
        aw_latched_axi <= 1'b0;
end

// R1: Write address register (11-bit for 9-bit word-address decode)
reg [10:0] wr_addr_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        wr_addr_axi <= 11'h000;
    else if (s_axi_awvalid & s_axi_awready)
        wr_addr_axi <= s_axi_awaddr[10:0];
end

// R1: W data latch register
reg w_latched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        w_latched_axi <= 1'b0;
    else if (s_axi_wvalid & s_axi_wready)
        w_latched_axi <= 1'b1;
    else if (wr_handshake_axi)
        w_latched_axi <= 1'b0;
end

// R1: Write data register
reg [31:0] wr_data_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        wr_data_axi <= 32'h0;
    else if (s_axi_wvalid & s_axi_wready)
        wr_data_axi <= s_axi_wdata;
end

// R1: Write strobe register
reg [3:0] wr_strb_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        wr_strb_axi <= 4'h0;
    else if (s_axi_wvalid & s_axi_wready)
        wr_strb_axi <= s_axi_wstrb;
end

// R1: Write response BVALID
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_bvalid <= 1'b0;
    else if (wr_handshake_axi)
        s_axi_bvalid <= 1'b1;
    else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
end

// R1: Write response BRESP (always OKAY — writes outside any window are
// silently dropped but still ACK'd, matching typical AXI-Lite slaves.)
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_bresp <= 2'b00;
    else if (wr_handshake_axi)
        s_axi_bresp <= 2'b00; // OKAY
end

// ---------------------------------------------------------------------------
// AXI Read Machine
// ---------------------------------------------------------------------------
assign s_axi_arready = !ar_latched_axi;

// ar_en_axi: 1-cycle pulse when address is latched but response not yet sent.
// Suppressed while a schedule read is in its 1-cycle BRAM delay (see
// ar_pending_sched_axi below) so the ar_en pulse doesn't re-fire the
// cycle after an in-window read issues.
wire ar_en_axi = ar_latched_axi & !s_axi_rvalid & !ar_pending_sched_axi;

// R1: AR latch register
reg ar_latched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        ar_latched_axi <= 1'b0;
    else if (s_axi_arvalid & s_axi_arready)
        ar_latched_axi <= 1'b1;
    else if (s_axi_rvalid & s_axi_rready)
        ar_latched_axi <= 1'b0;
end

// R1: Read address register (11-bit for 9-bit word-address decode)
reg [10:0] rd_addr_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        rd_addr_axi <= 11'h000;
    else if (s_axi_arvalid & s_axi_arready)
        rd_addr_axi <= s_axi_araddr[10:0];
end

// Schedule-window read-enable pulse: drives the Schedule-BRAM Port A
// read machinery one clk_axi cycle before the rdata mux latches.
wire [8:0] rd_word_idx_axi = rd_addr_axi[10:2];
wire rd_in_sched_window_axi = (rd_word_idx_axi >= 9'h100) &
                               (rd_word_idx_axi <  9'h190);

// Schedule-BRAM port A exposure (Plan Stufe 3) — the BRAM sits in a
// separate module (tetra_slot_schedule) instantiated at the top level.
// Writes: gated wr_en (address in 0x400..0x63F window).
// Reads : one-cycle pulse on ar_en_axi when the address is in window,
//         the BRAM registers its rdata on the next clk_axi cycle, and
//         the rdata mux picks it up the cycle after that when the AR
//         response pipeline latches.
assign schedule_axi_we    = wr_en_sched_axi;
assign schedule_axi_addr  = wr_en_sched_axi ? wr_word_idx_axi[7:0]
                                             : rd_word_idx_axi[7:0];
assign schedule_axi_wdata = wr_data_axi;
assign schedule_axi_wstrb = wr_strb_axi;
assign schedule_axi_re    = ar_en_axi & rd_in_sched_window_axi;

// ---------------------------------------------------------------------------
// Read Data Mux  (combinatorial, R10)
// ---------------------------------------------------------------------------
reg [4:0] irq_status_axi; // declared below; forward ref OK in Verilog
reg [3:0] ctrl_reg_axi;   // declared below
reg [31:0] scratch_axi;   // declared below

reg [31:0] rdata_mux_axi;
always @(*) begin
    case (rd_addr_axi[8:2])
        REG_CTRL:         rdata_mux_axi = {28'b0, ctrl_reg_axi};
        REG_STATUS:       rdata_mux_axi = {24'b0, slot_status_axi,
                                            rx_fifo_full_axi, rx_fifo_empty_axi,
                                            pll_locked_axi,   sync_locked_axi};
        REG_VERSION:      rdata_mux_axi = 32'h0001_0000;
        REG_SYNC_THRESH:  rdata_mux_axi = {24'b0, sync_thresh_axi};
        REG_COLOUR_CODE:  rdata_mux_axi = {26'b0, colour_code_axi};
        REG_FRAME_NUM:    rdata_mux_axi = {27'b0, frame_num_axi};
        REG_SLOT_NUM:     rdata_mux_axi = {30'b0, slot_num_axi};
        REG_RX_GAIN:      rdata_mux_axi = {25'b0, rx_gain_axi};
        REG_TX_ATT:       rdata_mux_axi = {24'b0, tx_att_axi};
        REG_IRQ_ENABLE:   rdata_mux_axi = {27'b0, irq_enable_axi};
        REG_IRQ_STATUS:   rdata_mux_axi = {27'b0, irq_status_axi};
        REG_DMA_BLK_CNT: rdata_mux_axi = {16'b0, dma_block_count_axi};
        REG_CRC_ERR_CNT: rdata_mux_axi = {16'b0, crc_error_count_axi};
        REG_SYNC_LST_CNT:rdata_mux_axi = {16'b0, sync_lost_count_axi};
        REG_TX_TDMA:      rdata_mux_axi = {19'b0, tx_mf_axi, tx_frame_axi, tx_slot_axi};
        REG_SCRATCH:      rdata_mux_axi = scratch_axi;
        REG_DBG_FE_CNT:   rdata_mux_axi = dbg_fe_cnt_axi;
        REG_DBG_DEMOD_CNT: rdata_mux_axi = dbg_demod_cnt_axi;
        REG_DBG_SYNC_CNT: rdata_mux_axi = dbg_sync_cnt_axi;
        REG_DBG_SYNC_UL:  rdata_mux_axi = dbg_sync_ul_axi;
        // SB Payload readback
        REG_SB_SB1_0:    rdata_mux_axi = sb_sb1_w0_axi;
        REG_SB_SB1_1:    rdata_mux_axi = sb_sb1_w1_axi;
        REG_SB_SB1_2:    rdata_mux_axi = sb_sb1_w2_axi;
        REG_SB_SB1_3:    rdata_mux_axi = {8'b0, sb_sb1_w3_axi};
        REG_SB_BKN2_0:   rdata_mux_axi = sb_bkn2_w0_axi;
        REG_SB_BKN2_1:   rdata_mux_axi = sb_bkn2_w1_axi;
        REG_SB_BKN2_2:   rdata_mux_axi = sb_bkn2_w2_axi;
        REG_SB_BKN2_3:   rdata_mux_axi = sb_bkn2_w3_axi;
        REG_SB_BKN2_4:   rdata_mux_axi = sb_bkn2_w4_axi;
        REG_SB_BKN2_5:   rdata_mux_axi = sb_bkn2_w5_axi;
        REG_SB_BKN2_6:   rdata_mux_axi = {8'b0, sb_bkn2_w6_axi};
        REG_SB_BB:        rdata_mux_axi = {2'b0, sb_bb_w0_axi};
        REG_TX_TEST:       rdata_mux_axi = {31'b0, tx_test_prbs_en_axi};
        // NDB block1/block2 readback
        REG_NDB_BLK1_0:   rdata_mux_axi = ndb_blk1_w0_axi;
        REG_NDB_BLK1_1:   rdata_mux_axi = ndb_blk1_w1_axi;
        REG_NDB_BLK1_2:   rdata_mux_axi = ndb_blk1_w2_axi;
        REG_NDB_BLK1_3:   rdata_mux_axi = ndb_blk1_w3_axi;
        REG_NDB_BLK1_4:   rdata_mux_axi = ndb_blk1_w4_axi;
        REG_NDB_BLK1_5:   rdata_mux_axi = ndb_blk1_w5_axi;
        REG_NDB_BLK1_6:   rdata_mux_axi = {8'b0, ndb_blk1_w6_axi};
        REG_NDB_BLK2_0:   rdata_mux_axi = ndb_blk2_w0_axi;
        REG_NDB_BLK2_1:   rdata_mux_axi = ndb_blk2_w1_axi;
        REG_NDB_BLK2_2:   rdata_mux_axi = ndb_blk2_w2_axi;
        REG_NDB_BLK2_3:   rdata_mux_axi = ndb_blk2_w3_axi;
        REG_NDB_BLK2_4:   rdata_mux_axi = ndb_blk2_w4_axi;
        REG_NDB_BLK2_5:   rdata_mux_axi = ndb_blk2_w5_axi;
        REG_NDB_BLK2_6:   rdata_mux_axi = {8'b0, ndb_blk2_w6_axi};
        // MCCH block1/block2 readback
        REG_MCCH_BLK1_0:  rdata_mux_axi = mcch_blk1_w0_axi;
        REG_MCCH_BLK1_1:  rdata_mux_axi = mcch_blk1_w1_axi;
        REG_MCCH_BLK1_2:  rdata_mux_axi = mcch_blk1_w2_axi;
        REG_MCCH_BLK1_3:  rdata_mux_axi = mcch_blk1_w3_axi;
        REG_MCCH_BLK1_4:  rdata_mux_axi = mcch_blk1_w4_axi;
        REG_MCCH_BLK1_5:  rdata_mux_axi = mcch_blk1_w5_axi;
        REG_MCCH_BLK1_6:  rdata_mux_axi = {8'b0, mcch_blk1_w6_axi};
        REG_MCCH_BLK2_0:  rdata_mux_axi = mcch_blk2_w0_axi;
        REG_MCCH_BLK2_1:  rdata_mux_axi = mcch_blk2_w1_axi;
        REG_MCCH_BLK2_2:  rdata_mux_axi = mcch_blk2_w2_axi;
        REG_MCCH_BLK2_3:  rdata_mux_axi = mcch_blk2_w3_axi;
        REG_MCCH_BLK2_4:  rdata_mux_axi = mcch_blk2_w4_axi;
        REG_MCCH_BLK2_5:  rdata_mux_axi = mcch_blk2_w5_axi;
        REG_MCCH_BLK2_6:  rdata_mux_axi = {8'b0, mcch_blk2_w6_axi};
        // BNCH block1/block2 readback
        REG_BNCH_BLK1_0:  rdata_mux_axi = bnch_blk1_w0_axi;
        REG_BNCH_BLK1_1:  rdata_mux_axi = bnch_blk1_w1_axi;
        REG_BNCH_BLK1_2:  rdata_mux_axi = bnch_blk1_w2_axi;
        REG_BNCH_BLK1_3:  rdata_mux_axi = bnch_blk1_w3_axi;
        REG_BNCH_BLK1_4:  rdata_mux_axi = bnch_blk1_w4_axi;
        REG_BNCH_BLK1_5:  rdata_mux_axi = bnch_blk1_w5_axi;
        REG_BNCH_BLK1_6:  rdata_mux_axi = {8'b0, bnch_blk1_w6_axi};
        REG_BNCH_BLK2_0:  rdata_mux_axi = bnch_blk2_w0_axi;
        REG_BNCH_BLK2_1:  rdata_mux_axi = bnch_blk2_w1_axi;
        REG_BNCH_BLK2_2:  rdata_mux_axi = bnch_blk2_w2_axi;
        REG_BNCH_BLK2_3:  rdata_mux_axi = bnch_blk2_w3_axi;
        REG_BNCH_BLK2_4:  rdata_mux_axi = bnch_blk2_w4_axi;
        REG_BNCH_BLK2_5:  rdata_mux_axi = bnch_blk2_w5_axi;
        REG_BNCH_BLK2_6:  rdata_mux_axi = {8'b0, bnch_blk2_w6_axi};
        // Cell-Config registers (Plan Stufe 3.5)
        REG_CELL_CFG_0:   rdata_mux_axi = {16'b0, cell_cfg_0_axi};
        REG_CELL_CFG_1:   rdata_mux_axi = {8'b0,  cell_cfg_1_axi};
        // TX TDMA timebase interface
        REG_TX_TDMA_LOAD: rdata_mux_axi = {13'b0,
                                            tx_tdma_load_hn_axi,
                                            tx_tdma_load_mn_axi,
                                            tx_tdma_load_fn_axi,
                                            tx_tdma_load_tn_axi};
        REG_TX_TDMA_STATE: rdata_mux_axi = {5'b0,
                                             tx_tdma_state_sym_cnt_axi,
                                             tx_tdma_state_hn_axi,
                                             tx_tdma_state_mn_axi,
                                             tx_tdma_state_fn_axi,
                                             tx_tdma_state_tn_axi};
        // NULL-PDU register bank (Plan Stufe 4)
        REG_NULL_PDU_0:   rdata_mux_axi = null_pdu_w0_axi;
        REG_NULL_PDU_1:   rdata_mux_axi = null_pdu_w1_axi;
        REG_NULL_PDU_2:   rdata_mux_axi = null_pdu_w2_axi;
        REG_NULL_PDU_3:   rdata_mux_axi = null_pdu_w3_axi;
        REG_NULL_PDU_4:   rdata_mux_axi = null_pdu_w4_axi;
        REG_NULL_PDU_5:   rdata_mux_axi = null_pdu_w5_axi;
        REG_NULL_PDU_6:   rdata_mux_axi = {8'b0, null_pdu_w6_axi};
        // UL MAC-ACCESS PDU mailbox (Task #36)
        REG_UL_PDU_STATUS: rdata_mux_axi = ul_pdu_status_axi;
        REG_UL_PDU_SSI:    rdata_mux_axi = {22'b0, ul_short_ssi_lat_axi};
        REG_UL_PDU_RAW_0:  rdata_mux_axi = ul_raw_info_bits_lat_axi[31:0];
        REG_UL_PDU_RAW_1:  rdata_mux_axi = ul_raw_info_bits_lat_axi[63:32];
        REG_UL_PDU_RAW_2:  rdata_mux_axi = {4'b0, ul_raw_info_bits_lat_axi[91:64]};
        REG_UL_PDU_CTRL:   rdata_mux_axi = {31'b0, ul_pdu_valid_sticky_axi};
        REG_UL_SCRAMB_INIT: rdata_mux_axi = ul_scramb_init_reg_axi;
        // Subscriber-Shadow indirect window readback (staging regs)
        REG_SHADOW_INDEX:   rdata_mux_axi = {24'b0, shadow_index_axi};
        REG_SHADOW_DATA_LO: rdata_mux_axi = shadow_data_lo_axi;
        REG_SHADOW_DATA_HI: rdata_mux_axi = shadow_data_hi_axi;
        REG_SHADOW_CTRL:    rdata_mux_axi = 32'b0; // self-clearing
        // MLE registration FSM debug
        REG_MLE_STATS_A:    rdata_mux_axi = {mle_accept_cnt_axi, mle_ul_req_cnt_axi};
        REG_MLE_STATS_B:    rdata_mux_axi = {15'b0, mle_busy_sticky_axi, mle_drop_cnt_axi};
        REG_MLE_STATS_C:    rdata_mux_axi = {mle_clear_cnt_axi, mle_inject_cnt_axi};
        default:          rdata_mux_axi = 32'b0;
    endcase
end

// ---------------------------------------------------------------------------
// Read pipeline with 1-cycle latency for Schedule-BRAM
//
// Reads to the register bank are purely combinatorial (rdata_mux_axi),
// so they resolve the same cycle as ar_en_axi.  Reads to the Schedule-
// BRAM window require one extra cycle because the BRAM Port A is a
// synchronous-read memory: on ar_en_axi we pulse schedule_axi_re, and
// the BRAM drives schedule_axi_rdata on the NEXT cycle.
//
// The staging register ar_pending_sched_axi captures "a schedule read
// was issued last cycle"; when it's high we latch rdata from
// schedule_axi_rdata instead of rdata_mux_axi, and we raise RVALID one
// cycle later than a register-bank read.  For register-bank reads the
// original 1-cycle ar_en -> rvalid path is preserved.
// ---------------------------------------------------------------------------
reg ar_pending_sched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        ar_pending_sched_axi <= 1'b0;
    else if (ar_en_axi & rd_in_sched_window_axi)
        ar_pending_sched_axi <= 1'b1;
    else
        ar_pending_sched_axi <= 1'b0;
end

// Effective "this is the cycle to commit rdata" strobe: for register-bank
// reads it's ar_en_axi; for schedule reads it's ar_pending_sched_axi.
wire rdata_commit_axi = (ar_en_axi & ~rd_in_sched_window_axi) |
                        ar_pending_sched_axi;

// R1: RVALID register
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rvalid <= 1'b0;
    else if (rdata_commit_axi)
        s_axi_rvalid <= 1'b1;
    else if (s_axi_rready)
        s_axi_rvalid <= 1'b0;
end

// R1: RDATA register — latched from mux when a read commits.  Schedule
// reads bypass the register-bank mux entirely and take schedule_axi_rdata.
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rdata <= 32'b0;
    else if (ar_pending_sched_axi)
        s_axi_rdata <= schedule_axi_rdata;
    else if (ar_en_axi & ~rd_in_sched_window_axi)
        s_axi_rdata <= rdata_mux_axi;
end

// R1: RRESP register (always OKAY)
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rresp <= 2'b00;
    else if (rdata_commit_axi)
        s_axi_rresp <= 2'b00; // OKAY
end

// ---------------------------------------------------------------------------
// R/W Registers
// ---------------------------------------------------------------------------

// ---- CTRL register (0x00) ----
// ctrl_reg_axi[0]=RX_EN, [1]=TX_EN, [2]=LOOPBACK, [3]=RST_CNTRS
// R1: one always block for the 4-bit CTRL register
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        ctrl_reg_axi <= 4'b0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_CTRL) & wr_strb_axi[0])
        ctrl_reg_axi <= wr_data_axi[3:0];
end

// CTRL outputs as combinatorial wires (R6: output wire for comb)
assign ctrl_rx_enable_axi      = ctrl_reg_axi[0];
assign ctrl_tx_enable_axi      = ctrl_reg_axi[1];
assign ctrl_loopback_en_axi    = ctrl_reg_axi[2];
assign ctrl_reset_counters_axi = ctrl_reg_axi[3];

// ---- SYNC_THRESH register (0x0C) ----
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        sync_thresh_axi <= 8'h0F; // default 15; must be ≤19 for STS (19 symbols), ≤11 for NTS
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SYNC_THRESH) & wr_strb_axi[0])
        sync_thresh_axi <= wr_data_axi[7:0];
end

// ---- COLOUR_CODE register (0x10) ----
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        colour_code_axi <= 6'd1; // default 1
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_COLOUR_CODE) & wr_strb_axi[0])
        colour_code_axi <= wr_data_axi[5:0];
end

// ---- RX_GAIN register (0x1C) ----
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        rx_gain_axi <= 7'h20; // default 32
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_RX_GAIN) & wr_strb_axi[0])
        rx_gain_axi <= wr_data_axi[6:0];
end

// ---- TX_ATT register (0x20) ----
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        tx_att_axi <= 8'h28; // default 40
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_TX_ATT) & wr_strb_axi[0])
        tx_att_axi <= wr_data_axi[7:0];
end

// ---- IRQ_ENABLE register (0x24) ----
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        irq_enable_axi <= 5'b0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_IRQ_ENABLE) & wr_strb_axi[0])
        irq_enable_axi <= wr_data_axi[4:0];
end

// ---- IRQ_STATUS register (0x28) — R/W1C with hardware set ----
// Hardware set:  pulse inputs set corresponding bits
// SW clear:      writing 1 clears a bit (W1C semantics)
// Priority:      hardware SET wins — if hw fires and sw clears simultaneously,
//                the bit stays set (irq_hw_set_axi masks the sw clear)
wire [4:0] irq_hw_set_axi = {irq_rx_fifo_full_axi,
                              irq_crc_error_axi,
                              irq_sync_lost_axi,
                              irq_sync_acquired_axi,
                              irq_mac_block_axi};

wire [4:0] irq_sw_clr_axi = (wr_en_axi & (wr_addr_axi[8:2] == REG_IRQ_STATUS))
                             ? wr_data_axi[4:0] : 5'b0;

// R1: IRQ_STATUS register
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        irq_status_axi <= 5'b0;
    else
        // New value = (current | hw_set) & ~(sw_clr & ~hw_set)
        // hw_set wins: if hw fires on same cycle as sw clears, bit stays 1
        irq_status_axi <= (irq_status_axi | irq_hw_set_axi)
                          & ~(irq_sw_clr_axi & ~irq_hw_set_axi);
end

// ---- SCRATCH register (0x3C) — byte-lane strobes supported ----
// R1: one always block for the 32-bit SCRATCH register
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        scratch_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SCRATCH)) begin
        if (wr_strb_axi[0]) scratch_axi[7:0]   <= wr_data_axi[7:0];
        if (wr_strb_axi[1]) scratch_axi[15:8]  <= wr_data_axi[15:8];
        if (wr_strb_axi[2]) scratch_axi[23:16] <= wr_data_axi[23:16];
        if (wr_strb_axi[3]) scratch_axi[31:24] <= wr_data_axi[31:24];
    end
end

// ---------------------------------------------------------------------------
// SB Payload Registers (0x40–0x7C) — PS-writable broadcast data for TX chain
//
// sb1:  120 bits = 4 × 32-bit words (word 3: only [23:0] used)
//       BSCH coded at RCPC rate 2/3 for continuous downlink burst (§9.4.4.2.6)
// bkn2: 216 bits = 7 × 32-bit words (word 6: only [23:0] used)
// bb:    30 bits = 1 × 32-bit word  (only [29:0] used)
//       RM(30,14) full output — shared across all burst types (AACH)
//
// R1: one always block per 32-bit register slice.
// R3: flat bus outputs (no arrays).
// ---------------------------------------------------------------------------

// ---- SB_SB1 registers (0x40–0x4C) ----
reg [31:0] sb_sb1_w0_axi;
reg [31:0] sb_sb1_w1_axi;
reg [31:0] sb_sb1_w2_axi;
reg [23:0] sb_sb1_w3_axi;  // word 3: only [23:0] (120 - 3×32 = 24 bits)

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_sb1_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_SB1_0)) sb_sb1_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_sb1_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_SB1_1)) sb_sb1_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_sb1_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_SB1_2)) sb_sb1_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_sb1_w3_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_SB1_3)) sb_sb1_w3_axi <= wr_data_axi[23:0];
end

assign sb_sb1_axi = {sb_sb1_w0_axi, sb_sb1_w1_axi, sb_sb1_w2_axi, sb_sb1_w3_axi};

// ---- SB_BKN2 registers (0x60–0x78) ----
reg [31:0] sb_bkn2_w0_axi;
reg [31:0] sb_bkn2_w1_axi;
reg [31:0] sb_bkn2_w2_axi;
reg [31:0] sb_bkn2_w3_axi;
reg [31:0] sb_bkn2_w4_axi;
reg [31:0] sb_bkn2_w5_axi;
reg [23:0] sb_bkn2_w6_axi;  // word 6: only [23:0] (216 - 6×32 = 24 bits)

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_0)) sb_bkn2_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_1)) sb_bkn2_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_2)) sb_bkn2_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_3)) sb_bkn2_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_4)) sb_bkn2_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_5)) sb_bkn2_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bkn2_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BKN2_6)) sb_bkn2_w6_axi <= wr_data_axi[23:0];
end

assign sb_bkn2_axi = {sb_bkn2_w0_axi, sb_bkn2_w1_axi, sb_bkn2_w2_axi, sb_bkn2_w3_axi,
                       sb_bkn2_w4_axi, sb_bkn2_w5_axi, sb_bkn2_w6_axi};

// ---- SB_BB register (0x7C) ----
reg [29:0] sb_bb_w0_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) sb_bb_w0_axi <= 30'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SB_BB)) sb_bb_w0_axi <= wr_data_axi[29:0];
end

assign sb_bb_axi = sb_bb_w0_axi;

// ---- TX_TEST register (0x84) ----
// Bit [0] = PRBS enable (inject 15-bit LFSR dibits into TX chain for spectrum test)
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) tx_test_prbs_en_axi <= 1'b0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_TX_TEST)) tx_test_prbs_en_axi <= wr_data_axi[0];
end

// ---------------------------------------------------------------------------
// NDB block1 registers (0x88–0xA0) — 216 bits in 7 words
// ---------------------------------------------------------------------------
reg [31:0] ndb_blk1_w0_axi;
reg [31:0] ndb_blk1_w1_axi;
reg [31:0] ndb_blk1_w2_axi;
reg [31:0] ndb_blk1_w3_axi;
reg [31:0] ndb_blk1_w4_axi;
reg [31:0] ndb_blk1_w5_axi;
reg [23:0] ndb_blk1_w6_axi;  // word 6: [23:0] (216 - 6×32 = 24 bits)

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_0)) ndb_blk1_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_1)) ndb_blk1_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_2)) ndb_blk1_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_3)) ndb_blk1_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_4)) ndb_blk1_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_5)) ndb_blk1_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk1_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK1_6)) ndb_blk1_w6_axi <= wr_data_axi[23:0];
end

assign ndb_block1_axi = {ndb_blk1_w0_axi, ndb_blk1_w1_axi, ndb_blk1_w2_axi,
                          ndb_blk1_w3_axi, ndb_blk1_w4_axi, ndb_blk1_w5_axi,
                          ndb_blk1_w6_axi};

// ---------------------------------------------------------------------------
// NDB block2 registers (0xA4–0xBC) — 216 bits in 7 words
// ---------------------------------------------------------------------------
reg [31:0] ndb_blk2_w0_axi;
reg [31:0] ndb_blk2_w1_axi;
reg [31:0] ndb_blk2_w2_axi;
reg [31:0] ndb_blk2_w3_axi;
reg [31:0] ndb_blk2_w4_axi;
reg [31:0] ndb_blk2_w5_axi;
reg [23:0] ndb_blk2_w6_axi;  // word 6: [23:0]

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_0)) ndb_blk2_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_1)) ndb_blk2_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_2)) ndb_blk2_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_3)) ndb_blk2_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_4)) ndb_blk2_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_5)) ndb_blk2_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) ndb_blk2_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NDB_BLK2_6)) ndb_blk2_w6_axi <= wr_data_axi[23:0];
end

assign ndb_block2_axi = {ndb_blk2_w0_axi, ndb_blk2_w1_axi, ndb_blk2_w2_axi,
                          ndb_blk2_w3_axi, ndb_blk2_w4_axi, ndb_blk2_w5_axi,
                          ndb_blk2_w6_axi};

// ---------------------------------------------------------------------------
// MCCH block1 registers (slot 1 dedicated — ACCESS-DEFINE PDU)
// R1: one always block per register
// ---------------------------------------------------------------------------
reg [31:0] mcch_blk1_w0_axi;
reg [31:0] mcch_blk1_w1_axi;
reg [31:0] mcch_blk1_w2_axi;
reg [31:0] mcch_blk1_w3_axi;
reg [31:0] mcch_blk1_w4_axi;
reg [31:0] mcch_blk1_w5_axi;
reg [23:0] mcch_blk1_w6_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_0)) mcch_blk1_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_1)) mcch_blk1_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_2)) mcch_blk1_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_3)) mcch_blk1_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_4)) mcch_blk1_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_5)) mcch_blk1_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk1_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK1_6)) mcch_blk1_w6_axi <= wr_data_axi[23:0];
end

assign mcch_block1_axi = {mcch_blk1_w0_axi, mcch_blk1_w1_axi, mcch_blk1_w2_axi,
                           mcch_blk1_w3_axi, mcch_blk1_w4_axi, mcch_blk1_w5_axi,
                           mcch_blk1_w6_axi};

// ---------------------------------------------------------------------------
// MCCH block2 registers
// ---------------------------------------------------------------------------
reg [31:0] mcch_blk2_w0_axi;
reg [31:0] mcch_blk2_w1_axi;
reg [31:0] mcch_blk2_w2_axi;
reg [31:0] mcch_blk2_w3_axi;
reg [31:0] mcch_blk2_w4_axi;
reg [31:0] mcch_blk2_w5_axi;
reg [23:0] mcch_blk2_w6_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_0)) mcch_blk2_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_1)) mcch_blk2_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_2)) mcch_blk2_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_3)) mcch_blk2_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_4)) mcch_blk2_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_5)) mcch_blk2_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) mcch_blk2_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_MCCH_BLK2_6)) mcch_blk2_w6_axi <= wr_data_axi[23:0];
end

assign mcch_block2_axi = {mcch_blk2_w0_axi, mcch_blk2_w1_axi, mcch_blk2_w2_axi,
                           mcch_blk2_w3_axi, mcch_blk2_w4_axi, mcch_blk2_w5_axi,
                           mcch_blk2_w6_axi};

// ---------------------------------------------------------------------------
// BNCH block1 registers (0xF8–0x110) — 216 bits in 7 words
// Frame 18 rotating slot, SCH/HD encoded payload
// ---------------------------------------------------------------------------
reg [31:0] bnch_blk1_w0_axi;
reg [31:0] bnch_blk1_w1_axi;
reg [31:0] bnch_blk1_w2_axi;
reg [31:0] bnch_blk1_w3_axi;
reg [31:0] bnch_blk1_w4_axi;
reg [31:0] bnch_blk1_w5_axi;
reg [23:0] bnch_blk1_w6_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_0)) bnch_blk1_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_1)) bnch_blk1_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_2)) bnch_blk1_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_3)) bnch_blk1_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_4)) bnch_blk1_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_5)) bnch_blk1_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk1_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK1_6)) bnch_blk1_w6_axi <= wr_data_axi[23:0];
end

assign bnch_block1_axi = {bnch_blk1_w0_axi, bnch_blk1_w1_axi, bnch_blk1_w2_axi,
                           bnch_blk1_w3_axi, bnch_blk1_w4_axi, bnch_blk1_w5_axi,
                           bnch_blk1_w6_axi};

// ---------------------------------------------------------------------------
// BNCH block2 registers (0x114–0x12C) — 216 bits in 7 words
// ---------------------------------------------------------------------------
reg [31:0] bnch_blk2_w0_axi;
reg [31:0] bnch_blk2_w1_axi;
reg [31:0] bnch_blk2_w2_axi;
reg [31:0] bnch_blk2_w3_axi;
reg [31:0] bnch_blk2_w4_axi;
reg [31:0] bnch_blk2_w5_axi;
reg [23:0] bnch_blk2_w6_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_0)) bnch_blk2_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_1)) bnch_blk2_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_2)) bnch_blk2_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_3)) bnch_blk2_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_4)) bnch_blk2_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_5)) bnch_blk2_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) bnch_blk2_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_BNCH_BLK2_6)) bnch_blk2_w6_axi <= wr_data_axi[23:0];
end

assign bnch_block2_axi = {bnch_blk2_w0_axi, bnch_blk2_w1_axi, bnch_blk2_w2_axi,
                           bnch_blk2_w3_axi, bnch_blk2_w4_axi, bnch_blk2_w5_axi,
                           bnch_blk2_w6_axi};

// ---------------------------------------------------------------------------
// NULL-PDU Registers (0x148–0x160) — 216 bits in 7 words (Plan Stufe 4)
//
// Stores the pre-computed SCH/HD-coded 216-bit NULL-PDU payload.  SW is
// expected to write this once at boot (after computing SCH/HD of the
// 124-bit static NULL-PDU pattern 0x0010_8000_0000_..._0000 — see
// scripts/gold_schedule.py and project_gold_null_pdu_layout.md).
// Reset default is 0; SW MUST program before enabling NULL_PDU schedule
// entries to avoid transmitting an invalid SCH/HD codeword.
// Word 6 uses bits [23:0] (216 - 6×32 = 24 bits), upper byte RAZ.
// ---------------------------------------------------------------------------
reg [31:0] null_pdu_w0_axi;
reg [31:0] null_pdu_w1_axi;
reg [31:0] null_pdu_w2_axi;
reg [31:0] null_pdu_w3_axi;
reg [31:0] null_pdu_w4_axi;
reg [31:0] null_pdu_w5_axi;
reg [23:0] null_pdu_w6_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w0_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_0)) null_pdu_w0_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w1_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_1)) null_pdu_w1_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w2_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_2)) null_pdu_w2_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w3_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_3)) null_pdu_w3_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w4_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_4)) null_pdu_w4_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w5_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_5)) null_pdu_w5_axi <= wr_data_axi;
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) null_pdu_w6_axi <= 24'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_NULL_PDU_6)) null_pdu_w6_axi <= wr_data_axi[23:0];
end

assign null_pdu_bits_axi = {null_pdu_w0_axi, null_pdu_w1_axi, null_pdu_w2_axi,
                            null_pdu_w3_axi, null_pdu_w4_axi, null_pdu_w5_axi,
                            null_pdu_w6_axi};

// ---------------------------------------------------------------------------
// UL MAC-ACCESS PDU Mailbox (Task #36) — 0x164..0x178
//
// Snapshot registers latch the parser outputs on ul_pdu_valid_axi pulse.
// The valid flag is sticky: set on each pulse, cleared by SW writing
// REG_UL_PDU_CTRL[0]=1.  On simultaneous set+clear the pulse wins so SW
// never misses a PDU that arrived the same cycle it acked a prior one.
// ---------------------------------------------------------------------------
reg        ul_pdu_valid_sticky_axi;
reg [1:0]  ul_pdu_type_lat_axi;
reg        ul_fill_bit_lat_axi;
reg [1:0]  ul_encryption_mode_lat_axi;
reg        ul_access_ack_lat_axi;
reg [2:0]  ul_address_type_lat_axi;
reg [9:0]  ul_short_ssi_lat_axi;
reg [91:0] ul_raw_info_bits_lat_axi;
reg [15:0] ul_pdu_count_lat_axi;

wire ul_pdu_ctrl_wr_axi = wr_en_axi & (wr_addr_axi[8:2] == REG_UL_PDU_CTRL);
wire ul_pdu_sw_clear_axi = ul_pdu_ctrl_wr_axi & wr_strb_axi[0] & wr_data_axi[0];

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        ul_pdu_valid_sticky_axi <= 1'b0;
    else if (ul_pdu_valid_axi)
        ul_pdu_valid_sticky_axi <= 1'b1; // hw-set wins
    else if (ul_pdu_sw_clear_axi)
        ul_pdu_valid_sticky_axi <= 1'b0;
end

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi) begin
        ul_pdu_type_lat_axi        <= 2'd0;
        ul_fill_bit_lat_axi        <= 1'b0;
        ul_encryption_mode_lat_axi <= 2'd0;
        ul_access_ack_lat_axi      <= 1'b0;
        ul_address_type_lat_axi    <= 3'd0;
        ul_short_ssi_lat_axi       <= 10'd0;
        ul_raw_info_bits_lat_axi   <= 92'd0;
        ul_pdu_count_lat_axi       <= 16'd0;
    end else if (ul_pdu_valid_axi) begin
        ul_pdu_type_lat_axi        <= ul_pdu_type_axi;
        ul_fill_bit_lat_axi        <= ul_fill_bit_axi;
        ul_encryption_mode_lat_axi <= ul_encryption_mode_axi;
        ul_access_ack_lat_axi      <= ul_access_ack_axi;
        ul_address_type_lat_axi    <= ul_address_type_axi;
        ul_short_ssi_lat_axi       <= ul_short_ssi_axi;
        ul_raw_info_bits_lat_axi   <= ul_raw_info_bits_axi;
        ul_pdu_count_lat_axi       <= ul_pdu_count_axi;
    end
end

wire [31:0] ul_pdu_status_axi = {ul_pdu_count_lat_axi,           // [31:16]
                                  6'b0,                           // [15:10]
                                  ul_address_type_lat_axi,        // [9:7]
                                  ul_access_ack_lat_axi,          // [6]
                                  ul_encryption_mode_lat_axi,     // [5:4]
                                  ul_fill_bit_lat_axi,            // [3]
                                  ul_pdu_type_lat_axi,            // [2:1]
                                  ul_pdu_valid_sticky_axi};       // [0]

// UL scrambler seed — R/W, full 32-bit, reset = 0.  MCU writes after it
// has computed the cell extended-scrambling init from CC/MCC/MNC (same
// value the DL sb1_encoder implicitly uses for type-2 descrambling on RX).
reg [31:0] ul_scramb_init_reg_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        ul_scramb_init_reg_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_UL_SCRAMB_INIT))
        ul_scramb_init_reg_axi <= wr_data_axi;
end
assign ul_scramb_init_axi = ul_scramb_init_reg_axi;

// ---------------------------------------------------------------------------
// Subscriber-Shadow BRAM indirect write window (Phase 6 M2.3)
// ---------------------------------------------------------------------------
// Staging registers for the 64-bit record + 8-bit slot index.  Written
// from AXI-Lite.  A write to REG_SHADOW_CTRL with wdata[0]=1 fires a
// single-cycle shadow_wr_en pulse that commits the staged values into
// the subscriber-shadow BRAM at the top level.
// ---------------------------------------------------------------------------
reg [7:0]  shadow_index_axi;
reg [31:0] shadow_data_lo_axi;
reg [31:0] shadow_data_hi_axi;
reg        shadow_commit_pulse_axi;

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        shadow_index_axi <= 8'h00;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SHADOW_INDEX) & wr_strb_axi[0])
        shadow_index_axi <= wr_data_axi[7:0];
end

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        shadow_data_lo_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SHADOW_DATA_LO)) begin
        if (wr_strb_axi[0]) shadow_data_lo_axi[7:0]   <= wr_data_axi[7:0];
        if (wr_strb_axi[1]) shadow_data_lo_axi[15:8]  <= wr_data_axi[15:8];
        if (wr_strb_axi[2]) shadow_data_lo_axi[23:16] <= wr_data_axi[23:16];
        if (wr_strb_axi[3]) shadow_data_lo_axi[31:24] <= wr_data_axi[31:24];
    end
end

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        shadow_data_hi_axi <= 32'h0;
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_SHADOW_DATA_HI)) begin
        if (wr_strb_axi[0]) shadow_data_hi_axi[7:0]   <= wr_data_axi[7:0];
        if (wr_strb_axi[1]) shadow_data_hi_axi[15:8]  <= wr_data_axi[15:8];
        if (wr_strb_axi[2]) shadow_data_hi_axi[23:16] <= wr_data_axi[23:16];
        if (wr_strb_axi[3]) shadow_data_hi_axi[31:24] <= wr_data_axi[31:24];
    end
end

// 1-cycle commit pulse on CTRL write with wdata[0]=1.
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        shadow_commit_pulse_axi <= 1'b0;
    else
        shadow_commit_pulse_axi <= wr_en_axi &
                                    (wr_addr_axi[8:2] == REG_SHADOW_CTRL) &
                                    wr_strb_axi[0] &
                                    wr_data_axi[0];
end

assign shadow_wr_idx_axi  = shadow_index_axi;
assign shadow_wr_data_axi = {shadow_data_hi_axi, shadow_data_lo_axi};
assign shadow_wr_en_axi   = shadow_commit_pulse_axi;

// ---------------------------------------------------------------------------
// Cell-Config Registers (0x130 CELL_CFG_0, 0x134 CELL_CFG_1) — Plan Stufe 3.5
//
// CELL_CFG_0 bit layout:
//   [3:0]   sys_code              (default 3 = V+D, matches sw/tetra_sysinfo)
//   [5:4]   sharing_mode          (default 0 = continuous carrier)
//   [8:6]   ts_reserved_frames    (default 0)
//   [9]     uplane_dtx            (default 0)
//   [10]    frame18_ext           (default 1 — own cell sends BNCH SYSINFO
//                                  on F18, matches real cell behaviour)
//   [12:11] neigh_cell_bc         (default 3 — HamTetra cell value)
//   [14:13] cell_service_level    (default 0 — HamTetra cell value)
//   [15]    late_entry_support    (default 1)
//   [31:16] reserved (RAZ)
//
// CELL_CFG_1 bit layout:
//   [9:0]   mcc                   (default 901 — ITU-T E.212 test network)
//   [23:10] mnc                   (default 9998)
//   [31:24] reserved (RAZ)
//
// Reset defaults mirror sw/tetra_hal.c's sysinfo defaults so the RTL
// encoder produces SYNC PDUs consistent with the legacy SW path before
// MCU overrides anything.  ColourCode stays on REG_COLOUR_CODE (0x10).
// ---------------------------------------------------------------------------
reg [15:0] cell_cfg_0_axi;  // only [15:0] used; [31:16] reserved
reg [23:0] cell_cfg_1_axi;  // only [23:0] used; [31:24] reserved

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        cell_cfg_0_axi <= {1'b1,         // [15]    late_entry_support = 1
                           2'b00,        // [14:13] cell_service_level = 0
                           2'b11,        // [12:11] neigh_cell_bc = 3
                           1'b1,         // [10]    frame18_ext = 1
                           1'b0,         // [9]     uplane_dtx = 0
                           3'b000,       // [8:6]   ts_reserved_frames = 0
                           2'b00,        // [5:4]   sharing_mode = 0
                           4'd3};        // [3:0]   sys_code = 3 (V+D)
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_CELL_CFG_0))
        cell_cfg_0_axi <= wr_data_axi[15:0];
end

always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        cell_cfg_1_axi <= {14'd9998,   // [23:10] mnc = 9998
                           10'd901};   // [9:0]   mcc = 901
    else if (wr_en_axi & (wr_addr_axi[8:2] == REG_CELL_CFG_1))
        cell_cfg_1_axi <= wr_data_axi[23:0];
end

assign cell_cfg_sys_code_axi           = cell_cfg_0_axi[3:0];
assign cell_cfg_sharing_mode_axi       = cell_cfg_0_axi[5:4];
assign cell_cfg_ts_reserved_frames_axi = cell_cfg_0_axi[8:6];
assign cell_cfg_uplane_dtx_axi         = cell_cfg_0_axi[9];
assign cell_cfg_frame18_ext_axi        = cell_cfg_0_axi[10];
assign cell_cfg_neigh_cell_bc_axi      = cell_cfg_0_axi[12:11];
assign cell_cfg_cell_service_level_axi = cell_cfg_0_axi[14:13];
assign cell_cfg_late_entry_support_axi = cell_cfg_0_axi[15];
assign cell_cfg_mcc_axi                = cell_cfg_1_axi[9:0];
assign cell_cfg_mnc_axi                = cell_cfg_1_axi[23:10];

// ---------------------------------------------------------------------------
// TX TDMA Timebase AXI interface (0x140 LOAD, 0x144 STATE) — Plan Stufe 2
//
// LOAD register layout:
//   [1:0]   TN           (0..3,  air-side 0-based)
//   [6:2]   FN           (0..17, air-side 0-based)
//   [12:7]  MN           (0..59, air-side 0-based)
//   [18:13] HN           (0..63, 6-bit free-running hyperframe)
//   [31]    STROBE       write-1 → single-cycle sync_load_strobe pulse
//                         (data is latched on the SAME AXI write, strobe
//                         fires one clk_axi cycle on that same write;
//                         writing TN/FN/MN/HN *without* STROBE=1 updates
//                         the data registers but does not move the RTL
//                         counter — next write with STROBE=1 commits the
//                         most recently written values).
//   [30:19] reserved, writes ignored, reads as 0
//
// STATE register layout:  (read-only mirror of timebase counter outputs
//                          after 2-FF resync in the top-level)
//   [1:0]   TN
//   [6:2]   FN
//   [12:7]  MN
//   [18:13] HN
//   [26:19] sym_cnt       8 bit, 0..254
//   [31:27] reserved, reads as 0
//
// STROBE semantics: sync_load_strobe output is a 1-clk_axi-cycle pulse
// fired on the cycle wr_en_axi fires against REG_TX_TDMA_LOAD with
// wr_data_axi[31]=1 (and wstrb[3] set so the strobe byte lane is active).
// Top-level 2-FF-resyncs the pulse into clk_sys (clk_sys and clk_axi
// share a PLL source — see tetra_zynq_top.v header — so a 2-stage
// synchronizer is enough to absorb the one-cycle pulse).
// ---------------------------------------------------------------------------
reg [1:0] tx_tdma_load_tn_axi;
reg [4:0] tx_tdma_load_fn_axi;
reg [5:0] tx_tdma_load_mn_axi;
reg [5:0] tx_tdma_load_hn_axi;

// A single AXI write whose data byte 3 has bit 7 (i.e. wdata[31]) set
// AND whose wstrb[3] is active is treated as a strobe write.  The data
// fields (TN/FN/MN/HN) are latched on every LOAD write regardless of
// STROBE — so SW can optionally pre-load the fields on one write and
// fire STROBE on a second write if it wants to.  The simpler, expected
// usage is a single write with all fields + STROBE=1 set at once.
wire tx_tdma_load_wr_axi = wr_en_axi & (wr_addr_axi[8:2] == REG_TX_TDMA_LOAD);

// Data-field latches (independent per field so wstrb byte lanes work
// sensibly — but since TN/FN/MN/HN straddle byte boundaries the driver
// is expected to issue full-word writes.  We simply guard by strobe[0]
// for TN/FN (bits 0..6 → byte 0), strobe[1] for MN + low HN (bits
// 7..15 → byte 1), strobe[2] for upper HN (bits 16..18 → byte 2).
// To keep the logic simple and the common case correct, any write whose
// wstrb != 0 updates all four fields — SW always writes full 32-bit
// words anyway.)
// R1: one always block per data field register.
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)                      tx_tdma_load_tn_axi <= 2'd0;
    else if (tx_tdma_load_wr_axi)        tx_tdma_load_tn_axi <= wr_data_axi[1:0];
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)                      tx_tdma_load_fn_axi <= 5'd0;
    else if (tx_tdma_load_wr_axi)        tx_tdma_load_fn_axi <= wr_data_axi[6:2];
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)                      tx_tdma_load_mn_axi <= 6'd0;
    else if (tx_tdma_load_wr_axi)        tx_tdma_load_mn_axi <= wr_data_axi[12:7];
end
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)                      tx_tdma_load_hn_axi <= 6'd0;
    else if (tx_tdma_load_wr_axi)        tx_tdma_load_hn_axi <= wr_data_axi[18:13];
end

// Strobe pulse — 1 clk_axi cycle when LOAD is written with bit 31 set.
// R1: dedicated register.  Note: the pulse fires the cycle wr_en_axi
// is high (same cycle the data fields latch above), so the top-level
// resynchronizer sees a strobe whose captured-data is already stable.
reg tx_tdma_strobe_pulse_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        tx_tdma_strobe_pulse_axi <= 1'b0;
    else
        tx_tdma_strobe_pulse_axi <= tx_tdma_load_wr_axi & wr_data_axi[31];
end

assign tx_tdma_sync_tn_axi     = tx_tdma_load_tn_axi;
assign tx_tdma_sync_fn_axi     = tx_tdma_load_fn_axi;
assign tx_tdma_sync_mn_axi     = tx_tdma_load_mn_axi;
assign tx_tdma_sync_hn_axi     = tx_tdma_load_hn_axi;
assign tx_tdma_sync_strobe_axi = tx_tdma_strobe_pulse_axi;

// ---------------------------------------------------------------------------
// IRQ output — registered OR-reduce of (status & enable)
// R1: irq_out_axi register
// ---------------------------------------------------------------------------
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        irq_out_axi <= 1'b0;
    else
        irq_out_axi <= |(irq_status_axi & irq_enable_axi);
end

endmodule

`default_nettype wire
