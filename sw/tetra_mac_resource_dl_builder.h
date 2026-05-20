/*
 * tetra_mac_resource_dl_builder.h — SW-Port von tetra_mac_resource_dl_builder.v
 *
 * Wraps a raw MM PDU into a full ETSI EN 300 392-2 MAC-RESOURCE downlink PDU
 * destined for SCH/F signalling. Reproduziert das RTL bit-genau für den
 * Subset den wir tatsächlich verwenden:
 *   - AddrType ∈ {1=SSI, 6=SsiAndUsageMarker}
 *   - LLC ∈ {0=BL-ADATA, 1=BL-DATA, 2=BL-UDATA, 8=AL-SETUP, 14=L2SigPdu}
 *   - Optional PowerCtrl(4bit), SlotGrant(8bit), ChanAlloc(<=32bit) elements
 *   - Single-PDU (kein second_pdu / BL-ACK Piggyback — wird bei Bedarf
 *     nachgereicht)
 *
 * Output: 268-bit MSB-first bit array, ready für SCH/F-encoder. Bit 0 ist
 * erstes On-Air-Bit (MSB-first, identisch zur RTL Convention).
 *
 * License: GPL v2
 */
#ifndef TETRA_MAC_RESOURCE_DL_BUILDER_H
#define TETRA_MAC_RESOURCE_DL_BUILDER_H

#include <stdint.h>

/* LLC PDU type constants (ETSI §21.2.2) */
#define MAC_LLC_BL_ADATA  0u   /* link-type=0, fcs=0, pdu_type=00 — 6-bit hdr */
#define MAC_LLC_BL_DATA   1u   /* link-type=0, fcs=0, pdu_type=01 — 5-bit hdr */
#define MAC_LLC_BL_UDATA  2u   /* link-type=0, fcs=0, pdu_type=10 — 4-bit hdr */
#define MAC_LLC_AL_SETUP  8u   /* AL-SETUP — 4-bit hdr, no TL-SDU             */
#define MAC_LLC_L2SIG    14u   /* L2SigPdu — 4-bit hdr, raw MM, no MLE-PD     */

/* MLE protocol discriminator (§18.5.2) */
#define MAC_MLE_PD_MM    1u    /* 0b001 = MM (mm=2, mm=11, …)                 */
#define MAC_MLE_PD_CMCE  2u    /* 0b010 = CMCE (D-CONNECT/D-TX-GRANTED/…)     */

/* AddrType constants (§21.4.3.1 Table 21.55) */
#define MAC_ADDR_TYPE_SSI         1u  /* 24-bit SSI                           */
#define MAC_ADDR_TYPE_SSI_USAGE   6u  /* 24-bit SSI + 6-bit UsageMarker       */

typedef struct {
    uint32_t ssi;                /* 24-bit                                  */
    uint8_t  addr_type;          /* 1=SSI, 6=SSI+UsageMarker                */
    uint8_t  usage_marker;       /* 6-bit, nur bei addr_type=6              */
    uint8_t  llc_pdu_type;       /* MAC_LLC_*                               */
    uint8_t  random_access_flag; /* 1=RA-ACK piggyback                      */
    uint8_t  mle_pd;             /* MAC_MLE_PD_* (1 oder 2)                 */
    uint8_t  ns;                 /* LLC stop-and-wait (mm=11/grpack)        */
    uint8_t  nr;                 /* LLC stop-and-wait                       */

    /* Optional header elements (alle defaults 0) */
    uint8_t  pc_flag;            /* 1 → 4-bit power_control_element          */
    uint8_t  pc_element;
    uint8_t  sg_flag;            /* 1 → 8-bit slot_granting_element          */
    uint8_t  sg_element;
    uint8_t  ca_flag;            /* 1 → ca_element_len bits ChanAlloc        */
    uint32_t ca_element;         /* right-aligned, MSB-first emitted         */
    uint8_t  ca_element_len;     /* 0..32                                    */
} tetra_mac_res_meta_t;

#define TETRA_MAC_RES_PDU_BITS 268

/* Build a 268-bit MAC-RESOURCE PDU from metadata + raw MM body.
 * - meta:       header metadata (alle Flags + Address)
 * - mm_bits:    MM-Body MSB-first, jedes Byte ist 8 Bits (bit-array, 0/1)
 * - mm_len:     Anzahl gültiger MM-Bits (0..128 typ)
 * - out_268:    Output, 268-Bit-Array, [0]=erstes On-Air-Bit
 *
 * Returns 0 on success, -1 on overflow (mm_len zu groß für PDU_BITS=268).
 *
 * Wenn meta->llc_pdu_type == MAC_LLC_AL_SETUP: mm_bits/mm_len ignoriert
 * (AL-SETUP hat kein TL-SDU, nur 4-bit LLC-Header). */
int tetra_build_mac_resource_pdu(const tetra_mac_res_meta_t *meta,
                                  const uint8_t *mm_bits,
                                  int mm_len,
                                  uint8_t out_268[TETRA_MAC_RES_PDU_BITS]);

#endif /* TETRA_MAC_RESOURCE_DL_BUILDER_H */
