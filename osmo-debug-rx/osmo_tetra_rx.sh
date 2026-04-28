#!/usr/bin/env bash
set -euo pipefail

MODE="decode"
if [[ $# -gt 0 ]]; then
  case "$1" in
    probe|capture|decode)
      MODE="$1"
      shift
      ;;
    -h|--help)
      MODE="help"
      shift
      ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="/tmp/tetra-osmo-debug"
CHANNEL_FREQ=""
TUNE_OFFSET="100000"
SAMPLE_RATE="1000000"
GAIN="38.6"
PPM="0"
DURATION="10"
DEVICE="0"
INPUT_FILE=""
KEEP_ARTIFACTS="1"

usage() {
  cat <<'EOF'
Usage:
  ./osmo_tetra_rx.sh probe
  ./osmo_tetra_rx.sh capture [options]
  ./osmo_tetra_rx.sh decode [options]

Options:
  --channel-freq HZ   TETRA channel frequency in Hz
  --tune-offset HZ    Tune offset to avoid DC spike (default: 100000)
  --sample-rate HZ    RTL-SDR sample rate (default: 1000000)
  --gain DB           RTL-SDR tuner gain (default: 38.6)
  --ppm PPM           RTL-SDR ppm correction (default: 0)
  --duration SEC      Capture length in seconds (default: 10)
  --device IDX        RTL-SDR device index (default: 0)
  --out-dir PATH      Output directory (default: /tmp/tetra-osmo-debug)
  --input PATH        Existing .cfile capture for decode mode
  --keep-artifacts    Keep float/bits/log files (default)
  --no-keep-artifacts Remove float/bits after decode
  -h, --help          Show this help

Environment overrides:
  OSMO_TETRA_ROOT     Root of local osmo-tetra checkout (default: vendor/osmo-tetra)
  OSMO_TETRA_DEMOD    Path to demod script (default: py3-osmo-demod/simdemod3.py, GR3.10-native)
  OSMO_TETRA_RX       Path to tetra-rx binary (default: $OSMO_TETRA_ROOT/src/tetra-rx)
EOF
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel-freq)
      CHANNEL_FREQ="${2:?missing value for --channel-freq}"
      shift 2
      ;;
    --tune-offset)
      TUNE_OFFSET="${2:?missing value for --tune-offset}"
      shift 2
      ;;
    --sample-rate)
      SAMPLE_RATE="${2:?missing value for --sample-rate}"
      shift 2
      ;;
    --gain)
      GAIN="${2:?missing value for --gain}"
      shift 2
      ;;
    --ppm)
      PPM="${2:?missing value for --ppm}"
      shift 2
      ;;
    --duration)
      DURATION="${2:?missing value for --duration}"
      shift 2
      ;;
    --device)
      DEVICE="${2:?missing value for --device}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:?missing value for --out-dir}"
      shift 2
      ;;
    --input)
      INPUT_FILE="${2:?missing value for --input}"
      shift 2
      ;;
    --keep-artifacts)
      KEEP_ARTIFACTS="1"
      shift
      ;;
    --no-keep-artifacts)
      KEEP_ARTIFACTS="0"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

mkdir -p "${OUT_DIR}"

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

calc_tune_freq() {
  if [[ -z "${CHANNEL_FREQ}" ]]; then
    fail "--channel-freq is required unless --input is used in decode mode"
  fi
  awk -v a="${CHANNEL_FREQ}" -v b="${TUNE_OFFSET}" 'BEGIN { printf "%.0f", a + b }'
}

resolve_osmo_paths() {
  local root="${OSMO_TETRA_ROOT:-${SCRIPT_DIR}/vendor/osmo-tetra}"
  OSMO_TETRA_DEMOD="${OSMO_TETRA_DEMOD:-}"
  OSMO_TETRA_RX="${OSMO_TETRA_RX:-}"

  [[ -n "${OSMO_TETRA_DEMOD}" ]] || OSMO_TETRA_DEMOD="${SCRIPT_DIR}/py3-osmo-demod/simdemod3.py"
  [[ -n "${OSMO_TETRA_RX}" ]] || OSMO_TETRA_RX="${root}/src/tetra-rx"

  if [[ -z "${OSMO_TETRA_RX}" ]] && command -v tetra-rx >/dev/null 2>&1; then
    OSMO_TETRA_RX="$(command -v tetra-rx)"
  fi

  [[ -f "${OSMO_TETRA_DEMOD}" ]] || fail "Demod script not found: ${OSMO_TETRA_DEMOD}"
  [[ -x "${OSMO_TETRA_RX}" ]] || fail "tetra-rx not executable: ${OSMO_TETRA_RX} (run: cd vendor/osmo-tetra/src && make)"
}

probe() {
  require_cmd rtl_test
  echo "Probing RTL-SDR devices..."
  rtl_test -t
}

capture() {
  require_cmd rtl_sdr

  local tune_freq
  local stamp
  local capture_file
  local sample_count

  tune_freq="$(calc_tune_freq)"
  stamp="$(timestamp)"
  capture_file="${OUT_DIR}/capture_${CHANNEL_FREQ}Hz_${stamp}.cfile"
  sample_count="$(awk -v s="${SAMPLE_RATE}" -v d="${DURATION}" 'BEGIN { printf "%.0f", s * d }')"

  echo "Capture settings:"
  echo "  device:       ${DEVICE}"
  echo "  channel_freq: ${CHANNEL_FREQ}"
  echo "  tune_offset:  ${TUNE_OFFSET}"
  echo "  tune_freq:    ${tune_freq}"
  echo "  sample_rate:  ${SAMPLE_RATE}"
  echo "  gain:         ${GAIN}"
  echo "  ppm:          ${PPM}"
  echo "  duration:     ${DURATION}"
  echo "  output:       ${capture_file}"

  rtl_sdr \
    -d "${DEVICE}" \
    -f "${tune_freq}" \
    -s "${SAMPLE_RATE}" \
    -g "${GAIN}" \
    -p "${PPM}" \
    -n "${sample_count}" \
    "${capture_file}"

  echo "${capture_file}"
}

decode() {
  resolve_osmo_paths

  local capture_file="${INPUT_FILE}"
  local stamp
  local base
  local bits_file
  local log_file

  if [[ -z "${capture_file}" ]]; then
    capture_file="$(capture | tail -n 1)"
  fi
  [[ -f "${capture_file}" ]] || fail "Capture file not found: ${capture_file}"

  stamp="$(timestamp)"
  base="$(basename "${capture_file}")"
  base="${base%.*}"
  bits_file="${OUT_DIR}/bits_${base}_${stamp}.bin"
  log_file="${OUT_DIR}/tetra-rx_${base}_${stamp}.log"

  echo "Osmo-TETRA paths:"
  echo "  demod:    ${OSMO_TETRA_DEMOD}"
  echo "  tetra-rx: ${OSMO_TETRA_RX}"
  echo "Demodulating capture (rtl_sdr u8 IQ -> bits)..."
  python3 "${OSMO_TETRA_DEMOD}" \
    -i "${capture_file}" \
    -o "${bits_file}" \
    -s "${SAMPLE_RATE}" \
    -t "-${TUNE_OFFSET}"

  echo "Running tetra-rx..."
  "${OSMO_TETRA_RX}" "${bits_file}" 2>&1 | tee "${log_file}"

  if [[ "${KEEP_ARTIFACTS}" != "1" ]]; then
    rm -f "${bits_file}"
  fi

  echo "Artifacts:"
  echo "  capture: ${capture_file}"
  [[ "${KEEP_ARTIFACTS}" == "1" ]] && echo "  bits:    ${bits_file}"
  echo "  log:     ${log_file}"
}

case "${MODE}" in
  help)
    usage
    ;;
  probe)
    probe
    ;;
  capture)
    capture
    ;;
  decode)
    decode
    ;;
  *)
    fail "Unknown mode: ${MODE}"
    ;;
esac
