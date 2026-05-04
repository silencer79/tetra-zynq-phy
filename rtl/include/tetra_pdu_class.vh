// =============================================================================
// tetra_pdu_class.vh — central DL PDU-class definitions (Phase Z.3)
//
// Single source of truth for the (slot_format, AACH-pattern, addr_type,
// llc_pdu_type, random_access_flag) tuple of every signalling-class DL
// PDU produced by this design.  Replaces hardcoded 2'd0 / 2'd1 / 14'h0009 /
// 14'h0249 / 4'd0 / 4'd8 / 3'd1 literals scattered across producer modules
// and tetra_zynq_top.v.
//
// Soll-Tabelle (Gold-conform — see references):
//
//   Class                          | Slot     | AACH    | TN   | LLC          | RA | Encoder
//   -------------------------------+----------+---------+------+--------------+----+---------------
//   PDUC_PRE_REPLY_SLOTGRANT_LU    | SCH/F    | 0x0009  | mcch | AL-SETUP (8) | 1  | sch_f  268→432
//   PDUC_PRE_REPLY_SLOTGRANT_GRP   | SCH/HD   | 0x0009  | mcch | AL-SETUP (8) | 1  | sch_hd 124→216
//   PDUC_FINAL_LU_ACCEPT           | SCH/F    | 0x0009  | mcch | BL-ADATA (0) | 0  | sch_f  268→432
//   PDUC_FINAL_LU_REJECT           | SCH/HD   | 0x0009  | mcch | BL-ADATA (0) | 0  | sch_hd 124→216
//   PDUC_GROUP_ACK                 | SCH/F    | 0x0009  | mcch | BL-ADATA (0) | 0  | sch_f  268→432
//   PDUC_BL_ACK_POST_FRAG2         | SCH/HD   | 0x0249  | mcch | BL-ACK       | 0  | sch_hd 124→216
//   PDUC_NWRK_BCAST                | SCH/F    | 0x0249  | mcch | BL-UDATA     | 0  | sch_f  (SW-prepacked)
//
// Sources:
//   - reference_gold_full_attach_timeline.md (mm=2 Pre-Reply LI=7 +
//     Final LU-ACCEPT LI=21 + DETACH-ACK BL-ACK 0x0249 idle + D-NWRK
//     0x0249 cadence)
//   - reference_gold_group_switch_burst_timeline.md (mm=7 Group-Switch
//     LI=7 Pre-Reply identical AL-SETUP pattern + LI=16 Group-ACK)
//   - project_h7_d_nwrk_broadcast.md (D-NWRK-BCAST AACH 0x0249 idle)
//
// Constraints:
//   - Verilog-2001 strict: declarations are emitted via `define so the
//     same header can be included at module scope (where `parameter` and
//     `localparam` are not allowed at file scope per IEEE 1364-2001).
//   - Bit widths match the existing producer-module port widths
//     (pdu_type=2 bits, aach_pattern=14 bits, addr_type=3 bits,
//     llc_pdu_type=4 bits, ra_flag=1 bit).
// =============================================================================
`ifndef TETRA_PDU_CLASS_VH
`define TETRA_PDU_CLASS_VH

// -----------------------------------------------------------------------------
// Slot formats (queue.pdu_type / scheduler / slot_content_mux convention)
// -----------------------------------------------------------------------------
`define PDUC_SLOTFMT_SCH_F   2'd0
`define PDUC_SLOTFMT_SCH_HD  2'd1
// SCH_F  = NDB1 432 coded bits;  SCH_HD = NDB2 216 coded bits

// -----------------------------------------------------------------------------
// AACH patterns (raw 14-bit AACH content as latched into the queue/scheduler)
// -----------------------------------------------------------------------------
`define PDUC_AACH_SIGNALLING_ACTIVE  14'h0009
`define PDUC_AACH_IDLE               14'h0249
// PDUC_AACH_TRAFFIC_IDLE — AACH for F1-17 TN!=0 idle traffic-slots.
// Gold-cell capture (2026-05-04 audit) zeigt konstantes
//   header=11 (CapAlloc) + Field1=000000 + Field2=000000 = 14'h3000
// unabhängig von cell-CC, MNC, MCC.  Vor dem Audit hatte der Encoder
// hier 14'h32CB = CapAlloc f1=11 f2=11 — das war Drift gegen Gold.
`define PDUC_AACH_TRAFFIC_IDLE       14'h3000

// -----------------------------------------------------------------------------
// Address-type ETSI EN 300 392-2 Table 21.66
// -----------------------------------------------------------------------------
`define PDUC_ADDRTYPE_SSI  3'd1

// -----------------------------------------------------------------------------
// LLC PDU-type encodings (ETSI EN 300 392-2 §23.4)
// -----------------------------------------------------------------------------
`define PDUC_LLC_BL_ADATA   4'd0
`define PDUC_LLC_BL_UDATA   4'd1
`define PDUC_LLC_BL_ACK     4'd2
`define PDUC_LLC_AL_SETUP   4'd8
// LLC notes:
//   BL-ADATA  — carries MLE+MM
//   BL-UDATA  — broadcast (D-NWRK)
//   BL-ACK    — pseudo-code, info only; bl_ack body is hand-packed in
//               mac_resource_bl_ack_builder
//   AL-SETUP  — 7-octet wrapper

// =============================================================================
// PDUC_PRE_REPLY_SLOTGRANT_LU
//   - mm=2 ITSI-Attach Pre-Reply LI=7 AL-SETUP
//   - SCH/F slot, AACH 0x0009 (signalling-active).  Historic working path
//     for the MTP3550 in our cell — pre-Z.3 mm=2 used SCH/F via shared
//     dl_pdu_builder with hardcoded slot_granting_flag=1 + element=0x01
//     (cad69e0).  Reverting Z.3's mm=2-on-SCH/HD attempt that broke the
//     MS's Frag-2 trigger.
// =============================================================================
`define PDUC_PRE_REPLY_SLOTGRANT_LU_FMT       `PDUC_SLOTFMT_SCH_F
`define PDUC_PRE_REPLY_SLOTGRANT_LU_AACH      `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_PRE_REPLY_SLOTGRANT_LU_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_PRE_REPLY_SLOTGRANT_LU_LLC       `PDUC_LLC_AL_SETUP
`define PDUC_PRE_REPLY_SLOTGRANT_LU_RA        1'b1

// =============================================================================
// PDUC_PRE_REPLY_SLOTGRANT_GRP
//   - mm=7 Group-Switch Pre-Reply LI=7 AL-SETUP
//   - SCH/HD slot, AACH 0x0009 (Gold-conform per
//     reference_gold_group_switch_burst_timeline.md), sg_flag=1 sg_element=0x00.
// =============================================================================
`define PDUC_PRE_REPLY_SLOTGRANT_GRP_FMT       `PDUC_SLOTFMT_SCH_HD
`define PDUC_PRE_REPLY_SLOTGRANT_GRP_AACH      `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_PRE_REPLY_SLOTGRANT_GRP_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_PRE_REPLY_SLOTGRANT_GRP_LLC       `PDUC_LLC_AL_SETUP
`define PDUC_PRE_REPLY_SLOTGRANT_GRP_RA        1'b1

// =============================================================================
// PDUC_FINAL_LU_ACCEPT — mm=2 Final D-LOC-UPDATE-ACCEPT LI=21 SCH/F
// =============================================================================
`define PDUC_FINAL_LU_ACCEPT_FMT       `PDUC_SLOTFMT_SCH_F
`define PDUC_FINAL_LU_ACCEPT_AACH      `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_FINAL_LU_ACCEPT_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_FINAL_LU_ACCEPT_LLC       `PDUC_LLC_BL_ADATA
`define PDUC_FINAL_LU_ACCEPT_RA        1'b0

// =============================================================================
// PDUC_FINAL_LU_REJECT — mm=4 D-LOC-UPDATE-REJECT LI=7 SCH/HD blk1
// =============================================================================
`define PDUC_FINAL_LU_REJECT_FMT       `PDUC_SLOTFMT_SCH_HD
`define PDUC_FINAL_LU_REJECT_AACH      `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_FINAL_LU_REJECT_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_FINAL_LU_REJECT_LLC       `PDUC_LLC_BL_ADATA
`define PDUC_FINAL_LU_REJECT_RA        1'b0

// =============================================================================
// PDUC_GROUP_ACK — mm=11 D-ATTACH-DETACH-GRP-ID-ACK LI=16 SCH/F
// =============================================================================
`define PDUC_GROUP_ACK_FMT       `PDUC_SLOTFMT_SCH_F
`define PDUC_GROUP_ACK_AACH      `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_GROUP_ACK_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_GROUP_ACK_LLC       `PDUC_LLC_BL_ADATA
`define PDUC_GROUP_ACK_RA        1'b0

// =============================================================================
// PDUC_BL_ACK_POST_FRAG2 — Post-Frag-2 BL-ACK LI=6 SCH/HD blk1
//   Gold: AACH stays at 0x0249 idle on this slot (DETACH-ACK + post-Frag-2
//   BL-ACK use idle, NOT 0x0009).  reference_gold_full_attach_timeline.md
//   Z. 138-143.
// =============================================================================
`define PDUC_BL_ACK_POST_FRAG2_FMT       `PDUC_SLOTFMT_SCH_HD
`define PDUC_BL_ACK_POST_FRAG2_AACH      `PDUC_AACH_IDLE
`define PDUC_BL_ACK_POST_FRAG2_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_BL_ACK_POST_FRAG2_LLC       `PDUC_LLC_BL_ACK
`define PDUC_BL_ACK_POST_FRAG2_RA        1'b0

// =============================================================================
// PDUC_NWRK_BCAST — D-NWRK-BROADCAST LI=16 BL-UDATA (broadcast addr=0xFFFFFF)
//   Gold: AACH 0x0249 idle on this slot, ~10 s cadence.
// =============================================================================
`define PDUC_NWRK_BCAST_FMT       `PDUC_SLOTFMT_SCH_F
`define PDUC_NWRK_BCAST_AACH      `PDUC_AACH_IDLE
`define PDUC_NWRK_BCAST_ADDRTYPE  `PDUC_ADDRTYPE_SSI
`define PDUC_NWRK_BCAST_LLC       `PDUC_LLC_BL_UDATA
`define PDUC_NWRK_BCAST_RA        1'b0

`endif // TETRA_PDU_CLASS_VH
