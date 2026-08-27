# shellcheck shell=bash
#
# lib/cloud.sh -- the rclone transport: S3, Google Drive, OneDrive, Dropbox.
#
# rsync cannot reach any of those services, so this is a SECOND TRANSPORT
# rather than another kind of rsync destination. Everything rclone-specific
# lives here; lib/common.sh sources it softly (see the bottom of that file) so
# a partially-updated engine home still runs every rsync backup normally.
#
# Same house rules as lib/common.sh: bash 3.2 only (no associative arrays, no
# mapfile, no ${var,,}), always ${arr[@]+"${arr[@]}"}, and never
# `big-producer | grep -q` under pipefail.
#
# THE SAFETY MODEL, in one paragraph. A scheduled or plain cloud run is
# `rclone copy`, which has no code path that deletes at the destination -- the
# structural equivalent of rsync without --delete. `rclone sync` is the only
# verb that deletes, it is produced at exactly ONE site in this file, and that
# site is guarded by assert_prune_sanctioned. Two things protect that: the
# flag blacklist below, and -- because rclone reads an RCLONE_* environment
# variable for EVERY flag it has -- the environment scrub. A blacklist alone
# would be decorative: RCLONE_IGNORE_ERRORS=true in the environment reaches
# the same switch as --ignore-errors on the command line.

# The floor. --filter-from, lsf --format and --stats-log-level all predate it,
# but 1.55 is where --dropbox-batch-mode arrives, and it is old enough (2021)
# that every packaged rclone in circulation clears it.
RBS_RCLONE_MIN='1.55.0'

RCLONE_BIN=''
RCLONE_VERSION=''

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

# _rclone_ver_field VERSION INDEX -- one numeric field of a version string.
# Normalises 'v1.75.0', '1.75' and '1.69.0-beta.1234.abcdef' alike: strip a
# leading v, drop any pre-release suffix, then pad so a two-field version has
# a third field of 0 rather than repeating its second.
_rclone_ver_field() {
    _vf=${1#v}
    _vf=${_vf%%-*}
    _vf=${_vf%%+*}
    _vf="$_vf.0.0"
    case $2 in
        1) _vf=${_vf%%.*} ;;
        2) _vf=${_vf#*.}; _vf=${_vf%%.*} ;;
        *) _vf=${_vf#*.}; _vf=${_vf#*.}; _vf=${_vf%%.*} ;;
    esac
    case $_vf in ''|*[!0-9]*) _vf=0 ;; esac
    printf '%s' "$_vf"
}

# _rclone_version_ge HAVE WANT -- true when HAVE >= WANT.
_rclone_version_ge() {
    for _vi in 1 2 3; do
        _vh=$(_rclone_ver_field "$1" "$_vi")
        _vw=$(_rclone_ver_field "$2" "$_vi")
        [ "$_vh" -gt "$_vw" ] && return 0
        [ "$_vh" -lt "$_vw" ] && return 1
    done
    return 0
}

# detect_rclone -- mirrors detect_rsync, including its test seam.
#
# The BUNDLED copy wins on purpose. The desktop apps ship rclone and
# materialize it into the engine home as bin/rclone, and a self-contained app
# should run the version it was built and tested against rather than whatever
# the machine happens to have. CLI and from-source installs have no bin/rclone
# and fall through to the system one.
detect_rclone() {
    # Deliberately NOT named RBS_*: it mirrors RSYNC_BIN_OVERRIDE, which is the
    # established seam name in this project. That does mean it matches RCLONE_*
    # and would be removed by the environment scrub, so the scrub exempts it by
    # name -- see _rclone_scrub_env.
    RCLONE_BIN=''
    if [ -n "${RCLONE_BIN_OVERRIDE:-}" ]; then
        # Unlike detect_rsync's seam this still probes `version`: the version
        # floor in run_backup is a real code path and the suite has to be able
        # to fail it, which means the stub has to be able to answer.
        RCLONE_BIN=$RCLONE_BIN_OVERRIDE
    fi
    [ -n "$RCLONE_BIN" ] || for _rc in "${REPO_ROOT:-}/bin/rclone" /opt/homebrew/bin/rclone /usr/local/bin/rclone; do
        if [ -x "$_rc" ]; then
            RCLONE_BIN=$_rc
            break
        fi
    done
    if [ -z "$RCLONE_BIN" ]; then
        RCLONE_BIN=$(command -v rclone 2>/dev/null) || RCLONE_BIN=''
    fi
    [ -n "$RCLONE_BIN" ] || return 1
    # Captured first, then matched -- `... | grep` inside an `if` is the
    # pipefail+SIGPIPE trap documented at the top of lib/common.sh.
    _rcv=$("$RCLONE_BIN" version 2>/dev/null | head -1)
    RCLONE_VERSION=$(printf '%s' "$_rcv" | sed -n 's/^rclone *v\{0,1\}\([0-9][0-9.]*.*\)$/\1/p')
    [ -n "$RCLONE_VERSION" ] || RCLONE_VERSION=unknown
    return 0
}

# rclone_install_hint -- one place for the install instructions, printed by the
# engine, the CLI and (through lib/cloud.sh hint) the desktop app.
rclone_install_hint() {
    if [ "$(uname -s)" = Darwin ]; then
        printf '%s\n' 'Install rclone:  brew install rclone'
        printf '%s\n' '(or download it from https://rclone.org/downloads/ and put it on your PATH)'
    else
        printf '%s\n' 'Install rclone:  sudo apt install rclone     (Debian/Ubuntu)'
        printf '%s\n' '                 sudo dnf install rclone     (Fedora)'
        printf '%s\n' '                 sudo pacman -S rclone       (Arch)'
        printf '%s\n' 'Distribution packages are often old; for the newest version:'
        printf '%s\n' '                 curl https://rclone.org/install.sh | sudo bash'
    fi
}

# ---------------------------------------------------------------------------
# The environment scrub.
#
# This is half of the never-delete guarantee, not a tidiness measure. rclone
# derives an environment variable name for every flag it has (strip --, s/-/_/,
# upper-case, prepend RCLONE_), and RCLONE_CONFIG_<REMOTE>_<KEY> can redefine
# the destination outright. So:
#
#   RCLONE_IGNORE_ERRORS=true       reaches the same switch as --ignore-errors
#   RCLONE_CONFIG_GDRIVE_TYPE=local turns a cloud remote into a local path
#   RCLONE_PASSWORD_COMMAND='...'   runs an arbitrary shell command at startup
#
# none of which the argv blacklist can see. Everything RCLONE_* is therefore
# removed before exec and named in the log, so a run whose behaviour was about
# to be altered from outside says so.
# ---------------------------------------------------------------------------
_rclone_scrub_env() {
    _sc_names=$(env 2>/dev/null | sed -n 's/^\(RCLONE_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u)
    _sc_hit=''
    for _sc_v in $_sc_names; do
        # The test seam is ours, not rclone's, and unsetting it here would
        # disarm the stub in the middle of the suite that verifies this scrub.
        [ "$_sc_v" = RCLONE_BIN_OVERRIDE ] && continue
        unset "$_sc_v" 2>/dev/null || true
        _sc_hit="$_sc_hit $_sc_v"
    done
    if [ -n "$_sc_hit" ]; then
        log "env      : ignored inherited rclone settings:$_sc_hit"
        log "           (rclone reads one env var per flag; the destination and the"
        log "            deletion switches must come from this repo's config only)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Path and remote validation
# ---------------------------------------------------------------------------

# _cloud_path_norm PATH -- normalise a path INSIDE an rclone remote.
#
# resolve_path() must never be used here: it prefixes $HOME to anything that is
# not absolute, and 'Backups/laptop' is exactly that shape. Silently backing up
# to /Users/you/Backups/laptop instead of the cloud is the failure this rules
# out.
_cloud_path_norm() {
    _cp=$1
    while [ "${_cp%/}" != "$_cp" ]; do _cp=${_cp%/}; done
    printf '%s' "$_cp"
}

# ---------------------------------------------------------------------------
# The rclone destructive-flag guard.
#
# A peer of assert_no_destructive_flags(), never a weaker cousin. It runs on
# the FULLY ASSEMBLED argv -- verb included -- immediately before exec, with
# SRC and DEST appended afterwards, exactly like the rsync guard.
#
# Two rules the rsync guard does not need:
#
#   * The VERB is checked here. ARGS[0] must be copy, sync or check, and sync
#     and check re-assert the prune sanction on the spot. A bug elsewhere that
#     reached exec with ARGS[0]=sync and no typed confirmation dies here.
#   * Every other token must start with '-'. rclone takes its source and
#     destination as positional arguments, so a bare word smuggled through
#     RCLONE_EXTRA_FLAGS would become a third path. This also forces the
#     --flag=value form throughout, which is what makes judging '--flag=VALUE'
#     as '--flag' safe.
#
# There is deliberately NO abbreviation arm here, unlike the rsync guard.
# rsync's getopt_long resolves any unambiguous prefix, so '--forc' really does
# reach --force and an exact-match blacklist would fail open. Go's pflag
# resolves nothing: '--delet' is simply an unknown flag and rclone exits 2. So
# the arm would catch no real bypass -- and rclone's flag namespace is full of
# shared prefixes, where it fires on legitimate flags instead. Measured: an
# earlier deletion-preview passed '--error=FILE', which is a prefix of the
# blacklisted '--error-on-no-transfer', and the arm refused every prune.
#
# The '<blacklisted>-*' arm below is the one that earns its keep: it catches
# any --delete-… or --rc-… flag rclone grows in the future.
# ---------------------------------------------------------------------------
# By category:
#   deletion at dest  --delete* --max-delete* --ignore-errors (for sync that
#                     means "delete even though the listing failed", which is
#                     the one thing --delete-after exists to prevent)
#   source mutation   --delete-empty-src-dirs   (rclone's --remove-source-files)
#   moves data around --backup-dir --suffix* --track-renames
#   in-place          --inplace
#   selection         --files-from* (overrides every filter layer)
#                     --include* (rclone appends an implicit '- **' after any
#                     include, turning the exclude list into an allow-list)
#                     --max-age --min-age --max-size --min-size (with sync
#                     these DELETE what they exclude)
#   removes the net   --drive-use-trash=false makes Drive deletions permanent
#   credential leak   --dump* writes HTTP auth headers -- OAuth bearer tokens
#                     and AWS signatures -- into a log kept for 30 runs
#   remote control    --rc* opens a local HTTP API that can drive sync/purge
#                     with this process's cloud credentials
#   code execution    --password-command runs a shell command at startup
#   ours to choose    --config --log-file
#   not a backup      --links stores .rclonelink text files instead of data
#   hangs cron        --interactive prompts before every operation
#   false failure     --error-on-no-transfer turns "nothing changed" into exit 9
_RBS_RCLONE_DANGEROUS='
--delete --delete-before --delete-during --delete-after --delete-excluded
--delete-empty-src-dirs --max-delete --max-delete-size
--backup-dir --suffix --suffix-keep-extension --track-renames
--ignore-errors --inplace
--files-from --files-from-raw --files-from0
--include --include-from
--max-age --min-age --max-size --min-size
--drive-use-trash
--dump --password-command --rc
--config --log-file --links --interactive --error-on-no-transfer
'

assert_no_destructive_rclone_flags() {
    _rg_first=1
    for _a in "$@"; do
        if [ "$_rg_first" = 1 ]; then
            _rg_first=0
            case $_a in
                copy) ;;
                # The ONLY two places a deleting or scanning verb is legal, and
                # both re-prove the sanction rather than trusting the caller.
                sync)  assert_prune_sanctioned real ;;
                lsf)   assert_prune_sanctioned preview ;;
                *) die 78 "refusing to run: '$_a' is not an rclone subcommand this tool issues (expected copy)" ;;
            esac
            continue
        fi
        # rclone takes paths positionally; a bare word here would become one.
        case $_a in
            -*) ;;
            *) die 78 "refusing to run: '$_a' is not a flag (rclone flags start with '-'; use --flag=value, never --flag value)" ;;
        esac
        # Judge --flag=VALUE as --flag.
        case $_a in
            --*=*) _t=${_a%%=*} ;;
            *)     _t=$_a ;;
        esac
        case $_t in
            --*)
                for _d in $_RBS_RCLONE_DANGEROUS; do
                    case $_t in
                        "$_d")
                            die 78 "refusing to run: unsafe rclone flag '$_a' (this tool never deletes or overwrites in place)"
                            ;;
                        "$_d"-*)
                            die 78 "refusing to run: '$_a' is a variant of the unsafe rclone flag '$_d'"
                            ;;
                    esac
                done
                ;;
        esac
        # Bundled short options. -l is --links, -P is --progress (which the
        # desktop app's line-oriented pty reader cannot consume: it redraws
        # with \r and arrives as one unbounded line), -i is --interactive,
        # which would sit at a prompt forever under cron.
        case $_a in
            --*) ;;
            -*)
                case $_a in
                    *l*|*P*|*i*)
                        die 78 "refusing to run: unsafe short option bundled in '$_a'"
                        ;;
                esac
                ;;
        esac
    done
    return 0
}

# _rclone_validate_extra TOKEN... -- checks applied to RCLONE_EXTRA_FLAGS only.
#
# --dry-run is legal for the engine (that is what --dry-run on a runner does)
# but must never come from config: a scheduled backup whose options.txt quietly
# says --dry-run reports success forever while transferring nothing.
_rclone_validate_extra() {
    for _xe in "$@"; do
        case $_xe in
            --dry-run|--dry-run=*|-n)
                die 78 "RCLONE_EXTRA_FLAGS may not contain --dry-run: a scheduled backup would report success while transferring nothing. Use: ./backups/<name>.sh --dry-run"
                ;;
            -*) ;;
            *) die 78 "RCLONE_EXTRA_FLAGS may only contain flags; got the bare word '$_xe'. Values attach with '=', e.g. --transfers=4" ;;
        esac
        case $_xe in
            --*) ;;
            -*) case $_xe in *n*) die 78 "RCLONE_EXTRA_FLAGS may not contain -n (--dry-run); use ./backups/<name>.sh --dry-run" ;; esac ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# Filter translation.
#
# rclone filters are NOT rsync filters, and forwarding this repo's rule files
# unchanged would silently back up every node_modules on the machine. From
# rclone's own documentation: "Rclone commands are applied to path/file names
# not directories" -- a bare pattern matches only the LAST path element, so
#
#   - build          excludes a FILE named build, but not build/foo.o
#   - node_modules/  is only a recursion-optimisation hint, whose applicability
#                    depends on the backend's ListR support and --fast-list
#
# The documented reliable form is 'dir/**'. So every rule is emitted more than
# once, preserving rsync's semantics exactly:
#
#   - build/     ->  - build/**      - build/          (directory only, so a
#                                                        FILE named build is
#                                                        still backed up)
#   - .DS_Store  ->  - .DS_Store     - .DS_Store/      - .DS_Store/**
#
# --filter-from, not --exclude-from: only the former honours the '- ' rule
# prefix these files already use, and that prefix is what keeps Synology's
# '#recycle' from being read as a comment (rclone treats a leading # or ; as
# one, exactly as rsync does).
# ---------------------------------------------------------------------------
_rclone_filter_write() {
    printf '%s\n' "# ---- from $1"
    while IFS= read -r _fl || [ -n "$_fl" ]; do
        case $_fl in
            ''|'#'*|';'*) continue ;;
        esac
        case $_fl in
            '- '*) _fp=${_fl#- } ;;
            # A '+ ' include passes through verbatim: rclone's filter files use
            # the same two prefixes, and re-including something is never a
            # deletion risk.
            '+ '*) printf '%s\n' "$_fl"; continue ;;
            *)     _fp=$_fl ;;
        esac
        _fp=$(trim "$_fp")
        [ -n "$_fp" ] || continue
        case $_fp in
            */)
                printf '%s\n' "- $_fp**"
                printf '%s\n' "- $_fp"
                ;;
            *)
                printf '%s\n' "- $_fp"
                printf '%s\n' "- $_fp/"
                printf '%s\n' "- $_fp/**"
                ;;
        esac
    done <"$1"
}

# _rclone_build_filter OUTFILE GLOBALFILE [PERBACKUPFILE] -- regenerate the
# translated filter file. Regenerated every run because the sources are
# user-editable; a dotfile in the log directory so it stays outside the
# [0-9]*.log rotation ring, and in the log directory rather than the cache so
# the user can actually read what was excluded.
_rclone_build_filter() {
    _bf_out=$1
    shift
    {
        printf '%s\n' '# Generated per run by lib/cloud.sh -- do not edit, it is overwritten.'
        printf '%s\n' '# rclone filter syntax, translated from this repo. Each source rule'
        printf '%s\n' '# becomes several here; see the comment in lib/cloud.sh for why.'
        for _bf_in in "$@"; do
            [ -f "$_bf_in" ] || continue
            _rclone_filter_write "$_bf_in"
        done
    } >"$_bf_out" || die 74 "cannot write the rclone filter file: $_bf_out"
    # A filter file with no rules means the exclude layer silently vanished.
    grep -q '^[-+] ' "$_bf_out" 2>/dev/null \
        || die 78 "the exclude list produced no rclone filter rules -- check config/global-exclude.txt"
    return 0
}

# ---------------------------------------------------------------------------
# Exit codes.
#
# rclone's table is its own (0-10) and COLLIDES with rsync's: rclone 4 is
# "file not found" where rsync 4 is "unsupported action", and rclone 5 is a
# TEMPORARY error where rsync 5 is a protocol failure. last-run.txt therefore
# records TRANSPORT= and both this and status.sh branch on it. Nothing here
# overlaps the engine's own codes (64/66/69/74/75/78/143), so rclone's code is
# passed through honestly rather than remapped.
# ---------------------------------------------------------------------------
_rclone_interpret_exit() {
    case $1 in
        0)  log "RESULT: SUCCESS (0)" ;;
        1)  log "RESULT: FAILED (1) -- rclone reported an error it could not categorise."
            log "        Search this log for 'ERROR' lines." ;;
        2)  log "RESULT: FAILED (2) -- rclone usage error. Suspect RCLONE_EXTRA_FLAGS in options.txt." ;;
        3)  log "RESULT: FAILED (3) -- a directory was not found."
            log "        Check DEST_PATH in destination.txt actually exists at the remote:"
            log "          rclone lsd ${RCLONE_REMOTE:-<remote>}:" ;;
        4)  log "RESULT: FAILED (4) -- a file was not found." ;;
        5)  log "RESULT: RETRYABLE (5) -- a temporary error at the provider; nothing was deleted."
            log "        Re-running resumes where this left off." ;;
        6)  log "RESULT: PARTIAL (6) -- some files could not be transferred."
            log "        Search this log for 'ERROR' lines to see which, and why."
            case ${CLOUD_PROVIDER:-} in
                onedrive) log "        OneDrive rejects paths over 400 characters and files over 250 GiB." ;;
                dropbox)  log "        Dropbox refuses some filenames outright (thumbs.db and friends)." ;;
            esac ;;
        7)  log "RESULT: AUTH FAILURE (7) -- the account is suspended, or its sign-in has expired."
            log "        Re-authorise:  rclone config reconnect ${RCLONE_REMOTE:-<remote>}:"
            log "        (or: rsyncronizer cloud login ${RCLONE_REMOTE:-<remote>})"
            case ${CLOUD_PROVIDER:-} in
                onedrive) log "        OneDrive sign-ins expire after 90 days without use." ;;
            esac ;;
        8)  log "RESULT: PARTIAL (8) -- a transfer limit was reached; the rest was not uploaded."
            log "        Re-run to continue."
            case ${CLOUD_PROVIDER:-} in
                drive) log "        Google Drive caps uploads at 750 GB per day. Re-run tomorrow." ;;
            esac ;;
        9)  log "RESULT: FAILED (9) -- rclone reports no files transferred (--error-on-no-transfer)."
            log "        This engine never passes that flag; something re-added it." ;;
        10) log "RESULT: PARTIAL (10) -- the run hit --max-duration. Re-run to continue." ;;
        *)  log "RESULT: FAILED ($1)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Argument assembly.
#
# Split into a shared middle plus a verb-specific head and tail, because
# `check` and `copy` do NOT accept the same flags: --create-empty-src-dirs is
# registered on copy/sync only and would be a usage error (exit 2) on check.
# What they MUST share is the filter set -- otherwise the deletion list would
# be computed against a different file set than the one that gets transferred.
# tests/run-tests.sh asserts --filter-from appears in all three calls of a
# confirmed prune for exactly that reason.
#
# --fast-list is deliberately absent: rclone disables directory-recursion
# pruning when it is set, and the translated filter leans on directory rules.
# ---------------------------------------------------------------------------
_rclone_common_args() {
    RCARGS=( --transfers="${RCLONE_TRANSFERS:-4}" --checkers="${RCLONE_CHECKERS:-8}" )
    RCARGS+=( --timeout="${TIMEOUT}s" --contimeout=60s )
    RCARGS+=( --retries=3 --low-level-retries=10 )
    # Stats are logged at INFO, which is BELOW rclone's default NOTICE level --
    # without this the summary never reaches the log and the file counts below
    # would be '?' forever.
    RCARGS+=( --stats=5m --stats-log-level=NOTICE -v )
    # rclone colourises when stdout is a terminal, and the [ -t 1 ] branch in
    # run_backup tees that straight into the log file.
    RCARGS+=( --color=NEVER )
    # The cron-equivalent posture: an encrypted rclone.conf must fail fast
    # rather than block forever at a password prompt while holding the lock.
    RCARGS+=( --ask-password=false )
    RCARGS+=( --filter-from="$1" )
    [ -n "$BWLIMIT" ] && RCARGS+=( --bwlimit="${BWLIMIT}K" )
    case ${CLOUD_PROVIDER:-} in
        drive)
            # Drive's undocumented 750 GB/day cap otherwise produces thousands
            # of individual errors instead of one clean stop.
            RCARGS+=( --drive-stop-on-upload-limit ) ;;
        dropbox)
            # Without batching, Dropbox answers too_many_requests and rclone
            # sits out 15-300s at a time.
            RCARGS+=( --dropbox-batch-mode=sync ) ;;
    esac
    return 0
}

# _rclone_transfer_args VERB -- copy (always) or sync (only from the one
# sanctioned site). RCLONE_EXTRA_FLAGS lands here and NOT on the check pass:
# check's only job is to compute the deletion list, and an arbitrary user flag
# that copy accepts but check does not would abort the prune with a usage error.
_rclone_transfer_args() {
    ARGS=( "$1" )
    ARGS+=( ${RCARGS[@]+"${RCARGS[@]}"} )
    ARGS+=( --create-empty-src-dirs )
    [ -n "$DRY_RUN" ] && ARGS+=( --dry-run )
    if [ -n "$RCLONE_EXTRA_FLAGS" ]; then
        # Split with globbing disabled: a '*' in the value would otherwise
        # glob against cron's working directory.
        set -f
        # shellcheck disable=SC2086
        set -- $RCLONE_EXTRA_FLAGS
        set +f
        _rclone_validate_extra ${1+"$@"}
        ARGS+=( ${1+"$@"} )
    fi
    return 0
}

# _rclone_append_config -- the typed exemption, appended AFTER the guard.
#
# --config is blacklisted so it can only ever arrive through the validated
# RCLONE_CONFIG_PATH key, never through RCLONE_EXTRA_FLAGS. It must be applied
# to EVERY invocation, not just the transfer: measured against a real rclone,
# a check pass without it failed with "didn't find section in config file",
# produced an empty deletion list, and the run reported "nothing to prune".
_rclone_append_config() {
    if [ -n "${RCLONE_CONFIG_PATH:-}" ]; then
        ARGS+=( --config="$RCLONE_CONFIG_PATH" )
    fi
    return 0
}

# _rclone_lsf_args -- one side of the deletion preview.
#
# NOT `rclone check`. check was the obvious choice and it is wrong here:
# measured against rclone 1.75, it reports every missing-on-source file as an
#
#     ERROR : a.txt: file not in Local file system at /path/to/src
#
# and counts it in "Errors: N". So "there is something to delete" and "the scan
# failed" produce the same signal, and no amount of parsing separates them.
# A control that gates deletion cannot be built on an ambiguous signal.
#
# Two `lsf` listings differenced with comm(1) have none of that ambiguity:
# exit 0 means a COMPLETE listing and nothing else, the output is one path per
# line on stdout with the log on stderr, and the same --filter-from is applied
# to both sides so an excluded name is shielded from deletion exactly as it is
# on the rsync path.
_rclone_lsf_args() {
    ARGS=( lsf )
    ARGS+=( ${RCARGS[@]+"${RCARGS[@]}"} )
    ARGS+=( --recursive --files-only --format=p )
    return 0
}

# _prune_scan_rclone RAWFILE LISTFILE -- the cloud half of _prune_scan.
#
# Same contract as the rsync one: write the cleaned, sorted deletion list to
# LISTFILE, or end the run. Audit files share the rsync path's naming and ring
# (prune-<ts>-{preview,recheck}.log, timestamp first, outside [0-9]*.log).
_prune_scan_rclone() {
    _ps_raw=$1
    _ps_list=$2
    assert_prune_sanctioned preview

    # _rclone_lsf_args writes into ARGS, which at this point already holds the
    # assembled transfer argv -- and run_backup execs that array after this
    # returns. Save and restore, or a preview would silently turn the run
    # itself into a listing.
    _ps_saved=( ${ARGS[@]+"${ARGS[@]}"} )

    _ps_src=$LOG_DIR/.prune-scan-src.txt
    _ps_dst=$LOG_DIR/.prune-scan-dst.txt
    : >"$_ps_raw"
    : >"$_ps_src"
    : >"$_ps_dst"

    _rclone_lsf_args
    assert_no_destructive_rclone_flags ${ARGS[@]+"${ARGS[@]}"}
    _rclone_append_config

    # Paths on stdout, rclone's own log on stderr: they are never merged, so a
    # NOTICE line cannot end up in the list the user is asked to confirm.
    "$RCLONE_BIN" ${ARGS[@]+"${ARGS[@]}"} "$SRC" >"$_ps_src" 2>>"$_ps_raw"
    _ps_rc=$?
    if [ "$_ps_rc" != 0 ]; then
        _prune_scan_abort "could not list the source" "$_ps_raw"
    fi

    # THE catastrophic direction, closed explicitly. If the source listed as
    # empty -- a drive that unmounted into an empty-but-readable mount point,
    # a permissions change -- then every single file at the destination is
    # "missing at source" and a confirmed prune would delete the whole backup.
    if [ ! -s "$_ps_src" ] && [ "${ALLOW_EMPTY_SOURCE:-}" != yes ]; then
        _prune_scan_abort "the source listed as EMPTY, which would mark the entire destination for deletion" "$_ps_raw"
    fi

    "$RCLONE_BIN" ${ARGS[@]+"${ARGS[@]}"} "$DEST" >"$_ps_dst" 2>>"$_ps_raw"
    _ps_rc=$?
    case $_ps_rc in
        0) ;;
        # 3 == directory not found: the destination does not exist yet, which
        # is simply a first run. Nothing there, nothing to delete.
        3) : >"$_ps_dst" ;;
        *) _prune_scan_abort "could not list the destination" "$_ps_raw" ;;
    esac

    sort "$_ps_src" -o "$_ps_src"
    sort "$_ps_dst" -o "$_ps_dst"
    # Present at the destination and absent from the source: exactly what a
    # sync would delete. (A directory left empty by the deletion is removed
    # too, and never appears in this list -- the preview text says so.)
    comm -13 "$_ps_src" "$_ps_dst" >"$_ps_list"

    ARGS=( ${_ps_saved[@]+"${_ps_saved[@]}"} )

    ls -1 "$LOG_DIR"/prune-*.log 2>/dev/null | sort -r | awk 'NR>10' \
        | while IFS= read -r _ps_old; do
            rm -f -- "$_ps_old"
        done
    return 0
}

# _prune_scan_abort REASON RAWFILE -- end the run without deleting anything.
# Exit 75 is the project's "the prune was declined or could not be trusted;
# nothing was transferred or deleted" code.
_prune_scan_abort() {
    log ""
    log "RESULT: SCAN INCOMPLETE -- $1, so the deletion list cannot be"
    log "        trusted. Nothing was transferred or deleted."
    log "        Audit log: $2"
    tail -10 "$2" 2>/dev/null | while IFS= read -r _psa_l; do log "  $_psa_l"; done
    release_lock
    exit 75
}
# ---------------------------------------------------------------------------
# _rclone_assemble_args -- the rclone side of argv assembly, the peer of
# _rsync_assemble_args in lib/common.sh.
# ---------------------------------------------------------------------------
_rclone_assemble_args() {
    _ra_filter=$LOG_DIR/.rclone-filter.txt
    # Same exclude layering as the rsync path: config/global-exclude.txt IS the
    # global list once it exists, with rsync-ignore.txt only the bare-clone
    # fallback, plus an optional per-backup file. Both are TRANSLATED rather
    # than forwarded -- see _rclone_filter_write for why that is not optional.
    if [ -f "$REPO_ROOT/config/global-exclude.txt" ]; then
        _ra_global=$REPO_ROOT/config/global-exclude.txt
        log "excludes : config/global-exclude.txt (global, yours)"
    else
        [ -f "$REPO_ROOT/rsync-ignore.txt" ] \
            || die 78 "missing $REPO_ROOT/rsync-ignore.txt -- incomplete checkout?"
        _ra_global=$REPO_ROOT/rsync-ignore.txt
    fi
    _ra_per=$REPO_ROOT/config/$BACKUP_NAME/exclude.txt
    if [ -f "$_ra_per" ]; then
        log "excludes : + $_ra_per"
        _rclone_build_filter "$_ra_filter" "$_ra_global" "$_ra_per"
    else
        _rclone_build_filter "$_ra_filter" "$_ra_global"
    fi
    log "filters  : rclone syntax, regenerated each run in $_ra_filter"

    _rclone_common_args "$_ra_filter"
    _rclone_transfer_args copy

    # Half of the never-delete guarantee. See the comment on the function: an
    # argv blacklist alone cannot see RCLONE_IGNORE_ERRORS in the environment.
    _rclone_scrub_env

    assert_no_destructive_rclone_flags ${ARGS[@]+"${ARGS[@]}"}

    _rclone_append_config
    return 0
}
