#!/bin/sh
# entities.cgi — Phase 6 D-rev EntityTable endpoint
#   GET                                     -> JSON array of all entities
#   POST op=add slot=... entity_id=...
#                entity_type=... profile_id=...
#   POST op=del slot=...
#
# Backed by /root/tetra_db_mgr (TSV in /var/lib/tetra/db.tsv +
# AXI indirect window 0x180..0x18C to FPGA EntityTable BRAM).
#
# Record layout per docs/ARCHITECTURE.md §9.2:
#   entity_id   24 bit (ISSI ODER GSSI)
#   entity_type  1 bit (0=ISSI, 1=GSSI)
#   profile_id   4 bit (index into ProfileTable, 0..5)
#   valid        1 bit

DBMGR=/root/tetra_db_mgr

emit_json() {
    echo "Content-Type: application/json"
    echo ""
    printf '%s' "$1"
    echo ""
}

emit_err() {
    echo "Content-Type: application/json"
    echo "Status: 400 Bad Request"
    echo ""
    msg=$(echo "$1" | tr -d '"\\')
    printf '{"ok":false,"err":"%s"}\n' "$msg"
}

san() {
    echo "$1" | sed 's/[^a-zA-Z0-9._-]//g'
}

parse_kv() {
    echo "$1" | tr '&' '\n' | while read kv; do
        [ -z "$kv" ] && continue
        k=$(echo "$kv" | cut -d= -f1)
        v=$(echo "$kv" | cut -d= -f2-)
        k_clean=$(echo "$k" | sed 's/[^a-zA-Z0-9_]//g')
        [ -z "$k_clean" ] && continue
        v_clean=$(echo "$v" | sed 's/[^a-zA-Z0-9._-]//g')
        echo "$k_clean=$v_clean"
    done
}

method="${REQUEST_METHOD:-GET}"

if [ "$method" = "POST" ]; then
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
        entity_id=$(san "${entity_id:-}")
        entity_type=$(san "${entity_type:-0}")
        profile_id=$(san "${profile_id:-0}")
        if [ -z "$slot" ] || [ -z "$entity_id" ]; then
            emit_err "missing slot/entity_id"
            exit 0
        fi
        out=$("$DBMGR" add "$slot" "$entity_id" "$entity_type" "$profile_id" 2>&1)
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
#   slot  entity_id  type profile
#     0   2633617    0    0
#   -- 2 record(s)
list=$("$DBMGR" list 2>/dev/null)

echo "Content-Type: application/json"
echo ""

printf '['
first=1
echo "$list" | while read slot entity_id etype prof rest; do
    case "$slot" in
        ''|slot|--) continue ;;
    esac
    case "$slot$entity_id$etype$prof" in
        ''|*[!0-9]*) continue ;;
    esac
    if [ "$first" = "1" ]; then
        first=0
    else
        printf ','
    fi
    printf '{"slot":%s,"entity_id":%s,"entity_type":%s,"profile_id":%s,"valid":1}' \
        "$slot" "$entity_id" "$etype" "$prof"
done
printf ']\n'
