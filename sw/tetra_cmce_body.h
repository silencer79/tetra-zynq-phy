/*
 * tetra_cmce_body.h — Phase 7 G.3 DL CMCE PDU body builders
 *
 * Generates the MM body bits (MSB-first byte stream) for the five DL
 * CMCE PDUs the call-control FSM needs:
 * - D-SETUP (pdu_type = 7)
 * - D-CALL-PROCEEDING (pdu_type = 1)
 * - D-CONNECT (pdu_type = 2)
 * - D-TX-GRANTED (pdu_type = 11)
 * - D-RELEASE (pdu_type = 6)
 *
 * Output is the raw CMCE body that goes into `tetra_dl_pdu_builder` via
 * the reply mailbox with raw_mode_flag=1 (Phase Y.2 pattern). No MAC
 * header, no LLC, no FCS — those are added in RTL/transport.
 *
 * Layouts mirror bluestation `cmce/pdus/d_*.rs` exactly — pdu_type is
 * 5 bits, call_identifier is 14 bits, then per-PDU type-1 mandatories,
 * then o-bit (which we always emit as 0 here = no Type-2/Type-3 IEs).
 *
 * All builders return the total bit length written, or 0 on error.
 * Caller must provide `out` ≥ TETRA_CMCE_MAX_BYTES = 32 bytes.
 *
 * License: GPL v2
 */

#ifndef TETRA_CMCE_BODY_H
#define TETRA_CMCE_BODY_H

#include <stdint.h>

#define TETRA_CMCE_MAX_BYTES 32

/* TransmissionGrant (2 bit, ETSI §14.8.42). */
#define CMCE_TG_GRANTED 0u
#define CMCE_TG_NOT_GRANTED 1u
#define CMCE_TG_REQUEST_QUEUED 2u
#define CMCE_TG_GRANTED_TO_OTHER_USER 3u

/* DisconnectCause subset (5 bit, ETSI §14.8.13). Add as needed. */
#define CMCE_DCAUSE_NORMAL_USER_REQ 0u
#define CMCE_DCAUSE_PRE_EMPTIVE_USE 1u
#define CMCE_DCAUSE_NETWORK_UNAVAILABLE 9u
#define CMCE_DCAUSE_EXPIRY_OF_TIMER 11u
#define CMCE_DCAUSE_RESOURCES_UNAVAILABLE 12u

typedef struct {
 /* Common header */
 uint16_t call_identifier; /* 14 bit; full 14-bit value */
 uint32_t calling_party_ssi; /* 24 bit, for D-SETUP */

 /* D-SETUP / D-CONNECT / D-CALL-PROCEEDING shared timing+hooks */
 uint8_t call_time_out; /* 4 bit (D-SETUP/D-CONNECT) */
 uint8_t call_time_out_setup_phase; /* 3 bit (D-CALL-PROCEEDING) */
 uint8_t hook_method_selection; /* 1 bit */
 uint8_t simplex_duplex_selection; /* 1 bit */

 /* D-SETUP / D-CONNECT shared TX-grant fields */
 uint8_t transmission_grant; /* 2 bit */
 uint8_t transmission_request_permission; /* 1 bit */
 uint8_t call_priority; /* 4 bit (D-SETUP) */

 /* D-CONNECT extra */
 uint8_t call_ownership; /* 1 bit */

 /* D-TX-GRANTED */
 uint8_t encryption_control; /* 1 bit */
 uint8_t tx_reserved; /* 1 bit (must be 0 per ETSI note) */

 /* D-RELEASE */
 uint8_t disconnect_cause; /* 5 bit */

 /* BasicServiceInformation (D-SETUP). Caller fills if used. */
 uint8_t bsi_circuit_mode_type; /* 3 bit (0 = TchS) */
 uint8_t bsi_encryption_flag; /* 1 bit */
 uint8_t bsi_communication_type; /* 2 bit */
 uint8_t bsi_speech_service; /* 2 bit (if TchS) */
 uint8_t bsi_slots_per_frame; /* 2 bit (if NOT TchS) */
} cmce_meta_t;

/* All return total bit length, 0 on parameter error. out is zeroed
 * up to TETRA_CMCE_MAX_BYTES on entry. */
int tetra_cmce_build_d_setup (const cmce_meta_t *m, uint8_t *out);
int tetra_cmce_build_d_call_proceeding (const cmce_meta_t *m, uint8_t *out);
int tetra_cmce_build_d_connect (const cmce_meta_t *m, uint8_t *out);
int tetra_cmce_build_d_tx_granted (const cmce_meta_t *m, uint8_t *out);
int tetra_cmce_build_d_tx_ceased (const cmce_meta_t *m, uint8_t *out);
int tetra_cmce_build_d_release (const cmce_meta_t *m, uint8_t *out);

#endif /* TETRA_CMCE_BODY_H */
