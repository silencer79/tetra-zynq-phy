/*
 * tetra_dl_pdu.h — Komplette DL-PDU-Build-Pipeline in SW.
 *
 * Phase Move-3+4 (2026-05-20): ersetzt die Funktion von u_dl_pdu_builder.v
 * + u_mle_registration_fsm.v + u_dloc + Reply-Pull-Mailbox durch reinen
 * C-Code. Pipeline:
 *
 *   meta + mm_bits → tetra_build_mac_resource_pdu()  → 268-bit info
 *                  → tetra_sch_f_encode()             → 432-bit type-5
 *                  → tetra_dl_pdu_push_432()          → REG_DL_RAW_PDU_*
 *                                                       → dl_signal_queue
 *
 * License: GPL v2
 */
#ifndef TETRA_DL_PDU_H
#define TETRA_DL_PDU_H

#include <stdint.h>
#include "tetra_mac_resource_dl_builder.h"
#include "tetra_hal.h"

/* Komplette MAC-RESOURCE + SCH/F Pipeline. */
int tetra_build_dl_pdu_432(const tetra_mac_res_meta_t *meta,
                            const uint8_t *mm_bits,
                            int mm_len,
                            uint32_t scramble_init,
                            uint8_t out_432[432]);

/* Build D-LOC-UPDATE-ACCEPT MM body (ETSI §16.10.x).
 *   loc_acc_type:    3-bit echo from MS demand (§16.10.35a)
 *   gila_gssi:       24-bit GILA target
 *   gila_class:      3-bit class_of_usage
 *   gila_lifetime:   2-bit lifetime
 *   gila_present:    1 = embed GILA Type-3 element (102-bit body),
 *                    0 = omit GILA (36-bit body)
 *   energy_saving_info: 14-bit ESI field (default 0 = StayAlive)
 *   mm_bits:         output, MSB-first bit array (at least 128 bytes)
 * Returns the number of valid MM bits (36 or 102). */
int tetra_build_d_loc_update_accept_mm(uint8_t loc_acc_type,
                                        uint32_t gila_gssi,
                                        uint8_t gila_class,
                                        uint8_t gila_lifetime,
                                        uint8_t gila_present,
                                        uint16_t energy_saving_info,
                                        uint8_t *mm_bits);

/* Build D-LOC-UPDATE-REJECT MM body — 8 bit:
 *   [0..3]  PDU type = 0111 (REJECT)
 *   [4..6]  reject cause (3 bit)
 *   [7]     o-bit = 0
 *
 * Caller passes the 3-bit reject cause directly (1 = illegal MS,
 * 2 = no resources, etc., ETSI Tab 16.43).
 * Returns 8. */
int tetra_build_d_loc_update_reject_mm(uint8_t reject_cause, uint8_t *mm_bits);

/* Push a fully-built 432-bit type-5 PDU into the DL-Signal-Queue via
 * REG_DL_RAW_PDU_*. Caller must ensure the previous push has been consumed
 * (the trigger reg HW-clears on consume). Returns 0 on success. */
int tetra_dl_pdu_push_432(tetra_hal_t *hal,
                           const uint8_t coded_432[432],
                           uint8_t pdu_type,        /* 0 = SCH/F */
                           uint8_t target_tn,       /* 0..3 */
                           uint16_t aach_pattern,   /* 14 bit */
                           uint8_t second_pdu_present,
                           uint8_t second_pdu_nr);

/* High-level: build MAC-Resource + SCH/F PDU AND push it via REG_DL_RAW_PDU_*.
 * Wrapper for tetra_build_dl_pdu_432 + tetra_dl_pdu_push_432. */
int tetra_dl_pdu_build_and_push(tetra_hal_t *hal,
                                 const tetra_mac_res_meta_t *meta,
                                 const uint8_t *mm_bits,
                                 int mm_len,
                                 uint32_t scramble_init,
                                 uint8_t pdu_type,
                                 uint8_t target_tn,
                                 uint16_t aach_pattern,
                                 uint8_t second_pdu_present,
                                 uint8_t second_pdu_nr);

#endif /* TETRA_DL_PDU_H */
