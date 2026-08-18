#!/bin/bash
# Installs the engine + CLI WITHOUT the GUI, for the current user (no root):
#   ~/.local/share/rsync-backup-scripts/   the engine (same home the GUI uses)
#   ~/.local/bin/rsyncronizer              the command
# Run from an unpacked release tarball or from a repo clone. User state
# (config/, backups/, logs/, remotes/) is never touched.
set -euo pipefail

self=$(cd "$(dirname "$0")" && pwd)
if [ -f "$self/lib/engine-manifest.txt" ]; then
    src=$self                       # release tarball root
elif [ -f "$self/../lib/engine-manifest.txt" ]; then
    src=$(cd "$self/.." && pwd)     # repo clone (this script lives in cli/)
else
    echo "error: cannot find lib/engine-manifest.txt near $self" >&2
    exit 78
fi

dest=${XDG_DATA_HOME:-$HOME/.local/share}/rsync-backup-scripts
mkdir -p "$dest" "$HOME/.local/bin"

while IFS= read -r f; do
    case $f in ''|'#'*) continue ;; esac
    mkdir -p "$dest/$(dirname "$f")"
    cp "$src/$f" "$dest/$f"
    case $f in
        *.sh|cli/rsyncronizer) chmod 755 "$dest/$f" ;;
    esac
done <"$src/lib/engine-manifest.txt"

ln -sf "$dest/cli/rsyncronizer" "$HOME/.local/bin/rsyncronizer"

echo "Installed $(cat "$dest/VERSION") to $dest"
echo "  command : rsyncronizer   (~/.local/bin must be on PATH)"
echo "  start   : rsyncronizer help"
