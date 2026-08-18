#!/bin/bash
#
# ssh-setup.sh [user@]host -- set up key-based SSH auth to a backup host.
#
#   1. Ensures ~/.ssh/id_ed25519 exists (generated without a passphrase --
#      cron gets no agent, so a passphrase would break every scheduled run).
#   2. ssh-copy-id: you type the account password ONCE, on this terminal
#      (or in the GUI's prompt, which forwards what you type over its pty).
#   3. Verifies the CRON-equivalent path: no agent, no tty, BatchMode.
#
# The password is consumed by ssh itself from the controlling terminal; this
# script never sees, stores, or logs it.

set -uo pipefail

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit "${2:-78}"; }

# Test seams, same pattern as RSYNC_BIN_OVERRIDE.
SSH_BIN=${RBS_SSH_BIN:-ssh}
SSH_COPY_ID_BIN=${RBS_SSH_COPY_ID_BIN:-ssh-copy-id}

TARGET=${1:-}
[ -n "$TARGET" ] || die "usage: ssh-setup.sh [user@]host" 64

# user@host, both parts starting alphanumeric, conservative charset -- an
# option-shaped target (-oProxyCommand=...) must never reach an ssh argv.
case $TARGET in
    [A-Za-z0-9]*) ;;
    *) die "invalid target: $TARGET (must start with a letter or digit)" ;;
esac
case $TARGET in
    *[!A-Za-z0-9._@-]*) die "invalid target: $TARGET (only letters, digits, . _ @ -)" ;;
esac

KEY=$HOME/.ssh/id_ed25519

if [ ! -f "$KEY" ]; then
    say "No $KEY yet -- generating one (ed25519, no passphrase: cron has no agent)."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N '' -f "$KEY" -q || die "ssh-keygen failed" 69
    say "  [ok]   generated $KEY"
else
    say "  [ok]   using the existing key: $KEY"
fi

say ""
say "Copying the public key to $TARGET -- you will be asked for that account's"
say "password ONCE. Nothing is stored; ssh reads it directly."
"$SSH_COPY_ID_BIN" -i "$KEY.pub" -o ConnectTimeout=10 "$TARGET" \
    || die "ssh-copy-id failed -- wrong password, or the host refuses password auth" 69

say ""
say "Verifying the way CRON will connect (no agent, no tty)..."
if env -u SSH_AUTH_SOCK "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=10 -- "$TARGET" true 2>/dev/null; then
    say "  [ok]   key auth to $TARGET works with no agent and no tty (cron-equivalent)"
    say "Done."
else
    die "the key was copied but BatchMode auth still fails -- check the server's sshd config (PubkeyAuthentication) and the account's ~/.ssh permissions" 69
fi
