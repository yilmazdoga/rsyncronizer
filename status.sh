#!/bin/bash
#
# status.sh -- answers "is my data safe?" at a glance.
#
# Exit codes:  0 everything healthy   1 something needs attention
# It is safe to run from cron and mail the output, since it prints a compact
# report and its exit code carries the verdict.
#
# --porcelain: machine-readable output for the GUI apps. Same computations,
# same exit code; KEY=VALUE lines in the config-file grammar. A header block
# comes first; each backup's block opens with BACKUP=<name>; blocks are
# separated by one blank line. Absent key == not applicable.

set -uo pipefail

SCRIPT_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$SCRIPT_DIR
CRON_TAG_PREFIX='rsync-backup-scripts'

. "$REPO_ROOT/lib/common.sh"

PORCELAIN=''
case ${1:-} in
    '') ;;
    --porcelain) PORCELAIN=1 ;;
    *) echo "unknown argument: $1 (accepts --porcelain)" >&2; exit 64 ;;
esac

UNHEALTHY=0
NOW=$(date +%s)

# One porcelain line. Kept trivial on purpose: the value never contains a
# newline (paths, verdict strings, numbers), so no escaping is needed.
p() { printf '%s=%s\n' "$1" "$2"; }

human_age() {
    _s=$1
    if [ "$_s" -lt 3600 ]; then printf '%dm ago' "$((_s / 60))"
    elif [ "$_s" -lt 86400 ]; then printf '%dh ago' "$((_s / 3600))"
    else printf '%dd ago' "$((_s / 86400))"; fi
}

# Estimate how often a cron expression fires, so "overdue" means something.
# Coarse on purpose: the question is whether a daily job has not run in days.
schedule_period() {
    set -f; set -- $1; set +f
    [ $# -ne 5 ] && { printf '86400'; return; }
    _min=$1 _hour=$2 _dom=$3 _mon=$4 _dow=$5
    if [ "$_dow" != '*' ] || [ "$_mon" != '*' ] || [ "$_dom" != '*' ]; then
        printf '604800'                       # weekly or rarer
    elif [ "$_hour" != '*' ]; then
        case $_hour in
            *,*) printf '43200' ;;            # a few times a day
            *) printf '86400' ;;              # daily
        esac
    elif [ "$_min" != '*' ]; then
        # A step value runs many times an hour: */15 is 15 minutes, not 1 hour.
        case $_min in
            \*/*) printf '%s' "$(( ${_min#*/} * 60 ))" ;;
            *,*)  printf '1800' ;;
            *)    printf '3600' ;;             # a fixed minute == hourly
        esac
    else
        printf '60'
    fi
}

# human_period SECONDS -- for the STALE message, so it reads "15m" not "0h".
human_period() {
    if [ "$1" -lt 3600 ]; then printf '%dm' "$(( $1 / 60 ))"
    elif [ "$1" -lt 86400 ]; then printf '%dh' "$(( $1 / 3600 ))"
    else printf '%dd' "$(( $1 / 86400 ))"; fi
}

# trigger_installed NAME -- a drive-connect backup is not in the crontab on
# Linux; it is pulled in by a udev rule, and on macOS by a launchd agent.
# Without this, status.sh calls a working trigger "not scheduled".
trigger_installed() {
    if [ "$(uname -s)" = Darwin ]; then
        [ -f "$HOME/Library/LaunchAgents/local.rsync-backup-scripts.$1.plist" ]
    else
        [ -f "/etc/udev/rules.d/95-rsync-backup-$1.rules" ]
    fi
}

cron_line_for() {
    crontab -l 2>/dev/null | awk -v tag="$CRON_TAG_PREFIX:$1" '
        $0 == "# >>> " tag " >>>" { inblk = 1; next }
        $0 == "# <<< " tag " <<<" { inblk = 0; next }
        inblk == 1 && $0 !~ /^#/ { print; exit }'
}

# Does ANY backup on this machine use the cloud transport? rclone is an
# optional dependency -- a machine with only ssh and drive backups must not go
# UNHEALTHY, or show an rclone line at all, merely because it updated.
#
# This pre-pass also caches `rclone listremotes` for the whole report. status.sh
# runs from cron and must never make a NETWORK call: every cloud fact below is
# answerable from the local filesystem, and an expired OAuth token must not be
# able to hang the health report. Reachability lives in `rsyncronizer cloud
# check`, which the user asks for explicitly.
CLOUD_ANY=0
RCLONE_REMOTES_CACHE=''
if [ -d "$REPO_ROOT/config" ]; then
    for _cd in "$REPO_ROOT"/config/*/; do
        [ -d "$_cd" ] || continue
        if [ "$(config_get "$_cd/destination.txt" DEST_TYPE 2>/dev/null)" = cloud ]; then
            CLOUD_ANY=1
            break
        fi
    done
fi
CLOUD_TOOL_OK=0
if [ "$CLOUD_ANY" = 1 ] && command -v detect_rclone >/dev/null 2>&1 && detect_rclone; then
    CLOUD_TOOL_OK=1
    RCLONE_REMOTES_CACHE=$("$RCLONE_BIN" listremotes 2>/dev/null) || RCLONE_REMOTES_CACHE=''
fi

# --- header ----------------------------------------------------------------
if [ -n "$PORCELAIN" ]; then
    p NOW "$(date '+%Y-%m-%d %H:%M:%S %z')"
    p HOSTNAME "$(hostname 2>/dev/null || echo unknown)"
    if detect_rsync; then
        p RSYNC_BIN "$RSYNC_BIN"
        p RSYNC_FLAVOUR "$RSYNC_FLAVOUR"
    else
        p RSYNC_BIN ''
        UNHEALTHY=1
    fi
    # Support-the-author state. Header keys; parse_porcelain in the GUI
    # tolerates unknown keys, and old engines simply omit these.
    p CLOUD_CONFIGURED "$CLOUD_ANY"
    if [ "$CLOUD_ANY" = 1 ]; then
        if [ "$CLOUD_TOOL_OK" = 1 ]; then
            p RCLONE_BIN "$RCLONE_BIN"
            p RCLONE_VERSION "$RCLONE_VERSION"
        else
            p RCLONE_BIN ''
            UNHEALTHY=1
        fi
    fi
    if _support_supported; then p SUPPORTED yes; else p SUPPORTED ''; fi
    p SUPPORT_RUNS "$(_support_num RUN_COUNT 0)"
    printf '\n'
else
    printf '\n'
    printf '  rsync backups on %s\n' "$(hostname 2>/dev/null || echo this machine)"
    printf '  %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    if detect_rsync; then
        printf '  rsync: %s (%s)\n' "$RSYNC_BIN" "$RSYNC_FLAVOUR"
    else
        printf '  rsync: NOT FOUND\n'
        UNHEALTHY=1
    fi
    if [ "$CLOUD_ANY" = 1 ]; then
        if [ "$CLOUD_TOOL_OK" = 1 ]; then
            printf '  rclone: %s (%s)\n' "$RCLONE_BIN" "$RCLONE_VERSION"
        else
            printf '  rclone: NOT FOUND -- cloud backups on this machine cannot run\n'
            UNHEALTHY=1
        fi
    fi
fi

# Count config DIRECTORIES, not entries: config/ also holds the user's
# global-exclude.txt, which must not suppress the "no backups yet" hint.
if [ ! -d "$REPO_ROOT/config" ] || [ -z "$(ls -d "$REPO_ROOT"/config/*/ 2>/dev/null)" ]; then
    if [ -z "$PORCELAIN" ]; then
        printf '\n  No backups are configured on this machine yet.\n'
        printf '  Run ./setup.sh to create one.\n\n'
    fi
    exit 0
fi

for _dir in "$REPO_ROOT"/config/*/; do
    [ -d "$_dir" ] || continue
    _name=$(basename "$_dir")
    _log_dir=$REPO_ROOT/logs/$_name

    if [ -z "$PORCELAIN" ]; then
        printf '\n--------------------------------------------------------------\n'
        printf '  %s\n' "$_name"
    else
        p BACKUP "$_name"
    fi

    _raw_src=$(config_first_line "$_dir/source.txt" 2>/dev/null) || _raw_src=''
    if [ -n "$_raw_src" ]; then
        _src=$(resolve_path "$_raw_src")
    else
        _src=''
    fi
    _u=$(config_get "$_dir/destination.txt" USER 2>/dev/null)
    _h=$(config_get "$_dir/destination.txt" HOST 2>/dev/null)
    _p=$(config_get "$_dir/destination.txt" DEST_PATH 2>/dev/null)
    _dt=$(config_get "$_dir/destination.txt" DEST_TYPE 2>/dev/null)
    _vol=$(config_get "$_dir/destination.txt" VOLUME_ROOT 2>/dev/null)
    _rr=$(config_get "$_dir/destination.txt" RCLONE_REMOTE 2>/dev/null)
    _cp=$(config_get "$_dir/destination.txt" CLOUD_PROVIDER 2>/dev/null)
    [ -n "$_dt" ] || _dt=ssh
    # A local destination is a plain path: building "host:path" for it produced
    # a stray leading colon. A cloud one is rclone's own remote:path syntax,
    # which is deliberate -- it is paste-able into an `rclone ls` command.
    if [ "$_dt" = local ]; then
        _remote=''
        _dest_disp=$_p
    elif [ "$_dt" = cloud ]; then
        _remote=''
        _dest_disp="$_rr:$_p"
    else
        if [ -n "$_u" ]; then _remote="$_u@$_h"; else _remote="$_h"; fi
        _dest_disp="$_remote:$_p"
    fi

    # Is the remote this backup names still defined here? The commonest cloud
    # failure after a reinstall or a move to a new machine, and answerable
    # without touching the network.
    _rdef=''
    if [ "$_dt" = cloud ]; then
        _rdef=0
        if [ -n "$RCLONE_REMOTES_CACHE" ] \
           && printf '%s\n' "$RCLONE_REMOTES_CACHE" | grep -xF -- "$_rr:" >/dev/null 2>&1; then
            _rdef=1
        fi
        [ "$_rdef" = 1 ] || UNHEALTHY=1
    fi

    _src_missing=0
    [ -n "$_src" ] && [ ! -d "$_src" ] && { _src_missing=1; UNHEALTHY=1; }

    # For a removable drive, whether it is plugged in right now is the single
    # most useful fact on the line.
    _drive=''
    if [ "$_dt" = local ] && [ -n "$_vol" ]; then
        if volume_mounted "$_vol" && volume_is_ours "$_vol"; then
            _drive=connected
        elif volume_mounted "$_vol"; then
            _drive=unmarked
        else
            _drive=absent
        fi
    fi

    if [ -z "$PORCELAIN" ]; then
        printf '    source   : %s\n' "${_src:-<unset>}"
        [ "$_src_missing" = 1 ] && printf '               ^ MISSING\n'
        printf '    dest     : %s\n' "$_dest_disp"
        [ -n "$_src" ] && printf '    lands as : %s/%s/\n' "$_dest_disp" "${_src##*/}"
        case $_drive in
            connected) printf '    drive    : connected (%s)\n' "$_vol" ;;
            unmarked)  printf '    drive    : mounted but unmarked (%s)\n' "$_vol" ;;
            absent)    printf '    drive    : not connected (%s)\n' "$_vol" ;;
        esac
        if [ "$_dt" = cloud ]; then
            printf '    cloud    : %s (%s)\n' "$_rr" "${_cp:-unspecified}"
            if [ "$CLOUD_TOOL_OK" != 1 ]; then
                printf '    !! rclone is not installed -- this backup cannot run\n'
            elif [ "$_rdef" != 1 ]; then
                printf '    !! the rclone remote %s: is not configured here -- run: rclone config\n' "$_rr"
            fi
        fi
    else
        p SRC "$_src"
        p SRC_MISSING "$_src_missing"
        p DEST "$_dest_disp"
        p DEST_TYPE "$_dt"
        [ -n "$_drive" ] && p DRIVE "$_drive"
        if [ "$_dt" = cloud ]; then
            p RCLONE_REMOTE "$_rr"
            p CLOUD_PROVIDER "$_cp"
            p REMOTE_DEFINED "$_rdef"
        fi
    fi

    # --- schedule ---------------------------------------------------------
    _cron=$(cron_line_for "$_name")
    _trigger=0
    if [ -n "$_cron" ]; then
        set -f; set -- $_cron; set +f
        _sched="$1 $2 $3 $4 $5"
        _period=$(schedule_period "$_sched")
    elif [ "$_dt" = local ] && trigger_installed "$_name"; then
        _sched='' ; _trigger=1 ; _period=''
    else
        _sched='' ; _period=''
    fi

    # A runner that a cron line points at but which no longer exists is a
    # backup that silently stopped happening.
    _runner_missing=0
    if [ -n "$_cron" ] && [ ! -x "$REPO_ROOT/backups/$_name.sh" ]; then
        _runner_missing=1
        UNHEALTHY=1
    fi

    if [ -z "$PORCELAIN" ]; then
        if [ -n "$_cron" ]; then
            printf '    schedule : %s\n' "$_sched"
        elif [ "$_trigger" = 1 ]; then
            printf '    schedule : on drive connect (trigger installed)\n'
        else
            printf '    schedule : not scheduled (manual runs only)\n'
        fi
        [ "$_runner_missing" = 1 ] \
            && printf '    !! the cron entry points at backups/%s.sh, which is missing\n' "$_name"
    else
        p SCHEDULE "$_sched"
        p TRIGGER "$_trigger"
        p RUNNER_MISSING "$_runner_missing"
    fi

    # --- last run ---------------------------------------------------------
    if [ ! -f "$_log_dir/last-run.txt" ]; then
        _never_alert=0
        [ -n "$_cron" ] && { _never_alert=1; UNHEALTHY=1; }
        if [ -z "$PORCELAIN" ]; then
            printf '    last run : never\n'
            [ "$_never_alert" = 1 ] && printf '    !! scheduled but has never run\n'
        else
            p NEVER_RAN 1
            printf '\n'
        fi
        continue
    fi

    _when=$(config_get "$_log_dir/last-run.txt" WHEN)
    _rc=$(config_get "$_log_dir/last-run.txt" RC)
    _files=$(config_get "$_log_dir/last-run.txt" FILES)
    _total=$(config_get "$_log_dir/last-run.txt" TOTAL_FILES)
    _elapsed=$(config_get "$_log_dir/last-run.txt" ELAPSED)
    _dry=$(config_get "$_log_dir/last-run.txt" DRY)
    _epoch=$(config_get "$_log_dir/last-run.txt" EPOCH)
    _log=$(config_get "$_log_dir/last-run.txt" LOG)
    # Written only by a real, confirmed --sync-deletions run; absent otherwise.
    _prune=$(config_get "$_log_dir/last-run.txt" PRUNE)
    _pruned=$(config_get "$_log_dir/last-run.txt" DELETED)
    # manual | cron | drive-connect; absent on runs recorded by older versions.
    _how=$(config_get "$_log_dir/last-run.txt" HOW)

    _age=''
    case $_epoch in
        ''|*[!0-9]*) ;;
        *) _age=$((NOW - _epoch)) ;;
    esac

    # WHICH table this code belongs to. rclone's exit codes collide with
    # rsync's -- rclone 4 is "file not found" where rsync 4 is "unsupported
    # action", rclone 5 is a TEMPORARY error where rsync 5 is a protocol
    # failure -- so reading one against the other would report confident
    # nonsense. The engine records TRANSPORT= only for rclone, so an absent
    # key (every last-run.txt written before 0.3.0) reads as rsync.
    _tp=$(config_get "$_log_dir/last-run.txt" TRANSPORT)
    [ -n "$_tp" ] || _tp=rsync

    # The engine's own codes come first: they mean the same thing on both
    # transports, and neither rsync's table nor rclone's uses these numbers.
    case $_rc in
        66) _verdict="REFUSED -- source empty or unreadable (check Full Disk Access)" ;;
        69) _verdict="UNAVAILABLE -- the destination or a required tool is not usable here" ;;
        78) _verdict="MISCONFIGURED -- see the log" ;;
        *)
            if [ "$_tp" = rclone ]; then
                case $_rc in
                    0)  _verdict="SUCCESS" ;;
                    2)  _verdict="FAILED -- rclone usage error, check RCLONE_EXTRA_FLAGS" ;;
                    3|4) _verdict="FAILED -- a path was not found at the remote" ;;
                    5)  _verdict="RETRYABLE -- a temporary error at the provider; nothing was deleted" ;;
                    6)  _verdict="PARTIAL -- some files could not be transferred" ;;
                    7)  _verdict="AUTH FAILURE -- re-authorise (rsyncronizer cloud login)" ;;
                    8|10) _verdict="PARTIAL -- a transfer limit was reached; re-run to continue" ;;
                    *)  _verdict="FAILED ($_rc)" ;;
                esac
            else
                case $_rc in
                    0)  _verdict="SUCCESS" ;;
                    24) _verdict="SUCCESS (source files vanished mid-run, benign)" ;;
                    23) _verdict="PARTIAL -- some files could not be transferred" ;;
                    12|255) _verdict="SSH FAILURE -- destination unreachable" ;;
                    30|35) _verdict="TIMEOUT -- connection stalled" ;;
                    *)  _verdict="FAILED ($_rc)" ;;
                esac
            fi ;;
    esac
    case $_rc in
        0|24) ;;
        *) UNHEALTHY=1 ;;
    esac

    # --- staleness --------------------------------------------------------
    # macOS cron does not catch up missed runs: a job scheduled for 02:00 on a
    # closed laptop never fires and leaves no log at all. A missing run is
    # invisible unless something explicitly looks for it -- this is that thing.
    _stale=0
    _waiting=0
    _ok_age=''
    if [ -n "$_period" ] && [ -f "$_log_dir/.last_success_epoch" ]; then
        _ok_epoch=$(cat "$_log_dir/.last_success_epoch" 2>/dev/null) || _ok_epoch=''
        case $_ok_epoch in
            ''|*[!0-9]*) ;;
            *)
                _ok_age=$((NOW - _ok_epoch))
                if [ "$_ok_age" -gt $((_period * 2)) ]; then
                    # A drive-connect backup cannot run while the drive is
                    # elsewhere. Calling that STALE is a false alarm, and a
                    # warning that cries wolf gets ignored when it matters.
                    if [ "$_dt" = local ] && [ -n "$_vol" ] && ! volume_mounted "$_vol"; then
                        _waiting=1
                    else
                        _stale=1
                        UNHEALTHY=1
                    fi
                fi
                ;;
        esac
    elif [ -n "$_period" ]; then
        _stale=2            # scheduled, but no successful run recorded at all
        UNHEALTHY=1
    fi

    _bootstrap=0
    [ -s "$_log_dir/cron-bootstrap.log" ] && { _bootstrap=1; UNHEALTHY=1; }

    if [ -z "$PORCELAIN" ]; then
        printf '    last run : %s' "$_when"
        [ -n "$_age" ] && printf '  (%s)' "$(human_age "$_age")"
        [ "$_dry" = 1 ] && printf '  [DRY RUN]'
        [ "$_prune" = 1 ] && printf '  [PRUNE]'
        printf '\n'
        printf '    result   : %s\n' "$_verdict"
        printf '    files    : %s transferred in %ss\n' "$_files" "$_elapsed"
        if [ "$_prune" = 1 ] && [ -n "$_pruned" ]; then
            printf '    pruned   : %s entries deleted at destination\n' "$_pruned"
        fi
        if [ "$_waiting" = 1 ]; then
            printf '    waiting  : drive not connected; last successful run %s\n' "$(human_age "$_ok_age")"
        elif [ "$_stale" = 1 ]; then
            printf '    !! STALE: last SUCCESSFUL run was %s, but this runs\n' "$(human_age "$_ok_age")"
            printf '       every %s. Scheduled runs are not happening.\n' "$(human_period "$_period")"
        elif [ "$_stale" = 2 ]; then
            printf '    !! scheduled, but no successful run has been recorded\n'
        fi
        [ -n "$_log" ] && printf '    log      : %s\n' "$_log"
        # Anything in the bootstrap log is by construction real signal: a
        # healthy cron run writes nothing to it.
        if [ "$_bootstrap" = 1 ]; then
            printf '    !! cron-bootstrap.log is not empty -- something failed before logging:\n'
            sed 's/^/       /' "$_log_dir/cron-bootstrap.log" | tail -5
        fi
    else
        p NEVER_RAN 0
        p LAST_WHEN "$_when"
        p LAST_EPOCH "$_epoch"
        p RC "$_rc"
        # Which table RC was read against, so a consumer cannot re-interpret it
        # with the wrong one.
        p TRANSPORT "$_tp"
        p VERDICT "$_verdict"
        p FILES "$_files"
        [ -n "$_total" ] && p TOTAL_FILES "$_total"
        p ELAPSED "$_elapsed"
        p DRY "${_dry:-0}"
        [ -n "$_how" ] && p TRIGGERED "$_how"
        [ "$_prune" = 1 ] && p PRUNE 1
        [ -n "$_pruned" ] && p DELETED "$_pruned"
        p STALE "$_stale"
        p WAITING "$_waiting"
        p BOOTSTRAP_ALERT "$_bootstrap"
        p LOG "$_log"
        printf '\n'
    fi
done

if [ -z "$PORCELAIN" ]; then
    printf '\n--------------------------------------------------------------\n'
    if [ "$UNHEALTHY" = 0 ]; then
        printf '  All configured backups look healthy.\n\n'
    else
        printf '  Something needs attention (see !! above).\n\n'
    fi
    # One warm line, no QR: status output gets piped and mailed.
    if ! _support_supported; then
        printf '  Rsyncronizer is completely free and will be so forever.\n'
        printf '  If you find it useful: %s\n\n' "$SUPPORT_URL"
    fi
fi
exit "$UNHEALTHY"
