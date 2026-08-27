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
    # A leading '?' marks an OPTIONAL entry: ship it if present, skip it if
    # not. bin/rclone is bundled only by the desktop builds; a CLI install
    # uses the system rclone, which detect_rclone finds on its own.
    _opt=''
    case $f in '?'*) _opt=1; f=${f#?} ;; esac
    if [ ! -f "$src/$f" ]; then
        [ -n "$_opt" ] && continue
        echo "error: manifest entry missing from this package: $f" >&2
        exit 78
    fi
    mkdir -p "$dest/$(dirname "$f")"
    # Write to a temp file and RENAME it into place, never cp over the target.
    #
    # cp truncates and rewrites the SAME inode, and bash reads a script
    # incrementally from a byte offset -- so overwriting a script that is
    # currently running makes execution resume inside the NEW bytes. That is
    # not theoretical: `rsyncronizer update` runs this installer from inside
    # the very script it replaces, and 0.2.0 -> 0.3.0 (284 -> 373 lines) landed
    # mid-`case` and died with "syntax error near unexpected token `('".
    #
    # rename(2) gives the new content a NEW inode, so anything already reading
    # the old one keeps a complete, consistent copy to the end. Same protection
    # for lib/common.sh under a backup that is running during an update.
    # chmod BEFORE the rename, so the file is never briefly non-executable.
    cp "$src/$f" "$dest/$f.rbs-new"
    case $f in
        *.sh|cli/rsyncronizer|bin/rclone) chmod 755 "$dest/$f.rbs-new" ;;
    esac
    mv -f "$dest/$f.rbs-new" "$dest/$f"
done <"$src/lib/engine-manifest.txt"

ln -sf "$dest/cli/rsyncronizer" "$HOME/.local/bin/rsyncronizer"

echo "Installed $(cat "$dest/VERSION") to $dest"
echo "  command : rsyncronizer   (~/.local/bin must be on PATH)"
echo "  start   : rsyncronizer help"
