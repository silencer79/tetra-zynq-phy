#!/usr/bin/env python3
"""
gen_sync_detect_vectors.py — Test vector generator for tetra_sync_detect
==========================================================================
Reference: ETSI EN 300 392-2 §9.4.4 (Training Sequences)

Training sequences are specified as dibit pairs (2 bits per symbol) as they
appear at the output of tetra_pi4dqpsk_demod (post-differential-decode).

Dibit encoding (from tetra_pi4dqpsk_demod):
  00 → ΔΦ = +π/4
  01 → ΔΦ = +3π/4
  11 → ΔΦ = -3π/4
  10 → ΔΦ = -π/4

IMPORTANT: The training sequence dibit values below are derived from
ETSI EN 300 392-2 Tables 9.11 (NTS), 9.12 (ETS), 9.14 (STS).
Verify against the actual standard document before hardware deployment.

NDB Normal Downlink Burst structure (EN 300 392-2 §9.4.4.3.1):
  PA(2) + Freq_Corr(2) + Block1(216) + NTS(44) + BB(30) + Block2(216) + Guard(2) = 512 bits
  → 256 symbols total, but effective payload symbols = 255 (1 guard)

SB Synchronisation Burst structure (EN 300 392-2 §9.4.4.3.2):
  PA(2) + Freq_Corr(4) + Block1(120) + STS(76) + Block2(112) + BB(30) + Guard(2) = 346 bits
  → Note: SB has different structure, 38-symbol STS in center
"""

import os
import random

# ---------------------------------------------------------------------------
# Training Sequence Reference Values
# ETSI EN 300 392-2, Tables 9.11 / 9.12 / 9.14
# Each entry is one dibit (0–3) in receive order.
# TODO: Cross-check these dibit values against the printed ETSI table.
# ---------------------------------------------------------------------------

# Normal Training Sequence (NTS) — 22 symbols, 44 bits (Table 9.11)
# These are the Type-5 dibits as output by the π/4-DQPSK demodulator.
NTS_DIBITS = [
    0b11, 0b01, 0b00, 0b00, 0b11, 0b10, 0b10, 0b01,
    0b11, 0b01, 0b00, 0b00, 0b11, 0b10, 0b10, 0b01,
    0b11, 0b01, 0b00, 0b00, 0b11, 0b00,
]
assert len(NTS_DIBITS) == 22, "NTS must be 22 symbols"

# Extended Training Sequence (ETS) — 30 symbols, 60 bits (Table 9.12)
ETS_DIBITS = [
    0b11, 0b01, 0b00, 0b00, 0b11, 0b10, 0b10, 0b01,
    0b11, 0b01, 0b00, 0b00, 0b11, 0b10, 0b10, 0b01,
    0b11, 0b01, 0b00, 0b00, 0b11, 0b00, 0b01, 0b10,
    0b11, 0b01, 0b00, 0b10, 0b11, 0b01,
]
assert len(ETS_DIBITS) == 30, "ETS must be 30 symbols"

# Synchronisation Training Sequence (STS) — 38 symbols, 76 bits (Table 9.14)
STS_DIBITS = [
    0b11, 0b01, 0b00, 0b10, 0b11, 0b01, 0b10, 0b01,
    0b00, 0b10, 0b11, 0b01, 0b00, 0b00, 0b11, 0b10,
    0b10, 0b01, 0b11, 0b01, 0b00, 0b10, 0b11, 0b01,
    0b10, 0b01, 0b00, 0b10, 0b11, 0b01, 0b00, 0b00,
    0b11, 0b10, 0b10, 0b01, 0b11, 0b01,
]
assert len(STS_DIBITS) == 38, "STS must be 38 symbols"

SEQ_TABLE = {
    0: NTS_DIBITS,   # seq_select 0 = Normal (22 sym)
    1: ETS_DIBITS,   # seq_select 1 = Extended (30 sym)
    2: STS_DIBITS,   # seq_select 2 = Synchronisation (38 sym)
}

SEQ_LEN_MAX = 38  # longest sequence


# ---------------------------------------------------------------------------
# Correlator model (mirrors the RTL implementation)
# ---------------------------------------------------------------------------

def correlate(window, reference):
    """
    Count matching dibits between a received window and the reference sequence.
    window[-len(reference):] is the most recent received data (index -1 newest).
    Returns count in [0, len(reference)].
    """
    ref_len = len(reference)
    if len(window) < ref_len:
        return 0
    recent = window[-ref_len:]
    return sum(1 for r, e in zip(recent, reference) if r == e)


def detect_peak(corr_prev, corr_curr, corr_next, threshold):
    """True when corr_curr is a local peak above threshold."""
    return (corr_curr >= threshold and
            corr_curr >= corr_prev and
            corr_curr >= corr_next)


def simulate_sync_detect(stream, seq_select, threshold, verbose=False):
    """
    Run the sliding correlator over a dibit stream.
    Returns list of (position, correlation) where sync_found fired.
    """
    reference = SEQ_TABLE[seq_select]
    ref_len = len(reference)
    window = []
    corr_prev = 0
    corr_curr = 0
    results = []

    for pos, dibit in enumerate(stream):
        window.append(dibit)
        corr_next = correlate(window, reference)

        if detect_peak(corr_prev, corr_curr, corr_next, threshold):
            # Peak was at previous position
            results.append((pos - 1, corr_curr))
            if verbose:
                print(f"  sync_found at pos={pos-1}, corr={corr_curr}/{ref_len}")

        corr_prev = corr_curr
        corr_curr = corr_next

    return results


# ---------------------------------------------------------------------------
# Burst builders
# ---------------------------------------------------------------------------

def build_ndb(block1=None, block2=None, bb=None, seq_select=0):
    """
    Build a Normal Downlink Burst as a dibit list.
    Returns (burst, ts_start_pos) where ts_start_pos is the symbol index
    where the training sequence begins.
    """
    # PA + Freq_Corr = 2 symbols (4 bits), fixed preamble
    preamble = [0b01, 0b01]  # Freq correction symbols

    # Block1: 216 bits = 108 dibits
    if block1 is None:
        block1 = [random.randint(0, 3) for _ in range(108)]

    # Training sequence
    ts = SEQ_TABLE[seq_select][:]

    # Broadcast Block: 30 bits = 15 dibits (Reed-Muller encoded AACH)
    if bb is None:
        bb = [random.randint(0, 3) for _ in range(15)]

    # Block2: 216 bits = 108 dibits
    if block2 is None:
        block2 = [random.randint(0, 3) for _ in range(108)]

    # Guard: 1 symbol
    guard = [0b00]

    burst = preamble + block1 + ts + bb + block2 + guard
    ts_start = len(preamble) + len(block1)
    return burst, ts_start


def build_random_noise(length, seed=42):
    """Random dibit stream (no training sequence)."""
    rng = random.Random(seed)
    return [rng.randint(0, 3) for _ in range(length)]


# ---------------------------------------------------------------------------
# Stimulus file format
# Each line: <dibit_hex> — one symbol per line (2 bits, written as 0/1/2/3)
# ---------------------------------------------------------------------------

def write_stimulus(path, dibits):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        for d in dibits:
            f.write(f"{d:02b}\n")  # 2-char binary for $readmemb or hex
    print(f"  Wrote {len(dibits)} symbols to {path}")


def write_expected(path, found_list, total_syms):
    """
    Expected output: one line per symbol position.
    Format: <sync_found_bit>
    """
    found_positions = {pos for pos, _ in found_list}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        for i in range(total_syms):
            f.write("1\n" if i in found_positions else "0\n")
    print(f"  Wrote {total_syms} expected lines to {path}")


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

def tc1_single_nts(out_dir):
    """
    TC1: Single NDB burst in random noise.
    seq_select=0 (NTS), threshold=18/22 (82% match required).
    """
    print("TC1: Single NDB, NTS correlator")
    random.seed(1)
    prefix_noise = build_random_noise(50, seed=1)
    burst, ts_start = build_ndb(seq_select=0)
    suffix_noise = build_random_noise(50, seed=2)
    stream = prefix_noise + burst + suffix_noise

    threshold = 18  # out of 22
    expected_sync_pos = len(prefix_noise) + ts_start + len(NTS_DIBITS) - 1

    results = simulate_sync_detect(stream, seq_select=0, threshold=threshold, verbose=True)
    print(f"  Expected sync at symbol ~{expected_sync_pos}")
    print(f"  Got: {results}")

    write_stimulus(f"{out_dir}/tc1_stim.txt", stream)
    write_expected(f"{out_dir}/tc1_expected.txt", results, len(stream))

    # Write threshold as single-line hex file
    with open(f"{out_dir}/tc1_threshold.txt", 'w') as f:
        f.write(f"{threshold}\n")
    with open(f"{out_dir}/tc1_seq_select.txt", 'w') as f:
        f.write("0\n")

    return len(results) >= 1


def tc2_sts_burst(out_dir):
    """
    TC2: Synchronisation Burst with STS correlator.
    seq_select=2 (STS), threshold=30/38.
    """
    print("TC2: Synchronisation Burst, STS correlator")
    random.seed(3)

    # SB has different structure but we simplify: treat as NDB with STS
    prefix_noise = build_random_noise(30, seed=3)
    burst, ts_start = build_ndb(seq_select=2)
    suffix_noise = build_random_noise(30, seed=4)
    stream = prefix_noise + burst + suffix_noise

    threshold = 30  # out of 38
    results = simulate_sync_detect(stream, seq_select=2, threshold=threshold, verbose=True)
    print(f"  Expected sync near symbol ~{len(prefix_noise) + ts_start + len(STS_DIBITS) - 1}")
    print(f"  Got: {results}")

    write_stimulus(f"{out_dir}/tc2_stim.txt", stream)
    write_expected(f"{out_dir}/tc2_expected.txt", results, len(stream))

    with open(f"{out_dir}/tc2_threshold.txt", 'w') as f:
        f.write(f"{threshold}\n")
    with open(f"{out_dir}/tc2_seq_select.txt", 'w') as f:
        f.write("2\n")

    return len(results) >= 1


def tc3_multi_frame(out_dir):
    """
    TC3: Four consecutive NDB bursts (1 TDMA frame, 4 timeslots).
    Tests lock detection — 4 sync pulses at 255-symbol spacing.
    """
    print("TC3: 4 consecutive NDB bursts, lock detection")
    random.seed(5)

    stream = []
    ts_positions = []
    for slot in range(4):
        burst, ts_start = build_ndb(seq_select=0)
        abs_ts_start = len(stream) + ts_start
        ts_positions.append(abs_ts_start + len(NTS_DIBITS) - 1)
        stream += burst

    threshold = 18
    results = simulate_sync_detect(stream, seq_select=0, threshold=threshold, verbose=True)
    print(f"  Expected sync positions: {ts_positions}")
    print(f"  Got: {[pos for pos, _ in results]}")

    write_stimulus(f"{out_dir}/tc3_stim.txt", stream)
    write_expected(f"{out_dir}/tc3_expected.txt", results, len(stream))

    with open(f"{out_dir}/tc3_threshold.txt", 'w') as f:
        f.write(f"{threshold}\n")
    with open(f"{out_dir}/tc3_seq_select.txt", 'w') as f:
        f.write("0\n")

    spacing = [ts_positions[i+1] - ts_positions[i] for i in range(3)]
    print(f"  Burst spacing (symbols): {spacing} (expected ~255 each)")

    return len(results) == 4


def tc4_no_sync(out_dir):
    """
    TC4: Pure random noise — should produce no (or very few spurious) hits
    with threshold set high.
    """
    print("TC4: Random noise, high threshold — no sync expected")
    random.seed(7)
    stream = build_random_noise(500, seed=7)

    threshold = 20  # high threshold, very unlikely in random data
    results = simulate_sync_detect(stream, seq_select=0, threshold=threshold, verbose=True)
    print(f"  Spurious detections: {len(results)} (expected 0 or very few)")

    write_stimulus(f"{out_dir}/tc4_stim.txt", stream)
    write_expected(f"{out_dir}/tc4_expected.txt", results, len(stream))

    with open(f"{out_dir}/tc4_threshold.txt", 'w') as f:
        f.write(f"{threshold}\n")
    with open(f"{out_dir}/tc4_seq_select.txt", 'w') as f:
        f.write("0\n")

    # Pass if 0 or 1 spurious hits (statistical chance is very low)
    return len(results) <= 1


def tc5_noisy_sync(out_dir):
    """
    TC5: NDB burst with 3 corrupted symbols (BER ~14%).
    Correlator should still detect with threshold=16/22.
    """
    print("TC5: NDB burst with 3 corrupted training sequence symbols")
    random.seed(9)

    prefix_noise = build_random_noise(40, seed=9)
    burst, ts_start = build_ndb(seq_select=0)

    # Corrupt 3 symbols within the training sequence
    ts_abs_start = len(prefix_noise) + ts_start
    for corrupt_offset in [3, 10, 17]:
        corrupt_pos = ts_abs_start + corrupt_offset
        stream_list = prefix_noise + burst + build_random_noise(40, seed=10)
        if corrupt_pos < len(stream_list):
            stream_list[corrupt_pos] = (stream_list[corrupt_pos] + 1) % 4

    stream = prefix_noise + burst + build_random_noise(40, seed=10)
    # Apply corruption
    for corrupt_offset in [3, 10, 17]:
        corrupt_pos = ts_abs_start + corrupt_offset
        if corrupt_pos < len(stream):
            stream[corrupt_pos] = (stream[corrupt_pos] + 1) % 4

    threshold = 16  # lowered to tolerate corruption (≥16/22 = 73%)
    results = simulate_sync_detect(stream, seq_select=0, threshold=threshold, verbose=True)
    print(f"  Expected sync near {ts_abs_start + len(NTS_DIBITS) - 1}")
    print(f"  Got: {results}")

    write_stimulus(f"{out_dir}/tc5_stim.txt", stream)
    write_expected(f"{out_dir}/tc5_expected.txt", results, len(stream))

    with open(f"{out_dir}/tc5_threshold.txt", 'w') as f:
        f.write(f"{threshold}\n")
    with open(f"{out_dir}/tc5_seq_select.txt", 'w') as f:
        f.write("0\n")

    return len(results) >= 1


# ---------------------------------------------------------------------------
# Autocorrelation sanity check
# ---------------------------------------------------------------------------

def check_autocorrelation():
    print("\nTraining Sequence Autocorrelation Check:")
    for name, seq in [("NTS", NTS_DIBITS), ("ETS", ETS_DIBITS), ("STS", STS_DIBITS)]:
        n = len(seq)
        # Zero-lag (perfect) correlation
        corr_0 = n
        # Off-by-one correlation (worst case for false detection)
        corr_1 = sum(1 for i in range(n-1) if seq[i] == seq[i+1])
        print(f"  {name}: len={n}, corr[0]={corr_0}, corr[±1]={corr_1}")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    out_dir = os.path.join(os.path.dirname(__file__), "sync_detect")
    os.makedirs(out_dir, exist_ok=True)

    check_autocorrelation()

    results = {
        "TC1 (Single NDB/NTS)":     tc1_single_nts(out_dir),
        "TC2 (SB/STS)":             tc2_sts_burst(out_dir),
        "TC3 (4-burst frame/lock)": tc3_multi_frame(out_dir),
        "TC4 (no sync, noise)":     tc4_no_sync(out_dir),
        "TC5 (noisy sync)":         tc5_noisy_sync(out_dir),
    }

    print("\n=== Vector Generation Summary ===")
    all_pass = True
    for name, ok in results.items():
        status = "PASS" if ok else "FAIL"
        print(f"  {status}: {name}")
        if not ok:
            all_pass = False

    if all_pass:
        print("\nAll test cases generated and self-checked OK.")
    else:
        print("\nWARNING: One or more test cases failed self-check.")
        print("         Verify training sequence values against ETSI EN 300 392-2.")
        raise SystemExit(1)
