#!/bin/sh
# entities.cgi — Phase X.4.5 SW-only db.tsv editor
#
#   GET                                       -> JSON array of all entities
#   POST op=add slot=N entity_id=M
#                  entity_type=T profile_id=P -> append/replace TSV row
#   POST op=del slot=N                        -> drop TSV row(s) for slot
#
# Source-of-truth = /root/db.tsv (single owner: tetra_attach_daemon).
# Daemon picks up changes via mtime poll (5 s); no RTL round-trip needed.
#
# TSV record layout (ARCHITECTURE.md §9.2 — kept stable across X.4 cut):
#   slot  entity_id  entity_type  profile_id
#     N      0..0xFFFFFF   0|1       0..5
# Columns are TAB- or whitespace-separated; '#' and blank lines = comments.

DB=/root/db.tsv
TMP=/tmp/db.tsv.NEW

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

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

# -------------------------------------------------------------------
# parse_kv — split URL-form body into k=v lines (sanitised).
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

# -------------------------------------------------------------------
# read_db_rows — emit one "slot eid etype prof" line per valid record.
# Skips comments (#...), blank lines, leading whitespace, malformed rows.
read_db_rows() {
    [ -r "$DB" ] || return 0
    awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            sl=$1; eid=$2; et=$3; pr=$4
            if (sl ~ /^[0-9]+$/ && eid ~ /^[0-9]+$/ && \
                et ~ /^[0-9]+$/ && pr ~ /^[0-9]+$/) {
                print sl, eid, et, pr
            }
        }
    ' "$DB"
}

# -------------------------------------------------------------------
# slot_in_use — return 0 if slot N is currently bound, else 1.
slot_in_use() {
    s="$1"
    read_db_rows | awk -v s="$s" '$1 == s { found=1 } END { exit !found }'
}

# -------------------------------------------------------------------
# next_free_slot — print first free slot 0..255 that has no row.
next_free_slot() {
    used=$(read_db_rows | awk '{ print $1 }')
    i=0
    while [ "$i" -le 255 ]; do
        if ! echo "$used" | grep -q "^${i}$"; then
            echo "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# -------------------------------------------------------------------
# write_atomic — write stdin to /tmp/db.tsv.NEW, then rename.
# Caller pipes the full new file content into this function.
write_atomic() {
    cat > "$TMP" || return 1
    mv "$TMP" "$DB" || return 1
    return 0
}

# -------------------------------------------------------------------
# emit_db_header — write the standard TSV preamble.
emit_db_header() {
    cat <<'HEAD'
# tetra entity DB (Phase 6 D-rev §9.2) — slot entity_id entity_type profile_id
# entity_type: 0=ISSI, 1=GSSI
# Managed by sw/web/cgi-bin/entities.cgi (atomic via /tmp/db.tsv.NEW + rename).
# Daemon owner: tetra_attach_daemon (mtime-poll reload, ~5 s).
HEAD
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

        # entity_id is mandatory; slot is optional (auto-find).
        if [ -z "$entity_id" ]; then
            emit_err "missing entity_id"
        fi
        for fv in "$entity_id" "$entity_type" "$profile_id"; do
            is_uint "$fv" || emit_err "non-numeric field"
        done
        # Numeric-range checks
        if [ "$entity_id" -gt 16777215 ]; then
            emit_err "entity_id out of range (0..0xFFFFFF)"
        fi
        case "$entity_type" in
            0|1) ;;
            *)   emit_err "entity_type must be 0 (ISSI) or 1 (GSSI)" ;;
        esac
        case "$profile_id" in
            0|1|2|3|4|5) ;;
            *)           emit_err "profile_id out of range (0..5)" ;;
        esac

        if [ -z "$slot" ]; then
            slot=$(next_free_slot) || emit_err "no free slot (0..255 full)"
        else
            is_uint "$slot" || emit_err "slot must be unsigned int"
            if [ "$slot" -gt 255 ]; then
                emit_err "slot out of range (0..255)"
            fi
            if slot_in_use "$slot"; then
                emit_err "slot $slot already in use"
            fi
        fi

        # Atomic write: header + existing rows (minus this slot) + new row.
        {
            emit_db_header
            read_db_rows | awk -v s="$slot" '$1 != s { print }' | \
                awk '{ printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }'
            printf '%s\t%s\t%s\t%s\n' "$slot" "$entity_id" \
                "$entity_type" "$profile_id"
        } | write_atomic || emit_err "write failed"

        emit_json "$(printf '{"ok":true,"slot":%s}' "$slot")"
        ;;
    del)
        slot=$(san "${slot:-}")
        if [ -z "$slot" ]; then
            emit_err "missing slot"
        fi
        is_uint "$slot" || emit_err "slot must be unsigned int"

        {
            emit_db_header
            read_db_rows | awk -v s="$slot" '$1 != s { print }' | \
                awk '{ printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4 }'
        } | write_atomic || emit_err "write failed"

        emit_json '{"ok":true}'
        ;;
    *)
        emit_err "unknown op"
        ;;
    esac
fi

# ---- GET: list all entities as JSON array ----
echo "Content-Type: application/json"
echo ""

printf '['
first=1
read_db_rows | while read sl eid et pr; do
    if [ "$first" = "1" ]; then
        first=0
    else
        printf ','
    fi
    printf '{"slot":%s,"entity_id":%s,"entity_type":%s,"profile_id":%s,"valid":1}' \
        "$sl" "$eid" "$et" "$pr"
done
printf ']\n'
