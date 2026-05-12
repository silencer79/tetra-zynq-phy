/*
 * tetra_tx_transport.c — TETRA TX Transport Layer
 *
 * Routes each tx_pdu_class_t to the appropriate AXI mailbox staging path.
 *
 * Phase Y.2 (Variante A multi-PDU dispatch):
 *   The dedicated GRP-Reply mailbox + RTL grpack-encoder were removed; the
 *   shared mm=2 Reply-Pull-Mailbox now also carries D-ATTACH-DETACH-GRP-ID-
 *   ACK bodies via a raw-mode flag (W9[31]=1 → MLE-FSM bypasses dloc encoder
 *   and routes the SW-built MM bits straight into the shared DL-PDU
 *   builder).  See `memory/project_arch_fpga_thin_signaling.md` for the
 *   architectural lock-decision.
 *
 * Bit-identity guarantee for mm=2 ACCEPT (raw_mode_flag=0): the on-air
 * output is byte-for-byte identical to pre-Y.2.  Phase Y.2 only ADDS a
 * code path; the legacy mailbox writes (W0..W8) and the RTL dloc encoder
 * are unchanged.
 *
 * License: GPL v2
 */

#include "tetra_tx_transport.h"
#include "tetra_grpack_body.h"
#include "tetra_cmce_body.h"

#include <stddef.h>
#include <string.h>

/* Indirect-write helper — match the (INDEX → DATA) sequence used in the
 * legacy daemon so the FPGA latches `data` at word `idx`. */
static void reply_write(tetra_hal_t *hal, uint32_t idx, uint32_t data)
{
    tetra_reg_write(hal, REG_REPLY_INDEX, idx);
    tetra_reg_write(hal, REG_REPLY_DATA,  data);
}

/* mm=1 / mm=4 — D-LOC-UPDATE-ACCEPT / -REJECT body.
 *
 * For REJECT (result != 0) the GILA fields are zeroed — the RTL REJECT
 * encoder (rtl/lmac/tetra_d_location_update_reject_encoder.v) builds an
 * 8-bit MM body (PDU-Type=7 + 3-bit cause + o-bit=0) without GILA, and
 * the MLE-FSM Z.5 dual-branch FSM picks the REJECT branch when W3 != 0.
 * Mirror the suppression here as a safety net.
 *
 * Phase Y.2 — explicitly clear W9 (raw_mode_flag) so the MLE-FSM uses
 * the legacy dloc-encoder path.  The reset state of W9 is 0, but a
 * previous mm=11 GROUP-ACK left it non-zero; clear it here so each LU
 * staging begins from a known mm=2 state. */
static int submit_lu(tetra_hal_t *hal, const tx_pdu_meta_t *m,
                     uint32_t result)
{
    uint32_t gila_gssi     = (result == 0u) ? (m->gila_gssi & 0x00FFFFFFu) : 0u;
    uint32_t gila_class    = (result == 0u) ? (m->gila_class & 0x7u)       : 0u;
    uint32_t gila_lifetime = (result == 0u) ? (m->gila_lifetime & 0x3u)    : 0u;
    uint32_t gila_present  = (result == 0u) ? (m->gila_present & 0x1u)     : 0u;

    reply_write(hal, 0, m->target_ssi & 0x00FFFFFFu);
    reply_write(hal, 1, m->la & 0x3FFFu);
    reply_write(hal, 2, 0x1u);                   /* addr_type = Ssi+EventLabel */
    reply_write(hal, 3, result & 0x3u);          /* W3 selects ACCEPT(=0) vs
                                                  * REJECT(!=0) branch in the
                                                  * MLE-FSM (Z.5 dual-branch). */
    reply_write(hal, 4, gila_gssi);
    reply_write(hal, 5, (gila_class << 2) | gila_lifetime);
    reply_write(hal, 6, gila_present);
    reply_write(hal, 7, m->encryption & 0x3u);
    reply_write(hal, 8, (m->auth_result == 0u) ? 0x1u : (m->auth_result & 0x3u));
    /* Phase Y.2 — clear raw-mode flag (W9) and the four raw-bit words
     * (W10..W13).  Bit-identity for mm=2: the FSM mux selects dloc-encoder
     * output when raw_mode_flag=0, so on-air bytes are unchanged. */
    reply_write(hal, 9,  0x00000000u);
    reply_write(hal, 10, 0x00000000u);
    reply_write(hal, 11, 0x00000000u);
    reply_write(hal, 12, 0x00000000u);
    reply_write(hal, 13, 0x00000000u);

    tetra_reg_write(hal, REG_REPLY_GO, 0x1u);
    return 0;
}

/* mm=11 — D-ATTACH-DETACH-GROUP-IDENTITY-ACK body (Phase Y.2 Variante A).
 *
 * The MM body is built fully in C via tetra_grpack_build() and then staged
 * into the shared mm=2 Reply-Pull-Mailbox using the raw-mode flag (W9[31]).
 * The MLE-FSM samples the raw bits on the GO pulse and routes them past
 * the dloc encoder into the shared DL-PDU builder; the same SCH/F coding
 * pipeline emits the on-air burst.
 *
 * Word layout written here (matches rtl/lmac/tetra_reply_mailbox.v):
 *   W0  ssi (24-bit MS-ISSI; needed for MAC-RESOURCE addr field)
 *   W1  la=0 (don't care for mm=11)
 *   W2  addr_type = SSI = 1 (matches Gold-Ref Burst #4811 mm=11 envelope)
 *   W3..W8 zeroed (legacy mm=2 GILA/encryption/auth — irrelevant in raw)
 *   W9  raw_mode_flag=1 | nr | ns | raw_mm_len[7:0]
 *   W10..W13 raw_mm_bits[127:0] (LSB-first across words; W10=bits[31:0])
 */
/* Stage a SW-built MM body (mm=11 GRP-ACK or any mm=cmce* PDU) into the
 * shared mm=2 Reply-Pull-Mailbox via raw_mode_flag=1.  Caller supplies
 * MSB-first byte stream; we pack it into the W10..W13 raw-bits window
 * with bit 0 of the body landing at raw_mm_bits[127] (= FSM's MSB).
 *
 * W0   target SSI (24-bit, MAC-RESOURCE addr field)
 * W1   la=0
 * W2   addr_type=1 (SSI)
 * W3..W8  zeroed (legacy mm=2 GILA fields irrelevant in raw)
 * W9   raw_mode_flag(31) | raw_nr(9) | raw_ns(8) | raw_mm_len[7:0]
 * W10..W13  raw_mm_bits[127:0]                                          */
static int stage_raw_mm(tetra_hal_t *hal,
                        uint32_t      target_ssi,
                        const uint8_t *mm_bytes,
                        int           mm_len,
                        uint8_t       ns,
                        uint8_t       nr)
{
    if (mm_len <= 0 || mm_len > 128) return -1;

    uint32_t w_raw[4] = { 0u, 0u, 0u, 0u };
    for (int i = 0; i < mm_len; i++) {
        unsigned src_byte = (unsigned)(i >> 3);
        unsigned src_bit  = 7u - ((unsigned)i & 0x7u);
        unsigned bit      = (mm_bytes[src_byte] >> src_bit) & 0x1u;
        if (bit) {
            unsigned dst_pos  = 127u - (unsigned)i;
            unsigned word_idx = dst_pos >> 5;
            unsigned word_bit = dst_pos & 0x1Fu;
            w_raw[word_idx] |= (1u << word_bit);
        }
    }

    reply_write(hal, 0, target_ssi & 0x00FFFFFFu);
    reply_write(hal, 1, 0u);
    reply_write(hal, 2, 0x1u);
    reply_write(hal, 3, 0u);
    reply_write(hal, 4, 0u);
    reply_write(hal, 5, 0u);
    reply_write(hal, 6, 0u);
    reply_write(hal, 7, 0u);
    reply_write(hal, 8, 0u);

    uint32_t w9 = (1u << 31)
                | ((uint32_t)(nr & 0x1u) << 9)
                | ((uint32_t)(ns & 0x1u) << 8)
                | ((uint32_t) mm_len & 0xFFu);
    reply_write(hal,  9, w9);
    reply_write(hal, 10, w_raw[0]);
    reply_write(hal, 11, w_raw[1]);
    reply_write(hal, 12, w_raw[2]);
    reply_write(hal, 13, w_raw[3]);

    tetra_reg_write(hal, REG_REPLY_GO, 0x1u);
    return 0;
}

static int submit_grp_ack(tetra_hal_t *hal, const tx_pdu_meta_t *m)
{
    uint8_t cnt = (m->reply_count > TETRA_GRPACK_MAX_RECORDS)
                  ? TETRA_GRPACK_MAX_RECORDS : m->reply_count;

    grpack_meta_t gm;
    memset(&gm, 0, sizeof(gm));
    gm.accept_reject = m->accept_reject & 0x1u;
    gm.num_records   = cnt;
    for (unsigned i = 0; i < cnt; i++) {
        gm.records[i].atd            = m->adi[i] & 0x1u;
        gm.records[i].lifetime       = m->lifetime[i] & 0x3u;
        gm.records[i].class_of_usage = m->cls[i] & 0x7u;
        gm.records[i].addr_type      = m->at[i] & 0x3u;
        gm.records[i].gssi           = m->gssi[i] & 0x00FFFFFFu;
    }

    uint8_t mm_bytes[TETRA_GRPACK_MAX_BYTES];
    int mm_len = tetra_grpack_build(&gm, mm_bytes);
    if (mm_len <= 0) return -1;

    return stage_raw_mm(hal, m->target_ssi, mm_bytes, mm_len, m->ns, m->nr);
}

/* CMCE submit-Helpers — Phase 7 G.4.  Jeder Helper baut den Body via den
 * passenden tetra_cmce_build_*() Builder und staged ihn via stage_raw_mm.
 * Body-Längen sind variabel (D-RELEASE ≈ 22 bit, D-SETUP/D-CONNECT bis ~50
 * bit ohne IE-Chain; mit Type-3-IEs später bis ~120 bit).                */
static int submit_cmce_pdu(tetra_hal_t      *hal,
                           const tx_pdu_meta_t *m,
                           int (*builder)(const cmce_meta_t *, uint8_t *))
{
    uint8_t mm_bytes[32];
    int mm_len = builder(&m->cmce, mm_bytes);
    if (mm_len <= 0) return -1;
    return stage_raw_mm(hal, m->target_ssi, mm_bytes, mm_len, m->ns, m->nr);
}

int tetra_tx_submit(tetra_hal_t *hal, tx_pdu_class_t cls,
                    const tx_pdu_meta_t *meta)
{
    if (hal == NULL || meta == NULL) return -1;

    switch (cls) {
    case TX_LU_ACCEPT:
        return submit_lu(hal, meta, 0u);
    case TX_LU_REJECT:
        return submit_lu(hal, meta, (meta->result != 0u) ? meta->result : 1u);
    case TX_GRP_ATTACH_ACK:
        return submit_grp_ack(hal, meta);
    case TX_D_SETUP:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_setup);
    case TX_D_CALL_PROCEEDING:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_call_proceeding);
    case TX_D_CONNECT:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_connect);
    case TX_D_TX_GRANTED:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_tx_granted);
    case TX_D_RELEASE:
        return submit_cmce_pdu(hal, meta, tetra_cmce_build_d_release);
    default:
        return -1;
    }
}
