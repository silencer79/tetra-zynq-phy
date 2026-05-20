/*
 * tetra_dl_pdu.h — Komplette DL-PDU-Build-Pipeline in SW.
 *
 * Phase Move-3+4 (2026-05-20): ersetzt die Funktion von u_dl_pdu_builder.v
 * (4555 LUT) durch reinen C-Code. Pipeline:
 *
 *   meta + mm_bits → tetra_build_mac_resource_pdu()  → 268-bit info
 *                  → tetra_sch_f_encode()             → 432-bit type-5
 *
 * Output landet via neuer RTL-raw-Mailbox direkt im u_dl_signal_queue.
 *
 * License: GPL v2
 */
#ifndef TETRA_DL_PDU_H
#define TETRA_DL_PDU_H

#include <stdint.h>
#include "tetra_mac_resource_dl_builder.h"

/* Komplette MAC-RESOURCE + SCH/F Pipeline.
 *   meta:           MAC-Resource Metadata
 *   mm_bits:        MM-Body MSB-first, 0/1 pro byte
 *   mm_len:         Anzahl gültiger MM-Bits (0..128)
 *   scramble_init:  Cell-LFSR-Seed (32 bit)
 *   out_432:        432-bit type-5 SCH/F coded, MSB-first
 * Returns 0 on success, -1 on overflow (mm_len zu groß). */
int tetra_build_dl_pdu_432(const tetra_mac_res_meta_t *meta,
                            const uint8_t *mm_bits,
                            int mm_len,
                            uint32_t scramble_init,
                            uint8_t out_432[432]);

#endif /* TETRA_DL_PDU_H */
