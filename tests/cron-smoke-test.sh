#!/bin/bash
#
# tests/cron-smoke-test.sh <backup-name>
#
# Proves that a CRON-spawned run can actually read the source, rather than
# waiting weeks to find out. Installs a throwaway cron entry that fires in two
# minutes and runs only the preflight (no transfer), waits for it, reports, and
# removes the entry again.
#
# This is the check that catches the macOS Full Disk Access trap: without FDA on
# /usr/sbin/cron, ~/Documents reads as EMPTY from cron, so a real run would
# report SUCCESS having copied nothing.
#
# Your existing crontab is backed up first and every exit path restores it.

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd -P "$SCRIPT_DIR/.." && pwd)
TAG='rsync-backup-scripts:SMOKETEST'

NAME=${1:-}
if [ -z "$NAME" ]; then
    # Auto-detect when exactly one backup is configured.
    set -- "$REPO_ROOT"/config/*/
    if [ $# -eq 1 ] && [ -d "$1" ]; then
        NAME=$(basename "$1")
    else
        echo "usage: $0 <backup-name>" >&2
        echo "configured:" >&2
        ls -1 "$REPO_ROOT/config" 2>/dev/null | sed 's/^/  /' >&2
        exit 64
    fi
fi
[ -d "$REPO_ROOT/config/$NAME" ] || { echo "no such backup: $NAME" >&2; exit 64; }
RUNNER=$REPO_ROOT/backups/$NAME.sh
[ -x "$RUNNER" ] || { echo "missing runner: $RUNNER" >&2; exit 64; }

command -v crontab >/dev/null 2>&1 || { echo "crontab not found" >&2; exit 69; }

LOG_DIR=$REPO_ROOT/logs/$NAME
mkdir -p "$LOG_DIR"

BK=$REPO_ROOT/logs/crontab.backup.smoketest.$(date +%Y-%m-%d_%H%M%S).txt
crontab -l >"$BK" 2>/dev/null
echo "Crontab backed up to: $BK"

strip_block() {
    crontab -l 2>/dev/null | awk -v tag="$TAG" '
        $0 == "# >>> " tag " >>>" { b = 1; next }
        $0 == "# <<< " tag " <<<" { b = 0; next }
        b != 1 { print }'
}

remove_entry() {
    _new=$(strip_block)
    if [ -z "$_new" ]; then
        crontab -r 2>/dev/null
    else
        printf '%s\n' "$_new" | crontab -
    fi
}

cleanup() {
    remove_entry
    if crontab -l 2>/dev/null | grep -q 'SMOKETEST'; then
        echo "WARNING: could not remove the test entry. Restore with:" >&2
        echo "  crontab $BK" >&2
    else
        echo "Test entry removed; your crontab is back to normal."
    fi
}
trap cleanup EXIT INT TERM HUP

# Two minutes from now. BSD date (macOS) and GNU date (Linux) differ.
if date -v+2M '+%M' >/dev/null 2>&1; then
    FIRE_MIN=$(date -v+2M '+%M'); FIRE_HR=$(date -v+2M '+%H')
else
    FIRE_MIN=$(date -d '+2 min' '+%M'); FIRE_HR=$(date -d '+2 min' '+%H')
fi
FIRE_MIN=$((10#$FIRE_MIN)); FIRE_HR=$((10#$FIRE_HR))

BEFORE=$(ls -1 "$LOG_DIR"/*.log 2>/dev/null | wc -l | tr -d ' ')

NEW=$( { strip_block
         printf '# >>> %s >>>\n' "$TAG"
         printf '%d %d * * * /bin/bash %s --preflight --cron >> %s/cron-bootstrap.log 2>&1\n' \
                "$FIRE_MIN" "$FIRE_HR" "$RUNNER" "$LOG_DIR"
         printf '# <<< %s <<<\n' "$TAG"; } )

printf '%s\n' "$NEW" | crontab - || { echo "could not install the test entry" >&2; exit 1; }

printf 'Test entry installed, fires at %02d:%02d (now %s).\n' "$FIRE_HR" "$FIRE_MIN" "$(date '+%H:%M:%S')"
printf 'Waiting up to 3 minutes'

DEADLINE=$(( $(date +%s) + 200 ))
NEWLOG=''
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    sleep 5
    printf '.'
    AFTER=$(ls -1 "$LOG_DIR"/*.log 2>/dev/null | wc -l | tr -d ' ')
    if [ "$AFTER" -gt "$BEFORE" ]; then
        NEWLOG=$(ls -1 "$LOG_DIR"/*.log | sort | tail -1)
        break
    fi
done
printf '\n\n'

if [ -z "$NEWLOG" ]; then
    echo "FAILED: cron never ran the job."
    echo "  The entry was installed correctly, so cron itself is not firing."
    echo "  Check: pgrep -x cron   and   log show --last 5m --predicate 'process == \"cron\"'"
    exit 1
fi

echo "--------------------------------------------------------------"
grep -E 'invoked|source check|WARNING|Full Disk|RESULT|ERROR' "$NEWLOG" | sed 's/^/  /'
echo "--------------------------------------------------------------"

COUNT=$(grep -o 'source check: [0-9]*' "$NEWLOG" | tail -1 | tr -dc '0-9')
BASE=''
[ -f "$LOG_DIR/.baseline_count" ] && BASE=$(cat "$LOG_DIR/.baseline_count")

echo
if [ -z "$COUNT" ]; then
    echo "INCONCLUSIVE: the job ran but produced no source check. See $NEWLOG"
    exit 1
elif [ "$COUNT" -eq 0 ]; then
    echo "FAILED: cron saw an EMPTY source."
    echo "  This is the Full Disk Access trap. Grant it to /usr/sbin/cron in"
    echo "  System Settings > Privacy & Security > Full Disk Access, then log out"
    echo "  and back in (launchctl kickstart is blocked by SIP), and re-run this."
    exit 1
elif [ -n "$BASE" ] && [ "$COUNT" -lt "$BASE" ]; then
    echo "SUSPICIOUS: cron saw $COUNT entries but setup recorded $BASE."
    echo "  Partial visibility usually still means a Full Disk Access problem."
    exit 1
else
    echo "PASSED: cron read $COUNT top-level entries${BASE:+ (baseline $BASE)}."
    echo "  Scheduled backups will see your real data."
fi
