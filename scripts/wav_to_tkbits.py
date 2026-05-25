#!/usr/bin/env python3
"""
wav_to_tkbits.py — Robust WAV → tetra-kit bits demodulator.

Uses decode_dl.py's feedforward burst-based approach:
  1. Auto freq offset (FFT peak)
  2. Decimate to ~8 sps, RRC matched filter
  3. Find all STS correlation peaks, pick best, lock cell (get SDB vs NSB layout)
  4. Walk the burst grid (255 sym spacing)
  5. Per-burst STS/NTS correlation → timing refinement → phase correction
  6. Differential demod → 510 bits per burst
  7. Emit continuous byte-per-bit stream (tetra-kit default format)

Output:
  - File: `-o bits.bin` → `./tetra-kit/decoder/decoder -i bits.bin`
  - UDP:  `--udp` → port 42000 (default tetra-kit live input)

Requires decode_dl.py in same scripts/ dir (imports helpers).
"""

import argparse
import os
import socket
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_dl import (
    SYMBOL_RATE, BURST_SYMBOLS,
    SDB_OFF_SB1, SDB_OFF_STS, SDB_OFF_BB, SDB_OFF_BKN2, SDB_SB1,
    NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2,
    NDB_OFF_NTS,
    STS_DIBITS, STS_DIFF_REF,
    NTS1_DIBITS, NTS1_DIFF_REF,
    NTS2_DIBITS, NTS2_DIFF_REF,
    dibits_to_symbols, demod_pi4dqpsk,
    _correlate_at, _build_diff_ref,
    load_iq_file, estimate_freq_offset, rrc_filter,
    scrambler_seq, decode_channel, parse_sysinfo_sb, make_scramb_code,
)


# Tetra-kit hardcoded burst layout (from tetra-kit/decoder/decoder.cc):
#   SYNC_TRAINING_SEQ  at bit 214 = symbol 107
#   NORMAL_TRAINING_SEQ at bit 244 = symbol 122
TK_SB_STS_SYM = 107
TK_NDB_NTS_SYM = 122


def _extract_and_correct(iq, ts_sample_pos, sps, output_ts_sym_offset,
                         ts_dibits, ts_diff_ref, refine=True):
    """Extract 255 symbols positioned so that the training sequence lands at
    `output_ts_sym_offset` in the output. ts_sample_pos is the detected sample
    position of the first TS symbol. Applies per-burst phase correction."""
    n = len(iq)
    # Optional sub-sample refinement of TS sample position
    best_c = 0.0
    best_t = 0.0
    if refine:
        for dt in np.linspace(-sps, sps, int(4 * sps) + 1):
            c = _correlate_at(iq, ts_sample_pos + dt, sps, ts_dibits, ts_diff_ref)
            if c > best_c:
                best_c = c
                best_t = dt
        for dt in np.linspace(best_t - 0.5, best_t + 0.5, 21):
            c = _correlate_at(iq, ts_sample_pos + dt, sps, ts_dibits, ts_diff_ref)
            if c > best_c:
                best_c = c
                best_t = dt
    ts_pos_final = ts_sample_pos + best_t

    # Burst start = TS sample pos - (output TS offset) * sps
    burst_start = ts_pos_final - output_ts_sym_offset * sps
    if burst_start < 0 or burst_start + BURST_SYMBOLS * sps >= n:
        return None, best_c

    sym_indices = np.round(np.arange(BURST_SYMBOLS) * sps + burst_start).astype(int)
    sym_indices = np.clip(sym_indices, 0, n - 1)
    burst_syms = iq[sym_indices]

    # Per-burst phase correction from training seq (linear+quadratic fit)
    ts_ref = dibits_to_symbols(ts_dibits)
    ts_dr = ts_ref[1:] * np.conj(ts_ref[:-1])
    s_idx = np.clip(np.arange(len(ts_dibits)) + output_ts_sym_offset, 0, BURST_SYMBOLS - 1)
    ss = burst_syms[s_idx]
    sd = ss[1:] * np.conj(ss[:-1])
    pe = np.angle(sd * np.conj(ts_dr))
    if len(pe) > 1:
        sl, ic = np.polyfit(np.arange(len(pe)), pe, 1)
        nr = np.arange(BURST_SYMBOLS, dtype=np.float64) - float(output_ts_sym_offset)
        burst_syms = burst_syms * np.exp(-1j * (ic * nr + 0.5 * sl * nr * (nr - 1.0)))

    return burst_syms, best_c


def _dibits_to_bytes_per_bit(dibits):
    """tetra-kit default: 1 byte per bit, value 0 or 1, MSB-first per dibit."""
    out = np.empty(len(dibits) * 2, dtype=np.uint8)
    out[0::2] = (dibits >> 1) & 1
    out[1::2] = dibits & 1
    return out


_UDP_FMT_MAP = {
    'int8':    (np.int8,    1/128.0),
    'uint8':   (np.uint8,   1/128.0),   # offset-binary
    'int16':   (np.int16,   1/32768.0),
    'float32': (np.float32, 1.0),
}


def open_udp_iq_socket(port, host='0.0.0.0'):
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    s.bind((host, port))
    return s


def _bytes_to_complex(buf, fmt):
    dtype, scale = _UDP_FMT_MAP[fmt]
    bps = np.dtype(dtype).itemsize * 2
    n = len(buf) // bps
    raw = np.frombuffer(bytes(buf[:n * bps]), dtype=dtype)
    if fmt == 'uint8':
        i = (raw[0::2].astype(np.float32) - 128.0) * scale
        q = (raw[1::2].astype(np.float32) - 128.0) * scale
    else:
        i = raw[0::2].astype(np.float32) * scale
        q = raw[1::2].astype(np.float32) * scale
    return (i + 1j * q).astype(np.complex64)


def capture_udp_iq(sock, duration, fmt):
    import time
    sock.settimeout(max(1.0, duration + 0.5))
    buf = bytearray()
    t0 = time.time()
    while time.time() - t0 < duration:
        try:
            data, _ = sock.recvfrom(65536)
        except Exception:
            break
        buf.extend(data)
    elapsed = time.time() - t0
    iq = _bytes_to_complex(buf, fmt)
    eff_rate = len(iq) / elapsed if elapsed > 0 else 0.0
    return iq, eff_rate, elapsed


def recv_udp_iq(port, rate, fmt, duration, host='0.0.0.0'):
    """Legacy one-shot: open, capture N seconds, close. Returns (iq, rate)."""
    if fmt not in _UDP_FMT_MAP:
        raise ValueError(f"unknown udp fmt '{fmt}'")
    s = open_udp_iq_socket(port, host)
    print(f"[udp-in] listening on {host}:{port}, fmt={fmt} rate={rate} duration={duration}s")
    iq, eff_rate, elapsed = capture_udp_iq(s, duration, fmt)
    s.close()
    use_rate = rate
    if elapsed > 1.0 and abs(eff_rate - rate) / rate > 0.02:
        print(f"[udp-in] WARN eff_rate {eff_rate:.0f} Hz differs from declared "
              f"{rate} Hz by {100*(eff_rate-rate)/rate:+.1f}%, using eff_rate")
        use_rate = eff_rate
    print(f"[udp-in] got {len(iq)} samples in {elapsed:.1f}s, eff_rate={eff_rate:.0f} Hz")
    return iq, use_rate


def process_iq(iq, sample_rate, output_sink, freq_offset=None,
               conjugate=False, max_bursts=100000, empty_fill=True):
    """Demodulate a complex64 IQ array → tetra-kit bit stream."""
    sps_target = 8
    if len(iq) < 1024:
        print("[demod] too few samples — aborting")
        return False

    if conjugate:
        iq = np.conj(iq)

    # --- Freq offset ---
    if freq_offset is None:
        freq_offset = estimate_freq_offset(iq, sample_rate)
    print(f"[demod] freq_offset={freq_offset:+.1f} Hz")
    if abs(freq_offset) > 10:
        t = np.arange(len(iq)) / sample_rate
        iq = iq * np.exp(-1j * 2 * np.pi * freq_offset * t)

    # --- Decimate to ~sps_target samples/symbol ---
    target_rate = SYMBOL_RATE * sps_target
    decim = max(1, int(sample_rate / target_rate))
    if decim > 1:
        ntaps = decim * 8 + 1
        cutoff = target_rate / sample_rate
        h = np.sinc(2 * cutoff * (np.arange(ntaps) - ntaps // 2)) * np.hanning(ntaps)
        h /= np.sum(h)
        iq = np.convolve(iq, h, mode='same')[::decim]
    actual_rate = sample_rate / decim
    sps = actual_rate / SYMBOL_RATE
    print(f"[demod] decim={decim}x → {actual_rate:.0f} Hz, sps={sps:.2f}")

    # --- RRC matched filter ---
    rrc_ntaps = int(6 * sps) * 2 + 1
    rrc = rrc_filter(rrc_ntaps, 0.35, sps)
    iq = np.convolve(iq, rrc, mode='same')

    # --- Cell acquisition: scan for STS, try both layouts ---
    n = len(iq)
    burst_spacing = BURST_SYMBOLS * sps
    step = max(1, int(sps / 2))
    scan_limit = min(n - int(BURST_SYMBOLS * sps), n)

    sts_peaks = []
    for off in range(0, scan_limit, step):
        c = _correlate_at(iq, off, sps, STS_DIBITS, STS_DIFF_REF)
        if c >= 0.35:
            sts_peaks.append((off, c))
    sts_peaks.sort(key=lambda x: -x[1])
    deduped = []
    for off, c in sts_peaks:
        if all(abs(off - po) >= burst_spacing // 2 for po, _ in deduped):
            deduped.append((off, c))
        if len(deduped) >= 30:
            break
    if not deduped:
        print("[demod] no STS candidates found — aborting")
        return False
    print(f"[demod] {len(deduped)} STS candidates (best={deduped[0][1]:.3f})")

    LAYOUTS = [
        ('non-continuous', NSB_OFF_SB1, NSB_OFF_STS, NSB_OFF_BB, NSB_OFF_BKN2),
        ('continuous',     SDB_OFF_SB1, SDB_OFF_STS, SDB_OFF_BB, SDB_OFF_BKN2),
    ]
    layout = None
    sb_off_sb1 = sb_off_sts = 0
    acq_sts_pos = None
    for sts_off, _ in deduped:
        for lname, l_sb1, l_sts, l_bb, l_bkn2 in LAYOUTS:
            best_t = 0.0
            best_c = 0.0
            for dt in np.linspace(-1.0, 1.0, 41):
                c = _correlate_at(iq, sts_off + dt, sps, STS_DIBITS, STS_DIFF_REF)
                if c > best_c:
                    best_c = c
                    best_t = dt
            burst_start = sts_off + best_t - l_sts * sps
            sym_idx = np.round(np.arange(BURST_SYMBOLS) * sps + burst_start).astype(int)
            if sym_idx[-1] >= len(iq) or sym_idx[0] < 0:
                continue
            bsyms = iq[sym_idx]
            # phase correct
            sts_ref = dibits_to_symbols(STS_DIBITS)
            sts_dr = sts_ref[1:] * np.conj(sts_ref[:-1])
            s_idx = np.clip(np.arange(len(STS_DIBITS)) + l_sts, 0, BURST_SYMBOLS - 1)
            ss = bsyms[s_idx]
            sd = ss[1:] * np.conj(ss[:-1])
            pe = np.angle(sd * np.conj(sts_dr))
            if len(pe) > 1:
                sl, ic = np.polyfit(np.arange(len(pe)), pe, 1)
                nr = np.arange(BURST_SYMBOLS, dtype=np.float64) - float(l_sts)
                bsyms = bsyms * np.exp(-1j * (ic * nr + 0.5 * sl * nr * (nr - 1.0)))
            db = demod_pi4dqpsk(bsyms)
            s = l_sb1 - 1
            if s < 0 or s + SDB_SB1 > len(db):
                continue
            sb1_bits = np.zeros(SDB_SB1 * 2, dtype=np.int32)
            sb1_bits[0::2] = (db[s:s+SDB_SB1] >> 1) & 1
            sb1_bits[1::2] = db[s:s+SDB_SB1] & 1
            sb1_d = (sb1_bits ^ scrambler_seq(3, 120)) & 1
            ok, info, _ = decode_channel(sb1_d, 120, 11, 60)
            if ok:
                layout = lname
                sb_off_sb1 = l_sb1
                sb_off_sts = l_sts
                acq_sts_pos = sts_off + best_t
                si = parse_sysinfo_sb(info)
                print(f"[demod] LOCKED [{lname}] MCC={si['MCC']} MNC={si['MNC']} "
                      f"CC={si['ColourCode']} FN={si['Frame']}")
                break
        if layout:
            break

    if layout is None:
        print("[demod] cell lock failed — using best-corr STS and SDB layout (continuous)")
        layout = 'continuous'
        sb_off_sts = SDB_OFF_STS
        acq_sts_pos = deduped[0][0]

    # --- Walk grid, demod each burst, emit 510 bits ---
    acq_sts_float = float(acq_sts_pos)
    pos = acq_sts_float
    while pos - burst_spacing >= 0:
        pos -= burst_spacing
    sts_positions = []
    while pos < n - int(BURST_SYMBOLS * sps) and len(sts_positions) < max_bursts:
        sts_positions.append(pos)
        pos += burst_spacing
    print(f"[demod] grid: {len(sts_positions)} bursts, emitting {len(sts_positions)*510} bits")

    n_sb = n_ndb = n_empty = 0
    for idx, grid_sts_pos in enumerate(sts_positions):
        # grid_sts_pos is where the STS should be (sample position).
        # For NDBs on the same grid, NTS sits (NDB_OFF_NTS - sb_off_sts) symbols later.
        ndb_nts_sample_pred = grid_sts_pos + (NDB_OFF_NTS - sb_off_sts) * sps

        sb_syms, sb_corr = _extract_and_correct(
            iq, grid_sts_pos, sps, TK_SB_STS_SYM,
            STS_DIBITS, STS_DIFF_REF)
        n1_syms, n1_corr = _extract_and_correct(
            iq, ndb_nts_sample_pred, sps, TK_NDB_NTS_SYM,
            NTS1_DIBITS, NTS1_DIFF_REF)
        n2_syms, n2_corr = _extract_and_correct(
            iq, ndb_nts_sample_pred, sps, TK_NDB_NTS_SYM,
            NTS2_DIBITS, NTS2_DIFF_REF)

        best_nts = max(n1_corr, n2_corr)
        if sb_corr >= best_nts and sb_corr >= 0.5 and sb_syms is not None:
            syms = sb_syms
            n_sb += 1
        elif best_nts >= 0.55:
            if n1_corr >= n2_corr and n1_syms is not None:
                syms = n1_syms
                n_ndb += 1
            elif n2_syms is not None:
                syms = n2_syms
                n_ndb += 1
            else:
                syms = None
                n_empty += 1
        else:
            syms = None
            n_empty += 1

        if syms is None:
            if empty_fill:
                # Fill empty slot with zeros — keeps grid alignment for decoder
                out = np.zeros(510, dtype=np.uint8)
                output_sink(out)
            continue

        # Differential demod: 255 symbols → 254 dibits, pad leading 0 → 255 dibits
        db = demod_pi4dqpsk(syms)
        db_padded = np.zeros(BURST_SYMBOLS, dtype=np.int32)
        db_padded[1:] = db
        out = _dibits_to_bytes_per_bit(db_padded)
        output_sink(out)

    print(f"[demod] done: SB={n_sb} NDB={n_ndb} empty={n_empty}")
    return True


def process_wav(wav_path, output_sink, sample_rate=None, freq_offset=None,
                conjugate=False, swap_iq=False, max_bursts=100000,
                empty_fill=True):
    iq, detected_rate = load_iq_file(wav_path, swap_iq=swap_iq)
    if sample_rate is None:
        sample_rate = detected_rate if detected_rate else 2_048_000
    print(f"[demod] sr={sample_rate} samples={len(iq)} ({len(iq)/sample_rate:.2f}s)")
    return process_iq(iq.astype(np.complex64), sample_rate, output_sink,
                      freq_offset=freq_offset, conjugate=conjugate,
                      max_bursts=max_bursts, empty_fill=empty_fill)


def main():
    ap = argparse.ArgumentParser(description="WAV / UDP-IQ → tetra-kit bits (robust demod)")
    ap.add_argument("wav", nargs='?',
                    help="WAV/IQ file (omit when using --udp-in)")
    ap.add_argument("-o", "--output", help="Output bits file (byte-per-bit)")
    ap.add_argument("--udp", action="store_true",
                    help="Send bit stream to UDP (tetra-kit input)")
    ap.add_argument("--udp-port", type=int, default=42000,
                    help="Output UDP port (default 42000). "
                         "Change when --udp-in uses the same port.")
    ap.add_argument("--udp-host", default="127.0.0.1")
    # UDP IQ input
    ap.add_argument("--udp-in", action="store_true",
                    help="Receive IQ samples via UDP instead of reading WAV")
    ap.add_argument("--udp-in-port", type=int, default=42000)
    ap.add_argument("--udp-in-host", default="0.0.0.0")
    ap.add_argument("--udp-in-rate", type=int, default=48000,
                    help="Declared sample rate of the UDP IQ stream")
    ap.add_argument("--udp-in-fmt", default="int8",
                    choices=["int8", "uint8", "int16", "float32"])
    ap.add_argument("--udp-in-secs", type=float, default=10.0,
                    help="Capture duration in seconds before demodulating")
    ap.add_argument("--sr", type=int, help="Override sample rate (WAV mode)")
    ap.add_argument("--offset", type=float, help="Force freq offset (Hz)")
    ap.add_argument("--conjugate", action="store_true")
    ap.add_argument("--swap-iq", action="store_true")
    ap.add_argument("--no-fill", action="store_true",
                    help="Do not fill empty slots with zero bits")
    ap.add_argument("--max-bursts", type=int, default=100000)
    args = ap.parse_args()

    if args.udp_in and args.udp and args.udp_port == args.udp_in_port:
        print(f"[err] --udp-in and --udp share port {args.udp_port}; "
              f"use --udp-port to pick a different output port.", file=sys.stderr)
        sys.exit(2)
    if not args.udp_in and not args.wav:
        ap.error("either provide a WAV file or use --udp-in")

    sinks = []
    if args.output:
        fout = open(args.output, "wb")
        sinks.append(lambda buf: fout.write(buf.tobytes()))
    if args.udp:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        addr = (args.udp_host, args.udp_port)
        # Chunk into <=1472 byte UDP packets
        def _udp_sink(buf):
            b = buf.tobytes()
            for i in range(0, len(b), 1024):
                sock.sendto(b[i:i+1024], addr)
        sinks.append(_udp_sink)

    if not sinks:
        # Default: stdout
        sinks.append(lambda buf: sys.stdout.buffer.write(buf.tobytes()))

    def sink(buf):
        for s in sinks:
            s(buf)

    if args.udp_in:
        iq, rate = recv_udp_iq(args.udp_in_port, args.udp_in_rate,
                               args.udp_in_fmt, args.udp_in_secs,
                               host=args.udp_in_host)
        process_iq(iq, rate, sink, freq_offset=args.offset,
                   conjugate=args.conjugate, max_bursts=args.max_bursts,
                   empty_fill=not args.no_fill)
    else:
        process_wav(args.wav, sink,
                    sample_rate=args.sr, freq_offset=args.offset,
                    conjugate=args.conjugate, swap_iq=args.swap_iq,
                    max_bursts=args.max_bursts, empty_fill=not args.no_fill)

    if args.output:
        fout.close()


if __name__ == "__main__":
    main()
