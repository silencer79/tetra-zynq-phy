#!/bin/sh
# entities.cgi — Phase E.1 Subscriber-DB endpoint
#   GET                       -> JSON array of all entities
#   POST op=add slot=... issi=... la=... pv=... pd=... pr=... prio=...
#   POST op=del slot=...
#
# Backed by /root/tetra_db_mgr (TSV in /var/lib/tetra/db.tsv +
# AXI indirect window 0x180..0x18C to FPGA shadow BRAM).

DBMGR=/root/tetra_db_mgr

emit_json() {
    echo "Content-Type: application/json"
    echo ""
    printf '%s' "$1"
    echo ""
}

emit_err() {
    # $1 = error message
    echo "Content-Type: application/json"
    echo "Status: 400 Bad Request"
    echo ""
    # crude escaping: drop quotes and backslashes
    msg=$(echo "$1" | tr -d '"\\')
    printf '{"ok":false,"err":"%s"}\n' "$msg"
}

# ---- input sanitizer (alnum + . _ -) ----
san() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]//g'
}

# ---- parse form-encoded body (GET QUERY_STRING or POST stdin) ----
parse_kv() {
    # $1 = raw body  (key=val&key=val&...)
    # emits eval-safe k=sanitized_v lines on stdout
    echo "$1" | tr '&' '\n' | while read kv; do
        [ -z "$kv" ] && continue
        k=$(echo "$kv" | cut -d= -f1)
        v=$(echo "$kv" | cut -d= -f2-)
        # only allow alnum keys
        k_clean=$(echo "$k" | sed 's/[^a-zA-Z0-9_]//g')
        [ -z "$k_clean" ] && continue
        v_clean=$(echo "$v" | sed 's/[^a-zA-Z0-9._-]//g')
        echo "$k_clean=$v_clean"
    done
}

method="${REQUEST_METHOD:-GET}"

if [ "$method" = "POST" ]; then
    # read POST body
    len="${CONTENT_LENGTH:-0}"
    case "$len" in
        ''|*[!0-9]*) len=0 ;;
    esac
    body=""
    if [ "$len" -gt 0 ] && [ "$len" -lt 8192 ]; then
        body=$(dd bs=1 count="$len" 2>/dev/null)
    fi

    eval "$(parse_kv "$body")"

    op=$(san "${op:-}")

    case "$op" in
    add)
        slot=$(san "${slot:-}")
        issi=$(san "${issi:-}")
        la=$(san "${la:-}")
        pv=$(san "${pv:-1}")
        pd=$(san "${pd:-1}")
        pr=$(san "${pr:-1}")
        prio=$(san "${prio:-0}")
        if [ -z "$slot" ] || [ -z "$issi" ] || [ -z "$la" ]; then
            emit_err "missing slot/issi/la"
            exit 0
        fi
        out=$("$DBMGR" add "$slot" "$issi" "$la" "$pv" "$pd" "$pr" "$prio" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            emit_err "tetra_db_mgr add failed: $out"
            exit 0
        fi
        out=$("$DBMGR" sync 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            emit_err "tetra_db_mgr sync failed: $out"
            exit 0
        fi
        emit_json '{"ok":true}'
        exit 0
        ;;
    del)
        slot=$(san "${slot:-}")
        if [ -z "$slot" ]; then
            emit_err "missing slot"
            exit 0
        fi
        out=$("$DBMGR" del "$slot" 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            emit_err "tetra_db_mgr del failed: $out"
            exit 0
        fi
        out=$("$DBMGR" sync 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ]; then
            emit_err "tetra_db_mgr sync failed: $out"
            exit 0
        fi
        emit_json '{"ok":true}'
        exit 0
        ;;
    *)
        emit_err "unknown op"
        exit 0
        ;;
    esac
fi

# ---- GET: list all entities as JSON array ----
# tetra_db_mgr list output:
#   slot  issi    la  v d r prio
#     0 2633617    1  1 1 1    0
#   -- 1 record(s)
list=$("$DBMGR" list 2>/dev/null)

echo "Content-Type: application/json"
echo ""

printf '['
first=1
echo "$list" | while read slot issi la pv pd pr prio rest; do
    # skip header / footer / blanks
    case "$slot" in
        ''|slot|--) continue ;;
    esac
    # require all 7 fields numeric
    case "$slot$issi$la$pv$pd$pr$prio" in
        ''|*[!0-9]*) continue ;;
    esac
    if [ "$first" = "1" ]; then
        first=0
    else
        printf ','
    fi
    printf '{"slot":%s,"issi":%s,"la":%s,"pv":%s,"pd":%s,"pr":%s,"prio":%s}' \
        "$slot" "$issi" "$la" "$pv" "$pd" "$pr" "$prio"
done
printf ']\n'
