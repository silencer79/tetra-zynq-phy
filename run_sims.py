#!/usr/bin/env python3
"""
run_sims.py — Run all iverilog testbenches for tetra-zynq-phy project.
"""
import subprocess
import os
import sys
import re

TETRA = "/home/kevin/claude-ralph/tetra"
TB    = f"{TETRA}/tb"
RTL   = f"{TETRA}/rtl"
SIMS  = f"{TB}/sim_models"
TMP   = f"{TETRA}/sim_out"

os.makedirs(TMP, exist_ok=True)

results = []

def run(name, tb_file, rtl_file, extra=None, cwd=None):
    sim_out = f"{TMP}/sim_{name}"
    cmd = ["iverilog", "-g2001", "-o", sim_out, tb_file, rtl_file]
    if extra:
        cmd += extra
    compile_cwd = cwd or TETRA
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=compile_cwd, timeout=60)
        if r.returncode != 0:
            results.append({
                "name": name,
                "compile": f"FAIL: {r.stderr.strip()[:200]}",
                "sim": "—"
            })
            return
    except Exception as e:
        results.append({"name": name, "compile": f"FAIL: {e}", "sim": "—"})
        return

    # Run simulation
    try:
        r2 = subprocess.run(["vvp", sim_out], capture_output=True, text=True,
                            cwd=cwd or TETRA, timeout=120)
        out = r2.stdout + r2.stderr
        # Classify
        out_lower = out.lower()
        # Check for explicit "N PASS  M FAIL" summary line first
        summary = re.search(r'(\d+)\s+pass\s+(\d+)\s+fail', out_lower)
        if summary:
            has_pass = int(summary.group(1)) > 0
            has_fail = int(summary.group(2)) > 0
        else:
            # Fallback: look for actual failure indicators
            # "FAIL TC", "FAIL T", "FAIL:" — actual test failures
            # "$fatal" / "fatal:" — simulation fatal
            # Avoid matching "0 fail" (zero failures) or "all tests passed"
            fail_match = re.search(r'\bfail\b\s*(tc|t)\d|\bfail\b\s*[-:]|\bfatal\b', out_lower)
            has_fail = bool(fail_match)
            has_pass = bool(re.search(r'\bpass\b', out_lower))

        if has_pass and not has_fail:
            status = "PASS"
        elif has_fail:
            status = "FAIL"
        elif r2.returncode == 0:
            status = "COMPLETED (no PASS/FAIL marker)"
        else:
            status = "FAIL (non-zero exit)"

        results.append({
            "name": name,
            "compile": "OK",
            "sim": status,
            "output": out.strip()[:400]
        })
    except subprocess.TimeoutExpired:
        results.append({"name": name, "compile": "OK", "sim": "TIMEOUT"})
    except Exception as e:
        results.append({"name": name, "compile": "OK", "sim": f"ERROR: {e}"})

def skip(name, reason):
    results.append({"name": name, "compile": "SKIP", "sim": f"SKIP ({reason})"})

# ---- Run all tests ----

# 1. clk_reset — pure RTL, no XPM primitives used in RTL
run("clk_reset",
    f"{TB}/tb_tetra_clk_reset.v",
    f"{RTL}/infra/tetra_clk_reset.v")

# 2. scrambler
run("scrambler",
    f"{TB}/tb_tetra_scrambler.v",
    f"{RTL}/lmac/tetra_scrambler.v")

# 3. interleaver
run("interleaver",
    f"{TB}/tb_tetra_interleaver.v",
    f"{RTL}/lmac/tetra_interleaver.v")

# 4. crc16
run("crc16",
    f"{TB}/tb_tetra_crc16.v",
    f"{RTL}/lmac/tetra_crc16.v")

# 5. reed_muller
run("reed_muller",
    f"{TB}/tb_tetra_reed_muller.v",
    f"{RTL}/lmac/tetra_reed_muller.v")

# 6. viterbi_decoder
run("viterbi_decoder",
    f"{TB}/tb_tetra_viterbi_decoder.v",
    f"{RTL}/lmac/tetra_viterbi_decoder.v")

# 7. frame_counter
run("frame_counter",
    f"{TB}/tb_tetra_frame_counter.v",
    f"{RTL}/rx/tetra_frame_counter.v")

# 8. burst_demux
run("burst_demux",
    f"{TB}/tb_tetra_burst_demux.v",
    f"{RTL}/rx/tetra_burst_demux.v")

# 9. sync_detect
run("sync_detect",
    f"{TB}/tb_tetra_sync_detect.v",
    f"{RTL}/rx/tetra_sync_detect.v")

# 10. timing_recovery — vectors use path "tb/vectors/..." → cwd=TETRA
run("timing_recovery",
    f"{TB}/tb_tetra_timing_recovery.v",
    f"{RTL}/rx/tetra_timing_recovery.v",
    cwd=TETRA)

# 11. pi4dqpsk_demod — vectors use path "vectors/..." → cwd=TB
run("pi4dqpsk_demod",
    f"{TB}/tb_tetra_pi4dqpsk_demod.v",
    f"{RTL}/rx/tetra_pi4dqpsk_demod.v",
    cwd=TB)

# 12. rx_frontend — uses xpm_fifo_async (no model in sim_models)
run("rx_frontend",
    f"{TB}/tb_tetra_rx_frontend.v",
    f"{RTL}/rx/tetra_rx_frontend.v",
    extra=[f"{SIMS}/xilinx_prim_sim.v"])

# 13. axi_lite_regs
run("axi_lite_regs",
    f"{TB}/tb_tetra_axi_lite_regs.v",
    f"{RTL}/infra/tetra_axi_lite_regs.v")

# 14. axi_dma_bridge
run("axi_dma_bridge",
    f"{TB}/tb_tetra_axi_dma_bridge.v",
    f"{RTL}/infra/tetra_axi_dma_bridge.v")

# 15. ad9361_interface — uses IBUFDS/BUFG/IDDR/ODDR/OBUFDS → sim_model required
run("ad9361_interface",
    f"{TB}/tb_tetra_ad9361_interface.v",
    f"{RTL}/tetra_ad9361_interface.v",
    extra=[f"{SIMS}/xilinx_prim_sim.v"])

# 16. rcpc_encoder — Phase 3 TX path
run("rcpc_encoder",
    f"{TB}/tb_tetra_rcpc_encoder.v",
    f"{RTL}/lmac/tetra_rcpc_encoder.v")

# 17. pi4dqpsk_mod — TX π/4-DQPSK modulator
run("pi4dqpsk_mod",
    f"{TB}/tb_tetra_pi4dqpsk_mod.v",
    f"{RTL}/tx/tetra_pi4dqpsk_mod.v")

# 18. rrc_filter — TX RRC polyphase interpolation filter
run("rrc_filter",
    f"{TB}/tb_tetra_rrc_filter.v",
    f"{RTL}/tx/tetra_rrc_filter.v")

# ---- Phase 3 modules ----

# 19. steal_detect — AACH stealing bit detector
run("steal_detect",
    f"{TB}/tb_tetra_steal_detect.v",
    f"{RTL}/lmac/tetra_steal_detect.v")

# 20. burst_builder — NDB TX burst assembler
run("burst_builder",
    f"{TB}/tb_tetra_burst_builder.v",
    f"{RTL}/tx/tetra_burst_builder.v")

# 21. burst_mux — 4-slot TDMA TX multiplexer
run("burst_mux",
    f"{TB}/tb_tetra_burst_mux.v",
    f"{RTL}/tx/tetra_burst_mux.v")

# 22. tx_frontend — CIC interpolator R=64 N=5, XPM async FIFO CDC
run("tx_frontend",
    f"{TB}/tb_tetra_tx_frontend.v",
    f"{RTL}/tx/tetra_tx_frontend.v",
    extra=[f"{SIMS}/xilinx_prim_sim.v"])

# ---- Print results ----
print("\n" + "="*80)
print("TETRA iverilog TEST RESULTS")
print("="*80)
print(f"{'Module':<22} {'Compile':<30} {'Sim'}")
print("-"*80)

pass_cnt = fail_cnt = skip_cnt = 0
for r in results:
    comp = r["compile"]
    sim  = r["sim"]
    if sim.startswith("PASS"):
        pass_cnt += 1
    elif sim.startswith("SKIP"):
        skip_cnt += 1
    else:
        fail_cnt += 1
    print(f"{r['name']:<22} {comp:<30} {sim}")

print("-"*80)
print(f"SUMMARY: PASS={pass_cnt}  FAIL={fail_cnt}  SKIP={skip_cnt}  TOTAL={len(results)}")
print("="*80)

# Detail output for failures
print("\n=== DETAILED OUTPUT ===")
for r in results:
    if r.get("output") and r["sim"] not in ("PASS",):
        print(f"\n--- {r['name']} ---")
        print(r.get("compile",""))
        print(r.get("output",""))
    elif r.get("output") and "PASS" in r["sim"]:
        # Show brief output for PASS too
        print(f"\n--- {r['name']} [PASS] ---")
        # Show last few lines
        lines = r["output"].splitlines()
        print("\n".join(lines[-5:]) if len(lines) > 5 else r["output"])
