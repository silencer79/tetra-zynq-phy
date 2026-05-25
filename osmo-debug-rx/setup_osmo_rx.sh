#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_ROOT="${ROOT}/vendor"
OSMO_ROOT="${VENDOR_ROOT}/osmo-tetra"
LOG_DIR="${ROOT}/build-logs"
PY3_DEMOD_DIR="${ROOT}/py3-osmo-demod"

mkdir -p "${VENDOR_ROOT}" "${LOG_DIR}"

clone_osmo() {
  if [[ -d "${OSMO_ROOT}/.git" ]]; then
    return
  fi

  rm -rf "${OSMO_ROOT}.tmp"
  if git clone https://github.com/osmocom/osmo-tetra "${OSMO_ROOT}.tmp" > "${LOG_DIR}/git-clone.log" 2>&1; then
    mv "${OSMO_ROOT}.tmp" "${OSMO_ROOT}"
    return
  fi

  rm -rf "${OSMO_ROOT}.tmp"
  git clone https://gitea.osmocom.org/tetra/osmo-tetra "${OSMO_ROOT}.tmp" > "${LOG_DIR}/git-clone.log" 2>&1
  mv "${OSMO_ROOT}.tmp" "${OSMO_ROOT}"
}

convert_demod_to_py3() {
  rm -rf "${PY3_DEMOD_DIR}"
  cp -R "${OSMO_ROOT}/src/demod" "${PY3_DEMOD_DIR}"
  python3 -m lib2to3 -w "${PY3_DEMOD_DIR}"/*.py > "${LOG_DIR}/lib2to3.log" 2>&1
}

write_float_to_bits_py() {
  cat > "${ROOT}/float_to_bits.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import numpy as np

MAXVAL = 5.0

def process_sym_fl(fl: float) -> int:
    if fl > 2:
        return 3
    if fl > 0:
        return 1
    if fl < -2:
        return -3
    return -1

def sym_int2bits(sym: int):
    if sym == -3:
        return (1, 1)
    if sym == 1:
        return (0, 0)
    if sym == 3:
        return (0, 1)
    return (1, 0)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-a", "--afc", action="store_true")
    ap.add_argument("-f", "--filter-val", type=float, default=0.0001)
    ap.add_argument("-F", "--filter-goal", type=float, default=0.0)
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("infile")
    ap.add_argument("outfile")
    args = ap.parse_args()

    floats = np.fromfile(args.infile, dtype=np.float32)
    bits = np.empty(floats.size * 2, dtype=np.uint8)

    flt = 0.0
    for i, val in enumerate(floats):
      if args.afc and (-MAXVAL < val < MAXVAL):
        flt = flt * (1.0 - args.filter_val) + (val - args.filter_goal) * args.filter_val
        sym = process_sym_fl(val - flt)
      else:
        sym = process_sym_fl(val)
      b0, b1 = sym_int2bits(sym)
      bits[2 * i] = b0
      bits[2 * i + 1] = b1

    bits.tofile(args.outfile)
    if args.verbose:
      print("".join(str(int(x)) for x in bits[:200]))

if __name__ == "__main__":
    main()
PYEOF
  chmod +x "${ROOT}/float_to_bits.py"
}

write_osmo_debug_rx_py() {
  cat > "${ROOT}/osmo_debug_rx.py" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import numpy as np

def summarize_bits(bits: np.ndarray):
    bits = bits.astype(np.uint8)
    total = int(bits.size)
    ones = int(bits.sum())
    zeros = total - ones
    pairs = bits[: total - (total % 2)].reshape(-1, 2)
    dibit_counts = {"00": 0, "01": 0, "10": 0, "11": 0}
    for a, b in pairs[:200000]:
        dibit_counts[f"{a}{b}"] += 1
    transitions = int(np.count_nonzero(bits[1:] != bits[:-1])) if total > 1 else 0
    return {
        "total_bits": total,
        "zeros": zeros,
        "ones": ones,
        "ones_ratio": (ones / total) if total else 0.0,
        "transitions": transitions,
        "transition_ratio": (transitions / (total - 1)) if total > 1 else 0.0,
        "dibits_sampled": int(min(len(pairs), 200000)),
        "dibit_counts": dibit_counts,
    }

def main():
    ap = argparse.ArgumentParser(description="Lightweight osmo-based TETRA HF debug summary")
    ap.add_argument("--bits", required=True)
    ap.add_argument("--float-file", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    bit_path = Path(args.bits)
    float_path = Path(args.float_file)
    out_path = Path(args.out)

    bits = np.fromfile(bit_path, dtype=np.uint8)
    fl = np.fromfile(float_path, dtype=np.float32)
    summary = summarize_bits(bits)
    summary["float_count"] = int(fl.size)
    summary["float_mean"] = float(np.mean(fl)) if fl.size else 0.0
    summary["float_std"] = float(np.std(fl)) if fl.size else 0.0
    summary["float_min"] = float(np.min(fl)) if fl.size else 0.0
    summary["float_max"] = float(np.max(fl)) if fl.size else 0.0

    out_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="ascii")
    print(out_path)

if __name__ == "__main__":
    main()
PYEOF
  chmod +x "${ROOT}/osmo_debug_rx.py"
}

patch_runner_paths() {
  python3 - <<'PYEOF'
from pathlib import Path

path = Path("/home/kevin/claude-ralph/tetra/osmo-debug-rx/osmo_tetra_rx.sh")
text = path.read_text(encoding="ascii")
text = text.replace(
    '    [[ -n "${OSMO_TETRA_DEMOD}" ]] || OSMO_TETRA_DEMOD="${root}/src/demod/python/simdemod2.py"\n',
    '    [[ -n "${OSMO_TETRA_DEMOD}" ]] || OSMO_TETRA_DEMOD="${root}/src/demod/simdemod2.py"\n',
)
text = text.replace(
    '  [[ -n "${OSMO_TETRA_DEMOD}" ]] || fail "OSMO_TETRA_DEMOD not set and no default from OSMO_TETRA_ROOT"\n'
    '  [[ -n "${OSMO_TETRA_RX}" ]] || fail "tetra-rx not found; set OSMO_TETRA_ROOT or OSMO_TETRA_RX"\n'
    '  [[ -n "${OSMO_FLOAT_TO_BITS}" ]] || fail "float_to_bits not found; set OSMO_TETRA_ROOT or OSMO_FLOAT_TO_BITS"\n'
    '\n'
    '  [[ -f "${OSMO_TETRA_DEMOD}" ]] || fail "Demod script not found: ${OSMO_TETRA_DEMOD}"\n'
    '  [[ -x "${OSMO_TETRA_RX}" ]] || fail "tetra-rx not executable: ${OSMO_TETRA_RX}"\n'
    '  [[ -x "${OSMO_FLOAT_TO_BITS}" ]] || fail "float_to_bits not executable: ${OSMO_FLOAT_TO_BITS}"\n',
    '  [[ -n "${OSMO_TETRA_DEMOD}" ]] || fail "OSMO_TETRA_DEMOD not set and no default from OSMO_TETRA_ROOT"\n'
    '  [[ -f "${OSMO_TETRA_DEMOD}" ]] || fail "Demod script not found: ${OSMO_TETRA_DEMOD}"\n'
    '\n'
    '  if [[ -z "${OSMO_FLOAT_TO_BITS}" ]]; then\n'
    '    OSMO_FLOAT_TO_BITS="${SCRIPT_DIR}/float_to_bits.py"\n'
    '  fi\n'
    '  [[ -x "${OSMO_FLOAT_TO_BITS}" ]] || fail "float_to_bits not executable: ${OSMO_FLOAT_TO_BITS}"\n'
    '\n'
    '  if [[ -z "${OSMO_TETRA_RX}" ]]; then\n'
    '    OSMO_TETRA_RX="${SCRIPT_DIR}/osmo_debug_rx.py"\n'
    '  fi\n'
    '  [[ -x "${OSMO_TETRA_RX}" ]] || fail "tetra-rx/debug receiver not executable: ${OSMO_TETRA_RX}"\n',
)
text = text.replace(
    '  "${OSMO_FLOAT_TO_BITS}" "${float_file}" "${bits_file}"\n'
    '\n'
    '  echo "Running tetra-rx..."\n'
    '  "${OSMO_TETRA_RX}" "${bits_file}" | tee "${log_file}"\n',
    '  "${OSMO_FLOAT_TO_BITS}" "${float_file}" "${bits_file}"\n'
    '\n'
    '  echo "Running tetra-rx/debug receiver..."\n'
    '  if [[ "${OSMO_TETRA_RX}" == *"osmo_debug_rx.py" ]]; then\n'
    '    "${OSMO_TETRA_RX}" --bits "${bits_file}" --float-file "${float_file}" --out "${log_file}"\n'
    '    cat "${log_file}"\n'
    '  else\n'
    '    "${OSMO_TETRA_RX}" "${bits_file}" | tee "${log_file}"\n'
    '  fi\n',
)
path.write_text(text, encoding="ascii")
PYEOF
}

clone_osmo
convert_demod_to_py3
write_float_to_bits_py
write_osmo_debug_rx_py
patch_runner_paths

printf 'READY\n'
printf 'OSMO_TETRA_ROOT=%s\n' "${PY3_DEMOD_DIR%/py3-osmo-demod}/vendor/osmo-tetra"
printf 'OSMO_TETRA_DEMOD=%s\n' "${PY3_DEMOD_DIR}/simdemod2.py"
