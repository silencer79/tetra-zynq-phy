#!/usr/bin/env python3
"""
decode_ul.py — Decode MS uplink Random-Access bursts from SDR WAV.

Pipeline:
  1. Load WAV + RRC matched filter + freq offset correct (from verify_ul_ra_burst)
  2. Detect bursts via power threshold
  3. Per burst: sub-symbol refine on x-sequence → anchor
  4. Demod 127 symbols centered on anchor → 254 bits
  5. Extract blk1 (108 bits before x) + blk2 (108 bits after x)
  6. Descramble with cell scrambling code
  7. Try SCH/HU channel decode (K=168, a=13, info=92) across hypotheses
     of which 168 bits of the 216-bit payload are type-5 coded

Usage:
    python3 scripts/decode_ul.py <wavfile> [--cc 49 --mcc 901 --mnc 9998]
"""
import argparse
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, load_iq_file, estimate_freq_offset, rrc_filter,
    dibits_to_bits, make_scramb_code,
    decode_channel_soft, demod_pi4dqpsk_soft,
    _build_diff_ref, _correlate_at,
    extract_bits, parse_llc,
)


def estimate_freq_offset_dqpsk(iq, sample_rate,
                               burst_threshold_db=7.0,
                               channel_bw_hz=25000.0):
    """CFO for π/4-DQPSK via burst-gated passband centroid.

    Bursty UL signals (MS RA / SCH/HU) have <1 % duty cycle, so the
    broadband `estimate_freq_offset` picks noise bins between bursts.
    Power-law methods (s⁴, s⁸) fail on oversampled IQ because
    consecutive samples are RRC-correlated, not independent symbols.

    This estimator:
      1. Gates IQ to high-power samples (rolling-power >threshold_dB
         above median floor) — silence set to zero
      2. Full-length FFT of the gated stream
      3. Finds the 25-kHz-wide window with maximum integrated energy
         (TETRA channel bandwidth, §9.1)
      4. Reports the power-weighted centroid of that window = carrier

    Searches the full ±sample_rate/2 baseband; the 25-kHz window is
    the signal passband width, not a search constraint.
    """
    iq = np.asarray(iq, dtype=np.complex128)
    if len(iq) < 2048:
        return float(estimate_freq_offset(iq, sample_rate))

    # 1) Burst-gate: keep rolling-power > threshold above median noise
    win = 1024
    pwr = np.abs(iq) ** 2
    mp = np.convolve(pwr, np.ones(win) / win, mode='same')
    floor = float(np.median(mp)) + 1e-12
    thr = floor * (10.0 ** (burst_threshold_db / 10.0))
    mask = mp > thr
    if mask.sum() < 256:
        iq_gated = iq.copy()  # fallback: no strong bursts found
    else:
        iq_gated = iq.copy()
        iq_gated[~mask] = 0.0

    # 2) Full FFT of gated signal — bursts may be scattered across 30+ s
    nfft = len(iq_gated)
    spec = np.abs(np.fft.fft(iq_gated)) ** 2
    freqs = np.fft.fftfreq(nfft, 1.0 / sample_rate)

    # Sort into ascending frequency for sliding-window integration
    order = np.argsort(freqs)
    freqs_s = freqs[order]
    spec_s = spec[order]

    # 3) Rolling sum over 25-kHz window across full ±sample_rate/2
    df = freqs_s[1] - freqs_s[0]
    w_bins = max(4, int(round(channel_bw_hz / df)))
    if w_bins >= len(spec_s):
        w_bins = len(spec_s) - 1
    cs = np.concatenate([[0.0], np.cumsum(spec_s, dtype=np.float64)])
    win_energy = cs[w_bins:] - cs[:-w_bins]
    best = int(np.argmax(win_energy))

    # 4) Power-weighted centroid of highest-energy 25-kHz window
    band = spec_s[best:best + w_bins]
    band_f = freqs_s[best:best + w_bins]
    total = band.sum()
    if total <= 0.0:
        return float((band_f[0] + band_f[-1]) * 0.5)
    return float((band * band_f).sum() / total)


from decode_dl import scrambler_seq as scrambler_seq_etsi


def descramble_soft_etsi(soft_bits, init, length):
    """Reuse canonical osmo-tetra / decode_dl scrambler.
    ETSI §8.2.5.2 polynomial — taps per osmo-tetra tetra_scramb.c ST(x,32-y)
    convention: [0,6,9,10,16,20,21,22,24,25,27,28,30,31]."""
    scr = scrambler_seq_etsi(init, length)
    return soft_bits * (1.0 - 2.0 * scr)
from verify_ul_ra_burst import X_DIBITS, X_DIFF_REF, find_bursts


# ETSI §9.4.4.2.1 Table 9.3 — Control Uplink Burst (CB, π/4-DQPSK):
#   tail(4b=2sym) + cb1(84b=42sym) + x(30b=15sym) + cb2(84b=42sym) + tail(4b=2sym)
#   = 206 bits = 103 symbols.  cb1+cb2 = 168 bits = SCH/HU type-5.
#
# Observed: verify_ul_ra_burst x-offset ~53.3 sym from power-detected start;
# burst_len 81-116 sym.  If CB (103 sym), x expected at sym 2+42=44 from absolute
# burst start.  Offset 53.3 = 9 sym into the burst → power-detection likely
# triggers 9 sym late OR the burst is longer.  Two candidate layouts supported.
RA_CB_SYMS    = 42       # CB half-block (SCH/HU = 168 type-5 bits)
RA_NUB_SYMS   = 54       # NUB/RAB half-block (216 type-5 bits)
RA_X_SYMS     = 15
RA_TAIL_SYMS  = 2


def refine_x_position(iq, sps, coarse_pos, search_syms=5):
    """Find precise sub-symbol position of x-sequence.
    Returns (best_pos, best_corr)."""
    best_c = 0.0
    best_pos = coarse_pos
    # Fine search ±search_syms around coarse_pos, step = sps/16
    step = max(1, sps / 16.0)
    n = int(round(2 * search_syms * sps / step))
    for k in range(-n // 2, n // 2 + 1):
        pos = coarse_pos + k * step
        c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
        if c > best_c:
            best_c = c
            best_pos = pos
    return best_pos, best_c


def demod_pi4dqpsk_soft_etsi(symbols):
    """ETSI soft π/4-DQPSK differential demod.
    Per EN 300 392-2 §5.5.1 Table 5.3 (osmo-tetra pi4map=[1,3,7,5]):
      dibit 00 → +π/4     (sin>0, cos>0)
      dibit 01 → +3π/4    (sin>0, cos<0)
      dibit 10 → −π/4     (sin<0, cos>0)
      dibit 11 → −3π/4    (sin<0, cos<0)
    → b1 (MSB) = 1 when sin(dφ)<0  →  soft_b1 = sin(dφ)
    → b0 (LSB) = 1 when cos(dφ)<0  →  soft_b0 = cos(dφ)
    Returns soft[2N-2]: positive=0, negative=1.
    """
    dphi = np.angle(symbols[1:] * np.conj(symbols[:-1]))
    soft = np.empty(len(dphi) * 2, dtype=np.float64)
    soft[0::2] = np.sin(dphi)  # b1 (MSB)
    soft[1::2] = np.cos(dphi)  # b0 (LSB)
    return soft


# Expected differential phases for the 15-dibit x-sequence (ETSI Table 5.1):
#   00 → +π/4, 01 → +3π/4, 10 → −π/4, 11 → −3π/4
_DIBIT_PHASE = {0: np.pi/4, 1: 3*np.pi/4, 2: -np.pi/4, 3: -3*np.pi/4}
X_EXPECTED_DPHI = np.array([_DIBIT_PHASE[d] for d in X_DIBITS])  # 15 values


def estimate_burst_cfo(iq, sps, x_start_pos, linear=True):
    """Per-burst residual CFO estimate using the known x-sequence as pilot.
    linear=False: fit constant Δφ/sym  → returns (A, 0.0)
    linear=True : fit linear chirp     → returns (A, B) where err(k)=A+B·k
                  (catches intra-burst frequency drift from osc pulling / Doppler).
    Apply derotation exp(-j·(A·n + 0.5·B·n²)) to sample at symbol index n.
    """
    x_idx = np.round(x_start_pos + np.arange(RA_X_SYMS) * sps).astype(int)
    if x_idx[0] < 0 or x_idx[-1] >= len(iq):
        return 0.0, 0.0
    x_syms = iq[x_idx]
    obs_dphi = np.angle(x_syms[1:] * np.conj(x_syms[:-1]))  # 14 transitions
    # Residual = obs - expected (wrapped to [-π,π])
    err = np.angle(np.exp(1j * (obs_dphi - X_EXPECTED_DPHI[1:])))
    if not linear:
        return float(np.median(err)), 0.0
    # Linear fit err(k) = A + B·k (least-squares on 14 points k=0..13)
    k = np.arange(len(err), dtype=np.float64)
    # Use linalg to be robust against outliers with huber-like reweighting:
    #   first pass polyfit, then mask residuals > π/3, refit.
    B, A = np.polyfit(k, err, 1)          # polyfit returns highest-order first
    resid = err - (A + B * k)
    mask = np.abs(resid) < (np.pi / 3)
    if mask.sum() >= 4:
        B, A = np.polyfit(k[mask], err[mask], 1)
    return float(A), float(B)


def sample_half_soft_bits(iq, sps, x_start_pos, half_syms, cfo_A=0.0, cfo_B=0.0):
    """Sample soft-demod bits for blk1+blk2 surrounding the x-sequence.
    x_start_pos = sample position where x-sequence begins.
    half_syms   = number of symbols per half-block (42 for CB, 54 for NUB/RAB).
    cfo_A, cfo_B = per-symbol residual  err(k) = A + B·k  (from x-pilot fit).
                  Derotation at sym index n: exp(-j·(A·n + 0.5·B·n²)).
    For differential demod, sample one extra reference symbol before each block.
    Returns (blk1_soft[2·half_syms], blk2_soft[2·half_syms]).
    """
    def derotate(syms, k_vec):
        return syms * np.exp(-1j * (cfo_A * k_vec + 0.5 * cfo_B * k_vec * k_vec))

    # Symbol indices relative to x_start: -half_syms-1..-1 for blk1 ref+data
    blk1_sym_k = np.arange(-half_syms - 1, 0, dtype=np.float64)
    blk1_idx = np.round(x_start_pos + blk1_sym_k * sps).astype(int)
    blk1_idx = np.clip(blk1_idx, 0, len(iq) - 1)
    blk1_syms = derotate(iq[blk1_idx], blk1_sym_k)
    blk1_soft = demod_pi4dqpsk_soft_etsi(blk1_syms)

    # blk2 ref = last x sym (sym RA_X_SYMS-1 relative to x_start), then blk2 data
    blk2_sym_k = np.arange(RA_X_SYMS - 1, RA_X_SYMS + half_syms, dtype=np.float64)
    blk2_idx = np.round(x_start_pos + blk2_sym_k * sps).astype(int)
    blk2_idx = np.clip(blk2_idx, 0, len(iq) - 1)
    blk2_syms = derotate(iq[blk2_idx], blk2_sym_k)
    blk2_soft = demod_pi4dqpsk_soft_etsi(blk2_syms)

    return blk1_soft, blk2_soft


def try_channel_decode(blk1_soft, blk2_soft, scramb_init, channel):
    """Try decoding the (blk1+blk2) payload under one channel hypothesis.
    channel: 'schhu' (K=168,a=13,info=92), 'schhd' (K=216,a=101,info=124),
             'schf'  (K=432,a=103,info=268).
    Runs order/polarity/scramble hypotheses; returns best result.
    """
    if channel == 'schhu':
        K, a, info = 168, 13, 92
    elif channel == 'schhd':
        K, a, info = 216, 101, 124
    elif channel == 'schf':
        K, a, info = 432, 103, 268
    else:
        raise ValueError(channel)

    len_half = len(blk1_soft)
    if 2 * len_half < K:
        return (False, None, None, None)
    # Trim to K bits from the concatenation (pad or cut)
    def cat_trim(a_, b_):
        s = np.concatenate([a_, b_])
        if len(s) >= K:
            return s[:K]
        out = np.zeros(K, dtype=np.float64)
        out[:len(s)] = s
        return out

    hypotheses = []
    for order_name, s in (('12', cat_trim(blk1_soft, blk2_soft)),
                          ('21', cat_trim(blk2_soft, blk1_soft))):
        for pol_name, pol in (('+', 1.0), ('-', -1.0)):
            for scr_name, use_scr in (('s', True), ('n', False)):
                soft_desc = pol * (descramble_soft_etsi(s, scramb_init, K) if use_scr else s)
                hypotheses.append((f'{channel}_{order_name}{pol_name}{scr_name}',
                                   soft_desc))

    best = (False, None, None, None)
    for name, soft_t5 in hypotheses:
        try:
            crc_ok, info_bits, _ = decode_channel_soft(soft_t5, K=K, a=a, info_bits_len=info)
        except Exception:
            continue
        hard = (soft_t5 < 0).astype(np.int32)
        if crc_ok:
            return True, info_bits, hard, name
        if best[1] is None:
            best = (crc_ok, info_bits, hard, name)
    return best


def try_schhu_decode(cb1_soft, cb2_soft, scramb_init):
    """Legacy entrypoint — tries SCH/HU first, then SCH/HD, then SCH/F."""
    for ch in ('schhu', 'schhd', 'schf'):
        res = try_channel_decode(cb1_soft, cb2_soft, scramb_init, ch)
        if res[0]:
            return res
    return res


def bits_to_hex(bits):
    """Pack MSB-first bits to hex string."""
    bits = list(int(b) for b in bits)
    # Pad to byte boundary
    while len(bits) % 8 != 0:
        bits.append(0)
    out = []
    for i in range(0, len(bits), 8):
        byte = 0
        for b in bits[i:i+8]:
            byte = (byte << 1) | (b & 1)
        out.append(f"{byte:02X}")
    return ' '.join(out)


UL_MLE_PDU_NAMES = {
    0: 'Reserved', 1: 'MM', 2: 'CMCE', 3: 'Reserved',
    4: 'SNDCP', 5: 'MLE', 6: 'TETRA-Mgmt', 7: 'Testing',
}

UL_MM_NAMES = {
    0:  'U-AUTHENTICATION',
    1:  'U-ITSI-DETACH',
    2:  'U-LOC-UPD-DEMAND',
    3:  'U-MM-STATUS',
    4:  'U-CK-CHG-RESULT',
    5:  'U-OTAR',
    6:  'U-INFO-PROVIDE',
    7:  'U-ATTACH-DETACH-GRP-ID',
    8:  'U-ATTACH-DETACH-GRP-ID-ACK',
    9:  'U-TEI-PROVIDE',
    10: 'Reserved',
    11: 'U-DISABLE-STATUS',
    12: 'Reserved',
    13: 'Reserved',
    14: 'Reserved',
    15: 'MM-PDU-FUNC-NOT-SUPPORTED',
}

UL_LOC_UPD_TYPE_NAMES = {
    0: 'Roaming',
    1: 'Migrating',
    2: 'Periodic',
    3: 'ITSI-Attach',
    4: 'Call-Restoration',
}


def parse_ul_mm(bits, pos, mm_type):
    r = {}

    if mm_type == 1:  # U-ITSI-DETACH (Clause 16.9.3.3, MmPduTypeUl::UItsiDetach)
        # Layout (after the 4-bit pdu_type already consumed by caller):
        #   1 bit obit (presence of any further fields)
        #   if obit: optional 24-bit address_extension (with type2-presence bit)
        if pos + 1 <= len(bits):
            obit = extract_bits(bits, pos, 1); pos += 1
            r['optional_fields_present'] = obit
            if obit == 1:
                if pos + 1 <= len(bits):
                    p_ae = extract_bits(bits, pos, 1); pos += 1
                    r['address_extension_present'] = p_ae
                    if p_ae == 1 and pos + 24 <= len(bits):
                        r['address_extension'] = extract_bits(bits, pos, 24); pos += 24
        r['payload_end'] = pos
        return r

    if mm_type == 2:  # U-LOCATION UPDATE DEMAND (per MmPduTypeUl)
        if pos + 3 <= len(bits):
            upd_type = extract_bits(bits, pos, 3); pos += 3
            r['location_update_type'] = upd_type
            r['location_update_type_name'] = UL_LOC_UPD_TYPE_NAMES.get(upd_type, f'Unknown({upd_type})')
        if pos + 1 <= len(bits):
            r['request_to_append_la'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            r['cipher_control'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            o_bit = extract_bits(bits, pos, 1); pos += 1
            r['optional_fields_present'] = o_bit
            if o_bit == 1:
                if pos + 1 <= len(bits):
                    p_class = extract_bits(bits, pos, 1); pos += 1
                    r['class_of_ms_present'] = p_class
                    if p_class == 1 and pos + 24 <= len(bits):
                        r['class_of_ms'] = extract_bits(bits, pos, 24); pos += 24
                if pos + 1 <= len(bits):
                    p_esm = extract_bits(bits, pos, 1); pos += 1
                    r['energy_saving_mode_present'] = p_esm
                    if p_esm == 1 and pos + 3 <= len(bits):
                        r['energy_saving_mode'] = extract_bits(bits, pos, 3); pos += 3
                if pos + 1 <= len(bits):
                    p_lai = extract_bits(bits, pos, 1); pos += 1
                    r['la_information_present'] = p_lai
                    if p_lai == 1 and pos + 14 <= len(bits):
                        r['location_area'] = extract_bits(bits, pos, 14); pos += 14
                if pos + 1 <= len(bits):
                    p_ssi = extract_bits(bits, pos, 1); pos += 1
                    r['ssi_present'] = p_ssi
                    if p_ssi == 1 and pos + 24 <= len(bits):
                        r['ssi'] = extract_bits(bits, pos, 24); pos += 24
                if pos + 1 <= len(bits):
                    p_addr_ext = extract_bits(bits, pos, 1); pos += 1
                    r['address_extension_present'] = p_addr_ext
                    if p_addr_ext == 1 and pos + 24 <= len(bits):
                        r['address_extension'] = extract_bits(bits, pos, 24); pos += 24
                if pos + 1 <= len(bits):
                    r['more_optional_bits'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_end'] = pos
        return r

    if mm_type == 7:  # U-ATTACH/DETACH GROUP ID (per MmPduTypeUl)
        if pos + 1 <= len(bits):
            r['group_identity_report'] = extract_bits(bits, pos, 1); pos += 1
        if pos + 1 <= len(bits):
            r['attach_detach_mode'] = extract_bits(bits, pos, 1); pos += 1
        r['payload_end'] = pos
        return r

    if mm_type == 3:  # U-MM-STATUS (per MmPduTypeUl)
        if pos + 5 <= len(bits):
            r['status_value'] = extract_bits(bits, pos, 5); pos += 5
        r['payload_end'] = pos
        return r

    return r


def parse_ul_mle(bits, pos):
    if pos + 3 > len(bits):
        return {'mle_type': 'TOO_SHORT'}
    disc = extract_bits(bits, pos, 3); pos += 3
    r = {
        'mle_disc': disc,
        'mle_disc_name': UL_MLE_PDU_NAMES.get(disc, '?'),
    }
    if disc == 1 and pos + 4 <= len(bits):  # MM
        mm_type = extract_bits(bits, pos, 4); pos += 4
        r['mm_type'] = mm_type
        r['mm_name'] = UL_MM_NAMES.get(mm_type, f'Unknown({mm_type})')
        r['mm'] = parse_ul_mm(bits, pos, mm_type)
    r['payload_start'] = pos
    return r


def parse_ul_direct_mm(bits, pos):
    """Observed UL MAC-ACCESS layout in local captures: MM starts at bit 23."""
    r = {}
    if pos + 4 > len(bits):
        return r
    mm_type = extract_bits(bits, pos, 4); pos += 4
    r['mm_type'] = mm_type
    r['mm_name'] = UL_MM_NAMES.get(mm_type, f'Unknown({mm_type})')
    r['mm'] = parse_ul_mm(bits, pos, mm_type)
    r['payload_start'] = pos
    return r


_ADDR_TYPE_NAMES = {0: 'Ssi(ISSI)', 1: 'EventLabel', 2: 'Ussi', 3: 'Smi'}


def parse_mac_access(bits92):
    """Parse UL MAC-ACCESS per bluestation `mac_access.rs::from_bitbuf`:
      bit[0]:    mac_pdu_type   (1 bit, must be 0 for MAC-ACCESS)
      bit[1]:    fill_bits      (1 bit)
      bit[2]:    encrypted      (1 bit)
      bits[3..4]: addr_type     (2 bits: 0=ISSI, 1=EventLabel, 2=Ussi, 3=Smi)
      bits[5..]: address        (24 bits for Ssi/Ussi/Smi, 10 bits for EventLabel)
      next bit:  optional_field_flag (1)
        if 1: length_ind_or_cap_req (1)
          if 0: length_ind (5)
          if 1: frag_flag (1), reservation_req (4)
      then: TL-SDU (LLC PDU carrying MLE/direct-MM payload)

    The old parser read addr_type as 3 bits and short_ssi as 10 bits — both
    off-by-N against ETSI / bluestation. This version matches bluestation bit-exact.
    """
    if bits92 is None or len(bits92) < 20:
        return None
    b = [int(x) & 1 for x in bits92]
    mac_pdu_type = b[0]
    fill_bits = b[1]
    out = {'pdu_type': mac_pdu_type, 'fill_bit': fill_bits}
    if mac_pdu_type != 0:
        # Not MAC-ACCESS (could be MAC-FRAG-UL type=01 or MAC-U-BLCK type=11
        # etc.). Keep the flag so the caller can tell these apart.
        out['mac_top_nibble'] = extract_bits(b, 0, 2)
        return out

    out['encrypted'] = b[2]
    addr_type = extract_bits(b, 3, 2)
    out['addr_type'] = addr_type
    out['addr_type_name'] = _ADDR_TYPE_NAMES.get(addr_type, f'Unknown({addr_type})')
    pos = 5
    if addr_type == 1:  # EventLabel
        out['event_label'] = extract_bits(b, pos, 10); pos += 10
    else:  # Ssi (=ISSI), Ussi, Smi all 24 bits
        out['ssi'] = extract_bits(b, pos, 24); pos += 24

    # Optional field(s)
    if pos < len(b):
        opt_flag = b[pos]; pos += 1
        out['optional_field_flag'] = opt_flag
        if opt_flag:
            if pos < len(b):
                lind_or_cap = b[pos]; pos += 1
                if lind_or_cap == 0:
                    if pos + 5 <= len(b):
                        out['length_ind'] = extract_bits(b, pos, 5); pos += 5
                else:
                    if pos + 5 <= len(b):
                        out['frag_flag'] = b[pos]; pos += 1
                        out['reservation_req'] = extract_bits(b, pos, 4); pos += 4

    out['payload_start'] = pos

    # TL-SDU starts at pos. Parse LLC layer.
    if pos + 4 <= len(b):
        llc = parse_llc(b, pos)
        out['llc'] = llc
        llc_payload = llc.get('payload_start')
        if llc_payload is not None and llc_payload + 3 <= len(b):
            mle = parse_ul_mle(b, llc_payload)
            out['mle'] = mle

    # Fallback direct-MM path — for MS's that pack MM-PDU directly behind the
    # MAC header without LLC wrap (L2SigPdu-ähnlich for UL RAs on some firmwares).
    if pos + 4 <= len(b):
        direct_mm = parse_ul_direct_mm(b, pos)
        out['direct_mm'] = direct_mm
        llc_name = out.get('llc', {}).get('llc_type_name', '')
        if (llc_name.startswith('Unknown(') or llc_name == '') and \
                direct_mm.get('mm_name', '').startswith('U-'):
            out['decoded_mode'] = 'direct_mm'
        elif 'mle' in out:
            out['decoded_mode'] = 'llc_mle'
        else:
            out['decoded_mode'] = 'raw'
    return out


def format_parsed_mac_access(parsed):
    if not parsed:
        return 'None'
    parts = [
        f"pdu={parsed.get('pdu_type', '?')}",
        f"fill={parsed.get('fill_bit', '?')}",
    ]
    if parsed.get('pdu_type') == 0:
        parts.append(f"enc={parsed.get('encrypted', '?')}")
        parts.append(f"addr={parsed.get('addr_type_name', '?')}")
        if 'ssi' in parsed:
            parts.append(f"ssi={parsed['ssi']}")
        elif 'event_label' in parsed:
            parts.append(f"ev={parsed['event_label']}")
        if 'frag_flag' in parsed:
            parts.append(f"frag={parsed['frag_flag']}")
        if 'reservation_req' in parsed:
            parts.append(f"res_req={parsed['reservation_req']}")
        if 'length_ind' in parsed:
            parts.append(f"LI={parsed['length_ind']}")
        llc = parsed.get('llc')
        if llc:
            seg = llc.get('llc_type_name', '?')
            if 'ns' in llc:
                seg += f"(NS={llc['ns']})"
            if 'nr' in llc:
                seg += f"(NR={llc['nr']})"
            parts.append(f"LLC={seg}")
        mle = parsed.get('mle')
        if mle:
            seg = mle.get('mle_disc_name', '?')
            if 'mm_name' in mle:
                seg += f"/{mle['mm_name']}"
                mm = mle.get('mm', {})
                if 'location_update_type_name' in mm:
                    seg += f"/{mm['location_update_type_name']}"
            parts.append(f"MLE={seg}")
        direct_mm = parsed.get('direct_mm')
        if direct_mm:
            seg = direct_mm.get('mm_name', '?')
            mm = direct_mm.get('mm', {})
            if 'location_update_type_name' in mm:
                seg += f"/{mm['location_update_type_name']}"
            parts.append(f"DirectMM={seg}")
        if 'decoded_mode' in parsed:
            parts.append(f"mode={parsed['decoded_mode']}")
    return ' '.join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('wav_file')
    ap.add_argument('--cc', type=int, default=49)
    ap.add_argument('--mcc', type=int, default=901)
    ap.add_argument('--mnc', type=int, default=9998)
    ap.add_argument('--threshold-db', type=float, default=15.0)
    ap.add_argument('--swap-iq', action='store_true')
    ap.add_argument('--max-bursts', type=int, default=50)
    ap.add_argument('--dump-bits', action='store_true',
                    help='Print raw descrambled bits for each burst')
    ap.add_argument('--cfo', type=float, default=None,
                    help='Manual CFO override in Hz (skip auto-detection)')
    args = ap.parse_args()

    iq, sr = load_iq_file(args.wav_file, swap_iq=args.swap_iq)
    if sr is None:
        print('ERROR: wav required', file=sys.stderr); return 1
    print(f'WAV: {args.wav_file}  sr={sr}  dur={len(iq)/sr:.2f}s')

    iq = iq / (np.median(np.abs(iq)) + 1e-12)
    if args.cfo is not None:
        f_off = float(args.cfo)
        print(f'  freq offset: {f_off:+.1f} Hz (manual --cfo)')
    else:
        f_off = estimate_freq_offset_dqpsk(iq, sr)
        print(f'  freq offset: {f_off:+.1f} Hz (π/4-DQPSK passband centroid)')
    t = np.arange(len(iq)) / sr
    iq = iq * np.exp(-2j * np.pi * f_off * t)

    # Decimate to ~8 sps
    sps_raw = sr / SYMBOL_RATE
    decim = max(1, int(round(sps_raw / 8)))
    if decim > 1:
        from scipy.signal import decimate
        iq = decimate(iq, decim, ftype='fir')
        sr_dec = sr / decim
    else:
        sr_dec = sr
    sps = sr_dec / SYMBOL_RATE
    print(f'  sps={sps:.3f}')

    # RRC matched filter
    ntaps = int(round(sps)) * 8 + 1
    if ntaps % 2 == 0: ntaps += 1
    h = rrc_filter(ntaps, 0.35, sps)
    iq = np.convolve(iq, h, mode='same')

    # Find bursts
    bursts, noise, thresh = find_bursts(iq, sps, threshold_db=args.threshold_db)
    print(f'  {len(bursts)} bursts detected')
    if not bursts: return 1

    # Cell scrambling init
    scramb_init = make_scramb_code(args.mcc, args.mnc, args.cc)
    print(f'  scrambler init: 0x{scramb_init:08X} (CC={args.cc} MCC={args.mcc} MNC={args.mnc})')
    print()

    crc_hits = 0
    decoded_pdus = []
    type5_patterns = []

    print(f'  {"#":>3} {"time_s":>8} {"corrX":>6} {"A_mrad":>9} {"B_mrad":>9} {"CRC":>4}  {"PDU bytes[0:6]":>20}')
    for i, (s, l) in enumerate(bursts[:args.max_bursts]):
        coarse_search_start = s
        coarse_search_end   = s + l - int(15 * sps)
        best_c = 0
        best_pos = s + int(42 * sps)  # expect x near cb1-end
        step = max(1, int(round(sps / 4)))
        for pos in range(coarse_search_start, coarse_search_end, step):
            c = _correlate_at(iq, pos, sps, X_DIBITS, X_DIFF_REF)
            if c > best_c:
                best_c = c
                best_pos = pos
        x_pos, x_corr = refine_x_position(iq, sps, best_pos, search_syms=2)

        if x_corr < 0.5:
            print(f'  {i:3d} {s/sr_dec:8.3f} {x_corr:6.3f}  SKIP (weak x)')
            continue

        # Per-burst CFO via x-seq pilot (constant fit). Linear-chirp fit was
        # tried but B variance on 14 points extrapolates catastrophically at
        # n=-43..56. Instead: joint grid search over (CFO, fine_timing) around
        # x-seq estimate.
        cfo_A0, _ = estimate_burst_cfo(iq, sps, x_pos, linear=False)

        # CFO grid: ±400 mrad/sym, step 10 mrad (center-out)
        cfo_offsets = [0.0]
        for d in range(1, 41):
            cfo_offsets.append(-0.01 * d)
            cfo_offsets.append(+0.01 * d)
        # Timing grid: ±0.5 sample, step 0.1 sample (center-out)
        tim_offsets = [0.0]
        for d in range(1, 6):
            tim_offsets.append(-0.1 * d)
            tim_offsets.append(+0.1 * d)

        result = (False, None, None, None)
        cfo_A = cfo_A0
        for tim_off in tim_offsets:
            x_pos_try = x_pos + tim_off
            cfo_A0t, _ = estimate_burst_cfo(iq, sps, x_pos_try, linear=False)
            for cfo_off in cfo_offsets:
                cfo_try = cfo_A0t + cfo_off
                blk1_cb, blk2_cb = sample_half_soft_bits(iq, sps, x_pos_try, RA_CB_SYMS, cfo_try, 0.0)
                r = try_channel_decode(blk1_cb, blk2_cb, scramb_init, 'schhu')
                if r[0]:
                    result = r; cfo_A = cfo_try; break
                if result[1] is None:
                    result = r; cfo_A = cfo_try
            if result[0]:
                break
        cfo_B = 0.0
        # Fallback: NUB layout (54-sym half-blocks → SCH/HD 216 or SCH/F 432)
        if not result[0]:
            blk1_nub, blk2_nub = sample_half_soft_bits(iq, sps, x_pos, RA_NUB_SYMS, cfo_A0, 0.0)
            r2 = try_channel_decode(blk1_nub, blk2_nub, scramb_init, 'schhd')
            if r2[0]:
                result = r2
            else:
                r3 = try_channel_decode(blk1_nub, blk2_nub, scramb_init, 'schf')
                if r3[0]:
                    result = r3
        crc_ok, info_bits, type5_hard = result[0], result[1], result[2]
        variant = result[3] if len(result) > 3 and result[3] else ''
        type5_patterns.append(type5_hard if type5_hard is not None else np.zeros(168, dtype=np.int8))

        tag = 'OK' if crc_ok else '-'
        pdu_hex = bits_to_hex(info_bits[:48])[:23] if info_bits is not None else ''
        print(f'  {i:3d} {s/sr_dec:8.3f} {x_corr:6.3f} {cfo_A*1000:+9.2f} {cfo_B*1000:+9.2f} {tag:>4} {variant:>14}  {pdu_hex}')
        if crc_ok:
            crc_hits += 1
            decoded_pdus.append(info_bits)

    print()
    print(f'=== SCH/HU CRC-pass: {crc_hits} / {len(type5_patterns)} ===')

    if type5_patterns:
        arr = np.array(type5_patterns, dtype=np.int8)
        ref = arr[0]
        print()
        print('=== Descrambled type-5 (168 bit) match vs burst #0 ===')
        matches = np.mean(arr == ref, axis=1)
        for i, m in enumerate(matches[:min(20, len(matches))]):
            print(f'  #{i:3d}: {m*100:5.1f}%  hex[0:12]={bits_to_hex(arr[i][:96])}')

    if decoded_pdus:
        print()
        print('=== Decoded MAC-ACCESS PDU (92 bits) ===')
        for i, pdu in enumerate(decoded_pdus[:10]):
            parsed = parse_mac_access(pdu)
            print(f'  #{i}: {bits_to_hex(pdu)}')
            print(f'      {format_parsed_mac_access(parsed)}')
            print(f'      parsed={parsed}')

    return 0


if __name__ == '__main__':
    sys.exit(main())
