#!/bin/bash
#
# remote.sh -- drive ANOTHER machine's engine over ssh.
#
#   ./remote.sh list
#   ./remote.sh add <label> <host> <engine-path>
#   ./remote.sh rm <label>
#   ./remote.sh <label> status
#   ./remote.sh <label> run|dry|sync-deletions <backup-name>
#
# Remotes live in remotes/<label>.txt (HOST=, ENGINE_PATH=), parsed with
# config_get and never sourced. Everything that reaches an ssh command line is
# validated or quoted here:
#   - label and backup name: [A-Za-z0-9._-]+ only
#   - HOST: first char alphanumeric, then [A-Za-z0-9._@-] only (a host shaped
#     like an ssh option, e.g. -oProxyCommand=..., is refused), and always
#     placed after `--` in the argv
#   - ENGINE_PATH: single-quote-escaped into the remote command; a leading ~/
#     stays outside the quotes so the remote shell expands it
#
# Every invocation carries BatchMode=yes + ConnectTimeout=5: a broken key is a
# clean exit-255 "run ssh-setup", never a password prompt hanging a frontend.
# For run/dry/sync-deletions, -t allocates a remote tty when the local side is
# one (the GUI's pty or a real terminal), so the remote engine's interactive
# sync-deletions gate runs honestly and its prompts stream back byte-identical.
#
# Connection-loss contract: a clean EOF at the remote confirmation prompt is a
# decline (remote exits 75); a dropped connection delivers SIGHUP (remote exits
# 143) with the lock released and bookkeeping untouched. Deletions run only
# after the transfer (--delete-after), so a drop mid-transfer deletes nothing;
# a drop during the final deletion phase leaves a partial prune, exactly like a
# local Ctrl-C.

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$SCRIPT_DIR

. "$REPO_ROOT/lib/common.sh"

# Test seam, same pattern as RSYNC_BIN_OVERRIDE: the suite points this at
# tests/fake-ssh to exercise every path without a network.
SSH_BIN=${RBS_SSH_BIN:-ssh}

REMOTES_DIR=$REPO_ROOT/remotes

_valid_name() {
    case $1 in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

_valid_host() {
    case $1 in
        [A-Za-z0-9]*) ;;
        *) return 1 ;;
    esac
    case $1 in
        *[!A-Za-z0-9._@-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# _sq STRING -- single-quote-escape for embedding in a remote command.
_sq() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# _cd_expr PATH -- a safe `cd ...` for the remote shell.
_cd_expr() {
    case $1 in
        -*) die 78 "ENGINE_PATH may not begin with '-': $1" ;;
        "~") printf 'cd ~' ;;
        "~/"*) printf "cd ~/'%s'" "$(_sq "${1#\~/}")" ;;
        *) printf "cd '%s'" "$(_sq "$1")" ;;
    esac
}

_load_remote() {          # sets RHOST, RCD from remotes/<label>.txt
    _lr_label=$1
    _valid_name "$_lr_label" || die 78 "invalid remote label: $_lr_label"
    _lr_file=$REMOTES_DIR/$_lr_label.txt
    [ -f "$_lr_file" ] || die 78 "no remote named '$_lr_label' (looked in $_lr_file); add it with: remote.sh add $_lr_label <host> <engine-path>"
    RHOST=$(config_get "$_lr_file" HOST)
    _lr_path=$(config_get "$_lr_file" ENGINE_PATH)
    _valid_host "$RHOST" || die 78 "remote '$_lr_label' has an invalid HOST ('$RHOST') -- edit $_lr_file"
    [ -n "$_lr_path" ] || die 78 "remote '$_lr_label' has no ENGINE_PATH -- edit $_lr_file"
    RCD=$(_cd_expr "$_lr_path")
}

_ssh() {                  # _ssh [-t] COMMAND -- argv shape shared by all calls
    if [ "$1" = -t ]; then
        shift
        "$SSH_BIN" -t -o BatchMode=yes -o ConnectTimeout=5 -- "$RHOST" "$1"
    else
        "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 -- "$RHOST" "$1"
    fi
}

_handshake() {            # prints the remote VERSION, or dies with the reason
    _hs_out=$(_ssh "$RCD && if [ -f VERSION ]; then cat VERSION; else echo NOVERSION; fi" 2>&1)
    _hs_rc=$?
    if [ "$_hs_rc" = 255 ]; then
        die 69 "cannot reach '$RHOST' (ssh exit 255) -- network down or key auth broken; run: ./ssh-setup.sh <user@host>"
    fi
    if [ "$_hs_rc" != 0 ]; then
        die 78 "engine path not found on '$RHOST' -- check ENGINE_PATH ($_hs_out)"
    fi
    case $_hs_out in
        *NOVERSION*) die 78 "the engine on '$RHOST' is too old (no VERSION file) -- git pull there" ;;
    esac
    printf '%s' "$_hs_out" | tail -1
}

case ${1:-} in
    list)
        [ -d "$REMOTES_DIR" ] || exit 0
        for _f in "$REMOTES_DIR"/*.txt; do
            [ -f "$_f" ] || continue
            _l=$(basename "$_f" .txt)
            printf '%s\t%s\t%s\n' "$_l" \
                "$(config_get "$_f" HOST)" "$(config_get "$_f" ENGINE_PATH)"
        done
        exit 0
        ;;
    add)
        [ $# -eq 4 ] || die 64 "usage: remote.sh add <label> <host> <engine-path>"
        _valid_name "$2" || die 78 "invalid label: $2 (letters, digits, dot, underscore, hyphen)"
        _valid_host "$3" || die 78 "invalid host: $3 (must start alphanumeric; only letters, digits, . _ @ -)"
        case $4 in -*) die 78 "engine path may not begin with '-'" ;; esac
        mkdir -p "$REMOTES_DIR" || die 74 "cannot create $REMOTES_DIR"
        {
            echo "# Remote engine for '$2'. HOST is an ssh alias/hostname;"
            echo "# ENGINE_PATH is where the engine (or a repo clone) lives there."
            echo "HOST=$3"
            echo "ENGINE_PATH=$4"
        } >"$REMOTES_DIR/$2.txt"
        echo "added remote '$2' ($3:$4)"
        exit 0
        ;;
    rm)
        [ $# -eq 2 ] || die 64 "usage: remote.sh rm <label>"
        _valid_name "$2" || die 78 "invalid label: $2"
        [ -f "$REMOTES_DIR/$2.txt" ] || die 78 "no remote named '$2'"
        rm -f "$REMOTES_DIR/$2.txt"
        echo "removed remote '$2' (the remote machine itself is untouched)"
        exit 0
        ;;
    "")
        die 64 "usage: remote.sh list | add <label> <host> <path> | rm <label> | <label> status|run|dry|sync-deletions [name]"
        ;;
esac

LABEL=$1
ACTION=${2:-}
_load_remote "$LABEL"

case $ACTION in
    status)
        RVER=$(_handshake) || exit $?
        # REMOTE_VERSION joins the porcelain header block (no blank line
        # between them), so parsers see it as one header.
        printf 'REMOTE_VERSION=%s\n' "$RVER"
        _ssh "$RCD && ./status.sh --porcelain"
        exit $?
        ;;
    run|dry|sync-deletions)
        NAME=${3:-}
        _valid_name "$NAME" || die 78 "invalid or missing backup name: '$NAME'"
        # RBS_NO_SUPPORT_NAG is presentational only: ssh -t gives the remote
        # engine a terminal, and without it the support reminder's QR would
        # leak into the streamed console. Old engines ignore the variable.
        case $ACTION in
            run)  _rcmd="$RCD && RBS_NO_SUPPORT_NAG=1 ./backups/$NAME.sh" ;;
            dry)  _rcmd="$RCD && RBS_NO_SUPPORT_NAG=1 ./backups/$NAME.sh --dry-run" ;;
            sync-deletions) _rcmd="$RCD && RBS_NO_SUPPORT_NAG=1 ./backups/$NAME.sh --sync-deletions" ;;
        esac
        _ssh -t "$_rcmd"
        exit $?
        ;;
    *)
        die 64 "unknown action '$ACTION' (accepts status, run, dry, sync-deletions)"
        ;;
esac
