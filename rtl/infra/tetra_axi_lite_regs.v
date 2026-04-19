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
    input  wire [31:0] dbg_sync_cnt_axi,  // Sync found count

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
localparam [6:0] REG_DBG_SYNC_CNT = 7'h16; // 0x58  Sync found count
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

// ---------------------------------------------------------------------------
// AXI Write Machine — handshake registers
// ---------------------------------------------------------------------------

// AWREADY and WREADY are combinatorial (output wire, R6 compliant)
assign s_axi_awready = !aw_latched_axi;
assign s_axi_wready  = !w_latched_axi;

// wr_en_axi: 1-cycle pulse when both address and data are latched,
//            not waiting for BREADY from a prior response.
wire wr_en_axi = aw_latched_axi & w_latched_axi & !s_axi_bvalid;

// R1: AW latch register
reg aw_latched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        aw_latched_axi <= 1'b0;
    else if (s_axi_awvalid & s_axi_awready)
        aw_latched_axi <= 1'b1;
    else if (wr_en_axi)
        aw_latched_axi <= 1'b0;
end

// R1: Write address register
reg [8:0] wr_addr_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        wr_addr_axi <= 9'h000;
    else if (s_axi_awvalid & s_axi_awready)
        wr_addr_axi <= s_axi_awaddr[8:0];
end

// R1: W data latch register
reg w_latched_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        w_latched_axi <= 1'b0;
    else if (s_axi_wvalid & s_axi_wready)
        w_latched_axi <= 1'b1;
    else if (wr_en_axi)
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
    else if (wr_en_axi)
        s_axi_bvalid <= 1'b1;
    else if (s_axi_bready)
        s_axi_bvalid <= 1'b0;
end

// R1: Write response BRESP (always OKAY)
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_bresp <= 2'b00;
    else if (wr_en_axi)
        s_axi_bresp <= 2'b00; // OKAY
end

// ---------------------------------------------------------------------------
// AXI Read Machine
// ---------------------------------------------------------------------------
assign s_axi_arready = !ar_latched_axi;

// ar_en_axi: 1-cycle pulse when address is latched but response not yet sent
wire ar_en_axi = ar_latched_axi & !s_axi_rvalid;

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

// R1: Read address register
reg [8:0] rd_addr_axi;
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        rd_addr_axi <= 9'h000;
    else if (s_axi_arvalid & s_axi_arready)
        rd_addr_axi <= s_axi_araddr[8:0];
end

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
        default:          rdata_mux_axi = 32'b0;
    endcase
end

// R1: RVALID register
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rvalid <= 1'b0;
    else if (ar_en_axi)
        s_axi_rvalid <= 1'b1;
    else if (s_axi_rready)
        s_axi_rvalid <= 1'b0;
end

// R1: RDATA register — latched from mux when ar_en fires
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rdata <= 32'b0;
    else if (ar_en_axi)
        s_axi_rdata <= rdata_mux_axi;
end

// R1: RRESP register (always OKAY)
always @(posedge clk_axi or negedge rst_n_axi) begin
    if (!rst_n_axi)
        s_axi_rresp <= 2'b00;
    else if (ar_en_axi)
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
