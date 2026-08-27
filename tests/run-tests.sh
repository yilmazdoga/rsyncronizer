#!/bin/bash
#
# tests/run-tests.sh -- exercises the real code paths against a stub rsync.
# Touches no real data and contacts no host. Run it after any change:
#     ./tests/run-tests.sh

set -uo pipefail

TESTS_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd -P "$TESTS_DIR/.." && pwd)

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
head_() { printf '\n== %s\n' "$1"; }

# The stub, a scratch source tree, and a scratch backup name. config/ and logs/
# are gitignored, so this leaves nothing committable behind, and it is all
# removed at the end regardless.
NAME=selftest
SCRATCH=$(mktemp -d)
export FAKE_RSYNC_ARGV=$SCRATCH/argv.txt
export RSYNC_BIN_OVERRIDE=$TESTS_DIR/fake-rsync
chmod +x "$TESTS_DIR/fake-rsync" 2>/dev/null

HNAME=selftest-headless
# Declared up here because cleanup() (installed below) references it, and the
# cloud sections that assign it run much later.
CNAME=selftest-cloud
# setup.sh seeds config/global-exclude.txt in THIS repo during the headless
# tests; remove it at the end only if it did not exist before the suite ran.
GLOBAL_EXCLUDE_PREEXISTED=0
[ -f "$REPO_ROOT/config/global-exclude.txt" ] && GLOBAL_EXCLUDE_PREEXISTED=1
# The support counter lives in the REAL repo's config/ and every completed
# stub run increments it; save any user copy now and restore it afterwards so
# the suite can neither inflate a real count nor mark anyone as supported.
SUPPORT_PREEXISTED=0
if [ -f "$REPO_ROOT/config/support.txt" ]; then
    SUPPORT_PREEXISTED=1
    cp "$REPO_ROOT/config/support.txt" "$SCRATCH/support.txt.orig"
fi
cleanup() {
    # Restore BEFORE the scratch dir (holding the backup copy) is removed.
    if [ "$SUPPORT_PREEXISTED" = 1 ]; then
        cp "$SCRATCH/support.txt.orig" "$REPO_ROOT/config/support.txt" 2>/dev/null
    else
        rm -f "$REPO_ROOT/config/support.txt"
    fi
    rm -rf "$SCRATCH"
    rm -rf "$REPO_ROOT/config/$NAME" "$REPO_ROOT/logs/$NAME" "$REPO_ROOT/backups/$NAME.sh"
    rm -rf "$REPO_ROOT/config/$HNAME" "$REPO_ROOT/logs/$HNAME" "$REPO_ROOT/backups/$HNAME.sh"
    rm -rf "$REPO_ROOT/config/$CNAME" "$REPO_ROOT/logs/$CNAME" "$REPO_ROOT/backups/$CNAME.sh"
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup/$CNAME.lock"
    rm -f "$REPO_ROOT/remotes/testbox.txt" "$REPO_ROOT/remotes/spacebox.txt"
    [ "$GLOBAL_EXCLUDE_PREEXISTED" = 0 ] && rm -f "$REPO_ROOT/config/global-exclude.txt"
    rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup/$NAME.lock"
    # If the cron-chain test died mid-way, surgically remove ONLY its block --
    # the same exact-whole-line awk setup.sh uses, so sibling entries survive.
    if command -v crontab >/dev/null 2>&1 \
       && crontab -l 2>/dev/null | grep -qF "# >>> rsync-backup-scripts:$HNAME >>>"; then
        crontab -l 2>/dev/null | awk -v tag="rsync-backup-scripts:$HNAME" '
            $0 == "# >>> " tag " >>>" { inblk = 1; next }
            $0 == "# <<< " tag " <<<" { inblk = 0; next }
            inblk != 1 { print }' | crontab -
    fi
}
trap cleanup EXIT

mkdir -p "$SCRATCH/src/sub"
echo hello >"$SCRATCH/src/a.txt"
echo world >"$SCRATCH/src/sub/b.txt"

# ---------------------------------------------------------------------------
head_ "pure functions"
. "$REPO_ROOT/lib/common.sh"

# The locale pin must actually engage wherever a C.UTF-8 variant exists: Ubuntu
# spells it 'C.utf8', and when the probe missed that, `sort` ran under the
# ssh-forwarded en_US.UTF-8, whose collation ignores punctuation and re-orders
# same-second log filenames -- 7 tests failed on the workstation only.
if locale -a 2>/dev/null | grep -ixE 'C\.UTF-?8' >/dev/null 2>&1; then
    case ${LC_ALL:-} in
        C.UTF-8|C.utf8) ok "LC_ALL is pinned to a C.UTF-8 variant ($LC_ALL)" ;;
        *) bad "LC_ALL is pinned to a C.UTF-8 variant" "got '${LC_ALL:-unset}'" ;;
    esac
else
    printf '  skip  no C.UTF-8 variant on this system\n'
fi

[ "$(resolve_path "$SCRATCH/src/")" = "$SCRATCH/src" ] \
    && ok "resolve_path strips a trailing slash" \
    || bad "resolve_path strips a trailing slash" "got $(resolve_path "$SCRATCH/src/")"

[ "$(resolve_path "$SCRATCH/src///")" = "$SCRATCH/src" ] \
    && ok "resolve_path strips repeated trailing slashes" \
    || bad "resolve_path strips repeated trailing slashes"

[ "$(resolve_path "Documents")" = "$HOME/Documents" ] \
    && ok "resolve_path resolves relative against \$HOME, not cwd" \
    || bad "resolve_path resolves relative against \$HOME"

[ "$(resolve_path "~/Documents")" = "$HOME/Documents" ] \
    && ok "resolve_path expands a leading ~" \
    || bad "resolve_path expands a leading ~"

# The classic bug: a [! \t] bracket expression strips the letter 't', because
# inside a bash pattern \t is an escape for t, not a tab.
[ "$(trim "  test  ")" = "test" ] \
    && ok "trim does not eat the letter 't'" \
    || bad "trim does not eat the letter 't'" "got '$(trim "  test  ")'"
[ "$(trim "$(printf '\tvalue\t')")" = "value" ] \
    && ok "trim strips real tabs" \
    || bad "trim strips real tabs"

# ---------------------------------------------------------------------------
head_ "never-delete guard rejects"
for f in --delete --delete-during --delete-after --delete-excluded --del \
         --remove-source-files --force --max-delete=5 --ignore-errors \
         --inplace --append --append-verify --partial -P -avP \
         --write-batch=x --read-batch=x --backup --backup-dir=/x -b \
         --link-dest=/x --compare-dest=/x --rsync-path=/bin/sh -e --rsh=sh \
         -M --remote-option=--delete --files-from=/x -R --relative \
         -C --cvs-exclude --chmod=777 --super --fake-super; do
    if ( assert_no_destructive_flags "$f" ) >/dev/null 2>&1; then
        bad "rejects $f" "it was ACCEPTED"
    else
        ok "rejects $f"
    fi
done

head_ "never-delete guard rejects ABBREVIATIONS (rsync resolves unambiguous prefixes)"
# Verified on macOS openrsync: `--remove` is accepted as --remove-source-files
# and really deletes the source; `--forc` as --force; `--inpl` as --inplace.
# An exact-string blacklist never sees these, so it fails OPEN. These cases exist
# because the original guard had exactly that hole and the suite stayed green.
for f in --remove --rem --forc --f --inpl --inp --max-del --rsync-pat --rs \
         --old-arg --backup-di --chmo --files-fr --relativ --cvs --supe; do
    if ( assert_no_destructive_flags "$f" ) >/dev/null 2>&1; then
        bad "rejects abbreviation $f" "it was ACCEPTED -- the guard is failing open"
    else
        ok "rejects abbreviation $f"
    fi
done

head_ "never-delete guard allows the flags we actually use"
if ( assert_no_destructive_flags -a --no-D --no-o --no-g -v --stats \
        --partial-dir=.rsync-partial --timeout=600 \
        --exclude-from="$REPO_ROOT/rsync-ignore.txt" --bwlimit=100 --dry-run \
   ) >/dev/null 2>&1; then
    ok "the real flag set passes the guard"
else
    bad "the real flag set passes the guard" "the guard rejected our own flags"
fi
# A safety check that cries wolf gets deleted, so prove it does not.
if ( assert_no_destructive_flags --exclude=delete-me.txt ) >/dev/null 2>&1; then
    ok "no false positive on --exclude=delete-me.txt"
else
    bad "no false positive on --exclude=delete-me.txt"
fi

# ---------------------------------------------------------------------------
head_ "config parsing is data, never code"
CFG=$REPO_ROOT/config/$NAME
mkdir -p "$CFG"
printf '%s\n' "$SCRATCH/src" >"$CFG/source.txt"
cat >"$CFG/destination.txt" <<EOF
# a comment
USER=someone
HOST=example.invalid
  DEST_PATH = /remote/dest
EOF
: >"$CFG/options.txt"

[ "$(config_get "$CFG/destination.txt" HOST)" = "example.invalid" ] \
    && ok "config_get reads a key" || bad "config_get reads a key"
[ "$(config_get "$CFG/destination.txt" DEST_PATH)" = "/remote/dest" ] \
    && ok "config_get trims whitespace around key and value" \
    || bad "config_get trims whitespace" "got '$(config_get "$CFG/destination.txt" DEST_PATH)'"

CANARY=$SCRATCH/pwned
printf '%s\n' "EVIL;touch $CANARY=1" >>"$CFG/destination.txt"
config_get "$CFG/destination.txt" USER >/dev/null
[ -f "$CANARY" ] && bad "a malformed config line cannot execute code" "the canary ran" \
                 || ok "a malformed config line cannot execute code"
config_unknown_keys "$CFG/destination.txt" USER HOST DEST_PATH RSYNC_PATH | grep -q . \
    && ok "an unknown/invalid key is reported, not ignored" \
    || bad "an unknown/invalid key is reported"
# Restore a clean destination.txt for the runner tests.
cat >"$CFG/destination.txt" <<EOF
USER=someone
HOST=example.invalid
DEST_PATH=/remote/dest
EOF

# ---------------------------------------------------------------------------
head_ "generated runner and argv assembly"
RUNNER=$REPO_ROOT/backups/$NAME.sh
mkdir -p "$REPO_ROOT/backups"
# FROZEN: this heredoc is the ORIGINAL v1 runner shape (functionally identical
# to setup.sh's template -- same statements, comments stripped; not
# byte-identical). Do not regenerate it when the template evolves: runners in
# the field are never regenerated either, so every run of this suite doubles
# as an old-runner-against-current-lib compatibility test.
sed -e "s/@NAME@/$NAME/" >"$RUNNER" <<'EOF'
#!/bin/bash
set -uo pipefail
_src=${BASH_SOURCE[0]:-$0}
while [ -h "$_src" ]; do
    _dir=$(cd -P "$(dirname -- "$_src")" && pwd)
    _src=$(readlink -- "$_src")
    case $_src in /*) ;; *) _src=$_dir/$_src ;; esac
done
SCRIPT_DIR=$(cd -P "$(dirname -- "$_src")" && pwd)
REPO_ROOT=$(cd -P "$SCRIPT_DIR/.." && pwd)
unset _src _dir
. "$REPO_ROOT/lib/common.sh"
run_backup "@NAME@" "$@"
EOF
chmod +x "$RUNNER"

FAKE_RSYNC_EXIT=0 "$RUNNER" >"$SCRATCH/run.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "a successful run exits 0" || bad "a successful run exits 0" "got $RC"

grep -qx -- '--no-o' "$FAKE_RSYNC_ARGV" && grep -qx -- '--no-g' "$FAKE_RSYNC_ARGV" \
    && ok "ownership is never preserved (--no-o --no-g passed)" \
    || bad "ownership is never preserved"
grep -qx -- '--no-D' "$FAKE_RSYNC_ARGV" \
    && ok "--no-D passed (unprivileged receiver cannot mknod)" || bad "--no-D passed"
grep -q -- '--exclude-from=' "$FAKE_RSYNC_ARGV" \
    && ok "the shared ignore file is passed" || bad "the shared ignore file is passed"
grep -qE -- '^--partial-dir=' "$FAKE_RSYNC_ARGV" \
    && ok "--partial-dir is used (never bare --partial)" || bad "--partial-dir is used"
grep -qE -- '^(--delete|--del|--remove|--inplace|--append|-P)' "$FAKE_RSYNC_ARGV" \
    && bad "no deletion flag ever reaches rsync" "found one in argv" \
    || ok "no deletion flag ever reaches rsync"
# Copy-by-name: the source must arrive WITHOUT a trailing slash, or rsync
# copies the contents and the folder name is lost.
grep -qx -- "$SCRATCH/src" "$FAKE_RSYNC_ARGV" \
    && ok "source is passed by name, with no trailing slash" \
    || bad "source is passed by name" "argv had: $(grep "$SCRATCH" "$FAKE_RSYNC_ARGV" | tr '\n' ' ')"
grep -qx -- "someone@example.invalid:/remote/dest/" "$FAKE_RSYNC_ARGV" \
    && ok "destination is user@host:path/" || bad "destination is user@host:path/"

# ---------------------------------------------------------------------------
head_ "EXTRA_FLAGS cannot smuggle a deletion flag"
printf 'EXTRA_FLAGS=--delete\n' >"$CFG/options.txt"
"$RUNNER" >"$SCRATCH/smuggle.out" 2>&1
RC=$?
[ "$RC" = 78 ] && ok "EXTRA_FLAGS=--delete is refused (exit 78)" \
               || bad "EXTRA_FLAGS=--delete is refused" "exit was $RC"
grep -q 'unsafe rsync flag' "$SCRATCH/smuggle.out" \
    && ok "the refusal explains itself" || bad "the refusal explains itself"
: >"$CFG/options.txt"

# ---------------------------------------------------------------------------
head_ "prune-dest: sanctioned interactive deletion"
# RBS_TEST_CONFIRM_STDIN lifts only the TTY check, and only because
# RSYNC_BIN_OVERRIDE points rsync at the stub -- on a real binary the seam is
# inert. It is passed per-invocation via env, never exported.
ALLCALLS=$FAKE_RSYNC_ARGV.all
# grep -c prints the count even when it is 0 (and exits 1 then), so no fallback:
# an `|| echo 0` would emit a SECOND line and break every comparison.
calls() { grep -c '^=== call' "$ALLCALLS" 2>/dev/null; }

# The bans are unconditional: no combination of env vars reaches rsync.
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
"$RUNNER" --sync-deletions --cron >/dev/null 2>&1
[ $? = 78 ] && ok "--sync-deletions --cron is refused (78)" || bad "--sync-deletions --cron is refused"
"$RUNNER" --sync-deletions --on-mount >/dev/null 2>&1
[ $? = 78 ] && ok "--sync-deletions --on-mount is refused (78)" || bad "--sync-deletions --on-mount is refused"
env RBS_TEST_CONFIRM_STDIN=1 "$RUNNER" --sync-deletions --cron >/dev/null 2>&1
[ $? = 78 ] && ok "the test seam does NOT lift the --cron ban" \
            || bad "the test seam does NOT lift the --cron ban" "it did"
[ ! -s "$FAKE_RSYNC_ARGV" ] && [ "$(calls)" = 0 ] \
    && ok "no refused prune ever invoked rsync" \
    || bad "no refused prune ever invoked rsync"

# Without the seam, a pipe is not a terminal: the confirmation cannot be piped.
echo 'I confirm' | "$RUNNER" --sync-deletions >"$SCRATCH/notty.out" 2>&1
[ $? = 78 ] && ok "piped stdin without the seam is refused (78)" \
            || bad "piped stdin without the seam is refused"
grep -q 'terminal' "$SCRATCH/notty.out" \
    && ok "the refusal names the terminal requirement" \
    || bad "the refusal names the terminal requirement"

# Wrong phrases abort with exit 75 after exactly ONE rsync call (the preview),
# leaving last-run.txt and the success marker untouched.
for phrase in 'confirm' 'I CONFIRM' 'yes' ''; do
    : >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
    printf 'SENTINEL=yes\n' >"$REPO_ROOT/logs/$NAME/last-run.txt"
    rm -f "$REPO_ROOT/logs/$NAME/.last_success_epoch"
    printf '%s\n' "$phrase" \
        | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=3 "$RUNNER" --sync-deletions \
        >"$SCRATCH/decline.out" 2>&1
    RC=$?
    [ "$RC" = 75 ] && ok "'${phrase:-<empty>}' is not a confirmation (exit 75)" \
                   || bad "'${phrase:-<empty>}' is not a confirmation" "exit $RC"
    [ "$(calls)" = 1 ] \
        && ok "  ...only the preview ran (1 rsync call)" \
        || bad "  ...only the preview ran" "$(calls) calls"
    grep -q 'SENTINEL' "$REPO_ROOT/logs/$NAME/last-run.txt" \
        && ok "  ...last-run.txt was not rewritten" \
        || bad "  ...last-run.txt was not rewritten"
    [ ! -f "$REPO_ROOT/logs/$NAME/.last_success_epoch" ] \
        && ok "  ...no success was recorded" || bad "  ...no success was recorded"
done
LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
grep -q 'NOT CONFIRMED' "$LOG" \
    && ok "a decline is logged as NOT CONFIRMED" || bad "a decline is logged as NOT CONFIRMED"

# The two accepted phrases: preview -> recheck -> real run with --delete-after.
for phrase in 'I confirm' 'i confirm'; do
    : >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
    printf '%s\n' "$phrase" \
        | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=3 "$RUNNER" --sync-deletions \
        >"$SCRATCH/confirm.out" 2>&1
    RC=$?
    [ "$RC" = 0 ] && ok "'$phrase' is accepted (exit 0)" || bad "'$phrase' is accepted" "exit $RC"
    [ "$(calls)" = 3 ] \
        && ok "  ...three rsync calls: preview, recheck, real" \
        || bad "  ...three rsync calls" "$(calls) calls"
done
# Anatomy of the confirmed flow, from the last run above:
[ "$(grep -cx -- '--dry-run' "$ALLCALLS")" = 2 ] \
    && ok "both previews are dry runs" || bad "both previews are dry runs"
[ "$(grep -cx -- '--delete-after' "$ALLCALLS")" = 3 ] \
    && ok "--delete-after on all three calls, never bare --delete" \
    || bad "--delete-after on all three calls"
grep -qx -- '--delete-after' "$FAKE_RSYNC_ARGV" \
    && ok "the real call carries --delete-after" || bad "the real call carries --delete-after"
grep -qx -- '--itemize-changes' "$FAKE_RSYNC_ARGV" \
    && ok "the real call carries --itemize-changes (deletions are countable)" \
    || bad "the real call carries --itemize-changes"
grep -qx -- '--dry-run' "$FAKE_RSYNC_ARGV" \
    && bad "the real call is not a dry run" "--dry-run leaked into it" \
    || ok "the real call is not a dry run"
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" PRUNE)" = 1 ] \
    && ok "last-run.txt records PRUNE=1" || bad "last-run.txt records PRUNE=1"
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" DELETED)" = 3 ] \
    && ok "last-run.txt records DELETED=3" \
    || bad "last-run.txt records DELETED=3" "got '$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" DELETED)'"
# The confirmed list itself, spaced filename included, is in the main log.
MAINLOG=$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" LOG)
grep -q '^  will delete: stale dir/$' "$MAINLOG" \
    && ok "the deletion list survives a filename with a space" \
    || bad "the deletion list survives a filename with a space"

# The changed-list abort: the recheck sees a different list than was confirmed.
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
printf '3\n5\n' >"$SCRATCH/delcounts"
printf 'I confirm\n' \
    | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS_FILE="$SCRATCH/delcounts" \
      "$RUNNER" --sync-deletions >"$SCRATCH/changed.out" 2>&1
RC=$?
[ "$RC" = 75 ] && ok "a deletion list that changed after confirmation aborts (75)" \
               || bad "a changed deletion list aborts" "exit $RC"
[ "$(calls)" = 2 ] && ok "  ...the real run never happened (2 calls)" \
                   || bad "  ...the real run never happened" "$(calls) calls"
LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log 2>/dev/null | sort | tail -1)
grep -q 'LIST CHANGED' "$LOG" \
    && ok "  ...and says why" || bad "  ...and says why"

# --sync-deletions --dry-run is preview-only: one call, no prompt, no DELETED.
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
FAKE_RSYNC_DELETIONS=3 "$RUNNER" --sync-deletions --dry-run >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok "--sync-deletions --dry-run exits 0" || bad "--sync-deletions --dry-run exits 0" "exit $RC"
[ "$(calls)" = 1 ] && ok "  ...single rsync call, no prompt" || bad "  ...single rsync call" "$(calls)"
grep -qx -- '--dry-run' "$FAKE_RSYNC_ARGV" && grep -qx -- '--delete-after' "$FAKE_RSYNC_ARGV" \
    && ok "  ...that call is a dry run with --delete-after" \
    || bad "  ...that call is a dry run with --delete-after"
grep -q '^DELETED=' "$REPO_ROOT/logs/$NAME/last-run.txt" \
    && bad "  ...a dry prune must not record DELETED" "it did" \
    || ok "  ...a dry prune records no DELETED count"

# A failing preview dies with rsync's code, before any prompt.
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
printf 'I confirm\n' \
    | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=3 FAKE_RSYNC_EXIT=12 \
      "$RUNNER" --sync-deletions >/dev/null 2>&1
RC=$?
[ "$RC" = 12 ] && ok "a failing preview propagates rsync's exit (12)" \
               || bad "a failing preview propagates rsync's exit" "exit $RC"
[ "$(calls)" = 1 ] && ok "  ...and stops after that one call" || bad "  ...and stops" "$(calls)"

# Nothing to prune -> a normal run, with no deletion flag at all.
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
printf 'I confirm\n' \
    | env RBS_TEST_CONFIRM_STDIN=1 "$RUNNER" --sync-deletions >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok "an empty deletion list falls through to a normal run" \
              || bad "an empty deletion list falls through" "exit $RC"
[ "$(calls)" = 2 ] && ok "  ...preview plus real run (no recheck needed)" \
                   || bad "  ...preview plus real run" "$(calls) calls"
grep -qx -- '--delete-after' "$FAKE_RSYNC_ARGV" \
    && bad "  ...the real run carries no deletion flag" "--delete-after found" \
    || ok "  ...the real run carries no deletion flag"

# The guard still owns EXTRA_FLAGS: --sync-deletions sanctions nothing there.
for bad_flag in --delete --delete-after; do
    : >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
    printf 'EXTRA_FLAGS=%s\n' "$bad_flag" >"$CFG/options.txt"
    printf 'I confirm\n' \
        | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=3 "$RUNNER" --sync-deletions \
        >/dev/null 2>&1
    RC=$?
    [ "$RC" = 78 ] && ok "EXTRA_FLAGS=$bad_flag still dies 78 under --sync-deletions" \
                   || bad "EXTRA_FLAGS=$bad_flag still dies 78 under --sync-deletions" "exit $RC"
    [ "$(calls)" = 0 ] && ok "  ...before rsync ever ran" || bad "  ...before rsync ever ran"
done
: >"$CFG/options.txt"

# ---------------------------------------------------------------------------
head_ "prune audit hygiene, exclude layers, TOTAL_FILES"

# Audit files live in their own prune-<ts>-*.log namespace with their own ring.
# Seed 12 ancient audits, run one confirmed prune (adds preview + recheck):
# the ring must hold at most 10, evicting the OLDEST (timestamp-first names
# keep lexical sort chronological).
i=0
while [ $i -lt 12 ]; do
    printf 'old\n' >"$REPO_ROOT/logs/$NAME/prune-2020-01-01_00000$i-preview.log"
    i=$((i+1))
done
: >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
printf 'I confirm\n' \
    | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=2 "$RUNNER" --sync-deletions \
    >/dev/null 2>&1
ls "$REPO_ROOT/logs/$NAME"/prune-*-preview.log >/dev/null 2>&1 \
    && ok "audits are named prune-<ts>-preview.log" \
    || bad "audits are named prune-<ts>-preview.log"
[ "$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | grep -c prune)" = 0 ] \
    && ok "audits stay OUT of the [0-9]*.log run-log ring" \
    || bad "audits stay OUT of the run-log ring"
PRUNE_COUNT=$(ls -1 "$REPO_ROOT/logs/$NAME"/prune-*.log | wc -l | tr -d ' ')
[ "$PRUNE_COUNT" -le 10 ] \
    && ok "the audit ring keeps at most 10 ($PRUNE_COUNT)" \
    || bad "the audit ring keeps at most 10" "got $PRUNE_COUNT"
ls "$REPO_ROOT/logs/$NAME"/prune-2020-01-01_000000-preview.log >/dev/null 2>&1 \
    && bad "the OLDEST audits are evicted first" "the 2020 file survived" \
    || ok "the OLDEST audits are evicted first"
rm -f "$REPO_ROOT/logs/$NAME"/prune-*.log

# A declined scan is not a run: no attempt/success/last-run bookkeeping.
rm -f "$REPO_ROOT/logs/$NAME/.last_attempt_epoch"
printf 'no\n' \
    | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RSYNC_DELETIONS=2 "$RUNNER" --sync-deletions \
    >/dev/null 2>&1
[ ! -f "$REPO_ROOT/logs/$NAME/.last_attempt_epoch" ] \
    && ok "a declined scan never arms .last_attempt_epoch" \
    || bad "a declined scan never arms .last_attempt_epoch"

# Global excludes: config/global-exclude.txt IS the global list -- when it
# exists it fully REPLACES the shipped rsync-ignore.txt (no hidden layer:
# deleting a rule really un-excludes it); absent, the shipped file is the
# fallback.
if [ -f "$REPO_ROOT/config/global-exclude.txt" ]; then
    printf '  skip  global-exclude tests (a real config/global-exclude.txt exists)\n'
else
    printf -- '- gx-test-marker\n' >"$REPO_ROOT/config/global-exclude.txt"
    : >"$FAKE_RSYNC_ARGV"
    FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
    grep -q 'global-exclude.txt' "$FAKE_RSYNC_ARGV" \
        && ok "the global file is passed to rsync" || bad "the global file is passed to rsync"
    grep -q 'rsync-ignore.txt' "$FAKE_RSYNC_ARGV" \
        && bad "the shipped list is fully REPLACED (nothing hidden)" "rsync-ignore.txt still passed" \
        || ok "the shipped list is fully REPLACED (nothing hidden)"
    # The prune preview must carry the same exclude stack.
    : >"$FAKE_RSYNC_ARGV"; : >"$ALLCALLS"
    FAKE_RSYNC_DELETIONS=1 "$RUNNER" --sync-deletions --dry-run >/dev/null 2>&1
    grep -q 'global-exclude.txt' "$FAKE_RSYNC_ARGV" \
        && ok "a prune scan carries the global excludes (they shield deletions)" \
        || bad "a prune scan carries the global excludes"
    rm -f "$REPO_ROOT/config/global-exclude.txt"
    : >"$FAKE_RSYNC_ARGV"
    FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
    grep -q 'rsync-ignore.txt' "$FAKE_RSYNC_ARGV" \
        && ok "absent global file: the shipped defaults are the fallback" \
        || bad "absent global file: shipped fallback"
fi

# TOTAL_FILES lands in last-run.txt, in both stats dialects.
FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" TOTAL_FILES)" = "100" ] \
    && ok "TOTAL_FILES parsed from openrsync-style stats" \
    || bad "TOTAL_FILES openrsync-style" "got '$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" TOTAL_FILES)'"
FAKE_RSYNC_EXIT=0 FAKE_RSYNC_GNU_STATS=1 "$RUNNER" >/dev/null 2>&1
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" TOTAL_FILES)" = "1416" ] \
    && ok "TOTAL_FILES parsed from GNU-style stats (commas, parenthetical)" \
    || bad "TOTAL_FILES GNU-style" "got '$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" TOTAL_FILES)'"

# ---------------------------------------------------------------------------
head_ "exit-code interpretation"
for pair in "23:PARTIAL" "24:SUCCESS" "255:SSH FAILURE" "30:TIMEOUT"; do
    code=${pair%%:*}
    want=${pair#*:}
    FAKE_RSYNC_EXIT=$code "$RUNNER" >/dev/null 2>&1
    got=$?
    LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
    if [ "$got" = "$code" ] && grep -q "$want" "$LOG"; then
        ok "exit $code is passed through and read as '$want'"
    else
        bad "exit $code -> '$want'" "exit was $got"
    fi
done

# ---------------------------------------------------------------------------
head_ "empty source is refused, not reported as success"
mkdir -p "$SCRATCH/empty"
printf '%s\n' "$SCRATCH/empty" >"$CFG/source.txt"
"$RUNNER" >"$SCRATCH/empty.out" 2>&1
RC=$?
[ "$RC" = 66 ] && ok "an empty source aborts (exit 66)" || bad "an empty source aborts" "exit $RC"
# The Full Disk Access advice is macOS-only by design; on Linux the message
# should instead point at the ALLOW_EMPTY_SOURCE escape hatch.
EMPTYLOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
if [ "$(uname -s)" = Darwin ]; then
    grep -qi 'full disk access' "$SCRATCH/empty.out" "$EMPTYLOG" 2>/dev/null \
        && ok "the empty-source failure names the macOS Full Disk Access cause" \
        || bad "the empty-source failure names the macOS Full Disk Access cause"
else
    grep -qi 'ALLOW_EMPTY_SOURCE' "$SCRATCH/empty.out" "$EMPTYLOG" 2>/dev/null \
        && ok "the empty-source failure names the escape hatch" \
        || bad "the empty-source failure names the escape hatch"
fi

printf 'ALLOW_EMPTY_SOURCE=yes\n' >"$CFG/options.txt"
"$RUNNER" >/dev/null 2>&1
[ $? = 0 ] && ok "ALLOW_EMPTY_SOURCE=yes provides the escape hatch" \
           || bad "ALLOW_EMPTY_SOURCE=yes provides the escape hatch"
printf '%s\n' "$SCRATCH/src" >"$CFG/source.txt"
: >"$CFG/options.txt"

# ---------------------------------------------------------------------------
head_ "locking"
LOCKBASE=${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup
mkdir -p "$LOCKBASE/$NAME.lock"
printf '%s\n' "$$" >"$LOCKBASE/$NAME.lock/pid"   # a live pid: this shell
"$RUNNER" >"$SCRATCH/lock.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "an overlapping run exits 0 (an overlap is normal)" \
              || bad "an overlapping run exits 0" "exit $RC"
# The SKIPPED line goes to the log, not to stdout: a non-interactive run stays
# quiet so a healthy cron job mails nothing. So assert against the log.
LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
grep -q 'SKIPPED' "$LOG" && ok "the overlap is recorded as SKIPPED in the log" \
                         || bad "the overlap is recorded as SKIPPED in the log"
# The critical property: the loser must NOT delete the holder's lock.
[ -d "$LOCKBASE/$NAME.lock" ] \
    && ok "the losing run did not delete the holder's lock" \
    || bad "the losing run did not delete the holder's lock" "the lock is gone"
rm -rf "$LOCKBASE/$NAME.lock"

FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
[ -d "$LOCKBASE/$NAME.lock" ] \
    && bad "the lock is released after a normal run" "it is still there" \
    || ok "the lock is released after a normal run"

# ---------------------------------------------------------------------------
head_ "missing config fails loudly and points at setup.sh"
mv "$CFG/destination.txt" "$SCRATCH/destination.txt.bak"
"$RUNNER" >"$SCRATCH/nocfg.out" 2>&1
RC=$?
[ "$RC" = 78 ] && ok "missing config exits 78" || bad "missing config exits 78" "exit $RC"
grep -q 'setup.sh' "$SCRATCH/nocfg.out" \
    && ok "the error names setup.sh" || bad "the error names setup.sh"
mv "$SCRATCH/destination.txt.bak" "$CFG/destination.txt"

# ---------------------------------------------------------------------------
head_ "logging"
FAKE_RSYNC_EXIT=0 FAKE_RSYNC_FILES=7 "$RUNNER" >/dev/null 2>&1
LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
grep -q 'files transferred: 7' "$LOG" \
    && ok "the transferred-file count is parsed into the log" \
    || bad "the transferred-file count is parsed into the log"
[ -f "$REPO_ROOT/logs/$NAME/last-run.txt" ] \
    && ok "last-run.txt is written" || bad "last-run.txt is written"
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" RC)" = "0" ] \
    && ok "last-run.txt is machine-readable by status.sh" \
    || bad "last-run.txt is machine-readable"
[ "$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" HOW)" = "manual" ] \
    && ok "last-run.txt records what triggered the run (HOW=manual)" \
    || bad "last-run.txt records HOW" "got '$(config_get "$REPO_ROOT/logs/$NAME/last-run.txt" HOW)'"

# ---------------------------------------------------------------------------
head_ "cron-parity: the runner works in cron's bare environment"
env -i HOME="$HOME" PATH=/usr/bin:/bin LOGNAME="${LOGNAME:-$USER}" SHELL=/bin/sh \
    RSYNC_BIN_OVERRIDE="$RSYNC_BIN_OVERRIDE" FAKE_RSYNC_ARGV="$FAKE_RSYNC_ARGV" \
    /bin/bash "$RUNNER" --cron >"$SCRATCH/cron.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "runs with no TMPDIR, no SSH_AUTH_SOCK, minimal PATH" \
              || bad "runs in cron's environment" "exit $RC; $(tail -3 "$SCRATCH/cron.out")"

# ---------------------------------------------------------------------------
head_ "support counter and reminder"
# RBS_TEST_SUPPORT_TTY stands in for the [ -t 1 ] check only, and only while
# rsync is the stub -- the same contract as RBS_TEST_CONFIRM_STDIN.
SUPPORT_FILE=$REPO_ROOT/config/support.txt
rm -f "$SUPPORT_FILE"

FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 1 ] \
    && ok "a completed run creates and increments the counter" \
    || bad "counter increments" "got '$(config_get "$SUPPORT_FILE" RUN_COUNT)'"

"$RUNNER" --dry-run >/dev/null 2>&1
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 1 ] \
    && ok "a dry run does not count" || bad "a dry run does not count"

FAKE_RSYNC_EXIT=23 "$RUNNER" >/dev/null 2>&1
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 2 ] \
    && ok "a failed run still counts (it completed)" || bad "a failed run counts"

"$RUNNER" --preflight >/dev/null 2>&1
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 2 ] \
    && ok "--preflight does not count" || bad "--preflight does not count"

# A pid-less lock is reclaimed as stale, so the planted lock must name a
# LIVE holder -- this suite's own pid.
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup/$NAME.lock"
printf '%s\n' "$$" >"${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup/$NAME.lock/pid"
"$RUNNER" >/dev/null 2>&1
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/rsync-backup/$NAME.lock"
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 2 ] \
    && ok "a lock-busy skip does not count" || bad "a lock-busy skip does not count"

{ echo 'RUN_COUNT=8'; echo 'LAST_NAG_COUNT=0'; } >"$SUPPORT_FILE"
RBS_TEST_SUPPORT_TTY=1 FAKE_RSYNC_EXIT=0 "$RUNNER" >"$SCRATCH/nag.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag.out" >/dev/null \
    && bad "no reminder before the 10th run" "nag showed at run 9" \
    || ok "no reminder before the 10th run"

RBS_TEST_SUPPORT_TTY=1 FAKE_RSYNC_EXIT=24 "$RUNNER" >"$SCRATCH/nag.out" 2>&1
RC=$?
[ "$RC" = 24 ] && ok "the reminder never clobbers the exit code (24 stays 24)" \
              || bad "reminder preserves RC" "got $RC"
grep -F "$SUPPORT_URL" "$SCRATCH/nag.out" >/dev/null \
    && ok "the 10th completed run prints the support URL" \
    || bad "the 10th run prints the URL"
grep -F '█' "$SCRATCH/nag.out" >/dev/null \
    && ok "the QR art is printed with the reminder" || bad "the QR art is printed"
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 10 ] \
    && [ "$(config_get "$SUPPORT_FILE" LAST_NAG_COUNT)" = 10 ] \
    && ok "showing the reminder arms the next 10-run window" \
    || bad "reminder arms next window" "RUN=$(config_get "$SUPPORT_FILE" RUN_COUNT) NAG=$(config_get "$SUPPORT_FILE" LAST_NAG_COUNT)"

LOG=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log | sort | tail -1)
grep -F buymeacoffee "$LOG" >/dev/null \
    && bad "the reminder stays out of the run log" "found it in $LOG" \
    || ok "the reminder stays out of the run log"

RBS_TEST_SUPPORT_TTY=1 "$RUNNER" >"$SCRATCH/nag2.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag2.out" >/dev/null \
    && bad "no repeat until 10 more runs" || ok "no repeat until 10 more runs"

{ echo 'SUPPORTED=yes'; echo 'RUN_COUNT=99'; echo 'LAST_NAG_COUNT=0'; } >"$SUPPORT_FILE"
RBS_TEST_SUPPORT_TTY=1 "$RUNNER" >"$SCRATCH/nag3.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag3.out" >/dev/null \
    && bad "SUPPORTED=yes silences the reminder" || ok "SUPPORTED=yes silences the reminder"
[ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 100 ] \
    && ok "counting continues after SUPPORTED=yes" || bad "counting continues after SUPPORTED"

{ echo 'RUN_COUNT=50'; echo 'LAST_NAG_COUNT=0'; } >"$SUPPORT_FILE"
RBS_TEST_SUPPORT_TTY=1 RBS_NO_SUPPORT_NAG=1 "$RUNNER" >"$SCRATCH/nag4.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag4.out" >/dev/null \
    && bad "RBS_NO_SUPPORT_NAG suppresses the reminder" \
    || ok "RBS_NO_SUPPORT_NAG suppresses the reminder (GUI/remote path)"

"$RUNNER" >"$SCRATCH/nag5.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag5.out" >/dev/null \
    && bad "no terminal, no reminder" || ok "no terminal, no reminder"

# Cron parity: the seam passes the TTY check, so what this proves is the
# HOW=manual gate -- a due counter must never leak into scheduled output.
env -i HOME="$HOME" PATH=/usr/bin:/bin LOGNAME="${LOGNAME:-$USER}" SHELL=/bin/sh \
    RSYNC_BIN_OVERRIDE="$RSYNC_BIN_OVERRIDE" FAKE_RSYNC_ARGV="$FAKE_RSYNC_ARGV" \
    RBS_TEST_SUPPORT_TTY=1 \
    /bin/bash "$RUNNER" --cron >"$SCRATCH/nag-cron.out" 2>&1
grep -F buymeacoffee "$SCRATCH/nag-cron.out" >/dev/null \
    && bad "a cron run never shows the reminder even when due" \
    || ok "a cron run never shows the reminder even when due"

{ echo 'RUN_COUNT=53'; echo 'LAST_NAG_COUNT=50'; } >"$SUPPORT_FILE"
"$REPO_ROOT/status.sh" >"$SCRATCH/st-support.out" 2>&1
grep -F "$SUPPORT_URL" "$SCRATCH/st-support.out" >/dev/null \
    && ok "status.sh human mode carries the support line" \
    || bad "status.sh human support line"
"$REPO_ROOT/status.sh" --porcelain >"$SCRATCH/st-support-p.out" 2>&1
grep -x 'SUPPORT_RUNS=53' "$SCRATCH/st-support-p.out" >/dev/null \
    && ok "porcelain reports SUPPORT_RUNS" || bad "porcelain SUPPORT_RUNS"
{ echo 'SUPPORTED=yes'; echo 'RUN_COUNT=53'; echo 'LAST_NAG_COUNT=50'; } >"$SUPPORT_FILE"
"$REPO_ROOT/status.sh" >"$SCRATCH/st-support2.out" 2>&1
grep -F buymeacoffee "$SCRATCH/st-support2.out" >/dev/null \
    && bad "status.sh support line hidden once supported" \
    || ok "status.sh support line hidden once supported"
"$REPO_ROOT/status.sh" --porcelain >"$SCRATCH/st-support-p2.out" 2>&1
grep -x 'SUPPORTED=yes' "$SCRATCH/st-support-p2.out" >/dev/null \
    && ok "porcelain reports SUPPORTED=yes" || bad "porcelain SUPPORTED"

# CLI face of the same state.
{ echo 'RUN_COUNT=7'; echo 'LAST_NAG_COUNT=0'; } >"$SUPPORT_FILE"
"$REPO_ROOT/cli/rsyncronizer" support >"$SCRATCH/cli-support.out" 2>&1
grep -F "$SUPPORT_URL" "$SCRATCH/cli-support.out" >/dev/null \
    && grep -F '█' "$SCRATCH/cli-support.out" >/dev/null \
    && ok "cli support prints the URL and QR" || bad "cli support prints URL/QR"
"$REPO_ROOT/cli/rsyncronizer" support --done >/dev/null 2>&1
[ "$(config_get "$SUPPORT_FILE" SUPPORTED)" = yes ] \
    && [ "$(config_get "$SUPPORT_FILE" RUN_COUNT)" = 7 ] \
    && ok "cli support --done marks supported and preserves counters" \
    || bad "cli support --done"
"$REPO_ROOT/cli/rsyncronizer" support --bogus >/dev/null 2>&1
[ $? = 64 ] && ok "cli support with a bad flag exits 64" || bad "cli support bad flag exits 64"
"$REPO_ROOT/cli/rsyncronizer" help | grep -F 'support' >/dev/null \
    && ok "cli help lists support" || bad "cli help lists support"

# One URL everywhere: the QR file names what it encodes, and the GUI and
# README carry the identical string.
head -1 "$REPO_ROOT/lib/support-qr.txt" | grep -F "$SUPPORT_URL" >/dev/null \
    && ok "support-qr.txt names the URL it encodes" || bad "support-qr URL comment"
grep -F "\"$SUPPORT_URL\"" "$REPO_ROOT/gui/app/engine.py" >/dev/null \
    && ok "the GUI carries the same support URL" || bad "GUI support URL differs"
grep -F "$SUPPORT_URL" "$REPO_ROOT/README.md" >/dev/null \
    && ok "the README carries the same support URL" || bad "README support URL differs"

# Leave a clean slate for the rest of the suite (cleanup restores any user
# file at the end).
rm -f "$SUPPORT_FILE"

# ---------------------------------------------------------------------------
head_ "shared ignore file"
grep -q '^- #recycle$' "$REPO_ROOT/rsync-ignore.txt" \
    && ok "#recycle carries the '- ' rule prefix" || bad "#recycle carries the '- ' rule prefix"
grep -q '^- \.git$' "$REPO_ROOT/rsync-ignore.txt" \
    && bad ".git must NOT be excluded" "found an exclude rule for .git" \
    || ok ".git is not excluded"
if grep -vE '^\s*(#|$)' "$REPO_ROOT/rsync-ignore.txt" | grep -qE '^- /|^- [^ ]*/[^ ]'; then
    bad "no rule is anchored or contains a slash" "$(grep -vE '^\s*(#|$)' "$REPO_ROOT/rsync-ignore.txt" | grep -E '^- /|^- [^ ]*/[^ ]')"
else
    ok "no rule is anchored or contains a slash"
fi

# ---------------------------------------------------------------------------
# The cloud transport (rclone). Every section below mirrors an rsync one, so
# the two safety stories are provably symmetrical rather than merely similar.
# ---------------------------------------------------------------------------
CNAME=selftest-cloud
CCFG=$REPO_ROOT/config/$CNAME
CRUNNER=$REPO_ROOT/backups/$CNAME.sh
export FAKE_RCLONE_ARGV=$SCRATCH/rclone-argv.txt
export RCLONE_BIN_OVERRIDE=$TESTS_DIR/fake-rclone
chmod +x "$TESTS_DIR/fake-rclone" 2>/dev/null
CALL=$FAKE_RCLONE_ARGV
CALLS=$FAKE_RCLONE_ARGV.all
rcalls() { grep -c '^=== call' "$CALLS" 2>/dev/null; }
# The verbs actually issued, in order -- the line right after each separator.
rverbs() { awk '/^=== call/{getline; printf "%s ", $0}' "$CALLS" 2>/dev/null; }

mkdir -p "$CCFG" "$REPO_ROOT/backups"
printf '%s\n' "$SCRATCH/src" >"$CCFG/source.txt"
cwrite_dest() { printf '%s\n' "$@" >"$CCFG/destination.txt"; }
cwrite_dest 'DEST_TYPE=cloud' 'RCLONE_REMOTE=gdrive' 'DEST_PATH=Backups/laptop' 'CLOUD_PROVIDER=drive'
: >"$CCFG/options.txt"
sed -e "s/@NAME@/$CNAME/" >"$CRUNNER" <<'EOF'
#!/bin/bash
set -uo pipefail
_src=${BASH_SOURCE[0]:-$0}
while [ -h "$_src" ]; do
    _dir=$(cd -P "$(dirname -- "$_src")" && pwd)
    _src=$(readlink -- "$_src")
    case $_src in /*) ;; *) _src=$_dir/$_src ;; esac
done
SCRIPT_DIR=$(cd -P "$(dirname -- "$_src")" && pwd)
REPO_ROOT=$(cd -P "$SCRIPT_DIR/.." && pwd)
unset _src _dir
. "$REPO_ROOT/lib/common.sh"
run_backup "@NAME@" "$@"
EOF
chmod +x "$CRUNNER"
# Reset both records; `: >file` on the .all file is what makes rcalls() honest.
creset() { : >"$CALL"; : >"$CALLS"; }

# ---------------------------------------------------------------------------
head_ "rclone guard rejects"
for f in --delete --delete-during --delete-after --delete-excluded \
         --delete-empty-src-dirs --max-delete=5 --max-delete-size=1G \
         --backup-dir=/x --suffix=.bak --track-renames --ignore-errors \
         --inplace --files-from=/x --files-from-raw=/x --include='*.txt' \
         --include-from=/x --max-age=1d --min-size=1M \
         --drive-use-trash=false --dump=headers --dump-bodies \
         --rc --rc-no-auth --rc-addr=:5572 --password-command=sh \
         --config=/x --log-file=/x --links --interactive \
         --error-on-no-transfer -l -P -i -Pv -vl; do
    if ( assert_no_destructive_rclone_flags copy "$f" ) >/dev/null 2>&1; then
        bad "rclone guard rejects $f" "it was accepted"
    else
        ok "rclone guard rejects $f"
    fi
done
# rclone takes its paths positionally, so a bare word is a smuggled third path.
for f in sync purge delete /etc/passwd 'gdrive:evil'; do
    if ( assert_no_destructive_rclone_flags copy "$f" ) >/dev/null 2>&1; then
        bad "rclone guard rejects the bare word '$f'" "it was accepted"
    else
        ok "rclone guard rejects the bare word '$f'"
    fi
done

# ---------------------------------------------------------------------------
head_ "rclone guard allows the flags we actually use"
# The whole assembled set at once. A false positive here is not theoretical:
# our own --error=FILE is a PREFIX of the blacklisted --error-on-no-transfer,
# and an rsync-style abbreviation arm refused every prune because of it.
if ( assert_no_destructive_rclone_flags copy \
        --create-empty-src-dirs --transfers=4 --checkers=8 \
        --timeout=600s --contimeout=60s --retries=3 --low-level-retries=10 \
        --stats=5m --stats-log-level=NOTICE -v --color=NEVER \
        --ask-password=false --filter-from=/tmp/delete-me.txt \
        --bwlimit=1000K --dry-run --drive-stop-on-upload-limit \
        --dropbox-batch-mode=sync ) >/dev/null 2>&1; then
    ok "the real assembled flag set passes the guard"
else
    bad "the real assembled flag set passes the guard" \
        "$( ( assert_no_destructive_rclone_flags copy --error=/tmp/x ) 2>&1 | head -1)"
fi
if ( assert_no_destructive_rclone_flags lsf --recursive --files-only --format=p ) >/dev/null 2>&1; then
    bad "the listing verb without a sanction is refused" "it was accepted"
else
    ok "the listing verb without a sanction is refused"
fi
if ( PRUNE=1; assert_no_destructive_rclone_flags lsf --recursive --files-only --format=p ) >/dev/null 2>&1; then
    ok "the preview's own flags pass once the prune is sanctioned"
else
    bad "the preview's own flags pass once the prune is sanctioned"
fi

# ---------------------------------------------------------------------------
head_ "rclone guard controls the VERB, which is the deletion switch"
( assert_no_destructive_rclone_flags sync ) >/dev/null 2>&1 \
    && bad "sync is refused without a typed confirmation" "it was accepted" \
    || ok "sync is refused without a typed confirmation"
( PRUNE=1; assert_no_destructive_rclone_flags sync ) >/dev/null 2>&1 \
    && bad "sync is refused with --sync-deletions but no confirmation" "accepted" \
    || ok "sync is refused with --sync-deletions but no confirmation"
( PRUNE=1; PRUNE_CONFIRMED=1; assert_no_destructive_rclone_flags sync ) >/dev/null 2>&1 \
    && ok "sync is accepted only after a typed confirmation" \
    || bad "sync is accepted after a typed confirmation"
( PRUNE=1; PRUNE_CONFIRMED=1; FROM_CRON=1; assert_no_destructive_rclone_flags sync ) >/dev/null 2>&1 \
    && bad "a confirmed sync is still refused under --cron" "accepted" \
    || ok "a confirmed sync is still refused under --cron"
for v in move purge delete rmdirs deletefile check; do
    ( assert_no_destructive_rclone_flags "$v" ) >/dev/null 2>&1 \
        && bad "the verb '$v' is refused" "it was accepted" \
        || ok "the verb '$v' is refused"
done
# Exactly ONE site in the codebase may produce a deleting verb.
[ "$(grep -c '_rclone_transfer_args sync' "$REPO_ROOT/lib/common.sh")" = 1 ] \
    && ok "exactly one site in the engine can produce the verb 'sync'" \
    || bad "exactly one site can produce the verb 'sync'" \
           "$(grep -n '_rclone_transfer_args sync' "$REPO_ROOT/lib/common.sh")"

# ---------------------------------------------------------------------------
head_ "cloud config validation"
cbad() {   # LABEL then destination.txt lines
    _lbl=$1; shift
    cwrite_dest "$@"
    "$CRUNNER" --dry-run >"$SCRATCH/cbad.out" 2>&1
    _rc=$?
    [ "$_rc" = 78 ] && ok "78: $_lbl" || bad "78: $_lbl" "exit was $_rc"
}
cbad "cloud + HOST"          'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'HOST=example'
cbad "cloud + USER"          'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'USER=alice'
cbad "cloud + RSYNC_PATH"    'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'RSYNC_PATH=/usr/bin/rsync'
cbad "cloud + VOLUME_ROOT"   'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'VOLUME_ROOT=/Volumes/x'
cbad "cloud + DEST_FS"       'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'DEST_FS=exfat'
cbad "cloud without RCLONE_REMOTE" 'DEST_TYPE=cloud' 'DEST_PATH=b'
cbad "remote containing ':'" 'DEST_TYPE=cloud' 'RCLONE_REMOTE=g:' 'DEST_PATH=b'
cbad "remote containing '/'" 'DEST_TYPE=cloud' 'RCLONE_REMOTE=a/b' 'DEST_PATH=b'
cbad "remote starting with '-'" 'DEST_TYPE=cloud' 'RCLONE_REMOTE=-oProxy' 'DEST_PATH=b'
cbad "absolute DEST_PATH"    'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=/b'
cbad "DEST_PATH with ':'"    'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=other:b'
cbad "DEST_PATH starting with '-'" 'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=-rf'
cbad "unknown CLOUD_PROVIDER" 'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'CLOUD_PROVIDER=azure'
cbad "a typo'd key"          'DEST_TYPE=cloud' 'RCLONE_REMOTE=g' 'DEST_PATH=b' 'RCLONE_REMOT=g'
cbad "ssh + RCLONE_REMOTE"   'HOST=example' 'DEST_PATH=/b' 'RCLONE_REMOTE=g'
cbad "an unknown DEST_TYPE"  'DEST_TYPE=azure' 'DEST_PATH=b'
cwrite_dest 'DEST_TYPE=cloud' 'RCLONE_REMOTE=gdrive' 'DEST_PATH=Backups/laptop' 'CLOUD_PROVIDER=drive'
printf 'EXTRA_FLAGS=--no-p\n' >"$CCFG/options.txt"
"$CRUNNER" --dry-run >/dev/null 2>&1
[ $? = 78 ] && ok "78: rsync's EXTRA_FLAGS is refused on a cloud backup" \
             || bad "rsync's EXTRA_FLAGS is refused on a cloud backup"
: >"$CCFG/options.txt"
printf 'RCLONE_TRANSFERS=4\n' >"$CFG/options.txt"
"$RUNNER" --dry-run >/dev/null 2>&1
[ $? = 78 ] && ok "78: RCLONE_TRANSFERS is refused on an rsync backup" \
             || bad "RCLONE_TRANSFERS is refused on an rsync backup"
: >"$CFG/options.txt"

# ---------------------------------------------------------------------------
head_ "cloud argv assembly"
creset
"$CRUNNER" --dry-run >"$SCRATCH/cloud-run.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "a cloud dry run exits 0" || bad "a cloud dry run exits 0" "got $RC"
[ "$(head -1 "$CALL")" = copy ] \
    && ok "the verb is 'copy' on a normal run" \
    || bad "the verb is 'copy'" "got $(head -1 "$CALL")"
# THE load-bearing assertion. `rclone copy SRC DST` copies the CONTENTS of SRC,
# so without the basename appended here ~/Documents lands as <dest>/ rather
# than <dest>/Documents/.
grep -qxF -- 'gdrive:Backups/laptop/src' "$CALL" \
    && ok "the destination carries the source basename (copy-by-name)" \
    || bad "the destination carries the source basename" \
           "got: $(grep 'gdrive:' "$CALL" | tr '\n' ' ')"
grep -qxF -- "$SCRATCH/src" "$CALL" \
    && ok "the source is passed with no trailing slash" || bad "the source has no trailing slash"
grep -qF -- '--filter-from=' "$CALL" \
    && ok "the translated filter file is passed" || bad "the translated filter file is passed"
grep -qxF -- '--stats-log-level=NOTICE' "$CALL" \
    && ok "--stats-log-level=NOTICE (stats are INFO and invisible without it)" \
    || bad "--stats-log-level=NOTICE is passed"
grep -qxF -- '--color=NEVER' "$CALL" \
    && ok "--color=NEVER (a tty would tee escape codes into the log)" || bad "--color=NEVER is passed"
grep -qxF -- '--ask-password=false' "$CALL" \
    && ok "--ask-password=false (an encrypted config must not block cron)" \
    || bad "--ask-password=false is passed"
grep -qxE -- '--(delete|max-delete).*|sync|--links|-l|--config=.*|--dump.*' "$CALL" \
    && bad "no deletion or unsafe flag reaches rclone" "found one in argv" \
    || ok "no deletion or unsafe flag reaches rclone"
grep -qxF -- '--progress' "$CALL" \
    && bad "--progress is never passed (it breaks the app's line reader)" "found it" \
    || ok "--progress is never passed"
grep -qxF -- "--drive-stop-on-upload-limit" "$CALL" \
    && ok "the provider default for drive is applied" || bad "the provider default for drive is applied"
# resolve_path would have prefixed $HOME to a relative cloud path.
grep -q "$HOME/Backups" "$CALL" \
    && bad "DEST_PATH is not resolved against \$HOME" "found $HOME in the destination" \
    || ok "DEST_PATH is not resolved against \$HOME"
grep -q 'TRANSPORT=rclone' "$REPO_ROOT/logs/$CNAME/last-run.txt" 2>/dev/null \
    && ok "last-run.txt records TRANSPORT=rclone" || bad "last-run.txt records TRANSPORT=rclone"
grep -q '^TRANSPORT=' "$REPO_ROOT/logs/$NAME/last-run.txt" 2>/dev/null \
    && bad "an rsync run writes NO TRANSPORT key (absent == rsync)" "it wrote one" \
    || ok "an rsync run writes no TRANSPORT key (absent == rsync)"
# Two 'Transferred:' lines: bytes, then files. A naive tail -1 mashes them.
grep -q '^FILES=42$' "$REPO_ROOT/logs/$CNAME/last-run.txt" \
    && ok "the file count comes from the right 'Transferred:' line" \
    || bad "the file count is parsed correctly" \
           "$(grep '^FILES=' "$REPO_ROOT/logs/$CNAME/last-run.txt")"
grep -q '^TOTAL_FILES=142$' "$REPO_ROOT/logs/$CNAME/last-run.txt" \
    && ok "TOTAL_FILES is checks plus transfers" \
    || bad "TOTAL_FILES is checks plus transfers" \
           "$(grep '^TOTAL_FILES=' "$REPO_ROOT/logs/$CNAME/last-run.txt")"

# ---------------------------------------------------------------------------
head_ "rclone filter translation"
# rclone matches only the LAST path element, so rsync's rules cannot be
# forwarded: '- build' would not exclude build/foo.o, and every node_modules on
# the machine would be backed up.
CFILT=$REPO_ROOT/logs/$CNAME/.rclone-filter.txt
[ -f "$CFILT" ] && ok "the translated filter file is generated" || bad "the filter file is generated"
grep -qxF -- '- node_modules/**' "$CFILT" \
    && ok "a directory rule becomes 'dir/**' (the only reliable form)" \
    || bad "a directory rule becomes dir/**"
grep -qxF -- '- node_modules/' "$CFILT" \
    && ok "the directory rule itself is kept (recursion pruning)" || bad "the directory rule is kept"
grep -qxF -- '- node_modules' "$CFILT" \
    && bad "a directory-only rule must NOT exclude a FILE of that name" "it emitted a bare rule" \
    || ok "a directory-only rule does not exclude a FILE of that name"
grep -qxF -- '- .DS_Store' "$CFILT" && grep -qxF -- '- .DS_Store/**' "$CFILT" \
    && ok "a bare rule covers both a file and a directory of that name" \
    || bad "a bare rule covers both a file and a directory"
grep -qxF -- '- #recycle' "$CFILT" \
    && ok "'#recycle' survives translation (it is not read as a comment)" \
    || bad "'#recycle' survives translation"
# Regenerated every run: the source files are user-editable.
#
# Snapshot and restore EXACTLY, including the case where the file does not
# exist yet: appending to a missing global-exclude.txt would create a one-line
# one, and setup.sh further down seeds that file only when it is absent -- so a
# sloppy restore here silently breaks a test 700 lines away.
GEFILE=$REPO_ROOT/config/global-exclude.txt
GE_HAD=0
[ -f "$GEFILE" ] && { GE_HAD=1; cp "$GEFILE" "$SCRATCH/ge.orig"; }
printf '%s\n' '- selftest-marker-xyz' >>"$GEFILE"
"$CRUNNER" --dry-run >/dev/null 2>&1
grep -qxF -- '- selftest-marker-xyz' "$CFILT" \
    && ok "the filter file is regenerated when the rules change" \
    || bad "the filter file is regenerated when the rules change"
if [ "$GE_HAD" = 1 ]; then
    cp "$SCRATCH/ge.orig" "$GEFILE"
else
    rm -f "$GEFILE"
fi
# A per-backup layer stacks on top of the global one.
printf '%s\n' '- perbackup-only-xyz' >"$CCFG/exclude.txt"
"$CRUNNER" --dry-run >/dev/null 2>&1
grep -qxF -- '- perbackup-only-xyz' "$CFILT" \
    && ok "the per-backup exclude layer is translated too" || bad "the per-backup layer is translated"
rm -f "$CCFG/exclude.txt"

# ---------------------------------------------------------------------------
head_ "rclone environment scrub"
# The argv blacklist is only half the guarantee: rclone derives an env var for
# EVERY flag, and RCLONE_CONFIG_<REMOTE>_<KEY> can redefine the destination.
creset
env FAKE_RCLONE_ENV="$SCRATCH/rclone-env.txt" \
    RCLONE_IGNORE_ERRORS=true RCLONE_CONFIG_GDRIVE_TYPE=local \
    RCLONE_DELETE_DURING=true RCLONE_PASSWORD_COMMAND=sh \
    "$CRUNNER" --dry-run >/dev/null 2>&1
if [ -s "$SCRATCH/rclone-env.txt" ]; then
    bad "no RCLONE_* variable survives into the child" \
        "$(tr '\n' ' ' <"$SCRATCH/rclone-env.txt")"
else
    ok "no RCLONE_* variable survives into the child"
fi
CLOG=$(ls -1 "$REPO_ROOT/logs/$CNAME"/[0-9]*.log 2>/dev/null | sort -r | head -1)
grep -q 'RCLONE_IGNORE_ERRORS' "$CLOG" \
    && ok "the log names each stripped variable" || bad "the log names each stripped variable"
# The seam itself must survive, or the stub disarms mid-suite.
creset
"$CRUNNER" --dry-run >/dev/null 2>&1
[ "$(rcalls)" -gt 0 ] \
    && ok "the scrub exempts the test seam (RCLONE_BIN_OVERRIDE)" \
    || bad "the scrub exempts the test seam"

# ---------------------------------------------------------------------------
head_ "detect_rclone: version floor and absence"
creset
env FAKE_RCLONE_VERSION=v1.50.0 "$CRUNNER" --dry-run >"$SCRATCH/old.out" 2>&1
[ $? = 69 ] && ok "an rclone below the floor is refused (69)" || bad "an old rclone is refused (69)"
[ "$(rverbs)" = "version " ] \
    && ok "nothing is transferred when the version is refused" \
    || bad "nothing is transferred when the version is refused" "verbs: $(rverbs)"
grep -q '1.55' "$SCRATCH/old.out" && ok "the refusal names the minimum" || bad "the refusal names the minimum"
env FAKE_RCLONE_VERSION=v1.55.0 "$CRUNNER" --dry-run >/dev/null 2>&1
[ $? = 0 ] && ok "exactly the floor is accepted" || bad "exactly the floor is accepted"
env FAKE_RCLONE_VERSION=v1.69.0-beta.1234.abcdef "$CRUNNER" --dry-run >/dev/null 2>&1
[ $? = 0 ] && ok "a -beta suffix parses" || bad "a -beta suffix parses"
# rclone is OPTIONAL: its absence must not touch the rsync backups.
( unset RCLONE_BIN_OVERRIDE; PATH=/usr/bin:/bin "$CRUNNER" --dry-run ) >"$SCRATCH/norc.out" 2>&1
[ $? = 69 ] && ok "a missing rclone is refused (69)" || bad "a missing rclone is refused (69)"
# log() writes to the run log always, and to stdout only on a terminal.
_norc_log=$(ls -1 "$REPO_ROOT/logs/$CNAME"/[0-9]*.log 2>/dev/null | sort -r | head -1)
grep -qi 'install rclone' "$_norc_log" \
    && ok "the refusal says how to install it" || bad "the refusal says how to install it"
( unset RCLONE_BIN_OVERRIDE; PATH=/usr/bin:/bin "$RUNNER" --dry-run ) >/dev/null 2>&1
[ $? = 0 ] && ok "an rsync backup is unaffected by a missing rclone" \
           || bad "an rsync backup is unaffected by a missing rclone"

# ---------------------------------------------------------------------------
head_ "cloud prune: the sanctioned deletion path"
# Mirrors the rsync prune section one assertion at a time.
creset; "$CRUNNER" --sync-deletions --cron >/dev/null 2>&1
[ $? = 78 ] && ok "--sync-deletions --cron is refused (78)" || bad "--sync-deletions --cron is refused"
[ "$(rcalls)" = 0 ] && ok "and rclone was never invoked" || bad "and rclone was never invoked" "$(rcalls)"
creset; "$CRUNNER" --sync-deletions --on-mount >/dev/null 2>&1
[ $? = 78 ] && ok "--sync-deletions --on-mount is refused (78)" || bad "--on-mount is refused"
[ "$(rcalls)" = 0 ] && ok "and rclone was never invoked" || bad "and rclone was never invoked"
creset; env RBS_TEST_CONFIRM_STDIN=1 "$CRUNNER" --sync-deletions --cron >/dev/null 2>&1
[ $? = 78 ] && ok "the test seam does not lift the --cron ban" || bad "the seam does not lift --cron"
# THE widening trap: the seam is keyed on THIS transport's own override, never
# on "either one is set".
creset
( unset RCLONE_BIN_OVERRIDE
  printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 RSYNC_BIN_OVERRIDE="$TESTS_DIR/fake-rsync" \
      "$CRUNNER" --sync-deletions ) >/dev/null 2>&1
[ $? = 78 ] && ok "the seam keyed on the rsync stub does NOT unlock a cloud prune" \
             || bad "the seam must key on the transport's own override"
creset
printf 'no\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=3 "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 75 ] && ok "declining exits 75" || bad "declining exits 75"
# One scan is TWO listings: the source, then the destination.
[ "$(rverbs)" = "version lsf lsf " ] \
    && ok "a decline runs the preview and nothing else" || bad "a decline runs only the preview" "$(rverbs)"
for reply in 'confirm' 'I CONFIRM' 'yes' ''; do
    creset
    printf '%s\n' "$reply" | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=3 \
        "$CRUNNER" --sync-deletions >/dev/null 2>&1
    [ $? = 75 ] && ok "the reply '$reply' aborts (75)" || bad "the reply '$reply' aborts (75)"
done
for reply in 'I confirm' 'i confirm'; do
    creset
    printf '%s\n' "$reply" | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=3 \
        "$CRUNNER" --sync-deletions >/dev/null 2>&1
    [ $? = 0 ] && ok "the reply '$reply' proceeds (0)" || bad "the reply '$reply' proceeds (0)"
    [ "$(rverbs)" = "version lsf lsf lsf lsf sync " ] \
        && ok "  preview, recheck, then sync -- in that order" \
        || bad "  preview, recheck, then sync" "$(rverbs)"
done
# check and sync must see the SAME rule set, or the confirmed list is a lie.
# Four listings plus the sync: an excluded name must be shielded from
# deletion exactly as it is on the rsync path, which only holds if the scan
# and the transfer see the SAME rule set.
[ "$(grep -cF -- '--filter-from=' "$CALLS")" = 5 ] \
    && ok "every listing and the sync share one filter file" \
    || bad "every listing and the sync share one filter file" "$(grep -cF -- '--filter-from=' "$CALLS")"
grep -qxF -- '--delete-after' "$CALL" && ok "the deleting run passes --delete-after" \
                                     || bad "the deleting run passes --delete-after"
grep -qxF -- '--max-delete=3' "$CALL" \
    && ok "--max-delete pins the confirmed count" || bad "--max-delete pins the confirmed count"
grep -qxF -- '--dry-run' "$CALL" && bad "a confirmed prune is not a dry run" "found --dry-run" \
                                || ok "a confirmed prune is not a dry run"
grep -q 'deletions confirmed and re-verified' "$(ls -1 "$REPO_ROOT/logs/$CNAME"/[0-9]*.log | sort -r | head -1)" \
    && ok "the confirmation marker is transport-neutral" || bad "the confirmation marker is transport-neutral"
grep -q '^DELETED=3$' "$REPO_ROOT/logs/$CNAME/last-run.txt" \
    && ok "the deletion count is parsed from rclone's stats" \
    || bad "the deletion count is parsed" "$(grep DELETED "$REPO_ROOT/logs/$CNAME/last-run.txt")"
# A list that moved between the preview and the recheck must delete nothing.
creset
printf '3\n5\n' >"$SCRATCH/missing.txt"
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 \
    FAKE_RCLONE_MISSING_FILE="$SCRATCH/missing.txt" "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 75 ] && ok "a changed deletion list aborts (75)" || bad "a changed deletion list aborts (75)"
[ "$(rverbs)" = "version lsf lsf lsf lsf " ] \
    && ok "and no sync was ever issued" || bad "and no sync was ever issued" "$(rverbs)"
# A listing that did not complete cannot be trusted: exit 0 from lsf means a
# COMPLETE listing and nothing else, which is why the preview is two listings
# rather than an `rclone check` (whose "missing at source" IS an ERROR line,
# making a real failure and a real deletion indistinguishable).
creset
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=2 \
    FAKE_RCLONE_LSF_SRC_EXIT=1 "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 75 ] && ok "a failed SOURCE listing aborts (75)" || bad "a failed source listing aborts (75)"
[ "$(rverbs)" = "version lsf " ] \
    && ok "and it stops at the first listing" || bad "and it stops at the first listing" "$(rverbs)"
creset
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=2 \
    FAKE_RCLONE_LSF_DST_EXIT=1 "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 75 ] && ok "a failed DESTINATION listing aborts (75)" || bad "a failed destination listing aborts (75)"
case $(rverbs) in *sync*) bad "and no sync was issued" "$(rverbs)" ;; *) ok "and no sync was issued" ;; esac
# THE catastrophic direction. A source that lists as empty would mark every
# file at the destination for deletion.
creset
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=2 \
    FAKE_RCLONE_EMPTY_SRC=1 "$CRUNNER" --sync-deletions >"$SCRATCH/emptysrc.out" 2>&1
[ $? = 75 ] && ok "a source that lists as EMPTY aborts (75)" || bad "an empty source listing aborts (75)"
case $(rverbs) in *sync*) bad "and no sync was issued" "$(rverbs)" ;; *) ok "and no sync was issued" ;; esac
grep -q 'EMPTY' "$(ls -1 "$REPO_ROOT/logs/$CNAME"/[0-9]*.log | sort -r | head -1)" \
    && ok "and the log says why" || bad "and the log says why"
# A destination that does not exist yet is a FIRST RUN, not a failure.
creset
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_LSF_DST_EXIT=3 \
    "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 0 ] && ok "a destination that does not exist yet is a first run, not an error" \
           || bad "a missing destination is a first run"
# Nothing to prune degrades to an ordinary append-only run.
creset
printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=0 \
    "$CRUNNER" --sync-deletions >/dev/null 2>&1
[ $? = 0 ] && ok "an empty deletion list continues as a normal run" || bad "an empty list continues"
[ "$(rverbs)" = "version lsf lsf copy " ] \
    && ok "  with the verb still 'copy'" || bad "  with the verb still copy" "$(rverbs)"
grep -q '^DELETED=' "$REPO_ROOT/logs/$CNAME/last-run.txt" \
    && bad "no DELETED count is recorded when nothing was pruned" "one was" \
    || ok "no DELETED count is recorded when nothing was pruned"
# The dry-run preview never assembles a deleting verb at all.
creset
env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=3 "$CRUNNER" --sync-deletions --dry-run >/dev/null 2>&1
[ $? = 0 ] && ok "--sync-deletions --dry-run exits 0" || bad "--sync-deletions --dry-run exits 0"
[ "$(rverbs)" = "version lsf lsf copy " ] \
    && ok "  and never assembles 'sync'" || bad "  and never assembles sync" "$(rverbs)"
grep -q '^DELETED=' "$REPO_ROOT/logs/$CNAME/last-run.txt" \
    && bad "a prune dry run records no DELETED count" "it recorded one" \
    || ok "a prune dry run records no DELETED count"
# RCLONE_EXTRA_FLAGS can never reach the deletion switch.
for f in 'sync' '--delete-after' '--ignore-errors' '--drive-use-trash=false' '--dump=auth'; do
    creset
    printf 'RCLONE_EXTRA_FLAGS=%s\n' "$f" >"$CCFG/options.txt"
    printf 'I confirm\n' | env RBS_TEST_CONFIRM_STDIN=1 FAKE_RCLONE_MISSING=3 \
        "$CRUNNER" --sync-deletions >/dev/null 2>&1
    _rc=$?
    case $(rverbs) in
        *sync*) bad "RCLONE_EXTRA_FLAGS=$f cannot reach a sync" "verbs: $(rverbs)" ;;
        *) [ "$_rc" = 78 ] && ok "RCLONE_EXTRA_FLAGS=$f is refused (78), no sync" \
                           || bad "RCLONE_EXTRA_FLAGS=$f is refused (78)" "exit $_rc" ;;
    esac
done
: >"$CCFG/options.txt"
# Audit files keep the rsync path's naming and stay out of the run-log ring.
ls -1 "$REPO_ROOT/logs/$CNAME"/prune-*-preview.log >/dev/null 2>&1 \
    && ok "the preview audit log is prune-<ts>-preview.log" || bad "the preview audit log is named right"
ls -1 "$REPO_ROOT/logs/$CNAME"/prune-*-recheck.log >/dev/null 2>&1 \
    && ok "the recheck audit log is prune-<ts>-recheck.log" || bad "the recheck audit log is named right"
ls -1 "$REPO_ROOT/logs/$CNAME"/prune-*.log 2>/dev/null | grep -q '^.*/[0-9]' \
    && bad "prune logs stay out of the [0-9]*.log ring" "one matches the run-log glob" \
    || ok "prune logs stay out of the [0-9]*.log run-log ring"

# ---------------------------------------------------------------------------
head_ "cloud verdicts and status.sh"
for pair in '0:SUCCESS' '2:FAILED (2)' '5:RETRYABLE' '6:PARTIAL' '7:AUTH FAILURE'; do
    _code=${pair%%:*}; _want=${pair#*:}
    creset
    env FAKE_RCLONE_EXIT="$_code" "$CRUNNER" >/dev/null 2>&1
    _log=$(ls -1 "$REPO_ROOT/logs/$CNAME"/[0-9]*.log | sort -r | head -1)
    grep -q "RESULT: $_want" "$_log" \
        && ok "rclone exit $_code reads as $_want" \
        || bad "rclone exit $_code reads as $_want" "$(grep '^RESULT:' "$_log")"
done
# The two tables must not be able to contaminate each other. rclone 5 is a
# TEMPORARY error; rsync 5 is a protocol failure.
env FAKE_RSYNC_EXIT=23 "$RUNNER" >/dev/null 2>&1
env FAKE_RCLONE_EXIT=7 "$CRUNNER" >/dev/null 2>&1
POUT=$SCRATCH/porcelain-cloud.txt
"$REPO_ROOT/status.sh" --porcelain >"$POUT" 2>&1
awk -v n="$NAME" '/^BACKUP=/{b=($0=="BACKUP=" n)} b && /^VERDICT=/{print}' "$POUT" | grep -q 'PARTIAL' \
    && ok "the rsync backup still reads against rsync's table" \
    || bad "the rsync backup reads against rsync's table" \
           "$(awk -v n="$NAME" '/^BACKUP=/{b=($0=="BACKUP=" n)} b && /^VERDICT=/{print}' "$POUT")"
awk -v n="$CNAME" '/^BACKUP=/{b=($0=="BACKUP=" n)} b && /^VERDICT=/{print}' "$POUT" | grep -q 'AUTH FAILURE' \
    && ok "the cloud backup reads against rclone's table, in the SAME report" \
    || bad "the cloud backup reads against rclone's table" \
           "$(awk -v n="$CNAME" '/^BACKUP=/{b=($0=="BACKUP=" n)} b && /^VERDICT=/{print}' "$POUT")"
for k in 'DEST_TYPE=cloud' 'RCLONE_REMOTE=gdrive' 'CLOUD_PROVIDER=drive' 'REMOTE_DEFINED=1' 'TRANSPORT=rclone'; do
    grep -qxF -- "$k" "$POUT" && ok "porcelain carries $k" || bad "porcelain carries $k"
done
grep -qxF -- 'CLOUD_CONFIGURED=1' "$POUT" && ok "porcelain carries CLOUD_CONFIGURED=1" \
                                          || bad "porcelain carries CLOUD_CONFIGURED=1"
grep -qxF -- 'DEST=gdrive:Backups/laptop' "$POUT" \
    && ok "the destination renders as remote:path" || bad "the destination renders as remote:path"
# status.sh must never make a network call: it runs from cron, where an expired
# token would otherwise hang the health report.
creset
"$REPO_ROOT/status.sh" --porcelain >/dev/null 2>&1
case $(rverbs) in
    *lsd*|*about*|*lsf*|*copy*|*sync*|*check*)
        bad "status.sh makes no network call" "it ran: $(rverbs)" ;;
    *) ok "status.sh makes no network call (only listremotes/version, both local)" ;;
esac
# The scan's two sides must never be merged: rclone's own log goes to stderr
# and the paths to stdout, so a NOTICE line cannot enter the confirmed list.
grep -q 'NOTICE\|INFO' "$REPO_ROOT/logs/$CNAME/.prune-list-confirmed.txt" 2>/dev/null \
    && bad "no log line can enter the confirmed deletion list" "found one" \
    || ok "no log line can enter the confirmed deletion list"
env FAKE_RCLONE_REMOTES='other:' "$REPO_ROOT/status.sh" --porcelain >"$SCRATCH/p2.txt" 2>&1
grep -qxF -- 'REMOTE_DEFINED=0' "$SCRATCH/p2.txt" \
    && ok "a vanished rclone remote is reported" || bad "a vanished rclone remote is reported"
env FAKE_RCLONE_EXIT=0 "$CRUNNER" >/dev/null 2>&1

# ---------------------------------------------------------------------------
head_ "portability lint"
for f in "$REPO_ROOT/lib/common.sh" "$REPO_ROOT/lib/cloud.sh" "$REPO_ROOT/setup.sh" \
         "$REPO_ROOT/status.sh" "$TESTS_DIR/fake-rclone"; do
    /bin/bash -n "$f" 2>/dev/null && ok "bash 3.2 parses $(basename "$f")" \
                                  || bad "bash 3.2 parses $(basename "$f")"
done
if grep -nE 'declare -A|[^a-z]mapfile|readarray|\$\{[A-Za-z_]+,,\}' \
        "$REPO_ROOT/lib/common.sh" "$REPO_ROOT/lib/cloud.sh" "$REPO_ROOT/setup.sh" \
        "$REPO_ROOT/status.sh" \
        | grep -v '^\s*#' | grep -vE ':\s*#' | grep -q .; then
    bad "no bash 4+ constructs" "$(grep -nE 'declare -A|mapfile|readarray' "$REPO_ROOT"/lib/common.sh)"
else
    ok "no bash 4+ constructs"
fi
# Match real usage (head -n -30), not the comment that warns about it.
if grep -nE 'head +-n +-[0-9$]' "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/*.sh >/dev/null 2>&1; then
    bad "no GNU-only 'head -n -N'" "it is not available on macOS"
else
    ok "no GNU-only 'head -n -N'"
fi
# Same class of bug: `timeout` is GNU coreutils and absent on macOS.
if grep -nE '^[^#]*\btimeout +[0-9]' "$REPO_ROOT"/lib/*.sh "$REPO_ROOT"/*.sh >/dev/null 2>&1; then
    bad "no GNU-only 'timeout' command" "it is not installed on macOS"
else
    ok "no GNU-only 'timeout' command"
fi

# ---------------------------------------------------------------------------
head_ "local destination (drive-connect backups)"

# Backward compatibility first: this is the guard for everything above.
[ -z "$(config_get "$CFG/destination.txt" DEST_TYPE)" ] \
    && ok "DEST_TYPE absent in an existing config (defaults to ssh)" \
    || bad "DEST_TYPE absent in an existing config"

mkdir -p "$SCRATCH/vol/dest"
mk_local_cfg() {                       # mk_local_cfg <extra destination.txt lines>
    { echo "DEST_TYPE=local"
      echo "VOLUME_ROOT=$SCRATCH/vol"
      echo "DEST_PATH=$SCRATCH/vol/dest"
      [ $# -gt 0 ] && printf '%s\n' "$@"; } >"$CFG/destination.txt"
}

# A plain directory is NOT a mount point: this is the case that would otherwise
# fill the system disk with hundreds of GB while reporting success.
mk_local_cfg
: >"$FAKE_RSYNC_ARGV"
"$RUNNER" >"$SCRATCH/nomount.out" 2>&1
RC=$?
[ "$RC" = 69 ] && ok "unmounted destination refuses to run (exit 69)" \
               || bad "unmounted destination refuses to run" "exit $RC"
[ ! -s "$FAKE_RSYNC_ARGV" ] \
    && ok "rsync was never invoked with the drive absent" \
    || bad "rsync was never invoked with the drive absent" "argv was written"

# Config validation
mk_local_cfg "HOST=example.invalid"
"$RUNNER" >/dev/null 2>&1; [ $? = 78 ] && ok "local + HOST is refused (78)" || bad "local + HOST is refused"
mk_local_cfg "USER=someone"
"$RUNNER" >/dev/null 2>&1; [ $? = 78 ] && ok "local + USER is refused (78)" || bad "local + USER is refused"
{ echo "DEST_TYPE=local"; echo "VOLUME_ROOT=$SCRATCH/vol"; echo "DEST_PATH=relative/path"; } >"$CFG/destination.txt"
"$RUNNER" >/dev/null 2>&1; [ $? = 78 ] && ok "relative DEST_PATH is refused (78)" || bad "relative DEST_PATH is refused"
{ echo "DEST_TYPE=local"; echo "VOLUME_ROOT=$SCRATCH/vol"; echo "DEST_PATH=$SCRATCH/elsewhere"; } >"$CFG/destination.txt"
"$RUNNER" >/dev/null 2>&1; [ $? = 78 ] && ok "DEST_PATH outside VOLUME_ROOT is refused (78)" || bad "DEST_PATH outside VOLUME_ROOT is refused"

# --- a REAL mounted volume, so the mount detection is genuinely exercised ---
DMG=''
if [ "$(uname -s)" = Darwin ] && command -v hdiutil >/dev/null 2>&1; then
    DMG=$SCRATCH/testvol.dmg
    if hdiutil create -size 20m -fs ExFAT -volname RBSTEST -quiet "$DMG" 2>/dev/null \
       && hdiutil attach "$DMG" -quiet 2>/dev/null; then
        VOL=/Volumes/RBSTEST
        volume_mounted "$VOL" && ok "volume_mounted detects a real mount point" \
                              || bad "volume_mounted detects a real mount point"
        volume_mounted "$SCRATCH/vol" && bad "a plain directory is not a mount point" \
                                      || ok "a plain directory is not a mount point"
        volume_is_ours "$VOL" && bad "an unmarked volume is rejected" \
                              || ok "an unmarked volume is rejected"

        mkdir -p "$VOL/dest"
        { echo "DEST_TYPE=local"; echo "VOLUME_ROOT=$VOL"; echo "DEST_PATH=$VOL/dest"; echo "DEST_FS=exfat"; } >"$CFG/destination.txt"
        "$RUNNER" >/dev/null 2>&1
        [ $? = 69 ] && ok "mounted but unmarked volume refuses to run (69)" \
                    || bad "mounted but unmarked volume refuses to run"

        printf 'test\n' >"$VOL/.rsync-backup-volume"
        printf 'PRESERVE_PERMS=no\nMODIFY_WINDOW=1\n' >"$CFG/options.txt"
        : >"$FAKE_RSYNC_ARGV"
        "$RUNNER" >/dev/null 2>&1
        RC=$?
        [ "$RC" = 0 ] && ok "marked, mounted volume runs (exit 0)" || bad "marked volume runs" "exit $RC"
        grep -qx -- "$VOL/dest/" "$FAKE_RSYNC_ARGV" \
            && ok "local destination is a bare path, no user@host: prefix" \
            || bad "local destination is a bare path" "got: $(grep "$VOL" "$FAKE_RSYNC_ARGV" | tr '\n' ' ')"
        grep -q ':' "$FAKE_RSYNC_ARGV" && grep -qE '^[^-]+@' "$FAKE_RSYNC_ARGV" \
            && bad "no SSH remote is constructed for a local destination" \
            || ok "no SSH remote is constructed for a local destination"
        grep -qx -- '--no-p' "$FAKE_RSYNC_ARGV" \
            && ok "PRESERVE_PERMS=no yields --no-p (exFAT has no permission bits)" \
            || bad "PRESERVE_PERMS=no yields --no-p"
        grep -qx -- '--modify-window=1' "$FAKE_RSYNC_ARGV" \
            && ok "MODIFY_WINDOW=1 yields --modify-window=1 (2s exFAT timestamps)" \
            || bad "MODIFY_WINDOW=1 yields --modify-window=1"
        # Linux exFAT cannot store symlinks at all; without -L every run exits 23.
        grep -qx -- '-L' "$FAKE_RSYNC_ARGV" \
            && bad "COPY_LINKS unset must NOT add -L" "found -L without the option" \
            || ok "COPY_LINKS unset does not add -L"
        printf 'PRESERVE_PERMS=no\nMODIFY_WINDOW=1\nCOPY_LINKS=yes\n' >"$CFG/options.txt"
        : >"$FAKE_RSYNC_ARGV"
        "$RUNNER" >/dev/null 2>&1
        grep -qx -- '-L' "$FAKE_RSYNC_ARGV" \
            && ok "COPY_LINKS=yes yields -L (Linux exFAT cannot store symlinks)" \
            || bad "COPY_LINKS=yes yields -L"
        printf 'PRESERVE_PERMS=no\nMODIFY_WINDOW=1\n' >"$CFG/options.txt"

        # per-backup exclude file, as a SECOND --exclude-from
        printf -- '- secret_dir\n' >"$CFG/exclude.txt"
        : >"$FAKE_RSYNC_ARGV"
        "$RUNNER" >/dev/null 2>&1
        [ "$(grep -c -- '--exclude-from=' "$FAKE_RSYNC_ARGV")" = 2 ] \
            && ok "config exclude.txt is passed as a second --exclude-from" \
            || bad "config exclude.txt is passed as a second --exclude-from"
        rm -f "$CFG/exclude.txt"

        # --- cooldown ---
        rm -f "$REPO_ROOT/logs/$NAME/.last_attempt_epoch"
        printf 'COOLDOWN_HOURS=12\n' >"$CFG/options.txt"
        # Assert on rsync being invoked, not on the log count: log names have
        # one-second granularity and the stub finishes several runs per second,
        # so two runs can legitimately share a filename.
        : >"$FAKE_RSYNC_ARGV"
        "$RUNNER" --on-mount >/dev/null 2>&1
        [ -s "$FAKE_RSYNC_ARGV" ] && ok "--on-mount runs when no cooldown is recorded" \
                                  || bad "--on-mount runs when no cooldown is recorded"
        [ -f "$REPO_ROOT/logs/$NAME/.last_attempt_epoch" ] \
            && ok "the attempt timestamp is armed when the gate clears" \
            || bad "the attempt timestamp is armed when the gate clears"
        : >"$FAKE_RSYNC_ARGV"
        BEFORE=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log 2>/dev/null | wc -l | tr -d ' ')
        "$RUNNER" --on-mount >/dev/null 2>&1
        RC=$?
        AFTER=$(ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log 2>/dev/null | wc -l | tr -d ' ')
        [ "$RC" = 0 ] && ok "--on-mount inside the cooldown exits 0 (not a failure)" \
                      || bad "--on-mount inside the cooldown exits 0" "exit $RC"
        [ "$AFTER" = "$BEFORE" ] \
            && ok "a cooled-down trigger writes NO log (StartOnMount fires constantly)" \
            || bad "a cooled-down trigger writes no log"
        [ ! -s "$FAKE_RSYNC_ARGV" ] && ok "a cooled-down trigger never invokes rsync" \
                                    || bad "a cooled-down trigger never invokes rsync"
        grep -q 'cooldown' "$REPO_ROOT/logs/$NAME/trigger-events.txt" 2>/dev/null \
            && ok "the skip is recorded in trigger-events.txt" \
            || bad "the skip is recorded in trigger-events.txt"

        rm -rf "$VOL/dest" "$VOL/.rsync-backup-volume" 2>/dev/null
        hdiutil detach "$VOL" -quiet 2>/dev/null || hdiutil detach "$VOL" -force -quiet 2>/dev/null
    else
        printf '  skip  real-volume tests (could not create a test exFAT image)\n'
    fi
else
    printf '  skip  real-volume tests (macOS/hdiutil only)\n'
fi

# ---------------------------------------------------------------------------
head_ "log rotation does not eat the bootstrap log"
RD=$SCRATCH/rot; mkdir -p "$RD"
printf 'x\n' >"$RD/cron-bootstrap.log"
printf 'x\n' >"$RD/prune-2020-01-01_000000-preview.log"
i=0; while [ $i -lt 35 ]; do printf 'x\n' >"$RD/2026-01-$(printf '%02d' $((i%28+1)))_0000$i.log"; i=$((i+1)); done
rotate_logs "$RD" 30
[ -f "$RD/cron-bootstrap.log" ] \
    && ok "cron-bootstrap.log survives rotation" || bad "cron-bootstrap.log survives rotation"
[ -f "$RD/prune-2020-01-01_000000-preview.log" ] \
    && ok "prune audits survive run-log rotation (separate rings)" \
    || bad "prune audits survive run-log rotation"
[ "$(ls -1 "$RD"/[0-9]*.log | wc -l | tr -d ' ')" = 30 ] \
    && ok "exactly 30 dated logs are kept" \
    || bad "exactly 30 dated logs are kept" "got $(ls -1 "$RD"/[0-9]*.log | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
head_ "logs/ is disposable: rm -rf it and everything recovers"
# Restore a working ssh config for this section.
cat >"$CFG/destination.txt" <<EOF
USER=someone
HOST=example.invalid
DEST_PATH=/remote/dest
EOF
printf '%s\n' "$SCRATCH/src" >"$CFG/source.txt"
: >"$CFG/options.txt"

rm -rf "$REPO_ROOT/logs/$NAME"
: >"$FAKE_RSYNC_ARGV"
FAKE_RSYNC_EXIT=0 "$RUNNER" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok "a run works with logs/<name>/ deleted" || bad "a run works with logs/<name>/ deleted" "exit $RC"
[ -d "$REPO_ROOT/logs/$NAME" ] && ok "the log directory is recreated" || bad "the log directory is recreated"
ls -1 "$REPO_ROOT/logs/$NAME"/[0-9]*.log >/dev/null 2>&1 \
    && ok "a fresh run log is written" || bad "a fresh run log is written"
[ -f "$REPO_ROOT/logs/$NAME/last-run.txt" ] \
    && ok "last-run.txt is recreated" || bad "last-run.txt is recreated"
# The drift detector must come back on its own, or deleting logs/ would
# silently disable the Full Disk Access check for ever.
[ -f "$REPO_ROOT/logs/$NAME/.baseline_count" ] \
    && ok ".baseline_count self-heals after deletion" \
    || bad ".baseline_count self-heals after deletion"
WANT=$(find "$SCRATCH/src" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
[ "$(cat "$REPO_ROOT/logs/$NAME/.baseline_count" 2>/dev/null)" = "$WANT" ] \
    && ok "the restored baseline matches the real source count ($WANT)" \
    || bad "the restored baseline matches the real source count" \
           "want $WANT, got $(cat "$REPO_ROOT/logs/$NAME/.baseline_count" 2>/dev/null)"

# A cron line must create its own log directory, or the redirect fails before
# the backup ever starts and the job silently no-ops.
rm -rf "$SCRATCH/redir"
/bin/sh -c "echo x >> $SCRATCH/redir/sub/boot.log 2>&1" 2>/dev/null \
    && bad "a bare >> into a missing dir fails (baseline assumption)" \
    || ok "a bare >> into a missing dir fails (this is why mkdir -p is needed)"
/bin/sh -c "mkdir -p $SCRATCH/redir/sub && echo x >> $SCRATCH/redir/sub/boot.log 2>&1" 2>/dev/null \
    && ok "'mkdir -p && cmd >> log' survives a deleted logs/" \
    || bad "'mkdir -p && cmd >> log' survives a deleted logs/"
grep -q 'mkdir -p' "$REPO_ROOT/setup.sh" \
    && ok "setup.sh writes cron entries with the mkdir guard" \
    || bad "setup.sh writes cron entries with the mkdir guard"
# repair.sh is an optional one-time migration for crontab entries written by an
# older setup.sh; it is fine for it not to exist.
if [ -f "$REPO_ROOT/repair.sh" ]; then
    /bin/bash -n "$REPO_ROOT/repair.sh" 2>/dev/null \
        && ok "bash 3.2 parses repair.sh" || bad "bash 3.2 parses repair.sh"
fi

# ---------------------------------------------------------------------------
head_ "trigger installers"
for f in trigger-macos.sh trigger-linux.sh wait-for-mount.sh; do
    /bin/bash -n "$REPO_ROOT/lib/$f" 2>/dev/null && ok "bash 3.2 parses lib/$f" || bad "bash 3.2 parses lib/$f"
done
# launchctl load/unload are deprecated on modern macOS; bootstrap/bootout are not.
# Strip comments first, or the grep matches the comment explaining the rule.
grep -v '^[[:space:]]*#' "$REPO_ROOT/lib/trigger-macos.sh" | grep -qE 'launchctl (load|unload)' \
    && bad "uses modern launchctl bootstrap/bootout" "found deprecated load/unload" \
    || ok "uses modern launchctl bootstrap/bootout"
# udev must never run the backup directly: it kills long-lived children.
grep -v '^[[:space:]]*#' "$REPO_ROOT/lib/trigger-linux.sh" | grep -q 'RUN+=' \
    && bad "udev rule does not RUN+= the backup" "found RUN+=" \
    || ok "udev rule hands off to systemd rather than RUN+="

# ---------------------------------------------------------------------------
head_ "setup.sh headless mode (--answers)"
HANS=$SCRATCH/answers.txt

# Happy path: ssh destination, deliberately unreachable host (the preflight
# warns and continues -- verified behaviour), no schedule keys -> no cron.
rm -rf "$REPO_ROOT/config/$HNAME" "$REPO_ROOT/logs/$HNAME" "$REPO_ROOT/backups/$HNAME.sh"
printf '%s\n' "A_NAME=$HNAME" "A_SOURCE=$SCRATCH/src" 'A_DEST_KIND=1' \
    'A_HOST=selftest.invalid' 'A_USER=@none' "A_DEST_PATH=$SCRATCH/hl-dest" \
    'A_CONFIRM_LANDING=yes' >"$HANS"
"$REPO_ROOT/setup.sh" --answers "$HANS" >"$SCRATCH/hl.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "headless setup exits 0" || bad "headless setup exits 0" "exit $RC; $(tail -3 "$SCRATCH/hl.out")"
[ -f "$REPO_ROOT/config/$HNAME/source.txt" ] && [ -f "$REPO_ROOT/config/$HNAME/destination.txt" ] \
    && ok "config files are written" || bad "config files are written"
[ -x "$REPO_ROOT/backups/$HNAME.sh" ] \
    && ok "the runner is generated and executable" || bad "the runner is generated"
[ -f "$REPO_ROOT/logs/$HNAME/.baseline_count" ] \
    && ok "the source baseline is recorded" || bad "the source baseline is recorded"
[ -z "$(config_get "$REPO_ROOT/config/$HNAME/destination.txt" USER)" ] \
    && ok "A_USER=@none yields an explicitly blank user" \
    || bad "A_USER=@none yields a blank user" "got '$(config_get "$REPO_ROOT/config/$HNAME/destination.txt" USER)'"
[ "$(config_get "$REPO_ROOT/config/$HNAME/destination.txt" HOST)" = selftest.invalid ] \
    && ok "the host lands in destination.txt" || bad "the host lands in destination.txt"
if [ "$GLOBAL_EXCLUDE_PREEXISTED" = 0 ]; then
    [ -f "$REPO_ROOT/config/global-exclude.txt" ] \
        && ok "setup.sh seeds the global exclude file" \
        || bad "setup.sh seeds the global exclude file"
    grep -qx -- '- .DS_Store' "$REPO_ROOT/config/global-exclude.txt" \
        && ok "the seed carries the shipped rules, visibly" \
        || bad "the seed carries the shipped rules"
fi

# An invalid answer must die 78 via the loop-breaker, not spin forever on the
# validation loop. Watchdog is background+kill: the suite bans GNU `timeout`.
printf 'A_NAME=bad name!\n' >"$HANS"
"$REPO_ROOT/setup.sh" --answers "$HANS" >"$SCRATCH/hl-bad.out" 2>&1 &
WPID=$!
( sleep 20; kill -9 "$WPID" 2>/dev/null ) &
WDOG=$!
wait "$WPID"; RC=$?
kill "$WDOG" 2>/dev/null; wait "$WDOG" 2>/dev/null
[ "$RC" = 78 ] && ok "an invalid answer dies 78 (no hang)" \
               || bad "an invalid answer dies 78 (no hang)" "exit $RC (137 = watchdog killed a HANG)"
grep -q 'invalid or missing answer A_NAME' "$SCRATCH/hl-bad.out" \
    && ok "the error names the offending key" || bad "the error names the offending key"

# No --answers and no terminal: still refused.
echo | "$REPO_ROOT/setup.sh" >/dev/null 2>&1
[ $? = 1 ] && ok "piped stdin without --answers is still refused" \
           || bad "piped stdin without --answers is still refused"

# The cron chain: A_SCHEDULE_YN -> cron_schedule_prompt -> cron_install's own
# confirm. A no-cron-only test would mask this two-confirm sequence. Touches
# the REAL crontab, surgically: install one marker block, verify, remove it via
# the A_CRON_REMOVE path, verify the rest of the crontab is byte-identical.
if command -v crontab >/dev/null 2>&1; then
    CRON_BEFORE=$(crontab -l 2>/dev/null) || CRON_BEFORE=''
    printf '%s\n' "A_NAME=$HNAME" "A_SOURCE=$SCRATCH/src" 'A_DEST_KIND=1' \
        'A_HOST=selftest.invalid' 'A_USER=@none' "A_DEST_PATH=$SCRATCH/hl-dest" \
        'A_CONFIRM_LANDING=yes' 'A_SCHEDULE_YN=y' 'A_SCHEDULE_CHOICE=1' \
        'A_CRON_CONFIRM=y' >"$HANS"
    "$REPO_ROOT/setup.sh" --answers "$HANS" >"$SCRATCH/hl-cron.out" 2>&1
    RC=$?
    if grep -q 'crontab install FAILED' "$SCRATCH/hl-cron.out"; then
        # Sandboxed environments (macOS TCC) can read the crontab but not
        # write it. CI and a normal terminal exercise the full chain; here the
        # contract under test is that headless does NOT report success.
        printf '  skip  cron-chain install (this environment denies crontab writes; CI covers it)\n'
        [ "$RC" = 78 ] \
            && ok "a failed cron install is a headless FAILURE (78), not silence" \
            || bad "a failed cron install exits 78 in headless mode" "exit $RC"
    else
        if [ "$RC" = 0 ] \
           && crontab -l 2>/dev/null | grep -qF "# >>> rsync-backup-scripts:$HNAME >>>"; then
            ok "headless cron chain installs the marker block (exit 0)"
        else
            bad "headless cron chain installs the marker block" "exit $RC; $(tail -3 "$SCRATCH/hl-cron.out")"
        fi
        crontab -l 2>/dev/null | awk -v tag="rsync-backup-scripts:$HNAME" '
               $0 == "# >>> " tag " >>>" { inblk = 1; next }
               $0 == "# <<< " tag " <<<" { inblk = 0; next }
               inblk == 1 && $0 !~ /^#/ { print }' | grep -q '^0 2 \* \* \* ' \
            && ok "the schedule line is 02:00 daily with no stray %" \
            || bad "the schedule line is 02:00 daily"
        # Remove via the headless A_CRON_REMOVE path (exercises that key too).
        printf '%s\n' "A_NAME=$HNAME" "A_SOURCE=$SCRATCH/src" 'A_DEST_KIND=1' \
            'A_HOST=selftest.invalid' 'A_USER=@none' "A_DEST_PATH=$SCRATCH/hl-dest" \
            'A_CONFIRM_LANDING=yes' 'A_CRON_REMOVE=y' >"$HANS"
        "$REPO_ROOT/setup.sh" --answers "$HANS" >>"$SCRATCH/hl-cron.out" 2>&1
        crontab -l 2>/dev/null | grep -qF "rsync-backup-scripts:$HNAME" \
            && bad "A_CRON_REMOVE=y removes the block" "the block is still installed" \
            || ok "A_CRON_REMOVE=y removes the block"
        CRON_AFTER=$(crontab -l 2>/dev/null) || CRON_AFTER=''
        [ "$CRON_AFTER" = "$CRON_BEFORE" ] \
            && ok "the rest of the crontab survives byte-identical" \
            || bad "the rest of the crontab survives byte-identical"
    fi
else
    printf '  skip  cron-chain tests (no crontab on this system)\n'
fi

# --- removal: setup.sh --remove NAME ---------------------------------------
# The $HNAME plan from above still exists. Plant "backed-up data" at its
# destination path first: removal must never touch it.
mkdir -p "$SCRATCH/hl-dest"
echo precious >"$SCRATCH/hl-dest/data.txt"

printf 'X=1\n' >"$HANS"    # no A_REMOVE key -> confirm defaults to N
"$REPO_ROOT/setup.sh" --remove "$HNAME" --answers "$HANS" >"$SCRATCH/rm.out" 2>&1
RC=$?
[ "$RC" = 75 ] && ok "--remove without A_REMOVE=y aborts (75)" \
               || bad "--remove without A_REMOVE=y aborts" "exit $RC"
[ -d "$REPO_ROOT/config/$HNAME" ] && ok "  ...and nothing was removed" \
                                  || bad "  ...and nothing was removed"

"$REPO_ROOT/setup.sh" --remove 'bad name!' --answers "$HANS" >/dev/null 2>&1
[ $? = 78 ] && ok "--remove rejects an invalid name (78)" \
            || bad "--remove rejects an invalid name"
"$REPO_ROOT/setup.sh" --remove no-such-backup --answers "$HANS" >/dev/null 2>&1
[ $? = 78 ] && ok "--remove of an unknown backup fails loudly (78)" \
            || bad "--remove of an unknown backup fails loudly"

printf 'A_REMOVE=y\n' >"$HANS"
"$REPO_ROOT/setup.sh" --remove "$HNAME" --answers "$HANS" >"$SCRATCH/rm.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "--remove with A_REMOVE=y succeeds" \
              || bad "--remove with A_REMOVE=y succeeds" "exit $RC; $(tail -3 "$SCRATCH/rm.out")"
[ ! -d "$REPO_ROOT/config/$HNAME" ] && [ ! -d "$REPO_ROOT/logs/$HNAME" ] \
    && [ ! -f "$REPO_ROOT/backups/$HNAME.sh" ] \
    && ok "config, logs and runner are gone" || bad "config, logs and runner are gone"
[ -f "$SCRATCH/hl-dest/data.txt" ] \
    && ok "the backed-up data is untouched" || bad "the backed-up data is untouched"
grep -q 'NOT touched' "$SCRATCH/rm.out" \
    && ok "the removal says the data is safe" || bad "the removal says the data is safe"

# ---------------------------------------------------------------------------
head_ "status.sh --porcelain (hermetic fake repo)"
# status.sh anchors on its own location, and this machine's real config/ may
# legitimately be stale or waiting -- so porcelain assertions run in a scratch
# copy of the tooling with fully controlled config and logs.
FR=$SCRATCH/fakerepo
mkdir -p "$FR/config/alpha" "$FR/logs/alpha"
cp -R "$REPO_ROOT/lib" "$FR/lib"
cp "$REPO_ROOT/status.sh" "$FR/status.sh"
printf '%s\n' "$SCRATCH/src" >"$FR/config/alpha/source.txt"
{ echo 'USER=someone'; echo 'HOST=example.invalid'; echo 'DEST_PATH=/remote/dest'; } >"$FR/config/alpha/destination.txt"
{ echo 'EPOCH=1700000000'; echo 'WHEN=2026-01-01 00:00:00'; echo 'RC=0'
  echo 'FILES=5'; echo 'TOTAL_FILES=321'; echo 'ELAPSED=3'; echo 'DRY=0'
  echo 'HOW=cron'; echo "LOG=$FR/logs/alpha/x.log"; } >"$FR/logs/alpha/last-run.txt"

"$FR/status.sh" --porcelain >"$SCRATCH/porc.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "porcelain: healthy repo exits 0" || bad "porcelain: healthy repo exits 0" "exit $RC"
grep -qx 'BACKUP=alpha' "$SCRATCH/porc.out" \
    && ok "porcelain: BACKUP= opens the block" || bad "porcelain: BACKUP= opens the block"
grep -qx 'RC=0' "$SCRATCH/porc.out" && grep -qx 'VERDICT=SUCCESS' "$SCRATCH/porc.out" \
    && ok "porcelain: RC and VERDICT are emitted" || bad "porcelain: RC and VERDICT are emitted"
grep -qx 'NEVER_RAN=0' "$SCRATCH/porc.out" \
    && ok "porcelain: NEVER_RAN=0 for a backup that ran" || bad "porcelain: NEVER_RAN=0"
grep -qx 'TRIGGERED=cron' "$SCRATCH/porc.out" \
    && ok "porcelain: TRIGGERED carries what started the run" \
    || bad "porcelain: TRIGGERED carries what started the run"
grep -qx 'TOTAL_FILES=321' "$SCRATCH/porc.out" \
    && ok "porcelain: TOTAL_FILES is emitted" || bad "porcelain: TOTAL_FILES is emitted"
# The grammar is the config grammar: config_get must be able to read it.
[ "$(config_get "$SCRATCH/porc.out" RSYNC_FLAVOUR)" != '' ] \
    && ok "porcelain parses with config_get" || bad "porcelain parses with config_get"

# A failing last run flips the exit code, exactly like the pretty mode.
sed 's/^RC=0/RC=23/' "$FR/logs/alpha/last-run.txt" >"$FR/logs/alpha/last-run.tmp" \
    && mv "$FR/logs/alpha/last-run.tmp" "$FR/logs/alpha/last-run.txt"
"$FR/status.sh" --porcelain >"$SCRATCH/porc23.out" 2>&1
RC=$?
[ "$RC" = 1 ] && ok "porcelain: RC=23 makes the exit code 1" || bad "porcelain: RC=23 exit 1" "exit $RC"
grep -qx 'RC=23' "$SCRATCH/porc23.out" && grep -q '^VERDICT=PARTIAL' "$SCRATCH/porc23.out" \
    && ok "porcelain: the PARTIAL verdict is emitted" || bad "porcelain: PARTIAL verdict"

# A configured backup that never ran: NEVER_RAN=1 and the block still closes.
mkdir -p "$FR/config/beta"
printf '%s\n' "$SCRATCH/src" >"$FR/config/beta/source.txt"
{ echo 'USER=x'; echo 'HOST=example.invalid'; echo 'DEST_PATH=/d'; } >"$FR/config/beta/destination.txt"
"$FR/status.sh" --porcelain >"$SCRATCH/porcnr.out" 2>&1
awk '/^BACKUP=beta$/{f=1} f && /^NEVER_RAN=1$/{n=1} f && /^$/{c=1; exit} END{exit !(n && c)}' "$SCRATCH/porcnr.out" \
    && ok "porcelain: never-ran block has NEVER_RAN=1 and is blank-line closed" \
    || bad "porcelain: never-ran block" "$(sed -n '/^BACKUP=beta/,/^$/p' "$SCRATCH/porcnr.out" | tr '\n' '|')"
# Pretty mode still works from the same fake repo and agrees on the verdict.
"$FR/status.sh" >"$SCRATCH/pretty.out" 2>&1
grep -q 'PARTIAL' "$SCRATCH/pretty.out" \
    && ok "pretty mode agrees with porcelain on the verdict" \
    || bad "pretty mode agrees with porcelain"
"$FR/status.sh" --nonsense >/dev/null 2>&1
[ $? = 64 ] && ok "an unknown status.sh argument is refused (64)" \
            || bad "an unknown status.sh argument is refused"

# ---------------------------------------------------------------------------
head_ "remote.sh against a fake ssh"
export FAKE_SSH_ARGV=$SCRATCH/ssh-argv.txt
FAKESSH=$TESTS_DIR/fake-ssh
chmod +x "$FAKESSH" "$TESTS_DIR/fake-ssh-copy-id" 2>/dev/null
RSH() { env RBS_SSH_BIN="$FAKESSH" "$REPO_ROOT/remote.sh" "$@"; }

/bin/bash -n "$REPO_ROOT/remote.sh" && ok "bash 3.2 parses remote.sh" || bad "bash 3.2 parses remote.sh"

RSH add 'bad label!' fakebox '~/x' >/dev/null 2>&1
[ $? = 78 ] && ok "add refuses an invalid label (78)" || bad "add refuses an invalid label"
RSH add testbox '-oProxyCommand=evil' '~/x' >/dev/null 2>&1
[ $? = 78 ] && ok "add refuses an option-shaped host (78)" || bad "add refuses an option-shaped host"
RSH testbox status >/dev/null 2>&1
[ $? = 78 ] && ok "an unknown remote fails loudly (78)" || bad "an unknown remote fails loudly"

RSH add testbox fakebox '~/rsyncronizer' >/dev/null 2>&1 \
    && [ -f "$REPO_ROOT/remotes/testbox.txt" ] \
    && ok "add writes remotes/<label>.txt" || bad "add writes remotes/<label>.txt"
RSH list | grep -q '^testbox' && ok "list shows the remote" || bad "list shows the remote"

: >"$FAKE_SSH_ARGV"
RSH testbox status >"$SCRATCH/rstatus.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "remote status exits with the remote's health (0)" \
              || bad "remote status exits 0" "exit $RC; $(tail -2 "$SCRATCH/rstatus.out")"
grep -qx 'BACKUP=remote-backup' "$SCRATCH/rstatus.out" \
    && ok "remote porcelain passes through" || bad "remote porcelain passes through"
grep -qx 'REMOTE_VERSION=0.1.0' "$SCRATCH/rstatus.out" \
    && ok "the handshake version joins the header" || bad "the handshake version joins the header"
grep -qx 'BatchMode=yes' "$FAKE_SSH_ARGV" && grep -qx -- '--' "$FAKE_SSH_ARGV" \
    && grep -qx 'fakebox' "$FAKE_SSH_ARGV" \
    && ok "ssh argv carries BatchMode and the -- separator" \
    || bad "ssh argv carries BatchMode and --"

env RBS_SSH_BIN="$FAKESSH" FAKE_SSH_EXIT=255 "$REPO_ROOT/remote.sh" testbox status >"$SCRATCH/r255.out" 2>&1
[ $? = 69 ] && grep -q 'ssh-setup' "$SCRATCH/r255.out" \
    && ok "unreachable host: exit 69, points at ssh-setup" \
    || bad "unreachable host: exit 69, points at ssh-setup"
env RBS_SSH_BIN="$FAKESSH" FAKE_SSH_NO_PATH=1 "$REPO_ROOT/remote.sh" testbox status >"$SCRATCH/rpath.out" 2>&1
[ $? = 78 ] && grep -q 'path not found' "$SCRATCH/rpath.out" \
    && ok "bad engine path: exit 78, names the path" || bad "bad engine path diagnosis"
env RBS_SSH_BIN="$FAKESSH" FAKE_SSH_NO_VERSION=1 "$REPO_ROOT/remote.sh" testbox status >"$SCRATCH/rver.out" 2>&1
[ $? = 78 ] && grep -q 'too old' "$SCRATCH/rver.out" \
    && ok "pre-VERSION engine: exit 78, says too old" || bad "pre-VERSION engine diagnosis"

: >"$FAKE_SSH_ARGV"
RSH testbox dry alpha >/dev/null 2>&1
[ $? = 0 ] && ok "remote dry run exits with the remote's code" || bad "remote dry run exit"
grep -q 'backups/alpha.sh --dry-run' "$FAKE_SSH_ARGV" \
    && ok "the remote command targets the named runner" || bad "the remote command targets the runner"
grep -qx -- '-t' "$FAKE_SSH_ARGV" \
    && ok "run modes request a remote tty (-t)" || bad "run modes request a remote tty"
grep -q 'RBS_NO_SUPPORT_NAG=1 \./backups/alpha.sh' "$FAKE_SSH_ARGV" \
    && ok "remote runs suppress the far side's support reminder" \
    || bad "remote runs suppress the support reminder"
: >"$FAKE_SSH_ARGV"
RSH testbox run 'bad name' >/dev/null 2>&1
[ $? = 78 ] && [ ! -s "$FAKE_SSH_ARGV" ] \
    && ok "an invalid backup name never reaches ssh (78)" \
    || bad "an invalid backup name never reaches ssh"
RSH testbox sync-deletions alpha >/dev/null 2>&1
grep -q -- '--sync-deletions' "$FAKE_SSH_ARGV" \
    && ok "remote sync-deletions passes the flag through" \
    || bad "remote sync-deletions passes the flag"

RSH add spacebox fakebox '~/My Backups/repo' >/dev/null 2>&1
: >"$FAKE_SSH_ARGV"
RSH spacebox status >/dev/null 2>&1
grep -q "cd ~/'My Backups/repo'" "$FAKE_SSH_ARGV" \
    && ok "a path with spaces is quoted, ~ expansion preserved" \
    || bad "a path with spaces is quoted" "$(tail -1 "$FAKE_SSH_ARGV")"
RSH rm spacebox >/dev/null 2>&1
RSH rm testbox >/dev/null 2>&1
[ ! -f "$REPO_ROOT/remotes/testbox.txt" ] \
    && ok "rm removes only the local definition" || bad "rm removes the local definition"

# ---------------------------------------------------------------------------
head_ "ssh-setup.sh"
/bin/bash -n "$REPO_ROOT/ssh-setup.sh" && ok "bash 3.2 parses ssh-setup.sh" || bad "bash 3.2 parses ssh-setup.sh"
SSHHOME=$SCRATCH/sshhome
mkdir -p "$SSHHOME"
"$REPO_ROOT/ssh-setup.sh" >/dev/null 2>&1
[ $? = 64 ] && ok "no target: usage error (64)" || bad "no target: usage error"
"$REPO_ROOT/ssh-setup.sh" '-oProxyCommand=evil' >/dev/null 2>&1
[ $? = 78 ] && ok "an option-shaped target is refused (78)" || bad "option-shaped target refused"

env HOME="$SSHHOME" RBS_SSH_BIN="$FAKESSH" \
    RBS_SSH_COPY_ID_BIN="$TESTS_DIR/fake-ssh-copy-id" \
    FAKE_SCI_ARGV="$SCRATCH/sci-argv.txt" \
    "$REPO_ROOT/ssh-setup.sh" user@fakebox >"$SCRATCH/sshsetup.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "happy path: key generated, copied, verified (0)" \
              || bad "ssh-setup happy path" "exit $RC; $(tail -3 "$SCRATCH/sshsetup.out")"
[ -f "$SSHHOME/.ssh/id_ed25519" ] && [ -f "$SSHHOME/.ssh/id_ed25519.pub" ] \
    && ok "the key pair lives under \$HOME/.ssh" || bad "the key pair lives under \$HOME/.ssh"
grep -qx 'user@fakebox' "$SCRATCH/sci-argv.txt" \
    && ok "ssh-copy-id targets user@host" || bad "ssh-copy-id targets user@host"
grep -q 'cron-equivalent' "$SCRATCH/sshsetup.out" \
    && ok "the verification is the cron-equivalent probe" || bad "cron-equivalent verification"

env HOME="$SSHHOME" RBS_SSH_BIN="$FAKESSH" FAKE_SSH_TRUE_EXIT=1 \
    RBS_SSH_COPY_ID_BIN="$TESTS_DIR/fake-ssh-copy-id" \
    "$REPO_ROOT/ssh-setup.sh" user@fakebox >/dev/null 2>&1
[ $? = 69 ] && ok "copied but BatchMode still failing: exit 69" \
            || bad "BatchMode-failing path exits 69"

# ---------------------------------------------------------------------------
head_ "cli/rsyncronizer + the engine manifest"
/bin/bash -n "$REPO_ROOT/cli/rsyncronizer" && ok "bash 3.2 parses cli/rsyncronizer" || bad "bash parses cli/rsyncronizer"
/bin/bash -n "$REPO_ROOT/cli/install-cli.sh" && ok "bash 3.2 parses install-cli.sh" || bad "bash parses install-cli.sh"

# The manifest is the single source: every entry exists, no hard-coded copies.
MISSING=''
OPTIONAL=''
while IFS= read -r _mf; do
    case $_mf in ''|'#'*) continue ;; esac
    # '?' marks an entry that is built, not committed (bin/rclone).
    case $_mf in
        '?'*) OPTIONAL="$OPTIONAL ${_mf#?}"; continue ;;
    esac
    [ -f "$REPO_ROOT/$_mf" ] || MISSING="$MISSING $_mf"
done <"$REPO_ROOT/lib/engine-manifest.txt"
[ -z "$MISSING" ] && ok "every required manifest entry exists" \
                  || bad "every required manifest entry exists" "missing:$MISSING"
# The marker only earns its keep if EVERY consumer understands it; a parser
# that missed it would either crash the CLI build or silently drop the binary.
if [ -n "$OPTIONAL" ]; then
    ok "the manifest marks build-time entries optional:$OPTIONAL"
    for _c in gui/app/engine.py gui/rsyncronizer.spec cli/install-cli.sh .github/workflows/release.yml; do
        grep -q '?' "$REPO_ROOT/$_c" && grep -qiE 'optional|startswith\("\?"\)|lstrip|\$\{f#\?\}|\$\{_mf#\?\}' "$REPO_ROOT/$_c" \
            && ok "  $_c handles it" || bad "  $_c handles the optional marker"
    done
    # A leading '?' must never survive into a path.
    for _o in $OPTIONAL; do
        case $_o in '?'*) bad "the marker is stripped from '$_o'" ;; *) ok "  the marker is stripped from $_o" ;; esac
    done
fi
grep -q 'lib/cloud.sh' "$REPO_ROOT/lib/engine-manifest.txt" \
    && ok "lib/cloud.sh ships (a cloud backup is useless without it)" \
    || bad "lib/cloud.sh is in the manifest"
grep -q 'lib/rclone-version.txt' "$REPO_ROOT/lib/engine-manifest.txt" \
    && ok "lib/rclone-version.txt ships" || bad "lib/rclone-version.txt is in the manifest"
grep -q 'ENGINE_FILES = \[' "$REPO_ROOT/gui/app/engine.py" \
    && bad "engine.py reads the manifest (no hard-coded list)" "found a literal list" \
    || ok "engine.py reads the manifest (no hard-coded list)"
grep -q 'engine-manifest.txt' "$REPO_ROOT/gui/rsyncronizer.spec" \
    && ok "the spec reads the manifest" || bad "the spec reads the manifest"
grep -q 'engine-manifest.txt' "$REPO_ROOT/cli/install-cli.sh" \
    && ok "the installer reads the manifest" || bad "the installer reads the manifest"

[ "$("$REPO_ROOT/cli/rsyncronizer" version)" = "$(cat "$REPO_ROOT/VERSION")" ] \
    && ok "cli version matches VERSION" || bad "cli version matches VERSION"
"$REPO_ROOT/cli/rsyncronizer" help | grep -q 'sync-deletions' \
    && ok "cli help lists the commands" || bad "cli help lists the commands"
"$REPO_ROOT/cli/rsyncronizer" definitely-not-a-command >/dev/null 2>&1
[ $? = 64 ] && ok "an unknown command exits 64" || bad "an unknown command exits 64"
"$REPO_ROOT/cli/rsyncronizer" run >/dev/null 2>&1
[ $? = 78 ] && ok "run without a name is refused (78)" || bad "run without a name is refused"
"$REPO_ROOT/cli/rsyncronizer" run no-such-backup >/dev/null 2>&1
[ $? = 78 ] && ok "run of an unknown backup is refused (78)" || bad "run of an unknown backup refused"
# Dispatch E2E: the suite's own stub backup, through the CLI.
FAKE_RSYNC_EXIT=0 "$REPO_ROOT/cli/rsyncronizer" dry "$NAME" >/dev/null 2>&1
[ $? = 0 ] && ok "cli dispatches to a real runner (dry run, exit 0)" \
           || bad "cli dispatches to a real runner"

# The ~/.local/bin symlink must resolve back to the engine root.
mkdir -p "$SCRATCH/bin"
ln -sf "$REPO_ROOT/cli/rsyncronizer" "$SCRATCH/bin/rsyncronizer"
[ "$("$SCRATCH/bin/rsyncronizer" version)" = "$(cat "$REPO_ROOT/VERSION")" ] \
    && ok "the file symlink resolves to the engine (install anchoring)" \
    || bad "the file symlink resolves to the engine"

# install-cli.sh into a scratch home: engine lands, command works.
env HOME="$SCRATCH/clihome" XDG_DATA_HOME="$SCRATCH/clihome/.local/share" \
    "$REPO_ROOT/cli/install-cli.sh" >"$SCRATCH/cli-install.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "install-cli.sh installs from a clone (0)" \
              || bad "install-cli.sh installs" "exit $RC; $(tail -2 "$SCRATCH/cli-install.out")"
CLIHOME_ENGINE=$SCRATCH/clihome/.local/share/rsync-backup-scripts
[ -x "$CLIHOME_ENGINE/cli/rsyncronizer" ] && [ -x "$CLIHOME_ENGINE/status.sh" ] \
    && ok "the installed engine is executable" || bad "the installed engine is executable"
"$SCRATCH/clihome/.local/bin/rsyncronizer" status >"$SCRATCH/cli-status.out" 2>&1
grep -q 'No backups are configured' "$SCRATCH/cli-status.out" \
    && ok "the installed cli runs status against ITS engine home" \
    || bad "the installed cli runs status" "$(tail -2 "$SCRATCH/cli-status.out")"

# --- cli remote status: the pretty REMOTE: view ----------------------------
RSH add testbox fakebox '~/rsyncronizer' >/dev/null 2>&1
env RBS_SSH_BIN="$FAKESSH" "$REPO_ROOT/cli/rsyncronizer" remote testbox status \
    >"$SCRATCH/cli-remote.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "cli remote status exits with the remote's health" \
              || bad "cli remote status exit" "rc $RC; $(tail -2 "$SCRATCH/cli-remote.out")"
grep -q '^REMOTE: fakebox' "$SCRATCH/cli-remote.out" \
    && ok "cli renders the REMOTE: machine-name header" \
    || bad "cli renders the REMOTE: header" "$(head -1 "$SCRATCH/cli-remote.out")"
grep -q 'remote-backup' "$SCRATCH/cli-remote.out" \
    && grep -q 'SUCCESS' "$SCRATCH/cli-remote.out" \
    && ok "cli lists the remote backups with verdicts" \
    || bad "cli lists the remote backups"
RSH rm testbox >/dev/null 2>&1

# --- cli update: offline via a file:// release ------------------------------
# A clone must never self-update over git.
"$REPO_ROOT/cli/rsyncronizer" update >/dev/null 2>&1
[ $? = 78 ] && ok "update from a git clone is refused (git pull instead)" \
            || bad "update from a git clone is refused"

# Build a fake v9.9.9 release: manifest files + installer, served over file://.
UPD=$SCRATCH/upd-release
mkdir -p "$UPD/rsyncronizer-cli-9.9.9"
while IFS= read -r _mf; do
    case $_mf in ''|'#'*) continue ;; esac
    case $_mf in '?'*) _mf=${_mf#?}; [ -f "$REPO_ROOT/$_mf" ] || continue ;; esac
    mkdir -p "$UPD/rsyncronizer-cli-9.9.9/$(dirname "$_mf")"
    cp "$REPO_ROOT/$_mf" "$UPD/rsyncronizer-cli-9.9.9/$_mf"
done <"$REPO_ROOT/lib/engine-manifest.txt"
cp "$REPO_ROOT/cli/install-cli.sh" "$UPD/rsyncronizer-cli-9.9.9/install-cli.sh"
printf '9.9.9\n' >"$UPD/rsyncronizer-cli-9.9.9/VERSION"
# The tarball must be NAMED like the real release asset: the URL matcher
# keys on 'rsyncronizer-cli-' appearing in the download URL.
tar -czf "$UPD/rsyncronizer-cli-9.9.9.tar.gz" -C "$UPD" rsyncronizer-cli-9.9.9
printf '{"tag_name": "v9.9.9", "assets": [{"name": "rsyncronizer-cli-9.9.9.tar.gz", "browser_download_url": "file://%s"}]}\n' \
    "$UPD/rsyncronizer-cli-9.9.9.tar.gz" >"$UPD/api.json"

# The INSTALLED cli (from the install test above) has no .git and its own home.
env HOME="$SCRATCH/clihome" XDG_DATA_HOME="$SCRATCH/clihome/.local/share" \
    RBS_UPDATE_API_URL="file://$UPD/api.json" \
    "$SCRATCH/clihome/.local/bin/rsyncronizer" update >"$SCRATCH/cli-update.out" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "cli update applies a newer release (0)" \
              || bad "cli update applies a newer release" "rc $RC; $(tail -2 "$SCRATCH/cli-update.out")"
[ "$(cat "$SCRATCH/clihome/.local/share/rsync-backup-scripts/VERSION")" = "9.9.9" ] \
    && ok "the installed engine is now the new version" \
    || bad "the installed engine is now the new version"
env HOME="$SCRATCH/clihome" XDG_DATA_HOME="$SCRATCH/clihome/.local/share" \
    RBS_UPDATE_API_URL="file://$UPD/api.json" \
    "$SCRATCH/clihome/.local/bin/rsyncronizer" update >"$SCRATCH/cli-update2.out" 2>&1
grep -q 'already up to date' "$SCRATCH/cli-update2.out" \
    && ok "a second update is a no-op (already up to date)" \
    || bad "a second update is a no-op" "$(tail -1 "$SCRATCH/cli-update2.out")"

# ---------------------------------------------------------------------------
printf '\n--------------------------------------------------------------\n'
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
