/*
 * tetra_cmce_body.c — Phase 7 G.3 DL CMCE PDU body builders
 *
 * Five builders, one bit-packer. All produce MSB-first byte streams
 * starting with the 5-bit pdu_type, exactly as expected by the RTL
 * `tetra_dl_pdu_builder` raw-mode mailbox path.
 *
 * No Type-2/Type-3 IEs are emitted in this phase — the o-bit is always
 * written as 0, followed (where the bluestation source emits one) by
 * the terminating m-bit. For PDUs where bluestation's `to_bitbuf`
 * returns early when `obit == false` (i.e. NO trailing m-bit), we
 * match that behaviour bit-for-bit.
 *
 * Source-of-truth: bluestation
 * crates/tetra-pdus/src/cmce/pdus/d_setup.rs
 * crates/tetra-pdus/src/cmce/pdus/d_call_proceeding.rs
 * crates/tetra-pdus/src/cmce/pdus/d_connect.rs
 * crates/tetra-pdus/src/cmce/pdus/d_tx_granted.rs
 * crates/tetra-pdus/src/cmce/pdus/d_release.rs
 *
 * License: GPL v2
 */

#include "tetra_cmce_body.h"

#include <string.h>

/* PDU type codes (5 bit, ETSI §14.8.28). */
#define D_ALERT 0u
#define D_CALL_PROCEEDING 1u
#define D_CONNECT 2u
#define D_CONNECT_ACK 3u
#define D_RELEASE 6u
#define D_SETUP 7u
#define D_TX_CEASED 9u
#define D_TX_GRANTED 11u
#define D_SDS_DATA 15u

static void put_bits(uint8_t *dst, int *pos, uint32_t value, int nbits)
{
 int i;
 for (i = nbits - 1; i >= 0; i--) {
 unsigned bit = (unsigned)((value >> i) & 0x1u);
 unsigned p = (unsigned)(*pos);
 unsigned byte_idx = p >> 3;
 unsigned bit_idx = 7u - (p & 0x7u);
 if (bit) {
 dst[byte_idx] |= (uint8_t)(1u << bit_idx);
 } else {
 dst[byte_idx] &= (uint8_t)~(1u << bit_idx);
 }
 (*pos)++;
 }
}

static void write_bsi(uint8_t *out, int *pos, const cmce_meta_t *m)
{
 put_bits(out, pos, m->bsi_circuit_mode_type & 0x07u, 3);
 put_bits(out, pos, m->bsi_encryption_flag & 0x01u, 1);
 put_bits(out, pos, m->bsi_communication_type& 0x03u, 2);
 if ((m->bsi_circuit_mode_type & 0x07u) == 0u) {
 /* TchS → speech_service */
 put_bits(out, pos, m->bsi_speech_service & 0x03u, 2);
 } else {
 put_bits(out, pos, m->bsi_slots_per_frame & 0x03u, 2);
 }
}

int tetra_cmce_build_d_setup(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_SETUP, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->call_time_out & 0x0Fu, 4);
 put_bits(out, &pos, m->hook_method_selection & 0x01u, 1);
 put_bits(out, &pos, m->simplex_duplex_selection & 0x01u, 1);
 write_bsi(out, &pos, m); /* 8 bits */
 put_bits(out, &pos, m->transmission_grant & 0x03u, 2);
 put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
 put_bits(out, &pos, m->call_priority & 0x0Fu, 4);

 /* Einzelruf 2026-05-25 — calling_party_ssi als Type-2 IE damit MS-B
  * (Empfänger) den Caller-Namen ausm Codeplug auflösen kann. Sonst:
  * "Einzelruf unbekannt" → reject.
  * Layout per ETSI §14.7.1.12:
  *   o-bit=1 (Type-2 folgt)
  *   p_notification_indicator(1)=0
  *   p_temporary_address(1)=0
  *   p_calling_party_type_identifier(1)=1 (present) + 2 bit value=1 (SSI)
  *   calling_party_address_ssi (24 bit)
  *   m-bit(1)=0 (kein Type-3) */
 if (m->calling_party_ssi != 0u) {
 put_bits(out, &pos, 1u, 1); /* o-bit = 1, Type-2 follows */
 put_bits(out, &pos, 0u, 1); /* p_notification_indicator absent */
 put_bits(out, &pos, 0u, 1); /* p_temporary_address absent */
 put_bits(out, &pos, 1u, 1); /* p_calling_party_type_identifier present */
 put_bits(out, &pos, 1u, 2); /* CPTI = 1 (SSI only) */
 put_bits(out, &pos, m->calling_party_ssi & 0x00FFFFFFu, 24);
 put_bits(out, &pos, 0u, 1); /* m-bit = 0, kein Type-3 */
 } else {
 /* Group-Call ohne Caller-Info — wie vorher, früh terminieren. */
 put_bits(out, &pos, 0u, 1);
 }
 return pos;
}

int tetra_cmce_build_d_call_proceeding(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_CALL_PROCEEDING, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->call_time_out_setup_phase & 0x07u, 3);
 put_bits(out, &pos, m->hook_method_selection & 0x01u, 1);
 put_bits(out, &pos, m->simplex_duplex_selection & 0x01u, 1);

 /* o-bit = 0 — bluestation returns early without trailing m-bit. */
 put_bits(out, &pos, 0u, 1);
 return pos; /* expected = 5+14+3+1+1+1 = 25 bits */
}

int tetra_cmce_build_d_call_proceeding(const cmce_meta_t *m, uint8_t *out); /* fwd */

int tetra_cmce_build_d_connect(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 /* Phase 7 G.7+ — bit-exact D-CONNECT body.
 * Verifiziert via `reference-DL.wav` Burst #5887/5895/5903
 * (alle 3 bit-identisch), info_hex=
 * 0x007e282ff42c89dd0ec9080080031021fe2f4d642c12380100026194a0bfd1...
 * Body-Layout (39 bits):
 * pdu_type(5) + call_id(14) + call_time_out(4) +
 * hook(1) + simplex(1) + tx_grant(2) + trp(1) + call_own(1) +
 * o-bit(1) +
 * Type-2: p_call_priority_present(1) + value(4) +
 * p_bsi_present(1) + ← = 0 (KEIN BSI!)
 * p_tmp_addr_present(1) +
 * p_notif_present(1) +
 * m-bit(1).
 *
 * verifizierte Felder (Caller setzt diese Werte):
 * call_time_out = 0 (Infinite)
 * transmission_grant = 0 (Granted)
 * trp = 0 ("allowed to request")
 * call_ownership = 0 ( pattern — NICHT 1)
 * call_priority = 1 ( pattern, von p_call_priority IE) */
 put_bits(out, &pos, D_CONNECT, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->call_time_out & 0x0Fu, 4);
 put_bits(out, &pos, m->hook_method_selection & 0x01u, 1);
 put_bits(out, &pos, m->simplex_duplex_selection & 0x01u, 1);
 put_bits(out, &pos, m->transmission_grant & 0x03u, 2);
 put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
 put_bits(out, &pos, m->call_ownership & 0x01u, 1);

 /* o-bit = 1 — Type-2 IE follows */
 put_bits(out, &pos, 1u, 1);
 /* p_call_priority_present = 1 ( present) + 4-bit value */
 put_bits(out, &pos, 1u, 1);
 put_bits(out, &pos, m->call_priority & 0x0Fu, 4);
 /* p_basic_service_information_present = 0 ( has NO BSI in D-CONNECT) */
 put_bits(out, &pos, 0u, 1);
 /* p_temporary_address_present = 0 */
 put_bits(out, &pos, 0u, 1);
 /* p_notification_indicator_present = 0 */
 put_bits(out, &pos, 0u, 1);
 /* m-bit termination (no Type-3 IEs) */
 put_bits(out, &pos, 0u, 1);

 return pos; /* 39 bits */
}

int tetra_cmce_build_d_tx_granted(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_TX_GRANTED, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->transmission_grant & 0x03u, 2);
 put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
 put_bits(out, &pos, m->encryption_control & 0x01u, 1);
 put_bits(out, &pos, m->tx_reserved & 0x01u, 1);

 /* o-bit = 0 — bluestation returns early without trailing m-bit. */
 put_bits(out, &pos, 0u, 1);
 return pos; /* expected = 5+14+2+1+1+1+1 = 25 bits */
}

int tetra_cmce_build_d_tx_ceased(const cmce_meta_t *m, uint8_t *out)
{
 /* D-TX-CEASED (ETSI §14.7.1.16) per bluestation `d_tx_ceased.rs`:
 * Type-1 mandatories:
 * pdu_type(5) + call_identifier(14) + transmission_request_permission(1)
 * + o-bit(1) — early return if 0 (no Type-2/3).
 * Body = 21 bits exakt ohne IEs. */
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_TX_CEASED, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
 put_bits(out, &pos, 0u, 1); /* o-bit = 0 */
 return pos; /* expected = 21 bits */
}

int tetra_cmce_build_d_release(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_RELEASE, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->disconnect_cause & 0x1Fu, 5);

 /* o-bit = 0 — bluestation returns early without trailing m-bit. */
 put_bits(out, &pos, 0u, 1);
 return pos; /* expected = 5+14+5+1 = 25 bits */
}

/* D-CONNECT-ACK (ETSI §14.7.1.5, BlueStation d_connect_acknowledge.rs):
 * Antwort an die CALLED MS auf U-CONNECT. "Through-connect"-Befehl.
 * Type-1 mandatories:
 *   pdu_type(5) + call_identifier(14) + call_time_out(4) +
 *   transmission_grant(2) + transmission_request_permission(1) + o-bit(1)
 * = 27 bits ohne Type-2/3 IEs. */
int tetra_cmce_build_d_connect_ack(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_CONNECT_ACK, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->call_time_out & 0x0Fu, 4);
 put_bits(out, &pos, m->transmission_grant & 0x03u, 2);
 put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
 put_bits(out, &pos, 0u, 1); /* o-bit = 0, keine IEs */
 return pos; /* 27 bits */
}

/* D-ALERT (ETSI §14.7.1.1, BlueStation d_alert.rs):
 * "Call is proceeding and the connecting party has been alerted" —
 * Antwort an die CALLING MS auf U-SETUP für individual calls (NICHT
 * D-CALL-PROCEEDING; D-ALERT bedeutet Klingelphase beim Callee).
 * Type-1 mandatories:
 *   pdu_type(5) + call_identifier(14) + call_time_out_setup_phase(3) +
 *   reserved(1)=1 + simplex_duplex(1) + call_queued(1) + o-bit(1)
 * = 26 bits ohne Type-2/3 IEs. */
int tetra_cmce_build_d_alert(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;

 put_bits(out, &pos, D_ALERT, 5);
 put_bits(out, &pos, m->call_identifier & 0x3FFFu, 14);
 put_bits(out, &pos, m->call_time_out_setup_phase & 0x07u, 3);
 put_bits(out, &pos, 1u, 1); /* reserved = 1 per BlueStation note */
 put_bits(out, &pos, m->simplex_duplex_selection & 0x01u, 1);
 put_bits(out, &pos, 0u, 1); /* call_queued = 0 */
 put_bits(out, &pos, 0u, 1); /* o-bit = 0 */
 return pos; /* 26 bits */
}

/* D-SDS-DATA (ETSI §14.7.1.10, BlueStation d_sds_data.rs): forward a short
 * data message to the addressed MS. CPTI=SSI (calling_party_ssi = sender),
 * SDTI=3 (UDD-4); user data = caller-supplied PID + SDS-TL header + 8-bit
 * text. Length bounded so 45 header bits + udd*8 + o-bit fit the 32-byte
 * mm_bytes staging buffer (≤ 256 bit). */
int tetra_cmce_build_d_sds_data(const cmce_meta_t *m, uint8_t *out)
{
 if (m == NULL || out == NULL || m->sds_udd_len == 0u ||
 m->sds_udd_len > 24u) return 0;
 memset(out, 0, TETRA_CMCE_MAX_BYTES);
 int pos = 0;
 put_bits(out, &pos, D_SDS_DATA, 5);
 put_bits(out, &pos, 1u, 2); /* CPTI = 1 (SSI) */
 put_bits(out, &pos, m->calling_party_ssi & 0x00FFFFFFu, 24);
 put_bits(out, &pos, 3u, 2); /* SDTI = 3 (UDD-4 = length + data) */
 put_bits(out, &pos, (uint32_t)(m->sds_udd_len * 8u) & 0x7FFu, 11); /* LI bits */
 int i;
 for (i = 0; i < (int)m->sds_udd_len; i++)
 put_bits(out, &pos, m->sds_udd[i], 8);
 put_bits(out, &pos, 0u, 1); /* o-bit = 0 (no Type-2/3 IEs) */
 return pos;
}
