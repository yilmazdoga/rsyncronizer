#!/bin/bash
#
# setup.sh -- interactive wizard. Configures one backup on this machine:
# writes config/<name>/, generates backups/<name>.sh, and optionally installs a
# cron entry. Safe to re-run: existing values are offered as defaults.

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$SCRIPT_DIR
CRON_TAG_PREFIX='rsync-backup-scripts'

. "$REPO_ROOT/lib/common.sh"

# ---------------------------------------------------------------------------
# Headless mode: --answers FILE supplies every prompt's answer as KEY=VALUE
# (parsed with config_get, never sourced). Built for the GUI apps; usable by
# hand. One key per prompt site:
#   A_NAME A_SOURCE A_DEST_KIND A_HOST A_USER A_DEST_PATH A_VOLUME_ROOT
#   A_CLOUD_PROVIDER A_RCLONE_REMOTE A_CREATE_REMOTE
#   A_CONFIRM_LANDING A_EXCLUDE_OFFER A_EXCLUDE_ADD A_EXCLUDE_MORE
#   A_CREATE_DEST A_RUN_DRY_RUN A_INSTALL_TRIGGER A_TRIGMODE
#   A_SCHEDULE_YN A_SCHEDULE_CHOICE A_SCHEDULE_CUSTOM A_CRON_CONFIRM
#   A_CRON_REMOVE A_REMOVE (for --remove NAME)
# A_DEST_KIND is 1 = another machine over SSH, 2 = a local drive, 3 = cloud.
# There are deliberately NO keys for cloud credentials: an answers file is a
# plain file on disk, and an access key does not belong in one. rclone owns
# every secret, and a remote that does not exist yet is a hard error in
# headless mode rather than something this script tries to create.
# An absent key behaves exactly like pressing Enter: the prompt's default, and
# for a [y/N] confirm the safe N. A_USER also accepts the sentinel @none for
# an explicitly blank username (absent means "accept the ssh -G prefill").
# Headless supports at most ONE exclude-picker entry (A_EXCLUDE_MORE must stay
# n/absent); the GUI writes config/<name>/exclude.txt directly instead.
# ---------------------------------------------------------------------------
ANSWERS_FILE=''
REMOVE_NAME=''
while [ $# -gt 0 ]; do
    case $1 in
        --answers)
            shift
            [ $# -gt 0 ] || { echo "--answers needs a file argument" >&2; exit 64; }
            ANSWERS_FILE=$1
            ;;
        --remove)
            shift
            [ $# -gt 0 ] || { echo "--remove needs a backup name" >&2; exit 64; }
            REMOVE_NAME=$1
            ;;
        *) echo "unknown argument: $1 (accepts --answers FILE, --remove NAME)" >&2; exit 64 ;;
    esac
    shift
done

if [ -z "$ANSWERS_FILE" ] && [ ! -t 0 ]; then
    echo "setup.sh is interactive and must be run from a terminal (or use --answers FILE)." >&2
    exit 1
fi

RBS_ANSWER_STATE=''
_headless_abort() {
    if [ -n "$RBS_ANSWER_STATE" ] && [ -f "$RBS_ANSWER_STATE/error" ]; then
        printf 'ERROR: %s\n' "$(cat "$RBS_ANSWER_STATE/error")" >&2
    else
        printf 'ERROR: headless run aborted\n' >&2
    fi
    rm -rf "$RBS_ANSWER_STATE"
    exit 78
}
if [ -n "$ANSWERS_FILE" ]; then
    [ -f "$ANSWERS_FILE" ] || { echo "answers file not found: $ANSWERS_FILE" >&2; exit 78; }
    RBS_ANSWER_STATE=$(mktemp -d) || exit 74
    trap 'rm -rf "$RBS_ANSWER_STATE"' EXIT
    trap _headless_abort TERM
fi

# ---------------------------------------------------------------------------
# Prompt helpers. Prompts go to stderr so $( ) captures only the answer.
#
# Every ask site runs inside $(...), i.e. a SUBSHELL: nothing set in here
# reaches the wizard, and a die here would kill only the subshell while the
# wizard marched on with an empty value. So in headless mode the repeat-serve
# record lives in a FILE, and the abort is delivered with `kill -TERM $$` --
# $$ is the wizard's own PID even inside $(...), so the TERM trap above turns
# it into a clean exit 78. Being asked the same KEY twice means the first
# answer failed that site's validation loop; without this, the loop would
# re-read the same bad answer forever and a GUI run would hang.
# ---------------------------------------------------------------------------
_answer_for() {          # _answer_for KEY PROMPT -- the raw answer, or aborts
    _af_k=$1
    _af_p=$2
    if grep -qx -- "$_af_k" "$RBS_ANSWER_STATE/served" 2>/dev/null; then
        printf 'invalid or missing answer %s for prompt "%s"' "$_af_k" "$_af_p" \
            >"$RBS_ANSWER_STATE/error"
        kill -TERM $$
        exit 1           # ends only this subshell; the wizard is already dying
    fi
    printf '%s\n' "$_af_k" >>"$RBS_ANSWER_STATE/served"
    config_get "$ANSWERS_FILE" "$_af_k"
}

ask() {                  # ask KEY PROMPT [DEFAULT]
    _k=$1
    _p=$2
    _d=${3:-}
    if [ -n "$ANSWERS_FILE" ]; then
        _ans=$(_answer_for "$_k" "$_p") || exit 1
        case $_ans in
            '@none') _ans='' ;;
            '') _ans=$_d ;;
        esac
        printf '%s' "$_ans"
        return 0
    fi
    if [ -n "$_d" ]; then
        printf '%s [%s]: ' "$_p" "$_d" >&2
    else
        printf '%s: ' "$_p" >&2
    fi
    IFS= read -r _ans || _ans=''
    [ -z "$_ans" ] && _ans=$_d
    printf '%s' "$_ans"
}

confirm() {              # confirm KEY PROMPT -- yes returns 0
    if [ -n "$ANSWERS_FILE" ]; then
        _c=$(_answer_for "$1" "$2") || exit 1
        case $_c in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
    fi
    printf '%s [y/N]: ' "$2" >&2
    IFS= read -r _c || _c=''
    case $_c in [Yy]*) return 0 ;; *) return 1 ;; esac
}

hr() { printf '%s\n' "--------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Cron. A marker-delimited BLOCK per backup, appended at the end.
# ---------------------------------------------------------------------------

# cron_current -- stdout is the current crontab, empty if there is none.
# `crontab -l` exits 1 BOTH when no crontab exists and when the read is denied;
# treating a denied read as "empty" would replace the user's whole crontab, so
# branch on the message rather than on the exit code alone.
cron_current() {
    _err=$(mktemp) || return 1
    _out=$(crontab -l 2>"$_err")
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        if grep -qi 'no crontab' "$_err"; then
            _out=''
        else
            warn "cannot read the crontab; refusing to write one:"
            cat "$_err" >&2
            rm -f "$_err"
            return 1
        fi
    fi
    rm -f "$_err"
    printf '%s\n' "$_out"
    return 0
}

# cron_without_block NAME -- current crontab minus this backup's block.
# awk with EXACT whole-line equality, not `grep -v -F`: a substring filter would
# match a sibling backup whose name contains this one and orphan its schedule.
cron_without_block() {
    cron_current | awk -v tag="$CRON_TAG_PREFIX:$1" '
        $0 == "# >>> " tag " >>>" { inblk = 1; next }
        $0 == "# <<< " tag " <<<" { inblk = 0; next }
        inblk != 1 { print }'
}

cron_install() {
    _name=$1
    _sched=$2
    _cmd=$3

    # In a crontab an unescaped % becomes a newline and everything after it is
    # fed to the command as stdin, so a `date +%F` makes the job a permanent
    # no-op that still looks installed. There are none here by construction.
    case $_cmd in
        *%*) warn "refusing: '%' in a cron command is translated to a newline."
             return 1 ;;
    esac

    mkdir -p "$REPO_ROOT/logs/$_name" || return 1

    _backup=$REPO_ROOT/logs/crontab.backup.$(date +%Y-%m-%d_%H%M%S).txt
    cron_current >"$_backup" || return 1
    say "Existing crontab saved to: $_backup"

    _new=$( { cron_without_block "$_name"
              printf '# >>> %s:%s >>>\n' "$CRON_TAG_PREFIX" "$_name"
              printf '# Managed by %s/setup.sh -- edit with ./setup.sh, not by hand.\n' "$REPO_ROOT"
              printf '%s %s\n' "$_sched" "$_cmd"
              printf '# <<< %s:%s <<<\n' "$CRON_TAG_PREFIX" "$_name"; } ) || return 1

    hr
    printf '%s\n' "$_new"
    hr
    confirm A_CRON_CONFIRM "Install this crontab?" || { say "Left the crontab unchanged."; return 1; }

    # printf restores the single trailing newline that $( ) strips and that
    # vixie cron requires, and this is a read-modify-write rather than a
    # `crontab -l | ... | crontab -` pipe, where a mid-pipeline failure would
    # install a truncated crontab.
    printf '%s\n' "$_new" | crontab - || { warn "crontab install FAILED"; return 1; }

    if cron_current | grep -qF "# >>> $CRON_TAG_PREFIX:$_name >>>"; then
        say "Cron entry installed and verified."
        return 0
    fi
    warn "wrote the crontab but could not read the marker back; restore from $_backup"
    return 1
}

cron_uninstall() {
    _name=$1
    _new=$(cron_without_block "$_name") || return 1
    if [ -z "$_new" ]; then
        crontab -r 2>/dev/null
    else
        printf '%s\n' "$_new" | crontab -
    fi
    say "Cron entry for '$_name' removed."
}

cron_schedule_prompt() {
    cat >&2 <<'EOF'

  When should this run automatically?
    1) Daily at 02:00                       0 2 * * *
    2) Twice daily, 12:30 and 20:30         30 12,20 * * *
    3) Hourly                               0 * * * *
    4) Weekly, Sunday 03:00                 0 3 * * 0
    5) Custom (5 fields, or @daily/@weekly)
    6) No cron entry
EOF
    _pick=$(ask A_SCHEDULE_CHOICE "  Choice" "1")
    case $_pick in
        1) printf '%s' "0 2 * * *" ;;
        2) printf '%s' "30 12,20 * * *" ;;
        3) printf '%s' "0 * * * *" ;;
        4) printf '%s' "0 3 * * 0" ;;
        5)
            while :; do
                _c=$(ask A_SCHEDULE_CUSTOM "  Cron expression")
                case $_c in
                    @reboot) warn "@reboot is not appropriate for a backup." ; continue ;;
                    @daily|@hourly|@weekly|@monthly) printf '%s' "$_c"; return 0 ;;
                esac
                # Five whitespace-separated fields, each of the permitted chars.
                set -f; set -- $_c; set +f
                if [ $# -ne 5 ]; then warn "need exactly 5 fields, got $#"; continue; fi
                _bad=0
                for _f in "$@"; do
                    case $_f in *[!0-9*,/-]*) _bad=1 ;; esac
                done
                [ "$_bad" = 1 ] && { warn "fields may contain only digits and * , / -"; continue; }
                printf '%s' "$_c"; return 0
            done ;;
        *) printf '%s' "" ;;
    esac
}

# ---------------------------------------------------------------------------
# Removal: setup.sh --remove NAME. Uninstalls the schedule/trigger and deletes
# this machine's BOOKKEEPING for one backup -- config/NAME, logs/NAME and the
# generated runner. The backed-up data is never touched: nothing in this
# branch constructs a destination path at all.
#
# Order matters: the schedule goes FIRST and is verified gone before any file
# is removed, so a failure leaves everything intact rather than a live cron
# line pointing at a deleted runner.
# ---------------------------------------------------------------------------
if [ -n "$REMOVE_NAME" ]; then
    NAME=$REMOVE_NAME
    case $NAME in
        ""|*[!A-Za-z0-9._-]*) warn "invalid backup name: $NAME"; exit 78 ;;
    esac
    CFG=$REPO_ROOT/config/$NAME
    if [ ! -d "$CFG" ]; then
        warn "no backup named '$NAME' is configured here (looked in $CFG)"
        exit 78
    fi
    # Read before rm -rf: the message below needs it, and the config is gone
    # a few lines further down.
    _rm_remote=$(config_get "$CFG/destination.txt" RCLONE_REMOTE 2>/dev/null) || _rm_remote=''
    say "Removing the backup schedule '$NAME' from THIS machine:"
    say "  - its cron entry / drive-connect trigger"
    say "  - config/$NAME, logs/$NAME and backups/$NAME.sh"
    say "The backed-up data at the destination is NOT touched."
    if ! confirm A_REMOVE "Remove '$NAME'?"; then
        say "Aborted; nothing was removed."
        exit 75
    fi
    if command -v crontab >/dev/null 2>&1 \
       && cron_current 2>/dev/null | grep -qF "# >>> $CRON_TAG_PREFIX:$NAME >>>"; then
        cron_uninstall "$NAME"
        # cron_uninstall cannot fail loudly (its last say always succeeds), so
        # verify the block is really gone before touching any file.
        if cron_current 2>/dev/null | grep -qF "# >>> $CRON_TAG_PREFIX:$NAME >>>"; then
            warn "the cron entry could not be removed; nothing was deleted"
            exit 78
        fi
    fi
    if [ "$(uname -s)" = Darwin ]; then
        . "$REPO_ROOT/lib/trigger-macos.sh"
        if [ -f "$(macos_agent_plist "$NAME")" ]; then
            macos_trigger_remove "$NAME" && say "  [ok]   launchd agent removed"
        fi
    else
        if [ -f "/etc/udev/rules.d/95-rsync-backup-$NAME.rules" ]; then
            warn "a udev trigger exists and needs root to remove. Run:"
            say "    sudo rm /etc/udev/rules.d/95-rsync-backup-$NAME.rules"
            say "    sudo udevadm control --reload"
            say "    sudo systemctl stop 'rsync-backup@$NAME.service' 2>/dev/null || true"
        fi
    fi
    rm -rf "$CFG" "$REPO_ROOT/logs/$NAME" "$REPO_ROOT/backups/$NAME.sh"
    say "  [ok]   removed config/$NAME, logs/$NAME and backups/$NAME.sh"
    say "Done. '$NAME' no longer runs on this machine; the destination data is untouched."
    if [ -n "$_rm_remote" ]; then
        say ""
        say "The rclone account '$_rm_remote:' and everything stored in it are NOT touched."
        say "Remove the account itself with: rclone config"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
say ""
say "  rsync backup setup"
say "  This machine is a SOURCE. Nothing needs to be installed at the destination"
say "  beyond SSH and rsync. Backups here NEVER delete anything at the destination."
hr

# --- 1. name ---------------------------------------------------------------
while :; do
    NAME=$(ask A_NAME "Backup name (e.g. documents-to-workstation)")
    case $NAME in
        "") warn "a name is required" ; continue ;;
        *[!A-Za-z0-9._-]*) warn "use only letters, digits, dot, underscore, hyphen" ; continue ;;
    esac
    break
done

CFG=$REPO_ROOT/config/$NAME
EDITING=0
if [ -d "$CFG" ]; then
    EDITING=1
    say ""
    say "'$NAME' is already configured. Existing values are shown as defaults;"
    say "press Enter to keep each one."
fi

OLD_SRC=''; OLD_USER=''; OLD_HOST=''; OLD_DPATH=''; OLD_DTYPE=''; OLD_VOLROOT=''
OLD_RREMOTE=''; OLD_CPROV=''
if [ "$EDITING" = 1 ]; then
    OLD_SRC=$(config_first_line "$CFG/source.txt" 2>/dev/null) || OLD_SRC=''
    OLD_USER=$(config_get "$CFG/destination.txt" USER 2>/dev/null)
    OLD_HOST=$(config_get "$CFG/destination.txt" HOST 2>/dev/null)
    OLD_DPATH=$(config_get "$CFG/destination.txt" DEST_PATH 2>/dev/null)
    OLD_DTYPE=$(config_get "$CFG/destination.txt" DEST_TYPE 2>/dev/null)
    OLD_VOLROOT=$(config_get "$CFG/destination.txt" VOLUME_ROOT 2>/dev/null)
    OLD_RREMOTE=$(config_get "$CFG/destination.txt" RCLONE_REMOTE 2>/dev/null)
    OLD_CPROV=$(config_get "$CFG/destination.txt" CLOUD_PROVIDER 2>/dev/null)
fi

# --- 2. source -------------------------------------------------------------
say ""
say "Source folder on THIS machine. Absolute, or relative to \$HOME."
while :; do
    RAW_SRC=$(ask A_SOURCE "Source path" "$OLD_SRC")
    [ -n "$RAW_SRC" ] || { warn "a source is required"; continue; }
    SRC=$(resolve_path "$RAW_SRC")
    [ -d "$SRC" ] || { warn "not a directory: $SRC"; continue; }
    break
done

# --- 3. destination --------------------------------------------------------
say ""
say "Where does this back up TO?"
say "  1) Another machine over SSH   (runs on a schedule)"
say "  2) A drive plugged into this machine  (runs when you connect it)"
say "  3) A cloud service -- S3, Google Drive, OneDrive or Dropbox (runs on a schedule)"
case $OLD_DTYPE in
    local) _kind_default=2 ;;
    cloud) _kind_default=3 ;;
    *)     _kind_default=1 ;;
esac
while :; do
    DEST_KIND=$(ask A_DEST_KIND "Choice" "$_kind_default")
    case $DEST_KIND in
        1|2|3) break ;;
        *) warn "choose 1, 2 or 3" ;;
    esac
done

DEST_TYPE=ssh
VOLUME_ROOT=''
DEST_FS=''
DEST_USER=''
DEST_HOST=''
RCLONE_REMOTE=''
CLOUD_PROVIDER=''

if [ "$DEST_KIND" = 2 ]; then
    DEST_TYPE=local
    . "$REPO_ROOT/lib/trigger-$( [ "$(uname -s)" = Darwin ] && echo macos || echo linux ).sh"

    say ""
    say "Plug the drive in now if it isn't already. Mounted volumes:"
    # List real mount points, excluding the system ones.
    if [ "$(uname -s)" = Darwin ]; then
        VOLS=$(ls -1d /Volumes/*/ 2>/dev/null | sed 's|/$||')
    else
        VOLS=$(findmnt -rno TARGET 2>/dev/null | grep -E '^/(media|mnt|run/media)/' )
    fi
    if [ -z "$VOLS" ]; then
        warn "no removable volumes found. Plug the drive in and re-run ./setup.sh."
        exit 1
    fi
    i=0
    printf '%s\n' "$VOLS" | while IFS= read -r v; do
        i=$((i+1)); printf '  %d) %s\n' "$i" "$v" >&2
    done
    while :; do
        VOLUME_ROOT=$(ask A_VOLUME_ROOT "Volume (full path, or paste one from above)" "$OLD_VOLROOT")
        [ -n "$VOLUME_ROOT" ] || { warn "required"; continue; }
        case $VOLUME_ROOT in
            [0-9]) VOLUME_ROOT=$(printf '%s\n' "$VOLS" | sed -n "${VOLUME_ROOT}p") ;;
        esac
        [ -d "$VOLUME_ROOT" ] || { warn "not a directory: $VOLUME_ROOT"; continue; }
        # Refuse anything that is not actually a mount point: writing to a plain
        # directory named like the drive is exactly the disaster this guards.
        if ! volume_mounted "$VOLUME_ROOT"; then
            warn "$VOLUME_ROOT is not a mount point -- is the drive actually connected?"
            continue
        fi
        break
    done

    # Detect the filesystem so the exFAT options are set for you rather than
    # discovered the hard way on the first run.
    if [ "$(uname -s)" = Darwin ]; then
        DEST_FS=$(diskutil info "$VOLUME_ROOT" 2>/dev/null | awk -F': *' '/Type \(Bundle\)/{print tolower($2); exit}')
        DRIVE_ID=$(macos_volume_identity "$VOLUME_ROOT")
    else
        DEST_FS=$(findmnt -no FSTYPE --target "$VOLUME_ROOT" 2>/dev/null)
        DRIVE_ID=$(linux_volume_identity "$VOLUME_ROOT")
    fi
    [ -n "$DEST_FS" ] || DEST_FS=unknown
    say "  [ok]   volume: $VOLUME_ROOT  ($DEST_FS, id ${DRIVE_ID:-unknown})"

    DEST_PATH=$(ask A_DEST_PATH "Folder ON the drive to back up into" "${OLD_DPATH:-$VOLUME_ROOT/$(hostname -s 2>/dev/null || echo backup)}")
    case $DEST_PATH in /*) ;; *) DEST_PATH=$VOLUME_ROOT/$DEST_PATH ;; esac
elif [ "$DEST_KIND" = 1 ]; then
    say ""
    say "Destination. Use an ~/.ssh/config alias or a hostname/IP. Key-based auth only."
    while :; do
        DEST_HOST=$(ask A_HOST "Destination host" "$OLD_HOST")
        [ -n "$DEST_HOST" ] && break
        warn "a host is required"
    done
fi

if [ "$DEST_KIND" = 3 ]; then
    DEST_TYPE=cloud
    command -v detect_rclone >/dev/null 2>&1 \
        || { warn "this engine has no cloud support (lib/cloud.sh is missing)"; exit 1; }
    if ! detect_rclone; then
        warn "rclone is not installed. Cloud destinations need it; SSH and drive backups do not."
        rclone_install_hint >&2
        exit 1
    fi
    if [ "$RCLONE_VERSION" != unknown ] && ! _rclone_version_ge "$RCLONE_VERSION" "$RBS_RCLONE_MIN"; then
        warn "rclone $RCLONE_VERSION is older than $RBS_RCLONE_MIN, which this needs."
        rclone_install_hint >&2
        exit 1
    fi
    say "  [ok]   rclone: $RCLONE_BIN ($RCLONE_VERSION)"

    say ""
    say "Which service?"
    say "  1) Amazon S3 (or S3-compatible)   2) Google Drive"
    say "  3) OneDrive                       4) Dropbox"
    say "  5) Another remote already in rclone.conf"
    case $OLD_CPROV in
        s3) _cp_default=1 ;; drive) _cp_default=2 ;; onedrive) _cp_default=3 ;;
        dropbox) _cp_default=4 ;; other) _cp_default=5 ;; *) _cp_default=2 ;;
    esac
    while :; do
        _cp_choice=$(ask A_CLOUD_PROVIDER "Choice" "$_cp_default")
        case $_cp_choice in
            1) CLOUD_PROVIDER=s3 ;;      2) CLOUD_PROVIDER=drive ;;
            3) CLOUD_PROVIDER=onedrive ;; 4) CLOUD_PROVIDER=dropbox ;;
            5) CLOUD_PROVIDER=other ;;
            *) warn "choose 1-5"; continue ;;
        esac
        break
    done

    # rclone owns the credentials. This script only ever learns the NAME of a
    # remote, never a key, a token or a password.
    say ""
    say "rclone accounts configured on this machine:"
    REMOTES=$("$RCLONE_BIN" listremotes 2>/dev/null)
    if [ -n "$REMOTES" ]; then
        printf '%s\n' "$REMOTES" | sed 's/^/    /' >&2
    else
        say "    (none yet)"
    fi
    say ""
    say "  Credentials live in rclone's own config, never in this repo."
    while :; do
        RCLONE_REMOTE=$(ask A_RCLONE_REMOTE "Account name (no colon)" "$OLD_RREMOTE")
        RCLONE_REMOTE=${RCLONE_REMOTE%:}
        case $RCLONE_REMOTE in
            ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*)
                warn "an rclone remote name is letters, digits, . _ - and starts with a letter or digit"
                continue ;;
        esac
        if printf '%s\n' "$REMOTES" | grep -xF -- "$RCLONE_REMOTE:" >/dev/null 2>&1; then
            break
        fi
        # Creating a remote is INTERACTIVE ONLY. In headless mode the caller
        # (the desktop app) connects the account first and passes the name;
        # this script must never launch a browser flow it cannot drive.
        if [ -n "$ANSWERS_FILE" ]; then
            warn "the rclone remote '$RCLONE_REMOTE:' is not configured on this machine."
            warn "  Create it first with: rclone config"
            exit 78
        fi
        warn "'$RCLONE_REMOTE:' is not configured yet."
        if confirm A_CREATE_REMOTE "  Run 'rclone config' now to set it up?"; then
            "$RCLONE_BIN" config
            REMOTES=$("$RCLONE_BIN" listremotes 2>/dev/null)
        fi
    done

    if [ "$CLOUD_PROVIDER" = s3 ]; then
        say ""
        say "  For S3 the first path segment is the BUCKET, e.g. my-bucket/backups"
    fi
    while :; do
        DEST_PATH=$(ask A_DEST_PATH "Folder inside $RCLONE_REMOTE: (the folder your source will be placed INSIDE)" \
                        "${OLD_DPATH:-Rsyncronizer/$(hostname -s 2>/dev/null || echo machine)}")
        case $DEST_PATH in
            '')  warn "a destination path is required"; continue ;;
            -*)  warn "the path may not begin with '-'"; continue ;;
            /*)  warn "give a path INSIDE the remote, with no leading '/'"; continue ;;
            *:*) warn "the path may not contain ':' -- the account is named separately"; continue ;;
        esac
        break
    done
fi

if [ "$DEST_TYPE" = ssh ]; then

# Prefill the username from ssh's own effective config, so a value already in
# ~/.ssh/config does not have to be retyped (and cannot be mistyped).
SUGGEST_USER=$OLD_USER
if [ -z "$SUGGEST_USER" ]; then
    SUGGEST_USER=$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^user /{print $2; exit}')
fi
DEST_USER=$(ask A_USER "Destination username (blank = let ~/.ssh/config decide)" "$SUGGEST_USER")

while :; do
        DEST_PATH=$(ask A_DEST_PATH "Destination path (the folder your source will be placed INSIDE)" "$OLD_DPATH")
        [ -n "$DEST_PATH" ] && break
        warn "a destination path is required"
    done
fi

# Strip trailing slashes for a stable "lands as" line.
while :; do
    case $DEST_PATH in
        /) break ;;
        */) DEST_PATH=${DEST_PATH%/} ;;
        *) break ;;
    esac
done

if [ "$DEST_TYPE" = local ]; then
    LANDING="$DEST_PATH/${SRC##*/}/"
elif [ "$DEST_TYPE" = cloud ]; then
    REMOTE=''
    LANDING="$RCLONE_REMOTE:$DEST_PATH/${SRC##*/}/"
elif [ -n "$DEST_USER" ]; then
    REMOTE="$DEST_USER@$DEST_HOST"; LANDING="$REMOTE:$DEST_PATH/${SRC##*/}/"
else
    REMOTE="$DEST_HOST"; LANDING="$REMOTE:$DEST_PATH/${SRC##*/}/"
fi

# --- 4. confirm the landing path ------------------------------------------
# Copy-by-name is the rule most likely to surprise, so show it before writing.
say ""
hr
say "  You entered   : $RAW_SRC"
say "  Resolves to   : $SRC"
say "  Will land as  : $LANDING"
say ""
say "  Nothing at the destination is ever deleted."
hr
confirm A_CONFIRM_LANDING "Is that correct?" || { say "Aborted; nothing was written."; exit 1; }

# --- 5. preflight ----------------------------------------------------------
say ""
say "Preflight checks"

# A cloud backup never invokes rsync, so a machine that only backs up to the
# cloud is not required to have it.
if [ "$DEST_TYPE" != cloud ]; then
    detect_rsync && say "  [ok]   local rsync: $RSYNC_BIN ($RSYNC_FLAVOUR)" \
                 || { warn "no rsync found on PATH"; exit 1; }
    if [ "$RSYNC_FLAVOUR" = openrsync ]; then
        say "         openrsync supports everything this repo uses. 'brew install rsync'"
        say "         is optional (it adds --protect-args for paths containing spaces)."
    fi
fi

SRC_COUNT=$(find "$SRC" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
PERR=$(find "$SRC" -mindepth 1 -maxdepth 1 -print 2>&1 >/dev/null)
if [ -n "$PERR" ]; then
    warn "the source could not be fully read: $PERR"
else
    say "  [ok]   source readable: $SRC_COUNT top-level entries"
fi

if [ "$DEST_TYPE" = local ]; then
    # Write the marker ON the drive. This is what lets every future run tell
    # "the drive is here" from "the mount point directory exists but the drive
    # is not", which is the difference between a backup and filling the system disk.
    if printf '%s\n' \
        "# Written by Rsyncronizer setup.sh -- do not delete." \
        "# Its presence is how a backup confirms THIS drive is really mounted." \
        "label=$(basename "$VOLUME_ROOT")" \
        "id=${DRIVE_ID:-unknown}" \
        >"$VOLUME_ROOT/$VOLUME_MARKER_NAME" 2>/dev/null; then
        say "  [ok]   marker written: $VOLUME_ROOT/$VOLUME_MARKER_NAME"
    else
        warn "cannot write to $VOLUME_ROOT -- is it mounted read-only?"
        exit 1
    fi
    mkdir -p "$DEST_PATH" 2>/dev/null \
        && say "  [ok]   destination ready: $DEST_PATH" \
        || { warn "cannot create $DEST_PATH"; exit 1; }
    say "  [ok]   free on drive: $(df -Pk -- "$VOLUME_ROOT" 2>/dev/null | awk 'NR==2{printf "%.1f GB", $4/1048576}')"

    if [ "$DEST_FS" = exfat ] || [ "$DEST_FS" = msdos ] || [ "$DEST_FS" = vfat ]; then
        say ""
        say "  $DEST_FS cannot store Unix permissions, and its timestamps are only"
        say "  accurate to 2 seconds. Setting PRESERVE_PERMS=no and MODIFY_WINDOW=1"
        say "  for this backup so every file does not look modified on every run."
        EXFAT=1
        # It also rejects  | < > : " ? * \  in filenames. Count them now rather
        # than letting the first run fail with thousands of errors.
        say "  Scanning the source for filenames $DEST_FS cannot store..."
        # Two patterns, not one bracket expression: inside [...] the backslash
        # escapes the ']' and leaves it unterminated, so the obvious one-liner
        # silently matches nothing.
        BADTMP=$(mktemp)
        find "$SRC" \( -name '*[|<>:"?*]*' -o -name '*\\*' \) 2>/dev/null >"$BADTMP"
        BADN=$(wc -l <"$BADTMP" | tr -d ' ')
        if [ "$BADN" -gt 0 ]; then
            say ""
            warn "$BADN file(s) have names $DEST_FS cannot store."
            say "  Left alone they fail on every single run (exit 23), which buries"
            say "  real errors. They are usually concentrated in a few folders:"
            say ""
            # Group by ancestor a few levels down -- that is the level at which a
            # single exclude rule usually covers the whole cluster.
            sed "s|^$SRC/||" "$BADTMP" \
                | awk -F/ '{n=(NF>3?3:NF-1); if(n<1)n=1; p=""; for(i=1;i<=n;i++) p=p (i>1?"/":"") $i; print p}' \
                | sort | uniq -c | sort -rn | head -5 >"$BADTMP.top"
            i=0
            while IFS= read -r line; do
                i=$((i+1))
                printf '    %d) %8s files under  %s\n' "$i" \
                    "$(echo "$line" | awk '{print $1}')" \
                    "$(echo "$line" | sed 's/^ *[0-9]* //')" >&2
            done <"$BADTMP.top"
            say ""
            say "  Excluding a folder here skips it for THIS backup only -- it stays"
            say "  fully backed up everywhere else."
            say ""
            if confirm A_EXCLUDE_OFFER "Add one of these to config/$NAME/exclude.txt now?"; then
                mkdir -p "$CFG"
                [ -f "$CFG/exclude.txt" ] || cat >"$CFG/exclude.txt" <<'EOF'
# Extra excludes for THIS backup only, on top of the shared rsync-ignore.txt.
# Same syntax: one rule per line, '- ' prefix, bare basenames (no slashes --
# a rule containing '/' anchors to the transfer root and will not match).
#
# Added because the destination cannot store  | < > : " ? * \  in filenames.
# These folders are still backed up by every other backup you have.
EOF
                while :; do
                    PICK=$(ask A_EXCLUDE_ADD "  Which number (or type a folder name, blank to stop)")
                    [ -n "$PICK" ] || break
                    case $PICK in
                        [1-9])
                            SEL=$(sed -n "${PICK}p" "$BADTMP.top" | sed 's/^ *[0-9]* //')
                            [ -n "$SEL" ] || { warn "no such choice"; continue; }
                            # The ignore-file syntax takes bare basenames: a rule
                            # containing '/' anchors to the transfer root.
                            SEL=${SEL##*/}
                            ;;
                        *) SEL=${PICK##*/} ;;
                    esac
                    if grep -qx -- "- $SEL" "$CFG/exclude.txt" 2>/dev/null; then
                        say "    already excluded: $SEL"
                    else
                        printf -- '- %s\n' "$SEL" >>"$CFG/exclude.txt"
                        say "    excluded: $SEL"
                    fi
                    confirm A_EXCLUDE_MORE "  Add another?" || break
                done
            else
                say "  Skipped. Add rules later to config/$NAME/exclude.txt, or leave them"
                say "  and expect exit 23 on every run."
            fi
            say ""
        else
            say "  [ok]   no incompatible filenames found"
        fi
        rm -f "$BADTMP" "$BADTMP.top"
    fi
fi

# Probe SSH the way CRON will: no agent, no tty. A passphrase-protected key
# passes every ordinary interactive check and then fails silently every night.
if [ "$DEST_TYPE" = ssh ] && env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE" true 2>/dev/null; then
    say "  [ok]   ssh $REMOTE works with no agent and no tty (cron-equivalent)"
    SSH_OK=1
elif [ "$DEST_TYPE" = ssh ]; then
    warn "ssh to $REMOTE failed with no agent. Under cron this will fail every time."
    warn "  Fix: passphrase-less key + ssh-copy-id, then re-run setup.sh."
    SSH_OK=0
else
    SSH_OK=0
fi

if [ "$DEST_TYPE" = ssh ] && [ "$SSH_OK" = 1 ]; then
    if ssh -o BatchMode=yes "$REMOTE" "test -d \"$DEST_PATH\"" 2>/dev/null; then
        say "  [ok]   destination exists: $DEST_PATH"
    else
        warn "destination does not exist: $REMOTE:$DEST_PATH"
        if confirm A_CREATE_DEST "  Create it now (mkdir -p)?"; then
            ssh -o BatchMode=yes "$REMOTE" "mkdir -p -- \"$DEST_PATH\"" \
                && say "  [ok]   created" || warn "could not create it"
        fi
    fi
    if ssh -o BatchMode=yes "$REMOTE" "test -w \"$DEST_PATH\"" 2>/dev/null; then
        say "  [ok]   destination is writable"
    else
        warn "destination is not writable by $REMOTE"
    fi
    if ssh -o BatchMode=yes "$REMOTE" "command -v rsync >/dev/null" 2>/dev/null; then
        say "  [ok]   remote rsync present"
    else
        warn "no rsync on the remote's non-interactive PATH."
        warn "  Set RSYNC_PATH=/full/path/to/rsync in config/$NAME/destination.txt"
    fi
fi

if [ "$DEST_TYPE" = cloud ]; then
    # Probe rclone the way CRON will. This is the exact counterpart of the
    # `env -u SSH_AUTH_SOCK ssh -o BatchMode=yes` probe above: an ENCRYPTED
    # rclone.conf passes every interactive check and then blocks forever at a
    # password prompt on every scheduled run, holding the lock, with nobody
    # watching. --ask-password=false turns that into a fast, legible failure.
    if "$RCLONE_BIN" config show "$RCLONE_REMOTE:" --ask-password=false >/dev/null 2>&1 </dev/null; then
        say "  [ok]   rclone.conf is readable with no password (cron-equivalent)"
    else
        warn "rclone's config could not be read without a password."
        warn "  An encrypted rclone.conf cannot work under cron -- nothing is there to type it."
        warn "  Remove the password: rclone config  ->  s) Set configuration password  ->  remove"
    fi
    if "$RCLONE_BIN" lsd "$RCLONE_REMOTE:" --max-depth 1 --ask-password=false >/dev/null 2>&1 </dev/null; then
        say "  [ok]   $RCLONE_REMOTE: answers with no interaction"
    else
        warn "could not list $RCLONE_REMOTE: without interaction."
        warn "  Re-authorise it: rclone config reconnect $RCLONE_REMOTE:"
    fi
    # S3 has no `about` at all, so a failure here is a note and never an error.
    if _ab=$("$RCLONE_BIN" about "$RCLONE_REMOTE:" 2>/dev/null </dev/null); then
        say "  [ok]   quota: $(printf '%s' "$_ab" | tr '\n' ' ')"
    else
        say "         (this service does not report a free-space figure)"
    fi
    if "$RCLONE_BIN" lsf "$RCLONE_REMOTE:$DEST_PATH" --max-depth 1 --ask-password=false >/dev/null 2>&1 </dev/null; then
        say "  [ok]   destination exists: $RCLONE_REMOTE:$DEST_PATH"
    else
        warn "destination does not exist yet: $RCLONE_REMOTE:$DEST_PATH"
        if confirm A_CREATE_DEST "  Create it now?"; then
            "$RCLONE_BIN" mkdir "$RCLONE_REMOTE:$DEST_PATH" </dev/null \
                && say "  [ok]   created" || warn "could not create it"
        fi
    fi
    # A write test that leaves its evidence behind on purpose. Deleting a
    # remote object here would be the ONLY deletion in this product outside
    # the guarded --sync-deletions path, and would need the same machinery to
    # be defensible; one tiny marker is a fair price. It also sits in the
    # PARENT of the transfer root, so it can never appear in a deletion list.
    if printf '%s\n' \
        "# Written by Rsyncronizer's setup.sh. Safe to delete." \
        "# It records that this machine could write here at setup time." \
        "backup=$NAME" \
        "host=$(hostname 2>/dev/null || echo unknown)" \
        "when=$(date '+%Y-%m-%d %H:%M:%S %z')" \
        | "$RCLONE_BIN" rcat "$RCLONE_REMOTE:$DEST_PATH/.rsyncronizer-write-test" \
              --ask-password=false >/dev/null 2>&1; then
        say "  [ok]   wrote $RCLONE_REMOTE:$DEST_PATH/.rsyncronizer-write-test"
    else
        warn "could not write to $RCLONE_REMOTE:$DEST_PATH -- check the account's permissions"
    fi

    # What will look like a bug later if nobody says it now.
    say ""
    say "  Worth knowing about this service:"
    case $CLOUD_PROVIDER in
        s3)
            say "    - No free-space figure exists, so the dashboard never shows one."
            say "    - Reading a file's timestamp costs an extra request; the first run is slow." ;;
        drive)
            say "    - Google Drive caps uploads at 750 GB per day. A bigger first backup"
            say "      simply continues the next day."
            say "    - Deletions go to Drive's trash, so space frees only when you empty it."
            say "    - Drive can hold two files with the same name; 'rclone dedupe' fixes that." ;;
        onedrive)
            say "    - Paths over 400 characters and files over 250 GB are rejected."
            say "    - The sign-in expires after 90 days of no use:"
            say "        rsyncronizer cloud login $RCLONE_REMOTE"
            say "    - Versioning is on by default and can double the space a file uses." ;;
        dropbox)
            say "    - Some filenames are refused outright (thumbs.db and friends)."
            say "    - Dropbox can only change a file's timestamp by uploading it again." ;;
    esac
    say "    - No cloud service stores symlinks, ownership or permission bits."
    say "      Files come back as plain files owned by you."
fi

# --- 6. write config -------------------------------------------------------
mkdir -p "$CFG" || { warn "cannot create $CFG"; exit 1; }

# Seed THE global exclude file once, from the shipped defaults. From then on
# it fully replaces rsync-ignore.txt at run time, so every exclusion is
# visible in one editable place and deleting a line really un-excludes it.
if [ ! -f "$REPO_ROOT/config/global-exclude.txt" ]; then
    {
        echo "# Global excludes -- applied to EVERY backup on this machine."
        echo "# This file IS the complete global list (seeded from the shipped"
        echo "# defaults; once it exists, rsync-ignore.txt no longer applies)."
        echo "# One rule per line, '- ' prefix, bare basenames. Deleting a line"
        echo "# un-excludes it. Excluded names are also protected from"
        echo "# sync-deletions at the destination."
        grep -v '^#' "$REPO_ROOT/rsync-ignore.txt" | grep -v '^[[:space:]]*$'
    } >"$REPO_ROOT/config/global-exclude.txt"
    say "  [ok]   seeded config/global-exclude.txt from the shipped defaults"
fi

{
    echo "# Source folder for '$NAME'."
    echo "# Absolute, or relative to \$HOME (cron has no meaningful cwd)."
    echo "# The folder is copied BY NAME: this lands as <DEST_PATH>/${SRC##*/}/"
    echo "$RAW_SRC"
} >"$CFG/source.txt"

if [ "$DEST_TYPE" = local ]; then
    {
        echo "# Destination for '$NAME': a drive plugged into this machine."
        echo "DEST_TYPE=local"
        echo "# The drive's mount point. A run refuses to proceed unless this is"
        echo "# really a mount point AND carries $VOLUME_MARKER_NAME -- otherwise a"
        echo "# backup with the drive unplugged would fill the system disk."
        echo "VOLUME_ROOT=$VOLUME_ROOT"
        echo "DEST_PATH=$DEST_PATH"
        echo "DEST_FS=$DEST_FS"
    } >"$CFG/destination.txt"
elif [ "$DEST_TYPE" = cloud ]; then
    {
        echo "# Destination for '$NAME': a cloud service, reached with rclone."
        echo "DEST_TYPE=cloud"
        echo "# The rclone remote, as named in rclone's own config."
        echo "# List them with: rclone listremotes    (or: rsyncronizer cloud list)"
        echo "# This is a NAME, never a credential -- no key, token or password"
        echo "# is stored anywhere in this repo."
        echo "RCLONE_REMOTE=$RCLONE_REMOTE"
        echo "# Path INSIDE the remote, with no leading slash. For S3 the first"
        echo "# segment is the bucket. The source is copied BY NAME beneath it,"
        echo "# so this lands as $RCLONE_REMOTE:$DEST_PATH/${SRC##*/}/"
        echo "DEST_PATH=$DEST_PATH"
        echo "# Used only to tailor advice and provider-specific defaults."
        echo "CLOUD_PROVIDER=$CLOUD_PROVIDER"
        echo "# Cloud destinations store no symlinks, no ownership and no"
        echo "# permission bits. No rclone flag changes that."
        echo "# RCLONE_CONFIG_PATH=   # only for a non-default rclone.conf"
    } >"$CFG/destination.txt"
else
    {
        echo "# Destination for '$NAME'. Key-based SSH auth only, no passwords."
        echo "USER=$DEST_USER"
        echo "HOST=$DEST_HOST"
        echo "DEST_PATH=$DEST_PATH"
        echo "# RSYNC_PATH=/usr/bin/rsync   # only if rsync is off the remote's PATH"
    } >"$CFG/destination.txt"
fi

if [ ! -f "$CFG/options.txt" ]; then
    cat >"$CFG/options.txt" <<'EOF'
# Optional settings for this backup. Every key may be omitted.
#
# SSH_PORT=22
# BWLIMIT=            # KB/s, blank or 0 = unlimited
# TIMEOUT=600         # rsync I/O timeout in seconds
# ALLOW_EMPTY_SOURCE=no
#                     # 'yes' permits a run when the source has no entries.
#                     # Leave it 'no' on macOS: an empty source is how a cron
#                     # job without Full Disk Access silently backs up nothing.
# EXTRA_FLAGS=
#                     # Extra rsync flags. Deletion and in-place-overwrite
#                     # flags are rejected at runtime, not silently dropped.
#                     # Do NOT set --iconv here: see README.
#
# --- drive-connect backups only ---
# PRESERVE_PERMS=no   # exFAT/FAT have no Unix permission bits
# MODIFY_WINDOW=1     # exFAT timestamps are only accurate to 2 seconds; without
#                     # this every file looks modified on every run
# COPY_LINKS=no       # 'yes' stores what a symlink points AT instead of the
#                     # link. Required on Linux+exFAT, which cannot store
#                     # symlinks at all (every run would exit 23).
# COOLDOWN_HOURS=12   # skip a connect-triggered run within N hours of the last
#                     # ATTEMPT, so replugging does not rescan the whole source.
#                     # Force one anyway: rm logs/<name>/.last_attempt_epoch
#
# --- cloud (rclone) backups only ---
# RCLONE_TRANSFERS=4  # files uploaded in parallel
# RCLONE_CHECKERS=8   # existence checks in parallel
# RCLONE_EXTRA_FLAGS=
#                     # Extra rclone flags, --flag=value form ONLY: no bare
#                     # words and no space-separated values. Deletion, filter,
#                     # logging, --config, --rc*, --dump and --password-command
#                     # are refused at runtime, not silently dropped. EXTRA_FLAGS
#                     # (the rsync one) is refused on a cloud backup, and this
#                     # key is refused on an rsync one.
EOF
fi

# Re-running the wizard can change a backup's KIND, and the engine rejects a
# config that carries keys from the kind it used to be. Comment those out
# rather than leaving them to trip validation on the next run. (awk into a temp
# file, not `sed -i`: BSD sed requires an argument to -i and GNU's does not.)
_comment_out_key() {
    [ -f "$1" ] || return 0
    grep -q "^[[:space:]]*$2[[:space:]]*=" "$1" 2>/dev/null || return 0
    awk -v k="$2" '$0 ~ "^[[:space:]]*" k "[[:space:]]*=" { print "# " $0; next } { print }' \
        "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    say "  (commented out $2= in options.txt: it does not apply to this kind of destination)"
}
if [ "$DEST_TYPE" = cloud ]; then
    _comment_out_key "$CFG/options.txt" EXTRA_FLAGS
    _comment_out_key "$CFG/options.txt" SSH_PORT
    _comment_out_key "$CFG/options.txt" PRESERVE_PERMS
    _comment_out_key "$CFG/options.txt" MODIFY_WINDOW
    _comment_out_key "$CFG/options.txt" COPY_LINKS
    _comment_out_key "$CFG/options.txt" COOLDOWN_HOURS
else
    _comment_out_key "$CFG/options.txt" RCLONE_EXTRA_FLAGS
    _comment_out_key "$CFG/options.txt" RCLONE_TRANSFERS
    _comment_out_key "$CFG/options.txt" RCLONE_CHECKERS
fi

# exFAT and friends need these, and they are per-backup: the SSH backups run to
# ext4/Btrfs and must not pick them up.
if [ "${EXFAT:-0}" = 1 ]; then
    grep -q '^PRESERVE_PERMS=' "$CFG/options.txt" || echo "PRESERVE_PERMS=no" >>"$CFG/options.txt"
    grep -q '^MODIFY_WINDOW='  "$CFG/options.txt" || echo "MODIFY_WINDOW=1"   >>"$CFG/options.txt"
    # Linux's exFAT driver cannot store symlinks at all, so without -L every run
    # ends in exit 23 forever and a systemd trigger shows as failed every time.
    # macOS's exFAT driver does support them, so this is set only where needed.
    if [ "$(uname -s)" != Darwin ]; then
        grep -q '^COPY_LINKS=' "$CFG/options.txt" || echo "COPY_LINKS=yes" >>"$CFG/options.txt"
    fi
fi
if [ "$DEST_TYPE" = local ]; then
    grep -q '^COOLDOWN_HOURS=' "$CFG/options.txt" || echo "COOLDOWN_HOURS=12" >>"$CFG/options.txt"
    [ -f "$CFG/exclude.txt" ] || cat >"$CFG/exclude.txt" <<'EOF'
# Extra excludes for THIS backup only, on top of the shared rsync-ignore.txt.
# Same syntax: one rule per line, '- ' prefix, bare basenames (no slashes).
#
# exFAT cannot store  | < > : " ? * \  in a filename. If setup.sh reported
# incompatible filenames, exclude the folder holding them here, e.g.:
# - manuscript_perceptual_mapping_misc
EOF
fi

mkdir -p "$REPO_ROOT/logs/$NAME"
printf '%s\n' "$SRC_COUNT" >"$REPO_ROOT/logs/$NAME/.baseline_count"
say "  [ok]   recorded baseline of $SRC_COUNT top-level entries"

# --- 7. generate the runner ------------------------------------------------
RUNNER=$REPO_ROOT/backups/$NAME.sh
mkdir -p "$REPO_ROOT/backups"
cat >"$RUNNER" <<EOF
#!/bin/bash
# Generated by setup.sh. SAFE TO COMMIT -- machine-agnostic by design: the only
# machine-specific line is the backup name, and every path comes from
# config/<name>/, which is gitignored.
#
# NOTE: /bin/bash, not /usr/bin/env bash. Under cron PATH is /usr/bin:/bin, so
# env would resolve to bash 3.2 on macOS while an interactive shell with
# Homebrew on PATH would resolve to bash 5 -- the same script running under two
# different bash versions. Pinning it makes manual testing exercise cron's path.
set -uo pipefail

# Cron gives no meaningful cwd, so everything derives from BASH_SOURCE. The
# loop resolves a symlinked FILE; readlink may return a RELATIVE target (on
# macOS \`readlink -- /etc\` prints 'private/etc'), so re-anchor it against the
# link's own directory. \`cd -P\` then resolves symlinked parent directories.
_src=\${BASH_SOURCE[0]:-\$0}
while [ -h "\$_src" ]; do
    _dir=\$(cd -P "\$(dirname -- "\$_src")" && pwd)
    _src=\$(readlink -- "\$_src")
    case \$_src in
        /*) ;;
        *) _src=\$_dir/\$_src ;;
    esac
done
SCRIPT_DIR=\$(cd -P "\$(dirname -- "\$_src")" && pwd)
REPO_ROOT=\$(cd -P "\$SCRIPT_DIR/.." && pwd)
unset _src _dir

. "\$REPO_ROOT/lib/common.sh"
run_backup "$NAME" "\$@"
EOF
chmod +x "$RUNNER"
say "  [ok]   generated backups/$NAME.sh"

# --- 8. git hygiene --------------------------------------------------------
# Verify rather than assume: a stray IDE .gitignore template will happily hide
# the runner and expose the config.
if command -v git >/dev/null 2>&1 && [ -d "$REPO_ROOT/.git" ]; then
    # Only one direction matters: config/ holds paths, usernames, hosts and
    # IPs, and must never be committed. backups/<name>.sh is regenerated by
    # this wizard on each machine and is useless without its config, so whether
    # it is tracked is a matter of taste, not correctness.
    ( cd "$REPO_ROOT" || exit 0
      if ! git check-ignore -q "config/$NAME/source.txt"; then
          warn "config/$NAME/source.txt is NOT gitignored but must never be committed."
      fi )
fi

# --- 9. dry run ------------------------------------------------------------
say ""
if confirm A_RUN_DRY_RUN "Run a dry run now (transfers nothing)?"; then
    hr
    "$RUNNER" --dry-run
    hr
fi

# --- 10. trigger -----------------------------------------------------------
if [ "$DEST_TYPE" = local ]; then
    say ""
    say "This backup runs when you CONNECT the drive, not on a clock."
    say "A cooldown (COOLDOWN_HOURS in options.txt, default 12h) stops a replug"
    say "from rescanning the whole source again."
    say ""
    if confirm A_INSTALL_TRIGGER "Install the drive-connect trigger?"; then
        if [ "$(uname -s)" = Darwin ]; then
            say ""
            say "  macOS grants Full Disk Access PER BINARY, and children inherit it."
            say "  That forces a choice, because your source is in ~/Documents:"
            say ""
            say "    1) launchd agent -- fires the instant you plug the drive in, but"
            say "       needs Full Disk Access granted to /bin/bash, which also gives"
            say "       every other bash script on this Mac the same access."
            say ""
            say "    2) cron poll -- checks every 15 minutes. cron already has Full"
            say "       Disk Access (your existing backup proves it), so this needs NO"
            say "       new permission. A check with the drive absent takes ~30ms."
            say ""
            TRIGMODE=$(ask A_TRIGMODE "  Choice" "2")
            if [ "$TRIGMODE" = 1 ]; then
                macos_trigger_install "$NAME" "$REPO_ROOT" && {
                    say ""
                    say "  Now grant Full Disk Access to /bin/bash, or every run will see an"
                    say "  empty source and refuse:"
                    say "    System Settings > Privacy & Security > Full Disk Access"
                    say "    '+' > Cmd-Shift-G > /bin/bash        (then log out and back in)"
                    say ""
                    say "  Test it:  ./backups/$NAME.sh --on-mount"
                    say "  Remove :  launchctl bootout gui/\$(id -u)/$(macos_agent_label "$NAME")"
                }
            else
                # Remove any launchd agent from a previous run of this wizard.
                # bootout alone is not enough: ~/Library/LaunchAgents is scanned
                # at every login, so a leftover plist silently comes back and you
                # end up with both triggers firing.
                if [ -f "$(macos_agent_plist "$NAME")" ]; then
                    macos_trigger_remove "$NAME"
                    say "  (removed the launchd agent so the two cannot both fire)"
                fi
                # Reuse the cron machinery already in this script, with the same
                # marker-block idempotency and the same % guard.
                # mkdir FIRST: the shell sets up the >> redirect before running
                # the command, so if logs/<name>/ is ever deleted the redirect
                # fails and the backup silently never runs at all.
                CMD="mkdir -p $REPO_ROOT/logs/$NAME && /bin/bash $RUNNER --on-mount >> $REPO_ROOT/logs/$NAME/cron-bootstrap.log 2>&1"
                if cron_install "$NAME" "*/15 * * * *" "$CMD"; then
                    say ""
                    say "  Checks every 15 minutes and exits in ~30ms unless the drive is"
                    say "  present AND the cooldown has passed. No new permission needed."
                    say ""
                    say "  Test it:  ./backups/$NAME.sh --on-mount"
                elif [ -n "$ANSWERS_FILE" ]; then
                    warn "headless run: the cron trigger could not be installed"
                    exit 78
                fi
            fi
        else
            INSTALLER=$REPO_ROOT/logs/$NAME/install-trigger.sh
            linux_trigger_emit "$NAME" "$REPO_ROOT" "$DRIVE_ID" "$(id -un)" >"$INSTALLER"
            chmod +x "$INSTALLER"
            say ""
            say "  The udev rule and systemd unit live under /etc, so they need root."
            say "  setup.sh does NOT escalate silently. Review, then run:"
            say ""
            say "    less $INSTALLER"
            say "    sudo $INSTALLER"
            say ""
            say "  Test without replugging:"
            say "    sudo systemctl start 'rsync-backup@$NAME.service'"
        fi
    fi
    say ""
    hr
    say "Done. '$NAME' is configured."
    say "  run now : ./backups/$NAME.sh"
    say "  dry run : ./backups/$NAME.sh --dry-run"
    say "  status  : ./status.sh"
    hr
    exit 0
fi

say ""
if confirm A_SCHEDULE_YN "Schedule this backup with cron?"; then
    SCHED=$(cron_schedule_prompt)
    if [ -n "$SCHED" ]; then
        if ! command -v crontab >/dev/null 2>&1; then
            warn "crontab not found (Ubuntu: sudo apt install cron)"
        else
            # mkdir FIRST -- see the note on the drive-connect entry: a deleted
            # logs/<name>/ makes the redirect fail and the job silently no-op.
            CMD="mkdir -p $REPO_ROOT/logs/$NAME && /bin/bash $RUNNER --cron >> $REPO_ROOT/logs/$NAME/cron-bootstrap.log 2>&1"
            if ! cron_install "$NAME" "$SCHED" "$CMD" && [ -n "$ANSWERS_FILE" ]; then
                # Interactively the warning is seen; a GUI run must not report
                # success for a schedule that was never installed.
                warn "headless run: the cron entry could not be installed"
                exit 78
            fi
            if [ "$(uname -s)" = Darwin ]; then
                say ""
                say "  IMPORTANT, macOS only:"
                say "  cron cannot read ~/Documents until /usr/sbin/cron is granted Full Disk"
                say "  Access. Without it the job runs, reports SUCCESS, and backs up almost"
                say "  nothing -- this repo detects that, but fix it now:"
                say "    System Settings > Privacy & Security > Full Disk Access"
                say "    '+' > Cmd-Shift-G > /usr/sbin/cron   (then switch the toggle ON)"
                say ""
                say "  Do NOT bother with 'launchctl kickstart' -- System Integrity Protection"
                say "  refuses it (error 150) on modern macOS. If cron is already running, log"
                say "  out and back in, or reboot, so it picks up the new grant."
                say ""
                say "  Then PROVE it works rather than assuming, with a throwaway cron entry"
                say "  that fires in two minutes:"
                say "    ./tests/cron-smoke-test.sh $NAME"
                say ""
                say "  Note also that cron does NOT catch up missed runs: if the lid is shut"
                say "  at the scheduled time the job simply does not fire. ./status.sh"
                say "  reports STALE when that has happened."
            fi
        fi
    fi
else
    if command -v crontab >/dev/null 2>&1 && cron_current 2>/dev/null | grep -qF "# >>> $CRON_TAG_PREFIX:$NAME >>>"; then
        confirm A_CRON_REMOVE "Remove the existing cron entry for '$NAME'?" && cron_uninstall "$NAME"
    fi
fi

say ""
hr
say "Done. '$NAME' is configured."
say "  run now : ./backups/$NAME.sh"
say "  dry run : ./backups/$NAME.sh --dry-run"
say "  status  : ./status.sh"
hr
