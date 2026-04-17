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
    SDB_OFF_BKN2, SDB_BKN2_LEN, SDB_OFF_SB1, SDB_SB1_LEN,
    BSCH_CODED_BITS, SYSINFO_BITS,
    etsi_deinterleave_bsch, etsi_depuncture_r23, etsi_viterbi_decode_r23,
    descramble_bsch, parse_sysinfo,
)
import numpy as np
import argparse

# BNCH constants
BNCH_INFO_BITS = 124
BNCH_CODED_BITS = 216  # type-5
BNCH_INTERL_K = 216
BNCH_INTERL_A = 101


def create_scrambler_code(mcc, mnc, cc):
    """SDR# CreateScramblerCode(mcc, mnc, colour) — verified from DLL."""
    return ((mcc & 0x3FF) << 22) | ((mnc & 0x3FFF) << 8) | ((cc & 0x3F) << 2) | 3


def etsi_deinterleave_bnch(bits):
    """Multiplicative de-interleave K=216, a=101."""
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


def decode_bnch_from_wav(filename, sample_rate=2048000, max_bursts=50,
                         verbose=False, swap_iq=False, conjugate=False):
    print(f"=== TETRA BNCH (bkn2) Decoder ===")
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

    # First: decode BSCH to get MCC/MNC/CC for scrambler
    print("\n--- Step 1: Decode BSCH for scrambler seed ---")
    mcc, mnc, cc = None, None, None
    for sts_offset, corr in peaks[:10]:
        burst_start = sts_offset - int(SDB_OFF_STS * sps)
        burst_end = burst_start + int(SB_TOTAL * sps)
        if burst_start < 0 or burst_end > len(iq):
            continue
        sym_indices = np.round(np.arange(SB_TOTAL) * sps + burst_start).astype(int)
        sym_indices = np.clip(sym_indices, 0, len(iq) - 1)
        burst_syms = iq[sym_indices]

        # Phase correction from STS
        slope, intercept = estimate_freq_from_sts(
            iq[burst_start:burst_end], sps, int(SDB_OFF_STS * sps))
        n_rel = np.arange(SB_TOTAL, dtype=np.float64) - float(SDB_OFF_STS)
        phase_corr = intercept * n_rel + 0.5 * slope * n_rel * (n_rel - 1.0)
        burst_syms = burst_syms * np.exp(-1j * phase_corr)

        # Demod sb1
        dibits = demod_pi4dqpsk(burst_syms)
        sb1_start = SDB_OFF_SB1 - 1
        sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]
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
            info = parse_sysinfo(info_crc[:SYSINFO_BITS])
            mcc = info['MCC']
            mnc = info['MNC']
            cc = info['ColorCode']
            print(f"BSCH decoded: MCC={mcc} MNC={mnc} CC={cc}")
            break

    if mcc is None:
        print("ERROR: Could not decode BSCH for scrambler seed")
        return

    scrambler_init = create_scrambler_code(mcc, mnc, cc)
    print(f"Scrambler init: 0x{scrambler_init:08X}")

    # Step 2: Decode BKN2 from each burst
    print(f"\n--- Step 2: Decode BKN2 from {min(len(peaks), max_bursts)} bursts ---")
    print(f"{'#':>4s}  {'FN':>3s} {'MF':>3s}  {'CRC':>4s}  {'PDU Type':<16s}  Details")
    print("-" * 80)

    n_sysinfo = 0
    n_access = 0
    n_other = 0
    n_crc_fail = 0

    for burst_idx, (sts_offset, corr) in enumerate(peaks[:max_bursts]):
        burst_start = sts_offset - int(SDB_OFF_STS * sps)
        burst_end = burst_start + int(SB_TOTAL * sps)
        if burst_start < 0 or burst_end > len(iq):
            continue

        sym_indices = np.round(np.arange(SB_TOTAL) * sps + burst_start).astype(int)
        sym_indices = np.clip(sym_indices, 0, len(iq) - 1)
        burst_syms = iq[sym_indices]

        # Phase correction
        slope, intercept = estimate_freq_from_sts(
            iq[burst_start:burst_end], sps, int(SDB_OFF_STS * sps))
        n_rel = np.arange(SB_TOTAL, dtype=np.float64) - float(SDB_OFF_STS)
        phase_corr = intercept * n_rel + 0.5 * slope * n_rel * (n_rel - 1.0)
        burst_syms = burst_syms * np.exp(-1j * phase_corr)

        # Also decode BSCH for frame number
        dibits = demod_pi4dqpsk(burst_syms)
        sb1_start = SDB_OFF_SB1 - 1
        sb1_dibits = dibits[sb1_start:sb1_start + SDB_SB1_LEN]
        sb1_bits = np.zeros(SDB_SB1_LEN * 2, dtype=np.int32)
        for j, d in enumerate(sb1_dibits):
            sb1_bits[2*j] = (int(d) >> 1) & 1
            sb1_bits[2*j+1] = int(d) & 1
        type4_sb1 = descramble_bsch(sb1_bits)
        type3_sb1 = etsi_deinterleave_bsch(type4_sb1)
        type2_sb1 = etsi_viterbi_decode_r23(type3_sb1)
        bsch_info = parse_sysinfo(type2_sb1[:SYSINFO_BITS])
        fn = bsch_info['Frame'] if bsch_info else '?'
        mf = bsch_info['MultiFrame'] if bsch_info else '?'

        # Extract bkn2 (108 dibits = 216 bits)
        bkn2_start = SDB_OFF_BKN2 - 1
        bkn2_dibits = dibits[bkn2_start:bkn2_start + SDB_BKN2_LEN]
        if len(bkn2_dibits) < SDB_BKN2_LEN:
            continue
        bkn2_bits = np.zeros(BNCH_CODED_BITS, dtype=np.int32)
        for j, d in enumerate(bkn2_dibits):
            bkn2_bits[2*j] = (int(d) >> 1) & 1
            bkn2_bits[2*j+1] = int(d) & 1

        # Descramble with cell-identity
        descrambled = (bkn2_bits ^ scrambler_seq(scrambler_init, BNCH_CODED_BITS)) & 1

        # Deinterleave K=216, a=101
        deinterleaved = etsi_deinterleave_bnch(descrambled)

        # Depuncture + Viterbi
        depunctured = etsi_depuncture_r23_bnch(deinterleaved)
        decoded = etsi_viterbi_decode_r14_with_erasures(depunctured)

        # CRC check on first 124+16=140 bits
        info_crc = decoded[:BNCH_INFO_BITS + 16]
        modes = crc16_modes(info_crc)
        crc_ok = modes['dll'] or modes['raw'] or modes['inverted']

        if crc_ok:
            pdu = parse_bnch_pdu(decoded[:BNCH_INFO_BITS])
            pdu_type = pdu.get('type', '?') if pdu else '?'

            if pdu_type == 'SYSINFO':
                n_sysinfo += 1
                detail = f"Carrier={pdu['Main_Carrier']} Band={pdu['Frequency_Band']} " \
                         f"LA={pdu['Location_Area']} HF={pdu.get('Hyperframe','?')}"
            elif pdu_type == 'ACCESS_DEFINE':
                n_access += 1
                detail = f"AC={pdu.get('Access_code','?')} IMM={pdu.get('Immediate','?')} " \
                         f"WT={pdu.get('Waiting_time','?')}"
            else:
                n_other += 1
                detail = str(pdu)

            crc_tag = modes['dll'] and 'dll' or modes['raw'] and 'raw' or 'inv'
            print(f"{burst_idx:4d}  {fn:>3}  {mf:>3}  {crc_tag:>4s}  {pdu_type:<16s}  {detail}")
        else:
            n_crc_fail += 1
            if verbose:
                print(f"{burst_idx:4d}  {fn:>3}  {mf:>3}  FAIL")

    print("-" * 80)
    total = n_sysinfo + n_access + n_other + n_crc_fail
    print(f"Total: {total} bursts  |  SYSINFO: {n_sysinfo}  ACCESS_DEFINE: {n_access}  "
          f"Other: {n_other}  CRC_FAIL: {n_crc_fail}")


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
