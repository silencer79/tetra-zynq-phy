#!/bin/sh
# tetra_autoenroll — Phase 6 E.5
#
# Watch /tmp/tetra_ul_mon.log for unknown ISSIs and append them to
# /var/lib/tetra/db.tsv with profile_id=0 (M2 default).  tetra_dbsync
# (E.4) then picks up the TSV change and pushes the new EntityTable
# slot to BRAM, so a fresh MS attach succeeds without operator action.
#
# Gated by REG_DB_POLICY @ 0x1AC bit 0 (accept_unknown):
#   1 = OPEN   → enroll new ISSIs.
#   0 = STRICT → leave unknown ISSIs alone (operator-only).
#
# Started in background by scripts/deploy.sh --init.

set -u

DBMGR=/root/tetra_db_mgr
LOG=/tmp/tetra_ul_mon.log
DB_FILE=/var/lib/tetra/db.tsv
POLICY_REG=0x43C001AC

log() { echo "[autoenroll] $*"; }

# Wait for ul_mon to create the log (it spawns a moment after we do).
while [ ! -f "$LOG" ]; do
    sleep 1
done
log "started, watching $LOG"

# Stream the log forever.  -F follows renames/rotation as well.
tail -F "$LOG" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *ssi=*\(0x*\)*) ;;
        *) continue ;;
    esac

    # Extract decimal ssi from "...ssi=NNNNN (0xNNNNNN)..."
    ssi=$(echo "$line" | sed -n 's/.*ssi=\([0-9][0-9]*\) (.*/\1/p')
    [ -z "$ssi" ] && continue

    # Read REG_DB_POLICY; bit 0 must be 1 to enroll.
    pol_hex=$(busybox devmem "$POLICY_REG" 32 2>/dev/null)
    case "$pol_hex" in
        0x*) pol=$(printf '%d' "$pol_hex") ;;
        *)   continue ;;
    esac
    if [ "$((pol & 1))" -eq 0 ]; then
        continue
    fi

    # Skip if entity_id already in TSV.
    if [ -f "$DB_FILE" ]; then
        if awk -v id="$ssi" '
            /^#/ { next }
            $1 ~ /^[0-9]+$/ && $2 == id { found=1; exit }
            END { exit !found }
        ' "$DB_FILE"; then
            continue
        fi
    fi

    # Find first unused slot 0..255.
    slot=$(awk '
        /^#/ { next }
        $1 ~ /^[0-9]+$/ { used[$1]=1 }
        END {
            for (i=0; i<256; i++) if (!used[i]) { print i; exit }
        }
    ' "$DB_FILE" 2>/dev/null)
    if [ -z "$slot" ]; then
        log "EntityTable full, cannot enroll ISSI $ssi"
        continue
    fi

    # Append + tetra_dbsync (E.4) will push to BRAM on next poll tick.
    out=$("$DBMGR" add "$slot" "$ssi" 0 0 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log "enrolled ISSI $ssi → slot $slot (entity_type=ISSI, profile_id=0)"
    else
        log "tetra_db_mgr add failed for ISSI $ssi: $out"
    fi
done
