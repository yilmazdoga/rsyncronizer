# shellcheck shell=bash
#
# lib/common.sh -- the engine behind every backup in this repo.
#
# MUST stay bash 3.2 compatible: stock macOS ships GNU bash 3.2.57 and that is
# what cron will use. No associative arrays, no `mapfile`, no ${var,,}, and no
# `${arr[@]}` on a possibly-empty array (3.2 treats that as an unbound variable
# under `set -u` -- always write ${arr[@]+"${arr[@]}"}).
#
# `set -e` is deliberately NOT used. The product of this script is an exit code
# and its interpretation; -e would abort before the verdict could be written,
# and `[ cond ] && arr+=(...)` as a statement would end functions early.
# Errors are checked explicitly instead.

set -uo pipefail

TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Environment hardening. Applies to manual, tmux and cron invocations alike --
# which is why PATH is fixed here rather than with a PATH= line in the crontab
# (crontab environment assignments are file-global and would silently alter the
# user's other jobs).
# ---------------------------------------------------------------------------
for _d in /usr/bin /bin /usr/sbin /sbin /usr/local/bin /opt/homebrew/bin; do
    case ":$PATH:" in
        *":$_d:"*) ;;
        *) PATH="$PATH:$_d" ;;
    esac
done
unset _d
export PATH

# Cron sets no locale. In the plain C locale rsync escapes every non-ASCII byte
# in its file list as \#303\#251, which would render exactly the Turkish
# filenames in these backups unreadable in the log. C.UTF-8 exists on macOS 26
# and on every modern Ubuntu; en_US.UTF-8 is not guaranteed on a minimal Ubuntu.
# Ubuntu spells it 'C.utf8', macOS 'C.UTF-8' -- probing only one spelling left
# the workstation on the ssh-forwarded en_US.UTF-8, whose collation ignores
# punctuation and re-orders same-second log filenames under `sort`.
#
# grep WITHOUT -q, deliberately: under `set -o pipefail`, grep -q exits at the
# first match, `locale -a` (288 lines on macOS) dies of SIGPIPE, and the
# pipeline "fails" -- measured, that happened on EVERY macOS run, so the pin
# never engaged there. Reading all input avoids the race.
for _loc in C.UTF-8 C.utf8; do
    if locale -a 2>/dev/null | grep -xF -- "$_loc" >/dev/null 2>&1; then
        LC_ALL=$_loc
        export LC_ALL
        break
    fi
done
unset _loc

# The one support-the-author URL. tests/run-tests.sh asserts that the GUI, the
# README and lib/support-qr.txt all carry this exact string.
SUPPORT_URL='https://buymeacoffee.com/yilmazdoga'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
LOG_FILE=''
LOG_DIR=''
LOCK_DIR=''
HAVE_LOCK=0
BACKUP_NAME=''
RSYNC_BIN=''
RSYNC_FLAVOUR=''

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# log MSG... -- always to the log file (once it exists); to the terminal only
# when interactive, so a healthy cron run writes nothing to the bootstrap log.
log() {
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$*" >>"$LOG_FILE"
    fi
    if [ -t 1 ]; then
        printf '%s\n' "$*"
    fi
}

# die CODE MSG... -- always reaches stderr as well, so a failure that happens
# before the log exists is still visible in the cron bootstrap log.
die() {
    _code=$1
    shift
    if [ -n "$LOG_FILE" ]; then
        printf 'ERROR: %s\n' "$*" >>"$LOG_FILE"
    fi
    printf 'ERROR: %s\n' "$*" >&2
    exit "$_code"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# trim STRING -- strip leading/trailing spaces and tabs.
# Written as a loop rather than with a [! \t] bracket expression: inside a bash
# pattern, \t is a backslash escape for the letter t, not a tab, so the obvious
# one-liner silently strips the letter 't' from every value.
trim() {
    _t=$1
    while :; do
        case $_t in
            " "*|"$TAB"*) _t=${_t#?} ;;
            *) break ;;
        esac
    done
    while :; do
        case $_t in
            *" "|*"$TAB") _t=${_t%?} ;;
            *) break ;;
        esac
    done
    printf '%s' "$_t"
}

# resolve_path PATH -- expand a leading ~, resolve relative paths against $HOME
# (NOT the cwd: cron provides no meaningful working directory), and strip every
# trailing slash so the folder is copied BY NAME. rsync's trailing-slash rule is
# the most common way to end up with Documents/Documents.
resolve_path() {
    _rp=$1
    case $_rp in
        "~") _rp=$HOME ;;
        "~/"*) _rp=$HOME/${_rp#"~/"} ;;
        /*) ;;
        *) _rp=$HOME/$_rp ;;
    esac
    while :; do
        case $_rp in
            /) break ;;
            */) _rp=${_rp%/} ;;
            *) break ;;
        esac
    done
    printf '%s' "$_rp"
}

# ---------------------------------------------------------------------------
# Config. Files are parsed line by line and NEVER sourced, so a stray line
# cannot execute code. A value is stored as a literal string; nothing is eval'd.
# ---------------------------------------------------------------------------

# config_first_line FILE -- first non-blank, non-comment line. Used by
# source.txt, which holds a bare path rather than KEY=VALUE.
config_first_line() {
    _cf_file=$1
    [ -f "$_cf_file" ] || return 1
    while IFS= read -r _cf_line || [ -n "$_cf_line" ]; do
        case $_cf_line in
            ""|"#"*) continue ;;
        esac
        _cf_line=$(trim "$_cf_line")
        [ -n "$_cf_line" ] || continue
        printf '%s' "$_cf_line"
        return 0
    done <"$_cf_file"
    return 1
}

# config_get FILE KEY -- value for KEY, or empty. Last occurrence wins.
config_get() {
    _cg_file=$1
    _cg_key=$2
    _cg_val=''
    [ -f "$_cg_file" ] || return 1
    while IFS= read -r _cg_line || [ -n "$_cg_line" ]; do
        case $_cg_line in
            ""|"#"*) continue ;;
        esac
        case $_cg_line in
            *"="*) ;;
            *) continue ;;
        esac
        _cg_k=$(trim "${_cg_line%%=*}")
        _cg_v=$(trim "${_cg_line#*=}")
        # Whole-string key validation. A [A-Z]* glob would be wrong: under a
        # UTF-8 collation `case "source" in [A-Z]*)` MATCHES, so ranges here are
        # locale-dependent. A negated class of the permitted characters is not.
        case $_cg_k in
            ""|*[!A-Z0-9_]*) continue ;;
        esac
        if [ "$_cg_k" = "$_cg_key" ]; then
            _cg_val=$_cg_v
        fi
    done <"$_cg_file"
    printf '%s' "$_cg_val"
}

# config_unknown_keys FILE ALLOWED... -- print any key not in the allowed list,
# so a typo is reported rather than silently ignored.
config_unknown_keys() {
    _ck_file=$1
    shift
    [ -f "$_ck_file" ] || return 0
    while IFS= read -r _ck_line || [ -n "$_ck_line" ]; do
        case $_ck_line in
            ""|"#"*) continue ;;
        esac
        case $_ck_line in
            *"="*) ;;
            *) continue ;;
        esac
        _ck_k=$(trim "${_ck_line%%=*}")
        case $_ck_k in
            ""|*[!A-Z0-9_]*) printf '%s\n' "$_ck_k"; continue ;;
        esac
        _ck_found=0
        for _ck_a in "$@"; do
            [ "$_ck_k" = "$_ck_a" ] && _ck_found=1 && break
        done
        [ "$_ck_found" = 0 ] && printf '%s\n' "$_ck_k"
    done <"$_ck_file"
    return 0
}

# ---------------------------------------------------------------------------
# Support the author
# ---------------------------------------------------------------------------
# One state file in the config grammar, honor system, local only, never
# transmitted. RUN_COUNT counts every completed non-dry run (any exit code);
# the reminder shows on interactive manual runs once every 10 runs until the
# user marks themselves as having supported. Two concurrent runs can lose one
# increment (read-modify-write, deliberately no lock); that only delays the
# reminder by one run. Nothing in here may exit or alter the run's RC: a
# failure to keep this bookkeeping must never fail a backup.

_support_file() {
    printf '%s' "$REPO_ROOT/config/support.txt"
}

# _support_num KEY DEFAULT -- counters are digit-validated so a hand-mangled
# file cannot crash the arithmetic below under set -u.
_support_num() {
    _sn_v=$(config_get "$(_support_file)" "$1" 2>/dev/null) || _sn_v=''
    case $_sn_v in
        ''|*[!0-9]*) _sn_v=$2 ;;
    esac
    printf '%s' "$_sn_v"
}

_support_supported() {
    _ss_v=$(config_get "$(_support_file)" SUPPORTED 2>/dev/null) || _ss_v=''
    [ "$_ss_v" = yes ]
}

# _support_write SUPPORTED_FLAG RUN_COUNT LAST_NAG_COUNT -- atomic full
# rewrite (tmp + mv). The Python side of the GUI emits the identical format.
_support_write() {
    _sw_f=$(_support_file)
    mkdir -p "$REPO_ROOT/config" 2>/dev/null || return 0
    {
        echo '# Support-the-author state. Honor system, local only, never transmitted.'
        [ -n "$1" ] && echo 'SUPPORTED=yes'
        echo "RUN_COUNT=$2"
        echo "LAST_NAG_COUNT=$3"
    } >"$REPO_ROOT/config/.support.tmp.$$" 2>/dev/null || return 0
    mv -f "$REPO_ROOT/config/.support.tmp.$$" "$_sw_f" 2>/dev/null \
        || rm -f "$REPO_ROOT/config/.support.tmp.$$" 2>/dev/null
    return 0
}

support_count_run() {
    _sc_s=''
    _support_supported && _sc_s=yes
    _support_write "$_sc_s" "$(($(_support_num RUN_COUNT 0) + 1))" \
        "$(_support_num LAST_NAG_COUNT 0)"
}

support_nag_due() {
    _support_supported && return 1
    [ "$(($(_support_num RUN_COUNT 0) - $(_support_num LAST_NAG_COUNT 0)))" -ge 10 ]
}

# support_show_nag -- plain printf to stdout, never log(): the reminder must
# stay out of the run log, whose contents feed the deletion count and the
# exit-code verdict. Showing it arms the next 10-run window.
support_show_nag() {
    _sh_r=$(_support_num RUN_COUNT 0)
    printf '\n%s\n' '--------------------------------------------------------------'
    printf 'Rsyncronizer has completed %s backups on this machine.\n' "$_sh_r"
    printf '%s\n' 'It is completely free and will be so forever. If you find it'
    printf '%s\n' 'useful, please consider supporting me and my work:'
    printf '\n    %s\n\n' "$SUPPORT_URL"
    grep -v '^#' "$REPO_ROOT/lib/support-qr.txt" 2>/dev/null
    printf '\n%s\n' 'Already supported, or simply do not want this note?'
    printf '%s\n' 'Run: rsyncronizer support --done   (it never appears again)'
    printf '%s\n' 'Otherwise it returns after another 10 backups.'
    printf '%s\n' '--------------------------------------------------------------'
    _sh_s=''
    _support_supported && _sh_s=yes
    _support_write "$_sh_s" "$_sh_r" "$_sh_r"
}

# ---------------------------------------------------------------------------
# rsync discovery
# ---------------------------------------------------------------------------

# detect_rsync -- prefer GNU rsync when present, but openrsync is fully
# supported: it accepts this repo's entire flag string verbatim. The only flags
# it lacks are --iconv and --info=, neither of which is used.
detect_rsync() {
    # Test seam: tests/run-tests.sh points this at tests/fake-rsync so the real
    # code path can be exercised without moving a byte of real data.
    if [ -n "${RSYNC_BIN_OVERRIDE:-}" ]; then
        RSYNC_BIN=$RSYNC_BIN_OVERRIDE
        RSYNC_FLAVOUR=override
        return 0
    fi
    for _r in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
        if [ -x "$_r" ]; then
            RSYNC_BIN=$_r
            break
        fi
    done
    if [ -z "$RSYNC_BIN" ]; then
        RSYNC_BIN=$(command -v rsync 2>/dev/null) || RSYNC_BIN=''
    fi
    [ -n "$RSYNC_BIN" ] || return 1
    # Captured first, then matched: `... | grep -q` inside an `if` is the
    # pipefail+SIGPIPE trap that silently disabled the locale pin (see above).
    _rv=$("$RSYNC_BIN" --version 2>&1 | head -1)
    if printf '%s' "$_rv" | grep -i openrsync >/dev/null 2>&1; then
        RSYNC_FLAVOUR=openrsync
    else
        RSYNC_FLAVOUR=gnu
    fi
    return 0
}

# ---------------------------------------------------------------------------
# The never-delete guard.
#
# Runs on the FULLY ASSEMBLED flag array immediately before exec -- not on the
# EXTRA_FLAGS string alone -- so a bug in our own assembly is caught too.
# Source and destination are appended AFTER this runs, so a directory literally
# named --delete cannot false-positive, and a path cannot be smuggled past it.
# ---------------------------------------------------------------------------
# The blacklist, by category:
#   deletion        --del --delete* --remove-* --force* --max-delete* --ignore-errors
#   in-place        --inplace --append* --partial -P   (an interrupted write
#                   destroys the previous good copy, which here is the only one)
#   batch replay    --read-batch --write-batch --only-write-batch
#                   (a batch file can reproduce deletions recorded elsewhere)
#   alt-dest        --backup -b --backup-dir --suffix --link-dest --copy-dest
#                   --compare-dest   (these move data around at the destination)
#   remote exec /   --rsync-path -e --rsh -M --remote-option --files-from
#   root-relocation -R --relative -C --cvs-exclude --chmod --super --fake-super
#
# Note: --partial-dir=DIR is NOT blocked and is what we actually use; only the
# bare --partial is unsafe.

# Every destructive LONG option, by canonical name.
#
# The guard rejects any token that is a PREFIX of one of these, not just an
# exact match. rsync parses long options with getopt_long, which resolves any
# unambiguous abbreviation -- verified on macOS openrsync:
#
#   rsync -a --remove src/ dst/   is accepted as --remove-source-files
#                                 and really does delete the source
#   rsync -a --forc   src/ dst/   is accepted as --force
#   rsync -a --inpl   src/ dst/   is accepted as --inplace
#
# An exact-string blacklist never sees those, so it fails OPEN: the single
# control this whole design rests on could be walked past with a typo.
# Do not "simplify" this back into a plain case of full spellings.
#
# --partial is here but --partial-dir=DIR is NOT rejected: a longer token is not
# a prefix of a shorter one, and an exact match wins in getopt_long anyway.
_RBS_DANGEROUS_LONG='
--del --delete --delete-before --delete-during --delete-delay --delete-after
--delete-excluded --delete-missing-args
--remove-source-files --remove-sent-files
--force --force-delete --max-delete --ignore-errors
--inplace --append --append-verify --partial
--read-batch --write-batch --only-write-batch
--backup --backup-dir --suffix
--link-dest --copy-dest --compare-dest
--rsync-path --rsh --remote-option --files-from
--relative --cvs-exclude --chmod --super --fake-super
--old-args
'

assert_no_destructive_flags() {
    for _a in "$@"; do
        # Judge --flag=VALUE as --flag.
        case $_a in
            --*=*) _t=${_a%%=*} ;;
            *)     _t=$_a ;;
        esac
        # Prefix check: reject anything that abbreviates a destructive flag.
        case $_t in
            --*)
                for _d in $_RBS_DANGEROUS_LONG; do
                    case $_d in
                        "$_t"*)
                            if [ "$_t" = "$_d" ]; then
                                die 78 "refusing to run: unsafe rsync flag '$_a' (this tool never deletes or overwrites in place)"
                            else
                                die 78 "refusing to run: '$_a' is an abbreviation of the unsafe rsync flag '$_d' (rsync accepts unambiguous prefixes)"
                            fi
                            ;;
                    esac
                done
                ;;
        esac
        case $_a in
            --del|--delete|--delete-*|--remove-source-files|--remove-sent-files|\
--force|--force-delete|--max-delete|--max-delete=*|--ignore-errors|\
--inplace|--append|--append-verify|--partial|-P|\
--read-batch|--read-batch=*|--write-batch|--write-batch=*|\
--only-write-batch|--only-write-batch=*|\
--backup|-b|--backup-dir|--backup-dir=*|--suffix|--suffix=*|\
--link-dest|--link-dest=*|--copy-dest|--copy-dest=*|\
--compare-dest|--compare-dest=*|\
--rsync-path|--rsync-path=*|-e|--rsh|--rsh=*|\
-M|--remote-option|--remote-option=*|--files-from|--files-from=*|\
-R|--relative|-C|--cvs-exclude|--chmod|--chmod=*|\
--super|--fake-super)
                die 78 "refusing to run: unsafe rsync flag '$_a' (this tool never deletes or overwrites in place)"
                ;;
        esac
        # Bundled short options, e.g. -avP or -avM. Long options are already
        # handled above; only look at single-dash tokens.
        case $_a in
            --*) ;;
            -*)
                case $_a in
                    *P*|*M*|*C*|*R*|*b*)
                        die 78 "refusing to run: unsafe short option bundled in '$_a'"
                        ;;
                esac
                ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# The sanctioned exception: --sync-deletions.
#
# assert_no_destructive_flags above is NEVER weakened. When a prune is
# sanctioned, --delete-after is appended AFTER the guard has run -- the same
# pattern as the typed RSYNC_PATH exemption -- and this belt runs immediately
# before every such append, so a bug elsewhere cannot reach an append site
# with the wrong state.
#
# MODE is 'preview' (a --dry-run scan; no confirmation exists yet) or 'real'
# (the confirmed deleting run).
# ---------------------------------------------------------------------------
assert_prune_sanctioned() {
    [ "${PRUNE:-}" = 1 ]  || die 78 "internal error: prune append reached without --sync-deletions"
    [ -z "${FROM_CRON:-}" ] || die 78 "internal error: prune append reached under --cron"
    [ -z "${ON_MOUNT:-}" ]  || die 78 "internal error: prune append reached under --on-mount"
    if [ "$1" = real ]; then
        [ "${PRUNE_CONFIRMED:-}" = 1 ] || die 78 "internal error: prune append reached without a typed confirmation"
        [ -z "${DRY_RUN:-}" ] || die 78 "internal error: a confirmed prune cannot be a dry run"
    fi
    return 0
}

# _prune_scan RAWFILE LISTFILE -- run the prune preview (a dry run with
# --delete-after --itemize-changes) and write the cleaned, sorted deletion
# list to LISTFILE. Exits the run on any rsync code other than 0/24.
#
# Audit files are named prune-<ts>-{preview,recheck}.log: timestamp FIRST so
# lexical sort stays chronological, and OUTSIDE the [0-9]*.log run-log ring --
# scans used to be named like run logs and evicted real runs from the 30-slot
# rotation, which is exactly how "a scan looks like a run". They rotate in
# their own namespace below (newest 10 kept).
#
# The parse keys on '^*deleting': with --itemize-changes a deletion is
# unambiguous, whereas plain -v output cannot be told apart from a transferred
# file literally named 'deleting x'. The separator differs by implementation
# (openrsync prints one space, GNU pads the itemize column), hence the
# flavour branch. This list is what the user confirms and what the counts
# come from; the deletion set itself is always computed by rsync.
_prune_scan() {
    _ps_raw=$1
    _ps_list=$2
    assert_prune_sanctioned preview
    "$RSYNC_BIN" ${ARGS[@]+"${ARGS[@]}"} --dry-run --delete-after --itemize-changes \
        "$SRC" "$DEST" >"$_ps_raw" 2>&1
    _ps_rc=$?
    case $_ps_rc in
        0|24) ;;
        *)
            log "prune preview failed; last lines of its output:"
            tail -10 "$_ps_raw" | while IFS= read -r _ps_l; do log "  $_ps_l"; done
            interpret_exit "$_ps_rc"
            exit "$_ps_rc"
            ;;
    esac
    if [ "$RSYNC_FLAVOUR" = gnu ]; then
        sed -n 's/^\*deleting[[:space:]]*//p' "$_ps_raw" | sort >"$_ps_list"
    else
        sed -n 's/^\*deleting //p' "$_ps_raw" | sort >"$_ps_list"
    fi
    # The audit ring: keep the newest 10 prune scans, never touching the
    # [0-9]*.log run logs (and vice versa).
    ls -1 "$LOG_DIR"/prune-*.log 2>/dev/null | sort -r | awk 'NR>10' \
        | while IFS= read -r _ps_old; do
            rm -f -- "$_ps_old"
        done
    return 0
}

# ---------------------------------------------------------------------------
# Locking. mkdir-based (atomic); flock is unavailable on macOS.
#
# Lives under $HOME/.cache, NOT $TMPDIR: cron sets no TMPDIR while an
# interactive macOS shell has /var/folders/.../T, so a $TMPDIR lock would let a
# manual run and the scheduled run take two different locks and start two
# concurrent 162 GB transfers. This deviates from CLAUDE.md deliberately.
# ---------------------------------------------------------------------------
acquire_lock() {
    _name=$1
    _base=${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup
    mkdir -p "$_base" 2>/dev/null || die 74 "cannot create lock directory: $_base"
    LOCK_DIR=$_base/$_name.lock

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        HAVE_LOCK=1
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        return 0
    fi

    _pid=''
    if [ -f "$LOCK_DIR/pid" ]; then
        _pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || _pid=''
    fi
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        return 1
    fi

    log "stale lock found (pid ${_pid:-unknown} is not running); reclaiming it"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    # Confirm ownership after the reclaim. If two runs both saw the same stale
    # lock, only one of them still owns it now.
    _owner=$(cat "$LOCK_DIR/pid" 2>/dev/null) || _owner=''
    [ "$_owner" = "$$" ] || return 1
    HAVE_LOCK=1
    return 0
}

# Only ever removes a lock THIS process created. Removing it on the
# failed-acquire path would delete the running backup's lock and let a third
# invocation start alongside it.
release_lock() {
    [ "$HAVE_LOCK" = 1 ] || return 0
    [ -n "$LOCK_DIR" ] || return 0
    rm -rf "$LOCK_DIR"
    HAVE_LOCK=0
    return 0
}

_on_exit() { release_lock; }
_on_signal() {
    release_lock
    exit 143
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
open_log() {
    _name=$1
    LOG_DIR=$REPO_ROOT/logs/$_name
    mkdir -p "$LOG_DIR" || die 74 "cannot create log directory: $LOG_DIR"
    # This format sorts lexically == chronologically, which is what lets
    # rotation avoid date arithmetic and avoid trusting mtimes.
    LOG_FILE=$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log
    : >"$LOG_FILE" || die 74 "cannot write log file: $LOG_FILE"
}

# rotate_logs DIR KEEP -- `head -n -N` is a GNU extension and fails on macOS.
#
# The glob is [0-9]*.log, NOT *.log. Run logs are named YYYY-MM-DD_HHMMSS.log, but
# the same directory also holds cron-bootstrap.log -- which `sort -r` puts FIRST
# (c > 2), so it would permanently occupy a retention slot and one real log would
# be pruned early. It must also never be deleted: anything in it is real signal.
rotate_logs() {
    _rl_dir=$1
    _rl_keep=$2
    ls -1 "$_rl_dir"/[0-9]*.log 2>/dev/null | sort -r | awk -v k="$_rl_keep" 'NR>k' \
        | while IFS= read -r _rl_f; do
            # The only rm in the whole system that touches anything but a lock,
            # and it is scoped to this backup's own *.log files.
            rm -f -- "$_rl_f"
        done
    return 0
}

# interpret_exit CODE -- the verdict is the deliverable, not the raw number.
interpret_exit() {
    case $1 in
        0)  log "RESULT: SUCCESS (0)" ;;
        24) log "RESULT: SUCCESS (24) -- some source files vanished while the run was in progress."
            log "        Benign: something was deleted or moved at the source mid-transfer." ;;
        23) log "RESULT: PARTIAL (23) -- some files could not be transferred."
            log "        Search this log for 'rsync: ' lines to see which, and why."
            if [ "${DEST_FS:-}" = exfat ]; then
                log "        The destination is exFAT, which cannot store  | < > : \" ? * \\  in a"
                log "        filename. Find offenders with (note the two patterns -- a single"
                log "        bracket expression does NOT work, the backslash escapes the ']'):"
                log "          find \"\$SRC\" \\( -name '*[|<>:\"?*]*' -o -name '*\\\\*' \\)"
            else
                log "        The destination is a normal Unix filesystem, so this is NOT a"
                log "        filename-character problem -- look for unreadable files."
            fi ;;
        12|255)
            log "RESULT: SSH FAILURE ($1) -- could not reach the destination."
            if [ -n "${DEST_HOST:-}" ]; then
                log "        Check the link, then: ssh -o BatchMode=yes $DEST_HOST true"
            fi ;;
        30|35)
            log "RESULT: TIMEOUT ($1) -- the connection stalled longer than TIMEOUT allows."
            log "        Re-running resumes from .rsync-partial; nothing was deleted." ;;
        1)  log "RESULT: FAILED (1) -- rsync syntax or usage error. Suspect EXTRA_FLAGS in options.txt." ;;
        *)  log "RESULT: FAILED ($1)" ;;
    esac
}

# ---------------------------------------------------------------------------
# The macOS Full Disk Access detector.
#
# Under cron without Full Disk Access, ~/Documents reads as EMPTY: rsync
# succeeds, transfers almost nothing, and the log says everything is fine. This
# is the failure mode most likely to go unnoticed, so it is checked explicitly.
# TCC shows up two ways -- an empty listing, or EPERM -- so test for both.
# ---------------------------------------------------------------------------
check_source_readable() {
    _src=$1
    _allow_empty=$2

    [ -d "$_src" ] || die 66 "source is not a directory: $_src"

    # 2>&1 >/dev/null captures stderr ONLY -- that ordering matters.
    _perr=$(find "$_src" -mindepth 1 -maxdepth 1 -print 2>&1 >/dev/null)
    if [ -n "$_perr" ]; then
        log "WARNING: the source could not be fully read:"
        log "  $_perr"
        if [ "$(uname -s)" = Darwin ]; then
            # macOS grants Full Disk Access PER BINARY, and children inherit it.
            # So the binary that needs the grant depends on who launched us.
            log "  This is macOS Full Disk Access. The grant is per-binary and is"
            log "  inherited by child processes, so the binary to grant depends on"
            log "  what started this run:"
            if [ -n "${ON_MOUNT:-}" ]; then
                log "    launched by the drive-connect launchd agent -> grant /bin/bash"
                log "    (the agent runs /bin/bash directly, so /bin/bash needs it)"
                log "    System Settings > Privacy & Security > Full Disk Access"
                log "    '+' then Cmd-Shift-G then /bin/bash"
                log "    Note this grants every bash script on the machine the same access."
                log "    The narrower alternative is to drop the agent and let cron poll"
                log "    instead -- cron already has the grant. See README."
            else
                log "    launched by cron -> grant /usr/sbin/cron"
                log "    System Settings > Privacy & Security > Full Disk Access"
                log "    '+' then Cmd-Shift-G then /usr/sbin/cron"
            fi
            log "  Then log out and back in. 'launchctl kickstart' does NOT work:"
            log "  System Integrity Protection refuses it (error 150)."
        fi
    fi

    _count=$(find "$_src" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    log "source check: $_count top-level entries in $_src"

    if [ "$_count" -eq 0 ] && [ "$_allow_empty" != yes ]; then
        log ""
        log "The source directory appears EMPTY. Refusing to run: a backup that"
        log "copies nothing must not be recorded as a success."
        if [ "$(uname -s)" = Darwin ]; then
            log "If this ran from cron, the cause is almost certainly Full Disk Access"
            log "(see above). If the source really is empty, set ALLOW_EMPTY_SOURCE=yes"
            log "in config/$BACKUP_NAME/options.txt."
        else
            log "If the source really is empty, set ALLOW_EMPTY_SOURCE=yes in"
            log "config/$BACKUP_NAME/options.txt."
        fi
        die 66 "source is empty: $_src"
    fi

    # Self-heal: logs/ is disposable, so deleting it must not permanently lose
    # the drift detector. A run that got this far has read the source
    # successfully and seen a non-zero count, which is exactly the condition
    # setup.sh records under -- so it is safe to re-record here.
    if [ ! -f "$LOG_DIR/.baseline_count" ] && [ "$_count" -gt 0 ]; then
        printf '%s\n' "$_count" >"$LOG_DIR/.baseline_count" 2>/dev/null \
            && log "recorded a new baseline of $_count entries (none was stored)"
    fi

    # Compare against the count recorded by setup.sh while running as the
    # interactive, TCC-allowed user, so the very FIRST scheduled run has a
    # truthful reference rather than needing one good run before it can detect.
    if [ -f "$LOG_DIR/.baseline_count" ]; then
        _base=$(cat "$LOG_DIR/.baseline_count" 2>/dev/null) || _base=''
        case $_base in
            ""|*[!0-9]*) _base='' ;;
        esac
        if [ -n "$_base" ] && [ "$_count" -lt "$_base" ]; then
            log "NOTE: top-level entry count ($_count) is below the baseline recorded at setup ($_base)."
            log "      If this is unexpected, check Full Disk Access before trusting this run."
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Removable-volume support, for backups triggered by plugging a drive in.
#
# The one catastrophic failure here is writing to the mount POINT while the
# drive is absent: rsync would happily fill the system disk with hundreds of GB
# and exit 0. Two independent guards prevent it -- the path must actually be a
# mount point, and it must carry our marker file, which lives ON the drive.
# ---------------------------------------------------------------------------

VOLUME_MARKER_NAME='.rsync-backup-volume'

# _dev_of PATH -- device number, the portable way. BSD stat and GNU stat take
# different flags, so probe once rather than branching on uname.
_dev_of() {
    if stat -f %d / >/dev/null 2>&1; then
        stat -f %d -- "$1" 2>/dev/null      # BSD / macOS
    else
        stat -c %d -- "$1" 2>/dev/null      # GNU / Linux
    fi
}

# volume_mounted PATH -- true when PATH is the root of a mounted filesystem.
# Comparing PATH's device to its parent's avoids parsing df entirely: df output
# cannot be split reliably when a mount point or filesystem name contains spaces.
volume_mounted() {
    _vm_p=$1
    [ -d "$_vm_p" ] || return 1
    _vm_a=$(_dev_of "$_vm_p")
    _vm_b=$(_dev_of "$_vm_p/..")
    [ -n "$_vm_a" ] && [ -n "$_vm_b" ] && [ "$_vm_a" != "$_vm_b" ]
}

# volume_is_ours PATH -- the marker lives on the drive itself, so it is absent
# when the drive is not there, even if the mount point directory exists.
volume_is_ours() {
    [ -f "$1/$VOLUME_MARKER_NAME" ]
}

# assert_volume_ready PATH -- used by every local run, triggered or manual.
assert_volume_ready() {
    _av_p=$1
    volume_mounted "$_av_p" \
        || die 69 "the backup drive is not mounted at $_av_p -- refusing to write to the system disk"
    volume_is_ours "$_av_p" \
        || die 69 "$_av_p is mounted but has no $VOLUME_MARKER_NAME marker -- wrong drive? (run ./setup.sh to mark it)"
}

# _trigger_note LOGDIR MSG -- a small, bounded record of trigger decisions that
# did NOT produce a run, so "why didn't it back up?" is answerable.
_trigger_note() {
    _tn_dir=$1
    shift
    mkdir -p "$_tn_dir" 2>/dev/null || return 0
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$_tn_dir/trigger-events.txt" 2>/dev/null
    if [ "$(wc -l <"$_tn_dir/trigger-events.txt" 2>/dev/null || echo 0)" -gt 400 ]; then
        tail -200 "$_tn_dir/trigger-events.txt" >"$_tn_dir/trigger-events.tmp" 2>/dev/null \
            && mv "$_tn_dir/trigger-events.tmp" "$_tn_dir/trigger-events.txt"
    fi
}

# mount_gate NAME CFG -- decide whether an --on-mount invocation should proceed.
# Returns 1 to skip. Called BEFORE open_log and before the lock: macOS
# StartOnMount fires for EVERY mount (disk images, network shares), and opening
# a log for each would churn the 30-log ring buffer away in a single day.
mount_gate() {
    _mg_name=$1
    _mg_cfg=$2
    _mg_logdir=$REPO_ROOT/logs/$_mg_name

    # Not a removable-volume backup: let the normal path report whatever is wrong.
    [ "$(config_get "$_mg_cfg/destination.txt" DEST_TYPE 2>/dev/null)" = local ] || return 0

    _mg_vol=$(config_get "$_mg_cfg/destination.txt" VOLUME_ROOT 2>/dev/null)
    [ -n "$_mg_vol" ] || return 0
    _mg_vol=$(resolve_path "$_mg_vol")

    # Silent on the overwhelmingly common case -- some other volume mounted.
    # Writing a note here would bury the interesting lines in DMG noise.
    volume_mounted "$_mg_vol" || return 1
    volume_is_ours "$_mg_vol" || return 1

    # Cooldown keyed on the last ATTEMPT, not the last SUCCESS. On this
    # destination a partial transfer (23) can be the steady state, and a
    # success-keyed cooldown would then never engage -- the drive would be
    # rescanned in full on every single replug.
    _mg_cool=$(config_get "$_mg_cfg/options.txt" COOLDOWN_HOURS 2>/dev/null)
    case $_mg_cool in ''|*[!0-9]*) _mg_cool=12 ;; esac
    if [ "$_mg_cool" -gt 0 ] && [ -f "$_mg_logdir/.last_attempt_epoch" ]; then
        _mg_last=$(cat "$_mg_logdir/.last_attempt_epoch" 2>/dev/null) || _mg_last=''
        case $_mg_last in ''|*[!0-9]*) _mg_last='' ;; esac
        if [ -n "$_mg_last" ]; then
            _mg_age=$(( $(date +%s) - _mg_last ))
            if [ "$_mg_age" -ge 0 ] && [ "$_mg_age" -lt $(( _mg_cool * 3600 )) ]; then
                _trigger_note "$_mg_logdir" \
                    "skip: drive present, last attempt $(( _mg_age / 60 ))m ago, cooldown ${_mg_cool}h (rm .last_attempt_epoch to force)"
                return 1
            fi
        fi
    fi

    # Armed at the moment the gate clears, not after rsync returns, so a crash
    # mid-transfer still bounds how soon the next replug retries.
    mkdir -p "$_mg_logdir" 2>/dev/null
    date +%s >"$_mg_logdir/.last_attempt_epoch" 2>/dev/null
    _trigger_note "$_mg_logdir" "run: drive present, cooldown ${_mg_cool}h satisfied"
    return 0
}

# ---------------------------------------------------------------------------
# The main entry point. Every generated runner calls this and nothing else.
# ---------------------------------------------------------------------------
run_backup() {
    BACKUP_NAME=$1
    shift

    DRY_RUN=''
    FROM_CRON=''
    PREFLIGHT_ONLY=''
    ON_MOUNT=''
    PRUNE=''
    PRUNE_CONFIRMED=''
    PRUNE_ACTIVE=''
    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run|-n) DRY_RUN=1 ;;
            --cron) FROM_CRON=1 ;;
            --preflight) PREFLIGHT_ONLY=1 ;;
            --on-mount) ON_MOUNT=1 ;;
            --sync-deletions) PRUNE=1 ;;
            *) die 64 "unknown argument: $1 (accepts --dry-run, --preflight, --cron, --on-mount, --sync-deletions)" ;;
        esac
        shift
    done

    # --sync-deletions is the ONLY sanctioned path to deletion, and it is manual by
    # construction. The cron/on-mount bans are unconditional -- no environment
    # variable lifts them. The terminal check covers BOTH ends: a piped stdin
    # cannot answer the prompt, and a redirected stdout would leave `read`
    # blocked invisibly while holding the lock. RBS_TEST_CONFIRM_STDIN is the
    # test seam for the TTY check alone, and it is honoured only when rsync is
    # the stub (RSYNC_BIN_OVERRIDE) -- on the real binary it is inert, so the
    # confirmation cannot be scripted or scheduled around.
    if [ -n "$PRUNE" ]; then
        [ -n "$FROM_CRON" ] && die 78 "--sync-deletions is refused on scheduled runs: deletion requires an interactive confirmation"
        [ -n "$ON_MOUNT" ]  && die 78 "--sync-deletions is refused on drive-connect runs: deletion requires an interactive confirmation"
        _seam=''
        [ -n "${RBS_TEST_CONFIRM_STDIN:-}" ] && [ -n "${RSYNC_BIN_OVERRIDE:-}" ] && _seam=1
        if [ -z "$DRY_RUN" ] && [ -z "$PREFLIGHT_ONLY" ] && [ -z "$_seam" ] \
           && { [ ! -t 0 ] || [ ! -t 1 ]; }; then
            die 78 "--sync-deletions needs a terminal on stdin and stdout to ask for confirmation"
        fi
    fi

    # The mount gate runs BEFORE the log is opened, and is the only thing that
    # does. A drive-connect trigger fires on every volume mount on the machine,
    # so the common case must cost one stat and leave no trace.
    if [ -n "$ON_MOUNT" ]; then
        mount_gate "$BACKUP_NAME" "$REPO_ROOT/config/$BACKUP_NAME" || exit 0
    fi

    # The log is opened FIRST, before config is validated. The crontab line
    # redirects to a bootstrap file, so a config error that died before the log
    # existed would otherwise be completely silent under cron.
    open_log "$BACKUP_NAME"
    trap _on_exit EXIT
    trap _on_signal INT TERM HUP

    _cfg=$REPO_ROOT/config/$BACKUP_NAME
    log "=============================================================="
    log "backup   : $BACKUP_NAME"
    log "started  : $(date '+%Y-%m-%d %H:%M:%S %z')"
    log "host     : $(hostname 2>/dev/null || echo unknown)"
    if [ -n "$ON_MOUNT" ]; then _how=drive-connect
    elif [ -n "$FROM_CRON" ]; then _how=cron
    else _how=manual; fi
    log "invoked  : $_how$([ -n "$DRY_RUN" ] && echo ' (dry run)')"
    log "=============================================================="

    # --- config -----------------------------------------------------------
    [ -d "$_cfg" ] || die 78 "no configuration for '$BACKUP_NAME'. Run ./setup.sh to create it. (looked in $_cfg)"
    for _f in source.txt destination.txt; do
        [ -f "$_cfg/$_f" ] || die 78 "missing $_cfg/$_f. Run ./setup.sh to recreate it."
    done

    _raw_src=$(config_first_line "$_cfg/source.txt") \
        || die 78 "$_cfg/source.txt is empty. Run ./setup.sh."
    SRC=$(resolve_path "$_raw_src")

    DEST_USER=$(config_get "$_cfg/destination.txt" USER)
    DEST_HOST=$(config_get "$_cfg/destination.txt" HOST)
    DEST_PATH=$(config_get "$_cfg/destination.txt" DEST_PATH)
    RSYNC_PATH=$(config_get "$_cfg/destination.txt" RSYNC_PATH)
    # An EXPLICIT key, never inferred from an empty HOST: destination.txt is
    # hand-editable, and a HOST line blanked by accident must not silently turn
    # an SSH backup into one that writes into $HOME. Absent == ssh == the
    # behaviour every existing config already has.
    DEST_TYPE=$(config_get "$_cfg/destination.txt" DEST_TYPE)
    VOLUME_ROOT=$(config_get "$_cfg/destination.txt" VOLUME_ROOT)
    DEST_FS=$(config_get "$_cfg/destination.txt" DEST_FS)
    [ -n "$DEST_TYPE" ] || DEST_TYPE=ssh

    _unknown=$(config_unknown_keys "$_cfg/destination.txt" \
        USER HOST DEST_PATH RSYNC_PATH DEST_TYPE VOLUME_ROOT DEST_FS)
    [ -n "$_unknown" ] && die 78 "unknown key(s) in destination.txt: $(echo $_unknown)"

    # Every one of these must be initialised BEFORE use: `set -u` makes an unset
    # variable a fatal error, so a key that only some backups set would crash
    # every backup that does not set it.
    SSH_PORT=''; BWLIMIT=''; TIMEOUT=''; EXTRA_FLAGS=''; ALLOW_EMPTY_SOURCE=''
    PRESERVE_PERMS=''; MODIFY_WINDOW=''; COOLDOWN_HOURS=''; COPY_LINKS=''
    if [ -f "$_cfg/options.txt" ]; then
        _unknown=$(config_unknown_keys "$_cfg/options.txt" \
            SSH_PORT BWLIMIT TIMEOUT EXTRA_FLAGS ALLOW_EMPTY_SOURCE \
            PRESERVE_PERMS MODIFY_WINDOW COOLDOWN_HOURS COPY_LINKS)
        [ -n "$_unknown" ] && die 78 "unknown key(s) in options.txt: $(echo $_unknown)"
        SSH_PORT=$(config_get "$_cfg/options.txt" SSH_PORT)
        BWLIMIT=$(config_get "$_cfg/options.txt" BWLIMIT)
        TIMEOUT=$(config_get "$_cfg/options.txt" TIMEOUT)
        EXTRA_FLAGS=$(config_get "$_cfg/options.txt" EXTRA_FLAGS)
        ALLOW_EMPTY_SOURCE=$(config_get "$_cfg/options.txt" ALLOW_EMPTY_SOURCE)
        PRESERVE_PERMS=$(config_get "$_cfg/options.txt" PRESERVE_PERMS)
        MODIFY_WINDOW=$(config_get "$_cfg/options.txt" MODIFY_WINDOW)
        COOLDOWN_HOURS=$(config_get "$_cfg/options.txt" COOLDOWN_HOURS)
        COPY_LINKS=$(config_get "$_cfg/options.txt" COPY_LINKS)
    fi
    [ -n "$TIMEOUT" ] || TIMEOUT=600
    case $TIMEOUT in *[!0-9]*) die 78 "TIMEOUT must be a number, got: $TIMEOUT" ;; esac
    [ -n "$BWLIMIT" ] && { case $BWLIMIT in *[!0-9]*) die 78 "BWLIMIT must be a number, got: $BWLIMIT" ;; esac; }
    [ -n "$SSH_PORT" ] && { case $SSH_PORT in *[!0-9]*) die 78 "SSH_PORT must be a number, got: $SSH_PORT" ;; esac; }
    [ -n "$MODIFY_WINDOW" ] && { case $MODIFY_WINDOW in *[!0-9]*) die 78 "MODIFY_WINDOW must be a number, got: $MODIFY_WINDOW" ;; esac; }
    [ -n "$COOLDOWN_HOURS" ] && { case $COOLDOWN_HOURS in *[!0-9]*) die 78 "COOLDOWN_HOURS must be a number, got: $COOLDOWN_HOURS" ;; esac; }

    case $DEST_TYPE in
        ssh)
            [ -n "$DEST_HOST" ] || die 78 "HOST is not set in $_cfg/destination.txt"
            [ -n "$DEST_PATH" ] || die 78 "DEST_PATH is not set in $_cfg/destination.txt"
            if [ -n "$DEST_USER" ]; then
                REMOTE="$DEST_USER@$DEST_HOST"
            else
                REMOTE="$DEST_HOST"
            fi
            DEST="$REMOTE:$DEST_PATH/"
            ;;
        local)
            # A half-edited config is a misconfiguration, not something to
            # silently ignore.
            [ -z "$DEST_HOST" ]  || die 78 "DEST_TYPE=local but HOST is set in $_cfg/destination.txt"
            [ -z "$DEST_USER" ]  || die 78 "DEST_TYPE=local but USER is set in $_cfg/destination.txt"
            [ -z "$RSYNC_PATH" ] || die 78 "DEST_TYPE=local but RSYNC_PATH is set in $_cfg/destination.txt"
            [ -n "$VOLUME_ROOT" ] || die 78 "DEST_TYPE=local requires VOLUME_ROOT in $_cfg/destination.txt"
            [ -n "$DEST_PATH" ] || die 78 "DEST_PATH is not set in $_cfg/destination.txt"
            # Absolute is not tidiness. rsync parses a path whose first colon
            # precedes the first slash as host:path, so a relative DEST_PATH on
            # a filesystem that permits ':' becomes a silent SSH attempt.
            case $DEST_PATH in /*) ;; *) die 78 "DEST_TYPE=local requires an ABSOLUTE DEST_PATH, got: $DEST_PATH" ;; esac
            case $VOLUME_ROOT in /*) ;; *) die 78 "VOLUME_ROOT must be absolute, got: $VOLUME_ROOT" ;; esac
            VOLUME_ROOT=$(resolve_path "$VOLUME_ROOT")
            DEST_PATH=$(resolve_path "$DEST_PATH")
            # Writing outside the removable volume is the failure this whole
            # feature must not have: it would fill the system disk instead.
            case "$DEST_PATH/" in
                "$VOLUME_ROOT"/*) ;;
                *) die 78 "DEST_PATH ($DEST_PATH) must be inside VOLUME_ROOT ($VOLUME_ROOT)" ;;
            esac
            REMOTE=''
            DEST="$DEST_PATH/"
            ;;
        *) die 78 "DEST_TYPE must be 'ssh' or 'local', got: $DEST_TYPE" ;;
    esac

    # --- rsync ------------------------------------------------------------
    detect_rsync || die 69 "no rsync found on PATH"
    log "rsync    : $RSYNC_BIN ($RSYNC_FLAVOUR)"
    if [ "$RSYNC_FLAVOUR" = openrsync ]; then
        case $EXTRA_FLAGS in
            *--iconv*|*--info=*)
                die 69 "EXTRA_FLAGS uses a flag openrsync does not support. Run: brew install rsync"
                ;;
        esac
    fi

    log "source   : $SRC"
    log "dest     : $DEST"
    log "lands as : $DEST${SRC##*/}/"

    # Checked on EVERY local run, not just triggered ones. A manual run with the
    # drive unplugged is the same catastrophe: rsync would create the mount-point
    # directory on the system disk and quietly fill it.
    if [ "$DEST_TYPE" = local ]; then
        assert_volume_ready "$VOLUME_ROOT"
        log "volume   : $VOLUME_ROOT mounted, marker present${DEST_FS:+ ($DEST_FS)}"
        log "free     : $(df -Pk -- "$VOLUME_ROOT" 2>/dev/null | awk 'NR==2{printf "%.1f GB", $4/1048576}')"
    fi
    log ""

    check_source_readable "$SRC" "$ALLOW_EMPTY_SOURCE"

    if [ -n "$PREFLIGHT_ONLY" ]; then
        log ""
        log "RESULT: PREFLIGHT OK (no transfer attempted)"
        exit 0
    fi

    # --- lock -------------------------------------------------------------
    if ! acquire_lock "$BACKUP_NAME"; then
        log ""
        log "RESULT: SKIPPED -- another run of '$BACKUP_NAME' is already in progress."
        # An overlap is a normal condition, not an error worth mailing about.
        exit 0
    fi

    # --- flags ------------------------------------------------------------
    # -a is -Dgloprt. --no-o --no-g must follow it (later wins) and are a hard
    # rule: chown only works when the receiver runs as root, so over a normal
    # SSH login it was silently failing anyway. --no-D is here for the same
    # structural reason: an unprivileged receiver cannot mknod, and leaving -D
    # on manufactures spurious exit-23 runs that would destroy the exit-code
    # signal this design depends on. Symlinks are still preserved.
    ARGS=( -a --no-D --no-o --no-g -v --stats )
    ARGS+=( --partial-dir=.rsync-partial )   # never bare --partial: that leaves
                                             # a truncated file under its real
                                             # name, which the next run's
                                             # size+mtime check accepts as whole
    ARGS+=( --timeout="$TIMEOUT" )
    # THE global exclude layer: config/global-exclude.txt, user-owned and
    # fully visible -- it is seeded from rsync-ignore.txt at setup time, and
    # from then on it REPLACES the shipped list entirely (no hidden excludes:
    # deleting a rule there really un-excludes it). rsync-ignore.txt itself is
    # only the fallback for a bare clone that never initialized, and the seed
    # source. Note excludes also shield matching destination entries from
    # --sync-deletions.
    if [ -f "$REPO_ROOT/config/global-exclude.txt" ]; then
        ARGS+=( --exclude-from="$REPO_ROOT/config/global-exclude.txt" )
        log "excludes : config/global-exclude.txt (global, yours)"
    else
        ARGS+=( --exclude-from="$REPO_ROOT/rsync-ignore.txt" )
    fi
    # An optional SECOND exclude file, per backup. Destination-specific
    # exclusions belong here, never in the shared rsync-ignore.txt, which is
    # documented as applying to every backup on every machine.
    if [ -f "$_cfg/exclude.txt" ]; then
        ARGS+=( --exclude-from="$_cfg/exclude.txt" )
        log "excludes : + $_cfg/exclude.txt"
    fi
    [ -n "$BWLIMIT" ] && ARGS+=( --bwlimit="$BWLIMIT" )
    [ -n "$DRY_RUN" ] && ARGS+=( --dry-run )

    # exFAT and friends: no permission bits, and 2-second timestamp granularity
    # (without --modify-window every file looks modified on every run).
    [ "$PRESERVE_PERMS" = no ] && ARGS+=( --no-p )
    [ -n "$MODIFY_WINDOW" ] && ARGS+=( --modify-window="$MODIFY_WINDOW" )
    # exFAT on LINUX cannot store symlinks at all ("Operation not permitted"),
    # which makes every run exit 23 forever and turns the systemd unit red.
    # macOS's exFAT driver DOES support them, hence the per-backup option.
    # -L copies what the link points AT, so the backup keeps the real content
    # and stays restorable -- strictly better here than skipping the file.
    [ "$COPY_LINKS" = yes ] && ARGS+=( -L )

    if [ "$DEST_TYPE" = ssh ]; then
        # The remote shell goes through RSYNC_RSH rather than -e, so -e can stay
        # on the destructive-flag blacklist with no exemption carved out for us.
        _rsh="ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
        [ -n "$SSH_PORT" ] && _rsh="$_rsh -p $SSH_PORT"
        RSYNC_RSH=$_rsh
        export RSYNC_RSH
    else
        # No remote shell is involved at all. Unset rather than leave a stale
        # value in the environment.
        unset RSYNC_RSH 2>/dev/null || true
    fi

    # EXTRA_FLAGS is split with globbing disabled: a '*' in the value would
    # otherwise glob against cron's cwd.
    if [ -n "$EXTRA_FLAGS" ]; then
        set -f
        # shellcheck disable=SC2086
        set -- $EXTRA_FLAGS
        set +f
        ARGS+=( ${1+"$@"} )
    fi

    [ -f "$REPO_ROOT/rsync-ignore.txt" ] \
        || die 78 "missing $REPO_ROOT/rsync-ignore.txt -- incomplete checkout?"

    assert_no_destructive_flags ${ARGS[@]+"${ARGS[@]}"}

    # Typed exemption: --rsync-path may only arrive through the validated
    # RSYNC_PATH key, never through EXTRA_FLAGS, and is appended after the guard.
    if [ -n "$RSYNC_PATH" ]; then
        case $RSYNC_PATH in
            /*rsync) ARGS+=( --rsync-path="$RSYNC_PATH" ) ;;
            *) die 78 "RSYNC_PATH must be an absolute path ending in 'rsync', got: $RSYNC_PATH" ;;
        esac
    fi

    # Paths are appended AFTER the guard, and validated separately so neither
    # can be mistaken for a flag.
    case $SRC in -*) die 78 "source path may not begin with '-'" ;; esac
    case $DEST in -*) die 78 "destination may not begin with '-'" ;; esac

    # --- prune: the sanctioned deletion path (see assert_prune_sanctioned) --
    # This block sits INSIDE the lock, so a scheduled run arriving while the
    # prompt is open exits 0 SKIPPED instead of racing the deletion.
    if [ -n "$PRUNE" ] && [ -n "$DRY_RUN" ]; then
        # The dry run IS the preview; no prompt, nothing happens.
        assert_prune_sanctioned preview
        ARGS+=( --delete-after --itemize-changes )
        log "prune    : DRY RUN -- lines marked '*deleting' would be deleted; nothing happens"
    elif [ -n "$PRUNE" ]; then
        # Preview: raw itemized output goes to its own prune-<ts>-preview.log
        # audit file (its own ring, see _prune_scan), NOT into the main log --
        # after the real run, '*deleting' lines in the main log are counted as
        # actual deletions, so preview output there would inflate the count.
        _pv_raw=$LOG_DIR/prune-$(date +%Y-%m-%d_%H%M%S)-preview.log
        _pv_list=$LOG_DIR/.prune-list-confirmed.txt
        log "prune    : scanning the destination for entries absent from the source..."
        _prune_scan "$_pv_raw" "$_pv_list"
        _pv_n=$(wc -l <"$_pv_list" | tr -d ' ')
        if [ "$_pv_n" -eq 0 ]; then
            log "prune    : nothing to prune -- the destination holds no entries absent from the source."
            log "prune    : continuing as a normal backup run (no deletion flag)."
        else
            log "prune    : $_pv_n entries exist at the DESTINATION but not at the source"
            log "prune    : and would be DELETED from $DEST"
            # The full list always goes to the log; the terminal shows at most 200.
            sed 's/^/  will delete: /' "$_pv_list" >>"$LOG_FILE"
            if [ -t 1 ]; then
                head -200 "$_pv_list" | sed 's/^/  will delete: /'
                if [ "$_pv_n" -gt 200 ]; then
                    printf '  ... and %s more -- the full list is in %s\n' "$((_pv_n - 200))" "$LOG_FILE"
                fi
            fi
            printf "\nType 'I confirm' to delete these %s entries from the destination (anything else aborts): " "$_pv_n"
            IFS= read -r _pv_reply || _pv_reply=''
            _pv_reply=$(trim "$_pv_reply")
            case $_pv_reply in
                'I confirm'|'i confirm') ;;
                *)
                    log ""
                    log "RESULT: NOT CONFIRMED -- nothing was transferred or deleted."
                    release_lock
                    exit 75
                    ;;
            esac
            log "prune    : user typed the confirmation for $_pv_n entries"
            # Re-verify before deleting. The prompt can sit open for hours; a
            # source that unmounted into an empty-but-readable directory in the
            # meantime would otherwise turn this into "delete the entire
            # destination tree". Nothing is deleted unless the recomputed list
            # is IDENTICAL to the one that was confirmed.
            check_source_readable "$SRC" "$ALLOW_EMPTY_SOURCE"
            [ "$DEST_TYPE" = local ] && assert_volume_ready "$VOLUME_ROOT"
            _pv_raw2=$LOG_DIR/prune-$(date +%Y-%m-%d_%H%M%S)-recheck.log
            _pv_list2=$LOG_DIR/.prune-list-recheck.txt
            _prune_scan "$_pv_raw2" "$_pv_list2"
            if ! cmp -s "$_pv_list" "$_pv_list2"; then
                _pv_n2=$(wc -l <"$_pv_list2" | tr -d ' ')
                log ""
                log "RESULT: LIST CHANGED -- the deletion list is no longer what was confirmed"
                log "        (confirmed $_pv_n entries, recheck found $_pv_n2). Nothing was"
                log "        transferred or deleted. Re-run --sync-deletions to review the new list."
                release_lock
                exit 75
            fi
            PRUNE_CONFIRMED=1
            assert_prune_sanctioned real
            ARGS+=( --delete-after --itemize-changes )
            PRUNE_ACTIVE=1
            log "prune    : confirmed; --delete-after enabled for this run"
        fi
    fi

    log "command  : $RSYNC_BIN ${ARGS[*]} <source> <dest>"
    # Only set for ssh destinations; a local one has no remote shell at all.
    [ -n "${RSYNC_RSH:-}" ] && log "RSYNC_RSH: $RSYNC_RSH"
    log "--------------------------------------------------------------"

    # --- run --------------------------------------------------------------
    _start=$(date +%s)
    if [ -t 1 ]; then
        "$RSYNC_BIN" ${ARGS[@]+"${ARGS[@]}"} "$SRC" "$DEST" 2>&1 | tee -a "$LOG_FILE"
        RC=${PIPESTATUS[0]}
    else
        "$RSYNC_BIN" ${ARGS[@]+"${ARGS[@]}"} "$SRC" "$DEST" >>"$LOG_FILE" 2>&1
        RC=$?
    fi
    _end=$(date +%s)
    _elapsed=$((_end - _start))

    log "--------------------------------------------------------------"

    # Both implementations are covered by one pattern:
    #   openrsync : "Number of files transferred: N"
    #   GNU rsync : "Number of regular files transferred: N"
    _xfer=$(grep -aE '^Number of (regular )?files transferred:' "$LOG_FILE" \
            | tail -1 | tr -dc '0-9')
    [ -n "$_xfer" ] || _xfer='?'
    # Total files considered, for the GUI's context line. GNU writes
    # "Number of files: 1,416 (reg: ...)"; openrsync "Number of files: 1416" --
    # cut at '(' first, or the parenthetical digits would concatenate in.
    _total=$(grep -a '^Number of files:' "$LOG_FILE" | tail -1 \
             | sed 's/(.*//' | tr -dc '0-9')

    log "finished : $(date '+%Y-%m-%d %H:%M:%S %z')  (${_elapsed}s)"
    log "files transferred: $_xfer"
    # Only a confirmed prune counts deletions; the preview output never lands
    # in the main log, so every '^*deleting' line here is a real deletion.
    _deleted=''
    if [ -n "$PRUNE_ACTIVE" ]; then
        _deleted=$(grep -c '^\*deleting' "$LOG_FILE" 2>/dev/null)
        log "entries deleted at destination: $_deleted"
    fi
    interpret_exit "$RC"

    # Same KEY=VALUE grammar as the config files, so status.sh reads it with
    # config_get rather than inventing a second parser.
    {
        echo "EPOCH=$_end"
        echo "WHEN=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "RC=$RC"
        echo "FILES=$_xfer"
        [ -n "$_total" ] && echo "TOTAL_FILES=$_total"
        echo "ELAPSED=$_elapsed"
        echo "DRY=${DRY_RUN:-0}"
        # What started this run: manual, cron or drive-connect ($_how from the
        # log header). status.sh --porcelain surfaces it as TRIGGERED.
        echo "HOW=$_how"
        echo "LOG=$LOG_FILE"
        # Written only for a real, confirmed prune -- a --sync-deletions --dry-run
        # must never yield a DELETED count that status.sh would report as fact.
        if [ -n "$PRUNE_ACTIVE" ]; then
            echo "PRUNE=1"
            echo "DELETED=$_deleted"
        fi
    } >"$LOG_DIR/last-run.txt"
    # A dry run must not be mistaken for a real backup when judging staleness.
    if [ -z "$DRY_RUN" ] && { [ "$RC" -eq 0 ] || [ "$RC" -eq 24 ]; }; then
        printf '%s\n' "$_end" >"$LOG_DIR/.last_success_epoch"
    fi

    # Support-the-author bookkeeping. Every completed non-dry run counts, any
    # RC; the earlier exits (mount gate, preflight, lock busy, prune aborts)
    # never reach this block and never count. RC is already final here and
    # nothing below may change it.
    if [ -z "$DRY_RUN" ]; then
        support_count_run
        _sup_tty=''
        [ -t 1 ] && _sup_tty=1
        # Test seam for the TTY check alone; honoured only when rsync is the
        # stub, same contract as RBS_TEST_CONFIRM_STDIN above.
        [ -n "${RBS_TEST_SUPPORT_TTY:-}" ] && [ -n "${RSYNC_BIN_OVERRIDE:-}" ] && _sup_tty=1
        # RBS_NO_SUPPORT_NAG is presentational only: the GUI shows its own
        # dialog instead, and remote.sh keeps the QR out of streamed consoles.
        # It gates nothing but this reminder.
        if [ "$_how" = manual ] && [ -n "$_sup_tty" ] \
           && [ -z "${RBS_NO_SUPPORT_NAG:-}" ] && support_nag_due; then
            support_show_nag
        fi
    fi

    rotate_logs "$LOG_DIR" 30

    release_lock
    exit "$RC"
}
