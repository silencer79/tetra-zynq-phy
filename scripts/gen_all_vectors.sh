#!/bin/bash
# =============================================================================
# gen_all_vectors.sh — Generate all testbench vectors
# Project: tetra-zynq-phy
#
# Usage:./scripts/gen_all_vectors.sh
# Requires: Python 3.8+ with numpy
# =============================================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"
VEC_DIR="$PROJ_DIR/tb/vectors"

echo "=== Generating all TETRA testbench vectors ==="
echo " Vectors directory: $VEC_DIR"
echo ""

run_gen() {
 local script="$1"
 local name="$(basename $script.py)"
 if [ -f "$script" ]; then
 echo "--- $name ---"
 python3 "$script"
 echo ""
 else
 echo "SKIP: $script (not yet implemented)"
 echo ""
 fi
}

run_gen "$VEC_DIR/gen_reset_vectors.py"
run_gen "$VEC_DIR/gen_pi4dqpsk_vectors.py"
run_gen "$VEC_DIR/gen_viterbi_vectors.py"
run_gen "$VEC_DIR/gen_reed_muller_vectors.py"
run_gen "$VEC_DIR/gen_scrambler_vectors.py"
run_gen "$VEC_DIR/gen_burst_vectors.py"
run_gen "$VEC_DIR/gen_crc16_vectors.py"

echo "=== Done ==="
echo "Generated files:"
ls -la "$VEC_DIR"/*.hex "$VEC_DIR"/*.txt 2>/dev/null || echo " (no.hex/.txt files yet)"
