/*
 * tetra_mm_demand_parser.h — SW-Port von tetra_ul_demand_ie_parser.v
 *
 * Phase 1B des Slice-Cleanup-Pfads. Walks die 129-bit MM-Bodies aus
 * tetra_ul_demand_body_mailbox (= REG_UL_DEMAND_BODY_*) für:
 *   - mm=2 U-LOCATION-UPDATE-DEMAND (ETSI EN 300 392-2 §16.10.21)
 *   - mm=7 U-ATTACH-DETACH-GROUP-IDENTITY (ETSI §16.10.5)
 *
 * Output-Struct ist Bit-für-Bit-äquivalent zum RTL-Parser (selbe Felder,
 * selbe Konventionen). Erlaubt A/B-Vergleich gegen den RTL-Parser und
 * spätere Substitution.
 *
 * Pure-C, kein dynamisches Allocation. ~500-800 Zeilen.
 *
 * License: GPL v2
 */
#ifndef TETRA_MM_DEMAND_PARSER_H
#define TETRA_MM_DEMAND_PARSER_H

#include <stdint.h>

/* Body-Bit-Format (matches tetra_ul_demand_body_mailbox.v):
 *   body_msb_first[0] bit 7 = body[128] (= erstes MM-Body-Bit on-air)
 *   body_msb_first[0] bit 6 = body[127]
 *   ...
 *   body_msb_first[16] bit 0 = body[0]   (= letztes MM-Body-Bit on-air)
 * Total: 17 byte (= 136 bit, davon 129 genutzt). */
#define TETRA_MM_DEMAND_BODY_BYTES 17

/* Parser-Output. Felder validity-flags wie der RTL-Parser. */
typedef struct {
    /* Header */
    uint8_t  parse_ok;            /* 1 = sauber durchgewalkt, 0 = strukturfehler */
    uint8_t  mm_pdu_type;         /* echo (2 oder 7) */
    uint32_t pdu_ssi;             /* MS-ISSI vom Mailbox-W1 (passthrough) */

    /* --- mm=2 U-LOCATION-UPDATE-DEMAND --- */
    uint8_t  location_update_type;        /* 3 bit */
    uint8_t  request_to_append_la;        /* 1 bit */
    uint8_t  cipher_control;              /* 1 bit */
    uint32_t class_of_ms;                 /* 24 bit */
    uint8_t  class_of_ms_valid;
    uint8_t  energy_saving_mode;          /* 3 bit */
    uint8_t  energy_saving_mode_valid;
    uint16_t la_information;              /* 14 bit */
    uint8_t  la_information_valid;
    uint32_t ssi_field;                   /* 24 bit */
    uint8_t  ssi_field_valid;
    uint32_t address_ext;                 /* 24 bit */
    uint8_t  address_ext_valid;

    /* GroupIdentityLocationDemand (single-GIU summary, Phase 7 F.2) */
    uint8_t  gild_valid;
    uint32_t gild_gssi;                   /* 24 bit */
    uint8_t  gild_class_of_usage;         /* 3 bit */
    uint8_t  gild_address_type;           /* 2 bit */

    /* --- mm=7 U-ATTACH-DETACH-GROUP-IDENTITY --- */
    uint8_t  gid_attach_detach_mode;      /* 1 bit (top-level mode) */
    uint8_t  gid_group_identity_report;   /* 1 bit (top-level report) */
    uint8_t  gid_count;                   /* 0..3 valid GIU records */
    struct {
        uint8_t  attach_detach;           /* 1 bit (0=attach, 1=detach) */
        uint8_t  class_of_usage;          /* 3 bit, valid only if attach */
        uint8_t  address_type;            /* 2 bit */
        uint32_t gssi;                    /* 24 bit (or VGSSI for at==2) */
    } gid_records[3];
} tetra_mm_demand_parsed_t;

/* Walks the 129-bit body. Output struct is zero-init'd by callee.
 * Returns 0 on success (parse_ok=1), -1 on structural error. */
int tetra_mm_demand_parser_parse(const uint8_t body_msb_first[TETRA_MM_DEMAND_BODY_BYTES],
                                  uint8_t mm_pdu_type,
                                  uint32_t pdu_ssi,
                                  tetra_mm_demand_parsed_t *out);

/* Helper: pack 6 mailbox words (W0, W1, W2-W5) into the MSB-first body array.
 *   word0_body128_mm = W0 (contains body[128] bit 0 + mm_pdu_type bits 7:4 + magic)
 *   word1_ssi        = W1 (bits 23:0 = SSI)
 *   word2..word5     = body[127:96], body[95:64], body[63:32], body[31:0]
 * Outputs:
 *   body_out         = 17 bytes MSB-first (bit 128 at byte[0] bit 7)
 *   mm_pdu_type_out  = mm_pdu_type from W0[7:4]
 *   pdu_ssi_out      = SSI from W1[23:0] */
void tetra_mm_demand_parser_unpack_mailbox(
        uint32_t word0_body128_mm,
        uint32_t word1_ssi,
        uint32_t word2_body_127_96,
        uint32_t word3_body_95_64,
        uint32_t word4_body_63_32,
        uint32_t word5_body_31_0,
        uint8_t body_out[TETRA_MM_DEMAND_BODY_BYTES],
        uint8_t *mm_pdu_type_out,
        uint32_t *pdu_ssi_out);

#endif /* TETRA_MM_DEMAND_PARSER_H */
