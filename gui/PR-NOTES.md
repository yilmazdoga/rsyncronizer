# PR notes for v0.1.0

Everything is on `feature/v0.1.0`, uncommitted. Nothing has been committed or
pushed for you.

## 1. Commit, push, open the PR

```
git add -A
git commit -m "v0.1.0: remotes, ssh setup, progress panel, CLI, ignore editor, prune-UX fix"
git push -u origin feature/v0.1.0
```

Open the PR; the four required checks run as before. Paste the description
below.

## 2. Merge, then release

```
git checkout main
git pull --ff-only
git tag v0.1.0
git push origin v0.1.0
```

The draft release will carry THREE artifacts (macOS app, Linux app, and the
new CLI tarball). Review, publish. Then on the workstation:
`cd ~/rsyncronizer && git pull --ff-only && ./tests/run-tests.sh`.

To see the workstation's backups in the Mac app afterwards: Add server →
label `workstation`, host `user@backup-server`, path `~/rsyncronizer`.

---

# PR description (paste into GitHub)

## v0.1.0: remote servers, SSH setup, progress panel, CLI, ignore editing

Seven features, engine-first as always (all logic in bash; GUI and CLI are
thin frontends):

- **Remote servers** (`remote.sh`): list/run/dry/sync-deletions for backups on
  other machines over ssh. UI groups LOCAL + one box per server; remote
  sync-deletions streams the remote engine's own preview and typed-phrase
  prompt (all safeguards server-side). Every ssh call BatchMode+timeout;
  hosts/paths validated or quoted before touching an argv; three-way
  handshake errors (unreachable / bad path / engine too old).
- **SSH key setup** (`ssh-setup.sh`): keygen if needed + ssh-copy-id +
  cron-equivalent verification. The GUI forwards the password over the pty,
  masked, never echoed or stored, enabled by PtyRunner now making the pty
  the child's CONTROLLING terminal (ssh reads /dev/tty).
- **Progress panel**: activity bar + honest counters, raw console behind a
  dropdown. No invented percentages.
- **Refresh button removed**: 30 s auto-refresh with a strict lifecycle
  (paused during runs/dialogs; generation-tokened remote fetches).
- **Sync-deletions UX fix**: no backup ever ran before confirmation; the
  illusion came from run-log-style audit files and header noise. Audits are
  now `prune-<ts>-{preview,recheck}.log` in their own 10-slot ring, and the
  dialog is staged (scan → list → phrase → re-verify → transfer).
- **CLI**: `rsyncronizer` bash dispatcher + `install-cli.sh` + a third
  release artifact; engine file set single-sourced in
  `lib/engine-manifest.txt`.
- **Ignore editing**: user-global `config/global-exclude.txt` layered BEFORE
  the shipped baseline (so `+` overrides work), editable in-app and via
  `rsyncronizer ignore`.

Engine guarantees unchanged: the never-delete guard, the sync-deletions
gate/recheck, runner template and config grammar are untouched; new keys are
additive (HOW, TOTAL_FILES).

Tests: bash suite ~300 checks (remote.sh against a fake ssh, ssh-setup,
CLI + manifest consistency, prune-ring regressions, exclude ordering);
pytest 29 (ctty regression, staged-dialog flows, password masking, remote
plumbing); widget E2Es on scratch volumes.
