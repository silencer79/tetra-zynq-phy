#!/bin/bash
# _compute_tc2.sh — compute TC2 vectors from TC0 using awk
# TC2 = TC0 shifted left by 1 sample (IQ pair)
# The IQ file has interleaved I,Q lines; each pair = 2 lines

set -e

VECDIR="$(dirname "$(realpath "$0")")"
TC0="$VECDIR/timing_tc0_iq_in.hex"
TC2_IQ="$VECDIR/timing_tc2_iq_in.hex"
TC2_TED="$VECDIR/timing_tc2_ted.hex"

# -----------------------------------------------------------------------
# Step 1: Generate TC2 IQ file = TC0 lines 3..256 + "0000\n0000"
# (shifting by one IQ pair = skipping first 2 lines, appending 2 zeros)
# -----------------------------------------------------------------------
{
  tail -n +3 "$TC0"
  printf '0000\n0000\n'
} > "$TC2_IQ"
echo "Written: $TC2_IQ  ($(wc -l < "$TC2_IQ") lines)"

# -----------------------------------------------------------------------
# Step 2: Run Gardner TED reference model in awk
#
# Parameters:
#   NCO_STEP = 0x40000000 = 1073741824
#   MASK32   = 0xFFFFFFFF = 4294967295
#   Overflow when (nco_acc + NCO_STEP) mod 2^32 < nco_acc
#
# Shift registers s0..s3 for I and Q (initialised to 0).
# At each sample n:
#   nco_sum = (nco_acc + NCO_STEP) mod 2^32
#   ovf = (nco_sum < nco_acc)
#   if ovf:
#     i_diff = i_in - s3i
#     q_diff = q_in - s3q
#     ted_sum = s1i * i_diff + s1q * q_diff
#     ted_scaled = int(ted_sum / 2^18)   # floor division (arithmetic)
#     clip to [-32768, 32767]
#   update nco_acc = nco_sum
#   shift: s3=s2, s2=s1, s1=s0, s0=i_in  (same for Q)
# -----------------------------------------------------------------------
awk '
BEGIN {
    NCO_STEP = 1073741824   # 0x40000000
    TWO32    = 4294967296   # 2^32
    SH18     = 262144       # 2^18
    nco_acc  = 0
    s0i = 0; s1i = 0; s2i = 0; s3i = 0
    s0q = 0; s1q = 0; s2q = 0; s3q = 0
    sample   = 0
    odd      = 0            # 0=I line, 1=Q line
    pending_i = 0
}
{
    # Convert hex to signed int16
    val = strtonum("0x" $1)
    if (val > 32767) val -= 65536

    if (odd == 0) {
        pending_i = val
        odd = 1
        next
    }

    # We have both I and Q
    i_in = pending_i
    q_in = val
    odd  = 0

    # NCO overflow detection
    nco_sum = (nco_acc + NCO_STEP) % TWO32
    ovf     = (nco_sum < nco_acc) ? 1 : 0

    if (ovf) {
        i_diff  = i_in - s3i
        q_diff  = q_in - s3q
        ted_sum = s1i * i_diff + s1q * q_diff

        # Arithmetic right shift 18 (floor for negative)
        if (ted_sum >= 0)
            ted_sc = int(ted_sum / SH18)
        else
            ted_sc = -int((-ted_sum + SH18 - 1) / SH18)  # ceiling of negative = floor

        # Actually floor division for negative = -(ceil of abs):
        # floor(-7/4) = floor(-1.75) = -2
        # We want: int(ted_sum / SH18) where int is floor
        # awk int() truncates toward zero, not floor
        # floor(x) = (x >= 0) ? int(x) : int(x)-1  IF x is not integer
        # More precisely: floor(ted_sum / SH18):
        ted_sc = int(ted_sum / SH18)
        if (ted_sum < 0 && ted_sum % SH18 != 0) ted_sc -= 1

        # clip to int16
        if (ted_sc >  32767) ted_sc =  32767
        if (ted_sc < -32768) ted_sc = -32768

        # output as 4-hex-digit two-s-complement
        if (ted_sc < 0) ted_sc += 65536
        printf "%04X\n", ted_sc
    }

    # Update NCO
    nco_acc = nco_sum

    # Shift registers
    s3i = s2i; s2i = s1i; s1i = s0i; s0i = i_in
    s3q = s2q; s2q = s1q; s1q = s0q; s0q = q_in

    sample++
}
' "$TC2_IQ" > "$TC2_TED"

TED_COUNT=$(wc -l < "$TC2_TED")
echo "Written: $TC2_TED  ($TED_COUNT TED events)"

# -----------------------------------------------------------------------
# Sanity check: mean TED of events 5..end should be < 0 (late timing)
# -----------------------------------------------------------------------
awk '
NR > 4 {
    val = strtonum("0x" $1)
    if (val > 32767) val -= 65536
    sum += val
    n++
}
END {
    if (n > 0) {
        mean = sum / n
        printf "Mean TED (skip first 4): %.1f\n", mean
        if (mean < 0)
            print "PASS: mean_ted < 0  (correct sign for late timing)"
        else {
            printf "WARNING: expected mean_ted < 0, got %.1f\n", mean
            exit 1
        }
    }
}
' "$TC2_TED"
