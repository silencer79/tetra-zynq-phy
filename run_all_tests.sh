#!/bin/bash
# run_all_tests.sh — führt alle iverilog-Testbenches aus
# Arbeitsverzeichnis muss /home/kevin/claude-ralph/tetra sein

TETRA=/home/kevin/claude-ralph/tetra
TB=$TETRA/tb
RTL=$TETRA/rtl
SIM_MODELS=$TB/sim_models
VECTORS=$TB/vectors
TMP=/tmp

PASS=0
FAIL=0
SKIP=0

run_test() {
 local NAME=$1
 local TB_FILE=$2
 local RTL_FILE=$3
 local EXTRA_FILES=$4
 local USE_TB_CWD=$5 # "1" = run iverilog from $TB dir (for relative readmemh)

 echo "========================================"
 echo "MODULE: $NAME"

 # Check file exists
 if [ ! -f "$RTL_FILE" ]; then
 echo "COMPILE: FAIL — RTL file not found: $RTL_FILE"
 FAIL=$((FAIL+1))
 return
 fi
 if [ ! -f "$TB_FILE" ]; then
 echo "COMPILE: FAIL — TB file not found: $TB_FILE"
 FAIL=$((FAIL+1))
 return
 fi

 # Compile
 local OUT="/tmp/sim_${NAME}"
 local COMPILE_LOG
 if [ "$USE_TB_CWD" = "1" ]; then
 COMPILE_LOG=$(cd "$TB" && iverilog -g2001 -o "$OUT" "$TB_FILE" "$RTL_FILE" $EXTRA_FILES 2>&1)
 else
 COMPILE_LOG=$(iverilog -g2001 -o "$OUT" "$TB_FILE" "$RTL_FILE" $EXTRA_FILES 2>&1)
 fi
 local COMPILE_EXIT=$?

 if [ $COMPILE_EXIT -ne 0 ]; then
 echo "COMPILE: FAIL"
 echo "$COMPILE_LOG"
 FAIL=$((FAIL+1))
 return
 fi
 echo "COMPILE: OK"

 # Simulate
 local SIM_LOG
 if [ "$USE_TB_CWD" = "1" ]; then
 SIM_LOG=$(cd "$TB" && vvp "$OUT" 2>&1)
 else
 SIM_LOG=$(vvp "$OUT" 2>&1)
 fi
 local SIM_EXIT=$?

 echo "SIM OUTPUT:"
 echo "$SIM_LOG"

 # Evaluate
 if echo "$SIM_LOG" | grep -qi "FAIL\|\$error\|\$fatal\|ERROR\|FATAL"; then
 if echo "$SIM_LOG" | grep -qi "PASS"; then
 # Mixed — check for net PASS
 FAIL_COUNT=$(echo "$SIM_LOG" | grep -i "FAIL\|\$error\|\$fatal" | grep -cvE "FAIL=0|0 FAIL\b")
 PASS_COUNT=$(echo "$SIM_LOG" | grep -ci "PASS")
 if [ $FAIL_COUNT -gt 0 ]; then
 echo "SIM: FAIL"
 FAIL=$((FAIL+1))
 else
 echo "SIM: PASS"
 PASS=$((PASS+1))
 fi
 else
 echo "SIM: FAIL"
 FAIL=$((FAIL+1))
 fi
 elif echo "$SIM_LOG" | grep -qi "PASS"; then
 echo "SIM: PASS"
 PASS=$((PASS+1))
 else
 # No explicit PASS/FAIL — check exit code and finish normally
 if [ $SIM_EXIT -eq 0 ]; then
 echo "SIM: COMPLETED (no PASS/FAIL marker)"
 PASS=$((PASS+1))
 else
 echo "SIM: FAIL (non-zero exit)"
 FAIL=$((FAIL+1))
 fi
 fi
}

skip_test() {
 local NAME=$1
 local REASON=$2
 echo "========================================"
 echo "MODULE: $NAME"
 echo "COMPILE: SKIP"
 echo "SIM: SKIP ($REASON)"
 SKIP=$((SKIP+1))
}

# ---- 1. clk_reset ----
run_test "clk_reset" \
 "$TB/tb_tetra_clk_reset.v" \
 "$RTL/infra/tetra_clk_reset.v" \
 "$SIM_MODELS/xilinx_prim_sim.v"

# ---- 2. scrambler ----
run_test "scrambler" \
 "$TB/tb_tetra_scrambler.v" \
 "$RTL/lmac/tetra_scrambler.v"

# ---- 3. interleaver ----
run_test "interleaver" \
 "$TB/tb_tetra_interleaver.v" \
 "$RTL/lmac/tetra_interleaver.v"

# ---- 4. crc16 ----
run_test "crc16" \
 "$TB/tb_tetra_crc16.v" \
 "$RTL/lmac/tetra_crc16.v"

# ---- 5. reed_muller ----
run_test "reed_muller" \
 "$TB/tb_tetra_reed_muller.v" \
 "$RTL/lmac/tetra_reed_muller.v"

# ---- 6. viterbi_decoder ----
run_test "viterbi_decoder" \
 "$TB/tb_tetra_viterbi_decoder.v" \
 "$RTL/lmac/tetra_viterbi_decoder.v"

# ---- 7. frame_counter ----
run_test "frame_counter" \
 "$TB/tb_tetra_frame_counter.v" \
 "$RTL/rx/tetra_frame_counter.v"

# ---- 8. burst_demux ----
run_test "burst_demux" \
 "$TB/tb_tetra_burst_demux.v" \
 "$RTL/rx/tetra_burst_demux.v"

# ---- 9. sync_detect ----
run_test "sync_detect" \
 "$TB/tb_tetra_sync_detect.v" \
 "$RTL/rx/tetra_sync_detect.v"

# ---- 10. timing_recovery ----
# Uses readmemh("tb/vectors/...") — needs project root as CWD
run_test "timing_recovery" \
 "$TB/tb_tetra_timing_recovery.v" \
 "$RTL/rx/tetra_timing_recovery.v" \
 ""

# ---- 11. pi4dqpsk_demod ----
# Uses readmemh("vectors/...") — needs $TB as CWD
run_test "pi4dqpsk_demod" \
 "$TB/tb_tetra_pi4dqpsk_demod.v" \
 "$RTL/rx/tetra_pi4dqpsk_demod.v" \
 "" "1"

# ---- 12. rx_frontend ----
# Uses xpm_fifo_async — needs sim_model
run_test "rx_frontend" \
 "$TB/tb_tetra_rx_frontend.v" \
 "$RTL/rx/tetra_rx_frontend.v" \
 "$SIM_MODELS/xilinx_prim_sim.v"

# ---- 13. axi_lite_regs ----
run_test "axi_lite_regs" \
 "$TB/tb_tetra_axi_lite_regs.v" \
 "$RTL/infra/tetra_axi_lite_regs.v"

# ---- 14. axi_dma_bridge ----
run_test "axi_dma_bridge" \
 "$TB/tb_tetra_axi_dma_bridge.v" \
 "$RTL/infra/tetra_axi_dma_bridge.v"

# ---- 15. ad9361_axis_adapter ----
run_test "ad9361_axis_adapter" \
 "$TB/tb_tetra_ad9361_axis_adapter.v" \
 "$RTL/tetra_ad9361_axis_adapter.v"

# ---- 16. rcpc_encoder ----
run_test "rcpc_encoder" \
 "$TB/tb_tetra_rcpc_encoder.v" \
 "$RTL/lmac/tetra_rcpc_encoder.v"

# ---- 17. pi4dqpsk_mod ----
run_test "pi4dqpsk_mod" \
 "$TB/tb_tetra_pi4dqpsk_mod.v" \
 "$RTL/tx/tetra_pi4dqpsk_mod.v"

# ---- 18. rrc_filter ----
run_test "rrc_filter" \
 "$TB/tb_tetra_rrc_filter.v" \
 "$RTL/tx/tetra_rrc_filter.v"

# ---- 19. steal_detect ----
run_test "steal_detect" \
 "$TB/tb_tetra_steal_detect.v" \
 "$RTL/lmac/tetra_steal_detect.v"

# ---- 20. burst_builder ----
run_test "burst_builder" \
 "$TB/tb_tetra_burst_builder.v" \
 "$RTL/tx/tetra_burst_builder.v"

# ---- 21. burst_mux ----
run_test "burst_mux" \
 "$TB/tb_tetra_burst_mux.v" \
 "$RTL/tx/tetra_burst_mux.v"

# ---- 22. tx_frontend ----
run_test "tx_frontend" \
 "$TB/tb_tetra_tx_frontend.v" \
 "$RTL/tx/tetra_tx_frontend.v" \
 "$SIM_MODELS/xilinx_prim_sim.v"

echo ""
echo "========================================"
echo "SUMMARY: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "========================================"
