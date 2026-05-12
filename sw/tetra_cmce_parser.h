/*
 * tetra_cmce_parser.h — Phase 7 G.1 UL CMCE PDU parser
 *
 * Parses MSB-first bit streams of CMCE U-PDUs (the MM-body slice from
 * MAC-ACCESS Frag-1 or a reassembled MAC-FRAG body) and returns the
 * common fields needed by the call-control FSM.
 *
 * Source-of-truth: bluestation `crates/tetra-pdus/src/cmce/pdus/u_*.rs`
 * cross-checked against `memory/reference_cmce_group_call_pdus.md`
 * (ETSI EN 300 392-2 §14.7).
 *
 * Convention: input buffer holds the *CMCE body only* (i.e. the 5-bit
 * pdu_type at byte[0] bit 7 is the first bit of the buffer).  Bit 0 of
 * the body lands at byte[0] bit 7 (MSB-first).
 *
 * License: GPL v2
 */

#ifndef TETRA_CMCE_PARSER_H
#define TETRA_CMCE_PARSER_H

#include <stdint.h>

typedef enum {
    CMCE_NONE         = 0x00,
    CMCE_U_ALERT      = 0x10,   /* pdu_type =  0, marker bit 0x10 to avoid 0 collision */
    CMCE_U_CONNECT    = 0x02,   /* pdu_type =  2 */
    CMCE_U_DISCONNECT = 0x04,   /* pdu_type =  4 */
    CMCE_U_INFO       = 0x05,   /* pdu_type =  5 */
    CMCE_U_RELEASE    = 0x06,   /* pdu_type =  6 */
    CMCE_U_SETUP      = 0x07,   /* pdu_type =  7 */
    CMCE_U_STATUS     = 0x08,   /* pdu_type =  8 */
    CMCE_U_TX_CEASED  = 0x09,   /* pdu_type =  9 */
    CMCE_U_TX_DEMAND  = 0x0A,   /* pdu_type = 10 */
    CMCE_UNSUPPORTED  = 0xFF,
} cmce_pdu_type_t;

/* Called-party type identifier (ETSI §14.8.5 / PartyTypeIdentifier) */
#define CMCE_CPTI_SNA       0
#define CMCE_CPTI_SSI       1
#define CMCE_CPTI_TSI       2
#define CMCE_CPTI_RESERVED  3

/* Basic-service-information (8 bits) — packed exactly as on-air. */
typedef struct {
    uint8_t  circuit_mode_type;     /* 3 bit  */
    uint8_t  encryption_flag;       /* 1 bit  */
    uint8_t  communication_type;    /* 2 bit  */
    /* if circuit_mode_type == TchS (0): speech_service else slots_per_frame */
    uint8_t  speech_service;        /* 2 bit, valid iff TchS                 */
    uint8_t  slots_per_frame;       /* 2 bit, valid iff NOT TchS             */
} cmce_bsi_t;

typedef struct {
    cmce_pdu_type_t pdu_type;
    /* Header / common fields populated per pdu_type.  Unused fields = 0. */
    uint16_t call_identifier;       /* 14 bit, valid for U-CONNECT/U-INFO/   */
                                    /*         U-RELEASE/U-TX-CEASED/         */
                                    /*         U-TX-DEMAND/U-DISCONNECT       */
    /* U-SETUP fields ---------------------------------------------------- */
    uint8_t  area_selection;        /* 4 bit  */
    uint8_t  hook_method_selection; /* 1 bit  */
    uint8_t  simplex_duplex_selection; /* 1 bit */
    cmce_bsi_t bsi;                 /* valid for U-SETUP                     */
    uint8_t  request_to_transmit_send_data; /* 1 bit */
    uint8_t  call_priority;         /* 4 bit  */
    uint8_t  clir_control;          /* 2 bit  */
    uint8_t  called_party_type_identifier;  /* 2 bit  */
    uint32_t called_party_ssi;      /* 24 bit, valid iff cpti==SSI or TSI    */
    uint8_t  called_party_sna;      /* 8 bit, valid iff cpti==SNA            */
    uint32_t called_party_extension;/* 24 bit, valid iff cpti==TSI           */

    /* U-TX-DEMAND fields ------------------------------------------------ */
    uint8_t  tx_demand_priority;    /* 2 bit  */
    uint8_t  encryption_control;    /* 1 bit  */
    uint8_t  reserved;              /* 1 bit  */

    /* U-RELEASE / U-DISCONNECT fields ---------------------------------- */
    uint8_t  disconnect_cause;      /* 5 bit  */

    /* O-bit: 1 iff any Type-2/Type-3 fields followed.  We do NOT parse the
     * type-2/3 IE chain — callers that need IE-level detail must do their
     * own pass.  Phase 7 G.1 FSM only consumes the type-1 header.         */
    uint8_t  o_bit;
} cmce_pdu_t;

/* Parse a CMCE U-PDU body.
 *
 *   body_bits_msb_first  : pointer to MSB-first byte stream.  Bit 0 of the
 *                          body is byte[0] bit 7.
 *   n_bits               : number of valid bits in the buffer (typically
 *                          ≥ 7 for the smallest U-TX-CEASED header).
 *   out                  : populated with parsed fields.
 *
 * Returns 0 on success (out->pdu_type is the parsed type), -1 if the
 * buffer is too short for the indicated pdu_type, -2 if the pdu_type
 * field is unsupported by this parser.  out is always zero-initialised
 * before parsing.
 */
int tetra_cmce_parse(const uint8_t *body_bits_msb_first,
                     int n_bits, cmce_pdu_t *out);

#endif /* TETRA_CMCE_PARSER_H */
