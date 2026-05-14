/*
 * tetra_cmce_parser.c — Phase 7 G.1 UL CMCE PDU parser
 *
 * Decodes the type-1 (mandatory) header of CMCE U-PDUs. IE chains
 * after the o-bit are NOT walked here; we surface `o_bit` and leave
 * deeper IE inspection to callers that need it.
 *
 * Layouts mirror bluestation `cmce/pdus/u_*.rs` (5-bit pdu_type
 * field). See `tetra_cmce_parser.h` for the field cheat-sheet.
 *
 * License: GPL v2
 */

#include "tetra_cmce_parser.h"

#include <string.h>

/* MSB-first bit-reader. Reads `nbits` bits starting at bit offset
 * `*pos` (bit 0 = MSB of byte 0). Advances `*pos`. Caller is
 * responsible for bounds checks (we mask to 32 bit to be safe). */
static uint32_t get_bits(const uint8_t *src, int *pos, int nbits)
{
 uint32_t v = 0;
 int i;
 for (i = 0; i < nbits; i++) {
 unsigned p = (unsigned)(*pos + i);
 unsigned byte_idx = p >> 3;
 unsigned bit_idx = 7u - (p & 0x7u);
 unsigned bit = ((unsigned)src[byte_idx] >> bit_idx) & 0x1u;
 v = (v << 1) | bit;
 }
 *pos += nbits;
 return v;
}

/* Map raw bluestation 5-bit UL pdu_type to our enum (0 stays UAlert,
 * which we encode as 0x10 to avoid colliding with CMCE_NONE). */
static cmce_pdu_type_t map_pdu_type(uint32_t raw)
{
 switch (raw) {
 case 0: return CMCE_U_ALERT;
 case 2: return CMCE_U_CONNECT;
 case 4: return CMCE_U_DISCONNECT;
 case 5: return CMCE_U_INFO;
 case 6: return CMCE_U_RELEASE;
 case 7: return CMCE_U_SETUP;
 case 8: return CMCE_U_STATUS;
 case 9: return CMCE_U_TX_CEASED;
 case 10: return CMCE_U_TX_DEMAND;
 default: return CMCE_UNSUPPORTED;
 }
}

/* Read 8-bit BSI block. Returns bits consumed (8 or 10). */
static int parse_bsi(const uint8_t *src, int *pos, int n_bits, cmce_bsi_t *bsi)
{
 if (*pos + 6 > n_bits) return -1;
 bsi->circuit_mode_type = (uint8_t)get_bits(src, pos, 3);
 bsi->encryption_flag = (uint8_t)get_bits(src, pos, 1);
 bsi->communication_type = (uint8_t)get_bits(src, pos, 2);
 if (*pos + 2 > n_bits) return -1;
 if (bsi->circuit_mode_type == 0) { /* TchS */
 bsi->speech_service = (uint8_t)get_bits(src, pos, 2);
 } else {
 bsi->slots_per_frame = (uint8_t)get_bits(src, pos, 2);
 }
 return 0;
}

int tetra_cmce_parse(const uint8_t *body_bits_msb_first,
 int n_bits, cmce_pdu_t *out)
{
 if (out == NULL || body_bits_msb_first == NULL) return -1;
 memset(out, 0, sizeof(*out));
 if (n_bits < 5) return -1;

 int pos = 0;
 uint32_t pdu_raw = get_bits(body_bits_msb_first, &pos, 5);
 out->pdu_type = map_pdu_type(pdu_raw);
 if (out->pdu_type == CMCE_UNSUPPORTED) return -2;

 /* Per-type parsing. Type-2/3 IEs after o-bit are NOT consumed. */
 switch (out->pdu_type) {
 case CMCE_U_SETUP: {
 if (pos + 5 + 1 + 1 + 8 + 1 + 4 + 2 + 2 > n_bits) return -1;
 out->area_selection = (uint8_t)get_bits(body_bits_msb_first, &pos, 4);
 out->hook_method_selection = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 out->simplex_duplex_selection = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 if (parse_bsi(body_bits_msb_first, &pos, n_bits, &out->bsi) < 0) return -1;
 out->request_to_transmit_send_data = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 out->call_priority = (uint8_t)get_bits(body_bits_msb_first, &pos, 4);
 out->clir_control = (uint8_t)get_bits(body_bits_msb_first, &pos, 2);
 out->called_party_type_identifier = (uint8_t)get_bits(body_bits_msb_first, &pos, 2);
 switch (out->called_party_type_identifier) {
 case CMCE_CPTI_SNA:
 if (pos + 8 > n_bits) return -1;
 out->called_party_sna = (uint8_t)get_bits(body_bits_msb_first, &pos, 8);
 break;
 case CMCE_CPTI_SSI:
 if (pos + 24 > n_bits) return -1;
 out->called_party_ssi = get_bits(body_bits_msb_first, &pos, 24);
 break;
 case CMCE_CPTI_TSI:
 if (pos + 48 > n_bits) return -1;
 out->called_party_ssi = get_bits(body_bits_msb_first, &pos, 24);
 out->called_party_extension = get_bits(body_bits_msb_first, &pos, 24);
 break;
 default:
 break;
 }
 if (pos + 1 <= n_bits) {
 out->o_bit = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 }
 return 0;
 }

 case CMCE_U_TX_DEMAND: {
 if (pos + 14 + 2 + 1 + 1 > n_bits) return -1;
 out->call_identifier = (uint16_t)get_bits(body_bits_msb_first, &pos, 14);
 out->tx_demand_priority= (uint8_t)get_bits(body_bits_msb_first, &pos, 2);
 out->encryption_control= (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 out->reserved = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 if (pos + 1 <= n_bits) {
 out->o_bit = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 }
 return 0;
 }

 case CMCE_U_TX_CEASED: {
 if (pos + 14 > n_bits) return -1;
 out->call_identifier = (uint16_t)get_bits(body_bits_msb_first, &pos, 14);
 if (pos + 1 <= n_bits) {
 out->o_bit = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 }
 return 0;
 }

 case CMCE_U_RELEASE:
 case CMCE_U_DISCONNECT: {
 if (pos + 14 + 5 > n_bits) return -1;
 out->call_identifier = (uint16_t)get_bits(body_bits_msb_first, &pos, 14);
 out->disconnect_cause = (uint8_t)get_bits(body_bits_msb_first, &pos, 5);
 if (pos + 1 <= n_bits) {
 out->o_bit = (uint8_t)get_bits(body_bits_msb_first, &pos, 1);
 }
 return 0;
 }

 case CMCE_U_CONNECT:
 case CMCE_U_INFO:
 case CMCE_U_ALERT:
 case CMCE_U_STATUS:
 default:
 /* Surface only pdu_type + call_identifier-attempt for U-ALERT/U-CONNECT
 * (both begin with 14-bit call_id per ETSI §14.7.2.x). Lack of body
 * means an empty header — still treated as success. */
 if (pos + 14 <= n_bits) {
 out->call_identifier = (uint16_t)get_bits(body_bits_msb_first, &pos, 14);
 }
 return 0;
 }
}
