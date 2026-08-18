#!/bin/bash
#
# lib/wait-for-mount.sh <backup-name>
#
# Bridges the gap between udev's "device added" event and udisks actually having
# the filesystem mounted -- those are not the same moment, and the difference is
# typically a second or two. Called by the systemd service on Linux; not used on
# macOS, where launchd's StartOnMount already fires after the mount completes.
#
# Waits only for the volume this backup expects, and only for a bounded time.
# If it never appears, the runner's own assert_volume_ready refuses to write.

set -uo pipefail

_src=${BASH_SOURCE[0]:-$0}
while [ -h "$_src" ]; do
    _dir=$(cd -P "$(dirname -- "$_src")" && pwd)
    _src=$(readlink -- "$_src")
    case $_src in /*) ;; *) _src=$_dir/$_src ;; esac
done
REPO_ROOT=$(cd -P "$(dirname -- "$_src")/.." && pwd)
unset _src _dir

NAME=${1:-}
[ -n "$NAME" ] || { echo "usage: wait-for-mount.sh <backup-name>" >&2; exit 64; }

CFG=$REPO_ROOT/config/$NAME
RUNNER=$REPO_ROOT/backups/$NAME.sh
[ -x "$RUNNER" ] || { echo "missing runner: $RUNNER" >&2; exit 78; }

# Read VOLUME_ROOT without sourcing the config (same rule as everywhere else).
VOL=$(awk -F= '/^[[:space:]]*VOLUME_ROOT[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]]*$/,""); print; exit}' \
      "$CFG/destination.txt" 2>/dev/null)

if [ -n "$VOL" ]; then
    # 30 s is generous for udisks; the cost of being wrong is only that the
    # runner declines, and the next replug tries again.
    n=0
    while [ "$n" -lt 60 ]; do
        if [ -f "$VOL/.rsync-backup-volume" ]; then
            break
        fi
        sleep 0.5
        n=$((n + 1))
    done
fi

exec /bin/bash "$RUNNER" --on-mount
