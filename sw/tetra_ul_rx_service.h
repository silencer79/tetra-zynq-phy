/*
 * tetra_ul_rx_service.h — UL-RX-Verbraucher-Kette (Option B, Integration)
 *
 * Bindet alle Bausteine zur kompletten SW-Seite: EIN Mailbox-Burst
 *   (Slot-Kennung + burst_type + Soft) →
 *   Soft-Decode (schhu/schf) → MAC-Header-Klassifikation →
 *   Reassembly (Demand-2-Burst / Long-SDS-Multi-Frag; der reservierte Slot
 *   ordnet Continuation-Bursts der SSI zu) →
 *   fertiger TM-SDU-Body + Meta für die vorhandenen Parser (mm_demand_parser /
 *   tetra_cmce_parse).
 *
 * Ersetzt logisch die RTL-Kette ul_sch_hu/f_decoder + ul_mac_access_parser +
 * ul_demand/schf_reassembly. RTL liefert nur noch Soft-Burst + Slot.
 *
 * License: GPL v2
 */
#ifndef TETRA_UL_RX_SERVICE_H
#define TETRA_UL_RX_SERVICE_H

#include <stdint.h>
#include "tetra_ul_reassembly.h"

typedef struct {
    ul_reass_t demand;        /* 2-Burst-SCH/HU-Demand */
    ul_lsds_t  lsds;          /* Multi-Fragment-SCH/F Long-SDS */
    uint8_t    cc, scr_slot;  /* Descramble-Parameter (Zelle) */
    uint16_t   mcc, mnc;
    uint32_t   slot_ssi[4];   /* pro on-air-TS: SSI, die den reservierten Slot besitzt */
} ul_rx_ctx_t;

/* Quelle eines fertigen Bodys. */
enum { UL_RX_SRC_SINGLE = 0, UL_RX_SRC_DEMAND = 1, UL_RX_SRC_LONGSDS = 2 };

typedef struct {
    int      crc_ok;            /* Decode-CRC des Bursts */
    int      have_body;         /* 1 = kompletter TM-SDU-Body bereit */
    int      source;            /* UL_RX_SRC_* */
    uint8_t  body[UL_LSDS_MAX_BITS]; /* byte-per-bit, MSB-first */
    int      body_len;          /* Bits */
    uint32_t ssi;
    uint16_t meta;              /* 13-bit Meta (single/demand); 0 für long-SDS */
    int      need_grant;        /* 1 = frag=1-Demand-Start: BS muss der SSI einen
                                 * UL-Subslot granten, damit sie den MAC-END-HU
                                 * (Continuation) sendet. Ersetzt den alten
                                 * RTL-frag1_pulse→pre_reply_slotgrant-Pfad. */
} ul_rx_result_t;

void tetra_ul_rx_init(ul_rx_ctx_t *c, uint8_t cc, uint8_t scr_slot,
                      uint16_t mcc, uint16_t mnc);

/* Verarbeitet einen Mailbox-Burst (words = Wire-Format aus tetra_ul_rx_mailbox).
 * Füllt *out. Rückgabe 1 = out gültig (Body oder informativ), 0 = ungültiger Burst. */
int tetra_ul_rx_service(ul_rx_ctx_t *c, const uint32_t *words,
                        uint32_t now_ms, ul_rx_result_t *out);

/* Wall-Clock-Tick für die Reassembly-T0-Timeouts. */
void tetra_ul_rx_tick(ul_rx_ctx_t *c, uint32_t now_ms);

#endif /* TETRA_UL_RX_SERVICE_H */
