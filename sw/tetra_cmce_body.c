/*
 * tetra_cmce_body.c — Phase 7 G.3 DL CMCE PDU body builders
 *
 * Five builders, one bit-packer.  All produce MSB-first byte streams
 * starting with the 5-bit pdu_type, exactly as expected by the RTL
 * `tetra_dl_pdu_builder` raw-mode mailbox path.
 *
 * No Type-2/Type-3 IEs are emitted in this phase — the o-bit is always
 * written as 0, followed (where the bluestation source emits one) by
 * the terminating m-bit.  For PDUs where bluestation's `to_bitbuf`
 * returns early when `obit == false` (i.e. NO trailing m-bit), we
 * match that behaviour bit-for-bit.
 *
 * Source-of-truth: bluestation
 *   crates/tetra-pdus/src/cmce/pdus/d_setup.rs
 *   crates/tetra-pdus/src/cmce/pdus/d_call_proceeding.rs
 *   crates/tetra-pdus/src/cmce/pdus/d_connect.rs
 *   crates/tetra-pdus/src/cmce/pdus/d_tx_granted.rs
 *   crates/tetra-pdus/src/cmce/pdus/d_release.rs
 *
 * License: GPL v2
 */

#include "tetra_cmce_body.h"

#include <string.h>

/* PDU type codes (5 bit, ETSI §14.8.28). */
#define D_CALL_PROCEEDING  1u
#define D_CONNECT          2u
#define D_RELEASE          6u
#define D_SETUP            7u
#define D_TX_GRANTED      11u

static void put_bits(uint8_t *dst, int *pos, uint32_t value, int nbits)
{
    int i;
    for (i = nbits - 1; i >= 0; i--) {
        unsigned bit = (unsigned)((value >> i) & 0x1u);
        unsigned p   = (unsigned)(*pos);
        unsigned byte_idx = p >> 3;
        unsigned bit_idx  = 7u - (p & 0x7u);
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
    put_bits(out, pos, m->bsi_encryption_flag   & 0x01u, 1);
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

    put_bits(out, &pos, D_SETUP,                              5);
    put_bits(out, &pos, m->call_identifier & 0x3FFFu,        14);
    put_bits(out, &pos, m->call_time_out   & 0x0Fu,           4);
    put_bits(out, &pos, m->hook_method_selection & 0x01u,     1);
    put_bits(out, &pos, m->simplex_duplex_selection & 0x01u,  1);
    write_bsi(out, &pos, m);                                  /* 8 bits */
    put_bits(out, &pos, m->transmission_grant & 0x03u,        2);
    put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
    put_bits(out, &pos, m->call_priority & 0x0Fu,             4);

    /* o-bit = 0 — bluestation returns early without trailing m-bit. */
    put_bits(out, &pos, 0u, 1);
    return pos;     /* expected = 5+14+4+1+1+8+2+1+4+1 = 41 bits */
}

int tetra_cmce_build_d_call_proceeding(const cmce_meta_t *m, uint8_t *out)
{
    if (m == NULL || out == NULL) return 0;
    memset(out, 0, TETRA_CMCE_MAX_BYTES);
    int pos = 0;

    put_bits(out, &pos, D_CALL_PROCEEDING,                    5);
    put_bits(out, &pos, m->call_identifier & 0x3FFFu,        14);
    put_bits(out, &pos, m->call_time_out_setup_phase & 0x07u, 3);
    put_bits(out, &pos, m->hook_method_selection & 0x01u,     1);
    put_bits(out, &pos, m->simplex_duplex_selection & 0x01u,  1);

    /* o-bit = 0 — bluestation returns early without trailing m-bit. */
    put_bits(out, &pos, 0u, 1);
    return pos;     /* expected = 5+14+3+1+1+1 = 25 bits */
}

int tetra_cmce_build_d_connect(const cmce_meta_t *m, uint8_t *out)
{
    if (m == NULL || out == NULL) return 0;
    memset(out, 0, TETRA_CMCE_MAX_BYTES);
    int pos = 0;

    put_bits(out, &pos, D_CONNECT,                            5);
    put_bits(out, &pos, m->call_identifier & 0x3FFFu,        14);
    put_bits(out, &pos, m->call_time_out & 0x0Fu,             4);
    put_bits(out, &pos, m->hook_method_selection & 0x01u,     1);
    put_bits(out, &pos, m->simplex_duplex_selection & 0x01u,  1);
    put_bits(out, &pos, m->transmission_grant & 0x03u,        2);
    put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
    put_bits(out, &pos, m->call_ownership & 0x01u,            1);

    /* Phase 7 G.5+ — Gold D-CONNECT #5887 hat o-bit=1 mit Type-2 BSI present.
     * Ohne BSI weiß MS nicht dass Speech-Service (TchS) bestätigt ist und
     * startet keinen TCH/S-TX.  Type-2-Layout per bluestation `d_connect.rs`:
     *   call_priority (4 bit, present-flag + value)
     *   basic_service_information (8 bit struct, present-flag + write_bsi)
     *   temporary_address (24 bit, present-flag + value)
     *   notification_indicator (6 bit, present-flag + value)
     * Wir emittieren: call_priority=absent, BSI=present(TchS), temp_addr=absent,
     * notif=absent.  Type-3 (Facility/Proprietary) ebenfalls absent. */
    put_bits(out, &pos, 1u, 1);                              /* o-bit = 1 */

    put_bits(out, &pos, 0u, 1);                              /* call_priority absent */
    put_bits(out, &pos, 1u, 1);                              /* BSI present */
    write_bsi(out, &pos, m);                                 /* 8-bit BSI */
    put_bits(out, &pos, 0u, 1);                              /* temp_address absent */
    put_bits(out, &pos, 0u, 1);                              /* notif_indicator absent */
    put_bits(out, &pos, 0u, 1);                              /* Type-3 Facility absent */
    put_bits(out, &pos, 0u, 1);                              /* Type-3 Proprietary absent */
    put_bits(out, &pos, 0u, 1);                              /* trailing m-bit = 0 */
    return pos;
    /* expected = 5+14+4+1+1+2+1+1+1 (header) + 1+1+8+1+1+1+1+1 (IE chain) = 44 bits */
}

int tetra_cmce_build_d_tx_granted(const cmce_meta_t *m, uint8_t *out)
{
    if (m == NULL || out == NULL) return 0;
    memset(out, 0, TETRA_CMCE_MAX_BYTES);
    int pos = 0;

    put_bits(out, &pos, D_TX_GRANTED,                         5);
    put_bits(out, &pos, m->call_identifier & 0x3FFFu,        14);
    put_bits(out, &pos, m->transmission_grant & 0x03u,        2);
    put_bits(out, &pos, m->transmission_request_permission & 0x01u, 1);
    put_bits(out, &pos, m->encryption_control & 0x01u,        1);
    put_bits(out, &pos, m->tx_reserved & 0x01u,               1);

    /* o-bit = 0 — bluestation returns early without trailing m-bit. */
    put_bits(out, &pos, 0u, 1);
    return pos;     /* expected = 5+14+2+1+1+1+1 = 25 bits */
}

int tetra_cmce_build_d_release(const cmce_meta_t *m, uint8_t *out)
{
    if (m == NULL || out == NULL) return 0;
    memset(out, 0, TETRA_CMCE_MAX_BYTES);
    int pos = 0;

    put_bits(out, &pos, D_RELEASE,                            5);
    put_bits(out, &pos, m->call_identifier & 0x3FFFu,        14);
    put_bits(out, &pos, m->disconnect_cause & 0x1Fu,          5);

    /* o-bit = 0 — bluestation returns early without trailing m-bit. */
    put_bits(out, &pos, 0u, 1);
    return pos;     /* expected = 5+14+5+1 = 25 bits */
}
