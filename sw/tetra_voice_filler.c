/*
 * tetra_voice_filler.c — Voice-Slot Filler (Phase A static-MAC-RESOURCE)
 *
 * SW-encoded SCH/F NULL-PDU addressed to the active group GSSI. Sent on
 * the voice-slot during an active group-call so the MS sees a valid
 * (CRC-OK, group-addressed) burst matching the AACH 0x32CB voice-call
 * allocation marker — necessary for the MS to keep PTT alive.
 *
 * Architecture: SW is the encoder (CRC + conv + interleave + scramble);
 * the RTL Voice-Filler-Mailbox is bit-pipe only. See
 * project_arch_fpga_thin_signaling.md.
 *
 * License: GPL v2
 */

#include "tetra_voice_filler.h"
#include "tetra_channel_codec.h"

#include <stdio.h>
#include <string.h>

#define SCHF_INFO_BITS 268
#define SCHF_CODED_BITS 432

/* ETSI EN 300 392-2 §21.4.3.1 Table 21.55 — MAC-RESOURCE DL header.
 * NULL/Filler PDU has length_indication = 62 (Table 21.56) and no TM-SDU.
 * Address-type = SSI (001), 24-bit SSI carries the group GSSI.
 * All three optional-element flags (PowerCtrl/SlotGrant/ChanAlloc) = 0.
 * Remaining 268-43 = 225 bits = pad (first fill bit = 1, rest 0). */
static void build_mac_resource_null_pdu(uint32_t group_gssi, uint8_t *info_268)
{
 int pos = 0;
 memset(info_268, 0, SCHF_INFO_BITS);

 /* PDUtype = 00 (MAC-RESOURCE) — 2 bits */
 info_268[pos++] = 0;
 info_268[pos++] = 0;
 /* FillBit = 0 — 1 bit (= no pad bytes after TM-SDU; for NULL-PDU
  *   the bluestation-compat ETSI fill convention uses the pad-bit
  *   marker below, not this field). */
 info_268[pos++] = 0;
 /* Position-of-grant = 0 — 1 bit */
 info_268[pos++] = 0;
 /* Encr = 00 (no encryption) — 2 bits */
 info_268[pos++] = 0;
 info_268[pos++] = 0;
 /* RandAccFlag = 0 (no RA-ack) — 1 bit */
 info_268[pos++] = 0;
 /* LengthInd = 62 (Filler / NULL-PDU) — 6 bits, MSB-first */
 uint8_t li = 62;
 for (int i = 5; i >= 0; i--)
 info_268[pos++] = (li >> i) & 1;
 /* AddrType = 001 (SSI) — 3 bits, MSB-first */
 info_268[pos++] = 0;
 info_268[pos++] = 0;
 info_268[pos++] = 1;
 /* SSI = 24-bit group address, MSB-first */
 for (int i = 23; i >= 0; i--)
 info_268[pos++] = (group_gssi >> i) & 1;
 /* PowerCtrl_flag = 0 */
 info_268[pos++] = 0;
 /* SlotGrant_flag = 0 */
 info_268[pos++] = 0;
 /* ChanAlloc_flag = 0 */
 info_268[pos++] = 0;
 /* pos = 43. Mark first fill bit = 1 (ETSI EN 300 392-2 §23.4.5
  *   pad convention used by bluestation MacResource::to_bitbuf),
  *   remainder stays 0 from memset. */
 info_268[pos++] = 1;
 /* rest = 0 already */
}

/* Pack 432 type-5 bits into 14 × 32-bit words such that
 * tetra_voice_filler_mailbox.v's slice
 *   blk1_sys = words_flat[215:0], blk2_sys = words_flat[431:216]
 * routed through tetra_burst_builder (which uses block1_data[BLOCK_BITS-1]
 * = first symbol on air, MSB-first) produces the correct on-air bit
 * order: type5[0] first.
 *
 *   BKN1 (type5[0..215]): type5[i] → bit position (215 - i) of words_flat
 *                         → blk1_sys[215-i] = type5[i]
 *                         → block1[215] = blk1_sys[215] = type5[0] ✓
 *   BKN2 (type5[216..431]): type5[216+i] → bit position (431 - i) of words_flat
 *                         → blk2_sys[215-i] = type5[216+i]
 *                         → block2[215] = blk2_sys[215] = type5[216] ✓
 */
static void pack_bits_mailbox(const uint8_t *type5_432, uint32_t *words_14)
{
 memset(words_14, 0, 14 * sizeof(uint32_t));
 for (int i = 0; i < 216; i++) {
 if (type5_432[i] & 1) {
 int dst = 215 - i;
 words_14[dst >> 5] |= (uint32_t)1u << (dst & 31);
 }
 }
 for (int i = 0; i < 216; i++) {
 if (type5_432[216 + i] & 1) {
 int dst = 431 - i;
 words_14[dst >> 5] |= (uint32_t)1u << (dst & 31);
 }
 }
}

int tetra_voice_filler_install(tetra_hal_t *hal, uint32_t group_gssi)
{
 if (hal == NULL || group_gssi == 0)
 return -1;

 /* Read cell parameters from RTL config registers. */
 uint8_t colour_code = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3F);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint16_t mcc = (uint16_t)(cfg1 & 0x3FF);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFF);

 uint8_t info[SCHF_INFO_BITS];
 build_mac_resource_null_pdu(group_gssi & 0x00FFFFFFu, info);

 uint8_t type5[SCHF_CODED_BITS];
 /* slot_num = 1 (= MCCH-slot scramble seed; matches the existing
  *   bluestation/RTL DL convention for SCH/F bursts). */
 if (tetra_codec_schf_encode(info, colour_code, 1, mcc, mnc, type5) != 0) {
 fprintf(stderr,
 "tetra_voice_filler: tetra_codec_schf_encode failed\n");
 return -1;
 }

 uint32_t words[14];
 pack_bits_mailbox(type5, words);

 /* AXI write: indirect 16-word mailbox. For each word index 0..13:
  *   1. write INDEX = i
  *   2. write DATA = words[i]
  *   The W1S handshake on the indirect_mailbox_wr commits both. */
 for (int i = 0; i < 14; i++) {
 tetra_reg_write(hal, REG_VOICE_FILLER_INDEX, (uint32_t)i);
 tetra_reg_write(hal, REG_VOICE_FILLER_DATA, words[i]);
 }
 /* W14[0] = 1 → filler_valid. */
 tetra_reg_write(hal, REG_VOICE_FILLER_INDEX, 14u);
 tetra_reg_write(hal, REG_VOICE_FILLER_DATA, 0x00000001u);
 /* GO pulse — currently informational only (dispatcher reads
  *   blk1/blk2/valid combinationally), kept for symmetry with the
  *   Reply-Pull mailbox handshake and future FSM extensions. */
 tetra_reg_write(hal, REG_VOICE_FILLER_GO, 0x1u);

 fprintf(stderr,
 "tetra_voice_filler: installed gssi=0x%06X cc=%u mcc=%u mnc=%u\n",
 group_gssi & 0x00FFFFFFu, colour_code, mcc, mnc);
 return 0;
}

void tetra_voice_filler_clear(tetra_hal_t *hal)
{
 if (hal == NULL) return;
 tetra_reg_write(hal, REG_VOICE_FILLER_INDEX, 14u);
 tetra_reg_write(hal, REG_VOICE_FILLER_DATA, 0x00000000u);
 fprintf(stderr, "tetra_voice_filler: cleared\n");
}
