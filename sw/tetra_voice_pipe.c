/*
 * tetra_voice_pipe.c — Phase B: UL→DL Voice-Bit-Pipe with MAC-addr-Patch
 *
 * SW-resident voice pipeline. Reads UL-NUB-bits from RTL mailbox, runs full
 * SCH/F decode (descramble + deinterleave + depuncture + Viterbi + CRC),
 * patches the 24-bit MAC-RESOURCE SSI to the call target, re-encodes and
 * writes back to the DL Voice-Filler-Mailbox. TCH/S ACELP voice bursts
 * (no MAC-header / CRC fail) are passed through 1:1.
 *
 * Architecture: RTL is bit-pipe only (read-mailbox + write-mailbox + slot-
 * routing). Codec runs in SW per project_arch_fpga_thin_signaling.md.
 *
 * License: GPL v2
 */

#include "tetra_voice_pipe.h"
#include "tetra_bs_tch_s.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static uint32_t mono_ms_lo_vp(void)
{
 struct timespec ts;
 clock_gettime(CLOCK_MONOTONIC, &ts);
 return (uint32_t)((uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u);
}

#define SCHF_CODED_BITS 432

/* Read 432 type-5 bits out of REG_VOICE_NUB_READ_DATA via INDEX 0..13.
 *
 * RTL coded_bits_sys convention (tetra_ul_nub_capture.v):
 *   coded_bits[431] = first BKN1 bit on air, coded_bits[0] = last BKN2 bit.
 * BS-Codec convention (tetra_bs_tch_s_decode):
 *   type5[0] = first transmitted bit, type5[431] = last transmitted bit.
 *
 * So mailbox bit i (= coded_bits[i]) maps to type5[431 - i]. */
static void read_nub_bits(tetra_hal_t *hal, uint8_t *type5_out_432)
{
 for (int w = 0; w < 14; w++) {
 tetra_reg_write(hal, REG_VOICE_NUB_READ_INDEX, (uint32_t)w);
 uint32_t word = tetra_reg_read(hal, REG_VOICE_NUB_READ_DATA);
 int base = w * 32;
 int n = (w == 13) ? 16 : 32; /* W13 holds bits 416..431 */
 for (int b = 0; b < n; b++)
 type5_out_432[431 - (base + b)] = (uint8_t)((word >> b) & 1u);
 }
}

/* Pack 432 type-5 bits into 14 words for the DL filler-mailbox using the
 * same convention as tetra_voice_filler.c::pack_bits_mailbox:
 *   BKN1 (i=0..215): type5[i] → bit position (215 - i)
 *   BKN2 (i=216..431): type5[i] → bit position (431 - (i-216)) = (647 - i)
 * Ensures block1[215]/block2[215] = first symbol on air. */
static void pack_filler_mailbox_words(const uint8_t *type5_432, uint32_t *words_14)
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

/* Write 14 packed words into the DL filler mailbox, set valid (W14[0]=1)
 * and pulse GO. */
static void write_filler_mailbox(tetra_hal_t *hal, const uint32_t *words_14)
{
 for (int i = 0; i < 14; i++) {
 tetra_reg_write(hal, REG_VOICE_FILLER_INDEX, (uint32_t)i);
 tetra_reg_write(hal, REG_VOICE_FILLER_DATA, words_14[i]);
 }
 tetra_reg_write(hal, REG_VOICE_FILLER_INDEX, 14u);
 tetra_reg_write(hal, REG_VOICE_FILLER_DATA, 0x00000001u);
 tetra_reg_write(hal, REG_VOICE_FILLER_GO, 0x1u);
}

int tetra_voice_pipe_tick(tetra_hal_t *hal, uint32_t target_ssi)
{
 if (hal == NULL) return -1;
 (void)target_ssi;

 if ((tetra_reg_read(hal, REG_VOICE_NUB_READ_STATUS) & 0x1u) == 0u)
 return 0; /* No burst pending */

 /* ETSI EN 300 395-2 §8.5 — full TCH/S decode + re-encode on BS:
  *   UL air → descramble → block-deinterleave → RCPC-decode → ACELP-274
  *   ACELP-274 → RCPC-encode → block-interleave → scramble → DL air
  * Removes UL bit errors via FEC, regenerates clean type-5 bits for DL. */

 /* Cell-scrambler init: same LFSR seed for UL/DL. */
 uint8_t cc = (uint8_t)(tetra_reg_read(hal, REG_COLOUR_CODE) & 0x3F);
 uint32_t cfg1 = tetra_reg_read(hal, REG_CELL_CFG_1);
 uint16_t mcc = (uint16_t)(cfg1 & 0x3FF);
 uint16_t mnc = (uint16_t)((cfg1 >> 10) & 0x3FFF);
 uint32_t scramb_init = ((uint32_t)(mcc & 0x3FF) << 22)
 | ((uint32_t)(mnc & 0x3FFF) << 8)
 | ((uint32_t)(cc & 0x3F) << 2)
 | 3u;

 /* 1. Read UL on-air 432 type-5 bits */
 uint8_t type5_in[SCHF_CODED_BITS];
 read_nub_bits(hal, type5_in);

 /* SELF-TEST 2026-05-17 (BlueStation port): encode silence, decode, check BFI. */
 static int s_selftest_done = 0;
 if (!s_selftest_done) {
 s_selftest_done = 1;
 uint8_t silence[274] = {0};
 uint8_t test_bits[432];
 tetra_bs_tch_s_encode(silence, scramb_init, test_bits);
 uint8_t recovered[274];
 int test_bfi = tetra_bs_tch_s_decode(test_bits, scramb_init, recovered);
 int diff = 0;
 for (int i = 0; i < 274; i++) if (recovered[i] != silence[i]) diff++;
 fprintf(stderr, "voice_pipe: BS-SELFTEST encode→decode silence → bfi=%d diff_bits=%d\n",
 test_bfi, diff);
 }

 uint8_t acelp[274];
 int bfi = tetra_bs_tch_s_decode(type5_in, scramb_init, acelp);
 static int s_n = 0;
 static int s_bfi = 0;
 s_n++;
 if (bfi) s_bfi++;

 /* 3. ETSI TCH/S re-encode → 432 clean type-5 bits for DL. */
 uint8_t type5_out[SCHF_CODED_BITS];
 tetra_bs_tch_s_encode(acelp, scramb_init, type5_out);

 /* DIAGNOSE 2026-05-17 — per-burst FEC-Correction-Count.
  *   type5_out (re-encoded clean Bits) vs type5_in (raw on-air, mit
  *   evtl. Bit-Errors): diff_bits = von Viterbi/RCPC korrigierte Bits.
  *   diff_bits sagt uns:
  *   - "Roh-BER" (Air-quality) — unabhängig von BFI-binary
  *   - WO im Burst (BKN1 vs BKN2 vs Edges) Fehler clustern
  *   Position-Histogram über Bursts hinweg verrät Sample-Offset-Drift,
  *   Phase-Drift, Edge-Bit-Probleme, etc. */
 static uint32_t s_pos_flips[SCHF_CODED_BITS] = {0};
 static int s_total_diff = 0;
 static int s_max_diff_burst = 0;
 int diff_bits = 0;
 if (!bfi) { /* only meaningful when decoder succeeded */
 for (int i = 0; i < SCHF_CODED_BITS; i++) {
 if ((type5_in[i] & 1) != (type5_out[i] & 1)) {
 diff_bits++;
 s_pos_flips[i]++;
 }
 }
 s_total_diff += diff_bits;
 if (diff_bits > s_max_diff_burst) s_max_diff_burst = diff_bits;
 }

 if ((s_n & 0x07) == 0) {
 int avg_diff = (s_n - s_bfi) > 0 ? s_total_diff / (s_n - s_bfi) : 0;
 fprintf(stderr,
 "voice_pipe: t=%ums bursts=%d bfi_fail=%d (= %d%%) "
 "diff_avg=%d max=%d\n",
 mono_ms_lo_vp(), s_n, s_bfi, (s_bfi*100)/(s_n?s_n:1),
 avg_diff, s_max_diff_burst);
 }

 /* Alle 64 Bursts: erweiterte Diagnose:
  *   - TOP20 Bit-Positionen mit den meisten Flips (statt nur TOP5)
  *   - 16-Bucket-Histogram (je 27 bits) → räumliche Verteilung
  *   - Anzahl Positionen die JE geflipped (= Spread vs Konzentration)
  *   - Per-BKN-Anteil (BKN2=pos 0-215, BKN1=pos 216-431) */
 if ((s_n & 0x3F) == 0) {
 /* TOP20 */
 int top_idx[20] = {0};
 uint32_t top_cnt[20] = {0};
 for (int i = 0; i < SCHF_CODED_BITS; i++) {
 uint32_t c = s_pos_flips[i];
 for (int k = 0; k < 20; k++) {
 if (c > top_cnt[k]) {
 for (int j = 19; j > k; j--) {
 top_cnt[j] = top_cnt[j-1];
 top_idx[j] = top_idx[j-1];
 }
 top_cnt[k] = c;
 top_idx[k] = i;
 break;
 }
 }
 }
 fprintf(stderr, "voice_pipe: TOP20-flip");
 for (int k = 0; k < 20; k++) {
 fprintf(stderr, " %d[%u]", top_idx[k], top_cnt[k]);
 }
 fprintf(stderr, "\n");

 /* 16-Bucket-Histogram je 27 bits */
 uint32_t bucket[16] = {0};
 int unique = 0;
 uint32_t bkn1_flips = 0, bkn2_flips = 0;
 for (int i = 0; i < SCHF_CODED_BITS; i++) {
 uint32_t c = s_pos_flips[i];
 bucket[i / 27] += c;
 if (c > 0) unique++;
 if (i < 216) bkn2_flips += c; else bkn1_flips += c;
 }
 fprintf(stderr, "voice_pipe: BUCKETS(27bit each)");
 for (int b = 0; b < 16; b++) {
 fprintf(stderr, " %u", bucket[b]);
 }
 fprintf(stderr, "\n");
 fprintf(stderr,
 "voice_pipe: SPREAD unique=%d/%d BKN2=%u BKN1=%u (BKN2_pct=%d%%)\n",
 unique, SCHF_CODED_BITS, bkn2_flips, bkn1_flips,
 (bkn2_flips + bkn1_flips) > 0
 ? (int)((bkn2_flips * 100) / (bkn2_flips + bkn1_flips))
 : 0);
 }

 /* 4. Pack and write to filler mailbox. */
 uint32_t words[14];
 pack_filler_mailbox_words(type5_out, words);
 write_filler_mailbox(hal, words);

 /* 5. Acknowledge UL mailbox. */
 tetra_reg_write(hal, REG_VOICE_NUB_READ_ACK, 0x1u);

 return 0;
}
