#!/bin/bash
# Installs the Linux build of Rsyncronizer for the current user (no root):
#   ~/.local/opt/rsyncronizer             the app
#   ~/.local/bin/rsyncronizer             launcher symlink
#   ~/.local/share/applications/...       desktop entry (app menu)
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
dest="$HOME/.local/opt/rsyncronizer"

mkdir -p "$dest" "$HOME/.local/bin" "$HOME/.local/share/applications" \
         "$HOME/.local/share/icons/hicolor/256x256/apps"
cp -R "$here/rsyncronizer/." "$dest/"
ln -sf "$dest/rsyncronizer" "$HOME/.local/bin/rsyncronizer"
cp "$dest/_internal/assets/icon-256.png" \
   "$HOME/.local/share/icons/hicolor/256x256/apps/rsyncronizer.png"
sed "s|@EXEC@|$dest/rsyncronizer|" "$here/rsyncronizer.desktop" \
    > "$HOME/.local/share/applications/rsyncronizer.desktop"

echo "Installed."
echo "  app menu : Rsyncronizer"
echo "  terminal : $dest/rsyncronizer   (or just rsyncronizer if ~/.local/bin is on PATH)"
