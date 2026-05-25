/*
 * tetra_mm_demand_parser.c — SW-Port von tetra_ul_demand_ie_parser.v
 *
 * Phase 1B Slice-Cleanup. Implementiert die mm=2 + mm=7 Walker
 * bit-äquivalent zum RTL-FSM (states S_HEADER_T1..S_T3_PAYLOAD_GILD
 * und S_GAD_HDR..S_GAD_GIU_REC_GSSI).
 *
 * Bit-Cursor: pos = Anzahl bereits konsumierter Bits ab MSB (body[128] = pos 0).
 *             remain = 129 − pos = Anzahl noch verfügbarer Bits.
 *
 * License: GPL v2
 */
#include "tetra_mm_demand_parser.h"

#include <string.h>

#define BODY_BITS 129

/* Read `n` bits at position `*pos` (MSB-first), advance cursor. Returns 0
 * silently on overflow (caller checks remain before). */
static uint32_t read_bits(const uint8_t *body, int *pos, int n)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        int p = *pos + i;
        if (p >= BODY_BITS) return v;  /* defensive — overflow */
        v = (v << 1) | ((body[p >> 3] >> (7 - (p & 7))) & 1u);
    }
    *pos += n;
    return v;
}

/* Peek 1 bit without advancing. */
static uint32_t peek_bit(const uint8_t *body, int pos)
{
    if (pos >= BODY_BITS) return 0;
    return (body[pos >> 3] >> (7 - (pos & 7))) & 1u;
}

/* mm=2 U-LOCATION-UPDATE-DEMAND walker.
 * Mirrors RTL states S_HEADER_T1, S_OPT_OBIT, S_T2_CLASS_P, S_T2_ESM_P,
 * S_T2_LA_P, S_T2_SSI_P, S_T2_AE_P, S_T3_M, S_T3_HEADER, S_T3_PAYLOAD_GILD. */
static int walk_mm2(const uint8_t *body, tetra_mm_demand_parsed_t *out)
{
    int pos = 0;
    int remain = BODY_BITS;

    /* Type-1 header: 3 bit LUT + 1 bit ra + 1 bit cc (= 5 bit) */
    if (remain < 5) return -1;
    out->location_update_type   = (uint8_t)read_bits(body, &pos, 3);
    out->request_to_append_la   = (uint8_t)read_bits(body, &pos, 1);
    out->cipher_control         = (uint8_t)read_bits(body, &pos, 1);
    remain -= 5;

    if (out->cipher_control) {
        if (remain < 10) return -1;
        (void)read_bits(body, &pos, 10);  /* skip ciphering_parameters */
        remain -= 10;
    }

    /* Optional-fields o-bit */
    if (remain == 0) return 0;  /* body ended cleanly */
    uint32_t obit = read_bits(body, &pos, 1);
    remain -= 1;
    if (obit == 0) return 0;

    /* S_T2_CLASS_P: p_class_of_ms + 24-bit class_of_ms */
    if (remain == 0) return -1;
    uint32_t p = read_bits(body, &pos, 1); remain -= 1;
    if (p) {
        if (remain < 24) return -1;
        out->class_of_ms       = read_bits(body, &pos, 24);
        out->class_of_ms_valid = 1;
        remain -= 24;
    }

    /* S_T2_ESM_P */
    if (remain == 0) return -1;
    p = read_bits(body, &pos, 1); remain -= 1;
    if (p) {
        if (remain < 3) return -1;
        out->energy_saving_mode       = (uint8_t)read_bits(body, &pos, 3);
        out->energy_saving_mode_valid = 1;
        remain -= 3;
    }

    /* S_T2_LA_P: bluestation reads 15 bit, divides by 2 → expose 14 bit (low bit always 0). */
    if (remain == 0) return -1;
    p = read_bits(body, &pos, 1); remain -= 1;
    if (p) {
        if (remain < 15) return -1;
        uint32_t la15 = read_bits(body, &pos, 15);
        out->la_information       = (uint16_t)(la15 >> 1);  /* 14-bit LA */
        out->la_information_valid = 1;
        remain -= 15;
    }

    /* S_T2_SSI_P */
    if (remain == 0) return -1;
    p = read_bits(body, &pos, 1); remain -= 1;
    if (p) {
        if (remain < 24) return -1;
        out->ssi_field       = read_bits(body, &pos, 24);
        out->ssi_field_valid = 1;
        remain -= 24;
    }

    /* S_T2_AE_P */
    if (remain == 0) return -1;
    p = read_bits(body, &pos, 1); remain -= 1;
    if (p) {
        if (remain < 24) return -1;
        out->address_ext       = read_bits(body, &pos, 24);
        out->address_ext_valid = 1;
        remain -= 24;
    }

    /* Type-3 list: m-bit + (elem_id + length + payload) loop. */
    while (remain > 0) {
        uint32_t mbit = read_bits(body, &pos, 1);
        remain -= 1;
        if (mbit == 0) return 0;  /* terminator */
        if (remain < 15) return -1;
        uint32_t elem_id  = read_bits(body, &pos, 4);
        uint32_t elem_len = read_bits(body, &pos, 11);
        remain -= 15;
        if ((int)elem_len > remain) return -1;

        if (elem_id == 3 && elem_len > 0) {
            /* GroupIdentityLocationDemand (GILD) sub-walker — single-GIU
             * extraction matching RTL S_T3_PAYLOAD_GILD semantics:
             *   payload[0]   reserved (= 0)
             *   payload[1]   group_identity_attach_detach_mode
             *   payload[2]   o-bit
             *   if o-bit:
             *     payload[3]      m-bit (must be 1)
             *     payload[4..7]   elem_id (= 8 for GIU)
             *     payload[8..18]  length
             *     payload[19..24] num_elem
             *     payload[25..]   GIU records
             *   First GIU (attach only):
             *     [25]      adi
             *     [26..28]  cou (3 bit)
             *     [29..30]  at (2 bit)
             *     [31..54]  gssi (24 bit) if at ∈ {0,1}
             */
            int gp = pos;          /* GILD payload start */
            uint32_t g = elem_len; /* payload length in bits */

            if (g >= 3) {
                /* atd_mode = bit 1 of payload (not exposed in output, parsed only) */
                /* obit = bit 2 of payload */
                uint32_t obit_gild = peek_bit(body, gp + 2);
                if (obit_gild && g >= 29) {
                    uint32_t mb     = peek_bit(body, gp + 3);
                    int sub_pos     = gp + 4;
                    uint32_t sub_id = read_bits(body, &sub_pos, 4);
                    uint32_t sub_len = read_bits(body, &sub_pos, 11);
                    if (mb == 1 && sub_id == 8 && sub_len >= 6 && g >= 32) {
                        int ne_pos = gp + 19;
                        uint32_t num_elem = read_bits(body, &ne_pos, 6);
                        if (num_elem >= 1) {
                            uint32_t adi = peek_bit(body, gp + 25);
                            if (adi == 0 && g >= 56) {
                                int cou_pos = gp + 26;
                                uint32_t cou = read_bits(body, &cou_pos, 3);
                                uint32_t at  = read_bits(body, &cou_pos, 2);
                                if (at == 0 || at == 1) {
                                    int gssi_pos = gp + 31;
                                    uint32_t gssi = read_bits(body, &gssi_pos, 24);
                                    out->gild_gssi           = gssi;
                                    out->gild_class_of_usage = (uint8_t)cou;
                                    out->gild_address_type   = (uint8_t)at;
                                    out->gild_valid          = 1;
                                }
                            }
                        }
                    }
                }
            }
            /* Consume payload from outer cursor regardless of sub-parse result */
            pos += elem_len;
            remain -= elem_len;
        } else {
            /* Skip unknown Type-3 element. */
            pos += elem_len;
            remain -= elem_len;
        }
    }
    return 0;
}

/* mm=7 U-ATTACH-DETACH-GROUP-IDENTITY walker.
 * Mirrors RTL states S_GAD_HDR, S_GAD_OBIT, S_GAD_M_REP, S_GAD_M_GIU,
 * S_GAD_GIU_INIT, S_GAD_GIU_REC_HDR, S_GAD_GIU_REC_GSSI. */
static int walk_mm7(const uint8_t *body, tetra_mm_demand_parsed_t *out)
{
    int pos = 0;
    int remain = BODY_BITS;

    /* Header: group_identity_report (1) + attach_detach_mode (1) */
    if (remain < 2) return -1;
    out->gid_group_identity_report = (uint8_t)read_bits(body, &pos, 1);
    out->gid_attach_detach_mode    = (uint8_t)read_bits(body, &pos, 1);
    remain -= 2;

    /* o-bit */
    if (remain == 0) return 0;
    uint32_t obit = read_bits(body, &pos, 1); remain -= 1;
    if (obit == 0) return 0;

    /* m-bit for GroupReportResponse (Type-3, elem_id=4) — bluestation peek
     * semantics: only consume when m=1 AND next 4 bits == 4. */
    if (remain == 0) return -1;
    uint32_t m_rep = peek_bit(body, pos);
    if (m_rep == 0) {
        pos += 1; remain -= 1;
        /* GRR not present, fall to GIU */
    } else if (remain >= 5) {
        uint32_t peek_id = (uint32_t)((body[(pos+1) >> 3] >> (7 - ((pos+1) & 7))) & 1u);
        peek_id = (peek_id << 1) | ((body[(pos+2) >> 3] >> (7 - ((pos+2) & 7))) & 1u);
        peek_id = (peek_id << 1) | ((body[(pos+3) >> 3] >> (7 - ((pos+3) & 7))) & 1u);
        peek_id = (peek_id << 1) | ((body[(pos+4) >> 3] >> (7 - ((pos+4) & 7))) & 1u);
        if (peek_id != 4) {
            /* m-bit belongs to GIU walker, leave it */
        } else if (remain >= 16) {
            pos += 1; remain -= 1;  /* consume m-bit */
            uint32_t elem_id  = read_bits(body, &pos, 4);
            uint32_t skip_len = read_bits(body, &pos, 11);
            (void)elem_id;
            remain -= 15;
            if ((int)skip_len > remain) return -1;
            pos += skip_len;
            remain -= skip_len;
        } else {
            return -1;
        }
    } else {
        return -1;
    }

    /* m-bit for GroupIdentityUplink (Type-4, elem_id=8) */
    if (remain == 0) return 0;
    uint32_t m_giu = read_bits(body, &pos, 1); remain -= 1;
    if (m_giu == 0) return 0;

    if (remain < 15) return -1;
    uint32_t giu_id   = read_bits(body, &pos, 4);
    uint32_t giu_len  = read_bits(body, &pos, 11);
    remain -= 15;
    if (giu_id != 8 || (int)giu_len > remain) return -1;

    /* GIU payload starts here: num_elem (6) + N × record */
    if (giu_len < 6) return -1;
    uint32_t num_elem = read_bits(body, &pos, 6);
    int giu_remain = (int)giu_len - 6;
    remain -= 6;

    if (num_elem == 0) return 0;

    for (uint32_t r = 0; r < num_elem && r < 3; r++) {
        /* Record header */
        if (giu_remain < 1) {
            out->gid_count = (uint8_t)r;
            return (r == 0) ? -1 : 0;
        }
        uint32_t adi = read_bits(body, &pos, 1);
        giu_remain -= 1; remain -= 1;

        uint32_t cou = 0;
        uint32_t at  = 0;

        if (adi == 0) {
            /* attach: cou(3) + at(2) */
            if (giu_remain < 5) {
                out->gid_count = (uint8_t)r;
                return (r == 0) ? -1 : 0;
            }
            cou = read_bits(body, &pos, 3);
            at  = read_bits(body, &pos, 2);
            giu_remain -= 5; remain -= 5;
        } else {
            /* detach: skip(2) + at(2) */
            if (giu_remain < 4) {
                out->gid_count = (uint8_t)r;
                return (r == 0) ? -1 : 0;
            }
            (void)read_bits(body, &pos, 2);  /* skip */
            at = read_bits(body, &pos, 2);
            giu_remain -= 4; remain -= 4;
        }

        /* GSSI (24 bit) if at ∈ {0,1,2} */
        uint32_t gssi = 0;
        if (at == 0 || at == 1 || at == 2) {
            if (giu_remain < 24) {
                out->gid_count = (uint8_t)r;
                return (r == 0) ? -1 : 0;
            }
            gssi = read_bits(body, &pos, 24);
            giu_remain -= 24; remain -= 24;
            /* at == 1: also 24-bit address_extension follows (skip) */
            if (at == 1) {
                if (giu_remain < 24) {
                    out->gid_count = (uint8_t)r;
                    return (r == 0) ? -1 : 0;
                }
                (void)read_bits(body, &pos, 24);
                giu_remain -= 24; remain -= 24;
            }
        }

        out->gid_records[r].attach_detach   = (uint8_t)adi;
        out->gid_records[r].class_of_usage  = (uint8_t)cou;
        out->gid_records[r].address_type    = (uint8_t)at;
        out->gid_records[r].gssi            = gssi;
        out->gid_count = (uint8_t)(r + 1);
    }

    return 0;
}

int tetra_mm_demand_parser_parse(const uint8_t body_msb_first[TETRA_MM_DEMAND_BODY_BYTES],
                                  uint8_t mm_pdu_type,
                                  uint32_t pdu_ssi,
                                  tetra_mm_demand_parsed_t *out)
{
    memset(out, 0, sizeof(*out));
    out->mm_pdu_type = mm_pdu_type;
    out->pdu_ssi     = pdu_ssi;

    int rc;
    switch (mm_pdu_type) {
    case 2:
        rc = walk_mm2(body_msb_first, out);
        break;
    case 7:
        rc = walk_mm7(body_msb_first, out);
        break;
    default:
        return -1;
    }

    if (rc == 0) {
        out->parse_ok = 1;
    }
    return rc;
}

void tetra_mm_demand_parser_unpack_mailbox(
        uint32_t word0_body128_mm,
        uint32_t word1_ssi,
        uint32_t word2_body_127_96,
        uint32_t word3_body_95_64,
        uint32_t word4_body_63_32,
        uint32_t word5_body_31_0,
        uint8_t body_out[TETRA_MM_DEMAND_BODY_BYTES],
        uint8_t *mm_pdu_type_out,
        uint32_t *pdu_ssi_out)
{
    memset(body_out, 0, TETRA_MM_DEMAND_BODY_BYTES);

    /* W0[7:4] = mm_pdu_type, W0[0] = body[128] */
    if (mm_pdu_type_out) *mm_pdu_type_out = (uint8_t)((word0_body128_mm >> 4) & 0xF);
    if (pdu_ssi_out)     *pdu_ssi_out     = word1_ssi & 0x00FFFFFFu;

    /* body[128] → bit 7 of byte 0 */
    if (word0_body128_mm & 1u) body_out[0] = 0x80;

    /* body[127:96] → bits 127..96, packed into bytes 0..4 (bit 7 of byte 0
     * is already set for body[128], rest fills downward). */
    uint32_t bits127_0[4] = {
        word2_body_127_96,
        word3_body_95_64,
        word4_body_63_32,
        word5_body_31_0
    };

    /* Pack bits 127..0 into MSB-first stream starting at body_out byte 0 bit 6. */
    int p = 1;  /* bit 1 of byte 0 (next after body[128] at bit 0... no wait, byte 0 bit 7 = body[128]; next is byte 0 bit 6 = body[127]) */
    for (int word_idx = 0; word_idx < 4; word_idx++) {
        uint32_t w = bits127_0[word_idx];
        /* Word has bits [127:96] for word_idx=0, etc. Bit 31 of word = highest bit. */
        for (int b = 31; b >= 0; b--) {
            uint32_t bit = (w >> b) & 1u;
            if (bit) {
                body_out[p >> 3] |= (uint8_t)(1u << (7 - (p & 7)));
            }
            p++;
        }
    }
    /* p is now 129. Bits 130..135 (= bytes 16..17 trailing) are 0. */
}
