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
#include "tetra_call_fsm.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static uint32_t mono_ms_lo_vp(void)
{
 struct timespec ts;
 clock_gettime(CLOCK_MONOTONIC, &ts);
 return (uint32_t)((uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u);
}

/* 2026-05-25 — TS-Identifier aus dem hardware-gemessenen TS1→UL Air-Anchor.
 *
 * Bei jedem UL-Burst latched die FPGA-Stopuhr in REG_TS1_STOPWATCH_DELTA die
 * Cycles vom letzten DL-TS1-Modulator-Output bis zum UL nub-sync. Dieser
 * Wert ist deterministisch und hängt nur davon ab, in welchem UL-Timeslot
 * der MS gesendet hat (jeder UL-TS hat 14.17 ms Distanz zum nächsten):
 *
 *   UL TS1 → DELTA ≈ 50.84 ms  (DL-TS1-first-dibit + 3.59 TS Anchor)
 *   UL TS2 → DELTA ≈  9.0 ms   (50.84 - 56.67 + 14.17 = -27.5, wraps + 56.67)
 *
 * Im 56.67-ms TDMA-Frame nach jedem TS1-Puls landen die 4 UL-TS-Arrival-
 * Zeitpunkte bei modulo-56.67ms-Werten:
 *
 *   UL paired with DL TS1: DELTA ≈ 50.84 ms
 *   UL paired with DL TS2: DELTA ≈  8.50 ms   (50.84 + 14.17 - 56.67)
 *   UL paired with DL TS3: DELTA ≈ 22.67 ms
 *   UL paired with DL TS4: DELTA ≈ 36.84 ms
 *
 * Bei stabilem Bitstream-Pfad (cycles_per_ts und base_offset konstant)
 * mappen wir mit einem nearest-Center-Match. Tolerance ±7.1 ms = ±0.5 TS. */
#define CYCLES_PER_TS         1416667u   /* 14.166666 ms @ 100 MHz */
/* Gemessen 2026-05-25 @ voice_ts=TS2: TS1-Puls → UL-Burst nub-sync = 50.837 ms.
 * Daraus abgeleitet TS1-Puls → UL-TS1-Burst-Arrival = 50.837 − 14.167 = 36.670 ms.
 * Alle weiteren UL-TS um je +14.167 ms versetzt. */
#define TS1_TO_UL_TS1_OFFSET  3667032u   /* 36.670 ms — UL TS1 air-arrival */

static uint8_t compute_ul_air_ts(uint32_t delta_cycles)
{
 const uint32_t frame = 4u * CYCLES_PER_TS;   /* 5,666,668 cyc = 56.6667 ms */
 uint32_t rel = (delta_cycles + frame - (TS1_TO_UL_TS1_OFFSET % frame)) % frame;
 uint32_t ts_idx = (rel + CYCLES_PER_TS / 2u) / CYCLES_PER_TS;
 if (ts_idx >= 4u) ts_idx = 0u;
 return (uint8_t)(ts_idx + 1u); /* ETSI 1-based TS1..TS4 */
}

#define SCHF_CODED_BITS 432

/* Phase E2 (2026-05-18): mailbox now holds 432 × 4-bit signed soft-values
 * = 54 × 32-bit words. Each word holds 8 nibbles (LSB-first), corresponding
 * to coded_softs index Wn*8..Wn*8+7.
 *
 * Layout mapping (= identical to old hard-bit indexing):
 *   coded_softs[i] is the soft-value for coded-bit position i,
 *   coded_softs[431] = first BKN1 bit on air,
 *   coded_softs[0]   = last BKN2 bit.
 * type5[k] = coded_softs[431 - k] mapped to signed soft (sign-extended). */
#define SCHF_NUB_WORDS 54
#define SOFT_W_BITS    4

static void read_nub_softs(tetra_hal_t *hal, int8_t *softs_432_out)
{
 for (int w = 0; w < SCHF_NUB_WORDS; w++) {
 tetra_reg_write(hal, REG_VOICE_NUB_READ_INDEX, (uint32_t)w);
 uint32_t word = tetra_reg_read(hal, REG_VOICE_NUB_READ_DATA);
 int base = w * 8; /* 8 nibbles per 32-bit word */
 for (int n = 0; n < 8; n++) {
 uint32_t nib = (word >> (n * SOFT_W_BITS)) & 0xFu;
 /* Sign-extend 4-bit → int8 */
 int8_t s = (int8_t)((nib & 0x8) ? (int8_t)(nib | 0xF0) : (int8_t)nib);
 int coded_idx = base + n;
 if (coded_idx < SCHF_CODED_BITS)
 softs_432_out[431 - coded_idx] = s;
 }
 }
}

/* Helper: extract hard-bits from soft (for diff-diagnostic compatibility
 * with the existing per-burst FEC-Correction logging that compares the
 * decoded-and-re-encoded bits against the on-air bits). */
static void softs_to_hard(const int8_t *softs_432, uint8_t *hard_432_out)
{
 /* Per nub_capture-Konvention: positive soft = bit '1', negative = bit '0'.
  * Zero is an edge case — bit '0' (consistent with sign-bit MSB=0 → '0'). */
 for (int i = 0; i < SCHF_CODED_BITS; i++)
 hard_432_out[i] = (softs_432[i] > 0) ? 1u : 0u;
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

 /* Phase A (2026-05-25): UL air-TS-Identifikation aus Hardware-Stopuhr.
  * SW liest race-frei den FPGA-berechneten DELTA + Event-Count und mappt
  * auf ETSI TS1..TS4. Bei Single-TS-Call (voice_ts=TS2) sollte hier
  * konstant TS2 stehen — Sanity-Check für die Math vor Phase B. */
 static uint32_t s_last_evt_cnt = 0u;
 uint32_t evt_cnt = tetra_reg_read(hal, REG_TS1_STOPWATCH_EVT);
 if (evt_cnt != s_last_evt_cnt) {
 uint32_t delta = tetra_reg_read(hal, REG_TS1_STOPWATCH_DELTA);
 uint8_t ul_air_ts = compute_ul_air_ts(delta);
 static uint32_t s_log_div = 0u;
 if ((s_log_div++ & 0xF) == 0u) {
 fprintf(stderr,
 "voice_pipe: UL-air-TS=TS%u (DELTA=%u cyc = %.3f ms, evt_cnt=%u)\n",
 ul_air_ts, delta, (double)delta / 100000.0, evt_cnt);
 }
 s_last_evt_cnt = evt_cnt;
 }

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

 /* 1. Read UL on-air 432 × 4-bit signed soft-values (Phase E2). */
 int8_t softs_in[SCHF_CODED_BITS];
 read_nub_softs(hal, softs_in);

 /* SELF-TEST 2026-05-17 (BlueStation port): encode silence, decode, check BFI.
  * Tests both hard and soft paths produce identical-good results on clean input. */
 static int s_selftest_done = 0;
 if (!s_selftest_done) {
 s_selftest_done = 1;
 uint8_t silence[274] = {0};
 uint8_t test_bits[432];
 tetra_bs_tch_s_encode(silence, scramb_init, test_bits);
 uint8_t recovered_h[274];
 int bfi_h = tetra_bs_tch_s_decode(test_bits, scramb_init, recovered_h);
 int diff_h = 0;
 for (int i = 0; i < 274; i++) if (recovered_h[i] != silence[i]) diff_h++;
 /* Soft path: emulate "perfect channel" with full-magnitude softs.
  * Convention: bit 1 → soft +7, bit 0 → soft -7. */
 int8_t test_softs[432];
 for (int i = 0; i < 432; i++) test_softs[i] = test_bits[i] ? (int8_t)7 : (int8_t)-7;
 uint8_t recovered_s[274];
 int bfi_s = tetra_bs_tch_s_decode_softi8(test_softs, scramb_init, recovered_s);
 int diff_s = 0;
 for (int i = 0; i < 274; i++) if (recovered_s[i] != silence[i]) diff_s++;
 fprintf(stderr,
 "voice_pipe: SELFTEST hard{bfi=%d diff=%d} soft{bfi=%d diff=%d}\n",
 bfi_h, diff_h, bfi_s, diff_s);
 }

 /* Derive hard-bit view for downstream diagnose + re-encode-equivalent. */
 uint8_t type5_in[SCHF_CODED_BITS];
 softs_to_hard(softs_in, type5_in);

 /* DIAGNOSE 2026-05-18 — A/B-Test: zur Validierung des RTL→SW-Pfades
  * temporär auch Hard-Decode-Variante laufen lassen. Wenn HARD BFI
  * deutlich besser ist als SOFT, ist die Soft-Konvention oder die
  * RTL-Soft-Output-Quantisierung verkehrt. */
 uint8_t acelp_h[274];
 int bfi_h = tetra_bs_tch_s_decode(type5_in, scramb_init, acelp_h);
 (void)acelp_h;

 uint8_t acelp[274];
 int bfi = tetra_bs_tch_s_decode_softi8(softs_in, scramb_init, acelp);

 /* TIMING-DIAGNOSE (2026-05-20): erster erfolgreich dekodierter NUB-Burst
  *   → Hook in call_fsm, der einmalig pro Call die Latenz t0→voice loggt. */
 if (!bfi) {
 tetra_call_fsm_notify_first_nub(mono_ms_lo_vp());
 }

 /* Combine BFI count for A/B logging (s_bfi_h tracks hard, s_bfi soft). */
 static int s_bfi_h = 0;
 if (bfi_h) s_bfi_h++;
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

 /* Phase E2-Add (2026-05-19) — Signal-Quality-Proxy aus Soft-Magnituden.
  *   |soft| ∈ [0..7] pro Coded-Bit (4-bit signed Slice in nub_capture).
  *   Hohe |soft| = klares Symbol, niedrige = nahe Decision-Boundary.
  *   Mean-|soft| / (7 − mean-|soft|) liefert eine MER-Schätzung in linear-
  *   Skala; dB davon ergibt einen verwendbaren SNR/MER-Proxy.
  *   Werte > 14 dB = sehr klar, 8-14 dB = ok, < 6 dB = grenzwertig. */
 static uint32_t s_total_mag_sum = 0;
 static uint32_t s_total_mag_n = 0;
 uint32_t mag_sum_burst = 0;
 for (int i = 0; i < SCHF_CODED_BITS; i++) {
 int v = (int)softs_in[i];
 mag_sum_burst += (uint32_t)(v < 0 ? -v : v);
 }
 s_total_mag_sum += mag_sum_burst;
 s_total_mag_n   += (uint32_t)SCHF_CODED_BITS;

 if ((s_n & 0x07) == 0) {
 int avg_diff = (s_n - s_bfi) > 0 ? s_total_diff / (s_n - s_bfi) : 0;
 /* Avg-magnitude scaled ×100 to keep integer arithmetic precision. */
 uint32_t mag_avg_x100 = s_total_mag_n
   ? (s_total_mag_sum * 100u) / s_total_mag_n : 0;
 fprintf(stderr,
 "voice_pipe: t=%ums bursts=%d soft{bfi=%d %d%%} hard{bfi=%d %d%%} "
 "diff_avg=%d max=%d soft_mag=%u.%02u\n",
 mono_ms_lo_vp(), s_n,
 s_bfi, (s_bfi*100)/(s_n?s_n:1),
 s_bfi_h, (s_bfi_h*100)/(s_n?s_n:1),
 avg_diff, s_max_diff_burst,
 mag_avg_x100 / 100u, mag_avg_x100 % 100u);
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
