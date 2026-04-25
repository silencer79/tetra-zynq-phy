#!/bin/sh
# tetra_dbsync — Phase 6 E.4
#
# Poll /var/lib/tetra/db.tsv mtime; on change, push to FPGA EntityTable
# BRAM via tetra_db_mgr sync. busybox on the LibreSDR has no inotifyd, so
# we use a 2 s mtime poll — good enough for operator edits and for the
# tetra_autoenroll-driven append flow.
#
# Started in background by scripts/deploy.sh --init.

set -u

DBMGR=/root/tetra_db_mgr
DB_FILE=/var/lib/tetra/db.tsv
POLL_SEC=2

log() { echo "[dbsync] $*"; }

log "started, polling $DB_FILE every ${POLL_SEC}s"

last_mtime=0
while true; do
    if [ -f "$DB_FILE" ]; then
        cur=$(stat -c %Y "$DB_FILE" 2>/dev/null)
        cur=${cur:-0}
        if [ "$cur" -ne "$last_mtime" ] && [ "$cur" -gt 0 ]; then
            out=$("$DBMGR" sync 2>&1)
            rc=$?
            if [ "$rc" -eq 0 ]; then
                log "$DB_FILE changed (mtime=$cur) → $out"
                last_mtime=$cur
            else
                log "sync FAILED (rc=$rc): $out"
                # Don't update last_mtime so we retry next tick.
            fi
        fi
    fi
    sleep "$POLL_SEC"
done
