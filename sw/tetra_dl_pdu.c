/*
 * tetra_dl_pdu.c — see header.
 * License: GPL v2
 */
#include "tetra_dl_pdu.h"
#include "tetra_sch_f_encoder.h"

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
