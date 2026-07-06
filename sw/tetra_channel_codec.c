/*
 * tetra_channel_codec.c — TETRA channel encoder primitives (SW side)
 *
 * Verbatim extract from tetra_hal.c (ETSI EN 300 392-2 §8.2.x), so the
 * tetra_attach_daemon can link these without pulling tetra_hal.c's
 * main(). When tetra_hal.c is refactored to share this codec module
 * the duplicates there can be removed.
 *
 * License: GPL v2
 */

#include "tetra_channel_codec.h"

#include <string.h>

/* ========================================================================
 * CRC-16-CCITT (X.25) with final XOR — ETSI EN 300 392-2 §8.2.2
 * ======================================================================== */
void tetra_codec_crc16(const uint8_t *bits, int len, uint8_t *out)
{
 uint16_t crc = 0xFFFF;

 memcpy(out, bits, len);

 for (int i = 0; i < len; i++) {
 int feedback = (bits[i] & 1) ^ ((crc >> 15) & 1);
 crc <<= 1;
 if (feedback)
 crc ^= 0x1021;
 }

 crc ^= 0xFFFF;
 for (int i = 0; i < 16; i++)
 out[len + i] = (crc >> (15 - i)) & 1;
}

/* ========================================================================
 * Parity helper (used by conv encoder).
 * ======================================================================== */
static inline int parity5(uint8_t x)
{
 x ^= x >> 4;
 x ^= x >> 2;
 x ^= x >> 1;
 return x & 1;
}

/* ========================================================================
 * ETSI rate-1/4 mother conv encoder (K=5, G1=0x13, G2=0x1D, G3=0x17,
 * G4=0x1B). MSB of shift register = newest input bit.
 * ======================================================================== */
int tetra_codec_conv_r14(const uint8_t *bits, int len, uint8_t *out)
{
 uint8_t sr = 0;
 int idx = 0;

 for (int i = 0; i < len; i++) {
 sr = ((sr << 1) | (bits[i] & 1)) & 0x1F;
 out[idx++] = parity5(sr & 0x13);
 out[idx++] = parity5(sr & 0x1D);
 out[idx++] = parity5(sr & 0x17);
 out[idx++] = parity5(sr & 0x1B);
 }
 return idx;
}

/* ========================================================================
 * P_2/3 puncture: keep {g1(a), g2(a), g1(b)} per pair of input bits.
 * ======================================================================== */
int tetra_codec_puncture_r23(const uint8_t *bits_r14, int len, uint8_t *out)
{
 int idx = 0;

 if ((len % 8) != 0)
 return -1;

 for (int i = 0; i < len; i += 8) {
 out[idx++] = bits_r14[i + 0]; /* g1(a) */
 out[idx++] = bits_r14[i + 1]; /* g2(a) */
 out[idx++] = bits_r14[i + 4]; /* g1(b) */
 }
 return idx;
}

/* ========================================================================
 * Multiplicative permutation interleaver — §8.2.4.1
 * ======================================================================== */
void tetra_codec_interleave_perm(const uint8_t *in, int N, int a,
                                 uint8_t *out)
{
 for (int k = 1; k <= N; k++) {
 int j = 1 + ((a * k) % N);
 out[j - 1] = in[k - 1];
 }
}

/* ========================================================================
 * Cell-identity scrambler LFSR — §8.2.5.2
 * Polynomial / taps: 32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1.
 * ======================================================================== */
#define ST(x, y) ((x) >> (32 - (y)))

static uint8_t next_lfsr_bit(uint32_t *lf)
{
 uint32_t lfsr = *lf;
 uint32_t bit;

 bit = (ST(lfsr, 32) ^ ST(lfsr, 26) ^ ST(lfsr, 23) ^ ST(lfsr, 22) ^
 ST(lfsr, 16) ^ ST(lfsr, 12) ^ ST(lfsr, 11) ^ ST(lfsr, 10) ^
 ST(lfsr,  8) ^ ST(lfsr,  7) ^ ST(lfsr,  5) ^ ST(lfsr,  4) ^
 ST(lfsr,  2) ^ ST(lfsr,  1)) & 1;
 lfsr = (lfsr >> 1) | (bit << 31);

 *lf = lfsr;
 return bit & 0xff;
}

/* ========================================================================
 * SCH/F channel coding: 268 info → 432 type-5
 *   info(268) → CRC-16 → type-2(284) → +4 tail → type-3(288)
 *            → rate-1/4 mother(1152) → P_2/3 puncture → type-4(432)
 *            → interleave K=432,a=103 → scramble → type-5(432)
 * Scrambler init (lower-2 = slot_num):
 *   e(0..31) = MCC(10) | MNC(14) | CC(6) | slot_num(2)
 * ======================================================================== */
#define SCHF_INFO_BITS 268
#define SCHF_CRC_BITS  (SCHF_INFO_BITS + 16) /* 284 */
#define SCHF_TAIL_BITS (SCHF_CRC_BITS + 4)   /* 288 */
#define SCHF_CODED_BITS 432

int tetra_codec_schf_encode(const uint8_t *info_268,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *out_432)
{
 uint8_t type2[SCHF_CRC_BITS];
 uint8_t type3[SCHF_TAIL_BITS];
 uint8_t mother[SCHF_TAIL_BITS * 4];
 uint8_t type4[SCHF_CODED_BITS];
 uint8_t type4i[SCHF_CODED_BITS];

 tetra_codec_crc16(info_268, SCHF_INFO_BITS, type2);
 memcpy(type3, type2, SCHF_CRC_BITS);
 memset(type3 + SCHF_CRC_BITS, 0, 4);

 int m = tetra_codec_conv_r14(type3, SCHF_TAIL_BITS, mother);
 int c = tetra_codec_puncture_r23(mother, m, type4);
 if (m != SCHF_TAIL_BITS * 4 || c != SCHF_CODED_BITS)
 return -1;

 tetra_codec_interleave_perm(type4, SCHF_CODED_BITS, 103, type4i);

 uint32_t lfsr = ((uint32_t)(mcc & 0x3FF) << 22)
 | ((uint32_t)(mnc & 0x3FFF) << 8)
 | ((uint32_t)(colour_code & 0x3F) << 2)
 | 3u;
 if (lfsr == 0)
 lfsr = 0xFFFFFFFF;
 for (int i = 0; i < SCHF_CODED_BITS; i++)
 out_432[i] = (type4i[i] ^ next_lfsr_bit(&lfsr)) & 1;

 (void)slot_num;
 return 0;
}

/* ========================================================================
 * Decoder primitives — Inverse zu Encoder, fuer SW Viterbi-Roundtrip.
 * ======================================================================== */

void tetra_codec_descramble(const uint8_t *type5_in, int len,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *type4_out)
{
 uint32_t lfsr = ((uint32_t)(mcc & 0x3FF) << 22)
 | ((uint32_t)(mnc & 0x3FFF) << 8)
 | ((uint32_t)(colour_code & 0x3F) << 2)
 | 3u;
 if (lfsr == 0)
 lfsr = 0xFFFFFFFF;
 for (int i = 0; i < len; i++)
 type4_out[i] = (type5_in[i] ^ next_lfsr_bit(&lfsr)) & 1;
 (void)slot_num;
}

void tetra_codec_deinterleave_perm(const uint8_t *in, int N, int a,
                                   uint8_t *out)
{
 /* Forward: out[j-1] = in[k-1] mit j = 1 + (a*k) mod N.
  *   → für jeden k ∈ [1..N]: input-position k landet bei output-position j.
  * Inverse: in[k-1] = out[j-1] mit gleicher j-Formel
  *   → für jeden k: lese out[j-1] und schreibe an Position k-1. */
 for (int k = 1; k <= N; k++) {
 int j = 1 + ((a * k) % N);
 out[k - 1] = in[j - 1];
 }
}

void tetra_codec_depuncture_r23(const uint8_t *in_punct, int in_len,
                                uint8_t *out_mother)
{
 /* in_punct: 3 bits pro 2 info-bits = 3/2 × Mother. Periode 8 mother
  * bits ↔ 3 punktierte bits. Werte:
  *   in_punct[3p+0] = g1(a) → mother[8p+0]
  *   in_punct[3p+1] = g2(a) → mother[8p+1]
  *   in_punct[3p+2] = g1(b) → mother[8p+4]
  *   Rest: Erasure (2). */
 int n_pairs = in_len / 3;
 for (int p = 0; p < n_pairs; p++) {
 out_mother[p * 8 + 0] = in_punct[p * 3 + 0] & 1;
 out_mother[p * 8 + 1] = in_punct[p * 3 + 1] & 1;
 out_mother[p * 8 + 2] = 2;
 out_mother[p * 8 + 3] = 2;
 out_mother[p * 8 + 4] = in_punct[p * 3 + 2] & 1;
 out_mother[p * 8 + 5] = 2;
 out_mother[p * 8 + 6] = 2;
 out_mother[p * 8 + 7] = 2;
 }
}

/* K=5 rate-1/4 Viterbi. Generators G1=0x13, G2=0x1D, G3=0x17, G4=0x1B,
 * matching tetra_codec_conv_r14. State = 4-bit shift-register (sr[3:0]
 * after right-shift). Input branch (0/1) shifts into MSB → sr5.
 * Output 4 mother bits = parity5(sr & Gx). */

static const uint8_t VITERBI_G[4] = { 0x13, 0x1D, 0x17, 0x1B };

void tetra_codec_viterbi_r14(const uint8_t *coded_in, int n_input,
                             uint8_t *decoded_out)
{
 const int N_STATES = 16;
 const int INF_M = 1 << 28;

 /* Path metrics — current + next. */
 int pm[16];
 int pm_new[16];
 /* Traceback tables: tb_state[i][s] = predecessor state, tb_input[i][s]
  * = input bit that drove the transition. Each as flat array
  * size n_input × 16 (max in our case 288 × 16 = 4608 entries each). */
 /* Heap allocation would be safer for arbitrary n_input. For SCH/F
  * (288 stages) we know the size at compile time; use VLA. */
 uint8_t *tb_state = (uint8_t *)__builtin_alloca((size_t)n_input * N_STATES);
 uint8_t *tb_input = (uint8_t *)__builtin_alloca((size_t)n_input * N_STATES);

 for (int s = 0; s < N_STATES; s++)
 pm[s] = (s == 0) ? 0 : INF_M;

 for (int i = 0; i < n_input; i++) {
 int rx[4];
 for (int m = 0; m < 4; m++)
 rx[m] = coded_in[i * 4 + m];

 for (int s = 0; s < N_STATES; s++)
 pm_new[s] = INF_M;

 for (int old_state = 0; old_state < N_STATES; old_state++) {
 if (pm[old_state] >= INF_M)
 continue;
 for (int inp = 0; inp < 2; inp++) {
 int sr = ((old_state << 1) | inp) & 0x1F;
 int new_state = sr & 0xF;
 int metric = pm[old_state];
 for (int m = 0; m < 4; m++) {
 int e = parity5((uint8_t)(sr & VITERBI_G[m]));
 if (rx[m] != 2)
 metric += (e ^ rx[m]);
 }
 if (metric < pm_new[new_state]) {
 pm_new[new_state] = metric;
 tb_state[i * N_STATES + new_state] = (uint8_t)old_state;
 tb_input[i * N_STATES + new_state] = (uint8_t)inp;
 }
 }
 }
 for (int s = 0; s < N_STATES; s++)
 pm[s] = pm_new[s];
 }

 /* Traceback from state 0 (encoder ends in state 0 after tail bits).
  * If best state is not 0 (CRC will fail), still trace from 0 — this
  * matches encoder convention. */
 int state = 0;
 for (int i = n_input - 1; i >= 0; i--) {
 decoded_out[i] = tb_input[i * N_STATES + state];
 state = tb_state[i * N_STATES + state];
 }
}

/* ========================================================================
 * Inverse-CRC-Check: input has 268 info + 16 CRC bits = 284 bits.
 * Run forward CRC over first 268 bits, compare appended 16.
 * ======================================================================== */
static int crc16_check(const uint8_t *bits_284)
{
 uint16_t crc = 0xFFFF;
 for (int i = 0; i < 268; i++) {
 int feedback = (bits_284[i] & 1) ^ ((crc >> 15) & 1);
 crc <<= 1;
 if (feedback)
 crc ^= 0x1021;
 }
 crc ^= 0xFFFF;
 for (int i = 0; i < 16; i++) {
 int want = (crc >> (15 - i)) & 1;
 if ((bits_284[268 + i] & 1) != want)
 return 0;
 }
 return 1;
}

int tetra_codec_schf_decode(const uint8_t *type5_in,
                            uint8_t colour_code, uint8_t slot_num,
                            uint16_t mcc, uint16_t mnc,
                            uint8_t *info_268_out)
{
 uint8_t type4[SCHF_CODED_BITS];
 uint8_t type4d[SCHF_CODED_BITS];
 uint8_t mother[SCHF_TAIL_BITS * 4];
 uint8_t decoded[SCHF_TAIL_BITS];

 tetra_codec_descramble(type5_in, SCHF_CODED_BITS, colour_code, slot_num,
 mcc, mnc, type4);
 tetra_codec_deinterleave_perm(type4, SCHF_CODED_BITS, 103, type4d);
 tetra_codec_depuncture_r23(type4d, SCHF_CODED_BITS, mother);
 tetra_codec_viterbi_r14(mother, SCHF_TAIL_BITS, decoded);

 /* decoded layout: [0..267]=info, [268..283]=CRC, [284..287]=tail (zeros). */
 memcpy(info_268_out, decoded, SCHF_INFO_BITS);

 return crc16_check(decoded) ? 0 : -1;
}

/* ========================================================================
 * SCH/HU (UL RA/MAC-ACCESS) Soft-Chain — Option B, spiegelt
 * tetra_ul_sch_hu_decoder.v (K=168, a=13, info=92) + decode_dl.py.
 * ======================================================================== */
#define SCHHU_INFO_BITS   92
#define SCHHU_CHECK_BITS  108   /* 92 info + 16 CRC */
#define SCHHU_DEC_BITS    112   /* + 4 tail */
#define SCHHU_MOTHER_BITS 448
#define SCHHU_CODED_BITS  168
#define SCHHU_A           13

static int crc16_check_n(const uint8_t *bits, int info_len)
{
    uint16_t crc = 0xFFFF;
    for (int i = 0; i < info_len; i++) {
        int fb = (bits[i] & 1) ^ ((crc >> 15) & 1);
        crc <<= 1; if (fb) crc ^= 0x1021;
    }
    crc ^= 0xFFFF;
    for (int i = 0; i < 16; i++) {
        int want = (crc >> (15 - i)) & 1;
        if ((bits[info_len + i] & 1) != want) return 0;
    }
    return 1;
}

int tetra_codec_schhu_decode(const uint8_t *type5_168,
                             uint8_t colour_code, uint8_t slot_num,
                             uint16_t mcc, uint16_t mnc,
                             uint8_t *info_92_out)
{
    uint8_t type4[SCHHU_CODED_BITS], type4d[SCHHU_CODED_BITS];
    uint8_t mother[SCHHU_MOTHER_BITS];
    uint8_t decoded[SCHHU_DEC_BITS];

    tetra_codec_descramble(type5_168, SCHHU_CODED_BITS, colour_code, slot_num,
                           mcc, mnc, type4);
    tetra_codec_deinterleave_perm(type4, SCHHU_CODED_BITS, SCHHU_A, type4d);
    tetra_codec_depuncture_r23(type4d, SCHHU_CODED_BITS, mother);
    tetra_codec_viterbi_r14(mother, SCHHU_DEC_BITS, decoded);
    memcpy(info_92_out, decoded, SCHHU_INFO_BITS);
    return crc16_check_n(decoded, SCHHU_INFO_BITS) ? 0 : -1;
}

/* ========================================================================
 * SOFT-Pfad (Option B) — signed int soft-values, Konvention:
 *   positiv = bit '1', negativ = bit '0', |s| = Konfidenz, 0 = Erasure.
 * ======================================================================== */
void tetra_codec_descramble_soft(const int *soft_in, int len,
                                 uint8_t colour_code, uint8_t slot_num,
                                 uint16_t mcc, uint16_t mnc, int *soft_out)
{
    uint32_t lfsr = ((uint32_t)(mcc&0x3FF)<<22)|((uint32_t)(mnc&0x3FFF)<<8)
                    |((uint32_t)(colour_code&0x3F)<<2)|3u;
    if(!lfsr) lfsr=0xFFFFFFFF;
    for(int i=0;i<len;i++){ uint8_t b=next_lfsr_bit(&lfsr); soft_out[i]= b? -soft_in[i] : soft_in[i]; }
    (void)slot_num;
}
void tetra_codec_deinterleave_perm_soft(const int *in,int N,int a,int *out){
    for(int k=1;k<=N;k++){ int j=1+((a*k)%N); out[k-1]=in[j-1]; }
}
/* Soft-Depuncture r=2/3: 3 soft/Paar an mother {0,1,4}; Rest Erasure=0. */
void tetra_codec_depuncture_r23_soft(const int *in_punct,int in_len,int *mother){
    int np=in_len/3;
    for(int p=0;p<np;p++){
        mother[p*8+0]=in_punct[p*3+0]; mother[p*8+1]=in_punct[p*3+1];
        mother[p*8+2]=0; mother[p*8+3]=0; mother[p*8+4]=in_punct[p*3+2];
        mother[p*8+5]=0; mother[p*8+6]=0; mother[p*8+7]=0;
    }
}
/* Soft K=5 r=1/4 Viterbi. Metrik: pro mother-bit Strafe |s| bei Vorzeichen-
 * Widerspruch zum erwarteten bit, 0 bei Erasure(s==0). */
void tetra_codec_viterbi_r14_soft(const int *soft_in,int n_input,uint8_t *decoded){
    const int NS=16; const int INF=1<<28; /* > max metric (~448×|s|); passt in 32-bit int (auch arm) */
    int pm[16],pmn[16];
    uint8_t *tbs=(uint8_t*)__builtin_alloca((size_t)n_input*NS);
    uint8_t *tbi=(uint8_t*)__builtin_alloca((size_t)n_input*NS);
    for(int s=0;s<NS;s++) pm[s]=(s==0)?0:INF;
    for(int i=0;i<n_input;i++){
        int rx[4]; for(int m=0;m<4;m++) rx[m]=soft_in[i*4+m];
        for(int s=0;s<NS;s++) pmn[s]=INF;
        for(int os=0;os<NS;os++){ if(pm[os]>=INF) continue;
            for(int inp=0;inp<2;inp++){
                int sr=((os<<1)|inp)&0x1F; int nsx=sr&0xF; int metric=pm[os];
                for(int m=0;m<4;m++){ int e=parity5((uint8_t)(sr&VITERBI_G[m])); int s=rx[m];
                    if(s!=0){ int hb=(s>0)?1:0; if(e!=hb) metric += (s<0? -s : s); } }
                if(metric<pmn[nsx]){ pmn[nsx]=metric; tbs[i*NS+nsx]=(uint8_t)os; tbi[i*NS+nsx]=(uint8_t)inp; }
            } }
        for(int s=0;s<NS;s++) pm[s]=pmn[s];
    }
    int st=0;
    for(int i=n_input-1;i>=0;i--){ decoded[i]=tbi[i*NS+st]; st=tbs[i*NS+st]; }
}
int tetra_codec_schhu_decode_soft(const int *soft_168,
                                  uint8_t cc,uint8_t slot,uint16_t mcc,uint16_t mnc,
                                  uint8_t *info_92_out){
    int t4[168],t4d[168],mo[448]; uint8_t dec[112];
    tetra_codec_descramble_soft(soft_168,168,cc,slot,mcc,mnc,t4);
    tetra_codec_deinterleave_perm_soft(t4,168,13,t4d);
    tetra_codec_depuncture_r23_soft(t4d,168,mo);
    tetra_codec_viterbi_r14_soft(mo,112,dec);
    memcpy(info_92_out,dec,92);
    return crc16_check_n(dec,92)?0:-1;
}

/* SCH/F Soft-Decoder (Option B): 432 soft type-5 → 268 info (K=432,a=103). */
int tetra_codec_schf_decode_soft(const int *soft_432,
                                 uint8_t colour_code, uint8_t slot_num,
                                 uint16_t mcc, uint16_t mnc,
                                 uint8_t *info_268_out)
{
    int t4[SCHF_CODED_BITS], t4d[SCHF_CODED_BITS], mo[SCHF_TAIL_BITS * 4];
    uint8_t dec[SCHF_TAIL_BITS];
    tetra_codec_descramble_soft(soft_432, SCHF_CODED_BITS, colour_code, slot_num,
                                mcc, mnc, t4);
    tetra_codec_deinterleave_perm_soft(t4, SCHF_CODED_BITS, 103, t4d);
    tetra_codec_depuncture_r23_soft(t4d, SCHF_CODED_BITS, mo);
    tetra_codec_viterbi_r14_soft(mo, SCHF_TAIL_BITS, dec);
    memcpy(info_268_out, dec, SCHF_INFO_BITS);
    return crc16_check_n(dec, SCHF_INFO_BITS) ? 0 : -1;
}
