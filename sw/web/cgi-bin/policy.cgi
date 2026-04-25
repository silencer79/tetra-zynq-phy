#!/bin/sh
# policy.cgi — Phase E live policy toggle
#
# POST op=set&accept_unknown=0|1 → write REG_DB_POLICY @ 0x1AC bit[0]
# Other bits in 0x1AC are preserved (RMW).

echo "Content-Type: application/json"
echo ""

reply_err() {
    printf '{"ok":false,"err":"%s"}\n' "$1"
    exit 0
}
reply_ok() {
    printf '{"ok":true,"accept_unknown":%u}\n' "$1"
    exit 0
}

if [ "$REQUEST_METHOD" != "POST" ]; then
    reply_err "POST required"
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

# Parse form-encoded body, sanitize
op=""
au=""
for kv in $(echo "$BODY" | tr '&' ' '); do
    k=$(echo "$kv" | cut -d= -f1 | sed 's/[^a-zA-Z0-9_]//g')
    v=$(echo "$kv" | cut -d= -f2 | sed 's/[^a-zA-Z0-9._-]//g')
    case "$k" in
        op)              op="$v" ;;
        accept_unknown)  au="$v" ;;
    esac
done

if [ "$op" != "set" ]; then
    reply_err "unknown op"
fi
case "$au" in
    0|1) ;;
    *)   reply_err "accept_unknown must be 0 or 1" ;;
esac

# RMW the policy register so we don't clobber other bits if added later.
CUR=$(busybox devmem 0x43C001AC 32 2>/dev/null)
case "$CUR" in
    0x*) ;;
    *)   CUR="0x0" ;;
esac
NEW=$(( ($CUR & ~0x1) | $au ))
busybox devmem 0x43C001AC 32 "$NEW" >/dev/null 2>&1 || reply_err "devmem write failed"

# Read back to confirm
RB=$(busybox devmem 0x43C001AC 32 2>/dev/null)
case "$RB" in
    0x*) ;;
    *)   RB="0x0" ;;
esac
RB_BIT0=$(( $RB & 0x1 ))
reply_ok "$RB_BIT0"
