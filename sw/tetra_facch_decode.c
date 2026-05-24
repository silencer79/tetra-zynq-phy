/*
 * tetra_facch_decode.c — UL NTS2 FACCH-Stealing SCH/HD Soft-Decode + Dispatch
 *
 * Phase A (2026-05-23): MS sendet U-DISCONNECT/U-RELEASE als NTS2
 * FACCH-Stealing-Burst auf UL-Voice-Slot. FPGA-RTL hat einen 2. Sync-Detector
 * (NTS2-Pattern) plus 2. Capture-Instanz die 432 signed 4-bit soft-values in
 * REG_FACCH_NUB_READ_* schreibt. Diese SW liest die Mailbox, dekodiert BKN1
 * als SCH/HD (124 info bits), parst die CMCE-PDU und ruft
 * tetra_call_fsm_handle() — der U-DISCONNECT-Handler triggert dann
 * stage_d_release(). Vorher (ohne diesen Pfad) wurde U-DISCONNECT nie zum
 * FSM weitergeleitet → kein D-RELEASE im DL.
 *
 * Soft-bits werden hier zu hard-bits konvertiert (sign bit). Damit reicht
 * der existierende hard-bit-Decoder in tetra_channel_codec. Soft-Viterbi
 * könnte später ~1 dB SNR gewinnen, ist aber für FACCH (~1 PDU/Sekunde
 * im Worst-Case) nicht zeitkritisch.
 *
 * License: GPL v2
 */
#include "tetra_facch_decode.h"
#include "tetra_channel_codec.h"
#include "tetra_cmce_parser.h"
#include "tetra_call_fsm.h"

#include <stdio.h>
#include <string.h>

#define FACCH_NUB_WORDS    54   /* 432 × 4-bit soft = 1728 bits = 54 × 32 */
#define SOFT_W_BITS         4
#define BKN_TYPE5_BITS    216   /* SCH/HD type-5 length */
#define BKN_INFO_BITS     124   /* SCH/HD info bits */
#define BKN_TYPE2_BITS    140   /* info + CRC16 */
#define BKN_TYPE3_BITS    144   /* + 4 tail */
#define BKN_MOTHER_BITS   576   /* 144 × 4 (rate-1/4) */

/* Read 54 mailbox words into a 432-entry signed soft-array.
 * Convention (per nub_capture): coded_softs[431] = first BKN1 on-air bit.
 * type5[k] = coded_softs[431 - k]: type5[0..215] = BKN1, [216..431] = BKN2. */
static void read_facch_softs(tetra_hal_t *hal, int8_t *softs_432_out)
{
 for (int w = 0; w < FACCH_NUB_WORDS; w++) {
 tetra_reg_write(hal, REG_FACCH_NUB_READ_INDEX, (uint32_t)w);
 uint32_t word = tetra_reg_read(hal, REG_FACCH_NUB_READ_DATA);
 int base = w * 8;
 for (int n = 0; n < 8; n++) {
 uint32_t nib = (word >> (n * SOFT_W_BITS)) & 0xFu;
 int8_t s = (int8_t)((nib & 0x8) ? (int8_t)(nib | 0xF0) : (int8_t)nib);
 int coded_idx = base + n;
 if (coded_idx < 432)
 softs_432_out[431 - coded_idx] = s;
 }
 }
}

/* SCH/HD hard-decoder: 216 type-5 → 124 info.
 * Returns 0 on CRC OK, -1 on CRC fail (info still populated best-effort). */
static int sch_hd_decode_hard(const uint8_t *type5_216,
 uint8_t colour_code, uint8_t slot_num,
 uint16_t mcc, uint16_t mnc,
 uint8_t *info_124_out)
{
 uint8_t type4[BKN_TYPE5_BITS];
 uint8_t type3[BKN_TYPE5_BITS];
 uint8_t mother[BKN_MOTHER_BITS];
 uint8_t decoded[BKN_TYPE3_BITS];

 /* descramble: 216 type-5 → 216 type-4 */
 tetra_codec_descramble(type5_216, BKN_TYPE5_BITS,
 colour_code, slot_num, mcc, mnc, type4);

 /* deinterleave (N=216, a=101) */
 tetra_codec_deinterleave_perm(type4, BKN_TYPE5_BITS, 101, type3);

 /* depuncture P_2/3: 216 → 576 mother (with erasure markers '2') */
 tetra_codec_depuncture_r23(type3, BKN_TYPE5_BITS, mother);

 /* Viterbi R=1/4 K=5: 576 mother (= 144 × 4) → 144 decoded bits */
 tetra_codec_viterbi_r14(mother, BKN_TYPE3_BITS, decoded);

 /* Strip 4 tail bits: decoded[0..139] = type-2 (info + CRC) */
 /* CRC-16-CCITT check on first 140 bits */
 uint8_t crc_buf[BKN_TYPE2_BITS + 16];
 tetra_codec_crc16(decoded, BKN_INFO_BITS, crc_buf);
 int crc_ok = 1;
 for (int i = 0; i < 16; i++) {
 if (crc_buf[BKN_INFO_BITS + i] != decoded[BKN_INFO_BITS + i]) {
 crc_ok = 0;
 break;
 }
 }

 memcpy(info_124_out, decoded, BKN_INFO_BITS);
 return crc_ok ? 0 : -1;
}

/* Parse MAC-RESOURCE header (124 info bits MSB-first) → addressed SSI
 * + LLC/MLE payload start. Mirrors decode_dl.py logic for BKN1 SCH/HD.
 *
 * Return: SSI (or 0 if NULL/broadcast), llc_payload_start_bit set in *out_start.
 * Returns -1 if PDU is NULL or non-MAC-RESOURCE. */
static int32_t parse_mac_resource_header(const uint8_t *info_124,
 int *out_payload_start)
{
 /* MAC-RESOURCE PDU structure (ETSI EN 300 392-2 §21.4.3.1):
  *   pdu_type (2)
  *   fill_bit (1)
  *   pos_reserve (1)
  *   encryption (2)
  *   random_access_flag (1)
  *   length_indicator (6)
  *   address_type (3)
  *     0=Null, 1=SSI(ISSI), 2=Event-Label, 3=USSI/SMI, 4..7=Reserved
  *   ... depending on addr_type
  * For SSI(ISSI): 24-bit SSI follows after addr_type. */
 if (info_124 == NULL) return -1;

 /* Helper: read N bits MSB-first starting at bit offset b */
 #define GETBITS(b, n) ({ \
 uint32_t _v = 0; \
 for (int _i = 0; _i < (n); _i++) \
 _v = (_v << 1) | (info_124[(b) + _i] & 1); \
 _v; })

 unsigned pdu_type = GETBITS(0, 2);
 if (pdu_type != 0) return -1; /* not MAC-RESOURCE */
 unsigned fill_bit = GETBITS(2, 1);
 unsigned pos_reserve = GETBITS(3, 1);
 unsigned encryption = GETBITS(4, 2);
 unsigned ra_flag = GETBITS(6, 1);
 unsigned li = GETBITS(7, 6);
 unsigned addr_type = GETBITS(13, 3);
 (void)fill_bit; (void)pos_reserve; (void)encryption;
 (void)ra_flag; (void)li;

 int bit_offset = 16;
 int32_t ssi = 0;
 if (addr_type == 1) {
 /* SSI(ISSI): 24-bit SSI follows */
 ssi = (int32_t)GETBITS(16, 24);
 bit_offset = 40;
 } else if (addr_type == 0) {
 ssi = 0; /* NULL-PDU filler */
 } else {
 /* Other addr types — would need handling for completeness, skip */
 return -1;
 }

 /* Optional Length-Indicator extension flag etc skipped — minimum-viable
  * for U-DISCONNECT/U-RELEASE which arrive as standard SSI-addressed
  * MAC-RESOURCE + BL-DATA(NS=0) + CMCE-PDU. */
 *out_payload_start = bit_offset;
 return ssi;
 #undef GETBITS
}

int tetra_facch_decode_tick(tetra_hal_t *hal)
{
 if (hal == NULL) return -1;

 if ((tetra_reg_read(hal, REG_FACCH_NUB_READ_STATUS) & 0x1u) == 0u)
 return 0; /* no burst pending */

 /* 1. Read 432 soft-values from mailbox */
 int8_t softs[432];
 memset(softs, 0, sizeof(softs));
 read_facch_softs(hal, softs);

 /* 2. Soft → hard (sign-bit): positive soft = '1', negative = '0' */
 uint8_t type5_full[432];
 for (int i = 0; i < 432; i++)
 type5_full[i] = (softs[i] > 0) ? 1u : 0u;

 /* 3. SCH/HD-Decode BKN1 (type5[0..215]) */
 uint8_t cc = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3F);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint16_t mcc = (uint16_t)(cfg1 & 0x3FF);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFF);
 /* slot_num for cell scrambler: SCH/HD on voice-slot uses voice_tn,
  * but for descramble seed in TMO it's the slot index — empirically
  * the same as DL voice_filler (slot_num=1 in tetra_voice_filler.c). */
 uint8_t slot_num = 1;

 uint8_t info_124[BKN_INFO_BITS];
 int crc_ok = (sch_hd_decode_hard(type5_full, cc, slot_num, mcc, mnc,
 info_124) == 0);

 /* 4. ACK regardless of CRC — arm next burst */
 tetra_reg_write(hal, REG_FACCH_NUB_READ_ACK, 0x1u);

 if (!crc_ok) {
 fprintf(stderr,
 "tetra_facch_decode: BKN1 SCH/HD CRC FAIL (bursts_rx=%u)\n",
 (unsigned)(tetra_reg_read(hal, REG_FACCH_NUB_RX_CNT) & 0xFFFFu));
 return 1;
 }

 /* 5. Parse MAC-RESOURCE header → SSI + payload offset */
 int payload_start = 0;
 int32_t ssi = parse_mac_resource_header(info_124, &payload_start);
 if (ssi <= 0) {
 /* NULL-PDU or unsupported addr-type — common filler, not an error */
 return 1;
 }

 /* 6. Skip LLC header (BL-DATA = 5 bits: 4 LLC-type + 1 NS) +
  *    MLE-discriminator (3 bits) to land on CMCE body.
  * MVP-Annahme: BL-DATA(NS=0) + CMCE wie U-DISCONNECT/U-RELEASE.
  * Match decode_dl.py / attach_daemon walker payload-offset logic. */
 int llc_hdr_bits = 5; /* BL-DATA */
 int mle_pd_bits = 3;
 int cmce_start = payload_start + llc_hdr_bits + mle_pd_bits;
 int cmce_bits = BKN_INFO_BITS - cmce_start;
 if (cmce_bits <= 0) return 1;

 /* Pack CMCE bits into bytes MSB-first */
 uint8_t body[16];
 memset(body, 0, sizeof(body));
 for (int i = 0; i < cmce_bits && i < (int)sizeof(body) * 8; i++) {
 if (info_124[cmce_start + i] & 1)
 body[i >> 3] |= (uint8_t)(0x80u >> (i & 7));
 }

 cmce_pdu_t p;
 memset(&p, 0, sizeof(p));
 int rc = tetra_cmce_parse(body, cmce_bits, &p);
 if (rc == 0) {
 fprintf(stderr,
 "tetra_facch_decode: NTS2-FACCH ssi=0x%06X pdu_type=%u "
 "→ tetra_call_fsm_handle\n",
 (unsigned)ssi, (unsigned)p.pdu_type);
 (void)tetra_call_fsm_handle(hal, (uint32_t)ssi, &p);
 } else {
 fprintf(stderr,
 "tetra_facch_decode: cmce_parse rc=%d ssi=0x%06X "
 "cmce_bits=%d body=%02X%02X%02X%02X\n",
 rc, (unsigned)ssi, cmce_bits,
 body[0], body[1], body[2], body[3]);
 }
 return 1;
}
