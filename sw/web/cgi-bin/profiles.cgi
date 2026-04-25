#!/bin/sh
# profiles.cgi — Phase 6 D-rev ProfileTable endpoint
#
# GET                                       -> JSON array of all 6 profile slots
# POST op=set slot=N data=0x...             -> write 32-bit profile via AXI
#                                              indirect window 0x1C0/1C4/1CC.
# POST op=set slot=N max=... hangtime=... priority=... gila_class=...
#               gila_lifetime=... permit_voice=... permit_data=...
#               permit_reg=... valid=...    -> field-form (server packs)
#
# 32-bit record (§9.2):
#   [31:24] max_call_duration  (sec, 0=unlimited)
#   [23:16] hangtime           (×100 ms)
#   [15:12] priority
#   [11: 9] gila_class         (M2-default=4)
#   [ 8: 7] gila_lifetime      (M2-default=1)
#   [ 6: 4] reserved
#   [ 3]    permit_voice
#   [ 2]    permit_data
#   [ 1]    permit_reg
#   [ 0]    valid

REG_PROFILE_INDEX=0x43C001C0
REG_PROFILE_DATA=0x43C001C4
REG_PROFILE_CTRL=0x43C001CC
DEPTH=6

emit_json() {
    echo "Content-Type: application/json"
    echo ""
    printf '%s\n' "$1"
}

emit_err() {
    echo "Content-Type: application/json"
    echo "Status: 400 Bad Request"
    echo ""
    msg=$(echo "$1" | tr -d '"\\')
    printf '{"ok":false,"err":"%s"}\n' "$msg"
    exit 0
}

san() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]//g'
}

# ----- Address-table for the 6 ProfileTable slots is held only in BRAM;
# we cannot read back the BRAM directly via AXI (the indirect window
# is write-only in Phase D — readback would need a separate window).
# For GET, we mirror an in-memory shadow file: /var/lib/tetra/profiles.tsv.
# A POST updates BOTH the BRAM (live) and the TSV (persistence).
# The TSV layout: slot<TAB>data_hex
PROFILES_TSV=/var/lib/tetra/profiles.tsv

# ---- helpers to manipulate the TSV ----
read_slot() {
    # $1 = slot index, prints the 32-bit hex value or "0" if unknown.
    if [ -f "$PROFILES_TSV" ]; then
        awk -v s="$1" '$1 == s { print $2; exit }' "$PROFILES_TSV"
    fi
}

write_slot_tsv() {
    # $1 = slot, $2 = hex value
    mkdir -p "$(dirname "$PROFILES_TSV")"
    if [ ! -f "$PROFILES_TSV" ]; then
        printf "# tetra profiles (Phase 6 D-rev §9.2) — slot data_hex\n" > "$PROFILES_TSV"
    fi
    # remove existing entry for this slot, append new
    tmp="${PROFILES_TSV}.tmp"
    awk -v s="$1" '!/^#/ && $1 == s { next } { print }' "$PROFILES_TSV" > "$tmp"
    printf "%s\t%s\n" "$1" "$2" >> "$tmp"
    mv "$tmp" "$PROFILES_TSV"
}

write_slot_axi() {
    # $1 = slot, $2 = 32-bit value (decimal or 0x..)
    busybox devmem "$REG_PROFILE_INDEX" 32 "$1"   >/dev/null 2>&1 || return 1
    busybox devmem "$REG_PROFILE_DATA"  32 "$2"   >/dev/null 2>&1 || return 1
    busybox devmem "$REG_PROFILE_CTRL"  32 0x1    >/dev/null 2>&1 || return 1
    return 0
}

method="${REQUEST_METHOD:-GET}"

if [ "$method" = "POST" ]; then
    len="${CONTENT_LENGTH:-0}"
    case "$len" in ''|*[!0-9]*) len=0 ;; esac
    body=""
    if [ "$len" -gt 0 ] && [ "$len" -lt 8192 ]; then
        body=$(dd bs=1 count="$len" 2>/dev/null)
    fi

    # Parse k=v pairs
    op="" slot="" data=""
    max="" hangtime="" priority="" gila_class="" gila_lifetime=""
    permit_voice="" permit_data="" permit_reg="" valid=""
    for kv in $(echo "$body" | tr '&' ' '); do
        k=$(echo "$kv" | cut -d= -f1 | sed 's/[^a-zA-Z0-9_]//g')
        v=$(echo "$kv" | cut -d= -f2- | sed 's/[^a-zA-Z0-9._-]//g')
        case "$k" in
            op)            op="$v" ;;
            slot)          slot="$v" ;;
            data)          data="$v" ;;
            max)           max="$v" ;;
            hangtime)      hangtime="$v" ;;
            priority)      priority="$v" ;;
            gila_class)    gila_class="$v" ;;
            gila_lifetime) gila_lifetime="$v" ;;
            permit_voice)  permit_voice="$v" ;;
            permit_data)   permit_data="$v" ;;
            permit_reg)    permit_reg="$v" ;;
            valid)         valid="$v" ;;
        esac
    done

    if [ "$op" != "set" ]; then
        emit_err "unknown op"
    fi

    case "$slot" in
        0|1|2|3|4|5) ;;
        *) emit_err "slot out of range (0..5)" ;;
    esac

    # If `data` is provided, use it directly.  Otherwise pack from fields.
    if [ -n "$data" ]; then
        case "$data" in
            0x*) ;;
            *)   data="0x$data" ;;
        esac
    else
        # Default each field to 0 if missing.
        max="${max:-0}"
        hangtime="${hangtime:-0}"
        priority="${priority:-0}"
        gila_class="${gila_class:-4}"
        gila_lifetime="${gila_lifetime:-1}"
        permit_voice="${permit_voice:-1}"
        permit_data="${permit_data:-1}"
        permit_reg="${permit_reg:-1}"
        valid="${valid:-1}"
        # Numeric sanity
        for fv in "$max" "$hangtime" "$priority" "$gila_class" \
                  "$gila_lifetime" "$permit_voice" "$permit_data" \
                  "$permit_reg" "$valid"; do
            case "$fv" in
                ''|*[!0-9]*) emit_err "non-numeric field" ;;
            esac
        done
        # Pack:
        # bits[31:24]=max  [23:16]=hangtime  [15:12]=priority
        # [11:9]=class     [8:7]=lifetime    [6:4]=0
        # [3]=pv  [2]=pd  [1]=pr  [0]=valid
        v=$(( ((max & 0xFF) << 24) |
              ((hangtime & 0xFF) << 16) |
              ((priority & 0xF) << 12) |
              ((gila_class & 0x7) << 9) |
              ((gila_lifetime & 0x3) << 7) |
              ((permit_voice & 0x1) << 3) |
              ((permit_data & 0x1) << 2) |
              ((permit_reg & 0x1) << 1) |
              (valid & 0x1) ))
        data=$(printf "0x%08x" "$v")
    fi

    write_slot_axi "$slot" "$data" || emit_err "AXI write failed"
    write_slot_tsv "$slot" "$data"

    printf 'Content-Type: application/json\n\n'
    printf '{"ok":true,"slot":%s,"data":"%s"}\n' "$slot" "$data"
    exit 0
fi

# ---- GET: list all 6 slots ----
echo "Content-Type: application/json"
echo ""

printf '['
i=0
while [ "$i" -lt "$DEPTH" ]; do
    raw=$(read_slot "$i")
    # If TSV missing, fall back to slot-0 default = 0x0000088F (M2 guard);
    # other slots fall back to 0.
    if [ -z "$raw" ]; then
        if [ "$i" = "0" ]; then
            raw="0x0000088f"
        else
            raw="0x00000000"
        fi
    fi
    # Decode fields.
    n=$(printf "%d" "$raw")
    max=$(( (n >> 24) & 0xFF ))
    hangtime=$(( (n >> 16) & 0xFF ))
    priority=$(( (n >> 12) & 0xF ))
    gila_class=$(( (n >> 9) & 0x7 ))
    gila_lifetime=$(( (n >> 7) & 0x3 ))
    permit_voice=$(( (n >> 3) & 0x1 ))
    permit_data=$(( (n >> 2) & 0x1 ))
    permit_reg=$(( (n >> 1) & 0x1 ))
    valid=$(( n & 0x1 ))

    [ "$i" -gt 0 ] && printf ','
    printf '{"slot":%d,"data":"%s","max":%d,"hangtime":%d,"priority":%d,"gila_class":%d,"gila_lifetime":%d,"permit_voice":%d,"permit_data":%d,"permit_reg":%d,"valid":%d}' \
        "$i" "$raw" "$max" "$hangtime" "$priority" \
        "$gila_class" "$gila_lifetime" \
        "$permit_voice" "$permit_data" "$permit_reg" "$valid"
    i=$((i + 1))
done
printf ']\n'
