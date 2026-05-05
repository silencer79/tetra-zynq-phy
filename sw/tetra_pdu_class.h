/*
 * tetra_pdu_class.h — central DL PDU-class definitions (Phase Z.9, SW-side mirror)
 *
 * Mirror of rtl/include/tetra_pdu_class.vh.  Used by sw/tetra_attach_daemon.c
 * and sw/tetra_tx_transport.c whenever they need to reason about a DL
 * signalling PDU's slot format / AACH pattern / LLC type rather than
 * hardcoded literals.
 *
 * Hard rule: every value here MUST match its `localparam` counterpart in the
 * RTL header byte-for-byte.  When you add a new PDU class touch BOTH files.
 *
 * License: GPL v2
 */
#ifndef TETRA_PDU_CLASS_H
#define TETRA_PDU_CLASS_H

#include <stdint.h>

/* Slot formats (queue.pdu_type / scheduler / slot_content_mux convention). */
#define PDUC_SLOTFMT_SCH_F   ((uint8_t)0u)  /* NDB1 SCH/F  432 coded bits */
#define PDUC_SLOTFMT_SCH_HD  ((uint8_t)1u)  /* NDB2 SCH/HD 216 coded bits */

/* Raw 14-bit AACH content as latched into the queue/scheduler. */
#define PDUC_AACH_SIGNALLING_ACTIVE  ((uint16_t)0x0009u)
#define PDUC_AACH_IDLE               ((uint16_t)0x0249u)

/* Address-type ETSI EN 300 392-2 Table 21.66 */
#define PDUC_ADDRTYPE_SSI   ((uint8_t)1u)

/* LLC PDU-type encodings (ETSI EN 300 392-2 §23.4). */
#define PDUC_LLC_BL_ADATA   ((uint8_t)0u)
#define PDUC_LLC_BL_UDATA   ((uint8_t)1u)
#define PDUC_LLC_BL_ACK     ((uint8_t)2u)
#define PDUC_LLC_AL_SETUP   ((uint8_t)8u)

/* PDUC_PRE_REPLY_SLOTGRANT — single Pre-Reply path for both mm=2 (ITSI-Attach)
 * and mm=7 (Group-Switch).  Phase Z.9 collapses the LU/GRP split to one
 * SCH/HD-encoded 124-bit AL-SETUP body with sg_element=0x00 (Gold-Ref
 * bit-pattern, applies to both timelines).
 */
#define PDUC_PRE_REPLY_SLOTGRANT_FMT       PDUC_SLOTFMT_SCH_HD
#define PDUC_PRE_REPLY_SLOTGRANT_AACH      PDUC_AACH_SIGNALLING_ACTIVE
#define PDUC_PRE_REPLY_SLOTGRANT_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_PRE_REPLY_SLOTGRANT_LLC       PDUC_LLC_AL_SETUP
#define PDUC_PRE_REPLY_SLOTGRANT_RA        1u

/* PDUC_FINAL_LU_ACCEPT — mm=2 D-LOC-UPDATE-ACCEPT LI=21 SCH/F */
#define PDUC_FINAL_LU_ACCEPT_FMT       PDUC_SLOTFMT_SCH_F
#define PDUC_FINAL_LU_ACCEPT_AACH      PDUC_AACH_SIGNALLING_ACTIVE
#define PDUC_FINAL_LU_ACCEPT_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_FINAL_LU_ACCEPT_LLC       PDUC_LLC_BL_ADATA
#define PDUC_FINAL_LU_ACCEPT_RA        0u

/* PDUC_FINAL_LU_REJECT — mm=4 D-LOC-UPDATE-REJECT LI=7 SCH/HD */
#define PDUC_FINAL_LU_REJECT_FMT       PDUC_SLOTFMT_SCH_HD
#define PDUC_FINAL_LU_REJECT_AACH      PDUC_AACH_SIGNALLING_ACTIVE
#define PDUC_FINAL_LU_REJECT_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_FINAL_LU_REJECT_LLC       PDUC_LLC_BL_ADATA
#define PDUC_FINAL_LU_REJECT_RA        0u

/* PDUC_GROUP_ACK — mm=11 D-ATTACH-DETACH-GRP-ID-ACK LI=16 SCH/F */
#define PDUC_GROUP_ACK_FMT       PDUC_SLOTFMT_SCH_F
#define PDUC_GROUP_ACK_AACH      PDUC_AACH_SIGNALLING_ACTIVE
#define PDUC_GROUP_ACK_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_GROUP_ACK_LLC       PDUC_LLC_BL_ADATA
#define PDUC_GROUP_ACK_RA        0u

/* PDUC_BL_ACK_POST_FRAG2 — Post-Frag-2 BL-ACK LI=6 SCH/HD blk1
 *
 * Gold: AACH stays at 0x0249 idle on this slot
 * (reference_gold_full_attach_timeline.md Z. 138-143).
 */
#define PDUC_BL_ACK_POST_FRAG2_FMT       PDUC_SLOTFMT_SCH_HD
#define PDUC_BL_ACK_POST_FRAG2_AACH      PDUC_AACH_IDLE
#define PDUC_BL_ACK_POST_FRAG2_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_BL_ACK_POST_FRAG2_LLC       PDUC_LLC_BL_ACK
#define PDUC_BL_ACK_POST_FRAG2_RA        0u

/* PDUC_NWRK_BCAST — D-NWRK-BROADCAST LI=16 BL-UDATA, AACH 0x0249 idle */
#define PDUC_NWRK_BCAST_FMT       PDUC_SLOTFMT_SCH_F
#define PDUC_NWRK_BCAST_AACH      PDUC_AACH_IDLE
#define PDUC_NWRK_BCAST_ADDRTYPE  PDUC_ADDRTYPE_SSI
#define PDUC_NWRK_BCAST_LLC       PDUC_LLC_BL_UDATA
#define PDUC_NWRK_BCAST_RA        0u

#endif /* TETRA_PDU_CLASS_H */
