/*
 * test_soft_viterbi.c — Pre-Test for Option E2 (soft-decisions @ NUB-Capture)
 *
 * Goal: validate that the existing Viterbi in tetra_bs_tch_s.c actually
 * benefits from soft input (vs the current ±1-only path) BEFORE we touch
 * any RTL. If this test shows no measurable BFI/diff gain, the dB-promise
 * is hollow and we save ~1 day of RTL work.
 *
 * Method:
 *   1. Random ACELP-bits → encode → 432 clean type-5 bits.
 *   2. Channel-simulate AWGN: for each bit, ±1 BPSK + Gaussian noise.
 *   3. Quantize received value to:
 *      - HARD: sign() → 0/1 → feed existing tetra_bs_tch_s_decode().
 *      - SOFT: round(rx * SCALE), clamp to int8 range → feed
 *              tetra_bs_tch_s_decode_softi8().
 *   4. Run N trials per SNR, count BFI (CRC-fail) and Hamming-distance
 *      between recovered and original ACELP.
 *
 * Run:  gcc -O2 sw/test_soft_viterbi.c sw/tetra_bs_tch_s.c sw/tetra_tch_s_codec.c -lm -o /tmp/test_soft && /tmp/test_soft
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#include "tetra_bs_tch_s.h"

/* Box-Muller — generate standard normal. */
static double randn(void)
{
 static int has_spare = 0;
 static double spare;
 if (has_spare) { has_spare = 0; return spare; }
 double u, v, s;
 do {
 u = (double)rand() / RAND_MAX * 2.0 - 1.0;
 v = (double)rand() / RAND_MAX * 2.0 - 1.0;
 s = u*u + v*v;
 } while (s >= 1.0 || s == 0.0);
 s = sqrt(-2.0 * log(s) / s);
 spare = v * s;
 has_spare = 1;
 return u * s;
}

int main(int argc, char **argv)
{
 const int N_TRIALS = (argc > 1) ? atoi(argv[1]) : 200;
 const uint32_t scramb_init = 0x12345678u;

 /* Test multiple soft-quantization scales to find the sweet spot.
  * SCALE maps the "ideal" received value (±1) to int8 magnitude X.
  * SCALE=1 → ±1 (≈ hard) ; SCALE=3 → ±3 ; SCALE=7 → 4-bit; SCALE=64 → 7-bit. */
 const int SCALES[] = {1, 2, 3, 4, 7, 15, 64};
 const int N_SCALES = sizeof(SCALES)/sizeof(SCALES[0]);

 /* SNRs in dB (energy-per-bit / N0). For BPSK in AWGN, sigma² = 1/(2·SNR). */
 const double snrs_db[] = {3.0, 4.0, 5.0, 6.0, 7.0, 8.0};
 const int N_SNR = sizeof(snrs_db)/sizeof(snrs_db[0]);

 srand(42);

 printf("Soft-Viterbi Pre-Test — N_TRIALS=%d per cell\n", N_TRIALS);
 printf("Random ACELP → encode → AWGN → quantize → decode → measure BFI/diff\n\n");
 printf("Reading:  HARD ⟶ existing path (input is uint8 0/1).\n");
 printf("          SOFT(S) ⟶ new path with soft-magnitude clipped to ±S.\n\n");

 printf("        |         HARD          |");
 for (int s = 0; s < N_SCALES; s++) printf("    SOFT(±%-3d)      |", SCALES[s]);
 printf("\n");
 printf("  SNR   | BFI/N    diff (bits)  |");
 for (int s = 0; s < N_SCALES; s++) printf("  BFI/N    diff      |");
 printf("\n");
 printf("--------+-----------------------+");
 for (int s = 0; s < N_SCALES; s++) printf("---------------------+");
 printf("\n");

 for (int snr_idx = 0; snr_idx < N_SNR; snr_idx++) {
 double snr_db = snrs_db[snr_idx];
 double snr_lin = pow(10.0, snr_db / 10.0);
 double sigma = sqrt(1.0 / (2.0 * snr_lin));

 int hard_bfi = 0, hard_diff = 0;
 int soft_bfi[N_SCALES], soft_diff[N_SCALES];
 for (int s = 0; s < N_SCALES; s++) { soft_bfi[s] = 0; soft_diff[s] = 0; }

 for (int trial = 0; trial < N_TRIALS; trial++) {
 uint8_t acelp_in[274];
 for (int i = 0; i < 274; i++) acelp_in[i] = (uint8_t)(rand() & 1);

 uint8_t type5_clean[432];
 tetra_bs_tch_s_encode(acelp_in, scramb_init, type5_clean);

 /* AWGN channel — store noisy received values, quantize per scale below. */
 double rx[432];
 for (int i = 0; i < 432; i++) {
 double sym = type5_clean[i] ? 1.0 : -1.0;
 rx[i] = sym + sigma * randn();
 }

 /* HARD path */
 uint8_t hard_bits[432];
 for (int i = 0; i < 432; i++) hard_bits[i] = (rx[i] >= 0.0) ? 1u : 0u;
 uint8_t acelp_h[274];
 int rc_h = tetra_bs_tch_s_decode(hard_bits, scramb_init, acelp_h);
 if (rc_h < 0) hard_bfi++;
 for (int i = 0; i < 274; i++) if (acelp_h[i] != acelp_in[i]) hard_diff++;

 /* SOFT path — try multiple quantization scales */
 for (int s = 0; s < N_SCALES; s++) {
 int scale = SCALES[s];
 int8_t soft_in[432];
 for (int i = 0; i < 432; i++) {
 int q = (int)lround(rx[i] * (double)scale);
 if (q > 127) q = 127;
 if (q < -127) q = -127; /* avoid INT8_MIN edge */
 soft_in[i] = (int8_t)q;
 }
 uint8_t acelp_s[274];
 int rc_s = tetra_bs_tch_s_decode_softi8(soft_in, scramb_init, acelp_s);
 if (rc_s < 0) soft_bfi[s]++;
 for (int i = 0; i < 274; i++) if (acelp_s[i] != acelp_in[i]) soft_diff[s]++;
 }
 }

 printf(" %4.1f   |  %3d/%-4d  %6d     |",
 snr_db, hard_bfi, N_TRIALS, hard_diff);
 for (int s = 0; s < N_SCALES; s++) {
 printf("  %3d/%-4d  %5d     |",
 soft_bfi[s], N_TRIALS, soft_diff[s]);
 }
 printf("\n");
 }

 printf("\nInterpretation:\n");
 printf("  - HARD vs SOFT(±1) should be ~identical (both effectively binary).\n");
 printf("  - SOFT(±3..±7) should show lower BFI/diff at the marginal SNRs (~3-5 dB).\n");
 printf("  - Above ±7 → diminishing returns (theoretical cap).\n");
 printf("  - If SOFT shows NO measurable improvement, the Viterbi isn't actually\n");
 printf("    soft-aware in a useful way — STOP before touching RTL.\n");

 return 0;
}
