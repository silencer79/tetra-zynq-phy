/*
 * tetra_facch_steal.c — DL FACCH-Stealing API implementation
 *
 * Encoded SCH/HD bits werden via REG_FACCH_STEAL_BKN1/BKN2_INDEX/DATA/GO
 * in die RTL-Mailbox geschrieben (16-word indirect-mailbox je BKN, gleiche
 * Semantik wie REG_VOICE_FILLER_* aber für 216 statt 432 bits).
 *
 * Word-Layout (siehe rtl/lmac/tetra_facch_steal_mailbox.v):
 *   W0..W6   216 type-5 bits LSB-first (= 6.75 words, top 8 bits in W6 = 0)
 *   W15[0]   bank_valid (= 1 nach kompletten Write)
 *
 * License: GPL v2
 */
#include "tetra_facch_steal.h"
#include "tetra_sch_hd_encoder.h"
#include "tetra_mac_resource_dl_builder.h"
#include "tetra_cmce_body.h"

#include <stdio.h>
#include <string.h>

/* Pack 216 type-5 bits (MSB-first input) into 7 × 32-bit words (LSB-first
 * pro word). Identische Konvention wie tetra_voice_filler.c::pack_bits_mailbox
 * aber für SCH/HD (216 bits = BKN1) statt SCH/F (432 bits = BKN1+BKN2).
 */
static void pack_bkn_mailbox(const uint8_t *type5_216, uint32_t *words_7)
{
 memset(words_7, 0, 7 * sizeof(uint32_t));
 for (int i = 0; i < 216; i++) {
 if (type5_216[i] & 1) {
 int dst = 215 - i;
 words_7[dst >> 5] |= (uint32_t)1u << (dst & 31);
 }
 }
}

/* Write 7 packed words to one BKN-mailbox, set W15[0]=1, pulse GO. */
static void write_bkn_mailbox(tetra_hal_t *hal,
 uint32_t reg_index, uint32_t reg_data,
 uint32_t reg_go, const uint32_t *words_7)
{
 for (int i = 0; i < 7; i++) {
 tetra_reg_write(hal, reg_index, (uint32_t)i);
 tetra_reg_write(hal, reg_data, words_7[i]);
 }
 /* W15[0] = valid */
 tetra_reg_write(hal, reg_index, 15u);
 tetra_reg_write(hal, reg_data, 0x00000001u);
 tetra_reg_write(hal, reg_go, 0x1u);
}

/* Read MCC/MNC/CC from cell config for scrambler init.
 * TMO cell-identity scrambler init per ETSI EN 300 392-2 §8.2.5:
 *   init = (MCC<<22)|(MNC<<8)|(CC<<2)|3
 * The trailing |3 is the fixed "extended-scrambling-code domain" bits,
 * NOT a slot_num. Decode side uses |3 unconditionally
 * (scripts/decode_dl.py::make_scramb_code). */
static uint32_t cell_scramb_init(tetra_hal_t *hal)
{
 uint8_t cc = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3F);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint16_t mcc = (uint16_t)(cfg1 & 0x3FF);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFF);
 return ((uint32_t)mcc << 22) |
 ((uint32_t)mnc << 8) |
 ((uint32_t)cc  << 2) |
 0x3u;
}

int tetra_facch_steal_stage(tetra_hal_t *hal, unsigned voice_tn,
 uint8_t mode,
 const uint8_t *bkn1_info_124,
 const uint8_t *bkn2_info_124)
{
 if (hal == NULL || voice_tn > 3) return -1;
 if (mode < SLOT_MODE_HALF_STEAL_SIG ||
 mode > SLOT_MODE_FULL_STEAL_FILLER) return -1;
 if (bkn1_info_124 == NULL) return -1;

 uint8_t bkn1_type5[216];
 uint8_t bkn2_type5[216];
 uint32_t bkn1_words[7];
 uint32_t bkn2_words[7];

 uint32_t scramb = cell_scramb_init(hal);

 /* Encode BKN1 (signaling PDU) */
 tetra_sch_hd_encode(bkn1_info_124, scramb, bkn1_type5);
 pack_bkn_mailbox(bkn1_type5, bkn1_words);
 write_bkn_mailbox(hal, REG_FACCH_STEAL_BKN1_INDEX,
 REG_FACCH_STEAL_BKN1_DATA,
 REG_FACCH_STEAL_BKN1_GO, bkn1_words);

 /* Encode BKN2 (SYSINFO oder anderer SCH/HD-content); im HALF_STEAL_SIG-
  * Modus genutzt nur wenn bkn2_info_124!=NULL — sonst nimmt burst_dispatcher
  * vfill_blk2 (TCH-Voice-Half). */
 if (bkn2_info_124 != NULL) {
 tetra_sch_hd_encode(bkn2_info_124, scramb, bkn2_type5);
 pack_bkn_mailbox(bkn2_type5, bkn2_words);
 write_bkn_mailbox(hal, REG_FACCH_STEAL_BKN2_INDEX,
 REG_FACCH_STEAL_BKN2_DATA,
 REG_FACCH_STEAL_BKN2_GO, bkn2_words);
 } else {
 /* HALF_STEAL_SIG ohne explizite BKN2: trotzdem valid setzen mit
  * dummy-bits (W15[0]=1) damit facch_steal_valid_sys hochgeht.
  * burst_dispatcher nimmt dann vfill_blk2 statt facch_bkn2. */
 for (int i = 0; i < 7; i++) bkn2_words[i] = 0;
 write_bkn_mailbox(hal, REG_FACCH_STEAL_BKN2_INDEX,
 REG_FACCH_STEAL_BKN2_DATA,
 REG_FACCH_STEAL_BKN2_GO, bkn2_words);
 }

 /* Set slot_mode[voice_tn] = mode (4-bit lane). Read-modify-write damit
  * andere TN unangetastet bleiben. */
 uint32_t slot_mode = tetra_reg_read(hal, REG_SLOT_MODE);
 uint32_t mask = (uint32_t)0xFu << (voice_tn * 4);
 slot_mode = (slot_mode & ~mask) | (((uint32_t)mode & 0xFu) << (voice_tn * 4));
 tetra_reg_write(hal, REG_SLOT_MODE, slot_mode);

 fprintf(stderr,
 "tetra_facch_steal: staged voice_tn=%u mode=%u (BKN1 + %s BKN2)\n",
 voice_tn, (unsigned)mode,
 bkn2_info_124 ? "SCH/HD" : "vfill (TCH-half)");
 return 0;
}

void tetra_facch_steal_clear(tetra_hal_t *hal, unsigned voice_tn)
{
 if (hal == NULL || voice_tn > 3) return;
 uint32_t slot_mode = tetra_reg_read(hal, REG_SLOT_MODE);
 uint32_t mask = (uint32_t)0xFu << (voice_tn * 4);
 slot_mode = slot_mode & ~mask; /* lane = 0 = IDLE */
 tetra_reg_write(hal, REG_SLOT_MODE, slot_mode);
 fprintf(stderr,
 "tetra_facch_steal: cleared voice_tn=%u → slot_mode=0x%08X\n",
 voice_tn, slot_mode);
}

/* ========================================================================
 * 124-bit PDU-Builder für SCH/HD-FACCH-Stealing.
 *
 * D-RELEASE-BKN1: MAC-RESOURCE addr=SSI + LLC=BL-UDATA + MLE=CMCE + CMCE
 * D-RELEASE call_id+cause. Gold-Pattern hat optional ChanAlloc-Keep-Element;
 * MVP ohne ChanAlloc (kann später nachgereicht werden).
 *
 * SYSINFO-BKN2: MAC-BROADCAST sub=SYSINFO mit Live-Cell-Config (MCC/MNC/CC/
 * Carrier/Band/Duplex/LA aus REG_CELL_CFG_*). Reproduziert Layout aus
 * tetra_hal.c::build_bnch_sysinfo aber portable für Cross-Compile + Read
 * von Hardware-Registern.
 * ======================================================================== */

static void pack_bits_msb(uint8_t *out, int *pos, uint32_t value, int nbits)
{
 for (int i = 0; i < nbits; i++)
 out[(*pos)++] = (uint8_t)((value >> (nbits - 1 - i)) & 1u);
}

/* Build 124-bit MAC-RESOURCE + LLC-BL-UDATA + MLE-CMCE + CMCE D-RELEASE. */
static void build_d_release_124bit(uint16_t call_id, uint32_t ssi,
 uint8_t cause, uint8_t out_124[124])
{
 /* Use existing 268-bit MAC-RESOURCE builder, truncate to 124 bits.
  * tetra_build_mac_resource_pdu handles MAC-Header (40-bit SSI),
  * flag bits, LLC header (BL-UDATA = 4 bit), MLE-PD (3 bit) + MM body.
  * For D-RELEASE the MM body is the CMCE PDU (25 bit). */
 tetra_mac_res_meta_t meta;
 memset(&meta, 0, sizeof(meta));
 meta.ssi = ssi;
 meta.addr_type = MAC_ADDR_TYPE_SSI;
 meta.llc_pdu_type = MAC_LLC_BL_UDATA;
 meta.mle_pd = 2; /* CMCE discriminator */

 cmce_meta_t cmce;
 memset(&cmce, 0, sizeof(cmce));
 cmce.call_identifier = call_id;
 cmce.disconnect_cause = cause;

 uint8_t cmce_body[TETRA_CMCE_MAX_BYTES];
 int cmce_bits = tetra_cmce_build_d_release(&cmce, cmce_body);
 if (cmce_bits <= 0) {
 memset(out_124, 0, 124);
 return;
 }
 /* tetra_cmce_build_d_release returns bytes-MSB but we need bit-array. */
 uint8_t cmce_bit_array[64];
 for (int i = 0; i < cmce_bits; i++)
 cmce_bit_array[i] = (cmce_body[i >> 3] >> (7 - (i & 7))) & 1u;

 uint8_t pdu_268[TETRA_MAC_RES_PDU_BITS];
 if (tetra_build_mac_resource_pdu(&meta, cmce_bit_array, cmce_bits,
 pdu_268) != 0) {
 memset(out_124, 0, 124);
 return;
 }
 memcpy(out_124, pdu_268, 124);
}

/* Build 124-bit MAC-BROADCAST SYSINFO from live cell-config registers. */
static void build_sysinfo_124bit(tetra_hal_t *hal, uint8_t out_124[124])
{
 memset(out_124, 0, 124);
 int bp = 0;

 uint32_t cfg0 = tetra_reg_read(hal, REG_CELL_CFG_0);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint8_t cc = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3F);
 uint32_t la = tetra_reg_read(hal, REG_CELL_LA) & 0x3FFF;

 uint16_t mcc = (uint16_t)(cfg1 & 0x3FF);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFF);
 uint8_t f18ext = (uint8_t)((cfg0 >> 10) & 0x01);
 (void)cc; (void)mcc; (void)mnc; (void)f18ext;

 /* Frequency derivation: our cell DL = 438.25 MHz (REG_DL_FREQ unset
  * in HAL — use hardcoded for current setup). Gold-decode showed Carrier=1530,
  * Band=4 in our local cell WAV: that matches 438.25 MHz exactly
  * (Band=4 × 100M + Carrier=1530 × 25k = 438.25M). */
 uint8_t band = 4;
 uint16_t carrier = 1530;

 /* MAC PDU type (2 bits): 10 = Broadcast */
 pack_bits_msb(out_124, &bp, 2, 2);
 /* MAC-BROADCAST sub-type (2 bits): 00 = SYSINFO */
 pack_bits_msb(out_124, &bp, 0, 2);

 pack_bits_msb(out_124, &bp, carrier, 12);
 pack_bits_msb(out_124, &bp, band, 4);
 pack_bits_msb(out_124, &bp, 0, 2); /* Offset = 0 */
 pack_bits_msb(out_124, &bp, 1, 3); /* Duplex spacing = 1 (10 MHz für 400-MHz-Band) */
 pack_bits_msb(out_124, &bp, 0, 1); /* Reverse op = 0 */
 pack_bits_msb(out_124, &bp, 0, 2); /* Num common SCs = 0 */
 pack_bits_msb(out_124, &bp, 6, 3); /* MS TX power max = 6 */
 pack_bits_msb(out_124, &bp, 0, 4); /* RX level access min = 0 */
 pack_bits_msb(out_124, &bp, 10, 4); /* Access parameter = 10 */
 pack_bits_msb(out_124, &bp, 5, 4); /* Radio DL timeout = 5 */
 pack_bits_msb(out_124, &bp, 0, 1); /* HF/CK flag = 0 (HF follows) */
 pack_bits_msb(out_124, &bp, 0, 16); /* Hyperframe number = 0 */
 pack_bits_msb(out_124, &bp, 0, 2); /* Optional field selector = 0 (None) */
 pack_bits_msb(out_124, &bp, 0, 20); /* Optional field value = 0 */
 pack_bits_msb(out_124, &bp, la, 14);
 pack_bits_msb(out_124, &bp, 0xFFFF, 16); /* Subscriber class = all */
 pack_bits_msb(out_124, &bp, 1, 1); /* Registration required */
 pack_bits_msb(out_124, &bp, 1, 1); /* De-registration required */
 pack_bits_msb(out_124, &bp, 0, 1); /* Priority cell */
 pack_bits_msb(out_124, &bp, 1, 1); /* Cell never uses min mode */
 pack_bits_msb(out_124, &bp, 0, 1); /* Migration supported */
 pack_bits_msb(out_124, &bp, 1, 1); /* System wide services */
 pack_bits_msb(out_124, &bp, 1, 1); /* TETRA voice service */
 pack_bits_msb(out_124, &bp, 1, 1); /* Circuit mode data */
 pack_bits_msb(out_124, &bp, 0, 1); /* Reserved */
 pack_bits_msb(out_124, &bp, 1, 1); /* SNDCP service */
 pack_bits_msb(out_124, &bp, 0, 1); /* Air interface encryption = 0 */
 pack_bits_msb(out_124, &bp, 1, 1); /* Advanced link supported */
 /* bp should be 124 now (= total SYSINFO bits per ETSI §18.4.2.1) */
}

int tetra_facch_steal_d_release(tetra_hal_t *hal, unsigned voice_tn,
 uint16_t call_id, uint32_t ssi, uint8_t cause)
{
 if (hal == NULL || voice_tn > 3) return -1;

 uint8_t bkn1_bits[124];
 uint8_t bkn2_bits[124];
 build_d_release_124bit(call_id, ssi, cause, bkn1_bits);
 build_sysinfo_124bit(hal, bkn2_bits);
 return tetra_facch_steal_stage(hal, voice_tn, SLOT_MODE_FULL_STEAL_SIG,
 bkn1_bits, bkn2_bits);
}

int tetra_facch_steal_filler(tetra_hal_t *hal, unsigned voice_tn)
{
 if (hal == NULL || voice_tn > 3) return -1;

 /* BKN1 = NULL-PDU-Filler (124 zero bits = MAC-RESOURCE addr=NULL filler),
  * BKN2 = live SYSINFO-Broadcast. Slot bleibt in FULL_STEAL_FILLER-Mode
  * (AACH 0x2049 NDB2) dauerhaft bis nächster Call. */
 uint8_t bkn1_null[124] = {0};
 uint8_t bkn2_sysinfo[124];
 build_sysinfo_124bit(hal, bkn2_sysinfo);
 return tetra_facch_steal_stage(hal, voice_tn,
 SLOT_MODE_FULL_STEAL_FILLER,
 bkn1_null, bkn2_sysinfo);
}

/* Build 124-bit MAC-RESOURCE + LLC-BL-UDATA + MLE-CMCE + CMCE D-TX-CEASED. */
static void build_d_tx_ceased_124bit(uint16_t call_id, uint32_t ssi,
 uint8_t out_124[124])
{
 tetra_mac_res_meta_t meta;
 memset(&meta, 0, sizeof(meta));
 meta.ssi = ssi;
 meta.addr_type = MAC_ADDR_TYPE_SSI;
 meta.llc_pdu_type = MAC_LLC_BL_UDATA;
 meta.mle_pd = 2; /* CMCE discriminator */

 cmce_meta_t cmce;
 memset(&cmce, 0, sizeof(cmce));
 cmce.call_identifier = call_id;
 cmce.transmission_request_permission = 0;

 uint8_t cmce_body[TETRA_CMCE_MAX_BYTES];
 int cmce_bits = tetra_cmce_build_d_tx_ceased(&cmce, cmce_body);
 if (cmce_bits <= 0) { memset(out_124, 0, 124); return; }

 uint8_t cmce_bit_array[64];
 for (int i = 0; i < cmce_bits; i++)
 cmce_bit_array[i] = (cmce_body[i >> 3] >> (7 - (i & 7))) & 1u;

 uint8_t pdu_268[TETRA_MAC_RES_PDU_BITS];
 if (tetra_build_mac_resource_pdu(&meta, cmce_bit_array, cmce_bits,
 pdu_268) != 0) {
 memset(out_124, 0, 124);
 return;
 }
 memcpy(out_124, pdu_268, 124);
}

int tetra_facch_steal_d_tx_ceased(tetra_hal_t *hal, unsigned voice_tn,
 uint16_t call_id, uint32_t ssi)
{
 if (hal == NULL || voice_tn > 3) return -1;

 uint8_t bkn1_bits[124];
 build_d_tx_ceased_124bit(call_id, ssi, bkn1_bits);
 /* HALF_STEAL_SIG: BKN2=NULL (= vfill_blk2 wird vom burst_dispatcher
  * stattdessen genutzt, wenn vfill_valid_sys=1 → TCH-Voice-Half).
  * burst_dispatcher Logik (slot_mode==2 && vfill_valid_sys) gewinnt. */
 return tetra_facch_steal_stage(hal, voice_tn, SLOT_MODE_HALF_STEAL_SIG,
 bkn1_bits, NULL);
}

/* Override the slot_num=1 hardcode in tetra_facch_steal_stage:
 * for SCH/HD on a specific TN, scrambler slot_num should match the TDMA
 * slot of that TN (ETSI §8.2.5). Phase 3.1-fix 2026-05-23: was using
 * slot_num=1 (MCCH-convention from tetra_voice_filler.c) which gave SCH/HD
 * CRC-fails in decoder. Patched to voice_tn (= TDMA slot number, 0..3). */

