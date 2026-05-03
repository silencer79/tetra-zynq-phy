#!/bin/sh
# sessions.cgi — Phase X.4.5 live session/counter dump for the WebUI
#
# Drops AST counters (REG_AST_DETACH_CNT/TTL_MULTIFRAMES/TTL_EVICT_CNT —
# all gone since Phase X.4 cut) and adds the new Thin-Signaling status:
#   - REG_DEMAND_STATUS  (0x200) -> demand_pending, demand_drop_cnt
#   - REG_REPLY_USE_SW   (0x230) -> reply_use_sw
#   - REG_NWRK_BCAST_CNT (0x1E4) -> nwrk_push_cnt
#   - /root/db.tsv parse         -> db_issi_cnt, db_gssi_cnt, db_total
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

hex_lo16()  { printf '%u' "$(( $1 & 0xFFFF ))"; }
hex_hi16()  { printf '%u' "$(( ($1 >> 16) & 0xFFFF ))"; }
hex_bit16() { printf '%u' "$(( ($1 >> 16) & 0x1 ))"; }
hex_bit0()  { printf '%u' "$(( $1 & 0x1 ))"; }
hex_bit1()  { printf '%u' "$(( ($1 >> 1) & 0x1 ))"; }
hex_lo24()  { printf '%u' "$(( $1 & 0xFFFFFF ))"; }

W_190=$(rd 0x43C00190)   # {accept[31:16], ul_req[15:0]}
W_194=$(rd 0x43C00194)   # {15'b0, busy_sticky[16], drop[15:0]}
W_198=$(rd 0x43C00198)   # {clear[31:16], sig_override[15:0]}
W_1AC=$(rd 0x43C001AC)   # {..., accept_unknown_gssi[1], accept_unknown_issi[0]}
W_168=$(rd 0x43C00168)   # last MTP3550 mailbox ISSI (24-bit)
W_1E0=$(rd 0x43C001E0)   # {drop[31:16], reassembled[15:0]} — F.3 reassembly
W_1E4=$(rd 0x43C001E4)   # [15:0] D-NWRK-BCAST sticky push counter
W_200=$(rd 0x43C00200)   # {drop_cnt[31:16], 15'd0, pending[0]}
W_230=$(rd 0x43C00230)   # [0] reply_use_sw

ul_req=$(hex_lo16 "$W_190")
accept=$(hex_hi16 "$W_190")
drop=$(hex_lo16 "$W_194")
busy=$(hex_bit16 "$W_194")
sig_override=$(hex_lo16 "$W_198")
clear=$(hex_hi16 "$W_198")
policy_acc_issi=$(hex_bit0 "$W_1AC")
policy_acc_gssi=$(hex_bit1 "$W_1AC")
last_issi=$(hex_lo24 "$W_168")
last_issi_hex=$(printf '0x%06X' "$last_issi")
reassembled_cnt=$(hex_lo16 "$W_1E0")
reassembly_drop_cnt=$(hex_hi16 "$W_1E0")
nwrk_push_cnt=$(hex_lo16 "$W_1E4")
demand_pending=$(hex_bit0 "$W_200")
demand_drop_cnt=$(hex_hi16 "$W_200")
reply_use_sw=$(hex_bit0 "$W_230")

# db.tsv stats — count valid rows, split by entity_type (0=ISSI, 1=GSSI).
DB=/root/db.tsv
db_issi_cnt=0
db_gssi_cnt=0
db_total=0
if [ -r "$DB" ]; then
    counts=$(awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
            if ($3 == 0) issi++
            else if ($3 == 1) gssi++
            total++
        }
        END { printf "%d %d %d", issi+0, gssi+0, total+0 }
    ' "$DB")
    db_issi_cnt=$(echo "$counts" | awk '{print $1}')
    db_gssi_cnt=$(echo "$counts" | awk '{print $2}')
    db_total=$(echo "$counts" | awk '{print $3}')
fi

# tail recent UL-mon log lines as a JSON string array
log=/tmp/tetra_ul_mon.log
recent_ul_mon='[]'
if [ -r "$log" ]; then
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
{"counters":{"ul_req":${ul_req},"accept":${accept},"drop":${drop},"sig_override":${sig_override},"clear":${clear},"busy_sticky":${busy},"reassembled_cnt":${reassembled_cnt},"reassembly_drop_cnt":${reassembly_drop_cnt},"nwrk_push_cnt":${nwrk_push_cnt},"demand_drop_cnt":${demand_drop_cnt}},"last_issi":${last_issi},"last_issi_hex":"${last_issi_hex}","policy_accept_unknown_issi":${policy_acc_issi},"policy_accept_unknown_gssi":${policy_acc_gssi},"demand_pending":${demand_pending},"reply_use_sw":${reply_use_sw},"db":{"issi_cnt":${db_issi_cnt},"gssi_cnt":${db_gssi_cnt},"total":${db_total}},"recent_ul_mon":${recent_ul_mon}}
EOF
