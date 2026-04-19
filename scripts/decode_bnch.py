#!/usr/bin/env python3
"""Decode BNCH (bkn2) from a TETRA WAV recording.

Extracts bkn2 from each SDB burst, applies cell-identity descrambler,
multiplicative deinterleaver, ETSI rate-2/3 RCPC (over rate-1/4 mother),
CRC-16 check, and parses SYSINFO / ACCESS_DEFINE PDUs.

Usage:
    python3 scripts/decode_bnch.py "16-Apr-2026 190240.941 425.520MHz 000.wav" --etsi
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from decode_sb import (
    load_iq_file, estimate_freq_offset, rrc_filter, find_sync_bursts,
    build_sts_reference, estimate_freq_from_sts, demod_pi4dqpsk,
    scrambler_seq, etsi_viterbi_decode_r14_with_erasures,
    crc16_check, crc16_check_dll, crc16_modes,
    SYMBOL_RATE, SB_TOTAL, SDB_OFF_STS, SDB_STS_LEN,
    SDB_OFF_BKN2, SDB_BKN2_LEN, SDB_OFF_SB1, SDB_SB1_LEN, SDB_BB_LEN,
    SDB_OFF_BB, NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2,
    BSCH_CODED_BITS, SYSINFO_BITS,
    etsi_deinterleave_bsch, etsi_depuncture_r23, etsi_viterbi_decode_r23,
    descramble_bsch, parse_sysinfo,
    _parity5, ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4,
)
import numpy as np
import argparse

# BNCH constants
BNCH_INFO_BITS = 124
BNCH_CODED_BITS = 216  # type-5
BNCH_INTERL_K = 216
BNCH_INTERL_A = 101


# ============================================================================
# Soft-decision demodulation and Viterbi
# ============================================================================

def demod_pi4dqpsk_soft(symbols):
    """Soft differential demod → (dibits, soft_bits).
    soft_bits[2*i]=MSB, soft_bits[2*i+1]=LSB.
    Convention: positive = likely 0, negative = likely 1.
    Amplitude-weighted: faded symbols get lower confidence."""
    diff = symbols[1:] * np.conj(symbols[:-1])
    dphi = np.angle(diff)
    amp = np.abs(diff)
    # Normalise amplitude so median = 1
    med_amp = np.median(amp)
    if med_amp > 0:
        amp_norm = amp / med_amp
    else:
        amp_norm = np.ones_like(amp)
    # Clip to avoid outliers
    amp_norm = np.clip(amp_norm, 0.0, 2.0)

    n = len(dphi)
    dibits = np.empty(n, dtype=np.int32)
    soft_bits = np.empty(2 * n, dtype=np.float64)

    for i in range(n):
        p = dphi[i]
        a = amp_norm[i]
        # Hard decision (same mapping as demod_pi4dqpsk)
        if -np.pi / 2 < p <= 0:
            dibits[i] = 0b10
        elif 0 < p <= np.pi / 2:
            dibits[i] = 0b00
        elif np.pi / 2 < p <= np.pi:
            dibits[i] = 0b01
        else:
            dibits[i] = 0b11
        # MSB: 0 when Δφ>0, 1 when Δφ<0 → sin(Δφ) is natural soft metric
        # LSB: 0 when |Δφ|<π/2, 1 when |Δφ|>π/2 → cos(Δφ)
        soft_bits[2 * i] = a * np.sin(p)
        soft_bits[2 * i + 1] = a * np.cos(p)

    return dibits, soft_bits


def etsi_deinterleave_bnch_soft(soft_bits):
    """Multiplicative de-interleave K=216, a=101 for soft values."""
    K, a = BNCH_INTERL_K, BNCH_INTERL_A
    out = np.zeros(K, dtype=np.float64)
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        out[i - 1] = soft_bits[k - 1]
    return out


def etsi_depuncture_r23_bnch_soft(soft216):
    """Rate 2/3 depuncture for soft values. Erasure positions = 0.0."""
    P = [0, 1, 2, 5]
    t, period = 3, 8
    mother_len = (len(soft216) // 3) * 8
    out = np.zeros(mother_len, dtype=np.float64)
    is_erasure = np.ones(mother_len, dtype=bool)
    for j in range(1, len(soft216) + 1):
        i = j
        k = period * ((i - 1) // t) + P[i - t * ((i - 1) // t)]
        out[k - 1] = soft216[j - 1]
        is_erasure[k - 1] = False
    return out, is_erasure


def etsi_viterbi_decode_r14_soft(soft_mother, is_erasure):
    """Soft-decision Viterbi, K=5, rate 1/4 mother code.
    Branch metric: sum of (1 - soft * (1 - 2*expected)) per non-erased bit.
    Reduces to 2× Hamming distance for hard ±1 values."""
    n_states = 16
    n_coded = len(soft_mother)
    n_input = n_coded // 4
    INF = 1e18

    Gs = (ETSI_G1, ETSI_G2, ETSI_G3, ETSI_G4)

    pm = np.full(n_states, INF, dtype=np.float64)
    pm[0] = 0.0
    tb_state = np.zeros((n_input, n_states), dtype=np.int32)
    tb_input = np.zeros((n_input, n_states), dtype=np.int32)

    for i in range(n_input):
        new_pm = np.full(n_states, INF, dtype=np.float64)
        s = [soft_mother[4 * i + m] for m in range(4)]
        e_flags = [is_erasure[4 * i + m] for m in range(4)]

        for old_state in range(n_states):
            if pm[old_state] >= INF:
                continue
            for inp in range(2):
                sr = ((old_state << 1) | inp) & 0x1F
                new_state = sr & 0xF
                metric = pm[old_state]
                for m, G in enumerate(Gs):
                    if e_flags[m]:
                        continue
                    e = _parity5(sr & G)
                    # cost = 1.0 - soft * (1.0 - 2.0 * expected_bit)
                    metric += 1.0 - s[m] * (1.0 - 2.0 * e)
                if metric < new_pm[new_state]:
                    new_pm[new_state] = metric
                    tb_state[i, new_state] = old_state
                    tb_input[i, new_state] = inp
        pm = new_pm

    decoded = np.zeros(n_input, dtype=np.int32)
    state = 0
    for i in range(n_input - 1, -1, -1):
        decoded[i] = tb_input[i, state]
        state = tb_state[i, state]
    return decoded


def create_scrambler_code(mcc, mnc, cc):
    """SDR# CreateScramblerCode(mcc, mnc, colour) — verified from DLL."""
    return ((mcc & 0x3FF) << 22) | ((mnc & 0x3FFF) << 8) | ((cc & 0x3F) << 2) | 3


def etsi_deinterleave_bnch(bits):
    """Multiplicative de-interleave K=216, a=101.
    Matches DLL Deinterleave::Process: out[i-1] = in[k-1], k = 1+(a*i mod K)."""
    K, a = BNCH_INTERL_K, BNCH_INTERL_A
    out = np.zeros(K, dtype=np.int32)
    for i in range(1, K + 1):
        k = 1 + ((a * i) % K)
        out[i - 1] = bits[k - 1]
    return out


def etsi_depuncture_r23_bnch(bits23):
    """ETSI rate 2/3 depuncture over rate-1/4 mother (for 216 coded bits).
    144 type-3 → 576 mother bits."""
    P = [0, 1, 2, 5]
    t, period = 3, 8
    mother_len = (len(bits23) // 3) * 8
    out = np.full(mother_len, 2, dtype=np.int32)
    for j in range(1, len(bits23) + 1):
        i = j
        k = period * ((i - 1) // t) + P[i - t * ((i - 1) // t)]
        out[k - 1] = bits23[j - 1]
    return out


def extract_bits(b, start, nbits):
    val = 0
    for i in range(nbits):
        val = (val << 1) | (int(b[start + i]) & 1)
    return val


def parse_bnch_pdu(bits):
    """Parse 124 type-1 bits as MAC-BROADCAST PDU."""
    if len(bits) < 4:
        return None

    mac_pdu_type = extract_bits(bits, 0, 2)
    if mac_pdu_type != 2:
        return {'type': 'unknown', 'mac_pdu_type': mac_pdu_type}

    broadcast_type = extract_bits(bits, 2, 2)

    if broadcast_type == 0:
        # SYSINFO
        bp = 4
        r = {'type': 'SYSINFO'}
        r['Main_Carrier'] = extract_bits(bits, bp, 12); bp += 12
        r['Frequency_Band'] = extract_bits(bits, bp, 4); bp += 4
        r['Offset'] = extract_bits(bits, bp, 2); bp += 2
        r['Duplex_Spacing'] = extract_bits(bits, bp, 3); bp += 3
        r['Reverse_Operation'] = extract_bits(bits, bp, 1); bp += 1
        r['NumberOfCommon_SC'] = extract_bits(bits, bp, 2); bp += 2
        r['MS_TXPwr_Max_Cell'] = extract_bits(bits, bp, 3); bp += 3
        r['RXLevel_Access_Min'] = extract_bits(bits, bp, 4); bp += 4
        r['Access_Parameter'] = extract_bits(bits, bp, 4); bp += 4
        r['Radio_DL_Timeout'] = extract_bits(bits, bp, 4); bp += 4
        r['HF_or_CK_flag'] = extract_bits(bits, bp, 1); bp += 1
        if r['HF_or_CK_flag'] == 0:
            r['Hyperframe'] = extract_bits(bits, bp, 16); bp += 16
        else:
            r['CK_Identifier'] = extract_bits(bits, bp, 16); bp += 16
        r['Optional_field_flag'] = extract_bits(bits, bp, 2); bp += 2
        r['Optional_field_value'] = extract_bits(bits, bp, 20); bp += 20
        r['Location_Area'] = extract_bits(bits, bp, 14); bp += 14
        r['Subscriber_Class'] = extract_bits(bits, bp, 16); bp += 16
        r['Registration_required'] = extract_bits(bits, bp, 1); bp += 1
        r['De_registration_required'] = extract_bits(bits, bp, 1); bp += 1
        r['Priority_cell'] = extract_bits(bits, bp, 1); bp += 1
        r['Cell_never_uses_minimum_mode'] = extract_bits(bits, bp, 1); bp += 1
        r['Migration_supported'] = extract_bits(bits, bp, 1); bp += 1
        r['System_wide_services'] = extract_bits(bits, bp, 1); bp += 1
        r['TETRA_voice_service'] = extract_bits(bits, bp, 1); bp += 1
        r['Circuit_mode_data_service'] = extract_bits(bits, bp, 1); bp += 1
        r['Reserved'] = extract_bits(bits, bp, 1); bp += 1
        r['SNDCP_Service'] = extract_bits(bits, bp, 1); bp += 1
        r['Air_interface_encryption'] = extract_bits(bits, bp, 1); bp += 1
        r['Advanced_link_supported'] = extract_bits(bits, bp, 1); bp += 1
        return r

    elif broadcast_type == 1:
        # ACCESS_DEFINE
        bp = 4
        r = {'type': 'ACCESS_DEFINE'}
        r['Fill_bit_indication'] = extract_bits(bits, bp, 1); bp += 1
        r['Encryption_mode'] = extract_bits(bits, bp, 2); bp += 2
        r['Random_access_flag'] = extract_bits(bits, bp, 1); bp += 1
        if r['Random_access_flag']:
            r['Access_code'] = extract_bits(bits, bp, 4); bp += 4
            r['Immediate'] = extract_bits(bits, bp, 1); bp += 1
            r['Waiting_time'] = extract_bits(bits, bp, 4); bp += 4
            r['Num_random_access_tx'] = extract_bits(bits, bp, 4); bp += 4
            r['Frame_length_factor'] = extract_bits(bits, bp, 1); bp += 1
            r['Timeslot_pointer'] = extract_bits(bits, bp, 4); bp += 4
            r['Min_priority'] = extract_bits(bits, bp, 3); bp += 3
        return r

    else:
        return {'type': f'broadcast_type_{broadcast_type}'}


def _try_decode_bsch(dibits, sb1_off, sts_off):
    """Try to decode BSCH from burst dibits using given SB layout offsets."""
    sb1_start = sb1_off - 1
    sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]
    if len(sb1_dibits) < SDB_SB1_LEN:
        return None
    sb1_bits = np.zeros(SDB_SB1_LEN * 2, dtype=np.int32)
    for j, d in enumerate(sb1_dibits):
        sb1_bits[2*j] = (int(d) >> 1) & 1
        sb1_bits[2*j+1] = int(d) & 1
    type4 = descramble_bsch(sb1_bits)
    type3 = etsi_deinterleave_bsch(type4)
    type2 = etsi_viterbi_decode_r23(type3)
    info_crc = type2[:SYSINFO_BITS + 16]
    modes = crc16_modes(info_crc)
    if modes['dll'] or modes['raw'] or modes['inverted']:
        return parse_sysinfo(info_crc[:SYSINFO_BITS])
    return None


def _bnch_crc16_check(bits140):
    """CRC-16 CCITT check for BNCH: 124 info + 16 FCS bits."""
    from decode_sb import crc16_bits, CRC_INIT, CRC_POLY
    info = np.asarray(bits140[:BNCH_INFO_BITS], dtype=np.int32)
    rx_fcs = np.asarray(bits140[BNCH_INFO_BITS:BNCH_INFO_BITS + 16], dtype=np.int32)
    calc_fcs = crc16_bits(info)
    return bool(np.array_equal(rx_fcs, calc_fcs))


def _descramble_soft(soft_bits, scrambler_init, n):
    """Descramble soft values: flip sign where scrambler bit = 1."""
    scr = scrambler_seq(scrambler_init, n)
    out = soft_bits.copy()
    for i in range(n):
        if scr[i]:
            out[i] = -out[i]
    return out


def _try_decode_bnch(dibits, bkn2_off, scrambler_init, debug=False,
                     soft_bits_all=None):
    """Try to decode BNCH (bkn2) from burst dibits at given offset.
    If soft_bits_all is provided, tries soft Viterbi first."""
    bkn2_start = bkn2_off - 1

    # --- Soft decode path ---
    if soft_bits_all is not None:
        sb_start = bkn2_start * 2  # soft_bits has 2 per dibit
        sb_end = sb_start + BNCH_CODED_BITS
        if sb_end <= len(soft_bits_all):
            soft_coded = soft_bits_all[sb_start:sb_end].copy()
            soft_descr = _descramble_soft(soft_coded, scrambler_init, BNCH_CODED_BITS)
            soft_deint = etsi_deinterleave_bnch_soft(soft_descr)
            soft_depunct, is_erasure = etsi_depuncture_r23_bnch_soft(soft_deint)
            decoded = etsi_viterbi_decode_r14_soft(soft_depunct, is_erasure)

            info_crc = decoded[:BNCH_INFO_BITS + 16]
            if crc16_check_dll(info_crc):
                pdu = parse_bnch_pdu(decoded[:BNCH_INFO_BITS])
                return pdu, 'soft'

            if debug:
                crc = 0xFFFF
                for b in info_crc:
                    feedback = (int(b) & 1) ^ (crc & 1)
                    crc >>= 1
                    if feedback:
                        crc ^= 0x8408
                mac = extract_bits(decoded, 0, 2)
                bc = extract_bits(decoded, 2, 2)
                print(f"    [soft] mac={mac} bc={bc} crc_rem=0x{crc:04X} "
                      f"bits={decoded[:20].tolist()}")

    # --- Hard decode path (fallback) ---
    bkn2_dibits = dibits[bkn2_start:bkn2_start + SDB_BKN2_LEN]
    if len(bkn2_dibits) < SDB_BKN2_LEN:
        return None, None
    bkn2_bits = np.zeros(BNCH_CODED_BITS, dtype=np.int32)
    for j, d in enumerate(bkn2_dibits):
        bkn2_bits[2*j] = (int(d) >> 1) & 1
        bkn2_bits[2*j+1] = int(d) & 1

    descrambled = (bkn2_bits ^ scrambler_seq(scrambler_init, BNCH_CODED_BITS)) & 1
    deinterleaved = etsi_deinterleave_bnch(descrambled)
    depunctured = etsi_depuncture_r23_bnch(deinterleaved)
    decoded = etsi_viterbi_decode_r14_with_erasures(depunctured)

    info_crc = decoded[:BNCH_INFO_BITS + 16]
    if crc16_check_dll(info_crc):
        pdu = parse_bnch_pdu(decoded[:BNCH_INFO_BITS])
        return pdu, 'dll'

    if debug:
        crc = 0xFFFF
        for b in info_crc:
            feedback = (int(b) & 1) ^ (crc & 1)
            crc >>= 1
            if feedback:
                crc ^= 0x8408
        mac = extract_bits(decoded, 0, 2)
        bc = extract_bits(decoded, 2, 2)
        print(f"    [cell] mac={mac} bc={bc} crc_rem=0x{crc:04X} "
              f"bits={decoded[:20].tolist()}")

    return None, None


def _try_decode_aach(dibits, bb_off):
    """Decode BB (AACH) from 15 dibit symbols via RM(30,14) soft decode."""
    bb_start = bb_off - 1
    bb_dibits = dibits[bb_start:bb_start + SDB_BB_LEN]
    if len(bb_dibits) < SDB_BB_LEN:
        return None
    bb_bits = np.zeros(30, dtype=np.int32)
    for j, d in enumerate(bb_dibits):
        bb_bits[2*j] = (int(d) >> 1) & 1
        bb_bits[2*j+1] = int(d) & 1

    # Descramble BB with cell-identity (same as BKN)
    # BB is 30 bits; we need scrambler sequence for 30 bits
    # Actually BB is descrambled separately — let's return raw for now
    return {
        'raw_bits': bb_bits.tolist(),
        'hex': ''.join(str(b) for b in bb_bits),
    }


# Layout table: (name, sb1_offset, sts_offset, bb_offset, bkn2_offset)
LAYOUTS = [
    ("SDB (continuous)", SDB_OFF_SB1, SDB_OFF_STS, SDB_OFF_BB, SDB_OFF_BKN2),
    ("SB  (non-cont.)",  NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2),
]


def decode_bnch_from_wav(filename, sample_rate=2048000, max_bursts=50,
                         verbose=False, swap_iq=False, conjugate=False):
    print(f"=== TETRA Full Burst Decoder (BSCH + BNCH + AACH) ===")
    print(f"File: {filename}")

    iq, detected_rate, input_fmt = load_iq_file(filename, swap_iq=swap_iq)
    print(f"Input: {input_fmt}, {len(iq)} samples")
    if detected_rate:
        sample_rate = detected_rate
    print(f"Sample rate: {sample_rate}")

    if conjugate:
        iq = np.conj(iq)

    # Freq correction
    freq_offset = estimate_freq_offset(iq, sample_rate)
    print(f"Freq offset: {freq_offset:+.1f} Hz")
    if abs(freq_offset) > 10:
        t = np.arange(len(iq)) / sample_rate
        iq = iq * np.exp(-1j * 2 * np.pi * freq_offset * t)

    # Decimate
    sps_target = 8
    target_rate = SYMBOL_RATE * sps_target
    decim = max(1, int(sample_rate / target_rate))
    actual_rate = sample_rate / decim
    sps = actual_rate / SYMBOL_RATE

    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sample_rate
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2))
        h *= np.hanning(ntaps)
        h /= np.sum(h)
        iq = np.convolve(iq, h, mode='same')[::decim]
    print(f"Decimated: {decim}x -> {actual_rate:.0f} Hz, {sps:.2f} sps")

    # RRC
    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = rrc_filter(rrc_ntaps, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')

    # Find STS
    peaks = find_sync_bursts(iq, sps, min_corr=0.35)
    if not peaks:
        print("No STS found.")
        return
    print(f"Found {len(peaks)} STS candidates")

    # Step 1: detect burst layout and decode BSCH
    print("\n--- Step 1: Detect layout + decode BSCH for scrambler seed ---")
    mcc, mnc, cc = None, None, None
    best_layout = None

    for layout_name, sb1_off, sts_off, bb_off, bkn2_off in LAYOUTS:
        for sts_offset, corr in peaks[:20]:
            burst_start = sts_offset - int(sts_off * sps)
            burst_end = burst_start + int(SB_TOTAL * sps)
            if burst_start < 0 or burst_end > len(iq):
                continue
            sym_indices = np.round(np.arange(SB_TOTAL) * sps + burst_start).astype(int)
            sym_indices = np.clip(sym_indices, 0, len(iq) - 1)
            burst_syms = iq[sym_indices]

            slope, intercept = estimate_freq_from_sts(
                iq[burst_start:burst_end], sps, int(sts_off * sps))
            n_rel = np.arange(SB_TOTAL, dtype=np.float64) - float(sts_off)
            phase_corr = intercept * n_rel + 0.5 * slope * n_rel * (n_rel - 1.0)
            burst_syms = burst_syms * np.exp(-1j * phase_corr)

            dibits = demod_pi4dqpsk(burst_syms)
            info = _try_decode_bsch(dibits, sb1_off, sts_off)
            if info:
                mcc = info['MCC']
                mnc = info['MNC']
                cc = info['ColorCode']
                best_layout = (layout_name, sb1_off, sts_off, bb_off, bkn2_off)
                print(f"Layout: {layout_name}")
                print(f"BSCH decoded: SC={info['SystemCode']} CC={cc} MCC={mcc} MNC={mnc}")
                print(f"  TN={info['TimeSlot']} FN={info['Frame']} MF={info['MultiFrame']}")
                break
        if mcc is not None:
            break

    if mcc is None:
        print("ERROR: Could not decode BSCH for scrambler seed")
        return

    scrambler_init = create_scrambler_code(mcc, mnc, cc)
    print(f"Scrambler init: 0x{scrambler_init:08X}")

    layout_name, sb1_off, sts_off, bb_off, bkn2_off = best_layout

    # Step 2: Decode all bursts
    n_total = min(len(peaks), max_bursts)
    print(f"\n--- Step 2: Decode {n_total} bursts [{layout_name}] ---")
    print(f"{'#':>4s} {'corr':>5s} {'SC':>2s} {'CC':>2s} {'TN':>2s} {'FN':>3s} {'MF':>3s}  "
          f"{'BSCH':>4s}  {'BNCH':>4s}  {'BNCH PDU':<16s}  Details")
    print("=" * 110)

    n_bsch_ok = 0
    n_bnch_ok = 0
    n_sysinfo = 0
    n_access = 0
    n_other = 0
    n_crc_fail = 0
    sysinfo_data = []

    for burst_idx, (sts_offset, corr) in enumerate(peaks[:max_bursts]):
        burst_start = sts_offset - int(sts_off * sps)
        burst_end = burst_start + int(SB_TOTAL * sps)
        if burst_start < 0 or burst_end > len(iq):
            continue

        sym_indices = np.round(np.arange(SB_TOTAL) * sps + burst_start).astype(int)
        sym_indices = np.clip(sym_indices, 0, len(iq) - 1)
        burst_syms = iq[sym_indices]

        slope, intercept = estimate_freq_from_sts(
            iq[burst_start:burst_end], sps, int(sts_off * sps))
        n_rel = np.arange(SB_TOTAL, dtype=np.float64) - float(sts_off)
        phase_corr = intercept * n_rel + 0.5 * slope * n_rel * (n_rel - 1.0)
        burst_syms = burst_syms * np.exp(-1j * phase_corr)

        # Decision-directed phase refinement: use hard decisions to estimate
        # residual phase across full burst, then re-correct
        dibits, soft_bits = demod_pi4dqpsk_soft(burst_syms)
        constellation = np.array([np.pi/4, 3*np.pi/4, -np.pi/4, -3*np.pi/4])  # 00,01,10,11
        dphi = np.angle(burst_syms[1:] * np.conj(burst_syms[:-1]))
        decided_phase = constellation[dibits]
        residuals = np.angle(np.exp(1j * (dphi - decided_phase)))
        # Smooth residual with running average (window ~30 symbols)
        win = min(31, len(residuals) // 4)
        if win >= 3:
            kernel = np.ones(win) / win
            smooth_res = np.convolve(residuals, kernel, mode='same')
            # Cumulative sum of smoothed differential residual = absolute phase correction
            cum_corr = np.cumsum(smooth_res)
            # Apply as additional phase correction to symbols (offset by 1 since diff has n-1 elements)
            phase_refine = np.zeros(len(burst_syms))
            phase_refine[1:] = cum_corr
            burst_syms_refined = burst_syms * np.exp(-1j * phase_refine)
            dibits, soft_bits = demod_pi4dqpsk_soft(burst_syms_refined)

        # BSCH
        bsch_info = _try_decode_bsch(dibits, sb1_off, sts_off)
        bsch_tag = 'OK' if bsch_info else 'FAIL'
        if bsch_info:
            n_bsch_ok += 1
            sc = bsch_info.get('SystemCode', '?')
            cc_val = bsch_info.get('ColorCode', '?')
            tn = bsch_info.get('TimeSlot', '?')
            fn = bsch_info.get('Frame', '?')
            mf = bsch_info.get('MultiFrame', '?')
        else:
            sc = cc_val = tn = fn = mf = '?'

        # BNCH (try soft + hard)
        pdu, crc_tag = _try_decode_bnch(dibits, bkn2_off, scrambler_init,
                                        debug=(bsch_info is not None),
                                        soft_bits_all=soft_bits)
        if pdu:
            n_bnch_ok += 1
            pdu_type = pdu.get('type', '?')
            if pdu_type == 'SYSINFO':
                n_sysinfo += 1
                sysinfo_data.append(pdu)
                detail = f"Carrier={pdu['Main_Carrier']} Band={pdu['Frequency_Band']} " \
                         f"LA={pdu['Location_Area']} HF={pdu.get('Hyperframe','?')}"
            elif pdu_type == 'ACCESS_DEFINE':
                n_access += 1
                detail = f"AC={pdu.get('Access_code','?')} IMM={pdu.get('Immediate','?')} " \
                         f"WT={pdu.get('Waiting_time','?')} Retries={pdu.get('Num_random_access_tx','?')}"
            else:
                n_other += 1
                detail = str(pdu)
            bnch_tag = crc_tag
        else:
            n_crc_fail += 1
            pdu_type = ''
            detail = ''
            bnch_tag = 'FAIL'

        print(f"{burst_idx:4d} {corr:5.3f} {sc:>2} {cc_val:>2} {tn:>2} {fn:>3} {mf:>3}  "
              f"{bsch_tag:>4s}  {bnch_tag:>4s}  {pdu_type:<16s}  {detail}")

    print("=" * 110)
    total = n_bnch_ok + n_crc_fail
    print(f"BSCH: {n_bsch_ok}/{n_total} OK  |  "
          f"BNCH: {n_bnch_ok}/{total} OK  (SYSINFO: {n_sysinfo}  ACCESS_DEFINE: {n_access}  "
          f"Other: {n_other}  CRC_FAIL: {n_crc_fail})")

    # Print first SYSINFO in detail
    if sysinfo_data:
        print(f"\n--- First SYSINFO PDU (full decode) ---")
        for k, v in sysinfo_data[0].items():
            print(f"  {k:30s} = {v}")
        # Compute DL frequency
        si = sysinfo_data[0]
        dl_freq = si['Frequency_Band'] * 100_000_000 + si['Main_Carrier'] * 25_000
        offset_val = si.get('Offset', 0)
        if offset_val == 1: dl_freq += 6250
        elif offset_val == 2: dl_freq -= 6250
        elif offset_val == 3: dl_freq += 12500
        print(f"  {'DL Frequency (Hz)':30s} = {dl_freq}")
        print(f"  {'DL Frequency (MHz)':30s} = {dl_freq / 1e6:.6f}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='TETRA BNCH (bkn2) Decoder')
    parser.add_argument('input', help='WAV or IQ file')
    parser.add_argument('--sr', type=int, default=2048000)
    parser.add_argument('--max-bursts', type=int, default=100)
    parser.add_argument('-v', '--verbose', action='store_true')
    parser.add_argument('--swap-iq', action='store_true')
    parser.add_argument('--conjugate', action='store_true')
    args = parser.parse_args()

    decode_bnch_from_wav(args.input, args.sr, args.max_bursts,
                         args.verbose, args.swap_iq, args.conjugate)
