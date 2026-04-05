#!/usr/bin/env python3
"""
Runner script: executes all gen_*.py scripts in order, captures results.
"""
import subprocess
import sys
import os

SCRIPTS = [
    "gen_reset_vectors.py",
    "gen_ad9361_vectors.py",
    "gen_pi4dqpsk_vectors.py",
    "gen_timing_recovery_vectors.py",
    "gen_rx_frontend_vectors.py",
    "gen_sync_detect_vectors.py",
    "gen_burst_vectors.py",
    "gen_scrambler_vectors.py",
    "gen_interleaver_vectors.py",
    "gen_viterbi_vectors.py",
    "gen_reed_muller_vectors.py",
    "gen_crc16_vectors.py",
]

VECTORS_DIR = os.path.dirname(os.path.abspath(__file__))

def list_files_before():
    return set(os.listdir(VECTORS_DIR))

results = []

for script in SCRIPTS:
    before = set(os.listdir(VECTORS_DIR))
    script_path = os.path.join(VECTORS_DIR, script)
    proc = subprocess.run(
        [sys.executable, script_path],
        capture_output=True,
        text=True,
        cwd=VECTORS_DIR,
    )
    after = set(os.listdir(VECTORS_DIR))
    new_files = sorted(after - before)
    results.append({
        "script": script,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "new_files": new_files,
    })
    status = "OK" if proc.returncode == 0 else f"FAILED (exit {proc.returncode})"
    print(f"[{status}] {script}  new_files={new_files}")
    if proc.returncode != 0:
        print("  STDERR:", proc.stderr[:500])

print("\n\n=== FULL REPORT ===\n")
for r in results:
    status = "SUCCESS" if r["returncode"] == 0 else f"FAILED (exit code {r['returncode']})"
    print(f"--- {r['script']} ---")
    print(f"  Status      : {status}")
    print(f"  New files   : {r['new_files']}")
    if r["returncode"] != 0:
        print(f"  STDERR:\n{r['stderr']}")
    print()
