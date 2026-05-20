/*
 * tetra_dl_pdu.c — see header.
 * License: GPL v2
 */
#include "tetra_dl_pdu.h"
#include "tetra_sch_f_encoder.h"

#include <string.h>

int tetra_build_dl_pdu_432(const tetra_mac_res_meta_t *meta,
                            const uint8_t *mm_bits,
                            int mm_len,
                            uint32_t scramble_init,
                            uint8_t out_432[432])
{
    uint8_t info_268[TETRA_MAC_RES_PDU_BITS];
    int rc = tetra_build_mac_resource_pdu(meta, mm_bits, mm_len, info_268);
    if (rc != 0) return rc;

    tetra_sch_f_encode(info_268, scramble_init, out_432);
    return 0;
}

/* MSB-first bit writer into a bit-array. */
static void wbits_into(uint8_t *out, int pos, uint32_t val, int n)
{
    for (int i = 0; i < n; i++)
        out[pos + i] = (uint8_t)((val >> (n - 1 - i)) & 1u);
}

int tetra_build_d_loc_update_accept_mm(uint8_t loc_acc_type,
                                        uint32_t gila_gssi,
                                        uint8_t gila_class,
                                        uint8_t gila_lifetime,
                                        uint8_t gila_present,
                                        uint16_t energy_saving_info,
                                        uint8_t *mm_bits)
{
    memset(mm_bits, 0, 128);
    int p = 0;
    /* [127:124] PDU type = 0101 (ACCEPT) */
    wbits_into(mm_bits, p, 0x5u, 4); p += 4;
    /* [123:121] loc_acc_type */
    wbits_into(mm_bits, p, loc_acc_type & 0x7u, 3); p += 3;
    /* [120] o-bit = 1 */
    wbits_into(mm_bits, p, 1u, 1); p += 1;
    /* [119] p_ssi = 0, [118] p_address_extension = 0, [117] p_subscriber_class = 0 */
    wbits_into(mm_bits, p, 0u, 3); p += 3;
    /* [116] p_energy_saving_info = 1 */
    wbits_into(mm_bits, p, 1u, 1); p += 1;
    /* [115:102] energy_saving_info (14 bit) */
    wbits_into(mm_bits, p, energy_saving_info & 0x3FFFu, 14); p += 14;
    /* [101] p_scch_info = 0 */
    wbits_into(mm_bits, p, 0u, 1); p += 1;

    if (!gila_present) {
        /* [100] m-bit T3 = 0, [99] trailing m-bit = 0 → 36 bit body */
        wbits_into(mm_bits, p, 0u, 1); p += 1;  /* m-bit T3 */
        wbits_into(mm_bits, p, 0u, 1); p += 1;  /* trailing m-bit */
        return 36;
    }

    /* GILA present — 102-bit body */
    /* [100] m-bit T3 = 1 */
    wbits_into(mm_bits, p, 1u, 1); p += 1;
    /* [99:96] T3 elem_id = 5 (GroupIdentityLocationAccept) */
    wbits_into(mm_bits, p, 5u, 4); p += 4;
    /* [95:85] T3 length = 58 */
    wbits_into(mm_bits, p, 58u, 11); p += 11;

    /* GILA payload (58 bit):
     *   accept_reject(0) + reserved(0) + o-bit(1)            = 001
     *   m-bit(1) + elem_id=7(4) + length=38(11)              = 1 0111 00000100110
     *   num_elems = 1 (6 bit)                                 = 000001
     *   GroupIdentityDownlink entry (32 bit):
     *     attach_detach_type_id(1)=0 + lifetime(2) + class(3)
     *     + address_type(2)=00 + GSSI(24)
     *   trailing m-bit (GILA itself) = 0
     */
    wbits_into(mm_bits, p, 0u, 1); p += 1;          /* accept_reject */
    wbits_into(mm_bits, p, 0u, 1); p += 1;          /* reserved */
    wbits_into(mm_bits, p, 1u, 1); p += 1;          /* o-bit */
    wbits_into(mm_bits, p, 1u, 1); p += 1;          /* m-bit (T4 follows) */
    wbits_into(mm_bits, p, 7u, 4); p += 4;          /* elem_id = 7 (GroupIdentityDownlink) */
    wbits_into(mm_bits, p, 38u, 11); p += 11;       /* length = 38 */
    wbits_into(mm_bits, p, 1u, 6); p += 6;          /* num_elems = 1 */
    wbits_into(mm_bits, p, 0u, 1); p += 1;          /* attach_detach_type_id */
    wbits_into(mm_bits, p, gila_lifetime & 0x3u, 2); p += 2;
    wbits_into(mm_bits, p, gila_class & 0x7u, 3); p += 3;
    wbits_into(mm_bits, p, 0u, 2); p += 2;          /* address_type = 00 */
    wbits_into(mm_bits, p, gila_gssi & 0xFFFFFFu, 24); p += 24;
    wbits_into(mm_bits, p, 0u, 1); p += 1;          /* trailing m-bit (inside GILA) */

    /* [26] trailing m-bit (D-LOC-UPDATE-ACCEPT outer) = 0 */
    wbits_into(mm_bits, p, 0u, 1); p += 1;
    /* p should equal 102 */

    return 102;
}

int tetra_build_d_loc_update_reject_mm(uint8_t reject_cause, uint8_t *mm_bits)
{
    memset(mm_bits, 0, 128);
    int p = 0;
    /* [0..3] PDU type = 0111 (REJECT) */
    wbits_into(mm_bits, p, 0x7u, 4); p += 4;
    /* [4..6] reject cause (3 bit) */
    wbits_into(mm_bits, p, reject_cause & 0x7u, 3); p += 3;
    /* [7] o-bit = 0 */
    wbits_into(mm_bits, p, 0u, 1); p += 1;
    return 8;
}

/* Indirect-write helper for REG_DL_RAW_PDU_DATA. */
static void rawpdu_write(tetra_hal_t *hal, uint32_t idx, uint32_t data)
{
    tetra_reg_write(hal, REG_DL_RAW_PDU_INDEX, idx);
    tetra_reg_write(hal, REG_DL_RAW_PDU_DATA, data);
}

int tetra_dl_pdu_push_432(tetra_hal_t *hal,
                           const uint8_t coded_432[432],
                           uint8_t pdu_type,
                           uint8_t target_tn,
                           uint16_t aach_pattern,
                           uint8_t second_pdu_present,
                           uint8_t second_pdu_nr)
{
    /* Pack 432 bits MSB-first into 14 × 32-bit words.
     * W0  = coded[0..31]   = first 32 on-air bits
     * W1  = coded[32..63]
     *  ...
     * W12 = coded[384..415]
     * W13 upper 16 bit = coded[416..431]
     */
    uint32_t words[14] = {0};
    for (int wi = 0; wi < 13; wi++) {
        uint32_t w = 0;
        for (int b = 0; b < 32; b++)
            w = (w << 1) | (coded_432[wi * 32 + b] & 1u);
        words[wi] = w;
    }
    uint32_t w13_top = 0;
    for (int b = 0; b < 16; b++)
        w13_top = (w13_top << 1) | (coded_432[416 + b] & 1u);
    words[13] = w13_top << 16;

    for (int wi = 0; wi < 14; wi++)
        rawpdu_write(hal, (uint32_t)wi, words[wi]);

    /* Meta word W14:
     *   [1:0]   pdu_type
     *   [3:2]   target_tn
     *   [17:4]  aach_pattern
     *   [18]    second_pdu_present
     *   [19]    second_pdu_nr
     */
    uint32_t meta = ((uint32_t)(pdu_type            & 0x3u) <<  0)
                  | ((uint32_t)(target_tn           & 0x3u) <<  2)
                  | ((uint32_t)(aach_pattern     & 0x3FFFu) <<  4)
                  | ((uint32_t)(second_pdu_present & 0x1u) << 18)
                  | ((uint32_t)(second_pdu_nr      & 0x1u) << 19);
    rawpdu_write(hal, 14u, meta);

    /* GO pulse — HW edge-detect on clk_sys side, consume HW-clears the bit. */
    tetra_reg_write(hal, REG_DL_RAW_PDU_GO, 0x1u);
    return 0;
}

int tetra_dl_pdu_build_and_push(tetra_hal_t *hal,
                                 const tetra_mac_res_meta_t *meta,
                                 const uint8_t *mm_bits,
                                 int mm_len,
                                 uint32_t scramble_init,
                                 uint8_t pdu_type,
                                 uint8_t target_tn,
                                 uint16_t aach_pattern,
                                 uint8_t second_pdu_present,
                                 uint8_t second_pdu_nr)
{
    uint8_t coded[432];
    int rc = tetra_build_dl_pdu_432(meta, mm_bits, mm_len, scramble_init, coded);
    if (rc != 0) return rc;
    return tetra_dl_pdu_push_432(hal, coded, pdu_type, target_tn,
                                  aach_pattern, second_pdu_present,
                                  second_pdu_nr);
}
