/*
 * tetra_bs_tch_s.c — TCH/S Codec ported from BlueStation Rust → C
 *
 * Source: tetra-bluestation/crates/tetra-entities/src/lmac/components/
 * Bit-exact ETSI EN 300 395-2 §5.4/§5.5 (TCH/S Channel Coding)
 *
 * Key difference vs tetra-kit (which our previous wrapper used):
 *   - Speech rate-1/3 conv encoder runs CONTINUOUSLY across Class 1 + Class 2
 *     (single 184-bit input stream → 552 mother bits, single Viterbi decode)
 *   - tetra-kit's Rcpc_Coding/Decoding splits into 2 separate streams
 *     → bit-output differs from ETSI → MS can't decode our re-encoded bursts
 *
 * License: GPL v2.
 */

#include "tetra_bs_tch_s.h"
#include "tetra_tch_s_codec.h"  /* reuse outer-layer: scrambler + block-interleave */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* ========================================================================
 * tch_reorder: channel-order ↔ codec-order (ETSI EN 300 395-2 Table 4)
 * Each class is interleaved between the 2 ACELP subframes.
 * ======================================================================== */

#define ACELP_BITS 137

static const uint8_t CLASS0_POS[51] = {
 35,36,37,38,39,40,41,42,43, 47,48, 56, 61,62,63,64,65,66,67,68,69,70,
 74,75, 83, 88,89,90,91,92,93,94,95, 96,97, 101,102, 110,115,116,117,118,
 119,120,121,122,123,124, 128,129, 137
};

static const uint8_t CLASS1_POS[56] = {
 58,85,112, 54,81,108,135, 50,77, 104,131, 45,72,99,126, 55,82,109,
 136, 5,13,34, 8,16,17, 22,23,24, 25,26, 6,14,7,15, 60,87,114, 46,
 73,100,127, 44,71,98,125, 33,49, 76,103,130, 59,86,113, 57,84,111
};

static const uint8_t CLASS2_POS[30] = {
 18,19,20,21, 31,32, 53,80,107,134, 1,2,3,4, 9,10,11,12,
 27,28,29,30, 52,79,106,133, 51,78,105,132
};

static void codec_to_channel(const uint8_t codec[274], uint8_t channel[274])
{
 int out = 0;
 for (int i = 0; i < 51; i++) {
 int pos = CLASS0_POS[i] - 1;
 channel[out++] = codec[pos];
 channel[out++] = codec[ACELP_BITS + pos];
 }
 for (int i = 0; i < 56; i++) {
 int pos = CLASS1_POS[i] - 1;
 channel[out++] = codec[pos];
 channel[out++] = codec[ACELP_BITS + pos];
 }
 for (int i = 0; i < 30; i++) {
 int pos = CLASS2_POS[i] - 1;
 channel[out++] = codec[pos];
 channel[out++] = codec[ACELP_BITS + pos];
 }
}

static void channel_to_codec(const uint8_t channel[274], uint8_t codec[274])
{
 int in = 0;
 for (int i = 0; i < 51; i++) {
 int pos = CLASS0_POS[i] - 1;
 codec[pos] = channel[in++];
 codec[ACELP_BITS + pos] = channel[in++];
 }
 for (int i = 0; i < 56; i++) {
 int pos = CLASS1_POS[i] - 1;
 codec[pos] = channel[in++];
 codec[ACELP_BITS + pos] = channel[in++];
 }
 for (int i = 0; i < 30; i++) {
 int pos = CLASS2_POS[i] - 1;
 codec[pos] = channel[in++];
 codec[ACELP_BITS + pos] = channel[in++];
 }
}

/* ========================================================================
 * Speech CRC: 8-bit CRC over 60 Class 2 bits (ETSI EN 300 395-2 §5.5.1)
 * G(X) = 1 + X³ + X⁷
 * Returns 7 parity bits + 1 overall parity bit.
 * ======================================================================== */

static void speech_crc(const uint8_t class2_60[60], uint8_t crc_out[8])
{
 uint8_t w[67] = {0};
 for (int k = 0; k < 60; k++)
 w[k + 7] = class2_60[k] & 1;

 for (int d = 66; d >= 7; d--) {
 if (w[d] == 1) {
 w[d] ^= 1;
 w[d - 4] ^= 1;
 w[d - 7] ^= 1;
 }
 }

 for (int i = 0; i < 7; i++)
 crc_out[i] = w[i];

 uint8_t parity = 0;
 for (int i = 0; i < 60; i++) parity ^= class2_60[i] & 1;
 for (int i = 0; i < 7; i++) parity ^= crc_out[i];
 crc_out[7] = parity;
}

/* ========================================================================
 * Speech rate-1/3 conv encoder (ETSI EN 300 395-2 §5.4.3.1)
 * G1 = 1+D+D²+D³+D⁴, G2 = 1+D+D³+D⁴, G3 = 1+D²+D⁴
 * State is 4 bits (= 16 states with K=5)
 * ======================================================================== */

typedef struct {
 uint8_t d[4];  /* delay line, d[0] = most recent */
} speech_conv_state_t;

static void speech_conv_init(speech_conv_state_t *st)
{
 memset(st->d, 0, 4);
}

/* Encode 1 input bit → 3 output bits (G1, G2, G3) */
static void speech_conv_encode_bit(speech_conv_state_t *st, uint8_t bit, uint8_t out[3])
{
 uint8_t d0 = st->d[0], d1 = st->d[1], d2 = st->d[2], d3 = st->d[3];
 out[0] = bit ^ d0 ^ d1 ^ d2 ^ d3;  /* G1 = 1+D+D²+D³+D⁴ */
 out[1] = bit ^ d0 ^ d2 ^ d3;       /* G2 = 1+D+D³+D⁴ */
 out[2] = bit ^ d1 ^ d3;            /* G3 = 1+D²+D⁴ */
 st->d[3] = d2;
 st->d[2] = d1;
 st->d[1] = d0;
 st->d[0] = bit;
}

/* Encode n input bits → 3n output bits. State continues across calls. */
static void speech_conv_encode(speech_conv_state_t *st,
 const uint8_t *input, int n, uint8_t *output)
{
 for (int i = 0; i < n; i++) {
 speech_conv_encode_bit(st, input[i], &output[i * 3]);
 }
}

/* ========================================================================
 * RCPC puncture/depuncture (BlueStation port)
 * ======================================================================== */

typedef struct {
 const uint32_t *p;
 int p_len;
 uint32_t t;
 uint32_t period;
} puncturer_t;

static const uint32_t P_RATE112_168[] = {0, 1, 2, 4};
static const uint32_t P_RATE72_162[]  = {0, 1, 2, 3, 4, 5, 7, 8, 10, 11};

static const puncturer_t PUNCT_RATE112_168 = {
 .p = P_RATE112_168, .p_len = 4, .t = 3, .period = 6
};
static const puncturer_t PUNCT_RATE72_162 = {
 .p = P_RATE72_162, .p_len = 10, .t = 9, .period = 12
};

/* Puncture: input mother-code bits → output (subset) */
static void rcpc_punct(const puncturer_t *pu, const uint8_t *input, uint8_t *output, int out_len)
{
 for (uint32_t j = 1; (int)j <= out_len; j++) {
 uint32_t i = j;
 uint32_t blk = (i - 1) / pu->t;
 uint32_t idx = i - pu->t * blk;  /* 1..t */
 uint32_t k = pu->period * blk + pu->p[idx];
 output[j - 1] = input[k - 1];
 }
}

/* De-puncture: input punctured bits → output mother-code bits with erasures (0xFF) */
static void rcpc_depunct(const puncturer_t *pu, const uint8_t *input, int input_len, uint8_t *output, int output_len)
{
 /* Initialize all to erasure */
 for (int i = 0; i < output_len; i++) output[i] = 0xFF;

 for (uint32_t j = 1; (int)j <= input_len; j++) {
 uint32_t i = j;
 uint32_t blk = (i - 1) / pu->t;
 uint32_t idx = i - pu->t * blk;
 uint32_t k = pu->period * blk + pu->p[idx];
 if ((int)k - 1 < output_len)
 output[k - 1] = input[j - 1];
 }
}

/* ========================================================================
 * Rate-1/3 Viterbi decoder for TETRA speech (K=5, 16 states)
 * Generators: G1=11111, G2=11011, G3=10101
 * Soft bits: 0 = puncture (erasure), -1 = strong '0', +1 = strong '1'
 * ======================================================================== */

#define NUM_STATES 16
#define K_LEN 5
#define N_OUT 3  /* rate 1/3 */

typedef int8_t soft_bit_t;
typedef int16_t metric_t;

/* expected_0[poly_n][state] = expected output for input "0" given state.
 * +1 for expected "1", -1 for expected "0". */
static int8_t s_expected_0[N_OUT][NUM_STATES];
static int s_viterbi_init = 0;

/* Generator polynomials (true/false per K-bit pattern, MSB-first) */
static const int s_speech_polys[N_OUT][K_LEN] = {
 {1, 1, 1, 1, 1},  /* G1 */
 {1, 1, 0, 1, 1},  /* G2 */
 {1, 0, 1, 0, 1},  /* G3 */
};

static void viterbi_init(void)
{
 if (s_viterbi_init) return;
 s_viterbi_init = 1;
 for (int n = 0; n < N_OUT; n++) {
 for (int state = 0; state < NUM_STATES; state++) {
 int out = 0;
 for (int bi = 0; bi < K_LEN - 1; bi++) {
 int past_bit = (state & (1 << (K_LEN - 2 - bi))) != 0;
 if (past_bit && s_speech_polys[n][bi]) {
 out ^= 1;
 }
 }
 s_expected_0[n][state] = out ? 1 : -1;
 }
 }
}

/* Decode mother_bits (length = num_output_bits * 3) → output_bits (length = num_output_bits).
 * mother_bits[i] is soft: -1 = '0', +1 = '1', 0 = erasure. */
static void viterbi_decode(const soft_bit_t *mother_bits, int num_output_bits, uint8_t *output_bits)
{
 viterbi_init();

 metric_t metrics[NUM_STATES];
 metric_t metrics_new[NUM_STATES];
 uint16_t *trellis = (uint16_t *)calloc(num_output_bits, sizeof(uint16_t));
 if (!trellis) return;

 /* Initial metrics: state 0 favored */
 for (int s = 0; s < NUM_STATES; s++) metrics[s] = INT16_MAX / 2;
 metrics[0] = 0;

 for (int step = 0; step < num_output_bits; step++) {
 metric_t branch_metric_0[NUM_STATES];
 for (int s = 0; s < NUM_STATES; s++) branch_metric_0[s] = 0;

 /* Branch metric: sum of -(received * expected_0) over N_OUT */
 for (int n = 0; n < N_OUT; n++) {
 soft_bit_t recv = mother_bits[step * N_OUT + n];
 for (int s = 0; s < NUM_STATES; s++) {
 branch_metric_0[s] -= (metric_t)recv * s_expected_0[n][s];
 }
 }

 uint16_t decisions = 0;
 for (int state = 0; state < NUM_STATES; state++) {
 int pred_0 = (state * 2) % NUM_STATES;
 int pred_1 = pred_0 + 1;
 metric_t m0 = metrics[pred_0] + branch_metric_0[state];
 /* For input "1", expected is inverse of input "0" → metric is negated */
 metric_t m1 = metrics[pred_1] - branch_metric_0[state];
 if (m1 < m0) {
 decisions |= (1u << state);
 metrics_new[state] = m1;
 } else {
 metrics_new[state] = m0;
 }
 }
 memcpy(metrics, metrics_new, sizeof(metrics));
 trellis[step] = decisions;
 }

 /* Traceback from state 0 */
 int state = 0;
 for (int step = num_output_bits - 1; step >= 0; step--) {
 output_bits[step] = (state >> (K_LEN - 2)) & 1;
 state = (state * 2) % NUM_STATES + ((trellis[step] >> state) & 1);
 }

 free(trellis);
}

/* ========================================================================
 * decode_tp / encode_tp: top-level TCH/S encode + decode (BlueStation match)
 * ======================================================================== */

#define CLASS0_BITS 102
#define CLASS1_BITS 112
#define CLASS2_BITS 60
#define CLASS2_TYPE2 72   /* 60 data + 8 CRC + 4 tail */
#define CLASS1_TYPE3 168  /* punctured Class 1 */
#define CLASS2_TYPE3 162  /* punctured Class 2 */

int tetra_bs_tch_s_decode(const uint8_t type5_432[432],
 uint32_t scramb_init,
 uint8_t acelp_274[274])
{
 /* 1. Descramble (in-place on a copy) */
 uint8_t type4[432];
 memcpy(type4, type5_432, 432);
 tetra_tch_s_scramble(type4, scramb_init);

 /* 2. Matrix de-interleave 24×18 */
 uint8_t type3[432];
 tetra_tch_s_deinterleave_speech(type4, type3);

 /* 3. Split: Class 0 unprotected, Class 1 + Class 2 RCPC-coded */
 uint8_t type1_arr[274];
 memcpy(type1_arr, type3, CLASS0_BITS); /* Class 0 direct */

 /* 4. De-puncture Class 1 (168 → 336 mother bits) */
 uint8_t mother_class1[CLASS1_BITS * 3];
 rcpc_depunct(&PUNCT_RATE112_168, &type3[CLASS0_BITS], CLASS1_TYPE3,
 mother_class1, CLASS1_BITS * 3);

 /* 5. De-puncture Class 2 (162 → 216 mother bits) */
 uint8_t mother_class2[CLASS2_TYPE2 * 3];
 rcpc_depunct(&PUNCT_RATE72_162, &type3[CLASS0_BITS + CLASS1_TYPE3], CLASS2_TYPE3,
 mother_class2, CLASS2_TYPE2 * 3);

 /* 6. Concatenate mother bits (Class 1: 336 + Class 2: 216 = 552) */
 uint8_t combined_mother[(CLASS1_BITS + CLASS2_TYPE2) * 3];
 memcpy(combined_mother, mother_class1, CLASS1_BITS * 3);
 memcpy(combined_mother + CLASS1_BITS * 3, mother_class2, CLASS2_TYPE2 * 3);

 /* 7. Convert to soft bits: 0 → -1, 1 → +1, 0xFF → 0 (erasure) */
 soft_bit_t soft[(CLASS1_BITS + CLASS2_TYPE2) * 3];
 for (int i = 0; i < (int)(sizeof(combined_mother)); i++) {
 if (combined_mother[i] == 0x00) soft[i] = -1;
 else if (combined_mother[i] == 0x01) soft[i] = 1;
 else soft[i] = 0;
 }

 /* 8. Viterbi decode: 552 soft → 184 bits (= Class 1 112 + Class 2 72) */
 uint8_t decoded[CLASS1_BITS + CLASS2_TYPE2];
 viterbi_decode(soft, CLASS1_BITS + CLASS2_TYPE2, decoded);

 /* 9. Extract Class 1 + Class 2 */
 memcpy(&type1_arr[CLASS0_BITS], decoded, CLASS1_BITS);
 const uint8_t *class2_decoded = &decoded[CLASS1_BITS];
 const uint8_t *class2_data = class2_decoded;
 const uint8_t *received_crc = &class2_decoded[CLASS2_BITS];

 /* 10. CRC check */
 uint8_t expected_crc[8];
 speech_crc(class2_data, expected_crc);
 int crc_ok = 1;
 for (int i = 0; i < 8; i++) {
 if (expected_crc[i] != received_crc[i]) { crc_ok = 0; break; }
 }
 memcpy(&type1_arr[CLASS0_BITS + CLASS1_BITS], class2_data, CLASS2_BITS);

 /* 11. channel → codec reorder */
 channel_to_codec(type1_arr, acelp_274);

 return crc_ok ? 0 : -1;
}

int tetra_bs_tch_s_encode(const uint8_t acelp_274[274],
 uint32_t scramb_init,
 uint8_t type5_out_432[432])
{
 /* 1. codec → channel reorder */
 uint8_t type1_arr[274];
 codec_to_channel(acelp_274, type1_arr);

 uint8_t type3_arr[432];
 int type3_idx = 0;

 /* 2. Class 0 uncoded (102 bits) */
 memcpy(type3_arr, type1_arr, CLASS0_BITS);
 type3_idx += CLASS0_BITS;

 /* 3. Speech convenc CONTINUOUS across Class 1 + Class 2 */
 speech_conv_state_t ces;
 speech_conv_init(&ces);

 /* 4. Class 1: 112 → 336 mother → 168 punctured */
 {
 const uint8_t *class1_in = &type1_arr[CLASS0_BITS];
 uint8_t mother_buf[CLASS1_BITS * 3];
 speech_conv_encode(&ces, class1_in, CLASS1_BITS, mother_buf);
 uint8_t punct_buf[168];
 rcpc_punct(&PUNCT_RATE112_168, mother_buf, punct_buf, 168);
 memcpy(&type3_arr[type3_idx], punct_buf, 168);
 type3_idx += 168;
 }

 /* 5. Class 2: data(60) + CRC(8) + tail(4) = 72 bits → 216 mother → 162 punctured */
 {
 const uint8_t *class2_data = &type1_arr[CLASS0_BITS + CLASS1_BITS];
 uint8_t class2_type2[CLASS2_TYPE2] = {0};
 memcpy(class2_type2, class2_data, CLASS2_BITS);
 uint8_t crc_bits[8];
 speech_crc(class2_data, crc_bits);
 memcpy(&class2_type2[CLASS2_BITS], crc_bits, 8);
 /* tail bits 68..71 stay 0 */

 uint8_t mother_buf[CLASS2_TYPE2 * 3];
 speech_conv_encode(&ces, class2_type2, CLASS2_TYPE2, mother_buf);
 uint8_t punct_buf[162];
 rcpc_punct(&PUNCT_RATE72_162, mother_buf, punct_buf, 162);
 memcpy(&type3_arr[type3_idx], punct_buf, 162);
 type3_idx += 162;
 }

 /* 6. Block-interleave 24×18 → type4 */
 uint8_t type4[432];
 tetra_tch_s_interleave_speech(type3_arr, type4);

 /* 7. Scramble → type5 */
 memcpy(type5_out_432, type4, 432);
 tetra_tch_s_scramble(type5_out_432, scramb_init);

 return 0;
}
