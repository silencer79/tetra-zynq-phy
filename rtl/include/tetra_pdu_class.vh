// =============================================================================
// tetra_pdu_class.vh — central DL PDU-class definitions (Phase Z.3)
//
// Single source of truth for the (slot_format, AACH-pattern, addr_type,
// llc_pdu_type, random_access_flag) tuple of every signalling-class DL
// PDU produced by this design. Replaces hardcoded 2'd0 / 2'd1 / 14'h0009 /
// 14'h0249 / 4'd0 / 4'd8 / 3'd1 literals scattered across producer modules
// and tetra_zynq_top.v.
//
// Soll-Tabelle (spec-conform — see references):
//
// Class | Slot | AACH | TN | LLC | RA | Encoder
// -------------------------------+----------+---------+------+--------------+----+---------------
// PDUC_PRE_REPLY_SLOTGRANT | SCH/HD | 0x0009 | mcch | AL-SETUP (8) | 1 | sch_hd 124→216
// (Phase Z.9: single-path for both mm=2 ITSI-Attach and mm=7 Group-Switch.)
// PDUC_FINAL_LU_ACCEPT | SCH/F | 0x0009 | mcch | BL-ADATA (0) | 0 | sch_f 268→432
// PDUC_FINAL_LU_REJECT | SCH/HD | 0x0009 | mcch | BL-ADATA (0) | 0 | sch_hd 124→216
// PDUC_GROUP_ACK | SCH/F | 0x0009 | mcch | BL-ADATA (0) | 0 | sch_f 268→432
// PDUC_BL_ACK_POST_FRAG2 | SCH/HD | 0x0249 | mcch | BL-ACK | 0 | sch_hd 124→216
// PDUC_NWRK_BCAST | SCH/F | 0x0249 | mcch | BL-UDATA | 0 | sch_f (SW-prepacked)
//
// Sources:
// - removed-memory (mm=2 Pre-Reply LI=7 +
// Final LU-ACCEPT LI=21 + DETACH-ACK BL-ACK 0x0249 idle + D-NWRK
// 0x0249 cadence)
// - removed-memory (mm=7 Group-Switch
// LI=7 Pre-Reply identical AL-SETUP pattern + LI=16 Group-ACK)
// - project_h7_d_nwrk_broadcast.md (D-NWRK-BCAST AACH 0x0249 idle)
//
// Constraints:
// - Verilog-2001 strict: declarations are emitted via `define so the
// same header can be included at module scope (where `parameter` and
// `localparam` are not allowed at file scope per IEEE 1364-2001).
// - Bit widths match the existing producer-module port widths
// (pdu_type=2 bits, aach_pattern=14 bits, addr_type=3 bits,
// llc_pdu_type=4 bits, ra_flag=1 bit).
// =============================================================================
`ifndef TETRA_PDU_CLASS_VH
`define TETRA_PDU_CLASS_VH

// -----------------------------------------------------------------------------
// Slot formats (queue.pdu_type / scheduler / slot_content_mux convention)
// -----------------------------------------------------------------------------
`define PDUC_SLOTFMT_SCH_F 2'd0
`define PDUC_SLOTFMT_SCH_HD 2'd1
// SCH_F = NDB1 432 coded bits; SCH_HD = NDB2 216 coded bits

// -----------------------------------------------------------------------------
// AACH patterns (raw 14-bit AACH content as latched into the queue/scheduler)
// -----------------------------------------------------------------------------
`define PDUC_AACH_SIGNALLING_ACTIVE 14'h0009
`define PDUC_AACH_IDLE 14'h0249
// PDUC_AACH_TRAFFIC_IDLE — AACH for F1-17 TN!=0 idle traffic-slots.
// cell capture (2026-05-04 audit) zeigt konstantes
// header=11 (CapAlloc) + Field1=000000 + Field2=000000 = 14'h3000
// unabhängig von cell-CC, MNC, MCC. Vor dem Audit hatte der Encoder
// hier 14'h32CB = CapAlloc f1=11 f2=11 — das war Drift gegen.
`define PDUC_AACH_TRAFFIC_IDLE 14'h3000

// -----------------------------------------------------------------------------
// Address-type ETSI EN 300 392-2 Table 21.66
// -----------------------------------------------------------------------------
`define PDUC_ADDRTYPE_SSI 3'd1
`define PDUC_ADDRTYPE_SSI_AND_USAGE 3'd6 // ETSI 21.4.3.1, MAC addressing for call-bound bursts

// -----------------------------------------------------------------------------
// LLC PDU-type encodings (ETSI EN 300 392-2 §23.4)
// -----------------------------------------------------------------------------
`define PDUC_LLC_BL_ADATA 4'd0
`define PDUC_LLC_BL_DATA 4'd1
`define PDUC_LLC_BL_UDATA 4'd2
`define PDUC_LLC_BL_ACK 4'd3
`define PDUC_LLC_AL_SETUP 4'd8
// LLC notes:
// BL-ADATA — carries MLE+MM
// BL-UDATA — broadcast (D-NWRK)
// BL-ACK — pseudo-code, info only; bl_ack body is hand-packed in
// mac_resource_bl_ack_builder
// AL-SETUP — 7-octet wrapper

// =============================================================================
// PDUC_PRE_REPLY_SLOTGRANT — single Pre-Reply path for BOTH mm=2 (ITSI-Attach)
// and mm=7 (Group-Switch). Phase Z.9 collapses the previous LU/GRP split:
// - SCH/HD slot (216-bit blk1, BKN2 carries SYSINFO companion)
// - AACH 0x0009 (signalling-active)
// - SSI addressing, AL-SETUP LLC, RA=1, slot_granting_flag=1,
// slot_granting_element=0x00 (Ref bit-pattern for both mm-types per
// removed-memory + removed-memory_
// burst_timeline.md — both timelines share the same Pre-Reply Body).
// =============================================================================
`define PDUC_PRE_REPLY_SLOTGRANT_FMT `PDUC_SLOTFMT_SCH_HD
`define PDUC_PRE_REPLY_SLOTGRANT_AACH `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_PRE_REPLY_SLOTGRANT_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_PRE_REPLY_SLOTGRANT_LLC `PDUC_LLC_AL_SETUP
`define PDUC_PRE_REPLY_SLOTGRANT_RA 1'b1

// =============================================================================
// PDUC_FINAL_LU_ACCEPT — mm=2 Final D-LOC-UPDATE-ACCEPT LI=21 SCH/F
// =============================================================================
`define PDUC_FINAL_LU_ACCEPT_FMT `PDUC_SLOTFMT_SCH_F
`define PDUC_FINAL_LU_ACCEPT_AACH `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_FINAL_LU_ACCEPT_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_FINAL_LU_ACCEPT_LLC `PDUC_LLC_BL_ADATA
`define PDUC_FINAL_LU_ACCEPT_RA 1'b0

// =============================================================================
// PDUC_FINAL_LU_REJECT — mm=4 D-LOC-UPDATE-REJECT LI=7 SCH/HD blk1
// =============================================================================
`define PDUC_FINAL_LU_REJECT_FMT `PDUC_SLOTFMT_SCH_HD
`define PDUC_FINAL_LU_REJECT_AACH `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_FINAL_LU_REJECT_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_FINAL_LU_REJECT_LLC `PDUC_LLC_BL_ADATA
`define PDUC_FINAL_LU_REJECT_RA 1'b0

// =============================================================================
// PDUC_GROUP_ACK — mm=11 D-ATTACH-DETACH-GRP-ID-ACK LI=16 SCH/F
// =============================================================================
`define PDUC_GROUP_ACK_FMT `PDUC_SLOTFMT_SCH_F
`define PDUC_GROUP_ACK_AACH `PDUC_AACH_SIGNALLING_ACTIVE
`define PDUC_GROUP_ACK_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_GROUP_ACK_LLC `PDUC_LLC_BL_ADATA
`define PDUC_GROUP_ACK_RA 1'b0

// =============================================================================
// PDUC_CMCE_D_CONNECT — D-CONNECT / D-SETUP / D-TX-GRANTED Group-Call bursts.
// Cell `reference-DL.wav` Burst #5887/#5895/#5903 (2026-05-13):
// - SCH/F (NDB1) 432-bit coded
// - AACH 0x0249 idle (NOT signalling-active — CMCE has no UL-slot grant)
// - addr_type=SsiAndUsageMarker (= 6, includes 8-bit UsageMarker)
// - LLC = BL-UDATA (unacknowledged — no NS/NR stop-and-wait)
// - RA=0 (addressed, not random access)
// Repeated 3× in for reliability (BL-UDATA has no acknowledgement).
// =============================================================================
`define PDUC_CMCE_D_CONNECT_FMT `PDUC_SLOTFMT_SCH_F
`define PDUC_CMCE_D_CONNECT_AACH `PDUC_AACH_IDLE
`define PDUC_CMCE_D_CONNECT_ADDRTYPE `PDUC_ADDRTYPE_SSI_AND_USAGE
`define PDUC_CMCE_D_CONNECT_LLC `PDUC_LLC_BL_UDATA
`define PDUC_CMCE_D_CONNECT_RA 1'b0

// =============================================================================
// PDUC_BL_ACK_POST_FRAG2 — Post-Frag-2 BL-ACK LI=6 SCH/HD blk1
//: AACH stays at 0x0249 idle on this slot (DETACH-ACK + post-Frag-2
// BL-ACK use idle, NOT 0x0009). removed-memory
// Z. 138-143.
// =============================================================================
`define PDUC_BL_ACK_POST_FRAG2_FMT `PDUC_SLOTFMT_SCH_HD
`define PDUC_BL_ACK_POST_FRAG2_AACH `PDUC_AACH_IDLE
`define PDUC_BL_ACK_POST_FRAG2_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_BL_ACK_POST_FRAG2_LLC `PDUC_LLC_BL_ACK
`define PDUC_BL_ACK_POST_FRAG2_RA 1'b0

// =============================================================================
// PDUC_NWRK_BCAST — D-NWRK-BROADCAST LI=16 BL-UDATA (broadcast addr=0xFFFFFF)
//: AACH 0x0249 idle on this slot, ~10 s cadence.
// =============================================================================
`define PDUC_NWRK_BCAST_FMT `PDUC_SLOTFMT_SCH_F
`define PDUC_NWRK_BCAST_AACH `PDUC_AACH_IDLE
`define PDUC_NWRK_BCAST_ADDRTYPE `PDUC_ADDRTYPE_SSI
`define PDUC_NWRK_BCAST_LLC `PDUC_LLC_BL_UDATA
`define PDUC_NWRK_BCAST_RA 1'b0

`endif // TETRA_PDU_CLASS_VH
