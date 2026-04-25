#!/bin/sh
# sessions.cgi — Phase E.1 live session/counter dump for the WebUI
#
# Reads AXI counters via devmem and emits a JSON object matching the
# contract documented in the index.html Subscribers tab.
#
# AXI base 0x43C00000 is the TETRA register block.

echo "Content-Type: application/json"
echo ""

# devmem helper — output a 32-bit hex word, default 0 on error
rd() {
    val=$(busybox devmem "$1" 32 2>/dev/null)
    case "$val" in
        0x*) echo "$val" ;;
        *)   echo "0x0" ;;
    esac
}

# unsigned-decimal subset of a 32-bit hex word
hex_lo16()  { printf '%u' "$(( $1 & 0xFFFF ))"; }
hex_hi16()  { printf '%u' "$(( ($1 >> 16) & 0xFFFF ))"; }
hex_bit16() { printf '%u' "$(( ($1 >> 16) & 0x1 ))"; }
hex_bit0()  { printf '%u' "$(( $1 & 0x1 ))"; }
hex_full()  { printf '%u' "$(( $1 ))"; }
hex_lo24()  { printf '%u' "$(( $1 & 0xFFFFFF ))"; }

W_190=$(rd 0x43C00190)   # {accept[31:16], ul_req[15:0]}
W_194=$(rd 0x43C00194)   # {15'b0, busy_sticky[16], drop[15:0]}
W_198=$(rd 0x43C00198)   # {clear[31:16], sig_override[15:0]}
W_1A4=$(rd 0x43C001A4)   # {0, detach[15:0]}
W_1B0=$(rd 0x43C001B0)   # {0, evict[15:0]}
W_1A8=$(rd 0x43C001A8)   # ttl_multiframes
W_1AC=$(rd 0x43C001AC)   # {..., accept_unknown[0]}
W_168=$(rd 0x43C00168)   # last MTP3550 mailbox ISSI (24-bit)

ul_req=$(hex_lo16 "$W_190")
accept=$(hex_hi16 "$W_190")
drop=$(hex_lo16 "$W_194")
busy=$(hex_bit16 "$W_194")
sig_override=$(hex_lo16 "$W_198")
clear=$(hex_hi16 "$W_198")
detach=$(hex_lo16 "$W_1A4")
evict=$(hex_lo16 "$W_1B0")
ttl_mfs=$(hex_full "$W_1A8")
policy_acc_unknown=$(hex_bit0 "$W_1AC")
last_issi=$(hex_lo24 "$W_168")
last_issi_hex=$(printf '0x%06X' "$last_issi")

# tail recent UL-mon log lines as a JSON string array
log=/tmp/tetra_ul_mon.log
recent_ul_mon='[]'
if [ -r "$log" ]; then
    # Build JSON array; quote-escape minimally (drop \ and ").
    # Use awk to keep this dependency-free on busybox.
    recent_ul_mon=$(tail -20 "$log" 2>/dev/null | awk '
        BEGIN { printf "[" }
        {
            gsub(/\\/, "", $0)
            gsub(/"/,  "", $0)
            gsub(/\r/, "", $0)
            gsub(/\t/, " ", $0)
            if (NR > 1) printf ","
            printf "\"%s\"", $0
        }
        END { printf "]" }
    ')
    [ -z "$recent_ul_mon" ] && recent_ul_mon='[]'
fi

cat <<EOF
{"counters":{"ul_req":${ul_req},"accept":${accept},"drop":${drop},"detach":${detach},"evict":${evict},"sig_override":${sig_override},"clear":${clear},"busy_sticky":${busy}},"last_issi":${last_issi},"last_issi_hex":"${last_issi_hex}","ttl_mfs":${ttl_mfs},"policy_accept_unknown":${policy_acc_unknown},"recent_ul_mon":${recent_ul_mon}}
EOF
