#!/usr/bin/env bash
# =============================================================================
# hw_deploy.sh — Vollautomatischer Hardware-Test: JTAG + SSH + ILA
# Project: tetra-zynq-phy
#
# Ablauf:
#   1. hw_server starten (falls nicht läuft)
#   2. Bitstream per JTAG flashen (Vivado)
#   3. AD9361 per SSH konfigurieren (iio_attr)
#   4. ILA scharf schalten + Daten erfassen (Vivado)
#   5. ILA-Daten auswerten (Python)
#
# Usage:
#   ./scripts/hw_deploy.sh [Optionen]
#
# Optionen:
#   --host       IP       SSH-Adresse des LibreSDR       [192.168.2.180]
#   --freq       HZ       RX-Frequenz in Hz              [430000000]
#   --samplerate HZ       AD9361 Samplerate              [4096000]
#   --gain       DB       RX-Gain dB (manuell)           [40]
#   --agc                 AGC statt manueller Gain
#   --timeout    MS       ILA-Trigger-Timeout            [30000]
#   --no-flash           Bitstream-Flash überspringen
#   --no-ad9361          AD9361-Init überspringen
#   --no-ila             ILA-Capture überspringen
#   --vivado     PATH     Vivado-Binary                  [auto-detect]
#
# Voraussetzungen:
#   - sshpass        (sudo apt install sshpass)
#   - Vivado 2022.2  in $PATH oder $VIVADO_BIN
#   - hw_server      (kommt mit Vivado)
#   - Python 3.8+
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(dirname "$SCRIPT_DIR")"

# --- Defaults ---
SSH_HOST="192.168.2.180"
SSH_USER="root"
SSH_PASS="openwifi"
RX_FREQ_HZ=430000000
SAMPLERATE_HZ=4096000
RX_GAIN_DB=40
AGC_MODE=""
ILA_TIMEOUT_MS=30000
DO_FLASH=1
DO_AD9361=1
DO_ILA=1

# --- Argument-Parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        SSH_HOST="$2";        shift 2 ;;
        --freq)        RX_FREQ_HZ="$2";      shift 2 ;;
        --samplerate)  SAMPLERATE_HZ="$2";   shift 2 ;;
        --gain)        RX_GAIN_DB="$2";      shift 2 ;;
        --agc)         AGC_MODE="--agc";     shift 1 ;;
        --timeout)     ILA_TIMEOUT_MS="$2";  shift 2 ;;
        --no-flash)    DO_FLASH=0;           shift 1 ;;
        --no-ad9361)   DO_AD9361=0;          shift 1 ;;
        --no-ila)      DO_ILA=0;             shift 1 ;;
        --vivado)      VIVADO_BIN="$2";      shift 2 ;;
        --help|-h)
            sed -n '/^# Usage/,/^# =====$/p' "$0" | grep -v "^# ====" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unbekanntes Argument: $1"; exit 1 ;;
    esac
done

BIT_FILE="${PROJ_DIR}/build/tetra_zynq_phy.bit"
LTX_FILE="${PROJ_DIR}/build/tetra_zynq_phy.ltx"

# --- Farben ---
RED='\033[91m'; GREEN='\033[92m'; YELLOW='\033[93m'; CYAN='\033[96m'; BOLD='\033[1m'; NC='\033[0m'
OK()   { echo -e "${GREEN}[OK]${NC}    $*"; }
FAIL() { echo -e "${RED}[FAIL]${NC}  $*"; }
WARN() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
INFO() { echo -e "${CYAN}[INFO]${NC}  $*"; }
STEP() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# =============================================================================
echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗"
echo    "║  tetra-zynq-phy  Hardware Deploy                ║"
echo    "╚══════════════════════════════════════════════════╝${NC}"
INFO "RX-Frequenz:  ${RX_FREQ_HZ} Hz ($(echo "scale=3; ${RX_FREQ_HZ}/1000000" | bc) MHz)"
INFO "Samplerate:   ${SAMPLERATE_HZ} sps"
INFO "SSH-Host:     ${SSH_USER}@${SSH_HOST}"
INFO "ILA-Timeout:  ${ILA_TIMEOUT_MS} ms"

# =============================================================================
# Voraussetzungen prüfen
# =============================================================================
STEP "Voraussetzungen"

# Vivado finden
if [[ -n "${VIVADO_BIN:-}" ]]; then
    VIVADO="$VIVADO_BIN"
elif command -v vivado &>/dev/null; then
    VIVADO="vivado"
else
    # Standard-Installationspfade
    for path in \
        /tools/Xilinx/Vivado/2022.2/bin/vivado \
        /opt/Xilinx/Vivado/2022.2/bin/vivado \
        ~/tools/Vivado/2022.2/bin/vivado; do
        if [[ -x "$path" ]]; then VIVADO="$path"; break; fi
    done
fi

if [[ -z "${VIVADO:-}" ]]; then
    FAIL "Vivado nicht gefunden. Setze: export PATH=\$PATH:/tools/Xilinx/Vivado/2022.2/bin"
    FAIL "Oder: ./scripts/hw_deploy.sh --vivado /pfad/zu/vivado"
    exit 1
fi
OK "Vivado: $VIVADO"

# sshpass prüfen
if ! command -v sshpass &>/dev/null; then
    FAIL "sshpass fehlt: sudo apt install sshpass"
    exit 1
fi
OK "sshpass gefunden"

# Python3 prüfen
if ! command -v python3 &>/dev/null; then
    WARN "python3 nicht gefunden — analyze_ila.py wird übersprungen"
    DO_ANALYZE=0
else
    OK "Python3: $(python3 --version)"
    DO_ANALYZE=1
fi

# Bitstream prüfen (wenn Flash geplant)
if [[ $DO_FLASH -eq 1 ]]; then
    if [[ ! -f "$BIT_FILE" ]]; then
        FAIL "Bitstream nicht gefunden: $BIT_FILE"
        FAIL "Erst bauen: ./scripts/run_build.sh"
        exit 1
    fi
    BIT_SIZE=$(du -h "$BIT_FILE" | cut -f1)
    OK "Bitstream: $BIT_FILE ($BIT_SIZE)"
    [[ -f "$LTX_FILE" ]] && OK "Probes:    $LTX_FILE" || WARN "Keine .ltx-Datei — ILA-Signalnamen unbekannt"
fi

# =============================================================================
# Schritt 1: hw_server starten
# =============================================================================
STEP "Schritt 1/4: hw_server"

HW_SERVER_BIN="$(dirname "$VIVADO")/hw_server"
if [[ ! -x "$HW_SERVER_BIN" ]]; then
    HW_SERVER_BIN="hw_server"
fi

# Prüfen ob hw_server schon läuft (Port 3121)
if nc -z localhost 3121 &>/dev/null 2>&1; then
    OK "hw_server läuft bereits auf Port 3121"
else
    INFO "Starte hw_server ..."
    "$HW_SERVER_BIN" &
    HW_SERVER_PID=$!
    sleep 2
    if nc -z localhost 3121 &>/dev/null 2>&1; then
        OK "hw_server gestartet (PID $HW_SERVER_PID)"
    else
        WARN "hw_server-Start unsicher — Vivado versucht es trotzdem"
    fi
fi

# =============================================================================
# Schritt 2: Bitstream flashen
# =============================================================================
STEP "Schritt 2/4: Bitstream flashen (JTAG)"

if [[ $DO_FLASH -eq 1 ]]; then
    INFO "Starte Vivado (batch mode) ..."
    if "$VIVADO" -mode batch \
        -source "${PROJ_DIR}/scripts/program_fpga.tcl" \
        -nojournal -nolog 2>&1 | tee "${PROJ_DIR}/build/program_fpga.log" | \
        grep -E "(Programming|complete|ERROR|WARN|Done)" ; then
        OK "Bitstream erfolgreich geflasht"
    else
        FAIL "Bitstream-Flash fehlgeschlagen — siehe build/program_fpga.log"
        exit 1
    fi
    INFO "Warte 2s auf FPGA-Init ..."
    sleep 2
else
    WARN "Bitstream-Flash übersprungen (--no-flash)"
fi

# =============================================================================
# Schritt 3: AD9361 initialisieren
# =============================================================================
STEP "Schritt 3/4: AD9361 initialisieren (SSH)"

if [[ $DO_AD9361 -eq 1 ]]; then
    GAIN_ARGS="--gain ${RX_GAIN_DB}"
    [[ -n "$AGC_MODE" ]] && GAIN_ARGS="$AGC_MODE"

    bash "${PROJ_DIR}/scripts/ad9361_init.sh" \
        --host       "${SSH_HOST}" \
        --freq       "${RX_FREQ_HZ}" \
        --samplerate "${SAMPLERATE_HZ}" \
        ${GAIN_ARGS}

    if [[ $? -eq 0 ]]; then
        OK "AD9361 konfiguriert"
        INFO "Warte 1s auf PLL-Stabilisierung ..."
        sleep 1
    else
        FAIL "AD9361-Init fehlgeschlagen"
        exit 1
    fi
else
    WARN "AD9361-Init übersprungen (--no-ad9361)"
fi

# =============================================================================
# Schritt 4: ILA-Capture
# =============================================================================
STEP "Schritt 4/4: ILA-Capture"

if [[ $DO_ILA -eq 1 ]]; then
    INFO "Starte ILA-Capture (Timeout: ${ILA_TIMEOUT_MS} ms) ..."
    if "$VIVADO" -mode batch \
        -source "${PROJ_DIR}/scripts/ila_capture.tcl" \
        -tclargs "--timeout_ms" "${ILA_TIMEOUT_MS}" "--out_dir" "build" \
        -nojournal -nolog 2>&1 | tee "${PROJ_DIR}/build/ila_capture.log" | \
        grep -E "(armed|Trigger|Daten|WARN|ERROR|abgeschlossen|CSV)" ; then
        OK "ILA-Capture abgeschlossen"
    else
        WARN "ILA-Capture endete mit Fehler — Analyse trotzdem versuchen"
    fi
else
    WARN "ILA-Capture übersprungen (--no-ila)"
fi

# =============================================================================
# Schritt 5: Analyse
# =============================================================================
STEP "Analyse"

if [[ ${DO_ANALYZE:-1} -eq 1 ]]; then
    python3 "${PROJ_DIR}/scripts/analyze_ila.py" \
        --lvds "${PROJ_DIR}/build/ila_lvds_data.csv" \
        --sys  "${PROJ_DIR}/build/ila_sys_data.csv" \
        --freq "${RX_FREQ_HZ}"
    ANALYZE_EXIT=$?
else
    WARN "Python3 nicht verfügbar — manuelle Analyse nötig"
    INFO "CSV-Dateien: build/ila_lvds_data.csv, build/ila_sys_data.csv"
    ANALYZE_EXIT=0
fi

# =============================================================================
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ $ANALYZE_EXIT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}Deploy + Test: ERFOLGREICH${NC}"
else
    echo -e "${YELLOW}${BOLD}Deploy fertig — Sync noch nicht bestätigt${NC}"
    echo -e "→ Frequenz/Signalquelle prüfen, dann nochmals:"
    echo -e "  ./scripts/hw_deploy.sh --no-flash --no-ad9361 --timeout 60000"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

exit $ANALYZE_EXIT
