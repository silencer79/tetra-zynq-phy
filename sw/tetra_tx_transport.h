/*
 * tetra_tx_transport.h — TETRA TX Transport Layer (Phase Z.1)
 *
 * Single-submit API for all DL signalling PDUs. Hides AXI mailbox layout
 * details and (in Phase Z.2) slot-class / AACH-pattern selection.
 *
 * Today (Z.1): each tx_pdu_class_t maps to one of the existing mailbox
 * windows (Reply 0x220 for mm=1/4, Group-Reply 0x250 for mm=11). No
 * on-air behaviour change vs. the previous inline staging.
 *
 * Z.2 will add `slot_class` and `aach_pattern` to the meta struct (already
 * present below as future-fields, default 0 = legacy behaviour) and route
 * them to a unified DL-Signal-Queue submit-mailbox.
 *
 * License: GPL v2
 */
#ifndef TETRA_TX_TRANSPORT_H
#define TETRA_TX_TRANSPORT_H

#include <stdint.h>
#include "tetra_hal.h"
#include "tetra_cmce_body.h"

typedef enum {
 TX_LU_ACCEPT = 0, /* mm=1, LI=21, SCH/F → mcch */
 TX_LU_REJECT = 1, /* mm=4, LI=7, SCH/HD blk1 → mcch (Z.5) */
 TX_GRP_ATTACH_ACK = 2, /* mm=11, LI=16, SCH/F → mcch */
 /* Phase 7 G.4 — CMCE DL replies (alle via raw_mode_flag=1 staging,
 * Body in SW per tetra_cmce_build_*). Architektur-Lock per
 * project_arch_fpga_thin_signaling.md: keine neuen RTL-Encoder. */
 TX_D_SETUP = 3, /* CMCE pdu=1, group-call BS→MS setup */
 TX_D_CALL_PROCEEDING = 4, /* CMCE pdu=3, setup-in-progress ack */
 TX_D_CONNECT = 5, /* CMCE pdu=2, group-call accepted */
 TX_D_TX_GRANTED = 6, /* CMCE pdu=21, talker-grant */
 TX_D_RELEASE = 7, /* CMCE pdu=10, end-of-call */
 TX_D_TX_CEASED = 8, /* CMCE pdu=9, ack MS U-TX-CEASED */
 /* Einzelruf-Handshake (2026-05-25) */
 TX_D_CONNECT_ACK = 9, /* CMCE pdu=3, through-connect Befehl an Callee */
 TX_D_ALERT = 10, /* CMCE pdu=0, "calling..." Status an Caller */
 /* Operator-getriggerte Kurznachricht (2026-06-01) */
 TX_D_SDS_DATA = 11, /* CMCE pdu=15, BS→MS SDS (raw_mode CMCE) */
 /* SDS-Zustellquittung (2026-06-02) */
 TX_BL_ACK = 12, /* reine LLC BL-ACK an SDS-Absender, nr=empfangene NS */
 /* Status-SDS (2026-06-03) */
 TX_D_STATUS = 13, /* CMCE pdu=8, BS→MS precoded status (raw_mode CMCE) */
} tx_pdu_class_t;

/* Slot-class hint (Z.2+). 0 = legacy (RTL chooses default per existing
 * behaviour: Reply→NDB1 path inside MLE-FSM, Group-Reply→whatever the
 * scheduler latches). Active selection lands in Z.2. */
typedef enum {
 TX_SLOT_DEFAULT = 0,
 TX_SLOT_NDB1_SCHF = 1,
 TX_SLOT_NDB2_BLK1 = 2,
 TX_SLOT_NDB2_BLK2 = 3,
 TX_SLOT_SCHHU = 4,
 TX_SLOT_SB = 5,
} tx_slot_class_t;

/* AACH override pattern (Z.2+). 0 = legacy (no override, RTL chooses
 * idle 0x0249 / signalling 0x0009 / etc per existing rules). */
typedef struct {
 /* ---- Common ---- */
 uint32_t target_ssi; /* 24-bit MS-ISSI */

 /* ---- mm=1 / mm=4 (LU ACCEPT / REJECT) ---- */
 uint16_t la; /* 14-bit cell LA */
 uint8_t result; /* 0=accept, 1=reject-temp, 2=reject-perm */
 uint8_t loc_acc_type; /* 3-bit (Bug-001 fix). Echoes MS's
                                          * location_update_type from
                                          * U-LOC-UPD-DEMAND (ETSI §16.10.35a).
                                          * 3 = ItsiAttach, 0 = Roaming, etc. */
 uint32_t gila_gssi; /* 24-bit */
 uint8_t gila_class; /* 3-bit */
 uint8_t gila_lifetime; /* 2-bit */
 uint8_t gila_present; /* 1-bit */
 uint8_t encryption; /* 2-bit, reserved */
 uint8_t auth_result; /* 2-bit, reserved */

 /* ---- mm=11 (Group-Attach-ACK) ---- */
 uint8_t reply_count; /* 0..3 */
 uint32_t gssi[3]; /* 24-bit each */
 uint8_t at[3]; /* 2-bit each: address-type per record */
 uint8_t lifetime[3]; /* 2-bit each */
 uint8_t adi[3]; /* 1-bit each: attach=0/detach=1 */
 uint8_t cls[3]; /* 3-bit each: class_of_usage */
 uint8_t ns, nr; /* LLC stop-and-wait */
 uint8_t accept_reject; /* 0=accept, 1=reject (W1 of GRP reply) */

 /* ---- CMCE (Phase 7 G.4 — D-SETUP / D-CONNECT / D-CALL-PROCEEDING /
 * D-TX-GRANTED / D-RELEASE). Builder picks fields per PDU class.
 * ns/nr above carry the LLC stop-and-wait sequence. */
 cmce_meta_t cmce;

 /* ---- Z.2 future-fields ---- */
 tx_slot_class_t slot_class; /* 0 = legacy */
 uint16_t aach_pattern; /* 0 = no override */

 /* Klasse 2 (2026-05-24) — Traffic Usage Marker per Call (ETSI EN 300
  * 392-2 §21.4.7.2). Range 4..63, 0 = nicht allokiert (legacy: dann
  * landet 0 in W2[8:3] und RTL fällt auf hardcoded 11 zurück, falls
  * RTL noch alt). Bei umt!=0 schreibt stage_raw_mm W2[8:3]=umt → RTL
  * mac_resource_dl_builder packt die Bits in den SsiAndUsageMarker-
  * Adress-Slot des MAC-RESOURCE PDUs. Muss zur AACH-Anzeige des
  * Voice-Slot (REG_SLOT_AACH_N=AACH_VOICE_UMT(umt)) passen, sonst
  * verwirft MS den Call. */
 uint8_t umt;

 /* 2026-05-25 Multi-Group — ts_assigned-Bitmap für ChanAlloc-Element
  * in CMCE D-CONNECT/D-SETUP. MSB-first [TS1,TS2,TS3,TS4]:
  *   0b1000 = TS1 (nicht für Voice — mcch)
  *   0b0100 = TS2 (Default Voice Slot)
  *   0b0010 = TS3
  *   0b0001 = TS4
  *   0b0000 = legacy / unset → RTL Fallback TS2
  * SW Helper: chan_alloc_ts_bitmap = 1u << (4 - voice_ts). */
 uint8_t chan_alloc_ts_bitmap;
} tx_pdu_meta_t;

/* Stage the PDU in the appropriate AXI reply mailbox and pulse GO.
 * Returns 0 on success, -1 if `cls` is unknown. Does NOT ACK the demand
 * snapshot — caller is responsible for REG_*_DEMAND_ACK after the call.
 *
 * Hard requirement (Z.1): the on-air output for a given (cls, meta) must be
 * byte-for-byte identical to the previous inline staging logic in
 * tetra_attach_daemon.c. Z.2 changes the slot-class/AACH path, not the
 * PDU bytes. */
int tetra_tx_submit(tetra_hal_t *hal, tx_pdu_class_t cls,
 const tx_pdu_meta_t *meta);

/* Empfänger-Slot-Grant (NDB2/SCH/HD AL-SETUP) an `ssi` — nach langer-SDS-
 * Zustellung, damit der Empfänger seinen SDS-TL-Delivery-Report senden kann.
 * Triggert die RTL pre_reply_slotgrant-FSM via Reply-Mailbox W9[14]. */
int tetra_tx_rx_slotgrant(tetra_hal_t *hal, uint32_t ssi);

#endif /* TETRA_TX_TRANSPORT_H */
