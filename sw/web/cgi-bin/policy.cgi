#!/bin/sh
# policy.cgi — Phase X.4.5 dual-bit policy editor for REG_DB_POLICY @ 0x1AC
#
#   GET                                            -> {ok, accept_unknown_issi,
#                                                       accept_unknown_gssi}
#   POST op=set [accept_unknown_issi=0|1]
#                  [accept_unknown_gssi=0|1]       -> RMW only the bits sent;
#                                                    others are preserved.
# Bit 0 = accept_unknown_issi (Phase 6 A)
# Bit 1 = accept_unknown_gssi (Phase X.3)
# Reset value 0x3 = both bits 1 = M2-compatible behaviour.

REG_HEX=0x43C001AC

reply_err() {
    echo "Content-Type: application/json"
    echo "Status: 400 Bad Request"
    echo ""
    msg=$(echo "$1" | tr -d '"\\')
    printf '{"ok":false,"err":"%s"}\n' "$msg"
    exit 0
}

reply_ok() {
    # $1 = accept_unknown_issi, $2 = accept_unknown_gssi
    echo "Content-Type: application/json"
    echo ""
    printf '{"ok":true,"accept_unknown_issi":%u,"accept_unknown_gssi":%u}\n' \
        "$1" "$2"
    exit 0
}

read_policy() {
    val=$(busybox devmem "$REG_HEX" 32 2>/dev/null)
    case "$val" in
        0x*) echo "$val" ;;
        *)   echo "0x0" ;;
    esac
}

method="${REQUEST_METHOD:-GET}"

if [ "$method" = "GET" ]; then
    CUR=$(read_policy)
    BIT0=$(( $CUR & 0x1 ))
    BIT1=$(( ($CUR >> 1) & 0x1 ))
    reply_ok "$BIT0" "$BIT1"
fi

if [ "$method" != "POST" ]; then
    reply_err "GET or POST required"
fi

# Read request body
LEN=${CONTENT_LENGTH:-0}
case "$LEN" in
    ''|*[!0-9]*) LEN=0 ;;
esac
BODY=""
if [ "$LEN" -gt 0 ]; then
    BODY=$(dd bs=1 count="$LEN" 2>/dev/null)
fi

# Parse form-encoded body, sanitize.  Allow either or both bits.
op=""
au_issi=""
au_gssi=""
au_legacy=""
for kv in $(echo "$BODY" | tr '&' ' '); do
    k=$(echo "$kv" | cut -d= -f1 | sed 's/[^a-zA-Z0-9_]//g')
    v=$(echo "$kv" | cut -d= -f2 | sed 's/[^a-zA-Z0-9._-]//g')
    case "$k" in
        op)                    op="$v" ;;
        accept_unknown_issi)   au_issi="$v" ;;
        accept_unknown_gssi)   au_gssi="$v" ;;
        accept_unknown)        au_legacy="$v" ;;
    esac
done

if [ "$op" != "set" ]; then
    reply_err "unknown op"
fi

# Legacy-compat: old `accept_unknown=...` still maps to Bit 0.
if [ -z "$au_issi" ] && [ -n "$au_legacy" ]; then
    au_issi="$au_legacy"
fi

if [ -z "$au_issi" ] && [ -z "$au_gssi" ]; then
    reply_err "need at least one of accept_unknown_issi / accept_unknown_gssi"
fi

if [ -n "$au_issi" ]; then
    case "$au_issi" in 0|1) ;; *) reply_err "accept_unknown_issi must be 0 or 1" ;; esac
fi
if [ -n "$au_gssi" ]; then
    case "$au_gssi" in 0|1) ;; *) reply_err "accept_unknown_gssi must be 0 or 1" ;; esac
fi

# RMW: read current, mask-and-set only the bits the caller specified.
CUR=$(read_policy)
NEW=$CUR
if [ -n "$au_issi" ]; then
    NEW=$(( ($NEW & ~0x1) | ($au_issi & 0x1) ))
fi
if [ -n "$au_gssi" ]; then
    NEW=$(( ($NEW & ~0x2) | (($au_gssi & 0x1) << 1) ))
fi
busybox devmem "$REG_HEX" 32 "$NEW" >/dev/null 2>&1 || reply_err "devmem write failed"

# Read back
RB=$(read_policy)
RB_BIT0=$(( $RB & 0x1 ))
RB_BIT1=$(( ($RB >> 1) & 0x1 ))
reply_ok "$RB_BIT0" "$RB_BIT1"
